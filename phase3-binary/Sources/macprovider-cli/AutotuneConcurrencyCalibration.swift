import Foundation

/// SPEC-023-R009 (§9.2): empirical, opt-in concurrency calibration.
///
/// The served provider's `max_concurrency_override` sizes the serve
/// `--max-batch` semaphore and is advertised 1:1 to the coordinator as
/// `slots_total`. `autotune --recommend` emits it from a blind chip/RAM tier
/// constant (`AutotuneRecommendHardware.recommendedMaxBatch`) that never
/// measures the specific box. This type measures the selected, already-verified
/// artifact's steady-state *aggregate* decode throughput and per-stream tail
/// TTFT across a bounded batch sweep and selects the empirically best depth,
/// bounded only by memory fit and the buyer-facing TTFT ceiling, with zero
/// errors. It is engine-agnostic
/// by construction: it drives genuine concurrent load and measures whatever
/// serve mode production runs (independent single-stream today; shared-forward
/// continuous batching, SPEC-038/039, once enabled).

struct AutotuneConcurrencyCalibrationMeasurement: Codable, Equatable {
    var batchDepth: Int
    var streams: Int
    var aggregateTPS: Double
    var perStreamP95TTFTMS: Int?
    /// Median per-stream decode rate (tok/s) under this depth's steady-state
    /// load. Informational, never a gate. Optional so stored v1 records (which
    /// never measured it) decode, and nil when the window had no measurable
    /// per-stream decode span.
    var perStreamDecodeTPS: Double? = nil
    var passed: Bool
    var failureReason: String? = nil

    enum CodingKeys: String, CodingKey {
        case batchDepth = "batch_depth"
        case streams
        case aggregateTPS = "aggregate_tps"
        case perStreamP95TTFTMS = "per_stream_p95_ttft_ms"
        case perStreamDecodeTPS = "per_stream_decode_tps"
        case passed
        case failureReason = "failure_reason"
    }
}

struct AutotuneConcurrencyCalibrationResult: Codable, Equatable {
    /// v2 (SPEC-023 v0.22.14): `ttft_regression_factor` no longer gates;
    /// `probe_prompt_tokens` and per-measurement `per_stream_decode_tps`
    /// added.
    static let schemaVersion = "autotune_concurrency_calibration.v2"
    /// v2 still writes `ttft_regression_factor`, fixed at the v1 default,
    /// because a pre-v2 CLI decodes stored recommendation state with that
    /// key required: a rolled-back CLI must still load a v2 record. It is a
    /// compatibility constant, not a gate (SPEC-023-R009).
    static let legacyTTFTRegressionFactor = 1.5

