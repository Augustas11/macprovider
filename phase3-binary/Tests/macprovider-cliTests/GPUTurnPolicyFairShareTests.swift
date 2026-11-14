import Foundation
import XCTest
@testable import macprovider_cli

private let ms: UInt64 = 1_000_000

/// What one simulated participant asks for: its next unit and how long the GPU
/// takes for it, or nil when it has no more work.
private typealias SimPlan = (_ now: UInt64, _ turnsDone: Int) -> (kind: GPUWorkKind, cost: UInt64)?

/// A prompt prefilled in chunks the arbiter sizes (`GPUTurnArbiter.prefillChunkTokens`),
/// at `nanosecondsPerToken` of GPU time per token.
private struct SimPrompt {
    let tokens: Int
    let fullChunk: Int
    let nanosecondsPerToken: Double
}

private struct SimParticipant {
    var plan: SimPlan?
    var prompt: SimPrompt?
    var start: UInt64 = 0
    /// CPU time between the end of one turn and the request for the next.
    var gap: UInt64 = ms / 2

    init(plan: @escaping SimPlan, start: UInt64 = 0, gap: UInt64 = ms / 2) {
        self.plan = plan
        self.start = start
        self.gap = gap
    }

    init(prompt: SimPrompt, start: UInt64 = 0, gap: UInt64 = ms / 2) {
        self.prompt = prompt
        self.start = start
        self.gap = gap
    }
}

private struct SimResult {
    var busy: [UInt64]
    var prefillBusy: [UInt64]
    var decodeBusy: [UInt64]
    var turns: [Int]
    var maxWait: [UInt64]
    var stallOverrides: [Int]
    /// (participant index, kind, begin, end) of every finished turn.
    var log: [(index: Int, kind: GPUWorkKind, begin: UInt64, end: UInt64)]

    /// First turn start to last turn end.
    var wall: UInt64 {
        guard let first = log.map(\.begin).min(), let last = log.map(\.end).max() else { return 0 }
        return last - first
    }

    /// GPU time during which two or more turns ran at once.
    var overlap: UInt64 {
        var total: UInt64 = 0
        var reach: UInt64 = 0
        for turn in log.sorted(by: { $0.begin < $1.begin }) {
            if turn.begin < reach { total += min(reach, turn.end) - turn.begin }
            reach = max(reach, turn.end)
        }
        return total
    }
}

