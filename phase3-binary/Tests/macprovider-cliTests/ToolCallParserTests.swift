import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class ToolCallParserTests: XCTestCase {
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
        let oversized = #"{"blob":"\#(String(repeating: "x", count: 256 * 1024))"}"#
        let raw = #"<tool_call>{"name":"find_definition","arguments":"\#(oversized.replacingOccurrences(of: "\"", with: "\\\""))"}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
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
        let repeatCount = ((256 * 1024) - envelopeBytes) / "€".utf8.count
        let arguments = prefix + String(repeating: "€", count: repeatCount) + suffix
        XCTAssertLessThanOrEqual(arguments.utf8.count, 256 * 1024)
        XCTAssertLessThanOrEqual(qwenToolCallJSON(argumentsJSON: arguments).utf8.count, 256 * 1024)
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
        let repeatCount = ((256 * 1024) - prefix.utf8.count - suffix.utf8.count) / "€".utf8.count + 1
        let arguments = prefix + String(repeating: "€", count: repeatCount) + suffix
        XCTAssertGreaterThan(arguments.utf8.count, 256 * 1024)
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
    }

    func testNullAndEmptyToolsDoNotEnableTemplateTools() {
        XCTAssertNil(ModelRuntime.mlxToolsForTemplate(from: .null))
        XCTAssertNil(ModelRuntime.mlxToolsForTemplate(from: .array([])))
        XCTAssertNil(ModelRuntime.mlxToolsForTemplate(from: nil))
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
