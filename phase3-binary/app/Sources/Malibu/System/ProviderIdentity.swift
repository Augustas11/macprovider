import Foundation
import CryptoKit

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

enum ProviderIdentityError: Error {
    case keychainUnavailable(status: OSStatus)
    case invalidKeyMaterial
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
        // IMPLEMENTER: SecItemCopyMatching with kSecMatchLimitOne and
        // kSecReturnAttributes to check for presence without exporting the
        // key. Return false on errSecItemNotFound; throw on other errors.
        false
    }

    /// Loads the existing identity key if present, otherwise generates
    /// a fresh Curve25519.Signing.PrivateKey, stores it in the Keychain
    /// with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and returns
    /// the key. Idempotent — safe to call from LaunchProviderController
    /// on every launch, but concurrent calls MUST serialize.
    static func loadOrGenerate() async throws -> Curve25519.Signing.PrivateKey {
        // IMPLEMENTER: See SPEC-026 §3.1 for the Keychain attribute set
        // (kSecClassGenericPassword + kSecAttrService + kSecAttrAccount
        // + kSecAttrAccessible). Use privkey.rawRepresentation (32 bytes)
        // as the stored blob. Serialize concurrent loadOrGenerate() calls
        // via an actor or NSLock to prevent double-generate races on
        // first launch.
        throw ProviderIdentityError.keychainUnavailable(status: errSecNotAvailable)
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
        // IMPLEMENTER: SecItemDelete with the same attribute set as
        // loadOrGenerate. Idempotent: swallow errSecItemNotFound.
    }

    // MARK: - Internals

    /// RFC 4648 §6 base32 with lowercased alphabet + no padding. MUST
    /// produce byte-for-byte identical output to Go coordinator's
    /// `base32.NewEncoding(Base32AlphabetLowercase).WithPadding(base32.NoPadding)`
    /// (see phase4-coordinator/internal/onboarding/apptrack.go).
    /// Parity fixture: `phase4-coordinator/test/jcs_fixtures/spec026_register.json`.
    static func base32LowercaseNoPad(_ data: Data) -> String {
        // IMPLEMENTER: Foundation doesn't ship a stdlib base32; add a
        // tested no-pad lowercase RFC 4648 §6 encoder. Bit-level
        // implementation walks 5-bit groups off the input byte stream.
        // See tests: parity fixture verifies against Go output for
        // inputs 0/1/2/.../31 bytes.
        ""
    }
}
