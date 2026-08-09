import Foundation

struct MalibuRecommendationDocument: Decodable, Equatable, Sendable {
    struct Inputs: Decodable, Equatable, Sendable {
        let rateCardVersion: String
        let demandRankVersion: String
        let candidateCatalogVersion: String

        enum CodingKeys: String, CodingKey {
            case rateCardVersion = "rate_card_version"
            case demandRankVersion = "demand_rank_version"
            case candidateCatalogVersion = "candidate_catalog_version"
        }
    }

    struct Hardware: Decodable, Equatable, Sendable {
        let machine: String?
        let chip: String
        let memoryGB: Int
        let bandwidthTier: String
        let detected: Bool
        let osVersion: String
        let binaryVersion: String

        enum CodingKeys: String, CodingKey {
            case machine, chip, detected
            case memoryGB = "memory_gb"
            case bandwidthTier = "bandwidth_tier"
            case osVersion = "os_version"
            case binaryVersion = "binary_version"
        }
    }

    struct ServeConfig: Decodable, Equatable, Sendable {
        let model: String
        let modelArtifactPath: String
        let modelArtifactSHA256: String
        let modelCatalogKey: String
        let modelCatalogModelID: String
        let modelCatalogRevision: String
        let modelCatalogSHA256: String
        let modelCatalogVersion: String
        let modelCatalogHash: String
        let kvBits: Int?
        let maxContextOverride: Int
        let maxConcurrencyOverride: Int
        let donorMode: Bool
        let draftModel: String?
        let draftModelArtifactSHA256: String?

        enum CodingKeys: String, CodingKey {
            case model
            case modelArtifactPath = "model_artifact_path"
            case modelArtifactSHA256 = "model_artifact_sha256"
            case modelCatalogKey = "model_catalog_key"
            case modelCatalogModelID = "model_catalog_model_id"
            case modelCatalogRevision = "model_catalog_revision"
            case modelCatalogSHA256 = "model_catalog_sha256"
            case modelCatalogVersion = "model_catalog_version"
            case modelCatalogHash = "model_catalog_hash"
            case kvBits = "kv_bits"
            case maxContextOverride = "max_context_override"
            case maxConcurrencyOverride = "max_concurrency_override"
            case donorMode = "donor_mode"
            case draftModel = "draft_model"
            case draftModelArtifactSHA256 = "draft_model_artifact_sha256"
        }
    }

    struct Candidate: Decodable, Equatable, Sendable {
        let rank: Int
        let model: String
        let eligible: Bool
        let confidence: String
        let why: String
        let promptRateUSDPerMillionTokens: Double?
        let completionRateUSDPerMillionTokens: Double?

        enum CodingKeys: String, CodingKey {
            case rank, model, eligible, confidence, why
            case promptRateUSDPerMillionTokens = "prompt_rate_usd_per_million_tokens"
            case completionRateUSDPerMillionTokens = "completion_rate_usd_per_million_tokens"
        }
    }

