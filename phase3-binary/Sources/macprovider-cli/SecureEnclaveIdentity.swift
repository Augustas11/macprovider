/// SecureEnclaveIdentity — persistent SE P-256 signing key backed by the
/// macOS data-protection keychain. arm64-only; callers must guard with
/// `#if arch(arm64)` or check `SecureEnclaveIdentity.isAvailable` at runtime.
///
/// Access-group note: The production access group is
/// `<TEAM_ID>.live.malibu.provider`. Set it via env var
/// `MACPROVIDER_KEYCHAIN_ACCESS_GROUP` or use the `accessGroup:` parameter.
/// A binary missing the `keychain-access-groups` entitlement receives
/// errSecMissingEntitlement (-34018), which surfaces as
/// `SecureEnclaveIdentityError.missingEntitlement`.

import CryptoKit
import Darwin
import Foundation
import Security

// MARK: - Errors

enum SecureEnclaveIdentityError: Error, CustomStringConvertible {
    case secureEnclaveUnavailable
    case accessControlCreationFailed(status: OSStatus)
    case keyCreationFailed(status: OSStatus)
    case keyLookupFailed(status: OSStatus)
    case deletionFailed(status: OSStatus)
    case signingFailed(status: OSStatus, message: String)
    case publicKeyExtractionFailed
    case publicKeySerializationFailed(status: OSStatus)
    case missingEntitlement

    var description: String {
        switch self {
        case .secureEnclaveUnavailable:
            return "Secure Enclave is not available on this device"
        case .accessControlCreationFailed(let status):
            return "Failed to create SE access control: OSStatus \(status)"
        case .keyCreationFailed(let status):
            if status == -34018 {
                return "SE key creation failed: missing keychain-access-groups entitlement (OSStatus -34018)"
            }
            return "SE key creation failed: OSStatus \(status)"
        case .keyLookupFailed(let status):
            return "SE key lookup failed: OSStatus \(status)"
        case .deletionFailed(let status):
            return "SE key deletion failed: OSStatus \(status)"
        case .signingFailed(let status, let message):
            return "SE signing failed (OSStatus \(status)): \(message)"
        case .publicKeyExtractionFailed:
            return "Failed to extract SE public key"
        case .publicKeySerializationFailed(let status):
            return "Failed to serialize SE public key: OSStatus \(status)"
        case .missingEntitlement:
            return "Binary is missing the keychain-access-groups entitlement for the configured access group"
        }
    }
}

// MARK: - Helpers

private func osStatus(from cfError: Unmanaged<CFError>?) -> OSStatus {
    guard let cfError else { return errSecInternalError }
    let nsError = cfError.takeRetainedValue() as Error as NSError
    return OSStatus(nsError.code)
}

enum MacProviderKeychainAccessGroup {
    static func resolve(_ override: String?) -> String {
        if let override { return override }
        if let env = ProcessInfo.processInfo.environment["MACPROVIDER_KEYCHAIN_ACCESS_GROUP"],
           !env.isEmpty { return env }
        // Production value: replace TEAMID with the 10-char Apple Developer Team ID.
        // The keychain-access-groups entitlement must list this group.
        // During local dev/CI, set MACPROVIDER_KEYCHAIN_ACCESS_GROUP to a signed
        // test group or leave unset — loadOrCreate will throw missingEntitlement,
        // which the generator treats as graceful SE-unavailable.
        return "REPLACEME.live.malibu.provider"
    }
}

// MARK: - SecureEnclaveIdentity

#if arch(arm64)

final class SecureEnclaveIdentity: @unchecked Sendable {
    /// Handle to the SE-backed private key; the SE owns all private material.
    internal let privateKey: SecKey

    private let _publicKeyRaw: Data

    /// Current label. Keys here use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
    /// so background attestation-challenge signing works while the screen is locked.
    static let defaultLabel = "live.malibu.provider.attestation-signing.v1"

    /// Raw P-256 public key (64 bytes: X || Y, without the 0x04 prefix).
    var publicKeyRaw: Data { _publicKeyRaw }

    /// Standard base64-encoded public key (not URL-safe).
    var publicKeyBase64: String { _publicKeyRaw.base64EncodedString() }

    /// Whether the Secure Enclave is available. Returns false on Intel Macs
    /// without T2, macOS VMs without virtualized SE, and the Simulator.
    static var isAvailable: Bool { SecureEnclave.isAvailable }

    // MARK: - Private init

