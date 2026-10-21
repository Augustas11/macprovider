import MacProviderCore
import XCTest

final class ChatCompletionRequestTests: XCTestCase {
    func testModelMatchIsAsciiCaseInsensitive() throws {
        let request = try makeRequest(model: "mlx-community/llama-3.2-3b-instruct-4bit")

        XCTAssertNoThrow(try request.validateModelMatches("mlx-community/Llama-3.2-3B-Instruct-4bit"))
    }

    func testOmittedParallelToolCallsIsSerial() throws {
        let request = try makeRequest(model: "m")
        XCTAssertNil(request.parallelToolCalls)
        XCTAssertTrue(request.stopsAfterFirstCompleteToolCall)
    }

    func testParallelToolCallsFalseIsSerial() throws {
        let request = try makeRequest(model: "m", extra: ["parallel_tool_calls": false])
        XCTAssertEqual(request.parallelToolCalls, false)
        XCTAssertTrue(request.stopsAfterFirstCompleteToolCall)
    }

    func testParallelToolCallsTrueKeepsMultiCall() throws {
        let request = try makeRequest(model: "m", extra: ["parallel_tool_calls": true])
        XCTAssertEqual(request.parallelToolCalls, true)
        XCTAssertFalse(request.stopsAfterFirstCompleteToolCall)
    }

    func testParallelToolCallsRejectsNonBoolean() {
        XCTAssertAPIError(
            try makeRequest(model: "m", extra: ["parallel_tool_calls": "yes"]),
            status: 400,
            code: "invalid_request"
        )
    }

    func testParallelToolCallsRejectsNull() {
        XCTAssertAPIError(
            try makeRequest(model: "m", extra: ["parallel_tool_calls": NSNull()]),
            status: 400,
            code: "invalid_request"
        )
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

    func testMaxCompletionTokensAliasIsEffectiveMaxTokens() throws {
        let request = try makeRequest(model: "m", extra: ["max_completion_tokens": 64])

        XCTAssertEqual(request.maxTokens, 64)
        XCTAssertTrue(request.topLevelKeys.contains("max_completion_tokens"))
        XCTAssertEqual(request.promptSource.maxTokens, .int(64))
    }

    func testNullMaxTokensFallsBackToMaxCompletionTokensEverywhere() throws {
        let request = try makeRequest(model: "m", extra: [
            "max_tokens": NSNull(),
            "max_completion_tokens": 64,
        ])

        XCTAssertEqual(request.maxTokens, 64)
        XCTAssertEqual(request.promptSource.maxTokens, .int(64))
    }

    func testMatchingMaxTokenAliasesAreAccepted() throws {
        let request = try makeRequest(model: "m", extra: [
            "max_tokens": 64,
            "max_completion_tokens": 64,
        ])

        XCTAssertEqual(request.maxTokens, 64)
    }

    func testConflictingMaxTokenAliasesAreRejected() throws {
        XCTAssertAPIError(
            try makeRequest(model: "m", extra: [
                "max_tokens": 64,
                "max_completion_tokens": 65,
            ]),
            status: 400,
            code: "invalid_request"
        )
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

        var strictNonBool = Self.jsonSchemaObject()
        strictNonBool["strict"] = "no"
        XCTAssertAPIError(try makeRequest(model: "m", responseFormat: ["type": "json_schema", "json_schema": strictNonBool]), status: 400, code: "invalid_request")
    }

    // SPEC-019 v0.3.0 §1a: strict is tri-state; the mode is a pure function
    // of the raw body and mirrors the coordinator's validateResponseFormatSchema.
    func testJsonSchemaStrictModes() throws {
        let subset: [String: Any] = Self.jsonSchemaObject()["schema"] as! [String: Any]
        let openAIShaped: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "nick": ["anyOf": [["type": "string"], ["type": "null"]]],
            ],
            "required": ["name"],
            "$defs": ["x": ["type": "string", "format": "email"]],
        ]
        func request(strict: Any?, schema: Any) throws -> ChatCompletionRequest {
            var spec: [String: Any] = ["name": "person-v1", "schema": schema]
            if let strict { spec["strict"] = strict }
            return try makeRequest(model: "m", responseFormat: ["type": "json_schema", "json_schema": spec])
        }
        func mode(strict: Any?, schema: Any) throws -> Bool {
            let request = try request(strict: strict, schema: schema)
            guard case .jsonSchema(let parsed) = request.responseFormat else {
                XCTFail("expected json_schema")
                return false
            }
            return parsed.strict
        }
        XCTAssertTrue(try mode(strict: true, schema: subset))
        XCTAssertTrue(try mode(strict: nil, schema: subset))
        XCTAssertTrue(try mode(strict: NSNull(), schema: subset))
        XCTAssertFalse(try mode(strict: false, schema: subset))
        XCTAssertFalse(try mode(strict: false, schema: openAIShaped))
        XCTAssertFalse(try mode(strict: nil, schema: openAIShaped))
        XCTAssertAPIError(try request(strict: true, schema: openAIShaped), status: 400, code: "json_schema_unsupported_keyword")
        XCTAssertAPIError(try request(strict: false, schema: [Any]()), status: 400, code: "json_schema_missing_schema")
        XCTAssertAPIError(try request(strict: nil, schema: "x"), status: 400, code: "json_schema_missing_schema")

