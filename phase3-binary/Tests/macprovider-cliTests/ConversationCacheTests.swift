import MLXLMCommon
@testable import macprovider_cli
import XCTest

final class ConversationCacheTests: XCTestCase {
    func testQuantizedKVIsDisabledForReusableConversationKeys() {
        XCTAssertNil(ModelRuntime.effectiveKVBits(configured: 8, conversationKey: "conv:buyer-1"))
        XCTAssertNil(ModelRuntime.effectiveKVBits(configured: 4, conversationKey: "   "))
        XCTAssertEqual(ModelRuntime.effectiveKVBits(configured: 8, conversationKey: nil), 8)
    }

    func testLongestCommonPrefixCases() {
        XCTAssertEqual(ConversationCache.longestCommonPrefix([], []), 0)
        XCTAssertEqual(ConversationCache.longestCommonPrefix([1, 2, 3], [1, 2, 3]), 3)
        XCTAssertEqual(ConversationCache.longestCommonPrefix([1, 2, 3], [1, 2, 9]), 2)
        XCTAssertEqual(ConversationCache.longestCommonPrefix([1, 2], [1, 2, 3]), 2)
        XCTAssertEqual(ConversationCache.longestCommonPrefix([1, 2], [9, 2]), 0)
    }

    func testHitTrimsCacheAndPreservesUsageInvariant() async {
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let seedTokens = int32Range(0..<64)
        let seed = await cache.begin(conversationKey: "conv:test", incomingTokens: seedTokens, modelID: "model-a", kvBits: nil)
        let layer = trimmableCache(offset: seedTokens.count)
        await cache.commit(seed!, cache: ConversationCacheLayers([layer]), fullTokens: seedTokens)

        let incoming = int32Range(0..<57) + int32Range(100..<112)
        let hit = await cache.begin(conversationKey: "conv:test", incomingTokens: incoming, modelID: "model-a", kvBits: nil)

        XCTAssertEqual(hit?.cachedPromptTokens, 57)
        XCTAssertEqual(hit?.trimBy, 7)
        XCTAssertEqual(layer.offset, 57)
        XCTAssertLessThanOrEqual(hit?.cachedPromptTokens ?? 0, incoming.count)
        await cache.abort(hit!)
    }

    func testModelAndKVBitsSwapMiss() async {
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let tokens = int32Range(0..<64)
        let seed = await cache.begin(conversationKey: "conv:test", incomingTokens: tokens, modelID: "model-a", kvBits: 4)
        await cache.commit(seed!, cache: ConversationCacheLayers([trimmableCache(offset: tokens.count)]), fullTokens: tokens)

        let modelSwap = await cache.begin(conversationKey: "conv:test", incomingTokens: tokens + [99], modelID: "model-b", kvBits: 4)
        XCTAssertEqual(modelSwap?.cachedPromptTokens, 0)
        await cache.abort(modelSwap!)

        let bitsSeed = await cache.begin(conversationKey: "conv:test", incomingTokens: tokens, modelID: "model-a", kvBits: 4)
        await cache.commit(bitsSeed!, cache: ConversationCacheLayers([trimmableCache(offset: tokens.count)]), fullTokens: tokens)
        let bitsSwap = await cache.begin(conversationKey: "conv:test", incomingTokens: tokens + [99], modelID: "model-a", kvBits: 8)
        XCTAssertEqual(bitsSwap?.cachedPromptTokens, 0)
        await cache.abort(bitsSwap!)
    }

