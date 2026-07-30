import AppKit
import XCTest
@testable import Malibu

final class MenuBarPresentationTests: XCTestCase {
    func testMenuBarIsIconOnlyEvenWhenServingWithBadges() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.earningsUsdcToday = 12.34
        snapshot.walletBound = false
        snapshot.unpaidLedgerBacklogUSDC = 25
        snapshot.unpaidLedgerBacklogMALIBU = 0
        snapshot.cliVersion = "1.8.56"
        snapshot.latestReleaseVersion = "1.8.57"
        snapshot.queueDepth = 3

        XCTAssertEqual(
            MenuBarPresentation.buttonTitle(for: snapshot, dismissedThreshold: nil),
            ""
        )
        XCTAssertEqual(MenuBarPresentation.statusItemLength, NSStatusItem.squareLength)
        XCTAssertEqual(
            MenuBarPresentation.brandIdentity,
            MalibuBrand.constructionMarkIdentity
        )
        XCTAssertEqual(MalibuBrand.constructionMarkIdentity, "malibu.construction-sunburst.v1")
    }

    func testConstructionMenuBarIconIsTemplateSizedForMenuBar() {
        let icon = MalibuMenuBarIcon.makeTemplate(pointSize: MalibuMenuBarIcon.defaultPointSize)
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size.width, MalibuMenuBarIcon.defaultPointSize)
        XCTAssertEqual(icon.size.height, MalibuMenuBarIcon.defaultPointSize)
        XCTAssertEqual(MalibuConstructionSunburstGeometry.rayCount, 9)
        XCTAssertEqual(MalibuConstructionSunburstGeometry.rayAnglesDegrees.count, 9)
        XCTAssertEqual(MalibuConstructionSunburstGeometry.firstRayDegrees, 12)
        XCTAssertEqual(MalibuConstructionSunburstGeometry.lastRayDegrees, 168)
        let appKit = MalibuConstructionSunburstGeometry.path(
            in: CGRect(x: 0, y: 0, width: 64, height: 64),
            yUp: true
        )
        let swiftUI = MalibuConstructionSunburstGeometry.swiftUIPath(
            in: CGRect(x: 0, y: 0, width: 64, height: 64)
        )
        XCTAssertFalse(appKit.isEmpty)
        XCTAssertFalse(swiftUI.isEmpty)
    }

    func testTooltipStillSurfacesPublicStatusWithoutMenuBarTitle() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "obs"
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true

        XCTAssertEqual(MenuBarPresentation.buttonTitle(for: snapshot, dismissedThreshold: nil), "")
        XCTAssertEqual(AgentSnapshotPresenter.short(snapshot), "Serving")
        XCTAssertTrue(AgentSnapshotPresenter.stateLine(snapshot).contains("Provider is ready"))
    }
}
