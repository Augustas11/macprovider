import XCTest
@testable import Malibu

/// #2029 Phase 1: the dashboard states what is true, for the state the
/// 2026-10-18 UX audit captured (Provisional, cooldown elapsed 10 Oct, MALIBU
/// emission off since 18 Aug, payouts disabled, USDC $0.15 lifetime).
final class TruthfulDashboardTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-18T00:40:00Z")!

    private func auditSnapshot(
        eligibility: MalibuRewardEligibility? = nil,
        trustProgress: MalibuTrustProgress?? = nil,
        emission: MalibuEmissionState?? = nil
    ) -> AgentSnapshot {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.currentModelID = "meta-llama/llama-3.2-3b-instruct"
        snapshot.thermalState = .nominal
        snapshot.uptimeSec = 35_880
        snapshot.restartCount = 2286
        snapshot.restartCount7d = 1
        snapshot.advertisedMaxConcurrency = 1
        snapshot.earningsUsdcToday = 0
        snapshot.earningsUsdcWeek = 0.0001
        snapshot.earningsUsdcPending = 0.152012
        snapshot.earningsUsdcLifetime = 0.154264
        snapshot.malibuAccruedAllTime = 257.03
        snapshot.payoutsEnabled = false
        snapshot.lastPaidJobAt = now.addingTimeInterval(-7 * 3_600)
        snapshot.payoutRegisteredAddress = "0xBE1c000000000000000000000000000000005dcd"
        snapshot.updateRewardInputs(
            walletBound: true,
            trustTier: .provisional,
            providerEarningsFresh: true,
            malibuProjectionFresh: true,
            malibuWithdrawable: 43.49,
            malibuHeld: 213.54,
            malibuHoldReasons: ["demotion_cooldown", "trust_tier_provisional"],
            malibuRewardEligibility: eligibility ?? MalibuRewardEligibility(
                earningState: "ineligible",
                withdrawalState: "held",
                primaryReason: "hardware_evidence_missing_or_expired",
                reasons: [
                    "compute_integrity_unavailable",
                    "hardware_evidence_missing_or_expired",
                    "held_provisional_trust_tier",
                    "held_retained_trust_hold",
                    "app_attestation_missing",
                    "withdrawable_balance_available",
                ]
            )
        )
        let uptimeSince = ISO8601DateFormatter().date(from: "2026-10-16T03:52:00Z")!
        snapshot.malibuTrustProgress = trustProgress ?? MalibuTrustProgress(
            tier: .provisional,
            demotionCooldownUntil: ISO8601DateFormatter().date(from: "2026-10-10T16:54:00Z"),
            demotionCooldownActive: false,
            requalificationRequired: true,
            uptimeOKSince: uptimeSince,
            verifiedReceiptCount: 12_587,
            requiredReceiptCount: 100,
            criteriaMet: ["E1"],
            earliestPromotionAt: uptimeSince.addingTimeInterval(144 * 3_600)
        )
        snapshot.malibuEmission = emission ?? MalibuEmissionState(
            active: false,
            lastAccrualAt: ISO8601DateFormatter().date(from: "2026-08-18T03:05:00Z")
        )
        return snapshot
    }

    /// Phrases the audit found false or misleading; none may render.
    private let forbidden = [
        "Trust verification is in progress",
        "trust review",
        "Trust review",
        "in progress",
        "payouts open in beta",
        "locked until eligible",
        "daily not reported",
        "Mining Health",
        "Rewards held",
        "Live · Provisional",
        "7d uptime",
        "declined",
        "GPU n/a",
        "unknown_cause",
        "Cause:",
        "_",
    ]

    private func assertNoForbiddenCopy(_ strings: [String], file: StaticString = #filePath, line: UInt = #line) {
        let text = strings.joined(separator: "\n")
        for phrase in forbidden where phrase != "_" {
            XCTAssertFalse(text.contains(phrase), "renders forbidden phrase \"\(phrase)\":\n\(text)", file: file, line: line)
        }
    }

    func testHeldMalibuIsStatedAsHeldNotReleasedNotWithdrawable() {
        let card = AgentSnapshotPresenter.earningsCard(auditSnapshot(), now: now)
        XCTAssertTrue(card.malibuLines.contains("MALIBU balance: 257.03 (beta points) · 213.54 held · 43.49 not held."))
        XCTAssertTrue(card.malibuLines.contains("Held MALIBU is not released and not withdrawable. MALIBU has no withdrawals yet."))
        let text = card.malibuLines.joined(separator: " ")
        for promise in ["will be released", "until Trusted", "until eligible", "eligible for withdrawal", "withdrawable MALIBU"] {
            XCTAssertFalse(text.contains(promise), "implies a release: \(promise)")
        }
    }

    func testEmissionOffIsStatedNetworkWide() {
        let card = AgentSnapshotPresenter.earningsCard(auditSnapshot(), now: now)
        XCTAssertEqual(card.malibuLines.first, "MALIBU rewards are paused network-wide. No new MALIBU since 18 Aug.")
        XCTAssertNil(card.hardwareBlocker, "an earning blocker is noise while emission is off")

        var running = auditSnapshot(emission: .some(MalibuEmissionState(active: true)))
        XCTAssertFalse(AgentSnapshotPresenter.earningsCard(running, now: now).malibuLines.contains { $0.contains("paused") })
        XCTAssertEqual(
            AgentSnapshotPresenter.earningsCard(running, now: now).hardwareBlocker,
            "New MALIBU needs verified hardware evidence for this Mac. Export diagnostics for support."
        )
        running.malibuEmission = nil
        XCTAssertFalse(AgentSnapshotPresenter.earningsCard(running, now: now).malibuLines.contains { $0.contains("paused") },
                       "an older coordinator that does not report emission gets no paused claim")
    }

    func testPayoutsDisabledIsStatedAndNeverPromised() {
        let snapshot = auditSnapshot()
        let card = AgentSnapshotPresenter.earningsCard(snapshot, now: now)
        XCTAssertEqual(card.usdcSummary, "$0.15 lifetime · $0.0001 this week · $0.00 today (UTC)")
        XCTAssertEqual(card.payoutLine, "Payouts are not enabled yet in beta. USDC earnings stay recorded.")
        XCTAssertFalse((card.payoutLine ?? "").contains("Unpaid"), "pending is not net of past payouts")

        var enabled = snapshot
        enabled.payoutsEnabled = true
        XCTAssertNil(AgentSnapshotPresenter.earningsCard(enabled, now: now).payoutLine)
        var unknown = snapshot
        unknown.payoutsEnabled = nil
        XCTAssertNil(AgentSnapshotPresenter.earningsCard(unknown, now: now).payoutLine)
        var stale = snapshot
        stale.updateRewardInputs(providerEarningsFresh: false)
        stale.hasObservedProviderEarnings = true
        XCTAssertNil(AgentSnapshotPresenter.earningsCard(stale, now: now).payoutLine, "no payout claim from a stale read")
    }

    func testTrustShowsRealProgressAndETA() {
        let line = AgentSnapshotPresenter.earningsCard(auditSnapshot(), now: now).trustLine
        XCTAssertEqual(
            line,
            "Trust: Provisional · online without a gap 44 of 72 h · then 72 h of requalification · earliest Trusted 22 Oct if online without a gap. Trust affects MALIBU only, not USDC."
        )
    }

    func testTrustWithoutEvaluatorWindowsShowsTierOnly() {
        let snapshot = auditSnapshot(trustProgress: .some(nil))
        XCTAssertEqual(
            AgentSnapshotPresenter.earningsCard(snapshot, now: now).trustLine,
            "Trust: Provisional. Trust affects MALIBU only, not USDC."
        )
    }

    /// An older coordinator still unions the August cooldown hold into the
    /// primary reason. The app must not turn that into a running review.
    func testStaleCooldownHoldFromOlderCoordinatorRendersNoTrustReview() {
        let snapshot = auditSnapshot(
            eligibility: MalibuRewardEligibility(
                earningState: "ineligible",
                withdrawalState: "held",
                primaryReason: "held_demotion_cooldown",
                reasons: ["held_demotion_cooldown", "held_provisional_trust_tier", "hardware_evidence_missing_or_expired"]
            ),
            trustProgress: .some(nil),
            emission: .some(nil)
        )
        let strings = DashboardCopy.defaultPublicStrings(snapshot, now: now)
        assertNoForbiddenCopy(strings)
        XCTAssertTrue(strings.contains("Held MALIBU is not released and not withdrawable. MALIBU has no withdrawals yet."))
        XCTAssertFalse(AgentSnapshotPresenter.consolidatedStatus(snapshot).meaning.contains("MALIBU"))
    }

    func testOneStatusPillAndNoDuplicateMessages() {
        let snapshot = auditSnapshot()
        let pill = AgentSnapshotPresenter.statusPill(snapshot)
        XCTAssertEqual(pill.label, "Serving")
        XCTAssertEqual(pill.accessibilityLabel, "Malibu status: Serving")
        let strings = DashboardCopy.defaultPublicStrings(snapshot, now: now)
        XCTAssertEqual(strings.filter { $0 == "Serving" }.count, 1)
        XCTAssertEqual(Set(strings).count, strings.count, "a message repeats on the main screen: \(strings)")
        XCTAssertEqual(strings.filter { $0.contains("213.54") }.count, 1)
        XCTAssertEqual(strings.filter { $0.contains("Trust:") }.count, 1)
        assertNoForbiddenCopy(strings)
    }

    func testHeaderShowsLastCreditedJob() {
        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(auditSnapshot(), now: now),
            "meta-llama/llama-3.2-3b-instruct · last credited job 7 h ago"
        )
    }

    func testMenuBarEarningsRowIsUsdcOnlyWithUTCDay() {
        XCTAssertEqual(
            AgentSnapshotPresenter.earningsLine(auditSnapshot()),
            "USDC today (UTC): $0.00 · $0.15 lifetime"
        )
    }

    func testDiagnosticsAreHumanisedAndDeduplicated() {
        var snapshot = auditSnapshot()
        let finding = ProviderDiagnosticFinding(
            signatureID: .serveUnresponsive,
            source: .status,
            userMessage: "Provider local status is unavailable or stale.",
            evidence: nil,
            observedAt: now
        )
        snapshot.diagnosticFindings = [finding, finding]
        let lines = AgentSnapshotPresenter.diagnosticFindingLines(snapshot)
        XCTAssertEqual(lines, ["Customer availability · Provider local status is unavailable or stale. · Cause unknown"])
        assertNoForbiddenCopy(lines)
    }

    func testResolvedAndSupersededLifecycleEventsAreDropped() {
        var snapshot = auditSnapshot()
        snapshot.lifecycleState = "serving_buyers"
        snapshot.lifecycleTransitionAt = ISO8601DateFormatter().date(from: "2026-10-17T14:37:51Z")
        snapshot.compatibilitySetID = "Augustas11/macprovider:v1.8.251@bbbb"
        snapshot.lifecycleLastRejection = ProviderLifecycleEventSnapshot(
            sequence: 3, transitionID: "t-3",
            transitionAt: ISO8601DateFormatter().date(from: "2026-10-09T08:00:00Z")!,
            state: "catalog_incompatible", reason: "catalog_incompatible", writer: "serve",
            compatibilitySetID: "Augustas11/macprovider:v1.8.224@aaaa", operationID: nil
        )
        snapshot.lifecycleLastUpdate = ProviderLifecycleEventSnapshot(
            sequence: 1, transitionID: "t-1",
            transitionAt: ISO8601DateFormatter().date(from: "2026-09-08T08:00:00Z")!,
            state: "update_in_progress", reason: "updated_provider_software_locally_healthy", writer: "updater",
            compatibilitySetID: "Augustas11/macprovider:v1.8.123@cccc", operationID: nil
        )
        XCTAssertNil(AgentSnapshotPresenter.currentSetupFailure(snapshot), "resolved by the later return to serving")
        XCTAssertNil(AgentSnapshotPresenter.currentLastUpdate(snapshot), "names software that is no longer installed")

        snapshot.lifecycleState = "catalog_incompatible"
        XCTAssertNotNil(AgentSnapshotPresenter.currentSetupFailure(snapshot))
        snapshot.lifecycleLastUpdate = ProviderLifecycleEventSnapshot(
            sequence: 9, transitionID: "t-9",
            transitionAt: ISO8601DateFormatter().date(from: "2026-10-17T14:37:00Z")!,
            state: "importing_credentials", reason: "resolving_cli_keychain_custody", writer: "serve",
            compatibilitySetID: "Augustas11/macprovider:v1.8.251@bbbb", operationID: nil
        )
        let update = try? XCTUnwrap(AgentSnapshotPresenter.currentLastUpdate(snapshot))
        XCTAssertTrue(update.map(AgentSnapshotPresenter.lastUpdateDisplay)?.hasPrefix("Provider software updated · ") == true)
    }

    /// Text render of the default dashboard for the PR evidence.
    func testPrintsDefaultDashboardTextRender() {
        let strings = DashboardCopy.defaultPublicStrings(auditSnapshot(), now: now)
        print("MALIBU_DASHBOARD_RENDER_BEGIN\n" + strings.joined(separator: "\n") + "\nMALIBU_DASHBOARD_RENDER_END")
        assertNoForbiddenCopy(strings)
    }
}
