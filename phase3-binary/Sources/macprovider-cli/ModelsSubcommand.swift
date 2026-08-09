import ArgumentParser
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

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock.")
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
                    authorizedModelIDs: Set(authorizedModelIDs.map(modelIDKey))
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
                    warmSwapAvailable: false
                )
            } else {
                print("serve not running; warm-swap disabled")
                printModelsTable(currentModelID: nil, supportedModels: models)
            }
            writeStderr("macprovider-cli serve is not running on this host (no control socket at \(path))")
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

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock.")
    var ctlSocketPath: String?

    @Option(help: "CLI-side cooldown state file. Overrides MACPROVIDER_SWITCH_STATE_PATH and config switch_state_path. Default $HOME/Library/Application Support/macprovider-cli/last-switch.ts.")
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
                try reject("provider is already loading \(currentTarget); refusing to start a second swap. Wait for current switch to complete (macprovider-cli models status)", code: "loading_in_progress", exitCode: 3)
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

    @Option(help: "Control socket path override. Overrides MACPROVIDER_CTL_SOCKET_PATH and config ctl_socket_path. Default $TMPDIR/macprovider-cli/ctl.sock.")
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

private func connectAndReadStatusOrExit(socketPath: URL) async throws -> (ControlSocketConnection, ModelsStatus) {
    do {
        return try await connectAndReadStatus(socketPath: socketPath)
    } catch ControlSocketConnectError.socketAbsent(let path) {
        writeStderr("macprovider-cli serve is not running on this host (no control socket at \(path))")
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
    authorizedModelIDs: Set<String>? = nil
) async throws {
    do {
        let document = try await makeModelsListWire(
            currentModelID: currentModelID,
            supportedModels: supportedModels,
            source: source,
            warmSwapAvailable: warmSwapAvailable,
            authorizedModelIDs: authorizedModelIDs
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
    authorizedModelIDs: Set<String>? = nil
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
            weightsPresent = exactLocalArtifactPresent(modelID: modelID)
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

private func exactLocalArtifactPresent(modelID: String) -> Bool {
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
    return (try? CachedModelArtifactResolver().verifiedExistingArtifact(for: row)) != nil
}
