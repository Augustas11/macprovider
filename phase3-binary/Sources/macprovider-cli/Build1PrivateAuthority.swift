import CryptoKit
import Darwin
import Foundation

enum Build1PrivatePrepareProfile {
    static let profile = "build1-orcarouter-private"
    static let modelKey = "orcarouter/qwen3.8-27b-uncensored"
    static let modelID = "orcarouter/Qwen3.8-27B-Uncensored-MLX"
    static let revision = "38d0ad4e02031658fadd3828634a0174e0b8a282"
    static let artifactID = "mlx-revision-snapshot"
    static let hashAlgorithm = "macprovider.snapshot-manifest.v1"
    static let hash = "8794a87d2041dce5e915809d9e6c16da709d1763e25c4289f279d929aea88dcd"
    static let sizeBytes = 94_723_099_062
    static let fileCount = 80
    static let runtimeFormat = "mlx_safetensors"
    static let runtimeSource = "mlx_cache"
    static let sourceKind = "huggingface_revision"
    static let artifactScope = "complete_revision_snapshot"
    static let signerKeyID = "streamvc-autotune-static-v4"
    static let schemaVersion = "macprovider.build1-private-authority.v1"
    static let authorityUnavailableReason = "private_authority_unavailable"

    static func isApprovedModel(_ value: String) -> Bool {
        value.lowercased(with: nil) == modelKey.lowercased(with: nil)
            || value.lowercased(with: nil) == modelID.lowercased(with: nil)
    }
}

enum Build1PrepareProfileSupport {
    static func profile(for authority: Build1LaneAArtifactAuthority) -> String? {
        if authority.catalogKey == Build1PrivatePrepareProfile.modelKey,
           authority.modelID == Build1PrivatePrepareProfile.modelID,
           authority.revision == Build1PrivatePrepareProfile.revision,
           authority.artifactID == Build1PrivatePrepareProfile.artifactID {
            return Build1PrivatePrepareProfile.profile
        }
        if authority.catalogKey == Build1LaneAPrepareProfile.catalogKey,
           authority.modelID == Build1LaneAPrepareProfile.artifactModelID,
           authority.revision == Build1LaneAPrepareProfile.artifactRevision,
           authority.artifactID == Build1LaneAPrepareProfile.artifactID {
            return Build1LaneAPrepareProfile.profile
        }
        return nil
    }

    static func expectedTuple(for catalogKey: String) -> (
        profile: String,
        catalogKey: String,
        modelID: String,
        revision: String,
        artifactID: String,
        runtimeSource: String
    )? {
        if Build1PrivatePrepareProfile.isApprovedModel(catalogKey) {
            return (
                Build1PrivatePrepareProfile.profile,
                Build1PrivatePrepareProfile.modelKey,
                Build1PrivatePrepareProfile.modelID,
                Build1PrivatePrepareProfile.revision,
                Build1PrivatePrepareProfile.artifactID,
                Build1PrivatePrepareProfile.runtimeSource
            )
        }
        if Build1LaneAPrepareProfile.isApprovedCatalogKey(catalogKey) {
            return (
                Build1LaneAPrepareProfile.profile,
                Build1LaneAPrepareProfile.catalogKey,
                Build1LaneAPrepareProfile.artifactModelID,
                Build1LaneAPrepareProfile.artifactRevision,
                Build1LaneAPrepareProfile.artifactID,
                Build1LaneAPrepareProfile.runtimeSource
            )
        }
        return nil
    }
}

enum Build1PrivateAuthorityError: Error, Equatable, Sendable {
    case invalid(String)
}

enum Build1PrivateAuthorityLoader {
    private static let maxAuthorityBytes = 64 * 1024
    private static let maxSignatureBytes = 4 * 1024
    private static let maxValidity: TimeInterval = 14 * 24 * 60 * 60
    private static let futureSkew: TimeInterval = 5 * 60

