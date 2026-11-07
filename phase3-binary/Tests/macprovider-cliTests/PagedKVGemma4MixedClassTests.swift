import Foundation
import MLX
import MLXLLM
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-039 v0.1.31 `gemma4` mixed cache class: the exact
/// `google/gemma-4-12b-it` identity, its `text_config` sliding-window /
/// full-attention layout, and batched-vs-alone token exactness on a tiny
/// random-weight Gemma 4 model whose rows cross the sliding window.
final class PagedKVGemma4MixedClassTests: XCTestCase {
    private static let config = PagedKVConfig(enabled: true, blockSizeTokens: 32, maxPhysicalBlocks: 64)
    private static let modelSHA = String(repeating: "a", count: 64)
    private static let modelID = "google/gemma-4-12b-it"

    /// The admitted 12B layout: five sliding layers then one full layer,
    /// eight times, with a 1024-token window.
    private static let layerTypes12B: [String] = (0 ..< 48).map {
        ($0 + 1).isMultiple(of: 6) ? "full_attention" : "sliding_attention"
    }

    private static func gemma4Config(
        layerTypes: [String]? = layerTypes12B,
        layers: Int = 48,
        slidingWindow: Int? = 1024,
        kvShared: Int? = 0,
        architectures: [String] = ["Gemma4UnifiedForConditionalGeneration"],
        modelType: String = "gemma4_unified",
        textModelType: String = "gemma4_unified_text"
    ) -> [String: Any] {
        var text: [String: Any] = [
            "model_type": textModelType,
            "num_hidden_layers": layers,
            "enable_moe_block": false,
        ]
        if let layerTypes { text["layer_types"] = layerTypes }
        if let slidingWindow { text["sliding_window"] = slidingWindow }
        if let kvShared { text["num_kv_shared_layers"] = kvShared }
        return ["model_type": modelType, "architectures": architectures, "text_config": text]
    }

