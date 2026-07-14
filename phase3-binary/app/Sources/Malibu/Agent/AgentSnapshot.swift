import Foundation

// AUDIT R1 ARCHITECT A1 / A5 fix.
//
// AgentSnapshot is now a pure domain type — no localized/formatted strings.
// - Earnings/metrics are Optional so "not reported yet" is distinct from "0".
//   Supported legacy CLI peers returned an all-zero tuple; rendering that as
//   authoritative "$0.00" would mask missing telemetry as actual earnings.
// - View strings (menu-bar label, status line, earnings line) live in
//   AgentSnapshotPresenter so future locale/currency work touches one place.

struct AgentSnapshot: Equatable {
    enum State: String { case idle, starting, serving, paused, reconnecting, error }
    enum TrustTier: String, Codable {
        case provisional
        case trusted

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
            self = raw == "trusted" ? .trusted : .provisional
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
    var state: State
    var currentModelID: String?
    var earningsUsdcToday: Double?
    var malibuAccruedToday: Double?
    var unpaidLedgerBacklogUSDC: Double?
    var unpaidLedgerBacklogMALIBU: Double?
    var walletBound: Bool
    var trustTier: TrustTier
    var uptimeSec: Int?
    var requestsServedToday: Int?
    var requestsServedAllTime: Int?
    var requestsPerMinute: Double?
    var inputTokensToday: Int64?
    var outputTokensToday: Int64?
    var inputTokensAllTime: Int64?
    var outputTokensAllTime: Int64?
    var earningsUsdcWeek: Double?
    var earningsUsdcPending: Double?
    var earningsUsdcLifetime: Double?
    var malibuAccruedAllTime: Double?
    var gpuUtilizationPct: Double?
    var gpuTemperatureC: Double?
    var latencyP50Ms: Int?
    var latencyP99Ms: Int?
    var queueDepth: Int?
    var uptime7dPct: Double?
    var declinedRequests: Int?
    var restartCount: Int?
    var weightsPath: String?
    var trustCriteriaMet: Int?
    var trustCriteriaRequired: Int?
    var thermalState: MalibuThermalState?
    var lastError: String?

    var cliVersion: String?
    var compatibilitySetID: String?
    var compatibilitySetSHA256: String?
    var localStatusContractVersion: Int?
    var localStatusMinimumReaderVersion: Int?
    var localStatusContractCompatible: Bool?
    var localStatusLifecycleOwner: String?
    var localStatusCapabilities: Set<String>
    var localProviderID: String?
    var statusObservationID: String?
    var statusObservedAt: Date?
    var statusObservationValidForMS: Int?
    var statusObservationFresh: Bool?
    var serviceInstanceID: String?
    var servicePID: Int?
    var serviceBootSession: String?
    var serviceStartedAt: Date?
    var serviceRole: String?
    var lifecycleRecordState: String?
    var lifecycleSequence: Int64?
    var lifecycleTransitionID: String?
    var lifecycleTransitionAt: Date?
    var lifecycleState: String?
    var lifecycleReason: String?
    var lifecycleAuthority: String?
    var lifecycleWriter: String?
    var lifecycleOperationID: String?
    var lifecycleOperatorPaused: Bool?
    var lifecycleLastRestart: ProviderLifecycleEventSnapshot?
    var lifecycleLastRejection: ProviderLifecycleEventSnapshot?
    var lifecycleLastUpdate: ProviderLifecycleEventSnapshot?
    var lifecycleLastWatchdog: ProviderLifecycleEventSnapshot?
    var lifecycleLeaseState: String?
    var lifecycleLeaseKind: String?
    var lifecycleLeaseOperationID: String?
    var lifecycleLeaseExpiresWallMS: Int64?
    var credentialSource: String?
    var credentialState: String?
    var credentialRestartSafe: Bool?
    var credentialMigrationPending: Bool?
    var credentialRecoveryAction: String?
    var credentialStatusObservedAt: Date?
    var credentialStatusFromDiagnostic: Bool
    var credentialRepairInProgress: Bool
    var credentialRepairLastError: String?
    var admissionIdentitySource: String?
    var admissionIdentityState: String?
    var admissionIdentityPublicKeySHA256: String?
    var admissionIdentityPendingPublicKeySHA256: String? = nil
    var admissionIdentityPreviousPublicKeySHA256: String? = nil
    var admissionIdentityPreviousValidUntil: Date? = nil
    var admissionIdentityCoordinatorGeneration: Int? = nil
    var admissionIdentityCoordinatorPublicKeySHA256: String? = nil
    var admissionIdentityCoordinatorKeyRole: String? = nil
    var admissionIdentityTransitionError: String? = nil
    var admissionIdentityRecoveryAction: String? = nil
    var admissionIdentityRecoveryInProgress: Bool = false
    var admissionIdentityRecoveryLastError: String? = nil
    var admissionIdentityRecoveryApprovalInstruction: String? = nil
    var admissionIdentityRecoveryOperatorRequest: String? = nil
    var admissionIdentityRecoveryJournalState: String? = nil
    var coordinatorIdentityAdmissionMode: String?
    /// Whether macprovider-cli reports an active coordinator WebSocket session.
    /// Distinct from verified buyer-serving readiness.
    var coordinatorConnected: Bool?
    /// Canonical provider state reported by /v1/status. `buyer_serving` is the
    /// only state backed by the coordinator's routing-readiness verdict.
    var networkState: String?
    var advertisedMaxConcurrency: Int?
    var catalogState: String?
    var catalogReleaseID: String?
    var catalogDigest: String?
    var catalogSignerKeyID: String?
    var catalogSource: String?
    var coordinatorRecommendedVersion: String?
    var latestReleaseVersion: String?
    var cliUpdateInProgress: Bool
    var cliUpdateLastError: String?

