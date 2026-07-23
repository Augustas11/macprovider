import CryptoKit
import Foundation
import MLXLMCommon

final class ConversationCacheLayers: @unchecked Sendable {
    let layers: [KVCache]

    init(_ layers: [KVCache]) {
        self.layers = layers
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
    /// True when this hit reuses cold-tier-promoted layers (FR-KVP9). Advisory,
    /// used only for telemetry attribution.
    let promotedFromCold: Bool

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
        promotedFromCold: Bool = false
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
        self.globalPurgeStamp = globalPurgeStamp
        self.promotedFromCold = promotedFromCold
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
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

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
        cold: ConversationColdContext? = nil
    ) async -> ConversationCacheLease? {
        guard let key = conversationKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        await waitForTurn(key)
        busyKeys.insert(key)

        let keyHash = Self.keyHash(key)
        sweepExpired(now: now)

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
        func stampedLease(
            reusableCache: ConversationCacheLayers?, cachedPromptTokens: Int, lcp: Int, trimBy: Int,
            promotedFromCold: Bool = false
        ) -> ConversationCacheLease {
            ConversationCacheLease(
                key: key, keyHash: keyHash, incomingTokens: incomingTokens, modelID: modelID, kvBits: kvBits,
                reusableCache: reusableCache, cachedPromptTokens: cachedPromptTokens, lcp: lcp, trimBy: trimBy,
                sampledPurgeGeneration: sampledPurgeGeneration, localPurgeStamp: localPurgeStamp,
                globalPurgeStamp: globalPurgeStamp, promotedFromCold: promotedFromCold)
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
            promotionCandidate = candidate
            entry = Entry(
                canonicalPromptTokens: candidate.canonicalTokens,
                kvCache: candidate.layers,
                modelID: modelID,
                kvBits: kvBits,
                storedAt: now,
                lastUsedAt: now,
                tokenCount: candidate.canonicalTokens.count)
            log("event=conv_cache action=promote key_hash=\(keyHash) canonical_tokens=\(candidate.canonicalTokens.count)")
        } else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=cold_start")
            return stampedLease(reusableCache: nil, cachedPromptTokens: 0, lcp: 0, trimBy: 0)
        }

        // Predicate miss on a promoted candidate is `disk_promote_rejected` (§5
        // row 25); on a resident hot candidate it is the shipped hot miss.
        func predicateMiss(_ reason: String) async -> ConversationCacheLease {
            if let promotionCandidate {
                await coldTier?.finishPromotion(promotionCandidate, accepted: false, rejectionReason: reason)
            }
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
        guard entry.kvCache.layers.allSatisfy(\.isTrimmable) else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=cache_not_trimmable")
            return await predicateMiss("cache_not_trimmable")
        }

