import CryptoKit
import Foundation

enum PrivacyClassConstants {
    static let v1 = "operator_constrained_beta_v1"
    static let assurance = "device_bound_self_attested_beta"
    static let responseEncryption = "buyer_provider_aead_v1"
    static let reservationVersion = "privacy-class-reservation-v1"
    static let responseVersion = "privacy-response-v1"
    static let finalVersion = "privacy-response-final-v1"
    static let postureVersion = "privacy-posture-v1"
    static let postureDomain = "macprovider/spec049/posture/v1"
    static let keyAttestationVersion = "privacy-key-attestation-v1"
    static let keyAttestationDomain = "macprovider/spec049/key-attestation/v1"
    static let responseKeyLabel = "macprovider/spec049/response/aead/v1"
    static let responseNoncePrefixLabel = "macprovider/spec049/response/nonce-prefix/v1"
    static let frameObject = "macprovider.privacy_frame"
    static let responseObject = "macprovider.privacy_response"
    static let runtimeSource = "native_mlx"
    static let seBackendFile = "file"
    static let seBackendKeychain = "keychain"
    static let finalStatusComplete = "complete"
    static let finalStatusError = "error"
    static let finalStatusCancelled = "cancelled"
    static let downgradeRejected = "privacy_class_downgrade_rejected"
    static let postureStale = "privacy_class_posture_stale"
    /// SPEC-049-R008. `expires_at_unix - not_before_unix` must stay within this.
    static let maxKeyLifetimeSeconds: Int64 = 3600
    static let maxKeyRecordDigests = 8
    static let maxIdentifierBytes = 128
}

enum PrivacyClassError: Error, Equatable, CustomStringConvertible {
    case invalidMaterial

    var description: String { "privacy_class_invalid_material" }
}

/// SPEC-041 transcript domain. Response HKDF uses it as the salt, with SPEC-049 labels.
private let privacyTranscriptDomain = "macprovider/spec041/relay-blind/transcript/v1"

struct PrivacyResponseSealer: Sendable {
    private let key: SymmetricKey
    private let noncePrefix: Data
    private let envelopeDigest: String
    private let kid: String
    private let requestID: String
    private let stream: Bool
    private(set) var nextSeq: UInt64

    init(sharedSecret: SharedSecret, aad: Data, envelopeDigest: String, kid: String, requestID: String, stream: Bool) throws {
        let derived = try Self.derive(sharedSecret: sharedSecret, aad: aad)
        try Self.validateContext(envelopeDigest: envelopeDigest, kid: kid, requestID: requestID)
        self.key = derived.key
        self.noncePrefix = derived.noncePrefix
        self.envelopeDigest = envelopeDigest
        self.kid = kid
        self.requestID = requestID
        self.stream = stream
        self.nextSeq = 0
    }

    static func derive(sharedSecret: SharedSecret, aad: Data) throws -> (key: SymmetricKey, noncePrefix: Data) {
        var shared = sharedSecret.withUnsafeBytes { Data($0) }
        defer { shared.resetBytes(in: 0..<shared.count) }
        guard shared.count == 32 else { throw PrivacyClassError.invalidMaterial }
        var accumulator: UInt8 = 0
        for byte in shared { accumulator |= byte }
        guard accumulator != 0 else { throw PrivacyClassError.invalidMaterial }
        let transcript = Data(SHA256.hash(data: Data(privacyTranscriptDomain.utf8) + aad))
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data(PrivacyClassConstants.responseKeyLabel.utf8),
            outputByteCount: 32
        )
        let prefixKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data(PrivacyClassConstants.responseNoncePrefixLabel.utf8),
            outputByteCount: 4
        )
        let noncePrefix = prefixKey.withUnsafeBytes { Data($0) }
        guard noncePrefix.count == 4 else { throw PrivacyClassError.invalidMaterial }
        return (key, noncePrefix)
    }

    /// `aad` is the envelope AAD. `envelopeDigest` and `kid` are canonical base64url text.
    static func frameAAD(envelopeDigest: String, kid: String, requestID: String, stream: Bool, seq: UInt64, final: Bool) -> Data {
        var framed = Data()
        framed.appendFramed(Data(PrivacyClassConstants.responseVersion.utf8))
        framed.appendFramed(Data(envelopeDigest.utf8))
        framed.appendFramed(Data(kid.utf8))
        framed.appendFramed(Data(requestID.utf8))
        framed.appendUnsigned64(stream ? 1 : 0)
        framed.appendUnsigned64(seq)
        framed.appendUnsigned64(final ? 1 : 0)
        return framed
    }

    /// Seals one frame and zeroes `plaintext` before returning, including on failure.
    /// `resetBytes` zeroes the buffer when this `Data` is uniquely referenced.
    mutating func seal(_ plaintext: inout Data, final: Bool) throws -> [String: Any] {
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard plaintext.count <= RelayBlindEnvelope.maxCiphertextBytes else {
            throw PrivacyClassError.invalidMaterial
        }
        guard nextSeq < (UInt64(1) << 32) else { throw PrivacyClassError.invalidMaterial }
        let seq = nextSeq
        var nonceBytes = Data()
        nonceBytes.reserveCapacity(12)
        nonceBytes.append(noncePrefix)
        nonceBytes.appendUnsigned64(seq)
        let nonce: AES.GCM.Nonce
        let box: AES.GCM.SealedBox
        do {
            nonce = try AES.GCM.Nonce(data: nonceBytes)
            box = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: Self.frameAAD(
                    envelopeDigest: envelopeDigest,
                    kid: kid,
                    requestID: requestID,
                    stream: stream,
                    seq: seq,
                    final: final
                )
            )
        } catch {
            throw PrivacyClassError.invalidMaterial
        }
        var sealed = box.ciphertext
        sealed.append(box.tag)
        nextSeq = seq + 1
        return [
            "object": PrivacyClassConstants.frameObject,
            "version": PrivacyClassConstants.responseVersion,
            "seq": seq,
            "final": final,
            "ciphertext": RelayBlindBase64URL.encode(sealed),
        ]
    }

    private static func validateContext(envelopeDigest: String, kid: String, requestID: String) throws {
        guard (try? decodePrivacyFixed(envelopeDigest, count: 32)) != nil,
              (try? decodePrivacyFixed(kid, count: 16)) != nil,
              visiblePrivacyASCII(requestID, maxBytes: PrivacyClassConstants.maxIdentifierBytes) else {
            throw PrivacyClassError.invalidMaterial
        }
    }
}

