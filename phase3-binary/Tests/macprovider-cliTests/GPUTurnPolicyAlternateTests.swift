import Foundation
import XCTest
@testable import macprovider_cli

private final class AlternateTurnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int] = []

    func append(_ id: Int) { lock.lock(); entries.append(id); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class GPUTurnPolicyAlternateTests: XCTestCase {
    private func policy(_ spec: String = "alternate") throws -> any GPUTurnPolicy {
        try GPUTurnPolicyRegistry.make(spec)
    }

    private func participant(
        _ id: Int, pending: Int = 0, waitingSince: UInt64? = nil, held: Int = 0, turns: Int = 0
    ) -> GPUTurnParticipantState {
        var state = GPUTurnParticipantState(id: id, modelID: "m\(id)")
        state.pendingWork = pending
        state.waitingSince = waitingSince
        state.turnsHeld = held
        state.counters.turns = turns
        return state
    }

    private func decide(
        _ policy: any GPUTurnPolicy, id: Int, waitingSince: UInt64 = 1_000, now: UInt64 = 1_000,
        last: Int?, _ participants: [GPUTurnParticipantState]
    ) -> GPUTurnDecision {
        policy.decide(
            GPUTurnRequest(participantID: id, kind: .decodeStep(rows: 1), waitingSince: waitingSince),
            state: GPUTurnArbiterState(now: now, participants: participants, lastTurnParticipantID: last))
    }

    private func isWait(_ decision: GPUTurnDecision) -> Bool {
        if case .wait = decision { return true }
        return false
    }

    private func run(_ spec: String, participants count: Int, turnsEach: Int) -> [Int] {
        let arbiter = GPUTurnArbiter(policy: try! policy(spec))
        let handles = (0..<count).map { arbiter.register(modelID: "m\($0)") }
        let log = AlternateTurnLog()
        handles.forEach { $0.beginWork() }
        var done: [XCTestExpectation] = []
        for handle in handles {
            let finished = expectation(description: "participant \(handle.id)")
            done.append(finished)
            Thread.detachNewThread {
                for _ in 0..<turnsEach {
                    handle.withTurn(.decodeStep(rows: 1)) { log.append(handle.id) }
                }
                handle.endWork()
                finished.fulfill()
            }
        }
        wait(for: done, timeout: 60)
        return log.all
    }

    func testFactoryParametersAndRejections() throws {
        let defaults = try policy()
        XCTAssertEqual(defaults.name, "alternate")
        XCTAssertEqual(defaults.parameters, ["burst": "1", "max_wait_ms": "250"])
        XCTAssertFalse(defaults.alwaysProceeds)
        XCTAssertEqual(try policy("alternate:burst=3,max_wait_ms=40").parameters, ["burst": "3", "max_wait_ms": "40"])
        XCTAssertThrowsError(try policy("alternate:ratio=1:2"))
        XCTAssertThrowsError(try policy("alternate:bogus=1")) { error in
            XCTAssertEqual(error as? GPUTurnPolicyError, .unknownParameters(policy: "alternate", names: ["bogus"]))
        }
        XCTAssertThrowsError(try policy("alternate:burst=0"))
        XCTAssertThrowsError(try policy("alternate:burst=x"))
        XCTAssertThrowsError(try policy("alternate:max_wait_ms=-5"))
    }

    func testLoneParticipantNeverWaits() throws {
        let p = try policy()
        XCTAssertEqual(decide(p, id: 1, last: 1, [participant(1, pending: 1, turns: 5)]), .proceed)
        // A peer with nothing pending and no turn does not want the GPU.
        XCTAssertEqual(decide(p, id: 1, last: 1, [participant(1, pending: 1, turns: 5), participant(2)]), .proceed)
        let arbiter = GPUTurnArbiter(policy: p)
        let only = arbiter.register(modelID: "only")
        let started = Date()
        for _ in 0..<50 { only.withTurn(.decodeStep(rows: 1)) {} }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertEqual(arbiter.snapshot().participants[0].waitedTurns, 0)
    }

    func testBurstOneYieldsToWantingPeerAndOnlyThen() throws {
        let p = try policy()
        var ran = participant(1, pending: 1, turns: 3)
        ran.lastTurnBeganAt = 900
        let peers = [ran, participant(2, pending: 1, turns: 2)]
        XCTAssertTrue(isWait(decide(p, id: 1, last: 1, peers)))
        XCTAssertEqual(decide(p, id: 2, last: 1, peers), .proceed)
        // Peer went idle: no wait.
        XCTAssertEqual(decide(p, id: 1, last: 1, [participant(1, pending: 1, turns: 3), participant(2, turns: 2)]), .proceed)
        // Peer waiting (no pending interval) also counts as wanting.
        XCTAssertTrue(isWait(decide(p, id: 1, last: 1, [participant(1, pending: 1, turns: 3), participant(2, waitingSince: 900, turns: 2)])))
    }

    func testBurstTwoAllowsTwoTurnsThenYields() throws {
        let p = try policy("alternate:burst=2")
        func peers(_ mine: Int) -> [GPUTurnParticipantState] {
            [participant(1, pending: 1, turns: mine), participant(2, pending: 1, turns: 4)]
        }
        XCTAssertEqual(decide(p, id: 1, last: 1, peers(3)), .proceed) // one of two taken
        XCTAssertTrue(isWait(decide(p, id: 1, last: 1, peers(4)))) // two taken
    }

    func testNeverStartsBesideAnotherTurn() throws {
        let p = try policy()
        let busy = [participant(1, pending: 1), participant(2, pending: 1, held: 1)]
        XCTAssertTrue(isWait(decide(p, id: 1, last: 2, busy)))
    }

    func testWaitsAreTimedAndBoundedByMaxWait() throws {
        let p = try policy("alternate:max_wait_ms=10")
        let peers = [participant(1, pending: 1, turns: 1), participant(2, pending: 1)]
        guard case .wait(let ns?) = decide(p, id: 1, waitingSince: 1_000, now: 1_000, last: 1, peers) else {
            return XCTFail("expected a timed wait")
        }
        XCTAssertGreaterThan(ns, 0)
        XCTAssertLessThanOrEqual(ns, 5_000_000)
        // 9.999 ms in: the remaining wait is clipped to 1 us.
        XCTAssertEqual(decide(p, id: 1, waitingSince: 1_000, now: 10_000_999, last: 1, peers), .wait(maxNanoseconds: 1))
        // 10 ms in: proceed.
        XCTAssertEqual(decide(p, id: 1, waitingSince: 1_000, now: 10_001_000, last: 1, peers), .proceed)
    }

    func testThreeParticipantsRotateByLongestWaiter() throws {
        let p = try policy()
        // 1 just ran; 2 was served longer ago than 3. 2 goes first, 3 and 1 hold back.
        var one = participant(1, pending: 1, turns: 1)
        one.lastTurnBeganAt = 900
        var two = participant(2, pending: 1, waitingSince: 500)
        two.lastTurnBeganAt = 100
        var three = participant(3, pending: 1, waitingSince: 800)
        three.lastTurnBeganAt = 300
        let state = [one, two, three]
        XCTAssertEqual(decide(p, id: 2, waitingSince: 500, last: 1, state), .proceed)
        XCTAssertTrue(isWait(decide(p, id: 3, waitingSince: 800, last: 1, state)))
        XCTAssertTrue(isWait(decide(p, id: 1, waitingSince: 1_000, last: 1, state)))
    }

    func testTwoParticipantsAlternateOneToOne() {
        let turnsEach = 100
        let order = run("alternate", participants: 2, turnsEach: turnsEach)
        XCTAssertEqual(order.count, 2 * turnsEach)
        for index in 1..<order.count {
            XCTAssertNotEqual(order[index], order[index - 1], "two turns in a row at \(index)")
        }
    }

    func testBurstTwoAlternatesTwoToTwo() {
        let turnsEach = 100
        let order = run("alternate:burst=2", participants: 2, turnsEach: turnsEach)
        XCTAssertEqual(order.count, 2 * turnsEach)
        for pair in stride(from: 0, to: order.count, by: 2) {
            XCTAssertEqual(order[pair], order[pair + 1], "burst split at \(pair)")
            if pair >= 2 { XCTAssertNotEqual(order[pair], order[pair - 1], "burst longer than 2 at \(pair)") }
        }
    }

    func testThreeParticipantsRotate() {
        let turnsEach = 60
        let order = run("alternate", participants: 3, turnsEach: turnsEach)
        XCTAssertEqual(order.count, 3 * turnsEach)
        let steady = Array(order.prefix(3 * (turnsEach - 2)))
        for index in 2..<steady.count {
            XCTAssertEqual(Set(steady[(index - 2)...index]).count, 3, "not a rotation at \(index): \(steady[(index - 2)...index])")
        }
    }

    func testWaiterIsReleasedWhenThePeerGoesIdleMidWait() {
        let arbiter = GPUTurnArbiter(policy: try! policy("alternate:max_wait_ms=5000"))
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork()
        a.withTurn(.decodeStep(rows: 1)) {}
        let released = expectation(description: "A second turn")
        Thread.detachNewThread {
            a.withTurn(.decodeStep(rows: 1)) {}
            released.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while arbiter.stateForTest().participant(a.id)?.isWaiting != true, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertEqual(arbiter.stateForTest().participant(a.id)?.isWaiting, true)
        let idleAt = Date()
        b.endWork()
        wait(for: [released], timeout: 2)
        XCTAssertLessThan(Date().timeIntervalSince(idleAt), 1)
    }

    func testStalledPeerDelaysWaiterByAtMostMaxWait() {
        let arbiter = GPUTurnArbiter(policy: try! policy("alternate:max_wait_ms=60"))
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork() // pending work, never asks for a turn
        a.withTurn(.decodeStep(rows: 1)) {}
        let started = Date()
        a.withTurn(.decodeStep(rows: 1)) {}
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.055)
        XCTAssertLessThan(elapsed, 0.5)
        let stats = arbiter.snapshot().participants.first { $0.id == a.id }!
        XCTAssertEqual(stats.turns, 2)
        XCTAssertEqual(stats.waitedTurns, 1)
        XCTAssertLessThan(stats.maxWaitSeconds, 0.5)
    }
}
