import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-001 FR-12 / SPEC-020 R-4.14 — validated local stop intent.
final class StopIntentMarkerTests: XCTestCase {
    private var home: URL!
    /// Deterministic process-start provider so tests do not depend on real PIDs.
    private let startFor: @Sendable (pid_t) -> Int64? = { pid in Int64(pid) * 1_000 + 7 }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("stop-intent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func recordMarker(pid: Int32 = 4242, ttl: Int64 = 120, now: Date, boot: String = "boot-a") -> Bool {
        StopIntentMarker.record(
            targetPID: pid, reason: "uninstall", ttlSeconds: ttl,
            home: home, bootSession: boot, now: now, processStartMicroseconds: startFor)
    }

    private func consume(pid: Int32 = 4242, now: Date, boot: String = "boot-a",
                         start: (@Sendable (pid_t) -> Int64?)? = nil) -> Bool {
        StopIntentMarker.consumeIfValid(
            currentPID: pid, home: home, bootSession: boot, now: now,
            processStartMicroseconds: start ?? startFor)
    }

    // Write a raw marker payload directly, bypassing record(), to exercise the
    // consumer's fail-closed parsing.
    private func writeRaw(_ object: [String: Any], mode: Int = 0o600) throws {
        let url = StopIntentMarker.markerURL(home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func validObject(pid: Int = 4242, now: Date) -> [String: Any] {
        [
            "schema": StopIntentMarker.schema,
            "pid": pid,
            "process_start_us": startFor(pid_t(pid))!,
            "boot_session": "boot-a",
            "expires_wall_ms": Int64(now.timeIntervalSince1970 * 1000) + 60_000,
            "reason": "uninstall",
        ]
    }

    func testRecordThenConsumeMatchingIsValidAndConsumesOnce() {
        let now = Date()
        XCTAssertTrue(recordMarker(now: now))
        XCTAssertTrue(consume(now: now))
        // Consume-once: the marker is deleted, so a second consume is invalid.
        XCTAssertFalse(consume(now: now))
    }

    func testConsumeWithDifferentPIDIsInvalid() {
        let now = Date()
        _ = recordMarker(pid: 4242, now: now)
        XCTAssertFalse(consume(pid: 9999, now: now))
    }

    func testConsumeWithDifferentBootSessionIsInvalid() {
        let now = Date()
        _ = recordMarker(now: now, boot: "boot-a")
        XCTAssertFalse(consume(now: now, boot: "boot-b"))
    }

    func testProcessStartMismatchIsInvalid() {
        // PID reuse within the same boot: same pid, different process-start time.
        let now = Date()
        _ = recordMarker(pid: 4242, now: now)
        XCTAssertFalse(consume(pid: 4242, now: now, start: { _ in 999_999 }))
    }

    func testExpiredMarkerIsInvalid() {
        let recordedAt = Date()
        _ = recordMarker(ttl: 60, now: recordedAt)
        XCTAssertFalse(consume(now: recordedAt.addingTimeInterval(61)))
    }

    func testMissingMarkerIsInvalid() {
        XCTAssertFalse(consume(now: Date()))
    }

    func testMalformedMarkerIsInvalidAndConsumed() throws {
        let url = StopIntentMarker.markerURL(home: home)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertFalse(consume(now: Date()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a malformed marker must still be consumed (deleted)")
    }

    func testWrongSchemaIsInvalid() throws {
        let now = Date()
        var obj = validObject(now: now)
        obj["schema"] = "macprovider.stop-intent.v2"
        try writeRaw(obj)
        XCTAssertFalse(consume(now: now))
    }

    func testFractionalPIDIsInvalid() throws {
        let now = Date()
        var obj = validObject(now: now)
        obj["pid"] = 4242.5
        try writeRaw(obj)
        XCTAssertFalse(consume(now: now))
    }

    func testStringPIDIsInvalid() throws {
        let now = Date()
        var obj = validObject(now: now)
        obj["pid"] = "4242"
        try writeRaw(obj)
        XCTAssertFalse(consume(now: now))
    }

    func testNegativePIDIsInvalid() throws {
        let now = Date()
        var obj = validObject(now: now)
        obj["pid"] = -1
        try writeRaw(obj)
        XCTAssertFalse(consume(pid: -1, now: now))
    }

    func testWorldReadableMarkerIsRejected() throws {
        let now = Date()
        try writeRaw(validObject(now: now), mode: 0o644)
        XCTAssertFalse(consume(now: now), "a marker not mode 0600 must be rejected")
    }

    func testRecordFailsClosedWithoutBootSession() {
        XCTAssertFalse(StopIntentMarker.record(
            targetPID: 4242, reason: "uninstall", home: home, bootSession: nil,
            now: Date(), processStartMicroseconds: startFor))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: StopIntentMarker.markerURL(home: home).path))
    }

    func testRecordFailsClosedWhenProcessStartUnresolvable() {
        XCTAssertFalse(StopIntentMarker.record(
            targetPID: 4242, reason: "uninstall", home: home, bootSession: "boot-a",
            now: Date(), processStartMicroseconds: { _ in nil }))
    }

    func testConsumeFailsClosedWhenCurrentBootSessionUnavailable() {
        let now = Date()
        _ = recordMarker(now: now)
        XCTAssertFalse(StopIntentMarker.consumeIfValid(
            currentPID: 4242, home: home, bootSession: nil, now: now,
            processStartMicroseconds: startFor))
    }

    func testRecordedMarkerIsPrivateMode0600() {
        let now = Date()
        XCTAssertTrue(recordMarker(now: now))
        let mode = (try? FileManager.default.attributesOfItem(
            atPath: StopIntentMarker.markerURL(home: home).path)[.posixPermissions] as? Int)
        XCTAssertEqual((mode ?? 0) & 0o777, 0o600)
    }

    func testRecordOverPreExistingWorldReadableMarkerPublishesPrivate() throws {
        let now = Date()
        // A pre-existing loose-mode marker at the destination must not leak its
        // permissions onto the freshly recorded marker (rename(2) publish).
        try writeRaw(validObject(now: now), mode: 0o644)
        XCTAssertTrue(recordMarker(now: now))
        let mode = (try? FileManager.default.attributesOfItem(
            atPath: StopIntentMarker.markerURL(home: home).path)[.posixPermissions] as? Int)
        XCTAssertEqual((mode ?? 0) & 0o777, 0o600, "republish must land 0600, not inherit 0644")
        XCTAssertTrue(consume(now: now))
    }
}
