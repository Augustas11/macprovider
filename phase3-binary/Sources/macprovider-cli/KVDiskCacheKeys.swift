/// KVDiskCacheKeys — SPEC-037 FR-KVP6 key hierarchy and index hiding.
///
/// Owns: the one canonical-key-bytes function (trim + NFC + UTF-8), the HMAC index
/// (base16(HMAC-SHA256(index_key, canonical_key_bytes))), the HKDF-SHA256 index-key
/// derivation with the spec's literal labels, the per-epoch master + per-entry DEK
/// Keychain items (Data-Protection, AfterFirstUnlockThisDeviceOnly, non-interactive,
/// non-synchronizable), the incarnation-tagged ownership model for abort-safe DEK
/// cleanup, service-prefix enumeration for uninstall, epoch-rotation Keychain steps,
/// and pre-unlock dormancy signaling. The AES-256-GCM chunk seal/open helpers live
/// here too (they consume the entry DEK).
///
/// The Keychain is abstracted behind `KVKeychain` so all logic is testable with an
/// in-memory double; only the thin `KVSecItemKeychain` adapter touches `SecItem`.
///
/// Reference: specs/SPEC-037-kv-survival-restart.md FR-KVP6, §5a AAD/blob.

import CryptoKit
import Darwin
import Foundation
import Security

// MARK: - Canonical key bytes + index (FR-KVP6)

enum KVCanonicalKey {
    /// The one canonical-key-bytes function used everywhere (lookup, write, purge,
    /// tombstone): trim whitespace per the shipped FR-CI1 handling, apply Unicode
    /// NFC normalization, encode UTF-8. Composed and decomposed forms of one logical
    /// key therefore map to one index (positive equivalence, AC-1).
    static func canonicalBytes(_ key: String) -> Data {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let nfc = trimmed.precomposedStringWithCanonicalMapping
        return Data(nfc.utf8)
    }
}

// MARK: - Keychain abstraction

/// One enumerated Keychain generic-password item (service-prefix scan).
struct KVKeychainItem: Sendable, Equatable {
    let service: String
    let account: String
    /// Creating write's incarnation identifier (ownership-checked cleanup, FR-KVP6).
    let incarnation: String
}

/// Errors distinguish *unavailable* (pre-unlock / missing entitlement → dormancy,
/// never a serve-loop failure) from *hard* failures and duplicates.
enum KVKeychainError: Error, Equatable {
    /// Material temporarily/structurally unavailable → tier dormant (FR-KVP6).
    case unavailable(OSStatus)
    /// A genuine operation failure.
    case failed(OSStatus)
    /// Add hit an existing item (caller resolves via delete-then-add).
    case duplicate
    /// A create/delete could not be verified (post-op existence check disagreed).
    case verificationFailed
}

/// Abstract Keychain surface. All lookups are non-interactive; a locked or
/// entitlement-less store surfaces `.unavailable`, driving dormancy.
protocol KVKeychain: Sendable {
    /// Add a generic-password item. Throws `.duplicate` if one already exists.
    func add(service: String, account: String, secret: Data, incarnation: String) throws
    /// Copy the secret bytes, or nil when absent. `.unavailable` ⇒ dormancy.
    func copySecret(service: String, account: String) throws -> Data?
    /// Copy the incarnation attribute of an item, or nil when absent.
    func copyIncarnation(service: String, account: String) throws -> String?
    /// Delete a single item (no-op if absent).
    func delete(service: String, account: String) throws
    /// Enumerate all items whose service begins with `prefix`.
    func enumerate(servicePrefix: String) throws -> [KVKeychainItem]
}

// MARK: - Service naming (FR-KVP6)

/// Deterministic Keychain service/account naming. Every item for a namespace shares
/// a service prefix so uninstall can enumerate + delete without trusting metadata.
struct KVKeychainNaming: Sendable {
    /// Product-wide root for all KV disk-cache Keychain items.
    static let root = "live.malibu.provider.kv-cache.v1"

