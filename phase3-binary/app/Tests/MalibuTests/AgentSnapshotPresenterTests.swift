import XCTest
@testable import Malibu

// AUDIT R1 ARCHITECT A1: rendering "not reported yet" must remain distinct
// from authoritative "$0.00" when a supported legacy peer omits telemetry.

final class AgentSnapshotPresenterTests: XCTestCase {
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
        XCTAssertEqual(AgentSnapshotPresenter.dashboardHeadline(s), "Connected")
        XCTAssertEqual(
            AgentSnapshotPresenter.dashboardSubtitle(s),
            "Coordinator connected · buyer-serving status unknown"
        )
        XCTAssertEqual(AgentSnapshotPresenter.stateLine(s), "Connected · buyer-serving status unknown")
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
        XCTAssertEqual(AgentSnapshotPresenter.stateLine(s), "boom")
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
            ("ready", "none", "restart-safe", false),
            ("missing", "repair_from_protected_source", "recovery source available", true),
            ("locked", "unlock_keychain", "unlock and retry", false),
            ("not_logged_in", "login", "sign in and retry", false),
            ("permission_denied", "authorize_keychain", "access denied", false),
            ("corrupt", "repair_from_protected_source", "recovery source available", true),
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
            "Ready · CLI Keychain · signature proven"
        )

        snapshot.coordinatorIdentityAdmissionMode = "exemption"
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityLine(snapshot),
            "Ready locally · coordinator exemption still active"
        )
    }

    func testAdmissionIdentityRecoveryShowsCandidateAndOperatorAction() {
        var snapshot = AgentSnapshot.empty
        snapshot.admissionIdentityState = "recovery_pending"
        snapshot.admissionIdentityPendingPublicKeySHA256 = String(repeating: "a", count: 64)

        let line = AgentSnapshotPresenter.admissionIdentityLine(snapshot)
        XCTAssertTrue(line.contains("Approval required"), line)
        XCTAssertTrue(line.contains("aaaaaaaaaaaa…"), line)
        XCTAssertTrue(line.contains("Activate in Malibu"), line)
        XCTAssertTrue(AgentSnapshotPresenter.canRepairAdmissionIdentity(snapshot))
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityRepairButtonTitle(snapshot),
            "Activate approved identity"
        )
    }

    func testAdmissionIdentityRepairStagesWithoutTerminalAndExplainsApprovalGate() {
        var snapshot = AgentSnapshot.empty
        snapshot.admissionIdentityState = "degraded_previous_key"
        snapshot.localStatusCapabilities = []
        XCTAssertTrue(AgentSnapshotPresenter.canRepairAdmissionIdentity(snapshot))
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityRepairButtonTitle(snapshot),
            "Repair admission identity"
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
            "Activate approved identity"
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
            "Activate approved identity"
        )
    }

    func testAdmissionIdentityRecoveryConfigMismatchIsActionable() {
        XCTAssertEqual(
            AgentSnapshotPresenter.admissionIdentityRecoveryConfigError(
                expectedProviderID: "provider-a",
                configuredProviderID: "provider-b"
            ),
            "Admission identity recovery refused because config provider_id provider-b does not match the active provider provider-a."
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
            "Degraded previous key until 2026-07-21T12:00:00Z · use Repair admission identity"
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
            "Lifecycle lease invalid · watchdog grace disabled"
        )

        snapshot.lifecycleLeaseState = nil
        snapshot.lifecycleRecordState = "missing"
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(snapshot),
            "Lifecycle history missing · provider restart required"
        )
        snapshot.lifecycleRecordState = "invalid"
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(snapshot),
            "Lifecycle history invalid · provider stopped trusting local state"
        )

        snapshot.localStatusContractCompatible = false
        XCTAssertEqual(AgentSnapshotPresenter.statusContractLine(snapshot), "Incompatible · update Malibu")

        snapshot.localStatusContractCompatible = true
        snapshot.statusObservationFresh = false
        XCTAssertEqual(AgentSnapshotPresenter.statusContractLine(snapshot), "Compatible · stale observation")
    }

    func testCompatibilitySetLineDistinguishesSignedAndLegacyReleases() {
        var snapshot = AgentSnapshot.empty
        XCTAssertEqual(
            AgentSnapshotPresenter.compatibilitySetLine(snapshot),
            "Legacy release · compatibility set not reported"
        )

        snapshot.compatibilitySetID = "Augustas11/macprovider:v1.9.0@0123456789abcdef0123456789abcdef01234567"
        snapshot.compatibilitySetSHA256 = String(repeating: "a", count: 64)
        snapshot.catalogReleaseID = "published-2026-07-14"
        XCTAssertEqual(
            AgentSnapshotPresenter.compatibilitySetLine(snapshot),
            "v1.9.0 · published-2026-07-14 · aaaaaaaaaaaa"
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
            "Catalog incompatible or update required · startup catalog incompatible · Check for the signed compatibility update, then retry"
        )

        snapshot.lifecycleState = "watchdog_recovery"
        snapshot.lifecycleReason = "watchdog_rollback_post_start_rejoin_timeout"
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleLine(snapshot),
            "Watchdog recovery · watchdog rollback post start rejoin timeout · No action required while this completes"
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
            "8 buyer slots · advertised to buyers"
        )
        XCTAssertEqual(
            AgentSnapshotPresenter.lifecycleEventLine(event),
            "watchdog rollback post start rejoin timeout · Watchdog recovery · watchdog-recovery:update-1"
        )
    }

    func testObservationExpiryBetweenPollsSuppressesServingRepairAndLifecycle() {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "observation-a"
        snapshot.statusObservedAt = Date().addingTimeInterval(-6)
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
        XCTAssertEqual(AgentSnapshotPresenter.statusContractLine(snapshot), "Compatible · stale observation")
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
}