    let schemaVersion: String
    let generatedAt: String
    let hardware: Hardware
    let inputs: Inputs
    let recommendedModel: String?
    let promptRateUSDPerMillionTokens: Double?
    let completionRateUSDPerMillionTokens: Double?
    let serveConfig: ServeConfig?
    let candidates: [Candidate]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case hardware, inputs
        case recommendedModel = "recommended_model"
        case promptRateUSDPerMillionTokens = "prompt_rate_usd_per_million_tokens"
        case completionRateUSDPerMillionTokens = "completion_rate_usd_per_million_tokens"
        case serveConfig = "serve_config"
        case candidates, warnings
    }

    func validated(now: Date = Date()) throws -> MalibuRecommendationDocument {
        guard schemaVersion == "autotune_recommend.v1",
              let generated = Self.parseTimestamp(generatedAt),
              generated <= now.addingTimeInterval(60),
              now.timeIntervalSince(generated) <= 7 * 24 * 60 * 60,
              hardware.memoryGB > 0,
              !hardware.chip.isEmpty,
              !hardware.binaryVersion.isEmpty,
              !inputs.rateCardVersion.isEmpty,
              !inputs.demandRankVersion.isEmpty,
              !inputs.candidateCatalogVersion.isEmpty else {
            throw MalibuRecommendationError.invalidDocument
        }
        guard let recommendedModel else { return self }
        guard isSafeRecommendationID(recommendedModel),
              let serveConfig,
              serveConfig.model == recommendedModel,
              isSafeRecommendationID(serveConfig.model),
              !serveConfig.modelArtifactPath.isEmpty,
              serveConfig.modelArtifactPath.hasPrefix("/"),
              Self.isLowerHex(serveConfig.modelArtifactSHA256, count: 64),
              !serveConfig.modelCatalogKey.isEmpty,
              isSafeRecommendationID(serveConfig.modelCatalogModelID),
              serveConfig.modelCatalogModelID == recommendedModel,
              !serveConfig.modelCatalogRevision.isEmpty,
              Self.isLowerHex(serveConfig.modelCatalogSHA256, count: 64),
              !serveConfig.modelCatalogVersion.isEmpty,
              Self.isLowerHex(serveConfig.modelCatalogHash, count: 64),
              serveConfig.maxContextOverride > 0,
              serveConfig.maxConcurrencyOverride > 0,
              (serveConfig.draftModel == nil) == (serveConfig.draftModelArtifactSHA256 == nil) else {
            throw MalibuRecommendationError.invalidDocument
        }
        if let draftModel = serveConfig.draftModel,
           let draftHash = serveConfig.draftModelArtifactSHA256 {
            guard isSafeRecommendationID(draftModel),
                  Self.isLowerHex(draftHash, count: 64) else {
                throw MalibuRecommendationError.invalidDocument
            }
        }
        return self
    }

    var isActionable: Bool {
        guard let recommendedModel, let serveConfig else { return false }
        return serveConfig.draftModel == nil
            && serveConfig.draftModelArtifactSHA256 == nil
            && Self.adoptionBlockingWarnings.isDisjoint(with: Set(warnings))
            && candidates.contains(where: { $0.model == recommendedModel && $0.eligible })
    }

    var adoptionAdvisoryReason: String? {
        guard recommendedModel != nil else { return nil }
        if serveConfig?.draftModel != nil {
            return String(localized: "This recommendation uses speculative decoding and is advisory only; adopt it manually after review.", comment: "Unsupported recommendation draft advisory")
        }
        if !Self.adoptionBlockingWarnings.isDisjoint(with: Set(warnings)) {
            return String(localized: "This recommendation has safety warnings and is advisory only; adopt it manually after review.", comment: "Recommendation warning advisory")
        }
        if !isActionable {
            return String(localized: "This recommendation is advisory only because it cannot be adopted safely as one transaction.", comment: "Recommendation advisory")
        }
        return nil
    }

    var recommendedCandidate: Candidate? {
        guard let recommendedModel else { return nil }
        return candidates.first { $0.model == recommendedModel }
    }

    func identity(currentModelID: String?) -> MalibuRecommendationIdentity? {
        guard let recommendedModel else { return nil }
        return MalibuRecommendationIdentity(
            recommendedModel: recommendedModel,
            currentModelID: currentModelID,
            rateCardVersion: inputs.rateCardVersion,
            demandRankVersion: inputs.demandRankVersion,
            candidateCatalogVersion: inputs.candidateCatalogVersion,
            chip: hardware.chip,
            memoryGB: hardware.memoryGB,
            bandwidthTier: hardware.bandwidthTier,
            binaryVersion: hardware.binaryVersion
        )
    }

    private static let adoptionBlockingWarnings: Set<String> = [
        "swap_observed_under_load",
        "buyer_ttft_ceiling_exceeded",
        "candidate_catalog_integrity_failure",
        "candidate_catalog_update_required",
        "demand_rank_integrity_failure",
        "demand_rank_update_required",
        "rate_card_integrity_failure",
        "rate_card_update_required",
        "thermal_throttle_detected",
        "thermal_throttled",
    ]

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