    private static func capabilities(
        _ object: [String: Any], modelID: String = modelID
    ) throws -> PagedKVRuntimeModelCapabilities {
        ModelRuntime.pagedKVModelCapabilities(
            modelID: modelID, configJSONData: try JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func expectedKinds(_ types: [String], window: Int) -> [PagedKVSharedForwardBackend.CacheKind] {
        types.map { $0 == "full_attention" ? .pagedAttention : .slidingWindow(windowTokens: window) }
    }

    func testGemma412BMixedClassRequiresExactIdentityAndLayout() throws {
        XCTAssertTrue(PagedKVAttachGate.recognizedModelFamilies.contains("gemma4"))
        let admitted = try Self.capabilities(Self.gemma4Config())
        XCTAssertEqual(admitted.modelFamily, "gemma4")
        XCTAssertFalse(admitted.requiresMoEDispatch)
        XCTAssertTrue(admitted.hybridDecoderArchitectureVerified)
        XCTAssertEqual(
            admitted.slidingWindowAttention?.expectedCacheKinds,
            Self.expectedKinds(Self.layerTypes12B, window: 1024)
        )

        let refused: [(String, [String: Any], String)] = [
            ("path alias", Self.gemma4Config(), "mlx-community/gemma-4-12b-it-4bit"),
            ("other identity", Self.gemma4Config(), "google/gemma-4-26b-a4b-it"),
            ("extra architecture", Self.gemma4Config(architectures: ["Gemma4UnifiedForConditionalGeneration", "Other"]), Self.modelID),
            ("other architecture", Self.gemma4Config(architectures: ["Gemma4ForConditionalGeneration"]), Self.modelID),
            ("model type", Self.gemma4Config(modelType: "gemma4"), Self.modelID),
            ("text model type", Self.gemma4Config(textModelType: "gemma4_text"), Self.modelID),
            ("implicit layer_types", Self.gemma4Config(layerTypes: nil), Self.modelID),
            ("kv-shared layers", Self.gemma4Config(kvShared: 20), Self.modelID),
            ("kv-shared absent", Self.gemma4Config(kvShared: nil), Self.modelID),
            ("no window", Self.gemma4Config(slidingWindow: nil), Self.modelID),
            ("short layer_types", Self.gemma4Config(layerTypes: Array(Self.layerTypes12B.dropLast())), Self.modelID),
            ("all sliding", Self.gemma4Config(layerTypes: Array(repeating: "sliding_attention", count: 48)), Self.modelID),
            ("unknown layer", Self.gemma4Config(layerTypes: ["linear_attention"] + Self.layerTypes12B.dropFirst()), Self.modelID),
        ]
        for (label, object, modelID) in refused {
            let capabilities = try Self.capabilities(object, modelID: modelID)
            XCTAssertFalse(capabilities.hybridDecoderArchitectureVerified, label)
            XCTAssertNil(capabilities.slidingWindowAttention, label)
        }
    }

    func testAttachGateAdmitsTheGemma4MixedClassOnlyForTheExactIdentity() throws {
        let gates = PagedKVGates(
            identityAvailable: true, metallibAvailable: false, kernelRegistered: false, parityEstablished: false
        )
        func reason(_ capabilities: PagedKVRuntimeModelCapabilities, modelID: String, cacheClass: String = "mixed") -> PagedKVFallbackReason? {
            ModelRuntime.pagedKVAttachDecision(
                config: Self.config, modelID: modelID, modelHash: Self.modelSHA,
                tokenizerSHA256: nil, chatTemplateSHA256: nil, kvBitsOverride: nil,
                runtimeCacheClass: cacheClass, gates: gates, modelCapabilities: capabilities
            ).reason
        }
        // Past the cache-class check, stopped at the metallib gate.
        XCTAssertEqual(reason(try Self.capabilities(Self.gemma4Config()), modelID: Self.modelID), .metallib)
        // Every other gemma4 artifact is an unverified mixed class.
        let other = "mlx-community/gemma-4-26b-a4b-it-4bit"
        XCTAssertEqual(reason(try Self.capabilities(Self.gemma4Config(), modelID: other), modelID: other), .cacheClass)
        XCTAssertEqual(reason(try Self.capabilities(Self.gemma4Config(kvShared: 20)), modelID: Self.modelID), .cacheClass)
        XCTAssertEqual(
            reason(try Self.capabilities(Self.gemma4Config()), modelID: Self.modelID, cacheClass: "RotatingKVCache"),
            .cacheClass
        )
        // An explicit kv_bits still falls back quantized (FR-PKV5).
        XCTAssertEqual(ModelRuntime.pagedKVAttachDecision(
            config: Self.config, modelID: Self.modelID, modelHash: Self.modelSHA,
            tokenizerSHA256: nil, chatTemplateSHA256: nil, kvBitsOverride: 8,
            runtimeCacheClass: "mixed", gates: gates, modelCapabilities: try Self.capabilities(Self.gemma4Config())
        ).reason, .quantized)
    }

    func testMeasuredTopologyRequiresTheExactGemma4LayerLayout() throws {
        let admitted = try Self.capabilities(Self.gemma4Config())
        let exact = Self.expectedKinds(Self.layerTypes12B, window: 1024)
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(exact, modelCapabilities: admitted))
        var swapped = exact
        swapped.swapAt(4, 5)
        let mismatches: [(String, [PagedKVSharedForwardBackend.CacheKind])] = [
            ("layer order", swapped),
            ("window", Self.expectedKinds(Self.layerTypes12B, window: 512)),
            ("kv-shared caches omitted", Array(exact.dropLast(8))),
            ("all full", Array(repeating: .pagedAttention, count: 48)),
        ]
        for (label, kinds) in mismatches {
            XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(kinds, modelCapabilities: admitted), label)
        }
        let noLayout = PagedKVRuntimeModelCapabilities(
            modelFamily: "gemma4", requiresMoEDispatch: false, hybridDecoderArchitectureVerified: true
        )
        XCTAssertFalse(ModelRuntime.measuredMixedPagedKVTopology(exact, modelCapabilities: noLayout))
    }

    /// FR-PKV4 rule 3: the attach proof's prompt passes the window, so decode
    /// starts past it. gpt-oss's 128-token window keeps the 513-token proof.
    func testAttachProofPromptPassesTheSlidingWindow() throws {
        let gemma4 = try Self.capabilities(Self.gemma4Config())
        XCTAssertEqual(gemma4.attachProbePromptTokens(blockSizeTokens: 16), 1024 + 32)
        XCTAssertEqual(gemma4.attachProbePromptTokens(blockSizeTokens: 32), 1024 + 64)
        let gptOSS = ModelRuntime.pagedKVModelCapabilities(
            modelID: "openai/gpt-oss-20b",
            configJSONData: try JSONSerialization.data(withJSONObject: [
                "model_type": "gpt_oss", "architectures": ["GptOssForCausalLM"],
                "num_hidden_layers": 24, "sliding_window": 128, "num_local_experts": 32,
            ])
        )
        XCTAssertNotNil(gptOSS.slidingWindowAttention)
        XCTAssertEqual(gptOSS.attachProbePromptTokens(blockSizeTokens: 16), 513)
    }

    // MARK: - Tiny random-weight exactness

