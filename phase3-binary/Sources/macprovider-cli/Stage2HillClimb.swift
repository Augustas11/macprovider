import Foundation

struct WinningKnobs: Equatable {
    var kvBits: Int?
    var maxBatch: Int
    var maxContext: Int
}

struct Stage2HillClimbResult: Equatable {
    var selectedModel: String
    var winningKnobs: WinningKnobs
    var medianTPS: Double
    var p95TTFTMS: Double
    var replicates: Int
    var cellTrials: [AutotuneTrialRow]
}

enum Stage2HillClimbError: Error, Equatable, CustomStringConvertible {
    case interrupted
    case budgetExhaustedWithPartialRecommendation(Stage2HillClimbResult)
    case noFeasibleCell(reason: String)

    var description: String {
        switch self {
        case .interrupted:
            return "interrupted"
        case .budgetExhaustedWithPartialRecommendation:
            return AutotuneExitReason.budgetExhaustedWithPartialRecommendation.rawValue
        case .noFeasibleCell(let reason):
            return "Stage 2 found no feasible knob cell: \(reason)"
        }
    }
}

enum Stage2ProbeResult: Equatable {
    case feasible(medianTPS: Double, p95TTFTMS: Double, measuredPromptTokens: Int?)
    case infeasible(reason: String, nErr: Int, measuredPromptTokens: Int?)
}

protocol Stage2Probing {
    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        knobs: WinningKnobs,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int
    ) async throws -> Stage2ProbeResult
}

struct Stage2HillClimb {
    typealias RunnerFactory = () throws -> Stage1ProviderRunning

    private struct BestCell {
        var knobs: WinningKnobs
        var tps: Double
        var ttft: Double
    }

    private let runnerFactory: RunnerFactory
    private let prober: Stage2Probing
    private let autotuneDB: AutotuneDB
    private let selectedModel: String
    private let kvBitsAxis: [Int?]
    private let maxBatchAxis: [Int]
    private let maxContextAxis: [Int]
    private let targetContext: Int
    private let gateTTFTMS: Int
    private let stage2Replicates: Int
    private let tpsTieEpsilon: Double
    private let port: Int
    private let runID: String
    private let now: () -> Date
    private let cancellationReason: () -> AutotuneCancellationReason?

    init(
        candidateProviderRunner: @escaping RunnerFactory,
        prober: Stage2Probing = Stage2Prober(),
        autotuneDB: AutotuneDB,
        selectedModel: String,
        kvBitsAxis: [Int?],
        maxBatchAxis: [Int],
        maxContextAxis: [Int],
        targetContext: Int,
        gateTTFTMS: Int,
        stage2Replicates: Int,
        tpsTieEpsilon: Double = 0.02,
        port: Int,
        runID: String = UUID().uuidString,
        now: @escaping () -> Date = Date.init,
        cancellationReason: @escaping () -> AutotuneCancellationReason? = { nil }
    ) {
        self.runnerFactory = candidateProviderRunner
        self.prober = prober
        self.autotuneDB = autotuneDB
        self.selectedModel = selectedModel
        self.kvBitsAxis = kvBitsAxis
        self.maxBatchAxis = maxBatchAxis
        self.maxContextAxis = maxContextAxis
        self.targetContext = targetContext
        self.gateTTFTMS = gateTTFTMS
        self.stage2Replicates = max(1, stage2Replicates)
        self.tpsTieEpsilon = tpsTieEpsilon
        self.port = port
        self.runID = runID
        self.now = now
        self.cancellationReason = cancellationReason
    }

