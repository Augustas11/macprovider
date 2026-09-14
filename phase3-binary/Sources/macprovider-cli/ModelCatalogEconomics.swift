import CryptoKit
import Foundation
import MacProviderCore

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
        var transactionContextSHA256: String? = nil

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
            case transactionContextSHA256 = "transaction_context_sha256"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cliVersion, forKey: .cliVersion)
            try container.encode(cliBuildCommit, forKey: .cliBuildCommit)
            try container.encode(processLaunchID, forKey: .processLaunchID)
            try container.encode(processStartedAt, forKey: .processStartedAt)
            try container.encode(projectionProtocolVersion, forKey: .projectionProtocolVersion)
            try container.encode(rateCardSource, forKey: .rateCardSource)
            try encodeNullable(rateCardDigest, forKey: .rateCardDigest, into: &container)
            try encodeNullable(rateCardSignatureDigest, forKey: .rateCardSignatureDigest, into: &container)
            try encodeNullable(demandFeedDigest, forKey: .demandFeedDigest, into: &container)
            try encodeNullable(candidateFeedDigest, forKey: .candidateFeedDigest, into: &container)
            try container.encode(rateCardMaxAgeSeconds, forKey: .rateCardMaxAgeSeconds)
            if projectionProtocolVersion == "2" {
                try encodeNullable(transactionContextSHA256, forKey: .transactionContextSHA256, into: &container)
            }
        }
    }

    struct Admission: Codable, Equatable, Sendable {
        let state: String
        let source: String
        let coordinatorEventID: String?
        let stateObservedAt: String?
        let catalogEconomicsPermitted: Bool
        let settlementCapable: Bool

        enum CodingKeys: String, CodingKey {
            case state
            case source
            case coordinatorEventID = "coordinator_event_id"
            case stateObservedAt = "state_observed_at"
            case catalogEconomicsPermitted = "catalog_economics_permitted"
            case settlementCapable = "settlement_capable"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encode(source, forKey: .source)
            try encodeNullable(coordinatorEventID, forKey: .coordinatorEventID, into: &container)
            try encodeNullable(stateObservedAt, forKey: .stateObservedAt, into: &container)
            try container.encode(catalogEconomicsPermitted, forKey: .catalogEconomicsPermitted)
            try container.encode(settlementCapable, forKey: .settlementCapable)
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
        var operationGeneration: String? = nil

        enum CodingKeys: String, CodingKey {
            case available
            case requiresConfirmation = "requires_confirmation"
            case transactionKind = "transaction_kind"
            case transactionID = "transaction_id"
            case actionTimeoutSeconds = "action_timeout_seconds"
            case estimatedBytes = "estimated_bytes"
            case unavailableReason = "unavailable_reason"
            case operationGeneration = "operation_generation"
        }

        static func unavailable(_ reason: String) -> Action {
            Action(
                available: false,
                requiresConfirmation: false,
                transactionKind: nil,
                transactionID: nil,
                actionTimeoutSeconds: nil,
                estimatedBytes: nil,
                unavailableReason: reason
            )
        }

        func encode(to encoder: Encoder) throws {
            try encode(to: encoder, includeGeneration: false)
        }

        func encode(to encoder: Encoder, includeGeneration: Bool) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(available, forKey: .available)
            try container.encode(requiresConfirmation, forKey: .requiresConfirmation)
            try encodeNullable(transactionKind, forKey: .transactionKind, into: &container)
            try encodeNullable(transactionID, forKey: .transactionID, into: &container)
            try encodeNullable(actionTimeoutSeconds, forKey: .actionTimeoutSeconds, into: &container)
            try encodeNullable(estimatedBytes, forKey: .estimatedBytes, into: &container)
            try encodeNullable(unavailableReason, forKey: .unavailableReason, into: &container)
            if includeGeneration {
                try encodeNullable(operationGeneration, forKey: .operationGeneration, into: &container)
            }
        }
    }

    struct LocalVerification: Codable, Equatable, Sendable {
        let state: ModelCatalogLocalVerificationState
    }

    struct Row: Codable, Equatable, Sendable {
        let modelKey: String
        let servedModelID: String
        let displayModelID: String
        let actionModelID: String?
        let isCurrent: Bool
        var weightsPresentLocally: Bool
        var runtimeState: String
        let estimatedGB: Double?
        let fit: String
        var disabledReason: String?
        var warningCodes: [String]
        let admission: Admission
        let rateCardVersion: String?
        let rateCardGeneratedAt: String?
        let rateCardKey: String?
        let rateSource: String
        let promptRateUSDPerMillionTokens: Double?
        let completionRateUSDPerMillionTokens: Double?
        let providerShareBPS: Int?
        let providerPromptPayoutUSDPerMillionTokens: Double?
        let providerCompletionPayoutUSDPerMillionTokens: Double?
        let economicsState: String
        let demandRank: Int?
        let demandWeight: Double?
        let readyProviderCount: Int?
        let supplyDeficitScore: Double?
        let switchAction: Action
        var prepare: Action
        var evaluate: Action
        var adoptRecommendation: Action
        let cleanupStaging: Action
        var includeGenerationFields = false
        var localVerification: LocalVerification? = nil

        enum CodingKeys: String, CodingKey {
            case localVerification = "local_verification"
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
            case admission
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
            case switchAction = "switch"
            case prepare
            case evaluate
            case adoptRecommendation = "adopt_recommendation"
            case cleanupStaging = "cleanup_staging"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if includeGenerationFields {
                try container.encode(localVerification ?? LocalVerification(state: .notApplicable), forKey: .localVerification)
            }
            try container.encode(modelKey, forKey: .modelKey)
            try container.encode(servedModelID, forKey: .servedModelID)
            try container.encode(displayModelID, forKey: .displayModelID)
            try encodeNullable(actionModelID, forKey: .actionModelID, into: &container)
            try container.encode(isCurrent, forKey: .isCurrent)
            try container.encode(weightsPresentLocally, forKey: .weightsPresentLocally)
            try container.encode(runtimeState, forKey: .runtimeState)
            try encodeNullable(estimatedGB, forKey: .estimatedGB, into: &container)
            try container.encode(fit, forKey: .fit)
            try encodeNullable(disabledReason, forKey: .disabledReason, into: &container)
            try container.encode(warningCodes, forKey: .warningCodes)
            try container.encode(admission, forKey: .admission)
            try encodeNullable(rateCardVersion, forKey: .rateCardVersion, into: &container)
            try encodeNullable(rateCardGeneratedAt, forKey: .rateCardGeneratedAt, into: &container)
            try encodeNullable(rateCardKey, forKey: .rateCardKey, into: &container)
            try container.encode(rateSource, forKey: .rateSource)
            try encodeNullable(promptRateUSDPerMillionTokens, forKey: .promptRateUSDPerMillionTokens, into: &container)
            try encodeNullable(completionRateUSDPerMillionTokens, forKey: .completionRateUSDPerMillionTokens, into: &container)
            try encodeNullable(providerShareBPS, forKey: .providerShareBPS, into: &container)
            try encodeNullable(providerPromptPayoutUSDPerMillionTokens, forKey: .providerPromptPayoutUSDPerMillionTokens, into: &container)
            try encodeNullable(providerCompletionPayoutUSDPerMillionTokens, forKey: .providerCompletionPayoutUSDPerMillionTokens, into: &container)
            try container.encode(economicsState, forKey: .economicsState)
            try encodeNullable(demandRank, forKey: .demandRank, into: &container)
            try encodeNullable(demandWeight, forKey: .demandWeight, into: &container)
            try encodeNullable(readyProviderCount, forKey: .readyProviderCount, into: &container)
            try encodeNullable(supplyDeficitScore, forKey: .supplyDeficitScore, into: &container)
            try switchAction.encode(to: container.superEncoder(forKey: .switchAction), includeGeneration: includeGenerationFields)
            try prepare.encode(to: container.superEncoder(forKey: .prepare), includeGeneration: includeGenerationFields)
            try evaluate.encode(to: container.superEncoder(forKey: .evaluate), includeGeneration: includeGenerationFields)
            try adoptRecommendation.encode(to: container.superEncoder(forKey: .adoptRecommendation), includeGeneration: includeGenerationFields)
            try cleanupStaging.encode(to: container.superEncoder(forKey: .cleanupStaging), includeGeneration: includeGenerationFields)
        }
    }

    struct Recovery: Codable, Equatable, Sendable {
        let targetModelID: String
        let modelKey: String
        let action: Action
        enum CodingKeys: String, CodingKey {
            case targetModelID = "target_model_id"
            case modelKey = "model_key"
            case action
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(targetModelID, forKey: .targetModelID)
            try container.encode(modelKey, forKey: .modelKey)
            try action.encode(to: container.superEncoder(forKey: .action), includeGeneration: true)
        }
    }

    let schema: String
    let generatedAt: String
    let projectionSequence: Int
    let source: Source
    let rows: [Row]
    let warnings: [String]
    let recoveries: [Recovery]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case projectionSequence = "projection_sequence"
        case source
        case rows
        case warnings
        case recoveries
    }

    init(
        generatedAt: String,
        projectionSequence: Int,
        source: Source,
        rows: [Row],
        warnings: [String],
        recoveries: [Recovery] = []
    ) {
        schema = "model_catalog_economics.v1"
        self.generatedAt = generatedAt
        self.projectionSequence = projectionSequence
        self.source = source
        self.rows = rows
        self.warnings = warnings
        self.recoveries = recoveries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        projectionSequence = try container.decode(Int.self, forKey: .projectionSequence)
        source = try container.decode(Source.self, forKey: .source)
        let localActivation = source.projectionProtocolVersion == "2"
        rows = try container.decode([Row].self, forKey: .rows).map { row in
            var row = row
            row.includeGenerationFields = localActivation
            return row
        }
        warnings = try container.decode([String].self, forKey: .warnings)
        recoveries = try container.decodeIfPresent([Recovery].self, forKey: .recoveries) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(projectionSequence, forKey: .projectionSequence)
        try container.encode(source, forKey: .source)
        try container.encode(rows, forKey: .rows)
        try container.encode(warnings, forKey: .warnings)
        if source.projectionProtocolVersion == "2" { try container.encode(recoveries, forKey: .recoveries) }
    }
}

