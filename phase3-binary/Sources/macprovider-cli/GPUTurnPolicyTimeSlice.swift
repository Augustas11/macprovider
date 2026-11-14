import Foundation

// SPEC-001-R018 (#2338): round-robin time slices. Among the participants that
// want the GPU, wall time is cut into slices of `quantum_ms`; slice k belongs
// to the (k mod N)-th contender in id order. The arbiter state does not expose
// when a participant's current run of consecutive turns began (only the last
// turn's start), so ownership is derived from `now` instead of a stored run
// start. A caller proceeds in its own slice, whenever nobody else wants a turn,
// and after `max_wait_ms` regardless, so a stalled peer cannot hang it.

struct TimeSliceGPUTurnPolicy: GPUTurnPolicy {
    static let name = "timeslice"
    static let defaultQuantumMilliseconds: UInt64 = 100
    static let defaultMaxWaitMilliseconds: UInt64 = 250
    /// Re-ask interval while waiting; keeps a stalled peer from hanging the waiter.
    static let pollNanoseconds: UInt64 = 2_000_000

    static let factory = GPUTurnPolicyFactory(
        name: name,
        summary: "Round-robin wall-time slices among participants that want turns (quantum_ms=100, max_wait_ms=250)."
    ) { parameters in
        var rest = parameters
        func number(_ key: String, default fallback: UInt64) throws -> UInt64 {
            guard let raw = rest.removeValue(forKey: key) else { return fallback }
            guard let value = UInt64(raw), value > 0, value <= 60_000 else {
                throw GPUTurnPolicyError.invalidParameter(policy: name, name: key, value: raw)
            }
            return value
        }
        let quantum = try number("quantum_ms", default: defaultQuantumMilliseconds)
        let maxWait = try number("max_wait_ms", default: defaultMaxWaitMilliseconds)
        guard rest.isEmpty else {
            throw GPUTurnPolicyError.unknownParameters(policy: name, names: rest.keys.sorted())
        }
        return TimeSliceGPUTurnPolicy(quantumMilliseconds: quantum, maxWaitMilliseconds: maxWait)
    }

    let quantumMilliseconds: UInt64
    let maxWaitMilliseconds: UInt64

    var name: String { Self.name }
    var parameters: [String: String] {
        ["quantum_ms": String(quantumMilliseconds), "max_wait_ms": String(maxWaitMilliseconds)]
    }

    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision {
        var contenders = state.others(than: request.participantID).filter { $0.wantsTurn || $0.inTurn }.map(\.id)
        if contenders.isEmpty { return .proceed }
        if state.now &- request.waitingSince >= maxWaitMilliseconds &* 1_000_000 { return .proceed }
        contenders.append(request.participantID)
        contenders.sort()
        let slice = state.now / (quantumMilliseconds &* 1_000_000)
        if contenders[Int(slice % UInt64(contenders.count))] == request.participantID { return .proceed }
        return .wait(maxNanoseconds: Self.pollNanoseconds)
    }
}
