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
    case kvBitsUnsupported = "kv_bits_unsupported"
    case draftSpecDecodeMutualExclusion = "draft_spec_decode_mutual_exclusion"
    case stickyCacheBridgeUnavailable = "sticky_cache_bridge_unavailable"
    case moePromotionEvidenceUnavailable = "moe_promotion_evidence_unavailable"
    case requestStateUnrepresented = "request_local_state_unrepresented"

    var apiCode: String {
        switch self {
        case .kvBitsUnsupported:
            return "continuous_batching_unsupported_kv_bits"
        case .draftSpecDecodeMutualExclusion:
            return "draft_model_capacity_shortfall"
        case .stickyCacheBridgeUnavailable:
            return "continuous_batching_sticky_cache_unavailable"
        case .moePromotionEvidenceUnavailable:
            return "continuous_batching_moe_promotion_evidence_unavailable"
        case .requestStateUnrepresented:
            return "continuous_batching_request_state_unsupported"
        case .localCapabilityUnavailable, .pagedKVDisabled,
             .pagedKVCapabilityUnavailable, .tupleNotAdvertised:
            return "continuous_batching_local_capability_unavailable"
        }
    }

    var status: Int {
        switch self {
        case .kvBitsUnsupported, .draftSpecDecodeMutualExclusion,
             .stickyCacheBridgeUnavailable, .moePromotionEvidenceUnavailable,
             .requestStateUnrepresented,
             .tupleNotAdvertised:
            return 400
        case .localCapabilityUnavailable, .pagedKVDisabled, .pagedKVCapabilityUnavailable:
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
            stickyCacheEligible: false,
            descriptor: nil,
            tuple: nil,
            checkLocalCapability: false,
            pagedKVDecision: .disabled
        )
    }

    static func capability(
        mode: ContinuousBatchingMode,
        maxBatch: Int,
        queueLimit configuredQueueLimit: Int?,
        kvBits: Int?,
        draftConfigured: Bool,
        stickyCacheEligible: Bool = false,
        requestStateRepresentable: Bool = true,
        schedulerBackendAvailable: Bool,
        pagedKVDecision: PagedKVAttachDecision,
        requestedTuple: ContinuousBatchingRequestedTuple?
    ) -> ContinuousBatchingCapability {
        makeCapability(
            mode: mode,
            maxBatch: maxBatch,
            queueLimit: configuredQueueLimit,
            kvBits: kvBits,
            draftConfigured: draftConfigured,
            stickyCacheEligible: stickyCacheEligible,
            requestStateRepresentable: requestStateRepresentable,
            descriptor: pagedKVDecision.descriptor,
            tuple: requestedTuple,
            schedulerBackendAvailable: schedulerBackendAvailable,
            checkLocalCapability: true,
            pagedKVDecision: pagedKVDecision
        )
    }

    private static func makeCapability(
        mode: ContinuousBatchingMode,
        maxBatch: Int,
        queueLimit configuredQueueLimit: Int?,
        kvBits: Int?,
        draftConfigured: Bool,
        stickyCacheEligible: Bool,
        requestStateRepresentable: Bool = true,
        descriptor: PagedKVDescriptor?,
        tuple: ContinuousBatchingRequestedTuple?,
        schedulerBackendAvailable: Bool = false,
        checkLocalCapability: Bool,
        pagedKVDecision: PagedKVAttachDecision
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
            // gate holds even once the deferred SPEC-039 bridge lands, so a future
            // backend cannot silently ignore or cross-contaminate that state.
            reason = .requestStateUnrepresented
        } else if draftConfigured {
            reason = .draftSpecDecodeMutualExclusion
        } else if kvBits != nil {
            reason = .kvBitsUnsupported
        } else if stickyCacheEligible {
            // FR-PKV10's live contiguous-cache bridge is tracked separately;
            // fresh conversations remain eligible for the first cut.
            reason = .stickyCacheBridgeUnavailable
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
                } else if tuple.requiresMoE {
                    // AC-23 keeps every MoE tuple unsupported until the
                    // representative correctness fixture and live MSB-04
                    // evidence exist. Descriptor membership alone is not a
                    // promotion signal.
                    reason = .moePromotionEvidenceUnavailable
                } else if !schedulerBackendAvailable {
                    reason = .localCapabilityUnavailable
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
        case .kvBitsUnsupported:
            return "continuous batching does not support the requested kv_bits tuple"
        case .draftSpecDecodeMutualExclusion:
            return "continuous batching is mutually exclusive with speculative decoding in this release"
        case .stickyCacheBridgeUnavailable:
            return "continuous batching requires the local contiguous-cache bridge for sticky-cache requests"
        case .moePromotionEvidenceUnavailable:
            return "continuous batching requires the representative MoE correctness fixture and live MSB-04 promotion evidence"
        case .requestStateUnrepresented:
            return "continuous batching does not support requests requiring row-local generation state (structured output or tool-constrained decoding) in this release"
        }
    }

    static func logSerialRouteIfNeeded(_ capability: ContinuousBatchingCapability) {
        guard let line = serialRouteTelemetryLine(capability) else { return }
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func serialRouteTelemetryLine(_ capability: ContinuousBatchingCapability) -> String? {
        guard capability.shouldUseSerialPath, let reason = capability.unsupportedReason else { return nil }
        return "event=batching_unsupported action=serial_routed reason=\(reason.rawValue)\n"
    }
}
