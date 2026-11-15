#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MLX
import MacProviderCore

/// `multi-model-bench --check`: the single check command of the #2338 swarm
/// run (scratchpad/swarm-brief-2338-gpu-sharing.md).
///
/// A lane is one row of one model: it serves that model's fixed prompts one
/// after another, starting at its own offset, until the phase deadline, then
/// finishes its in-flight request. Phases: an unmeasured `warmup` (one
/// request per model, alone), `solo-a`, `solo-b`, a `reference`
/// pre-pass that serves once, alone, every prompt index the solo phases did
/// not reach, `contended` (both models), and an optional `soak`.
///
/// Each runtime is constructed the way `serve` builds one: paged KV on with
/// the family defaults, the continuous-batching mode explicitly configured
/// (`--cb-x`, as `serve --continuous-batching` does) and max batch = rows,
/// bound to the catalog serving id (`--model-id-x`) and loaded from the
/// snapshot (`--model-x`). Mixed-cache models (GLM-5.3-Flash, Qwen3.6/3.8)
/// attach paged KV, and so batch, only under their exact serving id.
/// Rows: serve's CB self-check decides how many rows a model serves; the
/// check drives the rows it granted (`MultiModelCheckRowShape`), records the
/// requested and granted rows and the self-check reason in the JSON and on
/// the POLICY and GOAL lines, and judges its floors on that shape.
/// `--rows-exact` instead requires the requested rows, for a cell that is
/// about a row count. A model whose engine is not the one its granted rows
/// imply (rows > 1 on a serialized engine), that serves no row, or whose
/// scheduler never batched two of its granted rows, is a `CHECK error`,
/// never a GOAL.
/// Native MTP is not offered: the production load admits it only through a
/// signed admission sidecar, and this harness has no lab path around that.
///
/// One interval rule for every measured phase: tokens arriving between ramp
/// end (`rampSeconds`) and the phase deadline, over that wall time. In
/// `contended` and `soak` both models must have a request in flight for at
/// least `minimumOverlap` of the interval, else `CHECK error not_overlapped`.
/// Tokens are placed on chunk arrival times in order: exact when chunks
/// equal completion tokens, proportional otherwise (recorded per phase).
///
/// stdout ends with `GATE pass|fail ...` then `GOAL policy=<spec> share=...`. Exit codes:
/// 0 pass, 2 gate fail, 3 hang, 1 when the check cannot run.
///
/// Policies: without `--gpu-turn-policies` every phase runs under the one
/// selected policy. With `--gpu-turn-policies a;b;...` load, warmup, solo and
/// reference phases run once under passthrough. Either way each policy then
/// runs its own contended phase and, with `--soak-seconds`, its own soak, and
/// prints one `POLICY` line (contended numbers) and one `SOAK` line; the
/// final `GATE` line is the aggregate of every policy (fail names each failed
/// policy and its first reason) and `GOAL` is the first listed policy's. GOAL uses the soak when
/// one ran (a 60 s window is alignment-sensitive), else the contended phase.
/// Exit 2 when any policy fails its gate.
///
/// Gate floors (`MultiModelCheckFloors`): a measured interval with zero
/// tokens, a zero or missing rate, no request completed before the phase
/// deadline, a non-passthrough policy whose arbiter recorded no wait at all,
/// and any output compared as text instead of token ids each fail the gate.
///
/// `share` counts decode tokens only; `work_share` also credits prefill (see
/// `MultiModelCheckWork` and `--help` for the formula).
///
/// Watchdog: per model (`MultiModelCheckWatchdog`); exit 3 names the model.
enum MultiModelCheck {
    static let rampSeconds: Double = 10
    /// Shorter phases read about 7% high and cannot complete a 1024-token main request.
    static let minimumPhaseSeconds: Double = 120
    static let minimumOverlap = 0.95
    /// Upper bound on waiting for serve's CB self-check decision at load.
    static let selfCheckBoundSeconds: Double = 1800
    static let promptsPerModel = 8
    static let schema = "macprovider.multi-model-bench.check.v2"

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func seconds(_ nanos: UInt64, since start: UInt64) -> Double {
        nanos >= start ? Double(nanos - start) / 1e9 : -Double(start - nanos) / 1e9
    }

    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
        MultiModelBenchCommand.log(line)
    }

    static let gitSHAFileName = "GIT_SHA"
    static let gitSHAEnvironmentKey = "MACPROVIDER_BUILD_GIT_SHA"

    /// The build's git SHA: `MACPROVIDER_BUILD_GIT_SHA`, else the first
    /// `GIT_SHA` file found in the working directory, its parent, or the
    /// executable's directory and up to four of its ancestors (a lab build at
    /// `<src>/phase3-binary/.build/release/` finds `<src>/GIT_SHA`), else
    /// `unknown`. Only a 7-64 character hex string counts.
    static func buildGitSHA(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        executableDirectory: String? = Bundle.main.executableURL?.deletingLastPathComponent().path
    ) -> String {
        func valid(_ raw: String?) -> String? {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  (7...64).contains(value.count),
                  value.allSatisfy({ $0.isHexDigit })
            else { return nil }
            return value
        }
        if let sha = valid(environment[gitSHAEnvironmentKey]) { return sha }
        var directories = [URL(fileURLWithPath: currentDirectory)]
        directories.append(directories[0].deletingLastPathComponent())
        if let executableDirectory {
            var directory = URL(fileURLWithPath: executableDirectory)
            for _ in 0...4 {
                directories.append(directory)
                directory = directory.deletingLastPathComponent()
            }
        }
        for directory in directories {
            let path = directory.appendingPathComponent(gitSHAFileName).path
            if let data = FileManager.default.contents(atPath: path), let sha = valid(String(data: data, encoding: .utf8)) {
                return sha
            }
        }
        return "unknown"
    }
}

/// One contended (and soak) run: the spec printed on its lines and the
/// policy the arbiter is set to.
struct MultiModelCheckPolicyRun: Sendable {
    let spec: String
    let policy: any GPUTurnPolicy

    var recorded: MultiModelCheckPolicySpec {
        MultiModelCheckPolicySpec(spec: spec, name: policy.name, parameters: policy.parameters, alwaysProceeds: policy.alwaysProceeds)
    }

    /// `name[:k=v,...]` with the policy's full parameter set, sorted.
    static func label(_ policy: any GPUTurnPolicy) -> String {
        let parameters = policy.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return parameters.isEmpty ? policy.name : "\(policy.name):\(parameters.joined(separator: ","))"
    }
}

extension MultiModelBenchCommand {
    func runCheck() async throws {
        let nonce = String(UUID().uuidString.prefix(8).lowercased())
        let capturePath = Self.prepareTokenCapture(nonce: nonce)
        let firstFamily = ModelRuntime.localModelFamily(modelA)
        let appliedBudgetMB = firstFamily.flatMap { ModelRuntime.applyMLXCommandBufferBudget(modelFamily: $0) }
        let promptTokensBySlot: [MultiModelBenchSlot: Int] = [.a: promptTokensA ?? promptTokens, .b: promptTokensB ?? promptTokens]
        let basePrompts = promptTokensBySlot.mapValues { Self.promptText(promptTokens: $0) }
        // SPEC-001-R018: the lab selects the GPU turn policy both runtimes
        // share; an invalid flag or env value fails the check before any load.
        let gpuTurnSelection: (policy: any GPUTurnPolicy, source: String)
        // --gpu-turn-policies: everything before the first policy's contended
        // phase runs under passthrough; the list replaces the env selection.
        var policyList: [MultiModelCheckPolicySpec]?
        // What the contended/soak phases run: the list, or the one selection.
        let policyRuns: [MultiModelCheckPolicyRun]
        do {
            if let gpuTurnPolicies {
                let specs = try Self.parsePolicyList(gpuTurnPolicies)
                let runs = try specs.map { MultiModelCheckPolicyRun(spec: $0, policy: try GPUTurnPolicyRegistry.make($0)) }
                policyList = runs.map(\.recorded)
                policyRuns = runs
                gpuTurnSelection = (try GPUTurnPolicyRegistry.make("passthrough"), "policies_list_prepass")
            } else {
                gpuTurnSelection = try GPUTurnPolicyRegistry.labSelection(
                    flag: gpuTurnPolicy, environment: ProcessInfo.processInfo.environment
                ) ?? (GPUTurnPolicyRegistry.compiledDefault, "default")
                policyRuns = [MultiModelCheckPolicyRun(spec: MultiModelCheckPolicyRun.label(gpuTurnSelection.policy), policy: gpuTurnSelection.policy)]
            }
        } catch {
            MultiModelCheck.emit("CHECK error reason=gpu_turn_policy_invalid detail=\"\(error)\"")
            throw ExitCode(1)
        }
        GPUTurnArbiter.shared.setPolicy(gpuTurnSelection.policy)
        let labEnv = ProcessInfo.processInfo.environment
        MultiModelBenchCommand.log("lab_mlx max_ops_per_buffer=\(labEnv["MLX_MAX_OPS_PER_BUFFER"] ?? "unset") max_mb_per_buffer=\(labEnv["MLX_MAX_MB_PER_BUFFER"] ?? "unset")")
        MultiModelBenchCommand.log("gpu_turn_policy name=\(gpuTurnSelection.policy.name) parameters=\(gpuTurnSelection.policy.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")) source=\(gpuTurnSelection.source)")
        let config = MultiModelCheckConfig(
            modelA: modelA,
            modelB: modelB,
            modelIDA: modelIDA ?? modelA,
            modelIDB: modelIDB ?? modelB,
            rowsA: rowsA,
            rowsB: rowsB,
            rowsExact: rowsExact,
            continuousBatchingA: cbA,
            continuousBatchingB: cbB,
            maxTokensA: maxTokensA,
            maxTokensB: maxTokensB,
            promptTokensTarget: promptTokens,
            promptTokensTargetA: promptTokensBySlot[.a]!,
            promptTokensTargetB: promptTokensBySlot[.b]!,
            promptsPerModel: MultiModelCheck.promptsPerModel,
            phaseSeconds: phaseSeconds,
            soakSeconds: soakSeconds,
            rampSeconds: MultiModelCheck.rampSeconds,
            watchdogSeconds: watchdogSeconds,
            loadOrder: ["a", "b"],
            temperature: 0,
            topP: 1,
            stream: true,
            tokenCapturePath: capturePath,
            gpuTurnPolicy: MultiModelCheckGPUTurnPolicy(
                name: gpuTurnSelection.policy.name,
                parameters: gpuTurnSelection.policy.parameters,
                source: gpuTurnSelection.source
            ),
            gpuTurnPolicies: policyList
        )
        let report = MultiModelCheckReport(
            schema: MultiModelCheck.schema,
            generatedAtUnixSeconds: Date().timeIntervalSince1970,
            host: MultiModelBenchHost.current(),
            binaryVersion: CoordinatorClient.binaryVersion,
            gitSha: MultiModelCheck.buildGitSHA(),
            config: config,
            processEnvironment: MultiModelBenchProcessEnvironment(
                firstLoadedModelFamily: firstFamily,
                commandBufferBudgetAppliedMb: appliedBudgetMB,
                mlxMaxMbPerBuffer: ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"]
            )
        )
        let box = MultiModelCheckReportBox(report: report, outPath: out)
        box.write()
        let monitor = MultiModelBenchMonitor(
            outPath: nil,
            watchdogSeconds: watchdogSeconds,
            stallProbe: { limit in box.stalledModel(now: MultiModelCheck.now(), limitSeconds: limit) }
        ) { phase, model, idle, footprint in
            box.hang(phase: phase, model: model, secondsSinceLastChunk: idle, footprintMax: footprint)
        }
        monitor.start()
        defer { monitor.stop() }
        do {
            let serve = try MultiModelCheckServeSettings.resolve(configPath: configPath)
            let runner = MultiModelCheckRunner(config: config, serve: serve, basePrompts: basePrompts, policyRuns: policyRuns, nonce: nonce, box: box, monitor: monitor)
            try await runner.run()
        } catch let failure as MultiModelCheckFailure {
            box.update { $0.error = failure.reason }
            box.emit("CHECK error reason=\(failure.reason)")
            box.write()
            throw ExitCode(1)
        } catch let exit as ExitCode {
            throw exit
        } catch {
            let reason = "error detail=\(String(describing: error).replacingOccurrences(of: "\n", with: " "))"
            box.update { $0.error = reason }
            box.emit("CHECK error reason=\(reason)")
            box.write()
            throw ExitCode(1)
        }
    }
}

struct MultiModelCheckFailure: Error {
    let reason: String
}

// MARK: - Runner

struct MultiModelCheckRunner: Sendable {
    let config: MultiModelCheckConfig
    let serve: MultiModelCheckServeSettings
    let basePrompts: [MultiModelBenchSlot: String]
    let policyRuns: [MultiModelCheckPolicyRun]
    let nonce: String
    let box: MultiModelCheckReportBox
    let monitor: MultiModelBenchMonitor
    /// SPEC-001-R018: arbiter statistics per phase, by slot.
    let gpuTurns = MultiModelCheckGPUTurnWindow()
    /// SPEC-001-R017: shared memory budget per phase, by slot.
    let memoryBudget = MultiModelCheckMemoryBudgetWindow()
    /// The rows each model is driven with, set at its load.
    let rowShapes = MultiModelCheckRowShapes()

