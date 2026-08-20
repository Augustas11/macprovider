import XCTest
@testable import Malibu

final class DashboardViewTests: XCTestCase {
    func testDashboardModelSubtitleIsStableAndActionable() {
        XCTAssertEqual(
            DashboardCopy.modelRowStatusLine(
                currentModelID: "meta-llama/llama-3.2-3b-instruct",
                listState: .ready
            ),
            "Serving this model. Change Model lists other options."
        )
        XCTAssertEqual(
            DashboardCopy.modelRowStatusLine(
                currentModelID: "meta-llama/llama-3.2-3b-instruct",
                listState: .viewOnly
            ),
            "Serving this model. Live switching is off until warm swap is running."
        )
        XCTAssertEqual(
            DashboardCopy.modelRowStatusLine(
                currentModelID: "meta-llama/llama-3.2-3b-instruct",
                listState: .unavailable
            ),
            "Serving this model. Open Change Model to see why switching is unavailable."
        )
        XCTAssertEqual(
            DashboardCopy.modelRowStatusLine(
                currentModelID: "meta-llama/llama-3.2-3b-instruct",
                listState: .checking
            ),
            "Serving this model. Checking whether switching is available."
        )
    }

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

    func testFreshServingWithoutEarningsShowsQuietNetwork() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.providerEarningsFresh = true

        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
            "Ready for customer work · network is quiet"
        )
    }

    func testFreshServingWithZeroEarningsIsNetworkQuietNotBroken() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.providerEarningsFresh = true
        snapshot.earningsUsdcToday = 0
        snapshot.currentModelID = "Qwen3-8B"

        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
            "Ready for customer work · network is quiet"
        )
    }

    func testQueuedWorkBeatsQuietNetworkCopy() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.providerEarningsFresh = true
        snapshot.earningsUsdcToday = 0
        snapshot.queueDepth = 2

        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
            "Ready · work is queued on this Mac"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.eligibilityLine(snapshot),
            "Work is queued on this Mac"
        )
    }

    func testUnsettledWorkCopyWhenRequestsExistWithoutPaidCredits() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.providerEarningsFresh = true
        snapshot.earningsUsdcToday = 0
        snapshot.requestsServedToday = 4

        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
            "Ready · work ran; paid credits appear when a job settles"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.eligibilityLine(snapshot),
            "Work ran today · paid credits show when a job settles"
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
        snapshot.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )
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
        XCTAssertTrue(AgentSnapshotPresenter.malibuFullLine(snapshot).contains("locked until eligible"))
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
        XCTAssertEqual(AgentSnapshotPresenter.eligibilityLine(snapshot), "Eligible · network is quiet")

        snapshot.providerEarningsFresh = false
        XCTAssertNil(AgentSnapshotPresenter.eligibilityLine(snapshot))
    }

    func testMiningHealthCoversIssue1017OperationalStates() {
        var earning = miningBase()
        earning.earningsUsdcToday = 0.04
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(earning).reasonCode, "earning")

        var idle = miningBase()
        idle.earningsUsdcToday = 0
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(idle).reasonCode, "idle_no_work")

        var pendingAvailability = miningBase()
        pendingAvailability.earningsUsdcToday = 0
        pendingAvailability.networkState = "buyer_serving_unknown"
        XCTAssertEqual(
            AgentSnapshotPresenter.miningHealth(pendingAvailability).reasonCode,
            "customer_availability_pending"
        )

        var notRunning = AgentSnapshot.empty
        notRunning.state = .idle
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(notRunning).reasonCode, "not_running")

        var battery = miningBase()
        battery.idlePrewarmSummary = ProviderIdlePrewarmSummary(skipsByReasonLast1h: ["on_battery": 1])
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(battery).reasonCode, "local_on_battery")

        var thermal = miningBase()
        thermal.idlePrewarmSummary = ProviderIdlePrewarmSummary(skipsByReasonLast1h: ["thermal_pressure": 1])
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(thermal).reasonCode, "local_thermal_pressure")

        var preparing = AgentSnapshot.empty
        preparing.state = .starting
        preparing.lifecycleState = "loading_model"
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(preparing).reasonCode, "local_model_preparing")

        var unavailable = AgentSnapshot.empty
        unavailable.state = .serving
        unavailable.networkState = "buyer_serving"
        unavailable.earningsUsdcToday = 0
        unavailable.malibuWithdrawable = 0
        let unavailableHealth = AgentSnapshotPresenter.miningHealth(unavailable)
        XCTAssertEqual(unavailableHealth.reasonCode, "reward_projection_unavailable")
        XCTAssertEqual(unavailableHealth.rewardSummary, "USDC unavailable · MALIBU unavailable")

        var missingWallet = miningBase()
        missingWallet.walletBound = false
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(missingWallet).reasonCode, "wallet_missing")

        var provisional = miningBase()
        provisional.trustTier = .provisional
        provisional.malibuHoldReasons = ["trust_tier_provisional"]
        provisional.trustCriteriaMet = 1
        provisional.trustCriteriaRequired = 3
        let provisionalHealth = AgentSnapshotPresenter.miningHealth(provisional)
        XCTAssertEqual(provisionalHealth.reasonCode, "trust_tier_provisional")
        XCTAssertEqual(provisionalHealth.nextAction, "Complete 2 more trust criteria to unlock withdrawals.")

        provisional.malibuHoldReasons = []
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(provisional).reasonCode, "trust_tier_provisional")
        XCTAssertEqual(
            AgentSnapshotPresenter.miningHealth(provisional).nextAction,
            "Complete 2 more trust criteria to unlock withdrawals."
        )

        provisional.malibuHoldReasons = ["demotion_cooldown"]
        provisional.trustCriteriaMet = 2
        provisional.trustCriteriaRequired = 2
        let cooldownHealth = AgentSnapshotPresenter.miningHealth(provisional)
        XCTAssertEqual(cooldownHealth.trustSummary, "Trust: Provisional · requalification cooldown active")
        XCTAssertEqual(cooldownHealth.nextAction, "Re-qualify for Trusted to clear the cooldown.")
        XCTAssertEqual(AgentSnapshotPresenter.trustLine(provisional), "Provisional — requalification cooldown active")

        var trustedWithHistoricalHold = provisional
        trustedWithHistoricalHold.trustTier = .trusted
        XCTAssertEqual(AgentSnapshotPresenter.trustLine(trustedWithHistoricalHold), "Trusted")
        XCTAssertNotEqual(
            AgentSnapshotPresenter.miningHealth(trustedWithHistoricalHold).reasonCode,
            "trust_tier_provisional"
        )
        XCTAssertNotEqual(
            AgentSnapshotPresenter.miningHealth(trustedWithHistoricalHold).reasonCode,
            "rewards_held"
        )
        XCTAssertFalse(
            AgentSnapshotPresenter.miningHealth(trustedWithHistoricalHold).status.contains("Locked")
        )
        XCTAssertNotEqual(
            AgentSnapshotPresenter.eligibilityLine(trustedWithHistoricalHold),
            "MALIBU is locked until Trusted"
        )

        var unlockTrusted = miningBase()
        unlockTrusted.trustTier = .provisional
        unlockTrusted.trustCriteriaMet = 1
        unlockTrusted.trustCriteriaRequired = 3
        XCTAssertEqual(
            AgentSnapshotPresenter.trustLine(unlockTrusted),
            "Provisional — 1 of 3 criteria met · Unlock Trusted →"
        )

        var walletCap = miningBase()
        walletCap.malibuHeld = 2
        walletCap.malibuHoldReasons = ["per_wallet_daily_cap"]
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(walletCap).reasonCode, "wallet_daily_cap_held")

        var providerCap = miningBase()
        providerCap.malibuHeld = 2
        providerCap.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "capped",
            withdrawalState: "capped",
            primaryReason: "held_provider_daily_cap",
            reasons: ["held_provider_daily_cap"]
        )
        let providerCapHealth = AgentSnapshotPresenter.miningHealth(providerCap)
        XCTAssertEqual(providerCapHealth.reasonCode, "provider_daily_cap_held")
        XCTAssertEqual(providerCapHealth.nextAction, "Wait for the next UTC day.")

        var genericHold = miningBase()
        genericHold.malibuHeld = 2
        genericHold.malibuHoldReasons = ["manual_review"]
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(genericHold).reasonCode, "rewards_held")

        var withdrawable = miningBase()
        withdrawable.malibuWithdrawable = 2
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(withdrawable).reasonCode, "trusted_withdrawable")
    }

    func testMiningHealthDistinguishesFreshPartialAndUnavailableRewards() {
        var fresh = miningBase()
        fresh.earningsUsdcToday = nil
        fresh.malibuWithdrawable = 0
        fresh.malibuHeld = 0
        let freshHealth = AgentSnapshotPresenter.miningHealth(fresh)
        XCTAssertEqual(freshHealth.reasonCode, "idle_no_work")
        XCTAssertEqual(freshHealth.rewardSummary, "n/a USDC today · MALIBU 0.00 withdrawable / 0.00 held")

        var partial = miningBase()
        partial.malibuProjectionFresh = false
        partial.earningsUsdcToday = 0.04
        let partialHealth = AgentSnapshotPresenter.miningHealth(partial)
        XCTAssertEqual(partialHealth.reasonCode, "earning")
        XCTAssertEqual(partialHealth.rewardSummary, "$0.04 USDC today · MALIBU unavailable")
        XCTAssertEqual(partialHealth.trustSummary, "MALIBU trust telemetry not published yet")

        var partialIdle = miningBase()
        partialIdle.malibuProjectionFresh = false
        partialIdle.earningsUsdcToday = 0
        let partialIdleHealth = AgentSnapshotPresenter.miningHealth(partialIdle)
        XCTAssertEqual(partialIdleHealth.reasonCode, "idle_no_work")
        XCTAssertEqual(partialIdleHealth.status, "Eligible, idle")
        XCTAssertEqual(partialIdleHealth.trustSummary, "MALIBU trust telemetry not published yet")

        var stale = miningBase()
        stale.providerEarningsFresh = false
        stale.malibuProjectionFresh = false
        stale.earningsUsdcToday = 0
        stale.malibuWithdrawable = 0
        let staleHealth = AgentSnapshotPresenter.miningHealth(stale)
        XCTAssertEqual(staleHealth.reasonCode, "reward_projection_unavailable")
        XCTAssertFalse(staleHealth.rewardSummary.contains("$0.00"))
        XCTAssertFalse(staleHealth.rewardSummary.contains("0.00 MALIBU"))

        var lastKnown = miningBase()
        lastKnown.providerEarningsFresh = false
        lastKnown.malibuProjectionFresh = false
        lastKnown.hasObservedProviderEarnings = true
        lastKnown.earningsUsdcToday = 0.04
        lastKnown.malibuWithdrawable = 2
        lastKnown.malibuHeld = 0
        let lastKnownHealth = AgentSnapshotPresenter.miningHealth(lastKnown)
        XCTAssertNotEqual(lastKnownHealth.reasonCode, "reward_projection_unavailable")
        XCTAssertTrue(lastKnownHealth.rewardSummary.contains("$0.04 USDC today"))
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(lastKnown), "$0.04")
        XCTAssertNotEqual(
            AgentSnapshotPresenter.dashboardSubtitle(lastKnown),
            "Ready for customer work · earnings unavailable"
        )
    }

    private func miningBase() -> AgentSnapshot {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.providerEarningsFresh = true
        snapshot.malibuProjectionFresh = true
        snapshot.walletBound = true
        snapshot.trustTier = .trusted
        snapshot.malibuWithdrawable = 0
        snapshot.malibuHeld = 0
        return snapshot
    }

    func testRecoveryCopyIsOnTheDashboardSurface() {
        XCTAssertEqual(DashboardCopy.resetProviderTitle, "Reset provider service")
        XCTAssertEqual(DashboardCopy.exportDiagnosticsTitle, "Export diagnostics…")
        XCTAssertEqual(DashboardCopy.recoveryHelpTitle, "If something is stuck")
        XCTAssertFalse(DashboardCopy.resetProviderConfirmDetail.contains("launchd"))
        XCTAssertFalse(DashboardCopy.resetProviderConfirmDetail.lowercased().contains("cli"))
    }
}
