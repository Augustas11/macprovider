import XCTest
@testable import Malibu

final class MenuBarBadgeThresholdTests: XCTestCase {
    func testThresholdRatchetThroughAllConfiguredLevels() {
        XCTAssertEqual(UnclaimedBadgePolicy.visibleThreshold(totalBacklog: 1, dismissedThreshold: nil), 1)
        XCTAssertNil(UnclaimedBadgePolicy.visibleThreshold(totalBacklog: 9.99, dismissedThreshold: 1))
        XCTAssertEqual(UnclaimedBadgePolicy.visibleThreshold(totalBacklog: 10, dismissedThreshold: 1), 10)
        XCTAssertNil(UnclaimedBadgePolicy.visibleThreshold(totalBacklog: 99.99, dismissedThreshold: 10))
        XCTAssertEqual(UnclaimedBadgePolicy.visibleThreshold(totalBacklog: 100, dismissedThreshold: 10), 100)
        XCTAssertNil(UnclaimedBadgePolicy.visibleThreshold(totalBacklog: 1_000, dismissedThreshold: 100))
    }

    func testDismissedThresholdPersistsAcrossStoreInstances() {
        let suiteName = "malibu.badge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var first = UnclaimedBadgeDismissalStore(defaults: defaults)
        first.dismissedThreshold = 10

        let second = UnclaimedBadgeDismissalStore(defaults: defaults)
        XCTAssertEqual(second.dismissedThreshold, 10)
    }

    func testTotalIncludesUSDCAndMalibuEquivalent() {
        var snapshot = AgentSnapshot.empty
        snapshot.walletBound = false
        snapshot.unpaidLedgerBacklogUSDC = 0.50
        snapshot.unpaidLedgerBacklogMALIBU = 0.50

        XCTAssertEqual(AgentSnapshotPresenter.unclaimedBacklogTotal(snapshot), 1.0)
        XCTAssertEqual(AgentSnapshotPresenter.unclaimedBadge(snapshot, dismissedThreshold: nil), "$1+")
    }
}
