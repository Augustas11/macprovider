import XCTest
@testable import Malibu

final class DashboardViewTests: XCTestCase {
    func testOptionalDashboardFieldsRenderFriendlyZerosWhenServing() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"

        XCTAssertEqual(AgentSnapshotPresenter.modelLine(snapshot), "Connected")
        XCTAssertTrue(AgentSnapshotPresenter.requestsLine(snapshot).contains("0 today"))
        XCTAssertTrue(AgentSnapshotPresenter.tokenLine(snapshot).contains("0 in / 0 out today"))
        XCTAssertEqual(AgentSnapshotPresenter.usdcFullLine(snapshot), "n/a today · n/a wk · n/a accrued · n/a life")
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot), "n/a")
        XCTAssertEqual(AgentSnapshotPresenter.queueChip(snapshot), "0 queued")
        XCTAssertEqual(AgentSnapshotPresenter.thermalChip(snapshot), "Thermal OK")
        XCTAssertEqual(AgentSnapshotPresenter.dashboardHeadline(snapshot), "Provider is ready")
        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
            "Ready for customer work · earnings unavailable"
        )
    }

    func testFreshServingWithoutEarningsWaitsForFirstPaidJob() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.providerEarningsFresh = true

        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
            "Ready for customer work · waiting for the first paid job"
        )
    }

    func testLocalOnlyStateWhenCoordinatorDisconnected() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .reconnecting
        snapshot.coordinatorConnected = false
        snapshot.currentModelID = "qwen3-coder-30b-a3b-instruct"
        snapshot.lastError = "Model loaded locally · not connected to the network"

        XCTAssertEqual(AgentSnapshotPresenter.dashboardHeadline(snapshot), "Checking customer availability")
        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
            "Details are available in Advanced diagnostics."
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.stateLine(snapshot),
            "Checking customer availability · qwen3-coder-30b-a3b-instruct"
        )
        XCTAssertEqual(AgentSnapshotPresenter.short(snapshot), "Reconnect")
    }

    func testPopulatedDashboardFieldsRenderValues() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
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
        snapshot.providerEarningsFresh = true
        snapshot.malibuProjectionFresh = true
        snapshot.gpuUtilizationPct = 62
        snapshot.latencyP50Ms = 42
        snapshot.latencyP99Ms = 180
        snapshot.queueDepth = 3
        snapshot.thermalState = .serious

        XCTAssertEqual(AgentSnapshotPresenter.modelLine(snapshot), "Llama-3.1-8B · Q4_K_M · 4.2GB")
        XCTAssertEqual(AgentSnapshotPresenter.requestsLine(snapshot), "142 today · 8,204 all-time · 3.1 req/min")
        XCTAssertTrue(AgentSnapshotPresenter.tokenLine(snapshot).contains("1.2M in / 3.8M out today"))
        XCTAssertEqual(AgentSnapshotPresenter.usdcFullLine(snapshot), "$4.12 today · $18.40 wk · $6.90 accrued · $211.00 life")
        XCTAssertEqual(AgentSnapshotPresenter.usdcAccrualCaption(snapshot), "Accrued — payouts open in beta")
        XCTAssertTrue(AgentSnapshotPresenter.malibuFullLine(snapshot).contains("[locked] unlocks at Trusted"))
        XCTAssertEqual(AgentSnapshotPresenter.gpuChip(snapshot), "GPU 62%")
        XCTAssertEqual(AgentSnapshotPresenter.latencyChip(snapshot), "p50 42ms · p99 180ms")
        XCTAssertEqual(AgentSnapshotPresenter.queueChip(snapshot), "3 queued")
        XCTAssertEqual(AgentSnapshotPresenter.thermalChip(snapshot), "Serious")
    }

    func testUsdcAdaptivePrecisionShowsFourDecimalsUnderACentAndTwoOtherwise() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.providerEarningsFresh = true

        snapshot.earningsUsdcToday = 0.0047
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot), "$0.0047")

        snapshot.earningsUsdcToday = -0.0047
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot), "$-0.0047")

        snapshot.earningsUsdcToday = 0
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot), "$0.00")

        snapshot.earningsUsdcToday = 0.01
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot), "$0.01")

        snapshot.earningsUsdcToday = 4.5
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot), "$4.50")

        snapshot.earningsUsdcToday = 0.0047
        snapshot.earningsUsdcWeek = 0.02
        snapshot.earningsUsdcPending = 6.90
        snapshot.earningsUsdcLifetime = 211
        XCTAssertEqual(
            AgentSnapshotPresenter.usdcFullLine(snapshot),
            "$0.0047 today · $0.02 wk · $6.90 accrued · $211.00 life"
        )
    }

    func testEligibilityLinePrioritizesIdlePrewarmSkipReasons() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.providerEarningsFresh = true

        XCTAssertNil(AgentSnapshotPresenter.eligibilityLine(AgentSnapshot.empty))

        snapshot.idlePrewarmSummary = ProviderIdlePrewarmSummary(
            skipsByReasonLast1h: ["on_battery": 3, "thermal_pressure": 1]
        )
        XCTAssertEqual(AgentSnapshotPresenter.eligibilityLine(snapshot), "On battery — plug in to earn")

        snapshot.idlePrewarmSummary = ProviderIdlePrewarmSummary(
            skipsByReasonLast1h: ["thermal_pressure": 1, "model_not_loaded": 2]
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.eligibilityLine(snapshot),
            "Thermal throttle — waiting to cool before earning"
        )

        snapshot.idlePrewarmSummary = ProviderIdlePrewarmSummary(
            skipsByReasonLast1h: ["model_not_loaded": 2]
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.eligibilityLine(snapshot),
            "Model is preparing — earning starts when ready"
        )

        snapshot.idlePrewarmSummary = .empty
        XCTAssertEqual(AgentSnapshotPresenter.eligibilityLine(snapshot), "Eligible, waiting for work")

        snapshot.providerEarningsFresh = false
        XCTAssertNil(AgentSnapshotPresenter.eligibilityLine(snapshot))
    }
}
