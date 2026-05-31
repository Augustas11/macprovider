import Foundation

protocol Tier2AttestationTokenGenerating: Sendable {
    func makeAttestationToken(
        challengeBase64URL: String?,
        providerID: String,
        binaryVersion: String,
        snapshot: ProviderSnapshot,
        providerECDHPublicKey: String
    ) async -> [String: Any]?
}

struct ManagedDeviceAttestationGenerator: Tier2AttestationTokenGenerating {
    static let format = "apple-managed-device-attestation-acme-v1"
    static let artifactPathEnvironmentKey = "MACPROVIDER_TIER2_MDA_ARTIFACT_PATH"

    private let artifactPath: String?
    private let readFile: @Sendable (String) throws -> Data
    private let now: @Sendable () -> Date

    init(
        artifactPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readFile: @escaping @Sendable (String) throws -> Data = {
            try Data(contentsOf: URL(fileURLWithPath: $0))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let configuredPath = artifactPath ?? environment[Self.artifactPathEnvironmentKey]
        self.artifactPath = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.readFile = readFile
        self.now = now
    }

    func makeAttestationToken(
        challengeBase64URL: String?,
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
            return Self.tokenEnvelope(
                tokenBase64URL: artifact.tokenBase64URL ?? challengeBase64URL,
                challengeBase64URL: challengeBase64URL,
                providerID: providerID,
                binaryVersion: binaryVersion,
                snapshot: snapshot,
                providerECDHPublicKey: providerECDHPublicKey,
                issuedAt: now(),
                certificateChain: artifact.certificateChain,
                certificateSigningRequest: artifact.certificateSigningRequest
            )
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
        certificateSigningRequest: String? = nil
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
        }
        return [
            "format": format,
            "token": tokenBase64URL,
            "challenge": challengeBase64URL,
            "issued_at": iso8601String(issuedAt),
            "expires_at": iso8601String(issuedAt.addingTimeInterval(600)),
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

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private struct ManagedDeviceAttestationArtifact {
    let tokenBase64URL: String?
    let certificateChain: [String]
    let certificateSigningRequest: String

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
            certificateSigningRequest: csr
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
    case invalidRoot
    case unsupportedFormat(String)
    case missingCertificateChain
    case missingCertificateSigningRequest
    case invalidCertificateChain
    case invalidCertificateSigningRequest

    var description: String {
        switch self {
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
