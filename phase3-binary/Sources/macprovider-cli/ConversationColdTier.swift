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
    /// - Parameter nowMillis: the EXACT hot-commit instant (integer ms), passed in so
    ///   created_at/eligible_until derive from the commit timestamp — never from a
    ///   wall-clock read taken AFTER the up-to-256 MiB deep copy, which would extend
    ///   disk eligibility past the hot TTL by the copy duration (M-B).
    func captureSnapshot(
        conversationKey: String,
        layers: ConversationCacheLayers,
        fullTokens: [Int32],
        sampledPurgeGeneration: Int,
        identity: KVIdentityCore,
        nowMillis: Int
    ) -> ConversationColdSnapshot?

    /// Enqueue a captured snapshot for the bounded async writer. Non-blocking: the
    /// implementation owns the Task lifecycle, enforces one pending write per index
    /// (a newer commit displaces an unstarted older one, HIGH-5), and supports
    /// purge-all cancellation (CRITICAL-2) + bounded shutdown drain (HIGH-5).
    func enqueuePersist(_ snapshot: ConversationColdSnapshot)

    /// Cancel the queued/pending persist Task for ONE index WITHOUT publishing
    /// (single-key purge, FR-KVP8 (a)/(b)). Awaits an in-flight task so it cannot
    /// publish after the purge. Returns whether a pending persist existed for the key.
    func cancelPendingPersist(conversationKey: String) async -> Bool

    /// Cancel every queued/pending persist Task WITHOUT publishing (purge-all, before
    /// epoch rotation, CRITICAL-2). Awaits in-flight tasks so none can publish into
    /// the rotated epoch.
    func cancelPendingPersists() async

    /// Drain queued/pending persist work, bounded by `timeoutSeconds` (graceful
    /// shutdown, HIGH-5 / FR-KVP3).
    func drainPendingPersists(timeoutSeconds: Int) async

    /// FR-KVP12: a GATED request whose live identity is unavailable emits
    /// `disk_miss_identity_unavailable` through the store's telemetry sink on the
    /// cold-read attempt (hot miss) before failing safe to a miss — never a silent
    /// no-op. No promotion occurs.
    func noteReadIdentityUnavailable(conversationKey: String) async

    /// FR-KVP12: a GATED request whose live identity is unavailable emits
    /// `disk_write_skipped(detail=identity_unavailable)` through the store's telemetry
    /// sink on the commit (write) attempt before failing safe to skip. No persist occurs.
    func noteWriteSkippedIdentityUnavailable(conversationKey: String) async
}

/// Per-request cold-tier context supplied by the caller (ModelRuntime), which
/// alone knows the request's ingest provenance and the live model identity.
/// A nil context, or `eligible == false`, disables all cold-tier behavior for
/// the request.
struct ConversationColdContext: Sendable {
    /// Full-go flag: the FR-KVP11 gate accepted (key in the `conv:kvs-synth:`
    /// sub-namespace AND direct-HTTP provenance) AND the live identity is available.
    /// When true the cold tier may promote/persist. Computed by the caller — the gate
    /// never infers provenance from key shape alone.
    let eligible: Bool
    /// The model/tokenizer identity core for this request. The cold-tier adapter
    /// completes it with build-pinned ABI fields, the store namespace/epoch, and
    /// the live-model geometry template it owns. Consumed only when `eligible`.
    let identity: KVIdentityCore
    /// FR-KVP12: set (with `eligible == false`) when the request PASSED the gate but a
    /// live-identity input (model hash / tokenizer hash / template hash / catalog
    /// revision) is unavailable. The tier then emits the identity_unavailable telemetry
    /// on the read/write attempt and fails safe (no promote, no persist) rather than
    /// silently no-op'ing. Nil for a non-gated request (cold tier fully inert).
    let identityUnavailableReason: KVReasonDetail?

    init(eligible: Bool, identity: KVIdentityCore, identityUnavailableReason: KVReasonDetail? = nil) {
        self.eligible = eligible
        self.identity = identity
        self.identityUnavailableReason = identityUnavailableReason
    }

    /// Pure FR-KVP11 gate + FR-KVP12 identity-availability resolution, factored out of
    /// `ModelRuntime.coldContext` so it is unit-testable without a live model. `gated`
    /// is the gate decision (synthetic key sub-namespace + direct-HTTP provenance); each
    /// live-identity input is nil when unavailable this process. A gated request missing
    /// ANY of model hash / tokenizer hash / template hash / catalog revision resolves to
    /// `identityUnavailableReason == .identityUnavailable` (eligible false); a non-gated
    /// request resolves inert; a gated request with every input present is eligible.
    static func resolve(
        gated: Bool, requestModel: String, servedModelID: String,
        modelSHA256: String?, catalogRevision: String?,
        tokenizerConfigSHA256: String?, chatTemplateSHA256: String?
    ) -> ConversationColdContext {
        func placeholder() -> KVIdentityCore {
            KVIdentityCore.build(
                requestModel: requestModel, servedModelID: servedModelID, modelSHA256: modelSHA256,
                catalogRevision: catalogRevision ?? "", tokenizerConfigSHA256: tokenizerConfigSHA256 ?? "",
                chatTemplateSHA256: chatTemplateSHA256 ?? "")
        }
        guard gated else {
            return ConversationColdContext(eligible: false, identity: placeholder())
        }
        guard let catalogRevision, let tokenizerConfigSHA256, let chatTemplateSHA256, let modelSHA256 else {
            return ConversationColdContext(
                eligible: false, identity: placeholder(), identityUnavailableReason: .identityUnavailable)
        }
        let identity = KVIdentityCore.build(
            requestModel: requestModel, servedModelID: servedModelID, modelSHA256: modelSHA256,
            catalogRevision: catalogRevision, tokenizerConfigSHA256: tokenizerConfigSHA256,
            chatTemplateSHA256: chatTemplateSHA256)
        return ConversationColdContext(eligible: true, identity: identity)
    }
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
    /// §6 (Item 9): identity/format fields carried into the terminal `disk_hit` event so
    /// the KVS-01a harness records the full §6 evidence set. Defaulted so test doubles
    /// need not supply them.
    var modelSHA256: String = ""
    var catalogRevision: String = ""
    var kvBits: Int? = nil
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
    /// Item 3 (FR-KVP3 write-live budget): the aggregate write-live bytes reserved for
    /// this snapshot at capture (before the deep copy). Carried as a single-release
    /// token through pending → active serialization → completion/cancellation/
    /// displacement, and released exactly once by the persist Task. 0 for a snapshot
    /// that carries no reservation (e.g. a test double).
    let reservedWriteBytes: Int

    init(rawKey: String, tokens: [Int32], layers: [KVLayerPayload], identity: KVWriteIdentity,
         sampledPurgeGeneration: Int, commitSequence: Int, createdAtMillis: Int,
         eligibleUntilMillis: Int, incarnation: String, reservedWriteBytes: Int = 0) {
        self.rawKey = rawKey
        self.tokens = tokens
        self.layers = layers
        self.identity = identity
        self.sampledPurgeGeneration = sampledPurgeGeneration
        self.commitSequence = commitSequence
        self.createdAtMillis = createdAtMillis
        self.eligibleUntilMillis = eligibleUntilMillis
        self.incarnation = incarnation
        self.reservedWriteBytes = reservedWriteBytes
    }
}
