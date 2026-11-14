import Foundation

// SPEC-001-R018 (#2338): equal shares of GPU busy time, with prefill repaid in
// decode time. A participant that waited is "owed" a turn once the others have
// had, since it began waiting, the GPU time its own last turn took (times the
// number of other contenders), rounded to the nearest whole step of whoever is
// running. While another participant decodes, a mid-prefill participant is
// owed only after the others had `(1 - prefill_share) / prefill_share` of its
// last chunk, so each chunk is repaid with their decode time before the next.
// The most overdue owed waiter goes next; with nobody owed, the participant in
// the middle of its run keeps the GPU. Turns are exclusive: nobody starts while
// another participant holds a turn, so busy time is GPU time.
//
// The arbiter state has no busy counter for a sliding window and no start time
// of a participant's work interval or prefill run, so a true windowed deficit
// cannot be derived without stored state. Each decision instead compares time
// since the waiter began waiting with its last turn, which carries no history,
// plus a carry of at most `tolerance_ms` (and at most half a step) from the
// cumulative wait counters. Waits accrue only while another participant
// contends, so an idle participant banks nothing, and the clamp bounds what an
// old contention can still tilt. A last turn older than `window_ms` counts as
// no turn, so a participant back from idle is not held back for old usage.
// Every wait is timed and a waiter proceeds after `max_wait_ms` in total.

struct FairShareGPUTurnPolicy: GPUTurnPolicy {
    static let name = "fairshare"
    static let defaultWindowMilliseconds: UInt64 = 500
    static let defaultToleranceMilliseconds: UInt64 = 30
    static let defaultPrefillShare = 0.5
    static let defaultMaxWaitMilliseconds: UInt64 = 250

    static let factory = GPUTurnPolicyFactory(
        name: name,
        summary: "Equal GPU busy time per contender, prefill chunks repaid with decode time (window_ms=500, tolerance_ms=30, prefill_share=0.5, max_wait_ms=250)."
    ) { parameters in
        var rest = parameters
        func milliseconds(_ key: String, default fallback: UInt64) throws -> UInt64 {
            guard let raw = rest.removeValue(forKey: key) else { return fallback }
            guard let value = UInt64(raw), value > 0, value <= 60_000 else {
                throw GPUTurnPolicyError.invalidParameter(policy: name, name: key, value: raw)
            }
            return value
        }
        let window = try milliseconds("window_ms", default: defaultWindowMilliseconds)
        let tolerance = try milliseconds("tolerance_ms", default: defaultToleranceMilliseconds)
        let maxWait = try milliseconds("max_wait_ms", default: defaultMaxWaitMilliseconds)
        var share = defaultPrefillShare
        if let raw = rest.removeValue(forKey: "prefill_share") {
            guard let value = Double(raw), value.isFinite, value > 0, value <= 1 else {
                throw GPUTurnPolicyError.invalidParameter(policy: name, name: "prefill_share", value: raw)
            }
            share = value
        }
        guard rest.isEmpty else {
            throw GPUTurnPolicyError.unknownParameters(policy: name, names: rest.keys.sorted())
        }
        return FairShareGPUTurnPolicy(
            windowMilliseconds: window, toleranceMilliseconds: tolerance,
            prefillShare: share, maxWaitMilliseconds: maxWait)
    }

    let windowMilliseconds: UInt64
    let toleranceMilliseconds: UInt64
    let prefillShare: Double
    let maxWaitMilliseconds: UInt64

    init(
        windowMilliseconds: UInt64 = defaultWindowMilliseconds,
        toleranceMilliseconds: UInt64 = defaultToleranceMilliseconds,
        prefillShare: Double = defaultPrefillShare,
        maxWaitMilliseconds: UInt64 = defaultMaxWaitMilliseconds
    ) {
        self.windowMilliseconds = windowMilliseconds
        self.toleranceMilliseconds = toleranceMilliseconds
        self.prefillShare = prefillShare
        self.maxWaitMilliseconds = maxWaitMilliseconds
    }

    var name: String { Self.name }
    var parameters: [String: String] {
        [
            "window_ms": String(windowMilliseconds),
            "tolerance_ms": String(toleranceMilliseconds),
            "prefill_share": String(prefillShare),
            "max_wait_ms": String(maxWaitMilliseconds),
        ]
    }

