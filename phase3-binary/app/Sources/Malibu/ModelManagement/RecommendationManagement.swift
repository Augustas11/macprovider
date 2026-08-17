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
        let tokensPerSecond: Double?
        let memoryHeadroomGB: Double?
        let rawScore: Double?
        let explanation: Explanation?

        enum CodingKeys: String, CodingKey {
            case rank, model, eligible, confidence, why
            case promptRateUSDPerMillionTokens = "prompt_rate_usd_per_million_tokens"
            case completionRateUSDPerMillionTokens = "completion_rate_usd_per_million_tokens"
            case tokensPerSecond = "tokens_per_second"
            case memoryHeadroomGB = "memory_headroom_gb"
            case rawScore = "raw_score"
            case explanation
        }
    }

    struct Explanation: Decodable, Equatable, Sendable {
        struct MemoryFit: Decodable, Equatable, Sendable {
            let requiredGB: Int
            let totalGB: Int
            let safetyMarginGB: Int
            let headroomGB: Double

            enum CodingKeys: String, CodingKey {
                case requiredGB = "required_gb"
                case totalGB = "total_gb"
                case safetyMarginGB = "safety_margin_gb"
                case headroomGB = "headroom_gb"
            }
        }

        struct DemandSignal: Decodable, Equatable, Sendable {
            let rank: Int?
            let weight: Double
            let recommendable: Bool
            let minProviderTarget: Int
            let readyProviderCount: Int?
            let supplyDeficitMultiplier: Double

            enum CodingKeys: String, CodingKey {
                case rank, weight, recommendable
                case minProviderTarget = "min_provider_target"
                case readyProviderCount = "ready_provider_count"
                case supplyDeficitMultiplier = "supply_deficit_multiplier"
            }
        }

        struct RateSignal: Decodable, Equatable, Sendable {
            let promptRateUSDPerMillionTokens: Double
            let completionRateUSDPerMillionTokens: Double
            let providerShareBPS: Int
            let providerCompletionPayoutUSDPerMillionTokens: Double

            enum CodingKeys: String, CodingKey {
                case promptRateUSDPerMillionTokens = "prompt_rate_usd_per_million_tokens"
                case completionRateUSDPerMillionTokens = "completion_rate_usd_per_million_tokens"
                case providerShareBPS = "provider_share_bps"
                case providerCompletionPayoutUSDPerMillionTokens = "provider_completion_payout_usd_per_million_tokens"
            }
        }

        struct EarningPotential: Decodable, Equatable, Sendable {
            let score: Double
            let kind: String
            let note: String
        }

        struct LocalHealth: Decodable, Equatable, Sendable {
            let warnings: [String]
        }

        let summary: String
        let warningState: String
        let measuredTPS: Double
        let throughputSource: String
        let memoryFit: MemoryFit
        let demandSignal: DemandSignal
        let rateSignal: RateSignal
        let earningPotential: EarningPotential
        let localHealth: LocalHealth
        let confidence: String
        let lostReason: String

        enum CodingKeys: String, CodingKey {
            case summary
            case warningState = "warning_state"
            case measuredTPS = "measured_tps"
            case throughputSource = "throughput_source"
            case memoryFit = "memory_fit"
            case demandSignal = "demand_signal"
            case rateSignal = "rate_signal"
            case earningPotential = "earning_potential"
            case localHealth = "local_health"
            case confidence
            case lostReason = "lost_reason"
        }
    }

    struct AlternativeExplanation: Decodable, Equatable, Sendable {
        let rank: Int
        let model: String
        let eligible: Bool
        let lostReason: String
        let summary: String
        let expectedEarningPotentialScore: Double

        enum CodingKeys: String, CodingKey {
            case rank, model, eligible, summary
            case lostReason = "lost_reason"
            case expectedEarningPotentialScore = "expected_earning_potential_score"
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
    let selectedExplanation: Explanation?
    let alternativeExplanations: [AlternativeExplanation]
    let donorFallbackExplanation: Explanation?
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
        case selectedExplanation = "selected_explanation"
        case alternativeExplanations = "alternative_explanations"
        case donorFallbackExplanation = "donor_fallback_explanation"
        case candidates, warnings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(String.self, forKey: .schemaVersion)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        hardware = try c.decode(Hardware.self, forKey: .hardware)
        inputs = try c.decode(Inputs.self, forKey: .inputs)
        recommendedModel = try c.decodeIfPresent(String.self, forKey: .recommendedModel)
        promptRateUSDPerMillionTokens = try c.decodeIfPresent(Double.self, forKey: .promptRateUSDPerMillionTokens)
        completionRateUSDPerMillionTokens = try c.decodeIfPresent(Double.self, forKey: .completionRateUSDPerMillionTokens)
        serveConfig = try c.decodeIfPresent(ServeConfig.self, forKey: .serveConfig)
        selectedExplanation = try c.decodeIfPresent(Explanation.self, forKey: .selectedExplanation)
        alternativeExplanations = try c.decodeIfPresent([AlternativeExplanation].self, forKey: .alternativeExplanations) ?? []
        donorFallbackExplanation = try c.decodeIfPresent(Explanation.self, forKey: .donorFallbackExplanation)
        candidates = try c.decode([Candidate].self, forKey: .candidates)
        warnings = try c.decode([String].self, forKey: .warnings)
    }

    func validated(now: Date = Date()) throws -> MalibuRecommendationDocument {
        guard schemaVersion == "autotune_recommend.v1",
              let generated = Self.parseTimestamp(generatedAt),
              generated <= now.addingTimeInterval(60),
              now.timeIntervalSince(generated) <= 7 * 24 * 60 * 60,
              hardware.memoryGB > 0,
              Self.isSafeDisplayText(hardware.chip, maxLength: 128),
              hardware.machine.map({ Self.isSafeDisplayText($0, maxLength: 64) }) ?? true,
              Self.isSafeDisplayText(hardware.bandwidthTier, maxLength: 32),
              Self.isSafeDisplayText(hardware.osVersion, maxLength: 64),
              Self.isSafeDisplayText(hardware.binaryVersion, maxLength: 64),
              Self.isSafeDisplayText(inputs.rateCardVersion, maxLength: 128),
              Self.isSafeDisplayText(inputs.demandRankVersion, maxLength: 128),
              Self.isSafeDisplayText(inputs.candidateCatalogVersion, maxLength: 128),
              Self.validateOptionalRate(promptRateUSDPerMillionTokens),
              Self.validateOptionalRate(completionRateUSDPerMillionTokens) else {
            throw MalibuRecommendationError.invalidDocument
        }
        let structuredExplanations = candidates.compactMap(\.explanation)
            + [selectedExplanation, donorFallbackExplanation].compactMap { $0 }
        guard structuredExplanations.allSatisfy(Self.validateExplanation),
              alternativeExplanations.allSatisfy(Self.validateAlternativeExplanation),
              Self.validateAlternativeEvidence(alternativeExplanations, candidates: candidates, selectedModel: recommendedModel),
              Self.validateDonorFallbackEvidence(donorFallbackExplanation, candidates: candidates),
              candidates.allSatisfy(Self.validateCandidate),
              candidates.allSatisfy({ Self.validateCandidateEvidence($0, hardware: hardware) }),
              warnings.allSatisfy(Self.validateRootWarning) else {
            throw MalibuRecommendationError.invalidDocument
        }
        guard let recommendedModel else {
            guard selectedExplanation == nil,
                  promptRateUSDPerMillionTokens == nil,
                  completionRateUSDPerMillionTokens == nil,
                  serveConfig.map(Self.validateDonorServeConfig) ?? true,
                  candidates.allSatisfy(Self.validateNoRecommendationCandidate) else {
                throw MalibuRecommendationError.invalidDocument
            }
            return self
        }
        let selectedCandidates = candidates.filter { $0.model == recommendedModel }
        guard Self.isSafeVisibleRecommendationID(recommendedModel),
              selectedCandidates.count == 1,
              let serveConfig,
              serveConfig.model == recommendedModel,
              !serveConfig.donorMode,
              Self.validateServeConfig(serveConfig),
              serveConfig.modelCatalogModelID == recommendedModel,
              Self.validateRecommendedCandidateSemantics(
                  selectedCandidates[0],
                  selectedExplanation: selectedExplanation
              ),
              Self.selectedRatesAreBound(
                  candidate: selectedCandidates[0],
                  selectedExplanation: selectedExplanation,
                  promptRate: promptRateUSDPerMillionTokens,
                  completionRate: completionRateUSDPerMillionTokens
              ) else {
            throw MalibuRecommendationError.invalidDocument
        }
        let candidateExplanation = selectedCandidates[0].explanation
        switch (selectedExplanation, candidateExplanation) {
        case (nil, nil):
            throw MalibuRecommendationError.invalidDocument
        case (let selected?, let candidate?) where selected == candidate:
            break
        default:
            throw MalibuRecommendationError.invalidDocument
        }
        if let draftModel = serveConfig.draftModel,
           let draftHash = serveConfig.draftModelArtifactSHA256 {
            guard Self.isSafeVisibleRecommendationID(draftModel),
                  Self.isLowerHex(draftHash, count: 64) else {
                throw MalibuRecommendationError.invalidDocument
            }
        }
        return self
    }

    var isActionable: Bool {
        false
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
        let selectedCandidates = candidates.filter { $0.model == recommendedModel }
        guard selectedCandidates.count == 1 else { return nil }
        return selectedCandidates[0]
    }

    var selectedRationale: String? {
        selectedExplanation?.summary ?? recommendedCandidate?.explanation?.summary
    }

    var selectedEvidenceLines: [String] {
        guard let explanation = selectedExplanation ?? recommendedCandidate?.explanation else {
            return []
        }
        return evidenceLines(for: explanation)
    }

    var hasVisibleRecommendationFeedback: Bool {
        recommendedModel != nil || hasVisibleWhyNotFeedback
    }

    var hasVisibleWhyNotFeedback: Bool {
        recommendedModel == nil
            && (primaryDisplayExplanation != nil
            || recommendedCandidate != nil
        )
    }

    var displayModelID: String? {
        recommendedModel ?? primaryDisplayCandidate?.model
    }

    var displayRationale: String? {
        selectedRationale
            ?? primaryDisplayExplanation?.summary
            ?? primaryDisplayCandidate?.why
    }

    var displayEvidenceLines: [String] {
        guard let explanation = selectedExplanation ?? primaryDisplayExplanation else {
            return []
        }
        return evidenceLines(for: explanation)
    }

    var isRecommendationResult: Bool {
        recommendedModel != nil
    }

    private var primaryDisplayCandidate: Candidate? {
        donorFallbackDisplayCandidate
            ?? candidates.sorted { $0.rank < $1.rank }.first { $0.explanation != nil }
            ?? candidates.sorted { $0.rank < $1.rank }.first
    }

    private var primaryDisplayExplanation: Explanation? {
        donorFallbackDisplayCandidate?.explanation
            ?? primaryDisplayCandidate?.explanation
    }

    private var donorFallbackDisplayCandidate: Candidate? {
        guard let donorFallbackExplanation else { return nil }
        return candidates.sorted { $0.rank < $1.rank }.first { $0.explanation == donorFallbackExplanation }
    }

    private func evidenceLines(for explanation: Explanation) -> [String] {
        let memory = explanation.memoryFit
        let demand = explanation.demandSignal
        let rate = explanation.rateSignal
        let demandRank = demand.rank.map { "#\($0)" } ?? "unranked"
        let providerShare = Double(rate.providerShareBPS) / 100.0
        let throughputLabel: String
        switch explanation.throughputSource {
        case "catalog_estimate":
            throughputLabel = "Catalog estimate"
        case "unavailable":
            throughputLabel = "Throughput unavailable"
        case "measured":
            throughputLabel = "Measured"
        default:
            throughputLabel = "Throughput"
        }
        let throughputLine = explanation.throughputSource == "unavailable"
            ? String(
                format: "%@; memory headroom %.1f GB after %d GB safety margin.",
                throughputLabel,
                memory.headroomGB,
                memory.safetyMarginGB
            )
            : String(
                format: "%@ %.2f tok/s; memory headroom %.1f GB after %d GB safety margin.",
                throughputLabel,
                explanation.measuredTPS,
                memory.headroomGB,
                memory.safetyMarginGB
            )
        var lines = [
            "State \(explanation.warningState); confidence \(explanation.confidence).",
            throughputLine,
            String(
                format: "Demand %@, weight %.2f, supply %.2fx, ready %@/%d.",
                demandRank,
                demand.weight,
                demand.supplyDeficitMultiplier,
                demand.readyProviderCount.map(String.init) ?? "unknown",
                demand.minProviderTarget
            ),
            String(
                format: "Provider share %.2f%%; earning potential score %.2f, not accrued rewards.",
                providerShare,
                explanation.earningPotential.score
            ),
        ]
        if !explanation.localHealth.warnings.isEmpty {
            lines.append("Local health: \(explanation.localHealth.warnings.joined(separator: ", ")).")
        }
        for alternative in alternativeExplanations.prefix(3) {
            lines.append("Alternative \(alternative.rank): \(alternative.model) - \(alternative.summary)")
        }
        return lines
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

    private static let knownRootWarnings: Set<String> = [
        "candidate_catalog_fallback_used",
        "candidate_catalog_integrity_failure",
        "candidate_catalog_update_required",
        "candidate_catalog_stale",
        "demand_rank_fallback_used",
        "demand_rank_integrity_failure",
        "demand_rank_update_required",
        "demand_rank_stale",
        "hardware_tier_unknown",
        "rate_card_fallback_used",
        "rate_card_integrity_failure",
        "rate_card_update_required",
        "rate_card_stale",
        "no_eligible_model",
        "rate_card_default_tier_used",
        "swap_observed_under_load",
        "tps_below_gate",
        "ttft_above_gate",
        "buyer_ttft_ceiling_exceeded",
        "thermal_throttle_detected",
        "thermal_throttled",
    ]

    private static let knownThroughputSources: Set<String> = [
        "measured",
        "catalog_estimate",
        "unavailable",
    ]

    private static let noRecommendationLostReasons: Set<String> = [
        "paid_trust_blocked",
        "demand_not_recommendable",
        "demand_signal_unavailable",
        "runtime_not_recommendable",
        "rate_card_unavailable",
        "missing_model_artifact_identity",
        "insufficient_memory_headroom",
        "bandwidth_tier_below_minimum",
        "benchmark_unavailable",
        "thermal_throttle_detected",
        "swap_observed_under_load",
        "buyer_ttft_ceiling_exceeded",
        "benchmark_evidence_stale_or_mismatched",
        "unknown_recommendation_gate",
    ]

    private static let knownWarningStates: Set<String> = [
        "ready",
        "advisory",
        "blocked",
    ]

    private static let knownConfidenceValues: Set<String> = [
        "high",
        "medium",
        "low",
        "catalog_estimate",
    ]

    private static let knownLocalHealthWarnings: Set<String> = [
        "thermal_throttle_detected",
        "thermal_throttled",
        "swap_observed_under_load",
        "buyer_ttft_ceiling_exceeded",
    ]

    private static let forbiddenDisplayFragments = [
        "/private/",
        "/users/",
        "/var/",
        "/tmp/",
        "file://",
        "model_artifact_path",
        "model_artifact_sha256",
        "artifact_path",
        "artifact_sha",
        "provider_id",
        "provider id",
        "provider_identity",
        "hardware_identity",
        "hardware identity",
        "hardware_identity_hash",
        "hmac",
        "private key",
        "daily_income",
        "daily income",
        "daily_usd",
        "usd/day",
        "/day",
        "per day",
        "per week",
        "every 24 hours",
        "every week",
        "will pay",
        "will earn",
        "regardless of demand",
        "hourly",
        "guaranteed",
        "guarantee",
        "$",
    ]

    private static func validateExplanation(_ explanation: Explanation) -> Bool {
        let memory = explanation.memoryFit
        let demand = explanation.demandSignal
        let rate = explanation.rateSignal
        let earning = explanation.earningPotential

        return isSafeDisplayText(explanation.summary, maxLength: 200)
            && knownWarningStates.contains(explanation.warningState)
            && explanation.measuredTPS.isFinite
            && explanation.measuredTPS >= 0
            && knownThroughputSources.contains(explanation.throughputSource)
            && memory.requiredGB > 0
            && memory.requiredGB <= 1_024
            && memory.totalGB > 0
            && memory.totalGB <= 1_024
            && memory.safetyMarginGB >= 0
            && memory.safetyMarginGB <= 1_024
            && memory.headroomGB.isFinite
            && demand.weight.isFinite
            && demand.weight >= 0
            && demand.minProviderTarget >= 0
            && (demand.readyProviderCount == nil || demand.readyProviderCount! >= 0)
            && demand.supplyDeficitMultiplier.isFinite
            && demand.supplyDeficitMultiplier >= 0
            && rate.promptRateUSDPerMillionTokens.isFinite
            && rate.promptRateUSDPerMillionTokens >= 0
            && rate.completionRateUSDPerMillionTokens.isFinite
            && rate.completionRateUSDPerMillionTokens >= 0
            && (0...10_000).contains(rate.providerShareBPS)
            && rate.providerCompletionPayoutUSDPerMillionTokens.isFinite
            && rate.providerCompletionPayoutUSDPerMillionTokens >= 0
            && earning.score.isFinite
            && earning.score >= 0
            && earning.kind == "relative_ranking_score"
            && earning.note == "Estimated earning potential only; actual rewards depend on buyer demand, uptime, accepted work, and settlement."
            && explanation.localHealth.warnings.allSatisfy { knownLocalHealthWarnings.contains($0) }
            && knownConfidenceValues.contains(explanation.confidence)
            && isSafeSlug(explanation.lostReason, maxLength: 96)
    }

    private static func validateAlternativeExplanation(_ explanation: AlternativeExplanation) -> Bool {
        explanation.rank > 0
            && isSafeVisibleRecommendationID(explanation.model)
            && isSafeSlug(explanation.lostReason, maxLength: 96)
            && isSafeDisplayText(explanation.summary, maxLength: 240)
            && explanation.expectedEarningPotentialScore.isFinite
            && explanation.expectedEarningPotentialScore >= 0
    }

    private static func validateCandidate(_ candidate: Candidate) -> Bool {
        candidate.rank > 0
            && isSafeVisibleRecommendationID(candidate.model)
            && knownConfidenceValues.contains(candidate.confidence)
            && isSafeDisplayText(candidate.why, maxLength: 320)
            && validateOptionalRate(candidate.promptRateUSDPerMillionTokens)
            && validateOptionalRate(candidate.completionRateUSDPerMillionTokens)
            && validateOptionalRate(candidate.tokensPerSecond)
            && (candidate.memoryHeadroomGB.map { $0.isFinite } ?? true)
            && validateOptionalRate(candidate.rawScore)
    }

    private static func validateNoRecommendationCandidate(_ candidate: Candidate) -> Bool {
        guard !candidate.eligible,
              isNoRecommendationDisplayText(candidate.why) else {
            return false
        }
        guard let explanation = candidate.explanation else { return true }
        return explanation.warningState == "blocked"
            && noRecommendationLostReasons.contains(explanation.lostReason)
            && isNoRecommendationDisplayText(explanation.summary)
    }

    private static func validateRecommendedCandidateSemantics(
        _ candidate: Candidate,
        selectedExplanation: Explanation?
    ) -> Bool {
        guard let selectedExplanation,
              candidate.eligible,
              candidate.confidence == selectedExplanation.confidence,
              selectedExplanation.demandSignal.recommendable,
              selectedExplanation.lostReason == "selected_best_expected_earning_potential" else {
            return false
        }
        if selectedExplanation.warningState == "ready" {
            return selectedExplanation.confidence == "high"
                && selectedExplanation.throughputSource == "measured"
                && selectedExplanation.localHealth.warnings.isEmpty
        }
        return selectedExplanation.warningState == "advisory"
    }

    private static func validateCandidateEvidence(_ candidate: Candidate, hardware: Hardware) -> Bool {
        guard let explanation = candidate.explanation else { return true }
        guard let tokensPerSecond = candidate.tokensPerSecond,
              let memoryHeadroomGB = candidate.memoryHeadroomGB,
              let rawScore = candidate.rawScore,
              tokensPerSecond.isFinite,
              tokensPerSecond >= 0,
              memoryHeadroomGB.isFinite,
              rawScore.isFinite,
              rawScore >= 0,
              isKnownExplanationSummary(explanation.summary) else {
            return false
        }
        let afterMargin = explanation.memoryFit.totalGB
            .subtractingReportingOverflow(explanation.memoryFit.safetyMarginGB)
        guard !afterMargin.overflow else { return false }
        let afterRequired = afterMargin.partialValue
            .subtractingReportingOverflow(explanation.memoryFit.requiredGB)
        guard !afterRequired.overflow else { return false }
        let expectedHeadroom = Double(afterRequired.partialValue)
        return sameRate(explanation.measuredTPS, tokensPerSecond)
            && sameRate(explanation.memoryFit.headroomGB, memoryHeadroomGB)
            && sameRate(explanation.memoryFit.headroomGB, expectedHeadroom)
            && explanation.memoryFit.totalGB == hardware.memoryGB
            && sameRate(explanation.earningPotential.score, rawScore)
    }

    private static func isNoRecommendationDisplayText(_ value: String) -> Bool {
        guard isKnownExplanationSummary(value) else { return false }
        let normalized = value.lowercased()
        let selectedFragments = [
            "selected for",
            "best measured provider score",
            "best estimated earning potential",
            "best expected provider earnings",
            "eligible and will be ranked",
            "eligible, but another model",
            "stronger estimated earning potential",
        ]
        return selectedFragments.allSatisfy { !normalized.contains($0) }
    }

    private static func isKnownExplanationSummary(_ value: String) -> Bool {
        if knownExactExplanationSummaries.contains(value) { return true }
        return knownBlockedSummarySuffixes.contains { suffix in
            guard value.hasSuffix(suffix) else { return false }
            return isSafeSummaryModelKey(String(value.dropLast(suffix.count)))
        }
    }

    private static let knownExactExplanationSummaries: Set<String> = [
        "Selected for the best estimated earning potential on this Mac.",
        "Eligible, but another model has stronger estimated earning potential on this Mac.",
        "Selected from signed catalog estimates and current hardware fit; no local throughput benchmark was run.",
        "Eligible installed alternative from signed catalog estimates; no local throughput benchmark was run.",
        "No paid recommendation is available for this Mac right now.",
        "No paid recommendation is available for this row.",
        "No paid recommendation is available; this donor fallback remains advisory.",
        "Paid recommendation is unavailable until signed inputs are trusted.",
    ]

    private static let knownBlockedSummarySuffixes = [
        " is eligible and will be ranked by earning potential.",
        " is not currently marked recommendable by demand signal.",
        " has no trusted demand signal for earning estimates.",
        " is not in recommendable runtime status.",
        " has no trusted rate-card row for earning estimates.",
        " is missing release-pinned model artifact identity.",
        " does not fit with the local memory safety margin.",
        " needs a higher memory-bandwidth tier than this Mac advertises.",
        " has no current local throughput benchmark.",
        " was blocked by thermal throttling during the probe.",
        " was blocked because swap was observed under probe load.",
        " was blocked by the buyer latency ceiling.",
        " needs fresh local benchmark evidence.",
        " did not clear one or more recommendation gates.",
    ]

    private static func isSafeSummaryModelKey(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value)
                || (0x41...0x5A).contains(scalar.value)
                || (0x61...0x7A).contains(scalar.value)
                || scalar == "-"
                || scalar == "_"
                || scalar == "."
                || scalar == "/"
                || scalar == ":"
        }
    }

    private static func selectedRatesAreBound(
        candidate: Candidate,
        selectedExplanation: Explanation?,
        promptRate: Double?,
        completionRate: Double?
    ) -> Bool {
        guard let promptRate,
              let completionRate,
              let candidatePrompt = candidate.promptRateUSDPerMillionTokens,
              let candidateCompletion = candidate.completionRateUSDPerMillionTokens,
              sameRate(promptRate, candidatePrompt),
              sameRate(completionRate, candidateCompletion) else {
            return false
        }
        guard let selectedExplanation else { return true }
        return sameRate(promptRate, selectedExplanation.rateSignal.promptRateUSDPerMillionTokens)
            && sameRate(completionRate, selectedExplanation.rateSignal.completionRateUSDPerMillionTokens)
    }

    private static func validateDonorServeConfig(_ serveConfig: ServeConfig) -> Bool {
        serveConfig.donorMode && validateServeConfig(serveConfig)
    }

    private static func validateServeConfig(_ serveConfig: ServeConfig) -> Bool {
        isSafeVisibleRecommendationID(serveConfig.model)
            && !serveConfig.modelArtifactPath.isEmpty
            && serveConfig.modelArtifactPath.hasPrefix("/")
            && isLowerHex(serveConfig.modelArtifactSHA256, count: 64)
            && isSafeDisplayText(serveConfig.modelCatalogKey, maxLength: 128)
            && isSafeVisibleRecommendationID(serveConfig.modelCatalogModelID)
            && isSafeDisplayText(serveConfig.modelCatalogRevision, maxLength: 128)
            && isLowerHex(serveConfig.modelCatalogSHA256, count: 64)
            && isSafeDisplayText(serveConfig.modelCatalogVersion, maxLength: 128)
            && isLowerHex(serveConfig.modelCatalogHash, count: 64)
            && serveConfig.maxContextOverride > 0
            && serveConfig.maxConcurrencyOverride > 0
            && (serveConfig.draftModel == nil) == (serveConfig.draftModelArtifactSHA256 == nil)
            && (serveConfig.draftModel.map(isSafeVisibleRecommendationID) ?? true)
            && (serveConfig.draftModelArtifactSHA256.map { isLowerHex($0, count: 64) } ?? true)
    }

    private static func validateOptionalRate(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0
    }

    private static func sameRate(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.000_000_5
    }

    private static func validateAlternativeEvidence(
        _ alternatives: [AlternativeExplanation],
        candidates: [Candidate],
        selectedModel: String?
    ) -> Bool {
        alternatives.allSatisfy { alternative in
            let matches = candidates.filter { $0.model == alternative.model }
            guard matches.count == 1,
                  alternative.model != selectedModel,
                  let candidateExplanation = matches[0].explanation else {
                return false
            }
            return candidateExplanation.summary == alternative.summary
                && candidateExplanation.lostReason == alternative.lostReason
                && candidateExplanation.earningPotential.score == alternative.expectedEarningPotentialScore
        }
    }

    private static func validateDonorFallbackEvidence(
        _ donorFallbackExplanation: Explanation?,
        candidates: [Candidate]
    ) -> Bool {
        guard let donorFallbackExplanation else { return true }
        return candidates.filter { $0.explanation == donorFallbackExplanation }.count == 1
    }

    private static func validateRootWarning(_ warning: String) -> Bool {
        knownRootWarnings.contains(warning)
            && isSafeSlug(warning, maxLength: 96)
    }

    private static func isSafeDisplayText(_ value: String, maxLength: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return false }
        guard trimmed.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.newlines.contains($0)
        }) else { return false }
        let lowercased = trimmed.lowercased()
        return !forbiddenDisplayFragments.contains { lowercased.contains($0) }
    }

    private static func isSafeVisibleRecommendationID(_ value: String) -> Bool {
        isSafeRecommendationID(value)
            && isSafeDisplayText(value, maxLength: 256)
    }

    private static func isSafeSlug(_ value: String, maxLength: Int) -> Bool {
        !value.isEmpty
            && value.count <= maxLength
            && value.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

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
