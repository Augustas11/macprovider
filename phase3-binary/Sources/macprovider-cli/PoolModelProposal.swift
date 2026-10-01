import Foundation

/// #1816 `models propose`: the closed `pool_model_proposal.v1` bundle a
/// provider hands a Trusted Pool creator for one locally served model that is
/// not in the signed catalog.
///
/// `model_entry` carries the pool model entry fields under the names the
/// creator's signed entry uses, so the creator copies them, fills the creator
/// fields (`license`, `paid_serving_attested`, `pricing` when the provider
/// suggested none), and signs. The CLI computes `artifact_hash` from the file
/// bytes; it is never a runtime-reported tag, path, or name. Nothing in the
/// bundle is authority: the creator's signature makes the entry, and the
/// coordinator binds the offer only when the entry's artifact pair matches.
struct PoolModelProposalWire: Encodable, Equatable, Sendable {
    static let schemaID = "pool_model_proposal.v1"

    struct Pricing: Encodable, Equatable, Sendable {
        let promptRatePerMtok: Int64
        let promptCacheHitRatePerMtok: Int64
        let completionRatePerMtok: Int64

        enum CodingKeys: String, CodingKey {
            case promptRatePerMtok = "prompt_rate_per_mtok"
            case promptCacheHitRatePerMtok = "prompt_cache_hit_rate_per_mtok"
            case completionRatePerMtok = "completion_rate_per_mtok"
        }
    }

    struct ModelEntry: Encodable, Equatable, Sendable {
        let poolModelID: String
        let artifactHashAlgorithm: String
        let artifactHash: String
        let allowedRuntimeSources: [String]
        /// Creator-owned: an SPDX identifier or `LicenseRef-*`; always null here.
        let license: String?
        /// Creator-owned: must be `true` in the signed entry; always null here.
        let paidServingAttested: Bool?
        let pricing: Pricing?
        let disclosureClass: String
        let maxContextTokens: Int?

        enum CodingKeys: String, CodingKey {
            case poolModelID = "pool_model_id"
            case artifactHashAlgorithm = "artifact_hash_algorithm"
            case artifactHash = "artifact_hash"
            case allowedRuntimeSources = "allowed_runtime_sources"
            case license
            case paidServingAttested = "paid_serving_attested"
            case pricing
            case disclosureClass = "disclosure_class"
            case maxContextTokens = "max_context_tokens"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(poolModelID, forKey: .poolModelID)
            try container.encode(artifactHashAlgorithm, forKey: .artifactHashAlgorithm)
            try container.encode(artifactHash, forKey: .artifactHash)
            try container.encode(allowedRuntimeSources, forKey: .allowedRuntimeSources)
            try encodeNullable(license, forKey: .license, into: &container)
            try encodeNullable(paidServingAttested, forKey: .paidServingAttested, into: &container)
            try encodeNullable(pricing, forKey: .pricing, into: &container)
            try container.encode(disclosureClass, forKey: .disclosureClass)
            try encodeNullable(maxContextTokens, forKey: .maxContextTokens, into: &container)
        }
    }

    struct Evidence: Encodable, Equatable, Sendable {
        /// The operator's evaluation digest (`--evaluation-digest-sha256`), or null.
        let evaluationDigestSHA256: String?
        /// The coordinator records the known-answer probe evidence before it
        /// binds; a provider-side bundle never carries it, so this is null.
        let knownAnswerProbeEvidenceSHA256: String?

        enum CodingKeys: String, CodingKey {
            case evaluationDigestSHA256 = "evaluation_digest_sha256"
            case knownAnswerProbeEvidenceSHA256 = "known_answer_probe_evidence_sha256"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try encodeNullable(evaluationDigestSHA256, forKey: .evaluationDigestSHA256, into: &container)
            try encodeNullable(knownAnswerProbeEvidenceSHA256, forKey: .knownAnswerProbeEvidenceSHA256, into: &container)
        }
    }

