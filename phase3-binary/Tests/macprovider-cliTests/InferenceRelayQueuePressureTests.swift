@testable import macprovider_cli
import XCTest

final class InferenceRelayQueuePressureTests: XCTestCase {
    func testPreAdmissionQueuePressureReachesTheCoordinatorAsReroutableQueueFull() throws {
        for schedulerError in [ContinuousBatchSchedulerError.backpressure, .queueWaitTimedOut] {
            let error = try XCTUnwrap(schedulerError.asAPIError())
            let frame = InferenceRelay.errorEndFrame(requestID: "req-1", error: error, chunksSent: 0)
            XCTAssertEqual(frame["status"] as? String, "error_queue_full", "\(error.code)")
            XCTAssertNil(frame["retryable"], "error_queue_full carries no provider retryable override")
        }
    }

    func testPostTokenDeliveryBackpressureIsNotReroutable() throws {
        let error = try XCTUnwrap(ContinuousBatchSchedulerError.deliveryBackpressure.asAPIError())
        let frame = InferenceRelay.errorEndFrame(requestID: "req-1", error: error, chunksSent: 3)
        XCTAssertEqual(
            frame["status"] as? String,
            "error_internal",
            "tokens may already have reached the buyer; re-routing would re-run work that partly happened"
        )
    }

    func testBatchedContextRejectionReachesTheCoordinatorAsContextExceeded() throws {
        let error = try XCTUnwrap(ContinuousBatchSchedulerError.contextLengthExceeded(
            promptTokens: 40,
            maxOutputTokens: 199_960,
            contextTokens: 131_072
        ).asAPIError())
        let frame = InferenceRelay.errorEndFrame(requestID: "req-1", error: error, chunksSent: 0)
        XCTAssertEqual(
            frame["status"] as? String,
            "error_context_exceeded",
            "a request over the batched context cap is the buyer's 413, not a retryable provider 502"
        )
    }
}