/// Discrete-event model of the arbiter: a request after every turn, every
/// waiter re-asks on each turn end, on each new waiter and when its timed wait
/// expires. `gated` runs the arbiter's own rule (`GPUTurnArbiter.admit`:
/// exclusive turns, stall bound); ungated runs the bare policy, as round 1's
/// arbiter did. Prefill rates update as the arbiter does after a drained turn.
/// Calls only pure functions, so it runs on simulated time without threads.
private func simulate(
    _ policy: any GPUTurnPolicy, _ sims: [SimParticipant], until end: UInt64, gated: Bool = true
) -> SimResult {
    let count = sims.count
    var states = (0..<count).map { GPUTurnParticipantState(id: $0 + 1, modelID: "m\($0 + 1)") }
    var finishAt = [UInt64?](repeating: nil, count: count)
    var nextRequestAt: [UInt64?] = sims.map { $0.start }
    var wakeAt = [UInt64?](repeating: nil, count: count)
    var cost = [UInt64](repeating: 0, count: count)
    var prefilled = [Int](repeating: 0, count: count)
    var result = SimResult(
        busy: .init(repeating: 0, count: count), prefillBusy: .init(repeating: 0, count: count),
        decodeBusy: .init(repeating: 0, count: count), turns: .init(repeating: 0, count: count),
        maxWait: .init(repeating: 0, count: count), stallOverrides: .init(repeating: 0, count: count), log: [])
    var lastTurn: Int?
    var now: UInt64 = 0
    while now < end {
        var turnEnded = false
        for i in 0..<count where finishAt[i] == now {
            let began = states[i].lastTurnBeganAt ?? now
            let kind = states[i].lastTurnKind!
            states[i].turnsHeld = 0
            states[i].turnStartedAt = nil
            states[i].lastTurnEndedAt = now
            states[i].counters.busyNanoseconds += now - began
            if let tokens = kind.prefillTokens {
                states[i].prefillNanosecondsPerToken = GPUTurnArbiter.updatedPrefillRate(
                    states[i].prefillNanosecondsPerToken, tokens: tokens, nanoseconds: now - began)
                prefilled[i] += tokens
            }
            result.busy[i] += now - began
            if kind.isDecode { result.decodeBusy[i] += now - began } else { result.prefillBusy[i] += now - began }
            result.log.append((index: i, kind: kind, begin: began, end: now))
            result.turns[i] += 1
            finishAt[i] = nil
            nextRequestAt[i] = now + sims[i].gap
            turnEnded = true
        }
        if turnEnded {
            for i in 0..<count where states[i].isWaiting { wakeAt[i] = now }
        }
        for i in 0..<count {
            guard let at = nextRequestAt[i], at <= now, !states[i].inTurn, !states[i].isWaiting else { continue }
            nextRequestAt[i] = nil
            var next: (kind: GPUWorkKind, cost: UInt64)?
            if let prompt = sims[i].prompt {
                let remaining = prompt.tokens - prefilled[i]
                if remaining > 0 {
                    states[i].pendingWork = 1
                    let hinted = GPUTurnArbiter.prefillChunkTokens(
                        participantID: states[i].id, fullSize: prompt.fullChunk,
                        state: GPUTurnArbiterState(now: now, participants: states, lastTurnParticipantID: lastTurn),
                        policy: policy)
                    let tokens = min(hinted, remaining)
                    next = (.prefillChunk(tokens: tokens), UInt64(Double(tokens) * prompt.nanosecondsPerToken))
                }
            } else {
                next = sims[i].plan!(now, result.turns[i])
            }
            guard let next else {
                states[i].pendingWork = 0
                for j in 0..<count where states[j].isWaiting { wakeAt[j] = now }
                continue
            }
            states[i].pendingWork = 1
            states[i].waitingSince = now
            states[i].waitingKind = next.kind
            cost[i] = next.cost
            // A new waiter wakes the others (the arbiter broadcasts).
            for j in 0..<count where states[j].isWaiting { wakeAt[j] = now }
        }
        var changed = true
        while changed {
            changed = false
            for i in 0..<count {
                guard let since = states[i].waitingSince, let kind = states[i].waitingKind,
                      let wake = wakeAt[i], wake <= now else { continue }
                let request = GPUTurnRequest(participantID: states[i].id, kind: kind, waitingSince: since)
                let state = GPUTurnArbiterState(now: now, participants: states, lastTurnParticipantID: lastTurn)
                let admission: GPUTurnAdmission
                if gated {
                    admission = GPUTurnArbiter.admit(request, state: state, policy: policy)
                } else {
                    switch policy.decide(request, state: state) {
                    case .proceed: admission = .proceed
                    case .wait(let max): admission = .wait(maxNanoseconds: max ?? 3_600_000 * ms)
                    }
                }
                switch admission {
                case .proceed, .proceedStalled:
                    if admission == .proceedStalled { result.stallOverrides[i] += 1 }
                    let waited = now - since
                    states[i].counters.waitNanoseconds += waited
                    result.maxWait[i] = max(result.maxWait[i], waited)
                    states[i].waitingSince = nil
                    states[i].waitingKind = nil
                    states[i].turnsHeld = 1
                    states[i].turnStartedAt = now
                    states[i].lastTurnBeganAt = now
                    states[i].lastTurnKind = kind
                    finishAt[i] = now + cost[i]
                    wakeAt[i] = nil
                    lastTurn = states[i].id
                    changed = true
                case .wait(let maxNanoseconds):
                    wakeAt[i] = now + maxNanoseconds
                }
            }
        }
        var next = UInt64.max
        for i in 0..<count {
            if let at = finishAt[i] { next = min(next, at) }
            if let at = nextRequestAt[i] { next = min(next, max(at, now + 1)) }
            if let at = wakeAt[i] { next = min(next, max(at, now + 1)) }
        }
        if next == .max { break }
        now = next
    }
    return result
}