    func run() async throws {
        for (slot, path) in [(MultiModelBenchSlot.a, config.modelA), (.b, config.modelB)] {
            try Self.requireModelDirectory(slot: slot, value: path)
        }
        var runtimes: [MultiModelBenchSlot: ModelRuntime] = [:]
        for slot in MultiModelBenchSlot.allCases {
            runtimes[slot] = try await load(slot)
            gpuTurns.bind(slot: slot, participantID: runtimes[slot]!.gpuTurnParticipant.id)
            memoryBudget.bind(slot: slot, memberID: runtimes[slot]!.memoryBudgetMemberID)
        }
        var requests: [MultiModelBenchSlot: [ChatCompletionRequest]] = [:]
        for slot in MultiModelBenchSlot.allCases {
            let modelID = slot == .a ? config.modelIDA : config.modelIDB
            let maxTokens = slot == .a ? config.maxTokensA : config.maxTokensB
            requests[slot] = try (0..<config.promptsPerModel).map { index in
                try MultiModelBenchCommand.request(
                    modelID: modelID,
                    prompt: "Request \(index + 1) of \(config.promptsPerModel). " + basePrompts[slot]!,
                    maxTokens: maxTokens
                )
            }
        }
        let lanes = MultiModelCheckLanes(runtimes: runtimes, requests: requests, nonce: nonce, capturePath: config.tokenCapturePath, monitor: monitor, box: box)

        // A runtime's first request can take far longer than the ramp
        // (observed 34 s to first token on a cold second runtime), so each
        // model serves one unmeasured request alone before solo-a.
        _ = try await runSequential(.warmup, MultiModelBenchSlot.allCases.map { ($0, 0) }, lanes: lanes)
        let soloA = try await runPhase(.soloA, seconds: config.phaseSeconds, lanes: lanes)
        let soloB = try await runPhase(.soloB, seconds: config.phaseSeconds, lanes: lanes)
        var references: [MultiModelBenchSlot: [Int: MultiModelCheckRequestRecord]] = [.a: [:], .b: [:]]
        // References come from the solo phases and the pre-pass, which both
        // run the model's own row count; the warmup (one row) never does.
        for record in soloA.requests + soloB.requests {
            let slot = MultiModelBenchSlot(rawValue: record.model)!
            if references[slot]![record.promptIndex] == nil { references[slot]![record.promptIndex] = record }
        }
        var missing: [MultiModelBenchSlot: [Int]] = [:]
        for slot in MultiModelBenchSlot.allCases {
            missing[slot] = (0..<config.promptsPerModel).filter { references[slot]![$0] == nil }
        }
        let referencePass = try await runReferencePass(missing, lanes: lanes)
        for record in referencePass.requests where !record.filler {
            references[MultiModelBenchSlot(rawValue: record.model)!]![record.promptIndex] = record
        }
        box.update { report in
            report.references = MultiModelBenchSlot.allCases.flatMap { slot in
                references[slot]!.keys.sorted().map { MultiModelCheckReference(slot: slot, record: references[slot]![$0]!) }
            }
        }
        box.write()

        try await runPolicies(policyRuns, soloA: soloA, soloB: soloB, references: references, lanes: lanes)
    }

    /// One contended phase per policy and, with `--soak-seconds`, one soak
    /// per policy, each judged against the shared solo references and solo
    /// denominators. A phase returns only after every lane's in-flight
    /// request finished, so no request crosses into the next policy. A policy
    /// whose phase cannot be measured (e.g. a starved model completes
    /// nothing) fails its gate and the run goes on to the next policy.
    private func runPolicies(
        _ policies: [MultiModelCheckPolicyRun],
        soloA: MultiModelCheckPhaseResult,
        soloB: MultiModelCheckPhaseResult,
        references: [MultiModelBenchSlot: [Int: MultiModelCheckRequestRecord]],
        lanes: MultiModelCheckLanes
    ) async throws {
        let sharedPhases = box.snapshot().phases
        let listed = config.gpuTurnPolicies != nil
        var gateResults: [(spec: String, gate: MultiModelCheckGate)] = []
        var parityChecked = 0
        var parityMismatches: [MultiModelCheckMismatch] = []
        // GOAL is the first listed policy's (the baseline).
        var baselineGoal: MultiModelCheckGoal?
        var goalLine = ""
        for (index, entry) in policies.enumerated() {
            let policy = entry.policy
            GPUTurnArbiter.shared.setPolicy(policy)
            MultiModelBenchCommand.log("gpu_turn_policy index=\(index) spec=\(entry.spec) name=\(policy.name) parameters=\(MultiModelCheckPolicyRun.label(policy)) source=\(listed ? "policies_list" : config.gpuTurnPolicy.source)")
            let firstPhaseIndex = box.snapshot().phases.count
            let tag: (index: Int, spec: String) = (index, entry.spec)
            var failure: String?
            do {
                _ = try await runPhase(.contended, seconds: config.phaseSeconds, lanes: lanes, policy: tag)
                if config.soakSeconds > 0 {
                    _ = try await runPhase(.soak, seconds: config.soakSeconds, lanes: lanes, policy: tag)
                }
            } catch let exit as ExitCode {
                throw exit
            } catch let check as MultiModelCheckFailure {
                failure = check.reason
            } catch {
                failure = "error detail=\(String(describing: error).replacingOccurrences(of: "\n", with: " "))"
            }
            let policyPhases = Array(box.snapshot().phases[firstPhaseIndex...])
            // A phase that failed its post-run checks still recorded its stats.
            let measured = policyPhases.filter(\.completed)
            var outcome = Self.gate(checked: measured, references: references, report: box.snapshot(), memoryPhases: sharedPhases + policyPhases)
            if let failure { outcome.reasons.insert("check_error \(failure)", at: 0) }
            let contended = measured.first { $0.phase == MultiModelCheckPhase.contended.rawValue }
            let soak = measured.first { $0.phase == MultiModelCheckPhase.soak.rawValue }

            // Floors: every measured interval has tokens and a rate, every
            // model completed a request before the deadline, the policy was
            // exercised, and outputs were compared as token ids.
            var floorInputs: [MultiModelCheckFloors.Measured] = [
                .init(phase: MultiModelCheckPhase.soloA.rawValue, model: "a", stats: soloA.a),
                .init(phase: MultiModelCheckPhase.soloB.rawValue, model: "b", stats: soloB.b),
            ]
            var waitInputs: [MultiModelCheckFloors.Waits] = []
            for phase in [contended, soak].compactMap({ $0 }) {
                floorInputs.append(.init(phase: phase.phase, model: "a", stats: phase.a))
                floorInputs.append(.init(phase: phase.phase, model: "b", stats: phase.b))
                waitInputs.append(.init(phase: phase.phase, totalWaitSeconds: phase.gpuTurns.map { $0.participants.reduce(0) { $0 + $1.arbiter.waitSeconds } }))
            }
            outcome.reasons += MultiModelCheckFloors.reasons(
                measured: floorInputs,
                policy: policy.name,
                policyAlwaysProceeds: policy.alwaysProceeds,
                waits: waitInputs,
                comparisons: outcome.outputComparison
            )

            let contendedGoal = contended.map { Self.goal(soloA: soloA, soloB: soloB, measured: $0) }
            let soakGoal = soak.map { Self.goal(soloA: soloA, soloB: soloB, measured: $0) }
            if contended == nil {
                outcome.reasons.append("goal_unavailable no_contended_phase")
            } else if contendedGoal?.goal == nil {
                outcome.reasons.append("goal_unavailable phase=contended \(contendedGoal?.unavailable ?? "")")
            }
            if config.soakSeconds > 0 {
                if soak == nil {
                    outcome.reasons.append("goal_unavailable no_soak_phase")
                } else if soakGoal?.goal == nil {
                    outcome.reasons.append("goal_unavailable phase=soak \(soakGoal?.unavailable ?? "")")
                }
            }
            // GOAL uses the soak when one was asked for; a soak that could not
            // be measured leaves no GOAL rather than falling back silently.
            let goal = config.soakSeconds > 0 ? soakGoal?.goal : contendedGoal?.goal

            if let first = outcome.reasons.first {
                let more = outcome.reasons.count > 1 ? " (+\(outcome.reasons.count - 1) more in JSON)" : ""
                outcome.line = "GATE fail reason=\(first)\(more)"
            }
            let pass = outcome.reasons.isEmpty
            let waits = Self.waits(contended)
            let wired = Self.footprintOverWired(phases: sharedPhases + policyPhases)
            let contendedMetrics = MultiModelCheckGoal.metrics(contendedGoal?.goal, measured: contended)
            let gatePart = String(outcome.line.dropFirst("GATE ".count))
            let shapes = rowShapes.all
            let line = "POLICY \(entry.spec) \(gatePart) \(contendedMetrics) a_wait_s=\(MultiModelCheckGoal.fmt(waits["a"], "%.3f")) b_wait_s=\(MultiModelCheckGoal.fmt(waits["b"], "%.3f")) wired_limit_bytes=\(wired.wiredLimitBytes.map(String.init) ?? "n/a") footprint_over_wired_bytes=\(wired.overBytes.map(String.init) ?? "n/a") \(MultiModelCheckRowShape.lineFields(shapes))"
            var soakLine: String?
            if config.soakSeconds > 0 {
                let soakWaits = Self.waits(soak)
                let soakMetrics = MultiModelCheckGoal.metrics(soakGoal?.goal, measured: soak)
                soakLine = "SOAK \(entry.spec) \(soakMetrics) a_wait_s=\(MultiModelCheckGoal.fmt(soakWaits["a"], "%.3f")) b_wait_s=\(MultiModelCheckGoal.fmt(soakWaits["b"], "%.3f"))"
            }
            let minFrac = contendedGoal?.goal.map { min($0.aFrac, $0.bFrac) }
            let result = MultiModelCheckPolicyResult(
                spec: entry.spec,
                policy: policy.name,
                policyParameters: policy.parameters,
                policyAlwaysProceeds: policy.alwaysProceeds,
                phases: policyPhases.map(\.phase),
                gate: MultiModelCheckGate(pass: pass, reasons: outcome.reasons, line: outcome.line),
                goal: goal,
                contendedGoal: contendedGoal?.goal,
                soakGoal: soakGoal?.goal,
                minFrac: minFrac,
                mainTtftMsP95: contended?.a?.ttftMsP95,
                workerTtftMsMedian: contended?.b?.ttftMsMedian,
                aWaitSeconds: waits["a"],
                bWaitSeconds: waits["b"],
                wiredLimitBytes: wired.wiredLimitBytes,
                footprintOverWiredBytes: wired.overBytes,
                parityChecked: outcome.checked,
                parityMismatches: outcome.mismatches,
                gpuTurns: policyPhases.compactMap(\.gpuTurns),
                memoryBudget: policyPhases.compactMap(\.memoryBudget),
                line: line,
                soakLine: soakLine
            )
            box.update { report in
                report.policies.append(result)
                report.outputComparison = outcome.outputComparison
            }
            box.emit(line)
            if let soakLine { box.emit(soakLine) }
            box.write()
            gateResults.append((entry.spec, result.gate))
            parityChecked += outcome.checked
            parityMismatches += outcome.mismatches
            if index == 0 {
                baselineGoal = goal
                goalLine = Self.goalLine(spec: entry.spec, goal: goal, reasons: outcome.reasons, rowShapes: shapes)
            }
        }
        // The final GATE and the top-level JSON gate cover every policy; GOAL
        // is the baseline's. Exit 2 when any policy failed.
        let aggregate = Self.aggregateGate(gateResults)
        await recordRuntimeEnds(lanes.runtimes)
        box.update { report in
            report.parityChecked = parityChecked
            report.parityMismatches = parityMismatches
            report.gate = aggregate
            report.goal = baselineGoal
            report.complete = true
        }
        box.emit(aggregate.line)
        box.emit(goalLine)
        box.write()
        if !aggregate.pass { throw ExitCode(2) }
    }

    /// Pure. `GATE pass`, or a fail naming every failed policy and its first
    /// reason; the first failed policy's reason leads the line.
    static func aggregateGate(_ results: [(spec: String, gate: MultiModelCheckGate)]) -> MultiModelCheckGate {
        let failed = results.filter { !$0.gate.pass }
        guard let lead = failed.first else {
            return MultiModelCheckGate(pass: true, reasons: [], line: "GATE pass")
        }
        func first(_ gate: MultiModelCheckGate) -> String { gate.reasons.first ?? "unspecified" }
        var line = "GATE fail policies=\(failed.map(\.spec).joined(separator: "|")) reason=\(first(lead.gate))"
        for other in failed.dropFirst() { line += " other_policy=\(other.spec) other_reason=\(first(other.gate))" }
        let reasons = failed.flatMap { entry in entry.gate.reasons.map { "policy=\(entry.spec) \($0)" } }
        return MultiModelCheckGate(pass: false, reasons: reasons, line: line)
    }

    /// Pure. The GOAL line names the policy it measured and ends with the
    /// rows each model was driven with.
    static func goalLine(spec: String, goal: MultiModelCheckGoal?, reasons: [String], rowShapes: [MultiModelCheckRowShape] = []) -> String {
        let rows = rowShapes.isEmpty ? "" : " " + MultiModelCheckRowShape.lineFields(rowShapes)
        if let goal { return "GOAL policy=\(spec) " + String(goal.line.dropFirst("GOAL ".count)) + rows }
        return "GOAL policy=\(spec) unavailable reason=\(reasons.first { $0.hasPrefix("goal_unavailable") } ?? "see_json")" + rows
    }

    /// Pure, information only (never a failing condition): the wired limit and
    /// the largest process footprint above it across the phases.
    static func footprintOverWired(phases: [MultiModelCheckPhaseResult]) -> (wiredLimitBytes: Int?, overBytes: Int?) {
        var wired: Int?
        var over: Int?
        for phase in phases {
            guard let limit = phase.memoryBudget?.wiredLimitBytes, limit > 0 else { continue }
            wired = limit
            guard let footprint = phase.physFootprintMaxBytes else { continue }
            let excess = footprint > UInt64(limit) ? Int(footprint - UInt64(limit)) : 0
            over = max(over ?? 0, excess)
        }
        return (wired, over)
    }

    /// Arbiter wait seconds per slot over one phase.
    static func waits(_ phase: MultiModelCheckPhaseResult?) -> [String: Double] {
        Dictionary(
            (phase?.gpuTurns?.participants ?? []).compactMap { p in p.model.map { ($0, p.arbiter.waitSeconds) } },
            uniquingKeysWith: +)
    }

    private func recordRuntimeEnds(_ runtimes: [MultiModelBenchSlot: ModelRuntime]) async {
        for slot in MultiModelBenchSlot.allCases {
            let snapshot = await runtimes[slot]!.currentSnapshot()
            box.update { report in
                guard let index = report.runtimes.firstIndex(where: { $0.model == slot.rawValue }) else { return }
                report.runtimes[index].recordEnd(snapshot)
            }
        }
    }

