import Foundation
import Darwin
import Security
import XCTest
@testable import macprovider_cli

final class SelfUpdateTests: XCTestCase {
    func testDefaultReleaseRepositoryMatchesPublicInstaller() {
        XCTAssertEqual(
            SelfUpdate.defaultReleasesAPIURL,
            "https://api.github.com/repos/Augustas11/macprovider/releases/latest"
        )
    }

    func testReleaseAPIURLIgnoresEnvironmentFallback() {
        withEnvironmentVariable("MACPROVIDER_RELEASES_API_URL", value: "http://attacker.invalid/releases") {
            let update = SelfUpdate(currentVersion: "1.2.0", releasesAPIURL: nil)

            XCTAssertEqual(update.resolvedReleasesAPIURLForTest(), SelfUpdate.defaultReleasesAPIURL)
        }
    }

    func testReleaseAPIURLRejectsUntrustedExplicitOverrideBeforeFetching() async throws {
        let update = SelfUpdate(currentVersion: "1.2.0", releasesAPIURL: "http://attacker.invalid/releases")

        do {
            try await update.run(checkOnly: true)
            XCTFail("update unexpectedly fetched from an untrusted release API URL")
        } catch let error as UpdateError {
            XCTAssertEqual(
                error.description,
                UpdateError.untrustedReleaseAPIURL(
                    "http://attacker.invalid/releases?per_page=20"
                ).description
            )
        }
    }

    func testReleaseSigningKeyIgnoresEnvironmentOverride() {
        let attackerKey = """
        -----BEGIN PUBLIC KEY-----
        attacker-controlled-key
        -----END PUBLIC KEY-----
        """

        withEnvironmentVariable("MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM", value: attackerKey) {
            XCTAssertEqual(SelfUpdate.releaseSigningPublicKeyPEMForTest(), SelfUpdate.checksumPublicKeyPEM)
            XCTAssertNotEqual(SelfUpdate.releaseSigningPublicKeyPEMForTest(), attackerKey)
        }
    }

    func testSemverComparison() {
        XCTAssertEqual(SelfUpdate.compareSemver("1.2.0", "1.2.1"), .orderedAscending)
        XCTAssertEqual(SelfUpdate.compareSemver("v1.2.1", "1.2.1"), .orderedSame)
        XCTAssertEqual(SelfUpdate.compareSemver("1.3.0", "1.2.9"), .orderedDescending)
        XCTAssertEqual(SelfUpdate.compareSemver("1.2", "1.2.0"), .orderedSame)
    }

    func testReleaseTagAndStagedBinaryComponentVersionAreValidatedIndependently() throws {
        XCTAssertEqual(try SelfUpdate.validateReleaseTag("v1.2.1"), "1.2.1")
        XCTAssertThrowsError(try SelfUpdate.validateReleaseTag(" v1.2.1 "))
        XCTAssertThrowsError(try SelfUpdate.validateReleaseTag("release-1.2.1"))
        XCTAssertNoThrow(try SelfUpdate.requireStagedBinaryVersion("1.8.40\n", targetVersion: "1.8.40"))
    }

    func testDiscoveryHeadBindsSetVersionWhileCLIAndMalibuVersionsCanDiffer() throws {
        let setID = "Augustas11/macprovider:v1.8.50@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let manifest = CompatibilitySetManifest(
            compatibilitySetID: setID,
            envelopeSHA256: String(repeating: "b", count: 64),
            version: "1.8.50",
            catalogReleaseID: "catalog-2026-07-17",
            catalogPolicyVersion: "policy-1",
            maintenanceLeaseSeconds: 90,
            readinessTimeoutSeconds: 300,
            malibuAppVersion: "1.8.51",
            providerCLIVersion: "1.8.49"
        )
        let prepared = PreparedSelfUpdate(
            tempDir: FileManager.default.temporaryDirectory,
            newBinary: URL(fileURLWithPath: "/tmp/macprovider-cli-test"),
            stagedMalibuApp: nil,
            signedPolicy: nil,
            compatibilityManifest: manifest,
            artifactIndexSHA256: String(repeating: "c", count: 64)
        )
        let head = SignedReleaseDiscoveryHead(
            releaseSequence: 1,
            targetVersion: "1.8.50",
            targetCompatibilitySetID: setID,
            targetArtifactIndexSHA256: String(repeating: "c", count: 64),
            signedPolicyMinimum: nil,
            signedPolicyRevoked: [],
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(300),
            digest: String(repeating: "d", count: 64)
        )

