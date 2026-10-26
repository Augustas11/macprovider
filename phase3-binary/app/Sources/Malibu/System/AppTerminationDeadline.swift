import Foundation

/// An unstructured watchdog can finish even when drain ignores cancellation.
/// A task group would await the hung child before returning.
@MainActor
final class AppTerminationDeadline {
    static let graceSeconds: TimeInterval = 35
    private var drainTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private(set) var started = false
    private(set) var finished = false

    func begin(
        drain: @escaping @MainActor () async -> Void,
        wait: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(nanoseconds: 35_000_000_000)
        },
        reply: @escaping @MainActor (_ timedOut: Bool) -> Void
    ) {
        guard !started else { return }
        started = true
        drainTask = Task { @MainActor [weak self] in
            await drain()
            self?.finish(timedOut: false, reply: reply)
        }
        watchdog = Task { @MainActor [weak self] in
            do { try await wait() } catch { return }
            self?.finish(timedOut: true, reply: reply)
        }
    }

    private func finish(timedOut: Bool, reply: @MainActor (Bool) -> Void) {
        guard !finished else { return }
        finished = true
        if timedOut { drainTask?.cancel() }
        watchdog?.cancel()
        reply(timedOut)
    }
}
