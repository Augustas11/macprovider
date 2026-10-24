import Foundation
import Jinja
import MacProviderCore
import MLXLMCommon
@testable import macprovider_cli
import XCTest

/// GLM-5.3's template renders an assistant turn's `reasoning_content` back as
/// `<think>…</think>`. A tool-loop request that carries reasoning must reach
/// the template with it; every other GLM request keeps structured chat input.
final class GLMReasoningHistoryTests: XCTestCase {
    private let reasoning = "Check the weather tool before answering."
    private static let template = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures/glm53-chat-template/chat_template.jinja")

    private func request(reasoning: String?) throws -> ChatCompletionRequest {
        var assistant: [String: Any] = [
            "role": "assistant", "content": NSNull(), "tool_calls": [[
                "id": "call_0123456789abcdef", "type": "function",
                "function": ["name": "weather", "arguments": "{\"city\":\"Oslo\"}"],
            ]],
        ]
        if let reasoning { assistant["reasoning_content"] = reasoning }
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "zai-org/glm-5.3-flash",
            "tools": [["type": "function", "function": [
                "name": "weather",
                "parameters": ["type": "object", "properties": ["city": ["type": "string"]]],
            ]]],
            "messages": [
                ["role": "user", "content": "Weather in Oslo?"],
                assistant,
                ["role": "tool", "tool_call_id": "call_0123456789abcdef", "content": "Clear"],
            ],
        ]))
    }

    private func render(_ input: UserInput) throws -> String {
        let source = try String(contentsOf: Self.template, encoding: .utf8)
        let template = try Template(
            ChatTemplateCompatibility.rewrite(source).template,
            with: .init(lstripBlocks: true, trimBlocks: true)
        )
        // Round-trip messages through JSON so the template sees plain Foundation values.
        func plain(_ value: Any) throws -> Value {
            try Value(any: JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)))
        }
        var context: [String: Value] = [
            "messages": try plain(DefaultMessageGenerator().generate(from: input)),
            "add_generation_prompt": .boolean(true),
        ]
        // Tools already hold template values (Jinja `.null`), as the runtime passes them.
        if let tools = input.tools { context["tools"] = try Value(any: tools) }
        return try template.render(context)
    }

    func testToolLoopReasoningReachesTheTemplate() throws {
        let input = try ModelRuntime.userInput(for: request(reasoning: reasoning))
        guard case .messages = input.prompt else {
            return XCTFail("GLM history with reasoning must keep the raw reasoning field")
        }
        let messages = DefaultMessageGenerator().generate(from: input)
        XCTAssertEqual(messages[1]["reasoning_content"] as? String, reasoning)
        XCTAssertNil(messages[0]["reasoning_content"])
        XCTAssertNil(messages[2]["reasoning_content"])

        let withReasoning = try render(input)
        XCTAssertTrue(withReasoning.contains("<think>" + reasoning + "</think>"), withReasoning)
        // The only prompt difference is the restored thinking.
        let without = try render(ModelRuntime.userInput(for: request(reasoning: nil)))
        XCTAssertTrue(without.contains("<think></think>"))
        XCTAssertEqual(
            withReasoning.replacingOccurrences(of: "<think>" + reasoning + "</think>", with: "<think></think>"),
            without
        )
    }

    func testGLMWithoutReasoningKeepsStructuredChatInput() throws {
        let input = try ModelRuntime.userInput(for: request(reasoning: nil))
        guard case .chat = input.prompt else {
            return XCTFail("A GLM request without reasoning must keep the structured chat path")
        }
    }
}
