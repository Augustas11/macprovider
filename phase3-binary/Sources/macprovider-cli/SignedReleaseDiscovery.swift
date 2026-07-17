import CryptoKit
import Foundation

struct SignedReleaseDiscoveryHead: Equatable, Sendable {
    static let transportReleaseTag = "release-discovery"
    static let assetName = "macprovider-release-discovery.json"
    static let signatureAssetName = "macprovider-release-discovery.json.sig"
    static let envelopeSchema = "macprovider.release-discovery-envelope.v1"
    static let payloadSchema = "macprovider.release-discovery.v1"
    static let keyID = "macprovider-release-p256-v1"
    static let maxValiditySeconds: TimeInterval = 7 * 24 * 60 * 60

    let releaseSequence: UInt64
    let targetVersion: String
    let targetCompatibilitySetID: String
    let targetArtifactIndexSHA256: String
    let signedPolicyMinimum: String?
    let signedPolicyRevoked: [String]
    let issuedAt: Date
    let expiresAt: Date
    let digest: String

    static func loadVerified(
        headData: Data,
        signatureData: Data,
        now: Date = Date(),
        publicKeyPEM: String = SelfUpdate.checksumPublicKeyPEM
    ) throws -> SignedReleaseDiscoveryHead {
        do {
            try AutotuneStrictJSON.rejectDuplicateKeys(headData)
        } catch {
            throw UpdateError.discoveryHeadInvalid("duplicate_or_invalid_json")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: headData) as? [String: Any] else {
            throw UpdateError.discoveryHeadInvalid("top_level")
        }
        try requireExactKeys(envelope, ["schema_version", "signed"], "discovery_envelope")
        guard envelope["schema_version"] as? String == envelopeSchema,
              let signed = envelope["signed"] as? [String: Any]
        else {
            throw UpdateError.discoveryHeadInvalid("envelope_schema")
        }
        guard var canonicalEnvelope = try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw UpdateError.discoveryHeadInvalid("canonical_envelope")
        }
        canonicalEnvelope.append(0x0a)
        guard canonicalEnvelope == headData else {
            throw UpdateError.discoveryHeadInvalid("noncanonical_envelope")
        }

        try requireExactKeys(signed, [
            "expires_at",
            "issued_at",
            "release_sequence",
            "schema_version",
            "signed_policy_minimum",
            "signed_policy_revoked",
            "target_artifact_index_sha256",
            "target_compatibility_set_id",
        ], "discovery_signed")
        guard signed["schema_version"] as? String == payloadSchema,
              let sequenceNumber = signed["release_sequence"] as? NSNumber,
              sequenceNumber.doubleValue.rounded(.towardZero) == sequenceNumber.doubleValue,
              sequenceNumber.doubleValue > 0,
              sequenceNumber.uint64Value > 0,
              sequenceNumber.doubleValue <= Double(UInt64.max),
              let setID = signed["target_compatibility_set_id"] as? String,
              CompatibilitySetManifest.isCanonicalCompatibilitySetID(setID),
              let indexSHA = signed["target_artifact_index_sha256"] as? String,
              indexSHA.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let issuedRaw = signed["issued_at"] as? String,
              let expiresRaw = signed["expires_at"] as? String,
              let issued = ISO8601DateFormatter.releaseDiscovery.date(from: issuedRaw),
              let expires = ISO8601DateFormatter.releaseDiscovery.date(from: expiresRaw),
              let revoked = signed["signed_policy_revoked"] as? [String]
        else {
            throw UpdateError.discoveryHeadInvalid("signed_fields")
        }
        let releaseSequence = sequenceNumber.uint64Value
        let minimum = signed["signed_policy_minimum"] as? String
        let normalizedMinimum = try minimum.map { try AutoUpdateRecommendation.validate($0).normalized }
        let normalizedRevoked = try revoked.map { try AutoUpdateRecommendation.validate($0).normalized }
        guard issued <= now.addingTimeInterval(5),
              expires > now,
              expires.timeIntervalSince(issued) > 0,
              expires.timeIntervalSince(issued) <= maxValiditySeconds
        else {
            throw UpdateError.discoveryHeadExpired
        }
        guard var signedBytes = try? JSONSerialization.data(
            withJSONObject: signed,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw UpdateError.discoveryHeadInvalid("canonical_signed")
        }
        signedBytes.append(0x0a)
        try verifySignature(payload: signedBytes, signatureData: signatureData, publicKeyPEM: publicKeyPEM)
        let targetVersion = try targetVersion(fromCompatibilitySetID: setID)
        return SignedReleaseDiscoveryHead(
            releaseSequence: releaseSequence,
            targetVersion: targetVersion,
            targetCompatibilitySetID: setID,
            targetArtifactIndexSHA256: indexSHA,
            signedPolicyMinimum: normalizedMinimum,
            signedPolicyRevoked: normalizedRevoked,
            issuedAt: issued,
            expiresAt: expires,
            digest: SHA256.hash(data: headData).map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func targetVersion(fromCompatibilitySetID setID: String) throws -> String {
        guard let tagRange = setID.range(
            of: #":v[0-9]+\.[0-9]+\.[0-9]+@"#,
            options: .regularExpression
        ) else {
            throw UpdateError.discoveryHeadInvalid("target_version")
        }
        let raw = String(setID[tagRange].dropFirst(2).dropLast())
        return try AutoUpdateRecommendation.validate(raw).normalized
    }

    private static func requireExactKeys(_ object: [String: Any], _ keys: Set<String>, _ label: String) throws {
        guard Set(object.keys) == keys else {
            throw UpdateError.discoveryHeadInvalid("\(label)_fields")
        }
    }

    private static func verifySignature(payload: Data, signatureData: Data, publicKeyPEM: String) throws {
        do {
            let publicKey = try P256.Signing.PublicKey(pemRepresentation: publicKeyPEM)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            guard publicKey.isValidSignature(signature, for: SHA256.hash(data: payload)) else {
                throw UpdateError.discoveryHeadInvalid("signature_invalid")
            }
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.discoveryHeadInvalid("signature_invalid")
        }
    }
}

private extension ISO8601DateFormatter {
    static var releaseDiscovery: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

struct SignedReleaseDiscoveryState: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let releaseSequence: UInt64
    let headSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case releaseSequence = "release_sequence"
        case headSHA256 = "head_sha256"
    }
}
