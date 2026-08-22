import CryptoKit
import Foundation
import MacProviderCore

/// Strict, privacy-safe JSON contracts used by Malibu's model-management
/// surface. These types intentionally live beside the CLI commands so the
/// command output and the app's decoder have one documented shape.
struct ModelCatalogErrorWire: Codable, Equatable, Sendable {
    let schemaVersion: String
    let command: String
    let code: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case command
        case code
        case message
    }

    init(command: String, code: String, message: String) {
        schemaVersion = "model_catalog_error.v1"
        self.command = command
        self.code = code
        self.message = message
    }
}

struct ModelsListWire: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable {
        let modelID: String
        let displayID: String
        let actionModelID: String
        let state: String
        let weightsPresentLocally: Bool
        let source: String
        let fit: String?
        let estimatedGB: Double?

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case displayID = "display_id"
            case actionModelID = "action_model_id"
            case state
            case weightsPresentLocally = "weights_present_locally"
            case source
            case fit
            case estimatedGB = "estimated_gb"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(modelID, forKey: .modelID)
            try container.encode(displayID, forKey: .displayID)
            try container.encode(actionModelID, forKey: .actionModelID)
            try container.encode(state, forKey: .state)
            try container.encode(weightsPresentLocally, forKey: .weightsPresentLocally)
            try container.encode(source, forKey: .source)
            if let fit {
                try container.encode(fit, forKey: .fit)
            } else {
                try container.encodeNil(forKey: .fit)
            }
            if let estimatedGB {
                try container.encode(estimatedGB, forKey: .estimatedGB)
            } else {
                try container.encodeNil(forKey: .estimatedGB)
            }
        }
    }

    let schemaVersion: String
    let generatedAt: String
    let source: String
    let warmSwapAvailable: Bool
    let currentModelID: String?
    let rows: [Row]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case source
        case warmSwapAvailable = "warm_swap_available"
        case currentModelID = "current_model_id"
        case rows
    }

    init(
        generatedAt: String,
        source: String,
        warmSwapAvailable: Bool,
        currentModelID: String?,
        rows: [Row]
    ) {
        schemaVersion = "models_list.v1"
        self.generatedAt = generatedAt
        self.source = source
        self.warmSwapAvailable = warmSwapAvailable
        self.currentModelID = currentModelID
        self.rows = rows
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(source, forKey: .source)
        try container.encode(warmSwapAvailable, forKey: .warmSwapAvailable)
        if let currentModelID {
            try container.encode(currentModelID, forKey: .currentModelID)
        } else {
            try container.encodeNil(forKey: .currentModelID)
        }
        try container.encode(rows, forKey: .rows)
    }
}

struct ModelsBrowseWire: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable {
        let modelID: String
        let displayID: String
        let actionModelID: String?
        let source: String
        let fit: String
        let estimatedGB: Double?
        let actionable: Bool

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case displayID = "display_id"
            case actionModelID = "action_model_id"
            case source
            case fit
            case estimatedGB = "estimated_gb"
            case actionable
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(modelID, forKey: .modelID)
            try container.encode(displayID, forKey: .displayID)
            try container.encodeNil(forKey: .actionModelID)
            try container.encode(source, forKey: .source)
            try container.encode(fit, forKey: .fit)
            if let estimatedGB {
                try container.encode(estimatedGB, forKey: .estimatedGB)
            } else {
                try container.encodeNil(forKey: .estimatedGB)
            }
            try container.encode(actionable, forKey: .actionable)
        }
    }

    let schemaVersion: String
    let generatedAt: String
    let source: String
    let query: String?
    let limit: Int
    let fitsOnly: Bool
    let maxGB: Int?
    let ramGB: Int
    let rows: [Row]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case source
        case query
        case limit
        case fitsOnly = "fits_only"
        case maxGB = "max_gb"
        case ramGB = "ram_gb"
        case rows
    }

    init(
        generatedAt: String,
        query: String?,
        limit: Int,
        fitsOnly: Bool,
        maxGB: Int?,
        ramGB: Int,
        rows: [Row]
    ) {
        schemaVersion = "models_browse.v1"
        source = "huggingface_mlx_community"
        self.generatedAt = generatedAt
        self.query = query
        self.limit = limit
        self.fitsOnly = fitsOnly
        self.maxGB = maxGB
        self.ramGB = ramGB
        self.rows = rows
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(source, forKey: .source)
        if let query {
            try container.encode(query, forKey: .query)
        } else {
            try container.encodeNil(forKey: .query)
        }
        try container.encode(limit, forKey: .limit)
        try container.encode(fitsOnly, forKey: .fitsOnly)
        if let maxGB {
            try container.encode(maxGB, forKey: .maxGB)
        } else {
            try container.encodeNil(forKey: .maxGB)
        }
        try container.encode(ramGB, forKey: .ramGB)
        try container.encode(rows, forKey: .rows)
    }
}

