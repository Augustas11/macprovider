import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacProviderCore

/// `provider context` (#1689 part 3): explain, change, and roll back the serve
/// context window without editing YAML. It lives beside `provider verify`
/// because `--apply` and `rollback` finish by running that verification.
struct ProviderContextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Explain, change, or roll back this Mac's context window without editing YAML.",
        subcommands: [ProviderContextExplainCommand.self, ProviderContextSetCommand.self, ProviderContextRollbackCommand.self]
    )
}

struct ProviderContextExplainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Show the effective context window, where it came from, its limits, and whether it fits in memory."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Local HTTP port to query. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    func run() async throws {
        print(try await ProviderContextWorkflow.live(configPath: config, port: port, timeout: 0).explain())
    }
}

struct ProviderContextSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set the context window in config.yaml, backing up the previous config first.",
        discussion: "With --apply, restarts the installed provider service and waits until this Mac, the network, and the public feed agree; --apply is refused when --config or --port names another provider. Undo with `provider context rollback`."
    )

    @Argument(help: "Context window in tokens.")
    var tokens: Int

    @Flag(help: "Check bounds, memory fit, and competing processes. Without --apply nothing is written.")
    var preflight = false

    @Flag(help: "Restart the provider after writing, then verify the change end to end.")
    var apply = false

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Local HTTP port to query. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    @Option(help: "Seconds to wait for verification after --apply.")
    var timeout: Int = 180

    func validate() throws {
        try ProviderVerifyCommand.validateTimeout(timeout)
    }

    func run() async throws {
        let outcome = try await ProviderContextWorkflow.live(configPath: config, port: port, timeout: TimeInterval(timeout))
            .set(tokens: tokens, preflight: preflight, apply: apply)
        print(outcome.text)
        if outcome.exitCode != 0 {
            throw ExitCode(outcome.exitCode)
        }
    }
}

struct ProviderContextRollbackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Restore the settings from the newest config backup, restart the provider, and verify.",
        discussion: "The replaced config is saved as a new backup first, so running rollback again undoes the rollback. The restart applies only to the installed provider service; for another config use --no-restart and restart that provider yourself."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Local HTTP port to query. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    @Option(help: "Seconds to wait for verification after the restart.")
    var timeout: Int = 180

    @Flag(help: "Restore the config only; do not restart the provider.")
    var noRestart = false

    func validate() throws {
        try ProviderVerifyCommand.validateTimeout(timeout)
    }

    func run() async throws {
        let outcome = try await ProviderContextWorkflow.live(configPath: config, port: port, timeout: TimeInterval(timeout))
            .rollback(restart: !noRestart)
        print(outcome.text)
        if outcome.exitCode != 0 {
            throw ExitCode(outcome.exitCode)
        }
    }
}

struct ProviderContextWorkflow {
    struct ModelFacts: Equatable {
        var declaredMax: Int?
        var tokenizerMax: Int?
        var kvBytesPerToken: Int?
        var weightsBytes: UInt64?

        var limit: Int? { [declaredMax, tokenizerMax].compactMap { $0 }.min() }
    }

    struct MemoryEstimate: Equatable {
        var kvBytes: UInt64
        var availableBytes: UInt64
        var weightsBytes: UInt64
        var fits: Bool { kvBytes <= availableBytes }
    }

    struct Outcome: Equatable {
        var text: String
        var exitCode: Int32
    }

    /// The config and port the installed launchd provider job serves, the
    /// only provider `--apply` and `rollback` may restart (#1689 F3), and the
    /// launchd domain (`gui/<uid>` or `system`) its plist was found in.
    struct InstalledService: Equatable {
        var domain: String
        var configPath: String
        var port: Int

        var target: String { "\(domain)/\(CredentialRestartProver.launchdLabel)" }
        var summary: String { "\(target) (config \(configPath), port \(port))" }
    }

    enum InstalledServiceLookup: Equatable {
        case none
        case found(InstalledService)
        /// Both a LaunchAgent and a LaunchDaemon exist and launchd does not
        /// say which one runs: either both or neither is loaded.
        case ambiguous([InstalledService])

        var service: InstalledService? {
            if case let .found(service) = self { return service }
            return nil
        }

        var summary: String {
            switch self {
            case .none:
                return "none found (no readable \(CredentialRestartProver.launchdLabel) serve job in gui/<uid> or system)"
            case let .found(service):
                return service.summary
            case let .ambiguous(services):
                return "ambiguous: " + services.map(\.summary).joined(separator: " and ")
            }
        }
    }

    /// Reads the job's `ProgramArguments` (`serve [--config <path>]
    /// [--port <n>]`) and `EnvironmentVariables`, then resolves the port the
    /// way serve would from that config and environment. Nil when the plist
    /// is unreadable, is not a serve job, or its config cannot be loaded.
    static func installedService(plistData: Data, domain: String) -> InstalledService? {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.dropFirst().first == "serve" else {
            return nil
        }
        let environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        func value(of flag: String) -> String? {
            for (index, argument) in arguments.enumerated() {
                if argument == flag, index + 1 < arguments.count { return arguments[index + 1] }
                if argument.hasPrefix(flag + "=") { return String(argument.dropFirst(flag.count + 1)) }
            }
            return nil
        }
        let configPath = value(of: "--config")
            ?? environment["MACPROVIDER_CONFIG"]
            ?? AppConfig.defaultConfigPath
        let portFlag = value(of: "--port").flatMap { Int($0) }
        guard let config = try? ConfigLoader.load(
            cli: CLIOverrides(port: portFlag, configPath: configPath),
            environment: environment
        ) else {
            return nil
        }
        return InstalledService(domain: domain, configPath: config.configPath, port: config.port)
    }

