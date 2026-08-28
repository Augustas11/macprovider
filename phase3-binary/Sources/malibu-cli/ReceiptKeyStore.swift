import CryptoKit
import Foundation
import LocalAuthentication
import Security

protocol ReceiptKeyStoring: Sendable {
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey?
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws
}

protocol AdmissionIdentityRotationKeyStoring: Sendable {
    func loadAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey?
    func loadPendingAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey?
    func beginAdmissionIdentityRotation(providerId: String) throws -> Curve25519.Signing.PrivateKey
}

protocol AdmissionIdentityRecoveryKeyStoring: AdmissionIdentityRotationKeyStoring {
    func isAdmissionIdentityRecoveryPending(
        providerId: String,
        candidatePublicKey: Data
    ) throws -> Bool
    func beginAdmissionIdentityRecovery(
        providerId: String,
        allowExistingCurrent: Bool,
        afterPendingPersisted: (Curve25519.Signing.PrivateKey) throws -> Void
    ) throws -> Curve25519.Signing.PrivateKey
}

protocol ProviderIdentityKeyStoring: ReceiptKeyStoring, AdmissionIdentityRecoveryKeyStoring {
    func loadBootstrapIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey?
    func loadOrStoreBootstrapIdentity(
        providerId: String,
        candidate: Curve25519.Signing.PrivateKey
    ) throws -> Curve25519.Signing.PrivateKey
    func loadOrStoreAdmissionIdentity(
        providerId: String,
        candidate: Curve25519.Signing.PrivateKey
    ) throws -> Curve25519.Signing.PrivateKey
    func loadPrevious(providerId: String) throws -> Curve25519.Signing.PrivateKey?
    func loadPreviousAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey?
    func loadPreviousAdmissionIdentityState(providerId: String) throws -> AdmissionIdentityPreviousKeyState?
    func loadAdmissionIdentityRecoveryMarker(providerId: String) throws -> Data?
    func commitAdmissionIdentityRotation(
        providerId: String,
        expectedPublicKey: Data,
        previousValidUntil: Date?
    ) throws -> Curve25519.Signing.PrivateKey
    func commitAdmissionIdentityRecovery(
        providerId: String,
        expectedPublicKey: Data
    ) throws -> Curve25519.Signing.PrivateKey
    func cancelAdmissionIdentityRotation(providerId: String) throws
}

extension AdmissionIdentityRecoveryKeyStoring {
    func beginAdmissionIdentityRecovery(
        providerId: String,
        allowExistingCurrent: Bool
    ) throws -> Curve25519.Signing.PrivateKey {
        try beginAdmissionIdentityRecovery(
            providerId: providerId,
            allowExistingCurrent: allowExistingCurrent,
            afterPendingPersisted: { _ in }
        )
    }
}

struct AdmissionIdentityPreviousKeyState: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey
    let validUntil: Date
}

enum ReceiptKeyStoreError: Error, Equatable {
    case duplicateCurrentKey(providerId: String)
    case missingCurrentKey(providerId: String)
    case invalidPrivateKeyData(providerId: String, byteCount: Int)
    case keychainReadFailed(providerId: String, status: OSStatus)
    case keychainWriteFailed(providerId: String, status: OSStatus)
    case keychainDeleteFailed(providerId: String, status: OSStatus)
    case keychainUpdateFailed(providerId: String, status: OSStatus)
    case missingAdmissionIdentity(providerId: String)
    case admissionIdentityCandidateMismatch(providerId: String)
    case admissionIdentityRecoveryNotRequired(providerId: String)
    case admissionIdentityRecoveryInProgress(providerId: String)
}

struct KeychainReceiptKeyStore: ProviderIdentityKeyStoring {
    static let currentService = "com.malibu.provider.receipt-key"
    static let previousService = "com.malibu.provider.receipt-key.prev"
    // Keep the existing service name so upgraded providers retain the same
    // identity. The key is admission identity for every provider, not only
    // the historical mp-* bootstrap path.
    static let bootstrapIdentityService = "com.malibu.provider.bootstrap-identity-key"
    static let admissionIdentityService = bootstrapIdentityService
    static let pendingAdmissionIdentityService = "com.malibu.provider.admission-identity-key.pending"
    static let previousAdmissionIdentityService = "com.malibu.provider.admission-identity-key.prev"
    static let previousAdmissionIdentityValidUntilService = "com.malibu.provider.admission-identity-key.prev-valid-until"
    static let admissionIdentityRecoveryMarkerService = "com.malibu.provider.admission-identity-recovery.marker"
    private static let legacyServicePrefix = "com.streamvc.macprovider"
    private static let currentServicePrefix = "com.malibu.provider"
    static let previousRetention: TimeInterval = 7 * 24 * 60 * 60

    private static let mutationLock = NSLock()
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        try cleanupExpiredPrevious(providerId: providerId)