    // Whether the CLI has explicitly acknowledged a pause; distinct from
    // "we optimistically flipped the UI" — pauseAck accepted:false must NOT
    // leave the UI showing Paused.
    var pauseAcknowledged: Bool

    mutating func markCoordinatorReadinessUnknown() {
        networkState = "buyer_serving_unknown"
    }

    func isLocalStatusObservationCurrent(at now: Date = Date()) -> Bool {
        guard localStatusCapabilities.contains("status_observation_v1") else { return true }
        guard statusObservationFresh != false,
              let observationID = statusObservationID,
              !observationID.isEmpty,
              let observedAt = statusObservedAt,
              let validForMS = statusObservationValidForMS,
              (1...60_000).contains(validForMS) else {
            return false
        }
        return observedAt <= now.addingTimeInterval(1)
            && observedAt.addingTimeInterval(Double(validForMS) / 1_000) >= now
    }

    func isCredentialStatusCurrent(at now: Date = Date()) -> Bool {
        if credentialStatusFromDiagnostic {
            guard let credentialStatusObservedAt else { return false }
            let age = now.timeIntervalSince(credentialStatusObservedAt)
            return age >= -1 && age <= 60
        }
        return isLocalStatusObservationCurrent(at: now)
    }

    mutating func invalidateLocalStatusObservation() {
        if localStatusCapabilities.contains("status_observation_v1") {
            statusObservationFresh = false
        }
        serviceInstanceID = nil
        servicePID = nil
        serviceBootSession = nil
        serviceStartedAt = nil
        serviceRole = nil
        lifecycleRecordState = nil
        lifecycleSequence = nil
        lifecycleTransitionID = nil
        lifecycleTransitionAt = nil
        lifecycleState = nil
        lifecycleReason = nil
        lifecycleAuthority = nil
        lifecycleWriter = nil
        lifecycleOperationID = nil
        lifecycleOperatorPaused = nil
        lifecycleLastRestart = nil
        lifecycleLastRejection = nil
        lifecycleLastUpdate = nil
        lifecycleLastWatchdog = nil
        lifecycleLeaseState = nil
        lifecycleLeaseKind = nil
        lifecycleLeaseOperationID = nil
        lifecycleLeaseExpiresWallMS = nil
        credentialSource = nil
        credentialState = nil
        credentialRestartSafe = nil
        credentialMigrationPending = nil
        credentialRecoveryAction = nil
        credentialStatusObservedAt = nil
        credentialStatusFromDiagnostic = false
        admissionIdentitySource = nil
        admissionIdentityState = nil
        admissionIdentityPublicKeySHA256 = nil
        admissionIdentityPendingPublicKeySHA256 = nil
        admissionIdentityPreviousPublicKeySHA256 = nil
        admissionIdentityPreviousValidUntil = nil
        admissionIdentityCoordinatorGeneration = nil
        admissionIdentityCoordinatorPublicKeySHA256 = nil
        admissionIdentityCoordinatorKeyRole = nil
        admissionIdentityTransitionError = nil
        admissionIdentityRecoveryAction = nil
        coordinatorIdentityAdmissionMode = nil
        coordinatorConnected = nil
        networkState = "buyer_serving_unknown"
        catalogState = nil
        catalogReleaseID = nil
        catalogDigest = nil
        catalogSignerKeyID = nil
        catalogSource = nil
        compatibilitySetID = nil
        compatibilitySetSHA256 = nil
        coordinatorRecommendedVersion = nil
    }