    /// Finds the installed provider job by where its plist actually is, not
    /// by the config's credential store: a GUI install can use a
    /// `protected_file` config (#1689 round 2). A job counts when its plist
    /// parses as a serve job; when both domains have one, the one launchd has
    /// loaded wins, and otherwise the lookup is ambiguous.
    static func detectInstalledService(
        uid: uid_t,
        launchAgentsDirectory: URL,
        launchDaemonsDirectory: URL,
        isLoaded: (_ target: String) -> Bool
    ) -> InstalledServiceLookup {
        let plistName = "\(CredentialRestartProver.launchdLabel).plist"
        let candidates = [
            ("gui/\(uid)", launchAgentsDirectory.appendingPathComponent(plistName)),
            ("system", launchDaemonsDirectory.appendingPathComponent(plistName)),
        ]
        let services = candidates.compactMap { domain, plist in
            (try? Data(contentsOf: plist)).flatMap { installedService(plistData: $0, domain: domain) }
        }
        guard services.count > 1 else {
            return services.first.map(InstalledServiceLookup.found) ?? .none
        }
        let loaded = services.filter { isLoaded($0.target) }
        return loaded.count == 1 ? .found(loaded[0]) : .ambiguous(services)
    }

    static func liveInstalledService() -> InstalledServiceLookup {
        detectInstalledService(
            uid: getuid(),
            launchAgentsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            launchDaemonsDirectory: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
            isLoaded: launchdJobIsLoaded
        )
    }

    /// `launchctl print <domain>/<label>` exits 0 only for a loaded job; it
    /// needs no privileges for the system domain.
    static func launchdJobIsLoaded(_ target: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    var configPath: String
    var port: Int
    var physicalMemoryGB: Int
    var fetchStatus: () async -> [String: Any]?
    var modelFacts: (_ artifactPath: String?) -> ModelFacts
    var processes: () -> [(pid: Int32, argv: [String])]
    var listenerPIDs: () -> [Int]
    var restart: (_ service: InstalledService) throws -> Void
    var verify: (_ expected: ProviderVerifier.ExpectedContext) async -> ProviderVerifyReport
    var installedService: () -> InstalledServiceLookup
    var now: () -> Date = Date.init
    var environment: [String: String] = [:]

    private static let gib: UInt64 = 1 << 30

    static func live(configPath: String?, port: Int?, timeout: TimeInterval) throws -> ProviderContextWorkflow {
        let resolved = try ConfigLoader.load(cli: CLIOverrides(port: port, configPath: configPath))
        let environment = ProcessInfo.processInfo.environment
        return ProviderContextWorkflow(
            configPath: resolved.configPath,
            port: resolved.port,
            physicalMemoryGB: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil).ramGB,
            fetchStatus: { try? await LocalStatusClient.fetch(port: resolved.port) },
            modelFacts: { liveModelFacts(artifactPath: $0) },
            processes: { (try? ProviderConflictDetector.defaultProcessList()) ?? [] },
            listenerPIDs: { liveListenerPIDs(port: resolved.port) },
            restart: { try CredentialRestartProver.restartLaunchdProvider(domain: $0.domain) },
            verify: { expected in
                await ProviderVerifier(
                    port: resolved.port,
                    coordinatorURL: resolved.coordinatorURL,
                    timeout: timeout,
                    expectedContext: expected
                ).run()
            },
            installedService: { liveInstalledService() },
            environment: environment
        )
    }

    // MARK: explain

