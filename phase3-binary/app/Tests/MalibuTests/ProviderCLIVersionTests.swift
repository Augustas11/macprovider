import XCTest
@testable import Malibu

final class ProviderCLIVersionTests: XCTestCase {
    func testCompareSemverOrdering() {
        XCTAssertEqual(ProviderCLIVersion.compare("1.2.0", "1.2.1"), .ascending)
        XCTAssertEqual(ProviderCLIVersion.compare("v1.2.1", "1.2.1"), .same)
        XCTAssertEqual(ProviderCLIVersion.compare("1.3.0", "1.2.9"), .descending)
    }

    func testStrictVersionNormalizationRejectsOverflowAndLeadingZeroes() {
        XCTAssertEqual(ProviderCLIVersion.strictNormalize("v1.8.39"), "1.8.39")
        XCTAssertNil(ProviderCLIVersion.strictNormalize("999999999999999999999.0.0"))
        XCTAssertNil(ProviderCLIVersion.strictNormalize("01.8.39"))
        XCTAssertNil(ProviderCLIVersion.strictNormalize("1.08.39"))
        XCTAssertNil(ProviderCLIVersion.strictNormalize("1.8.039"))
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

    func testLatestBinaryWithMissingCompatibilitySetOffersRepair() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.cliVersion = "1.8.39"
        snapshot.latestReleaseVersion = "1.8.39"
        snapshot.statusObservationFresh = true
        snapshot.compatibilitySetID = nil

        XCTAssertNil(AgentSnapshotPresenter.updateTargetVersion(snapshot))
        XCTAssertTrue(AgentSnapshotPresenter.compatibilityRepairAvailable(snapshot))
        XCTAssertTrue(AgentSnapshotPresenter.updateAvailable(snapshot))
        XCTAssertEqual(AgentSnapshotPresenter.updateBadge(snapshot), "↑")
        XCTAssertEqual(
            AgentSnapshotPresenter.cliVersionLine(snapshot),
            "v1.8.39 · compatibility repair available"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.cliVersionMenuLine(snapshot),
            "CLI v1.8.39 · compatibility repair available"
        )
    }

    func testMissingCompatibilitySetDoesNotOfferRepairFromStaleObservation() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .reconnecting
        snapshot.cliVersion = "1.8.39"
        snapshot.latestReleaseVersion = "1.8.39"
        snapshot.statusObservationFresh = false
        snapshot.compatibilitySetID = nil

        XCTAssertFalse(AgentSnapshotPresenter.compatibilityRepairAvailable(snapshot))
        XCTAssertFalse(AgentSnapshotPresenter.updateAvailable(snapshot))
    }

    func testCurrentCompleteCompatibilitySetDoesNotOfferRepair() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.cliVersion = "1.8.39"
        snapshot.latestReleaseVersion = "1.8.39"
        snapshot.statusObservationFresh = true
        snapshot.compatibilitySetID = "Augustas11/macprovider:v1.8.39@abc123"

        XCTAssertFalse(AgentSnapshotPresenter.compatibilityRepairAvailable(snapshot))
        XCTAssertFalse(AgentSnapshotPresenter.updateAvailable(snapshot))
    }
}
