import Foundation

// SPEC-001-R018 (#2338): step-ratio alternation. After a participant has taken
// `burst` consecutive turns while another participant wants one, it waits until
// that participant has taken a turn; among several, the least recently served goes first. Prefill chunks and decode steps count alike.
//
// The policy keeps no state. "Consecutive" is derived from
// `lastTurnParticipantID` and the participant's own turn counter: a participant
// that had the last turn and whose counter is a multiple of `burst` has just
// finished a burst. A participant that joins out of phase takes one short
// burst and is aligned from then on.

struct AlternateGPUTurnPolicy: GPUTurnPolicy {
    static let name = "alternate"
    static let defaultBurst = 1
    static let defaultMaxWaitMilliseconds = 250
    /// Re-check interval while waiting, so a peer that never asks cannot hang us.
    static let pollNanoseconds: UInt64 = 2_000_000

    static let factory = GPUTurnPolicyFactory(
        name: name,
        summary: "Alternate turns between participants: at most `burst` (default 1) consecutive turns while another waits; `max_wait_ms` (default 250) bounds every wait."
    ) { parameters in
        var rest = parameters
        func integer(_ key: String, default fallback: Int) throws -> Int {
            guard let raw = rest.removeValue(forKey: key) else { return fallback }
            guard let value = Int(raw), value >= 1 else {
                throw GPUTurnPolicyError.invalidParameter(policy: name, name: key, value: raw)
            }
            return value
        }
        let burst = try integer("burst", default: defaultBurst)
        let maxWait = try integer("max_wait_ms", default: defaultMaxWaitMilliseconds)
        guard rest.isEmpty else {
            throw GPUTurnPolicyError.unknownParameters(policy: name, names: rest.keys.sorted())
        }
        return AlternateGPUTurnPolicy(burst: burst, maxWaitMilliseconds: maxWait)
    }

    let burst: Int
    let maxWaitMilliseconds: Int

    var name: String { Self.name }
    var parameters: [String: String] {
        ["burst": String(burst), "max_wait_ms": String(maxWaitMilliseconds)]
    }

    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision {
        let others = state.others(than: request.participantID)
        // Nobody else wants the GPU: never wait.
        guard others.contains(where: { $0.wantsTurn || $0.inTurn }) else { return .proceed }

        let maxWait = UInt64(maxWaitMilliseconds) * 1_000_000
        let waited = state.now &- request.waitingSince
        guard waited < maxWait else { return .proceed }
        let pause = GPUTurnDecision.wait(maxNanoseconds: min(Self.pollNanoseconds, maxWait - waited))

        // Never start beside another participant's turn.
        if others.contains(where: \.inTurn) { return pause }

        let lastWasMe = state.lastTurnParticipantID == request.participantID
        let me = state.participant(request.participantID)
        if lastWasMe {
            // Mid-burst: keep going. Burst complete: let the others in.
            return (me?.counters.turns ?? 0) % burst == 0 ? pause : .proceed
        }

        // The last runner is mid-burst and will ask again at once: let it.
        if let last = state.lastTurnParticipantID, let runner = state.participant(last),
           runner.wantsTurn, runner.counters.turns % burst != 0 {
            return pause
        }

        // Several wanting participants: the least recently served goes first,
        // whether or not it has reached `beginTurn` yet.
        let mine = me?.lastTurnBeganAt ?? 0
        let earlierWaiter = others.contains { other in
            guard other.wantsTurn else { return false }
            let theirs = other.lastTurnBeganAt ?? 0
            return theirs < mine || (theirs == mine && other.id < request.participantID)
        }
        return earlierWaiter ? pause : .proceed
    }
}
