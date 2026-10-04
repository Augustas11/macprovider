import CryptoKit
import Darwin
import Foundation

// SPEC-049 v0.2 supervisor-attestor (SPEC-049-R025, SPEC-049-R026,
// SPEC-049-R033). Malibu.app's main process is the only component that holds
// or uses the App Attest key. It attests and asserts only for the child it
// spawned, only after re-checking that child's dynamic code identity, and only
// over framing it recomputed from a statement whose supervisor-owned fields it
// filled itself. It never sees prompts, responses, or any private key.

/// App Attest behind a protocol: the real `DCAppAttestService` cannot run in
/// tests.
protocol AppAttestProviding: Sendable {
    /// macOS 27 or later and `DCAppAttestService.isSupported`.
    var isSupported: Bool { get }
    /// Returns the standard-base64 keyId Apple issued.
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

enum AppAttestProviderError: Error, Equatable {
    /// `DCError.invalidKey` or any other error that the key cannot be used.
    case invalidKey
    case unsupported
    case failed
}

/// Persists only the keyId, which is not secret. The key itself never leaves
/// the Secure Enclave.
protocol PrivacyAppAttestKeyIDStoring: Sendable {
    func load() -> String?
    func save(_ keyID: String) throws
    func delete()
}

/// The supervisor's view of the peer of one channel request. `token` comes
/// from the kernel (`LOCAL_PEERTOKEN`), never from a message.
struct PrivacyChildPeer: Sendable {
    let pid: pid_t
    let pidVersion: UInt32
    let token: audit_token_t
}

/// What the supervisor observed about the child for one request.
struct PrivacyChildObservation: Equatable, Sendable {
    let requirementSatisfied: Bool
    let identifier: String
    let cdhash: String
    /// Nil when `csops_audittoken` could not read the flags.
    let csFlags: UInt32?
}

protocol PrivacyChildInspecting: Sendable {
    func inspect(_ token: audit_token_t, requirement: String) -> PrivacyChildObservation?
}

/// The production inspector: SecCode by audit token, the requirement check,
/// the dynamic cdhash, and the dynamic code-signing flags.
struct PrivacyAuditTokenChildInspector: PrivacyChildInspecting {
    func inspect(_ token: audit_token_t, requirement: String) -> PrivacyChildObservation? {
        guard let code = PrivacySupervisorPeer.code(for: token),
              let identity = PrivacySupervisorPeer.dynamicIdentity(code) else {
            return nil
        }
        return PrivacyChildObservation(
            requirementSatisfied: PrivacySupervisorPeer.satisfies(code, requirement: requirement),
            identifier: identity.identifier,
            cdhash: identity.cdhash,
            csFlags: PrivacySupervisorPeer.codeSigningFlags(token)
        )
    }
}

/// Bounded local reason codes recorded when the child check fails (SPEC-049-R026).
enum PrivacyChildCheckFailure: String, Error, Equatable, Sendable {
    case unknownPeer = "child_peer_unknown"
    case codeUnavailable = "child_code_unavailable"
    case requirementFailed = "child_requirement_failed"
    case identifierMismatch = "child_identifier_mismatch"
    case cdhashMismatch = "child_cdhash_mismatch"
    case flagsUnreadable = "child_flags_unreadable"
    case flagsRejected = "child_flags_rejected"
}

/// The supervisor's own identity, read once from its validated bundle.
struct PrivacySupervisorIdentity: Equatable, Sendable {
    /// The team of the supervisor's own Developer ID signature.
    let teamID: String
    /// Malibu.app `CFBundleVersion`.
    let bundleVersion: String
    /// The cdhash of the `macprovider-cli` executable sealed in this bundle.
    let approvedChildCDHash: String
}

/// Process-wide latch: after a failed child check the app never spawns a
/// privacy-mode child again in this process lifetime (SPEC-049-R026).
enum PrivacyCodeBoundLatch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reason: PrivacyChildCheckFailure?