    var schemaVersion: String = Self.schemaVersion
    var recommendedMaxBatch: Int
    var tierConstantMaxBatch: Int
    var memoryFitCap: Int
    var hardCap: Int
    var ttftCeilingMS: Int
    var ttftRegressionFactor: Double = Self.legacyTTFTRegressionFactor
    var minAggregateGainFraction: Double
    var calibrationContextTokens: Int
    var probePromptTokens: Int
    var promptReserveTokens: Int
    var completionTokens: Int
    var draftPinned: Bool
    var measurements: [AutotuneConcurrencyCalibrationMeasurement]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recommendedMaxBatch = "recommended_max_batch"
        case tierConstantMaxBatch = "tier_constant_max_batch"
        case memoryFitCap = "memory_fit_cap"
        case hardCap = "hard_cap"
        case ttftCeilingMS = "ttft_ceiling_ms"
        case ttftRegressionFactor = "ttft_regression_factor"
        case minAggregateGainFraction = "min_aggregate_gain_fraction"
        case calibrationContextTokens = "calibration_context_tokens"
        case probePromptTokens = "probe_prompt_tokens"
        case promptReserveTokens = "prompt_reserve_tokens"
        case completionTokens = "completion_tokens"
        case draftPinned = "draft_pinned"
        case measurements
    }

    init(
        recommendedMaxBatch: Int,
        tierConstantMaxBatch: Int,
        memoryFitCap: Int,
        hardCap: Int,
        ttftCeilingMS: Int,
        minAggregateGainFraction: Double,
        calibrationContextTokens: Int,
        probePromptTokens: Int,
        promptReserveTokens: Int,
        completionTokens: Int,
        draftPinned: Bool,
        measurements: [AutotuneConcurrencyCalibrationMeasurement]
    ) {
        self.recommendedMaxBatch = recommendedMaxBatch
        self.tierConstantMaxBatch = tierConstantMaxBatch
        self.memoryFitCap = memoryFitCap
        self.hardCap = hardCap
        self.ttftCeilingMS = ttftCeilingMS
        self.minAggregateGainFraction = minAggregateGainFraction
        self.calibrationContextTokens = calibrationContextTokens
        self.probePromptTokens = probePromptTokens
        self.promptReserveTokens = promptReserveTokens
        self.completionTokens = completionTokens
        self.draftPinned = draftPinned
        self.measurements = measurements
    }

    /// Stored recommendation state may hold a v1 record. It keeps its own
    /// `schema_version`, its `ttft_regression_factor` is carried but never
    /// gates, and the
    /// v2-only `probe_prompt_tokens` it never recorded decodes as 0 instead of
    /// failing the whole state load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(String.self, forKey: .schemaVersion)
        recommendedMaxBatch = try c.decode(Int.self, forKey: .recommendedMaxBatch)
        tierConstantMaxBatch = try c.decode(Int.self, forKey: .tierConstantMaxBatch)
        memoryFitCap = try c.decode(Int.self, forKey: .memoryFitCap)
        hardCap = try c.decode(Int.self, forKey: .hardCap)
        ttftCeilingMS = try c.decode(Int.self, forKey: .ttftCeilingMS)
        ttftRegressionFactor = try c.decodeIfPresent(Double.self, forKey: .ttftRegressionFactor)
            ?? Self.legacyTTFTRegressionFactor
        minAggregateGainFraction = try c.decode(Double.self, forKey: .minAggregateGainFraction)
        calibrationContextTokens = try c.decode(Int.self, forKey: .calibrationContextTokens)
        probePromptTokens = try c.decodeIfPresent(Int.self, forKey: .probePromptTokens) ?? 0
        promptReserveTokens = try c.decode(Int.self, forKey: .promptReserveTokens)
        completionTokens = try c.decode(Int.self, forKey: .completionTokens)
        draftPinned = try c.decode(Bool.self, forKey: .draftPinned)
        measurements = try c.decode([AutotuneConcurrencyCalibrationMeasurement].self, forKey: .measurements)
    }

    /// Deterministic field order matching the SPEC-023 §6 output contract.
    var jsonString: String {
        let samples = measurements.map { sample in
            """
            {"batch_depth":\(sample.batchDepth),"streams":\(sample.streams),"aggregate_tps":\(concurrencyCalibrationJSONNumber(sample.aggregateTPS)),"per_stream_p95_ttft_ms":\(sample.perStreamP95TTFTMS.map(String.init) ?? "null"),"per_stream_decode_tps":\(sample.perStreamDecodeTPS.map(concurrencyCalibrationJSONNumber) ?? "null"),"passed":\(sample.passed),"failure_reason":\(sample.failureReason.map(concurrencyCalibrationJSONString) ?? "null")}
            """
        }.joined(separator: ",")
        return """
        {"schema_version":\(concurrencyCalibrationJSONString(schemaVersion)),"recommended_max_batch":\(recommendedMaxBatch),"tier_constant_max_batch":\(tierConstantMaxBatch),"memory_fit_cap":\(memoryFitCap),"hard_cap":\(hardCap),"ttft_ceiling_ms":\(ttftCeilingMS),"ttft_regression_factor":\(concurrencyCalibrationJSONNumber(ttftRegressionFactor)),"min_aggregate_gain_fraction":\(concurrencyCalibrationJSONNumber(minAggregateGainFraction)),"calibration_context_tokens":\(calibrationContextTokens),"probe_prompt_tokens":\(probePromptTokens),"prompt_reserve_tokens":\(promptReserveTokens),"completion_tokens":\(completionTokens),"draft_pinned":\(draftPinned),"measurements":[\(samples)]}
        """
    }
}

private func concurrencyCalibrationJSONNumber(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    return String(format: "%.6f", value)
        .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
}

private func concurrencyCalibrationJSONString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
}

enum AutotuneConcurrencyCalibrationError: Error, Equatable, CustomStringConvertible {
    case invalidBounds(memoryFitCap: Int, hardCap: Int)
    case baselineFailed(reason: String)
    case probeFailed(batchDepth: Int, reason: String)
    case interrupted
    case deadlineExceeded

    var description: String {
        switch self {
        case .invalidBounds(let memoryFitCap, let hardCap):
            return "concurrency calibration bounds are invalid: memory_fit_cap=\(memoryFitCap), hard_cap=\(hardCap)"
        case .baselineFailed(let reason):
            return "concurrency calibration baseline (batch=1) failed: \(reason)"
        case .probeFailed(let batchDepth, let reason):
            return "concurrency calibration batch=\(batchDepth) probe failed: \(reason)"
        case .interrupted:
            return "concurrency calibration interrupted"
        case .deadlineExceeded:
            return "concurrency calibration exceeded --max-duration"
        }
    }
}

