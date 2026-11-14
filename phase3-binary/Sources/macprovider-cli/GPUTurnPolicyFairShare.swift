import Foundation

// SPEC-001-R018 (#2338): equal shares of GPU busy time, with prefill repaid in
// decode time. A participant that waited is "owed" a turn once the others have
// had, since it began waiting, the GPU time its own last turn took (times the
// number of other contenders), rounded to the nearest whole step of whoever is
// running. While another participant decodes, a mid-prefill participant is
// owed only after the others had `(1 - prefill_share) / prefill_share` of its
// last chunk, so each chunk is repaid with their decode time before the next.
// The most overdue owed waiter goes next; with nobody owed, the participant in
// the middle of its run keeps the GPU.
//
// Exclusivity is the arbiter's: this policy is asked only while nobody holds a
// turn, and nobody starts beside a turn shorter than `stall_ms`. There is no
// "waited long enough" escape; a waiter goes past the rule only when the peer
// is stalled (the arbiter's stall bound). Busy time is therefore GPU time, and
// a turn includes the drain of the work it queued (the arbiter's), so a
// pipelined serial loop pays for its own queued step.
//
// With `prefill_chunk_ms` > 0 (default 0: off, see
// `GPUTurnPolicyDefaults.prefillChunkTargetMilliseconds`) and another
// participant active, the arbiter sizes this participant's prefill chunks to
// about that much GPU time (measured rate, at least `prefill_min_tokens`), so a
// decoding sibling waits about one step per chunk instead of a whole 1.2 s
// chunk. `prefill_chunk_ms=0` keeps full-size chunks; the repayment rule then still holds the prefill share, because a
// prefill quantum is no longer capped at `window_ms`.
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

struct FairShareGPUTurnPolicy: GPUTurnPolicy {
    static let name = "fairshare"
    static let defaultWindowMilliseconds: UInt64 = 500
    static let defaultToleranceMilliseconds: UInt64 = 30
    static let defaultPrefillShare = 0.5
    static let defaultStallMilliseconds = GPUTurnPolicyDefaults.stallMilliseconds
    static let defaultPrefillTargetMilliseconds = GPUTurnPolicyDefaults.prefillChunkTargetMilliseconds
    static let defaultPrefillMinimumTokens = GPUTurnPolicyDefaults.prefillChunkMinimumTokens

