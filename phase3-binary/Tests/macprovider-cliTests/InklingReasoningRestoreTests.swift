import Foundation
import MacProviderCore
import MLXLMCommon
@testable import macprovider_cli
import XCTest

/// SPEC-018-R011 (#2467): Inkling 2's template replays every earlier
/// assistant turn's reasoning. When a client drops it, the provider puts back
/// the reasoning it generated for that turn, so the prompt is the one the
/// model wrote and the conversation cache prefix still matches.
final class InklingReasoningRestoreTests: XCTestCase {
    private let model = "thinkingmachines/inkling-2-mini"
    private let reasoning = "17*23 = 17*20 + 17*3 = 340 + 51."
    private let answer = "391"

    private func request(
        _ messages: [[String: Any]], model: String? = nil, key: String? = "conv:inkling-restore"
    ) throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": model ?? self.model, "messages": messages,
        ])).withConversationKey(key)
    }

    private var firstTurn: [[String: Any]] { [["role": "user", "content": "What is 17*23?"]] }

    /// The follow-up as a client that keeps only `content` sends it.
    private var secondTurn: [[String: Any]] {
        firstTurn + [["role": "assistant", "content": answer], ["role": "user", "content": "And 17*24?"]]
    }

    private func completion() -> CompletionResult {
        CompletionResult(
            content: answer, finishReason: "stop", promptTokens: 1, completionTokens: 9,
            settlementDisposition: .eligibleOwner, reasoningContent: reasoning, reasoningTokens: 6)
    }

    private func prompt(_ request: ChatCompletionRequest, history: AssistantReasoningHistory) throws -> String {
        let input = try ModelRuntime.userInput(for: request, reasoningHistory: history)
        return try Inkling2Encoding.render(
            messages: DefaultMessageGenerator().generate(from: input), tools: nil, additionalContext: nil)
    }

    func testRestoredTurnRendersAsGeneratedAndExtendsTheCachedPrefix() throws {
        let history = AssistantReasoningHistory()
        let first = try request(firstTurn)
        let firstPrompt = try prompt(first, history: history)
        ModelRuntime.recordHistoryReasoning(completion(), for: first, toolSelectionModelID: nil, into: history)
        XCTAssertEqual(history.count, 1)

        // The frames the model writes after the first prompt
        // (`ReasoningOutput.Inkling`): a thinking frame, a text frame, EOS.
        let generated = "<|message_model|><|content_thinking|>" + reasoning + "<|end_message|>"
            + "<|message_model|><|content_text|>" + answer + "<|end_message|><|content_model_end_sampling|>"

        let second = try request(secondTurn)
        let restored = try prompt(second, history: history)
        XCTAssertTrue(restored.hasPrefix(firstPrompt + generated), restored)
        XCTAssertTrue(restored.hasSuffix("<|message_user|><|content_text|>And 17*24?<|end_message|>"), restored)
        // One log line per request, however often its prompt renders.
        XCTAssertFalse(second.outputState.claimReasoningRestoreReport())

        // Without the store the rendered history diverges from the cached
        // tokens at the start of the assistant turn.
        let dropped = try prompt(try request(secondTurn), history: AssistantReasoningHistory())
        XCTAssertFalse(dropped.hasPrefix(firstPrompt + generated))
        XCTAssertTrue(dropped.hasPrefix(firstPrompt + "<|message_model|><|content_text|>" + answer), dropped)
        XCTAssertFalse(dropped.contains("<|content_thinking|>"))
    }

    func testClientReasoningIsRenderedAsSent() throws {
        let history = AssistantReasoningHistory()
        ModelRuntime.recordHistoryReasoning(completion(), for: try request(firstTurn), toolSelectionModelID: nil, into: history)
        var messages = secondTurn
        messages[1]["reasoning"] = "Client copy."
        let rendered = try prompt(try request(messages), history: history)
        XCTAssertTrue(rendered.contains("<|content_thinking|>Client copy.<|end_message|>"), rendered)
        XCTAssertFalse(rendered.contains(reasoning))
    }

    func testNoRestoreWithoutConversationKeyOrOnThePrivacyPath() throws {
        let history = AssistantReasoningHistory()
        ModelRuntime.recordHistoryReasoning(completion(), for: try request(firstTurn), toolSelectionModelID: nil, into: history)
        XCTAssertFalse(try prompt(try request(secondTurn, key: nil), history: history).contains("<|content_thinking|>"))
        let privacy = try request(secondTurn).withIngestProvenance(.privacy)
        XCTAssertFalse(try prompt(privacy, history: history).contains("<|content_thinking|>"))
        // Neither records either.
        let empty = AssistantReasoningHistory()
        ModelRuntime.recordHistoryReasoning(completion(), for: try request(firstTurn, key: nil), toolSelectionModelID: nil, into: empty)
        ModelRuntime.recordHistoryReasoning(
            completion(), for: try request(firstTurn).withIngestProvenance(.privacy), toolSelectionModelID: nil, into: empty)
        XCTAssertEqual(empty.count, 0)
    }

    func testFamiliesWhoseRendererDropsHistoryReasoningAreLeftAlone() throws {
        let llama = "meta-llama/llama-3.3-70b-instruct"
        let history = AssistantReasoningHistory()
        ModelRuntime.recordHistoryReasoning(
            completion(), for: try request(firstTurn, model: llama), toolSelectionModelID: nil, into: history)
        XCTAssertEqual(history.count, 0)
        history.record(model: llama, conversationKey: "conv:inkling-restore",
                       prefix: try request(firstTurn, model: llama).messages,
                       content: answer, toolCalls: nil, reasoning: reasoning)
        let input = try ModelRuntime.userInput(for: try request(secondTurn, model: llama), reasoningHistory: history)
        guard case .chat = input.prompt else {
            return XCTFail("A family without history reasoning keeps the structured chat path")
        }
    }

    func testHistoryReasoningFamilies() {
        for grammar: ToolCallGrammar in [.inkling2, .glm, .lfm2, .dsml] {
            XCTAssertTrue(ModelRuntime.rendersHistoryReasoning(grammar: grammar, modelID: "any"), "\(grammar)")
        }
        XCTAssertTrue(ModelRuntime.rendersHistoryReasoning(grammar: .qwen, modelID: "qwen/qwen3.8-27b"))
        XCTAssertFalse(ModelRuntime.rendersHistoryReasoning(grammar: .qwen, modelID: "qwen/qwen3.6-35b-a3b"))
        XCTAssertFalse(ModelRuntime.rendersHistoryReasoning(grammar: .llama3, modelID: "any"))
        XCTAssertFalse(ModelRuntime.rendersHistoryReasoning(grammar: nil, modelID: "any"))
    }
}