    private init(privateKey: SecKey) throws {
        self.privateKey = privateKey

        guard let pubKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveIdentityError.publicKeyExtractionFailed
        }
        var serError: Unmanaged<CFError>?
        guard let pubData = SecKeyCopyExternalRepresentation(pubKey, &serError) as Data? else {
            throw SecureEnclaveIdentityError.publicKeySerializationFailed(
                status: osStatus(from: serError)
            )
        }
        // X9.62 uncompressed: 0x04 || X (32 bytes) || Y (32 bytes)
        guard pubData.count == 65, pubData[0] == 0x04 else {
            throw SecureEnclaveIdentityError.publicKeyExtractionFailed
        }
        self._publicKeyRaw = Data(pubData.dropFirst())
    }

    // MARK: - Load or Create

    /// Load an existing persistent SE key from the keychain, or create one if
    /// not found. Throws `missingEntitlement` when the binary lacks the
    /// `keychain-access-groups` entitlement — callers should fall back to a
    /// non-SE attestation path rather than aborting.
    static func loadOrCreate(
        accessGroup: String? = nil,
        label: String? = nil
    ) throws -> SecureEnclaveIdentity {
        guard isAvailable else {
            throw SecureEnclaveIdentityError.secureEnclaveUnavailable
        }
        let group = resolveAccessGroup(accessGroup)
        let keyLabel = label ?? defaultLabel

        do {
            let existing = try findExisting(accessGroup: group, label: keyLabel)
            return existing
        } catch SecureEnclaveIdentityError.keyLookupFailed(status: errSecItemNotFound) {
            // Fall through to creation.
        }

        return try createNew(accessGroup: group, label: keyLabel)
    }

    // MARK: - Sign

    /// Sign `data` using the SE private key.
    /// Returns a DER-encoded ECDSA signature (ASN.1 SEQUENCE of two INTEGERs),
    /// compatible with Go's crypto/ecdsa and the coordinator verifier.
    func sign(_ data: Data) throws -> Data {
        var signError: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &signError
        ) as Data? else {
            if let cfErr = signError {
                let nsErr = cfErr.takeRetainedValue() as Error as NSError
                throw SecureEnclaveIdentityError.signingFailed(
                    status: OSStatus(nsErr.code),
                    message: nsErr.localizedDescription
                )
            }
            throw SecureEnclaveIdentityError.signingFailed(
                status: errSecInternalError,
                message: "unknown error"
            )
        }
        return sig as Data
    }

    // MARK: - Delete

    static func delete(
        accessGroup: String? = nil,
        label: String? = nil
    ) throws {
        let group = resolveAccessGroup(accessGroup)
        let keyLabel = label ?? defaultLabel
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: keyLabel,
            kSecAttrAccessGroup as String: group,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case -34018:
            throw SecureEnclaveIdentityError.missingEntitlement
        default:
            throw SecureEnclaveIdentityError.deletionFailed(status: status)
        }
    }

    // MARK: - Access Group Resolution

    static func resolveAccessGroup(_ override: String?) -> String {
        MacProviderKeychainAccessGroup.resolve(override)
    }

    // MARK: - Private Helpers

    private static func findExisting(
        accessGroup: String,
        label: String
    ) throws -> SecureEnclaveIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: label,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let result else {
                throw SecureEnclaveIdentityError.keyLookupFailed(status: status)
            }
            let key = result as! SecKey
            return try SecureEnclaveIdentity(privateKey: key)
        case errSecItemNotFound:
            throw SecureEnclaveIdentityError.keyLookupFailed(status: errSecItemNotFound)
        case -34018:
            throw SecureEnclaveIdentityError.missingEntitlement
        default:
            throw SecureEnclaveIdentityError.keyLookupFailed(status: status)
        }
    }

    private static func createNew(
        accessGroup: String,
        label: String
    ) throws -> SecureEnclaveIdentity {
        var acError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            &acError
        ) else {
            throw SecureEnclaveIdentityError.accessControlCreationFailed(
                status: osStatus(from: acError)
            )
        }

        let privateKeyAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessControl as String: accessControl,
            kSecAttrLabel as String: label,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: privateKeyAttrs,
        ]

        var createError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            let status = osStatus(from: createError)
            if status == -34018 {
                throw SecureEnclaveIdentityError.missingEntitlement
            }
            if status == errSecDuplicateItem {
                return try findExisting(accessGroup: accessGroup, label: label)
            }
            throw SecureEnclaveIdentityError.keyCreationFailed(status: status)
        }
        return try SecureEnclaveIdentity(privateKey: privateKey)
    }
}

#endif
