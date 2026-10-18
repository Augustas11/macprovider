import Foundation
import MacProviderCore

/// SPEC-001-R011: where a request on the provider's own HTTP listener came
/// from. `network` is coordinator-dispatched buyer work (the WebSocket relay,
/// or a direct-HTTP dispatch that carries coordinator settlement metadata).
/// `local` is any other loopback client, such as the Mac app's Chat screen.
enum RequestOrigin: String, Sendable {
    case network
    case local
}

/// SPEC-001-R011 customers-first policy for local requests. Paying network
/// buyers always win: a reserved slot stays free for them, local work queues
/// behind them, and a buyer that would otherwise wait on local work preempts
/// it within `preemptionWindowMS`.
struct LocalPriorityPolicy: Sendable, Equatable {
    static let defaultReservedBuyerSlots = 1
    static let maximumReservedBuyerSlots = 64
    static let defaultPreemptionWindowMS = 0
    static let maximumPreemptionWindowMS = 2_000
    static let defaultQueueWaitMS = 30_000
    /// Local requests that may wait for a slot at once; more are declined.
    static let maximumQueuedLocalRequests = 16

    var reservedBuyerSlots = LocalPriorityPolicy.defaultReservedBuyerSlots
    var preemptionWindowMS = LocalPriorityPolicy.defaultPreemptionWindowMS
    var queueWaitMS = LocalPriorityPolicy.defaultQueueWaitMS

    /// Slots local work may never take. A single-slot provider reserves
    /// nothing (local work could never run) and relies on preemption instead.
    func reservation(forServedSlots slots: Int) -> Int {
        guard slots > 1 else { return 0 }
        return min(max(0, reservedBuyerSlots), slots - 1)
    }
}

/// One admitted (or waiting) local request. A buyer arrival that needs the
/// slot calls `preempt()`, which runs every registered cancellation once.
final class LocalPreemptionLease: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var preempted = false
    private var handlers: [@Sendable () -> Void] = []

    var isPreempted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return preempted
    }

    /// Runs `handler` on preemption, or at once if preemption already fired.
    func onPreempt(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if preempted {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }

    func preempt() {
        lock.lock()
        guard !preempted else {
            lock.unlock()
            return
        }
        preempted = true
        let pending = handlers
        handlers = []
        lock.unlock()
        pending.forEach { $0() }
    }
}

enum LocalAdmission: Sendable, Equatable {
    case admitted(Date)
    /// The provider is draining or has no model; same answer a buyer gets.
    case unavailable
    /// Buyers held every slot local work may use for the whole queue wait,
    /// or a buyer preempted the request while it waited.
    case preempted
    /// The local client went away while waiting.
    case cancelled
}

/// SPEC-001-R011 local-use counters. Process-lifetime, never persisted, and
/// never part of heartbeat, earnings, receipts or buyer-facing stats.
struct LocalUsageSnapshot: Sendable, Equatable {
    var requestsInFlight = 0
    var requestsTotal = 0
    var requestsCompleted = 0
    var requestsFailed = 0
    var requestsPreempted = 0
    var requestsDeclined = 0
    var promptTokensTotal: Int64 = 0
    var completionTokensTotal: Int64 = 0
    var reservedBuyerSlots = 0
    var preemptionWindowMS = LocalPriorityPolicy.defaultPreemptionWindowMS
    var queueWaitMS = LocalPriorityPolicy.defaultQueueWaitMS

    var statusJSON: [String: Any] {
        [
            "billable": false,
            "heartbeat_counted": false,
            "priority": "customers_first",
            "requests_in_flight": requestsInFlight,
            "requests_total": requestsTotal,
            "requests_completed": requestsCompleted,
            "requests_failed": requestsFailed,
            "requests_preempted": requestsPreempted,
            "requests_declined": requestsDeclined,
            "prompt_tokens_total": promptTokensTotal,
            "completion_tokens_total": completionTokensTotal,
            "reserved_buyer_slots": reservedBuyerSlots,
            "preemption_window_ms": preemptionWindowMS,
            "queue_wait_ms": queueWaitMS,
        ]
    }
}

extension APIError {
    /// SPEC-001-R011: a paying buyer needed the slot.
    static func localPreempted(running: Bool) -> APIError {
        APIError(
            status: 503,
            message: running
                ? "Local request was stopped because a network customer needed this Mac"
                : "Network customers are using this Mac; local requests wait behind them",
            type: "server_error",
            code: "local_preempted",
            retryable: true,
            inferenceRan: running
        )
    }
}
