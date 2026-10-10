import Foundation

actor AsyncSemaphore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Free permits; negative while a lowered limit still has holders above it.
    private var permits: Int
    private var limit: Int
    private var waiters: [Waiter] = []

    init(value: Int) {
        self.permits = max(0, value)
        self.limit = max(0, value)
    }

    /// Changes the limit in place. Holders keep their permits; after a
    /// decrease no new holder is admitted until the count falls under the new
    /// limit, and after an increase waiters are admitted at once.
    /// `stamp` (the runtime's swap generation) orders concurrent resizes: a
    /// resize stamped older than one already applied is ignored.
    private var resizeStamp: Int?

    func resize(to value: Int, stamp: Int? = nil) {
        if let stamp {
            if let applied = resizeStamp, stamp < applied { return }
            resizeStamp = stamp
        }
        let newLimit = max(0, value)
        permits += newLimit - limit
        limit = newLimit
        while permits > 0, !waiters.isEmpty {
            permits -= 1
            waiters.removeFirst().continuation.resume()
        }
    }

    func currentLimit() -> Int { limit }

    func withPermit<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await wait()
        do {
            let result = try await operation()
            signal()
            return result
        } catch {
            signal()
            throw error
        }
    }

    private func wait() async throws {
        if permits > 0 {
            permits -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func signal() {
        if permits < 0 {
            permits += 1
            return
        }
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