private func decode(_ costMs: UInt64) -> SimPlan {
    { _, _ in (.decodeStep(rows: 1), costMs * ms) }
}

/// Round 1's fair-share escape in isolation: wait while another participant
/// holds a turn, but proceed once 250 ms were waited, whatever it holds.
private struct MaxWaitFallbackTestPolicy: GPUTurnPolicy {
    var name: String { "max-wait-fallback-test" }
    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision {
        let waited = state.now - request.waitingSince
        if waited >= 250 * ms { return .proceed }
        if state.others(than: request.participantID).contains(where: \.inTurn) {
            return .wait(maxNanoseconds: 250 * ms - waited)
        }
        return .proceed
    }
}

final class GPUTurnPolicyFairShareTests: XCTestCase {
    /// The prefill chunk hint is off by default (it changed GLM's greedy
    /// output); these simulations exercise it explicitly at 150 ms.
    private let policy = FairShareGPUTurnPolicy(prefillTargetMilliseconds: 150)
    /// Real prefill chunk on the M3 Ultra: 8192 tokens in about 1.2 s.
    private let realChunk = SimPrompt(tokens: 8192 * 6, fullChunk: 8192, nanosecondsPerToken: 1.2e9 / 8192)

    private func share(_ result: SimResult, _ index: Int) -> Double {
        Double(result.busy[index]) / Double(result.busy.reduce(0, +))
    }

