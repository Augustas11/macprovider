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
            try encodeNullable(rateCardDigest, forKey: .rateCardDigest, into: &container)
            try encodeNullable(rateCardSignatureDigest, forKey: .rateCardSignatureDigest, into: &container)
            try encodeNullable(demandFeedDigest, forKey: .demandFeedDigest, into: &container)
            try encodeNullable(candidateFeedDigest, forKey: .candidateFeedDigest, into: &container)
            try container.encode(rateCardMaxAgeSeconds, forKey: .rateCardMaxAgeSeconds)
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

        enum CodingKeys: String, CodingKey {
            case available
            case requiresConfirmation = "requires_confirmation"
            case transactionKind = "transaction_kind"
            case transactionID = "transaction_id"
            case actionTimeoutSeconds = "action_timeout_seconds"
            case estimatedBytes = "estimated_bytes"
            case unavailableReason = "unavailable_reason"
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

        static func evaluateModel(transactionID: String, timeoutSeconds: Int = 10) -> Action {
            Action(
                available: true,
                requiresConfirmation: false,
                transactionKind: "evaluate_model",
                transactionID: transactionID,
                actionTimeoutSeconds: timeoutSeconds,
                estimatedBytes: nil,
                unavailableReason: nil
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(available, forKey: .available)
            try container.encode(requiresConfirmation, forKey: .requiresConfirmation)
            try encodeNullable(transactionKind, forKey: .transactionKind, into: &container)
            try encodeNullable(transactionID, forKey: .transactionID, into: &container)
            try encodeNullable(actionTimeoutSeconds, forKey: .actionTimeoutSeconds, into: &container)
            try encodeNullable(estimatedBytes, forKey: .estimatedBytes, into: &container)
            try encodeNullable(unavailableReason, forKey: .unavailableReason, into: &container)
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
        let admission: Admission
        let providerGuidance: BYOMDiscoveryWire.Guidance
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
        let prepare: Action
        let evaluate: Action
        let adoptRecommendation: Action
        let cleanupStaging: Action

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
            case admission
            case providerGuidance = "provider_guidance"
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
            try container.encode(providerGuidance, forKey: .providerGuidance)
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
            try container.encode(switchAction, forKey: .switchAction)
            try container.encode(prepare, forKey: .prepare)
            try container.encode(evaluate, forKey: .evaluate)
            try container.encode(adoptRecommendation, forKey: .adoptRecommendation)
            try container.encode(cleanupStaging, forKey: .cleanupStaging)
        }
    }

    let schema: String
    let generatedAt: String
    let projectionSequence: Int
    let source: Source
    let rows: [Row]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case projectionSequence = "projection_sequence"
        case source
        case rows
        case warnings
    }

    init(
        generatedAt: String,
        projectionSequence: Int,
        source: Source,
        rows: [Row],
        warnings: [String]
    ) {
        schema = "model_catalog_economics.v1"
        self.generatedAt = generatedAt
        self.projectionSequence = projectionSequence
        self.source = source
        self.rows = rows
        self.warnings = warnings
    }
}


private extension ModelCatalogEconomicsWire {
    func withProjectionProtocolVersion(_ version: String) -> ModelCatalogEconomicsWire {
        let nextSource = Source(
            cliVersion: source.cliVersion,
            cliBuildCommit: source.cliBuildCommit,
            processLaunchID: source.processLaunchID,
            processStartedAt: source.processStartedAt,
            projectionProtocolVersion: version,
            rateCardSource: source.rateCardSource,
            rateCardDigest: source.rateCardDigest,
            rateCardSignatureDigest: source.rateCardSignatureDigest,
            demandFeedDigest: source.demandFeedDigest,
            candidateFeedDigest: source.candidateFeedDigest,
            rateCardMaxAgeSeconds: source.rateCardMaxAgeSeconds
        )
        return ModelCatalogEconomicsWire(
            generatedAt: generatedAt,
            projectionSequence: projectionSequence,
            source: nextSource,
            rows: rows,
            warnings: warnings
        )
    }
}


struct ModelCatalogEconomicsV2Wire: Encodable, Equatable, Sendable {
    struct Action: Encodable, Equatable, Sendable {
        let available: Bool
        let requiresConfirmation: Bool
        let transactionKind: String?
        let transactionID: String?
        let actionTimeoutSeconds: Int?
        let estimatedBytes: Int64?
        let artifactIdentityDigest: String?
        let unavailableReason: String?

        enum CodingKeys: String, CodingKey {
            case available
            case requiresConfirmation = "requires_confirmation"
            case transactionKind = "transaction_kind"
            case transactionID = "transaction_id"
            case actionTimeoutSeconds = "action_timeout_seconds"
            case estimatedBytes = "estimated_bytes"
            case artifactIdentityDigest = "artifact_identity_digest"
            case unavailableReason = "unavailable_reason"
        }

