import CryptoKit
import Foundation
import MacProviderCore
import Security

enum BYOMDiscoveryWarning: String, Codable, Sendable {
    case candidateIDUnstable = "candidate_id_unstable"
    case adapterUnavailable = "adapter_unavailable"
    case adapterTimeout = "adapter_timeout"
    case adapterRejectedNonLoopback = "adapter_rejected_non_loopback"
    case adapterMalformedResponse = "adapter_malformed_response"
    case adapterResponseTruncated = "adapter_response_truncated"
    case catalogMatchUnverified = "catalog_match_unverified"
    case capabilityUnevaluated = "capability_unevaluated"
    case evaluationRequired = "evaluation_required"
    case evaluationFailed = "evaluation_failed"
    case requiresPreparation = "requires_preparation"
    case namespacePermissionInvalid = "namespace_permission_invalid"
}

struct BYOMDiscoveryWire: Codable, Equatable, Sendable {
    struct Adapter: Codable, Equatable, Sendable {
        let runtimeSource: String
        let status: String
        let originClass: String?
        let warningCodes: [String]

        enum CodingKeys: String, CodingKey {
            case runtimeSource = "runtime_source"
            case status
            case originClass = "origin_class"
            case warningCodes = "warning_codes"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(runtimeSource, forKey: .runtimeSource)
            try container.encode(status, forKey: .status)
            if let originClass {
                try container.encode(originClass, forKey: .originClass)
            } else {
                try container.encodeNil(forKey: .originClass)
            }
            try container.encode(warningCodes, forKey: .warningCodes)
        }

        init(runtimeSource: String, status: String, originClass: String?, warningCodes: [String]) {
            self.runtimeSource = runtimeSource
            self.status = status
            self.originClass = originClass
            self.warningCodes = warningCodes
        }
    }

    struct Capabilities: Codable, Equatable, Sendable {
        let chatCompletions: Bool?
        let streaming: Bool?
        let toolCallPassthrough: Bool?
        let structuredOutputPassthrough: Bool?
        let jsonMode: Bool?
        let usageReporting: Bool?
        let maxContextTokens: Int?
        let quantization: String?
        let family: String?
        let runtimeVersion: String?

        enum CodingKeys: String, CodingKey {
            case chatCompletions = "chat_completions"
            case streaming
            case toolCallPassthrough = "tool_call_passthrough"
            case structuredOutputPassthrough = "structured_output_passthrough"
            case jsonMode = "json_mode"
            case usageReporting = "usage_reporting"
            case maxContextTokens = "max_context_tokens"
            case quantization
            case family
            case runtimeVersion = "runtime_version"
        }

        static let unknown = Capabilities(
            chatCompletions: nil,
            streaming: nil,
            toolCallPassthrough: nil,
            structuredOutputPassthrough: nil,
            jsonMode: nil,
            usageReporting: nil,
            maxContextTokens: nil,
            quantization: nil,
            family: nil,
            runtimeVersion: nil
        )

        init(
            chatCompletions: Bool?,
            streaming: Bool?,
            toolCallPassthrough: Bool?,
            structuredOutputPassthrough: Bool?,
            jsonMode: Bool?,
            usageReporting: Bool?,
            maxContextTokens: Int?,
            quantization: String?,
            family: String?,
            runtimeVersion: String?
        ) {
            self.chatCompletions = chatCompletions
            self.streaming = streaming
            self.toolCallPassthrough = toolCallPassthrough
            self.structuredOutputPassthrough = structuredOutputPassthrough
            self.jsonMode = jsonMode
            self.usageReporting = usageReporting
            self.maxContextTokens = maxContextTokens
            self.quantization = quantization
            self.family = family
            self.runtimeVersion = runtimeVersion
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try encodeNullable(chatCompletions, forKey: .chatCompletions, into: &container)
            try encodeNullable(streaming, forKey: .streaming, into: &container)
            try encodeNullable(toolCallPassthrough, forKey: .toolCallPassthrough, into: &container)
            try encodeNullable(structuredOutputPassthrough, forKey: .structuredOutputPassthrough, into: &container)
            try encodeNullable(jsonMode, forKey: .jsonMode, into: &container)
            try encodeNullable(usageReporting, forKey: .usageReporting, into: &container)
            try encodeNullable(maxContextTokens, forKey: .maxContextTokens, into: &container)
            try encodeNullable(quantization, forKey: .quantization, into: &container)
            try encodeNullable(family, forKey: .family, into: &container)
            try encodeNullable(runtimeVersion, forKey: .runtimeVersion, into: &container)
        }

        private func encodeNullable<T: Encodable>(
            _ value: T?,
            forKey key: CodingKeys,
            into container: inout KeyedEncodingContainer<CodingKeys>
        ) throws {
            if let value {
                try container.encode(value, forKey: key)
            } else {
                try container.encodeNil(forKey: key)
            }
        }
    }

    struct Guidance: Codable, Equatable, Sendable {
        let stateLabelKey: String
        let stateMeaningKey: String
        let nextAction: String
        let transitionReasonCode: String?
        let earningPathClass: String

        enum CodingKeys: String, CodingKey {
            case stateLabelKey = "state_label_key"
            case stateMeaningKey = "state_meaning_key"
            case nextAction = "next_action"
            case transitionReasonCode = "transition_reason_code"
            case earningPathClass = "earning_path_class"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(stateLabelKey, forKey: .stateLabelKey)
            try container.encode(stateMeaningKey, forKey: .stateMeaningKey)
            try container.encode(nextAction, forKey: .nextAction)
            if let transitionReasonCode {
                try container.encode(transitionReasonCode, forKey: .transitionReasonCode)
            } else {
                try container.encodeNil(forKey: .transitionReasonCode)
            }
            try container.encode(earningPathClass, forKey: .earningPathClass)
        }

        init(
            stateLabelKey: String,
            stateMeaningKey: String,
            nextAction: String,
            transitionReasonCode: String?,
            earningPathClass: String
        ) {
            self.stateLabelKey = stateLabelKey
            self.stateMeaningKey = stateMeaningKey
            self.nextAction = nextAction
            self.transitionReasonCode = transitionReasonCode
            self.earningPathClass = earningPathClass
        }
    }

    struct Candidate: Codable, Equatable, Sendable {
        let candidateID: String
        let runtimeSource: String
        let displayName: String
        let servedModelRef: String
        let catalogModelKey: String?
        let identityState: String
        let locality: String
        let estimatedGB: Double?
        let contextWindowTokens: Int?
        let capabilities: Capabilities
        let readinessState: String
        let fitState: String
        let evaluationState: String
        let admissionState: String
        let admissionStateSource: String
        let providerGuidance: Guidance
        let warningCodes: [String]

        enum CodingKeys: String, CodingKey {
            case candidateID = "candidate_id"
            case runtimeSource = "runtime_source"
            case displayName = "display_name"
            case servedModelRef = "served_model_ref"
            case catalogModelKey = "catalog_model_key"
            case identityState = "identity_state"
            case locality
            case estimatedGB = "estimated_gb"
            case contextWindowTokens = "context_window_tokens"
            case capabilities
            case readinessState = "readiness_state"
            case fitState = "fit_state"
            case evaluationState = "evaluation_state"
            case admissionState = "admission_state"
            case admissionStateSource = "admission_state_source"
            case providerGuidance = "provider_guidance"
            case warningCodes = "warning_codes"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(candidateID, forKey: .candidateID)
            try container.encode(runtimeSource, forKey: .runtimeSource)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(servedModelRef, forKey: .servedModelRef)
            if let catalogModelKey {
                try container.encode(catalogModelKey, forKey: .catalogModelKey)
            } else {
                try container.encodeNil(forKey: .catalogModelKey)
            }
            try container.encode(identityState, forKey: .identityState)
            try container.encode(locality, forKey: .locality)
            if let estimatedGB {
                try container.encode(estimatedGB, forKey: .estimatedGB)
            } else {
                try container.encodeNil(forKey: .estimatedGB)
            }
            if let contextWindowTokens {
                try container.encode(contextWindowTokens, forKey: .contextWindowTokens)
            } else {
                try container.encodeNil(forKey: .contextWindowTokens)
            }
            try container.encode(capabilities, forKey: .capabilities)
            try container.encode(readinessState, forKey: .readinessState)
            try container.encode(fitState, forKey: .fitState)
            try container.encode(evaluationState, forKey: .evaluationState)
            try container.encode(admissionState, forKey: .admissionState)
            try container.encode(admissionStateSource, forKey: .admissionStateSource)
            try container.encode(providerGuidance, forKey: .providerGuidance)
            try container.encode(warningCodes, forKey: .warningCodes)
        }

        init(
            candidateID: String,
            runtimeSource: String,
            displayName: String,
            servedModelRef: String,
            catalogModelKey: String?,
            identityState: String,
            locality: String,
            estimatedGB: Double?,
            contextWindowTokens: Int?,
            capabilities: Capabilities,
            readinessState: String,
            fitState: String,
            evaluationState: String,
            admissionState: String,
            admissionStateSource: String,
            providerGuidance: Guidance,
            warningCodes: [String]
        ) {
            self.candidateID = candidateID
            self.runtimeSource = runtimeSource
            self.displayName = displayName
            self.servedModelRef = servedModelRef
            self.catalogModelKey = catalogModelKey
            self.identityState = identityState
            self.locality = locality
            self.estimatedGB = estimatedGB
            self.contextWindowTokens = contextWindowTokens
            self.capabilities = capabilities
            self.readinessState = readinessState
            self.fitState = fitState
            self.evaluationState = evaluationState
            self.admissionState = admissionState
            self.admissionStateSource = admissionStateSource
            self.providerGuidance = providerGuidance
            self.warningCodes = warningCodes
        }
    }

    let schema: String
    let generatedAt: String
    let cliVersion: String
    let projectionSequence: Int
    let adapters: [Adapter]
    let candidates: [Candidate]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case cliVersion = "cli_version"
        case projectionSequence = "projection_sequence"
        case adapters
        case candidates
        case warnings
    }

    init(
        generatedAt: String = ModelSwitchingWireCodec.timestamp(),
        cliVersion: String = CoordinatorClient.binaryVersion,
        projectionSequence: Int = 1,
        adapters: [Adapter],
        candidates: [Candidate],
        warnings: [String]
    ) {
        schema = "provider_byom_discovery.v1"
        self.generatedAt = generatedAt
        self.cliVersion = cliVersion
        self.projectionSequence = projectionSequence
        self.adapters = adapters
        self.candidates = candidates
        self.warnings = warnings
    }
}

struct BYOMEvaluationWire: Codable, Equatable, Sendable {
    struct CapabilityResult: Codable, Equatable, Sendable {
        let result: String
        let source: String
        let reasonCode: String?

        enum CodingKeys: String, CodingKey {
            case result
            case source
            case reasonCode = "reason_code"
        }

        init(result: String, source: String, reasonCode: String? = nil) {
            self.result = result
            self.source = source
            self.reasonCode = reasonCode
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(result, forKey: .result)
            try container.encode(source, forKey: .source)
            if let reasonCode {
                try container.encode(reasonCode, forKey: .reasonCode)
            } else {
                try container.encodeNil(forKey: .reasonCode)
            }
        }
    }

    struct MutationSummary: Codable, Equatable, Sendable {
        let productionConfigMutated: Bool
        let coordinatorStateMutated: Bool
        let productionModelSwitched: Bool
        let runtimeStarted: Bool
        let downloadsStarted: Bool
        let temporaryFilesCreated: Bool

        enum CodingKeys: String, CodingKey {
            case productionConfigMutated = "production_config_mutated"
            case coordinatorStateMutated = "coordinator_state_mutated"
            case productionModelSwitched = "production_model_switched"
            case runtimeStarted = "runtime_started"
            case downloadsStarted = "downloads_started"
            case temporaryFilesCreated = "temporary_files_created"
        }

        static let none = MutationSummary(
            productionConfigMutated: false,
            coordinatorStateMutated: false,
            productionModelSwitched: false,
            runtimeStarted: false,
            downloadsStarted: false,
            temporaryFilesCreated: false
        )
    }

    struct DiagnosticHashes: Codable, Equatable, Sendable {
        let promptSHA256: String
        let responseBodySHA256: String?

        enum CodingKeys: String, CodingKey {
            case promptSHA256 = "prompt_sha256"
            case responseBodySHA256 = "response_body_sha256"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(promptSHA256, forKey: .promptSHA256)
            if let responseBodySHA256 {
                try container.encode(responseBodySHA256, forKey: .responseBodySHA256)
            } else {
                try container.encodeNil(forKey: .responseBodySHA256)
            }
        }
    }

