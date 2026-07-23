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
    func promoteCandidate(conversationKey: String, runtime: KVRuntimeIdentity) async
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
        identity: KVWriteIdentity
    ) -> ConversationColdSnapshot?

    /// Hand a captured snapshot to the bounded async writer. MUST NOT block the
    /// hot commit (callers fire-and-forget it after the lease is released).
    func persist(_ snapshot: ConversationColdSnapshot) async
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
    /// Runtime identity for envelope validation on promotion (read side).
    let runtimeIdentity: KVRuntimeIdentity
    /// Envelope identity captured into the snapshot on commit (write side).
    let writeIdentity: KVWriteIdentity
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
    let createdAtMillis: Int
    let eligibleUntilMillis: Int
    let incarnation: String
}