    let namespaceID: String

    /// Fixed-length digest of the namespace ID (M-15). Using a 32-hex digest plus a
    /// terminating delimiter makes the enumeration prefix unambiguous — namespace
    /// "A" can never prefix-match namespace "AB" (or "A.B") regardless of how the raw
    /// provider ID is punctuated — and additionally hides the raw provider ID.
    private var namespaceDigest: String {
        SHA256.hash(data: Data(namespaceID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Prefix covering every item (masters + DEKs) for this namespace. The trailing
    /// `;` terminates the namespace field so no other namespace's items can share it.
    var servicePrefix: String { "\(Self.root).ns:\(namespaceDigest);" }

    func masterService(epoch: Int) -> String { "\(servicePrefix)epoch:\(epoch);master" }
    func dekService(epoch: Int) -> String { "\(servicePrefix)epoch:\(epoch);dek" }

    /// Fixed account for the single per-epoch master item.
    static let masterAccount = "master"
}

// MARK: - Key manager (FR-KVP6 hierarchy)

/// Manages epoch masters, HKDF index keys, and per-entry DEKs over an injectable
/// Keychain. Pure-logic (no fs I/O); the store actor owns one instance per namespace.
struct KVKeyManager: Sendable {
    let keychain: any KVKeychain
    let naming: KVKeychainNaming

    /// Literal HKDF salt (FR-KVP6). Fixed forever for v1.
    static let hkdfSalt = Data("macprovider-kv-v1".utf8)

    init(keychain: any KVKeychain, namespaceID: String) {
        self.keychain = keychain
        self.naming = KVKeychainNaming(namespaceID: namespaceID)
    }

    // MARK: Epoch master

    /// Load the epoch master secret, or nil when absent. `.unavailable` ⇒ dormancy.
    func epochMaster(epoch: Int) throws -> Data? {
        try keychain.copySecret(service: naming.masterService(epoch: epoch),
                                account: KVKeychainNaming.masterAccount)
    }

    /// Create + verify a fresh 32-byte epoch master. Idempotent-safe: an existing
    /// item is deleted then re-added (rotation re-entry after a crash).
    @discardableResult
    func createEpochMaster(epoch: Int, incarnation: String) throws -> Data {
        let secret = try Self.randomBytes(32)
        let service = naming.masterService(epoch: epoch)
        do {
            try keychain.add(service: service, account: KVKeychainNaming.masterAccount,
                             secret: secret, incarnation: incarnation)
        } catch KVKeychainError.duplicate {
            try keychain.delete(service: service, account: KVKeychainNaming.masterAccount)
            try keychain.add(service: service, account: KVKeychainNaming.masterAccount,
                             secret: secret, incarnation: incarnation)
        }
        guard let readback = try keychain.copySecret(service: service, account: KVKeychainNaming.masterAccount),
              readback == secret else {
            throw KVKeychainError.verificationFailed
        }
        return secret
    }

    /// Delete all Keychain items for one epoch (master + every entry DEK) and verify
    /// absence. Used by epoch rotation (purge-all) and cap-forced rotation.
    func deleteEpochItems(epoch: Int) throws {
        let items = try keychain.enumerate(servicePrefix: naming.servicePrefix)
        let masterService = naming.masterService(epoch: epoch)
        let dekService = naming.dekService(epoch: epoch)
        for item in items where item.service == masterService || item.service == dekService {
            try keychain.delete(service: item.service, account: item.account)
        }
        // Verify absence.
        let after = try keychain.enumerate(servicePrefix: naming.servicePrefix)
        guard !after.contains(where: { $0.service == masterService || $0.service == dekService }) else {
            throw KVKeychainError.verificationFailed
        }
    }

    /// Delete every Keychain item for the namespace (uninstall, `--forget`).
    func deleteAllNamespaceItems() throws {
        let items = try keychain.enumerate(servicePrefix: naming.servicePrefix)
        for item in items {
            try keychain.delete(service: item.service, account: item.account)
        }
        guard try keychain.enumerate(servicePrefix: naming.servicePrefix).isEmpty else {
            throw KVKeychainError.verificationFailed
        }
    }

    // MARK: Index key + HMAC index (FR-KVP6)

    /// HKDF-SHA256 index key: salt = "macprovider-kv-v1", info = "index/<epoch>",
    /// L = 32. Literal labels are normative; a conformance vector pins the derivation.
    static func deriveIndexKey(epochMaster: Data, epoch: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: epochMaster),
            salt: hkdfSalt,
            info: Data("index/\(epoch)".utf8),
            outputByteCount: 32)
    }

    /// base16(HMAC-SHA256(index_key, canonical_key_bytes)). Computed only inside the
    /// owning process; the raw key never appears in any path, log, or manifest field.
    static func indexHMAC(canonicalKeyBytes: Data, indexKey: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: canonicalKeyBytes, using: indexKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// Compute the index for a raw conversation key at the given epoch. Returns nil
    /// only when the epoch master is unavailable (dormancy handled by caller).
    func computeIndex(rawKey: String, epoch: Int) throws -> String? {
        guard let master = try epochMaster(epoch: epoch) else { return nil }
        let indexKey = Self.deriveIndexKey(epochMaster: master, epoch: epoch)
        let canonical = KVCanonicalKey.canonicalBytes(rawKey)
        return Self.indexHMAC(canonicalKeyBytes: canonical, indexKey: indexKey)
    }

    // MARK: Entry DEK (FR-KVP6 revocation authority)

    /// Load an entry DEK secret, or nil when absent/destroyed (→ tombstoned miss).
    func entryDEK(epoch: Int, index: String) throws -> Data? {
        try keychain.copySecret(service: naming.dekService(epoch: epoch), account: index)
    }

    /// Load the incarnation that created an entry DEK (ownership-checked cleanup).
    func entryDEKIncarnation(epoch: Int, index: String) throws -> String? {
        try keychain.copyIncarnation(service: naming.dekService(epoch: epoch), account: index)
    }

    /// Create + verify a fresh entry DEK. Re-creating an index after eviction/purge
    /// deletes any residual item then adds fresh (`errSecDuplicateItem` ⇒
    /// delete-then-add). Records the creating write's incarnation identifier.
    @discardableResult
    func createEntryDEK(epoch: Int, index: String, incarnation: String) throws -> Data {
        let secret = try Self.randomBytes(32)
        let service = naming.dekService(epoch: epoch)
        do {
            try keychain.add(service: service, account: index, secret: secret, incarnation: incarnation)
        } catch KVKeychainError.duplicate {
            try keychain.delete(service: service, account: index)
            try keychain.add(service: service, account: index, secret: secret, incarnation: incarnation)
        }
        guard let readback = try keychain.copySecret(service: service, account: index),
              readback == secret else {
            throw KVKeychainError.verificationFailed
        }
        return secret
    }

    /// Destroy an entry DEK (purge/eviction revocation authority) and verify absence.
    func destroyEntryDEK(epoch: Int, index: String) throws {
        let service = naming.dekService(epoch: epoch)
        try keychain.delete(service: service, account: index)
        guard try keychain.copySecret(service: service, account: index) == nil else {
            throw KVKeychainError.verificationFailed
        }
    }

    /// Ownership-checked abort deletion: delete an entry DEK only if it still carries
    /// the aborting write's own incarnation (so a delayed abort can never delete a
    /// fresh DEK re-created after a purge or eviction — AC-4).
    func destroyEntryDEKIfOwnedBy(epoch: Int, index: String, incarnation: String) throws {
        guard let owner = try entryDEKIncarnation(epoch: epoch, index: index) else { return }
        guard owner == incarnation else { return }
        try destroyEntryDEK(epoch: epoch, index: index)
    }

    /// Count of live Keychain items for the namespace (FR-KVP12 inspection surface).
    func keychainItemCount() throws -> Int {
        try keychain.enumerate(servicePrefix: naming.servicePrefix).count
    }

    /// Reconcile orphaned entry DEKs at activation (FR-KVP6 / M-E): enumerate the
    /// current-epoch DEK items by the delimited service prefix and destroy any whose
    /// account (index) has no matching live entry — e.g. a DEK left behind by a crash
    /// after the DEK was created but before/without a committed manifest, or after the
    /// files were swept but the key survived. Returns the number of DEKs destroyed.
    @discardableResult
    func reconcileOrphanEntryDEKs(epoch: Int, liveIndices: Set<String>) throws -> Int {
        let dekService = naming.dekService(epoch: epoch)
        let items = try keychain.enumerate(servicePrefix: naming.servicePrefix)
        var destroyed = 0
        for item in items where item.service == dekService && !liveIndices.contains(item.account) {
            try destroyEntryDEK(epoch: epoch, index: item.account)
            destroyed += 1
        }
        return destroyed
    }

    // MARK: Randomness

    /// CSPRNG. A failure surfaces as `.unavailable` (→ tier dormancy) rather than a
    /// process-fatal `precondition` (LOW): the KV disk tier is an optimization and
    /// must never crash the serve loop because entropy was momentarily unavailable.
    static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, count, base) == errSecSuccess
        }
        guard ok else { throw KVKeychainError.unavailable(errSecNotAvailable) }
        return data
    }
}

