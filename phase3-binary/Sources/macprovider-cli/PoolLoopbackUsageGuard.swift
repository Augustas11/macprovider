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

    /// GGUF runtimes (SPEC-023 §3.7.4 identity matrix) and the MLX-snapshot
    /// runtimes (mlxlm_loopback, omlx_loopback), which serve the catalog
    /// row's own MLX snapshot (SPEC-010-R009).
    static func applies(to authorization: PoolRuntimeAuthorization) -> Bool {
        MLXSnapshotLoopbackKind.kind(forRuntimeSource: authorization.runtimeSource) != nil ||
            ArtifactFeed.identityMatrix["gguf"]?.runtimeSources.contains(authorization.runtimeSource) == true
    }

    /// The MLX-snapshot runtimes re-count with the tokenizer in the served
    /// snapshot itself; every other runtime uses the catalog model id's
    /// local Hugging Face snapshot.
    static func snapshotDirectory(for authorization: PoolRuntimeAuthorization) -> (String) -> URL? {
        if authorization.runtimeSource == MLXLMLoopbackServeModel.runtimeSource,
           let directory = MLXLMLoopbackServeModel.servingSnapshotDirectory() {
            return { _ in directory }
        }
        if authorization.runtimeSource == OMLXLoopbackServeModel.runtimeSource,
           let directory = OMLXLoopbackServeModel.snapshotDirectory() {
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
        if let directory = snapshotDirectory(settlementMetadata.servedModelID),
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

/// #1690 M9 (review CODE HIGH): the tokenizer a cancelled loopback stream's
/// delivered content is counted with, loaded from a hash-verified MLX
/// snapshot and pinned in memory. It is loaded once, when serving starts, and
/// kept only when the snapshot is still exactly the one that was hashed after
/// the load, so the files it came from are the hashed files. A count is
/// given only while the snapshot is still current: a snapshot changed after
/// admission yields no count, so the cancel stays unattested.
final class PinnedSnapshotTokenizer: @unchecked Sendable {
    let snapshot: MLXSnapshotIdentity
    private let encode: @Sendable (String) -> Int

    init(snapshot: MLXSnapshotIdentity, encode: @escaping @Sendable (String) -> Int) {
        self.snapshot = snapshot
        self.encode = encode
    }

    /// Loads the tokenizer in `snapshot.directory`, or nil when it does not
    /// load or the snapshot changed while it loaded.
    static func load(snapshot: MLXSnapshotIdentity) async -> PinnedSnapshotTokenizer? {
        guard let tokenizer = try? await AutoTokenizer.from(modelFolder: snapshot.directory), snapshot.isCurrent() else {
            return nil
        }
        let box = TokenizerBox(tokenizer)
        return PinnedSnapshotTokenizer(snapshot: snapshot) { text in box.count(text) }
    }

    /// The token count of `text` (no special tokens), or nil when the
    /// snapshot is not the verified one both before and after the encode
    /// (the stamps are compared with the pinned ones each time), so a swap
    /// during the encode never yields a count.
    func count(_ text: String) -> Int? {
        guard snapshot.isCurrent() else { return nil }
        let tokens = encode(text)
        guard snapshot.isCurrent() else { return nil }
        return tokens
    }

    /// Serializes encodes: swift-transformers does not document its
    /// tokenizers as thread-safe, and concurrent cancels may count at once.
    private final class TokenizerBox: @unchecked Sendable {
        private let lock = NSLock()
        private let tokenizer: any Tokenizer
        init(_ tokenizer: any Tokenizer) { self.tokenizer = tokenizer }
        func count(_ text: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return tokenizer.encode(text: text, addSpecialTokens: false).count
        }
    }
}