struct MalibuRecommendationCheckEvent: Decodable, Equatable, Sendable {
    let schemaVersion: String
    let type: String
    let checkID: String
    let candidateModelID: String?
    let phase: String?
    let elapsedMS: Int?
    let cancellable: Bool
    let installedOnly: Bool?
    let reason: String?
    let stagingDiscarded: Bool?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case checkID = "check_id"
        case candidateModelID = "candidate_model_id"
        case phase
        case elapsedMS = "elapsed_ms"
        case cancellable
        case installedOnly = "installed_only"
        case reason
        case stagingDiscarded = "staging_discarded"
    }

    func validatedForBackground() throws -> MalibuRecommendationCheckEvent {
        guard schemaVersion == "model_recommendation_check_event.v1",
              UUID(uuidString: checkID) != nil,
              ["accepted", "progress", "completed", "failed", "cancelled"].contains(type),
              elapsedMS == nil || elapsedMS! >= 0,
              candidateModelID == nil || isSafeRecommendationID(candidateModelID!),
              phase != "downloading",
              installedOnly == true else {
            throw MalibuRecommendationError.invalidCheckEvent
        }
        switch type {
        case "accepted":
            guard phase == nil, reason == nil, stagingDiscarded == nil else {
                throw MalibuRecommendationError.invalidCheckEvent
            }
        case "progress":
            guard phase == "planning", reason == nil, stagingDiscarded == nil else {
                throw MalibuRecommendationError.invalidCheckEvent
            }
        case "completed":
            guard phase == "completed", reason == nil, stagingDiscarded == true else {
                throw MalibuRecommendationError.invalidCheckEvent
            }
        case "failed", "cancelled":
            guard reason?.isEmpty == false, stagingDiscarded == true else {
                throw MalibuRecommendationError.invalidCheckEvent
            }
        default:
            throw MalibuRecommendationError.invalidCheckEvent
        }
        return self
    }
}

struct MalibuRecommendationIdentity: Codable, Equatable, Sendable {
    let recommendedModel: String
    let currentModelID: String?
    let rateCardVersion: String
    let demandRankVersion: String
    let candidateCatalogVersion: String
    let chip: String
    let memoryGB: Int
    let bandwidthTier: String
    let binaryVersion: String
}

struct MalibuRecommendationCheckTranscript: Equatable, Sendable {
    private(set) var checkID: String?
    private(set) var terminalType: String?

    mutating func consume(_ event: MalibuRecommendationCheckEvent) throws {
        let checked = try event.validatedForBackground()
        guard terminalType == nil else { throw MalibuRecommendationError.invalidCheckEvent }
        switch checked.type {
        case "accepted":
            guard checkID == nil else { throw MalibuRecommendationError.invalidCheckEvent }
            checkID = checked.checkID
        case "progress":
            guard checkID == checked.checkID else { throw MalibuRecommendationError.invalidCheckEvent }
        case "completed", "failed", "cancelled":
            guard checkID == checked.checkID else { throw MalibuRecommendationError.invalidCheckEvent }
            terminalType = checked.type
        default:
            throw MalibuRecommendationError.invalidCheckEvent
        }
    }
}

struct MalibuModelAdoptionEvent: Decodable, Equatable, Sendable {
    let schemaVersion: String
    let type: String
    let transactionID: String
    let targetModelID: String?
    let fromModelID: String?
    let incumbentModelID: String?
    let phase: String?
    let elapsedMS: Int?
    let cancellable: Bool?
    let reason: String?
    let rollbackState: String?
    let configSHA256: String?
    let backupPath: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case transactionID = "transaction_id"
        case targetModelID = "target_model_id"
        case fromModelID = "from_model_id"
        case incumbentModelID = "incumbent_model_id"
        case phase
        case elapsedMS = "elapsed_ms"
        case cancellable, reason
        case rollbackState = "rollback_state"
        case configSHA256 = "config_sha256"
        case backupPath = "backup_path"
    }

    func validated(target: String) throws -> MalibuModelAdoptionEvent {
        let validPhases = [
            "validating", "preparing_artifact", "config_backup", "config_apply",
            "switch_loading", "switch_draining", "config_verify", "rollback",
            "completed", "failed", "cancelled",
        ]
        guard schemaVersion == "model_adoption_event.v1",
              UUID(uuidString: transactionID) != nil,
              ["accepted", "progress", "completed", "failed", "cancelled"].contains(type),
              targetModelID == nil || targetModelID == target,
              phase == nil || validPhases.contains(phase!),
              elapsedMS == nil || elapsedMS! >= 0,
              rollbackState == nil || ["not_needed", "rolled_back", "rollback_failed"].contains(rollbackState!) else {
            throw MalibuRecommendationError.invalidAdoptionEvent
        }
        guard targetModelID == target else {
            throw MalibuRecommendationError.invalidAdoptionEvent
        }
        switch type {
        case "accepted":
            guard phase == nil, fromModelID != nil, reason == nil, rollbackState == nil,
                  configSHA256 == nil, backupPath == nil else {
                throw MalibuRecommendationError.invalidAdoptionEvent
            }
        case "progress":
            guard phase != nil, reason == nil || reason?.isEmpty == false,
                  rollbackState == nil, configSHA256 == nil, backupPath == nil else {
                throw MalibuRecommendationError.invalidAdoptionEvent
            }
        case "completed":
            guard phase == nil, reason == nil, rollbackState == nil,
                  let configSHA256,
                  Self.isLowerHex(configSHA256),
                  backupPath == nil || backupPath == "redacted" else {
                throw MalibuRecommendationError.invalidAdoptionEvent
            }
        case "failed", "cancelled":
            guard reason?.isEmpty == false, rollbackState != nil,
                  configSHA256 == nil, backupPath == nil else {
                throw MalibuRecommendationError.invalidAdoptionEvent
            }
        default:
            throw MalibuRecommendationError.invalidAdoptionEvent
        }
        return self
    }

    private static func isLowerHex(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}

