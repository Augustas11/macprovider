import Foundation
import MLX
import MLXLLM
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-036 FR-21: the teacher-forced scorer gives the generating model's own
/// greedy output arg-max agreement and finite log-probabilities, matches a
/// one-shot full-sequence forward, is deterministic, and scores unrelated
/// tokens far lower. Uses a tiny random-weight Qwen3.5 hybrid, so it runs
/// without weights (skipped when the MLX metallib is unavailable).
final class ComputeScoreRuntimeTests: XCTestCase {
    private static let configuration = """
        {
          "model_type": "qwen3_5_text",
          "hidden_size": 16,
          "num_hidden_layers": 2,
          "intermediate_size": 32,
          "num_attention_heads": 2,
          "num_key_value_heads": 1,
          "head_dim": 8,
          "linear_num_value_heads": 2,
          "linear_num_key_heads": 1,
          "linear_key_head_dim": 32,
          "linear_value_head_dim": 32,
          "linear_conv_kernel_dim": 2,
          "rms_norm_eps": 1e-6,
          "vocab_size": 32,
          "rope_theta": 100000.0,
          "partial_rotary_factor": 0.25,
          "max_position_embeddings": 4096,
          "tie_word_embeddings": false,
          "attention_bias": false,
          "full_attention_interval": 2,
          "mtp_num_hidden_layers": 1,
          "mtp_use_dedicated_embeddings": false,
          "rope_parameters": {
            "type": "default",
            "rope_theta": 100000.0,
            "partial_rotary_factor": 0.25
          }
        }
        """

    private func requireMetal() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    private static func tinyModel() throws -> Qwen35TextModel {
        let config = try JSONDecoder().decode(Qwen35TextConfiguration.self, from: Data(configuration.utf8))
        MLXRandom.seed(1644)
        let model = Qwen35TextModel(config)
        eval(model)
        return model
    }

    private static func prompt(length: Int, salt: UInt64) -> [Int] {
        var state = 0x9E37_79B9 &+ salt
        return (0 ..< length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % 32)
        }
    }

    /// Generation as the serial path runs it: chunked prefill, then one token
    /// per forward.
    private static func greedy(model: Qwen35TextModel, prompt: [Int], count: Int) throws -> [Int] {
        let cache = try model.newCache(parameters: nil)
        var offset = 0
        while prompt.count - offset > 512 {
            let chunk = MLXArray(prompt[offset ..< offset + 512].map { Int32($0) }).reshaped([1, 512])
            _ = model(chunk, cache: cache)
            eval(cache.flatMap { $0.state })
            offset += 512
        }
        let rest = Array(prompt[offset...])
        var y = MLXArray(rest.map { Int32($0) }).reshaped([1, rest.count])
        var out: [Int] = []
        for _ in 0 ..< count {
            let logits = model(y, cache: cache)
            let v = logits.dim(logits.ndim - 1)
            let last = logits.reshaped([-1, v])[logits.reshaped([-1, v]).dim(0) - 1]
            let next = argMax(last, axis: -1).asType(.int32).item(Int32.self)
            eval(cache.flatMap { $0.state })
            out.append(Int(next))
            y = MLXArray([next]).reshaped([1, 1])
        }
        return out
    }

    func testOwnGreedyOutputAgreesAndMatchesOneShotForward() throws {
        try requireMetal()
        let model = try Self.tinyModel()
        // Crosses the 512-token prefill chunk and the 128-token score chunk.
        let prompt = Self.prompt(length: 600, salt: 7)
        let output = try Self.greedy(model: model, prompt: prompt, count: 140)

        let scores = try ComputeScoreRuntime.teacherForced(model: model, promptTokens: prompt, outputTokens: output)
        XCTAssertEqual(scores.logprobs.count, output.count)
        XCTAssertTrue(scores.logprobs.allSatisfy { $0.isFinite && $0 <= 0 })
        let agreement = Double(scores.top1.filter { $0 }.count) / Double(output.count)
        // Only near-ties between prefill and one-token decode may flip.
        XCTAssertGreaterThanOrEqual(agreement, 0.95)

        let again = try ComputeScoreRuntime.teacherForced(model: model, promptTokens: prompt, outputTokens: output)
        XCTAssertEqual(again, scores, "scoring must be deterministic")

        let full = prompt + output
        let cache = try model.newCache(parameters: nil)
        let logits = model(MLXArray(full.map { Int32($0) }).reshaped([1, full.count]), cache: cache)
        let v = logits.dim(logits.ndim - 1)
        let rows = logits.reshaped([-1, v]).asType(.float32)
        let logProbs = rows - logSumExp(rows, axis: -1, keepDims: true)
        let start = prompt.count - 1
        let targets = MLXArray(output.map { Int32($0) }).reshaped([output.count, 1])
        let picked = takeAlong(logProbs[start ..< start + output.count], targets, axis: -1).reshaped([-1])
        let reference = picked.asArray(Float.self).map(Double.init)
        for (i, value) in reference.enumerated() {
            XCTAssertEqual(scores.logprobs[i], value, accuracy: 1e-3, "position \(i)")
        }
    }

    func testUnrelatedOutputScoresLower() throws {
        try requireMetal()
        let model = try Self.tinyModel()
        let prompt = Self.prompt(length: 64, salt: 11)
        let own = try Self.greedy(model: model, prompt: prompt, count: 64)
        let unrelated = Self.prompt(length: 64, salt: 99)

        let ownScores = try ComputeScoreRuntime.teacherForced(model: model, promptTokens: prompt, outputTokens: own)
        let unrelatedScores = try ComputeScoreRuntime.teacherForced(model: model, promptTokens: prompt, outputTokens: unrelated)
        let ownMean = ownScores.logprobs.reduce(0, +) / Double(own.count)
        let unrelatedMean = unrelatedScores.logprobs.reduce(0, +) / Double(unrelated.count)
        XCTAssertGreaterThan(ownMean, unrelatedMean)
        XCTAssertGreaterThan(ownScores.top1.filter { $0 }.count, unrelatedScores.top1.filter { $0 }.count)
    }

    func testEmptyInputsScoreNothing() throws {
        try requireMetal()
        let model = try Self.tinyModel()
        XCTAssertEqual(try ComputeScoreRuntime.teacherForced(model: model, promptTokens: [], outputTokens: [1]).logprobs, [])
        XCTAssertEqual(try ComputeScoreRuntime.teacherForced(model: model, promptTokens: [1], outputTokens: []).logprobs, [])
    }
}