struct ModelCatalogEconomicsWire: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let cliVersion: String
        let cliBuildCommit: String
        let processLaunchID: String
        let processStartedAt: String
        let projectionProtocolVersion: String
        let rateCardSource: String
        let rateCardDigest: String?
        let rateCardSignatureDigest: String?
        let demandFeedDigest: String?
        let candidateFeedDigest: String?
        let rateCardMaxAgeSeconds: Int

        enum CodingKeys: String, CodingKey {
            case cliVersion = "cli_version"
            case cliBuildCommit = "cli_build_commit"
            case processLaunchID = "process_launch_id"
            case processStartedAt = "process_started_at"
            case projectionProtocolVersion = "projection_protocol_version"
            case rateCardSource = "rate_card_source"
            case rateCardDigest = "rate_card_digest"
            case rateCardSignatureDigest = "rate_card_signature_digest"
            case demandFeedDigest = "demand_feed_digest"
            case candidateFeedDigest = "candidate_feed_digest"
            case rateCardMaxAgeSeconds = "rate_card_max_age_seconds"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cliVersion, forKey: .cliVersion)
            try container.encode(cliBuildCommit, forKey: .cliBuildCommit)
            try container.encode(processLaunchID, forKey: .processLaunchID)
            try container.encode(processStartedAt, forKey: .processStartedAt)
            try container.encode(projectionProtocolVersion, forKey: .projectionProtocolVersion)
            try container.encode(rateCardSource, forKey: .rateCardSource)
            try container.encodeOptionalOrNull(rateCardDigest, forKey: .rateCardDigest)
            try container.encodeOptionalOrNull(rateCardSignatureDigest, forKey: .rateCardSignatureDigest)
            try container.encodeOptionalOrNull(demandFeedDigest, forKey: .demandFeedDigest)
            try container.encodeOptionalOrNull(candidateFeedDigest, forKey: .candidateFeedDigest)
            try container.encode(rateCardMaxAgeSeconds, forKey: .rateCardMaxAgeSeconds)
        }
    }

    struct ActionSet: Codable, Equatable, Sendable {
        let switchAction: Action
        let prepare: Action
        let evaluate: Action
        let adoptRecommendation: Action
        let cleanupStaging: Action

        enum CodingKeys: String, CodingKey {
            case switchAction = "switch"
            case prepare
            case evaluate
            case adoptRecommendation = "adopt_recommendation"
            case cleanupStaging = "cleanup_staging"
        }
    }

    struct Action: Codable, Equatable, Sendable {
        let available: Bool
        let requiresConfirmation: Bool
        let transactionKind: String?
        let transactionID: String?
        let actionTimeoutSeconds: Int?
        let estimatedBytes: Int64?
        let unavailableReason: String?

        enum CodingKeys: String, CodingKey {
            case available
            case requiresConfirmation = "requires_confirmation"
            case transactionKind = "transaction_kind"
            case transactionID = "transaction_id"
            case actionTimeoutSeconds = "action_timeout_seconds"
            case estimatedBytes = "estimated_bytes"
            case unavailableReason = "unavailable_reason"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(available, forKey: .available)
            try container.encode(requiresConfirmation, forKey: .requiresConfirmation)
            try container.encodeOptionalOrNull(transactionKind, forKey: .transactionKind)
            try container.encodeOptionalOrNull(transactionID, forKey: .transactionID)
            try container.encodeOptionalOrNull(actionTimeoutSeconds, forKey: .actionTimeoutSeconds)
            try container.encodeOptionalOrNull(estimatedBytes, forKey: .estimatedBytes)
            try container.encodeOptionalOrNull(unavailableReason, forKey: .unavailableReason)
        }
    }

    struct Row: Codable, Equatable, Sendable {
        let modelKey: String
        let servedModelID: String
        let displayModelID: String
        let actionModelID: String?
        let isCurrent: Bool
        let weightsPresentLocally: Bool
        let runtimeState: String
        let estimatedGB: Double?
        let fit: String
        let disabledReason: String?
        let warningCodes: [String]
        let rateCardVersion: String?
        let rateCardGeneratedAt: String?
        let rateCardKey: String?
        let rateSource: String
        let promptRateUSDPerMillionTokens: Double?
        let completionRateUSDPerMillionTokens: Double?
        let providerShareBPS: Int64?
        let providerPromptPayoutUSDPerMillionTokens: Double?
        let providerCompletionPayoutUSDPerMillionTokens: Double?
        let economicsState: String
        let demandRank: Int?
        let demandWeight: Double?
        let readyProviderCount: Int?
        let supplyDeficitScore: Double?
        let actions: ActionSet

        enum CodingKeys: String, CodingKey {
            case modelKey = "model_key"
            case servedModelID = "served_model_id"
            case displayModelID = "display_model_id"
            case actionModelID = "action_model_id"
            case isCurrent = "is_current"
            case weightsPresentLocally = "weights_present_locally"
            case runtimeState = "runtime_state"
            case estimatedGB = "estimated_gb"
            case fit
            case disabledReason = "disabled_reason"
            case warningCodes = "warning_codes"
            case rateCardVersion = "rate_card_version"
            case rateCardGeneratedAt = "rate_card_generated_at"
            case rateCardKey = "rate_card_key"
            case rateSource = "rate_source"
            case promptRateUSDPerMillionTokens = "prompt_rate_usd_per_million_tokens"
            case completionRateUSDPerMillionTokens = "completion_rate_usd_per_million_tokens"
            case providerShareBPS = "provider_share_bps"
            case providerPromptPayoutUSDPerMillionTokens = "provider_prompt_payout_usd_per_million_tokens"
            case providerCompletionPayoutUSDPerMillionTokens = "provider_completion_payout_usd_per_million_tokens"
            case economicsState = "economics_state"
            case demandRank = "demand_rank"
            case demandWeight = "demand_weight"
            case readyProviderCount = "ready_provider_count"
            case supplyDeficitScore = "supply_deficit_score"
            case actions
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(modelKey, forKey: .modelKey)
            try container.encode(servedModelID, forKey: .servedModelID)
            try container.encode(displayModelID, forKey: .displayModelID)
            try container.encodeOptionalOrNull(actionModelID, forKey: .actionModelID)
            try container.encode(isCurrent, forKey: .isCurrent)
            try container.encode(weightsPresentLocally, forKey: .weightsPresentLocally)
            try container.encode(runtimeState, forKey: .runtimeState)
            try container.encodeOptionalOrNull(estimatedGB, forKey: .estimatedGB)
            try container.encode(fit, forKey: .fit)
            try container.encodeOptionalOrNull(disabledReason, forKey: .disabledReason)
            try container.encode(warningCodes, forKey: .warningCodes)
            try container.encodeOptionalOrNull(rateCardVersion, forKey: .rateCardVersion)
            try container.encodeOptionalOrNull(rateCardGeneratedAt, forKey: .rateCardGeneratedAt)
            try container.encodeOptionalOrNull(rateCardKey, forKey: .rateCardKey)
            try container.encode(rateSource, forKey: .rateSource)
            try container.encodeOptionalOrNull(promptRateUSDPerMillionTokens, forKey: .promptRateUSDPerMillionTokens)
            try container.encodeOptionalOrNull(completionRateUSDPerMillionTokens, forKey: .completionRateUSDPerMillionTokens)
            try container.encodeOptionalOrNull(providerShareBPS, forKey: .providerShareBPS)
            try container.encodeOptionalOrNull(providerPromptPayoutUSDPerMillionTokens, forKey: .providerPromptPayoutUSDPerMillionTokens)
            try container.encodeOptionalOrNull(providerCompletionPayoutUSDPerMillionTokens, forKey: .providerCompletionPayoutUSDPerMillionTokens)
            try container.encode(economicsState, forKey: .economicsState)
            try container.encodeOptionalOrNull(demandRank, forKey: .demandRank)
            try container.encodeOptionalOrNull(demandWeight, forKey: .demandWeight)
            try container.encodeOptionalOrNull(readyProviderCount, forKey: .readyProviderCount)
            try container.encodeOptionalOrNull(supplyDeficitScore, forKey: .supplyDeficitScore)
            try container.encode(actions, forKey: .actions)
        }
    }

    let schema: String
    let generatedAt: String
    let projectionSequence: Int
    let source: Source
    let warnings: [String]
    let rows: [Row]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case projectionSequence = "projection_sequence"
        case source
        case warnings
        case rows
    }

    init(generatedAt: String, projectionSequence: Int, source: Source, warnings: [String], rows: [Row]) {
        schema = "model_catalog_economics.v1"
        self.generatedAt = generatedAt
        self.projectionSequence = projectionSequence
        self.source = source
        self.warnings = warnings
        self.rows = rows
    }
}