/// Outcome of measuring one batch depth under steady-state closed-loop load:
/// in-window aggregate decode throughput across all streams, per-stream p95
/// TTFT, and the median per-stream decode rate (informational; nil when no
/// request had a measurable decode span inside the window).
enum ConcurrencyProbeOutcome: Equatable {
    case feasible(aggregateTPS: Double, perStreamP95TTFTMS: Double, perStreamDecodeTPS: Double?)
    case infeasible(reason: String, nErr: Int)
}

protocol AutotuneConcurrencyCalibrationProbing {
    /// Start a local non-joining serve at `--max-batch batchDepth` and the
    /// production `calibrationContext`, keep `batchDepth` closed-loop workers
    /// issuing uncached, distinct requests of `promptTokens` prompt tokens and
    /// `completionTokens` completion tokens (SPEC-023-R009 step 2), and return
    /// the steady-state window metrics. Implementations MUST apply the
    /// probe-safety (swap/thermal) veto.
    func measure(
        batchDepth: Int,
        calibrationContext: Int,
        promptTokens: Int,
        completionTokens: Int,
        deadline: Date?
    ) async throws -> ConcurrencyProbeOutcome
}

struct AutotuneConcurrencyCalibrator {
    /// Default probe request shape (SPEC-023-R009 step 2): a fixed synthetic
    /// agent-chat shape, overridable with
    /// `--calibrate-concurrency-prompt-tokens` and
    /// `--calibrate-concurrency-completion-tokens` for a known workload. No
    /// buyer-traffic data exists yet to choose it from; it replaces a
    /// context-filling prompt with a 64-token completion, a shape nobody sends.
    static let defaultProbePromptTokens = 1_792
    static let defaultProbeCompletionTokens = 1_024
    static let promptReserveTokens = 256

    /// Per-request prompt length: the requested prompt, shrunk only when the
    /// calibration context cannot hold it plus the reserve and completion.
    static func probePromptTokens(
        requested: Int = defaultProbePromptTokens,
        calibrationContext: Int,
        promptReserveTokens: Int,
        completionTokens: Int
    ) -> Int {
        max(1, min(requested, calibrationContext - promptReserveTokens - completionTokens))
    }

    /// Served hard cap.
    var hardCap = ProviderCapacity.maxConcurrencyOverrideLimit
    /// The buyer-facing TTFT ceiling is the only latency gate. There is no
    /// gate relative to batch=1: under continuous batching any queued prefill
    /// raises TTFT at every depth above 1, so a relative gate blocks every
    /// depth regardless of throughput (#1906).
    var ttftCeilingMS = 8_000
    /// Selection tie band: the LOWEST feasible depth whose aggregate is within
    /// this fraction of the best measured aggregate wins (memory-risk posture,
    /// SPEC-029 FR-5), so a few percent of noise does not add slots.
    var minAggregateGainFraction = 0.15

    /// Depths above this are swept on a coarse ladder rather than one at a
    /// time: each depth is a full serve restart, and on the 256 GB Ultra the
    /// aggregate gain per added row past 8 is a few percent (#1906).
    static let contiguousSweepLimit = 8
    static let coarseSweepDepths = [12, 16, 24, 32]

    /// Ascending depths to measure: 1...min(upperBound, 8) one at a time, then
    /// the coarse ladder, then `upperBound` itself when it falls between rungs.
    static func sweepDepths(upperBound: Int) -> [Int] {
        let bound = max(1, upperBound)
        var depths = Array(1...min(bound, contiguousSweepLimit))
        depths += coarseSweepDepths.filter { $0 <= bound }
        if bound > contiguousSweepLimit, depths.last != bound {
            depths.append(bound)
        }
        return depths
    }

    /// Highest aggregate wins, tie-broken toward the LOWEST depth whose
    /// aggregate is within `minAggregateGainFraction` of that best.
    static func selectDepth(
        feasible: [AutotuneConcurrencyCalibrationMeasurement],
        minAggregateGainFraction: Double
    ) -> Int {
        guard let best = feasible.map(\.aggregateTPS).max() else { return 1 }
        let threshold = best / (1 + minAggregateGainFraction)
        return feasible
            .filter { $0.aggregateTPS >= threshold }
            .map(\.batchDepth)
            .min() ?? 1
    }

