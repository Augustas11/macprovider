import XCTest
@testable import Malibu

final class DashboardViewTests: XCTestCase {
    func testOptionalDashboardFieldsRenderDashWhenMissing() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving

        XCTAssertEqual(AgentSnapshotPresenter.modelLine(snapshot), "—")
        XCTAssertTrue(AgentSnapshotPresenter.requestsLine(snapshot).contains("— today"))
        XCTAssertTrue(AgentSnapshotPresenter.tokenLine(snapshot).contains("— in / — out today"))
        XCTAssertTrue(AgentSnapshotPresenter.usdcFullLine(snapshot).contains("$— today"))
        XCTAssertEqual(AgentSnapshotPresenter.queueChip(snapshot), "— queued")
        XCTAssertEqual(AgentSnapshotPresenter.thermalChip(snapshot), "Thermal —")
    }

    func testPopulatedDashboardFieldsRenderValues() {
        var snapshot = AgentSnapshot.empty
        snapshot.currentModelID = "Llama-3.1-8B · Q4_K_M · 4.2GB"
        snapshot.requestsServedToday = 142
        snapshot.requestsServedAllTime = 8_204
        snapshot.requestsPerMinute = 3.1
        snapshot.inputTokensToday = 1_200_000
        snapshot.outputTokensToday = 3_800_000
        snapshot.earningsUsdcToday = 4.12
        snapshot.earningsUsdcWeek = 18.40
        snapshot.earningsUsdcPending = 6.90
        snapshot.earningsUsdcLifetime = 211
        snapshot.malibuAccruedToday = 12
        snapshot.malibuAccruedAllTime = 50
        snapshot.trustTier = .provisional
        snapshot.gpuUtilizationPct = 62
        snapshot.latencyP50Ms = 42
        snapshot.latencyP99Ms = 180
        snapshot.queueDepth = 3
        snapshot.thermalState = .serious

        XCTAssertEqual(AgentSnapshotPresenter.modelLine(snapshot), "Llama-3.1-8B · Q4_K_M · 4.2GB")
        XCTAssertEqual(AgentSnapshotPresenter.requestsLine(snapshot), "142 today · 8,204 all-time · 3.1 req/min")
        XCTAssertTrue(AgentSnapshotPresenter.tokenLine(snapshot).contains("1.2M in / 3.8M out today"))
        XCTAssertEqual(AgentSnapshotPresenter.usdcFullLine(snapshot), "$4.12 today · $18.40 wk · $6.90 pending · $211.00 life")
        XCTAssertTrue(AgentSnapshotPresenter.malibuFullLine(snapshot).contains("[locked] unlocks at Trusted"))
        XCTAssertEqual(AgentSnapshotPresenter.gpuChip(snapshot), "GPU 62%")
        XCTAssertEqual(AgentSnapshotPresenter.latencyChip(snapshot), "p50 42ms · p99 180ms")
        XCTAssertEqual(AgentSnapshotPresenter.queueChip(snapshot), "3 queued")
        XCTAssertEqual(AgentSnapshotPresenter.thermalChip(snapshot), "Serious")
    }
}