    static let empty = AgentSnapshot(
        state: .idle,
        currentModelID: nil,
        earningsUsdcToday: nil,
        malibuAccruedToday: nil,
        unpaidLedgerBacklogUSDC: nil,
        unpaidLedgerBacklogMALIBU: nil,
        walletBound: false,
        trustTier: .provisional,
        uptimeSec: nil,
        requestsServedToday: nil,
        requestsServedAllTime: nil,
        requestsPerMinute: nil,
        inputTokensToday: nil,
        outputTokensToday: nil,
        inputTokensAllTime: nil,
        outputTokensAllTime: nil,
        earningsUsdcWeek: nil,
        earningsUsdcPending: nil,
        earningsUsdcLifetime: nil,
        malibuAccruedAllTime: nil,
        gpuUtilizationPct: nil,
        gpuTemperatureC: nil,
        latencyP50Ms: nil,
        latencyP99Ms: nil,
        queueDepth: nil,
        uptime7dPct: nil,
        declinedRequests: nil,
        restartCount: nil,
        weightsPath: nil,
        trustCriteriaMet: nil,
        trustCriteriaRequired: nil,
        thermalState: nil,
        lastError: nil,
        cliVersion: nil,
        compatibilitySetID: nil,
        compatibilitySetSHA256: nil,
        localStatusContractVersion: nil,
        localStatusMinimumReaderVersion: nil,
        localStatusContractCompatible: nil,
        localStatusLifecycleOwner: nil,
        localStatusCapabilities: [],
        localProviderID: nil,
        statusObservationID: nil,
        statusObservedAt: nil,
        statusObservationValidForMS: nil,
        statusObservationFresh: nil,
        serviceInstanceID: nil,
        servicePID: nil,
        serviceBootSession: nil,
        serviceStartedAt: nil,
        serviceRole: nil,
        lifecycleRecordState: nil,
        lifecycleSequence: nil,
        lifecycleTransitionID: nil,
        lifecycleTransitionAt: nil,
        lifecycleState: nil,
        lifecycleReason: nil,
        lifecycleAuthority: nil,
        lifecycleWriter: nil,
        lifecycleOperationID: nil,
        lifecycleOperatorPaused: nil,
        lifecycleLastRestart: nil,
        lifecycleLastRejection: nil,
        lifecycleLastUpdate: nil,
        lifecycleLastWatchdog: nil,
        lifecycleLeaseState: nil,
        lifecycleLeaseKind: nil,
        lifecycleLeaseOperationID: nil,
        lifecycleLeaseExpiresWallMS: nil,
        credentialSource: nil,
        credentialState: nil,
        credentialRestartSafe: nil,
        credentialMigrationPending: nil,
        credentialRecoveryAction: nil,
        credentialStatusObservedAt: nil,
        credentialStatusFromDiagnostic: false,
        credentialRepairInProgress: false,
        credentialRepairLastError: nil,
        admissionIdentitySource: nil,
        admissionIdentityState: nil,
        admissionIdentityPublicKeySHA256: nil,
        coordinatorIdentityAdmissionMode: nil,
        coordinatorConnected: nil,
        networkState: nil,
        advertisedMaxConcurrency: nil,
        catalogState: nil,
        catalogReleaseID: nil,
        catalogDigest: nil,
        catalogSignerKeyID: nil,
        catalogSource: nil,
        coordinatorRecommendedVersion: nil,
        latestReleaseVersion: nil,
        cliUpdateInProgress: false,
        cliUpdateLastError: nil,
        pauseAcknowledged: false
    )
}

enum AgentSnapshotPresenter {
    private static func isActive(_ s: AgentSnapshot) -> Bool {
        s.state == .serving || s.state == .paused || isLocalOnly(s)
    }

    static func isNetworkReady(_ s: AgentSnapshot) -> Bool {
        guard s.state == .serving else { return false }
        return s.isLocalStatusObservationCurrent() && s.networkState == "buyer_serving"
    }

    private static func isLocalOnly(_ s: AgentSnapshot) -> Bool {
        s.state == .reconnecting && s.currentModelID != nil
    }

    private static func authoritativeLifecycleLabel(_ s: AgentSnapshot) -> String? {
        guard s.isLocalStatusObservationCurrent(), let state = s.lifecycleState else { return nil }
        return lifecycleStateLabel(state)
    }

    static func short(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle: return s.lifecycleState == "uninstalled" ? "Uninstalled" : "Stopped"
        case .starting: return "Starting"
        case .serving:
            guard isNetworkReady(s) else { return "Connected" }
            if let usdc = s.earningsUsdcToday { return String(format: "$%.2f", usdc) }
            return "Serving"
        case .paused:         return "Paused"
        case .reconnecting:   return s.networkState == "network_offline" ? "Offline" : "Reconnect"
        case .error:
            switch s.lifecycleState {
            case "authentication_required": return "Auth"
            case "keychain_unavailable": return "Keychain"
            case "identity_migration_required": return "Identity"
            case "catalog_incompatible": return "Catalog"
            default: return "Failed"
            }
        }
    }

