import Foundation
import XCTest
@testable import macprovider_cli

/// F2 (#1366): the updater's trusted-root check on the installed watchdog
/// coordinator host must accept an optional `:port` suffix so a provider
/// pointed at a non-default-port coordinator can self-update, while keeping the
/// original host length/charset guard and rejecting a malformed port.
final class CoordinatorHostValidationTests: XCTestCase {
    func testAcceptsPortlessHosts() {
        XCTAssertTrue(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("coordinator.malibu.tech"))
        XCTAssertTrue(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("127.0.0.1"))
        XCTAssertTrue(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("localhost"))
    }

    func testAcceptsHostPort() {
        XCTAssertTrue(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("127.0.0.1:18445"))
        XCTAssertTrue(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("coordinator.malibu.tech:8443"))
        XCTAssertTrue(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("localhost:1"))
        XCTAssertTrue(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("localhost:65535"))
    }

    func testRejectsInvalidPort() {
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("127.0.0.1:0"))
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("127.0.0.1:65536"))
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("127.0.0.1:99999"))
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("127.0.0.1:abc"))
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("127.0.0.1:"))
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("127.0.0.1: 18445"))
    }

    func testRejectsInvalidHost() {
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue(""))
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue(":18445"))
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("host_name:8443"))
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("has space"))
        // Bare IPv6 (multiple colons) is not a supported coordinator host form.
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("::1"))
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue("fe80::1:8443"))
        // Host part longer than 253 chars is rejected.
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue(String(repeating: "a", count: 254)))
        XCTAssertFalse(AutoUpdateMarkerStore.isTrustedCoordinatorHostValue(String(repeating: "a", count: 254) + ":8443"))
    }
}
