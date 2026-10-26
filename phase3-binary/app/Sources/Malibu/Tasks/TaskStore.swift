import Combine
import Darwin
import Foundation

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [ScheduledTask] = []
    @Published private(set) var notice: String?
    @Published private var runs: [TaskRun] = []
    let directory: URL
    static let retention = 20
    static let transcriptByteLimit = 128 * 1024
    private let clock: () -> Date
    private let timezone: () -> TimeZone

    init(directory: URL = ProviderPaths.current.appSupport.appendingPathComponent("Tasks", isDirectory: true),
         clock: @escaping () -> Date = Date.init, timezone: @escaping () -> TimeZone = { .current }) {
        self.directory = directory; self.clock = clock; self.timezone = timezone
        do {
            try TaskPrivateFiles.prepare(directory)
            tasks = try TaskPrivateFiles.read([ScheduledTask].self, from: directory.appendingPathComponent("tasks.json"), maximum: 1024 * 1024) ?? []
            runs = try TaskPrivateFiles.read([TaskRun].self, from: directory.appendingPathComponent("runs.json"), maximum: 257 * 1024 * 1024) ?? []
            guard tasks.count <= 100, runs.count <= 2000 else { throw ChatFailure.limit }
            for id in Set(runs.map(\.taskID)) {
                let kept = Set(runs.filter { $0.taskID == id }.suffix(Self.retention).map(\.id))
                runs.removeAll { $0.taskID == id && !kept.contains($0.id) }
            }
        } catch { tasks = []; runs = []; notice = "Tasks could not be loaded from their local files." }
    }

    func save(_ task: ScheduledTask, original: ScheduledTask? = nil) throws {
        guard !task.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.name.utf8.count <= 256, task.prompt.utf8.count <= ChatStore.maxPromptBytes,
              !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.preapprovedTools.count <= 128,
              task.preapprovedTools.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              (0...23).contains(task.schedule.hour), (0...59).contains(task.schedule.minute) else { throw ChatFailure.limit }
        var updated = task
        if let old = tasks.first(where: { $0.id == task.id }) {
            // The editor may have stayed open while the scheduler consumed a run.
            // Only explicit schedule/enabled edits may replace scheduler-owned state.
            let baseline = original ?? old
            let scheduleChanged = baseline.schedule != task.schedule
            let enabledChanged = baseline.enabled != task.enabled
            updated.enabled = enabledChanged ? task.enabled : old.enabled
            updated.nextFire = old.nextFire
            if scheduleChanged || (enabledChanged && task.enabled) {
                updated.nextFire = task.schedule.initialFire(now: clock(), timezone: timezone())
            }
        } else {
            guard tasks.count < 100 else { throw ChatFailure.limit }
            updated.nextFire = task.schedule.initialFire(now: clock(), timezone: timezone())
        }
        var result = tasks.filter { $0.id != task.id }; result.append(updated)
        try TaskPrivateFiles.write(result, to: directory.appendingPathComponent("tasks.json"))
        tasks = result; notice = nil
    }

    func remove(_ id: UUID) throws {
        let result = tasks.filter { $0.id != id }
        try TaskPrivateFiles.write(result, to: directory.appendingPathComponent("tasks.json"))
        tasks = result
        runs.removeAll { $0.taskID == id }
        try TaskPrivateFiles.write(runs, to: directory.appendingPathComponent("runs.json"))
    }

    func history(taskID: UUID) -> [TaskRun] { runs.filter { $0.taskID == taskID }.reversed() }

    /// Advance before executing, so one launch consumes all missed occurrences.
    func consume(_ task: ScheduledTask, now: Date, timezone: TimeZone) throws {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var result = tasks
        result[index].nextFire = task.schedule.nextFire(after: now, timezone: timezone)
        if task.schedule.kind == .once { result[index].enabled = false }
        try TaskPrivateFiles.write(result, to: directory.appendingPathComponent("tasks.json"))
        tasks = result
    }

    func record(_ run: TaskRun) throws {
        guard run.transcript.utf8.count <= Self.transcriptByteLimit else { throw TaskRunFailure.outputLimit }
        var result = runs
        result.append(run)
        let old = result.filter { $0.taskID == run.taskID }.dropLast(Self.retention).map(\.id)
        result.removeAll { old.contains($0.id) }
        try TaskPrivateFiles.write(result, to: directory.appendingPathComponent("runs.json"))
        runs = result
    }

    func reportStorageError() { notice = "The task result could not be saved." }
}

private enum TaskPrivateFiles {
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else { throw ChatFailure.unsafePath }
    }
    static func read<T: Decodable>(_ type: T.Type, from file: URL, maximum: Int) throws -> T? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw ChatFailure.unsafePath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size <= maximum, fchmod(fd, 0o600) == 0 else { throw ChatFailure.unsafePath }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n >= 0 else { throw ChatFailure.unsafePath }
            if n == 0 { break }
            guard data.count + n <= maximum else { throw ChatFailure.limit }
            data.append(contentsOf: buffer.prefix(n))
        }
        return try JSONDecoder().decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, to file: URL) throws {
        try prepare(file.deletingLastPathComponent())
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChatFailure.unsafePath }
        defer { close(fd); unlink(temp.path) }
        let data = try JSONEncoder().encode(value)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard n > 0 else { throw ChatFailure.unsafePath }
                offset += n
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0, rename(temp.path, file.path) == 0 else { throw ChatFailure.unsafePath }
    }
}