        func nested(_ depth: Int) -> [String: Any] {
            depth == 1 ? [:] : ["a": nested(depth - 1)]
        }
        XCTAssertFalse(try mode(strict: false, schema: nested(64)))
        XCTAssertAPIError(try request(strict: false, schema: nested(65)), status: 400, code: "json_schema_too_deep")
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

    func testNativeSamplerControlsDefaultAndNullAreIdentityWithoutChangingPromptSource() throws {
        let omitted = try makeRequest(model: "m")
        XCTAssertEqual(omitted.topK, 0)
        XCTAssertEqual(omitted.repetitionPenalty, 1)
        XCTAssertNil(omitted.promptSource.topK)
        XCTAssertNil(omitted.promptSource.repetitionPenalty)

        let null = try makeRequest(model: "m", extra: ["top_k": NSNull(), "repetition_penalty": NSNull()])
        XCTAssertEqual(null.topK, 0)
        XCTAssertEqual(null.repetitionPenalty, 1)
        XCTAssertEqual(null.promptSource.topK, .null)
        XCTAssertEqual(null.promptSource.repetitionPenalty, .null)
        XCTAssertTrue(omitted.allowsSpeculativeDecoding)
        XCTAssertTrue(null.allowsSpeculativeDecoding)
    }

    func testNativeSamplerControlsAcceptBoundsAndPreserveRawValues() throws {
        for topK in [0, 20, Int(Int32.max)] {
            let request = try makeRequest(model: "m", extra: ["top_k": topK, "repetition_penalty": 1.05])
            XCTAssertEqual(request.topK, topK)
            XCTAssertEqual(request.repetitionPenalty, 1.05)
            XCTAssertEqual(request.promptSource.topK, .int(topK))
            XCTAssertEqual(request.promptSource.repetitionPenalty, .double(1.05))
        }
        let integralDouble = try makeRequest(model: "m", extra: ["top_k": 20.0])
        XCTAssertEqual(integralDouble.topK, 20)
        for penalty in [Double(Float.leastNonzeroMagnitude), 0.5, 1.0, Double(Float.greatestFiniteMagnitude)] {
            let request = try makeRequest(model: "m", extra: ["repetition_penalty": penalty])
            XCTAssertEqual(request.repetitionPenalty, penalty)
        }
    }

    func testNativeSamplerControlsRejectInvalidNumericShapes() throws {
        let invalidTopK: [Any] = [true, false, "20", ["value": 20], [20], -1, 0.5, 20.5, Int64(Int32.max) + 1, UInt64.max]
        for value in invalidTopK {
            XCTAssertAPIError(try makeRequest(model: "m", extra: ["top_k": value]), status: 400, code: "invalid_request")
        }
        let invalidPenalty: [Any] = [true, false, "1.05", ["value": 1.05], [1.05], 0, -0.1, 1e-100, 1e100]
        for value in invalidPenalty {
            XCTAssertAPIError(try makeRequest(model: "m", extra: ["repetition_penalty": value]), status: 400, code: "invalid_request")
        }
    }

    func testNativeSamplerControlsRejectNonfiniteJSONNumbers() {
        for field in ["top_k", "repetition_penalty"] {
            for value in ["1e400", "-1e400", "NaN", "Infinity"] {
                let raw = """
                {"model":"m","messages":[{"role":"user","content":"hello"}],"\(field)":\(value)}
                """
                // Invalid JSON may be rejected before the sampling-field gate.
                XCTAssertThrowsError(try ChatCompletionRequest.parse(data: Data(raw.utf8))) { error in
                    XCTAssertEqual((error as? APIError)?.status, 400)
                }
            }
        }
    }

    func testNativeSamplerControlsSurviveEveryRequestReconstruction() throws {
        let original = try makeRequest(model: "m", extra: ["top_k": 20, "repetition_penalty": 1.05])
        let cached = original.withConversationKey("conv:sampling", cacheOnly: true)
        let copies = [
            cached,
            cached.withFleetCacheGrant(nil),
            cached.withRequestID("sampling-request"),
            cached.withMaxTokensLimit(32),
            cached.withIngestProvenance(.privacy),
        ]
        for request in copies {
            XCTAssertEqual(request.topK, 20)
            XCTAssertEqual(request.repetitionPenalty, 1.05)
            XCTAssertEqual(request.promptSource, original.promptSource)
            XCTAssertFalse(request.allowsSpeculativeDecoding)
        }
    }

    func testSpeculativeDecodingGateAllowsExplicitNativeSamplerIdentities() throws {
        let request = try makeRequest(model: "m", extra: ["top_k": 0, "repetition_penalty": 1])
        XCTAssertTrue(request.allowsSpeculativeDecoding)
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
            ("top_k", ["top_k": 20], nil),
            ("repetition_penalty_above_one", ["repetition_penalty": 1.05], nil),
            ("repetition_penalty_below_one", ["repetition_penalty": 0.5], nil),
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