    let schema: String
    let generatedAt: String
    let cliVersion: String
    let candidateID: String
    let runtimeSource: String
    let servedModelRef: String
    let catalogModelKey: String?
    let adapterIdentity: String
    let healthResult: String
    let latencyMs: Int?
    let completionTokens: Int?
    let tokensPerSecond: Double?
    let requestCount: Int
    let outputBytes: Int
    let usageReportingSource: String
    let capabilityResults: [String: CapabilityResult]
    let fitEstimateSource: String
    let mutationSummary: MutationSummary
    let diagnosticHashes: DiagnosticHashes
    let providerGuidance: BYOMDiscoveryWire.Guidance
    let offerPreconditionsAppearSatisfied: Bool
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case cliVersion = "cli_version"
        case candidateID = "candidate_id"
        case runtimeSource = "runtime_source"
        case servedModelRef = "served_model_ref"
        case catalogModelKey = "catalog_model_key"
        case adapterIdentity = "adapter_identity"
        case healthResult = "health_result"
        case latencyMs = "latency_ms"
        case completionTokens = "completion_tokens"
        case tokensPerSecond = "tokens_per_second"
        case requestCount = "request_count"
        case outputBytes = "output_bytes"
        case usageReportingSource = "usage_reporting_source"
        case capabilityResults = "capability_results"
        case fitEstimateSource = "fit_estimate_source"
        case mutationSummary = "mutation_summary"
        case diagnosticHashes = "diagnostic_hashes"
        case providerGuidance = "provider_guidance"
        case offerPreconditionsAppearSatisfied = "offer_preconditions_appear_satisfied"
        case warnings
    }

    init(
        generatedAt: String = ModelSwitchingWireCodec.timestamp(),
        cliVersion: String = CoordinatorClient.binaryVersion,
        candidateID: String,
        runtimeSource: String,
        servedModelRef: String,
        catalogModelKey: String?,
        adapterIdentity: String,
        healthResult: String,
        latencyMs: Int?,
        completionTokens: Int?,
        tokensPerSecond: Double?,
        requestCount: Int,
        outputBytes: Int,
        usageReportingSource: String,
        capabilityResults: [String: CapabilityResult],
        fitEstimateSource: String,
        mutationSummary: MutationSummary,
        diagnosticHashes: DiagnosticHashes,
        providerGuidance: BYOMDiscoveryWire.Guidance,
        offerPreconditionsAppearSatisfied: Bool,
        warnings: [String]
    ) {
        schema = "provider_byom_evaluation.v1"
        self.generatedAt = generatedAt
        self.cliVersion = cliVersion
        self.candidateID = candidateID
        self.runtimeSource = runtimeSource
        self.servedModelRef = servedModelRef
        self.catalogModelKey = catalogModelKey
        self.adapterIdentity = adapterIdentity
        self.healthResult = healthResult
        self.latencyMs = latencyMs
        self.completionTokens = completionTokens
        self.tokensPerSecond = tokensPerSecond
        self.requestCount = requestCount
        self.outputBytes = outputBytes
        self.usageReportingSource = usageReportingSource
        self.capabilityResults = capabilityResults
        self.fitEstimateSource = fitEstimateSource
        self.mutationSummary = mutationSummary
        self.diagnosticHashes = diagnosticHashes
        self.providerGuidance = providerGuidance
        self.offerPreconditionsAppearSatisfied = offerPreconditionsAppearSatisfied
        self.warnings = warnings
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(cliVersion, forKey: .cliVersion)
        try container.encode(candidateID, forKey: .candidateID)
        try container.encode(runtimeSource, forKey: .runtimeSource)
        try container.encode(servedModelRef, forKey: .servedModelRef)
        if let catalogModelKey {
            try container.encode(catalogModelKey, forKey: .catalogModelKey)
        } else {
            try container.encodeNil(forKey: .catalogModelKey)
        }
        try container.encode(adapterIdentity, forKey: .adapterIdentity)
        try container.encode(healthResult, forKey: .healthResult)
        if let latencyMs {
            try container.encode(latencyMs, forKey: .latencyMs)
        } else {
            try container.encodeNil(forKey: .latencyMs)
        }
        if let completionTokens {
            try container.encode(completionTokens, forKey: .completionTokens)
        } else {
            try container.encodeNil(forKey: .completionTokens)
        }
        if let tokensPerSecond {
            try container.encode(tokensPerSecond, forKey: .tokensPerSecond)
        } else {
            try container.encodeNil(forKey: .tokensPerSecond)
        }
        try container.encode(requestCount, forKey: .requestCount)
        try container.encode(outputBytes, forKey: .outputBytes)
        try container.encode(usageReportingSource, forKey: .usageReportingSource)
        try container.encode(capabilityResults, forKey: .capabilityResults)
        try container.encode(fitEstimateSource, forKey: .fitEstimateSource)
        try container.encode(mutationSummary, forKey: .mutationSummary)
        try container.encode(diagnosticHashes, forKey: .diagnosticHashes)
        try container.encode(providerGuidance, forKey: .providerGuidance)
        try container.encode(offerPreconditionsAppearSatisfied, forKey: .offerPreconditionsAppearSatisfied)
        try container.encode(warnings, forKey: .warnings)
    }
}

struct BYOMOfferDryRunWire: Codable, Equatable, Sendable {
    let schema: String
    let generatedAt: String
    let cliVersion: String
    let candidateID: String
    let servedModelRef: String
    let catalogModelKey: String?
    let wouldSubmit: Bool
    let likelyAdmissionState: String
    let likelyAdmissionStateSource: String
    let providerGuidance: BYOMDiscoveryWire.Guidance
    let reasonCode: String?
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case cliVersion = "cli_version"
        case candidateID = "candidate_id"
        case servedModelRef = "served_model_ref"
        case catalogModelKey = "catalog_model_key"
        case wouldSubmit = "would_submit"
        case likelyAdmissionState = "likely_admission_state"
        case likelyAdmissionStateSource = "likely_admission_state_source"
        case providerGuidance = "provider_guidance"
        case reasonCode = "reason_code"
        case warnings
    }

    init(
        generatedAt: String = ModelSwitchingWireCodec.timestamp(),
        cliVersion: String = CoordinatorClient.binaryVersion,
        candidateID: String,
        servedModelRef: String,
        catalogModelKey: String?,
        wouldSubmit: Bool,
        likelyAdmissionState: String,
        likelyAdmissionStateSource: String,
        providerGuidance: BYOMDiscoveryWire.Guidance,
        reasonCode: String?,
        warnings: [String]
    ) {
        schema = "model_admission_offer_dry_run.v1"
        self.generatedAt = generatedAt
        self.cliVersion = cliVersion
        self.candidateID = candidateID
        self.servedModelRef = servedModelRef
        self.catalogModelKey = catalogModelKey
        self.wouldSubmit = wouldSubmit
        self.likelyAdmissionState = likelyAdmissionState
        self.likelyAdmissionStateSource = likelyAdmissionStateSource
        self.providerGuidance = providerGuidance
        self.reasonCode = reasonCode
        self.warnings = warnings
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(cliVersion, forKey: .cliVersion)
        try container.encode(candidateID, forKey: .candidateID)
        try container.encode(servedModelRef, forKey: .servedModelRef)
        if let catalogModelKey {
            try container.encode(catalogModelKey, forKey: .catalogModelKey)
        } else {
            try container.encodeNil(forKey: .catalogModelKey)
        }
        try container.encode(wouldSubmit, forKey: .wouldSubmit)
        try container.encode(likelyAdmissionState, forKey: .likelyAdmissionState)
        try container.encode(likelyAdmissionStateSource, forKey: .likelyAdmissionStateSource)
        try container.encode(providerGuidance, forKey: .providerGuidance)
        if let reasonCode {
            try container.encode(reasonCode, forKey: .reasonCode)
        } else {
            try container.encodeNil(forKey: .reasonCode)
        }
        try container.encode(warnings, forKey: .warnings)
    }
}

struct BYOMAdmissionStatusWire: Codable, Equatable, Sendable {
    let schema: String
    let generatedAt: String
    let cliVersion: String
    let providerID: String
    let candidateID: String
    let servedModelRef: String
    let catalogModelKey: String?
    let admissionState: String
    let admissionStateSource: String
    let coordinatorEventID: String?
    let stateObservedAt: String?
    let providerGuidance: BYOMDiscoveryWire.Guidance
    let allowedNextStates: [String]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case cliVersion = "cli_version"
        case providerID = "provider_id"
        case candidateID = "candidate_id"
        case servedModelRef = "served_model_ref"
        case catalogModelKey = "catalog_model_key"
        case admissionState = "admission_state"
        case admissionStateSource = "admission_state_source"
        case coordinatorEventID = "coordinator_event_id"
        case stateObservedAt = "state_observed_at"
        case providerGuidance = "provider_guidance"
        case allowedNextStates = "allowed_next_states"
        case warnings
    }
}

extension BYOMAdmissionStatusWire {
    private static let topLevelKeys: Set<String> = [
        "schema",
        "generated_at",
        "cli_version",
        "provider_id",
        "candidate_id",
        "served_model_ref",
        "catalog_model_key",
        "admission_state",
        "admission_state_source",
        "coordinator_event_id",
        "state_observed_at",
        "provider_guidance",
        "allowed_next_states",
        "warnings",
    ]
    private static let guidanceKeys: Set<String> = [
        "state_label_key",
        "state_meaning_key",
        "next_action",
        "transition_reason_code",
        "earning_path_class",
    ]
    private static let localDefaultStates: Set<String> = ["local_only", "not_offered", "offerable"]
    private static let coordinatorStates: Set<String> = [
        "not_offered",
        "offer_submitted",
        "offer_rejected",
        "sandbox_probe_only",
        "network_visible_unpriced",
        "network_admitted_unsettled",
        "catalog_priced",
        "settlement_capable",
        "withdrawn",
        "revoked",
    ]
    private static let nextActions: Set<String> = [
        "fix_local_blocker",
        "evaluate",
        "offer_dry_run",
        "submit_offer",
        "revise_and_reoffer",
        "check_status",
        "withdraw",
        "wait_for_coordinator",
        "maintain_runtime",
        "none",
    ]
    private static let earningPathClasses: Set<String> = [
        "local_inventory_only",
        "not_earning_yet_catalog_or_receipt_path_exists",
        "no_earning_path_in_v0_1",
        "settlement_capable",
    ]
    private static let reasonRequiredStates: Set<String> = [
        "offer_rejected",
        "withdrawn",
        "revoked",
    ]

