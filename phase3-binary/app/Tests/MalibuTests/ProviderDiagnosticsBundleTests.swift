import Foundation
import XCTest
@testable import Malibu

final class ProviderDiagnosticsBundleTests: XCTestCase {
    func testBundleIncludesLifecycleAndWatchdogEvidenceWithoutSecrets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let watchdog = root.appendingPathComponent("watchdog.log")
        try """
        [2026-07-14T12:00:00Z] recovery action=restored_prior_release reason=readiness_timeout
        [2026-07-14T12:00:01Z] Authorization: Bearer watchdog-secret-value
        """.write(to: watchdog, atomically: true, encoding: .utf8)

        var snapshot = AgentSnapshot.empty
        snapshot.state = .reconnecting
        snapshot.localProviderID = "provider-a"
        snapshot.cliVersion = "1.8.33"
        snapshot.compatibilitySetID = "Augustas11/macprovider:v1.8.33@abc123"
        snapshot.lifecycleRecordState = "valid"
        snapshot.lifecycleSequence = 42
        snapshot.lifecycleTransitionID = "11111111-1111-1111-1111-111111111111"
        snapshot.lifecycleState = "watchdog_recovery"
        snapshot.lifecycleReason = "readiness_timeout"
        snapshot.lifecycleWriter = "watchdog"
        snapshot.lifecycleLastWatchdog = ProviderLifecycleEventSnapshot(
            sequence: 41,
            transitionID: "22222222-2222-4222-8222-222222222222",
            transitionAt: Date(timeIntervalSince1970: 1_752_499_100),
            state: "watchdog_recovery",
            reason: "watchdog_rollback_post_start_rejoin_timeout",
            writer: "watchdog",
            compatibilitySetID: "Augustas11/macprovider:v1.8.33@abc123",
            operationID: "watchdog-recovery:update-1"
        )
        snapshot.credentialState = "ready"
        snapshot.credentialRestartSafe = true
        snapshot.lastError = "provider_token=must-not-export"
        snapshot.currentModelID = "/Users/provider/.cache/model"
        snapshot.localStatusContractCompatible = true
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "11111111-1111-4111-8111-111111111111"
        snapshot.statusObservedAt = Date(timeIntervalSince1970: 1_752_499_199)
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        snapshot.networkState = "buyer_serving_unknown"

        let data = try ProviderDiagnosticsBundle.make(
            snapshot: snapshot,
            providerLogLines: [
                "provider healthy",
                "api_key=must-not-export",
                "GET https://example.test/status?access_token=must-not-export",
                "model artifact hash mismatch at /Users/provider/.cache/model.safetensors host=provider-mac.local ip=192.168.1.44\u{001B}",
            ],
            watchdogLogURL: watchdog,
            appVersion: "1.8.33",
            now: Date(timeIntervalSince1970: 1_752_499_200)
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("watchdog_recovery"), text)
        XCTAssertTrue(text.contains("Augustas11/macprovider:v1.8.33@abc123"), text)
        XCTAssertTrue(text.contains("\"compatibility_set_id\" : \"Augustas11/macprovider:v1.8.33@abc123\""), text)
        XCTAssertTrue(text.contains("\"admission_identity\""), text)
        XCTAssertTrue(text.contains("\"schema\" : \"malibu.provider-diagnostics.v2\""), text)
        XCTAssertTrue(text.contains("\"schema_version\" : 2"), text)
        XCTAssertTrue(text.contains("\"minimum_reader_version\" : 1"), text)
        XCTAssertTrue(text.contains("\"diagnostic_findings\""), text)
        XCTAssertTrue(text.contains("\"signature_id\" : \"serve_unresponsive\""), text)
        XCTAssertTrue(text.contains("\"signature_id\" : \"artifact_hash_mismatch\""), text)
        XCTAssertTrue(text.contains("restored_prior_release"), text)
        XCTAssertTrue(text.contains("readiness_timeout"), text)
        XCTAssertTrue(text.contains("watchdog_rollback_post_start_rejoin_timeout"), text)
        XCTAssertTrue(text.contains("[redacted]"), text)
        XCTAssertTrue(text.contains("[path]"), text)
        XCTAssertTrue(text.contains("\"model_id\" : \"[path]\""), text)
        XCTAssertTrue(text.contains("[host]"), text)
        XCTAssertTrue(text.contains("[ip]"), text)
        XCTAssertFalse(text.contains("must-not-export"), text)
        XCTAssertFalse(text.contains("/Users/provider/.cache/model"), text)
        XCTAssertFalse(text.lowercased().contains("bearer watchdog-secret"), text)
        XCTAssertFalse(text.contains("/Users/provider"), text)
        XCTAssertFalse(text.contains("provider-mac.local"), text)
        XCTAssertFalse(text.contains("192.168.1.44"), text)
        XCTAssertFalse(text.contains("\u{001B}"), text)
        XCTAssertFalse(text.contains("\u{009B}"), text)
        XCTAssertFalse(text.contains("\\u001B"), text)
        XCTAssertFalse(text.contains("\\u009B"), text)
    }

    func testWatchdogTailRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-diagnostics-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.log")
        let link = root.appendingPathComponent("watchdog.log")
        try "not safe through a link".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertEqual(ProviderDiagnosticsBundle.readRedactedTail(link), [])
    }

    func testBundleClassifiesRawWatchdogAndLaunchdRepairBeforeExportRedaction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("malibu-diagnostics-raw-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let watchdog = root.appendingPathComponent("watchdog.log")
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        try "autoupdate recovery_error=acl_write_rejected:\(homePath)\n"
            .write(to: watchdog, atomically: true, encoding: .utf8)

        var snapshot = AgentSnapshot.empty
        snapshot.state = .reconnecting
        snapshot.localStatusContractCompatible = true
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservedAt = Date(timeIntervalSince1970: 1_752_499_199)
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        snapshot.networkState = "buyer_serving"

        let data = try ProviderDiagnosticsBundle.make(
            snapshot: snapshot,
            providerLogLines: [
                "provider process unhealthy: launchd service live.malibu.provider has no validated PID at \(homePath)/macprovider-cli"
            ],
            watchdogLogURL: watchdog,
            appVersion: "1.8.33",
            launchdNeedsRepair: true,
            now: Date(timeIntervalSince1970: 1_752_499_200)
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("\"signature_id\" : \"stale_launch_agent\""), text)
        XCTAssertTrue(text.contains("\"signature_id\" : \"autoupdate_home_acl_rejected\""), text)
        XCTAssertTrue(text.contains("[path]"), text)
        XCTAssertFalse(text.contains(homePath), text)
    }
}
