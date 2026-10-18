import Foundation

/// SPEC-048-R016 (v0.1.48): re-offer policy for a native-MTP tuple the
/// coordinator rejected with `bank_mismatch`.
///
/// `bank_mismatch` says the coordinator canary does not hold the challenge
/// bank this provider qualified against, not that the tuple failed. The
/// provider fences the tuple (it serves no native MTP without a canary that
/// can check it) but keeps its qualified load, and offers it again when the
/// mismatch can have cleared:
///
/// 1. a new coordinator session (a reconnect, including a coordinator
///    restart that loaded a new bank), at most once per session; and
/// 2. the coordinator's served self-test bank changing to the bank this
///    provider offers, at most once per (session, observed bank).
///
/// Nothing else re-offers, so a coordinator that keeps rejecting sees one
/// offer per session or per observed bank change, never a loop. The offer
/// carries the bank the provider already qualified, so the local self-check
/// does not run again; a new bank of the provider's own arrives only with a
/// new release's admission set, which loads (and self-checks) a new tuple.
struct NativeMTPTupleReofferGate: Sendable, Equatable {
    struct Parked: Sendable, Equatable {
        let offer: NativeMTPPublishedTupleOffer
        var session: UInt64
        var coordinatorBankAtRejection: String?
        var restored = false
        var triggersUsed: Set<String> = []
    }

    private(set) var parked: Parked?

    /// True while a rejected tuple waits for a re-offer trigger.
    var awaitingReoffer: Bool {
        guard let parked else { return false }
        return !parked.restored
    }

    /// Records a `bank_mismatch` rejection of `offer` in `session`. A repeat
    /// rejection of the same offer keeps the triggers already spent.
    mutating func park(
        _ offer: NativeMTPPublishedTupleOffer,
        session: UInt64,
        observedCoordinatorBankSHA256: String?
    ) {
        var next = Parked(offer: offer, session: session, coordinatorBankAtRejection: observedCoordinatorBankSHA256)
        if let parked, parked.offer == offer {
            next.triggersUsed = parked.triggersUsed
        }
        // The rejecting session is spent: only a later session re-offers.
        next.triggersUsed.insert(Self.sessionTrigger(session))
        parked = next
    }

    /// A different tuple from the runtime (a new model load) supersedes the
    /// parked one.
    mutating func clear() {
        parked = nil
    }

    mutating func markRestored() {
        parked?.restored = true
    }

    /// The parked offer when a trigger is due, consuming that trigger.
    mutating func reofferDue(session: UInt64, observedCoordinatorBankSHA256: String?) -> NativeMTPPublishedTupleOffer? {
        guard var current = parked, !current.restored else { return nil }
        let trigger: String
        if session != current.session {
            trigger = Self.sessionTrigger(session)
        } else if let observed = observedCoordinatorBankSHA256,
                  observed == current.offer.challengeBankSHA256,
                  observed != current.coordinatorBankAtRejection {
            trigger = "bank:\(session):\(observed)"
        } else {
            return nil
        }
        guard !current.triggersUsed.contains(trigger) else { return nil }
        current.triggersUsed.insert(trigger)
        parked = current
        return current.offer
    }

    private static func sessionTrigger(_ session: UInt64) -> String {
        "session:\(session)"
    }
}

/// What restoring a parked tuple for a re-offer did (SPEC-048-R016).
enum NativeMTPTupleRestoreOutcome: Sendable, Equatable {
    /// Restored and published again; offer it.
    case restored
    /// Nothing matching is parked: a load or swap replaced it, or it was
    /// discarded. The re-offer is dropped.
    case gone
    /// The latest verified revocation feed names it: discarded.
    case revoked
    /// No verified revocation state could be read: it stays parked and
    /// fenced (fail closed), and a later trigger may try again.
    case revocationUnavailable
}

/// Poll schedule for the coordinator's served self-test bank while a tuple
/// waits for a re-offer: 60 s doubling to a 15-minute ceiling.
enum NativeMTPServedBankPoll {
    static let initialDelaySeconds: UInt64 = 60
    static let maximumDelaySeconds: UInt64 = 900

    static func delaySeconds(attempt: Int) -> UInt64 {
        guard attempt > 0 else { return initialDelaySeconds }
        let shift = min(attempt, 8)
        return min(initialDelaySeconds << UInt64(shift), maximumDelaySeconds)
    }
}

/// The runtime's published native-MTP tuple and spec-decode generation, kept
/// under a lock so the coordinator client can confirm, synchronously and
/// right before a send, that the tuple it is about to offer is still the one
/// the runtime publishes (no load or swap in between).
final class NativeMTPPublishedTupleOfferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var offer: NativeMTPPublishedTupleOffer?
    private var generation = 0

    func set(_ offer: NativeMTPPublishedTupleOffer?, generation: Int) {
        lock.lock()
        self.offer = offer
        self.generation = generation
        lock.unlock()
    }

    /// The published tuple and its generation.
    func current() -> (offer: NativeMTPPublishedTupleOffer?, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (offer, generation)
    }
}