    func run() async throws -> Stage2HillClimbResult {
        var trialRows: [AutotuneTrialRow] = []
        var best: BestCell?
        var bestRowIndex: Int?
        var failureReasons: [String] = []

        for kvBits in kvBitsAxis {
            for maxBatch in maxBatchAxis {
                for maxContext in maxContextAxis {
                    switch cancellationReason() {
                    case .interrupted:
                        throw Stage2HillClimbError.interrupted
                    case .budgetExhausted:
                        if let partial = try finalizePartial(best: best, bestRowIndex: bestRowIndex, trialRows: trialRows) {
                            throw Stage2HillClimbError.budgetExhaustedWithPartialRecommendation(partial)
                        }
                        throw Stage2HillClimbError.noFeasibleCell(reason: "budget exhausted before any Stage 2 cell completed")
                    case .none:
                        break
                    }

                    let knobs = WinningKnobs(
                        kvBits: kvBits,
                        maxBatch: maxBatch,
                        maxContext: maxContext
                    )
                    let runner = try runnerFactory()
                    let probeResult = try await prober.probe(
                        model: selectedModel,
                        port: port,
                        runner: runner,
                        knobs: knobs,
                        targetContext: targetContext,
                        gateTTFTMS: gateTTFTMS,
                        replicates: stage2Replicates
                    )

                    switch probeResult {
                    case .feasible(let medianTPS, let p95TTFTMS, _):
                        if Self.isNewBest(
                            tps: medianTPS,
                            ttft: p95TTFTMS,
                            bestTPS: best?.tps,
                            bestTTFT: best?.ttft,
                            tpsTieEpsilon: tpsTieEpsilon
                        ) {
                            best = BestCell(knobs: knobs, tps: medianTPS, ttft: p95TTFTMS)
                            // Stamped at insert-time below; the actual
                            // `kept = 1` DB write happens AFTER the loop
                            // per D.1 closure (see below).
                            bestRowIndex = trialRows.count
                        }
                    case .infeasible(let reason, _, _):
                        failureReasons.append("\(Self.describe(knobs)): \(reason)")
                    }

                    // Round-1 audit D.1 (MAJOR) closure: the prior code
                    // passed `kept: isNewBest(...)` at insert time, which
                    // left multiple Stage 2 rows with `kept = 1` for runs
                    // where later cells outperformed earlier baselines.
                    // SPEC-013 §5.7 FR-G.1 requires only the FINAL winning
                    // Stage 2 cell to carry `kept = 1`. We now insert every
                    // row with `kept = false`, then update the winning row
                    // via `markStage2WinnerCell` once iteration completes.
                    let row = makeTrialRow(
                        knobs: knobs,
                        result: probeResult,
                        kept: false
                    )
                    try autotuneDB.insertTrial(row)
                    trialRows.append(row)
                }
            }
        }

        guard let best else {
            let summary = failureReasons.isEmpty
                ? "no Stage 2 cells were evaluated"
                : failureReasons.joined(separator: " | ")
            throw Stage2HillClimbError.noFeasibleCell(reason: summary)
        }

        // D.1 closure: stamp the FINAL winner's row with `kept = 1`. The
        // UPDATE matches the (run_id, stage=2, knobs) compound; idempotent.
        try autotuneDB.markStage2WinnerCell(
            runID: runID,
            kvBits: best.knobs.kvBits,
            maxBatch: best.knobs.maxBatch,
            maxContextCap: best.knobs.maxContext
        )
        // Mirror the DB update in the in-memory trial rows so callers
        // reading `cellTrials` see consistent kept semantics.
        if let bestRowIndex {
            trialRows[bestRowIndex].kept = true
        }

        return Stage2HillClimbResult(
            selectedModel: selectedModel,
            winningKnobs: best.knobs,
            medianTPS: best.tps,
            p95TTFTMS: best.ttft,
            replicates: stage2Replicates,
            cellTrials: trialRows
        )
    }

    private func finalizePartial(
        best: BestCell?,
        bestRowIndex: Int?,
        trialRows: [AutotuneTrialRow]
    ) throws -> Stage2HillClimbResult? {
        guard let best else {
            return nil
        }
        try autotuneDB.markStage2WinnerCell(
            runID: runID,
            kvBits: best.knobs.kvBits,
            maxBatch: best.knobs.maxBatch,
            maxContextCap: best.knobs.maxContext
        )
        var rows = trialRows
        if let bestRowIndex {
            rows[bestRowIndex].kept = true
        }
        return Stage2HillClimbResult(
            selectedModel: selectedModel,
            winningKnobs: best.knobs,
            medianTPS: best.tps,
            p95TTFTMS: best.ttft,
            replicates: stage2Replicates,
            cellTrials: rows
        )
    }

    static func isNewBest(
        tps: Double?,
        ttft: Double?,
        bestTPS: Double?,
        bestTTFT: Double?,
        tpsTieEpsilon: Double = 0.02
    ) -> Bool {
        guard let tps else {
            return false
        }
        guard let bestTPS else {
            return true
        }
        if bestTPS <= 0 {
            return tps > 0
        }
        let relGap = (tps - bestTPS) / bestTPS
        if relGap > tpsTieEpsilon {
            return true
        }
        if abs(relGap) <= tpsTieEpsilon {
            if let ttft, let bestTTFT {
                return ttft < bestTTFT
            }
            if ttft != nil {
                return true
            }
        }
        return false
    }