    static func decodeStrictStatus(
        from data: Data,
        expectedProviderID: String? = nil,
        expectedCandidateID: String? = nil
    ) throws -> BYOMAdmissionStatusWire {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == topLevelKeys,
              let guidance = object["provider_guidance"] as? [String: Any],
              Set(guidance.keys) == guidanceKeys else {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
        let status = try JSONDecoder().decode(BYOMAdmissionStatusWire.self, from: data)
        try validate(status, expectedProviderID: expectedProviderID, expectedCandidateID: expectedCandidateID)
        return status
    }

    private static func validate(
        _ status: BYOMAdmissionStatusWire,
        expectedProviderID: String?,
        expectedCandidateID: String?
    ) throws {
        guard status.schema == "model_admission_status.v1",
              status.admissionStateSource == "local_default" || status.admissionStateSource == "coordinator",
              nextActions.contains(status.providerGuidance.nextAction),
              earningPathClasses.contains(status.providerGuidance.earningPathClass) else {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
        if let expectedProviderID, status.providerID != expectedProviderID {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
        if let expectedCandidateID, status.candidateID != expectedCandidateID {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
        if status.admissionStateSource == "local_default" {
            guard localDefaultStates.contains(status.admissionState),
                  status.allowedNextStates.isEmpty else {
                throw BYOMModelAdmissionError.invalidStatusSchema
            }
            return
        }
        guard coordinatorStates.contains(status.admissionState) else {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
        let allowed = Set(Self.allowedNextStates(for: status.admissionState))
        guard status.allowedNextStates.allSatisfy({ allowed.contains($0) }) else {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
        if reasonRequiredStates.contains(status.admissionState),
           status.providerGuidance.transitionReasonCode?.isEmpty ?? true {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
        guard Self.guidanceMatches(status) else {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
    }

    private static func allowedNextStates(for state: String) -> [String] {
        switch state {
        case "not_offered", "withdrawn", "revoked":
            return ["offer_submitted"]
        case "offer_rejected":
            return ["offer_submitted", "revoked"]
        case "offer_submitted":
            return ["offer_rejected", "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"]
        case "sandbox_probe_only":
            return ["network_visible_unpriced", "network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"]
        case "network_visible_unpriced":
            return ["network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"]
        case "network_admitted_unsettled":
            return ["catalog_priced", "settlement_capable", "withdrawn", "revoked"]
        case "catalog_priced":
            return ["network_admitted_unsettled", "settlement_capable", "withdrawn", "revoked"]
        case "settlement_capable":
            return ["network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"]
        default:
            return []
        }
    }

    private static func guidanceMatches(_ status: BYOMAdmissionStatusWire) -> Bool {
        let guidance = status.providerGuidance
        switch status.admissionState {
        case "not_offered":
            return guidance.nextAction == "submit_offer" &&
                guidance.earningPathClass == "local_inventory_only"
        case "offer_submitted":
            return guidance.nextAction == "wait_for_coordinator" &&
                (guidance.earningPathClass == "no_earning_path_in_v0_1" ||
                 guidance.earningPathClass == "not_earning_yet_catalog_or_receipt_path_exists")
        case "offer_rejected":
            return guidance.nextAction == "revise_and_reoffer" &&
                guidance.earningPathClass == "no_earning_path_in_v0_1"
        case "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled", "catalog_priced":
            return guidance.nextAction == "withdraw" &&
                guidance.earningPathClass == "not_earning_yet_catalog_or_receipt_path_exists"
        case "settlement_capable":
            return guidance.nextAction == "maintain_runtime" &&
                guidance.earningPathClass == "settlement_capable"
        case "withdrawn", "revoked":
            return guidance.nextAction == "submit_offer" &&
                guidance.earningPathClass == "no_earning_path_in_v0_1"
        default:
            return false
        }
    }
}

struct BYOMOfferSubmitRequestWire: Codable, Equatable, Sendable {
    let schema: String
    let signatureDomain: String
    let providerID: String
    let candidateID: String
    let runtimeSource: String
    let servedModelRef: String
    let catalogModelKey: String
    let discoveryDigestSHA256: String
    let evaluationDigestSHA256: String
    let artifactHashes: [String: String]
    let advisoryCapabilities: AdvisoryCapabilities
    let fitEvidenceSource: String
    let localReadiness: String
    let requestedDisclosureClass: String
    let timestamp: String
    let nonce: String
    let idempotencyKey: String
    let signingKeyDigest: String
    let signatureAlgorithm: String
    var providerSignature: String
    let cliVersion: String

    enum CodingKeys: String, CodingKey {
        case schema
        case signatureDomain = "signature_domain"
        case providerID = "provider_id"
        case candidateID = "candidate_id"
        case runtimeSource = "runtime_source"
        case servedModelRef = "served_model_ref"
        case catalogModelKey = "catalog_model_key"
        case discoveryDigestSHA256 = "discovery_digest_sha256"
        case evaluationDigestSHA256 = "evaluation_digest_sha256"
        case artifactHashes = "artifact_hashes"
        case advisoryCapabilities = "advisory_capabilities"
        case fitEvidenceSource = "fit_evidence_source"
        case localReadiness = "local_readiness"
        case requestedDisclosureClass = "requested_disclosure_class"
        case timestamp
        case nonce
        case idempotencyKey = "idempotency_key"
        case signingKeyDigest = "signing_key_digest"
        case signatureAlgorithm = "signature_algorithm"
        case providerSignature = "provider_signature"
        case cliVersion = "cli_version"
    }

    struct AdvisoryCapabilities: Codable, Equatable, Sendable {
        let chatCompletions: Bool?
        let streaming: Bool?
        let toolCallPassthrough: Bool?
        let structuredOutputPassthrough: Bool?
        let jsonMode: Bool?
        let usageReporting: Bool?
        let maxContextTokens: Int?
        let quantization: String?
        let family: String?
        let runtimeVersion: String?

        enum CodingKeys: String, CodingKey {
            case chatCompletions = "chat_completions"
            case streaming
            case toolCallPassthrough = "tool_call_passthrough"
            case structuredOutputPassthrough = "structured_output_passthrough"
            case jsonMode = "json_mode"
            case usageReporting = "usage_reporting"
            case maxContextTokens = "max_context_tokens"
            case quantization
            case family
            case runtimeVersion = "runtime_version"
        }
    }

    func canonicalValue() -> RFC8785JCS.Value {
        .object([
            "signature_domain": .string(signatureDomain),
            "provider_id": .string(providerID),
            "candidate_id": .string(candidateID),
            "runtime_source": .string(runtimeSource),
            "served_model_ref": .string(servedModelRef),
            "catalog_model_key": .string(catalogModelKey),
            "discovery_digest_sha256": .string(discoveryDigestSHA256),
            "evaluation_digest_sha256": .string(evaluationDigestSHA256),
            "artifact_hashes": .object(artifactHashes.mapValues(RFC8785JCS.Value.string)),
            "advisory_capabilities": advisoryCapabilities.canonicalValue(),
            "fit_evidence_source": .string(fitEvidenceSource),
            "local_readiness": .string(localReadiness),
            "requested_disclosure_class": .string(requestedDisclosureClass),
            "timestamp": .string(timestamp),
            "nonce": .string(nonce),
            "idempotency_key": .string(idempotencyKey),
            "signing_key_digest": .string(signingKeyDigest),
            "cli_version": .string(cliVersion),
        ])
    }
}

extension BYOMOfferSubmitRequestWire.AdvisoryCapabilities {
    init(_ capabilities: BYOMDiscoveryWire.Capabilities) {
        self.init(
            chatCompletions: capabilities.chatCompletions,
            streaming: capabilities.streaming,
            toolCallPassthrough: capabilities.toolCallPassthrough,
            structuredOutputPassthrough: capabilities.structuredOutputPassthrough,
            jsonMode: capabilities.jsonMode,
            usageReporting: capabilities.usageReporting,
            maxContextTokens: capabilities.maxContextTokens,
            quantization: capabilities.quantization,
            family: capabilities.family,
            runtimeVersion: capabilities.runtimeVersion
        )
    }

    func canonicalValue() -> RFC8785JCS.Value {
        .object([
            "chat_completions": chatCompletions.map(RFC8785JCS.Value.bool) ?? .null,
            "streaming": streaming.map(RFC8785JCS.Value.bool) ?? .null,
            "tool_call_passthrough": toolCallPassthrough.map(RFC8785JCS.Value.bool) ?? .null,
            "structured_output_passthrough": structuredOutputPassthrough.map(RFC8785JCS.Value.bool) ?? .null,
            "json_mode": jsonMode.map(RFC8785JCS.Value.bool) ?? .null,
            "usage_reporting": usageReporting.map(RFC8785JCS.Value.bool) ?? .null,
            "max_context_tokens": maxContextTokens.map(RFC8785JCS.Value.int) ?? .null,
            "quantization": quantization.map(RFC8785JCS.Value.string) ?? .null,
            "family": family.map(RFC8785JCS.Value.string) ?? .null,
            "runtime_version": runtimeVersion.map(RFC8785JCS.Value.string) ?? .null,
        ])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeNullable(chatCompletions, forKey: .chatCompletions, into: &container)
        try encodeNullable(streaming, forKey: .streaming, into: &container)
        try encodeNullable(toolCallPassthrough, forKey: .toolCallPassthrough, into: &container)
        try encodeNullable(structuredOutputPassthrough, forKey: .structuredOutputPassthrough, into: &container)
        try encodeNullable(jsonMode, forKey: .jsonMode, into: &container)
        try encodeNullable(usageReporting, forKey: .usageReporting, into: &container)
        try encodeNullable(maxContextTokens, forKey: .maxContextTokens, into: &container)
        try encodeNullable(quantization, forKey: .quantization, into: &container)
        try encodeNullable(family, forKey: .family, into: &container)
        try encodeNullable(runtimeVersion, forKey: .runtimeVersion, into: &container)
    }

    private func encodeNullable<T: Encodable>(
        _ value: T?,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

enum BYOMModelAdmissionError: Error, Equatable, CustomStringConvertible {
    case missingProviderID
    case missingCoordinatorURL
    case missingBearer(providerID: String)
    case missingAdmissionIdentity(providerID: String)
    case candidateNotFound
    case candidateUnstable
    case candidateNotOfferable
    case invalidEvaluationDigest
    case invalidCoordinatorURL
    case httpStatus(Int)
    case invalidStatusSchema

    var description: String {
        switch self {
        case .missingProviderID:
            return "models offer requires provider_id from --provider-id, config, or MACPROVIDER_PROVIDER_ID"
        case .missingCoordinatorURL:
            return "models offer requires coordinator_url from --coordinator-url, config, or MACPROVIDER_COORDINATOR_URL"
        case .missingBearer(let providerID):
            return "provider bearer token is missing for \(providerID); run macprovider-cli credentials import first"
        case .missingAdmissionIdentity(let providerID):
            return "provider admission signing identity is missing for \(providerID); start provider enrollment before offering BYOM models"
        case .candidateNotFound:
            return "BYOM candidate was not found in local discovery"
        case .candidateUnstable:
            return "BYOM candidate id is unstable; run models discover --json to initialize the local namespace"
        case .candidateNotOfferable:
            return "BYOM candidate is not offerable; run models evaluate and models offer --dry-run --json before submitting"
        case .invalidEvaluationDigest:
            return "evaluation digest must be a 64-character lowercase SHA-256 hex value"
        case .invalidCoordinatorURL:
            return "invalid coordinator URL; use wss:// or https://"
        case .httpStatus(let status):
            return "coordinator model admission request failed with HTTP \(status)"
        case .invalidStatusSchema:
            return "coordinator returned an invalid model admission status schema"
        }
    }
}

struct BYOMOfferSubmissionPackage: Equatable, Sendable {
    let request: BYOMOfferSubmitRequestWire
    let encodedRequest: Data
    let payloadDigestSHA256: String
}

struct BYOMOfferSubmissionBuilder {
    private static let stableCandidatePattern = #"^byom_[a-z2-7]{52}$"#

    static func makePackage(
        providerID: String,
        candidate: BYOMDiscoveryWire.Candidate,
        admissionIdentity: Curve25519.Signing.PrivateKey,
        evaluationDigestSHA256: String?,
        requestedDisclosureClass: String,
        now: Date = Date(),
        nonce: String = UUID().uuidString.lowercased(),
        idempotencyKey: String = UUID().uuidString.lowercased(),
        cliVersion: String = CoordinatorClient.binaryVersion
    ) throws -> BYOMOfferSubmissionPackage {
        guard candidate.candidateID.range(of: stableCandidatePattern, options: .regularExpression) != nil,
              !candidate.warningCodes.contains(BYOMDiscoveryWarning.candidateIDUnstable.rawValue),
              !candidate.warningCodes.contains(BYOMDiscoveryWarning.namespacePermissionInvalid.rawValue) else {
            throw BYOMModelAdmissionError.candidateUnstable
        }
        let evaluationDigest = evaluationDigestSHA256?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !evaluationDigest.isEmpty, !Self.isLowercaseSHA256(evaluationDigest) {
            throw BYOMModelAdmissionError.invalidEvaluationDigest
        }
        guard Self.canSubmit(candidate: candidate, evaluationDigestSHA256: evaluationDigest) else {
            throw BYOMModelAdmissionError.candidateNotOfferable
        }
        let publicKey = admissionIdentity.publicKey.rawRepresentation
        let signingKeyDigest = Self.sha256Hex(publicKey)
        var request = BYOMOfferSubmitRequestWire(
            schema: "model_admission_offer_submit.v1",
            signatureDomain: "macprovider.model_admission.offer.v1",
            providerID: providerID,
            candidateID: candidate.candidateID,
            runtimeSource: candidate.runtimeSource,
            servedModelRef: candidate.servedModelRef,
            catalogModelKey: candidate.catalogModelKey ?? "",
            discoveryDigestSHA256: try discoveryDigest(candidate),
            evaluationDigestSHA256: evaluationDigest,
            artifactHashes: [:],
            advisoryCapabilities: BYOMOfferSubmitRequestWire.AdvisoryCapabilities(candidate.capabilities),
            fitEvidenceSource: "local_discovery",
            localReadiness: candidate.readinessState,
            requestedDisclosureClass: requestedDisclosureClass,
            timestamp: ModelSwitchingWireCodec.timestamp(now),
            nonce: nonce,
            idempotencyKey: idempotencyKey,
            signingKeyDigest: signingKeyDigest,
            signatureAlgorithm: "ed25519",
            providerSignature: "",
            cliVersion: cliVersion
        )
        let canonical = try RFC8785JCS.canonicalString(request.canonicalValue())
        let canonicalData = Data(canonical.utf8)
        let signatureData = try admissionIdentity.signature(for: canonicalData)
        request.providerSignature = signatureData.base64EncodedString()
        return BYOMOfferSubmissionPackage(
            request: request,
            encodedRequest: Data(try ModelSwitchingWireCodec.encode(request).utf8),
            payloadDigestSHA256: Self.sha256Hex(canonicalData)
        )
    }

    static func discoveryDigest(_ candidate: BYOMDiscoveryWire.Candidate) throws -> String {
        try RFC8785JCS.sha256Hex(of: .object([
            "candidate_id": .string(candidate.candidateID),
            "runtime_source": .string(candidate.runtimeSource),
            "served_model_ref": .string(candidate.servedModelRef),
            "catalog_model_key": candidate.catalogModelKey.map(RFC8785JCS.Value.string) ?? .null,
            "identity_state": .string(candidate.identityState),
            "readiness_state": .string(candidate.readinessState),
            "fit_state": .string(candidate.fitState),
            "evaluation_state": .string(candidate.evaluationState),
            "admission_state": .string(candidate.admissionState),
            "warning_codes": .array(candidate.warningCodes.sorted().map(RFC8785JCS.Value.string)),
        ]))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static func canSubmit(candidate: BYOMDiscoveryWire.Candidate, evaluationDigestSHA256: String) -> Bool {
        guard candidate.admissionStateSource == "local_default",
              candidate.admissionState == "offerable",
              candidate.readinessState == "ready",
              candidate.fitState != "does_not_fit" else {
            return false
        }
        let warnings = Set(candidate.warningCodes)
        if warnings.contains(BYOMDiscoveryWarning.adapterRejectedNonLoopback.rawValue) ||
            warnings.contains(BYOMDiscoveryWarning.adapterMalformedResponse.rawValue) ||
            warnings.contains(BYOMDiscoveryWarning.adapterResponseTruncated.rawValue) ||
            warnings.contains(BYOMDiscoveryWarning.requiresPreparation.rawValue) {
            return false
        }
        return !evaluationDigestSHA256.isEmpty || !warnings.contains(BYOMDiscoveryWarning.evaluationRequired.rawValue)
    }
}

struct BYOMModelAdmissionClient: Sendable {
    private static let maxStatusResponseBytes = 64 * 1024

    let baseURL: URL
    private let session: URLSession?

    init(coordinatorURL: String?, session: URLSession? = nil) throws {
        guard let baseURL = Self.httpBaseURL(from: coordinatorURL) else {
            throw BYOMModelAdmissionError.invalidCoordinatorURL
        }
        self.baseURL = baseURL
        self.session = session
    }

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.session = session
    }

    static func httpBaseURL(from coordinatorURL: String?) -> URL? {
        guard let coordinatorURL,
              var components = URLComponents(string: coordinatorURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        guard components.user == nil,
              components.password == nil,
              components.host != nil else {
            return nil
        }
        switch components.scheme {
        case "wss":
            components.scheme = "https"
        case "https":
            break
        default:
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func submitOffer(_ package: BYOMOfferSubmissionPackage, bearerToken: String) async throws -> BYOMAdmissionStatusWire {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/provider/model-admission/offers"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = package.encodedRequest
        return try await perform(
            request,
            expectedProviderID: package.request.providerID,
            expectedCandidateID: package.request.candidateID
        )
    }

    func status(candidateID: String, providerID: String? = nil, bearerToken: String) async throws -> BYOMAdmissionStatusWire {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/provider/model-admission/status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "candidate_id", value: candidateID)]
        guard let url = components?.url else {
            throw BYOMModelAdmissionError.invalidCoordinatorURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return try await perform(request, expectedProviderID: providerID, expectedCandidateID: candidateID)
    }

    private func perform(
        _ request: URLRequest,
        expectedProviderID: String?,
        expectedCandidateID: String?
    ) async throws -> BYOMAdmissionStatusWire {
        let data: Data
        let response: URLResponse
        if let session {
            (data, response) = try await session.data(for: request)
        } else {
            let ephemeral = URLSession(configuration: .ephemeral, delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
            defer { ephemeral.finishTasksAndInvalidate() }
            (data, response) = try await ephemeral.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BYOMModelAdmissionError.httpStatus(http.statusCode)
        }
        guard data.count <= Self.maxStatusResponseBytes else {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
        let status = try BYOMAdmissionStatusWire.decodeStrictStatus(
            from: data,
            expectedProviderID: expectedProviderID,
            expectedCandidateID: expectedCandidateID
        )
        guard status.admissionStateSource == "coordinator" else {
            throw BYOMModelAdmissionError.invalidStatusSchema
        }
        return status
    }
}

struct BYOMModelAdmissionRuntime: Sendable {
    let environment: BYOMDiscoveryEnvironment
    let credentialStore: any ProviderCredentialStoring
    let identityStore: any ProviderIdentityKeyStoring
    let client: BYOMModelAdmissionClient
    let httpClient: any BYOMDiscoveryHTTPClient

    init(
        environment: BYOMDiscoveryEnvironment,
        credentialStore: any ProviderCredentialStoring = KeychainProviderCredentialStore(),
        identityStore: any ProviderIdentityKeyStoring = KeychainReceiptKeyStore(),
        client: BYOMModelAdmissionClient,
        httpClient: any BYOMDiscoveryHTTPClient = BYOMURLSessionHTTPClient()
    ) {
        self.environment = environment
        self.credentialStore = credentialStore
        self.identityStore = identityStore
        self.client = client
        self.httpClient = httpClient
    }

    func submitOffer(
        providerID: String,
        target: String,
        evaluationDigestSHA256: String?,
        requestedDisclosureClass: String
    ) async throws -> BYOMAdmissionStatusWire {
        let discovery = await BYOMDiscoveryRunner(
            environment: environment,
            httpClient: httpClient,
            namespaceMode: .readOnly
        ).discover()
        guard let candidate = Self.selectCandidate(target: target, candidates: discovery.candidates) else {
            throw BYOMModelAdmissionError.candidateNotFound
        }
        guard let bearer = try credentialStore.load(providerID: providerID) else {
            throw BYOMModelAdmissionError.missingBearer(providerID: providerID)
        }
        guard let identity = try identityStore.loadAdmissionIdentity(providerId: providerID) else {
            throw BYOMModelAdmissionError.missingAdmissionIdentity(providerID: providerID)
        }
        let package = try BYOMOfferSubmissionBuilder.makePackage(
            providerID: providerID,
            candidate: candidate,
            admissionIdentity: identity,
            evaluationDigestSHA256: evaluationDigestSHA256,
            requestedDisclosureClass: requestedDisclosureClass
        )
        return try await client.submitOffer(package, bearerToken: bearer)
    }

    func status(providerID: String, target: String) async throws -> BYOMAdmissionStatusWire {
        let candidate = await resolveCandidate(target)
        let candidateID = candidate?.candidateID ?? target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bearer = try credentialStore.load(providerID: providerID) else {
            throw BYOMModelAdmissionError.missingBearer(providerID: providerID)
        }
        let status = try await client.status(candidateID: candidateID, providerID: providerID, bearerToken: bearer)
        return status.withLocalCandidateIdentityIfCoordinatorHasNoOffer(candidate)
    }

    private func resolveCandidate(_ target: String) async -> BYOMDiscoveryWire.Candidate? {
        let discovery = await BYOMDiscoveryRunner(
            environment: environment,
            httpClient: httpClient,
            namespaceMode: .readOnly
        ).discover()
        return Self.selectCandidate(target: target, candidates: discovery.candidates)
    }

    static func selectCandidate(target: String, candidates: [BYOMDiscoveryWire.Candidate]) -> BYOMDiscoveryWire.Candidate? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.first { candidate in
            candidate.candidateID == trimmed ||
                candidate.servedModelRef == trimmed ||
                candidate.displayName == trimmed
        }
    }
}

private extension BYOMAdmissionStatusWire {
    func withLocalCandidateIdentityIfCoordinatorHasNoOffer(_ candidate: BYOMDiscoveryWire.Candidate?) -> BYOMAdmissionStatusWire {
        guard let candidate,
              candidate.candidateID == candidateID,
              admissionStateSource == "coordinator",
              admissionState == "not_offered",
              servedModelRef.isEmpty
        else {
            return self
        }
        return BYOMAdmissionStatusWire(
            schema: schema,
            generatedAt: generatedAt,
            cliVersion: cliVersion,
            providerID: providerID,
            candidateID: candidateID,
            servedModelRef: candidate.servedModelRef,
            catalogModelKey: catalogModelKey ?? candidate.catalogModelKey,
            admissionState: admissionState,
            admissionStateSource: admissionStateSource,
            coordinatorEventID: coordinatorEventID,
            stateObservedAt: stateObservedAt,
            providerGuidance: providerGuidance,
            allowedNextStates: allowedNextStates,
            warnings: warnings
        )
    }
}

struct BYOMDiscoveryEnvironment: Sendable {
    let namespaceURL: URL
    let mlxCacheRoot: URL
    let ollamaOrigin: String?

    static func production(
        namespacePath: String?,
        mlxCacheDir: String?,
        ollamaOrigin: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> BYOMDiscoveryEnvironment {
        BYOMDiscoveryEnvironment(
            namespaceURL: namespacePath.map(URL.init(fileURLWithPath:)) ?? defaultNamespaceURL(homeDirectory: homeDirectory),
            mlxCacheRoot: mlxCacheDir.map(URL.init(fileURLWithPath:)) ?? defaultMLXCacheRoot(environment: environment, homeDirectory: homeDirectory),
            ollamaOrigin: ollamaOrigin
        )
    }

    static func defaultNamespaceURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        // The salt lives in a dedicated `byom` subdirectory that provisioning
        // creates and owns at 0700, so the shared `~/.config/macprovider` config
        // dir (which may be group/other-readable) is never chmod'd and the salt's
        // immediate parent is always private without touching operator state.
        homeDirectory
            .appendingPathComponent(".config/macprovider", isDirectory: true)
            .appendingPathComponent("byom", isDirectory: true)
            .appendingPathComponent("local_discovery_namespace")
    }

    static func defaultMLXCacheRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let cache = environment["HF_HUB_CACHE"], !cache.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: cache)
        }
        if let hfHome = environment["HF_HOME"], !hfHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: hfHome).appendingPathComponent("hub", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }
}

struct BYOMHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [(String, String)]
    let body: Data
}

protocol BYOMDiscoveryHTTPClient: Sendable {
    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse
    func post(
        _ url: URL,
        jsonBody: Data,
        maxHeaderBytes: Int,
        maxBodyBytes: Int
    ) async throws -> BYOMHTTPResponse
}

extension BYOMDiscoveryHTTPClient {
    func post(
        _ url: URL,
        jsonBody: Data,
        maxHeaderBytes: Int,
        maxBodyBytes: Int
    ) async throws -> BYOMHTTPResponse {
        throw BYOMDiscoveryAdapterError.rejectedNonLoopback
    }
}

final class BYOMURLSessionHTTPClient: BYOMDiscoveryHTTPClient, @unchecked Sendable {
    func get(_ url: URL, maxHeaderBytes: Int, maxBodyBytes: Int) async throws -> BYOMHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return try await perform(request, maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxBodyBytes)
    }

    func post(
        _ url: URL,
        jsonBody: Data,
        maxHeaderBytes: Int,
        maxBodyBytes: Int
    ) async throws -> BYOMHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = jsonBody
        return try await perform(request, maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxBodyBytes)
    }

    private func perform(
        _ request: URLRequest,
        maxHeaderBytes: Int,
        maxBodyBytes: Int
    ) async throws -> BYOMHTTPResponse {
        guard let url = request.url, BYOMLoopbackOriginValidator.isSafeLoopbackHTTPURL(url) else {
            throw BYOMDiscoveryAdapterError.rejectedNonLoopback
        }
        let session = Self.directLoopbackSession()
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BYOMDiscoveryAdapterError.malformed
        }
        let headers = http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let key = key as? String else { return nil }
            return (key, String(describing: value))
        }
        guard BYOMDiscoveryHTTPBounds.headerBytes(headers) <= maxHeaderBytes else {
            throw BYOMDiscoveryAdapterError.truncated
        }
        var body = Data()
        body.reserveCapacity(min(maxBodyBytes, 64 * 1024))
        for try await byte in bytes {
            guard body.count < maxBodyBytes else {
                throw BYOMDiscoveryAdapterError.truncated
            }
            body.append(byte)
        }
        return BYOMHTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
    }

    static func directLoopbackConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2.0
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        return configuration
    }

    private static func directLoopbackSession() -> URLSession {
        URLSession(configuration: directLoopbackConfiguration(), delegate: NoRedirectURLSessionDelegate(), delegateQueue: nil)
    }
}

enum BYOMDiscoveryAdapterError: Error {
    case rejectedNonLoopback
    case malformed
    case truncated
}

struct BYOMDiscoveryRunner {
    private let environment: BYOMDiscoveryEnvironment
    private let fileManager: FileManager
    private let httpClient: any BYOMDiscoveryHTTPClient

    init(
        environment: BYOMDiscoveryEnvironment,
        fileManager: FileManager = .default,
        httpClient: any BYOMDiscoveryHTTPClient = BYOMURLSessionHTTPClient()
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.httpClient = httpClient
    }

    func discover() async -> BYOMDiscoveryWire {
        let namespace = BYOMDiscoveryNamespaceStore(fileManager: fileManager)
            .readNamespace(at: environment.namespaceURL)
        let catalog = BYOMCatalogMatcher()
        var adapters: [BYOMDiscoveryWire.Adapter] = []
        var candidates: [BYOMDiscoveryWire.Candidate] = []
        var warnings = Set(namespace.warnings.map(\.rawValue))

        let mlx = BYOMMLXCacheDiscovery(
            cacheRoot: environment.mlxCacheRoot,
            namespace: namespace.bytes,
            namespaceWarnings: namespace.warnings,
            catalogMatcher: catalog,
            fileManager: fileManager
        ).discover()
        adapters.append(mlx.adapter)
        candidates.append(contentsOf: mlx.candidates)
        warnings.formUnion(mlx.adapter.warningCodes)
        for candidate in mlx.candidates {
            warnings.formUnion(candidate.warningCodes)
        }

        if let ollamaOrigin = environment.ollamaOrigin,
           !ollamaOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let ollama = await BYOMOllamaDiscovery(
                origin: ollamaOrigin,
                namespace: namespace.bytes,
                namespaceWarnings: namespace.warnings,
                catalogMatcher: catalog,
                httpClient: httpClient
            ).discover()
            adapters.append(ollama.adapter)
            candidates.append(contentsOf: ollama.candidates)
            warnings.formUnion(ollama.adapter.warningCodes)
            for candidate in ollama.candidates {
                warnings.formUnion(candidate.warningCodes)
            }
        }

        candidates.sort {
            if $0.runtimeSource == $1.runtimeSource {
                return $0.servedModelRef < $1.servedModelRef
            }
            return $0.runtimeSource < $1.runtimeSource
        }
        adapters.sort { $0.runtimeSource < $1.runtimeSource }

        return BYOMDiscoveryWire(
            adapters: adapters,
            candidates: candidates,
            warnings: Array(warnings).sorted()
        )
    }
}

struct BYOMEvaluationLimits: Sendable {
    let timeoutSeconds: Double
    let maxRequestBytes: Int
    let maxHeaderBytes: Int
    let maxBodyBytes: Int
    let maxOutputBytes: Int
    let maxTokens: Int
    let requestCount: Int

    static let standard = BYOMEvaluationLimits(
        timeoutSeconds: 3.0,
        maxRequestBytes: 16 * 1024,
        maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
        maxBodyBytes: 256 * 1024,
        maxOutputBytes: 64 * 1024,
        maxTokens: 8,
        requestCount: 1
    )
}

struct BYOMEvaluationRunner: Sendable {
    private static let prompt = "MacProvider BYOM local evaluation health probe. Reply with one short word."

    private let target: String
    private let environment: BYOMDiscoveryEnvironment
    private let limits: BYOMEvaluationLimits
    private let httpClient: any BYOMDiscoveryHTTPClient

    init(
        target: String,
        environment: BYOMDiscoveryEnvironment,
        limits: BYOMEvaluationLimits = .standard,
        httpClient: any BYOMDiscoveryHTTPClient = BYOMURLSessionHTTPClient()
    ) {
        self.target = target
        self.environment = environment
        self.limits = limits
        self.httpClient = httpClient
    }

    func evaluate() async -> BYOMEvaluationWire {
        // Evaluate is a deliberate command: establish a stable provider identity
        // (idempotent salt provisioning) before discovery so the evaluated
        // candidate has a stable id. Discovery itself stays read-only.
        BYOMDiscoveryNamespaceStore().provisionNamespaceIfMissing(at: environment.namespaceURL)
        let discovery = await BYOMDiscoveryRunner(environment: environment, httpClient: httpClient).discover()
        guard let candidate = selectLocalEvaluationCandidate(from: discovery.candidates) else {
            let warnings = [BYOMDiscoveryWarning.evaluationFailed.rawValue]
            return failureDocument(
                candidateID: "unknown",
                runtimeSource: "unknown",
                servedModelRef: "unknown",
                catalogModelKey: nil,
                adapterIdentity: "unknown",
                healthResult: "blocked",
                responseBody: nil,
                warnings: warnings,
                guidance: evaluationGuidance(health: "blocked", warnings: Set(warnings))
            )
        }

        guard candidate.candidateID.hasPrefix("byom_"),
              !candidate.candidateID.hasPrefix("byom_unstable_"),
              !candidate.warningCodes.contains(BYOMDiscoveryWarning.candidateIDUnstable.rawValue),
              !candidate.warningCodes.contains(BYOMDiscoveryWarning.namespacePermissionInvalid.rawValue) else {
            let warnings = mergedWarnings(candidate, adding: [.candidateIDUnstable])
            return failureDocument(
                for: candidate,
                healthResult: "blocked",
                responseBody: nil,
                warnings: warnings,
                guidance: evaluationGuidance(health: "blocked", warnings: Set(warnings))
            )
        }

        guard candidate.readinessState == "ready", candidate.fitState != "does_not_fit" else {
            let warnings = mergedWarnings(candidate, adding: [.requiresPreparation])
            return failureDocument(
                for: candidate,
                healthResult: "blocked",
                responseBody: nil,
                warnings: warnings,
                guidance: evaluationGuidance(health: "blocked", warnings: Set(warnings))
            )
        }

        guard candidate.runtimeSource == "ollama_loopback",
              let baseURL = BYOMLoopbackOriginValidator.validatedHTTPOrigin(environment.ollamaOrigin ?? ""),
              let runtimeModel = ollamaModelName(from: candidate.servedModelRef) else {
            let warnings = mergedWarnings(candidate, adding: [.requiresPreparation])
            return failureDocument(
                for: candidate,
                healthResult: "blocked",
                responseBody: nil,
                warnings: warnings,
                guidance: evaluationGuidance(health: "blocked", warnings: Set(warnings))
            )
        }

        return await evaluateOpenAICompatible(candidate: candidate, runtimeModel: runtimeModel, baseURL: baseURL)
    }

    private func evaluateOpenAICompatible(
        candidate: BYOMDiscoveryWire.Candidate,
        runtimeModel: String,
        baseURL: URL
    ) async -> BYOMEvaluationWire {
        let requestBody: Data
        do {
            requestBody = try BYOMEvaluationJSON.chatCompletionsRequest(model: runtimeModel, prompt: Self.prompt, maxTokens: limits.maxTokens)
        } catch {
            let warnings = mergedWarnings(candidate, adding: [.evaluationFailed])
            return failureDocument(
                for: candidate,
                healthResult: "failed",
                responseBody: nil,
                warnings: warnings,
                guidance: evaluationGuidance(health: "failed", warnings: Set(warnings))
            )
        }
        guard requestBody.count <= limits.maxRequestBytes else {
            let warnings = mergedWarnings(candidate, adding: [.adapterResponseTruncated, .evaluationFailed])
            return failureDocument(
                for: candidate,
                healthResult: "failed",
                responseBody: nil,
                warnings: warnings,
                guidance: evaluationGuidance(health: "failed", warnings: Set(warnings))
            )
        }

        let started = Date()
        do {
            let response = try await withTimeout(seconds: limits.timeoutSeconds) {
                try await httpClient.post(
                    baseURL.appendingPathComponent("v1/chat/completions"),
                    jsonBody: requestBody,
                    maxHeaderBytes: limits.maxHeaderBytes,
                    maxBodyBytes: limits.maxBodyBytes
                )
            }
            let elapsed = max(Date().timeIntervalSince(started), 0)
            guard response.statusCode == 200 else {
                let warnings = mergedWarnings(candidate, adding: nonOKWarnings(response))
                return failureDocument(
                    for: candidate,
                    healthResult: "failed",
                    latencyMs: milliseconds(elapsed),
                    responseBody: response.body,
                    requestCount: limits.requestCount,
                    warnings: warnings,
                    guidance: evaluationGuidance(health: "failed", warnings: Set(warnings))
                )
            }
            guard response.body.count <= limits.maxOutputBytes else {
                let warnings = mergedWarnings(candidate, adding: [.adapterResponseTruncated, .evaluationFailed])
                return failureDocument(
                    for: candidate,
                    healthResult: "failed",
                    latencyMs: milliseconds(elapsed),
                    responseBody: response.body,
                    requestCount: limits.requestCount,
                    warnings: warnings,
                    guidance: evaluationGuidance(health: "failed", warnings: Set(warnings))
                )
            }
            let parsed: BYOMEvaluationJSON.ParsedChatCompletion
            do {
                parsed = try BYOMEvaluationJSON.parseChatCompletions(
                    response.body,
                    maxCompletionTokens: limits.maxTokens
                )
            } catch let error as BYOMDiscoveryAdapterError {
                let warning: BYOMDiscoveryWarning = switch error {
                case .truncated:
                    .adapterResponseTruncated
                case .malformed:
                    .adapterMalformedResponse
                case .rejectedNonLoopback:
                    .adapterRejectedNonLoopback
                }
                let warnings = mergedWarnings(candidate, adding: [warning, .evaluationFailed])
                return failureDocument(
                    for: candidate,
                    healthResult: "failed",
                    latencyMs: milliseconds(elapsed),
                    responseBody: response.body,
                    requestCount: limits.requestCount,
                    warnings: warnings,
                    guidance: evaluationGuidance(health: "failed", warnings: Set(warnings))
                )
            } catch {
                let warnings = mergedWarnings(candidate, adding: [.adapterMalformedResponse, .evaluationFailed])
                return failureDocument(
                    for: candidate,
                    healthResult: "failed",
                    latencyMs: milliseconds(elapsed),
                    responseBody: response.body,
                    requestCount: limits.requestCount,
                    warnings: warnings,
                    guidance: evaluationGuidance(health: "failed", warnings: Set(warnings))
                )
            }
            let usageSource = parsed.completionTokens == nil ? "absent" : "runtime_reported"
            let tps: Double?
            if let tokens = parsed.completionTokens, elapsed > 0 {
                tps = (Double(tokens) / elapsed * 100).rounded() / 100
            } else {
                tps = nil
            }
            let warnings = mergedWarnings(candidate, excluding: [.evaluationRequired, .capabilityUnevaluated])
            return BYOMEvaluationWire(
                candidateID: candidate.candidateID,
                runtimeSource: candidate.runtimeSource,
                servedModelRef: candidate.servedModelRef,
                catalogModelKey: candidate.catalogModelKey,
                adapterIdentity: "openai_compatible_loopback",
                healthResult: "passed",
                latencyMs: milliseconds(elapsed),
                completionTokens: parsed.completionTokens,
                tokensPerSecond: tps,
                requestCount: limits.requestCount,
                outputBytes: response.body.count,
                usageReportingSource: usageSource,
                capabilityResults: capabilityResults(chatPassed: true, usageSource: usageSource),
                fitEstimateSource: "discovery_fit_state",
                mutationSummary: .none,
                diagnosticHashes: diagnosticHashes(responseBody: response.body),
                providerGuidance: evaluationGuidance(health: "passed", warnings: Set(warnings)),
                offerPreconditionsAppearSatisfied: candidate.admissionState == "offerable",
                warnings: warnings
            )
        } catch is CancellationError {
            let warnings = mergedWarnings(candidate, adding: [.adapterTimeout, .evaluationFailed])
            return failureDocument(
                for: candidate,
                healthResult: "timed_out",
                responseBody: nil,
                requestCount: limits.requestCount,
                warnings: warnings,
                guidance: evaluationGuidance(health: "timed_out", warnings: Set(warnings))
            )
        } catch let error as URLError where error.code == .timedOut {
            let warnings = mergedWarnings(candidate, adding: [.adapterTimeout, .evaluationFailed])
            return failureDocument(
                for: candidate,
                healthResult: "timed_out",
                responseBody: nil,
                requestCount: limits.requestCount,
                warnings: warnings,
                guidance: evaluationGuidance(health: "timed_out", warnings: Set(warnings))
            )
        } catch let error as BYOMDiscoveryAdapterError {
            let warning: BYOMDiscoveryWarning
            switch error {
            case .truncated:
                warning = .adapterResponseTruncated
            case .malformed:
                warning = .adapterMalformedResponse
            case .rejectedNonLoopback:
                warning = .adapterRejectedNonLoopback
            }
            let warnings = mergedWarnings(candidate, adding: [warning, .evaluationFailed])
            return failureDocument(
                for: candidate,
                healthResult: "failed",
                responseBody: nil,
                requestCount: limits.requestCount,
                warnings: warnings,
                guidance: evaluationGuidance(health: "failed", warnings: Set(warnings))
            )
        } catch {
            let warnings = mergedWarnings(candidate, adding: [.evaluationFailed])
            return failureDocument(
                for: candidate,
                healthResult: "failed",
                responseBody: nil,
                requestCount: limits.requestCount,
                warnings: warnings,
                guidance: evaluationGuidance(health: "failed", warnings: Set(warnings))
            )
        }
    }

    private func selectLocalEvaluationCandidate(from candidates: [BYOMDiscoveryWire.Candidate]) -> BYOMDiscoveryWire.Candidate? {
        let normalizedTarget = BYOMCandidateIdentity.normalizedServedModelRef(target)
        return candidates.first {
            $0.candidateID == target
                || BYOMCandidateIdentity.normalizedServedModelRef($0.servedModelRef) == normalizedTarget
                || BYOMCandidateIdentity.normalizedServedModelRef($0.displayName) == normalizedTarget
        }
    }

    private func ollamaModelName(from servedModelRef: String) -> String? {
        guard servedModelRef.hasPrefix("ollama:") else { return nil }
        let name = String(servedModelRef.dropFirst("ollama:".count))
        guard BYOMDiscoveryPrivacy.isSafeRuntimeModelReference(name) else { return nil }
        return name
    }

    private func mergedWarnings(
        _ candidate: BYOMDiscoveryWire.Candidate,
        adding added: [BYOMDiscoveryWarning] = [],
        excluding excluded: [BYOMDiscoveryWarning] = []
    ) -> [String] {
        var warnings = Set(candidate.warningCodes)
        warnings.formUnion(added.map(\.rawValue))
        warnings.subtract(excluded.map(\.rawValue))
        return Array(warnings).sorted()
    }

    private func failureDocument(
        for candidate: BYOMDiscoveryWire.Candidate,
        healthResult: String,
        latencyMs: Int? = nil,
        responseBody: Data?,
        requestCount: Int = 0,
        warnings: [String],
        guidance: BYOMDiscoveryWire.Guidance
    ) -> BYOMEvaluationWire {
        failureDocument(
            candidateID: candidate.candidateID,
            runtimeSource: candidate.runtimeSource,
            servedModelRef: candidate.servedModelRef,
            catalogModelKey: candidate.catalogModelKey,
            adapterIdentity: adapterIdentity(for: candidate),
            healthResult: healthResult,
            latencyMs: latencyMs,
            responseBody: responseBody,
            requestCount: requestCount,
            warnings: warnings,
            guidance: guidance
        )
    }

    private func failureDocument(
        candidateID: String,
        runtimeSource: String,
        servedModelRef: String,
        catalogModelKey: String?,
        adapterIdentity: String,
        healthResult: String,
        latencyMs: Int? = nil,
        responseBody: Data?,
        requestCount: Int = 0,
        warnings: [String],
        guidance: BYOMDiscoveryWire.Guidance
    ) -> BYOMEvaluationWire {
        BYOMEvaluationWire(
            candidateID: candidateID,
            runtimeSource: runtimeSource,
            servedModelRef: servedModelRef,
            catalogModelKey: catalogModelKey,
            adapterIdentity: adapterIdentity,
            healthResult: healthResult,
            latencyMs: latencyMs,
            completionTokens: nil,
            tokensPerSecond: nil,
            requestCount: requestCount,
            outputBytes: responseBody?.count ?? 0,
            usageReportingSource: "not_evaluated",
            capabilityResults: capabilityResults(chatPassed: false, usageSource: "not_evaluated"),
            fitEstimateSource: "discovery_fit_state",
            mutationSummary: .none,
            diagnosticHashes: diagnosticHashes(responseBody: responseBody),
            providerGuidance: guidance,
            offerPreconditionsAppearSatisfied: false,
            warnings: warnings
        )
    }

    private func adapterIdentity(for candidate: BYOMDiscoveryWire.Candidate) -> String {
        switch candidate.runtimeSource {
        case "ollama_loopback":
            return "openai_compatible_loopback"
        case "mlx_cache":
            return "mlx_cache_local_artifact"
        default:
            return "unknown"
        }
    }

    private func nonOKWarnings(_ response: BYOMHTTPResponse) -> [BYOMDiscoveryWarning] {
        guard (300..<400).contains(response.statusCode),
              let location = header("location", in: response.headers),
              let url = URL(string: location),
              !BYOMLoopbackOriginValidator.isSafeLoopbackHTTPURL(url) else {
            return [.evaluationFailed]
        }
        return [.adapterRejectedNonLoopback, .evaluationFailed]
    }

    private func header(_ name: String, in headers: [(String, String)]) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    private func capabilityResults(chatPassed: Bool, usageSource: String) -> [String: BYOMEvaluationWire.CapabilityResult] {
        [
            "chat_completions": BYOMEvaluationWire.CapabilityResult(
                result: chatPassed ? "passed" : "not_tested",
                source: chatPassed ? "evaluation" : "not_evaluated"
            ),
            "streaming": BYOMEvaluationWire.CapabilityResult(result: "not_tested", source: "not_evaluated"),
            "tool_call_passthrough": BYOMEvaluationWire.CapabilityResult(result: "not_tested", source: "not_evaluated"),
            "structured_output_passthrough": BYOMEvaluationWire.CapabilityResult(result: "not_tested", source: "not_evaluated"),
            "json_mode": BYOMEvaluationWire.CapabilityResult(result: "not_tested", source: "not_evaluated"),
            "usage_reporting": BYOMEvaluationWire.CapabilityResult(
                result: usageSource == "runtime_reported" ? "passed" : "not_tested",
                source: usageSource
            ),
        ]
    }

    /// Warnings that genuinely block progressing to an offer. Informational
    /// warnings that survive a successful probe (e.g. `catalog_match_unverified`)
    /// are NOT blockers, so a passed evaluation must not steer the operator to
    /// `fix_local_blocker` merely because such a warning is present.
    private static let evaluationBlockingWarningCodes: Set<String> = [
        BYOMDiscoveryWarning.candidateIDUnstable.rawValue,
        BYOMDiscoveryWarning.namespacePermissionInvalid.rawValue,
        BYOMDiscoveryWarning.adapterRejectedNonLoopback.rawValue,
        BYOMDiscoveryWarning.adapterMalformedResponse.rawValue,
        BYOMDiscoveryWarning.adapterResponseTruncated.rawValue,
        BYOMDiscoveryWarning.adapterTimeout.rawValue,
        BYOMDiscoveryWarning.evaluationFailed.rawValue,
        BYOMDiscoveryWarning.requiresPreparation.rawValue,
    ]

    private func evaluationGuidance(health: String, warnings: Set<String>) -> BYOMDiscoveryWire.Guidance {
        if health == "passed" {
            let hasBlocker = !warnings.isDisjoint(with: Self.evaluationBlockingWarningCodes)
            return BYOMDiscoveryWire.Guidance(
                stateLabelKey: "byom.evaluation.passed",
                stateMeaningKey: "byom.evaluation.passed_not_earning",
                nextAction: hasBlocker ? "fix_local_blocker" : "offer_dry_run",
                transitionReasonCode: warnings.sorted().first,
                earningPathClass: "local_inventory_only"
            )
        }
        return BYOMDiscoveryWire.Guidance(
            stateLabelKey: health == "timed_out" ? "byom.evaluation.timed_out" : "byom.evaluation.blocked_or_failed",
            stateMeaningKey: "byom.evaluation.not_earning",
            nextAction: "fix_local_blocker",
            transitionReasonCode: warnings.sorted().first,
            earningPathClass: "local_inventory_only"
        )
    }

    private func diagnosticHashes(responseBody: Data?) -> BYOMEvaluationWire.DiagnosticHashes {
        BYOMEvaluationWire.DiagnosticHashes(
            promptSHA256: sha256Hex(Data(Self.prompt.utf8)),
            responseBodySHA256: responseBody.map(sha256Hex)
        )
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw URLError(.timedOut)
            }
            return result
        }
    }

    private func milliseconds(_ seconds: TimeInterval) -> Int {
        max(0, Int((seconds * 1000).rounded()))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct BYOMOfferDryRunRunner: Sendable {
    private let target: String
    private let environment: BYOMDiscoveryEnvironment
    private let httpClient: any BYOMDiscoveryHTTPClient

    init(
        target: String,
        environment: BYOMDiscoveryEnvironment,
        httpClient: any BYOMDiscoveryHTTPClient = BYOMURLSessionHTTPClient()
    ) {
        self.target = target
        self.environment = environment
        self.httpClient = httpClient
    }

    func dryRun() async -> BYOMOfferDryRunWire {
        let discovery = await BYOMDiscoveryRunner(
            environment: environment,
            httpClient: httpClient
        ).discover()
        guard let candidate = selectLocalOfferCandidate(from: discovery.candidates) else {
            let reason = "candidate_not_found"
            let warnings = discovery.warnings.sorted()
            return BYOMOfferDryRunWire(
                candidateID: "unknown",
                servedModelRef: "unknown",
                catalogModelKey: nil,
                wouldSubmit: false,
                likelyAdmissionState: "local_only",
                likelyAdmissionStateSource: "local_default",
                providerGuidance: dryRunGuidance(
                    wouldSubmit: false,
                    catalogModelKey: nil,
                    reasonCode: reason,
                    warnings: warnings
                ),
                reasonCode: reason,
                warnings: warnings
            )
        }

        let warnings = candidate.warningCodes.sorted()
        let reason = reasonCode(for: candidate, warnings: Set(warnings))
        let wouldSubmit = canSubmitLocalDryRun(candidate: candidate, reasonCode: reason)
        return BYOMOfferDryRunWire(
            candidateID: candidate.candidateID,
            servedModelRef: candidate.servedModelRef,
            catalogModelKey: candidate.catalogModelKey,
            wouldSubmit: wouldSubmit,
            likelyAdmissionState: localDefaultAdmissionState(candidate.admissionState),
            likelyAdmissionStateSource: "local_default",
            providerGuidance: dryRunGuidance(
                wouldSubmit: wouldSubmit,
                catalogModelKey: candidate.catalogModelKey,
                reasonCode: reason,
                warnings: warnings
            ),
            reasonCode: reason,
            warnings: warnings
        )
    }

    private func selectLocalOfferCandidate(from candidates: [BYOMDiscoveryWire.Candidate]) -> BYOMDiscoveryWire.Candidate? {
        let normalizedTarget = BYOMCandidateIdentity.normalizedServedModelRef(target)
        return candidates.first {
            $0.candidateID == target
                || BYOMCandidateIdentity.normalizedServedModelRef($0.servedModelRef) == normalizedTarget
                || BYOMCandidateIdentity.normalizedServedModelRef($0.displayName) == normalizedTarget
        }
    }

    private func canSubmitLocalDryRun(candidate: BYOMDiscoveryWire.Candidate, reasonCode: String?) -> Bool {
        guard candidate.candidateID.hasPrefix("byom_"),
              !candidate.candidateID.hasPrefix("byom_unstable_"),
              candidate.admissionStateSource == "local_default",
              candidate.admissionState == "offerable",
              candidate.readinessState == "ready",
              candidate.fitState != "does_not_fit" else {
            return false
        }
        // `evaluation_required` is advisory, NOT a hard blocker: SPEC-047-R002
        // permits submitting an offer without the evaluation digest when the
        // dry-run labels it more likely to be rejected or confined to
        // non-earning states (which every v0.1 local_inventory_only candidate
        // is). Treating it as a hard block made would_submit unreachable, since
        // a freshly discovered candidate always carries evaluation_required.
        return !Set(candidate.warningCodes).contains(BYOMDiscoveryWarning.candidateIDUnstable.rawValue)
            && !Set(candidate.warningCodes).contains(BYOMDiscoveryWarning.namespacePermissionInvalid.rawValue)
            && reasonCode != BYOMDiscoveryWarning.requiresPreparation.rawValue
    }

    private func localDefaultAdmissionState(_ state: String) -> String {
        switch state {
        case "offerable", "not_offered":
            return state
        default:
            return "local_only"
        }
    }

    private func reasonCode(for candidate: BYOMDiscoveryWire.Candidate, warnings: Set<String>) -> String? {
        // evaluation_required is intentionally NOT a hard blocker here (it is
        // advisory per SPEC-047-R002); it remains available as a lower-priority
        // fallback reason below when nothing harder applies.
        let blockingReasons = [
            BYOMDiscoveryWarning.candidateIDUnstable.rawValue,
            BYOMDiscoveryWarning.namespacePermissionInvalid.rawValue,
            BYOMDiscoveryWarning.adapterRejectedNonLoopback.rawValue,
            BYOMDiscoveryWarning.adapterMalformedResponse.rawValue,
            BYOMDiscoveryWarning.adapterResponseTruncated.rawValue,
            BYOMDiscoveryWarning.requiresPreparation.rawValue,
        ]
        if let blocker = blockingReasons.first(where: warnings.contains) {
            return blocker
        }
        if candidate.catalogModelKey == nil {
            return "no_trusted_catalog_match"
        }
        if warnings.contains(BYOMDiscoveryWarning.catalogMatchUnverified.rawValue) {
            return "catalog_binding_unverified"
        }
        if warnings.contains(BYOMDiscoveryWarning.evaluationRequired.rawValue) {
            return BYOMDiscoveryWarning.evaluationRequired.rawValue
        }
        return nil
    }

    private func dryRunGuidance(
        wouldSubmit: Bool,
        catalogModelKey: String?,
        reasonCode: String?,
        warnings: [String]
    ) -> BYOMDiscoveryWire.Guidance {
        if wouldSubmit {
            if catalogModelKey == nil {
                return BYOMDiscoveryWire.Guidance(
                    stateLabelKey: "byom.offer_dry_run.would_submit",
                    stateMeaningKey: "byom.offer_dry_run.no_earning_path_v0_1",
                    nextAction: "submit_offer",
                    transitionReasonCode: reasonCode,
                    earningPathClass: "no_earning_path_in_v0_1"
                )
            }
            return BYOMDiscoveryWire.Guidance(
                stateLabelKey: "byom.offer_dry_run.would_submit",
                stateMeaningKey: "byom.offer_dry_run.catalog_path_missing_trusted_binding",
                nextAction: "submit_offer",
                transitionReasonCode: reasonCode,
                earningPathClass: "not_earning_yet_catalog_or_receipt_path_exists"
            )
        }
        if reasonCode == BYOMDiscoveryWarning.evaluationRequired.rawValue {
            if catalogModelKey == nil {
                return BYOMDiscoveryWire.Guidance(
                    stateLabelKey: "byom.offer_dry_run.blocked",
                    stateMeaningKey: "byom.offer_dry_run.no_earning_path_v0_1",
                    nextAction: "evaluate",
                    transitionReasonCode: reasonCode,
                    earningPathClass: "no_earning_path_in_v0_1"
                )
            }
            return BYOMDiscoveryWire.Guidance(
                stateLabelKey: "byom.offer_dry_run.blocked",
                stateMeaningKey: "byom.offer_dry_run.catalog_path_missing_trusted_binding",
                nextAction: "evaluate",
                transitionReasonCode: reasonCode,
                earningPathClass: "not_earning_yet_catalog_or_receipt_path_exists"
            )
        }
        return BYOMDiscoveryWire.Guidance(
            stateLabelKey: "byom.offer_dry_run.blocked",
            stateMeaningKey: "byom.offer_dry_run.not_submitted_not_earning",
            nextAction: "fix_local_blocker",
            transitionReasonCode: reasonCode ?? warnings.sorted().first,
            earningPathClass: "local_inventory_only"
        )
    }
}

struct BYOMDiscoveryNamespaceStore {
    struct Result: Sendable {
        let bytes: Data?
        let warnings: [BYOMDiscoveryWarning]
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Read-only namespace lookup. `models discover` MUST NOT mutate local state
    /// (SPEC-046-R001), so an absent salt yields unstable candidate IDs rather
    /// than provisioning the salt here; salt creation belongs to a later
    /// mutating command (e.g. offer), never to discovery.
    func readNamespace(at url: URL) -> Result {
        let parent = url.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: url.path) else {
            return Result(bytes: nil, warnings: [.candidateIDUnstable])
        }
        guard namespaceDirectoryPermissionsArePrivate(parent), namespaceFilePermissionsArePrivate(url) else {
            return Result(bytes: nil, warnings: [.namespacePermissionInvalid, .candidateIDUnstable])
        }
        guard let data = try? Data(contentsOf: url), data.count == 32 else {
            return Result(bytes: nil, warnings: [.namespacePermissionInvalid, .candidateIDUnstable])
        }
        return Result(bytes: data, warnings: [])
    }

    /// Provision the per-provider identity salt if absent, so that a DELIBERATE
    /// command (`models evaluate` / `models offer`) yields stable candidate IDs.
    /// This is the "later mutating command" the read-only discovery path defers
    /// to — the workflow is discover -> evaluate -> offer, so a stable identity
    /// must exist by evaluate. Idempotent: an existing salt is read unchanged, so
    /// this never rewrites it. The salt is local CLI identity state only (0700
    /// dir / 0600 file), never serving config or coordinator state.
    @discardableResult
    func provisionNamespaceIfMissing(at url: URL) -> Result {
        if fileManager.fileExists(atPath: url.path) {
            return readNamespace(at: url)
        }
        let parent = url.deletingLastPathComponent()
        // Create the parent dir only if missing (0700 is applied at creation).
        // Do NOT chmod an already-existing parent: the namespace path may be
        // operator-supplied, so rewriting an unrelated directory's permissions is
        // out of scope. An existing non-private parent just yields an unstable id
        // via readNamespace rather than a silent perms change on the user's dir.
        try? fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return Result(bytes: nil, warnings: [.candidateIDUnstable])
        }
        let data = Data(bytes)
        // Atomic exclusive create (O_EXCL): if a concurrent first-run provisioner
        // wins the race, read its salt instead of overwriting, so every command
        // converges on a single identity rather than diverging.
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        }
        if fd < 0 {
            return errno == EEXIST
                ? readNamespace(at: url)
                : Result(bytes: nil, warnings: [.candidateIDUnstable])
        }
        defer { close(fd) }
        _ = fchmod(fd, 0o600)
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base, raw.count)
        }
        guard written == data.count else {
            return Result(bytes: nil, warnings: [.candidateIDUnstable])
        }
        return Result(bytes: data, warnings: [])
    }

    private func namespaceDirectoryPermissionsArePrivate(_ url: URL) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeDirectory,
              let permissions = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o077 == 0
    }

    private func namespaceFilePermissionsArePrivate(_ url: URL) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeRegular,
              let permissions = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o077 == 0
    }
}