    /// SPEC-023-R009. `memoryFitCap` is the largest depth whose weights + KV at
    /// the production context/kv_bits fit the §5/§9 memory-safety envelope.
    /// `tierConstant` is the blind `recommendedMaxBatch` value this measurement
    /// is compared against and recorded alongside. When `draftConfigured`, the
    /// value is pinned to 1 with no sweep (SPEC-028 FR-4).
    func calibrate(
        memoryFitCap: Int,
        tierConstant: Int,
        draftConfigured: Bool,
        calibrationContext: Int,
        promptTokens requestedPromptTokens: Int = AutotuneConcurrencyCalibrator.defaultProbePromptTokens,
        promptReserveTokens: Int,
        completionTokens: Int,
        prober: AutotuneConcurrencyCalibrationProbing,
        deadline: Date? = nil,
        isInterrupted: @escaping () -> Bool = { false },
        hasDeadlineExpired: @escaping () -> Bool = { false }
    ) async throws -> AutotuneConcurrencyCalibrationResult {
        guard hardCap >= 1,
              ttftCeilingMS >= 1,
              minAggregateGainFraction >= 0,
              memoryFitCap >= 1
        else {
            throw AutotuneConcurrencyCalibrationError.invalidBounds(memoryFitCap: memoryFitCap, hardCap: hardCap)
        }

        let promptTokens = Self.probePromptTokens(
            requested: requestedPromptTokens,
            calibrationContext: calibrationContext,
            promptReserveTokens: promptReserveTokens,
            completionTokens: completionTokens
        )

        func makeResult(
            recommended: Int,
            draftPinned: Bool,
            measurements: [AutotuneConcurrencyCalibrationMeasurement]
        ) -> AutotuneConcurrencyCalibrationResult {
            AutotuneConcurrencyCalibrationResult(
                recommendedMaxBatch: recommended,
                tierConstantMaxBatch: tierConstant,
                memoryFitCap: memoryFitCap,
                hardCap: hardCap,
                ttftCeilingMS: ttftCeilingMS,
                minAggregateGainFraction: minAggregateGainFraction,
                calibrationContextTokens: calibrationContext,
                probePromptTokens: promptTokens,
                promptReserveTokens: promptReserveTokens,
                completionTokens: completionTokens,
                draftPinned: draftPinned,
                measurements: measurements
            )
        }

        // SPEC-028 FR-4: a configured draft model forces effective_max_batch=1.
        if draftConfigured {
            return makeResult(recommended: 1, draftPinned: true, measurements: [])
        }

        // The probe shape must leave prompt room in the calibration context.
        guard requestedPromptTokens >= 1,
              completionTokens >= 1,
              promptReserveTokens >= 0,
              calibrationContext - promptReserveTokens - completionTokens >= 1
        else {
            throw AutotuneConcurrencyCalibrationError.invalidBounds(memoryFitCap: memoryFitCap, hardCap: hardCap)
        }

        let upperBound = max(1, min(memoryFitCap, hardCap))

        var measurements: [AutotuneConcurrencyCalibrationMeasurement] = []

        func run(_ batchDepth: Int) async throws -> AutotuneConcurrencyCalibrationMeasurement {
            guard !isInterrupted() else { throw AutotuneConcurrencyCalibrationError.interrupted }
            guard !hasDeadlineExpired() else { throw AutotuneConcurrencyCalibrationError.deadlineExceeded }
            let outcome = try await prober.measure(
                batchDepth: batchDepth,
                calibrationContext: calibrationContext,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                deadline: deadline
            )
            guard !isInterrupted() else { throw AutotuneConcurrencyCalibrationError.interrupted }
            guard !hasDeadlineExpired() else { throw AutotuneConcurrencyCalibrationError.deadlineExceeded }
            switch outcome {
            case .feasible(let aggregateTPS, let p95TTFTMS, let decodeTPS):
                guard aggregateTPS.isFinite, aggregateTPS > 0,
                      p95TTFTMS.isFinite, p95TTFTMS >= 0, p95TTFTMS <= Double(Int.max),
                      decodeTPS.map({ $0.isFinite && $0 >= 0 }) ?? true
                else {
                    throw AutotuneConcurrencyCalibrationError.probeFailed(
                        batchDepth: batchDepth,
                        reason: "probe returned invalid metrics (aggregate_tps \(aggregateTPS), p95 \(p95TTFTMS)ms, per-stream decode \(decodeTPS.map { "\($0)" } ?? "none") tok/s)"
                    )
                }
                let ttft = Int(p95TTFTMS.rounded(.up))
                let failureReason: String? = p95TTFTMS > Double(ttftCeilingMS)
                    ? "per-stream p95 TTFT \(ttft)ms exceeded ceiling \(ttftCeilingMS)ms"
                    : nil
                return AutotuneConcurrencyCalibrationMeasurement(
                    batchDepth: batchDepth,
                    streams: batchDepth,
                    aggregateTPS: aggregateTPS,
                    perStreamP95TTFTMS: ttft,
                    perStreamDecodeTPS: decodeTPS,
                    passed: failureReason == nil,
                    failureReason: failureReason
                )
            case .infeasible(let reason, let nErr):
                throw AutotuneConcurrencyCalibrationError.probeFailed(
                    batchDepth: batchDepth,
                    reason: "\(reason) (n_err=\(nErr))"
                )
            }
        }

        // Baseline: batch=1 MUST be measured first and MUST pass the ceiling.
        let baseline = try await run(1)
        measurements.append(baseline)
        guard baseline.passed else {
            throw AutotuneConcurrencyCalibrationError.baselineFailed(
                reason: baseline.failureReason ?? "batch=1 did not pass the TTFT ceiling"
            )
        }

        for depth in Self.sweepDepths(upperBound: upperBound).dropFirst() {
            // A probe ERROR — serve/process failure, swap/thermal safety veto,
            // timeout, interruption, or malformed/non-finite metrics — throws
            // out of `run(...)` and fails the WHOLE calibration closed
            // (SPEC-023-R009 step 6 / AC-43). A depth we could not reliably
            // measure must never yield a stored or applied recommendation, even
            // when a lower depth already passed: the measurement as a whole is
            // untrustworthy, so the caller keeps the tier-constant default.
            let sample = try await run(depth)
            measurements.append(sample)

            // The TTFT ceiling is a normal SEARCH signal, not an error. A depth
            // over it stops the sweep: queueing raises TTFT monotonically with
            // depth, so deeper depths will not recover. A sub-gain-fraction
            // step does NOT stop the sweep; aggregate can rise again further
            // up the ladder.
            if !sample.passed {
                break
            }
        }

        return makeResult(
            recommended: Self.selectDepth(feasible: measurements.filter(\.passed), minAggregateGainFraction: minAggregateGainFraction),
            draftPinned: false,
            measurements: measurements
        )
    }
}

