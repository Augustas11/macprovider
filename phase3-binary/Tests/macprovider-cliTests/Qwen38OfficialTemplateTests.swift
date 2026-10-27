import CryptoKit
import Foundation
import Jinja
import MLXLMCommon
import MacProviderCore
@testable import macprovider_cli
import XCTest

/// The official Qwen/Qwen3.8-27B template at
/// 1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0, independent of community quants.
final class Qwen38OfficialTemplateTests: XCTestCase {
    private static let templateURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures/qwen38-27b-official/chat_template.jinja")
    private static let officialModel = "Qwen/Qwen3.8-27B"

    private func request(model: String = "Qwen/Qwen3.8-27B", effort: String? = nil,
                         history: Bool = false) throws -> ChatCompletionRequest {
        var messages: [[String: Any]] = [["role": "user", "content": "Look up Paris."]]
        var body: [String: Any] = ["model": model]
        if let effort { body["reasoning_effort"] = effort }
        if history {
            body["tools"] = [["type": "function", "function": [
                "name": "lookup", "parameters": ["type": "object", "properties": ["city": ["type": "string"]]],
            ]]]
            messages.append(["role": "assistant", "content": "", "reasoning_content": "PRESERVED_TOOL_REASONING",
                             "tool_calls": [["id": "call_0123456789abcdef", "type": "function",
                                             "function": ["name": "lookup", "arguments": #"{"city":"Paris"}"#]]]])
            messages.append(["role": "tool", "tool_call_id": "call_0123456789abcdef", "content": "PARIS_RESULT"])
        }
        body["messages"] = messages
        return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: body))
    }

    private func input(_ request: ChatCompletionRequest, loadedModel: String? = nil) throws -> UserInput {
        try ModelRuntime.userInput(for: request, templateSupportsThinkingToggle: true,
                                   templateSupportsPreserveThinking: true, toolSelectionModelID: loadedModel)
    }

    private func render(_ input: UserInput, enableThinking: Bool? = nil) throws -> String {
        let source = try String(contentsOf: Self.templateURL, encoding: .utf8)
        let template = try Template(ChatTemplateCompatibility.rewrite(source).template,
                                    with: .init(lstripBlocks: true, trimBlocks: true))
        let messages = DefaultMessageGenerator().generate(from: input)
        var context: [String: Value] = [
            "messages": try Value(any: messages.map { $0 as [String: Any] }),
            "tools": try Value(any: input.tools ?? []),
            "add_generation_prompt": .boolean(true),
        ]
        for (key, value) in input.additionalContext ?? [:] { context[key] = try Value(any: value) }
        if let enableThinking { context["enable_thinking"] = .boolean(enableThinking) }
        return try template.render(context)
    }

    func testOfficialTemplateFixtureIdentity() throws {
        let bytes = try Data(contentsOf: Self.templateURL)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041")
    }

    func testEveryAcceptedEffortFitsOfficialTemplate() throws {
        for model in [Self.officialModel, "qwen3.8-27b", "mlx-community/Qwen3.8-27B-4bit"] {
            for effort in ChatCompletionRequest.acceptedReasoningEfforts {
                let request = try request(model: model, effort: effort)
                let expected = ["none", "minimal"].contains(effort) ? "low"
                    : (["high", "max"].contains(effort) ? "xhigh" : effort)
                let input = try input(request)
                XCTAssertEqual(input.additionalContext?["reasoning_effort"] as? String, expected)
                // Thinking-on exercises the vendor's closed effort validation;
                // the provider's normal thinking-off prompt bypasses that branch.
                let thinking = try render(input, enableThinking: true)
                XCTAssertTrue(thinking.hasSuffix("<|im_start|>assistant\n<think>\n"))
                if expected != "medium" {
                    XCTAssertTrue(thinking.contains("Reasoning effort is set to \(expected)."))
                }
                let ordinary = try render(input)
                XCTAssertTrue(ordinary.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
                XCTAssertFalse(ordinary.contains("Reasoning effort is set to"))
            }
        }
    }

    func testLoadedIdentityScopesEffortAndHistoryToOfficialFamily() throws {
        let aliased = try request(model: "buyer-alias", effort: "high", history: true)
        // The loaded template resolves these traits before production rendering.
        aliased.outputState.resolve(RequestOutputTraits(toolGrammar: .qwen))
        let official = try input(aliased, loadedModel: Self.officialModel)
        XCTAssertEqual(official.additionalContext?["reasoning_effort"] as? String, "xhigh")
        XCTAssertTrue(try render(official).contains("PRESERVED_TOOL_REASONING"))
        let other = try input(request(model: Self.officialModel, effort: "high"),
                              loadedModel: "qwen/qwen3.6-35b-a3b")
        XCTAssertEqual(other.additionalContext?["reasoning_effort"] as? String, "high")
        for lookalike in ["other/Qwen3.8-27B", "Qwen/Qwen3.8-27B-Distill", "Qwen/Qwen3.8-Flash-Next"] {
            XCTAssertFalse(ChatCompletionRequest.usesQwen38Template(modelID: lookalike))
            XCTAssertEqual(try request(model: lookalike, effort: "max").templateReasoningEffort, "max")
        }
    }

    func testToolLoopPreservesOfficialReasoningAndFunctionXML() throws {
        let rendered = try render(input(request(history: true)))
        XCTAssertEqual(rendered.components(separatedBy: "PRESERVED_TOOL_REASONING").count, 2)
        XCTAssertTrue(rendered.contains("<think>\nPRESERVED_TOOL_REASONING\n</think>"))
        XCTAssertTrue(rendered.contains("<tool_call>\n<function=lookup>\n<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>"))
        XCTAssertTrue(rendered.contains("<tool_response>\nPARIS_RESULT\n</tool_response>"))
        for other in ["qwen/qwen3.6-35b-a3b", "qwen3-8b"] {
            let otherInput = try input(request(model: other, history: true))
            let messages = DefaultMessageGenerator().generate(from: otherInput)
            XCTAssertFalse(messages.contains { ($0["reasoning_content"] as? String) == "PRESERVED_TOOL_REASONING" })
        }
    }
}
