import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// The FR-CB10 self-check's stock serial baseline
/// (`ModelRuntime.continuousBatchingSelfCheckSerialTPS`) on a GLM-5-Next
/// model at a 64k serve cap. Before the KV-cap choke point it failed with
/// `incompatibleCapacity(expected: 65536, count: <sparse layers>)` because
/// `generate` validated the model's own latent caches against `maxKVSize`.
/// Runs a tiny randomly initialised GLM-5-Next text model (Metal host).
final class GLM5NextSerialBaselineTests: XCTestCase {
    func testSelfCheckSerialBaselineRunsOnAGLMModelUnderTheServeCap() async throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        let model = try Self.tinyModel()
        XCTAssertTrue(ModelRuntime.modelSizesItsOwnKVCache(model))
        let cache = try model.newCache(parameters: nil)
        XCTAssertTrue(cache.contains { $0 is any GLM5NextLatentCache })
        // The serve cap the window used, through the one serve-parameter
        // constructor: no maxKVSize for a model that sizes its own cache.
        let parameters = try ModelRuntime.makeServeGenerateParameters(
            model: model, maxTokens: 4, promptTokens: 8, maxContextTokens: 65_536, kvBitsOverride: nil,
            prefillStepSize: 512, temperature: 0, topP: 1
        )
        XCTAssertNil(parameters.maxKVSize)
        XCTAssertEqual(parameters.maxTokens, 4)
        XCTAssertEqual(parameters.topK, 0)
        XCTAssertNil(parameters.repetitionPenalty)
        let sampled = try ModelRuntime.makeServeGenerateParameters(
            model: model, maxTokens: 4, promptTokens: 8, maxContextTokens: 65_536, kvBitsOverride: nil,
            prefillStepSize: 512, temperature: 0.7, topP: 0.8, topK: 20, repetitionPenalty: 1.05
        )
        XCTAssertNil(sampled.maxKVSize)
        XCTAssertEqual(sampled.maxTokens, 4)
        XCTAssertEqual(sampled.topK, 20)
        XCTAssertEqual(sampled.repetitionPenalty, Float(1.05))
        XCTAssertEqual(sampled.repetitionContextSize, 20)
        // No maxKVSize bounds this model's cache, so the serve constructor
        // clamps the completion budget to the context the prompt leaves.
        let nearLimit = try ModelRuntime.makeServeGenerateParameters(
            model: model, maxTokens: 1_000_000, promptTokens: 65_000, maxContextTokens: 65_536,
            kvBitsOverride: nil, prefillStepSize: 512, temperature: 0, topP: 1
        )
        XCTAssertEqual(nearLimit.maxTokens, 536)
        XCTAssertThrowsError(try ModelRuntime.makeServeGenerateParameters(
            model: model, maxTokens: 4, promptTokens: 65_536, maxContextTokens: 65_536,
            kvBitsOverride: nil, prefillStepSize: 512, temperature: 0, topP: 1
        )) { error in
            XCTAssertEqual((error as? APIError)?.code, "context_length_exceeded")
        }

        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: "zai-org/glm-5.3-flash"),
            model: model,
            processor: StandInUserInputProcessor(),
            tokenizer: TinyGLMTokenizer()
        ))
        let runtime = ModelRuntime(
            modelID: "zai-org/glm-5.3-flash",
            maxContextTokensOverride: 65_536,
            warmSwapEnabled: false,
            container: container,
            loader: { _ in throw CancellationError() }
        )
        let rate = try await runtime.continuousBatchingSelfCheckSerialTPS(
            prompts: [[1, 2, 3, 4, 5, 6, 7, 8]], maxTokens: 4
        )
        XCTAssertGreaterThan(rate.decodeTPS, 0)
        XCTAssertGreaterThan(rate.endToEndTPS, 0)
    }

    /// Security r1: a model that sizes its own KV cache gets no `maxKVSize`,
    /// so the serial path clamps its completion budget exactly as a batched
    /// row does (`continuousBatchMaxOutputTokens`).
    func testSerialBudgetForASelfSizedCacheMatchesTheBatchedRowBound() throws {
        for (requested, prompt) in [(Int?.none, 40), (512, 40), (250_000, 40), (1_000_000, 199_999), (Int?.none, 199_999)] {
            XCTAssertEqual(
                try ModelRuntime.serialMaxOutputTokens(
                    requested: requested, promptTokens: prompt, maxContextTokens: 200_000,
                    modelSizesItsOwnKVCache: true
                ),
                try ModelRuntime.continuousBatchMaxOutputTokens(
                    requested: requested, promptTokens: prompt, maxContextTokens: 200_000
                )
            )
        }
        for prompt in [200_000, 200_001] {
            XCTAssertThrowsError(try ModelRuntime.serialMaxOutputTokens(
                requested: 16, promptTokens: prompt, maxContextTokens: 200_000,
                modelSizesItsOwnKVCache: true
            )) { error in
                let apiError = error as? APIError
                XCTAssertEqual(apiError?.status, 413)
                XCTAssertEqual(apiError?.code, "context_length_exceeded")
                XCTAssertEqual(apiError?.inferenceRan, false)
                XCTAssertEqual(apiError?.settlementRan, false)
            }
        }
    }

    /// A capped serve cache (`maxKVSize`, a rotating cache) already bounds
    /// memory, so every other model keeps the requested budget unchanged,
    /// including at and past the context edge.
    func testSerialBudgetForACappedServeCacheIsUnchanged() throws {
        for (requested, prompt) in [(Int?.none, 40), (512, 40), (1_000_000, 199_999), (16, 200_000), (Int?.none, 200_000)] {
            XCTAssertEqual(
                try ModelRuntime.serialMaxOutputTokens(
                    requested: requested, promptTokens: prompt, maxContextTokens: 200_000,
                    modelSizesItsOwnKVCache: false
                ),
                requested
            )
        }
    }

    /// Six layers (three KDA, then DSA + MoE, KDA + MoE, DSA with a shared
    /// indexer), as the fork's GLM5NextTests fixture.
    private static func tinyModel() throws -> GLM5NextTextModel {
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
        // Small seeded noise so routing and top-k selection have no ties.
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

private struct TinyGLMTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.utf8.map { Int($0) % 64 } }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map(String.init).joined(separator: " ") }
    func convertTokenToId(_ token: String) -> Int? { Int(token) }
    func convertIdToToken(_ id: Int) -> String? { String(id) }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [1, 2, 3] }
}