        if let existing = try loadCurrent(providerId: providerId) {
            return existing
        }

        let generated = Curve25519.Signing.PrivateKey()
        do {
            try storeNew(providerId: providerId, privateKey: generated)
            return generated
        } catch ReceiptKeyStoreError.duplicateCurrentKey {
            guard let winner = try loadCurrent(providerId: providerId) else {
                throw ReceiptKeyStoreError.missingCurrentKey(providerId: providerId)
            }
            return winner
        }
    }

    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadKey(providerId: providerId, service: Self.currentService)
    }

    func loadBootstrapIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadKey(providerId: providerId, service: Self.bootstrapIdentityService)
    }

    func loadAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadKey(providerId: providerId, service: Self.admissionIdentityService)
    }

    func loadPendingAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadKey(providerId: providerId, service: Self.pendingAdmissionIdentityService)
    }

    func loadPreviousAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadPreviousAdmissionIdentityState(providerId: providerId)?.privateKey
    }

    func loadPreviousAdmissionIdentityState(providerId: String) throws -> AdmissionIdentityPreviousKeyState? {
        let privateKey = try loadKey(providerId: providerId, service: Self.previousAdmissionIdentityService)
        let validUntilData = try loadData(
            providerId: providerId,
            service: Self.previousAdmissionIdentityValidUntilService
        )
        guard let privateKey, let validUntilData,
              let validUntilText = String(data: validUntilData, encoding: .utf8),
              let validUntil = Self.parsePreviousAdmissionIdentityDeadline(validUntilText),
              validUntil > now() else {
            // A rollback key without the authenticated coordinator deadline is
            // not admissible. Delete incomplete or expired pairs fail-closed.
            try deleteIfPresent(providerId: providerId, service: Self.previousAdmissionIdentityService)
            try deleteIfPresent(providerId: providerId, service: Self.previousAdmissionIdentityValidUntilService)
            return nil
        }
        return AdmissionIdentityPreviousKeyState(
            privateKey: privateKey,
            validUntil: validUntil
        )
    }

    func loadPrevious(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadKey(providerId: providerId, service: Self.previousService)
    }

    /// Preserve the first installer receipt key as the initial admission
    /// identity. Returning the existing winner makes concurrent bootstrap and
    /// startup races converge; later rotations use the pending/current CAS.
    func loadOrStoreBootstrapIdentity(
        providerId: String,
        candidate: Curve25519.Signing.PrivateKey
    ) throws -> Curve25519.Signing.PrivateKey {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        if let existing = try loadBootstrapIdentity(providerId: providerId) {
            return existing
        }
        let status = SecItemAdd(Self.addQuery(
            providerId: providerId,
            service: Self.bootstrapIdentityService,
            privateKey: candidate
        ) as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return candidate
        case errSecDuplicateItem:
            guard let winner = try loadBootstrapIdentity(providerId: providerId) else {
                throw ReceiptKeyStoreError.missingCurrentKey(providerId: providerId)
            }
            return winner
        default:
            throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: status)
        }
    }

    func loadOrStoreAdmissionIdentity(
        providerId: String,
        candidate: Curve25519.Signing.PrivateKey
    ) throws -> Curve25519.Signing.PrivateKey {
        try loadOrStoreBootstrapIdentity(providerId: providerId, candidate: candidate)
    }

    /// Stage exactly one restart-safe rotation candidate. Repeated commands
    /// converge on the same pending key until coordinator admission commits or
    /// the operator explicitly cancels it.
    func beginAdmissionIdentityRotation(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        if try loadData(providerId: providerId, service: Self.admissionIdentityRecoveryMarkerService) != nil {
            throw ReceiptKeyStoreError.admissionIdentityRecoveryInProgress(providerId: providerId)
        }
        guard try loadAdmissionIdentity(providerId: providerId) != nil else {
            throw ReceiptKeyStoreError.missingAdmissionIdentity(providerId: providerId)
        }
        if let pending = try loadPendingAdmissionIdentity(providerId: providerId) {
            return pending
        }
        let candidate = Curve25519.Signing.PrivateKey()
        let status = SecItemAdd(Self.addQuery(
            providerId: providerId,
            service: Self.pendingAdmissionIdentityService,
            privateKey: candidate
        ) as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return candidate
        case errSecDuplicateItem:
            guard let winner = try loadPendingAdmissionIdentity(providerId: providerId) else {
                throw ReceiptKeyStoreError.missingAdmissionIdentity(providerId: providerId)
            }
            return winner
        default:
            throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: status)
        }
    }

    /// Stages a new identity only when local current custody is absent. The
    /// coordinator will accept it solely under an active operator-approved
    /// recovery policy and exact bearer proof.
    func beginAdmissionIdentityRecovery(
        providerId: String,
        allowExistingCurrent: Bool = false
    ) throws -> Curve25519.Signing.PrivateKey {
        try beginAdmissionIdentityRecovery(
            providerId: providerId,
            allowExistingCurrent: allowExistingCurrent,
            afterPendingPersisted: { _ in }
        )
    }

    func beginAdmissionIdentityRecovery(
        providerId: String,
        allowExistingCurrent: Bool,
        afterPendingPersisted: (Curve25519.Signing.PrivateKey) throws -> Void
    ) throws -> Curve25519.Signing.PrivateKey {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        if try loadAdmissionIdentity(providerId: providerId) != nil && !allowExistingCurrent {
            throw ReceiptKeyStoreError.admissionIdentityRecoveryNotRequired(providerId: providerId)
        }
        if let pending = try loadPendingAdmissionIdentity(providerId: providerId) {
            try afterPendingPersisted(pending)
            try replaceData(
                providerId: providerId,
                service: Self.admissionIdentityRecoveryMarkerService,
                data: pending.publicKey.rawRepresentation
            )
            return pending
        }
        let candidate = Curve25519.Signing.PrivateKey()
        let status = SecItemAdd(Self.addQuery(
            providerId: providerId,
            service: Self.pendingAdmissionIdentityService,
            privateKey: candidate
        ) as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            try afterPendingPersisted(candidate)
            try replaceData(
                providerId: providerId,
                service: Self.admissionIdentityRecoveryMarkerService,
                data: candidate.publicKey.rawRepresentation
            )
            return candidate
        case errSecDuplicateItem:
            guard let winner = try loadPendingAdmissionIdentity(providerId: providerId) else {
                throw ReceiptKeyStoreError.missingAdmissionIdentity(providerId: providerId)
            }
            try afterPendingPersisted(winner)
            try replaceData(
                providerId: providerId,
                service: Self.admissionIdentityRecoveryMarkerService,
                data: winner.publicKey.rawRepresentation
            )
            return winner
        default:
            throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: status)
        }
    }

    func isAdmissionIdentityRecoveryPending(
        providerId: String,
        candidatePublicKey: Data
    ) throws -> Bool {
        try loadAdmissionIdentityRecoveryMarker(providerId: providerId) == candidatePublicKey
    }

    func loadAdmissionIdentityRecoveryMarker(providerId: String) throws -> Data? {
        try loadData(
            providerId: providerId,
            service: Self.admissionIdentityRecoveryMarkerService
        )
    }

    /// Commit only the candidate named by the coordinator's accepted response.
    /// The old key is retained locally for bounded software-rollback recovery;
    /// server policy decides whether that previous key is still admissible.
    func commitAdmissionIdentityRotation(
        providerId: String,
        expectedPublicKey: Data,
        previousValidUntil: Date?
    ) throws -> Curve25519.Signing.PrivateKey {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

        if let current = try loadAdmissionIdentity(providerId: providerId),
           current.publicKey.rawRepresentation == expectedPublicKey {
            try deleteIfPresent(providerId: providerId, service: Self.pendingAdmissionIdentityService)
            try deleteIfPresent(providerId: providerId, service: Self.admissionIdentityRecoveryMarkerService)
            return current
        }
        guard let current = try loadAdmissionIdentity(providerId: providerId) else {
            throw ReceiptKeyStoreError.missingAdmissionIdentity(providerId: providerId)
        }
        guard let pending = try loadPendingAdmissionIdentity(providerId: providerId),
              pending.publicKey.rawRepresentation == expectedPublicKey else {
            throw ReceiptKeyStoreError.admissionIdentityCandidateMismatch(providerId: providerId)
        }

        try deleteIfPresent(providerId: providerId, service: Self.previousAdmissionIdentityService)
        try deleteIfPresent(providerId: providerId, service: Self.previousAdmissionIdentityValidUntilService)
        if let previousValidUntil, previousValidUntil > now() {
            try addKey(
                providerId: providerId,
                service: Self.previousAdmissionIdentityService,
                privateKey: current
            )
            try replaceData(
                providerId: providerId,
                service: Self.previousAdmissionIdentityValidUntilService,
                data: Data(Self.formatPreviousAdmissionIdentityDeadline(previousValidUntil).utf8)
            )
        }
        try replaceKey(
            providerId: providerId,
            service: Self.admissionIdentityService,
            privateKey: pending
        )
        try deleteIfPresent(providerId: providerId, service: Self.pendingAdmissionIdentityService)
        try deleteIfPresent(providerId: providerId, service: Self.admissionIdentityRecoveryMarkerService)
        return pending
    }

    func commitAdmissionIdentityRecovery(
        providerId: String,
        expectedPublicKey: Data
    ) throws -> Curve25519.Signing.PrivateKey {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        if let current = try loadAdmissionIdentity(providerId: providerId),
           current.publicKey.rawRepresentation == expectedPublicKey {
            try deleteIfPresent(providerId: providerId, service: Self.pendingAdmissionIdentityService)
            try deleteIfPresent(providerId: providerId, service: Self.previousAdmissionIdentityService)
            try deleteIfPresent(providerId: providerId, service: Self.previousAdmissionIdentityValidUntilService)
            try deleteIfPresent(providerId: providerId, service: Self.admissionIdentityRecoveryMarkerService)
            return current
        }
        guard let pending = try loadPendingAdmissionIdentity(providerId: providerId),
              pending.publicKey.rawRepresentation == expectedPublicKey else {
            throw ReceiptKeyStoreError.admissionIdentityCandidateMismatch(providerId: providerId)
        }
        try replaceKey(
            providerId: providerId,
            service: Self.admissionIdentityService,
            privateKey: pending
        )
        try deleteIfPresent(providerId: providerId, service: Self.previousAdmissionIdentityService)
        try deleteIfPresent(providerId: providerId, service: Self.previousAdmissionIdentityValidUntilService)
        try deleteIfPresent(providerId: providerId, service: Self.pendingAdmissionIdentityService)
        try deleteIfPresent(providerId: providerId, service: Self.admissionIdentityRecoveryMarkerService)
        return pending
    }

    func cancelAdmissionIdentityRotation(providerId: String) throws {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        try deleteIfPresent(providerId: providerId, service: Self.pendingAdmissionIdentityService)
        try deleteIfPresent(providerId: providerId, service: Self.admissionIdentityRecoveryMarkerService)
    }

    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {
        let status = SecItemAdd(Self.addQuery(
            providerId: providerId,
            service: Self.currentService,
            privateKey: privateKey
        ) as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw ReceiptKeyStoreError.duplicateCurrentKey(providerId: providerId)
        default:
            throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: status)
        }
    }

    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }

        guard let current = try loadCurrent(providerId: providerId) else {
            throw ReceiptKeyStoreError.missingCurrentKey(providerId: providerId)
        }

        // Crash-safety order: commit the new key to .current FIRST so that, if
        // the process dies between the two writes, the binary still signs with
        // the key the coordinator already published. Then snapshot the old key
        // into .prev for operator recovery (.prev is never read for signing).
        try replaceKey(providerId: providerId, service: Self.currentService, privateKey: newKey)
        try deleteIfPresent(providerId: providerId, service: Self.previousService)
        try addKey(providerId: providerId, service: Self.previousService, privateKey: current)
    }

    private func cleanupExpiredPrevious(providerId: String) throws {
        try cleanupExpiredKey(
            providerId: providerId,
            service: Self.previousService,
            retention: Self.previousRetention
        )
    }

    private func cleanupExpiredKey(
        providerId: String,
        service: String,
        retention: TimeInterval
    ) throws {
        let query = Self.baseQuery(providerId: providerId, service: service)
            .merging([
                kSecReturnAttributes as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let attrs = result as? [String: Any] else {
                return
            }
            let modifiedAt = (attrs[kSecAttrModificationDate as String] as? Date)
                ?? (attrs[kSecAttrCreationDate as String] as? Date)
            guard let modifiedAt, now().timeIntervalSince(modifiedAt) > retention else {
                return
            }
            try deleteIfPresent(providerId: providerId, service: service)
        case errSecItemNotFound:
            return
        default:
            throw ReceiptKeyStoreError.keychainReadFailed(providerId: providerId, status: status)
        }
    }

    private func loadKey(providerId: String, service: String) throws -> Curve25519.Signing.PrivateKey? {
        if let privateKey = try loadKeyExact(providerId: providerId, service: service) {
            return privateKey
        }
        guard let legacyService = Self.legacyService(for: service),
              let legacyKey = try loadKeyExact(providerId: providerId, service: legacyService) else {
            return nil
        }
        try? migrateLegacyKeyIfAbsent(providerId: providerId, service: service, privateKey: legacyKey)
        return legacyKey
    }

    private func loadKeyExact(providerId: String, service: String) throws -> Curve25519.Signing.PrivateKey? {
        let query = Self.baseQuery(providerId: providerId, service: service)
            .merging([
                kSecReturnData as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                let count = (result as? Data)?.count ?? 0
                throw ReceiptKeyStoreError.invalidPrivateKeyData(providerId: providerId, byteCount: count)
            }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        case errSecItemNotFound:
            return nil
        default:
            throw ReceiptKeyStoreError.keychainReadFailed(providerId: providerId, status: status)
        }
    }

    private func loadData(providerId: String, service: String) throws -> Data? {
        if let data = try loadDataExact(providerId: providerId, service: service) {
            return data
        }
        guard let legacyService = Self.legacyService(for: service),
              let legacyData = try loadDataExact(providerId: providerId, service: legacyService) else {
            return nil
        }
        try? migrateLegacyDataIfAbsent(providerId: providerId, service: service, data: legacyData)
        return legacyData
    }

    private func loadDataExact(providerId: String, service: String) throws -> Data? {
        let query = Self.baseQuery(providerId: providerId, service: service)
            .merging([
                kSecReturnData as String: kCFBooleanTrue as Any,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw ReceiptKeyStoreError.invalidPrivateKeyData(providerId: providerId, byteCount: 0)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw ReceiptKeyStoreError.keychainReadFailed(providerId: providerId, status: status)
        }
    }

    private static func legacyService(for service: String) -> String? {
        guard service.hasPrefix(currentServicePrefix) else { return nil }
        return legacyServicePrefix + service.dropFirst(currentServicePrefix.count)
    }

    private func migrateLegacyKeyIfAbsent(
        providerId: String,
        service: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws {
        let status = SecItemAdd(Self.addQuery(
            providerId: providerId,
            service: service,
            privateKey: privateKey
        ) as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecDuplicateItem:
            return
        default:
            throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: status)
        }
    }

    private func migrateLegacyDataIfAbsent(providerId: String, service: String, data: Data) throws {
        let add = Self.baseQuery(providerId: providerId, service: service)
            .merging([
                kSecAttrSynchronizable as String: false,
                kSecValueData as String: data,
            ]) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecDuplicateItem:
            return
        default:
            throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: status)
        }
    }

    private func replaceData(providerId: String, service: String, data: Data) throws {
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: false,
        ]
        let status = SecItemUpdate(
            Self.baseQuery(providerId: providerId, service: service) as CFDictionary,
            values as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let add = Self.baseQuery(providerId: providerId, service: service)
                .merging(values) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: addStatus)
            }
        default:
            throw ReceiptKeyStoreError.keychainUpdateFailed(providerId: providerId, status: status)
        }
    }

    private static func formatPreviousAdmissionIdentityDeadline(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parsePreviousAdmissionIdentityDeadline(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: text)
    }

    private func addKey(
        providerId: String,
        service: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws {
        let status = SecItemAdd(Self.addQuery(
            providerId: providerId,
            service: service,
            privateKey: privateKey
        ) as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        default:
            throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: status)
        }
    }

    private func replaceKey(
        providerId: String,
        service: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws {
        let status = SecItemUpdate(
            Self.baseQuery(providerId: providerId, service: service) as CFDictionary,
            [
                kSecValueData as String: privateKey.rawRepresentation,
                kSecAttrSynchronizable as String: false,
            ] as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try addKey(providerId: providerId, service: service, privateKey: privateKey)
        default:
            throw ReceiptKeyStoreError.keychainUpdateFailed(providerId: providerId, status: status)
        }
    }

    private func deleteIfPresent(providerId: String, service: String) throws {
        let status = SecItemDelete(Self.baseQuery(providerId: providerId, service: service) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw ReceiptKeyStoreError.keychainDeleteFailed(providerId: providerId, status: status)
        }
    }

    static func baseQuery(providerId: String, service: String = currentService) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    static func addQuery(
        providerId: String,
        service: String = currentService,
        privateKey: Curve25519.Signing.PrivateKey
    ) -> [String: Any] {
        baseQuery(providerId: providerId, service: service)
            .merging([
                // Match provider bearer custody: use the legacy login Keychain
                // so the signed CLI's designated requirement remains the ACL
                // boundary across updates. macOS ignores kSecAttrAccessible on
                // this backend, so availability is the login-Keychain contract
                // and every operation explicitly forbids authentication UI.
                kSecAttrSynchronizable as String: false,
                kSecAttrLabel as String: "MacProvider receipt and admission identity key",
                kSecValueData as String: privateKey.rawRepresentation,
            ]) { _, new in new }
    }
}