    static let factory = GPUTurnPolicyFactory(
        name: name,
        summary: "Equal GPU busy time per contender with exclusive turns; prefill repaid with decode time (window_ms=500, tolerance_ms=30, prefill_share=0.5, stall_ms=10000, prefill_chunk_ms=0 [0 = full chunks; >0 sizes chunks to that many ms while a sibling is active], prefill_min_tokens=256)."
    ) { parameters in
        var rest = parameters
        let window = try GPUTurnPolicyParameters.milliseconds(&rest, "window_ms", policy: name, default: defaultWindowMilliseconds)
        let tolerance = try GPUTurnPolicyParameters.milliseconds(&rest, "tolerance_ms", policy: name, default: defaultToleranceMilliseconds)
        let stall = try GPUTurnPolicyParameters.milliseconds(&rest, "stall_ms", policy: name, default: defaultStallMilliseconds)
        let target = try GPUTurnPolicyParameters.milliseconds(
            &rest, "prefill_chunk_ms", policy: name, default: defaultPrefillTargetMilliseconds, minimum: 0)
        let minimumTokens = try GPUTurnPolicyParameters.integer(
            &rest, "prefill_min_tokens", policy: name, default: defaultPrefillMinimumTokens, maximum: 1 << 20)
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
            windowMilliseconds: window, toleranceMilliseconds: tolerance, prefillShare: share,
            stallMilliseconds: stall, prefillTargetMilliseconds: target, prefillMinimumTokens: minimumTokens)
    }

    let windowMilliseconds: UInt64
    let toleranceMilliseconds: UInt64
    let prefillShare: Double
    let stallMilliseconds: UInt64
    let prefillTargetMilliseconds: UInt64
    let prefillMinimumTokens: Int

    init(
        windowMilliseconds: UInt64 = defaultWindowMilliseconds,
        toleranceMilliseconds: UInt64 = defaultToleranceMilliseconds,
        prefillShare: Double = defaultPrefillShare,
        stallMilliseconds: UInt64 = defaultStallMilliseconds,
        prefillTargetMilliseconds: UInt64 = defaultPrefillTargetMilliseconds,
        prefillMinimumTokens: Int = defaultPrefillMinimumTokens
    ) {
        self.windowMilliseconds = windowMilliseconds
        self.toleranceMilliseconds = toleranceMilliseconds
        self.prefillShare = prefillShare
        self.stallMilliseconds = stallMilliseconds
        self.prefillTargetMilliseconds = prefillTargetMilliseconds
        self.prefillMinimumTokens = prefillMinimumTokens
    }

    var name: String { Self.name }
    var parameters: [String: String] {
        [
            "window_ms": String(windowMilliseconds),
            "tolerance_ms": String(toleranceMilliseconds),
            "prefill_share": String(prefillShare),
            "stall_ms": String(stallMilliseconds),
            "prefill_chunk_ms": String(prefillTargetMilliseconds),
            "prefill_min_tokens": String(prefillMinimumTokens),
        ]
    }
    var stallNanoseconds: UInt64 { stallMilliseconds &* 1_000_000 }
    var prefillChunkTargetNanoseconds: UInt64? {
        prefillTargetMilliseconds == 0 ? nil : prefillTargetMilliseconds &* 1_000_000
    }
    var prefillChunkMinimumTokens: Int { prefillMinimumTokens }

    private var window: Double { Double(windowMilliseconds) * 1e6 }
    private var tolerance: Double { Double(toleranceMilliseconds) * 1e6 }
    private var toleranceNanoseconds: UInt64 { toleranceMilliseconds &* 1_000_000 }
    /// Longest prefill quantum (and repayment) the rule honours: half a stall
    /// bound, so repayment alone never reaches the stall escape.
    private var prefillCap: Double { Double(stallNanoseconds) / 2 }

    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision {
        let contenders = state.others(than: request.participantID).filter { $0.wantsTurn || $0.inTurn }
        if contenders.isEmpty { return .proceed }
        // The arbiter never asks while a live turn is held; a stalled holder is
        // its call too. Wait for the turn to end.
        if contenders.contains(where: \.inTurn) { return .wait(maxNanoseconds: nil) }

        var me = state.participant(request.participantID)
            ?? GPUTurnParticipantState(id: request.participantID, modelID: "")
        if me.waitingSince == nil {
            me.waitingSince = request.waitingSince
            me.waitingKind = request.kind
        }
        let mine = claim(me, state: state)
        // Owed-ness grows with time alone: re-ask exactly when this caller
        // becomes owed (not earlier), or at a state change.
        let untilOwed: UInt64? = mine.owed || !mine.repaying ? nil : UInt64(max(-mine.overdue, 1))

        for other in contenders where other.isWaiting {
            let theirs = claim(other, state: state)
            guard theirs.owed else { continue }
            if !mine.owed || outranks(other, theirs.overdue, me, mine.overdue) {
                // The other goes; its turn's end wakes this caller.
                return .wait(maxNanoseconds: untilOwed.map { min($0, toleranceNanoseconds) } ?? toleranceNanoseconds)
            }
        }
        guard !mine.owed else { return .proceed }

        // Nobody is owed. A prefill run never keeps the GPU by recency against
        // a waiting decoder: its next chunk goes only once owed (repaid), so
        // chunks cannot chain past the repayment.
        let iAmRepayingPrefill = repaysPrefill(me, state: state)
        if iAmRepayingPrefill, contenders.contains(where: { $0.isWaiting && isDecoding($0) }) {
            return .wait(maxNanoseconds: untilOwed)
        }

        // Otherwise the participant in the middle of its run keeps the GPU.
        for other in contenders {
            // A waiting prefill run that must first be repaid does not hold back a decoder.
            if other.isWaiting, isDecoding(me), repaysPrefill(other, state: state) { continue }
            if !other.isWaiting {
                // Between two turns of its run: give it up to one tolerance to come back.
                if let ended = other.lastTurnEndedAt, state.now >= ended {
                    let age = state.now - ended
                    if Double(age) < tolerance {
                        let comeBack = toleranceNanoseconds - age
                        return .wait(maxNanoseconds: untilOwed.map { min($0, comeBack) } ?? comeBack)
                    }
                }
                continue
            }
            let recencyOther = other.lastTurnBeganAt ?? 0
            let recencyMe = me.lastTurnBeganAt ?? 0
            if recencyOther > recencyMe
                || (recencyOther == recencyMe && outranks(other, 0, me, 0)) {
                return .wait(maxNanoseconds: untilOwed)
            }
        }
        return .proceed
    }

    /// Whether a waiting participant is owed a turn, and by how much (ns).
    /// `repaying` is false when nobody else finished a turn since it began
    /// waiting: then only a state change (another turn's end) can make it owed.
    private func claim(_ waiter: GPUTurnParticipantState, state: GPUTurnArbiterState) -> (owed: Bool, overdue: Double, repaying: Bool) {
        guard let since = waiter.waitingSince else { return (false, 0, false) }
        let others = state.others(than: waiter.id)
        // Nobody else has finished a turn since it began waiting: nothing to repay.
        guard others.contains(where: { ($0.lastTurnEndedAt ?? 0) >= since && $0.lastTurnEndedAt != nil }) else {
            return (false, 0, false)
        }
        let served = Double(state.now &- since)
        let ownQuantum = quantum(waiter, reference: since)
        let otherContenders = others.filter { $0.wantsTurn || $0.inTurn }
        var threshold: Double
        var repayingPrefill = false
        if repaysPrefill(waiter, state: state) {
            threshold = min(ownQuantum * (1 - prefillShare) / prefillShare, prefillCap)
            repayingPrefill = true
        } else {
            threshold = min(Double(max(otherContenders.count, 1)) * ownQuantum, max(window, ownQuantum))
        }
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
        return (overdue > 0, overdue, true)
    }

    /// The participant's last turn in ns; 0 when it never had one or it ended
    /// more than a window before `reference`. A decode quantum is capped at the
    /// window; a prefill quantum at half the stall bound, so a whole 1.2 s
    /// chunk is repaid, not just one window of it.
    private func quantum(_ participant: GPUTurnParticipantState, reference: UInt64) -> Double {
        guard let began = participant.lastTurnBeganAt, let ended = participant.lastTurnEndedAt, ended >= began else {
            return 0
        }
        if reference > ended, Double(reference - ended) > window { return 0 }
        let cap = participant.lastTurnKind?.prefillTokens != nil ? prefillCap : window
        return min(Double(ended - began), cap)
    }

    private func waitTotal(_ participant: GPUTurnParticipantState, now: UInt64) -> Double {
        let current = participant.waitingSince.map { now &- $0 } ?? 0
        return Double(participant.counters.waitNanoseconds) + Double(current)
    }

    /// A waiter in the middle of a prefill run (asks for a chunk after a
    /// chunk) while another contender decodes: its chunks are repaid.
    private func repaysPrefill(_ waiter: GPUTurnParticipantState, state: GPUTurnArbiterState) -> Bool {
        guard waiter.waitingKind?.prefillTokens != nil, waiter.lastTurnKind?.prefillTokens != nil else { return false }
        return state.participants.contains { $0.id != waiter.id && ($0.wantsTurn || $0.inTurn) && isDecoding($0) }
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