    static func load(
        authorityURL: URL,
        signatureURL: URL,
        now: Date = Date(),
        candidateBytes: Data = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8),
        verifySignature: (Data, Data) -> Bool = AutotuneStaticInputs.defaultSignatureVerifier
    ) throws -> Build1LaneAArtifactAuthority {
        let authorityBytes = try readRegular(authorityURL, maximum: maxAuthorityBytes, label: "authority")
        let signatureBytes = try readRegular(signatureURL, maximum: maxSignatureBytes, label: "authority signature")
        guard verifySignature(authorityBytes, signatureBytes) else {
            throw Build1PrivateAuthorityError.invalid("signature_invalid")
        }

        try AutotuneStrictJSON.rejectDuplicateKeys(authorityBytes)
        try AutotuneStrictJSON.rejectDuplicateKeys(signatureBytes)
        let sidecar = try object(signatureBytes, label: "authority signature")
        try exactKeys(sidecar, ["alg", "key_id", "signature"], label: "authority signature")
        guard sidecar["alg"] as? String == "ed25519",
              sidecar["key_id"] as? String == Build1PrivatePrepareProfile.signerKeyID,
              let encodedSignature = sidecar["signature"] as? String,
              let signature = Data(base64Encoded: encodedSignature),
              signature.count == 64,
              signature.base64EncodedString() == encodedSignature
        else {
            throw Build1PrivateAuthorityError.invalid("signer_mismatch")
        }

        let root = try object(authorityBytes, label: "authority")
        try exactKeys(
            root,
            ["artifact", "catalog_guard", "constraints", "expires_at", "generated_at", "model", "profile", "release_id", "schema_version"],
            label: "authority"
        )
        guard root["schema_version"] as? String == Build1PrivatePrepareProfile.schemaVersion,
              root["profile"] as? String == Build1PrivatePrepareProfile.profile,
              let releaseID = nonempty(root["release_id"]),
              let generatedRaw = root["generated_at"] as? String,
              let expiresRaw = root["expires_at"] as? String,
              let generatedAt = timestamp(generatedRaw),
              let expiresAt = timestamp(expiresRaw),
              generatedAt <= now.addingTimeInterval(futureSkew),
              expiresAt > now,
              expiresAt > generatedAt,
              expiresAt.timeIntervalSince(generatedAt) <= maxValidity + futureSkew
        else {
            throw Build1PrivateAuthorityError.invalid("release_or_freshness_invalid")
        }

        let model = try child(root, "model", keys: ["model_id", "model_key", "revision"])
        guard model["model_key"] as? String == Build1PrivatePrepareProfile.modelKey,
              model["model_id"] as? String == Build1PrivatePrepareProfile.modelID,
              model["revision"] as? String == Build1PrivatePrepareProfile.revision
        else {
            throw Build1PrivateAuthorityError.invalid("model_tuple_mismatch")
        }

        let artifact = try child(
            root,
            "artifact",
            keys: ["artifact_id", "artifact_scope", "file_count", "hash", "hash_algorithm", "runtime_format", "runtime_source", "size_bytes", "source_kind"]
        )
        guard artifact["artifact_id"] as? String == Build1PrivatePrepareProfile.artifactID,
              artifact["artifact_scope"] as? String == Build1PrivatePrepareProfile.artifactScope,
              artifact["file_count"] as? Int == Build1PrivatePrepareProfile.fileCount,
              artifact["hash"] as? String == Build1PrivatePrepareProfile.hash,
              artifact["hash_algorithm"] as? String == Build1PrivatePrepareProfile.hashAlgorithm,
              artifact["runtime_format"] as? String == Build1PrivatePrepareProfile.runtimeFormat,
              artifact["runtime_source"] as? String == Build1PrivatePrepareProfile.runtimeSource,
              artifact["size_bytes"] as? Int == Build1PrivatePrepareProfile.sizeBytes,
              artifact["source_kind"] as? String == Build1PrivatePrepareProfile.sourceKind,
              Build1PrivatePrepareProfile.sizeBytes <= Build1LaneAPrepareProfile.maxArtifactSizeBytes
        else {
            throw Build1PrivateAuthorityError.invalid("artifact_tuple_mismatch")
        }

        let constraints = try child(
            root,
            "constraints",
            keys: ["admission_granted", "production_activation", "public_catalog_publication", "rewards_or_payouts", "settlement_granted"]
        )
        guard constraints.values.allSatisfy({ ($0 as? Bool) == false }) else {
            throw Build1PrivateAuthorityError.invalid("authority_boundary_invalid")
        }

        let candidate = try AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(candidateBytes)
        let guardObject = try child(
            root,
            "catalog_guard",
            keys: ["absent", "candidate_catalog_sha256", "candidate_release_id", "checked_at", "model_key"]
        )
        guard guardObject["absent"] as? Bool == true,
              guardObject["model_key"] as? String == Build1PrivatePrepareProfile.modelKey,
              guardObject["candidate_release_id"] as? String == candidate.version,
              guardObject["candidate_catalog_sha256"] as? String == sha256Hex(candidateBytes),
              guardObject["checked_at"] as? String == generatedRaw,
              candidate.rows[Build1PrivatePrepareProfile.modelKey] == nil
        else {
            throw Build1PrivateAuthorityError.invalid("public_catalog_guard_failed")
        }

        return Build1LaneAArtifactAuthority(
            catalogKey: Build1PrivatePrepareProfile.modelKey,
            modelID: Build1PrivatePrepareProfile.modelID,
            revision: Build1PrivatePrepareProfile.revision,
            artifactID: Build1PrivatePrepareProfile.artifactID,
            hashAlgorithm: Build1PrivatePrepareProfile.hashAlgorithm,
            hash: Build1PrivatePrepareProfile.hash,
            sizeBytes: Build1PrivatePrepareProfile.sizeBytes,
            feedSHA256: sha256Hex(authorityBytes),
            feedSignerKeyID: Build1PrivatePrepareProfile.signerKeyID,
            releaseID: releaseID
        )
    }

    private static func readRegular(_ url: URL, maximum: Int, label: String) throws -> Data {
        guard url.isFileURL else {
            throw Build1PrivateAuthorityError.invalid("\(label)_not_file_url")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Build1PrivateAuthorityError.invalid("\(label)_unavailable")
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= maximum
        else {
            throw Build1PrivateAuthorityError.invalid("\(label)_unsafe")
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: min(8 * 1024, maximum + 1))
        while true {
            let count = read(descriptor, &buffer, min(buffer.count, maximum + 1 - data.count))
            guard count >= 0 else {
                throw Build1PrivateAuthorityError.invalid("\(label)_unreadable")
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            guard data.count <= maximum else {
                throw Build1PrivateAuthorityError.invalid("\(label)_unsafe")
            }
        }
        guard data.count == Int(metadata.st_size) else {
            throw Build1PrivateAuthorityError.invalid("\(label)_changed_during_read")
        }
        return data
    }

    private static func object(_ data: Data, label: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Build1PrivateAuthorityError.invalid("\(label)_not_object")
        }
        return value
    }

    private static func child(_ root: [String: Any], _ key: String, keys: Set<String>) throws -> [String: Any] {
        guard let value = root[key] as? [String: Any] else {
            throw Build1PrivateAuthorityError.invalid("\(key)_not_object")
        }
        try exactKeys(value, keys, label: key)
        return value
    }

    private static func exactKeys(_ object: [String: Any], _ keys: Set<String>, label: String) throws {
        guard Set(object.keys) == keys else {
            throw Build1PrivateAuthorityError.invalid("\(label)_keys_invalid")
        }
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let value = value as? String,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 128
        else {
            return nil
        }
        return value
    }

    private static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}