struct ModelSwitchEventWire: Codable, Equatable, Sendable {
    let schemaVersion: String
    let type: String
    let transactionID: String
    let fromModelID: String?
    let targetModelID: String
    let phase: String
    let elapsedMS: Int
    let cancellable: Bool
    let reason: String?
    let cooldownSecondsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case transactionID = "transaction_id"
        case fromModelID = "from_model_id"
        case targetModelID = "target_model_id"
        case phase
        case elapsedMS = "elapsed_ms"
        case cancellable
        case reason
        case cooldownSecondsRemaining = "cooldown_seconds_remaining"
    }

    init(
        type: String,
        transactionID: String,
        fromModelID: String? = nil,
        targetModelID: String,
        phase: String,
        elapsedMS: Int = 0,
        cancellable: Bool = false,
        reason: String? = nil,
        cooldownSecondsRemaining: Int? = nil
    ) {
        schemaVersion = "model_switch_event.v1"
        self.type = type
        self.transactionID = transactionID
        self.fromModelID = fromModelID
        self.targetModelID = targetModelID
        self.phase = phase
        self.elapsedMS = elapsedMS
        self.cancellable = cancellable
        self.reason = reason
        self.cooldownSecondsRemaining = cooldownSecondsRemaining
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(type, forKey: .type)
        try container.encode(transactionID, forKey: .transactionID)
        if let fromModelID {
            try container.encode(fromModelID, forKey: .fromModelID)
        } else {
            try container.encodeNil(forKey: .fromModelID)
        }
        try container.encode(targetModelID, forKey: .targetModelID)
        try container.encode(phase, forKey: .phase)
        try container.encode(elapsedMS, forKey: .elapsedMS)
        try container.encode(cancellable, forKey: .cancellable)
        if let reason {
            try container.encode(reason, forKey: .reason)
        } else {
            try container.encodeNil(forKey: .reason)
        }
        if let cooldownSecondsRemaining {
            try container.encode(cooldownSecondsRemaining, forKey: .cooldownSecondsRemaining)
        } else {
            try container.encodeNil(forKey: .cooldownSecondsRemaining)
        }
    }
}

