import Foundation
import XCTest
@testable import macprovider_cli

final class GPUTurnPolicyTimeSliceTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let policy = TimeSliceGPUTurnPolicy(quantumMilliseconds: 100)

    private func participant(_ id: Int, pendingWork: Int = 1, inTurn: Bool = false) -> GPUTurnParticipantState {
        var state = GPUTurnParticipantState(id: id, modelID: "m\(id)")
        state.pendingWork = pendingWork
        state.turnsHeld = inTurn ? 1 : 0
        return state
    }

    /// Simulates participants with continuous demand and fixed step costs
    /// (ms); returns the GPU milliseconds each one was granted.
    private func simulate(costs: [Int], totalMilliseconds: Int, policy: any GPUTurnPolicy) -> [Int] {
        var states = costs.indices.map { participant($0 + 1) }
        var busyUntil = [UInt64](repeating: 0, count: costs.count)
        var waitingSince = [UInt64?](repeating: nil, count: costs.count)
        var granted = [Int](repeating: 0, count: costs.count)
        var last: Int?
        for tick in 0..<totalMilliseconds {
            let now = UInt64(tick) * ms
            for i in costs.indices {
                if states[i].turnsHeld > 0, busyUntil[i] <= now { states[i].turnsHeld = 0 }
            }
            for i in costs.indices where states[i].turnsHeld == 0 {
                if waitingSince[i] == nil { waitingSince[i] = now }
                states[i].waitingSince = waitingSince[i]
                let request = GPUTurnRequest(participantID: states[i].id, kind: .decodeStep(rows: 1), waitingSince: waitingSince[i]!)
                let decision = policy.decide(request, state: GPUTurnArbiterState(now: now, participants: states, lastTurnParticipantID: last))
                states[i].waitingSince = nil
                if decision == .proceed {
                    states[i].turnsHeld = 1
                    busyUntil[i] = now + UInt64(costs[i]) * ms
                    granted[i] += costs[i]
                    waitingSince[i] = nil
                    last = states[i].id
                }
            }
        }
        return granted
    }

    func testTwoContinuousParticipantsGetAboutHalfEach() {
        let granted = simulate(costs: [10, 10], totalMilliseconds: 2000, policy: policy)
        for share in granted {
            XCTAssertGreaterThan(share, 800, "\(granted)")
            XCTAssertLessThan(share, 1200, "\(granted)")
        }
    }

    func testThreeParticipantsRotate() {
        let granted = simulate(costs: [10, 10, 10], totalMilliseconds: 3000, policy: policy)
        for share in granted {
            XCTAssertGreaterThan(share, 700, "\(granted)")
            XCTAssertLessThan(share, 1300, "\(granted)")
        }
    }

    func testLoneParticipantNeverWaits() {
        let request = GPUTurnRequest(participantID: 1, kind: .decodeStep(rows: 1), waitingSince: 0)
        for tick: UInt64 in [0, 50, 100, 150, 999] {
            let state = GPUTurnArbiterState(
                now: tick * ms,
                participants: [participant(1), participant(2, pendingWork: 0)],
                lastTurnParticipantID: 1)
            XCTAssertEqual(policy.decide(request, state: state), .proceed)
        }
    }

    func testWaiterProceedsAtOnceWhenPeerGoesIdle() {
        // Slice 1 (100-200 ms) belongs to participant 2 of [1, 2].
        let request = GPUTurnRequest(participantID: 1, kind: .decodeStep(rows: 1), waitingSince: 110 * ms)
        var peer = participant(2)
        let busy = GPUTurnArbiterState(now: 120 * ms, participants: [participant(1), peer], lastTurnParticipantID: 2)
        // Sleeps to the slice boundary (200 ms), no 2 ms re-poll.
        XCTAssertEqual(policy.decide(request, state: busy), .wait(maxNanoseconds: 80 * ms))
        peer.pendingWork = 0
        let idle = GPUTurnArbiterState(now: 121 * ms, participants: [participant(1), peer], lastTurnParticipantID: 2)
        XCTAssertEqual(policy.decide(request, state: idle), .proceed)
    }

    func testStalledPeerDelaysWaiterAtMostTheStallBound() {
        // Long quantum so only the arbiter's stall bound can release the
        // waiter; the peer wants a turn but never asks or runs.
        let slow = TimeSliceGPUTurnPolicy(quantumMilliseconds: 10_000, stallMilliseconds: 250)
        let start = 10_000 * ms // slice 1: participant 2's
        let request = GPUTurnRequest(participantID: 1, kind: .decodeStep(rows: 1), waitingSince: start)
        var waitedMilliseconds: UInt64 = 0
        while waitedMilliseconds < 1000 {
            let state = GPUTurnArbiterState(
                now: start + waitedMilliseconds * ms,
                participants: [participant(1), participant(2)],
                lastTurnParticipantID: 2)
            if GPUTurnArbiter.admit(request, state: state, policy: slow) != .wait(maxNanoseconds: (250 - waitedMilliseconds) * ms) { break }
            waitedMilliseconds += 1
        }
        XCTAssertEqual(waitedMilliseconds, 250)
        // A peer holding a live turn in the waiter's own slice is waited for, not bypassed.
        let mine = TimeSliceGPUTurnPolicy(quantumMilliseconds: 100)
        var holder = participant(2, inTurn: true)
        holder.turnStartedAt = 0
        let ownSlice = GPUTurnArbiterState(now: 20 * ms, participants: [participant(1), holder], lastTurnParticipantID: 2)
        let early = GPUTurnRequest(participantID: 1, kind: .decodeStep(rows: 1), waitingSince: 0)
        XCTAssertEqual(mine.decide(early, state: GPUTurnArbiterState(now: 20 * ms, participants: [participant(1), participant(2)], lastTurnParticipantID: 2)), .proceed)
        XCTAssertEqual(GPUTurnArbiter.admit(early, state: ownSlice, policy: mine), .wait(maxNanoseconds: 10_000 * ms - 20 * ms))
    }

    func testWaitsAreTimed() {
        let request = GPUTurnRequest(participantID: 1, kind: .decodeStep(rows: 1), waitingSince: 110 * ms)
        let state = GPUTurnArbiterState(now: 120 * ms, participants: [participant(1), participant(2, inTurn: true)], lastTurnParticipantID: 2)
        guard case .wait(let max) = policy.decide(request, state: state) else { return XCTFail("expected wait") }
        XCTAssertNotNil(max)
        XCTAssertLessThanOrEqual(max ?? .max, 100 * ms)
    }

    func testFactoryParametersAndRejection() throws {
        let made = try GPUTurnPolicyRegistry.make("timeslice:quantum_ms=40,stall_ms=90")
        XCTAssertEqual(made.name, "timeslice")
        XCTAssertEqual(made.parameters, ["quantum_ms": "40", "stall_ms": "90"])
        XCTAssertEqual(made.stallNanoseconds, 90 * ms)
        XCTAssertEqual(try GPUTurnPolicyRegistry.make("timeslice").parameters, ["quantum_ms": "100", "stall_ms": "10000"])
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("timeslice:max_wait_ms=250"))
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("timeslice:bogus=1"))
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("timeslice:quantum_ms=0"))
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("timeslice:quantum_ms=abc"))
    }
}
