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
}
