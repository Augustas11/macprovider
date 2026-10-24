import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
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
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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

    func testSnapshotEntryMissesWhenThePromptDivergesInsideIt() async throws {
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let stored = int32Range(0..<64)
        _ = try await seedSnapshot(cache, key: "conv:same", tokens: stored)
        let miss = try Self.unwrap(await cache.begin(conversationKey: "conv:same", incomingTokens: stored,
                                                  modelID: "model-a", kvBits: nil))
        XCTAssertNil(miss.reusableCache)
        await cache.abort(miss)
    }

    func testSnapshotEntriesCountAgainstTheTokenCap() async throws {
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 100, ttlSeconds: 900))
        _ = try await seedSnapshot(cache, key: "conv:first", tokens: int32Range(0..<64))
        _ = try await seedSnapshot(cache, key: "conv:second", tokens: int32Range(0..<64))
        let stats = await cache.snapshotStats()
        XCTAssertEqual(stats.entries, 1)
        XCTAssertEqual(stats.tokens, 64)
    }

    /// The same layer classes without the snapshot flag keep every existing
    /// rejection: a rotating window misses, an untrimmable pool misses.
    func testUnflaggedRotatingAndPoolEntriesStillMiss() async {
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
        let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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

    func testGLM5NextSnapshotPolicyNeedsRoundTrippingRoleTokens() throws {
        try Self.requireMetal()
        let tokenizer = MarkerTokenizer()
        let glm = try Self.tinyGLM()
        XCTAssertEqual(ModelRuntime.conversationPromptSnapshotPolicy(model: glm, tokenizer: tokenizer),
                       .lastRoleMarker(tokenIDs: Set(MarkerTokenizer.markers.values.map(Int32.init))))
        XCTAssertNil(ModelRuntime.conversationPromptSnapshotPolicy(model: glm, tokenizer: NoMarkerTokenizer()),
                     "a tokenizer without the role tokens gets no policy")
    }

    // MARK: - DeepSeek V4 tiny fixture: resumed == fresh, bit for bit

    func testDeepseekV4ResumedTurnMatchesFreshPrefillExactlyOnCPU() async throws {
        try Self.requireMetal()
        try await Device.withDefaultDevice(.cpu) {
            let model = try Self.tinyDeepseekV4()
            let context = ModelContext(configuration: .init(id: "deepseek/deepseek-v4-flash"), model: model,
                                       processor: FixtureProcessor(), tokenizer: NoMarkerTokenizer())
            let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
            let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
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
    /// default (Metal) device of a tiny randomly initialised model.
    func testGLM5NextResumedTurnMatchesFreshPrefill() async throws {
        // Also probe beside the test bundle's own executable, where MLX looks.
        let testBundle = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(
                bundleURL: testBundle.resourceURL, executableURL: testBundle.executableURL)
        else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        do {
            let model = try Self.tinyGLM()
            let tokenizer = MarkerTokenizer()
            let context = ModelContext(configuration: .init(id: "zai-org/glm-5.3-flash"), model: model,
                                       processor: FixtureProcessor(), tokenizer: tokenizer)
            let (system, user, assistant, observation) = (Int32(63), Int32(60), Int32(61), Int32(62))
            let think: Int32 = 5
            let cache = ConversationCache(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
            let key = "conv:glm-two-turn"
            let systemText: [Int32] = (0..<40).map { Int32(($0 * 7 + 3) % 56) }
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
            XCTAssertEqual(snap1.tokenCount, history.count)
            let reply = try Self.greedy(model, input: Array(turn1[history.count...]), cache: work1, count: 4)
            await cache.commit(lease1, cache: ConversationCacheLayers(try XCTUnwrap(snap1.layers), promptSnapshot: true),
                               fullTokens: Array(turn1.prefix(history.count)))

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
            XCTAssertEqual(lease2.cachedPromptTokens, history.count)
            let resumedCache = try XCTUnwrap(lease2.reusableCache).layers
            let snap2 = try ModelRuntime.prefillPromptSnapshot(lease: lease2, cache: resumedCache, promptTokenIds: turn2,
                                                           start: lease2.lcp, context: context, prefillStepSize: 512)
            XCTAssertEqual(snap2.tokenCount, turn2.count - 2)
            let resumed = try Self.greedy(model, input: Array(turn2[snap2.tokenCount...]), cache: resumedCache, count: 8)

            // Fresh keyed turn 2 (snapshot to its own marker) and a plain full prefill.
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
    private static func tinyGLM() throws -> GLM5NextTextModel {
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
        let model = GLM5NextTextModel(configuration)
        let noisy: [(String, MLXArray)] = withRandomState(MLXRandom.RandomState(seed: 7)) {
            model.parameters().flattened().map { key, value in
                (key, (MLXRandom.normal(value.shape) * 0.02).asType(value.dtype))
            }
        }
        model.update(parameters: ModuleParameters.unflattened(noisy))
        eval(model)
        return model
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
