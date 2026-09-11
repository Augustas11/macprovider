import Foundation
import MLXLMCommon
@testable import MacProviderCore
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

    func testSerialFallbackAbortRestoresNonRetainedCacheForBillingParity() async {
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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

    func testTTLSweepDoesNotRemoveEntryCommittedDuringRetainedDiscard() async throws {
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 60))
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
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
        let cache = ConversationCache(
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
    private var captures: [ConversationColdSnapshot] = []
    private var enqueues: [ConversationColdSnapshot] = []

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
        lock.lock()
        captures.append(snapshot)
        lock.unlock()
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
