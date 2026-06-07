import Foundation

public struct SwitchStateStore: Sendable {
    /// Default cooldown window per SPEC-011 v0.5 R-3.1.4.
    public static let defaultCooldownWindowMs: Int64 = 10_000

    public let path: URL
    public let cooldownWindowMs: Int64

    public init(path: URL, cooldownWindowMs: Int64 = SwitchStateStore.defaultCooldownWindowMs) {
        self.path = path
        self.cooldownWindowMs = cooldownWindowMs
    }

    /// Returns the recorded last-switch timestamp (epoch ms), or nil
    /// if the file does not exist OR cannot be parsed as Int64.
    public func readLastSwitchMs() -> Int64? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return nil
        }
        return Int64(text.trimmingCharacters(in: .newlines))
    }

    /// Writes the given timestamp atomically (write-to-temp-then-rename).
    /// Creates the parent directory if missing. Throws on filesystem
    /// errors that prevent the write.
    public func writeLastSwitchMs(_ value: Int64) throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let tmpURL = URL(fileURLWithPath: path.path + ".tmp")
        try? FileManager.default.removeItem(at: tmpURL)
        try String(value).write(to: tmpURL, atomically: false, encoding: .utf8)

        if FileManager.default.fileExists(atPath: path.path) {
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: path)
        }
    }

    /// Returns the cooldown decision:
    /// - .clear        — no recent switch (file missing or > window)
    /// - .cooldown(s)  — within the window; `secondsRemaining` is
    ///                   ceil((window - elapsed) / 1000), clamped to
    ///                   [1, cooldownWindowMs / 1000]
    public func cooldownDecision(now: Int64) -> CooldownDecision {
        guard let lastSwitchMs = readLastSwitchMs() else {
            return .clear
        }

        let elapsed = now - lastSwitchMs
        guard elapsed >= 0, elapsed < cooldownWindowMs else {
            return .clear
        }

        let remainingMs = cooldownWindowMs - elapsed
        let ceilingSeconds = Int((remainingMs + 999) / 1000)
        let maxSeconds = max(1, Int((cooldownWindowMs + 999) / 1000))
        return .cooldown(secondsRemaining: min(max(ceilingSeconds, 1), maxSeconds))
    }

    public enum CooldownDecision: Equatable, Sendable {
        case clear
        case cooldown(secondsRemaining: Int)
    }
}
