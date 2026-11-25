import UniformTypeIdentifiers
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
        XCTAssertEqual(store.turns.map(\.prompt), ["hello"])
        await store.refresh(port: 9042)
        XCTAssertEqual(store.turns.map(\.prompt), ["hello"], "A loaded-model change keeps the conversation")
        XCTAssertEqual(store.capability?.model, "replacement")
    }

    func testNetworkModelKeepsTheConversation() async throws {
        let transport = ControlledChatTransport()
        let gateway = FakeChatGateway()
        gateway.models = [ConnectedModel(id: "net-model", contextWindow: 8192, maxOutputTokens: 1024, supportsTools: false)]
        let store = ChatStore(transport: transport, gateway: gateway, buyerKey: { "buyer" })
        await store.refresh(port: 9042)
        try await answer(store, transport, "local question", "local answer")
        await store.refreshNetworkModels()
        store.route = .network("net-model")
        XCTAssertEqual(store.turns.count, 1)
        store.send("next")
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.turns.map(\.prompt), ["local question", "next"])
        XCTAssertEqual(store.turns.last?.answer, "network answer")
        XCTAssertEqual(transport.bodies.count, 1)
        let body = try XCTUnwrap(gateway.bodies.last)
        XCTAssertEqual(body["model"] as? String, "net-model")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? String },
                       ["local question", "local answer", "next"])
        let missing = ChatStore(transport: transport, gateway: gateway, buyerKey: { throw ConnectedAppsError.credential })
        await missing.refresh(port: 9042)
        try await answer(missing, transport, "stay", "put")
        await missing.refreshNetworkModels()
        missing.route = .network("net-model")
        missing.send("again")
        XCTAssertEqual(missing.notice, "Save a buyer key in Connected apps to use a network model.")
        XCTAssertEqual(missing.turns.map(\.prompt), ["stay"])
        XCTAssertEqual(gateway.bodies.count, 1)
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
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") && $0 != ChatHistoryStore.indexName }
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

    func testHistoryIsSizedToTheModelContext() async throws {
        let unknown = ChatCapability(model: "fixture", generation: 1, guaranteedTools: false)
        XCTAssertEqual(ChatStore.contextBytes(for: unknown), ChatStore.defaultContextBytes)
        XCTAssertEqual(ChatStore.outputTokens(for: unknown), ChatStore.maxTokens)
        let large = ChatCapability(model: "fixture", generation: 1, guaranteedTools: false, maxContextTokens: 32768)
        XCTAssertEqual(ChatStore.outputTokens(for: large), 8192)
        XCTAssertEqual(ChatStore.contextBytes(for: large), (32768 - 8192) * 3)
        let small = ChatCapability(model: "fixture", generation: 1, guaranteedTools: false, maxContextTokens: 4096)
        XCTAssertEqual(ChatStore.outputTokens(for: small), 2048)
        XCTAssertEqual(ChatStore.contextBytes(for: small), 2048 * 3)

        let transport = ControlledChatTransport()
        transport.current = small
        let store = ChatStore(transport: transport)
        await store.refresh(port: 9042)
        let long = String(repeating: "x", count: 7000)
        try await answer(store, transport, "first", long)
        try await answer(store, transport, "second", "short")
        store.send("third")
        try await waitUntil { transport.pending.count == 3 }
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[2]) as? [String: Any])
        XCTAssertEqual(request["max_tokens"] as? Int, 2048)
        XCTAssertEqual((request["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? String },
                       ["second", "short", "third"], "The turn that no longer fits the context is left out")
        XCTAssertEqual(store.contextNote, ChatStore.contextOmittedNote)
        transport.pending[2].continuation.resume(throwing: ChatFailure.contextTooLong)
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.notice, ChatFailure.contextTooLong.localizedDescription)
        XCTAssertEqual(store.turns.count, 3, "The conversation itself is kept")
    }

    func testAnswerStatsAreShownFromUsageAndSaved() async throws {
        let directory = try historyDirectory()
        let transport = ControlledChatTransport()
        transport.current = ChatCapability(model: "fixture", generation: 1, guaranteedTools: false, maxContextTokens: 8192)
        let store = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        await store.refresh(port: 9042)
        store.send("hello")
        try await waitUntil { transport.pending.count == 1 }
        transport.resolve(0, text: "hello there", promptTokens: 30, completionTokens: 12, decodeMilliseconds: 400)
        try await waitUntil { !store.isRunning }
        let turn = try XCTUnwrap(store.turns.last)
        XCTAssertEqual(turn.completionTokens, 12)
        XCTAssertEqual(turn.promptTokens, 30)
        XCTAssertEqual(turn.tokensPerSecond, 30)
        XCTAssertEqual(store.contextUsedTokens, 30)
        XCTAssertEqual(store.contextLimitTokens, 8192)
        XCTAssertNil(store.contextNote)
        let saved = try XCTUnwrap(ChatHistoryStore(directory: directory).load(store.conversationID))
        XCTAssertEqual(saved.turns.last?.completionTokens, 12)
        XCTAssertEqual(saved.turns.last?.tokensPerSecond, 30)
    }

    func testSettingsReachTheRequestAndRoundTrip() async throws {
        let directory = try historyDirectory()
        var settings = ChatSettings()
        settings.systemPrompt = "Be brief."
        settings.presetID = "precise"
        settings.sampling.temperature = 0.5
        settings.sampling.topP = 0.25
        settings.sampling.topK = 40
        settings.sampling.seed = 7
        settings.sampling.stop = ["END"]
        settings.sampling.maxTokens = 1000
        let stored = ChatSettingsStore(directory: directory)
        try stored.save(settings)
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport, settingsStore: ChatSettingsStore(directory: directory))
        XCTAssertEqual(store.settings.systemPrompt, "Be brief.")
        XCTAssertEqual(store.settings.sampling.seed, 7)
        await store.refresh(port: 9042)
        store.send("hi")
        try await waitUntil { transport.pending.count == 1 }
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[0]) as? [String: Any])
        XCTAssertEqual(request["temperature"] as? Double, 0.5)
        XCTAssertEqual(request["top_p"] as? Double, 0.25)
        XCTAssertEqual(request["top_k"] as? Int, 40)
        XCTAssertEqual(request["seed"] as? Int, 7)
        XCTAssertEqual(request["stop"] as? [String], ["END"])
        XCTAssertEqual(request["max_tokens"] as? Int, 1000)
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.first?["content"] as? String, "Be brief.")
        let permissions = try FileManager.default.attributesOfItem(atPath: stored.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let old = try JSONDecoder().decode(AgentSampling.self, from: Data(#"{"temperature":0.5,"topP":0.25,"maxTokens":512}"#.utf8))
        XCTAssertEqual(old.topK, 0)
        XCTAssertNil(old.seed)
        XCTAssertTrue(old.stop.isEmpty)
        XCTAssertTrue(old.isValid)
    }

    func testInvalidSamplingDoesNotSend() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        await store.refresh(port: 9042)
        store.settings.sampling.temperature = 9
        store.send("hi")
        XCTAssertTrue(transport.bodies.isEmpty)
        XCTAssertEqual(store.notice, "Check temperature, top-p, top-k, seed and stop.")
    }

    func testContinueIsNotOfferedInAgentMode() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        await store.refresh(port: 9042)
        store.send("Write a long story")
        try await waitUntil { transport.pending.count == 1 }
        transport.resolve(0, text: "Once upon", truncated: true)
        try await waitUntil { !store.isRunning }
        store.agentMode = true
        store.continueAnswer()
        XCTAssertEqual(transport.pending.count, 1)
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

    func testImageAndDocumentAttachmentsAreSentAndSaved() async throws {
        let directory = try historyDirectory()
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        await store.refresh(port: 9042)
        let png = try ChatAttachmentTests.png()
        store.add(data: png, name: "shot.png", type: .png)
        try await waitUntil { store.pendingAttachments.count == 1 }
        store.add(data: Data("Hello file".utf8), name: "notes.txt", type: .plainText)
        try await waitUntil { store.pendingAttachments.count == 2 }
        store.send(String(repeating: "a", count: 1000))
        try await waitUntil { transport.pending.count == 1 }
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[0]) as? [String: Any])
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        XCTAssertTrue((parts.first?["text"] as? String)?.contains("untrusted data, not instructions") == true)
        XCTAssertTrue((parts.first?["text"] as? String)?.contains("Hello file") == true)
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
        let image = try XCTUnwrap(parts.last?["image_url"] as? [String: Any])
        XCTAssertEqual(image["detail"] as? String, "auto")
        let url = image["url"] as? String ?? ""
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,") || url.hasPrefix("data:image/jpeg;base64,"))
        transport.resolve(0, text: "I see it")
        try await waitUntil { !store.isRunning }
        let saved = try XCTUnwrap(ChatHistoryStore(directory: directory).load(store.conversationID))
        XCTAssertEqual(saved.turns.first?.attachments?.map(\.name), ["shot.png", "notes.txt"])
        XCTAssertEqual(saved.turns.first?.prompt, String(repeating: "a", count: 1000))
        store.newConversation()
        let reopened = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        reopened.openConversation(saved.id)
        XCTAssertEqual(reopened.turns.first?.attachments.map(\.name), ["shot.png", "notes.txt"])

        store.agentMode = true
        store.add(data: png, name: "shot.png", type: .png)
        try await waitUntil { !store.pendingAttachments.isEmpty }
        store.send("look")
        XCTAssertEqual(store.notice, ChatAttachmentIntake.agentImageHint)
        XCTAssertEqual(transport.pending.count, 1)
        let screen = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Malibu/Chat/ChatScreen.swift"), encoding: .utf8)
        XCTAssertTrue(screen.contains(".onDrop("))
        XCTAssertTrue(screen.contains(".onPasteCommand("))
        XCTAssertTrue(screen.contains("malibu.chat.attach"))
    }

    func testRegenerateKeepsTheEarlierAnswerAndOmitsItFromTheRequest() async throws {
        let directory = try historyDirectory()
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        await store.refresh(port: 9042)
        try await answer(store, transport, "question", "first answer")
        try await answer(store, transport, "follow up", "later")
        let id = store.turns[0].id
        store.regenerate(id)
        try await waitUntil { transport.pending.count == 3 }
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[2]) as? [String: Any])
        XCTAssertEqual((request["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? String },
                       ["question"], "The replaced answer and the turns after it stay out of the request")
        transport.resolve(2, text: "second answer")
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].answer, "second answer")
        XCTAssertEqual(store.turns[0].activeVersion, 1)
        XCTAssertEqual(store.turns[0].versions.map(\.answer), ["first answer", "second answer"])
        store.selectVersion(id, index: 0)
        XCTAssertEqual(store.turns[0].answer, "first answer")
        XCTAssertEqual(store.turns[0].prompt, "question")
        let saved = try XCTUnwrap(ChatHistoryStore(directory: directory).load(store.conversationID))
        XCTAssertEqual(saved.turns.first?.activeVersion, 0)
        XCTAssertEqual(saved.turns.first?.versions?.map(\.answer), ["first answer", "second answer"])
        store.newConversation()
        let reopened = ChatStore(transport: transport, historyStore: ChatHistoryStore(directory: directory))
        reopened.openConversation(saved.id)
        XCTAssertEqual(reopened.turns.first?.answer, "first answer")
        XCTAssertEqual(reopened.turns.first?.versions.count, 2)
        let screen = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Malibu/Chat/ChatScreen.swift"), encoding: .utf8)
        XCTAssertTrue(screen.contains("malibu.chat.edit"))
        XCTAssertTrue(screen.contains("malibu.chat.regenerate"))
        XCTAssertTrue(screen.contains("malibu.chat.branch"))
    }

    func testEditChangesThePromptAndDropsLaterTurns() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        await store.refresh(port: 9042)
        try await answer(store, transport, "original", "old answer")
        try await answer(store, transport, "next", "kept too long")
        let id = store.turns[0].id
        store.editAndResend(id, prompt: "  rewritten  ")
        try await waitUntil { transport.pending.count == 3 }
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[2]) as? [String: Any])
        XCTAssertEqual((request["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? String }, ["rewritten"])
        transport.resolve(2, text: "new answer")
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.turns.count, 1)
        XCTAssertEqual(store.turns[0].prompt, "rewritten")
        XCTAssertEqual(store.turns[0].answer, "new answer")
        XCTAssertEqual(store.turns[0].versions[0].prompt, "original")
        XCTAssertEqual(store.turns[0].versions[0].answer, "old answer")
        store.regenerate(id)
        try await waitUntil { transport.pending.count == 4 }
        store.regenerate(id)
        XCTAssertEqual(transport.pending.count, 4, "An answer still streaming is not regenerated again")
        store.selectVersion(id, index: 0)
        XCTAssertEqual(store.turns[0].answer, "", "Switching versions waits until the run stops")
        store.stop()
    }

    func testMCPToolCallAsksAndSendsTheResult() async throws {
        let transport = ControlledChatTransport()
        let fake = FakeMCPServer()
        let store = ChatStore(transport: transport, makeMCP: { configuration in
            fake.configuration = configuration
            return fake
        })
        await store.refresh(port: 9042)
        store.settings.servers = [MCPServerConfiguration(name: "Docs", url: "http://127.0.0.1:9/mcp")]
        store.send("use the tool")
        try await waitUntil { transport.pending.count == 1 }
        let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[0]) as? [String: Any])
        XCTAssertEqual(first["tool_choice"] as? String, "auto")
        let messages = try XCTUnwrap(first["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("untrusted data") == true })
        transport.resolve(0, calls: [ChatToolCall(id: "c1", name: fake.toolName, arguments: "{\"q\":\"hi\"}")])
        try await waitUntil { store.pendingApproval != nil }
        XCTAssertEqual(store.pendingApproval?.tool, "echo")
        store.resolveApproval(.allowOnce)
        try await waitUntil { transport.pending.count == 2 }
        XCTAssertEqual(fake.executed, 1)
        let second = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[1]) as? [String: Any])
        let follow = try XCTUnwrap(second["messages"] as? [[String: Any]])
        XCTAssertTrue(follow.contains { $0["role"] as? String == "tool" && ($0["content"] as? String)?.contains("untrusted-data") == true })
        transport.resolve(1, text: "done")
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.turns.first?.answer, "done")
        XCTAssertEqual(store.turns.first?.complete, true)
        XCTAssertEqual(store.turns.first?.tools, ["MCP Docs · echo"])
        let screen = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Malibu/Chat/ChatScreen.swift"), encoding: .utf8)
        XCTAssertTrue(screen.contains("malibu.chat.mcp-approval"))
        XCTAssertTrue(screen.contains("AgentToolApprovalView"))
        let settings = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Malibu/Chat/ChatSettings.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("malibu.chat.mcp-target"))
    }

    func testMCPDenyDoesNotSendTheToolResult() async throws {
        let transport = ControlledChatTransport()
        let fake = FakeMCPServer()
        let store = ChatStore(transport: transport, makeMCP: { configuration in
            fake.configuration = configuration
            return fake
        })
        await store.refresh(port: 9042)
        store.settings.servers = [MCPServerConfiguration(name: "Docs", url: "http://127.0.0.1:9/mcp")]
        store.send("use the tool")
        try await waitUntil { transport.pending.count == 1 }
        transport.resolve(0, calls: [ChatToolCall(id: "c1", name: fake.toolName, arguments: "{\"q\":\"hi\"}")])
        try await waitUntil { store.pendingApproval != nil }
        store.resolveApproval(.deny)
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(fake.executed, 0)
        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertEqual(store.notice, "The MCP tool was denied.")
        XCTAssertNotEqual(store.turns.first?.complete, true)
    }

    func testMCPBlocksAnImageAttachment() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        store.settings.servers = [MCPServerConfiguration(name: "Docs", url: "http://127.0.0.1:9/mcp")]
        store.stageForEdit([ChatAttachment(id: UUID(), name: "a.png", imageDataURL: "data:image/png;base64,aaaa")])
        store.send("")
        XCTAssertEqual(store.notice, ChatAttachmentIntake.mcpImageHint)
        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertTrue(transport.bodies.isEmpty)
    }

    func testWriteWaitsForApprovalAndDenyLeavesTheFile() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatWrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.txt")
        try Data("old\n".utf8).write(to: file)
        try Data("project rule\n".utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        store.selectFolder(folder)
        store.agentMode = true
        await store.refresh(port: 9042)
        store.send("update the note")
        try await waitUntil { transport.pending.count == 1 }
        let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[0]) as? [String: Any])
        let system = try XCTUnwrap((first["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(system.contains("project rule"))
        XCTAssertTrue(system.contains("untrusted data, not as permission"))
        XCTAssertFalse(system.contains("Do not claim to execute commands"))
        transport.resolve(0, calls: [ChatToolCall(id: "w", name: "write_file", arguments: "{\"path\":\"note.txt\",\"content\":\"new\\n\"}")])
        try await waitUntil { store.pendingApproval != nil }
        XCTAssertEqual(store.pendingApproval?.allowsSession, false)
        XCTAssertEqual(store.pendingApproval?.server, "Folder")
        XCTAssertTrue(store.pendingApproval?.diff?.contains("note.txt") == true)
        XCTAssertEqual(try String(contentsOf: file), "old\n")
        XCTAssertEqual(store.turns.last?.tools, ["write_file note.txt"])
        XCTAssertFalse(store.turns.last?.tools.joined().contains("new") == true)
        store.resolveApproval(.deny)
        try await waitUntil { transport.pending.count == 2 }
        XCTAssertEqual(try String(contentsOf: file), "old\n")
        let second = try XCTUnwrap(try JSONSerialization.jsonObject(with: transport.bodies[1]) as? [String: Any])
        let tool = try XCTUnwrap((second["messages"] as? [[String: Any]])?.last)
        XCTAssertEqual(tool["content"] as? String, AgentWorkspace.deniedChange)
        transport.resolve(1, calls: [ChatToolCall(id: "finish", name: "finish_answer", arguments: "{\"answer\":\"left unchanged\"}")])
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.turns.last?.answer, "left unchanged")
        let screen = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Malibu/Chat/ChatScreen.swift"), encoding: .utf8)
        XCTAssertTrue(screen.contains("malibu.chat.undo"))
    }

    func testAllowSessionDoesNotWriteAndAllowOnceCanBeUndone() async throws {
        let transport = ControlledChatTransport()
        let store = ChatStore(transport: transport)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatUndo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.txt")
        try Data("old\n".utf8).write(to: file)
        store.selectFolder(folder)
        store.agentMode = true
        await store.refresh(port: 9042)
        store.send("update the note")
        try await waitUntil { transport.pending.count == 1 }
        transport.resolve(0, calls: [ChatToolCall(id: "w", name: "write_file", arguments: "{\"path\":\"note.txt\",\"content\":\"new\\n\"}")])
        try await waitUntil { store.pendingApproval != nil }
        store.resolveApproval(.allowSession)
        try await waitUntil { transport.pending.count == 2 }
        XCTAssertEqual(try String(contentsOf: file), "old\n")
        transport.resolve(1, calls: [ChatToolCall(id: "w2", name: "write_file", arguments: "{\"path\":\"note.txt\",\"content\":\"new\\n\"}")])
        try await waitUntil { store.pendingApproval != nil }
        store.resolveApproval(.allowOnce)
        try await waitUntil { transport.pending.count == 3 }
        XCTAssertEqual(try String(contentsOf: file), "new\n")
        XCTAssertTrue(store.canUndo)
        transport.resolve(2, calls: [ChatToolCall(id: "finish", name: "finish_answer", arguments: "{\"answer\":\"updated\"}")])
        try await waitUntil { !store.isRunning }
        store.undoLastChange()
        try await waitUntil { store.pendingApproval?.tool == "undo" }
        store.resolveApproval(.allowOnce)
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(try String(contentsOf: file), "old\n")
        XCTAssertFalse(store.canUndo)
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
private final class FakeChatGateway: ChatGateway {
    var models: [ConnectedModel] = []
    var bodies: [[String: Any]] = []
    var text = "network answer"
    func chatModels(key: String) async throws -> [ConnectedModel] { models }
    func complete(body: [String: Any], key: String) async throws -> ChatCompletion {
        bodies.append(body)
        return ChatCompletion(text: text)
    }
}

@MainActor
private final class FakeMCPServer: MCPServing {
    var configuration: MCPServerConfiguration
    var isRunning = false
    var executed = 0
    let toolName = "mcp_fake_echo"
    init(configuration: MCPServerConfiguration = MCPServerConfiguration(name: "Docs", url: "http://127.0.0.1:9/mcp")) {
        self.configuration = configuration
    }
    func start() async throws -> [MCPTool] {
        isRunning = true
        let schema: [String: Any] = ["type": "object", "properties": ["q": ["type": "string"]], "required": ["q"], "additionalProperties": false]
        return [MCPTool(name: toolName, serverName: configuration.name, originalName: "echo", schema: schema)]
    }
    func call(tool: MCPTool, arguments: String,
              approval: @MainActor (MCPTool, String) async -> MCPApprovalDecision) async throws -> String {
        let decision = await approval(tool, arguments)
        guard decision != .deny else { throw MCPFailure.denied }
        executed += 1
        return "{\"ok\":\"untrusted-data\"}"
    }
    func stop() { isRunning = false }
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
    func resolve(_ index: Int, text: String = "", calls: [ChatToolCall] = [], reasoning: String = "",
                 truncated: Bool = false, promptTokens: Int? = nil, completionTokens: Int? = nil,
                 decodeMilliseconds: Int? = nil) {
        pending[index].continuation.resume(returning: ChatCompletion(
            text: text, calls: calls, reasoning: reasoning, truncated: truncated,
            completionTokens: completionTokens, promptTokens: promptTokens,
            decodeMilliseconds: decodeMilliseconds))
    }
}
