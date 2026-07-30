import ArgumentParser
import CryptoKit
import Foundation

struct AdmissionIdentityRotationCommandResult: Equatable, Sendable {
    let providerID: String
    let publicKeySHA256: String

    func printJSON(operation: String = "rotate_admission_identity") throws {
        let payload: [String: Any] = [
            "contract_version": 1,
            "operation": operation,
            "provider_id": providerID,
            "owner": "macprovider_cli",
            "state": "committed",
            "public_key_sha256": publicKeySHA256,
            "restart_safe": true,
        ]
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}

struct AdmissionIdentityRecoveryStageResult: Equatable, Sendable {
    let providerID: String
    let candidatePublicKeySHA256: String

    func journalRecord(
        incidentID: String,
        reason: String,
        requestedUntil: Date
    ) -> AdmissionIdentityRecoveryJournalRecord {
        AdmissionIdentityRecoveryJournalRecord(
            providerID: providerID,
            candidatePublicKeySHA256: candidatePublicKeySHA256,
            requestedUntil: requestedUntil,
            reason: reason,
            incidentID: incidentID
        )
    }
}

struct CredentialsRecoverAdmissionIdentityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover-admission-identity",
        abstract: "Stage a CLI identity recovery candidate, then activate it after dual-control approval."
    )

    @Option(help: "YAML config path containing the provider_id and local provider port.")
    var config: String

    @Option(help: "Refuse the operation unless config contains this exact provider_id.")
    var expectedProviderID: String

    @Option(help: "Previously observed service instance that the restart proof must replace.")
    var previousServiceInstance: String?

    @Flag(help: "Restart and prove the already staged candidate after the coordinator authorization is approved.")
    var activate = false

    @Option(help: "Incident identifier included in the coordinator recovery request emitted during staging.")
    var incidentID: String?

    @Option(help: "Operator reason included in the coordinator recovery request emitted during staging.")
    var reason: String?

    @Option(help: "Requested authorization lifetime in minutes (1...1440).")
    var approvalTTLMinutes = 60

    func run() async throws {
        let now = Date()
        let journalStore = AdmissionIdentityRecoveryJournalStore()
        let loadedConfig = try CredentialsImportCommand.loadConfig(configPath: config)
        let providerID = try CredentialsImportCommand.requiredProviderID(loadedConfig)
        try CredentialsStatusCommand.validateExpectedProviderID(expectedProviderID, actual: providerID)
        if activate {
            let record = try journalStore.loadRequired(
                configPath: config,
                expectedProviderID: providerID,
                now: now,
                allowExpired: true
            )
            let keyStore = KeychainReceiptKeyStore()
            if let current = try keyStore.loadAdmissionIdentity(providerId: providerID),
               try keyStore.loadPendingAdmissionIdentity(providerId: providerID) == nil,
               Self.sha256(current.publicKey.rawRepresentation) == record.candidatePublicKeySHA256 {
                guard try journalStore.clearIfMatches(record, configPath: config) else {
                    throw AdmissionIdentityRecoveryJournalError.unavailable
                }
                try AdmissionIdentityRotationCommandResult(
                    providerID: providerID,
                    publicKeySHA256: record.candidatePublicKeySHA256
                ).printJSON(operation: "recover_admission_identity")
                return
            }
            guard (record.requestedUntilDate?.timeIntervalSince(now) ?? -1) > 0 else {
                throw AdmissionIdentityRecoveryJournalError.expired
            }
            let result = try await AdmissionIdentityRotationCommandRunner.recover(
                configPath: config,
                expectedProviderID: expectedProviderID,
                previousServiceInstance: previousServiceInstance,
                store: keyStore,
                leaseStore: ProviderLifecycleLeaseStore(),
                expectedCandidatePublicKeySHA256: record.candidatePublicKeySHA256
            )
            guard try journalStore.clearIfMatches(record, configPath: config) else {
                throw AdmissionIdentityRecoveryJournalError.unavailable
            }
            try result.printJSON(operation: "recover_admission_identity")
            return
        }
        let normalizedIncidentID = incidentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedIncidentID.isEmpty else {
            throw ValidationError("--incident-id is required when staging recovery")
        }
        guard !normalizedReason.isEmpty else {
            throw ValidationError("--reason is required when staging recovery")
        }
        guard (1...1_440).contains(approvalTTLMinutes) else {
            throw ValidationError("--approval-ttl-minutes must be between 1 and 1440")
        }
        let requestedUntil = now.addingTimeInterval(Double(approvalTTLMinutes) * 60)
        _ = try await AdmissionIdentityRotationCommandRunner.stageRecovery(
            configPath: config,
            expectedProviderID: expectedProviderID,
            store: KeychainReceiptKeyStore(),
            now: { now },
            afterPendingPersisted: { staged in
                _ = try journalStore.persistOrReuse(
                    staged.journalRecord(
                        incidentID: normalizedIncidentID,
                        reason: normalizedReason,
                        requestedUntil: requestedUntil
                    ),
                    configPath: config,
                    now: now
                )
            }
        )
        let record = try journalStore.loadRequired(
            configPath: config,
            expectedProviderID: providerID,
            now: now,
            allowExpired: true
        )
        try record.printJSON(
            operation: "recover_admission_identity",
            state: "approval_required"
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CredentialsAdmissionIdentityRecoveryStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "admission-identity-recovery-status",
        abstract: "Print the durable redacted CLI-owned admission identity recovery transaction."
    )

    @Option(help: "YAML config path containing the provider_id.")
    var config: String

    @Option(help: "Refuse the operation unless config contains this exact provider_id.")
    var expectedProviderID: String

    func run() throws {
        let loadedConfig = try CredentialsImportCommand.loadConfig(configPath: config)
        let providerID = try CredentialsImportCommand.requiredProviderID(loadedConfig)
        try CredentialsStatusCommand.validateExpectedProviderID(expectedProviderID, actual: providerID)
        let journalStore = AdmissionIdentityRecoveryJournalStore()
        guard let record = try journalStore.load(configPath: config) else {
            var data = try JSONSerialization.data(withJSONObject: [
                "contract_version": 1,
                "operation": "admission_identity_recovery_status",
                "provider_id": providerID,
                "owner": "macprovider_cli",
                "state": "not_staged",
                "restart_safe": true,
                "next_action": "stage admission identity recovery if local status requires it",
            ], options: [.sortedKeys])
            data.append(0x0a)
            FileHandle.standardOutput.write(data)
            return
        }
        guard record.providerID == providerID else {
            throw AdmissionIdentityRecoveryJournalError.providerMismatch
        }
        let keyStore = KeychainReceiptKeyStore()
        let pendingDigest = try keyStore.loadPendingAdmissionIdentity(providerId: providerID)
            .map { Self.sha256($0.publicKey.rawRepresentation) }
        let currentDigest = try keyStore.loadAdmissionIdentity(providerId: providerID)
            .map { Self.sha256($0.publicKey.rawRepresentation) }
        let state: String
        if pendingDigest == record.candidatePublicKeySHA256 {
            state = (record.requestedUntilDate?.timeIntervalSinceNow ?? -1) > 0
                ? "approval_required"
                : "expired"
        } else if pendingDigest == nil, currentDigest == record.candidatePublicKeySHA256 {
            state = "committed_cleanup"
        } else {
            throw AdmissionIdentityRecoveryJournalError.candidateMismatch
        }
        try record.printJSON(
            operation: "admission_identity_recovery_status",
            state: state,
            publicKeySHA256: state == "committed_cleanup" ? currentDigest : nil
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CredentialsRotateAdmissionIdentityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate-admission-identity",
        abstract: "Stage and prove a crash-safe CLI-owned admission identity rotation."
    )

    @Option(help: "YAML config path containing the provider_id and local provider port.")
    var config: String

    @Option(help: "Refuse the operation unless config contains this exact provider_id.")
    var expectedProviderID: String

    @Option(help: "Previously observed service instance that the restart proof must replace.")
    var previousServiceInstance: String?

    func run() async throws {
        let result = try await AdmissionIdentityRotationCommandRunner.rotate(
            configPath: config,
            expectedProviderID: expectedProviderID,
            previousServiceInstance: previousServiceInstance,
            store: KeychainReceiptKeyStore(),
            leaseStore: ProviderLifecycleLeaseStore()
        )
        try result.printJSON()
    }
}

enum AdmissionIdentityRotationCommandRunner {
    typealias RestartAndProve = (
        _ configPath: String,
        _ expectedProviderID: String,
        _ previousServiceInstance: String?
    ) async throws -> CredentialCommandResult

    static func rotate(
        configPath: String,
        expectedProviderID: String,
        previousServiceInstance: String?,
        store: any AdmissionIdentityRotationKeyStoring,
        leaseStore: ProviderLifecycleLeaseStore,
        startupHandoffExecutableURL: @escaping () -> URL? = {
            CompatibilitySetManifest.resolvedExecutableURL(Bundle.main.executableURL)
        },
        startupHandoffExecutableSHA256: @escaping (URL) throws -> String = {
            try AutoUpdateMarkerStore.sha256(file: $0)
        },
        restartAndProve: @escaping RestartAndProve = liveRestartAndProve
    ) async throws -> AdmissionIdentityRotationCommandResult {
        let config = try CredentialsImportCommand.loadConfig(configPath: configPath)
        let providerID = try CredentialsImportCommand.requiredProviderID(config)
        try CredentialsStatusCommand.validateExpectedProviderID(expectedProviderID, actual: providerID)

        let operationID = "admission-identity-rotation-\(UUID().uuidString.lowercased())"
        let lease = try leaseStore.acquire(
            kind: .maintenance,
            operationID: operationID,
            duration: 20 * 60
        )
        defer {
            // This CAS clear removes failures that occur before adoption. Once
            // launchd adopts the handoff it owns a new lease ID, which this
            // initiating process must never clear.
            _ = try? leaseStore.clear(ifLeaseID: lease.leaseID)
        }

        // Staging is idempotent. If restart/proof fails, the pending key is
        // intentionally retained so the next CLI-owned provider start retries
        // the exact signed transition instead of generating another candidate.
        let candidate = try store.beginAdmissionIdentityRotation(providerId: providerID)
        let expectedPublicKey = candidate.publicKey.rawRepresentation

        try prepareStartupHandoff(
            leaseStore: leaseStore,
            maintenanceLease: lease,
            operationID: operationID,
            providerID: providerID,
            executableURL: startupHandoffExecutableURL,
            executableSHA256: startupHandoffExecutableSHA256
        )
        _ = try await restartAndProve(configPath, providerID, previousServiceInstance)

        guard let current = try store.loadAdmissionIdentity(providerId: providerID),
              current.publicKey.rawRepresentation == expectedPublicKey else {
            throw ValidationError(
                "provider rejoined, but the coordinator-authoritative admission identity rotation was not committed"
            )
        }
        if try store.loadPendingAdmissionIdentity(providerId: providerID) != nil {
            throw ValidationError(
                "provider rejoined, but the coordinator-authoritative admission identity rotation was not committed"
            )
        }
        return AdmissionIdentityRotationCommandResult(
            providerID: providerID,
            publicKeySHA256: SHA256.hash(data: Data(expectedPublicKey))
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    static func recover(
        configPath: String,
        expectedProviderID: String,
        previousServiceInstance: String?,
        store: any AdmissionIdentityRecoveryKeyStoring,
        leaseStore: ProviderLifecycleLeaseStore,
        fetchStatus: ((Int) async -> Data?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        launchdPID: @escaping () -> Int? = CredentialRestartProver.currentLaunchdPID,
        listenerOwnerPID: @escaping (Int) -> Int? = CredentialRestartProver.currentListenerOwnerPID,
        bootSession: @escaping () -> String? = CredentialRestartProver.currentBootSessionUUID,
        expectedCandidatePublicKeySHA256: String? = nil,
        startupHandoffExecutableURL: @escaping () -> URL? = {
            CompatibilitySetManifest.resolvedExecutableURL(Bundle.main.executableURL)
        },
        startupHandoffExecutableSHA256: @escaping (URL) throws -> String = {
            try AutoUpdateMarkerStore.sha256(file: $0)
        },
        restartAndProve: @escaping RestartAndProve = liveRestartAndProve
    ) async throws -> AdmissionIdentityRotationCommandResult {
        let config = try CredentialsImportCommand.loadConfig(configPath: configPath)
        let providerID = try CredentialsImportCommand.requiredProviderID(config)
        try CredentialsStatusCommand.validateExpectedProviderID(expectedProviderID, actual: providerID)

        let operationID = "admission-identity-recovery-\(UUID().uuidString.lowercased())"
        let lease = try leaseStore.acquire(
            kind: .maintenance,
            operationID: operationID,
            duration: 20 * 60
        )
        defer {
            _ = try? leaseStore.clear(ifLeaseID: lease.leaseID)
        }

        let candidate = try await prepareRecoveryCandidate(
            providerID: providerID,
            port: config.port,
            store: store,
            fetchStatus: fetchStatus,
            now: now,
            launchdPID: launchdPID,
            listenerOwnerPID: listenerOwnerPID,
            bootSession: bootSession
        )
        let expectedPublicKey = candidate.publicKey.rawRepresentation
        let expectedDigest = SHA256.hash(data: Data(expectedPublicKey))
            .map { String(format: "%02x", $0) }
            .joined()
        if let expectedCandidatePublicKeySHA256,
           expectedCandidatePublicKeySHA256 != expectedDigest {
            throw AdmissionIdentityRecoveryJournalError.candidateMismatch
        }
        try prepareStartupHandoff(
            leaseStore: leaseStore,
            maintenanceLease: lease,
            operationID: operationID,
            providerID: providerID,
            executableURL: startupHandoffExecutableURL,
            executableSHA256: startupHandoffExecutableSHA256
        )
        _ = try await restartAndProve(configPath, providerID, previousServiceInstance)

        guard let current = try store.loadAdmissionIdentity(providerId: providerID),
              current.publicKey.rawRepresentation == expectedPublicKey,
              try store.loadPendingAdmissionIdentity(providerId: providerID) == nil else {
            throw ValidationError(
                "provider rejoined, but operator-authorized admission identity recovery was not committed"
            )
        }
        return AdmissionIdentityRotationCommandResult(
            providerID: providerID,
            publicKeySHA256: expectedDigest
        )
    }

    private static func prepareStartupHandoff(
        leaseStore: ProviderLifecycleLeaseStore,
        maintenanceLease: ProviderLifecycleLeaseRecord,
        operationID: String,
        providerID: String,
        executableURL: () -> URL?,
        executableSHA256: (URL) throws -> String
    ) throws {
        guard let targetExecutableURL = CompatibilitySetManifest.resolvedExecutableURL(
            executableURL()
        ) else {
            throw ProviderLifecycleLeaseError.invalidHandoffField("target_executable_path")
        }
        _ = try leaseStore.prepareStartupHandoff(
            maintenanceLeaseID: maintenanceLease.leaseID,
            operationID: operationID,
            providerID: providerID,
            serviceIdentity: CredentialRestartProver.launchdLabel,
            targetExecutablePath: targetExecutableURL.path,
            targetExecutableSHA256: try executableSHA256(targetExecutableURL),
            handoffDuration: 60,
            startupLeaseDuration: 20 * 60
        )
    }

    static func stageRecovery(
        configPath: String,
        expectedProviderID: String,
        store: any AdmissionIdentityRecoveryKeyStoring,
        fetchStatus: ((Int) async -> Data?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        launchdPID: @escaping () -> Int? = CredentialRestartProver.currentLaunchdPID,
        listenerOwnerPID: @escaping (Int) -> Int? = CredentialRestartProver.currentListenerOwnerPID,
        bootSession: @escaping () -> String? = CredentialRestartProver.currentBootSessionUUID,
        afterPendingPersisted: ((AdmissionIdentityRecoveryStageResult) throws -> Void)? = nil
    ) async throws -> AdmissionIdentityRecoveryStageResult {
        let config = try CredentialsImportCommand.loadConfig(configPath: configPath)
        let providerID = try CredentialsImportCommand.requiredProviderID(config)
        try CredentialsStatusCommand.validateExpectedProviderID(expectedProviderID, actual: providerID)
        let candidate = try await prepareRecoveryCandidate(
            providerID: providerID,
            port: config.port,
            store: store,
            fetchStatus: fetchStatus,
            now: now,
            launchdPID: launchdPID,
            listenerOwnerPID: listenerOwnerPID,
            bootSession: bootSession,
            afterPendingPersisted: afterPendingPersisted
        )
        return recoveryStageResult(providerID: providerID, candidate: candidate)
    }

    private static func prepareRecoveryCandidate(
        providerID: String,
        port: Int,
        store: any AdmissionIdentityRecoveryKeyStoring,
        fetchStatus: ((Int) async -> Data?)?,
        now: @escaping @Sendable () -> Date,
        launchdPID: @escaping () -> Int?,
        listenerOwnerPID: @escaping (Int) -> Int?,
        bootSession: @escaping () -> String?,
        afterPendingPersisted: ((AdmissionIdentityRecoveryStageResult) throws -> Void)? = nil
    ) async throws -> Curve25519.Signing.PrivateKey {
        var allowExistingCurrent = false
        if let current = try store.loadAdmissionIdentity(providerId: providerID) {
            if let pending = try store.loadPendingAdmissionIdentity(providerId: providerID),
               try store.isAdmissionIdentityRecoveryPending(
                   providerId: providerID,
                   candidatePublicKey: pending.publicKey.rawRepresentation
               ) {
                try afterPendingPersisted?(
                    recoveryStageResult(providerID: providerID, candidate: pending)
                )
                return pending
            }
            let statusFetcher = fetchStatus ?? CredentialRestartProver.fetchLocalStatus
            guard let exactLaunchdPID = launchdPID(),
                  listenerOwnerPID(port) == exactLaunchdPID,
                  let status = await statusFetcher(port),
                  launchdPID() == exactLaunchdPID,
                  listenerOwnerPID(port) == exactLaunchdPID,
                  validatePreviousKeyRecoveryStatus(
                    status,
                    providerID: providerID,
                    currentPublicKey: current.publicKey.rawRepresentation,
                    launchdPID: exactLaunchdPID,
                    now: now(),
                    currentBootSession: bootSession()
                  ) else {
                throw ReceiptKeyStoreError.admissionIdentityRecoveryNotRequired(providerId: providerID)
            }
            allowExistingCurrent = true
        }
        return try store.beginAdmissionIdentityRecovery(
            providerId: providerID,
            allowExistingCurrent: allowExistingCurrent,
            afterPendingPersisted: { candidate in
                try afterPendingPersisted?(
                    recoveryStageResult(providerID: providerID, candidate: candidate)
                )
            }
        )
    }

    static func validatePreviousKeyRecoveryStatus(
        _ data: Data,
        providerID: String,
        currentPublicKey: Data,
        launchdPID: Int,
        now: Date,
        currentBootSession: String?
    ) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              CredentialRestartProver.validateCLIAuthoredLocalStatus(
                object,
                requiredCapabilities: [
                    "admission_identity_v1", "service_instance_v1", "status_observation_v1",
                ],
                launchdPID: launchdPID,
                now: now,
                currentBootSession: currentBootSession
              ),
              object["provider_id"] as? String == providerID,
              let admission = object["admission_identity"] as? [String: Any],
              admission["owner"] as? String == "macprovider_cli",
              admission["source"] as? String == "cli_keychain",
              admission["state"] as? String == "degraded_previous_key",
              admission["coordinator_key_role"] as? String == "previous",
              let generation = admission["coordinator_generation"] as? Int,
              generation >= 2,
              let localDigest = admission["public_key_sha256"] as? String,
              let coordinatorDigest = admission["coordinator_public_key_sha256"] as? String,
              coordinatorDigest != localDigest,
              localDigest == SHA256.hash(data: currentPublicKey)
                .map({ String(format: "%02x", $0) }).joined(),
              let previousValidUntilText = admission["previous_valid_until"] as? String,
              let previousValidUntil = CredentialRestartProver.parseISO8601(previousValidUntilText),
              previousValidUntil > now else {
            return false
        }
        return true
    }

    private static func recoveryStageResult(
        providerID: String,
        candidate: Curve25519.Signing.PrivateKey
    ) -> AdmissionIdentityRecoveryStageResult {
        AdmissionIdentityRecoveryStageResult(
            providerID: providerID,
            candidatePublicKeySHA256: SHA256.hash(data: Data(candidate.publicKey.rawRepresentation))
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private static func liveRestartAndProve(
        configPath: String,
        expectedProviderID: String,
        previousServiceInstance: String?
    ) async throws -> CredentialCommandResult {
        try await CredentialRestartProver.restartAndProve(
            configPath: configPath,
            expectedProviderID: expectedProviderID,
            previousServiceInstance: previousServiceInstance
        )
    }
}