struct MalibuModelAdoptionTranscript: Equatable, Sendable {
    private(set) var transactionID: String?
    private(set) var terminalEvent: MalibuModelAdoptionEvent?

    mutating func consume(_ event: MalibuModelAdoptionEvent, target: String) throws {
        let checked = try event.validated(target: target)
        guard terminalEvent == nil else { throw MalibuRecommendationError.invalidAdoptionEvent }
        switch checked.type {
        case "accepted":
            guard transactionID == nil else { throw MalibuRecommendationError.invalidAdoptionEvent }
            transactionID = checked.transactionID
        case "progress":
            guard transactionID == checked.transactionID else { throw MalibuRecommendationError.invalidAdoptionEvent }
        case "completed", "failed", "cancelled":
            guard transactionID == checked.transactionID else { throw MalibuRecommendationError.invalidAdoptionEvent }
            terminalEvent = checked
        default:
            throw MalibuRecommendationError.invalidAdoptionEvent
        }
    }
}

struct MalibuRecommendationSchedule: Codable, Equatable, Sendable {
    var lastCheckedAt: Date?
    var nextEligibleAt: Date?
    var consecutiveFailures = 0
    var snoozedUntil: Date?
    var snoozedRecommendationIdentity: MalibuRecommendationIdentity?

    mutating func recordSuccess(at date: Date) {
        lastCheckedAt = date
        nextEligibleAt = date.addingTimeInterval(24 * 60 * 60)
        consecutiveFailures = 0
    }

    mutating func recordFailure(at date: Date) {
        consecutiveFailures = min(consecutiveFailures + 1, 5)
        let hours = min(24, 1 << max(0, consecutiveFailures - 1))
        nextEligibleAt = date.addingTimeInterval(TimeInterval(hours * 60 * 60))
    }

    mutating func snooze(identity: MalibuRecommendationIdentity, at date: Date) {
        snoozedUntil = date.addingTimeInterval(24 * 60 * 60)
        snoozedRecommendationIdentity = identity
        // Permit a safe background recheck so a materially changed recommendation
        // is not hidden behind an older recommendation's dismissal.
        nextEligibleAt = nil
    }

    func suppresses(identity: MalibuRecommendationIdentity, at date: Date) -> Bool {
        snoozedRecommendationIdentity == identity
            && snoozedUntil.map { $0 > date } == true
    }

    func isEligible(at date: Date) -> Bool {
        nextEligibleAt == nil || nextEligibleAt! <= date
    }
}

enum MalibuRecommendationError: LocalizedError {
    case invalidDocument
    case notActionable
    case invalidCheckEvent
    case invalidAdoptionEvent

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return String(localized: "The provider returned an invalid recommendation.", comment: "Invalid recommendation")
        case .notActionable:
            return String(localized: "This recommendation cannot be adopted safely.", comment: "Blocked recommendation")
        case .invalidCheckEvent:
            return String(localized: "The provider returned invalid recommendation progress.", comment: "Invalid recommendation progress")
        case .invalidAdoptionEvent:
            return String(localized: "The provider returned invalid adoption progress.", comment: "Invalid adoption progress")
        }
    }
}

private func isSafeRecommendationID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 256 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value)
    }
}
