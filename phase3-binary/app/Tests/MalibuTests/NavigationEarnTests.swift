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
            let window = NSWindow(contentViewController: NSHostingController(rootView: screen.frame(width: 1000, height: 800)))
            window.setContentSize(NSSize(width: 1000, height: 800))
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            settle(window)
            let rendered = try renderedText(window)
            let diagnostic = rendered.map(\.text).joined(separator: "\n")
            let title = try XCTUnwrap(rendered.first { $0.text == "Earn" }, diagnostic)
            let actionLabel = state == .serving ? "Pause customer work" : "Resume customer work"
            let action = try XCTUnwrap(rendered.first { $0.text.contains(actionLabel) }, diagnostic)
            XCTAssertLessThan(abs(action.bounds.midY - title.bounds.midY) * window.frame.height, 50,
                              "Pause/Resume must be rendered in the Earn header")
            let detailLandmarks = ["Requests", "Endpoints (this Mac only)", "/v1/chat/completions",
                                   "/v1/responses", "Logs and events are in Diagnostics"]
            for landmark in detailLandmarks {
                XCTAssertFalse(normalized(diagnostic).contains(normalized(landmark)),
                               "Provider details start collapsed: \(landmark)")
            }
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
            let expanded = try renderedTextAcrossScroll(window)
            for expected in detailLandmarks {
                XCTAssertTrue(normalized(expanded).contains(normalized(expected)),
                              "Expanded Earn details must render R007 content: \(expected)\n\(expanded)")
            }
        }
    }

    private func settle(_ window: NSWindow) {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Use a screen-sized viewport and overlapping scroll positions so no R007
    /// landmark is clipped or compressed into an oversized window capture.
    private func renderedTextAcrossScroll(_ window: NSWindow) throws -> String {
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScrollView).first
        }
        let content = try XCTUnwrap(window.contentView)
        let scroll = try XCTUnwrap(findScrollView(content))
        let document = try XCTUnwrap(scroll.documentView)
        let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let step = max(1, scroll.contentView.bounds.height / 2)
        var texts: [String] = []
        var offset: CGFloat = 0
        while true {
            let y = document.isFlipped ? offset : maxY - offset
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(window)
            texts.append(contentsOf: try renderedText(window).map(\.text))
            if offset == maxY { break }
            offset = min(maxY, offset + step)
        }
        return texts.joined(separator: "\n")
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
