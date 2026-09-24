import Foundation
import MacProviderCore

/// Stable, reason-coded explanations for why a request did not enter the
/// continuous-batching scheduler. These describe locally-owned capability;
/// activation depends only on capability advertised by this provider.
enum ContinuousBatchingUnsupportedReason: String, Sendable, Equatable {
    case localCapabilityUnavailable = "local_batching_capability_unavailable"
    case pagedKVDisabled = "paged_kv_disabled"
    case pagedKVCapabilityUnavailable = "paged_kv_capability_unavailable"
    case tupleNotAdvertised = "requested_tuple_not_advertised"
    case tupleAcceptanceCoverageUnavailable = "tuple_acceptance_coverage_unavailable"
    case kvBitsUnsupported = "kv_bits_unsupported"
    case draftSpecDecodeMutualExclusion = "draft_spec_decode_mutual_exclusion"
    case stickyCacheHandoffUnavailable = "sticky_cache_handoff_unavailable"
    /// Kept for reason-coded API compatibility. Admission no longer serial-routes
    /// merely because a conversation key is present; first-turn / cache-miss keyed
    /// requests may enter the scheduler. Any positive cached-token hit still
    /// serial-routes (canary) or fail-closes (`.on`) as `stickyCacheHandoffUnavailable`
    /// until AC-26 packaged sticky/cross-turn proof.
    case conversationKeyRolloutUnavailable = "conversation_key_rollout_unavailable"
    case durableReplayAuthorityUnavailable = "durable_replay_authority_unavailable"
    case stableRequestIDUnavailable = "stable_request_id_unavailable"
    case moePromotionEvidenceUnavailable = "moe_promotion_evidence_unavailable"
    case requestStateUnrepresented = "request_local_state_unrepresented"

    var apiCode: String {
        switch self {
        case .kvBitsUnsupported:
            return "continuous_batching_unsupported_kv_bits"
        case .draftSpecDecodeMutualExclusion:
            return "draft_model_capacity_shortfall"
        case .stickyCacheHandoffUnavailable:
            return "continuous_batching_paged_kv_handoff_unavailable"
        case .conversationKeyRolloutUnavailable:
            return "continuous_batching_conversation_key_rollout_unavailable"
        case .durableReplayAuthorityUnavailable:
            return "continuous_batching_durable_replay_authority_unavailable"
        case .stableRequestIDUnavailable:
            return "continuous_batching_request_id_unavailable"
        case .moePromotionEvidenceUnavailable:
            return "continuous_batching_moe_promotion_evidence_unavailable"
        case .requestStateUnrepresented:
            return "continuous_batching_request_state_unsupported"
        case .tupleAcceptanceCoverageUnavailable:
            return "continuous_batching_tuple_acceptance_coverage_unavailable"
        case .localCapabilityUnavailable, .pagedKVDisabled,
             .pagedKVCapabilityUnavailable, .tupleNotAdvertised:
            return "continuous_batching_local_capability_unavailable"
        }
    }

    var status: Int {
        switch self {
        case .kvBitsUnsupported, .draftSpecDecodeMutualExclusion,
             .stickyCacheHandoffUnavailable,
             .conversationKeyRolloutUnavailable,
             .stableRequestIDUnavailable,
             .moePromotionEvidenceUnavailable,
             .requestStateUnrepresented,
             .tupleNotAdvertised,
             .tupleAcceptanceCoverageUnavailable:
            return 400
        case .localCapabilityUnavailable, .pagedKVDisabled,
             .pagedKVCapabilityUnavailable,
             .durableReplayAuthorityUnavailable:
            return 503
        }
    }
}

/// The exact runtime tuple whose membership in the SPEC-039 descriptor is the
/// activation predicate. Keeping this separate makes static and fixture review
/// able to prove that no scheduler-owned support matrix can drift from the engine.
struct ContinuousBatchingRequestedTuple: Sendable, Equatable {
    let modelID: String
    let modelSHA256: String
    let tokenizerSHA256: String?
    let chatTemplateSHA256: String?
    let cacheClass: String
    let kvDType: PagedKVDType
    let requiresMoE: Bool
    let hardwareClass: String
    let metallibSHA256: String
    let kernelIdentifier: String
    let parityLabel: String
    let poolEpoch: Int

