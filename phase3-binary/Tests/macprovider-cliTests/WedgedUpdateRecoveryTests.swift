import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

/// F3 (#1363): a failed self-update can wedge the provider — `pending.json` in
/// `restoring_previous` plus an updater-owned `rollback_in_progress` lifecycle
/// record fence both `serve` and `update`, and the only in-CLI resolver runs
/// inside `serve`, which is itself fenced. These tests pin the serve-independent
/// recovery: an abandoned wedge is cleared and `serve` can start again, while a
/// genuinely in-progress or live rollback is never un-fenced.
final class WedgedUpdateRecoveryTests: XCTestCase {
    // MARK: - fixtures

    private final class TempRoot {
        let home: URL
        let lifecycleRecordURL: URL

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("wedged-update-recovery-\(UUID().uuidString)", isDirectory: true)
            lifecycleRecordURL = home
                .appendingPathComponent("lifecycle", isDirectory: true)
                .appendingPathComponent("state-v1.json")
            try FileManager.default.createDirectory(
                at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }

        deinit { try? FileManager.default.removeItem(at: home) }
    }

    /// Matches `ISO8601DateFormatter.autoupdate` (internet date-time, GMT), so
    /// the produced deadline round-trips through the marker validator.
    private func isoDeadline(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func writeUpdaterRollbackLifecycle(_ store: ProviderLifecycleStateStore) throws {
        _ = try store.transition(
            to: .rollbackInProgress,
            reasonCode: "self_update_rollback",
            writer: .updater,
            providerID: "provider-test",
            modelID: "llama-3.2-3b-instruct",
            operationID: "self-update:\(UUID().uuidString.lowercased())"
        )
    }

    /// The exact serve startup transition. It is fenced while the record is
    /// updater-owned rollback and only succeeds once recovery has translated
    /// the record into an installer-owned one.
    @discardableResult
    private func attemptServeStart(_ store: ProviderLifecycleStateStore) throws -> ProviderLifecycleStateRecord {
        try store.transition(
            to: .startingProvider,
            reasonCode: "launchd_service_started",
            writer: .serve,
            providerID: "provider-test",
            modelID: "llama-3.2-3b-instruct",
            operationID: "serve:\(UUID().uuidString.lowercased())"
        )
    }

    // MARK: - tests

    func testUnfencesAbandonedUpdaterRollbackWithNoMarker() throws {
        let root = try TempRoot()
        let lifecycleStore = ProviderLifecycleStateStore(url: root.lifecycleRecordURL)
        try writeUpdaterRollbackLifecycle(lifecycleStore)

        // Precondition: a fresh serve child is fenced by the updater-owned
        // rollback record.
        XCTAssertThrowsError(try attemptServeStart(lifecycleStore)) { error in
            guard case .operationFenced = error as? ProviderLifecycleStateError else {
                return XCTFail("expected operationFenced, got \(error)")
            }
        }

        let recovery = WedgedUpdateRecovery(
            markerStore: AutoUpdateMarkerStore(homeDirectory: root.home),
            lifecycleStore: lifecycleStore
        )
        XCTAssertEqual(recovery.recover(), .recovered(markerOutcome: nil, lifecycleUnfenced: true))

        // The record is now installer-owned rollback, which serve may leave.
        let translated = try XCTUnwrap(try lifecycleStore.current())
        XCTAssertEqual(translated.writer, .installer)
        XCTAssertEqual(translated.state, .rollbackInProgress)
        XCTAssertEqual(translated.reasonCode, WedgedUpdateRecovery.translationReasonCode)

        // serve can now start.
        let started = try attemptServeStart(lifecycleStore)
        XCTAssertEqual(started.state, .startingProvider)
        XCTAssertEqual(started.writer, .serve)
    }

    func testRefusesWhenInstallerOwnerLive() throws {
        let root = try TempRoot()
        let lifecycleStore = ProviderLifecycleStateStore(url: root.lifecycleRecordURL)
        try writeUpdaterRollbackLifecycle(lifecycleStore)

        let recovery = WedgedUpdateRecovery(
            markerStore: AutoUpdateMarkerStore(
                homeDirectory: root.home,
                installerOwnerLiveOverride: { true }
            ),
            lifecycleStore: lifecycleStore
        )
        XCTAssertEqual(recovery.recover(), .ownerLive)

        // A live owner means a genuine mutation may be in flight; the fence
        // must stay exactly as it was.
        let unchanged = try XCTUnwrap(try lifecycleStore.current())
        XCTAssertEqual(unchanged.writer, .updater)
        XCTAssertEqual(unchanged.state, .rollbackInProgress)
    }

    func testRefusesFutureDeadlineTransaction() throws {
        let root = try TempRoot()
        let lifecycleStore = ProviderLifecycleStateStore(url: root.lifecycleRecordURL)
        try writeUpdaterRollbackLifecycle(lifecycleStore)

        let store = AutoUpdateMarkerStore(homeDirectory: root.home)
        try store.ensureTrustedRoot()
        let marker = AutoUpdatePendingMarker(
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.8.119",
            targetPath: root.home.appendingPathComponent("bin/macprovider-cli").path,
            backupPath: root.home.appendingPathComponent("bin/.macprovider-cli.rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee").path,
            size: 3,
            mode: 0o755,
            sha256: AutoUpdateEvent.sha256Hex("old"),
            markerDeadline: isoDeadline(Date().addingTimeInterval(1_800))
        )
        try store.writePending(marker)

        let recovery = WedgedUpdateRecovery(markerStore: store, lifecycleStore: lifecycleStore)
        XCTAssertEqual(recovery.recover(), .transactionActive)

        // Neither the marker nor the fence may be touched for a genuine
        // in-progress transaction.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.pendingURL.path))
        let unchanged = try XCTUnwrap(try lifecycleStore.current())
        XCTAssertEqual(unchanged.writer, .updater)
        XCTAssertEqual(unchanged.state, .rollbackInProgress)
    }

    func testRecoversExpiredMarkerAndUnfencesLifecycle() throws {
        let root = try TempRoot()
        let lifecycleStore = ProviderLifecycleStateStore(url: root.lifecycleRecordURL)
        try writeUpdaterRollbackLifecycle(lifecycleStore)

        let store = AutoUpdateMarkerStore(homeDirectory: root.home)
        try store.ensureTrustedRoot()
        FileManager.default.createFile(atPath: store.lockURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let binaryDir = root.home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let binary = binaryDir.appendingPathComponent("macprovider-cli")
        let backup = binaryDir.appendingPathComponent(".macprovider-cli.rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        try Data("new".utf8).write(to: binary)
        try Data("old".utf8).write(to: backup)
        let marker = AutoUpdatePendingMarker(
            updateID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            targetVersion: "1.8.119",
            targetPath: binary.path,
            backupPath: backup.path,
            size: 3,
            mode: 0o755,
            sha256: AutoUpdateEvent.sha256Hex("old"),
            markerDeadline: isoDeadline(Date().addingTimeInterval(-3_600))
        )
        try store.writePending(marker)

        let recovery = WedgedUpdateRecovery(markerStore: store, lifecycleStore: lifecycleStore)
        XCTAssertEqual(recovery.recover(), .recovered(markerOutcome: .restored(marker), lifecycleUnfenced: true))

        // The previous binary is restored and the pending marker cleared.
        XCTAssertEqual(try String(contentsOf: binary), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pendingURL.path))

        // And serve is un-fenced.
        let translated = try XCTUnwrap(try lifecycleStore.current())
        XCTAssertEqual(translated.writer, .installer)
        let started = try attemptServeStart(lifecycleStore)
        XCTAssertEqual(started.state, .startingProvider)
    }

    func testNoWedgeWhenLifecycleNotUpdaterOwned() throws {
        let root = try TempRoot()
        let lifecycleStore = ProviderLifecycleStateStore(url: root.lifecycleRecordURL)
        // An installer-owned rollback is not a wedge — serve can already leave it.
        _ = try lifecycleStore.transition(
            to: .rollbackInProgress,
            reasonCode: "install_admission_failed",
            writer: .installer,
            providerID: "provider-test",
            operationID: "install-rollback:1234"
        )
        let before = try XCTUnwrap(try lifecycleStore.current())

        let recovery = WedgedUpdateRecovery(
            markerStore: AutoUpdateMarkerStore(homeDirectory: root.home),
            lifecycleStore: lifecycleStore
        )
        XCTAssertEqual(recovery.recover(), .noWedge)

        let after = try XCTUnwrap(try lifecycleStore.current())
        XCTAssertEqual(after.sequence, before.sequence)
        XCTAssertEqual(after.writer, .installer)
    }
}
