import ArgumentParser
import CryptoKit
import Foundation
import MacProviderCore

struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Inspect or switch the provider warm model.",
        subcommands: [
            ModelsListCommand.self,
            ModelsSwitchCommand.self,
            ModelsStatusCommand.self,
            ModelsBrowseCommand.self,
            ModelsAdoptRecommendationCommand.self,
        ]
    )
}

struct ModelsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List models known to this provider (warm/idle)."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths). Overrides MACPROVIDER_SUPPORTED_MODELS and config supported_models.")
    var supportedModels: String?

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/malibu-cli/ctl.sock.")
    var ctlSocketPath: String?

    @Flag(name: .customLong("json"), help: "Emit the strict models_list.v1 JSON contract.")
    var emitJSON = false

    func run() async throws {
        let resolved = try loadModelsConfig(config: config, model: model, supportedModels: supportedModels, ctlSocketPath: ctlSocketPath)
        let socketPath = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
        do {
            let (connection, status) = try await connectAndReadStatus(socketPath: socketPath)
            try await connection.send(.modelsRequest)
            let modelsFrame = try await connection.receive(timeout: 2.0)
            guard case let .modelsResponse(authorizedModelIDs, supportedModelIDs) = modelsFrame else {
                await connection.close()
                throw ControlSocketConnectError.handshakeTimeout(path: socketPath.path)
            }
            await connection.close()
            // Preserve every configured supported model for the catalog. The
            // running authority inventory only determines whether an idle row
            // is locally ready; it must not erase supported-but-uninstalled
            // rows that Malibu presents as Needs preparation.
            var models = supportedModelIDs.isEmpty ? (resolved.supportedModels ?? []) : supportedModelIDs
            for authorizedModelID in authorizedModelIDs where !models.contains(where: {
                modelIDKey($0) == modelIDKey(authorizedModelID)
            }) {
                models.append(authorizedModelID)
            }
            if !models.contains(where: { modelIDKey($0) == modelIDKey(status.currentModelID) }) {
                models.insert(status.currentModelID, at: 0)
            }
            if emitJSON {
                try await emitJSONList(
                    currentModelID: status.currentModelID,
                    supportedModels: models,
                    source: "control_socket",
                    warmSwapAvailable: true,
                    authorizedModelIDs: Set(authorizedModelIDs.map(modelIDKey)),
                    artifactResolver: CachedModelArtifactResolver.forConfig(resolved)
                )
            } else {
                printModelsTable(currentModelID: status.currentModelID, supportedModels: models)
            }
        } catch ControlSocketConnectError.socketAbsent(let path) {
            let models = idleCatalog(from: resolved)
            if emitJSON {
                try await emitJSONList(
                    currentModelID: nil,
                    supportedModels: models,
                    source: "config_fallback",
                    warmSwapAvailable: false,
                    artifactResolver: CachedModelArtifactResolver.forConfig(resolved)
                )
            } else {
                print("serve not running; warm-swap disabled")
                printModelsTable(currentModelID: nil, supportedModels: models)
            }
            writeStderr("malibu-cli serve is not running on this host (no control socket at \(path))")
            return
        } catch ControlSocketConnectError.connectionRefused(let path) {
            writeStderr("stale control socket at \(path) (no listener); remove the file and restart serve")
            throw ExitCode(4)
        } catch ControlSocketConnectError.handshakeTimeout {
            writeStderr("serve is running but warm-swap is not enabled (or serve is unresponsive); restart serve with --enable-warm-swap")
            throw ExitCode(4)
        }
    }
}

struct ModelsSwitchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Switch the provider to another supported model."
    )

    @Argument(help: "Target HuggingFace model ID or local path.")
    var targetModelID: String

    @Flag(help: "Bypass local cooldown and RAM-fit checks. This does not allow unsupported models or override network concurrency limits.")
    var force = false

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "Current HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths). Overrides MACPROVIDER_SUPPORTED_MODELS and config supported_models.")
    var supportedModels: String?

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/malibu-cli/ctl.sock.")
    var ctlSocketPath: String?

    @Option(help: "CLI-side cooldown state file. Overrides MACPROVIDER_SWITCH_STATE_PATH and config switch_state_path. Default $HOME/Library/Application Support/malibu-cli/last-switch.ts.")
    var switchStatePath: String?

    @Flag(name: .customLong("json"), help: "Emit model_switch_event.v1 frames on stdout.")
    var emitJSON = false

    func run() async throws {
        let transactionID = UUID().uuidString.lowercased()
        func reject(_ message: String, code: String, exitCode: Int32, cooldownSeconds: Int? = nil) throws -> Never {
            if emitJSON {
                try ModelSwitchingWireCodec.printJSON(
                    ModelSwitchEventWire(
                        type: "terminal",
                        transactionID: transactionID,
                        fromModelID: nil,
                        targetModelID: targetModelID,
                        phase: "failed",
                        cancellable: false,
                        reason: code,
                        cooldownSecondsRemaining: cooldownSeconds
                    )
                )
            }
            writeStderr(message)
            throw ExitCode(exitCode)
        }

        let options = ModelsSwitchOptions(force: force, switchStatePath: switchStatePath)
        let resolved = try loadModelsConfig(
            config: config,
            model: model,
            supportedModels: supportedModels,
            ctlSocketPath: ctlSocketPath,
            switchStatePath: switchStatePath
        )

        do {
            _ = try SupportedModels.validate(model: targetModelID, supportedModels: resolved.supportedModels)
        } catch SupportedModelsValidationError.modelNotInCatalog {
            try reject("switch target \(targetModelID) not in --supported-models", code: "not_in_supported_models", exitCode: 2)
        } catch let error as SupportedModelsValidationError {
            try reject("\(error)", code: "invalid_supported_models", exitCode: 2)
        }

        // Pre-flight RAM fit check per SPEC-001 v1.4 §6.13 (R-6.13.1 through
        // R-6.13.5). Same name-parsing + headroom rules as SPEC-003 v0.9.1
        // FR-D2.1 step 4 so a model accepted at install time is judged the
        // same way here. `--force` bypasses both the wontFit hard-block and
        // the tight-fit warning, and overrides the .unknown fail-closed gate
        // for HF-shape ids (R-6.13.2).
        switch ModelFit.evaluate(modelID: targetModelID, ramGB: ModelFit.detectRAMGB()) {
        case let .wontFit(estGB, ramGB):
            if options.force {
                writeStderr("warning: target ~\(estGB) GB weights will not fit on \(ramGB) GB Mac; --force set, proceeding")
            } else {
                try reject("switch target \(targetModelID) (~\(estGB) GB weights) will not fit on \(ramGB) GB Mac. Re-issue with --force to override.", code: "ram_unfit", exitCode: 2)
            }
        case let .tight(estGB, ramGB):
            // Round-2 (codex code MINOR): match the comment — --force quiets
            // the tight warning too. CI scripts use --force to mean "I know
            // what I'm doing, don't shout."
            if !options.force {
                writeStderr("warning: tight fit — target ~\(estGB) GB weights on \(ramGB) GB Mac; may swap or OOM under load")
            }
        case .fits:
            break
        case let .unknown(reason):
            // Round-2 (codex security MINOR): fail closed when the target
            // *looks like* an HF id (contains '/' and isn't a local path)
            // but the parser can't size it. Otherwise a malicious or
            // oddly-named oversized repo bypasses the guard. Synthetic IDs
            // like "old-model" / "A" used in tests, and local paths like
            // "./checkpoints/foo", still skip the fit check as before.
            let looksLikeHFID = targetModelID.contains("/")
                && !targetModelID.hasPrefix(".")
                && !targetModelID.hasPrefix("/")
            if looksLikeHFID && !options.force {
                try reject("could not size HF-style target \(targetModelID): \(reason). Re-issue with --force to override.", code: "fit_unknown", exitCode: 2)
            }
            writeStderr("note: \(reason); skipping fit check")
        }

        if !options.force {
            let storePath = ControlSocketPaths.defaultSwitchStatePath(resolved.switchStatePath)
            let store = SwitchStateStore(path: storePath)
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            switch store.cooldownDecision(now: nowMs) {
            case .clear:
                break
            case .cooldown(let secondsRemaining):
                try reject("swap on cooldown for \(secondsRemaining)s. Re-issue with --force to bypass", code: "cooldown", exitCode: 6, cooldownSeconds: secondsRemaining)
            }
        }

        let socketPath = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
        let (connection, status) = try await connectAndReadStatusOrExit(socketPath: socketPath)
        let requestedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await connection.send(.switchRequest(targetModelID: targetModelID, requestedAtMs: requestedAtMs))
        let ack = try await connection.receive()
        guard case let .switchAck(accepted, reason, currentTarget, secondsRemaining) = ack else {
            writeStderr("expected switch_ack")
            await connection.close()
            try reject("expected switch_ack", code: "invalid_ack", exitCode: 4)
        }

        guard accepted else {
            await connection.close()
            switch reason {
            case .loadingInProgress:
                let currentTarget = currentTarget ?? "<unknown>"
                try reject("provider is already loading \(currentTarget); refusing to start a second swap. Wait for current switch to complete (malibu-cli models status)", code: "loading_in_progress", exitCode: 3)
            case .cooldown:
                let seconds = secondsRemaining ?? 0
                try reject("swap on cooldown for \(seconds)s. Re-issue with --force to bypass", code: "cooldown", exitCode: 6, cooldownSeconds: seconds)
            case .notInSupportedModels:
                try reject("switch target \(targetModelID) not in --supported-models (rejected by serve)", code: "not_in_supported_models", exitCode: 2)
            default:
                try reject("switch rejected", code: "rejected", exitCode: 4)
            }
        }

        if emitJSON {
            try ModelSwitchingWireCodec.printJSON(
                ModelSwitchEventWire(
                    type: "accepted",
                    transactionID: transactionID,
                    fromModelID: status.currentModelID,
                    targetModelID: targetModelID,
                    phase: "requested",
                    cancellable: false
                )
            )
        }

        let storePath = ControlSocketPaths.defaultSwitchStatePath(resolved.switchStatePath)
        let store = SwitchStateStore(path: storePath)
        do {
            try store.writeLastSwitchMs(requestedAtMs)
        } catch {
            writeStderr("warning: could not write switch state file at \(storePath.path): \(error)")
        }

        while true {
            let frame = try await connection.receive()
            guard case let .switchProgress(state, elapsedMs, reason) = frame else {
                continue
            }
            writeStderr("switch_progress state=\(state.rawValue) elapsed_ms=\(elapsedMs)")
            if emitJSON {
                let cooldownSecondsRemaining: Int? = state == .loaded
                    ? {
                        if case let .cooldown(seconds) = store.cooldownDecision(now: Int64(Date().timeIntervalSince1970 * 1000)) {
                            return seconds
                        }
                        return nil
                    }()
                    : nil
                try ModelSwitchingWireCodec.printJSON(
                    ModelSwitchEventWire(
                        type: state == .loaded || state == .failed ? "terminal" : "progress",
                        transactionID: transactionID,
                        fromModelID: status.currentModelID,
                        targetModelID: targetModelID,
                        phase: state.rawValue,
                        elapsedMS: elapsedMs,
                        cancellable: false,
                        reason: reason,
                        cooldownSecondsRemaining: cooldownSecondsRemaining
                    )
                )
            }
            switch state {
            case .loaded:
                await connection.close()
                return
            case .failed:
                await connection.close()
                writeStderr("swap failed: \(reason ?? "unknown")")
                throw ExitCode(5)
            case .loading, .draining:
                continue
            }
        }
    }
}