struct BYOMCandidateIdentity: Sendable {
    static func candidateID(namespace: Data?, runtimeSource: String, servedModelRef: String) -> (String, [BYOMDiscoveryWarning]) {
        let normalized = normalizedServedModelRef(servedModelRef)
        let framed = Data(runtimeSource.utf8) + Data([0]) + Data(normalized.utf8)
        guard let namespace, namespace.count == 32 else {
            let digest = SHA256.hash(data: framed)
            return ("byom_unstable_\(base32URLNoPadding(Data(digest)))", [.candidateIDUnstable])
        }
        let mac = HMAC<SHA256>.authenticationCode(for: framed, using: SymmetricKey(data: namespace))
        return ("byom_\(base32URLNoPadding(Data(mac)))", [])
    }

    static func normalizedServedModelRef(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: nil)
    }

    static func base32URLNoPadding(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var output = ""
        var buffer = 0
        var bitsLeft = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1f
                output.append(alphabet[index])
                bitsLeft -= 5
            }
        }
        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1f
            output.append(alphabet[index])
        }
        return output
    }
}

struct BYOMCatalogMatcher: Sendable {
    private let rows: [(key: String, modelID: String)]

    init() {
        let baked = Data(AutotuneStaticInputs.bakedCandidateCatalogJSON.utf8)
        if let catalog = try? AutotuneStaticInputs.decodeSignedStaticCandidateCatalog(baked) {
            rows = catalog.rows.map { (key: $0.key, modelID: $0.value.modelID) }
        } else {
            rows = []
        }
    }

