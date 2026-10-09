import XCTest
@testable import macprovider_cli

final class AutotuneConcurrencyCalibrationTests: XCTestCase {
    func testSelectsDepthWithHighestAggregateThroughput() async throws {
        // depth 2 is the aggregate peak; depth 3 is still measured (a lower
        // step never stops the sweep) and the peak is selected.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: feasible(100),
            2: feasible(200),
            3: feasible(150),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 3,
            tierConstant: 4,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: prober
        )

        XCTAssertEqual(result.recommendedMaxBatch, 2)
        XCTAssertEqual(result.tierConstantMaxBatch, 4)
        XCTAssertFalse(result.draftPinned)
        XCTAssertEqual(result.measurements.map(\.batchDepth), [1, 2, 3])
        let calls = await prober.calls
        XCTAssertEqual(calls.map(\.batchDepth), [1, 2, 3])
        XCTAssertTrue(calls.allSatisfy { $0.calibrationContext == 4_000 })
    }

    func testNeverExceedsMemoryFitOrHardCap() async throws {
        // Aggregate keeps climbing materially, so only the bounds can stop it.
        let climbing: [Int: ConcurrencyProbeOutcome] = Dictionary(
            uniqueKeysWithValues: (1...12).map { depth in
                (depth, ConcurrencyProbeOutcome.feasible(
                    aggregateTPS: 100 * pow(2, Double(depth)),
                    perStreamP95TTFTMS: 1_000,
                    perStreamDecodeTPS: 30
                ))
            }
        )

        // memory_fit_cap binds below the hard cap.
        let memoryBound = ConcurrencyCalibrationFake(outcomesByDepth: climbing)
        let memoryResult = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 3,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: memoryBound
        )
        XCTAssertEqual(memoryResult.recommendedMaxBatch, 3)
        XCTAssertEqual(memoryResult.memoryFitCap, 3)
        let memoryCalls = await memoryBound.calls
        XCTAssertEqual(memoryCalls.map(\.batchDepth), [1, 2, 3])

        // hard cap binds below the memory-fit cap.
        let hardBound = ConcurrencyCalibrationFake(outcomesByDepth: climbing)
        let hardResult = try await AutotuneConcurrencyCalibrator(hardCap: 4).calibrate(
            memoryFitCap: 100,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: hardBound
        )
        XCTAssertEqual(hardResult.recommendedMaxBatch, 4)
        XCTAssertEqual(hardResult.hardCap, 4)
        let hardCalls = await hardBound.calls
        XCTAssertEqual(hardCalls.map(\.batchDepth), [1, 2, 3, 4])
    }

    func testSweepsCoarseLadderAboveEightUpToTheBound() async throws {
        XCTAssertEqual(AutotuneConcurrencyCalibrator.sweepDepths(upperBound: 1), [1])
        XCTAssertEqual(AutotuneConcurrencyCalibrator.sweepDepths(upperBound: 8), Array(1...8))
        XCTAssertEqual(AutotuneConcurrencyCalibrator.sweepDepths(upperBound: 12), Array(1...8) + [12])
        XCTAssertEqual(AutotuneConcurrencyCalibrator.sweepDepths(upperBound: 20), Array(1...8) + [12, 16, 20])
        XCTAssertEqual(AutotuneConcurrencyCalibrator.sweepDepths(upperBound: 32), Array(1...8) + [12, 16, 24, 32])
        XCTAssertEqual(AutotuneConcurrencyCalibrator().hardCap, ProviderCapacity.maxConcurrencyOverrideLimit)
        XCTAssertEqual(ProviderCapacity.maxConcurrencyOverrideLimit, 32)

        // Aggregate doubles per measured depth, so only the memory-fit bound
        // stops it; a bound between rungs is measured itself.
        let climbing: [Int: ConcurrencyProbeOutcome] = Dictionary(
            uniqueKeysWithValues: AutotuneConcurrencyCalibrator.sweepDepths(upperBound: 32)
                .enumerated().map { index, depth in
                    (depth, ConcurrencyProbeOutcome.feasible(
                        aggregateTPS: 100 * pow(2, Double(index)),
                        perStreamP95TTFTMS: 1_000,
                        perStreamDecodeTPS: 30
                    ))
                }
                + [(20, ConcurrencyProbeOutcome.feasible(aggregateTPS: 100 * pow(2, 11), perStreamP95TTFTMS: 1_000, perStreamDecodeTPS: 30))]
        )
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: climbing)
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 20,
            tierConstant: 8,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: prober
        )
        XCTAssertEqual(result.recommendedMaxBatch, 20)
        XCTAssertEqual(result.hardCap, 32)
        let calls = await prober.calls
        XCTAssertEqual(calls.map(\.batchDepth), Array(1...8) + [12, 16, 20])
    }

    func testMeasuresEveryRungAndTieBreaksWithinGainFraction() async throws {
        // 8 -> 12 rows adds only 3%, but the sweep keeps climbing: 16 rows is
        // the aggregate peak (+25% over 8). 24 rows is within the 15% tie band
        // of 16, so the lower depth wins. 32 breaches the TTFT ceiling.
        let eight = 40 * pow(1.2, 8)
        var outcomes: [Int: ConcurrencyProbeOutcome] = Dictionary(
            uniqueKeysWithValues: (1...8).map { depth in (depth, feasible(40 * pow(1.2, Double(depth)))) }
        )
        outcomes[12] = feasible(eight * 1.03, ttft: 2_000)
        outcomes[16] = feasible(eight * 1.25, ttft: 4_000)
        outcomes[24] = feasible(eight * 1.20, ttft: 7_000)
        outcomes[32] = feasible(eight * 1.30, ttft: 9_000)
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: outcomes)
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 32,
            tierConstant: 8,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: prober
        )
        XCTAssertEqual(result.recommendedMaxBatch, 16)
        let calls = await prober.calls
        XCTAssertEqual(calls.map(\.batchDepth), Array(1...8) + [12, 16, 24, 32])
        let rejected = try XCTUnwrap(result.measurements.last)
        XCTAssertEqual(rejected.batchDepth, 32)
        XCTAssertFalse(rejected.passed)
    }

    func testTieBreaksTowardLowerDepthWithinGainFraction() async throws {
        // Every depth is measured; the best (112) is within 15% of depth 1
        // (100), so the lowest depth inside the tie band wins.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: feasible(100),
            2: feasible(110),
            3: feasible(112),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 3,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: prober
        )
        XCTAssertEqual(result.recommendedMaxBatch, 1)
        let calls = await prober.calls
        XCTAssertEqual(calls.map(\.batchDepth), [1, 2, 3])
        XCTAssertEqual(
            AutotuneConcurrencyCalibrator.selectDepth(feasible: [], minAggregateGainFraction: 0.15),
            1
        )
    }

    func testBaselineFailureFailsClosed() async {
        // batch=1 is measured first and exceeds the TTFT ceiling.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 9_000, perStreamDecodeTPS: 30),
        ])
        await XCTAssertThrowsErrorAsync(
            try await AutotuneConcurrencyCalibrator().calibrate(
                memoryFitCap: 8,
                tierConstant: 1,
                draftConfigured: false,
                calibrationContext: 4_000,
                promptReserveTokens: 256,
                completionTokens: 1_024,
                prober: prober
            )
        ) { error in
            guard case AutotuneConcurrencyCalibrationError.baselineFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let calls = await prober.calls
        XCTAssertEqual(calls.map(\.batchDepth), [1])
    }

    func testTTFTCeilingStopsSweepAndKeepsBestLowerDepth() async throws {
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: feasible(100),
            2: feasible(200),
            3: feasible(400, ttft: 9_000),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 8,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: prober
        )
        XCTAssertEqual(result.recommendedMaxBatch, 2)
        let calls = await prober.calls
        XCTAssertEqual(calls.map(\.batchDepth), [1, 2, 3])
        let rejected = try XCTUnwrap(result.measurements.first { $0.batchDepth == 3 })
        XCTAssertFalse(rejected.passed)
        XCTAssertEqual(rejected.failureReason?.contains("exceeded ceiling 8000ms"), true)
    }

    func testTTFTIncreaseOverBaselineDoesNotRejectDepth() async throws {
        // Continuous batching raises per-stream TTFT with any queued prefill.
        // depth 2's p95 is 4x batch=1 but under the absolute ceiling, so it
        // stays feasible and its aggregate gain selects it.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: feasible(100, ttft: 1_000),
            2: feasible(180, ttft: 4_000),
            3: feasible(190, ttft: 4_500),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 3,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: prober
        )
        XCTAssertEqual(result.recommendedMaxBatch, 2)
        XCTAssertTrue(result.measurements.allSatisfy(\.passed))
    }

    func testPerStreamDecodeRateIsRecordedButNeverGates() async throws {
        // A slow per-stream decode does not reject a depth; only memory fit,
        // the TTFT ceiling and errors bound the search. A window without a
        // measurable per-stream decode span records null.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: feasible(100, decode: 30),
            2: feasible(500, ttft: 5_000, decode: 5),
            3: feasible(510, ttft: 6_000, decode: nil),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 3,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: prober
        )
        XCTAssertEqual(result.recommendedMaxBatch, 2)
        XCTAssertEqual(result.measurements.map(\.perStreamDecodeTPS), [30, 5, nil])
        XCTAssertTrue(result.measurements.allSatisfy(\.passed))
        XCTAssertTrue(result.jsonString.contains("\"per_stream_decode_tps\":null"))
    }

    func testNonFiniteDecodeRateFailsClosed() async {
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: feasible(100),
            2: feasible(200, decode: .nan),
        ])
        await XCTAssertThrowsErrorAsync(
            try await AutotuneConcurrencyCalibrator().calibrate(
                memoryFitCap: 8,
                tierConstant: 1,
                draftConfigured: false,
                calibrationContext: 4_000,
                promptReserveTokens: 256,
                completionTokens: 1_024,
                prober: prober
            )
        ) { error in
            guard case AutotuneConcurrencyCalibrationError.probeFailed(let depth, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(depth, 2)
        }
    }

    func testDefaultProbeShapeIsFixedNotContextFilling() async throws {
        XCTAssertEqual(AutotuneConcurrencyCalibrator.defaultProbePromptTokens, 1_792)
        XCTAssertEqual(AutotuneConcurrencyCalibrator.defaultProbeCompletionTokens, 1_024)
        XCTAssertEqual(AutotuneConcurrencyCalibrator.promptReserveTokens, 256)
        // A 200k context still probes the fixed default prompt.
        XCTAssertEqual(
            AutotuneConcurrencyCalibrator.probePromptTokens(
                calibrationContext: 200_000, promptReserveTokens: 256, completionTokens: 1_024
            ),
            1_792
        )
        // A context too small for it shrinks the prompt, never the reserve.
        XCTAssertEqual(
            AutotuneConcurrencyCalibrator.probePromptTokens(
                calibrationContext: 2_048, promptReserveTokens: 256, completionTokens: 1_024
            ),
            768
        )

        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 1_000, perStreamDecodeTPS: 30),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 1,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 200_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: prober
        )
        let calls = await prober.calls
        XCTAssertEqual(calls, [.init(batchDepth: 1, calibrationContext: 200_000, promptTokens: 1_792, completionTokens: 1_024)])
        XCTAssertEqual(result.probePromptTokens, 1_792)
        XCTAssertEqual(result.calibrationContextTokens, 200_000)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.jsonString.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["schema_version"] as? String, "autotune_concurrency_calibration.v2")
        XCTAssertEqual(json["probe_prompt_tokens"] as? Int, 1_792)
        XCTAssertEqual(json["completion_tokens"] as? Int, 1_024)
        XCTAssertNil(json["min_per_stream_decode_tps"])
        XCTAssertNil(json["ttft_regression_factor"])
        let sample = try XCTUnwrap((json["measurements"] as? [[String: Any]])?.first)
        XCTAssertEqual(sample["per_stream_decode_tps"] as? Double, 30)
        // §6 field order.
        let order = ["\"ttft_ceiling_ms\"", "\"min_aggregate_gain_fraction\"",
                     "\"calibration_context_tokens\"", "\"probe_prompt_tokens\"", "\"prompt_reserve_tokens\"",
                     "\"completion_tokens\""]
        let positions = try order.map { try XCTUnwrap(result.jsonString.range(of: $0)).lowerBound }
        XCTAssertEqual(positions, positions.sorted())

        let roundTripped = try JSONDecoder().decode(
            AutotuneConcurrencyCalibrationResult.self,
            from: Data(result.jsonString.utf8)
        )
        XCTAssertEqual(roundTripped, result)
    }

    func testOperatorProbeShapeIsUsedAndRecorded() async throws {
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 1_000, perStreamDecodeTPS: 30),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 1,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 32_000,
            promptTokens: 8_000,
            promptReserveTokens: 256,
            completionTokens: 512,
            prober: prober
        )
        let calls = await prober.calls
        XCTAssertEqual(calls, [.init(batchDepth: 1, calibrationContext: 32_000, promptTokens: 8_000, completionTokens: 512)])
        XCTAssertEqual(result.probePromptTokens, 8_000)
        XCTAssertEqual(result.completionTokens, 512)

        // A requested prompt larger than the context allows is capped.
        let capped = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 1_000, perStreamDecodeTPS: 30),
        ])
        let cappedResult = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 1,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 4_096,
            promptTokens: 100_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: capped
        )
        XCTAssertEqual(cappedResult.probePromptTokens, 2_816)

        // A completion that leaves no prompt room is rejected before probing.
        let never = ConcurrencyCalibrationFake(outcomesByDepth: [:])
        await XCTAssertThrowsErrorAsync(
            try await AutotuneConcurrencyCalibrator().calibrate(
                memoryFitCap: 1,
                tierConstant: 1,
                draftConfigured: false,
                calibrationContext: 1_024,
                promptReserveTokens: 256,
                completionTokens: 1_024,
                prober: never
            )
        ) { error in
            guard case AutotuneConcurrencyCalibrationError.invalidBounds = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let neverCalls = await never.calls
        XCTAssertTrue(neverCalls.isEmpty)
    }

    func testProbeShapeOptionsRequireCalibrateConcurrency() throws {
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--calibrate-concurrency-prompt-tokens", "4000", "--no-submit-hardware-evidence", "--dry-run",
        ]))
        XCTAssertThrowsError(try AutotuneCommand.parse([
            "--recommend", "--calibrate-concurrency", "--calibrate-concurrency-completion-tokens", "0", "--no-submit-hardware-evidence", "--dry-run",
        ]))
        let parsed = try AutotuneCommand.parse([
            "--recommend", "--calibrate-concurrency",
            "--calibrate-concurrency-prompt-tokens", "4000",
            "--calibrate-concurrency-completion-tokens", "512",
            "--no-submit-hardware-evidence",
            "--dry-run",
        ])
        XCTAssertEqual(parsed.calibrateConcurrencyPromptTokens, 4_000)
        XCTAssertEqual(parsed.calibrateConcurrencyCompletionTokens, 512)
    }

    func testStoredV1RecordStillDecodes() throws {
        let v1 = """
        {"schema_version":"autotune_concurrency_calibration.v1","recommended_max_batch":2,"tier_constant_max_batch":4,"memory_fit_cap":8,"hard_cap":32,"ttft_ceiling_ms":8000,"ttft_regression_factor":1.5,"min_aggregate_gain_fraction":0.15,"calibration_context_tokens":4000,"prompt_reserve_tokens":256,"completion_tokens":64,"draft_pinned":false,"measurements":[{"batch_depth":1,"streams":1,"aggregate_tps":100,"per_stream_p95_ttft_ms":1000,"passed":true,"failure_reason":null}]}
        """
        let decoded = try JSONDecoder().decode(AutotuneConcurrencyCalibrationResult.self, from: Data(v1.utf8))
        XCTAssertEqual(decoded.schemaVersion, "autotune_concurrency_calibration.v1")
        XCTAssertEqual(decoded.recommendedMaxBatch, 2)
        XCTAssertEqual(decoded.probePromptTokens, 0)
        XCTAssertNil(decoded.measurements.first?.perStreamDecodeTPS)
    }

    // MARK: - Steady-state window aggregation

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: Double) -> Date {
        t0.addingTimeInterval(seconds)
    }

    func testWindowCountsOnlyTokensStreamedInsideTheWindow() throws {
        // Window [10, 20). Request A streams 1 token/s from t=5 to t=24
        // (20 chunks); 10 of them (t=10...19) fall in the window. Request B
        // streams 10 chunks from t=12.0 to t=12.9 (10 tok/s), all inside.
        let a = ConcurrencyWindowRequest(
            start: at(4), end: at(24),
            chunkTimes: (5...24).map { at(Double($0)) },
            usageDecodedTokens: 20, usageGenerationMS: nil
        )
        let b = ConcurrencyWindowRequest(
            start: at(11), end: at(13),
            chunkTimes: (0..<10).map { at(12 + Double($0) / 10) },
            usageDecodedTokens: 10, usageGenerationMS: nil
        )
        let metrics = try XCTUnwrap(
            ConcurrencyWindowAggregation.aggregate(requests: [a, b], windowStart: at(10), windowEnd: at(20))
        )
        XCTAssertEqual(metrics.tokensInWindow, 20, accuracy: 1e-9)
        XCTAssertEqual(metrics.aggregateTPS, 2, accuracy: 1e-9)
        // TTFT only over requests started inside the window: B (1s).
        XCTAssertEqual(metrics.ttftSamples, 1)
        XCTAssertEqual(metrics.perStreamP95TTFTMS, 1_000, accuracy: 1e-6)
        // Decode: A in-window 1 tok/s, B 10 tok/s -> median 5.5.
        XCTAssertEqual(metrics.decodeSamples, 2)
        XCTAssertEqual(try XCTUnwrap(metrics.perStreamDecodeTPS), 5.5, accuracy: 1e-9)
    }

    func testWindowTTFTFallsBackToAllRequestsWhenNoneStartInside() throws {
        // Requests longer than the window: none start inside it.
        let a = ConcurrencyWindowRequest(
            start: at(0), end: at(40),
            chunkTimes: (2...40).map { at(Double($0)) },
            usageDecodedTokens: 39, usageGenerationMS: nil
        )
        let b = ConcurrencyWindowRequest(
            start: at(1), end: at(40),
            chunkTimes: (5...40).map { at(Double($0)) },
            usageDecodedTokens: 36, usageGenerationMS: nil
        )
        let metrics = try XCTUnwrap(
            ConcurrencyWindowAggregation.aggregate(requests: [a, b], windowStart: at(10), windowEnd: at(30))
        )
        XCTAssertEqual(metrics.ttftSamples, 2)
        XCTAssertEqual(metrics.perStreamP95TTFTMS, 4_000, accuracy: 1e-6)
        XCTAssertEqual(metrics.aggregateTPS, 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(metrics.perStreamDecodeTPS), 1, accuracy: 1e-9)
    }

    func testWindowProratesSuppressedReasoningStreamOverProviderDecodeWindow() throws {
        // A reasoning channel suppressed from SSE: 2 visible chunks but 100
        // decoded tokens over a provider-reported 10s decode window ending at
        // t=30 (decode t=20...30). Window [25, 35) overlaps half of it.
        let r = ConcurrencyWindowRequest(
            start: at(18), end: at(30),
            chunkTimes: [at(29.5), at(29.9)],
            usageDecodedTokens: 100, usageGenerationMS: 10_000
        )
        let metrics = try XCTUnwrap(
            ConcurrencyWindowAggregation.aggregate(requests: [r], windowStart: at(25), windowEnd: at(35))
        )
        XCTAssertEqual(metrics.tokensInWindow, 50, accuracy: 1e-6)
        XCTAssertEqual(metrics.aggregateTPS, 5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(metrics.perStreamDecodeTPS), 10, accuracy: 1e-6)
        // TTFT = decode start - request start = 2s (fallback: started before window).
        XCTAssertEqual(metrics.perStreamP95TTFTMS, 2_000, accuracy: 1e-3)
    }

    func testWindowWithNoInWindowDecodeHasNoDecodeRate() throws {
        let r = ConcurrencyWindowRequest(
            start: at(0), end: at(5),
            chunkTimes: (1...5).map { at(Double($0)) },
            usageDecodedTokens: 5, usageGenerationMS: nil
        )
        let metrics = try XCTUnwrap(
            ConcurrencyWindowAggregation.aggregate(requests: [r], windowStart: at(10), windowEnd: at(20))
        )
        XCTAssertEqual(metrics.aggregateTPS, 0)
        XCTAssertNil(metrics.perStreamDecodeTPS)
        XCTAssertNil(ConcurrencyWindowAggregation.aggregate(requests: [], windowStart: at(10), windowEnd: at(20)))
        XCTAssertNil(ConcurrencyWindowAggregation.aggregate(requests: [r], windowStart: at(10), windowEnd: at(10)))
    }

    func testHigherDepthProbeFailureFailsClosed() async {
        // batch=1 passes, but batch=2 hits a probe ERROR (serve/process/veto/
        // malformed metrics). SPEC-023-R009 step 6 / AC-43: this fails the WHOLE
        // calibration closed — it must NOT silently return the passing depth 1
        // and let the caller store/apply a recommendation.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 1_000, perStreamDecodeTPS: 30),
            2: .infeasible(reason: "provider exited during concurrency probe", nErr: 2),
        ])
        await XCTAssertThrowsErrorAsync(
            try await AutotuneConcurrencyCalibrator().calibrate(
                memoryFitCap: 8,
                tierConstant: 4,
                draftConfigured: false,
                calibrationContext: 4_000,
                promptReserveTokens: 256,
                completionTokens: 1_024,
                prober: prober
            )
        ) { error in
            guard case AutotuneConcurrencyCalibrationError.probeFailed(let depth, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(depth, 2)
        }
        let calls = await prober.calls
        XCTAssertEqual(calls.map(\.batchDepth), [1, 2])
    }

    func testHonorsCustomTTFTCeiling() async throws {
        // A stricter ceiling (the operator's --buyer-ttft-ceiling-ms, wired in
        // by AutotuneCommand as min(buyer, 8000)) must gate depths the default
        // 8000ms ceiling would pass. depth 2's 3500ms p95 exceeds the 3000ms
        // ceiling, so it is rejected and the baseline depth is kept.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 2_000, perStreamDecodeTPS: 30),
            2: .feasible(aggregateTPS: 500, perStreamP95TTFTMS: 3_500, perStreamDecodeTPS: 30),
        ])
        let result = try await AutotuneConcurrencyCalibrator(ttftCeilingMS: 3_000).calibrate(
            memoryFitCap: 8,
            tierConstant: 4,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: prober
        )

        XCTAssertEqual(result.recommendedMaxBatch, 1)
        XCTAssertEqual(result.ttftCeilingMS, 3_000)
        let rejected = try XCTUnwrap(result.measurements.first { $0.batchDepth == 2 })
        XCTAssertFalse(rejected.passed)
    }

    func testDraftConfiguredPinsMaxBatchToOne() async throws {
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 1_000, perStreamDecodeTPS: 30),
            2: .feasible(aggregateTPS: 500, perStreamP95TTFTMS: 1_000, perStreamDecodeTPS: 30),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 8,
            tierConstant: 4,
            draftConfigured: true,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 1_024,
            prober: prober
        )

        XCTAssertEqual(result.recommendedMaxBatch, 1)
        XCTAssertTrue(result.draftPinned)
        XCTAssertTrue(result.measurements.isEmpty)
        // No sweep: the prober is never invoked.
        let calls = await prober.calls
        XCTAssertTrue(calls.isEmpty)
    }
}