private struct ProtectedFileIdentitySecretStore: Sendable {
    private let custody: ProtectedFileCredentialCustody

    init(rootDirectory: URL) {
        custody = ProtectedFileCredentialCustody(rootDirectory: rootDirectory)
    }

    func load(providerID: String, service: String) throws -> Data? {
        try custody.withLockedProviderDirectory(namespace: .identityKeys, providerID: providerID) { directory in
            try directory.read(name: fileName(service))?.data
        }
    }

    func add(providerID: String, service: String, data: Data) throws -> Bool {
        try custody.withLockedProviderDirectory(namespace: .identityKeys, providerID: providerID) { directory in
            do {
                try directory.add(name: fileName(service), data: data)
                return true
            } catch ProtectedFileCredentialCustodyError.duplicate {
                return false
            }
        }
    }

    func replace(providerID: String, service: String, data: Data) throws {
        try custody.withLockedProviderDirectory(namespace: .identityKeys, providerID: providerID) { directory in
            try directory.replace(name: fileName(service), data: data)
        }
    }

    func deleteIfPresent(providerID: String, service: String) throws {
        try custody.withLockedProviderDirectory(namespace: .identityKeys, providerID: providerID) { directory in
            try directory.deleteIfPresent(name: fileName(service))
        }
    }