    private func makeTrialRow(
        knobs: WinningKnobs,
        result: Stage2ProbeResult,
        kept: Bool
    ) -> AutotuneTrialRow {
        let fits: Bool
        let nErr: Int
        let notes: String?
        let medianTPS: Double?
        let p95TTFTMS: Double?
        let measuredPromptTokens: Int?

        switch result {
        case .feasible(let tps, let ttft, let promptTokens):
            fits = true
            nErr = 0
            notes = nil
            medianTPS = tps
            p95TTFTMS = ttft
            measuredPromptTokens = promptTokens
        case .infeasible(let reason, let errors, let promptTokens):
            fits = false
            nErr = errors
            notes = reason
            medianTPS = nil
            p95TTFTMS = nil
            measuredPromptTokens = promptTokens
        }

        return AutotuneTrialRow(
            tsUTC: Self.iso8601UTC(now()),
            runID: runID,
            stage: 2,
            model: selectedModel,
            targetContext: targetContext,
            measuredPromptTokens: measuredPromptTokens,
            maxTokens: Stage2Prober.maxTokens(for: targetContext),
            aggThroughputTPS: medianTPS,
            ttftP95MS: p95TTFTMS,
            fits: fits,
            nErr: nErr,
            kept: kept,
            notes: notes,
            kvBits: knobs.kvBits,
            maxContextCap: knobs.maxContext,
            maxBatch: knobs.maxBatch,
            replicatesN: stage2Replicates
        )
    }

    private static func describe(_ knobs: WinningKnobs) -> String {
        let kv = knobs.kvBits.map(String.init) ?? "unset"
        return "kv_bits=\(kv), max_batch=\(knobs.maxBatch), max_context=\(knobs.maxContext)"
    }

    private static func iso8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

struct Stage2Prober: Stage2Probing {
    // Stage 2 deliberately uses the same context-bounded completion budget as
    // Stage 1. Both stages send the same padded Harmony probe; retaining a
    // 64-token Stage 2 cap would make gpt-oss-20b fail tuning after Stage 1
    // had established that its terminal framing needs the larger allowance.
    static func maxTokens(for targetContext: Int) -> Int {
        Stage1Prober.maxTokens(for: targetContext)
    }
    static let defaultProbeIdleTimeoutSec: TimeInterval = 300
    static let defaultProbeTotalTimeoutSec: TimeInterval = 300
    private static let stopTokens = ["<|im_end|>", "<|endoftext|>", "<|eot_id|>"]

    private let session: URLSession
    private let readyTimeoutSec: TimeInterval
    private let stopGraceSeconds: Double
    private let probeTotalTimeoutSec: TimeInterval
    private let clock: () -> Date

    init(
        session: URLSession = .shared,
        readyTimeoutSec: TimeInterval = 120,
        stopGraceSeconds: Double = 10,
        probeTotalTimeoutSec: TimeInterval = Stage2Prober.defaultProbeTotalTimeoutSec,
        clock: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.readyTimeoutSec = readyTimeoutSec
        self.stopGraceSeconds = stopGraceSeconds
        self.probeTotalTimeoutSec = max(1, probeTotalTimeoutSec)
        self.clock = clock
    }