/// One request observed by the steady-state concurrency probe.
struct ConcurrencyWindowRequest: Equatable {
    var start: Date
    var end: Date
    /// Arrival time of every non-empty streamed content/reasoning delta.
    var chunkTimes: [Date]
    /// Authoritative all-channel decode count from the terminal usage chunk.
    var usageDecodedTokens: Int?
    /// Provider-reported decode wall-time from the terminal usage chunk.
    var usageGenerationMS: Int?
}

struct ConcurrencyWindowMetrics: Equatable {
    var aggregateTPS: Double
    var perStreamP95TTFTMS: Double
    /// Median per-request decode rate; nil when no request had a measurable
    /// decode span inside the window.
    var perStreamDecodeTPS: Double?
    var tokensInWindow: Double
    var ttftSamples: Int
    var decodeSamples: Int
}

/// Steady-state window math for the concurrency probe, kept pure so it is
/// unit-testable without a serve.
enum ConcurrencyWindowAggregation {
    /// A stream is "visible" when its streamed deltas account for at least this
    /// fraction of the authoritative decode count. Otherwise (a reasoning
    /// channel suppressed from SSE) its tokens are spread uniformly over the
    /// provider-reported decode window.
    static let visibleChunkFraction = 0.9
    private static let generationWindowToleranceMS = 250.0

