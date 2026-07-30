import MacProviderCore
import XCTest
@testable import macprovider_cli

final class InferenceRelayStructuredOutputTests: XCTestCase {
    func testInferenceRelayPreservesMalformedJsonResponseStatusOverWS() throws {
        try assertStructuredOutputStatusPreserved("malformed_json_response", retryable: true)
    }

    func testInferenceRelayPreservesJsonSchemaValidationFailedStatusOverWS() throws {
        try assertStructuredOutputStatusPreserved("json_schema_validation_failed", retryable: true)
    }

    func testInferenceRelayPreservesResponseByteCapExceededStatusOverWS() throws {
        try assertStructuredOutputStatusPreserved("response_byte_cap_exceeded", retryable: false)
    }

    func testInferenceRelayPreservesProviderTimeoutStatusOverWS() throws {
        try assertStructuredOutputStatusPreserved("provider_timeout", retryable: false)
    }

    private func assertStructuredOutputStatusPreserved(_ code: String, retryable: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let error = APIError(
            status: code == "provider_timeout" ? 504 : 502,
            message: "structured output failed",
            type: "upstream_provider_error",
            code: code,
            inferenceRan: true,
            settlementRan: true
        )
        let frame = InferenceRelay.errorEndFrame(requestID: "req-1", error: error, chunksSent: 0)

        XCTAssertEqual(frame["status"] as? String, code, file: file, line: line)
        XCTAssertEqual(frame["retryable"] as? Bool, retryable, file: file, line: line)

        let data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["status"] as? String, code, file: file, line: line)
        XCTAssertEqual(decoded?["retryable"] as? Bool, retryable, file: file, line: line)
    }
}
