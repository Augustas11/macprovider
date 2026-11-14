import Foundation
import XCTest
@testable import macprovider_cli

/// A policy that always says wait: proves the single-participant fast path
/// never consults the policy.
private struct AlwaysWaitTestPolicy: GPUTurnPolicy {
    var name: String { "always-wait-test" }
    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision {
        .wait(maxNanoseconds: nil)
    }
}

/// Strict alternation: a caller may not take two turns in a row while another
/// participant wants one, and never runs beside another participant's turn.
private struct StrictAlternationTestPolicy: GPUTurnPolicy {
    var name: String { "strict-alternation-test" }
    func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision {
        let others = state.others(than: request.participantID)
        if others.contains(where: \.inTurn) { return .wait(maxNanoseconds: nil) }
        if state.lastTurnParticipantID == request.participantID, others.contains(where: \.wantsTurn) {
            return .wait(maxNanoseconds: nil)
        }
        return .proceed
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000

    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ nanos: UInt64) { lock.lock(); value += nanos; lock.unlock() }
}

private final class TurnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int] = []

    func append(_ id: Int) { lock.lock(); entries.append(id); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class GPUTurnArbiterTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return condition()
    }

    /// Starts `body` on a plain thread; the returned expectation fulfils when it returns.
    private func onThread(_ description: String, _ body: @escaping @Sendable () -> Void) -> XCTestExpectation {
        let done = expectation(description: description)
        Thread.detachNewThread {
            body()
            done.fulfill()
        }
        return done
    }

    func testPassthroughNeverBlocksEvenBesideAnotherTurn() {
        let arbiter = GPUTurnArbiter(policy: PassthroughGPUTurnPolicy())
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        a.beginTurn(.decodeStep(rows: 1))
        // Same thread: a wait here would never return.
        b.beginTurn(.prefillChunk(tokens: 512))
        b.endTurn()
        a.endTurn()
        let snapshot = arbiter.snapshot()
        XCTAssertEqual(snapshot.policy, "passthrough")
        XCTAssertEqual(snapshot.participants.map(\.turns), [1, 1])
        XCTAssertEqual(snapshot.participants.map(\.waitedTurns), [0, 0])
        XCTAssertEqual(snapshot.participants.map(\.waitSeconds), [0, 0])
    }

    func testSingleParticipantNeverConsultsThePolicy() {
        let arbiter = GPUTurnArbiter(policy: AlwaysWaitTestPolicy())
        let only = arbiter.register(modelID: "only")
        for _ in 0..<100 {
            only.withTurn(.decodeStep(rows: 2)) {}
        }
        let stats = arbiter.snapshot().participants[0]
        XCTAssertEqual(stats.turns, 100)
        XCTAssertEqual(stats.decodeSteps, 100)
        XCTAssertEqual(stats.decodeRows, 200)
        XCTAssertEqual(stats.waitedTurns, 0)
    }

    func testNestedTurnOfOneParticipantNeverWaitsOnItself() {
        let arbiter = GPUTurnArbiter(policy: AlwaysWaitTestPolicy())
        let a = arbiter.register(modelID: "a")
        _ = arbiter.register(modelID: "b")
        // With two participants the policy is consulted, so the outer turn
        // has to be granted some other way: switch policy around it.
        arbiter.setPolicy(PassthroughGPUTurnPolicy())
        a.beginTurn(.decodeStep(rows: 1))
        arbiter.setPolicy(AlwaysWaitTestPolicy())
        a.beginTurn(.prefillChunk(tokens: 16))
        a.endTurn()
        a.endTurn()
        XCTAssertEqual(arbiter.snapshot().participants[0].turns, 2)
    }

    func testStrictAlternationAlternatesAndFinishes() {
        let arbiter = GPUTurnArbiter(policy: StrictAlternationTestPolicy())
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        let log = TurnLog()
        let turnsEach = 200
        a.beginWork()
        b.beginWork()
        var expectations: [XCTestExpectation] = []
        for participant in [a, b] {
            expectations.append(onThread("participant \(participant.id)") {
                for _ in 0..<turnsEach {
                    participant.withTurn(.decodeStep(rows: 1)) { log.append(participant.id) }
                }
                participant.endWork()
            })
        }
        wait(for: expectations, timeout: 30)
        let order = log.all
        XCTAssertEqual(order.count, 2 * turnsEach)
        XCTAssertEqual(order.filter { $0 == a.id }.count, turnsEach)
        // Both want turns until each has had all of its own, so no
        // participant ever takes two in a row.
        for index in 1..<order.count {
            XCTAssertNotEqual(order[index], order[index - 1], "two turns in a row at \(index)")
        }
        let stats = arbiter.snapshot().participants
        XCTAssertEqual(stats.map(\.turns), [turnsEach, turnsEach])
        XCTAssertGreaterThan(stats.map(\.waitedTurns).reduce(0, +), 0)
    }

    /// The classic deadlock: A waits for B's turn, then B goes idle without
    /// taking one. A must be released by B's state change.
    func testWaiterIsReleasedWhenTheOtherParticipantGoesIdle() {
        let arbiter = GPUTurnArbiter(policy: StrictAlternationTestPolicy())
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork()
        a.withTurn(.decodeStep(rows: 1)) {} // A had the last turn.
        let released = onThread("A second turn") {
            a.withTurn(.decodeStep(rows: 1)) {}
        }
        XCTAssertTrue(waitUntil { arbiter.stateForTest().participant(a.id)?.isWaiting == true }, "A never waited")
        b.endWork() // B goes idle mid-wait.
        wait(for: [released], timeout: 5)
        let stats = arbiter.snapshot().participants.first { $0.id == a.id }!
        XCTAssertEqual(stats.turns, 2)
        XCTAssertEqual(stats.waitedTurns, 1)
        XCTAssertGreaterThan(stats.waitSeconds, 0)
        XCTAssertEqual(stats.maxWaitSeconds, stats.waitSeconds)
    }

    func testWaiterIsReleasedWhenTheOtherParticipantUnregisters() {
        let arbiter = GPUTurnArbiter(policy: StrictAlternationTestPolicy())
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork()
        a.withTurn(.decodeStep(rows: 1)) {}
        let released = onThread("A second turn") {
            a.withTurn(.decodeStep(rows: 1)) {}
        }
        XCTAssertTrue(waitUntil { arbiter.stateForTest().participant(a.id)?.isWaiting == true })
        arbiter.unregister(b) // B's runtime unloads mid-wait.
        wait(for: [released], timeout: 5)
        XCTAssertEqual(arbiter.snapshot().participants.map(\.id), [a.id])
        // A runtime that unloads still finishes its loop: its calls proceed untracked.
        b.withTurn(.decodeStep(rows: 1)) {}
    }

    func testWaiterThatUnregistersItselfReturns() {
        let arbiter = GPUTurnArbiter(policy: StrictAlternationTestPolicy())
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork()
        a.withTurn(.decodeStep(rows: 1)) {}
        let released = onThread("A second turn") {
            a.withTurn(.decodeStep(rows: 1)) {}
        }
        XCTAssertTrue(waitUntil { arbiter.stateForTest().participant(a.id)?.isWaiting == true })
        arbiter.unregister(a)
        wait(for: [released], timeout: 5)
        XCTAssertFalse(arbiter.isRegistered(a))
    }

    func testWaiterIsReleasedWhenTheOtherTakesAndEndsItsTurn() {
        let arbiter = GPUTurnArbiter(policy: StrictAlternationTestPolicy())
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork()
        a.withTurn(.decodeStep(rows: 1)) {}
        let released = onThread("A second turn") {
            a.withTurn(.decodeStep(rows: 1)) {}
        }
        XCTAssertTrue(waitUntil { arbiter.stateForTest().participant(a.id)?.isWaiting == true })
        b.withTurn(.prefillChunk(tokens: 64)) {}
        wait(for: [released], timeout: 5)
        b.endWork()
        XCTAssertEqual(arbiter.snapshot().participants.map(\.turns), [2, 1])
    }

    func testTimedWaitReasksThePolicy() {
        struct WaitOnceTestPolicy: GPUTurnPolicy {
            var name: String { "wait-briefly-test" }
            func decide(_ request: GPUTurnRequest, state: GPUTurnArbiterState) -> GPUTurnDecision {
                state.now - request.waitingSince >= 20_000_000 ? .proceed : .wait(maxNanoseconds: 5_000_000)
            }
        }
        let arbiter = GPUTurnArbiter(policy: WaitOnceTestPolicy())
        let a = arbiter.register(modelID: "a")
        _ = arbiter.register(modelID: "b")
        let started = Date()
        a.withTurn(.decodeStep(rows: 1)) {}
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.02)
        XCTAssertEqual(arbiter.snapshot().participants[0].waitedTurns, 1)
    }

    func testStatisticsAddUp() {
        let clock = ManualClock()
        let arbiter = GPUTurnArbiter(policy: PassthroughGPUTurnPolicy(), clock: { clock.now() })
        let a = arbiter.register(modelID: "model-a")
        let b = arbiter.register(modelID: "model-b")
        let before = arbiter.snapshot(resettingMaxWait: true)

        a.beginTurn(.prefillChunk(tokens: 512))
        clock.advance(10_000_000)
        a.endTurn()
        a.beginTurn(.prefillChunk(tokens: 100))
        clock.advance(2_000_000)
        a.endTurn()
        for _ in 0..<5 {
            b.beginTurn(.decodeStep(rows: 2))
            clock.advance(1_000_000)
            b.endTurn()
            clock.advance(500_000)
        }
        // A turn in progress counts its time so far.
        a.beginTurn(.decodeStep(rows: 1))
        clock.advance(3_000_000)

        let delta = arbiter.snapshot().delta(since: before)
        let rowA = delta.participants.first { $0.id == a.id }!
        let rowB = delta.participants.first { $0.id == b.id }!
        XCTAssertEqual(rowA.modelID, "model-a")
        XCTAssertEqual(rowA.turns, 3)
        XCTAssertEqual(rowA.prefillChunks, 2)
        XCTAssertEqual(rowA.prefillTokens, 612)
        XCTAssertEqual(rowA.decodeSteps, 1)
        XCTAssertEqual(rowA.busySeconds, 0.015, accuracy: 1e-9)
        XCTAssertEqual(rowB.turns, 5)
        XCTAssertEqual(rowB.decodeSteps, 5)
        XCTAssertEqual(rowB.decodeRows, 10)
        XCTAssertEqual(rowB.busySeconds, 0.005, accuracy: 1e-9)
        XCTAssertEqual(rowA.waitSeconds + rowB.waitSeconds, 0)
        a.endTurn()
        XCTAssertEqual(arbiter.snapshot().participants.first { $0.id == a.id }!.busySeconds, 0.015, accuracy: 1e-9)
    }

    func testScopeIsIdempotentAndClosesItsTurnAndWork() {
        let arbiter = GPUTurnArbiter(policy: PassthroughGPUTurnPolicy())
        let a = arbiter.register(modelID: "a")
        do {
            let scope = GPUTurnScope(a)
            scope.open()
            scope.open()
            scope.end() // nothing held: no-op
            scope.begin(.prefillChunk(tokens: 8))
            scope.begin(.prefillChunk(tokens: 8)) // already held: no-op
            scope.yield(.decodeStep(rows: 1))
            withExtendedLifetime(scope) {
                XCTAssertEqual(arbiter.stateForTest().participant(a.id)?.pendingWork, 1)
                XCTAssertEqual(arbiter.stateForTest().participant(a.id)?.turnsHeld, 1)
            }
            // Dropped while holding: deinit releases both.
        }
        let state = arbiter.stateForTest().participant(a.id)!
        XCTAssertEqual(state.turnsHeld, 0)
        XCTAssertEqual(state.pendingWork, 0)
        XCTAssertEqual(state.counters.turns, 2)
        // Unbalanced ends on the participant are ignored.
        a.endTurn()
        a.endWork()
        XCTAssertEqual(arbiter.stateForTest().participant(a.id)?.turnsHeld, 0)
    }

    func testReregisterKeepsHandleAndRelabels() {
        let arbiter = GPUTurnArbiter()
        let a = arbiter.register(modelID: "first")
        arbiter.unregister(a)
        XCTAssertFalse(arbiter.isRegistered(a))
        arbiter.register(a, modelID: "second")
        XCTAssertTrue(arbiter.isRegistered(a))
        XCTAssertEqual(arbiter.snapshot().participants.map(\.modelID), ["second"])
    }

    func testRegistryParsesAndRejects() throws {
        XCTAssertEqual(try GPUTurnPolicyRegistry.make("passthrough").name, "passthrough")
        XCTAssertTrue(try GPUTurnPolicyRegistry.make(" passthrough ").alwaysProceeds)
        let parsed = try GPUTurnPolicyRegistry.parse("fair:share=0.5, chunk=256")
        XCTAssertEqual(parsed.name, "fair")
        XCTAssertEqual(parsed.parameters, ["share": "0.5", "chunk": "256"])
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("no-such-policy")) { error in
            XCTAssertEqual(error as? GPUTurnPolicyError, .unknownPolicy("no-such-policy", known: ["passthrough"]))
        }
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("passthrough:k=v"))
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.parse("x:novalue"))
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.parse("x:a=1,a=2"))
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.parse(":a=1"))
        XCTAssertEqual(GPUTurnPolicyRegistry.compiledDefault.name, "passthrough")
    }

    func testLabSelectionPrefersFlagOverEnvironment() throws {
        let key = GPUTurnPolicyRegistry.labEnvironmentKey
        XCTAssertNil(try GPUTurnPolicyRegistry.labSelection(flag: nil, environment: [:]))
        XCTAssertEqual(try GPUTurnPolicyRegistry.labSelection(flag: nil, environment: [key: "passthrough"])?.source, "env")
        XCTAssertEqual(try GPUTurnPolicyRegistry.labSelection(flag: "passthrough", environment: [key: "bogus"])?.source, "flag")
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.labSelection(flag: nil, environment: [key: "bogus"]))
    }
}