struct PrivacyPostureStatement: Sendable, Equatable {
    let version: String
    let privacyClass: String
    let providerID: String
    let assignedSession: String
    let nonce: String
    let sequence: UInt64
    let issuedAtUnix: Int64
    let binaryVersion: String
    let codeCDHash: String
    let teamID: String
    let signingIdentifier: String
    let hardenedRuntime: Bool
    let libraryValidation: Bool
    let getTaskAllow: Bool
    let csDebugged: Bool
    let pTraced: Bool
    let ptDenyAttachApplied: Bool
    let coreDumpsDisabled: Bool
    let sipEnabled: Bool
    let runtimeSource: String
    let diagnosticEnvClear: Bool
    let kvDiskTierDisabled: Bool
    let seKeyBackend: String
    /// Framed in the given order. Must already be strictly ascending; framing does not sort.
    let privacyKeyRecordDigests: [String]

    var wireObject: [String: Any] {
        [
            "version": version,
            "privacy_class": privacyClass,
            "provider_id": providerID,
            "assigned_session": assignedSession,
            "nonce": nonce,
            "sequence": sequence,
            "issued_at_unix": issuedAtUnix,
            "binary_version": binaryVersion,
            "code_cdhash": codeCDHash,
            "team_id": teamID,
            "signing_identifier": signingIdentifier,
            "hardened_runtime": hardenedRuntime,
            "library_validation": libraryValidation,
            "get_task_allow": getTaskAllow,
            "cs_debugged": csDebugged,
            "p_traced": pTraced,
            "pt_deny_attach_applied": ptDenyAttachApplied,
            "core_dumps_disabled": coreDumpsDisabled,
            "sip_enabled": sipEnabled,
            "runtime_source": runtimeSource,
            "diagnostic_env_clear": diagnosticEnvClear,
            "kv_disk_tier_disabled": kvDiskTierDisabled,
            "se_key_backend": seKeyBackend,
            "privacy_key_record_digests": privacyKeyRecordDigests,
        ]
    }

    /// SPEC-049-R006 booleans are not enforced. A failing posture still frames so the coordinator can quarantine it.
    func framing() throws -> Data {
        try validate()
        let nonceBytes = try decodePrivacyFixed(nonce, count: 32)
        var framed = Data()
        for value in [PrivacyClassConstants.postureDomain, version, privacyClass, providerID, assignedSession] {
            framed.appendFramed(Data(value.utf8))
        }
        framed.appendFramed(nonceBytes)
        framed.appendUnsigned64(sequence)
        framed.appendSigned64(issuedAtUnix)
        for value in [binaryVersion, codeCDHash, teamID, signingIdentifier] {
            framed.appendFramed(Data(value.utf8))
        }
        for flag in [hardenedRuntime, libraryValidation, getTaskAllow, csDebugged, pTraced, ptDenyAttachApplied, coreDumpsDisabled, sipEnabled] {
            framed.appendUnsigned64(flag ? 1 : 0)
        }
        framed.appendFramed(Data(runtimeSource.utf8))
        framed.appendUnsigned64(diagnosticEnvClear ? 1 : 0)
        framed.appendUnsigned64(kvDiskTierDisabled ? 1 : 0)
        framed.appendFramed(Data(seKeyBackend.utf8))
        guard privacyKeyRecordDigests.count <= Int(UInt32.max) else { throw PrivacyClassError.invalidMaterial }
        framed.appendUnsigned32(UInt32(privacyKeyRecordDigests.count))
        for digest in privacyKeyRecordDigests {
            framed.appendFramed(Data(digest.utf8))
        }
        return framed
    }