final class ModelCatalogEconomicsProcessState: @unchecked Sendable {
    static let shared = ModelCatalogEconomicsProcessState()

    let launchID = UUID().uuidString.lowercased()
    let startedAt = Date()
    private let lock = NSLock()
    private var sequence = 0

    func nextSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        return sequence
    }
}

/// CLI-reserved actions for a freshly verified primary catalog target. Callers
/// construct these only after resolving transaction authority; discovery alone
/// cannot make a download or activation actionable.
struct ModelCatalogLocalActions {
    let targetModelID: String
    let prepare: ModelCatalogEconomicsWire.Action
    let evaluate: ModelCatalogEconomicsWire.Action
    let adoptRecommendation: ModelCatalogEconomicsWire.Action
    let cleanupStaging: ModelCatalogEconomicsWire.Action
}

struct ModelCatalogEconomicsBuilder {
    static let protocolVersion = "1"
    static let rateCardMaxAgeSeconds = 604_800

    static func makeProjection(
        generatedAt: Date = Date(),
        cliVersion: String = CoordinatorClient.binaryVersion,
        cliBuildCommit: String = "unknown",
        processLaunchID: String = ModelCatalogEconomicsProcessState.shared.launchID,
        processStartedAt: Date = ModelCatalogEconomicsProcessState.shared.startedAt,
        projectionSequence: Int = ModelCatalogEconomicsProcessState.shared.nextSequence(),
        currentModelID: String?,
        discovery: BYOMDiscoveryWire,
        admissionStatuses: [String: BYOMAdmissionStatusWire],
        demand: AutotuneStaticSelection<DemandRank>,
        candidateCatalog: AutotuneStaticSelection<CandidateCatalog>,
        rateCard: AutotuneStaticSelection<RateCardProjection>?,
        localActivation: Bool = false,
        localActions: [String: ModelCatalogLocalActions] = [:],
        localInspection: ModelCatalogLocalInspection? = nil,
        transactionContextSHA256: String? = nil,
        recoveries: [ModelCatalogEconomicsWire.Recovery] = []
    ) -> ModelCatalogEconomicsWire {
        let hasBoundContext = transactionContextSHA256.map { value in
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        } ?? false
        let localActions = hasBoundContext ? localActions : localActions.mapValues { value in
            ModelCatalogLocalActions(targetModelID: value.targetModelID, prepare: .unavailable("action_unavailable"),
                evaluate: .unavailable("action_unavailable"), adoptRecommendation: .unavailable("action_unavailable"),
                cleanupStaging: .unavailable("action_unavailable"))
        }
        let rateCardSource = source(for: rateCard)
        let feedWarnings = demand.warnings
            .union(candidateCatalog.warnings)
            .union(rateCard?.warnings ?? [])
        var projectionWarnings = Set(feedWarnings.flatMap(mapFeedWarning))
        if rateCard == nil {
            projectionWarnings.insert("projection_unavailable")
        }

        var rows: [ModelCatalogEconomicsWire.Row] = []
        var seenCatalogKeys = Set<String>()
        for candidate in discovery.candidates {
            let row = makeCandidateRow(
                candidate,
                currentModelID: currentModelID,
                status: admissionStatuses[candidate.candidateID],
                demand: demand.value,
                rateCard: rateCard,
                rateCardSource: rateCardSource,
                feedWarnings: feedWarnings,
                generatedAt: generatedAt,
                localActions: localActivation ? candidate.catalogModelKey.flatMap { localActions[$0] } : nil
            )
            rows.append(row)
            if let catalogKey = candidate.catalogModelKey {
                seenCatalogKeys.insert(catalogKey.lowercased())
            }
        }

        for key in candidateCatalog.value.rows.keys.sorted() where !seenCatalogKeys.contains(key.lowercased()) {
            guard let catalogRow = candidateCatalog.value.rows[key] else { continue }
            let row = makeCatalogOnlyRow(
                modelKey: key,
                catalogRow: catalogRow,
                currentModelID: currentModelID,
                demand: demand.value,
                rateCardSource: rateCardSource,
                localActions: localActivation ? localActions[key] : nil
            )
            rows.append(row)
        }

        rows = rows.map { row in
            var row = row
            row.includeGenerationFields = localActivation
            if localActivation {
                let state = localInspection?.entry(modelKey: row.modelKey, modelID: row.servedModelID)?.state ?? .notApplicable
                row.localVerification = .init(state: state)
                if state != .notApplicable {
                    row.weightsPresentLocally = state == .verified
                    switch state {
                    case .unverified, .incomplete:
                        if !row.isCurrent { row.runtimeState = "verification_required" }
                        row.disabledReason = "local_verification_required"
                        row.warningCodes.removeAll { $0 == "model_not_local" || $0 == "requires_preparation" }
                        row.prepare = .unavailable("local_verification_required")
                        row.evaluate = .unavailable("local_verification_required")
                        row.adoptRecommendation = .unavailable("local_verification_required")
                    case .invalid:
                        row.warningCodes.removeAll { $0 == "model_not_local" || $0 == "requires_preparation" }
                        if !row.isCurrent { row.runtimeState = "blocked" }
                        row.disabledReason = "local_artifact_invalid"
                        row.prepare = .unavailable("local_artifact_invalid")
                        row.evaluate = .unavailable("local_artifact_invalid")
                        row.adoptRecommendation = .unavailable("local_artifact_invalid")
                    case .missing:
                        if !row.isCurrent { row.runtimeState = "needs_preparation" }
                        row.evaluate = .unavailable("local_verification_required")
                        row.adoptRecommendation = .unavailable("local_verification_required")
                    case .verified:
                        if !row.isCurrent { row.runtimeState = "ready" }
                    case .notApplicable: break
                    }
                }
            }
            return row
        }
        let source = ModelCatalogEconomicsWire.Source(
            cliVersion: cliVersion,
            cliBuildCommit: cliBuildCommit,
            processLaunchID: processLaunchID,
            processStartedAt: ModelSwitchingWireCodec.timestamp(processStartedAt),
            projectionProtocolVersion: localActivation ? "2" : protocolVersion,
            rateCardSource: rateCardSource,
            rateCardDigest: rateCard.map { sha256Hex($0.selectedBytes) },
            rateCardSignatureDigest: nil,
            demandFeedDigest: sha256Hex(demand.selectedBytes),
            candidateFeedDigest: sha256Hex(candidateCatalog.selectedBytes),
            rateCardMaxAgeSeconds: rateCardMaxAgeSeconds,
            transactionContextSHA256: localActivation && hasBoundContext ? transactionContextSHA256 : nil
        )
        return ModelCatalogEconomicsWire(
            generatedAt: ModelSwitchingWireCodec.timestamp(generatedAt),
            projectionSequence: projectionSequence,
            source: source,
            rows: rows,
            warnings: Array(projectionWarnings).sorted(),
            recoveries: localActivation && hasBoundContext ? recoveries : []
        )
    }