    func probe(
        model: String,
        port: Int,
        runner: CandidateProviderRunner,
        knobs: WinningKnobs,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int
    ) async throws -> Stage2ProbeResult {
        try await probe(
            model: model,
            port: port,
            runner: runner as Stage1ProviderRunning,
            knobs: knobs,
            targetContext: targetContext,
            gateTTFTMS: gateTTFTMS,
            replicates: replicates
        )
    }

    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        knobs: WinningKnobs,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int
    ) async throws -> Stage2ProbeResult {
        let replicateCount = max(1, replicates)
        let measuredPromptTokens = Stage1Prober.promptTokenEstimate(targetContext: targetContext)

        try runner.start(
            model: model,
            port: port,
            kvBits: knobs.kvBits,
            maxContext: knobs.maxContext,
            maxBatch: knobs.maxBatch
        )
        return try await withCandidateProviderCleanup(runner, graceSeconds: stopGraceSeconds) {
        switch try await runner.waitForReady(timeout: readyTimeoutSec) {
        case .ready:
            break
        case .processExited(let rc, let stderrTail):
            return .infeasible(
                reason: "provider exited before Stage 2 probe rc=\(rc): \(stderrTail)",
                nErr: replicateCount,
                measuredPromptTokens: nil
            )
        case .timeout(let lastError):
            return .infeasible(
                reason: "provider readiness timeout before Stage 2 probe: \(lastError)",
                nErr: replicateCount,
                measuredPromptTokens: nil
            )
        }

        var ttfts: [Double] = []
        var throughputs: [Double] = []
        var nErr = 0
        var firstFailure: String?

        for _ in 0..<replicateCount {
            do {
                let result = try await probeOnce(model: model, port: port, targetContext: targetContext)
                guard (200...299).contains(result.statusCode) else {
                    nErr += 1
                    firstFailure = firstFailure ?? "HTTP \(result.statusCode)"
                    continue
                }
                if let leaked = Self.stopTokens.first(where: { result.generatedText.contains($0) }) {
                    return .infeasible(
                        reason: "stop-token leak: \(leaked)",
                        nErr: max(1, nErr + 1),
                        measuredPromptTokens: measuredPromptTokens
                    )
                }
                // Reject non-finite TTFT / non-positive throughput BEFORE
                // recording the replicate. finalizeProbeMetrics returns
                // `(.infinity, 0)` for a stream that generated nothing (empty
                // or zero-usage). This guard MUST run independent of
                // `gateTTFTMS`: when `gateTTFTMS == 0` disables the TTFT
                // ceiling below, an unguarded `(0, ∞)` replicate would be
                // appended and yield `.feasible(medianTPS: 0, p95TTFTMS: ∞)`
                // — an infeasible cell wrongly marked feasible.
                guard result.throughputTPS.isFinite, result.throughputTPS > 0, result.ttftMS.isFinite else {
                    nErr += 1
                    firstFailure = firstFailure ?? "probe produced no measurable throughput (TPS \(result.throughputTPS), TTFT \(result.ttftMS)ms)"
                    continue
                }
                // gateTTFTMS == 0 means the ceiling is disabled (#742: no 60s default).
                if gateTTFTMS > 0, result.ttftMS > Double(gateTTFTMS) {
                    nErr += 1
                    firstFailure = firstFailure ?? "TTFT \(Int(result.ttftMS.rounded()))ms exceeded gate \(gateTTFTMS)ms"
                    continue
                }
                ttfts.append(result.ttftMS)
                throughputs.append(result.throughputTPS)

                if case .processExited(let rc, let stderrTail) = try await runner.waitForReady(timeout: 0.05) {
                    return .infeasible(
                        reason: "provider exited during Stage 2 probe rc=\(rc): \(stderrTail)",
                        nErr: max(1, nErr + 1),
                        measuredPromptTokens: measuredPromptTokens
                    )
                }
            } catch {
                nErr += 1
                firstFailure = firstFailure ?? "probe request failed: \(error.localizedDescription)"
                if case .processExited(let rc, let stderrTail) = try await runner.waitForReady(timeout: 0.05) {
                    return .infeasible(
                        reason: "provider exited during Stage 2 probe rc=\(rc): \(stderrTail)",
                        nErr: nErr,
                        measuredPromptTokens: measuredPromptTokens
                    )
                }
            }
        }

        if nErr > 0 {
            return .infeasible(
                reason: firstFailure ?? "Stage 2 probe failed",
                nErr: nErr,
                measuredPromptTokens: measuredPromptTokens
            )
        }
        guard !ttfts.isEmpty else {
            return .infeasible(
                reason: "Stage 2 probe produced no content",
                nErr: replicateCount,
                measuredPromptTokens: measuredPromptTokens
            )
        }

        // Round-2 security MEDIUM: guard the cell aggregate before declaring it
        // feasible. Even with the per-replicate guards above, the median of
        // enormous-but-finite per-replicate values can overflow to `.infinity`
        // (the averaging is now overflow-safe, but this backstops any residual
        // non-finite/non-positive aggregate). A non-finite or non-positive
        // aggregate is an infeasible cell, never a winner.
        let medianTPS = median(throughputs)
        let p95TTFTMS = percentile95(ttfts)
        guard medianTPS.isFinite, medianTPS > 0, p95TTFTMS.isFinite else {
            return .infeasible(
                reason: "Stage 2 aggregate produced invalid metrics (median TPS \(medianTPS), p95 TTFT \(p95TTFTMS)ms)",
                nErr: replicateCount,
                measuredPromptTokens: measuredPromptTokens
            )
        }

        return .feasible(
            medianTPS: medianTPS,
            p95TTFTMS: p95TTFTMS,
            measuredPromptTokens: measuredPromptTokens
        )
        }
    }

