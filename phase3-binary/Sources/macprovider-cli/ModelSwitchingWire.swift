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
