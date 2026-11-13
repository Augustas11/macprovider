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
/// Rates use a measurement interval that skips the first `rampSeconds` of a
/// phase and ends at its deadline; in `contended` and `soak` it is further
/// cut to the time during which at least one lane of each model is decoding
/// (between a request's first and last chunk). Tokens are placed on chunk
/// arrival times in order: exact when chunks equal completion tokens,
/// proportional otherwise (recorded per model and phase).
///
/// stdout ends with `GATE pass|fail ...` then `GOAL share=...`. Exit codes:
/// 0 pass, 2 gate fail, 3 hang, 1 when the check cannot run.
enum MultiModelCheck {
    static let rampSeconds: Double = 10
    static let promptsPerModel = 8
    static let schema = "macprovider.multi-model-bench.check.v1"

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func seconds(_ nanos: UInt64, since start: UInt64) -> Double {
        nanos >= start ? Double(nanos - start) / 1e9 : -Double(start - nanos) / 1e9
    }

    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
        MultiModelBenchCommand.log(line)
    }
}

extension MultiModelBenchCommand {
    func runCheck() async throws {
        let nonce = String(UUID().uuidString.prefix(8).lowercased())
        let capturePath = Self.prepareTokenCapture(nonce: nonce)
        let firstFamily = ModelRuntime.localModelFamily(modelA)
        let appliedBudgetMB = firstFamily.flatMap { ModelRuntime.applyMLXCommandBufferBudget(modelFamily: $0) }
        let basePrompt = Self.promptText(promptTokens: promptTokens)
        let config = MultiModelCheckConfig(
            modelA: modelA,
            modelB: modelB,
            rowsA: rowsA,
            rowsB: rowsB,
            maxTokensA: maxTokensA,
            maxTokensB: maxTokensB,
            promptTokensTarget: promptTokens,
            promptsPerModel: MultiModelCheck.promptsPerModel,
            phaseSeconds: phaseSeconds,
            soakSeconds: soakSeconds,
            rampSeconds: MultiModelCheck.rampSeconds,
            watchdogSeconds: watchdogSeconds,
            loadOrder: ["a", "b"],
            temperature: 0,
            topP: 1,
            stream: true,
            tokenCapturePath: capturePath
        )
        let report = MultiModelCheckReport(
            schema: MultiModelCheck.schema,
            generatedAtUnixSeconds: Date().timeIntervalSince1970,
            host: MultiModelBenchHost.current(),
            binaryVersion: CoordinatorClient.binaryVersion,
            config: config,
            processEnvironment: MultiModelBenchProcessEnvironment(
                firstLoadedModelFamily: firstFamily,
                commandBufferBudgetAppliedMb: appliedBudgetMB,
                mlxMaxMbPerBuffer: ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"]
            )
        )
        let box = MultiModelCheckReportBox(report: report, outPath: out)
        box.write()
        let monitor = MultiModelBenchMonitor(outPath: nil, watchdogSeconds: watchdogSeconds) { phase, idle, footprint in
            box.hang(phase: phase, secondsSinceLastChunk: idle, footprintMax: footprint)
        }
        monitor.start()
        defer { monitor.stop() }
        let runner = MultiModelCheckRunner(config: config, basePrompt: basePrompt, nonce: nonce, box: box, monitor: monitor)
        do {
            try await runner.run()
        } catch let failure as MultiModelCheckFailure {
            box.update { $0.error = failure.reason }
            box.write()
            MultiModelCheck.emit("CHECK error reason=\(failure.reason)")
            throw ExitCode(1)
        } catch let exit as ExitCode {
            throw exit
        } catch {
            let reason = "error detail=\(String(describing: error).replacingOccurrences(of: "\n", with: " "))"
            box.update { $0.error = reason }
            box.write()
            MultiModelCheck.emit("CHECK error reason=\(reason)")
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
    let basePrompt: String
    let nonce: String
    let box: MultiModelCheckReportBox
    let monitor: MultiModelBenchMonitor

    func run() async throws {
        for (slot, path) in [(MultiModelBenchSlot.a, config.modelA), (.b, config.modelB)] {
            try Self.requireModelDirectory(slot: slot, value: path)
        }
        var runtimes: [MultiModelBenchSlot: ModelRuntime] = [:]
        for slot in MultiModelBenchSlot.allCases {
            runtimes[slot] = try await load(slot)
        }
        var requests: [MultiModelBenchSlot: [ChatCompletionRequest]] = [:]
        for slot in MultiModelBenchSlot.allCases {
            let modelID = slot == .a ? config.modelA : config.modelB
            let maxTokens = slot == .a ? config.maxTokensA : config.maxTokensB
            requests[slot] = try (0..<config.promptsPerModel).map { index in
                try MultiModelBenchCommand.request(
                    modelID: modelID,
                    prompt: "Request \(index + 1) of \(config.promptsPerModel). " + basePrompt,
                    maxTokens: maxTokens
                )
            }
        }
        let lanes = MultiModelCheckLanes(runtimes: runtimes, requests: requests, nonce: nonce, capturePath: config.tokenCapturePath, monitor: monitor, box: box)

        // A runtime's first request can take far longer than the ramp
        // (observed 34 s to first token on a cold second runtime), so each
        // model serves one unmeasured request alone before solo-a.
        let warmup = try await runSequential(.warmup, MultiModelBenchSlot.allCases.map { ($0, 0) }, lanes: lanes)
        let soloA = try await runPhase(.soloA, seconds: config.phaseSeconds, lanes: lanes)
        let soloB = try await runPhase(.soloB, seconds: config.phaseSeconds, lanes: lanes)
        var references: [MultiModelBenchSlot: [Int: MultiModelCheckRequestRecord]] = [.a: [:], .b: [:]]
        for record in soloA.requests + soloB.requests + warmup.requests {
            let slot = MultiModelBenchSlot(rawValue: record.model)!
            if references[slot]![record.promptIndex] == nil { references[slot]![record.promptIndex] = record }
        }
        let missing = MultiModelBenchSlot.allCases.flatMap { slot in
            (0..<config.promptsPerModel).filter { references[slot]![$0] == nil }.map { (slot, $0) }
        }
        let referencePass = try await runSequential(.reference, missing, lanes: lanes)
        for record in referencePass.requests {
            references[MultiModelBenchSlot(rawValue: record.model)!]![record.promptIndex] = record
        }
        box.update { report in
            report.references = MultiModelBenchSlot.allCases.flatMap { slot in
                references[slot]!.keys.sorted().map { MultiModelCheckReference(slot: slot, record: references[slot]![$0]!) }
            }
        }
        box.write()

        let contended = try await runPhase(.contended, seconds: config.phaseSeconds, lanes: lanes)
        var checked = [contended]
        if config.soakSeconds > 0 {
            checked.append(try await runPhase(.soak, seconds: config.soakSeconds, lanes: lanes))
        }

        for slot in MultiModelBenchSlot.allCases {
            let snapshot = await runtimes[slot]!.currentSnapshot()
            box.update { report in
                guard let index = report.runtimes.firstIndex(where: { $0.model == slot.rawValue }) else { return }
                report.runtimes[index].recordEnd(snapshot.nativeMTPStatus)
            }
        }

        let gate = Self.gate(checked: checked, references: references, report: box.snapshot())
        let goal = try Self.goal(soloA: soloA, soloB: soloB, contended: contended)
        box.update { report in
            report.parityChecked = gate.checked
            report.parityMismatches = gate.mismatches
            report.outputComparison = gate.outputComparison
            report.gate = MultiModelCheckGate(pass: gate.reasons.isEmpty, reasons: gate.reasons, line: gate.line)
            report.goal = goal
            report.complete = true
        }
        box.write()
        MultiModelCheck.emit(gate.line)
        MultiModelCheck.emit(goal.line)
        if !gate.reasons.isEmpty { throw ExitCode(2) }
    }

    /// A value that names a local path must exist as a directory; anything
    /// else is treated as a model id and left to the runtime.
    static func requireModelDirectory(slot: MultiModelBenchSlot, value: String) throws {
        guard value.hasPrefix("/") || value.hasPrefix(".") || value.hasPrefix("~") else { return }
        let path = (value as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MultiModelCheckFailure(reason: "missing_model_dir model=\(slot.rawValue) path=\(path)")
        }
    }

    private func load(_ slot: MultiModelBenchSlot) async throws -> ModelRuntime {
        let modelID = slot == .a ? config.modelA : config.modelB
        MultiModelBenchCommand.log("load start model=\(slot.rawValue) id=\(modelID)")
        let started = Date()
        let runtime: ModelRuntime
        do {
            runtime = try await ModelRuntime(modelID: modelID)
        } catch {
            throw MultiModelCheckFailure(reason: "load_failed model=\(slot.rawValue) detail=\(String(describing: error).replacingOccurrences(of: "\n", with: " "))")
        }
        guard await runtime.isLoaded else {
            throw MultiModelCheckFailure(reason: "load_failed model=\(slot.rawValue) detail=not_loaded")
        }
        let load = MultiModelBenchLoad(
            model: slot.rawValue,
            modelID: modelID,
            modelFamily: ModelRuntime.localModelFamily(modelID),
            loadSeconds: Date().timeIntervalSince(started),
            mlxActiveBytes: Memory.activeMemory,
            mlxPeakBytes: Memory.peakMemory,
            mlxCacheBytes: Memory.cacheMemory,
            mlxCacheLimitBytes: Memory.cacheLimit,
            mlxMemoryLimitBytes: Memory.memoryLimit,
            physFootprintBytes: MultiModelBenchMonitor.physFootprintBytes(),
            mlxMaxMbPerBuffer: ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"]
        )
        let state = MultiModelCheckRuntimeState(
            slot: slot,
            snapshot: await runtime.currentSnapshot(),
            servedSlots: await runtime.servedSlotLimitForTest()
        )
        box.update { report in
            report.loads.append(load)
            report.runtimes.append(state)
        }
        box.write()
        MultiModelBenchCommand.log("load done model=\(slot.rawValue) seconds=\(String(format: "%.1f", load.loadSeconds)) engine=\(state.engine) served_slots=\(state.servedSlots) native_mtp=\(state.nativeMTPModeAtLoad) memory_limit=\(load.mlxMemoryLimitBytes)")
        return runtime
    }

    // MARK: Phases

    private func rows(_ slot: MultiModelBenchSlot) -> Int { slot == .a ? config.rowsA : config.rowsB }

    private func runPhase(_ phase: MultiModelCheckPhase, seconds: Double, lanes: MultiModelCheckLanes) async throws -> MultiModelCheckPhaseResult {
        let started = beginPhase(phase, seconds: seconds)
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
                            try await lanes.runLane(phase: phase, slot: slot, lane: lane, offset: offset, phaseStart: started, deadline: deadline)
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
        let window = (MultiModelCheck.rampSeconds, seconds)
        var segments = [window]
        if phase.slots.count == 2 {
            for slot in phase.slots {
                segments = MultiModelCheckIntervals.intersect(segments, MultiModelCheckIntervals.union(records.filter { $0.model == slot.rawValue }.compactMap(\.decodeSpan)))
            }
        }
        let intervalSeconds = segments.reduce(0) { $0 + ($1.1 - $1.0) }
        result.measurementSegments = segments.map { [$0.0, $0.1] }
        result.measurementIntervalSeconds = intervalSeconds
        for slot in phase.slots {
            let modelRecords = records.filter { $0.model == slot.rawValue }
            let stats = MultiModelCheckModelPhaseStats(rows: rowCounts[slot]!, records: modelRecords, segments: segments, intervalSeconds: intervalSeconds)
            if slot == .a { result.a = stats } else { result.b = stats }
        }
        let snapshot = result
        box.update { $0.phases[$0.phases.count - 1] = snapshot }
        box.write()
        for slot in phase.slots {
            guard let stats = slot == .a ? result.a : result.b else { continue }
            MultiModelBenchCommand.log("  \(phase.rawValue) model=\(slot.rawValue) rows=\(stats.rows) completed=\(stats.requestsCompleted) tokens_in_interval=\(stats.tokensInInterval) decode_tps=\(stats.decodeTokensPerSecond.map { String(format: "%.2f", $0) } ?? "n/a") ttft_ms_median=\(stats.ttftMsMedian.map { String(format: "%.0f", $0) } ?? "n/a") interval_s=\(String(format: "%.1f", intervalSeconds))")
            guard stats.requestsCompleted > 0 else {
                throw MultiModelCheckFailure(reason: "no_completed_requests phase=\(phase.rawValue) model=\(slot.rawValue)")
            }
        }
        guard intervalSeconds > 0 else {
            throw MultiModelCheckFailure(reason: "empty_measurement_interval phase=\(phase.rawValue)")
        }
        return result
    }

    /// Serves each (model, prompt index) once, alone, one after another: the
    /// warmup, and the reference pre-pass that gives every index served under
    /// contention a solo reference.
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

    private func beginPhase(_ phase: MultiModelCheckPhase, seconds: Double) -> UInt64 {
        Memory.peakMemory = 0 // setter resets MLX's peak counter
        monitor.phaseBegan(phase.rawValue)
        box.update { $0.phases.append(MultiModelCheckPhaseResult(phase: phase.rawValue, durationSeconds: seconds)) }
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
        }
        box.write()
        MultiModelBenchCommand.log("phase \(phase.rawValue) failed: \(error)")
    }

    private func finishPhase(_ phase: MultiModelCheckPhase, seconds: Double, records: [MultiModelCheckRequestRecord], started: UInt64) -> MultiModelCheckPhaseResult {
        var result = MultiModelCheckPhaseResult(phase: phase.rawValue, durationSeconds: seconds)
        result.wallSeconds = MultiModelCheck.seconds(MultiModelCheck.now(), since: started)
        result.physFootprintMaxBytes = monitor.phaseEnded()
        result.mlxPeakBytes = Memory.peakMemory
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
        report: MultiModelCheckReport
    ) -> GateOutcome {
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
        for phase in report.phases {
            guard let footprint = phase.physFootprintMaxBytes, memoryLimit > 0, footprint > UInt64(memoryLimit) else { continue }
            outcome.reasons.append("memory_over_limit phase=\(phase.phase) footprint_max_bytes=\(footprint) mlx_memory_limit_bytes=\(memoryLimit)")
        }
        if let first = outcome.reasons.first {
            let more = outcome.reasons.count > 1 ? " (+\(outcome.reasons.count - 1) more in JSON)" : ""
            outcome.line = "GATE fail reason=\(first)\(more)"
        }
        return outcome
    }

    static func goal(soloA: MultiModelCheckPhaseResult, soloB: MultiModelCheckPhaseResult, contended: MultiModelCheckPhaseResult) throws -> MultiModelCheckGoal {
        guard let soloATPS = soloA.a?.decodeTokensPerSecond, soloATPS > 0 else {
            throw MultiModelCheckFailure(reason: "no_tokens_in_interval phase=solo-a model=a")
        }
        guard let soloBTPS = soloB.b?.decodeTokensPerSecond, soloBTPS > 0 else {
            throw MultiModelCheckFailure(reason: "no_tokens_in_interval phase=solo-b model=b")
        }
        let contendedA = contended.a?.decodeTokensPerSecond ?? 0
        let contendedB = contended.b?.decodeTokensPerSecond ?? 0
        guard let ttftSolo = soloA.a?.ttftMsMedian, let ttftContended = contended.a?.ttftMsMedian else {
            throw MultiModelCheckFailure(reason: "no_main_ttft")
        }
        let share = (contendedA + contendedB) / (soloATPS + soloBTPS)
        let aFrac = contendedA / soloATPS
        let bFrac = contendedB / soloBTPS
        let line = String(
            format: "GOAL share=%.4f a_frac=%.4f b_frac=%.4f main_ttft_ms_solo=%.0f main_ttft_ms_contended=%.0f",
            share, aFrac, bFrac, ttftSolo, ttftContended
        )
        return MultiModelCheckGoal(
            share: share,
            aFrac: aFrac,
            bFrac: bFrac,
            soloADecodeTokensPerSecond: soloATPS,
            soloBDecodeTokensPerSecond: soloBTPS,
            contendedADecodeTokensPerSecond: contendedA,
            contendedBDecodeTokensPerSecond: contendedB,
            mainTtftMsSolo: ttftSolo,
            mainTtftMsContended: ttftContended,
            line: line
        )
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

    func runLane(phase: MultiModelCheckPhase, slot: MultiModelBenchSlot, lane: Int, offset: Int, phaseStart: UInt64, deadline: UInt64) async throws -> [MultiModelCheckRequestRecord] {
        var records: [MultiModelCheckRequestRecord] = []
        var sequence = 0
        while MultiModelCheck.now() < deadline {
            let promptIndex = (offset + sequence) % promptCount
            records.append(try await serve(phase: phase, slot: slot, lane: lane, sequence: sequence, promptIndex: promptIndex, phaseStart: phaseStart))
            sequence += 1
        }
        return records
    }

    func serve(phase: MultiModelCheckPhase, slot: MultiModelBenchSlot, lane: Int, sequence: Int, promptIndex: Int, phaseStart: UInt64) async throws -> MultiModelCheckRequestRecord {
        let runtime = runtimes[slot]!
        let request = requests[slot]![promptIndex].withRequestID("mmc-\(nonce)-\(phase.rawValue)-\(slot.rawValue)-l\(lane)-r\(sequence)")
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

    func write() {
        guard let outPath, let data = try? Self.encode(snapshot()) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        } catch {
            MultiModelBenchCommand.log("cannot write \(outPath): \(error)")
        }
    }

    /// Runs on the watchdog thread; the monitor exits 3 after it returns.
    func hang(phase: String, secondsSinceLastChunk: Double, footprintMax: UInt64) {
        let line = "GATE fail reason=hang phase=\(phase) seconds_since_last_chunk=\(Int(secondsSinceLastChunk))"
        let now = MultiModelCheck.now()
        update { report in
            report.hang = MultiModelBenchHang(phase: phase, secondsSinceLastChunk: secondsSinceLastChunk)
            report.inFlightAtHang = inFlight.values
                .sorted { ($0.model, $0.lane) < ($1.model, $1.lane) }
                .map { $0.state(now: now) }
            if let index = report.phases.lastIndex(where: { $0.phase == phase }) {
                report.phases[index].physFootprintMaxBytes = footprintMax
            }
            report.gate = MultiModelCheckGate(pass: false, reasons: [String(line.dropFirst("GATE fail reason=".count))], line: line)
        }
        write()
        MultiModelCheck.emit(line)
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
    let config: MultiModelCheckConfig
    let processEnvironment: MultiModelBenchProcessEnvironment
    var loads: [MultiModelBenchLoad] = []
    var runtimes: [MultiModelCheckRuntimeState] = []
    var phases: [MultiModelCheckPhaseResult] = []
    var references: [MultiModelCheckReference] = []
    var outputComparison: [MultiModelCheckOutputComparison] = []
    var parityChecked = 0
    var parityMismatches: [MultiModelCheckMismatch] = []
    var gate: MultiModelCheckGate?
    var goal: MultiModelCheckGoal?
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

struct MultiModelCheckConfig: Encodable, Sendable {
    let modelA: String
    let modelB: String
    let rowsA: Int
    let rowsB: Int
    let maxTokensA: Int
    let maxTokensB: Int
    let promptTokensTarget: Int
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
}

/// What the runtime actually does with concurrent requests, as constructed
/// here: `ModelRuntime(modelID:)` defaults (max_batch 1, continuous batching
/// mode off, native MTP mode off, no signed CB policy or MTP sidecar). The
/// harness reports this; it does not change it.
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

    init(slot: MultiModelBenchSlot, snapshot: RuntimeSnapshot, servedSlots: Int) {
        let cb = snapshot.continuousBatching
        model = slot.rawValue
        constructedWith = "ModelRuntime(modelID:) defaults: max_batch=1 continuous_batching_mode=off native_mtp_mode=off, no signed CB policy, no native MTP admission sidecar"
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

    mutating func recordEnd(_ status: NativeMTPStatusSnapshot) {
        nativeMTPModeAtEnd = status.mode.rawValue
        nativeMTPForwardsAtEnd = status.mtpForwards
        nativeMTPActive = status.mtpForwards > 0
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
    let completionTokens: Int
    let finishReason: String
    let ttftMilliseconds: Double?
    var outputKind: String
    var outputSha256: String
    var outputTokenIDs: [Int]?
    var outputText: String

    enum CodingKeys: String, CodingKey {
        case model, lane, promptIndex, requestID, startSeconds, endSeconds, chunkOffsetsSeconds
        case promptTokens, completionTokens, finishReason, ttftMilliseconds, outputKind, outputSha256
    }

    /// First to last chunk: the time this request is actively decoding.
    var decodeSpan: (Double, Double)? {
        guard let first = chunkOffsetsSeconds.first, let last = chunkOffsetsSeconds.last else { return nil }
        return (first, last)
    }

    /// Arrival time of each completion token: chunk `j * chunks / tokens`.
    var tokenArrivals: [Double] {
        let chunks = chunkOffsetsSeconds.count
        guard chunks > 0, completionTokens > 0 else { return [] }
        return (0..<completionTokens).map { chunkOffsetsSeconds[min(chunks - 1, $0 * chunks / completionTokens)] }
    }
}

struct MultiModelCheckModelPhaseStats: Encodable, Sendable {
    let rows: Int
    let requestsCompleted: Int
    let tokensInInterval: Int
    /// tokens_in_interval ÷ measurement_interval_seconds.
    let decodeTokensPerSecond: Double?
    let ttftMsMedian: Double?
    let ttftMsP95: Double?
    /// `exact` when every request's chunk count equals its completion tokens.
    let tokenChunkMapping: String

    init(rows: Int, records: [MultiModelCheckRequestRecord], segments: [(Double, Double)], intervalSeconds: Double) {
        self.rows = rows
        requestsCompleted = records.count
        tokensInInterval = records.reduce(0) { total, record in
            total + record.tokenArrivals.filter { MultiModelCheckIntervals.contains(segments, $0) }.count
        }
        decodeTokensPerSecond = intervalSeconds > 0 ? Double(tokensInInterval) / intervalSeconds : nil
        let ttfts = records.compactMap(\.ttftMilliseconds).sorted()
        ttftMsMedian = MultiModelBenchModelStats.median(ttfts)
        ttftMsP95 = ttfts.isEmpty ? nil : ttfts[max(0, Int((0.95 * Double(ttfts.count)).rounded(.up)) - 1)]
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
    let share: Double
    let aFrac: Double
    let bFrac: Double
    let soloADecodeTokensPerSecond: Double
    let soloBDecodeTokensPerSecond: Double
    let contendedADecodeTokensPerSecond: Double
    let contendedBDecodeTokensPerSecond: Double
    let mainTtftMsSolo: Double
    let mainTtftMsContended: Double
    let line: String
}
#endif
