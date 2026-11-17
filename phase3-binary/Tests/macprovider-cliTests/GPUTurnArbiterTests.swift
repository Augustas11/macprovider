import Foundation
import MLXLMCommon
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
            guard case .unknownPolicy(let name, let known)? = error as? GPUTurnPolicyError else {
                return XCTFail("expected unknownPolicy, got \(error)")
            }
            XCTAssertEqual(name, "no-such-policy")
            XCTAssertTrue(Set(known).isSuperset(of: ["passthrough", "alternate", "timeslice", "fairshare"]), "\(known)")
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

    func testUnregisteredHandleProceedsAndRecordsNothingUntilRegistered() {
        let arbiter = GPUTurnArbiter(policy: AlwaysWaitTestPolicy())
        let other = arbiter.register(modelID: "other")
        let pending = arbiter.makeParticipant()
        XCTAssertFalse(arbiter.isRegistered(pending))
        // Not registered: no wait even under an always-wait policy, and the
        // other participant keeps its single-participant fast path.
        pending.withTurn(.prefillChunk(tokens: 8)) {}
        other.withTurn(.decodeStep(rows: 1)) {}
        XCTAssertEqual(arbiter.snapshot().participants.map(\.id), [other.id])
        arbiter.register(pending, modelID: "pending")
        XCTAssertTrue(arbiter.isRegistered(pending))
        XCTAssertNotEqual(pending.id, other.id)
    }

    /// A runtime whose initializer throws before every property is set runs
    /// no deinit; it must leave no participant in the process arbiter.
    func testRuntimeInitThatThrowsLeavesNoParticipant() async {
        let modelID = "mlx-community/gpt-oss-20b-gpu-turn-leak-test"
        do {
            // Explicit kv_bits on gpt-oss is refused before any load.
            _ = try await ModelRuntime(modelID: modelID, kvBitsOverride: 4)
            XCTFail("expected the quantized-KV refusal")
        } catch {
            XCTAssertTrue(error is ModelRuntimeLoadError, "\(error)")
        }
        XCTAssertFalse(GPUTurnArbiter.shared.stateForTest().participants.contains { $0.modelID == modelID })
    }

    /// The serial prefill seam: the caller's turn covers the first chunk, the
    /// progress report after each chunk passes the turn on, and the iterator's
    /// final forward (the remainder) runs in the last one. A 16-token prompt at
    /// step 4 under the legacy remainder plan is four forwards in four turns.
    func testChunkedPrefillTakesOneTurnPerChunk() throws {
        let arbiter = GPUTurnArbiter(policy: PassthroughGPUTurnPolicy())
        let a = arbiter.register(modelID: "a")
        let scope = GPUTurnScope(a)
        scope.open()
        let stepSize = 4
        let total = 16
        var prefill = PrefillParameters.legacyRemainder(stepSize: stepSize)
        // No MLX arrays pass through this loop and CI hosts have no default
        // metallib, so the per-chunk buffer cache clear is off here.
        prefill.clearsBufferCache = false
        prefill.progress = scope.prefillProgress(stepSize: stepSize)
        var turnAtForward: [Int] = []
        func fakeForward(_ tokens: Int) {
            let state = arbiter.stateForTest().participant(a.id)!
            XCTAssertEqual(state.turnsHeld, 1)
            XCTAssertEqual(state.lastTurnKind, .prefillChunk(tokens: tokens))
            turnAtForward.append(state.counters.turns)
        }

        scope.begin(.prefillChunk(tokens: min(stepSize, total)))
        // `LLMModel.prepare` under `.remainder` reserves one step for the iterator.
        let processed = try prefill.forEachChunk(total: total, reserving: stepSize) { range in
            fakeForward(range.count)
        }
        fakeForward(total - processed)
        prefill.progress?(total, total)
        scope.end()
        scope.close()

        XCTAssertEqual(processed, 12)
        XCTAssertEqual(turnAtForward, [1, 2, 3, 4])
        let counters = arbiter.stateForTest().participant(a.id)!.counters
        XCTAssertEqual(counters.prefillChunks, 4)
        XCTAssertEqual(counters.prefillTokens, total)
        XCTAssertEqual(arbiter.stateForTest().participant(a.id)?.turnsHeld, 0)
    }

    // MARK: Round 2: exclusivity, stall bound, cancellation, drain, chunk hint

    /// Judge point 1: a waiter is never let in beside a live turn because it
    /// waited 250 ms. B holds a 400 ms turn; A starts only after B's ends.
    func testLiveTurnIsNeverBypassedByWaitingLong() {
        let arbiter = GPUTurnArbiter(policy: FairShareGPUTurnPolicy(stallMilliseconds: 5_000))
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        let times = TurnTimes()
        a.beginWork()
        b.beginWork()
        b.beginTurn(.prefillChunk(tokens: 8192))
        let started = Date()
        let done = onThread("A's turn") {
            a.withTurn(.decodeStep(rows: 1)) { times.set(aBegan: Date()) }
        }
        XCTAssertTrue(waitUntil { arbiter.stateForTest().participant(a.id)?.isWaiting == true })
        Thread.sleep(forTimeInterval: 0.4)
        times.set(bEnded: Date())
        b.endTurn()
        wait(for: [done], timeout: 5)
        XCTAssertGreaterThanOrEqual(times.aBegan!, times.bEnded!)
        XCTAssertGreaterThanOrEqual(times.aBegan!.timeIntervalSince(started), 0.39)
        let stats = arbiter.snapshot().participants.first { $0.id == a.id }!
        XCTAssertEqual(stats.stallOverrides, 0)
        a.endWork()
        b.endWork()
    }

    /// A peer that holds its turn and never returns: the waiter goes in beside
    /// it once the turn is older than `stall_ms`, and the override is counted.
    func testStalledHolderReleasesTheWaiterAfterTheStallBound() {
        let arbiter = GPUTurnArbiter(policy: FairShareGPUTurnPolicy(stallMilliseconds: 100))
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork()
        b.beginTurn(.decodeStep(rows: 2)) // B holds its turn and never comes back.
        a.beginWork()
        let started = Date()
        let done = onThread("A's turn") {
            a.withTurn(.decodeStep(rows: 1)) {}
        }
        wait(for: [done], timeout: 5)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.09)
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(arbiter.snapshot().participants.first { $0.id == a.id }?.stallOverrides, 1)
        b.endTurn()
        b.endWork()
        a.endWork()
    }

    /// Judge point 4: a cancelled caller leaves the wait promptly, takes no
    /// turn and leaves no waiting state; the participant stays usable.
    func testCancelledWaiterLeavesPromptlyWithoutATurn() {
        let arbiter = GPUTurnArbiter(policy: FairShareGPUTurnPolicy(stallMilliseconds: 30_000))
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork()
        b.beginTurn(.decodeStep(rows: 2))
        let flag = CancelFlag()
        let result = ResultBox()
        let done = onThread("A's cancelled wait") {
            result.set(a.beginTurn(.decodeStep(rows: 1), isCancelled: { flag.isSet }))
        }
        XCTAssertTrue(waitUntil { arbiter.stateForTest().participant(a.id)?.isWaiting == true })
        let cancelledAt = Date()
        flag.set()
        wait(for: [done], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.5)
        XCTAssertEqual(result.value, false)
        let state = arbiter.stateForTest().participant(a.id)!
        XCTAssertEqual(state.turnsHeld, 0)
        XCTAssertNil(state.waitingSince)
        XCTAssertEqual(state.counters.turns, 0)
        XCTAssertEqual(state.counters.cancelledWaits, 1)
        // B's turn is untouched; after it ends A takes turns normally.
        XCTAssertEqual(arbiter.stateForTest().participant(b.id)?.turnsHeld, 1)
        b.endTurn()
        b.endWork()
        XCTAssertTrue(a.beginTurn(.decodeStep(rows: 1)))
        a.endTurn()
        XCTAssertEqual(arbiter.stateForTest().participant(a.id)?.turnsHeld, 0)
    }

    /// A scope whose wait is cancelled holds nothing; `end`/`close` are safe.
    func testCancelledScopeHoldsNoTurnAndClosesCleanly() {
        let arbiter = GPUTurnArbiter(policy: FairShareGPUTurnPolicy(stallMilliseconds: 30_000))
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        b.beginWork()
        b.beginTurn(.decodeStep(rows: 2))
        let scope = GPUTurnScope(a)
        scope.open()
        scope.isCancelled = { true }
        let started = Date()
        XCTAssertFalse(scope.begin(.decodeStep(rows: 1)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        scope.end()
        scope.close()
        let state = arbiter.stateForTest().participant(a.id)!
        XCTAssertEqual(state.turnsHeld, 0)
        XCTAssertEqual(state.pendingWork, 0)
        XCTAssertNil(state.waitingSince)
        b.endTurn()
        b.endWork()
    }

    /// Judge point 3: under a sharing policy a turn drains the work it queued
    /// before it ends, and the drain is its own busy time. One participant or
    /// passthrough never drains (asyncEval pipelining untouched).
    func testSharingTurnDrainsQueuedWorkAndChargesItToItsOwner() {
        let clock = ManualClock()
        let drains = Counter()
        let drain: @Sendable () -> Void = { drains.increment(); clock.advance(7_000_000) }

        let lone = GPUTurnArbiter(policy: FairShareGPUTurnPolicy(), clock: { clock.now() }, drainQueuedWork: drain)
        let only = lone.register(modelID: "only")
        only.withTurn(.decodeStep(rows: 1)) { clock.advance(1_000_000) }
        XCTAssertEqual(drains.value, 0)

        let pass = GPUTurnArbiter(policy: PassthroughGPUTurnPolicy(), clock: { clock.now() }, drainQueuedWork: drain)
        let p1 = pass.register(modelID: "p1")
        _ = pass.register(modelID: "p2")
        p1.withTurn(.decodeStep(rows: 1)) {}
        XCTAssertEqual(drains.value, 0)

        let arbiter = GPUTurnArbiter(policy: FairShareGPUTurnPolicy(), clock: { clock.now() }, drainQueuedWork: drain)
        let a = arbiter.register(modelID: "a")
        _ = arbiter.register(modelID: "b")
        a.withTurn(.decodeStep(rows: 1)) { clock.advance(26_000_000) }
        XCTAssertEqual(drains.value, 1)
        XCTAssertEqual(arbiter.snapshot().participants.first { $0.id == a.id }!.busySeconds, 0.033, accuracy: 1e-9)
        // A nested turn drains once, at the outer end.
        a.beginTurn(.decodeStep(rows: 1))
        a.beginTurn(.prefillChunk(tokens: 8))
        a.endTurn()
        XCTAssertEqual(drains.value, 1)
        a.endTurn()
        XCTAssertEqual(drains.value, 2)
    }

    /// Judge point 2: the chunk hint. Full size with one participant, under
    /// passthrough, or with an idle sibling; the floor before a rate is
    /// measured; then about `prefill_chunk_ms` of the measured rate.
    func testPrefillChunkHintFollowsTheMeasuredRateOnlyBesideAnActiveSibling() {
        let clock = ManualClock()
        let fullSize = 8192

        let lone = GPUTurnArbiter(policy: FairShareGPUTurnPolicy(), clock: { clock.now() })
        let only = lone.register(modelID: "only")
        only.beginWork()
        XCTAssertEqual(only.prefillChunkTokens(fullSize: fullSize), fullSize)

        let pass = GPUTurnArbiter(policy: PassthroughGPUTurnPolicy(), clock: { clock.now() })
        let p1 = pass.register(modelID: "p1")
        pass.register(modelID: "p2").beginWork()
        XCTAssertEqual(p1.prefillChunkTokens(fullSize: fullSize), fullSize)

        let arbiter = GPUTurnArbiter(
            policy: FairShareGPUTurnPolicy(prefillTargetMilliseconds: 150), clock: { clock.now() }, drainQueuedWork: { clock.advance(7_000_000) })
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        a.beginWork()
        XCTAssertEqual(a.prefillChunkTokens(fullSize: fullSize), fullSize, "idle sibling")
        b.beginWork()
        XCTAssertEqual(a.prefillChunkTokens(fullSize: fullSize), 256, "no rate yet: the floor")
        // One drained chunk: 512 tokens in 63 ms + 7 ms drain = 136,718.75 ns/token,
        // so 150 ms fits 1097 tokens, aligned down to 1088.
        b.endWork()
        a.withTurn(.prefillChunk(tokens: 512)) { clock.advance(63_000_000) }
        b.beginWork()
        XCTAssertEqual(a.prefillChunkTokens(fullSize: fullSize), 1088)
        XCTAssertEqual(a.prefillChunkTokens(fullSize: 600), 600, "never above the full size")
        b.endWork()
        XCTAssertEqual(a.prefillChunkTokens(fullSize: fullSize), fullSize, "sibling idle again")
        // prefill_chunk_ms=0 turns the hint off.
        arbiter.setPolicy(FairShareGPUTurnPolicy(prefillTargetMilliseconds: 0))
        b.beginWork()
        XCTAssertEqual(a.prefillChunkTokens(fullSize: fullSize), fullSize)
        // The default policy never shrinks chunks (the hint is off).
        arbiter.setPolicy(FairShareGPUTurnPolicy())
        XCTAssertEqual(a.prefillChunkTokens(fullSize: fullSize), fullSize)
        // Single participant left: the hint is the full size again.
        arbiter.unregister(b)
        XCTAssertEqual(a.prefillChunkTokens(fullSize: fullSize), fullSize)
    }

    /// A single participant under every registered policy: never waits, never
    /// drains, full chunks, even beside an unregistered handle.
    func testSingleParticipantIsPassthroughUnderEveryPolicy() throws {
        for name in GPUTurnPolicyRegistry.names {
            let drains = Counter()
            let arbiter = GPUTurnArbiter(policy: try GPUTurnPolicyRegistry.make(name), drainQueuedWork: { drains.increment() })
            let only = arbiter.register(modelID: "only")
            let scope = GPUTurnScope(only)
            scope.open()
            for _ in 0..<20 {
                XCTAssertEqual(scope.prefillChunkTokens(fullSize: 2048), 2048, name)
                XCTAssertTrue(scope.yield(.prefillChunk(tokens: 2048)), name)
                XCTAssertTrue(scope.yield(.decodeStep(rows: 1)), name)
            }
            scope.close()
            let stats = arbiter.snapshot().participants[0]
            XCTAssertEqual(stats.waitedTurns, 0, name)
            XCTAssertEqual(stats.stallOverrides, 0, name)
            XCTAssertEqual(drains.value, 0, name)
        }
    }

    /// Drains of two sharing scenarios under `policy`: A's turn while B is
    /// idle, then A's turn ending while B waits in `beginTurn` (B's own turn
    /// follows, with A idle).
    private func drainCounts(_ policy: any GPUTurnPolicy) -> (idle: Int, waiter: Int) {
        let drains = Counter()
        let arbiter = GPUTurnArbiter(policy: policy, drainQueuedWork: { drains.increment() })
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        a.withTurn(.decodeStep(rows: 1)) {}
        let idle = drains.value
        XCTAssertTrue(a.beginTurn(.decodeStep(rows: 1)))
        let bDone = onThread("B turn after A") { b.withTurn(.decodeStep(rows: 1)) {} }
        XCTAssertTrue(waitUntil { arbiter.stateForTest().participant(b.id)?.isWaiting == true })
        a.endTurn()
        wait(for: [bDone], timeout: 5)
        return (idle, drains.value - idle)
    }

    func testDrainModeAlwaysDrainsEveryLastHeldTurn() {
        let counts = drainCounts(AlternateGPUTurnPolicy())
        XCTAssertEqual(counts.idle, 1)
        XCTAssertEqual(counts.waiter, 2, "A's turn and B's turn")
        let timeslice = drainCounts(TimeSliceGPUTurnPolicy(drain: .always))
        XCTAssertEqual(timeslice.idle, 1)
    }

    func testDrainModeNeverDrains() {
        let counts = drainCounts(AlternateGPUTurnPolicy(drain: .never))
        XCTAssertEqual(counts.idle, 0)
        XCTAssertEqual(counts.waiter, 0)
    }

    /// `handoff` drains A's turn because B waits and is admitted once it ends;
    /// neither A's turn beside an idle B nor B's turn beside an idle A drains.
    func testDrainModeHandoffDrainsOnlyWhenTheTurnChangesHands() {
        let counts = drainCounts(AlternateGPUTurnPolicy(drain: .handoff))
        XCTAssertEqual(counts.idle, 0)
        XCTAssertEqual(counts.waiter, 1)
    }

    /// `handoff` under time slices: B waiting in A's slice does not take the
    /// GPU when A's turn ends, so that turn does not drain; at the slice
    /// boundary B runs.
    func testDrainModeHandoffSkipsAWaiterThePolicyKeepsWaiting() {
        let clock = ManualClock()
        let drains = Counter()
        let arbiter = GPUTurnArbiter(
            policy: TimeSliceGPUTurnPolicy(quantumMilliseconds: 100, drain: .handoff),
            clock: { clock.now() }, drainQueuedWork: { drains.increment() })
        let a = arbiter.register(modelID: "a")
        let b = arbiter.register(modelID: "b")
        a.beginWork()
        // Clock 1000 ns: slice 0 belongs to A (lowest id).
        XCTAssertTrue(a.beginTurn(.decodeStep(rows: 1)))
        let bDone = onThread("B waits for its slice") { b.withTurn(.decodeStep(rows: 1)) {} }
        XCTAssertTrue(waitUntil { arbiter.stateForTest().participant(b.id)?.isWaiting == true })
        a.endTurn()
        XCTAssertEqual(drains.value, 0, "B is still kept waiting in A's slice")
        XCTAssertEqual(arbiter.stateForTest().participant(b.id)?.isWaiting, true)
        clock.advance(100_000_000)
        wait(for: [bDone], timeout: 5)
        a.endWork()
        XCTAssertEqual(drains.value, 0, "A was not waiting when B's turn ended")
    }

    func testDrainParameterParsesForTimeSliceAndAlternate() throws {
        let timeslice = try GPUTurnPolicyRegistry.make("timeslice:drain=handoff")
        XCTAssertEqual(timeslice.drain, .handoff)
        XCTAssertEqual(timeslice.parameters, ["quantum_ms": "100", "stall_ms": "10000", "drain": "handoff"])
        let alternate = try GPUTurnPolicyRegistry.make("alternate:drain=never")
        XCTAssertEqual(alternate.drain, .never)
        XCTAssertEqual(alternate.parameters["drain"], "never")
        XCTAssertEqual(try GPUTurnPolicyRegistry.make("alternate:drain=always").drain, .always)
        for name in GPUTurnPolicyRegistry.names {
            let policy = try GPUTurnPolicyRegistry.make(name)
            XCTAssertEqual(policy.drain, .always, name)
            XCTAssertNil(policy.parameters["drain"], "the default is not recorded: \(name)")
        }
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("timeslice:drain=sometimes")) { error in
            XCTAssertEqual(error as? GPUTurnPolicyError, .invalidParameter(policy: "timeslice", name: "drain", value: "sometimes"))
        }
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("alternate:drain=")) { error in
            XCTAssertEqual(error as? GPUTurnPolicyError, .invalidParameter(policy: "alternate", name: "drain", value: ""))
        }
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("fairshare:drain=never"))
        XCTAssertThrowsError(try GPUTurnPolicyRegistry.make("passthrough:drain=never"))
    }

    func testDrainSpecRoundTripsThroughTheRegistry() throws {
        for spec in ["timeslice:quantum_ms=40,drain=handoff", "alternate:burst=2,drain=never", "timeslice", "alternate:drain=always"] {
            let policy = try GPUTurnPolicyRegistry.make(spec)
            let label = MultiModelCheckPolicyRun.label(policy)
            let again = try GPUTurnPolicyRegistry.make(label)
            XCTAssertEqual(again.name, policy.name, spec)
            XCTAssertEqual(again.drain, policy.drain, spec)
            XCTAssertEqual(again.parameters, policy.parameters, spec)
        }
        XCTAssertEqual(
            MultiModelCheckPolicyRun.label(try GPUTurnPolicyRegistry.make("timeslice:drain=handoff")),
            "timeslice:drain=handoff,quantum_ms=100,stall_ms=10000")
    }
}

private final class TurnTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var began: Date?
    private var ended: Date?
    func set(aBegan date: Date) { lock.lock(); began = date; lock.unlock() }
    func set(bEnded date: Date) { lock.lock(); ended = date; lock.unlock() }
    var aBegan: Date? { lock.lock(); defer { lock.unlock() }; return began }
    var bEnded: Date? { lock.lock(); defer { lock.unlock() }; return ended }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ value: Bool) { lock.lock(); stored = value; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
