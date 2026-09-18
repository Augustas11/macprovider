import Foundation

/// SPEC-023-R009 (§9.2): empirical, opt-in concurrency calibration.
///
/// The served provider's `max_concurrency_override` sizes the serve
/// `--max-batch` semaphore and is advertised 1:1 to the coordinator as
/// `slots_total`. `autotune --recommend` emits it from a blind chip/RAM tier
/// constant (`AutotuneRecommendHardware.recommendedMaxBatch`) that never
/// measures the specific box. This type measures the selected, already-verified
/// artifact's *aggregate* decode throughput and per-stream tail latency across a
/// bounded batch sweep and selects the empirically best depth, under a
/// memory-fit hard upper bound and a tail-latency ceiling. It is engine-agnostic
/// by construction: it drives genuine concurrent load and measures whatever
/// serve mode production runs (independent single-stream today; shared-forward
/// continuous batching, SPEC-038/039, once enabled).

struct AutotuneConcurrencyCalibrationMeasurement: Codable, Equatable {
    var batchDepth: Int
    var streams: Int
    var aggregateTPS: Double
    var perStreamP95TTFTMS: Int?
    var passed: Bool
    var failureReason: String? = nil

    enum CodingKeys: String, CodingKey {
        case batchDepth = "batch_depth"
        case streams
        case aggregateTPS = "aggregate_tps"
        case perStreamP95TTFTMS = "per_stream_p95_ttft_ms"
        case passed
        case failureReason = "failure_reason"
    }
}

struct AutotuneConcurrencyCalibrationResult: Codable, Equatable {
    static let schemaVersion = "autotune_concurrency_calibration.v1"

