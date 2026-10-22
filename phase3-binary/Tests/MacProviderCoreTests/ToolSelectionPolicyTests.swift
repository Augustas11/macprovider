import Foundation
import MacProviderCore
import XCTest

final class ToolSelectionPolicyTests: XCTestCase {
    static func request(choice: Any = "required", parallel: Bool = false, schema: [String: Any]? = nil, extra: [String: Any] = [:]) throws -> ChatCompletionRequest {
        var body: [String: Any] = [
            "model": ToolSelectionPolicy.supportedNativeModel,
            "messages": [["role": "user", "content": "Look up 3"]],
            "tool_choice": choice,
            "parallel_tool_calls": parallel,
            "max_tokens": 100,
            "tools": [["type": "function", "function": ["name": "lookup", "parameters": schema ?? [
                "type": "object", "properties": ["id": ["type": "integer", "minimum": 1]],
                "required": ["id"], "additionalProperties": false,
            ]]]],
        ]
        body.merge(extra) { _, new in new }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    static func call(_ name: String = "lookup", arguments: String = #"{"id":3}"#, id: String = "call_0123456789abcdef") -> ToolCall {
        ToolCall(id: id, functionName: name, arguments: arguments)
    }

    func testExactModelAndRuntimeCapabilities() throws {
        let request = try Self.request()
        XCTAssertNoThrow(try ToolSelectionPolicy.validateRequest(request, loadedModelID: ToolSelectionPolicy.supportedNativeModel, runtime: "mlx_cache"))
        for model in ["other/Qwen3.6-35B-A3B-4bit", "mlx-community/Qwen3-8B-4bit", "mlx-community/gpt-oss-20b", "mlx-community/Llama-3.3-70B"] {
            XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(request, loadedModelID: model, runtime: "mlx_cache"))
        }
        for runtime in ["llama_cpp_loopback", "ollama_loopback", "mlxlm_loopback", "omlx_loopback", "lmstudio_loopback"] {
            XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(request, loadedModelID: ToolSelectionPolicy.supportedNativeModel, runtime: runtime))
        }
        XCTAssertEqual(ToolSelectionPolicy.modes(modelID: "unknown", runtime: "mlx_cache"), ["auto", "none"])
    }

    func testRequiredNeverSucceedsWithProseAndChecksArguments() throws {
        let request = try Self.request()
        for arguments in [#"{"id":"wrong"}"#, #"{"id":0}"#, #"{"id":3,"extra":true}"#, "{}", "[]", #"{"id":3"#, #"{"id":3,"id":4}"#] {
            XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [Self.call(arguments: arguments)], finishReason: "tool_calls", generatedTokens: 9, request: request))
        }
        XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [], finishReason: "stop", generatedTokens: 9, request: request))
        XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [Self.call("other")], finishReason: "tool_calls", generatedTokens: 9, request: request))
        XCTAssertNoThrow(try ToolSelectionPolicy.validateOutput(calls: [Self.call()], finishReason: "tool_calls", generatedTokens: 9, request: request))
    }

    func testAdditionalProfilesRequireExactLoadedIdentityAndRetainRequestBounds() throws {
        let models = [
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
        ]
        for model in models {
            for choice in ["required", ["type": "function", "function": ["name": "lookup"]]] as [Any] {
                let request = try Self.request(choice: choice, extra: ["model": "buyer/alias"])
                XCTAssertNoThrow(try ToolSelectionPolicy.validateRequest(request, loadedModelID: model, runtime: "mlx_cache"))
                XCTAssertEqual(ToolSelectionPolicy.modes(modelID: model, runtime: "mlx_cache"), ["auto", "none", "required", "named"])
                for alias in [model.lowercased(), model + "-copy", model.replacingOccurrences(of: "4bit", with: "8bit"),
                              String(model.split(separator: "/").last!), "local/" + model, "buyer/alias"] {
                    XCTAssertNil(ToolSelectionPolicy.guaranteedCallProfile(modelID: alias))
                    XCTAssertEqual(ToolSelectionPolicy.modes(modelID: alias, runtime: "mlx_cache"), ["auto", "none"])
                    XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(request, loadedModelID: alias, runtime: "mlx_cache"))
                }
                XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(request, loadedModelID: model, runtime: "ollama_loopback"))
                for extra: [String: Any] in [["max_tokens": NSNull()], ["max_tokens": 16_385], ["stop": ["cut"]]] {
                    XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(Self.request(choice: choice, extra: extra), loadedModelID: model, runtime: "mlx_cache"))
                }
            }
        }
    }

    func testNamedUnavailableAndWrongName() throws {
        let named: [String: Any] = ["type": "function", "function": ["name": "lookup"]]
        let request = try Self.request(choice: named)
        XCTAssertNoThrow(try ToolSelectionPolicy.validateOutput(calls: [Self.call()], finishReason: "tool_calls", generatedTokens: 9, request: request))
        XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [Self.call("other")], finishReason: "tool_calls", generatedTokens: 9, request: request))
        let unavailable = try Self.request(choice: ["type": "function", "function": ["name": "absent"]])
        XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(unavailable, loadedModelID: ToolSelectionPolicy.supportedNativeModel, runtime: "mlx_cache"))
    }

    func testNoneAndAuto() throws {
        let none = try Self.request(choice: "none")
        XCTAssertNoThrow(try ToolSelectionPolicy.validateRequest(none, loadedModelID: "unknown", runtime: "mlx_cache"))
        XCTAssertNoThrow(try ToolSelectionPolicy.validateOutput(calls: [], finishReason: "stop", generatedTokens: 9, request: none))
        XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [Self.call()], finishReason: "tool_calls", generatedTokens: 9, request: none))
        XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(none, loadedModelID: "unknown", runtime: "ollama_loopback"))
        let auto = try Self.request(choice: "auto")
        XCTAssertNoThrow(try ToolSelectionPolicy.validateOutput(calls: [], finishReason: "length", generatedTokens: 100, request: auto))
    }

    func testCardinalityExhaustionAndDuplicateIDs() throws {
        let serial = try Self.request()
        let calls = [Self.call(), Self.call(id: "call_fedcba9876543210")]
        XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: calls, finishReason: "tool_calls", generatedTokens: 9, request: serial))
        let parallel = try Self.request(parallel: true)
        XCTAssertNoThrow(try ToolSelectionPolicy.validateOutput(calls: calls, finishReason: "tool_calls", generatedTokens: 9, request: parallel))
        XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [Self.call(), Self.call()], finishReason: "tool_calls", generatedTokens: 9, request: parallel))
        XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [Self.call()], finishReason: "length", generatedTokens: 9, request: serial))
        XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [Self.call()], finishReason: "tool_calls", generatedTokens: 100, request: serial))
    }

    func testMalformedAndUnsupportedSchemaRejectedBeforeInference() throws {
        // A schema nested past JSONSchemaValidator.maxDepth containers never
        // reaches the policy: the request parser bounds every tool first.
        var deep: [String: Any] = ["type": "string"]
        for _ in 0..<17 { deep = ["type": "object", "properties": ["x": deep]] }
        XCTAssertThrowsError(try Self.request(schema: deep)) { error in
            XCTAssertEqual((error as? APIError)?.code, "invalid_tools")
        }
        for schema: [String: Any] in [
            ["type": "array", "items": ["type": "string"]],
            ["properties": ["x": ["type": "string"]]],
        ] {
            let request = try Self.request(schema: schema)
            XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(request, loadedModelID: ToolSelectionPolicy.supportedNativeModel, runtime: "mlx_cache")) { error in
                XCTAssertEqual((error as? APIError)?.code, "unsupported_tool_schema")
                XCTAssertEqual((error as? APIError)?.inferenceRan, false)
            }
        }
        for extra: [String: Any] in [["stop": ["cut"]], ["response_format": ["type": "json_object"]]] {
            let request = try Self.request(extra: extra)
            XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(request, loadedModelID: ToolSelectionPolicy.supportedNativeModel, runtime: "mlx_cache"))
        }
    }
    func testExplicitSelectionRejectsDuplicateSchemaAndArgumentBounds() throws {
        let raw = #"{"model":"mlx-community/Qwen3.6-35B-A3B-4bit","messages":[{"role":"user","content":"go"}],"tool_choice":"required","tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","additionalProperties":false,"additionalProperties":true}}}]}"#
        XCTAssertThrowsError(try ChatCompletionRequest.parse(data: Data(raw.utf8))) { error in
            XCTAssertEqual((error as? APIError)?.code, "invalid_json")
            XCTAssertEqual((error as? APIError)?.inferenceRan, false)
        }
        let request = try Self.request()
        let overLimit = Self.call(arguments: String(repeating: " ", count: ToolSelectionPolicy.maxArgumentBytes + 1))
        XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [overLimit], finishReason: "tool_calls", generatedTokens: 9, request: request))
    }

    func testExplicitTokenBudgetIsRequiredAndBoundedWithoutMutation() throws {
        for extra: [String: Any] in [["max_tokens": NSNull()], ["max_tokens": 16_385]] {
            let request = try Self.request(extra: extra)
            XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(request, loadedModelID: ToolSelectionPolicy.supportedNativeModel, runtime: "mlx_cache")) { error in
                XCTAssertEqual((error as? APIError)?.code, "unsupported_tool_choice")
                XCTAssertEqual((error as? APIError)?.inferenceRan, false)
            }
        }
        let alias = try Self.request(extra: ["max_tokens": NSNull(), "max_completion_tokens": 16_384])
        XCTAssertEqual(alias.maxTokens, 16_384)
        XCTAssertNoThrow(try ToolSelectionPolicy.validateRequest(alias, loadedModelID: ToolSelectionPolicy.supportedNativeModel, runtime: "mlx_cache"))
    }

    func testUnsafeNumericSchemaAndArgumentsCannotFalseSucceed() throws {
        for keyword in ["minimum", "maximum", "multipleOf", "const"] {
            let request = try Self.request(schema: [
                "type": "object", "properties": ["id": ["type": "integer", keyword: 9_007_199_254_740_993]],
                "required": ["id"], "additionalProperties": false,
            ])
            XCTAssertThrowsError(try ToolSelectionPolicy.validateRequest(request, loadedModelID: ToolSelectionPolicy.supportedNativeModel, runtime: "mlx_cache")) { error in
                XCTAssertEqual((error as? APIError)?.code, "unsupported_tool_schema")
                XCTAssertEqual((error as? APIError)?.inferenceRan, false)
            }
        }
        let request = try Self.request(schema: [
            "type": "object", "properties": ["id": ["type": "integer", "maximum": ToolSelectionPolicy.maxSafeNumericMagnitude]],
            "required": ["id"], "additionalProperties": false,
        ])
        for arguments in [#"{"id":9007199254740992}"#, #"{"id":9007199254740993}"#, #"{"id":-9223372036854775808}"#] {
            XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [Self.call(arguments: arguments)], finishReason: "tool_calls", generatedTokens: 9, request: request)) { error in
                XCTAssertEqual((error as? APIError)?.code, "tool_selection_validation_failed")
            }
        }
        XCTAssertTrue(ToolSelectionPolicy.supportsNumericDomain(.int(ToolSelectionPolicy.maxSafeNumericMagnitude)))
        XCTAssertFalse(ToolSelectionPolicy.supportsNumericDomain(.int(Int.min)))
        XCTAssertFalse(ToolSelectionPolicy.supportsNumericDomain(.double(.infinity)))
    }

    func testExplicitRequestDuplicateScanPreservesExistingToolSchemaDepth() throws {
        var child: [String: Any] = ["type": "integer"]
        for _ in 0..<14 {
            child = ["type": "object", "properties": ["value": child], "required": ["value"], "additionalProperties": false]
        }
        let request = try Self.request(schema: [
            "type": "object", "properties": ["id": child], "required": ["id"], "additionalProperties": false,
        ])
        XCTAssertNoThrow(try ToolSelectionPolicy.validateRequest(request, loadedModelID: ToolSelectionPolicy.supportedNativeModel, runtime: "mlx_cache"))
        let wrappedTools = try JSONSerialization.data(withJSONObject: ["tools": try XCTUnwrap(request.promptSource.tools).jsonObject])
        XCTAssertThrowsError(try StrictJSONParser.parse(String(decoding: wrappedTools, as: UTF8.self)), "Regression must exceed the old whole-request bound")
        let nested = String(repeating: "[", count: 32) + "0" + String(repeating: "]", count: 32)
        XCTAssertThrowsError(try StrictJSONParser.parse(nested), "Default parser bound remains unchanged")
        XCTAssertNoThrow(try StrictJSONParser.parse(nested, maxDepth: 128))
    }


    /// #2107 validation (Qwen3.6, `required`/named): the buyer-UX suite's
    /// ordinary OpenAI parameters object, with no `additionalProperties:false`,
    /// returned 400 `unsupported_tool_schema`. SPEC-018 §3.11 v0.3.1 admits it;
    /// its output must still be an object holding every root required key.
    func testOrdinaryOpenAISchemaIsAdmittedForGuaranteedSelection() throws {
        let readFile: [String: Any] = ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]
        for choice: Any in ["required", ["type": "function", "function": ["name": "lookup"]]] {
            let request = try Self.request(choice: choice, schema: readFile)
            XCTAssertNoThrow(try ToolSelectionPolicy.validateRequest(request, loadedModelID: ToolSelectionPolicy.supportedNativeModel, runtime: "mlx_cache"))
            XCTAssertFalse(ToolSelectionPolicy.isStrictSubset(try XCTUnwrap(ToolSelectionPolicy.schemas(request)["lookup"])))
            XCTAssertNoThrow(try ToolSelectionPolicy.validateOutput(calls: [Self.call(arguments: #"{"path":"/etc/hosts"}"#)], finishReason: "tool_calls", generatedTokens: 9, request: request))
            for arguments in [#"{}"#, #"{"file":"/etc/hosts"}"#, #"[]"#] {
                XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [Self.call(arguments: arguments)], finishReason: "tool_calls", generatedTokens: 9, request: request)) { error in
                    XCTAssertEqual((error as? APIError)?.code, "tool_selection_validation_failed")
                }
            }
        }
        // A strict-subset schema keeps full validation.
        let strict = try Self.request()
        XCTAssertTrue(ToolSelectionPolicy.isStrictSubset(try XCTUnwrap(ToolSelectionPolicy.schemas(strict)["lookup"])))
        XCTAssertThrowsError(try ToolSelectionPolicy.validateOutput(calls: [Self.call(arguments: #"{"id":0}"#)], finishReason: "tool_calls", generatedTokens: 9, request: strict))
    }
}