    func isAdmitted(by descriptor: PagedKVDescriptor) -> Bool {
        descriptor.admits(
            modelID: modelID,
            modelSHA256: modelSHA256,
            tokenizerSHA256: tokenizerSHA256,
            chatTemplateSHA256: chatTemplateSHA256,
            cacheClass: cacheClass,
            kvDType: kvDType,
            requiresMoE: requiresMoE,
            hardwareClass: hardwareClass,
            metallibSHA256: metallibSHA256,
            kernelIdentifier: kernelIdentifier,
            parityLabel: parityLabel,
            poolEpoch: poolEpoch
        )
    }
}

/// SPEC-038 FR-CB10: descriptor membership alone is not support. A tuple may
/// only batch when the operator has recorded acceptance coverage for it — the
/// real-hardware AC-14 / AC-23 evidence that this exact tuple was qualified.
/// Compiling a global "evidence available" constant into the binary is not
/// per-tuple coverage: every Mac taking that binary would inherit it.
///
/// Coverage keys on the identity the *evidence* was measured on: hardware
/// class, model id + SHA, cache class, KV dtype, MoE requirement, and the
/// runtime revision (Metal library SHA + paged-KV kernel identifier). Binding
/// the runtime revision means a new build re-earns acceptance on its own
/// measurements (including the SPEC-039 FR-PKV13 overhead ceiling) instead of
/// inheriting an entry recorded on a different kernel. `parityLabel` is derived
/// from these fields plus the pool shape, and `poolEpoch` is per-boot; both stay
/// the SPEC-039 descriptor's job (`isAdmitted(by:)`), which runs first.
struct ContinuousBatchingAcceptanceCoverage: Sendable, Equatable {
    let acceptedTuples: [ContinuousBatchingAcceptedTuple]
    private let unrestricted: Bool

    static let empty = ContinuousBatchingAcceptanceCoverage(acceptedTuples: [])

    /// Test-only escape hatch, mirroring
    /// `ContinuousBatchRuntimeReplayAuthority.inMemoryForTests`. Never
    /// construct this from configuration or production code.
    static let unrestrictedForTests = ContinuousBatchingAcceptanceCoverage(
        acceptedTuples: [],
        unrestricted: true
    )

    init(acceptedTuples: [ContinuousBatchingAcceptedTuple]) {
        self.init(acceptedTuples: acceptedTuples, unrestricted: false)
    }

    private init(acceptedTuples: [ContinuousBatchingAcceptedTuple], unrestricted: Bool) {
        self.acceptedTuples = acceptedTuples
        self.unrestricted = unrestricted
    }

    func covers(_ tuple: ContinuousBatchingRequestedTuple) -> Bool {
        if unrestricted { return true }
        return acceptedTuples.contains { accepted in
            accepted.modelID == tuple.modelID
                && accepted.modelSHA256 == tuple.modelSHA256
                && accepted.cacheClass == tuple.cacheClass
                && accepted.kvDType == tuple.kvDType
                && accepted.requiresMoE == tuple.requiresMoE
                && accepted.hardwareClass == tuple.hardwareClass
                && accepted.metallibSHA256 == tuple.metallibSHA256
                && accepted.kernelIdentifier == tuple.kernelIdentifier
        }
    }
}

struct ContinuousBatchingCapability: Sendable, Equatable {
    let mode: ContinuousBatchingMode
    let maxActiveRows: Int
    let queueLimit: Int
    let descriptor: PagedKVDescriptor?
    let unsupportedReason: ContinuousBatchingUnsupportedReason?

    var isRequested: Bool { mode != .off }

    /// Canary is an explicit permissive policy: use batching when the local
    /// tuple is supported, otherwise serial-route with reason-coded telemetry.
    var shouldUseSerialPath: Bool {
        mode == .off
            || (unsupportedReason == .draftSpecDecodeMutualExclusion && maxActiveRows == 1)
            || (mode == .canary && unsupportedReason != nil)
    }
}

enum ContinuousBatchingPolicy {
    /// SPEC-038 AC-23 / FR-CB16. Descriptor membership still does not promote a
    /// MoE tuple. This production constant is the explicit activation signal
    /// after the representative correctness fixture, live MSB-04, leftover
    /// bundle, and the 2026-09-20 promotion review. Buyer `continuous_batching`
    /// stays off until a later packaged-RC canary; this flag only stops the
    /// capability gate from fail-closing Qwen3-Coder.
    static let productionMoEPromotionEvidenceAvailable = true

