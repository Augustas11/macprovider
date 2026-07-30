import ArgumentParser
import Darwin
import Foundation
import MacProviderCore

struct AutotuneCommand: AsyncParsableCommand {
    static let spec023RecommendationProbeContext = 4_000

    static let configuration = CommandConfiguration(
        commandName: "autotune",
        abstract: "Find the biggest feasible model for this Mac and recommend serve knobs.",
        subcommands: [AutotuneRecommendSimulateCommand.self, AutotuneDumpBakedSnapshotCommand.self]
    )

    @Option(help: "Target context in tokens.")
    var targetContext = 2000

    @Option(help: "Override default ordered model list as comma-separated HuggingFace model IDs. Operator order is preserved.")
    var candidateModels: String?

    @Option(help: "Trim the default list above this model size, e.g. 16B. Ignored when --candidate-models is set.")
    var maxModelSize: String?

    @Option(help: "Trim the default list below this model size, e.g. 7B. Ignored when --candidate-models is set.")
    var minModelSize: String?

    @Option(help: "Stage 2 KV-cache bit cells. Use 'unset' for no --kv-bits flag.")
    var kvBitsAxis = "unset,4,8"

    @Option(help: "Stage 2 max-batch cells.")
    var maxBatchAxis = "1,2"

    @Option(help: "Stage 2 max-context cells as absolute token caps. Empty means target-context only.")
    var maxContextAxis = ""

    @Option(help: "Stage 1 replicates per candidate.")
    var stage1Replicates = 1

    @Option(help: "Stage 2 replicates per knob cell.")
    var stage2Replicates = 3

    /// Path-dependent default (#742 / AC-3):
    /// - classic Stage 1/2 (SPEC-013): omitted → 60_000 ms
    /// - paid `--recommend` (SPEC-023): omitted → disabled (0); no 60s default
    /// Explicit `0` disables the ceiling on either path. Buyer-facing paid
    /// selection has a separate post-measurement ceiling below.
    @Option(name: .customLong("gate-ttft-ms"), help: "Maximum p95 TTFT in milliseconds for Stage 1/2 feasibility. 0 disables the ceiling. Classic autotune defaults to 60000 when omitted; --recommend has no TTFT default.")
    var gateTTFTMS: Int?

    @Option(name: .customLong("buyer-ttft-ceiling-ms"), help: "With --recommend, maximum measured p95 TTFT in milliseconds allowed for paid recommendation selection. 0 disables the paid selection ceiling.")
    var buyerTTFTCeilingMS = 0

    @Option(help: "Relative throughput tie band for TTFT tiebreak.")
    var tpsTieEpsilon = 0.02

    @Option(help: "Hard wall-clock budget in seconds.")
    var maxDuration = 7_200

    @Option(help: "Grace period in seconds for draining or stopping providers.")
    var drainGrace = 30

    @Option(help: "Local provider port for candidate probes.")
    var port = 18_080

    @Option(help: "SQLite database path.")
    var dbPath = Self.defaultDBPath

    @Option(help: "YAML config path for --apply. Defaults to ~/.config/macprovider/config.yaml.")
    var config: String?

    @Option(help: "Number of recent autotune runs to retain.")
    var retainRuns = 50

    @Flag(name: .customLong("json"), help: "Emit recommendation as JSON.")
    var emitJSON = false

    @Flag(help: "Recommend the best paid-yield model for this Mac from the signed/static market inputs.")
    var recommend = false

    @Flag(name: .customLong("submit-hardware-evidence"), inversion: .prefixedNo, help: "With --recommend, submit local autotune hardware evidence for stats verification when provider credentials are configured.")
    var submitHardwareEvidence = true

    @Flag(name: .customLong("require-hardware-evidence"), help: "With --recommend, fail before applying configuration when hardware evidence cannot be submitted.")
    var requireHardwareEvidence = false

    @Flag(help: "With --recommend, check whether the stored recommendation is fresh without benchmarking.")
    var freshnessCheck = false

    @Flag(
        name: .customLong("recover-hardware-admission"),
        help: "With --recommend, run corrective stranger recovery: drain the running provider, recommend/apply with required evidence submission, and restore the provider. Pending-trust resubmit uses --freshness-check --require-hardware-evidence instead."
    )
    var recoverHardwareAdmission = false

    @Flag(help: "With --recommend and --candidate-models, download and verify the exact signed model artifacts without loading or benchmarking them.")
    var prefetch = false

    @Option(help: "Private receipt path written by --prefetch and required by a cache-only constrained --apply.")
    var prefetchReceipt: String?

    @Flag(help: "Allow local donor-mode configuration for non-paid-yield rows.")
    var donorMode = false

    @Flag(help: "Write the final recommendation to config.yaml.")
    var apply = false

    @Flag(help: "Drain an already-running serve process before tuning.")
    var drain = false

    @Flag(help: "After draining a foreground serve process, restart it at exit.")
    var restartForeground = false

    @Flag(help: "Print the candidate plan and exit without serving.")
    var dryRun = false

    @Flag(help: "Re-render the latest persisted report and exit.")
    var reportOnly = false

    @Flag(name: [.short, .long], help: "Stream per-trial details to stderr.")
    var verbose = false

