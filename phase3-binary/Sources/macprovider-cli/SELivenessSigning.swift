import Foundation

/// SELivenessSigning is the signing interface for SE liveness challenge responses
/// (Phase 1, Track P1-C). The coordinator sends ``se_liveness_challenge`` after
/// a provider has completed macprovider-se-p256-v1 auth; the provider MUST sign
/// UTF-8(nonce+timestamp) with its SE private key and echo both fields back.
///
/// `SecureEnclaveIdentity` conforms on arm64 when the SE is available.
/// Tests use ``SELivenessTestSigning`` to inject a deterministic signing double.
protocol SELivenessSigning: Sendable {
    /// Signs `data` (raw UTF-8 bytes of the message) using ECDSA with SHA-256.
    /// Returns a DER-encoded ECDSA signature (ASN.1 SEQUENCE { R INTEGER, S INTEGER }).
    func sign(_ data: Data) throws -> Data

    /// Base64-encoded raw P-256 public key (64 bytes: X||Y, no 0x04 prefix).
    var publicKeyBase64: String { get }
}

#if arch(arm64)
/// Conformance for the production Secure Enclave identity.
/// SecureEnclaveIdentity.sign(_:) uses ecdsaSignatureMessageX962SHA256 which
/// internally applies SHA-256, matching Go's ecdsa.Verify over sha256.Sum256(msg).
extension SecureEnclaveIdentity: SELivenessSigning {}
#endif

/// SELivenessTestSigning is a deterministic in-process signer for tests.
/// It uses a standard CryptoKit / Security framework P-256 key (not the SE)
/// so it works on any architecture, including CI and x86 simulators.
final class SELivenessTestSigning: SELivenessSigning, @unchecked Sendable {
    private let privateKey: SecKey
    private let _publicKeyBase64: String

    /// Create a signing double from an existing SecKey P-256 private key.
    init(privateKey: SecKey, publicKeyBase64: String) {
        self.privateKey = privateKey
        self._publicKeyBase64 = publicKeyBase64
    }

    /// Convenience: generate a fresh ephemeral P-256 key for tests.
    static func generate() throws -> SELivenessTestSigning {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let msg = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            throw NSError(domain: "SELivenessTestSigning", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "key generation failed: \(msg)"])
        }
        guard let pubKey = SecKeyCopyPublicKey(privKey) else {
            throw NSError(domain: "SELivenessTestSigning", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot extract public key"])
        }
        var copyError: Unmanaged<CFError>?
        guard let pubData = SecKeyCopyExternalRepresentation(pubKey, &copyError) as Data? else {
            throw NSError(domain: "SELivenessTestSigning", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "cannot serialize public key"])
        }
        // Uncompressed P-256 key is 65 bytes with a 0x04 prefix; drop it → 64 bytes.
        let raw = pubData.dropFirst()
        return SELivenessTestSigning(privateKey: privKey,
                                    publicKeyBase64: raw.base64EncodedString())
    }

    func sign(_ data: Data) throws -> Data {
        var signError: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &signError
        ) as Data? else {
            let msg = signError.map { String(describing: $0.takeRetainedValue()) } ?? "unknown"
            throw NSError(domain: "SELivenessTestSigning", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "signing failed: \(msg)"])
        }
        return sig
    }

    var publicKeyBase64: String { _publicKeyBase64 }
}
