import XCTest
@testable import Malibu

final class DashboardViewTests: XCTestCase {
    func testDashboardModelSubtitleIsStableAndActionable() {
        XCTAssertEqual(
            DashboardCopy.modelRowStatusLine(currentModelID: "meta-llama/llama-3.2-3b-instruct", listState: .ready),
            "Serving this model. Switching is available."
        )
        XCTAssertEqual(
            DashboardCopy.modelRowStatusLine(currentModelID: "meta-llama/llama-3.2-3b-instruct", listState: .viewOnly),
            "Serving this model. Switching is off until warm swap is running."
        )
        XCTAssertEqual(
            DashboardCopy.modelRowStatusLine(currentModelID: "meta-llama/llama-3.2-3b-instruct", listState: .unavailable),
            "Serving this model. Switching is unavailable right now; open Change Model to retry."
        )
        XCTAssertEqual(
            DashboardCopy.modelRowStatusLine(currentModelID: "meta-llama/llama-3.2-3b-instruct", listState: .checking),
            "Serving this model. Checking whether switching is available…"
        )
    }

    func testUnreportedMetricsAreAbsentNotInventedZeros() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"

        XCTAssertEqual(AgentSnapshotPresenter.modelLine(snapshot), "Connected")
        XCTAssertEqual(AgentSnapshotPresenter.requestsLine(snapshot), "— today (UTC) · — all-time")
        XCTAssertEqual(AgentSnapshotPresenter.tokenLine(snapshot), "— today (UTC)\n— all-time")
        XCTAssertEqual(AgentSnapshotPresenter.runLine(snapshot), "—")
        XCTAssertEqual(AgentSnapshotPresenter.diagnosticChips(snapshot), [], "no 0 queued / Thermal OK / GPU n/a")
        XCTAssertEqual(AgentSnapshotPresenter.dashboardHeadline(snapshot), "Provider is ready")
        let card = AgentSnapshotPresenter.earningsCard(snapshot)
        XCTAssertEqual(card.usdcSummary, "USDC earnings are unavailable right now.")
        XCTAssertNil(card.unpaidLine)
    }

    func testPopulatedMetricsAreLabelledHonestly() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "Llama-3.1-8B"
        snapshot.requestsServedToday = 142
        snapshot.requestsServedAllTime = 8_204
        snapshot.requestsPerMinute = 3.1
        snapshot.inputTokensToday = 1_200_000
        snapshot.outputTokensToday = 3_800_000
        snapshot.gpuUtilizationPct = 62
        snapshot.latencyP50Ms = 42
        snapshot.queueDepth = 3
        snapshot.thermalState = .serious
        snapshot.uptimeSec = 35_880
        snapshot.restartCount = 2286
        snapshot.restartCount7d = 1

        XCTAssertEqual(AgentSnapshotPresenter.requestsLine(snapshot), "142 today (UTC) · 8,204 all-time · 3.1 req/min")
        XCTAssertTrue(AgentSnapshotPresenter.tokenLine(snapshot).hasPrefix("1.2M in / 3.8M out today (UTC)"))
        XCTAssertEqual(AgentSnapshotPresenter.runLine(snapshot), "9h 58m current run · 1 restart in 7 days · 2,286 restarts lifetime")
        XCTAssertEqual(
            AgentSnapshotPresenter.diagnosticChips(snapshot),
            ["3 queued", "Thermal serious", "GPU 62%", "avg latency 42 ms"]
        )
        XCTAssertFalse(AgentSnapshotPresenter.diagnosticChips(snapshot).joined().contains("p50"))
        XCTAssertFalse(AgentSnapshotPresenter.runLine(snapshot).contains("7d uptime"))
        XCTAssertFalse(AgentSnapshotPresenter.runLine(snapshot).contains("declined"))
    }

    func testMacHealthUsesReportedValuesOnly() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.thermalState = .nominal
        snapshot.uptimeSec = 35_880
        snapshot.restartCount7d = 1
        snapshot.advertisedMaxConcurrency = 1
        XCTAssertEqual(
            AgentSnapshotPresenter.macHealthLine(snapshot),
            "Cool · up 9h 58m · 1 restart in 7 days · 1 customer slot"
        )
        snapshot.restartCount7d = nil
        snapshot.thermalState = nil
        XCTAssertEqual(AgentSnapshotPresenter.macHealthLine(snapshot), "up 9h 58m · 1 customer slot")
        XCTAssertNil(AgentSnapshotPresenter.macHealthLine(.empty))
    }

    func testUsdcAdaptivePrecisionShowsFourDecimalsUnderACentAndTwoOtherwise() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.updateRewardInputs(providerEarningsFresh: true)
        snapshot.earningsUsdcToday = 0
        snapshot.earningsUsdcWeek = 0.0001
        snapshot.earningsUsdcLifetime = 0.154264
        XCTAssertEqual(
            AgentSnapshotPresenter.earningsCard(snapshot).usdcSummary,
            "$0.15 lifetime · $0.0001 this week · $0.00 today (UTC)"
        )
        snapshot.earningsUsdcToday = -0.0047
        XCTAssertTrue(AgentSnapshotPresenter.earningsCard(snapshot).usdcSummary.hasSuffix("$-0.0047 today (UTC)"))
    }

    func testLastKnownUsdcIsLabelled() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.hasObservedProviderEarnings = true
        snapshot.earningsUsdcToday = 0.04
        snapshot.earningsUsdcLifetime = 1
        XCTAssertEqual(
            AgentSnapshotPresenter.earningsCard(snapshot).usdcSummary,
            "Last known: $1.00 lifetime · $0.04 today (UTC)"
        )
    }

    func testRecoveryCopyIsOnTheDashboardSurface() {
        XCTAssertEqual(DashboardCopy.resetProviderTitle, "Reset provider service")
        XCTAssertEqual(DashboardCopy.exportDiagnosticsTitle, "Export diagnostics…")
        XCTAssertEqual(DashboardCopy.recoveryHelpTitle, "If something is stuck")
        XCTAssertFalse(DashboardCopy.resetProviderConfirmDetail.contains("launchd"))
        XCTAssertFalse(DashboardCopy.resetProviderConfirmDetail.lowercased().contains("cli"))
    }

    func testRecoveryActionsLeaveTheMainSurfaceWhileHealthy() {
        var healthy = AgentSnapshot.empty
        healthy.state = .serving
        healthy.coordinatorConnected = true
        healthy.networkState = "buyer_serving"
        XCTAssertFalse(DashboardCopy.showsStatusNotice(healthy))
        XCTAssertFalse(DashboardCopy.showsRecoveryOnMainSurface(healthy))

        var failed = AgentSnapshot.empty
        failed.state = .error
        failed.lastError = "Provider setup failed"
        XCTAssertTrue(DashboardCopy.showsStatusNotice(failed))
        XCTAssertTrue(DashboardCopy.showsRecoveryOnMainSurface(failed))
    }
}
