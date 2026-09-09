import CryptoKit
import Foundation

/// SPEC-023 §3.7 artifact feed (`autotune-artifacts.json`) as the CLI consumes it
/// (BYOM v0.2 slice 2c).
///
/// The feed is a separate signed static feed (§3.7.1): the candidate catalog's
/// closed row schema never changes, so every v0.1 consumer is byte-for-byte
/// unaffected. It is fetched from `/v1/catalog-artifacts` with its detached
/// sidecar and verified through the §3.5 procedure verbatim (§3.7.2), then
/// BOUND to the candidate catalog selected for the same release (§3.7.4) with
/// signer identity equality (§3.7.2) and primary-artifact consistency (§3.7.5).
/// Its failure classes (§3.7.6) fail closed for artifact-derived capabilities
/// only and never block paid recommendation or coordinator join (rule 6): an
/// absent feed — `bakedArtifactFeedJSON == nil` — is indistinguishable from v0.1.
///
/// The schema, identity matrix, uniqueness, and binding rules here mirror the
/// generator (`scripts/catalog-release.py`) and the coordinator
/// (`phase4-coordinator/internal/buyer/catalog_artifacts_feed.go`) exactly; the
/// shared corpus `scripts/tests/fixtures/artifact_feed_conformance.json` pins
/// all three.
struct ArtifactFeed: Equatable, Sendable {
    struct SourceRef: Equatable, Sendable {
        var kind: String
        var repoID: String?
        var revision: String?
        var libraryTag: String?
        var digest: String?
    }

    struct Artifact: Equatable, Sendable {
        var runtimeFormat: String
        var quantization: String
        var sourceRef: SourceRef
        var hashAlgorithm: String
        var hash: String
        var sizeBytes: Int
        var minRAMGB: Double
        var allowedRuntimeSources: [String]
        var verificationStatus: String
        var verifiedAt: String?
        var notes: String?
    }

    struct Model: Equatable, Sendable {
        var rateClass: String?
        var primaryArtifactID: String
        var artifacts: [String: Artifact]

        var primary: Artifact { artifacts[primaryArtifactID]! }
    }

    var version: String
    var generatedAt: Date
    /// The exact `generated_at` string the release stamped; §3.5 rule 11 pairs
    /// feeds by this STRING (the generator compares strings), so an equal
    /// instant spelled differently is a different release stamp here too.
    var generatedAtRaw: String
    var policyVersion: String
    var source: String
    var releaseID: String
    var candidateCatalogSHA256: String
    var models: [String: Model]

    static let source = "operator_curated_autotune_artifact_catalog"
    static let primaryFormat = "mlx_safetensors"
    static let rateClasses: Set<String> = [
        "class-3b", "class-8b", "class-20b-moe", "class-30b-moe", "class-32b", "class-70b", "class-120b-moe",
    ]
    static let verificationStatuses: Set<String> = ["declared", "verified", "blocked"]

    /// §3.7.4 closed artifact-identity matrix: runtime_format determines the only
    /// legal hash_algorithm, source_ref.kind, and allowed_runtime_sources set.
    struct IdentityRow: Sendable {
        var hashAlgorithm: String
        var sourceRefKind: String
        var runtimeSources: Set<String>
    }

    static let identityMatrix: [String: IdentityRow] = [
        "mlx_safetensors": IdentityRow(
            hashAlgorithm: "macprovider.snapshot-manifest.v1",
            sourceRefKind: "huggingface_revision",
            runtimeSources: ["mlx_cache"]
        ),
        "gguf": IdentityRow(
            hashAlgorithm: "macprovider.gguf-file.v1",
            sourceRefKind: "ollama_library_tag",
            runtimeSources: ["ollama_loopback", "llamacpp_loopback", "lmstudio_loopback", "openai_compatible_loopback"]
        ),
    ]
}

