import CryptoKit
import Foundation
import XCTest
@testable import Malibu

final class CLIUpdateRunnerTests: XCTestCase {
    func testLegacyCLIUsesPinnedCompleteInstaller() throws {
        XCTAssertEqual(
            try CLIUpdateRunner.strategy(
                installedVersion: "1.8.30",
                compatibilitySetID: nil,
                bundledAppVersion: "1.8.40"
            ),
            .pinnedInstaller(version: "v1.8.40")
        )
        XCTAssertEqual(
            try CLIUpdateRunner.strategy(
                installedVersion: "v1.8.32",
                compatibilitySetID: "legacy-placeholder",
                bundledAppVersion: "v1.8.40"
            ),
            .pinnedInstaller(version: "v1.8.40")
        )
    }

    func testCompatibilityAwareCLIKeepsInstalledUpdater() throws {
        XCTAssertEqual(
            try CLIUpdateRunner.strategy(
                installedVersion: "1.8.33",
                compatibilitySetID: "Augustas11/macprovider:v1.8.33@abc123",
                bundledAppVersion: "1.8.40"
            ),
            .installedCompatibilityCLI
        )
    }

    func testSupportedCLIIsAcceptedIndependentlyOfMalibuMarketingVersion() throws {
        XCTAssertEqual(
            try CLIUpdateRunner.strategy(
                installedVersion: "1.8.40",
                compatibilitySetID: "Augustas11/macprovider:v1.8.40@abc123",
                bundledAppVersion: "1.8.41"
            ),
            .installedCompatibilityCLI
        )
    }

    func testMissingCompatibilityIdentityRepairsThroughPinnedInstaller() throws {
        XCTAssertEqual(
            try CLIUpdateRunner.strategy(
                installedVersion: "1.8.38",
                compatibilitySetID: "  ",
                bundledAppVersion: "1.8.40"
            ),
            .pinnedInstaller(version: "v1.8.40")
        )
    }

    func testLegacyRepairRequiresExactBridgeAppVersion() throws {
        // Any bundle version other than the current pin target disarms the
        // bridge — including the previous release's target (1.8.39), which must
        // no longer arm 1.8.40's repair.
        for appVersion in [nil, "1.8.38", "1.8.39", "1.8.41", "not-a-version"] as [String?] {
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
                bundledAppVersion: "1.8.40"
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
                installedVersion: "1.8.41",
                compatibilitySetID: nil,
                bundledAppVersion: "1.8.40"
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
            pinnedVersion: "1.8.40"
        )
        XCTAssertEqual(environment["MACPROVIDER_VERSION"], "v1.8.40")
        XCTAssertEqual(environment["MACPROVIDER_NO_PROMPT"], "1")
        XCTAssertEqual(environment["MACPROVIDER_PORT"], "61919")
    }

