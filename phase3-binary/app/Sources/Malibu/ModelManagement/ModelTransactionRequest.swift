import Foundation

// One retained worker, including after a syscall outlives the UI deadline. The
// timer revokes authorization; it never closes another thread's reusable FD.
final class MalibuTransactionRequest: @unchecked Sendable {
    enum Failure: Error { case busy, expired }
    let nonce = UUID()
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let deadline: UInt64
    let beforeResourceRead: (@Sendable () -> Void)?
    let afterPayloadWrite: (@Sendable (MalibuTransactionRequest) -> Void)?
    private let lock = NSLock()
    private var revoked = false
    private var revocationHandler: (@Sendable () -> Void)?
    init(timeout: TimeInterval, beforeResourceRead: (@Sendable () -> Void)? = nil, afterPayloadWrite: (@Sendable (MalibuTransactionRequest) -> Void)? = nil) {
        self.beforeResourceRead = beforeResourceRead
        self.afterPayloadWrite = afterPayloadWrite
        deadline = startedAt + UInt64(max(0, timeout) * 1_000_000_000)
    }
    var remaining: TimeInterval { let now = DispatchTime.now().uptimeNanoseconds; return Double(deadline > now ? deadline - now : 0) / 1_000_000_000 }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        guard !revoked, DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.expired }
    }
    func revoke() { lock.lock(); revoked = true; let handler = revocationHandler; lock.unlock(); handler?() }
    func onRevocation(_ handler: (@Sendable () -> Void)?) {
        lock.lock(); revocationHandler = handler; let alreadyRevoked = revoked; lock.unlock()
        if alreadyRevoked { handler?() }
    }
    func commitSpawn() throws { try check() }

}

private final class MalibuRequestCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let saved = continuation; continuation = nil; lock.unlock()
        saved?.resume(with: result)
    }
}

final class MalibuTransactionWorker: @unchecked Sendable {
    static let shared = MalibuTransactionWorker()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "tech.malibu.transaction-resource", qos: .userInitiated)
    private var active: UUID?
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return active != nil }
    private func reserve(_ request: MalibuTransactionRequest) throws {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { throw MalibuTransactionRequest.Failure.busy }
        active = request.nonce
    }
    private func release(_ request: MalibuTransactionRequest) {
        lock.lock(); if active == request.nonce { active = nil }; lock.unlock()
    }
    func run<Value: Sendable>(request: MalibuTransactionRequest,
                             work: @escaping @Sendable (MalibuTransactionRequest) throws -> Value) async throws -> Value {
        try reserve(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = MalibuRequestCompletion(continuation)
                request.onRevocation { completion.finish(.failure(MalibuTransactionRequest.Failure.expired)) }
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                timer.schedule(deadline: DispatchTime(uptimeNanoseconds: request.deadline))
                timer.setEventHandler { request.revoke(); completion.finish(.failure(MalibuTransactionRequest.Failure.expired)) }
                timer.resume()
                queue.async {
                    let result = Result { try request.check(); return try work(request) }
                    timer.cancel()
                    request.onRevocation(nil)
                    self.release(request)
                    // A timed-out read can neither revive permission nor replace
                    // the outcome already delivered by the independent timer.
                    if case .success = result {
                        do { try request.check(); completion.finish(result) }
                        catch { completion.finish(.failure(error)) }
                    } else { completion.finish(result) }
                }
            }
        } onCancel: { request.revoke() }
    }
    func run<Value: Sendable>(timeout: TimeInterval = 10,
                             work: @escaping @Sendable (MalibuTransactionRequest) throws -> Value) async throws -> Value {
        try await run(request: MalibuTransactionRequest(timeout: timeout), work: work)
    }
}
