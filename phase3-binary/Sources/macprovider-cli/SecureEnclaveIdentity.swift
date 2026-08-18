/// SecureEnclaveIdentity — persistent SE P-256 signing key. arm64-only;
/// callers must guard with `#if arch(arm64)` or check
/// `SecureEnclaveIdentity.isAvailable` at runtime.
///
/// Access-group note: production Developer ID `macprovider-cli` omits
/// `kSecAttrAccessGroup` and ships with no keychain entitlements. A named
/// group requires the restricted `keychain-access-groups` entitlement, and
/// AMFI SIGKILLs a naked Developer ID CLI that carries that entitlement
/// without an embedded provisioning profile (v1.8.96). Override with env
/// var `MACPROVIDER_KEYCHAIN_ACCESS_GROUP` or the `accessGroup:` parameter
/// only when the binary is profiled. A named group without the entitlement
/// returns errSecMissingEntitlement (-34018) as
/// `SecureEnclaveIdentityError.missingEntitlement`.
///
/// Data-protection keychain SE items also return -34018 for this naked CLI
/// even with no named group (no `application-identifier`). When no named
/// group is requested, load-or-create falls back to a CryptoKit SE key whose
/// wrapped `dataRepresentation` lives in an owner-only file. That blob is
/// not raw private key material; the Secure Enclave still owns the key.

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
    case fileStoreAlreadyExists
    case fileStoreFailed(String)

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
            return "Binary is missing the keychain-access-groups entitlement for the requested access group"
        case .fileStoreAlreadyExists:
            return "SE file-backed identity store already exists"
        case .fileStoreFailed(let message):
            return "SE file-backed identity store failed: \(message)"
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
    /// Superposition Technologies Developer ID Team ID (`YF7XNRJUG4`).
    static let productionTeamID = "YF7XNRJUG4"
    /// Named group for a future profiled app bundle. Not the Developer ID CLI default.
    static let namedProduction = "YF7XNRJUG4.live.malibu.provider"

    static func resolve(_ override: String?) -> String? {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let env = ProcessInfo.processInfo.environment["MACPROVIDER_KEYCHAIN_ACCESS_GROUP"] {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}

enum SEAttestationFileStore {
    /// Test-only override. Production uses `defaultURL`.
    nonisolated(unsafe) static var urlOverride: URL?

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/macprovider/se-attestation-p256.v1",
                isDirectory: false
            )
    }

    static var resolvedURL: URL {
        urlOverride ?? defaultURL
    }

    static func read(_ url: URL) throws -> Data {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw SecureEnclaveIdentityError.fileStoreFailed("missing \(url.path)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_mode & 0o077) == 0
        else {
            throw SecureEnclaveIdentityError.fileStoreFailed(
                "\(url.path) is not an owner-only regular file"
            )
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SecureEnclaveIdentityError.fileStoreFailed(
                "read \(url.path): \(error.localizedDescription)"
            )
        }
    }

    static func writeExclusive(_ url: URL, data: Data) throws {
        try ensurePrivateParentDirectory(for: url)
        let path = url.path
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        let openErrno = errno
        guard fd >= 0 else {
            if openErrno == EEXIST {
                throw SecureEnclaveIdentityError.fileStoreAlreadyExists
            }
            throw SecureEnclaveIdentityError.fileStoreFailed(
                "open \(path): errno=\(openErrno)"
            )
        }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        var written = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            written = write(fd, base, raw.count)
        }
        guard written == data.count else {
            unlink(path)
            throw SecureEnclaveIdentityError.fileStoreFailed("write \(path): short write")
        }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              (st.st_mode & 0o777) == 0o600,
              st.st_uid == getuid()
        else {
            unlink(path)
            throw SecureEnclaveIdentityError.fileStoreFailed(
                "post-write permission check failed for \(path)"
            )
        }
    }

    static func ensurePrivateParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SecureEnclaveIdentityError.fileStoreFailed(
                "mkdir \(parent.path): \(error.localizedDescription)"
            )
        }
        var st = stat()
        // stat(2) follows symlinks so /var → /private/var is a directory.
        guard stat(parent.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid()
        else {
            throw SecureEnclaveIdentityError.fileStoreFailed(
                "parent \(parent.path) is not an owner directory"
            )
        }
        if (st.st_mode & 0o077) != 0 {
            guard chmod(parent.path, 0o700) == 0 else {
                throw SecureEnclaveIdentityError.fileStoreFailed(
                    "chmod \(parent.path): errno=\(errno)"
                )
            }
        }
    }
}

// MARK: - SecureEnclaveIdentity

#if arch(arm64)

final class SecureEnclaveIdentity: @unchecked Sendable {
    private enum KeyBackend {
        case secKey(SecKey)
        case cryptoKit(SecureEnclave.P256.Signing.PrivateKey)
    }

    private let backend: KeyBackend
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

    var backendName: String {
        switch backend {
        case .secKey:
            return "keychain"
        case .cryptoKit:
            return "file"
        }
    }

    // MARK: - Private init

    private init(backend: KeyBackend, publicKeyRaw: Data) {
        self.backend = backend
        self._publicKeyRaw = publicKeyRaw
    }

