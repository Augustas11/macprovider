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

    init(
        key: String,
        keyHash: String,
        incomingTokens: [Int32],
        modelID: String,
        kvBits: Int?,
        reusableCache: ConversationCacheLayers?,
        cachedPromptTokens: Int,
        lcp: Int,
        trimBy: Int
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

    init(config: Config = .fromEnvironment()) {
        self.config = config
    }

    func begin(
        conversationKey: String?,
        incomingTokens: [Int32],
        modelID: String,
        kvBits: Int?,
        now: Date = Date()
    ) async -> ConversationCacheLease? {
        guard let key = conversationKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        await waitForTurn(key)
        busyKeys.insert(key)

        let keyHash = Self.keyHash(key)
        sweepExpired(now: now)

        guard var entry = entries.removeValue(forKey: key) else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=cold_start")
            return ConversationCacheLease(
                key: key,
                keyHash: keyHash,
                incomingTokens: incomingTokens,
                modelID: modelID,
                kvBits: kvBits,
                reusableCache: nil,
                cachedPromptTokens: 0,
                lcp: 0,
                trimBy: 0
            )
        }

        guard entry.modelID == modelID else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=model_swap stored_model=\(entry.modelID) incoming_model=\(modelID)")
            return missLease(key: key, keyHash: keyHash, incomingTokens: incomingTokens, modelID: modelID, kvBits: kvBits)
        }
        guard entry.kvBits == kvBits else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=kvbits_swap")
            return missLease(key: key, keyHash: keyHash, incomingTokens: incomingTokens, modelID: modelID, kvBits: kvBits)
        }

        let lcp = Self.longestCommonPrefix(entry.canonicalPromptTokens, incomingTokens)
        guard lcp >= Self.lcpThreshold else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=prefix_diverged lcp=\(lcp) threshold=\(Self.lcpThreshold)")
            return missLease(key: key, keyHash: keyHash, incomingTokens: incomingTokens, modelID: modelID, kvBits: kvBits)
        }
        guard lcp < incomingTokens.count else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=nothing_new lcp=\(lcp) prompt_tokens=\(incomingTokens.count)")
            return missLease(key: key, keyHash: keyHash, incomingTokens: incomingTokens, modelID: modelID, kvBits: kvBits)
        }
        guard entry.kvCache.layers.allSatisfy(\.isTrimmable) else {
            log("event=conv_cache action=miss key_hash=\(keyHash) reason=cache_not_trimmable")
            return missLease(key: key, keyHash: keyHash, incomingTokens: incomingTokens, modelID: modelID, kvBits: kvBits)
        }

        let trimBy = entry.canonicalPromptTokens.count - lcp
        if trimBy > 0 {
            for layer in entry.kvCache.layers {
                let trimmed = layer.trim(trimBy)
                if trimmed != trimBy {
                    log("event=conv_cache action=miss key_hash=\(keyHash) reason=trim_underflow requested=\(trimBy) actual=\(trimmed)")
                    return missLease(key: key, keyHash: keyHash, incomingTokens: incomingTokens, modelID: modelID, kvBits: kvBits)
                }
            }
        }
        entry.lastUsedAt = now
        let stats = currentStats()
        log("event=conv_cache action=hit key_hash=\(keyHash) cached_prompt_tokens=\(lcp) prompt_tokens=\(incomingTokens.count) lcp=\(lcp) trim_by=\(trimBy) conv_cache_entries=\(stats.entries) conv_cache_tokens=\(stats.tokens)")
        return ConversationCacheLease(
            key: key,
            keyHash: keyHash,
            incomingTokens: incomingTokens,
            modelID: modelID,
            kvBits: kvBits,
            reusableCache: entry.kvCache,
            cachedPromptTokens: min(lcp, incomingTokens.count),
            lcp: lcp,
            trimBy: trimBy
        )
    }

    func commit(_ lease: ConversationCacheLease, cache: ConversationCacheLayers, fullTokens: [Int32], now: Date = Date()) {
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
        releaseTurn(lease.key)
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

    private func missLease(
        key: String,
        keyHash: String,
        incomingTokens: [Int32],
        modelID: String,
        kvBits: Int?
    ) -> ConversationCacheLease {
        ConversationCacheLease(
            key: key,
            keyHash: keyHash,
            incomingTokens: incomingTokens,
            modelID: modelID,
            kvBits: kvBits,
            reusableCache: nil,
            cachedPromptTokens: 0,
            lcp: 0,
            trimBy: 0
        )
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
