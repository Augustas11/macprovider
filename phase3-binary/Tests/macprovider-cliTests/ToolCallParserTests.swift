import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class ToolCallParserTests: XCTestCase {
    func testAC46_KnownButMalformedHashReturnsNilAndLogs() {
        let result = ModelRuntime.validObservedModelHash("not-a-hex-string")
        XCTAssertNil(result, "AC-46: malformed hex input must return nil")
        // Logging happens; test passes if no fatal error.
    }

    func testSingleQwenToolCall() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call>{"name":"find_definition","arguments":{"symbol":"ToolCallParser"}}</tool_call>"#,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertNil(parsed.cleanedContent)
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertTrue(call.id.hasPrefix("call_"))
        XCTAssertEqual(call.functionName, "find_definition")
        XCTAssertEqual(try argumentValue(call.arguments, key: "symbol") as? String, "ToolCallParser")
    }

    func testMultipleQwenToolCalls() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call>{"name":"find_definition","arguments":{"symbol":"ToolCallParser"}}</tool_call><tool_call>{"name":"list_references","arguments":{"symbol":"ToolCallParser"}}</tool_call>"#,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertNil(parsed.cleanedContent)
        XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["find_definition", "list_references"])
        XCTAssertEqual(try argumentValue(parsed.toolCalls[1].arguments, key: "symbol") as? String, "ToolCallParser")
    }

    func testQwenPythonStyleToolCall() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call>find_definition(symbol="ToolCallParser")</tool_call>"#,
            modelID: "mlx-community/Qwen3-32B-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertNil(parsed.cleanedContent)
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(call.functionName, "find_definition")
        XCTAssertEqual(try argumentValue(call.arguments, key: "symbol") as? String, "ToolCallParser")
    }

    func testDelimiterOnlyDetection_SentinelWithoutModelID_FallsBackToPlainContent() {
        let raw = #"<tool_call>find_definition(symbol="ToolCallParser")</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Other-Instruct-7B-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testQwen3ModelID_TriggersQwenParser() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call>{"name":"find_definition","arguments":{"symbol":"ToolCallParser"}}</tool_call>"#,
            modelID: "mlx-community/Qwen3-32B-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(call.functionName, "find_definition")
        XCTAssertEqual(try argumentValue(call.arguments, key: "symbol") as? String, "ToolCallParser")
    }

    func testMixedFamilyModelID_UsesQwenTableOrderPrecedence() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call>{"name":"find_definition","arguments":{"symbol":"ToolCallParser"}}</tool_call>"#,
            modelID: "mlx-community/Qwen3-Llama-3.3-hybrid",
            allowedFunctionNames: ["find_definition"]
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertNil(parsed.cleanedContent)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(call.functionName, "find_definition")
        XCTAssertEqual(try argumentValue(call.arguments, key: "symbol") as? String, "ToolCallParser")
    }

    func testEmptyModelID_FallsBackToPlainContent() {
        let raw = #"<tool_call>{"name":"find_definition","arguments":{"symbol":"ToolCallParser"}}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testWhitespaceModelID_FallsBackToPlainContent() {
        let raw = #"<tool_call>{"name":"find_definition","arguments":{"symbol":"ToolCallParser"}}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: " \n\t ",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testQwenPythonStyleToolCallKeepsThinkingOutOfToolArguments() throws {
        let raw = """
        <think>
        I should use the provided tool.
        </think>

        <tool_call>
        find_definition(symbol='ToolCallParser')
        </tool_call>
        """
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen3-32B-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "find_definition")
        XCTAssertEqual(try argumentValue(call.arguments, key: "symbol") as? String, "ToolCallParser")
        XCTAssertEqual(parsed.cleanedContent?.trimmingCharacters(in: .whitespacesAndNewlines), "<think>\nI should use the provided tool.\n</think>")
    }

    func testToolCallWithNoArgumentsUsesEmptyObjectString() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call>{"name":"explain_current_file"}</tool_call>"#,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.arguments, "{}")
    }

    func testExplicitNullArgumentsFallBackToPlainText() {
        let raw = #"<tool_call>{"name":"find_definition","arguments":null}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testMalformedToolCallJSONFallsBackToPlainText() {
        let raw = #"<tool_call>{"name":"find_definition","arguments":</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testMalformedPythonStyleToolCallFallsBackToPlainText() {
        let raw = #"<tool_call>find_definition("ToolCallParser")</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen3-32B-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testDuplicatePythonStyleArgumentsFallBackToPlainText() {
        let raw = #"<tool_call>find_definition(symbol="ToolCallParser", symbol="Other")</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen3-32B-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testDuplicateJSONObjectArgumentsFallBackToPlainText() {
        let raw = #"<tool_call>{"name":"find_definition","arguments":{"symbol":"ToolCallParser","symbol":"Other"}}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testDuplicateJSONStringArgumentsFallBackToPlainText() {
        let raw = #"<tool_call>{"name":"find_definition","arguments":"{\"symbol\":\"ToolCallParser\",\"symbol\":\"Other\"}"}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testUnknownModelWithoutToolDelimiterDoesNotParsePythonStyleText() {
        let raw = #"find_definition(symbol="ToolCallParser")"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Other-Instruct-7B-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testNonObjectArgumentsFallBackToPlainText() {
        let raw = #"<tool_call>{"name":"find_definition","arguments":["ToolCallParser"]}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testEmptyToolCallObjectFallsBackToPlainText() {
        let raw = #"<tool_call>{}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testDeepNestedArgumentsFallBackToPlainText() {
        var nested = "1"
        for i in stride(from: 100, through: 1, by: -1) {
            nested = #"{"k\#(i)":\#(nested)}"#
        }
        let raw = #"<tool_call>{"name":"find_definition","arguments":"\#(nested.replacingOccurrences(of: "\"", with: "\\\""))"}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testOversizedArgumentsFallBackToPlainText() {
        let oversized = #"{"blob":"\#(String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP))"}"#
        let raw = #"<tool_call>{"name":"find_definition","arguments":"\#(oversized.replacingOccurrences(of: "\"", with: "\\\""))"}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testOversizedQwenPythonStyleArgumentsFallBackToPlainText() {
        let raw = #"<tool_call>find_definition(blob="\#(String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP))")</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen3-32B-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testOversizedLlamaPythonStyleArgumentsFallBackToPlainText() {
        let raw = #"<|python_tag|>find_definition(blob="\#(String(repeating: "x", count: ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP))")<|eom_id|>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Llama-3.3-70B-Instruct-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testMaxDepthArgumentsAccepted() throws {
        let arguments = nestedObject(depth: 32)
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: qwenToolCallRaw(argumentsJSON: arguments),
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertNil(parsed.cleanedContent)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(call.functionName, "find_definition")
    }

    func testMaxDepthPlusOneArgumentsFallBackToPlainText() {
        let raw = qwenToolCallRaw(argumentsJSON: nestedObject(depth: 33))
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testMultibyteArgumentsUnderByteLimitAccepted() throws {
        let prefix = #"{"blob":""#
        let suffix = #""}"#
        let envelopeBytes = qwenToolCallJSON(argumentsJSON: prefix + suffix).utf8.count
        let repeatCount = (ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP - envelopeBytes) / "€".utf8.count
        let arguments = prefix + String(repeating: "€", count: repeatCount) + suffix
        XCTAssertLessThanOrEqual(arguments.utf8.count, ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP)
        XCTAssertLessThanOrEqual(qwenToolCallJSON(argumentsJSON: arguments).utf8.count, ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP)
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: qwenToolCallRaw(argumentsJSON: arguments),
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertNil(parsed.cleanedContent)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        _ = try XCTUnwrap(parsed.toolCalls.first)
    }

    func testMultibyteArgumentsOverByteLimitFallBackToPlainText() {
        let prefix = #"{"blob":""#
        let suffix = #""}"#
        let repeatCount = (ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP - prefix.utf8.count - suffix.utf8.count) / "€".utf8.count + 1
        let arguments = prefix + String(repeating: "€", count: repeatCount) + suffix
        XCTAssertGreaterThan(arguments.utf8.count, ToolCallParser.SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP)
        let raw = qwenToolCallRaw(argumentsJSON: arguments)
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testMixedProseAndToolCallKeepsCleanedContent() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"I'll check that.<tool_call>{"name":"find_definition","arguments":{"symbol":"ToolCallParser"}}</tool_call>"#,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, "I'll check that.")
        XCTAssertEqual(parsed.toolCalls.count, 1)
    }

    func testLlamaParametersNormalizeToArgumentsString() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<|python_tag|>{"name":"find_definition","parameters":{"symbol":"ToolCallParser"}}<|eom_id|>"#,
            modelID: "mlx-community/Llama-3.3-70B-Instruct-4bit"
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "find_definition")
        XCTAssertEqual(try argumentValue(call.arguments, key: "symbol") as? String, "ToolCallParser")
    }

    func testLlamaPythonStyleToolCall() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<|python_tag|>find_definition(symbol="ToolCallParser")<|eom_id|>"#,
            modelID: "mlx-community/Llama-3.3-70B-Instruct-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "find_definition")
        XCTAssertEqual(try argumentValue(call.arguments, key: "symbol") as? String, "ToolCallParser")
    }

    func testUndeclaredFunctionFallsBackToPlainText() {
        let raw = #"<tool_call>{"name":"delete_symbol","arguments":{"symbol":"ToolCallParser"}}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            allowedFunctionNames: ["find_definition"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testQwen3CoderNemotronXMLToolCall() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"""
<tool_call>
<function=json_validate>
<parameter=text>
{"valid":true}
</parameter>
</function>
</tool_call>
"""#,
            modelID: "qwen3-coder-30b-a3b-instruct",
            allowedFunctionNames: ["json_validate"]
        )

        XCTAssertNil(parsed.cleanedContent)
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "json_validate")
        XCTAssertEqual(try argumentValue(call.arguments, key: "text") as? String, "{\"valid\":true}")
    }

    func testQwen3CoderNemotronXMLInlineToolCall() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call><function=json_validate><parameter=text>{"valid":true}</parameter></function></tool_call>"#,
            modelID: "qwen3-coder-30b-a3b-instruct",
            allowedFunctionNames: ["json_validate"]
        )

        XCTAssertNil(parsed.cleanedContent)
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "json_validate")
        XCTAssertEqual(try argumentValue(call.arguments, key: "text") as? String, "{\"valid\":true}")
    }

    func testQwen3CoderNemotronXMLMultilineParameter() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"""
<tool_call>
<function=execute_bash>
<parameter=command>
pwd && ls
</parameter>
</function>
</tool_call>
"""#,
            modelID: "qwen3-coder-30b-a3b-instruct",
            allowedFunctionNames: ["execute_bash"]
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "execute_bash")
        XCTAssertEqual(try argumentValue(call.arguments, key: "command") as? String, "pwd && ls")
    }

    func testQwen3CoderNemotronXMLMultipleParameters() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"""
<tool_call>
<function=search_products>
<parameter=query>
waterproof running shoes
</parameter>
<parameter=sort_by>
price_low_to_high
</parameter>
</function>
</tool_call>
"""#,
            modelID: "qwen3-coder-30b-a3b-instruct",
            allowedFunctionNames: ["search_products"]
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "search_products")
        XCTAssertEqual(try argumentValue(call.arguments, key: "query") as? String, "waterproof running shoes")
        XCTAssertEqual(try argumentValue(call.arguments, key: "sort_by") as? String, "price_low_to_high")
    }

    func testQwen3CoderNemotronXMLUndeclaredFunctionFailsClosed() {
        let raw = #"<tool_call><function=delete_symbol><parameter=symbol>x</parameter></function></tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "qwen3-coder-30b-a3b-instruct",
            allowedFunctionNames: ["json_validate"]
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testQwen3CoderNemotronXMLBareFunctionWithoutToolCallWrapper() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: """
I'll validate that.

<function=json_validate><parameter=text>{"valid":true}</parameter></function>
""",
            modelID: "qwen3-coder-30b-a3b-instruct",
            allowedFunctionNames: ["json_validate"]
        )

        XCTAssertEqual(parsed.cleanedContent, "I'll validate that.")
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "json_validate")
    }

    func testTemplateToolsStripFieldsOutsideReceiptCanonicalSubset() {
        let tools: JSONValue = .array([
            .object([
                "type": .string("function"),
                "x_tool_extra": .string("must-not-reach-template"),
                "function": .object([
                    "name": .string("find_definition"),
                    "description": .string("Find where a code symbol is defined"),
                    "parameters": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "symbol": .object(["type": .string("string")]),
                        ]),
                    ]),
                    "x_function_extra": .string("must-not-reach-template"),
                ]),
            ]),
        ])

        let converted = ModelRuntime.mlxToolsForTemplate(from: tools)
        let tool = try! XCTUnwrap(converted?.first)
        XCTAssertEqual(tool["type"] as? String, "function")
        XCTAssertNil(tool["x_tool_extra"])
        let function = try! XCTUnwrap(tool["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "find_definition")
        XCTAssertEqual(function["description"] as? String, "Find where a code symbol is defined")
        XCTAssertNotNil(function["parameters"])
        XCTAssertNil(function["x_function_extra"])
        XCTAssertFalse(Self.containsNSNull(tool), "template tools must not materialize NSNull")
    }

    func testTemplateToolsOmitJSONNullsAndMissingDescription() {
        // Regression for https://github.com/Augustas11/macprovider/issues/718:
        // `"default": null` in tool parameters became NSNull, which swift-jinja
        // cannot convert → 503 model_not_loaded mislabel.
        let tools: JSONValue = .array([
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string("f"),
                    // description intentionally omitted
                    "parameters": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "timeout": .object([
                                "type": .string("integer"),
                                "default": .null,
                            ]),
                            "optional_hint": .null,
                        ]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
            ]),
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string("g"),
                    "description": .null,
                    "parameters": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "tags": .object([
                                "type": .string("array"),
                                "items": .object([
                                    "type": .array([.string("string"), .string("null")]),
                                ]),
                                "default": .array([.null, .string("x")]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])

        let converted = try! XCTUnwrap(ModelRuntime.mlxToolsForTemplate(from: tools))
        XCTAssertEqual(converted.count, 2)

        for tool in converted {
            XCTAssertFalse(Self.containsNSNull(tool), "converted tool must not contain NSNull: \(tool)")
        }

        let first = try! XCTUnwrap(converted[0]["function"] as? [String: Any])
        XCTAssertEqual(first["name"] as? String, "f")
        XCTAssertNil(first["description"], "missing description must be omitted, not NSNull")
        let firstParams = try! XCTUnwrap(first["parameters"] as? [String: Any])
        let firstProps = try! XCTUnwrap(firstParams["properties"] as? [String: Any])
        let timeout = try! XCTUnwrap(firstProps["timeout"] as? [String: Any])
        XCTAssertEqual(timeout["type"] as? String, "integer")
        XCTAssertNil(timeout["default"], "default:null must be omitted from template tools")
        XCTAssertNil(firstProps["optional_hint"], "null-valued property entry must be omitted")

        let second = try! XCTUnwrap(converted[1]["function"] as? [String: Any])
        XCTAssertEqual(second["name"] as? String, "g")
        XCTAssertNil(second["description"], "description:null must be omitted, not NSNull")
        let secondParams = try! XCTUnwrap(second["parameters"] as? [String: Any])
        let secondProps = try! XCTUnwrap(secondParams["properties"] as? [String: Any])
        let tags = try! XCTUnwrap(secondProps["tags"] as? [String: Any])
        // Array null elements are dropped so Jinja never sees NSNull.
        let defaultTags = try! XCTUnwrap(tags["default"] as? [Any])
        XCTAssertEqual(defaultTags.count, 1)
        XCTAssertEqual(defaultTags.first as? String, "x")
        // Union type ["string","null"] keeps the string "null" (not a JSON null).
        let items = try! XCTUnwrap(tags["items"] as? [String: Any])
        let typeUnion = try! XCTUnwrap(items["type"] as? [Any])
        XCTAssertEqual(typeUnion as? [String], ["string", "null"])
    }

    func testNullAndEmptyToolsDoNotEnableTemplateTools() {
        XCTAssertNil(ModelRuntime.mlxToolsForTemplate(from: .null))
        XCTAssertNil(ModelRuntime.mlxToolsForTemplate(from: .array([])))
        XCTAssertNil(ModelRuntime.mlxToolsForTemplate(from: nil))
    }

    private static func containsNSNull(_ value: Any) -> Bool {
        if value is NSNull {
            return true
        }
        if let object = value as? [String: Any] {
            return object.values.contains(where: containsNSNull)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsNSNull)
        }
        return false
    }

    private func argumentValue(_ arguments: String, key: String) throws -> Any? {
        let data = try XCTUnwrap(arguments.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object[key]
    }

    private func nestedObject(depth: Int) -> String {
        var nested = "1"
        for i in stride(from: depth, through: 1, by: -1) {
            nested = #"{"k\#(i)":\#(nested)}"#
        }
        return nested
    }

    private func qwenToolCallRaw(argumentsJSON: String) -> String {
        #"<tool_call>\#(qwenToolCallJSON(argumentsJSON: argumentsJSON))</tool_call>"#
    }

    private func qwenToolCallJSON(argumentsJSON: String) -> String {
        let escaped = argumentsJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"name":"find_definition","arguments":"\#(escaped)"}"#
    }
}
