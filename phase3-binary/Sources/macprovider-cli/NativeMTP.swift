import Foundation
import MacProviderCore

enum DecodePath: String, Sendable, Equatable {
    case ordinary
    case classicDraftSpec = "classic_draft_spec"
    case nativeMTP = "native_mtp"
}

enum NativeMTPProposalBounds {
    /// `maximumBlockSize` is the total target-verification width: the current
    /// bonus token plus the proposed tokens. A signed proposal depth therefore
    /// needs one extra slot and must never be silently clamped.
    static func fits(maximumProposalDepth: Int, maximumBlockSize: Int?) -> Bool {
        guard maximumProposalDepth >= 1 else { return false }
        guard let maximumBlockSize else { return true }
        return maximumBlockSize > 0 && maximumProposalDepth <= maximumBlockSize - 1
    }
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
    let maximumPromptTokens: Int
    let maximumCompletionTokens: Int
    let completeWindowBytesByDepth: [Int]
    let family: String?
    let throughputDeltaPPM: Int
    /// SPEC-048-R007 signed load bound. `Int.max` is only for capabilities
    /// that never came from a signed sidecar (unit fixtures).
    let maximumNativeActiveRows: Int
    /// The signed tuple qualified sampled rows (SPEC-023-R024
    /// `native_mtp_sampled_text_v1`); greedy-only tuples route them ordinary.
    let supportsSampling: Bool

