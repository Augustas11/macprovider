import Foundation
import MacProviderCore

enum ContinuousBatchingUnsupportedReason: String, Sendable, Equatable {
    case upstreamBatchAPIUnpinned = "upstream_batch_api_unpinned"
    case kvBitsUnsupported = "kv_bits_unsupported"
    case draftSpecDecodeMutualExclusion = "draft_spec_decode_mutual_exclusion"

    var apiCode: String {
        switch self {
        case .upstreamBatchAPIUnpinned:
            return "continuous_batching_unavailable"
        case .kvBitsUnsupported:
            return "continuous_batching_unsupported_kv_bits"
        case .draftSpecDecodeMutualExclusion:
            return "draft_model_capacity_shortfall"
        }
    }
}

struct ContinuousBatchingCapability: Sendable, Equatable {
    let mode: ContinuousBatchingMode
    let maxActiveRows: Int
    let queueLimit: Int
    let reviewedUpstreamRevision: String?
    let unsupportedReason: ContinuousBatchingUnsupportedReason?

    var isRequested: Bool {
        mode != .off
    }

    var shouldUseSerialPath: Bool {
        mode == .off || mode == .canary
    }
}

enum ContinuousBatchingPolicy {
    static let reviewedUpstreamBatchRevision: String? = nil

    static func defaultQueueLimit(maxActiveRows: Int) -> Int {
        max(1, maxActiveRows) * 2
    }

    static func queueLimit(configured: Int?, maxActiveRows: Int) -> Int {
        configured ?? defaultQueueLimit(maxActiveRows: maxActiveRows)
    }

    static func capability(
        mode: ContinuousBatchingMode,
        maxBatch: Int,
        queueLimit configuredQueueLimit: Int?,
        kvBits: Int?,
        draftConfigured: Bool,
        reviewedUpstreamRevision: String? = reviewedUpstreamBatchRevision
    ) -> ContinuousBatchingCapability {
        let maxActiveRows = max(1, maxBatch)
        let queueLimit = queueLimit(configured: configuredQueueLimit, maxActiveRows: maxActiveRows)
        let reason: ContinuousBatchingUnsupportedReason?
        if mode == .off {
            reason = nil
        } else if draftConfigured {
            reason = .draftSpecDecodeMutualExclusion
        } else if kvBits != nil {
            reason = .kvBitsUnsupported
        } else if reviewedUpstreamRevision == nil {
            reason = .upstreamBatchAPIUnpinned
        } else {
            reason = nil
        }
        return ContinuousBatchingCapability(
            mode: mode,
            maxActiveRows: maxActiveRows,
            queueLimit: queueLimit,
            reviewedUpstreamRevision: reviewedUpstreamRevision,
            unsupportedReason: reason
        )
    }

    static func validateStrictStartup(_ capability: ContinuousBatchingCapability) throws {
        guard capability.mode == .on, let reason = capability.unsupportedReason else {
            return
        }
        let status = reason == .upstreamBatchAPIUnpinned ? 503 : 400
        throw APIError(
            status: status,
            message: strictMessage(for: reason),
            type: "invalid_request_error",
            code: reason.apiCode
        )
    }

    static func strictMessage(for reason: ContinuousBatchingUnsupportedReason) -> String {
        switch reason {
        case .upstreamBatchAPIUnpinned:
            return "continuous batching requires a reviewed pinned mlx-swift-lm batch API"
        case .kvBitsUnsupported:
            return "continuous batching does not support kv_bits in this release"
        case .draftSpecDecodeMutualExclusion:
            return "continuous batching is mutually exclusive with speculative decoding in this release"
        }
    }

    static func logSerialRouteIfNeeded(_ capability: ContinuousBatchingCapability) {
        guard capability.mode == .canary, let reason = capability.unsupportedReason else {
            return
        }
        FileHandle.standardError.write(Data((
            "event=continuous_batching_unsupported action=serial_routed reason=\(reason.rawValue)\n"
        ).utf8))
    }
}