// MARK: - Chunk crypto (AES-256-GCM under the entry DEK, §5a)

/// AES-256-GCM seal/open for one chunk under the entry DEK. Nonce is a fresh CSPRNG
/// 96-bit value (never counter-derived); AAD is the §5a non-circular manifest
/// projection plus the big-endian ordinal.
enum KVChunkCrypto {
    struct Sealed: Sendable, Equatable {
        let nonce: Data          // 12 bytes
        let ciphertext: Data
        let tag: Data            // 16 bytes
    }

    static func seal(plaintext: Data, dek: Data, aad: Data) throws -> Sealed {
        let nonceData = try KVKeyManager.randomBytes(KVDiskCacheFormat.chunkNonceBytes)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: dek),
                                   nonce: nonce, authenticating: aad)
        return Sealed(nonce: nonceData, ciphertext: box.ciphertext, tag: box.tag)
    }

    static func open(nonce: Data, ciphertext: Data, tag: Data, dek: Data, aad: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: dek), authenticating: aad)
    }
}

// MARK: - SecItem adapter (thin; only this touches the Keychain)

/// Data-Protection-Keychain adapter. All items are generic passwords with
/// `kSecUseDataProtectionKeychain = true`, the process default keychain
/// (no named access group unless `MACPROVIDER_KEYCHAIN_ACCESS_GROUP` is set),
/// `AfterFirstUnlockThisDeviceOnly`, non-synchronizable, and non-interactive
/// lookups. If a named group is requested without the entitlement, operations
/// surface `.unavailable` and the tier stays dormant.
struct KVSecItemKeychain: KVKeychain {
    let accessGroup: String?