struct ModelRecommendationCheckEventWire: Codable, Equatable, Sendable {
    let schemaVersion = "model_recommendation_check_event.v1"
    let type: String
    let checkID: String
    let candidateModelID: String?
    let isolatedCacheRoot: String?
    let stagingOwner: String?
    let phase: String?
    let elapsedMS: Int
    let cancellable: Bool
    let downloadBytesWritten: Int?
    let downloadBytesTotal: Int?
    let reason: String?
    let stagingDiscarded: Bool?
    let installedOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case checkID = "check_id"
        case candidateModelID = "candidate_model_id"
        case isolatedCacheRoot = "isolated_cache_root"
        case stagingOwner = "staging_owner"
        case phase
        case elapsedMS = "elapsed_ms"
        case cancellable
        case downloadBytesWritten = "download_bytes_written"
        case downloadBytesTotal = "download_bytes_total"
        case reason
        case stagingDiscarded = "staging_discarded"
        case installedOnly = "installed_only"
    }
}

struct ModelAdoptionEventWire: Codable, Equatable, Sendable {
    let schemaVersion = "model_adoption_event.v1"
    let type: String
    let transactionID: String
    let targetModelID: String?
    let fromModelID: String?
    let phase: String?
    let elapsedMS: Int
    let cancellable: Bool
    let downloadBytesWritten: Int?
    let downloadBytesTotal: Int?
    let reason: String?
    let rollbackState: String?
    let incumbentModelID: String?
    let configSHA256: String?
    let backupPath: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case transactionID = "transaction_id"
        case targetModelID = "target_model_id"
        case fromModelID = "from_model_id"
        case phase
        case elapsedMS = "elapsed_ms"
        case cancellable
        case downloadBytesWritten = "download_bytes_written"
        case downloadBytesTotal = "download_bytes_total"
        case reason
        case rollbackState = "rollback_state"
        case incumbentModelID = "incumbent_model_id"
        case configSHA256 = "config_sha256"
        case backupPath = "backup_path"
    }
}

