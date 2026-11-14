import Foundation
import XCTest
@testable import macprovider_cli

private let ms: UInt64 = 1_000_000

/// What one simulated participant asks for: its next unit and how long the GPU
/// takes for it, or nil when it has no more work.
private typealias SimPlan = (_ now: UInt64, _ turnsDone: Int) -> (kind: GPUWorkKind, cost: UInt64)?

private struct SimParticipant {
    let plan: SimPlan
    var start: UInt64 = 0
    /// CPU time between the end of one turn and the request for the next.
    var gap: UInt64 = ms / 2
}

private struct SimResult {
    var busy: [UInt64]
    var prefillBusy: [UInt64]
    var decodeBusy: [UInt64]
    var turns: [Int]
    var maxWait: [UInt64]
    /// (participant index, kind, begin, end) of every finished turn.
    var log: [(index: Int, kind: GPUWorkKind, begin: UInt64, end: UInt64)]
}

/// Discrete-event model of the arbiter: exclusive GPU, a request after every
/// turn, every waiter re-asks on each turn end and when its timed wait expires.
/// Calls only the pure `decide`, so it runs on simulated time without threads.
private func simulate(_ policy: any GPUTurnPolicy, _ sims: [SimParticipant], until end: UInt64) -> SimResult {
    let count = sims.count
    var states = (0..<count).map { GPUTurnParticipantState(id: $0 + 1, modelID: "m\($0 + 1)") }
    var finishAt = [UInt64?](repeating: nil, count: count)
    var nextRequestAt: [UInt64?] = sims.map { $0.start }
    var wakeAt = [UInt64?](repeating: nil, count: count)
    var cost = [UInt64](repeating: 0, count: count)
    var result = SimResult(
        busy: .init(repeating: 0, count: count), prefillBusy: .init(repeating: 0, count: count),
        decodeBusy: .init(repeating: 0, count: count), turns: .init(repeating: 0, count: count),
        maxWait: .init(repeating: 0, count: count), log: [])
    var lastTurn: Int?
    var now: UInt64 = 0
    while now < end {
        var turnEnded = false
        for i in 0..<count where finishAt[i] == now {
            let began = states[i].lastTurnBeganAt ?? now
            states[i].turnsHeld = 0
            states[i].turnStartedAt = nil
            states[i].lastTurnEndedAt = now
            states[i].counters.busyNanoseconds += now - began
            result.busy[i] += now - began
            if states[i].lastTurnKind?.isDecode == true { result.decodeBusy[i] += now - began } else { result.prefillBusy[i] += now - began }
            result.log.append((index: i, kind: states[i].lastTurnKind!, begin: began, end: now))
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
            guard let next = sims[i].plan(now, result.turns[i]) else {
                states[i].pendingWork = 0
                continue
            }
            states[i].pendingWork = 1
            states[i].waitingSince = now
            states[i].waitingKind = next.kind
            cost[i] = next.cost
            wakeAt[i] = now
        }
        var changed = true
        while changed {
            changed = false
            for i in 0..<count {
                guard let since = states[i].waitingSince, let kind = states[i].waitingKind,
                      let wake = wakeAt[i], wake <= now else { continue }
                let decision = policy.decide(
                    GPUTurnRequest(participantID: states[i].id, kind: kind, waitingSince: since),
                    state: GPUTurnArbiterState(now: now, participants: states, lastTurnParticipantID: lastTurn))
                switch decision {
                case .proceed:
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
                    wakeAt[i] = now + (maxNanoseconds ?? 3_600_000 * ms)
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

final class GPUTurnPolicyFairShareTests: XCTestCase {
    private let policy = FairShareGPUTurnPolicy()

    private func share(_ result: SimResult, _ index: Int) -> Double {
        Double(result.busy[index]) / Double(result.busy.reduce(0, +))
    }

    func testUnequalStepCostsConvergeToEqualBusyTime() {
        // Serial main model (26 ms per token step) beside a 2-row batched worker (63 ms per step).
        let result = simulate(policy, [SimParticipant(plan: decode(26)), SimParticipant(plan: decode(63))], until: 5_000 * ms)
        XCTAssertEqual(share(result, 0), 0.5, accuracy: 0.05)
        XCTAssertEqual(share(result, 1), 0.5, accuracy: 0.05)
        XCTAssertLessThanOrEqual(result.maxWait.max()!, policy.maxWaitMilliseconds * ms)
        // Same with no CPU gap between turns.
        let tight = simulate(policy, [SimParticipant(plan: decode(26), gap: 0), SimParticipant(plan: decode(63), gap: 0)], until: 5_000 * ms)
        XCTAssertEqual(share(tight, 0), 0.5, accuracy: 0.05)
    }

    func testThreeParticipantsGetAThirdEach() {
        let result = simulate(policy, [
            SimParticipant(plan: decode(26)), SimParticipant(plan: decode(40)), SimParticipant(plan: decode(63)),
        ], until: 5_000 * ms)
        for index in 0..<3 {
            XCTAssertEqual(share(result, index), 1.0 / 3.0, accuracy: 0.05, "participant \(index)")
        }
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

    func testPrefillIsRepaidWithDecodeWhileThePeerDecodes() {
        let chunk = 200 * ms
        let chunks = 10
        let prefill: SimPlan = { _, done in done < chunks ? (.prefillChunk(tokens: 512), chunk) : nil }
        let result = simulate(policy, [SimParticipant(plan: prefill), SimParticipant(plan: decode(63))], until: 8_000 * ms)
        let chunkTurns = result.log.filter { $0.index == 0 }
        XCTAssertEqual(chunkTurns.count, chunks)
        let prefillEnd = chunkTurns.last!.end
        let peerDecode = result.log.filter { $0.index == 1 && $0.end <= prefillEnd }.reduce(UInt64(0)) { $0 + $1.end - $1.begin }
        let prefillTime = Double(result.prefillBusy[0])
        XCTAssertLessThanOrEqual(prefillTime, policy.prefillShare * (prefillTime + Double(peerDecode)) + Double(chunk))
        // Decode steps of the peer run between every two chunks.
        for (first, second) in zip(chunkTurns, chunkTurns.dropFirst()) {
            XCTAssertTrue(result.log.contains { $0.index == 1 && $0.begin >= first.end && $0.end <= second.begin },
                          "no decode between chunks at \(first.end / ms) ms")
        }
        // The prefill never starves.
        XCTAssertLessThanOrEqual(result.maxWait[0], policy.maxWaitMilliseconds * ms)

        // A lower share makes the peer repay more per chunk (the repayment,
        // 300 ms per 200 ms chunk, must fit under max_wait to hold).
        let lowShare = FairShareGPUTurnPolicy(prefillShare: 0.4, maxWaitMilliseconds: 1_000)
        let low = simulate(lowShare, [SimParticipant(plan: prefill), SimParticipant(plan: decode(63))], until: 8_000 * ms)
        let lowEnd = low.log.filter { $0.index == 0 }.last!.end
        let lowDecode = low.log.filter { $0.index == 1 && $0.end <= lowEnd }.reduce(UInt64(0)) { $0 + $1.end - $1.begin }
        XCTAssertLessThanOrEqual(Double(low.prefillBusy[0]), 0.4 * Double(low.prefillBusy[0] + lowDecode) + Double(chunk))
    }

    func testPrefillRunsUnthrottledWhenThePeerIsIdle() {
        let prefill: SimPlan = { _, done in done < 10 ? (.prefillChunk(tokens: 512), 200 * ms) : nil }
        let result = simulate(policy, [SimParticipant(plan: prefill), SimParticipant(plan: decode(63), start: 10_000 * ms)], until: 3_000 * ms)
        XCTAssertEqual(result.turns[0], 10)
        XCTAssertEqual(result.maxWait[0], 0)
    }

    func testWaiterIsReleasedWhenThePeerGoesIdle() {
        // Long tolerance and max wait: only B's state change can release A.
        let arbiter = GPUTurnArbiter(policy: FairShareGPUTurnPolicy(toleranceMilliseconds: 20_000, maxWaitMilliseconds: 30_000))
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

    func testStalledPeerDelaysAtMostMaxWait() {
        let arbiter = GPUTurnArbiter(policy: FairShareGPUTurnPolicy(maxWaitMilliseconds: 100))
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork()
        b.beginTurn(.decodeStep(rows: 2)) // B holds its turn and never comes back.
        a.beginWork()
        let started = Date()
        let done = expectation(description: "A's turn")
        Thread.detachNewThread {
            a.withTurn(.decodeStep(rows: 1)) {}
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.09)
        XCTAssertLessThan(elapsed, 1.0)
        b.endTurn()
        b.endWork()
        a.endWork()
    }

    func testParametersParseAndReject() throws {
        let defaults = try GPUTurnPolicyRegistry.make("fairshare")
        XCTAssertEqual(defaults.name, "fairshare")
        XCTAssertFalse(defaults.alwaysProceeds)
        XCTAssertEqual(defaults.parameters, ["window_ms": "500", "tolerance_ms": "30", "prefill_share": "0.5", "max_wait_ms": "250"])
        let custom = try GPUTurnPolicyRegistry.make("fairshare:window_ms=800,tolerance_ms=10,prefill_share=0.25,max_wait_ms=400")
        XCTAssertEqual(custom.parameters, ["window_ms": "800", "tolerance_ms": "10", "prefill_share": "0.25", "max_wait_ms": "400"])
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("fairshare:weight=2")) { error in
            XCTAssertEqual(error as? GPUTurnPolicyError, .unknownParameters(policy: "fairshare", names: ["weight"]))
        }
        for bad in ["prefill_share=0", "prefill_share=1.5", "prefill_share=nan", "window_ms=0", "max_wait_ms=-1", "tolerance_ms=x"] {
            XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("fairshare:\(bad)"), bad)
        }
    }
}
