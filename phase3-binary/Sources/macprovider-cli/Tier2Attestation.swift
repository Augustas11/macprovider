import CryptoKit
import Foundation
import Security

// MARK: - SecureEnclaveAttestationGenerator

#if arch(arm64)

/// Produces `macprovider-se-p256-v1` attestation tokens at auth proof time
/// using a persistent Secure Enclave P-256 key (runbook §1.1.A).
///
/// Returns nil (with a WARN log) when:
/// - SE hardware is unavailable
/// - A named keychain access group is requested without the entitlement
/// - File-backed SE store initialization fails
/// - Any other SE initialization error
///
/// When no named group is set, a data-protection keychain -34018 falls
/// back to the file-backed CryptoKit SE store instead of returning nil.
///
/// This generator does NOT fake attestation on non-SE hardware; it lets the
/// caller fall back to ManagedDeviceAttestationGenerator or return nil.
struct SecureEnclaveAttestationGenerator: Tier2AttestationTokenGenerating {
    static let format = "macprovider-se-p256-v1"

    private let signer: SEBlobSigner
    private let builder: SEAttestationBuilder
    private let now: @Sendable () -> Date

    init(
        signer: SEBlobSigner,
        builder: SEAttestationBuilder = SEAttestationBuilder(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.signer = signer
        self.builder = builder
        self.now = now
    }

    /// Load (or create) the persistent SE key and return a generator, or nil
    /// if SE is unavailable or the entitlement is missing.
    static func loadIfAvailable(
        accessGroup: String? = nil,
        label: String? = nil
    ) -> SecureEnclaveAttestationGenerator? {
        guard SecureEnclaveIdentity.isAvailable else { return nil }
        do {
            let identity = try SecureEnclaveIdentity.loadOrCreate(
                accessGroup: accessGroup,
                label: label
            )
            return SecureEnclaveAttestationGenerator(signer: identity)
        } catch {
            print("WARN se_attestation unavailable reason=se_identity_load_failed error=\(error)")
            return nil
        }
    }

    func makeAttestationToken(
        challengeBase64URL: String?,
        authAttemptID: String,
        providerID: String,
        binaryVersion: String,
        snapshot: ProviderSnapshot,
        providerECDHPublicKey: String
    ) async -> [String: Any]? {
        guard let challengeBase64URL, !challengeBase64URL.isEmpty else {
            print("WARN se_attestation unsupported reason=missing_attestation_challenge")
            return nil
        }

        let attestation: SignedSEAttestation
        do {
            attestation = try builder.build(
                signer: signer,
                providerECDHPublicKey: providerECDHPublicKey
            )
        } catch {
            print("WARN se_attestation unsupported reason=blob_build_failed error=\(error)")
            return nil
        }

        let tokenBase64URL: String
        do {
            tokenBase64URL = try attestation.tokenBase64URL()
        } catch {
            print("WARN se_attestation unsupported reason=token_serialization_failed error=\(error)")
            return nil
        }

        let issuedAt = now()
        var claimed: [String: Any] = [
            "hardware_family": "apple_silicon",
            "ram_gb": snapshot.capacity.ramGB,
            "model_id": snapshot.modelID ?? "",
        ]
        if let modelHash = snapshot.modelHash {
            claimed["model_hash"] = modelHash
            if let algorithm = snapshot.modelHashAlgorithm {
                claimed["model_hash_algorithm"] = algorithm
            }
        }
        if let weights = snapshot.weightsManifestSHA256 {
            claimed["weights_manifest_sha256"] = weights
            claimed["weights_manifest_algorithm"] = ModelArtifactIdentity.safetensorsManifestV1
        }

        var envelope: [String: Any] = [
            "format": Self.format,
            "token": tokenBase64URL,
            "challenge": challengeBase64URL,
            "issued_at": ManagedDeviceAttestationGenerator.iso8601(issuedAt),
            "expires_at": ManagedDeviceAttestationGenerator.iso8601(issuedAt.addingTimeInterval(600)),
            "provider_id": providerID,
            "binary_version": binaryVersion,
            "claimed": claimed,
            "key_binding": [
                "provider_ecdh_public_key": providerECDHPublicKey,
            ],
        ]

        do {
            envelope["signature"] = try seBindingSignature(
                envelope: envelope,
                authAttemptID: authAttemptID,
                signer: signer
            )
        } catch {
            print("WARN se_attestation unsupported reason=binding_signature_failed error=\(error)")
            return nil
        }

        return envelope
    }

    private func seBindingSignature(
        envelope: [String: Any],
        authAttemptID: String,
        signer: SEBlobSigner
    ) throws -> [String: Any] {
        let payload = try ManagedDeviceAttestationGenerator.buildBindingPayload(
            envelope: envelope,
            authAttemptID: authAttemptID
        )
        let sigDER = try signer.sign(payload)
        return [
            "alg": "ES256",
            "signature": sigDER.base64URLUnpadded(),
        ]
    }
}

#endif

// MARK: - Tier2AttestationTokenGenerating

protocol Tier2AttestationTokenGenerating: Sendable {
    func makeAttestationToken(
        challengeBase64URL: String?,
        authAttemptID: String,
        providerID: String,
        binaryVersion: String,
        snapshot: ProviderSnapshot,
        providerECDHPublicKey: String
    ) async -> [String: Any]?
}

struct ManagedDeviceAttestationGenerator: Tier2AttestationTokenGenerating {
    static let format = "apple-managed-device-attestation-acme-v1"
    static let artifactPathEnvironmentKey = "MACPROVIDER_TIER2_MDA_ARTIFACT_PATH"
    static let signingKeyPathEnvironmentKey = "MACPROVIDER_TIER2_MDA_SIGNING_KEY_PATH"