    func modificationDate(providerID: String, service: String) throws -> Date? {
        try custody.withLockedProviderDirectory(namespace: .identityKeys, providerID: providerID) { directory in
            try directory.read(name: fileName(service))?.modifiedAt
        }
    }

    func secretURL(providerID: String, service: String) -> URL {
        custody.providerDirectoryURL(namespace: .identityKeys, providerID: providerID)
            .appendingPathComponent(fileName(service))
    }

    private func fileName(_ service: String) -> String {
        SHA256.hash(data: Data(service.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct ProtectedFileReceiptKeyStore: ProviderIdentityKeyStoring {
    private static let mutationLock = NSLock()
    private let store: ProtectedFileIdentitySecretStore
    private let now: @Sendable () -> Date

    init(rootDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = ProtectedFileIdentitySecretStore(rootDirectory: rootDirectory)
        self.now = now
    }

    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        try cleanupExpiredPrevious(providerId: providerId)
        if let existing = try loadCurrent(providerId: providerId) {
            return existing
        }
        let generated = Curve25519.Signing.PrivateKey()
        do {
            try storeNew(providerId: providerId, privateKey: generated)
            return generated
        } catch ReceiptKeyStoreError.duplicateCurrentKey {
            guard let winner = try loadCurrent(providerId: providerId) else {
                throw ReceiptKeyStoreError.missingCurrentKey(providerId: providerId)
            }
            return winner
        }
    }

    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadKey(providerId: providerId, service: KeychainReceiptKeyStore.currentService)
    }

    func loadBootstrapIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadKey(providerId: providerId, service: KeychainReceiptKeyStore.bootstrapIdentityService)
    }

    func loadAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadKey(providerId: providerId, service: KeychainReceiptKeyStore.admissionIdentityService)
    }