    private static func makeCandidateRow(
        _ candidate: BYOMDiscoveryWire.Candidate,
        currentModelID: String?,
        status: BYOMAdmissionStatusWire?,
        demand: DemandRank,
        rateCard: AutotuneStaticSelection<RateCardProjection>?,
        rateCardSource: String,
        feedWarnings: Set<AutotuneRecommendWarning>,
        generatedAt: Date,
        localActions: ModelCatalogLocalActions?
    ) -> ModelCatalogEconomicsWire.Row {
        let admission = admissionSnapshot(candidate: candidate, status: status)
        let modelKey = candidate.catalogModelKey ?? candidate.candidateID
        let pricingModelKey = coordinatorBoundCatalogModelKey(candidate: candidate, status: status)
        let coordinatorIdentityMismatched = coordinatorPricedIdentityIsMissingOrMismatched(candidate: candidate, status: status)
        let hasCoordinatorBoundCatalogIdentity = pricingModelKey != nil
        let demandRow = candidate.catalogModelKey.flatMap { demand.rows[$0] }
        let economics = economicsFields(
            modelKey: pricingModelKey,
            admission: admission,
            rateCard: rateCard,
            rateCardSource: rateCardSource,
            feedWarnings: feedWarnings,
            generatedAt: generatedAt
        )
        let candidateWarnings = hasCoordinatorBoundCatalogIdentity
            ? candidate.warningCodes.filter { $0 != BYOMDiscoveryWarning.catalogMatchUnverified.rawValue }
            : candidate.warningCodes
        var warnings = Set(candidateWarnings.flatMap(mapCandidateWarning))
        warnings.formUnion(feedWarnings.flatMap(mapFeedWarning))
        warnings.formUnion(economics.warningCodes)
        if !admission.settlementCapable {
            warnings.insert("admission_state_not_settlement_capable")
        }
        if coordinatorIdentityMismatched {
            warnings.insert("admission_state_missing")
        }
        let actionUnavailable = candidate.catalogModelKey == nil
            ? "model_not_supported"
            : "action_unavailable"
        let actions = localActions.flatMap { actions in
            currentModelMatches(actions.targetModelID, candidate.servedModelRef) ? actions : nil
        }
        // Prepared adoption stores the signed catalog key in runtime config,
        // while discovery names its canonical artifact repository. Only the
        // verified local-action binding permits treating those as aliases.
        let isCurrent = currentModelMatches(currentModelID, candidate.servedModelRef)
            || (actions != nil && currentModelMatches(currentModelID, modelKey))
        let hideLocalEconomics = actions != nil && economics.state != "trusted"
        return ModelCatalogEconomicsWire.Row(
            modelKey: modelKey,
            servedModelID: candidate.servedModelRef,
            displayModelID: candidate.displayName,
            actionModelID: actions?.targetModelID ?? candidate.candidateID,
            isCurrent: isCurrent,
            weightsPresentLocally: candidate.readinessState == "ready",
            runtimeState: runtimeState(readinessState: candidate.readinessState, isCurrent: isCurrent),
            estimatedGB: candidate.estimatedGB,
            fit: fit(candidate.fitState),
            disabledReason: disabledReason(
                admission: admission,
                candidate: candidate,
                economicsState: economics.state,
                coordinatorIdentityMismatched: coordinatorIdentityMismatched
            ),
            warningCodes: Array(warnings).sorted(),
            admission: admission,
            rateCardVersion: economics.rateCardVersion,
            rateCardGeneratedAt: economics.rateCardGeneratedAt,
            rateCardKey: economics.rateCardKey,
            rateSource: economics.rateSource,
            promptRateUSDPerMillionTokens: hideLocalEconomics ? nil : economics.promptRate,
            completionRateUSDPerMillionTokens: hideLocalEconomics ? nil : economics.completionRate,
            providerShareBPS: hideLocalEconomics ? nil : economics.providerShareBPS,
            providerPromptPayoutUSDPerMillionTokens: hideLocalEconomics ? nil : economics.providerPromptPayout,
            providerCompletionPayoutUSDPerMillionTokens: hideLocalEconomics ? nil : economics.providerCompletionPayout,
            economicsState: economics.state,
            demandRank: hideLocalEconomics ? nil : demandRow?.rank,
            demandWeight: economics.state == "trusted" ? demandRow?.demandWeight : nil,
            readyProviderCount: economics.state == "trusted" ? demandRow?.readyProviderCount : nil,
            supplyDeficitScore: economics.state == "trusted" ? demandRow?.effectiveSupplyDeficitMultiplier : nil,
            switchAction: .unavailable(actionUnavailable),
            prepare: actions?.prepare ?? .unavailable(actionUnavailable),
            evaluate: actions?.evaluate ?? .unavailable("use_models_evaluate"),
            adoptRecommendation: actions?.adoptRecommendation ?? .unavailable(actionUnavailable),
            cleanupStaging: .unavailable("staging_cleanup_not_required")
        )
    }

