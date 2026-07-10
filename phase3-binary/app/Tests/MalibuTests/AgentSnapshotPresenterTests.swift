import XCTest
@testable import Malibu

// AUDIT R1 ARCHITECT A1: rendering "not reported yet" must be distinct from
// authoritative "$0.00" until the CLI moves past the stub metrics_response.

final class AgentSnapshotPresenterTests: XCTestCase {
    func testEarningsLineShowsZeroWhenBothMetricsMissingWhileServing() {
        var s = AgentSnapshot.empty
        s.state = .serving
        XCTAssertTrue(AgentSnapshotPresenter.earningsLine(s).contains("$0.00"))
        XCTAssertTrue(AgentSnapshotPresenter.earningsLine(s).contains("no jobs yet"))
    }

    func testShortShowsServingWhenNoEarningsYet() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.coordinatorConnected = true
        s.networkState = "buyer_serving"
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "Serving")
    }

    func testShortShowsSyncWhenLocalOnly() {
        var s = AgentSnapshot.empty
        s.state = .reconnecting
        s.coordinatorConnected = false
        s.currentModelID = "model-a"
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "Sync")
    }

    func testShortShowsSyncWhenReconnecting() {
        var s = AgentSnapshot.empty
        s.state = .reconnecting
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "Sync")
    }

    func testShortShowsFormattedDollarsWhenPopulated() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.earningsUsdcToday = 12.34
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "$12.34")
    }

    func testStateLineIncludesLastErrorOnError() {
        var s = AgentSnapshot.empty
        s.state = .error
        s.lastError = "boom"
        XCTAssertEqual(AgentSnapshotPresenter.stateLine(s), "boom")
    }

    func testProvisionalMalibuIsRenderedLocked() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.earningsUsdcToday = 1
        s.malibuAccruedToday = 2
        s.trustTier = .provisional
        XCTAssertTrue(AgentSnapshotPresenter.earningsLine(s).contains("[locked] 2.00 MALIBU"))
        XCTAssertTrue(AgentSnapshotPresenter.earningsLine(s).contains("unlocks at Trusted"))
    }

    func testBacklogLineOnlyWhenWalletUnbound() {
        var s = AgentSnapshot.empty
        s.unpaidLedgerBacklogUSDC = 10
        s.unpaidLedgerBacklogMALIBU = 5
        s.walletBound = false
        XCTAssertNotNil(AgentSnapshotPresenter.backlogLine(s))
        s.walletBound = true
        XCTAssertNil(AgentSnapshotPresenter.backlogLine(s))
    }

    func testUnclaimedBadgeThresholdsResurfaceAfterDismissal() {
        var s = AgentSnapshot.empty
        s.walletBound = false
        s.unpaidLedgerBacklogUSDC = 9
        s.unpaidLedgerBacklogMALIBU = 0
        XCTAssertEqual(AgentSnapshotPresenter.unclaimedBadge(s, dismissedThreshold: nil), "$1+")
        XCTAssertNil(AgentSnapshotPresenter.unclaimedBadge(s, dismissedThreshold: 10))

        s.unpaidLedgerBacklogUSDC = 10
        XCTAssertEqual(AgentSnapshotPresenter.unclaimedBadge(s, dismissedThreshold: 1), "$10+")
        XCTAssertNil(AgentSnapshotPresenter.unclaimedBadge(s, dismissedThreshold: 10))

        s.unpaidLedgerBacklogUSDC = 100
        XCTAssertEqual(AgentSnapshotPresenter.unclaimedBadge(s, dismissedThreshold: 10), "$100+")
    }

    func testProviderEarningsDecodesSpec026ExtendedFields() throws {
        let data = Data("""
        {
          "wallet_bound": false,
          "trust_tier": "Trusted",
          "unpaid_ledger_backlog_usdc": 12.5,
          "unpaid_ledger_backlog_malibu": 7.25
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(ProviderEarnings.self, from: data)
        XCTAssertFalse(decoded.walletBound)
        XCTAssertEqual(decoded.trustTier, .trusted)
        XCTAssertEqual(decoded.unpaidLedgerBacklogUSDC, 12.5)
        XCTAssertEqual(decoded.unpaidLedgerBacklogMALIBU, 7.25)
    }
}
