import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import macprovider_cli

final class AdmissionIdentityRotationCommandTests: XCTestCase {
    func testRecoveryStagesCandidateBeforeRestartAndReusesItDuringActivation() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let store = InMemoryAdmissionIdentityRotationStore(current: nil)

        let staged = try await AdmissionIdentityRotationCommandRunner.stageRecovery(
            configPath: fixture.configURL.path,
            expectedProviderID: "provider-a",
            store: store
        )
        let pending = try XCTUnwrap(try store.loadPendingAdmissionIdentity(providerId: "provider-a"))
        XCTAssertEqual(
            staged.candidatePublicKeySHA256,
            SHA256.hash(data: Data(pending.publicKey.rawRepresentation))
                .map { String(format: "%02x", $0) }.joined()
        )

        let activated = try await AdmissionIdentityRotationCommandRunner.recover(
            configPath: fixture.configURL.path,
            expectedProviderID: "provider-a",
            previousServiceInstance: nil,
            store: store,
            leaseStore: fixture.leaseStore,
            startupHandoffExecutableURL: { fixture.handoffExecutableURL },
            startupHandoffExecutableSHA256: { _ in fixture.handoffExecutableSHA256 },
            restartAndProve: { _, providerID, _ in
                let startupLease = try fixture.adoptPreparedStartupLease()
                XCTAssertTrue(startupLease.operationID.hasPrefix("admission-identity-recovery-"))
                XCTAssertEqual(startupLease.startupHandoff?.operationID, startupLease.operationID)
                try store.commitPending()
                XCTAssertTrue(try fixture.leaseStore.clear(ifLeaseID: startupLease.leaseID))
                return CredentialCommandResult(
                    providerID: providerID,
                    status: ProviderCredentialStatus(
                        source: .cliKeychain,
                        state: .ready,
                        restartSafe: true,
                        migrationPending: false
                    )
                )
            }
        )
        XCTAssertEqual(activated.publicKeySHA256, staged.candidatePublicKeySHA256)
    }

    func testRecoveryJournalIsDurableBeforeMarkerAndCrashRetryConverges() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let store = InMemoryAdmissionIdentityRotationStore(current: nil)
        let journalStore = AdmissionIdentityRecoveryJournalStore(
            url: fixture.directory.appendingPathComponent("recovery.json")
        )
        let now = Date(timeIntervalSince1970: 1_784_035_200)

        do {
            _ = try await AdmissionIdentityRotationCommandRunner.stageRecovery(
                configPath: fixture.configURL.path,
                expectedProviderID: "provider-a",
                store: store,
                now: { now },
                afterPendingPersisted: { staged in
                    _ = try journalStore.persistOrReuse(
                        staged.journalRecord(
                            incidentID: "incident-original",
                            reason: "persist before publishing the recovery marker",
                            requestedUntil: now.addingTimeInterval(3_600)
                        ),
                        configPath: fixture.configURL.path,
                        now: now
                    )
                    throw AdmissionIdentityRotationTestError.simulatedCrash
                }
            )
            XCTFail("simulated crash must interrupt marker publication")
        } catch AdmissionIdentityRotationTestError.simulatedCrash {
        }

        let pending = try XCTUnwrap(try store.loadPendingAdmissionIdentity(providerId: "provider-a"))
        let pendingDigest = SHA256.hash(data: Data(pending.publicKey.rawRepresentation))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(store.hasRecoveryMarker())
        XCTAssertEqual(
            try journalStore.load(configPath: fixture.configURL.path)?.candidatePublicKeySHA256,
            pendingDigest
        )

        let retried = try await AdmissionIdentityRotationCommandRunner.stageRecovery(
            configPath: fixture.configURL.path,
            expectedProviderID: "provider-a",
            store: store,
            now: { now.addingTimeInterval(5) },
            afterPendingPersisted: { staged in
                _ = try journalStore.persistOrReuse(
                    staged.journalRecord(
                        incidentID: "incident-retry-must-not-replace",
                        reason: "retry exact persisted request",
                        requestedUntil: now.addingTimeInterval(7_200)
                    ),
                    configPath: fixture.configURL.path,
                    now: now.addingTimeInterval(5)
                )
            }
        )

        XCTAssertEqual(retried.candidatePublicKeySHA256, pendingDigest)
        XCTAssertTrue(store.hasRecoveryMarker())
        let durable = try XCTUnwrap(journalStore.load(configPath: fixture.configURL.path))
        XCTAssertEqual(durable.incidentID, "incident-original")
        XCTAssertEqual(durable.candidatePublicKeySHA256, pendingDigest)
    }

    func testRotationStagesOnceRestartsAndRequiresCommittedCandidate() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let original = Curve25519.Signing.PrivateKey()
        let store = InMemoryAdmissionIdentityRotationStore(current: original)

        let result = try await AdmissionIdentityRotationCommandRunner.rotate(
            configPath: fixture.configURL.path,
            expectedProviderID: "provider-a",
            previousServiceInstance: "old-instance",
            store: store,
            leaseStore: fixture.leaseStore,
            startupHandoffExecutableURL: { fixture.handoffExecutableURL },
            startupHandoffExecutableSHA256: { _ in fixture.handoffExecutableSHA256 },
            restartAndProve: { configPath, providerID, previousServiceInstance in
                XCTAssertEqual(configPath, fixture.configURL.path)
                XCTAssertEqual(providerID, "provider-a")
                XCTAssertEqual(previousServiceInstance, "old-instance")
                let startupLease = try fixture.adoptPreparedStartupLease()
                XCTAssertTrue(startupLease.operationID.hasPrefix("admission-identity-rotation-"))
                XCTAssertEqual(startupLease.startupHandoff?.operationID, startupLease.operationID)
                try store.commitPending()
                XCTAssertTrue(try fixture.leaseStore.clear(ifLeaseID: startupLease.leaseID))
                return CredentialCommandResult(
                    providerID: providerID,
                    status: ProviderCredentialStatus(
                        source: .cliKeychain,
                        state: .ready,
                        restartSafe: true,
                        migrationPending: false
                    )
                )
            }
        )

        let current = try XCTUnwrap(try store.loadAdmissionIdentity(providerId: "provider-a"))
        XCTAssertNotEqual(current.rawRepresentation, original.rawRepresentation)
        XCTAssertNil(try store.loadPendingAdmissionIdentity(providerId: "provider-a"))
        XCTAssertEqual(result.providerID, "provider-a")
        XCTAssertEqual(
            result.publicKeySHA256,
            SHA256.hash(data: Data(current.publicKey.rawRepresentation))
                .map { String(format: "%02x", $0) }
                .joined()
        )
        if case .missing = fixture.leaseStore.inspect() {
        } else {
            XCTFail("rotation must clear its maintenance lease")
        }
    }

    func testRestartFailureRetainsExactPendingCandidateForRetry() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let original = Curve25519.Signing.PrivateKey()
        let store = InMemoryAdmissionIdentityRotationStore(current: original)

        do {
            _ = try await AdmissionIdentityRotationCommandRunner.rotate(
                configPath: fixture.configURL.path,
                expectedProviderID: "provider-a",
                previousServiceInstance: nil,
                store: store,
                leaseStore: fixture.leaseStore,
                startupHandoffExecutableURL: { fixture.handoffExecutableURL },
                startupHandoffExecutableSHA256: { _ in fixture.handoffExecutableSHA256 },
                restartAndProve: { _, _, _ in throw AdmissionIdentityRotationTestError.restartFailed }
            )
            XCTFail("restart failure must fail the command")
        } catch AdmissionIdentityRotationTestError.restartFailed {
        }
        let firstPending = try XCTUnwrap(try store.loadPendingAdmissionIdentity(providerId: "provider-a"))
        let repeated = try store.beginAdmissionIdentityRotation(providerId: "provider-a")
        XCTAssertEqual(firstPending.rawRepresentation, repeated.rawRepresentation)
        XCTAssertEqual(
            try store.loadAdmissionIdentity(providerId: "provider-a")?.rawRepresentation,
            original.rawRepresentation
        )
        XCTAssertEqual(fixture.leaseStore.inspect(), .missing)
    }

    func testRestartProofFailureAfterAdoptionCannotClearReplacementStartupLease() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let original = Curve25519.Signing.PrivateKey()
        let store = InMemoryAdmissionIdentityRotationStore(current: original)
        var adoptedLeaseID: String?

        do {
            _ = try await AdmissionIdentityRotationCommandRunner.rotate(
                configPath: fixture.configURL.path,
                expectedProviderID: "provider-a",
                previousServiceInstance: nil,
                store: store,
                leaseStore: fixture.leaseStore,
                startupHandoffExecutableURL: { fixture.handoffExecutableURL },
                startupHandoffExecutableSHA256: { _ in fixture.handoffExecutableSHA256 },
                restartAndProve: { _, _, _ in
                    let startupLease = try fixture.adoptPreparedStartupLease()
                    adoptedLeaseID = startupLease.leaseID
                    throw AdmissionIdentityRotationTestError.restartFailed
                }
            )
            XCTFail("restart proof failure must fail the command")
        } catch AdmissionIdentityRotationTestError.restartFailed {
        }

        guard case .valid(let retainedStartupLease) = fixture.leaseStore.inspect() else {
            return XCTFail("the initiating process must preserve the replacement startup lease")
        }
        XCTAssertEqual(retainedStartupLease.leaseID, adoptedLeaseID)
        XCTAssertEqual(retainedStartupLease.kind, .startup)
        XCTAssertTrue(retainedStartupLease.operationID.hasPrefix("admission-identity-rotation-"))
        XCTAssertEqual(
            retainedStartupLease.startupHandoff?.operationID,
            retainedStartupLease.operationID
        )
        XCTAssertTrue(try fixture.leaseStore.clear(ifLeaseID: retainedStartupLease.leaseID))
    }

    func testHandoffPreparationFailureClearsMaintenanceLeaseBeforeRestart() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let store = InMemoryAdmissionIdentityRotationStore(current: Curve25519.Signing.PrivateKey())
        fixture.invalidateTargetExecutableDigest()

        do {
            _ = try await AdmissionIdentityRotationCommandRunner.rotate(
                configPath: fixture.configURL.path,
                expectedProviderID: "provider-a",
                previousServiceInstance: nil,
                store: store,
                leaseStore: fixture.leaseStore,
                startupHandoffExecutableURL: { fixture.handoffExecutableURL },
                startupHandoffExecutableSHA256: { _ in fixture.handoffExecutableSHA256 },
                restartAndProve: { _, _, _ in
                    XCTFail("restart must not run when the executable binding cannot be prepared")
                    throw AdmissionIdentityRotationTestError.restartFailed
                }
            )
            XCTFail("invalid executable binding must fail handoff preparation")
        } catch let error as ProviderLifecycleLeaseError {
            XCTAssertEqual(error, .targetExecutableMismatch)
        }

        XCTAssertEqual(fixture.leaseStore.inspect(), .missing)
        XCTAssertNotNil(try store.loadPendingAdmissionIdentity(providerId: "provider-a"))
    }

    func testRecoveryHandsLeaseToReplacementAndCommitsOperatorAuthorizedCandidate() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let store = InMemoryAdmissionIdentityRotationStore(current: nil)

        let result = try await AdmissionIdentityRotationCommandRunner.recover(
            configPath: fixture.configURL.path,
            expectedProviderID: "provider-a",
            previousServiceInstance: "lost-custody-instance",
            store: store,
            leaseStore: fixture.leaseStore,
            startupHandoffExecutableURL: { fixture.handoffExecutableURL },
            startupHandoffExecutableSHA256: { _ in fixture.handoffExecutableSHA256 },
            restartAndProve: { _, providerID, _ in
                let startupLease = try fixture.adoptPreparedStartupLease()
                XCTAssertTrue(startupLease.operationID.hasPrefix("admission-identity-recovery-"))
                XCTAssertEqual(startupLease.startupHandoff?.operationID, startupLease.operationID)
                try store.commitPending()
                XCTAssertTrue(try fixture.leaseStore.clear(ifLeaseID: startupLease.leaseID))
                return CredentialCommandResult(
                    providerID: providerID,
                    status: ProviderCredentialStatus(
                        source: .cliKeychain,
                        state: .ready,
                        restartSafe: true,
                        migrationPending: false
                    )
                )
            }
        )

        let current = try XCTUnwrap(try store.loadAdmissionIdentity(providerId: "provider-a"))
        XCTAssertNil(try store.loadPendingAdmissionIdentity(providerId: "provider-a"))
        XCTAssertEqual(result.providerID, "provider-a")
        XCTAssertEqual(
            result.publicKeySHA256,
            SHA256.hash(data: Data(current.publicKey.rawRepresentation))
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    func testRecoveryRefusesCandidateThatDoesNotMatchDurableJournal() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let store = InMemoryAdmissionIdentityRotationStore(current: nil)

        do {
            _ = try await AdmissionIdentityRotationCommandRunner.recover(
                configPath: fixture.configURL.path,
                expectedProviderID: "provider-a",
                previousServiceInstance: nil,
                store: store,
                leaseStore: fixture.leaseStore,
                expectedCandidatePublicKeySHA256: String(repeating: "f", count: 64),
                startupHandoffExecutableURL: { fixture.handoffExecutableURL },
                startupHandoffExecutableSHA256: { _ in fixture.handoffExecutableSHA256 },
                restartAndProve: { _, _, _ in
                    XCTFail("candidate mismatch must be rejected before restart")
                    throw AdmissionIdentityRotationTestError.restartFailed
                }
            )
            XCTFail("expected journal candidate mismatch")
        } catch let error as AdmissionIdentityRecoveryJournalError {
            XCTAssertEqual(error, .candidateMismatch)
        }
        XCTAssertEqual(fixture.leaseStore.inspect(), .missing)
    }

    func testRecoveryFromCoordinatorPreviousKeyRequiresFreshDegradedStatus() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let previous = Curve25519.Signing.PrivateKey()
        let authoritative = Curve25519.Signing.PrivateKey()
        let store = InMemoryAdmissionIdentityRotationStore(current: previous)
        let now = Date()
        let status = try makePreviousKeyRecoveryStatus(
            now: now,
            previous: previous,
            authoritative: authoritative
        )

        let result = try await AdmissionIdentityRotationCommandRunner.recover(
            configPath: fixture.configURL.path,
            expectedProviderID: "provider-a",
            previousServiceInstance: nil,
            store: store,
            leaseStore: fixture.leaseStore,
            fetchStatus: { _ in status },
            now: { now },
            launchdPID: { 4_321 },
            listenerOwnerPID: { _ in 4_321 },
            bootSession: { "boot-a" },
            startupHandoffExecutableURL: { fixture.handoffExecutableURL },
            startupHandoffExecutableSHA256: { _ in fixture.handoffExecutableSHA256 },
            restartAndProve: { _, providerID, _ in
                let startupLease = try fixture.adoptPreparedStartupLease()
                XCTAssertTrue(startupLease.operationID.hasPrefix("admission-identity-recovery-"))
                XCTAssertEqual(startupLease.startupHandoff?.operationID, startupLease.operationID)
                try store.commitPending()
                XCTAssertTrue(try fixture.leaseStore.clear(ifLeaseID: startupLease.leaseID))
                return CredentialCommandResult(
                    providerID: providerID,
                    status: ProviderCredentialStatus(
                        source: .cliKeychain,
                        state: .ready,
                        restartSafe: true,
                        migrationPending: false
                    )
                )
            }
        )

        XCTAssertEqual(result.providerID, "provider-a")
        XCTAssertNotEqual(
            try store.loadAdmissionIdentity(providerId: "provider-a")?.rawRepresentation,
            previous.rawRepresentation
        )
    }

    func testExistingKeyRecoveryRejectsUnsignedStatusAndUnownedListener() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let previous = Curve25519.Signing.PrivateKey()
        let authoritative = Curve25519.Signing.PrivateKey()
        let store = InMemoryAdmissionIdentityRotationStore(current: previous)
        let now = Date()
        let validStatus = try makePreviousKeyRecoveryStatus(
            now: now,
            previous: previous,
            authoritative: authoritative
        )
        let unsignedStatus = try JSONSerialization.data(withJSONObject: [
            "provider_id": "provider-a",
            "admission_identity": [
                "state": "degraded_previous_key",
                "public_key_sha256": SHA256.hash(data: Data(previous.publicKey.rawRepresentation))
                    .map { String(format: "%02x", $0) }.joined(),
                "coordinator_public_key_sha256": SHA256.hash(
                    data: Data(authoritative.publicKey.rawRepresentation)
                ).map { String(format: "%02x", $0) }.joined(),
                "coordinator_generation": 2,
                "coordinator_key_role": "previous",
            ],
        ])

        do {
            _ = try await AdmissionIdentityRotationCommandRunner.stageRecovery(
                configPath: fixture.configURL.path,
                expectedProviderID: "provider-a",
                store: store,
                fetchStatus: { _ in unsignedStatus },
                now: { now },
                launchdPID: { 4_321 },
                listenerOwnerPID: { _ in 4_321 },
                bootSession: { "boot-a" }
            )
            XCTFail("unsigned loopback status must not authorize recovery staging")
        } catch {
            XCTAssertEqual(
                error as? ReceiptKeyStoreError,
                .admissionIdentityRecoveryNotRequired(providerId: "provider-a")
            )
        }

        do {
            _ = try await AdmissionIdentityRotationCommandRunner.stageRecovery(
                configPath: fixture.configURL.path,
                expectedProviderID: "provider-a",
                store: store,
                fetchStatus: { _ in validStatus },
                now: { now },
                launchdPID: { 4_321 },
                listenerOwnerPID: { _ in 9_999 },
                bootSession: { "boot-a" }
            )
            XCTFail("a non-launchd listener must not authorize recovery staging")
        } catch {
            XCTAssertEqual(
                error as? ReceiptKeyStoreError,
                .admissionIdentityRecoveryNotRequired(providerId: "provider-a")
            )
        }

        var listenerOwnershipChecks = 0
        do {
            _ = try await AdmissionIdentityRotationCommandRunner.stageRecovery(
                configPath: fixture.configURL.path,
                expectedProviderID: "provider-a",
                store: store,
                fetchStatus: { _ in validStatus },
                now: { now },
                launchdPID: { 4_321 },
                listenerOwnerPID: { _ in
                    listenerOwnershipChecks += 1
                    return listenerOwnershipChecks == 1 ? 4_321 : 9_999
                },
                bootSession: { "boot-a" }
            )
            XCTFail("listener ownership lost during status fetch must not authorize recovery staging")
        } catch {
            XCTAssertEqual(
                error as? ReceiptKeyStoreError,
                .admissionIdentityRecoveryNotRequired(providerId: "provider-a")
            )
        }
        XCTAssertNil(try store.loadPendingAdmissionIdentity(providerId: "provider-a"))
        XCTAssertFalse(store.hasRecoveryMarker())
    }

    func testExpiredRecoveryRestagingAfterRestartReusesMatchingPendingMarker() async throws {
        let fixture = try AdmissionIdentityRotationFixture()
        defer { fixture.cleanup() }
        let previous = Curve25519.Signing.PrivateKey()
        let authoritative = Curve25519.Signing.PrivateKey()
        let store = InMemoryAdmissionIdentityRotationStore(current: previous)
        let now = Date(timeIntervalSince1970: 1_784_035_200)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let degradedStatus = try makePreviousKeyRecoveryStatus(
            now: now,
            previous: previous,
            authoritative: authoritative
        )

        let first = try await AdmissionIdentityRotationCommandRunner.stageRecovery(
            configPath: fixture.configURL.path,
            expectedProviderID: "provider-a",
            store: store,
            fetchStatus: { _ in degradedStatus },
            now: { now },
            launchdPID: { 4_321 },
            listenerOwnerPID: { _ in 4_321 },
            bootSession: { "boot-a" }
        )
        let journalStore = AdmissionIdentityRecoveryJournalStore(
            url: fixture.directory.appendingPathComponent("recovery.json")
        )
        let expired = first.journalRecord(
            incidentID: "INC-EXPIRED-RECOVERY",
            reason: "operator approval window expired after restart",
            requestedUntil: now.addingTimeInterval(1)
        )
        _ = try journalStore.persistOrReuse(
            expired,
            configPath: fixture.configURL.path,
            now: now
        )

        let afterRestart = now.addingTimeInterval(2)
        let recoveryPendingStatus = try JSONSerialization.data(withJSONObject: [
            "provider_id": "provider-a",
            "observation": [
                "observed_at": formatter.string(from: afterRestart),
                "valid_for_ms": 30_000,
            ],
            "admission_identity": [
                "state": "recovery_pending",
                "public_key_sha256": first.candidatePublicKeySHA256,
                "pending_public_key_sha256": first.candidatePublicKeySHA256,
            ],
        ])
        let restaged = try await AdmissionIdentityRotationCommandRunner.stageRecovery(
            configPath: fixture.configURL.path,
            expectedProviderID: "provider-a",
            store: store,
            fetchStatus: { _ in recoveryPendingStatus },
            now: { afterRestart }
        )
        XCTAssertEqual(restaged.candidatePublicKeySHA256, first.candidatePublicKeySHA256)

        let renewed = restaged.journalRecord(
            incidentID: "INC-RENEWED-RECOVERY",
            reason: "restage exact candidate after expired approval",
            requestedUntil: afterRestart.addingTimeInterval(3_600)
        )
        let persisted = try journalStore.persistOrReuse(
            renewed,
            configPath: fixture.configURL.path,
            now: afterRestart
        )
        XCTAssertEqual(persisted.candidatePublicKeySHA256, first.candidatePublicKeySHA256)
        XCTAssertEqual(persisted.incidentID, renewed.incidentID)
        XCTAssertEqual(persisted.requestedUntil, renewed.requestedUntil)
    }
}