    private static func makeCatalogOnlyRow(
        modelKey: String,
        catalogRow: CandidateCatalog.Row,
        currentModelID: String?,
        demand: DemandRank,
        rateCardSource: String,
        localActions: ModelCatalogLocalActions?
    ) -> ModelCatalogEconomicsWire.Row {
        let admission = ModelCatalogEconomicsWire.Admission(
            state: "not_offered",
            source: "local_default",
            coordinatorEventID: nil,
            stateObservedAt: nil,
            catalogEconomicsPermitted: false,
            settlementCapable: false
        )
        let demandRow = demand.rows[modelKey]
        let unavailable = ModelCatalogEconomicsWire.Action.unavailable("no_cli_transaction_available")
        let actions = localActions.flatMap { $0.targetModelID == catalogRow.modelID ? $0 : nil }
        let isCurrent = currentModelMatches(currentModelID, catalogRow.modelID)
            || (actions != nil && currentModelMatches(currentModelID, modelKey))
        return ModelCatalogEconomicsWire.Row(
            modelKey: modelKey,
            servedModelID: catalogRow.modelID,
            displayModelID: catalogRow.modelID,
            actionModelID: actions?.targetModelID,
            isCurrent: isCurrent,
            weightsPresentLocally: false,
            runtimeState: actions == nil ? "catalog" : "needs_preparation",
            estimatedGB: Double(catalogRow.minRAMGB),
            fit: ModelFit.detectRAMGB() >= catalogRow.minRAMGB ? "fits" : "does_not_fit",
            disabledReason: actions?.prepare.available == true ? nil : "no_cli_transaction_available",
            warningCodes: ["admission_state_not_settlement_capable", "model_not_local"]
                + (actions?.prepare.available == true ? [] : ["action_unavailable"]),
            admission: admission,
            rateCardVersion: nil,
            rateCardGeneratedAt: nil,
            rateCardKey: nil,
            rateSource: conservativeRateSource(rateCardSource, permitted: false),
            promptRateUSDPerMillionTokens: nil,
            completionRateUSDPerMillionTokens: nil,
            providerShareBPS: nil,
            providerPromptPayoutUSDPerMillionTokens: nil,
            providerCompletionPayoutUSDPerMillionTokens: nil,
            economicsState: "blocked",
            demandRank: actions == nil ? demandRow?.rank : nil,
            demandWeight: nil,
            readyProviderCount: nil,
            supplyDeficitScore: nil,
            switchAction: unavailable,
            prepare: actions?.prepare ?? unavailable,
            evaluate: unavailable,
            adoptRecommendation: unavailable,
            cleanupStaging: .unavailable("staging_cleanup_not_required")
        )
    }

