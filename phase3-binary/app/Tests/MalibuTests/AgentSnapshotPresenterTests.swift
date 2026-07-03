import XCTest
@testable import Malibu

// AUDIT R1 ARCHITECT A1: rendering "not reported yet" must be distinct from
// authoritative "$0.00" until the CLI moves past the stub metrics_response.

final class AgentSnapshotPresenterTests: XCTestCase {
    func testEarningsLineShowsDashWhenBothMetricsMissing() {
        var s = AgentSnapshot.empty
        s.state = .serving
        XCTAssertTrue(AgentSnapshotPresenter.earningsLine(s).contains("—"))
        XCTAssertTrue(AgentSnapshotPresenter.earningsLine(s).contains("not implemented"))
    }

    func testShortShowsDashWhenServingButNoEarningsYet() {
        var s = AgentSnapshot.empty
        s.state = .serving
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "—")
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
}
