import Foundation
import MLX

/// SPEC-038 FR-CB9 (v0.3.61, #2462): the small-row route of the request whose
/// forward is being built.
///
/// The MLX core captures the route on each quantized-matmul op when the op is
/// added to the graph, from a scope set on the current thread
/// (`MLX.withSmallMRoute`). A request's route travels through the async
/// scheduler and backend as a task-local value (`run`), and each synchronous
/// graph build reads it (`build`) and sets the thread scope only around that
/// build: a thread scope never spans a suspension point, and each forward is
/// built under exactly one scope. With no task-local route the build runs on
/// the process route.
enum SmallMRouteScope {
    @TaskLocal static var current: SmallMRoute?

    /// Runs `operation` with `route` as the task's request route.
    nonisolated(nonsending) static func run<R>(
        _ route: SmallMRoute,
        _ operation: nonisolated(nonsending) () async throws -> R
    ) async rethrows -> R {
        try await $current.withValue(route, operation: operation)
    }

    /// Builds `body`'s graph on the task's request route. `body` must build
    /// synchronously (calling a compiled function counts); it need not
    /// evaluate inside.
    ///
    /// Fails closed in a `mixed` process when the task carries no request
    /// route: the build would otherwise take the process route (stock
    /// order) whatever the rows are. Any other process runs one route, so no
    /// route means the process route.
    static func build<R>(mixed: Bool = SmallMRoute.processMixed, _ body: () throws -> R) throws -> R {
        guard let route = current?.mlxRoute else {
            if mixed { throw ContinuousBatchSchedulerError.unsupported(missingRouteCode) }
            #if DEBUG
            buildObserverForTest?(currentSmallMRoute())
            #endif
            return try body()
        }
        return try withSmallMRoute(route) {
            #if DEBUG
            buildObserverForTest?(currentSmallMRoute())
            #endif
            return try body()
        }
    }

    #if DEBUG
    /// Tests: called in every build, just before its graph is built, with the
    /// route MLX captures on this thread there.
    nonisolated(unsafe) static var buildObserverForTest: (@Sendable (MLX.SmallMRoute?) -> Void)?
    #endif

    /// The failure a `mixed` build with no request route throws.
    static let missingRouteCode = "small_m_route_scope_missing"

    /// Splits items into runs of one route each, in first-appearance order
    /// of the routes, keeping the items' order inside each group.
    static func groups<T>(_ items: [T], route: (T) -> SmallMRoute) -> [[T]] {
        var order: [SmallMRoute] = []
        var byRoute: [SmallMRoute: [T]] = [:]
        for item in items {
            let key = route(item)
            if byRoute[key] == nil { order.append(key) }
            byRoute[key, default: []].append(item)
        }
        return order.compactMap { byRoute[$0] }
    }

    /// Nil when MLX's process route matches `route`, else why not. The core
    /// reads the process route once; this read happens after `SmallMRoute.apply`.
    static func processRouteMismatch(applied route: SmallMRoute) -> String? {
        let core = processSmallMRoute()
        guard core != route.mlxRoute else { return nil }
        let name = core.map { $0 == .rowInvariant ? "row_invariant" : "stock_order" } ?? "serial_only"
        return "event=small_m_route action=mlx_process_route_mismatch applied=\(route.rawValue) mlx=\(name)"
    }
}

extension SmallMRoute {
    /// Port of core `metal::is_nax_available` (`mlx/backend/metal/device.cpp`):
    /// macOS 26.2 or later and architecture generation 17 or later (18 for a
    /// phone, `p`), the generation read from the two digits before the last
    /// character of the architecture name exactly as core reads it.
    static func naxAvailable(architecture: String, osSupportsNAX: Bool) -> Bool {
        guard osSupportsNAX else { return false }
        let bytes = Array(architecture.utf8)
        func digit(_ index: Int) -> Int {
            guard index >= 0, index < bytes.count else { return 0 }
            let value = Int(bytes[index]) - 48
            return (0 ..< 10).contains(value) ? value : 0
        }
        let generation = bytes.count >= 3 ? digit(bytes.count - 3) * 10 + digit(bytes.count - 2) : 0
        return generation >= (bytes.last == UInt8(ascii: "p") ? 18 : 17)
    }

