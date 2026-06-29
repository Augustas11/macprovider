import Foundation
import XCTest
@testable import MacProviderCore
@testable import macprovider_cli

final class AutoUpdateTests: XCTestCase {
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

    func testSignedPolicyPersistenceIsMonotonic() throws {
        let fixture = try TempHome()
        let store = AutoUpdateMarkerStore(homeDirectory: fixture.url)
        try store.ensureTrustedRoot()
        store.updateSignedPolicy(minimum: "1.7.0", revoked: ["1.6.1"])
        store.updateSignedPolicy(minimum: "1.6.0", revoked: [])
        var policy = store.effectivePolicy()
        XCTAssertEqual(policy.minimum, "1.7.0")
        XCTAssertTrue(policy.revoked.contains("1.6.1"))
        store.updateSignedPolicy(minimum: "1.8.0", revoked: ["1.7.1"])
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