    init(accessGroup: String? = nil) {
        self.accessGroup = MacProviderKeychainAccessGroup.resolve(accessGroup)
    }

    private func nonInteractiveBase(service: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    func add(service: String, account: String, secret: Data, incarnation: String) throws {
        var query = nonInteractiveBase(service: service)
        query[kSecAttrAccount as String] = account
        query[kSecValueData as String] = secret
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Incarnation identifier for ownership-checked cleanup (FR-KVP6).
        query[kSecAttrGeneric as String] = Data(incarnation.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem: throw KVKeychainError.duplicate
        default: throw Self.classify(status)
        }
    }

    func copySecret(service: String, account: String) throws -> Data? {
        var query = nonInteractiveBase(service: service)
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw Self.classify(status)
        }
    }

    func copyIncarnation(service: String, account: String) throws -> String? {
        var query = nonInteractiveBase(service: service)
        query[kSecAttrAccount as String] = account
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let attrs = result as? [String: Any],
                  let data = attrs[kSecAttrGeneric as String] as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound: return nil
        default: throw Self.classify(status)
        }
    }

    func delete(service: String, account: String) throws {
        var query = nonInteractiveBase(service: service)
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound: return
        default: throw Self.classify(status)
        }
    }

    func enumerate(servicePrefix: String) throws -> [KVKeychainItem] {
        // Data-Protection generic passwords cannot be prefix-queried by service, so
        // enumerate all items in the access group and filter in-process.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let rows = result as? [[String: Any]] else { return [] }
            return rows.compactMap { row in
                guard let service = row[kSecAttrService as String] as? String,
                      service.hasPrefix(servicePrefix),
                      let account = row[kSecAttrAccount as String] as? String else { return nil }
                let incarnation = (row[kSecAttrGeneric as String] as? Data)
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return KVKeychainItem(service: service, account: account, incarnation: incarnation)
            }
        case errSecItemNotFound:
            return []
        default:
            throw Self.classify(status)
        }
    }

    /// Map an OSStatus to unavailable (dormancy) vs hard failure. Locked/no-login/
    /// interaction-required/missing-entitlement are transient-or-structural
    /// availability conditions the tier tolerates by going dormant (FR-KVP6).
    private static func classify(_ status: OSStatus) -> KVKeychainError {
        switch status {
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecDatabaseLocked,
             errSecNotAvailable, errSecNotLoggedIn, errSecMissingEntitlement,
             errSecNoAccessForItem, errSecAuthFailed, errSecUserCanceled:
            return .unavailable(status)
        default:
            return .failed(status)
        }
    }
}

