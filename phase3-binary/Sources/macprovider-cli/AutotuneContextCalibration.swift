import Foundation

struct AutotuneContextCalibrationMeasurement: Codable, Equatable {
    var contextTokens: Int
    var ttftP95MS: Int?
    var decodeTPS: Double
    var replicates: Int
    var passed: Bool
    var failureReason: String? = nil

    enum CodingKeys: String, CodingKey {
        case contextTokens = "context_tokens"
        case ttftP95MS = "ttft_p95_ms"
        case decodeTPS = "decode_tps"
        case replicates
        case passed
        case failureReason = "failure_reason"
    }
}

struct AutotuneContextCalibrationResult: Codable, Equatable {
    static let schemaVersion = "autotune_context_calibration.v1"
    static let promptReserveTokens = 256
    static let completionTokens = 1

    var schemaVersion: String = Self.schemaVersion
    var recommendedContext: Int
    var safeUpperBound: Int
    var minimumContext: Int
    var ttftCeilingMS: Int
    var quantum: Int
    var promptReserveTokens: Int = Self.promptReserveTokens
    var completionTokens: Int = Self.completionTokens
    var measurements: [AutotuneContextCalibrationMeasurement]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recommendedContext = "recommended_context"
        case safeUpperBound = "safe_upper_bound"
        case minimumContext = "minimum_context"
        case ttftCeilingMS = "ttft_ceiling_ms"
        case quantum
        case promptReserveTokens = "prompt_reserve_tokens"
        case completionTokens = "completion_tokens"
        case measurements
    }

    init(
        recommendedContext: Int,
        safeUpperBound: Int,
        minimumContext: Int,
        ttftCeilingMS: Int,
        quantum: Int,
        measurements: [AutotuneContextCalibrationMeasurement]
    ) {
        self.recommendedContext = recommendedContext
        self.safeUpperBound = safeUpperBound
        self.minimumContext = minimumContext
        self.ttftCeilingMS = ttftCeilingMS
        self.quantum = quantum
        self.measurements = measurements
    }

    var jsonString: String {
        let samples = measurements.map { sample in
            """
            {"context_tokens":\(sample.contextTokens),"ttft_p95_ms":\(sample.ttftP95MS.map(String.init) ?? "null"),"decode_tps":\(contextCalibrationJSONNumber(sample.decodeTPS)),"replicates":\(sample.replicates),"passed":\(sample.passed),"failure_reason":\(sample.failureReason.map(contextCalibrationJSONString) ?? "null")}
            """
        }.joined(separator: ",")
        return """
        {"schema_version":\(contextCalibrationJSONString(Self.schemaVersion)),"recommended_context":\(recommendedContext),"safe_upper_bound":\(safeUpperBound),"minimum_context":\(minimumContext),"ttft_ceiling_ms":\(ttftCeilingMS),"quantum":\(quantum),"prompt_reserve_tokens":\(Self.promptReserveTokens),"completion_tokens":\(Self.completionTokens),"measurements":[\(samples)]}
        """
    }
}

private func contextCalibrationJSONNumber(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    return String(format: "%.6f", value)
        .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
}

private func contextCalibrationJSONString(_ value: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
    let array = String(decoding: data, as: UTF8.self)
    return String(array.dropFirst().dropLast())
}

enum AutotuneContextCalibrationError: Error, Equatable, CustomStringConvertible {
    case invalidBounds(minimum: Int, upper: Int)
    case minimumFailed(context: Int, reason: String)
    case finalValidationFailed(context: Int, reason: String)
    case probeFailed(context: Int, reason: String)
    case interrupted
    case deadlineExceeded

