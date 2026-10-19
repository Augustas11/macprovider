import XCTest
@testable import Malibu

@MainActor
final class ChatStoreTests: XCTestCase {
    func testServingTransitionDoesNotInvalidateLocalConversationIdentity() {
        var snapshot = AgentSnapshot.empty
        snapshot.currentModelID = "fixture"
        snapshot.currentModelLoaded = true
        snapshot.serviceInstanceID = "process-1"
        snapshot.state = .idle
        let identity = ChatProviderIdentity(snapshot)
        snapshot.state = .serving
        XCTAssertEqual(ChatProviderIdentity(snapshot), identity)
        snapshot.state = .paused
        XCTAssertEqual(ChatProviderIdentity(snapshot), identity)
        snapshot.state = .reconnecting
        XCTAssertNotEqual(ChatProviderIdentity(snapshot), identity)
        snapshot.state = .serving
        snapshot.serviceInstanceID = "process-2"
        XCTAssertNotEqual(ChatProviderIdentity(snapshot), identity)
    }
    func testRefreshUsesConfiguredPortAndMissingPortFailsClosed() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        await store.refresh(port: nil)
        XCTAssertNil(store.capability); XCTAssertTrue(transport.ports.isEmpty)
        await store.refresh(port: 9042)
        XCTAssertEqual(transport.ports, [9042]); XCTAssertNotNil(store.capability)
    }
    func testStopIsImmediateAndStaleOutputCannotEnterNextTurn() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        await store.refresh(port: 9042)
        store.send("first")
        try await waitUntil { transport.pending.count == 1 }
        transport.pending[0].onText("partial")
        XCTAssertEqual(store.turns.last?.answer, "partial")
        store.stop()
        XCTAssertFalse(store.isRunning)
        store.send("second")
        try await waitUntil { transport.pending.count == 2 }
        transport.pending[0].onText(" stale")
        transport.resolve(0, text: "partial stale")
        transport.pending[1].onText("new answer")
        transport.resolve(1, text: "new answer")
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.turns.last?.answer, "new answer")
        XCTAssertEqual(store.turns.first?.answer, "partial")
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[1]) as? [String: Any])
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "Stopped exchanges must not enter model context")
    }
    func testPreemptedTurnIsIncompleteAndHistoryRemainsBounded() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        await store.refresh(port: 9042)
        store.send("preempt")
        try await waitUntil { transport.pending.count == 1 }
        transport.pending[0].continuation.resume(throwing: ChatFailure.preempted)
        try await waitUntil { !store.isRunning }
        XCTAssertFalse(store.turns[0].complete)
        XCTAssertEqual(store.notice, ChatFailure.preempted.localizedDescription)
        for index in 1...10 {
            store.send("message \(index)")
            try await waitUntil { transport.pending.count == index + 1 }
            transport.pending[index].onText("answer")
            transport.resolve(index, text: "answer")
            try await waitUntil { !store.isRunning }
        }
        XCTAssertEqual(store.turns.count, 8)
        XCTAssertTrue(store.turns.allSatisfy(\.complete))
    }
    func testFreshCapabilityChangeStopsBeforeInference() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        await store.refresh(port: 9042)
        transport.current = ChatCapability(model: "replacement", generation: 3, guaranteedTools: false)
        store.send("hello")
        try await waitUntil { !store.isRunning }
        XCTAssertTrue(transport.bodies.isEmpty)
        XCTAssertEqual(store.notice, ChatFailure.modelChanged.localizedDescription)
        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertNil(store.capability)
    }
    func testUnsupportedAgentAndOversizedPromptNeverReachTransport() async throws {
        let transport = ControlledChatTransport()
        transport.current = ChatCapability(model: "fixture", generation: 1, guaranteedTools: false)
        let store = ChatStore(transport: transport)
        await store.refresh(port: 9042)
        store.agentMode = true
        store.send("read files")
        XCTAssertFalse(store.isRunning)
        store.agentMode = false
        store.send(String(repeating: "x", count: ChatStore.maxPromptBytes + 1))
        XCTAssertFalse(store.isRunning); XCTAssertTrue(transport.bodies.isEmpty)
    }
    func testAgentRequiresToolSelectionAndReturnsValidatedAnswer() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatAgent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("selected content".utf8).write(to: folder.appendingPathComponent("note.txt"))
        store.selectFolder(folder)
        _ = try XCTUnwrap(store.folderName)
        store.agentMode = true
        await store.refresh(port: 9042)
        store.send("Summarize note.txt")
        try await waitUntil { transport.pending.count == 1 }
        transport.resolve(0, calls: [ChatToolCall(id: "read1", name: "read_file", arguments: "{\"path\":\"note.txt\"}")])
        try await waitUntil { transport.pending.count == 2 }
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[1]) as? [String: Any])
        XCTAssertEqual(body["tool_choice"] as? String, "required")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["role"] as? String, "tool")
        XCTAssertEqual(messages.last?["content"] as? String, "selected content")
        transport.resolve(1, calls: [ChatToolCall(id: "finish", name: "finish_answer", arguments: "{\"answer\":\"Summary of selected content\"}")])
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.turns.last?.answer, "Summary of selected content")
        XCTAssertEqual(store.turns.last?.complete, true)
        XCTAssertEqual(transport.ports, [9042, 9042, 9042])
    }
    func testAgentRoundLimitStopsRepeatedToolLoop() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatLimit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        store.selectFolder(folder)
        _ = try XCTUnwrap(store.folderName)
        store.agentMode = true
        await store.refresh(port: 9042)
        store.send("keep listing")
        for index in 0..<ChatStore.maxRounds {
            try await waitUntil { transport.pending.count == index + 1 }
            transport.resolve(index, calls: [ChatToolCall(id: "list\(index)", name: "list_files", arguments: "{\"path\":\".\"}")])
        }
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.notice, ChatFailure.limit.localizedDescription)
        XCTAssertFalse(store.turns.last?.complete ?? true)
    }
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("State did not settle", file: file, line: line)
        throw ChatFailure.timeout
    }
}

@MainActor
private final class ControlledChatTransport: ChatTransport {
    struct Pending {
        let onText: @MainActor (String) -> Void
        let continuation: CheckedContinuation<ChatCompletion, Error>
    }
    var current = ChatCapability(model: "fixture", generation: 1, guaranteedTools: true)
    var ports: [Int] = []
    var bodies: [Data] = []
    var pending: [Pending] = []
    func capability(at endpoint: ChatEndpoint) async throws -> ChatCapability {
        ports.append(endpoint.port); return current
    }
    func complete(at endpoint: ChatEndpoint, body: Data,
                  onText: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion {
        bodies.append(body)
        return try await withCheckedThrowingContinuation { pending.append(Pending(onText: onText, continuation: $0)) }
    }
    func resolve(_ index: Int, text: String = "", calls: [ChatToolCall] = []) {
        pending[index].continuation.resume(returning: ChatCompletion(text: text, calls: calls))
    }
}