    let schema: String
    let generatedAt: String
    let cliVersion: String
    let poolID: String
    let providerID: String?
    let candidateID: String
    let servedModelRef: String
    let runtimeSource: String
    let displayName: String
    let catalogModelKey: String?
    let modelEntry: ModelEntry
    let creatorRequirements: [String]
    let evidence: Evidence
    let offerStatus: BYOMAdmissionStatusWire?
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case cliVersion = "cli_version"
        case poolID = "pool_id"
        case providerID = "provider_id"
        case candidateID = "candidate_id"
        case servedModelRef = "served_model_ref"
        case runtimeSource = "runtime_source"
        case displayName = "display_name"
        case catalogModelKey = "catalog_model_key"
        case modelEntry = "model_entry"
        case creatorRequirements = "creator_requirements"
        case evidence
        case offerStatus = "offer_status"
        case warnings
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(cliVersion, forKey: .cliVersion)
        try container.encode(poolID, forKey: .poolID)
        try encodeNullable(providerID, forKey: .providerID, into: &container)
        try container.encode(candidateID, forKey: .candidateID)
        try container.encode(servedModelRef, forKey: .servedModelRef)
        try container.encode(runtimeSource, forKey: .runtimeSource)
        try container.encode(displayName, forKey: .displayName)
        try encodeNullable(catalogModelKey, forKey: .catalogModelKey, into: &container)
        try container.encode(modelEntry, forKey: .modelEntry)
        try container.encode(creatorRequirements, forKey: .creatorRequirements)
        try container.encode(evidence, forKey: .evidence)
        try encodeNullable(offerStatus, forKey: .offerStatus, into: &container)
        try container.encode(warnings, forKey: .warnings)
    }

    /// Closed `creator_requirements` codes, always in this order when present.
    enum Requirement: String, CaseIterable {
        case licenseRequired = "license_spdx_or_licenseref_required"
        case paidServingAttestedRequired = "paid_serving_attested_must_be_true"
        case pricingRequired = "pricing_required_within_pool_model_bounds"
        case pricingWithinBounds = "pricing_must_be_within_pool_model_bounds"
        case maxContextRequired = "max_context_tokens_required"
        case runtimeAllowlisted = "runtime_source_in_runtime_allowlist"
        case memberAttestation = "attested_member_required_for_non_creator_account"
    }

    /// Closed `warnings` codes.
    enum Warning: String {
        case catalogMatchExists = "candidate_catalog_matched"
        case offerNotSubmitted = "offer_not_submitted"
        case maxContextUnknown = "max_context_unknown"
    }
}

private func encodeNullable<T: Encodable, K: CodingKey>(
    _ value: T?,
    forKey key: K,
    into container: inout KeyedEncodingContainer<K>
) throws {
    if let value {
        try container.encode(value, forKey: key)
    } else {
        try container.encodeNil(forKey: key)
    }
}

enum PoolModelProposalError: Error, Equatable, CustomStringConvertible {
    case invalidPoolID
    case invalidSlug
    case invalidPricing
    case runtimeNotPoolEligible(String)
    case artifactHashUnavailable(String)

    var description: String {
        switch self {
        case .invalidPoolID:
            return "--pool must be the 22-character pool id (letters, digits, '_' or '-')"
        case .invalidSlug:
            return "--slug must match [a-z0-9][a-z0-9-]{0,62}"
        case .invalidPricing:
            return "pricing needs all three of --prompt-rate-per-mtok, --prompt-cache-hit-rate-per-mtok and --completion-rate-per-mtok, each >= 0, with the cache-hit rate no higher than the prompt rate"
        case .runtimeNotPoolEligible(let runtime):
            return "\(runtime) has no exact artifact identity a pool entry can name; pool models are served by llama.cpp, LM Studio, Ollama, mlx_lm, oMLX, or native MLX"
        case .artifactHashUnavailable(let runtime):
            return "the CLI could not hash the served \(runtime) artifact from its bytes; for llama.cpp pass --llamacpp-model-root or --llamacpp-model-path, for native MLX set model_artifact_path to the served snapshot directory"
        }
    }
}

enum PoolModelProposalBuilder {
    /// The runtimes a pool entry may name, keyed to the one artifact algorithm
    /// each serves (SPEC-042-R015 field 4, with native `mlx_cache` for
    /// snapshot-manifest entries per #1816).
    static let algorithmByRuntime: [String: String] = [
        "llamacpp_loopback": ModelArtifactIdentity.ggufFileV1,
        "lmstudio_loopback": ModelArtifactIdentity.ggufFileV1,
        "ollama_loopback": ModelArtifactIdentity.ggufFileV1,
        "mlx_cache": ModelArtifactIdentity.snapshotManifestV1,
        "mlxlm_loopback": ModelArtifactIdentity.snapshotManifestV1,
        "omlx_loopback": ModelArtifactIdentity.snapshotManifestV1,
    ]
    static let maxContextTokensBound = 1 ... 1_048_576
    static let slugPattern = #"^[a-z0-9][a-z0-9-]{0,62}$"#

