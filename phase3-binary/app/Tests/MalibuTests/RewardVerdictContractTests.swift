import XCTest
@testable import Malibu

final class RewardVerdictContractTests: XCTestCase {
    func testTrustedLegacyLeftoverProvisionalLockStillUnlocksWithdrawableMalibu() {
        var snapshot = trustedServing()
        snapshot.malibuAccruedToday = 2
        snapshot.malibuAccruedAllTime = 14.5
        snapshot.updateRewardInputs(
            malibuWithdrawable: 2,
            malibuHeld: 12.5,
            malibuHoldReasons: ["trust_tier_provisional", "demotion_cooldown"],
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "held",
                withdrawalState: "held",
                primaryReason: "held_provisional_trust_tier",
                reasons: ["held_provisional_trust_tier"]
            )
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.trustDisplay, .trustedAuthoritative)
        XCTAssertEqual(verdict.malibuWithdrawal, .unlocked)
        XCTAssertTrue(verdict.canClaimWithdrawable)
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(snapshot).reasonCode, "trusted_withdrawable")
        XCTAssertNil(AgentSnapshotPresenter.malibuHoldLine(snapshot))
        XCTAssertFalse(AgentSnapshotPresenter.malibuFullLine(snapshot).lowercased().contains("locked"))
    }

    func testStaleTrustedTrustIsNeutralLiveAndCannotUnlockMalibu() {
        var snapshot = trustedServing()
        snapshot.updateRewardInputs(
            providerEarningsFresh: false,
            malibuProjectionFresh: false,
            malibuWithdrawable: 8,
            malibuHeld: 0
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.trustDisplay, .trustedStaleNeutral)
        XCTAssertEqual(verdict.malibuWithdrawal, .unknown)
        XCTAssertFalse(verdict.canClaimWithdrawable)
        XCTAssertEqual(AgentSnapshotPresenter.trustLine(snapshot), "Live")
    }

    func testFreshUsdcEarningDoesNotAssertMalibuUnlockWhenMalibuProjectionIsAbsent() {
        var snapshot = trustedServing()
        snapshot.earningsUsdcToday = 0.04
        snapshot.updateRewardInputs(malibuProjectionFresh: false)

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.usdcActivity, .earning)
        XCTAssertEqual(verdict.malibuWithdrawal, .unknown)
        XCTAssertFalse(verdict.canClaimWithdrawable)

        let health = AgentSnapshotPresenter.miningHealth(snapshot)
        XCTAssertEqual(health.reasonCode, "earning")
        XCTAssertTrue(health.rewardSummary.contains("MALIBU unavailable"))
    }

    func testFreshMalibuVerdictIsIndependentFromStaleUsdcProjection() {
        var snapshot = trustedServing()
        snapshot.updateRewardInputs(
            providerEarningsFresh: false,
            malibuHeld: 4,
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "capped",
                withdrawalState: "capped",
                primaryReason: "held_provider_daily_cap",
                reasons: ["held_provider_daily_cap"]
            )
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.usdcActivity, .none)
        XCTAssertEqual(verdict.malibuWithdrawal, .capped(.heldProviderDailyCap))
        XCTAssertFalse(verdict.canClaimWithdrawable)
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(snapshot).reasonCode, "provider_daily_cap_held")
    }

    func testEpochDispositionOutranksWithdrawableAmount() {
        var snapshot = trustedServing()
        snapshot.updateRewardInputs(
            malibuWithdrawable: 3,
            malibuHeld: 0,
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "held",
                withdrawalState: "held",
                primaryReason: "held_epoch_disposition",
                reasons: ["held_epoch_disposition"]
            )
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.reasonCode, .heldEpochDisposition)
        XCTAssertEqual(verdict.malibuWithdrawal, .epochDisposition(.heldEpochDisposition))
        XCTAssertFalse(verdict.canClaimWithdrawable)
        XCTAssertEqual(AgentSnapshotPresenter.miningHealth(snapshot).reasonCode, "rewards_held")
    }

    func testExplicitRewardTelemetryOutageOutranksWarmingUpAndEarningCopy() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.earningsUsdcToday = 0.04
        snapshot.updateRewardInputs(
            walletBound: true,
            trustTier: .trusted,
            providerEarningsFresh: true,
            malibuProjectionFresh: false,
            rewardTelemetryUnavailable: true
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.usdcActivity, .earning)
        XCTAssertEqual(verdict.malibuWithdrawal, .unavailable)
        XCTAssertEqual(verdict.reasonCode, .telemetryUnavailable)

        let health = AgentSnapshotPresenter.miningHealth(snapshot)
        XCTAssertEqual(health.status, "Reward status unavailable")
        XCTAssertFalse(health.status.contains("No earnings yet"))
        XCTAssertFalse(health.reason.contains("warming"))
    }

    func testReasonCodeHasClosedSemanticKnownSetAndUnknownEscapeHatch() {
        XCTAssertEqual(
            AgentSnapshotPresenter.RewardVerdict.ReasonCode.coordinator("held_epoch_disposition"),
            .heldEpochDisposition
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.RewardVerdict.ReasonCode.coordinator("future_reason"),
            .unknown("future_reason")
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.RewardVerdict.ReasonCode.coordinator("future_reason").rawValue,
            "unknown:future_reason"
        )
    }

    func testEveryKnownCoordinatorReasonMapsToTypedReasonCode() {
        for reason in MalibuRewardEligibility.knownReasons {
            if case .unknown = AgentSnapshotPresenter.RewardVerdict.ReasonCode.coordinator(reason) {
                XCTFail("\(reason) must be a typed RewardVerdict reason")
            }
        }
    }

    func testDecodedUnknownCoordinatorReasonReachesVerdictEscapeHatch() throws {
        let data = Data("""
        {
          "wallet_bound": true,
          "trust_tier": "trusted",
          "unpaid_ledger_backlog_usdc": 0,
          "unpaid_ledger_backlog_malibu": 0,
          "malibu_withdrawable": 0,
          "malibu_held": 0,
          "malibu_projection_fresh": true,
          "malibu_reward_eligibility": {
            "schema_version": "malibu_reward_eligibility.v1",
            "earning_state": "held",
            "withdrawal_state": "held",
            "primary_reason": "future_reason",
            "reasons": ["future_reason"]
          }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ProviderEarnings.self, from: data)
        var snapshot = trustedServing()
        snapshot.applyProviderEarnings(decoded, providerProjectionEligible: true)

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.reasonCode, .unknown("future_reason"))
        XCTAssertEqual(verdict.malibuWithdrawal, .unknown)
    }

    func testDecodedUnknownCoordinatorReasonLogsSchemaDriftFields() throws {
        var logged: [(String, String)] = []
        let observer = NotificationCenter.default.addObserver(
            forName: MalibuRewardEligibility.schemaDriftNotification,
            object: nil,
            queue: nil
        ) { note in
            guard let schema = note.userInfo?["schema_version"] as? String,
                  let field = note.userInfo?["field"] as? String else { return }
            logged.append((schema, field))
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let data = Data("""
        {
          "wallet_bound": true,
          "trust_tier": "trusted",
          "unpaid_ledger_backlog_usdc": 0,
          "unpaid_ledger_backlog_malibu": 0,
          "malibu_projection_fresh": true,
          "malibu_reward_eligibility": {
            "schema_version": "malibu_reward_eligibility.v1",
            "earning_state": "held",
            "withdrawal_state": "held",
            "primary_reason": "future_reason",
            "reasons": ["future_reason", "held_provider_daily_cap"]
          }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ProviderEarnings.self, from: data)

        XCTAssertEqual(decoded.malibuRewardEligibility?.primaryReason, "future_reason")
        XCTAssertEqual(decoded.malibuRewardEligibility?.reasons.first, "future_reason")
        XCTAssertEqual(logged.map { "\($0.0):\($0.1)" }, [
            "malibu_reward_eligibility.v1:primary_reason",
            "malibu_reward_eligibility.v1:reasons",
        ])
    }

    func testUnknownWithdrawableReasonCannotUnlockPositiveMalibuAmount() {
        var snapshot = trustedServing()
        snapshot.updateRewardInputs(
            malibuWithdrawable: 4,
            malibuHeld: 0,
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "earning",
                withdrawalState: "withdrawable",
                primaryReason: "future_reason",
                reasons: ["future_reason"]
            )
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.reasonCode, .unknown("future_reason"))
        XCTAssertEqual(verdict.malibuWithdrawal, .unknown)
        XCTAssertFalse(verdict.canClaimWithdrawable)
        XCTAssertFalse(AgentSnapshotPresenter.malibuFullLine(snapshot).contains("4.00 MALIBU ·"))
    }

    func testMissingPrimaryReasonCannotBecomeNoActionHeldVerdict() {
        var snapshot = trustedServing()
        snapshot.updateRewardInputs(
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "held",
                withdrawalState: "held",
                primaryReason: "",
                reasons: []
            )
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.reasonCode, .unknown("missing_primary_reason"))
        XCTAssertEqual(verdict.malibuWithdrawal, .unknown)
    }

    func testStaleUsdcWithoutPriorFreshObservationDoesNotRenderAsTodayMoney() {
        var snapshot = trustedServing()
        snapshot.hasObservedProviderEarnings = false
        snapshot.earningsUsdcToday = 9.25
        snapshot.updateRewardInputs(
            providerEarningsFresh: false,
            malibuProjectionFresh: true,
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "eligible_idle",
                withdrawalState: "withdrawable",
                primaryReason: "withdrawable_no_balance",
                reasons: ["withdrawable_no_balance"]
            )
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.usdcActivity, .none)
        XCTAssertEqual(AgentSnapshotPresenter.usdcPeriodLabel(snapshot, verdict: verdict), "Today")
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot, verdict: verdict), "n/a")
        XCTAssertFalse(AgentSnapshotPresenter.usdcFullLine(snapshot, verdict: verdict).contains("$9.25 today"))
        XCTAssertFalse(AgentSnapshotPresenter.usdcFullLine(snapshot, verdict: verdict).contains("Today: $9.25"))
    }

    func testUnavailableStatePreservesNonTelemetryPrimaryReason() {
        var snapshot = trustedServing()
        snapshot.updateRewardInputs(
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "unavailable",
                withdrawalState: "unavailable",
                primaryReason: "compute_integrity_pending",
                reasons: ["compute_integrity_pending"]
            )
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.reasonCode, .computeIntegrityPending)
        XCTAssertEqual(verdict.malibuWithdrawal, .unavailable)
    }

    func testMissingWalletReasonCannotRenderPositiveWithdrawableAsAvailable() {
        var snapshot = trustedServing()
        snapshot.walletBound = false
        snapshot.malibuAccruedToday = 3
        snapshot.updateRewardInputs(
            malibuWithdrawable: 3,
            malibuHeld: 1,
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "ineligible",
                withdrawalState: "ineligible",
                primaryReason: "missing_wallet_binding",
                reasons: ["missing_wallet_binding"]
            )
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.reasonCode, .walletMissing)
        XCTAssertEqual(verdict.malibuWithdrawal, .none)
        XCTAssertFalse(verdict.canClaimWithdrawable)
        XCTAssertEqual(
            AgentSnapshotPresenter.malibuAvailabilityLine(snapshot),
            "MALIBU: wallet required · 1.00 held"
        )
        let rewardSummary = AgentSnapshotPresenter.miningHealth(snapshot).rewardSummary
        XCTAssertFalse(rewardSummary.contains("3.00 withdrawable"))
        XCTAssertFalse(rewardSummary.contains("3.00 available"))
    }

    func testCoordinatorNoBalanceReasonCannotUnlockPositiveMalibuAmount() {
        var snapshot = trustedServing()
        snapshot.updateRewardInputs(
            malibuWithdrawable: 3,
            malibuHeld: 0,
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "eligible_idle",
                withdrawalState: "withdrawable",
                primaryReason: "withdrawable_no_balance",
                reasons: ["withdrawable_no_balance"]
            )
        )

        let verdict = AgentSnapshotPresenter.rewardVerdict(snapshot)
        XCTAssertEqual(verdict.reasonCode, .idleNoWork)
        XCTAssertEqual(verdict.malibuWithdrawal, .none)
        XCTAssertFalse(verdict.canClaimWithdrawable)
        let rewardSummary = AgentSnapshotPresenter.miningHealth(snapshot).rewardSummary
        XCTAssertTrue(rewardSummary.contains("not withdrawable"))
        XCTAssertFalse(rewardSummary.contains("3.00 withdrawable"))
        XCTAssertFalse(rewardSummary.contains("3.00 available"))
    }

    func testPositiveWithdrawableReasonRequiresNonEmptyKnownReasonsSet() {
        var emptyReasons = trustedServing()
        emptyReasons.updateRewardInputs(
            malibuWithdrawable: 3,
            malibuHeld: 0,
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "earning",
                withdrawalState: "withdrawable",
                primaryReason: "withdrawable_balance_available",
                reasons: []
            )
        )
        let emptyVerdict = AgentSnapshotPresenter.rewardVerdict(emptyReasons)
        XCTAssertEqual(emptyVerdict.reasonCode, .unknown("malformed_withdrawable_reason_set"))
        XCTAssertEqual(emptyVerdict.malibuWithdrawal, .unknown)
        XCTAssertFalse(emptyVerdict.canClaimWithdrawable)

        var unknownExtraReason = trustedServing()
        unknownExtraReason.updateRewardInputs(
            malibuWithdrawable: 3,
            malibuHeld: 0,
            malibuRewardEligibility: MalibuRewardEligibility(
                earningState: "earning",
                withdrawalState: "withdrawable",
                primaryReason: "withdrawable_balance_available",
                reasons: ["withdrawable_balance_available", "future_positive_reason"]
            )
        )
        let unknownExtraVerdict = AgentSnapshotPresenter.rewardVerdict(unknownExtraReason)
        XCTAssertEqual(unknownExtraVerdict.reasonCode, .unknown("malformed_withdrawable_reason_set"))
        XCTAssertEqual(unknownExtraVerdict.malibuWithdrawal, .unknown)
        XCTAssertFalse(unknownExtraVerdict.canClaimWithdrawable)
    }

    func testTrustProgressIsSanitizedFromGranularAndLegacyInputs() {
        var overlapping = AgentSnapshot.empty
        overlapping.updateRewardInputs(
            trustTier: .provisional,
            economicCriteria: ["E2"],
            additionalCriteria: ["A3"],
            hasGranularTrustCriteria: true
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.rewardVerdict(overlapping).trustProgress,
            AgentSnapshotPresenter.RewardVerdict.TrustProgress(met: 1, required: 2)
        )

        var distinct = overlapping
        distinct.updateRewardInputs(additionalCriteria: ["A4"])
        XCTAssertEqual(
            AgentSnapshotPresenter.rewardVerdict(distinct).trustProgress,
            AgentSnapshotPresenter.RewardVerdict.TrustProgress(met: 2, required: 2)
        )

        var clamped = AgentSnapshot.empty
        clamped.updateRewardInputs(
            trustTier: .provisional,
            trustCriteriaMet: 4,
            trustCriteriaRequired: 2
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.rewardVerdict(clamped).trustProgress,
            AgentSnapshotPresenter.RewardVerdict.TrustProgress(met: 2, required: 2)
        )
    }

    func testSliceADoesNotExposeRawRewardInputsToMoneyPathViewsAndLegacyHelpers() throws {
        let testsFile = URL(fileURLWithPath: #filePath)
        let appRoot = testsFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            appRoot.appendingPathComponent("Sources/Malibu/Dashboard/DashboardWindow.swift"),
            appRoot.appendingPathComponent("Sources/Malibu/MenuBar/MenuBarController.swift"),
        ]
        let prohibited = [
            ".trustTier",
            ".malibuProjectionFresh",
            ".providerEarningsFresh",
            ".malibuWithdrawable",
            ".malibuHeld",
            ".malibuHoldReasons",
            ".malibuRewardEligibility",
            ".trustCriteriaMet",
            ".trustCriteriaRequired",
            ".rewardTelemetryUnavailable",
            ".economicCriteria",
            ".additionalCriteria",
        ]

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for token in prohibited {
                XCTAssertFalse(
                    contents.contains(token),
                    "\(file.lastPathComponent) must consume RewardVerdict instead of \(token)"
                )
            }
        }

        let presenter = try String(
            contentsOf: appRoot.appendingPathComponent("Sources/Malibu/Agent/AgentSnapshot.swift"),
            encoding: .utf8
        )
        for legacyHelper in [
            "displayRewardEligibility(_ s: AgentSnapshot)",
            "displayMalibuHoldReasons(_ s: AgentSnapshot)",
            "shouldIgnoreLeftoverProvisionalLock(_ s: AgentSnapshot)",
            "malibuDisplay(_ amount: Double, snapshot: AgentSnapshot",
        ] {
            XCTAssertFalse(
                presenter.contains(legacyHelper),
                "AgentSnapshotPresenter must consume RewardVerdict instead of legacy raw helper \(legacyHelper)"
            )
        }
    }

    private func trustedServing() -> AgentSnapshot {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.walletBound = true
        snapshot.updateRewardInputs(
            trustTier: .trusted,
            providerEarningsFresh: true,
            malibuProjectionFresh: true,
            malibuWithdrawable: 0,
            malibuHeld: 0
        )
        return snapshot
    }
}
