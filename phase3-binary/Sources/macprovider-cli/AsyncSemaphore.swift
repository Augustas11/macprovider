actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.permits = max(0, value)
    }

    func withPermit<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await wait()
        do {
            let result = try await operation()
            signal()
            return result
        } catch {
            signal()
            throw error
        }
    }

    private func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
