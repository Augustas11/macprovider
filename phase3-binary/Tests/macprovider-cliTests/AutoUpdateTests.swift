import CryptoKit
import Foundation
import XCTest
@testable import MacProviderCore
@testable import macprovider_cli

final class AutoUpdateTests: XCTestCase {
    func testAutoUpdaterServiceLoadedProbeFailsClosedOnTimeoutAndUnknownStatus() {
        let started = Date()
        XCTAssertFalse(AutoUpdater.launchctlServiceLoaded(
            label: SelfUpdate.launchdLabel,
            executablePath: "/usr/bin/yes",
            timeout: 0.05
        ))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertFalse(AutoUpdater.launchctlServiceLoaded(
            label: SelfUpdate.launchdLabel,
            executablePath: "/usr/bin/false",
            timeout: 0.5
        ))
    }

    func testFailureClassEnumMatchesSpecR65() {
        XCTAssertEqual(AutoUpdateFailureClass.allCases.map(\.rawValue), [
            "rollback_observer_unavailable",
            "target_release_not_found",
            "release_asset_missing",
            "recommended_version_invalid",
            "version_too_long",
            "version_component_too_long",
            "autoupdate_already_pending",
            "orphaned_pending_marker",
            "orphaned_success_sentinel",
            "rollback_backup_corrupt",
            "target_revoked_or_below_minimum",
            "signature_invalid",
            "checksum_mismatch",
            "release_payload_incomplete",
            "self_test_failed",
            "drain_timeout",
            "trust_state_lost",
            "post_start_crash",
            "post_start_health_failed",
            "post_start_network_unavailable",
            "post_start_network_not_ready",
            "rollback_target_disallowed",
            "discovery_head_replay",
            "discovery_head_equivocation",
            "discovery_head_expired",
            "insufficient_disk_space",
            "event_payload_too_large",
            "other",
        ])
    }

    func testRecommendedVersionValidationNormalizesAndRejectsOversize() throws {
        XCTAssertEqual(try AutoUpdateRecommendation.validate("v1.7.0").normalized, "1.7.0")
        XCTAssertEqual(try AutoUpdateRecommendation.validate("V1.7.0").normalized, "1.7.0")
        XCTAssertThrowsError(try AutoUpdateRecommendation.validate("1.7")) { error in
            XCTAssertEqual(error as? AutoUpdateValidationError, .invalid)
        }
        XCTAssertThrowsError(try AutoUpdateRecommendation.validate("1.123456789.0")) { error in
            XCTAssertEqual(error as? AutoUpdateValidationError, .componentTooLong)
        }
        let oversized = "v" + String(repeating: "1", count: 40) + ".2.3"
        XCTAssertThrowsError(try AutoUpdateRecommendation.validate(oversized)) { error in
            guard case let AutoUpdateValidationError.versionTooLong(sha)? = error as? AutoUpdateValidationError else {
                return XCTFail("expected versionTooLong, got \(error)")
            }
            XCTAssertEqual(sha.count, 64)
            XCTAssertEqual(sha, AutoUpdateEvent.sha256Hex(oversized))
        }
    }

