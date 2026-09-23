import ArgumentParser
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
        discussion: "With --apply, restarts the provider and waits until this Mac, the network, and the public feed agree. Undo with `provider context rollback`."
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
        discussion: "The replaced config is saved as a new backup first, so running rollback again undoes the rollback."
    )

    @Option(help: "YAML config path. Overrides MACPROVIDER_CONFIG. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Local HTTP port to query. Overrides MACPROVIDER_PORT and config file port.")
    var port: Int?

    @Option(help: "Seconds to wait for verification after the restart.")
    var timeout: Int = 180

    func validate() throws {
        try ProviderVerifyCommand.validateTimeout(timeout)
    }

    func run() async throws {
        let outcome = try await ProviderContextWorkflow.live(configPath: config, port: port, timeout: TimeInterval(timeout))
            .rollback()
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

    var configPath: String
    var port: Int
    var physicalMemoryGB: Int
    var fetchStatus: () async -> [String: Any]?
    var modelFacts: () -> ModelFacts
    var processes: () -> [(pid: Int32, argv: [String])]
    var listenerPIDs: () -> [Int]
    var restart: () throws -> Void
    var verify: (_ expected: ProviderVerifier.ExpectedContext) async -> ProviderVerifyReport
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
            modelFacts: { liveModelFacts(artifactPath: resolved.modelArtifactPath) },
            processes: { (try? ProviderConflictDetector.defaultProcessList()) ?? [] },
            listenerPIDs: { liveListenerPIDs(port: resolved.port) },
            restart: { try CredentialRestartProver.restartLaunchdProvider(config: resolved) },
            verify: { expected in
                await ProviderVerifier(
                    port: resolved.port,
                    coordinatorURL: resolved.coordinatorURL,
                    timeout: timeout,
                    expectedContext: expected
                ).run()
            },
            environment: environment
        )
    }

    // MARK: explain

    func explain() async -> String {
        let config = loadConfig()
        let status = await fetchStatus()
        let capacity = status?["capacity"] as? [String: Any]
        let facts = modelFacts()
        let ramDefault = ProviderCapacity.defaultContextTokens(forPhysicalMemoryGB: physicalMemoryGB)
        let effective = (capacity?["max_context_tokens"] as? NSNumber)?.intValue
            ?? config?.maxContextOverride
            ?? ramDefault
        let sourceRaw = capacity?["max_context_source"] as? String
            ?? config?.maxContextSource?.rawValue
            ?? MaxContextSource.ramTierDefault.rawValue
        let slots = concurrency(status: status, config: config)
        let provenance = KnobProvenance.load(configPath: expandedConfigPath) { try String(contentsOfFile: $0, encoding: .utf8) }

        var lines = ["Context window"]
        lines.append("  Effective:    \(effective) tokens (source: \(LocalStatusFormatter.maxContextSourceLabel(sourceRaw)))")
        if let configured = config?.maxContextOverride {
            if config?.maxContextSource == .recommendationApply, let entry = provenance?.maxContextOverride {
                lines.append("  Config file:  max_context_override \(configured), written by an autotune recommendation for \(entry.model ?? "<unknown>") at \(entry.generatedAt)\(entry.benchmarkID.map { " (benchmark \($0))" } ?? "")")
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
        let supported = [ramDefault, facts.limit, draftLimit].compactMap { $0 }.min() ?? ramDefault
        if effective * 2 < supported {
            lines.append("Warning: this cap is well below what this Mac and model support (\(supported) tokens). To change it: malibu-cli provider context set \(supported) --preflight")
        }
        if config?.maxContextSource == .recommendationApply,
           let generatedFor = provenance?.maxContextOverride?.model,
           let model = config?.model,
           generatedFor != model {
            lines.append("Warning: this value was generated for \(generatedFor), but \(model) is configured now. Re-run `malibu-cli autotune --recommend --apply` or set it with `malibu-cli provider context set`.")
        }
        lines.append(contentsOf: resourceCheck())
        return lines.joined(separator: "\n")
    }

    // MARK: set

    func set(tokens: Int, preflight: Bool, apply: Bool) async throws -> Outcome {
        let minimum = AutotuneModelContextCap.minimumServeContext
        let maximum = AutotuneModelContextCap.maximumAcceptedContext
        guard (minimum...maximum).contains(tokens) else {
            return Outcome(text: "Refused: context must be between \(minimum) and \(maximum) tokens.", exitCode: 1)
        }
        let facts = modelFacts()
        if let limit = facts.limit, tokens > limit {
            return Outcome(text: "Refused: \(tokens) is above this model's limit of \(limit) tokens.", exitCode: 1)
        }
        let config = loadConfig()
        if let draftLimit = ProviderCapacity.draftModelContextLimit(physicalMemoryGB: physicalMemoryGB, draftModel: config?.draftModel),
           tokens > draftLimit {
            return Outcome(
                text: "Refused: \(tokens) is above the \(draftLimit)-token limit for this Mac with a draft model configured; serve would refuse to start (draft_model_capacity_shortfall). Nothing was written.",
                exitCode: 1
            )
        }
        let slots = concurrency(status: await fetchStatus(), config: config)
        var lines = resourceCheck()
        if let estimate = memoryEstimate(context: tokens, slots: slots, facts: facts) {
            lines.append("Memory: \(describe(estimate, context: tokens, slots: slots))")
            guard estimate.fits else {
                lines.append("Refused: lower the context or the slot count. Nothing was written.")
                return Outcome(text: lines.joined(separator: "\n"), exitCode: 1)
            }
        } else {
            lines.append("Memory: \(memoryLine(context: tokens, slots: slots, facts: facts)); continuing without a memory check")
        }
        if preflight && !apply {
            lines.append("Preflight passed. Nothing was written; run again without --preflight to write it.")
            return Outcome(text: lines.joined(separator: "\n"), exitCode: 0)
        }
        let backup = try applier().setOperatorOwnedValue(key: "max_context_override", value: String(tokens), now: now())
        lines.append("Wrote max_context_override: \(tokens) to \(expandedConfigPath) (previous config saved at \(backup.path)).")
        guard apply else {
            lines.append("Restart the provider to use it, or run again with --apply.")
            return Outcome(text: lines.joined(separator: "\n"), exitCode: 0)
        }
        return await restartAndVerify(
            expected: .init(tokens: tokens, source: nil),
            lines: lines,
            undoHint: "To undo this change: malibu-cli provider context rollback"
        )
    }

    // MARK: rollback

    func rollback() async throws -> Outcome {
        let applier = applier()
        let result = try applier.rollbackToNewestBackup(now: now())
        let lines = [
            "Restored settings from \(result.restoredFrom.path); the replaced config was saved at \(result.savedCurrentAs.path).",
        ]
        return await restartAndVerify(
            expected: expectedAfterRollback(),
            lines: lines,
            undoHint: "To undo the rollback, run `malibu-cli provider context rollback` again."
        )
    }

    /// What serve runs after the rollback: the restored override, else the
    /// default serve resolves for a config without one.
    func expectedAfterRollback() -> ProviderVerifier.ExpectedContext {
        let config = loadConfig()
        if let override = config?.maxContextOverride {
            return .init(tokens: override, source: nil)
        }
        let draft = config?.draftModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let unset = ProviderCapacity.unsetOverrideContext(physicalMemoryGB: physicalMemoryGB, draftModelConfigured: draft)
        return .init(tokens: unset.tokens, source: unset.source)
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
        var lines: [String] = []
        if serve.count > 1 {
            lines.append("Resource check: more than one provider process is running (pids \(serve.map(String.init).joined(separator: ", "))). Stop the extra one yourself; this command never stops processes.")
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
            ?? config?.maxConcurrencyOverride
            ?? ProviderCapacity.defaults(forPhysicalMemoryGB: physicalMemoryGB).concurrency
    }

    private func restartAndVerify(expected: ProviderVerifier.ExpectedContext, lines: [String], undoHint: String) async -> Outcome {
        var lines = lines
        do {
            try restart()
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
        guard let bytesPerToken = facts.kvBytesPerToken, let weights = facts.weightsBytes,
              context > 0, slots > 0 else {
            return nil
        }
        let ram = UInt64(physicalMemoryGB) * Self.gib
        let reserved = weights + UInt64(AutotuneRecommendEngine.safetyMarginGB) * Self.gib
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
        "about \(gibText(estimate.kvBytes)) GiB of KV cache for \(slots) slots × \(context) tokens; about \(gibText(estimate.availableBytes)) GiB available after \(gibText(estimate.weightsBytes)) GiB of weights and a \(AutotuneRecommendEngine.safetyMarginGB) GB reserve (\(estimate.fits ? "fits" : "does not fit"))"
    }

    private func gibText(_ bytes: UInt64) -> String {
        bytes == UInt64.max ? "∞" : String(format: "%.1f", Double(bytes) / Double(Self.gib))
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
