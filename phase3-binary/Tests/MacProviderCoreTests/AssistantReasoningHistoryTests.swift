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

    /// Many uses between evictions leave stale queue tickets behind; the
    /// order stays least recently used first after the queues compact.
    func testLeastRecentlyUsedOrderSurvivesManyUses() {
        let history = AssistantReasoningHistory(limits: .init(maxEntries: 3, maxBytes: 1 << 20, maxEntryBytes: 1 << 20, ttlSeconds: 3600))
        func turn(_ n: Int) -> [ChatMessage] { [ChatMessage(role: .user, content: "q\(n)")] }
        func ask(_ n: Int) -> [ChatMessage] { turn(n) + [ChatMessage(role: .assistant, content: "a\(n)")] }
        for n in 0..<3 {
            history.record(model: model, conversationKey: key, prefix: turn(n), content: "a\(n)", toolCalls: nil, reasoning: "r\(n)")
        }
        for round in 0..<500 {
            XCTAssertNotNil(history.restoring(ask(round % 2 == 0 ? 0 : 2), model: model, conversationKey: key))
        }
        // Turn 1 was never used again: it goes first.
        history.record(model: model, conversationKey: key, prefix: turn(3), content: "a3", toolCalls: nil, reasoning: "r3")
        XCTAssertNil(history.restoring(ask(1), model: model, conversationKey: key))
        XCTAssertEqual(history.count, 3)
        // Then turn 0 (used before turn 2 in the last round).
        history.record(model: model, conversationKey: key, prefix: turn(4), content: "a4", toolCalls: nil, reasoning: "r4")
        XCTAssertNil(history.restoring(ask(0), model: model, conversationKey: key))
        XCTAssertNotNil(history.restoring(ask(2), model: model, conversationKey: key))
    }

    func testBytesAreBoundedInTotalAndPerConversation() {
        let overhead = AssistantReasoningHistory.entryOverheadBytes
        let entry = overhead + 10
        // An eighth of the total is two entries per conversation.
        let history = AssistantReasoningHistory(limits: .init(
            maxEntries: 100, maxBytes: 16 * entry, maxEntryBytes: 10, ttlSeconds: 3600))
        func turn(_ n: Int) -> [ChatMessage] { [ChatMessage(role: .user, content: "q\(n)")] }
        let ten = String(repeating: "x", count: 10)
        // Over the per-entry reasoning cap: not stored; exactly at it: stored.
        history.record(model: model, conversationKey: key, prefix: turn(99), content: "a", toolCalls: nil, reasoning: ten + "x")
        XCTAssertEqual(history.count, 0)
        for n in 0..<3 {
            history.record(model: model, conversationKey: key, prefix: turn(n), content: "a", toolCalls: nil, reasoning: ten)
        }
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.conversationByteCount(conversationKey: key), 2 * entry)
        XCTAssertNil(history.restoring(turn(0) + [ChatMessage(role: .assistant, content: "a")], model: model, conversationKey: key))
        XCTAssertNotNil(history.restoring(turn(2) + [ChatMessage(role: .assistant, content: "a")], model: model, conversationKey: key))
        // Re-recording a turn replaces it without double-counting.
        history.record(model: model, conversationKey: key, prefix: turn(2), content: "a", toolCalls: nil, reasoning: String(repeating: "y", count: 10))
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.byteCount, 2 * entry)
        // Nine conversations of two turns each: the total holds sixteen.
        for conversation in 0..<9 {
            for n in 0..<2 {
                history.record(model: model, conversationKey: "conv:\(conversation)", prefix: turn(n), content: "a", toolCalls: nil, reasoning: ten)
            }
        }
        XCTAssertEqual(history.count, 16)
        XCTAssertEqual(history.byteCount, 16 * entry)
        XCTAssertEqual(history.conversationByteCount(conversationKey: "conv:8"), 2 * entry)
    }

    func testStandardEntryCapIsExactlyOneMebibyteOfReasoning() {
        let history = AssistantReasoningHistory()
        history.record(model: model, conversationKey: key, prefix: opening, content: "", toolCalls: [call],
                       reasoning: String(repeating: "x", count: (1 << 20) + 1))
        XCTAssertEqual(history.count, 0)
        history.record(model: model, conversationKey: key, prefix: opening, content: "", toolCalls: [call],
                       reasoning: String(repeating: "x", count: 1 << 20))
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.byteCount, (1 << 20) + AssistantReasoningHistory.entryOverheadBytes)
        XCTAssertEqual(AssistantReasoningHistory.Limits.standard.maxConversationBytes, 4 << 20)
        XCTAssertEqual(AssistantReasoningHistory.Limits.standard.maxRestoreBytes, 256 << 10)
    }

    /// The newest turns are restored first; the first turn over the
    /// per-request cap ends the restore.
    func testRestoreIsCappedPerRequestNewestFirst() throws {
        let history = AssistantReasoningHistory(limits: .init(
            maxEntries: 10, maxBytes: 1 << 20, maxEntryBytes: 1 << 20, maxRestoreBytes: 10, ttlSeconds: 3600))
        var messages: [ChatMessage] = [ChatMessage(role: .user, content: "q0")]
        for n in 0..<3 {
            history.record(model: model, conversationKey: key, prefix: messages, content: "a\(n)", toolCalls: nil, reasoning: "rrr\(n)")
            messages += [ChatMessage(role: .assistant, content: "a\(n)"), ChatMessage(role: .user, content: "q\(n + 1)")]
        }
        let restored = try XCTUnwrap(history.restoring(messages, model: model, conversationKey: key))
        XCTAssertEqual(restored.turns, 2)
        XCTAssertEqual(restored.bytes, 8)
        XCTAssertNil(restored.messages[1].reasoningContent)
        XCTAssertEqual(restored.messages[3].reasoningContent, "rrr1")
        XCTAssertEqual(restored.messages[5].reasoningContent, "rrr2")
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
        // A record sweeps idle entries too.
        recordFirstTurn(history)
        clock.advance(61)
        history.record(model: model, conversationKey: "conv:other", prefix: opening, content: "", toolCalls: [call], reasoning: "x")
        XCTAssertEqual(history.count, 1)
    }

    func testNegativeTTLIsClampedToZero() {
        XCTAssertEqual(AssistantReasoningHistory.Limits(maxEntries: 1, maxBytes: 1, maxEntryBytes: 1, ttlSeconds: -5).ttlSeconds, 0)
        XCTAssertEqual(AssistantReasoningHistory.Limits(maxEntries: 1, maxBytes: 1, maxEntryBytes: 1, ttlSeconds: .nan).ttlSeconds, 0)
        let clock = TestClock()
        let history = AssistantReasoningHistory(
            limits: .init(maxEntries: 10, maxBytes: 1 << 20, maxEntryBytes: 1 << 20, ttlSeconds: -60),
            now: { clock.now })
        recordFirstTurn(history)
        // Not expired at once (a negative TTL would expire every entry).
        XCTAssertNotNil(history.restoring(followUp(), model: model, conversationKey: key))
        clock.advance(1)
        XCTAssertNil(history.restoring(followUp(), model: model, conversationKey: key))
    }

    func testPurgeDropsOneConversationAndRemoveAllDropsEvery() {
        let history = AssistantReasoningHistory()
        recordFirstTurn(history)
        history.record(model: "zai-org/glm-5.3-flash", conversationKey: key, prefix: opening, content: "", toolCalls: [call], reasoning: "GLM.")
        history.record(model: model, conversationKey: "conv:account-b", prefix: opening, content: "", toolCalls: [call], reasoning: "B.")
        history.purge(conversationKey: " \(key)")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.conversationByteCount(conversationKey: key), 0)
        XCTAssertNil(history.restoring(followUp(), model: model, conversationKey: key))
        XCTAssertNotNil(history.restoring(followUp(), model: model, conversationKey: "conv:account-b"))
        history.removeAll()
        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(history.byteCount, 0)
    }

    /// A turn whose request rendered before a purge of its key never
    /// records after it; other keys and later requests record.
    func testRecordRacingAPurgeIsFencedOut() {
        let history = AssistantReasoningHistory()
        let rendered = history.fence(conversationKey: key)
        let otherRendered = history.fence(conversationKey: "conv:account-b")
        history.purge(conversationKey: key)
        history.record(model: model, conversationKey: key, prefix: opening, content: "", toolCalls: [call],
                       reasoning: "Stale.", fence: rendered)
        XCTAssertEqual(history.count, 0)
        history.record(model: model, conversationKey: "conv:account-b", prefix: opening, content: "", toolCalls: [call],
                       reasoning: "B.", fence: otherRendered)
        XCTAssertEqual(history.count, 1)
        history.record(model: model, conversationKey: key, prefix: opening, content: "", toolCalls: [call],
                       reasoning: "Fresh.", fence: history.fence(conversationKey: " \(key) "))
        XCTAssertEqual(history.count, 2)
    }

    func testRecordRacingRemoveAllIsFencedOut() {
        let history = AssistantReasoningHistory()
        let rendered = history.fence(conversationKey: key)
        history.removeAll()
        history.record(model: model, conversationKey: key, prefix: opening, content: "", toolCalls: [call],
                       reasoning: "Stale.", fence: rendered)
        XCTAssertEqual(history.count, 0)
        XCTAssertNotEqual(rendered, history.fence(conversationKey: key))
        recordFirstTurn(history)
        XCTAssertEqual(history.count, 1)
    }

    /// One lookup per request: later renders reuse it even when the store
    /// changes in between, and a withdrawn restore renders as sent.
    func testRequestStatePinsOneRestore() throws {
        let history = AssistantReasoningHistory()
        recordFirstTurn(history, reasoning: "First.")
        let state = ReasoningHistoryRequestState()
        XCTAssertNil(state.restore(followUp(), model: model, conversationKey: key))
        XCTAssertNil(state.recordTarget())
        state.attach(history)
        XCTAssertEqual(state.restore(followUp(), model: model, conversationKey: key)?.messages[2].reasoningContent, "First.")
        XCTAssertTrue(state.isRestoring)
        // A regenerated turn overwrites the stored reasoning; this request
        // keeps the restore it rendered first.
        recordFirstTurn(history, reasoning: "Second.")
        XCTAssertEqual(state.restore(followUp(), model: model, conversationKey: key)?.messages[2].reasoningContent, "First.")
        history.removeAll()
        XCTAssertEqual(state.restore(followUp(), model: model, conversationKey: key)?.messages[2].reasoningContent, "First.")
        // The fence is the one the first render saw.
        let target = try XCTUnwrap(state.recordTarget())
        XCTAssertNotEqual(target.fence, history.fence(conversationKey: key))
        state.noteRestoredPromptTokens(12)
        XCTAssertEqual(state.restoredPromptTokens, 12)
        state.withdraw()
        XCTAssertNil(state.restore(followUp(), model: model, conversationKey: key))
        XCTAssertFalse(state.isRestoring)
        XCTAssertEqual(state.restoredPromptTokens, 0)
        state.noteRestoredPromptTokens(12)
        XCTAssertEqual(state.restoredPromptTokens, 0)
        XCTAssertTrue(state.claimReport())
        XCTAssertFalse(state.claimReport())
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
        // An empty reasoning_content counts as absent.
        XCTAssertEqual(try parse(["reasoning_content": "", "reasoning": "b"]).reasoningContent, "b")
        XCTAssertEqual(try parse(["reasoning_content": ""]).reasoningContent, "")
        XCTAssertNil(try parse(["reasoning": ["effort": "high"]]).reasoningContent)
        XCTAssertNil(try parse([:]).reasoningContent)
    }
}

private extension AssistantReasoningHistory {
    /// A record under the purge state at the call.
    func record(
        model: String, conversationKey: String?, prefix: [ChatMessage],
        content: String?, toolCalls: [ToolCall]?, reasoning: String?
    ) {
        record(model: model, conversationKey: conversationKey, prefix: prefix, content: content,
               toolCalls: toolCalls, reasoning: reasoning, fence: fence(conversationKey: conversationKey))
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