    func loadPendingAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadKey(providerId: providerId, service: KeychainReceiptKeyStore.pendingAdmissionIdentityService)
    }

    func loadPreviousAdmissionIdentity(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadPreviousAdmissionIdentityState(providerId: providerId)?.privateKey
    }

    func loadPreviousAdmissionIdentityState(providerId: String) throws -> AdmissionIdentityPreviousKeyState? {
        let privateKey = try loadKey(providerId: providerId, service: KeychainReceiptKeyStore.previousAdmissionIdentityService)
        let validUntilData = try loadData(
            providerId: providerId,
            service: KeychainReceiptKeyStore.previousAdmissionIdentityValidUntilService
        )
        guard let privateKey, let validUntilData,
              let validUntilText = String(data: validUntilData, encoding: .utf8),
              let validUntil = Self.parsePreviousAdmissionIdentityDeadline(validUntilText),
              validUntil > now() else {
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.previousAdmissionIdentityService)
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.previousAdmissionIdentityValidUntilService)
            return nil
        }
        return AdmissionIdentityPreviousKeyState(privateKey: privateKey, validUntil: validUntil)
    }

    func loadPrevious(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        try loadKey(providerId: providerId, service: KeychainReceiptKeyStore.previousService)
    }

    func loadOrStoreBootstrapIdentity(
        providerId: String,
        candidate: Curve25519.Signing.PrivateKey
    ) throws -> Curve25519.Signing.PrivateKey {
        try Self.withMutationLock {
            if let existing = try loadBootstrapIdentity(providerId: providerId) {
                return existing
            }
            if try addKeyIfAbsent(
                providerId: providerId,
                service: KeychainReceiptKeyStore.bootstrapIdentityService,
                privateKey: candidate
            ) {
                return candidate
            }
            guard let winner = try loadBootstrapIdentity(providerId: providerId) else {
                throw ReceiptKeyStoreError.missingCurrentKey(providerId: providerId)
            }
            return winner
        }
    }

    func loadOrStoreAdmissionIdentity(
        providerId: String,
        candidate: Curve25519.Signing.PrivateKey
    ) throws -> Curve25519.Signing.PrivateKey {
        try loadOrStoreBootstrapIdentity(providerId: providerId, candidate: candidate)
    }

    func beginAdmissionIdentityRotation(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        try Self.withMutationLock {
            if try loadAdmissionIdentityRecoveryMarker(providerId: providerId) != nil {
                throw ReceiptKeyStoreError.admissionIdentityRecoveryInProgress(providerId: providerId)
            }
            guard try loadAdmissionIdentity(providerId: providerId) != nil else {
                throw ReceiptKeyStoreError.missingAdmissionIdentity(providerId: providerId)
            }
            if let pending = try loadPendingAdmissionIdentity(providerId: providerId) {
                return pending
            }
            let candidate = Curve25519.Signing.PrivateKey()
            if try addKeyIfAbsent(
                providerId: providerId,
                service: KeychainReceiptKeyStore.pendingAdmissionIdentityService,
                privateKey: candidate
            ) {
                return candidate
            }
            guard let winner = try loadPendingAdmissionIdentity(providerId: providerId) else {
                throw ReceiptKeyStoreError.missingAdmissionIdentity(providerId: providerId)
            }
            return winner
        }
    }

    func beginAdmissionIdentityRecovery(
        providerId: String,
        allowExistingCurrent: Bool = false
    ) throws -> Curve25519.Signing.PrivateKey {
        try beginAdmissionIdentityRecovery(
            providerId: providerId,
            allowExistingCurrent: allowExistingCurrent,
            afterPendingPersisted: { _ in }
        )
    }

    func beginAdmissionIdentityRecovery(
        providerId: String,
        allowExistingCurrent: Bool,
        afterPendingPersisted: (Curve25519.Signing.PrivateKey) throws -> Void
    ) throws -> Curve25519.Signing.PrivateKey {
        try Self.withMutationLock {
            if try loadAdmissionIdentity(providerId: providerId) != nil && !allowExistingCurrent {
                throw ReceiptKeyStoreError.admissionIdentityRecoveryNotRequired(providerId: providerId)
            }
            if let pending = try loadPendingAdmissionIdentity(providerId: providerId) {
                try afterPendingPersisted(pending)
                try replaceData(
                    providerId: providerId,
                    service: KeychainReceiptKeyStore.admissionIdentityRecoveryMarkerService,
                    data: pending.publicKey.rawRepresentation
                )
                return pending
            }
            let candidate = Curve25519.Signing.PrivateKey()
            if try addKeyIfAbsent(
                providerId: providerId,
                service: KeychainReceiptKeyStore.pendingAdmissionIdentityService,
                privateKey: candidate
            ) {
                try afterPendingPersisted(candidate)
                try replaceData(
                    providerId: providerId,
                    service: KeychainReceiptKeyStore.admissionIdentityRecoveryMarkerService,
                    data: candidate.publicKey.rawRepresentation
                )
                return candidate
            }
            guard let winner = try loadPendingAdmissionIdentity(providerId: providerId) else {
                throw ReceiptKeyStoreError.missingAdmissionIdentity(providerId: providerId)
            }
            try afterPendingPersisted(winner)
            try replaceData(
                providerId: providerId,
                service: KeychainReceiptKeyStore.admissionIdentityRecoveryMarkerService,
                data: winner.publicKey.rawRepresentation
            )
            return winner
        }
    }

    func isAdmissionIdentityRecoveryPending(providerId: String, candidatePublicKey: Data) throws -> Bool {
        try loadAdmissionIdentityRecoveryMarker(providerId: providerId) == candidatePublicKey
    }

    func loadAdmissionIdentityRecoveryMarker(providerId: String) throws -> Data? {
        try loadData(providerId: providerId, service: KeychainReceiptKeyStore.admissionIdentityRecoveryMarkerService)
    }

    func commitAdmissionIdentityRotation(
        providerId: String,
        expectedPublicKey: Data,
        previousValidUntil: Date?
    ) throws -> Curve25519.Signing.PrivateKey {
        try Self.withMutationLock {
            if let current = try loadAdmissionIdentity(providerId: providerId),
               current.publicKey.rawRepresentation == expectedPublicKey {
                try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.pendingAdmissionIdentityService)
                try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.admissionIdentityRecoveryMarkerService)
                return current
            }
            guard let current = try loadAdmissionIdentity(providerId: providerId) else {
                throw ReceiptKeyStoreError.missingAdmissionIdentity(providerId: providerId)
            }
            guard let pending = try loadPendingAdmissionIdentity(providerId: providerId),
                  pending.publicKey.rawRepresentation == expectedPublicKey else {
                throw ReceiptKeyStoreError.admissionIdentityCandidateMismatch(providerId: providerId)
            }

            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.previousAdmissionIdentityService)
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.previousAdmissionIdentityValidUntilService)
            if let previousValidUntil, previousValidUntil > now() {
                try addKey(
                    providerId: providerId,
                    service: KeychainReceiptKeyStore.previousAdmissionIdentityService,
                    privateKey: current
                )
                try replaceData(
                    providerId: providerId,
                    service: KeychainReceiptKeyStore.previousAdmissionIdentityValidUntilService,
                    data: Data(Self.formatPreviousAdmissionIdentityDeadline(previousValidUntil).utf8)
                )
            }
            try replaceKey(
                providerId: providerId,
                service: KeychainReceiptKeyStore.admissionIdentityService,
                privateKey: pending
            )
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.pendingAdmissionIdentityService)
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.admissionIdentityRecoveryMarkerService)
            return pending
        }
    }

    func commitAdmissionIdentityRecovery(providerId: String, expectedPublicKey: Data) throws -> Curve25519.Signing.PrivateKey {
        try Self.withMutationLock {
            if let current = try loadAdmissionIdentity(providerId: providerId),
               current.publicKey.rawRepresentation == expectedPublicKey {
                try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.pendingAdmissionIdentityService)
                try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.previousAdmissionIdentityService)
                try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.previousAdmissionIdentityValidUntilService)
                try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.admissionIdentityRecoveryMarkerService)
                return current
            }
            guard let pending = try loadPendingAdmissionIdentity(providerId: providerId),
                  pending.publicKey.rawRepresentation == expectedPublicKey else {
                throw ReceiptKeyStoreError.admissionIdentityCandidateMismatch(providerId: providerId)
            }
            try replaceKey(
                providerId: providerId,
                service: KeychainReceiptKeyStore.admissionIdentityService,
                privateKey: pending
            )
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.previousAdmissionIdentityService)
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.previousAdmissionIdentityValidUntilService)
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.pendingAdmissionIdentityService)
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.admissionIdentityRecoveryMarkerService)
            return pending
        }
    }

    func cancelAdmissionIdentityRotation(providerId: String) throws {
        try Self.withMutationLock {
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.pendingAdmissionIdentityService)
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.admissionIdentityRecoveryMarkerService)
        }
    }

    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {
        if try !addKeyIfAbsent(providerId: providerId, service: KeychainReceiptKeyStore.currentService, privateKey: privateKey) {
            throw ReceiptKeyStoreError.duplicateCurrentKey(providerId: providerId)
        }
    }

    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {
        try Self.withMutationLock {
            guard let current = try loadCurrent(providerId: providerId) else {
                throw ReceiptKeyStoreError.missingCurrentKey(providerId: providerId)
            }
            try replaceKey(providerId: providerId, service: KeychainReceiptKeyStore.currentService, privateKey: newKey)
            try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.previousService)
            try addKey(providerId: providerId, service: KeychainReceiptKeyStore.previousService, privateKey: current)
        }
    }

    func protectedFileURL(providerId: String, service: String) -> URL {
        store.secretURL(providerID: providerId, service: service)
    }

    private func cleanupExpiredPrevious(providerId: String) throws {
        guard let modified = try store.modificationDate(
            providerID: providerId,
            service: KeychainReceiptKeyStore.previousService
        ),
              now().timeIntervalSince(modified) > KeychainReceiptKeyStore.previousRetention else {
            return
        }
        try deleteIfPresent(providerId: providerId, service: KeychainReceiptKeyStore.previousService)
    }

    private func loadKey(providerId: String, service: String) throws -> Curve25519.Signing.PrivateKey? {
        guard let data = try loadData(providerId: providerId, service: service) else { return nil }
        guard data.count == 32 else {
            throw ReceiptKeyStoreError.invalidPrivateKeyData(providerId: providerId, byteCount: data.count)
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private func loadData(providerId: String, service: String) throws -> Data? {
        do {
            return try store.load(providerID: providerId, service: service)
        } catch {
            throw ReceiptKeyStoreError.keychainReadFailed(providerId: providerId, status: errSecIO)
        }
    }

    private func addKeyIfAbsent(
        providerId: String,
        service: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Bool {
        try addDataIfAbsent(providerId: providerId, service: service, data: privateKey.rawRepresentation)
    }

    private func addKey(
        providerId: String,
        service: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws {
        if try !addKeyIfAbsent(providerId: providerId, service: service, privateKey: privateKey) {
            throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: errSecDuplicateItem)
        }
    }

    private func addDataIfAbsent(providerId: String, service: String, data: Data) throws -> Bool {
        do {
            return try store.add(providerID: providerId, service: service, data: data)
        } catch {
            throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: errSecIO)
        }
    }

    private func replaceKey(
        providerId: String,
        service: String,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws {
        try replaceData(providerId: providerId, service: service, data: privateKey.rawRepresentation)
    }

    private func replaceData(providerId: String, service: String, data: Data) throws {
        do {
            try store.replace(providerID: providerId, service: service, data: data)
        } catch {
            throw ReceiptKeyStoreError.keychainWriteFailed(providerId: providerId, status: errSecIO)
        }
    }

    private func deleteIfPresent(providerId: String, service: String) throws {
        do {
            try store.deleteIfPresent(providerID: providerId, service: service)
        } catch {
            throw ReceiptKeyStoreError.keychainDeleteFailed(providerId: providerId, status: errSecIO)
        }
    }

    private static func withMutationLock<T>(_ operation: () throws -> T) throws -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return try operation()
    }

    private static func formatPreviousAdmissionIdentityDeadline(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parsePreviousAdmissionIdentityDeadline(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: text)
    }
}
