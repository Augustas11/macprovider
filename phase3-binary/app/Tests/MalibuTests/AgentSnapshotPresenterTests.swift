import XCTest
@testable import Malibu

// AUDIT R1 ARCHITECT A1: rendering "not reported yet" must remain distinct
// from authoritative "$0.00" when a supported legacy peer omits telemetry.

final class AgentSnapshotPresenterTests: XCTestCase {
    private let prohibitedPublicTerms = [
        "compatibility set",
        "admission identity",
        "watchdog",
        "buyer-serving",
        "spec-023",
        "spec-026",
        "spec-027",
        "migration token",
        "credential custody",
        "coordinator admission",
        "provider cli",
        "macprovider-cli",
        "cli-owned",
        "terminal path",
        "referral_bootstrap_v1",
    ]

    func testEarningsLineShowsUnavailableWhenBothMetricsMissingWhileServing() {
        var s = AgentSnapshot.empty
        s.state = .serving
        XCTAssertEqual(AgentSnapshotPresenter.earningsLine(s), "Today: reward status unavailable")
    }

    func testMalibuDailyMissingExplainsProjectionInsteadOfShowingNA() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = true
        s.earningsUsdcToday = 0.04
        s.malibuAccruedToday = nil
        s.malibuAccruedAllTime = 12.5
        s.malibuHeld = 12.5
        s.trustTier = .provisional
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )

        XCTAssertEqual(
            AgentSnapshotPresenter.earningsLine(s),
            "Today: $0.04 USDC · MALIBU daily not reported yet"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.malibuFullLine(s),
            "MALIBU daily not reported yet · 12.50 all-time · locked until eligible"
        )
    }

    func testUptimeLineLabelsProviderProcessRuntimeAsCurrentRun() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.uptimeSec = 75
        s.uptime7dPct = 99.5
        s.declinedRequests = 0
        s.restartCount = 2

        XCTAssertEqual(
            AgentSnapshotPresenter.uptimeLine(s),
            "1m current run · 99.5% uptime (7d) · 0 declined · 2 restarts"
        )
    }

    func testShortShowsServingWhenNoEarningsYet() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.coordinatorConnected = true
        s.networkState = "buyer_serving"
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "Serving")
    }

    func testCoordinatorConnectionWithoutNetworkStateIsNotBuyerServing() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.coordinatorConnected = true
        s.networkState = nil

        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(s))
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "Connected")
        // Not yet buyer-serving-admitted → consolidated status is "Setting up".
        let checking = AgentSnapshotPresenter.consolidatedStatus(s)
        XCTAssertEqual(checking.phase, .settingUp)
        XCTAssertEqual(
            checking.meaning,
            "Malibu has not received a current network approval status yet."
        )
        XCTAssertEqual(AgentSnapshotPresenter.stateLine(s), "Checking customer availability")
    }

    func testPublicStatusPresentsRequiredUserStates() {
        var waiting = AgentSnapshot.empty
        waiting.state = .reconnecting
        waiting.currentModelID = "llama"
        waiting.networkState = "live_verified"
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(waiting).title, "Waiting for network approval")

        var interrupted = AgentSnapshot.empty
        interrupted.state = .reconnecting
        interrupted.currentModelID = "llama"
        interrupted.networkState = "not_buyer_serving"
        XCTAssertEqual(
            AgentSnapshotPresenter.publicStatus(interrupted).title,
            "Customer availability is temporarily interrupted"
        )

        var preparing = AgentSnapshot.empty
        preparing.state = .starting
        preparing.lifecycleState = "loading_model"
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(preparing).title, "Model is preparing")

        var ready = AgentSnapshot.empty
        ready.state = .serving
        ready.networkState = "buyer_serving"
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(ready).title, "Provider is ready")
    }

    func testPublicStatusHoldsReadyAcrossTransientLiveVerifiedBlip() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "qwen3-8b"
        snapshot.networkState = "live_verified"
        snapshot.coordinatorConnected = false
        snapshot.lastBuyerServingAt = Date()
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "obs-hold"
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true

        XCTAssertTrue(AgentSnapshotPresenter.isNetworkReady(snapshot))
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(snapshot).title, "Provider is ready")
        XCTAssertEqual(AgentSnapshotPresenter.short(snapshot), "Serving")
    }

    func testPublicStatusHoldsReadyAcrossBuyerServingUnknown() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "qwen3-8b"
        snapshot.networkState = "buyer_serving_unknown"
        snapshot.coordinatorConnected = true
        snapshot.lastBuyerServingAt = Date()
        snapshot.statusObservationFresh = true

        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(snapshot).title, "Provider is ready")
    }

    func testPublicStatusStillWaitsForApprovalOnFirstJoin() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .reconnecting
        snapshot.currentModelID = "qwen3-8b"
        snapshot.networkState = "live_verified"
        snapshot.coordinatorConnected = true
        snapshot.lastBuyerServingAt = nil

        XCTAssertEqual(
            AgentSnapshotPresenter.publicStatus(snapshot).title,
            "Waiting for network approval"
        )
    }

    func testPersistedBuyerServingHoldKeepsReadyAfterRelaunchBlip() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-observation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let providerID = "mp-1962fb3ccb9fa0d227767c3a77b54fbe"
        let servedAt = Date().addingTimeInterval(-120)
        DashboardObservationStore.save(
            DashboardObservationStore.Record(
                providerID: providerID,
                lastBuyerServingAt: servedAt,
                hasObservedProviderEarnings: true,
                earningsUsdcToday: 0.04,
                earningsUsdcWeek: 0.12,
                earningsUsdcPending: 0.01,
                earningsUsdcLifetime: 18.4,
                malibuAccruedToday: 2,
                malibuAccruedAllTime: 8,
                malibuWithdrawable: 8,
                malibuHeld: 0,
                walletBound: true,
                recordedAt: Date()
            ),
            fileURL: fileURL
        )

        let record = DashboardObservationStore.load(providerID: providerID, fileURL: fileURL)
        XCTAssertEqual(
            record?.lastBuyerServingAt?.timeIntervalSince1970 ?? 0,
            servedAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(record?.earningsUsdcToday, 0.04)
        XCTAssertNil(DashboardObservationStore.load(providerID: "mp-other", fileURL: fileURL))

        var snapshot = AgentSnapshot.empty
        snapshot.state = .starting
        snapshot.localProviderID = providerID
        snapshot.lastBuyerServingAt = record?.lastBuyerServingAt
        snapshot.hasObservedProviderEarnings = record?.hasObservedProviderEarnings ?? false
        snapshot.earningsUsdcToday = record?.earningsUsdcToday
        snapshot.state = .serving
        snapshot.currentModelID = "qwen3-8b"
        snapshot.networkState = "live_verified"
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "obs-relaunch"
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true

        XCTAssertTrue(AgentSnapshotPresenter.isNetworkReady(snapshot))
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(snapshot).title, "Provider is ready")
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(snapshot), "$0.04")
    }

    func testIncumbentJobHistoryHoldsReadyOnFirstLaunchWithoutPersistFile() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "qwen3-8b"
        snapshot.networkState = "live_verified"
        snapshot.coordinatorConnected = false
        snapshot.requestsServedAllTime = 12
        snapshot.earningsUsdcLifetime = 18.4
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "obs-incumbent"
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        snapshot.updateBuyerServingHold()

        XCTAssertNotNil(snapshot.lastBuyerServingAt)
        XCTAssertTrue(AgentSnapshotPresenter.isNetworkReady(snapshot))
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(snapshot).title, "Provider is ready")
    }

    func testBuyerServingHoldClearsOnCoordinatorNotServing() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "qwen3-8b"
        snapshot.networkState = "not_buyer_serving"
        snapshot.lastBuyerServingAt = Date()
        snapshot.updateBuyerServingHold()

        XCTAssertNil(snapshot.lastBuyerServingAt)
        XCTAssertEqual(
            AgentSnapshotPresenter.publicStatus(snapshot).title,
            "Customer availability is temporarily interrupted"
        )
    }

    func testBuyerServingHoldClearsOnStatusInvalidation() {
        var snapshot = buyerServingObservationSnapshot(observedAt: Date())
        snapshot.updateBuyerServingHold()
        XCTAssertNotNil(snapshot.lastBuyerServingAt)
        XCTAssertTrue(AgentSnapshotPresenter.isNetworkReady(snapshot))

        snapshot.invalidateLocalStatusObservation()

        XCTAssertNil(snapshot.lastBuyerServingAt)
        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot))
        XCTAssertNotEqual(AgentSnapshotPresenter.publicStatus(snapshot).title, "Provider is ready")
    }

    func testBuyerServingHoldRequiresCurrentObservation() {
        var snapshot = buyerServingObservationSnapshot(
            observedAt: Date().addingTimeInterval(
                -(LocalStatusObservationPolicy.displayRetentionSeconds + 1)
            )
        )
        snapshot.lastBuyerServingAt = Date().addingTimeInterval(-30)
        snapshot.networkState = "live_verified"

        XCTAssertFalse(snapshot.isLocalStatusObservationCurrent())
        XCTAssertFalse(snapshot.isHoldingBuyerServingReady())
        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot))
    }

    func testPublicStatusDistinguishesHardwareVerificationFromGenericReconnect() {
        var pending = AgentSnapshot.empty
        pending.state = .reconnecting
        pending.currentModelID = "llama"
        pending.networkState = "live_verified"
        pending.lifecycleState = "coordinator_unavailable"
        pending.lifecycleReason = "autotune_evidence_required"

        let pendingStatus = AgentSnapshotPresenter.publicStatus(pending)
        XCTAssertEqual(pendingStatus.title, "Pending hardware verification")
        XCTAssertEqual(
            pendingStatus.safeNextAction,
            "Keep Malibu online · retry setup if this lasts more than an hour."
        )
        XCTAssertEqual(pendingStatus.executableAction, .retryHardwareVerification)
        XCTAssertFalse(pendingStatus.safeNextAction?.contains("macprovider-cli") == true)
        XCTAssertTrue(pendingStatus.detail?.contains("usually under an hour") == true)
        XCTAssertFalse(pendingStatus.detail?.contains("wait for operator approval") == true)
        XCTAssertEqual(AgentSnapshotPresenter.short(pending), "Pending")
        XCTAssertEqual(AgentSnapshotPresenter.modelLine(pending), "llama")
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(pending),
            "Pending hardware verification · Usually under an hour · keep online"
        )

        var rejected = AgentSnapshot.empty
        rejected.state = .reconnecting
        rejected.currentModelID = "llama"
        rejected.lifecycleState = "catalog_incompatible"
        rejected.lifecycleReason = "autotune_evidence_invalid"

        let rejectedStatus = AgentSnapshotPresenter.publicStatus(rejected)
        XCTAssertEqual(rejectedStatus.title, "Not eligible: admission evidence failed")
        XCTAssertEqual(rejectedStatus.safeNextAction, "Retry provider setup while online.")
        XCTAssertEqual(rejectedStatus.executableAction, .retryHardwareVerification)
        XCTAssertFalse(rejectedStatus.safeNextAction?.contains("macprovider-cli") == true)
        XCTAssertEqual(AgentSnapshotPresenter.short(rejected), "Ineligible")
        XCTAssertEqual(AgentSnapshotPresenter.stateLine(rejected), "Not eligible: admission evidence failed")
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(rejected),
            "Not eligible: admission evidence failed · Retry provider setup while online"
        )

        var binaryMismatch = rejected
        binaryMismatch.lifecycleReason = "autotune_evidence_binary_version_mismatch"
        XCTAssertEqual(
            AgentSnapshotPresenter.publicStatus(binaryMismatch).title,
            "Not eligible: admission evidence failed"
        )
        XCTAssertEqual(AgentSnapshotPresenter.short(binaryMismatch), "Ineligible")

        var uncatalogued = AgentSnapshot.empty
        uncatalogued.state = .reconnecting
        uncatalogued.currentModelID = "llama"
        uncatalogued.lifecycleState = "catalog_incompatible"
        uncatalogued.lifecycleReason = "autotune_model_uncatalogued"
        let uncataloguedStatus = AgentSnapshotPresenter.publicStatus(uncatalogued)
        XCTAssertEqual(uncataloguedStatus.title, "This Mac is not currently eligible")
        XCTAssertEqual(uncataloguedStatus.safeNextAction, "Retry provider setup while online.")
        XCTAssertEqual(uncataloguedStatus.executableAction, .retryHardwareVerification)
        XCTAssertTrue(uncataloguedStatus.detail?.contains("supported model") == true)
        XCTAssertEqual(AgentSnapshotPresenter.stateLine(uncatalogued), "This Mac is not currently eligible")
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(uncatalogued),
            "This Mac is not currently eligible · Retry setup to apply a supported model"
        )

        var capExceeded = AgentSnapshot.empty
        capExceeded.state = .reconnecting
        capExceeded.lifecycleState = "catalog_incompatible"
        capExceeded.lifecycleReason = "autotune_model_cap_exceeded"
        let capStatus = AgentSnapshotPresenter.publicStatus(capExceeded)
        XCTAssertEqual(capStatus.executableAction, .retryHardwareVerification)
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(capExceeded),
            "Not eligible: admission evidence failed · Retry setup to apply a smaller admitted model"
        )
    }

    func testBlockedPublicStatesExposeExactlyOneSafeAction() {
        let snapshots: [AgentSnapshot] = [
            {
                var s = AgentSnapshot.empty
                s.state = .reconnecting
                s.currentModelID = "llama"
                s.networkState = "live_verified"
                return s
            }(),
            {
                var s = AgentSnapshot.empty
                s.state = .reconnecting
                s.currentModelID = "llama"
                s.networkState = "not_buyer_serving"
                return s
            }(),
            {
                var s = AgentSnapshot.empty
                s.state = .starting
                s.lifecycleState = "loading_model"
                return s
            }(),
        ]

        for snapshot in snapshots {
            let action = AgentSnapshotPresenter.publicStatus(snapshot).safeNextAction
            XCTAssertEqual([action].compactMap { $0 }.count, 1)
        }
    }

    func testPausedPublicStateTakesPrecedenceOverPreparingFallback() {
        var withoutModel = AgentSnapshot.empty
        withoutModel.state = .paused
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(withoutModel).title, "Provider is paused")
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(withoutModel).safeNextAction, "Choose Resume when ready.")

        var withModel = AgentSnapshot.empty
        withModel.state = .paused
        withModel.currentModelID = "llama"
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(withModel).title, "Provider is paused")
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(withModel).safeNextAction, "Choose Resume when ready.")
    }

    func testPublicStatusDoesNotTreatMissingNetworkStateAsApproval() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "llama"
        snapshot.networkState = nil

        let status = AgentSnapshotPresenter.publicStatus(snapshot)
        XCTAssertEqual(status.title, "Checking customer availability")
        XCTAssertEqual(status.safeNextAction, "Keep Malibu open while status updates.")
    }

    func testStaleBuyerServingUnknownDoesNotClaimNetworkApproval() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "llama"
        snapshot.networkState = "buyer_serving_unknown"
        snapshot.statusObservationFresh = false

        let status = AgentSnapshotPresenter.publicStatus(snapshot)
        XCTAssertEqual(status.title, "Checking customer availability")
        XCTAssertEqual(status.safeNextAction, "Keep Malibu open while status updates.")
    }

    func testOptionalLatestReleaseDoesNotMakeProviderIneligible() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "llama"
        snapshot.networkState = nil
        snapshot.cliVersion = "1.8.40"
        snapshot.latestReleaseVersion = "1.8.41"

        let status = AgentSnapshotPresenter.publicStatus(snapshot)
        XCTAssertEqual(status.title, "Checking customer availability")
        XCTAssertEqual(status.safeNextAction, "Keep Malibu open while status updates.")
        XCTAssertNotEqual(status.title, "This Mac is not currently eligible")
    }

    func testFailedReadinessRefreshInvalidatesPriorServingVerdict() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"

        snapshot.markCoordinatorReadinessUnknown()

        XCTAssertEqual(snapshot.networkState, "buyer_serving_unknown")
        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot))
    }

    func testShortShowsReconnectWhenLocalOnly() {
        var s = AgentSnapshot.empty
        s.state = .reconnecting
        s.coordinatorConnected = false
        s.currentModelID = "model-a"
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "Reconnect")
    }

    func testShortShowsReconnectWhenReconnecting() {
        var s = AgentSnapshot.empty
        s.state = .reconnecting
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "Reconnect")
    }

    func testShortShowsFormattedDollarsWhenPopulated() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.earningsUsdcToday = 12.34
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "$12.34")
    }

    func testStateLineIncludesLastErrorOnError() {
        var s = AgentSnapshot.empty
        s.state = .error
        s.lastError = "boom"
        XCTAssertEqual(
            AgentSnapshotPresenter.stateLine(s),
            "Details are available in Advanced diagnostics."
        )
    }

    func testProvisionalMalibuIsRenderedLocked() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.earningsUsdcToday = 1
        s.malibuAccruedToday = 2
        s.trustTier = .provisional
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = true
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )
        XCTAssertTrue(AgentSnapshotPresenter.earningsLine(s).contains("[locked] 2.00 MALIBU"))
        XCTAssertFalse(AgentSnapshotPresenter.earningsLine(s).contains("unlocks at Trusted"))
    }

    func testBacklogLineOnlyWhenWalletUnbound() {
        var s = AgentSnapshot.empty
        s.unpaidLedgerBacklogUSDC = 10
        s.unpaidLedgerBacklogMALIBU = 5
        s.walletBound = false
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = true
        XCTAssertNotNil(AgentSnapshotPresenter.backlogLine(s))
        s.walletBound = true
        XCTAssertNil(AgentSnapshotPresenter.backlogLine(s))
    }

    func testCredentialConditionTableUsesPreciseRecoveryGuidance() {
        let cases: [(state: String, action: String, expected: String, repairable: Bool)] = [
            ("ready", "none", "safe after restart", false),
            ("missing", "repair_from_protected_source", "recovery available", true),
            ("locked", "unlock_keychain", "unlock and retry", false),
            ("not_logged_in", "login", "sign in and retry", false),
            ("permission_denied", "authorize_keychain", "access denied", false),
            ("corrupt", "repair_from_protected_source", "recovery available", true),
            ("conflict", "restore_or_reenroll", "automatic repair refused", false),
            ("keychain_failure", "repair_keychain", "database failure", false),
            ("incompatible", "update_or_reinstall", "update or reinstall", false),
            ("unavailable", "retry", "unavailable", false),
        ]

        for item in cases {
            var snapshot = AgentSnapshot.empty
            snapshot.credentialState = item.state
            snapshot.credentialRecoveryAction = item.action
            snapshot.credentialRestartSafe = item.state == "ready"
            XCTAssertTrue(
                AgentSnapshotPresenter.credentialLine(snapshot).localizedCaseInsensitiveContains(item.expected),
                "unexpected presentation for \(item.state)"
            )
            XCTAssertEqual(AgentSnapshotPresenter.canRepairCredential(snapshot), item.repairable)
        }
    }

    func testAdmissionIdentityDistinguishesProofFromExemption() {
        var snapshot = AgentSnapshot.empty
        snapshot.admissionIdentityState = "ready"

        snapshot.coordinatorIdentityAdmissionMode = "signature"
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityLine(snapshot),
            "Ready · verified by this Mac"
        )

        snapshot.coordinatorIdentityAdmissionMode = "exemption"
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityLine(snapshot),
            "Ready locally · temporary network approval active"
        )
    }

    func testAdmissionIdentityRecoveryShowsCandidateAndOperatorAction() {
        var snapshot = AgentSnapshot.empty
        snapshot.admissionIdentityState = "recovery_pending"
        snapshot.admissionIdentityPendingPublicKeySHA256 = String(repeating: "a", count: 64)

        let line = AgentSnapshotPresenter.admissionIdentityLine(snapshot)
        XCTAssertTrue(line.contains("Approval required"), line)
        XCTAssertTrue(line.contains("aaaaaaaaaaaa…"), line)
        XCTAssertTrue(line.contains("activate in Malibu"), line)
        XCTAssertTrue(AgentSnapshotPresenter.canRepairAdmissionIdentity(snapshot))
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityRepairButtonTitle(snapshot),
            "Activate approved verification"
        )
    }

    func testAdmissionIdentityRepairStagesWithoutTerminalAndExplainsApprovalGate() {
        var snapshot = AgentSnapshot.empty
        snapshot.admissionIdentityState = "degraded_previous_key"
        snapshot.localStatusCapabilities = []
        XCTAssertTrue(AgentSnapshotPresenter.canRepairAdmissionIdentity(snapshot))
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityRepairButtonTitle(snapshot),
            "Repair network verification"
        )

        snapshot.admissionIdentityRecoveryApprovalInstruction = "distinct second operator approval required"
        snapshot.admissionIdentityRecoveryJournalState = "approval_required"
        snapshot.statusObservationFresh = false
        XCTAssertTrue(AgentSnapshotPresenter.canRepairAdmissionIdentity(snapshot))
        XCTAssertTrue(
            AgentSnapshotPresenter.admissionIdentityLine(snapshot).contains("Approval required"),
            "the signed CLI-owned journal remains actionable while local HTTP status is unavailable"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityRepairButtonTitle(snapshot),
            "Activate approved verification"
        )
    }

    func testDurableRecoveryStatusRehydratesFreshAppSnapshot() throws {
        let candidate = String(repeating: "d", count: 64)
        let data = try JSONSerialization.data(withJSONObject: [
            "contract_version": 1,
            "operation": "admission_identity_recovery_status",
            "provider_id": "provider-a",
            "state": "approval_required",
            "candidate_public_key_sha256": candidate,
            "restart_safe": true,
            "admin_request": [
                "method": "POST",
                "path": "/admin/provider-admission-identity/recover",
                "body": [
                    "provider_id": "provider-a",
                    "candidate_public_key_sha256": candidate,
                    "requested_until": "2026-07-14T13:00:00Z",
                    "reason": "Malibu admission identity recovery",
                    "incident_id": "incident-585",
                ],
                "approval_path_template": "/admin/provider-admission-identity/recover/{pending_id}/approve",
            ],
        ])
        let recovery = try JSONDecoder().decode(
            ProviderCredentialHandoffRunner.AdmissionRecoverySnapshot.self,
            from: data
        )
        var snapshot = AgentSnapshot.empty
        snapshot.localProviderID = "provider-a"
        snapshot.statusObservationFresh = true
        snapshot.applyAdmissionIdentityRecoveryJournal(recovery)

        XCTAssertEqual(snapshot.admissionIdentityRecoveryJournalState, "approval_required")
        XCTAssertEqual(snapshot.admissionIdentityPendingPublicKeySHA256, candidate)
        XCTAssertTrue(try XCTUnwrap(snapshot.admissionIdentityRecoveryOperatorRequest).contains("incident-585"))
        XCTAssertTrue(AgentSnapshotPresenter.canRepairAdmissionIdentity(snapshot))
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityRepairButtonTitle(snapshot),
            "Activate approved verification"
        )
    }

    func testAdmissionIdentityRecoveryConfigMismatchIsActionable() {
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityRecoveryConfigError(
                expectedProviderID: "provider-a",
                configuredProviderID: "provider-b"
            ),
            "Network verification repair refused because config provider_id provider-b does not match the active provider provider-a."
        )
        XCTAssertNotNil(AgentSnapshotPresenter.admissionIdentityRecoveryConfigError(
            expectedProviderID: "provider-a",
            configuredProviderID: nil
        ))
    }

    func testAdmissionIdentityPreviousKeyShowsGraceDeadline() {
        var snapshot = AgentSnapshot.empty
        snapshot.admissionIdentityState = "degraded_previous_key"
        snapshot.admissionIdentityPreviousValidUntil = ISO8601DateFormatter().date(
            from: "2026-07-21T12:00:00Z"
        )

        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityLine(snapshot),
            "Using previous verification until 2026-07-21T12:00:00Z · repair network verification"
        )
    }

    func testStatusContractAndLifecycleExposeCLIAuthoredInstance() {
        var snapshot = AgentSnapshot.empty
        snapshot.localStatusContractVersion = 1
        snapshot.localStatusContractCompatible = true
        snapshot.localStatusLifecycleOwner = "macprovider_cli"
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "observation-a"
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        snapshot.serviceInstanceID = "abcdef0123456789"
        snapshot.servicePID = 4321
        snapshot.serviceRole = "serve"
        snapshot.lifecycleState = "busy"
        snapshot.lifecycleReason = "request_capacity_full"

        XCTAssertEqual(AgentSnapshotPresenter.statusContractLine(snapshot), "v1 · macprovider_cli")
        XCTAssertEqual(AgentSnapshotPresenter.serviceInstanceLine(snapshot), "serve · PID 4321 · abcdef01")
        XCTAssertEqual(AgentSnapshotPresenter.lifecycleLine(snapshot), "busy · request capacity full")

        snapshot.lifecycleLeaseState = "active"
        snapshot.admissionIdentityPreviousValidUntil = Date()
        snapshot.lifecycleLeaseKind = "maintenance"
        snapshot.lifecycleLeaseOperationID = "provider repair"
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(snapshot),
            "Update or repair in progress · provider repair"
        )

        snapshot.lifecycleLeaseState = "invalid"
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(snapshot),
            "Provider recovery status needs a restart"
        )

        snapshot.lifecycleLeaseState = nil
        snapshot.lifecycleRecordState = "missing"
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(snapshot),
            "Provider history missing · restart required"
        )
        snapshot.lifecycleRecordState = "invalid"
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(snapshot),
            "Provider history invalid · restart required"
        )

        snapshot.localStatusContractCompatible = false
        XCTAssertEqual(AgentSnapshotPresenter.statusContractLine(snapshot), "Incompatible · update Malibu")

        snapshot.localStatusContractCompatible = true
        snapshot.statusObservationFresh = false
        XCTAssertEqual(AgentSnapshotPresenter.statusContractLine(snapshot), "Compatible · checking again")
    }

    func testCompatibilitySetLineDistinguishesSignedAndLegacyReleases() {
        var snapshot = AgentSnapshot.empty
        XCTAssertEqual(
            AgentSnapshotPresenter.compatibilitySetLine(snapshot),
            "Status not reported"
        )

        snapshot.cliVersion = "1.9.0"
        snapshot.compatibilitySetID = "Augustas11/macprovider:v1.9.0@0123456789abcdef0123456789abcdef01234567"
        snapshot.compatibilitySetSHA256 = String(repeating: "a", count: 64)
        snapshot.catalogReleaseID = "published-2026-07-14"
        XCTAssertEqual(
            AgentSnapshotPresenter.compatibilitySetLine(snapshot),
            "v1.9.0 · up to date"
        )
    }

    func testLifecycleStatesUsePlainLanguageAndSafeNextActions() {
        var snapshot = AgentSnapshot.empty
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "observation-a"
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        snapshot.lifecycleState = "catalog_incompatible"
        snapshot.lifecycleReason = "startup_catalog_incompatible"

        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(snapshot),
            "Provider software update required · startup catalog incompatible · Install latest provider software, then retry"
        )

        snapshot.lifecycleState = "watchdog_recovery"
        snapshot.lifecycleReason = "watchdog_rollback_post_start_rejoin_timeout"
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(snapshot),
            "Provider recovery · provider recovery rollback post start rejoin timeout · No action required while this completes"
        )
    }

    func testSignificantLifecycleReasonAndAdvertisedCapacityAreOperatorReadable() {
        var snapshot = AgentSnapshot.empty
        snapshot.networkState = "buyer_serving"
        snapshot.advertisedMaxConcurrency = 8
        let event = ProviderLifecycleEventSnapshot(
            sequence: 9,
            transitionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            transitionAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: "watchdog_recovery",
            reason: "watchdog_rollback_post_start_rejoin_timeout",
            writer: "watchdog",
            compatibilitySetID: "set-1",
            operationID: "watchdog-recovery:update-1"
        )

        XCTAssertEqual(
            AgentSnapshotPresenter.advertisedCapacityLine(snapshot),
            "8 buyer slots · available to customers"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleEventLine(event),
            "provider recovery rollback post start rejoin timeout · Provider recovery"
        )
    }

    func testLaunchdRestartCopyIsOperatorReadable() {
        let event = ProviderLifecycleEventSnapshot(
            sequence: 1,
            transitionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            transitionAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: "starting_provider",
            reason: "launchd_service_started",
            writer: "serve",
            compatibilitySetID: nil,
            operationID: nil
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleEventLine(event),
            "Provider service started · Starting provider"
        )
        XCTAssertTrue(AgentSnapshotPresenter.lifecycleEventDisplay(event).hasPrefix(
            "Provider service started · Starting provider · "
        ))
    }

    func testObservationLeaseShorterThanPollCadenceKeepsBuyerServingStable() {
        // CLI valid_for_ms is 5s; Malibu polls ~15s. Public status must remain
        // Serving across that gap while the same healthy observation is retained.
        let ages: [TimeInterval] = [0, 4.9, 6, 14.9, 19.9]
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        for age in ages {
            let observedAt = origin
            let now = origin.addingTimeInterval(age)
            let snapshot = buyerServingObservationSnapshot(observedAt: observedAt)
            XCTAssertTrue(
                snapshot.isLocalStatusObservationCurrent(at: now),
                "observation should remain current at age \(age)s"
            )
            XCTAssertTrue(AgentSnapshotPresenter.isNetworkReady(snapshot, at: now))
            XCTAssertEqual(AgentSnapshotPresenter.short(snapshot, at: now), "Serving")
        }
    }

    func testTenHealthyPollCyclesRemainServingAcrossUnrelatedMetricsPhases() {
        // Simulate Malibu's 15s refresh cadence with a 5s CLI lease for ≥10 cycles.
        // Between polls, only wall-clock advances (unrelated metrics/UI ticks).
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        for cycle in 0..<10 {
            let observedAt = origin.addingTimeInterval(Double(cycle) * LocalStatusObservationPolicy.pollIntervalSeconds)
            let snapshot = buyerServingObservationSnapshot(observedAt: observedAt)
            let justAfterPoll = observedAt.addingTimeInterval(0.5)
            let beforeNextPoll = observedAt.addingTimeInterval(
                LocalStatusObservationPolicy.pollIntervalSeconds - 0.1
            )
            XCTAssertEqual(
                AgentSnapshotPresenter.short(snapshot, at: justAfterPoll),
                "Serving",
                "cycle \(cycle) just after poll"
            )
            XCTAssertEqual(
                AgentSnapshotPresenter.short(snapshot, at: beforeNextPoll),
                "Serving",
                "cycle \(cycle) before next poll"
            )
            XCTAssertTrue(AgentSnapshotPresenter.isNetworkReady(snapshot, at: beforeNextPoll))
        }

        // Without a refresh after the final observation, retention expiry demotes.
        let lastObserved = origin.addingTimeInterval(9 * LocalStatusObservationPolicy.pollIntervalSeconds)
        let expired = lastObserved.addingTimeInterval(
            LocalStatusObservationPolicy.displayRetentionSeconds + 0.1
        )
        let stale = buyerServingObservationSnapshot(observedAt: lastObserved)
        XCTAssertEqual(AgentSnapshotPresenter.short(stale, at: expired), "Connected")
    }

    func testObservationRetentionExpiryEventuallyDemotesPublicServing() {
        let snapshot = buyerServingObservationSnapshot(
            observedAt: Date().addingTimeInterval(
                -(LocalStatusObservationPolicy.displayRetentionSeconds + 1)
            )
        )

        XCTAssertFalse(snapshot.isLocalStatusObservationCurrent())
        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot))
        XCTAssertEqual(AgentSnapshotPresenter.short(snapshot), "Connected")
        XCTAssertEqual(
            AgentSnapshotPresenter.statusContractLine(snapshot),
            "Compatible · checking again"
        )
    }

    func testHardObservationInvalidationDemotesImmediately() {
        var snapshot = buyerServingObservationSnapshot(observedAt: Date())
        XCTAssertTrue(AgentSnapshotPresenter.isNetworkReady(snapshot))

        snapshot.invalidateLocalStatusObservation()

        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot))
        XCTAssertEqual(snapshot.networkState, "buyer_serving_unknown")
        XCTAssertEqual(AgentSnapshotPresenter.short(snapshot), "Connected")
    }

    func testAuthoritativeNotBuyerServingDemotesEvenWithinRetention() {
        var snapshot = buyerServingObservationSnapshot(
            observedAt: Date().addingTimeInterval(-6)
        )
        snapshot.networkState = "not_buyer_serving"

        XCTAssertTrue(snapshot.isLocalStatusObservationCurrent())
        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot))
        XCTAssertEqual(
            AgentSnapshotPresenter.publicStatus(snapshot).title,
            "Customer availability is temporarily interrupted"
        )
    }

    func testDisplayRetentionStrictlyExceedsSharedPollInterval() {
        XCTAssertEqual(LocalStatusObservationPolicy.pollIntervalSeconds, 15)
        XCTAssertGreaterThan(
            LocalStatusObservationPolicy.displayRetentionSeconds,
            LocalStatusObservationPolicy.pollIntervalSeconds
        )
        XCTAssertEqual(
            LocalStatusObservationPolicy.pollIntervalNanoseconds,
            UInt64(LocalStatusObservationPolicy.pollIntervalSeconds * 1_000_000_000)
        )
    }

    @MainActor
    func testObservationExpiryDiagnosticEmitsOnPresentedServingToConnectedTransition() {
        PublicStatusTransitionDiagnostics.resetForTests()
        let fresh = buyerServingObservationSnapshot(observedAt: Date())
        XCTAssertFalse(PublicStatusTransitionDiagnostics.notePresentedSnapshot(fresh))
        XCTAssertEqual(AgentSnapshotPresenter.short(fresh), "Serving")

        let expired = buyerServingObservationSnapshot(
            observedAt: Date().addingTimeInterval(
                -(LocalStatusObservationPolicy.displayRetentionSeconds + 1)
            )
        )
        XCTAssertEqual(AgentSnapshotPresenter.short(expired), "Connected")
        XCTAssertTrue(PublicStatusTransitionDiagnostics.notePresentedSnapshot(expired))
        // Rate-limited: immediate repeat must not emit again.
        XCTAssertFalse(PublicStatusTransitionDiagnostics.notePresentedSnapshot(expired))
    }

    func testHardFailuresDemoteEvenWhenObservationWouldStillBeWithinRetention() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = buyerServingObservationSnapshot(observedAt: now.addingTimeInterval(-1))
        XCTAssertTrue(AgentSnapshotPresenter.isNetworkReady(snapshot, at: now))

        // Failed refresh / provider exit / service-identity mismatch all call
        // invalidateLocalStatusObservation() before reconcile (MalibuAgent).
        snapshot.invalidateLocalStatusObservation()
        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot, at: now))
        XCTAssertEqual(AgentSnapshotPresenter.short(snapshot, at: now), "Connected")

        snapshot = buyerServingObservationSnapshot(observedAt: now.addingTimeInterval(-1))
        snapshot.networkState = "not_buyer_serving"
        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot, at: now))
        XCTAssertEqual(
            AgentSnapshotPresenter.publicStatus(snapshot).title,
            "Customer availability is temporarily interrupted"
        )

        // Coordinator disconnect while still within retention: authoritative
        // network state leaves buyer_serving.
        snapshot = buyerServingObservationSnapshot(observedAt: now.addingTimeInterval(-1))
        snapshot.coordinatorConnected = false
        snapshot.networkState = "live_verified"
        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot, at: now))
        XCTAssertEqual(AgentSnapshotPresenter.short(snapshot, at: now), "Connected")

        // Service-instance change arrives as a fresh observation with a new ID;
        // same buyer_serving verdict stays Serving (identity mismatch would have
        // invalidated instead of applying the new observation).
        snapshot = buyerServingObservationSnapshot(observedAt: now)
        snapshot.serviceInstanceID = "instance-b"
        XCTAssertEqual(AgentSnapshotPresenter.short(snapshot, at: now.addingTimeInterval(1)), "Serving")
    }

    func testObservationExpiryBetweenPollsSuppressesServingRepairAndLifecycle() {
        // Past the display retention floor (poll interval + margin), observation
        // expiry still fail-closes repair/lifecycle surfaces.
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "observation-a"
        snapshot.statusObservedAt = Date().addingTimeInterval(
            -(LocalStatusObservationPolicy.displayRetentionSeconds + 1)
        )
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        snapshot.networkState = "buyer_serving"
        snapshot.serviceInstanceID = "instance-a"
        snapshot.lifecycleState = "ready"
        snapshot.credentialState = "missing"
        snapshot.credentialRecoveryAction = "repair_from_protected_source"

        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(snapshot))
        XCTAssertFalse(AgentSnapshotPresenter.canRepairCredential(snapshot))
        XCTAssertNil(AgentSnapshotPresenter.serviceInstanceLine(snapshot))
        XCTAssertNil(AgentSnapshotPresenter.lifecycleLine(snapshot))
        XCTAssertEqual(AgentSnapshotPresenter.statusContractLine(snapshot), "Compatible · checking again")
    }

    func testCredentialDiagnosticRejectsFutureTimestamp() {
        var snapshot = AgentSnapshot.empty
        snapshot.credentialState = "ready"
        snapshot.credentialStatusFromDiagnostic = true
        snapshot.credentialStatusObservedAt = Date(timeIntervalSince1970: 120)

        XCTAssertFalse(snapshot.isCredentialStatusCurrent(at: Date(timeIntervalSince1970: 100)))
    }

    func testFailedRefreshClearsEveryObservationBoundField() {
        var snapshot = AgentSnapshot.empty
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationFresh = true
        snapshot.serviceInstanceID = "instance-a"
        snapshot.lifecycleState = "ready"
        snapshot.credentialState = "missing"
        snapshot.credentialRecoveryAction = "repair_from_protected_source"
        snapshot.coordinatorConnected = true
        snapshot.networkState = "buyer_serving"
        snapshot.catalogState = "live_verified"
        snapshot.compatibilitySetID = "set-a"
        snapshot.compatibilitySetSHA256 = String(repeating: "a", count: 64)
        snapshot.lifecycleLeaseState = "active"

        snapshot.invalidateLocalStatusObservation()

        XCTAssertEqual(snapshot.statusObservationFresh, false)
        XCTAssertNil(snapshot.serviceInstanceID)
        XCTAssertNil(snapshot.lifecycleState)
        XCTAssertNil(snapshot.credentialState)
        XCTAssertNil(snapshot.credentialRecoveryAction)
        XCTAssertNil(snapshot.coordinatorConnected)
        XCTAssertEqual(snapshot.networkState, "buyer_serving_unknown")
        XCTAssertNil(snapshot.catalogState)
        XCTAssertNil(snapshot.compatibilitySetID)
        XCTAssertNil(snapshot.compatibilitySetSHA256)
        XCTAssertNil(snapshot.lifecycleLeaseState)
        XCTAssertNil(snapshot.admissionIdentityPreviousValidUntil)
    }

    func testUnclaimedBadgeThresholdsResurfaceAfterDismissal() {
        var s = AgentSnapshot.empty
        s.walletBound = false
        s.unpaidLedgerBacklogUSDC = 9
        s.unpaidLedgerBacklogMALIBU = 0
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = true
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
          "unpaid_ledger_backlog_malibu": 7.25,
          "malibu_withdrawable": 3.5,
          "malibu_held": 0.5,
          "malibu_hold_reasons": ["per_wallet_daily_cap"],
          "malibu_daily_cap": 25,
          "malibu_wallet_daily_cap": 100,
          "malibu_reward_eligibility": {
            "schema_version": "malibu_reward_eligibility.v1",
            "earning_state": "capped",
            "withdrawal_state": "capped",
            "primary_reason": "held_wallet_daily_cap",
            "reasons": ["held_wallet_daily_cap"]
          }
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(ProviderEarnings.self, from: data)
        XCTAssertFalse(decoded.walletBound)
        XCTAssertEqual(decoded.trustTier, .trusted)
        XCTAssertEqual(decoded.unpaidLedgerBacklogUSDC, 12.5)
        XCTAssertEqual(decoded.unpaidLedgerBacklogMALIBU, 7.25)
        XCTAssertEqual(decoded.malibuWithdrawable, 3.5)
        XCTAssertEqual(decoded.malibuHeld, 0.5)
        XCTAssertEqual(decoded.malibuHoldReasons, ["per_wallet_daily_cap"])
        XCTAssertEqual(decoded.malibuDailyCap, 25)
        XCTAssertEqual(decoded.malibuWalletDailyCap, 100)
        XCTAssertEqual(decoded.malibuRewardEligibility?.primaryReason, "held_wallet_daily_cap")
        XCTAssertFalse(decoded.malibuProjectionFresh)
        XCTAssertFalse(decoded.earningsProjectionFresh)
    }

    func testProviderEarningsAcceptsProviderDailyCapRewardReason() throws {
        let data = Data("""
        {
          "wallet_bound": true,
          "trust_tier": "trusted",
          "unpaid_ledger_backlog_usdc": 0,
          "unpaid_ledger_backlog_malibu": 4,
          "malibu_withdrawable": 0,
          "malibu_held": 4,
          "malibu_projection_fresh": true,
          "malibu_reward_eligibility": {
            "schema_version": "malibu_reward_eligibility.v1",
            "earning_state": "capped",
            "withdrawal_state": "capped",
            "primary_reason": "held_provider_daily_cap",
            "reasons": ["held_provider_daily_cap"]
          }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ProviderEarnings.self, from: data)
        XCTAssertEqual(decoded.malibuRewardEligibility?.earningState, "capped")
        XCTAssertEqual(decoded.malibuRewardEligibility?.withdrawalState, "capped")
        XCTAssertEqual(decoded.malibuRewardEligibility?.primaryReason, "held_provider_daily_cap")
        XCTAssertEqual(decoded.malibuRewardEligibility?.reasons, ["held_provider_daily_cap"])
    }

    func testMalibuAvailabilityAndHoldCopyExplainWithdrawalState() {
        var snapshot = AgentSnapshot.empty
        snapshot.trustTier = .provisional
        snapshot.providerEarningsFresh = true
        snapshot.malibuProjectionFresh = true
        snapshot.malibuWithdrawable = 0
        snapshot.malibuHeld = 12.5
        snapshot.malibuHoldReasons = ["trust_tier_provisional"]
        snapshot.trustCriteriaMet = 2
        snapshot.trustCriteriaRequired = 4
        snapshot.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )

        XCTAssertEqual(AgentSnapshotPresenter.malibuAvailabilityLine(snapshot), "MALIBU: not withdrawable · 12.50 held")
        XCTAssertEqual(
            AgentSnapshotPresenter.malibuHoldLine(snapshot),
            "MALIBU status: Trust verification is incomplete. Next: Complete the remaining trust criteria to unlock withdrawals."
        )

        snapshot.malibuHoldReasons = ["per_wallet_daily_cap"]
        snapshot.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "capped",
            withdrawalState: "capped",
            primaryReason: "held_wallet_daily_cap",
            reasons: ["held_wallet_daily_cap"]
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.malibuHoldLine(snapshot),
            "MALIBU status: wallet daily limit reached. Next: The wallet cap resets at the next UTC day."
        )

        snapshot.malibuHoldReasons = []
        snapshot.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "capped",
            withdrawalState: "capped",
            primaryReason: "held_provider_daily_cap",
            reasons: ["held_provider_daily_cap"]
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.malibuHoldLine(snapshot),
            "MALIBU status: provider daily limit reached. Next: The provider cap resets at the next UTC day."
        )

        snapshot.trustTier = .provisional
        snapshot.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_demotion_cooldown",
            reasons: ["held_demotion_cooldown"]
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.malibuHoldLine(snapshot),
            "MALIBU status: Trust verification is in progress. Next: Keep Malibu online; withdrawals unlock automatically when Trusted."
        )
    }

    func testRewardEligibilityV1OverridesLegacyMalibuPresentation() {
        var snapshot = AgentSnapshot.empty
        snapshot.trustTier = .trusted
        snapshot.providerEarningsFresh = true
        snapshot.malibuProjectionFresh = true
        snapshot.malibuAccruedToday = 2
        snapshot.malibuAccruedAllTime = 2
        snapshot.malibuWithdrawable = 2
        snapshot.malibuHeld = 0
        snapshot.malibuHoldReasons = []
        snapshot.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )

        XCTAssertNil(AgentSnapshotPresenter.eligibilityLine(snapshot))
        XCTAssertEqual(
            AgentSnapshotPresenter.malibuAvailabilityLine(snapshot),
            "MALIBU: 2.00 available · 0.00 held"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.malibuFullLine(snapshot),
            "2.00 MALIBU · 2.00 all-time"
        )
        XCTAssertNil(AgentSnapshotPresenter.malibuHoldLine(snapshot))
    }

    func testTrustedSnapshotIgnoresLeftoverProvisionalHoldCopy() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.trustTier = .trusted
        snapshot.providerEarningsFresh = true
        snapshot.malibuProjectionFresh = true
        snapshot.walletBound = true
        snapshot.malibuAccruedToday = 2
        snapshot.malibuAccruedAllTime = 2
        snapshot.malibuWithdrawable = 2
        snapshot.malibuHeld = 12.5
        snapshot.malibuHoldReasons = ["trust_tier_provisional", "demotion_cooldown"]
        snapshot.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )

        let health = AgentSnapshotPresenter.miningHealth(snapshot)
        XCTAssertNotEqual(health.reasonCode, "trust_tier_provisional")
        XCTAssertNotEqual(health.reasonCode, "rewards_held")
        XCTAssertFalse(health.status.contains("Locked"))
        XCTAssertFalse(health.status.contains("Rewards held"))
        XCTAssertNil(AgentSnapshotPresenter.malibuHoldLine(snapshot))
        XCTAssertNotEqual(
            AgentSnapshotPresenter.eligibilityLine(snapshot),
            "MALIBU is locked until Trusted"
        )
        XCTAssertFalse(AgentSnapshotPresenter.malibuFullLine(snapshot).contains("locked"))
        XCTAssertFalse(AgentSnapshotPresenter.malibuFullLine(snapshot).contains("Locked"))
        XCTAssertFalse(
            (AgentSnapshotPresenter.malibuHoldLine(snapshot) ?? "")
                .contains("Trust verification is incomplete")
        )
    }

    func testRewardEligibilityUsesFreshMalibuProjectionWithoutFreshUSDCProjection() {
        var snapshot = AgentSnapshot.empty
        snapshot.trustTier = .trusted
        snapshot.providerEarningsFresh = false
        snapshot.malibuProjectionFresh = true
        snapshot.malibuAccruedToday = 2
        snapshot.malibuAccruedAllTime = 2
        snapshot.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )

        XCTAssertNil(AgentSnapshotPresenter.eligibilityLine(snapshot))
        XCTAssertEqual(
            AgentSnapshotPresenter.malibuFullLine(snapshot),
            "2.00 MALIBU · 2.00 all-time"
        )
    }

    func testProviderEarningsUnknownRewardEligibilityNormalizesUnavailable() throws {
        let data = Data("""
        {
          "wallet_bound": true,
          "trust_tier": "trusted",
          "unpaid_ledger_backlog_usdc": 0,
          "unpaid_ledger_backlog_malibu": 0,
          "malibu_reward_eligibility": {
            "schema_version": "malibu_reward_eligibility.v1",
            "earning_state": "earning",
            "withdrawal_state": "withdrawable",
            "primary_reason": "future_reason",
            "reasons": ["future_reason"]
          }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ProviderEarnings.self, from: data)
        XCTAssertEqual(decoded.malibuRewardEligibility?.schemaVersion, "malibu_reward_eligibility.v1")
        XCTAssertEqual(decoded.malibuRewardEligibility?.earningState, "unavailable")
        XCTAssertEqual(decoded.malibuRewardEligibility?.withdrawalState, "unavailable")
        XCTAssertEqual(decoded.malibuRewardEligibility?.primaryReason, "telemetry_unavailable")
        XCTAssertEqual(decoded.malibuRewardEligibility?.reasons, ["telemetry_unavailable"])
    }

    func testFreshProviderEarningsWithoutRewardEligibilityFailsClosed() throws {
        let data = Data("""
        {
          "wallet_bound": false,
          "trust_tier": "trusted",
          "unpaid_ledger_backlog_usdc": 0,
          "unpaid_ledger_backlog_malibu": 8,
          "malibu_withdrawable": 8,
          "malibu_held": 0,
          "malibu_projection_fresh": true
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ProviderEarnings.self, from: data)
        XCTAssertTrue(decoded.malibuProjectionFresh)
        XCTAssertEqual(decoded.malibuRewardEligibility?.schemaVersion, "malibu_reward_eligibility.v1")
        XCTAssertEqual(decoded.malibuRewardEligibility?.withdrawalState, "unavailable")

        var snapshot = AgentSnapshot.empty
        snapshot.walletBound = decoded.walletBound
        snapshot.trustTier = decoded.trustTier
        snapshot.providerEarningsFresh = decoded.earningsProjectionFresh
        snapshot.malibuProjectionFresh = decoded.malibuProjectionFresh
        snapshot.malibuWithdrawable = decoded.malibuWithdrawable
        snapshot.malibuHeld = decoded.malibuHeld
        snapshot.malibuRewardEligibility = decoded.malibuRewardEligibility

        XCTAssertEqual(AgentSnapshotPresenter.malibuAvailabilityLine(snapshot), "MALIBU: status unavailable · 0.00 held")
        XCTAssertEqual(AgentSnapshotPresenter.eligibilityLine(snapshot), "Reward status unavailable")
    }

    func testUnavailableRewardEligibilityDoesNotRenderLockedAmount() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.providerEarningsFresh = true
        snapshot.malibuProjectionFresh = true
        snapshot.earningsUsdcToday = 0.04
        snapshot.malibuAccruedToday = 8
        snapshot.malibuAccruedAllTime = 8
        snapshot.malibuRewardEligibility = MalibuRewardEligibility.unavailableForMissingObject()

        let earningsLine = AgentSnapshotPresenter.earningsLine(snapshot)
        let fullLine = AgentSnapshotPresenter.malibuFullLine(snapshot)
        XCTAssertEqual(earningsLine, "Today: $0.04 USDC · MALIBU reward status unavailable")
        XCTAssertEqual(fullLine, "MALIBU today unavailable · 8.00 all-time · reward status unavailable")
        XCTAssertFalse(earningsLine.contains("[locked]"))
        XCTAssertFalse(fullLine.contains("locked"))
    }

    // HIGH-2: a wallet-status telemetry failure (earnings fresh, MALIBU
    // projection NOT fresh, wallet state preserved) must read as an honest
    // "not available" — never a fake "No payout wallet yet" or "warming up".
    func testTelemetryFailureReadsHonestNotBenign() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = false   // wallet-status telemetry failed
        s.walletBound = true              // preserved from the earnings frame
        s.earningsUsdcToday = 0.03

        XCTAssertEqual(AgentSnapshotPresenter.malibuFullLine(s), "MALIBU rewards not available yet")
        XCTAssertNil(AgentSnapshotPresenter.trustCriteria(s))
        let health = AgentSnapshotPresenter.miningHealth(s)
        XCTAssertNotEqual(health.reasonCode, "wallet_missing")
        XCTAssertFalse(health.status.lowercased().contains("warming"))
        XCTAssertFalse(health.status.contains("No payout wallet"))
        XCTAssertTrue(health.rewardSummary.contains("MALIBU unavailable"), health.rewardSummary)
    }

    // HIGH-2: a fresh frame that could not compute a verdict (telemetry
    // unavailable sentinel) reads as a problem, not "Locked until Trusted" or
    // any all-good state, and shows no fabricated trust criteria.
    func testFreshRewardTelemetryUnavailableReadsAsProblem() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = true
        s.walletBound = true
        s.malibuRewardEligibility = MalibuRewardEligibility.unavailableForMissingObject()

        XCTAssertTrue(AgentSnapshotPresenter.isRewardTelemetryUnavailable(s))
        XCTAssertNil(AgentSnapshotPresenter.trustCriteria(s))
        XCTAssertEqual(AgentSnapshotPresenter.trustLine(s), "Trust status temporarily unavailable")
        let health = AgentSnapshotPresenter.miningHealth(s)
        XCTAssertEqual(health.reasonCode, "reward_telemetry_outage")
        XCTAssertFalse(health.status.contains("Locked"))
        let status = AgentSnapshotPresenter.consolidatedStatus(s)
        // A GENUINE reward-telemetry outage is a fault: surfaced as needs-
        // attention, never as calm "warming up" or a false-positive "earning".
        XCTAssertEqual(status.tone, .attention)
        XCTAssertEqual(status.label, "Reward status unavailable")
        XCTAssertFalse(status.meaning.lowercased().contains("warming"))
    }

    // HIGH-1: criteria render by their ACTUAL IDs with distinct-pair truth.
    // E1 satisfies the economic slot; an empty additional list leaves the
    // distinct second slot pending → "1 of 2", not the raw unique-ID count.
    func testTrustCriteriaRenderDistinctPairE1EconomicOnly() throws {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.malibuProjectionFresh = true
        s.trustTier = .provisional
        s.trustCriteriaMet = 1
        s.trustCriteriaRequired = 2
        s.hasGranularTrustCriteria = true
        s.economicCriteria = ["E1"]
        s.additionalCriteria = ["E1"]   // coordinator adds E1 to both lists
        s.verifiedReceiptCount = 137
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )

        let criteria = try XCTUnwrap(AgentSnapshotPresenter.trustCriteria(s))
        XCTAssertEqual(criteria.count, 2)
        XCTAssertEqual(criteria[0].title, "Economic criterion")
        XCTAssertTrue(criteria[0].done)
        XCTAssertTrue(criteria[0].detail.contains("100 verified customer jobs"))
        XCTAssertEqual(criteria[1].title, "Distinct additional criterion")
        // Duplicate E1 overlaps itself → the second slot is still pending.
        XCTAssertFalse(criteria[1].done)
        XCTAssertEqual(AgentSnapshotPresenter.trustLine(s), "Provisional — 1 of 2 criteria met")
        XCTAssertFalse(AgentSnapshotPresenter.trustLine(s).contains("→"))

        var notFresh = s
        notFresh.malibuProjectionFresh = false
        XCTAssertNil(AgentSnapshotPresenter.trustCriteria(notFresh))
    }

    // HIGH-1: the four auditor-named cases for distinct-pair truth.
    func testTrustDistinctPairTruthAcrossCriterionCombinations() {
        func snap(_ econ: [String], _ add: [String]) -> AgentSnapshot {
            var s = AgentSnapshot.empty
            s.state = .serving
            s.networkState = "buyer_serving"
            s.malibuProjectionFresh = true
            s.trustTier = .provisional
            s.hasGranularTrustCriteria = true
            s.economicCriteria = econ
            s.additionalCriteria = add
            s.malibuRewardEligibility = MalibuRewardEligibility(
                earningState: "held", withdrawalState: "held",
                primaryReason: "held_provisional_trust_tier",
                reasons: ["held_provisional_trust_tier"]
            )
            return s
        }
        func slots(_ econ: [String], _ add: [String]) -> (Int, Bool, Bool) {
            let s = snap(econ, add)
            let c = AgentSnapshotPresenter.trustCriteria(s)!
            return (AgentSnapshotPresenter.distinctPairProgress(s).met, c[0].done, c[1].done)
        }
        // E2 (economic) + A4 (additional): distinct → 2 of 2.
        XCTAssertEqual(slots(["E2"], ["A4"]).0, 2)
        // E3 (economic) + A3 (additional): distinct → 2 of 2.
        XCTAssertEqual(slots(["E3"], ["A3"]).0, 2)
        // E1 as additional only (both lists carry E1): economic done, second
        // slot pending → 1 of 2.
        let e1 = slots(["E1"], ["E1"])
        XCTAssertEqual(e1.0, 1); XCTAssertTrue(e1.1); XCTAssertFalse(e1.2)
        // E2 economic + A3 additional overlap (wallet balance) → 1 of 2, second
        // slot pending even though two IDs are satisfied.
        let overlap = slots(["E2"], ["A3"])
        XCTAssertEqual(overlap.0, 1); XCTAssertTrue(overlap.1); XCTAssertFalse(overlap.2)
    }

    // Re-audit HIGH: an ADDITIONAL-only criterion (e.g. A4 App Attest with no
    // economic criterion yet) counts its own row as done — the provider really
    // completed one of the two displayed slots — while the overall progress
    // still reflects that the distinct economic slot is pending.
    func testAdditionalOnlyCriterionCountsItsRow() throws {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.malibuProjectionFresh = true
        s.trustTier = .provisional
        s.hasGranularTrustCriteria = true
        s.economicCriteria = []
        s.additionalCriteria = ["A4"]
        s.appAttested = true
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held", withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )
        let criteria = try XCTUnwrap(AgentSnapshotPresenter.trustCriteria(s))
        XCTAssertFalse(criteria[0].done)                       // economic pending
        XCTAssertTrue(criteria[1].done)                        // additional (A4) done
        XCTAssertTrue(criteria[1].detail.contains("App Attest"))
        XCTAssertEqual(AgentSnapshotPresenter.distinctPairProgress(s).met, 1)
        XCTAssertEqual(AgentSnapshotPresenter.trustLine(s), "Provisional — 1 of 2 criteria met")
    }

    // Re-audit HIGH (back-compat): a legacy frame that predates the granular
    // criterion IDs (hasGranularTrustCriteria == false) must fall back to the
    // raw coordinator counters rather than rendering an empty-array "0 of 2",
    // and must hide the by-name disclosure it cannot render faithfully.
    func testLegacyFrameWithoutGranularCriteriaFallsBackToCounters() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.malibuProjectionFresh = true
        s.trustTier = .provisional
        s.hasGranularTrustCriteria = false        // legacy CLI: no granular keys
        s.trustCriteriaMet = 1
        s.trustCriteriaRequired = 2
        s.economicCriteria = []
        s.additionalCriteria = []
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held", withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )
        XCTAssertEqual(AgentSnapshotPresenter.distinctPairProgress(s).met, 1)
        XCTAssertEqual(AgentSnapshotPresenter.trustLine(s), "Provisional — 1 of 2 criteria met")
        // The per-criterion sheet is hidden for a legacy frame (cannot be named).
        XCTAssertNil(AgentSnapshotPresenter.trustCriteria(s))
    }

    // Re-audit HIGH: an explicit CLI-signalled reward/wallet telemetry OUTAGE
    // (rewardTelemetryUnavailable) — even with a fresh USDC earnings frame —
    // reads as an honest "reward status unavailable", never the calm first-run
    // "warming up" copy nor a false "earning". USDC stays truthful separately.
    func testWalletStatusOutageSignalReadsAsUnavailableNotWarmingUp() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = false           // MALIBU projection failed
        s.rewardTelemetryUnavailable = true       // CLI signalled the outage
        s.walletBound = true
        s.earningsUsdcToday = 0.05                // USDC unaffected
        let health = AgentSnapshotPresenter.miningHealth(s)
        XCTAssertEqual(health.reasonCode, "reward_telemetry_outage")
        XCTAssertFalse(health.status.lowercased().contains("warming"))
        XCTAssertFalse(health.status.contains("No payout wallet"))
        let status = AgentSnapshotPresenter.consolidatedStatus(s)
        // A genuine wallet-status outage is a fault → needs-attention, not the
        // calm neutral reserved for benign warming-up / missing-wallet.
        XCTAssertEqual(status.tone, .attention)
        XCTAssertEqual(status.label, "Reward status unavailable")
        XCTAssertFalse(status.meaning.lowercased().contains("warming"))
        XCTAssertTrue(AgentSnapshotPresenter.isRewardTelemetryUnavailable(s))
    }

    // Re-audit HIGH (back-compat wire contract): the app derives
    // hasGranularTrustCriteria from field PRESENCE on the wire — a legacy frame
    // that never carried the granular keys decodes to false (→ counter
    // fallback), while a modern frame that carries them (even empty) decodes to
    // true. rewardTelemetryUnavailable defaults false when the key is absent.
    func testGranularTrustCriteriaPresenceDecodesFromWire() throws {
        let legacy = try JSONDecoder().decode(
            ProviderEarnings.self,
            from: Data("""
            {"wallet_bound": true, "trust_tier": "provisional",
             "trust_criteria_met": 1, "trust_criteria_required": 2,
             "malibu_projection_fresh": true, "earnings_projection_fresh": true}
            """.utf8)
        )
        XCTAssertFalse(legacy.hasGranularTrustCriteria)
        XCTAssertFalse(legacy.rewardTelemetryUnavailable)

        let modern = try JSONDecoder().decode(
            ProviderEarnings.self,
            from: Data("""
            {"wallet_bound": true, "trust_tier": "provisional",
             "trust_criteria_met": 1, "trust_criteria_required": 2,
             "economic_criteria": [], "additional_criteria": [],
             "malibu_projection_fresh": true, "earnings_projection_fresh": true}
            """.utf8)
        )
        XCTAssertTrue(modern.hasGranularTrustCriteria)
    }

    // Re-audit HIGH: the additional slot uses the coordinator's distinct-pair
    // EXISTENCE rule, not "additional distinct from every economic". A provider
    // with E1,E2 economic + E1,A3 additional has a valid distinct pair (E1+A3),
    // so both slots read done → 2 of 2, matching coordinator Trusted eligibility.
    func testAdditionalSlotUsesDistinctPairExistence() throws {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.malibuProjectionFresh = true
        s.trustTier = .provisional
        s.hasGranularTrustCriteria = true
        s.economicCriteria = ["E1", "E2"]
        s.additionalCriteria = ["E1", "A3"]
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held", withdrawalState: "held",
            primaryReason: "held_provisional_trust_tier",
            reasons: ["held_provisional_trust_tier"]
        )
        let criteria = try XCTUnwrap(AgentSnapshotPresenter.trustCriteria(s))
        XCTAssertTrue(criteria[0].done)
        XCTAssertTrue(criteria[1].done)
        XCTAssertEqual(AgentSnapshotPresenter.distinctPairProgress(s).met, 2)
    }

    // Re-audit HIGH: an authoritative BLOCKING reward reason (compute integrity
    // block, untrusted token) surfaces its real reason as needs-attention,
    // never the generic "Locked until Trusted / complete trust criteria".
    func testBlockingRewardReasonSurfacesBeforeProvisionalLock() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.walletBound = true
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = true
        s.trustTier = .provisional
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "ineligible", withdrawalState: "ineligible",
            primaryReason: "compute_integrity_blocked",
            reasons: ["compute_integrity_blocked"]
        )
        let health = AgentSnapshotPresenter.miningHealth(s)
        XCTAssertEqual(health.reasonCode, "reward_eligibility_review")
        XCTAssertFalse(health.status.contains("Locked until Trusted"))
        XCTAssertEqual(AgentSnapshotPresenter.consolidatedStatus(s).tone, .attention)

        // A past-epoch exclusion is informational (neutral), not a red alarm and
        // not "Locked until Trusted".
        var epoch = s
        epoch.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "ineligible", withdrawalState: "ineligible",
            primaryReason: "excluded_epoch_disposition",
            reasons: ["excluded_epoch_disposition"]
        )
        let epochHealth = AgentSnapshotPresenter.miningHealth(epoch)
        XCTAssertEqual(epochHealth.reasonCode, "reward_epoch_disposition")
        XCTAssertEqual(AgentSnapshotPresenter.consolidatedStatus(epoch).tone, .neutral)
    }

    // Re-audit HIGH: a blocking reward verdict must beat the wallet-missing
    // branch. A provider with no payout wallet AND a compute-integrity block
    // must be told to resolve the block, not "add a payout wallet".
    func testBlockingRewardReasonBeatsWalletMissing() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.walletBound = false          // no payout wallet
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = true
        s.trustTier = .provisional
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "ineligible", withdrawalState: "ineligible",
            primaryReason: "compute_integrity_blocked",
            reasons: ["compute_integrity_blocked"]
        )
        let health = AgentSnapshotPresenter.miningHealth(s)
        XCTAssertEqual(health.reasonCode, "reward_eligibility_review")
        XCTAssertNotEqual(health.reasonCode, "wallet_missing")
        XCTAssertFalse(health.nextAction.contains("payout wallet"))
    }

    // Re-audit MEDIUM: a post-setup interruption (reconnecting) is NOT collapsed
    // into "Setting up" — it keeps its accurate status label.
    func testInterruptionIsNotLabeledSettingUp() {
        var s = AgentSnapshot.empty
        s.state = .reconnecting
        s.currentModelID = "meta-llama/llama-3.2-3b-instruct"
        let status = AgentSnapshotPresenter.consolidatedStatus(s)
        XCTAssertNotEqual(status.label, "Setting up")

        // A genuine first-run startup still reads "Setting up".
        var startup = AgentSnapshot.empty
        startup.state = .starting
        XCTAssertEqual(AgentSnapshotPresenter.consolidatedStatus(startup).label, "Setting up")
    }

    // Re-audit MEDIUM: the three USDC surfaces agree on a fresh PARTIAL frame.
    // A frame reporting some totals but not usdc_today must not fabricate $0.00
    // anywhere; hero, full line, and reward summary all use non-authoritative
    // placeholders for the missing field.
    func testPartialUSDCFrameNeverFabricatesTodayZero() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.networkState = "buyer_serving"
        s.providerEarningsFresh = true
        s.earningsUsdcToday = nil          // missing
        s.earningsUsdcLifetime = 12.5      // but lifetime present → partial frame
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(s), "—")
        XCTAssertTrue(AgentSnapshotPresenter.usdcFullLine(s).contains("not reported today"))
        XCTAssertFalse(AgentSnapshotPresenter.usdcFullLine(s).contains("$0.00 today"))

        // A brand-new all-absent fresh frame IS a real $0.00 across surfaces.
        var allZero = AgentSnapshot.empty
        allZero.state = .serving
        allZero.networkState = "buyer_serving"
        allZero.providerEarningsFresh = true
        XCTAssertEqual(AgentSnapshotPresenter.usdcTodayDisplay(allZero), "$0.00")
    }

    // P2.7: one authoritative status following the three-state model.
    func testConsolidatedStatusFollowsThreeStateModel() {
        var setup = AgentSnapshot.empty
        setup.state = .starting
        let settingUp = AgentSnapshotPresenter.consolidatedStatus(setup)
        XCTAssertEqual(settingUp.phase, .settingUp)
        XCTAssertEqual(settingUp.label, "Setting up")

        var live = AgentSnapshot.empty
        live.state = .serving
        live.networkState = "buyer_serving"
        live.providerEarningsFresh = true
        live.trustTier = .provisional
        live.walletBound = false
        let liveStatus = AgentSnapshotPresenter.consolidatedStatus(live)
        XCTAssertEqual(liveStatus.phase, .live)
        XCTAssertEqual(liveStatus.label, "Live · Provisional")
        XCTAssertEqual(liveStatus.tone, .neutral)
        XCTAssertEqual(liveStatus.nextAction, "Add a payout wallet to receive earnings.")

        var earning = live
        earning.trustTier = .trusted
        earning.walletBound = true
        let earningStatus = AgentSnapshotPresenter.consolidatedStatus(earning)
        XCTAssertEqual(earningStatus.phase, .earning)
        XCTAssertEqual(earningStatus.label, "Earning · Trusted")
        XCTAssertNil(earningStatus.nextAction)

        var err = AgentSnapshot.empty
        err.state = .error
        err.lastError = "boom"
        XCTAssertEqual(AgentSnapshotPresenter.consolidatedStatus(err).phase, .needsAttention)

        // A network-ready provider blocked on battery surfaces that (with its
        // concrete action) rather than a generic "live" headline.
        var battery = live
        battery.providerEarningsFresh = true
        battery.idlePrewarmSummary = ProviderIdlePrewarmSummary(skipsByReasonLast1h: ["on_battery": 1])
        let batteryStatus = AgentSnapshotPresenter.consolidatedStatus(battery)
        XCTAssertEqual(batteryStatus.phase, .needsAttention)
        XCTAssertEqual(batteryStatus.nextAction, "Plug in power to earn.")
    }

    // P1.5 wire: the granular trust-criterion fields decode from the earnings
    // frame, and legacy frames without them default safely.
    func testProviderEarningsDecodesTrustCriteriaArrays() throws {
        let data = Data("""
        {
          "wallet_bound": true,
          "trust_tier": "provisional",
          "unpaid_ledger_backlog_usdc": 0,
          "unpaid_ledger_backlog_malibu": 0,
          "trust_criteria_met": 1,
          "trust_criteria_required": 2,
          "economic_criteria": ["E1"],
          "additional_criteria": ["A1"],
          "verified_receipt_count": 137,
          "app_attested": true
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(ProviderEarnings.self, from: data)
        XCTAssertEqual(decoded.economicCriteria, ["E1"])
        XCTAssertEqual(decoded.additionalCriteria, ["A1"])
        XCTAssertEqual(decoded.verifiedReceiptCount, 137)
        XCTAssertEqual(decoded.appAttested, true)

        let legacy = try JSONDecoder().decode(ProviderEarnings.self, from: Data("""
        {"wallet_bound": false, "trust_tier": "provisional", "unpaid_ledger_backlog_usdc": 0, "unpaid_ledger_backlog_malibu": 0}
        """.utf8))
        XCTAssertEqual(legacy.economicCriteria, [])
        XCTAssertEqual(legacy.additionalCriteria, [])
        XCTAssertNil(legacy.verifiedReceiptCount)
        XCTAssertNil(legacy.appAttested)
    }

    // LOW-7: every coordinator reward reason (including the epoch-disposition
    // reasons) survives decode on the app side instead of collapsing to the
    // generic telemetry-drift sentinel; an unknown future reason fails closed.
    func testAppRewardReasonAllowlistRoundTripsEveryCoordinatorReason() throws {
        let reasons = [
            "earning_verified_work", "eligible_idle_no_work", "held_provisional_trust_tier",
            "held_provider_daily_cap", "held_wallet_daily_cap", "held_demotion_cooldown",
            "held_epoch_disposition", "excluded_epoch_disposition",
            "burned_or_retired_epoch_disposition", "withdrawable_balance_available",
            "withdrawable_no_balance", "missing_wallet_binding", "insufficient_verified_receipts",
            "app_attestation_missing", "hardware_evidence_unavailable",
            "hardware_evidence_missing_or_expired", "compute_integrity_unavailable",
            "compute_integrity_pending", "compute_integrity_blocked", "provider_token_untrusted",
            "local_on_battery", "local_thermal_pressure", "model_not_ready", "telemetry_unavailable",
        ]
        for reason in reasons {
            let json = """
            {"schema_version":"malibu_reward_eligibility.v1","earning_state":"held",
             "withdrawal_state":"held","primary_reason":"\(reason)","reasons":["\(reason)"]}
            """
            let decoded = try JSONDecoder().decode(MalibuRewardEligibility.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.primaryReason, reason, "reason \(reason) should round-trip")
        }
        let unknown = """
        {"schema_version":"malibu_reward_eligibility.v1","earning_state":"held",
         "withdrawal_state":"held","primary_reason":"future_unknown_reason","reasons":["future_unknown_reason"]}
        """
        let decoded = try JSONDecoder().decode(MalibuRewardEligibility.self, from: Data(unknown.utf8))
        XCTAssertEqual(decoded.primaryReason, "telemetry_unavailable")
    }

    func testDefaultPresenterStringsDoNotExposeInternalTerms() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .reconnecting
        snapshot.currentModelID = "llama"
        snapshot.networkState = "live_verified"
        snapshot.cliVersion = "1.9.0"
        snapshot.advertisedMaxConcurrency = 2
        snapshot.lifecycleState = "watchdog_recovery"
        snapshot.lifecycleReason = "watchdog_rollback_post_start_rejoin_timeout"
        snapshot.credentialState = "ready"
        snapshot.credentialRestartSafe = true
        snapshot.admissionIdentityState = "ready"
        snapshot.coordinatorIdentityAdmissionMode = "signature"

        let publicStrings = [
            AgentSnapshotPresenter.publicStatus(snapshot).title,
            AgentSnapshotPresenter.publicStatus(snapshot).detail,
            AgentSnapshotPresenter.publicStatus(snapshot).safeNextAction,
            AgentSnapshotPresenter.consolidatedStatus(snapshot).label,
            AgentSnapshotPresenter.consolidatedStatus(snapshot).meaning,
            AgentSnapshotPresenter.consolidatedStatus(snapshot).nextAction,
            AgentSnapshotPresenter.stateLine(snapshot),
            AgentSnapshotPresenter.credentialLine(snapshot),
            AgentSnapshotPresenter.admissionIdentityLine(snapshot),
            AgentSnapshotPresenter.lifecycleLine(snapshot),
            AgentSnapshotPresenter.compatibilitySetLine(snapshot),
            AgentSnapshotPresenter.advertisedCapacityLine(snapshot),
            AgentSnapshotPresenter.cliVersionLine(snapshot),
            AgentSnapshotPresenter.cliVersionMenuLine(snapshot),
        ].compactMap { $0 }.joined(separator: "\n").lowercased()

        for term in prohibitedPublicTerms {
            XCTAssertFalse(publicStrings.contains(term), "\(term) leaked in:\n\(publicStrings)")
        }
    }

    func testProviderSoftwareRepairRequiresFreshProtectedSourceCapability() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "catalog_update_required"
        snapshot.cliVersion = "1.8.93"
        snapshot.coordinatorRecommendedVersion = "1.8.101"
        snapshot.providerSoftwareRepairRecommended = true

        let status = AgentSnapshotPresenter.publicStatus(snapshot)

        XCTAssertEqual(status.title, "This Mac is not currently eligible")
        XCTAssertEqual(status.safeNextAction, "Install latest provider software.")
        XCTAssertEqual(status.executableAction, .updateProviderSoftware)
        XCTAssertFalse(AgentSnapshotPresenter.canRepairProviderSoftware(snapshot))
    }

    func testProviderSoftwareRepairCapabilityTakesSoftwareUpdateAction() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "catalog_update_required"
        snapshot.cliVersion = "1.8.93"
        snapshot.coordinatorRecommendedVersion = "1.8.101"
        snapshot.providerSoftwareRepairRecommended = true
        enableProtectedProviderSoftwareRepair(&snapshot)

        let status = AgentSnapshotPresenter.publicStatus(snapshot)

        XCTAssertEqual(status.title, "Provider software repair available")
        XCTAssertEqual(status.detail, "A permission on your home folder blocked automatic update recovery.")
        XCTAssertEqual(
            status.safeNextAction,
            "Repair provider software. Malibu will reinstall the bundled provider software and watchdog. Your provider identity and downloaded models will be kept."
        )
        XCTAssertEqual(status.executableAction, .repairProviderSoftware)
        XCTAssertTrue(AgentSnapshotPresenter.canRepairProviderSoftware(snapshot))
    }

    func testProviderSoftwareRepairRecommendedTakesReadyStateAction() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationFresh = true
        snapshot.statusObservationID = "obs-ready-repair"
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.providerSoftwareRepairRecommended = true
        enableProtectedProviderSoftwareRepair(&snapshot)

        let status = AgentSnapshotPresenter.publicStatus(snapshot)

        XCTAssertEqual(status.title, "Provider is ready")
        XCTAssertEqual(status.executableAction, .repairProviderSoftware)
        XCTAssertTrue(AgentSnapshotPresenter.canRepairProviderSoftware(snapshot))
    }

    func testProviderSoftwareRepairRecommendedTakesPausedStateAction() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .paused
        snapshot.providerSoftwareRepairRecommended = true
        enableProtectedProviderSoftwareRepair(&snapshot)

        let status = AgentSnapshotPresenter.publicStatus(snapshot)

        XCTAssertEqual(status.title, "Provider is paused")
        XCTAssertEqual(status.executableAction, .repairProviderSoftware)
    }

    func testProviderSoftwareRepairCapabilityDoesNotSurviveStatusInvalidation() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationFresh = true
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.providerSoftwareRepairRecommended = true
        enableProtectedProviderSoftwareRepair(&snapshot)

        snapshot.invalidateLocalStatusObservation()
        let status = AgentSnapshotPresenter.publicStatus(snapshot)

        XCTAssertNotEqual(status.executableAction, .repairProviderSoftware)
        XCTAssertFalse(AgentSnapshotPresenter.canRepairProviderSoftware(snapshot))
    }

    func testProviderSoftwareUpdateInProgressSurvivesStatusInvalidation() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationFresh = true
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.cliUpdateInProgress = true

        snapshot.invalidateLocalStatusObservation()

        XCTAssertTrue(snapshot.cliUpdateInProgress)
        XCTAssertEqual(
            AgentSnapshotPresenter.cliUpdateStatusLine(snapshot),
            "Installing latest provider software…"
        )
    }

    func testProviderSoftwareRepairInProgressKeepsRepairStatus() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "catalog_update_required"
        snapshot.cliVersion = "1.8.93"
        snapshot.coordinatorRecommendedVersion = "1.8.101"
        snapshot.providerSoftwareRepairRecommended = true
        enableProtectedProviderSoftwareRepair(&snapshot)
        snapshot.providerSoftwareRepairInProgress = true

        let status = AgentSnapshotPresenter.publicStatus(snapshot)

        XCTAssertEqual(status.title, "Repairing provider software")
        XCTAssertEqual(
            status.detail,
            "Malibu is reinstalling the bundled provider software and watchdog. Keep Malibu open. Your identity, models, and payout stay on this Mac."
        )
        XCTAssertEqual(status.safeNextAction, "Keep Malibu open. You do not need a new invite.")
        XCTAssertNil(status.executableAction)
    }

    func testProviderSoftwareRepairInProgressKeepsReadyWhenStillServing() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationFresh = true
        snapshot.statusObservationID = "obs-repair-live"
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.providerSoftwareRepairRecommended = true
        enableProtectedProviderSoftwareRepair(&snapshot)
        snapshot.providerSoftwareRepairInProgress = true

        let status = AgentSnapshotPresenter.publicStatus(snapshot)

        XCTAssertEqual(status.title, "Provider is ready")
        XCTAssertTrue(status.detail?.contains("approved and available") == true)
        XCTAssertTrue(status.detail?.contains("software update") == true)
        XCTAssertEqual(status.safeNextAction, "Keep Malibu open. You do not need a new invite.")
        XCTAssertNil(status.executableAction)
    }

    func testProviderSoftwareRepairStatusLine() {
        var snapshot = AgentSnapshot.empty
        snapshot.providerSoftwareRepairInProgress = true

        XCTAssertEqual(
            AgentSnapshotPresenter.cliUpdateStatusLine(snapshot),
            "Repairing provider software…"
        )
    }

    func testDefaultDashboardAndOnboardingStringsDoNotExposeInternalTerms() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .error
        snapshot.credentialState = "incompatible"
        snapshot.cliUpdateLastError = CLIUpdateRunner.Error.cliNotFound.localizedDescription

        let publicStrings = (
            DashboardCopy.defaultPublicStrings(snapshot) + [
                OnboardingCopy.intro,
                OnboardingCopy.introDetail,
                OnboardingCopy.idleDetail,
                OnboardingCopy.installingFallback,
                OnboardingCopy.importingProviderAccess,
                OnboardingCopy.referralCaption,
                OnboardingCopy.referralChecking,
                OnboardingCopy.referralUnavailable,
                DashboardCopy.resetProviderTitle,
                DashboardCopy.exportDiagnosticsTitle,
                DashboardCopy.recoveryHelpTitle,
                DashboardCopy.resetProviderConfirmTitle,
                DashboardCopy.resetProviderConfirmDetail,
                "Ready for customer work · network is quiet",
                "Ready · work is queued on this Mac",
                "Ready · work ran; paid credits appear when a job settles",
                "Eligible · network is quiet",
                AgentSnapshotPresenter.credentialLine(snapshot),
                AgentSnapshotPresenter.cliUpdateStatusLine(snapshot),
            ].compactMap { $0 }
        ).joined(separator: "\n").lowercased()

        for term in prohibitedPublicTerms {
            XCTAssertFalse(publicStrings.contains(term), "\(term) leaked in:\n\(publicStrings)")
        }
    }

    func testUnknownLifecycleIdentifiersDoNotAppearInDefaultStatusCopy() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .starting
        snapshot.lifecycleState = "coordinator_admission_waiting"
        snapshot.lifecycleReason = "compatibility_set_stale"

        let publicStrings = [
            AgentSnapshotPresenter.stateLine(snapshot),
            AgentSnapshotPresenter.lifecycleLine(snapshot),
        ].compactMap { $0 }.joined(separator: "\n").lowercased()

        XCTAssertFalse(publicStrings.contains("coordinator_admission_waiting"), publicStrings)
        XCTAssertFalse(publicStrings.contains("compatibility_set_stale"), publicStrings)
        XCTAssertFalse(publicStrings.contains("coordinator"), publicStrings)
        XCTAssertFalse(publicStrings.contains("compatibility"), publicStrings)
        XCTAssertTrue(publicStrings.contains("provider status update"), publicStrings)
    }

    func testDashboardDefaultStringsExcludeAdvancedLogs() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.currentModelID = "llama"
        let logs = [
            "watchdog recovery started",
            "coordinator join requires model_artifact_sha256",
        ]

        let defaultCopy = DashboardCopy.defaultPublicStrings(snapshot)
            .joined(separator: "\n")
            .lowercased()
        let advancedCopy = DashboardCopy.advancedDiagnosticsStrings(snapshot, logLines: logs)
            .joined(separator: "\n")
            .lowercased()

        XCTAssertFalse(defaultCopy.contains("watchdog"), defaultCopy)
        XCTAssertFalse(defaultCopy.contains("coordinator"), defaultCopy)
        XCTAssertTrue(advancedCopy.contains("watchdog"), advancedCopy)
        XCTAssertTrue(advancedCopy.contains("coordinator"), advancedCopy)
    }

    func testRawInternalErrorFallsBackToAdvancedDiagnosticsGuidance() {
        let raw = "coordinator join requires model_artifact_sha256 in /tmp/macprovider.err.log"

        XCTAssertEqual(
            AgentSnapshotPresenter.publicErrorDetail(raw),
            "Details are available in Advanced diagnostics."
        )
        XCTAssertEqual(
            LogTailBuffer.redacted(raw),
            "coordinator join requires model_artifact_sha256 in [path]"
        )
    }

    func testStaleLaunchAgentRecoveryMessageRemainsUserVisible() {
        let message =
            "Provider setup is blocked by a previous installation. "
            + "Click Launch Provider to repair the background service. "
            + "Your provider identity and model files will be kept."

        XCTAssertEqual(AgentSnapshotPresenter.publicErrorDetail(message), message)
    }

    func testRepairFailureMessagesRemainUserVisible() {
        let missing =
            "Provider software could not be verified for repair. Your provider identity was not changed."
        let absent =
            "Provider software for repair was not found in Malibu. Your provider identity was not changed."

        XCTAssertEqual(AgentSnapshotPresenter.publicErrorDetail(missing), missing)
        XCTAssertEqual(AgentSnapshotPresenter.publicErrorDetail(absent), absent)

        let failedInstall = CLIInstallRunner.Error.nonZeroExit(5)
        let failedLaunch = CLIInstallRunner.Error.launchFailed("coordinator join /tmp/macprovider.err.log")
        XCTAssertEqual(
            AgentSnapshotPresenter.publicErrorDetail(failedInstall.localizedDescription),
            "Provider software install failed (exit 5). Your provider identity was not changed."
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.publicErrorDetail(failedLaunch.localizedDescription),
            "Provider software could not start the installer. Your provider identity was not changed."
        )
        XCTAssertFalse(failedLaunch.localizedDescription.contains("/tmp"))
    }

    func testOnboardingAdvancedFailureDiagnosticsKeepsRedactedDetails() {
        let details = OnboardingCopy.advancedFailureDiagnostics(
            message: "coordinator join requires model_artifact_sha256 in /tmp/macprovider.err.log",
            installLogLines: ["provider_token: secret-token-value"],
            providerLogLines: ["watchdog recovery started"]
        )

        XCTAssertTrue(details.contains("coordinator join requires model_artifact_sha256 in [path]"))
        XCTAssertFalse(details.contains("/tmp/macprovider.err.log"))
        XCTAssertTrue(details.contains("[redacted]"))
        XCTAssertTrue(details.contains("watchdog recovery started"))
    }

    func testHomeACLDiagnosticFindingShowsRepairPendingWithoutRepairCTA() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.providerSoftwareRepairRecommended = true
        snapshot.diagnosticFindings = [
            ProviderDiagnosticFinding(
                signatureID: .autoupdateHomeACLRejected,
                source: .providerLogDiagnostics,
                userMessage: "Provider software repair is pending.",
                evidence: "autoupdate recovery_error=acl_write_rejected:/Users/provider",
                observedAt: Date()
            )
        ]

        let status = AgentSnapshotPresenter.publicStatus(snapshot)

        XCTAssertEqual(status.title, "Provider software repair pending")
        XCTAssertEqual(status.executableAction, .exportDiagnostics)
        XCTAssertFalse(AgentSnapshotPresenter.canRepairProviderSoftware(snapshot))
        XCTAssertFalse(status.safeNextAction?.contains("Repair provider software.") == true)
    }

    func testFreshReadyStatusKeepsPrimaryStateWhenLogFindingSupplementsDiagnostics() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.networkState = "buyer_serving"
        snapshot.localStatusContractCompatible = true
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "ready-observation"
        snapshot.statusObservedAt = Date()
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        snapshot.diagnosticFindings = [
            ProviderDiagnosticFinding(
                signatureID: .staleModelCatalog,
                source: .providerLogDiagnostics,
                userMessage: "Model options changed since this Mac last picked a model.",
                evidence: "model catalog provenance envelope is stale",
                observedAt: Date()
            )
        ]

        let status = AgentSnapshotPresenter.publicStatus(snapshot)
        let diagnosticLines = AgentSnapshotPresenter.diagnosticFindingLines(snapshot)

        XCTAssertEqual(status.title, "Provider is ready")
        XCTAssertNil(status.executableAction)
        XCTAssertTrue(diagnosticLines.joined(separator: "\n").contains("Provider software"))
    }

    func testServeUnresponsiveUnknownCauseIsRenderedHonestly() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .error
        snapshot.diagnosticFindings = [
            ProviderDiagnosticFinding(
                signatureID: .serveUnresponsive,
                source: .status,
                userMessage: "Provider local status is unavailable or stale.",
                evidence: nil,
                observedAt: Date()
            )
        ]

        let status = AgentSnapshotPresenter.publicStatus(snapshot)
        let diagnosticLines = AgentSnapshotPresenter.diagnosticFindingLines(snapshot)

        XCTAssertEqual(status.title, "Provider status is unavailable")
        XCTAssertEqual(status.detail, "Malibu cannot confirm current provider status. Cause unknown.")
        XCTAssertTrue(diagnosticLines.joined(separator: "\n").contains("Cause: unknown_cause"))
    }

    func testStaleObservationIDDoesNotFabricateNetworkContext() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .reconnecting
        snapshot.networkState = "coordinator_unavailable"
        snapshot.diagnosticFindings = [
            ProviderDiagnosticFinding(
                signatureID: .serveUnresponsive,
                source: .status,
                userMessage: "Provider local status is unavailable or stale.",
                evidence: "observation.id=stale-observation",
                observedAt: Date()
            )
        ]

        let status = AgentSnapshotPresenter.publicStatus(snapshot)
        let diagnosticLines = AgentSnapshotPresenter.diagnosticFindingLines(snapshot).joined(separator: "\n")

        XCTAssertEqual(status.title, "Provider status is unavailable")
        XCTAssertEqual(status.detail, "Malibu cannot confirm current provider status. Cause unknown.")
        XCTAssertTrue(diagnosticLines.contains("Cause: unknown_cause"))
        XCTAssertFalse(diagnosticLines.contains("Network context:"))
    }

    func testCoordinatorUnavailableIsContextNotRootCause() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .reconnecting
        snapshot.networkState = "coordinator_unavailable"
        snapshot.diagnosticFindings = [
            ProviderDiagnosticFinding(
                signatureID: .serveUnresponsive,
                source: .status,
                userMessage: "Provider is not confirmed available for customer work.",
                evidence: "network_state=coordinator_unavailable",
                observedAt: Date()
            )
        ]

        let status = AgentSnapshotPresenter.publicStatus(snapshot)
        let diagnosticLines = AgentSnapshotPresenter.diagnosticFindingLines(snapshot)

        XCTAssertEqual(status.title, "Customer availability is interrupted")
        XCTAssertEqual(
            status.detail,
            "Provider local status is current, but customer availability is not confirmed. This is context, not a diagnosed root cause."
        )
        XCTAssertTrue(diagnosticLines.joined(separator: "\n").contains("Network context: network unavailable"))
        XCTAssertFalse(status.detail?.lowercased().contains("coordinator") == true)
    }

    // Re-audit: a post-setup connectivity OUTAGE (local link down) is not
    // first-run setup. consolidatedStatus must classify a reconnecting snapshot
    // whose networkState is "network_offline" as needs-attention (never
    // .settingUp) and carry the honest "Network offline" copy.
    func testConsolidatedStatusTreatsNetworkOfflineAsNeedsAttentionNotSettingUp() {
        var s = AgentSnapshot.empty
        s.state = .reconnecting
        s.currentModelID = "llama"
        s.networkState = "network_offline"

        let status = AgentSnapshotPresenter.consolidatedStatus(s)
        XCTAssertNotEqual(status.phase, .settingUp)
        XCTAssertEqual(status.phase, .needsAttention)
        XCTAssertEqual(status.tone, .attention)
        XCTAssertEqual(status.label, "Network offline")
    }

    // Re-audit: a coordinator-side outage ("coordinator_unavailable") is also
    // not first-run setup, but recovery is automatic — needs-attention with a
    // neutral tone and the "Network unavailable" copy, never .settingUp.
    func testConsolidatedStatusTreatsCoordinatorUnavailableAsNeedsAttentionNotSettingUp() {
        var s = AgentSnapshot.empty
        s.state = .reconnecting
        s.currentModelID = "llama"
        s.networkState = "coordinator_unavailable"

        let status = AgentSnapshotPresenter.consolidatedStatus(s)
        XCTAssertNotEqual(status.phase, .settingUp)
        XCTAssertEqual(status.phase, .needsAttention)
        XCTAssertEqual(status.tone, .neutral)
        XCTAssertEqual(status.label, "Network unavailable")
    }

    // Re-audit: the reward-telemetry outage bit is projection-scoped. A genuine
    // outage now arrives as a non-nil provider_earnings frame with the flag set;
    // a later frame carrying no provider_earnings object is benign absence and
    // must clear a stale sticky bit so a recovered snapshot stops reading
    // "reward status unavailable".
    @MainActor
    func testNilEarningsMetricsFrameClearsStickyRewardTelemetryOutage() {
        var initial = AgentSnapshot.empty
        initial.rewardTelemetryUnavailable = true
        let agent = MalibuAgent(initialSnapshot: initial)
        XCTAssertTrue(agent.snapshot.rewardTelemetryUnavailable)

        // A non-stub metrics frame (uptime reported) with no provider_earnings
        // object: takes the nil-earnings branch that clears the outage bit.
        agent.consume(.metricsResponse(
            earningsUsdc: nil,
            malibuAccrued: nil,
            providerEarnings: nil,
            gpuC: nil,
            gpuUtilizationPct: nil,
            latencyP50Ms: nil,
            latencyP99Ms: nil,
            queueDepth: nil,
            requestsServedToday: nil,
            requestsServedAllTime: nil,
            requestsPerMinute: nil,
            inputTokensToday: nil,
            outputTokensToday: nil,
            inputTokensAllTime: nil,
            outputTokensAllTime: nil,
            uptimeSec: 60
        ))

        XCTAssertFalse(agent.snapshot.rewardTelemetryUnavailable)
    }

    // Round-5 audit: a legacy all-zero stub frame arriving after a real Trusted
    // withdrawable projection must demote freshness so the presenter cannot keep
    // asserting "Earning · Trusted / withdrawals unlocked" from stale data.
    @MainActor
    func testLegacyStubFrameDemotesStaleTrustedWithdrawableFreshness() {
        var initial = AgentSnapshot.empty
        initial.state = .serving
        initial.trustTier = .trusted
        initial.walletBound = true
        initial.hasObservedProviderEarnings = true
        initial.malibuProjectionFresh = true
        initial.providerEarningsFresh = true
        initial.malibuWithdrawable = 5
        let agent = MalibuAgent(initialSnapshot: initial)
        XCTAssertTrue(agent.snapshot.malibuProjectionFresh)

        // A legacy all-zero stub frame (all nil, zero usdc/malibu/uptime).
        agent.consume(.metricsResponse(
            earningsUsdc: 0,
            malibuAccrued: 0,
            providerEarnings: nil,
            gpuC: nil,
            gpuUtilizationPct: nil,
            latencyP50Ms: nil,
            latencyP99Ms: nil,
            queueDepth: nil,
            requestsServedToday: nil,
            requestsServedAllTime: nil,
            requestsPerMinute: nil,
            inputTokensToday: nil,
            outputTokensToday: nil,
            inputTokensAllTime: nil,
            outputTokensAllTime: nil,
            uptimeSec: 0
        ))

        XCTAssertFalse(agent.snapshot.malibuProjectionFresh)
        XCTAssertFalse(agent.snapshot.providerEarningsFresh)
        XCTAssertNotEqual(AgentSnapshotPresenter.miningHealth(agent.snapshot).reasonCode, "trusted_withdrawable")
    }

    // Round-5 audit: an active epoch hold (SPEC-021 authoritative eligibility)
    // outranks raw tier/amount. A Trusted snapshot with malibuWithdrawable > 0 but
    // withdrawal_state=held / primary_reason=held_epoch_disposition must surface
    // held, never trusted_withdrawable / "withdrawals unlocked".
    func testTrustedHeldEpochDispositionDoesNotClaimWithdrawable() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.trustTier = .trusted
        s.walletBound = true
        s.hasObservedProviderEarnings = true
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = true
        s.malibuWithdrawable = 5
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_epoch_disposition",
            reasons: ["held_epoch_disposition"]
        )

        let mining = AgentSnapshotPresenter.miningHealth(s)
        XCTAssertNotEqual(mining.reasonCode, "trusted_withdrawable")
        XCTAssertEqual(mining.reasonCode, "rewards_held")
    }

    // Round-5 audit: the raw trusted-withdrawable branch must be gated on the
    // authoritative eligibility verdict. A held verdict that reaches that branch
    // (not specially handled earlier) must not be promoted to withdrawable.
    func testTrustedWithdrawableGatedOnAuthoritativeEligibility() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.trustTier = .trusted
        s.walletBound = true
        s.hasObservedProviderEarnings = true
        s.providerEarningsFresh = true
        s.malibuProjectionFresh = true
        s.malibuWithdrawable = 9
        s.malibuHeld = 0
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "held",
            primaryReason: "held_manual_review",
            reasons: ["held_manual_review"]
        )

        let mining = AgentSnapshotPresenter.miningHealth(s)
        XCTAssertNotEqual(mining.reasonCode, "trusted_withdrawable")
        XCTAssertEqual(mining.reasonCode, "rewards_held")
    }

    // Round-5 audit: Trust-tier disclosure must not assert "withdrawals unlocked"
    // for a Trusted provider whose authoritative reward status is capped/held.
    func testTrustUnlockSummaryNotUnlockedWhenTrustedButCapped() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.trustTier = .trusted
        s.walletBound = true
        s.malibuProjectionFresh = true
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "held",
            withdrawalState: "capped",
            primaryReason: "held_wallet_daily_cap",
            reasons: ["held_wallet_daily_cap"]
        )

        let summary = AgentSnapshotPresenter.trustUnlockSummary(s)
        XCTAssertFalse(summary.contains("withdrawals are unlocked"))
        XCTAssertTrue(summary.lowercased().contains("follow current reward status"))
    }

    // Round-5 audit (redaction): an unknown/crafted trust-criterion ID must never
    // be rendered raw into dashboard text.
    func testUnknownTrustCriterionIDIsNotRenderedRaw() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.trustTier = .provisional
        s.economicCriteria = ["provider_token=secret /Users/alice host=10.0.0.1"]
        s.additionalCriteria = ["A1"]

        let rendered = (AgentSnapshotPresenter.trustCriteria(s) ?? [])
            .map { $0.title }
            .joined(separator: " · ")
        XCTAssertFalse(rendered.contains("provider_token"))
        XCTAssertFalse(rendered.contains("/Users/alice"))
        XCTAssertFalse(rendered.contains("10.0.0.1"))
    }

    // Round-5 audit: a post-setup interruption (was serving, now not buyer-serving)
    // is NOT first-run setup; the phase itself must not read as .settingUp.
    func testPostSetupInterruptionIsNotSettingUpPhase() {
        var s = AgentSnapshot.empty
        s.state = .reconnecting
        s.currentModelID = "llama"
        s.networkState = "not_buyer_serving"

        let status = AgentSnapshotPresenter.consolidatedStatus(s)
        XCTAssertNotEqual(status.phase, .settingUp)
        XCTAssertEqual(status.phase, .needsAttention)
    }

    // Round-5 audit: an action-less diagnostic that owns the primary status
    // (software update in progress) must not be overwritten by the earning display
    // on a network-ready provider.
    func testAutoupdateInProgressOnBuyerServingIsNotEarning() {
        var s = buyerServingObservationSnapshot(observedAt: Date())
        s.trustTier = .trusted
        s.diagnosticFindings = [
            ProviderDiagnosticFinding(
                signatureID: .autoupdateInProgress,
                source: .status,
                userMessage: "Provider software update in progress.",
                evidence: "lifecycle.state=update_in_progress",
                observedAt: Date()
            )
        ]

        let status = AgentSnapshotPresenter.consolidatedStatus(s)
        XCTAssertNotEqual(status.phase, .earning)
        XCTAssertEqual(status.phase, .live)
        XCTAssertTrue(status.label.lowercased().contains("update in progress"))
    }

    // Round-5 audit: a live buyer-serving provider that merely has a nonblocking
    // repair-available CTA must not be demoted to needs-attention.
    func testLiveProviderWithNonblockingRepairCTAIsNotNeedsAttention() {
        var s = buyerServingObservationSnapshot(observedAt: Date())
        s.trustTier = .trusted
        s.walletBound = true
        s.malibuProjectionFresh = true
        s.malibuWithdrawable = 3
        s.malibuRewardEligibility = MalibuRewardEligibility(
            earningState: "earning",
            withdrawalState: "withdrawable",
            primaryReason: "earning_verified_work",
            reasons: ["earning_verified_work"]
        )
        enableProtectedProviderSoftwareRepair(&s)
        s.providerSoftwareRepairRecommended = true

        // Sanity: the repair CTA is present but nonblocking on a ready provider.
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(s).executableAction, .repairProviderSoftware)
        let status = AgentSnapshotPresenter.consolidatedStatus(s)
        XCTAssertNotEqual(status.phase, .needsAttention)
    }

    private func buyerServingObservationSnapshot(observedAt: Date) -> AgentSnapshot {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "observation-a"
        snapshot.statusObservedAt = observedAt
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        snapshot.networkState = "buyer_serving"
        snapshot.coordinatorConnected = true
        snapshot.serviceInstanceID = "instance-a"
        return snapshot
    }

    private func enableProtectedProviderSoftwareRepair(_ snapshot: inout AgentSnapshot) {
        snapshot.localStatusContractCompatible = true
        snapshot.localStatusCapabilities = [
            "status_observation_v1",
            ProviderSoftwareRepairCapabilityGate.repairFromProtectedSource,
        ]
        snapshot.statusObservationID = snapshot.statusObservationID ?? "repair-observation"
        snapshot.statusObservedAt = snapshot.statusObservedAt ?? Date()
        snapshot.statusObservationValidForMS = snapshot.statusObservationValidForMS ?? 5_000
        snapshot.statusObservationFresh = true
    }
}
