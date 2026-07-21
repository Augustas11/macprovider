import XCTest
@testable import Malibu

/// Pins the wall-clock budget the App gives `macprovider-cli autotune
/// --recommend --json` on fresh-install onboarding.
///
/// **Design decision (R3)**: this timeout is the App-side authoritative
/// ceiling for autotune runtime. The CLI's declared
/// `AutotuneCommand.maxDuration = 7200s` is NOT enforced on the
/// `--recommend` code path — `runAutotuneRecommend()` at
/// `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:131-139`
/// returns before the deadline is created at :157-161, and
/// `AutotuneRecommendationBenchmarker.benchmarks()` runs with no
/// deadline / cancellation input. So the App cannot rely on a
/// CLI-enforced upper bound firing first.
///
/// Given that, the App-side timeout is NOT derived from per-candidate
/// math (which under-counts on higher-tier Macs because `--recommend`
/// iterates every non-blocked RAM-eligible catalog row, count varies).
/// It IS bounded to a defensible range that survives realistic
/// worst-case candidate cardinality while remaining a UX-tolerable
/// ceiling.
///
/// The 2026-07-05 v1.8.3 smoke shows `processTimeout = 30` killed
/// autotune ~4 minutes before completion on this Mac. Any App-side
/// value shorter than realistic per-machine autotune runtime will
/// reproduce that failure on some tier.
final class AutotuneRecommendationRunnerTimeoutTests: XCTestCase {
    /// Realistic worst-case autotune runtime the App must budget for.
    /// Rationale: per-candidate strict worst case is 720s
    /// (`readyTimeoutSec = 120s` + prewarm `probeOnce = 300s` +
    /// measured `probeOnce = 300s` per SPEC-023 v1.7.5). Catalog
    /// cardinality after RAM/tier filtering scales with hardware; a
    /// 10-candidate ceiling covers current catalog size with headroom.
    /// 10 × 720s = 7200s. If either per-candidate math or catalog size
    /// changes materially, revisit this floor.
    private static let realisticWorstCaseAutotuneSec: TimeInterval = 7200

    /// Above this, the user is in a multi-hour spinner and has almost
    /// certainly quit the app. Beyond legitimate autotune runtime by
    /// any reasonable interpretation.
    private static let untenableSpinnerCeilingSec: TimeInterval = 2.5 * 60 * 60

    func testProcessTimeoutCoversRealisticWorstCaseAutotune() {
        // The App-side deadline MUST cover the realistic worst-case
        // autotune runtime for the highest-tier hardware in the wild,
        // because the CLI's --recommend path does NOT enforce its
        // own declared maxDuration and cannot fail-fast on its own.
        // If the App fires below this floor, healthy fresh installs
        // on beefier Macs get killed mid-benchmark — that is the
        // 2026-07-05 v1.8.3 smoke failure mode.
        XCTAssertGreaterThanOrEqual(
            AutotuneRecommendationRunner.processTimeout,
            Self.realisticWorstCaseAutotuneSec,
            """
            processTimeout=\(AutotuneRecommendationRunner.processTimeout)s \
            is below the realistic worst-case autotune runtime of \
            \(Self.realisticWorstCaseAutotuneSec)s (10 candidates × 720s \
            per candidate). Higher-tier Macs will hit .timedOut before \
            autotune converges. If per-candidate math or catalog size \
            has changed, update realisticWorstCaseAutotuneSec.
            """
        )
    }

    func testTerminateAutotuneSubtreeSIGTERMsCooperativeChild() throws {
        // ARCH-M-1 regression: the runner tears down cooperative CLI
        // subprocesses via `process.terminate()` (SIGTERM). A well-behaved
        // shell exits promptly. Confirm the helper returns within grace
        // and the process is gone.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30"]
        try process.run()
        // Give macOS a beat to actually start the child.
        Thread.sleep(forTimeInterval: 0.05)
        AutotuneRecommendationRunner.terminateAutotuneSubtree(
            process: process,
            graceSeconds: 2
        )
        XCTAssertFalse(process.isRunning)
    }

    func testTerminateAutotuneSubtreeSIGKILLEscalatesWhenChildIgnoresSIGTERM() throws {
        // ARCH-M-1 regression: if the CLI ignores SIGTERM (wedged handler,
        // pathological state), the runner must escalate to SIGKILL so
        // orphan grandchildren cannot outlive the timeout. Simulate this
        // with a shell that ignores SIGTERM and stays alive until SIGKILL.
        //
        // Do NOT use `sleep … & wait`: on some /bin/sh builds, an ignored
        // SIGTERM still interrupts `wait`, so the script exits before grace
        // and the wall-clock assertion flakes (CI saw ~0.06s elapsed).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' 15; while :; do sleep 1; done"]
        try process.run()
        Thread.sleep(forTimeInterval: 0.1)
        let before = Date()
        AutotuneRecommendationRunner.terminateAutotuneSubtree(
            process: process,
            graceSeconds: 0.5
        )
        let elapsed = Date().timeIntervalSince(before)
        XCTAssertFalse(process.isRunning)
        // Must have waited at least the grace window before escalating.
        XCTAssertGreaterThanOrEqual(elapsed, 0.4)
        // And must not have waited absurdly long (i.e. SIGKILL landed).
        XCTAssertLessThan(elapsed, 5.0)
    }

    func testSubtreeGraceSecondsIsPositive() {
        XCTAssertGreaterThan(AutotuneRecommendationRunner.subtreeGraceSeconds, 0)
    }

    func testHardwareAdmissionRecoveryUsesCLIOwnedTransactionFlag() {
        let config = URL(fileURLWithPath: "/tmp/macprovider-config.yaml")
        let args = AutotuneRecommendationRunner.hardwareAdmissionRecoveryArguments(configPath: config)
        XCTAssertTrue(args.contains("--recover-hardware-admission"))
        XCTAssertTrue(args.contains("--recommend"))
        XCTAssertFalse(args.contains("--apply"))
        XCTAssertFalse(args.contains("--freshness-check"))
    }

    func testProcessTimeoutIsNotUntenable() {
        // Belt-and-suspenders: if the constant is ever set to some
        // multi-hour value, the user is trapped in an indefinite
        // spinner because the CLI has no independent way to give up
        // (recommend path doesn't enforce maxDuration). Catch that
        // before it ships.
        XCTAssertLessThanOrEqual(
            AutotuneRecommendationRunner.processTimeout,
            Self.untenableSpinnerCeilingSec,
            """
            processTimeout=\(AutotuneRecommendationRunner.processTimeout)s \
            exceeds \(Self.untenableSpinnerCeilingSec)s (2.5h). The CLI \
            --recommend path does not enforce its own maxDuration, so \
            this ceiling IS the outer bound. Beyond 2.5h the user has \
            given up. Introduce a heartbeat / progress protocol rather \
            than raise this further.
            """
        )
    }
}
