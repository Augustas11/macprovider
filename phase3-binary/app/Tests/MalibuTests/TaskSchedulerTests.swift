import Foundation
import XCTest
@testable import Malibu

@MainActor
final class TaskSchedulerTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("MalibuTaskTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Task scheduler did not settle")
    }
    private func task(now: Date = Date()) -> ScheduledTask {
        ScheduledTask(agentID: UUID(), prompt: "Summarize the folder", schedule: TaskSchedule(kind: .once, date: now))
    }

    func testGlobalConcurrencyIsOneAndDuplicateRunNowIsRecordedSkipped() async throws {
        let store = TaskStore(directory: try directory())
        var pending: CheckedContinuation<String, Error>?
        var calls = 0
        let scheduler = TaskScheduler(store: store, execute: { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
        let first = task(); let second = task()
        scheduler.runNow(first)
        try await eventually { calls == 1 }
        scheduler.runNow(first); scheduler.runNow(second)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.history(taskID: first.id).first?.status, .skipped)
        XCTAssertEqual(store.history(taskID: second.id).first?.status, .skipped)
        pending?.resume(returning: "answer")
        try await eventually { scheduler.runningTaskID == nil }
        XCTAssertEqual(store.history(taskID: first.id).first?.status, .succeeded)
    }

    func testMissedRunCatchesUpExactlyOnceEvenAfterReload() async throws {
        let path = try directory()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        var now = old
        let store = TaskStore(directory: path, clock: { now }, timezone: { TimeZone(secondsFromGMT: 0)! })
        var scheduled = task(now: old); scheduled.schedule.kind = .hourly
        try store.save(scheduled)
        now = old.addingTimeInterval(10 * 86400)
        var calls = 0
        let scheduler = TaskScheduler(store: store, clock: { now }, timezone: { TimeZone(secondsFromGMT: 0)! },
                                      execute: { _ in calls += 1; return "caught up" })
        scheduler.tick()
        try await eventually { scheduler.runningTaskID == nil }
        for _ in 0..<10 { scheduler.tick() }
        XCTAssertEqual(calls, 1)
        let reloaded = TaskStore(directory: path, clock: { now })
        let second = TaskScheduler(store: reloaded, clock: { now }, execute: { _ in calls += 1; return "unexpected" })
        second.tick()
        XCTAssertNil(second.runningTaskID)
        XCTAssertEqual(calls, 1)
    }

    func testPastOnceRunsOnceAndDisablesItself() async throws {
        let now = Date()
        let store = TaskStore(directory: try directory(), clock: { now })
        let scheduled = task(now: now.addingTimeInterval(-86400))
        try store.save(scheduled)
        var calls = 0
        let scheduler = TaskScheduler(store: store, clock: { now }, execute: { _ in calls += 1; return "done" })
        scheduler.tick()
        try await eventually { scheduler.runningTaskID == nil }
        scheduler.tick()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(try XCTUnwrap(store.tasks.first).enabled)
        XCTAssertNil(store.tasks.first?.nextFire)
    }

    func testWallTimeCapCancelsRunAndRecordsFailure() async throws {
        let store = TaskStore(directory: try directory())
        var canceled = false
        let scheduled = task()
        let scheduler = TaskScheduler(store: store, wallTime: 0.02, execute: { _ in
            try await Task.sleep(for: .seconds(30)); return "too late"
        }, cancel: { canceled = true })
        scheduler.runNow(scheduled)
        try await eventually { !store.history(taskID: scheduled.id).isEmpty }
        XCTAssertTrue(canceled)
        XCTAssertEqual(store.history(taskID: scheduled.id).first?.status, .failed)
        XCTAssertEqual(store.history(taskID: scheduled.id).first?.reason, TaskRunFailure.timeout.localizedDescription)
    }

    func testOutputCapFailsWithoutSavingOversizedTranscript() async throws {
        let store = TaskStore(directory: try directory())
        let scheduled = task()
        let scheduler = TaskScheduler(store: store, execute: { _ in String(repeating: "x", count: TaskStore.transcriptByteLimit + 1) })
        scheduler.runNow(scheduled)
        try await eventually { scheduler.runningTaskID == nil }
        let run = try XCTUnwrap(store.history(taskID: scheduled.id).first)
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.reason, TaskRunFailure.outputLimit.localizedDescription)
        XCTAssertLessThan(run.transcript.utf8.count, TaskStore.transcriptByteLimit)
    }

    func testUnapprovedToolFailsRunAndAllowlistIsPassedUnchanged() async throws {
        let store = TaskStore(directory: try directory())
        var scheduled = task(); scheduled.preapprovedTools = ["server__read"]
        let scheduler = TaskScheduler(store: store, execute: { task in
            XCTAssertEqual(task.preapprovedTools, ["server__read"])
            throw TaskRunFailure.unapprovedTool
        })
        scheduler.runNow(scheduled)
        try await eventually { scheduler.runningTaskID == nil }
        XCTAssertEqual(store.history(taskID: scheduled.id).first?.status, .failed)
        XCTAssertEqual(store.history(taskID: scheduled.id).first?.reason, TaskRunFailure.unapprovedTool.localizedDescription)
    }

    func testActualAgentSessionRejectsUnapprovedMCPWithoutExecutingIt() async throws {
        let path = try directory()
        let marker = path.appendingPathComponent("executed")
        let script = path.appendingPathComponent("server.py")
        let source = """
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if "id" not in request:
                continue
            if method == "initialize":
                result = {"protocolVersion":"2024-11-05", "capabilities":{}, "serverInfo":{"name":"test","version":"1"}}
            elif method == "tools/list":
                result = {"tools":[{"name":"read", "inputSchema":{"type":"object", "properties":{}, "additionalProperties":False}}]}
            else:
                open(sys.argv[1], "w").write("executed")
                result = {"content":[{"type":"text", "text":"read"}]}
            print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":result}), flush=True)
        """
        try Data(source.utf8).write(to: script)
        var server = MCPServerConfiguration()
        server.name = "Task server"; server.command = "/usr/bin/python3"; server.arguments = ["-u", script.path, marker.path]
        var agent = AgentDefinition(); agent.servers = [server]
        let transport = TaskLoopTransport(mcp: true)
        let session = AgentSession(transport: AgentModelTransport(local: transport, port: { 9042 }))
        let store = TaskStore(directory: path.appendingPathComponent("Tasks"))
        let scheduled = task()
        let scheduler = TaskScheduler(store: store, execute: { task in
            try await session.run(agent: agent, prompt: task.prompt, preapprovedTools: task.preapprovedTools)
        }, cancel: { session.cancel() })
        scheduler.runNow(scheduled)
        try await eventually { scheduler.runningTaskID == nil }
        XCTAssertEqual(store.history(taskID: scheduled.id).first?.status, .failed)
        XCTAssertEqual(store.history(taskID: scheduled.id).first?.reason, TaskRunFailure.unapprovedTool.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(session.pendingApproval)
    }

    func testActualSessionEnforcesRoundAndOutputTokenBudgets() async throws {
        for (tokens, expectedCalls) in [(1024, 6), (2048, 4)] {
            let path = try directory()
            var agent = AgentDefinition(); agent.workspaceTools = true; agent.workspacePath = path.path
            agent.sampling.maxTokens = tokens
            let transport = TaskLoopTransport(mcp: false)
            let session = AgentSession(transport: AgentModelTransport(local: transport, port: { 9042 }))
            do {
                _ = try await session.run(agent: agent, prompt: "Keep reading", preapprovedTools: [])
                XCTFail("Unbounded loop succeeded")
            } catch { XCTAssertEqual(error as? ChatFailure, .limit) }
            XCTAssertEqual(transport.calls, expectedCalls)
            XCTAssertLessThanOrEqual(transport.budgets.reduce(0, +), TaskScheduler.maximumOutputTokens)
            XCTAssertLessThanOrEqual(transport.calls, TaskScheduler.maximumRounds)
        }
    }

    func testFailurePreservesBoundedPartialTranscript() async throws {
        let store = TaskStore(directory: try directory()); let scheduled = task()
        let scheduler = TaskScheduler(store: store, execute: { _ in
            throw TaskExecutionFailure(underlying: ChatFailure.preempted, transcript: "You: prompt\nTool result before preemption")
        })
        scheduler.runNow(scheduled)
        try await eventually { scheduler.runningTaskID == nil }
        let run = try XCTUnwrap(store.history(taskID: scheduled.id).first)
        XCTAssertEqual(run.status, .preempted)
        XCTAssertTrue(run.transcript.contains("Tool result before preemption"))
    }

    func testPreemptionHasDistinctStatus() async throws {
        let store = TaskStore(directory: try directory()); let scheduled = task()
        let scheduler = TaskScheduler(store: store, execute: { _ in throw ChatFailure.preempted })
        scheduler.runNow(scheduled)
        try await eventually { scheduler.runningTaskID == nil }
        XCTAssertEqual(store.history(taskID: scheduled.id).first?.status, .preempted)
    }

    func testQuitCancelsRunningTaskAndRecordsEnd() async throws {
        let store = TaskStore(directory: try directory()); let scheduled = task()
        var canceled = false
        let scheduler = TaskScheduler(store: store, execute: { _ in
            try await Task.sleep(for: .seconds(30)); return "unexpected"
        }, partialTranscript: { "You: prompt\nTool partial result" }, cancel: { canceled = true })
        scheduler.runNow(scheduled)
        scheduler.stop()
        XCTAssertTrue(canceled)
        XCTAssertNil(scheduler.runningTaskID)
        let run = try XCTUnwrap(store.history(taskID: scheduled.id).first)
        XCTAssertEqual(run.status, .skipped)
        XCTAssertTrue(run.transcript.contains("Tool partial result"))
        XCTAssertGreaterThanOrEqual(run.endedAt, run.startedAt)
    }

    func testRunRetentionAndPrivateFileModesSurviveReload() throws {
        let path = try directory(); let store = TaskStore(directory: path); let scheduled = task()
        try store.save(scheduled)
        for index in 0..<25 {
            try store.record(TaskRun(taskID: scheduled.id, startedAt: Date(), endedAt: Date(), status: .succeeded,
                                     reason: nil, transcript: "run \(index)"))
        }
        let history = TaskStore(directory: path).history(taskID: scheduled.id)
        XCTAssertEqual(history.count, 20)
        XCTAssertEqual(history.first?.transcript, "run 24")
        XCTAssertEqual(history.last?.transcript, "run 5")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o700)
        for file in ["tasks.json", "runs.json"] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent(file).path)[.posixPermissions] as? Int, 0o600)
        }
    }

    func testTranscriptsNeverEnterDiagnosticsBundle() throws {
        let path = try directory(); let store = TaskStore(directory: path); let scheduled = task()
        let secretTranscript = "task-transcript-canary-\(UUID().uuidString)"
        try store.record(TaskRun(taskID: scheduled.id, startedAt: Date(), endedAt: Date(), status: .succeeded,
                                 reason: nil, transcript: secretTranscript))
        let bundle = try ProviderDiagnosticsBundle.make(snapshot: .empty, providerLogLines: [], watchdogLogURL: nil, appVersion: "test")
        let text = try XCTUnwrap(String(data: bundle, encoding: .utf8))
        XCTAssertFalse(text.contains(secretTranscript))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bundle) as? [String: Any])
        XCTAssertNil(object["tasks"]); XCTAssertNil(object["transcripts"])
        XCTAssertEqual(store.history(taskID: scheduled.id).first?.transcript, secretTranscript)
    }
}

@MainActor
private final class TaskLoopTransport: ChatTransport {
    let mcp: Bool
    var calls = 0
    var budgets: [Int] = []
    init(mcp: Bool) { self.mcp = mcp }
    func capability(at endpoint: ChatEndpoint) async throws -> ChatCapability {
        ChatCapability(model: "fixture", generation: 1, guaranteedTools: true)
    }
    func complete(at endpoint: ChatEndpoint, body: Data,
                  onText: @escaping @MainActor (String) -> Void) async throws -> ChatCompletion {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        calls += 1; budgets.append(try XCTUnwrap(object["max_tokens"] as? Int))
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let first = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        let name = try XCTUnwrap(first["name"] as? String)
        return ChatCompletion(text: "", calls: [ChatToolCall(id: "call-\(calls)", name: name,
                               arguments: mcp ? "{}" : "{\"path\":\".\"}")])
    }
}