    private static func rawPublicKey(from secKey: SecKey) throws -> Data {
        guard let pubKey = SecKeyCopyPublicKey(secKey) else {
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
        return Data(pubData.dropFirst())
    }

    private static func rawPublicKey(
        from cryptoKit: SecureEnclave.P256.Signing.PrivateKey
    ) throws -> Data {
        let x963 = cryptoKit.publicKey.x963Representation
        guard x963.count == 65, x963[0] == 0x04 else {
            throw SecureEnclaveIdentityError.publicKeyExtractionFailed
        }
        return Data(x963.dropFirst())
    }

    // MARK: - Load or Create

    /// Load an existing persistent SE key from the keychain, or create one if
    /// not found. Throws `missingEntitlement` when a named access group is
    /// requested and the binary lacks `keychain-access-groups` — callers
    /// should fall back to a non-SE attestation path rather than aborting.
    ///
    /// When no named group is requested and the data-protection keychain
    /// returns -34018, falls back to the file-backed CryptoKit SE store.
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
            do {
                let existing = try findExisting(accessGroup: group, label: keyLabel)
                print("INFO se_attestation identity_ready backend=\(existing.backendName)")
                return existing
            } catch SecureEnclaveIdentityError.keyLookupFailed(status: errSecItemNotFound) {
                let created = try createNew(accessGroup: group, label: keyLabel)
                print("INFO se_attestation identity_ready backend=\(created.backendName)")
                return created
            }
        } catch SecureEnclaveIdentityError.missingEntitlement where group == nil {
            let fileBacked = try loadOrCreateFileBacked()
            print("INFO se_attestation identity_ready backend=\(fileBacked.backendName)")
            return fileBacked
        }
    }

    internal static func loadOrCreateFileBacked() throws -> SecureEnclaveIdentity {
        guard isAvailable else {
            throw SecureEnclaveIdentityError.secureEnclaveUnavailable
        }
        let url = SEAttestationFileStore.resolvedURL
        if FileManager.default.fileExists(atPath: url.path) {
            return try loadFileBacked(url: url)
        }
        let privateKey: SecureEnclave.P256.Signing.PrivateKey
        do {
            privateKey = try SecureEnclave.P256.Signing.PrivateKey()
        } catch {
            throw SecureEnclaveIdentityError.keyCreationFailed(status: errSecInternalError)
        }
        do {
            try SEAttestationFileStore.writeExclusive(url, data: privateKey.dataRepresentation)
        } catch SecureEnclaveIdentityError.fileStoreAlreadyExists {
            return try loadFileBacked(url: url)
        }
        return try SecureEnclaveIdentity(
            backend: .cryptoKit(privateKey),
            publicKeyRaw: rawPublicKey(from: privateKey)
        )
    }

    private static func loadFileBacked(url: URL) throws -> SecureEnclaveIdentity {
        let data = try SEAttestationFileStore.read(url)
        let privateKey: SecureEnclave.P256.Signing.PrivateKey
        do {
            privateKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        } catch {
            throw SecureEnclaveIdentityError.fileStoreFailed(
                "restore SE handle: \(error.localizedDescription)"
            )
        }
        return try SecureEnclaveIdentity(
            backend: .cryptoKit(privateKey),
            publicKeyRaw: rawPublicKey(from: privateKey)
        )
    }

    // MARK: - Sign

    /// Sign `data` using the SE private key.
    /// Returns a DER-encoded ECDSA signature (ASN.1 SEQUENCE of two INTEGERs),
    /// compatible with Go's crypto/ecdsa and the coordinator verifier.
    func sign(_ data: Data) throws -> Data {
        switch backend {
        case .secKey(let privateKey):
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
        case .cryptoKit(let privateKey):
            do {
                return try privateKey.signature(for: data).derRepresentation
            } catch {
                throw SecureEnclaveIdentityError.signingFailed(
                    status: errSecInternalError,
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Delete

    static func delete(
        accessGroup: String? = nil,
        label: String? = nil
    ) throws {
        let group = resolveAccessGroup(accessGroup)
        let keyLabel = label ?? defaultLabel
        let query = applyingAccessGroup([
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: keyLabel,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
        ], group)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            break
        case -34018 where group == nil:
            break
        case -34018:
            throw SecureEnclaveIdentityError.missingEntitlement
        default:
            throw SecureEnclaveIdentityError.deletionFailed(status: status)
        }
        if group == nil {
            try? FileManager.default.removeItem(at: SEAttestationFileStore.resolvedURL)
        }
    }

    // MARK: - Access Group Resolution

    static func resolveAccessGroup(_ override: String?) -> String? {
        MacProviderKeychainAccessGroup.resolve(override)
    }

    private static func applyingAccessGroup(
        _ query: [String: Any],
        _ accessGroup: String?
    ) -> [String: Any] {
        guard let accessGroup else { return query }
        var query = query
        query[kSecAttrAccessGroup as String] = accessGroup
        return query
    }

    // MARK: - Private Helpers

    private static func findExisting(
        accessGroup: String?,
        label: String
    ) throws -> SecureEnclaveIdentity {
        let query = applyingAccessGroup([
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: label,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
        ], accessGroup)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let result else {
                throw SecureEnclaveIdentityError.keyLookupFailed(status: status)
            }
            let key = result as! SecKey
            return try SecureEnclaveIdentity(
                backend: .secKey(key),
                publicKeyRaw: rawPublicKey(from: key)
            )
        case errSecItemNotFound:
            throw SecureEnclaveIdentityError.keyLookupFailed(status: errSecItemNotFound)
        case -34018:
            throw SecureEnclaveIdentityError.missingEntitlement
        default:
            throw SecureEnclaveIdentityError.keyLookupFailed(status: status)
        }
    }

    private static func createNew(
        accessGroup: String?,
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

        let privateKeyAttrs = applyingAccessGroup([
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessControl as String: accessControl,
            kSecAttrLabel as String: label,
        ], accessGroup)
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
        return try SecureEnclaveIdentity(
            backend: .secKey(privateKey),
            publicKeyRaw: rawPublicKey(from: privateKey)
        )
    }
}

#endif
