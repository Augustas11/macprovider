import XCTest
@testable import Malibu

@MainActor
final class CLIInstallTeardownTests: XCTestCase {
    func testUninstallReturnsWarningWhenRunnerFails() async {
        let result = await CLIInstallTeardown.uninstallBackgroundProvider {
            throw NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.warnings, ["CLI uninstall failed: boom"])
    }

    func testUninstallSucceedsWhenRunnerCompletes() async {
        let result = await CLIInstallTeardown.uninstallBackgroundProvider {}
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.warnings.isEmpty)
    }
}
