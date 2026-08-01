import Foundation
import XCTest
import Jinja
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

    // Regression: MCP-namespaced tool names contain hyphens (e.g. buzz-dev-mcp__shell).
    // These are valid OpenAI/MCP function names but were rejected by the old
    // Python-identifier validator, so Qwen3-Coder's <function=…> tool calls leaked as
    // raw text and never became structured tool_calls (Buzz reply never posted).
    func testQwen3CoderHyphenatedMCPToolName_WrappedForm() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"""
<tool_call>
<function=buzz-dev-mcp__shell>
<parameter=command>
buzz messages send --channel 7d5f1966-d036-431e-821e-3a4083f145fe --content "buzz-smoke-ok" --broadcast
</parameter>
</function>
</tool_call>
"""#,
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["buzz-dev-mcp__shell"]
        )

        XCTAssertNil(parsed.cleanedContent)
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(call.functionName, "buzz-dev-mcp__shell")
        XCTAssertEqual(
            try argumentValue(call.arguments, key: "command") as? String,
            "buzz messages send --channel 7d5f1966-d036-431e-821e-3a4083f145fe --content \"buzz-smoke-ok\" --broadcast"
        )
    }

    // Exact shape captured on the wire from Qwen3-Coder on the Malibu gateway: a bare
    // <function=…> block with an orphan trailing </tool_call> and no opening <tool_call>.
    func testQwen3CoderHyphenatedMCPToolName_BareFunctionFormWithOrphanClose() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: "<function=buzz-dev-mcp__shell>\n<parameter=command>\necho hi\n</parameter>\n</function>\n</tool_call>",
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["buzz-dev-mcp__shell"]
        )

        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(call.functionName, "buzz-dev-mcp__shell")
        XCTAssertEqual(try argumentValue(call.arguments, key: "command") as? String, "echo hi")
    }

    // Broadening the name charset must NOT weaken the allowlist boundary: a hyphenated
    // name that is not among the declared tools still fails closed (leaks as text).
    func testQwen3CoderHyphenatedUndeclaredFunctionStillFailsClosed() {
        let raw = #"<tool_call><function=evil-dev-mcp__wipe><parameter=path>/</parameter></function></tool_call>"#
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["buzz-dev-mcp__shell"]
        )

        XCTAssertTrue(parsed.toolCalls.isEmpty)
        XCTAssertEqual(parsed.cleanedContent, raw)
    }

    // Names longer than the 64-char OpenAI limit are rejected (fail closed).
    func testQwen3CoderOverlongFunctionNameFailsClosed() {
        let longName = String(repeating: "a", count: 65)
        let raw = "<tool_call><function=\(longName)><parameter=x>1</parameter></function></tool_call>"
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: raw,
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: [longName]
        )

        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    // MCP/JSON-Schema property names are not restricted to Python identifiers; the XML
    // <parameter=…> parser must accept hyphenated parameter names (they become JSON keys).
    func testQwen3CoderHyphenatedParameterName() throws {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call><function=buzz-dev-mcp__shell><parameter=work-dir>/tmp</parameter></function></tool_call>"#,
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["buzz-dev-mcp__shell"]
        )
        let call = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(call.functionName, "buzz-dev-mcp__shell")
        XCTAssertEqual(try argumentValue(call.arguments, key: "work-dir") as? String, "/tmp")
    }

    // Security: parameters from a LATER (undeclared) function block must not be attributed to a
    // declared first function. Parsing is bound to the first <function>…</function> block.
    func testQwen3CoderNestedUndeclaredFunctionDoesNotLeakParameters() {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<tool_call><function=buzz-dev-mcp__shell></function><function=evil-dev-mcp__wipe><parameter=command>rm -rf "$HOME/.ssh"</parameter></function></tool_call>"#,
            modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            allowedFunctionNames: ["buzz-dev-mcp__shell"]
        )
        // Acceptable outcomes: the declared first function with EMPTY args, or fully fail-closed.
        // What must NOT happen: the undeclared second function's `command` leaks into the call.
        for call in parsed.toolCalls {
            XCTAssertEqual(call.functionName, "buzz-dev-mcp__shell")
            XCTAssertFalse(call.arguments.contains("rm -rf"), "later-block params must not leak into the declared call")
        }
    }

    // Function-XML is a Qwen-row-only grammar (SPEC-018 §3.1 v0.2.7). A Llama modelID must not
    // synthesize tool calls from `<function=…>` markup.
    func testLlamaModelIDDoesNotParseFunctionXML() {
        let parsed = ToolCallParser.parseToolCalls(
            rawOutput: #"<function=search><parameter=q>x</parameter></function>"#,
            modelID: "mlx-community/Llama-3.3-70B-Instruct-4bit",
            allowedFunctionNames: ["search"]
        )
        XCTAssertTrue(parsed.toolCalls.isEmpty, "function-XML must not parse for non-Qwen families")
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

    func testTemplateToolsRenderJSONNullsAsJinjaNullPreservingShape() throws {
        // Regression for https://github.com/Augustas11/macprovider/issues/718
        // and correctness follow-up: `"default": null` in tool parameters
        // became NSNull, which swift-jinja cannot convert → 503 model_not_loaded
        // mislabel. The fix renders JSON nulls as native `Jinja.Value.null`
        // WITHOUT dropping keys or array positions (the earlier omit-based fix
        // silently mutated `enum:[null,…]`, `const:null`, and positional
        // defaults).
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

        let converted = try XCTUnwrap(ModelRuntime.mlxToolsForTemplate(from: tools))
        XCTAssertEqual(converted.count, 2)

        for tool in converted {
            XCTAssertFalse(Self.containsNSNull(tool), "converted tool must not contain NSNull: \(tool)")
        }

        let first = try XCTUnwrap(converted[0]["function"] as? [String: Any])
        XCTAssertEqual(first["name"] as? String, "f")
        // An absent description renders as a native Jinja null, matching the
        // receipt canonical form where absent and explicit-null both hash to
        // JCS null (PromptCanonicalizer.canonicalTool). Render must not diverge
        // from the signed prompt hash by treating absent as "undefined".
        XCTAssertTrue(first.keys.contains("description"), "absent description is rendered as null (hash parity)")
        XCTAssertEqual(first["description"] as? Jinja.Value, Jinja.Value.null)
        let firstParams = try XCTUnwrap(first["parameters"] as? [String: Any])
        let firstProps = try XCTUnwrap(firstParams["properties"] as? [String: Any])
        let timeout = try XCTUnwrap(firstProps["timeout"] as? [String: Any])
        XCTAssertEqual(timeout["type"] as? String, "integer")
        // default:null is PRESERVED as a native Jinja null (key retained).
        XCTAssertTrue(timeout.keys.contains("default"), "default key must be preserved")
        XCTAssertEqual(timeout["default"] as? Jinja.Value, Jinja.Value.null)
        XCTAssertTrue(firstProps.keys.contains("optional_hint"), "null-valued property key must be preserved")
        XCTAssertEqual(firstProps["optional_hint"] as? Jinja.Value, Jinja.Value.null)

        let second = try XCTUnwrap(converted[1]["function"] as? [String: Any])
        XCTAssertEqual(second["name"] as? String, "g")
        // description:null is PRESERVED as a native Jinja null.
        XCTAssertTrue(second.keys.contains("description"), "present description key must be preserved")
        XCTAssertEqual(second["description"] as? Jinja.Value, Jinja.Value.null)
        let secondParams = try XCTUnwrap(second["parameters"] as? [String: Any])
        let secondProps = try XCTUnwrap(secondParams["properties"] as? [String: Any])
        let tags = try XCTUnwrap(secondProps["tags"] as? [String: Any])
        // Array null elements keep their POSITION as a native Jinja null.
        let defaultTags = try XCTUnwrap(tags["default"] as? [Any])
        XCTAssertEqual(defaultTags.count, 2, "array null positions must be preserved, not dropped")
        XCTAssertEqual(defaultTags[0] as? Jinja.Value, Jinja.Value.null)
        XCTAssertEqual(defaultTags[1] as? String, "x")
        // Union type ["string","null"] keeps the string "null" (not a JSON null).
        let items = try XCTUnwrap(tags["items"] as? [String: Any])
        let typeUnion = try XCTUnwrap(items["type"] as? [Any])
        XCTAssertEqual(typeUnion as? [String], ["string", "null"])

        // The failing #718 boundary itself: the converted tools must round-trip
        // through swift-jinja's `Value(any:)` (what the tokenizer calls) WITHOUT
        // throwing — the original crash was here, not in the model.
        XCTAssertNoThrow(try Jinja.Value(any: converted))
    }

    func testTemplateToolConverterPreservesDeepShapeWithoutTruncation() throws {
        // Depth is bounded upstream at request validation (see the request-level
        // test below), so the converter is a faithful shape-preserving pass with
        // NO silent truncation: a deep-but-legal schema must reach its leaf
        // intact rather than being collapsed to null partway down.
        let depth = 20
        var node: JSONValue = .object(["leaf": .string("bottom")])
        for _ in 0..<depth {
            node = .object(["nested": node])
        }
        let tools: JSONValue = .array([
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string("deep"),
                    "parameters": .object(["type": .string("object"), "properties": node]),
                ]),
            ]),
        ])
        let converted = try XCTUnwrap(ModelRuntime.mlxToolsForTemplate(from: tools))
        var cursor: [String: Any] = try XCTUnwrap(
            (try XCTUnwrap(converted[0]["function"] as? [String: Any])["parameters"] as? [String: Any])?["properties"] as? [String: Any]
        )
        for _ in 0..<depth {
            cursor = try XCTUnwrap(cursor["nested"] as? [String: Any], "shape truncated before reaching the leaf")
        }
        XCTAssertEqual(cursor["leaf"] as? String, "bottom", "leaf value must survive the full depth")
        XCTAssertNoThrow(try Jinja.Value(any: converted))
    }

    func testOverDeepToolSchemaRejectedAtRequestValidation() throws {
        // Buyer-controlled tool schemas must not drive unbounded native
        // recursion in JSONValue.parse or the template converter. The guard
        // lives at the untrusted-input boundary (validateTools): it bounds the
        // container nesting of each function member, measured with the member
        // (here `parameters`) as depth 1, against JSONSchemaValidator.maxDepth.
        // A schema whose deepest container sits AT the limit is accepted; one
        // level past it is rejected 400 invalid_tools BEFORE any recursive walk.

        // Build a `parameters` value whose deepest container is at exactly
        // `containerDepth` (linear nesting so the boundary is precise).
        func parametersOfDepth(_ containerDepth: Int) -> Any {
            var node: Any = ["type": "object"]
            for _ in 1..<containerDepth { node = ["nested": node] }
            return node
        }
        func toolBody(depth: Int) -> [String: Any] {
            [
                "model": "fixture-model",
                "messages": [["role": "user", "content": "hi"]],
                "tools": [[
                    "type": "function",
                    "function": ["name": "f", "parameters": parametersOfDepth(depth)],
                ]],
            ]
        }

        let limit = 32 // JSONSchemaValidator.maxDepth

        // Exactly AT the limit: accepted.
        XCTAssertNoThrow(try parseRequest(toolBody(depth: limit)))

        // Exactly ONE past the limit: rejected with the established taxonomy code.
        XCTAssertThrowsError(try parseRequest(toolBody(depth: limit + 1))) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.status, 400)
            XCTAssertEqual(apiError?.code, "invalid_tools")
        }

        // A deep `description` object (not just parameters) is also bounded.
        let deepDescription: [String: Any] = [
            "model": "fixture-model",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [[
                "type": "function",
                "function": [
                    "name": "f",
                    "description": parametersOfDepth(limit + 1),
                    "parameters": ["type": "object"],
                ],
            ]],
        ]
        XCTAssertThrowsError(try parseRequest(deepDescription)) { error in
            XCTAssertEqual((error as? APIError)?.code, "invalid_tools")
        }

        // A deep member OUTSIDE `function` (an over-permissive client may attach
        // extra keys to the tool object) must not bypass the guard — JSONValue
        // .parse still recurses it.
        let deepExtraToolMember: [String: Any] = [
            "model": "fixture-model",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [[
                "type": "function",
                "function": ["name": "f", "parameters": ["type": "object"]],
                "x": parametersOfDepth(limit + 1),
            ]],
        ]
        XCTAssertThrowsError(try parseRequest(deepExtraToolMember)) { error in
            XCTAssertEqual((error as? APIError)?.code, "invalid_tools")
        }
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