    func catalogKey(for servedModelRef: String) -> String? {
        let normalized = BYOMCandidateIdentity.normalizedServedModelRef(servedModelRef)
        return rows.first { row in
            BYOMCandidateIdentity.normalizedServedModelRef(row.key) == normalized
                || BYOMCandidateIdentity.normalizedServedModelRef(row.modelID) == normalized
        }?.key
    }
}

struct BYOMMLXCacheDiscovery {
    private let cacheRoot: URL
    private let namespace: Data?
    private let namespaceWarnings: [BYOMDiscoveryWarning]
    private let catalogMatcher: BYOMCatalogMatcher
    private let fileManager: FileManager

    init(
        cacheRoot: URL,
        namespace: Data?,
        namespaceWarnings: [BYOMDiscoveryWarning] = [],
        catalogMatcher: BYOMCatalogMatcher,
        fileManager: FileManager = .default
    ) {
        self.cacheRoot = cacheRoot
        self.namespace = namespace
        self.namespaceWarnings = namespaceWarnings
        self.catalogMatcher = catalogMatcher
        self.fileManager = fileManager
    }

    /// Enumerate at most `cap` immediate children of `root`, then sort by name.
    /// Uses a streaming enumerator with an early cutoff so a cache root holding
    /// millions of entries cannot exhaust memory/time before the caller's
    /// `.prefix(...)` cap applies (bulk `contentsOfDirectory` materializes the
    /// whole listing first). `cap` is set well above the caller's prefix so
    /// normal caches enumerate fully and deterministically.
    private func boundedDirectoryEntries(at root: URL, cap: Int) -> [URL]? {
        // Treat a missing or non-directory path as unreadable (nil), matching
        // the throwing `contentsOfDirectory` this replaced — an `enumerator`
        // over a missing path yields an empty, non-nil sequence otherwise.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) else {
            return nil
        }
        var collected: [URL] = []
        collected.reserveCapacity(min(cap, 1024))
        for case let url as URL in enumerator {
            collected.append(url)
            if collected.count >= cap { break }
        }
        return collected.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    /// True when `url`, after symlink resolution, is `root` itself or lives
    /// under it — used to reject symlinks that escape the cache root.
    private func pathIsContained(_ url: URL, in root: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        if target == base { return true }
        return target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// Read a file only after confirming (via the resolved target's stat) that
    /// it is a regular file inside `root` and no larger than `maxBytes`. The
    /// size gate runs BEFORE any bytes are read, so a multi-GB or symlinked
    /// file cannot force an unbounded `Data(contentsOf:)` allocation.
    private func boundedFileContents(at url: URL, within root: URL, maxBytes: Int) -> Data? {
        let resolved = url.resolvingSymlinksInPath()
        guard pathIsContained(resolved, in: root),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size >= 0, size <= maxBytes else {
            return nil
        }
        return try? Data(contentsOf: resolved)
    }

    func discover() -> (adapter: BYOMDiscoveryWire.Adapter, candidates: [BYOMDiscoveryWire.Candidate]) {
        guard let entries = boundedDirectoryEntries(at: cacheRoot, cap: 4096) else {
            return (
                BYOMDiscoveryWire.Adapter(
                    runtimeSource: "mlx_cache",
                    status: "unavailable",
                    originClass: nil,
                    warningCodes: [BYOMDiscoveryWarning.adapterUnavailable.rawValue]
                ),
                []
            )
        }

        var candidates: [BYOMDiscoveryWire.Candidate] = []
        for entry in entries.prefix(200) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let modelID = modelID(fromHFCacheDirectoryName: entry.lastPathComponent) else {
                continue
            }
            let snapshotSummary = summarizeSnapshots(repoDirectory: entry)
            let candidate = buildCandidate(
                servedModelRef: modelID,
                readinessState: snapshotSummary.ready ? "ready" : "needs_weights",
                estimatedGB: estimatedGB(modelID: modelID, snapshotBytes: snapshotSummary.weightBytes),
                contextWindowTokens: snapshotSummary.contextWindowTokens,
                warningCodes: snapshotSummary.ready ? [] : [.requiresPreparation]
            )
            candidates.append(candidate)
        }

        return (
            BYOMDiscoveryWire.Adapter(
                runtimeSource: "mlx_cache",
                status: "ok",
                originClass: nil,
                warningCodes: []
            ),
            candidates
        )
    }

