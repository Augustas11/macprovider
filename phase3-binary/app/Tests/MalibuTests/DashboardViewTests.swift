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
        // Not-fresh telemetry stays calm and small rather than four "n/a"s or a
        // fabricated hero "$0.00" (P0.2).
        XCTAssertEqual(AgentSnapshotPresenter.usdcFullLine(snapshot), "Earnings not available yet")
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot), "—")
        XCTAssertEqual(AgentSnapshotPresenter.queueChip(snapshot), "0 queued")
        XCTAssertEqual(AgentSnapshotPresenter.thermalChip(snapshot), "Thermal OK")
        // Header + card share one ConsolidatedStatus source (MED-4). No wallet
        // + no fresh telemetry yet → benign Live · Provisional, calm tone.
        let status = AgentSnapshotPresenter.consolidatedStatus(snapshot)
        XCTAssertEqual(status.label, "Live · Provisional")
        XCTAssertEqual(status.tone, .neutral)
    }

    func testFreshServingWithoutEarningsShowsQuietNetwork() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.providerEarningsFresh = true
        snapshot.walletBound = true

        let status = AgentSnapshotPresenter.consolidatedStatus(snapshot)
        XCTAssertEqual(status.tone, .neutral)
        XCTAssertTrue(status.meaning.contains("network is quiet"), status.meaning)
    }

    func testFreshServingWithZeroEarningsIsNetworkQuietNotBroken() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.providerEarningsFresh = true
        snapshot.walletBound = true
        snapshot.earningsUsdcToday = 0
        snapshot.currentModelID = "Qwen3-8B"

        let status = AgentSnapshotPresenter.consolidatedStatus(snapshot)
        XCTAssertEqual(status.tone, .neutral)
        XCTAssertTrue(status.meaning.contains("network is quiet"), status.meaning)
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

        // Not yet buyer-serving-admitted → the consolidated status is "Setting up".
        XCTAssertEqual(AgentSnapshotPresenter.consolidatedStatus(snapshot).phase, .settingUp)
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
        // A live, admitted provider with no fresh telemetry yet is the benign
        // warming-up state (calm), not a fault (P0.1).
        XCTAssertEqual(unavailableHealth.reasonCode, "reward_projection_warming_up")
        XCTAssertEqual(unavailableHealth.rewardSummary, "USDC unavailable · MALIBU unavailable")

        var missingWallet = miningBase()
        missingWallet.walletBound = false
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(missingWallet).reasonCode, "wallet_missing")

        // A live provider that has never earned is the normal fresh state, not a
        // fault. Its headline must read forward-looking (not "unavailable") and
        // its next action must be concrete, not "keep waiting".
        var liveNoEarnings = AgentSnapshot.empty
        liveNoEarnings.state = .serving
        liveNoEarnings.networkState = "buyer_serving"
        liveNoEarnings.walletBound = false
        let liveNoEarningsHealth = AgentSnapshotPresenter.miningHealth(liveNoEarnings)
        XCTAssertEqual(liveNoEarningsHealth.status, "No earnings yet")
        // Benign fresh-provider state reads calm, not as an outage (P0.1).
        XCTAssertEqual(liveNoEarningsHealth.reasonCode, "reward_projection_warming_up")
        XCTAssertFalse(liveNoEarningsHealth.status.lowercased().contains("unavailable"))
        XCTAssertTrue(liveNoEarningsHealth.nextAction.contains("wallet"))
        XCTAssertFalse(liveNoEarningsHealth.nextAction.contains("reward status refreshes"))

        // Guard regression 1: a reconnecting/local-only provider is NOT yet
        // buyer-serving-admitted, so it must not claim "No earnings yet".
        var reconnecting = AgentSnapshot.empty
        reconnecting.state = .reconnecting
        reconnecting.currentModelID = "meta-llama/llama-3.2-3b-instruct"
        XCTAssertNotEqual(
            AgentSnapshotPresenter.miningHealth(reconnecting).status, "No earnings yet")

        // Guard regression 2: a fresh MALIBU projection must not be preempted by
        // the reframe (it should keep the conservative wording, not "No earnings
        // yet"), so held/withdrawable/locked reward state is never mislabeled.
        var malibuFresh = AgentSnapshot.empty
        malibuFresh.state = .serving
        malibuFresh.networkState = "buyer_serving"
        malibuFresh.malibuProjectionFresh = true
        malibuFresh.trustTier = .provisional
        XCTAssertNotEqual(
            AgentSnapshotPresenter.miningHealth(malibuFresh).status, "No earnings yet")

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
        XCTAssertEqual(cooldownHealth.trustSummary, "Trust: Provisional · Trust review in progress")
        XCTAssertEqual(cooldownHealth.nextAction, "Keep Malibu online; withdrawals unlock automatically when Trusted.")
        XCTAssertEqual(AgentSnapshotPresenter.trustLine(provisional), "Provisional — Trust review in progress")

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
        // Distinct-pair truth: an economic criterion satisfied, no distinct
        // additional yet → 1 of 2 (not the raw unique-ID count).
        unlockTrusted.hasGranularTrustCriteria = true
        unlockTrusted.economicCriteria = ["E1"]
        unlockTrusted.additionalCriteria = ["E1"]
        XCTAssertEqual(
            AgentSnapshotPresenter.trustLine(unlockTrusted),
            "Provisional — 1 of 2 criteria met"
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
        // A brand-new all-zero fresh frame is a real $0.00 today, not "n/a"
        // (consistent with the hero number and the full USDC line).
        XCTAssertEqual(freshHealth.rewardSummary, "$0.00 USDC today · MALIBU 0.00 withdrawable / 0.00 held")

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

        // A provider that is NOT yet buyer-serving-admitted with no fresh
        // telemetry keeps the genuine "unavailable" (amber) wording (P0.1).
        var stale = miningBase()
        stale.state = .reconnecting
        stale.networkState = "buyer_serving_unknown"
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
        // A real fresh frame carries a usable eligibility verdict; without one
        // the projection is treated as a genuine telemetry outage. Give the
        // base a concrete withdrawable verdict so these operational-state cases
        // exercise earning/idle/hold logic rather than the unavailable path.
        snapshot.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "earning",
            withdrawalState: "withdrawable",
            primaryReason: "",
            reasons: []
        )
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