    static func maximumQueueLimit(maxActiveRows: Int) -> Int {
        let normalizedRows = max(1, maxActiveRows)
        let (limit, overflow) = normalizedRows.multipliedReportingOverflow(by: 8)
        return overflow ? Int.max : limit
    }

    static func defaultQueueLimit(maxActiveRows: Int) -> Int {
        let normalizedRows = max(1, maxActiveRows)
        let (limit, overflow) = normalizedRows.multipliedReportingOverflow(by: 2)
        return overflow ? Int.max : limit
    }

    static func queueLimit(configured: Int?, maxActiveRows: Int) -> Int {
        min(
            max(1, configured ?? defaultQueueLimit(maxActiveRows: maxActiveRows)),
            maximumQueueLimit(maxActiveRows: maxActiveRows)
        )
    }

    /// Configuration-only validation used before the model and engine are
    /// loaded. This release has no production scheduler backend, so strict mode
    /// fails before provider readiness instead of accepting a configuration
    /// whose every fresh request would fail at runtime.
    static func configurationCapability(
        mode: ContinuousBatchingMode,
        maxBatch: Int,
        queueLimit configuredQueueLimit: Int?,
        kvBits: Int?,
        draftConfigured: Bool
    ) -> ContinuousBatchingCapability {
        makeCapability(
            mode: mode,
            maxBatch: maxBatch,
            queueLimit: configuredQueueLimit,
            kvBits: kvBits,
            draftConfigured: draftConfigured,
            descriptor: nil,
            tuple: nil,
            checkLocalCapability: false,
            pagedKVDecision: .disabled,
            // Inert on this path: `pagedKVDecision: .disabled` means the
            // `.attached` branch that consults coverage is unreachable, and no
            // tuple exists pre-model to evaluate it against. `.empty` keeps the
            // production default fail-closed without fail-closing config
            // validation.
            acceptanceCoverage: .empty
        )
    }

    static func capability(
        mode: ContinuousBatchingMode,
        maxBatch: Int,
        queueLimit configuredQueueLimit: Int?,
        kvBits: Int?,
        draftConfigured: Bool,
        requestHasStableRequestID: Bool = true,
        requestStateRepresentable: Bool = true,
        schedulerBackendAvailable: Bool,
        durableReplayAuthorityAvailable: Bool = true,
        pagedKVDecision: PagedKVAttachDecision,
        requestedTuple: ContinuousBatchingRequestedTuple?,
        // SPEC-038 FR-CB10. Deliberately undefaulted: a defaulted parameter
        // would let a future call site silently skip the per-tuple acceptance
        // gate, which is the exact failure mode this gate exists to close.
        acceptanceCoverage: ContinuousBatchingAcceptanceCoverage,
        moePromotionEvidenceAvailable: Bool = productionMoEPromotionEvidenceAvailable
    ) -> ContinuousBatchingCapability {
        makeCapability(
            mode: mode,
            maxBatch: maxBatch,
            queueLimit: configuredQueueLimit,
            kvBits: kvBits,
            draftConfigured: draftConfigured,
            requestHasStableRequestID: requestHasStableRequestID,
            requestStateRepresentable: requestStateRepresentable,
            descriptor: pagedKVDecision.descriptor,
            tuple: requestedTuple,
            schedulerBackendAvailable: schedulerBackendAvailable,
            durableReplayAuthorityAvailable: durableReplayAuthorityAvailable,
            checkLocalCapability: true,
            pagedKVDecision: pagedKVDecision,
            acceptanceCoverage: acceptanceCoverage,
            moePromotionEvidenceAvailable: moePromotionEvidenceAvailable
        )
    }

