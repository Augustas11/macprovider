import Foundation
import XCTest
@testable import Malibu

final class ProviderDiagnosticFindingTests: XCTestCase {
    func testClosedTaxonomyCoversProviderLogDiagnosticIDs() {
        let findings = ProviderLogDiagnostics.diagnoseAll(lines: [
            "provider process unhealthy: launchd service live.malibu.provider has no validated PID at /Users/provider/macprovider-cli",
            "model catalog provenance envelope is stale",
            "model artifact is not admitted by the signed candidate catalog",
            "model artifact is not admitted by the signed rate card",
            "model must match model_catalog_key",
            "model artifact hash mismatch",
            "model artifact verification failed",
            "model_artifact_sha256 requires model_catalog_* provenance",
            "coordinator join requires model_artifact_sha256",
            "model must be the catalog-pinned hugging face snapshot path",
            "auto_update_enabled: false",
            "self-update startup handoff recovery refused: startup handoff does not match target",
            "self-update startup reload fence authorization mismatch: startup_handoff",
            "provider startup preflight failed: startup handoff expired before adoption",
        ])

        XCTAssertFalse(findings.isEmpty)
        for finding in findings {
            XCTAssertNotNil(
                ProviderDiagnosticSignatureID(rawValue: finding.id),
                "log finding id \(finding.id) is not in the closed taxonomy"
            )
        }
    }

    func testClosedTaxonomyCoversExistingProviderLogAggregateIDs() {
        let findings = ProviderLogDiagnostics.diagnoseAll(
            providerLines: [
                "provider process unhealthy: launchd service live.malibu.provider has no validated PID at /Users/provider/macprovider-cli"
            ],
            watchdogLines: [
                "autoupdate recovery_error=acl_write_rejected:/Users/provider"
            ],
            launchdNeedsRepair: true,
            homeDirectory: URL(fileURLWithPath: "/Users/provider")
        )

        XCTAssertEqual(
            findings.map(\.id),
            ["stale_launch_agent", "autoupdate_home_acl_rejected"]
        )
        for finding in findings {
            XCTAssertNotNil(
                ProviderDiagnosticSignatureID(rawValue: finding.id),
                "aggregate log finding id \(finding.id) is not in the closed taxonomy"
            )
        }
    }

    func testFreshStatusFindingsPrecedeSupplementalLogFindings() {
        let now = Date(timeIntervalSince1970: 1_788_249_600)
        var snapshot = freshStatusSnapshot(now: now)
        snapshot.credentialState = "locked"
        snapshot.credentialRecoveryAction = "unlock_keychain"

        let findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot,
            providerLogLines: [
                "provider process unhealthy: launchd service live.malibu.provider has no validated PID at /Users/provider/macprovider-cli"
            ],
            watchdogLogLines: [],
            launchdNeedsRepair: true,
            now: now
        )

