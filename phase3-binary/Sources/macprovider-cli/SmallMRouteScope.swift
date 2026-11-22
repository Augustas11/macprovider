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
    static func build<R>(_ body: () throws -> R) rethrows -> R {
        guard let route = current?.mlxRoute else { return try body() }
        return try withSmallMRoute(route, body)
    }

    /// The route of rows built in one forward. Nil when they hold two routes,
    /// which a forward never may.
    static func uniformRoute(_ routes: some Sequence<SmallMRoute>) -> SmallMRoute? {
        var iterator = routes.makeIterator()
        guard let first = iterator.next() else { return nil }
        while let next = iterator.next() {
            if next != first { return nil }
        }
        return first
    }

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
/// `continuous_batching.small_m_route_requests` in a `mixed` process.
final class SmallMRouteRequestCounter: @unchecked Sendable {
    static let shared = SmallMRouteRequestCounter()

    private let lock = NSLock()
    private var counts: [SmallMRoute: Int] = [:]

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
