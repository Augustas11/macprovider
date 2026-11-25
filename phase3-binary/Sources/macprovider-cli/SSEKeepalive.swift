import Foundation

/// Sends an SSE comment while a stream is quiet. A model that buffers a tool
/// call can emit nothing for a minute; without bytes on the wire, clients'
/// idle timeouts drop the stream. Clients ignore lines that do not start with
/// `data:`, so the comment never changes the reply. After `quietLimit`
/// without a data event the comments stop, so a wedged runtime is not held
/// open: the client's own stall guard then ends the request.
final class SSEKeepalive: @unchecked Sendable {
    static let comment = ": keepalive\n\n"
    private let lock = NSLock()
    private let interval: Duration
    private let quietLimit: Duration
    private let emit: @Sendable () -> Void
    private var lastOutput = ContinuousClock.now
    private var lastData = ContinuousClock.now
    private var stopped = false
    private var task: Task<Void, Never>?

    init(interval: Duration = .seconds(10), quietLimit: Duration = .seconds(300),
         emit: @escaping @Sendable () -> Void) {
        self.interval = interval
        self.quietLimit = quietLimit
        self.emit = emit
    }

    /// Runs `body` with the keepalive active and always stops it before
    /// returning, so no comment can follow the terminal `[DONE]`.
    func during<T>(_ body: () async throws -> T) async rethrows -> T {
        start()
        defer { stop() }
        return try await body()
    }

    /// A data event was written; it resets both the keepalive and quiet clocks.
    func noteOutput(at now: ContinuousClock.Instant = ContinuousClock.now) {
        lock.lock()
        lastOutput = now
        lastData = now
        lock.unlock()
    }

    func start() {
        let poll = interval / 4
        let heartbeat = Task.detached { [self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: poll) } catch { return }
                _ = self.tick()
            }
        }
        lock.lock()
        if stopped { heartbeat.cancel() } else { task = heartbeat }
        lock.unlock()
    }

    /// Emits a comment when nothing was written for `interval`. Holding the
    /// lock across `emit` orders it before any write that follows `stop()`.
    @discardableResult
    func tick(now: ContinuousClock.Instant = ContinuousClock.now) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, now - lastData < quietLimit, now - lastOutput >= interval else { return false }
        lastOutput = now
        emit()
        return true
    }

    func stop() {
        lock.lock()
        stopped = true
        task?.cancel()
        task = nil
        lock.unlock()
    }
}
