import AppKit
import XCTest
@testable import Malibu

@MainActor
final class DashboardWindowSmokeTests: XCTestCase {
    func testDashboardWindowIsResizableAndCanShrinkToMinSize() {
        let agent = MalibuAgent(initialSnapshot: Self.readyUSDCWithoutMALIBU())
        let window = DashboardWindow.make(
            agent: agent,
            onExportDiagnostics: {},
            onResetProvider: {}
        )
        defer { window.close() }

        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize.width, 640)
        XCTAssertEqual(window.contentMinSize.height, 520)
        XCTAssertEqual(window.title, "Malibu")

        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 660, height: 540))
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(window.frame.width, 640)
        XCTAssertGreaterThanOrEqual(window.frame.height, 520)
        XCTAssertLessThan(window.contentMinSize.width, 780)
        XCTAssertLessThan(window.contentMinSize.height, 740)
    }

    private static func readyUSDCWithoutMALIBU() -> AgentSnapshot {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.currentModelID = "qwen3-8b"
        snapshot.updateRewardInputs(providerEarningsFresh: true, malibuProjectionFresh: false)
        snapshot.walletBound = true
        snapshot.earningsUsdcToday = 0
        snapshot.earningsUsdcPending = 0.07
        snapshot.earningsUsdcLifetime = 0.07
        return snapshot
    }
}
