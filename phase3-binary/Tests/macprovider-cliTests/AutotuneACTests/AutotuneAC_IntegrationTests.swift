import Foundation
import XCTest
@testable import macprovider_cli

final class AutotuneACIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["AUTOTUNE_INTEGRATION_TESTS"] == "1" else {
            print("Skipping SPEC-013 autotune integration ACs; set AUTOTUNE_INTEGRATION_TESTS=1 to enable them.")
            throw XCTSkip("Set AUTOTUNE_INTEGRATION_TESTS=1 to enable integration tests")
        }
        try super.setUpWithError()
    }

    /// AC-6: launchd-managed provider conflict refuses by default; SPEC-013 lines 1404-1424.
    func testAC6ProviderConflictPreFlightRefusesLaunchdByDefault() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command()
        var deps = fixture.dependencies()
        deps.detectConflict = { .launchdManaged(pid: 123) }

        try await fixture.assertExit { try await command.run(dependencies: deps) }

        XCTAssertTrue(fixture.stderr.contains("launchd-managed pid 123"), fixture.stderr)
        XCTAssertTrue(fixture.stderr.contains("--drain"), fixture.stderr)
        XCTAssertEqual(try fixture.latestRunRow().exitReason, "provider_conflict")
    }

    /// AC-6: foreground provider conflict refuses by default; SPEC-013 lines 1404-1424.
    func testAC6ProviderConflictPreFlightRefusesForegroundByDefault() async throws {
        let fixture = try AutotuneACTestFixture(testCase: self)
        let command = try fixture.command()
        var deps = fixture.dependencies()
        deps.detectConflict = { .foreground(pid: 456, argv: ["macprovider-cli", "serve"]) }

        try await fixture.assertExit { try await command.run(dependencies: deps) }

        XCTAssertTrue(fixture.stderr.contains("foreground-PID-456"), fixture.stderr)
        XCTAssertTrue(fixture.stderr.contains("--drain"), fixture.stderr)
        XCTAssertEqual(try fixture.latestRunRow().exitReason, "provider_conflict")
    }
}