    /// A value that names a local path must exist as a directory; anything
    /// else is treated as a model id and left to the runtime.
    static func isLocalPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix(".") || value.hasPrefix("~")
    }

    static func requireModelDirectory(slot: MultiModelBenchSlot, value: String) throws {
        guard isLocalPath(value) else { return }
        let path = (value as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MultiModelCheckFailure(reason: "missing_model_dir model=\(slot.rawValue) path=\(path)")
        }
    }

    private func load(_ slot: MultiModelBenchSlot) async throws -> ModelRuntime {
        let loadValue = slot == .a ? config.modelA : config.modelB
        // As serve: the runtime is bound to the catalog serving id and loads
        // from the snapshot path. The SPEC-039 FR-PKV12 mixed-layout allowlist
        // (ModelRuntime.pagedKVModelCapabilities) keys on that serving id, so
        // a path-bound GLM-5.3-Flash or Qwen3.8 runtime falls back with
        // `paged_fallback_cache_class` and never batches.
        let modelID = slot == .a ? config.modelIDA : config.modelIDB
        let modelLoadPath: String? = modelID == loadValue ? nil : loadValue
        MultiModelBenchCommand.log("load start model=\(slot.rawValue) id=\(modelID) load_path=\(modelLoadPath ?? "nil")")
        let started = Date()
        let rows = rows(slot)
        let mode = ContinuousBatchingMode(rawValue: slot == .a ? config.continuousBatchingA : config.continuousBatchingB) ?? .on
        // As serve: paged KV attaches by default with the family block size,
        // sized to the advertised context (MacProviderCLI.swift serve path).
        let pagedKV = serve.pagedKV
            .withFamilyDefaults(modelFamily: ModelRuntime.localModelFamily(loadValue) ?? "")
            .sizedToCover(contextTokens: ProviderCapacity(maxContextOverride: serve.maxContextOverride, maxConcurrencyOverride: nil).maxContextTokens)
        // Serve passes the catalog-verified snapshot-manifest hash; paged KV
        // (and so CB) attaches only with an artifact identity. A local
        // snapshot gets the same canonical hash the catalog records.
        let artifactSHA256: String?
        if Self.isLocalPath(loadValue) {
            do {
                artifactSHA256 = try ModelArtifactVerifier.canonicalArtifactHash(
                    directory: URL(fileURLWithPath: (loadValue as NSString).expandingTildeInPath))
            } catch {
                throw MultiModelCheckFailure(reason: "artifact_hash_failed model=\(slot.rawValue) detail=\(String(describing: error).replacingOccurrences(of: "\n", with: " "))")
            }
        } else {
            artifactSHA256 = nil
        }
        // SPEC-001-R017 *Load*: the shared budget decides before any weights
        // are read, from the snapshot's safetensors sizes.
        let loadDecision = Self.loadDecision(slot: slot, loadValue: loadValue, maxContextOverride: serve.maxContextOverride)
        box.update { $0.loadDecisions.append(loadDecision) }
        box.write()
        MultiModelBenchCommand.log("load_decision model=\(slot.rawValue) admitted=\(loadDecision.decision.admitted) reason=\(loadDecision.decision.reason) required_bytes=\(loadDecision.decision.requiredBytes) limit_bytes=\(loadDecision.decision.limitBytes.map(String.init) ?? "nil")")
        guard loadDecision.decision.admitted else {
            throw MultiModelCheckFailure(reason: "insufficient_memory model=\(slot.rawValue) required_bytes=\(loadDecision.decision.requiredBytes) limit_bytes=\(loadDecision.decision.limitBytes.map(String.init) ?? "nil")")
        }
        let runtime: ModelRuntime
        do {
            runtime = try await ModelRuntime(
                modelID: modelID,
                modelLoadPath: modelLoadPath,
                mlxCacheLimitMB: serve.mlxCacheLimitMB,
                maxContextTokensOverride: serve.maxContextOverride,
                kvBitsOverride: serve.kvBitsOverride,
                familyKVQuantDefault: true,
                pagedKVConfig: pagedKV,
                prefillStepSize: serve.prefillStepSize,
                prefillStepSizeExplicitlyConfigured: serve.prefillStepSizeExplicitlyConfigured,
                maxBatch: rows,
                continuousBatchingMode: mode,
                continuousBatchQueueLimit: serve.continuousBatchQueueLimit,
                continuousBatchQueueWaitTimeoutMS: serve.continuousBatchQueueWaitTimeoutMS,
                continuousBatchPrefillTokensPerIteration: serve.continuousBatchPrefillTokensPerIteration,
                continuousBatchingCachedTurns: serve.continuousBatchingCachedTurns,
                // Serve's coverage for every non-autotune runtime.
                continuousBatchingAcceptanceCoverage: .defaultOn(revocations: []),
                continuousBatchingModeExplicitlyConfigured: true,
                nativeMTPMode: serve.nativeMTPMode,
                verifiedModelArtifactSHA256: artifactSHA256
            )
        } catch {
            throw MultiModelCheckFailure(reason: "load_failed model=\(slot.rawValue) detail=\(String(describing: error).replacingOccurrences(of: "\n", with: " "))")
        }
        guard await runtime.isLoaded else {
            throw MultiModelCheckFailure(reason: "load_failed model=\(slot.rawValue) detail=not_loaded")
        }
        let selfCheck = try await runSelfCheck(slot: slot, runtime: runtime, modelID: modelID, rows: rows, mode: mode, artifactSHA256: artifactSHA256)
        let load = MultiModelBenchLoad(
            model: slot.rawValue,
            modelID: modelID,
            modelFamily: ModelRuntime.localModelFamily(loadValue),
            loadSeconds: Date().timeIntervalSince(started),
            mlxActiveBytes: Memory.activeMemory,
            mlxPeakBytes: Memory.peakMemory,
            mlxCacheBytes: Memory.cacheMemory,
            mlxCacheLimitBytes: Memory.cacheLimit,
            mlxMemoryLimitBytes: Memory.memoryLimit,
            physFootprintBytes: MultiModelBenchMonitor.physFootprintBytes(),
            mlxMaxMbPerBuffer: ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"]
        )
        var state = MultiModelCheckRuntimeState(
            slot: slot,
            requestedMode: mode,
            rows: rows,
            snapshot: await runtime.currentSnapshot(),
            servedSlots: await runtime.servedSlotLimitForTest(),
            selfCheck: selfCheck
        )
        // The self-check's decision is the product's: drive the rows it
        // granted (or, with --rows-exact, require the requested rows).
        let shape = try MultiModelCheckRowShape.resolve(
            slot: slot, requestedRows: rows, engine: state.engine, servedSlots: state.servedSlots,
            selfCheck: selfCheck, rowsExact: config.rowsExact,
            detail: "cb_mode=\(state.continuousBatchingMode ?? "nil") cb_unsupported=\(state.continuousBatchingUnsupportedReason ?? "nil") paged_kv=\(state.pagedKvDecision ?? "nil")")
        state.requestedRows = shape.requestedRows
        state.grantedRows = shape.grantedRows
        state.selfCheckReason = shape.selfCheckReason
        rowShapes.set(slot, shape)
        box.update { report in
            report.loads.append(load)
            report.runtimes.append(state)
            report.modelArtifactSha256[slot.rawValue] = artifactSHA256
        }
        box.write()
        MultiModelBenchCommand.log("load done model=\(slot.rawValue) seconds=\(String(format: "%.1f", load.loadSeconds)) engine=\(state.engine) cb_mode=\(state.continuousBatchingMode ?? "nil") cb_active=\(state.continuousBatchingActive) paged_kv=\(state.pagedKvDecision ?? "nil") served_slots=\(state.servedSlots) native_mtp=\(state.nativeMTPModeAtLoad) memory_limit=\(load.mlxMemoryLimitBytes) \(MultiModelCheckRowShape.lineFields([shape]))")
        return runtime
    }

    static func loadDecision(slot: MultiModelBenchSlot, loadValue: String, maxContextOverride: Int?) -> MultiModelCheckLoadDecision {
        let directory = try? ModelRuntime.localModelDirectory(for: loadValue)
        let estimated = directory.map { SharedModelMemoryRules.estimatedResidentBytes(modelDirectory: $0) } ?? 0
        let perToken = MLXMemoryLimit.kvBytesPerToken(modelDirectory: directory) ?? 0
        let rowKV = MLXMemoryBudget.kvBytes(tokens: SharedModelMemoryRules.minimumRowTokens, bytesPerToken: perToken)
        return MultiModelCheckLoadDecision(
            model: slot.rawValue,
            decision: SharedModelMemoryBudget.shared.canLoad(estimatedResidentBytes: estimated, minimumRowKVBytes: rowKV))
    }

    /// Serve's default-on path: under default-on coverage the runtime serves
    /// serially until this Mac's CB self-check decides. Runs serve's own
    /// `ContinuousBatchingSelfCheckDriver` against a private ProviderStatus and
    /// a private, empty decision store (no prior grant carries over), and
    /// waits for its decision. Nil when CB is off or nothing can be checked.
    private func runSelfCheck(
        slot: MultiModelBenchSlot,
        runtime: ModelRuntime,
        modelID: String,
        rows: Int,
        mode: ContinuousBatchingMode,
        artifactSHA256: String?
    ) async throws -> MultiModelCheckSelfCheck? {
        guard mode != .off, await runtime.continuousBatchingSelfCheckTarget() != nil else { return nil }
        let status = ProviderStatus(
            modelID: modelID,
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: rows),
            modelHash: artifactSHA256
        )
        await runtime.setProviderStatus(status)
        let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macprovider-multi-model-check-\(nonce)-\(slot.rawValue)")
            .appendingPathComponent(ContinuousBatchingSelfCheckStore.fileName)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let driver = ContinuousBatchingSelfCheckDriver(
            runtime: runtime,
            providerStatus: status,
            store: ContinuousBatchingSelfCheckStore(url: storeURL),
            ownerPinnedSlots: nil,
            idleSeconds: 1,
            pollSeconds: 0.5,
            log: { MultiModelBenchCommand.log("cb_self_check model=\(slot.rawValue) \($0)") }
        )
        MultiModelBenchCommand.log("cb_self_check start model=\(slot.rawValue) max_rows=\(rows)")
        let started = Date()
        let task = Task { await driver.run() }
        var state = await runtime.continuousBatchingSelfCheckState()
        while state == .pending, Date().timeIntervalSince(started) < MultiModelCheck.selfCheckBoundSeconds {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            state = await runtime.continuousBatchingSelfCheckState()
        }
        task.cancel()
        await task.value
        let seconds = Date().timeIntervalSince(started)
        guard state != .pending else {
            throw MultiModelCheckFailure(reason: "self_check_timeout model=\(slot.rawValue) seconds=\(Int(seconds))")
        }
        let outcome: String
        let reason: String
        var grantedSlots: Int?
        switch state {
        case .granted(let slots): outcome = "granted slots=\(slots)"; reason = "granted"; grantedSlots = slots
        case .refused(let refusal): outcome = "refused reason=\(refusal)"; reason = refusal
        case .pending: outcome = "pending"; reason = "pending"
        }
        MultiModelBenchCommand.log("cb_self_check done model=\(slot.rawValue) \(outcome) seconds=\(Int(seconds))")
        return MultiModelCheckSelfCheck(outcome: outcome, reason: reason, grantedSlots: grantedSlots, seconds: seconds, storePath: storeURL.path)
    }

    // MARK: Phases

    /// The rows a model is driven with: what its load granted, else (before
    /// its load) the requested rows.
    private func rows(_ slot: MultiModelBenchSlot) -> Int {
        rowShapes.granted(slot) ?? (slot == .a ? config.rowsA : config.rowsB)
    }

    /// `policy`: the policy run (contended or soak) this phase belongs to; its
    /// index tags request ids so phases of different policies never share one.
    private func runPhase(_ phase: MultiModelCheckPhase, seconds: Double, lanes: MultiModelCheckLanes, policy: (index: Int, spec: String)? = nil) async throws -> MultiModelCheckPhaseResult {
        let started = beginPhase(phase, seconds: seconds, policySpec: policy?.spec)
        let tag = policy.map { "-p\($0.index)" } ?? ""
        let deadline = started + UInt64(seconds * 1e9)
        let rowCounts = Dictionary(uniqueKeysWithValues: phase.slots.map { ($0, rows($0)) })
        var records: [MultiModelCheckRequestRecord] = []
        do {
            records = try await withThrowingTaskGroup(of: [MultiModelCheckRequestRecord].self) { group in
                for slot in phase.slots {
                    let count = rowCounts[slot]!
                    for lane in 0..<count {
                        let offset = (lane * lanes.promptCount) / count
                        group.addTask {
                            try await lanes.runLane(phase: phase, tag: tag, slot: slot, lane: lane, offset: offset, phaseStart: started, deadline: deadline)
                        }
                    }
                }
                var all: [MultiModelCheckRequestRecord] = []
                for try await laneRecords in group { all.append(contentsOf: laneRecords) }
                return all
            }
        } catch {
            endPhase(phase, failedWith: error)
            throw error
        }
        lanes.attachOutputs(&records)
        records.sort { ($0.startSeconds, $0.model, $0.lane) < ($1.startSeconds, $1.model, $1.lane) }
        var result = finishPhase(phase, seconds: seconds, records: records, started: started)
        result.gpuTurnPolicy = policy?.spec
        let window = (MultiModelCheck.rampSeconds, seconds)
        let intervalSeconds = window.1 - window.0
        result.measurementSegments = [[window.0, window.1]]
        result.measurementIntervalSeconds = intervalSeconds
        if phase.slots.count == 2 {
            var overlap = [window]
            for slot in phase.slots {
                overlap = MultiModelCheckIntervals.intersect(overlap, MultiModelCheckIntervals.union(records.filter { $0.model == slot.rawValue }.map(\.inFlightSpan)))
            }
            result.overlapFraction = overlap.reduce(0) { $0 + ($1.1 - $1.0) } / intervalSeconds
        }
        for slot in phase.slots {
            let modelRecords = records.filter { $0.model == slot.rawValue }
            var stats = MultiModelCheckModelPhaseStats(rows: rowCounts[slot]!, records: modelRecords, segments: [window], intervalSeconds: intervalSeconds, deadlineSeconds: seconds)
            let scheduler = await lanes.runtimes[slot]!.currentSnapshot().continuousBatching?.scheduler
            stats.schedulerMaxObservedBatchDepth = scheduler?.maxObservedBatchDepth
            stats.schedulerSharedForwardCalls = scheduler?.sharedForwardCalls
            if slot == .a { result.a = stats } else { result.b = stats }
        }
        let snapshot = result
        box.update { $0.phases[$0.phases.count - 1] = snapshot }
        box.write()
        for slot in phase.slots {
            guard let stats = slot == .a ? result.a : result.b else { continue }
            // Zero tokens, zero rate or nothing completed before the deadline
            // are gate floors (MultiModelCheckFloors), judged with the policy.
            MultiModelBenchCommand.log("  \(phase.rawValue) model=\(slot.rawValue) rows=\(stats.rows) batch_depth_max=\(stats.schedulerMaxObservedBatchDepth.map(String.init) ?? "n/a") completed=\(stats.requestsCompleted) late=\(stats.requestsLate) tokens_in_interval=\(stats.tokensInInterval) prefill_tokens_in_interval=\(String(format: "%.0f", stats.promptTokensPrefilledInInterval)) prefill_s=\(String(format: "%.2f", stats.prefillSecondsInInterval)) decode_tps=\(stats.decodeTokensPerSecond.map { String(format: "%.2f", $0) } ?? "n/a") ttft_n=\(stats.ttft.n) ttft_ms_median=\(stats.ttftMsMedian.map { String(format: "%.0f", $0) } ?? "n/a") interval_s=\(String(format: "%.1f", intervalSeconds))")
        }
        guard intervalSeconds > 0 else {
            throw MultiModelCheckFailure(reason: "empty_measurement_interval phase=\(phase.rawValue)")
        }
        if let overlap = result.overlapFraction {
            MultiModelBenchCommand.log("  \(phase.rawValue) overlap_fraction=\(String(format: "%.3f", overlap))")
            guard overlap >= MultiModelCheck.minimumOverlap else {
                throw MultiModelCheckFailure(reason: "not_overlapped phase=\(phase.rawValue) overlap_fraction=\(String(format: "%.3f", overlap)) required=\(MultiModelCheck.minimumOverlap)")
            }
        }
        // A rows > 1 model whose scheduler never put two rows in one forward
        // ran serialized, whatever the load-time snapshot said.
        for slot in phase.slots where rowCounts[slot]! > 1 {
            let depth = (slot == .a ? result.a : result.b)?.schedulerMaxObservedBatchDepth ?? 0
            guard depth >= 2 else {
                throw MultiModelCheckFailure(reason: "engine_mismatch phase=\(phase.rawValue) model=\(slot.rawValue) rows=\(rowCounts[slot]!) scheduler_max_observed_batch_depth=\(depth)")
            }
        }
        return result
    }

    /// Serves each missing prompt index once per model, that model alone, on
    /// the model's own row count: `rows` lanes take indices from a shared
    /// queue, and a lane with no index left serves filler requests (excluded
    /// from references) while real ones are still decoding, so the batch the
    /// reference decoded in has the same row count as the solo phase.
    private func runReferencePass(_ missing: [MultiModelBenchSlot: [Int]], lanes: MultiModelCheckLanes) async throws -> MultiModelCheckPhaseResult {
        let started = beginPhase(.reference, seconds: 0)
        var records: [MultiModelCheckRequestRecord] = []
        do {
            for slot in MultiModelBenchSlot.allCases {
                guard let indices = missing[slot], !indices.isEmpty else { continue }
                let queue = MultiModelCheckReferenceQueue(indices)
                let count = rows(slot)
                let modelRecords = try await withThrowingTaskGroup(of: [MultiModelCheckRequestRecord].self) { group in
                    for lane in 0..<count {
                        group.addTask {
                            var laneRecords: [MultiModelCheckRequestRecord] = []
                            var sequence = 0
                            while true {
                                let promptIndex: Int
                                let filler: Bool
                                if let next = await queue.take() {
                                    promptIndex = next
                                    filler = false
                                } else if await queue.realInFlight > 0 {
                                    promptIndex = (lane + sequence) % lanes.promptCount
                                    filler = true
                                } else {
                                    break
                                }
                                var record = try await lanes.serve(phase: .reference, slot: slot, lane: lane, sequence: sequence, promptIndex: promptIndex, phaseStart: started)
                                if filler { record.filler = true } else { await queue.finished() }
                                laneRecords.append(record)
                                sequence += 1
                            }
                            return laneRecords
                        }
                    }
                    var all: [MultiModelCheckRequestRecord] = []
                    for try await laneRecords in group { all.append(contentsOf: laneRecords) }
                    return all
                }
                records.append(contentsOf: modelRecords)
            }
        } catch {
            endPhase(.reference, failedWith: error)
            throw error
        }
        lanes.attachOutputs(&records)
        let result = finishPhase(.reference, seconds: 0, records: records, started: started)
        box.update { $0.phases[$0.phases.count - 1] = result }
        box.write()
        MultiModelBenchCommand.log("  reference served=\(records.filter { !$0.filler }.count) filler=\(records.filter(\.filler).count)")
        return result
    }

    /// Serves each (model, prompt index) once, alone, one after another (the
    /// unmeasured warmup).
    private func runSequential(_ phase: MultiModelCheckPhase, _ items: [(MultiModelBenchSlot, Int)], lanes: MultiModelCheckLanes) async throws -> MultiModelCheckPhaseResult {
        let started = beginPhase(phase, seconds: 0)
        var records: [MultiModelCheckRequestRecord] = []
        do {
            for (sequence, item) in items.enumerated() {
                records.append(try await lanes.serve(phase: phase, slot: item.0, lane: 0, sequence: sequence, promptIndex: item.1, phaseStart: started))
            }
        } catch {
            endPhase(phase, failedWith: error)
            throw error
        }
        lanes.attachOutputs(&records)
        let result = finishPhase(phase, seconds: 0, records: records, started: started)
        box.update { $0.phases[$0.phases.count - 1] = result }
        box.write()
        MultiModelBenchCommand.log("  \(phase.rawValue) served=\(records.count)")
        return result
    }

    private func beginPhase(_ phase: MultiModelCheckPhase, seconds: Double, policySpec: String? = nil) -> UInt64 {
        Memory.peakMemory = 0 // setter resets MLX's peak counter
        gpuTurns.begin()
        memoryBudget.begin()
        // The watchdog's phase label names the policy, so a hang line does too.
        monitor.phaseBegan(policySpec.map { "\(phase.rawValue)[\($0)]" } ?? phase.rawValue)
        box.update { report in
            var result = MultiModelCheckPhaseResult(phase: phase.rawValue, durationSeconds: seconds)
            result.gpuTurnPolicy = policySpec
            report.phases.append(result)
        }
        box.write()
        MultiModelBenchCommand.log("phase start \(phase.rawValue) seconds=\(seconds)")
        return MultiModelCheck.now()
    }

    private func endPhase(_ phase: MultiModelCheckPhase, failedWith error: Error) {
        let footprint = monitor.phaseEnded()
        let peak = Memory.peakMemory
        box.update { report in
            let index = report.phases.count - 1
            report.phases[index].error = String(describing: error)
            report.phases[index].physFootprintMaxBytes = footprint
            report.phases[index].mlxPeakBytes = peak
            report.phases[index].gpuTurns = gpuTurns.finish()
            report.phases[index].memoryBudget = memoryBudget.finish()
        }
        box.write()
        MultiModelBenchCommand.log("phase \(phase.rawValue) failed: \(error)")
    }

    private func finishPhase(_ phase: MultiModelCheckPhase, seconds: Double, records: [MultiModelCheckRequestRecord], started: UInt64) -> MultiModelCheckPhaseResult {
        var result = MultiModelCheckPhaseResult(phase: phase.rawValue, durationSeconds: seconds)
        result.wallSeconds = MultiModelCheck.seconds(MultiModelCheck.now(), since: started)
        result.physFootprintMaxBytes = monitor.phaseEnded()
        result.mlxPeakBytes = Memory.peakMemory
        result.gpuTurns = gpuTurns.finish()
        result.memoryBudget = memoryBudget.finish()
        if let budget = result.memoryBudget {
            MultiModelBenchCommand.log("  \(phase.rawValue) memory_budget limit_bytes=\(budget.limitBytes.map(String.init) ?? "nil") wired_limit_bytes=\(budget.wiredLimitBytes.map(String.init) ?? "nil") cache_limit_bytes=\(budget.cacheLimitBytes) headroom_min_bytes=\(budget.headroomMinBytes.map(String.init) ?? "nil") refusals=\(budget.admissionRefusals) admitted_past_budget=\(budget.rowsAdmittedPastBudget) cache_clears_performed=\(budget.cacheClearsPerformed) cache_clears_skipped=\(budget.cacheClearsSkipped) \(budget.runtimes.map { "\($0.model ?? "unbound"):resident=\($0.residentBytes),committed_kv_peak=\($0.committedKVPeakBytes)" }.joined(separator: " "))")
        }
        if let stats = result.gpuTurns {
            for participant in stats.participants {
                MultiModelBenchCommand.log("  \(phase.rawValue) gpu_turns model=\(participant.model ?? "unbound") participant=\(participant.arbiter.id) turns=\(participant.arbiter.turns) decode_steps=\(participant.arbiter.decodeSteps) prefill_chunks=\(participant.arbiter.prefillChunks) busy_s=\(String(format: "%.3f", participant.arbiter.busySeconds)) wait_s=\(String(format: "%.3f", participant.arbiter.waitSeconds)) max_wait_s=\(String(format: "%.4f", participant.arbiter.maxWaitSeconds))")
            }
        }
        result.requests = records
        result.completed = true
        return result
    }

    // MARK: Gate and goal

    struct GateOutcome {
        var checked = 0
        var mismatches: [MultiModelCheckMismatch] = []
        var outputComparison: [MultiModelCheckOutputComparison] = []
        var reasons: [String] = []
        var line = "GATE pass"
    }

    static func gate(
        checked phases: [MultiModelCheckPhaseResult],
        references: [MultiModelBenchSlot: [Int: MultiModelCheckRequestRecord]],
        report: MultiModelCheckReport,
        memoryPhases: [MultiModelCheckPhaseResult]? = nil
    ) -> GateOutcome {
        let memoryPhases = memoryPhases ?? report.phases
        var outcome = GateOutcome()
        for slot in MultiModelBenchSlot.allCases {
            let all = (references[slot]!.values.map { $0 }) + phases.flatMap(\.requests).filter { $0.model == slot.rawValue }
            let ids = all.filter { $0.outputTokenIDs != nil }.count
            let kind = ids == all.count ? "token_ids" : (ids == 0 ? "text" : "mixed_token_ids_where_both_captured_else_text")
            outcome.outputComparison.append(MultiModelCheckOutputComparison(model: slot.rawValue, kind: kind))
        }
        for phase in phases {
            for record in phase.requests {
                let slot = MultiModelBenchSlot(rawValue: record.model)!
                guard let reference = references[slot]![record.promptIndex] else {
                    outcome.reasons.append("no_reference phase=\(phase.phase) model=\(record.model) prompt=\(record.promptIndex)")
                    continue
                }
                outcome.checked += 1
                let compared: String
                let position: Int?
                if let left = record.outputTokenIDs, let right = reference.outputTokenIDs {
                    compared = "token_ids"
                    position = left == right ? nil : MultiModelBenchCommand.firstDifference(left, right)
                } else {
                    compared = "text"
                    let left = Array(record.outputText.unicodeScalars)
                    let right = Array(reference.outputText.unicodeScalars)
                    position = left == right ? nil : MultiModelBenchCommand.firstDifference(left, right)
                }
                let countEqual = record.completionTokens == reference.completionTokens
                let finishEqual = record.finishReason == reference.finishReason
                guard position != nil || !countEqual || !finishEqual else { continue }
                let mismatch = MultiModelCheckMismatch(
                    model: record.model,
                    phase: phase.phase,
                    promptIndex: record.promptIndex,
                    requestID: record.requestID,
                    referenceRequestID: reference.requestID,
                    compared: compared,
                    firstDivergingPosition: position,
                    completionTokens: record.completionTokens,
                    referenceCompletionTokens: reference.completionTokens,
                    finishReason: record.finishReason,
                    referenceFinishReason: reference.finishReason
                )
                outcome.mismatches.append(mismatch)
                let kind = position != nil ? "output_mismatch" : (!countEqual ? "token_count_mismatch" : "finish_reason_mismatch")
                outcome.reasons.append("\(kind) phase=\(phase.phase) model=\(record.model) prompt=\(record.promptIndex) compared=\(compared) position=\(position.map(String.init) ?? "-") tokens=\(record.completionTokens)/\(reference.completionTokens) finish=\(record.finishReason)/\(reference.finishReason)")
            }
        }
        let memoryLimit = report.loads.last?.mlxMemoryLimitBytes ?? 0
        for phase in memoryPhases {
            guard let footprint = phase.physFootprintMaxBytes, memoryLimit > 0, footprint > UInt64(memoryLimit) else { continue }
            outcome.reasons.append("memory_over_limit phase=\(phase.phase) footprint_max_bytes=\(footprint) mlx_memory_limit_bytes=\(memoryLimit)")
        }
        // SPEC-001-R017: the process stays under the one shared limit and no
        // row is admitted past the shared budget.
        for phase in memoryPhases {
            guard let budget = phase.memoryBudget else { continue }
            if let limit = budget.limitBytes, limit > 0, let footprint = phase.physFootprintMaxBytes, footprint > UInt64(limit) {
                outcome.reasons.append("memory_over_shared_limit phase=\(phase.phase) footprint_max_bytes=\(footprint) shared_limit_bytes=\(limit)")
            }
            if budget.rowsAdmittedPastBudget > 0 {
                outcome.reasons.append("row_admitted_past_shared_budget phase=\(phase.phase) rows=\(budget.rowsAdmittedPastBudget)")
            }
        }
        if let first = outcome.reasons.first {
            let more = outcome.reasons.count > 1 ? " (+\(outcome.reasons.count - 1) more in JSON)" : ""
            outcome.line = "GATE fail reason=\(first)\(more)"
        }
        return outcome
    }

    struct GoalOutcome {
        var goal: MultiModelCheckGoal?
        /// Why `goal` is nil.
        var unavailable: String?
    }

    static func goal(soloA: MultiModelCheckPhaseResult, soloB: MultiModelCheckPhaseResult, measured: MultiModelCheckPhaseResult) -> GoalOutcome {
        goal(soloA: soloA.a, soloB: soloB.b, measuredPhase: measured.phase, a: measured.a, b: measured.b,
             intervalSeconds: measured.measurementIntervalSeconds ?? 0)
    }

    /// Pure: no default for a missing or zero rate; the goal is unavailable
    /// instead (and the gate floors fail the policy).
    static func goal(
        soloA: MultiModelCheckModelPhaseStats?,
        soloB: MultiModelCheckModelPhaseStats?,
        measuredPhase: String,
        a: MultiModelCheckModelPhaseStats?,
        b: MultiModelCheckModelPhaseStats?,
        intervalSeconds: Double
    ) -> GoalOutcome {
        func positive(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        guard let soloATPS = positive(soloA?.decodeTokensPerSecond) else { return GoalOutcome(unavailable: "zero_rate phase=solo-a model=a") }
        guard let soloBTPS = positive(soloB?.decodeTokensPerSecond) else { return GoalOutcome(unavailable: "zero_rate phase=solo-b model=b") }
        guard let soloA, let soloB, let a, let b else { return GoalOutcome(unavailable: "no_stats phase=\(measuredPhase)") }
        guard let measuredA = positive(a.decodeTokensPerSecond) else { return GoalOutcome(unavailable: "zero_rate phase=\(measuredPhase) model=a") }
        guard let measuredB = positive(b.decodeTokensPerSecond) else { return GoalOutcome(unavailable: "zero_rate phase=\(measuredPhase) model=b") }
        let share = (measuredA + measuredB) / (soloATPS + soloBTPS)
        let aFrac = measuredA / soloATPS
        let bFrac = measuredB / soloBTPS
        let aWork = MultiModelCheckWork.fraction(decodeTokens: a.tokensInInterval, prefillTokens: a.promptTokensPrefilledInInterval, solo: soloA, intervalSeconds: intervalSeconds)
        let bWork = MultiModelCheckWork.fraction(decodeTokens: b.tokensInInterval, prefillTokens: b.promptTokensPrefilledInInterval, solo: soloB, intervalSeconds: intervalSeconds)
        let workShare = aWork.flatMap { a in bWork.map { a + $0 } }
        var goal = MultiModelCheckGoal(
            source: measuredPhase,
            intervalSeconds: intervalSeconds,
            share: share,
            aFrac: aFrac,
            bFrac: bFrac,
            workShare: workShare,
            aWork: aWork,
            bWork: bWork,
            soloADecodeTokensPerSecond: soloATPS,
            soloBDecodeTokensPerSecond: soloBTPS,
            soloADecodeOnlyTokensPerSecond: soloA.decodeOnlyTokensPerSecond,
            soloBDecodeOnlyTokensPerSecond: soloB.decodeOnlyTokensPerSecond,
            soloAPrefillTokensPerSecond: soloA.prefillTokensPerSecond,
            soloBPrefillTokensPerSecond: soloB.prefillTokensPerSecond,
            contendedADecodeTokensPerSecond: measuredA,
            contendedBDecodeTokensPerSecond: measuredB,
            aDecodeTokens: a.tokensInInterval,
            bDecodeTokens: b.tokensInInterval,
            aPrefillTokens: a.promptTokensPrefilledInInterval,
            bPrefillTokens: b.promptTokensPrefilledInInterval,
            aRequestsCompleted: a.requestsCompleted,
            bRequestsCompleted: b.requestsCompleted,
            aRequestsLate: a.requestsLate,
            bRequestsLate: b.requestsLate,
            mainTtftSolo: soloA.ttft,
            mainTtftContended: a.ttft,
            workerTtftSolo: soloB.ttft,
            workerTtftContended: b.ttft,
            mainTtftMsSolo: soloA.ttft.medianMs,
            mainTtftMsContended: a.ttft.medianMs,
            line: ""
        )
        goal.line = "GOAL " + MultiModelCheckGoal.metrics(goal, measured: nil)
        return GoalOutcome(goal: goal)
    }
}