    static let defaultCandidates: [AutotuneCandidate] = [
        AutotuneCandidate(modelID: "mlx-community/Qwen2.5-32B-Instruct-4bit", sizeB: 32),
        AutotuneCandidate(modelID: "mlx-community/Qwen2.5-14B-Instruct-4bit", sizeB: 14),
        AutotuneCandidate(modelID: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", sizeB: 7),
        AutotuneCandidate(modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit", sizeB: 3),
        AutotuneCandidate(modelID: "mlx-community/Llama-3.2-1B-Instruct-4bit", sizeB: 1),
    ]

    static var defaultDBPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macprovider/autotune.sqlite")
            .path
    }

    mutating func validate() throws {
        try validateBasicInputs()
        // Surface --candidate-models parse errors (e.g. empty cells from
        // typos like `a,,b`) at flag-parse time per FR-A.1 / FR-B.1
        // "reject invalid cells at flag-parse time." candidatePlan() is a
        // pure function; the call here is just a parse-time gate.
        _ = try candidatePlan()
    }

    func run() async throws {
        try await run(dependencies: .production)
    }

    func run(dependencies: AutotuneRunDependencies) async throws {
        if recommend {
            if recoverHardwareAdmission {
                try await runHardwareAdmissionRecovery()
                return
            }
            if freshnessCheck {
                try await runRecommendationFreshnessCheck()
                return
            }
            if prefetch {
                try await runRecommendationPrefetch()
                return
            }
            try await runAutotuneRecommend()
            return
        }

        let plan = try candidatePlan()

        if dryRun {
            printDryRun(plan)
            return
        }

        if reportOnly {
            FileHandle.standardError.write(Data(("autotune --report-only is a v2 feature.\n").utf8))
            throw ExitCode(2)
        }

        if let warning = plan.warning {
            dependencies.writeStderr("\(warning)\n")
        }

        let runID = dependencies.makeRunID()
        let startedAt = dependencies.now()
        let deadline = startedAt.addingTimeInterval(TimeInterval(maxDuration))
        let interruptFlag = dependencies.makeInterruptFlag()
        let signalSources = dependencies.installSignalSources(interruptFlag)
        defer {
            _ = signalSources
        }

        let machine = dependencies.machineFingerprint()
        let db = try dependencies.makeDB(dbPath)
        var recommendationJSON: String?
        var recipeHash: String?
        var applied = false
        var restoredConflict: ProviderConflict = .none

        let cancellationReason: () -> AutotuneCancellationReason? = {
            if interruptFlag.isSet() {
                return .interrupted
            }
            if dependencies.now() > deadline {
                return .budgetExhausted
            }
            return nil
        }

        func updateRun(
            endedAt: Date?,
            exitReason: AutotuneExitReason,
            recommendationJSON: String? = recommendationJSON,
            recipeHash: String? = recipeHash,
            applied: Bool = applied
        ) throws {
            try db.updateRun(
                runID: runID,
                endedAtUTC: endedAt.map(Self.iso8601UTC),
                recommendationJSON: recommendationJSON,
                recipeHash: recipeHash,
                applied: applied,
                exitReason: exitReason
            )
        }

        func emit(_ inputs: RecommendationInputs) throws -> EmittedRecommendation {
            let emitted = try dependencies.emitRecommendation(inputs)
            dependencies.writeStdout("\(emitted.terminalBlock)\n")
            if emitJSON {
                dependencies.writeStdout("\(emitted.jsonString)\n")
            }
            return emitted
        }

        let candidatesJSON = try Self.jsonString(plan.candidates)
        try db.insertRun(AutotuneRunRow(
            runID: runID,
            startedAtUTC: Self.iso8601UTC(startedAt),
            endedAtUTC: nil,
            specVersion: Self.specVersion,
            binaryVersion: machine.binaryVersion,
            machineRAMGB: machine.ramGB,
            machineChip: machine.chip,
            machineOSVersion: machine.osVersion,
            targetContext: targetContext,
            candidateModelsJSON: candidatesJSON,
            stage1Replicates: stage1Replicates,
            stage2Replicates: stage2Replicates,
            gateTTFTMS: resolvedGateTTFTMS(forRecommend: false),
            tpsTieEpsilon: tpsTieEpsilon,
            recommendationJSON: nil,
            recipeHash: nil,
            applied: false,
            exitReason: AutotuneExitReason.internalError.rawValue
        ))
        try db.applyRetentionInTransaction(retainRuns: retainRuns)

        defer {
            if restoredConflict != .none {
                _ = try? dependencies.restoreConflict(restoredConflict, restartForeground)
            }
        }

        do {
            if cancellationReason() == .interrupted {
                try updateRun(endedAt: nil, exitReason: .interrupted)
                throw ExitCode(130)
            }
            if cancellationReason() == .budgetExhausted {
                let endedAt = dependencies.now()
                let inputs = recommendationInputs(
                    plan: plan,
                    machine: machine,
                    runID: runID,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    recommendation: nil,
                    infeasible: []
                )
                _ = try emit(inputs)
                try updateRun(endedAt: endedAt, exitReason: .budgetExhaustedNoModelSelected, recommendationJSON: nil, recipeHash: nil)
                throw ExitCode(1)
            }

            let conflict = try dependencies.detectConflict()
            if conflict != .none {
                guard drain else {
                    let endedAt = dependencies.now()
                    try updateRun(endedAt: endedAt, exitReason: .providerConflict, recommendationJSON: nil, recipeHash: nil)
                    dependencies.writeStderr("autotune: provider conflict: \(Self.describe(conflict)); rerun with --drain to stop it first.\n")
                    throw ExitCode(1)
                }
                // Round-1 audit J.1 MAJOR fix: drain failures (e.g. launchctl
                // bootout failure, foreground SIGTERM failure) are still a
                // conflict scenario and must classify as .providerConflict,
                // not .internalError. The prior code let drainConflict's
                // thrown errors fall through to the generic catch which
                // finalized as internal_error.
                let drainResult: ProviderDrainResult
                do {
                    drainResult = try dependencies.drainConflict(conflict, port, TimeInterval(drainGrace))
                } catch {
                    let endedAt = dependencies.now()
                    try updateRun(endedAt: endedAt, exitReason: .providerConflict, recommendationJSON: nil, recipeHash: nil)
                    dependencies.writeStderr("autotune: provider conflict: --drain failed: \(error)\n")
                    throw ExitCode(1)
                }
                if case .portStillOpen(let heldPort) = drainResult {
                    let endedAt = dependencies.now()
                    try updateRun(endedAt: endedAt, exitReason: .providerConflict, recommendationJSON: nil, recipeHash: nil)
                    dependencies.writeStderr("autotune: provider conflict: port \(heldPort) still open after --drain.\n")
                    throw ExitCode(1)
                }
                restoredConflict = conflict
            }

            let stage1: Stage1IteratorResult
            do {
                stage1 = try await dependencies.runStage1(AutotuneStage1Request(
                    db: db,
                    runID: runID,
                    candidates: plan.candidates,
                    candidatesBySize: Self.candidatesBySize(for: plan),
                    targetContext: targetContext,
                    gateTTFTMS: resolvedGateTTFTMS(forRecommend: false),
                    stage1Replicates: stage1Replicates,
                    port: port,
                    drainGrace: drainGrace,
                    cancellationReason: cancellationReason
                ))
            } catch let error as Stage1IteratorError {
                switch error {
                case .interrupted:
                    try updateRun(endedAt: nil, exitReason: .interrupted, recommendationJSON: nil, recipeHash: nil)
                    throw ExitCode(130)
                case .budgetExhaustedNoModelSelected:
                    let endedAt = dependencies.now()
                    let inputs = recommendationInputs(
                        plan: plan,
                        machine: machine,
                        runID: runID,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        recommendation: nil,
                        infeasible: []
                    )
                    _ = try emit(inputs)
                    try updateRun(endedAt: endedAt, exitReason: .budgetExhaustedNoModelSelected, recommendationJSON: nil, recipeHash: nil)
                    throw ExitCode(1)
                case .noFeasible(_, let trials, _):
                    let endedAt = dependencies.now()
                    let infeasible = Self.infeasibleEntries(
                        reasonsBySurfaceOrder: trials,
                        candidatesBySurfaceOrder: Self.candidatesBySize(for: plan) ?? plan.candidates
                    )
                    let inputs = recommendationInputs(
                        plan: plan,
                        machine: machine,
                        runID: runID,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        recommendation: nil,
                        infeasible: infeasible
                    )
                    _ = try emit(inputs)
                    try updateRun(endedAt: endedAt, exitReason: .noFeasible, recommendationJSON: nil, recipeHash: nil)
                    dependencies.writeStderr(Self.noFeasibleMessage(infeasible: infeasible))
                    throw ExitCode(1)
                case .preWarmIntegrityFailure(let model, let reason, _):
                    let endedAt = dependencies.now()
                    let inputs = recommendationInputs(
                        plan: plan,
                        machine: machine,
                        runID: runID,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        recommendation: nil,
                        infeasible: [InfeasibleEntry(model: model, rank: 1, reason: "pre-warm integrity: \(reason)")]
                    )
                    _ = try emit(inputs)
                    try updateRun(endedAt: endedAt, exitReason: .preWarmIntegrityFailure, recommendationJSON: nil, recipeHash: nil)
                    dependencies.writeStderr("autotune: pre-warm integrity failure for \(model): \(reason)\n")
                    throw ExitCode(1)
                default:
                    throw error
                }
            }

            let stage2: Stage2HillClimbResult
            do {
                stage2 = try await dependencies.runStage2(AutotuneStage2Request(
                    db: db,
                    runID: runID,
                    selectedModel: stage1.selectedModel,
                    kvBitsAxis: try Self.parseKvBitsAxis(kvBitsAxis),
                    maxBatchAxis: try Self.parsePositiveIntAxis(maxBatchAxis, flag: "--max-batch-axis"),
                    maxContextAxis: try Self.parseMaxContextAxis(maxContextAxis, targetContext: targetContext),
                    targetContext: targetContext,
                    gateTTFTMS: resolvedGateTTFTMS(forRecommend: false),
                    stage2Replicates: stage2Replicates,
                    tpsTieEpsilon: tpsTieEpsilon,
                    port: port,
                    drainGrace: drainGrace,
                    cancellationReason: cancellationReason
                ))
            } catch let error as Stage2HillClimbError {
                switch error {
                case .interrupted:
                    try updateRun(endedAt: nil, exitReason: .interrupted, recommendationJSON: nil, recipeHash: nil)
                    throw ExitCode(130)
                case .budgetExhaustedWithPartialRecommendation(let partial):
                    let endedAt = dependencies.now()
                    let recommendation = Self.recommendation(from: partial, targetContext: targetContext, partial: true)
                    let inputs = recommendationInputs(
                        plan: plan,
                        machine: machine,
                        runID: runID,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        recommendation: recommendation,
                        infeasible: []
                    )
                    let emitted = try emit(inputs)
                    recommendationJSON = emitted.jsonString
                    recipeHash = emitted.recipeHash
                    try updateRun(
                        endedAt: endedAt,
                        exitReason: .budgetExhaustedWithPartialRecommendation,
                        recommendationJSON: emitted.jsonString,
                        recipeHash: emitted.recipeHash
                    )
                    throw ExitCode(1)
                case .noFeasibleCell(let reason):
                    let endedAt = dependencies.now()
                    let inputs = recommendationInputs(
                        plan: plan,
                        machine: machine,
                        runID: runID,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        recommendation: nil,
                        infeasible: [InfeasibleEntry(model: stage1.selectedModel, rank: 1, reason: reason)]
                    )
                    _ = try emit(inputs)
                    try updateRun(endedAt: endedAt, exitReason: .noFeasible, recommendationJSON: nil, recipeHash: nil)
                    throw ExitCode(1)
                }
            }

            // Round-1 audit B.1 MAJOR fix: poll cancellation after Stage 2
            // returns to catch SIGINT/SIGTERM that arrived between the last
            // Stage 2 cell boundary and recommendation emission. Without
            // this poll, an interrupt in this window would still apply
            // config and finalize as .ok.
            if cancellationReason() == .interrupted {
                try updateRun(endedAt: nil, exitReason: .interrupted, recommendationJSON: nil, recipeHash: nil)
                throw ExitCode(130)
            }

            let endedAt = dependencies.now()
            let recommendation = Self.recommendation(from: stage2, targetContext: targetContext, partial: false)
            let inputs = recommendationInputs(
                plan: plan,
                machine: machine,
                runID: runID,
                startedAt: startedAt,
                endedAt: endedAt,
                recommendation: recommendation,
                infeasible: []
            )
            let emitted = try emit(inputs)
            recommendationJSON = emitted.jsonString
            recipeHash = emitted.recipeHash

            if apply {
                // Round-1 audit B.1 MAJOR fix (continued): re-poll before
                // applyConfig so an interrupt that arrived during emission
                // does not still write to disk.
                if cancellationReason() == .interrupted {
                    try updateRun(endedAt: nil, exitReason: .interrupted, recommendationJSON: nil, recipeHash: nil)
                    throw ExitCode(130)
                }
                do {
                    let result = try dependencies.applyConfig(recommendation, endedAt, config)
                    applied = true
                    dependencies.writeStdout("\(result.summary)\n")
                    if !drain {
                        dependencies.writeStderr("\(RecommendationEmitter.launchdRestartHint())\n")
                    }
                } catch {
                    applied = false
                    dependencies.writeStderr("autotune: apply failed; recommendation remains valid: \(error)\n")
                }
            }

            try updateRun(
                endedAt: endedAt,
                exitReason: .ok,
                recommendationJSON: emitted.jsonString,
                recipeHash: emitted.recipeHash,
                applied: applied
            )
        } catch let exit as ExitCode {
            throw exit
        } catch {
            try? updateRun(endedAt: dependencies.now(), exitReason: .internalError, recommendationJSON: nil, recipeHash: nil, applied: false)
            throw error
        }
    }

    func candidatePlan() throws -> AutotunePlan {
        if let candidateModels, !candidateModels.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let models = try Self.parseCSVStrict(candidateModels, flag: "--candidate-models")
            guard !models.isEmpty else {
                throw ValidationError("--candidate-models must contain at least one model id")
            }
            let warning: String? = (maxModelSize != nil || minModelSize != nil)
                ? "warning: --candidate-models supplied; ignoring --max-model-size/--min-model-size"
                : nil
            return AutotunePlan(candidates: models, source: .explicit, warning: warning)
        }

        let maxSize = try maxModelSize.map(Self.parseSizeB)
        let minSize = try minModelSize.map(Self.parseSizeB)
        if let minSize, let maxSize, minSize > maxSize {
            throw ValidationError("--min-model-size must be <= --max-model-size")
        }

        let filtered = Self.defaultCandidates.filter { candidate in
            if let maxSize, candidate.sizeB > maxSize {
                return false
            }
            if let minSize, candidate.sizeB < minSize {
                return false
            }
            return true
        }
        guard !filtered.isEmpty else {
            throw ValidationError("model-size filters removed every default candidate")
        }
        return AutotunePlan(candidates: filtered.map(\.modelID), source: .defaultList, warning: nil)
    }

