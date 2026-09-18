import XCTest
@testable import macprovider_cli

final class AutotuneConcurrencyCalibrationTests: XCTestCase {
    func testSelectsDepthWithHighestAggregateThroughput() async throws {
        // depth 2 is the aggregate peak; depth 3 regresses below it, so the
        // sweep stops and returns the highest-aggregate feasible depth.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 1_000),
            2: .feasible(aggregateTPS: 200, perStreamP95TTFTMS: 1_000),
            3: .feasible(aggregateTPS: 150, perStreamP95TTFTMS: 1_000),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 8,
            tierConstant: 4,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 64,
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
                    perStreamP95TTFTMS: 1_000
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
            completionTokens: 64,
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
            completionTokens: 64,
            prober: hardBound
        )
        XCTAssertEqual(hardResult.recommendedMaxBatch, 4)
        XCTAssertEqual(hardResult.hardCap, 4)
        let hardCalls = await hardBound.calls
        XCTAssertEqual(hardCalls.map(\.batchDepth), [1, 2, 3, 4])
    }

    func testTieBreaksTowardLowerDepthWithinGainFraction() async throws {
        // depth 2 improves by only 10% (< the 15% minimum aggregate-gain
        // fraction), so the lower depth wins and the sweep stops.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 1_000),
            2: .feasible(aggregateTPS: 110, perStreamP95TTFTMS: 1_000),
            3: .feasible(aggregateTPS: 300, perStreamP95TTFTMS: 1_000),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 8,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 64,
            prober: prober
        )

        XCTAssertEqual(result.recommendedMaxBatch, 1)
        // depth 3 is never measured: the sweep stops at the immaterial gain.
        let calls = await prober.calls
        XCTAssertEqual(calls.map(\.batchDepth), [1, 2])
    }

    func testBaselineFailureFailsClosed() async {
        // batch=1 is measured first and exceeds the TTFT ceiling.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 9_000),
        ])
        await XCTAssertThrowsErrorAsync(
            try await AutotuneConcurrencyCalibrator().calibrate(
                memoryFitCap: 8,
                tierConstant: 1,
                draftConfigured: false,
                calibrationContext: 4_000,
                promptReserveTokens: 256,
                completionTokens: 64,
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

    func testLatencyRegressionRejectsHigherDepth() async throws {
        // depth 2's aggregate is materially higher, but its per-stream p95 TTFT
        // regresses past 1.5x the batch=1 baseline, so it is rejected and the
        // baseline depth is kept.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 1_000),
            2: .feasible(aggregateTPS: 500, perStreamP95TTFTMS: 2_000),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 8,
            tierConstant: 1,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 64,
            prober: prober
        )

        XCTAssertEqual(result.recommendedMaxBatch, 1)
        let regressed = try XCTUnwrap(result.measurements.first { $0.batchDepth == 2 })
        XCTAssertFalse(regressed.passed)
        XCTAssertEqual(regressed.failureReason?.contains("regressed"), true)
    }

    func testHigherDepthProbeFailureFailsClosed() async {
        // batch=1 passes, but batch=2 hits a probe ERROR (serve/process/veto/
        // malformed metrics). SPEC-023-R009 step 6 / AC-43: this fails the WHOLE
        // calibration closed — it must NOT silently return the passing depth 1
        // and let the caller store/apply a recommendation.
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 1_000),
            2: .infeasible(reason: "provider exited during concurrency probe", nErr: 2),
        ])
        await XCTAssertThrowsErrorAsync(
            try await AutotuneConcurrencyCalibrator().calibrate(
                memoryFitCap: 8,
                tierConstant: 4,
                draftConfigured: false,
                calibrationContext: 4_000,
                promptReserveTokens: 256,
                completionTokens: 64,
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
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 2_000),
            2: .feasible(aggregateTPS: 500, perStreamP95TTFTMS: 3_500),
        ])
        let result = try await AutotuneConcurrencyCalibrator(ttftCeilingMS: 3_000).calibrate(
            memoryFitCap: 8,
            tierConstant: 4,
            draftConfigured: false,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 64,
            prober: prober
        )

        XCTAssertEqual(result.recommendedMaxBatch, 1)
        XCTAssertEqual(result.ttftCeilingMS, 3_000)
        let rejected = try XCTUnwrap(result.measurements.first { $0.batchDepth == 2 })
        XCTAssertFalse(rejected.passed)
    }

    func testDraftConfiguredPinsMaxBatchToOne() async throws {
        let prober = ConcurrencyCalibrationFake(outcomesByDepth: [
            1: .feasible(aggregateTPS: 100, perStreamP95TTFTMS: 1_000),
            2: .feasible(aggregateTPS: 500, perStreamP95TTFTMS: 1_000),
        ])
        let result = try await AutotuneConcurrencyCalibrator().calibrate(
            memoryFitCap: 8,
            tierConstant: 4,
            draftConfigured: true,
            calibrationContext: 4_000,
            promptReserveTokens: 256,
            completionTokens: 64,
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
        promptReserveTokens _: Int,
        completionTokens _: Int,
        deadline _: Date?
    ) async throws -> ConcurrencyProbeOutcome {
        calls.append(Call(batchDepth: batchDepth, calibrationContext: calibrationContext))
        return outcomesByDepth[batchDepth] ?? defaultOutcome
    }
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