    func testTTLAndNonTrimmableMiss() async {
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 60))
        let tokens = int32Range(0..<64)
        let old = Date(timeIntervalSince1970: 1_000)
        let seed = await cache.begin(conversationKey: "conv:ttl", incomingTokens: tokens, modelID: "model-a", kvBits: nil, now: old)
        await cache.commit(seed!, cache: ConversationCacheLayers([trimmableCache(offset: tokens.count)]), fullTokens: tokens, now: old)
        let expired = await cache.begin(conversationKey: "conv:ttl", incomingTokens: tokens + [99], modelID: "model-a", kvBits: nil, now: old.addingTimeInterval(61))
        XCTAssertEqual(expired?.cachedPromptTokens, 0)
        await cache.abort(expired!)

        let nonTrimSeed = await cache.begin(conversationKey: "conv:nontrim", incomingTokens: tokens, modelID: "model-a", kvBits: nil)
        await cache.commit(nonTrimSeed!, cache: ConversationCacheLayers([nonTrimmableCache(offset: tokens.count)]), fullTokens: tokens)
        let nonTrim = await cache.begin(conversationKey: "conv:nontrim", incomingTokens: tokens + [99], modelID: "model-a", kvBits: nil)
        XCTAssertEqual(nonTrim?.cachedPromptTokens, 0)
        await cache.abort(nonTrim!)
    }

    func testLRUAndTokenCapEviction() async {
        let cache = ConversationCache(config: .init(maxConversations: 2, maxTokens: 10_000, ttlSeconds: 900))
        for index in 0..<3 {
            let tokens = int32Range(0..<64).map { $0 + Int32(index * 100) }
            let lease = await cache.begin(conversationKey: "conv:\(index)", incomingTokens: tokens, modelID: "model-a", kvBits: nil)
            await cache.commit(lease!, cache: ConversationCacheLayers([trimmableCache(offset: tokens.count)]), fullTokens: tokens)
        }
        let stats = await cache.snapshotStats()
        XCTAssertEqual(stats.entries, 2)

        let tokenCapped = ConversationCache(config: .init(maxConversations: 8, maxTokens: 100, ttlSeconds: 900))
        for index in 0..<3 {
            let tokens = int32Range(0..<64).map { $0 + Int32(index * 100) }
            let lease = await tokenCapped.begin(conversationKey: "conv:t\(index)", incomingTokens: tokens, modelID: "model-a", kvBits: nil)
            await tokenCapped.commit(lease!, cache: ConversationCacheLayers([trimmableCache(offset: tokens.count)]), fullTokens: tokens)
        }
        let cappedStats = await tokenCapped.snapshotStats()
        XCTAssertLessThanOrEqual(cappedStats.tokens, 100)
    }

    func testCompletionResultClampsCachedTokensToPromptTokens() {
        let completion = CompletionResult(
            content: "ok",
            finishReason: "stop",
            promptTokens: 10,
            cachedPromptTokens: 11,
            kvCacheBytesReused: 123,
            completionTokens: 1
        )
        XCTAssertEqual(completion.cachedPromptTokens, 10)
        XCTAssertEqual(completion.kvCacheReuseRatio, 1.0)
        XCTAssertEqual(completion.kvCacheBytesReused, 123)
    }

    func testCompletionResultZerosReuseTelemetryWithoutCachedTokens() {
        let completion = CompletionResult(
            content: "ok",
            finishReason: "stop",
            promptTokens: 0,
            cachedPromptTokens: 4,
            kvCacheBytesReused: 123,
            completionTokens: 1
        )
        XCTAssertEqual(completion.cachedPromptTokens, 0)
        XCTAssertEqual(completion.kvCacheReuseRatio, 0)
        XCTAssertEqual(completion.kvCacheBytesReused, 0)
    }

    func testCachedPromptUTF8BytesUsesDecodedCachedPrefix() {
        let bytes = ModelRuntime.cachedPromptUTF8Bytes(
            promptTokenIds: [1, 2, 3, 4],
            cachedPromptTokens: 3,
            decode: { tokens in
                XCTAssertEqual(tokens, [1, 2, 3])
                return "hi µ"
            }
        )
        XCTAssertEqual(bytes, "hi µ".utf8.count)
    }

    private func int32Range(_ range: Range<Int>) -> [Int32] {
        range.map(Int32.init)
    }

    private func trimmableCache(offset: Int) -> KVCacheSimple {
        let cache = KVCacheSimple()
        cache.offset = offset
        return cache
    }

    private func nonTrimmableCache(offset: Int) -> ArraysCache {
        let cache = ArraysCache(size: 1)
        cache.offset = offset
        return cache
    }
}