    func explain() async -> String {
        let config = loadConfig()
        let status = await fetchStatus()
        let capacity = status?["capacity"] as? [String: Any]
        let servedModel = status?["model"] as? String
        let facts = modelFacts(Self.servedModelArtifactPath(modelID: servedModel, config: config))
        let ramDefault = ProviderCapacity.defaultContextTokens(forPhysicalMemoryGB: physicalMemoryGB)
        let effective = (capacity?["max_context_tokens"] as? NSNumber)?.intValue
            ?? config?.maxContextOverride
            ?? ramDefault
        let sourceRaw = capacity?["max_context_source"] as? String
            ?? config?.maxContextSource?.rawValue
            ?? MaxContextSource.ramTierDefault.rawValue
        let slots = concurrency(status: status, config: config)
        let provenance = config?.maxContextProvenance

        var lines = ["Context window"]
        lines.append("  Effective:    \(effective) tokens (source: \(LocalStatusFormatter.maxContextSourceLabel(sourceRaw)))")
        if let configured = config?.maxContextOverride {
            if config?.maxContextSource == .recommendationApply, let entry = provenance {
                lines.append("  Config file:  max_context_override \(configured), written by an autotune recommendation for \(entry.model)\(entry.generatedAt.map { " at \($0)" } ?? "")\(entry.benchmarkID.map { " (benchmark \($0))" } ?? "")")
            } else {
                lines.append("  Config file:  max_context_override \(configured), set by the operator")
            }
        } else {
            lines.append("  Config file:  max_context_override not set")
        }
        if let shellValue = environment["MACPROVIDER_MAX_CONTEXT_OVERRIDE"],
           !shellValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("  This shell:   sets MACPROVIDER_MAX_CONTEXT_OVERRIDE=\(shellValue); the launchd service does not inherit it")
        }
        lines.append("  RAM default:  \(ramDefault) tokens for \(physicalMemoryGB) GB")
        let draftLimit = ProviderCapacity.draftModelContextLimit(physicalMemoryGB: physicalMemoryGB, draftModel: config?.draftModel)
        if let draftLimit {
            lines.append("  Draft cap:    \(draftLimit) tokens (draft_model is configured; serve refuses a larger max_context_override)")
        }
        if let declared = facts.declaredMax {
            lines.append("  Model limit:  \(declared) tokens (config.json\(facts.tokenizerMax.map { "; tokenizer \($0)" } ?? ""))")
        } else if let tokenizer = facts.tokenizerMax {
            lines.append("  Model limit:  \(tokenizer) tokens (tokenizer)")
        } else {
            lines.append("  Model limit:  unknown (no readable model config.json)")
        }
        lines.append("  Slots:        \(slots)")
        lines.append("  KV memory:    \(memoryLine(context: effective, slots: slots, facts: facts))")
        if let status {
            let connected = (status["coordinator"] as? [String: Any])?["connected"] as? Bool == true
            let advertised = (capacity?["max_context_tokens"] as? NSNumber)?.intValue
            lines.append("  Advertised:   \(advertised.map(String.init) ?? "<unknown>") tokens to the network (\(connected ? "connected" : "not connected"))")
        } else {
            lines.append("  Advertised:   not reported (the provider is not running on port \(port))")
        }
        if let warning = Self.underUseWarning(
            effective: effective,
            supported: Self.supportedContext(ramDefault: ramDefault, facts: facts, draftLimit: draftLimit)
        ) {
            lines.append(warning)
        }
        if let warning = Self.aboveModelLimitWarning(
            effective: effective,
            declaredMax: facts.declaredMax,
            model: servedModel ?? config?.model ?? "the configured model"
        ) {
            lines.append(warning)
        }
        if config?.maxContextSource == .recommendationApply,
           let generatedFor = provenance?.model,
           let model = config?.model,
           generatedFor != model {
            lines.append("Warning: this value was generated for \(generatedFor), but \(model) is configured now. Re-run `malibu-cli autotune --recommend --apply` or set it with `malibu-cli provider context set`.")
        }
        lines.append("  Installed:    \(installedService().summary)")
        lines.append(contentsOf: resourceCheck())
        return lines.joined(separator: "\n")
    }

    /// What this Mac and model support without a memory estimate:
    /// `min(RAM-tier default, model limit, draft cap when a draft model is
    /// configured)`.
    static func supportedContext(ramDefault: Int, facts: ModelFacts, draftLimit: Int?) -> Int {
        [ramDefault, facts.limit, draftLimit].compactMap { $0 }.min() ?? ramDefault
    }

    /// F6: a context above the served model's declared maximum is served
    /// and advertised as set; operator surfaces say so and never change it.
    static func aboveModelLimitWarning(effective: Int, declaredMax: Int?, model: String) -> String? {
        guard let declaredMax, effective > declaredMax else { return nil }
        return "Warning: the context window (\(effective) tokens) is above \(model)'s declared maximum of \(declaredMax) tokens; requests longer than that may fail or degrade. It was not changed. To lower it: malibu-cli provider context set \(max(declaredMax, AutotuneModelContextCap.minimumServeContext)) --preflight"
    }

    /// The context lines `status --advanced` adds from the running
    /// provider's capacity, the config file, and the served model's local
    /// `config.json` facts: above the declared maximum, a generated value
    /// serve lowered to fit its slots (SPEC-023-R018 item 9), or a context ×
    /// slots KV estimate that does not fit memory.
    static func statusContextWarnings(status: [String: Any], config: AppConfig?, physicalMemoryGB: Int, facts: ModelFacts) -> [String] {
        let capacity = status["capacity"] as? [String: Any] ?? [:]
        guard let effective = (capacity["max_context_tokens"] as? NSNumber)?.intValue, effective > 0 else { return [] }
        let slots = (capacity["max_concurrency"] as? NSNumber)?.intValue ?? 1
        let model = status["model"] as? String ?? "the served model"
        var warnings: [String] = []
        if let warning = aboveModelLimitWarning(effective: effective, declaredMax: facts.declaredMax, model: model) {
            warnings.append(warning)
        }
        if capacity["max_context_source"] as? String == MaxContextSource.recommendationApply.rawValue,
           config?.maxContextSource == .recommendationApply,
           let configured = config?.maxContextOverride,
           effective < configured {
            warnings.append("Context lowered from \(configured) to \(effective) tokens so \(slots) slots fit in memory (config.yaml keeps the recommendation's \(configured); if config.yaml changed after serve started, restart to apply it).")
        } else if let estimate = memoryEstimate(physicalMemoryGB: physicalMemoryGB, context: effective, slots: slots, facts: facts),
                  !estimate.fits {
            warnings.append("Warning: \(describe(estimate, context: effective, slots: slots)). Lower the context (malibu-cli provider context set) or the slot count.")
        }
        // SPEC-023-R018 item 9: serve lowers a generated pair's slot count
        // only when even the minimum context does not fit the configured one,
        // so it is served at or below that minimum (a smaller --max-batch
        // at a larger context is the operator's choice, not a lowering).
        if effective <= AutotuneModelContextCap.minimumServeContext,
           let source = capacity["max_context_source"] as? String,
           source == MaxContextSource.recommendationApply.rawValue
            || source == MaxContextSource.recommendationAdoption.rawValue,
           config?.maxContextSource == .recommendationApply,
           let configuredSlots = config?.maxConcurrencyOverride,
           slots < configuredSlots {
            warnings.append("Slots lowered from \(configuredSlots) to \(slots): even the \(AutotuneModelContextCap.minimumServeContext)-token minimum context does not fit \(configuredSlots) slots of this model in memory (config.yaml keeps \(configuredSlots)).")
        }
        return warnings
    }

    /// The local directory holding the model a provider serves: the
    /// configured artifact for the configured model, else the signed-catalog
    /// row's durable copy, else its Hugging Face snapshot. Nil for a model
    /// outside the signed catalog.
    static func servedModelArtifactPath(modelID: String?, config: AppConfig?) -> String? {
        guard let modelID else { return config?.modelArtifactPath }
        let key = modelID.lowercased()
        let configuredIDs = [config?.model, config?.modelCatalogModelID, config?.modelCatalogKey]
            .compactMap { $0?.lowercased() }
        if configuredIDs.contains(key) {
            return config?.modelArtifactPath
        }
        guard let catalog = try? AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(
            Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        ),
            let entry = catalog.rows.first(where: {
                $0.key.lowercased() == key || $0.value.modelID.lowercased() == key
            }),
            let revision = entry.value.modelRevision,
            let sha256 = entry.value.modelSHA256 else {
            return nil
        }
        let resolver = CachedModelArtifactResolver.forConfig(config)
        let durable = (try? resolver.durableStore.artifactURL(modelID: entry.value.modelID, revision: revision, sha256: sha256))
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        return (durable ?? resolver.snapshotURL(modelID: entry.value.modelID, revision: revision)).path
    }

    static func underUseWarning(effective: Int, supported: Int) -> String? {
        guard effective * 2 < supported else { return nil }
        return "Warning: this cap is well below what this Mac and model support (\(supported) tokens). To change it: malibu-cli provider context set \(supported) --preflight"
    }

    // MARK: set

    /// How many times a context change re-runs its preflight when config.yaml
    /// changes between the preflight and the locked write.
    static let mutationAttempts = 3

    func set(tokens: Int, preflight: Bool, apply: Bool) async throws -> Outcome {
        let minimum = AutotuneModelContextCap.minimumServeContext
        let maximum = AutotuneModelContextCap.maximumAcceptedContext
        guard (minimum...maximum).contains(tokens) else {
            return Outcome(text: "Refused: context must be between \(minimum) and \(maximum) tokens.", exitCode: 1)
        }
        var service: InstalledService?
        if apply {
            switch restartTarget(action: "--apply", alternative: "Run it again without --apply") {
            case let .success(found): service = found
            case let .failure(refusal): return Outcome(text: refusal.reason, exitCode: 1)
            }
        }
        let liveSlots = ((await fetchStatus())?["capacity"] as? [String: Any])?["max_concurrency"] as? NSNumber
        let applier = applier()
        for _ in 0..<Self.mutationAttempts {
            // The model inspection runs outside the lock; the locked write
            // re-checks the fields it depends on and validates the exact
            // config it writes.
            let currentText = try applier.currentConfigText()
            let prospectiveText = try applier.settingOperatorOwnedValue(key: "max_context_override", value: String(tokens), in: currentText)
            let facts = modelFacts(fileConfig(prospectiveText)?.modelArtifactPath)
            var lines = resourceCheck()
            switch check(prospectiveText, facts: facts) {
            case .refused(let reason):
                return Outcome(text: (lines + [reason]).joined(separator: "\n"), exitCode: 1)
            case .accepted(let checked):
                lines += checked
            }
            if let liveSlots, let fileSlots = fileSlotCount(prospectiveText), liveSlots.intValue != fileSlots {
                lines.append("Slots: the running provider uses \(liveSlots.intValue); after a restart it uses \(fileSlots) (\(slotOrigin(prospectiveText))), which is what the memory check counts.")
            }
            if preflight && !apply {
                lines.append("Preflight passed. Nothing was written; run again without --preflight to write it.")
                return Outcome(text: lines.joined(separator: "\n"), exitCode: 0)
            }
            let fingerprint = Self.contextFingerprint(fileConfig(currentText))
            let backup: URL
            do {
                backup = try applier.setOperatorOwnedValue(key: "max_context_override", value: String(tokens), now: now()) { lockedText, updatedText in
                    try requireUnchanged(lockedText, fingerprint: fingerprint, facts: facts, prospectiveText: updatedText)
                }
            } catch is ContextConfigChanged {
                continue
            } catch let refusal as ContextRefusal {
                return Outcome(text: (lines + [refusal.reason]).joined(separator: "\n"), exitCode: 1)
            }
            lines.append("Wrote max_context_override: \(tokens) to \(expandedConfigPath) (previous config saved at \(backup.path)).")
            guard let service else {
                lines.append("Restart the provider to use it, or run again with --apply.")
                return Outcome(text: lines.joined(separator: "\n"), exitCode: 0)
            }
            return await restartAndVerify(
                service,
                expected: .init(tokens: tokens, source: nil),
                lines: lines,
                undoHint: "To undo this change: malibu-cli provider context rollback"
            )
        }
        return Outcome(text: Self.keptChangingRefusal, exitCode: 1)
    }

    // MARK: rollback

    func rollback(restart: Bool = true) async throws -> Outcome {
        var service: InstalledService?
        if restart {
            switch restartTarget(
                action: "rollback",
                alternative: "Run `malibu-cli provider context rollback --no-restart --config \(ModelCatalogPreparation.shellWord(expandedConfigPath)) --port \(port)`"
            ) {
            case let .success(found): service = found
            case let .failure(refusal): return Outcome(text: refusal.reason, exitCode: 1)
            }
        }
        let applier = applier()
        for _ in 0..<Self.mutationAttempts {
            let preview = try applier.rollbackPreview()
            let facts = modelFacts(fileConfig(preview.restoredText)?.modelArtifactPath)
            if case .refused(let reason) = check(preview.restoredText, facts: facts) {
                return Outcome(text: "Cannot roll back to \(preview.backup.path):\n\(reason)", exitCode: 1)
            }
            let fingerprint = Self.contextFingerprint(fileConfig(preview.currentText))
            let restoredFingerprint = Self.contextFingerprint(fileConfig(preview.restoredText))
            let result: (restoredFrom: URL, savedCurrentAs: URL)
            do {
                result = try applier.rollbackToNewestBackup(now: now()) { lockedText, backup, restoredText in
                    guard backup == preview.backup,
                          Self.contextFingerprint(fileConfig(restoredText)) == restoredFingerprint else {
                        throw ContextConfigChanged()
                    }
                    try requireUnchanged(lockedText, fingerprint: fingerprint, facts: facts, prospectiveText: restoredText)
                }
            } catch is ContextConfigChanged {
                continue
            } catch let refusal as ContextRefusal {
                return Outcome(text: "Cannot roll back to \(preview.backup.path):\n\(refusal.reason)", exitCode: 1)
            }
            var lines = [
                "Restored settings from \(result.restoredFrom.path); the replaced config was saved at \(result.savedCurrentAs.path).",
            ]
            guard let service else {
                lines.append("Not restarted. Restart the provider that uses \(expandedConfigPath), then run: \(verifyCommand)")
                return Outcome(text: lines.joined(separator: "\n"), exitCode: 0)
            }
            return await restartAndVerify(
                service,
                expected: expectedAfterRollback(),
                lines: lines,
                undoHint: "To undo the rollback, run `malibu-cli provider context rollback` again."
            )
        }
        return Outcome(text: Self.keptChangingRefusal, exitCode: 1)
    }

    /// What serve runs after the rollback: the restored override, else the
    /// default serve resolves for a config without one.
    func expectedAfterRollback() -> ProviderVerifier.ExpectedContext {
        let config = loadConfig()
        if let override = config?.maxContextOverride {
            return .init(tokens: override, source: nil)
        }
        let draft = ProviderCapacity.servedDraftModel(configured: config?.draftModel) != nil
        let unset = ProviderCapacity.unsetOverrideContext(physicalMemoryGB: physicalMemoryGB, draftModelConfigured: draft)
        return .init(tokens: unset.tokens, source: unset.source)
    }

    // MARK: prospective config check

    private struct ContextConfigChanged: Error {}

    private struct ContextRefusal: Error {
        var reason: String
    }

    static let keptChangingRefusal = "Refused: config.yaml kept changing while this command checked it (\(mutationAttempts) attempts). Nothing was written; run the command again."

    enum ProspectiveCheck: Equatable {
        case accepted([String])
        case refused(String)
    }

    /// The fields a context check depends on, from the config file alone:
    /// model and artifact identity (the model facts), slots, draft model, and
    /// the context with its provenance.
    static func contextFingerprint(_ config: AppConfig?) -> [String] {
        guard let config else { return ["<unloadable>"] }
        return [
            config.model,
            config.modelArtifactPath,
            config.modelArtifactSHA256,
            config.modelCatalogKey,
            config.modelCatalogModelID,
            config.modelCatalogRevision,
            config.modelCatalogSHA256,
            config.modelCatalogHash,
            config.maxConcurrencyOverride.map(String.init),
            config.draftModel,
            config.maxContextOverride.map(String.init),
            config.maxContextProvenance?.yamlFlowValue,
        ].map { $0 ?? "<unset>" }
    }

    /// Under the config lock: refuses to write unless the fields the
    /// preflight's model facts came from are unchanged, then validates the
    /// complete config about to be written.
    private func requireUnchanged(_ lockedText: String, fingerprint: [String], facts: ModelFacts, prospectiveText: String) throws {
        guard Self.contextFingerprint(fileConfig(lockedText)) == fingerprint else {
            throw ContextConfigChanged()
        }
        if case .refused(let reason) = check(prospectiveText, facts: facts) {
            throw ContextRefusal(reason: reason)
        }
    }

    /// Validates a complete config as serve would load it after a restart
    /// (SPEC-001 FR-20b): the model limit, the draft cap and draft slot limit
    /// for the draft model in that file, and the KV cache for the file's
    /// slot count, never the running provider's.
    func check(_ text: String, facts: ModelFacts) -> ProspectiveCheck {
        let draftModel: String?
        do {
            draftModel = try ProviderCapacity.servedDraftModel(configText: text, configPath: expandedConfigPath)
        } catch {
            return .refused("Refused: \(error). Nothing was written.")
        }
        guard let config = fileConfig(text) else {
            return .refused("Refused: serve could not load the resulting \(expandedConfigPath). Nothing was written.")
        }
        if draftModel != nil, let slots = config.maxConcurrencyOverride, slots > 1 {
            return .refused("Refused: max_concurrency_override \(slots) with a draft model configured; serve would refuse to start (draft_model_capacity_shortfall). Nothing was written.")
        }
        guard let tokens = config.maxContextOverride else {
            // No override: serve resolves its own default, which it never refuses.
            return .accepted([])
        }
        if let limit = facts.limit, tokens > limit {
            return .refused("Refused: \(tokens) is above this model's limit of \(limit) tokens.")
        }
        if let draftLimit = ProviderCapacity.draftModelContextLimit(physicalMemoryGB: physicalMemoryGB, draftModel: draftModel),
           tokens > draftLimit {
            return .refused("Refused: \(tokens) is above the \(draftLimit)-token limit for this Mac with a draft model configured; serve would refuse to start (draft_model_capacity_shortfall). Nothing was written.")
        }
        let slots = fileSlotCount(text) ?? 1
        guard let estimate = memoryEstimate(context: tokens, slots: slots, facts: facts) else {
            return .accepted(["Memory: \(memoryLine(context: tokens, slots: slots, facts: facts)); continuing without a memory check"])
        }
        let line = "Memory: \(describe(estimate, context: tokens, slots: slots))"
        guard estimate.fits else {
            return .refused("\(line)\nRefused: lower the context or the slot count. Nothing was written.")
        }
        return .accepted([line])
    }

    /// The slot count serve runs with after a restart from this config: one
    /// with a draft model, else serve's own resolution
    /// (`max_concurrency_override`, else 1).
    private func fileSlotCount(_ text: String) -> Int? {
        guard let config = fileConfig(text) else { return nil }
        if ProviderCapacity.servedDraftModel(configured: config.draftModel) != nil { return 1 }
        return ProviderCapacity.servedSlotCount(maxConcurrencyOverride: config.maxConcurrencyOverride)
    }

    private func slotOrigin(_ text: String) -> String {
        guard let config = fileConfig(text) else { return "from config.yaml" }
        if ProviderCapacity.servedDraftModel(configured: config.draftModel) != nil { return "one slot with a draft model" }
        return config.maxConcurrencyOverride == nil
            ? "serve's default without max_concurrency_override"
            : "max_concurrency_override in config.yaml"
    }

    /// `text` loaded as serve loads config.yaml, without this shell's
    /// environment (the launchd service does not inherit it).
    private func fileConfig(_ text: String) -> AppConfig? {
        try? ConfigLoader.load(
            cli: CLIOverrides(configPath: expandedConfigPath),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in text }
        )
    }

    // MARK: resource check

    /// Lists competing provider processes and duplicate listeners. It only
    /// suggests; it never stops a process.
    func resourceCheck() -> [String] {
        let serve = processes()
            .filter { ProviderConflictDetector.isForegroundServe(argv: $0.argv) }
            .map { Int($0.pid) }
            .sorted()
        let listeners = Array(Set(listenerPIDs())).sorted()
        // A serve listening on the queried port is the provider being checked.
        let others = serve.filter { !listeners.contains($0) }
        var lines: [String] = []
        if !others.isEmpty {
            // Other serves may be separate providers on other ports and
            // configs, so they are listed, not called extra.
            lines.append("Resource check: other serve processes on this Mac: pids \(others.map(String.init).joined(separator: ", ")). The KV-memory estimate does not count their memory.")
        }
        if listeners.count > 1 {
            lines.append("Resource check: more than one process listens on port \(port) (pids \(listeners.map(String.init).joined(separator: ", "))). Stop the extra one yourself; this command never stops processes.")
        }
        if lines.isEmpty {
            lines.append("Resource check: \(serve.count) provider process(es), \(listeners.count) listener(s) on port \(port)")
        }
        return lines
    }

    // MARK: helpers

    private var expandedConfigPath: String { ConfigLoader.expandTilde(configPath) }

    private var verifyCommand: String {
        "malibu-cli provider verify --config \(ModelCatalogPreparation.shellWord(expandedConfigPath)) --port \(port)"
    }

    /// Restarting kicks the installed launchd job in the domain it was found
    /// in, so it is allowed only when that job serves this config (compared
    /// after resolving symlinks) on this port; otherwise the restart would hit
    /// another provider.
    private func restartTarget(action: String, alternative: String) -> Result<InstalledService, ContextRefusal> {
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: ConfigLoader.expandTilde(path)).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let lookup = installedService()
        let reason: String
        switch lookup {
        case let .found(service):
            if canonical(service.configPath) == canonical(expandedConfigPath), service.port == port {
                return .success(service)
            }
            reason = "the installed service \(service.target) runs \(service.configPath) on port \(service.port); this config is \(expandedConfigPath) on port \(port), so restarting it would restart another provider"
        case .none:
            reason = "installed provider service \(lookup.summary), so there is no service to restart"
        case .ambiguous:
            reason = "installed provider service is \(lookup.summary), and launchd does not say which one runs"
        }
        return .failure(ContextRefusal(reason: "Refused \(action): \(reason). Nothing was written. \(alternative), restart the provider that uses this config yourself, then run: \(verifyCommand)"))
    }

    private func applier() -> ConfigApplier {
        ConfigApplier(configPath: URL(fileURLWithPath: expandedConfigPath))
    }

    /// The config file alone. The launchd service `restart` kicks does not
    /// inherit this shell's environment, so a shell override is neither the
    /// file's value nor what serve resolves after a restart; `explain` shows it
    /// as a separate line.
    private func loadConfig() -> AppConfig? {
        try? ConfigLoader.load(cli: CLIOverrides(configPath: configPath), environment: [:])
    }

    private func concurrency(status: [String: Any]?, config: AppConfig?) -> Int {
        ((status?["capacity"] as? [String: Any])?["max_concurrency"] as? NSNumber)?.intValue
            ?? ProviderCapacity.servedSlotCount(maxConcurrencyOverride: config?.maxConcurrencyOverride)
    }

    private func restartAndVerify(_ service: InstalledService, expected: ProviderVerifier.ExpectedContext, lines: [String], undoHint: String) async -> Outcome {
        var lines = lines
        do {
            try restart(service)
        } catch {
            lines.append("Restart failed: \(error). The config change is written; restart the provider yourself, then run `malibu-cli provider verify`.")
            return Outcome(text: lines.joined(separator: "\n"), exitCode: 1)
        }
        lines.append("Restarted the provider; waiting for this Mac, the network, and the public feed to agree.")
        let report = await verify(expected)
        lines.append(ProviderVerifyFormatter.text(report))
        if report.exitCode != 0 {
            lines.append(undoHint)
        }
        return Outcome(text: lines.joined(separator: "\n"), exitCode: report.exitCode)
    }

    /// Same envelope as the recommend memory cap: three quarters of the RAM
    /// left after the weights and the safety reserve holds the KV cache.
    func memoryEstimate(context: Int, slots: Int, facts: ModelFacts) -> MemoryEstimate? {
        Self.memoryEstimate(physicalMemoryGB: physicalMemoryGB, context: context, slots: slots, facts: facts)
    }

    static func memoryEstimate(physicalMemoryGB: Int, context: Int, slots: Int, facts: ModelFacts) -> MemoryEstimate? {
        guard let bytesPerToken = facts.kvBytesPerToken, let weights = facts.weightsBytes,
              context > 0, slots > 0 else {
            return nil
        }
        let ram = UInt64(physicalMemoryGB) * gib
        let reserved = weights + UInt64(AutotuneRecommendEngine.safetyMarginGB) * gib
        let available = ram > reserved ? (ram - reserved) / 4 * 3 : 0
        let perSlot = UInt64(bytesPerToken).multipliedReportingOverflow(by: UInt64(context))
        let total = perSlot.partialValue.multipliedReportingOverflow(by: UInt64(slots))
        let kv = perSlot.overflow || total.overflow ? UInt64.max : total.partialValue
        return MemoryEstimate(kvBytes: kv, availableBytes: available, weightsBytes: weights)
    }

    private func memoryLine(context: Int, slots: Int, facts: ModelFacts) -> String {
        if let estimate = memoryEstimate(context: context, slots: slots, facts: facts) {
            return describe(estimate, context: context, slots: slots)
        }
        return facts.kvBytesPerToken == nil
            ? "cannot estimate (model attention geometry unknown)"
            : "cannot estimate (model weight size unknown)"
    }

    private func describe(_ estimate: MemoryEstimate, context: Int, slots: Int) -> String {
        Self.describe(estimate, context: context, slots: slots)
    }

    private static func describe(_ estimate: MemoryEstimate, context: Int, slots: Int) -> String {
        "about \(gibText(estimate.kvBytes)) GiB of KV cache for \(slots) slots × \(context) tokens; about \(gibText(estimate.availableBytes)) GiB available after \(gibText(estimate.weightsBytes)) GiB of weights and a \(AutotuneRecommendEngine.safetyMarginGB) GB reserve (\(estimate.fits ? "fits" : "does not fit"))"
    }

    private static func gibText(_ bytes: UInt64) -> String {
        bytes == UInt64.max ? "∞" : String(format: "%.1f", Double(bytes) / Double(gib))
    }

    static func liveModelFacts(artifactPath: String?) -> ModelFacts {
        guard let artifactPath else { return ModelFacts() }
        let directory = URL(fileURLWithPath: ConfigLoader.expandTilde(artifactPath), isDirectory: true)
        var facts = ModelFacts()
        if let config = try? Data(contentsOf: directory.appendingPathComponent("config.json")) {
            facts.declaredMax = AutotuneModelContextCap.declaredMaxContextTokens(configData: config)
            facts.kvBytesPerToken = AutotuneModelContextCap.kvCacheBytesPerToken(configData: config)
        }
        if let tokenizer = try? Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json")),
           let object = try? JSONSerialization.jsonObject(with: tokenizer) as? [String: Any],
           let value = (object["model_max_length"] as? NSNumber)?.doubleValue,
           value >= 1, value <= Double(AutotuneModelContextCap.maximumAcceptedContext) {
            // Tokenizers without a real limit publish a 1e30 sentinel; it is ignored.
            facts.tokenizerMax = Int(value)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let weights = names.filter { $0.hasSuffix(".safetensors") }.compactMap { name -> UInt64? in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return (attributes?[.size] as? NSNumber)?.uint64Value
        }
        facts.weightsBytes = weights.isEmpty ? nil : weights.reduce(0, +)
        return facts
    }

    static func liveListenerPIDs(port: Int) -> [Int] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: { $0 == "\n" || $0 == " " })
                .compactMap { Int($0) }
        } catch {
            return []
        }
    }
}

