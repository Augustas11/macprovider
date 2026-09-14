import Darwin
import Dispatch
import Foundation

enum ModelTransactionOwnerLifetimeError: Error, CustomStringConvertible {
    case durableHeartbeatUnavailable
    var description: String { "durable transaction progress unavailable; inspect the original operation before retrying" }
}

/// A stalled owner cannot outlive its last durable heartbeat indefinitely. This
/// guard observes only its own command; existing candidate-parent and restoration
/// pipe guards remain responsible for the children that command actually owns.
final class ModelTransactionOwnerLifetimeGuard: @unchecked Sendable {
    private static let fenceNanoseconds: UInt64 = 8_000_000_000
    private static let exitNanoseconds: UInt64 = 10_000_000_000
    private let lock = NSLock()
    private var lastDurableHeartbeat = DispatchTime.now().uptimeNanoseconds
    private var fenced = false
    private var cancellationDispatched = false
    private let onFence: @Sendable () -> Void
    private let cancellationQueue = DispatchQueue(label: "macprovider.transaction-owner-cancellation")
    private let timer: DispatchSourceTimer

    init(onFence: @escaping @Sendable () -> Void) {
        self.onFence = onFence
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "macprovider.transaction-owner-watchdog"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
    }

    /// Call only after this owner's exact-generation start, heartbeat or terminal
    /// record and its directory have completed fsync. Busy attempts, unrelated
    /// writes and stream/index activity never acknowledge owner progress.
    /// Once fenced, even a late successful write cannot revive this owner.
    func acknowledgeDurableHeartbeat() throws {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastDurableHeartbeat >= Self.fenceNanoseconds { fenced = true }
        let rejected = fenced
        if !rejected { lastDurableHeartbeat = now }
        let notify = takeCancellationNotificationLocked()
        lock.unlock()
        if notify { dispatchCancellation() }
        if rejected { throw ModelTransactionOwnerLifetimeError.durableHeartbeatUnavailable }
    }

    /// Check immediately before publication/result/config mutation or a new
    /// worker launch. This observes the clock itself rather than waiting for a
    /// scheduled timer callback to publish the fence.
    func checkPublicationAllowed() throws {
        if isFenced { throw ModelTransactionOwnerLifetimeError.durableHeartbeatUnavailable }
    }

    var isFenced: Bool {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastDurableHeartbeat >= Self.fenceNanoseconds { fenced = true }
        let result = fenced
        let notify = takeCancellationNotificationLocked()
        lock.unlock()
        if notify { dispatchCancellation() }
        return result
    }

    private func poll() {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - lastDurableHeartbeat
        if elapsed >= Self.fenceNanoseconds { fenced = true }
        let notify = takeCancellationNotificationLocked()
        lock.unlock()
        // No journal work, callback, cleanup or child wait can block this queue.
        if elapsed >= Self.exitNanoseconds { _exit(70) }
        if notify { dispatchCancellation() }
    }

    // The state lock is never held during filesystem I/O or caller callbacks.
    private func takeCancellationNotificationLocked() -> Bool {
        guard fenced, !cancellationDispatched else { return false }
        cancellationDispatched = true
        return true
    }

    private func dispatchCancellation() {
        // Cancellation itself can block on a Swift executor or lifecycle work;
        // it must not prevent the independent ten-second process deadline.
        cancellationQueue.async(execute: onFence)
    }

    deinit { timer.cancel() }
}
