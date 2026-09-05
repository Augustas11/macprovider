import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-025 §5.4 / RFC-001 F5 — supervisor beacon reader/projector.
final class SupervisorBeaconReaderTests: XCTestCase {
    private var dir: URL!
    private var beacon: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-beacon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        beacon = dir.appendingPathComponent("supervisor-beacon.json", isDirectory: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ object: [String: Any], mode: Int = 0o600) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: beacon)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: beacon.path)
    }

    private func restartBeacon(boot: String = "BOOT-A") -> [String: Any] {
        [
            "schema": "macprovider.supervisor-event.v1",
            "ts": "2026-09-05T00:00:00Z",
            "kind": "restart",
            "boot_id": boot,
            "seq": 3,
            "supervisor_label": "provider-watchdog",
            "supervisor_version": "1.0",
            "restarts_total": 1,
            "deferrals_total": 0,
            "last_restart": [
                "seq": 3,
                "ts": "2026-09-05T00:00:00Z",
                "reason": "wedge",
                "cooldown_state": "armed",
                "service_instance": "old-inst",
                "model_liveness": [
                    "token_age_ms": 1500,
                    "active_inference": true,
                    "active_inference_age_ms": 1500,
                ],
            ],
            "last_deferral": NSNull(),
        ]
    }

    func testValidRestartBeaconProjects() throws {
        try write(restartBeacon())
        let out = SupervisorBeaconReader.lastWireObject(url: beacon, currentBootSession: "BOOT-A")
        let obj = try XCTUnwrap(out)
        XCTAssertEqual(obj["schema"] as? String, "macprovider.supervisor-event.v1")
        XCTAssertEqual(obj["kind"] as? String, "restart")
        XCTAssertEqual(obj["seq"] as? UInt64, 3)
        XCTAssertEqual(obj["restarts_total"] as? UInt64, 1)
        XCTAssertEqual(obj["supervisor_label"] as? String, "provider-watchdog")
        let lr = try XCTUnwrap(obj["last_restart"] as? [String: Any])
        XCTAssertEqual(lr["reason"] as? String, "wedge")
        XCTAssertEqual(lr["cooldown_state"] as? String, "armed")
        XCTAssertEqual(lr["service_instance"] as? String, "old-inst")
        let ml = try XCTUnwrap(lr["model_liveness"] as? [String: Any])
        XCTAssertEqual(ml["token_age_ms"] as? UInt64, 1500)
        XCTAssertEqual(ml["active_inference"] as? Bool, true)
    }

    func testWrongBootIsDropped() throws {
        try write(restartBeacon(boot: "BOOT-OLD"))
        XCTAssertNil(SupervisorBeaconReader.lastWireObject(url: beacon, currentBootSession: "BOOT-NEW"))
    }

    func testWrongSchemaIsDropped() throws {
        var obj = restartBeacon()
        obj["schema"] = "something.else.v9"
        try write(obj)
        XCTAssertNil(SupervisorBeaconReader.lastWireObject(url: beacon, currentBootSession: "BOOT-A"))
    }

    func testUnknownKeysAreDroppedLocally() throws {
        var obj = restartBeacon()
        obj["secret_home_path"] = "/Users/someone/private"
        try write(obj)
        let out = try XCTUnwrap(SupervisorBeaconReader.lastWireObject(url: beacon, currentBootSession: "BOOT-A"))
        XCTAssertNil(out["secret_home_path"], "unknown keys must be dropped before uplink")
    }

    func testRawLaunchdLabelMappedToUnknown() throws {
        var obj = restartBeacon()
        obj["supervisor_label"] = "live.operator.internal.hostname-42"
        try write(obj)
        let out = try XCTUnwrap(SupervisorBeaconReader.lastWireObject(url: beacon, currentBootSession: "BOOT-A"))
        XCTAssertEqual(out["supervisor_label"] as? String, "unknown")
    }

    func testNonPrivateModeIsRejected() throws {
        try write(restartBeacon(), mode: 0o644)
        XCTAssertNil(SupervisorBeaconReader.lastWireObject(url: beacon, currentBootSession: "BOOT-A"),
                     "a world-readable/group-writable beacon must fail the hardened read")
    }

    func testMissingFileYieldsNil() {
        XCTAssertNil(SupervisorBeaconReader.lastWireObject(url: beacon, currentBootSession: "BOOT-A"))
    }

    /// Fail-safe: an out-of-range/non-finite numeric field must resolve to nil,
    /// never TRAP while building the heartbeat.
    func testOversizedNumericFieldFailsClosed() throws {
        // seq far beyond UInt64.max (and an over-range model_liveness age).
        let raw = """
        {"schema":"macprovider.supervisor-event.v1","kind":"beacon","boot_id":"BOOT-A",\
        "seq":1e400,"supervisor_label":"provider-watchdog","supervisor_version":"1.0",\
        "restarts_total":0,"deferrals_total":0,"last_restart":null,"last_deferral":null}
        """
        try Data(raw.utf8).write(to: beacon)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: beacon.path)
        // seq is required; an unparseable seq drops the whole beacon to nil.
        XCTAssertNil(SupervisorBeaconReader.lastWireObject(url: beacon, currentBootSession: "BOOT-A"))
    }

    func testOversizedModelLivenessAgeFailsClosedToNull() throws {
        // A large but FINITE number (1e30) is valid JSON yet overflows UInt64:
        // the field must project to null (not trap, not drop the whole beacon).
        let raw = """
        {"schema":"macprovider.supervisor-event.v1","kind":"restart","boot_id":"BOOT-A","seq":3,\
        "supervisor_label":"provider-watchdog","supervisor_version":"1.0","restarts_total":1,"deferrals_total":0,\
        "last_restart":{"seq":3,"ts":"t","reason":"wedge","cooldown_state":"armed","service_instance":"old",\
        "model_liveness":{"token_age_ms":1e30,"active_inference":true,"active_inference_age_ms":5}},"last_deferral":null}
        """
        try Data(raw.utf8).write(to: beacon)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: beacon.path)
        let out = try XCTUnwrap(SupervisorBeaconReader.lastWireObject(url: beacon, currentBootSession: "BOOT-A"))
        let lrOut = try XCTUnwrap(out["last_restart"] as? [String: Any])
        let ml = try XCTUnwrap(lrOut["model_liveness"] as? [String: Any])
        XCTAssertTrue(ml["token_age_ms"] is NSNull, "out-of-range token_age_ms must project to null, not crash")
        XCTAssertEqual(ml["active_inference_age_ms"] as? UInt64, 5)
    }

    func testBeaconKindHasNullRestart() throws {
        let obj: [String: Any] = [
            "schema": "macprovider.supervisor-event.v1",
            "kind": "beacon",
            "boot_id": "BOOT-A",
            "seq": 5,
            "supervisor_label": "legacy-watchdog",
            "supervisor_version": "1.0",
            "restarts_total": 2,
            "deferrals_total": 1,
            "last_restart": NSNull(),
            "last_deferral": NSNull(),
        ]
        try write(obj)
        let out = try XCTUnwrap(SupervisorBeaconReader.lastWireObject(url: beacon, currentBootSession: "BOOT-A"))
        XCTAssertEqual(out["kind"] as? String, "beacon")
        XCTAssertEqual(out["supervisor_label"] as? String, "legacy-watchdog")
        XCTAssertTrue(out["last_restart"] is NSNull)
    }
}