    static func dashboardHeadline(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle:         return authoritativeLifecycleLabel(s) ?? "Provider stopped"
        case .starting:     return authoritativeLifecycleLabel(s) ?? "Starting provider…"
        case .serving:
            return isNetworkReady(s) ? "Serving" : "Connected"
        case .paused:       return "Paused"
        case .reconnecting:
            return authoritativeLifecycleLabel(s) ?? (isLocalOnly(s) ? "Local only" : "Reconnecting to coordinator…")
        case .error:        return authoritativeLifecycleLabel(s) ?? "Provider failed"
        }
    }

    static func dashboardSubtitle(_ s: AgentSnapshot) -> String? {
        switch s.state {
        case .serving where !isNetworkReady(s):
            return "Coordinator connected · buyer-serving status unknown"
        case .serving where s.earningsUsdcToday == nil:
            return "Connected to coordinator · waiting for first paid job"
        case .serving:
            return s.currentModelID
        case .reconnecting where isLocalOnly(s):
            return s.lastError ?? "Model loaded locally · reconnecting to coordinator"
        case .reconnecting:
            return s.lastError ?? "Checking background provider…"
        case .starting:
            return s.lastError ?? "Waiting for the background provider to respond…"
        case .error:
            return s.lastError
        default:
            return nil
        }
    }

    static func stateLine(_ s: AgentSnapshot) -> String {
        switch s.state {
        case .idle:         return authoritativeLifecycleLabel(s) ?? "Provider stopped"
        case .starting:     return authoritativeLifecycleLabel(s) ?? "Starting provider…"
        case .serving:
            if isNetworkReady(s) {
                return "Serving " + (s.currentModelID ?? "model")
            }
            return "Connected · buyer-serving status unknown"
        case .paused:       return "Paused"
        case .reconnecting:
            if let label = authoritativeLifecycleLabel(s) {
                return label
            }
            if isLocalOnly(s) {
                return "Local only · " + (s.currentModelID ?? "model loaded")
            }
            return "Reconnecting…"
        case .error:        return authoritativeLifecycleLabel(s) ?? s.lastError ?? "Provider failed"
        }
    }

    static func earningsLine(_ s: AgentSnapshot) -> String {
        switch (s.earningsUsdcToday, s.malibuAccruedToday) {
        case (nil, nil):
            if isActive(s) {
                return "Today: $0.00 USDC · 0.00 MALIBU (no jobs yet)"
            }
            return "Today: not running"
        case let (usdc?, malibu?):
            return String(format: "Today: $%.2f USDC · %@", usdc, malibuDisplay(malibu, tier: s.trustTier))
        case let (usdc?, nil):
            return String(format: "Today: $%.2f USDC · 0.00 MALIBU", usdc)
        case let (nil, malibu?):
            return "Today: $0.00 USDC · \(malibuDisplay(malibu, tier: s.trustTier))"
        }
    }

    static func backlogLine(_ s: AgentSnapshot) -> String? {
        guard s.walletBound == false,
              let usdc = s.unpaidLedgerBacklogUSDC,
              let malibu = s.unpaidLedgerBacklogMALIBU,
              usdc + malibu > 0 else {
            return nil
        }
        return String(format: "Unclaimed: $%.2f USDC · %@", usdc, malibuDisplay(malibu, tier: s.trustTier))
    }

    static func modelLine(_ s: AgentSnapshot) -> String {
        if let model = s.currentModelID { return model }
        if isNetworkReady(s) { return "Connected" }
        if isLocalOnly(s) { return "Local only" }
        return isActive(s) ? "Connected" : "Not running"
    }

    static func credentialLine(_ s: AgentSnapshot) -> String {
        guard s.isCredentialStatusCurrent() else {
            return "Credential status expired · checking again"
        }
        switch s.credentialState {
        case "ready":
            return s.credentialRestartSafe == true
                ? "Ready · restart-safe CLI Keychain custody"
                : "Ready · restart safety not confirmed"
        case "missing":
            return s.credentialRecoveryAction == "repair_from_protected_source"
                ? "Missing · protected recovery source available"
                : "Missing · restore custody or re-enroll"
        case "locked":
            return "Login Keychain locked · unlock and retry"
        case "not_logged_in":
            return "Login Keychain unavailable · sign in and retry"
        case "permission_denied":
            return "Keychain access denied · authorize the provider CLI"
        case "corrupt":
            return s.credentialRecoveryAction == "repair_from_protected_source"
                ? "Corrupt · protected recovery source available"
                : "Corrupt · restore custody or re-enroll"
        case "conflict":
            return "Credential conflict · automatic repair refused"
        case "keychain_failure":
            return "Keychain database failure · repair Keychain before retrying"
        case "incompatible":
            return "Provider CLI lacks Keychain access · update or reinstall"
        case "degraded":
            return "Degraded · using a compatibility source"
        case "unavailable":
            return "Keychain unavailable · retry"
        case "unconfigured":
            return "Not configured"
        case .some(let state):
            return "Unknown credential condition (\(state))"
        case nil:
            return "Not reported by this provider version"
        }
    }

    static func canRepairCredential(_ s: AgentSnapshot) -> Bool {
        s.isCredentialStatusCurrent()
            && s.credentialRecoveryAction == "repair_from_protected_source"
            && !s.credentialRepairInProgress
    }

    static func admissionIdentityLine(_ s: AgentSnapshot) -> String {
        if s.admissionIdentityRecoveryJournalState == "approval_required" {
            let candidate = abbreviatedDigest(
                s.admissionIdentityPendingPublicKeySHA256 ?? s.admissionIdentityPublicKeySHA256
            )
            return "Approval required · candidate \(candidate) · approve via coordinator, then Activate in Malibu"
        }
        if s.admissionIdentityRecoveryJournalState == "committed_cleanup" {
            return "Recovery committed · finalize the local recovery journal"
        }
        guard s.isLocalStatusObservationCurrent() else {
            return "Admission identity expired · checking again"
        }
        switch (s.admissionIdentityState, s.coordinatorIdentityAdmissionMode) {
        case ("ready", "signature"):
            return "Ready · CLI Keychain · signature proven"
        case ("ready", "exemption"):
            return "Ready locally · coordinator exemption still active"
        case ("ready", _):
            return "Ready · CLI Keychain · admission proof pending"
        case ("missing", _):
            return "Missing · re-enrollment or audited recovery required"
        case ("recovery_pending", _):
            let candidate = abbreviatedDigest(s.admissionIdentityPendingPublicKeySHA256 ?? s.admissionIdentityPublicKeySHA256)
            return "Approval required · candidate \(candidate) · approve via coordinator, then Activate in Malibu"
        case ("degraded_previous_key", _):
            let deadline = s.admissionIdentityPreviousValidUntil.map(ISO8601DateFormatter().string(from:))
                ?? "expiry unknown"
            return "Degraded previous key until \(deadline) · use Repair admission identity"
        case ("recovery_required", _):
            return "Recovery required · \(s.admissionIdentityTransitionError ?? s.admissionIdentityRecoveryAction ?? "run macprovider-cli recovery")"
        case ("unconfigured", _), (nil, _):
            return "Not reported by this provider version"
        case (.some(let state), _):
            return "Admission identity condition: \(state)"
        }
    }

    static func canRepairAdmissionIdentity(_ s: AgentSnapshot) -> Bool {
        guard !s.admissionIdentityRecoveryInProgress else { return false }
        if ["approval_required", "committed_cleanup"]
            .contains(s.admissionIdentityRecoveryJournalState) {
            return true
        }
        guard s.isLocalStatusObservationCurrent() else { return false }
        return ["degraded_previous_key", "missing", "recovery_required", "recovery_pending"]
            .contains(s.admissionIdentityState)
    }

    static func admissionIdentityRepairButtonTitle(_ s: AgentSnapshot) -> String {
        if ["approval_required", "committed_cleanup"]
            .contains(s.admissionIdentityRecoveryJournalState)
            || s.admissionIdentityState == "recovery_pending" {
            return "Activate approved identity"
        }
        return "Repair admission identity"
    }

    static func admissionIdentityRecoveryConfigError(
        expectedProviderID: String?,
        configuredProviderID: String?
    ) -> String? {
        guard let expectedProviderID, !expectedProviderID.isEmpty else {
            return "Admission identity recovery requires a current provider identity observation."
        }
        guard let configuredProviderID, !configuredProviderID.isEmpty else {
            return "Admission identity recovery requires ~/.config/macprovider/config.yaml with provider_id \(expectedProviderID)."
        }
        guard configuredProviderID == expectedProviderID else {
            return "Admission identity recovery refused because config provider_id \(configuredProviderID) does not match the active provider \(expectedProviderID)."
        }
        return nil
    }

    private static func abbreviatedDigest(_ digest: String?) -> String {
        guard let digest, digest.count >= 12 else { return digest ?? "unknown" }
        return String(digest.prefix(12)) + "…"
    }

    static func statusContractLine(_ s: AgentSnapshot) -> String {
        if s.localStatusContractCompatible == false {
            return "Incompatible · update Malibu"
        }
        if !s.isLocalStatusObservationCurrent() {
            return "Compatible · stale observation"
        }
        guard let version = s.localStatusContractVersion else {
            return "Legacy provider status"
        }
        let owner = s.localStatusLifecycleOwner ?? "owner not reported"
        return "v\(version) · \(owner)"
    }

    static func serviceInstanceLine(_ s: AgentSnapshot) -> String? {
        guard s.isLocalStatusObservationCurrent() else { return nil }
        guard let instanceID = s.serviceInstanceID else { return nil }
        let shortID = String(instanceID.prefix(8))
        var parts = [s.serviceRole ?? "serve"]
        if let pid = s.servicePID {
            parts.append("PID \(pid)")
        }
        parts.append(shortID)
        return parts.joined(separator: " · ")
    }

    static func lifecycleLine(_ s: AgentSnapshot) -> String? {
        guard s.isLocalStatusObservationCurrent() else { return nil }
        if s.lifecycleLeaseState == "active" {
            let label = s.lifecycleLeaseKind == "maintenance" ? "Update or repair in progress" : "Starting provider"
            if let operation = s.lifecycleLeaseOperationID {
                return "\(label) · \(operation.replacingOccurrences(of: "_", with: " "))"
            }
            return label
        }
        if s.lifecycleLeaseState == "invalid" {
            return "Lifecycle lease invalid · watchdog grace disabled"
        }
        if s.lifecycleRecordState == "missing" {
            return "Lifecycle history missing · provider restart required"
        }
        if s.lifecycleRecordState == "invalid" {
            return "Lifecycle history invalid · provider stopped trusting local state"
        }
        guard let state = s.lifecycleState else { return nil }
        let label = lifecycleStateLabel(state)
        var parts = [label]
        if let reason = s.lifecycleReason {
            parts.append(reason.replacingOccurrences(of: "_", with: " "))
        }
        if let guidance = lifecycleGuidance(state) {
            parts.append(guidance)
        }
        return parts.joined(separator: " · ")
    }

    static func lifecycleEventLine(_ event: ProviderLifecycleEventSnapshot) -> String {
        var parts = [event.reason.replacingOccurrences(of: "_", with: " ")]
        parts.append(lifecycleStateLabel(event.state))
        if let operationID = event.operationID {
            parts.append(operationID)
        }
        return parts.joined(separator: " · ")
    }

    static func advertisedCapacityLine(_ s: AgentSnapshot) -> String {
        let capacity = s.advertisedMaxConcurrency.map { value in
            "\(value) buyer slot\(value == 1 ? "" : "s")"
        } ?? "Capacity not reported"
        switch s.networkState {
        case "buyer_serving":
            return "\(capacity) · advertised to buyers"
        case "buyer_serving_unknown", nil:
            return "\(capacity) · advertisement unconfirmed"
        default:
            return "\(capacity) · not advertised"
        }
    }

    private static func lifecycleStateLabel(_ state: String) -> String {
        switch state {
        case "installing": return "Installing provider"
        case "importing_credentials": return "Importing credentials"
        case "starting_provider": return "Starting provider"
        case "validating_catalog": return "Validating catalog"
        case "loading_model": return "Loading model"
        case "locally_ready_connecting": return "Locally ready, connecting to coordinator"
        case "authentication_required": return "Authentication missing or expired"
        case "keychain_unavailable": return "Keychain locked or permission denied"
        case "identity_migration_required": return "Identity migration required"
        case "catalog_incompatible": return "Catalog incompatible or update required"
        case "serving_buyers": return "Serving buyers"
        case "update_in_progress": return "Update in progress"
        case "rollback_in_progress": return "Rollback in progress"
        case "paused_by_operator": return "Paused by operator"
        case "watchdog_recovery": return "Watchdog recovery"
        case "network_offline": return "Network offline"
        case "coordinator_unavailable": return "Coordinator unavailable"
        case "degraded_serving": return "Degraded but still serving"
        case "failed": return "Failed"
        case "uninstalled": return "Uninstalled"
        default: return state
        }
    }

    private static func lifecycleGuidance(_ state: String) -> String? {
        switch state {
        case "authentication_required":
            return "Use Repair credential"
        case "keychain_unavailable":
            return "Unlock or authorize Keychain, then retry Repair credential"
        case "identity_migration_required":
            return "Use Repair admission identity"
        case "catalog_incompatible":
            return "Check for the signed compatibility update, then retry"
        case "paused_by_operator":
            return "Choose Resume when ready"
        case "network_offline":
            return "Restore network; reconnect is automatic"
        case "coordinator_unavailable":
            return "Reconnect is automatic"
        case "watchdog_recovery", "update_in_progress", "rollback_in_progress":
            return "No action required while this completes"
        case "failed":
            return "Use the offered Repair action or export redacted diagnostics"
        default:
            return nil
        }
    }

    static func compatibilitySetLine(_ s: AgentSnapshot) -> String {
        guard let identifier = s.compatibilitySetID else {
            return "Legacy release · compatibility set not reported"
        }
        let version = identifier.split(separator: ":").last?.split(separator: "@").first.map(String.init)
            ?? "signed set"
        let digest = s.compatibilitySetSHA256.map { String($0.prefix(12)) } ?? "digest unavailable"
        let catalog = s.catalogReleaseID ?? "catalog unavailable"
        return "\(version) · \(catalog) · \(digest)"
    }

    static func requestsLine(_ s: AgentSnapshot) -> String {
        [
            s.requestsServedToday.map { "\(formatCount($0)) today" }
                ?? (isActive(s) ? "0 today" : "n/a today"),
            s.requestsServedAllTime.map { "\(formatCount($0)) all-time" }
                ?? (isActive(s) ? "0 all-time" : "n/a all-time"),
            s.requestsPerMinute.map { String(format: "%.1f req/min", $0) }
                ?? (isActive(s) ? "0.0 req/min" : "n/a req/min")
        ].joined(separator: " · ")
    }

    static func tokenLine(_ s: AgentSnapshot) -> String {
        let today = tokenPair(input: s.inputTokensToday, output: s.outputTokensToday, suffix: "today")
        let allTime = tokenPair(input: s.inputTokensAllTime, output: s.outputTokensAllTime, suffix: "all-time")
        return "\(today)\n\(allTime)"
    }

    static func usdcFullLine(_ s: AgentSnapshot) -> String {
        let unset = isActive(s) ? "$0.00" : "n/a"
        return [
            s.earningsUsdcToday.map { String(format: "$%.2f today", $0) } ?? "\(unset) today",
            s.earningsUsdcWeek.map { String(format: "$%.2f wk", $0) } ?? "\(unset) wk",
            s.earningsUsdcPending.map { String(format: "$%.2f pending", $0) } ?? "\(unset) pending",
            s.earningsUsdcLifetime.map { String(format: "$%.2f life", $0) } ?? "\(unset) life"
        ].joined(separator: " · ")
    }

    static func usdcTodayDisplay(_ s: AgentSnapshot) -> String {
        s.earningsUsdcToday.map { String(format: "$%.2f", $0) } ?? (isActive(s) ? "$0.00" : "n/a")
    }

    static func malibuFullLine(_ s: AgentSnapshot) -> String {
        let today = s.malibuAccruedToday.map { malibuDisplay($0, tier: s.trustTier, compact: true) }
            ?? (isActive(s) ? "0.00 MALIBU today" : "n/a MALIBU today")
        let allTime = s.malibuAccruedAllTime.map { String(format: "%.2f all-time", $0) }
            ?? (isActive(s) ? "0.00 all-time" : "n/a all-time")
        switch s.trustTier {
        case .trusted:
            return "\(today) · \(allTime)"
        case .provisional:
            return "\(today) · \(allTime) · [locked] unlocks at Trusted"
        }
    }

    static func trustLine(_ s: AgentSnapshot) -> String {
        let tier = s.trustTier.rawValue.capitalized
        if let met = s.trustCriteriaMet, let required = s.trustCriteriaRequired {
            return "\(tier) — \(met) of \(required) criteria met · Unlock Trusted →"
        }
        return tier
    }

    static func uptimeLine(_ s: AgentSnapshot) -> String {
        var parts: [String] = []
        if let sec = s.uptimeSec, isActive(s) {
            parts.append("\(formatDuration(sec)) up")
        } else if isActive(s) {
            parts.append("uptime n/a")
        }
        if let pct = s.uptime7dPct {
            parts.append(String(format: "%.1f%% uptime (7d)", pct))
        } else if isActive(s) {
            parts.append("7d uptime n/a")
        }
        parts.append(s.declinedRequests.map { "\($0) declined" } ?? (isActive(s) ? "0 declined" : "n/a declined"))
        parts.append(s.restartCount.map { "\($0) restarts" } ?? (isActive(s) ? "0 restarts" : "n/a restarts"))
        return parts.joined(separator: " · ")
    }

    static func gpuChip(_ s: AgentSnapshot) -> String {
        if let util = s.gpuUtilizationPct {
            return String(format: "GPU %.0f%%", util)
        }
        if let temp = s.gpuTemperatureC {
            return String(format: "GPU %.0f°C", temp)
        }
        return "GPU n/a"
    }

    static func latencyChip(_ s: AgentSnapshot) -> String {
        switch (s.latencyP50Ms, s.latencyP99Ms) {
        case let (p50?, p99?):
            return "p50 \(p50)ms · p99 \(p99)ms"
        case let (p50?, nil):
            return "p50 \(p50)ms · p99 n/a"
        case let (nil, p99?):
            return "p50 n/a · p99 \(p99)ms"
        case (nil, nil):
            return isActive(s) ? "Latency n/a" : "Latency n/a"
        }
    }

    static func queueChip(_ s: AgentSnapshot) -> String {
        if let depth = s.queueDepth { return "\(depth) queued" }
        return isActive(s) ? "0 queued" : "Queue n/a"
    }

    static func thermalChip(_ s: AgentSnapshot) -> String {
        s.thermalState?.label ?? (isActive(s) ? "Thermal OK" : "Thermal n/a")
    }

    static func unclaimedBadge(_ s: AgentSnapshot, dismissedThreshold: Double?) -> String? {
        guard let total = unclaimedBacklogTotal(s),
              let threshold = UnclaimedBadgePolicy.visibleThreshold(
                totalBacklog: total,
                dismissedThreshold: dismissedThreshold
              ) else {
            return nil
        }
        return threshold >= 100 ? "$100+" : String(format: "$%.0f+", threshold)
    }

    static func unclaimedBacklogTotal(_ s: AgentSnapshot) -> Double? {
        guard s.walletBound == false else { return nil }
        let total = (s.unpaidLedgerBacklogUSDC ?? 0) + (s.unpaidLedgerBacklogMALIBU ?? 0)
        return total > 0 ? total : nil
    }

    static func updateTargetVersion(_ s: AgentSnapshot) -> String? {
        ProviderCLIVersion.updateTarget(
            current: s.cliVersion,
            recommended: s.coordinatorRecommendedVersion,
            latestRelease: s.latestReleaseVersion
        )
    }

    static func updateAvailable(_ s: AgentSnapshot) -> Bool {
        updateTargetVersion(s) != nil
    }

    static func updateBadge(_ s: AgentSnapshot) -> String? {
        guard updateAvailable(s), !s.cliUpdateInProgress else { return nil }
        return "↑"
    }

    static func cliVersionLine(_ s: AgentSnapshot) -> String {
        guard let current = s.cliVersion else {
            return isActive(s) ? "Version unknown" : "Not running"
        }
        var parts = ["v\(current)"]
        if let target = updateTargetVersion(s) {
            parts.append("→ v\(target) available")
        } else if let latest = s.latestReleaseVersion {
            parts.append("latest v\(latest)")
        } else if let recommended = s.coordinatorRecommendedVersion {
            parts.append("coordinator v\(recommended)")
        } else {
            parts.append("up to date")
        }
        return parts.joined(separator: " · ")
    }

    static func cliUpdateStatusLine(_ s: AgentSnapshot) -> String? {
        if s.cliUpdateInProgress {
            return "Updating provider CLI…"
        }
        if let error = s.cliUpdateLastError {
            return error
        }
        return nil
    }

    static func cliVersionMenuLine(_ s: AgentSnapshot) -> String? {
        guard let current = s.cliVersion else { return nil }
        if let target = updateTargetVersion(s) {
            return "CLI v\(current) · v\(target) available"
        }
        return "CLI v\(current) · up to date"
    }

    private static func malibuDisplay(_ amount: Double, tier: AgentSnapshot.TrustTier, compact: Bool = false) -> String {
        switch tier {
        case .trusted:
            return String(format: "%.2f MALIBU", amount)
        case .provisional:
            if compact {
                return String(format: "%.2f MALIBU today (locked)", amount)
            }
            return String(format: "[locked] %.2f MALIBU (unlocks at Trusted)", amount)
        }
    }

    private static func tokenPair(input: Int64?, output: Int64?, suffix: String) -> String {
        "\(formatTokens(input)) in / \(formatTokens(output)) out \(suffix)"
    }

    private static func formatTokens(_ value: Int64?) -> String {
        guard let value else { return "0" }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private static func formatCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%dm", seconds / 60) }
        return String(format: "%dh %dm", seconds / 3600, (seconds % 3600) / 60)
    }
}