    /// Whether this process's GPU takes the NAX kernels. Reads the Metal
    /// device (or `MLX_METAL_GPU_ARCH`), not the MLX core, so it is safe
    /// before MLX is first used.
    static func processNAXAvailable() -> Bool {
        let osSupportsNAX: Bool
        if #available(macOS 26.2, *) {
            osSupportsNAX = true
        } else {
            osSupportsNAX = false
        }
        return naxAvailable(
            architecture: ModelRuntime.metalArchitectureForQuantizedRoutes(), osSupportsNAX: osSupportsNAX)
    }

    /// The MLX core route this route selects; nil for serial-only, which no
    /// scope can select.
    var mlxRoute: MLX.SmallMRoute? {
        switch self {
        case .rowInvariant: return .rowInvariant
        case .stockOrder: return .stockOrder
        case .serialOnly: return nil
        }
    }
}

/// SPEC-038 FR-CB9 (v0.3.61): in-flight requests per route, for
/// `continuous_batching.small_m_route_requests` in a `mixed` process, and
/// (v0.3.63) the admission that reads them (`admit`).
final class SmallMRouteRequestCounter: @unchecked Sendable {
    static let shared = SmallMRouteRequestCounter()

    private let lock = NSLock()
    private var counts: [SmallMRoute: Int] = [:]
    private var admissions: [SmallMRoute.AdmissionReason: Int] = [:]
    /// Row-invariant requests an ordinary admission joins (`Ticket.joinable`):
    /// native ones, reserved or admitted, and ordinary ones that joined them.
    /// A request on row-invariant only for its own conversation-cache entry
    /// is left out, so one keyed conversation never moves other requests off
    /// stock order.
    private var joinableRowInvariant = 0

    /// One admitted request's place in the count. `end` is idempotent, so a
    /// caller may end it where the request leaves the scheduler and again,
    /// as a backstop, on every exit path.
    final class Ticket: @unchecked Sendable {
        let route: SmallMRoute
        let reason: SmallMRoute.AdmissionReason
        /// Whether ordinary admissions join this request's route while it is
        /// in flight: a row-invariant native request, or an ordinary one that
        /// joined one (`native_active`); never `conversation_cache`.
        let joinable: Bool
        private let counter: SmallMRouteRequestCounter
        private let lock = NSLock()
        private var open = true

        fileprivate init(route: SmallMRoute, reason: SmallMRoute.AdmissionReason, counter: SmallMRouteRequestCounter) {
            self.route = route
            self.reason = reason
            self.joinable = route == .rowInvariant && (reason == .nativeAdmitted || reason == .nativeActive)
            self.counter = counter
        }

        func end() {
            if close() { counter.release(self) }
        }

        /// Marks the ticket ended without touching the count; true if it was open.
        fileprivate func close() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let wasOpen = open
            open = false
            return wasOpen
        }

