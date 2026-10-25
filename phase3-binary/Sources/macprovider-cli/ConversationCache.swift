import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import MacProviderCore

/// Recurrent (`ArraysCache`/`MambaCache`) layer states captured right after the
/// prompt was prefilled to exactly `tokenCount` tokens. Recurrent state cannot be
/// trimmed, so a hybrid entry is reusable only from one of these (SPEC-024 FR-CI2).
/// `@unchecked Sendable` for the same reason `ConversationCacheLayers` is: the
/// batched scheduler hands it across actors and nothing mutates the arrays.
struct RecurrentStateCheckpoint: @unchecked Sendable {
    let tokenCount: Int
    /// Layer index → that layer's `state` arrays. MLX arrays are immutable values
    /// and `ArraysCache` replaces (never mutates) its slots, so holding the
    /// references is a valid snapshot.
    let states: [Int: [MLXArray]]
}

/// Identity equality: the same snapshot, i.e. the same length and the very same
/// state arrays per layer. Lets scheduler requests that carry a checkpoint stay
/// `Equatable` without comparing tensor contents.
extension RecurrentStateCheckpoint: Equatable {
    static func == (lhs: RecurrentStateCheckpoint, rhs: RecurrentStateCheckpoint) -> Bool {
        guard lhs.tokenCount == rhs.tokenCount, lhs.states.count == rhs.states.count else { return false }
        return lhs.states.allSatisfy { index, arrays in
            guard let other = rhs.states[index], other.count == arrays.count else { return false }
            return zip(arrays, other).allSatisfy { $0 === $1 }
        }
    }
}

/// SPEC-048-R009 (0.1.56) / SPEC-024-R005: the native-MTP head's state at a
/// GLM-5-Next prompt snapshot, captured on a native continuous-batching row
/// right after its prefill reached the snapshot length `nextPosition`. The
/// head's cache entry for position `p` pairs the target hidden state at `p`
/// with prompt token `p + 1`, so the last entry consumed `foldedNextToken`
/// (prompt token `nextPosition`). A later turn may restore it only when its
/// own prompt has that token at `nextPosition` (oMLX `_MtpPrefixSnapshot`,
/// adapted: the GLM role marker there is fixed, so the boundary pair is folded
/// at capture instead of carrying a pending hidden column). The cache layers
/// are copies that nothing mutates; a restore copies them again.
struct NativeMTPDrafterPrefixSnapshot: @unchecked Sendable {
    let cache: [KVCache]
    let nextPosition: Int
    let foldedNextToken: Int

    /// The token check a restoring prompt must pass.
    func restores(into incomingTokens: [Int32], at tokenCount: Int) -> Bool {
        nextPosition == tokenCount
            && incomingTokens.indices.contains(tokenCount)
            && Int(incomingTokens[tokenCount]) == foldedNextToken
    }
}

final class ConversationCacheLayers: @unchecked Sendable {
    let layers: [KVCache]
    let retainedPagedKVSequence: PagedKVRetainedSequence?
    /// Ascending by `tokenCount`; bounded to scaffold end, last turn start, and
    /// the covered reply end for hybrid recurrent reuse.
    let recurrentCheckpoints: [RecurrentStateCheckpoint]
    /// SPEC-024 FR-CI2a: a deep copy of every layer taken when prefill reached
    /// exactly the committed canonical tokens (a prompt prefix). Its layers may
    /// be rotating, pooled or recurrent and are never trimmed, so the entry
    /// serves only an incoming prompt that extends all of its tokens.
    let promptSnapshot: Bool
    /// SPEC-024-R005: the native-MTP head state at this prompt snapshot, when a
    /// native GLM-5-Next CB row published it. Nil for every other entry.
    let nativeMTPDrafter: NativeMTPDrafterPrefixSnapshot?
    private let discardRetainedPagedKVSequence: (@Sendable (PagedKVRetainedSequence, String) async -> Void)?

    init(
        _ layers: [KVCache],
        retainedPagedKVSequence: PagedKVRetainedSequence? = nil,
        discardRetainedPagedKVSequence: (@Sendable (PagedKVRetainedSequence, String) async -> Void)? = nil,
        recurrentCheckpoints: [RecurrentStateCheckpoint] = [],
        promptSnapshot: Bool = false,
        nativeMTPDrafter: NativeMTPDrafterPrefixSnapshot? = nil
    ) {
        self.layers = layers
        self.retainedPagedKVSequence = retainedPagedKVSequence
        self.discardRetainedPagedKVSequence = discardRetainedPagedKVSequence
        self.recurrentCheckpoints = recurrentCheckpoints.sorted { $0.tokenCount < $1.tokenCount }
        self.promptSnapshot = promptSnapshot
        self.nativeMTPDrafter = promptSnapshot ? nativeMTPDrafter : nil
    }

