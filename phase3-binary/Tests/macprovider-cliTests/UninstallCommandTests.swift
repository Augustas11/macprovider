import XCTest
@testable import macprovider_cli

final class UninstallCommandTests: XCTestCase {
    func testArtifactPathsMatchCanonicalInstallLayout() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let paths = UninstallCommand.artifactPaths(home: home)

        XCTAssertEqual(paths.binary.path, "/Users/tester/.local/bin/macprovider-cli")
        XCTAssertEqual(paths.supportDirectory.path, "/Users/tester/macprovider")
        XCTAssertEqual(paths.logsDirectory.path, "/Users/tester/Library/Logs/macprovider")
        XCTAssertEqual(paths.plist.path, "/Users/tester/Library/LaunchAgents/live.streamvc.macprovider.plist")
        XCTAssertEqual(paths.cacheDirectory.path, "/Users/tester/.cache/macprovider")
    }
}
