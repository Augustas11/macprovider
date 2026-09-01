import Foundation

enum ProviderDiagnosticSignatureID: String, CaseIterable, Comparable {
    case staleLaunchAgent = "stale_launch_agent"
    case staleModelCatalog = "stale_model_catalog"
    case catalogAdmission = "catalog_admission"
    case rateCardAdmission = "rate_card_admission"
    case catalogKeyMismatch = "catalog_key_mismatch"
    case artifactHashMismatch = "artifact_hash_mismatch"
    case artifactVerificationFailed = "artifact_verification_failed"
    case missingCatalogProvenance = "missing_catalog_provenance"
    case missingArtifactSHA = "missing_artifact_sha"
    case snapshotPathMismatch = "snapshot_path_mismatch"
    case autoupdateHomeACLRejected = "autoupdate_home_acl_rejected"
    case credentialStoreUnavailable = "credential_store_unavailable"
    case serveUnresponsive = "serve_unresponsive"
    case admissionIdentityBlocked = "admission_identity_blocked"
    case autoupdateInProgress = "autoupdate_in_progress"
    case autoupdateDisabled = "autoupdate_disabled"

    static func < (lhs: ProviderDiagnosticSignatureID, rhs: ProviderDiagnosticSignatureID) -> Bool {
        lhs.rank < rhs.rank
    }

    var rank: Int {
        switch self {
        case .credentialStoreUnavailable: return 0
        case .admissionIdentityBlocked: return 1
        case .autoupdateInProgress: return 2
        case .serveUnresponsive: return 3
        case .staleLaunchAgent: return 4
        case .staleModelCatalog: return 5
        case .catalogAdmission: return 6
        case .rateCardAdmission: return 7
        case .catalogKeyMismatch: return 8
        case .artifactHashMismatch: return 9
        case .artifactVerificationFailed: return 10
        case .missingCatalogProvenance: return 11
        case .missingArtifactSHA: return 12
        case .snapshotPathMismatch: return 13
        case .autoupdateHomeACLRejected: return 14
        case .autoupdateDisabled: return 15
        }
    }
}

struct ProviderDiagnosticFinding: Equatable {
    enum Source: String, Comparable {
        case status = "status"
        case providerLogDiagnostics = "provider_log_diagnostics"
        case doctorReport = "doctor_report"
        case appPollingHistory = "app_polling_history"
        case credentialsStatus = "credentials_status"

        static func < (lhs: Source, rhs: Source) -> Bool {
            lhs.rank < rhs.rank
        }

        var rank: Int {
            switch self {
            case .status: return 0
            case .providerLogDiagnostics: return 1
            case .doctorReport: return 2
            case .appPollingHistory: return 3
            case .credentialsStatus: return 4
            }
        }
    }

    let signatureID: ProviderDiagnosticSignatureID
    let source: Source
    let userMessage: String
    let evidence: String?
    let observedAt: Date?

    var jsonObject: [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "signature_id": signatureID.rawValue,
            "source": source.rawValue,
            "message": LogTailBuffer.redacted(userMessage),
            "evidence": evidence.map(LogTailBuffer.redacted) ?? NSNull(),
            "observed_at": observedAt.map(formatter.string(from:)) ?? NSNull(),
        ]
    }
}