    /// Four layers (sliding, sliding, full, sliding) with an 8-token window,
    /// K=V full attention and a wider full-attention head, as the 12B has.
    private static let tinyGemma4Configuration = """
        {
          "model_type": "gemma4_unified",
          "architectures": ["Gemma4UnifiedForConditionalGeneration"],
          "vocab_size": 32,
          "text_config": {
            "model_type": "gemma4_unified_text",
            "hidden_size": 16,
            "num_hidden_layers": 4,
            "intermediate_size": 32,
            "num_attention_heads": 2,
            "head_dim": 8,
            "global_head_dim": 16,
            "num_key_value_heads": 1,
            "num_global_key_value_heads": 1,
            "attention_k_eq_v": true,
            "num_kv_shared_layers": 0,
            "hidden_size_per_layer_input": 0,
            "vocab_size": 32,
            "vocab_size_per_layer_input": 32,
            "sliding_window": 8,
            "layer_types": ["sliding_attention", "sliding_attention", "full_attention", "sliding_attention"],
            "max_position_embeddings": 4096,
            "final_logit_softcapping": 30.0,
            "use_double_wide_mlp": false,
            "enable_moe_block": false,
            "tie_word_embeddings": false,
            "rms_norm_eps": 1e-6,
            "rope_parameters": {
              "full_attention": {"partial_rotary_factor": 0.25, "rope_theta": 1000000.0, "rope_type": "proportional"},
              "sliding_attention": {"rope_theta": 10000.0, "rope_type": "default"}
            }
          }
        }
        """
    private static let tinyWindow = 8
    private static let tinyKinds: [PagedKVSharedForwardBackend.CacheKind] = [
        .slidingWindow(windowTokens: 8), .slidingWindow(windowTokens: 8), .pagedAttention, .slidingWindow(windowTokens: 8),
    ]
    private static let blockSizeTokens = 4
    private static let maxPhysicalBlocks = 512
    private static let lockstepWindow = ContinuousBatchSchedulerConfiguration.defaultDecodeLockstepWindow

