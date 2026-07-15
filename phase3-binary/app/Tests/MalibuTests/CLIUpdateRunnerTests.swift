import Foundation
import XCTest
@testable import Malibu

final class CLIUpdateRunnerTests: XCTestCase {
    func testLegacyCLIUsesPinnedCompleteInstaller() throws {
        XCTAssertEqual(
            try CLIUpdateRunner.strategy(
                installedVersion: "1.8.30",
                compatibilitySetID: nil,
                bundledAppVersion: "1.8.39"
            ),
            .pinnedInstaller(version: "v1.8.39")
        )
        XCTAssertEqual(
            try CLIUpdateRunner.strategy(
                installedVersion: "v1.8.32",
                compatibilitySetID: "legacy-placeholder",
                bundledAppVersion: "v1.8.39"
            ),
            .pinnedInstaller(version: "v1.8.39")
        )
    }

    func testCompatibilityAwareCLIKeepsInstalledUpdater() throws {
        XCTAssertEqual(
            try CLIUpdateRunner.strategy(
                installedVersion: "1.8.33",
                compatibilitySetID: "Augustas11/macprovider:v1.8.33@abc123",
                bundledAppVersion: "1.8.39"
            ),
            .installedCompatibilityCLI
        )
    }

    func testMissingCompatibilityIdentityRepairsThroughPinnedInstaller() throws {
        XCTAssertEqual(
            try CLIUpdateRunner.strategy(
                installedVersion: "1.8.38",
                compatibilitySetID: "  ",
                bundledAppVersion: "1.8.39"
            ),
            .pinnedInstaller(version: "v1.8.39")
        )
    }