    private func modelID(fromHFCacheDirectoryName name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let modelID = String(name.dropFirst("models--".count))
            .replacingOccurrences(of: "--", with: "/")
        guard !modelID.isEmpty,
              BYOMDiscoveryPrivacy.isSafeModelReference(modelID),
              modelID.lowercased().contains("mlx") else {
            return nil
        }
        return modelID
    }

    private func summarizeSnapshots(repoDirectory: URL) -> (ready: Bool, weightBytes: UInt64, contextWindowTokens: Int?) {
        let snapshots = repoDirectory.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotDirs = boundedDirectoryEntries(at: snapshots, cap: 256) else {
            return (false, 0, nil)
        }
        var sawConfig = false
        var weightBytes: UInt64 = 0
        var context: Int?
        var inspected = 0
        for snapshot in snapshotDirs.prefix(20) {
            guard (try? snapshot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let config = boundedFileContents(
                at: snapshot.appendingPathComponent("config.json"),
                within: cacheRoot,
                maxBytes: 128 * 1024
            ) {
                sawConfig = true
                context = context ?? BYOMDiscoveryJSON.contextWindowTokens(from: config)
            }
            guard let enumerator = fileManager.enumerator(
                at: snapshot,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                inspected += 1
                if inspected > 2048 { break }
                guard BYOMMLXCacheDiscovery.isModelWeightFile(fileURL.lastPathComponent) else {
                    continue
                }
                // HF snapshots store weights as symlinks into the sibling
                // `blobs/` dir, so resolve the target (an unresolved symlink is
                // not `isRegularFile` and would be miscounted as missing) and
                // require it to stay under the cache root to block symlink escape.
                let resolved = fileURL.resolvingSymlinksInPath()
                guard pathIsContained(resolved, in: cacheRoot),
                      let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else {
                    continue
                }
                weightBytes += UInt64(values.fileSize ?? 0)
            }
        }
        return (sawConfig && weightBytes > 0, weightBytes, context)
    }

    private static func isModelWeightFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".safetensors")
            || lower.hasSuffix(".bin")
            || lower.hasSuffix(".gguf")
            || lower.hasSuffix(".npz")
    }

    private func estimatedGB(modelID: String, snapshotBytes: UInt64) -> Double? {
        if let estimate = ModelFit.estimateWeightSizeGB(modelID: modelID) {
            return Double(estimate)
        }
        guard snapshotBytes > 0 else { return nil }
        let gb = Double(snapshotBytes) / 1_073_741_824.0
        return (gb * 100).rounded() / 100
    }

    private func buildCandidate(
        servedModelRef: String,
        readinessState: String,
        estimatedGB: Double?,
        contextWindowTokens: Int?,
        warningCodes localWarnings: [BYOMDiscoveryWarning]
    ) -> BYOMDiscoveryWire.Candidate {
        let (candidateID, idWarnings) = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "mlx_cache",
            servedModelRef: servedModelRef
        )
        let catalogKey = catalogMatcher.catalogKey(for: servedModelRef)
        var warnings = Set((namespaceWarnings + idWarnings + localWarnings + [.capabilityUnevaluated, .evaluationRequired]).map(\.rawValue))
        if catalogKey != nil {
            warnings.insert(BYOMDiscoveryWarning.catalogMatchUnverified.rawValue)
        }
        let fit = fitState(modelID: servedModelRef)
        let admission = localAdmissionState(
            stableID: idWarnings.isEmpty,
            readinessState: readinessState,
            fitState: fit,
            blockingWarnings: warnings
        )
        return BYOMDiscoveryWire.Candidate(
            candidateID: candidateID,
            runtimeSource: "mlx_cache",
            displayName: BYOMDiscoveryPrivacy.displayName(from: servedModelRef),
            servedModelRef: servedModelRef,
            catalogModelKey: catalogKey,
            identityState: catalogKey == nil ? "runtime_reported" : "catalog_matched",
            locality: "local_artifact",
            estimatedGB: estimatedGB,
            contextWindowTokens: contextWindowTokens,
            capabilities: BYOMDiscoveryWire.Capabilities(
                chatCompletions: nil,
                streaming: nil,
                toolCallPassthrough: nil,
                structuredOutputPassthrough: nil,
                jsonMode: nil,
                usageReporting: nil,
                maxContextTokens: contextWindowTokens,
                quantization: BYOMDiscoveryPrivacy.safeOptionalLabel(BYOMDiscoveryPrivacy.quantizationHint(from: servedModelRef)),
                family: nil,
                runtimeVersion: nil
            ),
            readinessState: readinessState,
            fitState: fit,
            evaluationState: "not_evaluated",
            admissionState: admission,
            admissionStateSource: "local_default",
            providerGuidance: BYOMDiscoveryGuidance.guidance(forAdmissionState: admission, warnings: warnings),
            warningCodes: Array(warnings).sorted()
        )
    }

    private func fitState(modelID: String) -> String {
        switch ModelFit.evaluate(modelID: modelID, ramGB: ModelFit.detectRAMGB()) {
        case .fits, .tight:
            return "fits"
        case .wontFit:
            return "does_not_fit"
        case .unknown:
            return "unknown"
        }
    }
}

