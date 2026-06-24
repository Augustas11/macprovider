import Foundation
import XCTest
import MacProviderCore
@testable import macprovider_cli

final class ToolCallParserTests: XCTestCase {
    func testSingleQwenToolCall() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call>{"name":"get_weather","arguments":{"city":"Vilnius"}}</tool_call>"#,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertNil(parsed.cleanedContent)
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertTrue(call.id.hasPrefix("call_"))
        XCTAssertEqual(call.functionName, "get_weather")
        XCTAssertEqual(try argumentValue(call.arguments, key: "city") as? String, "Vilnius")
    }

    func testMultipleQwenToolCalls() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call>{"name":"get_weather","arguments":{"city":"Vilnius"}}</tool_call><tool_call>{"name":"get_time","arguments":{"city":"Kaunas"}}</tool_call>"#,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertNil(parsed.cleanedContent)
        XCTAssertEqual(parsed.toolCalls.map(\.functionName), ["get_weather", "get_time"])
        XCTAssertEqual(try argumentValue(parsed.toolCalls[1].arguments, key: "city") as? String, "Kaunas")
    }

    func testToolCallWithNoArgumentsUsesEmptyObjectString() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call>{"name":"get_weather"}</tool_call>"#,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.arguments, "{}")
    }

    func testExplicitNullArgumentsFallBackToPlainText() {
        let raw = #"<tool_call>{"name":"get_weather","arguments":null}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testMalformedToolCallJSONFallsBackToPlainText() {
        let raw = #"<tool_call>{"name":"get_weather","arguments":</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testNonObjectArgumentsFallBackToPlainText() {
        let raw = #"<tool_call>{"name":"get_weather","arguments":["Vilnius"]}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, raw)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testMixedProseAndToolCallKeepsCleanedContent() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"I'll check that.<tool_call>{"name":"get_weather","arguments":{"city":"Vilnius"}}</tool_call>"#,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )

        XCTAssertEqual(parsed.cleanedContent, "I'll check that.")
        XCTAssertEqual(parsed.toolCalls.count, 1)
    }

    func testLlamaParametersNormalizeToArgumentsString() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<|python_tag|>{"name":"get_weather","parameters":{"city":"Vilnius"}}<|eom_id|>"#,
            modelID: "mlx-community/Llama-3.3-70B-Instruct-4bit"
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "get_weather")
        XCTAssertEqual(try argumentValue(call.arguments, key: "city") as? String, "Vilnius")
    }

    func testUndeclaredFunctionFallsBackToPlainText() {
        let raw = #"<tool_call>{"name":"delete_city","arguments":{"city":"Vilnius"}}</tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            allowedFunctionNames: ["get_weather"]
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
                    "name": .string("get_weather"),
                    "description": .string("Get weather"),
                    "parameters": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "city": .object(["type": .string("string")]),
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
        XCTAssertEqual(function["name"] as? String, "get_weather")
        XCTAssertEqual(function["description"] as? String, "Get weather")
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
}
