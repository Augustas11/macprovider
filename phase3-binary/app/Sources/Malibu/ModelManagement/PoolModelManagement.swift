import Foundation

// #1816: Trusted Pool model proposals, pool-scoped admission readback,
// BYOM withdrawal, and the local-runtime adapter settings Malibu passes to
// the provider CLI's BYOM commands.

/// SPEC-047-R011 pool-manifest binding as `models admission status --json`
/// reports it. A closed object; every value is checked before Malibu shows it.
struct MalibuBYOMPoolBinding: Decodable, Equatable, Sendable {
    struct Pricing: Decodable, Equatable, Sendable {
        let promptRatePerMtok: Int64
        let promptCacheHitRatePerMtok: Int64
        let completionRatePerMtok: Int64

        enum CodingKeys: String, CodingKey, CaseIterable {
            case promptRatePerMtok = "prompt_rate_per_mtok"
            case promptCacheHitRatePerMtok = "prompt_cache_hit_rate_per_mtok"
            case completionRatePerMtok = "completion_rate_per_mtok"
        }

        init(from decoder: Decoder) throws {
            try poolRejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.stringValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            promptRatePerMtok = try container.decode(Int64.self, forKey: .promptRatePerMtok)
            promptCacheHitRatePerMtok = try container.decode(Int64.self, forKey: .promptCacheHitRatePerMtok)
            completionRatePerMtok = try container.decode(Int64.self, forKey: .completionRatePerMtok)
        }
    }

    let poolID: String
    let poolModelID: String
    let manifestVersion: UInt64
    let coreDigest: String
    let artifactHashAlgorithm: String
    let artifactHash: String
    let runtimeSource: String
    let pricing: Pricing
    let disclosureClass: String
    let maxContextTokens: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case poolID = "pool_id"
        case poolModelID = "pool_model_id"
        case manifestVersion = "manifest_version"
        case coreDigest = "core_digest"
        case artifactHashAlgorithm = "artifact_hash_algorithm"
        case artifactHash = "artifact_hash"
        case runtimeSource = "runtime_source"
        case pricing
        case disclosureClass = "disclosure_class"
        case maxContextTokens = "max_context_tokens"
    }

    init(from decoder: Decoder) throws {
        try poolRejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        poolID = try container.decode(String.self, forKey: .poolID)
        poolModelID = try container.decode(String.self, forKey: .poolModelID)
        manifestVersion = try container.decode(UInt64.self, forKey: .manifestVersion)
        coreDigest = try container.decode(String.self, forKey: .coreDigest)
        artifactHashAlgorithm = try container.decode(String.self, forKey: .artifactHashAlgorithm)
        artifactHash = try container.decode(String.self, forKey: .artifactHash)
        runtimeSource = try container.decode(String.self, forKey: .runtimeSource)
        pricing = try container.decode(Pricing.self, forKey: .pricing)
        disclosureClass = try container.decode(String.self, forKey: .disclosureClass)
        maxContextTokens = try container.decode(Int.self, forKey: .maxContextTokens)
    }

    static let poolIDPattern = "^[A-Za-z0-9_-]{22}$"
    static let poolModelIDPattern = "^pool/[A-Za-z0-9_-]{22}/[a-z0-9][a-z0-9-]{0,62}$"
    private static let runtimesByAlgorithm: [String: Set<String>] = [
        "macprovider.gguf-file.v1": ["llamacpp_loopback", "lmstudio_loopback", "ollama_loopback"],
        "macprovider.snapshot-manifest.v1": ["mlx_cache", "mlxlm_loopback", "omlx_loopback"],
    ]

    var isValid: Bool {
        poolID.range(of: Self.poolIDPattern, options: .regularExpression) != nil
            && poolModelID.utf8.count <= 91
            && poolModelID.range(of: Self.poolModelIDPattern, options: .regularExpression) != nil
            && poolModelID.split(separator: "/", omittingEmptySubsequences: false).dropFirst().first.map(String.init) == poolID
            && manifestVersion >= 1
            && Self.isLowercaseHex64(coreDigest)
            && Self.isLowercaseHex64(artifactHash)
            && Self.runtimesByAlgorithm[artifactHashAlgorithm]?.contains(runtimeSource) == true
            && pricing.promptRatePerMtok >= 0
            && pricing.completionRatePerMtok >= 0
            && pricing.promptCacheHitRatePerMtok >= 0
            && pricing.promptCacheHitRatePerMtok <= pricing.promptRatePerMtok
            && disclosureClass == "pool_attested_unverified"
            && (1...1_048_576).contains(maxContextTokens)
    }

    static func isLowercaseHex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// `models admission withdraw --json` (`model_admission_withdraw.v1`).
