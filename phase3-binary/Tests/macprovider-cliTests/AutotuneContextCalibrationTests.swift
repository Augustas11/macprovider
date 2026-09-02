import XCTest
@testable import macprovider_cli

final class AutotuneContextCalibrationTests: XCTestCase {
    func testSearchFindsLargestPassingQuantumAndValidatesItThreeTimes() async throws {
        let prober = ContextCalibrationFake(ttftByContext: [
            4_000: 3_000,
            8_000: 7_000,
            16_000: 14_000,
            12_000: 10_000,
            10_000: 7_500,
            11_000: 8_500,
        ])
        let result = try await AutotuneContextCalibrator().calibrate(
            safeUpperBound: 50_000,
            prober: prober
        )

        XCTAssertEqual(result.recommendedContext, 10_000)
        XCTAssertEqual(result.measurements.last?.replicates, 3)
        let calls = await prober.calls
        XCTAssertEqual(calls.last?.context, 10_000)
        XCTAssertEqual(calls.last?.replicates, 3)
    }

    func testSafeUpperBoundIsNeverExceeded() async throws {
        let prober = ContextCalibrationFake(defaultTTFT: 1_000)
        let result = try await AutotuneContextCalibrator().calibrate(
            safeUpperBound: 9_500,
            prober: prober
        )

        XCTAssertEqual(result.safeUpperBound, 9_000)
        XCTAssertEqual(result.recommendedContext, 9_000)
        let calls = await prober.calls
        XCTAssertTrue(calls.allSatisfy { $0.context <= 9_000 })
    }

