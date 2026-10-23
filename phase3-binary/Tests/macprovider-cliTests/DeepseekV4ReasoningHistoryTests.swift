import Foundation
import MacProviderCore
import MLXLMCommon
@testable import macprovider_cli
import XCTest

final class DeepseekV4ReasoningHistoryTests: XCTestCase {
    private let callReasoning = "I should look up the weather before answering."
    private let answerReasoning = "The tool reports clear weather."

    /// The encoder is checked against encoding_dsv4.py in
    /// DeepseekV4EncodingTests. Exercise the request boundary and message
    /// generator too: neither may discard reasoning that the reference keeps
    /// when tools are present, including reasoning before the last user turn.
    func testRequestToolHistoryRetainsReasoningThroughMessageGeneration() throws {
        let request = try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "deepseek/deepseek-v4-flash",
            "tools": [["type": "function", "function": [
                "name": "weather", "parameters": ["type": "object", "properties": [:]],
            ]]],
            "messages": [
                ["role": "user", "content": "What is the weather?"],
                ["role": "assistant", "content": NSNull(), "reasoning_content": callReasoning, "tool_calls": [[
                    "id": "call_0123456789abcdef", "type": "function",
                    "function": ["name": "weather", "arguments": "{}"],
                ]]],
                ["role": "tool", "tool_call_id": "call_0123456789abcdef", "content": "Clear"],
                ["role": "assistant", "content": "It is clear.", "reasoning_content": answerReasoning],
                ["role": "user", "content": "Thanks. What should I wear?"],
            ],
        ]))
        let input = try ModelRuntime.userInput(for: request)
        let messages = DefaultMessageGenerator().generate(from: input)
        XCTAssertEqual(messages[1]["reasoning_content"] as? String, callReasoning)
        XCTAssertEqual(messages[3]["reasoning_content"] as? String, answerReasoning)

        var referenceMessages = messages
        referenceMessages[1]["reasoning_content"] = callReasoning
        referenceMessages[3]["reasoning_content"] = answerReasoning
        let expected = try DeepseekV4Encoding.renderPrompt(
            messages: referenceMessages, tools: input.tools, additionalContext: input.additionalContext
        )
        XCTAssertTrue(expected.contains("<think>" + callReasoning + "</think>"))
        XCTAssertTrue(expected.contains("<think>" + answerReasoning + "</think>"))
        XCTAssertEqual(try DeepseekV4Encoding.renderPrompt(
            messages: messages, tools: input.tools, additionalContext: input.additionalContext
        ), expected)
    }

    func testNoToolsStillLetsReferenceDropEarlierReasoning() throws {
        let request = try historyRequest(model: "deepseek/deepseek-v4-flash")
        let input = try ModelRuntime.userInput(for: request)
        let messages = DefaultMessageGenerator().generate(from: input)
        XCTAssertEqual(messages[1]["reasoning_content"] as? String, answerReasoning)
        let prompt = try DeepseekV4Encoding.renderPrompt(
            messages: messages, tools: input.tools, additionalContext: input.additionalContext
        )
        XCTAssertFalse(prompt.contains(answerReasoning))
        XCTAssertTrue(prompt.contains("It is clear."))
    }

    func testOtherModelFamiliesKeepStructuredChatInput() throws {
        let request = try historyRequest(model: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit")
        let input = try ModelRuntime.userInput(for: request)
        guard case .chat = input.prompt else {
            return XCTFail("Only DSML needs raw reasoning-bearing messages")
        }
        let messages = DefaultMessageGenerator().generate(from: input)
        XCTAssertNil(messages[1]["reasoning_content"])
        XCTAssertEqual(messages[1]["content"] as? String, "It is clear.")
    }

    private func historyRequest(model: String) throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "user", "content": "What is the weather?"],
                ["role": "assistant", "content": "It is clear.", "reasoning_content": answerReasoning],
                ["role": "user", "content": "What should I wear?"],
            ],
        ]))
    }
}