        XCTAssertEqual(findings.map(\.signatureID), [.credentialStoreUnavailable, .staleLaunchAgent])
        XCTAssertEqual(findings.map(\.source), [.status, .providerLogDiagnostics])
    }

    func testCredentialStatusSubprocessCannotOverrideFreshServeCredentialState() {
        let now = Date(timeIntervalSince1970: 1_788_249_600)
        var snapshot = freshStatusSnapshot(now: now)
        snapshot.credentialState = "ready"
        snapshot.credentialRestartSafe = true

        let subprocessFinding = ProviderDiagnosticFinding(
            signatureID: .credentialStoreUnavailable,
            source: .credentialsStatus,
            userMessage: "stale subprocess says Keychain unavailable",
            evidence: "condition=unavailable",
            observedAt: now.addingTimeInterval(1)
        )

        let findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot,
            providerLogLines: [],
            watchdogLogLines: [],
            credentialsStatusFindings: [subprocessFinding],
            now: now
        )

        XCTAssertFalse(findings.contains(subprocessFinding))
    }

    func testDiagnosticCredentialSnapshotIsNeverStatusOwned() {
        let now = Date(timeIntervalSince1970: 1_788_249_600)
        var snapshot = freshStatusSnapshot(now: now)
        snapshot.credentialState = "unavailable"
        snapshot.credentialStatusObservedAt = now
        snapshot.credentialStatusFromDiagnostic = true

        let findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot,
            providerLogLines: [],
            watchdogLogLines: [],
            now: now
        )

        XCTAssertFalse(snapshot.hasFreshServeOwnedCredentialState(at: now))
        XCTAssertEqual(findings.map(\.source), [.credentialsStatus])
        XCTAssertEqual(findings.map(\.signatureID), [.credentialStoreUnavailable])
    }

    func testStaleStatusAllowsDoctorServeDeadAndCredentialStatusFallbacks() {
        let now = Date(timeIntervalSince1970: 1_788_249_600)
        var snapshot = freshStatusSnapshot(now: now.addingTimeInterval(-120))
        snapshot.statusObservationFresh = false
        snapshot.credentialState = "ready"

        let doctorServeDead = ProviderDiagnosticFinding(
            signatureID: .serveUnresponsive,
            source: .doctorReport,
            userMessage: "doctor report found serve dead",
            evidence: "serve_dead=true",
            observedAt: now
        )
        let doctorWrongDomain = ProviderDiagnosticFinding(
            signatureID: .catalogAdmission,
            source: .doctorReport,
            userMessage: "doctor report must not own catalog admission",
            evidence: nil,
            observedAt: now
        )
        let credentialFallback = ProviderDiagnosticFinding(
            signatureID: .credentialStoreUnavailable,
            source: .credentialsStatus,
            userMessage: "credential status fallback",
            evidence: "condition=unavailable",
            observedAt: now
        )

        let findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot,
            providerLogLines: [],
            watchdogLogLines: [],
            doctorReportFindings: [doctorServeDead, doctorWrongDomain],
            credentialsStatusFindings: [credentialFallback],
            now: now
        )

        XCTAssertEqual(
            findings.map { "\($0.source.rawValue):\($0.signatureID.rawValue)" },
            [
                "status:serve_unresponsive",
                "doctor_report:serve_unresponsive",
                "credentials_status:credential_store_unavailable",
            ]
        )
    }

    /// #2029 P1-1: findings use the same freshness clock as the ready rows.
    /// A 6 s-old observation is past the CLI's 5 s lease but inside Malibu's
    /// poll retention, so it is current: no "stale" finding, no doctor fallback.
    func testObservationInsidePollRetentionProducesNoStaleFinding() {
        let now = Date(timeIntervalSince1970: 1_788_249_600)
        var snapshot = freshStatusSnapshot(now: now.addingTimeInterval(-6))
        snapshot.credentialState = "ready"
        XCTAssertTrue(snapshot.isLocalStatusObservationCurrent(at: now))

        let doctorServeDead = ProviderDiagnosticFinding(
            signatureID: .serveUnresponsive,
            source: .doctorReport,
            userMessage: "doctor report found serve dead",
            evidence: "serve_dead=true",
            observedAt: now
        )
        let findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot,
            providerLogLines: [],
            watchdogLogLines: [],
            doctorReportFindings: [doctorServeDead],
            now: now
        )
        XCTAssertFalse(findings.contains { $0.signatureID == .serveUnresponsive }, "\(findings)")
    }

    func testObservationPastPollRetentionStillReportsStaleAndAllowsFallback() {
        let now = Date(timeIntervalSince1970: 1_788_249_600)
        let age = LocalStatusObservationPolicy.displayRetentionSeconds + 1
        var snapshot = freshStatusSnapshot(now: now.addingTimeInterval(-age))
        snapshot.credentialState = "ready"
        XCTAssertFalse(snapshot.isLocalStatusObservationCurrent(at: now))

        let doctorServeDead = ProviderDiagnosticFinding(
            signatureID: .serveUnresponsive,
            source: .doctorReport,
            userMessage: "doctor report found serve dead",
            evidence: "serve_dead=true",
            observedAt: now
        )
        let findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot,
            providerLogLines: [],
            watchdogLogLines: [],
            doctorReportFindings: [doctorServeDead],
            now: now
        )
        XCTAssertEqual(
            findings.map { "\($0.source.rawValue):\($0.signatureID.rawValue)" },
            ["status:serve_unresponsive", "doctor_report:serve_unresponsive"]
        )
    }

    func testStaleStatusStillReportsLocalProviderSoftwareRepairInProgress() {
        let now = Date(timeIntervalSince1970: 1_788_249_600)
        var snapshot = freshStatusSnapshot(now: now.addingTimeInterval(-120))
        snapshot.statusObservationFresh = false
        snapshot.providerSoftwareRepairInProgress = true

        let findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot,
            providerLogLines: [],
            watchdogLogLines: [],
            now: now
        )

        XCTAssertEqual(
            findings.map(\.signatureID),
            [.autoupdateInProgress, .serveUnresponsive]
        )
        XCTAssertEqual(
            findings.first?.evidence,
            "malibu.provider_software_repair_in_progress=true"
        )
    }

    func testWithinSourceOrderingUsesSignatureRankBeforeTimestamp() {
        let now = Date(timeIntervalSince1970: 1_788_249_600)
        var snapshot = freshStatusSnapshot(now: now.addingTimeInterval(-120))
        snapshot.statusObservationFresh = false

        let findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot,
            providerLogLines: [],
            watchdogLogLines: [],
            appPollingHistoryFindings: [
                ProviderDiagnosticFinding(
                    signatureID: .serveUnresponsive,
                    source: .appPollingHistory,
                    userMessage: "newer serve finding",
                    evidence: nil,
                    observedAt: now
                ),
                ProviderDiagnosticFinding(
                    signatureID: .credentialStoreUnavailable,
                    source: .appPollingHistory,
                    userMessage: "older credential finding",
                    evidence: nil,
                    observedAt: now.addingTimeInterval(-60)
                ),
            ],
            now: now
        )

        XCTAssertEqual(
            findings.filter { $0.source == .appPollingHistory }.map(\.signatureID),
            [.credentialStoreUnavailable, .serveUnresponsive]
        )
    }

    func testUnknownSignatureIDsAreSkippedWhenMinimumReaderVersionIsSupported() throws {
        let data = Data("""
        {
          "minimum_reader_version": 1,
          "diagnostic_findings": [
            {"signature_id": "future_signature", "source": "status", "message": "future"},
            {"signature_id": "serve_unresponsive", "source": "status", "message": "known"}
          ]
        }
        """.utf8)

        let findings = ProviderDiagnosticFindingAggregator.decodeBundleFindings(data)

        XCTAssertEqual(findings.map(\.signatureID), [.serveUnresponsive])
        XCTAssertEqual(findings.first?.userMessage, "known")
    }

    func testJSONSerializationRedactsCallerSuppliedMessageAndEvidence() throws {
        let finding = ProviderDiagnosticFinding(
            signatureID: .serveUnresponsive,
            source: .doctorReport,
            userMessage: #"serve dead at \/Users\/provider\/provider.log"#,
            evidence: #"file:\/\/\/private\/var\/folders\/provider.log provider_token=must-not-export"#,
            observedAt: Date(timeIntervalSince1970: 1_788_249_600)
        )

        let data = try JSONSerialization.data(withJSONObject: finding.jsonObject)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("serve dead at [path]"), text)
        XCTAssertTrue(text.contains("[redacted]"), text)
        XCTAssertFalse(text.contains(#"\/Users\/provider"#), text)
        XCTAssertFalse(text.contains(#"\/private"#), text)
        XCTAssertFalse(text.contains("must-not-export"), text)
    }

    func testFreshBuyerServingClearsHistoricalStartupFailureButKeepsVerificationAndUpdateWarnings() {
        let now = Date()
        var snapshot = freshStatusSnapshot(now: now)
        let lines = [
            "self-update startup handoff recovery refused: old service target mismatch",
            "model artifact hash mismatch",
            "model catalog provenance envelope is stale",
            "auto_update_enabled: false",
        ]
        var findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot, providerLogLines: lines, watchdogLogLines: [], now: now
        )
        XCTAssertFalse(findings.contains { $0.signatureID == .startupHandoffRecoveryRequired })
        XCTAssertTrue(findings.contains { $0.signatureID == .artifactHashMismatch })
        XCTAssertTrue(findings.contains { $0.signatureID == .staleModelCatalog })
        XCTAssertTrue(findings.contains { $0.signatureID == .autoupdateDisabled })

        snapshot.networkState = "not_buyer_serving"
        findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot, providerLogLines: lines, watchdogLogLines: [], now: now
        )
        XCTAssertTrue(findings.contains { $0.signatureID == .startupHandoffRecoveryRequired })
        snapshot.networkState = "buyer_serving"
        snapshot.cliUpdateInProgress = true
        findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot, providerLogLines: lines, watchdogLogLines: [], now: now
        )
        XCTAssertTrue(findings.contains { $0.signatureID == .startupHandoffRecoveryRequired })
        snapshot.cliUpdateInProgress = false
        snapshot.statusObservationFresh = false
        findings = ProviderDiagnosticFindingAggregator.aggregate(
            snapshot: snapshot, providerLogLines: lines, watchdogLogLines: [], now: now
        )
        XCTAssertTrue(findings.contains { $0.signatureID == .startupHandoffRecoveryRequired })
    }

    func testAvailabilityFindingsNameCurrentCausesAndRecoveryHints() {
        let now = Date()
        let cases: [(String, String?, String, String)] = [
            ("loading_model", nil, "language model is loading", "automatically"),
            ("paused_by_operator", nil, "Provider is paused", "Resume"),
            ("coordinator_unavailable", nil, "coordinator is unreachable", "automatic"),
            ("authentication_required", "provider_token_expired", "provider token expired", "automatically"),
            ("starting_provider", nil, "updating or restarting", "automatically"),
            ("update_in_progress", nil, "updating or restarting", "automatically"),
        ]
        for (state, reason, cause, hint) in cases {
            var snapshot = freshStatusSnapshot(now: now)
            snapshot.lifecycleState = state
            snapshot.lifecycleReason = reason
            snapshot.networkState = "not_buyer_serving"
            snapshot.diagnosticFindings = ProviderDiagnosticFindingAggregator.aggregate(
                snapshot: snapshot, providerLogLines: [], watchdogLogLines: [], now: now
            )
            let lines = AgentSnapshotPresenter.diagnosticFindingLines(snapshot).joined(separator: "\n")
            XCTAssertTrue(lines.contains(cause), lines)
            XCTAssertTrue(lines.contains(hint), lines)
            XCTAssertFalse(lines.contains("Cause unknown"), lines)
            if state == "authentication_required" {
                XCTAssertTrue(AgentSnapshotPresenter.credentialLine(snapshot).contains("provider token expired"))
            }
        }
    }

    func testCreativeHoldFindingsExplainEveryActiveState() {
        let now = Date()
        for state in ["holding_customers", "downloading", "generating", "warm", "restoring"] {
            var snapshot = freshStatusSnapshot(now: now)
            snapshot.localImageGenerationState = state
            snapshot.diagnosticFindings = ProviderDiagnosticFindingAggregator.aggregate(
                snapshot: snapshot, providerLogLines: [], watchdogLogLines: [], now: now
            )
            let lines = AgentSnapshotPresenter.diagnosticFindingLines(snapshot).joined(separator: "\n")
            XCTAssertTrue(lines.contains("Image creation is holding customer work"), lines)
            XCTAssertTrue(lines.contains("Stop Create or wait"), lines)
            XCTAssertFalse(lines.contains("Cause unknown"), lines)
        }
    }

    func testKnownAuthenticationReasonCodesUseSafeDisplayStrings() {
        let now = Date()
        for (reason, expected) in [
            ("authentication_required", "the network requires fresh provider access"),
            ("provider_token_expired", "provider token expired"),
            ("bootstrap_token_expired", "setup access token expired"),
        ] {
            var snapshot = freshStatusSnapshot(now: now)
            snapshot.lifecycleState = "authentication_required"
            snapshot.lifecycleReason = reason
            let cause = AgentSnapshotPresenter.knownAvailabilityCause(snapshot, at: now) ?? ""
            XCTAssertTrue(cause.contains(expected), cause)
            XCTAssertFalse(cause.contains("[redacted]"), cause)
        }
    }

    func testAuthenticationReasonIsRedactedBeforeHumanizing() {
        let now = Date()
        var snapshot = freshStatusSnapshot(now: now)
        snapshot.lifecycleState = "authentication_required"
        snapshot.lifecycleReason = "provider_token=must-not-display"
        let cause = AgentSnapshotPresenter.knownAvailabilityCause(snapshot, at: now) ?? ""
        XCTAssertFalse(cause.contains("must-not-display"), cause)
        XCTAssertTrue(cause.contains("[redacted]"), cause)
    }

    func testExpiredStatusDoesNotReuseOldAvailabilityCause() {
        let now = Date()
        var snapshot = freshStatusSnapshot(now: now.addingTimeInterval(-120))
        snapshot.lifecycleState = "loading_model"
        snapshot.localImageGenerationState = "generating"
        XCTAssertNil(AgentSnapshotPresenter.knownAvailabilityCause(snapshot, at: now))
        snapshot.invalidateLocalStatusObservation()
        XCTAssertNil(snapshot.localImageGenerationState)
        snapshot.cliUpdateInProgress = true
        XCTAssertTrue(AgentSnapshotPresenter.knownAvailabilityCause(snapshot, at: now)?.contains("updating or restarting") == true)
    }

    private func freshStatusSnapshot(now: Date) -> AgentSnapshot {
        var snapshot = AgentSnapshot.empty
        snapshot.state = .serving
        snapshot.localStatusContractCompatible = true
        snapshot.localStatusCapabilities = ["status_observation_v1"]
        snapshot.statusObservationID = "11111111-1111-4111-8111-111111111111"
        snapshot.statusObservedAt = now
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        snapshot.networkState = "buyer_serving"
        snapshot.admissionIdentityState = "ready"
        return snapshot
    }
}