    private struct EconomicsFields {
        var state: String
        var rateSource: String
        var rateCardVersion: String?
        var rateCardGeneratedAt: String?
        var rateCardKey: String?
        var promptRate: Double?
        var completionRate: Double?
        var providerShareBPS: Int?
        var providerPromptPayout: Double?
        var providerCompletionPayout: Double?
        var warningCodes: Set<String>
    }

    private static func economicsFields(
        modelKey: String?,
        admission: ModelCatalogEconomicsWire.Admission,
        rateCard: AutotuneStaticSelection<RateCardProjection>?,
        rateCardSource: String,
        feedWarnings: Set<AutotuneRecommendWarning>,
        generatedAt: Date
    ) -> EconomicsFields {
        guard admission.catalogEconomicsPermitted else {
            return nullEconomics(state: "blocked", rateSource: conservativeRateSource(rateCardSource, permitted: false), warnings: ["admission_state_not_settlement_capable"])
        }
        guard let modelKey, let rateCard else {
            return nullEconomics(state: "unavailable", rateSource: "none", warnings: ["projection_unavailable"])
        }
        let blockingWarnings = economicsBlockingWarnings(feedWarnings)
        if !blockingWarnings.isEmpty {
            return nullEconomics(state: "blocked", rateSource: "none", warnings: blockingWarnings)
        }
        guard let match = rateCard.value.rowForRecommendation(modelKey: modelKey),
              match.key != "default" || modelKey == "default" else {
            return nullEconomics(state: "blocked", rateSource: "none", warnings: ["rate_multiplier_unknown"])
        }
        let state: String
        if generatedAt.timeIntervalSince(rateCard.value.generatedAt) > TimeInterval(rateCardMaxAgeSeconds)
            || feedWarnings.contains(where: isStaleWarning) {
            state = "stale"
        } else if rateCard.usedFallback || feedWarnings.contains(where: isFallbackWarning) {
            state = "fallback"
        } else {
            state = "trusted"
        }
        guard state == "trusted" else {
            return nullEconomics(
                state: state,
                rateSource: rateCardSource,
                warnings: state == "stale" ? ["feed_stale"] : ["feed_fallback"]
            )
        }
        let row = match.row
        let prompt = row.usdPerMillionPromptTokens(creditsPerMillion: rateCard.value.usdPerMillionCredits)
        let completion = row.usdPerMillionCompletionTokens(creditsPerMillion: rateCard.value.usdPerMillionCredits)
        let share = Double(row.providerShareBPS) / 10_000.0
        return EconomicsFields(
            state: "trusted",
            rateSource: rateCardSource,
            rateCardVersion: rateCard.value.version,
            rateCardGeneratedAt: ModelSwitchingWireCodec.timestamp(rateCard.value.generatedAt),
            rateCardKey: match.key,
            promptRate: prompt,
            completionRate: completion,
            providerShareBPS: Int(row.providerShareBPS),
            providerPromptPayout: prompt * share,
            providerCompletionPayout: completion * share,
            warningCodes: []
        )
    }

