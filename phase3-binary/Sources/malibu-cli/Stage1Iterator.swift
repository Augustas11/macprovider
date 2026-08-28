import Foundation

/// Exact artifact identity selected and verified by the recommendation parent.
/// Candidate processes must receive this binding instead of resolving a model
/// name again from mutable local cache state.
struct CandidateArtifactBinding: Equatable, Sendable {
    let path: String
    let sha256: String
}

protocol Stage1ProviderRunning: AnyObject {
    func start(
        model: String,
        port: Int,
        kvBits: Int?,
        maxContext: Int?,
        maxBatch: Int?
    ) throws
    func start(
        model: String,
        port: Int,
        kvBits: Int?,
        maxContext: Int?,
        maxBatch: Int?,
        artifactBinding: CandidateArtifactBinding?
    ) throws
    func waitForReady(timeout: TimeInterval) async throws -> ReadyStatus
    @discardableResult
    func stop(graceSeconds: Double) -> StopResult
}

extension Stage1ProviderRunning {
    func start(
        model: String,
        port: Int,
        kvBits: Int?,
        maxContext: Int?,
        maxBatch: Int?,
        artifactBinding: CandidateArtifactBinding?
    ) throws {
        // Existing test/fallback runners do not need artifact binding; the
        // production runner supplies the stronger witness below.
        try start(model: model, port: port, kvBits: kvBits, maxContext: maxContext, maxBatch: maxBatch)
    }
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
    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int,
        artifactBinding: CandidateArtifactBinding?
    ) async throws -> Stage1ProbeResult
}

extension Stage1Probing {
    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int,
        artifactBinding: CandidateArtifactBinding?
    ) async throws -> Stage1ProbeResult {
        try await probe(
            model: model,
            port: port,
            runner: runner,
            targetContext: targetContext,
            gateTTFTMS: gateTTFTMS,
            replicates: replicates
        )
    }
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

enum CandidateProviderTeardownError: Error, Equatable, CustomStringConvertible {
    case stuck(pid: Int32)

    var description: String {
        switch self {
        case .stuck(let pid):
            return "candidate provider teardown remained stuck (pid \(pid))"
        }
    }
}

