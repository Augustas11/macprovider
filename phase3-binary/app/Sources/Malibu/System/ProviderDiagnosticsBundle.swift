import Darwin
import Foundation

/// Builds the support artifact from an explicit allowlist of non-secret state.
/// Malibu never copies config, Keychain values, environment variables, or raw
/// coordinator frames into diagnostics.
enum ProviderDiagnosticsBundle {
    static let schema = "malibu.provider-diagnostics.v1"
    private static let maximumLogBytes = 256 * 1024
    private static let maximumLogLines = 400
    private static let maximumLineCharacters = 8 * 1024

    static func make(
        snapshot: AgentSnapshot,
        providerLogLines: [String],
        watchdogLogURL: URL?,
        appVersion: String,
        now: Date = Date()
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let lifecycle: [String: Any] = [
            "record_state": json(snapshot.lifecycleRecordState),
            "sequence": json(snapshot.lifecycleSequence),
            "transition_id": json(snapshot.lifecycleTransitionID),
            "transition_at": json(snapshot.lifecycleTransitionAt.map(formatter.string(from:))),
            "state": json(snapshot.lifecycleState),
            "reason": json(snapshot.lifecycleReason),
            "authority": json(snapshot.lifecycleAuthority),
            "writer": json(snapshot.lifecycleWriter),
            "operation_id": json(snapshot.lifecycleOperationID),
            "operator_paused": json(snapshot.lifecycleOperatorPaused),
            "last_restart": lifecycleEvent(snapshot.lifecycleLastRestart, formatter: formatter),
            "last_rejection": lifecycleEvent(snapshot.lifecycleLastRejection, formatter: formatter),
            "last_update": lifecycleEvent(snapshot.lifecycleLastUpdate, formatter: formatter),
            "last_watchdog": lifecycleEvent(snapshot.lifecycleLastWatchdog, formatter: formatter),
            "lease_state": json(snapshot.lifecycleLeaseState),
            "lease_kind": json(snapshot.lifecycleLeaseKind),
            "lease_operation_id": json(snapshot.lifecycleLeaseOperationID),
            "lease_expires_wall_ms": json(snapshot.lifecycleLeaseExpiresWallMS),
        ]
        let service: [String: Any] = [
            "instance_id": json(snapshot.serviceInstanceID),
            "pid": json(snapshot.servicePID),
            "boot_session": json(snapshot.serviceBootSession),
            "started_at": json(snapshot.serviceStartedAt.map(formatter.string(from:))),
            "role": json(snapshot.serviceRole),
        ]
        let credential: [String: Any] = [
            "source": json(snapshot.credentialSource),
            "state": json(snapshot.credentialState),
            "restart_safe": json(snapshot.credentialRestartSafe),
            "migration_pending": json(snapshot.credentialMigrationPending),
            "recovery_action": json(snapshot.credentialRecoveryAction),
            "repair_error": json(redacted(snapshot.credentialRepairLastError)),
        ]
        let admissionIdentity: [String: Any] = [
            "source": json(snapshot.admissionIdentitySource),
            "state": json(snapshot.admissionIdentityState),
            "public_key_sha256": json(snapshot.admissionIdentityPublicKeySHA256),
            "pending_public_key_sha256": json(snapshot.admissionIdentityPendingPublicKeySHA256),
            "previous_public_key_sha256": json(snapshot.admissionIdentityPreviousPublicKeySHA256),
            "previous_valid_until": json(snapshot.admissionIdentityPreviousValidUntil.map(formatter.string(from:))),
            "coordinator_generation": json(snapshot.admissionIdentityCoordinatorGeneration),
            "coordinator_key_role": json(snapshot.admissionIdentityCoordinatorKeyRole),
            "transition_error": json(redacted(snapshot.admissionIdentityTransitionError)),
            "recovery_action": json(snapshot.admissionIdentityRecoveryAction),
            "recovery_journal_state": json(snapshot.admissionIdentityRecoveryJournalState),
        ]
        let catalog: [String: Any] = [
            "state": json(snapshot.catalogState),
            "release_id": json(snapshot.catalogReleaseID),
            "digest": json(snapshot.catalogDigest),
            "signer_key_id": json(snapshot.catalogSignerKeyID),
            "source": json(snapshot.catalogSource),
        ]
        let compatibility: [String: Any] = [
            "set_id": json(snapshot.compatibilitySetID),
            "set_sha256": json(snapshot.compatibilitySetSHA256),
            "status_contract_version": json(snapshot.localStatusContractVersion),
            "minimum_reader_version": json(snapshot.localStatusMinimumReaderVersion),
            "contract_compatible": json(snapshot.localStatusContractCompatible),
            "lifecycle_owner": json(snapshot.localStatusLifecycleOwner),
            "capabilities": snapshot.localStatusCapabilities.sorted(),
        ]
        let watchdogLines = watchdogLogURL.map(readRedactedTail) ?? []
        let root: [String: Any] = [
            "schema": schema,
            "created_at": formatter.string(from: now),
            "malibu_version": appVersion,
            "provider": [
                "id": json(snapshot.localProviderID),
                "ui_state": snapshot.state.rawValue,
                "model_id": json(snapshot.currentModelID),
                "cli_version": json(snapshot.cliVersion),
                "network_state": json(snapshot.networkState),
                "coordinator_connected": json(snapshot.coordinatorConnected),
                "coordinator_recommended_version": json(snapshot.coordinatorRecommendedVersion),
                "restart_count": json(snapshot.restartCount),
                "last_error": json(redacted(snapshot.lastError)),
                "hardware_verification_retry_in_progress": snapshot.hardwareVerificationRetryInProgress,
                "hardware_verification_retry_last_error": json(
                    redacted(snapshot.hardwareVerificationRetryLastError)
                ),
            ],
            "compatibility": compatibility,
            "service": service,
            "lifecycle": lifecycle,
            "credential": credential,
            "admission_identity": admissionIdentity,
            "catalog": catalog,
            "logs": [
                "provider": redactedLines(providerLogLines),
                "watchdog": watchdogLines,
            ],
        ]
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func readRedactedTail(_ url: URL) -> [String] {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0 else {
            return []
        }
        let start = max(off_t(0), info.st_size - off_t(maximumLogBytes))
        guard lseek(descriptor, start, SEEK_SET) >= 0 else { return [] }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while bytes.count < maximumLogBytes {
            let count = read(descriptor, &buffer, min(buffer.count, maximumLogBytes - bytes.count))
            guard count >= 0 else { return [] }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard var text = String(data: bytes, encoding: .utf8) else { return [] }
        if start > 0, let firstNewline = text.firstIndex(where: \.isNewline) {
            text = String(text[text.index(after: firstNewline)...])
        }
        return redactedLines(text.components(separatedBy: .newlines).filter { !$0.isEmpty })
    }

    private static func redactedLines(_ lines: [String]) -> [String] {
        lines.suffix(maximumLogLines).map { line in
            String(LogTailBuffer.redacted(line).prefix(maximumLineCharacters))
        }
    }

    private static func redacted(_ value: String?) -> String? {
        value.map { String(LogTailBuffer.redacted($0).prefix(maximumLineCharacters)) }
    }

    private static func json<T>(_ value: T?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private static func lifecycleEvent(
        _ event: ProviderLifecycleEventSnapshot?,
        formatter: ISO8601DateFormatter
    ) -> Any {
        guard let event else { return NSNull() }
        return [
            "sequence": event.sequence,
            "transition_id": event.transitionID,
            "transition_at": formatter.string(from: event.transitionAt),
            "state": event.state,
            "reason": event.reason,
            "writer": event.writer,
            "compatibility_set_id": json(event.compatibilitySetID),
            "operation_id": json(event.operationID),
        ] as [String: Any]
    }
}
