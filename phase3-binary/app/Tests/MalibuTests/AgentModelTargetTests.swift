import XCTest
@testable import Malibu

@MainActor
final class AgentModelTargetTests: XCTestCase {
    func testLocalTargetRequiresGuaranteedToolsBeforeInference() async throws {
        let fake = AgentTestTransport(); fake.guaranteed = false
        let transport = AgentModelTransport(local: fake, buyerKey: { XCTFail("Local work must not read buyer keys"); return "" }, port: { 9042 })
        do { _ = try await transport.prepare(AgentDefinition()); XCTFail("Unsupported local agent admitted") }
        catch { XCTAssertEqual(error as? ChatFailure, .unsupportedTools) }
        XCTAssertEqual(fake.completions, 0)
    }
    func testSendStartsConversationAndCarriesCompletedHistory() async throws {
        let fake = AgentTestTransport()
        let session = AgentSession(transport: AgentModelTransport(local: fake, port: { 9042 }))
        let agent = AgentDefinition()
        session.send(agent: agent, prompt: "first")
        for _ in 0..<100 where fake.completions < 1 || session.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fake.completions, 1)
        XCTAssertTrue(session.transcript.contains("hello"))
        _ = try await session.run(agent: agent, prompt: "second")
        XCTAssertEqual(fake.messageCounts, [2, 4])
        session.reset()
        XCTAssertTrue(session.transcript.isEmpty)
    }

    func testLocalOriginHeaderOccursExactlyOnce() throws {
        let request = LocalChatTransport.completionRequest(at: try ChatEndpoint(port: 9042), body: Data())
        let headers = request.allHTTPHeaderFields ?? [:]
        XCTAssertEqual(headers.filter { $0.key.lowercased() == "x-macprovider-origin" }.count, 1)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-MacProvider-Origin"), "local-app")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
    func testPreemptionEndsAgentWithoutRetryOrToolExecution() async throws {
        let fake = AgentTestTransport(); fake.preempt = true
        let session = AgentSession(transport: AgentModelTransport(local: fake, port: { 9042 }))
        do { _ = try await session.run(agent: AgentDefinition(), prompt: "hello"); XCTFail("Must preempt") }
        catch { XCTAssertEqual(error as? ChatFailure, .preempted) }
        XCTAssertEqual(fake.completions, 1); XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.transcript.contains("Agent:")); XCTAssertNil(session.pendingApproval)
    }
    func testNetworkPickerUsesPublishedToolsAndContextOnly() throws {
        let data = Data(#"{"data":[{"id":"ok","capabilities":{"tools":true},"max_context_tokens":32768},{"id":"short","capabilities":{"tools":true},"max_context_tokens":32767},{"id":"missing"},{"id":"no-tools","max_context_tokens":65536}]}"#.utf8)
        XCTAssertEqual(ConnectedGatewayClient.agentReady(try ConnectedGatewayClient.decodeModels(data)).map(\.id), ["ok"])
    }
    func testRoundAndOutputBudgetAreBounded() async throws {
        let fake = AgentTestTransport(); fake.repeatTools = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var agent = AgentDefinition(); agent.workspacePath = folder.path; agent.workspaceTools = true
        agent.sampling.maxTokens = 2048
        let session = AgentSession(transport: AgentModelTransport(local: fake, port: { 9042 }))
        do { _ = try await session.run(agent: agent, prompt: "loop"); XCTFail("Must hit cap") }
        catch { XCTAssertEqual(error as? ChatFailure, .limit) }
        XCTAssertEqual(fake.completions, 4)
        XCTAssertEqual(fake.budgets.reduce(0,+), 8192)
    }
}

@MainActor
private final class AgentTestTransport: ChatTransport {
    var guaranteed = true
    var preempt = false
    var repeatTools = false
    var completions = 0
    var budgets: [Int] = []
    var messageCounts: [Int] = []
    func capability(at endpoint: ChatEndpoint) async throws -> ChatCapability {
        ChatCapability(model: "fixture", generation: 1, guaranteedTools: guaranteed)
    }
    func complete(at endpoint: ChatEndpoint, body: Data, onText: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion {
        completions += 1
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        budgets.append(object?["max_tokens"] as? Int ?? 0)
        messageCounts.append((object?["messages"] as? [[String: Any]])?.count ?? 0)
        if preempt { throw ChatFailure.preempted }
        return ChatCompletion(text: repeatTools ? "" : "hello", calls: repeatTools ? [ChatToolCall(id: "call\(completions)", name: "list_files", arguments: #"{"path":"."}"#)] : [])
    }
}
