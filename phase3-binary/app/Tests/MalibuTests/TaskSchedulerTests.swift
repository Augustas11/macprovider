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

    func testSavingOpenEditorCannotReplayConsumedOnceOrRecurringOccurrence() async throws {
        for kind in [TaskSchedule.Kind.once, .hourly] {
            var now = Date(timeIntervalSince1970: 1_700_000_000)
            let zone = TimeZone(secondsFromGMT: 0)!
            let store = TaskStore(directory: try directory(), clock: { now }, timezone: { zone })
            var scheduled = task(now: now); scheduled.schedule.kind = kind
            try store.save(scheduled)
            let original = try XCTUnwrap(store.tasks.first)
            var edited = original
            edited.name = "Edited while running"; edited.prompt = "New prompt"
            now = try XCTUnwrap(original.nextFire)
            var calls = 0
            let scheduler = TaskScheduler(store: store, clock: { now }, timezone: { zone }, execute: { _ in
                calls += 1; return "done"
            })
            scheduler.tick()
            try await eventually { scheduler.runningTaskID == nil }
            let consumed = try XCTUnwrap(store.tasks.first)
            try store.save(edited, original: original)
            XCTAssertEqual(store.tasks.first?.nextFire, consumed.nextFire)
            XCTAssertEqual(store.tasks.first?.enabled, consumed.enabled)
            XCTAssertEqual(store.tasks.first?.prompt, "New prompt")
            scheduler.tick()
            XCTAssertNil(scheduler.runningTaskID)
            XCTAssertEqual(calls, 1)
        }
    }

    func testExplicitScheduleChangeFromOpenEditorRecomputesOccurrence() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TaskStore(directory: try directory(), clock: { now })
        try store.save(task(now: now))
        let original = try XCTUnwrap(store.tasks.first)
        try store.consume(original, now: now, timezone: .current)
        var edited = original
        edited.schedule.date = now.addingTimeInterval(3600)
        try store.save(edited, original: original)
        XCTAssertEqual(store.tasks.first?.nextFire, edited.schedule.date)
        XCTAssertFalse(try XCTUnwrap(store.tasks.first).enabled)
    }

    func testTimezoneChangeRecomputesDailyOccurrenceAndPersistsAcrossReload() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-10-26T12:00:00Z"))
        var zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let path = try directory()
        let store = TaskStore(directory: path, clock: { now }, timezone: { zone })
        var scheduled = task(now: now)
        scheduled.schedule = TaskSchedule(kind: .daily, hour: 9, minute: 0)
        try store.save(scheduled)
        XCTAssertEqual(store.tasks.first?.nextFire, formatter.date(from: "2026-10-26T16:00:00Z"))
        zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let scheduler = TaskScheduler(store: store, clock: { now }, timezone: { zone }, execute: { _ in
            XCTFail("09:00 has not arrived"); return "unexpected"
        })
        scheduler.tick()
        XCTAssertEqual(store.tasks.first?.nextFire, formatter.date(from: "2026-10-26T13:00:00Z"))
        let reloaded = TaskStore(directory: path, clock: { now }, timezone: { zone })
        XCTAssertEqual(reloaded.tasks, store.tasks)
    }

    func testTimezoneChangeAfterMissedRunCatchesUpOnceAcrossReload() async throws {
        let formatter = ISO8601DateFormatter()
        var now = try XCTUnwrap(formatter.date(from: "2026-10-26T12:00:00Z"))
        var zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let path = try directory()
        let store = TaskStore(directory: path, clock: { now }, timezone: { zone })
        var scheduled = task(now: now)
        scheduled.schedule = TaskSchedule(kind: .daily, hour: 9, minute: 0)
        try store.save(scheduled)
        now = try XCTUnwrap(formatter.date(from: "2026-10-27T14:00:00Z"))
        zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // A closed app observes the change on its first tick after reload.
        let reloaded = TaskStore(directory: path, clock: { now }, timezone: { zone })
        var calls = 0
        let scheduler = TaskScheduler(store: reloaded, clock: { now }, timezone: { zone }, execute: { _ in
            calls += 1; return "caught up"
        })
        scheduler.tick()
        try await eventually { scheduler.runningTaskID == nil }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(reloaded.tasks.first?.nextFire, formatter.date(from: "2026-10-28T13:00:00Z"))
        let again = TaskStore(directory: path, clock: { now }, timezone: { zone })
        let next = TaskScheduler(store: again, clock: { now }, timezone: { zone }, execute: { _ in
            calls += 1; return "unexpected"
        })
        next.tick()
        XCTAssertNil(next.runningTaskID)
        XCTAssertEqual(calls, 1)
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

    func testEverySavedTaskAndRunFieldSurvivesRestart() throws {
        let path = try directory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let zone = TimeZone(identifier: "Asia/Makassar")!
        let store = TaskStore(directory: path, clock: { now }, timezone: { zone })
        var scheduled = task(now: now)
        scheduled.name = "猫\\\" task"
        scheduled.prompt = "Résumé\n猫\\\""
        scheduled.schedule = TaskSchedule(kind: .weekdays, date: now.addingTimeInterval(600), hour: 17, minute: 42)
        scheduled.enabled = false
        scheduled.preapprovedTools = ["server__read", "server__list"]
        try store.save(scheduled)
        let saved = try XCTUnwrap(store.tasks.first)
        XCTAssertNotNil(saved.nextFire)
        XCTAssertEqual(saved.scheduleAnchor, now)
        XCTAssertEqual(saved.scheduleTimezoneIdentifier, zone.identifier)
        let run = TaskRun(taskID: saved.id, startedAt: now, endedAt: now.addingTimeInterval(5),
                          status: .preempted, reason: "Interrupted\n猫", transcript: "You: \\\"猫\nTool: résumé")
        try store.record(run)

        let restarted = TaskStore(directory: path)
        XCTAssertNil(restarted.notice)
        // Equatable includes every persisted task, schedule and run field.
        XCTAssertEqual(restarted.tasks, [saved])
        XCTAssertEqual(restarted.history(taskID: saved.id), [run])
    }

    func testEscapedTaskCollectionRejectsOverBudgetSaveWithoutLosingRestartData() throws {
        let path = try directory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TaskStore(directory: path, clock: { now })
        var rejected = false
        for index in 0..<100 {
            var scheduled = task(now: now)
            scheduled.name = "Escaped task \(index)"
            scheduled.prompt = String(repeating: "\\", count: ChatStore.maxPromptBytes)
            let previous = store.tasks
            let file = path.appendingPathComponent("tasks.json")
            let previousBytes = try? Data(contentsOf: file)
            do { try store.save(scheduled) }
            catch {
                XCTAssertEqual(error as? ChatFailure, .limit)
                XCTAssertEqual(store.tasks, previous)
                XCTAssertEqual(try Data(contentsOf: file), previousBytes)
                rejected = true
                break
            }
        }
        XCTAssertTrue(rejected, "JSON escaping must count toward the collection budget")
        XCTAssertGreaterThan(store.tasks.count, 1)
        XCTAssertLessThanOrEqual(try Data(contentsOf: path.appendingPathComponent("tasks.json")).count,
                                 TaskStore.taskFileByteLimit)
        let first = try XCTUnwrap(store.tasks.first)
        let run = TaskRun(taskID: first.id, startedAt: now, endedAt: now, status: .succeeded,
                          reason: nil, transcript: "History survives a rejected save")
        try store.record(run)
        let restarted = TaskStore(directory: path)
        XCTAssertNil(restarted.notice)
        XCTAssertEqual(restarted.tasks, store.tasks)
        XCTAssertEqual(restarted.history(taskID: first.id), [run])
        // An edit that adds JSON bytes is subject to the same collection budget.
        var edited = first
        edited.preapprovedTools = Set((0..<128).map { String(repeating: "\\", count: 61) + String($0) })
        XCTAssertThrowsError(try restarted.save(edited))
        XCTAssertEqual(TaskStore(directory: path).tasks, store.tasks)
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