    func testEventPayloadDropsOptionalFieldsBeforeFallback() {
        let event = AutoUpdateEvent(
            updateID: UUID().uuidString.lowercased(),
            currentVersion: "1.6.1",
            targetVersion: "1.7.0",
            phase: .download,
            outcome: .failure,
            reason: String(repeating: "reason", count: 1200),
            attempt: 2,
            failureClass: .targetReleaseNotFound,
            extraMetadata: ["blob": String(repeating: "x", count: 5000)],
            attemptHistory: [String(repeating: "y", count: 5000)],
            releaseURL: "https://github.com/Augustas11/macprovider/releases/download/v1.7.0/a.tar.gz?token=secret"
        )
        let object = event.wireObject()
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        XCTAssertLessThanOrEqual(data.count, AutoUpdateEvent.maxWireBytes)
        XCTAssertNil(object["extra_metadata"])
        XCTAssertNil(object["attempt_history"])
        XCTAssertNil(object["release_url"])
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("token=secret"))
    }

    func testEventPayloadTooLargeFallsBackToMinimalStablePayload() {
        let event = AutoUpdateEvent(
            updateID: UUID().uuidString.lowercased(),
            currentVersion: String(repeating: "1", count: 5000),
            targetVersion: "1.7.0",
            phase: .rollback,
            outcome: .failure,
            reason: String(repeating: "oversized", count: 1200),
            attempt: 1,
            failureClass: .orphanedPendingMarker,
            inflightRequests: 42,
            recommendedBinaryVersionSHA256: String(repeating: "a", count: 5000),
            extraMetadata: ["blob": String(repeating: "x", count: 5000)],
            attemptHistory: [String(repeating: "y", count: 5000)],
            releaseURL: "https://github.com/Augustas11/macprovider/releases/download/v1.7.0/a.tar.gz?token=secret"
        )

        let object = event.wireObject()
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])

        XCTAssertLessThanOrEqual(data.count, AutoUpdateEvent.maxWireBytes)
        XCTAssertEqual(object["reason"] as? String, "event_payload_too_large")
        XCTAssertEqual(object["failure_class"] as? String, AutoUpdateFailureClass.eventPayloadTooLarge.rawValue)
        XCTAssertNil(object["extra_metadata"])
        XCTAssertNil(object["attempt_history"])
        XCTAssertNil(object["release_url"])
        XCTAssertNil(object["inflight_requests"])
        XCTAssertNil(object["recommended_binary_version_sha256"])
    }

    func testAutoupdateOptOutReadsLegacyAndSpecSources() throws {
        let yaml = """
        coordinator_url: wss://example.invalid/ws/provider
        autoupdate:
          enabled: false
        auto_update_enabled: true
        """
        let config = try ConfigLoader.load(
            cli: CLIOverrides(configPath: "/tmp/provider.yaml"),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in yaml }
        )
        XCTAssertFalse(AutoUpdateConfig.enabled(config))

        let env = try ConfigLoader.load(
            cli: CLIOverrides(),
            environment: ["MACPROVIDER_AUTOUPDATE": "off"],
            fileExists: { _ in false },
            readFile: { _ in "" }
        )
        XCTAssertFalse(AutoUpdateConfig.enabled(env))
    }

    func testCooldownBackoffIsKeyedByTargetAndFailureClass() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        store.recordCooldown(target: "1.7.0", failureClass: .targetReleaseNotFound)
        let first = try XCTUnwrap(store.cooldown(target: "1.7.0", failureClass: .targetReleaseNotFound))
        XCTAssertEqual(first.attempt, 1)
        XCTAssertGreaterThan(first.until.timeIntervalSinceNow, 250)
        XCTAssertNil(store.cooldown(target: "1.7.0", failureClass: .signatureInvalid))
        XCTAssertEqual(store.activeCooldown(target: "1.7.0")?.failureClass, .targetReleaseNotFound)
        store.recordCooldown(target: "1.7.0", failureClass: .targetReleaseNotFound)
        let second = try XCTUnwrap(store.cooldown(target: "1.7.0", failureClass: .targetReleaseNotFound))
        XCTAssertEqual(second.attempt, 2)
        XCTAssertGreaterThan(second.until.timeIntervalSince(first.until), 250)
        store.recordCooldown(target: "1.7.0", failureClass: .targetReleaseNotFound)
        let third = try XCTUnwrap(store.cooldown(target: "1.7.0", failureClass: .targetReleaseNotFound))
        XCTAssertEqual(third.attempt, 3)
        XCTAssertGreaterThan(third.until.timeIntervalSinceNow, 1_000)
        store.recordCooldown(target: "1.7.0", failureClass: .targetReleaseNotFound)
        let fourth = try XCTUnwrap(store.cooldown(target: "1.7.0", failureClass: .targetReleaseNotFound))
        XCTAssertEqual(fourth.attempt, 4)
        XCTAssertLessThan(fourth.until.timeIntervalSinceNow, 3_700)
    }

    func testSuccessCleanupLeavesSentinelUntilFinalize() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        _ = try store.acquireLock()
        let binaryDir = fixture.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let binary = binaryDir.appendingPathComponent("macprovider-cli")
        let backup = binaryDir.appendingPathComponent(".macprovider-cli.rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        try Data("new".utf8).write(to: binary)
        try Data("old".utf8).write(to: backup)
        let marker = AutoUpdatePendingMarker(
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0",
            targetPath: binary.path,
            backupPath: backup.path,
            size: 3,
            mode: 0o755,
            sha256: AutoUpdateEvent.sha256Hex("old"),
            markerDeadline: ISO8601DateFormatter.autoupdateTest.string(from: Date().addingTimeInterval(300))
        )
        try store.writePending(marker)

        XCTAssertFalse(store.updateLockIsLive())
        XCTAssertThrowsError(try store.acquireLock()) { error in
            XCTAssertEqual(error as? AutoUpdateMarkerError, .transactionPending)
        }

        try store.completeSuccessfulUpdate(marker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.successSentinelPath(binaryURL: binary, updateID: marker.updateID).path))

        try store.finalizeSuccessfulUpdate(marker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.successSentinelPath(binaryURL: binary, updateID: marker.updateID).path))
    }

    func testProviderMutationOuterLockSerializesSwiftMutators() throws {
        let fixture = try TempHome()
        let first = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let second = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let lock = try first.acquireLock()

        XCTAssertTrue(second.updateLockIsLive())
        XCTAssertThrowsError(try second.acquireLock()) { error in
            XCTAssertEqual(error as? AutoUpdateMarkerError, .lockContended)
        }
        withExtendedLifetime(lock) {}
    }

    func testProviderMutationLocksAreNormalizedToExactPrivateMode() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let lock = try store.acquireLock()

        for path in [store.installerLockURL.path, store.lockURL.path] {
            var info = stat()
            XCTAssertEqual(lstat(path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)
            XCTAssertEqual(info.st_nlink, 1)
        }
        withExtendedLifetime(lock) {}
    }

    func testInnerProviderMutationLockRejectsHardlinkFIFOAndReadableMode() throws {
        enum UnsafeLockKind: String, CaseIterable {
            case hardlink
            case fifo
            case readable
        }

        for kind in UnsafeLockKind.allCases {
            let fixture = try TempHome()
            let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
            var initial: AutoUpdateLock? = try store.acquireLock()
            initial = nil
            try FileManager.default.removeItem(at: store.lockURL)

            switch kind {
            case .hardlink:
                let source = store.root.appendingPathComponent("lock-source")
                try Data().write(to: source)
                XCTAssertEqual(link(source.path, store.lockURL.path), 0)
            case .fifo:
                XCTAssertEqual(mkfifo(store.lockURL.path, 0o600), 0)
            case .readable:
                try Data().write(to: store.lockURL)
                XCTAssertEqual(chmod(store.lockURL.path, 0o644), 0)
            }

            XCTAssertTrue(store.updateLockIsLive(), "\(kind.rawValue) lock must fail closed")
            XCTAssertThrowsError(try store.acquireLock(), "\(kind.rawValue) lock must be rejected") { error in
                XCTAssertEqual(
                    error as? AutoUpdateMarkerError,
                    .trustedRootInvalid("provider_mutation_inner_lock_invalid")
                )
            }
        }
    }

    func testOuterProviderMutationLockRejectsReadableMode() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        var initial: AutoUpdateLock? = try store.acquireLock()
        initial = nil
        XCTAssertEqual(chmod(store.installerLockURL.path, 0o644), 0)

        XCTAssertThrowsError(try store.acquireLock()) { error in
            XCTAssertEqual(
                error as? AutoUpdateMarkerError,
                .trustedRootInvalid("provider_mutation_outer_lock_invalid")
            )
        }
    }

    func testRecoveryCommitHoldsStableOuterAndInnerLockDomain() throws {
        let fixture = try TempHome()
        let first = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let second = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, _, backup) = try makePendingMarkerFixture(
            store: first,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )
        var before = stat()
        XCTAssertEqual(lstat(first.lockURL.path, &before), 0)

        var held: AutoUpdateLock? = try first.acquireRecoveryLock()
        XCTAssertThrowsError(try second.acquireRecoveryLock()) { error in
            XCTAssertEqual(error as? AutoUpdateMarkerError, .lockContended)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        held = nil
        let committer = try second.acquireRecoveryLock()
        let current = try XCTUnwrap(second.readPending())
        XCTAssertEqual(current, marker)
        try second.completeSuccessfulUpdate(current)
        try second.finalizeSuccessfulUpdate(current)
        withExtendedLifetime(committer) {}

        var after = stat()
        XCTAssertEqual(lstat(first.lockURL.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testLiveInstallerOwnerFencesMutationAndRecoveryAfterHelperSIGKILL() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(
            homeDirectory: fixture.url,
            installerOwnerLiveOverride: { true }
        )

        XCTAssertTrue(store.updateLockIsLive())
        XCTAssertThrowsError(try store.acquireLock()) { error in
            XCTAssertEqual(error as? AutoUpdateMarkerError, .lockContended)
        }
    }

    func testOrphanPendingMarkerWithValidBackupRestoresBeforeCleanup() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, binary, backup) = try makePendingMarkerFixture(store: store, fixture: fixture, backupContents: "old", targetContents: "new")

        let outcome = store.recoverOrphanedMarker(marker)

        XCTAssertEqual(outcome, .restored(marker))
        XCTAssertEqual(try String(contentsOf: binary), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertEqual(store.cooldown(target: marker.targetVersion, failureClass: .orphanedPendingMarker)?.attempt, 1)
    }

    func testExpiredPendingMarkerStillRestoresFromBackup() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        var (marker, binary, backup) = try makePendingMarkerFixture(store: store, fixture: fixture, backupContents: "old", targetContents: "new")
        marker = AutoUpdatePendingMarker(
            updateID: marker.updateID,
            targetVersion: marker.targetVersion,
            targetPath: marker.targetPath,
            backupPath: marker.backupPath,
            size: marker.size,
            mode: marker.mode,
            sha256: marker.sha256,
            markerDeadline: ISO8601DateFormatter.autoupdateTest.string(from: Date().addingTimeInterval(-3_600))
        )
        try store.writePending(marker)

        let outcome = store.recoverOrphanedMarker(marker)

        XCTAssertEqual(outcome, .restored(marker))
        XCTAssertEqual(try String(contentsOf: binary), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testFullReleasePendingMarkerRestoresAllOwnedResourcesAndRemovesNewOnlyBundle() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let binaryDirectory = fixture.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let binary = binaryDirectory.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try writeOwnedReleaseResources(in: binaryDirectory, prefix: "old")

        let marker = try store.preserveReleaseRollbackBackup(
            binaryURL: binary,
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0"
        )
        try store.writePending(marker)
        try Data("new-binary".utf8).write(to: binary)
        try replaceOwnedReleaseResources(in: binaryDirectory, prefix: "new")
        let newOnlyBundle = binaryDirectory.appendingPathComponent("NewOnly.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: newOnlyBundle, withIntermediateDirectories: false)
        try Data("new-only".utf8).write(to: newOnlyBundle.appendingPathComponent("resource"))

        let outcome = store.recoverOrphanedMarker(marker)

        XCTAssertEqual(outcome, .restored(marker))
        XCTAssertEqual(try String(contentsOf: binary), "old-binary")
        XCTAssertEqual(try String(contentsOf: binaryDirectory.appendingPathComponent("mlx.metallib")), "old-metal")
        XCTAssertEqual(try String(contentsOf: binaryDirectory.appendingPathComponent("THIRD-PARTY-NOTICES.txt")), "old-notices")
        XCTAssertEqual(
            try String(contentsOf: binaryDirectory.appendingPathComponent("Runtime.bundle/resource")),
            "old-bundle"
        )
        XCTAssertEqual(
            try String(contentsOf: binaryDirectory.appendingPathComponent("catalog-release/release.json")),
            "old-catalog"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: newOnlyBundle.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.backupPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.releaseBackupPath ?? ""))
    }

    func testExactCompatibilityRollbackRetainsSnapshotsUntilPreviousSetReadinessCommit() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let binaryDirectory = fixture.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let binary = binaryDirectory.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try writeOwnedReleaseResources(in: binaryDirectory, prefix: "old")
        let legacyMarker = try store.preserveReleaseRollbackBackup(
            binaryURL: binary,
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0"
        )
        let marker = AutoUpdatePendingMarker(
            updateID: legacyMarker.updateID,
            targetVersion: legacyMarker.targetVersion,
            targetPath: legacyMarker.targetPath,
            backupPath: legacyMarker.backupPath,
            size: legacyMarker.size,
            mode: legacyMarker.mode,
            sha256: legacyMarker.sha256,
            markerDeadline: ISO8601DateFormatter.autoupdateTest.string(
                from: Date().addingTimeInterval(-1)
            ),
            releaseBackupPath: legacyMarker.releaseBackupPath,
            releaseBackupSHA256: legacyMarker.releaseBackupSHA256,
            commitOwner: "coordinator",
            targetCompatibilitySetID: "Augustas11/macprovider:v1.7.0@fedcba9876543210fedcba9876543210fedcba98",
            targetCompatibilitySetSHA256: String(repeating: "7", count: 64),
            previousVersion: "1.6.0",
            previousCompatibilitySetID: "Augustas11/macprovider:v1.6.0@0123456789abcdef0123456789abcdef01234567",
            previousCompatibilitySetSHA256: String(repeating: "6", count: 64),
            transactionState: .activatingTarget
        )
        try store.writePending(marker)
        try Data("new-binary".utf8).write(to: binary)
        try replaceOwnedReleaseResources(in: binaryDirectory, prefix: "new")

        let outcome = store.recoverOrphanedMarker(marker)
        guard case .restoredAwaitingReadiness(let awaiting) = outcome else {
            return XCTFail("expected restoredAwaitingReadiness, got \(outcome)")
        }
        XCTAssertEqual(awaiting.transactionState, .awaitingPreviousReadiness)
        XCTAssertEqual(try String(contentsOf: binary), "old-binary")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.backupPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.releaseBackupPath ?? ""))

        try store.completeRestoredPreviousSet(awaiting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.backupPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.releaseBackupPath ?? ""))
    }

    func testFullReleasePendingMarkerRejectsTamperedResourceSnapshot() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let binaryDirectory = fixture.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let binary = binaryDirectory.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try writeOwnedReleaseResources(in: binaryDirectory, prefix: "old")
        let marker = try store.preserveReleaseRollbackBackup(
            binaryURL: binary,
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0"
        )
        try store.writePending(marker)
        try Data("new-binary".utf8).write(to: binary)
        try replaceOwnedReleaseResources(in: binaryDirectory, prefix: "new")
        let releaseBackup = URL(fileURLWithPath: try XCTUnwrap(marker.releaseBackupPath), isDirectory: true)
            .appendingPathComponent("mlx.metallib")
        try Data("tampered".utf8).write(to: releaseBackup)

        let outcome = store.recoverOrphanedMarker(marker)

        guard case .backupCorrupt = outcome else {
            return XCTFail("expected backupCorrupt, got \(outcome)")
        }
        XCTAssertEqual(try String(contentsOf: binary), "new-binary")
        XCTAssertEqual(try String(contentsOf: binaryDirectory.appendingPathComponent("mlx.metallib")), "new-metal")
    }

    func testReleasePayloadActivationAndRollbackKeepBinaryResourcesAndCatalogTogether() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let live = fixture.url.appendingPathComponent("bin", isDirectory: true)
        let payload = fixture.url.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let liveBinary = live.appendingPathComponent("macprovider-cli")
        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: liveBinary)
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try writeOwnedReleaseResources(in: live, prefix: "old")
        try writeOwnedReleaseResources(in: payload, prefix: "new")
        let launchAgents = fixture.url.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let watchdogDirectory = fixture.url.appendingPathComponent(".local/share/macprovider-watchdog", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: watchdogDirectory, withIntermediateDirectories: true)
        let providerPlist = launchAgents.appendingPathComponent("live.streamvc.macprovider.plist")
        let watchdogScript = watchdogDirectory.appendingPathComponent("macprovider-health-monitor")
        let watchdogPlist = launchAgents.appendingPathComponent("live.streamvc.macprovider-watchdog.plist")
        try Data("old-provider-plist".utf8).write(to: providerPlist)
        try Data("old-watchdog".utf8).write(to: watchdogScript)
        try installedWatchdogPlist(home: fixture.url, installDirectory: live).write(to: watchdogPlist)
        let marker = try store.preserveReleaseRollbackBackup(
            binaryURL: liveBinary,
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0"
        )
        try store.writePending(marker)

        try store.activateReleasePayload(from: payload, newBinary: newBinary, to: liveBinary)
        XCTAssertEqual(try String(contentsOf: liveBinary), "new-binary")
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("mlx.metallib")), "new-metal")
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("catalog-release/release.json")), "new-catalog")
        XCTAssertEqual(
            try String(contentsOf: live.appendingPathComponent(CompatibilitySetManifest.fileName)),
            "new-compatibility-set"
        )
        XCTAssertEqual(try String(contentsOf: watchdogScript), "new-watchdog")
        XCTAssertTrue(try String(contentsOf: providerPlist).contains("live.streamvc.macprovider"))
        XCTAssertTrue(try String(contentsOf: watchdogPlist).contains("live.streamvc.macprovider-watchdog"))

        try store.restoreBackup(marker)
        XCTAssertEqual(try String(contentsOf: liveBinary), "old-binary")
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("mlx.metallib")), "old-metal")
        XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("catalog-release/release.json")), "old-catalog")
        XCTAssertEqual(
            try String(contentsOf: live.appendingPathComponent(CompatibilitySetManifest.fileName)),
            "old-compatibility-set"
        )
        XCTAssertEqual(try String(contentsOf: providerPlist), "old-provider-plist")
        XCTAssertEqual(try String(contentsOf: watchdogScript), "old-watchdog")
        XCTAssertEqual(
            try Data(contentsOf: watchdogPlist),
            try installedWatchdogPlist(home: fixture.url, installDirectory: live)
        )
    }

    func testActivationConvergesStalePathEntrypointCopyWithNoSiblingSetToSymlink() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let live = fixture.url.appendingPathComponent("bin", isDirectory: true)
        let payload = fixture.url.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let liveBinary = live.appendingPathComponent("macprovider-cli")
        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: liveBinary)
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try writeOwnedReleaseResources(in: live, prefix: "old")
        try writeOwnedReleaseResources(in: payload, prefix: "new")

        // Legacy pre-symlink install: a standalone stale copy at the PATH
        // entrypoint with no sibling compatibility-set.json (the exact #616
        // reproduction).
        let localBin = fixture.url.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entrypoint = localBin.appendingPathComponent("macprovider-cli")
        try Data("stale-path-copy".utf8).write(to: entrypoint)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localBin.appendingPathComponent(CompatibilitySetManifest.fileName).path))

        let marker = try store.preserveReleaseRollbackBackup(
            binaryURL: liveBinary,
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0"
        )
        try store.writePending(marker)

        try store.activateReleasePayload(from: payload, newBinary: newBinary, to: liveBinary)

        var entrypointInfo = stat()
        XCTAssertEqual(lstat(entrypoint.path, &entrypointInfo), 0)
        XCTAssertEqual(entrypointInfo.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: entrypoint.path),
            liveBinary.path
        )
        XCTAssertEqual(try String(contentsOf: entrypoint), "new-binary")
        // The PATH entrypoint must now resolve to a sibling compatibility-set.json --
        // the exact gap the issue reports ("PATH binary ... no sibling set").
        let resolvedDirectory = entrypoint.resolvingSymlinksInPath().deletingLastPathComponent()
        XCTAssertEqual(resolvedDirectory.standardizedFileURL, live.standardizedFileURL)
        XCTAssertEqual(
            try String(contentsOf: resolvedDirectory.appendingPathComponent(CompatibilitySetManifest.fileName)),
            "new-compatibility-set"
        )
    }

    func testActivationIsIdempotentWhenPathEntrypointAlreadyConverged() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let live = fixture.url.appendingPathComponent("bin", isDirectory: true)
        let payload = fixture.url.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let liveBinary = live.appendingPathComponent("macprovider-cli")
        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: liveBinary)
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try writeOwnedReleaseResources(in: live, prefix: "old")
        try writeOwnedReleaseResources(in: payload, prefix: "new")

        let localBin = fixture.url.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entrypoint = localBin.appendingPathComponent("macprovider-cli")
        try FileManager.default.createSymbolicLink(at: entrypoint, withDestinationURL: liveBinary)

        let marker = try store.preserveReleaseRollbackBackup(
            binaryURL: liveBinary,
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0"
        )
        try store.writePending(marker)

        // Already converged: activation must not need to touch the
        // entrypoint again; the symlink identity is preserved exactly.
        try store.activateReleasePayload(from: payload, newBinary: newBinary, to: liveBinary)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: entrypoint.path),
            liveBinary.path
        )
        XCTAssertEqual(try String(contentsOf: entrypoint), "new-binary")
    }

    func testActivationSkipsPathEntrypointConvergenceWhenNoneIsInstalled() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let live = fixture.url.appendingPathComponent("bin", isDirectory: true)
        let payload = fixture.url.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let liveBinary = live.appendingPathComponent("macprovider-cli")
        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: liveBinary)
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try writeOwnedReleaseResources(in: live, prefix: "old")
        try writeOwnedReleaseResources(in: payload, prefix: "new")
        // No ~/.local/bin at all: nothing to converge, must not be created here.

        let marker = try store.preserveReleaseRollbackBackup(
            binaryURL: liveBinary,
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0"
        )
        try store.writePending(marker)

        try store.activateReleasePayload(from: payload, newBinary: newBinary, to: liveBinary)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent(".local/bin").path))
    }

    func testActivationFailsClosedWhenPathEntrypointDirectoryIsUnsafe() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let live = fixture.url.appendingPathComponent("bin", isDirectory: true)
        let payload = fixture.url.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let liveBinary = live.appendingPathComponent("macprovider-cli")
        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: liveBinary)
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try writeOwnedReleaseResources(in: live, prefix: "old")
        try writeOwnedReleaseResources(in: payload, prefix: "new")

        // A world-writable ~/.local/bin is unsafe to repair into: activation
        // must fail closed (and the caller rolls back) rather than silently
        // declare success with a mixed PATH/payload state.
        let localBin = fixture.url.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        let entrypoint = localBin.appendingPathComponent("macprovider-cli")
        try Data("stale-path-copy".utf8).write(to: entrypoint)

        let marker = try store.preserveReleaseRollbackBackup(
            binaryURL: liveBinary,
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0"
        )
        try store.writePending(marker)

        XCTAssertThrowsError(
            try store.activateReleasePayload(from: payload, newBinary: newBinary, to: liveBinary)
        ) { error in
            guard case AutoUpdateMarkerError.trustedRootInvalid = error else {
                return XCTFail("expected trustedRootInvalid, got \(error)")
            }
        }
        // The stale copy must be left untouched rather than partially repaired.
        XCTAssertEqual(try String(contentsOf: entrypoint), "stale-path-copy")

        // Rollback restores the canonical binary, then must also refuse to
        // leave PATH divergent when the entrypoint directory is unsafe.
        XCTAssertThrowsError(try store.restoreBackup(marker)) { error in
            guard case AutoUpdateMarkerError.trustedRootInvalid = error else {
                return XCTFail("expected trustedRootInvalid on rollback PATH converge, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: liveBinary), "old-binary")
        XCTAssertEqual(try String(contentsOf: entrypoint), "stale-path-copy")
    }

    func testRestoreBackupReConvergesPathEntrypointToRestoredCanonicalBinary() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let live = fixture.url.appendingPathComponent("macprovider", isDirectory: true)
        let payload = fixture.url.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let liveBinary = live.appendingPathComponent("macprovider-cli")
        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: liveBinary)
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try writeOwnedReleaseResources(in: live, prefix: "old")
        try writeOwnedReleaseResources(in: payload, prefix: "new")

        let localBin = fixture.url.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entrypoint = localBin.appendingPathComponent("macprovider-cli")
        try Data("stale-path-copy".utf8).write(to: entrypoint)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)

        let marker = try store.preserveReleaseRollbackBackup(
            binaryURL: liveBinary,
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0"
        )
        try store.writePending(marker)
        try store.activateReleasePayload(from: payload, newBinary: newBinary, to: liveBinary)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: entrypoint.path),
            liveBinary.path
        )
        XCTAssertEqual(try String(contentsOf: entrypoint), "new-binary")

        try store.restoreBackup(marker)
        XCTAssertEqual(try String(contentsOf: liveBinary), "old-binary")
        var entrypointInfo = stat()
        XCTAssertEqual(lstat(entrypoint.path, &entrypointInfo), 0)
        XCTAssertEqual(entrypointInfo.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: entrypoint.path),
            liveBinary.path
        )
        XCTAssertEqual(try String(contentsOf: entrypoint), "old-binary")
    }

    func testResolveCanonicalInstallBinaryPrefersInstallerContractOverStalePathCopy() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let install = fixture.url.appendingPathComponent("macprovider", isDirectory: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let canonical = install.appendingPathComponent("macprovider-cli")
        try Data("canonical-binary".utf8).write(to: canonical)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: canonical.path)

        let localBin = fixture.url.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entrypoint = localBin.appendingPathComponent("macprovider-cli")
        try Data("stale-path-copy".utf8).write(to: entrypoint)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)

        let resolved = store.resolveCanonicalInstallBinary(launchedExecutableURL: entrypoint)
        XCTAssertEqual(resolved?.standardizedFileURL, canonical.standardizedFileURL)
        XCTAssertNotEqual(resolved?.standardizedFileURL, entrypoint.standardizedFileURL)
    }

    func testResolveCanonicalInstallBinaryPrefersLaunchdProgramArguments() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let install = fixture.url.appendingPathComponent("macprovider", isDirectory: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let canonical = install.appendingPathComponent("macprovider-cli")
        try Data("canonical-binary".utf8).write(to: canonical)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: canonical.path)

        let other = fixture.url.appendingPathComponent("other-install", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let otherBinary = other.appendingPathComponent("macprovider-cli")
        try Data("other-binary".utf8).write(to: otherBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: otherBinary.path)

        let launchAgents = fixture.url.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "live.streamvc.macprovider",
                "ProgramArguments": [
                    otherBinary.path,
                    "serve",
                    "--config",
                    fixture.url.appendingPathComponent(".config/macprovider/config.yaml").path,
                ],
                "WorkingDirectory": other.path,
            ],
            format: .xml,
            options: 0
        )
        try plist.write(to: launchAgents.appendingPathComponent("live.streamvc.macprovider.plist"))

        let localBin = fixture.url.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entrypoint = localBin.appendingPathComponent("macprovider-cli")
        try Data("stale-path-copy".utf8).write(to: entrypoint)

        let resolved = store.resolveCanonicalInstallBinary(launchedExecutableURL: entrypoint)
        XCTAssertEqual(resolved?.standardizedFileURL, otherBinary.standardizedFileURL)
    }

    func testActivationFromStalePathLaunchStillActivatesCanonicalInstallAndConvergesPath() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let live = fixture.url.appendingPathComponent("macprovider", isDirectory: true)
        let payload = fixture.url.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let liveBinary = live.appendingPathComponent("macprovider-cli")
        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: liveBinary)
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try writeOwnedReleaseResources(in: live, prefix: "old")
        try writeOwnedReleaseResources(in: payload, prefix: "new")

        let localBin = fixture.url.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entrypoint = localBin.appendingPathComponent("macprovider-cli")
        try Data("stale-path-copy".utf8).write(to: entrypoint)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)

        // Simulate SelfUpdate/AutoUpdater resolving authority while launched
        // from the stale PATH regular copy (no sibling compatibility-set).
        let current = try XCTUnwrap(
            store.resolveCanonicalInstallBinary(launchedExecutableURL: entrypoint)
        )
        XCTAssertEqual(current.standardizedFileURL, liveBinary.standardizedFileURL)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: entrypoint.deletingLastPathComponent()
                    .appendingPathComponent(CompatibilitySetManifest.fileName).path
            )
        )

        let marker = try store.preserveReleaseRollbackBackup(
            binaryURL: current,
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0"
        )
        try store.writePending(marker)
        try store.activateReleasePayload(from: payload, newBinary: newBinary, to: current)

        XCTAssertEqual(try String(contentsOf: liveBinary), "new-binary")
        XCTAssertEqual(
            try String(contentsOf: live.appendingPathComponent(CompatibilitySetManifest.fileName)),
            "new-compatibility-set"
        )
        var entrypointInfo = stat()
        XCTAssertEqual(lstat(entrypoint.path, &entrypointInfo), 0)
        XCTAssertEqual(entrypointInfo.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: entrypoint.path),
            liveBinary.path
        )
        XCTAssertEqual(try String(contentsOf: entrypoint), "new-binary")
    }

    func testAutoUpdaterPathConvergeFailureRollsBackCanonicalBinary() async throws {
        let fixture = try TempHome()
        let manifestSigningKey = P256.Signing.PrivateKey()
        let manifestPublicKey = manifestSigningKey.publicKey.pemRepresentation
        let store = AutoUpdateMarkerStore(
            homeDirectory: fixture.url,
            compatibilityManifestPublicKeyPEM: manifestPublicKey
        )
        try store.ensureTrustedRoot()
        let binaryDirectory = fixture.url.appendingPathComponent("macprovider", isDirectory: true)
        let payload = fixture.url.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: payload,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let binary = binaryDirectory.appendingPathComponent("macprovider-cli")
        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: binary)
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try writeOwnedReleaseResources(in: binaryDirectory, prefix: "old")
        try writeOwnedReleaseResources(in: payload, prefix: "new")
        _ = try CompatibilityManifestFixture(
            root: binaryDirectory,
            privateKey: manifestSigningKey,
            version: "1.8.48",
            providerCLIVersion: "1.8.48",
            malibuAppVersion: "1.8.43",
            commit: "1111111111111111111111111111111111111111",
            populateResources: false
        )
        let manifestFixture = try CompatibilityManifestFixture(
            root: payload,
            privateKey: manifestSigningKey,
            version: "1.8.50",
            providerCLIVersion: "1.8.50",
            malibuAppVersion: "1.8.43",
            commit: "2222222222222222222222222222222222222222",
            populateResources: false
        )
        let manifest = try CompatibilitySetManifest.loadValidated(
            from: payload,
            expectedProviderVersion: "1.8.50",
            publicKeyPEM: manifestPublicKey
        )
        XCTAssertEqual(manifest.compatibilitySetID, manifestFixture.compatibilitySetID)

        // Unsafe PATH directory forces converge failure during activation.
        let localBin = fixture.url.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        let entrypoint = localBin.appendingPathComponent("macprovider-cli")
        try Data("stale-path-copy".utf8).write(to: entrypoint)

        let prepared = PreparedSelfUpdate(
            tempDir: fixture.url,
            newBinary: newBinary,
            stagedMalibuApp: nil,
            signedPolicy: nil,
            compatibilityManifest: manifest,
            artifactIndexSHA256: String(repeating: "a", count: 64)
        )
        let head = SignedReleaseDiscoveryHead(
            releaseSequence: 12,
            targetVersion: "1.8.50",
            targetCompatibilitySetID: manifest.compatibilitySetID,
            targetArtifactIndexSHA256: prepared.artifactIndexSHA256,
            signedPolicyMinimum: nil,
            signedPolicyRevoked: [],
            issuedAt: Date().addingTimeInterval(-30),
            expiresAt: Date().addingTimeInterval(300),
            digest: String(repeating: "b", count: 64)
        )
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.8.48",
            providerStatus: status,
            markerStore: store,
            trustProvider: {
                AutoUpdateTrustState(
                    v2Accepted: false,
                    tier: nil,
                    encryptedLegValid: false,
                    attestationRequired: false,
                    attestationSatisfied: false,
                    tokenConfigured: true,
                    tokenValidated: false,
                    bearerlessDuplicate: false,
                    connected: false,
                    stableReason: "coordinator_disconnected"
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: {},
            fenceReloadJobs: {},
            currentBinaryURL: {
                store.resolveCanonicalInstallBinary(launchedExecutableURL: entrypoint)
            },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { false }
        )

        do {
            try await updater.preserveMarkerAndSwapForTest(
                updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                target: "1.8.50",
                prepared: prepared,
                authorityMode: "signed_discovery_head",
                discoveryHead: head,
                requireCurrentTrustAtSwap: false
            )
            XCTFail("expected PATH converge failure to abort activation")
        } catch {
            // Production caller path must restore the canonical binary even when
            // PATH re-converge on rollback also fails closed (unsafe directory).
        }

        XCTAssertEqual(try String(contentsOf: binary), "old-binary")
        XCTAssertEqual(
            try String(contentsOf: binaryDirectory.appendingPathComponent("mlx.metallib")),
            "old-metal"
        )
        // Entrypoint left untouched under unsafe PATH directory (fail closed).
        XCTAssertEqual(try String(contentsOf: entrypoint), "stale-path-copy")
    }

    func testInterruptedCompatibilitySetCutoverRecoversAtEveryDestructivePhase() throws {
        for phase in CompatibilitySetCutoverPhase.allCases {
            let fixture = try TempHome()
            let manifestSigningKey = P256.Signing.PrivateKey()
            let manifestPublicKey = manifestSigningKey.publicKey.pemRepresentation
            let store = AutoUpdateMarkerStore(
                homeDirectory: fixture.url,
                compatibilityManifestPublicKeyPEM: manifestPublicKey
            )
            try store.ensureTrustedRoot()
            let live = fixture.url.appendingPathComponent("bin", isDirectory: true)
            let payload = fixture.url.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let liveBinary = live.appendingPathComponent("macprovider-cli")
            let newBinary = payload.appendingPathComponent("macprovider-cli")
            try Data("old-binary".utf8).write(to: liveBinary)
            try Data("new-binary".utf8).write(to: newBinary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveBinary.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
            try writeOwnedReleaseResources(in: live, prefix: "old")
            try writeOwnedReleaseResources(in: payload, prefix: "new")
            let priorManifestFixture = try CompatibilityManifestFixture(
                root: live,
                privateKey: manifestSigningKey,
                version: "1.8.40",
                providerCLIVersion: "1.8.40",
                malibuAppVersion: "1.8.40",
                commit: "1111111111111111111111111111111111111111",
                populateResources: false
            )
            let targetManifestFixture = try CompatibilityManifestFixture(
                root: payload,
                privateKey: manifestSigningKey,
                version: "1.8.42",
                providerCLIVersion: "1.8.40",
                malibuAppVersion: "1.8.41",
                commit: "2222222222222222222222222222222222222222",
                populateResources: false
            )
            let priorManifestData = try Data(
                contentsOf: live.appendingPathComponent(CompatibilitySetManifest.fileName)
            )
            let targetManifestData = try Data(
                contentsOf: payload.appendingPathComponent(CompatibilitySetManifest.fileName)
            )
            let priorManifest = try CompatibilitySetManifest.loadValidated(
                from: live,
                expectedProviderVersion: "1.8.40",
                publicKeyPEM: manifestPublicKey
            )
            XCTAssertEqual(priorManifest.compatibilitySetID, priorManifestFixture.compatibilitySetID)
            XCTAssertEqual(priorManifest.malibuAppVersion, "1.8.40")
            let targetManifest = try CompatibilitySetManifest.loadValidated(
                from: payload,
                expectedProviderVersion: "1.8.40",
                publicKeyPEM: manifestPublicKey
            )
            XCTAssertEqual(targetManifest.compatibilitySetID, targetManifestFixture.compatibilitySetID)
            XCTAssertEqual(targetManifest.version, "1.8.42")
            XCTAssertEqual(targetManifest.providerCLIVersion, "1.8.40")
            XCTAssertEqual(targetManifest.malibuAppVersion, "1.8.41")
            let applications = fixture.url.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(
                at: applications,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let installedMalibu = applications.appendingPathComponent("Malibu.app", isDirectory: true)
            try writeMalibuAppFixture(
                at: installedMalibu,
                version: "1.8.40",
                compatibilityManifest: priorManifestData,
                marker: "old-app"
            )
            let stagedMalibu = fixture.url.appendingPathComponent("staged/Malibu.app", isDirectory: true)
            try writeMalibuAppFixture(
                at: stagedMalibu,
                version: "1.8.41",
                compatibilityManifest: targetManifestData,
                marker: "new-app"
            )

            let launchAgents = fixture.url.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            let watchdogDirectory = fixture.url.appendingPathComponent(".local/share/macprovider-watchdog", isDirectory: true)
            try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: watchdogDirectory, withIntermediateDirectories: true)
            let providerPlist = launchAgents.appendingPathComponent("live.streamvc.macprovider.plist")
            let watchdogScript = watchdogDirectory.appendingPathComponent("macprovider-health-monitor")
            let watchdogPlist = launchAgents.appendingPathComponent("live.streamvc.macprovider-watchdog.plist")
            let oldWatchdogPlist = try installedWatchdogPlist(home: fixture.url, installDirectory: live)
            try Data("old-provider-plist".utf8).write(to: providerPlist)
            try Data("old-watchdog".utf8).write(to: watchdogScript)
            try oldWatchdogPlist.write(to: watchdogPlist)

            let marker = try store.preserveReleaseRollbackBackup(
                binaryURL: liveBinary,
                updateID: UUID().uuidString.lowercased(),
                targetVersion: "1.8.40",
                previousVersion: "1.8.40",
                targetCompatibilitySetID: targetManifest.compatibilitySetID,
                targetCompatibilitySetSHA256: targetManifest.envelopeSHA256
            )
            try store.writePending(marker)

            var observedCheckpoint: CompatibilitySetCutoverPhase?
            XCTAssertThrowsError(
                try store.activateReleasePayload(
                    from: payload,
                    newBinary: newBinary,
                    to: liveBinary,
                    stagedMalibuApp: stagedMalibu,
                    rollbackMarker: marker,
                    cutoverCheckpoint: { checkpoint in
                        if checkpoint == phase {
                            observedCheckpoint = checkpoint
                            throw SimulatedCutoverInterruption.stop
                        }
                    }
                ),
                "phase \(phase.rawValue)"
            ) { error in
                XCTAssertEqual(
                    error as? SimulatedCutoverInterruption,
                    .stop,
                    "phase \(phase.rawValue)"
                )
                XCTAssertEqual(observedCheckpoint, phase, "phase \(phase.rawValue)")
            }
            let restartedStore = AutoUpdateMarkerStore(
                homeDirectory: fixture.url,
                compatibilityManifestPublicKeyPEM: manifestPublicKey
            )
            let persistedMarker = try XCTUnwrap(restartedStore.readPending(), "phase \(phase.rawValue)")

            let recovery = restartedStore.recoverOrphanedMarker(persistedMarker)
            guard case .restoredAwaitingReadiness(let awaitingPrevious) = recovery else {
                XCTFail(
                    "expected restoredAwaitingReadiness for phase \(phase.rawValue), got \(recovery)"
                )
                continue
            }
            XCTAssertEqual(
                awaitingPrevious.transactionState,
                .awaitingPreviousReadiness,
                "phase \(phase.rawValue)"
            )
            XCTAssertEqual(
                awaitingPrevious.previousCompatibilitySetID,
                priorManifestFixture.compatibilitySetID,
                "phase \(phase.rawValue)"
            )
            XCTAssertEqual(try String(contentsOf: liveBinary), "old-binary", "phase \(phase.rawValue)")
            XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("mlx.metallib")), "old-metal", "phase \(phase.rawValue)")
            XCTAssertEqual(try String(contentsOf: live.appendingPathComponent("catalog-release/release.json")), "old-catalog", "phase \(phase.rawValue)")
            XCTAssertEqual(
                try Data(contentsOf: live.appendingPathComponent(CompatibilitySetManifest.fileName)),
                priorManifestData,
                "phase \(phase.rawValue)"
            )
            let restoredManifest = try CompatibilitySetManifest.loadValidated(
                from: live,
                expectedProviderVersion: "1.8.40",
                publicKeyPEM: manifestPublicKey
            )
            XCTAssertEqual(
                restoredManifest.compatibilitySetID,
                priorManifestFixture.compatibilitySetID,
                "phase \(phase.rawValue)"
            )
            XCTAssertEqual(restoredManifest.malibuAppVersion, "1.8.40", "phase \(phase.rawValue)")
            XCTAssertEqual(try String(contentsOf: providerPlist), "old-provider-plist", "phase \(phase.rawValue)")
            XCTAssertEqual(try String(contentsOf: watchdogScript), "old-watchdog", "phase \(phase.rawValue)")
            XCTAssertEqual(try Data(contentsOf: watchdogPlist), oldWatchdogPlist, "phase \(phase.rawValue)")
            XCTAssertEqual(
                try String(contentsOf: installedMalibu.appendingPathComponent("Contents/Resources/test-marker")),
                "old-app",
                "phase \(phase.rawValue)"
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: installedMalibu.appendingPathComponent(
                        "Contents/Resources/\(CompatibilitySetManifest.fileName)"
                    )
                ),
                priorManifestData,
                "phase \(phase.rawValue)"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: restartedStore.pendingURL.path),
                "phase \(phase.rawValue)"
            )
            try restartedStore.completeRestoredPreviousSet(awaitingPrevious)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: restartedStore.pendingURL.path),
                "phase \(phase.rawValue)"
            )
        }
    }

    func testAutoUpdateMarkerStoreDefaultsCompatibilityManifestTrustToReleaseKey() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)

        XCTAssertEqual(
            store.compatibilityManifestPublicKeyPEM,
            SelfUpdate.checksumPublicKeyPEM
        )
    }

    func testLegacyBinaryOnlyPendingMarkerEncodingOmitsReleaseSnapshotFields() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, _, _) = try makePendingMarkerFixture(
            store: store,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )

        let raw = try Data(contentsOf: store.pendingURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertNil(object["release_backup_path"])
        XCTAssertNil(object["release_backup_sha256"])
        XCTAssertEqual(try store.readPending(), marker)
    }

    func testOrphanPendingMarkerWithMissingOrCorruptBackupQuarantinesWithoutRestore() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, binary, backup) = try makePendingMarkerFixture(store: store, fixture: fixture, backupContents: "wrong", targetContents: "new")

        let outcome = store.recoverOrphanedMarker(marker)

        guard case .backupCorrupt(let recovered, _) = outcome else {
            return XCTFail("expected backupCorrupt, got \(outcome)")
        }
        XCTAssertEqual(recovered, marker)
        XCTAssertEqual(try String(contentsOf: binary), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
            .filter { $0.hasPrefix("pending-quarantined-") && $0.hasSuffix(".json") }
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertNil(store.cooldown(target: marker.targetVersion, failureClass: .orphanedPendingMarker))
    }

    func testOrphanPendingMarkerRejectsBackupOutsideDerivedRollbackPath() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        var (marker, binary, backup) = try makePendingMarkerFixture(store: store, fixture: fixture, backupContents: "old", targetContents: "new")
        let attackerBackup = fixture.url.appendingPathComponent("attacker-backup")
        try Data("old".utf8).write(to: attackerBackup)
        marker = AutoUpdatePendingMarker(
            updateID: marker.updateID,
            targetVersion: marker.targetVersion,
            targetPath: marker.targetPath,
            backupPath: attackerBackup.path,
            size: marker.size,
            mode: marker.mode,
            sha256: marker.sha256,
            markerDeadline: marker.markerDeadline
        )
        try store.writePending(marker)

        let outcome = store.recoverOrphanedMarker(marker)

        guard case .backupCorrupt = outcome else {
            return XCTFail("expected backupCorrupt, got \(outcome)")
        }
        XCTAssertEqual(try String(contentsOf: binary), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attackerBackup.path))
    }

    func testSuccessCleanupIsIdempotentAcrossCrashSteps() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, binary, backup) = try makePendingMarkerFixture(store: store, fixture: fixture, backupContents: "old", targetContents: "new")
        let sentinel = store.successSentinelPath(binaryURL: binary, updateID: marker.updateID)

        try store.writeSuccessSentinel(binaryURL: binary, updateID: marker.updateID, targetVersion: marker.targetVersion)
        try store.completeSuccessfulUpdate(marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        try store.writePending(marker)
        try Data("old".utf8).write(to: backup)
        FileManager.default.createFile(atPath: store.lockURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        store.clearPending()
        try store.completeSuccessfulUpdate(marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        try store.finalizeSuccessfulUpdate(marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testMarkerValidationRejectsUppercaseShaAndNonCanonicalVersion() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let binary = fixture.url.appendingPathComponent("bin/macprovider-cli")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = AutoUpdatePendingMarker(
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "v1.7.0",
            targetPath: binary.path,
            backupPath: binary.deletingLastPathComponent().appendingPathComponent(".macprovider-cli.rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee").path,
            size: 0,
            mode: 0o755,
            sha256: String(repeating: "A", count: 64),
            markerDeadline: ISO8601DateFormatter.autoupdateTest.string(from: Date().addingTimeInterval(300))
        )
        XCTAssertThrowsError(try store.validateMarker(marker))
    }

    func testCoordinatorCompatibilityAdmissionRequiresFreshExactCurrentAndTargetSets() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let current = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let target = "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let observed = Date(timeIntervalSince1970: 1_800_000_000)

        try store.persistCompatibilityAdmission(
            acceptedCompatibilitySetID: current,
            recommendedCompatibilitySetID: target,
            now: observed,
            validitySeconds: 90
        )

        XCTAssertNoThrow(try store.requireCoordinatorCompatibilityTarget(
            target,
            currentCompatibilitySetID: current,
            now: observed.addingTimeInterval(45)
        ))
        XCTAssertThrowsError(try store.requireCoordinatorCompatibilityTarget(
            target,
            currentCompatibilitySetID: target,
            now: observed.addingTimeInterval(45)
        ))
        XCTAssertThrowsError(try store.requireCoordinatorCompatibilityTarget(
            current,
            currentCompatibilitySetID: current,
            now: observed.addingTimeInterval(45)
        ))
        XCTAssertThrowsError(try store.requireCoordinatorCompatibilityTarget(
            target,
            currentCompatibilitySetID: current,
            now: observed.addingTimeInterval(91)
        ))
    }

    func testCoordinatorCompatibilityAdmissionRejectsUnknownFieldsAndClearsDurably() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let current = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let target = "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        try store.persistCompatibilityAdmission(
            acceptedCompatibilitySetID: current,
            recommendedCompatibilitySetID: target
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.compatibilityAdmissionURL))
                as? [String: Any]
        )
        object["unexpected"] = true
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try tampered.write(to: store.compatibilityAdmissionURL, options: .atomic)

        XCTAssertThrowsError(try store.readCompatibilityAdmissionForTest())
        try store.clearCompatibilityAdmission()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.compatibilityAdmissionURL.path))
    }

    func testSignedReleaseDiscoveryVerifiesSignatureExpiryAndTamperResistance() throws {
        let privateKey = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let signed = signedDiscoveryPayload(
            sequence: 7,
            targetSetID: "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            artifactIndexSHA256: String(repeating: "b", count: 64),
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(300),
            minimum: "1.8.0",
            revoked: ["1.7.9"]
        )
        let headData = try canonicalJSON(["schema_version": SignedReleaseDiscoveryHead.envelopeSchema, "signed": signed])
        let signedBytes = try canonicalJSON(signed)
        let signature = try privateKey.signature(for: SHA256.hash(data: signedBytes)).derRepresentation

        let head = try SignedReleaseDiscoveryHead.loadVerified(
            headData: headData,
            signatureData: signature,
            now: now,
            publicKeyPEM: privateKey.publicKey.pemRepresentation
        )

        XCTAssertEqual(head.releaseSequence, 7)
        XCTAssertEqual(head.targetVersion, "1.8.4")
        XCTAssertEqual(head.targetArtifactIndexSHA256, String(repeating: "b", count: 64))
        XCTAssertEqual(head.signedPolicyMinimum, "1.8.0")
        XCTAssertEqual(head.signedPolicyRevoked, ["1.7.9"])

        var tampered = headData
        tampered[tampered.count - 2] = UInt8(ascii: "c")
        XCTAssertThrowsError(try SignedReleaseDiscoveryHead.loadVerified(
            headData: tampered,
            signatureData: signature,
            now: now,
            publicKeyPEM: privateKey.publicKey.pemRepresentation
        )) { error in
            guard case .discoveryHeadInvalid? = error as? UpdateError else {
                return XCTFail("expected discoveryHeadInvalid, got \(error)")
            }
        }

        let expired = signedDiscoveryPayload(
            sequence: 8,
            targetSetID: "Augustas11/macprovider:v1.8.5@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            artifactIndexSHA256: String(repeating: "c", count: 64),
            issuedAt: now.addingTimeInterval(-600),
            expiresAt: now.addingTimeInterval(-1)
        )
        let expiredData = try canonicalJSON(["schema_version": SignedReleaseDiscoveryHead.envelopeSchema, "signed": expired])
        let expiredSignature = try privateKey.signature(for: SHA256.hash(data: try canonicalJSON(expired))).derRepresentation
        XCTAssertThrowsError(try SignedReleaseDiscoveryHead.loadVerified(
            headData: expiredData,
            signatureData: expiredSignature,
            now: now,
            publicKeyPEM: privateKey.publicKey.pemRepresentation
        )) { error in
            guard case .discoveryHeadExpired? = error as? UpdateError else {
                return XCTFail("expected discoveryHeadExpired, got \(error)")
            }
        }
    }

    func testDiscoveryStateRejectsReplayAndEquivocationBeforeMutation() throws {
        let privateKey = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let first = try signedDiscoveryHead(
            sequence: 10,
            targetSetID: "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            privateKey: privateKey,
            now: now
        )
        let replay = try signedDiscoveryHead(
            sequence: 9,
            targetSetID: "Augustas11/macprovider:v1.8.3@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            privateKey: privateKey,
            now: now
        )
        let equivocation = try signedDiscoveryHead(
            sequence: 10,
            targetSetID: "Augustas11/macprovider:v1.8.5@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            privateKey: privateKey,
            now: now
        )

        try store.acceptDiscoveryHead(first)
        XCTAssertEqual(try XCTUnwrap(store.readDiscoveryStateForTest()).releaseSequence, 10)
        XCTAssertThrowsError(try store.acceptDiscoveryHead(replay)) { error in
            guard case .discoveryHeadReplay? = error as? UpdateError else {
                return XCTFail("expected discoveryHeadReplay, got \(error)")
            }
        }
        XCTAssertThrowsError(try store.acceptDiscoveryHead(equivocation)) { error in
            guard case .discoveryHeadEquivocation? = error as? UpdateError else {
                return XCTFail("expected discoveryHeadEquivocation, got \(error)")
            }
        }
    }

    func testSignedReleasePendingMarkerRequiresDiscoveryAndExactTargetSetBinding() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let binary = fixture.url.appendingPathComponent("bin/macprovider-cli")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = binary.deletingLastPathComponent().appendingPathComponent(".macprovider-cli.rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        let base = AutoUpdatePendingMarker(
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.8.4",
            targetPath: binary.path,
            backupPath: backup.path,
            size: 0,
            mode: 0o755,
            sha256: String(repeating: "a", count: 64),
            markerDeadline: ISO8601DateFormatter.autoupdateTest.string(from: Date().addingTimeInterval(300)),
            targetCompatibilitySetID: "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            targetCompatibilitySetSHA256: String(repeating: "b", count: 64),
            updateAuthorityMode: "signed_release"
        )

        XCTAssertThrowsError(try store.validateMarker(base))

        let bound = AutoUpdatePendingMarker(
            updateID: base.updateID,
            targetVersion: base.targetVersion,
            targetPath: base.targetPath,
            backupPath: base.backupPath,
            size: base.size,
            mode: base.mode,
            sha256: base.sha256,
            markerDeadline: base.markerDeadline,
            targetCompatibilitySetID: base.targetCompatibilitySetID,
            targetCompatibilitySetSHA256: base.targetCompatibilitySetSHA256,
            discoveryHeadSequence: 12,
            discoveryHeadSHA256: String(repeating: "c", count: 64),
            updateAuthorityMode: "signed_release"
        )
        XCTAssertNoThrow(try store.validateMarker(bound))
    }

    func testRollbackTargetDisallowedByPersistedMinimumOrRevocation() async throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        var (marker, binary, _) = try makePendingMarkerFixture(
            store: store,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )
        marker = AutoUpdatePendingMarker(
            updateID: marker.updateID,
            targetVersion: marker.targetVersion,
            targetPath: marker.targetPath,
            backupPath: marker.backupPath,
            size: marker.size,
            mode: marker.mode,
            sha256: marker.sha256,
            markerDeadline: marker.markerDeadline,
            previousVersion: "1.6.9"
        )
        try await store.updateSignedPolicy(minimum: "1.7.0", revoked: [])

        XCTAssertThrowsError(try store.restoreBackupAwaitingPreviousReadiness(marker)) { error in
            XCTAssertEqual(error as? AutoUpdateMarkerError, .rollbackTargetDisallowed)
        }
        XCTAssertEqual(try String(contentsOf: binary), "new")
    }

    func testSuccessSentinelBindsExactCompatibilitySetIdentityAndDigest() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        var (marker, binary, _) = try makePendingMarkerFixture(
            store: store,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )
        marker = AutoUpdatePendingMarker(
            updateID: marker.updateID,
            targetVersion: marker.targetVersion,
            targetPath: marker.targetPath,
            backupPath: marker.backupPath,
            size: marker.size,
            mode: marker.mode,
            sha256: marker.sha256,
            markerDeadline: marker.markerDeadline,
            targetCompatibilitySetID: "Augustas11/macprovider:v1.7.0@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            targetCompatibilitySetSHA256: String(repeating: "d", count: 64)
        )

        try store.writeSuccessSentinel(binaryURL: binary, marker: marker)
        let payload = try store.readSuccessSentinel(store.successSentinelPath(binaryURL: binary, updateID: marker.updateID))
        XCTAssertEqual(payload.targetCompatibilitySetID, marker.targetCompatibilitySetID)
        XCTAssertEqual(payload.targetCompatibilitySetSHA256, marker.targetCompatibilitySetSHA256)

        let sentinel = store.successSentinelPath(binaryURL: binary, updateID: marker.updateID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sentinel)) as? [String: Any])
        object["target_compatibility_set_sha256"] = String(repeating: "e", count: 64)
        try canonicalJSON(object).write(to: sentinel, options: .atomic)
        let tampered = try store.readSuccessSentinel(sentinel)
        XCTAssertNotEqual(tampered.targetCompatibilitySetSHA256, marker.targetCompatibilitySetSHA256)
    }

    func testNotifyOnlyTrustDoesNotCreateAutoupdateState() async throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.6.0",
            providerStatus: status,
            markerStore: store,
            trustProvider: {
                // Provider config opts out of provisional autoupdate
                // (`auto_update_accept_provisional: false`), so provisional
                // trust is "notify only" — the scenario the test name
                // promises. Without this override, v1.8.16's default
                // `acceptProvisional=true` treats provisional as eligible
                // and autoupdate state DOES get created.
                AutoUpdateTrustState(
                    v2Accepted: true,
                    tier: "provisional",
                    encryptedLegValid: true,
                    attestationRequired: false,
                    attestationSatisfied: true,
                    tokenConfigured: false,
                    tokenValidated: true,
                    bearerlessDuplicate: false,
                    connected: true,
                    stableReason: "tier_demoted",
                    acceptProvisional: false
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: {},
            fenceReloadJobs: {},
            currentBinaryURL: { nil },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )

        await updater.handleCoordinatorRecommendation("1.7.0")

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        let event = await AutoUpdateEventStore.shared.lastWireObject()
        XCTAssertEqual(event?["reason"] as? String, "tier_demoted")
    }

    func testTrustLossBetweenAuthAndSwapAbortsAutoupdate() async throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let binaryDir = fixture.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let binary = binaryDir.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: binary)
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let trustCalls = AutoUpdateCounter()
        await AutoUpdateEventStore.shared.clear()
        SessionAutoupdateGate.shared.resetForTest()
        defer { SessionAutoupdateGate.shared.resetForTest() }
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.6.0",
            providerStatus: status,
            markerStore: store,
            trustProvider: {
                if trustCalls.incrementAndGet() == 1 {
                    return AutoUpdateTrustState(
                        v2Accepted: true,
                        tier: "pinned",
                        encryptedLegValid: true,
                        attestationRequired: false,
                        attestationSatisfied: true,
                        tokenConfigured: true,
                        tokenValidated: true,
                        bearerlessDuplicate: false,
                        connected: true
                    )
                }
                // Provider config opts out of provisional autoupdate
                // (`auto_update_accept_provisional: false`), so the tier
                // demotion between auth and swap DOES disqualify the
                // update — the scenario the test name promises. Without
                // this override, v1.8.16's default `acceptProvisional=true`
                // treats provisional as eligible and execution falls
                // through to the release API.
                return AutoUpdateTrustState(
                    v2Accepted: true,
                    tier: "provisional",
                    encryptedLegValid: true,
                    attestationRequired: false,
                    attestationSatisfied: true,
                    tokenConfigured: true,
                    tokenValidated: true,
                    bearerlessDuplicate: false,
                    connected: true,
                    stableReason: "tier_demoted",
                    acceptProvisional: false
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: {},
            fenceReloadJobs: {},
            currentBinaryURL: { binary },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )

        await updater.handleCoordinatorRecommendation("1.7.0")

        XCTAssertEqual(try String(contentsOf: binary), "old-binary")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        let event = await AutoUpdateEventStore.shared.lastWireObject()
        XCTAssertEqual(event?["failure_class"] as? String, AutoUpdateFailureClass.trustStateLost.rawValue)
        XCTAssertEqual(event?["reason"] as? String, "tier_demoted")
    }

    func testSignedReleaseDiscoverySwapDoesNotRequireCoordinatorTrust() async throws {
        let fixture = try TempHome()
        let manifestSigningKey = P256.Signing.PrivateKey()
        let manifestPublicKey = manifestSigningKey.publicKey.pemRepresentation
        let store = AutoUpdateMarkerStore(
            homeDirectory: fixture.url,
            compatibilityManifestPublicKeyPEM: manifestPublicKey
        )
        try store.ensureTrustedRoot()
        let binaryDirectory = fixture.url.appendingPathComponent("bin", isDirectory: true)
        let payload = fixture.url.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: payload,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let binary = binaryDirectory.appendingPathComponent("macprovider-cli")
        let newBinary = payload.appendingPathComponent("macprovider-cli")
        try Data("old-binary".utf8).write(to: binary)
        try Data("new-binary".utf8).write(to: newBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        try writeOwnedReleaseResources(in: binaryDirectory, prefix: "old")
        try writeOwnedReleaseResources(in: payload, prefix: "new")
        let priorManifestFixture = try CompatibilityManifestFixture(
            root: binaryDirectory,
            privateKey: manifestSigningKey,
            version: "1.8.48",
            providerCLIVersion: "1.8.48",
            malibuAppVersion: "1.8.43",
            commit: "1111111111111111111111111111111111111111",
            populateResources: false
        )
        let manifestFixture = try CompatibilityManifestFixture(
            root: payload,
            privateKey: manifestSigningKey,
            version: "1.8.50",
            providerCLIVersion: "1.8.50",
            malibuAppVersion: "1.8.43",
            commit: "2222222222222222222222222222222222222222",
            populateResources: false
        )
        let manifest = try CompatibilitySetManifest.loadValidated(
            from: payload,
            expectedProviderVersion: "1.8.50",
            publicKeyPEM: manifestPublicKey
        )
        XCTAssertEqual(priorManifestFixture.compatibilitySetID, "Augustas11/macprovider:v1.8.48@1111111111111111111111111111111111111111")
        XCTAssertEqual(manifest.compatibilitySetID, manifestFixture.compatibilitySetID)
        let prepared = PreparedSelfUpdate(
            tempDir: fixture.url,
            newBinary: newBinary,
            stagedMalibuApp: nil,
            signedPolicy: nil,
            compatibilityManifest: manifest,
            artifactIndexSHA256: String(repeating: "a", count: 64)
        )
        let head = SignedReleaseDiscoveryHead(
            releaseSequence: 12,
            targetVersion: "1.8.50",
            targetCompatibilitySetID: manifest.compatibilitySetID,
            targetArtifactIndexSHA256: prepared.artifactIndexSHA256,
            signedPolicyMinimum: nil,
            signedPolicyRevoked: [],
            issuedAt: Date().addingTimeInterval(-30),
            expiresAt: Date().addingTimeInterval(300),
            digest: String(repeating: "b", count: 64)
        )
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.8.48",
            providerStatus: status,
            markerStore: store,
            trustProvider: {
                AutoUpdateTrustState(
                    v2Accepted: false,
                    tier: nil,
                    encryptedLegValid: false,
                    attestationRequired: false,
                    attestationSatisfied: false,
                    tokenConfigured: true,
                    tokenValidated: false,
                    bearerlessDuplicate: false,
                    connected: false,
                    stableReason: "coordinator_disconnected"
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: {},
            fenceReloadJobs: {},
            currentBinaryURL: { binary },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )

        try await updater.preserveMarkerAndSwapForTest(
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            target: "1.8.50",
            prepared: prepared,
            authorityMode: "signed_release",
            discoveryHead: head,
            requireCurrentTrustAtSwap: false
        )

        XCTAssertEqual(try String(contentsOf: binary), "new-binary")
        let marker = try XCTUnwrap(store.readPending())
        XCTAssertEqual(marker.updateAuthorityMode, "signed_release")
        XCTAssertEqual(marker.discoveryHeadSequence, 12)
        XCTAssertEqual(marker.targetCompatibilitySetID, manifest.compatibilitySetID)
        XCTAssertEqual(marker.targetCompatibilitySetSHA256, manifest.envelopeSHA256)
    }

    func testAutoUpdaterOwnsMutationLockBeforeFencingReloadJobs() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        let fenceObservedOwnedLock = LockedInvocationCounter()
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.6.0",
            providerStatus: ProviderStatus(
                modelID: "mlx-community/Test-Model",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            markerStore: store,
            trustProvider: {
                AutoUpdateTrustState(
                    v2Accepted: true,
                    tier: "pinned",
                    encryptedLegValid: true,
                    attestationRequired: false,
                    attestationSatisfied: true,
                    tokenConfigured: true,
                    tokenValidated: true,
                    bearerlessDuplicate: false,
                    connected: true
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: {},
            fenceReloadJobs: {
                do {
                    let unexpectedLock = try store.acquireLock()
                    withExtendedLifetime(unexpectedLock) {}
                    throw SimulatedCutoverInterruption.stop
                } catch AutoUpdateMarkerError.lockContended {
                    fenceObservedOwnedLock.record()
                }
            },
            currentBinaryURL: { nil },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )

        let lock = try updater.acquireUpdateLockAndFenceReloadJobsForTest()
        defer { withExtendedLifetime(lock) {} }

        XCTAssertEqual(fenceObservedOwnedLock.value, 1)
    }

    func testTrustLossRollbackAndCleanupRemainUnderMutationLock() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, binary, backup) = try makePendingMarkerFixture(
            store: store,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )
        let fenceObservedOwnedLock = LockedInvocationCounter()
        let fenceObservedNewBinary = LockedInvocationCounter()
        let cleanupObservedOwnedLock = LockedInvocationCounter()
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.6.0",
            providerStatus: ProviderStatus(
                modelID: "mlx-community/Test-Model",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            markerStore: store,
            trustProvider: {
                AutoUpdateTrustState(
                    v2Accepted: true,
                    tier: "pinned",
                    encryptedLegValid: true,
                    attestationRequired: false,
                    attestationSatisfied: true,
                    tokenConfigured: true,
                    tokenValidated: true,
                    bearerlessDuplicate: false,
                    connected: true
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: {},
            fenceReloadJobs: {
                do {
                    let unexpectedLock = try store.acquireRecoveryLock()
                    withExtendedLifetime(unexpectedLock) {}
                } catch AutoUpdateMarkerError.lockContended {
                    fenceObservedOwnedLock.record()
                } catch {
                    XCTFail("Unexpected competing lock error: \(error)")
                }
                if (try? String(contentsOf: binary)) == "new" {
                    fenceObservedNewBinary.record()
                }
            },
            currentBinaryURL: { binary },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )
        let lock = try store.acquireRecoveryLock()
        defer { withExtendedLifetime(lock) {} }

        updater.rollbackAfterTrustLossForTest(marker, whileHolding: lock) {
            do {
                let unexpectedLock = try store.acquireRecoveryLock()
                withExtendedLifetime(unexpectedLock) {}
            } catch AutoUpdateMarkerError.lockContended {
                cleanupObservedOwnedLock.record()
            } catch {
                XCTFail("Unexpected competing lock error: \(error)")
            }
        }

        XCTAssertEqual(fenceObservedOwnedLock.value, 1)
        XCTAssertEqual(fenceObservedNewBinary.value, 1)
        XCTAssertEqual(cleanupObservedOwnedLock.value, 1)
        XCTAssertEqual(try String(contentsOf: binary), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testActivationFailureRefencesBeforeRestoringUnderMutationLock() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, binary, backup) = try makePendingMarkerFixture(
            store: store,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )
        let fenceObservedOwnedLock = LockedInvocationCounter()
        let fenceObservedNewBinary = LockedInvocationCounter()
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.6.0",
            providerStatus: ProviderStatus(
                modelID: "mlx-community/Test-Model",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            markerStore: store,
            trustProvider: {
                AutoUpdateTrustState(
                    v2Accepted: true,
                    tier: "pinned",
                    encryptedLegValid: true,
                    attestationRequired: false,
                    attestationSatisfied: true,
                    tokenConfigured: true,
                    tokenValidated: true,
                    bearerlessDuplicate: false,
                    connected: true
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: {},
            fenceReloadJobs: {
                do {
                    let unexpectedLock = try store.acquireRecoveryLock()
                    withExtendedLifetime(unexpectedLock) {}
                } catch AutoUpdateMarkerError.lockContended {
                    fenceObservedOwnedLock.record()
                } catch {
                    XCTFail("Unexpected competing lock error: \(error)")
                }
                if (try? String(contentsOf: binary)) == "new" {
                    fenceObservedNewBinary.record()
                }
            },
            currentBinaryURL: { binary },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )
        let lock = try store.acquireRecoveryLock()
        defer { withExtendedLifetime(lock) {} }

        try updater.rollbackAfterActivationFailureForTest(marker, whileHolding: lock)

        XCTAssertEqual(fenceObservedOwnedLock.value, 1)
        XCTAssertEqual(fenceObservedNewBinary.value, 1)
        XCTAssertEqual(try String(contentsOf: binary), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testPostSwapPolicyPersistFailureUsesHeldMutationLockAndRefencesBeforeRestore() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let fenceObservedOwnedLock = LockedInvocationCounter()
        let fenceObservedNewBinary = LockedInvocationCounter()
        let rollbackObservedOwnedLock = LockedInvocationCounter()
        let binary = fixture.url.appendingPathComponent("bin/macprovider-cli")
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.6.0",
            providerStatus: ProviderStatus(
                modelID: "mlx-community/Test-Model",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            markerStore: store,
            trustProvider: {
                AutoUpdateTrustState(
                    v2Accepted: true,
                    tier: "pinned",
                    encryptedLegValid: true,
                    attestationRequired: false,
                    attestationSatisfied: true,
                    tokenConfigured: true,
                    tokenValidated: true,
                    bearerlessDuplicate: false,
                    connected: true
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: {},
            fenceReloadJobs: {
                do {
                    let unexpectedLock = try store.acquireRecoveryLock()
                    withExtendedLifetime(unexpectedLock) {}
                } catch AutoUpdateMarkerError.lockContended {
                    fenceObservedOwnedLock.record()
                } catch {
                    XCTFail("Unexpected competing lock error: \(error)")
                }
                if (try? String(contentsOf: binary)) == "new" {
                    fenceObservedNewBinary.record()
                }
            },
            currentBinaryURL: { binary },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )
        let lock = try updater.acquireUpdateLockAndFenceReloadJobsForTest()
        defer { withExtendedLifetime(lock) {} }
        let (marker, _, backup) = try makePendingMarkerFixture(
            store: store,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )

        updater.rollbackAfterSignedPolicyPersistFailureForTest(
            marker,
            whileHolding: lock
        ) {
            do {
                let unexpectedLock = try store.acquireRecoveryLock()
                withExtendedLifetime(unexpectedLock) {}
            } catch AutoUpdateMarkerError.lockContended {
                rollbackObservedOwnedLock.record()
            } catch {
                XCTFail("Unexpected competing lock error: \(error)")
            }
        }

        XCTAssertEqual(fenceObservedOwnedLock.value, 2)
        XCTAssertEqual(fenceObservedNewBinary.value, 1)
        XCTAssertEqual(rollbackObservedOwnedLock.value, 1)
        XCTAssertEqual(try String(contentsOf: binary), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRestartFailureRollbackRestoresBinaryAndClearsPendingState() async throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, binary, backup) = try makePendingMarkerFixture(
            store: store,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )
        let status = ProviderStatus(
            modelID: "mlx-community/Test-Model",
            modelLoaded: true,
            capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
        )
        let reloads = LockedInvocationCounter()
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.6.0",
            providerStatus: status,
            markerStore: store,
            trustProvider: {
                AutoUpdateTrustState(
                    v2Accepted: true,
                    tier: "pinned",
                    encryptedLegValid: true,
                    attestationRequired: false,
                    attestationSatisfied: true,
                    tokenConfigured: true,
                    tokenValidated: true,
                    bearerlessDuplicate: false,
                    connected: true
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: { reloads.record() },
            fenceReloadJobs: {},
            currentBinaryURL: { binary },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )

        updater.rollbackCommittedSwapAfterRestartFailureForTest(marker)

        XCTAssertEqual(try String(contentsOf: binary), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertEqual(reloads.value, 1)
    }

    func testRestartFailureRollbackKeepsRecoveryStateWhenRestoredJobsCannotReload() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, binary, backup) = try makePendingMarkerFixture(
            store: store,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.6.0",
            providerStatus: ProviderStatus(
                modelID: "mlx-community/Test-Model",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            markerStore: store,
            trustProvider: {
                AutoUpdateTrustState(
                    v2Accepted: true,
                    tier: "pinned",
                    encryptedLegValid: true,
                    attestationRequired: false,
                    attestationSatisfied: true,
                    tokenConfigured: true,
                    tokenValidated: true,
                    bearerlessDuplicate: false,
                    connected: true
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: { throw SimulatedCutoverInterruption.stop },
            fenceReloadJobs: {},
            currentBinaryURL: { binary },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )

        updater.rollbackCommittedSwapAfterRestartFailureForTest(marker)

        XCTAssertEqual(try String(contentsOf: binary), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRestartFailureRollbackDoesNotRestoreBeforeReloadJobsAreFenced() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, binary, backup) = try makePendingMarkerFixture(
            store: store,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )
        let fenceAttempts = LockedInvocationCounter()
        let reloads = LockedInvocationCounter()
        let updater = AutoUpdater(
            config: .defaults(configPath: fixture.url.appendingPathComponent("config.yaml").path),
            currentVersion: "1.6.0",
            providerStatus: ProviderStatus(
                modelID: "mlx-community/Test-Model",
                modelLoaded: true,
                capacity: ProviderCapacity(maxContextOverride: nil, maxConcurrencyOverride: nil)
            ),
            markerStore: store,
            trustProvider: {
                AutoUpdateTrustState(
                    v2Accepted: true,
                    tier: "pinned",
                    encryptedLegValid: true,
                    attestationRequired: false,
                    attestationSatisfied: true,
                    tokenConfigured: true,
                    tokenValidated: true,
                    bearerlessDuplicate: false,
                    connected: true
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: { reloads.record() },
            fenceReloadJobs: {
                fenceAttempts.record()
                throw SimulatedCutoverInterruption.stop
            },
            currentBinaryURL: { binary },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )

        updater.rollbackCommittedSwapAfterRestartFailureForTest(marker)

        XCTAssertEqual(fenceAttempts.value, 1)
        XCTAssertEqual(reloads.value, 0)
        XCTAssertEqual(try String(contentsOf: binary), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testAutoupdateReasonRedactionUsesStableCodes() {
        let errors: [Error] = [
            UpdateError.invalidURL("https://example.com/update?token=secret"),
            UpdateError.checksumMismatch(expected: String(repeating: "a", count: 64), actual: String(repeating: "b", count: 64)),
            UpdateError.unsafeArchiveEntry("/Users/example/.ssh/id_rsa"),
            UpdateError.processFailed("/tmp/macprovider-cli", 1),
        ]
        for error in errors {
            let reason = AutoUpdater.redactedReason(for: error)
            XCTAssertFalse(reason.contains("https://"))
            XCTAssertFalse(reason.contains("/tmp/"))
            XCTAssertFalse(reason.range(of: #"[0-9a-fA-F]{17,}"#, options: .regularExpression) != nil)
        }
    }

    func testSignedPolicyPersistenceIsMonotonic() async throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        try await store.updateSignedPolicy(minimum: "1.7.0", revoked: ["1.6.1"])
        try await store.updateSignedPolicy(minimum: "1.6.0", revoked: [])
        var policy = store.effectivePolicy()
        XCTAssertEqual(policy.minimum, "1.7.0")
        XCTAssertTrue(policy.revoked.contains("1.6.1"))
        try await store.updateSignedPolicy(minimum: "1.8.0", revoked: ["1.7.1"])
        policy = store.effectivePolicy()
        XCTAssertEqual(policy.minimum, "1.8.0")
        XCTAssertTrue(policy.revoked.contains("1.6.1"))
        XCTAssertTrue(policy.revoked.contains("1.7.1"))
    }

    func testPreLockSignedPolicyPersistFailureNeverRestoresPendingReleaseBytes() async throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, binary, backup) = try makePendingMarkerFixture(
            store: store,
            fixture: fixture,
            backupContents: "old",
            targetContents: "new"
        )
        try FileManager.default.createDirectory(
            at: store.policyURL,
            withIntermediateDirectories: false
        )
        await AutoUpdateEventStore.shared.clear()
        SessionAutoupdateGate.shared.resetForTest()
        defer { SessionAutoupdateGate.shared.resetForTest() }

        do {
            try await store.updateSignedPolicy(minimum: "1.7.0", revoked: [])
            XCTFail("Expected signed policy persistence to fail")
        } catch is AutoUpdateSignedPolicyPersistError {
            // Expected.
        }

        XCTAssertEqual(try String(contentsOf: binary), "new")
        XCTAssertEqual(try String(contentsOf: backup), "old")
        XCTAssertEqual(try store.readPending(), marker)
        XCTAssertTrue(SessionAutoupdateGate.shared.isDisabled)
        let event = await AutoUpdateEventStore.shared.lastWireObject()
        XCTAssertEqual(event?["reason"] as? String, "signed_policy_persist_failed")
    }

    func testUnsignedReleasePolicyMetadataIsIgnored() throws {
        let data = Data("""
        {
          "tag_name": "v1.8.0",
          "assets": [],
          "signed_policy_minimum": "9.9.9",
          "signed_policy_revoked": ["1.8.0"],
          "body": "```json\\n{\\\"signed_policy_minimum\\\":\\\"9.9.9\\\"}\\n```"
        }
        """.utf8)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        XCTAssertNil(release.signedPolicy)
    }

    func testSelfUpdateResolvesReleaseByVTagThenBareTag() async throws {
        let latest = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/latest")!
        let vTag = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/tags/v1.7.0")!
        let bare = URL(string: "https://api.github.com/repos/Augustas11/macprovider/releases/tags/1.7.0")!
        AutoUpdateMockURLProtocol.responses = [
            vTag: (404, Data("{}".utf8)),
            bare: (200, Data(#"{"tag_name":"1.7.0","assets":[]}"#.utf8)),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutoUpdateMockURLProtocol.self]
        let update = SelfUpdate(currentVersion: "1.6.1", releasesAPIURL: latest.absoluteString, session: URLSession(configuration: configuration))

        let release = try await update.resolveReleaseByTags(normalizedTarget: "1.7.0")

        XCTAssertEqual(release.tagName, "1.7.0")
    }

    private func signedDiscoveryPayload(
        sequence: UInt64,
        targetSetID: String,
        artifactIndexSHA256: String = String(repeating: "a", count: 64),
        issuedAt: Date,
        expiresAt: Date,
        minimum: String? = nil,
        revoked: [String] = []
    ) -> [String: Any] {
        [
            "schema_version": SignedReleaseDiscoveryHead.payloadSchema,
            "release_sequence": NSNumber(value: sequence),
            "target_compatibility_set_id": targetSetID,
            "target_artifact_index_sha256": artifactIndexSHA256,
            "signed_policy_minimum": minimum ?? NSNull(),
            "signed_policy_revoked": revoked,
            "issued_at": ISO8601DateFormatter.autoupdateTest.string(from: issuedAt),
            "expires_at": ISO8601DateFormatter.autoupdateTest.string(from: expiresAt),
        ]
    }

    private func signedDiscoveryHead(
        sequence: UInt64,
        targetSetID: String,
        privateKey: P256.Signing.PrivateKey,
        now: Date
    ) throws -> SignedReleaseDiscoveryHead {
        let payload = signedDiscoveryPayload(
            sequence: sequence,
            targetSetID: targetSetID,
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(300)
        )
        let headData = try canonicalJSON([
            "schema_version": SignedReleaseDiscoveryHead.envelopeSchema,
            "signed": payload,
        ])
        let signature = try privateKey.signature(for: SHA256.hash(data: try canonicalJSON(payload))).derRepresentation
        return try SignedReleaseDiscoveryHead.loadVerified(
            headData: headData,
            signatureData: signature,
            now: now,
            publicKeyPEM: privateKey.publicKey.pemRepresentation
        )
    }

    private func canonicalJSON(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private func makePendingMarkerFixture(
        store: AutoUpdateMarkerStore,
        fixture: TempHome,
        backupContents: String,
        targetContents: String
    ) throws -> (AutoUpdatePendingMarker, URL, URL) {
        try store.ensureTrustedRoot()
        FileManager.default.createFile(atPath: store.lockURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let binaryDir = fixture.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let binary = binaryDir.appendingPathComponent("macprovider-cli")
        let backup = binaryDir.appendingPathComponent(".macprovider-cli.rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        try Data(targetContents.utf8).write(to: binary)
        try Data(backupContents.utf8).write(to: backup)
        let marker = AutoUpdatePendingMarker(
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.7.0",
            targetPath: binary.path,
            backupPath: backup.path,
            size: 3,
            mode: 0o755,
            sha256: AutoUpdateEvent.sha256Hex("old"),
            markerDeadline: ISO8601DateFormatter.autoupdateTest.string(from: Date().addingTimeInterval(300))
        )
        try store.writePending(marker)
        return (marker, binary, backup)
    }

    private func writeOwnedReleaseResources(in directory: URL, prefix: String) throws {
        try Data("\(prefix)-metal".utf8).write(to: directory.appendingPathComponent("mlx.metallib"))
        try Data("\(prefix)-notices".utf8).write(to: directory.appendingPathComponent("THIRD-PARTY-NOTICES.txt"))
        try Data("\(prefix)-compatibility-set".utf8).write(
            to: directory.appendingPathComponent(CompatibilitySetManifest.fileName)
        )
        let bundle = directory.appendingPathComponent("Runtime.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        try Data("\(prefix)-bundle".utf8).write(to: bundle.appendingPathComponent("resource"))
        let catalog = directory.appendingPathComponent("catalog-release", isDirectory: true)
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
        for name in [
            "release.json",
            "trusted-keys.json",
            "autotune-candidates.json",
            "autotune-candidates.json.sig",
            "demand-rank.json",
            "demand-rank.json.sig",
        ] {
            let contents = name == "release.json" ? "\(prefix)-catalog" : "\(prefix)-\(name)"
            try Data(contents.utf8).write(to: catalog.appendingPathComponent(name))
        }
        let localArtifacts = directory.appendingPathComponent(
            CompatibilitySetManifest.localArtifactDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: localArtifacts, withIntermediateDirectories: false)
        try Data("new-install".utf8).write(to: localArtifacts.appendingPathComponent("install.sh"))
        try Data(providerPlistTemplate.utf8).write(
            to: localArtifacts.appendingPathComponent("provider-launch-agent.plist.template")
        )
        try CompatibilitySetRollbackPlan.canonicalSupportedData().write(
            to: localArtifacts.appendingPathComponent("updater-rollback.json")
        )
        try Data(watchdogPlistTemplate.utf8).write(
            to: localArtifacts.appendingPathComponent("watchdog-launch-agent.plist.template")
        )
        try Data("\(prefix)-watchdog".utf8).write(to: localArtifacts.appendingPathComponent("watchdog.sh"))
    }

    private func replaceOwnedReleaseResources(in directory: URL, prefix: String) throws {
        for name in [
            "mlx.metallib",
            "THIRD-PARTY-NOTICES.txt",
            CompatibilitySetManifest.fileName,
            "Runtime.bundle",
            "catalog-release",
            CompatibilitySetManifest.localArtifactDirectoryName,
        ] {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try writeOwnedReleaseResources(in: directory, prefix: prefix)
    }

    private func writeMalibuAppFixture(
        at app: URL,
        version: String,
        compatibilityManifest: Data,
        marker: String
    ) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "tech.malibu.app",
                "CFBundleShortVersionString": version,
                "CFBundleExecutable": "Malibu",
            ],
            format: .binary,
            options: 0
        )
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        try compatibilityManifest.write(
            to: resources.appendingPathComponent(CompatibilitySetManifest.fileName)
        )
        try Data(marker.utf8).write(to: resources.appendingPathComponent("test-marker"))
        let executable = macOS.appendingPathComponent("Malibu")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    private var providerPlistTemplate: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Label</key><string>live.streamvc.macprovider</string>
        <key>ProgramArguments</key><array><string>__INSTALL_DIR__/macprovider-cli</string><string>serve</string><string>--config</string><string>__HOME__/.config/macprovider/config.yaml</string></array>
        <key>WorkingDirectory</key><string>__INSTALL_DIR__</string>
        </dict></plist>
        """
    }

    private var watchdogPlistTemplate: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Label</key><string>live.streamvc.macprovider-watchdog</string>
        <key>ProgramArguments</key><array><string>__HOME__/.local/share/macprovider-watchdog/macprovider-health-monitor</string></array>
        <key>EnvironmentVariables</key><dict>
        <key>MACPROVIDER_BINARY_PATH</key><string>__INSTALL_DIR__/macprovider-cli</string>
        <key>MACPROVIDER_COORDINATOR_HOST</key><string>__COORDINATOR_HOST__</string>
        </dict>
        </dict></plist>
        """
    }

    private func installedWatchdogPlist(home: URL, installDirectory: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "live.streamvc.macprovider-watchdog",
                "EnvironmentVariables": ["MACPROVIDER_COORDINATOR_HOST": "coordinator.example.test"],
            ],
            format: .xml,
            options: 0
        )
    }

    // MARK: — Provisional-tier auto-update graduation (2026-07-03)

    // Before this fix: `guard tier == "pinned" else { return .provisional }`
    // architecturally blocked every self-service (curl|bash-onboarded) provider
    // from ever receiving auto-updates. After the fix, `acceptProvisional`
    // (fed from `auto_update_accept_provisional` in the provider config or
    // MACPROVIDER_AUTO_UPDATE_ACCEPT_PROVISIONAL env var) is an explicit
    // operator opt-in that flips only the auto-update tier gate — pool cap,
    // rate limit, routing-weight halving, and the other provisional-tier
    // restrictions remain untouched (those live in the coordinator, not in
    // this trust state).

    func testTrustVerdictProvisionalDefaultsToEligible() {
        let state = AutoUpdateTrustState(
            v2Accepted: true,
            tier: "provisional",
            encryptedLegValid: true,
            attestationRequired: false,
            attestationSatisfied: true,
            tokenConfigured: false,
            tokenValidated: true,
            bearerlessDuplicate: false,
            connected: true
        )
        XCTAssertEqual(state.verdict, .eligible)
        XCTAssertTrue(state.isEligible)
    }

    func testTrustVerdictProvisionalExplicitOptOutStaysIneligible() {
        let state = AutoUpdateTrustState(
            v2Accepted: true,
            tier: "provisional",
            encryptedLegValid: true,
            attestationRequired: false,
            attestationSatisfied: true,
            tokenConfigured: false,
            tokenValidated: true,
            bearerlessDuplicate: false,
            connected: true,
            acceptProvisional: false
        )
        XCTAssertEqual(state.verdict, .provisional)
        XCTAssertFalse(state.isEligible)
    }

    func testTrustVerdictProvisionalWithAcceptFlagBecomesEligible() {
        let state = AutoUpdateTrustState(
            v2Accepted: true,
            tier: "provisional",
            encryptedLegValid: true,
            attestationRequired: false,
            attestationSatisfied: true,
            tokenConfigured: false,
            tokenValidated: true,
            bearerlessDuplicate: false,
            connected: true,
            acceptProvisional: true
        )
        XCTAssertEqual(state.verdict, .eligible)
        XCTAssertTrue(state.isEligible)
    }

    // Belt-and-suspenders: acceptProvisional must NOT loosen anything else.
    // Even with acceptProvisional=true, encryptedLegFailed / attestationFailed
    // / tokenRejected / bearerlessDuplicate must still block.
    func testAcceptProvisionalDoesNotBypassEncryptedLegGate() {
        let state = AutoUpdateTrustState(
            v2Accepted: true,
            tier: "provisional",
            encryptedLegValid: false,
            attestationRequired: false,
            attestationSatisfied: true,
            tokenConfigured: false,
            tokenValidated: true,
            bearerlessDuplicate: false,
            connected: true,
            acceptProvisional: true
        )
        XCTAssertEqual(state.verdict, .encryptedLegFailed)
    }

    func testAcceptProvisionalDoesNotBypassBearerlessDuplicateGate() {
        let state = AutoUpdateTrustState(
            v2Accepted: true,
            tier: "provisional",
            encryptedLegValid: true,
            attestationRequired: false,
            attestationSatisfied: true,
            tokenConfigured: true,
            tokenValidated: false,
            bearerlessDuplicate: true,
            connected: true,
            acceptProvisional: true
        )
        XCTAssertEqual(state.verdict, .bearerlessDuplicate)
    }

    func testAcceptProvisionalDoesNotBypassTokenRejectionGate() {
        let state = AutoUpdateTrustState(
            v2Accepted: true,
            tier: "provisional",
            encryptedLegValid: true,
            attestationRequired: false,
            attestationSatisfied: true,
            tokenConfigured: true,
            tokenValidated: false,
            bearerlessDuplicate: false,
            connected: true,
            acceptProvisional: true
        )
        XCTAssertEqual(state.verdict, .tokenRejected)
    }

    // Rejected tier is a hard-refuse from the coordinator; acceptProvisional
    // must not turn it into eligible. Only "pinned" and "provisional+opt-in"
    // pass the gate.
    func testAcceptProvisionalDoesNotEscalateRejectedTier() {
        let state = AutoUpdateTrustState(
            v2Accepted: true,
            tier: "rejected",
            encryptedLegValid: true,
            attestationRequired: false,
            attestationSatisfied: true,
            tokenConfigured: false,
            tokenValidated: true,
            bearerlessDuplicate: false,
            connected: true,
            acceptProvisional: true
        )
        XCTAssertEqual(state.verdict, .provisional)
    }

    // Pinned providers must remain eligible with or without the flag — flag
    // affects only the provisional tier gate.
    func testPinnedRemainsEligibleWhenAcceptProvisionalIsFalse() {
        let state = AutoUpdateTrustState(
            v2Accepted: true,
            tier: "pinned",
            encryptedLegValid: true,
            attestationRequired: false,
            attestationSatisfied: true,
            tokenConfigured: false,
            tokenValidated: true,
            bearerlessDuplicate: false,
            connected: true,
            acceptProvisional: false
        )
        XCTAssertEqual(state.verdict, .eligible)
    }

    // fromCoordinatorPayload must forward the flag intact. Prior version
    // silently dropped it (missing param → default false), which was the
    // shape of the trust-orphan bug the fix closes.
    func testFromCoordinatorPayloadForwardsAcceptProvisional() throws {
        let payload: [String: Any] = [
            "type": "auth_response",
            "status": "accepted",
            "tier": "provisional",
        ]
        let session = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
            p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
        )
        let state = AutoUpdateTrustState.fromCoordinatorPayload(
            payload,
            isV2: true,
            session: session,
            providerToken: "test-token",
            assignedProviderTokenAdopted: false,
            acceptProvisional: true
        )
        XCTAssertEqual(state.tier, "provisional")
        XCTAssertTrue(state.acceptProvisional)
        XCTAssertEqual(state.verdict, .eligible)
    }

    func testFromCoordinatorPayloadTreatsOptionalAttestationAsEligible() throws {
        let payload: [String: Any] = [
            "type": "auth_response",
            "status": "accepted",
            "tier": "pinned",
            "tier2_session": [
                "attestation": ["status": "not_required"]
            ]
        ]
        let session = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
            p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
        )

        let state = AutoUpdateTrustState.fromCoordinatorPayload(
            payload,
            isV2: true,
            session: session,
            providerToken: nil,
            assignedProviderTokenAdopted: false
        )

        XCTAssertTrue(state.isEligible)
        XCTAssertEqual(state.verdict, .eligible)
    }

    func testFromCoordinatorPayloadStillBlocksUnsupportedAttestation() throws {
        let payload: [String: Any] = [
            "type": "auth_response",
            "status": "accepted",
            "tier": "pinned",
            "tier2_session": [
                "attestation": ["status": "unsupported"]
            ]
        ]
        let session = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
            p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
        )

        let state = AutoUpdateTrustState.fromCoordinatorPayload(
            payload,
            isV2: true,
            session: session,
            providerToken: nil,
            assignedProviderTokenAdopted: false
        )

        XCTAssertFalse(state.isEligible)
        XCTAssertEqual(state.verdict, .attestationFailed)
    }

    // Runbook item 23 / SPEC-020: closes the tokenless race-loser residual. In
    // that corner the admitted bearerless-duplicate session is TOKENLESS (no held
    // token, no assigned_provider_token in the ack), so the pre-existing heuristic
    // computes tokenConfigured=false → bearerlessDuplicate=false and can wrongly
    // reach .eligible. The coordinator now sends auth_state=bearerless_duplicate,
    // which is authoritative → the notify-only floor is client-enforceable.
    func testFromCoordinatorPayloadExplicitBearerlessDuplicateClosesTokenlessResidual() throws {
        let payload: [String: Any] = [
            "type": "auth_response",
            "status": "accepted",
            "tier": "provisional",
            "auth_state": "bearerless_duplicate", // no assigned_provider_token — tokenless racer
        ]
        let session = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
            p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
        )
        let state = AutoUpdateTrustState.fromCoordinatorPayload(
            payload,
            isV2: true,
            session: session,
            providerToken: nil, // tokenless — heuristic alone yields tokenConfigured=false => NOT flagged
            assignedProviderTokenAdopted: false,
            acceptProvisional: true
        )
        XCTAssertFalse(state.tokenConfigured) // confirms the heuristic could not flag it
        XCTAssertTrue(state.bearerlessDuplicate) // explicit verdict does
        XCTAssertEqual(state.verdict, .bearerlessDuplicate)
        XCTAssertFalse(state.isEligible)
    }

    // The explicit verdict also SUPPRESSES a heuristic false-positive: an
    // assigned_provider_token in the payload with no held token would make the
    // inference say bearerless, but auth_state=bearer_validated is authoritative.
    func testFromCoordinatorPayloadExplicitBearerValidatedOverridesHeuristic() throws {
        let payload: [String: Any] = [
            "type": "auth_response",
            "status": "accepted",
            "tier": "provisional",
            "assigned_provider_token": "minted-xyz", // makes tokenConfigured true
            "auth_state": "bearer_validated",
        ]
        let session = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
            p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
        )
        let state = AutoUpdateTrustState.fromCoordinatorPayload(
            payload,
            isV2: true,
            session: session,
            providerToken: nil, // heuristic: tokenConfigured && nil token && !adopted => bearerless
            assignedProviderTokenAdopted: false,
            acceptProvisional: true
        )
        // The explicit verdict suppresses the heuristic's bearerless false
        // positive. (tokenValidated is a separate, unchanged dimension: with an
        // unadopted assigned token and no held token the verdict is tokenRejected,
        // not bearerlessDuplicate — the override worked. Item 23 only makes the
        // restrictive bearerless floor authoritative; it does not relax token
        // validation on a coordinator claim.)
        XCTAssertFalse(state.bearerlessDuplicate)
        XCTAssertNotEqual(state.verdict, .bearerlessDuplicate)
        XCTAssertEqual(state.verdict, .tokenRejected)
    }

    // Legacy coordinator (no auth_state) must fall back to the pre-existing
    // heuristic so behavior is unchanged against old coordinators.
    func testFromCoordinatorPayloadLegacyNoAuthStateFallsBackToHeuristic() throws {
        let payload: [String: Any] = [
            "type": "auth_response",
            "status": "accepted",
            "tier": "provisional",
            "assigned_provider_token": "minted-xyz", // tokenConfigured true, no auth_state
        ]
        let session = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
            p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
        )
        let state = AutoUpdateTrustState.fromCoordinatorPayload(
            payload,
            isV2: true,
            session: session,
            providerToken: nil,
            assignedProviderTokenAdopted: false,
            acceptProvisional: true
        )
        XCTAssertTrue(state.bearerlessDuplicate) // heuristic preserved for legacy
        XCTAssertEqual(state.verdict, .bearerlessDuplicate)
    }

    // An UNKNOWN/unexpected auth_state (enum evolution, malformed) must FAIL
    // CLOSED to the notify-only floor, not silently become eligible. Here a
    // tokenless session (heuristic would say tokenConfigured=false → not
    // bearerless → eligible) carries an unrecognized auth_state; the switch
    // holds it notify-only.
    func testFromCoordinatorPayloadUnknownAuthStateFailsClosed() throws {
        let payload: [String: Any] = [
            "type": "auth_response",
            "status": "accepted",
            "tier": "provisional",
            "auth_state": "some_future_state_v9",
        ]
        let session = try Tier2ProviderSession(
            providerID: "provider-test",
            assignedID: "assigned-test",
            selectedAEAD: Tier2ProviderSession.aeadSuite,
            keyID: "kid-test",
            c2pKey: Data(repeating: 0x11, count: 32),
            p2cKey: Data(repeating: 0x22, count: 32),
            c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
            p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
        )
        let state = AutoUpdateTrustState.fromCoordinatorPayload(
            payload,
            isV2: true,
            session: session,
            providerToken: nil, // tokenless — heuristic would NOT flag; fail-open risk
            assignedProviderTokenAdopted: false,
            acceptProvisional: true
        )
        XCTAssertTrue(state.bearerlessDuplicate)
        XCTAssertEqual(state.verdict, .bearerlessDuplicate)
        XCTAssertFalse(state.isEligible)
    }

    // A PRESENT-but-malformed auth_state (empty string, NSNull, number, bool,
    // object) must FAIL CLOSED — it must not fall through to the legacy heuristic
    // (which, tokenless, would reach .eligible). Only an ABSENT key uses the
    // heuristic. Each malformed value below is a tokenless v2 provisional session
    // that the heuristic alone would let become eligible.
    func testFromCoordinatorPayloadMalformedAuthStateFailsClosed() throws {
        let malformed: [Any] = ["", NSNull(), 123, true, ["k": "v"], [1, 2, 3]]
        for badValue in malformed {
            let payload: [String: Any] = [
                "type": "auth_response",
                "status": "accepted",
                "tier": "provisional",
                "auth_state": badValue,
            ]
            let session = try Tier2ProviderSession(
                providerID: "provider-test",
                assignedID: "assigned-test",
                selectedAEAD: Tier2ProviderSession.aeadSuite,
                keyID: "kid-test",
                c2pKey: Data(repeating: 0x11, count: 32),
                p2cKey: Data(repeating: 0x22, count: 32),
                c2pNonceBase: Data([0x01, 0x02, 0x03, 0x04]),
                p2cNonceBase: Data([0x05, 0x06, 0x07, 0x08])
            )
            let state = AutoUpdateTrustState.fromCoordinatorPayload(
                payload,
                isV2: true,
                session: session,
                providerToken: nil,
                assignedProviderTokenAdopted: false,
                acceptProvisional: true
            )
            XCTAssertTrue(state.bearerlessDuplicate, "malformed auth_state \(badValue) must fail closed")
            XCTAssertEqual(state.verdict, .bearerlessDuplicate, "malformed auth_state \(badValue) must be notify-only")
        }
    }

    // Config loader must accept the flag from both YAML flat key,
    // YAML nested `autoupdate.accept_provisional`, and the env var.
    func testConfigLoaderReadsAcceptProvisionalFromYAMLFlatAndNestedAndEnv() throws {
        // 1. Flat YAML key.
        let flatYAML = """
        auto_update_accept_provisional: true
        """
        let fromFlat = try ConfigLoader.load(
            cli: CLIOverrides(configPath: "/tmp/provider.yaml"),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in flatYAML }
        )
        XCTAssertEqual(fromFlat.autoUpdateAcceptProvisional, true)

        // 2. Nested YAML block.
        let nestedYAML = """
        autoupdate:
          accept_provisional: true
        """
        let fromNested = try ConfigLoader.load(
            cli: CLIOverrides(configPath: "/tmp/provider.yaml"),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in nestedYAML }
        )
        XCTAssertEqual(fromNested.autoUpdateAcceptProvisional, true)

        // 3. Env var overrides YAML (matches existing precedence).
        let fromEnv = try ConfigLoader.load(
            cli: CLIOverrides(configPath: "/tmp/provider.yaml"),
            environment: ["MACPROVIDER_AUTO_UPDATE_ACCEPT_PROVISIONAL": "false"],
            fileExists: { _ in true },
            readFile: { _ in flatYAML }
        )
        XCTAssertEqual(fromEnv.autoUpdateAcceptProvisional, false)

        // 4. Default is nil in config; runtime treats nil as enabled for
        //    provisional-tier autoupdate unless explicitly set false.
        let fromDefault = try ConfigLoader.load(
            cli: CLIOverrides(configPath: "/tmp/provider.yaml"),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "port: 8080" }
        )
        XCTAssertNil(fromDefault.autoUpdateAcceptProvisional)
        XCTAssertTrue(AutoUpdateConfig.acceptProvisional(fromDefault))
        var optedOut = AppConfig.defaults(configPath: "/tmp/provider.yaml")
        optedOut.autoUpdateAcceptProvisional = false
        XCTAssertFalse(AutoUpdateConfig.acceptProvisional(optedOut))
    }
}

private extension ISO8601DateFormatter {
    static let autoupdateTest: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

private enum SimulatedCutoverInterruption: Error, Equatable {
    case stop
}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class TempHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class AutoUpdateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class AutoUpdateMockURLProtocol: URLProtocol {
    static var responses: [URL: (status: Int, body: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = Self.responses[url] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