    private static func nullEconomics(
        state: String,
        rateSource: String,
        warnings: Set<String>
    ) -> EconomicsFields {
        EconomicsFields(
            state: state,
            rateSource: rateSource,
            rateCardVersion: nil,
            rateCardGeneratedAt: nil,
            rateCardKey: nil,
            promptRate: nil,
            completionRate: nil,
            providerShareBPS: nil,
            providerPromptPayout: nil,
            providerCompletionPayout: nil,
            warningCodes: warnings
        )
    }

    private static func admissionSnapshot(
        candidate: BYOMDiscoveryWire.Candidate,
        status: BYOMAdmissionStatusWire?
    ) -> ModelCatalogEconomicsWire.Admission {
        let source = status?.admissionStateSource ?? candidate.admissionStateSource
        let state = status?.admissionState ?? candidate.admissionState
        let permitted = source == "coordinator"
            && (state == "catalog_priced" || state == "settlement_capable")
            && coordinatorBoundCatalogModelKey(candidate: candidate, status: status) != nil
        return ModelCatalogEconomicsWire.Admission(
            state: state,
            source: source,
            coordinatorEventID: status?.coordinatorEventID,
            stateObservedAt: status?.stateObservedAt,
            catalogEconomicsPermitted: permitted,
            settlementCapable: source == "coordinator" && state == "settlement_capable"
                && coordinatorBoundCatalogModelKey(candidate: candidate, status: status) != nil
        )
    }