    func testMinimumFailureFailsClosed() async {
        let prober = ContextCalibrationFake(defaultTTFT: 8_001)
        await XCTAssertThrowsErrorAsync(
            try await AutotuneContextCalibrator().calibrate(
                safeUpperBound: 50_000,
                prober: prober
            )
        ) { error in
            guard case AutotuneContextCalibrationError.minimumFailed(let context, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(context, 4_000)
        }
    }

    func testHigherContextTimeoutFailsClosedWithoutSelectingLowerContext() async {
        let prober = ContextCalibrationFake(
            defaultTTFT: 1_000,
            infeasibleContexts: [8_000]
        )
        await XCTAssertThrowsErrorAsync(
            try await AutotuneContextCalibrator().calibrate(
                safeUpperBound: 8_000,
                prober: prober
            )
        ) { error in
            guard case AutotuneContextCalibrationError.probeFailed(let context, let reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(context, 8_000)
            XCTAssertEqual(reason, "probe timed out (n_err=1)")
        }
        let calls = await prober.calls
        XCTAssertEqual(calls, [
            ContextCalibrationFake.Call(context: 4_000, replicates: 1),
            ContextCalibrationFake.Call(context: 8_000, replicates: 1),
        ])
    }

    func testFinalValidationFailureDoesNotReturnUnvalidatedContext() async {
        let prober = ContextCalibrationFake(
            defaultTTFT: 1_000,
            finalValidationTTFT: 9_000
        )
        await XCTAssertThrowsErrorAsync(
            try await AutotuneContextCalibrator().calibrate(
                safeUpperBound: 4_000,
                prober: prober
            )
        ) { error in
            guard case AutotuneContextCalibrationError.finalValidationFailed(let context, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(context, 4_000)
        }
    }

    func testInterruptDuringHigherCellStopsBeforeLaterProbeOrFinalValidation() async {
        let flag = AutotuneInterruptFlag()
        let prober = ContextCalibrationFake(
            defaultTTFT: 1_000,
            interruptAtContext: 8_000,
            interruptFlag: flag
        )
        await XCTAssertThrowsErrorAsync(
            try await AutotuneContextCalibrator().calibrate(
                safeUpperBound: 50_000,
                prober: prober,
                isInterrupted: { flag.isSet() }
            )
        ) { error in
            XCTAssertEqual(error as? AutotuneContextCalibrationError, .interrupted)
        }
        let calls = await prober.calls
        XCTAssertEqual(calls, [
            ContextCalibrationFake.Call(context: 4_000, replicates: 1),
            ContextCalibrationFake.Call(context: 8_000, replicates: 1),
        ])
    }

    func testDeadlineBeforeProbeStopsWithoutMeasuring() async {
        let prober = ContextCalibrationFake(defaultTTFT: 1_000)
        await XCTAssertThrowsErrorAsync(
            try await AutotuneContextCalibrator().calibrate(
                safeUpperBound: 50_000,
                prober: prober,
                hasDeadlineExpired: { true }
            )
        ) { error in
            XCTAssertEqual(error as? AutotuneContextCalibrationError, .deadlineExceeded)
        }
        let calls = await prober.calls
        XCTAssertEqual(calls, [])
    }

    func testDeadlineAfterProbeStopsBeforeLaterProbeOrFinalValidation() async {
        let prober = ContextCalibrationFake(defaultTTFT: 1_000)
        var deadlineChecks = 0
        await XCTAssertThrowsErrorAsync(
            try await AutotuneContextCalibrator().calibrate(
                safeUpperBound: 50_000,
                prober: prober,
                hasDeadlineExpired: {
                    deadlineChecks += 1
                    return deadlineChecks >= 2
                }
            )
        ) { error in
            XCTAssertEqual(error as? AutotuneContextCalibrationError, .deadlineExceeded)
        }
        let calls = await prober.calls
        XCTAssertEqual(calls, [
            ContextCalibrationFake.Call(context: 4_000, replicates: 1),
        ])
    }

    func testResultJSONCarriesPolicyAndEvidence() throws {
        let result = AutotuneContextCalibrationResult(
            recommendedContext: 8_000,
            safeUpperBound: 50_000,
            minimumContext: 4_000,
            ttftCeilingMS: 8_000,
            quantum: 1_000,
            measurements: [
                AutotuneContextCalibrationMeasurement(
                    contextTokens: 8_000,
                    ttftP95MS: 7_500,
                    decodeTPS: 42.5,
                    replicates: 3,
                    passed: true
                ),
            ]
        )
        let object = try JSONSerialization.jsonObject(with: Data(result.jsonString.utf8)) as? [String: Any]
        XCTAssertEqual(object?["schema_version"] as? String, "autotune_context_calibration.v1")
        XCTAssertEqual(object?["recommended_context"] as? Int, 8_000)
        XCTAssertEqual((object?["measurements"] as? [[String: Any]])?.count, 1)
    }

    func testContextCalibrationFlagsRequireRecommend() {
        XCTAssertThrowsError(try AutotuneCommand.parse(["--calibrate-context", "--dry-run"]))
        XCTAssertNoThrow(try AutotuneCommand.parse([
            "--recommend",
            "--calibrate-context",
            "--no-submit-hardware-evidence",
            "--dry-run",
        ]))
    }

    func testCalibrationPromptNonceChangesPrefixWithoutChangingWordCount() {
        let first = Stage1Prober.paddedPrompt(targetContext: 4_000, nonce: "first")
        let second = Stage1Prober.paddedPrompt(targetContext: 4_000, nonce: "second")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.split(separator: " ").count, Stage1Prober.promptTokenEstimate(targetContext: 4_000))
        XCTAssertEqual(first.split(separator: " ").count, second.split(separator: " ").count)
    }

    func testCalibrationPromptUsesAdvertisedBoundaryReserveAndOneCompletionToken() {
        let target = 4_000
        let prompt = Stage1Prober.contextCalibrationPrompt(targetContext: target, nonce: "shape")
        XCTAssertEqual(
            prompt.split(separator: " ").count,
            target
                - AutotuneContextCalibrationResult.promptReserveTokens
                - AutotuneContextCalibrationResult.completionTokens
        )
        XCTAssertEqual(AutotuneContextCalibrationResult.completionTokens, 1)
    }
}

private actor ContextCalibrationFake: AutotuneContextCalibrationProbing {
    struct Call: Equatable {
        var context: Int
        var replicates: Int
    }

    private let ttftByContext: [Int: Int]
    private let defaultTTFT: Int
    private let finalValidationTTFT: Int?
    private let infeasibleContexts: Set<Int>
    private let interruptAtContext: Int?
    private let interruptFlag: AutotuneInterruptFlag?
    private(set) var calls: [Call] = []

    init(
        ttftByContext: [Int: Int] = [:],
        defaultTTFT: Int = 1_000,
        finalValidationTTFT: Int? = nil,
        infeasibleContexts: Set<Int> = [],
        interruptAtContext: Int? = nil,
        interruptFlag: AutotuneInterruptFlag? = nil
    ) {
        self.ttftByContext = ttftByContext
        self.defaultTTFT = defaultTTFT
        self.finalValidationTTFT = finalValidationTTFT
        self.infeasibleContexts = infeasibleContexts
        self.interruptAtContext = interruptAtContext
        self.interruptFlag = interruptFlag
    }

    func measure(contextTokens: Int, replicates: Int, deadline _: Date?) async throws -> Stage1ProbeResult {
        calls.append(Call(context: contextTokens, replicates: replicates))
        if contextTokens == interruptAtContext {
            interruptFlag?.set()
        }
        if infeasibleContexts.contains(contextTokens) {
            return .infeasible(reason: "probe timed out", nErr: 1)
        }
        let ttft = replicates >= 3
            ? (finalValidationTTFT ?? ttftByContext[contextTokens] ?? defaultTTFT)
            : (ttftByContext[contextTokens] ?? defaultTTFT)
        return .feasible(medianTPS: 40, p95TTFTMS: Double(ttft))
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