    static func hasRecurrentLayers(_ layers: [KVCache]) -> Bool {
        layers.contains { $0 is ArraysCache }
    }

    func discardRetainedPagedKV(conversationKey: String) async {
        guard let retainedPagedKVSequence, let discardRetainedPagedKVSequence else { return }
        await discardRetainedPagedKVSequence(retainedPagedKVSequence, conversationKey)
    }
}

final class ConversationCacheLease: @unchecked Sendable {
    let key: String
    let keyHash: String
    let incomingTokens: [Int32]
    let modelID: String
    let kvBits: Int?
    let reusableCache: ConversationCacheLayers?
    let cachedPromptTokens: Int
    let lcp: Int
    let trimBy: Int
    /// SPEC-037 FR-KVP8 stamping rule: the cold-tier store's live purge-generation
    /// high-watermark sampled at `begin()`, carried immutably into the disk
    /// snapshot at commit. 0 when no cold tier is active.
    let sampledPurgeGeneration: Int
    /// Within-process single-key purge counter for this key sampled at `begin()`.
    /// A `commit()` whose stamp is below the live value reinserts nothing.
    let localPurgeStamp: Int
    /// Within-process purge-all counter sampled at `begin()`. A `commit()` after a
    /// purge-all reinserts nothing.
    let globalPurgeStamp: Int
    let fleetGrant: FleetConversationCacheGrant?
    let originalStoredAt: Date?
    /// True when this hit reuses cold-tier-promoted layers (FR-KVP9). Advisory,
    /// used only for telemetry attribution.
    let promotedFromCold: Bool
    let reusableCanonicalPromptTokens: [Int32]?
    /// SPEC-038 AC-26 hybrid cached turn: the recurrent checkpoint a retained
    /// paged-KV hit resumes from (`cachedPromptTokens == tokenCount`). Nil for
    /// every other lease; the batched scheduler installs it into the row.
    let recurrentCheckpoint: RecurrentStateCheckpoint?

    init(
        key: String,
        keyHash: String,
        incomingTokens: [Int32],
        modelID: String,
        kvBits: Int?,
        reusableCache: ConversationCacheLayers?,
        cachedPromptTokens: Int,
        lcp: Int,
        trimBy: Int,
        sampledPurgeGeneration: Int = 0,
        localPurgeStamp: Int = 0,
        globalPurgeStamp: Int = 0,
        promotedFromCold: Bool = false,
        reusableCanonicalPromptTokens: [Int32]? = nil,
        recurrentCheckpoint: RecurrentStateCheckpoint? = nil,
        fleetGrant: FleetConversationCacheGrant? = nil,
        originalStoredAt: Date? = nil
    ) {
        self.key = key
        self.keyHash = keyHash
        self.incomingTokens = incomingTokens
        self.modelID = modelID
        self.kvBits = kvBits
        self.reusableCache = reusableCache
        self.cachedPromptTokens = cachedPromptTokens
        self.lcp = lcp
        self.trimBy = trimBy
        self.sampledPurgeGeneration = sampledPurgeGeneration
        self.localPurgeStamp = localPurgeStamp
        self.fleetGrant = fleetGrant
        self.originalStoredAt = originalStoredAt
        self.globalPurgeStamp = globalPurgeStamp
        self.promotedFromCold = promotedFromCold
        self.reusableCanonicalPromptTokens = reusableCanonicalPromptTokens
        self.recurrentCheckpoint = recurrentCheckpoint
    }
}

