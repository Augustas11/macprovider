import Foundation
import XCTest
@testable import macprovider_cli
import MacProviderCore

/// Issue #1695: receipt eligibility is explicit. Non-native conformers declare
/// themselves not settlement eligible and mark every completion `.notEligible`;
/// rebuilding a completion never resets its disposition to `.eligibleOwner`.
final class ReceiptEligibilityTests: XCTestCase {
    func testOllamaLoopbackCompletionsAreNotEligibleOnCompleteAndStream() async throws {
        let loopback = try ReceiptEligibilityFixtures.makeOllamaLoopbackRuntime(testCase: self)
        let request = try Self.request(model: ReceiptEligibilityFixtures.ollamaServedRef)
        XCTAssertFalse(loopback.runtime.isSettlementReceiptEligible)

        let completed = try await loopback.runtime.complete(request, shouldCancel: { false })
        XCTAssertEqual(completed.settlementDisposition, .notEligible)

        let handle = try await loopback.runtime.acquireRequestHandle(request)
        let streamed = try await loopback.runtime.stream(request, with: handle, shouldCancel: { false }) { _ in }
        XCTAssertEqual(streamed.settlementDisposition, .notEligible)
    }

    func testRelayBlindFixtureCompletionsAreNotEligibleOnCompleteAndStream() async throws {
        let runtime = ReceiptEligibilityFixtures.makeRelayBlindFixtureRuntime()
        let request = try Self.request(model: ReceiptEligibilityFixtures.fixtureModel)
        XCTAssertFalse(runtime.isSettlementReceiptEligible)

        let completed = try await runtime.complete(request, shouldCancel: { false })
        XCTAssertEqual(completed.settlementDisposition, .notEligible)

        let handle = try await runtime.acquireRequestHandle(request)
        let streamed = try await runtime.stream(request, with: handle, shouldCancel: { false }) { _ in }
        XCTAssertEqual(streamed.settlementDisposition, .notEligible)
    }

    /// The structured-streaming rebuild used to drop the disposition, turning a
    /// continuous-batching replay waiter back into a receipt-eligible owner.
    func testStructuredStreamingValidationPreservesSettlementDisposition() throws {
        let request = try Self.request(
            model: "fixture-model",
            responseFormat: ["type": "json_object"]
        )
        for disposition in [
            ContinuousBatchSettlementDisposition.nonSettlingReplay,
            .notEligible,
            .eligibleOwner,
        ] {
            let completion = CompletionResult(
                content: #"{"ok":true}"#,
                finishReason: "stop",
                promptTokens: 3,
                completionTokens: 4,
                settlementDisposition: disposition
            )
            let validated = try ModelRuntime.validateStructuredStreamingCompletion(
                completion,
                request: request,
                buyerVisibleContent: #"{"ok":true}"#
            )
            XCTAssertEqual(validated.settlementDisposition, disposition)
        }
    }

    func testWithModelHashObservedPreservesSettlementDisposition() {
        let completion = CompletionResult(
            content: "answer",
            finishReason: "stop",
            promptTokens: 1,
            completionTokens: 1,
            settlementDisposition: .nonSettlingReplay
        )
        let observed = completion.withModelHashObservedIfMissing(String(repeating: "b", count: 64))
        XCTAssertEqual(observed.settlementDisposition, .nonSettlingReplay)
    }

    private static func request(
        model: String,
        responseFormat: [String: Any]? = nil
    ) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hello"]],
        ]
        if let responseFormat {
            body["response_format"] = responseFormat
        }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }
}