    func testLegacyRepairRequiresExactBridgeAppVersion() throws {
        for appVersion in [nil, "1.8.38", "1.8.40", "not-a-version"] as [String?] {
            XCTAssertThrowsError(
                try CLIUpdateRunner.strategy(
                    installedVersion: "1.8.30",
                    compatibilitySetID: nil,
                    bundledAppVersion: appVersion
                )
            ) { error in
                guard case CLIUpdateRunner.Error.legacyBootstrapUnavailable = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testMalformedInstalledVersionFailsClosed() {
        XCTAssertThrowsError(
            try CLIUpdateRunner.strategy(
                installedVersion: "1.8.x",
                compatibilitySetID: nil,
                bundledAppVersion: "1.8.39"
            )
        ) { error in
            guard case CLIUpdateRunner.Error.invalidInstalledVersion = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testBridgeNeverDowngradesNewerDamagedCLI() {
        XCTAssertThrowsError(
            try CLIUpdateRunner.strategy(
                installedVersion: "1.8.40",
                compatibilitySetID: nil,
                bundledAppVersion: "1.8.39"
            )
        ) { error in
            guard case CLIUpdateRunner.Error.legacyBootstrapWouldDowngrade = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPinnedInstallerEnvironmentNormalizesReleaseTag() throws {
        let environment = try CLIInstallRunner.installerEnvironment(
            parentEnvironment: [:],
            installPort: 61919,
            pinnedVersion: "1.8.39"
        )
        XCTAssertEqual(environment["MACPROVIDER_VERSION"], "v1.8.39")
        XCTAssertEqual(environment["MACPROVIDER_NO_PROMPT"], "1")
        XCTAssertEqual(environment["MACPROVIDER_PORT"], "61919")
    }

    func testPinnedInstallerEnvironmentRejectsMalformedTag() {
        XCTAssertThrowsError(
            try CLIInstallRunner.installerEnvironment(
                parentEnvironment: [:],
                installPort: nil,
                pinnedVersion: "1.8.39-beta"
            )
        ) { error in
            guard case CLIInstallRunner.Error.invalidPinnedVersion = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPinnedInstallerEnvironmentDropsAmbientAuthorityAndSecrets() throws {
        let hostile = [
            "GH_TOKEN": "secret",
            "MACPROVIDER_PROVIDER_TOKEN": "provider-secret",
            "MACPROVIDER_GITHUB_REPO": "attacker/repository",
            "MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM": "/tmp/attacker.pem",
            "MACPROVIDER_ACCEPTANCE_ASSET_DIR": "/tmp/candidate",
            "MACPROVIDER_ACCEPTANCE_COMMIT": String(repeating: "a", count: 40),
            "MACPROVIDER_EMERGENCY_ROLLBACK": "1",
            "MACPROVIDER_INSTALL_DIR": "/tmp/partial-install",
            "MACPROVIDER_NO_LAUNCHD": "1",
            "BASH_ENV": "/tmp/injected.sh",
            "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
            "PATH": "/tmp/attacker-bin",
            "HOME": "/tmp/attacker-home",
        ]
        let environment = try CLIInstallRunner.installerEnvironment(
            parentEnvironment: hostile,
            installPort: 61919,
            pinnedVersion: "v1.8.39"
        )

        XCTAssertEqual(
            Set(environment.keys),
            Set([
                "PATH", "HOME", "TMPDIR", "LC_ALL", "MACPROVIDER_NO_PROMPT",
                "MACPROVIDER_PORT", "MACPROVIDER_VERSION",
            ])
        )
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["HOME"], NSHomeDirectory())
        XCTAssertEqual(environment["TMPDIR"], "/tmp")
        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(environment["MACPROVIDER_VERSION"], "v1.8.39")
    }

    func testInstalledUpdaterEnvironmentDropsAmbientAuthorityAndSecrets() throws {
        let environment = try CLIUpdateRunner.updaterEnvironment(
            parentEnvironment: [
                "GH_TOKEN": "secret",
                "MACPROVIDER_GITHUB_REPO": "attacker/repository",
                "MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM": "/tmp/attacker.pem",
                "MACPROVIDER_VERSION": "v9.9.9",
                "BASH_ENV": "/tmp/injected.sh",
                "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
                "PATH": "/tmp/attacker-bin",
                "HOME": "/tmp/attacker-home",
            ]
        )

        XCTAssertEqual(Set(environment.keys), Set(["PATH", "HOME", "TMPDIR", "LC_ALL"]))
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["HOME"], NSHomeDirectory())
        XCTAssertEqual(environment["TMPDIR"], "/tmp")
        XCTAssertEqual(environment["LC_ALL"], "C")
    }

    func testSelectedLegacyStrategyInvokesOnlyPinnedInstallerAndReadiness() async throws {
        let recorder = CLIUpdateInvocationRecorder()
        try await CLIUpdateRunner.runStrategyForTest(
            strategy: .pinnedInstaller(version: "v1.8.39"),
            installedUpdate: { await recorder.recordInstalledUpdate() },
            pinnedInstall: { version in await recorder.recordPinnedInstall(version) },
            readinessCheck: {
                await recorder.recordReadiness()
                return true
            }
        )
        let result = await recorder.snapshot()
        XCTAssertEqual(result.installedUpdates, 0)
        XCTAssertEqual(result.pinnedVersions, ["v1.8.39"])
        XCTAssertEqual(result.readinessChecks, 1)
    }

    func testNonzeroRollbackMarkerIsExposedDistinctly() async throws {
        do {
            try await CLIUpdateRunner.runForTest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo rollback_restored >&2; exit 6"],
                onLogLine: { _ in },
                readinessCheck: { true }
            )
            XCTFail("rollback failure unexpectedly returned success")
        } catch let error as CLIUpdateRunner.Error {
            XCTAssertEqual(
                error.localizedDescription,
                "Provider update failed; the previous release was restored (rollback_restored, exit 6)."
            )
        }
    }

    func testZeroExitStillRequiresBuyerServingReadiness() async throws {
        do {
            try await CLIUpdateRunner.runForTest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 0"],
                onLogLine: { _ in },
                readinessCheck: { false }
            )
            XCTFail("unready provider update unexpectedly returned success")
        } catch let error as CLIUpdateRunner.Error {
            XCTAssertEqual(
                error.localizedDescription,
                "Provider update installed but did not reach buyer-serving readiness."
            )
        }
    }

    func testNonzeroRollbackFailureIsExposedDistinctly() async throws {
        do {
            try await CLIUpdateRunner.runForTest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo rollback_failed >&2; exit 7"],
                onLogLine: { _ in },
                readinessCheck: { true }
            )
            XCTFail("rollback failure unexpectedly returned success")
        } catch let error as CLIUpdateRunner.Error {
            XCTAssertEqual(
                error.localizedDescription,
                "Provider update and rollback both failed (rollback_failed, exit 7)."
            )
        }
    }

    func testReadinessSuccessCompletesUpdate() async throws {
        try await CLIUpdateRunner.runForTest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"],
            onLogLine: { _ in },
            readinessCheck: { true }
        )
    }
}

private actor CLIUpdateInvocationRecorder {
    private var installedUpdates = 0
    private var pinnedVersions: [String] = []
    private var readinessChecks = 0

    func recordInstalledUpdate() {
        installedUpdates += 1
    }

    func recordPinnedInstall(_ version: String) {
        pinnedVersions.append(version)
    }

    func recordReadiness() {
        readinessChecks += 1
    }

    func snapshot() -> (installedUpdates: Int, pinnedVersions: [String], readinessChecks: Int) {
        (installedUpdates, pinnedVersions, readinessChecks)
    }
}
