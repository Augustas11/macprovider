import Foundation

/// SPEC-037 stage 5 — the additive bridge between the shipped in-RAM
/// `ConversationCache` (hot tier) and the encrypted on-disk `KVDiskTier`
/// (cold tier). The hot tier stays the ONLY reuse mechanism (FR-KVP2): the
/// cold tier only changes cache *residency* by (a) snapshotting a just-committed
/// entry to disk and (b) promoting a validated cold entry back into the hot
/// tier on a miss, after which the existing `begin()` predicate decides hit/miss.
///
/// Every method is a no-op unless an implementation is injected AND the caller
/// supplies an eligible `ConversationColdContext`, so a `ConversationCache`
/// built without a cold tier — or serving a non-gated key — behaves
/// byte-identically to today (FR-KVP1 non-gated-key invariant).
protocol ConversationColdTier: Sendable {
    /// FR-KVP8 stamping rule: the live purge-generation high-watermark for the
    /// key, sampled at hot-lease acquisition (`begin()`), carried immutably into
    /// the snapshot, and re-verified inside the store's mutation lane at publish.
    func sampledPurgeGeneration(conversationKey: String) async -> Int

    /// Lazy, on-demand promotion (FR-KVP9): on a hot-tier miss for a gated key,
    /// ask the store for a validated cold entry and materialize it into hot-tier
    /// layers WITHOUT emitting a terminal telemetry code yet. Returns the restored
    /// layers plus the canonical token sequence the generation was committed with,
    /// so the caller runs the UNCHANGED `begin()` LCP/trim predicate against it
    /// (no second predicate) and then calls `finishPromotion` with the outcome.
    /// Nil on any store-side miss/failure (the store emits its own FR-KVP12 code).
    /// The adapter assembles the full runtime envelope identity from `identity`
    /// plus the live-model geometry template it owns.
    func promoteCandidate(conversationKey: String, identity: KVIdentityCore) async
        -> ColdPromotionCandidate?

    /// Emit the single terminal telemetry code for a promotion candidate after the
    /// hot predicate ran: `disk_hit` when accepted, `disk_promote_rejected` (plus
    /// the shipped hot-tier reason) when the predicate rejected the restored
    /// layers (§5 row 25).
    func finishPromotion(_ candidate: ColdPromotionCandidate, accepted: Bool, rejectionReason: String?) async

    /// FR-KVP3 snapshot-at-commit: synchronously (while the per-key lease is
    /// still held) capture an immutable, deep-copied snapshot of the committed
    /// layer state + full envelope identity. Returns nil when the geometry is
    /// unsupported or identity is unavailable — in which case nothing is
    /// persisted. The synchronous copy is the only hot-path cost; the actual disk
    /// write is deferred to `persist`.
    func captureSnapshot(
        conversationKey: String,
        layers: ConversationCacheLayers,
        fullTokens: [Int32],
        sampledPurgeGeneration: Int,
        identity: KVIdentityCore
    ) -> ConversationColdSnapshot?

    /// Enqueue a captured snapshot for the bounded async writer. Non-blocking: the
    /// implementation owns the Task lifecycle, enforces one pending write per index
    /// (a newer commit displaces an unstarted older one, HIGH-5), and supports
    /// purge-all cancellation (CRITICAL-2) + bounded shutdown drain (HIGH-5).
    func enqueuePersist(_ snapshot: ConversationColdSnapshot)

    /// Cancel every queued/pending persist Task WITHOUT publishing (purge-all, before
    /// epoch rotation, CRITICAL-2). Awaits in-flight tasks so none can publish into
    /// the rotated epoch.
    func cancelPendingPersists() async

    /// Drain queued/pending persist work, bounded by `timeoutSeconds` (graceful
    /// shutdown, HIGH-5 / FR-KVP3).
    func drainPendingPersists(timeoutSeconds: Int) async
}

/// Per-request cold-tier context supplied by the caller (ModelRuntime), which
/// alone knows the request's ingest provenance and the live model identity.
/// A nil context, or `eligible == false`, disables all cold-tier behavior for
/// the request.
struct ConversationColdContext: Sendable {
    /// FR-KVP11 gate decision: key in the `conv:kvs-synth:` sub-namespace AND
    /// direct-HTTP provenance. Computed by the caller — the gate never infers
    /// provenance from key shape alone.
    let eligible: Bool
    /// The model/tokenizer identity core for this request. The cold-tier adapter
    /// completes it with build-pinned ABI fields, the store namespace/epoch, and
    /// the live-model geometry template it owns.
    let identity: KVIdentityCore
}

/// The per-request model + tokenizer identity that ModelRuntime can supply
/// directly (FR-KVP4 items 4–5, 9). The cold-tier adapter augments it with the
/// build-pinned ABI epoch / MLX revisions (item 6), the ordinary decode-path
/// class (item 10), the cache class + geometry (items 7–8), and the store's
/// namespace/epoch — so write and read derive identical envelopes.
struct KVIdentityCore: Sendable, Equatable {
    let requestModel: String
    let servedModelID: String
    /// nil ⇒ the canonical model hash is unavailable this process (FR-KVP4): the
    /// tier neither writes nor promotes.
    let modelSHA256: String?
    let catalogRevision: String
    let tokenizerID: String
    let tokenizerConfigSHA256: String
    let chatTemplateSHA256: String
    let kvBits: Int?
    let kvGroupSize: Int?
    let kvQuantMode: String?
    let kvQuantPolicy: String?
}

/// A validated cold entry restored into hot-tier layers, pending the hot
/// predicate's accept/reject decision (FR-KVP9). Carries the store's restore
/// telemetry so `finishPromotion` can emit exactly one terminal code.
struct ColdPromotionCandidate: Sendable {
    let layers: ConversationCacheLayers
    let canonicalTokens: [Int32]
    let keyHashPrefix: String
    let bytesRead: Int
    let decryptMillis: Int
    let peakStagingBytes: Int
}

/// An immutable, `Sendable` hand-off from a synchronous hot-tier commit to the
/// asynchronous disk writer (FR-KVP3). The tensor bytes inside (`layers`) are
/// already deep-copied at capture time, so subsequent in-place trims of the hot
/// layers cannot alter what is persisted (fixture: AC-9). The HMAC index and
/// commit sequence are allocated later, inside the store actor, so no Keychain
/// or actor hop occurs on the synchronous hot path.
struct ConversationColdSnapshot: Sendable {
    let rawKey: String
    let tokens: [Int32]
    let layers: [KVLayerPayload]
    let identity: KVWriteIdentity
    let sampledPurgeGeneration: Int
    /// Monotonic per-index commit sequence, allocated synchronously under the hot
    /// lease at capture time (CRITICAL-2). Two commits therefore publish in commit
    /// order regardless of persist-Task scheduling.
    let commitSequence: Int
    let createdAtMillis: Int
    let eligibleUntilMillis: Int
    let incarnation: String
}
