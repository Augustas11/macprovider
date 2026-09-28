import Foundation
import MacProviderCore

enum DecodePath: String, Sendable, Equatable {
    case ordinary
    case classicDraftSpec = "classic_draft_spec"
    case nativeMTP = "native_mtp"
}

enum NativeMTPMode: String, Sendable, Equatable {
    case off
    case auto
}

struct DecodePathSelection: Sendable, Equatable {
    let path: DecodePath
    let nativeMTPReason: NativeMTPSelectorReason?
}

struct NativeMTPCapability: Sendable, Equatable {
    let admitted: Bool
    let revoked: Bool
    let revocationStateAvailable: Bool
    let supportsCurrentProcessor: Bool
    let supportsCurrentStateCache: Bool
    let supportsStreaming: Bool
    let supportsNonStreaming: Bool
    let supportsStopSequences: Bool
    let hasQualifiedRowMappedTransactions: Bool
    let maximumProposalDepth: Int

    static let unavailable = NativeMTPCapability(
        admitted: false,
        revoked: false,
        revocationStateAvailable: false,
        supportsCurrentProcessor: false,
        supportsCurrentStateCache: false,
        supportsStreaming: false,
        supportsNonStreaming: false,
        supportsStopSequences: false,
        hasQualifiedRowMappedTransactions: false,
        maximumProposalDepth: 0
    )
}

enum NativeMTPSelectorReason: String, CaseIterable, Sendable {
    case eligible
    case modeOff = "mode_off"
    case classicDraftConfigured = "classic_draft_configured"
    case sampling
    case multipleCompletions = "multiple_completions"
    case tools
    case structuredOutput = "structured_output"
    case logprobs
    case logitControls = "logit_controls"
    case reasoningOrTemplate = "reasoning_or_template"
    case unknownRequestField = "unknown_request_field"
    case conversationKey = "conversation_key"
    case multimodal
    case unsupportedProcessor = "unsupported_processor"
    case unsupportedStateCache = "unsupported_state_cache"
    case insufficientVerificationCapacity = "insufficient_verification_capacity"
    case capabilityMismatch = "capability_mismatch"
    case tupleNotAdmitted = "tuple_not_admitted"
    case tupleRevoked = "tuple_revoked"
    case revocationStateUnavailable = "revocation_state_unavailable"

    var isEligible: Bool { self == .eligible }
}

struct NativeMTPSelector: Sendable {
    static let admittedTopLevelKeys: Set<String> = [
        "model",
        "messages",
        "max_tokens",
        "stream",
        "stream_options",
        "temperature",
        "top_p",
        "top_k",
        "min_p",
        "presence_penalty",
        "frequency_penalty",
        "repetition_penalty",
        "n",
        "response_format",
        "tools",
        "tool_choice",
        "logprobs",
        "top_logprobs",
        "logit_bias",
        "stop",
        "seed",
        "user",
    ]

    static let admittedStreamOptionKeys: Set<String> = ["include_usage"]

    static func select(
        request: ChatCompletionRequest,
        draftConfigured: Bool,
        draftLoaded: Bool,
        numDraftTokens: Int?,
        nativeMTPMode: NativeMTPMode,
        nativeCapability: NativeMTPCapability?
    ) -> DecodePathSelection {
        if draftConfigured {
            let classic = ModelRuntime.speculativeRoute(
                for: request,
                draftLoaded: draftLoaded,
                numDraftTokens: numDraftTokens
            )
            return DecodePathSelection(
                path: classic == .speculative ? .classicDraftSpec : .ordinary,
                nativeMTPReason: .classicDraftConfigured
            )
        }

        let reason = reason(
            request: request,
            mode: nativeMTPMode,
            nativeCapability: nativeCapability
        )
        return DecodePathSelection(
            path: reason.isEligible ? .nativeMTP : .ordinary,
            nativeMTPReason: reason
        )
    }