enum ArtifactFeedError: Error, Equatable, Sendable {
    /// §3.7.6 class 2: schema, identity matrix, uniqueness, signer identity.
    case integrity(String)
    /// §3.7.6 class 3: release binding (version / generated_at / policy /
    /// candidate digest) or primary consistency with a different release.
    case releaseMismatch(String)
}

extension ArtifactFeed {
    private static let modelKeyPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9._/-]{0,127}$")
    private static let artifactIDPattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]{0,63}$")
    private static let hex64Pattern = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
    private static let hex40Pattern = try! NSRegularExpression(pattern: "^[0-9a-f]{40}$")
    private static let repoIDPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")
    private static let fullDatePattern = try! NSRegularExpression(pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")

    private static func matches(_ pattern: NSRegularExpression, _ value: String) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func exactKeys(_ object: [String: Any], allowed: Set<String>, required: Set<String>, label: String) throws {
        let actual = Set(object.keys)
        guard actual.isSubset(of: allowed), required.isSubset(of: actual) else {
            throw ArtifactFeedError.integrity("\(label): fields differ from the closed schema")
        }
    }

    private static func string(_ object: [String: Any], _ key: String, label: String) throws -> String {
        guard let value = object[key] as? String else {
            throw ArtifactFeedError.integrity("\(label): \(key) must be a string")
        }
        return value
    }

    /// An OPTIONAL string: absent is fine, a present null is a wrong-typed field.
    private static func presentString(_ object: [String: Any], _ key: String, label: String) throws -> String? {
        guard let raw = object[key] else { return nil }
        guard let value = raw as? String else {
            throw ArtifactFeedError.integrity("\(label): \(key) must be a string when present, not null")
        }
        return value
    }

    /// Strict decode of the §3.7.3 closed schema with the §3.7.4 identity matrix
    /// and global hash uniqueness. Release binding is `bind(...)`.
    static func decode(_ data: Data) throws -> ArtifactFeed {
        do {
            try AutotuneStrictJSON.rejectDuplicateKeys(data)
        } catch {
            throw ArtifactFeedError.integrity("duplicate JSON keys")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArtifactFeedError.integrity("top-level value must be an object")
        }
        let top: Set<String> = ["version", "generated_at", "policy_version", "source", "release_id", "candidate_catalog_sha256", "models"]
        try exactKeys(object, allowed: top, required: top, label: "artifact feed")
        let version = try string(object, "version", label: "artifact feed")
        let policyVersion = try string(object, "policy_version", label: "artifact feed")
        let rawGeneratedAt = try string(object, "generated_at", label: "artifact feed")
        let source = try string(object, "source", label: "artifact feed")
        let releaseID = try string(object, "release_id", label: "artifact feed")
        let digest = try string(object, "candidate_catalog_sha256", label: "artifact feed")
        guard !version.isEmpty, version == version.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ArtifactFeedError.integrity("version must be a non-empty trimmed string")
        }
        guard !policyVersion.isEmpty, policyVersion == policyVersion.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ArtifactFeedError.integrity("policy_version must be a non-empty trimmed string")
        }
        guard let generatedAt = ISO8601DateFormatter.autotuneInternet.date(from: rawGeneratedAt) else {
            throw ArtifactFeedError.integrity("generated_at must be RFC3339")
        }
        guard source == Self.source else {
            throw ArtifactFeedError.integrity("source must be \(Self.source)")
        }
        guard releaseID == version else {
            throw ArtifactFeedError.integrity("release_id must equal version")
        }
        guard matches(hex64Pattern, digest) else {
            throw ArtifactFeedError.integrity("candidate_catalog_sha256 must be lowercase 64-hex")
        }
        guard let rawModels = object["models"] as? [String: Any], !rawModels.isEmpty else {
            throw ArtifactFeedError.integrity("models must be a non-empty object")
        }
        var models: [String: Model] = [:]
        var seen: [String: String] = [:]
        for key in rawModels.keys.sorted() {
            guard matches(modelKeyPattern, key), !key.contains("//") else {
                throw ArtifactFeedError.integrity("model \(key): invalid model key")
            }
            guard let rawModel = rawModels[key] as? [String: Any] else {
                throw ArtifactFeedError.integrity("model \(key): must be an object")
            }
            try exactKeys(rawModel, allowed: ["rate_class", "primary_artifact_id", "artifacts"], required: ["primary_artifact_id", "artifacts"], label: "model \(key)")
            let rateClass = try presentString(rawModel, "rate_class", label: "model \(key)")
            if let rateClass, !rateClasses.contains(rateClass) {
                throw ArtifactFeedError.integrity("model \(key): rate_class \(rateClass) is not a SPEC-023 §3.3.1 class")
            }
            let primaryID = try string(rawModel, "primary_artifact_id", label: "model \(key)")
            guard let rawArtifacts = rawModel["artifacts"] as? [String: Any], !rawArtifacts.isEmpty else {
                throw ArtifactFeedError.integrity("model \(key): artifacts must be a non-empty object")
            }
            var artifacts: [String: Artifact] = [:]
            for artifactID in rawArtifacts.keys.sorted() {
                guard matches(artifactIDPattern, artifactID) else {
                    throw ArtifactFeedError.integrity("model \(key): artifact_id \(artifactID) does not match ^[a-z0-9][a-z0-9-]{0,63}$")
                }
                guard let rawArtifact = rawArtifacts[artifactID] as? [String: Any] else {
                    throw ArtifactFeedError.integrity("model \(key) artifact \(artifactID): must be an object")
                }
                let artifact = try decodeArtifact(rawArtifact, label: "model \(key) artifact \(artifactID)")
                let identity = artifact.hashAlgorithm + "\u{0}" + artifact.hash
                if let prior = seen[identity] {
                    throw ArtifactFeedError.integrity("(\(artifact.hashAlgorithm), \(artifact.hash)) appears under both \(prior) and \(key)/\(artifactID)")
                }
                seen[identity] = key + "/" + artifactID
                artifacts[artifactID] = artifact
            }
            guard let primary = artifacts[primaryID] else {
                throw ArtifactFeedError.integrity("model \(key): primary_artifact_id \(primaryID) does not name an artifact of this model")
            }
            guard primary.runtimeFormat == primaryFormat else {
                throw ArtifactFeedError.integrity("model \(key): primary_artifact_id must name an \(primaryFormat) artifact")
            }
            models[key] = Model(rateClass: rateClass, primaryArtifactID: primaryID, artifacts: artifacts)
        }
        return ArtifactFeed(
            version: version, generatedAt: generatedAt, generatedAtRaw: rawGeneratedAt, policyVersion: policyVersion,
            source: source, releaseID: releaseID, candidateCatalogSHA256: digest, models: models
        )
    }

    private static func decodeArtifact(_ object: [String: Any], label: String) throws -> Artifact {
        let allowed: Set<String> = [
            "runtime_format", "quantization", "source_ref", "hash_algorithm", "hash", "size_bytes", "min_ram_gb",
            "allowed_runtime_sources", "verification_status", "verified_at", "notes",
        ]
        try exactKeys(object, allowed: allowed, required: allowed.subtracting(["notes"]), label: label)
        let runtimeFormat = try string(object, "runtime_format", label: label)
        guard let row = identityMatrix[runtimeFormat] else {
            throw ArtifactFeedError.integrity("\(label): unknown runtime_format \(runtimeFormat)")
        }
        let hashAlgorithm = try string(object, "hash_algorithm", label: label)
        guard hashAlgorithm == row.hashAlgorithm else {
            throw ArtifactFeedError.integrity("\(label): runtime_format \(runtimeFormat) requires hash_algorithm \(row.hashAlgorithm)")
        }
        let quantization = try string(object, "quantization", label: label)
        guard !quantization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArtifactFeedError.integrity("\(label): quantization must be a non-empty string")
        }
        let hash = try string(object, "hash", label: label)
        guard matches(hex64Pattern, hash) else {
            throw ArtifactFeedError.integrity("\(label): hash must be lowercase 64-hex")
        }
        // size_bytes: an integer in the int64 domain of every consumer. JSON
        // numbers reach us as NSNumber; a float, a bool, or a value NSNumber can
        // only represent by saturating (its decimal text no longer round-trips
        // through int64) is rejected.
        guard let rawSize = object["size_bytes"] as? NSNumber,
              CFGetTypeID(rawSize) != CFBooleanGetTypeID(),
              CFNumberIsFloatType(rawSize) == false,
              rawSize.int64Value > 0,
              rawSize.stringValue == String(rawSize.int64Value)
        else {
            throw ArtifactFeedError.integrity("\(label): size_bytes must be a measured integer > 0 within int64")
        }
        guard let rawRAM = object["min_ram_gb"] as? NSNumber, CFGetTypeID(rawRAM) != CFBooleanGetTypeID(),
              rawRAM.doubleValue.isFinite, rawRAM.doubleValue > 0
        else {
            throw ArtifactFeedError.integrity("\(label): min_ram_gb must be a number > 0")
        }
        guard let sources = object["allowed_runtime_sources"] as? [String], !sources.isEmpty else {
            throw ArtifactFeedError.integrity("\(label): allowed_runtime_sources must be a non-empty array of strings")
        }
        guard Set(sources).count == sources.count else {
            throw ArtifactFeedError.integrity("\(label): allowed_runtime_sources must not repeat an adapter")
        }
        for adapter in sources where !row.runtimeSources.contains(adapter) {
            throw ArtifactFeedError.integrity("\(label): runtime_format \(runtimeFormat) may not allow runtime source \(adapter)")
        }
        let status = try string(object, "verification_status", label: label)
        guard verificationStatuses.contains(status) else {
            throw ArtifactFeedError.integrity("\(label): invalid verification_status \(status)")
        }
        // verified_at is REQUIRED and may be null: presence was checked by exactKeys.
        let verifiedAt: String?
        if object["verified_at"] is NSNull {
            verifiedAt = nil
        } else {
            verifiedAt = try string(object, "verified_at", label: label)
        }
        if status == "verified" {
            guard !sources.contains("openai_compatible_loopback") else {
                throw ArtifactFeedError.integrity("\(label): a verified artifact may not allow openai_compatible_loopback")
            }
            guard let verifiedAt, matches(fullDatePattern, verifiedAt), realDate(verifiedAt) else {
                throw ArtifactFeedError.integrity("\(label): verified_at must be an RFC3339 full-date when verified")
            }
        } else if verifiedAt != nil {
            throw ArtifactFeedError.integrity("\(label): verified_at must be null unless verification_status is verified")
        }
        let notes = try presentString(object, "notes", label: label)
        guard let rawRef = object["source_ref"] as? [String: Any] else {
            throw ArtifactFeedError.integrity("\(label): source_ref must be an object")
        }
        let kind = try string(rawRef, "kind", label: "\(label) source_ref")
        guard kind == row.sourceRefKind else {
            throw ArtifactFeedError.integrity("\(label): runtime_format \(runtimeFormat) requires source_ref.kind \(row.sourceRefKind)")
        }
        let sourceRef: SourceRef
        if kind == "huggingface_revision" {
            try exactKeys(rawRef, allowed: ["kind", "repo_id", "revision"], required: ["kind", "repo_id", "revision"], label: "\(label) source_ref")
            let repoID = try string(rawRef, "repo_id", label: "\(label) source_ref")
            let revision = try string(rawRef, "revision", label: "\(label) source_ref")
            guard matches(repoIDPattern, repoID) else {
                throw ArtifactFeedError.integrity("\(label): source_ref.repo_id must be a HuggingFace repo id")
            }
            guard matches(hex40Pattern, revision) else {
                throw ArtifactFeedError.integrity("\(label): source_ref.revision must be an immutable lowercase 40-hex commit")
            }
            sourceRef = SourceRef(kind: kind, repoID: repoID, revision: revision, libraryTag: nil, digest: nil)
        } else {
            try exactKeys(rawRef, allowed: ["kind", "library_tag", "digest"], required: ["kind", "library_tag", "digest"], label: "\(label) source_ref")
            let libraryTag = try string(rawRef, "library_tag", label: "\(label) source_ref")
            let digest = try string(rawRef, "digest", label: "\(label) source_ref")
            guard !libraryTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArtifactFeedError.integrity("\(label): source_ref.library_tag required")
            }
            guard digest == "sha256:" + hash else {
                throw ArtifactFeedError.integrity("\(label): gguf source_ref.digest must equal 'sha256:' + hash")
            }
            sourceRef = SourceRef(kind: kind, repoID: nil, revision: nil, libraryTag: libraryTag, digest: digest)
        }
        return Artifact(
            runtimeFormat: runtimeFormat, quantization: quantization, sourceRef: sourceRef, hashAlgorithm: hashAlgorithm,
            hash: hash, sizeBytes: Int(rawSize.int64Value), minRAMGB: rawRAM.doubleValue, allowedRuntimeSources: sources,
            verificationStatus: status, verifiedAt: verifiedAt, notes: notes
        )
    }

    static func rawGeneratedAt(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["generated_at"] as? String
    }

    private static func realDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    /// §3.7.2 / §3.7.4 / §3.7.5 release binding against the candidate catalog
    /// SELECTED for the same release: the authenticated signer of both feeds
    /// must be one key (a valid signature by a second concurrently trusted key
    /// fails), the release stamp and the served candidate bytes must match, and
    /// every listed/recommendable row must have a verified primary artifact
    /// identical in identity to the row.
    /// - Parameters:
    ///   - manifestSignerKeyID: the `release.json`-bound signer of the artifact
    ///     feed when the caller knows it (the compiled-in snapshot bakes it from
    ///     the release that produced it). When known it must equal both
    ///     authenticated signers, so the baked path is a genuine three-way
    ///     identity check, not `baked == baked`. For a live fetch the CLI has no
    ///     authenticated copy of that release's manifest; the release host
    ///     (`verify`, the acceptance signer, the live release gate) and the
    ///     coordinator (`LoadAutotuneFeeds`) enforce the manifest binding
    ///     before those bytes are ever served, and the CLI enforces equality of
    ///     the two authenticated signers it does have.
    func bind(
        to catalog: CandidateCatalog,
        candidateBytes: Data,
        candidateSignerKeyID: String?,
        artifactSignerKeyID: String?,
        manifestSignerKeyID: String? = nil
    ) throws {
        guard let candidateSignerKeyID, let artifactSignerKeyID, candidateSignerKeyID == artifactSignerKeyID else {
            throw ArtifactFeedError.integrity("artifact feed signer \(artifactSignerKeyID ?? "nil") is not the candidate catalog signer \(candidateSignerKeyID ?? "nil")")
        }
        if let manifestSignerKeyID, manifestSignerKeyID != artifactSignerKeyID {
            throw ArtifactFeedError.integrity("artifact feed signer \(artifactSignerKeyID) is not the release-manifest-bound signer \(manifestSignerKeyID)")
        }
        guard version == catalog.version else {
            throw ArtifactFeedError.releaseMismatch("artifact feed version \(version) != candidate catalog version \(catalog.version)")
        }
        guard generatedAt == catalog.generatedAt, generatedAtRaw == Self.rawGeneratedAt(in: candidateBytes) else {
            throw ArtifactFeedError.releaseMismatch("artifact feed generated_at differs from the candidate catalog's exact stamp")
        }
        guard policyVersion == catalog.policyVersion else {
            throw ArtifactFeedError.releaseMismatch("artifact feed policy_version differs from the candidate catalog")
        }
        let digest = Data(SHA256.hash(data: candidateBytes)).map { String(format: "%02x", $0) }.joined()
        guard candidateCatalogSHA256 == digest else {
            throw ArtifactFeedError.releaseMismatch("artifact feed candidate_catalog_sha256 does not match the selected candidate catalog bytes")
        }
        for key in models.keys.sorted() where catalog.rows[key] == nil {
            throw ArtifactFeedError.integrity("artifact feed model \(key) is absent from the candidate catalog")
        }
        for key in catalog.rows.keys.sorted() {
            let row = catalog.rows[key]!
            if row.runtimeStatus == "blocked" { continue }
            guard let model = models[key] else {
                if row.runtimeStatus == "candidate" { continue }
                throw ArtifactFeedError.integrity("\(row.runtimeStatus) candidate row \(key) has no artifact-feed model entry")
            }
            let primary = model.primary
            guard primary.hash == row.modelSHA256 else {
                throw ArtifactFeedError.integrity("model \(key): primary artifact hash does not equal the candidate model_sha256")
            }
            guard primary.sourceRef.repoID == row.modelID else {
                throw ArtifactFeedError.integrity("model \(key): primary artifact repo_id does not equal the candidate model_id")
            }
            guard primary.sourceRef.revision == row.modelRevision else {
                throw ArtifactFeedError.integrity("model \(key): primary artifact revision does not equal the candidate model_revision")
            }
            guard primary.minRAMGB == Double(row.minRAMGB) else {
                throw ArtifactFeedError.integrity("model \(key): primary artifact min_ram_gb does not equal the candidate min_ram_gb")
            }
            guard row.runtimeStatus == "candidate" || primary.verificationStatus == "verified" else {
                throw ArtifactFeedError.integrity("\(row.runtimeStatus) candidate row \(key) requires a verified primary artifact")
            }
            guard row.runtimeStatus != "recommendable" || model.rateClass != nil else {
                throw ArtifactFeedError.integrity("recommendable candidate row \(key) must declare a rate_class")
            }
        }
    }

    /// One served-model reference an artifact of this feed answers to
    /// (HuggingFace repo id for MLX snapshots, library tag for GGUF), with the
    /// constraints §3.7.4 puts on matching: only a `verified` artifact may
    /// satisfy a catalog match, a `blocked` one never may, and the runtime
    /// source that reports the reference must be one the artifact allows.
    struct ServedReference: Equatable, Sendable {
        var reference: String
        var catalogKey: String
        var verificationStatus: String
        var allowedRuntimeSources: [String]

        func matches(_ normalizedReference: String, runtimeSource: String) -> Bool {
            verificationStatus == "verified"
                && allowedRuntimeSources.contains(runtimeSource)
                && BYOMCandidateIdentity.normalizedServedModelRef(reference) == normalizedReference
        }
    }

    /// Every served reference of this feed. Identity only — never admission.
    func servedReferences() -> [ServedReference] {
        var out: [ServedReference] = []
        for key in models.keys.sorted() {
            for artifactID in models[key]!.artifacts.keys.sorted() {
                let artifact = models[key]!.artifacts[artifactID]!
                for reference in [artifact.sourceRef.repoID, artifact.sourceRef.libraryTag].compactMap({ $0 }) {
                    out.append(ServedReference(
                        reference: reference, catalogKey: key,
                        verificationStatus: artifact.verificationStatus,
                        allowedRuntimeSources: artifact.allowedRuntimeSources
                    ))
                }
            }
        }
        return out
    }
}