struct MalibuBYOMWithdrawDocument: Decodable, Equatable, Sendable {
    let schema: String
    let generatedAt: String
    let cliVersion: String
    let providerID: String
    let candidateID: String
    let servedModelRef: String
    let catalogModelKey: String?
    let idempotencyKey: String
    let reasonCode: String
    let previousAdmissionState: String
    let coordinatorEventID: String
    let acceptedAt: String
    let resultingAdmissionState: String
    let providerGuidance: MalibuModelCatalogEconomicsDocument.ProviderGuidance
    let warnings: [String]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema
        case generatedAt = "generated_at"
        case cliVersion = "cli_version"
        case providerID = "provider_id"
        case candidateID = "candidate_id"
        case servedModelRef = "served_model_ref"
        case catalogModelKey = "catalog_model_key"
        case idempotencyKey = "idempotency_key"
        case reasonCode = "reason_code"
        case previousAdmissionState = "previous_admission_state"
        case coordinatorEventID = "coordinator_event_id"
        case acceptedAt = "accepted_at"
        case resultingAdmissionState = "resulting_admission_state"
        case providerGuidance = "provider_guidance"
        case warnings
    }

    init(from decoder: Decoder) throws {
        try poolRejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        cliVersion = try container.decode(String.self, forKey: .cliVersion)
        providerID = try container.decode(String.self, forKey: .providerID)
        candidateID = try container.decode(String.self, forKey: .candidateID)
        servedModelRef = try container.decode(String.self, forKey: .servedModelRef)
        guard container.contains(.catalogModelKey) else {
            throw DecodingError.keyNotFound(CodingKeys.catalogModelKey, DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "required nullable field missing"
            ))
        }
        catalogModelKey = try container.decodeIfPresent(String.self, forKey: .catalogModelKey)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        reasonCode = try container.decode(String.self, forKey: .reasonCode)
        previousAdmissionState = try container.decode(String.self, forKey: .previousAdmissionState)
        coordinatorEventID = try container.decode(String.self, forKey: .coordinatorEventID)
        acceptedAt = try container.decode(String.self, forKey: .acceptedAt)
        resultingAdmissionState = try container.decode(String.self, forKey: .resultingAdmissionState)
        providerGuidance = try container.decode(MalibuModelCatalogEconomicsDocument.ProviderGuidance.self, forKey: .providerGuidance)
        warnings = try container.decode([String].self, forKey: .warnings)
    }

    func validated(expectedCandidateID: String) throws {
        guard schema == "model_admission_withdraw.v1",
              candidateID == expectedCandidateID,
              resultingAdmissionState == "withdrawn",
              reasonCode == "provider_requested",
              !coordinatorEventID.isEmpty,
              providerGuidance.earningPathClass == "no_earning_path_in_v0_1",
              providerGuidance.nextAction == "submit_offer" else {
            throw ModelManagementError.invalidCatalog
        }
    }
}

/// `models propose --json` (`pool_model_proposal.v1`). Malibu checks the
/// closed shape and shows or exports the exact bytes the CLI printed; the
/// creator, not Malibu, turns it into a signed pool entry.
struct MalibuPoolModelProposalDocument: Decodable, Equatable, Sendable {
    struct ModelEntry: Decodable, Equatable, Sendable {
        let poolModelID: String
        let artifactHashAlgorithm: String
        let artifactHash: String
        let allowedRuntimeSources: [String]
        let disclosureClass: String

        enum CodingKeys: String, CodingKey, CaseIterable {
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

        init(from decoder: Decoder) throws {
            try poolRejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.stringValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            for key in [CodingKeys.license, .paidServingAttested, .pricing, .maxContextTokens] where !container.contains(key) {
                throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: container.codingPath, debugDescription: "required nullable field missing"))
            }
            poolModelID = try container.decode(String.self, forKey: .poolModelID)
            artifactHashAlgorithm = try container.decode(String.self, forKey: .artifactHashAlgorithm)
            artifactHash = try container.decode(String.self, forKey: .artifactHash)
            allowedRuntimeSources = try container.decode([String].self, forKey: .allowedRuntimeSources)
            disclosureClass = try container.decode(String.self, forKey: .disclosureClass)
        }
    }

    let schema: String
    let poolID: String
    let candidateID: String
    let modelEntry: ModelEntry
    let creatorRequirements: [String]
    let warnings: [String]

    enum CodingKeys: String, CodingKey, CaseIterable {
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

    init(from decoder: Decoder) throws {
        try poolRejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for key in CodingKeys.allCases where !container.contains(key) {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: container.codingPath, debugDescription: "closed bundle key missing"))
        }
        schema = try container.decode(String.self, forKey: .schema)
        poolID = try container.decode(String.self, forKey: .poolID)
        candidateID = try container.decode(String.self, forKey: .candidateID)
        modelEntry = try container.decode(ModelEntry.self, forKey: .modelEntry)
        creatorRequirements = try container.decode([String].self, forKey: .creatorRequirements)
        warnings = try container.decode([String].self, forKey: .warnings)
    }

    func validated(expectedCandidateID: String, expectedPoolID: String) throws {
        guard schema == "pool_model_proposal.v1",
              candidateID == expectedCandidateID,
              poolID == expectedPoolID,
              modelEntry.poolModelID.hasPrefix("pool/\(expectedPoolID)/"),
              modelEntry.poolModelID.range(of: MalibuBYOMPoolBinding.poolModelIDPattern, options: .regularExpression) != nil,
              MalibuBYOMPoolBinding.isLowercaseHex64(modelEntry.artifactHash),
              ["macprovider.gguf-file.v1", "macprovider.snapshot-manifest.v1"].contains(modelEntry.artifactHashAlgorithm),
              modelEntry.allowedRuntimeSources.count == 1,
              modelEntry.disclosureClass == "pool_attested_unverified" else {
            throw ModelManagementError.invalidCatalog
        }
    }
}

