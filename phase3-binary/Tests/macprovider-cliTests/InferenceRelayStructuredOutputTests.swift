import MacProviderCore
import XCTest
@testable import macprovider_cli

final class InferenceRelayStructuredOutputTests: XCTestCase {
    func testStructuredOutputErrorCodesPreservedInEndFrame() throws {
        let cases: [(code: String, retryable: Bool)] = [
            ("malformed_json_response", false),
            ("json_schema_validation_failed", true),
        ]

        for tc in cases {
            let error = APIError(
                status: 502,
                message: "structured output failed",
                type: "upstream_provider_error",
                code: tc.code,
                retryable: tc.retryable,
                inferenceRan: true,
                settlementRan: true
            )
            let frame = InferenceRelay.errorEndFrame(requestID: "req-1", error: error, chunksSent: 0)

            XCTAssertEqual(frame["status"] as? String, tc.code)
            XCTAssertEqual(frame["retryable"] as? Bool, tc.retryable)

            let data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(decoded?["status"] as? String, tc.code)
            XCTAssertEqual(decoded?["retryable"] as? Bool, tc.retryable)
        }
    }
}