struct ModelsStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the running provider warm-swap status."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "HuggingFace model identifier or local model path. Overrides MACPROVIDER_MODEL and config file model.")
    var model: String?

    @Option(help: "Comma-separated list of HuggingFace model IDs (or local paths). Overrides MACPROVIDER_SUPPORTED_MODELS and config supported_models.")
    var supportedModels: String?

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/malibu-cli/ctl.sock.")
    var ctlSocketPath: String?

    func run() async throws {
        let resolved = try loadModelsConfig(config: config, model: model, supportedModels: supportedModels, ctlSocketPath: ctlSocketPath)
        let socketPath = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
        let (connection, status) = try await connectAndReadStatusOrExit(socketPath: socketPath)
        await connection.close()
        let data = try ControlSocketCodec.encode(.statusResponse(currentModelID: status.currentModelID, runtimeState: status.runtimeState))
        print(String(decoding: data.dropLast(), as: UTF8.self))
    }
}

struct ModelsAdoptRecommendationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt-recommendation",
        abstract: "Apply and live-switch to an actionable autotune recommendation."
    )

    @Flag(name: .customLong("json"), help: "Emit model_adoption_event.v1 frames on stdout.")
    var emitJSON = false

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG.")
    var config: String?

    @Option(help: "Path to autotune_recommend.v1 JSON, or '-' for stdin.")
    var recommendationJSON: String

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path.")
    var ctlSocketPath: String?

    @Option(help: "CLI-side cooldown state file. Overrides MACPROVIDER_SWITCH_STATE_PATH and config switch_state_path.")
    var switchStatePath: String?

    func run() async throws {
        guard emitJSON else {
            throw ValidationError("adopt-recommendation requires --json")
        }
        let startedAt = Date()
        let transactionID = UUID().uuidString.lowercased()
        var phase = "validating"
        var incumbentModelID: String?
        var targetModelID: String?
        var backupPath: URL?
        var configPath: URL?
        var journalRecord: RecommendationAdoptionJournalRecord?
        var journalURL: URL?

        func elapsed() -> Int { Int(Date().timeIntervalSince(startedAt) * 1000) }
        func event(
            type: String,
            phase eventPhase: String? = nil,
            cancellable: Bool = false,
            reason: String? = nil,
            rollbackState: String? = nil,
            configSHA256: String? = nil,
            backupPath redactedBackupPath: String? = nil
        ) throws {
            try ModelSwitchingWireCodec.printJSON(ModelAdoptionEventWire(
                type: type,
                transactionID: transactionID,
                targetModelID: targetModelID,
                fromModelID: incumbentModelID,
                phase: eventPhase,
                elapsedMS: elapsed(),
                cancellable: cancellable,
                downloadBytesWritten: nil,
                downloadBytesTotal: nil,
                reason: reason,
                rollbackState: rollbackState,
                incumbentModelID: incumbentModelID,
                configSHA256: configSHA256,
                backupPath: redactedBackupPath
            ))
        }
        func fail(_ reason: String, exitCode: Int32, rollbackState: String = "not_needed") throws -> Never {
            try event(type: "failed", phase: phase, reason: reason, rollbackState: rollbackState)
            throw ExitCode(exitCode)
        }

        let recommendation: ParsedRecommendationAdoption
        do {
            recommendation = try Self.loadRecommendation(pathOrStdin: recommendationJSON)
        } catch {
            try event(type: "failed", phase: phase, reason: "invalid_recommendation", rollbackState: "not_needed")
            throw ExitCode(2)
        }
        targetModelID = recommendation.targetModelID
        guard ModelSwitchingWireCodec.safeID(recommendation.targetModelID) else {
            try fail("invalid_target_model", exitCode: 2)
        }
        guard recommendation.draftModel == nil, recommendation.draftModelArtifactSHA256 == nil else {
            try fail("unsupported_draft", exitCode: 2)
        }
        guard !Self.hasBlockingWarning(recommendation.warnings) else {
            try fail("blocked_warning", exitCode: 2)
        }
        do {
            try await Self.validateSignedAuthority(recommendation, configPath: config)
        } catch {
            try fail("signed_authority_invalid", exitCode: 2)
        }
        guard let artifactPath = recommendation.core.modelArtifactPath,
              let artifactSHA = recommendation.core.modelArtifactSHA256,
              let actualSHA = try? ModelArtifactVerifier.canonicalArtifactHash(directory: URL(fileURLWithPath: artifactPath)),
              actualSHA == artifactSHA
        else {
            try fail("artifact_not_verified", exitCode: 2)
        }

        let effectiveConfigPath = Self.effectiveConfigURL(explicit: config)
        configPath = effectiveConfigPath
        let resolved = try loadModelsConfig(
            config: effectiveConfigPath.path,
            model: nil,
            supportedModels: nil,
            ctlSocketPath: ctlSocketPath,
            switchStatePath: switchStatePath
        )
        do {
            _ = try SupportedModels.validate(model: recommendation.targetModelID, supportedModels: resolved.supportedModels)
        } catch SupportedModelsValidationError.modelNotInCatalog {
            try fail("not_in_supported_models", exitCode: 2)
        } catch {
            try fail("invalid_supported_models", exitCode: 2)
        }
        switch ModelFit.evaluate(modelID: recommendation.targetModelID, ramGB: ModelFit.detectRAMGB()) {
        case .wontFit:
            try fail("ram_unfit", exitCode: 2)
        case .unknown:
            if recommendation.targetModelID.contains("/") {
                try fail("fit_unknown", exitCode: 2)
            }
        case .fits, .tight:
            break
        }
        let storePath = ControlSocketPaths.defaultSwitchStatePath(resolved.switchStatePath)
        let store = SwitchStateStore(path: storePath)
        if case let .cooldown(seconds) = store.cooldownDecision(now: Int64(Date().timeIntervalSince1970 * 1000)) {
            try fail("cooldown_\(seconds)", exitCode: 6)
        }
        let socketPath = ControlSocketPaths.resolve(ctlSocketPath: resolved.ctlSocketPath)
        let adoptionLock: RecommendationAdoptionLock
        do {
            adoptionLock = try RecommendationAdoptionLock.acquire(configPath: effectiveConfigPath)
        } catch {
            try fail("adoption_busy", exitCode: 6)
        }
        defer { withExtendedLifetime(adoptionLock) {} }
        let journalStore = RecommendationAdoptionJournalStore()
        do {
            try await Self.recoverPendingTransactions(
                store: journalStore,
                configPath: effectiveConfigPath,
                socketPath: socketPath
            )
        } catch {
            try fail("adoption_recovery_failed", exitCode: 5, rollbackState: "rollback_failed")
        }
        let (connection, status) = try await connectAndReadStatusOrExit(socketPath: socketPath)
        incumbentModelID = status.currentModelID
        if modelIDKey(status.currentModelID) == modelIDKey(recommendation.targetModelID) {
            await connection.close()
            try fail("current_model_already_recommended", exitCode: 2)
        }
        guard resolved.donorMode == recommendation.donorMode else {
            await connection.close()
            try fail("live_donor_mode_mismatch", exitCode: 2)
        }
        try event(type: "accepted", cancellable: false)
        phase = "preparing_artifact"
        try event(type: "progress", phase: phase, cancellable: false)
        let authority = Self.adoptionAuthority(
            transactionID: transactionID,
            incumbentModelID: status.currentModelID,
            recommendation: recommendation
        )
        do {
            try await connection.send(.prepareModelAdoptionRequest(authority))
            let frame = try await connection.receive()
            guard case let .prepareModelAdoptionResult(prepared) = frame,
                  prepared.accepted,
                  Self.preparationMatches(prepared, authority: authority) else {
                await connection.close()
                try fail("runtime_prepare_rejected", exitCode: 5)
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            await connection.close()
            try fail("runtime_prepare_failed", exitCode: 5)
        }
        phase = "config_backup"
        try event(type: "progress", phase: phase, cancellable: false)

        let applier = ConfigApplier(configPath: configPath!)
        do {
            phase = "config_apply"
            let applied = try applier.apply(
                recommendation: recommendation.core,
                now: Date(),
                donorMode: recommendation.donorMode,
                beforeMutation: { before, after, backup, preSHA, postSHA in
                    let record = RecommendationAdoptionJournalRecord(
                        transactionID: transactionID,
                        fromModelID: status.currentModelID,
                        targetModelID: recommendation.targetModelID,
                        recommendationSHA256: recommendation.recommendationSHA256,
                        configPath: effectiveConfigPath.standardizedFileURL.path,
                        preApplyConfigSHA256: preSHA,
                        postApplyConfigSHA256: postSHA,
                        redactedBackupPath: "redacted",
                        recommendationOwnedFieldsBefore: before,
                        recommendationOwnedFieldsAfter: after,
                        now: Date()
                    )
                    try journalStore.write(record)
                    journalRecord = record
                    journalURL = journalStore.url(transactionID: transactionID)
                    backupPath = backup
                }
            )
            backupPath = applied.backupPath
            try event(type: "progress", phase: phase, cancellable: false)
        } catch {
            let rollback = if backupPath != nil || journalRecord != nil {
                Self.rollback(
                    applier: applier,
                    backupPath: backupPath,
                    journalRecord: journalRecord
                )
            } else {
                "not_needed"
            }
            let cleanupReady = Self.persistCancelPending(
                record: &journalRecord,
                rollback: rollback,
                journalStore: journalStore
            )
            let cancelled = cleanupReady
                ? await Self.cancelPreparedAdoption(connection: connection, transactionID: transactionID)
                : false
            await connection.close()
            if cancelled, rollback == "rolled_back", let journalURL {
                try? journalStore.remove(journalURL)
            }
            try fail(
                cancelled ? "config_apply_failed" : "runtime_cancel_failed",
                exitCode: 5,
                rollbackState: rollback
            )
        }

        var runtimeLoaded = false
        do {
            phase = "switch_loading"
            let requestedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            guard var issuedRecord = journalRecord else {
                throw RecommendationAdoptionJournalError.invalidJournal
            }
            issuedRecord.phase = .switchIssued
            issuedRecord.updatedAt = Date()
            try journalStore.write(issuedRecord)
            journalRecord = issuedRecord
            try await connection.send(.applyModelAdoptionRequest(
                transactionID: transactionID,
                requestedAtMs: requestedAtMs
            ))
            try? store.writeLastSwitchMs(requestedAtMs)
            while true {
                let frame = try await connection.receive()
                guard case let .modelAdoptionProgress(progress) = frame,
                      progress.transactionID == transactionID else {
                    continue
                }
                guard let state = SwitchProgressState(rawValue: progress.state) else {
                    throw ModelRuntimeAdoptionError.authorityMismatch
                }
                let authorityUnavailable = progress.targetModelID.isEmpty
                    && progress.targetArtifactPath.isEmpty
                    && progress.targetArtifactSHA256.isEmpty
                    && progress.targetCatalogRevision.isEmpty
                    && progress.serveKnobsSHA256.isEmpty
                    && progress.catalogIdentitySHA256.isEmpty
                if state == .failed, authorityUnavailable {
                    throw ModelRuntimeAdoptionError.runtimeRejected(progress.reason ?? "runtime rejected adoption")
                }
                guard Self.progressMatches(progress, authority: authority) else {
                    throw ModelRuntimeAdoptionError.authorityMismatch
                }
                let elapsedMs = progress.elapsedMS
                let reason = progress.reason
                phase = state == .draining ? "switch_draining" : "switch_loading"
                try event(type: "progress", phase: phase, cancellable: false, reason: reason)
                switch state {
                case .loaded:
                    guard progress.loadedModelID.map(modelIDKey) == modelIDKey(recommendation.targetModelID),
                          progress.loadedModelSHA256 == recommendation.core.modelArtifactSHA256 else {
                        throw ModelRuntimeAdoptionError.authorityMismatch
                    }
                    runtimeLoaded = true
                    await connection.close()
                    if var record = journalRecord {
                        record.phase = .runtimeCommitted
                        record.runtimeCommitObserved = true
                        record.rollbackState = .notNeeded
                        record.updatedAt = Date()
                        try journalStore.write(record)
                        journalRecord = record
                    }
                    phase = "config_verify"
                    try event(type: "progress", phase: phase, cancellable: false)
                    let (verifyConnection, verifiedStatus) = try await connectAndReadStatusOrExit(socketPath: socketPath)
                    await verifyConnection.close()
                    guard verifiedStatus.runtimeState == .ready,
                          modelIDKey(verifiedStatus.currentModelID) == modelIDKey(recommendation.targetModelID) else {
                        try fail("runtime_verify_failed", exitCode: 5, rollbackState: "rollback_failed")
                    }
                    guard Self.ensureConfigParity(
                        applier: applier,
                        configPath: configPath!,
                        recommendation: recommendation
                    ) else {
                        try fail("config_repair_failed", exitCode: 5, rollbackState: "rollback_failed")
                    }
                    let configSHA = try Self.sha256Hex(Data(contentsOf: configPath!))
                    if var record = journalRecord {
                        record.phase = .finalizePending
                        record.updatedAt = Date()
                        try journalStore.write(record)
                        journalRecord = record
                    }
                    guard await Self.finalizePreparedAdoption(
                        transactionID: transactionID,
                        socketPath: socketPath
                    ) else {
                        try fail("runtime_finalize_failed", exitCode: 5, rollbackState: "rollback_failed")
                    }
                    if let journalURL {
                        try journalStore.remove(journalURL)
                    }
                    try event(
                        type: "completed",
                        phase: nil,
                        cancellable: false,
                        configSHA256: configSHA,
                        backupPath: backupPath == nil ? nil : "redacted"
                    )
                    return
                case .failed:
                    await connection.close()
                    let rollback = Self.rollback(
                        applier: applier,
                        backupPath: backupPath,
                        journalRecord: journalRecord
                    )
                    let cleanupReady = Self.persistCancelPending(
                        record: &journalRecord,
                        rollback: rollback,
                        journalStore: journalStore
                    )
                    let cancelled = cleanupReady
                        ? await Self.cancelPreparedAdoption(
                            transactionID: transactionID,
                            socketPath: socketPath
                        )
                        : false
                    if cancelled, rollback == "rolled_back", let journalURL {
                        try? journalStore.remove(journalURL)
                    }
                    _ = elapsedMs
                    try fail(reason ?? "switch_failed", exitCode: 5, rollbackState: rollback)
                case .loading, .draining:
                    continue
                }
            }
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            await connection.close()
            let rollback: String
            if runtimeLoaded {
                rollback = "rollback_failed"
            } else if let recovered = try? await Self.runtimeMatches(
                targetModelID: recommendation.targetModelID,
                socketPath: socketPath
            ), recovered {
                runtimeLoaded = true
                guard Self.ensureConfigParity(
                    applier: applier,
                    configPath: configPath!,
                    recommendation: recommendation
                ) else {
                    try fail("config_repair_failed", exitCode: 5, rollbackState: "rollback_failed")
                }
                if var record = journalRecord {
                    record.phase = .runtimeCommitted
                    record.runtimeCommitObserved = true
                    record.rollbackState = .notNeeded
                    record.updatedAt = Date()
                    try journalStore.write(record)
                }
                let configSHA = try Self.sha256Hex(Data(contentsOf: configPath!))
                if var record = journalRecord {
                    record.phase = .finalizePending
                    record.updatedAt = Date()
                    try journalStore.write(record)
                    journalRecord = record
                }
                guard await Self.finalizePreparedAdoption(
                    transactionID: transactionID,
                    socketPath: socketPath
                ) else {
                    try fail("runtime_finalize_failed", exitCode: 5, rollbackState: "rollback_failed")
                }
                if let journalURL { try journalStore.remove(journalURL) }
                try event(
                    type: "completed",
                    configSHA256: configSHA,
                    backupPath: backupPath == nil ? nil : "redacted"
                )
                return
            } else {
                rollback = Self.rollback(
                    applier: applier,
                    backupPath: backupPath,
                    journalRecord: journalRecord
                )
                let cleanupReady = Self.persistCancelPending(
                    record: &journalRecord,
                    rollback: rollback,
                    journalStore: journalStore
                )
                let cancelled = cleanupReady
                    ? await Self.cancelPreparedAdoption(
                        transactionID: transactionID,
                        socketPath: socketPath
                    )
                    : false
                if cancelled, rollback == "rolled_back", let journalURL {
                    try? journalStore.remove(journalURL)
                }
            }
            try fail(
                runtimeLoaded ? "config_repair_failed" : "switch_transport_failed",
                exitCode: 5,
                rollbackState: rollback
            )
        }
    }
}