/// What a model switch does to `max_context_override` (#1689, SPEC-001
/// FR-20b). A value a recommendation generated follows the served model: the
/// switch target gets the context recomputed for it with the same function
/// `autotune --recommend` uses. An operator-owned value (CLI flag,
/// environment, or a config value its `max_context_override_provenance` does
/// not mark generated) is kept, with a warning when it is under half of what the target
/// supports.
enum ModelSwitchContext: Equatable {
    /// No override: the RAM-tier default applies to every model.
    case unset
    /// The context to serve for the target: the recorded value for the model
    /// it was generated for, else the value recomputed for the target.
    case generated(Int)
    case operatorOwned(warning: String?)

    static func decide(
        config: AppConfig,
        targetModelIDs: [String],
        recomputedContext: Int,
        supportedContext: Int
    ) -> ModelSwitchContext {
        guard let configured = config.maxContextOverride else { return .unset }
        guard config.maxContextSource == .recommendationApply,
              let entry = config.maxContextProvenance,
              entry.generatedMaxContext(configured) else {
            return .operatorOwned(warning: ProviderContextWorkflow.underUseWarning(
                effective: configured,
                supported: supportedContext
            ))
        }
        let generatedFor = entry.model.lowercased()
        let sameModel = targetModelIDs.contains { $0.lowercased() == generatedFor }
        return .generated(sameModel ? configured : recomputedContext)
    }

