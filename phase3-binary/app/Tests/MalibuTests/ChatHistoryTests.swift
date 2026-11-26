import XCTest
@testable import Malibu

@MainActor
final class ChatHistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func chat(_ prompt: String, updated: Date) -> SavedChat {
        SavedChat(id: UUID(), title: SavedChat.title(from: prompt), model: "fixture", createdAt: updated,
                  updatedAt: updated, turns: [SavedChatTurn(prompt: prompt, answer: "answer", complete: true)])
    }

    func testTitleIsTheFirstMessageOnOneLineCutToAboutSixtyCharacters() {
        XCTAssertEqual(SavedChat.title(from: "  Hello\n\n  world\t again  "), "Hello world again")
        XCTAssertEqual(SavedChat.title(from: String(repeating: "a", count: 60)), String(repeating: "a", count: 60))
        let long = SavedChat.title(from: String(repeating: "word ", count: 40))
        XCTAssertEqual(long.count, SavedChat.titleLimit)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(SavedChat.title(from: " \n "), "Untitled chat")
    }

    func testSavedFileIsOwnerOnlyAndRoundTrips() throws {
        let root = try directory()
        let store = ChatHistoryStore(directory: root)
        var saved = chat("Round trip", updated: Date(timeIntervalSince1970: 1_800_000_000.5))
        saved.turns.append(SavedChatTurn(prompt: "Next", answer: "Partial", complete: false,
                                         reasoning: "thinking", truncated: true, note: "Stopped.",
                                         tools: ["read_file notes.txt"]))
        try store.save(saved)
        let file = root.appendingPathComponent("\(saved.id.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(ChatHistoryStore(directory: root).load(saved.id), saved)
    }

    func testEmptyConversationIsNeverWritten() throws {
        let root = try directory()
        let store = ChatHistoryStore(directory: root)
        try store.save(SavedChat(id: UUID(), title: "Empty", model: "fixture", createdAt: Date(), updatedAt: Date(), turns: []))
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testListIsNewestFirstAndPrunedToTheCap() throws {
        let root = try directory()
        let store = ChatHistoryStore(directory: root)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var saved: [SavedChat] = []
        for index in 0...ChatHistoryStore.limit {
            let next = chat("Chat \(index)", updated: start.addingTimeInterval(TimeInterval(index)))
            saved.append(next)
            try store.save(next)
        }
        XCTAssertEqual(store.summaries.count, ChatHistoryStore.limit)
        XCTAssertEqual(store.summaries.first?.id, saved.last?.id)
        XCTAssertFalse(store.summaries.contains { $0.id == saved[0].id }, "The oldest chat is pruned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(saved[0].id.uuidString).json").path))
        let reloaded = ChatHistoryStore(directory: root)
        XCTAssertEqual(reloaded.summaries.map(\.id), store.summaries.map(\.id))
    }

    func testCorruptAndForeignFilesAreSkippedWhenTheIndexIsRebuilt() async throws {
        let root = try directory()
        let good = chat("Good", updated: Date())
        try ChatHistoryStore(directory: root).save(good)
        try Data("{not json".utf8).write(to: root.appendingPathComponent("\(UUID().uuidString).json"))
        try Data("[]".utf8).write(to: root.appendingPathComponent("notes.json"))
        // A file whose name and id disagree is not trusted either.
        var mismatched = chat("Mismatched", updated: Date())
        let data = try JSONEncoder().encode(mismatched)
        mismatched = chat("Other", updated: Date())
        try data.write(to: root.appendingPathComponent("\(mismatched.id.uuidString).json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(ChatHistoryStore.indexName))
        let store = ChatHistoryStore(directory: root)
        await store.rebuild?.value
        XCTAssertEqual(store.summaries.map(\.id), [good.id])
        XCTAssertNil(store.load(mismatched.id))
    }

    func testLaunchReadsOnlyTheIndexAndLoadsAChatWhenOpened() throws {
        let root = try directory()
        let saved = chat("Indexed", updated: Date())
        try ChatHistoryStore(directory: root).save(saved)
        // Launch must not decode chat files: a damaged chat still lists from the index.
        try Data("{damaged".utf8).write(to: root.appendingPathComponent("\(saved.id.uuidString).json"))
        let store = ChatHistoryStore(directory: root)
        XCTAssertNil(store.rebuild)
        XCTAssertEqual(store.summaries.map(\.id), [saved.id])
        XCTAssertNil(store.load(saved.id), "Opening reads the file and drops a damaged chat")
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertTrue(ChatHistoryStore(directory: root).summaries.isEmpty)
    }

    func testCorruptIndexIsRebuiltOffTheMainActor() async throws {
        let root = try directory()
        let first = chat("First", updated: Date(timeIntervalSince1970: 1_800_000_000))
        let second = chat("Second", updated: Date(timeIntervalSince1970: 1_800_000_100))
        let writer = ChatHistoryStore(directory: root)
        try writer.save(first); try writer.save(second)
        try Data("{corrupt".utf8).write(to: root.appendingPathComponent(ChatHistoryStore.indexName))
        let store = ChatHistoryStore(directory: root)
        var notified = false
        store.onChange = { notified = true }
        await store.rebuild?.value
        XCTAssertTrue(notified)
        XCTAssertEqual(store.summaries.map(\.id), [second.id, first.id])
        XCTAssertEqual(ChatHistoryStore.readIndex(root)?.map(\.id), [second.id, first.id], "The rebuilt index is written back")
    }

    func testChatSavedBeforeWebSearchStillLoads() throws {
        let saved = chat("Before search", updated: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "webSearch")
        let decoded = try JSONDecoder().decode(SavedChat.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNotEqual(decoded.webSearch, true)
        XCTAssertEqual(decoded.turns.map(\.prompt), ["Before search"])
        var enabled = saved
        enabled.webSearch = true
        let root = try directory()
        try ChatHistoryStore(directory: root).save(enabled)
        XCTAssertEqual(ChatHistoryStore(directory: root).load(enabled.id)?.webSearch, true)
    }

    func testChatSavedBeforeCitationsStillLoads() throws {
        let saved = chat("Before citations", updated: Date(timeIntervalSince1970: 1_800_000_000))
        var versioned = saved
        versioned.turns[0].versions = [ChatVersion(prompt: "Before citations", answer: "answer")]
        versioned.turns[0].activeVersion = 0
        let data = try JSONEncoder().encode(versioned)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var turns = try XCTUnwrap(object["turns"] as? [[String: Any]])
        XCTAssertNil(turns[0]["citations"])
        var versions = try XCTUnwrap(turns[0]["versions"] as? [[String: Any]])
        XCTAssertNil(versions[0]["citations"])
        versions[0].removeValue(forKey: "citations")
        turns[0]["versions"] = versions
        turns[0].removeValue(forKey: "citations")
        object["turns"] = turns
        let decoded = try JSONDecoder().decode(SavedChat.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.turns[0].citations)
        XCTAssertNil(decoded.turns[0].versions?.first?.citations)
        let root = try directory()
        var cited = saved
        cited.turns[0].citations = ["notes.txt"]
        try ChatHistoryStore(directory: root).save(cited)
        XCTAssertEqual(ChatHistoryStore(directory: root).load(cited.id)?.turns.first?.citations, ["notes.txt"])
    }

    func testDeleteRemovesTheFile() throws {
        let root = try directory()
        let store = ChatHistoryStore(directory: root)
        let saved = chat("Delete me", updated: Date())
        try store.save(saved)
        try store.delete(saved.id)
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertNil(store.load(saved.id))
        XCTAssertTrue(ChatHistoryStore(directory: root).summaries.isEmpty)
    }
}
