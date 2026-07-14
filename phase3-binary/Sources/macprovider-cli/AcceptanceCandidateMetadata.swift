import CryptoKit
import Foundation

struct AcceptanceCandidateMetadata: Equatable, Sendable {
    static let fileName = "acceptance-candidate.json"
    static let signatureFileName = "acceptance-candidate.json.sig"
    static let schemaVersion = "macprovider.acceptance-candidate.v1"
    static let channel = "acceptance"
    static let repository = "Augustas11/macprovider"
    static let signatureDomain = Data("macprovider.acceptance-candidate.v1\n".utf8)
    // Synced byte-for-byte from security/acceptance-candidate-signing-public.pem.
    static let signingPublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEH3cSQs2LWFX2fP980/bheMCDuDRl
    9Rk7C3PxvOE96Lm1Iy2oZGgB7sA99226bl8irZKV2L9o7IL/2/mL/F0m8A==
    -----END PUBLIC KEY-----
    """

    let compatibilitySetID: String

    static func signaturePayload(metadata: Data) -> Data {
        signatureDomain + metadata
    }

    static func loadValidated(
        metadata: Data,
        checksums: Data,
        expectedRepository: String = repository,
        expectedTag: String,
        expectedCandidateCommit: String,
        expectedControlCommit: String,
        expectedRunID: String,
        expectedRunAttempt: Int,
        now: Date = Date()
    ) throws -> AcceptanceCandidateMetadata {
        guard metadata.count <= 16_384 else { throw invalid("size") }
        do {
            try AutotuneStrictJSON.rejectDuplicateKeys(metadata)
        } catch {
            throw invalid("duplicate_or_invalid_json")
        }
        guard let object = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              Set(object.keys) == Set([
                  "candidate_commit", "candidate_ref", "channel", "checksums", "compatibility_set_id",
                  "control_commit", "expires_at", "issued_at", "repository", "run_attempt", "run_id",
                  "schema_version", "signing", "tag",
              ]),
              var canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              )
        else { throw invalid("fields") }
        canonical.append(0x0a)
        guard canonical == metadata else { throw invalid("noncanonical") }

        guard expectedRepository == repository,
              matches(expectedRepository, #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#),
              matches(expectedTag, #"^v[0-9]+\.[0-9]+\.[0-9]+$"#),
              matches(expectedCandidateCommit, #"^[0-9a-f]{40}$"#),
              matches(expectedControlCommit, #"^[0-9a-f]{40}$"#),
              matches(expectedRunID, #"^[1-9][0-9]{0,19}$"#),
              (1...Int(UInt32.max)).contains(expectedRunAttempt)
        else { throw invalid("expected_identity") }
        guard object["schema_version"] as? String == schemaVersion,
              object["channel"] as? String == channel
        else { throw invalid("signature_domain") }
        guard object["repository"] as? String == expectedRepository,
              object["tag"] as? String == expectedTag,
              object["candidate_commit"] as? String == expectedCandidateCommit,
              object["control_commit"] as? String == expectedControlCommit,
              object["run_id"] as? String == expectedRunID,
              object["run_attempt"] as? Int == expectedRunAttempt,
              let candidateRef = object["candidate_ref"] as? String,
              isValidBranchRef(candidateRef)
        else { throw invalid("expected_identity") }

        let expectedSetID = "\(expectedRepository):\(expectedTag)@\(expectedCandidateCommit)"
        guard object["compatibility_set_id"] as? String == expectedSetID else {
            throw invalid("compatibility_set_id")
        }
        let checksumDigest = SHA256.hash(data: checksums).map { String(format: "%02x", $0) }.joined()
        guard let checksumDescriptor = object["checksums"] as? [String: Any],
              Set(checksumDescriptor.keys) == Set(["name", "sha256"]),
              checksumDescriptor["name"] as? String == "checksums.txt",
              checksumDescriptor["sha256"] as? String == checksumDigest
        else {
            throw invalid("checksums_sha256")
        }
        guard let signing = object["signing"] as? [String: Any],
              Set(signing.keys) == Set(["algorithm", "key_id"]),
              signing["algorithm"] as? String == "ecdsa-p256-sha256",
              signing["key_id"] as? String == "macprovider-acceptance-p256-v1"
        else { throw invalid("signing") }

        guard let issuedRaw = object["issued_at"] as? String,
              let expiresRaw = object["expires_at"] as? String,
              let issuedAt = parseTimestamp(issuedRaw),
              let expiresAt = parseTimestamp(expiresRaw)
        else { throw invalid("timestamps") }
        let validity = expiresAt.timeIntervalSince(issuedAt)
        guard validity >= 300, validity <= 86_400 else { throw invalid("validity_window") }
        guard issuedAt <= now.addingTimeInterval(300) else { throw invalid("future_issuance") }
        guard expiresAt > now else { throw invalid("expired") }

        return AcceptanceCandidateMetadata(compatibilitySetID: expectedSetID)
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        guard matches(raw, #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: raw), formatter.string(from: parsed) == raw else { return nil }
        return parsed
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isValidBranchRef(_ value: String) -> Bool {
        guard matches(value, #"^refs/heads/[A-Za-z0-9](?:[A-Za-z0-9._/-]{0,253}[A-Za-z0-9])?$"#) else {
            return false
        }
        let branch = String(value.dropFirst("refs/heads/".count))
        let components = branch.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !branch.contains("..")
            && !branch.contains("@{")
            && !branch.contains("//")
            && !branch.hasSuffix(".")
            && components.allSatisfy {
                !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".") && !$0.hasSuffix(".lock")
            }
    }

    private static func invalid(_ reason: String) -> UpdateError {
        .acceptanceMetadataInvalid(reason)
    }
}
