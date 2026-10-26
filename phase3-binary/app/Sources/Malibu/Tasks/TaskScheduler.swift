import Combine
import Foundation

@MainActor
final class TaskScheduler: ObservableObject {
    typealias Execute = @MainActor (ScheduledTask) async throws -> String
    @Published private(set) var runningTaskID: UUID?
    static let maximumRounds = 6
    static let maximumOutputTokens = 8192
    static let maximumWallTime: TimeInterval = 90
    private let store: TaskStore
    private let clock: () -> Date
    private let timezone: () -> TimeZone
    private let execute: Execute
    private let cancelExecution: @MainActor () -> Void
    private let wallTime: TimeInterval
    private let partialTranscript: @MainActor () -> String
    private var timer: Task<Void, Never>?
    private var execution: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var runID: UUID?
    private var timedOut = false
    private var currentTask: ScheduledTask?
    private var startedAt: Date?

    init(store: TaskStore, clock: @escaping () -> Date = Date.init,
         timezone: @escaping () -> TimeZone = { .current },
         wallTime: TimeInterval = TaskScheduler.maximumWallTime,
         execute: @escaping Execute, partialTranscript: @escaping @MainActor () -> String = { "" }, cancel: @escaping @MainActor () -> Void = {}) {
        self.store = store; self.clock = clock; self.timezone = timezone
        self.wallTime = min(max(0.01, wallTime), Self.maximumWallTime)
        self.execute = execute; self.cancelExecution = cancel; self.partialTranscript = partialTranscript
    }

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.tick()
            }
        }
    }

    func tick() {
        guard runningTaskID == nil else { return }
        let now = clock()
        let zone = timezone()
        do { try store.refreshTimezone(now: now, timezone: zone) }
        catch { store.reportStorageError(); return }
        guard let task = store.tasks.filter({ $0.enabled && $0.nextFire.map { $0 <= now } == true })
            .sorted(by: { ($0.nextFire ?? .distantFuture) < ($1.nextFire ?? .distantFuture) }).first else { return }
        do { try store.consume(task, now: now, timezone: zone) }
        catch { store.reportStorageError(); return }
        begin(task)
    }

    func runNow(_ task: ScheduledTask) {
        guard runningTaskID == nil else {
            saveRun(task, start: clock(), status: .skipped, reason: "Another task is running.", transcript: "")
            return
        }
        begin(task)
    }

    func stop() {
        timer?.cancel(); timer = nil
        guard let currentTask, let startedAt else { return }
        execution?.cancel(); watchdog?.cancel(); cancelExecution()
        let partial = partialTranscript()
        saveRun(currentTask, start: startedAt, status: .skipped,
                reason: "Stopped when Malibu closed.",
                transcript: String(decoding: (partial.isEmpty ? "You: \(currentTask.prompt)" : partial).utf8.prefix(TaskStore.transcriptByteLimit - 3), as: UTF8.self))
        runID = nil; runningTaskID = nil; self.currentTask = nil; self.startedAt = nil
    }

    private func begin(_ task: ScheduledTask) {
        let id = UUID(); runID = id; runningTaskID = task.id
        currentTask = task; let start = clock(); startedAt = start; timedOut = false
        execution = Task { [weak self] in
            guard let self, self.runID == id else { return }
            var status: TaskRun.Status = .succeeded
            var reason: String?
            var transcript = "You: \(task.prompt)"
            do {
                let answer = try await self.execute(task)
                try Task.checkCancellation()
                guard answer.utf8.count + transcript.utf8.count + 10 <= TaskStore.transcriptByteLimit else {
                    throw TaskRunFailure.outputLimit
                }
                transcript += "\n\nMalibu: \(answer)"
            } catch {
                let wrapped = error as? TaskExecutionFailure
                let error = wrapped?.underlying ?? error
                if let saved = wrapped?.transcript {
                    transcript = String(decoding: saved.utf8.prefix(TaskStore.transcriptByteLimit - 3), as: UTF8.self)
                }
                if self.timedOut { status = .failed; reason = TaskRunFailure.timeout.localizedDescription }
                else if error as? ChatFailure == .preempted { status = .preempted; reason = "Paused for a paying customer." }
                else if error as? MCPFailure == .denied { status = .failed; reason = TaskRunFailure.unapprovedTool.localizedDescription }
                else if let failure = error as? TaskRunFailure { status = .failed; reason = failure.localizedDescription }
                else if let failure = error as? ChatFailure { status = .failed; reason = failure.localizedDescription }
                else if let failure = error as? MCPFailure { status = .failed; reason = failure.localizedDescription }
                else if error is CancellationError { status = .skipped; reason = "Stopped." }
                else { status = .failed; reason = "The agent could not complete this task." }
            }
            guard self.runID == id else { return }
            self.watchdog?.cancel(); self.watchdog = nil
            self.saveRun(task, start: start, status: status, reason: reason, transcript: transcript)
            self.runID = nil; self.runningTaskID = nil; self.currentTask = nil; self.startedAt = nil
            self.execution = nil
        }
        watchdog = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(self.wallTime)) } catch { return }
            guard self.runID == id else { return }
            self.timedOut = true
            self.execution?.cancel(); self.cancelExecution()
        }
    }

    private func saveRun(_ task: ScheduledTask, start: Date, status: TaskRun.Status,
                         reason: String?, transcript: String) {
        do {
            try store.record(TaskRun(taskID: task.id, startedAt: start, endedAt: clock(),
                                     status: status, reason: reason, transcript: transcript))
        } catch { store.reportStorageError() }
    }
}