    func testPinnedInstallerEnvironmentRejectsMalformedTag() {
        XCTAssertThrowsError(
            try CLIInstallRunner.installerEnvironment(
                parentEnvironment: [:],
                installPort: nil,
                pinnedVersion: "1.8.40-beta"
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
            pinnedVersion: "v1.8.40"
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
        XCTAssertEqual(environment["MACPROVIDER_VERSION"], "v1.8.40")
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
            strategy: .pinnedInstaller(version: "v1.8.40"),
            installedUpdate: { await recorder.recordInstalledUpdate() },
            pinnedInstall: { version in await recorder.recordPinnedInstall(version) },
            readinessCheck: {
                await recorder.recordReadiness()
                return true
            }
        )
        let result = await recorder.snapshot()
        XCTAssertEqual(result.installedUpdates, 0)
        XCTAssertEqual(result.pinnedVersions, ["v1.8.40"])
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
                "Provider update installed but did not become ready for customer work."
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

    func testRunHandoffInvokesRelaunchAfterInstalledCompatibilityUpdate() async throws {
        let manifestBytes = Data("signed compatibility set".utf8)
        let app = try makeTemporaryMalibuApp(
            version: "1.8.93",
            build: "930",
            embeddedCompatibilityManifestData: manifestBytes
        )
        let running = CLIUpdateRunner.RunningAppSnapshot(
            bundleURL: app,
            version: "1.8.92",
            build: "920"
        )
        let recorder = CLIUpdateRunRecorder()

        try await CLIUpdateRunner.runForTest(
            installedVersion: "1.8.33",
            compatibilitySetID: "Augustas11/macprovider:v1.8.33@abc123",
            bundledAppVersion: "1.8.92",
            runningApp: running,
            installedUpdate: { recorder.recordInstalledUpdate() },
            pinnedInstall: { version in recorder.recordPinnedInstall(version) },
            readinessCheck: {
                recorder.recordReadiness()
                return true
            },
            expectedAppIdentityAfterUpdate: { strategy, runningApp in
                recorder.recordExpectedProof(strategy: strategy, runningApp: runningApp)
                return .init(
                    version: "1.8.93",
                    compatibilitySetID: "Augustas11/macprovider:v1.8.93@0123456789abcdef0123456789abcdef01234567",
                    compatibilityManifestBytes: manifestBytes
                )
            },
            relaunchUpdatedApp: { plan in recorder.recordRelaunch(plan) },
            onLogLine: { line in recorder.recordLog(line) }
        )

        let result = recorder.snapshot()
        XCTAssertEqual(result.installedUpdates, 1)
        XCTAssertEqual(result.pinnedVersions, [])
        XCTAssertEqual(result.readinessChecks, 1)
        XCTAssertEqual(result.proofStrategies, [.installedCompatibilityCLI])
        XCTAssertEqual(result.proofSnapshots, [running])
        XCTAssertEqual(result.relaunchPlans, [
            .init(
                bundleURL: app,
                previousVersion: "1.8.92",
                previousBuild: "920",
                installedVersion: "1.8.93",
                installedBuild: "930",
                expectedVersion: "1.8.93"
            ),
        ])
        XCTAssertEqual(
            result.logLines,
            ["[Malibu] Malibu.app v1.8.93 build 930 installed; reopening the updated app."]
        )
    }

    func testRunHandoffRejectsStalePostUpdateManifestInsteadOfSilentNoop() async throws {
        let app = try makeTemporaryMalibuApp(version: "1.8.92", build: "920")
        let running = CLIUpdateRunner.RunningAppSnapshot(
            bundleURL: app,
            version: "1.8.92",
            build: "920"
        )

        do {
            try await CLIUpdateRunner.runForTest(
                installedVersion: "1.8.33",
                compatibilitySetID: "Augustas11/macprovider:v1.8.92@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                bundledAppVersion: "1.8.92",
                runningApp: running,
                installedUpdate: {},
                pinnedInstall: { _ in XCTFail("installed strategy should not call pinned installer") },
                readinessCheck: { true },
                expectedAppIdentityAfterUpdate: { _, _ in
                    .init(
                        version: "1.8.92",
                        compatibilitySetID: "Augustas11/macprovider:v1.8.92@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    )
                },
                relaunchUpdatedApp: { _ in XCTFail("stale manifest must not relaunch or silently succeed") },
                onLogLine: { _ in }
            )
            XCTFail("stale post-update manifest unexpectedly returned success")
        } catch let error as CLIUpdateRunner.Error {
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but Malibu.app update proof could not be verified. Reopen Malibu from Applications and run Update again."
            )
        }
    }

    @MainActor
    func testAgentUpdateCLINowInvokesUpdateRunnerFromPublicAction() async throws {
        var snapshot = AgentSnapshot.empty
        snapshot.cliVersion = "1.8.92"
        snapshot.latestReleaseVersion = "1.8.93"
        snapshot.compatibilitySetID = "Augustas11/macprovider:v1.8.92@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let recorder = CLIUpdateAgentRecorder()
        let agent = MalibuAgent(
            initialSnapshot: snapshot,
            cliUpdateRunner: { installedVersion, compatibilitySetID, onLogLine in
                recorder.recordInvocation(
                    installedVersion: installedVersion,
                    compatibilitySetID: compatibilitySetID
                )
                await onLogLine("provider update started")
            }
        )

        await agent.updateCLINow()

        XCTAssertEqual(recorder.snapshot(), [
            .init(
                installedVersion: "1.8.92",
                compatibilitySetID: "Augustas11/macprovider:v1.8.92@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            ),
        ])
        XCTAssertEqual(agent.logLines, ["provider update started"])
        XCTAssertFalse(agent.snapshot.cliUpdateInProgress)
        XCTAssertNil(agent.snapshot.cliUpdateLastError)
    }

    func testExpectedManifestAppVersionMismatchFailsInsteadOfSilentNoop() throws {
        let app = try makeTemporaryMalibuApp(version: "1.8.92", build: "92")
        let running = CLIUpdateRunner.RunningAppSnapshot(
            bundleURL: app,
            version: "1.8.92",
            build: "92"
        )

        XCTAssertThrowsError(
            try CLIUpdateRunner.updatedAppRelaunchPlanForTest(
                runningApp: running,
                expectedIdentity: .init(version: "1.8.93")
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but Malibu.app did not update to v1.8.93 (installed v1.8.92). Reopen Malibu from Applications and run Update again."
            )
        }
    }

    func testNewlyInstalledAppVersionPlansRelaunch() throws {
        let app = try makeTemporaryMalibuApp(version: "1.8.93", build: "930")
        let running = CLIUpdateRunner.RunningAppSnapshot(
            bundleURL: app,
            version: "1.8.92",
            build: "920"
        )

        let plan = try XCTUnwrap(CLIUpdateRunner.updatedAppRelaunchPlanForTest(
            runningApp: running,
            expectedIdentity: .init(version: "1.8.93")
        ))
        XCTAssertEqual(plan.bundleURL, app.standardizedFileURL)
        XCTAssertEqual(plan.previousVersion, "1.8.92")
        XCTAssertEqual(plan.previousBuild, "920")
        XCTAssertEqual(plan.installedVersion, "1.8.93")
        XCTAssertEqual(plan.installedBuild, "930")
        XCTAssertEqual(plan.expectedVersion, "1.8.93")
    }

    func testSameVersionNewerBuildPlansRelaunch() throws {
        let app = try makeTemporaryMalibuApp(version: "1.8.93", build: "931")
        let running = CLIUpdateRunner.RunningAppSnapshot(
            bundleURL: app,
            version: "1.8.93",
            build: "930"
        )

        let plan = try XCTUnwrap(CLIUpdateRunner.updatedAppRelaunchPlanForTest(
            runningApp: running,
            expectedIdentity: .init(version: "1.8.93")
        ))
        XCTAssertEqual(plan.previousVersion, "1.8.93")
        XCTAssertEqual(plan.previousBuild, "930")
        XCTAssertEqual(plan.installedVersion, "1.8.93")
        XCTAssertEqual(plan.installedBuild, "931")
    }

    func testCurrentAppVersionDoesNotRelaunchWithoutExpectedTarget() throws {
        let app = try makeTemporaryMalibuApp(version: "1.8.93", build: "930")
        let running = CLIUpdateRunner.RunningAppSnapshot(
            bundleURL: app,
            version: "1.8.93",
            build: "930"
        )

        XCTAssertNil(try CLIUpdateRunner.updatedAppRelaunchPlanForTest(
            runningApp: running,
            expectedIdentity: nil
        ))
    }

    func testNonUpdaterOwnedAppPathDoesNotEnforceRelaunch() throws {
        let app = try makeTemporaryMalibuApp(version: "1.8.92", build: "92")
        let running = CLIUpdateRunner.RunningAppSnapshot(
            bundleURL: app,
            version: "1.8.92",
            build: "92"
        )

        XCTAssertNil(try CLIUpdateRunner.updatedAppRelaunchPlanForTest(
            runningApp: running,
            expectedIdentity: .init(version: "1.8.93"),
            isUpdaterOwnedInstall: { _ in false }
        ))
    }

    func testUnverifiedUpdatedAppFailsBeforeRelaunch() throws {
        let app = try makeTemporaryMalibuApp(version: "1.8.93", build: "930")
        let running = CLIUpdateRunner.RunningAppSnapshot(
            bundleURL: app,
            version: "1.8.92",
            build: "920"
        )

        XCTAssertThrowsError(
            try CLIUpdateRunner.updatedAppRelaunchPlanForTest(
                runningApp: running,
                expectedIdentity: .init(version: "1.8.93"),
                validateAppSignature: { _ in false }
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but the updated Malibu.app could not be verified. Reopen Malibu from Applications and run Update again."
            )
        }
    }

    func testMissingEmbeddedCompatibilityManifestFailsBeforeRelaunch() throws {
        let app = try makeTemporaryMalibuApp(version: "1.8.93", build: "930")
        let running = CLIUpdateRunner.RunningAppSnapshot(
            bundleURL: app,
            version: "1.8.92",
            build: "920"
        )

        XCTAssertThrowsError(
            try CLIUpdateRunner.updatedAppRelaunchPlanForTest(
                runningApp: running,
                expectedIdentity: .init(
                    version: "1.8.93",
                    compatibilitySetID: "Augustas11/macprovider:v1.8.93@0123456789abcdef0123456789abcdef01234567",
                    compatibilityManifestBytes: Data("expected manifest".utf8)
                )
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but Malibu.app update proof could not be verified. Reopen Malibu from Applications and run Update again."
            )
        }
    }

    func testMismatchedEmbeddedCompatibilityManifestFailsBeforeRelaunch() throws {
        let app = try makeTemporaryMalibuApp(
            version: "1.8.93",
            build: "930",
            embeddedCompatibilityManifestData: Data("different manifest".utf8)
        )
        let running = CLIUpdateRunner.RunningAppSnapshot(
            bundleURL: app,
            version: "1.8.92",
            build: "920"
        )

        XCTAssertThrowsError(
            try CLIUpdateRunner.updatedAppRelaunchPlanForTest(
                runningApp: running,
                expectedIdentity: .init(
                    version: "1.8.93",
                    compatibilitySetID: "Augustas11/macprovider:v1.8.93@0123456789abcdef0123456789abcdef01234567",
                    compatibilityManifestBytes: Data("expected manifest".utf8)
                )
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but Malibu.app update proof could not be verified. Reopen Malibu from Applications and run Update again."
            )
        }
    }

    func testSignedCompatibilityManifestProvidesExpectedAppVersion() throws {
        let fixture = try makeSignedCompatibilityManifest(malibuVersion: "1.8.94")
        let manifestBytes = try Data(contentsOf: fixture.manifest)

        let identity = try CLIUpdateRunner.expectedAppIdentityFromManifestForTest(
            manifestURL: fixture.manifest,
            publicKeyPEM: fixture.publicKeyPEM
        )

        XCTAssertEqual(
            identity,
            .init(
                version: "1.8.94",
                compatibilitySetID: "Augustas11/macprovider:v1.8.94@0123456789abcdef0123456789abcdef01234567",
                compatibilityManifestBytes: manifestBytes
            )
        )
    }

    func testMissingCompatibilityManifestFailsClosed() throws {
        let signingKey = P256.Signing.PrivateKey()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-compatibility-set-\(UUID().uuidString).json")

        XCTAssertThrowsError(
            try CLIUpdateRunner.expectedAppIdentityFromManifestForTest(
                manifestURL: missing,
                publicKeyPEM: signingKey.publicKey.pemRepresentation
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but Malibu.app update proof could not be verified. Reopen Malibu from Applications and run Update again."
            )
        }
    }

    func testUnsignedCompatibilityManifestFailsClosed() throws {
        let fixture = try makeSignedCompatibilityManifest(malibuVersion: "1.8.94")
        try rewriteManifest(fixture.manifest) { envelope in envelope["signatures"] = [] }

        XCTAssertThrowsError(
            try CLIUpdateRunner.expectedAppIdentityFromManifestForTest(
                manifestURL: fixture.manifest,
                publicKeyPEM: fixture.publicKeyPEM
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but Malibu.app update proof could not be verified. Reopen Malibu from Applications and run Update again."
            )
        }
    }

    func testTamperedCompatibilityManifestFailsClosed() throws {
        let fixture = try makeSignedCompatibilityManifest(malibuVersion: "1.8.94")
        try rewriteManifest(fixture.manifest) { envelope in
            guard var signed = envelope["signed"] as? [String: Any],
                  var components = signed["components"] as? [String: Any],
                  var malibuApp = components["malibu_app"] as? [String: Any] else {
                return XCTFail("fixture missing signed Malibu app section")
            }
            malibuApp["version"] = "1.8.95"
            components["malibu_app"] = malibuApp
            signed["components"] = components
            envelope["signed"] = signed
        }

        XCTAssertThrowsError(
            try CLIUpdateRunner.expectedAppIdentityFromManifestForTest(
                manifestURL: fixture.manifest,
                publicKeyPEM: fixture.publicKeyPEM
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but Malibu.app update proof could not be verified. Reopen Malibu from Applications and run Update again."
            )
        }
    }

    func testWrongCompatibilityManifestKeyFailsClosed() throws {
        let fixture = try makeSignedCompatibilityManifest(malibuVersion: "1.8.94")
        let wrongKey = P256.Signing.PrivateKey()

        XCTAssertThrowsError(
            try CLIUpdateRunner.expectedAppIdentityFromManifestForTest(
                manifestURL: fixture.manifest,
                publicKeyPEM: wrongKey.publicKey.pemRepresentation
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but Malibu.app update proof could not be verified. Reopen Malibu from Applications and run Update again."
            )
        }
    }

    func testWrongCompatibilityHandoffMetadataFailsClosed() throws {
        let fixture = try makeSignedCompatibilityManifest(
            malibuVersion: "1.8.94",
            handoffDelivery: "zip"
        )

        XCTAssertThrowsError(
            try CLIUpdateRunner.expectedAppIdentityFromManifestForTest(
                manifestURL: fixture.manifest,
                publicKeyPEM: fixture.publicKeyPEM
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but Malibu.app update proof could not be verified. Reopen Malibu from Applications and run Update again."
            )
        }
    }

    func testInstalledManifestProofRequiresInstalledProviderPayload() throws {
        let fixture = try makeSignedCompatibilityManifest(malibuVersion: "1.8.94")
        let manifestBytes = try Data(contentsOf: fixture.manifest)
        let executable = fixture.manifest.deletingLastPathComponent()
            .appendingPathComponent("macprovider-cli")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let identity = try CLIUpdateRunner.expectedAppIdentityFromInstalledProviderManifestForTest(
            executableURL: executable,
            publicKeyPEM: fixture.publicKeyPEM
        )

        XCTAssertEqual(
            identity,
            .init(
                version: "1.8.94",
                compatibilitySetID: "Augustas11/macprovider:v1.8.94@0123456789abcdef0123456789abcdef01234567",
                compatibilityManifestBytes: manifestBytes
            )
        )
    }

    func testInstalledManifestProofRejectsMissingProviderExecutable() throws {
        let fixture = try makeSignedCompatibilityManifest(malibuVersion: "1.8.94")
        let missingExecutable = fixture.manifest.deletingLastPathComponent()
            .appendingPathComponent("macprovider-cli")

        XCTAssertThrowsError(
            try CLIUpdateRunner.expectedAppIdentityFromInstalledProviderManifestForTest(
                executableURL: missingExecutable,
                publicKeyPEM: fixture.publicKeyPEM
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Provider software update completed, but Malibu.app update proof could not be verified. Reopen Malibu from Applications and run Update again."
            )
        }
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

private final class CLIUpdateRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var installedUpdates = 0
    private var pinnedVersions: [String] = []
    private var readinessChecks = 0
    private var proofStrategies: [CLIUpdateRunner.Strategy] = []
    private var proofSnapshots: [CLIUpdateRunner.RunningAppSnapshot?] = []
    private var relaunchPlans: [CLIUpdateRunner.UpdatedAppRelaunchPlan] = []
    private var logLines: [String] = []

    func recordInstalledUpdate() {
        lock.withLock { installedUpdates += 1 }
    }

    func recordPinnedInstall(_ version: String) {
        lock.withLock { pinnedVersions.append(version) }
    }

    func recordReadiness() {
        lock.withLock { readinessChecks += 1 }
    }

    func recordExpectedProof(
        strategy: CLIUpdateRunner.Strategy,
        runningApp: CLIUpdateRunner.RunningAppSnapshot?
    ) {
        lock.withLock {
            proofStrategies.append(strategy)
            proofSnapshots.append(runningApp)
        }
    }

    func recordRelaunch(_ plan: CLIUpdateRunner.UpdatedAppRelaunchPlan) {
        lock.withLock { relaunchPlans.append(plan) }
    }

    func recordLog(_ line: String) {
        lock.withLock { logLines.append(line) }
    }

    func snapshot() -> (
        installedUpdates: Int,
        pinnedVersions: [String],
        readinessChecks: Int,
        proofStrategies: [CLIUpdateRunner.Strategy],
        proofSnapshots: [CLIUpdateRunner.RunningAppSnapshot?],
        relaunchPlans: [CLIUpdateRunner.UpdatedAppRelaunchPlan],
        logLines: [String]
    ) {
        lock.withLock {
            (
                installedUpdates,
                pinnedVersions,
                readinessChecks,
                proofStrategies,
                proofSnapshots,
                relaunchPlans,
                logLines
            )
        }
    }
}

private final class CLIUpdateAgentRecorder: @unchecked Sendable {
    struct Invocation: Equatable {
        let installedVersion: String?
        let compatibilitySetID: String?
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []

    func recordInvocation(installedVersion: String?, compatibilitySetID: String?) {
        lock.withLock {
            invocations.append(
                .init(
                    installedVersion: installedVersion,
                    compatibilitySetID: compatibilitySetID
                )
            )
        }
    }

    func snapshot() -> [Invocation] {
        lock.withLock { invocations }
    }
}

private extension XCTestCase {
    func makeTemporaryMalibuApp(
        version: String,
        build: String,
        embeddedCompatibilityManifestData: Data? = nil
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-update-test-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Malibu.app", isDirectory: true).standardizedFileURL
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "tech.malibu.app",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
                "CFBundleExecutable": "Malibu",
            ],
            format: .xml,
            options: 0
        )
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        if let embeddedCompatibilityManifestData {
            let resources = contents.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try embeddedCompatibilityManifestData.write(
                to: resources.appendingPathComponent("compatibility-set.json")
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return app
    }

    func makeSignedCompatibilityManifest(
        malibuVersion: String,
        compatibilitySetID: String? = nil,
        handoffDelivery: String = "signed_dmg_transaction_member"
    ) throws -> (manifest: URL, publicKeyPEM: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-manifest-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let signingKey = P256.Signing.PrivateKey()
        let setID = compatibilitySetID
            ?? "Augustas11/macprovider:v\(malibuVersion)@0123456789abcdef0123456789abcdef01234567"
        let signed: [String: Any] = [
            "schema_version": "macprovider.compatibility-set.v1",
            "compatibility_set_id": setID,
            "components": [
                "malibu_app": [
                    "activation": "cli_owned_if_installed",
                    "bundle_id": "tech.malibu.app",
                    "compatibility_handoff": [
                        "delivery": handoffDelivery,
                        "embedded_manifest_path": "Contents/Resources/compatibility-set.json",
                        "provider_mutation": "forbidden",
                        "reader_compatibility": "backward_compatible",
                    ],
                    "minimum_status_reader": 1,
                    "version": malibuVersion,
                ],
            ],
        ]
        var signedData = try JSONSerialization.data(
            withJSONObject: signed,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        signedData.append(0x0a)
        let signature = try signingKey.signature(for: SHA256.hash(data: signedData))
        let envelope: [String: Any] = [
            "schema_version": "macprovider.compatibility-set-envelope.v1",
            "signatures": [[
                "algorithm": "ecdsa-p256-sha256",
                "key_id": "macprovider-release-p256-v1",
                "signature": signature.derRepresentation.base64EncodedString(),
            ]],
            "signed": signed,
        ]
        var envelopeData = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        envelopeData.append(0x0a)
        let manifest = root.appendingPathComponent("compatibility-set.json")
        try envelopeData.write(to: manifest)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (manifest, signingKey.publicKey.pemRepresentation)
    }

    func rewriteManifest(
        _ manifest: URL,
        mutateEnvelope: (inout [String: Any]) throws -> Void
    ) throws {
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        )
        try mutateEnvelope(&envelope)
        var data = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        try data.write(to: manifest)
    }
}