    var description: String {
        switch self {
        case .invalidBounds(let minimum, let upper):
            return "context calibration bounds are invalid: minimum=\(minimum), upper=\(upper)"
        case .minimumFailed(let context, let reason):
            return "minimum context \(context) failed calibration: \(reason)"
        case .finalValidationFailed(let context, let reason):
            return "final context \(context) failed calibration: \(reason)"
        case .probeFailed(let context, let reason):
            return "context \(context) probe failed integrity checks: \(reason)"
        case .interrupted:
            return "context calibration interrupted"
        case .deadlineExceeded:
            return "context calibration exceeded --max-duration"
        }
    }
}

protocol AutotuneContextCalibrationProbing {
    func measure(contextTokens: Int, replicates: Int, deadline: Date?) async throws -> Stage1ProbeResult
}

extension AutotuneContextCalibrationProbing {
    func measure(contextTokens: Int, replicates: Int) async throws -> Stage1ProbeResult {
        try await measure(contextTokens: contextTokens, replicates: replicates, deadline: nil)
    }
}

struct AutotuneContextCalibrator {
    var minimumContext = 4_000
    var ttftCeilingMS = 8_000
    var quantum = 1_000
    var finalReplicates = 3

    func calibrate(
        safeUpperBound rawUpperBound: Int,
        prober: AutotuneContextCalibrationProbing,
        deadline: Date? = nil,
        isInterrupted: @escaping () -> Bool = { false },
        hasDeadlineExpired: @escaping () -> Bool = { false }
    ) async throws -> AutotuneContextCalibrationResult {
        guard minimumContext >= 1,
              quantum >= 1,
              ttftCeilingMS >= 1,
              finalReplicates >= 3
        else {
            throw AutotuneContextCalibrationError.invalidBounds(
                minimum: minimumContext,
                upper: rawUpperBound
            )
        }
        let upperBound = (rawUpperBound / quantum) * quantum
        guard upperBound >= minimumContext else {
            throw AutotuneContextCalibrationError.invalidBounds(
                minimum: minimumContext,
                upper: rawUpperBound
            )
        }

        var measurements: [AutotuneContextCalibrationMeasurement] = []
        func run(_ context: Int, replicates: Int) async throws -> AutotuneContextCalibrationMeasurement {
            guard !isInterrupted() else {
                throw AutotuneContextCalibrationError.interrupted
            }
            guard !hasDeadlineExpired() else {
                throw AutotuneContextCalibrationError.deadlineExceeded
            }
            let outcome = try await prober.measure(contextTokens: context, replicates: replicates, deadline: deadline)
            guard !isInterrupted() else {
                throw AutotuneContextCalibrationError.interrupted
            }
            guard !hasDeadlineExpired() else {
                throw AutotuneContextCalibrationError.deadlineExceeded
            }
            switch outcome {
            case .feasible(let medianTPS, let p95TTFTMS):
                guard medianTPS.isFinite, medianTPS > 0,
                      p95TTFTMS.isFinite, p95TTFTMS >= 0,
                      p95TTFTMS <= Double(Int.max)
                else {
                    throw AutotuneContextCalibrationError.probeFailed(
                        context: context,
                        reason: "probe returned invalid metrics"
                    )
                }
                return AutotuneContextCalibrationMeasurement(
                    contextTokens: context,
                    ttftP95MS: Int(p95TTFTMS.rounded(.up)),
                    decodeTPS: medianTPS,
                    replicates: replicates,
                    passed: p95TTFTMS <= Double(ttftCeilingMS),
                    failureReason: p95TTFTMS <= Double(ttftCeilingMS)
                        ? nil
                        : "TTFT p95 \(Int(p95TTFTMS.rounded(.up)))ms exceeded \(ttftCeilingMS)ms"
                )
            case .infeasible(let reason, let nErr):
                throw AutotuneContextCalibrationError.probeFailed(
                    context: context,
                    reason: "\(reason) (n_err=\(nErr))"
                )
            }
        }

        let minimum = try await run(minimumContext, replicates: 1)
        measurements.append(minimum)
        guard minimum.passed else {
            throw AutotuneContextCalibrationError.minimumFailed(
                context: minimumContext,
                reason: minimum.failureReason ?? "context did not pass"
            )
        }

        var lowerPass = minimumContext
        var upperFail: Int?
        while lowerPass < upperBound {
            let next = min(upperBound, max(lowerPass + quantum, lowerPass * 2))
            let sample = try await run(next, replicates: 1)
            measurements.append(sample)
            if sample.passed {
                lowerPass = next
            } else {
                upperFail = next
                break
            }
        }

        if var fail = upperFail {
            while fail - lowerPass > quantum {
                let cells = (fail - lowerPass) / quantum
                let midpoint = lowerPass + max(1, cells / 2) * quantum
                let sample = try await run(midpoint, replicates: 1)
                measurements.append(sample)
                if sample.passed {
                    lowerPass = midpoint
                } else {
                    fail = midpoint
                }
            }
        }

        let final = try await run(lowerPass, replicates: finalReplicates)
        measurements.append(final)
        guard final.passed else {
            throw AutotuneContextCalibrationError.finalValidationFailed(
                context: lowerPass,
                reason: final.failureReason ?? "context did not pass"
            )
        }
        return AutotuneContextCalibrationResult(
            recommendedContext: lowerPass,
            safeUpperBound: upperBound,
            minimumContext: minimumContext,
            ttftCeilingMS: ttftCeilingMS,
            quantum: quantum,
            measurements: measurements
        )
    }
}