enum MultiModelCheckPhase: String, Sendable {
    case soloA = "solo-a"
    case soloB = "solo-b"
    case warmup
    case reference
    case contended
    case soak

    var slots: [MultiModelBenchSlot] {
        switch self {
        case .soloA: return [.a]
        case .soloB: return [.b]
        case .warmup, .reference, .contended, .soak: return [.a, .b]
        }
    }
}

// MARK: - Lanes

struct MultiModelCheckLanes: Sendable {
    let runtimes: [MultiModelBenchSlot: ModelRuntime]
    let requests: [MultiModelBenchSlot: [ChatCompletionRequest]]
    let nonce: String
    let capturePath: String
    let monitor: MultiModelBenchMonitor
    let box: MultiModelCheckReportBox

    var promptCount: Int { requests[.a]!.count }

    func runLane(phase: MultiModelCheckPhase, tag: String = "", slot: MultiModelBenchSlot, lane: Int, offset: Int, phaseStart: UInt64, deadline: UInt64) async throws -> [MultiModelCheckRequestRecord] {
        var records: [MultiModelCheckRequestRecord] = []
        var sequence = 0
        while MultiModelCheck.now() < deadline {
            let promptIndex = (offset + sequence) % promptCount
            records.append(try await serve(phase: phase, tag: tag, slot: slot, lane: lane, sequence: sequence, promptIndex: promptIndex, phaseStart: phaseStart))
            sequence += 1
        }
        return records
    }

