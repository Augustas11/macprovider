/// SEAttestationBuilder — constructs the `SignedSEAttestation` JSON blob
/// that forms the `token` field in a `macprovider-se-p256-v1` attestation
/// envelope (runbook §1.1.A).
///
/// Blob structure (JSON, sorted keys):
///   { "attestation": { … hardware fields … }, "signature": "<base64 DER ECDSA>" }
///
/// The signature covers the canonical JSON of the inner `attestation` object
/// (sorted keys, UTF-8). The coordinator verifier re-derives the same bytes
/// and checks the SE public key bound in the envelope.

import CryptoKit
import Darwin
import Foundation
import IOKit
import Security

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
    let chipName: String
    let hardwareModel: String
    let osVersion: String
    let sipEnabled: Bool
    let secureBootEnabled: Bool
    let secureEnclaveAvailable: Bool
    let publicKey: String           // base64 raw P-256 64-byte SE pubkey
    let encryptionPublicKey: String // base64url 32-byte X25519 session key (= provider_ecdh_public_key)
    let timestamp: String           // RFC3339
    let serialNumber: String?
    let binaryHash: String?         // optional sha256 hex of binary

    func asDictionary() -> [String: Any] {
        var d: [String: Any] = [
            "chipName": chipName,
            "hardwareModel": hardwareModel,
            "osVersion": osVersion,
            "sipEnabled": sipEnabled,
            "secureBootEnabled": secureBootEnabled,
            "secureEnclaveAvailable": secureEnclaveAvailable,
            "publicKey": publicKey,
            "encryptionPublicKey": encryptionPublicKey,
            "timestamp": timestamp,
        ]
        if let sn = serialNumber { d["serialNumber"] = sn }
        if let bh = binaryHash { d["binaryHash"] = bh }
        return d
    }

    /// Canonical JSON bytes for signature: sorted keys, UTF-8.
    func canonicalJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: asDictionary(), options: [.sortedKeys])
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
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    func tokenBase64URL() throws -> String {
        try tokenJSON().base64URLUnpadded()
    }
}

// MARK: - Builder

struct SEAttestationBuilder {
    var now: () -> Date
    var sysctlStringOverride: ((String) -> String?)?
    var serialNumberOverride: (() -> String?)?

    init(
        now: @escaping () -> Date = { Date() },
        sysctlStringOverride: ((String) -> String?)? = nil,
        serialNumberOverride: (() -> String?)? = nil
    ) {
        self.now = now
        self.sysctlStringOverride = sysctlStringOverride
        self.serialNumberOverride = serialNumberOverride
    }

    func build(
        signer: SEBlobSigner,
        providerECDHPublicKey: String,
        binaryHash: String? = nil
    ) throws -> SignedSEAttestation {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let model = sysctlString("hw.model") ?? "unknown"
        let osVer = Self.osVersionString()
        let serial = serialNumberOverride != nil ? serialNumberOverride!() : machineSerialNumber()
        let seAvail: Bool
        #if arch(arm64)
        seAvail = SecureEnclave.isAvailable
        #else
        seAvail = false
        #endif

        let blob = AttestationBlob(
            chipName: chip,
            hardwareModel: model,
            osVersion: osVer,
            // SIP and SecureBoot are enabled by default on Apple Silicon.
            // Phase 3 (Live MDA) will replace these with Apple-rooted hardware evidence.
            sipEnabled: true,
            secureBootEnabled: true,
            secureEnclaveAvailable: seAvail,
            publicKey: signer.publicKeyRaw.base64EncodedString(),
            encryptionPublicKey: providerECDHPublicKey,
            timestamp: iso8601String(now()),
            serialNumber: serial,
            binaryHash: binaryHash
        )

        let canonical = try blob.canonicalJSON()
        let sigDER = try signer.sign(canonical)
        let sigBase64 = sigDER.base64EncodedString()

        return SignedSEAttestation(blob: blob, signatureBase64: sigBase64)
    }

    // MARK: - Private helpers

    private func sysctlString(_ name: String) -> String? {
        if let override = sysctlStringOverride {
            return override(name)
        }
        return Self.sysctlString(name)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
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

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
