import MacProviderCore
import XCTest
@testable import macprovider_cli

final class StreamingIdleTimeoutValidatesBufferTests: XCTestCase {
    func testStructuredStreamingIdleTimeoutValidBufferReturnsSuccess() async throws {
        let request = try streamingRequest(responseFormat: integerAgeResponseFormat())
        let accumulator = StructuredStreamingContentAccumulator(enabled: true)
        XCTAssertNil(accumulator.append(#"{"age":37}"#))
        let idleState = StructuredStreamingIdleState(enabled: true)

        let result = try await ModelRuntime.withStructuredStreamingIdleTimeout(
            idleState: idleState,
            timeout: 0.001,
            pollNanoseconds: 1_000_000,
            onIdleTimeout: {
                try Self.validatedBufferResult(accumulator: accumulator, request: request)
            },
            operation: {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return CompletionResult(content: "late", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )

        XCTAssertEqual(result.content, #"{"age":37}"#)
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertEqual(result.promptTokens, 0)
        XCTAssertEqual(result.completionTokens, 0)
    }

    func testStructuredStreamingIdleTimeoutInvalidBufferThrowsProviderTimeout() async throws {
        let request = try streamingRequest(responseFormat: integerAgeResponseFormat())
        let accumulator = StructuredStreamingContentAccumulator(enabled: true)
        XCTAssertNil(accumulator.append(#"{"age":"old"}"#))
        let idleState = StructuredStreamingIdleState(enabled: true)
        let drainToken = DrainCancelToken()

        await XCTAssertStreamingAPIError(
            try await ModelRuntime.withStructuredStreamingIdleTimeout(
                idleState: idleState,
                timeout: 0.001,
                pollNanoseconds: 1_000_000,
                onIdleTimeout: {
                    do {
                        return try Self.validatedBufferResult(accumulator: accumulator, request: request)
                    } catch {
                        throw APIError(
                            status: 504,
                            message: "Provider emitted no buyer-visible structured-output content delta within 60 seconds",
                            type: "upstream_provider_error",
                            code: "provider_timeout",
                            inferenceRan: true,
                            settlementRan: true
                        )
                    }
                },
                operation: {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    return CompletionResult(content: "late", finishReason: "stop", promptTokens: 1, completionTokens: 1)
                }
            ),
            status: 504,
            code: "provider_timeout",
            retryable: false
        )
        XCTAssertFalse(drainToken.isFired)
    }

    private static func validatedBufferResult(
        accumulator: StructuredStreamingContentAccumulator,
        request: ChatCompletionRequest
    ) throws -> CompletionResult {
        let content = accumulator.content
        return try ModelRuntime.validateStructuredStreamingCompletion(
            CompletionResult(
                content: content,
                finishReason: "stop",
                promptTokens: 0,
                completionTokens: 0,
                ttftMilliseconds: 0
            ),
            request: request,
            buyerVisibleContent: content
        )
    }
}