extension AutotuneStaticInputs {
    static func decodeArtifactFeed(_ data: Data) throws -> ArtifactFeed {
        try ArtifactFeed.decode(data)
    }

    /// The exact signed bytes of the compiled-in artifact feed (base64 in the
    /// generated source so no string escape can alter them), or nil for a
    /// rate-card-bound release.
    static var bakedArtifactFeedBytes: Data? {
        bakedArtifactFeedBase64.flatMap { Data(base64Encoded: $0) }
    }

    /// The artifact feed the compiled-in snapshot carries, bound to the
    /// compiled-in candidate catalog with the three-way signer identity
    /// (manifest-bound artifact signer, candidate signer, artifact signer), or
    /// nil for a rate-card-bound release.
    static func bakedBoundArtifactFeed() -> ArtifactFeed? {
        guard let bytes = bakedArtifactFeedBytes else { return nil }
        let candidateBytes = Data(bakedCandidateCatalogJSON.utf8)
        guard let feed = try? decodeArtifactFeed(bytes),
              let catalog = try? decodeSignedStaticCandidateCatalog(candidateBytes),
              (try? feed.bind(
                  to: catalog,
                  candidateBytes: candidateBytes,
                  candidateSignerKeyID: bakedCatalogSignerKeyID,
                  artifactSignerKeyID: bakedArtifactFeedSignerKeyID,
                  manifestSignerKeyID: bakedArtifactFeedSignerKeyID
              )) != nil
        else {
            return nil
        }
        return feed
    }

