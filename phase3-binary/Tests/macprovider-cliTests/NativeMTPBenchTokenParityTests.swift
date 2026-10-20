#if DEBUG || MACPROVIDER_LAB_HARNESS
import XCTest
@testable import macprovider_cli

final class NativeMTPBenchTokenParityTests: XCTestCase {
    func testDifferentTokenIDsMismatchEvenWhenTextAndCountsMatch() {
        let ordinary = comparable(id: "req-1", tokenIDs: [10, 20])
        let native = comparable(id: "req-1", tokenIDs: [11, 20])

        XCTAssertTrue(NativeMTPBenchParity.mismatch(ordinary: [ordinary], native: [native]))
    }

    func testTerminalMismatchFailsParity() {
        let ordinary = comparable(id: "req-1", tokenIDs: [10], finishReason: "stop")
        let native = comparable(id: "req-1", tokenIDs: [10], finishReason: "length")

        XCTAssertTrue(NativeMTPBenchParity.mismatch(ordinary: [ordinary], native: [native]))
    }

    func testMissingDuplicateAndWrongCountCapturesFailClosed() {
        let requests = [observed(id: "req-1")]

        XCTAssertThrowsError(try NativeMTPBenchTokenCaptureValidator.aligned(
            captures: [],
            requests: requests
        ))
        XCTAssertThrowsError(try NativeMTPBenchTokenCaptureValidator.aligned(
            captures: [capture(id: "req-1"), capture(id: "req-1")],
            requests: requests
        ))
        XCTAssertThrowsError(try NativeMTPBenchTokenCaptureValidator.aligned(
            captures: [capture(id: "req-1", tokenIDs: [10, 20], schedulerCompletionTokens: 1)],
            requests: requests
        ))
    }

    func testStopMayCaptureOneRawModelStopTokenBeyondFinalCompletion() throws {
        let aligned = try NativeMTPBenchTokenCaptureValidator.aligned(
            captures: [capture(
                id: "req-1",
                tokenIDs: [10, 99],
                schedulerCompletionTokens: 2,
                validatedCompletionTokens: 1,
                finishReason: "stop"
            )],
            requests: [observed(id: "req-1", completionTokens: 1, finishReason: "stop")]
        )

        XCTAssertEqual(aligned.first?.tokenIDs, [10, 99])
    }

    func testLengthRejectsExtraRawToken() {
        XCTAssertThrowsError(try NativeMTPBenchTokenCaptureValidator.aligned(
            captures: [capture(
                id: "req-1",
                tokenIDs: [10, 99],
                schedulerCompletionTokens: 2,
                validatedCompletionTokens: 1,
                finishReason: "length"
            )],
            requests: [observed(id: "req-1", completionTokens: 1, finishReason: "length")]
        ))
    }

    func testEmptyAndDuplicateCompletionRowsFailClosed() {
        XCTAssertThrowsError(try NativeMTPBenchTokenCaptureValidator.aligned(
            captures: [],
            requests: []
        ))
        XCTAssertThrowsError(try NativeMTPBenchTokenCaptureValidator.aligned(
            captures: [capture(id: "req-1")],
            requests: [observed(id: "req-1"), observed(id: "req-1")]
        ))
    }

    func testCaptureRowsAlignToCompletionRequestOrder() throws {
        let aligned = try NativeMTPBenchTokenCaptureValidator.aligned(
            captures: [capture(id: "req-2", tokenIDs: [2]), capture(id: "req-1", tokenIDs: [1])],
            requests: [
                observed(id: "req-1"),
                observed(id: "req-2"),
            ]
        )

        XCTAssertEqual(aligned.map(\.requestID), ["req-1", "req-2"])
        XCTAssertEqual(aligned.map(\.tokenIDs), [[1], [2]])
    }

    func testCaptureFinishReasonMustMatchCompletion() {
        XCTAssertThrowsError(try NativeMTPBenchTokenCaptureValidator.aligned(
            captures: [capture(id: "req-1", finishReason: "length")],
            requests: [observed(id: "req-1")]
        ))
    }

    func testResumeRejectsPreTokenParityHeader() throws {
        XCTAssertThrowsError(try NativeMTPExistingEvidence.validateRunMetricsVersion([
            "run_metrics_version": 5,
        ]))
        XCTAssertNoThrow(try NativeMTPExistingEvidence.validateRunMetricsVersion([
            "run_metrics_version": 6,
        ]))
    }

    func testResumeRejectsMalformedMetricsVersions() {
        let invalidVersions: [Any] = [6.5, "6", true, NSNull(), -6]
        for version in invalidVersions {
            XCTAssertThrowsError(try NativeMTPExistingEvidence.validateRunMetricsVersion([
                "run_metrics_version": version,
            ]))
        }
        XCTAssertThrowsError(try NativeMTPExistingEvidence.validateRunMetricsVersion([:]))
    }

    private func comparable(
        id: String,
        tokenIDs: [Int],
        finishReason: String = "stop"
    ) -> NativeMTPBenchComparableRequest {
        NativeMTPBenchComparableRequest(
            requestID: id,
            content: "same text",
            completionTokens: tokenIDs.count,
            finishReason: finishReason,
            tokenIDs: tokenIDs
        )
    }

    private func capture(
        id: String,
        tokenIDs: [Int] = [10],
        schedulerCompletionTokens: Int? = nil,
        validatedCompletionTokens: Int? = nil,
        finishReason: String = "stop"
    ) -> NativeMTPBenchTokenCapture {
        NativeMTPBenchTokenCapture(
            requestID: id,
            tokenIDs: tokenIDs,
            schedulerCompletionTokens: schedulerCompletionTokens ?? tokenIDs.count,
            validatedCompletionTokens: validatedCompletionTokens ?? tokenIDs.count,
            finishReason: finishReason
        )
    }

    private func observed(
        id: String,
        completionTokens: Int = 1,
        finishReason: String = "stop"
    ) -> NativeMTPBenchObservedRequest {
        NativeMTPBenchObservedRequest(
            requestID: id,
            completionTokens: completionTokens,
            finishReason: finishReason
        )
    }
}
#endif
