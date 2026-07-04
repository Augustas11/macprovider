import Foundation
import CryptoKit
import Security

// SPEC-026 v0.11 §7.1: ProviderIdentity — Ed25519 keypair in the App-track
// Keychain slot `provider_identity_v1`.
//
// Distinct from the SPEC-015 receipt key (which lives in
// `receipt_key_v1` in the CLI-track's own Keychain slot). This module is
// App-track-only; the key never leaves the Keychain and never enters any
// child process's environment.
//
// See specs/SPEC-026-browserless-provider-onboarding.md v0.11 §3.1-§3.3
// for the identity model + provider_id derivation.
//
// See specs/BUILD_SPEC_026_IMPL_STEP_2_APP_BUNDLE_PROMPT.md for the full
// impl contract that codex fills in via the audit loop.

enum ProviderIdentityError: Error, LocalizedError {
    case keychainUnavailable(status: OSStatus)
    case invalidKeyMaterial
    case missingIdentity

    var errorDescription: String? {
        switch self {
        case let .keychainUnavailable(status):
            return "Provider identity Keychain operation failed with status \(status)."
        case .invalidKeyMaterial:
            return "Provider identity key material was invalid."
        case .missingIdentity:
            return "Provider identity key material was not found."
        }
    }
}

enum ProviderIdentity {
    /// Keychain service = bundle identifier (SPEC-026 §3.1).
    static let keychainService = Bundle.main.bundleIdentifier ?? "tech.malibu.app"

    /// Keychain account slot per SPEC-026 §3.1.
    /// DISTINCT from SPEC-015's `receipt_key_v1` slot (which stays owned
    /// by the CLI-track's KeychainReceiptKeyStore).
    static let keychainAccount = "provider_identity_v1"

    /// Base32 alphabet: RFC 4648 §6 lowercased, no padding.
    /// MUST match the Go coordinator side (SPEC-026 §3.3, provider_id
    /// parity fixture at
    /// `phase4-coordinator/test/jcs_fixtures/spec026_register.json`).
    static let base32Alphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz234567")

    /// Returns true iff a `provider_identity_v1` row exists in the App
    /// target's Keychain (SecItem generic-password class). Used by
    /// LaunchProviderController + §8.1 migration matrix state
    /// classification. Does NOT load the private key material.
    static func isReady() async -> Bool {
        await ProviderIdentityKeychain.shared.isReady()
    }

    /// Loads the existing identity key if present, otherwise generates
    /// a fresh Curve25519.Signing.PrivateKey, stores it in the Keychain
    /// with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and returns
    /// the key. Idempotent — safe to call from LaunchProviderController
    /// on every launch, but concurrent calls MUST serialize.
    static func loadOrGenerate() async throws -> Curve25519.Signing.PrivateKey {
        try await ProviderIdentityKeychain.shared.loadOrGenerate()
    }

    /// Loads an existing identity key without generating a replacement.
    /// Proof-stage signing must use this so a corrupted/imported config cannot
    /// silently bind a new identity to an old provider_id.
    static func loadExisting() async throws -> Curve25519.Signing.PrivateKey {
        try await ProviderIdentityKeychain.shared.loadExisting()
    }

    /// Derives `provider_id = "p_" + base32_lc(sha256(pubkey.rawRepresentation))`
    /// per SPEC-026 §3.3.
    ///
    /// Returned string is 54 chars total ("p_" + 52 chars). UI compact
    /// display is `"p_" + first 8 payload chars` per §3.3.
    static func providerID(for key: Curve25519.Signing.PrivateKey) -> String {
        let pubkeyBytes = key.publicKey.rawRepresentation
        let digest = SHA256.hash(data: pubkeyBytes)
        return "p_" + base32LowercaseNoPad(Data(digest))
    }

    /// Signs `payload` with the identity key. Returns the 64-byte
    /// Ed25519 signature.
    static func sign(_ payload: Data, using key: Curve25519.Signing.PrivateKey) throws -> Data {
        try key.signature(for: payload)
    }

    /// Deletes the identity Keychain slot. Called by the uninstall path
    /// (SPEC-026 §6.5) BEFORE the ProviderConfig.wipeAppOwnedState()
    /// call. Idempotent — errSecItemNotFound is treated as success.
    static func deleteFromKeychain() async throws {
        try await ProviderIdentityKeychain.shared.delete()
    }

    // MARK: - Internals

    /// RFC 4648 §6 base32 with lowercased alphabet + no padding. MUST
    /// produce byte-for-byte identical output to Go coordinator's
    /// `base32.NewEncoding(Base32AlphabetLowercase).WithPadding(base32.NoPadding)`
    /// (see phase4-coordinator/internal/onboarding/apptrack.go).
    /// Parity fixture: `phase4-coordinator/test/jcs_fixtures/spec026_register.json`.
    static func base32LowercaseNoPad(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        var output = ""
        output.reserveCapacity((data.count * 8 + 4) / 5)

        var buffer = 0
        var bitsLeft = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1f
                output.append(base32Alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1f
            output.append(base32Alphabet[index])
        }

        return output
    }
}

private actor ProviderIdentityKeychain {
    static let shared = ProviderIdentityKeychain()

    func isReady() -> Bool {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.presenceQuery() as CFDictionary, &result)
        return status == errSecSuccess
    }

    func loadOrGenerate() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try readExisting() {
            return existing
        }

        let key = Curve25519.Signing.PrivateKey()
        let status = SecItemAdd(Self.insertQuery(key.rawRepresentation) as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try readExisting() {
            return existing
        }
        guard status == errSecSuccess else {
            throw ProviderIdentityError.keychainUnavailable(status: status)
        }
        return key
    }

    func loadExisting() throws -> Curve25519.Signing.PrivateKey {
        guard let existing = try readExisting() else {
            throw ProviderIdentityError.missingIdentity
        }
        return existing
    }

    func delete() throws {
        let status = SecItemDelete(Self.baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderIdentityError.keychainUnavailable(status: status)
        }
    }

    private func readExisting() throws -> Curve25519.Signing.PrivateKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.readQuery() as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ProviderIdentityError.keychainUnavailable(status: status)
        }
        guard let data = result as? Data, data.count == 32 else {
            throw ProviderIdentityError.invalidKeyMaterial
        }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        } catch {
            throw ProviderIdentityError.invalidKeyMaterial
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ProviderIdentity.keychainService,
            kSecAttrAccount as String: ProviderIdentity.keychainAccount
        ]
    }

    private static func presenceQuery() -> [String: Any] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        return query
    }

    private static func readQuery() -> [String: Any] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        return query
    }

    private static func insertQuery(_ keyBytes: Data) -> [String: Any] {
        var query = baseQuery()
        query[kSecValueData as String] = keyBytes
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return query
    }
}