public struct ModelAdoptionAuthorityWire: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let transactionID: String
    public let recommendationSHA256: String
    public let expectedIncumbentModelID: String
    public let targetModelID: String
    public let targetArtifactPath: String
    public let targetArtifactSHA256: String
    public let targetCatalogRevision: String
    public let targetKVBits: Int?
    public let targetMaxContext: Int
    public let targetMaxBatch: Int
    public let targetDonorMode: Bool
    public let serveKnobsSHA256: String
    public let catalogIdentitySHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transactionID = "transaction_id"
        case recommendationSHA256 = "recommendation_sha256"
        case expectedIncumbentModelID = "expected_incumbent_model_id"
        case targetModelID = "target_model_id"
        case targetArtifactPath = "target_artifact_path"
        case targetArtifactSHA256 = "target_artifact_sha256"
        case targetCatalogRevision = "target_catalog_revision"
        case targetKVBits = "target_kv_bits"
        case targetMaxContext = "target_max_context"
        case targetMaxBatch = "target_max_batch"
        case targetDonorMode = "target_donor_mode"
        case serveKnobsSHA256 = "serve_knobs_sha256"
        case catalogIdentitySHA256 = "catalog_identity_sha256"
    }

    public init(
        transactionID: String,
        recommendationSHA256: String,
        expectedIncumbentModelID: String,
        targetModelID: String,
        targetArtifactPath: String,
        targetArtifactSHA256: String,
        targetCatalogRevision: String,
        targetKVBits: Int?,
        targetMaxContext: Int,
        targetMaxBatch: Int,
        targetDonorMode: Bool,
        serveKnobsSHA256: String,
        catalogIdentitySHA256: String
    ) {
        self.schemaVersion = "model_recommendation_apply_switch.v1"
        self.transactionID = transactionID
        self.recommendationSHA256 = recommendationSHA256
        self.expectedIncumbentModelID = expectedIncumbentModelID
        self.targetModelID = targetModelID
        self.targetArtifactPath = targetArtifactPath
        self.targetArtifactSHA256 = targetArtifactSHA256
        self.targetCatalogRevision = targetCatalogRevision
        self.targetKVBits = targetKVBits
        self.targetMaxContext = targetMaxContext
        self.targetMaxBatch = targetMaxBatch
        self.targetDonorMode = targetDonorMode
        self.serveKnobsSHA256 = serveKnobsSHA256
        self.catalogIdentitySHA256 = catalogIdentitySHA256
    }

    static func serveKnobsDigest(
        kvBits: Int?,
        maxContext: Int,
        maxBatch: Int,
        donorMode: Bool
    ) -> String {
        let fields = [
            kvBits.map(String.init) ?? "null",
            String(maxContext),
            String(maxBatch),
            donorMode ? "true" : "false",
        ]
        let data = fields.reduce(into: Data()) { partial, field in
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { partial.append(contentsOf: $0) }
            partial.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ModelAdoptionPrepareResultWire: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let transactionID: String
    public let accepted: Bool
    public let reason: String?
    public let targetModelID: String?
    public let targetArtifactPath: String?
    public let targetArtifactSHA256: String?
    public let targetCatalogRevision: String?
    public let serveKnobsSHA256: String?
    public let catalogIdentitySHA256: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transactionID = "transaction_id"
        case accepted
        case reason
        case targetModelID = "target_model_id"
        case targetArtifactPath = "target_artifact_path"
        case targetArtifactSHA256 = "target_artifact_sha256"
        case targetCatalogRevision = "target_catalog_revision"
        case serveKnobsSHA256 = "serve_knobs_sha256"
        case catalogIdentitySHA256 = "catalog_identity_sha256"
    }

    public init(
        transactionID: String,
        accepted: Bool,
        reason: String?,
        targetModelID: String?,
        targetArtifactPath: String?,
        targetArtifactSHA256: String?,
        targetCatalogRevision: String?,
        serveKnobsSHA256: String?,
        catalogIdentitySHA256: String?
    ) {
        self.schemaVersion = "model_recommendation_apply_switch.v1"
        self.transactionID = transactionID
        self.accepted = accepted
        self.reason = reason
        self.targetModelID = targetModelID
        self.targetArtifactPath = targetArtifactPath
        self.targetArtifactSHA256 = targetArtifactSHA256
        self.targetCatalogRevision = targetCatalogRevision
        self.serveKnobsSHA256 = serveKnobsSHA256
        self.catalogIdentitySHA256 = catalogIdentitySHA256
    }
}

