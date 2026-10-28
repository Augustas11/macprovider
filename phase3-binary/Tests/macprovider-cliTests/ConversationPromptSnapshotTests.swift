import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-024 FR-CI2a: extend-only prompt snapshots for families whose caches
/// cannot be rewound (DeepSeek V4 windows and pools, GLM-5-Next sparse and
/// recurrent layers). DeepSeek V4 runs on the CPU device; GLM-5-Next's
/// linear-attention kernels exist only on the GPU.
final class ConversationPromptSnapshotTests: XCTestCase {
    // MARK: - begin() acceptance rules (no model)

    func testSnapshotEntryServesOnlyAnExtendingPrompt() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<64)
        let layers = try await seedSnapshot(cache, key: "conv:snapshot", tokens: stored)

        let extended = stored + int32Range(200..<230)
        let hit = try Self.unwrap(await cache.begin(conversationKey: "conv:snapshot", incomingTokens: extended,
                                                 modelID: "model-a", kvBits: nil))
        XCTAssertTrue(hit.reusableCache === layers)
        XCTAssertEqual(hit.cachedPromptTokens, 64)
        XCTAssertEqual(hit.lcp, 64)
        XCTAssertEqual(hit.trimBy, 0)
        XCTAssertEqual(hit.reusableCanonicalPromptTokens, stored)
        await cache.abort(hit)
    }

    /// SPEC-001-R013: a request cancelled before its entry is inserted
    /// publishes nothing, and its key is free for the next request.
    func testCommitOfACancelledRequestPublishesNothing() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<64)
        let lease = try Self.unwrap(await cache.begin(conversationKey: "conv:cancelled", incomingTokens: stored,
                                                   modelID: "model-a", kvBits: nil))
        let layers = ConversationCacheLayers([RotatingKVCache(maxSize: 8, keep: 0)], promptSnapshot: true)
        await cache.commit(lease, cache: layers, fullTokens: stored, isCancelled: { true })

        let extended = stored + int32Range(200..<230)
        let next = try Self.unwrap(await cache.begin(conversationKey: "conv:cancelled", incomingTokens: extended,
                                                  modelID: "model-a", kvBits: nil))
        XCTAssertNil(next.reusableCache, "the cancelled request's cache was not published")
        await cache.abort(next)
    }

    func testSnapshotEntryMissesWhenThePromptDivergesInsideIt() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<64)
        _ = try await seedSnapshot(cache, key: "conv:diverged", tokens: stored)
        // lcp = 63 >= the reuse threshold, but one stored token is not shared.
        let diverged = int32Range(0..<63) + int32Range(300..<340)
        let miss = try Self.unwrap(await cache.begin(conversationKey: "conv:diverged", incomingTokens: diverged,
                                                  modelID: "model-a", kvBits: nil))
        XCTAssertNil(miss.reusableCache)
        XCTAssertEqual(miss.cachedPromptTokens, 0)
        await cache.abort(miss)
    }

    func testSnapshotEntryMissesWhenNothingIsNew() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<64)
        _ = try await seedSnapshot(cache, key: "conv:same", tokens: stored)
        let miss = try Self.unwrap(await cache.begin(conversationKey: "conv:same", incomingTokens: stored,
                                                  modelID: "model-a", kvBits: nil))
        XCTAssertNil(miss.reusableCache)
        await cache.abort(miss)
    }

    func testSnapshotEntriesCountAgainstTheTokenCap() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 100, ttlSeconds: 900))
        _ = try await seedSnapshot(cache, key: "conv:first", tokens: int32Range(0..<64))
        _ = try await seedSnapshot(cache, key: "conv:second", tokens: int32Range(0..<64))
        let stats = await cache.snapshotStats()
        XCTAssertEqual(stats.entries, 1)
        XCTAssertEqual(stats.tokens, 64)
    }

    /// The same layer classes without the snapshot flag keep every existing
    /// rejection: a rotating window misses, an untrimmable pool misses.
    func testUnflaggedRotatingAndPoolEntriesStillMiss() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<64)
        for (key, layer) in [("conv:rotating", RotatingKVCache(maxSize: 8, keep: 0) as KVCache),
                             ("conv:pool", DeepseekV4PoolCache(ratio: 4) as KVCache)] {
            let seed = await cache.begin(conversationKey: key, incomingTokens: stored, modelID: "model-a", kvBits: nil)
            await cache.commit(seed!, cache: ConversationCacheLayers([layer]), fullTokens: stored)
            let next = await cache.begin(conversationKey: key, incomingTokens: stored + [500, 501],
                                         modelID: "model-a", kvBits: nil)
            XCTAssertNil(next?.reusableCache, key)
            await cache.abort(next!)
        }
    }

    /// An ordinary trimmable entry still trims back to a diverging prompt.
    func testUnflaggedTrimmableEntryStillTrimsOnDivergence() async {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<64)
        let seed = await cache.begin(conversationKey: "conv:simple", incomingTokens: stored, modelID: "model-a", kvBits: nil)
        let layer = KVCacheSimple()
        layer.offset = 64
        await cache.commit(seed!, cache: ConversationCacheLayers([layer]), fullTokens: stored)
        let hit = await cache.begin(conversationKey: "conv:simple", incomingTokens: int32Range(0..<50) + [900, 901],
                                    modelID: "model-a", kvBits: nil)
        XCTAssertEqual(hit?.cachedPromptTokens, 50)
        XCTAssertEqual(hit?.trimBy, 14)
        XCTAssertEqual(layer.offset, 50)
        await cache.abort(hit!)
    }

    // MARK: - Snapshot position

    func testQwen35SnapshotPolicyRequiresTheLoadedDenseIdentityAndWrapper() throws {
        try Self.requireMetal()
        let models = try Self.tinyQwen35Models()
        for step in [128, 512, 1024] {
            XCTAssertEqual(ModelRuntime.conversationPromptSnapshotPolicy(
                model: models.dense, tokenizer: NoMarkerTokenizer(), prefillStepSize: step,
                modelID: "qwen/qwen3.5-27b"), .referencePlanBoundary(step: step))
        }
        let excludedIDs: [String?] = [nil, "qwen/qwen3.6-27b", "qwen/qwen3.5-35b-a3b"]
        for id in excludedIDs {
            XCTAssertNil(ModelRuntime.conversationPromptSnapshotPolicy(
                model: models.dense, tokenizer: NoMarkerTokenizer(), modelID: id))
        }
        let excludedModels: [any LanguageModel] = [models.text, models.moe]
        for model in excludedModels {
            XCTAssertNil(ModelRuntime.qwen35SerialPromptSnapshotStepSize(
                model: model, modelID: "qwen/qwen3.5-27b", prefillStepSize: 512))
        }
        for model in try Self.tinyLFMModels() {
            XCTAssertNil(ModelRuntime.qwen35SerialPromptSnapshotStepSize(
                model: model, modelID: "qwen/qwen3.5-27b", prefillStepSize: 512))
        }
        XCTAssertNil(ModelRuntime.lfmSerialReferencePrefillStepSize(model: models.dense, prefillStepSize: 512),
                     "Qwen must keep its legacy multi-token tail")
    }

    func testQwen35PositiveSnapshotHitKeepsTheNoKeyLegacyTail() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let seedPrompt = int32Range(0..<993)
        let boundary = try XCTUnwrap(ModelRuntime.conversationPromptSnapshotTokenCount(
            promptTokenIds: seedPrompt, policy: .referencePlanBoundary(step: 512)))
        XCTAssertEqual(boundary, 512, "the role checkpoint at 986 must not split a legacy chunk")
        _ = try await seedSnapshot(cache, key: "conv:qwen-legacy", tokens: Array(seedPrompt.prefix(boundary)))
        let extensionPrompt = int32Range(0..<989) + int32Range(2000..<2027)
        let lease = try Self.unwrap(await cache.begin(
            conversationKey: "conv:qwen-legacy", incomingTokens: extensionPrompt, modelID: "model-a", kvBits: nil))
        XCTAssertNotNil(lease.reusableCache)
        XCTAssertEqual(lease.cachedPromptTokens, 512)
        var coldChunks: [Range<Int>] = []
        var warmChunks: [Range<Int>] = []
        let coldCursor = try ModelRuntime.cancellableLocalPrefill(
            tokenCount: extensionPrompt.count, from: 0, stepSize: 512, isCancelled: { false }
        ) { coldChunks.append($0) }
        let warmCursor = try ModelRuntime.cancellableLocalPrefill(
            tokenCount: extensionPrompt.count, from: lease.lcp, stepSize: 512, isCancelled: { false }
        ) { warmChunks.append($0) }
        XCTAssertEqual(coldChunks, [0..<512])
        XCTAssertTrue(warmChunks.isEmpty)
        XCTAssertEqual(coldCursor, warmCursor)
        XCTAssertEqual(extensionPrompt.count - warmCursor, 504,
                       "both iterators receive the original 504-token tail, not 503 + 1")
        await cache.abort(lease)
    }

    func testQwen35SnapshotsSkipRolePrefillAndDoNotPrefillWithoutAKey() async throws {
        try Self.requireMetal()
        let model = try Self.tinyQwen35Models().dense
        let context = ModelContext(configuration: .init(id: "qwen/qwen3.5-27b"), model: model,
                                   processor: FixtureProcessor(), tokenizer: NoMarkerTokenizer())
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        var prompt = Array(repeating: Int32(1), count: 1016)
        prompt[986] = 0 // NoMarkerTokenizer's role marker.
        let lease = try Self.unwrap(await cache.begin(
            conversationKey: "conv:qwen-no-role-prefill", incomingTokens: prompt, modelID: "qwen/qwen3.5-27b", kvBits: nil))
        let layers: [KVCache] = [MambaCache()]
        let recurrent = try ModelRuntime.prefillRecurrentCheckpoints(
            lease: lease, cache: layers, promptTokenIds: prompt, context: context,
            prefillStepSize: 512, modelID: "qwen/qwen3.5-27b", isCancelled: { true })
        XCTAssertTrue(recurrent.checkpoints.isEmpty)
        XCTAssertNil(recurrent.resumeAt)
        let noKey = try ModelRuntime.prefillPromptSnapshot(
            lease: nil, cache: layers, promptTokenIds: prompt, start: 0, context: context,
            prefillStepSize: 512, modelID: "qwen/qwen3.5-27b", isCancelled: { true })
        XCTAssertFalse(noKey.applies)
        XCTAssertNil(noKey.resumeAt)
        XCTAssertTrue(layers[0].state.isEmpty)
        await cache.abort(lease)
    }

    func testLFMPoliciesUseTheConfiguredReferenceGridWithoutRoleMarkers() throws {
        try Self.requireMetal()
        for model in try Self.tinyLFMModels() {
            for step in [128, 512, 1024] {
                XCTAssertEqual(ModelRuntime.lfmSerialReferencePrefillStepSize(model: model, prefillStepSize: step), step)
                let policy = ModelRuntime.conversationPromptSnapshotPolicy(
                    model: model, tokenizer: NoMarkerTokenizer(), prefillStepSize: step)
                XCTAssertEqual(policy, .referencePlanBoundary(step: step))
                XCTAssertEqual(ModelRuntime.conversationPromptSnapshotTokenCount(
                    promptTokenIds: Array(repeating: 1, count: 1070), policy: policy), step * (1069 / step))
            }
        }
    }

    func testLFMReferencePrefillReservesOneTokenAtShortAndLongPromptLengths() throws {
        for step in [128, 512, 1024] {
            for count in [1, 10, step, step + 1, 1034, 1070, 8202] {
                var chunks: [Range<Int>] = []
                let cursor = try ModelRuntime.cancellableLocalPrefill(
                    tokenCount: count, from: 0, stepSize: step, referenceStepSize: step,
                    isCancelled: { false }
                ) { chunks.append($0) }
                XCTAssertEqual(cursor, count - 1)
                XCTAssertTrue(chunks.allSatisfy { $0.count <= step })
                XCTAssertEqual(chunks.flatMap { Array($0) }, Array(0..<(count - 1)))
                if count == 1034, step == 512 {
                    XCTAssertEqual(chunks, [0..<512, 512..<1024, 1024..<1033])
                }
            }
        }
    }

    func testLFMPositiveSnapshotHitPreservesTheColdReferenceChunkPlan() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let firstPrompt = int32Range(0..<1052)
        // The assistant marker at 1048 must not split the reference grid.
        let snapshotCount = try XCTUnwrap(ModelRuntime.conversationPromptSnapshotTokenCount(
            promptTokenIds: firstPrompt, policy: .referencePlanBoundary(step: 512)))
        XCTAssertEqual(snapshotCount, 1024)
        _ = try await seedSnapshot(cache, key: "conv:lfm-grid", tokens: Array(firstPrompt.prefix(snapshotCount)))
        let secondPrompt = int32Range(0..<1051) + int32Range(2000..<2019)
        let lease = try Self.unwrap(await cache.begin(
            conversationKey: "conv:lfm-grid", incomingTokens: secondPrompt, modelID: "model-a", kvBits: nil))
        XCTAssertEqual(lease.cachedPromptTokens, 1024)
        XCTAssertNotNil(lease.reusableCache)
        var cold: [Range<Int>] = []
        var resumed: [Range<Int>] = []
        let coldCursor = try ModelRuntime.cancellableLocalPrefill(
            tokenCount: secondPrompt.count, from: 0, stepSize: 512, referenceStepSize: 512,
            isCancelled: { false }
        ) { cold.append($0) }
        let resumedCursor = try ModelRuntime.cancellableLocalPrefill(
            tokenCount: secondPrompt.count, from: lease.lcp, stepSize: 512, referenceStepSize: 512,
            isCancelled: { false }
        ) { resumed.append($0) }
        XCTAssertEqual(cold, [0..<512, 512..<1024, 1024..<1069])
        XCTAssertEqual(resumed, Array(cold.dropFirst(2)))
        XCTAssertEqual(coldCursor, resumedCursor)
        await cache.abort(lease)
    }

    func testRecurrentCheckpointPrefillCarriesPrimaryWrapperStateIntoDecode() async throws {
        try Self.requireMetal()
        let conversations = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        var prompt = Array(repeating: Int32(1), count: 1070)
        prompt[1048] = 0
        let lease = try Self.unwrap(await conversations.begin(
            conversationKey: "conv:state-only-wrapper", incomingTokens: prompt, modelID: "wrapper", kvBits: nil))
        let model = CheckpointStateOnlyModel()
        let context = ModelContext(configuration: .init(id: "wrapper"), model: model,
                                   processor: FixtureProcessor(), tokenizer: NoMarkerTokenizer())
        let cache: [KVCache] = [MambaCache()]
        let result = try ModelRuntime.prefillRecurrentCheckpoints(
            lease: lease, cache: cache, promptTokenIds: prompt, context: context, prefillStepSize: 512)
        XCTAssertEqual(result.resumeAt, 1048)
        XCTAssertEqual(result.checkpoints.map(\.tokenCount), [1048])
        XCTAssertEqual(model.widths, [512, 512, 24])
        XCTAssertEqual(model.incomingPositions, [nil, 512, 1024])
        XCTAssertEqual(result.state?[CheckpointStateOnlyModel.positionKey], 1048)

        var iterator = try TokenIterator(
            input: LMInput(tokens: MLXArray(Array(prompt[1048...]))), model: model, cache: cache,
            state: result.state, parameters: GenerateParameters(maxTokens: 2, temperature: 0))
        XCTAssertNotNil(iterator.next())
        XCTAssertNotNil(iterator.next())
        XCTAssertEqual(model.widths, [512, 512, 24, 22, 1, 1])
        XCTAssertEqual(model.incomingPositions, [nil, 512, 1024, 1048, 1070, 1071])
        await conversations.abort(lease)
    }

    func testQwen35VLMTextOnlyRestoreSeedsZeroRotaryAnchorWithoutBuyerIdentity() throws {
        try Self.requireMetal()
        let model = try Self.tinyQwen35VLM()
        let models = try Self.tinyQwen35Models()
        let key = LMOutput.Key<MLXArray>("qwen35.ropeDeltas")
        let state = ModelRuntime.serialTextPrefillInitialState(
            model: model, containsNonTextMessageContentPart: false)
        let delta = try XCTUnwrap(state?[key])
        XCTAssertEqual(delta.shape, [1], "one rotary anchor for the single text sequence")
        XCTAssertEqual(delta.dtype, .int32)
        XCTAssertEqual(delta.item(Int32.self), 0)
        XCTAssertNil(ModelRuntime.serialTextPrefillInitialState(
            model: model, containsNonTextMessageContentPart: true))
        let unrelatedModels: [any LanguageModel] = [models.text, models.dense, models.moe, CheckpointStateOnlyModel()]
        for unrelated in unrelatedModels {
            XCTAssertNil(ModelRuntime.serialTextPrefillInitialState(
                model: unrelated, containsNonTextMessageContentPart: false))
        }
    }

    func testRealQwen35VLMCheckpointChunksAndRestoredWarmCacheCarryRotaryAnchor() async throws {
        try Self.requireMetal()
        try await Device.withDefaultDevice(.gpu) {
            let model = try Self.tinyQwen35VLM()
            let conversations = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
            var prompt = Array(repeating: Int32(1), count: 70)
            prompt[64] = 0
            let lease = try Self.unwrap(await conversations.begin(
                conversationKey: "conv:real-vlm-wrapper", incomingTokens: prompt, modelID: "local-artifact", kvBits: nil))
            let context = ModelContext(configuration: .init(id: "local-artifact"), model: model,
                                       processor: FixtureProcessor(), tokenizer: NoMarkerTokenizer())
            let cache = try model.newCache(parameters: nil)
            let state = ModelRuntime.serialTextPrefillInitialState(
                model: model, containsNonTextMessageContentPart: false)
            let checkpoint = try ModelRuntime.prefillRecurrentCheckpoints(
                lease: lease, cache: cache, promptTokenIds: prompt, context: context,
                prefillStepSize: 32, state: state)
            XCTAssertEqual(checkpoint.resumeAt, 64)
            XCTAssertEqual(checkpoint.checkpoints.map(\.tokenCount), [64])
            XCTAssertEqual(cache.last?.offset, 64)
            let key = LMOutput.Key<MLXArray>("qwen35.ropeDeltas")
            XCTAssertEqual(try XCTUnwrap(checkpoint.state?[key]).item(Int32.self), 0)

            // Restore the same KV without retaining the wrapper's per-call state.
            // The real VLM prepare must reject nil, and accept the text-only anchor.
            let restored = cache.map { $0.copy() }
            eval(restored)
            let tail = LMInput(tokens: MLXArray(Array(prompt[64...])))
            XCTAssertThrowsError(try model.prepare(tail, cache: restored, state: nil, prefill: .init()))
            let restoredState = ModelRuntime.serialTextPrefillInitialState(
                model: model, containsNonTextMessageContentPart: false)
            guard case .logits(let resumed) = try model.prepare(
                tail, cache: restored, state: restoredState, prefill: .init()),
                  case .logits(let carried) = try model.prepare(
                tail, cache: cache, state: checkpoint.state, prefill: .init()) else {
                return XCTFail("the VLM wrapper must return prepared logits")
            }
            XCTAssertTrue((resumed.logits .== carried.logits).all().item(Bool.self))
            XCTAssertEqual(restored.last?.offset, prompt.count)
            XCTAssertEqual(try XCTUnwrap(resumed.state?[key]).item(Int32.self), 0)
            await conversations.abort(lease)
        }
    }

    func testLFMPromptSnapshotsBypassRecurrentRoleBoundaryPrefill() async throws {
        try Self.requireMetal()
        for model in try Self.tinyLFMModels() {
            let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
            var prompt = Array(repeating: Int32(1), count: 1070)
            prompt[1048] = 0 // NoMarkerTokenizer maps <|im_start|> to 0.
            let lease = try Self.unwrap(await cache.begin(
                conversationKey: "conv:lfm-no-role-prefill", incomingTokens: prompt, modelID: "lfm", kvBits: nil))
            let context = ModelContext(configuration: .init(id: "lfm"), model: model,
                                       processor: FixtureProcessor(), tokenizer: NoMarkerTokenizer())
            let recurrent = MambaCache()
            // Without the LFM guard, the role checkpoint would enter a forward
            // (and throw this cancellation) before the grid snapshot is taken.
            let result = try ModelRuntime.prefillRecurrentCheckpoints(
                lease: lease, cache: [recurrent], promptTokenIds: prompt,
                context: context, prefillStepSize: 512, isCancelled: { true })
            XCTAssertTrue(result.checkpoints.isEmpty)
            XCTAssertNil(result.resumeAt)
            XCTAssertTrue(recurrent.state.isEmpty)
            await cache.abort(lease)
        }
    }

    func testReferencePlanBoundaryIsTheLastWholeStepBeforeTheFinalToken() {
        let policy = ModelRuntime.ConversationPromptSnapshotPolicy.referencePlanBoundary(step: 2048)
        func count(_ n: Int) -> Int? {
            ModelRuntime.conversationPromptSnapshotTokenCount(promptTokenIds: Array(repeating: 1, count: n), policy: policy)
        }
        XCTAssertNil(count(1))
        XCTAssertNil(count(2048), "the only boundary is 0")
        XCTAssertEqual(count(2049), 2048)
        XCTAssertEqual(count(4096), 2048)
        XCTAssertEqual(count(4097), 4096)
        XCTAssertEqual(count(28_500), 26_624)
    }

    func testLastRoleMarkerIsTheGenerationPromptStart() {
        let policy = ModelRuntime.ConversationPromptSnapshotPolicy.lastRoleMarker(tokenIDs: [60, 61, 62])
        let prompt: [Int32] = [60] + Array(repeating: 1, count: 40) + [61] + Array(repeating: 2, count: 9) + [61, 5]
        XCTAssertEqual(ModelRuntime.conversationPromptSnapshotTokenCount(promptTokenIds: prompt, policy: policy), 51)
        XCTAssertNil(ModelRuntime.conversationPromptSnapshotTokenCount(
            promptTokenIds: [60, 1, 2, 61, 5], policy: policy), "below the reuse threshold")
        XCTAssertNil(ModelRuntime.conversationPromptSnapshotTokenCount(
            promptTokenIds: Array(repeating: 1, count: 100), policy: policy), "no marker")
        XCTAssertNil(ModelRuntime.conversationPromptSnapshotTokenCount(promptTokenIds: prompt, policy: nil))
    }

    /// GLM-5-Next CB rows publish no prompt snapshot; DeepSeek V4 CB rows do.
    func testContinuousBatchRowsKeepOnlyTheReferencePlanSnapshot() {
        XCTAssertEqual(ModelRuntime.continuousBatchPromptSnapshotPolicy(.referencePlanBoundary(step: 2048)),
                       .referencePlanBoundary(step: 2048))
        XCTAssertNil(ModelRuntime.continuousBatchPromptSnapshotPolicy(.lastRoleMarker(tokenIDs: [60, 61])))
        XCTAssertNil(ModelRuntime.continuousBatchPromptSnapshotPolicy(nil))
    }

    /// SPEC-024-R005: a GLM-5-Next CB row snapshots only under the AC-26
    /// grant, so without it no later hit is fenced off CB.
    func testGLM5NextCBRowsSnapshotOnlyUnderTheCachedTurnsGrant() {
        let glm = ModelRuntime.ConversationPromptSnapshotPolicy.lastRoleMarker(tokenIDs: [60, 61], resumeTokenID: 61)
        XCTAssertNil(ModelRuntime.continuousBatchPromptSnapshotPolicy(glm, cachedTurnsAttachable: false))
        XCTAssertEqual(ModelRuntime.continuousBatchPromptSnapshotPolicy(glm, cachedTurnsAttachable: true),
                       .resumeMarker(tokenID: 61))
        XCTAssertNil(ModelRuntime.continuousBatchPromptSnapshotPolicy(.lastRoleMarker(tokenIDs: [60, 61]),
                                                                     cachedTurnsAttachable: true),
                     "no round-tripping <|assistant|>, no CB snapshot")
        XCTAssertEqual(ModelRuntime.continuousBatchPromptSnapshotPolicy(.referencePlanBoundary(step: 2048),
                                                                       cachedTurnsAttachable: true),
                       .referencePlanBoundary(step: 2048))
        XCTAssertNil(ModelRuntime.continuousBatchPromptSnapshotPolicy(nil, cachedTurnsAttachable: true))
    }

    /// SPEC-024-R005: a GLM-5-Next CB row snapshots at its last
    /// `<|assistant|>` and ends a prefill chunk at every `<|assistant|>` at or
    /// above the reuse threshold. Every snapshot an earlier turn took sits on
    /// a later turn's boundaries, so a cold prefill of the later prompt and
    /// one resumed at that snapshot run the same chunks.
    func testResumeBoundariesCoverEveryEarlierTurnsSnapshot() {
        let policy = ModelRuntime.ConversationPromptSnapshotPolicy.resumeMarker(tokenID: 61)
        func count(_ prompt: [Int32]) -> Int? {
            ModelRuntime.conversationPromptSnapshotTokenCount(promptTokenIds: prompt, policy: policy)
        }
        func boundaries(_ prompt: [Int32]) -> [Int] {
            ModelRuntime.continuousBatchPromptResumeBoundaries(promptTokenIds: prompt, policy: policy)
        }
        let system: [Int32] = [63] + Array(repeating: 1, count: 20)
        let early: [Int32] = system + [60, 2, 61, 3, 60, 4]          // an assistant marker below 32
        var history = early + Array(repeating: 5, count: 30) + [60, 6]
        var prompts: [[Int32]] = []
        for turn in 0 ..< 3 {
            prompts.append(history + [61, 5])
            history += [61] + Array(repeating: Int32(7 + turn), count: 9) + [62, 8, 60, 9]
        }
        let snapshots = prompts.map(count)
        XCTAssertEqual(snapshots, [prompts[0].count - 2, prompts[1].count - 2, prompts[2].count - 2])
        for (index, prompt) in prompts.enumerated() {
            XCTAssertEqual(boundaries(prompt), snapshots[...index].compactMap { $0 },
                           "turn \(index): every earlier snapshot and its own, nothing else")
            XCTAssertEqual(boundaries(prompt).last, count(prompt))
        }
        XCTAssertFalse(boundaries(prompts[2]).contains(23), "an <|assistant|> below the reuse threshold")
        // A prompt whose last role marker is not <|assistant|> snapshots at its
        // last <|assistant|>, which is still one of its boundaries.
        let noGeneration = prompts[1] + [60, 3]
        XCTAssertEqual(count(noGeneration), boundaries(noGeneration).last)
        XCTAssertEqual(ModelRuntime.continuousBatchPromptResumeBoundaries(
            promptTokenIds: prompts[2], policy: .lastRoleMarker(tokenIDs: [60, 61, 62], resumeTokenID: 61)), [])
    }

    /// SPEC-024-R005: a CB lease resumes a snapshot only when another CB row
    /// took it on the resume-boundary plan and its length is one of the
    /// incoming prompt's resume boundaries; otherwise the cold and resumed
    /// chunk plans would differ, so it is a miss. A serial snapshot, even on
    /// a boundary, ran another plan.
    func testResumeBoundaryLeaseMissesASnapshotOffTheIncomingPromptsBoundaries() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<64)
        func seed(_ key: String, plan: Bool = true) async throws -> ConversationCacheLayers {
            let lease = try Self.unwrap(await cache.begin(conversationKey: key, incomingTokens: stored,
                                                       modelID: "model-a", kvBits: nil))
            let layers = ConversationCacheLayers([RotatingKVCache(maxSize: 8, keep: 0)], promptSnapshot: true,
                                                 resumeBoundaryPlan: plan)
            await cache.commit(lease, cache: layers, fullTokens: stored)
            return layers
        }
        let incoming = stored + [61] + int32Range(200..<230)
        let layers = try await seed("conv:on")
        let hit = try Self.unwrap(await cache.begin(conversationKey: "conv:on", incomingTokens: incoming,
                                                    modelID: "model-a", kvBits: nil,
                                                    promptSnapshotResumeBoundaries: [64, 94]))
        XCTAssertTrue(hit.reusableCache === layers)
        XCTAssertEqual(hit.cachedPromptTokens, 64)
        await cache.abort(hit)

        _ = try await seed("conv:off")
        let miss = try Self.unwrap(await cache.begin(conversationKey: "conv:off", incomingTokens: incoming,
                                                     modelID: "model-a", kvBits: nil,
                                                     promptSnapshotResumeBoundaries: [94]))
        XCTAssertNil(miss.reusableCache)
        XCTAssertEqual(miss.cachedPromptTokens, 0)
        await cache.abort(miss)

        _ = try await seed("conv:serial", plan: false)
        let serialMiss = try Self.unwrap(await cache.begin(conversationKey: "conv:serial", incomingTokens: incoming,
                                                           modelID: "model-a", kvBits: nil,
                                                           promptSnapshotResumeBoundaries: [64, 94]))
        XCTAssertNil(serialMiss.reusableCache, "a serial snapshot never resumes a CB row")
        await cache.abort(serialMiss)
        let serialLayers = try await seed("conv:serial-path", plan: false)
        let serialHit = try Self.unwrap(await cache.begin(conversationKey: "conv:serial-path", incomingTokens: incoming,
                                                          modelID: "model-a", kvBits: nil))
        XCTAssertTrue(serialHit.reusableCache === serialLayers, "the serial path still reuses it")
        await cache.abort(serialHit)
        XCTAssertFalse(ConversationCacheLayers([KVCacheSimple()], resumeBoundaryPlan: true).resumeBoundaryPlan,
                       "only a prompt snapshot carries the plan mark")
    }

    /// SPEC-024-R005 / SPEC-048 MTP-9: a native-MTP lease reuses a snapshot
    /// only with MTP head state at its boundary whose recorded token is the
    /// incoming prompt's token there; anything else is a miss, never a
    /// reselection. An ordinary lease ignores the head state.
    func testNativeLeaseReusesASnapshotOnlyWithMatchingHeadState() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<64)
        let marker: Int32 = 61
        let extended = stored + [marker] + int32Range(200..<230)
        let headState = NativeMTPDrafterPrefixSnapshot(cache: [KVCacheSimple()], nextPosition: 64,
                                                       foldedNextToken: Int(marker))

        func seed(_ key: String, drafter: NativeMTPDrafterPrefixSnapshot?) async throws -> ConversationCacheLayers {
            let lease = try Self.unwrap(await cache.begin(conversationKey: key, incomingTokens: stored,
                                                       modelID: "model-a", kvBits: nil))
            let layers = ConversationCacheLayers([RotatingKVCache(maxSize: 8, keep: 0)], promptSnapshot: true,
                                                 nativeMTPDrafter: drafter)
            await cache.commit(lease, cache: layers, fullTokens: stored)
            return layers
        }
        func begin(_ key: String, _ tokens: [Int32], native: Bool) async throws -> ConversationCacheLease {
            try Self.unwrap(await cache.begin(conversationKey: key, incomingTokens: tokens, modelID: "model-a",
                                              kvBits: nil, requireNativeMTPDrafterSnapshot: native))
        }

        let withHead = try await seed("conv:head", drafter: headState)
        let hit = try await begin("conv:head", extended, native: true)
        XCTAssertTrue(hit.reusableCache === withHead)
        XCTAssertEqual(hit.cachedPromptTokens, 64)
        XCTAssertEqual(hit.reusableCache?.nativeMTPDrafter?.nextPosition, 64)
        await cache.abort(hit)

        _ = try await seed("conv:other-token", drafter: headState)
        let otherToken = stored + [Int32(62)] + int32Range(200..<230)
        let tokenMiss = try await begin("conv:other-token", otherToken, native: true)
        XCTAssertNil(tokenMiss.reusableCache)
        XCTAssertEqual(tokenMiss.cachedPromptTokens, 0)
        await cache.abort(tokenMiss)

        _ = try await seed("conv:no-head", drafter: nil)
        let headMiss = try await begin("conv:no-head", extended, native: true)
        XCTAssertNil(headMiss.reusableCache)
        await cache.abort(headMiss)

        let ordinaryLayers = try await seed("conv:ordinary", drafter: nil)
        let ordinary = try await begin("conv:ordinary", extended, native: false)
        XCTAssertTrue(ordinary.reusableCache === ordinaryLayers)
        await cache.abort(ordinary)

        // Head state never rides on a non-snapshot entry.
        XCTAssertNil(ConversationCacheLayers([KVCacheSimple()], nativeMTPDrafter: headState).nativeMTPDrafter)
    }

    func testGLM5NextSnapshotPolicyNeedsRoundTrippingRoleTokens() throws {
        try Self.requireMetal()
        try Device.withDefaultDevice(.gpu) {
            let tokenizer = MarkerTokenizer()
            let glm = try Self.tinyGLM()
            XCTAssertEqual(ModelRuntime.conversationPromptSnapshotPolicy(model: glm, tokenizer: tokenizer),
                           .lastRoleMarker(tokenIDs: Set(MarkerTokenizer.markers.values.map(Int32.init)),
                                           resumeTokenID: 61))
            XCTAssertNil(ModelRuntime.conversationPromptSnapshotPolicy(model: glm, tokenizer: NoMarkerTokenizer()),
                         "a tokenizer without the role tokens gets no policy")
        }
    }

    func testGLMSerialGridPolicyDoesNotAlterCBOrOtherFamilyPlans() throws {
        try Self.requireMetal()
        try Device.withDefaultDevice(.gpu) {
            let glm = try Self.tinyGLM()
            for step in [128, 512, 1024] {
                XCTAssertEqual(ModelRuntime.serialConversationPromptSnapshotPolicy(
                    model: glm, tokenizer: NoMarkerTokenizer(), prefillStepSize: step),
                    .referencePlanBoundary(step: step))
            }
            XCTAssertNil(ModelRuntime.lfmSerialReferencePrefillStepSize(model: glm, prefillStepSize: 512),
                         "GLM keeps the keyless final multi-token forward")
            let cbPolicy = ModelRuntime.conversationPromptSnapshotPolicy(model: glm, tokenizer: MarkerTokenizer())
            XCTAssertEqual(cbPolicy, .lastRoleMarker(
                tokenIDs: Set(MarkerTokenizer.markers.values.map(Int32.init)), resumeTokenID: 61))
            XCTAssertEqual(ModelRuntime.continuousBatchPromptSnapshotPolicy(cbPolicy, cachedTurnsAttachable: true),
                           .resumeMarker(tokenID: 61))
            let qwen = try Self.tinyQwen35Models()
            var otherModels: [any LanguageModel] = [qwen.text, qwen.dense, qwen.moe]
            otherModels += try Self.tinyLFMModels()
            for model in otherModels {
                XCTAssertNil(ModelRuntime.glm5NextSerialSnapshotStepSize(model: model, prefillStepSize: 512))
                XCTAssertEqual(ModelRuntime.serialConversationPromptSnapshotPolicy(
                    model: model, tokenizer: MarkerTokenizer(), modelID: "qwen/qwen3.5-27b"),
                    ModelRuntime.conversationPromptSnapshotPolicy(
                        model: model, tokenizer: MarkerTokenizer(), modelID: "qwen/qwen3.5-27b"))
            }
        }
    }

    func testGLMSerialSnapshotGridPreservesColdForwardShapesAndPositiveReuse() async throws {
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        for (seedCount, nextCount, expectedHit) in [(985, 1000, 512), (1048, 1060, 1024),
                                                   (985, 1126, 512), (1024, 1126, 512)] {
            let key = "conv:glm-grid-\(seedCount)-\(nextCount)"
            let seed = int32Range(0..<seedCount)
            let snapshotCount = try XCTUnwrap(ModelRuntime.conversationPromptSnapshotTokenCount(
                promptTokenIds: seed, policy: .referencePlanBoundary(step: 512)))
            XCTAssertEqual(snapshotCount, expectedHit)
            _ = try await seedSnapshot(cache, key: key, tokens: Array(seed.prefix(snapshotCount)))
            let prompt = int32Range(0..<nextCount)
            let lease = try Self.unwrap(await cache.begin(
                conversationKey: key, incomingTokens: prompt, modelID: "model-a", kvBits: nil))
            XCTAssertEqual(lease.cachedPromptTokens, expectedHit)
            var cold: [Range<Int>] = []
            var warm: [Range<Int>] = []
            let coldCursor = try ModelRuntime.cancellableLocalPrefill(
                tokenCount: nextCount, from: 0, stepSize: 512, isCancelled: { false }
            ) { cold.append($0) }
            let warmCursor = try ModelRuntime.cancellableLocalPrefill(
                tokenCount: nextCount, from: lease.lcp, stepSize: 512, isCancelled: { false }
            ) { warm.append($0) }
            let prefix = stride(from: 0, to: snapshotCount, by: 512).map { $0..<($0 + 512) }
            XCTAssertEqual(prefix + warm, cold)
            XCTAssertEqual(coldCursor, warmCursor)
            XCTAssertEqual(prompt.count - warmCursor, nextCount % 512 == 0 ? 512 : nextCount % 512)
            await cache.abort(lease)
        }
        XCTAssertNil(ModelRuntime.conversationPromptSnapshotTokenCount(
            promptTokenIds: int32Range(0..<512), policy: .referencePlanBoundary(step: 512)),
            "an exact first stride stays the unchanged 512-token iterator tail")
    }

    func testGLMSerialRejectsCBAndOffGridSnapshotsBeforeInstallingLayers() throws {
        try Self.requireMetal()
        try Device.withDefaultDevice(.gpu) {
            let glm = try Self.tinyGLM()
            func lease(tokens: Int, cbPlan: Bool) -> ConversationCacheLease {
                ConversationCacheLease(
                    key: "conv:glm-plan", keyHash: "private-key-hash", incomingTokens: int32Range(0..<1126),
                    modelID: "glm", kvBits: nil,
                    reusableCache: ConversationCacheLayers([MambaCache()], promptSnapshot: true,
                                                           resumeBoundaryPlan: cbPlan),
                    cachedPromptTokens: tokens, lcp: tokens, trimBy: 0,
                    sampledPurgeGeneration: 7, localPurgeStamp: 8, globalPurgeStamp: 9,
                    reusableCanonicalPromptTokens: int32Range(0..<tokens))
            }
            for original in [lease(tokens: 983, cbPlan: false), lease(tokens: 1046, cbPlan: false),
                             lease(tokens: 512, cbPlan: true)] {
                let miss = try Self.unwrap(ModelRuntime.serialPromptSnapshotLease(
                    original, model: glm, prefillStepSize: 512))
                XCTAssertNil(miss.reusableCache)
                XCTAssertEqual(miss.cachedPromptTokens, 0)
                XCTAssertEqual(miss.lcp, 0)
                XCTAssertNil(miss.reusableCanonicalPromptTokens)
                XCTAssertEqual(miss.key, original.key)
                XCTAssertEqual(miss.incomingTokens, original.incomingTokens)
                XCTAssertEqual(miss.sampledPurgeGeneration, 7)
                XCTAssertEqual(miss.localPurgeStamp, 8)
                XCTAssertEqual(miss.globalPurgeStamp, 9)
            }
            let serial = lease(tokens: 512, cbPlan: false)
            XCTAssertTrue(ModelRuntime.serialPromptSnapshotLease(serial, model: glm, prefillStepSize: 512) === serial)
            let qwen = try Self.tinyQwen35Models().dense
            let unrelated = lease(tokens: 983, cbPlan: true)
            XCTAssertTrue(ModelRuntime.serialPromptSnapshotLease(unrelated, model: qwen, prefillStepSize: 512) === unrelated)
            XCTAssertNil(ModelRuntime.serialPromptSnapshotLease(nil, model: glm, prefillStepSize: 512))
        }
    }

    func testGLMSerialGridSkipsRoleCheckpointPrefill() async throws {
        try Self.requireMetal()
        try await Device.withDefaultDevice(.gpu) {
            let glm = try Self.tinyGLM()
            let context = ModelContext(configuration: .init(id: "glm"), model: glm,
                                       processor: FixtureProcessor(), tokenizer: MarkerTokenizer())
            let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
            let prompt = Array(repeating: Int32(1), count: 1048)
            let lease = try Self.unwrap(await cache.begin(
                conversationKey: "conv:glm-no-role-checkpoint", incomingTokens: prompt, modelID: "glm", kvBits: nil))
            let layers = try glm.newCache(parameters: nil)
            let initialLayers = layers.map { $0.copy() }
            let recurrent = try ModelRuntime.prefillRecurrentCheckpoints(
                lease: lease, cache: layers, promptTokenIds: prompt, context: context,
                prefillStepSize: 512, isCancelled: { true })
            XCTAssertTrue(recurrent.checkpoints.isEmpty)
            XCTAssertNil(recurrent.resumeAt)
            Self.assertStatesEqual(layers, initialLayers, "suppressed GLM role checkpoint preserves initial cache state")
            await cache.abort(lease)
        }
    }

    // MARK: - DeepSeek V4 tiny fixture: resumed == fresh, bit for bit

    func testDeepseekV4ResumedTurnMatchesFreshPrefillExactlyOnCPU() async throws {
        try Self.requireMetal()
        try await Device.withDefaultDevice(.cpu) {
            let model = try Self.tinyDeepseekV4()
            XCTAssertNil(ModelRuntime.glm5NextSerialSnapshotStepSize(model: model, prefillStepSize: 512))
            XCTAssertEqual(ModelRuntime.serialConversationPromptSnapshotPolicy(
                model: model, tokenizer: NoMarkerTokenizer()),
                ModelRuntime.conversationPromptSnapshotPolicy(model: model, tokenizer: NoMarkerTokenizer()))
            let context = ModelContext(configuration: .init(id: "deepseek/deepseek-v4-flash"), model: model,
                                       processor: FixtureProcessor(), tokenizer: NoMarkerTokenizer())
            let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
            let key = "conv:dsv4-two-turn"
            let turn1 = (0..<2100).map { Int32(($0 * 7 + 3) % 128) }

            // Turn 1, keyed miss: snapshot at 2048, generate, commit the snapshot.
            let lease1 = try Self.unwrap(await cache.begin(conversationKey: key, incomingTokens: turn1,
                                                        modelID: "dsv4", kvBits: nil))
            XCTAssertNil(lease1.reusableCache)
            let work1 = try model.newCache(parameters: nil)
            let snap1 = try ModelRuntime.prefillPromptSnapshot(lease: lease1, cache: work1, promptTokenIds: turn1,
                                                           start: 0, context: context, prefillStepSize: 512)
            XCTAssertTrue(snap1.applies)
            XCTAssertEqual(snap1.tokenCount, 2048)
            XCTAssertEqual(snap1.resumeAt, 2048)
            let reply = try Self.greedyReference(model, input: Array(turn1[2048...]), cache: work1, count: 6)
            await cache.commit(lease1, cache: ConversationCacheLayers(try XCTUnwrap(snap1.layers), promptSnapshot: true),
                               fullTokens: Array(turn1.prefix(2048)))

            // Turn 2 extends turn 1 past the next reference boundary.
            let replyTokens: [Int32] = reply.map(Int32.init)
            let followUp: [Int32] = (0..<2200).map { Int32(($0 * 11 + 5) % 128) }
            let turn2: [Int32] = turn1 + replyTokens + followUp
            let lease2 = try Self.unwrap(await cache.begin(conversationKey: key, incomingTokens: turn2,
                                                        modelID: "dsv4", kvBits: nil))
            XCTAssertEqual(lease2.cachedPromptTokens, 2048)
            let resumedCache = try XCTUnwrap(lease2.reusableCache).layers
            let snap2 = try ModelRuntime.prefillPromptSnapshot(lease: lease2, cache: resumedCache, promptTokenIds: turn2,
                                                           start: lease2.lcp, context: context, prefillStepSize: 512)
            XCTAssertEqual(snap2.tokenCount, 4096)
            XCTAssertEqual(snap2.resumeAt, 4096)

            // A fresh reference-plan prefill to the same boundary holds the same state.
            let freshCache = try model.newCache(parameters: nil)
            for range in [0..<2048, 2048..<4096] {
                _ = model(MLXArray(Array(turn2[range])).reshaped([1, range.count]), cache: freshCache)
                eval(freshCache)
            }
            Self.assertStatesEqual(try XCTUnwrap(snap2.layers), freshCache, "turn-2 snapshot vs fresh")

            let resumed = try Self.greedyReference(model, input: Array(turn2[4096...]), cache: resumedCache, count: 8)
            let fresh = try Self.greedyReference(model, input: turn2, cache: try model.newCache(parameters: nil), count: 8)
            XCTAssertEqual(resumed, fresh)
            await cache.abort(lease2)
        }
    }

    /// SPEC-001 FR-26 / SPEC-001-R013: a cancel during the multi-chunk
    /// prompt-snapshot prefill (the DeepSeek V4 keyed path, which prefills
    /// almost the whole prompt here) stops within one chunk, returns no
    /// snapshot, and the aborted lease commits nothing.
    func testDeepseekV4PromptSnapshotStopsWithinOneChunkOnCancelAndCommitsNothing() async throws {
        try Self.requireMetal()
        try await Device.withDefaultDevice(.cpu) {
            let model = try Self.tinyDeepseekV4()
            let context = ModelContext(configuration: .init(id: "deepseek/deepseek-v4-flash"), model: model,
                                       processor: FixtureProcessor(), tokenizer: NoMarkerTokenizer())
            let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
            let key = "conv:dsv4-cancel"
            // Snapshot target 6144: three 2048-token reference chunks.
            let prompt = (0..<6200).map { Int32(($0 * 7 + 3) % 128) }
            let lease = try Self.unwrap(await cache.begin(conversationKey: key, incomingTokens: prompt,
                                                       modelID: "dsv4", kvBits: nil))
            let work = try model.newCache(parameters: nil)
            var checks = 0
            XCTAssertThrowsError(try ModelRuntime.prefillPromptSnapshot(
                lease: lease, cache: work, promptTokenIds: prompt, start: 0, context: context,
                prefillStepSize: 512, isCancelled: { checks += 1; return checks > 1 }
            )) { error in
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(checks, 2, "one chunk ran; the check before the second stopped it")

            // The serial path's catch aborts the lease: the key is free and holds no entry.
            await cache.abort(lease)
            let next = try Self.unwrap(await cache.begin(conversationKey: key, incomingTokens: prompt,
                                                      modelID: "dsv4", kvBits: nil))
            XCTAssertNil(next.reusableCache)
            XCTAssertEqual(next.cachedPromptTokens, 0)
            await cache.abort(next)
        }
    }

    /// The caveat the boundary exists for: resuming off the reference plan
    /// changes the ratio-4 overlap pools.
    func testDeepseekV4OffPlanResumeChangesThePools() throws {
        try Self.requireMetal()
        try Device.withDefaultDevice(.cpu) {
            let model = try Self.tinyDeepseekV4()
            let prompt = (0..<2200).map { Int32(($0 * 7 + 3) % 128) }
            let onPlan = try model.newCache(parameters: nil)
            _ = model(MLXArray(Array(prompt[0..<2048])).reshaped([1, 2048]), cache: onPlan)
            _ = model(MLXArray(Array(prompt[2048..<2199])).reshaped([1, 151]), cache: onPlan)
            let offPlan = try model.newCache(parameters: nil)
            _ = model(MLXArray(Array(prompt[0..<2047])).reshaped([1, 2047]), cache: offPlan)
            _ = model(MLXArray(Array(prompt[2047..<2199])).reshaped([1, 152]), cache: offPlan)
            eval(onPlan + offPlan)
            let differs = zip(onPlan, offPlan).contains { lhs, rhs in
                zip(lhs.state, rhs.state).contains { !Self.equal($0, $1) }
            }
            XCTAssertTrue(differs)
        }
    }

    // MARK: - GLM-5-Next tiny model: resumed == fresh greedy tokens

    /// GLM-5-Next's linear-attention kernels are GPU-only, so this runs on the
    /// explicitly scoped Metal device of a tiny randomly initialised model.
    func testGLM5NextResumedTurnMatchesFreshPrefill() async throws {
        // Also probe beside the test bundle's own executable, where MLX looks.
        let testBundle = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(
                bundleURL: testBundle.resourceURL, executableURL: testBundle.executableURL)
        else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        try await Device.withDefaultDevice(.gpu) {
            let model = try Self.tinyGLM()
            let tokenizer = MarkerTokenizer()
            let context = ModelContext(configuration: .init(id: "zai-org/glm-5.3-flash"), model: model,
                                       processor: FixtureProcessor(), tokenizer: tokenizer)
            let (system, user, assistant, observation) = (Int32(63), Int32(60), Int32(61), Int32(62))
            let think: Int32 = 5
            let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
            let key = "conv:glm-two-turn"
            let systemText: [Int32] = (0..<1026).map { Int32(($0 * 7 + 3) % 56) }
            let userText: [Int32] = (0..<20).map { Int32(($0 * 5 + 1) % 56) }
            var history: [Int32] = [system]
            history += systemText
            history.append(user)
            history += userText
            let turn1 = history + [assistant, think]

            let lease1 = try Self.unwrap(await cache.begin(conversationKey: key, incomingTokens: turn1,
                                                        modelID: "glm", kvBits: nil))
            let work1 = try model.newCache(parameters: nil)
            let snap1 = try ModelRuntime.prefillPromptSnapshot(lease: lease1, cache: work1, promptTokenIds: turn1,
                                                           start: 0, context: context, prefillStepSize: 512)
            XCTAssertEqual(snap1.tokenCount, 1024)
            let reply = try Self.greedy(model, input: Array(turn1[snap1.tokenCount...]), cache: work1, count: 4)
            await cache.commit(lease1, cache: ConversationCacheLayers(try XCTUnwrap(snap1.layers), promptSnapshot: true),
                               fullTokens: Array(turn1.prefix(snap1.tokenCount)))

            // Turn 2: the template re-renders the assistant turn after the marker,
            // then a tool result and a new generation prompt.
            let replyText: [Int32] = reply.map { Int32($0 % 56) }
            let toolText: [Int32] = (0..<30).map { Int32(($0 * 3 + 2) % 56) }
            var turn2: [Int32] = history
            turn2.append(assistant)
            turn2 += replyText
            turn2.append(observation)
            turn2 += toolText
            turn2 += [assistant, think]
            let lease2 = try Self.unwrap(await cache.begin(conversationKey: key, incomingTokens: turn2,
                                                        modelID: "glm", kvBits: nil))
            XCTAssertEqual(lease2.cachedPromptTokens, 1024)
            let resumedCache = try XCTUnwrap(lease2.reusableCache).layers
            let snap2 = try ModelRuntime.prefillPromptSnapshot(lease: lease2, cache: resumedCache, promptTokenIds: turn2,
                                                           start: lease2.lcp, context: context, prefillStepSize: 512)
            XCTAssertEqual(snap2.tokenCount, 1024)
            let resumed = try Self.greedy(model, input: Array(turn2[snap2.tokenCount...]), cache: resumedCache, count: 8)

            // Fresh keyed and keyless turns keep identical whole-stride forwards.
            let keyedFreshCache = try model.newCache(parameters: nil)
            let keyedFresh = try ModelRuntime.prefillPromptSnapshot(lease: lease2, cache: keyedFreshCache, promptTokenIds: turn2,
                                                                start: 0, context: context, prefillStepSize: 512)
            let keyed = try Self.greedy(model, input: Array(turn2[keyedFresh.tokenCount...]), cache: keyedFreshCache, count: 8)
            let plain = try Self.greedy(model, input: turn2, cache: try model.newCache(parameters: nil), count: 8)
            XCTAssertEqual(resumed, keyed)
            XCTAssertEqual(resumed, plain)
            await cache.abort(lease2)
        }
    }

    // MARK: - Helpers

    private func seedSnapshot(_ cache: ConversationCache, key: String, tokens: [Int32]) async throws -> ConversationCacheLayers {
        let seed = try Self.unwrap(await cache.begin(conversationKey: key, incomingTokens: tokens, modelID: "model-a", kvBits: nil))
        let window = RotatingKVCache(maxSize: 8, keep: 0)
        let pool = DeepseekV4PoolCache(ratio: 4)
        XCTAssertFalse(pool.isTrimmable)
        let layers = ConversationCacheLayers([window, CacheList(RotatingKVCache(maxSize: 8, keep: 0), pool)],
                                             promptSnapshot: true)
        await cache.commit(seed, cache: layers, fullTokens: tokens)
        return layers
    }

    private func int32Range(_ range: Range<Int>) -> [Int32] { range.map(Int32.init) }

    private static func tinyQwen35Models() throws -> (
        text: Qwen35TextModel, dense: Qwen35Model, moe: Qwen35MoEModel
    ) {
        let data = Data("""
        {"model_type":"qwen3_5","hidden_size":16,"num_hidden_layers":2,
         "intermediate_size":32,"num_attention_heads":2,"num_key_value_heads":1,
         "head_dim":8,"linear_num_value_heads":2,"linear_num_key_heads":1,
         "linear_key_head_dim":32,"linear_value_head_dim":32,"linear_conv_kernel_dim":2,
         "rms_norm_eps":0.000001,"vocab_size":32,"max_position_embeddings":4096,
         "tie_word_embeddings":false,"attention_bias":false,"full_attention_interval":2,
         "rope_parameters":{"type":"default","rope_theta":100000.0,"partial_rotary_factor":0.25}}
        """.utf8)
        let decoder = JSONDecoder()
        let wrapper = try decoder.decode(MLXLLM.Qwen35Configuration.self, from: data)
        return (Qwen35TextModel(try decoder.decode(Qwen35TextConfiguration.self, from: data)),
                Qwen35Model(wrapper), Qwen35MoEModel(wrapper))
    }

    /// Same dimensions and rotary sections as upstream Qwen35ContinuationTests,
    /// with two layers so one recurrent and one full-attention layer are exercised.
    private static func tinyQwen35VLM() throws -> MLXVLM.Qwen35 {
        let data = Data("""
        {"model_type":"qwen3_5_vl","image_token_id":500,"video_token_id":501,
         "vision_start_token_id":502,"vision_end_token_id":503,"vocab_size":512,
         "text_config":{"model_type":"qwen3_5","hidden_size":64,"num_hidden_layers":2,
          "intermediate_size":128,"num_attention_heads":4,"num_key_value_heads":2,
          "head_dim":32,"vocab_size":512,"full_attention_interval":2,
          "linear_num_value_heads":4,"linear_num_key_heads":2,"linear_key_head_dim":32,
          "linear_value_head_dim":32,"linear_conv_kernel_dim":4,"max_position_embeddings":4096,
          "rope_parameters":{"type":"default","mrope_section":[8,4,4],
                             "rope_theta":100000.0,"partial_rotary_factor":1.0}},
         "vision_config":{"model_type":"qwen3_vl","depth":2,"hidden_size":32,
          "intermediate_size":64,"out_hidden_size":64,"num_heads":2,"patch_size":16,
          "spatial_merge_size":2,"temporal_patch_size":2,"num_position_embeddings":64}}
        """.utf8)
        let config = try JSONDecoder().decode(MLXVLM.Qwen35Configuration.self, from: data)
        return withRandomState(MLXRandom.RandomState(seed: 1)) { MLXVLM.Qwen35(config) }
    }

    private static func tinyLFMModels() throws -> [any LanguageModel] {
        let data = Data("""
        {"model_type":"lfm2_moe","vocab_size":128,"hidden_size":16,
         "intermediate_size":32,"moe_intermediate_size":16,"num_hidden_layers":2,
         "num_experts":2,"num_experts_per_tok":1,"norm_topk_prob":true,
         "num_attention_heads":2,"num_key_value_heads":1,"max_position_embeddings":2048,
         "use_expert_bias":false,"num_dense_layers":1,"norm_eps":0.00001,
         "conv_bias":false,"conv_L_cache":3,"full_attn_idxs":[1],
         "block_multiple_of":16,"block_auto_adjust_ff_dim":false}
        """.utf8)
        return [
            LFM2Model(try JSONDecoder().decode(LFM2Configuration.self, from: data)),
            LFM2MoEModel(try JSONDecoder().decode(LFM2MoEConfiguration.self, from: data)),
        ]
    }

    /// `XCTUnwrap` takes an autoclosure, which cannot hold an `await`.
    /// MLX loads the default metallib even for the CPU device.
    private static func requireMetal() throws {
        let tests = Bundle(for: ConversationPromptSnapshotTests.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(bundleURL: tests.resourceURL, executableURL: tests.executableURL)
        else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    private static func unwrap(_ lease: ConversationCacheLease?) throws -> ConversationCacheLease {
        try XCTUnwrap(lease)
    }

    /// Greedy tokens through the production iterator parameters.
    private static func greedy(_ model: any LanguageModel, input: [Int32], cache: [KVCache], count: Int) throws -> [Int] {
        let parameters = ModelRuntime.serveIteratorParameters(
            GenerateParameters(maxTokens: count, temperature: 0), forceSimpleKV: true, reusedCache: true, cache: cache)
        var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(input)), model: model, cache: cache,
                                         parameters: parameters)
        var tokens: [Int] = []
        while tokens.count < count, let token = iterator.next() { tokens.append(token) }
        return tokens
    }

    /// DeepSeek V4 greedy tokens without `TokenIterator`: the model's own
    /// `prepare` (the reference chunk plan the iterator runs) and one-token
    /// argmax decode. A resumed DeepSeek cache cannot enter the iterator in a
    /// debug build: its compressor pools keep offset 0 while the windows are
    /// at the prompt length, which trips KVCacheStorage's debug-only
    /// offset-alignment assertion (release builds infer the minimum).
    private static func greedyReference(_ model: DeepseekV4Model, input: [Int32], cache: [KVCache], count: Int) throws -> [Int] {
        guard case .tokens(let rest) = try model.prepare(
            LMInput(tokens: MLXArray(input)), cache: cache, state: nil, prefill: .init())
        else { throw XCTSkip("unexpected prepare result") }
        var current = rest.tokens.reshaped([1, -1])
        var tokens: [Int] = []
        while tokens.count < count {
            let logits = model(current, cache: cache)
            let next = argMax(logits[0, -1], axis: -1).item(Int.self)
            eval(cache)
            tokens.append(next)
            current = MLXArray([Int32(next)]).reshaped([1, 1])
        }
        return tokens
    }

    private static func equal(_ lhs: MLXArray, _ rhs: MLXArray) -> Bool {
        lhs.shape == rhs.shape && lhs.dtype == rhs.dtype && (lhs.size == 0 || all(lhs .== rhs).item(Bool.self))
    }

    private static func assertStatesEqual(_ lhs: [KVCache], _ rhs: [KVCache], _ label: String) {
        XCTAssertEqual(lhs.count, rhs.count, label)
        for (index, (a, b)) in zip(lhs, rhs).enumerated() {
            XCTAssertEqual(a.metaState, b.metaState, "\(label) layer \(index) meta")
            let (sa, sb) = (a.state, b.state)
            XCTAssertEqual(sa.count, sb.count, "\(label) layer \(index)")
            for (slot, (x, y)) in zip(sa, sb).enumerated() {
                XCTAssertTrue(equal(x, y), "\(label) layer \(index) slot \(slot): \(x.shape) vs \(y.shape)")
            }
        }
    }

    private static func tinyDeepseekV4() throws -> DeepseekV4Model {
        guard let path = ProcessInfo.processInfo.environment["MACPROVIDER_DSV4_TINY_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("MACPROVIDER_DSV4_TINY_FIXTURE is not set")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Fail before loading weights if an operator accidentally names a real model.
        guard object["hidden_size"] as? Int == 64, object["num_hidden_layers"] as? Int == 4,
              object["vocab_size"] as? Int == 128, object["sliding_window"] as? Int == 8 else {
            throw ContinuousBatchSchedulerError.unsupported("deepseek_v4_tiny_fixture_required")
        }
        let config = try JSONDecoder().decode(DeepseekV4Configuration.self, from: data)
        let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
        let model = DeepseekV4Model(config)
        try loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
        model.train(false)
        return model
    }

    /// The randomly initialised GLM-5-Next text model of
    /// `GLM5NextSerialBaselineTests` (linear-attention and sparse layers).
    /// Shared with `GLM5NextCBPromptSnapshotTests`.
    static func tinyGLM() throws -> GLM5NextTextModel {
        GLM5NextTextModel(try tinyGLMConfiguration()).withTinyNoise()
    }

    static func tinyGLMConfiguration() throws -> GLM5NextConfiguration {
        let json = """
        {
            "model_type": "glm5_next_text", "vocab_size": 64, "hidden_size": 64,
            "intermediate_size": 96, "moe_intermediate_size": 32,
            "num_hidden_layers": 6, "num_nextn_predict_layers": 1,
            "num_attention_heads": 2, "num_key_value_heads": 2,
            "n_shared_experts": 1, "n_routed_experts": 4, "num_experts_per_tok": 2,
            "routed_scaling_factor": 2.5, "n_group": 1, "topk_group": 1,
            "norm_topk_prob": true, "scoring_func": "sigmoid", "topk_method": "noaux_tc",
            "kv_lora_rank": 32, "q_lora_rank": 32, "qk_rope_head_dim": 0,
            "qk_nope_head_dim": 32, "v_head_dim": 32, "mla_use_nope": true,
            "rms_norm_eps": 1e-5, "tie_word_embeddings": false, "attention_bias": false,
            "index_topk": 8, "index_head_dim": 16, "index_n_heads": 2,
            "index_kpool": 4, "index_kpool_always_select_tail": true,
            "layer_types": ["linear_attention", "linear_attention", "linear_attention",
                "deepseek_sparse_attention", "linear_attention", "deepseek_sparse_attention"],
            "mlp_layer_types": ["dense", "dense", "dense", "sparse", "sparse", "sparse"],
            "indexer_types": ["full", "full", "full", "full", "full", "shared"],
            "swiglu_limit": 10.0,
            "linear_attn_config": {"num_heads": 2, "head_dim": 32,
                "short_conv_kernel_size": 4, "gate_lower_bound": -5.0},
            "hc_mult": 4, "hc_eps": 1e-6, "hc_sinkhorn_iters": 20,
            "first_k_dense_replace": 3
        }
        """
        let configuration = try JSONDecoder().decode(GLM5NextConfiguration.self, from: Data(json.utf8))
        try configuration.validateModelConfiguration()
        return configuration
    }
}

private extension GLM5NextTextModel {
    func withTinyNoise() -> GLM5NextTextModel {
        let noisy: [(String, MLXArray)] = withRandomState(MLXRandom.RandomState(seed: 7)) {
            parameters().flattened().map { key, value in
                (key, (MLXRandom.normal(value.shape) * 0.02).asType(value.dtype))
            }
        }
        update(parameters: ModuleParameters.unflattened(noisy))
        eval(self)
        return self
    }
}

private struct FixtureProcessor: UserInputProcessor {
    func prepare(input: UserInput) throws -> LMInput {
        LMInput(text: .init(tokens: MLXArray([Int32]()).reshaped([1, 0])))
    }
}

/// GLM-5-Next role tokens at fixed ids; every other string is unknown.
private struct MarkerTokenizer: MLXLMCommon.Tokenizer {
    static let markers: [String: Int] = ["<|user|>": 60, "<|assistant|>": 61, "<|observation|>": 62, "<|system|>": 63]
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map(String.init).joined(separator: " ") }
    func convertTokenToId(_ token: String) -> Int? { Self.markers[token] }
    func convertIdToToken(_ id: Int) -> String? { Self.markers.first { $0.value == id }?.key }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

/// Maps every string to a token id, the way an unknown-token fallback would.
private struct NoMarkerTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map(String.init).joined(separator: " ") }
    func convertTokenToId(_ token: String) -> Int? { 0 }
    func convertIdToToken(_ id: Int) -> String? { "<unk>" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

/// Implements only the primary text/state interface: the legacy array overload
/// must never be selected, and every forward records the state it received.
private final class CheckpointStateOnlyModel: Module, LanguageModel, KVCacheDimensionProvider {
    static let positionKey = LMOutput.Key<Int>("checkpoint.position")
    let kvHeads = [1]
    var widths: [Int] = []
    var incomingPositions: [Int?] = []

    func prepare(
        _ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters
    ) throws -> PrepareResult { .tokens(input.text) }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        let width = input.tokens.dim(1)
        let incoming = state?[Self.positionKey]
        widths.append(width)
        incomingPositions.append(incoming)
        let position = (incoming ?? 0) + width
        for case let layer as MambaCache in cache ?? [] {
            layer[0] = MLXArray(Int32(position))
            layer[1] = MLXArray(Int32(position))
        }
        var next = LMOutput.State()
        next[Self.positionKey] = position
        return LMOutput(logits: MLXArray.zeros([1, width, 4]), state: next)
    }
}
