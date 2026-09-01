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

    func testExpiredStatusLeaseAllowsFallbackEvenWhenUIWouldRetainObservation() {
        let now = Date(timeIntervalSince1970: 1_788_249_600)
        var snapshot = freshStatusSnapshot(now: now.addingTimeInterval(-6))
        snapshot.statusObservationValidForMS = 5_000
        snapshot.statusObservationFresh = true
        snapshot.credentialState = "ready"
        XCTAssertTrue(snapshot.isLocalStatusObservationCurrent(at: now))

        let doctorServeDead = ProviderDiagnosticFinding(
            signatureID: .serveUnresponsive,
            source: .doctorReport,
            userMessage: "doctor report found serve dead",
            evidence: "serve_dead=true",
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
            doctorReportFindings: [doctorServeDead],
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
