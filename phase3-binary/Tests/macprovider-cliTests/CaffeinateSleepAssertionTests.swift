import Darwin
import XCTest
@testable import macprovider_cli

/// The provider must stay reachable while connected, but on a laptop the
/// keep-awake assertion must not hold the display on or claim user activity:
/// `caffeinate -d` prevents display sleep and `-u` turns the display back on,
/// for as long as the provider is connected, even with no jobs.
final class CaffeinateSleepAssertionTests: XCTestCase {
    func testKeepsSystemAwakeWithoutHoldingDisplayOrUserActivity() {
        let arguments = CaffeinateSleepAssertion.arguments(watchingPID: 4242)
        XCTAssertEqual(arguments, ["-ims", "-w", "4242"])

        let flags = Set(arguments[0].dropFirst())
        XCTAssertTrue(flags.contains("i"), "idle system sleep must stay prevented so the provider stays reachable")
        XCTAssertTrue(flags.contains("s"), "system sleep on AC must stay prevented")
        XCTAssertFalse(flags.contains("d"), "display sleep must be allowed")
        XCTAssertFalse(flags.contains("u"), "must not declare the user active (turns the display on)")
    }
}