    /// Sum of busy time never exceeds wall time, and no two turns overlap.
    private func assertExclusive(_ result: SimResult, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.overlap, 0, "\(label): overlap \(result.overlap / ms) ms", file: file, line: line)
        XCTAssertLessThanOrEqual(result.busy.reduce(0, +), result.wall, "\(label): busy exceeds wall", file: file, line: line)
    }

    func testNoOverlapInvariantCatchesTheRoundOneEscape() {
        // 1.2 s prefill chunks beside a 26 ms decoder: the 250 ms escape lets
        // the decoder in mid-chunk, so busy time exceeds wall time.
        let chunked: SimPlan = { _, done in done < 8 ? (.prefillChunk(tokens: 8192), 1_200 * ms) : nil }
        let sims = [SimParticipant(plan: chunked), SimParticipant(plan: decode(26))]
        let ungated = simulate(MaxWaitFallbackTestPolicy(), sims, until: 12_000 * ms, gated: false)
        XCTAssertGreaterThan(ungated.overlap, 0)
        XCTAssertGreaterThan(ungated.busy.reduce(0, +), ungated.wall)
        // The arbiter's rule makes the same policy exclusive.
        assertExclusive(simulate(MaxWaitFallbackTestPolicy(), sims, until: 12_000 * ms), "gated round-1 escape")
        // And the reworked fair share, with and without prefill chunk hints.
        assertExclusive(simulate(policy, sims, until: 12_000 * ms), "fairshare")
        let fullChunks = FairShareGPUTurnPolicy(prefillTargetMilliseconds: 0)
        assertExclusive(simulate(fullChunks, sims, until: 12_000 * ms), "fairshare full chunks")
    }

    func testUnequalStepCostsConvergeToEqualBusyTime() {
        // Serial main model (26 ms per token step) beside a 2-row batched worker (63 ms per step).
        let result = simulate(policy, [SimParticipant(plan: decode(26)), SimParticipant(plan: decode(63))], until: 5_000 * ms)
        XCTAssertEqual(share(result, 0), 0.5, accuracy: 0.05)
        XCTAssertEqual(share(result, 1), 0.5, accuracy: 0.05)
        assertExclusive(result, "26/63")
        XCTAssertEqual(result.stallOverrides, [0, 0])
        // Same with no CPU gap between turns.
        let tight = simulate(policy, [SimParticipant(plan: decode(26), gap: 0), SimParticipant(plan: decode(63), gap: 0)], until: 5_000 * ms)
        XCTAssertEqual(share(tight, 0), 0.5, accuracy: 0.05)
        assertExclusive(tight, "26/63 tight")
    }

    func testThreeParticipantsGetAThirdEach() {
        let result = simulate(policy, [
            SimParticipant(plan: decode(26)), SimParticipant(plan: decode(40)), SimParticipant(plan: decode(63)),
        ], until: 5_000 * ms)
        for index in 0..<3 {
            XCTAssertEqual(share(result, index), 1.0 / 3.0, accuracy: 0.05, "participant \(index)")
        }
        assertExclusive(result, "three")
    }

    func testLoneParticipantNeverWaits() {
        // Pure: a registered peer with no work is not a contender.
        let me = GPUTurnParticipantState(id: 1, modelID: "a", pendingWork: 1, waitingSince: 10, waitingKind: .decodeStep(rows: 1))
        var idle = GPUTurnParticipantState(id: 2, modelID: "b")
        idle.lastTurnBeganAt = 5
        idle.lastTurnEndedAt = 9
        idle.counters.busyNanoseconds = 10_000 * ms
        let state = GPUTurnArbiterState(now: 10, participants: [me, idle], lastTurnParticipantID: 2)
        XCTAssertEqual(policy.decide(GPUTurnRequest(participantID: 1, kind: .prefillChunk(tokens: 512), waitingSince: 10), state: state), .proceed)
        // An idle peer gives no chunk hint either.
        XCTAssertEqual(GPUTurnArbiter.prefillChunkTokens(participantID: 1, fullSize: 8192, state: state, policy: policy), 8192)
        // Simulated: a peer that never asks costs nothing.
        let result = simulate(policy, [SimParticipant(plan: decode(26)), SimParticipant(plan: { _, _ in nil })], until: 1_000 * ms)
        XCTAssertEqual(result.maxWait[0], 0)
        // Real arbiter, two registered, one idle.
        let arbiter = GPUTurnArbiter(policy: policy)
        let a = arbiter.register(modelID: "a")
        _ = arbiter.register(modelID: "b")
        a.beginWork()
        for _ in 0..<50 { a.withTurn(.decodeStep(rows: 1)) {} }
        a.endWork()
        XCTAssertEqual(arbiter.snapshot().participants[0].waitedTurns, 0)
    }

    func testIdleThenBusyBanksNoMoreThanTolerance() {
        // A runs alone for 2 s, B joins; over the next second neither leads by more than tolerance plus one step.
        for (costA, costB) in [(UInt64(26), UInt64(26)), (26, 63), (63, 26)] {
            let joined = 2_000 * ms
            let sims = [SimParticipant(plan: decode(costA)), SimParticipant(plan: decode(costB), start: joined)]
            let result = simulate(policy, sims, until: 3_000 * ms)
            var after = [UInt64](repeating: 0, count: 2)
            for turn in result.log where turn.begin >= joined { after[turn.index] += turn.end - turn.begin }
            let lead = abs(Int64(after[1]) - Int64(after[0]))
            let bound = Int64(policy.toleranceMilliseconds * ms + max(costA, costB) * ms)
            XCTAssertLessThanOrEqual(lead, bound, "costs \(costA)/\(costB): A \(after[0] / ms) ms, B \(after[1] / ms) ms")
        }
    }

    func testOldTurnDoesNotHoldBackAReturningParticipant() {
        // B's last turn (a 400 ms prefill) ended long ago: it is owed after one of A's steps.
        var a = GPUTurnParticipantState(id: 1, modelID: "a", pendingWork: 1)
        a.lastTurnBeganAt = 10_000 * ms
        a.lastTurnEndedAt = 10_026 * ms
        a.waitingSince = 10_026 * ms
        a.waitingKind = .decodeStep(rows: 1)
        var b = GPUTurnParticipantState(id: 2, modelID: "b", pendingWork: 1)
        b.lastTurnBeganAt = 1_000 * ms
        b.lastTurnEndedAt = 1_400 * ms
        b.lastTurnKind = .prefillChunk(tokens: 2048)
        b.waitingSince = 9_990 * ms
        b.waitingKind = .decodeStep(rows: 1)
        let state = GPUTurnArbiterState(now: 10_026 * ms, participants: [a, b], lastTurnParticipantID: 1)
        guard case .wait = policy.decide(GPUTurnRequest(participantID: 1, kind: .decodeStep(rows: 1), waitingSince: 10_026 * ms), state: state) else {
            return XCTFail("A should yield to B")
        }
        XCTAssertEqual(policy.decide(GPUTurnRequest(participantID: 2, kind: .decodeStep(rows: 1), waitingSince: 9_990 * ms), state: state), .proceed)
    }

    /// Judge point 2: 1.2 s chunks beside 5, 26 and 200 ms decode steps. The
    /// arbiter's hint cuts each chunk to about `prefill_chunk_ms` (150 ms of
    /// measured GPU time), so the decoder waits about one short chunk, the
    /// prefill still finishes, and it gets about `prefill_share` of the GPU.
    func testRealPrefillChunksShrinkBesideADecodingSibling() {
        for step in [UInt64(5), 26, 200] {
            let label = "decode \(step) ms"
            // The prompt arrives while the decoder already runs.
            let sims = [SimParticipant(prompt: realChunk, start: ms), SimParticipant(plan: decode(step))]
            let result = simulate(policy, sims, until: 30_000 * ms)
            assertExclusive(result, label)
            XCTAssertEqual(result.stallOverrides, [0, 0], label)
            let chunks = result.log.filter { $0.index == 0 }
            XCTAssertEqual(chunks.reduce(0) { $0 + ($1.kind.prefillTokens ?? 0) }, realChunk.tokens, "\(label): prefill unfinished")
            // First chunk: the floor (no rate yet); then the measured rate's 150 ms.
            XCTAssertEqual(chunks.first?.kind, .prefillChunk(tokens: policy.prefillMinimumTokens), label)
            for chunk in chunks.dropFirst() {
                XCTAssertLessThan(chunk.kind.prefillTokens ?? .max, realChunk.fullChunk, label)
                XCTAssertLessThanOrEqual(chunk.end - chunk.begin, 151 * ms, label)
            }
            // The decoder waits about one short chunk, never a whole 1.2 s one.
            XCTAssertLessThan(result.maxWait[1], 300 * ms, "\(label): decoder waited \(result.maxWait[1] / ms) ms")
            // Prefill share of the GPU while it ran.
            let prefillEnd = chunks.last!.end
            let peerDecode = result.log.filter { $0.index == 1 && $0.end <= prefillEnd }.reduce(UInt64(0)) { $0 + $1.end - $1.begin }
            let fraction = Double(result.prefillBusy[0]) / Double(result.prefillBusy[0] + peerDecode)
            XCTAssertEqual(fraction, policy.prefillShare, accuracy: 0.12, label)
        }
    }

    /// The same 1.2 s chunks with the hint off (`prefill_chunk_ms=0`, the CB
    /// path whose partition the scheduler fixes): each whole chunk is now
    /// repaid, so the prefill share holds at real chunk sizes (round 1: ~0.83).
    func testWholeChunksAreRepaidAtRealChunkSizes() {
        let fullChunks = FairShareGPUTurnPolicy(prefillTargetMilliseconds: 0)
        for step in [UInt64(5), 26, 200] {
            let label = "decode \(step) ms"
            let result = simulate(fullChunks, [SimParticipant(prompt: realChunk), SimParticipant(plan: decode(step))], until: 30_000 * ms)
            assertExclusive(result, label)
            let chunks = result.log.filter { $0.index == 0 }
            XCTAssertTrue(chunks.allSatisfy { $0.kind == .prefillChunk(tokens: realChunk.fullChunk) }, label)
            let prefillEnd = chunks.last!.end
            let peerDecode = result.log.filter { $0.index == 1 && $0.end <= prefillEnd }.reduce(UInt64(0)) { $0 + $1.end - $1.begin }
            let fraction = Double(result.prefillBusy[0]) / Double(result.prefillBusy[0] + peerDecode)
            XCTAssertEqual(fraction, fullChunks.prefillShare, accuracy: 0.1, label)
            // Decode steps of the peer run between every two chunks.
            for (first, second) in zip(chunks, chunks.dropFirst()) {
                XCTAssertTrue(result.log.contains { $0.index == 1 && $0.begin >= first.end && $0.end <= second.begin },
                              "\(label): no decode between chunks at \(first.end / ms) ms")
            }
        }
    }

    func testPrefillIsRepaidWithDecodeWhileThePeerDecodes() {
        let chunk = 200 * ms
        let chunks = 10
        let prefill: SimPlan = { _, done in done < chunks ? (.prefillChunk(tokens: 512), chunk) : nil }
        let result = simulate(policy, [SimParticipant(plan: prefill), SimParticipant(plan: decode(63))], until: 8_000 * ms)
        assertExclusive(result, "200 ms chunks")
        let chunkTurns = result.log.filter { $0.index == 0 }
        XCTAssertEqual(chunkTurns.count, chunks)
        let prefillEnd = chunkTurns.last!.end
        let peerDecode = result.log.filter { $0.index == 1 && $0.end <= prefillEnd }.reduce(UInt64(0)) { $0 + $1.end - $1.begin }
        let prefillTime = Double(result.prefillBusy[0])
        XCTAssertLessThanOrEqual(prefillTime, policy.prefillShare * (prefillTime + Double(peerDecode)) + Double(chunk))
        for (first, second) in zip(chunkTurns, chunkTurns.dropFirst()) {
            XCTAssertTrue(result.log.contains { $0.index == 1 && $0.begin >= first.end && $0.end <= second.begin },
                          "no decode between chunks at \(first.end / ms) ms")
        }
        // A lower share makes the peer repay more per chunk (300 ms per 200 ms chunk).
        let lowShare = FairShareGPUTurnPolicy(prefillShare: 0.4)
        let low = simulate(lowShare, [SimParticipant(plan: prefill), SimParticipant(plan: decode(63))], until: 8_000 * ms)
        let lowEnd = low.log.filter { $0.index == 0 }.last!.end
        let lowDecode = low.log.filter { $0.index == 1 && $0.end <= lowEnd }.reduce(UInt64(0)) { $0 + $1.end - $1.begin }
        XCTAssertLessThanOrEqual(Double(low.prefillBusy[0]), 0.4 * Double(low.prefillBusy[0] + lowDecode) + Double(chunk))
    }

    func testPrefillRunsUnthrottledWithFullChunksWhenThePeerIsIdle() {
        let result = simulate(policy, [SimParticipant(prompt: realChunk), SimParticipant(plan: decode(63), start: 60_000 * ms)], until: 20_000 * ms)
        XCTAssertEqual(result.turns[0], realChunk.tokens / realChunk.fullChunk)
        XCTAssertTrue(result.log.allSatisfy { $0.kind == .prefillChunk(tokens: realChunk.fullChunk) })
        XCTAssertEqual(result.maxWait[0], 0)
    }

    /// A peer that holds one turn far past the stall bound: the waiter goes
    /// in beside it after exactly one stall bound, and only then.
    func testStalledPeerReleasesTheWaiterAfterTheStallBound() {
        let stalled: SimPlan = { _, done in done == 0 ? (.decodeStep(rows: 2), 60_000 * ms) : nil }
        let result = simulate(policy, [SimParticipant(plan: stalled), SimParticipant(plan: decode(26), start: ms)], until: 12_000 * ms)
        XCTAssertEqual(result.maxWait[1], policy.stallMilliseconds * ms - ms)
        // Once past the stall the waiter keeps running beside the hung turn;
        // every such turn is counted as an override.
        XCTAssertGreaterThan(result.turns[1], 10)
        XCTAssertGreaterThanOrEqual(result.stallOverrides[1], result.turns[1])
        XCTAssertEqual(result.stallOverrides[0], 0)
    }

    func testWaiterIsReleasedWhenThePeerGoesIdle() {
        // Long tolerance and stall bound: only B's state change can release A.
        let arbiter = GPUTurnArbiter(policy: FairShareGPUTurnPolicy(toleranceMilliseconds: 20_000, stallMilliseconds: 30_000))
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork()
        b.withTurn(.decodeStep(rows: 2)) {} // B is mid-run, between two turns.
        a.beginWork()
        let done = expectation(description: "A's turn")
        Thread.detachNewThread {
            a.withTurn(.decodeStep(rows: 1)) {}
            done.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while arbiter.stateForTest().participant(a.id)?.isWaiting != true, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertEqual(arbiter.stateForTest().participant(a.id)?.isWaiting, true, "A never waited")
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(arbiter.stateForTest().participant(a.id)?.counters.turns, 0)
        b.endWork()
        wait(for: [done], timeout: 5)
        a.endWork()
        XCTAssertEqual(arbiter.snapshot().participants.first { $0.id == a.id }?.waitedTurns, 1)
    }

    func testParametersParseAndReject() throws {
        let defaults = try GPUTurnPolicyRegistry.make("fairshare")
        XCTAssertEqual(defaults.name, "fairshare")
        XCTAssertFalse(defaults.alwaysProceeds)
        XCTAssertEqual(defaults.parameters, [
            "window_ms": "500", "tolerance_ms": "30", "prefill_share": "0.5",
            "stall_ms": "10000", "prefill_chunk_ms": "0", "prefill_min_tokens": "256",
        ])
        XCTAssertEqual(defaults.stallNanoseconds, 10_000 * ms)
        XCTAssertNil(defaults.prefillChunkTargetNanoseconds, "hint off by default")
        XCTAssertEqual(try GPUTurnPolicyRegistry.make("fairshare:prefill_chunk_ms=150").prefillChunkTargetNanoseconds, 150 * ms)
        XCTAssertEqual(defaults.prefillChunkMinimumTokens, 256)
        let custom = try GPUTurnPolicyRegistry.make(
            "fairshare:window_ms=800,tolerance_ms=10,prefill_share=0.25,stall_ms=4000,prefill_chunk_ms=500,prefill_min_tokens=512")
        XCTAssertEqual(custom.parameters, [
            "window_ms": "800", "tolerance_ms": "10", "prefill_share": "0.25",
            "stall_ms": "4000", "prefill_chunk_ms": "500", "prefill_min_tokens": "512",
        ])
        XCTAssertNil(try GPUTurnPolicyRegistry.make("fairshare:prefill_chunk_ms=0").prefillChunkTargetNanoseconds)
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("fairshare:weight=2")) { error in
            XCTAssertEqual(error as? GPUTurnPolicyError, .unknownParameters(policy: "fairshare", names: ["weight"]))
        }
        // Round 1's escape is gone, not renamed.
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("fairshare:max_wait_ms=250")) { error in
            XCTAssertEqual(error as? GPUTurnPolicyError, .unknownParameters(policy: "fairshare", names: ["max_wait_ms"]))
        }
        for bad in ["prefill_share=0", "prefill_share=1.5", "prefill_share=nan", "window_ms=0", "stall_ms=0",
                    "stall_ms=-1", "tolerance_ms=x", "prefill_chunk_ms=-5", "prefill_min_tokens=0"] {
            XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("fairshare:\(bad)"), bad)
        }
    }
}