    private var window: Double { Double(windowMilliseconds) * 1e6 }
    private var tolerance: Double { Double(toleranceMilliseconds) * 1e6 }

    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision {
        let contenders = state.others(than: request.participantID).filter { $0.wantsTurn || $0.inTurn }
        if contenders.isEmpty { return .proceed }
        let waited = state.now &- request.waitingSince
        let maxWait = maxWaitMilliseconds &* 1_000_000
        if waited >= maxWait { return .proceed }
        // Re-ask at least every tolerance: owed-ness grows with time alone.
        let poll = min(maxWait - waited, toleranceMilliseconds &* 1_000_000)
        if contenders.contains(where: \.inTurn) { return .wait(maxNanoseconds: poll) }

        var me = state.participant(request.participantID)
            ?? GPUTurnParticipantState(id: request.participantID, modelID: "")
        if me.waitingSince == nil {
            me.waitingSince = request.waitingSince
            me.waitingKind = request.kind
        }
        let mine = claim(me, state: state)

        for other in contenders where other.isWaiting {
            let theirs = claim(other, state: state)
            guard theirs.owed else { continue }
            if !mine.owed || outranks(other, theirs.overdue, me, mine.overdue) {
                return .wait(maxNanoseconds: poll)
            }
        }
        guard !mine.owed else { return .proceed }

        // Nobody is owed: the participant in the middle of its run keeps the GPU.
        for other in contenders {
            if !other.isWaiting {
                // Between two turns of its run: give it up to one tolerance to come back.
                if let ended = other.lastTurnEndedAt, state.now >= ended {
                    let age = state.now - ended
                    if Double(age) < tolerance {
                        return .wait(maxNanoseconds: min(poll, toleranceMilliseconds &* 1_000_000 - age))
                    }
                }
                continue
            }
            let recencyOther = other.lastTurnBeganAt ?? 0
            let recencyMe = me.lastTurnBeganAt ?? 0
            if recencyOther > recencyMe
                || (recencyOther == recencyMe && outranks(other, 0, me, 0)) {
                return .wait(maxNanoseconds: poll)
            }
        }
        return .proceed
    }

    /// Whether a waiting participant is owed a turn, and by how much (ns).
    private func claim(_ waiter: GPUTurnParticipantState, state: GPUTurnArbiterState) -> (owed: Bool, overdue: Double) {
        guard let since = waiter.waitingSince else { return (false, 0) }
        let others = state.others(than: waiter.id)
        // Nobody else has finished a turn since it began waiting: nothing to repay.
        guard others.contains(where: { ($0.lastTurnEndedAt ?? 0) >= since && $0.lastTurnEndedAt != nil }) else {
            return (false, 0)
        }
        let served = Double(state.now &- since)
        let ownQuantum = quantum(waiter, reference: since)
        let otherContenders = others.filter { $0.wantsTurn || $0.inTurn }
        var threshold: Double
        var repayingPrefill = false
        if case .prefillChunk = waiter.waitingKind, case .prefillChunk = waiter.lastTurnKind,
           otherContenders.contains(where: isDecoding) {
            threshold = ownQuantum * (1 - prefillShare) / prefillShare
            repayingPrefill = true
        } else {
            threshold = Double(max(otherContenders.count, 1)) * ownQuantum
        }
        threshold = min(threshold, window)
        // The runner whose next step is in question: the latest to begin a turn.
        let runner = others.filter { $0.lastTurnBeganAt != nil }.max { ($0.lastTurnBeganAt ?? 0) < ($1.lastTurnBeganAt ?? 0) }
        var halfStep = 0.0
        var carry = 0.0
        if let runner {
            halfStep = quantum(runner, reference: state.now) / 2
            // Prefill repayment is deliberately unequal: no carry toward equal waits.
            let cap = repayingPrefill ? 0 : min(tolerance, halfStep)
            let lead = waitTotal(waiter, now: state.now) - waitTotal(runner, now: state.now)
            carry = min(max(lead, -cap), cap)
        }
        let overdue = served + halfStep - (threshold - carry)
        return (overdue > 0, overdue)
    }

    /// The participant's last turn in ns; 0 when it never had one or it ended
    /// more than a window before `reference`.
    private func quantum(_ participant: GPUTurnParticipantState, reference: UInt64) -> Double {
        guard let began = participant.lastTurnBeganAt, let ended = participant.lastTurnEndedAt, ended >= began else {
            return 0
        }
        if reference > ended, Double(reference - ended) > window { return 0 }
        return min(Double(ended - began), window)
    }

    private func waitTotal(_ participant: GPUTurnParticipantState, now: UInt64) -> Double {
        let current = participant.waitingSince.map { now &- $0 } ?? 0
        return Double(participant.counters.waitNanoseconds) + Double(current)
    }

    private func isDecoding(_ participant: GPUTurnParticipantState) -> Bool {
        (participant.waitingKind ?? participant.lastTurnKind)?.isDecode ?? false
    }

    /// `a` goes before `b`: more overdue, then waiting longer, then lower id.
    private func outranks(_ a: GPUTurnParticipantState, _ aOverdue: Double, _ b: GPUTurnParticipantState, _ bOverdue: Double) -> Bool {
        if aOverdue != bOverdue { return aOverdue > bOverdue }
        let aSince = a.waitingSince ?? .max
        let bSince = b.waitingSince ?? .max
        if aSince != bSince { return aSince < bSince }
        return a.id < b.id
    }
}
