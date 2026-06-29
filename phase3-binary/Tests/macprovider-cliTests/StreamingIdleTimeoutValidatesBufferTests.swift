import MacProviderCore
import XCTest
@testable import macprovider_cli

final class StreamingIdleTimeoutValidatesBufferTests: XCTestCase {
    func testIdleBreachValidatesBufferAndReturnsSuccessWhenValid() throws {
        let request = try streamingRequest(responseFormat: integerAgeResponseFormat())
        let accumulator = StructuredStreamingContentAccumulator(enabled: true)
        XCTAssertNil(accumulator.append(#"{"age":37}"#))

        let result = try ModelRuntime.synthesizeIdleTimeoutResultOrThrow(
            accumulator: accumulator,
            request: request
        )

        XCTAssertEqual(result.content, #"{"age":37}"#)
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertEqual(result.promptTokens, 0)
        XCTAssertEqual(result.completionTokens, 0)
    }

    func testIdleBreachValidatesBufferAndThrowsWhenInvalid() throws {
        let request = try streamingRequest(responseFormat: integerAgeResponseFormat())
        let accumulator = StructuredStreamingContentAccumulator(enabled: true)
        XCTAssertNil(accumulator.append(#"{"age":"old"}"#))

        XCTAssertThrowsError(try ModelRuntime.synthesizeIdleTimeoutResultOrThrow(
            accumulator: accumulator,
            request: request
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 504)
            XCTAssertEqual(apiError?.code, "provider_timeout")
            let envelope = apiError?.envelope["error"] as? [String: Any]
            XCTAssertEqual(envelope?["retryable"] as? Bool, false)
        }
    }

    func testIdleBreachReadsBufferAfterOperationStopped() async throws {
        let request = try streamingRequest(responseFormat: integerAgeResponseFormat())
        let accumulator = StructuredStreamingContentAccumulator(enabled: true)
        let idleState = StructuredStreamingIdleState(enabled: true)

        let result = try await ModelRuntime.withStructuredStreamingIdleTimeout(
            idleState: idleState,
            timeout: 0.005,
            pollNanoseconds: 1_000_000,
            onIdleTimeout: {
                try ModelRuntime.synthesizeIdleTimeoutResultOrThrow(
                    accumulator: accumulator,
                    request: request
                )
            },
            operation: { idleCancellation in
                for delta in [#"{"#, #""age""#, #":37}"#] {
                    XCTAssertNil(accumulator.append(delta))
                    idleState.noteContent()
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                while !idleCancellation.isFired {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                try await Task.sleep(nanoseconds: 20_000_000)
                if !idleCancellation.isFired {
                    XCTAssertNil(accumulator.append(#"{"age":38}"#))
                    idleState.noteContent()
                }
                return CompletionResult(content: "late", finishReason: "stop", promptTokens: 1, completionTokens: 1)
            }
        )

        XCTAssertEqual(result.content, #"{"age":37}"#)
        XCTAssertEqual(accumulator.content, #"{"age":37}"#)
    }

    func testStructuredStreamingIdleTimeoutInvalidBufferDoesNotFireDrainToken() async throws {
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
                    try ModelRuntime.synthesizeIdleTimeoutResultOrThrow(
                        accumulator: accumulator,
                        request: request
                    )
                },
                operation: { _ in
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
}
