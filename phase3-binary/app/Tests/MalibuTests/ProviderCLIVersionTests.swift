import XCTest
@testable import Malibu

final class ProviderCLIVersionTests: XCTestCase {
    func testCompareSemverOrdering() {
        XCTAssertEqual(ProviderCLIVersion.compare("1.2.0", "1.2.1"), .ascending)
        XCTAssertEqual(ProviderCLIVersion.compare("v1.2.1", "1.2.1"), .same)
        XCTAssertEqual(ProviderCLIVersion.compare("1.3.0", "1.2.9"), .descending)
    }

    func testUpdateTargetPrefersNewestCandidate() {
        XCTAssertEqual(
            ProviderCLIVersion.updateTarget(current: "1.8.0", recommended: "1.8.2", latestRelease: "1.8.5"),
            "1.8.5"
        )
        XCTAssertNil(
            ProviderCLIVersion.updateTarget(current: "1.8.5", recommended: "1.8.3", latestRelease: "1.8.4")
        )
    }
}

final class AgentSnapshotCLIVersionPresenterTests: XCTestCase {
    func testUpdateBadgeShowsWhenUpdateAvailable() {
        var snapshot = AgentSnapshot.empty
        snapshot.cliVersion = "1.8.0"
        snapshot.latestReleaseVersion = "1.8.5"
        XCTAssertEqual(AgentSnapshotPresenter.updateBadge(snapshot), "↑")
    }

    func testUpdateBadgeHiddenWhileUpdating() {
        var snapshot = AgentSnapshot.empty
        snapshot.cliVersion = "1.8.0"
        snapshot.latestReleaseVersion = "1.8.5"
        snapshot.cliUpdateInProgress = true
        XCTAssertNil(AgentSnapshotPresenter.updateBadge(snapshot))
    }

    func testCliVersionLineShowsTarget() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.cliVersion = "1.8.0"
        snapshot.coordinatorRecommendedVersion = "1.8.6"
        XCTAssertTrue(AgentSnapshotPresenter.cliVersionLine(snapshot).contains("→ v1.8.6 available"))
    }
}
