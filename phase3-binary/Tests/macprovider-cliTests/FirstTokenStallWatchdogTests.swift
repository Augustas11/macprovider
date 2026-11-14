import Foundation
import XCTest
@testable import macprovider_cli

/// Issue #2364: first-token stall watchdog trip, recovery and backoff.
final class FirstTokenStallWatchdogTests: XCTestCase {
    private final class FakeClock: @unchecked Sendable { var seconds: Double = 1_000 }
    private final class Flag: @unchecked Sendable { var value = false }

    private let policy = FirstTokenStallPolicy()

    private func makeWatchdog(_ clock: FakeClock) -> FirstTokenStallWatchdog {
        FirstTokenStallWatchdog(policy: policy, clock: { clock.seconds })
    }

    private func isTrip(_ decision: FirstTokenStallWatchdog.Decision) -> Bool {
        if case .trip = decision { return true }
        return false
    }

    func testBoundUsesFloorForShortPromptsAndScalesWithPromptLength() {
        XCTAssertEqual(policy.boundSeconds(pendingPromptTokens: 0, prefillTokensPerSecond: 1_000), 60)
        // 128K tokens at a measured 1000 tok/s: 3 x 128 s of prefill over the floor.
        XCTAssertEqual(policy.boundSeconds(pendingPromptTokens: 128_000, prefillTokensPerSecond: 1_000), 60 + 384)
        // Capped however long the prompt.
        XCTAssertEqual(policy.boundSeconds(pendingPromptTokens: 1_000_000, prefillTokensPerSecond: 1_000), 600)
        // A wild rate measurement is clamped, so the bound never collapses to the floor for a long prompt.
        XCTAssertEqual(policy.boundSeconds(pendingPromptTokens: 200_000, prefillTokensPerSecond: 1e9), 60 + 30)
    }

    func testTripsWhenNoFirstTokenAndNoProgressPastTheBound() {
        let clock = FakeClock()
        let watchdog = makeWatchdog(clock)
        watchdog.register(id: "a", promptTokens: 100, firstTokenObserved: { false })
        XCTAssertEqual(watchdog.evaluate(progressToken: 0), .none)
        let bound = policy.boundSeconds(pendingPromptTokens: 100, prefillTokensPerSecond: policy.defaultPrefillTokensPerSecond)
        clock.seconds += bound - 1
        XCTAssertEqual(watchdog.evaluate(progressToken: 0), .none)
        clock.seconds += 2
        guard case .trip(let trip) = watchdog.evaluate(progressToken: 0) else {
            return XCTFail("expected a trip")
        }
        XCTAssertEqual(trip.pendingRequests, 1)
        XCTAssertEqual(trip.pendingPromptTokens, 100)
        XCTAssertEqual(trip.backoffSeconds, policy.initialBackoffSeconds)
        XCTAssertEqual(watchdog.currentPhase, .tripped)
    }

    func testNeverTripsOnARequestWhoseFirstTokenArrived() {
        let clock = FakeClock()
        let watchdog = makeWatchdog(clock)
        let first = Flag()
        watchdog.register(id: "a", promptTokens: 100, firstTokenObserved: { first.value })
        clock.seconds += 10
        first.value = true
        clock.seconds += 10_000
        XCTAssertEqual(watchdog.evaluate(progressToken: 0), .none)
        XCTAssertEqual(watchdog.currentPhase, .healthy)
    }

    func testModelProgressFromOtherRowsRestartsTheStallClock() {
        let clock = FakeClock()
        let watchdog = makeWatchdog(clock)
        watchdog.register(id: "queued", promptTokens: 100, firstTokenObserved: { false })
        var token: UInt64 = 0
        // Another row decodes for ten minutes: the queued request never trips.
        for _ in 0..<300 {
            clock.seconds += 2
            token += 1
            XCTAssertFalse(isTrip(watchdog.evaluate(progressToken: token)))
        }
        // Progress stops: the bound counts from the last progress.
        clock.seconds += 70
        XCTAssertTrue(isTrip(watchdog.evaluate(progressToken: token)))
    }

    func testLongPromptGetsAPrefillSizedBound() {
        let clock = FakeClock()
        let watchdog = makeWatchdog(clock)
        // Measured prefill: 2048 uncached tokens in 2 s = 1024 tok/s.
        watchdog.recordPrefillSample(uncachedPromptTokens: 2_048, prefillSeconds: 2)
        XCTAssertEqual(watchdog.prefillTokensPerSecond, 1_024, accuracy: 0.001)
        watchdog.register(id: "long", promptTokens: 128_000, firstTokenObserved: { false })
        // A 128K prefill takes ~125 s at that rate; it must not trip at 300 s.
        clock.seconds += 300
        XCTAssertEqual(watchdog.evaluate(progressToken: 0), .none)
        clock.seconds += 200
        XCTAssertTrue(isTrip(watchdog.evaluate(progressToken: 0)))
    }

    func testSmallPrefillsAreNotRateSamples() {
        let watchdog = makeWatchdog(FakeClock())
        watchdog.recordPrefillSample(uncachedPromptTokens: 10, prefillSeconds: 0.001)
        watchdog.recordPrefillSample(uncachedPromptTokens: 4_096, prefillSeconds: 0)
        XCTAssertEqual(watchdog.prefillTokensPerSecond, policy.defaultPrefillTokensPerSecond)
    }

