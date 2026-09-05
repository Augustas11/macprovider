import Foundation

/// SPEC-025 §5.2 (capability `model_liveness_token_v1`) — model-thread liveness.
///
/// A bare `/v1/health` 200 does not prove the model thread is alive: the HTTP
/// listener can answer while the inference thread is dead. This tracker exposes a
/// monotone token that advances ONLY on model/inference forward progress, plus
/// the monotonic age since it last advanced, so an out-of-process observer can
/// distinguish a healthy provider from a listener-alive / model-dead wedge.
///
/// Observability-only in this version: the value is surfaced on `/v1/status` and
/// carries no buyer-serving authority and does not gate admission. Wiring it into
/// a watchdog restart decision is a deferred RFC-001 follow-up.
///
/// The token is process-scoped (starts at 0 each process/service instance), so it
/// resets on restart and must not be compared across `service_instance.instance_id`.
/// Reads never block on the model thread — the model loop only briefly bumps a
/// lock-guarded counter, and `snapshot()` reads the last-published values.
final class ModelLivenessTracker: @unchecked Sendable {
    static let shared = ModelLivenessTracker()

    struct Snapshot: Sendable {
        let token: UInt64
        let tokenAgeMs: UInt64?
        let activeInference: Bool
        let activeInferenceAgeMs: UInt64?
        let lastAdvancedAt: Date?
    }

    private let lock = NSLock()
    private var token: UInt64 = 0
    private var lastAdvanceMonoNs: UInt64?
    private var lastAdvanceWall: Date?
    private var activeCount = 0
    private var activeSinceMonoNs: UInt64?

    // Injectable monotonic clock for tests; defaults to the process uptime clock,
    // which is immune to wall-clock jumps.
    private let monotonicNs: @Sendable () -> UInt64
    private let wallClock: @Sendable () -> Date

    init(
        monotonicNs: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.monotonicNs = monotonicNs
        self.wallClock = wallClock
    }

    /// Called by the inference loop whenever the model produces forward progress
    /// (one or more tokens). Advances the token and restarts the
    /// active-without-progress clock.
    func recordProgress() {
        lock.lock(); defer { lock.unlock() }
        // Sample the clock INSIDE the lock so published timestamps are serialized
        // with readers and never move backward relative to a later snapshot.
        let now = monotonicNs()
        // Saturating increment: never wrap UInt64.max -> 0 (monotone contract).
        if token != .max { token += 1 }
        lastAdvanceMonoNs = now
        lastAdvanceWall = wallClock()
        if activeCount > 0 { activeSinceMonoNs = now }
    }

    /// Bracket around a unit of buyer-serving model work. `beginInference` marks
    /// active inference (so a stalled token is meaningful); `endInference` clears
    /// it when no work remains.
    func beginInference() {
        lock.lock(); defer { lock.unlock() }
        if activeCount == 0 { activeSinceMonoNs = monotonicNs() }
        activeCount += 1
    }

    func endInference() {
        lock.lock(); defer { lock.unlock() }
        if activeCount > 0 { activeCount -= 1 }
        if activeCount == 0 { activeSinceMonoNs = nil }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        // Sample `now` under the lock, after any concurrent writer has published,
        // so the monotonic clock guarantees now >= every stored timestamp.
        let now = monotonicNs()
        let tokenAge = lastAdvanceMonoNs.map { Self.ageMs(now: now, then: $0) }
        let active = activeCount > 0
        let activeAge = active ? activeSinceMonoNs.map { Self.ageMs(now: now, then: $0) } : nil
        return Snapshot(
            token: token,
            tokenAgeMs: tokenAge,
            activeInference: active,
            activeInferenceAgeMs: activeAge,
            lastAdvancedAt: lastAdvanceWall
        )
    }

    /// Clamped elapsed-ms: never underflow if `now < then` (defense in depth
    /// against clock quirks / test seams that move the sampled clock backward).
    private static func ageMs(now: UInt64, then: UInt64) -> UInt64 {
        (now >= then ? now - then : 0) / 1_000_000
    }
}