    /// When `--candidate-models` is set, `--recommend` probes only catalog rows
    /// whose HuggingFace `model_id` appears in the operator list.
    private func recommendCandidateModelFilter() throws -> Set<String>? {
        guard let candidateModels,
              !candidateModels.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return Set(try Self.parseCSVStrict(candidateModels, flag: "--candidate-models"))
    }

    static let specVersion = "SPEC-013 v0.3"

    static func candidatesBySize(for plan: AutotunePlan) -> [String]? {
        switch plan.source {
        case .defaultList:
            let selected = Set(plan.candidates)
            return defaultCandidates
                .filter { selected.contains($0.modelID) }
                .sorted { $0.sizeB < $1.sizeB }
                .map(\.modelID)
        case .explicit:
            // Round-1 audit M.1 CRITICAL fix: operator overrides have no
            // size metadata in v1, so pass the input order EXPLICITLY as
            // the error-surface order. This preserves the LOCKED Stage 7
            // iterator's nil-fallback semantics (reversed) while letting
            // operator-override runs surface infeasibles in the order the
            // operator typed them. The LOCKED fallback is never triggered
            // from production code now.
            return plan.candidates
        }
    }

    private func recommendationInputs(
        plan: AutotunePlan,
        machine: MachineFingerprint,
        runID: String,
        startedAt: Date,
        endedAt: Date,
        recommendation: RecommendationCore?,
        infeasible: [InfeasibleEntry]
    ) -> RecommendationInputs {
        RecommendationInputs(
            specVersion: Self.specVersion,
            runID: runID,
            startedAt: startedAt,
            endedAt: endedAt,
            machine: machine,
            targetContext: targetContext,
            candidateModels: plan.candidates,
            stage1Replicates: stage1Replicates,
            stage2Replicates: stage2Replicates,
            gateTTFTMS: resolvedGateTTFTMS(forRecommend: false),
            tpsTieEpsilon: tpsTieEpsilon,
            recommendation: recommendation,
            infeasible: infeasible,
            dbPath: dbPath
        )
    }