enum ProviderDiagnosticFindingAggregator {
    static func aggregate(
        snapshot: AgentSnapshot,
        providerLogLines: [String],
        watchdogLogLines: [String],
        launchdNeedsRepair: Bool = false,
        doctorReportFindings: [ProviderDiagnosticFinding] = [],
        appPollingHistoryFindings: [ProviderDiagnosticFinding] = [],
        credentialsStatusFindings: [ProviderDiagnosticFinding] = [],
        now: Date = Date()
    ) -> [ProviderDiagnosticFinding] {
        let hasFreshStatus = snapshot.hasFreshContractValidatedStatusObservation(at: now)
        let hasFreshServeOwnedCredentialState = snapshot.hasFreshServeOwnedCredentialState(at: now)
        var findings: [ProviderDiagnosticFinding] = []
        findings.append(contentsOf: statusFindings(snapshot, hasFreshStatus: hasFreshStatus, now: now))
        findings.append(contentsOf: diagnosticCredentialFindings(snapshot, now: now))
        findings.append(contentsOf: logFindings(
            providerLogLines: providerLogLines,
            watchdogLogLines: watchdogLogLines,
            launchdNeedsRepair: launchdNeedsRepair,
            now: now
        ))
        if !hasFreshStatus {
            findings.append(contentsOf: doctorReportFindings.filter { $0.signatureID == .serveUnresponsive })
            findings.append(contentsOf: appPollingHistoryFindings)
        }
        if !hasFreshServeOwnedCredentialState {
            findings.append(contentsOf: credentialsStatusFindings)
        }
        return findings.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            if lhs.signatureID != rhs.signatureID {
                return lhs.signatureID < rhs.signatureID
            }
            return (lhs.observedAt ?? .distantPast) > (rhs.observedAt ?? .distantPast)
        }
    }

    static func decodeBundleFindings(_ data: Data) -> [ProviderDiagnosticFinding] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let minimumReaderVersion = root["minimum_reader_version"] as? Int,
              minimumReaderVersion <= ProviderDiagnosticsBundle.supportedReaderVersion,
              let rawFindings = root["diagnostic_findings"] as? [[String: Any]] else {
            return []
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return rawFindings.compactMap { raw in
            guard let rawID = raw["signature_id"] as? String,
                  let signatureID = ProviderDiagnosticSignatureID(rawValue: rawID),
                  let rawSource = raw["source"] as? String,
                  let source = ProviderDiagnosticFinding.Source(rawValue: rawSource),
                  let message = raw["message"] as? String else {
                return nil
            }
            let observedAt = (raw["observed_at"] as? String).flatMap(formatter.date(from:))
            return ProviderDiagnosticFinding(
                signatureID: signatureID,
                source: source,
                userMessage: message,
                evidence: raw["evidence"] as? String,
                observedAt: observedAt
            )
        }
    }

    private static func statusFindings(
        _ snapshot: AgentSnapshot,
        hasFreshStatus: Bool,
        now: Date
    ) -> [ProviderDiagnosticFinding] {
        guard hasFreshStatus else {
            return [
                ProviderDiagnosticFinding(
                    signatureID: .serveUnresponsive,
                    source: .status,
                    userMessage: "Provider local status is unavailable or stale.",
                    evidence: snapshot.statusObservationID.map { "observation.id=\($0)" },
                    observedAt: snapshot.statusObservedAt ?? now
                )
            ] + localUpdateRepairFindings(snapshot, now: now)
        }
        var findings: [ProviderDiagnosticFinding] = []
        if let credentialState = snapshot.credentialState,
           !snapshot.credentialStatusFromDiagnostic,
           credentialUnavailableStates.contains(credentialState) {
            findings.append(ProviderDiagnosticFinding(
                signatureID: .credentialStoreUnavailable,
                source: .status,
                userMessage: AgentSnapshotPresenter.credentialLine(snapshot),
                evidence: "credential.state=\(credentialState)",
                observedAt: snapshot.statusObservedAt ?? now
            ))
        }
        if let admissionState = snapshot.admissionIdentityState,
           admissionIdentityBlockedStates.contains(admissionState) {
            findings.append(ProviderDiagnosticFinding(
                signatureID: .admissionIdentityBlocked,
                source: .status,
                userMessage: AgentSnapshotPresenter.admissionIdentityLine(snapshot),
                evidence: "admission_identity.state=\(admissionState)",
                observedAt: snapshot.statusObservedAt ?? now
            ))
        }
        if snapshot.lifecycleState == "update_in_progress"
            || snapshot.lifecycleState == "rollback_in_progress"
            || snapshot.cliUpdateInProgress
            || snapshot.providerSoftwareRepairInProgress {
            findings.append(ProviderDiagnosticFinding(
                signatureID: .autoupdateInProgress,
                source: .status,
                userMessage: "Provider software update is in progress.",
                evidence: snapshot.lifecycleState.map { "lifecycle.state=\($0)" }
                    ?? localUpdateRepairEvidence(snapshot),
                observedAt: snapshot.statusObservedAt ?? now
            ))
        }
        switch snapshot.networkState {
        case "not_buyer_serving", "buyer_serving_unknown", "network_offline", "coordinator_unavailable":
            findings.append(ProviderDiagnosticFinding(
                signatureID: .serveUnresponsive,
                source: .status,
                userMessage: "Provider is not confirmed available for customer work.",
                evidence: snapshot.networkState.map { "network_state=\($0)" },
                observedAt: snapshot.statusObservedAt ?? now
            ))
        default:
            break
        }
        return findings
    }

    private static func diagnosticCredentialFindings(
        _ snapshot: AgentSnapshot,
        now: Date
    ) -> [ProviderDiagnosticFinding] {
        guard snapshot.credentialStatusFromDiagnostic,
              snapshot.isCredentialStatusCurrent(at: now),
              let credentialState = snapshot.credentialState,
              credentialUnavailableStates.contains(credentialState) else {
            return []
        }
        return [
            ProviderDiagnosticFinding(
                signatureID: .credentialStoreUnavailable,
                source: .credentialsStatus,
                userMessage: AgentSnapshotPresenter.credentialLine(snapshot),
                evidence: "credential.state=\(credentialState)",
                observedAt: snapshot.credentialStatusObservedAt ?? now
            )
        ]
    }

    private static func localUpdateRepairFindings(
        _ snapshot: AgentSnapshot,
        now: Date
    ) -> [ProviderDiagnosticFinding] {
        guard snapshot.cliUpdateInProgress || snapshot.providerSoftwareRepairInProgress else {
            return []
        }
        return [
            ProviderDiagnosticFinding(
                signatureID: .autoupdateInProgress,
                source: .status,
                userMessage: "Provider software update is in progress.",
                evidence: localUpdateRepairEvidence(snapshot),
                observedAt: snapshot.statusObservedAt ?? now
            )
        ]
    }

    private static func localUpdateRepairEvidence(_ snapshot: AgentSnapshot) -> String? {
        if snapshot.cliUpdateInProgress {
            return "malibu.cli_update_in_progress=true"
        }
        if snapshot.providerSoftwareRepairInProgress {
            return "malibu.provider_software_repair_in_progress=true"
        }
        return nil
    }

    private static func logFindings(
        providerLogLines: [String],
        watchdogLogLines: [String],
        launchdNeedsRepair: Bool,
        now: Date
    ) -> [ProviderDiagnosticFinding] {
        let findings = ProviderLogDiagnostics.diagnoseAll(
            providerLines: providerLogLines,
            watchdogLines: watchdogLogLines,
            launchdNeedsRepair: launchdNeedsRepair
        )
        return findings.compactMap { finding in
            guard let signatureID = ProviderDiagnosticSignatureID(rawValue: finding.id),
                  ProviderLogDiagnostics.isActionable(finding, launchdNeedsRepair: launchdNeedsRepair) else {
                return nil
            }
            return ProviderDiagnosticFinding(
                signatureID: signatureID,
                source: .providerLogDiagnostics,
                userMessage: finding.userMessage,
                evidence: finding.matchedLine,
                observedAt: now
            )
        }
    }

    private static let credentialUnavailableStates: Set<String> = [
        "locked", "not_logged_in", "permission_denied", "keychain_failure", "incompatible", "unavailable",
    ]

    private static let admissionIdentityBlockedStates: Set<String> = [
        "missing", "recovery_pending", "degraded_previous_key", "recovery_required",
    ]
}