private func makePreviousKeyRecoveryStatus(
    now: Date,
    previous: Curve25519.Signing.PrivateKey,
    authoritative: Curve25519.Signing.PrivateKey,
    launchdPID: Int = 4_321,
    bootSession: String = "boot-a"
) throws -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let previousDigest = SHA256.hash(data: Data(previous.publicKey.rawRepresentation))
        .map { String(format: "%02x", $0) }.joined()
    let authoritativeDigest = SHA256.hash(data: Data(authoritative.publicKey.rawRepresentation))
        .map { String(format: "%02x", $0) }.joined()
    return try JSONSerialization.data(withJSONObject: [
        "binary_version": "1.8.33",
        "local_status_contract": [
            "version": 1,
            "minimum_reader_version": 1,
            "lifecycle_owner": "macprovider_cli",
            "capabilities": [
                "admission_identity_v1", "service_instance_v1", "status_observation_v1",
            ],
        ],
        "provider_id": "provider-a",
        "observation": [
            "id": "observation-a",
            "observed_at": formatter.string(from: now),
            "valid_for_ms": 30_000,
        ],
        "service_instance": [
            "instance_id": "instance-a",
            "pid": launchdPID,
            "boot_session": bootSession,
            "started_at": formatter.string(from: now.addingTimeInterval(-60)),
            "role": "serve",
        ],
        "admission_identity": [
            "owner": "macprovider_cli",
            "source": "cli_keychain",
            "state": "degraded_previous_key",
            "public_key_sha256": previousDigest,
            "previous_valid_until": formatter.string(from: now.addingTimeInterval(3_600)),
            "coordinator_public_key_sha256": authoritativeDigest,
            "coordinator_generation": 2,
            "coordinator_key_role": "previous",
        ],
    ])
}

