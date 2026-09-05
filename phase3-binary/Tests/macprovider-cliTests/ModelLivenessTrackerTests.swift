import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-025 §5.2 (capability `model_liveness_token_v1`).
final class ModelLivenessTrackerTests: XCTestCase {
    /// Mutable monotonic clock so age assertions are deterministic.
    private final class FakeClock: @unchecked Sendable { var ns: UInt64 = 1_000_000_000 }

    private func makeTracker(_ clock: FakeClock) -> ModelLivenessTracker {
        ModelLivenessTracker(
            monotonicNs: { clock.ns },
            wallClock: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func ms(_ n: UInt64) -> UInt64 { n * 1_000_000 }

    func testFreshTrackerHasNoProgress() {
        let t = makeTracker(FakeClock())
        let s = t.snapshot()
        XCTAssertEqual(s.token, 0)
        XCTAssertNil(s.tokenAgeMs)
        XCTAssertFalse(s.activeInference)
        XCTAssertNil(s.activeInferenceAgeMs)
        XCTAssertNil(s.lastAdvancedAt)
    }

    func testRecordProgressAdvancesTokenAndAge() {
        let clock = FakeClock()
        let t = makeTracker(clock)
        t.recordProgress()
        clock.ns += ms(50)
        let s = t.snapshot()
        XCTAssertEqual(s.token, 1)
        XCTAssertEqual(s.tokenAgeMs, 50)
        XCTAssertNotNil(s.lastAdvancedAt)
    }

    func testTokenIsMonotoneAcrossProgress() {
        let t = makeTracker(FakeClock())
        t.recordProgress(); t.recordProgress(); t.recordProgress()
        XCTAssertEqual(t.snapshot().token, 3)
    }

    func testActiveInferenceLifecycleAndAge() {
        let clock = FakeClock()
        let t = makeTracker(clock)
        t.beginInference()
        XCTAssertTrue(t.snapshot().activeInference)
        clock.ns += ms(30)
        XCTAssertEqual(t.snapshot().activeInferenceAgeMs, 30)
        t.endInference()
        let s = t.snapshot()
        XCTAssertFalse(s.activeInference)
        XCTAssertNil(s.activeInferenceAgeMs)
    }

    func testProgressResetsActiveAgeButNotToken() {
        let clock = FakeClock()
        let t = makeTracker(clock)
        t.beginInference()
        clock.ns += ms(20)
        t.recordProgress()             // advances token, resets active-without-progress clock
        clock.ns += ms(10)
        let s = t.snapshot()
        XCTAssertEqual(s.token, 1)
        XCTAssertEqual(s.activeInferenceAgeMs, 10)  // since last progress, not since begin
        XCTAssertEqual(s.tokenAgeMs, 10)
    }

    func testAgeClampsToZeroIfClockMovesBackward() {
        // The clock is sampled under the lock (no real backward motion), but the
        // age math must still clamp rather than wrap to a huge UInt64 if a stored
        // timestamp is ever ahead of `now`.
        let clock = FakeClock()
        let t = makeTracker(clock)
        clock.ns = ms(1_000)
        t.recordProgress()          // lastAdvance recorded at 1000ms
        clock.ns = ms(400)          // clock moves backward
        let s = t.snapshot()
        XCTAssertEqual(s.tokenAgeMs, 0, "age must clamp to 0, never wrap")
    }

    func testNestedInferenceStaysActiveUntilZero() {
        let t = makeTracker(FakeClock())
        t.beginInference()
        t.beginInference()
        t.endInference()
        XCTAssertTrue(t.snapshot().activeInference, "still active while one inference remains")
        t.endInference()
        XCTAssertFalse(t.snapshot().activeInference)
    }

    func testIdleProviderTokenAgeGrowsButActiveIsFalse() {
        // A healthy idle provider: a token advanced once, then no work. token_age_ms
        // grows, but active_inference is false so it must not read as a wedge.
        let clock = FakeClock()
        let t = makeTracker(clock)
        t.recordProgress()
        clock.ns += ms(5_000)
        let s = t.snapshot()
        XCTAssertFalse(s.activeInference)
        XCTAssertNil(s.activeInferenceAgeMs)
        XCTAssertEqual(s.tokenAgeMs, 5_000)
    }
}