struct ModelsSwitchOptions: Sendable, Equatable {
    let force: Bool
    // Phase 1E reads/writes this path for the cooldown soft guard; Phase 1C only preserves it.
    let switchStatePath: String?
}

private struct ModelsStatus: Sendable, Equatable {
    let currentModelID: String
    let runtimeState: SwapState
}

private func loadModelsConfig(
    config: String?,
    model: String?,
    supportedModels: String?,
    ctlSocketPath: String?,
    switchStatePath: String? = nil
) throws -> AppConfig {
    try ConfigLoader.load(
        cli: CLIOverrides(
            model: model,
            configPath: config,
            supportedModels: SupportedModels.parseCSV(supportedModels),
            ctlSocketPath: ctlSocketPath,
            switchStatePath: switchStatePath
        )
    )
}

struct ParsedRecommendationAdoption {
    let targetModelID: String
    let core: RecommendationCore
    let donorMode: Bool
    let draftModel: String?
    let draftModelArtifactSHA256: String?
    let warnings: [String]
    let recommendationSHA256: String
    let rateCardVersion: String
    let demandRankVersion: String
    let candidateCatalogVersion: String
    let hardwareChip: String
    let hardwareMemoryGB: Int
    let hardwareBinaryVersion: String
}

extension ModelsAdoptRecommendationCommand {
    static func loadRecommendation(pathOrStdin: String) throws -> ParsedRecommendationAdoption {
        let data: Data
        if pathOrStdin == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: ConfigLoader.expandTilde(pathOrStdin)))
        }
        try AutotuneStrictJSON.rejectDuplicateKeys(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema_version"] as? String == "autotune_recommend.v1",
              let generatedAt = root["generated_at"] as? String,
              let generatedDate = parseRecommendationTimestamp(generatedAt),
              generatedDate <= Date().addingTimeInterval(60),
              Date().timeIntervalSince(generatedDate) <= 7 * 24 * 60 * 60,
              let recommendedModel = root["recommended_model"] as? String,
              let inputs = root["inputs"] as? [String: Any],
              let rateCardVersion = inputs["rate_card_version"] as? String,
              let demandRankVersion = inputs["demand_rank_version"] as? String,
              let candidateCatalogVersion = inputs["candidate_catalog_version"] as? String,
              let hardware = root["hardware"] as? [String: Any],
              let hardwareChip = hardware["chip"] as? String,
              let hardwareMemoryGB = strictRecommendationInt(hardware["memory_gb"]),
              let hardwareBinaryVersion = hardware["binary_version"] as? String,
              let serveConfig = root["serve_config"] as? [String: Any],
              let warnings = root["warnings"] as? [String],
              let candidates = root["candidates"] as? [[String: Any]],
              candidates.contains(where: {
                  $0["model"] as? String == recommendedModel && $0["eligible"] as? Bool == true
              })
        else {
            throw ValidationError("invalid autotune_recommend.v1 recommendation")
        }
        guard serveConfig["model"] as? String == recommendedModel else {
            throw ValidationError("recommendation target does not match serve_config.model")
        }
        let trustedStrings = [
            recommendedModel, rateCardVersion, demandRankVersion, candidateCatalogVersion,
            hardwareChip, hardwareBinaryVersion,
        ]
        guard trustedStrings.allSatisfy(isSafeConfigString) else {
            throw ValidationError("recommendation contains unsafe strings")
        }
        let allowedKeys = Set(ConfigApplier.recommendationOwnedKeys + [
            "draft_model",
            "draft_model_artifact_sha256",
        ])
        let unknownKeys = Set(serveConfig.keys).subtracting(allowedKeys)
        guard unknownKeys.isEmpty else {
            throw ValidationError("serve_config contains unsupported keys: \(unknownKeys.sorted().joined(separator: ", "))")
        }
        guard let artifactPath = serveConfig["model_artifact_path"] as? String,
              artifactPath.hasPrefix("/"),
              let artifactSHA = serveConfig["model_artifact_sha256"] as? String,
              isLowerHex(artifactSHA, count: 64),
              let catalogKey = serveConfig["model_catalog_key"] as? String,
              catalogKey == recommendedModel,
              let catalogModelID = serveConfig["model_catalog_model_id"] as? String,
              !catalogModelID.isEmpty,
              let catalogRevision = serveConfig["model_catalog_revision"] as? String,
              !catalogRevision.isEmpty,
              let catalogSHA = serveConfig["model_catalog_sha256"] as? String,
              isLowerHex(catalogSHA, count: 64),
              let catalogVersion = serveConfig["model_catalog_version"] as? String,
              !catalogVersion.isEmpty,
              let catalogHash = serveConfig["model_catalog_hash"] as? String,
              isLowerHex(catalogHash, count: 64),
              let maxContext = strictRecommendationInt(serveConfig["max_context_override"]),
              maxContext > 0,
              let maxBatch = strictRecommendationInt(serveConfig["max_concurrency_override"]),
              maxBatch > 0,
              let donorMode = serveConfig["donor_mode"] as? Bool
        else {
            throw ValidationError("serve_config is incomplete or invalid")
        }
        guard [artifactPath, catalogKey, catalogModelID, catalogRevision, catalogVersion]
            .allSatisfy(isSafeConfigString) else {
            throw ValidationError("serve_config contains unsafe strings")
        }
        if let value = serveConfig["kv_bits"], !(value is NSNull),
           strictRecommendationInt(value) == nil {
            throw ValidationError("serve_config.kv_bits is invalid")
        }
        for key in ["draft_model", "draft_model_artifact_sha256"] {
            if let value = serveConfig[key], !(value is NSNull), !(value is String) {
                throw ValidationError("serve_config.\(key) is invalid")
            }
        }
        let kvBits = strictRecommendationInt(serveConfig["kv_bits"])
        let core = RecommendationCore(
            model: recommendedModel,
            targetContext: maxContext,
            knobs: WinningKnobs(kvBits: kvBits, maxBatch: maxBatch, maxContext: maxContext),
            tpsMedian: 0,
            ttftP95MS: 0,
            replicates: 0,
            modelArtifactPath: artifactPath,
            modelArtifactSHA256: artifactSHA,
            modelCatalogKey: catalogKey,
            modelCatalogModelID: catalogModelID,
            modelCatalogRevision: catalogRevision,
            modelCatalogSHA256: catalogSHA,
            modelCatalogVersion: catalogVersion,
            modelCatalogHash: catalogHash
        )
        return ParsedRecommendationAdoption(
            targetModelID: recommendedModel,
            core: core,
            donorMode: donorMode,
            draftModel: serveConfig["draft_model"] as? String,
            draftModelArtifactSHA256: serveConfig["draft_model_artifact_sha256"] as? String,
            warnings: warnings,
            recommendationSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            rateCardVersion: rateCardVersion,
            demandRankVersion: demandRankVersion,
            candidateCatalogVersion: candidateCatalogVersion,
            hardwareChip: hardwareChip,
            hardwareMemoryGB: hardwareMemoryGB,
            hardwareBinaryVersion: hardwareBinaryVersion
        )
    }

    private static func strictRecommendationInt(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if type(of: value) == Bool.self {
            return nil
        }
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        if let intValue = value as? Int {
            return intValue
        }
        if let doubleValue = value as? Double,
           doubleValue.isFinite,
           doubleValue.rounded(.towardZero) == doubleValue,
           let exact = Int(exactly: doubleValue) {
            return exact
        }
        return nil
    }

    private static func isSafeConfigString(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 0x20 && $0 != 0x7F }
    }

    fileprivate static func validateSignedAuthority(
        _ recommendation: ParsedRecommendationAdoption,
        configPath: String? = nil
    ) async throws {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.processName.lowercased().contains("xctest") {
            return
        }
        #endif
        let inputs = await AutotuneStaticInputs().loadRecommendationInputs()
        let warnings = inputs.demand.warnings
            .union(inputs.candidate.warnings)
            .union(inputs.rateCard.warnings)
        guard !AutotuneRecommendEngine.paidTrustBlocks(warnings),
              recommendation.demandRankVersion == inputs.demand.value.version,
              recommendation.candidateCatalogVersion == inputs.candidate.value.version,
              recommendation.rateCardVersion == inputs.rateCard.value.version,
              recommendation.core.modelCatalogVersion == inputs.candidate.value.version,
              recommendation.core.modelCatalogHash == AutotuneStaticInputs.candidateCatalogSHA256(bytes: inputs.candidate.selectedBytes),
              let catalogKey = recommendation.core.modelCatalogKey,
              let row = inputs.candidate.value.rows[catalogKey] else {
            throw ValidationError("recommendation is not bound to the current signed catalog inputs")
        }
        try validateSignedCatalogBinding(recommendation: recommendation, catalogKey: catalogKey, row: row)
        let currentHardware = MachineFingerprinter().sample()
        guard recommendation.hardwareChip == currentHardware.chip,
              recommendation.hardwareMemoryGB == currentHardware.ramGB,
              recommendation.hardwareBinaryVersion == currentHardware.binaryVersion,
              recommendation.hardwareMemoryGB >= row.minRAMGB,
              BandwidthTier.derive(chip: currentHardware.chip).satisfies(minimum: row.minBandwidthTier) else {
            throw ValidationError("recommendation hardware or binary identity is stale")
        }
        let resolvedConfig = try? ConfigLoader.load(cli: CLIOverrides(configPath: configPath))
        let artifact = try CachedModelArtifactResolver.forConfig(resolvedConfig).verifiedExistingArtifact(for: row)
        guard artifact.sha256 == recommendation.core.modelArtifactSHA256 else {
            throw ValidationError("recommendation artifact authority does not match the signed snapshot")
        }
        if let recordedPath = recommendation.core.modelArtifactPath {
            let recorded = URL(fileURLWithPath: recordedPath).standardizedFileURL
            let loaded = URL(fileURLWithPath: artifact.modelArgument).standardizedFileURL
            if recorded != loaded, FileManager.default.fileExists(atPath: recorded.path) {
                let recordedHash = try ModelArtifactVerifier.canonicalArtifactHash(directory: recorded)
                guard recordedHash == artifact.sha256 else {
                    throw ValidationError("recommendation artifact authority does not match the signed snapshot")
                }
            }
        }
        try validateSignedContextAuthority(recommendation: recommendation, row: row, artifact: artifact)
    }

    static func validateSignedCatalogBinding(
        recommendation: ParsedRecommendationAdoption,
        catalogKey: String,
        row: CandidateCatalog.Row
    ) throws {
        guard let catalogModelID = recommendation.core.modelCatalogModelID,
              catalogKey == recommendation.targetModelID,
              row.runtimeStatus == "recommendable",
              row.modelID == catalogModelID,
              row.modelRevision == recommendation.core.modelCatalogRevision,
              row.modelSHA256 == recommendation.core.modelCatalogSHA256,
              row.modelSHA256 == recommendation.core.modelArtifactSHA256 else {
            throw ValidationError("recommendation is not bound to the current signed catalog inputs")
        }
    }

    static func validateSignedContextAuthority(
        recommendation: ParsedRecommendationAdoption,
        row: CandidateCatalog.Row,
        artifact: VerifiedModelArtifact
    ) throws {
        let hardware = AutotuneRecommendHardware(
            machine: nil,
            chip: recommendation.hardwareChip,
            memoryGB: recommendation.hardwareMemoryGB,
            bandwidthTier: BandwidthTier.derive(chip: recommendation.hardwareChip),
            osVersion: "",
            binaryVersion: recommendation.hardwareBinaryVersion,
            diversificationID: "",
            hardwareIdentityHash: ""
        )
        let expectedMaxContext = hardware.recommendedMaxContext(
            modelID: row.modelID,
            verifiedConfigJSONData: artifact.configJSONData,
            verifiedConfigSHA256: artifact.configSHA256,
            catalogMinRAMGB: row.minRAMGB
        )
        guard recommendation.core.knobs.maxContext == expectedMaxContext else {
            throw ValidationError("recommendation context authority does not match the verified model config")
        }
    }

    private static func parseRecommendationTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    fileprivate static func hasBlockingWarning(_ warnings: [String]) -> Bool {
        let blocking = Set([
            AutotuneRecommendWarning.swapObservedUnderLoad.rawValue,
            "buyer_ttft_ceiling_exceeded",
            "candidate_catalog_integrity_failure",
            "candidate_catalog_update_required",
            "demand_rank_integrity_failure",
            "demand_rank_update_required",
            "rate_card_integrity_failure",
            "rate_card_update_required",
            "thermal_throttle_detected",
            "thermal_throttled",
        ])
        return warnings.contains { blocking.contains($0) }
    }

    fileprivate static func rollback(
        applier: ConfigApplier,
        backupPath: URL?,
        journalRecord: RecommendationAdoptionJournalRecord? = nil
    ) -> String {
        do {
            let expected: [String: String]
            if let journalRecord {
                expected = try applier.restoreRecommendationOwnedFields(
                    journalRecord.recommendationOwnedFieldsBefore,
                    now: Date()
                )
            } else if let backupPath {
                expected = try applier.restoreRecommendationOwnedFields(from: backupPath, now: Date())
            } else {
                return "rollback_failed"
            }
            let restored = try applier.recommendationOwnedFieldValues()
            guard restored == expected else { return "rollback_failed" }
            return "rolled_back"
        } catch {
            return "rollback_failed"
        }
    }

    static func persistCancelPending(
        record: inout RecommendationAdoptionJournalRecord?,
        rollback: String,
        journalStore: RecommendationAdoptionJournalStore
    ) -> Bool {
        guard var pending = record else { return true }
        pending.phase = .cancelPending
        pending.runtimeCommitObserved = false
        pending.rollbackState = rollback == "rolled_back" ? .rolledBack : .rollbackFailed
        pending.updatedAt = Date()
        do {
            try journalStore.write(pending)
            record = pending
            return pending.rollbackState == .rolledBack
        } catch {
            return false
        }
    }

    fileprivate static func effectiveConfigURL(explicit: String?) -> URL {
        let path = explicit
            ?? ProcessInfo.processInfo.environment["MACPROVIDER_CONFIG"]
            ?? AppConfig.defaultConfigPath
        return URL(fileURLWithPath: ConfigLoader.expandTilde(path))
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    static func recoverPendingTransactions(
        store: RecommendationAdoptionJournalStore,
        configPath: URL,
        socketPath: URL,
        configLockTimeoutSeconds: TimeInterval = 60,
        recoveryClaim: ((String, String, String, URL) async throws -> (
            currentModelID: String,
            runtimeState: SwapState
        ))? = nil
    ) async throws {
        func claim(_ record: RecommendationAdoptionJournalRecord) async throws -> (
            currentModelID: String,
            runtimeState: SwapState
        ) {
            if let recoveryClaim {
                return try await recoveryClaim(
                    record.transactionID,
                    record.fromModelID,
                    record.targetModelID,
                    socketPath
                )
            }
            return try await claimAdoptionRecovery(
                transactionID: record.transactionID,
                fromModelID: record.fromModelID,
                targetModelID: record.targetModelID,
                socketPath: socketPath
            )
        }

        for (url, record) in try store.records(for: configPath) {
            if record.phase == .finalizePending,
               await finalizePreparedAdoption(
                   transactionID: record.transactionID,
                   socketPath: socketPath
               ) {
                try store.remove(url)
                continue
            }
            if record.phase == .cancelPending,
               record.rollbackState == .rolledBack,
               await cancelPreparedAdoption(
                   transactionID: record.transactionID,
                   socketPath: socketPath
               ) {
                try store.remove(url)
                continue
            }
            let initialStatus = try await claim(record)
            guard initialStatus.runtimeState == .ready else {
                throw RecommendationAdoptionJournalError.invalidJournal
            }
            do {
                let applier = ConfigApplier(configPath: configPath)
                let configLock = try applier.acquireRecommendationMutationLock(
                    timeoutSeconds: configLockTimeoutSeconds
                )
                let status = try await claim(record)
                guard status.runtimeState == .ready,
                      modelIDKey(status.currentModelID) == modelIDKey(initialStatus.currentModelID) else {
                    throw RecommendationAdoptionJournalError.invalidJournal
                }
                let mutationResult = try applier.withLockedRecommendationMutation(configLock) { mutation in
                    let snapshot = try mutation.snapshot()
                    let configMatchesTransaction = [
                        record.preApplyConfigSHA256,
                        record.postApplyConfigSHA256,
                    ].contains(snapshot.configSHA256) || [
                        record.recommendationOwnedFieldsBefore,
                        record.recommendationOwnedFieldsAfter,
                    ].contains(snapshot.values)
                    guard configMatchesTransaction else {
                        throw RecommendationAdoptionJournalError.invalidJournal
                    }
                    let expected: [String: String]
                    let runtimeCommitted: Bool
                    switch (record.phase, record.runtimeCommitObserved) {
                    case (.runtimeCommitted, true):
                        guard modelIDKey(status.currentModelID) == modelIDKey(record.targetModelID) else {
                            throw RecommendationAdoptionJournalError.invalidJournal
                        }
                        expected = record.recommendationOwnedFieldsAfter
                        runtimeCommitted = true
                    case (.finalizePending, true):
                        guard modelIDKey(status.currentModelID) == modelIDKey(record.targetModelID) else {
                            throw RecommendationAdoptionJournalError.invalidJournal
                        }
                        expected = record.recommendationOwnedFieldsAfter
                        runtimeCommitted = true
                    case (.switchIssued, false):
                        if modelIDKey(status.currentModelID) == modelIDKey(record.targetModelID) {
                            expected = record.recommendationOwnedFieldsAfter
                            runtimeCommitted = true
                        } else if modelIDKey(status.currentModelID) == modelIDKey(record.fromModelID) {
                            expected = record.recommendationOwnedFieldsBefore
                            runtimeCommitted = false
                        } else {
                            throw RecommendationAdoptionJournalError.invalidJournal
                        }
                    case (.configPrepared, false):
                        guard modelIDKey(status.currentModelID) == modelIDKey(record.fromModelID) else {
                            throw RecommendationAdoptionJournalError.invalidJournal
                        }
                        expected = record.recommendationOwnedFieldsBefore
                        runtimeCommitted = false
                    case (.cancelPending, false):
                        guard modelIDKey(status.currentModelID) == modelIDKey(record.fromModelID) else {
                            throw RecommendationAdoptionJournalError.invalidJournal
                        }
                        expected = record.recommendationOwnedFieldsBefore
                        runtimeCommitted = false
                    default:
                        throw RecommendationAdoptionJournalError.invalidJournal
                    }
                    _ = try mutation.restore(expected, now: Date())
                    guard try mutation.snapshot().values == expected else {
                        throw RecommendationAdoptionJournalError.invalidJournal
                    }
                    return (runtimeCommitted: runtimeCommitted, originalValues: snapshot.values)
                }
                do {
                    let confirmedStatus = try await claim(record)
                    guard confirmedStatus.runtimeState == .ready,
                          modelIDKey(confirmedStatus.currentModelID) == modelIDKey(status.currentModelID) else {
                        throw RecommendationAdoptionJournalError.invalidJournal
                    }
                } catch {
                    // The runtime reservation is a lease. If suspension or blocked
                    // I/O lets it expire after config repair, restore the exact
                    // pre-repair config while the cross-process lock is still held.
                    try applier.withLockedRecommendationMutation(configLock) { mutation in
                        _ = try mutation.restore(mutationResult.originalValues, now: Date())
                        guard try mutation.snapshot().values == mutationResult.originalValues else {
                            throw RecommendationAdoptionJournalError.invalidJournal
                        }
                    }
                    throw error
                }
                let runtimeCommitted = mutationResult.runtimeCommitted
                var cleanupRecord = record
                cleanupRecord.phase = runtimeCommitted ? .finalizePending : .cancelPending
                cleanupRecord.runtimeCommitObserved = runtimeCommitted
                cleanupRecord.rollbackState = runtimeCommitted ? .notNeeded : .rolledBack
                cleanupRecord.updatedAt = Date()
                try store.write(cleanupRecord)
                let cleanupAccepted: Bool
                if runtimeCommitted {
                    cleanupAccepted = await finalizePreparedAdoption(
                        transactionID: record.transactionID,
                        socketPath: socketPath
                    )
                } else {
                    cleanupAccepted = await cancelPreparedAdoption(
                        transactionID: record.transactionID,
                        socketPath: socketPath
                    )
                }
                guard cleanupAccepted else {
                    throw RecommendationAdoptionJournalError.invalidJournal
                }
                try store.remove(url)
                withExtendedLifetime(configLock) {}
            }
        }
    }

    fileprivate static func runtimeMatches(targetModelID: String, socketPath: URL) async throws -> Bool {
        let (connection, status) = try await connectAndReadStatus(socketPath: socketPath)
        await connection.close()
        return status.runtimeState == .ready
            && modelIDKey(status.currentModelID) == modelIDKey(targetModelID)
    }

    fileprivate static func cancelPreparedAdoption(
        connection: ControlSocketConnection,
        transactionID: String
    ) async -> Bool {
        do {
            try await connection.send(.cancelModelAdoptionRequest(
                transactionID: transactionID,
                requestedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))
            guard case let .cancelModelAdoptionResult(resultTransactionID, accepted, _) =
                try await connection.receive(timeout: 2)
            else { return false }
            return resultTransactionID == transactionID && accepted
        } catch {
            return false
        }
    }

    fileprivate static func cancelPreparedAdoption(
        transactionID: String,
        socketPath: URL
    ) async -> Bool {
        do {
            let connection = try await ControlSocketClient.connect(socketPath: socketPath)
            let accepted = await cancelPreparedAdoption(
                connection: connection,
                transactionID: transactionID
            )
            await connection.close()
            return accepted
        } catch {
            return false
        }
    }

    fileprivate static func finalizePreparedAdoption(
        transactionID: String,
        socketPath: URL
    ) async -> Bool {
        for _ in 0..<2 {
            do {
                let connection = try await ControlSocketClient.connect(socketPath: socketPath)
                do {
                    try await connection.send(.finalizeModelAdoptionRequest(
                        transactionID: transactionID,
                        requestedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
                    ))
                    guard case let .finalizeModelAdoptionResult(resultTransactionID, accepted, _) =
                        try await connection.receive(timeout: 2) else {
                        await connection.close()
                        continue
                    }
                    await connection.close()
                    if resultTransactionID == transactionID, accepted {
                        return true
                    }
                } catch {
                    await connection.close()
                }
            } catch {
                continue
            }
        }
        return false
    }

    fileprivate static func claimAdoptionRecovery(
        transactionID: String,
        fromModelID: String,
        targetModelID: String,
        socketPath: URL
    ) async throws -> (currentModelID: String, runtimeState: SwapState) {
        let connection = try await ControlSocketClient.connect(socketPath: socketPath)
        do {
            try await connection.send(.claimModelAdoptionRecoveryRequest(
                transactionID: transactionID,
                fromModelID: fromModelID,
                targetModelID: targetModelID,
                requestedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))
            guard case let .claimModelAdoptionRecoveryResult(
                resultTransactionID,
                accepted,
                _,
                currentModelID,
                runtimeState
            ) = try await connection.receive(timeout: 2),
                resultTransactionID == transactionID,
                accepted else {
                throw RecommendationAdoptionJournalError.invalidJournal
            }
            await connection.close()
            return (currentModelID, runtimeState)
        } catch {
            await connection.close()
            throw error
        }
    }

    fileprivate static func adoptionAuthority(
        transactionID: String,
        incumbentModelID: String,
        recommendation: ParsedRecommendationAdoption
    ) -> ModelAdoptionAuthorityWire {
        ModelAdoptionAuthorityWire(
            transactionID: transactionID,
            recommendationSHA256: recommendation.recommendationSHA256,
            expectedIncumbentModelID: incumbentModelID,
            targetModelID: recommendation.targetModelID,
            targetArtifactPath: recommendation.core.modelArtifactPath ?? "",
            targetArtifactSHA256: recommendation.core.modelArtifactSHA256 ?? "",
            targetCatalogRevision: recommendation.core.modelCatalogRevision ?? "",
            targetKVBits: recommendation.core.knobs.kvBits,
            targetMaxContext: recommendation.core.knobs.maxContext,
            targetMaxBatch: recommendation.core.knobs.maxBatch,
            targetDonorMode: recommendation.donorMode,
            serveKnobsSHA256: ModelAdoptionAuthorityWire.serveKnobsDigest(
                kvBits: recommendation.core.knobs.kvBits,
                maxContext: recommendation.core.knobs.maxContext,
                maxBatch: recommendation.core.knobs.maxBatch,
                donorMode: recommendation.donorMode
            ),
            catalogIdentitySHA256: hashFields([
                recommendation.core.modelCatalogKey ?? "",
                recommendation.core.modelCatalogModelID ?? "",
                recommendation.core.modelCatalogRevision ?? "",
                recommendation.core.modelCatalogSHA256 ?? "",
                recommendation.core.modelCatalogVersion ?? "",
                recommendation.core.modelCatalogHash ?? "",
            ])
        )
    }

    fileprivate static func preparationMatches(
        _ prepared: ModelAdoptionPrepareResultWire,
        authority: ModelAdoptionAuthorityWire
    ) -> Bool {
        prepared.transactionID == authority.transactionID
            && prepared.schemaVersion == "model_recommendation_apply_switch.v1"
            && prepared.targetModelID == authority.targetModelID
            && prepared.targetArtifactPath == authority.targetArtifactPath
            && prepared.targetArtifactSHA256 == authority.targetArtifactSHA256
            && prepared.targetCatalogRevision == authority.targetCatalogRevision
            && prepared.serveKnobsSHA256 == authority.serveKnobsSHA256
            && prepared.catalogIdentitySHA256 == authority.catalogIdentitySHA256
    }

    fileprivate static func progressMatches(
        _ progress: ModelAdoptionProgressWire,
        authority: ModelAdoptionAuthorityWire
    ) -> Bool {
        progress.transactionID == authority.transactionID
            && progress.schemaVersion == "model_recommendation_apply_switch.v1"
            && progress.targetModelID == authority.targetModelID
            && progress.targetArtifactPath == authority.targetArtifactPath
            && progress.targetArtifactSHA256 == authority.targetArtifactSHA256
            && progress.targetCatalogRevision == authority.targetCatalogRevision
            && progress.serveKnobsSHA256 == authority.serveKnobsSHA256
            && progress.catalogIdentitySHA256 == authority.catalogIdentitySHA256
    }

    private static func hashFields(_ fields: [String]) -> String {
        let data = fields.reduce(into: Data()) { partial, field in
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { partial.append(contentsOf: $0) }
            partial.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func switchRejectReason(_ reason: SwitchAckReason?) -> String {
        switch reason {
        case .loadingInProgress: return "loading_in_progress"
        case .cooldown: return "cooldown"
        case .notInSupportedModels: return "not_in_supported_models"
        case .other: return "switch_rejected"
        case .none: return "switch_rejected"
        }
    }

    fileprivate static func configOwnsRecommendation(
        loaded: AppConfig,
        recommendation: ParsedRecommendationAdoption
    ) -> Bool {
        loaded.model == recommendation.core.model
            && loaded.modelArtifactPath == recommendation.core.modelArtifactPath
            && loaded.modelArtifactSHA256 == recommendation.core.modelArtifactSHA256
            && loaded.modelCatalogKey == recommendation.core.modelCatalogKey
            && loaded.modelCatalogModelID == recommendation.core.modelCatalogModelID
            && loaded.modelCatalogRevision == recommendation.core.modelCatalogRevision
            && loaded.modelCatalogSHA256 == recommendation.core.modelCatalogSHA256
            && loaded.modelCatalogVersion == recommendation.core.modelCatalogVersion
            && loaded.modelCatalogHash == recommendation.core.modelCatalogHash
            && loaded.kvBitsOverride == recommendation.core.knobs.kvBits
            && loaded.maxContextOverride == recommendation.core.knobs.maxContext
            && loaded.maxConcurrencyOverride == recommendation.core.knobs.maxBatch
            && loaded.donorMode == recommendation.donorMode
    }

    fileprivate static func ensureConfigParity(
        applier: ConfigApplier,
        configPath: URL,
        recommendation: ParsedRecommendationAdoption
    ) -> Bool {
        func matches() -> Bool {
            guard let loaded = try? ConfigLoader.load(cli: CLIOverrides(configPath: configPath.path)) else {
                return false
            }
            return modelIDKey(loaded.model ?? "") == modelIDKey(recommendation.targetModelID)
                && configOwnsRecommendation(loaded: loaded, recommendation: recommendation)
        }
        if matches() { return true }
        do {
            _ = try applier.apply(
                recommendation: recommendation.core,
                now: Date(),
                donorMode: recommendation.donorMode
            )
            return matches()
        } catch {
            return false
        }
    }

    fileprivate static func sha256Hex(_ data: Data) throws -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func connectAndReadStatusOrExit(socketPath: URL) async throws -> (ControlSocketConnection, ModelsStatus) {
    do {
        return try await connectAndReadStatus(socketPath: socketPath)
    } catch ControlSocketConnectError.socketAbsent(let path) {
        writeStderr("malibu-cli serve is not running on this host (no control socket at \(path))")
        throw ExitCode(4)
    } catch ControlSocketConnectError.connectionRefused(let path) {
        writeStderr("stale control socket at \(path) (no listener); remove the file and restart serve")
        throw ExitCode(4)
    } catch ControlSocketConnectError.handshakeTimeout {
        writeStderr("serve is running but warm-swap is not enabled (or serve is unresponsive); restart serve with --enable-warm-swap")
        throw ExitCode(4)
    }
}

private func connectAndReadStatus(socketPath: URL) async throws -> (ControlSocketConnection, ModelsStatus) {
    let connection = try await ControlSocketClient.connect(socketPath: socketPath)
    try await connection.send(.statusRequest)
    do {
        let frame = try await connection.receive(timeout: 2.0)
        guard case let .statusResponse(currentModelID, runtimeState) = frame else {
            await connection.close()
            throw ControlSocketConnectError.handshakeTimeout(path: socketPath.path)
        }
        return (connection, ModelsStatus(currentModelID: currentModelID, runtimeState: runtimeState))
    } catch ControlSocketConnectionError.timedOut {
        await connection.close()
        throw ControlSocketConnectError.handshakeTimeout(path: socketPath.path)
    }
}

private func idleCatalog(from config: AppConfig) -> [String] {
    if let supportedModels = config.supportedModels, !supportedModels.isEmpty {
        return supportedModels
    }
    if let model = config.model {
        return [model]
    }
    return []
}

private func printModelsTable(currentModelID: String?, supportedModels: [String]) {
    print("model_id\tstate")
    var rows: [String] = []
    var seen = Set<String>()
    for modelID in supportedModels where seen.insert(modelIDKey(modelID)).inserted {
        rows.append(modelID)
    }
    if let currentModelID, !rows.contains(where: { modelIDKey($0) == modelIDKey(currentModelID) }) {
        rows.insert(currentModelID, at: 0)
    }
    for modelID in rows {
        let state = currentModelID.map { modelIDKey(modelID) == modelIDKey($0) } == true ? "warm" : "idle"
        print("\(modelID)\t\(state)")
    }
}

private func modelIDKey(_ modelID: String) -> String {
    modelID.lowercased(with: nil)
}

private func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

private enum ModelsListWireError: Error {
    case invalidModelID
}

private func emitJSONList(
    currentModelID: String?,
    supportedModels: [String],
    source: String,
    warmSwapAvailable: Bool,
    authorizedModelIDs: Set<String>? = nil,
    artifactResolver: CachedModelArtifactResolver = CachedModelArtifactResolver()
) async throws {
    do {
        let document = try await makeModelsListWire(
            currentModelID: currentModelID,
            supportedModels: supportedModels,
            source: source,
            warmSwapAvailable: warmSwapAvailable,
            authorizedModelIDs: authorizedModelIDs,
            artifactResolver: artifactResolver
        )
        try ModelSwitchingWireCodec.printJSON(document)
    } catch {
        try ModelSwitchingWireCodec.printJSON(ModelCatalogErrorWire(
            command: "models list",
            code: "invalid_argument",
            message: "The provider returned an invalid model identifier."
        ))
        throw ExitCode(2)
    }
}

private func makeModelsListWire(
    currentModelID: String?,
    supportedModels: [String],
    source: String,
    warmSwapAvailable: Bool,
    authorizedModelIDs: Set<String>? = nil,
    artifactResolver: CachedModelArtifactResolver = CachedModelArtifactResolver()
) async throws -> ModelsListWire {
    var effectiveModels = supportedModels
    if let currentModelID {
        let currentKey = modelIDKey(currentModelID)
        if let index = effectiveModels.firstIndex(where: { modelIDKey($0) == currentKey }) {
            // Preserve the authoritative runtime spelling for the warm row.
            effectiveModels[index] = currentModelID
        } else {
            effectiveModels.insert(currentModelID, at: 0)
        }
    }
    var seen = Set<String>()
    var rows: [ModelsListWire.Row] = []
    for modelID in effectiveModels {
        guard ModelSwitchingWireCodec.safeID(modelID) else { throw ModelsListWireError.invalidModelID }
        guard seen.insert(modelIDKey(modelID)).inserted else { continue }
        let state = currentModelID.map { modelIDKey(modelID) == modelIDKey($0) } == true ? "warm" : "idle"
        let verdict = ModelFit.evaluate(modelID: modelID, ramGB: ModelFit.detectRAMGB())
        let estimate = ModelFit.estimateWeightSizeGB(modelID: modelID).map(Double.init)
        let weightsPresent: Bool
        if state == "warm" {
            weightsPresent = true
        } else if let authorizedModelIDs {
            // A running serve process owns the authoritative target inventory.
            // Never re-probe the cache here: a post-start artifact change must
            // not make Malibu advertise a target the runtime cannot switch to.
            weightsPresent = warmSwapAvailable && authorizedModelIDs.contains(modelIDKey(modelID))
        } else {
            weightsPresent = exactLocalArtifactPresent(modelID: modelID, artifactResolver: artifactResolver)
        }
        rows.append(ModelsListWire.Row(
            modelID: modelID,
            displayID: modelID,
            actionModelID: modelID,
            state: state,
            weightsPresentLocally: weightsPresent,
            source: source == "control_socket" ? (state == "warm" ? "status_response" : "supported_models") : "config_fallback",
            fit: ModelSwitchingWireCodec.fitLabel(verdict),
            estimatedGB: estimate
        ))
    }
    return ModelsListWire(
        generatedAt: ModelSwitchingWireCodec.timestamp(),
        source: source,
        warmSwapAvailable: warmSwapAvailable,
        currentModelID: currentModelID,
        rows: rows
    )
}

private func exactLocalArtifactPresent(
    modelID: String,
    artifactResolver: CachedModelArtifactResolver
) -> Bool {
    // A plain directory is insufficient evidence: the runtime requires the
    // signed catalog revision and canonical artifact hash. Unknown rows stay
    // false so Malibu cannot promote an idle partial/stale cache to Ready.
    let baked = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
    let targetKey = modelIDKey(modelID)
    guard let catalog = try? AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(baked),
          let row = catalog.rows.first(where: {
              modelIDKey($0.key) == targetKey || modelIDKey($0.value.modelID) == targetKey
          })?.value,
          row.modelRevision != nil,
          row.modelSHA256 != nil else {
        return false
    }
    return (try? artifactResolver.verifiedExistingArtifact(for: row)) != nil
}