actor ConversationCache {
    static let lcpThreshold = 32

    struct Config: Sendable {
        let maxConversations: Int
        let maxTokens: Int
        let ttlSeconds: TimeInterval

        static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Config {
            Config(
                maxConversations: Self.positiveInt(environment["MACPROVIDER_CONV_CACHE_MAX_CONVERSATIONS"]) ?? 8,
                maxTokens: Self.positiveInt(environment["MACPROVIDER_CONV_CACHE_MAX_TOKENS"]) ?? 200_000,
                ttlSeconds: TimeInterval(Self.positiveInt(environment["MACPROVIDER_CONV_CACHE_TTL_MINUTES"]) ?? 15) * 60
            )
        }

        private static func positiveInt(_ value: String?) -> Int? {
            guard let value, let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else {
                return nil
            }
            return parsed
        }
    }

    private struct Entry {
        var canonicalPromptTokens: [Int32]
        var kvCache: ConversationCacheLayers
        var modelID: String
        var kvBits: Int?
        var storedAt: Date
        var lastUsedAt: Date
        var tokenCount: Int
    }

    private let config: Config
    private var entries: [String: Entry] = [:]
    private var busyKeys: Set<String> = []
    private var waiters: [String: [(id: UUID, continuation: CheckedContinuation<Void, Never>)]] = [:]

    /// SPEC-037 stage 5 — optional encrypted disk cold tier. Nil ⇒ the hot tier
    /// behaves byte-identically to today (FR-KVP1 non-gated-key invariant).
    private var coldTier: (any ConversationColdTier)?
    /// Within-process single-key purge generation (FR-KVP8 hot-lease fencing).
    private var localPurgeGen: [String: Int] = [:]
    /// Within-process purge-all generation.
    private var globalPurgeGen = 0

    init(config: Config = .fromEnvironment(), coldTier: (any ConversationColdTier)? = nil) {
        self.config = config
        self.coldTier = coldTier
    }

    /// Attach the cold tier after construction (the serve process activates the
    /// disk tier only once it holds the namespace lock, FR-KVP7).
    func attachColdTier(_ tier: any ConversationColdTier) {
        coldTier = tier
    }

    func begin(
        conversationKey: String?,
        incomingTokens: [Int32],
        modelID: String,
        kvBits: Int?,
        now: Date = Date(),
        cold: ConversationColdContext? = nil,
        allowRetainedPagedKVHandoff: Bool = false,
        fleetGrant: FleetConversationCacheGrant? = nil,
        requireNativeMTPDrafterSnapshot: Bool = false
    ) async -> ConversationCacheLease? {
        guard let key = conversationKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        func authorized() -> Bool {
            fleetGrant.map { $0.isValid && $0.conversationKey == key } ?? true
        }
        guard authorized() else { return nil }
        guard await waitForTurn(key) else { return nil }
        busyKeys.insert(key)
        guard authorized() else { releaseTurn(key); return nil }

        let keyHash = Self.keyHash(key)
        await sweepExpired(now: now)
        guard authorized() else { releaseTurn(key); return nil }

        // SPEC-037 FR-KVP8 — sample the purge stamps at lease acquisition. The
        // store high-watermark is stamped into any disk write; the local counters
        // fence a `commit()` racing a purge that lands before it.
        let localPurgeStamp = localPurgeGen[key] ?? 0
        let globalPurgeStamp = globalPurgeGen
        var sampledPurgeGeneration = 0
        let gated = (cold?.eligible ?? false) && coldTier != nil
        if gated, let coldTier {
            sampledPurgeGeneration = await coldTier.sampledPurgeGeneration(conversationKey: key)
        }
        guard authorized() else { releaseTurn(key); return nil }
        func stampedLease(
            reusableCache: ConversationCacheLayers?, cachedPromptTokens: Int, lcp: Int, trimBy: Int,
            promotedFromCold: Bool = false,
            reusableCanonicalPromptTokens: [Int32]? = nil,
            recurrentCheckpoint: RecurrentStateCheckpoint? = nil,
            originalStoredAt: Date? = nil
        ) -> ConversationCacheLease {
            ConversationCacheLease(
                key: key, keyHash: keyHash, incomingTokens: incomingTokens, modelID: modelID, kvBits: kvBits,
                reusableCache: reusableCache, cachedPromptTokens: cachedPromptTokens, lcp: lcp, trimBy: trimBy,
                sampledPurgeGeneration: sampledPurgeGeneration, localPurgeStamp: localPurgeStamp,
                globalPurgeStamp: globalPurgeStamp, promotedFromCold: promotedFromCold,
                reusableCanonicalPromptTokens: reusableCanonicalPromptTokens,
                recurrentCheckpoint: recurrentCheckpoint, fleetGrant: fleetGrant,
                originalStoredAt: originalStoredAt)
        }

        // Acquire a candidate entry from the hot tier, or — for a gated key that
        // missed hot — lazily promote a validated cold entry (FR-KVP9). A promoted
        // candidate is fed through the SAME predicate below (no second predicate).
        var entry: Entry
        var promotionCandidate: ColdPromotionCandidate?
        if let hot = entries.removeValue(forKey: key) {
            entry = hot
        } else if gated, let coldTier, let cold,
                  let candidate = await coldTier.promoteCandidate(conversationKey: key, identity: cold.identity) {
            // CRITICAL-1(d): `promoteCandidate` suspended this actor. Recheck the purge
            // stamps sampled at `begin()` — a single-key `purgeHot` or a `purgeAllHot` that
            // ran on this actor DURING the suspension bumped `localPurgeGen[key]` /
            // `globalPurgeGen`, revoking the state the store just promoted. A bumped stamp
            // ⇒ reject the candidate as a miss rather than seating layers the purge already
            // invalidated (defense in depth alongside the store's own post-decode re-fence).
            let promoFencedLocal = (localPurgeGen[key] ?? 0) > localPurgeStamp
            let promoFencedGlobal = globalPurgeGen > globalPurgeStamp
            if promoFencedLocal || promoFencedGlobal || !authorized() {
                await coldTier.finishPromotion(candidate, accepted: false, rejectionReason: "purged_during_promotion")
                log("event=conv_cache action=miss key_hash=\(keyHash) reason=purged_during_promotion")
                return stampedLease(reusableCache: nil, cachedPromptTokens: 0, lcp: 0, trimBy: 0)
            }
            promotionCandidate = candidate
            // A restore changes residency, not the original reuse deadline.
            let createdAt = candidate.createdAtMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? now
            let deadlineBound = candidate.eligibleUntilMillis.map {
                Date(timeIntervalSince1970: Double($0) / 1000).addingTimeInterval(-config.ttlSeconds)
            } ?? createdAt
            let originalStoredAt = min(createdAt, deadlineBound)
            guard now.timeIntervalSince(originalStoredAt) <= config.ttlSeconds else {
                await coldTier.finishPromotion(candidate, accepted: false, rejectionReason: "expired_during_promotion")
                return stampedLease(reusableCache: nil, cachedPromptTokens: 0, lcp: 0, trimBy: 0)
            }
            entry = Entry(
                canonicalPromptTokens: candidate.canonicalTokens,
                kvCache: candidate.layers,
                modelID: modelID,
                kvBits: kvBits,
                storedAt: originalStoredAt,
                lastUsedAt: now,
                tokenCount: candidate.canonicalTokens.count)
            log("event=conv_cache action=promote key_hash=\(keyHash) canonical_tokens=\(candidate.canonicalTokens.count)")
        } else {
            // FR-KVP12: a gated request whose live identity is unavailable emits
            // disk_miss_identity_unavailable on this cold-read attempt (hot missed)
            // before failing safe to a normal miss — no silent no-op, no promotion.
            if let coldTier, let cold, cold.identityUnavailableReason != nil {
                await coldTier.noteReadIdentityUnavailable(conversationKey: key)
            }
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=cold_start")
            return stampedLease(reusableCache: nil, cachedPromptTokens: 0, lcp: 0, trimBy: 0)
        }

        // Predicate miss on a promoted candidate is `disk_promote_rejected` (§5
        // row 25); on a resident hot candidate it is the shipped hot miss.
        func predicateMiss(_ reason: String) async -> ConversationCacheLease {
            if let promotionCandidate {
                await coldTier?.finishPromotion(promotionCandidate, accepted: false, rejectionReason: reason)
            }
            await entry.kvCache.discardRetainedPagedKV(conversationKey: key)
            return stampedLease(reusableCache: nil, cachedPromptTokens: 0, lcp: 0, trimBy: 0)
        }

        guard entry.modelID == modelID else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=model_swap stored_model=\(entry.modelID) incoming_model=\(modelID)")
            return await predicateMiss("model_swap")
        }
        guard entry.kvBits == kvBits else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=kvbits_swap")
            return await predicateMiss("kvbits_swap")
        }

        let lcp = Self.longestCommonPrefix(entry.canonicalPromptTokens, incomingTokens)
        guard lcp >= Self.lcpThreshold else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=prefix_diverged lcp=\(lcp) threshold=\(Self.lcpThreshold)")
            return await predicateMiss("prefix_diverged")
        }
        guard lcp < incomingTokens.count else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=nothing_new lcp=\(lcp) prompt_tokens=\(incomingTokens.count)")
            return await predicateMiss("nothing_new")
        }

        let retainedPagedKV = entry.kvCache.retainedPagedKVSequence != nil
        if retainedPagedKV && !allowRetainedPagedKVHandoff {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=retained_paged_kv_requires_handoff")
            return await predicateMiss("retained_paged_kv_requires_handoff")
        }
        // Tokens of the stored prefix actually reused: `lcp`, or the chosen recurrent
        // checkpoint's length for a hybrid entry.
        var reuseLength = lcp
        var restoreCheckpoint: RecurrentStateCheckpoint?
        var retainedCheckpoint: RecurrentStateCheckpoint?
        if retainedPagedKV, !entry.kvCache.recurrentCheckpoints.isEmpty {
            // SPEC-038 AC-26 hybrid retained entry: its recurrent state is only
            // reusable at a checkpoint, so the hit resumes from the largest one
            // within the shared prefix. The scheduler's reattach trims the paged
            // attention KV to exactly that length.
            guard let checkpoint = Self.selectRecurrentCheckpoint(entry.kvCache.recurrentCheckpoints, lcp: lcp) else {
                log("event=conv_cache action=miss key_hash=\(keyHash) reason=recurrent_checkpoint_diverged lcp=\(lcp) checkpoints=\(entry.kvCache.recurrentCheckpoints.map(\.tokenCount))")
                return await predicateMiss("recurrent_checkpoint_diverged")
            }
            reuseLength = checkpoint.tokenCount
            retainedCheckpoint = checkpoint
        }
        if !retainedPagedKV, entry.kvCache.promptSnapshot {
            // SPEC-024 FR-CI2a: a prompt snapshot is reused only by extension. Its
            // window, pool or recurrent layers cannot be rewound, so any prompt
            // that diverges inside the stored tokens misses.
            guard lcp == entry.canonicalPromptTokens.count else {
                log("event=conv_cache action=miss key_hash=\(keyHash) reason=prompt_snapshot_diverged lcp=\(lcp) snapshot_tokens=\(entry.canonicalPromptTokens.count)")
                return await predicateMiss("prompt_snapshot_diverged")
            }
            // SPEC-024-R005: a native-MTP row reuses a snapshot only together
            // with the MTP head state taken at it; otherwise it stays native
            // and prefills from zero (never an ordinary reselection).
            if requireNativeMTPDrafterSnapshot,
               entry.kvCache.nativeMTPDrafter?.restores(into: incomingTokens, at: lcp) != true {
                log("event=conv_cache action=miss key_hash=\(keyHash) reason=prompt_snapshot_drafter_unavailable snapshot_tokens=\(entry.canonicalPromptTokens.count)")
                return await predicateMiss("prompt_snapshot_drafter_unavailable")
            }
        } else if !retainedPagedKV {
            // SPEC-024-R001: RotatingKVCache is trimmable only while offset < maxSize,
            // and even then trim is windowed — not full-prefix reuse. Reject the class
            // rather than treating a temporarily-trimmable rotating cache as a hit.
            if entry.kvCache.layers.contains(where: { $0 is RotatingKVCache }) {
                log("event=conv_cache action=miss key_hash=\(keyHash) reason=rotating_window_cache")
                return await predicateMiss("rotating_window_cache")
            }
            if !entry.kvCache.recurrentCheckpoints.isEmpty,
               ConversationCacheLayers.hasRecurrentLayers(entry.kvCache.layers) {
                guard let checkpoint = Self.selectRecurrentCheckpoint(entry.kvCache.recurrentCheckpoints, lcp: lcp) else {
                    log("event=conv_cache action=miss key_hash=\(keyHash) reason=recurrent_checkpoint_diverged lcp=\(lcp) checkpoints=\(entry.kvCache.recurrentCheckpoints.map(\.tokenCount))")
                    return await predicateMiss("recurrent_checkpoint_diverged")
                }
                let covered = entry.kvCache.layers.indices.allSatisfy { index in
                    let layer = entry.kvCache.layers[index]
                    return layer.isTrimmable || (layer is ArraysCache && checkpoint.states[index] != nil)
                }
                guard covered else {
                    log("event=conv_cache action=miss key_hash=\(keyHash) reason=cache_not_trimmable")
                    return await predicateMiss("cache_not_trimmable")
                }
                reuseLength = checkpoint.tokenCount
                restoreCheckpoint = checkpoint
            } else {
                guard entry.kvCache.layers.allSatisfy(\.isTrimmable) else {
                    log("event=conv_cache action=miss key_hash=\(keyHash) reason=cache_not_trimmable")
                    return await predicateMiss("cache_not_trimmable")
                }
            }
        }
        let trimBy = entry.canonicalPromptTokens.count - reuseLength
        if trimBy > 0 && !retainedPagedKV {
            for layer in entry.kvCache.layers where layer.isTrimmable || restoreCheckpoint == nil {
                let trimmed = layer.trim(trimBy)
                if trimmed != trimBy {
                    log("event=conv_cache action=miss key_hash=\(keyHash) reason=trim_underflow requested=\(trimBy) actual=\(trimmed)")
                    return await predicateMiss("trim_underflow")
                }
            }
        }
        if let restoreCheckpoint {
            for (index, state) in restoreCheckpoint.states where entry.kvCache.layers.indices.contains(index) {
                (entry.kvCache.layers[index] as? ArraysCache)?.state = state
            }
        }
        entry.lastUsedAt = now
        if let promotionCandidate {
            await coldTier?.finishPromotion(promotionCandidate, accepted: true, rejectionReason: nil)
        }
        guard authorized(),
              (localPurgeGen[key] ?? 0) == localPurgeStamp,
              globalPurgeGen == globalPurgeStamp else {
            await entry.kvCache.discardRetainedPagedKV(conversationKey: key)
            releaseTurn(key)
            return nil
        }
        let stats = currentStats()
        let checkpointField = (restoreCheckpoint ?? retainedCheckpoint).map { " recurrent_checkpoint=\($0.tokenCount)" }
            ?? (entry.kvCache.promptSnapshot ? " prompt_snapshot=true" : "")
        log("event=conv_cache action=hit key_hash=\(keyHash) cached_prompt_tokens=\(reuseLength) prompt_tokens=\(incomingTokens.count) lcp=\(lcp) trim_by=\(trimBy)\(checkpointField) conv_cache_entries=\(stats.entries) conv_cache_tokens=\(stats.tokens)")
        return stampedLease(
            reusableCache: entry.kvCache,
            cachedPromptTokens: min(reuseLength, incomingTokens.count),
            lcp: reuseLength,
            trimBy: trimBy,
            promotedFromCold: promotionCandidate != nil,
            reusableCanonicalPromptTokens: Array(entry.canonicalPromptTokens.prefix(reuseLength)),
            recurrentCheckpoint: retainedCheckpoint, originalStoredAt: entry.storedAt)
    }

    /// `isCancelled` is the request's own cancel signal (SPEC-001-R013): a request
    /// cancelled before its entry is inserted publishes nothing. It is checked
    /// with the purge fence, the second time with no suspension before insertion.
    func commit(
        _ lease: ConversationCacheLease, cache: ConversationCacheLayers, fullTokens: [Int32], now: Date = Date(),
        cold: ConversationColdContext? = nil, isCancelled: @Sendable () -> Bool = { false }
    ) async {
        // SPEC-037 FR-KVP8 — a `commit()` whose stamps predate a purge that landed
        // during the request reinserts nothing (neither RAM nor disk).
        guard !Task.isCancelled, !isCancelled(), !isFenced(lease) else {
            log("event=conv_cache action=commit_fenced key_hash=\(lease.keyHash)")
            await cache.discardRetainedPagedKV(conversationKey: lease.key)
            releaseTurn(lease.key)
            return
        }
        let checkpointTokenCounts = cache.recurrentCheckpoints.map(\.tokenCount)
        guard checkpointTokenCounts.allSatisfy({ $0 <= fullTokens.count }) else {
            log("event=conv_cache action=commit_rejected key_hash=\(lease.keyHash) reason=recurrent_checkpoint_beyond_canonical_tokens tokens=\(fullTokens.count) checkpoints=\(checkpointTokenCounts)")
            await cache.discardRetainedPagedKV(conversationKey: lease.key)
            releaseTurn(lease.key)
            return
        }

        if let old = entries.removeValue(forKey: lease.key),
           old.kvCache.retainedPagedKVSequence?.handle != cache.retainedPagedKVSequence?.handle {
            await old.kvCache.discardRetainedPagedKV(conversationKey: lease.key)
        }
        guard !Task.isCancelled, !isCancelled(), !isFenced(lease) else {
            log("event=conv_cache action=commit_fenced key_hash=\(lease.keyHash)")
            await cache.discardRetainedPagedKV(conversationKey: lease.key)
            releaseTurn(lease.key)
            return
        }
        entries[lease.key] = Entry(
            canonicalPromptTokens: fullTokens,
            kvCache: cache,
            modelID: lease.modelID,
            kvBits: lease.kvBits,
            storedAt: now,
            lastUsedAt: now,
            tokenCount: fullTokens.count
        )
        await enforceLimits()
        guard !Task.isCancelled, !isFenced(lease) else {
            log("event=conv_cache action=commit_fenced key_hash=\(lease.keyHash)")
            if let current = entries[lease.key], current.kvCache === cache {
                entries.removeValue(forKey: lease.key)
                await current.kvCache.discardRetainedPagedKV(conversationKey: lease.key)
            }
            releaseTurn(lease.key)
            return
        }

        // SPEC-037 FR-KVP3 — snapshot-at-commit while the lease is still held: the
        // synchronous deep copy is the only hot-path cost; the disk write is
        // deferred so the hot commit never blocks on I/O.
        if cache.promptSnapshot {
            // SPEC-024 FR-CI2a: prompt snapshots stay in RAM; the SPEC-037 disk
            // codec does not encode window, pool or recurrent snapshot layers.
            log("event=conv_cache action=cold_snapshot_skipped key_hash=\(lease.keyHash) reason=prompt_snapshot")
        } else if let coldTier, let cold, cold.eligible,
           let snapshot = coldTier.captureSnapshot(
               conversationKey: lease.key, layers: cache, fullTokens: fullTokens,
               sampledPurgeGeneration: lease.sampledPurgeGeneration, identity: cold.identity,
               nowMillis: Int(now.timeIntervalSince1970 * 1000)) {
            // The adapter owns the persist Task (one pending per index, purge-all
            // cancellation, bounded shutdown drain). Non-blocking (CRITICAL-2/HIGH-5).
            coldTier.enqueuePersist(snapshot)
        } else if let coldTier, let cold, cold.identityUnavailableReason != nil {
            // FR-KVP12: a gated commit whose live identity is unavailable emits
            // disk_write_skipped(identity_unavailable) before failing safe to skip.
            await coldTier.noteWriteSkippedIdentityUnavailable(conversationKey: lease.key)
        } else if coldTier == nil {
            log("event=conv_cache action=cold_unattached key_hash=\(lease.keyHash)")
        } else if let cold, !cold.eligible {
            log("event=conv_cache action=cold_ineligible key_hash=\(lease.keyHash) gated_identity_missing=\(cold.identityUnavailableReason != nil)")
        } else {
            log("event=conv_cache action=cold_snapshot_skipped key_hash=\(lease.keyHash)")
        }
        releaseTurn(lease.key)
    }

    // MARK: - SPEC-037 FR-KVP8 hot-tier purge callbacks (wired from KVDiskTier)

    /// Remove the matching hot entry, cancel any queued/in-flight cold-tier persist
    /// for the key, and bump the within-process single-key purge generation so any
    /// outstanding lease's `commit()` reinserts nothing. Returns whether the hot tier
    /// held live state (a resident entry OR a pending persist) so the store's purge
    /// path never no-ops a purge that had hot/pending state (FR-KVP8 (a)).
    @discardableResult
    func purgeHot(conversationKey: String) async -> Bool {
        // Key on the trimmed form so a purge matches `begin()`'s entry keying.
        let key = conversationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        localPurgeGen[key, default: 0] += 1
        let removed = entries.removeValue(forKey: key)
        await removed?.kvCache.discardRetainedPagedKV(conversationKey: key)
        let hadHot = removed != nil
        let hadPending = await coldTier?.cancelPendingPersist(conversationKey: key) ?? false
        return hadHot || hadPending
    }

    /// Clear every hot entry and invalidate every outstanding lease's pending
    /// commit (purge-all / epoch rotation, FR-KVP8). Also cancels queued cold-tier
    /// persist work so no pre-rotation snapshot publishes into the new epoch
    /// (CRITICAL-2).
    func purgeAllHot() async {
        globalPurgeGen += 1
        let removed = entries
        entries.removeAll()
        for (key, entry) in removed {
            await entry.kvCache.discardRetainedPagedKV(conversationKey: key)
        }
        await coldTier?.cancelPendingPersists()
    }

    /// Drain queued cold-tier persist work on graceful shutdown (HIGH-5).
    func drainColdWrites(timeoutSeconds: Int) async {
        await coldTier?.drainPendingPersists(timeoutSeconds: timeoutSeconds)
    }

    func abort(_ lease: ConversationCacheLease) async {
        await lease.reusableCache?.discardRetainedPagedKV(conversationKey: lease.key)
        releaseTurn(lease.key)
    }

    /// A retained paged-KV entry (including a hybrid one with recurrent
    /// checkpoints) cannot serve the serial path, so it is discarded here and the
    /// serial request misses; only a serial-format entry is put back.
    func abortForSerialFallback(_ lease: ConversationCacheLease, now: Date = Date()) async {
        defer { releaseTurn(lease.key) }
        guard let reusableCache = lease.reusableCache,
              reusableCache.retainedPagedKVSequence == nil,
              lease.cachedPromptTokens > 0,
              let reusableCanonicalPromptTokens = lease.reusableCanonicalPromptTokens
        else {
            await lease.reusableCache?.discardRetainedPagedKV(conversationKey: lease.key)
            return
        }
        guard !isFenced(lease) else {
            log("event=conv_cache action=serial_fallback_fenced key_hash=\(lease.keyHash)")
            return
        }
        entries[lease.key] = Entry(
            canonicalPromptTokens: reusableCanonicalPromptTokens,
            kvCache: reusableCache,
            modelID: lease.modelID,
            kvBits: lease.kvBits,
            storedAt: lease.originalStoredAt ?? now,
            lastUsedAt: now,
            tokenCount: reusableCanonicalPromptTokens.count
        )
        await enforceLimits()
        if isFenced(lease), let current = entries[lease.key], current.kvCache === reusableCache {
            entries.removeValue(forKey: lease.key)
            log("event=conv_cache action=serial_fallback_fenced key_hash=\(lease.keyHash)")
        }
    }

    func snapshotStats() -> (entries: Int, tokens: Int) {
        currentStats()
    }

    /// The largest checkpoint the incoming prompt still shares (`tokenCount <= lcp`).
    static func selectRecurrentCheckpoint(_ checkpoints: [RecurrentStateCheckpoint], lcp: Int) -> RecurrentStateCheckpoint? {
        checkpoints
            .filter { $0.tokenCount >= lcpThreshold && $0.tokenCount <= lcp }
            .max { $0.tokenCount < $1.tokenCount }
    }

    /// Recurrent-state prefill checkpoint positions for a ChatML prompt on a
    /// hybrid model, ascending, deduplicated, each `>= lcpThreshold`:
    /// - C1: the first `<|im_start|>` that opens a `user` turn — the end of the
    ///   system/tools scaffold that gateway auto-prefix keys hash, so a new
    ///   conversation under a shared key still reuses it.
    /// - C2: the last `<|im_start|>` — the history the next turn repeats; the
    ///   generation prompt and re-rendered assistant turn after it may differ.
    /// The reply-end checkpoint is captured after decode because it is outside
    /// the rendered prompt this helper inspects.
    /// The role is detected by decoding up to three tokens after the marker and
    /// requiring the text to start with `user\n`, which is independent of how the
    /// tokenizer splits `user` and the newline.
    static func recurrentCheckpointPositions(
        promptTokenIds: [Int32],
        imStartTokenID: Int32?,
        hybrid: Bool,
        decode: ([Int]) -> String
    ) -> [Int] {
        guard hybrid, let imStartTokenID else { return [] }
        let starts = promptTokenIds.indices.filter { promptTokenIds[$0] == imStartTokenID }
        guard let last = starts.last else { return [] }
        let firstUser = starts.first { index in
            let roleTokens = promptTokenIds[(index + 1)..<min(index + 4, promptTokenIds.count)].map(Int.init)
            return decode(roleTokens).hasPrefix("user\n")
        }
        return Array(Set([firstUser, last].compactMap { $0 }.filter { $0 >= lcpThreshold })).sorted()
    }

    static func longestCommonPrefix(_ lhs: [Int32], _ rhs: [Int32]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var index = 0
        while index < limit, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    /// False when the waiting task is cancelled while the key is still busy
    /// (SPEC-001-R013): a cancelled request stops waiting for another
    /// request's turn and takes no lease. A waiter that `releaseTurn` resumed
    /// takes the free turn even if cancelled, so the turn is never lost.
    private func waitForTurn(_ key: String) async -> Bool {
        while busyKeys.contains(key) {
            if Task.isCancelled { return false }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters[key, default: []].append((id, continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelTurnWaiter(key: key, id: id) }
            }
        }
        return true
    }

    private func cancelTurnWaiter(key: String, id: UUID) {
        guard var keyWaiters = waiters[key],
              let index = keyWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = keyWaiters.remove(at: index)
        waiters[key] = keyWaiters.isEmpty ? nil : keyWaiters
        waiter.continuation.resume()
    }

    private func releaseTurn(_ key: String) {
        busyKeys.remove(key)
        guard var keyWaiters = waiters[key], !keyWaiters.isEmpty else {
            waiters.removeValue(forKey: key)
            return
        }
        let next = keyWaiters.removeFirst()
        waiters[key] = keyWaiters.isEmpty ? nil : keyWaiters
        next.continuation.resume()
    }

    private func sweepExpired(now: Date) async {
        let expired = entries.compactMap { key, entry -> (String, Entry)? in
            now.timeIntervalSince(entry.storedAt) > config.ttlSeconds ? (key, entry) : nil
        }
        for (key, entry) in expired {
            guard let current = entries[key], current.kvCache === entry.kvCache else { continue }
            entries.removeValue(forKey: key)
            await entry.kvCache.discardRetainedPagedKV(conversationKey: key)
            log("event=conv_cache action=evict key_hash=\(Self.keyHash(key)) reason=ttl_\(Int(config.ttlSeconds / 60))min")
        }
    }

    private func enforceLimits() async {
        while entries.count > config.maxConversations || currentStats().tokens > config.maxTokens {
            guard let victim = entries.min(by: { lhs, rhs in lhs.value.lastUsedAt < rhs.value.lastUsedAt })?.key else {
                return
            }
            let evicted = entries.removeValue(forKey: victim)
            await evicted?.kvCache.discardRetainedPagedKV(conversationKey: victim)
            log("event=conv_cache action=evict key_hash=\(Self.keyHash(victim)) reason=lru")
        }
    }

    private func currentStats() -> (entries: Int, tokens: Int) {
        (entries.count, entries.values.reduce(0) { $0 + $1.tokenCount })
    }

    private func isFenced(_ lease: ConversationCacheLease) -> Bool {
        (lease.fleetGrant.map { !$0.isValid } ?? false) ||
            (localPurgeGen[lease.key] ?? 0) > lease.localPurgeStamp || globalPurgeGen > lease.globalPurgeStamp
    }

    private static func keyHash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