    static var latchedReason: PrivacyChildCheckFailure? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }

    static func latch(_ failure: PrivacyChildCheckFailure) {
        lock.lock()
        if reason == nil { reason = failure }
        lock.unlock()
    }

    static func resetForTest() {
        lock.lock()
        reason = nil
        lock.unlock()
    }
}

actor PrivacyCodeBoundSupervisor {
    private let identity: PrivacySupervisorIdentity
    private let appAttest: any AppAttestProviding
    private let keyStore: any PrivacyAppAttestKeyIDStoring
    private let inspector: any PrivacyChildInspecting
    private let now: @Sendable () -> Date
    private let terminateChild: @Sendable () -> Void
    private var child: (pid: pid_t, pidVersion: UInt32)?

    init(
        identity: PrivacySupervisorIdentity,
        appAttest: any AppAttestProviding,
        keyStore: any PrivacyAppAttestKeyIDStoring,
        inspector: any PrivacyChildInspecting = PrivacyAuditTokenChildInspector(),
        now: @escaping @Sendable () -> Date = { Date() },
        terminateChild: @escaping @Sendable () -> Void
    ) {
        self.identity = identity
        self.appAttest = appAttest
        self.keyStore = keyStore
        self.inspector = inspector
        self.now = now
        self.terminateChild = terminateChild
    }

    /// Records the PID and PID version of the child this app just spawned.
    func childSpawned(pid: pid_t, pidVersion: UInt32) {
        child = (pid, pidVersion)
    }

    func childExited() {
        child = nil
    }

    /// True when `peer` is the running child this supervisor spawned
    /// (SPEC-049-R026 step 2). Other peers are dropped without a reply.
    func isSpawnedChild(_ peer: PrivacyChildPeer) -> Bool {
        guard let child else { return false }
        return peer.pid == child.pid && peer.pidVersion == child.pidVersion
    }

    func handle(_ request: PrivacySupervisorRequest, peer: PrivacyChildPeer) async -> PrivacySupervisorReply {
        if PrivacyCodeBoundLatch.latchedReason != nil { return .error(.childCheckFailed) }
        guard appAttest.isSupported else { return .error(.unsupported) }
        let observed: PrivacyChildObservation
        switch checkChild(peer) {
        case .success(let observation):
            observed = observation
        case .failure(let failure):
            // SPEC-049-R026: no attestation, terminate, never respawn.
            PrivacyCodeBoundLatch.latch(failure)
            child = nil
            terminateChild()
            return .error(.childCheckFailed)
        }
        switch request {
        case .key(let discard):
            return await key(discard: discard)
        case .attest(let draft):
            return await attest(draft, observed: observed)
        case .assert(let draft):
            return await assert(draft, observed: observed)
        }
    }

    // MARK: SPEC-049-R026

    private func checkChild(_ peer: PrivacyChildPeer) -> Result<PrivacyChildObservation, PrivacyChildCheckFailure> {
        guard isSpawnedChild(peer) else { return .failure(.unknownPeer) }
        guard let requirement = PrivacySupervisorPeer.requirement(
            identifier: PrivacySupervisorConstants.childSigningIdentifier,
            teamID: identity.teamID,
            cdhash: identity.approvedChildCDHash
        ), let observation = inspector.inspect(peer.token, requirement: requirement) else {
            return .failure(.codeUnavailable)
        }
        guard observation.requirementSatisfied else { return .failure(.requirementFailed) }
        guard observation.identifier == PrivacySupervisorConstants.childSigningIdentifier else {
            return .failure(.identifierMismatch)
        }
        guard observation.cdhash == identity.approvedChildCDHash else { return .failure(.cdhashMismatch) }
        guard let flags = observation.csFlags else { return .failure(.flagsUnreadable) }
        guard PrivacySupervisorConstants.childCSFlagsOK(UInt64(flags)) else { return .failure(.flagsRejected) }
        return .success(observation)
    }

    // MARK: Requests

    private func key(discard: String?) async -> PrivacySupervisorReply {
        if let discard, let stored = storedWireKeyID(), stored == discard {
            keyStore.delete()
        }
        if let stored = storedWireKeyID() {
            return .key(appAttestKeyID: stored)
        }
        do {
            let keyID = try await appAttest.generateKey()
            guard let wire = PrivacySupervisorBase64URL.fromAppAttestKeyID(keyID) else { return .error(.unavailable) }
            try keyStore.save(keyID)
            return .key(appAttestKeyID: wire)
        } catch AppAttestProviderError.unsupported {
            return .error(.unsupported)
        } catch {
            return .error(.unavailable)
        }
    }

    private func attest(_ draft: PrivacyEnrollmentDraft, observed: PrivacyChildObservation) async -> PrivacySupervisorReply {
        guard let keyID = keyStore.load(), PrivacySupervisorBase64URL.fromAppAttestKeyID(keyID) == draft.appAttestKeyID else {
            return .error(.keyInvalid)
        }
        let statement = PrivacyEnrollmentStatement(
            draft: draft,
            supervisor: PrivacySupervisorEnrollmentFields(
                teamID: identity.teamID,
                bundleID: PrivacySupervisorConstants.supervisorBundleID,
                environment: PrivacySupervisorConstants.environment,
                childCDHash: observed.cdhash,
                childCSFlags: UInt64(observed.csFlags ?? 0),
                supervisorBundleVersion: identity.bundleVersion,
                issuedAtUnix: Int64(now().timeIntervalSince1970)
            )
        )
        guard statement.supervisorConsistent, let framing = try? statement.framing() else {
            return .error(.draftRejected)
        }
        do {
            let attestation = try await appAttest.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: framing)))
            guard (1...PrivacySupervisorConstants.maxAttestationBytes).contains(attestation.count) else {
                return .error(.unavailable)
            }
            return .attestation(statement, attestation: attestation)
        } catch {
            return failure(error)
        }
    }

    private func assert(_ draft: PrivacyPostureV2Draft, observed: PrivacyChildObservation) async -> PrivacySupervisorReply {
        // SPEC-049-R025: refuse a draft that disagrees with what was observed.
        guard draft.codeCDHash == observed.cdhash,
              draft.signingIdentifier == observed.identifier,
              draft.teamID == identity.teamID else {
            return .error(.draftRejected)
        }
        guard let keyID = keyStore.load(), PrivacySupervisorBase64URL.fromAppAttestKeyID(keyID) == draft.appAttestKeyID else {
            return .error(.keyInvalid)
        }
        let checkedAt = Int64(now().timeIntervalSince1970)
        let statement = PrivacyPostureV2Statement(
            draft: draft,
            supervisor: PrivacySupervisorPostureFields(
                supervisorTeamID: identity.teamID,
                supervisorBundleID: PrivacySupervisorConstants.supervisorBundleID,
                supervisorBundleVersion: identity.bundleVersion,
                childCDHash: observed.cdhash,
                childSigningIdentifier: observed.identifier,
                childCSFlags: UInt64(observed.csFlags ?? 0),
                childCheckedAtUnix: checkedAt,
                childChannelPeerVerified: true
            )
        )
        // The ±5 second rule and the masks are checked here too, so the app
        // never asserts over a statement the coordinator would quarantine.
        guard statement.childCheckConsistent, let framing = try? statement.framing() else {
            return .error(.draftRejected)
        }
        do {
            let assertion = try await appAttest.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: framing)))
            guard (1...PrivacySupervisorConstants.maxAssertionBytes).contains(assertion.count) else {
                return .error(.unavailable)
            }
            return .assertion(statement, assertion: assertion)
        } catch {
            return failure(error)
        }
    }

    /// SPEC-049-R033: an unusable key is discarded so the next key request
    /// generates and enrolls a new one.
    private func failure(_ error: Error) -> PrivacySupervisorReply {
        switch error as? AppAttestProviderError {
        case .invalidKey:
            keyStore.delete()
            return .error(.keyInvalid)
        case .unsupported:
            return .error(.unsupported)
        default:
            return .error(.unavailable)
        }
    }

    private func storedWireKeyID() -> String? {
        keyStore.load().flatMap(PrivacySupervisorBase64URL.fromAppAttestKeyID)
    }
}
