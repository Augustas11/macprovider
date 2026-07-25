import CryptoKit
import Foundation
import Security

struct MalibuReleaseTrustBundle: Codable, Equatable {
    let keyringData: Data
    let revocationsData: Data
    let publicKeys: [String: Data]

    enum CodingKeys: String, CodingKey {
        case keyringData = "keyring_data"
        case revocationsData = "revocations_data"
        case publicKeys = "public_keys"
    }

    func trustPolicy(minimumGeneration: Int) throws -> MalibuReleaseTrustPolicy {
        try MalibuReleaseTrustPolicy.parse(
            keyringData: keyringData,
            revocationsData: revocationsData,
            minimumGeneration: minimumGeneration,
            publicKeyLoader: { path in
                guard let key = publicKeys[path] else {
                    throw MalibuReleaseContractError.invalidValue("protected trust public key path")
                }
                return key
            }
        )
    }
}

struct MalibuReleaseRollbackReceipt: Codable, Equatable {
    enum Status: String, Codable { case pending, completed }

    let authorizationSHA256: String
    let nonce: String
    let issuedAt: Date
    let expiresAt: Date
    let current: MalibuReleaseAntiReplayState
    let target: MalibuReleaseAntiReplayState
    let keyringGeneration: Int
    let keyringSHA256: String
    let revocationsGeneration: Int
    let revocationsSHA256: String
    let selectedKeyID: String
    let selectedSPKISHA256: String
    let transactionID: String?
    let transactionSHA256: String?
    let status: Status

    enum CodingKeys: String, CodingKey {
        case authorizationSHA256 = "authorization_sha256"
        case nonce
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case current, target
        case keyringGeneration = "keyring_generation"
        case keyringSHA256 = "keyring_sha256"
        case revocationsGeneration = "revocations_generation"
        case revocationsSHA256 = "revocations_sha256"
        case selectedKeyID = "selected_key_id"
        case selectedSPKISHA256 = "selected_spki_sha256"
        case transactionID = "transaction_id"
        case transactionSHA256 = "transaction_sha256"
        case status
    }
}

struct MalibuReleaseRotationReceipt: Codable, Equatable {
    enum Status: String, Codable { case pending, completed, retired }

    let rotationID: String
    let currentKeyringGeneration: Int
    let currentKeyringSHA256: String
    let successorKeyringGeneration: Int
    let successorKeyringSHA256: String
    let successorRevocationsGeneration: Int
    let successorRevocationsSHA256: String
    let overlapIndexGeneration: Int
    let overlapIndexSHA256: String
    let retiringKeyID: String
    let successorKeyID: String
    let successorTrustBundle: MalibuReleaseTrustBundle
    let status: Status

    enum CodingKeys: String, CodingKey {
        case rotationID = "rotation_id"
        case currentKeyringGeneration = "current_keyring_generation"
        case currentKeyringSHA256 = "current_keyring_sha256"
        case successorKeyringGeneration = "successor_keyring_generation"
        case successorKeyringSHA256 = "successor_keyring_sha256"
        case successorRevocationsGeneration = "successor_revocations_generation"
        case successorRevocationsSHA256 = "successor_revocations_sha256"
        case overlapIndexGeneration = "overlap_index_generation"
        case overlapIndexSHA256 = "overlap_index_sha256"
        case retiringKeyID = "retiring_key_id"
        case successorKeyID = "successor_key_id"
        case successorTrustBundle = "successor_trust_bundle"
        case status
    }
}

struct MalibuReleaseRetirementReceipt: Codable, Equatable {
    enum Status: String, Codable { case pending, completed }

    let authorizationSHA256: String
    let nonce: String
    let rotationID: String
    let protectedRevision: Int
    let highWater: MalibuReleaseAntiReplayState
    let retiringKeyID: String
    let successorKeyID: String
    let overlapKeyringGeneration: Int
    let overlapKeyringSHA256: String
    let overlapRevocationsGeneration: Int
    let overlapRevocationsSHA256: String
    let retirementKeyringGeneration: Int
    let retirementKeyringSHA256: String
    let retirementRevocationsGeneration: Int
    let retirementRevocationsSHA256: String
    let retirementTrustBundle: MalibuReleaseTrustBundle
    let status: Status