        init(
            available: Bool,
            requiresConfirmation: Bool,
            transactionKind: String?,
            transactionID: String?,
            actionTimeoutSeconds: Int?,
            estimatedBytes: Int64?,
            artifactIdentityDigest: String?,
            unavailableReason: String?
        ) {
            self.available = available
            self.requiresConfirmation = requiresConfirmation
            self.transactionKind = transactionKind
            self.transactionID = transactionID
            self.actionTimeoutSeconds = actionTimeoutSeconds
            self.estimatedBytes = estimatedBytes
            self.artifactIdentityDigest = artifactIdentityDigest
            self.unavailableReason = unavailableReason
        }

        static func unavailable(_ reason: String) -> Action {
            Action(
                available: false,
                requiresConfirmation: false,
                transactionKind: nil,
                transactionID: nil,
                actionTimeoutSeconds: nil,
                estimatedBytes: nil,
                artifactIdentityDigest: nil,
                unavailableReason: reason
            )
        }

        init(_ v1: ModelCatalogEconomicsWire.Action) {
            self.available = false
            self.requiresConfirmation = false
            self.transactionKind = nil
            self.transactionID = nil
            self.actionTimeoutSeconds = nil
            self.estimatedBytes = nil
            self.artifactIdentityDigest = nil
            self.unavailableReason = v1.unavailableReason ?? "action_unavailable"
        }

        init(_ privateAction: ModelPreparationAction) {
            self.available = privateAction.available
            self.requiresConfirmation = privateAction.requiresConfirmation
            self.transactionKind = privateAction.transactionKind?.rawValue
            self.transactionID = privateAction.transactionID
            self.actionTimeoutSeconds = privateAction.actionTimeoutSeconds
            self.estimatedBytes = privateAction.estimatedBytes
            self.artifactIdentityDigest = privateAction.artifactIdentityDigest
            self.unavailableReason = privateAction.unavailableReason
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(available, forKey: .available)
            try container.encode(requiresConfirmation, forKey: .requiresConfirmation)
            try encodeNullable(transactionKind, forKey: .transactionKind, into: &container)
            try encodeNullable(transactionID, forKey: .transactionID, into: &container)
            try encodeNullable(actionTimeoutSeconds, forKey: .actionTimeoutSeconds, into: &container)
            try encodeNullable(estimatedBytes, forKey: .estimatedBytes, into: &container)
            try encodeNullable(artifactIdentityDigest, forKey: .artifactIdentityDigest, into: &container)
            try encodeNullable(unavailableReason, forKey: .unavailableReason, into: &container)
        }
    }

    struct GuidanceBinding: Encodable, Equatable, Sendable {
        let sourceSchema: String
        let sourceSHA256: String
        let sourceGeneratedAt: String
        let sourceProjectionSequence: Int?
        let sourceCoordinatorEventID: String?
        let candidateID: String
        let admissionSource: String
        let admissionState: String