    func testIneligibleTimeDoesNotCount() {
        let clock = FakeClock()
        let watchdog = makeWatchdog(clock)
        watchdog.register(id: "a", promptTokens: 0, firstTokenObserved: { false })
        clock.seconds += 500
        watchdog.noteIneligible()
        clock.seconds += 30
        XCTAssertEqual(watchdog.evaluate(progressToken: 0), .none)
    }

    func testFinishedRequestsAreForgotten() {
        let clock = FakeClock()
        let watchdog = makeWatchdog(clock)
        watchdog.register(id: "a", promptTokens: 0, firstTokenObserved: { false })
        watchdog.finish(id: "a")
        clock.seconds += 10_000
        XCTAssertEqual(watchdog.evaluate(progressToken: 0), .none)
    }

    func testRecoveryOnlyAfterAProbeSucceedsWithBackoffBetweenProbes() {
        let clock = FakeClock()
        let watchdog = makeWatchdog(clock)
        watchdog.register(id: "a", promptTokens: 0, firstTokenObserved: { false })
        clock.seconds += 61
        XCTAssertTrue(isTrip(watchdog.evaluate(progressToken: 0)))

        // No probe before the backoff, even with progress elsewhere.
        clock.seconds += policy.initialBackoffSeconds - 1
        XCTAssertEqual(watchdog.evaluate(progressToken: 5), .none)
        XCTAssertEqual(watchdog.currentPhase, .tripped)
        clock.seconds += 1
        XCTAssertEqual(watchdog.evaluate(progressToken: 5), .probe(timeoutSeconds: policy.probeTimeoutSeconds))
        XCTAssertEqual(watchdog.currentPhase, .probing)
        // One probe at a time.
        XCTAssertEqual(watchdog.evaluate(progressToken: 5), .none)

        // A failed probe doubles the wait before the next one.
        XCTAssertEqual(watchdog.probeFinished(success: false), .stillStalled(nextProbeInSeconds: 2 * policy.initialBackoffSeconds))
        clock.seconds += 2 * policy.initialBackoffSeconds - 1
        XCTAssertEqual(watchdog.evaluate(progressToken: 5), .none)
        clock.seconds += 1
        XCTAssertEqual(watchdog.evaluate(progressToken: 5), .probe(timeoutSeconds: policy.probeTimeoutSeconds))

        clock.seconds += 3
        XCTAssertEqual(watchdog.probeFinished(success: true), .recovered(degradedSeconds: 3 * policy.initialBackoffSeconds + 3))
        XCTAssertEqual(watchdog.currentPhase, .healthy)
        XCTAssertEqual(watchdog.probeFinished(success: true), .ignored)

        // The still-waiting request gets a fresh bound from the recovery.
        clock.seconds += 59
        XCTAssertEqual(watchdog.evaluate(progressToken: 5), .none)
    }

    func testBackoffIsCappedAndEscalatesOnQuickRetrip() {
        let clock = FakeClock()
        let watchdog = makeWatchdog(clock)
        watchdog.register(id: "a", promptTokens: 0, firstTokenObserved: { false })
        var lastBackoff = 0.0
        for _ in 0..<8 {
            clock.seconds += 61
            guard case .trip(let trip) = watchdog.evaluate(progressToken: 0) else {
                return XCTFail("expected a trip")
            }
            XCTAssertGreaterThanOrEqual(trip.backoffSeconds, lastBackoff)
            XCTAssertLessThanOrEqual(trip.backoffSeconds, policy.maximumBackoffSeconds)
            lastBackoff = trip.backoffSeconds
            clock.seconds += trip.backoffSeconds
            XCTAssertEqual(watchdog.evaluate(progressToken: 0), .probe(timeoutSeconds: policy.probeTimeoutSeconds))
            _ = watchdog.probeFinished(success: true)
        }
        XCTAssertEqual(lastBackoff, policy.maximumBackoffSeconds)

        // A provider that stays healthy past the reset window starts over.
        clock.seconds += policy.stableResetSeconds + 1
        guard case .trip(let trip) = watchdog.evaluate(progressToken: 0) else {
            return XCTFail("expected a trip")
        }
        XCTAssertEqual(trip.backoffSeconds, policy.initialBackoffSeconds)
    }

    func testStallHoldReportsDegradedWithNoFreeSlotUntilCleared() async {
        let status = ProviderStatus(
            modelID: "m",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: 4_096, maxConcurrencyOverride: 2)
        )
        var snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.slotsFree, 2)
        let eligible = await status.isServingForFirstTokenStallWatch()
        XCTAssertTrue(eligible)

        await status.setFirstTokenStallHold(true)
        snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.status, .degraded)
        XCTAssertEqual(snapshot.slotsFree, 0)
        XCTAssertEqual(snapshot.transitionReason, "first_token_stall")
        // A coordinator warm_up's ready does not lift the hold.
        await status.setState(.ready, reason: "warm_up complete")
        snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.status, .degraded)

        await status.setFirstTokenStallHold(false)
        snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.slotsFree, 2)
    }
}