    private let artifactPath: String?
    private let signingKeyPath: String?
    private let readFile: @Sendable (String) throws -> Data
    private let now: @Sendable () -> Date

    init(
        artifactPath: String? = nil,
        signingKeyPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readFile: @escaping @Sendable (String) throws -> Data = {
            try Data(contentsOf: URL(fileURLWithPath: $0))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let configuredPath = artifactPath ?? environment[Self.artifactPathEnvironmentKey]
        let configuredSigningKeyPath = signingKeyPath ?? environment[Self.signingKeyPathEnvironmentKey]
        self.artifactPath = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.signingKeyPath = configuredSigningKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.readFile = readFile
        self.now = now
    }

    func makeAttestationToken(
        challengeBase64URL: String?,
        authAttemptID: String,
        providerID: String,
        binaryVersion: String,
        snapshot: ProviderSnapshot,
        providerECDHPublicKey: String
    ) async -> [String: Any]? {
        guard let challengeBase64URL, !challengeBase64URL.isEmpty else {
            print("WARN tier2 attestation unsupported reason=missing_attestation_challenge")
            return nil
        }
        guard let artifactPath else {
            print("WARN tier2 attestation unsupported reason=managed_device_attestation_acme_unavailable")
            return nil
        }
        do {
            let artifact = try ManagedDeviceAttestationArtifact.parse(readFile(artifactPath))
            var envelope = Self.tokenEnvelope(
                tokenBase64URL: artifact.tokenBase64URL ?? challengeBase64URL,
                challengeBase64URL: challengeBase64URL,
                providerID: providerID,
                binaryVersion: binaryVersion,
                snapshot: snapshot,
                providerECDHPublicKey: providerECDHPublicKey,
                issuedAt: now(),
                certificateChain: artifact.certificateChain,
                certificateSigningRequest: artifact.certificateSigningRequest,
                signature: artifact.signature
            )
            if envelope["signature"] == nil, let signingKeyPath {
                envelope["signature"] = try Self.bindingSignature(
                    envelope: envelope,
                    authAttemptID: authAttemptID,
                    privateKeyData: readFile(signingKeyPath)
                )
            }
            return envelope
        } catch {
            print("WARN tier2 attestation unsupported reason=mda_artifact_invalid error=\(error)")
            return nil
        }
    }

    static func tokenEnvelope(
        tokenBase64URL: String,
        challengeBase64URL: String,
        providerID: String,
        binaryVersion: String,
        snapshot: ProviderSnapshot,
        providerECDHPublicKey: String,
        issuedAt: Date,
        certificateChain: [String] = [],
        certificateSigningRequest: String? = nil,
        signature: [String: Any]? = nil
    ) -> [String: Any] {
        var envelope = baseTokenEnvelope(
            tokenBase64URL: tokenBase64URL,
            challengeBase64URL: challengeBase64URL,
            providerID: providerID,
            binaryVersion: binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: providerECDHPublicKey,
            issuedAt: issuedAt
        )
        if !certificateChain.isEmpty {
            envelope["certificate_chain"] = certificateChain
        }
        if let certificateSigningRequest {
            envelope["certificate_signing_request"] = certificateSigningRequest
        }
        if let signature {
            envelope["signature"] = signature
        }
        return envelope
    }

    static func tokenEnvelope(
        tokenData: Data,
        challengeBase64URL: String,
        providerID: String,
        binaryVersion: String,
        snapshot: ProviderSnapshot,
        providerECDHPublicKey: String,
        issuedAt: Date
    ) -> [String: Any] {
        baseTokenEnvelope(
            tokenBase64URL: tokenData.base64URLUnpadded(),
            challengeBase64URL: challengeBase64URL,
            providerID: providerID,
            binaryVersion: binaryVersion,
            snapshot: snapshot,
            providerECDHPublicKey: providerECDHPublicKey,
            issuedAt: issuedAt
        )
    }

    private static func baseTokenEnvelope(
        tokenBase64URL: String,
        challengeBase64URL: String,
        providerID: String,
        binaryVersion: String,
        snapshot: ProviderSnapshot,
        providerECDHPublicKey: String,
        issuedAt: Date
    ) -> [String: Any] {
        var claimed: [String: Any] = [
            "hardware_family": hardwareFamilyClaim(),
            "ram_gb": snapshot.capacity.ramGB,
            "model_id": snapshot.modelID ?? "",
        ]
        if let modelHash = snapshot.modelHash {
            claimed["model_hash"] = modelHash
            if let algorithm = snapshot.modelHashAlgorithm {
                claimed["model_hash_algorithm"] = algorithm
            }
        }
        if let weights = snapshot.weightsManifestSHA256 {
            claimed["weights_manifest_sha256"] = weights
            claimed["weights_manifest_algorithm"] = ModelArtifactIdentity.safetensorsManifestV1
        }
        return [
            "format": format,
            "token": tokenBase64URL,
            "challenge": challengeBase64URL,
            "issued_at": iso8601(issuedAt),
            "expires_at": iso8601(issuedAt.addingTimeInterval(600)),
            "provider_id": providerID,
            "binary_version": binaryVersion,
            "claimed": claimed,
            "key_binding": [
                "provider_ecdh_public_key": providerECDHPublicKey,
            ],
        ]
    }

    private static func hardwareFamilyClaim() -> String {
        #if arch(arm64)
        return "apple_silicon"
        #else
        return "unknown"
        #endif
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func bindingSignature(envelope: [String: Any], authAttemptID: String, privateKeyData: Data) throws -> [String: Any] {
        let payload = try buildBindingPayload(envelope: envelope, authAttemptID: authAttemptID)
        let key = try secKey(privateKeyData: privateKeyData)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256,
            payload as CFData,
            &error
        ) as Data? else {
            throw error?.takeRetainedValue() ?? ManagedDeviceAttestationArtifactError.bindingSignatureFailed
        }
        return [
            "alg": "ES256",
            "signature": signature.base64URLUnpadded(),
        ]
    }

    static func buildBindingPayload(envelope: [String: Any], authAttemptID: String) throws -> Data {
        guard let providerID = envelope["provider_id"] as? String,
              let binaryVersion = envelope["binary_version"] as? String,
              let challenge = envelope["challenge"] as? String,
              let issuedAt = envelope["issued_at"] as? String,
              let expiresAt = envelope["expires_at"] as? String,
              let token = envelope["token"] as? String,
              let keyBinding = envelope["key_binding"] as? [String: Any],
              let providerECDH = keyBinding["provider_ecdh_public_key"] as? String,
              let claimed = envelope["claimed"] as? [String: Any]
        else {
            throw ManagedDeviceAttestationArtifactError.bindingPayloadInvalid
        }
        let claimedData = try JSONSerialization.data(withJSONObject: claimed, options: [.sortedKeys])
        let claimedHash = Data(SHA256.hash(data: claimedData)).base64URLUnpadded()
        let tokenHash = Data(SHA256.hash(data: Data(token.utf8))).base64URLUnpadded()
        let fields: [(String, String)] = [
            ("version", "macprovider/spec008/attestation-binding/v1"),
            ("provider_id", providerID),
            ("binary_version", binaryVersion),
            ("challenge", challenge),
            ("auth_attempt_id", authAttemptID),
            ("provider_ecdh_public_key", providerECDH),
            ("issued_at", issuedAt),
            ("expires_at", expiresAt),
            ("token_sha256", tokenHash),
            ("claimed_sha256", claimedHash),
        ]
        var data = Data("{".utf8)
        for (index, field) in fields.enumerated() {
            if index > 0 {
                data.append(Data(",".utf8))
            }
            data.append(goJSONString(field.0))
            data.append(Data(":".utf8))
            data.append(goJSONString(field.1))
        }
        data.append(Data("}".utf8))
        return data
    }

    private static func secKey(privateKeyData: Data) throws -> SecKey {
        let der = decodePEMIfNeeded(privateKeyData)
        for bits in [256, 384, 521] {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits: bits,
            ]
            if let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) {
                return key
            }
        }
        throw ManagedDeviceAttestationArtifactError.bindingPrivateKeyInvalid
    }

