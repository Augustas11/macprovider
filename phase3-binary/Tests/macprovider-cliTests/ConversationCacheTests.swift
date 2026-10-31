import Foundation
import MLX
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

final class ConversationCacheTests: XCTestCase {
    override func invokeTest() {
        Device.withDefaultDevice(Device(.cpu)) {
            XCTAssertEqual(Device.defaultDevice().deviceType, .cpu)
            super.invokeTest()
        }
    }

    override class func setUp() {
        super.setUp()
        Device.setDefault(device: Device(.cpu))
    }

    func testCountersAccumulateHitsMissesAndPreserveModelsAfterPurge() async throws {
        let cache = makeConversationCacheForTest()
        let tokens = int32Range(0..<64)
        let seedValue = await cache.begin(
            conversationKey: "private-conversation", incomingTokens: tokens, modelID: "model-a", kvBits: nil)
        let seed = try XCTUnwrap(seedValue)
        await cache.commit(seed, cache: ConversationCacheLayers([trimmableCache(offset: 64)]), fullTokens: tokens)
        let resident = await cache.countersSnapshot()
        XCTAssertEqual(resident.models.first?.entries, 1)
        XCTAssertEqual(resident.models.first?.tokens, 64)
        XCTAssertGreaterThanOrEqual(resident.models.first?.bytes ?? 0, 256)
        XCTAssertGreaterThan(resident.models.first?.hotByteLimit ?? 0, 0)
        let hitValue = await cache.begin(conversationKey: "private-conversation", incomingTokens: tokens + [65], modelID: "model-a", kvBits: nil)
        let hit = try XCTUnwrap(hitValue)
        await cache.commit(hit, cache: ConversationCacheLayers([trimmableCache(offset: 65)]), fullTokens: tokens + [65])
        await cache.purgeAllHot()
        let nextValue = await cache.begin(conversationKey: "other", incomingTokens: tokens, modelID: "model-b", kvBits: nil)
        let next = try XCTUnwrap(nextValue)
        await cache.abort(next)
        let snapshot = await cache.countersSnapshot()
        let model = try XCTUnwrap(snapshot.models.first { $0.modelID == "model-a" })
        XCTAssertEqual(model.lookups, 2)
        XCTAssertEqual(model.hits, 1)
        XCTAssertEqual(model.cachedPromptTokens, 64)
        XCTAssertEqual(model.misses, ["cold_start": 1])
        XCTAssertEqual(model.evictions, ["purge_all": 1])
        XCTAssertEqual(model.coldSnapshotSkips, 2)
        XCTAssertEqual(model.entries, 0)
        XCTAssertEqual(model.bytes, 0)
        XCTAssertEqual(snapshot.models.map(\.modelID), ["model-a", "model-b"])
        XCTAssertFalse(String(describing: snapshot.jsonObject).contains("private-conversation"))
        XCTAssertEqual(snapshot.jsonObject["process_id"] as? String, resident.jsonObject["process_id"] as? String)
    }

