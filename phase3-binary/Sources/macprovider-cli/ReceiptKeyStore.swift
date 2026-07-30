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

struct KeychainReceiptKeyStore: ReceiptKeyStoring, AdmissionIdentityRecoveryKeyStoring {
    static let currentService = "com.streamvc.macprovider.receipt-key"
    static let previousService = "com.streamvc.macprovider.receipt-key.prev"
    // Keep the existing service name so upgraded providers retain the same
    // identity. The key is admission identity for every provider, not only
    // the historical mp-* bootstrap path.
    static let bootstrapIdentityService = "com.streamvc.macprovider.bootstrap-identity-key"
    static let admissionIdentityService = bootstrapIdentityService
    static let pendingAdmissionIdentityService = "com.streamvc.macprovider.admission-identity-key.pending"
    static let previousAdmissionIdentityService = "com.streamvc.macprovider.admission-identity-key.prev"
    static let previousAdmissionIdentityValidUntilService = "com.streamvc.macprovider.admission-identity-key.prev-valid-until"
    static let admissionIdentityRecoveryMarkerService = "com.streamvc.macprovider.admission-identity-recovery.marker"
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