    var schemaVersion: String = Self.schemaVersion
    var recommendedMaxBatch: Int
    var tierConstantMaxBatch: Int
    var memoryFitCap: Int
    var hardCap: Int
    var ttftCeilingMS: Int
    var ttftRegressionFactor: Double
    var minAggregateGainFraction: Double
    var calibrationContextTokens: Int
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
        case promptReserveTokens = "prompt_reserve_tokens"
        case completionTokens = "completion_tokens"
        case draftPinned = "draft_pinned"
        case measurements
    }

    /// Deterministic field order matching the SPEC-023 §6 output contract.
    var jsonString: String {
        let samples = measurements.map { sample in
            """
            {"batch_depth":\(sample.batchDepth),"streams":\(sample.streams),"aggregate_tps":\(concurrencyCalibrationJSONNumber(sample.aggregateTPS)),"per_stream_p95_ttft_ms":\(sample.perStreamP95TTFTMS.map(String.init) ?? "null"),"passed":\(sample.passed),"failure_reason":\(sample.failureReason.map(concurrencyCalibrationJSONString) ?? "null")}
            """
        }.joined(separator: ",")
        return """
        {"schema_version":\(concurrencyCalibrationJSONString(Self.schemaVersion)),"recommended_max_batch":\(recommendedMaxBatch),"tier_constant_max_batch":\(tierConstantMaxBatch),"memory_fit_cap":\(memoryFitCap),"hard_cap":\(hardCap),"ttft_ceiling_ms":\(ttftCeilingMS),"ttft_regression_factor":\(concurrencyCalibrationJSONNumber(ttftRegressionFactor)),"min_aggregate_gain_fraction":\(concurrencyCalibrationJSONNumber(minAggregateGainFraction)),"calibration_context_tokens":\(calibrationContextTokens),"prompt_reserve_tokens":\(promptReserveTokens),"completion_tokens":\(completionTokens),"draft_pinned":\(draftPinned),"measurements":[\(samples)]}
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

/// Outcome of measuring one batch depth: aggregate decode throughput across all
/// concurrent streams, plus the per-stream p95 TTFT.
enum ConcurrencyProbeOutcome: Equatable {
    case feasible(aggregateTPS: Double, perStreamP95TTFTMS: Double)
    case infeasible(reason: String, nErr: Int)
}

protocol AutotuneConcurrencyCalibrationProbing {
    /// Start a local non-joining serve at `--max-batch batchDepth`, drive
    /// `batchDepth` genuinely concurrent uncached probe streams whose prompts
    /// fill the calibration context to its advertised boundary minus
    /// `promptReserveTokens` (SPEC-023-R009 step 2) while generating
    /// `completionTokens`, and return aggregate throughput + per-stream p95
    /// TTFT. Implementations MUST apply the probe-safety (swap/thermal) veto.
    func measure(
        batchDepth: Int,
        calibrationContext: Int,
        promptReserveTokens: Int,
        completionTokens: Int,
        deadline: Date?
    ) async throws -> ConcurrencyProbeOutcome
}

struct AutotuneConcurrencyCalibrator {
    /// Served hard cap; mirrors `ProviderCapacity.maxConcurrencyOverrideLimit`.
    var hardCap = 8
    var ttftCeilingMS = 8_000
    /// A higher batch depth is rejected if its per-stream p95 TTFT exceeds the
    /// single-stream (batch=1) p95 by more than this factor.
    var ttftRegressionFactor = 1.5
    /// Two feasible depths within this aggregate-throughput fraction of each
    /// other are treated as tied; the LOWER depth wins (memory-risk posture,
    /// SPEC-029 FR-5).
    var minAggregateGainFraction = 0.15

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
        promptReserveTokens: Int,
        completionTokens: Int,
        prober: AutotuneConcurrencyCalibrationProbing,
        deadline: Date? = nil,
        isInterrupted: @escaping () -> Bool = { false },
        hasDeadlineExpired: @escaping () -> Bool = { false }
    ) async throws -> AutotuneConcurrencyCalibrationResult {
        guard hardCap >= 1,
              ttftCeilingMS >= 1,
              ttftRegressionFactor >= 1,
              minAggregateGainFraction >= 0,
              memoryFitCap >= 1
        else {
            throw AutotuneConcurrencyCalibrationError.invalidBounds(memoryFitCap: memoryFitCap, hardCap: hardCap)
        }

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
                ttftRegressionFactor: ttftRegressionFactor,
                minAggregateGainFraction: minAggregateGainFraction,
                calibrationContextTokens: calibrationContext,
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

        let upperBound = max(1, min(memoryFitCap, hardCap))

        var measurements: [AutotuneConcurrencyCalibrationMeasurement] = []

        func run(_ batchDepth: Int) async throws -> AutotuneConcurrencyCalibrationMeasurement {
            guard !isInterrupted() else { throw AutotuneConcurrencyCalibrationError.interrupted }
            guard !hasDeadlineExpired() else { throw AutotuneConcurrencyCalibrationError.deadlineExceeded }
            let outcome = try await prober.measure(
                batchDepth: batchDepth,
                calibrationContext: calibrationContext,
                promptReserveTokens: promptReserveTokens,
                completionTokens: completionTokens,
                deadline: deadline
            )
            guard !isInterrupted() else { throw AutotuneConcurrencyCalibrationError.interrupted }
            guard !hasDeadlineExpired() else { throw AutotuneConcurrencyCalibrationError.deadlineExceeded }
            switch outcome {
            case .feasible(let aggregateTPS, let p95TTFTMS):
                guard aggregateTPS.isFinite, aggregateTPS > 0,
                      p95TTFTMS.isFinite, p95TTFTMS >= 0, p95TTFTMS <= Double(Int.max)
                else {
                    throw AutotuneConcurrencyCalibrationError.probeFailed(
                        batchDepth: batchDepth,
                        reason: "probe returned invalid metrics (aggregate_tps \(aggregateTPS), p95 \(p95TTFTMS)ms)"
                    )
                }
                let ttft = Int(p95TTFTMS.rounded(.up))
                let withinCeiling = p95TTFTMS <= Double(ttftCeilingMS)
                return AutotuneConcurrencyCalibrationMeasurement(
                    batchDepth: batchDepth,
                    streams: batchDepth,
                    aggregateTPS: aggregateTPS,
                    perStreamP95TTFTMS: ttft,
                    passed: withinCeiling,
                    failureReason: withinCeiling ? nil : "per-stream p95 TTFT \(ttft)ms exceeded ceiling \(ttftCeilingMS)ms"
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
        guard baseline.passed, let baselineP95 = baseline.perStreamP95TTFTMS else {
            throw AutotuneConcurrencyCalibrationError.baselineFailed(
                reason: baseline.failureReason ?? "batch=1 did not pass the TTFT ceiling"
            )
        }

        // best is always a feasible depth; seed with the passing baseline.
        var bestDepth = 1
        var bestAggregate = baseline.aggregateTPS

        var depth = 2
        while depth <= upperBound {
            // A probe ERROR — serve/process failure, swap/thermal safety veto,
            // timeout, interruption, or malformed/non-finite metrics — throws
            // out of `run(...)` and fails the WHOLE calibration closed
            // (SPEC-023-R009 step 6 / AC-43). A depth we could not reliably
            // measure must never yield a stored or applied recommendation, even
            // when a lower depth already passed: the measurement as a whole is
            // untrustworthy, so the caller keeps the tier-constant default.
            let sample = try await run(depth)
            measurements.append(sample)

            // Latency gates are normal SEARCH signals, not errors. A depth whose
            // per-stream p95 exceeds the ceiling (`sample.passed == false`) or
            // regresses past the bounded factor over the batch=1 baseline stops
            // the contiguous sweep and keeps the best lower FEASIBLE depth —
            // contention degrades latency monotonically, so deeper depths will
            // not recover.
            let regressed: Bool
            if let p95 = sample.perStreamP95TTFTMS {
                regressed = Double(p95) > Double(baselineP95) * ttftRegressionFactor
            } else {
                regressed = true
            }
            if !sample.passed || regressed {
                if regressed, sample.failureReason == nil {
                    let last = measurements.count - 1
                    measurements[last].passed = false
                    measurements[last].failureReason = "per-stream p95 TTFT regressed past \(concurrencyCalibrationJSONNumber(ttftRegressionFactor))x the batch=1 baseline (\(baselineP95)ms)"
                }
                break
            }

            // Feasible: keep it only when it MATERIALLY raises aggregate
            // throughput; otherwise keep the LOWER depth (memory-risk posture,
            // SPEC-029 FR-5) and stop climbing — diminishing returns.
            if sample.aggregateTPS > bestAggregate * (1 + minAggregateGainFraction) {
                bestDepth = depth
                bestAggregate = sample.aggregateTPS
            } else {
                break
            }
            depth += 1
        }

        return makeResult(recommended: bestDepth, draftPinned: false, measurements: measurements)
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
/// batchDepth`, drives `batchDepth` genuinely concurrent uncached probe streams
/// against it, and returns aggregate decode throughput plus per-stream p95 TTFT.
/// Mirrors `Stage1ContextCalibrationAdapter`'s runner/artifact wiring and reuses
/// `Stage2Prober`'s streaming `/v1/chat/completions` probe shape and
/// `Stage1Prober`'s usage-token throughput finalization. The calibrator is
/// tested against a fake probe; this is the box-touching implementation.
struct Stage1ConcurrencyCalibrationAdapter: AutotuneConcurrencyCalibrationProbing {
    var model: String
    var port: Int
    var artifactBinding: CandidateArtifactBinding
    var runnerFactory: () throws -> CandidateProviderRunner = { try CandidateProviderRunner() }
    var safetySampler: ProbeSafetySampling = SystemProbeSafetySampler()

    private static let readyTimeoutSec: TimeInterval = 120
    private static let stopGraceSeconds: Double = 10
    private static let probeIdleTimeoutSec: TimeInterval = 300
    private static let probeTotalTimeoutSec: TimeInterval = 300
    private static let stopTokens = ["<|im_end|>", "<|endoftext|>", "<|eot_id|>"]

    private struct ConcurrencyStreamResult {
        var start: Date
        var end: Date
        var ttftMS: Double
        var decodedTokens: Int
        var throughputTPS: Double
        var statusCode: Int
        var stopTokenLeak: String?
    }

    func measure(
        batchDepth: Int,
        calibrationContext: Int,
        promptReserveTokens: Int,
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

        // Start ONE serve at this batch depth (started once per depth, not per
        // stream) and tear it down after the concurrent streams complete.
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

            // Drive `batchDepth` genuinely concurrent streams — one child task
            // each, all in flight at once — with DISTINCT padded prompts so no
            // two streams share a prefill/cache path. A single child throwing
            // ends the group and marks the depth infeasible.
            let streams: [ConcurrencyStreamResult]
            do {
                streams = try await withThrowingTaskGroup(of: ConcurrencyStreamResult.self) { group in
                    for index in 0..<batchDepth {
                        group.addTask {
                            try await Self.measureStream(
                                model: model,
                                port: port,
                                calibrationContext: calibrationContext,
                                promptReserveTokens: promptReserveTokens,
                                completionTokens: completionTokens,
                                streamIndex: index,
                                batchDepth: batchDepth
                            )
                        }
                    }
                    var collected: [ConcurrencyStreamResult] = []
                    for try await result in group {
                        collected.append(result)
                    }
                    return collected
                }
            } catch {
                return .infeasible(
                    reason: "concurrency probe stream failed: \(error.localizedDescription)",
                    nErr: max(1, batchDepth)
                )
            }

            guard streams.count == batchDepth else {
                return .infeasible(
                    reason: "concurrency probe produced \(streams.count) of \(batchDepth) streams",
                    nErr: max(1, batchDepth - streams.count)
                )
            }

            var nErr = 0
            var firstFailure: String?
            for stream in streams {
                if let leaked = stream.stopTokenLeak {
                    return .infeasible(reason: "stop-token leak: \(leaked)", nErr: max(1, nErr + 1))
                }
                guard (200...299).contains(stream.statusCode) else {
                    nErr += 1
                    firstFailure = firstFailure ?? "HTTP \(stream.statusCode)"
                    continue
                }
                guard stream.throughputTPS.isFinite, stream.throughputTPS > 0, stream.ttftMS.isFinite else {
                    nErr += 1
                    firstFailure = firstFailure ?? "stream produced no measurable throughput (TPS \(stream.throughputTPS), TTFT \(stream.ttftMS)ms)"
                    continue
                }
            }
            if nErr > 0 {
                return .infeasible(reason: firstFailure ?? "concurrency probe failed", nErr: nErr)
            }

            // Aggregate throughput = total decoded tokens across all streams
            // over the wall-clock from the first stream's start to the last
            // stream's end. This is the concurrency signal Stage 2's serialized
            // single-stream replicates cannot observe.
            let wallStart = streams.map(\.start).min() ?? Date()
            let wallEnd = streams.map(\.end).max() ?? wallStart
            let wallSeconds = max(0.001, wallEnd.timeIntervalSince(wallStart))
            let totalDecoded = streams.reduce(0) { $0 + $1.decodedTokens }
            let aggregateTPS = Double(totalDecoded) / wallSeconds
            let perStreamP95TTFTMS = Stage2Prober.percentile95(streams.map(\.ttftMS))
            guard aggregateTPS.isFinite, aggregateTPS > 0, perStreamP95TTFTMS.isFinite else {
                return .infeasible(
                    reason: "concurrency aggregate produced invalid metrics (aggregate_tps \(aggregateTPS), p95 \(perStreamP95TTFTMS)ms)",
                    nErr: max(1, batchDepth)
                )
            }
            return .feasible(aggregateTPS: aggregateTPS, perStreamP95TTFTMS: perStreamP95TTFTMS)
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

    /// Issues one streaming request, racing a total-duration ceiling so a
    /// slow/stuck stream cannot hang the whole concurrent group.
    private static func measureStream(
        model: String,
        port: Int,
        calibrationContext: Int,
        promptReserveTokens: Int,
        completionTokens: Int,
        streamIndex: Int,
        batchDepth: Int
    ) async throws -> ConcurrencyStreamResult {
        try await withThrowingTaskGroup(of: ConcurrencyStreamResult.self) { group in
            group.addTask {
                try await performStream(
                    model: model,
                    port: port,
                    calibrationContext: calibrationContext,
                    promptReserveTokens: promptReserveTokens,
                    completionTokens: completionTokens,
                    streamIndex: streamIndex,
                    batchDepth: batchDepth
                )
            }
            group.addTask {
                let nanoseconds = UInt64(probeTotalTimeoutSec * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func performStream(
        model: String,
        port: Int,
        calibrationContext: Int,
        promptReserveTokens: Int,
        completionTokens: Int,
        streamIndex: Int,
        batchDepth: Int
    ) async throws -> ConcurrencyStreamResult {
        // SPEC-023-R009 step 2: fill the calibration context to its advertised
        // boundary MINUS the reserve (prompt reserve + completion budget), not
        // `paddedPrompt`'s ~80%, so each concurrent slot carries a
        // production-representative KV footprint — otherwise a higher depth
        // could pass under a shorter prompt and be selected even though it would
        // breach latency/memory near the real production context boundary.
        // Distinct nonce per stream so streams neither collapse to one cached
        // prefill nor measure a shared-prompt best case.
        let promptTokenTarget = max(1, calibrationContext - promptReserveTokens - completionTokens)
        var words = Array(repeating: "probe", count: promptTokenTarget)
        words[0] = "probe-concurrency-\(batchDepth)-\(streamIndex)-\(UUID().uuidString)"
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
        var generatedText = ""
        var firstTokenAt: Date?
        var deltaCount = 0
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
            if let usage = Stage1Prober.usageDecodedTokens(from: payload, maxTokens: completionTokens) {
                usageDecodedTokens = usage
            }
            if let generationMS = Stage1Prober.usageGenerationMS(from: payload) {
                usageGenerationMS = generationMS
            }
            guard let content = Stage1Prober.contentDelta(from: payload), !content.isEmpty else {
                continue
            }
            if firstTokenAt == nil {
                firstTokenAt = Date()
            }
            generatedText += content
            deltaCount += 1
        }

        let ended = Date()
        let metrics = Stage1Prober.finalizeProbeMetrics(
            contentFallbackTokens: deltaCount,
            usageDecodedTokens: usageDecodedTokens,
            usageGenerationMS: usageGenerationMS,
            firstTokenAt: firstTokenAt,
            started: started,
            ended: ended
        )
        // Aggregate numerator: the authoritative all-channel decode count when
        // present (may be 0 → an infeasible stream that
        // `finalizeProbeMetrics` already reports as 0 TPS), else the visible
        // content-delta count.
        let decodedTokens = usageDecodedTokens ?? max(1, deltaCount)
        return ConcurrencyStreamResult(
            start: started,
            end: ended,
            ttftMS: metrics.ttftMS,
            decodedTokens: decodedTokens,
            throughputTPS: metrics.throughputTPS,
            statusCode: statusCode,
            stopTokenLeak: Self.stopTokens.first(where: { generatedText.contains($0) })
        )
    }
}