    func testCountersDistinguishCapacityEvictionsAndTTLMisses() async throws {
        let tokens = int32Range(0..<64)
        let noMemory = ConversationCacheMemoryBudget(probe: .init(identity: "no-headroom") {
            NativeMTPRoundSystemMemorySample(availableBytes: 0, physicalBytes: 64 * 1024 * 1024 * 1024)
        })
        let fixtures: [(ConversationCache.Config, ConversationCacheMemoryBudget, String, Int)] = [
            (.init(maxConversations: 1, maxTokens: 1000, ttlSeconds: 60), conversationCacheTestMemoryBudget(), "lru_count_limit", 2),
            (.init(maxConversations: 8, maxTokens: 63, ttlSeconds: 60), conversationCacheTestMemoryBudget(), "lru_token_limit", 1),
            (.init(maxConversations: 8, maxTokens: 1000, ttlSeconds: 60), noMemory, "lru_byte_limit", 1),
        ]
        for (config, budget, reason, count) in fixtures {
            let cache = makeConversationCacheForTest(config: config, memoryBudget: budget)
            for index in 0..<count {
                let value = await cache.begin(conversationKey: "key-\(index)", incomingTokens: tokens, modelID: "m", kvBits: nil)
                let lease = try XCTUnwrap(value)
                await cache.commit(lease, cache: ConversationCacheLayers([trimmableCache(offset: 64)]), fullTokens: tokens)
            }
            let snapshot = await cache.countersSnapshot()
            XCTAssertEqual(snapshot.models.first?.evictions, [reason: 1])
        }
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 1000, ttlSeconds: 60))
        let start = Date(timeIntervalSince1970: 1000)
        let seedValue = await cache.begin(conversationKey: "ttl", incomingTokens: tokens, modelID: "m", kvBits: nil, now: start)
        let seed = try XCTUnwrap(seedValue)
        await cache.commit(seed, cache: ConversationCacheLayers([trimmableCache(offset: 64)]), fullTokens: tokens, now: start)
        let missValue = await cache.begin(conversationKey: "ttl", incomingTokens: tokens + [65], modelID: "m", kvBits: nil, now: start.addingTimeInterval(61))
        let miss = try XCTUnwrap(missValue)
        await cache.abort(miss)
        let snapshot = await cache.countersSnapshot()
        XCTAssertEqual(snapshot.models.first?.misses, ["cold_start": 1, "ttl": 1])
        XCTAssertEqual(snapshot.models.first?.evictions, ["ttl": 1])
    }

    func testRevokedFleetGrantCannotBeginOrPublishAfterPurge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = FleetConversationCacheAuthority(storageURL: root.appendingPathComponent("floors.json"))
        let key = "conv:fleet-a"
        let grant = try authority.authorize(conversationKey: key, generation: 1)
        let cache = makeConversationCacheForTest()
        let tokens = int32Range(0..<64)
        let lease = await cache.begin(conversationKey: key, incomingTokens: tokens,
                                      modelID: "model-a", kvBits: nil, fleetGrant: grant)
        let active = try XCTUnwrap(lease)
        _ = try await authority.revokeAndPurge(conversationKey: key, through: 1) { key in
            _ = await cache.purgeHot(conversationKey: key)
            return true
        }
        await cache.commit(active, cache: ConversationCacheLayers([trimmableCache(offset: 64)]), fullTokens: tokens)
        let stale = await cache.begin(conversationKey: key, incomingTokens: tokens + [99],
                                      modelID: "model-a", kvBits: nil, fleetGrant: grant)
        XCTAssertNil(stale)
        let next = try authority.authorize(conversationKey: key, generation: 2)
        let fresh = await cache.begin(conversationKey: key, incomingTokens: tokens + [99],
                                      modelID: "model-a", kvBits: nil, fleetGrant: next)
        XCTAssertEqual(fresh?.cachedPromptTokens, 0)
        if let fresh { await cache.abort(fresh) }
    }

    func testFleetGrantCannotSelectDifferentConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = FleetConversationCacheAuthority(storageURL: root.appendingPathComponent("floors.json"))
        let grant = try authority.authorize(conversationKey: "conv:account-a", generation: 1)
        let cache = makeConversationCacheForTest()
        let lease = await cache.begin(conversationKey: "conv:account-b", incomingTokens: [1, 2],
                                      modelID: "model-a", kvBits: nil, fleetGrant: grant)
        XCTAssertNil(lease)
    }

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
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
        let counters = await cache.countersSnapshot()
        XCTAssertEqual(counters.models.first { $0.modelID == "model-b" }?.misses["model_swap"], 1)
        XCTAssertEqual(counters.models.first { $0.modelID == "model-a" }?.misses["kvbits_swap"], 1)
    }

    func testTTLAndNonTrimmableMiss() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 60))
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

    func testSerialFallbackAbortRestoresNonRetainedCacheForBillingParity() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let seedTokens = int32Range(0..<64)
        let seed = await cache.begin(conversationKey: "conv:fallback", incomingTokens: seedTokens, modelID: "model-a", kvBits: nil)
        let layer = trimmableCache(offset: seedTokens.count)
        await cache.commit(seed!, cache: ConversationCacheLayers([layer]), fullTokens: seedTokens)

        let incoming = int32Range(0..<57) + int32Range(100..<112)
        let canaryLease = await cache.begin(
            conversationKey: "conv:fallback",
            incomingTokens: incoming,
            modelID: "model-a",
            kvBits: nil,
            allowRetainedPagedKVHandoff: true
        )
        XCTAssertEqual(canaryLease?.cachedPromptTokens, 57)
        XCTAssertEqual(layer.offset, 57)

        await cache.abortForSerialFallback(canaryLease!)

        let serialLease = await cache.begin(
            conversationKey: "conv:fallback",
            incomingTokens: incoming,
            modelID: "model-a",
            kvBits: nil
        )
        XCTAssertEqual(serialLease?.cachedPromptTokens, 57)
        XCTAssertEqual(serialLease?.trimBy, 0)
        XCTAssertEqual(layer.offset, 57)
        await cache.abort(serialLease!)
    }

    func testSerialFallbackAbortDoesNotRestoreAfterPurge() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let seedTokens = int32Range(0..<64)
        let seed = await cache.begin(conversationKey: "conv:fallback-purge", incomingTokens: seedTokens, modelID: "model-a", kvBits: nil)
        let layer = trimmableCache(offset: seedTokens.count)
        await cache.commit(seed!, cache: ConversationCacheLayers([layer]), fullTokens: seedTokens)

        let incoming = int32Range(0..<57) + int32Range(100..<112)
        let canaryLease = await cache.begin(
            conversationKey: "conv:fallback-purge",
            incomingTokens: incoming,
            modelID: "model-a",
            kvBits: nil,
            allowRetainedPagedKVHandoff: true
        )
        XCTAssertEqual(canaryLease?.cachedPromptTokens, 57)

        _ = await cache.purgeHot(conversationKey: "conv:fallback-purge")
        await cache.abortForSerialFallback(canaryLease!)

        let serialLease = await cache.begin(
            conversationKey: "conv:fallback-purge",
            incomingTokens: incoming,
            modelID: "model-a",
            kvBits: nil
        )
        XCTAssertEqual(serialLease?.cachedPromptTokens, 0)
        await cache.abort(serialLease!)
    }

    func testRotatingKVCacheStopsBeingTrimmableOnceFilled() {
        let rotating = RotatingKVCache(maxSize: 8, keep: 0)
        rotating.offset = 7
        XCTAssertTrue(rotating.isTrimmable, "below the serve cap the rotating cache still trims")
        rotating.offset = 8
        XCTAssertFalse(rotating.isTrimmable, "at maxSize FR-CI2 would miss with cache_not_trimmable")
        let simple = KVCacheSimple()
        simple.offset = 8
        XCTAssertTrue(simple.isTrimmable, "KVCacheSimple stays trimmable after the same offset")
    }

    func testRotatingWindowCacheMissesEvenWhenTemporarilyTrimmable() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let tokens = int32Range(0..<64)
        let seed = await cache.begin(conversationKey: "conv:windowed", incomingTokens: tokens, modelID: "model-a", kvBits: nil)
        let rotating = RotatingKVCache(maxSize: 256, keep: 0)
        rotating.offset = tokens.count
        XCTAssertTrue(rotating.isTrimmable)
        await cache.commit(seed!, cache: ConversationCacheLayers([rotating]), fullTokens: tokens)

        let hit = await cache.begin(
            conversationKey: "conv:windowed",
            incomingTokens: tokens + int32Range(100..<112),
            modelID: "model-a",
            kvBits: nil
        )
        XCTAssertEqual(hit?.cachedPromptTokens, 0, "sliding-window RotatingKVCache must miss, not reuse a temporary trim")
        await cache.abort(hit!)
    }

    /// Eligible prompt snapshots pass through the same encrypted cold-tier bridge.
    func testPromptSnapshotIsCapturedByTheColdTier() async {
        let coldTier = FakeConversationColdTier()
        let cache = makeConversationCacheForTest(
            config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900), coldTier: coldTier)
        let tokens = int32Range(0..<64)
        let snapshotLease = await cache.begin(conversationKey: "conv:snapshot-cold", incomingTokens: tokens,
                                              modelID: "model-a", kvBits: nil, cold: coldContext(eligible: true))
        await cache.commit(snapshotLease!, cache: ConversationCacheLayers(
            [RotatingKVCache(maxSize: 8, keep: 0), DeepseekV4PoolCache(ratio: 4)], promptSnapshot: true),
            fullTokens: tokens, cold: coldContext(eligible: true))
        XCTAssertEqual(coldTier.captureCount, 1)
        let ordinaryLease = await cache.begin(conversationKey: "conv:ordinary-cold", incomingTokens: tokens,
                                              modelID: "model-a", kvBits: nil, cold: coldContext(eligible: true))
        await cache.commit(ordinaryLease!, cache: ConversationCacheLayers([trimmableCache(offset: 64)]),
                           fullTokens: tokens, cold: coldContext(eligible: true))
        XCTAssertEqual(coldTier.captureCount, 2)
    }

    func testKeyedSerialSimpleCacheHitSkipsPrefillTokens() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let seedTokens = int32Range(0..<64)
        let seed = await cache.begin(conversationKey: "conv:auto.prefix.hit", incomingTokens: seedTokens, modelID: "model-a", kvBits: nil)
        let layer = KVCacheSimple()
        layer.offset = seedTokens.count
        await cache.commit(seed!, cache: ConversationCacheLayers([layer]), fullTokens: seedTokens)

        let incoming = int32Range(0..<64) + int32Range(100..<112)
        let hit = await cache.begin(conversationKey: "conv:auto.prefix.hit", incomingTokens: incoming, modelID: "model-a", kvBits: nil)
        XCTAssertEqual(hit?.cachedPromptTokens, 64)
        XCTAssertEqual(hit?.lcp, 64)
        XCTAssertEqual(hit?.trimBy, 0)
        XCTAssertEqual(layer.offset, 64)
        XCTAssertTrue(layer.isTrimmable)
        await cache.abort(hit!)
    }

    func testTTLSweepDoesNotRemoveEntryCommittedDuringRetainedDiscard() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 60))
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let oldRetained = try await retainedSequence(
            allocator: allocator,
            conversationKey: "conv:ttl-race",
            tokenCount: 64
        )
        let newTokens = int32Range(0..<64)
        let replacementCommitted = CacheCompletionFlag()
        let oldTokens = int32Range(100..<164)
        let oldSeed = await cache.begin(
            conversationKey: "conv:ttl-race",
            incomingTokens: oldTokens,
            modelID: "model-a",
            kvBits: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        await cache.commit(
            oldSeed!,
            cache: ConversationCacheLayers(
                [trimmableCache(offset: oldTokens.count)],
                retainedPagedKVSequence: oldRetained,
                discardRetainedPagedKVSequence: { retained, key in
                    try? await allocator.discardRetained(retained, conversationKey: key)
                    let replacementSeed = await cache.begin(
                        conversationKey: "conv:ttl-race",
                        incomingTokens: newTokens,
                        modelID: "model-a",
                        kvBits: nil,
                        now: Date(timeIntervalSince1970: 1_100)
                    )
                    await cache.commit(
                        replacementSeed!,
                        cache: ConversationCacheLayers([self.trimmableCache(offset: newTokens.count)]),
                        fullTokens: newTokens,
                        now: Date(timeIntervalSince1970: 1_100)
                    )
                    await replacementCommitted.markComplete()
                }
            ),
            fullTokens: oldTokens,
            now: Date(timeIntervalSince1970: 1_000)
        )

        let trigger = await cache.begin(
            conversationKey: "conv:trigger",
            incomingTokens: [1, 2, 3],
            modelID: "model-a",
            kvBits: nil,
            now: Date(timeIntervalSince1970: 1_061)
        )
        await cache.abort(trigger!)
        let didCommitReplacement = await replacementCommitted.isComplete
        XCTAssertTrue(didCommitReplacement)

        let hit = await cache.begin(
            conversationKey: "conv:ttl-race",
            incomingTokens: newTokens + [64],
            modelID: "model-a",
            kvBits: nil,
            now: Date(timeIntervalSince1970: 1_100)
        )
        XCTAssertEqual(hit?.cachedPromptTokens, 64)
        await cache.abort(hit!)
    }

    func testLRUAndTokenCapEviction() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 2, maxTokens: 10_000, ttlSeconds: 900))
        for index in 0..<3 {
            let tokens = int32Range(0..<64).map { $0 + Int32(index * 100) }
            let lease = await cache.begin(conversationKey: "conv:\(index)", incomingTokens: tokens, modelID: "model-a", kvBits: nil)
            await cache.commit(lease!, cache: ConversationCacheLayers([trimmableCache(offset: tokens.count)]), fullTokens: tokens)
        }
        let stats = await cache.snapshotStats()
        XCTAssertEqual(stats.entries, 2)

        let tokenCapped = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 100, ttlSeconds: 900))
        for index in 0..<3 {
            let tokens = int32Range(0..<64).map { $0 + Int32(index * 100) }
            let lease = await tokenCapped.begin(conversationKey: "conv:t\(index)", incomingTokens: tokens, modelID: "model-a", kvBits: nil)
            await tokenCapped.commit(lease!, cache: ConversationCacheLayers([trimmableCache(offset: tokens.count)]), fullTokens: tokens)
        }
        let cappedStats = await tokenCapped.snapshotStats()
        XCTAssertLessThanOrEqual(cappedStats.tokens, 100)
    }

    func testAgentDefaultsRetainMoreThanEightConversationsPastOldTTL() async throws {
        let config = ConversationCache.Config.fromEnvironment([:])
        XCTAssertEqual(config.maxConversations, 64)
        XCTAssertEqual(config.maxTokens, 2_000_000)
        XCTAssertEqual(config.ttlSeconds, 3 * 24 * 60 * 60)
        let cache = makeConversationCacheForTest(config: config)
        let start = Date(timeIntervalSince1970: 1_000)
        let tokens = int32Range(0..<64)
        for index in 0..<12 {
            let lease = await cache.begin(conversationKey: "conv:agent-\(index)", incomingTokens: tokens,
                                          modelID: "model-a", kvBits: nil, now: start)
            await cache.commit(try XCTUnwrap(lease), cache: ConversationCacheLayers(
                [trimmableCache(offset: 64)], promptSnapshot: true), fullTokens: tokens, now: start)
        }
        let hit = await cache.begin(conversationKey: "conv:agent-0", incomingTokens: tokens + [65],
                                    modelID: "model-a", kvBits: nil, now: start.addingTimeInterval(901))
        XCTAssertEqual(hit?.cachedPromptTokens, 64)
        if let hit { await cache.abort(hit) }
    }

    func testLRUProtectsLongPrefixOnRecencyTie() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 2, maxTokens: 10_000, ttlSeconds: 900))
        let now = Date(timeIntervalSince1970: 1_000)
        for (key, count) in [("long", 128), ("short", 64), ("new", 96)] {
            let tokens = int32Range(0..<count)
            let lease = await cache.begin(conversationKey: key, incomingTokens: tokens,
                                          modelID: "model-a", kvBits: nil, now: now)
            await cache.commit(try XCTUnwrap(lease), cache: ConversationCacheLayers(
                [trimmableCache(offset: count)]), fullTokens: tokens, now: now)
        }
        let hit = await cache.begin(conversationKey: "long", incomingTokens: int32Range(0..<129),
                                    modelID: "model-a", kvBits: nil, now: now)
        XCTAssertEqual(hit?.cachedPromptTokens, 128)
        if let hit { await cache.abort(hit) }
        let miss = await cache.begin(conversationKey: "short", incomingTokens: int32Range(0..<65),
                                     modelID: "model-a", kvBits: nil, now: now)
        XCTAssertEqual(miss?.cachedPromptTokens, 0)
        if let miss { await cache.abort(miss) }
    }

    func testRetentionByteLimitProtectsServingAndStagingHeadroom() async throws {
        let gib = 1024 * 1024 * 1024
        let physical = 64 * gib
        let available = physical / 10 + 2 * gib + 4_096
        let budget = ConversationCacheMemoryBudget(probe: .init(identity: "bounded-test") {
            NativeMTPRoundSystemMemorySample(availableBytes: available, physicalBytes: physical)
        })
        XCTAssertEqual(budget.hotByteLimit(), 4_095)
        let cache = makeConversationCacheForTest(memoryBudget: budget)
        let tokens = int32Range(0..<64)
        // Host-data initializers use MLX's Metal allocator even for CPU
        // operations. Lazy CPU arrays provide the same byte metadata without
        // allocating/evaluating tensors or requiring a metallib in CI.
        let layer = KVCacheSimple()
        layer.state = [
            MLXArray.arange(1_024, dtype: .float32, stream: .cpu)
                .reshaped(1, 1, 64, 16, stream: .cpu),
            MLXArray.arange(1_024, dtype: .float32, stream: .cpu)
                .reshaped(1, 1, 64, 16, stream: .cpu),
        ]
        let lease = await cache.begin(conversationKey: "conv:bytes", incomingTokens: tokens,
                                      modelID: "model-a", kvBits: nil)
        await cache.commit(try XCTUnwrap(lease), cache: ConversationCacheLayers([layer]), fullTokens: tokens)
        let stats = await cache.snapshotStats()
        XCTAssertEqual(stats.entries, 0, "tensor bytes evict before retention consumes serving headroom")
        budget.configure(maxContextTokens: 131_072, slots: 4, residentTokens: 65_536, verifyBytes: gib)
        XCTAssertEqual(budget.hotByteLimit(), 0)
        XCTAssertFalse(budget.admitsStaging(bytes: gib))
    }

    // CPU metadata fixtures: no tensor allocation, evaluation or model load.
    func testShortGLMSeedDoesNotExtrapolateBoundedIndexerWindows() {
        let gib = 1024 * 1024 * 1024
        let budget = ConversationCacheMemoryBudget(probe: .init(identity: "short-glm-seed") {
            .init(availableBytes: 80 * gib, physicalBytes: 256 * gib)
        })
        budget.configure(maxContextTokens: 200_000, slots: 4, residentTokens: 65_536, verifyBytes: 0)
        // Representative sparse-layer geometry: bf16 latent 512, index width
        // 128, pool 4, rewind 16. Thirty-token seeds already fill rewind state.
        let layer = ConversationCacheMemoryBudget.glmGeometry(
            latentBytesPerToken: 1_024, pooledBytesPerKey: 256,
            rawKeyBytesPerToken: 256, rawGateBytesPerToken: 256,
            kpool: 4, maxTrim: 16, step: 256)
        XCTAssertEqual(layer.bytesPerToken, 1_088)
        XCTAssertEqual(layer.fixedRowBytes, 272_384)
        budget.observe(geometry: .init(fixedRowBytes: layer.fixedRowBytes * 48,
                                       bytesPerToken: layer.bytesPerToken * 48))
        XCTAssertEqual(budget.hotByteLimit(), 8 * gib,
                       "the 30-token seed must leave useful retention after full four-slot reserve")
        // Old classification scales all 22 raw columns by 800k/30. That
        // fictitious state alone is 13.4 GiB and drives this same guard to zero.
        let oldDensity = ((30 * 1_024 + 7 * 256 + 22 * 512) * 48 + 29) / 30
        let oldReserve = 800_000 * oldDensity + (256 - 30) * 1_024 * 48 * 4
        XCTAssertGreaterThan(oldReserve + oldReserve / 20 + 256 * gib / 10 + 2 * gib, 80 * gib)
    }

    func testGLMBudgetPreservesVerifyStagingAndFreeFloorAtFullSlots() {
        let gib = 1024 * 1024 * 1024
        let layer = ConversationCacheMemoryBudget.glmGeometry(
            latentBytesPerToken: 1_024, pooledBytesPerKey: 256,
            rawKeyBytesPerToken: 256, rawGateBytesPerToken: 256,
            kpool: 4, maxTrim: 16, step: 256)
        for available in [24 * gib, 26 * gib, 80 * gib] {
            let budget = ConversationCacheMemoryBudget(probe: .init(identity: "full-slots-\(available)") {
                .init(availableBytes: available, physicalBytes: 256 * gib)
            })
            budget.configure(maxContextTokens: 200_000, slots: 4, residentTokens: 65_536, verifyBytes: gib)
            budget.observe(geometry: .init(fixedRowBytes: layer.fixedRowBytes * 48,
                                           bytesPerToken: layer.bytesPerToken * 48))
            XCTAssertEqual(budget.hotByteLimit(), 0,
                           "even corrected geometry cannot spend full-slot/head/verify/floor reserves")
            XCTAssertFalse(budget.admitsStaging(bytes: gib))
        }
    }

    func testLiveGLMSnapshotSurvivesOversizedLogicalPoolAtFourSlots() async throws {
        // XCTest async tasks need their own task-local CPU device scope.
        try await Device.withDefaultDevice(Device(.cpu)) {
            let gib = 1024 * 1024 * 1024
            // 256 GiB Studio, ~175 GB resident model. Free + inactive + purgeable
            // pages from the live defect sample; no model or tensor evaluation.
            let available = (4_223_692 + 371_987 + 28_736) * 16_384
            let tokens = int32Range(0..<4_598)
            var layers: [KVCache] = []
            for index in 0..<45 {
                if index % 4 == 3 {
                    // Preserve the GLM tensor layouts in a metadata-only container:
                    // GLM's state getter creates an empty scalar-backed array
                    // that requires Metal even when only reading byte counts.
                    let layer = ArraysCache(size: 6)
                    layer.state = [
                        MLXArray.arange(2_359_296, dtype: .float32, stream: .cpu)
                            .asType(.bfloat16, stream: .cpu).reshaped([1, 1, 4_608, 512], stream: .cpu),
                        MLXArray.arange(147_072, dtype: .float32, stream: .cpu)
                            .asType(.bfloat16, stream: .cpu).reshaped([1, 1_149, 128], stream: .cpu),
                        MLXArray.arange(256, dtype: .float32, stream: .cpu)
                            .asType(.bfloat16, stream: .cpu).reshaped([1, 2, 128], stream: .cpu),
                        MLXArray.arange(256, dtype: .float32, stream: .cpu)
                            .asType(.bfloat16, stream: .cpu).reshaped([1, 2, 128], stream: .cpu),
                        MLXArray.arange(2_432, dtype: .float32, stream: .cpu)
                            .asType(.bfloat16, stream: .cpu).reshaped([1, 19, 128], stream: .cpu),
                        MLXArray.arange(2_432, dtype: .float32, stream: .cpu)
                            .asType(.bfloat16, stream: .cpu).reshaped([1, 19, 128], stream: .cpu),
                    ]
                    layer.offset = tokens.count
                    layers.append(layer)
                } else {
                    let layer = MambaCache()
                    layer.state = [
                        MLXArray.arange(73_728, dtype: .float32, stream: .cpu)
                            .asType(.bfloat16, stream: .cpu).reshaped([1, 3, 24_576], stream: .cpu),
                        MLXArray.arange(1_048_576, dtype: .float32, stream: .cpu)
                            .asType(.float32, stream: .cpu).reshaped([1, 64, 128, 128], stream: .cpu),
                    ]
                    layer.offset = tokens.count
                    layers.append(layer)
                }
            }
            let snapshot = ConversationCacheLayers(layers, promptSnapshot: true, resumeBoundaryPlan: true)
            let entryBytes = ConversationCacheMemoryBudget.tensorBytes(snapshot) + tokens.count * 4
            XCTAssertEqual(entryBytes, 202_896_600)
            // Live ordinary CB has no admitted native capability. Also exercise a
            // native verify window: its existing target/head reserve must survive.
            for verifyBytes in [0, gib] {
                let budget = ConversationCacheMemoryBudget(probe: .init(identity: "live-glm-\(verifyBytes)") {
                    .init(availableBytes: available, physicalBytes: 256 * gib)
                })
                budget.configure(maxContextTokens: 200_000, slots: 4,
                                 residentTokens: 102_400 * 256, verifyBytes: verifyBytes)
                let sparse = ConversationCacheMemoryBudget.glmGeometry(
                    latentBytesPerToken: 1_024, pooledBytesPerKey: 256,
                    rawKeyBytesPerToken: 256, rawGateBytesPerToken: 256,
                    kpool: 4, maxTrim: 16, step: 256)
                budget.observe(geometry: .init(
                    fixedRowBytes: 34 * (3 * 24_576 * 2 + 64 * 128 * 128 * 4) + 11 * sparse.fixedRowBytes,
                    bytesPerToken: 11 * sparse.bytesPerToken))
                XCTAssertEqual(budget.hotByteLimit(), 8 * gib)
                XCTAssertTrue(budget.admitsStaging(bytes: gib))
                let cache = makeConversationCacheForTest(memoryBudget: budget)
                let lease = await cache.begin(conversationKey: "conv:live-glm", incomingTokens: tokens,
                                              modelID: "glm-live", kvBits: nil)
                await cache.commit(try XCTUnwrap(lease), cache: snapshot, fullTokens: tokens)
                let stats = await cache.snapshotStats()
                XCTAssertEqual(stats.entries, 1)
                let warm = await cache.begin(conversationKey: "conv:live-glm", incomingTokens: tokens + [7],
                                             modelID: "glm-live", kvBits: nil)
                XCTAssertEqual(warm?.cachedPromptTokens, tokens.count)
                if let warm { await cache.abort(warm) }
            }
        }
    }

    func testReported108kGLMEntryFitsDefaultHotRetentionAfter2185() {
        let gib = 1 << 30
        let physical = 256 * gib
        let available = (4_223_692 + 371_987 + 28_736) * 16_384
        let fixed = 150_616_064 // recurrent state + GLM padding/raw windows
        let density = 11_968
        let reachableRowBytes = 800_000 * density + 4 * fixed
        let reserved = (physical + 9) / 10 + reachableRowBytes + reachableRowBytes / 20 + 2 * gib
        XCTAssertEqual(reachableRowBytes, 10_176_864_256)
        XCTAssertEqual(reserved, 40_320_981_811)
        let config = ConversationCache.Config.fromEnvironment([:])
        XCTAssertEqual(config.maxConversations, 64)
        XCTAssertEqual(config.maxTokens, 2_000_000)
        let budget = ConversationCacheMemoryBudget(probe: .init(identity: "reported-108k") {
            .init(availableBytes: available, physicalBytes: physical)
        })
        budget.configure(maxContextTokens: 200_000, slots: 4,
                         residentTokens: 26_214_400, verifyBytes: 0)
        budget.observe(geometry: .init(fixedRowBytes: fixed, bytesPerToken: density))
        XCTAssertEqual(budget.hotByteLimit(), 8 * gib)
        // The emitted decoded length includes codec metadata. Either this exact
        // measured entry or the padded tensor estimate fits the hot byte bound.
        XCTAssertLessThan(1_445_244_936, budget.hotByteLimit())
        for tokens in [108_380, 114_000] {
            XCTAssertLessThan(fixed + tokens * (density + 4), budget.hotByteLimit())
            XCTAssertLessThan(tokens, config.maxTokens)
        }
        // Before #2185, reserving the logical pool instead of reachable rows
        // consumed over 300 GB: the same measured host had no hot allowance.
        XCTAssertGreaterThan(26_214_400 * density, available)
    }

    func testLongGLMConversationBudgetPreservesServingFloors() {
        let gib = 1024 * 1024 * 1024
        let physical = 256 * gib
        let available = (4_223_692 + 371_987 + 28_736) * 16_384
        let sparse = ConversationCacheMemoryBudget.glmGeometry(
            latentBytesPerToken: 512 * 2, pooledBytesPerKey: 128 * 2,
            rawKeyBytesPerToken: 128 * 2, rawGateBytesPerToken: 128 * 2,
            kpool: 4, maxTrim: 16, step: 256)
        let recurrentBytes = 34 * (3 * 24_576 * 2 + 64 * 128 * 128 * 4)
        let density = 11 * sparse.bytesPerToken
        let fixed = recurrentBytes + 11 * sparse.fixedRowBytes
        XCTAssertEqual(recurrentBytes, 147_619_840)
        XCTAssertEqual(density, 11_968)
        let serving = 800_000 * density + fixed * 4
        let reserved = physical / 10 + 1 + serving + serving / 20 + 2 * gib
        for (tokens, expectedBytes) in [(100_000, 1_347_816_064), (128_000, 1_683_032_064)] {
            let entryBytes = fixed + tokens * (density + MemoryLayout<Int32>.stride)
            XCTAssertEqual(entryBytes, expectedBytes)
            XCTAssertGreaterThan(2 * (recurrentBytes + tokens * (density + 4)),
                                 KVDiskCacheStoreConfig.promotionCeilingHardMax)
            for (freeBytes, expectedLimit) in [(available, 8 * gib), (reserved, 0),
                                              (reserved + entryBytes - 1, entryBytes - 1),
                                              (reserved + entryBytes, entryBytes)] {
                let budget = ConversationCacheMemoryBudget(probe: .init(identity: "long-glm-\(tokens)-\(freeBytes)") {
                    .init(availableBytes: freeBytes, physicalBytes: physical)
                })
                budget.configure(maxContextTokens: 200_000, slots: 4,
                                 residentTokens: 26_214_400, verifyBytes: 0)
                budget.observe(geometry: .init(fixedRowBytes: fixed, bytesPerToken: density))
                XCTAssertEqual(budget.hotByteLimit(), expectedLimit)
                XCTAssertEqual(entryBytes <= budget.hotByteLimit(), expectedLimit >= entryBytes)
            }
        }
        let overflow = ConversationCacheMemoryBudget(probe: .init(identity: "long-glm-overflow") {
            .init(availableBytes: physical, physicalBytes: physical)
        })
        overflow.configure(maxContextTokens: Int.max, slots: 4, residentTokens: 26_214_400, verifyBytes: 0)
        overflow.observe(geometry: .init(fixedRowBytes: fixed, bytesPerToken: density))
        XCTAssertEqual(overflow.hotByteLimit(), 0)
    }

    func testLongPromptRemainsHotWhenColdCaptureIsRefused() async throws {
        try await Device.withDefaultDevice(Device(.cpu)) {
            let gib = 1024 * 1024 * 1024
            for (count, expectedBytes) in [(100_000, 1_347_816_064), (128_000, 1_683_032_064)] {
                let budget = ConversationCacheMemoryBudget(probe: .init(identity: "long-refused-cold-\(count)") {
                    .init(availableBytes: (4_223_692 + 371_987 + 28_736) * 16_384,
                          physicalBytes: 256 * gib)
                })
                budget.configure(maxContextTokens: 200_000, slots: 4,
                                 residentTokens: 26_214_400, verifyBytes: 0)
                let coldTier = FakeConversationColdTier(refuseCapture: true)
                let cache = makeConversationCacheForTest(coldTier: coldTier, memoryBudget: budget)
                let tokens = int32Range(0..<count)
                // Lazy CPU metadata carriers reproduce the GLM byte geometry;
                // no tensor values are evaluated or model loaded.
                let attention = KVCacheSimple()
                attention.state = (0..<2).map { _ in
                    MLXArray.arange(count * 1_496, dtype: .float32, stream: .cpu)
                        .reshaped([1, 1, count, 1_496], stream: .cpu)
                }
                let fixed = ArraysCache(size: 1)
                fixed.state = [MLXArray.arange(150_616_064 / 4, dtype: .float32, stream: .cpu)]
                let snapshot = ConversationCacheLayers([attention, fixed], promptSnapshot: true,
                                                       resumeBoundaryPlan: true)
                XCTAssertEqual(ConversationCacheMemoryBudget.tensorBytes(snapshot) + count * 4, expectedBytes)
                let lease = await cache.begin(conversationKey: "conv:long-refused", incomingTokens: tokens,
                                              modelID: "model-a", kvBits: nil, cold: coldContext(eligible: true))
                await cache.commit(try XCTUnwrap(lease), cache: snapshot, fullTokens: tokens,
                                   cold: coldContext(eligible: true))
                XCTAssertEqual(coldTier.captureAttemptCount, 1)
                XCTAssertEqual(coldTier.enqueueCount, 0)
                let stats = await cache.snapshotStats()
                XCTAssertEqual(stats.entries, 1)
                let hit = await cache.begin(conversationKey: "conv:long-refused", incomingTokens: tokens + [7],
                                            modelID: "model-a", kvBits: nil, cold: coldContext(eligible: true))
                XCTAssertEqual(hit?.cachedPromptTokens, count)
                if let hit { await cache.abort(hit) }
            }
        }
    }

    func testLogicalPoolCapStillReservesFullRowsAndFailsClosedUnderPressure() {
        let gib = 1024 * 1024 * 1024
        let physical = 256 * gib
        let floor = physical / 10 + 1
        // Full four-row GLM geometry from the live model, not 48 sparse layers.
        let fixed = 34 * (3 * 24_576 * 2 + 64 * 128 * 128 * 4) + 11 * 272_384
        let density = 11 * 1_088
        let serving = 800_000 * density + fixed * 4
        let reserved = floor + serving + serving / 20 + 2 * gib
        for pool in [65_536, 800_000, 26_214_400, Int.max] {
            for extra in [0, 1, 4_096] {
                let budget = ConversationCacheMemoryBudget(probe: .init(identity: "pool-floor-\(pool)-\(extra)") {
                    .init(availableBytes: reserved + extra, physicalBytes: physical)
                })
                budget.configure(maxContextTokens: 200_000, slots: 4, residentTokens: pool, verifyBytes: 0)
                budget.observe(geometry: .init(fixedRowBytes: fixed, bytesPerToken: density))
                XCTAssertEqual(budget.hotByteLimit(), extra)
                XCTAssertEqual(budget.admitsStaging(bytes: gib), extra > 0)
            }
        }
        let overflow = ConversationCacheMemoryBudget(probe: .init(identity: "row-overflow") {
            .init(availableBytes: physical, physicalBytes: physical)
        })
        overflow.configure(maxContextTokens: Int.max, slots: 4, residentTokens: 1, verifyBytes: 0)
        overflow.observe(geometry: .init(bytesPerToken: density))
        XCTAssertEqual(overflow.hotByteLimit(), 0)
    }

    func testGLMPromptSnapshotBudgetCountsPaddedTargetAndHeadBuffers() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KV_ENABLE_MLX_TESTS"] == "1",
                          "requires MLX runtime (set KV_ENABLE_MLX_TESTS=1 on a capable host)")
        let target = GLM5NextAttentionCache(kpool: 4)
        let head = GLM5NextAttentionCache(kpool: 4)
        _ = target.appendLatent(MLXArray([Float(1), 2, 3], [1, 1, 3, 1]))
        _ = head.appendLatent(MLXArray([Float(4), 5, 6], [1, 1, 3, 1]))
        let snapshot = ConversationCacheLayers([target], promptSnapshot: true,
            nativeMTPDrafter: NativeMTPDrafterPrefixSnapshot(
                cache: [head.copy()], nextPosition: 3, foldedNextToken: 7), resumeBoundaryPlan: true)
        let logicalBytes = (target.state + head.state).reduce(0) { $0 + $1.nbytes }
        let backingBytes = (target.innerState() + head.innerState()).reduce(0) { $0 + $1.nbytes }
        XCTAssertGreaterThan(backingBytes, logicalBytes, "the fixture must retain step-rounded padding")
        XCTAssertEqual(ConversationCacheMemoryBudget.tensorBytes(snapshot), backingBytes,
                       "both the target and copied MTP head must charge their complete retained buffers")
        let gib = 1024 * 1024 * 1024
        let physical = 64 * gib
        let available = physical / 10 + 2 * gib + 1_000_000
        let budget = ConversationCacheMemoryBudget(probe: .init(identity: "glm-padding-test") {
            NativeMTPRoundSystemMemorySample(availableBytes: available, physicalBytes: physical)
        })
        budget.configure(maxContextTokens: 3_000, slots: 1, residentTokens: 3_000, verifyBytes: 0)
        budget.observe(layers: snapshot, tokenCount: 3)
        let variableBytes = logicalBytes / 3 * 3_000
        let servingBytes = 255 * 4 * 2 + variableBytes
        let expected = available - (physical / 10 + 1) - 2 * gib - servingBytes - servingBytes / 20
        XCTAssertEqual(budget.hotByteLimit(), expected,
                       "padding is reserved once per row while valid-token state scales to full context")
        XCTAssertGreaterThan(budget.hotByteLimit(), 900_000,
                             "short warmup padding must not inflate per-token density")
    }

    func testUnknownMemorySampleDeclinesOpportunisticAllocations() {
        let budget = ConversationCacheMemoryBudget(probe: .init(identity: "unavailable") { nil })
        XCTAssertEqual(budget.hotByteLimit(), 0)
        XCTAssertFalse(budget.admitsStaging(bytes: 1))
    }

    func testCompletionResultClampsCachedTokensToPromptTokens() {
        let completion = CompletionResult(
            content: "ok",
            finishReason: "stop",
            promptTokens: 10,
            cachedPromptTokens: 11,
            kvCacheBytesReused: 123,
            completionTokens: 1,
            settlementDisposition: .eligibleOwner
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
            completionTokens: 1,
            settlementDisposition: .eligibleOwner
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

    func testCommitReplacingConsumedRetainedHandleDoesNotDiscardNewOwner() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let handle = try await allocator.allocate(
            conversationKey: "conv:retained",
            initialCapacityTokens: 64,
            maxLogicalTokens: 80,
            initialTokens: 64
        )
        let oldRetained = try await allocator.retain(handle)
        let recorder = RetainedDiscardRecorder()
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let seedTokens = int32Range(0..<64)
        let seed = await cache.begin(
            conversationKey: "conv:retained",
            incomingTokens: seedTokens,
            modelID: "model-a",
            kvBits: nil
        )
        await cache.commit(
            seed!,
            cache: ConversationCacheLayers(
                [trimmableCache(offset: seedTokens.count)],
                retainedPagedKVSequence: oldRetained,
                discardRetainedPagedKVSequence: { retained, _ in
                    await recorder.record(retained)
                }
            ),
            fullTokens: seedTokens
        )

        let hit = await cache.begin(
            conversationKey: "conv:retained",
            incomingTokens: seedTokens + [64],
            modelID: "model-a",
            kvBits: nil,
            allowRetainedPagedKVHandoff: true
        )
        _ = try await allocator.reattach(oldRetained, conversationKey: "conv:retained", trimToLogicalTokens: 64)
        let newRetained = try await allocator.retain(handle)
        await cache.commit(
            hit!,
            cache: ConversationCacheLayers(
                [trimmableCache(offset: 65)],
                retainedPagedKVSequence: newRetained,
                discardRetainedPagedKVSequence: { retained, _ in
                    await recorder.record(retained)
                }
            ),
            fullTokens: seedTokens + [64]
        )

        let discardCount = await recorder.count()
        XCTAssertEqual(discardCount, 0)
        let reattached = try await allocator.reattach(
            newRetained,
            conversationKey: "conv:retained",
            trimToLogicalTokens: 64
        )
        try await allocator.release(reattached)
    }

    func testRetainedPagedKVRequiresExplicitHandoffOptIn() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let retained = try await retainedSequence(
            allocator: allocator,
            conversationKey: "conv:handoff",
            tokenCount: 64
        )
        let recorder = RetainedDiscardRecorder()
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let seedTokens = int32Range(0..<64)
        let seed = await cache.begin(
            conversationKey: "conv:handoff",
            incomingTokens: seedTokens,
            modelID: "model-a",
            kvBits: nil
        )
        await cache.commit(
            seed!,
            cache: ConversationCacheLayers(
                [trimmableCache(offset: seedTokens.count)],
                retainedPagedKVSequence: retained,
                discardRetainedPagedKVSequence: { retained, key in
                    await recorder.record(retained)
                    try? await allocator.discardRetained(retained, conversationKey: key)
                }
            ),
            fullTokens: seedTokens
        )

        let hit = await cache.begin(
            conversationKey: "conv:handoff",
            incomingTokens: seedTokens + [64],
            modelID: "model-a",
            kvBits: nil
        )

        XCTAssertEqual(hit?.cachedPromptTokens, 0)
        let discardCount = await recorder.count()
        XCTAssertEqual(discardCount, 1)
        await cache.abort(hit!)
        await assertRetainedSequenceDiscarded(retained, allocator: allocator, conversationKey: "conv:handoff")
    }

    func testPurgeHotDiscardsRetainedPagedKVOwner() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let retained = try await retainedSequence(
            allocator: allocator,
            conversationKey: "conv:purge",
            tokenCount: 64
        )
        let recorder = RetainedDiscardRecorder()
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let tokens = int32Range(0..<64)
        let seed = await cache.begin(
            conversationKey: "conv:purge",
            incomingTokens: tokens,
            modelID: "model-a",
            kvBits: nil
        )
        await cache.commit(
            seed!,
            cache: ConversationCacheLayers(
                [trimmableCache(offset: tokens.count)],
                retainedPagedKVSequence: retained,
                discardRetainedPagedKVSequence: { retained, key in
                    await recorder.record(retained)
                    try? await allocator.discardRetained(retained, conversationKey: key)
                }
            ),
            fullTokens: tokens
        )

        let hadHot = await cache.purgeHot(conversationKey: "conv:purge")

        XCTAssertTrue(hadHot)
        let discardCount = await recorder.count()
        XCTAssertEqual(discardCount, 1)
        await assertRetainedSequenceDiscarded(retained, allocator: allocator, conversationKey: "conv:purge")
    }

    func testFencedCommitDiscardsNewRetainedPagedKVOwner() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 16)
        let retained = try await retainedSequence(
            allocator: allocator,
            conversationKey: "conv:fenced",
            tokenCount: 64
        )
        let recorder = RetainedDiscardRecorder()
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let tokens = int32Range(0..<64)
        let lease = await cache.begin(
            conversationKey: "conv:fenced",
            incomingTokens: tokens,
            modelID: "model-a",
            kvBits: nil
        )
        _ = await cache.purgeHot(conversationKey: "conv:fenced")

        await cache.commit(
            lease!,
            cache: ConversationCacheLayers(
                [trimmableCache(offset: tokens.count)],
                retainedPagedKVSequence: retained,
                discardRetainedPagedKVSequence: { retained, key in
                    await recorder.record(retained)
                    try? await allocator.discardRetained(retained, conversationKey: key)
                }
            ),
            fullTokens: tokens
        )

        let discardCount = await recorder.count()
        XCTAssertEqual(discardCount, 1)
        await assertRetainedSequenceDiscarded(retained, allocator: allocator, conversationKey: "conv:fenced")
    }

    func testCommitFencedDuringReplacementDiscardDoesNotPublishOrLeakNewRetainedOwner() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 64)
        let oldRetained = try await retainedSequence(
            allocator: allocator,
            conversationKey: "conv:commit-race",
            tokenCount: 64
        )
        let newRetained = try await retainedSequence(
            allocator: allocator,
            conversationKey: "conv:commit-race",
            tokenCount: 65
        )
        let oldDiscardGate = RetainedDiscardGate()
        let newRecorder = RetainedDiscardRecorder()
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let seedTokens = int32Range(0..<64)
        let seed = await cache.begin(
            conversationKey: "conv:commit-race",
            incomingTokens: seedTokens,
            modelID: "model-a",
            kvBits: nil
        )
        await cache.commit(
            seed!,
            cache: ConversationCacheLayers(
                [trimmableCache(offset: seedTokens.count)],
                retainedPagedKVSequence: oldRetained,
                discardRetainedPagedKVSequence: { retained, key in
                    try? await allocator.discardRetained(retained, conversationKey: key)
                    await oldDiscardGate.pauseUntilReleased()
                }
            ),
            fullTokens: seedTokens
        )

        let staleLease = ConversationCacheLease(
            key: "conv:commit-race",
            keyHash: "commit-race",
            incomingTokens: seedTokens + [64],
            modelID: "model-a",
            kvBits: nil,
            reusableCache: nil,
            cachedPromptTokens: 0,
            lcp: 0,
            trimBy: 0,
            localPurgeStamp: 0,
            globalPurgeStamp: 0
        )
        let commitTask = Task {
            await cache.commit(
                staleLease,
                cache: ConversationCacheLayers(
                    [self.trimmableCache(offset: seedTokens.count + 1)],
                    retainedPagedKVSequence: newRetained,
                    discardRetainedPagedKVSequence: { retained, key in
                        await newRecorder.record(retained)
                        try? await allocator.discardRetained(retained, conversationKey: key)
                    }
                ),
                fullTokens: seedTokens + [64]
            )
        }
        await oldDiscardGate.waitUntilPaused()
        _ = await cache.purgeHot(conversationKey: "conv:commit-race")
        await oldDiscardGate.release()
        await commitTask.value

        let stats = await cache.snapshotStats()
        XCTAssertEqual(stats.entries, 0)
        let newDiscardCount = await newRecorder.count()
        XCTAssertEqual(newDiscardCount, 1)
        await assertRetainedSequenceDiscarded(newRetained, allocator: allocator, conversationKey: "conv:commit-race")
    }

    func testCommitFencedDuringLimitEnforcementSkipsColdPersist() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 32)
        let victimRetained = try await retainedSequence(
            allocator: allocator,
            conversationKey: "conv:victim",
            tokenCount: 64
        )
        let currentRetained = try await retainedSequence(
            allocator: allocator,
            conversationKey: "conv:cold-race",
            tokenCount: 64
        )
        let victimDiscardGate = RetainedDiscardGate()
        let currentRecorder = RetainedDiscardRecorder()
        let coldTier = FakeConversationColdTier()
        let cache = makeConversationCacheForTest(
            config: .init(maxConversations: 1, maxTokens: 200_000, ttlSeconds: 900),
            coldTier: coldTier
        )
        let victimTokens = int32Range(0..<64)
        let victimSeed = await cache.begin(
            conversationKey: "conv:victim",
            incomingTokens: victimTokens,
            modelID: "model-a",
            kvBits: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        await cache.commit(
            victimSeed!,
            cache: ConversationCacheLayers(
                [trimmableCache(offset: victimTokens.count)],
                retainedPagedKVSequence: victimRetained,
                discardRetainedPagedKVSequence: { retained, key in
                    try? await allocator.discardRetained(retained, conversationKey: key)
                    await victimDiscardGate.pauseUntilReleased()
                }
            ),
            fullTokens: victimTokens,
            now: Date(timeIntervalSince1970: 1_000)
        )

        let currentTokens = int32Range(100..<164)
        let currentLease = await cache.begin(
            conversationKey: "conv:cold-race",
            incomingTokens: currentTokens,
            modelID: "model-a",
            kvBits: nil,
            now: Date(timeIntervalSince1970: 1_100),
            cold: coldContext(eligible: true)
        )
        let commitTask = Task {
            await cache.commit(
                currentLease!,
                cache: ConversationCacheLayers(
                    [self.trimmableCache(offset: currentTokens.count)],
                    retainedPagedKVSequence: currentRetained,
                    discardRetainedPagedKVSequence: { retained, key in
                        await currentRecorder.record(retained)
                        try? await allocator.discardRetained(retained, conversationKey: key)
                    }
                ),
                fullTokens: currentTokens,
                now: Date(timeIntervalSince1970: 1_100),
                cold: self.coldContext(eligible: true)
            )
        }
        await victimDiscardGate.waitUntilPaused()
        _ = await cache.purgeHot(conversationKey: "conv:cold-race")
        await victimDiscardGate.release()
        await commitTask.value

        let currentDiscardCount = await currentRecorder.count()
        XCTAssertEqual(currentDiscardCount, 1)
        XCTAssertEqual(coldTier.captureCount, 0)
        XCTAssertEqual(coldTier.enqueueCount, 0)
        await assertRetainedSequenceDiscarded(currentRetained, allocator: allocator, conversationKey: "conv:cold-race")
    }

    private func coldContext(eligible: Bool) -> ConversationColdContext {
        ConversationColdContext(
            eligible: eligible,
            identity: KVIdentityCore(
                requestModel: "model-a",
                servedModelID: "model-a",
                modelSHA256: String(repeating: "b", count: 64),
                catalogRevision: "r",
                tokenizerID: "model-a",
                tokenizerConfigSHA256: String(repeating: "c", count: 64),
                chatTemplateSHA256: String(repeating: "d", count: 64),
                kvBits: nil,
                kvGroupSize: nil,
                kvQuantMode: nil,
                kvQuantPolicy: nil
            )
        )
    }

    private func int32Range(_ range: Range<Int>) -> [Int32] {
        range.map(Int32.init)
    }

    private func retainedSequence(
        allocator: PagedKVBlockAllocator,
        conversationKey: String,
        tokenCount: Int
    ) async throws -> PagedKVRetainedSequence {
        let handle = try await allocator.allocate(
            conversationKey: conversationKey,
            initialCapacityTokens: tokenCount,
            maxLogicalTokens: tokenCount + 16,
            initialTokens: tokenCount
        )
        return try await allocator.retain(handle)
    }

    private func assertRetainedSequenceDiscarded(
        _ retained: PagedKVRetainedSequence,
        allocator: PagedKVBlockAllocator,
        conversationKey: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await allocator.reattach(retained, conversationKey: conversationKey)
            XCTFail("retained sequence was still reattachable", file: file, line: line)
        } catch PagedKVAllocatorError.unknownHandle {
        } catch {
            XCTFail("unexpected retained sequence error: \(error)", file: file, line: line)
        }
    }

    // MARK: - Hybrid (recurrent) checkpoint reuse

    private static let imStart: Int32 = 7
    private static let vocabulary: [Int: String] = [100: "system", 101: "user", 102: "assistant", 103: "us", 104: "er", 10: "\n"]

    private func decodeFake(_ ids: [Int]) -> String {
        ids.map { Self.vocabulary[$0] ?? "x" }.joined()
    }

    private func turn(_ role: Int32, filler: Int) -> [Int32] {
        [Self.imStart, role, 10] + Array(repeating: Int32(1), count: filler)
    }

    func testRecurrentCheckpointPositionsPickScaffoldEndAndLastTurnStart() {
        // system(40) | user(20) | assistant(10) | user(5) | assistant header
        let prompt = turn(100, filler: 40) + turn(101, filler: 20) + turn(102, filler: 10) + turn(101, filler: 5) + [Self.imStart, 102, 10]
        let positions = ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: prompt, imStartTokenID: Self.imStart, hybrid: true, decode: decodeFake)
        XCTAssertEqual(positions, [43, 87])
        XCTAssertEqual(prompt[43], Self.imStart)
        XCTAssertEqual(prompt[87], Self.imStart)
    }

    func testRecurrentCheckpointPositionsDetectUserRoleAcrossTokenSplits() {
        let prompt = turn(100, filler: 40) + [Self.imStart, 103, 104, 10] + Array(repeating: Int32(1), count: 5) + [Self.imStart, 102, 10]
        let positions = ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: prompt, imStartTokenID: Self.imStart, hybrid: true, decode: decodeFake)
        XCTAssertEqual(positions, [43, 52])
    }

    func testRecurrentCheckpointPositionsEmptyWhenInapplicable() {
        let prompt = turn(100, filler: 40) + turn(101, filler: 20) + [Self.imStart, 102, 10]
        XCTAssertEqual(ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: prompt, imStartTokenID: Self.imStart, hybrid: false, decode: decodeFake), [], "non-hybrid")
        XCTAssertEqual(ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: prompt, imStartTokenID: nil, hybrid: true, decode: decodeFake), [], "no <|im_start|> id")
        XCTAssertEqual(ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: Array(repeating: 1, count: 80), imStartTokenID: Self.imStart, hybrid: true, decode: decodeFake), [], "absent")
        let short = turn(100, filler: 5) + turn(101, filler: 5) + [Self.imStart, 102, 10]
        XCTAssertEqual(ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: short, imStartTokenID: Self.imStart, hybrid: true, decode: decodeFake), [], "below lcpThreshold")
        // First user turn IS the last marker (no generation header): one checkpoint.
        let single = turn(100, filler: 40) + turn(101, filler: 5)
        XCTAssertEqual(ConversationCache.recurrentCheckpointPositions(
            promptTokenIds: single, imStartTokenID: Self.imStart, hybrid: true, decode: decodeFake), [43])
    }

    func testSelectRecurrentCheckpointTakesLargestWithinCommonPrefix() {
        let checkpoints = [40, 70, 89].map { RecurrentStateCheckpoint(tokenCount: $0, states: [:]) }
        XCTAssertEqual(ConversationCache.selectRecurrentCheckpoint(checkpoints, lcp: 89)?.tokenCount, 89, "reply-end match")
        XCTAssertEqual(ConversationCache.selectRecurrentCheckpoint(checkpoints, lcp: 75)?.tokenCount, 70, "full-history match")
        XCTAssertEqual(ConversationCache.selectRecurrentCheckpoint(checkpoints, lcp: 70)?.tokenCount, 70)
        XCTAssertEqual(ConversationCache.selectRecurrentCheckpoint(checkpoints, lcp: 69)?.tokenCount, 40, "scaffold-only match")
        XCTAssertNil(ConversationCache.selectRecurrentCheckpoint(checkpoints, lcp: 39))
        XCTAssertNil(ConversationCache.selectRecurrentCheckpoint(
            [RecurrentStateCheckpoint(tokenCount: 20, states: [:])], lcp: 64), "below lcpThreshold")
    }

    private func seedHybridEntry(
        _ cache: ConversationCache, key: String, tokens: [Int32], checkpoints: [Int]
    ) async -> (attention: KVCacheSimple, recurrent: MambaCache) {
        let seed = await cache.begin(conversationKey: key, incomingTokens: tokens, modelID: "hybrid", kvBits: nil)
        let attention = trimmableCache(offset: tokens.count)
        let recurrent = MambaCache()
        let stored = checkpoints.map { RecurrentStateCheckpoint(tokenCount: $0, states: [1: []]) }
        await cache.commit(seed!, cache: ConversationCacheLayers([attention, recurrent], recurrentCheckpoints: stored), fullTokens: tokens)
        return (attention, recurrent)
    }

    func testHybridEntryHitsFullHistoryCheckpoint() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<90)
        let layers = await seedHybridEntry(cache, key: "conv:hybrid", tokens: stored, checkpoints: [40, 70])

        let incoming = int32Range(0..<75) + int32Range(500..<520)
        let hit = await cache.begin(conversationKey: "conv:hybrid", incomingTokens: incoming, modelID: "hybrid", kvBits: nil)
        XCTAssertEqual(hit?.cachedPromptTokens, 70)
        XCTAssertEqual(hit?.lcp, 70)
        XCTAssertEqual(hit?.trimBy, 20)
        XCTAssertEqual(layers.attention.offset, 70, "attention layers trimmed to the checkpoint")
        XCTAssertEqual(hit?.reusableCanonicalPromptTokens, int32Range(0..<70))
        XCTAssertEqual(hit?.reusableCache?.recurrentCheckpoints.map(\.tokenCount), [40, 70])
        await cache.abort(hit!)
    }

    func testHybridEntryScaffoldOnlyMatchHitsFirstCheckpoint() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<90)
        let layers = await seedHybridEntry(cache, key: "conv:hybrid", tokens: stored, checkpoints: [40, 70])

        let incoming = int32Range(0..<50) + int32Range(500..<540)
        let hit = await cache.begin(conversationKey: "conv:hybrid", incomingTokens: incoming, modelID: "hybrid", kvBits: nil)
        XCTAssertEqual(hit?.cachedPromptTokens, 40)
        XCTAssertEqual(hit?.lcp, 40)
        XCTAssertEqual(layers.attention.offset, 40)
        await cache.abort(hit!)
    }

    func testHybridEntryMissesWhenPrefixStopsBeforeEveryCheckpoint() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<90)
        let layers = await seedHybridEntry(cache, key: "conv:hybrid", tokens: stored, checkpoints: [40, 70])

        let incoming = int32Range(0..<36) + int32Range(500..<540)
        let miss = await cache.begin(conversationKey: "conv:hybrid", incomingTokens: incoming, modelID: "hybrid", kvBits: nil)
        XCTAssertEqual(miss?.cachedPromptTokens, 0)
        XCTAssertNil(miss?.reusableCache, "recurrent_checkpoint_diverged is a miss")
        XCTAssertEqual(layers.attention.offset, 90, "a miss trims nothing")
        await cache.abort(miss!)
    }

    func testHybridEntryWithoutCheckpointStaysNotTrimmable() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<90)
        _ = await seedHybridEntry(cache, key: "conv:hybrid", tokens: stored, checkpoints: [])

        let miss = await cache.begin(conversationKey: "conv:hybrid", incomingTokens: stored + [999], modelID: "hybrid", kvBits: nil)
        XCTAssertEqual(miss?.cachedPromptTokens, 0)
        XCTAssertNil(miss?.reusableCache)
        await cache.abort(miss!)
    }

    func testHybridCheckpointHitRestoresRecurrentState() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<90)
        let seed = await cache.begin(conversationKey: "conv:hybrid", incomingTokens: stored, modelID: "hybrid", kvBits: nil)
        let attention = trimmableCache(offset: stored.count)
        let recurrent = MambaCache()
        recurrent.state = [MLXArray([Float(9)]), MLXArray([Float(9)])]
        let checkpointState = [MLXArray([Float(1)]), MLXArray([Float(2)])]
        await cache.commit(
            seed!,
            cache: ConversationCacheLayers([attention, recurrent], recurrentCheckpoints: [
                RecurrentStateCheckpoint(tokenCount: 70, states: [1: checkpointState]),
            ]),
            fullTokens: stored)

        let hit = await cache.begin(conversationKey: "conv:hybrid", incomingTokens: int32Range(0..<80) + [999], modelID: "hybrid", kvBits: nil)
        XCTAssertEqual(hit?.cachedPromptTokens, 70)
        XCTAssertEqual(recurrent.state.count, 2)
        XCTAssertTrue(recurrent.state[0] === checkpointState[0])
        XCTAssertTrue(recurrent.state[1] === checkpointState[1])
        await cache.abort(hit!)
    }

    func testSerialConversationCacheCommitTokensCutToCoveredLength() {
        let canonical = int32Range(0..<90)
        XCTAssertEqual(ModelRuntime.serialConversationCacheCommitTokens(canonicalTokens: canonical, coveredTokenCount: 89), int32Range(0..<89))
        XCTAssertEqual(ModelRuntime.serialConversationCacheCommitTokens(canonicalTokens: canonical, coveredTokenCount: 90), canonical)
        XCTAssertNil(ModelRuntime.serialConversationCacheCommitTokens(canonicalTokens: canonical, coveredTokenCount: 91))
    }

    /// A row stopped early at a serial tool boundary still publishes its prompt
    /// snapshot (prompt tokens only); a cache covering generated tokens does not.
    func testSerialStopTruncationKeepsOnlyPromptSnapshotCommittable() {
        XCTAssertTrue(ModelRuntime.serialConversationCacheCommittable(
            truncatedAtSerialStop: false, promptSnapshot: false, coveredTokenCount: 120, promptTokenCount: 100))
        XCTAssertTrue(ModelRuntime.serialConversationCacheCommittable(
            truncatedAtSerialStop: true, promptSnapshot: true, coveredTokenCount: 98, promptTokenCount: 100))
        XCTAssertTrue(ModelRuntime.serialConversationCacheCommittable(
            truncatedAtSerialStop: true, promptSnapshot: true, coveredTokenCount: 100, promptTokenCount: 100))
        XCTAssertFalse(ModelRuntime.serialConversationCacheCommittable(
            truncatedAtSerialStop: true, promptSnapshot: true, coveredTokenCount: 101, promptTokenCount: 100))
        XCTAssertFalse(ModelRuntime.serialConversationCacheCommittable(
            truncatedAtSerialStop: true, promptSnapshot: false, coveredTokenCount: 90, promptTokenCount: 100))
    }

    /// A batched hybrid first turn commits attention covering all but the last
    /// sampled token, empty recurrent layers and its checkpoints; `begin` must
    /// trim the attention layers exactly onto the largest checkpoint, including
    /// the reply-end checkpoint when the next turn repeats the answer.
    func testBatchedHybridEntryTrimsAttentionOntoCheckpoint() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let canonical = int32Range(0..<90)
        let seed = await cache.begin(conversationKey: "conv:batched", incomingTokens: int32Range(0..<80), modelID: "hybrid", kvBits: nil)
        let attention = trimmableCache(offset: 89)
        let fullTokens = ModelRuntime.serialConversationCacheCommitTokens(canonicalTokens: canonical, coveredTokenCount: 89)!
        await cache.commit(
            seed!,
            cache: ConversationCacheLayers([attention, MambaCache()], recurrentCheckpoints: [40, 70, 89].map {
                RecurrentStateCheckpoint(tokenCount: $0, states: [1: []])
            }),
            fullTokens: fullTokens)

        let hit = await cache.begin(conversationKey: "conv:batched", incomingTokens: int32Range(0..<89) + [999], modelID: "hybrid", kvBits: nil)
        XCTAssertEqual(hit?.cachedPromptTokens, 89)
        XCTAssertEqual(attention.offset, 89)
        await cache.abort(hit!)
    }

    private func seedRetainedHybridEntry(
        _ cache: ConversationCache,
        allocator: PagedKVBlockAllocator,
        recorder: RetainedDiscardRecorder,
        tokens: [Int32],
        checkpoints: [Int]
    ) async throws -> PagedKVRetainedSequence {
        let retained = try await retainedSequence(allocator: allocator, conversationKey: "conv:hybrid", tokenCount: tokens.count)
        let seed = await cache.begin(conversationKey: "conv:hybrid", incomingTokens: tokens, modelID: "hybrid", kvBits: nil)
        await cache.commit(
            seed!,
            cache: ConversationCacheLayers(
                [],
                retainedPagedKVSequence: retained,
                discardRetainedPagedKVSequence: { retained, key in
                    await recorder.record(retained)
                    try? await allocator.discardRetained(retained, conversationKey: key)
                },
                recurrentCheckpoints: checkpoints.map { RecurrentStateCheckpoint(tokenCount: $0, states: [1: []]) }
            ),
            fullTokens: tokens)
        return retained
    }

    /// SPEC-038 AC-26: a retained hybrid entry resumes from the largest
    /// checkpoint inside the shared prefix. The lease carries that checkpoint and
    /// reports it as the cached length, and the trim stays with the scheduler.
    func testRetainedHybridEntryLeasesLargestCheckpointAndLeavesTrimToScheduler() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 32)
        let recorder = RetainedDiscardRecorder()
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let retained = try await seedRetainedHybridEntry(
            cache, allocator: allocator, recorder: recorder, tokens: int32Range(0..<90), checkpoints: [40, 70])

        let hit = await cache.begin(
            conversationKey: "conv:hybrid",
            incomingTokens: int32Range(0..<75) + int32Range(500..<520),
            modelID: "hybrid",
            kvBits: nil,
            allowRetainedPagedKVHandoff: true)

        XCTAssertEqual(hit?.cachedPromptTokens, 70, "the serial checkpoint hit reports the same length")
        XCTAssertEqual(hit?.lcp, 70)
        XCTAssertEqual(hit?.trimBy, 20)
        XCTAssertEqual(hit?.recurrentCheckpoint?.tokenCount, 70)
        XCTAssertEqual(hit?.reusableCache?.retainedPagedKVSequence, retained)
        XCTAssertTrue(ModelRuntime.leaseHasUsableRetainedHandoff(hit!, modelHasRecurrentLayers: true))
        XCTAssertEqual(ModelRuntime.retainedRecurrentCheckpoints(for: hit).map(\.tokenCount), [40, 70])
        let discardsBeforeAbort = await recorder.count()
        XCTAssertEqual(discardsBeforeAbort, 0)
        await cache.abort(hit!)
        await assertRetainedSequenceDiscarded(retained, allocator: allocator, conversationKey: "conv:hybrid")
    }

    func testRetainedHybridEntryMissesWithoutCheckpointInPrefixAndDiscardsOwner() async throws {
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 4, maxPhysicalBlocks: 32)
        let recorder = RetainedDiscardRecorder()
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let retained = try await seedRetainedHybridEntry(
            cache, allocator: allocator, recorder: recorder, tokens: int32Range(0..<90), checkpoints: [40, 70])

        let miss = await cache.begin(
            conversationKey: "conv:hybrid",
            incomingTokens: int32Range(0..<36) + int32Range(500..<540),
            modelID: "hybrid",
            kvBits: nil,
            allowRetainedPagedKVHandoff: true)

        XCTAssertEqual(miss?.cachedPromptTokens, 0, "recurrent_checkpoint_diverged is a miss")
        XCTAssertNil(miss?.reusableCache)
        XCTAssertNil(miss?.recurrentCheckpoint)
        let discards = await recorder.count()
        XCTAssertEqual(discards, 1, "the retained owner is discarded exactly like other retained misses")
        await cache.abort(miss!)
        await assertRetainedSequenceDiscarded(retained, allocator: allocator, conversationKey: "conv:hybrid")
        let freeBlocks = await allocator.freeBlockCount()
        XCTAssertEqual(freeBlocks, 32)
        let next = await cache.begin(
            conversationKey: "conv:hybrid", incomingTokens: int32Range(0..<90), modelID: "hybrid", kvBits: nil)
        XCTAssertNil(next?.reusableCache, "no entry survives the miss")
        await cache.abort(next!)
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

