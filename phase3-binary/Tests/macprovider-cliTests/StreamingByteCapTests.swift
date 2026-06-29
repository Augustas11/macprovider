import XCTest
@testable import macprovider_cli

final class StreamingByteCapTests: XCTestCase {
    func testStructuredStreamingValidationBufferCapIsEnforced() async throws {
        let oversized = String(repeating: "x", count: ModelRuntime.structuredStreamingValidationBufferByteCap + 1)
        let runtime = streamingRuntimeReturning(oversized)
        let request = try streamingRequest(responseFormat: ["type": "json_object"])
        let handle = try await runtime.acquireRequestHandle(request)

        await XCTAssertStreamingAPIError(
            try await runtime.stream(request, with: handle) { _ in },
            status: 502,
            code: "response_byte_cap_exceeded",
            retryable: false
        )
    }
}