    func serve(phase: MultiModelCheckPhase, tag: String = "", slot: MultiModelBenchSlot, lane: Int, sequence: Int, promptIndex: Int, phaseStart: UInt64) async throws -> MultiModelCheckRequestRecord {
        let runtime = runtimes[slot]!
        let request = requests[slot]![promptIndex].withRequestID("mmc-\(nonce)-\(phase.rawValue)\(tag)-\(slot.rawValue)-l\(lane)-r\(sequence)")
        let chunks = MultiModelCheckChunkLog()
        let monitor = monitor
        monitor.chunkArrived()
        let started = MultiModelCheck.now()
        let requestKey = request.requestID ?? UUID().uuidString
        box.beginRequest(requestKey, MultiModelCheckInFlight(
            model: slot.rawValue, phase: phase.rawValue, lane: lane, promptIndex: promptIndex,
            requestID: request.requestID, phaseStart: phaseStart, started: started, chunks: chunks
        ))
        defer { box.endRequest(requestKey) }
        let handle = try await runtime.acquireRequestHandle(request)
        let completion: CompletionResult
        do {
            try await runtime.preflight(request, with: handle)
            completion = try await runtime.stream(request, with: handle) { _ in
                chunks.record()
                monitor.chunkArrived()
            }
            await runtime.unregisterInFlight(handle.registrationID)
        } catch {
            await runtime.unregisterInFlight(handle.registrationID)
            throw error
        }
        let arrivals = chunks.snapshot().map { MultiModelCheck.seconds($0, since: phaseStart) }
        let startSeconds = MultiModelCheck.seconds(started, since: phaseStart)
        return MultiModelCheckRequestRecord(
            model: slot.rawValue,
            lane: lane,
            promptIndex: promptIndex,
            requestID: request.requestID,
            startSeconds: startSeconds,
            endSeconds: MultiModelCheck.seconds(MultiModelCheck.now(), since: phaseStart),
            chunkOffsetsSeconds: arrivals,
            promptTokens: completion.promptTokens,
            cachedPromptTokens: completion.cachedPromptTokens,
            completionTokens: completion.completionTokens,
            finishReason: completion.finishReason,
            ttftMilliseconds: arrivals.first.map { ($0 - startSeconds) * 1000 },
            outputKind: "text",
            outputSha256: "",
            outputTokenIDs: nil,
            outputText: (completion.reasoningContent ?? "") + "\u{1}" + completion.content
        )
    }

    /// Reads the token-capture file once per phase, after it ends, so the
    /// lookup never runs on the measured path; text hash otherwise, as in the
    /// default phases.
    func attachOutputs(_ records: inout [MultiModelCheckRequestRecord]) {
        var captured: [String: [Int]] = [:]
        if let data = FileManager.default.contents(atPath: capturePath) {
            for line in data.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let requestID = object["request_id"] as? String,
                      let ids = object["output_token_ids"] as? [Int]
                else { continue }
                captured[requestID] = ids
            }
        }
        for index in records.indices {
            let ids = records[index].requestID.flatMap { captured[$0] }
            let hashInput = ids.map { $0.map(String.init).joined(separator: ",") } ?? records[index].outputText
            records[index].outputTokenIDs = ids
            records[index].outputKind = ids == nil ? "text" : "token_ids"
            records[index].outputSha256 = SHA256.hash(data: Data(hashInput.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// Prompt indices still to serve in a reference pre-pass, and how many
/// real (non-filler) requests are still decoding.
actor MultiModelCheckReferenceQueue {
    private var pending: [Int]
    private(set) var realInFlight = 0

    init(_ indices: [Int]) {
        pending = indices
    }

    func take() -> Int? {
        guard !pending.isEmpty else { return nil }
        realInFlight += 1
        return pending.removeFirst()
    }

    func finished() {
        realInFlight -= 1
    }
}

/// Monotonic chunk arrival times for one request.
final class MultiModelCheckChunkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals: [UInt64] = []

    func record() {
        let now = MultiModelCheck.now()
        lock.lock()
        arrivals.append(now)
        lock.unlock()
    }

    func snapshot() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return arrivals
    }

    func last() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return arrivals.last
    }
}

/// Per-model hang decision (pure). Each model with a request in flight must
/// show progress (a request start or a chunk) within the limit; a model is
/// judged on its own in-flight requests only, so a streaming sibling never
/// masks it. Returns the model idle longest (ties: lowest name) at or past
/// the limit.
enum MultiModelCheckWatchdog {
    struct InFlight: Sendable, Equatable {
        let model: String
        /// Latest of the request's start and its last chunk (monotonic ns).
        let lastProgress: UInt64
    }

    static func stalled(_ inFlight: [InFlight], now: UInt64, limitSeconds: Double) -> MultiModelBenchStall? {
        var latest: [String: UInt64] = [:]
        for entry in inFlight {
            latest[entry.model] = max(latest[entry.model] ?? 0, entry.lastProgress)
        }
        var worst: MultiModelBenchStall?
        for (model, progress) in latest.sorted(by: { $0.key < $1.key }) {
            let idle = MultiModelCheck.seconds(now, since: progress)
            guard idle >= limitSeconds else { continue }
            if worst == nil || idle > worst!.idleSeconds { worst = MultiModelBenchStall(model: model, idleSeconds: idle) }
        }
        return worst
    }
}

/// Gate floors (pure): conditions under which a run measured nothing real
/// and must not pass.
enum MultiModelCheckFloors {
    struct Measured: Sendable {
        let phase: String
        let model: String
        let stats: MultiModelCheckModelPhaseStats?
    }

    struct Waits: Sendable {
        let phase: String
        /// Arbiter wait summed over participants; nil when not recorded.
        let totalWaitSeconds: Double?
    }

    static func reasons(
        measured: [Measured],
        policy: String,
        policyAlwaysProceeds: Bool,
        waits: [Waits],
        comparisons: [MultiModelCheckOutputComparison]
    ) -> [String] {
        var reasons: [String] = []
        for entry in measured {
            guard let stats = entry.stats else {
                reasons.append("no_stats phase=\(entry.phase) model=\(entry.model)")
                continue
            }
            if stats.tokensInInterval <= 0 {
                reasons.append("zero_tokens_in_interval phase=\(entry.phase) model=\(entry.model)")
            } else if !(stats.decodeTokensPerSecond.map { $0.isFinite && $0 > 0 } ?? false) {
                reasons.append("zero_rate phase=\(entry.phase) model=\(entry.model)")
            }
            if stats.requestsCompleted <= 0 {
                reasons.append("no_completed_requests phase=\(entry.phase) model=\(entry.model) late=\(stats.requestsLate)")
            }
        }
        if !policyAlwaysProceeds {
            for entry in waits where !((entry.totalWaitSeconds ?? 0) > 0) {
                reasons.append("policy_not_exercised phase=\(entry.phase) policy=\(policy) arbiter_wait_s=\(entry.totalWaitSeconds.map { String(format: "%.3f", $0) } ?? "n/a")")
            }
        }
        for comparison in comparisons where comparison.kind != "token_ids" {
            reasons.append("token_ids_unavailable model=\(comparison.model) compared=\(comparison.kind)")
        }
        return reasons
    }
}

/// Prefill credit and solo-equivalent work (pure).
///
/// Solo phase split: prefill time = the part of the interval in which some
/// request of the model is between its start and its first chunk; decode time
/// = the rest. solo_prefill_rate = prompt tokens prefilled in the interval /
/// prefill time; solo_decode_rate = decode tokens in the interval / decode
/// time. A request's prefilled tokens (prompt less cached) are spread evenly
/// over its start-to-first-chunk span and counted by the share of the span
/// inside the interval.
///
/// Per model, work fraction = (decode_tokens / solo_decode_rate +
/// prefill_tokens / solo_prefill_rate) / interval_seconds: seconds of solo
/// GPU work delivered per second. A solo phase scores exactly 1.0 against
/// itself. work_share = fraction A + fraction B: 1.0 is no loss from
/// sharing, 2.0 perfect parallelism.
enum MultiModelCheckWork {
    /// Prefilled prompt tokens placed inside `segments`, and the seconds of
    /// `segments` covered by some request's prefill span.
    static func prefill(records: [MultiModelCheckRequestRecord], segments: [(Double, Double)]) -> (tokens: Double, seconds: Double) {
        var tokens = 0.0
        var spans: [(Double, Double)] = []
        for record in records {
            guard let span = record.prefillSpan else { continue }
            let prefilled = Double(record.prefilledPromptTokens)
            spans.append(span)
            let length = span.1 - span.0
            if length > 0 {
                let inside = MultiModelCheckIntervals.intersect([span], MultiModelCheckIntervals.union(segments))
                    .reduce(0) { $0 + ($1.1 - $1.0) }
                tokens += prefilled * inside / length
            } else if MultiModelCheckIntervals.contains(segments, span.0) {
                tokens += prefilled
            }
        }
        let covered = MultiModelCheckIntervals.intersect(MultiModelCheckIntervals.union(spans), MultiModelCheckIntervals.union(segments))
            .reduce(0) { $0 + ($1.1 - $1.0) }
        return (tokens, covered)
    }