    /// - Aggregate TPS: tokens generated inside `[windowStart, windowEnd)`
    ///   divided by the window length. A visible stream contributes its
    ///   in-window deltas (scaled to the authoritative count); a suppressed
    ///   stream contributes its decode window's overlap pro rata.
    /// - Per-stream p95 TTFT (request start to first streamed delta, never
    ///   an inferred decode start) over requests that STARTED inside the
    ///   window, or over every request when none did.
    /// - Per-stream decode: median over requests whose decode overlaps the
    ///   window of the in-window delta rate (visible) or tokens over the
    ///   decode window (suppressed).
    static func aggregate(
        requests: [ConcurrencyWindowRequest],
        windowStart: Date,
        windowEnd: Date
    ) -> ConcurrencyWindowMetrics? {
        let windowSeconds = windowEnd.timeIntervalSince(windowStart)
        guard windowSeconds > 0, !requests.isEmpty else { return nil }

        var tokensInWindow = 0.0
        var decodeRates: [Double] = []
        var startedInWindowTTFTs: [Double] = []
        var allTTFTs: [Double] = []

        for request in requests {
            let tokens = request.usageDecodedTokens ?? request.chunkTimes.count
            let elapsedMS = max(0, request.end.timeIntervalSince(request.start) * 1_000)
            let visible = !request.chunkTimes.isEmpty
                && Double(request.chunkTimes.count) >= Double(tokens) * visibleChunkFraction
            let decodeStart: Date
            if visible {
                decodeStart = request.chunkTimes[0]
            } else if let generationMS = request.usageGenerationMS, generationMS >= 1,
                      Double(generationMS) <= elapsedMS + generationWindowToleranceMS {
                decodeStart = max(request.start, request.end.addingTimeInterval(-Double(generationMS) / 1_000))
            } else {
                decodeStart = request.chunkTimes.first ?? request.end
            }

            // The TTFT gate measures the first buyer-visible delta directly.
            // The decode start inferred from usage generation time above only
            // spreads a suppressed stream's tokens for throughput: hidden work
            // before the first visible delta is still waiting time for the
            // buyer. A stream with no visible delta at all waited until its end.
            let firstVisibleAt = request.chunkTimes.first ?? request.end
            let ttftMS = max(0, firstVisibleAt.timeIntervalSince(request.start) * 1_000)
            allTTFTs.append(ttftMS)
            if request.start >= windowStart, request.start < windowEnd {
                startedInWindowTTFTs.append(ttftMS)
            }

            guard tokens > 0 else { continue }
            if visible {
                let inWindow = request.chunkTimes.filter { $0 >= windowStart && $0 < windowEnd }
                let tokensPerChunk = Double(tokens) / Double(request.chunkTimes.count)
                tokensInWindow += Double(inWindow.count) * tokensPerChunk
                if inWindow.count >= 2, let first = inWindow.first, let last = inWindow.last {
                    let span = last.timeIntervalSince(first)
                    if span > 0 {
                        decodeRates.append(Double(inWindow.count - 1) * tokensPerChunk / span)
                    }
                }
            } else {
                let length = request.end.timeIntervalSince(decodeStart)
                if length <= 0 {
                    if request.end >= windowStart, request.end < windowEnd {
                        tokensInWindow += Double(tokens)
                    }
                    continue
                }
                let overlap = min(request.end, windowEnd).timeIntervalSince(max(decodeStart, windowStart))
                if overlap > 0 {
                    tokensInWindow += Double(tokens) * overlap / length
                    decodeRates.append(Double(tokens) / length)
                }
            }
        }

        let ttftSamples = startedInWindowTTFTs.isEmpty ? allTTFTs : startedInWindowTTFTs
        return ConcurrencyWindowMetrics(
            aggregateTPS: tokensInWindow / windowSeconds,
            perStreamP95TTFTMS: Stage2Prober.percentile95(ttftSamples),
            perStreamDecodeTPS: median(decodeRates),
            tokensInWindow: tokensInWindow,
            ttftSamples: ttftSamples.count,
            decodeSamples: decodeRates.count
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? sorted[mid - 1] / 2 + sorted[mid] / 2 : sorted[mid]
    }
}

extension AutotuneRecommendResult {
    /// Human transcript for a calibration run. Layers on
    /// `contextCalibrationHumanTranscript` (which already falls back to the
    /// plain transcript when no context calibration ran) and, when concurrency
    /// calibration is present, inserts the measured max-concurrency line so both
    /// optional calibrations surface together.
    func calibrationHumanTranscript(configurationApplied: Bool) -> String {
        let transcript = contextCalibrationHumanTranscript(configurationApplied: configurationApplied)
        guard let concurrencyCalibration else {
            return transcript
        }
        let concurrencyLine = concurrencyCalibration.draftPinned
            ? "Measured max concurrency: pinned to 1 (draft model configured; SPEC-028 FR-4)."
            : "Measured max concurrency: \(concurrencyCalibration.recommendedMaxBatch) "
                + "(aggregate-throughput best under memory-fit cap \(concurrencyCalibration.memoryFitCap), "
                + "hard cap \(concurrencyCalibration.hardCap); tier constant \(concurrencyCalibration.tierConstantMaxBatch))."
        return transcript.replacingOccurrences(
            of: "Real earnings scale with buyer demand and your uptime.",
            with: "\(concurrencyLine)\nReal earnings scale with buyer demand and your uptime."
        )
    }
}

/// Production `AutotuneConcurrencyCalibrationProbing`: starts one local,
/// non-joining serve of the selected verified artifact at `--max-batch
/// batchDepth`, runs `batchDepth` closed-loop workers against it (each issues a
/// fresh distinct request as soon as its previous one ends, arrivals
/// staggered), and measures a fixed window after a warmup. Mirrors
/// `Stage1ContextCalibrationAdapter`'s runner/artifact wiring and reuses
/// `Stage1Prober`'s usage-chunk parsing. The calibrator is tested against a
/// fake probe and the window math through `ConcurrencyWindowAggregation`; this
/// is the box-touching implementation.
struct Stage1ConcurrencyCalibrationAdapter: AutotuneConcurrencyCalibrationProbing {
    var model: String
    var port: Int
    var artifactBinding: CandidateArtifactBinding
    var runnerFactory: () throws -> CandidateProviderRunner = { try CandidateProviderRunner() }
    var safetySampler: ProbeSafetySampling = SystemProbeSafetySampler()
    /// Polled between and during requests so an interrupt does not wait out
    /// the measured window.
    var isInterrupted: @Sendable () -> Bool = { false }