struct BYOMOllamaDiscovery: Sendable {
    private let origin: String
    private let namespace: Data?
    private let namespaceWarnings: [BYOMDiscoveryWarning]
    private let catalogMatcher: BYOMCatalogMatcher
    private let httpClient: any BYOMDiscoveryHTTPClient

    init(
        origin: String,
        namespace: Data?,
        namespaceWarnings: [BYOMDiscoveryWarning] = [],
        catalogMatcher: BYOMCatalogMatcher,
        httpClient: any BYOMDiscoveryHTTPClient
    ) {
        self.origin = origin
        self.namespace = namespace
        self.namespaceWarnings = namespaceWarnings
        self.catalogMatcher = catalogMatcher
        self.httpClient = httpClient
    }

    func discover() async -> (adapter: BYOMDiscoveryWire.Adapter, candidates: [BYOMDiscoveryWire.Candidate]) {
        guard let baseURL = BYOMLoopbackOriginValidator.validatedHTTPOrigin(origin) else {
            return (
                BYOMDiscoveryWire.Adapter(
                    runtimeSource: "ollama_loopback",
                    status: "rejected",
                    originClass: "rejected",
                    warningCodes: [BYOMDiscoveryWarning.adapterRejectedNonLoopback.rawValue]
                ),
                []
            )
        }

        do {
            let response = try await httpClient.get(
                baseURL.appendingPathComponent("api/tags"),
                maxHeaderBytes: BYOMDiscoveryHTTPBounds.maxHeaderBytes,
                maxBodyBytes: BYOMDiscoveryHTTPBounds.maxBodyBytes
            )
            guard response.statusCode == 200 else {
                return adapterFailure(.adapterUnavailable, status: "unavailable")
            }
            guard BYOMDiscoveryHTTPBounds.headerBytes(response.headers) <= BYOMDiscoveryHTTPBounds.maxHeaderBytes else {
                return adapterFailure(.adapterResponseTruncated, status: "truncated")
            }
            guard response.body.count <= BYOMDiscoveryHTTPBounds.maxBodyBytes else {
                return adapterFailure(.adapterResponseTruncated, status: "truncated")
            }
            let models = try BYOMDiscoveryJSON.parseOllamaTags(response.body)
            return (
                BYOMDiscoveryWire.Adapter(
                    runtimeSource: "ollama_loopback",
                    status: "ok",
                    originClass: "loopback_http",
                    warningCodes: []
                ),
                models.map(buildCandidate)
            )
        } catch is CancellationError {
            return adapterFailure(.adapterTimeout, status: "timeout")
        } catch let error as URLError where error.code == .timedOut {
            return adapterFailure(.adapterTimeout, status: "timeout")
        } catch let error as BYOMDiscoveryAdapterError {
            switch error {
            case .malformed:
                return adapterFailure(.adapterMalformedResponse, status: "malformed")
            case .truncated:
                return adapterFailure(.adapterResponseTruncated, status: "truncated")
            case .rejectedNonLoopback:
                return adapterFailure(.adapterRejectedNonLoopback, status: "rejected")
            }
        } catch {
            return adapterFailure(.adapterUnavailable, status: "unavailable")
        }
    }

    private func adapterFailure(
        _ warning: BYOMDiscoveryWarning,
        status: String
    ) -> (adapter: BYOMDiscoveryWire.Adapter, candidates: [BYOMDiscoveryWire.Candidate]) {
        (
            BYOMDiscoveryWire.Adapter(
                runtimeSource: "ollama_loopback",
                status: status,
                originClass: "loopback_http",
                warningCodes: [warning.rawValue]
            ),
            []
        )
    }

    private func buildCandidate(_ model: BYOMDiscoveryJSON.OllamaModel) -> BYOMDiscoveryWire.Candidate {
        let servedModelRef = "ollama:\(model.name)"
        let (candidateID, idWarnings) = BYOMCandidateIdentity.candidateID(
            namespace: namespace,
            runtimeSource: "ollama_loopback",
            servedModelRef: servedModelRef
        )
        let catalogKey = catalogMatcher.catalogKey(for: model.name)
        var warnings = Set((namespaceWarnings + idWarnings + [.capabilityUnevaluated, .evaluationRequired]).map(\.rawValue))
        if catalogKey != nil {
            warnings.insert(BYOMDiscoveryWarning.catalogMatchUnverified.rawValue)
        }
        let fit = fitState(modelID: model.name)
        let admission = localAdmissionState(
            stableID: idWarnings.isEmpty,
            readinessState: "ready",
            fitState: fit,
            blockingWarnings: warnings
        )
        return BYOMDiscoveryWire.Candidate(
            candidateID: candidateID,
            runtimeSource: "ollama_loopback",
            displayName: BYOMDiscoveryPrivacy.displayName(from: model.name),
            servedModelRef: servedModelRef,
            catalogModelKey: catalogKey,
            identityState: catalogKey == nil ? "runtime_reported" : "catalog_matched",
            locality: "loopback_runtime",
            estimatedGB: ModelFit.estimateWeightSizeGB(modelID: model.name).map(Double.init),
            contextWindowTokens: nil,
            capabilities: BYOMDiscoveryWire.Capabilities(
                chatCompletions: true,
                streaming: nil,
                toolCallPassthrough: nil,
                structuredOutputPassthrough: nil,
                jsonMode: nil,
                usageReporting: nil,
                maxContextTokens: nil,
                quantization: BYOMDiscoveryPrivacy.safeOptionalLabel(model.quantization),
                family: BYOMDiscoveryPrivacy.safeOptionalLabel(model.family),
                runtimeVersion: nil
            ),
            readinessState: "ready",
            fitState: fit,
            evaluationState: "not_evaluated",
            admissionState: admission,
            admissionStateSource: "local_default",
            providerGuidance: BYOMDiscoveryGuidance.guidance(forAdmissionState: admission, warnings: warnings),
            warningCodes: Array(warnings).sorted()
        )
    }