    private static func coordinatorBoundCatalogModelKey(
        candidate: BYOMDiscoveryWire.Candidate,
        status: BYOMAdmissionStatusWire?
    ) -> String? {
        guard let status,
              status.admissionStateSource == "coordinator",
              status.candidateID == candidate.candidateID,
              status.servedModelRef == candidate.servedModelRef,
              let statusCatalogKey = status.catalogModelKey,
              let candidateCatalogKey = candidate.catalogModelKey,
              statusCatalogKey == candidateCatalogKey
        else {
            return nil
        }
        return statusCatalogKey
    }

    private static func coordinatorPricedIdentityIsMissingOrMismatched(
        candidate: BYOMDiscoveryWire.Candidate,
        status: BYOMAdmissionStatusWire?
    ) -> Bool {
        guard let status,
              status.admissionStateSource == "coordinator",
              status.admissionState == "catalog_priced" || status.admissionState == "settlement_capable"
        else {
            return false
        }
        return coordinatorBoundCatalogModelKey(candidate: candidate, status: status) == nil
    }

    private static func source(for rateCard: AutotuneStaticSelection<RateCardProjection>?) -> String {
        guard let rateCard else { return "none" }
        return rateCard.usedFallback ? "static_signed" : "live_signed"
    }

    private static func conservativeRateSource(_ rateCardSource: String, permitted: Bool) -> String {
        permitted ? rateCardSource : "none"
    }

