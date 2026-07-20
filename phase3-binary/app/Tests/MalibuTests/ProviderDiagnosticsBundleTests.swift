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

        let data = try ProviderDiagnosticsBundle.make(
            snapshot: snapshot,
            providerLogLines: [
                "provider healthy",
                "api_key=must-not-export",
                "GET https://example.test/status?access_token=must-not-export",
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
        XCTAssertTrue(text.contains("restored_prior_release"), text)
        XCTAssertTrue(text.contains("readiness_timeout"), text)
        XCTAssertTrue(text.contains("watchdog_rollback_post_start_rejoin_timeout"), text)
        XCTAssertTrue(text.contains("[redacted]"), text)
        XCTAssertFalse(text.contains("must-not-export"), text)
        XCTAssertFalse(text.lowercased().contains("bearer watchdog-secret"), text)
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
}
