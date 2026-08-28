import XCTest
@testable import malibu_cli

/// SPEC-020-R005 accepted-but-stuck session recovery counter coverage,
/// AC-V0.1-R005-1 through AC-V0.1-R005-4.
final class AcceptedSessionRecoveryTrackerTests: XCTestCase {
    private let identityA = "1.9.0|<none>"
    private let identityB = "1.9.0|set-42"
    private let identityC = "1.9.1|<none>"

    private func increments(_ events: [AcceptedSessionRecoveryTracker.Event]) -> [AcceptedSessionRecoveryTracker.IncrementReason] {
        events.compactMap { if case let .increment(reason, _) = $0 { return reason } else { return nil } }
    }

    private func resets(_ events: [AcceptedSessionRecoveryTracker.Event]) -> [AcceptedSessionRecoveryTracker.ResetReason] {
        events.compactMap { if case let .reset(reason, _) = $0 { return reason } else { return nil } }
    }

    private func becameEligible(_ events: [AcceptedSessionRecoveryTracker.Event]) -> Bool {
        events.contains { if case .eligible = $0 { return true } else { return false } }
    }

    // AC-V0.1-R005-1: threshold counting, not transience. N-1 consecutive
    // missing-target outcomes must NOT arm recovery; the Nth must.
    func testMissingTargetArmsOnlyAtThreshold() {
        var tracker = AcceptedSessionRecoveryTracker(failureThreshold: 3)

        let t1 = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertEqual(t1.count, 1)
        XCTAssertFalse(t1.eligible)
        XCTAssertEqual(increments(t1.events), [.missingTarget])
        XCTAssertFalse(becameEligible(t1.events))

        let t2 = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertEqual(t2.count, 2)
        XCTAssertFalse(t2.eligible)
        XCTAssertFalse(becameEligible(t2.events))

        let t3 = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertEqual(t3.count, 3)
        XCTAssertTrue(t3.eligible)
        XCTAssertTrue(becameEligible(t3.events))
        // The becoming-eligible event names the threshold.
        XCTAssertTrue(t3.events.contains(.eligible(count: 3, threshold: 3)))
    }

    // AC-V0.1-R005-1 (mixed): recorded failures and cooldowns fold into the SAME
    // counter as missing-target observations.
    func testRecordedFailureAndCooldownShareTheCounter() {
        var tracker = AcceptedSessionRecoveryTracker(failureThreshold: 3)
        _ = tracker.register(outcome: .missingTarget, identity: identityA)
        _ = tracker.register(outcome: .forwardProgressFailure, identity: identityA)
        let t3 = tracker.register(outcome: .cooldownActive, identity: identityA)
        XCTAssertEqual(t3.count, 3)
        XCTAssertTrue(t3.eligible)
        XCTAssertTrue(becameEligible(t3.events))
    }

    // AC-V0.1-R005-2: target-missing is stuck only when persistent. A single
    // missing-target observation followed by a valid target (rollout transient)
    // resets the counter and grants no eligibility.
    func testSingleMissingTargetThenValidTargetResetsWithoutEligibility() {
        var tracker = AcceptedSessionRecoveryTracker(failureThreshold: 3)

        let t1 = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertEqual(t1.count, 1)
        XCTAssertFalse(t1.eligible)

        // A valid installable target now makes forward progress: reset, no arm.
        let t2 = tracker.register(outcome: .forwardProgress, identity: identityA)
        XCTAssertEqual(t2.count, 0)
        XCTAssertFalse(t2.eligible)
        XCTAssertEqual(resets(t2.events), [.forwardProgress])
        XCTAssertFalse(becameEligible(t2.events))

        // And it stays unarmed on the next missing-target: the run restarts at 1.
        let t3 = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertEqual(t3.count, 1)
        XCTAssertFalse(t3.eligible)
    }

    // AC-V0.1-R005-2 variant: the "valid target" arrives as a changed identity
    // (a compatibility-set id is now present), which also resets the counter.
    func testMissingTargetThenIdentityGainsCompatSetResets() {
        var tracker = AcceptedSessionRecoveryTracker(failureThreshold: 3)
        let t1 = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertEqual(t1.count, 1)

        let t2 = tracker.register(outcome: .forwardProgress, identity: identityB)
        XCTAssertEqual(t2.count, 0)
        XCTAssertFalse(t2.eligible)
        // Identity change resets before the outcome is applied.
        XCTAssertEqual(resets(t2.events), [.identityChanged])
    }

