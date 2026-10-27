import Foundation
import Jinja
import MacProviderCore
import MLXLMCommon
import XCTest
@testable import macprovider_cli

final class LFMToolRuntimeTests: XCTestCase {
    private let model = "LiquidAI/LFM2.5-24B-A2B-MLX-4bit"
    private static let templateURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures/lfm25-chat-template/chat_template.jinja")

    private func request(name: String = "weather", arguments: String = #"{"city":"Oslo"}"#,
                         reasoning: String? = nil, laterUser: Bool = false) throws -> ChatCompletionRequest {
        var assistant: [String: Any] = ["role": "assistant", "content": "", "tool_calls": [[
            "id": "call_0123456789abcdef", "type": "function",
            "function": ["name": name, "arguments": arguments],
        ]]]
        if let reasoning { assistant["reasoning_content"] = reasoning }
        var messages: [[String: Any]] = [
            ["role": "user", "content": "Weather?"], assistant,
            ["role": "tool", "tool_call_id": "call_0123456789abcdef", "content": "Clear"],
        ]
        if laterUser { messages.append(["role": "user", "content": "Thanks"]) }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model, "messages": messages,
        ]))
    }

    private func render(_ input: UserInput) throws -> String {
        let source = try String(contentsOf: Self.templateURL, encoding: .utf8)
        let template = try Template(ChatTemplateCompatibility.rewrite(source).template,
                                    with: .init(lstripBlocks: true, trimBlocks: true))
        let messages = DefaultMessageGenerator().generate(from: input)
        let plain = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: messages))
        return try template.render([
            "messages": try Value(any: plain), "bos_token": .string("<|startoftext|>"),
            "add_generation_prompt": .boolean(true),
        ])
    }

    func testPinnedVendorTemplateRendersNativeHistoryAndOngoingReasoning() throws {
        let input = try ModelRuntime.userInput(for: request(reasoning: "Check the tool."))
        guard case .messages = input.prompt else { return XCTFail("LFM reasoning must reach the raw template messages") }
        XCTAssertEqual(DefaultMessageGenerator().generate(from: input)[1]["reasoning_content"] as? String, "Check the tool.")
        XCTAssertEqual(try render(input), "<|startoftext|><|im_start|>user\nWeather?<|im_end|>\n<|im_start|>assistant\n<think>Check the tool.</think><|tool_call_start|>[weather(city='Oslo')]<|tool_call_end|><|im_end|>\n<|im_start|>tool\nClear<|im_end|>\n<|im_start|>assistant\n<think>")
        let oldReasoning = try render(ModelRuntime.userInput(for: request(reasoning: "Check the tool.", laterUser: true)))
        XCTAssertFalse(oldReasoning.contains("Check the tool."), "The vendor template discards reasoning before the latest user turn")
    }

    func testHistoryArgumentsRemainMappingsAndNestedJSONKeysAreUnrestricted() throws {
        let input = try ModelRuntime.userInput(for: request(arguments: #"{"payload":{"not-an-identifier":true}}"#))
        let messages = DefaultMessageGenerator().generate(from: input)
        let calls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: any Sendable]])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: any Sendable])
        XCTAssertNotNil(function["arguments"] as? [String: any Sendable])
        let output = try render(input)
        XCTAssertTrue(output.contains(#"[weather(payload={"not-an-identifier": true})]"#), output)
        guard case .chat = input.prompt else { return XCTFail("Absent reasoning keeps structured chat input") }
    }

    func testHistoryRejectsInvalidNativeIdentifiersBeforeTemplate() throws {
        for name in ["bad-name", "1name", "é", "class"] {
            XCTAssertThrowsError(try ModelRuntime.userInput(for: request(name: name)))
        }
        for key in ["bad-key", "1key", "é", "for"] {
            let args = String(data: try JSONSerialization.data(withJSONObject: [key: 1]), encoding: .utf8)!
            XCTAssertThrowsError(try ModelRuntime.userInput(for: request(arguments: args)))
        }
    }

    func testLoadedTemplateAliasCannotBypassNativeSchemaValidation() throws {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "local-alias", "messages": [["role": "user", "content": "Run"]],
            "tools": [["type": "function", "function": ["name": "bad-name", "parameters": ["type": "object"]]]],
        ]))
        XCTAssertEqual(try ModelRuntime.resolvedToolGrammar(for: request, templateToolFormat: "lfm2"), .lfm2)
        let filter = ModelRuntime.toolAwareStopTokenFilter(StopTokenFilter(tokens: ["<|tool_call_end|>"]), grammar: ModelRuntime.toolGrammar(for: request))
        XCTAssertTrue(filter.tokens.isEmpty, "The loaded alias preserves native framing after grammar resolution")
        XCTAssertThrowsError(try ModelRuntime.userInput(for: request)) { error in
            XCTAssertEqual((error as? APIError)?.code, "unsupported_tool_schema")
        }
    }

    func testStreamingHoldsNativeEnvelopeUntilItsActualClose() {
        var emitter = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["weather"])
        let output = "Here. <|tool_call_start|>[weather(city='Oslo')]<|tool_call_end|>"
        var prefix = ""
        for character in output {
            prefix.append(character)
            XCTAssertTrue(emitter.observe(prefix).isEmpty, "LFM emits complete calls through the final parser")
            XCTAssertEqual(emitter.hasCompletedValidToolCall, prefix == output)
            let visible = emitter.visibleContentPrefix(of: prefix)
            XCTAssertFalse(visible.contains("<|tool"), visible)
        }
        XCTAssertTrue(emitter.suppressesAssistantContent)
    }

    func testMarkerInsideStringAndMalformedEnvelopesCannotStopSerialTurn() {
        for incomplete in [
            "<|tool_call_start|>[weather(city='<|tool_call_end|>",
            "<|tool_call_start|>[weather(city='Oslo')]",
            "<|tool_call_start|>[weather(city='Oslo'), broken(]<|tool_call_end|>",
            "<|tool_call_start|>[unknown(city='Oslo')]<|tool_call_end|>",
            "<|tool_call_start|>[weather(city='Oslo')]<|tool_call_end|>junk",
        ] {
            var emitter = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["weather"])
            XCTAssertTrue(emitter.observe(incomplete).isEmpty)
            XCTAssertFalse(emitter.hasCompletedValidToolCall, incomplete)
        }
        var emitter = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["weather"])
        _ = emitter.observe("<|tool_call_start|>[weather(city='<|tool_call_end|>')]<|tool_call_end|>")
        XCTAssertTrue(emitter.hasCompletedValidToolCall)
        var whitespace = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["weather"])
        _ = whitespace.observe("<|tool_call_start|>[weather(city='Oslo')]<|tool_call_end|>\n")
        XCTAssertTrue(whitespace.hasCompletedValidToolCall)
    }

    func testVendorOpenReasoningDefersNativeSerialStopUntilAnswer() throws {
        let prompt = try render(ModelRuntime.userInput(for: request()))
        XCTAssertTrue(ReasoningOutput.promptLeavesThinkOpen(String(prompt.suffix(100))))
        let call = "<|tool_call_start|>[weather(city='Oslo')]<|tool_call_end|>"
        var emitter = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["weather"])
        let filter = ModelRuntime.toolAwareStopTokenFilter(StopTokenFilter(tokens: ["<|tool_call_start|>", "<|tool_call_end|>"]), grammar: .lfm2)
        XCTAssertFalse(ModelRuntime.observeSerialToolStop(&emitter, decoded: call, stopTokenFilter: filter, requestStops: [], reasoningOpen: true))
        XCTAssertTrue(ModelRuntime.observeSerialToolStop(&emitter, decoded: "Plan.</think>" + call, stopTokenFilter: filter, requestStops: [], reasoningOpen: true))
    }

    func testSpecialTokenFilteringPreservesNativeFramingButRequestStopsStillApply() {
        let filter = ModelRuntime.toolAwareStopTokenFilter(
            StopTokenFilter(tokens: ["<|tool_call_start|>", "<|tool_call_end|>", "<|im_end|>"]), grammar: .lfm2)
        let text = "<|tool_call_start|>[weather(city='Oslo')]<|tool_call_end|>"
        let result = ModelRuntime.applyOutputFilters(text + "<|im_end|>", stopTokenFilter: filter, requestStops: [])
        XCTAssertEqual(result.text, text)
        var emitter = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["weather"])
        XCTAssertTrue(ModelRuntime.observeSerialToolStop(&emitter, decoded: text, stopTokenFilter: filter, requestStops: []))
        var stopped = NativeToolCallStreamEmitter(modelID: model, allowedFunctionNames: ["weather"])
        XCTAssertFalse(ModelRuntime.observeSerialToolStop(&stopped, decoded: text, stopTokenFilter: filter, requestStops: ["Oslo"]))
        let raw = StopTokenFilter(tokens: ["<|tool_call_start|>", "<|im_end|>"])
        let other = ModelRuntime.toolAwareStopTokenFilter(raw, grammar: .qwen)
        XCTAssertEqual(other.tokens, raw.tokens)
    }
}
