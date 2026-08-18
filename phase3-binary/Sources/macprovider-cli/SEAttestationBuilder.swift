/// SEAttestationBuilder — constructs the compact `SignedSEAttestation` JSON
/// blob that forms the `token` field in a `macprovider-se-p256-v1`
/// attestation envelope (SPEC-008 §7.4a).
///
/// The whole outer `attestation_token` object must fit in 1024 bytes
/// (`maxHandshakeMetadataBytes`). The inner blob therefore carries only
/// the fields the coordinator verifier reads: SE public key, session ECDH
/// public key, and optional serial (live MDA lookup). Extra hardware
/// self-claims belong on hello/heartbeat, not in this envelope.
///
/// Blob structure (JSON, sorted keys):
///   { "attestation": { publicKey, encryptionPublicKey, serialNumber? },
///     "signature": "<base64 DER ECDSA>" }
///
/// The signature covers the canonical JSON of the inner `attestation`
/// object (sorted keys, UTF-8). The coordinator verifier re-derives the
/// same bytes and checks the SE public key bound in the envelope.

import Foundation
import IOKit

// MARK: - SEBlobSigner

/// Injectable signer so tests can provide a mock without SE hardware.
protocol SEBlobSigner: Sendable {
    /// Sign `data`; returns DER-encoded ECDSA signature.
    func sign(_ data: Data) throws -> Data
    /// Raw P-256 public key (64 bytes: X||Y, no 0x04 prefix).
    var publicKeyRaw: Data { get }
}

#if arch(arm64)
extension SecureEnclaveIdentity: SEBlobSigner {}
#endif

// MARK: - AttestationBlob

struct AttestationBlob {
    let publicKey: String           // base64 raw P-256 64-byte SE pubkey
    let encryptionPublicKey: String // base64url 32-byte X25519 session key (= provider_ecdh_public_key)
    let serialNumber: String?

    func asDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "publicKey": publicKey,
            "encryptionPublicKey": encryptionPublicKey,
        ]
        if let sn = serialNumber { d["serialNumber"] = sn }
        return d
    }

    /// Canonical JSON bytes for signature: Go `encoding/json` Marshal of a
    /// map (sorted keys, `/` left literal). SPEC-008 §7.4a.
    func canonicalJSON() throws -> Data {
        try Spec008CanonicalJSON.marshal(asDictionary())
    }
}

// MARK: - SignedSEAttestation

struct SignedSEAttestation {
    let blob: AttestationBlob
    let signatureBase64: String // base64 (not URL-safe) DER ECDSA over canonical attestation JSON

    func tokenJSON() throws -> Data {
        let obj: [String: Any] = [
            "attestation": blob.asDictionary(),
            "signature": signatureBase64,
        ]
        return try Spec008CanonicalJSON.marshal(obj)
    }

    func tokenBase64URL() throws -> String {
        try tokenJSON().base64URLUnpadded()
    }
}

// MARK: - Builder

struct SEAttestationBuilder: Sendable {
    var serialNumberOverride: (@Sendable () -> String?)?

    init(serialNumberOverride: (@Sendable () -> String?)? = nil) {
        self.serialNumberOverride = serialNumberOverride
    }

    func build(
        signer: SEBlobSigner,
        providerECDHPublicKey: String
    ) throws -> SignedSEAttestation {
        let serial = serialNumberOverride != nil ? serialNumberOverride!() : machineSerialNumber()
        let blob = AttestationBlob(
            publicKey: signer.publicKeyRaw.base64EncodedString(),
            encryptionPublicKey: providerECDHPublicKey,
            serialNumber: serial
        )

        let canonical = try blob.canonicalJSON()
        let sigDER = try signer.sign(canonical)
        let sigBase64 = sigDER.base64EncodedString()

        return SignedSEAttestation(blob: blob, signatureBase64: sigBase64)
    }

    private func machineSerialNumber() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let key = "IOPlatformSerialNumber" as CFString
        guard let raw = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0) else {
            return nil
        }
        guard let serial = raw.takeRetainedValue() as? String else { return nil }
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Go `encoding/json` Marshal of a JSON object: sorted keys, `/` unescaped.
/// HTML-escaping of `<`, `>`, `&` is unused for current SE fields (base64,
/// serial, model ids). The coordinator verifies signatures over this form.
enum Spec008CanonicalJSON {
    static func marshal(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}
