import MacProviderCore
import XCTest
@testable import macprovider_cli

final class ModelRuntimeStructuredOutputTests: XCTestCase {
    func testJsonSchemaValidOutputReturnsOriginalJSONString() async throws {
        let runtime = Self.runtimeReturning(CompletionResult(content: #"{"name":"Ada","age":37}"#, finishReason: "stop", promptTokens: 1, completionTokens: 2))
        let result = try await runtime.complete(Self.request(responseFormat: Self.jsonSchemaResponseFormat()))

        XCTAssertEqual(result.content, #"{"name":"Ada","age":37}"#)
    }

    func testMalformedJsonResponseIs502RetryableAfterInference() async throws {
        let runtime = Self.runtimeReturning(CompletionResult(content: "not json", finishReason: "stop", promptTokens: 1, completionTokens: 2))

        await XCTAssertAsyncAPIError(
            try await runtime.complete(Self.request(responseFormat: Self.jsonSchemaResponseFormat())),
            status: 502,
            code: "malformed_json_response",
            retryable: true
        )
    }

    func testEmptyStructuredOutputIsNotRetryable() async throws {
        let runtime = Self.runtimeReturning(CompletionResult(content: "", finishReason: "stop", promptTokens: 1, completionTokens: 0))

        await XCTAssertAsyncAPIError(
            try await runtime.complete(Self.request(responseFormat: Self.jsonSchemaResponseFormat())),
            status: 502,
            code: "malformed_json_response",
            retryable: false
        )
    }

    func testJsonSchemaValidationFailureReportsPointer() async throws {
        let runtime = Self.runtimeReturning(CompletionResult(content: #"{"name":"Ada","age":"old"}"#, finishReason: "stop", promptTokens: 1, completionTokens: 2))

        await XCTAssertAsyncAPIError(
            try await runtime.complete(Self.request(responseFormat: Self.jsonSchemaResponseFormat())),
            status: 502,
            code: "json_schema_validation_failed",
            retryable: true,
            param: "/age"
        )
    }

    func testJsonObjectRequiresObjectOrArray() async throws {
        let runtime = Self.runtimeReturning(CompletionResult(content: #""scalar""#, finishReason: "stop", promptTokens: 1, completionTokens: 1))

        await XCTAssertAsyncAPIError(
            try await runtime.complete(Self.request(responseFormat: ["type": "json_object"])),
            status: 502,
            code: "malformed_json_response",
            retryable: true
        )
    }

    func testToolCallsSkipSchemaValidation() async throws {
        let runtime = Self.runtimeReturning(CompletionResult(
            content: "",
            finishReason: "tool_calls",
            promptTokens: 1,
            completionTokens: 2,
            toolCalls: [ToolCall(id: "call_0123456789abcdef", functionName: "lookup", arguments: #"{"id":"1"}"#)]
        ))
        let result = try await runtime.complete(Self.request(responseFormat: Self.jsonSchemaResponseFormat()))

        XCTAssertEqual(result.toolCalls?.first?.functionName, "lookup")
    }

    private static func runtimeReturning(_ completion: CompletionResult) -> ModelRuntime {
        ModelRuntime(
            modelID: "fixture-model",
            warmSwapEnabled: false,
            loader: { _ in throw TestError.unexpectedLoad },
            testCompletion: { _, _ in completion }
        )
    }

    private static func request(responseFormat: [String: Any]) throws -> ChatCompletionRequest {
        let body: [String: Any] = [
            "model": "fixture-model",
            "messages": [["role": "user", "content": "Return a person"]],
            "response_format": responseFormat,
        ]
        return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
    }

    private static func jsonSchemaResponseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "json_schema": [
                "name": "person-v1",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "age": ["type": "number"],
                    ],
                    "required": ["name", "age"],
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    private enum TestError: Error {
        case unexpectedLoad
    }

    private func XCTAssertAsyncAPIError(
        _ expression: @autoclosure () async throws -> CompletionResult,
        status: Int,
        code: String,
        retryable: Bool,
        param: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected APIError", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error.status, status, file: file, line: line)
            XCTAssertEqual(error.code, code, file: file, line: line)
            XCTAssertEqual(error.inferenceRan, true, file: file, line: line)
            XCTAssertEqual(error.settlementRan, true, file: file, line: line)
            let envelope = error.envelope["error"] as? [String: Any]
            XCTAssertEqual(envelope?["retryable"] as? Bool, retryable, file: file, line: line)
            if let param {
                XCTAssertEqual(error.param, param, file: file, line: line)
            }
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
