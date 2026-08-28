import Foundation
import XCTest
@testable import malibu_cli

/// Round-1 audit A.1 + E.1 closure (Step 11 R1): the AC-6 tests below inject
/// `detectConflict` as a proxy mapping check (conflict enum → exit_reason).
/// They do NOT spawn real subprocesses or exercise `launchctl list` /
/// foreground argv detection. The actual detection-path coverage lives in
/// `ProviderConflictDetectorTests` from Step 5. The real-spawn AC-6 and
/// AC-7 integration variants are recorded as `XCTSkip` placeholders below
/// with a clear "v2 expansion" reason — Step 11's BUILD scope kept these as
/// documented deferrals rather than implementing a full subprocess harness.
final class AutotuneACIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["AUTOTUNE_INTEGRATION_TESTS"] == "1" else {
            print("Skipping SPEC-013 autotune integration ACs; set AUTOTUNE_INTEGRATION_TESTS=1 to enable them.")
            throw XCTSkip("Set AUTOTUNE_INTEGRATION_TESTS=1 to enable integration tests")
        }
        try super.setUpWithError()
    }

    /// AC-6 mapping: launchd-managed provider conflict refuses by default; SPEC-013 lines 1404-1424.
    ///
    /// This test asserts the MAPPING from a `launchdManaged` `ProviderConflict`
    /// enum to `exit_reason = 'provider_conflict'` + stderr message. It does
    /// NOT spawn a real launchd-managed `malibu-cli serve` process. See
    /// `testAC6RealSubprocessLaunchdDetection` below for the real-detection
    /// placeholder.
    func testAC6ProviderConflictMappingLaunchdManaged() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command()
        var deps = fixture.dependencies()
        deps.detectConflict = { .launchdManaged(pid: 123) }

        try await fixture.assertExit { try await command.run(dependencies: deps) }

        XCTAssertTrue(fixture.stderr.contains("launchd-managed pid 123"), fixture.stderr)
        XCTAssertTrue(fixture.stderr.contains("--drain"), fixture.stderr)
        XCTAssertEqual(try fixture.latestRunRow().exitReason, "provider_conflict")
    }

    /// AC-6 mapping: foreground provider conflict refuses by default; SPEC-013 lines 1404-1424.
    ///
    /// This test asserts the MAPPING from a `foreground` `ProviderConflict`
    /// enum to `exit_reason = 'provider_conflict'` + stderr message. It does
    /// NOT spawn a real foreground `malibu-cli serve` process. See
    /// `testAC6RealSubprocessForegroundDetection` below for the
    /// real-detection placeholder.
    func testAC6ProviderConflictMappingForeground() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command()
        var deps = fixture.dependencies()
        deps.detectConflict = { .foreground(pid: 456, argv: ["malibu-cli", "serve"]) }

        try await fixture.assertExit { try await command.run(dependencies: deps) }

        XCTAssertTrue(fixture.stderr.contains("foreground-PID-456"), fixture.stderr)
        XCTAssertTrue(fixture.stderr.contains("--drain"), fixture.stderr)
        XCTAssertEqual(try fixture.latestRunRow().exitReason, "provider_conflict")
    }

    /// AC-6 real detection: launchd-managed conflict via `launchctl bootstrap`
    /// of a test plist; SPEC-013 lines 1411-1417.
    ///
    /// v2 expansion: requires test plist setup + `launchctl bootstrap gui/$UID`,
    /// which mutates the operator's launchd session. Deferred from v1 BUILD
    /// scope. The unit-level detection logic is covered by
    /// `ProviderConflictDetectorTests`.
    func testAC6RealSubprocessLaunchdDetection() throws {
        throw XCTSkip("AC-6 real launchd detection is a v2 integration expansion; unit coverage in ProviderConflictDetectorTests.")
    }

    /// AC-6 real detection: foreground conflict via real `malibu-cli serve`
    /// subprocess spawn + argv-match detection; SPEC-013 lines 1418-1424.
    ///
    /// v2 expansion: requires building/locating the binary, spawning it on a
    /// free port, polling for ready, running autotune, asserting detection,
    /// and cleaning up the subprocess. Deferred from v1 BUILD scope. The
    /// unit-level argv-match detection is covered by
    /// `ProviderConflictDetectorTests` (including the argv-match-on-serve
    /// guard that ignores the autotune process itself).
    func testAC6RealSubprocessForegroundDetection() throws {
        throw XCTSkip("AC-6 real foreground detection is a v2 integration expansion; unit coverage in ProviderConflictDetectorTests.")
    }

    /// AC-7 real subprocess: `--no-join` set on every candidate spawn argv +
    /// coordinator pool unaffected; SPEC-013 lines 1426-1432.
    ///
    /// v2 expansion: requires building/locating the binary, spawning candidate
    /// serve processes with `--no-join`, observing coordinator
    /// `/admin/pool/check` (or equivalent) to confirm NO provider connection
    /// is registered during the autotune run. Deferred from v1 BUILD scope.
    /// The unit-level argv-construction guard is covered by
    /// `testAC7NoJoinIsSetOnEveryCandidate` in `AutotuneAC_Stage1Tests`.
    func testAC7RealSubprocessNoJoinPlusCoordinatorPoolUnaffected() throws {
        throw XCTSkip("AC-7 real-subprocess + coordinator-pool observation is a v2 integration expansion; unit coverage in AutotuneAC_Stage1Tests.")
    }
}