    static func reason(
        request: ChatCompletionRequest,
        mode: NativeMTPMode,
        nativeCapability: NativeMTPCapability?
    ) -> NativeMTPSelectorReason {
        guard mode == .auto else {
            return .modeOff
        }
        guard let nativeCapability else { return .capabilityMismatch }
        guard nativeCapability.hasQualifiedRowMappedTransactions else {
            return .capabilityMismatch
        }
        guard nativeCapability.revocationStateAvailable else {
            return .revocationStateUnavailable
        }
        guard !nativeCapability.revoked else {
            return .tupleRevoked
        }
        guard nativeCapability.admitted else {
            return .tupleNotAdmitted
        }
        guard nativeCapability.supportsCurrentProcessor else {
            return .unsupportedProcessor
        }
        guard nativeCapability.supportsCurrentStateCache else {
            return .unsupportedStateCache
        }
        guard request.stream
                ? nativeCapability.supportsStreaming
                : nativeCapability.supportsNonStreaming else {
            return .capabilityMismatch
        }
        guard nativeCapability.maximumProposalDepth > 0 else {
            return .insufficientVerificationCapacity
        }
        guard request.stop.isEmpty || nativeCapability.supportsStopSequences else {
            return .capabilityMismatch
        }
        guard request.topLevelKeys.isSubset(of: admittedTopLevelKeys),
              request.streamOptionKeys.isSubset(of: admittedStreamOptionKeys) else {
            return .unknownRequestField
        }
        guard request.temperature == 0.0, request.topP == 1.0 else {
            return .sampling
        }
        guard jsonInt(request.promptSource.n) ?? 1 == 1 else {
            return .multipleCompletions
        }
        guard request.presencePenalty == 0.0,
              request.frequencyPenalty == 0.0,
              isAbsentOrNull(request.promptSource.topK),
              absentOrZero(request.promptSource.minPValue),
              absentOrOne(request.promptSource.repetitionPenaltyValue) else {
            return .logitControls
        }
        guard request.conversationKey == nil else {
            return .conversationKey
        }
        guard !request.containsNonTextMessageContentPart else {
            return .multimodal
        }
        guard case .text = request.responseFormat else {
            return .structuredOutput
        }
        guard hasNoTools(request.promptSource.tools),
              isAbsentOrNull(request.promptSource.toolChoice),
              !hasToolTurnState(request.messages) else {
            return .tools
        }
        guard isAbsentNullOrFalse(request.promptSource.logprobs),
              isAbsentOrNull(request.promptSource.topLogprobs) else {
            return .logprobs
        }
        guard isAbsentOrNull(request.promptSource.logitBias) else {
            return .logitControls
        }
        guard !HarmonyResponseParser.isHarmonyModelID(request.model) else {
            return .reasoningOrTemplate
        }
        return .eligible
    }

    private static func hasNoTools(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:
            return true
        case .array(let entries):
            return entries.isEmpty
        default:
            return false
        }
    }

    private static func isAbsentOrNull(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:
            return true
        default:
            return false
        }
    }

    private static func isAbsentNullOrFalse(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:
            return true
        case .bool(let bool):
            return bool == false
        default:
            return false
        }
    }

    private static func hasToolTurnState(_ messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            message.role == .tool || !(message.toolCalls?.isEmpty ?? true)
        }
    }

    private static func jsonInt(_ value: JSONValue?) -> Int? {
        guard case .int(let int)? = value else { return nil }
        return int
    }

    private static func absentOrZero(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:
            return true
        case .int(let int):
            return int == 0
        case .double(let double):
            return double == 0
        default:
            return false
        }
    }

    private static func absentOrOne(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null:
            return true
        case .int(let int):
            return int == 1
        case .double(let double):
            return double == 1
        default:
            return false
        }
    }
}

private extension ChatCompletionPromptSource {
    var minPValue: JSONValue? { minP }
    var repetitionPenaltyValue: JSONValue? { repetitionPenalty }
}