    /// Steady-state schedule (SPEC-023-R009 step 2). Workers stop issuing at
    /// the window end; requests in flight then drain, and only tokens streamed
    /// inside the window count.
    static let warmupSeconds: TimeInterval = 30
    static let windowSeconds: TimeInterval = 90
    static let arrivalStaggerSeconds: TimeInterval = 0.25

    private static let readyTimeoutSec: TimeInterval = 120
    private static let stopGraceSeconds: Double = 10
    private static let probeIdleTimeoutSec: TimeInterval = 300
    private static let probeTotalTimeoutSec: TimeInterval = 300
    private static let stopTokens = ["<|im_end|>", "<|endoftext|>", "<|eot_id|>"]

    private struct StreamFailure: Error, CustomStringConvertible {
        var description: String
    }

    func measure(
        batchDepth: Int,
        calibrationContext: Int,
        promptTokens: Int,
        completionTokens: Int,
        deadline: Date?
    ) async throws -> ConcurrencyProbeOutcome {
        // Sample memory-pressure/thermal state across the whole probe so a
        // sweep depth that drives the box into swap or throttle fails closed,
        // exactly like the context adapter.
        let buffer = ProbeSafetySampleBuffer()
        buffer.append(safetySampler.sample())
        let sampler = safetySampler
        let samplerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { break }
                buffer.append(sampler.sample())
            }
        }
        defer { samplerTask.cancel() }

        // Start ONE serve at this batch depth and the production context (the
        // memory-fit bound is computed there) and tear it down afterwards.
        let runner = try runnerFactory()
        try runner.start(
            model: model,
            port: port,
            kvBits: nil,
            maxContext: calibrationContext,
            maxBatch: batchDepth,
            artifactBinding: artifactBinding,
            deadline: deadline
        )
        let outcome: ConcurrencyProbeOutcome = try await withCandidateProviderCleanup(
            runner,
            graceSeconds: Self.stopGraceSeconds
        ) {
            switch try await runner.waitForReady(timeout: Self.readyTimeoutSec, deadline: deadline) {
            case .ready:
                break
            case .processExited(let rc, let stderrTail):
                return .infeasible(
                    reason: "provider exited before concurrency probe rc=\(rc): \(stderrTail)",
                    nErr: max(1, batchDepth)
                )
            case .timeout(let lastError):
                return .infeasible(
                    reason: "provider readiness timeout before concurrency probe: \(lastError)",
                    nErr: max(1, batchDepth)
                )
            }

            let loadStart = Date()
            let windowStart = loadStart.addingTimeInterval(Self.warmupSeconds)
            let windowEnd = windowStart.addingTimeInterval(Self.windowSeconds)
            let isInterrupted = self.isInterrupted
            let model = self.model
            let port = self.port

            // `batchDepth` closed-loop workers with DISTINCT padded prompts so
            // no two requests share a prefill/cache path. Any failed request
            // throws, cancels the other workers, and marks the depth
            // infeasible.
            let requests: [ConcurrencyWindowRequest]
            do {
                requests = try await withThrowingTaskGroup(of: [ConcurrencyWindowRequest].self) { group in
                    for index in 0..<batchDepth {
                        group.addTask {
                            let staggerNS = UInt64(Double(index) * Self.arrivalStaggerSeconds * 1_000_000_000)
                            try await Task.sleep(nanoseconds: staggerNS)
                            var observed: [ConcurrencyWindowRequest] = []
                            var sequence = 0
                            while Date() < windowEnd {
                                try Self.checkAbort(isInterrupted: isInterrupted, deadline: deadline)
                                let next = try await Self.measureStream(
                                    model: model,
                                    port: port,
                                    promptTokens: promptTokens,
                                    completionTokens: completionTokens,
                                    streamIndex: index,
                                    sequence: sequence,
                                    batchDepth: batchDepth,
                                    isInterrupted: isInterrupted,
                                    deadline: deadline
                                )
                                observed.append(next)
                                sequence += 1
                            }
                            return observed
                        }
                    }
                    var collected: [ConcurrencyWindowRequest] = []
                    for try await observed in group {
                        collected += observed
                    }
                    return collected
                }
            } catch {
                let reason = (error as? StreamFailure)?.description ?? "\(error)"
                return .infeasible(
                    reason: "concurrency probe stream failed: \(reason)",
                    nErr: 1
                )
            }

            let metrics = ConcurrencyWindowAggregation.aggregate(
                requests: requests,
                windowStart: windowStart,
                windowEnd: windowEnd
            )
            guard let metrics,
                  metrics.aggregateTPS.isFinite, metrics.aggregateTPS > 0,
                  metrics.perStreamP95TTFTMS.isFinite
            else {
                return .infeasible(
                    reason: "concurrency window produced no measurable throughput (\(requests.count) requests)",
                    nErr: max(1, batchDepth)
                )
            }
            return .feasible(
                aggregateTPS: metrics.aggregateTPS,
                perStreamP95TTFTMS: metrics.perStreamP95TTFTMS,
                perStreamDecodeTPS: metrics.perStreamDecodeTPS
            )
        }