        enum CodingKeys: String, CodingKey {
            case sourceSchema = "source_schema"
            case sourceSHA256 = "source_sha256"
            case sourceGeneratedAt = "source_generated_at"
            case sourceProjectionSequence = "source_projection_sequence"
            case sourceCoordinatorEventID = "source_coordinator_event_id"
            case candidateID = "candidate_id"
            case admissionSource = "admission_source"
            case admissionState = "admission_state"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sourceSchema, forKey: .sourceSchema)
            try container.encode(sourceSHA256, forKey: .sourceSHA256)
            try container.encode(sourceGeneratedAt, forKey: .sourceGeneratedAt)
            try encodeNullable(sourceProjectionSequence, forKey: .sourceProjectionSequence, into: &container)
            try encodeNullable(sourceCoordinatorEventID, forKey: .sourceCoordinatorEventID, into: &container)
            try container.encode(candidateID, forKey: .candidateID)
            try container.encode(admissionSource, forKey: .admissionSource)
            try container.encode(admissionState, forKey: .admissionState)
        }
    }

    struct Storage: Encodable, Equatable, Sendable {
        let schema: String
        let managedV3PublishedBytes: Int64?
        let managedV3ReclaimableBytes: Int64?
        let managedV3ObjectCount: Int?
        let configuredLegacyProtectedBytes: Int64?
        let configuredLegacyOtherDeviceBytes: Int64?
        let managedBudgetChargeBytes: Int64?
        let availableManagedBudgetBytes: Int64?
        let globalManagedBudgetBytes: Int64
        let configuredLegacyAccountingState: String
        let managedV3OverflowDetected: Bool
        let managedBudgetSource: String

        enum CodingKeys: String, CodingKey {
            case schema
            case managedV3PublishedBytes = "managed_v3_published_bytes"
            case managedV3ReclaimableBytes = "managed_v3_reclaimable_bytes"
            case managedV3ObjectCount = "managed_v3_object_count"
            case configuredLegacyProtectedBytes = "configured_legacy_protected_bytes"
            case configuredLegacyOtherDeviceBytes = "configured_legacy_other_device_bytes"
            case managedBudgetChargeBytes = "managed_budget_charge_bytes"
            case availableManagedBudgetBytes = "available_managed_budget_bytes"
            case globalManagedBudgetBytes = "global_managed_budget_bytes"
            case configuredLegacyAccountingState = "configured_legacy_accounting_state"
            case managedV3OverflowDetected = "managed_v3_overflow_detected"
            case managedBudgetSource = "managed_budget_source"
        }

        static let unavailable = unavailableStorage()

        static func unavailableStorage(overflowDetected: Bool = false) -> Storage {
            Storage(
                schema: "model_catalog_storage.v1",
                managedV3PublishedBytes: nil,
                managedV3ReclaimableBytes: nil,
                managedV3ObjectCount: nil,
                configuredLegacyProtectedBytes: nil,
                configuredLegacyOtherDeviceBytes: nil,
                managedBudgetChargeBytes: nil,
                availableManagedBudgetBytes: nil,
                globalManagedBudgetBytes: 0,
                configuredLegacyAccountingState: "unavailable",
                managedV3OverflowDetected: overflowDetected,
                managedBudgetSource: "default"
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schema, forKey: .schema)
            try encodeNullable(managedV3PublishedBytes, forKey: .managedV3PublishedBytes, into: &container)
            try encodeNullable(managedV3ReclaimableBytes, forKey: .managedV3ReclaimableBytes, into: &container)
            try encodeNullable(managedV3ObjectCount, forKey: .managedV3ObjectCount, into: &container)
            try encodeNullable(configuredLegacyProtectedBytes, forKey: .configuredLegacyProtectedBytes, into: &container)
            try encodeNullable(configuredLegacyOtherDeviceBytes, forKey: .configuredLegacyOtherDeviceBytes, into: &container)
            try encodeNullable(managedBudgetChargeBytes, forKey: .managedBudgetChargeBytes, into: &container)
            try encodeNullable(availableManagedBudgetBytes, forKey: .availableManagedBudgetBytes, into: &container)
            try container.encode(globalManagedBudgetBytes, forKey: .globalManagedBudgetBytes)
            try container.encode(configuredLegacyAccountingState, forKey: .configuredLegacyAccountingState)
            try container.encode(managedV3OverflowDetected, forKey: .managedV3OverflowDetected)
            try container.encode(managedBudgetSource, forKey: .managedBudgetSource)
        }
    }

    struct CleanupTarget: Encodable, Equatable, Sendable {
        let artifactIdentityDigest: String
        let displayModelID: String
        let modelRevision: String
        let artifactID: String
        let releaseID: String
        let modelKey: String?
        let eventModelKey: String
        let rootIdentityDigest: String
        let receiptSHA256: String
        let estimatedBytes: Int64
        let keepSetStatus: String
        let protectedReason: String?
        let cleanup: Action

        enum CodingKeys: String, CodingKey {
            case artifactIdentityDigest = "artifact_identity_digest"
            case displayModelID = "display_model_id"
            case modelRevision = "model_revision"
            case artifactID = "artifact_id"
            case releaseID = "release_id"
            case modelKey = "model_key"
            case eventModelKey = "event_model_key"
            case rootIdentityDigest = "root_identity_digest"
            case receiptSHA256 = "receipt_sha256"
            case estimatedBytes = "estimated_bytes"
            case keepSetStatus = "keep_set_status"
            case protectedReason = "protected_reason"
            case cleanup
        }
    }

    struct Row: Encodable, Equatable, Sendable {
        let modelKey: String
        let servedModelID: String
        let displayModelID: String
        let actionModelID: String?
        let candidateID: String?
        let providerGuidance: BYOMDiscoveryWire.Guidance?
        let guidanceBinding: GuidanceBinding?
        let isCurrent: Bool
        let weightsPresentLocally: Bool
        let runtimeState: String
        let estimatedGB: Double?
        let fit: String
        let disabledReason: String?
        let warningCodes: [String]
        let admission: ModelCatalogEconomicsWire.Admission
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
        let prepare: Action
        let evaluate: Action
        let adoptRecommendation: Action
        let cleanupStaging: Action
        let cleanupPublished: Action

        enum CodingKeys: String, CodingKey {
            case modelKey = "model_key"
            case servedModelID = "served_model_id"
            case displayModelID = "display_model_id"
            case actionModelID = "action_model_id"
            case candidateID = "candidate_id"
            case providerGuidance = "provider_guidance"
            case guidanceBinding = "guidance_binding"
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
            case cleanupPublished = "cleanup_published"
        }

        init(
            v1: ModelCatalogEconomicsWire.Row,
            candidate: BYOMDiscoveryWire.Candidate?,
            binding: GuidanceBinding?,
            guidance: BYOMDiscoveryWire.Guidance?,
            forcedUnavailableReason: String? = nil
        ) {
            let offerRejected = v1.admission.source == "coordinator" && v1.admission.state == "offer_rejected"
            let forceUnavailable = forcedUnavailableReason != nil || offerRejected
            let actionUnavailableReason: String
            if let forcedUnavailableReason {
                actionUnavailableReason = forcedUnavailableReason
            } else if offerRejected {
                actionUnavailableReason = "action_unavailable"
            } else if candidate == nil {
                actionUnavailableReason = "no_local_candidate"
            } else {
                actionUnavailableReason = "no_cli_transaction_available"
            }
            let unavailable = Action.unavailable(actionUnavailableReason)
            self.modelKey = v1.modelKey
            self.servedModelID = v1.servedModelID
            self.displayModelID = v1.displayModelID
            self.actionModelID = v1.actionModelID
            self.candidateID = candidate?.candidateID
            self.providerGuidance = guidance
            self.guidanceBinding = binding
            self.isCurrent = v1.isCurrent
            self.weightsPresentLocally = v1.weightsPresentLocally
            self.runtimeState = v1.runtimeState
            self.estimatedGB = v1.estimatedGB
            self.fit = v1.fit
            self.disabledReason = forceUnavailable ? actionUnavailableReason : v1.disabledReason
            self.warningCodes = forceUnavailable ? Array(Set(v1.warningCodes + [actionUnavailableReason]).sorted()) : v1.warningCodes
            self.admission = forceUnavailable ? ModelCatalogEconomicsWire.Admission(
                state: v1.admission.state,
                source: v1.admission.source,
                coordinatorEventID: v1.admission.coordinatorEventID,
                stateObservedAt: v1.admission.stateObservedAt,
                catalogEconomicsPermitted: false,
                settlementCapable: false
            ) : v1.admission
            self.rateCardVersion = forceUnavailable ? nil : v1.rateCardVersion
            self.rateCardGeneratedAt = forceUnavailable ? nil : v1.rateCardGeneratedAt
            self.rateCardKey = forceUnavailable ? nil : v1.rateCardKey
            self.rateSource = forceUnavailable ? "none" : v1.rateSource
            self.promptRateUSDPerMillionTokens = forceUnavailable ? nil : v1.promptRateUSDPerMillionTokens
            self.completionRateUSDPerMillionTokens = forceUnavailable ? nil : v1.completionRateUSDPerMillionTokens
            self.providerShareBPS = forceUnavailable ? nil : v1.providerShareBPS
            self.providerPromptPayoutUSDPerMillionTokens = forceUnavailable ? nil : v1.providerPromptPayoutUSDPerMillionTokens
            self.providerCompletionPayoutUSDPerMillionTokens = forceUnavailable ? nil : v1.providerCompletionPayoutUSDPerMillionTokens
            self.economicsState = forceUnavailable ? "unavailable" : v1.economicsState
            self.demandRank = forceUnavailable ? nil : v1.demandRank
            self.demandWeight = forceUnavailable ? nil : v1.demandWeight
            self.readyProviderCount = forceUnavailable ? nil : v1.readyProviderCount
            self.supplyDeficitScore = forceUnavailable ? nil : v1.supplyDeficitScore
            self.switchAction = unavailable
            self.prepare = unavailable
            self.evaluate = Action(v1.evaluate)
            self.adoptRecommendation = unavailable
            self.cleanupStaging = Action(v1.cleanupStaging)
            self.cleanupPublished = Action.unavailable("cleanup_unavailable_without_private_store")
        }
    }

    let schema: String
    let generatedAt: String
    let projectionSequence: Int
    let source: ModelCatalogEconomicsWire.Source
    let storage: Storage
    let rows: [Row]
    let cleanupTargets: [CleanupTarget]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case projectionSequence = "projection_sequence"
        case source
        case storage
        case rows
        case cleanupTargets = "cleanup_targets"
        case warnings
    }

    init(
        v1: ModelCatalogEconomicsWire,
        rows: [Row],
        storage: Storage = .unavailable,
        cleanupTargets: [CleanupTarget] = [],
        warnings: [String]
    ) {
        self.schema = "model_catalog_economics.v2"
        self.generatedAt = v1.generatedAt
        self.projectionSequence = v1.projectionSequence
        self.source = v1.source
        self.storage = storage
        self.rows = rows
        self.cleanupTargets = cleanupTargets
        self.warnings = warnings
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

struct ModelCatalogEconomicsBuilder {
    static let protocolVersion = "1"
    static let rateCardMaxAgeSeconds = 604_800

    struct PrivateStorageBudget: Equatable, Sendable {
        let globalManagedBudgetBytes: Int64
        let managedBudgetSource = "default"

        private init(globalManagedBudgetBytes: Int64) {
            self.globalManagedBudgetBytes = globalManagedBudgetBytes
        }

        static func defaultBudget(volumeCapacityBytes: Int64) -> PrivateStorageBudget? {
            guard volumeCapacityBytes > 0 else { return nil }
            let quotient = volumeCapacityBytes / 100
            let remainder = volumeCapacityBytes % 100
            let multipliedQuotient = quotient.multipliedReportingOverflow(by: 70)
            guard !multipliedQuotient.overflow else { return nil }
            let multipliedRemainder = remainder * 70
            let computed = multipliedQuotient.partialValue.addingReportingOverflow(multipliedRemainder / 100)
            guard !computed.overflow else { return nil }
            let capped = min(Int64(ModelPreparationContracts.maxEstimatedBytes), computed.partialValue)
            guard capped > 0, capped <= ModelPreparationContracts.maxJavaScriptSafeInteger else { return nil }
            return PrivateStorageBudget(globalManagedBudgetBytes: capped)
        }
    }

    struct PrivateStorageSnapshot: Equatable, Sendable {
        let inventory: ModelPreparationInventoryRecord?
        let budget: PrivateStorageBudget?
        let overflowDetected: Bool

        fileprivate init(
            inventory: ModelPreparationInventoryRecord?,
            budget: PrivateStorageBudget?,
            overflowDetected: Bool
        ) {
            self.inventory = inventory
            self.budget = budget
            self.overflowDetected = overflowDetected
        }

        static func unavailable(overflowDetected: Bool = false) -> PrivateStorageSnapshot {
            PrivateStorageSnapshot(inventory: nil, budget: nil, overflowDetected: overflowDetected)
        }
    }

    static func loadPrivateStorageSnapshot(
        store: ModelPreparationPrivateStore,
        rootLocator: ModelPreparationRootLocator,
        volumeCapacityBytes: Int64,
        overflowDetected: Bool = false
    ) -> PrivateStorageSnapshot {
        if overflowDetected { return .unavailable(overflowDetected: true) }
        do {
            let payload = try store.readRecord(kind: .publishedInventory, rootLocator: rootLocator)
            return loadPrivateStorageSnapshotPayload(
                payload,
                rootLocator: rootLocator,
                volumeCapacityBytes: volumeCapacityBytes
            )
        } catch {
            return .unavailable()
        }
    }

    private static func loadPrivateStorageSnapshotPayload(
        _ payload: Data?,
        rootLocator: ModelPreparationRootLocator,
        volumeCapacityBytes: Int64
    ) -> PrivateStorageSnapshot {
        guard let budget = PrivateStorageBudget.defaultBudget(volumeCapacityBytes: volumeCapacityBytes),
              let payload
        else {
            return .unavailable()
        }
        do {
            let inventory = try ModelPreparationContracts.decode(
                ModelPreparationInventoryRecord.self,
                from: payload,
                maxBytes: ModelPreparationContracts.inventoryMaxBytes
            )
            guard inventory.root == rootLocator else { return .unavailable() }
            return PrivateStorageSnapshot(inventory: inventory, budget: budget, overflowDetected: false)
        } catch {
            return .unavailable()
        }
    }

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
        rateCard: AutotuneStaticSelection<RateCardProjection>?
    ) -> ModelCatalogEconomicsWire {
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
                generatedAt: generatedAt
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
                rateCardSource: rateCardSource
            )
            rows.append(row)
        }

        let source = ModelCatalogEconomicsWire.Source(
            cliVersion: cliVersion,
            cliBuildCommit: cliBuildCommit,
            processLaunchID: processLaunchID,
            processStartedAt: ModelSwitchingWireCodec.timestamp(processStartedAt),
            projectionProtocolVersion: protocolVersion,
            rateCardSource: rateCardSource,
            rateCardDigest: rateCard.map { sha256Hex($0.selectedBytes) },
            rateCardSignatureDigest: nil,
            demandFeedDigest: sha256Hex(demand.selectedBytes),
            candidateFeedDigest: sha256Hex(candidateCatalog.selectedBytes),
            rateCardMaxAgeSeconds: rateCardMaxAgeSeconds
        )
        return ModelCatalogEconomicsWire(
            generatedAt: ModelSwitchingWireCodec.timestamp(generatedAt),
            projectionSequence: projectionSequence,
            source: source,
            rows: rows,
            warnings: Array(projectionWarnings).sorted()
        )
    }

    static func makeProjectionV2(
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
        rateCard: AutotuneStaticSelection<RateCardProjection>,
        privateStorage: PrivateStorageSnapshot? = nil
    ) -> ModelCatalogEconomicsV2Wire {
        let v1Document = makeProjection(
            generatedAt: generatedAt,
            cliVersion: cliVersion,
            cliBuildCommit: cliBuildCommit,
            processLaunchID: processLaunchID,
            processStartedAt: processStartedAt,
            projectionSequence: projectionSequence,
            currentModelID: currentModelID,
            discovery: discovery,
            admissionStatuses: admissionStatuses,
            demand: demand,
            candidateCatalog: candidateCatalog,
            rateCard: rateCard
        )
        let v1 = v1Document.withProjectionProtocolVersion("model_catalog_economics.v2")
        var candidatesByID: [String: BYOMDiscoveryWire.Candidate] = [:]
        for candidate in discovery.candidates where candidatesByID[candidate.candidateID] == nil {
            candidatesByID[candidate.candidateID] = candidate
        }
        let discoveryText = try? ModelSwitchingWireCodec.encode(discovery)
        let discoveryDigest = discoveryText.map { sha256Hex(Data($0.utf8)) }
        let discoveryFresh = discoveryText != nil && sourceGeneratedAtIsFresh(discovery.generatedAt, at: generatedAt)
        let rows = v1.rows.map { row -> ModelCatalogEconomicsV2Wire.Row in
            guard let actionModelID = row.actionModelID, let candidate = candidatesByID[actionModelID] else {
                return ModelCatalogEconomicsV2Wire.Row(v1: catalogOnlyV2Sentinel(row), candidate: nil, binding: nil, guidance: nil)
            }
            if let status = admissionStatuses[actionModelID], status.admissionStateSource == "coordinator" {
                guard let statusText = try? ModelSwitchingWireCodec.encode(status),
                      coordinatorStatusBinds(status, to: candidate, at: generatedAt)
                else {
                    return ModelCatalogEconomicsV2Wire.Row(
                        v1: row,
                        candidate: candidate,
                        binding: nil,
                        guidance: nil,
                        forcedUnavailableReason: "source_binding_invalid"
                    )
                }
                if status.admissionState == "offer_rejected" {
                    return ModelCatalogEconomicsV2Wire.Row(
                        v1: row,
                        candidate: candidate,
                        binding: nil,
                        guidance: nil,
                        forcedUnavailableReason: "action_unavailable"
                    )
                }
                let binding = ModelCatalogEconomicsV2Wire.GuidanceBinding(
                    sourceSchema: status.schema,
                    sourceSHA256: sha256Hex(Data(statusText.utf8)),
                    sourceGeneratedAt: status.generatedAt,
                    sourceProjectionSequence: nil,
                    sourceCoordinatorEventID: status.coordinatorEventID,
                    candidateID: status.candidateID,
                    admissionSource: status.admissionStateSource,
                    admissionState: status.admissionState
                )
                return ModelCatalogEconomicsV2Wire.Row(v1: row, candidate: candidate, binding: binding, guidance: status.providerGuidance)
            }
            guard discoveryFresh, let discoveryDigest else {
                return ModelCatalogEconomicsV2Wire.Row(
                    v1: row,
                    candidate: candidate,
                    binding: nil,
                    guidance: nil,
                    forcedUnavailableReason: "source_binding_invalid"
                )
            }
            let binding = ModelCatalogEconomicsV2Wire.GuidanceBinding(
                sourceSchema: discovery.schema,
                sourceSHA256: discoveryDigest,
                sourceGeneratedAt: discovery.generatedAt,
                sourceProjectionSequence: discovery.projectionSequence,
                sourceCoordinatorEventID: nil,
                candidateID: candidate.candidateID,
                admissionSource: row.admission.source,
                admissionState: row.admission.state
            )
            return ModelCatalogEconomicsV2Wire.Row(v1: row, candidate: candidate, binding: binding, guidance: candidate.providerGuidance)
        }
        let storageProjection = makePrivateStorageProjection(privateStorage)
        return ModelCatalogEconomicsV2Wire(
            v1: v1,
            rows: rows,
            storage: storageProjection.storage,
            cleanupTargets: storageProjection.cleanupTargets,
            warnings: v1.warnings
        )
    }

    private static let v2SourceFreshnessSeconds: TimeInterval = 300

    private static func makePrivateStorageProjection(
        _ snapshot: PrivateStorageSnapshot?
    ) -> (storage: ModelCatalogEconomicsV2Wire.Storage, cleanupTargets: [ModelCatalogEconomicsV2Wire.CleanupTarget]) {
        guard let snapshot else { return (.unavailable, []) }
        if snapshot.overflowDetected { return (.unavailableStorage(overflowDetected: true), []) }
        guard let inventory = snapshot.inventory, let budget = snapshot.budget else { return (.unavailable, []) }

        do {
            let targets = try inventory.targets.map { try v2CleanupTarget(from: $0) }
            guard targets.map(\.artifactIdentityDigest) == targets.map(\.artifactIdentityDigest).sorted() else {
                return (.unavailable, [])
            }
            var publishedBytes: Int64 = 0
            var reclaimableBytes: Int64 = 0
            for target in targets {
                publishedBytes = try checkedAdd(publishedBytes, target.estimatedBytes)
                if target.keepSetStatus == ModelPreparationKeepSetStatus.reclaimable.rawValue {
                    reclaimableBytes = try checkedAdd(reclaimableBytes, target.estimatedBytes)
                }
            }
            try ModelPreparationContracts.requireNonNegativeSafeInteger(targets.count, field: "managed_v3_object_count")
            let chargeBytes = publishedBytes
            let availableBudget = max(0, budget.globalManagedBudgetBytes - chargeBytes)
            let storage = ModelCatalogEconomicsV2Wire.Storage(
                schema: "model_catalog_storage.v1",
                managedV3PublishedBytes: publishedBytes,
                managedV3ReclaimableBytes: reclaimableBytes,
                managedV3ObjectCount: targets.count,
                configuredLegacyProtectedBytes: 0,
                configuredLegacyOtherDeviceBytes: 0,
                managedBudgetChargeBytes: chargeBytes,
                availableManagedBudgetBytes: availableBudget,
                globalManagedBudgetBytes: budget.globalManagedBudgetBytes,
                configuredLegacyAccountingState: "not_configured",
                managedV3OverflowDetected: false,
                managedBudgetSource: budget.managedBudgetSource
            )
            return (storage, targets)
        } catch {
            return (.unavailable, [])
        }
    }

    private static func v2CleanupTarget(from target: ModelPreparationCleanupTarget) throws -> ModelCatalogEconomicsV2Wire.CleanupTarget {
        try ModelPreparationContracts.requireHex64(target.artifactIdentityDigest, field: "artifact_identity_digest")
        try ModelPreparationContracts.requireHex64(target.rootIdentityDigest, field: "root_identity_digest")
        try ModelPreparationContracts.requireHex64(target.receiptSHA256, field: "receipt_sha256")
        try ModelPreparationContracts.requireNonNegativeSafeInteger(target.estimatedBytes, field: "estimated_bytes")
        try ModelPreparationContracts.requireSafeString(target.eventModelKey, field: "event_model_key")
        switch target.keepSetStatus {
        case .reclaimable:
            try ModelPreparationContracts.validateCleanupBinding(rowAction: target.cleanup, target: target)
            guard target.cleanup.available,
                  target.cleanup.transactionKind == .cleanupPublishedArtifact,
                  target.cleanup.artifactIdentityDigest == target.artifactIdentityDigest,
                  target.cleanup.estimatedBytes == target.estimatedBytes,
                  target.protectedReason == nil
            else {
                throw ModelPreparationContractError.malformed("reclaimable cleanup")
            }
        case .protected:
            guard let protectedReason = target.protectedReason else {
                throw ModelPreparationContractError.malformed("protected_reason")
            }
            try ModelPreparationContracts.requireSafeString(protectedReason, field: "protected_reason", maxUTF8Bytes: 512)
            guard !target.cleanup.available,
                  target.cleanup.transactionKind == nil,
                  target.cleanup.transactionID == nil,
                  target.cleanup.actionTimeoutSeconds == nil,
                  target.cleanup.estimatedBytes == nil,
                  target.cleanup.artifactIdentityDigest == nil
            else {
                throw ModelPreparationContractError.malformed("protected cleanup")
            }
        }
        return ModelCatalogEconomicsV2Wire.CleanupTarget(
            artifactIdentityDigest: target.artifactIdentityDigest,
            displayModelID: target.displayModelID,
            modelRevision: target.modelRevision,
            artifactID: target.artifactID,
            releaseID: target.releaseID,
            modelKey: target.modelKey,
            eventModelKey: target.eventModelKey,
            rootIdentityDigest: target.rootIdentityDigest,
            receiptSHA256: target.receiptSHA256,
            estimatedBytes: target.estimatedBytes,
            keepSetStatus: target.keepSetStatus.rawValue,
            protectedReason: target.protectedReason,
            cleanup: ModelCatalogEconomicsV2Wire.Action(target.cleanup)
        )
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ModelPreparationContractError.malformed("integer overflow") }
        try ModelPreparationContracts.requireNonNegativeSafeInteger(result.partialValue, field: "sum")
        return result.partialValue
    }

    private static func coordinatorStatusBinds(
        _ status: BYOMAdmissionStatusWire,
        to candidate: BYOMDiscoveryWire.Candidate,
        at projectionTime: Date
    ) -> Bool {
        guard status.admissionStateSource == "coordinator",
              status.candidateID == candidate.candidateID,
              status.servedModelRef == candidate.servedModelRef,
              status.catalogModelKey == candidate.catalogModelKey,
              sourceGeneratedAtIsFresh(status.generatedAt, at: projectionTime)
        else {
            return false
        }
        return true
    }

    private static func sourceGeneratedAtIsFresh(_ value: String, at projectionTime: Date) -> Bool {
        guard let sourceTime = parseWireTimestamp(value) else { return false }
        let age = projectionTime.timeIntervalSince(sourceTime)
        return age >= 0 && age <= v2SourceFreshnessSeconds
    }

    private static func parseWireTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    private static func catalogOnlyV2Sentinel(_ row: ModelCatalogEconomicsWire.Row) -> ModelCatalogEconomicsWire.Row {
        ModelCatalogEconomicsWire.Row(
            modelKey: row.modelKey,
            servedModelID: row.servedModelID,
            displayModelID: row.displayModelID,
            actionModelID: nil,
            isCurrent: row.isCurrent,
            weightsPresentLocally: false,
            runtimeState: "catalog",
            estimatedGB: row.estimatedGB,
            fit: row.fit,
            disabledReason: "no_cli_transaction_available",
            warningCodes: row.warningCodes,
            admission: ModelCatalogEconomicsWire.Admission(
                state: "not_offered",
                source: "local_default",
                coordinatorEventID: nil,
                stateObservedAt: nil,
                catalogEconomicsPermitted: false,
                settlementCapable: false
            ),
            providerGuidance: BYOMDiscoveryGuidance.guidance(forAdmissionState: "not_offered", warnings: []),
            rateCardVersion: nil,
            rateCardGeneratedAt: nil,
            rateCardKey: nil,
            rateSource: "none",
            promptRateUSDPerMillionTokens: nil,
            completionRateUSDPerMillionTokens: nil,
            providerShareBPS: nil,
            providerPromptPayoutUSDPerMillionTokens: nil,
            providerCompletionPayoutUSDPerMillionTokens: nil,
            economicsState: "unavailable",
            demandRank: nil,
            demandWeight: nil,
            readyProviderCount: nil,
            supplyDeficitScore: nil,
            switchAction: .unavailable("no_cli_transaction_available"),
            prepare: .unavailable("no_cli_transaction_available"),
            evaluate: .unavailable("no_cli_transaction_available"),
            adoptRecommendation: .unavailable("no_cli_transaction_available"),
            cleanupStaging: .unavailable("staging_cleanup_not_required")
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
        generatedAt: Date
    ) -> ModelCatalogEconomicsWire.Row {
        let admission = admissionSnapshot(candidate: candidate, status: status)
        let modelKey = candidate.catalogModelKey ?? candidate.candidateID
        let pricingModelKey = coordinatorBoundCatalogModelKey(candidate: candidate, status: status)
        let coordinatorIdentityMismatched = coordinatorPricedIdentityIsMissingOrMismatched(candidate: candidate, status: status)
        let hasCoordinatorBoundCatalogIdentity = pricingModelKey != nil
        let demandRow = candidate.catalogModelKey.flatMap { demand.rows[$0] }
        let isCurrent = currentModelMatches(currentModelID, candidate.servedModelRef)
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
        let evaluateAction = Self.evaluateAction(for: candidate)
        return ModelCatalogEconomicsWire.Row(
            modelKey: modelKey,
            servedModelID: candidate.servedModelRef,
            displayModelID: candidate.displayName,
            actionModelID: candidate.candidateID,
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
            providerGuidance: status?.providerGuidance ?? candidate.providerGuidance,
            rateCardVersion: economics.rateCardVersion,
            rateCardGeneratedAt: economics.rateCardGeneratedAt,
            rateCardKey: economics.rateCardKey,
            rateSource: economics.rateSource,
            promptRateUSDPerMillionTokens: economics.promptRate,
            completionRateUSDPerMillionTokens: economics.completionRate,
            providerShareBPS: economics.providerShareBPS,
            providerPromptPayoutUSDPerMillionTokens: economics.providerPromptPayout,
            providerCompletionPayoutUSDPerMillionTokens: economics.providerCompletionPayout,
            economicsState: economics.state,
            demandRank: demandRow?.rank,
            demandWeight: economics.state == "trusted" ? demandRow?.demandWeight : nil,
            readyProviderCount: economics.state == "trusted" ? demandRow?.readyProviderCount : nil,
            supplyDeficitScore: economics.state == "trusted" ? demandRow?.effectiveSupplyDeficitMultiplier : nil,
            switchAction: .unavailable(actionUnavailable),
            prepare: .unavailable(actionUnavailable),
            evaluate: evaluateAction,
            adoptRecommendation: .unavailable(actionUnavailable),
            cleanupStaging: .unavailable("staging_cleanup_not_required")
        )
    }

    private static func evaluateAction(for candidate: BYOMDiscoveryWire.Candidate) -> ModelCatalogEconomicsWire.Action {
        let evaluatable = BYOMWithdrawalBuilder.isStableCandidateID(candidate.candidateID)
            && candidate.readinessState == "ready"
            && candidate.fitState != "does_not_fit"
            && Set(candidate.warningCodes).isDisjoint(with: BYOMDiscoveryWarning.submitBlockingWarningCodes)
        guard evaluatable else {
            return .unavailable("candidate_not_evaluatable")
        }
        return .evaluateModel(transactionID: UUID().uuidString.lowercased())
    }

    private static func makeCatalogOnlyRow(
        modelKey: String,
        catalogRow: CandidateCatalog.Row,
        currentModelID: String?,
        demand: DemandRank,
        rateCardSource: String
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
        let isCurrent = currentModelMatches(currentModelID, catalogRow.modelID)
        return ModelCatalogEconomicsWire.Row(
            modelKey: modelKey,
            servedModelID: catalogRow.modelID,
            displayModelID: catalogRow.modelID,
            actionModelID: nil,
            isCurrent: isCurrent,
            weightsPresentLocally: false,
            runtimeState: "catalog",
            estimatedGB: Double(catalogRow.minRAMGB),
            fit: ModelFit.detectRAMGB() >= catalogRow.minRAMGB ? "fits" : "does_not_fit",
            disabledReason: "no_cli_transaction_available",
            warningCodes: ["admission_state_not_settlement_capable", "model_not_local", "action_unavailable"],
            admission: admission,
            providerGuidance: BYOMDiscoveryGuidance.guidance(forAdmissionState: "not_offered", warnings: []),
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
            demandRank: demandRow?.rank,
            demandWeight: nil,
            readyProviderCount: nil,
            supplyDeficitScore: nil,
            switchAction: unavailable,
            prepare: unavailable,
            evaluate: unavailable,
            adoptRecommendation: unavailable,
            cleanupStaging: ModelCatalogEconomicsWire.Action.unavailable("staging_cleanup_not_required")
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