    /// `min(RAM-tier default, declared model max, memory-safe context, draft
    /// cap when a draft model is configured)`, the value `autotune --recommend`
    /// writes for this model on this Mac, lowered further when the configured
    /// `slots` full-context KV caches would not fit memory at it (SPEC-023-R018
    /// item 9). The context of `recomputedServeKnobs`.
    static func recomputedContext(
        memoryGB: Int,
        modelID: String,
        catalogMinRAMGB: Int,
        configJSONData: Data?,
        configSHA256: String?,
        draftModel: String?,
        slots: Int
    ) -> Int {
        recomputedServeKnobs(
            memoryGB: memoryGB,
            modelID: modelID,
            catalogMinRAMGB: catalogMinRAMGB,
            configJSONData: configJSONData,
            configSHA256: configSHA256,
            draftModel: draftModel,
            slots: slots
        ).context
    }

    /// The (context, slots) pair a warm switch serves for a target: the
    /// recomputed context, bounded jointly with `slots` (SPEC-023-R018 item 9).
    /// `slots` is kept unless even the 4000-token floor does not fit it; then
    /// the floor is served with the slot count that fits there.
    static func recomputedServeKnobs(
        memoryGB: Int,
        modelID: String,
        catalogMinRAMGB: Int,
        configJSONData: Data?,
        configSHA256: String?,
        draftModel: String?,
        slots: Int
    ) -> (context: Int, slots: Int) {
        let context = AutotuneRecommendHardware(
            machine: nil,
            chip: "",
            memoryGB: memoryGB,
            bandwidthTier: .c,
            osVersion: "",
            binaryVersion: "",
            diversificationID: "",
            hardwareIdentityHash: ""
        ).recommendedMaxContext(
            modelID: modelID,
            verifiedConfigJSONData: configJSONData,
            verifiedConfigSHA256: configSHA256,
            catalogMinRAMGB: catalogMinRAMGB,
            draftModel: draftModel
        )
        return AutotuneModelContextCap.memoryBoundedServePair(
            context: context,
            slots: slots,
            verifiedConfigJSONData: configJSONData,
            verifiedConfigSHA256: configSHA256,
            hardwareMemoryGB: memoryGB,
            catalogMinRAMGB: catalogMinRAMGB
        )
    }

