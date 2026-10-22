import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Issue #2084: a model split into pipeline stages must produce the same logits as
/// the whole model. Uses tiny random-weight Llama and DeepSeek-V3 checkpoints written
/// to a temp directory and runs on the CPU, so it needs no cached weights and no GPU.
final class PipelineStageForwardTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private static let llamaConfig: [String: Any] = [
        "model_type": "llama",
        "hidden_size": 64,
        "num_hidden_layers": 4,
        "intermediate_size": 96,
        "num_attention_heads": 4,
        "num_key_value_heads": 2,
        "rms_norm_eps": 1e-5,
        "vocab_size": 97,
        "tie_word_embeddings": true,
    ]

    private static let deepseekConfig: [String: Any] = [
        "model_type": "deepseek_v3",
        "vocab_size": 97,
        "hidden_size": 64,
        "intermediate_size": 96,
        "moe_intermediate_size": 32,
        "num_hidden_layers": 3,
        "num_attention_heads": 4,
        "num_key_value_heads": 4,
        "n_shared_experts": 1,
        "n_routed_experts": 4,
        "routed_scaling_factor": 1.0,
        "kv_lora_rank": 16,
        "q_lora_rank": 24,
        "qk_rope_head_dim": 8,
        "v_head_dim": 8,
        "qk_nope_head_dim": 8,
        "norm_topk_prob": true,
        "n_group": 1,
        "topk_group": 1,
        "num_experts_per_tok": 2,
        "moe_layer_freq": 1,
        "first_k_dense_replace": 1,
        "max_position_embeddings": 256,
        "rms_norm_eps": 1e-6,
        "rope_theta": 10000.0,
        "attention_bias": false,
    ]

    /// Write `config` and seeded random weights for it; return the directory and the
    /// whole model holding exactly those weights.
    private func makeCheckpoint(_ config: [String: Any]) async throws -> (URL, any LLMModel) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: directory.appendingPathComponent("config.json"))
        let created = try await LLMTypeRegistry.shared.createModel(
            configuration: data, modelType: config["model_type"] as! String)
        let model = try XCTUnwrap(created as? any LLMModel)
        MLXRandom.seed(2084)
        var weights = [String: MLXArray]()
        for (key, value) in model.parameters().flattened() {
            let noise = MLXRandom.normal(value.shape) * 0.1
            weights[key] = key.hasSuffix("norm.weight") ? 1 + noise : noise
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(Array(weights.values))
        try save(arrays: weights, url: directory.appendingPathComponent("model.safetensors"))
        return (directory, model)
    }

    /// Prefill `prompt` then decode `steps` greedy tokens through both the whole model
    /// and the chained stages, asserting the logits agree at every step.
    private func assertStagesMatchWholeModel(
        _ config: [String: Any],
        splits: [Range<Int>],
        prompt: [Int32] = [3, 14, 15, 92, 65],
        steps: Int = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await Device.withDefaultDevice(.cpu) {
            let (directory, whole) = try await makeCheckpoint(config)
            var stages = [PipelineStageModel]()
            for range in splits {
                stages.append(try await PipelineStageModel.load(directory: directory, layers: range))
            }
            let wholeCache = try whole.newCache(parameters: nil)
            let stageCaches = try stages.map { try $0.newCache() }

            var input = MLXArray(prompt).reshaped(1, prompt.count)
            for step in 0...steps {
                let expected = whole(input, cache: wholeCache)
                var carried = input
                for (stage, cache) in zip(stages, stageCaches) {
                    let output = try stage.forward(carried, cache: cache)
                    if !stage.plan.isLast {
                        // Ship the boundary through the frame codec, as the link does.
                        let encoded = try PipelineActivationCodec.encode(output)
                        carried = try PipelineActivationCodec.decode(
                            dtype: encoded.dtype, shape: encoded.shape, payload: encoded.payload)
                    } else {
                        carried = output
                    }
                }
                XCTAssertEqual(carried.shape, expected.shape, "step \(step)", file: file, line: line)
                let difference = abs(carried - expected).max().item(Float.self)
                XCTAssertLessThanOrEqual(difference, 1e-4, "step \(step) max |delta| \(difference)", file: file, line: line)
                let token = argMax(expected[0, -1], axis: -1).item(Int32.self)
                XCTAssertEqual(argMax(carried[0, -1], axis: -1).item(Int32.self), token, "step \(step)", file: file, line: line)
                input = MLXArray([token]).reshaped(1, 1)
            }
        }
    }

    func testLlamaTwoStageSplitMatchesWholeModel() async throws {
        try await assertStagesMatchWholeModel(Self.llamaConfig, splits: [0..<2, 2..<4])
    }

    func testLlamaThreeStageSplitWithMiddleStageMatchesWholeModel() async throws {
        try await assertStagesMatchWholeModel(Self.llamaConfig, splits: [0..<1, 1..<3, 3..<4])
    }

    func testLlamaUntiedHeadSplitMatchesWholeModel() async throws {
        var config = Self.llamaConfig
        config["tie_word_embeddings"] = false
        try await assertStagesMatchWholeModel(config, splits: [0..<3, 3..<4])
    }

    func testDeepseekV3SplitAcrossDenseAndMoELayersMatchesWholeModel() async throws {
        // Layer 0 is dense (first_k_dense_replace = 1); layers 1-2 are MoE. Splitting
        // at 1 renumbers the tail's MoE layers from 0, which the config rewrite covers.
        try await assertStagesMatchWholeModel(Self.deepseekConfig, splits: [0..<1, 1..<3])
        try await assertStagesMatchWholeModel(Self.deepseekConfig, splits: [0..<2, 2..<3])
    }

    /// SPEC-051-R017: decode rows of requests with different prompt lengths run
    /// in one batched forward per stage and give each request exactly the logits it
    /// gets alone, step after step (its own KV, its own position).
    private func assertBatchedDecodeMatchesPerRequest(
        _ config: [String: Any],
        splits: [Range<Int>],
        prompts: [[Int32]] = [[3, 14, 15, 92, 65], [7, 1], [42, 8, 19]],
        steps: Int = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await Device.withDefaultDevice(.cpu) {
            let (directory, _) = try await makeCheckpoint(config)
            var stages = [PipelineStageModel]()
            for range in splits {
                stages.append(try await PipelineStageModel.load(directory: directory, layers: range))
            }
            // Two copies of every request's KV: one decoded alone, one batched.
            let alone = try prompts.map { _ in try stages.map { try $0.newCache() } }
            let batched = try prompts.map { _ in try stages.map { try $0.newCache() } }
            func run(_ input: MLXArray, _ caches: [[KVCache]]) throws -> MLXArray {
                var carried = input
                for (index, stage) in stages.enumerated() {
                    carried = try stage.forward(carried, cache: caches[index])
                }
                return carried
            }
            var next = [Int32]()
            for (row, prompt) in prompts.enumerated() {
                let logits = try run(MLXArray(prompt).reshaped(1, prompt.count), alone[row])
                _ = try run(MLXArray(prompt).reshaped(1, prompt.count), batched[row])
                next.append(argMax(logits[0, -1], axis: -1).item(Int32.self))
            }
            for step in 0..<steps {
                var expected = [MLXArray]()
                for row in prompts.indices {
                    expected.append(try run(MLXArray([next[row]]).reshaped(1, 1), alone[row]))
                }
                var carried = MLXArray(next).reshaped(prompts.count, 1)
                for (index, stage) in stages.enumerated() {
                    XCTAssertTrue(stage.canBatchDecode(batched.map { $0[index] }), file: file, line: line)
                    let output = try stage.forwardBatch(carried, caches: batched.map { $0[index] })
                    if stage.plan.isLast {
                        carried = output
                    } else {
                        let encoded = try PipelineActivationCodec.encode(output)
                        carried = try PipelineActivationCodec.decode(dtype: encoded.dtype, shape: encoded.shape, payload: encoded.payload)
                    }
                }
                for row in prompts.indices {
                    let difference = abs(carried[row ..< row + 1] - expected[row]).max().item(Float.self)
                    XCTAssertLessThanOrEqual(difference, 1e-4, "step \(step) row \(row) max |delta| \(difference)", file: file, line: line)
                    let token = argMax(expected[row][0, -1], axis: -1).item(Int32.self)
                    XCTAssertEqual(argMax(carried[row, -1], axis: -1).item(Int32.self), token, "step \(step) row \(row)", file: file, line: line)
                    next[row] = token
                }
            }
            for row in prompts.indices {
                XCTAssertEqual(batched[row].last?.first?.offset, prompts[row].count + steps, "row \(row) KV length", file: file, line: line)
            }
        }
    }

    func testBatchedDecodeMatchesPerRequestLlama() async throws {
        try await assertBatchedDecodeMatchesPerRequest(Self.llamaConfig, splits: [0..<1, 1..<3, 3..<4])
    }

    func testBatchedDecodeMatchesPerRequestDeepseekV3() async throws {
        try await assertBatchedDecodeMatchesPerRequest(Self.deepseekConfig, splits: [0..<1, 1..<3])
    }

    /// Prefill `prompt` in chunks through the stages (fill-only on the last stage for
    /// all but the final chunk) and compare with the whole model's one-shot prefill,
    /// then keep decoding to show the chunked KV is the same KV.
    private func assertChunkedPrefillMatchesUnchunked(
        _ config: [String: Any],
        splits: [Range<Int>],
        prompt: [Int32],
        chunk: Int,
        steps: Int = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await Device.withDefaultDevice(.cpu) {
            let (directory, whole) = try await makeCheckpoint(config)
            var stages = [PipelineStageModel]()
            for range in splits {
                stages.append(try await PipelineStageModel.load(directory: directory, layers: range))
            }
            let wholeCache = try whole.newCache(parameters: nil)
            let stageCaches = try stages.map { try $0.newCache() }
            var expected = whole(MLXArray(prompt).reshaped(1, prompt.count), cache: wholeCache)

            var logits: MLXArray?
            let starts = Array(stride(from: 0, to: prompt.count, by: chunk))
            for (index, start) in starts.enumerated() {
                let isLast = index == starts.count - 1
                let piece = Array(prompt[start..<min(prompt.count, start + chunk)])
                var carried = MLXArray(piece).reshaped(1, piece.count)
                for (stage, cache) in zip(stages, stageCaches) {
                    if stage.plan.isLast {
                        if isLast {
                            logits = try stage.forward(carried, cache: cache)
                        } else {
                            try stage.fill(carried, cache: cache)
                        }
                    } else {
                        let encoded = try PipelineActivationCodec.encode(try stage.forward(carried, cache: cache))
                        carried = try PipelineActivationCodec.decode(dtype: encoded.dtype, shape: encoded.shape, payload: encoded.payload)
                    }
                }
            }
            var actual = try XCTUnwrap(logits, file: file, line: line)
            for step in 0...steps {
                let difference = abs(actual[0, -1] - expected[0, -1]).max().item(Float.self)
                XCTAssertLessThanOrEqual(difference, 1e-4, "step \(step) max |delta| \(difference)", file: file, line: line)
                let token = argMax(expected[0, -1], axis: -1).item(Int32.self)
                XCTAssertEqual(argMax(actual[0, -1], axis: -1).item(Int32.self), token, "step \(step)", file: file, line: line)
                guard step < steps else { break }
                let input = MLXArray([token]).reshaped(1, 1)
                expected = whole(input, cache: wholeCache)
                var carried = input
                for (stage, cache) in zip(stages, stageCaches) {
                    carried = try stage.forward(carried, cache: cache)
                }
                actual = carried
            }
            XCTAssertEqual(stageCaches.last?.first?.offset, prompt.count + steps, file: file, line: line)
        }
    }

    func testChunkedPrefillLogitsEqualUnchunkedLlama() async throws {
        let prompt: [Int32] = [3, 14, 15, 92, 65, 35, 89, 79, 32, 38, 46]
        try await assertChunkedPrefillMatchesUnchunked(Self.llamaConfig, splits: [0..<1, 1..<3, 3..<4], prompt: prompt, chunk: 4)
        try await assertChunkedPrefillMatchesUnchunked(Self.llamaConfig, splits: [0..<2, 2..<4], prompt: prompt, chunk: 1)
    }

    func testChunkedPrefillLogitsEqualUnchunkedDeepseekV3() async throws {
        let prompt: [Int32] = [3, 14, 15, 92, 65, 35, 89, 79, 32]
        try await assertChunkedPrefillMatchesUnchunked(Self.deepseekConfig, splits: [0..<1, 1..<3], prompt: prompt, chunk: 4)
    }

    /// Teacher-forced parity on a real (tiny, random-weight) model: the reference is
    /// the whole model's greedy run with per-step logit summaries; the stages are fed
    /// the reference tokens, and `perturb(step, stage, activation)` may alter the
    /// boundary activation a stage sends.
    private func teacherForcedParity(
        _ config: [String: Any],
        splits: [Range<Int>],
        prompt: [Int32] = [3, 14, 15, 92, 65],
        steps: Int = 6,
        topK: Int = 8,
        perturb: ((Int, Int, MLXArray) -> MLXArray)? = nil
    ) async throws -> ShardTeacherForcedParity {
        try await Device.withDefaultDevice(.cpu) {
            let (directory, whole) = try await makeCheckpoint(config)
            var stages = [PipelineStageModel]()
            for range in splits {
                stages.append(try await PipelineStageModel.load(directory: directory, layers: range))
            }
            let wholeCache = try whole.newCache(parameters: nil)
            var reference = [ShardLogitSummary]()
            var teacher = [Int32]()
            var input = MLXArray(prompt).reshaped(1, prompt.count)
            for _ in 0..<steps {
                let summary = PipelineLogitSummarizer.summarize(logits: whole(input, cache: wholeCache), topK: topK)
                reference.append(summary)
                teacher.append(summary.top1)
                input = MLXArray([summary.top1]).reshaped(1, 1)
            }

            let caches = try stages.map { try $0.newCache() }
            var sharded = [ShardLogitSummary]()
            input = MLXArray(prompt).reshaped(1, prompt.count)
            for step in 0..<steps {
                var carried = input
                for (index, (stage, cache)) in zip(stages, caches).enumerated() {
                    let output = try stage.forward(carried, cache: cache)
                    if stage.plan.isLast {
                        sharded.append(PipelineLogitSummarizer.summarize(logits: output, topK: topK))
                    } else {
                        carried = perturb?(step, index, output) ?? output
                    }
                }
                input = MLXArray([teacher[step]]).reshaped(1, 1)
            }
            return try ShardLogitParity.compare(reference: [reference], sharded: [sharded])
        }
    }

    func testTeacherForcedParityOfAnIdenticalSplitPassesWithFullAgreement() async throws {
        let parity = try await teacherForcedParity(Self.llamaConfig, splits: [0..<1, 1..<3, 3..<4])
        XCTAssertEqual(parity.verdict, "pass")
        XCTAssertEqual(parity.steps, 6)
        XCTAssertEqual(parity.top1AgreementRate, 1)
        XCTAssertEqual(parity.nearTieFlips, 0)
        XCTAssertLessThan(parity.maxAbsDeltaLogprob, 1e-4)
        XCTAssertGreaterThan(parity.meanTopKOverlap, 0.99)

        let deepseek = try await teacherForcedParity(Self.deepseekConfig, splits: [0..<1, 1..<3])
        XCTAssertEqual(deepseek.verdict, "pass")
        XCTAssertEqual(deepseek.top1AgreementRate, 1)
    }

    func testTeacherForcedParityFailsHardAtTheStepAStageIsPerturbed() async throws {
        // From step 3 on, stage 0 ships a boundary activation replaced by large noise.
        let parity = try await teacherForcedParity(Self.llamaConfig, splits: [0..<2, 2..<4]) { step, stage, output in
            guard step == 3, stage == 0 else { return output }
            MLXRandom.seed(51)
            return (MLXRandom.normal(output.shape) * 40).asType(output.dtype)
        }
        XCTAssertEqual(parity.verdict, "fail")
        let first = try XCTUnwrap(parity.hardFailures.first, "a 40-sigma activation must flip the top-1")
        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(first.step, 3)
        XCTAssertNotEqual(first.shardedToken, first.referenceToken)
        XCTAssertGreaterThan(parity.maxAbsDeltaLogprob, 0.1)
    }

    func testStageLoadsOnlyItsOwnLayers() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let (directory, _) = try await makeCheckpoint(Self.llamaConfig)
            let plan = try PipelineStagePlan(layers: 1..<3, totalLayers: 4)
            let weights = try PipelineStageModel.loadStageWeights(directory: directory, plan: plan)
            XCTAssertTrue(weights.keys.allSatisfy { $0.hasPrefix("model.layers.0.") || $0.hasPrefix("model.layers.1.") },
                          "middle stage loaded \(weights.keys.sorted())")
            XCTAssertFalse(weights.isEmpty)
        }
    }

    func testStageConfigRewrite() throws {
        let config: [String: Any] = [
            "num_hidden_layers": 6,
            "first_k_dense_replace": 3,
            "layer_types": ["a", "b", "c", "d", "e", "f"],
            "quantization": [
                "group_size": 64,
                "bits": 4,
                "model.layers.1.mlp.gate": ["bits": 8],
                "model.layers.4.mlp.gate": ["bits": 8],
                "lm_head": ["bits": 6],
            ] as [String: Any],
        ]
        let plan = try PipelineStagePlan(layers: 2..<5, totalLayers: 6)
        let stage = try PipelineStageModel.stageConfig(config, plan: plan, builtLayers: 4)
        XCTAssertEqual(stage["num_hidden_layers"] as? Int, 4)
        XCTAssertEqual(stage["first_k_dense_replace"] as? Int, 1)
        XCTAssertEqual(stage["layer_types"] as? [String], ["c", "d", "e", "e"])
        let quant = try XCTUnwrap(stage["quantization"] as? [String: Any])
        XCTAssertEqual(Set(quant.keys), ["group_size", "bits", "model.layers.2.mlp.gate", "lm_head"])

        XCTAssertThrowsError(try PipelineStageModel.stageConfig(
            ["num_hidden_layers": 6, "moe_layer_freq": 2], plan: try PipelineStagePlan(layers: 1..<6, totalLayers: 6),
            builtLayers: 5))
    }

    func testRejectsBadRangesAndUnsupportedModels() async throws {
        XCTAssertThrowsError(try PipelineStagePlan(layers: 3..<3, totalLayers: 4))
        XCTAssertThrowsError(try PipelineStagePlan(layers: 2..<5, totalLayers: 4))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        try JSONSerialization.data(withJSONObject: ["model_type": "glm5_next_text", "num_hidden_layers": 4])
            .write(to: directory.appendingPathComponent("config.json"))
        do {
            _ = try await PipelineStageModel.load(directory: directory, layers: 0..<2)
            XCTFail("glm5_next_text must be refused")
        } catch PipelineStageError.unsupportedModelType(let type) {
            XCTAssertEqual(type, "glm5_next_text")
        }
    }

    func testActivationCodecRoundTripsBitExactly() throws {
        try Device.withDefaultDevice(.cpu) {
            for dtype in [DType.bfloat16, .float16, .float32] {
                let array = (MLXRandom.normal([1, 3, 16]) * 7).asType(dtype)
                let encoded = try PipelineActivationCodec.encode(array)
                XCTAssertEqual(encoded.shape, [1, 3, 16])
                let decoded = try PipelineActivationCodec.decode(dtype: encoded.dtype, shape: encoded.shape, payload: encoded.payload)
                XCTAssertEqual(decoded.dtype, dtype)
                XCTAssertTrue(arrayEqual(decoded, array).item(Bool.self))
            }
            XCTAssertThrowsError(try PipelineActivationCodec.encode(MLXArray([Int32(1)]).reshaped(1, 1, 1)))
            XCTAssertThrowsError(try PipelineActivationCodec.encode(MLXArray.zeros([4], dtype: .float16)))
        }
    }
}