struct Stage1ContextCalibrationAdapter: AutotuneContextCalibrationProbing {
    var model: String
    var port: Int
    var artifactBinding: CandidateArtifactBinding
    var runnerFactory: () throws -> CandidateProviderRunner = { try CandidateProviderRunner() }
    var safetySampler: ProbeSafetySampling = SystemProbeSafetySampler()

    func measure(contextTokens: Int, replicates: Int, deadline: Date?) async throws -> Stage1ProbeResult {
        let buffer = ProbeSafetySampleBuffer()
        buffer.append(safetySampler.sample())
        let sampler = safetySampler
        let task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { break }
                buffer.append(sampler.sample())
            }
        }
        defer { task.cancel() }

        let runner = try runnerFactory()
        let outcome = try await Stage1Prober(
            probeIdleTimeoutSec: 30,
            probeTotalTimeoutSec: 30
        ).probeContextCalibration(
            model: model,
            port: port,
            runner: runner,
            targetContext: contextTokens,
            replicates: replicates,
            artifactBinding: artifactBinding,
            deadline: deadline
        )
        task.cancel()
        _ = await task.value
        buffer.append(sampler.sample())
        let safety = ProbeSafetyAssessment.assess(samples: buffer.snapshot())
        if safety.swapDetected || safety.thermalThrottleDetected {
            return .infeasible(reason: "memory-pressure or thermal safety veto", nErr: 1)
        }
        return outcome
    }
}

extension AutotuneRecommendResult {
    func contextCalibrationHumanTranscript(configurationApplied: Bool) -> String {
        guard let contextCalibration else {
            return humanTranscript(configurationApplied: configurationApplied)
        }
        let contextLine = "Interactive context: \(contextCalibration.recommendedContext) tokens "
            + "(uncached p95 TTFT <= \(contextCalibration.ttftCeilingMS)ms; "
            + "RAM/model upper bound \(contextCalibration.safeUpperBound))."
        var transcript = humanTranscript(configurationApplied: configurationApplied)
            .replacingOccurrences(
                of: "Real earnings scale with buyer demand and your uptime.",
                with: "\(contextLine)\nReal earnings scale with buyer demand and your uptime."
            )
        if !configurationApplied {
            transcript = transcript.replacingOccurrences(
                of: "To apply this recommendation, rerun with --apply. Then start the provider with:",
                with: "To apply this measured context, rerun with --calibrate-context --apply. Then start the provider with:"
            )
        }
        return transcript
    }
}