// MARK: - In-memory Keychain double (tests only)

/// Thread-safe in-memory `KVKeychain` for tests: exercises every logic path without
/// a Data-Protection entitlement. `forceUnavailable` simulates pre-unlock dormancy.
final class KVInMemoryKeychain: KVKeychain, @unchecked Sendable {
    private struct Stored { var secret: Data; var incarnation: String }
    private let lock = NSLock()
    private var items: [String: Stored] = [:]   // key = service\u{0}account
    private var _forceUnavailable = false

    var forceUnavailable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _forceUnavailable }
        set { lock.lock(); _forceUnavailable = newValue; lock.unlock() }
    }

    private static func key(_ service: String, _ account: String) -> String {
        "\(service)\u{0}\(account)"
    }

    func add(service: String, account: String, secret: Data, incarnation: String) throws {
        lock.lock(); defer { lock.unlock() }
        if _forceUnavailable { throw KVKeychainError.unavailable(errSecInteractionNotAllowed) }
        let k = Self.key(service, account)
        if items[k] != nil { throw KVKeychainError.duplicate }
        items[k] = Stored(secret: secret, incarnation: incarnation)
    }

    func copySecret(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if _forceUnavailable { throw KVKeychainError.unavailable(errSecInteractionNotAllowed) }
        return items[Self.key(service, account)]?.secret
    }

    func copyIncarnation(service: String, account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if _forceUnavailable { throw KVKeychainError.unavailable(errSecInteractionNotAllowed) }
        return items[Self.key(service, account)]?.incarnation
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if _forceUnavailable { throw KVKeychainError.unavailable(errSecInteractionNotAllowed) }
        items.removeValue(forKey: Self.key(service, account))
    }

    func enumerate(servicePrefix: String) throws -> [KVKeychainItem] {
        lock.lock(); defer { lock.unlock() }
        if _forceUnavailable { throw KVKeychainError.unavailable(errSecInteractionNotAllowed) }
        return items.compactMap { entry in
            let parts = entry.key.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let service = String(parts[0])
            guard service.hasPrefix(servicePrefix) else { return nil }
            return KVKeychainItem(service: service, account: String(parts[1]), incarnation: entry.value.incarnation)
        }
    }
}
