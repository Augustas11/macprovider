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

    /// The hand-off fails closed: a missing (unreadable or timed-out), invalid,
    /// or non-strict canonical version is refused with its own reason.
    func testUnknownOrInvalidCanonicalVersionIsRefused() {
        for canonical in [nil, "", "garbage", "1.8", "1.8.214-beta", "1.8.214\n1.8.215", "latest"] as [String?] {
            XCTAssertEqual(
                CanonicalReexecDecision.decide(canonicalVersion: canonical, runningVersion: "1.8.214"),
                .refuseUnknownVersion,
                "canonical=\(String(describing: canonical))"
            )
        }
    }

    /// The normal autoupdate hand-off: a stale PATH copy re-execs into the
    /// freshly updated canonical install whose version reads newer.
    func testReadableNewerCanonicalAfterAutoupdateReexecs() {
        XCTAssertEqual(CanonicalReexecDecision.decide(canonicalVersion: "v1.8.215", runningVersion: "1.8.214"), .reexec)
        XCTAssertEqual(CanonicalReexecDecision.decide(canonicalVersion: "1.10.0", runningVersion: "1.9.99"), .reexec)
    }

    func testUnknownVersionFatalLineHasItsOwnReason() {
        let line = CanonicalReexecDecision.unknownVersionFatalLine(
            path: "/Users/x/macprovider/macprovider-cli", runningVersion: "1.8.214"
        )
        XCTAssertTrue(line.hasPrefix(
            "FATAL canonical_install_version_unknown path=/Users/x/macprovider/macprovider-cli running=1.8.214: "
        ))
        XCTAssertFalse(line.contains("canonical_install_older"))
        XCTAssertTrue(line.hasSuffix("\n"))
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