extension AgentSnapshot {
    mutating func applyAdmissionIdentityRecoveryJournal(
        _ recovery: ProviderCredentialHandoffRunner.AdmissionRecoverySnapshot
    ) {
        admissionIdentityRecoveryJournalState = recovery.state
        switch recovery.state {
        case "approval_required":
            admissionIdentityState = "recovery_pending"
            admissionIdentityPendingPublicKeySHA256 = recovery.candidatePublicKeySHA256
            admissionIdentityTransitionError = "approval_required"
            admissionIdentityRecoveryAction = "obtain_operator_recovery_approval_then_restart"
            admissionIdentityRecoveryApprovalInstruction = recovery.approvalInstruction
            admissionIdentityRecoveryOperatorRequest = recovery.operatorRequest
            admissionIdentityRecoveryLastError = nil
        case "committed_cleanup":
            admissionIdentityPendingPublicKeySHA256 = recovery.candidatePublicKeySHA256
            admissionIdentityRecoveryApprovalInstruction = "Finalize the already committed recovery journal."
            admissionIdentityRecoveryOperatorRequest = nil
            admissionIdentityRecoveryLastError = nil
        case "expired":
            admissionIdentityRecoveryApprovalInstruction = nil
            admissionIdentityRecoveryOperatorRequest = nil
            admissionIdentityRecoveryLastError = "The staged admission identity recovery request expired. Stage a new request."
        case "not_staged", "committed":
            admissionIdentityRecoveryApprovalInstruction = nil
            admissionIdentityRecoveryOperatorRequest = nil
            if recovery.state == "committed" {
                admissionIdentityRecoveryJournalState = nil
            }
        default:
            break
        }
    }
}
