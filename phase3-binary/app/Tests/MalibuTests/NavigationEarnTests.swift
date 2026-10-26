import AppKit
import SwiftUI
import XCTest
import Vision
@testable import Malibu

@MainActor
final class NavigationEarnTests: XCTestCase {
    func testPersistedSectionsMigrateWithoutLosingTheirDestination() {
        XCTAssertEqual(MalibuNavigation().selection, .chat)
        for value in ["dashboard", "provider"] {
            XCTAssertEqual(MalibuNavigation(persistedValue: value).selection, .earn)
        }
        XCTAssertEqual(MalibuNavigation(persistedValue: "connectedApps").selection, .terminal)
        let discover = MalibuNavigation(persistedValue: "discover")
        XCTAssertEqual(discover.selection, .models)
        XCTAssertEqual(discover.modelsTab, .browse)
        for section in MalibuSection.allCases {
            XCTAssertEqual(MalibuNavigation(persistedValue: section.rawValue).selection, section)
        }
        XCTAssertEqual(MalibuNavigation(persistedValue: "future-section").selection, .chat)
    }

    func testModelLinksSelectTheirExactTab() {
        let navigation = MalibuNavigation()
        navigation.showModels(.onThisMac)
        XCTAssertEqual(navigation.selection, .models)
        XCTAssertEqual(navigation.modelsTab, .onThisMac)
        navigation.showPersistedValue("discover")
        XCTAssertEqual(navigation.selection, .models)
        XCTAssertEqual(navigation.modelsTab, .browse)
    }

    func testEarnReusesDashboardWithCollapsedProviderDetailsAndVisiblePause() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        let earn = EarnScreen(
            agent: MalibuAgent(initialSnapshot: snapshot), navigate: { _ in },
            browseModels: {}, onThisMacModels: {},
            onExportDiagnostics: {}, onResetProvider: {}
        )
        let dashboard = earn.dashboard
        XCTAssertTrue(dashboard.includesProviderDetails)
        XCTAssertFalse(dashboard.providerDetailsExpanded)
        XCTAssertNotNil(dashboard.browseModels)
        XCTAssertNotNil(dashboard.onThisMacModels)
        XCTAssertEqual(ProviderScreenPresentation.pauseAction(dashboard.agent.snapshot), .pause)
        XCTAssertTrue(DashboardCopy.defaultPublicStrings(snapshot).contains("Earnings (USDC)"))
        XCTAssertTrue(DashboardCopy.defaultPublicStrings(snapshot).contains("Your model"))
        XCTAssertTrue(ProviderScreenPresentation.screenStrings(snapshot).contains { $0.hasPrefix("Customer slots:") })
    }

    func testEarnHeaderRendersPauseAndResumeAndDisclosureRevealsProviderContent() throws {
        for state in [AgentSnapshot.State.serving, .paused] {
            var snapshot = AgentSnapshot.empty
            snapshot.state = state
            let agent = MalibuAgent(initialSnapshot: snapshot)
            let screen = EarnScreen(agent: agent, navigate: { _ in }, browseModels: {},
                                    onThisMacModels: {}, onExportDiagnostics: {}, onResetProvider: {})
            let window = NSWindow(contentViewController: NSHostingController(rootView: screen.frame(width: 1000, height: 1600)))
            window.setContentSize(NSSize(width: 1000, height: 1600))
            window.orderFrontRegardless()
            defer { window.close() }
            settle(window)
            let rendered = try renderedText(window)
            let diagnostic = rendered.map(\.text).joined(separator: "\n")
            let title = try XCTUnwrap(rendered.first { $0.text == "Earn" }, diagnostic)
            let actionLabel = state == .serving ? "Pause customer work" : "Resume customer work"
            let action = try XCTUnwrap(rendered.first { $0.text.contains(actionLabel) }, diagnostic)
            XCTAssertLessThan(abs(action.bounds.midY - title.bounds.midY) * window.frame.height, 50,
                              "Pause/Resume must be rendered in the Earn header")
            XCTAssertFalse(diagnostic.contains("Customer slots"), "Provider details start collapsed")
            let disclosure = try XCTUnwrap(rendered.first { $0.text.contains("Provider details") }, diagnostic)
            // Vision includes the leading disclosure chevron in the text bounds.
            // Click inside that glyph, rather than left of the detected run.
            let point = NSPoint(x: disclosure.bounds.minX * window.frame.width + 4,
                                y: disclosure.bounds.midY * window.frame.height)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            settle(window)
            let expanded = try renderedText(window).map(\.text).joined(separator: "\n")
            for expected in ["Customer slots", "Requests", "Tokens", "Current run", "Endpoints (this Mac only)",
                             "/v1/chat/completions", "/v1/responses"] {
                XCTAssertTrue(expanded.contains(expected), "Expanded Earn details must render R007 content: \(expected)\n\(expanded)")
            }
        }
    }

    private func settle(_ window: NSWindow) {
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private struct RenderedText {
        let text: String
        let bounds: CGRect
    }

    /// The hosted test process exposes only an AXGroup on some macOS versions.
    /// Read the rendered pixels so deleting a view still fails this regression.
    private func renderedText(_ window: NSWindow) throws -> [RenderedText] {
        let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow,
            CGWindowID(window.windowNumber), [.bestResolution, .boundsIgnoreFraming]))
        let attachment = XCTAttachment(image: NSImage(cgImage: image, size: window.frame.size))
        attachment.name = "Earn rendered controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { RenderedText(text: $0.string, bounds: observation.boundingBox) }
        }
    }
}