    private func validate() throws {
        guard version == PrivacyClassConstants.postureVersion,
              privacyClass == PrivacyClassConstants.v1,
              runtimeSource == PrivacyClassConstants.runtimeSource,
              visiblePrivacyASCII(providerID, maxBytes: PrivacyClassConstants.maxIdentifierBytes),
              visiblePrivacyASCII(assignedSession, maxBytes: PrivacyClassConstants.maxIdentifierBytes),
              (try? decodePrivacyFixed(nonce, count: 32)) != nil,
              visiblePrivacyASCII(binaryVersion, maxBytes: PrivacyClassConstants.maxIdentifierBytes),
              validPrivacyCDHash(codeCDHash),
              validPrivacyTeamID(teamID),
              visiblePrivacyASCII(signingIdentifier, maxBytes: PrivacyClassConstants.maxIdentifierBytes),
              seKeyBackend == PrivacyClassConstants.seBackendFile || seKeyBackend == PrivacyClassConstants.seBackendKeychain,
              validPrivacyDigestSet(privacyKeyRecordDigests) else {
            throw PrivacyClassError.invalidMaterial
        }
    }
}

struct PrivacyKeyAttestation: Sendable, Equatable {
    let version: String
    let keyRecordDigest: String
    let privacyClass: String
    let assurance: String
    let binaryVersion: String
    let codeCDHash: String
    let notBeforeUnix: Int64
    let expiresAtUnix: Int64

    var wireObject: [String: Any] {
        [
            "version": version,
            "key_record_digest": keyRecordDigest,
            "privacy_class": privacyClass,
            "assurance": assurance,
            "binary_version": binaryVersion,
            "code_cdhash": codeCDHash,
            "not_before_unix": notBeforeUnix,
            "expires_at_unix": expiresAtUnix,
        ]
    }

    func framing() throws -> Data {
        try validate()
        var framed = Data()
        for value in [PrivacyClassConstants.keyAttestationDomain, version, keyRecordDigest, privacyClass, assurance, binaryVersion, codeCDHash] {
            framed.appendFramed(Data(value.utf8))
        }
        framed.appendSigned64(notBeforeUnix)
        framed.appendSigned64(expiresAtUnix)
        return framed
    }

    func sign(identityKey: Curve25519.Signing.PrivateKey) throws -> Data {
        try identityKey.signature(for: framing())
    }

    private func validate() throws {
        guard version == PrivacyClassConstants.keyAttestationVersion,
              privacyClass == PrivacyClassConstants.v1,
              assurance == PrivacyClassConstants.assurance,
              (try? decodePrivacyFixed(keyRecordDigest, count: 32)) != nil,
              visiblePrivacyASCII(binaryVersion, maxBytes: PrivacyClassConstants.maxIdentifierBytes),
              validPrivacyCDHash(codeCDHash),
              notBeforeUnix >= 0,
              expiresAtUnix > notBeforeUnix,
              expiresAtUnix - notBeforeUnix <= PrivacyClassConstants.maxKeyLifetimeSeconds else {
            throw PrivacyClassError.invalidMaterial
        }
    }
}

private func decodePrivacyFixed(_ text: String, count: Int) throws -> Data {
    do {
        return try RelayBlindBase64URL.decode(text, exactCount: count)
    } catch {
        throw PrivacyClassError.invalidMaterial
    }
}

private func visiblePrivacyASCII(_ value: String, maxBytes: Int) -> Bool {
    let bytes = Array(value.utf8)
    return !bytes.isEmpty && bytes.count <= maxBytes && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
}

private func validPrivacyCDHash(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 40 else { return false }
    return bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
}

private func validPrivacyTeamID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 10 else { return false }
    return bytes.allSatisfy { ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x30 && $0 <= 0x39) }
}

private func validPrivacyDigestSet(_ values: [String]) -> Bool {
    guard values.count <= PrivacyClassConstants.maxKeyRecordDigests else { return false }
    for (index, value) in values.enumerated() {
        guard (try? decodePrivacyFixed(value, count: 32)) != nil else { return false }
        if index > 0 && value <= values[index - 1] { return false }
    }
    return true
}