    /// Resolve the TTFT feasibility ceiling.
    /// - `0` means disabled (explicit or paid-path default).
    /// - Classic Stage 1/2 keeps SPEC-013's 60s default when the flag is omitted.
    /// - Paid `--recommend` never inherits that 60s default (#742 AC-3).
    private func resolvedGateTTFTMS(forRecommend: Bool) -> Int {
        if let gateTTFTMS { return gateTTFTMS }
        return forRecommend ? 0 : 60_000
    }

    private static func recommendation(
        from stage2: Stage2HillClimbResult,
        targetContext: Int,
        partial: Bool
    ) -> RecommendationCore {
        RecommendationCore(
            model: stage2.selectedModel,
            targetContext: targetContext,
            knobs: stage2.winningKnobs,
            tpsMedian: stage2.medianTPS,
            ttftP95MS: stage2.p95TTFTMS,
            replicates: stage2.replicates,
            partial: partial
        )
    }

    private static func infeasibleEntries(
        reasonsBySurfaceOrder: [String],
        candidatesBySurfaceOrder: [String]
    ) -> [InfeasibleEntry] {
        zip(candidatesBySurfaceOrder, reasonsBySurfaceOrder).enumerated().map { index, pair in
            InfeasibleEntry(model: pair.0, rank: index + 1, reason: pair.1)
        }
    }