    /// Load the §3.7 artifact feed for the release whose candidate catalog was
    /// just selected. `value` is the bound, usable feed, or nil whenever any
    /// artifact-derived capability must fail closed (§3.7.6 rule 5) — or when
    /// the release carries no artifact feed at all (rule 6, no warnings).
    func loadArtifactFeed(
        candidate: AutotuneStaticSelection<CandidateCatalog>,
        bakedArtifactFeed: Data? = AutotuneStaticInputs.bakedArtifactFeedBytes,
        bakedArtifactFeedSignerKeyID: String? = AutotuneStaticInputs.bakedArtifactFeedSignerKeyID
    ) async -> AutotuneStaticSelection<ArtifactFeed?> {
        guard let bakedBytes = bakedArtifactFeed else {
            return AutotuneStaticSelection(value: nil, selectedBytes: Data(), warnings: [], usedFallback: false, signerKeyID: nil)
        }
        let selection = await loadSignedStatic(
            name: "catalog-artifacts",
            bakedBytes: bakedBytes,
            fallbackWarning: .catalogArtifactFeedFallbackUsed,
            integrityWarning: .catalogArtifactFeedIntegrityFailure,
            updateWarning: .catalogArtifactFeedUpdateRequired,
            staleWarning: .catalogArtifactFeedStale
        ) { try Self.decodeArtifactFeed($0) }
        var warnings = selection.warnings
        do {
            // The compiled-in bytes carry their release-manifest-bound signer;
            // when they are what was selected, enforce the three-way identity.
            try selection.value.bind(
                to: candidate.value,
                candidateBytes: candidate.selectedBytes,
                candidateSignerKeyID: candidate.signerKeyID,
                artifactSignerKeyID: selection.usedFallback ? bakedArtifactFeedSignerKeyID : selection.signerKeyID,
                manifestSignerKeyID: selection.usedFallback ? bakedArtifactFeedSignerKeyID : nil
            )
        } catch ArtifactFeedError.integrity {
            warnings.insert(.catalogArtifactFeedIntegrityFailure)
        } catch {
            warnings.insert(.catalogArtifactFeedUpdateRequired)
        }
        let usable = warnings.isDisjoint(with: [
            .catalogArtifactFeedIntegrityFailure, .catalogArtifactFeedUpdateRequired, .catalogArtifactFeedStale,
        ])
        return AutotuneStaticSelection(
            value: usable ? selection.value : nil,
            selectedBytes: selection.selectedBytes,
            warnings: warnings,
            usedFallback: selection.usedFallback,
            signerKeyID: selection.usedFallback ? bakedArtifactFeedSignerKeyID : selection.signerKeyID
        )
    }
}