    private static func runtimeState(readinessState: String, isCurrent: Bool) -> String {
        if isCurrent { return "current" }
        return readinessState == "ready" ? "ready" : "needs_preparation"
    }

    private static func currentModelMatches(_ currentModelID: String?, _ modelID: String) -> Bool {
        guard let currentModelID else { return false }
        return modelKey(currentModelID) == modelKey(modelID)
    }

    private static func modelKey(_ modelID: String) -> String {
        modelID.lowercased(with: nil)
    }

    private static func fit(_ fitState: String) -> String {
        switch fitState {
        case "fits": return "fits"
        case "does_not_fit": return "does_not_fit"
        default: return "unknown"
        }
    }

    private static func disabledReason(
        admission: ModelCatalogEconomicsWire.Admission,
        candidate: BYOMDiscoveryWire.Candidate,
        economicsState: String,
        coordinatorIdentityMismatched: Bool
    ) -> String? {
        if candidate.fitState == "does_not_fit" {
            return "hardware_does_not_fit"
        }
        if candidate.readinessState != "ready" {
            return "model_not_local"
        }
        if coordinatorIdentityMismatched {
            return "admission_state_missing"
        }
        if !admission.catalogEconomicsPermitted {
            return "admission_state_not_settlement_capable"
        }
        if economicsState != "trusted" {
            return economicsState
        }
        return nil
    }

    private static func economicsBlockingWarnings(_ warnings: Set<AutotuneRecommendWarning>) -> Set<String> {
        var blocked = Set<String>()
        for warning in warnings {
            switch warning {
            case .rateCardIntegrityFailure:
                blocked.insert("feed_signature_invalid")
            case .demandRankIntegrityFailure, .candidateCatalogIntegrityFailure,
                 .rateCardUpdateRequired, .demandRankUpdateRequired, .candidateCatalogUpdateRequired:
                blocked.insert("feed_generation_mismatch")
            case .rateCardDefaultTierUsed:
                blocked.insert("rate_multiplier_unknown")
            default:
                break
            }
        }
        return blocked
    }

    private static func isFallbackWarning(_ warning: AutotuneRecommendWarning) -> Bool {
        switch warning {
        case .rateCardFallbackUsed, .demandRankFallbackUsed, .candidateCatalogFallbackUsed:
            return true
        default:
            return false
        }
    }

    private static func isStaleWarning(_ warning: AutotuneRecommendWarning) -> Bool {
        switch warning {
        case .rateCardStale, .demandRankStale, .candidateCatalogStale:
            return true
        default:
            return false
        }
    }

    private static func mapCandidateWarning(_ warning: String) -> [String] {
        switch warning {
        case BYOMDiscoveryWarning.requiresPreparation.rawValue:
            return ["model_not_local"]
        case BYOMDiscoveryWarning.catalogMatchUnverified.rawValue:
            return ["admission_state_missing"]
        case BYOMDiscoveryWarning.capabilityUnevaluated.rawValue, BYOMDiscoveryWarning.evaluationRequired.rawValue:
            return ["hardware_fit_unknown"]
        default:
            return []
        }
    }

    private static func mapFeedWarning(_ warning: AutotuneRecommendWarning) -> [String] {
        switch warning {
        case .rateCardFallbackUsed, .demandRankFallbackUsed, .candidateCatalogFallbackUsed:
            return ["feed_fallback"]
        case .rateCardStale, .demandRankStale, .candidateCatalogStale:
            return ["feed_stale"]
        case .rateCardIntegrityFailure:
            return ["feed_signature_invalid"]
        case .demandRankIntegrityFailure, .candidateCatalogIntegrityFailure,
             .rateCardUpdateRequired, .demandRankUpdateRequired, .candidateCatalogUpdateRequired:
            return ["feed_generation_mismatch"]
        case .rateCardDefaultTierUsed:
            return ["rate_multiplier_unknown"]
        case .hardwareTierUnknown:
            return ["hardware_fit_unknown"]
        default:
            return []
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
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
