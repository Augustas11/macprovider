import ArgumentParser
import Foundation
import MacProviderCore

/// SPEC-048-R003 / SPEC-038 FR-CB9 (#2335): the MLX core route for small-row
/// affine quantized matmuls in this process.
///
/// `rowInvariant` is the core default: rows 1-16 take kernels with one
/// reduction order, so a row computes the same bits alone and inside a
/// continuous batch. `serialOnly` sets `MLX_METAL_SMALL_M_ROW_INVARIANT=0`,
/// the MLX fork's pre-window per-row `qmv` below the `qmm` limit, which is faster for one row
/// but not row-invariant. Only a process that can never batch decode rows may
/// run it, and such a process refuses every batching entry point.
enum SmallMRoute: String, Sendable, Equatable {
    case rowInvariant = "row_invariant"
    case serialOnly = "serial_only"

    /// Read once per process by the MLX core at its first small-row dispatch;
    /// anything but "0" keeps the row-invariant window.
    static let environmentKey = "MLX_METAL_SMALL_M_ROW_INVARIANT"

    struct Decision: Sendable, Equatable {
        let route: SmallMRoute
        let reason: String
    }

    /// The route a `serve` process runs, from configuration that cannot change
    /// for the life of the process. Serial-only needs continuous batching set
    /// `off` by YAML, environment or CLI (the emergency override: neither the
    /// signed policy nor a self-check can lift it, and a warm swap keeps it),
    /// `native_mtp_mode: off` (native MTP rounds run in the batch scheduler
    /// whatever the CB mode), no draft model, no shard-group role and not an
    /// autotune child. Every other state, including CB still awaiting its
    /// self-check, keeps the row-invariant route.
    static func decide(
        continuousBatching: ContinuousBatchingMode,
        continuousBatchingExplicitlyConfigured: Bool,
        nativeMTPMode: NativeMTPMode,
        draftConfigured: Bool,
        shardGroupRole: Bool,
        autotuneCandidate: Bool
    ) -> Decision {
        guard continuousBatchingExplicitlyConfigured, continuousBatching == .off else {
            return Decision(route: .rowInvariant, reason: "continuous_batching_not_configured_off")
        }
        if nativeMTPMode != .off {
            return Decision(route: .rowInvariant, reason: "native_mtp_\(nativeMTPMode.rawValue)")
        }
        if draftConfigured {
            return Decision(route: .rowInvariant, reason: "draft_model")
        }
        if shardGroupRole {
            return Decision(route: .rowInvariant, reason: "shard_group")
        }
        if autotuneCandidate {
            return Decision(route: .rowInvariant, reason: "autotune_candidate")
        }
        return Decision(route: .serialOnly, reason: "continuous_batching_off_by_configuration")
    }

    /// The route the MLX core takes for a given environment value.
    static func route(environmentValue: String?) -> SmallMRoute {
        environmentValue == "0" ? .serialOnly : .rowInvariant
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var applied: SmallMRoute?

    /// The route this process runs: the one `apply` set, else the one the
    /// inherited environment gives the MLX core.
    static var processRoute: SmallMRoute {
        lock.lock()
        defer { lock.unlock() }
        return applied ?? route(environmentValue: ProcessInfo.processInfo.environment[environmentKey])
    }

    /// Sets the environment for this process before MLX's first small-row
    /// dispatch. Row-invariant removes any inherited value, so a stray "0"
    /// never reaches a process that can batch. The first call wins; a later
    /// call returns the route already applied.
    @discardableResult
    static func apply(_ route: SmallMRoute) -> SmallMRoute {
        lock.lock()
        defer { lock.unlock() }
        if let applied { return applied }
        switch route {
        case .serialOnly: setenv(environmentKey, "0", 1)
        case .rowInvariant: unsetenv(environmentKey)
        }
        applied = route
        return route
    }

    /// The startup event serve and decode-bench print.
    static func event(_ decision: Decision) -> String {
        "event=small_m_route mode=\(decision.route.rawValue) reason=\(decision.reason)\n"
    }

    /// Nil when a process on `route` may batch rows, else why `entry` refuses.
    static func batchingRefusal(route: SmallMRoute, entry: String) -> String? {
        guard route == .serialOnly else { return nil }
        return "small_m_route_serial_only: \(entry) batches decode rows, but this process runs the serial-only small-row route (\(environmentKey)=0), which is not row-invariant"
    }

    /// For lab commands that batch rows: exits 2 on a serial-only process,
    /// else pins the row-invariant route before MLX starts.
    static func requireRowInvariant(entry: String) throws {
        if let refusal = batchingRefusal(route: processRoute, entry: entry) {
            FileHandle.standardError.write(Data("\(refusal)\n".utf8))
            throw ExitCode(2)
        }
        apply(.rowInvariant)
    }

    /// SPEC-037 FR-KVP4 item 10: the decode-path class in a disk-cache
    /// envelope. KV written on one route is a clean miss on the other.
    var kvDecodePath: String {
        switch self {
        case .rowInvariant: return KVBuildIdentity.decodePathOrdinary
        case .serialOnly: return KVBuildIdentity.decodePathOrdinary + "+serial_small_m"
        }
    }
}
