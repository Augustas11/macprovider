import XCTest
@testable import malibu_cli

final class StreamingByteCapTests: XCTestCase {
    func testStructuredStreamingValidationBufferCapBoundaryIsAccepted() async throws {
        let prefix = "{\"x\":\""
        let suffix = "\"}"
        let overhead = prefix.utf8.count + suffix.utf8.count
        let exact = prefix + String(repeating: "x", count: ModelRuntime.structuredStreamingValidationBufferByteCap - overhead) + suffix
        XCTAssertEqual(exact.utf8.count, ModelRuntime.structuredStreamingValidationBufferByteCap)
        let runtime = streamingRuntimeReturning(exact)
        let request = try streamingRequest(responseFormat: ["type": "json_object"])
        let handle = try await runtime.acquireRequestHandle(request)

        let completion = try await runtime.stream(request, with: handle) { _ in }
        XCTAssertEqual(completion.content, exact)
    }

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