        XCTAssertNoThrow(try SelfUpdate.requireDiscoveryHead(head, matches: prepared))
        let mismatched = PreparedSelfUpdate(
            tempDir: prepared.tempDir,
            newBinary: prepared.newBinary,
            stagedMalibuApp: nil,
            signedPolicy: nil,
            compatibilityManifest: manifest,
            artifactIndexSHA256: String(repeating: "e", count: 64)
        )
        XCTAssertThrowsError(try SelfUpdate.requireDiscoveryHead(head, matches: mismatched)) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.discoveryHeadInvalid("target_identity_mismatch").description
            )
        }
    }

    func testAppendOnlyDiscoveryTransportRequiresTagSequenceToMatchSignedHead() throws {
        let head = SignedReleaseDiscoveryHead(
            releaseSequence: 1,
            targetVersion: "1.8.56",
            targetCompatibilitySetID: "Augustas11/macprovider:v1.8.56@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            targetArtifactIndexSHA256: String(repeating: "b", count: 64),
            signedPolicyMinimum: nil,
            signedPolicyRevoked: [],
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(300),
            digest: String(repeating: "c", count: 64)
        )

        XCTAssertNoThrow(
            try SelfUpdate.requireAppendOnlyDiscoveryTransport(
                transportTag: "release-discovery-v1-1",
                transportSequence: 1,
                head: head
            )
        )
        XCTAssertThrowsError(
            try SelfUpdate.requireAppendOnlyDiscoveryTransport(
                transportTag: "release-discovery-v1-2",
                transportSequence: 2,
                head: head
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.discoveryHeadInvalid("transport_sequence_mismatch").description
            )
        }
        XCTAssertNil(SignedReleaseDiscoveryHead.transportSequence(from: "release-discovery-v1-01"))
        XCTAssertNil(SignedReleaseDiscoveryHead.transportSequence(from: "release-discovery-v1-0"))
        XCTAssertNil(SignedReleaseDiscoveryHead.transportSequence(from: "v1.8.56"))
    }

    func testAcceptanceProviderComponentAllowsEqualityAndUpgradeButRejectsDowngrade() throws {
        XCTAssertNoThrow(
            try SelfUpdate.requireAcceptanceProviderVersion(current: "1.8.40", target: "1.8.40")
        )
        XCTAssertNoThrow(
            try SelfUpdate.requireAcceptanceProviderVersion(current: "1.8.40", target: "1.8.41")
        )
        XCTAssertThrowsError(
            try SelfUpdate.requireAcceptanceProviderVersion(current: "1.8.40", target: "1.8.39")
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.acceptanceProviderDowngrade(
                    current: "1.8.40",
                    target: "1.8.39"
                ).description
            )
        }
    }

    func testStagedCLIPreflightCannotLoadTheServingModel() {
        XCTAssertEqual(SelfUpdate.stagedCLIPreflightArguments, ["--version"])
        XCTAssertFalse(SelfUpdate.stagedCLIPreflightArguments.contains("self-test"))
    }

    func testCurrentTeamIDLookupValidatesBeforeRequestingCryptographicSigningInformation() throws {
        XCTAssertEqual(
            SelfUpdate.currentSigningInformationFlags.rawValue,
            kSecCSSigningInformation
        )
        XCTAssertEqual(
            SelfUpdate.currentCodeValidityFlags.rawValue,
            kSecCSStrictValidate
        )

        var currentCode: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &currentCode), errSecSuccess)
        let unwrappedCurrentCode = try XCTUnwrap(currentCode)
        var currentStaticCode: SecStaticCode?
        XCTAssertEqual(
            SecCodeCopyStaticCode(unwrappedCurrentCode, [], &currentStaticCode),
            errSecSuccess
        )
        let unwrappedStaticCode = try XCTUnwrap(currentStaticCode)

        var calls: [String] = []
        let teamID = try SelfUpdate.signingTeamID(
            for: unwrappedCurrentCode,
            checkValidity: { _, flags, requirement in
                calls.append("validity")
                XCTAssertEqual(flags.rawValue, kSecCSStrictValidate)
                XCTAssertNil(requirement)
                return errSecSuccess
            },
            copyStaticCode: { _, flags, output in
                calls.append("static")
                XCTAssertEqual(flags.rawValue, 0)
                output.pointee = unwrappedStaticCode
                return errSecSuccess
            },
            copySigningInformation: { _, flags, output in
                calls.append("signing")
                XCTAssertEqual(flags.rawValue, kSecCSSigningInformation)
                output.pointee = [
                    kSecCodeInfoTeamIdentifier as String: "YF7XNRJUG4"
                ] as CFDictionary
                return errSecSuccess
            }
        )

        XCTAssertEqual(teamID, "YF7XNRJUG4")
        XCTAssertEqual(calls, ["validity", "static", "signing"])
    }

    func testCurrentTeamIDLookupFailsBeforeReadingInvalidRunningCode() throws {
        var currentCode: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &currentCode), errSecSuccess)
        let unwrappedCurrentCode = try XCTUnwrap(currentCode)
        var copiedStaticCode = false
        var copiedSigningInformation = false

        XCTAssertThrowsError(
            try SelfUpdate.signingTeamID(
                for: unwrappedCurrentCode,
                checkValidity: { _, _, _ in errSecParam },
                copyStaticCode: { _, _, _ in
                    copiedStaticCode = true
                    return errSecSuccess
                },
                copySigningInformation: { _, _, _ in
                    copiedSigningInformation = true
                    return errSecSuccess
                }
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.stagedCLIIdentityInvalid(
                    "running_cli_signing_identity_invalid"
                ).description
            )
        }
        XCTAssertFalse(copiedStaticCode)
        XCTAssertFalse(copiedSigningInformation)
    }

    func testAcceptanceDirectoryRequiresOwnedFlatNonWritableRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acceptance-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("signed-assets".utf8).write(to: root.appendingPathComponent("checksums.txt"))

        XCTAssertEqual(
            try SelfUpdate.validatedAcceptanceAssetNames(in: root),
            ["checksums.txt"]
        )

        let link = root.appendingPathComponent("checksums.txt.sig")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root.appendingPathComponent("checksums.txt")
        )
        XCTAssertThrowsError(try SelfUpdate.validatedAcceptanceAssetNames(in: root)) { error in
            XCTAssertTrue(String(describing: error).contains("asset_permissions_or_type"))
        }
    }

    func testAcceptanceCandidateRejectsDowngradeBeforeReadingAssets() async {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-downgrade-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let update = SelfUpdate(
            currentVersion: "1.8.34",
            releasesAPIURL: nil,
            markerStore: AutoUpdateMarkerStore(homeDirectory: home)
        )
        do {
            try await update.runAcceptanceCandidate(
                from: URL(fileURLWithPath: "/path/that/does/not/exist", isDirectory: true),
                tag: "v1.8.33",
                expectedCommit: String(repeating: "a", count: 40),
                expectedControlCommit: String(repeating: "b", count: 40),
                expectedRunID: "12345",
                expectedRunAttempt: 1
            )
            XCTFail("acceptance candidate unexpectedly allowed a downgrade")
        } catch let error as UpdateError {
            XCTAssertEqual(
                error.description,
                UpdateError.acceptanceCandidateNotNewer(current: "1.8.34", target: "1.8.33").description
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCopiedOlderSignedPayloadCannotMasqueradeAsNewRelease() {
        XCTAssertThrowsError(
            try SelfUpdate.requireStagedBinaryVersion("1.2.0\n", targetVersion: "1.2.1")
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.stagedVersionMismatch(expected: "1.2.1", actual: "1.2.0").description
            )
        }
    }

    func testValidatedUpdateDrainsBeforeReplacingAndRestartingLaunchd() async throws {
        let recorder = UpdateActionRecorder()
        let binary = URL(fileURLWithPath: "/tmp/macprovider-cli-test")
        let update = SelfUpdate(
            currentVersion: "1.2.0",
            releasesAPIURL: nil,
            drainBeforeReplace: {
                recorder.append("drain_status:starting")
                recorder.append("drain_status:in_progress")
                recorder.append("drain_status:complete")
            },
            replaceBinary: { _ in
                recorder.append("replace")
            },
            restartLaunchd: {
                recorder.append("launchctl_bootstrap")
            },
            postRestartReadiness: { true }
        )

        try await update.applyValidatedUpdateForTest(newBinary: binary)

        XCTAssertEqual(recorder.snapshot(), [
            "drain_status:starting",
            "drain_status:in_progress",
            "drain_status:complete",
            "replace",
            "launchctl_bootstrap",
        ])
    }

    func testRestartFailureReturnsFailureAndRollsBackReplacement() async throws {
        let recorder = UpdateActionRecorder()
        let binary = URL(fileURLWithPath: "/tmp/macprovider-cli-test")
        let update = SelfUpdate(
            currentVersion: "1.2.0",
            releasesAPIURL: nil,
            drainBeforeReplace: {
                recorder.append("drain")
            },
            replaceBinary: { _ in
                recorder.append("replace")
            },
            rollbackReplacement: {
                recorder.append("rollback")
            },
            restartLaunchd: {
                recorder.append("restart")
                throw UpdateError.processFailed("/bin/launchctl", 5)
            }
        )

        do {
            try await update.applyValidatedUpdateForTest(newBinary: binary)
            XCTFail("restart failure unexpectedly returned success")
        } catch let error as UpdateError {
            XCTAssertTrue(error.description.contains("rollback_restored"))
        }

        XCTAssertEqual(recorder.snapshot(), ["drain", "replace", "restart", "rollback"])
    }

    func testReadinessFailureRollsBackReplacement() async throws {
        let recorder = UpdateActionRecorder()
        let update = SelfUpdate(
            currentVersion: "1.2.0",
            releasesAPIURL: nil,
            replaceBinary: { _ in recorder.append("replace") },
            rollbackReplacement: { recorder.append("rollback") },
            restartLaunchd: { recorder.append("restart") },
            postRestartReadiness: { false }
        )

        do {
            try await update.applyValidatedUpdateForTest(newBinary: URL(fileURLWithPath: "/tmp/macprovider-cli-test"))
            XCTFail("readiness failure unexpectedly returned success")
        } catch let error as UpdateError {
            XCTAssertTrue(error.description.contains("rollback_restored"))
        }

        XCTAssertEqual(recorder.snapshot(), ["replace", "restart", "rollback", "restart"])
    }

    func testPayloadTransactionRestoresBinaryAndAdjacentResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-payload-\(UUID().uuidString)", isDirectory: true)
        let current = root.appendingPathComponent("current", isDirectory: true)
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let currentBinary = current.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: currentBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: currentBinary.path)
        try Data("old-metal".utf8).write(to: current.appendingPathComponent("mlx.metallib"))
        let oldBundle = current.appendingPathComponent("Runtime.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: oldBundle, withIntermediateDirectories: false)
        try Data("old-resource".utf8).write(to: oldBundle.appendingPathComponent("resource"))
        let oldCatalog = current.appendingPathComponent("catalog-release", isDirectory: true)
        try Self.writeCatalogFixture(to: oldCatalog, marker: "old")
        try Data("old-compatibility-set".utf8).write(
            to: current.appendingPathComponent(CompatibilitySetManifest.fileName)
        )

        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try Data("new-metal".utf8).write(to: payload.appendingPathComponent("mlx.metallib"))
        let newBundle = payload.appendingPathComponent("Runtime.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: false)
        try Data("new-resource".utf8).write(to: newBundle.appendingPathComponent("resource"))
        let newCatalog = payload.appendingPathComponent("catalog-release", isDirectory: true)
        try Self.writeCatalogFixture(to: newCatalog, marker: "new")
        try Data("new-notices".utf8).write(to: payload.appendingPathComponent("THIRD-PARTY-NOTICES.txt"))
        try Data("new-compatibility-set".utf8).write(
            to: payload.appendingPathComponent(CompatibilitySetManifest.fileName)
        )
        try Self.writeLocalCompatibilityArtifacts(to: payload)
        try Data("new-compatibility-set".utf8).write(
            to: payload.appendingPathComponent(CompatibilitySetManifest.fileName)
        )

        let transaction = try ProviderReleasePayloadTransaction(
            currentBinary: currentBinary,
            markerStore: AutoUpdateMarkerStore(homeDirectory: root)
        )
        try transaction.activate(from: payload, newBinary: newBinary)
        XCTAssertEqual(try String(contentsOf: currentBinary), "new-binary")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("mlx.metallib")), "new-metal")
        XCTAssertEqual(try String(contentsOf: oldCatalog.appendingPathComponent("release.json")), "new-release.json")
        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent(CompatibilitySetManifest.fileName)),
            "new-compatibility-set"
        )

        try transaction.restore()
        transaction.cleanup()

        XCTAssertEqual(try String(contentsOf: currentBinary), "old-binary")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("mlx.metallib")), "old-metal")
        XCTAssertEqual(try String(contentsOf: oldBundle.appendingPathComponent("resource")), "old-resource")
        XCTAssertEqual(try String(contentsOf: oldCatalog.appendingPathComponent("release.json")), "old-release.json")
        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent(CompatibilitySetManifest.fileName)),
            "old-compatibility-set"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.backupDirectory.path))
    }

    func testPayloadValidationRejectsIncompleteReleaseBeforeActivation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-incomplete-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = root.appendingPathComponent("macprovider-cli")
        try Data("new-binary".utf8).write(to: binary)

        XCTAssertThrowsError(
            try ProviderReleasePayloadTransaction.validateReleasePayload(at: root, newBinary: binary)
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                UpdateError.missingReleaseResource("mlx.metallib").description
            )
        }
    }

    func testExtractedTreeRejectsNestedSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-update-symlink-\(UUID().uuidString)", isDirectory: true)
        let bundle = root.appendingPathComponent("Runtime.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("escape"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertThrowsError(try SelfUpdate.validateExtractedTreeForTest(root)) { error in
            XCTAssertTrue(String(describing: error).contains("unsafe entry"))
        }
    }

    private static func writeCatalogFixture(to directory: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in [
            "release.json",
            "trusted-keys.json",
            "tier2-catalog.json",
            "autotune-candidates.json",
            "autotune-candidates.json.sig",
            "demand-rank.json",
            "demand-rank.json.sig",
            "rate-card.json",
            "rate-card.json.sig",
        ] {
            try Data("\(marker)-\(name)".utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    private static func writeLocalCompatibilityArtifacts(to directory: URL) throws {
        let local = directory.appendingPathComponent(CompatibilitySetManifest.localArtifactDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        for name in [
            "install.sh",
            "provider-launch-agent.plist.template",
            "updater-rollback.json",
            "watchdog-launch-agent.plist.template",
            "watchdog.sh",
        ] {
            try Data(name.utf8).write(to: local.appendingPathComponent(name))
        }
    }

    func testLaunchdReloadBootsOutAndBootstrapsLoadedService() {
        XCTAssertEqual(
            SelfUpdate.launchdReloadArguments(
                label: SelfUpdate.launchdLabel,
                serviceLoaded: true,
                uid: 501,
                plistPath: "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist"
            ),
            [
                ["bootout", "gui/501/live.streamvc.macprovider"],
                ["bootstrap", "gui/501", "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist"],
            ]
        )
    }

    func testLaunchdReloadBootstrapsOnlyWhenServiceIsNotLoaded() {
        let plist = "/Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist"

        XCTAssertEqual(
            SelfUpdate.launchdReloadArguments(
                label: SelfUpdate.launchdLabel,
                serviceLoaded: false,
                uid: 501,
                plistPath: plist
            ),
            [["bootstrap", "gui/501", plist]]
        )
    }

    func testCompatibilityReloadReloadsWatchdogBeforeProvider() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-reload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        for label in [SelfUpdate.watchdogLaunchdLabel, SelfUpdate.launchdLabel] {
            try Data("plist".utf8).write(to: launchAgents.appendingPathComponent("\(label).plist"))
        }
        var commands: [([String], Bool)] = []

        try SelfUpdate.reloadCompatibilityLaunchdJobs(
            homeDirectory: home,
            uid: 501,
            serviceLoaded: { $0 == SelfUpdate.watchdogLaunchdLabel },
            servicePresent: { _ in false },
            loadedServiceLabels: { [] },
            runLaunchctl: { commands.append(($0, $1)) }
        )

        XCTAssertEqual(commands.count, 4)
        XCTAssertEqual(
            commands[0].0,
            ["bootout", "gui/501/live.streamvc.macprovider-compatibility-reload"]
        )
        XCTAssertTrue(commands[0].1)
        XCTAssertEqual(commands[1].0, ["bootout", "gui/501/live.streamvc.macprovider-watchdog"])
        XCTAssertFalse(commands[1].1)
        XCTAssertEqual(
            commands[2].0,
            [
                "bootstrap",
                "gui/501",
                launchAgents.appendingPathComponent("live.streamvc.macprovider-watchdog.plist").path,
            ]
        )
        XCTAssertEqual(
            commands[3].0,
            [
                "bootstrap",
                "gui/501",
                launchAgents.appendingPathComponent(
                    "live.streamvc.macprovider-compatibility-reload.plist"
                ).path,
            ]
        )
        XCTAssertFalse(commands[3].1)
        XCTAssertFalse(commands.flatMap(\.0).contains("submit"))

        let helperURL = launchAgents.appendingPathComponent(
            "live.streamvc.macprovider-compatibility-reload.plist"
        )
        let helper = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: helperURL),
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(helper["Label"] as? String, SelfUpdate.providerReloadLaunchdLabel)
        XCTAssertEqual(helper["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(helper["KeepAlive"] as? Bool, false)
        XCTAssertEqual(helper["LaunchOnlyOnce"] as? Bool, true)
        XCTAssertNil(helper["SuccessfulExit"])
        let arguments = try XCTUnwrap(helper["ProgramArguments"] as? [String])
        XCTAssertEqual(Array(arguments.prefix(2)), ["/bin/sh", "-c"])
        let script = try XCTUnwrap(arguments.last)
        XCTAssertEqual(
            script.components(separatedBy: "bootout 'gui/501/live.streamvc.macprovider'").count - 1,
            1
        )
        let bootoutRange = try XCTUnwrap(
            script.range(of: "bootout 'gui/501/live.streamvc.macprovider'")
        )
        let absenceRange = try XCTUnwrap(
            script.range(of: "print 'gui/501/live.streamvc.macprovider'")
        )
        let bootstrapRange = try XCTUnwrap(
            script.range(
                of: "bootstrap 'gui/501' '\(launchAgents.appendingPathComponent("live.streamvc.macprovider.plist").path)'"
            )
        )
        XCTAssertLessThan(bootoutRange.lowerBound, absenceRange.lowerBound)
        XCTAssertLessThan(absenceRange.lowerBound, bootstrapRange.lowerBound)
        XCTAssertTrue(script.contains("while [ \"$attempt\" -lt 100 ]"))
        XCTAssertTrue(script.contains("[ \"$status\" -eq 113 ]"))
        XCTAssertTrue(script.contains("*\"Could not find service\"*"))
        XCTAssertTrue(script.contains("[ \"$provider_absent\" -eq 1 ] || exit 75"))
        XCTAssertEqual(
            script.components(
                separatedBy: "bootstrap 'gui/501' '\(launchAgents.appendingPathComponent("live.streamvc.macprovider.plist").path)'"
            ).count - 1,
            1
        )
    }

    func testReloadHelperWaitsForCanonicalAbsenceThenBootstrapsExactlyOnce() throws {
        let result = try runReloadHelperScenario(absentAfterCheck: 3, maxChecks: 5)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(
            result.log,
            [
                "bootout gui/501/live.streamvc.macprovider",
                "print gui/501/live.streamvc.macprovider",
                "sleep 0.1",
                "print gui/501/live.streamvc.macprovider",
                "sleep 0.1",
                "print gui/501/live.streamvc.macprovider",
                "bootstrap gui/501 \(result.providerPlistPath)",
                "bootout gui/501/live.streamvc.macprovider-compatibility-reload",
            ]
        )
        XCTAssertEqual(result.log.filter { $0.hasPrefix("bootstrap ") }.count, 1)
        XCTAssertFalse(result.helperPlistExists)
    }

    func testReloadHelperFailsBoundedlyWithoutBootstrapWhenCanonicalNeverDisappears() throws {
        let result = try runReloadHelperScenario(absentAfterCheck: nil, maxChecks: 3)

        XCTAssertEqual(result.status, 75)
        XCTAssertEqual(
            result.log.filter { $0 == "print gui/501/live.streamvc.macprovider" }.count,
            3
        )
        XCTAssertEqual(result.log.filter { $0 == "sleep 0.1" }.count, 2)
        XCTAssertFalse(result.log.contains { $0.hasPrefix("bootstrap ") })
        XCTAssertFalse(result.helperPlistExists)
    }

    func testReloadHelperFailsClosedOnUnknownServiceInspectionError() throws {
        let result = try runReloadHelperScenario(
            absentAfterCheck: nil,
            maxChecks: 3,
            printFailureStatus: 5
        )

        XCTAssertEqual(result.status, 5)
        XCTAssertEqual(
            result.log.filter { $0 == "print gui/501/live.streamvc.macprovider" }.count,
            1
        )
        XCTAssertFalse(result.log.contains { $0.hasPrefix("bootstrap ") })
        XCTAssertFalse(result.helperPlistExists)
    }

    func testReloadHelperTimesOutHungBootoutWithoutBootstrappingOrRemovingProviderPlist() throws {
        let started = Date()
        let result = try runReloadHelperScenario(
            absentAfterCheck: 1,
            maxChecks: 3,
            hangOperation: "bootout"
        )

        XCTAssertEqual(result.status, 124)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(result.log.contains { $0.hasPrefix("print ") })
        XCTAssertFalse(result.log.contains { $0.hasPrefix("bootstrap ") })
        XCTAssertTrue(result.providerPlistExists)
        XCTAssertFalse(result.helperPlistExists)
    }

    func testReloadHelperTimesOutHungPrintWithoutBootstrappingOrRemovingProviderPlist() throws {
        let started = Date()
        let result = try runReloadHelperScenario(
            absentAfterCheck: nil,
            maxChecks: 3,
            hangOperation: "print"
        )

        XCTAssertEqual(result.status, 124)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(result.log.contains { $0.hasPrefix("bootstrap ") })
        XCTAssertTrue(result.providerPlistExists)
        XCTAssertFalse(result.helperPlistExists)
    }

    func testReloadHelperTimesOutHungBootstrapWithoutRemovingProviderPlist() throws {
        let started = Date()
        let result = try runReloadHelperScenario(
            absentAfterCheck: 1,
            maxChecks: 3,
            hangOperation: "bootstrap"
        )

        XCTAssertEqual(result.status, 124)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(result.log.filter { $0.hasPrefix("bootstrap ") }.count, 1)
        XCTAssertTrue(result.providerPlistExists)
        XCTAssertFalse(result.helperPlistExists)
    }

    func testCompatibilityReloadFencesLegacyJobsBeforeValidatingCanonicalPlists() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-reload-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try Data("provider".utf8).write(
            to: launchAgents.appendingPathComponent("\(SelfUpdate.launchdLabel).plist")
        )
        let legacyLabel = "live.streamvc.macprovider-compatibility-reload.12345678-1234-1234-1234-123456789abc"
        var loaded = Set([legacyLabel])
        var commands: [([String], Bool)] = []

        XCTAssertThrowsError(try SelfUpdate.reloadCompatibilityLaunchdJobs(
            homeDirectory: home,
            uid: 501,
            serviceLoaded: { loaded.contains($0) },
            servicePresent: { loaded.contains($0) },
            loadedServiceLabels: { Array(loaded) },
            runLaunchctl: {
                commands.append(($0, $1))
                if $0 == ["bootout", "gui/501/\(legacyLabel)"] {
                    loaded.remove(legacyLabel)
                }
            }
        ))
        XCTAssertEqual(
            commands.map(\.0),
            [
                ["bootout", "gui/501/\(legacyLabel)"],
                ["bootout", "gui/501/live.streamvc.macprovider-compatibility-reload"],
            ]
        )
        XCTAssertTrue(commands[0].1)
        XCTAssertTrue(commands[1].1)
    }

    func testCompatibilityReloadFenceWaitsForDelayedHelperDisappearance() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-fence-delayed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let helperPlist = launchAgents.appendingPathComponent(
            "\(SelfUpdate.providerReloadLaunchdLabel).plist"
        )
        try Data("stale".utf8).write(to: helperPlist)
        var inspections = 0
        var sleeps: [TimeInterval] = []

        try SelfUpdate.fenceProviderReloadLaunchdJobs(
            homeDirectory: home,
            uid: 501,
            servicePresent: { label in
                XCTAssertEqual(label, SelfUpdate.providerReloadLaunchdLabel)
                inspections += 1
                return inspections < 3
            },
            loadedServiceLabels: { [SelfUpdate.providerReloadLaunchdLabel] },
            runLaunchctl: { arguments, allowFailure in
                XCTAssertEqual(
                    arguments,
                    ["bootout", "gui/501/\(SelfUpdate.providerReloadLaunchdLabel)"]
                )
                XCTAssertTrue(allowFailure)
            },
            removalMaxChecks: 5,
            sleep: { sleeps.append($0) }
        )

        XCTAssertEqual(inspections, 3)
        XCTAssertEqual(sleeps, [0.1, 0.1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: helperPlist.path))
    }

    func testCompatibilityReloadFenceAcceptsListBootoutAlreadyAbsentRace() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-fence-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let helperPlist = launchAgents.appendingPathComponent(
            "\(SelfUpdate.providerReloadLaunchdLabel).plist"
        )
        try Data("stale".utf8).write(to: helperPlist)
        var inspected = false

        try SelfUpdate.fenceProviderReloadLaunchdJobs(
            homeDirectory: home,
            uid: 501,
            servicePresent: { label in
                XCTAssertEqual(label, SelfUpdate.providerReloadLaunchdLabel)
                inspected = true
                return false
            },
            loadedServiceLabels: { [SelfUpdate.providerReloadLaunchdLabel] },
            runLaunchctl: { arguments, allowFailure in
                XCTAssertEqual(
                    arguments,
                    ["bootout", "gui/501/\(SelfUpdate.providerReloadLaunchdLabel)"]
                )
                XCTAssertTrue(allowFailure)
            },
            removalMaxChecks: 3,
            sleep: { _ in XCTFail("already-absent helper should not sleep") }
        )

        XCTAssertTrue(inspected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helperPlist.path))
    }

    func testCompatibilityReloadFenceTimesOutBeforeUnlinkingHelperPlist() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-fence-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let helperPlist = launchAgents.appendingPathComponent(
            "\(SelfUpdate.providerReloadLaunchdLabel).plist"
        )
        try Data("stale".utf8).write(to: helperPlist)
        var inspections = 0
        var sleeps = 0

        XCTAssertThrowsError(try SelfUpdate.fenceProviderReloadLaunchdJobs(
            homeDirectory: home,
            uid: 501,
            servicePresent: { _ in
                inspections += 1
                return true
            },
            loadedServiceLabels: { [] },
            runLaunchctl: { _, allowFailure in XCTAssertTrue(allowFailure) },
            removalMaxChecks: 3,
            sleep: { _ in sleeps += 1 }
        ))

        XCTAssertEqual(inspections, 3)
        XCTAssertEqual(sleeps, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperPlist.path))
    }

    func testCompatibilityReloadFenceFailsClosedWhenServiceInspectionFails() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-fence-query-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let helperPlist = launchAgents.appendingPathComponent(
            "\(SelfUpdate.providerReloadLaunchdLabel).plist"
        )
        try Data("stale".utf8).write(to: helperPlist)
        var commands: [([String], Bool)] = []

        XCTAssertThrowsError(try SelfUpdate.fenceProviderReloadLaunchdJobs(
            homeDirectory: home,
            uid: 501,
            servicePresent: { _ in
                throw UpdateError.processFailed("launchctl print", 5)
            },
            loadedServiceLabels: { [] },
            runLaunchctl: { commands.append(($0, $1)) }
        ))

        XCTAssertEqual(
            commands.map(\.0),
            [["bootout", "gui/501/live.streamvc.macprovider-compatibility-reload"]]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperPlist.path))
    }

    func testCompatibilityReloadFenceTreatsDisabledLoadedHelperAsPresent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-fence-disabled-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let helperPlist = launchAgents.appendingPathComponent(
            "\(SelfUpdate.providerReloadLaunchdLabel).plist"
        )
        try Data("stale".utf8).write(to: helperPlist)

        XCTAssertThrowsError(try SelfUpdate.fenceProviderReloadLaunchdJobs(
            homeDirectory: home,
            uid: 501,
            servicePresent: { $0 == SelfUpdate.providerReloadLaunchdLabel },
            loadedServiceLabels: { [] },
            runLaunchctl: { _, allowFailure in XCTAssertTrue(allowFailure) },
            removalMaxChecks: 3,
            sleep: { _ in }
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: helperPlist.path))
    }

    func testBoundedLaunchctlRunnerReportsTimeoutDistinctly() throws {
        let started = Date()

        XCTAssertThrowsError(try SelfUpdate.runLaunchctlCommand(
            arguments: ["10"],
            executablePath: "/bin/sleep",
            timeout: 0.05,
            terminateGrace: 0.05
        )) { error in
            guard case let UpdateError.processTimedOut(command, timeout) = error else {
                return XCTFail("expected processTimedOut, got \(error)")
            }
            XCTAssertEqual(command, "/bin/sleep 10")
            XCTAssertEqual(timeout, 0.05)
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testServiceLoadedProbeFailsClosedOnTimeoutAndUnknownStatus() throws {
        let started = Date()
        XCTAssertFalse(SelfUpdate.launchctlServiceLoaded(
            label: SelfUpdate.launchdLabel,
            executablePath: "/usr/bin/yes",
            timeout: 0.05
        ))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        XCTAssertFalse(SelfUpdate.launchctlServiceLoaded(
            label: SelfUpdate.launchdLabel,
            executablePath: "/usr/bin/false",
            timeout: 0.5
        ))
    }

    func testBoundedLaunchctlRunnerDrainsOutputWithoutPipeBackpressure() throws {
        let byteCount = 1_048_576
        let result = try SelfUpdate.runLaunchctlCommand(
            arguments: [
                "-c",
                "/usr/bin/yes launchctl-output | /usr/bin/head -c \(byteCount)",
            ],
            allowFailure: false,
            executablePath: "/bin/sh",
            timeout: 2
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.output.utf8.count, byteCount)
        XCTAssertTrue(result.output.hasPrefix("launchctl-output"))
    }

    func testLaunchctlTimeoutFailsFenceBeforeUnlinkingHelperPlist() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchctl-command-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let helperPlist = launchAgents.appendingPathComponent(
            "\(SelfUpdate.providerReloadLaunchdLabel).plist"
        )
        try Data("stale".utf8).write(to: helperPlist)

        XCTAssertThrowsError(try SelfUpdate.fenceProviderReloadLaunchdJobs(
            homeDirectory: home,
            uid: 501,
            servicePresent: { _ in false },
            loadedServiceLabels: { [SelfUpdate.providerReloadLaunchdLabel] },
            runLaunchctl: { _, allowFailure in
                XCTAssertTrue(allowFailure)
                _ = try SelfUpdate.runLaunchctlCommand(
                    arguments: ["10"],
                    allowFailure: allowFailure,
                    executablePath: "/bin/sleep",
                    timeout: 0.05,
                    terminateGrace: 0.05
                )
            }
        )) { error in
            guard case UpdateError.processTimedOut = error else {
                return XCTFail("expected processTimedOut, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: helperPlist.path))
    }

    func testLaunchctlServiceLoadedThrowsOnTimeoutForRestartPath() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hanging-launchctl-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: script) }
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )

        XCTAssertThrowsError(try SelfUpdate.launchctlServiceLoadedOrThrow(
            label: SelfUpdate.watchdogLaunchdLabel,
            executablePath: script.path,
            timeout: 0.05
        )) { error in
            guard case UpdateError.processTimedOut = error else {
                return XCTFail("expected processTimedOut, got \(error)")
            }
        }
    }

    func testCompatibilityReloadCleansPartiallyBootstrappedHelperOnFailure() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchd-bootstrap-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        for label in [SelfUpdate.watchdogLaunchdLabel, SelfUpdate.launchdLabel] {
            try Data("plist".utf8).write(to: launchAgents.appendingPathComponent("\(label).plist"))
        }
        let helperLabel = SelfUpdate.providerReloadLaunchdLabel
        let helperPlist = launchAgents.appendingPathComponent("\(helperLabel).plist")
        var loaded = Set<String>()
        var commands: [([String], Bool)] = []

        XCTAssertThrowsError(try SelfUpdate.reloadCompatibilityLaunchdJobs(
            homeDirectory: home,
            uid: 501,
            serviceLoaded: { _ in false },
            servicePresent: { loaded.contains($0) },
            loadedServiceLabels: { Array(loaded) },
            runLaunchctl: { arguments, allowFailure in
                commands.append((arguments, allowFailure))
                if arguments == ["bootstrap", "gui/501", helperPlist.path] {
                    loaded.insert(helperLabel)
                    throw UpdateError.processFailed("launchctl bootstrap", 5)
                }
                if arguments == ["bootout", "gui/501/\(helperLabel)"] {
                    loaded.remove(helperLabel)
                }
            }
        ))

        XCTAssertFalse(loaded.contains(helperLabel))
        XCTAssertFalse(FileManager.default.fileExists(atPath: helperPlist.path))
        XCTAssertEqual(
            commands.filter {
                $0.0 == ["bootout", "gui/501/\(helperLabel)"] && $0.1
            }.count,
            2
        )
    }

    func testCompatibilityReloadFencesOnlyExactLegacyUUIDLabels() throws {
        let output = """
        PID\tStatus\tLabel
        -\t0\tlive.streamvc.macprovider-compatibility-reload.12345678-1234-1234-1234-123456789abc
        -\t0\tlive.streamvc.macprovider-compatibility-reload.not-a-uuid
        -\t0\tattacker.live.streamvc.macprovider-compatibility-reload.12345678-1234-1234-1234-123456789abc
        42\t0\tlive.streamvc.macprovider
        """

        let labels = SelfUpdate.launchctlServiceLabels(from: output)

        XCTAssertEqual(labels.count, 4)
        XCTAssertTrue(SelfUpdate.isLegacyProviderReloadLabel(labels[0]))
        XCTAssertFalse(SelfUpdate.isLegacyProviderReloadLabel(labels[1]))
        XCTAssertFalse(SelfUpdate.isLegacyProviderReloadLabel(labels[2]))
        XCTAssertFalse(SelfUpdate.isLegacyProviderReloadLabel(labels[3]))
        XCTAssertFalse(
            SelfUpdate.isLegacyProviderReloadLabel(
                "live.streamvc.macprovider-compatibility-reload.12345678-1234-1234-1234-123456789ABC"
            )
        )
    }

    func testLocalHealthRequiresStableHealthyTargetInstance() {
        let matching: [String: Any] = [
            "binary_version": "1.8.50",
            "compatibility_set_id": "set-50",
            "compatibility_set_sha256": String(repeating: "a", count: 64),
            "status": "ready",
            "service_instance": [
                "instance_id": "instance-a",
                "pid": 123,
            ],
        ]

        XCTAssertEqual(
            SelfUpdate.localHealthyTargetInstanceKey(
                matching,
                targetVersion: "1.8.50",
                expectedCompatibilitySetID: "set-50",
                expectedCompatibilitySetSHA256: String(repeating: "a", count: 64)
            ),
            "123:instance-a"
        )
        XCTAssertNil(
            SelfUpdate.localHealthyTargetInstanceKey(
                matching,
                targetVersion: "1.8.49",
                expectedCompatibilitySetID: "set-50",
                expectedCompatibilitySetSHA256: String(repeating: "a", count: 64)
            )
        )
        var missingDigest = matching
        missingDigest.removeValue(forKey: "compatibility_set_sha256")
        XCTAssertNil(
            SelfUpdate.localHealthyTargetInstanceKey(
                missingDigest,
                targetVersion: "1.8.50",
                expectedCompatibilitySetID: "set-50",
                expectedCompatibilitySetSHA256: String(repeating: "a", count: 64)
            )
        )
        XCTAssertNil(
            SelfUpdate.localHealthyTargetInstanceKey(
                matching,
                targetVersion: "1.8.50",
                expectedCompatibilitySetID: "set-49",
                expectedCompatibilitySetSHA256: String(repeating: "a", count: 64)
            )
        )
        XCTAssertNil(
            SelfUpdate.localHealthyTargetInstanceKey(
                matching,
                targetVersion: "1.8.50",
                expectedCompatibilitySetID: "set-50",
                expectedCompatibilitySetSHA256: String(repeating: "b", count: 64)
            )
        )
        var restarted = matching
        restarted["service_instance"] = [
            "instance_id": "instance-b",
            "pid": 456,
        ]
        XCTAssertEqual(
            SelfUpdate.localHealthyTargetInstanceKey(
                restarted,
                targetVersion: "1.8.50",
                expectedCompatibilitySetID: "set-50",
                expectedCompatibilitySetSHA256: String(repeating: "a", count: 64)
            ),
            "456:instance-b"
        )
        var unavailable = matching
        unavailable["status"] = "unavailable"
        XCTAssertNil(
            SelfUpdate.localHealthyTargetInstanceKey(
                unavailable,
                targetVersion: "1.8.50",
                expectedCompatibilitySetID: "set-50",
                expectedCompatibilitySetSHA256: String(repeating: "a", count: 64)
            )
        )
        XCTAssertEqual(SelfUpdate.localHealthRequiredConsecutiveSamples, 11)
    }

    func testRestartFailureRecoveryCommandReloadsBothCompatibilityJobs() {
        let home = URL(fileURLWithPath: "/Users/provider", isDirectory: true)

        let command = SelfUpdate.launchdRestartRecoveryCommand(homeDirectory: home, uid: 501)

        XCTAssertTrue(command.contains("launchctl bootout gui/501/live.streamvc.macprovider-watchdog"))
        XCTAssertTrue(command.contains("launchctl bootstrap gui/501 /Users/provider/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"))
        XCTAssertTrue(command.contains("launchctl bootout gui/501/live.streamvc.macprovider"))
        XCTAssertTrue(command.contains("launchctl bootstrap gui/501 /Users/provider/Library/LaunchAgents/live.streamvc.macprovider.plist"))
    }

    func testUpdateRequiresSignedChecksumAsset() async throws {
        let releaseURL = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!
        let tagURL = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/tags/v1.2.1")!
        MockURLProtocol.responses = [
            tagURL: (
                200,
                """
                {
                  "tag_name": "v1.2.1",
                  "assets": [
                    {
                      "name": "macprovider-cli-v1.2.1-darwin-arm64.tar.gz",
                      "browser_download_url": "https://github.com/Augustas11/macprovider/releases/download/v1.2.1/macprovider-cli-v1.2.1-darwin-arm64.tar.gz"
                    },
                    {
                      "name": "checksums.txt",
                      "browser_download_url": "https://github.com/Augustas11/macprovider/releases/download/v1.2.1/checksums.txt"
                    }
                  ]
                }
                """.data(using: .utf8)!
            ),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let update = SelfUpdate(currentVersion: "1.2.0", releasesAPIURL: releaseURL.absoluteString, session: session)

        do {
            try await update.runByTag(tag: "v1.2.1")
            XCTFail("update unexpectedly accepted a release without checksums.txt.sig")
        } catch let error as UpdateError {
            XCTAssertEqual(error.description, UpdateError.missingAsset.description)
        }
    }

    func testDefaultUpdateUsesBoundedAppendOnlyDiscoveryListing() async throws {
        let releaseURL = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!
        let discoveryURL = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases?per_page=20")!
        MockURLProtocol.responses = [
            discoveryURL: (
                200,
                """
                [{
                  "tag_name": "release-discovery-v1-200",
                  "draft": false,
                  "prerelease": true,
                  "immutable": true,
                  "assets": []
                }]
                """.data(using: .utf8)!
            ),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let update = SelfUpdate(currentVersion: "1.2.0", releasesAPIURL: releaseURL.absoluteString, session: session)

        do {
            try await update.run(checkOnly: true)
            XCTFail("update unexpectedly accepted a discovery transport without signed head assets")
        } catch let error as UpdateError {
            XCTAssertEqual(error.description, UpdateError.missingAsset.description)
        }
    }

    func testDiscoveryFailsClosedOnHighestMutableTransportWithoutFallingBack() async throws {
        let releaseURL = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!
        let discoveryURL = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases?per_page=20")!
        MockURLProtocol.responses = [
            discoveryURL: (
                200,
                """
                [
                  {
                    "tag_name": "release-discovery-v1-200",
                    "draft": false,
                    "prerelease": true,
                    "immutable": true,
                    "assets": []
                  },
                  {
                    "tag_name": "release-discovery-v1-201",
                    "draft": false,
                    "prerelease": true,
                    "immutable": false,
                    "assets": []
                  }
                ]
                """.data(using: .utf8)!
            ),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let update = SelfUpdate(currentVersion: "1.2.0", releasesAPIURL: releaseURL.absoluteString, session: session)

        do {
            try await update.run(checkOnly: true)
            XCTFail("update unexpectedly fell back from a mutable highest transport")
        } catch let error as UpdateError {
            XCTAssertEqual(
                error.description,
                UpdateError.discoveryHeadInvalid("transport_not_immutable").description
            )
        }
    }
}

private struct ReloadHelperScenarioResult {
    let status: Int32
    let log: [String]
    let providerPlistPath: String
    let providerPlistExists: Bool
    let helperPlistExists: Bool
}

private func runReloadHelperScenario(
    absentAfterCheck: Int?,
    maxChecks: Int,
    printFailureStatus: Int? = nil,
    hangOperation: String? = nil
) throws -> ReloadHelperScenarioResult {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("reload-helper-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let logURL = root.appendingPathComponent("commands.log")
    let countURL = root.appendingPathComponent("print-count")
    let launchctlURL = root.appendingPathComponent("launchctl")
    let sleepURL = root.appendingPathComponent("sleep")
    let commandSleepURL = root.appendingPathComponent("command-sleep")
    let providerPlist = root.appendingPathComponent("live.streamvc.macprovider.plist")
    let helperPlist = root.appendingPathComponent(
        "live.streamvc.macprovider-compatibility-reload.plist"
    )
    let absentAt = absentAfterCheck ?? (maxChecks + 1)
    let forcedPrintFailure = printFailureStatus.map { "exit \($0)" } ?? ":"
    let forcedHang = hangOperation.map {
        "if [ \"$1\" = \"\($0)\" ]; then trap '' TERM; while :; do :; done; fi"
    } ?? ":"
    let launchctl = """
    #!/bin/sh
    set -eu
    printf '%s\\n' "$*" >> '\(logURL.path)'
    \(forcedHang)
    if [ "$1" = "print" ]; then
      \(forcedPrintFailure)
      count=0
      if [ -f '\(countURL.path)' ]; then count=$(/bin/cat '\(countURL.path)'); fi
      count=$((count + 1))
      printf '%s\\n' "$count" > '\(countURL.path)'
      if [ "$count" -ge \(absentAt) ]; then
        printf '%s\\n' 'Could not find service' >&2
        exit 113
      fi
    fi
    exit 0
    """
    let sleep = """
    #!/bin/sh
    set -eu
    printf 'sleep %s\\n' "$*" >> '\(logURL.path)'
    """
    let commandSleep = """
    #!/bin/sh
    exit 0
    """
    try Data(launchctl.utf8).write(to: launchctlURL)
    try Data(sleep.utf8).write(to: sleepURL)
    try Data(commandSleep.utf8).write(to: commandSleepURL)
    try Data("provider".utf8).write(to: providerPlist)
    try Data("helper".utf8).write(to: helperPlist)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: launchctlURL.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: sleepURL.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: commandSleepURL.path
    )

    let data = try SelfUpdate.providerReloadLaunchAgentData(
        providerPlistPath: providerPlist.path,
        helperPlistPath: helperPlist.path,
        uid: 501,
        launchctlPath: launchctlURL.path,
        sleepPath: sleepURL.path,
        commandSleepPath: commandSleepURL.path,
        providerRemovalMaxChecks: maxChecks,
        commandTimeoutChecks: 3,
        commandTerminateGraceChecks: 2
    )
    let propertyList = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    let arguments = try XCTUnwrap(propertyList["ProgramArguments"] as? [String])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = Array(arguments.dropFirst())
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()

    let log = (try? String(contentsOf: logURL, encoding: .utf8))?
        .split(separator: "\n")
        .map(String.init) ?? []
    return ReloadHelperScenarioResult(
        status: process.terminationStatus,
        log: log,
        providerPlistPath: providerPlist.path,
        providerPlistExists: FileManager.default.fileExists(atPath: providerPlist.path),
        helperPlistExists: FileManager.default.fileExists(atPath: helperPlist.path)
    )
}

private final class UpdateActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [String] = []

    func append(_ action: String) {
        lock.lock()
        defer { lock.unlock() }
        actions.append(action)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }
}

private final class MockURLProtocol: URLProtocol {
    static var responses: [URL: (status: Int, body: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let response = Self.responses[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func withEnvironmentVariable(_ name: String, value: String, body: () -> Void) {
    let previous = getenv(name).map { String(cString: $0) }
    setenv(name, value, 1)
    defer {
        if let previous {
            setenv(name, previous, 1)
        } else {
            unsetenv(name)
        }
    }
    body()
}