    // AC-V0.1-R005-3: primary-rail precedence and reset. Forward progress mid-run
    // resets, and the run must re-accumulate from scratch to re-arm.
    func testForwardProgressMidRunResetsAndRequiresFullReaccumulation() {
        var tracker = AcceptedSessionRecoveryTracker(failureThreshold: 3)
        _ = tracker.register(outcome: .missingTarget, identity: identityA)
        _ = tracker.register(outcome: .forwardProgressFailure, identity: identityA)
        let reset = tracker.register(outcome: .forwardProgress, identity: identityA)
        XCTAssertEqual(reset.count, 0)
        XCTAssertEqual(resets(reset.events), [.forwardProgress])

        // Two more failures are not enough after the reset.
        _ = tracker.register(outcome: .missingTarget, identity: identityA)
        let two = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertEqual(two.count, 2)
        XCTAssertFalse(two.eligible)
        let three = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertTrue(three.eligible)
        XCTAssertTrue(becameEligible(three.events))
    }

    // AC-V0.1-R005-3: recommendation identity change resets the counter.
    func testIdentityChangeResetsCounter() {
        var tracker = AcceptedSessionRecoveryTracker(failureThreshold: 3)
        _ = tracker.register(outcome: .missingTarget, identity: identityA)
        let two = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertEqual(two.count, 2)

        // The coordinator advertises a different recommended version: reset.
        let changed = tracker.register(outcome: .missingTarget, identity: identityC)
        XCTAssertEqual(changed.count, 1)
        XCTAssertFalse(changed.eligible)
        XCTAssertEqual(resets(changed.events), [.identityChanged])
        XCTAssertEqual(increments(changed.events), [.missingTarget])
    }

    // notAttempted outcomes (trust-skip, disabled, target-not-newer, revoked) must
    // leave the counter unchanged and emit no events.
    func testNotAttemptedLeavesCounterUnchanged() {
        var tracker = AcceptedSessionRecoveryTracker(failureThreshold: 3)
        let t1 = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertEqual(t1.count, 1)

        let noop = tracker.register(outcome: .notAttempted, identity: identityA)
        XCTAssertEqual(noop.count, 1)
        XCTAssertFalse(noop.eligible)
        XCTAssertTrue(noop.events.isEmpty)
    }

    // The becoming-eligible event fires exactly once on the transition, not again
    // while the count stays at or above threshold.
    func testEligibleEventEmittedOnceOnTransition() {
        var tracker = AcceptedSessionRecoveryTracker(failureThreshold: 2)
        _ = tracker.register(outcome: .missingTarget, identity: identityA)
        let arm = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertTrue(becameEligible(arm.events))

        let stillStuck = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertEqual(stillStuck.count, 3)
        XCTAssertTrue(stillStuck.eligible)
        // No second eligible event: already eligible before this call.
        XCTAssertFalse(becameEligible(stillStuck.events))
        XCTAssertEqual(increments(stillStuck.events), [.missingTarget])
    }

    // Reset events carry the post-reset count (0); increment events carry the
    // incremented count. Confirms the emitted counts are exact per R-6.8.
    func testEventCountsAreExact() {
        var tracker = AcceptedSessionRecoveryTracker(failureThreshold: 3)
        let inc = tracker.register(outcome: .forwardProgressFailure, identity: identityA)
        XCTAssertEqual(inc.events, [.increment(reason: .recordedFailure, count: 1)])

        let reset = tracker.register(outcome: .forwardProgress, identity: identityA)
        XCTAssertEqual(reset.events, [.reset(reason: .forwardProgress, count: 0)])
    }

    // LOW regression: with failureThreshold == 1, a NEW identity that arms within
    // the same register call (identity-change reset then increment) MUST still emit
    // a becoming-eligible event. Prior-eligibility is measured after the reset.
    func testThresholdOneNewIdentityStillEmitsEligible() {
        var tracker = AcceptedSessionRecoveryTracker(failureThreshold: 1)
        let first = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertTrue(first.eligible)
        XCTAssertTrue(becameEligible(first.events))

        // Different identity: reset (was eligible on A) then increment on B, which
        // re-arms in the same call. The eligible event must fire again for B.
        let second = tracker.register(outcome: .missingTarget, identity: identityC)
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second.eligible)
        XCTAssertEqual(resets(second.events), [.identityChanged])
        XCTAssertTrue(becameEligible(second.events))
    }

    // The default threshold is 3 per the SPEC.
    func testDefaultThresholdIsThree() {
        XCTAssertEqual(AcceptedSessionRecoveryTracker.defaultFailureThreshold, 3)
        var tracker = AcceptedSessionRecoveryTracker()
        _ = tracker.register(outcome: .missingTarget, identity: identityA)
        _ = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertFalse(tracker.isEligible)
        _ = tracker.register(outcome: .missingTarget, identity: identityA)
        XCTAssertTrue(tracker.isEligible)
    }
}