        samplerTask.cancel()
        _ = await samplerTask.value
        buffer.append(sampler.sample())
        let safety = ProbeSafetyAssessment.assess(samples: buffer.snapshot())
        if safety.swapDetected || safety.thermalThrottleDetected {
            return .infeasible(reason: "memory-pressure or thermal safety veto", nErr: 1)
        }
        return outcome
    }

    private static func checkAbort(isInterrupted: @Sendable () -> Bool, deadline: Date?) throws {
        if isInterrupted() {
            throw AutotuneConcurrencyCalibrationError.interrupted
        }
        if let deadline, Date() >= deadline {
            throw AutotuneConcurrencyCalibrationError.deadlineExceeded
        }
    }

    /// Issues one streaming request, racing a total-duration ceiling so a
    /// slow/stuck stream cannot hang the whole worker group.
    private static func measureStream(
        model: String,
        port: Int,
        promptTokens: Int,
        completionTokens: Int,
        streamIndex: Int,
        sequence: Int,
        batchDepth: Int,
        isInterrupted: @escaping @Sendable () -> Bool,
        deadline: Date?
    ) async throws -> ConcurrencyWindowRequest {
        try await withThrowingTaskGroup(of: ConcurrencyWindowRequest.self) { group in
            group.addTask {
                try await performStream(
                    model: model,
                    port: port,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    streamIndex: streamIndex,
                    sequence: sequence,
                    batchDepth: batchDepth,
                    isInterrupted: isInterrupted,
                    deadline: deadline
                )
            }
            group.addTask {
                let nanoseconds = UInt64(probeTotalTimeoutSec * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw StreamFailure(description: "request exceeded \(Int(probeTotalTimeoutSec))s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func performStream(
        model: String,
        port: Int,
        promptTokens: Int,
        completionTokens: Int,
        streamIndex: Int,
        sequence: Int,
        batchDepth: Int,
        isInterrupted: @Sendable () -> Bool,
        deadline: Date?
    ) async throws -> ConcurrencyWindowRequest {
        // SPEC-023-R009 step 2: the configured probe shape, not a
        // context-filling prompt. The unique nonce leads the prompt so no two
        // requests share a cached prefix.
        var words = Array(repeating: "probe", count: max(1, promptTokens))
        words[0] = "probe-concurrency-\(batchDepth)-\(streamIndex)-\(sequence)-\(UUID().uuidString)"
        let prompt = words.joined(separator: " ")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = probeIdleTimeoutSec
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "temperature": 0,
            "max_tokens": completionTokens,
            "messages": [
                [
                    "role": "user",
                    "content": prompt,
                ],
            ],
        ])

        let started = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            throw StreamFailure(description: "HTTP \(statusCode)")
        }
        var generatedText = ""
        var chunkTimes: [Date] = []
        var usageDecodedTokens: Int?
        var usageGenerationMS: Int?

        for try await rawLine in bytes.lines {
            try checkAbort(isInterrupted: isInterrupted, deadline: deadline)
            guard rawLine.hasPrefix("data:") else {
                continue
            }
            let payload = rawLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                break
            }
            if let usage = Stage1Prober.usageDecodedTokens(from: payload, maxTokens: completionTokens) {
                usageDecodedTokens = usage
            }
            if let generationMS = Stage1Prober.usageGenerationMS(from: payload) {
                usageGenerationMS = generationMS
            }
            guard let delta = streamedDelta(from: payload), !delta.isEmpty else {
                continue
            }
            chunkTimes.append(Date())
            generatedText += delta
        }

        let ended = Date()
        if let leaked = stopTokens.first(where: { generatedText.contains($0) }) {
            throw StreamFailure(description: "stop-token leak: \(leaked)")
        }
        if usageDecodedTokens == 0 || (usageDecodedTokens == nil && chunkTimes.isEmpty) {
            throw StreamFailure(description: "stream produced no measurable tokens")
        }
        return ConcurrencyWindowRequest(
            start: started,
            end: ended,
            chunkTimes: chunkTimes,
            usageDecodedTokens: usageDecodedTokens,
            usageGenerationMS: usageGenerationMS
        )
    }

    /// Generated text from a streamed chunk: visible content, or a reasoning
    /// channel when the serve streams one separately. Both are decode work.
    private static func streamedDelta(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first
        else {
            return nil
        }
        if let delta = first["delta"] as? [String: Any] {
            for key in ["content", "reasoning_content", "reasoning"] {
                if let text = delta[key] as? String, !text.isEmpty {
                    return text
                }
            }
            return nil
        }
        return first["text"] as? String
    }
}