private enum AdmissionIdentityRotationTestError: Error {
    case restartFailed
    case simulatedCrash
    case handoffMissing
}

private final class InMemoryAdmissionIdentityRotationStore: AdmissionIdentityRecoveryKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Curve25519.Signing.PrivateKey?
    private var pending: Curve25519.Signing.PrivateKey?
    private var recoveryMarker: Data?

    init(current: Curve25519.Signing.PrivateKey?) {
        self.current = current
    }

    func loadAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func loadPendingAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    func beginAdmissionIdentityRotation(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        guard current != nil else {
            throw ReceiptKeyStoreError.missingAdmissionIdentity(providerId: providerId)
        }
        if let pending { return pending }
        let candidate = Curve25519.Signing.PrivateKey()
        pending = candidate
        return candidate
    }

    func beginAdmissionIdentityRecovery(
        providerId: String,
        allowExistingCurrent: Bool,
        afterPendingPersisted: (Curve25519.Signing.PrivateKey) throws -> Void
    ) throws -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if current != nil && !allowExistingCurrent {
            throw ReceiptKeyStoreError.admissionIdentityRecoveryNotRequired(providerId: providerId)
        }
        if let pending {
            try afterPendingPersisted(pending)
            recoveryMarker = pending.publicKey.rawRepresentation
            return pending
        }
        let candidate = Curve25519.Signing.PrivateKey()
        pending = candidate
        try afterPendingPersisted(candidate)
        recoveryMarker = candidate.publicKey.rawRepresentation
        return candidate
    }

    func isAdmissionIdentityRecoveryPending(
        providerId: String,
        candidatePublicKey: Data
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recoveryMarker == candidatePublicKey
    }

    func hasRecoveryMarker() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recoveryMarker != nil
    }

    func commitPending() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let pending else {
            throw AdmissionIdentityRotationTestError.restartFailed
        }
        current = pending
        self.pending = nil
        recoveryMarker = nil
    }
}