    private func probeOnce(model: String, port: Int, targetContext: Int) async throws -> Stage2SingleProbeResult {
        try await withThrowingTaskGroup(of: Stage2SingleProbeResult.self) { group in
            group.addTask {
                try await self.probeOnceWithoutDeadline(model: model, port: port, targetContext: targetContext)
            }
            group.addTask {
                let nanoseconds = UInt64(self.probeTotalTimeoutSec * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func probeOnceWithoutDeadline(model: String, port: Int, targetContext: Int) async throws -> Stage2SingleProbeResult {
        let maxTokens = Self.maxTokens(for: targetContext)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.defaultProbeIdleTimeoutSec
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                [
                    "role": "user",
                    "content": Stage1Prober.paddedPrompt(targetContext: targetContext),
                ],
            ],
        ])

        let started = clock()
        let (bytes, response) = try await session.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        var generatedText = ""
        var firstTokenAt: Date?
        // Reasoning models (gpt-oss-20b / Harmony) suppress their
        // analysis/reasoning channel from `delta.content`, so on the
        // probe's nonsense padded prompt they generate tokens but emit
        // ZERO visible content deltas. The provider closes the stream with
        // a usage chunk (`choices: []` + `usage`) that carries the honest
        // total decode count in `macprovider_generated_completion_tokens`
        // (all channels incl. suppressed reasoning; HTTPServer.swift
        // `usage()`) and the warm-decode wall-time in
        // `macprovider_generation_ms`. Track the latest reported values so
        // finalization can derive throughput from them, not from counting
        // visible content deltas — otherwise reasoning models measure
        // 0 tok/s and are wrongly marked infeasible.
        var usageDecodedTokens: Int?
        var usageGenerationMS: Int?

        for try await rawLine in bytes.lines {
            guard rawLine.hasPrefix("data:") else {
                continue
            }
            let payload = rawLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                break
            }
            if let usage = Stage1Prober.usageDecodedTokens(from: payload, maxTokens: maxTokens) {
                usageDecodedTokens = usage
            }
            if let generationMS = Stage1Prober.usageGenerationMS(from: payload) {
                usageGenerationMS = generationMS
            }
            guard let content = Self.contentDelta(from: payload), !content.isEmpty else {
                continue
            }
            if firstTokenAt == nil {
                firstTokenAt = clock()
            }
            generatedText += content
        }

        let ended = clock()
        // Share Stage 1's finalization so both stages agree on decode
        // throughput and the reasoning-model fallback. Stage 2 preserves its
        // historical content-fallback numerator (word count of the visible
        // text) for older serve builds without the vendor timing field.
        let contentWordCount = generatedText.split(whereSeparator: \.isWhitespace).count
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: contentWordCount,
            usageDecodedTokens: usageDecodedTokens,
            usageGenerationMS: usageGenerationMS,
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        return Stage2SingleProbeResult(
            statusCode: statusCode,
            ttftMS: metrics.ttftMS,
            generatedText: generatedText,
            throughputTPS: metrics.throughputTPS
        )
    }

    private static func contentDelta(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first
        else {
            return nil
        }
        if let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String
        {
            return content
        }
        if let text = first["text"] as? String {
            return text
        }
        return nil
    }

    private func percentile95(_ values: [Double]) -> Double {
        Stage2Prober.percentile95(values)
    }

    static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1))
        return sorted[index]
    }

    private func median(_ values: [Double]) -> Double {
        Stage2Prober.median(values)
    }

    /// Overflow-safe median. Internal (not private) so the round-2 security
    /// MEDIUM overflow guard is directly unit-testable.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            // Round-2 security MEDIUM: average as `a/2 + b/2` rather than
            // `(a + b) / 2` so two enormous-but-finite middle values do not
            // overflow to `.infinity` before the aggregate guard runs.
            return sorted[mid - 1] / 2 + sorted[mid] / 2
        }
        return sorted[mid]
    }
}

private struct Stage2SingleProbeResult {
    var statusCode: Int
    var ttftMS: Double
    var generatedText: String
    var throughputTPS: Double
}
