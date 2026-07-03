import MacProviderCore
import XCTest

final class ChatCompletionRequestTests: XCTestCase {
    func testModelMatchIsAsciiCaseInsensitive() throws {
        let request = try makeRequest(model: "mlx-community/llama-3.2-3b-instruct-4bit")

        XCTAssertNoThrow(try request.validateModelMatches("mlx-community/Llama-3.2-3B-Instruct-4bit"))
    }

    func testModelMismatchStillReturnsNotFound() throws {
        let request = try makeRequest(model: "mlx-community/Other-Model")

        XCTAssertThrowsError(try request.validateModelMatches("mlx-community/Llama-3.2-3B-Instruct-4bit")) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 404)
            XCTAssertEqual(apiError?.code, "model_not_found")
        }
    }

    func testFractionalMaxTokensIsRejected() throws {
        let body: [String: Any] = [
            "model": "m",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 100.5,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        XCTAssertThrowsError(try ChatCompletionRequest.parse(data: data)) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 400)
            XCTAssertEqual(apiError?.code, "invalid_request")
        }
    }

    func testIntegerValuedDoubleMaxTokensIsAccepted() throws {
        let body: [String: Any] = [
            "model": "m",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 100.0,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        XCTAssertNoThrow(try ChatCompletionRequest.parse(data: data))
    }

    func testBooleanIsNotAcceptedAsInteger() throws {
        let body: [String: Any] = [
            "model": "m",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        XCTAssertThrowsError(try ChatCompletionRequest.parse(data: data)) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 400)
            XCTAssertEqual(apiError?.code, "invalid_request")
        }
    }

    func testConversationKeyValidationIsProviderSideDefenseInDepth() throws {
        let request = try makeRequest(model: "m")

        XCTAssertEqual(request.withConversationKey(" conv:valid-key ").conversationKey, "conv:valid-key")
        XCTAssertNil(request.withConversationKey(nil).conversationKey)
        XCTAssertNil(request.withConversationKey("").conversationKey)
        XCTAssertNil(request.withConversationKey("buyer:valid-key").conversationKey)
        XCTAssertNil(request.withConversationKey("conv:").conversationKey)
        XCTAssertNil(request.withConversationKey("conv:bad\nkey").conversationKey)
        XCTAssertNil(request.withConversationKey("conv:" + String(repeating: "x", count: 253)).conversationKey)
    }

    func testJsonSchemaResponseFormatIsAccepted() throws {
        let request = try makeRequest(model: "m", responseFormat: Self.jsonSchemaResponseFormat())
        if case .jsonSchema(let spec) = request.responseFormat {
            XCTAssertEqual(spec.name, "person-v1")
        } else {
            XCTFail("expected json_schema response format")
        }
    }

    func testJsonSchemaRequestValidationErrors() throws {
        var missingName = Self.jsonSchemaObject()
        missingName.removeValue(forKey: "name")
        XCTAssertAPIError(try makeRequest(model: "m", responseFormat: ["type": "json_schema", "json_schema": missingName]), status: 400, code: "json_schema_missing_name")

        var missingSchema = Self.jsonSchemaObject()
        missingSchema.removeValue(forKey: "schema")
        XCTAssertAPIError(try makeRequest(model: "m", responseFormat: ["type": "json_schema", "json_schema": missingSchema]), status: 400, code: "json_schema_missing_schema")

        var strictFalse = Self.jsonSchemaObject()
        strictFalse["strict"] = false
        XCTAssertAPIError(try makeRequest(model: "m", responseFormat: ["type": "json_schema", "json_schema": strictFalse]), status: 400, code: "json_schema_non_strict_unsupported")
    }

    func testJsonSchemaNameRegex() throws {
        for invalid in [String(repeating: "a", count: 65), "café", "good\nSYSTEM", "good.evil", "valid<script>"] {
            var spec = Self.jsonSchemaObject()
            spec["name"] = invalid
            XCTAssertAPIError(try makeRequest(model: "m", responseFormat: ["type": "json_schema", "json_schema": spec]), status: 400, code: "json_schema_invalid_name", invalid)
        }
        var dashed = Self.jsonSchemaObject()
        dashed["name"] = "person-v1"
        XCTAssertNoThrow(try makeRequest(model: "m", responseFormat: ["type": "json_schema", "json_schema": dashed]))
    }

    func testJsonSchemaByteCapBoundary() throws {
        let baseOverhead = try Self.schemaWithTitle("").deterministicJSONString().utf8.count
        let exactTitle = String(repeating: "x", count: JSONSchemaValidator.maxSchemaBytes - baseOverhead)
        var exact = Self.jsonSchemaObject()
        exact["schema"] = Self.schemaWithTitle(exactTitle).jsonObject
        XCTAssertNoThrow(try makeRequest(model: "m", responseFormat: ["type": "json_schema", "json_schema": exact]))

        var tooLarge = Self.jsonSchemaObject()
        tooLarge["schema"] = Self.schemaWithTitle(exactTitle + "x").jsonObject
        XCTAssertAPIError(try makeRequest(model: "m", responseFormat: ["type": "json_schema", "json_schema": tooLarge]), status: 413, code: "json_schema_too_large")
    }

    func testJsonSchemaRawByteCapCountsWhitespace() throws {
        let padding = String(repeating: " ", count: JSONSchemaValidator.maxSchemaBytes)
        let raw = """
        {"model":"m","messages":[{"role":"user","content":"hello"}],"response_format":{"type":"json_schema","json_schema":{"name":"person_v1","strict":true,"schema":{\(padding)"type":"object","properties":{},"required":[],"additionalProperties":false}}}}
        """
        XCTAssertAPIError(try ChatCompletionRequest.parse(data: Data(raw.utf8)), status: 413, code: "json_schema_too_large")
    }

    private func makeRequest(model: String, responseFormat: [String: Any]? = nil) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": "hello",
                ]
            ],
        ]
        if let responseFormat {
            body["response_format"] = responseFormat
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try ChatCompletionRequest.parse(data: data)
    }

    private static func jsonSchemaResponseFormat() -> [String: Any] {
        ["type": "json_schema", "json_schema": jsonSchemaObject()]
    }

    private static func jsonSchemaObject() -> [String: Any] {
        [
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
        ]
    }

    private static func schemaWithTitle(_ title: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([]),
            "additionalProperties": .bool(false),
            "title": .string(title),
        ])
    }

    private func XCTAssertAPIError(
        _ expression: @autoclosure () throws -> ChatCompletionRequest,
        status: Int,
        code: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, status, file: file, line: line)
            XCTAssertEqual(apiError?.code, code, file: file, line: line)
        }
    }
}