    private static func noFeasibleMessage(infeasible: [InfeasibleEntry]) -> String {
        var lines = ["autotune: no candidate fits this Mac."]
        for entry in infeasible {
            let label = entry.rank == 1 ? "\(Self.shortModelLabel(entry.model)) (smallest)" : Self.shortModelLabel(entry.model)
            lines.append("  \(label): \(entry.reason)")
        }
        lines.append("hint: lower --target-context or pass --candidate-models with a smaller model.")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func shortModelLabel(_ model: String) -> String {
        if let candidate = defaultCandidates.first(where: { $0.modelID == model }) {
            return "\(Int(candidate.sizeB))B"
        }
        return model
    }

    private static func describe(_ conflict: ProviderConflict) -> String {
        switch conflict {
        case .none:
            return "none"
        case .launchdManaged(let pid):
            return "launchd-managed\(pid.map { " pid \($0)" } ?? "")"
        case .foreground(let pid, _):
            return "foreground-PID-\(pid)"
        }
    }

    private static func jsonString(_ strings: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: strings, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    private static func iso8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    func printDryRun(_ plan: AutotunePlan) {
        if let warning = plan.warning {
            FileHandle.standardError.write(Data(("\(warning)\n").utf8))
        }
        for line in dryRunLines(plan) {
            print(line)
        }
    }

    /// Builds the dry-run line list for stdout. Exposed so tests can assert
    /// content (especially candidate order) without capturing stdout.
    func dryRunLines(_ plan: AutotunePlan) -> [String] {
        var lines: [String] = []
        lines.append("autotune: dry run")
        lines.append("autotune: target_context=\(targetContext)")
        lines.append("autotune: candidates (\(plan.source.description)):")
        for (index, model) in plan.candidates.enumerated() {
            lines.append("  \(index + 1). \(model)")
        }
        lines.append("autotune: stage1_replicates=\(stage1Replicates) stage2_replicates=\(stage2Replicates)")
        let classicGate = resolvedGateTTFTMS(forRecommend: false)
        lines.append("autotune: gate_ttft_ms=\(classicGate == 0 ? "disabled" : String(classicGate)) tps_tie_epsilon=\(tpsTieEpsilon)")
        lines.append("autotune: kv_bits_axis=\(kvBitsAxis) max_batch_axis=\(maxBatchAxis) max_context_axis=\(maxContextAxis.isEmpty ? "<target-context>" : maxContextAxis)")
        lines.append("autotune: port=\(port) db_path=\(dbPath) retain_runs=\(retainRuns)")
        lines.append("[dry-run] would evaluate Stage 1 candidates in this order and then hill-climb knobs only within the first feasible model.")
        return lines
    }

    private func validateBasicInputs() throws {
        guard targetContext > 0 else {
            throw ValidationError("--target-context must be >= 1")
        }
        guard stage1Replicates >= 1 else {
            throw ValidationError("--stage1-replicates must be >= 1")
        }
        guard stage2Replicates >= 1 else {
            throw ValidationError("--stage2-replicates must be >= 1")
        }
        if let gateTTFTMS, gateTTFTMS < 0 {
            throw ValidationError("--gate-ttft-ms must be >= 0 (0 disables the TTFT feasibility ceiling)")
        }
        guard buyerTTFTCeilingMS >= 0 else {
            throw ValidationError("--buyer-ttft-ceiling-ms must be >= 0 (0 disables the paid selection ceiling)")
        }
        if buyerTTFTCeilingMS > 0 && !recommend {
            throw ValidationError("--buyer-ttft-ceiling-ms requires --recommend")
        }
        guard tpsTieEpsilon >= 0 else {
            throw ValidationError("--tps-tie-epsilon must be >= 0")
        }
        if freshnessCheck && !recommend {
            throw ValidationError("--freshness-check requires --recommend")
        }
        if recoverHardwareAdmission && !recommend {
            throw ValidationError("--recover-hardware-admission requires --recommend")
        }
        if recoverHardwareAdmission && freshnessCheck {
            throw ValidationError("--recover-hardware-admission cannot be combined with --freshness-check")
        }
        if recoverHardwareAdmission && prefetch {
            throw ValidationError("--recover-hardware-admission cannot be combined with --prefetch")
        }
        if recoverHardwareAdmission && !submitHardwareEvidence {
            throw ValidationError("--recover-hardware-admission cannot be combined with --no-submit-hardware-evidence")
        }
        if prefetch && !recommend {
            throw ValidationError("--prefetch requires --recommend")
        }
        if prefetch && freshnessCheck {
            throw ValidationError("--prefetch cannot be combined with --freshness-check")
        }
        if prefetch && apply {
            throw ValidationError("--prefetch cannot be combined with --apply")
        }
        if prefetch && donorMode {
            throw ValidationError("--prefetch cannot be combined with --donor-mode")
        }
        if prefetch && candidateModels == nil {
            throw ValidationError("--prefetch requires an explicit --candidate-models allowlist")
        }
        if prefetch && prefetchReceipt == nil {
            throw ValidationError("--prefetch requires --prefetch-receipt")
        }
        if prefetchReceipt != nil && !prefetch && !apply {
            throw ValidationError("--prefetch-receipt requires --prefetch or --apply")
        }
        if prefetchReceipt != nil && !recommend {
            throw ValidationError("--prefetch-receipt requires --recommend")
        }
        if prefetchReceipt != nil && apply && candidateModels == nil {
            throw ValidationError("cache-only --apply requires an explicit --candidate-models allowlist")
        }
        if requireHardwareEvidence && !recommend {
            throw ValidationError("--require-hardware-evidence requires --recommend")
        }
        if requireHardwareEvidence && !submitHardwareEvidence {
            throw ValidationError("--require-hardware-evidence cannot be combined with --no-submit-hardware-evidence")
        }
        guard maxDuration > 0 else {
            throw ValidationError("--max-duration must be > 0")
        }
        guard drainGrace >= 0 else {
            throw ValidationError("--drain-grace must be >= 0")
        }
        guard port > 0 && port <= 65_535 else {
            throw ValidationError("--port must be in 1...65535")
        }
        guard retainRuns >= 1 else {
            throw ValidationError("--retain-runs must be >= 1")
        }
        _ = try Self.parseKvBitsAxis(kvBitsAxis)
        _ = try Self.parsePositiveIntAxis(maxBatchAxis, flag: "--max-batch-axis")
        _ = try Self.parseMaxContextAxis(maxContextAxis, targetContext: targetContext)
    }

    private func runAutotuneRecommend() async throws {
        // ARCH-M-1 orphan-child fix: become process-group leader BEFORE
        // spawning any CandidateProviderRunner subprocess. Combined with the
        // cascading signal handler below, this lets the caller (App) send
        // one `killpg(cliPid, SIGTERM)` and cleanly tear down every
        // `serve --no-join` grandchild alongside this process.
        _ = autotuneBecomeProcessGroupLeader()
        let interruptFlag = AutotuneInterruptFlag()
        let signalSources = AutotuneSignalSources(flag: interruptFlag, cascadeToProcessGroup: true)
        defer { _ = signalSources }

        let staticInputs = AutotuneStaticInputs()
        let inputs = await staticInputs.loadRecommendationInputs()
        let demand = inputs.demand
        let catalog = inputs.candidate
        let rateCard = inputs.rateCard

        let fingerprint = MachineFingerprinter().sample()
        let resolvedConfig = try? ConfigLoader.load(cli: CLIOverrides(configPath: config))
        let secret = try AutotuneHMACSecretStore(path: AutotuneHMACSecretStore.defaultPath).loadOrCreate()
        let identity = HMACIdentity.derive(secret: secret, fingerprint: fingerprint, providerID: resolvedConfig?.providerID)
        let hardware = AutotuneRecommendHardware(fingerprint: fingerprint, hmacIdentity: identity)
        let catalogSHA = AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalog.selectedBytes)
        let candidateModelFilter = try recommendCandidateModelFilter()
        let prefetchedArtifacts: [String: PrefetchedModelArtifact]?
        if let prefetchReceipt {
            let receiptURL = URL(fileURLWithPath: ConfigLoader.expandTilde(prefetchReceipt))
            let receipt = try AutotuneArtifactPrefetchReceipt.load(from: receiptURL)
            let validated = try receipt.validatedArtifacts(
                candidateCatalog: catalog.value,
                candidateCatalogSHA256: catalogSHA
            )
            let receiptModelIDs = Set(validated.values.map(\.modelID))
            guard candidateModelFilter == receiptModelIDs else {
                throw ValidationError("--candidate-models must exactly match the prefetch receipt")
            }
            prefetchedArtifacts = validated
        } else {
            prefetchedArtifacts = nil
        }
        let now = Date()
        var warnings = Set<AutotuneRecommendWarning>()
        warnings.formUnion(demand.warnings)
        warnings.formUnion(catalog.warnings)
        warnings.formUnion(rateCard.warnings)

        if AutotuneRecommendEngine.paidTrustBlocks(warnings) {
            throw ValidationError(AutotuneRecommendEngine.paidTrustBlockMessage(warnings))
        }
        // #582: baked-catalog / network-submission blocks are known before
        // Stage-1 probes. Fail closed immediately when apply/submit is enabled
        // so strangers do not wait hours for an already-rejected evidence class.
        // Offline diagnostics remain available with --no-submit-hardware-evidence
        // (and without --apply / --require-hardware-evidence).
        if AutotuneRecommendEngine.shouldFailClosedBeforeBenchmarks(
            warnings,
            apply: apply,
            submitHardwareEvidence: submitHardwareEvidence,
            requireHardwareEvidence: requireHardwareEvidence
        ) {
            throw ValidationError(AutotuneRecommendEngine.networkSubmissionBlockMessage(warnings))
        }
        if AutotuneRecommendEngine.networkSubmissionBlocks(warnings) {
            let message = AutotuneRecommendEngine.networkSubmissionBlockMessage(warnings)
            FileHandle.standardError.write(Data("[warn] \(message)\n".utf8))
        }

        var request = AutotuneRecommendRequest(
            hardware: hardware,
            demandRank: demand.value,
            candidateCatalog: catalog.value,
            candidateCatalogSHA256: catalogSHA,
            rateCard: rateCard.value,
            benchmarks: [:],
            warnings: warnings,
            generatedAt: now,
            donorMode: donorMode,
            buyerTTFTCeilingMS: buyerTTFTCeilingMS
        )
        let outcomes = try await AutotuneRecommendationBenchmarker().benchmarks(
            request: request,
            targetContext: Self.spec023RecommendationProbeContext,
            gateTTFTMS: resolvedGateTTFTMS(forRecommend: true),
            replicates: stage1Replicates,
            port: port,
            interruptFlag: interruptFlag,
            candidateModelIDs: candidateModelFilter,
            prefetchedArtifacts: prefetchedArtifacts
        )
        if interruptFlag.isSet() {
            FileHandle.standardError.write(Data("autotune --recommend interrupted; exiting after subtree cleanup\n".utf8))
            throw ExitCode(130)
        }
        request.benchmarks = outcomes.benchmarks
        for modelKey in outcomes.diagnostics.keys.sorted() {
            let reason = outcomes.diagnostics[modelKey]!
            FileHandle.standardError.write(Data("[warn] Model readiness check: \(modelKey): \(reason)\n".utf8))
        }
        var result = AutotuneRecommendEngine().recommend(request)
        result.probeDiagnostics = outcomes.diagnostics
        try RecommendationStateStore.write(result, benchmarks: request.benchmarks)
        if AutotuneRecommendEngine.networkSubmissionBlocks(Set(result.warnings)) {
            let message = AutotuneRecommendEngine.networkSubmissionBlockMessage(Set(result.warnings))
            if apply || submitHardwareEvidence || requireHardwareEvidence {
                throw ValidationError(message)
            }
            FileHandle.standardError.write(Data("[warn] \(message)\n".utf8))
        }
        if submitHardwareEvidence {
            let submission = await AutotuneHardwareEvidenceSubmitter(config: resolvedConfig).submit(
                result: result,
                benchmarks: request.benchmarks
            )
            if let reason = Self.requiredHardwareEvidenceBlockReason(
                submission: submission,
                required: requireHardwareEvidence
            ) {
                FileHandle.standardError.write(Data("hardware_evidence_unavailable: \(reason)\n".utf8))
                throw ExitCode(11)
            }
            switch submission {
            case .submitted:
                FileHandle.standardError.write(Data("hardware evidence submitted for stats verification\n".utf8))
            case .skipped:
                break
            case .failed(let reason):
                FileHandle.standardError.write(Data("[warn] hardware evidence submission failed: \(reason)\n".utf8))
            }
        }
        let paidSelected = result.recommendedModel.flatMap { recommendedModel in
            result.selectedCandidate.flatMap { $0.model == recommendedModel ? $0 : nil }
        }
        if apply, result.recommendedModel != nil, paidSelected == nil, !donorMode {
            throw ValidationError("selected paid recommendation was not available for config apply")
        }
        let donorSelected = donorMode ? result.donorFallbackCandidate : nil
        if apply, donorMode, result.donorFallbackModel != nil, donorSelected == nil {
            throw ValidationError("selected donor recommendation was not available for config apply")
        }
        let selectedForConfig = paidSelected ?? donorSelected
        let applyingDonorFallback = paidSelected == nil && selectedForConfig == donorSelected
        let serveConfig: RecommendationCore?
        var configurationApplied = false
        if let selected = selectedForConfig,
           let selectedBenchmark = request.benchmarks[selected.catalogKey],
           let selectedRow = catalog.value.rows[selected.catalogKey] {
            serveConfig = Self.recommendationCoreForConfig(
                selected: selected,
                selectedBenchmark: selectedBenchmark,
                selectedRow: selectedRow,
                catalogVersion: catalog.value.version,
                catalogHash: catalogSHA,
                hardware: hardware
            )
        } else {
            serveConfig = nil
        }
        if apply, let selected = selectedForConfig {
            guard request.benchmarks[selected.catalogKey] != nil else {
                throw ValidationError("selected recommendation lacks verified benchmark artifact")
            }
            guard catalog.value.rows[selected.catalogKey] != nil else {
                throw ValidationError("selected recommendation lacks signed catalog row")
            }
            if applyingDonorFallback {
                FileHandle.standardError.write(Data("\(Self.donorModeApplyWarning(for: selected.model))\n".utf8))
            }
            let rawPath = config ?? AppConfig.defaultConfigPath
            let expanded = ConfigLoader.expandTilde(rawPath)
            guard let core = serveConfig else {
                throw ValidationError("selected recommendation lacks serve config")
            }
            let applied = try ConfigApplier(configPath: URL(fileURLWithPath: expanded)).apply(
                recommendation: core,
                now: now,
                donorMode: applyingDonorFallback
            )
            configurationApplied = true
            if emitJSON {
                FileHandle.standardError.write(Data("\(applied.summary)\n".utf8))
            } else {
                print(applied.summary)
            }
        }
        if emitJSON {
            print(result.jsonString(serveConfig: serveConfig, donorMode: applyingDonorFallback))
        } else {
            print(result.humanTranscript(configurationApplied: configurationApplied))
        }
        for warning in result.warnings {
            FileHandle.standardError.write(Data("\(warning.rawValue)\n".utf8))
        }
    }

    private func runRecommendationPrefetch() async throws {
        let staticInputs = AutotuneStaticInputs()
        let inputs = await staticInputs.loadRecommendationInputs()
        let catalog = inputs.candidate
        let fingerprint = MachineFingerprinter().sample()
        let resolvedConfig = try? ConfigLoader.load(cli: CLIOverrides(configPath: config))
        let secret = try AutotuneHMACSecretStore(path: AutotuneHMACSecretStore.defaultPath).loadOrCreate()
        let identity = HMACIdentity.derive(secret: secret, fingerprint: fingerprint, providerID: resolvedConfig?.providerID)
        let hardware = AutotuneRecommendHardware(fingerprint: fingerprint, hmacIdentity: identity)
        let warnings = Self.recommendationPrefetchTrustWarnings(
            demand: inputs.demand,
            catalog: catalog,
            rateCard: inputs.rateCard
        )

        if AutotuneRecommendEngine.paidTrustBlocks(warnings) {
            throw ValidationError(AutotuneRecommendEngine.paidTrustBlockMessage(warnings))
        }

        guard let requestedModelIDs = try recommendCandidateModelFilter(), !requestedModelIDs.isEmpty else {
            throw ValidationError("--prefetch requires an explicit --candidate-models allowlist")
        }
        let outcome = try await AutotuneRecommendationBenchmarker().prefetchArtifacts(
            candidateCatalog: catalog.value,
            hardware: hardware,
            candidateModelIDs: requestedModelIDs
        )
        let missingRows = requestedModelIDs.subtracting(outcome.matchedModelIDs).sorted()
        guard missingRows.isEmpty else {
            throw ValidationError("prefetch models are absent from the signed catalog: \(missingRows.joined(separator: ", "))")
        }
        let failed = requestedModelIDs.subtracting(outcome.prefetchedModelIDs).sorted()
        guard failed.isEmpty else {
            let details = outcome.diagnostics
                .filter { failed.contains($0.modelID) }
                .sorted { $0.modelID < $1.modelID }
                .map { "\($0.modelID): \($0.reason)" }
                .joined(separator: "; ")
            throw ValidationError("signed model artifact prefetch failed: \(details)")
        }
        guard outcome.artifacts.count == requestedModelIDs.count else {
            throw ValidationError("each prefetch model must match exactly one signed catalog row")
        }
        let catalogSHA = AutotuneStaticInputs.candidateCatalogSHA256(bytes: catalog.selectedBytes)
        let receipt = AutotuneArtifactPrefetchReceipt(
            schemaVersion: AutotuneArtifactPrefetchReceipt.currentSchemaVersion,
            candidateCatalogSHA256: catalogSHA,
            candidateCatalogVersion: catalog.value.version,
            candidateCatalogPolicyVersion: catalog.value.policyVersion,
            artifacts: outcome.artifacts.sorted { $0.modelKey < $1.modelKey }
        )
        guard let prefetchReceipt else {
            throw ValidationError("--prefetch requires --prefetch-receipt")
        }
        try receipt.write(to: URL(fileURLWithPath: ConfigLoader.expandTilde(prefetchReceipt)))
        for artifact in outcome.artifacts.sorted(by: { $0.modelID < $1.modelID }) {
            print("prefetch_verified model=\(artifact.modelID) path=\(artifact.path) sha256=\(artifact.sha256)")
        }
    }

    static func recommendationPrefetchTrustWarnings(
        demand: AutotuneStaticSelection<DemandRank>,
        catalog: AutotuneStaticSelection<CandidateCatalog>,
        rateCard: AutotuneStaticSelection<RateCardProjection>
    ) -> Set<AutotuneRecommendWarning> {
        demand.warnings.union(catalog.warnings).union(rateCard.warnings)
    }

    static func recommendationCoreForConfig(
        selected: AutotuneCandidateScore,
        selectedBenchmark: CandidateBenchmark,
        selectedRow: CandidateCatalog.Row,
        catalogVersion: String,
        catalogHash: String,
        hardware: AutotuneRecommendHardware
    ) -> RecommendationCore {
        RecommendationCore(
            model: selected.model,
            targetContext: Self.spec023RecommendationProbeContext,
            knobs: WinningKnobs(
                kvBits: nil,
                maxBatch: hardware.recommendedMaxBatch,
                maxContext: Self.spec023RecommendationProbeContext
            ),
            tpsMedian: selected.tokensPerSecond,
            ttftP95MS: 0,
            replicates: 0,
            modelArtifactPath: selectedBenchmark.modelArtifactPath,
            modelArtifactSHA256: selectedBenchmark.artifactSHA256,
            modelCatalogKey: selected.catalogKey,
            modelCatalogModelID: selectedRow.modelID,
            modelCatalogRevision: selectedRow.modelRevision,
            modelCatalogSHA256: selectedRow.modelSHA256,
            modelCatalogVersion: catalogVersion,
            modelCatalogHash: catalogHash
        )
    }

    /// Corrective #582 recovery owned by the CLI:
    /// drain (bootout) → recommend/apply with required evidence → restore.
    /// Pending-trust resubmit is a separate freshness-check path so rejected /
    /// cap / uncatalogued models cannot false-complete via stored evidence.
    private func runHardwareAdmissionRecovery() async throws {
        // Own the process group and cooperative cancellation before mutating
        // launchd so SIGTERM can restore instead of stranding a bootout.
        _ = autotuneBecomeProcessGroupLeader()
        let interruptFlag = AutotuneInterruptFlag()
        let signalSources = AutotuneSignalSources(flag: interruptFlag, cascadeToProcessGroup: true)
        defer { _ = signalSources }

        let conflict = try ProviderConflictDetector().detect()
        let shouldRestore: Bool
        switch conflict {
        case .none:
            shouldRestore = false
        case .launchdManaged, .foreground:
            shouldRestore = true
        }

        let drainer = ProviderDrainer()
        let restoreGuard = shouldRestore
            ? try drainer.startLaunchdCrashRestoreGuard(for: conflict)
            : nil

        let drainResult = try drainer.drain(
            conflict,
            port: port,
            graceSeconds: TimeInterval(drainGrace)
        )

        var recoveryError: Error?
        if case .portStillOpen(let openPort) = drainResult {
            recoveryError = ValidationError(
                "provider port \(openPort) still open after drain; cannot recover hardware admission safely"
            )
        } else if interruptFlag.isSet() {
            recoveryError = ExitCode(130)
        } else {
            do {
                var recovery = self
                recovery.apply = true
                recovery.requireHardwareEvidence = true
                recovery.submitHardwareEvidence = true
                try await recovery.runAutotuneRecommend()
            } catch {
                recoveryError = error
            }
        }

        var restoreError: Error?
        if shouldRestore {
            do {
                _ = try drainer.restore(conflict, restartForeground: true)
                restoreGuard?.dismiss()
            } catch {
                restoreError = error
            }
        }

        if let restoreError {
            if let recoveryError {
                FileHandle.standardError.write(
                    Data("hardware_admission_recovery_failed: \(recoveryError)\n".utf8)
                )
            }
            throw restoreError
        }
        if let recoveryError {
            throw recoveryError
        }
    }

    private func runRecommendationFreshnessCheck() async throws {
        let resolvedConfig = try? ConfigLoader.load(cli: CLIOverrides(configPath: config))
        let status = await RecommendationFreshnessChecker(providerID: resolvedConfig?.providerID).status()
        switch status {
        case .fresh:
            let storedEvidence = try? RecommendationStateStore.read().hardwareEvidence
            let evidenceOutcome = await Self.freshRecommendationEvidenceOutcome(
                storedEvidence: storedEvidence,
                submitEnabled: submitHardwareEvidence,
                submit: { evidence in
                    await AutotuneHardwareEvidenceSubmitter(config: resolvedConfig).submit(snapshot: evidence)
                }
            )
            switch evidenceOutcome {
            case .ready(let submitted):
                if submitted {
                    FileHandle.standardError.write(Data("hardware evidence resubmitted for stats verification\n".utf8))
                }
                print("recommendation_fresh")
            case .rerunRecommendation(let reason):
                FileHandle.standardError.write(Data("recommendation_stale: \(reason)\n".utf8))
                throw ExitCode(10)
            case .blocked(let reason):
                FileHandle.standardError.write(Data("hardware_evidence_unavailable: \(reason)\n".utf8))
                throw ExitCode(11)
            }
        case .missing, .stale, .trustBlocked:
            guard let failure = Self.recommendationFreshnessFailure(for: status) else {
                preconditionFailure("non-fresh recommendation status must have a failure mapping")
            }
            FileHandle.standardError.write(Data(failure.diagnostic.utf8))
            throw failure.exitCode
        }
    }

    struct RecommendationFreshnessFailure: Equatable {
        let diagnostic: String
        let exitCode: ExitCode
    }

    static func recommendationFreshnessFailure(
        for status: RecommendationFreshnessChecker.Status
    ) -> RecommendationFreshnessFailure? {
        switch status {
        case .fresh:
            return nil
        case .missing:
            return RecommendationFreshnessFailure(
                diagnostic: "recommendation_stale: missing stored recommendation\n",
                exitCode: ExitCode(10)
            )
        case .stale(let generatedAt):
            return RecommendationFreshnessFailure(
                diagnostic: "recommendation_stale: inputs changed since \(ISO8601DateFormatter.autotuneInternet.string(from: generatedAt))\n",
                exitCode: ExitCode(10)
            )
        case .trustBlocked(_, let warnings):
            let failures = warnings
                .intersection(AutotuneRecommendEngine.networkSubmissionBlockingWarnings)
                .map(\.rawValue)
                .sorted()
                .joined(separator: ", ")
            return RecommendationFreshnessFailure(
                diagnostic: "catalog_trust_blocked: \(failures)\n",
                exitCode: ExitCode(12)
            )
        }
    }

    static func freshRecommendationEvidenceOutcome(
        storedEvidence: AutotuneHardwareEvidenceSnapshot?,
        submitEnabled: Bool,
        submit: (AutotuneHardwareEvidenceSnapshot) async -> AutotuneHardwareEvidenceSubmission
    ) async -> FreshRecommendationEvidenceOutcome {
        guard submitEnabled else { return .ready(submitted: false) }
        guard let storedEvidence else {
            // Legacy state did not retain enough benchmark detail to recreate
            // verifier evidence safely. Exit 10 makes the installer run the
            // normal recommendation once and seed reusable evidence.
            return .rerunRecommendation("stored hardware evidence is missing")
        }
        switch await submit(storedEvidence) {
        case .submitted:
            return .ready(submitted: true)
        case .skipped(let reason):
            return .blocked(reason)
        case .failed(let reason):
            return .blocked(reason)
        }
    }

    static func requiredHardwareEvidenceBlockReason(
        submission: AutotuneHardwareEvidenceSubmission,
        required: Bool
    ) -> String? {
        guard required else { return nil }
        switch submission {
        case .submitted:
            return nil
        case .skipped(let reason), .failed(let reason):
            return reason
        }
    }

    /// Tolerant CSV split: trims each token and DROPS empty tokens.
    /// Use for fields where empty cells are operator-irrelevant noise.
    /// Do NOT use for FR-validated lists; use `parseCSVStrict` instead.
    static func parseCSV(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Strict CSV split for FR-validated lists. Preserves empty subsequences
    /// (so a stray comma produces an empty token) and rejects empty tokens
    /// with a clear error naming the flag. Closes round-1 audit A.4 / B.5:
    /// `parseCSV` silently dropped empty cells, allowing
    /// `--max-context-axis 4000,,8000` and `--candidate-models a,,b` to
    /// parse as 2-element lists instead of throwing.
    static func parseCSVStrict(_ raw: String, flag: String) throws -> [String] {
        let tokens = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for token in tokens {
            if token.isEmpty {
                throw ValidationError("\(flag) contains an empty cell; check for stray commas")
            }
        }
        return tokens
    }

    static func parseSizeB(_ raw: String) throws -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixStripped: String
        if trimmed.lowercased().hasSuffix("b") {
            suffixStripped = String(trimmed.dropLast())
        } else {
            suffixStripped = trimmed
        }
        guard let value = Double(suffixStripped), value > 0 else {
            throw ValidationError("model size must be a positive value like 7B")
        }
        return value
    }

    static func parseKvBitsAxis(_ raw: String) throws -> [Int?] {
        let cells = try parseCSVStrict(raw, flag: "--kv-bits-axis")
        guard !cells.isEmpty else {
            throw ValidationError("--kv-bits-axis must contain at least one cell")
        }
        return try cells.map { cell in
            if cell.lowercased() == "unset" {
                return nil
            }
            guard let value = Int(cell), value == 4 || value == 8 else {
                throw ValidationError("--kv-bits-axis cells must be unset, 4, or 8")
            }
            return value
        }
    }

    static func parsePositiveIntAxis(_ raw: String, flag: String) throws -> [Int] {
        let cells = try parseCSVStrict(raw, flag: flag)
        guard !cells.isEmpty else {
            throw ValidationError("\(flag) must contain at least one cell")
        }
        return try cells.map { cell in
            guard let value = Int(cell), value > 0 else {
                throw ValidationError("\(flag) cells must be positive integers")
            }
            return value
        }
    }

    static func parseMaxContextAxis(_ raw: String, targetContext: Int) throws -> [Int] {
        // Empty raw value (the default) maps to a single cell at --target-context
        // per FR-B.1's "empty default treated as [--target-context]" rule. We
        // check the raw form here so a literal empty string is OK while a
        // stray-comma form like "," or "4000,,8000" still fails strict parse.
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [targetContext]
        }
        let cells = try parseCSVStrict(raw, flag: "--max-context-axis")
        let values = try cells.map { cell in
            guard let value = Int(cell), value > 0 else {
                throw ValidationError("--max-context-axis cells must be positive integers")
            }
            guard value >= targetContext else {
                throw ValidationError("--max-context-axis cell \(value) is below --target-context \(targetContext)")
            }
            return value
        }.sorted()
        guard Set(values).count == values.count else {
            throw ValidationError("--max-context-axis must not contain duplicate cells")
        }
        return values
    }