    private static func decodePEMIfNeeded(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") else {
            return data
        }
        let body = text
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: body) ?? data
    }

    private static func goJSONString(_ value: String) -> Data {
        var data = Data("\"".utf8)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08:
                data.append(Data(#"\b"#.utf8))
            case 0x0c:
                data.append(Data(#"\f"#.utf8))
            case 0x0a:
                data.append(Data(#"\n"#.utf8))
            case 0x0d:
                data.append(Data(#"\r"#.utf8))
            case 0x09:
                data.append(Data(#"\t"#.utf8))
            case 0x22:
                data.append(Data(#"\""#.utf8))
            case 0x5c:
                data.append(Data(#"\\"#.utf8))
            case 0x26:
                data.append(Data(#"\u0026"#.utf8))
            case 0x3c:
                data.append(Data(#"\u003c"#.utf8))
            case 0x3e:
                data.append(Data(#"\u003e"#.utf8))
            case 0x2028:
                data.append(Data(#"\u2028"#.utf8))
            case 0x2029:
                data.append(Data(#"\u2029"#.utf8))
            case 0x00..<0x20:
                data.append(Data(String(format: #"\u%04x"#, scalar.value).utf8))
            default:
                data.append(Data(String(scalar).utf8))
            }
        }
        data.append(Data("\"".utf8))
        return data
    }
}

private struct ManagedDeviceAttestationArtifact {
    let tokenBase64URL: String?
    let certificateChain: [String]
    let certificateSigningRequest: String
    let signature: [String: Any]?

    static func parse(_ data: Data) throws -> ManagedDeviceAttestationArtifact {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw ManagedDeviceAttestationArtifactError.invalidRoot
        }
        if let format = nonEmptyString(dict["format"]), format != ManagedDeviceAttestationGenerator.format {
            throw ManagedDeviceAttestationArtifactError.unsupportedFormat(format)
        }
        let chain = nonEmptyStringArray(dict["certificate_chain"]) ?? nonEmptyStringArray(dict["x5c"]) ?? []
        guard !chain.isEmpty else {
            throw ManagedDeviceAttestationArtifactError.missingCertificateChain
        }
        for certificate in chain {
            guard validatesDERSequence(certificate) else {
                throw ManagedDeviceAttestationArtifactError.invalidCertificateChain
            }
        }
        guard let csr = nonEmptyString(dict["certificate_signing_request"]) ?? nonEmptyString(dict["csr"]) else {
            throw ManagedDeviceAttestationArtifactError.missingCertificateSigningRequest
        }
        guard validatesDERSequence(csr) else {
            throw ManagedDeviceAttestationArtifactError.invalidCertificateSigningRequest
        }
        let token = nonEmptyString(dict["token"])
        if let token {
            _ = try Data(base64URLUnpadded: token)
        }
        return ManagedDeviceAttestationArtifact(
            tokenBase64URL: token,
            certificateChain: chain,
            certificateSigningRequest: csr,
            signature: dict["signature"] as? [String: Any]
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func nonEmptyStringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        let strings = values.compactMap { nonEmptyString($0) }
        return strings.isEmpty ? nil : strings
    }

    private static func validatesDERSequence(_ encoded: String) -> Bool {
        guard let data = decodeDERData(encoded) else { return false }
        return isTopLevelDERSequence(data)
    }

    private static func decodeDERData(_ encoded: String) -> Data? {
        if encoded.contains("-----BEGIN") {
            return decodePEMData(encoded)
        }
        let compact = encoded.filter { !$0.isWhitespace }
        if let data = Data(base64Encoded: compact) {
            return data
        }
        return try? Data(base64URLUnpadded: compact)
    }

    private static func decodePEMData(_ encoded: String) -> Data? {
        var bodyLines: [String] = []
        var inBlock = false
        for rawLine in encoded.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("-----BEGIN ") {
                inBlock = true
                continue
            }
            if line.hasPrefix("-----END ") {
                break
            }
            if inBlock && !line.isEmpty {
                bodyLines.append(line)
            }
        }
        guard !bodyLines.isEmpty else { return nil }
        return Data(base64Encoded: bodyLines.joined())
    }

    private static func isTopLevelDERSequence(_ data: Data) -> Bool {
        guard data.count >= 2, data[data.startIndex] == 0x30 else { return false }
        let lengthStart = data.index(after: data.startIndex)
        let firstLength = data[lengthStart]
        if firstLength & 0x80 == 0 {
            return data.count == 2 + Int(firstLength)
        }
        let lengthByteCount = Int(firstLength & 0x7f)
        guard lengthByteCount > 0, lengthByteCount <= 4, data.count >= 2 + lengthByteCount else {
            return false
        }
        let firstLongLengthByte = data[data.index(data.startIndex, offsetBy: 2)]
        guard firstLongLengthByte != 0 else { return false }
        var length = 0
        for offset in 0..<lengthByteCount {
            length = (length << 8) | Int(data[data.index(data.startIndex, offsetBy: 2 + offset)])
        }
        guard length >= 128 else { return false }
        return data.count == 2 + lengthByteCount + length
    }
}

private enum ManagedDeviceAttestationArtifactError: Error, CustomStringConvertible {
    case bindingPayloadInvalid
    case bindingPrivateKeyInvalid
    case bindingSignatureFailed
    case invalidRoot
    case unsupportedFormat(String)
    case missingCertificateChain
    case missingCertificateSigningRequest
    case invalidCertificateChain
    case invalidCertificateSigningRequest

    var description: String {
        switch self {
        case .bindingPayloadInvalid:
            return "binding_payload_invalid"
        case .bindingPrivateKeyInvalid:
            return "binding_private_key_invalid"
        case .bindingSignatureFailed:
            return "binding_signature_failed"
        case .invalidRoot:
            return "invalid_root"
        case let .unsupportedFormat(format):
            return "unsupported_format:\(format)"
        case .missingCertificateChain:
            return "missing_certificate_chain"
        case .missingCertificateSigningRequest:
            return "missing_certificate_signing_request"
        case .invalidCertificateChain:
            return "invalid_certificate_chain"
        case .invalidCertificateSigningRequest:
            return "invalid_certificate_signing_request"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