    init(
        admitted: Bool,
        revoked: Bool,
        revocationStateAvailable: Bool,
        supportsCurrentProcessor: Bool,
        supportsCurrentStateCache: Bool,
        supportsStreaming: Bool,
        supportsNonStreaming: Bool,
        supportsStopSequences: Bool,
        hasQualifiedRowMappedTransactions: Bool,
        maximumProposalDepth: Int,
        maximumPromptTokens: Int,
        maximumCompletionTokens: Int,
        completeWindowBytesByDepth: [Int] = [],
        family: String? = nil,
        throughputDeltaPPM: Int = 0,
        maximumNativeActiveRows: Int = Int.max,
        supportsSampling: Bool = false
    ) {
        self.admitted = admitted
        self.revoked = revoked
        self.revocationStateAvailable = revocationStateAvailable
        self.supportsCurrentProcessor = supportsCurrentProcessor
        self.supportsCurrentStateCache = supportsCurrentStateCache
        self.supportsStreaming = supportsStreaming
        self.supportsNonStreaming = supportsNonStreaming
        self.supportsStopSequences = supportsStopSequences
        self.hasQualifiedRowMappedTransactions = hasQualifiedRowMappedTransactions
        self.maximumProposalDepth = maximumProposalDepth
        self.maximumPromptTokens = maximumPromptTokens
        self.maximumCompletionTokens = maximumCompletionTokens
        self.completeWindowBytesByDepth = completeWindowBytesByDepth
        self.family = family
        self.throughputDeltaPPM = throughputDeltaPPM
        self.maximumNativeActiveRows = max(1, maximumNativeActiveRows)
        self.supportsSampling = supportsSampling
    }

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
        maximumProposalDepth: 0,
        maximumPromptTokens: 0,
        maximumCompletionTokens: 0,
        completeWindowBytesByDepth: []
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
    case capacityAboveNativeBound = "capacity_above_native_bound"
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
        "max_completion_tokens",
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
        guard nativeCapability.maximumPromptTokens > 0,
              nativeCapability.maximumCompletionTokens > 0 else {
            return .capabilityMismatch
        }
        if let maxTokens = request.maxTokens,
           maxTokens > nativeCapability.maximumCompletionTokens {
            return .capabilityMismatch
        }
        guard request.stop.isEmpty || nativeCapability.supportsStopSequences else {
            return .capabilityMismatch
        }
        guard request.topLevelKeys.isSubset(of: admittedTopLevelKeys),
              request.streamOptionKeys.isSubset(of: admittedStreamOptionKeys) else {
            return .unknownRequestField
        }
        // Sampled rows verify by target-sample exact match with the row's own
        // sampler, so a tuple qualified for sampling admits any temperature/
        // top_p pair the ordinary row sampler supports; anything else, and
        // every sampled request on a greedy-only tuple, stays ordinary.
        if request.temperature != 0.0 || request.topP != 1.0 {
            guard nativeCapability.supportsSampling,
                  ContinuousBatchRowSampler.supports(
                      temperature: request.temperature,
                      topP: request.topP
                  ) else {
                return .sampling
            }
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
        // SPEC-048-R009 (G7): a sticky key stays ordinary. A cache-only
        // auto-prefix key stays eligible here; the conversation-cache lease
        // decides before any native state exists
        // (`resolvingConversationCacheLease`).
        guard request.conversationKey == nil || request.conversationCacheOnly else {
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

struct NativeMTPRuntimeAdmission: Sendable, Equatable {
    let selection: DecodePathSelection
    let effectivePath: DecodePath
    let initialProposalDepth: Int
    let maximumPromptTokens: Int
    let maximumCompletionTokens: Int
    let completeWindowBytesByDepth: [Int]
    let maximumNativeActiveRows: Int
    let tupleFence: NativeMTPTupleFence?

    var usesNativeMTP: Bool {
        effectivePath == .nativeMTP
    }

    var allowsConversationCacheLease: Bool {
        !usesNativeMTP
    }

    /// SPEC-048-R009 (G7): a native row may take a conversation-cache lease
    /// only for a cache-only key, so the lease can decide its path.
    func allowsConversationCacheLease(cacheOnlyKey: Bool) -> Bool {
        !usesNativeMTP || cacheOnlyKey
    }

    /// SPEC-048-R009 (G7). A native admission that carries a cache-only key
    /// stays native only when the lease the ordinary path would take is a
    /// miss and the runtime publishes keyed rows in the serial conversation
    /// cache format. Then serving the row natively changes no cache outcome:
    /// no discount is forgone and the same entry kind is committed. Any hit,
    /// missing lease, or retained paged-KV handoff reselects ordinary with
    /// reason `conversation_key` before native state exists. A request whose
    /// provenance forbids any lease (SPEC-049) has no cache outcome to change.
    func resolvingConversationCacheLease(
        hasConversationKey: Bool,
        leaseAllowed: Bool,
        cachedPromptTokens: Int?,
        keyedRowsCommitSerialFormat: Bool
    ) -> NativeMTPRuntimeAdmission {
        guard usesNativeMTP, hasConversationKey, leaseAllowed else { return self }
        guard keyedRowsCommitSerialFormat, cachedPromptTokens == 0 else {
            return Self.ordinary(reason: .conversationKey)
        }
        return self
    }

    static func resolve(
        selection: DecodePathSelection,
        capability: NativeMTPCapability?,
        schedulerSupportsNativeMTP: Bool
    ) -> NativeMTPRuntimeAdmission {
        guard selection.path == .nativeMTP,
              schedulerSupportsNativeMTP,
              let capability,
              capability.maximumProposalDepth > 0 else {
            return NativeMTPRuntimeAdmission(
                selection: selection,
                effectivePath: selection.path == .classicDraftSpec ? .classicDraftSpec : .ordinary,
                initialProposalDepth: 0,
                maximumPromptTokens: 0,
                maximumCompletionTokens: 0,
                completeWindowBytesByDepth: [],
                maximumNativeActiveRows: 0,
                tupleFence: nil
            )
        }
        return NativeMTPRuntimeAdmission(
            selection: selection,
            effectivePath: .nativeMTP,
            initialProposalDepth: capability.maximumProposalDepth,
            maximumPromptTokens: capability.maximumPromptTokens,
            maximumCompletionTokens: capability.maximumCompletionTokens,
            completeWindowBytesByDepth: capability.completeWindowBytesByDepth,
            maximumNativeActiveRows: capability.maximumNativeActiveRows,
            tupleFence: nil
        )
    }

    /// SPEC-048-R007 load gate at admission. `otherActiveRows` counts every
    /// other in-flight request on the served runtime, native or ordinary.
    /// Admitting this request native would make the active row count exceed
    /// the signed bound, so it takes ordinary decode before any native state
    /// exists.
    func resolvingActiveRows(otherActiveRows: Int) -> NativeMTPRuntimeAdmission {
        guard usesNativeMTP, max(0, otherActiveRows) >= maximumNativeActiveRows else { return self }
        return Self.ordinary(reason: .capacityAboveNativeBound)
    }

    private static func ordinary(reason: NativeMTPSelectorReason) -> NativeMTPRuntimeAdmission {
        NativeMTPRuntimeAdmission(
            selection: DecodePathSelection(path: .ordinary, nativeMTPReason: reason),
            effectivePath: .ordinary,
            initialProposalDepth: 0,
            maximumPromptTokens: 0,
            maximumCompletionTokens: 0,
            completeWindowBytesByDepth: [],
            maximumNativeActiveRows: 0,
            tupleFence: nil
        )
    }

    func resolvingTokenBounds(
        promptTokenCount: Int,
        maxOutputTokens: Int
    ) -> NativeMTPRuntimeAdmission {
        guard usesNativeMTP else { return self }
        let effectiveMaximumPromptTokens = maximumPromptTokens
        let reason: NativeMTPSelectorReason?
        if promptTokenCount < 0
            || effectiveMaximumPromptTokens <= 0
            || promptTokenCount > effectiveMaximumPromptTokens {
            reason = .capabilityMismatch
        } else if maxOutputTokens < 0 || maximumCompletionTokens <= 0 || maxOutputTokens > maximumCompletionTokens {
            reason = .capabilityMismatch
        } else {
            reason = nil
        }
        guard let reason else { return self }
        return Self.ordinary(reason: reason)
    }

    func binding(to fence: NativeMTPTupleFence?) -> NativeMTPRuntimeAdmission {
        NativeMTPRuntimeAdmission(
            selection: selection,
            effectivePath: effectivePath,
            initialProposalDepth: initialProposalDepth,
            maximumPromptTokens: maximumPromptTokens,
            maximumCompletionTokens: maximumCompletionTokens,
            completeWindowBytesByDepth: completeWindowBytesByDepth,
            maximumNativeActiveRows: maximumNativeActiveRows,
            tupleFence: usesNativeMTP ? fence : nil
        )
    }
}

struct NativeMTPTupleFence: Sendable, Hashable, Codable {
    let admissionTupleSHA256: String
    let servedSnapshotID: String
    let targetGeneration: UInt64
}

private extension ChatCompletionPromptSource {
    var minPValue: JSONValue? { minP }
    var repetitionPenaltyValue: JSONValue? { repetitionPenalty }
}

/// SPEC-048-R016 (v0.1.32) on-device native-MTP qualification: MTP-on greedy
/// tokens must equal ordinary decode on the same paged engine (same kernels,
/// so near-tied logits resolve the same way), and MTP must beat ordinary
/// decode by the SPEC-048-R015 decode-throughput bar.
enum NativeMTPOnDeviceSelfCheck {
    static let minimumSpeedup = 1.15
    static let repetitions = 2

    struct Verdict: Equatable {
        let passed: Bool
        /// `passed`, `token_mismatch`, `no_net_gain`, `empty_output`.
        let reason: String
        let speedup: Double
    }

    static func decide(
        mtpTokens: [Int],
        mtpSeconds: Double,
        ordinaryTokens: [Int],
        ordinarySeconds: Double
    ) -> Verdict {
        guard !ordinaryTokens.isEmpty else {
            return Verdict(passed: false, reason: "empty_output", speedup: 0)
        }
        guard mtpTokens == ordinaryTokens else {
            return Verdict(passed: false, reason: "token_mismatch", speedup: 0)
        }
        guard mtpSeconds > 0, mtpSeconds.isFinite, ordinarySeconds.isFinite else {
            return Verdict(passed: false, reason: "no_net_gain", speedup: 0)
        }
        let speedup = ordinarySeconds / mtpSeconds
        guard speedup >= minimumSpeedup else {
            return Verdict(passed: false, reason: "no_net_gain", speedup: speedup)
        }
        return Verdict(passed: true, reason: "passed", speedup: speedup)
    }
}