    static func donorModeApplyWarning(for selectedModel: String) -> String {
        "DONOR MODE: \(selectedModel) does not meet rate-card or hardware requirements on this Mac."
    }
}

struct AutotuneCandidate: Equatable {
    let modelID: String
    let sizeB: Double
}

struct AutotunePlan: Equatable {
    enum Source: Equatable, CustomStringConvertible {
        case defaultList
        case explicit

        var description: String {
            switch self {
            case .defaultList:
                return "largest-first default list"
            case .explicit:
                return "operator-supplied order"
            }
        }
    }

    let candidates: [String]
    let source: Source
    let warning: String?
}

struct AutotuneStage1Request {
    var db: AutotuneDB
    var runID: String
    var candidates: [String]
    var candidatesBySize: [String]?
    var targetContext: Int
    var gateTTFTMS: Int
    var stage1Replicates: Int
    var port: Int
    var drainGrace: Int
    var cancellationReason: () -> AutotuneCancellationReason?
}

struct AutotuneStage2Request {
    var db: AutotuneDB
    var runID: String
    var selectedModel: String
    var kvBitsAxis: [Int?]
    var maxBatchAxis: [Int]
    var maxContextAxis: [Int]
    var targetContext: Int
    var gateTTFTMS: Int
    var stage2Replicates: Int
    var tpsTieEpsilon: Double
    var port: Int
    var drainGrace: Int
    var cancellationReason: () -> AutotuneCancellationReason?
}