    private static func makeCapability(
        mode: ContinuousBatchingMode,
        maxBatch: Int,
        queueLimit configuredQueueLimit: Int?,
        kvBits: Int?,
        draftConfigured: Bool,
        requestHasStableRequestID: Bool = true,
        requestStateRepresentable: Bool = true,
        descriptor: PagedKVDescriptor?,
        tuple: ContinuousBatchingRequestedTuple?,
        schedulerBackendAvailable: Bool = false,
        durableReplayAuthorityAvailable: Bool = true,
        checkLocalCapability: Bool,
        pagedKVDecision: PagedKVAttachDecision,
        acceptanceCoverage: ContinuousBatchingAcceptanceCoverage,
        moePromotionEvidenceAvailable: Bool = productionMoEPromotionEvidenceAvailable
    ) -> ContinuousBatchingCapability {
        let maxActiveRows = max(1, maxBatch)
        let queueLimit = queueLimit(configured: configuredQueueLimit, maxActiveRows: maxActiveRows)
        let reason: ContinuousBatchingUnsupportedReason?
        if mode == .off {
            reason = nil
        } else if !requestStateRepresentable {
            // The shared-forward backend contract carries only scalar sampling
            // parameters. A request needing row-local generation state the
            // contract does not represent (structured-output/grammar-constrained
            // decoding, tool-forced decoding, custom logit processors) must never
            // enter a batch: serial-route in canary, fail closed in strict. This
            // gate holds for the SPEC-039 bridge so a future backend cannot
            // silently ignore or cross-contaminate that state.
            reason = .requestStateUnrepresented
        } else if draftConfigured {
            reason = .draftSpecDecodeMutualExclusion
        } else if kvBits != nil {
            reason = .kvBitsUnsupported
        } else if !checkLocalCapability {
            reason = schedulerBackendAvailable ? nil : .localCapabilityUnavailable
        } else {
            switch pagedKVDecision {
            case .disabled:
                reason = .pagedKVDisabled
            case .fallback, .rejected:
                reason = .pagedKVCapabilityUnavailable
            case .attached(let advertised):
                guard let tuple else {
                    reason = .localCapabilityUnavailable
                    break
                }
                if !tuple.isAdmitted(by: advertised) {
                    reason = .tupleNotAdvertised
                } else if !acceptanceCoverage.covers(tuple) {
                    // FR-CB10: descriptor membership is only half of support.
                    // The operator must also have recorded acceptance coverage
                    // for this exact tuple on this hardware class.
                    reason = .tupleAcceptanceCoverageUnavailable
                } else if tuple.requiresMoE && !moePromotionEvidenceAvailable {
                    // AC-23: descriptor membership is not a promotion signal.
                    reason = .moePromotionEvidenceUnavailable
                } else if !schedulerBackendAvailable {
                    reason = .localCapabilityUnavailable
                } else if !durableReplayAuthorityAvailable {
                    reason = .durableReplayAuthorityUnavailable
                } else if !requestHasStableRequestID {
                    reason = .stableRequestIDUnavailable
                } else {
                    reason = nil
                }
            }
        }
        return ContinuousBatchingCapability(
            mode: mode,
            maxActiveRows: maxActiveRows,
            queueLimit: queueLimit,
            descriptor: descriptor,
            unsupportedReason: reason
        )
    }

    static func validateStrictStartup(_ capability: ContinuousBatchingCapability) throws {
        guard capability.mode == .on, let reason = capability.unsupportedReason else { return }
        if reason == .draftSpecDecodeMutualExclusion, capability.maxActiveRows == 1 {
            return
        }
        throw APIError(
            status: reason.status,
            message: strictMessage(for: reason),
            type: "invalid_request_error",
            code: reason.apiCode,
            inferenceRan: false,
            settlementRan: false
        )
    }

    static func strictMessage(for reason: ContinuousBatchingUnsupportedReason) -> String {
        switch reason {
        case .localCapabilityUnavailable:
            return "continuous batching local scheduler capability is unavailable for the loaded runtime"
        case .pagedKVDisabled:
            return "continuous batching requires an attached local SPEC-039 paged-KV engine"
        case .pagedKVCapabilityUnavailable:
            return "continuous batching requires the requested tuple to pass the local SPEC-039 capability gate"
        case .tupleNotAdvertised:
            return "continuous batching requested tuple is not advertised by the local SPEC-039 engine"
        case .tupleAcceptanceCoverageUnavailable:
            return "continuous batching requires recorded acceptance coverage for the requested tuple (SPEC-038 FR-CB10); add it to continuous_batching_accepted_tuples"
        case .kvBitsUnsupported:
            return "continuous batching does not support the requested kv_bits tuple"
        case .draftSpecDecodeMutualExclusion:
            return "continuous batching is mutually exclusive with speculative decoding in this release"
        case .stickyCacheHandoffUnavailable:
            return "continuous batching requires a same-conversation FR-PKV10 retained paged-KV handoff before cached-token credit can enter the scheduler"
        case .conversationKeyRolloutUnavailable:
            return "continuous batching conversation-keyed traffic is not in the current operator rollout scope"
        case .durableReplayAuthorityUnavailable:
            return "continuous batching requires durable replay authority before scheduler activation"
        case .stableRequestIDUnavailable:
            return "continuous batching requires a stable ingress request id before scheduler activation"
        case .moePromotionEvidenceUnavailable:
            return "continuous batching requires the representative MoE correctness fixture and live MSB-04 promotion evidence"
        case .requestStateUnrepresented:
            return "continuous batching does not support requests requiring row-local generation state (structured output or tool-constrained decoding) in this release"
        }
    }