private final class AdmissionIdentityRotationFixture: @unchecked Sendable {
    let directory: URL
    let configURL: URL
    let leaseStore: ProviderLifecycleLeaseStore
    let handoffExecutableURL: URL
    let handoffExecutableSHA256: String
    private let leaseEnvironment: AdmissionIdentityLeaseTestEnvironment

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "admission-identity-rotation-command-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        configURL = directory.appendingPathComponent("config.yaml")
        try "provider_id: provider-a\nport: 9999\n".write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        handoffExecutableURL = directory.appendingPathComponent("macprovider-cli")
        let executableBytes = Data("signed-test-provider-cli".utf8)
        try executableBytes.write(to: handoffExecutableURL)
        XCTAssertEqual(chmod(handoffExecutableURL.path, 0o700), 0)
        handoffExecutableSHA256 = SHA256.hash(data: executableBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let environment = AdmissionIdentityLeaseTestEnvironment(
            targetExecutablePath: handoffExecutableURL.path,
            targetExecutableSHA256: handoffExecutableSHA256
        )
        leaseEnvironment = environment
        leaseStore = ProviderLifecycleLeaseStore(
            url: directory.appendingPathComponent("lifecycle/lease.json"),
            environment: environment.value
        )
    }

    func adoptPreparedStartupLease() throws -> ProviderLifecycleLeaseRecord {
        guard case .valid(let prepared) = leaseStore.inspect(),
              let handoff = prepared.startupHandoff,
              handoff.state == .prepared else {
            throw AdmissionIdentityRotationTestError.handoffMissing
        }
        leaseEnvironment.transitionToLaunchdReplacement()
        return try leaseStore.adoptStartupHandoff(
            operationID: handoff.operationID,
            providerID: handoff.providerID,
            serviceIdentity: handoff.serviceIdentity
        )
    }

