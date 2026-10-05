import XCTest
@testable import macprovider_cli

/// #616 canonical hand-off: a newer running binary must not silently re-exec
/// into an older canonical install.
final class CanonicalReexecDecisionTests: XCTestCase {
    func testOlderCanonicalIsRefused() {
        XCTAssertEqual(
            CanonicalReexecDecision.decide(canonicalVersion: "1.8.123", runningVersion: "1.8.214"),
            .refuse(canonicalVersion: "1.8.123")
        )
        XCTAssertEqual(
            CanonicalReexecDecision.decide(canonicalVersion: "1.8.99", runningVersion: "1.8.100"),
            .refuse(canonicalVersion: "1.8.99")
        )
    }

    func testEqualCanonicalReexecs() {
        XCTAssertEqual(CanonicalReexecDecision.decide(canonicalVersion: "1.8.214", runningVersion: "1.8.214"), .reexec)
    }

    func testNewerCanonicalReexecs() {
        XCTAssertEqual(CanonicalReexecDecision.decide(canonicalVersion: "1.8.215", runningVersion: "1.8.214"), .reexec)
        XCTAssertEqual(CanonicalReexecDecision.decide(canonicalVersion: "1.9.0", runningVersion: "1.8.214"), .reexec)
    }

    func testUnknownCanonicalVersionKeepsReexec() {
        XCTAssertEqual(CanonicalReexecDecision.decide(canonicalVersion: nil, runningVersion: "1.8.214"), .reexec)
    }

    func testFatalLineNamesPathAndBothVersions() {
        let line = CanonicalReexecDecision.fatalLine(
            path: "/Users/x/macprovider/macprovider-cli", canonicalVersion: "1.8.123", runningVersion: "1.8.214"
        )
        XCTAssertTrue(line.hasPrefix(
            "FATAL canonical_install_older path=/Users/x/macprovider/macprovider-cli canonical=1.8.123 running=1.8.214: "
        ))
        XCTAssertTrue(line.hasSuffix("\n"))
    }
}
