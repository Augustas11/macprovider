import Foundation
import XCTest
@testable import MacProviderCore

/// SPEC-018-R011 (#2467): the provider keeps the reasoning of turns it
/// generated and puts it back on the same turn when a client drops it.
final class AssistantReasoningHistoryTests: XCTestCase {
    private let model = "thinkingmachines/inkling-2-mini"
    private let key = "conv:account-a"

    private let opening: [ChatMessage] = [
        ChatMessage(role: .system, content: "You are terse."),
        ChatMessage(role: .user, content: "Weather in Oslo?"),
    ]
    private let call = ToolCall(id: "call_0123456789abcdef", functionName: "weather", arguments: #"{"city":"Oslo","units":"c"}"#)

    private func recordFirstTurn(_ history: AssistantReasoningHistory, reasoning: String = "Use the tool.") {
        history.record(model: model, conversationKey: key, prefix: opening,
                       content: "", toolCalls: [call], reasoning: reasoning)
    }

    /// The follow-up as a client that dropped reasoning sends it.
    private func followUp(call: ToolCall? = nil, content: String? = nil) -> [ChatMessage] {
        opening + [
            ChatMessage(role: .assistant, content: content, toolCalls: [call ?? self.call]),
            ChatMessage(role: .tool, content: "Clear", toolCallID: (call ?? self.call).id),
        ]
    }

    func testRestoresTheRecordedTurn() throws {
        let history = AssistantReasoningHistory()
        recordFirstTurn(history)
        let restored = try XCTUnwrap(history.restoring(followUp(), model: model, conversationKey: key))
        XCTAssertEqual(restored.turns, 1)
        XCTAssertEqual(restored.bytes, "Use the tool.".utf8.count)
        XCTAssertEqual(restored.messages.count, 4)
        XCTAssertEqual(restored.messages[2].reasoningContent, "Use the tool.")
        XCTAssertEqual(restored.messages[2].toolCalls, [call])
        XCTAssertNil(restored.messages[2].content)
        for index in [0, 1, 3] {
            XCTAssertNil(restored.messages[index].reasoningContent)
            XCTAssertEqual(restored.messages[index].content, followUp()[index].content)
        }
    }

    func testMatchesWhatClientsChangeButNotTheTurn() throws {
        let history = AssistantReasoningHistory()
        recordFirstTurn(history)
        // A new call ID, re-encoded arguments and "" for null content still match.
        let reencoded = ToolCall(id: "call_ffffffffffffffff", functionName: "weather", arguments: #"{ "units": "c", "city": "Oslo" }"#)
        XCTAssertNotNil(history.restoring(followUp(call: reencoded, content: ""), model: model, conversationKey: key))
        // Different arguments, name or content are a different turn.
        let other = ToolCall(id: call.id, functionName: "weather", arguments: #"{"city":"Bergen","units":"c"}"#)
        XCTAssertNil(history.restoring(followUp(call: other), model: model, conversationKey: key))
        let renamed = ToolCall(id: call.id, functionName: "forecast", arguments: call.arguments)
        XCTAssertNil(history.restoring(followUp(call: renamed), model: model, conversationKey: key))
        XCTAssertNil(history.restoring(followUp(content: "Checking."), model: model, conversationKey: key))
    }

    func testAssistantContentComparesTrimmed() throws {
        let history = AssistantReasoningHistory()
        history.record(model: model, conversationKey: key, prefix: opening,
                       content: "Clear skies.\n", toolCalls: nil, reasoning: "Recall it.")
        let messages = opening + [ChatMessage(role: .assistant, content: "Clear skies."), ChatMessage(role: .user, content: "Thanks")]
        XCTAssertEqual(history.restoring(messages, model: model, conversationKey: key)?.messages[2].reasoningContent, "Recall it.")
    }

    func testScopedToConversationKeyModelAndPrefix() {
        let history = AssistantReasoningHistory()
        recordFirstTurn(history)
        XCTAssertNil(history.restoring(followUp(), model: model, conversationKey: "conv:account-b"))
        XCTAssertNil(history.restoring(followUp(), model: "zai-org/glm-5.3-flash", conversationKey: key))
        XCTAssertNil(history.restoring(followUp(), model: model, conversationKey: nil))
        var edited = followUp()
        edited[1] = ChatMessage(role: .user, content: "Weather in Bergen?")
        XCTAssertNil(history.restoring(edited, model: model, conversationKey: key))
        // The key compares trimmed, as the conversation cache keys it.
        XCTAssertNotNil(history.restoring(followUp(), model: model, conversationKey: " \(key) "))
    }

    func testNothingIsRecordedWithoutKeyOrReasoning() {
        let history = AssistantReasoningHistory()
        history.record(model: model, conversationKey: nil, prefix: opening, content: "", toolCalls: [call], reasoning: "x")
        history.record(model: model, conversationKey: "  ", prefix: opening, content: "", toolCalls: [call], reasoning: "x")
        history.record(model: model, conversationKey: key, prefix: opening, content: "", toolCalls: [call], reasoning: nil)
        history.record(model: model, conversationKey: key, prefix: opening, content: "", toolCalls: [call], reasoning: "")
        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(history.byteCount, 0)
    }

    func testClientReasoningIsKept() {
        let history = AssistantReasoningHistory()
        recordFirstTurn(history)
        var messages = followUp()
        messages[2] = ChatMessage(role: .assistant, content: nil, toolCalls: [call], reasoningContent: "Client copy.")
        XCTAssertNil(history.restoring(messages, model: model, conversationKey: key))
        // An empty string is no reasoning.
        messages[2] = ChatMessage(role: .assistant, content: nil, toolCalls: [call], reasoningContent: "")
        XCTAssertEqual(history.restoring(messages, model: model, conversationKey: key)?.messages[2].reasoningContent, "Use the tool.")
    }

    /// Turn 2 is recorded with turn 1 in its prefix as the client sent it
    /// (without reasoning); turn 3 restores both.
    func testRestoresEveryTurnOfAConversation() throws {
        let history = AssistantReasoningHistory()
        recordFirstTurn(history, reasoning: "First.")
        let second = followUp()
        history.record(model: model, conversationKey: key, prefix: second,
                       content: "Clear in Oslo.", toolCalls: nil, reasoning: "Second.")
        let third = second + [ChatMessage(role: .assistant, content: "Clear in Oslo."), ChatMessage(role: .user, content: "And tomorrow?")]
        let restored = try XCTUnwrap(history.restoring(third, model: model, conversationKey: key))
        XCTAssertEqual(restored.turns, 2)
        XCTAssertEqual(restored.messages[2].reasoningContent, "First.")
        XCTAssertEqual(restored.messages[4].reasoningContent, "Second.")
        XCTAssertEqual(restored.bytes, "First.Second.".utf8.count)
        // A client that kept turn 1's reasoning still gets turn 2 back.
        var mixed = third
        mixed[2] = ChatMessage(role: .assistant, content: nil, toolCalls: [call], reasoningContent: "First.")
        XCTAssertEqual(history.restoring(mixed, model: model, conversationKey: key)?.turns, 1)
    }

    func testEntryCountIsBoundedLeastRecentlyUsedFirst() {
        let history = AssistantReasoningHistory(limits: .init(maxEntries: 2, maxBytes: 1 << 20, maxEntryBytes: 1 << 20, ttlSeconds: 3600))
        func turn(_ n: Int) -> [ChatMessage] { [ChatMessage(role: .user, content: "q\(n)")] }
        func ask(_ n: Int) -> [ChatMessage] { turn(n) + [ChatMessage(role: .assistant, content: "a\(n)")] }
        for n in 0..<2 {
            history.record(model: model, conversationKey: key, prefix: turn(n), content: "a\(n)", toolCalls: nil, reasoning: "r\(n)")
        }
        // Using turn 0 makes turn 1 the least recently used.
        XCTAssertNotNil(history.restoring(ask(0), model: model, conversationKey: key))
        history.record(model: model, conversationKey: key, prefix: turn(2), content: "a2", toolCalls: nil, reasoning: "r2")
        XCTAssertEqual(history.count, 2)
        XCTAssertNotNil(history.restoring(ask(0), model: model, conversationKey: key))
        XCTAssertNil(history.restoring(ask(1), model: model, conversationKey: key))
        XCTAssertNotNil(history.restoring(ask(2), model: model, conversationKey: key))
    }

    func testBytesAreBounded() {
        let overhead = AssistantReasoningHistory.entryOverheadBytes
        let history = AssistantReasoningHistory(limits: .init(
            maxEntries: 100, maxBytes: 2 * (overhead + 10), maxEntryBytes: overhead + 10, ttlSeconds: 3600))
        func turn(_ n: Int) -> [ChatMessage] { [ChatMessage(role: .user, content: "q\(n)")] }
        // Over the per-entry cap: not stored.
        history.record(model: model, conversationKey: key, prefix: turn(9), content: "a", toolCalls: nil, reasoning: String(repeating: "x", count: 11))
        XCTAssertEqual(history.count, 0)
        for n in 0..<3 {
            history.record(model: model, conversationKey: key, prefix: turn(n), content: "a", toolCalls: nil, reasoning: String(repeating: "x", count: 10))
        }
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.byteCount, 2 * (overhead + 10))
        XCTAssertNil(history.restoring(turn(0) + [ChatMessage(role: .assistant, content: "a")], model: model, conversationKey: key))
        // Re-recording a turn replaces it without double-counting.
        history.record(model: model, conversationKey: key, prefix: turn(2), content: "a", toolCalls: nil, reasoning: String(repeating: "y", count: 10))
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.byteCount, 2 * (overhead + 10))
    }

    func testIdleEntriesExpire() {
        let clock = TestClock()
        let history = AssistantReasoningHistory(
            limits: .init(maxEntries: 10, maxBytes: 1 << 20, maxEntryBytes: 1 << 20, ttlSeconds: 60),
            now: { clock.now })
        recordFirstTurn(history)
        clock.advance(59)
        XCTAssertNotNil(history.restoring(followUp(), model: model, conversationKey: key))
        clock.advance(61)
        XCTAssertNil(history.restoring(followUp(), model: model, conversationKey: key))
        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(history.byteCount, 0)
    }

    func testPurgeDropsOneConversationAndRemoveAllDropsEvery() {
        let history = AssistantReasoningHistory()
        recordFirstTurn(history)
        history.record(model: "zai-org/glm-5.3-flash", conversationKey: key, prefix: opening, content: "", toolCalls: [call], reasoning: "GLM.")
        history.record(model: model, conversationKey: "conv:account-b", prefix: opening, content: "", toolCalls: [call], reasoning: "B.")
        history.purge(conversationKey: " \(key)")
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history.restoring(followUp(), model: model, conversationKey: key))
        XCTAssertNotNil(history.restoring(followUp(), model: model, conversationKey: "conv:account-b"))
        history.removeAll()
        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(history.byteCount, 0)
    }

    func testReasoningAliasParses() throws {
        func parse(_ assistant: [String: Any]) throws -> ChatMessage {
            var message = assistant
            message["role"] = "assistant"
            message["content"] = "Blue."
            return try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
                "model": "m", "messages": [["role": "user", "content": "pick"], message, ["role": "user", "content": "why"]],
            ])).messages[1]
        }
        XCTAssertEqual(try parse(["reasoning_content": "a"]).reasoningContent, "a")
        XCTAssertEqual(try parse(["reasoning": "b"]).reasoningContent, "b")
        XCTAssertEqual(try parse(["reasoning_content": "a", "reasoning": "b"]).reasoningContent, "a")
        XCTAssertNil(try parse(["reasoning": ["effort": "high"]]).reasoningContent)
        XCTAssertNil(try parse([:]).reasoningContent)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current += seconds
        lock.unlock()
    }
}