    static func validatePoolID(_ poolID: String) throws -> String {
        let trimmed = poolID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: BYOMAdmissionStatusWire.poolIDPattern, options: .regularExpression) != nil else {
            throw PoolModelProposalError.invalidPoolID
        }
        return trimmed
    }

    /// A deterministic slug from the served model's name: lowercase ASCII
    /// letters and digits, every other run collapsed to one '-', at most 63
    /// characters, never empty.
    static func suggestedSlug(for candidate: BYOMDiscoveryWire.Candidate) -> String {
        let fromName = slug(from: candidate.displayName)
        if !fromName.isEmpty { return fromName }
        let fromRef = slug(from: candidate.servedModelRef)
        return fromRef.isEmpty ? "model" : fromRef
    }

    private static func slug(from source: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in source.lowercased().unicodeScalars {
            if (0x61...0x7a).contains(scalar.value) || (0x30...0x39).contains(scalar.value) {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        slug = String(slug.prefix(63))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    static func pricing(prompt: Int64?, cacheHit: Int64?, completion: Int64?) throws -> PoolModelProposalWire.Pricing? {
        switch (prompt, cacheHit, completion) {
        case (nil, nil, nil):
            return nil
        case let (prompt?, cacheHit?, completion?):
            guard prompt >= 0, completion >= 0, cacheHit >= 0, cacheHit <= prompt else {
                throw PoolModelProposalError.invalidPricing
            }
            return PoolModelProposalWire.Pricing(
                promptRatePerMtok: prompt,
                promptCacheHitRatePerMtok: cacheHit,
                completionRatePerMtok: completion
            )
        default:
            throw PoolModelProposalError.invalidPricing
        }
    }

    static func makeBundle(
        poolID: String,
        slug: String?,
        providerID: String?,
        candidate: BYOMDiscoveryWire.Candidate,
        artifactHashes: [String: String],
        pricing: PoolModelProposalWire.Pricing?,
        evaluationDigestSHA256: String?,
        offerStatus: BYOMAdmissionStatusWire?,
        generatedAt: String = ModelSwitchingWireCodec.timestamp(),
        cliVersion: String = CoordinatorClient.binaryVersion
    ) throws -> PoolModelProposalWire {
        let poolID = try validatePoolID(poolID)
        guard let algorithm = algorithmByRuntime[candidate.runtimeSource] else {
            throw PoolModelProposalError.runtimeNotPoolEligible(candidate.runtimeSource)
        }
        guard let hash = artifactHashes[algorithm],
              hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw PoolModelProposalError.artifactHashUnavailable(candidate.runtimeSource)
        }
        let resolvedSlug = slug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? suggestedSlug(for: candidate)
        guard resolvedSlug.range(of: slugPattern, options: .regularExpression) != nil else {
            throw PoolModelProposalError.invalidSlug
        }
        let poolModelID = "pool/\(poolID)/\(resolvedSlug)"
        let context = candidate.contextWindowTokens ?? candidate.capabilities.maxContextTokens
        let maxContext = context.flatMap { maxContextTokensBound.contains($0) ? $0 : nil }

        var requirements: [PoolModelProposalWire.Requirement] = [.licenseRequired, .paidServingAttestedRequired]
        requirements.append(pricing == nil ? .pricingRequired : .pricingWithinBounds)
        if maxContext == nil { requirements.append(.maxContextRequired) }
        requirements.append(contentsOf: [.runtimeAllowlisted, .memberAttestation])

        var warnings: Set<String> = []
        if candidate.catalogModelKey != nil { warnings.insert(PoolModelProposalWire.Warning.catalogMatchExists.rawValue) }
        if offerStatus == nil { warnings.insert(PoolModelProposalWire.Warning.offerNotSubmitted.rawValue) }
        if maxContext == nil { warnings.insert(PoolModelProposalWire.Warning.maxContextUnknown.rawValue) }

        return PoolModelProposalWire(
            schema: PoolModelProposalWire.schemaID,
            generatedAt: generatedAt,
            cliVersion: cliVersion,
            poolID: poolID,
            providerID: providerID,
            candidateID: candidate.candidateID,
            servedModelRef: candidate.servedModelRef,
            runtimeSource: candidate.runtimeSource,
            displayName: candidate.displayName,
            catalogModelKey: candidate.catalogModelKey,
            modelEntry: PoolModelProposalWire.ModelEntry(
                poolModelID: poolModelID,
                artifactHashAlgorithm: algorithm,
                artifactHash: hash,
                allowedRuntimeSources: [candidate.runtimeSource],
                license: nil,
                paidServingAttested: nil,
                pricing: pricing,
                disclosureClass: "pool_attested_unverified",
                maxContextTokens: maxContext
            ),
            creatorRequirements: requirements.map(\.rawValue),
            evidence: PoolModelProposalWire.Evidence(
                evaluationDigestSHA256: evaluationDigestSHA256,
                knownAnswerProbeEvidenceSHA256: nil
            ),
            offerStatus: offerStatus,
            warnings: warnings.sorted()
        )
    }
}