private actor RetainedDiscardRecorder {
    private var retained: [PagedKVRetainedSequence] = []

    func record(_ sequence: PagedKVRetainedSequence) {
        retained.append(sequence)
    }

    func count() -> Int {
        retained.count
    }
}

private actor CacheCompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private actor RetainedDiscardGate {
    private var paused = false
    private var released = false
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { continuation in
            pausedWaiters.append(continuation)
        }
    }

    func pauseUntilReleased() async {
        paused = true
        let waiters = pausedWaiters
        pausedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class FakeConversationColdTier: ConversationColdTier, @unchecked Sendable {
    private let lock = NSLock()
    private let refuseCapture: Bool
    private var captureAttempts = 0
    private var captures: [ConversationColdSnapshot] = []
    private var enqueues: [ConversationColdSnapshot] = []

    init(refuseCapture: Bool = false) {
        self.refuseCapture = refuseCapture
    }

    var captureAttemptCount: Int {
        lock.lock(); defer { lock.unlock() }
        return captureAttempts
    }

    var captureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return captures.count
    }

    var enqueueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return enqueues.count
    }

    func sampledPurgeGeneration(conversationKey: String) async -> Int { 0 }

    func promoteCandidate(conversationKey: String, identity: KVIdentityCore) async -> ColdPromotionCandidate? { nil }

    func finishPromotion(_ candidate: ColdPromotionCandidate, accepted: Bool, rejectionReason: String?) async {}

    func captureSnapshot(
        conversationKey: String,
        layers: ConversationCacheLayers,
        fullTokens: [Int32],
        sampledPurgeGeneration: Int,
        identity: KVIdentityCore,
        nowMillis: Int
    ) -> ConversationColdSnapshot? {
        lock.lock(); defer { lock.unlock() }
        captureAttempts += 1
        guard !refuseCapture else { return nil }
        let snapshot = ConversationColdSnapshot(
            rawKey: conversationKey,
            tokens: fullTokens,
            layers: [],
            identity: Self.writeIdentity,
            sampledPurgeGeneration: sampledPurgeGeneration,
            commitSequence: captures.count + 1,
            createdAtMillis: nowMillis,
            eligibleUntilMillis: nowMillis,
            incarnation: "test"
        )
        captures.append(snapshot)
        return snapshot
    }

    func enqueuePersist(_ snapshot: ConversationColdSnapshot) {
        lock.lock()
        enqueues.append(snapshot)
        lock.unlock()
    }

    func cancelPendingPersist(conversationKey: String) async -> Bool { false }

    func cancelPendingPersists() async {}

    func drainPendingPersists(timeoutSeconds: Int) async {}

    func noteReadIdentityUnavailable(conversationKey: String) async {}

    func noteWriteSkippedIdentityUnavailable(conversationKey: String) async {}

    private static let writeIdentity = KVWriteIdentity(
        requestModel: "model-a",
        servedModelID: "model-a",
        modelSHA256: String(repeating: "b", count: 64),
        catalogRevision: "r",
        tokenizerID: "model-a",
        tokenizerConfigSHA256: String(repeating: "c", count: 64),
        chatTemplateSHA256: String(repeating: "d", count: 64),
        abiEpoch: 1,
        mlxSwiftLMRevision: "x",
        mlxVersion: "y",
        cacheClass: "KVCacheSimple",
        layerCount: 1,
        kvBits: nil,
        kvGroupSize: nil,
        kvQuantMode: nil,
        kvQuantPolicy: nil,
        decodePath: "ordinary",
        keyEpoch: 1
    )
}