public struct ModelAdoptionProgressWire: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let transactionID: String
    public let state: String
    public let elapsedMS: Int
    public let reason: String?
    public let targetModelID: String
    public let targetArtifactPath: String
    public let targetArtifactSHA256: String
    public let targetCatalogRevision: String
    public let serveKnobsSHA256: String
    public let catalogIdentitySHA256: String
    public let loadedModelID: String?
    public let loadedModelSHA256: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transactionID = "transaction_id"
        case state
        case elapsedMS = "elapsed_ms"
        case reason
        case targetModelID = "target_model_id"
        case targetArtifactPath = "target_artifact_path"
        case targetArtifactSHA256 = "target_artifact_sha256"
        case targetCatalogRevision = "target_catalog_revision"
        case serveKnobsSHA256 = "serve_knobs_sha256"
        case catalogIdentitySHA256 = "catalog_identity_sha256"
        case loadedModelID = "loaded_model_id"
        case loadedModelSHA256 = "loaded_model_sha256"
    }

    public init(
        transactionID: String,
        state: String,
        elapsedMS: Int,
        reason: String?,
        targetModelID: String,
        targetArtifactPath: String,
        targetArtifactSHA256: String,
        targetCatalogRevision: String,
        serveKnobsSHA256: String,
        catalogIdentitySHA256: String,
        loadedModelID: String?,
        loadedModelSHA256: String?
    ) {
        self.schemaVersion = "model_recommendation_apply_switch.v1"
        self.transactionID = transactionID
        self.state = state
        self.elapsedMS = elapsedMS
        self.reason = reason
        self.targetModelID = targetModelID
        self.targetArtifactPath = targetArtifactPath
        self.targetArtifactSHA256 = targetArtifactSHA256
        self.targetCatalogRevision = targetCatalogRevision
        self.serveKnobsSHA256 = serveKnobsSHA256
        self.catalogIdentitySHA256 = catalogIdentitySHA256
        self.loadedModelID = loadedModelID
        self.loadedModelSHA256 = loadedModelSHA256
    }
}

enum ModelSwitchingWireCodec {
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        print(try encode(value))
    }

    static func safeID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let code = scalar.value
            return code >= 0x20 && code != 0x7F && !(0x80...0x9F).contains(code)
        }
    }

    static func fitLabel(_ verdict: ModelFit.Verdict) -> String {
        switch verdict {
        case .fits: return "fits"
        case .tight: return "tight"
        case .wontFit: return "wont_fit"
        case .unknown: return "unknown"
        }
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeOptionalOrNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