    /// Solo rates from one solo interval; nil where the time or work is zero.
    static func soloRates(decodeTokens: Int, prefillTokens: Double, prefillSeconds: Double, intervalSeconds: Double) -> (decode: Double?, prefill: Double?) {
        let decodeSeconds = intervalSeconds - prefillSeconds
        let decode = decodeSeconds > 0 && decodeTokens > 0 ? Double(decodeTokens) / decodeSeconds : nil
        let prefill = prefillSeconds > 0 && prefillTokens > 0 ? prefillTokens / prefillSeconds : nil
        return (decode, prefill)
    }

    /// Solo-equivalent seconds of work; nil when work was done of a kind the
    /// solo phase has no rate for.
    static func soloEquivalentSeconds(decodeTokens: Int, prefillTokens: Double, soloDecodeRate: Double?, soloPrefillRate: Double?) -> Double? {
        var seconds = 0.0
        if decodeTokens > 0 {
            guard let rate = soloDecodeRate, rate > 0 else { return nil }
            seconds += Double(decodeTokens) / rate
        }
        if prefillTokens > 0 {
            guard let rate = soloPrefillRate, rate > 0 else { return nil }
            seconds += prefillTokens / rate
        }
        return seconds
    }

    static func fraction(decodeTokens: Int, prefillTokens: Double, solo: MultiModelCheckModelPhaseStats, intervalSeconds: Double) -> Double? {
        guard intervalSeconds > 0 else { return nil }
        return soloEquivalentSeconds(
            decodeTokens: decodeTokens,
            prefillTokens: prefillTokens,
            soloDecodeRate: solo.decodeOnlyTokensPerSecond,
            soloPrefillRate: solo.prefillTokensPerSecond
        ).map { $0 / intervalSeconds }
    }
}

enum MultiModelCheckIntervals {
    /// Merged, sorted union of closed intervals.
    static func union(_ spans: [(Double, Double)]) -> [(Double, Double)] {
        var merged: [(Double, Double)] = []
        for span in spans.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, span.1)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Intersection of two merged, sorted interval lists.
    static func intersect(_ lhs: [(Double, Double)], _ rhs: [(Double, Double)]) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        var i = 0
        var j = 0
        while i < lhs.count, j < rhs.count {
            let low = max(lhs[i].0, rhs[j].0)
            let high = min(lhs[i].1, rhs[j].1)
            if low < high { result.append((low, high)) }
            if lhs[i].1 < rhs[j].1 { i += 1 } else { j += 1 }
        }
        return result
    }

    static func contains(_ segments: [(Double, Double)], _ time: Double) -> Bool {
        segments.contains { time >= $0.0 && time <= $0.1 }
    }
}

// MARK: - Report box

/// The check report, readable from the watchdog thread on a hang.
final class MultiModelCheckReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report: MultiModelCheckReport
    private let outPath: String?
    private var inFlight: [String: MultiModelCheckInFlight] = [:]

    init(report: MultiModelCheckReport, outPath: String?) {
        self.report = report
        self.outPath = outPath
    }

    func update(_ body: (inout MultiModelCheckReport) -> Void) {
        lock.lock()
        body(&report)
        lock.unlock()
    }

    func beginRequest(_ key: String, _ request: MultiModelCheckInFlight) {
        lock.lock()
        inFlight[key] = request
        lock.unlock()
    }

    func endRequest(_ key: String) {
        lock.lock()
        inFlight[key] = nil
        lock.unlock()
    }

    func snapshot() -> MultiModelCheckReport {
        lock.lock()
        defer { lock.unlock() }
        return report
    }

    /// Prints one stdout line and keeps it in the report (`printed_lines`).
    func emit(_ line: String) {
        update { $0.printedLines.append(line) }
        MultiModelCheck.emit(line)
    }

    /// Watchdog probe: the in-flight requests' progress, judged per model.
    func stalledModel(now: UInt64, limitSeconds: Double) -> MultiModelBenchStall? {
        lock.lock()
        let requests = Array(inFlight.values)
        lock.unlock()
        let entries = requests.map { request in
            MultiModelCheckWatchdog.InFlight(model: request.model, lastProgress: max(request.started, request.chunks.last() ?? 0))
        }
        return MultiModelCheckWatchdog.stalled(entries, now: now, limitSeconds: limitSeconds)
    }

    func write() {
        guard let outPath, let data = try? Self.encode(snapshot()) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        } catch {
            MultiModelBenchCommand.log("cannot write \(outPath): \(error)")
        }
    }

    /// Runs on the watchdog thread; the monitor exits 3 after it returns.
    func hang(phase: String, model: String?, secondsSinceLastChunk: Double, footprintMax: UInt64) {
        let modelPart = model.map { " model=\($0)" } ?? ""
        let line = "GATE fail reason=hang phase=\(phase)\(modelPart) seconds_since_last_chunk=\(Int(secondsSinceLastChunk))"
        let now = MultiModelCheck.now()
        update { report in
            report.hang = MultiModelBenchHang(phase: phase, secondsSinceLastChunk: secondsSinceLastChunk, model: model)
            report.inFlightAtHang = inFlight.values
                .sorted { ($0.model, $0.lane) < ($1.model, $1.lane) }
                .map { $0.state(now: now) }
            let bare = phase.split(separator: "[", maxSplits: 1).first.map(String.init) ?? phase
            if let index = report.phases.lastIndex(where: { $0.phase == bare }) {
                report.phases[index].physFootprintMaxBytes = footprintMax
            }
            report.gate = MultiModelCheckGate(pass: false, reasons: [String(line.dropFirst("GATE fail reason=".count))], line: line)
        }
        // The hung policy gets its POLICY line too.
        if let open = phase.firstIndex(of: "["), phase.hasSuffix("]") {
            let spec = phase[phase.index(after: open)..<phase.index(before: phase.endIndex)]
            emit("POLICY \(spec) GATE fail reason=hang\(modelPart) seconds_since_last_chunk=\(Int(secondsSinceLastChunk))")
        }
        emit(line)
        write()
    }

    static func encode(_ report: MultiModelCheckReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(report)
    }
}

// MARK: - Report schema

struct MultiModelCheckReport: Encodable, Sendable {
    let schema: String
    let generatedAtUnixSeconds: Double
    let host: MultiModelBenchHost
    let binaryVersion: String
    /// `MultiModelCheck.buildGitSHA()`: env, a GIT_SHA file, else `unknown`.
    let gitSha: String
    let config: MultiModelCheckConfig
    let processEnvironment: MultiModelBenchProcessEnvironment
    /// Every line printed to stdout, in order (POLICY, SOAK, GATE, GOAL,
    /// CHECK error, hang lines).
    var printedLines: [String] = []
    var loads: [MultiModelBenchLoad] = []
    /// SPEC-001-R017: the shared budget's load decision before each load.
    var loadDecisions: [MultiModelCheckLoadDecision] = []
    var runtimes: [MultiModelCheckRuntimeState] = []
    /// Canonical snapshot-manifest hash passed as the verified artifact identity.
    var modelArtifactSha256: [String: String] = [:]
    var phases: [MultiModelCheckPhaseResult] = []
    var references: [MultiModelCheckReference] = []
    var outputComparison: [MultiModelCheckOutputComparison] = []
    var parityChecked = 0
    var parityMismatches: [MultiModelCheckMismatch] = []
    var gate: MultiModelCheckGate?
    var goal: MultiModelCheckGoal?
    /// `--gpu-turn-policies`: one entry per policy, in run order.
    var policies: [MultiModelCheckPolicyResult] = []
    var hang: MultiModelBenchHang?
    /// Requests in flight when the watchdog fired.
    var inFlightAtHang: [MultiModelCheckInFlightState] = []
    var error: String?
    var complete = false
}

struct MultiModelCheckInFlight: Sendable {
    let model: String
    let phase: String
    let lane: Int
    let promptIndex: Int
    let requestID: String?
    let phaseStart: UInt64
    let started: UInt64
    let chunks: MultiModelCheckChunkLog

    func state(now: UInt64) -> MultiModelCheckInFlightState {
        let arrivals = chunks.snapshot()
        return MultiModelCheckInFlightState(
            model: model,
            phase: phase,
            lane: lane,
            promptIndex: promptIndex,
            requestID: requestID,
            startSeconds: MultiModelCheck.seconds(started, since: phaseStart),
            chunksReceived: arrivals.count,
            secondsSinceStart: MultiModelCheck.seconds(now, since: started),
            secondsSinceLastChunk: arrivals.last.map { MultiModelCheck.seconds(now, since: $0) }
        )
    }
}

struct MultiModelCheckInFlightState: Encodable, Sendable {
    let model: String
    let phase: String
    let lane: Int
    let promptIndex: Int
    let requestID: String?
    let startSeconds: Double
    let chunksReceived: Int
    let secondsSinceStart: Double
    let secondsSinceLastChunk: Double?
}

/// The serve tunables both runtimes are built with. Without `--config`:
/// serve's defaults. With it: the file resolved by serve's own
/// `ConfigLoader` (YAML, then environment), applied as serve applies it.
/// `continuous_batching_accepted_tuples` is not read: serve ignores manual
/// tuples outside `--no-join` (MacProviderCLI.swift, `continuous_batching_
/// manual_tuple action=ignored`); under default-on coverage CB admission is
/// the on-device self-check's decision, and accepted tuples only carry the
/// signed AC-26 cached-turn grant.
struct MultiModelCheckServeSettings: Sendable {
    var configPath: String?
    var pagedKV = PagedKVConfig(enabled: true)
    var maxContextOverride: Int?
    var kvBitsOverride: Int?
    var mlxCacheLimitMB: Int?
    var prefillStepSize = 512
    var prefillStepSizeExplicitlyConfigured = false
    var continuousBatchQueueLimit: Int?
    var continuousBatchQueueWaitTimeoutMS: Int?
    var continuousBatchPrefillTokensPerIteration: Int?
    var continuousBatchingCachedTurns = true
    var nativeMTPMode: NativeMTPMode = .off

    static func resolve(configPath: String?) throws -> MultiModelCheckServeSettings {
        var settings = MultiModelCheckServeSettings()
        if let configPath {
            let resolved = try ConfigLoader.load(cli: CLIOverrides(configPath: configPath), resolveCredentials: false)
            settings.configPath = resolved.configPath
            settings.pagedKV = resolved.pagedKV
            // As serve: paged KV attaches by default unless paged_kv.enabled
            // is set explicitly (SPEC-039 FR-PKV14).
            if !resolved.pagedKVEnabledExplicitlyConfigured, resolved.pagedKV.errors.isEmpty {
                settings.pagedKV.enabled = true
            }
            settings.maxContextOverride = resolved.maxContextOverride
            settings.kvBitsOverride = resolved.kvBitsOverride
            settings.mlxCacheLimitMB = resolved.mlxCacheLimitMB
            settings.prefillStepSize = resolved.prefillStepSize
            settings.prefillStepSizeExplicitlyConfigured = resolved.prefillStepSizeExplicitlyConfigured
            settings.continuousBatchQueueLimit = resolved.continuousBatchQueueLimit
            settings.continuousBatchQueueWaitTimeoutMS = resolved.continuousBatchQueueWaitTimeoutMS
            settings.continuousBatchPrefillTokensPerIteration = resolved.continuousBatchPrefillTokensPerIteration
            settings.continuousBatchingCachedTurns = resolved.continuousBatchingCachedTurns
            settings.nativeMTPMode = resolved.nativeMTPMode
        }
        MultiModelBenchCommand.log("serve_settings config=\(settings.configPath ?? "nil") paged_kv_enabled=\(settings.pagedKV.enabled) paged_kv_errors=\(settings.pagedKV.errors.count) block_size=\(settings.pagedKV.blockSizeTokens) max_physical_blocks=\(settings.pagedKV.maxPhysicalBlocks) max_context=\(settings.maxContextOverride.map(String.init) ?? "nil") kv_bits=\(settings.kvBitsOverride.map(String.init) ?? "nil") mlx_cache_limit_mb=\(settings.mlxCacheLimitMB.map(String.init) ?? "nil") prefill_step=\(settings.prefillStepSize) queue_limit=\(settings.continuousBatchQueueLimit.map(String.init) ?? "nil") cached_turns=\(settings.continuousBatchingCachedTurns) native_mtp_mode=\(settings.nativeMTPMode.rawValue)")
        return settings
    }
}

struct MultiModelCheckConfig: Encodable, Sendable {
    /// Load path (or id) per model.
    let modelA: String
    let modelB: String
    /// Serving identity bound into the runtime and sent as `request.model`,
    /// as serve binds the catalog id (`--model-id-x`, default the load value).
    let modelIDA: String
    let modelIDB: String
    /// Requested rows (`--rows-x`); the rows driven are each runtime's
    /// `granted_rows`.
    let rowsA: Int
    let rowsB: Int
    /// `--rows-exact`: the requested rows are required, else `CHECK error`.
    let rowsExact: Bool
    /// Explicitly configured continuous-batching mode per model (`--cb-x`).
    let continuousBatchingA: String
    let continuousBatchingB: String
    let maxTokensA: Int
    let maxTokensB: Int
    /// `--prompt-tokens`; the per-model targets below are what was used.
    let promptTokensTarget: Int
    let promptTokensTargetA: Int
    let promptTokensTargetB: Int
    let promptsPerModel: Int
    let phaseSeconds: Double
    let soakSeconds: Double
    let rampSeconds: Double
    let watchdogSeconds: Double
    let loadOrder: [String]
    let temperature: Double
    let topP: Double
    let stream: Bool
    let tokenCapturePath: String
    /// SPEC-001-R018: the GPU turn policy both runtimes ran under (with
    /// `--gpu-turn-policies`: the passthrough of the shared pre-pass phases).
    let gpuTurnPolicy: MultiModelCheckGPUTurnPolicy
    /// `--gpu-turn-policies`, in run order; nil for a single-policy check.
    let gpuTurnPolicies: [MultiModelCheckPolicySpec]?
}

struct MultiModelCheckPolicySpec: Encodable, Sendable {
    let spec: String
    let name: String
    /// The policy's full parameter set, defaults included.
    let parameters: [String: String]
    let alwaysProceeds: Bool
}