/// The proposal Malibu shows after `models propose` succeeds.
struct MalibuPoolProposalResult: Equatable, Identifiable, Sendable {
    var id: String { candidateID + "|" + poolID }
    let candidateID: String
    let poolID: String
    let poolModelID: String
    /// The CLI's exact JSON output, for copy and export.
    let bundleJSON: String
}

/// Local runtime adapter settings passed to the provider CLI's BYOM
/// commands. Empty fields pass nothing, so the CLI keeps its defaults.
struct MalibuBYOMAdapterSettings: Codable, Equatable, Sendable {
    var llamacppModelRoot: String = ""
    var llamacppModelPath: String = ""
    var llamacppOrigin: String = ""
    var lmstudioOrigin: String = ""
    var openaiCompatibleOrigin: String = ""

    static let defaultsKey = "malibu.model-management.byom-adapters"

    enum ValidationError: Error, Equatable {
        case pathNotAbsolute(String)
        case originNotLoopback(String)
    }

    /// The CLI enforces the same rules; validating here keeps a bad value
    /// from silently failing every BYOM command.
    func validated() throws -> MalibuBYOMAdapterSettings {
        var copy = self
        copy.llamacppModelRoot = llamacppModelRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.llamacppModelPath = llamacppModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.llamacppOrigin = llamacppOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.lmstudioOrigin = lmstudioOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.openaiCompatibleOrigin = openaiCompatibleOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        for path in [copy.llamacppModelRoot, copy.llamacppModelPath] where !path.isEmpty {
            guard path.hasPrefix("/"), !path.contains("\0") else { throw ValidationError.pathNotAbsolute(path) }
        }
        for origin in [copy.llamacppOrigin, copy.lmstudioOrigin, copy.openaiCompatibleOrigin] where !origin.isEmpty {
            guard Self.isLoopbackHTTPOrigin(origin) else { throw ValidationError.originNotLoopback(origin) }
        }
        return copy
    }

    var cliArguments: [String] {
        var arguments: [String] = []
        if !llamacppModelRoot.isEmpty { arguments += ["--llamacpp-model-root", llamacppModelRoot] }
        if !llamacppModelPath.isEmpty { arguments += ["--llamacpp-model-path", llamacppModelPath] }
        if !llamacppOrigin.isEmpty { arguments += ["--llamacpp-origin", llamacppOrigin] }
        if !lmstudioOrigin.isEmpty { arguments += ["--lmstudio-origin", lmstudioOrigin] }
        if !openaiCompatibleOrigin.isEmpty { arguments += ["--openai-compatible-origin", openaiCompatibleOrigin] }
        return arguments
    }

    /// `models propose` has no OpenAI-compatible adapter: that runtime has
    /// no artifact identity a pool entry can name.
    var proposeArguments: [String] {
        var copy = self
        copy.openaiCompatibleOrigin = ""
        return copy.cliArguments
    }

    static func isLoopbackHTTPOrigin(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              components.scheme == "http",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port != nil,
              let host = components.host?.lowercased() else {
            return false
        }
        if host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4
            && octets.first == "127"
            && octets.allSatisfy { UInt8($0) != nil }
    }
}

private struct PoolDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func poolRejectUnknownKeys(_ decoder: Decoder, allowed: [String]) throws {
    let container = try decoder.container(keyedBy: PoolDynamicCodingKey.self)
    let allowed = Set(allowed)
    if let extra = container.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath + [extra],
            debugDescription: "unsupported key \(extra.stringValue)"
        ))
    }
}
