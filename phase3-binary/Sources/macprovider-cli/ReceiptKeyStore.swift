import CryptoKit
import Foundation
import Security

protocol ReceiptKeyStoring: Sendable {
    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey
    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey?
    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws
    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws
}

enum ReceiptKeyStoreError: Error, Equatable {
    case duplicateCurrentKey(providerId: String)
    case missingCurrentKey(providerId: String)
    case invalidPrivateKeyData(providerId: String, byteCount: Int)
    case keychainReadFailed(providerId: String, status: OSStatus)
    case keychainWriteFailed(providerId: String, status: OSStatus)
    case keychainDeleteFailed(providerId: String, status: OSStatus)
    case keychainUpdateFailed(providerId: String, status: OSStatus)
}

struct KeychainReceiptKeyStore: ReceiptKeyStoring {
    static let currentService = "com.streamvc.macprovider.receipt-key"
    static let previousService = "com.streamvc.macprovider.receipt-key.prev"
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

        try deleteIfPresent(providerId: providerId, service: Self.previousService)
        try addKey(providerId: providerId, service: Self.previousService, privateKey: current)
        do {
            try replaceKey(providerId: providerId, service: Self.currentService, privateKey: newKey)
        } catch {
            try? deleteIfPresent(providerId: providerId, service: Self.previousService)
            throw error
        }
    }

    private func cleanupExpiredPrevious(providerId: String) throws {
        let query = Self.baseQuery(providerId: providerId, service: Self.previousService)
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
            guard let modifiedAt, now().timeIntervalSince(modifiedAt) > Self.previousRetention else {
                return
            }
            try deleteIfPresent(providerId: providerId, service: Self.previousService)
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
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId,
        ]
    }

    static func addQuery(
        providerId: String,
        service: String = currentService,
        privateKey: Curve25519.Signing.PrivateKey
    ) -> [String: Any] {
        baseQuery(providerId: providerId, service: service)
            .merging([
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: false,
                kSecValueData as String: privateKey.rawRepresentation,
            ]) { _, new in new }
    }
}