/// One `--gpu-turn-policies` entry: its contended (and, for the last, soak)
/// phases, judged against the shared solo references.
struct MultiModelCheckPolicyResult: Encodable, Sendable {
    let spec: String
    let policy: String
    let policyParameters: [String: String]
    let policyAlwaysProceeds: Bool
    let phases: [String]
    var gate: MultiModelCheckGate
    /// What GOAL uses: the soak's when a soak was asked for, else the
    /// contended phase's.
    var goal: MultiModelCheckGoal?
    var contendedGoal: MultiModelCheckGoal?
    var soakGoal: MultiModelCheckGoal?
    var minFrac: Double?
    var mainTtftMsP95: Double?
    var workerTtftMsMedian: Double?
    var aWaitSeconds: Double?
    var bWaitSeconds: Double?
    /// Information only: the wired limit and the largest footprint above it.
    var wiredLimitBytes: Int?
    var footprintOverWiredBytes: Int?
    var parityChecked = 0
    var parityMismatches: [MultiModelCheckMismatch] = []
    var gpuTurns: [MultiModelCheckGPUTurnStats] = []
    var memoryBudget: [MultiModelCheckMemoryBudgetStats] = []
    var line: String
    var soakLine: String?
}

struct MultiModelCheckGPUTurnPolicy: Encodable, Sendable {
    let name: String
    let parameters: [String: String]
    /// `flag`, `env` or `default`.
    let source: String
}

/// One phase's arbiter statistics: counters accumulated during the phase and
/// the longest single wait inside it, per participant, labelled by slot.
struct MultiModelCheckGPUTurnStats: Encodable, Sendable {
    let policy: String
    let policyParameters: [String: String]
    let participants: [MultiModelCheckGPUTurnParticipant]
}

struct MultiModelCheckGPUTurnParticipant: Encodable, Sendable {
    /// `a` or `b`; nil for a participant that is not one of the two runtimes.
    let model: String?
    let arbiter: GPUTurnParticipantSnapshot
}

final class MultiModelCheckGPUTurnWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Int: MultiModelBenchSlot] = [:]
    private var baseline: GPUTurnArbiterSnapshot?

    func bind(slot: MultiModelBenchSlot, participantID: Int) {
        lock.lock(); defer { lock.unlock() }
        slots[participantID] = slot
    }

    func begin() {
        let snapshot = GPUTurnArbiter.shared.snapshot(resettingMaxWait: true)
        lock.lock(); defer { lock.unlock() }
        baseline = snapshot
    }

    func finish() -> MultiModelCheckGPUTurnStats? {
        let current = GPUTurnArbiter.shared.snapshot(resettingMaxWait: true)
        lock.lock(); defer { lock.unlock() }
        guard let baseline else { return nil }
        self.baseline = nil
        let delta = current.delta(since: baseline)
        return MultiModelCheckGPUTurnStats(
            policy: delta.policy,
            policyParameters: delta.policyParameters,
            participants: delta.participants.map {
                MultiModelCheckGPUTurnParticipant(model: slots[$0.id]?.rawValue, arbiter: $0)
            }
        )
    }
}

struct MultiModelCheckLoadDecision: Encodable, Sendable {
    let model: String
    let decision: SharedModelMemoryRules.LoadDecision
}

struct MultiModelCheckMemoryBudgetRuntime: Encodable, Sendable {
    /// `a` or `b`; nil for a member that is not one of the two runtimes.
    let model: String?
    let memberID: Int
    let residentBytes: Int
    let kvBytesPerToken: Int
    /// Highest worst-case KV committed to this runtime's admitted rows.
    let committedKVPeakBytes: Int
    let rowsAdmitted: Int
    let rowsRefused: Int
    let rowsAdmittedPastBudget: Int
}

/// One phase of the shared budget: the limits at phase end, counters
/// accumulated during the phase, and the lowest headroom (limit less every
/// runtime's weights, peak committed row KV and margin).
struct MultiModelCheckMemoryBudgetStats: Encodable, Sendable {
    let limitBytes: Int?
    let wiredLimitBytes: Int?
    let cacheLimitBytes: Int
    let headroomMinBytes: Int?
    let admissionRefusals: Int
    let rowsAdmittedPastBudget: Int
    let cacheClearsPerformed: Int
    let cacheClearsSkipped: Int
    let commandBufferBudgetSetBy: String?
    let commandBufferBudgetMb: Int?
    let commandBufferConflicts: [String]
    let runtimes: [MultiModelCheckMemoryBudgetRuntime]
}

final class MultiModelCheckMemoryBudgetWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Int: MultiModelBenchSlot] = [:]
    private var baseline: SharedModelMemoryBudget.Snapshot?

    func bind(slot: MultiModelBenchSlot, memberID: Int) {
        lock.lock(); defer { lock.unlock() }
        slots[memberID] = slot
    }

    func begin() {
        SharedModelMemoryBudget.shared.resetPeaks()
        let snapshot = SharedModelMemoryBudget.shared.snapshot()
        lock.lock(); defer { lock.unlock() }
        baseline = snapshot
    }

    func finish() -> MultiModelCheckMemoryBudgetStats? {
        let end = SharedModelMemoryBudget.shared.snapshot()
        lock.lock(); defer { lock.unlock() }
        guard let start = baseline else { return nil }
        baseline = nil
        let before = Dictionary(uniqueKeysWithValues: start.members.map { ($0.memberID, $0) })
        let runtimes = end.members.map { member in
            let earlier = before[member.memberID]
            return MultiModelCheckMemoryBudgetRuntime(
                model: slots[member.memberID]?.rawValue,
                memberID: member.memberID,
                residentBytes: member.residentBytes,
                kvBytesPerToken: member.kvBytesPerToken,
                committedKVPeakBytes: member.peakCommittedKVBytes,
                rowsAdmitted: member.rowsAdmitted - (earlier?.rowsAdmitted ?? 0),
                rowsRefused: member.rowsRefused - (earlier?.rowsRefused ?? 0),
                rowsAdmittedPastBudget: member.rowsAdmittedPastBudget - (earlier?.rowsAdmittedPastBudget ?? 0)
            )
        }
        return MultiModelCheckMemoryBudgetStats(
            limitBytes: end.limitBytes,
            wiredLimitBytes: end.wiredLimitBytes,
            cacheLimitBytes: end.cacheLimitBytes,
            headroomMinBytes: end.limitBytes.map { $0 - end.peakChargedBytes },
            admissionRefusals: runtimes.reduce(0) { $0 + $1.rowsRefused },
            rowsAdmittedPastBudget: runtimes.reduce(0) { $0 + $1.rowsAdmittedPastBudget },
            cacheClearsPerformed: end.cacheClearsPerformed - start.cacheClearsPerformed,
            cacheClearsSkipped: end.cacheClearsSkipped - start.cacheClearsSkipped,
            commandBufferBudgetSetBy: end.commandBufferBudgetSetBy,
            commandBufferBudgetMb: end.commandBufferBudgetMb,
            commandBufferConflicts: end.commandBufferConflicts,
            runtimes: runtimes
        )
    }
}

/// What the runtime actually does with concurrent requests, as reported by
/// its own snapshot after the serve-shaped construction in `load`.
struct MultiModelCheckRuntimeState: Encodable, Sendable {
    let model: String
    let constructedWith: String
    /// `continuous_batching` when the CB scheduler is active, else
    /// `serial_inference_gate` (lanes queue on the runtime's inference gate).
    let engine: String
    let servedSlots: Int
    let continuousBatchingMode: String?
    let continuousBatchingActive: Bool
    let continuousBatchingUnsupportedReason: String?
    let pagedKvDecision: String?
    let continuousBatchingPolicyLoadStatus: String?
    let continuousBatchingPolicyAuthorized: Bool?
    let continuousBatchingPolicyDecisionReason: String?
    let nativeMTPSupported: Bool
    let nativeMTPEnabled: Bool
    let nativeMTPModeAtLoad: String
    let nativeMTPReasonAtLoad: String
    var nativeMTPModeAtEnd: String?
    var nativeMTPForwardsAtEnd: UInt64?
    /// True only when the runtime ran MTP forwards during the check.
    var nativeMTPActive: Bool?
    var continuousBatchingActiveAtEnd: Bool?
    var schedulerMaxObservedBatchDepthAtEnd: Int?
    var schedulerSharedForwardCallsAtEnd: Int?
    /// Serve's CB self-check run at load; nil when CB is off or uncheckable.
    let selfCheck: MultiModelCheckSelfCheck?
    /// `--rows-x`, the rows the check drove (`MultiModelCheckRowShape`), and
    /// the self-check's reason (`granted`, a refusal reason, or `none`).
    var requestedRows: Int?
    var grantedRows: Int?
    var selfCheckReason: String?

    init(slot: MultiModelBenchSlot, requestedMode: ContinuousBatchingMode, rows: Int, snapshot: RuntimeSnapshot, servedSlots: Int, selfCheck: MultiModelCheckSelfCheck?) {
        self.selfCheck = selfCheck
        let cb = snapshot.continuousBatching
        model = slot.rawValue
        constructedWith = "serve shape: paged_kv=on (family defaults) max_batch=\(rows) continuous_batching_mode=\(requestedMode.rawValue) explicitly_configured=true cached_turns=true verified_artifact_sha256=canonical snapshot-manifest hash, default-on CB coverage decided by serve's self-check driver, native_mtp_mode=off (no signed admission sidecar), no signed CB policy"
        engine = cb?.active == true ? "continuous_batching" : "serial_inference_gate"
        self.servedSlots = servedSlots
        continuousBatchingMode = cb?.mode.rawValue
        continuousBatchingActive = cb?.active ?? false
        continuousBatchingUnsupportedReason = cb?.unsupportedReason
        pagedKvDecision = cb?.pagedKVDecision
        continuousBatchingPolicyLoadStatus = cb?.policy.loadStatus
        continuousBatchingPolicyAuthorized = cb?.policy.authorized
        continuousBatchingPolicyDecisionReason = cb?.policy.decisionReason
        nativeMTPSupported = snapshot.nativeMTPStatus.supported
        nativeMTPEnabled = snapshot.nativeMTPStatus.enabled
        nativeMTPModeAtLoad = snapshot.nativeMTPStatus.mode.rawValue
        nativeMTPReasonAtLoad = snapshot.nativeMTPStatus.lastReason.rawValue
    }

    mutating func recordEnd(_ snapshot: RuntimeSnapshot) {
        let status = snapshot.nativeMTPStatus
        continuousBatchingActiveAtEnd = snapshot.continuousBatching?.active
        schedulerMaxObservedBatchDepthAtEnd = snapshot.continuousBatching?.scheduler?.maxObservedBatchDepth
        schedulerSharedForwardCallsAtEnd = snapshot.continuousBatching?.scheduler?.sharedForwardCalls
        nativeMTPModeAtEnd = status.mode.rawValue
        nativeMTPForwardsAtEnd = status.mtpForwards
        nativeMTPActive = status.mtpForwards > 0
    }
}

struct MultiModelCheckSelfCheck: Encodable, Sendable, Equatable {
    let outcome: String
    /// `granted`, or the refusal reason (e.g. `no_net_gain`, `single_row`).
    var reason: String
    /// The slots a grant gave; nil for a refusal.
    var grantedSlots: Int?
    var seconds: Double = 0
    var storePath: String = ""
}

/// The rows the check drives one model with. Serve's CB self-check may grant
/// fewer rows than requested (or refuse batching, leaving one row); that is
/// what the product serves, so by default the check drives the granted rows.
struct MultiModelCheckRowShape: Encodable, Sendable, Equatable {
    let model: String
    let requestedRows: Int
    let grantedRows: Int
    /// `granted`, the self-check's refusal reason, or `none` when no
    /// self-check ran.
    let selfCheckReason: String

    /// Pure. Default: granted = min(requested, served slots). Fails when the
    /// model serves no row, or when the granted rows (or a self-check grant)
    /// imply batching and the engine is serialized. `rowsExact`: the
    /// requested rows on the continuous-batching engine, as before.
    static func resolve(
        slot: MultiModelBenchSlot, requestedRows: Int, engine: String, servedSlots: Int,
        selfCheck: MultiModelCheckSelfCheck?, rowsExact: Bool, detail: String = ""
    ) throws -> MultiModelCheckRowShape {
        let reason = selfCheck?.reason ?? "none"
        func mismatch(_ rows: Int) -> MultiModelCheckFailure {
            MultiModelCheckFailure(reason: "engine_mismatch model=\(slot.rawValue) rows=\(rows) requested_rows=\(requestedRows) engine=\(engine) served_slots=\(servedSlots) self_check=\(reason) rows_exact=\(rowsExact)\(detail.isEmpty ? "" : " \(detail)")")
        }
        if rowsExact {
            if requestedRows > 1, engine != "continuous_batching" || servedSlots < requestedRows { throw mismatch(requestedRows) }
            return MultiModelCheckRowShape(model: slot.rawValue, requestedRows: requestedRows, grantedRows: requestedRows, selfCheckReason: reason)
        }
        guard servedSlots >= 1 else {
            throw MultiModelCheckFailure(reason: "no_rows model=\(slot.rawValue) requested_rows=\(requestedRows) served_slots=\(servedSlots) self_check=\(reason)")
        }
        let granted = min(requestedRows, servedSlots)
        let grantImpliesBatching = (selfCheck?.grantedSlots ?? 0) > 1 && requestedRows > 1
        if (granted > 1 || grantImpliesBatching), engine != "continuous_batching" { throw mismatch(granted) }
        return MultiModelCheckRowShape(model: slot.rawValue, requestedRows: requestedRows, grantedRows: granted, selfCheckReason: reason)
    }

    /// `a_rows_requested=4 a_rows_granted=3 a_self_check=granted ...`, by model.
    static func lineFields(_ shapes: [MultiModelCheckRowShape]) -> String {
        shapes.map { "\($0.model)_rows_requested=\($0.requestedRows) \($0.model)_rows_granted=\($0.grantedRows) \($0.model)_self_check=\($0.selfCheckReason)" }
            .joined(separator: " ")
    }
}

/// The row shape of each loaded model, read by every phase.
final class MultiModelCheckRowShapes: @unchecked Sendable {
    private let lock = NSLock()
    private var shapes: [MultiModelBenchSlot: MultiModelCheckRowShape] = [:]

