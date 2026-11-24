import Foundation
import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-018-R011 (#2467): the conversation cache purges its runtime's
/// reasoning history with the conversations, and fences out a record whose
/// request rendered before the purge. Each cache has its own store.
final class ConversationCacheReasoningHistoryPurgeTests: XCTestCase {
    private let model = "thinkingmachines/inkling-2-mini"
    private let opening = [ChatMessage(role: .user, content: "Weather in Oslo?")]

    private func record(_ history: AssistantReasoningHistory, key: String, fence: AssistantReasoningHistory.Fence? = nil) {
        history.record(model: model, conversationKey: key, prefix: opening, content: "Clear.", toolCalls: nil,
                       reasoning: "Recall it.", fence: fence ?? history.fence(conversationKey: key))
    }

    private func makeCache(_ history: AssistantReasoningHistory) -> ConversationCache {
        ConversationCache(memoryBudget: conversationCacheTestMemoryBudget(), reasoningHistory: history)
    }

    func testPurgeHotClearsTheKeysTurnsAndFencesItsRecords() async {
        let history = AssistantReasoningHistory()
        let cache = makeCache(history)
        record(history, key: "conv:a")
        record(history, key: "conv:b")
        let rendered = history.fence(conversationKey: "conv:a")
        await cache.purgeHot(conversationKey: " conv:a ")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.conversationByteCount(conversationKey: "conv:a"), 0)
        record(history, key: "conv:a", fence: rendered)
        XCTAssertEqual(history.count, 1)
        record(history, key: "conv:a")
        XCTAssertEqual(history.count, 2)
    }

    func testPurgeAllHotClearsTheStoreAndFencesEveryRecord() async {
        let history = AssistantReasoningHistory()
        let cache = makeCache(history)
        record(history, key: "conv:a")
        record(history, key: "conv:b")
        let rendered = history.fence(conversationKey: "conv:b")
        await cache.purgeAllHot()
        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(history.byteCount, 0)
        record(history, key: "conv:b", fence: rendered)
        XCTAssertEqual(history.count, 0)
    }

    /// A purge clears only the store of the cache it runs on.
    func testEachCacheOwnsItsStore() async {
        let mine = AssistantReasoningHistory()
        let theirs = AssistantReasoningHistory()
        let cache = makeCache(mine)
        _ = makeCache(theirs)
        record(mine, key: "conv:a")
        record(theirs, key: "conv:a")
        await cache.purgeAllHot()
        XCTAssertEqual(mine.count, 0)
        XCTAssertEqual(theirs.count, 1)
        XCTAssertFalse(makeCache(AssistantReasoningHistory()).reasoningHistory === cache.reasoningHistory)
        XCTAssertTrue(cache.reasoningHistory === mine)
        XCTAssertFalse(ConversationCache().reasoningHistory === ConversationCache().reasoningHistory)
    }
}
