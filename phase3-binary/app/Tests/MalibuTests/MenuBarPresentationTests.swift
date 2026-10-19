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
        XCTAssertEqual(MenuBarPresentation.statusItemLength, NSStatusItem.variableLength)
        XCTAssertEqual(
            MenuBarPresentation.brandIdentity,
            MalibuBrand.constructionMarkIdentity
        )
        XCTAssertEqual(MalibuBrand.constructionMarkIdentity, "malibu.construction-sunburst.v2")
    }

    func testConstructionMenuBarIconIsTemplateSizedForMenuBar() {
        let icon = MalibuMenuBarIcon.makeTemplate()
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size.width, MalibuMenuBarIcon.canvasWidth)
        XCTAssertEqual(icon.size.height, MalibuMenuBarIcon.canvasHeight)
        XCTAssertEqual(MalibuConstructionSunburstGeometry.rayCount, 7)
        XCTAssertEqual(MalibuConstructionSunburstGeometry.rayTipRadii.count, 7)
        XCTAssertEqual(MalibuConstructionSunburstGeometry.sideBeamAnglesDegrees, [0, 180])
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

    /// The brand-kit mark: an open dome ringed by a band, seven rays, and
    /// two side beams on the baseline (mark points, origin at the baseline centre).
    func testConstructionMarkHasCutOutDomeRaysAndSideBeams() {
        let mark = MalibuConstructionSunburstGeometry.unitMark
        let box = mark.boundingBoxOfPath
        XCTAssertEqual(box.minX, -145.39, accuracy: 0.1)
        XCTAssertEqual(box.maxX, 145.39, accuracy: 0.1)
        XCTAssertEqual(box.minY, 0, accuracy: 0.01)
        XCTAssertEqual(box.maxY, 133.03, accuracy: 0.1)
        XCTAssertFalse(mark.contains(CGPoint(x: 0, y: 20)), "dome must be a cut-out")
        XCTAssertTrue(mark.contains(CGPoint(x: 0, y: 55)), "band rings the cut-out")
        XCTAssertTrue(mark.contains(CGPoint(x: -135, y: 4)), "left side beam")
        XCTAssertTrue(mark.contains(CGPoint(x: 135, y: 4)), "right side beam")
        XCTAssertFalse(mark.contains(CGPoint(x: 135, y: 20)), "side beams stay on the baseline")
        let geometry = MalibuConstructionSunburstGeometry.self
        for (degrees, radius) in zip(geometry.rayAnglesDegrees, geometry.rayTipRadii) {
            let r = degrees * .pi / 180
            let nearTip = radius - 6
            XCTAssertTrue(mark.contains(CGPoint(x: CGFloat(cos(r)) * nearTip, y: CGFloat(sin(r)) * nearTip)),
                          "ray at \(degrees)°")
        }
        for degrees in [35.0, 57.0, 79.0, 101.0, 123.0, 145.0] {
            let r = degrees * .pi / 180
            XCTAssertFalse(mark.contains(CGPoint(x: CGFloat(cos(r)) * 110, y: CGFloat(sin(r)) * 110)),
                           "gap between rays at \(degrees)°")
        }
    }

    /// The checked-in SVG is an export of the geometry; regenerate it with
    /// scripts/generate-app-icon.sh when the geometry changes.
    func testCheckedInBrandSVGMatchesGeometry() throws {
        let svg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Malibu/Resources/Brand/malibu-icon.svg")
        XCTAssertEqual(try String(contentsOf: svg, encoding: .utf8), MalibuConstructionSunburstGeometry.appIconSVG())
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
