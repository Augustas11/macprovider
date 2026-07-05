import XCTest
@testable import Malibu

/// Pins the wall-clock budget the App gives `macprovider-cli autotune
/// --recommend --json` on fresh-install onboarding.
///
/// The CLI's Stage-1 prober (`Stage1Iterator.swift:379`) runs
/// benchmarks against 2-3 candidate models. Each candidate can take
/// up to `readyTimeoutSec (120s) + probeIdleTimeoutSec (300s)` in the
/// worst case, per SPEC-023 v1.7.5. Compounded across candidates this
/// is a real ~10-15 min worst-case wall-clock cost — driven by MLX
/// model loading and prefill latency, not a bug in the CLI.
///
/// The App-side timeout MUST NOT be shorter than the CLI's own combined
/// budget or `AutotuneRecommendationError.timedOut` will fire and every
/// fresh-install onboarding will fail at `.autotuning` (which is what
/// happened on 2026-07-05 v1.8.3 smoke — `processTimeout = 30` killed
/// autotune ~4 minutes before completion).
final class AutotuneRecommendationRunnerTimeoutTests: XCTestCase {
    /// The CLI's own worst-case per-candidate wall-clock ceiling
    /// (readyTimeout 120s + probeIdle 300s). See
    /// `Stage1Prober.defaultProbeIdleTimeoutSec` and
    /// `Stage1Prober.init(readyTimeoutSec: TimeInterval = 120, ...)`
    /// in `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`.
    private static let cliPerCandidateWorstCaseSec: TimeInterval = 420

    /// Realistic minimum candidate count autotune probes on a
    /// fresh install. SPEC-023 selects 2-3 candidates; 2 is the
    /// floor.
    private static let minCandidateCount: Int = 2

    func testProcessTimeoutIsAtLeastRealisticCLIBudget() {
        // The App-side budget MUST cover at least the CLI's
        // worst-case time for the minimum number of candidates,
        // OR the fresh-install path fires .timedOut before the
        // CLI can converge on a recommendation.
        let requiredMinimum =
            Self.cliPerCandidateWorstCaseSec * TimeInterval(Self.minCandidateCount)
        XCTAssertGreaterThanOrEqual(
            AutotuneRecommendationRunner.processTimeout,
            requiredMinimum,
            """
            processTimeout=\(AutotuneRecommendationRunner.processTimeout)s \
            is below the CLI's own worst-case autotune budget of \
            \(requiredMinimum)s (\(Self.minCandidateCount) candidates × \
            \(Self.cliPerCandidateWorstCaseSec)s). Fresh-install onboarding \
            will fail at .autotuning. Raise the constant or reduce the \
            CLI's per-candidate budget in Stage1Iterator.swift.
            """
        )
    }

    func testProcessTimeoutHasHeadroomForThreeCandidates() {
        // SPEC-023 sometimes selects up to 3 candidates. The
        // budget should cover that WITH a small safety margin so
        // that a single slow candidate doesn't tip the entire
        // onboarding into .timedOut.
        let threeCandidateWorstCase =
            Self.cliPerCandidateWorstCaseSec * 3
        XCTAssertGreaterThanOrEqual(
            AutotuneRecommendationRunner.processTimeout,
            threeCandidateWorstCase,
            """
            processTimeout=\(AutotuneRecommendationRunner.processTimeout)s \
            lacks headroom for the 3-candidate case worst case of \
            \(threeCandidateWorstCase)s.
            """
        )
    }

    func testProcessTimeoutIsNotUnbounded() {
        // Belt-and-suspenders: if a subprocess wedges indefinitely
        // (kernel bug, mlx-swift deadlock, disk I/O storm), the
        // user shouldn't stare at a spinner forever. Cap at
        // 60 minutes so `.failed(autotuning, retryable: true, ...)`
        // eventually surfaces and the user can retry.
        XCTAssertLessThanOrEqual(
            AutotuneRecommendationRunner.processTimeout,
            60 * 60,
            "processTimeout must not exceed 60 min or wedged subprocesses hang the UI indefinitely."
        )
    }
}
