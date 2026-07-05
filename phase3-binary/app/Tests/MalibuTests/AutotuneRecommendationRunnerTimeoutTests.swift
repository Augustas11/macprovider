import XCTest
@testable import Malibu

/// Pins the wall-clock budget the App gives `macprovider-cli autotune
/// --recommend --json` on fresh-install onboarding.
///
/// **Design decision (R2)**: the App-side timeout is NOT derived from
/// per-candidate math because the recommend path iterates every
/// non-blocked RAM-eligible catalog row and that count scales with the
/// user's Mac tier. Any per-candidate × N estimate under-counts on some
/// machine.
///
/// The only principled invariant is: the App-side timeout must be at
/// least as long as the CLI's OWN outer hard budget
/// (`AutotuneCommand.maxDuration` in `Stage1Iterator`'s enclosing
/// command). If the App fires first, the CLI never gets to enforce its
/// own timeout and every fresh-install onboarding fails at
/// `.autotuning` (which is what happened on 2026-07-05 v1.8.3 smoke —
/// `processTimeout = 30` killed autotune ~4 minutes before completion).
final class AutotuneRecommendationRunnerTimeoutTests: XCTestCase {
    /// The CLI's own outer hard budget from
    /// `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:47-48`
    /// (`@Option(help: "Hard wall-clock budget in seconds.") var maxDuration = 7200`).
    ///
    /// This constant lives in a different SwiftPM target so we can't
    /// import it. If the CLI's `maxDuration` changes, this constant
    /// must move with it and this test file's location is the reason
    /// the PR reviewer will catch it.
    private static let cliMaxDurationSec: TimeInterval = 7200

    /// Grace window we allow between the CLI's own deadline firing and
    /// the App-side deadline firing, so a healthy CLI has a chance to
    /// return a nonzero exit code before the App terminates it.
    private static let cliDeadlineGraceSec: TimeInterval = 60

    func testProcessTimeoutMirrorsCLIOuterBudgetPlusGrace() {
        // The App-side deadline MUST NOT fire before the CLI's own
        // hard budget. If it does, the CLI never gets to enforce
        // maxDuration and the App's SIGTERM race becomes the
        // authoritative timeout — which fires INSIDE any legitimate
        // per-candidate work window and produces `.timedOut` on
        // healthy fresh installs (see 2026-07-05 v1.8.3 smoke).
        let requiredMinimum = Self.cliMaxDurationSec + Self.cliDeadlineGraceSec
        XCTAssertGreaterThanOrEqual(
            AutotuneRecommendationRunner.processTimeout,
            requiredMinimum,
            """
            processTimeout=\(AutotuneRecommendationRunner.processTimeout)s \
            is below the CLI's own hard budget of \
            \(Self.cliMaxDurationSec)s + \(Self.cliDeadlineGraceSec)s grace = \
            \(requiredMinimum)s. The App-side deadline will fire before the \
            CLI can enforce its own maxDuration, killing autotune while it \
            is still doing legitimate work. If the CLI's maxDuration truly \
            changed, update cliMaxDurationSec in this file too.
            """
        )
    }

    func testProcessTimeoutIsNotUnbounded() {
        // Belt-and-suspenders: if the CLI's outer maxDuration is ever
        // raised past 2.5h without updating the App-side constant,
        // this catches the drift before the user is trapped in a
        // multi-hour spinner. 2.5h = CLI's current 2h + 30min slack.
        XCTAssertLessThanOrEqual(
            AutotuneRecommendationRunner.processTimeout,
            2.5 * 60 * 60,
            """
            processTimeout=\(AutotuneRecommendationRunner.processTimeout)s \
            exceeds 2.5h ceiling. Wedged subprocesses would trap the user \
            in a multi-hour spinner. If the CLI's maxDuration was raised, \
            reconsider whether the App should still mirror it directly or \
            introduce a heartbeat protocol instead.
            """
        )
    }
}