        fileprivate var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return open
        }
    }

    /// SPEC-038 FR-CB9 (v0.3.63): counts a request decided native at
    /// registration as `rowInvariant` in flight until `admit` takes the
    /// ticket over (or the request leaves: the caller ends it on every exit
    /// path), so an ordinary request that reaches admission first still
    /// joins `rowInvariant`. Nil outside `mixed`.
    func reserveNative(mixed: Bool = SmallMRoute.processMixed) -> Ticket? {
        guard mixed else { return nil }
        lock.lock()
        counts[.rowInvariant, default: 0] += 1
        joinableRowInvariant += 1
        lock.unlock()
        return Ticket(route: .rowInvariant, reason: .nativeAdmitted, counter: self)
    }

    /// Ends one ticket's count; under `lock` when `locked`.
    fileprivate func release(_ ticket: Ticket, locked: Bool = false) {
        if !locked { lock.lock() }
        counts[ticket.route] = max(0, (counts[ticket.route] ?? 0) - 1)
        if ticket.joinable { joinableRowInvariant = max(0, joinableRowInvariant - 1) }
        if !locked { lock.unlock() }
    }

    /// SPEC-038 FR-CB9 (v0.3.63): fixes a request's route
    /// (`SmallMRoute.admissionRoute`) from the requests in flight and counts
    /// it in flight, in one step, so two concurrent admissions cannot both
    /// miss each other. In `mixed` it logs
    /// `event=small_m_route_admission route=... reason=...`.
    ///
    /// `reservation` is the request's own `reserveNative` ticket: a request
    /// still native takes it over (it is already counted); one that turned
    /// ordinary since releases it first, so it never counts as its own
    /// row-invariant request in flight. `storedRoute` is the route of the
    /// hot conversation-cache entry stored for the request's key. Only
    /// joinable row-invariant requests (`Ticket.joinable`) move an ordinary
    /// admission onto row-invariant.
    func admit(
        nativeAdmitted: Bool,
        reservation: Ticket? = nil,
        storedRoute: SmallMRoute? = nil,
        processRoute: SmallMRoute = SmallMRoute.processRoute,
        mixed: Bool = SmallMRoute.processMixed,
        log: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) -> Ticket {
        lock.lock()
        var reused: Ticket?
        if let reservation, reservation.isOpen {
            if nativeAdmitted, mixed {
                reused = reservation
            } else if reservation.close() {
                release(reservation, locked: true)
            }
        }
        // In-flight counts other than this request.
        let rowInvariant = (counts[.rowInvariant] ?? 0) - (reused == nil ? 0 : 1)
        let joinable = joinableRowInvariant - (reused == nil ? 0 : 1)
        let stockOrder = counts[.stockOrder] ?? 0
        let (route, reason) = SmallMRoute.admissionRoute(
            nativeAdmitted: nativeAdmitted, rowInvariantInFlight: joinable, storedRoute: storedRoute,
            processRoute: processRoute, mixed: mixed
        )
        let ticket = reused ?? Ticket(route: route, reason: reason, counter: self)
        if reused == nil {
            counts[route, default: 0] += 1
            if ticket.joinable { joinableRowInvariant += 1 }
        }
        admissions[reason, default: 0] += 1
        lock.unlock()
        if mixed {
            log("event=small_m_route_admission route=\(route.rawValue) reason=\(reason.rawValue) "
                + "in_flight_row_invariant=\(rowInvariant) in_flight_stock_order=\(stockOrder) "
                + "joinable_row_invariant=\(joinable)\n")
        }
        return ticket
    }

    /// Admissions per reason since start, for
    /// `continuous_batching.small_m_route_admissions` (v0.3.63).
    func admissionSnapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var out: [String: Int] = [:]
        for reason in SmallMRoute.AdmissionReason.allCases where reason != .processRoute {
            out[reason.rawValue] = admissions[reason] ?? 0
        }
        return out
    }

    func begin(_ route: SmallMRoute) {
        lock.lock()
        defer { lock.unlock() }
        counts[route, default: 0] += 1
    }

    func end(_ route: SmallMRoute) {
        lock.lock()
        defer { lock.unlock() }
        counts[route] = max(0, (counts[route] ?? 0) - 1)
    }

    /// Counts `operation` as one in-flight request on `route`.
    nonisolated(nonsending) func tracking<R>(
        _ route: SmallMRoute,
        _ operation: nonisolated(nonsending) () async throws -> R
    ) async rethrows -> R {
        begin(route)
        defer { end(route) }
        return try await operation()
    }

    /// `stock_order` and `row_invariant` counts.
    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return [
            SmallMRoute.stockOrder.rawValue: counts[.stockOrder] ?? 0,
            SmallMRoute.rowInvariant.rawValue: counts[.rowInvariant] ?? 0,
        ]
    }
}
