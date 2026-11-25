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
    func testPreemptedTurnIsIncompleteAndModelContextRemainsBounded() async throws {
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
        // Every turn stays visible; only the request to the model is bounded.
        XCTAssertEqual(store.turns.count, 11)
        XCTAssertFalse(store.turns[0].complete)
        XCTAssertTrue(store.turns.dropFirst().allSatisfy(\.complete))
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies.last!) as? [String: Any])
        XCTAssertEqual((request["messages"] as? [[String: Any]])?.count, ChatStore.contextMessages + 1)
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
        XCTAssertEqual(store.turns.last?.tools, ["read_file note.txt"])
        XCTAssertEqual(transport.ports, [9042, 9042, 9042])
    }
    func testToolErrorIsReturnedToTheModelAndTheTurnContinues() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatToolError-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(String(repeating: "x", count: AgentWorkspace.fileByteLimit + 1).utf8).write(to: folder.appendingPathComponent("big.txt"))
        store.selectFolder(folder)
        store.agentMode = true
        await store.refresh(port: 9042)
        store.send("Read everything")
        try await waitUntil { transport.pending.count == 1 }
        transport.resolve(0, calls: [
            ChatToolCall(id: "big", name: "read_file", arguments: "{\"path\":\"big.txt\"}"),
            ChatToolCall(id: "escape", name: "read_file", arguments: "{\"path\":\"../outside\"}"),
            ChatToolCall(id: "bad", name: "read_file", arguments: "{\"file\":\"x\"}")
        ])
        try await waitUntil { transport.pending.count == 2 }
        XCTAssertTrue(store.isRunning, "Tool errors must not end the turn")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[1]) as? [String: Any])
        let tools = try XCTUnwrap(body["messages"] as? [[String: Any]]).filter { $0["role"] as? String == "tool" }
        XCTAssertEqual(tools.compactMap { $0["tool_call_id"] as? String }, ["big", "escape", "bad"])
        XCTAssertEqual(tools.compactMap { $0["content"] as? String },
                       [ChatStore.toolError(.limit), ChatStore.toolError(.unsafePath), ChatStore.toolError(.invalidTool)])
        XCTAssertTrue(tools.allSatisfy { ($0["content"] as? String)?.hasPrefix("error: ") == true })
        XCTAssertEqual(store.turns.last?.tools, ["read_file big.txt", "read_file ../outside", "read_file"])
        transport.resolve(1, calls: [ChatToolCall(id: "done", name: "finish_answer", arguments: "{\"answer\":\"Could not read big.txt\"}")])
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.turns.last?.answer, "Could not read big.txt")
        XCTAssertEqual(store.turns.last?.complete, true)
    }

    func testEachToolCallIsListedByNameAndPath() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatActivity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        store.selectFolder(folder)
        store.agentMode = true
        await store.refresh(port: 9042)
        store.send("List")
        try await waitUntil { transport.pending.count == 1 }
        transport.resolve(0, calls: [ChatToolCall(id: "list", name: "list_files", arguments: "{\"path\":\".\"}")])
        try await waitUntil { transport.pending.count == 2 }
        XCTAssertEqual(ChatStore.toolLine("list_files", ["path": "."]), "list_files .")
        XCTAssertEqual(ChatStore.toolLine("read_file", ["path": "README.md"]), "read_file README.md")
        XCTAssertEqual(store.turns.last?.tools, ["list_files ."])
        store.stop()
        transport.resolve(1, text: "ignored")
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
    // MARK: Saved history

    private func historyDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-history-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func jsonFiles(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
    }
    private func answer(_ store: ChatStore, _ transport: ControlledChatTransport, _ prompt: String, _ text: String) async throws {
        let index = transport.pending.count
        store.send(prompt)
        try await waitUntil { transport.pending.count == index + 1 }
        transport.pending[index].onText(text)
        transport.resolve(index, text: text)
        try await waitUntil { !store.isRunning }
    }

    func testNewChatSavesConversationAndAFreshStoreReloadsIt() async throws {
        let directory = try historyDirectory()
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        await store.refresh(port: 9042)
        try await answer(store, transport, "  What is MLX?\n", "An array framework.")
        let savedID = store.conversationID
        store.newConversation()
        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertNotEqual(store.conversationID, savedID)
        XCTAssertEqual(store.history.map(\.id), [savedID])
        XCTAssertEqual(store.history.first?.title, "What is MLX?")
        XCTAssertEqual(store.history.first?.model, "fixture")
        let file = directory.appendingPathComponent("\(savedID.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reopened = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        XCTAssertEqual(reopened.history.map(\.id), [savedID])
        await reopened.refresh(port: 9042)
        reopened.openConversation(savedID)
        XCTAssertEqual(reopened.turns.map(\.prompt), ["What is MLX?"])
        XCTAssertEqual(reopened.turns.map(\.answer), ["An array framework."])
        XCTAssertNil(reopened.notice)
        // Continuing sends the saved history to the model and updates the same file.
        try await answer(reopened, transport, "And Metal?", "A GPU API.")
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies.last!) as? [String: Any])
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["content"] as? String },
                       ["What is MLX?", "An array framework.", "And Metal?"])
        XCTAssertEqual(jsonFiles(directory).count, 1)
    }

    func testLongConversationIsSavedAndReloadedWithEveryTurn() async throws {
        let directory = try historyDirectory()
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        await store.refresh(port: 9042)
        for index in 1...20 { try await answer(store, transport, "question \(index)", "answer \(index)") }
        XCTAssertEqual(store.turns.count, 20)
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies.last!) as? [String: Any])
        XCTAssertEqual((request["messages"] as? [[String: Any]])?.count, ChatStore.contextMessages + 1)
        let id = store.conversationID
        store.newConversation()
        let reopened = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        reopened.openConversation(id)
        XCTAssertEqual(reopened.turns.map(\.prompt), (1...20).map { "question \($0)" })
        XCTAssertEqual(reopened.turns.map(\.answer), (1...20).map { "answer \($0)" })
    }

    func testEmptyConversationIsNotSaved() async throws {
        let directory = try historyDirectory()
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        await store.refresh(port: 9042)
        store.newConversation()
        store.newConversation()
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(jsonFiles(directory).isEmpty)
    }

    func testDeleteRemovesSavedChat() async throws {
        let directory = try historyDirectory()
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        await store.refresh(port: 9042)
        try await answer(store, transport, "first chat", "ok")
        let first = store.conversationID
        store.newConversation()
        try await answer(store, transport, "second chat", "ok")
        let second = store.conversationID
        store.deleteConversation(first)
        XCTAssertEqual(store.history.map(\.id), [second])
        XCTAssertEqual(store.turns.count, 1, "Deleting another chat keeps the open one")
        store.deleteConversation(second)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertTrue(jsonFiles(directory).isEmpty)
        XCTAssertTrue(ChatHistoryStore(directory: directory).summaries.isEmpty)
    }

    func testReopenedChatFromAnotherModelNamesBothModelsAndContinuesOnLoadedModel() async throws {
        let directory = try historyDirectory()
        let history = ChatHistoryStore(directory: directory)
        let id = UUID()
        try history.save(SavedChat(id: id, title: "Old", model: "old-model", createdAt: Date(), updatedAt: Date(),
                                   turns: [SavedChatTurn(prompt: "Old question", answer: "Old answer", complete: true)]))
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport, historyStore: history)
        await store.refresh(port: 9042)
        store.openConversation(id)
        XCTAssertEqual(store.notice, "This chat used old-model. Replies now come from fixture.")
        try await answer(store, transport, "New question", "New answer")
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies.last!) as? [String: Any])
        XCTAssertEqual(request["model"] as? String, "fixture")
        XCTAssertEqual((request["messages"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(history.load(id)?.model, "fixture")
    }

    func testLeavingAndReenteringTheScreenKeepsTheConversation() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        var snapshot = AgentSnapshot.empty
        snapshot.currentModelID = "fixture"; snapshot.currentModelLoaded = true
        store.providerChanged(to: ChatProviderIdentity(snapshot))
        await store.refresh(port: 9042)
        try await answer(store, transport, "keep me", "kept")
        store.close()
        store.providerChanged(to: ChatProviderIdentity(snapshot))
        XCTAssertEqual(store.turns.map(\.prompt), ["keep me"])
    }

    // MARK: Long replies and reasoning

    func testLengthFinishKeepsPartialAnswerAndContinueSendsIt() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        await store.refresh(port: 9042)
        store.send("Write a long story")
        try await waitUntil { transport.pending.count == 1 }
        let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[0]) as? [String: Any])
        XCTAssertEqual(first["max_tokens"] as? Int, ChatStore.maxTokens)
        transport.pending[0].onText("Once upon")
        transport.resolve(0, text: "Once upon", truncated: true)
        try await waitUntil { !store.isRunning }
        let turn = try XCTUnwrap(store.turns.last)
        XCTAssertEqual(turn.answer, "Once upon")
        XCTAssertTrue(turn.truncated)
        XCTAssertTrue(turn.complete)
        store.continueAnswer()
        try await waitUntil { transport.pending.count == 2 }
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[1]) as? [String: Any])
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(messages.compactMap { $0["content"] as? String },
                       ["Write a long story", "Once upon", ChatStore.continuePrompt])
        transport.resolve(1, text: " a time.")
        try await waitUntil { !store.isRunning }
        store.continueAnswer()
        XCTAssertEqual(transport.pending.count, 2, "Continue only follows a cut-off reply")
    }

    func testReasoningOnlyReplyIsShownSavedAndNeverSentBack() async throws {
        let directory = try historyDirectory()
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        await store.refresh(port: 9042)
        store.send("Think about it")
        try await waitUntil { transport.pending.count == 1 }
        transport.resolve(0, text: "", reasoning: "private chain of thought")
        try await waitUntil { !store.isRunning }
        XCTAssertNil(store.notice, "A reasoning-only reply is not an error")
        XCTAssertEqual(store.turns.last?.reasoning, "private chain of thought")
        XCTAssertEqual(store.turns.last?.complete, true)
        let saved = try XCTUnwrap(ChatHistoryStore(directory: directory).load(store.conversationID))
        XCTAssertEqual(saved.turns.first?.reasoning, "private chain of thought")
        store.send("Next")
        try await waitUntil { transport.pending.count == 2 }
        XCTAssertFalse(String(decoding: transport.bodies[1], as: UTF8.self).contains("private chain of thought"))
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
    func resolve(_ index: Int, text: String = "", calls: [ChatToolCall] = [], reasoning: String = "", truncated: Bool = false) {
        pending[index].continuation.resume(returning: ChatCompletion(text: text, calls: calls,
                                                                     reasoning: reasoning, truncated: truncated))
    }
}