    /// The lowercased ids of the model a generated value's provenance record
    /// names: the recorded id plus every other id of the same model (the
    /// configured model's alias, a target's catalog ids). A warm switch serves
    /// `recommendation_apply` only for these; empty for an operator value.
    static func provenanceModelIDs(
        config: AppConfig,
        configuredModelIDs: [String],
        targets: [(ids: [String], recomputed: Int)]
    ) -> Set<String> {
        guard config.maxContextSource == .recommendationApply,
              let entry = config.maxContextProvenance,
              entry.generatedMaxContext(config.maxContextOverride) else {
            return []
        }
        let named = entry.model.lowercased()
        var ids: Set<String> = [named]
        for group in [configuredModelIDs] + targets.map(\.ids)
        where group.contains(where: { $0.lowercased() == named }) {
            ids.formUnion(group.map { $0.lowercased() })
        }
        return ids
    }

    /// SPEC-023-R018 item 9 at serve start: a recommendation-generated
    /// context lowered to the largest one at which the slot count serve runs
    /// (after `--max-batch` and the environment) fits the same memory
    /// envelope as the recommend path, with the configured model's verified
    /// `config.json`. When even the 4000-token floor does not fit those slots,
    /// the context is the floor and the slot count comes down to what fits.
    /// Nil when nothing changes: an operator-owned value (kept;
    /// `status --advanced` warns), unknown geometry, or slots that already fit.
    static func startupBoundedContext(
        config: AppConfig,
        slots: Int,
        memoryGB: Int,
        configJSONData: Data?,
        catalogMinRAMGB: Int?
    ) -> (context: Int, slots: Int)? {
        guard config.maxContextSource == .recommendationApply,
              let configured = config.maxContextOverride,
              let configJSONData,
              let catalogMinRAMGB else {
            return nil
        }
        let bounded = AutotuneModelContextCap.memoryBoundedServePair(
            context: configured,
            slots: slots,
            verifiedConfigJSONData: configJSONData,
            verifiedConfigSHA256: SHA256.hash(data: configJSONData).map { String(format: "%02x", $0) }.joined(),
            hardwareMemoryGB: memoryGB,
            catalogMinRAMGB: catalogMinRAMGB
        )
        return bounded.context < configured || bounded.slots < slots ? bounded : nil
    }

