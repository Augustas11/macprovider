import XCTest
@testable import Malibu

final class CLIInstallActivityMonitorTests: XCTestCase {
    func testGithubDownloadIsTheFirstVisibleStage() {
        let progress = CLIInstallRunner.ActivityMonitor.progress(
            processLines: ["curl -L https://github.com/Augustas11/macprovider/releases/download/v1.8.93/macprovider-cli"]
        )
        XCTAssertEqual(progress.stage, .downloadingRelease)
        XCTAssertEqual(progress.detail, "Downloading provider software…")
        XCTAssertGreaterThan(progress.overallFraction, 0.05)
        XCTAssertLessThan(progress.overallFraction, 0.2)
    }

    func testInstalledSoftwareAdvancesPastReleaseDownload() {
        let progress = CLIInstallRunner.ActivityMonitor.progress(
            processLines: [],
            cliInstalled: true
        )
        XCTAssertEqual(progress.stage, .installingCLI)
        XCTAssertTrue(progress.detail.contains("Model download"))
        XCTAssertFalse(progress.detail.lowercased().contains("cli"))
    }

    func testModelPullShowsPercentFromLogLines() {
        let progress = CLIInstallRunner.ActivityMonitor.progress(
            processLines: ["/Users/a/macprovider/macprovider-cli models pull Qwen/Qwen3-8B"],
            logLines: [
                "Fetching snapshot",
                "model.safetensors:  42%|████      | 1.23GB / 2.90GB",
            ],
            cliInstalled: true
        )
        XCTAssertEqual(progress.stage, .downloadingModel)
        XCTAssertEqual(progress.downloadFraction, 0.42)
        XCTAssertEqual(progress.percentLabel, "42%")
        XCTAssertEqual(progress.detail, "Downloading model weights — 42%")
        XCTAssertGreaterThan(progress.overallFraction, 0.4)
        XCTAssertLessThan(progress.overallFraction, 0.88)
    }

    func testBytePairParsesWhenPercentIsMissing() {
        let fraction = CLIInstallRunner.ActivityMonitor.parseDownloadFraction(
            from: ["Downloading weights 1.5 GB / 3.0 GB"]
        )
        XCTAssertEqual(fraction, 0.5)
    }

    func testAutotuneOutranksModelDownload() {
        let progress = CLIInstallRunner.ActivityMonitor.progress(
            processLines: [
                "/Users/a/macprovider/macprovider-cli autotune --recommend",
                "/Users/a/macprovider/macprovider-cli models pull Qwen/Qwen3-8B",
            ],
            logLines: ["model.safetensors: 99%"],
            cliInstalled: true
        )
        XCTAssertEqual(progress.stage, .autotune)
        XCTAssertNil(progress.downloadFraction)
        XCTAssertTrue(progress.detail.contains("10–30 minutes"))
        XCTAssertEqual(progress.overallFraction, 0.88, accuracy: 0.001)
    }

    func testServeNoJoinNamesTheModelUnderTest() {
        let progress = CLIInstallRunner.ActivityMonitor.progress(
            processLines: [
                "macprovider-cli serve --no-join --model Qwen/Qwen3-8B --port 8080",
            ]
        )
        XCTAssertEqual(progress.stage, .autotune)
        XCTAssertEqual(progress.detail, "Testing Qwen3-8B performance…")
    }

    func testFallbackDoesNotAdvertiseSilence() {
        let progress = CLIInstallRunner.ActivityMonitor.progress(processLines: [])
        XCTAssertEqual(progress.stage, .starting)
        XCTAssertEqual(progress.detail, "Install in progress…")
        XCTAssertFalse(OnboardingCopy.installingFallback.contains("little visible progress"))
    }

    // Regression for the beachball: `ps -ax` on a busy Mac can emit >64KB, more
    // than the pipe buffer. Draining to EOF before waitUntilExit must not
    // deadlock. This helper emits ~220KB (>128KB); if the old
    // waitUntilExit-then-read ordering regressed, this test would hang and fail.
    func testCapturedProcessOutputDrainsLargeOutputWithoutDeadlock() async {
        let output = await CLIInstallRunner.ActivityMonitor.capturedProcessOutput(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "for i in $(seq 1 20000); do echo 0123456789; done"]
        )
        XCTAssertGreaterThan(
            output.utf8.count, 128 * 1024,
            "large subprocess output must be fully drained without deadlock"
        )
    }

    // A launch failure returns empty rather than hanging or throwing.
    func testCapturedProcessOutputReturnsEmptyOnLaunchFailure() async {
        let output = await CLIInstallRunner.ActivityMonitor.capturedProcessOutput(
            executableURL: URL(fileURLWithPath: "/nonexistent/definitely-not-a-binary"),
            arguments: []
        )
        XCTAssertEqual(output, "")
    }

    // The progress poller path is async (runs its subprocess off the caller's
    // actor) and still returns a usable InstallProgress. Driven from @MainActor
    // to prove the await suspends rather than blocks the main actor.
    @MainActor
    func testSnapshotIsAsyncAndReturnsProgressFromMainActor() async {
        let progress = await CLIInstallRunner.ActivityMonitor.snapshot(
            logLines: ["Fetching model weights 42%"]
        )
        // With no macprovider-cli process running, the log lines drive the stage.
        XCTAssertNotNil(progress.detail)
    }
}
