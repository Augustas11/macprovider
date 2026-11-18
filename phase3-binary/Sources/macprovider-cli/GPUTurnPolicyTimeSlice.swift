import Foundation

// SPEC-001-R018 (#2338): round-robin time slices. Among the participants that
// want the GPU, wall time is cut into slices of `quantum_ms`; slice k belongs
// to the (k mod N)-th contender in id order. The arbiter state does not expose
// when a participant's current run of consecutive turns began (only the last
// turn's start), so ownership is derived from `now` instead of a stored run
// start. A caller proceeds in its own slice or whenever nobody else wants a
// turn; otherwise it sleeps until the next slice boundary (or a state change)
// instead of re-polling. Turns are exclusive (the arbiter's rule): a turn that
// began in its owner's slice finishes even past the boundary, and only a turn
// held past `stall_ms` lets a waiter in beside it.

struct TimeSliceGPUTurnPolicy: GPUTurnPolicy {
    static let name = "timeslice"
    static let defaultQuantumMilliseconds: UInt64 = 100
    static let defaultStallMilliseconds = GPUTurnPolicyDefaults.stallMilliseconds

    static let factory = GPUTurnPolicyFactory(
        name: name,
        summary: "Round-robin wall-time slices among participants that want turns, exclusive turns, wake at the slice boundary (quantum_ms=100, stall_ms=10000, drain=always|handoff|never: when a turn drains its queued GPU work, default always)."
    ) { parameters in
        var rest = parameters
        let quantum = try GPUTurnPolicyParameters.milliseconds(&rest, "quantum_ms", policy: name, default: defaultQuantumMilliseconds)
        let stall = try GPUTurnPolicyParameters.milliseconds(&rest, "stall_ms", policy: name, default: defaultStallMilliseconds)
        let drain = try GPUTurnPolicyParameters.enumerated(&rest, "drain", policy: name, default: GPUTurnDrain.always)
        guard rest.isEmpty else {
            throw GPUTurnPolicyError.unknownParameters(policy: name, names: rest.keys.sorted())
        }
        return TimeSliceGPUTurnPolicy(quantumMilliseconds: quantum, stallMilliseconds: stall, drain: drain)
    }

    let quantumMilliseconds: UInt64
    let stallMilliseconds: UInt64
    let drain: GPUTurnDrain

    init(
        quantumMilliseconds: UInt64 = defaultQuantumMilliseconds, stallMilliseconds: UInt64 = defaultStallMilliseconds,
        drain: GPUTurnDrain = .always
    ) {
        self.quantumMilliseconds = quantumMilliseconds
        self.stallMilliseconds = stallMilliseconds
        self.drain = drain
    }

    var name: String { Self.name }
    var parameters: [String: String] {
        var values = ["quantum_ms": String(quantumMilliseconds), "stall_ms": String(stallMilliseconds)]
        // The default drain is left out, so existing results read the same.
        if drain != .always { values["drain"] = drain.rawValue }
        return values
    }
    var stallNanoseconds: UInt64 { stallMilliseconds &* 1_000_000 }

    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision {
        var contenders = state.others(than: request.participantID).filter { $0.wantsTurn || $0.inTurn }.map(\.id)
        if contenders.isEmpty { return .proceed }
        contenders.append(request.participantID)
        contenders.sort()
        let quantum = max(quantumMilliseconds &* 1_000_000, 1)
        let slice = state.now / quantum
        if contenders[Int(slice % UInt64(contenders.count))] == request.participantID { return .proceed }
        // Not this caller's slice: sleep to the next boundary; a contender
        // going idle or a turn ending wakes it sooner.
        return .wait(maxNanoseconds: quantum - state.now % quantum)
    }
}
