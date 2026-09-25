import Foundation
import Tokenizers

/// SPEC-015 §N.12 item 5 (informative, #1690 M5): the honest-bug guard for a
/// pool-authorized loopback completion served from a catalog-matched GGUF.
///
/// It re-counts the completion text with the tokenizer of the sibling catalog
/// MLX row, found as the catalog model id's local Hugging Face snapshot, and
/// emits one `pool_usage_recount` line. It is check-and-alert only: it runs
/// detached after the signing decision and never changes the relayed usage,
/// the signed usage, or whether a receipt is signed. It never downloads; with
/// no cached sibling snapshot it records `tokenizer_unavailable`. The count
/// covers the visible content only, so reasoning or tool-call tokens the
/// upstream runtime also counted can widen the gap on such completions.
enum PoolLoopbackUsageGuard {
    enum Status: String, Sendable {
        case consistent
        case divergent
        case tokenizerUnavailable = "tokenizer_unavailable"
    }

    /// A gap above max(8 tokens, 5% of the reported count) is divergent.
    static let absoluteTolerance: Int64 = 8
    static let relativeTolerance = 0.05

    /// GGUF runtimes (SPEC-023 §3.7.4 identity matrix) and mlxlm_loopback,
    /// which serves the catalog row's own MLX snapshot (SPEC-010-R009).
    static func applies(to authorization: PoolRuntimeAuthorization) -> Bool {
        authorization.runtimeSource == MLXLMLoopbackServeModel.runtimeSource ||
            ArtifactFeed.identityMatrix["gguf"]?.runtimeSources.contains(authorization.runtimeSource) == true
    }

    /// mlxlm_loopback re-counts with the tokenizer in the served snapshot
    /// itself; every other runtime uses the catalog model id's local Hugging
    /// Face snapshot.
    static func snapshotDirectory(for authorization: PoolRuntimeAuthorization) -> (String) -> URL? {
        if authorization.runtimeSource == MLXLMLoopbackServeModel.runtimeSource,
           let directory = MLXLMLoopbackServeModel.snapshotDirectory() {
            return { _ in directory }
        }
        return ModelRuntime.localHuggingFaceSnapshot(for:)
    }

    static func schedule(
        settlementMetadata: SettlementReceiptMetadata,
        providerID: String,
        completionText: String,
        reportedCompletionTokens: Int64
    ) {
        guard let authorization = settlementMetadata.poolRuntimeAuthorization, applies(to: authorization) else {
            return
        }
        Task.detached(priority: .background) {
            _ = await check(
                settlementMetadata: settlementMetadata,
                authorization: authorization,
                providerID: providerID,
                completionText: completionText,
                reportedCompletionTokens: reportedCompletionTokens,
                snapshotDirectory: snapshotDirectory(for: authorization)
            )
        }
    }

    @discardableResult
    static func check(
        settlementMetadata: SettlementReceiptMetadata,
        authorization: PoolRuntimeAuthorization,
        providerID: String,
        completionText: String,
        reportedCompletionTokens: Int64,
        snapshotDirectory: (String) -> URL? = ModelRuntime.localHuggingFaceSnapshot(for:)
    ) async -> Status {
        var recounted: Int64?
        if let directory = snapshotDirectory(settlementMetadata.modelID),
           let tokenizer = await TokenizerCache.shared.tokenizer(at: directory) {
            recounted = Int64(tokenizer.encode(text: completionText, addSpecialTokens: false).count)
        }
        let status: Status
        if let recounted {
            status = isDivergent(reported: reportedCompletionTokens, recounted: recounted) ? .divergent : .consistent
        } else {
            status = .tokenizerUnavailable
        }
        ReceiptAudit.emitUsageRecount(
            providerID: providerID,
            requestID: settlementMetadata.requestID,
            modelID: settlementMetadata.modelID,
            runtimeSource: authorization.runtimeSource,
            poolID: authorization.poolID,
            reportedCompletionTokens: reportedCompletionTokens,
            recountedCompletionTokens: recounted,
            status: status.rawValue
        )
        return status
    }

    static func isDivergent(reported: Int64, recounted: Int64) -> Bool {
        let relative = Int64((Double(max(reported, 0)) * relativeTolerance).rounded(.up))
        return abs(reported - recounted) > max(absoluteTolerance, relative)
    }

    /// One load per snapshot directory, failures included, so a broken
    /// snapshot is not re-parsed on every pool request.
    private actor TokenizerCache {
        static let shared = TokenizerCache()
        private var loaded: [String: (any Tokenizer)?] = [:]

        func tokenizer(at directory: URL) async -> (any Tokenizer)? {
            if let cached = loaded[directory.path] {
                return cached
            }
            let tokenizer = try? await AutoTokenizer.from(modelFolder: directory)
            loaded[directory.path] = .some(tokenizer)
            return tokenizer
        }
    }
}
