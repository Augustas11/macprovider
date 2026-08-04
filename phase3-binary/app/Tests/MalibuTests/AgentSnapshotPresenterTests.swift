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

    func testCoordinatorConnectionWithoutNetworkStateIsNotBuyerServing() {
        var s = AgentSnapshot.empty
        s.state = .serving
        s.coordinatorConnected = true
        s.networkState = nil

        XCTAssertFalse(AgentSnapshotPresenter.isNetworkReady(s))
        XCTAssertEqual(AgentSnapshotPresenter.short(s), "Connected")
        XCTAssertEqual(AgentSnapshotPresenter.dashboardHeadline(s), "Checking customer availability")
        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(s),
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

        var ineligible = AgentSnapshot.empty
        ineligible.state = .reconnecting
        ineligible.currentModelID = "llama"
        ineligible.networkState = "not_buyer_serving"
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(ineligible).title, "This Mac is not currently eligible")

        var preparing = AgentSnapshot.empty
        preparing.state = .starting
        preparing.lifecycleState = "loading_model"
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(preparing).title, "Model is preparing")

        var ready = AgentSnapshot.empty
        ready.state = .serving
        ready.networkState = "buyer_serving"
        XCTAssertEqual(AgentSnapshotPresenter.publicStatus(ready).title, "Provider is ready")
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
        XCTAssertEqual(pendingStatus.safeNextAction, "Retry provider setup while online.")
        XCTAssertEqual(pendingStatus.executableAction, .retryHardwareVerification)
        XCTAssertFalse(pendingStatus.safeNextAction?.contains("macprovider-cli") == true)
        XCTAssertFalse(pendingStatus.detail?.contains("wait for operator approval") == true)
        XCTAssertEqual(AgentSnapshotPresenter.short(pending), "Pending")
        XCTAssertEqual(AgentSnapshotPresenter.modelLine(pending), "llama")
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(pending),
            "Pending hardware verification · Retry provider setup while online"
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
            "Provider software update required · startup catalog incompatible · Update provider software, then retry"
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
            "This Mac is not currently eligible"
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
            "This Mac is not currently eligible"
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
            AgentSnapshotPresenter.dashboardHeadline(snapshot),
            AgentSnapshotPresenter.dashboardSubtitle(snapshot),
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
        XCTAssertEqual(LogTailBuffer.redacted(raw), raw)
    }

    func testOnboardingAdvancedFailureDiagnosticsKeepsRedactedDetails() {
        let details = OnboardingCopy.advancedFailureDiagnostics(
            message: "coordinator join requires model_artifact_sha256 in /tmp/macprovider.err.log",
            installLogLines: ["provider_token: secret-token-value"],
            providerLogLines: ["watchdog recovery started"]
        )

        XCTAssertTrue(details.contains("coordinator join requires model_artifact_sha256 in /tmp/macprovider.err.log"))
        XCTAssertTrue(details.contains("[redacted]"))
        XCTAssertTrue(details.contains("watchdog recovery started"))
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
}