    static func logSerialRouteIfNeeded(_ capability: ContinuousBatchingCapability) {
        guard let line = serialRouteTelemetryLine(capability) else { return }
        // write(contentsOf:) fails recoverably on a closed stderr; write(_:) aborts.
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }

    static func serialRouteTelemetryLine(_ capability: ContinuousBatchingCapability) -> String? {
        guard capability.shouldUseSerialPath, let reason = capability.unsupportedReason else { return nil }
        return "event=batching_unsupported action=serial_routed reason=\(reason.rawValue)\n"
    }

    /// Serve-path scheduler prefill currently fail-closes as a generic
    /// `continuous_batching_prefill_failed` API code. Log the inner throw so an
    /// operator canary can tell cache-layout / dtype / cancellation apart from
    /// an opaque 503. Never include the error's localized description: MLX
    /// dumps can carry prompt tokens.
    static func logPrefillFailed(_ error: Error) {
        try? FileHandle.standardError.write(contentsOf: Data(prefillFailureTelemetryLine(error).utf8))
    }

    static func logForwardFailed(_ error: Error) {
        try? FileHandle.standardError.write(contentsOf: Data(forwardFailureTelemetryLine(error).utf8))
    }

    static func prefillFailureTelemetryLine(_ error: Error) -> String {
        "event=batching_prefill_failed action=fail_closed reason=\(prefillFailureReason(error))\n"
    }

    static func forwardFailureTelemetryLine(_ error: Error) -> String {
        "event=batching_forward_failed action=fail_closed reason=\(prefillFailureReason(error))\n"
    }

    static func prefillFailureReason(_ error: Error) -> String {
        sanitizeTelemetryReason(prefillFailureRawReason(error))
    }

    private static func prefillFailureRawReason(_ error: Error) -> String {
        switch error {
        case ContinuousBatchSchedulerError.unsupported(let code),
             ContinuousBatchSchedulerError.requestFailed(let code):
            return code
        case PagedKVContiguousCacheBridgeError.noRecordedBlocks:
            return "paged_kv_no_recorded_blocks"
        case PagedKVContiguousCacheBridgeError.unsupportedDType:
            return "paged_kv_unsupported_dtype"
        case PagedKVContiguousCacheBridgeError.invalidLayerState:
            return "paged_kv_invalid_layer_state"
        case PagedKVContiguousCacheBridgeError.blockTableMismatch:
            return "paged_kv_block_table_mismatch"
        case PagedKVContiguousCacheBridgeError.trimShortfall:
            return "paged_kv_trim_shortfall"
        default:
            return String(describing: type(of: error))
        }
    }

    static func sanitizeTelemetryReason(_ raw: String) -> String {
        let mapped = raw.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "." {
                return Character(scalar)
            }
            return "_"
        }
        let collapsed = String(mapped)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        let bounded = String(collapsed.prefix(96))
        return bounded.isEmpty ? "unrecognized_prefill_error" : bounded
    }
}

/// Lab-only request lifecycle trace, on only with `MACPROVIDER_CB_TRACE=1`.
/// Request ids and stage names only; never prompt or completion content.
enum CBTrace {
    static let enabled = ProcessInfo.processInfo.environment["MACPROVIDER_CB_TRACE"] == "1"

    static func log(_ requestID: String?, _ event: @autoclosure () -> String) {
        guard enabled else { return }
        let ms = DispatchTime.now().uptimeNanoseconds / 1_000_000
        // `write(contentsOf:)` fails recoverably on a closed stderr; the
        // deprecated `write(_:)` would abort serving (see PagedKVRuntimeDiagnostics).
        try? FileHandle.standardError.write(contentsOf: Data("cbtrace t=\(ms) rid=\(requestID ?? "-") ev=\(event())\n".utf8))
    }
}
