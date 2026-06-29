import MacProviderCore
import XCTest
@testable import macprovider_cli

final class StreamingValidationFailureTests: XCTestCase {
    func testTerminalSchemaFailureUsesBuyerVisibleStreamingContent() async throws {
        let runtime = streamingRuntimeReturning(#"{"age":"old"}"#)
        let request = try streamingRequest(responseFormat: integerAgeResponseFormat())
        let handle = try await runtime.acquireRequestHandle(request)

        await XCTAssertStreamingAPIError(
            try await runtime.stream(request, with: handle) { _ in },
            status: 502,
            code: "json_schema_validation_failed",
            retryable: true,
            param: "/age"
        )
    }
}

func streamingRuntimeReturning(_ content: String) -> ModelRuntime {
    ModelRuntime(
        modelID: "fixture-model",
        warmSwapEnabled: false,
        loader: { _ in throw StreamingRuntimeTestError.unexpectedLoad },
        testCompletion: { _, _ in
            CompletionResult(content: content, finishReason: "stop", promptTokens: 1, completionTokens: 1)
        }
    )
}

func streamingRequest(responseFormat: [String: Any]) throws -> ChatCompletionRequest {
    let body: [String: Any] = [
        "model": "fixture-model",
        "messages": [["role": "user", "content": "Return JSON"]],
        "stream": true,
        "response_format": responseFormat,
    ]
    return try ChatCompletionRequest.parse(data: try JSONSerialization.data(withJSONObject: body))
}

func integerAgeResponseFormat() -> [String: Any] {
    [
        "type": "json_schema",
        "json_schema": [
            "name": "age-v1",
            "strict": true,
            "schema": [
                "type": "object",
                "properties": [
                    "age": ["type": "integer"],
                ],
                "required": ["age"],
                "additionalProperties": false,
            ],
        ],
    ]
}

enum StreamingRuntimeTestError: Error {
    case unexpectedLoad
}

func XCTAssertStreamingAPIError(
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
        XCTFail("expected APIError, got \(error)", file: file, line: line)
    }
}
