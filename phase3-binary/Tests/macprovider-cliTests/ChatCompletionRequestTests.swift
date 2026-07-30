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

    // Default aliases: [] preserves prior behavior — a non-matching model still 404s.
    func testDefaultEmptyAliasesStillReturnsNotFound() throws {
        let request = try makeRequest(model: "mlx-community/Other-Model")

        XCTAssertThrowsError(try request.validateModelMatches("qwen3-coder-30b-a3b-instruct", aliases: [])) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 404)
            XCTAssertEqual(apiError?.code, "model_not_found")
        }
    }

    // Request model equals the loaded id → passes even with aliases present.
    func testLoadedIDMatchWithAliasesPresent() throws {
        let request = try makeRequest(model: "qwen3-coder-30b-a3b-instruct")

        XCTAssertNoThrow(try request.validateModelMatches(
            "qwen3-coder-30b-a3b-instruct",
            aliases: ["mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"]
        ))
    }

    // Request model equals an alias entry (ascii case-insensitive) → passes.
    func testAliasMatchIsAsciiCaseInsensitive() throws {
        let request = try makeRequest(model: "MLX-COMMUNITY/qwen3-coder-30b-a3b-instruct-4bit")

        XCTAssertNoThrow(try request.validateModelMatches(
            "qwen3-coder-30b-a3b-instruct",
            aliases: ["mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"]
        ))
    }

    // Request model matches neither the loaded id nor any alias → 404.
    func testNeitherLoadedNorAliasReturnsNotFound() throws {
        let request = try makeRequest(model: "some-other-model")

        XCTAssertThrowsError(try request.validateModelMatches(
            "qwen3-coder-30b-a3b-instruct",
            aliases: ["mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"]
        )) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 404)
            XCTAssertEqual(apiError?.code, "model_not_found")
        }
    }

    // Empty-string alias entries must never match (no accidental match on "").
    // The request model is non-empty (parse rejects ""), and an all-empty alias
    // list must be treated as no alias at all → 404.
    func testEmptyStringAliasEntryIsIgnored() throws {
        let request = try makeRequest(model: "unrelated-model")

        XCTAssertThrowsError(try request.validateModelMatches(
            "qwen3-coder-30b-a3b-instruct",
            aliases: [""]
        )) { error in
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

    func testSpeculativeDecodingGateAllowsGreedyTextOnlyRequests() throws {
        let request = try makeRequest(
            model: "m",
            extra: [
                "temperature": 0,
                "top_p": 1.0,
                "presence_penalty": 0,
                "frequency_penalty": 0,
                "response_format": ["type": "text"],
                "tools": [],
                "logprobs": false,
            ]
        )

        XCTAssertTrue(request.allowsSpeculativeDecoding)
    }

    func testSpeculativeDecodingGateRejectsStochasticAndFeaturefulRequests() throws {
        let validTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "lookup",
                "parameters": ["type": "object", "properties": [:] as [String: Any]],
            ],
        ]
        let assistantWithToolCall: [[String: Any]] = [
            ["role": "user", "content": "hello"],
            [
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": [[
                    "id": "call_1234567890abcdef",
                    "type": "function",
                    "function": ["name": "lookup", "arguments": "{}"],
                ]],
            ],
        ]
        let toolResultMessages: [[String: Any]] = assistantWithToolCall + [
            ["role": "tool", "tool_call_id": "call_1234567890abcdef", "content": "ok"],
        ]

        let rejected: [(String, [String: Any], [[String: Any]]?)] = [
            ("temperature", ["temperature": 0.1], nil),
            ("top_p", ["top_p": 0.9], nil),
            ("tools", ["tools": [validTool]], nil),
            ("tool_choice_auto", ["tool_choice": "auto"], nil),
            ("assistant_tool_calls", [:], assistantWithToolCall),
            ("tool_role", [:], toolResultMessages),
            ("json_object", ["response_format": ["type": "json_object"]], nil),
            ("logprobs", ["logprobs": true], nil),
            ("top_logprobs", ["top_logprobs": 1], nil),
            ("logit_bias", ["logit_bias": ["42": -1]], nil),
            ("presence_penalty", ["presence_penalty": 0.2], nil),
            ("frequency_penalty", ["frequency_penalty": 0.2], nil),
            ("stop", ["stop": ["END"]], nil),
        ]

        for (name, extra, messages) in rejected {
            var request = try makeRequest(model: "m", messages: messages, extra: extra)
            if name == "temperature" {
                XCTAssertEqual(request.temperature, 0.1)
            }
            XCTAssertFalse(request.allowsSpeculativeDecoding, name)
            request = request.withConversationKey("conv:\(name)")
            XCTAssertFalse(request.allowsSpeculativeDecoding, "\(name) with conversation cache")
        }

        let cached = try makeRequest(model: "m").withConversationKey("conv:cached")
        XCTAssertFalse(cached.allowsSpeculativeDecoding)
    }

    private func makeRequest(
        model: String,
        messages: [[String: Any]]? = nil,
        responseFormat: [String: Any]? = nil,
        extra: [String: Any] = [:]
    ) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": messages ?? [
                [
                    "role": "user",
                    "content": "hello",
                ]
            ],
            "temperature": 0,
            "top_p": 1.0,
        ]
        if let responseFormat {
            body["response_format"] = responseFormat
        }
        for (key, value) in extra {
            body[key] = value
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