    /// The per-target contexts `serve` applies on a warm switch, keyed by
    /// lowercased model id. Empty unless the configured value is generated, so
    /// an operator value is served unchanged for every model.
    static func serveContextsByTarget(
        config: AppConfig,
        configuredModelIDs: [String],
        targets: [(ids: [String], recomputed: Int)],
        configuredContext: Int? = nil
    ) -> [String: Int] {
        guard let configured = config.maxContextOverride,
              case .generated = decide(
                  config: config,
                  targetModelIDs: configuredModelIDs,
                  recomputedContext: configured,
                  supportedContext: configured
              ) else {
            return [:]
        }
        var contexts: [String: Int] = [:]
        for target in targets {
            let decision = decide(
                config: config,
                targetModelIDs: target.ids,
                recomputedContext: target.recomputed,
                supportedContext: target.recomputed
            )
            guard case .generated(let value) = decision else { continue }
            for id in target.ids { contexts[id.lowercased()] = value }
        }
        // The configured model always returns to the configured value, or to
        // the value serve lowered it to at start so its slots fit.
        for id in configuredModelIDs { contexts[id.lowercased()] = configuredContext ?? configured }
        return contexts
    }

    /// The per-target slot counts `serve` applies on a warm switch, keyed like
    /// `serveContextsByTarget` and empty under the same condition. A target's
    /// count is below `configuredSlots` only when even the 4000-token floor
    /// does not fit it (SPEC-023-R018 item 9); the configured model returns to
    /// `configuredSlots`, the count serve runs after its own start bound.
    static func serveSlotsByTarget(
        config: AppConfig,
        configuredModelIDs: [String],
        targets: [(ids: [String], slots: Int)],
        configuredSlots: Int
    ) -> [String: Int] {
        guard let configured = config.maxContextOverride,
              case .generated = decide(
                  config: config,
                  targetModelIDs: configuredModelIDs,
                  recomputedContext: configured,
                  supportedContext: configured
              ) else {
            return [:]
        }
        var slotsByTarget: [String: Int] = [:]
        for target in targets {
            // Mirrors `decide`: the model the provenance record names serves
            // the configured value, so it keeps the configured slot count.
            let generatedFor = config.maxContextProvenance?.model.lowercased()
            let slots = target.ids.contains { $0.lowercased() == generatedFor } ? configuredSlots : target.slots
            for id in target.ids { slotsByTarget[id.lowercased()] = slots }
        }
        for id in configuredModelIDs { slotsByTarget[id.lowercased()] = configuredSlots }
        return slotsByTarget
    }
}