    /// The tiny config passes the same layout gate the 12B does, and the
    /// model builds exactly that cache topology.
    func testTinyGemma4ConfigYieldsTheAdmittedTopology() throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(Self.tinyGemma4Configuration.utf8)) as? [String: Any]
        )
        let capabilities = try Self.capabilities(object)
        XCTAssertEqual(capabilities.slidingWindowAttention?.expectedCacheKinds, Self.tinyKinds)
        let model = try Self.tinyGemma4()
        let kinds = PagedKVSharedForwardBackend.CacheKind.kinds(from: try model.newCache(parameters: nil))
        XCTAssertEqual(kinds, Self.tinyKinds)
        XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(Self.tinyKinds, modelCapabilities: capabilities))
        XCTAssertEqual(try ModelRuntime.pagedKVRuntimeCacheClass(model: model, baseParameters: GenerateParameters()), "mixed")
    }

    /// Rows whose prompts are shorter than, equal to and longer than the
    /// window, decoded together for several lockstep windows (past more than
    /// one ring wrap), emit bitwise the same greedy tokens as each row
    /// decoded alone on the paged backend and as the stock serial caches
    /// (`RotatingKVCache` / `KVCacheSimple`).
    func testBatchedRowsMatchEachRowAloneAndTheSerialCaches() async throws {
        // Under `swift test` Bundle.main is Xcode's xctest runner; MLX loads
        // the metallib colocated with this test bundle's binary.
        let tests = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(bundleURL: tests.resourceURL, executableURL: tests.executableURL)
        else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        let model = try Self.tinyGemma4()
        let prompts = [5, 8, 13, 21].enumerated().map { Self.tinyPrompt(length: $1, salt: $0) }
        let decodeTokens = 2 * Self.lockstepWindow + 5

        let batched = try await Self.runPaged(model: model, prompts: prompts, decodeTokens: decodeTokens)
        for (row, prompt) in prompts.enumerated() {
            let alone = try await Self.runPaged(model: model, prompts: [prompt], decodeTokens: decodeTokens)[0]
            let serial = try Self.runSerial(model: model, prompt: prompt, decodeTokens: decodeTokens)
            XCTAssertEqual(alone.count, decodeTokens + 1, "row \(row)")
            XCTAssertEqual(alone, serial, "row \(row): paged alone differs from the serial caches")
            XCTAssertEqual(batched[row], alone, "row \(row): batched differs from alone")
        }
        XCTAssertGreaterThan(Set(batched.flatMap { $0 }).count, 2, "random weights degenerated to one token")
    }

    private static func tinyGemma4() throws -> Gemma4Model {
        let configuration = try JSONDecoder().decode(Gemma4Configuration.self, from: Data(tinyGemma4Configuration.utf8))
        MLXRandom.seed(2154)
        let model = Gemma4Model(configuration)
        eval(model)
        return model
    }

    private static func tinyPrompt(length: Int, salt: Int) -> [Int] {
        var state = UInt64(truncatingIfNeeded: 0x9E37_79B9 &+ salt)
        return (0 ..< length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % 32)
        }
    }

    private static func container(_ model: Gemma4Model) -> ModelContainer {
        ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: modelID),
            model: model,
            processor: StandInUserInputProcessor(),
            tokenizer: Gemma4MixedClassTokenizer()
        ))
    }

    /// Stock serial greedy decode on the model's own caches.
    private static func runSerial(model: Gemma4Model, prompt: [Int], decodeTokens: Int) throws -> [Int] {
        let caches = try model.newCache(parameters: nil)
        var logits = model(MLXArray(prompt.map(Int32.init))[.newAxis], cache: caches)
        var tokens: [Int] = []
        for _ in 0 ... decodeTokens {
            let next = argMax(logits[0, -1], axis: -1).item(Int.self)
            tokens.append(next)
            logits = model(MLXArray([Int32(next)])[.newAxis], cache: caches)
        }
        return tokens
    }

    /// Paged prefill (one chunk per row), then lockstep decode windows.
    private static func runPaged(model: Gemma4Model, prompts: [[Int]], decodeTokens: Int) async throws -> [[Int]] {
        let backend = PagedKVSharedForwardBackend(
            container: container(model),
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: 1,
            layerCount: tinyKinds.count,
            cacheKinds: tinyKinds
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: blockSizeTokens, maxPhysicalBlocks: maxPhysicalBlocks)
        func id(_ row: Int) -> String { "gemma4-mixed-\(row)" }
        var handles: [PagedKVBlockTableHandle] = []
        var generated: [[Int]] = []
        for (row, prompt) in prompts.enumerated() {
            let handle = try await allocator.allocate(conversationKey: id(row), maxTokens: prompt.count + decodeTokens + 8)
            handles.append(handle)
            _ = try await allocator.extend(handle, by: prompt.count)
            let outputs = try await backend.prefill(rows: [ContinuousBatchPrefillInput(
                requestID: id(row),
                promptTokens: prompt,
                binding: try await allocator.binding(for: handle),
                promptTokenOffset: 0,
                committedKVTokenCount: 0,
                targetKVTokenCount: prompt.count,
                isFinalChunk: true
            )])
            XCTAssertNil(outputs.first?.failureCode)
            generated.append([try XCTUnwrap(outputs.first?.sampledToken, "row \(row) sampled no first token")])
        }
        var remaining = decodeTokens
        while remaining > 0 {
            let steps = min(lockstepWindow, remaining)
            var inputs: [ContinuousBatchDecodeInput] = []
            for row in prompts.indices {
                let committed = prompts[row].count - 1 + generated[row].count
                _ = try await allocator.extend(handles[row], by: steps)
                try await allocator.beginDecodeStep(handles[row])
                let binding = try await allocator.binding(for: handles[row])
                inputs.append(ContinuousBatchDecodeInput(
                    requestID: id(row),
                    currentToken: generated[row].last!,
                    generatedTokens: generated[row],
                    promptTokens: prompts[row],
                    samplerSeed: 0,
                    temperature: 0,
                    topP: 1,
                    presencePenalty: 0,
                    frequencyPenalty: 0,
                    binding: binding,
                    blockTable: binding.currentTable,
                    committedKVTokenCount: committed,
                    targetKVTokenCount: committed + steps,
                    samplerStep: generated[row].count
                ))
            }
            let outcomes = try await backend.decodeLockstepWindow(rows: inputs, steps: steps)
            for handle in handles {
                try await allocator.endDecodeStep(handle)
            }
            for (row, outcome) in outcomes.enumerated() {
                guard case .output(let output) = outcome, output.requestID == id(row), output.tokens.count == steps else {
                    XCTFail("row \(row) decode failed: \(outcome)")
                    return generated
                }
                generated[row].append(contentsOf: output.tokens)
            }
            remaining -= steps
        }
        return generated
    }
}

private struct Gemma4MixedClassTokenizer: Tokenizer {
    let bosToken: String? = nil
    let eosToken: String? = nil
    let unknownToken: String? = nil

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map(String.init).joined(separator: " ") }
    func convertTokenToId(_ token: String) -> Int? { Int(token) }
    func convertIdToToken(_ id: Int) -> String? { String(id) }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}
