import CryptoKit
import Foundation

/// Wraps another ``ReceiptKeyStoring`` and caches the result of
/// ``loadCurrent`` in process memory. The Keychain hit happens once per
/// process lifetime per ``providerId``; subsequent receipt builds reuse the
/// cached signing key, satisfying SPEC-015 §7.1 step 5 ("MUST cache for
/// process lifetime") and closing the TOCTOU window where ``swapToCurrent``
/// could otherwise observe a different key than the eligibility check ran
/// against.
///
/// ``swapToCurrent`` and ``storeNew`` invalidate the cache so the next read
/// surfaces the just-installed key.
final class CachedReceiptKeyStore: ReceiptKeyStoring, @unchecked Sendable {
    private let underlying: ReceiptKeyStoring
    private let lock = NSLock()
    private var cache: [String: Curve25519.Signing.PrivateKey] = [:]

    init(_ underlying: ReceiptKeyStoring) {
        self.underlying = underlying
    }

    func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey {
        if let cached = cachedKey(forProviderId: providerId) {
            return cached
        }
        let key = try underlying.loadOrGenerate(providerId: providerId)
        store(key: key, forProviderId: providerId)
        return key
    }

    func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey? {
        if let cached = cachedKey(forProviderId: providerId) {
            return cached
        }
        guard let key = try underlying.loadCurrent(providerId: providerId) else {
            return nil
        }
        store(key: key, forProviderId: providerId)
        return key
    }

    func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws {
        try underlying.storeNew(providerId: providerId, privateKey: privateKey)
        store(key: privateKey, forProviderId: providerId)
    }

    func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws {
        try underlying.swapToCurrent(providerId: providerId, newKey: newKey)
        store(key: newKey, forProviderId: providerId)
    }

    private func cachedKey(forProviderId providerId: String) -> Curve25519.Signing.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        return cache[providerId]
    }

    private func store(key: Curve25519.Signing.PrivateKey, forProviderId providerId: String) {
        lock.lock()
        cache[providerId] = key
        lock.unlock()
    }
}
