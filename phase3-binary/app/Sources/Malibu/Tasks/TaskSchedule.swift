import Foundation

struct TaskSchedule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case once, hourly, daily, weekdays }
    var kind: Kind = .daily
    var date: Date = Date()
    var hour: Int = 9
    var minute: Int = 0

    /// Calendar matching uses the device's timezone on each evaluation. A missing
    /// DST time runs at the next valid time; a repeated time runs only once.
    func nextFire(after date: Date, timezone: TimeZone) -> Date? {
        if kind == .once { return self.date > date ? self.date : nil }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        var components = DateComponents()
        components.second = 0
        components.minute = kind == .hourly ? 0 : minute
        if kind != .hourly { components.hour = hour }
        var cursor = date
        for _ in 0..<8 {
            guard let next = calendar.nextDate(after: cursor, matching: components,
                                              matchingPolicy: .nextTime,
                                              repeatedTimePolicy: .first, direction: .forward) else { return nil }
            if kind != .weekdays || (2...6).contains(calendar.component(.weekday, from: next)) { return next }
            cursor = next
        }
        return nil
    }

    func initialFire(now: Date, timezone: TimeZone) -> Date? {
        kind == .once ? date : nextFire(after: now, timezone: timezone)
    }
}

struct ScheduledTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = "New task"
    var agentID: UUID
    var prompt: String = ""
    var schedule = TaskSchedule()
    var enabled = true
    var preapprovedTools: Set<String> = []
    var nextFire: Date?
    // Persist the evaluation origin so a device-zone change can recompute the
    // pending wall-clock occurrence without dropping a missed catch-up run.
    var scheduleAnchor: Date?
    var scheduleTimezoneIdentifier: String?
}

struct TaskRun: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case succeeded, failed, preempted, skipped }
    var id = UUID()
    let taskID: UUID
    let startedAt: Date
    let endedAt: Date
    let status: Status
    let reason: String?
    let transcript: String
}

enum TaskRunFailure: Error, LocalizedError {
    case unavailableAgent, unapprovedTool, timeout, outputLimit
    var errorDescription: String? {
        switch self {
        case .unavailableAgent: return "The selected agent is unavailable."
        case .unapprovedTool: return "The agent requested a tool that was not approved for this task."
        case .timeout: return "The task reached its time limit."
        case .outputLimit: return "The task reached its output limit."
        }
    }
}

/// Preserves the bounded work completed before a task failure without logging it.
struct TaskExecutionFailure: Error {
    let underlying: Error
    let transcript: String
}