    private func fitState(modelID: String) -> String {
        switch ModelFit.evaluate(modelID: modelID, ramGB: ModelFit.detectRAMGB()) {
        case .fits, .tight:
            return "fits"
        case .wontFit:
            return "does_not_fit"
        case .unknown:
            return "unknown"
        }
    }
}

enum BYOMLoopbackOriginValidator {
    static func validatedHTTPOrigin(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              isLoopbackLiteral(host),
              components.port.map({ (1...65535).contains($0) }) ?? false else {
            return nil
        }
        guard components.path.isEmpty || components.path == "/" else {
            return nil
        }
        components.path = ""
        return components.url
    }

    static func isSafeLoopbackHTTPURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              isLoopbackLiteral(host),
              components.port.map({ (1...65535).contains($0) }) ?? false else {
            return false
        }
        return true
    }

    static func isLoopbackLiteral(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "::1" { return true }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4
            && UInt8(parts[0]) == 127
            && parts.dropFirst().allSatisfy { UInt8($0) != nil }
    }
}

enum BYOMDiscoveryHTTPBounds {
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 256 * 1024

    static func headerBytes(_ headers: [(String, String)]) -> Int {
        headers.reduce(0) { total, header in
            total + header.0.utf8.count + header.1.utf8.count
        }
    }
}

enum BYOMDiscoveryJSON {
    struct OllamaModel: Equatable {
        let name: String
        let family: String?
        let quantization: String?
    }

    static func parseOllamaTags(_ data: Data) throws -> [OllamaModel] {
        guard let text = String(data: data, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text),
              case .array(let rawModels)? = root["models"] else {
            throw BYOMDiscoveryAdapterError.malformed
        }
        return rawModels.prefix(100).compactMap { value in
            guard case .object(let object) = value,
                  case .string(let name)? = object["name"],
                  BYOMDiscoveryPrivacy.isSafeRuntimeModelReference(name) else {
                return nil
            }
            let details: [String: JSONValue]
            if case .object(let detailObject)? = object["details"] {
                details = detailObject
            } else {
                details = [:]
            }
            return OllamaModel(
                name: name,
                family: stringField("family", in: details),
                quantization: stringField("quantization_level", in: details)
            )
        }
    }

    static func contextWindowTokens(from data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text) else {
            return nil
        }
        for key in ["max_position_embeddings", "model_max_length", "max_sequence_length", "n_ctx"] {
            if let value = intField(key, in: root), value > 0 {
                return value
            }
        }
        return nil
    }

    private static func stringField(_ key: String, in object: [String: JSONValue]) -> String? {
        guard case .string(let value)? = object[key] else { return nil }
        return value
    }

    private static func intField(_ key: String, in object: [String: JSONValue]) -> Int? {
        switch object[key] {
        case .int(let value)?:
            return value
        case .double(let value)?:
            // Int(exactly:) rejects non-integral, out-of-range, NaN and infinite
            // values (e.g. a hostile config.json with 1e20), where Int(_:) would
            // trap and abort discovery.
            return Int(exactly: value)
        default:
            return nil
        }
    }
}

enum BYOMEvaluationJSON {
    struct ParsedChatCompletion: Equatable, Sendable {
        let completionTokens: Int?
    }

    static func chatCompletionsRequest(model: String, prompt: String, maxTokens: Int) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                [
                    "role": "user",
                    "content": prompt,
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func parseChatCompletions(_ data: Data, maxCompletionTokens: Int) throws -> ParsedChatCompletion {
        guard data.count <= BYOMDiscoveryHTTPBounds.maxBodyBytes,
              let text = String(data: data, encoding: .utf8),
              case .object(let root) = try? StrictJSONParser.parse(text),
              case .array(let choices)? = root["choices"],
              let firstChoice = choices.first,
              isValidProbeChoice(firstChoice) else {
            throw BYOMDiscoveryAdapterError.malformed
        }
        let usageTokens: Int?
        if case .object(let usage)? = root["usage"] {
            usageTokens = try completionTokens(in: usage, maxCompletionTokens: maxCompletionTokens)
        } else {
            usageTokens = nil
        }
        return ParsedChatCompletion(completionTokens: usageTokens)
    }

    private static func isValidProbeChoice(_ value: JSONValue) -> Bool {
        guard case .object(let choice) = value,
              case .object(let message)? = choice["message"],
              case .string(let content)? = message["content"],
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if case .string(let role)? = message["role"],
           role.lowercased() != "assistant" {
            return false
        }
        return true
    }

    private static func completionTokens(
        in object: [String: JSONValue],
        maxCompletionTokens: Int
    ) throws -> Int? {
        for key in ["completion_tokens", "completionTokens", "output_tokens"] {
            guard let value = object[key] else { continue }
            switch value {
            case .int(let tokens) where tokens >= 0 && tokens <= maxCompletionTokens:
                return tokens
            case .double(let tokens)
                where tokens.isFinite
                    && tokens >= 0
                    && tokens <= Double(maxCompletionTokens)
                    && tokens.rounded(.towardZero) == tokens:
                guard let exact = Int(exactly: tokens), exact <= maxCompletionTokens else {
                    throw BYOMDiscoveryAdapterError.malformed
                }
                return exact
            default:
                throw BYOMDiscoveryAdapterError.malformed
            }
        }
        return nil
    }
}

enum BYOMDiscoveryPrivacy {
    static func isSafeModelReference(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else { return false }
        let lower = trimmed.lowercased()
        guard !trimmed.contains(".."),
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("@"),
              !trimmed.contains("="),
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              !trimmed.contains("&"),
              !lower.contains("://"),
              !lower.hasPrefix("http:"),
              !lower.hasPrefix("https:"),
              !lower.hasPrefix("file:"),
              !lower.hasPrefix("unix:"),
              !lower.hasPrefix("ws:"),
              !lower.hasPrefix("wss:"),
              !lower.contains("token="),
              !lower.contains("api_key="),
              !lower.contains("apikey="),
              !lower.contains("secret="),
              !lower.contains("authorization="),
              !lower.contains("password="),
              !lower.contains("bearer ") else {
            return false
        }
        guard !looksLikeEndpoint(trimmed), !looksLikeCredential(trimmed) else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x21 && scalar.value <= 0x7e
                && scalar != "<"
                && scalar != ">"
                && scalar != "\""
                && scalar != "'"
                && scalar != ";"
        }
    }

    static func isSafeRuntimeModelReference(_ value: String) -> Bool {
        guard isSafeModelReference(value), !value.contains("/") else { return false }
        // Structural IP guard: reject when the authority (the part before an
        // optional `:<tag>`/`:<port>`) is an all-numeric or 0x-hex dotted
        // address. This closes every IPv4 shorthand at once — 127.1, 127.0.1,
        // 0177.1, 0x7f.1, 017700000001, 2130706433, 0x7f000001 — where an
        // encoding-by-encoding blocklist cannot. A legitimate model name's
        // pre-tag part always carries a non-hex letter or hyphen, so it is
        // unaffected (llama3.2:3b, qwen2.5-coder:7b, mistral-7b-instruct-v0.2).
        let authority = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? value
        if authority.range(
            of: #"^(0[xX][0-9A-Fa-f]+|[0-9]+)(\.(0[xX][0-9A-Fa-f]+|[0-9]+))*$"#,
            options: .regularExpression
        ) != nil {
            return false
        }
        return true
    }

    static func displayName(from value: String) -> String {
        let safe = value.unicodeScalars.map { scalar -> Character in
            if scalar.value >= 0x20 && scalar.value <= 0x7e,
               scalar != "<",
               scalar != ">",
               scalar != "\"",
               scalar != "'" {
                return Character(scalar)
            }
            return "?"
        }
        let string = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(string.prefix(128))
    }

    static func safeOptionalLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 64,
              !looksSensitive(trimmed),
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value <= 0x7e
                      && (scalar.properties.isAlphabetic
                          || scalar.properties.isMath
                          || CharacterSet.decimalDigits.contains(scalar)
                          || scalar == "_"
                          || scalar == "-"
                          || scalar == "."
                          || scalar == "+")
              }) else {
            return nil
        }
        return trimmed
    }

    private static func looksSensitive(_ value: String) -> Bool {
        let lower = value.lowercased()
        return value.contains("/")
            || value.contains("\\")
            || value.contains("=")
            || value.contains("?")
            || value.contains("#")
            || value.contains("&")
            || value.contains("@")
            || lower.contains("://")
            || lower.hasPrefix("http:")
            || lower.hasPrefix("https:")
            || lower.hasPrefix("file:")
            || lower.hasPrefix("unix:")
            || lower.contains("token")
            || lower.contains("api_key")
            || lower.contains("apikey")
            || lower.contains("secret")
            || lower.contains("authorization")
            || lower.contains("password")
            || lower.contains("bearer ")
            || looksLikeEndpoint(value)
            || looksLikeCredential(value)
    }

    private static func looksLikeEndpoint(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        // Loopback names and ANY IPv6 form — `localhost` and the `::` / bracket
        // notations never appear in a legitimate model reference, so match them
        // anywhere in the string (embedded, with a port, etc.).
        if lower.contains("localhost") || trimmed.contains("::") {
            return true
        }
        if trimmed.range(of: #"\[[0-9A-Fa-f:]+\]"#, options: .regularExpression) != nil {
            return true
        }
        // Uncompressed IPv6 (>=4 colon-separated hex groups).
        if trimmed.range(of: #"(^|[^0-9A-Za-z:])([0-9A-Fa-f]{1,4}:){3,}[0-9A-Fa-f]{1,4}"#, options: .regularExpression) != nil {
            return true
        }
        // Dotted IPv4 (four octets: decimal, octal 0177, or hex 0x7f), matched
        // when embedded or carrying a :port — not just as the whole value.
        if trimmed.range(
            of: #"(^|[^0-9A-Za-z])(0?[0-9]{1,3}|0[xX][0-9A-Fa-f]{1,2})(\.(0?[0-9]{1,4}|0[xX][0-9A-Fa-f]{1,4})){3}($|[^0-9A-Za-z.])"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        // One-piece encoded IPv4: a hex dword (0x7f000001) or a bare 32-bit
        // decimal (2130706433), boundary-delimited so a :port suffix is caught.
        if trimmed.range(of: #"(^|[^0-9A-Za-z])0[xX][0-9A-Fa-f]{5,8}($|[^0-9A-Za-z])"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"(^|[^0-9A-Za-z])[0-9]{8,10}($|[^0-9A-Za-z])"#, options: .regularExpression) != nil {
            return true
        }
        // Any DNS hostname: one or more dotted labels ending in an alphabetic
        // TLD (public OR private like .local/.internal, optional trailing dot,
        // with or without a port or scheme/path). Legitimate model refs put only
        // numeric version tokens after a dot (e.g. `llama3.2`, `mistral-7b-v0.2`),
        // so their final label is never a bare alpha TLD and they are unaffected.
        return trimmed.range(
            of: #"(^|[^A-Za-z0-9_-])([A-Za-z0-9-]+\.)+[A-Za-z]{2,}\.?($|[^A-Za-z0-9-])"#,
            options: .regularExpression
        ) != nil
    }

    private static func looksLikeCredential(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("sk-") || lower.hasPrefix("ghp_") || lower.hasPrefix("github_pat_") {
            return true
        }
        if lower.hasPrefix("xoxb-") || lower.hasPrefix("xoxp-") || lower.hasPrefix("xoxa-") || lower.hasPrefix("xoxr-") {
            return true
        }
        if trimmed.range(of: #"^eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$"#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.range(of: #"^[A-Za-z0-9_-]{40,}$"#, options: .regularExpression) != nil
    }

    static func quantizationHint(from value: String) -> String? {
        let lower = value.lowercased()
        if lower.contains("4bit") || lower.contains("-q4") || lower.contains("_q4") {
            return "q4"
        }
        if lower.contains("8bit") || lower.contains("-q8") || lower.contains("_q8") {
            return "q8"
        }
        if lower.contains("bf16") {
            return "bf16"
        }
        if lower.contains("fp16") || lower.contains("-f16") {
            return "fp16"
        }
        return nil
    }
}

enum BYOMDiscoveryGuidance {
    static func guidance(forAdmissionState state: String, warnings: Set<String>) -> BYOMDiscoveryWire.Guidance {
        switch state {
        case "offerable":
            return BYOMDiscoveryWire.Guidance(
                stateLabelKey: "byom.local.offerable",
                stateMeaningKey: "byom.local.offerable_not_earning",
                nextAction: warnings.contains(BYOMDiscoveryWarning.evaluationRequired.rawValue) ? "evaluate" : "offer_dry_run",
                transitionReasonCode: nil,
                earningPathClass: "local_inventory_only"
            )
        default:
            return BYOMDiscoveryWire.Guidance(
                stateLabelKey: "byom.local.local_only",
                stateMeaningKey: "byom.local.local_only_not_earning",
                nextAction: "fix_local_blocker",
                transitionReasonCode: warnings.sorted().first,
                earningPathClass: "local_inventory_only"
            )
        }
    }
}

private func localAdmissionState(
    stableID: Bool,
    readinessState: String,
    fitState: String,
    blockingWarnings: Set<String>
) -> String {
    let blockingWarningCodes = Set([
        BYOMDiscoveryWarning.candidateIDUnstable.rawValue,
        BYOMDiscoveryWarning.namespacePermissionInvalid.rawValue,
        BYOMDiscoveryWarning.adapterRejectedNonLoopback.rawValue,
        BYOMDiscoveryWarning.adapterMalformedResponse.rawValue,
        BYOMDiscoveryWarning.adapterResponseTruncated.rawValue,
        BYOMDiscoveryWarning.requiresPreparation.rawValue,
    ])
    guard stableID,
          readinessState == "ready",
          fitState != "does_not_fit",
          blockingWarnings.isDisjoint(with: blockingWarningCodes) else {
        return "local_only"
    }
    return "offerable"
}