    enum CodingKeys: String, CodingKey {
        case authorizationSHA256 = "authorization_sha256"
        case nonce
        case rotationID = "rotation_id"
        case protectedRevision = "protected_revision"
        case highWater = "high_water"
        case retiringKeyID = "retiring_key_id"
        case successorKeyID = "successor_key_id"
        case overlapKeyringGeneration = "overlap_keyring_generation"
        case overlapKeyringSHA256 = "overlap_keyring_sha256"
        case overlapRevocationsGeneration = "overlap_revocations_generation"
        case overlapRevocationsSHA256 = "overlap_revocations_sha256"
        case retirementKeyringGeneration = "retirement_keyring_generation"
        case retirementKeyringSHA256 = "retirement_keyring_sha256"
        case retirementRevocationsGeneration = "retirement_revocations_generation"
        case retirementRevocationsSHA256 = "retirement_revocations_sha256"
        case retirementTrustBundle = "retirement_trust_bundle"
        case status
    }
}

struct MalibuReleaseProtectedState: Codable, Equatable {
    let schemaVersion: String
    let revision: Int
    let highWater: MalibuReleaseAntiReplayState
    let activeRelease: MalibuReleaseAntiReplayState
    let keyringGenerationFloor: Int
    let keyringSHA256: String
    let revocationsGenerationFloor: Int
    let revocationsSHA256: String
    let legacySourceAppVersion: String?
    let legacySourceTransactionSHA256: String?
    let rollback: MalibuReleaseRollbackReceipt?
    let rotation: MalibuReleaseRotationReceipt?
    let retirement: MalibuReleaseRetirementReceipt?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision
        case highWater = "high_water"
        case activeRelease = "active_release"
        case keyringGenerationFloor = "keyring_generation_floor"
        case keyringSHA256 = "keyring_sha256"
        case revocationsGenerationFloor = "revocations_generation_floor"
        case revocationsSHA256 = "revocations_sha256"
        case legacySourceAppVersion = "legacy_source_app_version"
        case legacySourceTransactionSHA256 = "legacy_source_transaction_sha256"
        case rollback, rotation, retirement
    }

    static func bootstrap(
        release: MalibuReleaseAntiReplayState,
        trust: MalibuReleaseTrustPolicy,
        legacySourceAppVersion: String? = nil,
        legacySourceTransactionSHA256: String? = nil
    ) -> MalibuReleaseProtectedState {
        MalibuReleaseProtectedState(
            schemaVersion: "malibu-release-protected-state.v1",
            revision: 1,
            highWater: release,
            activeRelease: release,
            keyringGenerationFloor: trust.generation,
            keyringSHA256: trust.keyringSHA256,
            revocationsGenerationFloor: trust.revocationsGeneration,
            revocationsSHA256: trust.revocationsSHA256,
            legacySourceAppVersion: legacySourceAppVersion,
            legacySourceTransactionSHA256: legacySourceTransactionSHA256,
            rollback: nil,
            rotation: nil,
            retirement: nil
        )
    }
}

protocol MalibuReleaseProtectedStateBacking: AnyObject {
    func read(account: String) throws -> Data?
    func add(_ data: Data, account: String) throws
    func replace(_ data: Data, account: String) throws
}

