import Foundation

actor AsyncSemaphore {
    enum AdmissionError: Error, Equatable {
        case closed
    }

    private enum Ownership {
        case shared
        case exclusive
    }

    private struct Waiter {
        let id: UUID
        let ownership: Ownership
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Free shared permits; negative after lowering the limit below active holders.
    private var permits: Int
    private var limit: Int
    private var waiters: [Waiter] = []
    private var exclusiveHeld = false
    private var closed = false

    init(value: Int) {
        self.permits = max(0, value)
        self.limit = max(0, value)
    }

    /// Holders keep ownership across resize. An exclusive holder blocks shared
    /// admission until its entire operation, including cleanup, returns.
    /// Swap-generation stamps prevent late resizes from replacing newer limits.
    private var resizeStamp: Int?

    func resize(to value: Int, stamp: Int? = nil) {
        if let stamp {
            if let applied = resizeStamp, stamp < applied { return }
            resizeStamp = stamp
        }
        let newLimit = max(0, value)
        if !exclusiveHeld {
            permits += newLimit - limit
        }
        limit = newLimit
        drainWaiters()
    }

    func currentLimit() -> Int { limit }

    /// Queued acquisitions, excluding callers that already own the gate.
    func queuedWaiterCount() -> Int { waiters.count }

    /// Permanently prevents admission when native cleanup cannot prove retirement.
    /// Existing holders still own their permits and may finish safely.
    func failClosed() {
        closed = true
        let rejected = waiters
        waiters.removeAll()
        for waiter in rejected {
            waiter.continuation.resume(throwing: AdmissionError.closed)
        }
    }

    func withPermit<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await withOwnership(.shared, operation)
    }

    /// Drains shared holders, then reserves the gate through the operation's
    /// cleanup. This works even when a probe needs more rows than the shared limit.
    func withExclusivePermit<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await withOwnership(.exclusive, operation)
    }

    private func withOwnership<T>(
        _ ownership: Ownership,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await wait(for: ownership)
        do {
            // Cancellation can race with a continuation handing off ownership.
            try Task.checkCancellation()
            // Poisoning can likewise race with an already-resumed waiter.
            if closed { throw AdmissionError.closed }
            let result = try await operation()
            signal(ownership)
            return result
        } catch {
            signal(ownership)
            throw error
        }
    }

    private func wait(for ownership: Ownership) async throws {
        if closed { throw AdmissionError.closed }
        try Task.checkCancellation()
        if !exclusiveHeld, waiters.isEmpty {
            switch ownership {
            case .shared where permits > 0:
                permits -= 1
                return
            case .exclusive where permits == limit:
                exclusiveHeld = true
                permits = 0
                return
            default:
                break
            }
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Covers cancellation before the handler's actor task can run.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, ownership: ownership, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func signal(_ ownership: Ownership) {
        switch ownership {
        case .shared:
            permits += 1
        case .exclusive:
            exclusiveHeld = false
            permits = limit
        }
        drainWaiters()
    }

    private func drainWaiters() {
        guard !closed, !exclusiveHeld else { return }
        while let waiter = waiters.first {
            switch waiter.ownership {
            case .shared:
                guard permits > 0 else { return }
                permits -= 1
            case .exclusive:
                guard permits == limit else { return }
                exclusiveHeld = true
                permits = 0
            }
            waiters.removeFirst().continuation.resume()
            if exclusiveHeld { return }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drainWaiters()
    }
}