func withCandidateProviderCleanup<T>(
    _ runner: Stage1ProviderRunning,
    graceSeconds: Double,
    operation: () async throws -> T
) async throws -> T {
    do {
        let value = try await operation()
        switch runner.stop(graceSeconds: graceSeconds) {
        case .stopped:
            return value
        case .stuck(let pid):
            throw CandidateProviderTeardownError.stuck(pid: pid)
        }
    } catch {
        switch runner.stop(graceSeconds: graceSeconds) {
        case .stopped:
            throw error
        case .stuck(let pid):
            throw CandidateProviderTeardownError.stuck(pid: pid)
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
            maxTokens: Stage1Prober.maxTokens(for: targetContext),
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
    // Harmony reasoning models such as gpt-oss-20b may need more than a
    // short visible answer budget to finish their internal response framing.
    // At 64 tokens the 3,200-token admission probe can truncate the Harmony
    // tool-call JSON and the provider returns malformed_tool_call_final_json
    // without terminal usage. This is the maximum for Stage 1; the actual
    // request cap is reduced for smaller target contexts below.
    static let maxTokens = 512
    // Reserve space for the chat template and Harmony framing around the
    // padded user prompt. The measured 4,000-token admission request uses
    // 3,269 prompt tokens, so this leaves the full 512-token completion cap
    // within that context while keeping smaller classic autotune requests
    // bounded too.
    private static let promptOverheadReserve = 128
    /// URL request idle-timeout (URLSession semantics: max seconds without any
    /// bytes arriving from the server). Must cover prefill TTFT for the largest
    /// supported candidate on the weakest supported hardware (30B MoE on M-Base
    /// prefilling a ~3200-token probe can take 60-180s before first byte).
    /// A value below 200s produced silent .infeasible timeouts on M-Base;
    /// keeping headroom above measured maxima. See SPEC-023 v1.7.5.
    static let defaultProbeIdleTimeoutSec: TimeInterval = 300
    /// Hard wall-clock ceiling for one streamed probe. URLRequest's timeout is
    /// an idle timeout, so it cannot bound a stream that emits bytes slowly.
    /// The task race below enforces this total duration as well as the idle
    /// timeout.
    static let defaultProbeTotalTimeoutSec: TimeInterval = 300
    private static let stopTokens = ["<|im_end|>", "<|endoftext|>", "<|eot_id|>"]

    private let session: URLSession
    private let readyTimeoutSec: TimeInterval
    private let stopGraceSeconds: Double
    private let probeIdleTimeoutSec: TimeInterval
    private let probeTotalTimeoutSec: TimeInterval
    private let clock: () -> Date

    init(
        session: URLSession = .shared,
        readyTimeoutSec: TimeInterval = 120,
        stopGraceSeconds: Double = 10,
        probeIdleTimeoutSec: TimeInterval = Stage1Prober.defaultProbeIdleTimeoutSec,
        probeTotalTimeoutSec: TimeInterval = Stage1Prober.defaultProbeTotalTimeoutSec,
        clock: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.readyTimeoutSec = readyTimeoutSec
        self.stopGraceSeconds = stopGraceSeconds
        self.probeIdleTimeoutSec = max(1, probeIdleTimeoutSec)
        self.probeTotalTimeoutSec = max(1, probeTotalTimeoutSec)
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
        try await probe(
            model: model,
            port: port,
            runner: runner,
            targetContext: targetContext,
            gateTTFTMS: gateTTFTMS,
            replicates: replicates,
            artifactBinding: nil
        )
    }

    func probe(
        model: String,
        port: Int,
        runner: Stage1ProviderRunning,
        targetContext: Int,
        gateTTFTMS: Int,
        replicates: Int,
        artifactBinding: CandidateArtifactBinding?
    ) async throws -> Stage1ProbeResult {
        try runner.start(
            model: model,
            port: port,
            kvBits: nil,
            maxContext: targetContext,
            maxBatch: nil,
            artifactBinding: artifactBinding
        )
        return try await withCandidateProviderCleanup(runner, graceSeconds: stopGraceSeconds) {
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

        // Issue #901 / v1.7.7 Track A3: prewarm the subprocess before
        // measuring TTFT. The discard request is deliberately outside the
        // sample arrays below, so ttftMS records warm serving latency rather
        // than the first request's cold-start/JIT/prefill latency.
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
    }

    static func promptTokenEstimate(targetContext: Int) -> Int {
        max(1, Int((Double(targetContext) * 0.8).rounded(.down)))
    }

    static func paddedPrompt(targetContext: Int) -> String {
        Array(repeating: "probe", count: promptTokenEstimate(targetContext: targetContext))
            .joined(separator: " ")
    }

    static func maxTokens(for targetContext: Int) -> Int {
        let available = targetContext
            - promptTokenEstimate(targetContext: targetContext)
            - promptOverheadReserve
        return max(1, min(maxTokens, available))
    }

    private func probeOnce(model: String, port: Int, targetContext: Int) async throws -> SingleProbeResult {
        try await withThrowingTaskGroup(of: SingleProbeResult.self) { group in
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

    private func probeOnceWithoutDeadline(model: String, port: Int, targetContext: Int) async throws -> SingleProbeResult {
        let maxTokens = Self.maxTokens(for: targetContext)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = probeIdleTimeoutSec
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "temperature": 0,
            "max_tokens": maxTokens,
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
        // Reasoning models (gpt-oss-20b / Harmony) suppress their
        // analysis/reasoning channel from `delta.content`, so on the
        // probe's nonsense padded prompt they generate tokens but emit
        // ZERO visible content deltas. The provider closes the stream with
        // a usage chunk (`choices: []` + `usage`) that carries the honest
        // total decode count in `macprovider_generated_completion_tokens`
        // (all channels incl. suppressed reasoning; HTTPServer.swift
        // `usage()`). Track the latest reported value so finalization can
        // derive throughput from it, not from counting visible content
        // deltas — otherwise reasoning models measure 0 tok/s and are
        // wrongly marked infeasible.
        var usageDecodedTokens: Int?
        // Provider-reported warm-decode wall-time (ms) from the terminal
        // usage chunk (`macprovider_generation_ms`). This is the ONLY honest
        // decode-window signal for reasoning models, whose analysis channel
        // is silent in the SSE stream so the client cannot time it. When
        // present, finalization divides total decoded tokens by this window
        // instead of any client-observed timing. Whole milliseconds (the
        // provider emits an Int64); see `usageGenerationMS(from:)`.
        var usageGenerationMS: Int?

        for try await rawLine in bytes.lines {
            guard rawLine.hasPrefix("data:") else {
                continue
            }
            let payload = rawLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                break
            }
            if let usage = Self.usageDecodedTokens(from: payload, maxTokens: maxTokens) {
                usageDecodedTokens = usage
            }
            if let generationMS = Self.usageGenerationMS(from: payload) {
                usageGenerationMS = generationMS
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

        let ended = clock()
        let metrics = Self.finalizeProbeMetrics(
            contentFallbackTokens: deltaCount,
            usageDecodedTokens: usageDecodedTokens,
            usageGenerationMS: usageGenerationMS,
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        return SingleProbeResult(
            statusCode: statusCode,
            ttftMS: metrics.ttftMS,
            generatedText: generatedText,
            throughputTPS: metrics.throughputTPS
        )
    }

    /// Derives TTFT and decode throughput from a completed probe stream.
    /// Extracted as a pure static function so the finalization logic is
    /// unit-testable without spawning a provider process.
    ///
    /// Throughput branch order (highest fidelity first). The decoded-token
    /// count is authoritative: `nil` means absent/invalid, an explicit `0`
    /// means the provider decoded nothing (infeasible), and any positive value
    /// is the all-channel decode count.
    ///
    ///  1. **Decoded count present (authoritative).**
    ///     a. `== 0` → `(.infinity, 0)` — the provider reports it decoded
    ///        nothing; infeasible regardless of any observed content (round-2
    ///        code MEDIUM-2).
    ///     b. `> 0` AND `usageGenerationMS != nil && ms >= 1` → provider-timed:
    ///        `usageDecodedTokens / max(0.001, ms/1000)`. This is the only
    ///        correct path for reasoning models: their analysis channel is
    ///        silent in SSE, so client-observed timing cannot see the decode
    ///        window at all. The 1 ms floor bounds throughput (round-2 security
    ///        HIGH: a fractional/sub-ms window otherwise inflates TPS).
    ///     c. `> 0` with no usable ms → warm-generation window when a visible
    ///        token was seen (`ended - firstTokenAt`), else the full request
    ///        window (`ended - started`); both floored at 0.001s. Conservative
    ///        but positive.
    ///  2. **Decoded count absent (`nil`).**
    ///     a. Legacy content window for older serve builds (non-reasoning
    ///        models) that stream visible content but no vendor usage fields:
    ///        `contentFallbackTokens / max(0.001, ended - firstTokenAt)`.
    ///     b. else → `(.infinity, 0)`, the genuinely-infeasible case.
    ///
    /// TTFT is the first-content-token elapsed when a visible token was seen;
    /// otherwise the full request elapsed (best available signal for a
    /// reasoning-only stream). It is NEVER `.infinity` when tokens were
    /// decoded.
    static func finalizeProbeMetrics(
        contentFallbackTokens: Int,
        usageDecodedTokens: Int?,
        usageGenerationMS: Int?,
        firstTokenAt: Date?,
        started: Date,
        ended: Date
    ) -> (ttftMS: Double, throughputTPS: Double) {
        // TTFT: time to first content token when observed; otherwise the
        // full request elapsed (best available signal for a reasoning-only
        // stream). Computed up front so every non-infeasible branch shares it.
        let ttftMS = firstTokenAt.map { max(0, $0.timeIntervalSince(started) * 1_000) }
            ?? max(0, ended.timeIntervalSince(started) * 1_000)

        // Branch 1: authoritative decoded-token count present (may be 0).
        if let usageDecodedTokens {
            // 1a: an authoritative 0 means the provider decoded nothing —
            // infeasible regardless of any observed content.
            if usageDecodedTokens == 0 {
                return (ttftMS: .infinity, throughputTPS: 0)
            }
            // 1b: provider-timed. Only when the vendor decode window is present,
            // at least 1 whole millisecond, AND not larger than the observed
            // request wall-time (plus a small tolerance for clock skew /
            // measurement boundaries). The decode window is a subset of the
            // request, so a value exceeding the observed request duration —
            // e.g. an overflowed `Int64.max` that would otherwise yield a
            // garbage ~0 TPS "feasible" replicate — is malformed and ignored,
            // falling through to the conservative client-timed window. Floor
            // the denominator at 1 ms.
            let requestElapsedMS = max(0, ended.timeIntervalSince(started) * 1_000)
            let generationWindowToleranceMS = 250.0
            if let usageGenerationMS, usageGenerationMS >= 1,
               Double(usageGenerationMS) <= requestElapsedMS + generationWindowToleranceMS {
                let generationElapsedSec = max(0.001, Double(usageGenerationMS) / 1000)
                return (ttftMS: ttftMS, throughputTPS: Double(usageDecodedTokens) / generationElapsedSec)
            }
            // 1c: decoded count but no usable timing — divide by the
            // warm-generation window when a visible token was seen, else the
            // full request window. Both floored at 0.001s.
            if let firstTokenAt {
                let generationElapsed = max(0.001, ended.timeIntervalSince(firstTokenAt))
                return (ttftMS: ttftMS, throughputTPS: Double(usageDecodedTokens) / generationElapsed)
            }
            let requestElapsed = max(0.001, ended.timeIntervalSince(started))
            return (ttftMS: ttftMS, throughputTPS: Double(usageDecodedTokens) / requestElapsed)
        }

        // Branch 2a: legacy warm-generation window for older serve builds
        // (non-reasoning models) that stream visible content but no vendor
        // usage fields. `firstTokenAt` is only set on a NON-empty content
        // delta, so content was observed — at least one token was generated
        // even when the delta/word count rounds to 0 (e.g. a whitespace-only
        // delta like " "). `max(1, ...)` preserves the pre-existing Stage 1
        // `max(1, deltaCount)` / Stage 2 `max(1, wordCount)` fallback and
        // avoids a false-infeasible verdict on such legacy output.
        if let firstTokenAt {
            let fallbackTokens = max(1, contentFallbackTokens)
            let generationElapsed = max(0.001, ended.timeIntervalSince(firstTokenAt))
            return (ttftMS: ttftMS, throughputTPS: Double(fallbackTokens) / generationElapsed)
        }

        // Branch 2b: genuinely nothing generated.
        return (ttftMS: .infinity, throughputTPS: 0)
    }

    /// Extracts the `usage` object from a payload IFF the payload is a
    /// genuine terminal usage chunk: a valid JSON object with a top-level
    /// `choices` key that is an EMPTY array and a `usage` object. A content
    /// chunk that also carries `usage` has a non-empty `choices` array and is
    /// rejected here so it is never mistaken for the terminal usage chunk.
    private static func terminalUsageObject(from payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [Any], choices.isEmpty,
              let usage = json["usage"] as? [String: Any]
        else {
            return nil
        }
        return usage
    }

    /// True when `num` is a JSON boolean masquerading as an `NSNumber`
    /// (`true`/`false` bridge to `NSNumber` and would otherwise pass numeric
    /// checks as 1/0).
    private static func isBoolean(_ num: NSNumber) -> Bool {
        CFGetTypeID(num) == CFBooleanGetTypeID()
    }

    /// Parses the streamed terminal usage chunk (`choices: []` + top-level
    /// `usage`) and returns the honest decode-token count for throughput
    /// measurement.
    ///
    /// Prefers `usage.macprovider_generated_completion_tokens` — the total
    /// tokens the model decoded across ALL channels (reasoning/analysis +
    /// final). This is the correct throughput numerator: for Harmony
    /// reasoning models (gpt-oss-20b) the analysis channel is suppressed
    /// from `completion_tokens`, so on the probe's gibberish prompt
    /// `completion_tokens` can be ~0 while real decode work happened.
    /// Falls back to `usage.completion_tokens` for older serve builds that
    /// predate the namespaced field (non-reasoning models, where the two
    /// are equal).
    ///
    /// Hardened against malformed/hostile values: rejects booleans,
    /// non-integral (fractional) numbers, negatives, and values greater than
    /// `maxTokens` (the probe caps `max_tokens` at `maxTokens`; an honest
    /// provider cannot decode more completion tokens than the cap, so a
    /// larger value — including an overflowed `Int.max` — is malformed).
    /// Returns nil for ordinary content chunks, `[DONE]`, malformed payloads,
    /// and any value failing validation, which makes finalization fall back
    /// rather than trust an inflated count.
    static func usageDecodedTokens(from payload: String, maxTokens: Int = Self.maxTokens) -> Int? {
        guard let usage = terminalUsageObject(from: payload) else {
            return nil
        }
        // Round-2 code MEDIUM-1: when the namespaced field is PRESENT it is
        // authoritative — its validation result (which is nil for a bool,
        // fractional, negative, or over-cap value) is returned as-is. We must
        // NOT fall back to `completion_tokens` in that case, or a hostile
        // provider could suppress the honest all-channel count with a
        // malformed value and have the probe trust the (possibly ~0)
        // final-channel `completion_tokens` instead.
        if let generatedRaw = usage["macprovider_generated_completion_tokens"] {
            guard let generated = generatedRaw as? NSNumber else { return nil }
            return validatedTokenCount(generated, maxTokens: maxTokens)
        }
        if let completionTokens = usage["completion_tokens"] as? NSNumber {
            return validatedTokenCount(completionTokens, maxTokens: maxTokens)
        }
        return nil
    }

    /// Validates an `NSNumber` token count: not a boolean, integral,
    /// nonnegative, and not greater than `maxTokens`. Returns the `Int` value
    /// or nil.
    private static func validatedTokenCount(_ num: NSNumber, maxTokens: Int) -> Int? {
        guard !isBoolean(num) else { return nil }
        let value = num.doubleValue
        guard value.isFinite else { return nil }
        // Integral check: reject fractional values.
        guard Double(num.int64Value) == value else { return nil }
        let tokens = num.int64Value
        guard tokens >= 0, tokens <= Int64(max(1, maxTokens)) else { return nil }
        return Int(tokens)
    }

    /// Parses the provider-reported warm-decode wall-time
    /// (`macprovider_generation_ms`) from the terminal usage chunk. The
    /// provider emits this as an `Int64` (whole milliseconds), so the value
    /// must be a non-boolean, finite, integral, nonnegative `NSNumber`.
    /// Round-2 security HIGH: a lenient `Double` accepted sub-millisecond
    /// values (e.g. `0.001`) that inflated throughput by ~10^6; rejecting
    /// fractional/negative/non-finite values (→ nil) forces finalization onto
    /// a floored, honest window. Returns whole `Int` milliseconds, else nil.
    static func usageGenerationMS(from payload: String) -> Int? {
        guard let usage = terminalUsageObject(from: payload),
              let generationMS = usage["macprovider_generation_ms"] as? NSNumber,
              !isBoolean(generationMS)
        else {
            return nil
        }
        let value = generationMS.doubleValue
        guard value.isFinite else { return nil }
        // Integral check: reject fractional values.
        guard Double(generationMS.int64Value) == value else { return nil }
        let ms = generationMS.int64Value
        guard ms >= 0 else { return nil }
        return Int(ms)
    }

    static func contentDelta(from payload: String) -> String? {
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
            // Overflow-safe average (round-2 security MEDIUM): `a/2 + b/2`
            // avoids the intermediate `a + b` overflowing to `.infinity`.
            return sorted[mid - 1] / 2 + sorted[mid] / 2
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
