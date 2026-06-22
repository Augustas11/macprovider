import CryptoKit
import Foundation

final class InMemoryReceiptKeyStore: ReceiptKeyStoring {
    private struct StoredKey {
        var key: Curve25519.Signing.PrivateKey
        var updatedAt: Date
    }

    private let lock = NSLock()
    private var current: [String: StoredKey] = [:]
    private var previous: [String: StoredKey] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }

        cleanupExpiredPreviousLocked(providerId: providerId)

        if let existing = current[providerId]?.key {
            return existing
        }

        let generated = Curve25519.Signing.PrivateKey()
        current[providerId] = StoredKey(key: generated, updatedAt: now())
        return generated
    }

    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        return current[providerId]?.key
    }

    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {
        lock.lock()
        defer { lock.unlock() }

        if current[providerId] != nil {
            throw ReceiptKeyStoreError.duplicateCurrentKey(providerId: providerId)
        }
        current[providerId] = StoredKey(key: privateKey, updatedAt: now())
    }

    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let existing = current[providerId] else {
            throw ReceiptKeyStoreError.missingCurrentKey(providerId: providerId)
        }
        previous[providerId] = StoredKey(key: existing.key, updatedAt: now())
        current[providerId] = StoredKey(key: newKey, updatedAt: now())
    }

    func previousKeyForTest(providerId: String) -> Curve25519.Signing.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        return previous[providerId]?.key
    }

    private func cleanupExpiredPreviousLocked(providerId: String) {
        guard let stored = previous[providerId],
              now().timeIntervalSince(stored.updatedAt) > KeychainReceiptKeyStore.previousRetention else {
            return
        }
        previous[providerId] = nil
    }
}
