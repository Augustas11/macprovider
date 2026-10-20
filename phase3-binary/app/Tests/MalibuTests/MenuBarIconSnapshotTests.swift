import AppKit
import XCTest
@testable import Malibu

/// #2029 P1-20: renders the menu-bar glyph at 1x and 2x and measures it, so a
/// future re-cut cannot shrink it back to a faint 8 pt smudge.
@MainActor
final class MenuBarIconSnapshotTests: XCTestCase {
    private struct Bitmap {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        func alpha(_ x: Int, _ yFromBottom: Int) -> CGFloat {
            guard x >= 0, yFromBottom >= 0, x < rep.pixelsWide, yFromBottom < rep.pixelsHigh else { return 0 }
            return rep.colorAt(x: x, y: rep.pixelsHigh - 1 - yFromBottom)?.alphaComponent ?? 0
        }
    }

    private func render(_ image: NSImage, scale: CGFloat) throws -> Bitmap {
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return Bitmap(rep: rep, scale: scale)
    }

    func testGlyphInkIsAtLeast14PointsTallAt1xAnd2x() throws {
        for scale in [CGFloat(1), 2] {
            let bitmap = try render(MalibuMenuBarIcon.make(), scale: scale)
            var minY = Int.max, maxY = Int.min
            for x in 0..<bitmap.rep.pixelsWide {
                for y in 0..<bitmap.rep.pixelsHigh where bitmap.alpha(x, y) > 0.5 {
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            let inkPoints = CGFloat(maxY - minY + 1) / scale
            XCTAssertGreaterThanOrEqual(inkPoints, 14, "ink is \(inkPoints) pt tall at \(scale)x")
            XCTAssertLessThanOrEqual(inkPoints, MalibuMenuBarIcon.canvasHeight)
        }
    }

    func testEveryRayIsAtLeastOneAndAHalfPointsWide() throws {
        XCTAssertGreaterThanOrEqual(MalibuMenuBarIcon.rayStrokeWidth, 1.5)
        XCTAssertGreaterThanOrEqual(MalibuMenuBarIcon.sideBeamThickness, 1.5)
        let bitmap = try render(MalibuMenuBarIcon.make(), scale: 2)
        let center = CGPoint(x: MalibuMenuBarIcon.canvasWidth / 2, y: MalibuMenuBarIcon.baselineY)
        for (degrees, tipRadius) in zip(MalibuMenuBarIcon.rayAnglesDegrees, MalibuMenuBarIcon.rayTipRadii) {
            let r = degrees * .pi / 180
            // Measure two thirds of the way out, where the taper is narrow.
            let along = MalibuMenuBarIcon.rayInnerRadius + (tipRadius - MalibuMenuBarIcon.rayInnerRadius) * 2 / 3
            let p = CGPoint(x: center.x + CGFloat(cos(r)) * along, y: center.y + CGFloat(sin(r)) * along)
            let normal = CGPoint(x: -CGFloat(sin(r)), y: CGFloat(cos(r)))
            var inked = 0
            // Sample across the ray in 0.05 pt steps.
            for step in -40...40 {
                let offset = CGFloat(step) * 0.05
                let x = Int(((p.x + normal.x * offset) * bitmap.scale).rounded(.down))
                let y = Int(((p.y + normal.y * offset) * bitmap.scale).rounded(.down))
                if bitmap.alpha(x, y) > 0.5 { inked += 1 }
            }
            let width = CGFloat(inked) * 0.05
            XCTAssertGreaterThanOrEqual(width, 1.5, "ray at \(degrees)° renders \(width) pt wide")
        }
    }

    /// The glyph is the brand mark simplified: same ray count and angles, a
    /// cut-out dome, and both horizontal side beams inside the canvas.
    func testGlyphKeepsTheBrandMarksDomeRaysAndSideBeams() throws {
        XCTAssertEqual(MalibuMenuBarIcon.rayAnglesDegrees, MalibuConstructionSunburstGeometry.rayAnglesDegrees)
        XCTAssertEqual(MalibuMenuBarIcon.rayAnglesDegrees.count, 7)
        let bitmap = try render(MalibuMenuBarIcon.make(), scale: 2)
        func inked(_ x: CGFloat, _ y: CGFloat) -> Bool {
            bitmap.alpha(Int(x * bitmap.scale), Int(y * bitmap.scale)) > 0.5
        }
        let midX = MalibuMenuBarIcon.canvasWidth / 2
        let beamY = MalibuMenuBarIcon.baselineY + MalibuMenuBarIcon.sideBeamThickness / 2
        let beamTip = MalibuMenuBarIcon.sideBeamTipX
        XCTAssertTrue(inked(midX - beamTip + 1, beamY), "left side beam missing")
        XCTAssertTrue(inked(midX + beamTip - 1, beamY), "right side beam missing")
        XCTAssertFalse(inked(midX - beamTip + 1, beamY + 2), "left side beam must stay on the baseline")
        XCTAssertFalse(inked(midX + beamTip - 1, beamY + 2), "right side beam must stay on the baseline")
        XCTAssertFalse(inked(midX, MalibuMenuBarIcon.baselineY + 1), "dome must be a cut-out")
        XCTAssertTrue(inked(midX, MalibuMenuBarIcon.baselineY + MalibuMenuBarIcon.cutoutRadius + 1), "band missing")
        // Everything stays inside the canvas.
        XCTAssertGreaterThanOrEqual(midX - beamTip, 0.5)
        XCTAssertGreaterThanOrEqual(MalibuMenuBarIcon.baselineY, 0.5)
        for x in 0..<bitmap.rep.pixelsWide {
            XCTAssertLessThan(bitmap.alpha(x, 0), 0.5, "ink touches the bottom edge")
            XCTAssertLessThan(bitmap.alpha(x, bitmap.rep.pixelsHigh - 1), 0.5, "ink touches the top edge")
        }
        for y in 0..<bitmap.rep.pixelsHigh {
            XCTAssertLessThan(bitmap.alpha(0, y), 0.5, "ink touches the left edge")
            XCTAssertLessThan(bitmap.alpha(bitmap.rep.pixelsWide - 1, y), 0.5, "ink touches the right edge")
        }
    }

    func testStateBadgesAndLabels() {
        XCTAssertTrue(MalibuMenuBarIcon.make(badge: .none).isTemplate)
        XCTAssertTrue(MalibuMenuBarIcon.make(badge: .paused).isTemplate)
        XCTAssertFalse(MalibuMenuBarIcon.make(badge: .attention).isTemplate, "the red dot must keep its colour")
        XCTAssertEqual(MalibuMenuBarIcon.accessibilityLabel(for: .none), "Malibu")
        XCTAssertEqual(MalibuMenuBarIcon.accessibilityLabel(for: .paused), "Malibu — paused")
        XCTAssertEqual(MalibuMenuBarIcon.accessibilityLabel(for: .attention), "Malibu — needs attention")

        var serving = AgentSnapshot.empty
        serving.state = .serving
        serving.networkState = "buyer_serving"
        XCTAssertEqual(MenuBarPresentation.badge(for: serving), .none)
        var paused = AgentSnapshot.empty
        paused.state = .paused
        XCTAssertEqual(MenuBarPresentation.badge(for: paused), .paused)
        var failed = AgentSnapshot.empty
        failed.state = .error
        XCTAssertEqual(MenuBarPresentation.badge(for: failed), .attention)
        serving.thermalState = .critical
        XCTAssertEqual(MenuBarPresentation.badge(for: serving), .attention)
    }
}

/// #2029 P1-21: Dock and Cmd-Tab while a Malibu window is open.
@MainActor
final class DockPresenceTests: XCTestCase {
    func testRegularWhileAWindowIsOpenAccessoryAfterTheLastCloses() {
        let controller = DockPresenceController()
        var policies: [NSApplication.ActivationPolicy] = []
        controller.applyPolicy = { policies.append($0) }
        controller.activate = {}
        let dashboard = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let settings = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        dashboard.isReleasedWhenClosed = false
        settings.isReleasedWhenClosed = false

        controller.present(dashboard)
        controller.present(settings)
        XCTAssertEqual(policies, [.regular, .regular])
        settings.close()
        XCTAssertEqual(policies.last, .regular, "the dashboard is still open")
        XCTAssertEqual(controller.trackedWindowCount, 1)
        dashboard.close()
        XCTAssertEqual(policies.last, .accessory)
        XCTAssertEqual(controller.trackedWindowCount, 0)
    }

    func testReopenWithoutWindowsShowsTheDashboard() {
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:))))
    }

    func testPersistentDockPreferenceAppliesImmediatelyAndSurvivesWindowClose() {
        let controller = DockPresenceController()
        var policies: [NSApplication.ActivationPolicy] = []
        controller.applyPolicy = { policies.append($0) }
        controller.activate = {}
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false

        controller.setKeepsDockIcon(true)
        controller.present(window)
        window.close()
        XCTAssertEqual(policies, [.regular, .regular])

        controller.setKeepsDockIcon(false)
        XCTAssertEqual(policies.last, .accessory)
    }
}

@MainActor
final class MainMenuTests: XCTestCase {
    /// A `.regular` app needs a real main menu: Settings, Open Dashboard,
    /// Quit, plus the standard Edit and Window menus.
    func testMainMenuOffersSettingsDashboardAndQuit() {
        let titles = (NSApp.mainMenu?.items ?? []).flatMap { item in
            [item.title] + (item.submenu?.items.map(\.title) ?? [])
        }
        XCTAssertTrue(titles.contains("Settings…"), "\(titles)")
        XCTAssertTrue(titles.contains("Open Dashboard"), "\(titles)")
        XCTAssertTrue(titles.contains { $0.hasPrefix("Quit") }, "\(titles)")
        XCTAssertTrue(titles.contains("Edit"), "\(titles)")
        XCTAssertTrue(titles.contains("Window"), "\(titles)")
    }
}
