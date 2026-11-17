import Foundation

// SPEC-001-R018 (#2338): step-ratio alternation. After a participant has taken
// `burst` consecutive turns while another participant wants one, it waits until
// that participant has taken a turn; among several, the least recently served
// goes first. Prefill chunks and decode steps count alike.
//
// The policy keeps no state. "Consecutive" is derived from
// `lastTurnParticipantID` and the participant's own turn counter: a participant
// that had the last turn and whose counter is a multiple of `burst` has just
// finished a burst. A participant that joins out of phase takes one short
// burst and is aligned from then on.
//
// A peer counts as about to take a turn only while it waits in `beginTurn`, or
// while it is inside a work interval and less than `graceNanoseconds` have
// passed since its last turn ended (or since this caller began waiting, if
// later); a waiter sleeps until that grace runs out or a state change, never
// re-polls. A peer with work open that never asks costs at most one grace.
// Turns are exclusive (the arbiter's rule); only a turn held past `stall_ms`
// lets a waiter in beside it.

struct AlternateGPUTurnPolicy: GPUTurnPolicy {
    static let name = "alternate"
    static let defaultBurst = 1
    static let defaultStallMilliseconds = GPUTurnPolicyDefaults.stallMilliseconds
    /// How long a peer between two turns of its run is expected back.
    static let graceNanoseconds: UInt64 = 30_000_000

    static let factory = GPUTurnPolicyFactory(
        name: name,
        summary: "Alternate turns between participants: at most `burst` (default 1) consecutive turns while another is about to take one; exclusive turns; `stall_ms` (default 10000) is the stalled-peer bound; `drain` (always|handoff|never, default always) is when a turn drains its queued GPU work."
    ) { parameters in
        var rest = parameters
        let burst = try GPUTurnPolicyParameters.integer(&rest, "burst", policy: name, default: defaultBurst)
        let stall = try GPUTurnPolicyParameters.milliseconds(&rest, "stall_ms", policy: name, default: defaultStallMilliseconds)
        let drain = try GPUTurnPolicyParameters.enumerated(&rest, "drain", policy: name, default: GPUTurnDrain.always)
        guard rest.isEmpty else {
            throw GPUTurnPolicyError.unknownParameters(policy: name, names: rest.keys.sorted())
        }
        return AlternateGPUTurnPolicy(burst: burst, stallMilliseconds: stall, drain: drain)
    }

    let burst: Int
    let stallMilliseconds: UInt64
    let drain: GPUTurnDrain

    init(burst: Int = defaultBurst, stallMilliseconds: UInt64 = defaultStallMilliseconds, drain: GPUTurnDrain = .always) {
        self.burst = burst
        self.stallMilliseconds = stallMilliseconds
        self.drain = drain
    }

    var name: String { Self.name }
    var parameters: [String: String] {
        var values = ["burst": String(burst), "stall_ms": String(stallMilliseconds)]
        // The default drain is left out, so existing results read the same.
        if drain != .always { values["drain"] = drain.rawValue }
        return values
    }
    var stallNanoseconds: UInt64 { stallMilliseconds &* 1_000_000 }

    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision {
        let others = state.others(than: request.participantID)
        // Nobody else wants the GPU: never wait.
        guard others.contains(where: { $0.wantsTurn || $0.inTurn }) else { return .proceed }

        // Never start beside another participant's turn; its end wakes us.
        if others.contains(where: \.inTurn) { return .wait(maxNanoseconds: nil) }

        let lastWasMe = state.lastTurnParticipantID == request.participantID
        let me = state.participant(request.participantID)
        if lastWasMe {
            // Mid-burst: keep going. Burst complete: let the others in, if one
            // is about to take a turn.
            guard (me?.counters.turns ?? 0) % burst == 0 else { return .proceed }
            return pause(for: others, state: state, since: request.waitingSince) ?? .proceed
        }

        // The last runner is mid-burst and about to ask again: let it.
        if let last = state.lastTurnParticipantID, let runner = state.participant(last),
           runner.counters.turns % burst != 0, let wait = pause(for: [runner], state: state, since: request.waitingSince) {
            return wait
        }

        // Several wanting participants: the least recently served goes first.
        let mine = me?.lastTurnBeganAt ?? 0
        let earlier = others.filter { other in
            let theirs = other.lastTurnBeganAt ?? 0
            return theirs < mine || (theirs == mine && other.id < request.participantID)
        }
        return pause(for: earlier, state: state, since: request.waitingSince) ?? .proceed
    }

    /// A wait for the first of `peers` that is about to take a turn: until a
    /// state change if one is already waiting, else until its grace ends.
    /// Nil when none is.
    private func pause(for peers: [GPUTurnParticipantState], state: GPUTurnArbiterState, since: UInt64) -> GPUTurnDecision? {
        var soonest: UInt64?
        for peer in peers {
            if peer.isWaiting { return .wait(maxNanoseconds: nil) }
            let reference = max(peer.lastTurnEndedAt ?? 0, since)
            guard peer.pendingWork > 0, state.now >= reference else { continue }
            let age = state.now - reference
            if age < Self.graceNanoseconds {
                soonest = min(soonest ?? .max, Self.graceNanoseconds - age)
            }
        }
        return soonest.map { .wait(maxNanoseconds: $0) }
    }
}