        let trimBy = entry.canonicalPromptTokens.count - lcp
        if trimBy > 0 {
            for layer in entry.kvCache.layers {
                let trimmed = layer.trim(trimBy)
                if trimmed != trimBy {
                    log("event=conv_cache action=miss key_hash=\(keyHash) reason=trim_underflow requested=\(trimBy) actual=\(trimmed)")
                    return await predicateMiss("trim_underflow")
                }
            }
        }
        entry.lastUsedAt = now
        if let promotionCandidate {
            await coldTier?.finishPromotion(promotionCandidate, accepted: true, rejectionReason: nil)
        }
        let stats = currentStats()
        log("event=conv_cache action=hit key_hash=\(keyHash) cached_prompt_tokens=\(lcp) prompt_tokens=\(incomingTokens.count) lcp=\(lcp) trim_by=\(trimBy) conv_cache_entries=\(stats.entries) conv_cache_tokens=\(stats.tokens)")
        return stampedLease(
            reusableCache: entry.kvCache,
            cachedPromptTokens: min(lcp, incomingTokens.count),
            lcp: lcp,
            trimBy: trimBy,
            promotedFromCold: promotionCandidate != nil)
    }

    func commit(_ lease: ConversationCacheLease, cache: ConversationCacheLayers, fullTokens: [Int32], now: Date = Date(), cold: ConversationColdContext? = nil) {
        // SPEC-037 FR-KVP8 — a `commit()` whose stamps predate a purge that landed
        // during the request reinserts nothing (neither RAM nor disk).
        let fencedLocal = (localPurgeGen[lease.key] ?? 0) > lease.localPurgeStamp
        let fencedGlobal = globalPurgeGen > lease.globalPurgeStamp
        guard !fencedLocal, !fencedGlobal else {
            log("event=conv_cache action=commit_fenced key_hash=\(lease.keyHash)")
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
        enforceLimits()

        // SPEC-037 FR-KVP3 — snapshot-at-commit while the lease is still held: the
        // synchronous deep copy is the only hot-path cost; the disk write is
        // deferred so the hot commit never blocks on I/O.
        if let coldTier, let cold, cold.eligible,
           let snapshot = coldTier.captureSnapshot(
               conversationKey: lease.key, layers: cache, fullTokens: fullTokens,
               sampledPurgeGeneration: lease.sampledPurgeGeneration, identity: cold.identity,
               nowMillis: Int(now.timeIntervalSince1970 * 1000)) {
            // The adapter owns the persist Task (one pending per index, purge-all
            // cancellation, bounded shutdown drain). Non-blocking (CRITICAL-2/HIGH-5).
            coldTier.enqueuePersist(snapshot)
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
        let hadHot = entries.removeValue(forKey: key) != nil
        let hadPending = await coldTier?.cancelPendingPersist(conversationKey: key) ?? false
        return hadHot || hadPending
    }

    /// Clear every hot entry and invalidate every outstanding lease's pending
    /// commit (purge-all / epoch rotation, FR-KVP8). Also cancels queued cold-tier
    /// persist work so no pre-rotation snapshot publishes into the new epoch
    /// (CRITICAL-2).
    func purgeAllHot() async {
        globalPurgeGen += 1
        entries.removeAll()
        await coldTier?.cancelPendingPersists()
    }

    /// Drain queued cold-tier persist work on graceful shutdown (HIGH-5).
    func drainColdWrites(timeoutSeconds: Int) async {
        await coldTier?.drainPendingPersists(timeoutSeconds: timeoutSeconds)
    }

    func abort(_ lease: ConversationCacheLease) {
        releaseTurn(lease.key)
    }

    func snapshotStats() -> (entries: Int, tokens: Int) {
        currentStats()
    }

    static func longestCommonPrefix(_ lhs: [Int32], _ rhs: [Int32]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var index = 0
        while index < limit, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }

    private func waitForTurn(_ key: String) async {
        while busyKeys.contains(key) {
            await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
        }
    }

    private func releaseTurn(_ key: String) {
        busyKeys.remove(key)
        guard var keyWaiters = waiters[key], !keyWaiters.isEmpty else {
            waiters.removeValue(forKey: key)
            return
        }
        let next = keyWaiters.removeFirst()
        waiters[key] = keyWaiters.isEmpty ? nil : keyWaiters
        next.resume()
    }

    private func sweepExpired(now: Date) {
        for (key, entry) in entries where now.timeIntervalSince(entry.storedAt) > config.ttlSeconds {
            entries.removeValue(forKey: key)
            log("event=conv_cache action=evict key_hash=\(Self.keyHash(key)) reason=ttl_\(Int(config.ttlSeconds / 60))min")
        }
    }

    private func enforceLimits() {
        while entries.count > config.maxConversations || currentStats().tokens > config.maxTokens {
            guard let victim = entries.min(by: { lhs, rhs in lhs.value.lastUsedAt < rhs.value.lastUsedAt })?.key else {
                return
            }
            entries.removeValue(forKey: victim)
            log("event=conv_cache action=evict key_hash=\(Self.keyHash(victim)) reason=lru")
        }
    }

    private func currentStats() -> (entries: Int, tokens: Int) {
        (entries.count, entries.values.reduce(0) { $0 + $1.tokenCount })
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
