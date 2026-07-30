// StageForwardParityTests.swift
// Spike 01: prove mlx-swift-lm can slice Llama layers on hidden state and match full-model output.

import Foundation
import MLX
import MLXNN
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
@testable import MLXLLM
import XCTest

// MARK: - Helpers

/// Run a contiguous slice of Llama transformer blocks on a hidden state tensor.
func runLayerBlock(
    layers: [LlamaTransformerBlock],
    range: Range<Int>,
    hidden: MLXArray,
    cache: [KVCache],
    mask: MLXFast.ScaledDotProductAttentionMaskMode
) -> MLXArray {
    var h = hidden
    for i in range {
        h = layers[i](h, mask: mask, cache: cache[i])
    }
    return h
}

/// Resolve a HuggingFace model ID to a local snapshot directory.
/// Tries `refs/main` first; falls back to the first snapshot directory found.
func localHFSnapshot(for modelID: String) -> URL? {
    let parts = modelID.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let repoDir = home
        .appendingPathComponent(".cache/huggingface/hub")
        .appendingPathComponent("models--\(parts[0])--\(parts[1])")
    let snapshotsDir = repoDir.appendingPathComponent("snapshots")

    // Try refs/main first (standard HF hub layout)
    let refsMain = repoDir.appendingPathComponent("refs/main")
    if let revision = try? String(contentsOf: refsMain, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !revision.isEmpty
    {
        let snapshot = snapshotsDir.appendingPathComponent(revision)
        if FileManager.default.fileExists(atPath: snapshot.path) { return snapshot }
    }

    // Fall back: pick the first snapshot directory that contains config.json
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: snapshotsDir, includingPropertiesForKeys: nil)
    else { return nil }
    return entries.first { dir in
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        guard exists && isDir.boolValue else { return false }
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path)
    }
}

/// Locate the best available Llama model directory (env override or HF cache).
func resolveLlamaModelDir() -> URL? {
    if let envPath = ProcessInfo.processInfo.environment["SPIKE01_MODEL_PATH"]
        ?? ProcessInfo.processInfo.environment["MACPROVIDER_INTEGRATION_MODEL"],
        !envPath.isEmpty
    {
        let url = URL(fileURLWithPath: envPath)
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    for candidate in [
        "mlx-community/Llama-3.2-3B-Instruct-4bit",
        "mlx-community/Llama-3.2-1B-Instruct-4bit",
        "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
    ] {
        if let url = localHFSnapshot(for: candidate) {
            return url
        }
    }
    return nil
}

// MARK: - Tests

final class StageForwardParityTests: XCTestCase {

    // MARK: testLlamaLayerBlockShape

    /// Load Llama, embed one token, run layers[0] only, assert output shape and finiteness.
    func testLlamaLayerBlockShape() async throws {
        guard let modelDir = resolveLlamaModelDir() else {
            throw XCTSkip("No cached Llama model found — set SPIKE01_MODEL_PATH or cache a model under ~/.cache/huggingface/hub")
        }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir,
            using: #huggingFaceTokenizerLoader()
        )

        try await container.perform { context in
            guard let llamaModel = context.model as? LlamaModel else {
                XCTFail("Loaded model is not LlamaModel (got \(type(of: context.model)))")
                return
            }

            let input = MLXArray([Int32(1)]).reshaped(1, 1)
            var h = llamaModel.model.embedTokens(input)
            // Derive hiddenSize from the embedding output (quantized weights have
            // a different weight shape than the actual hidden dimension).
            let hiddenSize = h.dim(2)

            // seq len == 1 → mask is .none
            let mask = createAttentionMask(h: h, cache: nil as KVCache?)

            let cache = KVCacheSimple()
            h = llamaModel.model.layers[0](h, mask: mask, cache: cache)
            eval(h)

            XCTAssertEqual(h.shape, [1, 1, hiddenSize],
                "layers[0] output shape should be [1, 1, hiddenSize=\(hiddenSize)]")
            let flat = h.flattened().asArray(Float.self)
            XCTAssertFalse(flat.contains(where: { $0.isNaN }),
                "layers[0] output must be finite — found NaN")
        }
    }

    // MARK: testLlamaStagedForwardMatchesFullModel

    /// Run full Llama forward and a two-stage sliced forward on a single token.
    /// The greedy argmax of the final logits must agree.
    func testLlamaStagedForwardMatchesFullModel() async throws {
        guard let modelDir = resolveLlamaModelDir() else {
            throw XCTSkip("No cached Llama model found — set SPIKE01_MODEL_PATH or cache a model under ~/.cache/huggingface/hub")
        }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir,
            using: #huggingFaceTokenizerLoader()
        )

        try await container.perform { context in
            guard let llamaModel = context.model as? LlamaModel else {
                XCTFail("Loaded model is not LlamaModel (got \(type(of: context.model)))")
                return
            }

            let input = MLXArray([Int32(1)]).reshaped(1, 1)

            // ── Full path ──────────────────────────────────────────────────────────
            let fullCache = llamaModel.newCache(parameters: nil)
            let fullLogits = llamaModel(input, cache: fullCache)
            eval(fullLogits)
            let fullArgmax = argMax(fullLogits[0, -1], axis: -1).item(Int.self)

            // ── Staged path ────────────────────────────────────────────────────────
            let numLayers = llamaModel.model.layers.count
            let lo = numLayers / 2

            let stagedCache = llamaModel.newCache(parameters: nil)
            var h = llamaModel.model.embedTokens(input)

            // single token: seq len == 1 → .none mask throughout
            let mask = createAttentionMask(h: h, cache: nil as KVCache?)

            h = runLayerBlock(
                layers: llamaModel.model.layers,
                range: 0..<lo,
                hidden: h,
                cache: stagedCache,
                mask: mask
            )
            h = runLayerBlock(
                layers: llamaModel.model.layers,
                range: lo..<numLayers,
                hidden: h,
                cache: stagedCache,
                mask: mask
            )

            h = llamaModel.model.norm(h)

            let stagedLogits: MLXArray
            if let lmHead = llamaModel.lmHead {
                stagedLogits = lmHead(h)
            } else {
                stagedLogits = llamaModel.model.embedTokens.asLinear(h)
            }
            eval(stagedLogits)
            let stagedArgmax = argMax(stagedLogits[0, -1], axis: -1).item(Int.self)

            XCTAssertEqual(
                stagedArgmax, fullArgmax,
                "Staged argmax (\(stagedArgmax)) must equal full-model argmax (\(fullArgmax))"
            )
        }
    }
}
