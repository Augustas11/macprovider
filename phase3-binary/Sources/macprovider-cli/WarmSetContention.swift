import Foundation

/// SPEC-001-R018 advertised capacity: GPU time each warm member held and
/// waited for over the last measured window, read from the process's GPU
/// turn counters.
struct WarmSetContentionWindow: Sendable, Equatable {
    let wallNanoseconds: UInt64
    let busyNanoseconds: [Int: UInt64]
    let waitNanoseconds: [Int: UInt64]

    /// The share of its solo decode rate member `memberID` achieves while
    /// `siblings` load the GPU, or nil when no sibling was busy (the solo
    /// rate stands). A member that asked for the GPU gets the share of its
    /// asking time it held it; an idle member gets the GPU time its siblings
    /// left, never less than an even split with the busy ones, since no
    /// member with admitted rows is starved.
    func share(of memberID: Int, siblings: Set<Int>) -> Double? {
        guard wallNanoseconds > 0 else { return nil }
        let busySiblings = siblings.subtracting([memberID]).filter { (busyNanoseconds[$0] ?? 0) > 0 }
        guard !busySiblings.isEmpty else { return nil }
        let busy = Double(busyNanoseconds[memberID] ?? 0)
        let wait = Double(waitNanoseconds[memberID] ?? 0)
        if busy + wait > 0 {
            return min(1, busy / (busy + wait))
        }
        let siblingBusy = busySiblings.reduce(0.0) { $0 + Double(busyNanoseconds[$1] ?? 0) }
        let left = max(0, 1 - siblingBusy / Double(wallNanoseconds))
        return min(1, max(left, 1 / Double(busySiblings.count + 1)))
    }

    /// `solo` scaled for contention; unchanged when no sibling was busy.
    func estimate(solo: Double, memberID: Int?, members: Set<Int>) -> Double {
        guard let memberID, let share = share(of: memberID, siblings: members) else { return solo }
        return (solo * share * 10).rounded() / 10
    }
}

/// Keeps the last completed window of at least `minimumWindowNanoseconds`,
/// so every report reads a measured share, not one instant.
final class WarmSetContentionMeter: @unchecked Sendable {
    static let shared = WarmSetContentionMeter(
        counters: { GPUTurnArbiter.shared.snapshot().counters },
        clock: { DispatchTime.now().uptimeNanoseconds })
    static let minimumWindowNanoseconds: UInt64 = 5_000_000_000

    private let lock = NSLock()
    private let counters: @Sendable () -> [Int: GPUTurnParticipantCounters]
    private let clock: @Sendable () -> UInt64
    private var base: (at: UInt64, counters: [Int: GPUTurnParticipantCounters])?
    private var last: WarmSetContentionWindow?

    init(
        counters: @escaping @Sendable () -> [Int: GPUTurnParticipantCounters],
        clock: @escaping @Sendable () -> UInt64
    ) {
        self.counters = counters
        self.clock = clock
    }

    /// The last completed window; nil before the first one completes.
    func window() -> WarmSetContentionWindow? {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        let current = counters()
        guard let base else {
            self.base = (now, current)
            return nil
        }
        if now &- base.at >= Self.minimumWindowNanoseconds {
            var busy: [Int: UInt64] = [:]
            var wait: [Int: UInt64] = [:]
            for (id, c) in current {
                let before = base.counters[id] ?? GPUTurnParticipantCounters()
                busy[id] = c.busyNanoseconds &- before.busyNanoseconds
                wait[id] = c.waitNanoseconds &- before.waitNanoseconds
            }
            last = WarmSetContentionWindow(wallNanoseconds: now &- base.at, busyNanoseconds: busy, waitNanoseconds: wait)
            self.base = (now, current)
        }
        return last
    }

    /// A member's solo decode rate from a probe that ran while it held
    /// `busy` and waited `wait` nanoseconds of GPU time: the probe's rate
    /// divided by the share it held.
    static func soloRate(measured: Double, busyNanoseconds busy: UInt64, waitNanoseconds wait: UInt64) -> Double {
        guard measured > 0, busy > 0, wait > 0 else { return measured }
        return measured * Double(busy + wait) / Double(busy)
    }
}