private actor ConcurrencyCalibrationFake: AutotuneConcurrencyCalibrationProbing {
    struct Call: Equatable {
        var batchDepth: Int
        var calibrationContext: Int
        var promptTokens: Int
        var completionTokens: Int
    }

    private let outcomesByDepth: [Int: ConcurrencyProbeOutcome]
    private let defaultOutcome: ConcurrencyProbeOutcome
    private(set) var calls: [Call] = []

    init(
        outcomesByDepth: [Int: ConcurrencyProbeOutcome],
        defaultOutcome: ConcurrencyProbeOutcome = .infeasible(reason: "unstubbed depth", nErr: 1)
    ) {
        self.outcomesByDepth = outcomesByDepth
        self.defaultOutcome = defaultOutcome
    }

    func measure(
        batchDepth: Int,
        calibrationContext: Int,
        promptTokens: Int,
        completionTokens: Int,
        deadline _: Date?
    ) async throws -> ConcurrencyProbeOutcome {
        calls.append(Call(
            batchDepth: batchDepth,
            calibrationContext: calibrationContext,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        ))
        return outcomesByDepth[batchDepth] ?? defaultOutcome
    }
}

private func feasible(
    _ aggregateTPS: Double,
    ttft: Double = 1_000,
    decode: Double? = 30
) -> ConcurrencyProbeOutcome {
    .feasible(aggregateTPS: aggregateTPS, perStreamP95TTFTMS: ttft, perStreamDecodeTPS: decode)
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
