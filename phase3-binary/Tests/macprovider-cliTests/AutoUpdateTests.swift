import Foundation
import XCTest
@testable import MacProviderCore
@testable import macprovider_cli

final class AutoUpdateTests: XCTestCase {
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
            "self_test_failed",
            "drain_timeout",
            "trust_state_lost",
            "post_start_crash",
            "post_start_health_failed",
            "post_start_rejoin_timeout",
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
        do {
            let lock = try store.acquireLock()
            XCTAssertTrue(store.updateLockIsLive())
            withExtendedLifetime(lock) {}
        }
        XCTAssertFalse(store.updateLockIsLive())

        try store.completeSuccessfulUpdate(marker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.successSentinelPath(binaryURL: binary, updateID: marker.updateID).path))

        try store.finalizeSuccessfulUpdate(marker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.successSentinelPath(binaryURL: binary, updateID: marker.updateID).path))
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertEqual(store.cooldown(target: marker.targetVersion, failureClass: .orphanedPendingMarker)?.attempt, 1)
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

    func testSuccessCleanupIsIdempotentAcrossCrashSteps() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        let (marker, binary, backup) = try makePendingMarkerFixture(store: store, fixture: fixture, backupContents: "old", targetContents: "new")
        let sentinel = store.successSentinelPath(binaryURL: binary, updateID: marker.updateID)

        try store.writeSuccessSentinel(binaryURL: binary, updateID: marker.updateID, targetVersion: marker.targetVersion)
        try store.completeSuccessfulUpdate(marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        try store.writePending(marker)
        try Data("old".utf8).write(to: backup)
        FileManager.default.createFile(atPath: store.lockURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        store.clearPending()
        try store.completeSuccessfulUpdate(marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lockURL.path))
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
                    stableReason: "tier_demoted"
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: {},
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
                    stableReason: "tier_demoted"
                )
            },
            drain: { _ in true },
            sendReady: {},
            restartLaunchd: {},
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
            restartLaunchd: {},
            currentBinaryURL: { binary },
            rollbackObserverAvailable: { true },
            launchdProviderAvailable: { true }
        )

        updater.rollbackCommittedSwapAfterRestartFailureForTest(marker)

        XCTAssertEqual(try String(contentsOf: binary), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.lockURL.path))
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

    func testTrustVerdictProvisionalWithoutAcceptFlagStaysIneligible() {
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
            // acceptProvisional defaults to false
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

        // 4. Default is nil (unset), preserving the pinned-only trust
        //    posture for existing deployments that haven't opted in.
        let fromDefault = try ConfigLoader.load(
            cli: CLIOverrides(configPath: "/tmp/provider.yaml"),
            environment: [:],
            fileExists: { _ in true },
            readFile: { _ in "port: 8080" }
        )
        XCTAssertNil(fromDefault.autoUpdateAcceptProvisional)
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
