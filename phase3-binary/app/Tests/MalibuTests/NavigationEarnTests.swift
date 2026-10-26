import AppKit
import SwiftUI
import XCTest
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
            let content = try XCTUnwrap(window.contentView)
            let rendered = elements(content)
            let diagnostic = rendered.prefix(100).map {
                "role=\($0.accessibilityRole()?.rawValue ?? "nil") label=\($0.accessibilityLabel() ?? "nil") value=\(String(describing: $0.accessibilityValue()).prefix(180))"
            }.joined(separator: "\n")
            let title = try XCTUnwrap(rendered.first { text($0).contains("Earn") }, diagnostic)
            let actionLabel = state == .serving ? "Pause customer work…" : "Resume customer work"
            let action = try XCTUnwrap(rendered.first { text($0).contains(actionLabel) }, diagnostic)
            XCTAssertGreaterThan(action.accessibilityFrame().width, 0)
            XCTAssertLessThan(abs(action.accessibilityFrame().midY - title.accessibilityFrame().midY), 50,
                              "Pause/Resume must be rendered in the Earn header")
            XCTAssertFalse(strings(content).contains("Customer slots"), "Provider details start collapsed")
            let disclosure = try XCTUnwrap(elements(content).first {
                $0.accessibilityRole() == .disclosureTriangle
            })
            XCTAssertTrue(disclosure.accessibilityPerformPress())
            settle(window)
            let expanded = strings(content)
            for expected in ["Customer slots", "Requests", "Tokens", "Current run", "Endpoints (this Mac only)",
                             "POST /v1/chat/completions", "POST /v1/responses", ProviderScreenPresentation.endpointsNote] {
                XCTAssertTrue(expanded.contains(expected), "Expanded Earn details must render R007 content: \(expected)")
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

    private func elements(_ root: Any) -> [any NSAccessibilityProtocol] {
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: Any) -> [any NSAccessibilityProtocol] {
            guard let object = object as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = object as? any NSAccessibilityProtocol
            let children = element?.accessibilityChildren() ?? []
            // NSHostingView can be an ignored wrapper. Inspect its native
            // descendants as well as the exposed virtual accessibility tree.
            let nativeChildren = (object as? NSView)?.subviews ?? []
            return (element.map { [$0] } ?? []) + (children + nativeChildren).flatMap(visit)
        }
        return visit(root)
    }

    private func text(_ element: any NSAccessibilityProtocol) -> [String] {
        [element.accessibilityLabel(), element.accessibilityValue() as? String,
         element.accessibilityTitle()].compactMap { $0 }
    }

    private func strings(_ root: Any) -> Set<String> {
        Set(elements(root).flatMap(text))
    }
}