    func set(_ slot: MultiModelBenchSlot, _ shape: MultiModelCheckRowShape) {
        lock.lock(); defer { lock.unlock() }
        shapes[slot] = shape
    }

    func granted(_ slot: MultiModelBenchSlot) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return shapes[slot]?.grantedRows
    }

    /// In slot order (a, b).
    var all: [MultiModelCheckRowShape] {
        lock.lock(); defer { lock.unlock() }
        return MultiModelBenchSlot.allCases.compactMap { shapes[$0] }
    }
}

struct MultiModelCheckRequestRecord: Encodable, Sendable {
    let model: String
    let lane: Int
    let promptIndex: Int
    let requestID: String?
    /// Seconds since the phase start (monotonic clock).
    let startSeconds: Double
    let endSeconds: Double
    let chunkOffsetsSeconds: [Double]
    let promptTokens: Int
    /// Prompt tokens served from cache (not prefilled).
    let cachedPromptTokens: Int
    let completionTokens: Int
    let finishReason: String
    let ttftMilliseconds: Double?
    var outputKind: String
    var outputSha256: String
    var outputTokenIDs: [Int]?
    var outputText: String
    /// Reference pre-pass only: served to keep the row count, not a reference.
    var filler = false

    enum CodingKeys: String, CodingKey {
        case model, lane, promptIndex, requestID, startSeconds, endSeconds, chunkOffsetsSeconds
        case promptTokens, cachedPromptTokens, completionTokens, finishReason, ttftMilliseconds, outputKind, outputSha256, filler
    }

    /// Submission to completion: the time this request is in flight.
    var inFlightSpan: (Double, Double) { (startSeconds, endSeconds) }

    /// Submission to first chunk: the time the prompt is (queued and)
    /// prefilled. Nil when no chunk arrived.
    var prefillSpan: (Double, Double)? {
        chunkOffsetsSeconds.first.map { (startSeconds, max(startSeconds, $0)) }
    }

    var prefilledPromptTokens: Int { max(0, promptTokens - cachedPromptTokens) }

    /// Arrival time of each completion token: chunk `j * chunks / tokens`.
    var tokenArrivals: [Double] {
        let chunks = chunkOffsetsSeconds.count
        guard chunks > 0, completionTokens > 0 else { return [] }
        return (0..<completionTokens).map { chunkOffsetsSeconds[min(chunks - 1, $0 * chunks / completionTokens)] }
    }
}

/// TTFT summary over one phase's requests, with its sample count so
/// solo and contended figures are compared like for like.
struct MultiModelCheckTTFT: Encodable, Sendable, Equatable {
    let n: Int
    let medianMs: Double?
    let p95Ms: Double?
    /// TTFT of the phase's first request, kept out of n/median/p95: it starts
    /// at t=0 together with the sibling's first request and collides with its
    /// prefill, which steady state never does.
    let firstMs: Double?

    /// First request (earliest start) reported alone; n/median/p95 over the rest.
    init(records: [MultiModelCheckRequestRecord]) {
        let ordered = records.sorted { $0.startSeconds < $1.startSeconds }
        self.init(rest: ordered.dropFirst().compactMap(\.ttftMilliseconds), first: ordered.first?.ttftMilliseconds)
    }

    init(_ values: [Double]) { self.init(rest: values, first: nil) }

    private init(rest values: [Double], first: Double?) {
        firstMs = first
        let sorted = values.sorted()
        n = sorted.count
        medianMs = MultiModelBenchModelStats.median(sorted)
        p95Ms = sorted.isEmpty ? nil : sorted[max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)]
    }
}

struct MultiModelCheckModelPhaseStats: Encodable, Sendable {
    let rows: Int
    /// Requests that finished at or before the phase deadline.
    let requestsCompleted: Int
    /// Requests started before the deadline that finished after it.
    let requestsLate: Int
    let tokensInInterval: Int
    /// tokens_in_interval ÷ measurement_interval_seconds.
    let decodeTokensPerSecond: Double?
    /// Prompt tokens (less cached) prefilled inside the interval.
    let promptTokensPrefilledInInterval: Double
    /// Seconds of the interval with some request between start and first chunk.
    let prefillSecondsInInterval: Double
    /// tokens_in_interval ÷ (interval − prefill seconds): the solo decode
    /// rate `MultiModelCheckWork` uses.
    let decodeOnlyTokensPerSecond: Double?
    /// prompt_tokens_prefilled_in_interval ÷ prefill seconds.
    let prefillTokensPerSecond: Double?
    let ttft: MultiModelCheckTTFT
    let ttftMsMedian: Double?
    let ttftMsP95: Double?
    /// `exact` when every request's chunk count equals its completion tokens.
    let tokenChunkMapping: String
    /// Cumulative CB scheduler counters at phase end (nil when no scheduler).
    var schedulerMaxObservedBatchDepth: Int?
    var schedulerSharedForwardCalls: Int?

    init(rows: Int, records: [MultiModelCheckRequestRecord], segments: [(Double, Double)], intervalSeconds: Double, deadlineSeconds: Double) {
        self.rows = rows
        requestsCompleted = records.filter { $0.endSeconds <= deadlineSeconds }.count
        requestsLate = records.count - requestsCompleted
        tokensInInterval = records.reduce(0) { total, record in
            total + record.tokenArrivals.filter { MultiModelCheckIntervals.contains(segments, $0) }.count
        }
        decodeTokensPerSecond = intervalSeconds > 0 ? Double(tokensInInterval) / intervalSeconds : nil
        let prefill = MultiModelCheckWork.prefill(records: records, segments: segments)
        promptTokensPrefilledInInterval = prefill.tokens
        prefillSecondsInInterval = prefill.seconds
        let rates = MultiModelCheckWork.soloRates(decodeTokens: tokensInInterval, prefillTokens: prefill.tokens, prefillSeconds: prefill.seconds, intervalSeconds: intervalSeconds)
        decodeOnlyTokensPerSecond = rates.decode
        prefillTokensPerSecond = rates.prefill
        ttft = MultiModelCheckTTFT(records: records)
        ttftMsMedian = ttft.medianMs
        ttftMsP95 = ttft.p95Ms
        tokenChunkMapping = records.allSatisfy { $0.chunkOffsetsSeconds.count == $0.completionTokens } ? "exact" : "proportional"
    }
}

struct MultiModelCheckPhaseResult: Encodable, Sendable {
    let phase: String
    let durationSeconds: Double
    var wallSeconds: Double?
    var completed = false
    var mlxPeakBytes: Int?
    var physFootprintMaxBytes: UInt64?
    var measurementIntervalSeconds: Double?
    var measurementSegments: [[Double]] = []
    /// Contended/soak: share of the interval with a request of each model in flight.
    var overlapFraction: Double?
    /// `--gpu-turn-policies`: the policy spec this phase ran under.
    var gpuTurnPolicy: String?
    /// SPEC-001-R018: GPU turn arbiter statistics for this phase.
    var gpuTurns: MultiModelCheckGPUTurnStats?
    /// SPEC-001-R017: the shared memory budget over this phase.
    var memoryBudget: MultiModelCheckMemoryBudgetStats?
    var a: MultiModelCheckModelPhaseStats?
    var b: MultiModelCheckModelPhaseStats?
    var requests: [MultiModelCheckRequestRecord] = []
    var error: String?

    init(phase: String, durationSeconds: Double) {
        self.phase = phase
        self.durationSeconds = durationSeconds
    }
}

struct MultiModelCheckReference: Encodable, Sendable {
    let model: String
    let promptIndex: Int
    let requestID: String?
    let completionTokens: Int
    let finishReason: String
    let outputKind: String
    let outputSha256: String
    let outputTokenIDs: [Int]?

    init(slot: MultiModelBenchSlot, record: MultiModelCheckRequestRecord) {
        model = slot.rawValue
        promptIndex = record.promptIndex
        requestID = record.requestID
        completionTokens = record.completionTokens
        finishReason = record.finishReason
        outputKind = record.outputKind
        outputSha256 = record.outputSha256
        outputTokenIDs = record.outputTokenIDs
    }
}

struct MultiModelCheckOutputComparison: Encodable, Sendable {
    let model: String
    /// `token_ids` (lab token capture) or `text` (completion text fallback).
    let kind: String
}

struct MultiModelCheckMismatch: Encodable, Sendable {
    let model: String
    let phase: String
    let promptIndex: Int
    let requestID: String?
    let referenceRequestID: String?
    let compared: String
    let firstDivergingPosition: Int?
    let completionTokens: Int
    let referenceCompletionTokens: Int
    let finishReason: String
    let referenceFinishReason: String
}

struct MultiModelCheckGate: Encodable, Sendable {
    let pass: Bool
    let reasons: [String]
    let line: String
}

struct MultiModelCheckGoal: Encodable, Sendable {
    /// The phase measured against the solo phases: `contended` or `soak`.
    let source: String
    let intervalSeconds: Double
    /// Decode tokens only, as in round 1 (kept for continuity).
    let share: Double
    let aFrac: Double
    let bFrac: Double
    /// `MultiModelCheckWork`: (solo-equivalent seconds of A + of B) ÷ interval.
    let workShare: Double?
    let aWork: Double?
    let bWork: Double?
    let soloADecodeTokensPerSecond: Double
    let soloBDecodeTokensPerSecond: Double
    let soloADecodeOnlyTokensPerSecond: Double?
    let soloBDecodeOnlyTokensPerSecond: Double?
    let soloAPrefillTokensPerSecond: Double?
    let soloBPrefillTokensPerSecond: Double?
    let contendedADecodeTokensPerSecond: Double
    let contendedBDecodeTokensPerSecond: Double
    let aDecodeTokens: Int
    let bDecodeTokens: Int
    let aPrefillTokens: Double
    let bPrefillTokens: Double
    let aRequestsCompleted: Int
    let bRequestsCompleted: Int
    let aRequestsLate: Int
    let bRequestsLate: Int
    let mainTtftSolo: MultiModelCheckTTFT
    let mainTtftContended: MultiModelCheckTTFT
    let workerTtftSolo: MultiModelCheckTTFT
    let workerTtftContended: MultiModelCheckTTFT
    /// Medians, kept for continuity with round 1 JSON.
    let mainTtftMsSolo: Double?
    let mainTtftMsContended: Double?
    var line: String

    static func fmt(_ value: Double?, _ format: String) -> String { value.map { String(format: format, $0) } ?? "n/a" }

    static func ttftFields(_ label: String, _ ttft: MultiModelCheckTTFT?) -> String {
        let first = "\(label)_ttft_first_ms=\(fmt(ttft?.firstMs, "%.0f"))"
        // No request after the first: n=0 and no median rather than a misleading one.
        guard let ttft, ttft.n > 0 else { return "\(label)_ttft_n=0 \(first)" }
        return "\(label)_ttft_n=\(ttft.n) \(label)_ttft_ms=\(fmt(ttft.medianMs, "%.0f")) \(label)_ttft_p95_ms=\(fmt(ttft.p95Ms, "%.0f")) \(first)"
    }

    /// The metric fields of POLICY, SOAK and GOAL lines; starts `share=`.
    /// Without a goal, what the measured phase itself recorded.
    static func metrics(_ goal: MultiModelCheckGoal?, measured: MultiModelCheckPhaseResult?) -> String {
        var fields: [String] = []
        guard let goal else {
            let a = measured?.a
            let b = measured?.b
            fields.append("share=n/a a_frac=n/a b_frac=n/a min_frac=n/a work_share=n/a a_work=n/a b_work=n/a")
            fields.append("a_tps=\(fmt(a?.decodeTokensPerSecond, "%.2f")) b_tps=\(fmt(b?.decodeTokensPerSecond, "%.2f"))")
            fields.append("a_tokens=\(a?.tokensInInterval ?? 0) b_tokens=\(b?.tokensInInterval ?? 0)")
            fields.append("a_prefill_tokens=\(fmt(a?.promptTokensPrefilledInInterval, "%.0f")) b_prefill_tokens=\(fmt(b?.promptTokensPrefilledInInterval, "%.0f"))")
            fields.append("a_completed=\(a?.requestsCompleted ?? 0) a_late=\(a?.requestsLate ?? 0) b_completed=\(b?.requestsCompleted ?? 0) b_late=\(b?.requestsLate ?? 0)")
            fields.append(ttftFields("main", a?.ttft))
            fields.append(ttftFields("worker", b?.ttft))
            fields.append("source=\(measured?.phase ?? "n/a")")
            return fields.joined(separator: " ")
        }
        fields.append("share=\(fmt(goal.share, "%.4f")) a_frac=\(fmt(goal.aFrac, "%.4f")) b_frac=\(fmt(goal.bFrac, "%.4f")) min_frac=\(fmt(min(goal.aFrac, goal.bFrac), "%.4f"))")
        fields.append("work_share=\(fmt(goal.workShare, "%.4f")) a_work=\(fmt(goal.aWork, "%.4f")) b_work=\(fmt(goal.bWork, "%.4f"))")
        fields.append("a_tps=\(fmt(goal.contendedADecodeTokensPerSecond, "%.2f")) b_tps=\(fmt(goal.contendedBDecodeTokensPerSecond, "%.2f"))")
        fields.append("a_tokens=\(goal.aDecodeTokens) b_tokens=\(goal.bDecodeTokens)")
        fields.append("a_prefill_tokens=\(fmt(goal.aPrefillTokens, "%.0f")) b_prefill_tokens=\(fmt(goal.bPrefillTokens, "%.0f"))")
        fields.append("solo_a_prefill_tps=\(fmt(goal.soloAPrefillTokensPerSecond, "%.1f")) solo_b_prefill_tps=\(fmt(goal.soloBPrefillTokensPerSecond, "%.1f"))")
        fields.append("a_completed=\(goal.aRequestsCompleted) a_late=\(goal.aRequestsLate) b_completed=\(goal.bRequestsCompleted) b_late=\(goal.bRequestsLate)")
        fields.append(ttftFields("main_solo", goal.mainTtftSolo))
        fields.append(ttftFields("main", goal.mainTtftContended))
        fields.append(ttftFields("worker_solo", goal.workerTtftSolo))
        fields.append(ttftFields("worker", goal.workerTtftContended))
        fields.append("source=\(goal.source) interval_s=\(fmt(goal.intervalSeconds, "%.1f"))")
        return fields.joined(separator: " ")
    }
}
#endif