    func invalidateTargetExecutableDigest() {
        leaseEnvironment.invalidateTargetExecutableDigest()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class AdmissionIdentityLeaseTestEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private let targetExecutablePath: String
    private var wallMilliseconds: Int64 = 1_784_016_000_000
    private var monotonicNanoseconds: Int64 = 500_000_000_000
    private var processID: pid_t = 4_321
    private var processStarts: [pid_t: Int64] = [4_321: 99_000_123]
    private var launchdProcessIDs: [String: pid_t] = [:]
    private var executablePaths: [pid_t: String] = [:]
    private var executableDigests: [String: String]

    init(targetExecutablePath: String, targetExecutableSHA256: String) {
        self.targetExecutablePath = targetExecutablePath
        self.executableDigests = [targetExecutablePath: targetExecutableSHA256]
    }

    var value: ProviderLifecycleLeaseEnvironment {
        ProviderLifecycleLeaseEnvironment(
            wallMilliseconds: { [weak self] in self?.read { $0.wallMilliseconds } ?? -1 },
            monotonicNanoseconds: { [weak self] in self?.read { $0.monotonicNanoseconds } ?? -1 },
            bootSession: { "boot-a" },
            processStartMicroseconds: { [weak self] pid in
                self?.read { $0.processStarts[pid] }
            },
            processID: { [weak self] in self?.read { $0.processID } ?? -1 },
            launchdServiceProcessID: { [weak self] serviceIdentity in
                self?.read { $0.launchdProcessIDs[serviceIdentity] }
            },
            executablePath: { [weak self] pid in
                self?.read { $0.executablePaths[pid] }
            },
            executableSHA256: { [weak self] path in
                self?.read { $0.executableDigests[path] }
            }
        )
    }

    func transitionToLaunchdReplacement() {
        mutate {
            $0.processID = 5_321
            $0.processStarts[5_321] = 100_000_456
            $0.launchdProcessIDs[CredentialRestartProver.launchdLabel] = 5_321
            $0.executablePaths[5_321] = $0.targetExecutablePath
        }
    }

    func invalidateTargetExecutableDigest() {
        mutate { $0.executableDigests[$0.targetExecutablePath] = nil }
    }

    private func read<T>(_ operation: (AdmissionIdentityLeaseTestEnvironment) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation(self)
    }

    private func mutate(_ operation: (AdmissionIdentityLeaseTestEnvironment) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        operation(self)
    }
}