final class MalibuReleaseKeychainBacking: MalibuReleaseProtectedStateBacking, @unchecked Sendable {
    static let shared = MalibuReleaseKeychainBacking()
    private let service = "tech.malibu.release-state.YF7XNRJUG4"

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MalibuReleaseContractError.insecureState("protected Keychain state is unreadable (\(status))")
        }
        return data
    }

    func add(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            let reason = status == errSecDuplicateItem ? "already exists" : "could not be created (\(status))"
            throw MalibuReleaseContractError.insecureState("protected Keychain state \(reason)")
        }
    }

    func replace(_ data: Data, account: String) throws {
        let status = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecSuccess else {
            throw MalibuReleaseContractError.insecureState("protected Keychain state could not be replaced (\(status))")
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

final class MalibuReleaseProtectedStateStore: @unchecked Sendable {
    private struct AuthenticatedBlob: Codable {
        let schemaVersion: String
        let payload: Data
        let authentication: Data

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case payload, authentication
        }
    }

    static let live = MalibuReleaseProtectedStateStore(backing: MalibuReleaseKeychainBacking.shared)

    private let backing: MalibuReleaseProtectedStateBacking
    private let stateAccount = "tech.malibu.app/YF7XNRJUG4/protected-state-v1"
    private let keyAccount = "tech.malibu.app/YF7XNRJUG4/protected-state-auth-key-v1"
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private let keyGenerator: () throws -> Data

    init(
        backing: MalibuReleaseProtectedStateBacking,
        keyGenerator: @escaping () throws -> Data = MalibuReleaseProtectedStateStore.randomKey
    ) {
        self.backing = backing
        self.keyGenerator = keyGenerator
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func load() throws -> MalibuReleaseProtectedState? {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func save(_ state: MalibuReleaseProtectedState, expectedRevision: Int?) throws {
        lock.lock()
        defer { lock.unlock() }
        let existing = try loadUnlocked()
        guard existing?.revision == expectedRevision else {
            throw MalibuReleaseContractError.insecureState("protected state revision changed concurrently")
        }
        try validate(state)
        if let existing {
            guard state.revision == existing.revision + 1,
                  dominates(state.highWater, existing.highWater),
                  state.keyringGenerationFloor >= existing.keyringGenerationFloor,
                  state.revocationsGenerationFloor >= existing.revocationsGenerationFloor else {
                throw MalibuReleaseContractError.insecureState("protected monotonic floors would roll back")
            }
            try validateTransition(from: existing, to: state)
        } else {
            guard state.revision == 1 else {
                throw MalibuReleaseContractError.insecureState("protected state bootstrap revision is invalid")
            }
        }
        let key = try authenticationKey(createIfMissing: existing == nil)
        let payload = try encoder.encode(state)
        let tag = Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key)))
        let blob = try encoder.encode(AuthenticatedBlob(
            schemaVersion: "malibu-release-protected-blob.v1",
            payload: payload,
            authentication: tag
        ))
        if existing == nil { try backing.add(blob, account: stateAccount) }
        else { try backing.replace(blob, account: stateAccount) }
    }

    private func loadUnlocked() throws -> MalibuReleaseProtectedState? {
        let blobData = try backing.read(account: stateAccount)
        let keyData = try backing.read(account: keyAccount)
        if blobData == nil, keyData == nil { return nil }
        guard let blobData, let keyData, keyData.count == 32 else {
            throw MalibuReleaseContractError.insecureState("protected state or authentication key is missing")
        }
        let blob: AuthenticatedBlob
        do { blob = try decoder.decode(AuthenticatedBlob.self, from: blobData) }
        catch { throw MalibuReleaseContractError.insecureState("protected state blob is malformed") }
        guard blob.schemaVersion == "malibu-release-protected-blob.v1" else {
            throw MalibuReleaseContractError.insecureState("protected state blob schema is unsupported")
        }
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: blob.payload,
            using: SymmetricKey(data: keyData)
        ))
        guard expected == blob.authentication else {
            throw MalibuReleaseContractError.insecureState("protected state authentication failed")
        }
        let state: MalibuReleaseProtectedState
        do { state = try decoder.decode(MalibuReleaseProtectedState.self, from: blob.payload) }
        catch { throw MalibuReleaseContractError.insecureState("protected state payload is malformed") }
        try validate(state)
        return state
    }

    private func authenticationKey(createIfMissing: Bool) throws -> Data {
        if let existing = try backing.read(account: keyAccount) {
            guard existing.count == 32 else {
                throw MalibuReleaseContractError.insecureState("protected state authentication key is invalid")
            }
            return existing
        }
        guard createIfMissing else {
            throw MalibuReleaseContractError.insecureState("protected state authentication key is missing")
        }
        let key = try keyGenerator()
        guard key.count == 32 else {
            throw MalibuReleaseContractError.insecureState("protected state authentication key generation failed")
        }
        try backing.add(key, account: keyAccount)
        return key
    }

    private static func randomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw MalibuReleaseContractError.insecureState("protected state authentication key generation failed")
        }
        return Data(bytes)
    }

    private func validate(_ state: MalibuReleaseProtectedState) throws {
        guard state.schemaVersion == "malibu-release-protected-state.v1",
              state.revision > 0,
              state.keyringGenerationFloor > 0,
              state.revocationsGenerationFloor > 0,
              isDigest(state.keyringSHA256),
              isDigest(state.revocationsSHA256),
              (state.legacySourceAppVersion == nil) == (state.legacySourceTransactionSHA256 == nil),
              state.legacySourceAppVersion == nil
                || ProviderCLIVersion.strictNormalize(state.legacySourceAppVersion!) != nil,
              state.legacySourceTransactionSHA256 == nil
                || isDigest(state.legacySourceTransactionSHA256!),
              valid(state.highWater), valid(state.activeRelease),
              dominates(state.highWater, state.activeRelease) else {
            throw MalibuReleaseContractError.insecureState("protected state invariants are invalid")
        }
        if state.activeRelease != state.highWater {
            guard let rollback = state.rollback,
                  rollback.status == .completed,
                  rollback.target == state.activeRelease,
                  rollback.current == state.highWater,
                  isDigest(rollback.authorizationSHA256),
                  isDigest(rollback.nonce) else {
                throw MalibuReleaseContractError.insecureState("active rollback target lacks protected authorization")
            }
        }
        if let rollback = state.rollback {
            guard isDigest(rollback.authorizationSHA256), isDigest(rollback.nonce),
                  rollback.expiresAt > rollback.issuedAt,
                  rollback.keyringGeneration > 0,
                  isDigest(rollback.keyringSHA256),
                  rollback.revocationsGeneration > 0,
                  isDigest(rollback.revocationsSHA256),
                  !rollback.selectedKeyID.isEmpty,
                  isDigest(rollback.selectedSPKISHA256),
                  rollback.current == state.highWater,
                  dominates(rollback.current, rollback.target),
                  rollback.current != rollback.target else {
                throw MalibuReleaseContractError.insecureState("protected rollback receipt is invalid")
            }
            if rollback.status == .pending {
                guard rollback.transactionID == nil, rollback.transactionSHA256 == nil else {
                    throw MalibuReleaseContractError.insecureState("pending rollback contains completion evidence")
                }
            } else {
                guard rollback.transactionID?.range(
                    of: "^[0-9a-f]{32}$",
                    options: .regularExpression
                ) != nil,
                      let digest = rollback.transactionSHA256,
                      isDigest(digest) else {
                    throw MalibuReleaseContractError.insecureState("completed rollback lacks transaction evidence")
                }
            }
        }
        if let rotation = state.rotation {
            guard rotation.currentKeyringGeneration > 0,
                  rotation.successorKeyringGeneration > rotation.currentKeyringGeneration,
                  rotation.successorRevocationsGeneration > 0,
                  isDigest(rotation.rotationID),
                  isDigest(rotation.currentKeyringSHA256),
                  isDigest(rotation.successorKeyringSHA256),
                  isDigest(rotation.successorRevocationsSHA256),
                  rotation.overlapIndexGeneration > 0,
                  isDigest(rotation.overlapIndexSHA256),
                  rotation.retiringKeyID != rotation.successorKeyID,
                  let successorTrust = try? rotation.successorTrustBundle.trustPolicy(
                      minimumGeneration: rotation.successorKeyringGeneration
                  ),
                  successorTrust.generation == rotation.successorKeyringGeneration,
                  successorTrust.keyringSHA256 == rotation.successorKeyringSHA256,
                  successorTrust.revocationsGeneration == rotation.successorRevocationsGeneration,
                  successorTrust.revocationsSHA256 == rotation.successorRevocationsSHA256 else {
                throw MalibuReleaseContractError.insecureState("protected rotation receipt is invalid")
            }
        }
        if let retirement = state.retirement {
            guard let rotation = state.rotation,
                  rotation.status == .completed,
                  retirement.protectedRevision > 0,
                  retirement.protectedRevision < state.revision,
                  retirement.highWater == state.highWater,
                  retirement.rotationID == rotation.rotationID,
                  retirement.retiringKeyID == rotation.retiringKeyID,
                  retirement.successorKeyID == rotation.successorKeyID,
                  retirement.overlapKeyringGeneration == rotation.successorKeyringGeneration,
                  retirement.overlapKeyringSHA256 == rotation.successorKeyringSHA256,
                  retirement.overlapRevocationsGeneration == rotation.successorRevocationsGeneration,
                  retirement.overlapRevocationsSHA256 == rotation.successorRevocationsSHA256,
                  retirement.retirementKeyringGeneration > retirement.overlapKeyringGeneration,
                  retirement.retirementRevocationsGeneration >= retirement.overlapRevocationsGeneration,
                  isDigest(retirement.authorizationSHA256),
                  isDigest(retirement.nonce),
                  isDigest(retirement.overlapKeyringSHA256),
                  isDigest(retirement.overlapRevocationsSHA256),
                  isDigest(retirement.retirementKeyringSHA256),
                  isDigest(retirement.retirementRevocationsSHA256),
                  let retirementTrust = try? retirement.retirementTrustBundle.trustPolicy(
                      minimumGeneration: retirement.retirementKeyringGeneration
                  ),
                  retirementTrust.generation == retirement.retirementKeyringGeneration,
                  retirementTrust.keyringSHA256 == retirement.retirementKeyringSHA256,
                  retirementTrust.revocationsGeneration == retirement.retirementRevocationsGeneration,
                  retirementTrust.revocationsSHA256 == retirement.retirementRevocationsSHA256 else {
                throw MalibuReleaseContractError.insecureState("protected retirement receipt is invalid")
            }
            if retirement.status == .completed {
                guard state.keyringGenerationFloor == retirement.retirementKeyringGeneration,
                      state.keyringSHA256 == retirement.retirementKeyringSHA256,
                      state.revocationsGenerationFloor == retirement.retirementRevocationsGeneration,
                      state.revocationsSHA256 == retirement.retirementRevocationsSHA256 else {
                    throw MalibuReleaseContractError.insecureState("completed retirement does not match protected trust floors")
                }
            }
        }
    }

    private func validateTransition(
        from existing: MalibuReleaseProtectedState,
        to next: MalibuReleaseProtectedState
    ) throws {
        guard existing.legacySourceAppVersion == next.legacySourceAppVersion,
              existing.legacySourceTransactionSHA256 == next.legacySourceTransactionSHA256 else {
            throw MalibuReleaseContractError.insecureState("protected legacy source attestation changed")
        }
        if let oldRollback = existing.rollback, let newRollback = next.rollback {
            let sameAuthorization =
                  oldRollback.authorizationSHA256 == newRollback.authorizationSHA256
                  && oldRollback.nonce == newRollback.nonce
                  && oldRollback.issuedAt == newRollback.issuedAt
                  && oldRollback.expiresAt == newRollback.expiresAt
                  && oldRollback.keyringGeneration == newRollback.keyringGeneration
                  && oldRollback.keyringSHA256 == newRollback.keyringSHA256
                  && oldRollback.revocationsGeneration == newRollback.revocationsGeneration
                  && oldRollback.revocationsSHA256 == newRollback.revocationsSHA256
                  && oldRollback.selectedKeyID == newRollback.selectedKeyID
                  && oldRollback.selectedSPKISHA256 == newRollback.selectedSPKISHA256
            let sameScope = oldRollback.current == newRollback.current
                && oldRollback.target == newRollback.target
            let validStatusTransition =
                sameAuthorization
                && (oldRollback.status == newRollback.status
                    || oldRollback.status == .pending && newRollback.status == .completed)
            let freshPendingReplacement = oldRollback.status == .pending
                && newRollback.status == .pending
                && !sameAuthorization
                && newRollback.issuedAt > oldRollback.issuedAt
            guard sameScope,
                  validStatusTransition || freshPendingReplacement else {
                throw MalibuReleaseContractError.insecureState("protected rollback receipt transition is invalid")
            }
        } else if let oldRollback = existing.rollback {
            guard oldRollback.status == .completed,
                  next.highWater != existing.highWater,
                  dominates(next.highWater, existing.highWater),
                  next.activeRelease == next.highWater else {
                throw MalibuReleaseContractError.insecureState("protected rollback receipt cannot be removed")
            }
        }
        if let oldRotation = existing.rotation {
            guard let newRotation = next.rotation,
                  sameRotation(oldRotation, newRotation),
                  oldRotation.status == newRotation.status
                    || oldRotation.status == .pending && newRotation.status == .completed else {
                throw MalibuReleaseContractError.insecureState("protected rotation receipt transition is invalid")
            }
        }
        switch (existing.retirement, next.retirement) {
        case (nil, nil):
            break
        case (nil, let new?):
            guard new.status == .pending,
                  new.protectedRevision == existing.revision else {
                throw MalibuReleaseContractError.insecureState("protected retirement receipt did not begin atomically")
            }
        case (let old?, let new?):
            guard sameRetirement(old, new),
                  old.status == new.status
                    || old.status == .pending && new.status == .completed else {
                throw MalibuReleaseContractError.insecureState("protected retirement receipt transition is invalid")
            }
        case (.some, nil):
            throw MalibuReleaseContractError.insecureState("protected retirement receipt cannot be removed")
        }
    }

    private func sameRotation(
        _ lhs: MalibuReleaseRotationReceipt,
        _ rhs: MalibuReleaseRotationReceipt
    ) -> Bool {
        lhs.rotationID == rhs.rotationID
            && lhs.currentKeyringGeneration == rhs.currentKeyringGeneration
            && lhs.currentKeyringSHA256 == rhs.currentKeyringSHA256
            && lhs.successorKeyringGeneration == rhs.successorKeyringGeneration
            && lhs.successorKeyringSHA256 == rhs.successorKeyringSHA256
            && lhs.successorRevocationsGeneration == rhs.successorRevocationsGeneration
            && lhs.successorRevocationsSHA256 == rhs.successorRevocationsSHA256
            && lhs.overlapIndexGeneration == rhs.overlapIndexGeneration
            && lhs.overlapIndexSHA256 == rhs.overlapIndexSHA256
            && lhs.retiringKeyID == rhs.retiringKeyID
            && lhs.successorKeyID == rhs.successorKeyID
            && lhs.successorTrustBundle == rhs.successorTrustBundle
    }

    private func sameRetirement(
        _ lhs: MalibuReleaseRetirementReceipt,
        _ rhs: MalibuReleaseRetirementReceipt
    ) -> Bool {
        lhs.authorizationSHA256 == rhs.authorizationSHA256
            && lhs.nonce == rhs.nonce
            && lhs.rotationID == rhs.rotationID
            && lhs.protectedRevision == rhs.protectedRevision
            && lhs.highWater == rhs.highWater
            && lhs.retiringKeyID == rhs.retiringKeyID
            && lhs.successorKeyID == rhs.successorKeyID
            && lhs.overlapKeyringGeneration == rhs.overlapKeyringGeneration
            && lhs.overlapKeyringSHA256 == rhs.overlapKeyringSHA256
            && lhs.overlapRevocationsGeneration == rhs.overlapRevocationsGeneration
            && lhs.overlapRevocationsSHA256 == rhs.overlapRevocationsSHA256
            && lhs.retirementKeyringGeneration == rhs.retirementKeyringGeneration
            && lhs.retirementKeyringSHA256 == rhs.retirementKeyringSHA256
            && lhs.retirementRevocationsGeneration == rhs.retirementRevocationsGeneration
            && lhs.retirementRevocationsSHA256 == rhs.retirementRevocationsSHA256
            && lhs.retirementTrustBundle == rhs.retirementTrustBundle
    }

    private func valid(_ state: MalibuReleaseAntiReplayState) -> Bool {
        state.schemaVersion == "malibu-release-anti-replay.v1"
            && state.highestIndexGeneration > 0
            && state.highestBuild > 0
            && state.highestEnvelopeGeneration > 0
            && isDigest(state.envelopeSHA256)
    }

    private func dominates(
        _ lhs: MalibuReleaseAntiReplayState,
        _ rhs: MalibuReleaseAntiReplayState
    ) -> Bool {
        lhs.highestIndexGeneration >= rhs.highestIndexGeneration
            && lhs.highestBuild >= rhs.highestBuild
            && lhs.highestEnvelopeGeneration >= rhs.highestEnvelopeGeneration
    }

    private func isDigest(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

#if DEBUG
final class MalibuReleaseMemoryBacking: MalibuReleaseProtectedStateBacking {
    var values: [String: Data] = [:]

    func read(account: String) throws -> Data? { values[account] }
    func add(_ data: Data, account: String) throws {
        guard values[account] == nil else {
            throw MalibuReleaseContractError.insecureState("memory item already exists")
        }
        values[account] = data
    }
    func replace(_ data: Data, account: String) throws {
        guard values[account] != nil else {
            throw MalibuReleaseContractError.insecureState("memory item is missing")
        }
        values[account] = data
    }
}
#endif