enum FreshRecommendationEvidenceOutcome: Equatable {
    case ready(submitted: Bool)
    case rerunRecommendation(String)
    case blocked(String)
}

struct AutotuneRunDependencies {
    var now: () -> Date
    var makeRunID: () -> String
    var makeInterruptFlag: () -> AutotuneInterruptFlag
    var installSignalSources: (AutotuneInterruptFlag) -> AnyObject?
    var machineFingerprint: () -> MachineFingerprint
    var makeDB: (String) throws -> AutotuneDB
    var detectConflict: () throws -> ProviderConflict
    var drainConflict: (ProviderConflict, Int, TimeInterval) throws -> ProviderDrainResult
    var restoreConflict: (ProviderConflict, Bool) throws -> ProviderRestoreResult
    var runStage1: (AutotuneStage1Request) async throws -> Stage1IteratorResult
    var runStage2: (AutotuneStage2Request) async throws -> Stage2HillClimbResult
    var emitRecommendation: (RecommendationInputs) throws -> EmittedRecommendation
    var applyConfig: (RecommendationCore, Date, String?) throws -> ConfigApplier.AppliedConfig
    var writeStdout: (String) -> Void
    var writeStderr: (String) -> Void

    static var production: AutotuneRunDependencies {
        AutotuneRunDependencies(
        now: Date.init,
        makeRunID: { UUID().uuidString },
        makeInterruptFlag: AutotuneInterruptFlag.init,
        installSignalSources: { AutotuneSignalSources(flag: $0) },
        machineFingerprint: { MachineFingerprinter().sample() },
        makeDB: { try AutotuneDB(path: $0) },
        detectConflict: { try ProviderConflictDetector().detect() },
        drainConflict: { conflict, port, grace in
            try ProviderDrainer().drain(conflict, port: port, graceSeconds: grace)
        },
        restoreConflict: { conflict, restartForeground in
            try ProviderDrainer().restore(conflict, restartForeground: restartForeground)
        },
        runStage1: { request in
            try await Stage1Iterator(
                candidateProviderRunner: { try CandidateProviderRunner() },
                providerPreWarmer: ProviderPreWarmer(stopGraceSeconds: Double(request.drainGrace)),
                autotuneDB: request.db,
                runID: request.runID,
                candidates: request.candidates,
                candidatesBySize: request.candidatesBySize,
                targetContext: request.targetContext,
                gateTTFTMS: request.gateTTFTMS,
                stage1Replicates: request.stage1Replicates,
                port: request.port,
                prober: Stage1Prober(stopGraceSeconds: Double(request.drainGrace)),
                cancellationReason: request.cancellationReason
            ).run()
        },
        runStage2: { request in
            try await Stage2HillClimb(
                candidateProviderRunner: { try CandidateProviderRunner() },
                prober: Stage2Prober(stopGraceSeconds: Double(request.drainGrace)),
                autotuneDB: request.db,
                selectedModel: request.selectedModel,
                kvBitsAxis: request.kvBitsAxis,
                maxBatchAxis: request.maxBatchAxis,
                maxContextAxis: request.maxContextAxis,
                targetContext: request.targetContext,
                gateTTFTMS: request.gateTTFTMS,
                stage2Replicates: request.stage2Replicates,
                tpsTieEpsilon: request.tpsTieEpsilon,
                port: request.port,
                runID: request.runID,
                cancellationReason: request.cancellationReason
            ).run()
        },
        emitRecommendation: { try RecommendationEmitter().build($0) },
        applyConfig: { recommendation, now, configPath in
            let rawPath = configPath ?? AppConfig.defaultConfigPath
            let expanded = ConfigLoader.expandTilde(rawPath)
            return try ConfigApplier(configPath: URL(fileURLWithPath: expanded)).apply(
                recommendation: recommendation,
                now: now
            )
        },
        writeStdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
        writeStderr: { FileHandle.standardError.write(Data($0.utf8)) }
        )
    }
}
