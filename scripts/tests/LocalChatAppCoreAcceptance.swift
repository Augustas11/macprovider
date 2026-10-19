import Combine
import Darwin
import Foundation

/// Builds with the verbatim app core. This observer forwards every request and
/// callback to LocalChatTransport; it does not substitute model or tool results.
@MainActor
private final class ObservedLocalTransport: ChatTransport {
    private let actual = LocalChatTransport()
    private(set) var completionCount = 0
    private(set) var readMarkerRequested = false
    private(set) var finishRequested = false
    func capability(at endpoint: ChatEndpoint) async throws -> ChatCapability {
        try await actual.capability(at: endpoint)
    }
    func complete(at endpoint: ChatEndpoint, body: Data,
                  onText: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion {
        completionCount += 1
        let response = try await actual.complete(at: endpoint, body: body, onText: onText)
        for call in response.calls {
            let arguments = try AgentWorkspace.arguments(for: call)
            if call.name == "read_file" && arguments["path"] == "marker.txt" { readMarkerRequested = true }
            if call.name == "finish_answer" { finishRequested = true }
        }
        return response
    }
}

@main
private enum LocalChatAppCoreAcceptance {
    private enum Failure: Error { case assertion(String) }
    @MainActor
    static func main() async {
        var report: [String: Any] = ["result": "fail", "port": 18055, "transport": "actual_app_core"]
        do {
            // Defense in depth: the launcher also validates sysctl/hostname and
            // the exact --no-join listening process before compiling anything.
            guard ProcessInfo.processInfo.environment["MACPROVIDER_TEST_STUDIO_HOST"]?.isEmpty == false,
                  ProcessInfo.processInfo.environment["MACPROVIDER_CHAT_ACCEPTANCE_READY"] == "1"
            else { throw Failure.assertion("studio_environment_missing") }
            let transport = ObservedLocalTransport()
            let store = ChatStore(transport: transport)
            defer { store.close() }
            await store.refresh(port: 18055)
            guard let capability = store.capability,
                  capability.model == "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
                  capability.guaranteedTools else { throw Failure.assertion("qualified_local_capability_missing") }
            report["model"] = capability.model
            report["local_accounting_gate"] = true

            var partialUpdates = 0
            var lastLength = 0
            let subscription = store.$turns.sink { turns in
                guard store.isRunning, let turn = turns.last, !turn.complete,
                      turn.answer.utf8.count > lastLength else { return }
                lastLength = turn.answer.utf8.count
                partialUpdates += 1
            }
            store.send("Write four short sentences explaining why a local read-only assistant is useful. Plain text only.")
            try await waitForTurn(store)
            subscription.cancel()
            report["chat_turn_complete"] = store.turns.last?.complete ?? false
            report["chat_notice_present"] = store.notice != nil
            report["partial_updates"] = partialUpdates
            guard let chat = store.turns.last, chat.complete, !chat.answer.isEmpty,
                  partialUpdates >= 2 else { throw Failure.assertion("incremental_chat_not_completed") }
            report["chat_completed"] = true
            report["partial_updates"] = partialUpdates
            report["chat_output_bytes"] = chat.answer.utf8.count

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-core-marker-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let marker = "APP_CORE_MARKER_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let file = folder.appendingPathComponent("marker.txt")
            guard FileManager.default.createFile(atPath: file.path, contents: Data(marker.utf8),
                                                  attributes: [.posixPermissions: 0o600])
            else { throw Failure.assertion("marker_setup_failed") }
            store.selectFolder(folder)
            guard store.folderName != nil else { throw Failure.assertion("workspace_selection_failed") }
            store.agentMode = true
            store.send("Use read_file to read marker.txt in the selected folder. Then use finish_answer with only the exact file contents as the answer. No explanation, quotes or extra characters.")
            try await waitForTurn(store)
            report["agent_turn_complete"] = store.turns.last?.complete ?? false
            report["agent_notice_present"] = store.notice != nil
            report["read_marker_requested"] = transport.readMarkerRequested
            report["finish_answer_requested"] = transport.finishRequested
            report["completion_requests"] = transport.completionCount
            guard let agent = store.turns.last, agent.complete,
                  agent.answer == marker, transport.readMarkerRequested, transport.finishRequested
            else { throw Failure.assertion("agent_marker_not_completed") }
            report["agent_completed"] = true
            report["read_marker_requested"] = true
            report["finish_answer_requested"] = true
            report["exact_marker_match"] = true
            report["completion_requests"] = transport.completionCount
            report["result"] = "pass"
        } catch Failure.assertion(let reason) {
            report["reason"] = reason
        } catch {
            // Never log model output, file contents, paths, or raw transport errors.
            report["reason"] = "app_core_acceptance_failed"
        }
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: bytes, encoding: .utf8) { print(text) }
        exit(report["result"] as? String == "pass" ? 0 : 1)
    }

    @MainActor
    private static func waitForTurn(_ store: ChatStore) async throws {
        guard store.isRunning else { throw Failure.assertion("turn_not_started") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(95))
        while store.isRunning {
            guard ContinuousClock.now < deadline else {
                store.stop()
                throw Failure.assertion("turn_timeout")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
