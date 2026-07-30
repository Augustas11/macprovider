// SPEC-039 AC-1/AC-2/AC-3 — real-model paged-attention GATHER parity.
//
// Ports the proven Phase-2/Phase-3 spike harness
// (`spikes/paged-attn-phase2/Sources/PagedAttnPhase2/{PagedKVCache,main}.swift`,
// recorded in `docs/research/SPIKE_PAGED_ATTN_PHASE2_RESULT_2026-07-29.md`).
//
// Each case greedy-generates (argmax) with stock `KVCacheSimple` vs `macprovider-cli`'s
// `PagedKVCache`, whose `update()` reconstructs logical K/V through the REAL Metal gather
// over a NON-identity (reversed) physical block order (blockSize 16). Correctness gate:
// token-for-token argmax equality over >= 40 generated tokens, PLUS proof the gather
// kernel actually ran (`gatherKernelCalls > 0`) over a non-degenerate, boundary-crossing
// layout (`maxLogicalBlocksObserved >= 2`, non-identity permutation).
//
// Heavy real-model fixtures — gated behind env flags so ordinary `swift test`/CI without
// the local HF cache does not fail:
//   MACPROVIDER_RUN_PAGED_PARITY=1      → AC-1 (Llama-3.2-3B), AC-2 (Qwen2.5-7B)
//   MACPROVIDER_RUN_PAGED_PARITY_MOE=1  → AC-3 (Qwen3-Coder-30B-A3B MoE, ~17GB)
//
// Models load ONLY from `~/.cache/huggingface/hub` (no download).

import Foundation
import MLX
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import Tokenizers
import XCTest

@testable import MacProviderCore
@testable import macprovider_cli

final class PagedKVParityTests: XCTestCase {

    // MARK: - Harness (ported from the spike)

    private static let blockSize = 16
    private static let nNew = 40
    private static let prompt = "Explain in one paragraph why the sky appears blue during the day."

    private func findSnapshotDir(_ modelName: String) -> String? {
        let base = ("~/.cache/huggingface/hub/models--mlx-community--\(modelName)/snapshots"
            as NSString).expandingTildeInPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for e in entries {
            let dir = base + "/" + e
            if FileManager.default.fileExists(atPath: dir + "/config.json") { return dir }
        }
        return nil
    }

    private func loadLocal(_ dir: String) async throws -> ModelContext {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        return try await LLMModelFactory.shared.load(from: url, using: #huggingFaceTokenizerLoader())
    }

    private func lastTokenArgmax(_ logits: MLXArray) -> Int32 {
        let v = logits.dim(logits.ndim - 1)
        let flat = logits.reshaped([-1, v])
        let row = flat[flat.dim(0) - 1]
        return argMax(row, axis: -1).item(Int32.self)
    }

    private func greedyGenerate(
        model: any LanguageModel, promptTokens: [Int], nNew: Int, makeCache: () -> [KVCache]
    ) -> [Int] {
        let cache = makeCache()
        var out: [Int] = []
        var y = MLXArray(promptTokens.map { Int32($0) }).reshaped([1, promptTokens.count])
        for _ in 0 ..< nNew {
            let logits = model(y, cache: cache)
            let next = lastTokenArgmax(logits)
            eval(cache.flatMap { $0.state })
            out.append(Int(next))
            y = MLXArray([next]).reshaped([1, 1])
        }
        return out
    }

    private func firstDivergence(_ a: [Int], _ b: [Int]) -> Int? {
        for i in 0 ..< min(a.count, b.count) where a[i] != b[i] { return i }
        return a.count == b.count ? nil : min(a.count, b.count)
    }

    /// Generous descriptor/binding: metadata only (SPEC-038-facing surface). `update()`
    /// holds K/V in-tensor and never touches the allocator, so a single value-type binding
    /// is reused for every layer.
    private func makePagedCacheFactory(modelName: String, nLayers: Int) async throws -> () -> [KVCache] {
        let maxBlocks = 512
        let descriptor = PagedKVDescriptor(
            blockSizeTokens: Self.blockSize,
            maxPhysicalBlocks: maxBlocks,
            modelID: "mlx-community/\(modelName)",
            modelSHA256: String(repeating: "0", count: 64),
            supportedModelFamilies: ["llama", "qwen"],
            supportsMoEDispatch: true,
            metallibSHA256: String(repeating: "0", count: 64),
            kernelIdentifier: PagedKVGatherKernel.registeredKernelName,
            parityLabel: "sdpa-parity-v1"
        )
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: Self.blockSize, maxPhysicalBlocks: maxBlocks)
        let handle = try await allocator.allocate(
            conversationKey: "parity-\(modelName)",
            maxTokens: Self.blockSize * maxBlocks,
            initialTokens: 0
        )
        let binding = try await allocator.binding(for: handle)
        return { (0 ..< nLayers).map { _ in PagedKVCache(descriptor: descriptor, binding: binding) } }
    }

    private struct ParityOutcome {
        let match: Bool
        let n: Int
        let nLayers: Int
        let firstDiff: Int?
        let kernelCalls: Int
        let maxBlocks: Int
        let nonIdentity: Bool
        let stockText: String
        let pagedText: String
    }

    private func runParity(modelName: String) async throws -> ParityOutcome {
        guard let dir = findSnapshotDir(modelName) else {
            throw XCTSkip("snapshot for \(modelName) not found in local HF cache")
        }
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
        let ctx = try await loadLocal(dir)
        let model = ctx.model
        let promptTokens = ctx.tokenizer.encode(text: Self.prompt)
        let sampleCache = model.newCache(parameters: nil)
        let nLayers = sampleCache.count
        let cacheTypes = Dictionary(
            grouping: sampleCache.map { String(describing: type(of: $0)) }, by: { $0 }
        ).mapValues { $0.count }
        print("  [\(modelName)] loaded; layers=\(nLayers); promptTokens=\(promptTokens.count); "
            + "newCache types=\(cacheTypes)")

        let stock = greedyGenerate(model: model, promptTokens: promptTokens, nNew: Self.nNew) {
            (0 ..< nLayers).map { _ in KVCacheSimple() }
        }

        PagedKVCache.resetGatherDiagnostics()
        let pagedFactory = try await makePagedCacheFactory(modelName: modelName, nLayers: nLayers)
        let paged = greedyGenerate(model: model, promptTokens: promptTokens, nNew: Self.nNew, makeCache: pagedFactory)

        let calls = PagedKVCache.gatherKernelCalls
        let fd = firstDivergence(stock, paged)
        return ParityOutcome(
            match: fd == nil && stock.count == paged.count,
            n: Self.nNew,
            nLayers: nLayers,
            firstDiff: fd,
            kernelCalls: calls,
            maxBlocks: PagedKVCache.maxLogicalBlocksObserved,
            nonIdentity: PagedKVCache.observedNonIdentityPermutation,
            stockText: ctx.tokenizer.decode(tokenIds: stock),
            pagedText: ctx.tokenizer.decode(tokenIds: paged)
        )
    }

    private func assertParity(_ modelName: String, _ label: String) async throws {
        let r = try await runParity(modelName: modelName)
        print("  [\(label)] \(modelName): PARITY \(r.match ? "PASS" : "FAIL") "
            + "\(r.match ? r.n : (r.firstDiff ?? -1))/\(r.n) tokens; gatherKernelCalls=\(r.kernelCalls); "
            + "maxLogicalBlocks=\(r.maxBlocks); nonIdentityPermutation=\(r.nonIdentity)")
        if !r.match {
            print("    stock: \(r.stockText)")
            print("    paged: \(r.pagedText)")
        }
        XCTAssertTrue(r.match, "\(label) \(modelName): paged gather output diverged from stock at token \(String(describing: r.firstDiff))")

        // EXACT call-count identity (FR-PKV4): the real gather must run for EVERY layer at
        // EVERY forward pass, over BOTH K and V — never bypassed for a single layer/step.
        //   greedyGenerate performs exactly `nNew` forward passes (the loop runs nNew times:
        //   one prefill pass over the prompt, then decode passes, nNew total). Each forward
        //   pass drives `model(y, cache:)`, which calls `update()` once per layer (nLayers),
        //   and each `update()` invokes `pagedGather` twice — once for keys, once for values.
        //   Therefore gatherKernelCalls == nLayers * nNew * 2, an exact equality (e.g. the
        //   28-layer Llama-3.2-3B over 40 passes → 28*40*2 = 2240).
        let expectedCalls = r.nLayers * r.n * 2
        XCTAssertEqual(
            r.kernelCalls, expectedCalls,
            "\(label): gather ran \(r.kernelCalls) times; expected exactly nLayers(\(r.nLayers)) * nNew(\(r.n)) * 2 = \(expectedCalls) — a per-layer/per-step/per-tensor gather"
        )
        XCTAssertGreaterThanOrEqual(r.maxBlocks, 3, "\(label): layout degenerate (< 3 blocks) — not a robust multi-block/boundary-crossing gather")
        XCTAssertTrue(r.nonIdentity, "\(label): physical permutation was identity — gather not meaningfully exercised")
    }

    // MARK: - AC-1 dense Llama

    func testAC1_DenseLlama_3_2_3B_ParityWithRealGather() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPROVIDER_RUN_PAGED_PARITY"] == "1",
            "set MACPROVIDER_RUN_PAGED_PARITY=1 to run real-model paged parity (needs local HF model)"
        )
        try await assertParity("Llama-3.2-3B-Instruct-4bit", "AC-1")
    }

    // MARK: - AC-2 dense Qwen

    func testAC2_DenseQwen2_5_7B_ParityWithRealGather() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPROVIDER_RUN_PAGED_PARITY"] == "1",
            "set MACPROVIDER_RUN_PAGED_PARITY=1 to run real-model paged parity (needs local HF model)"
        )
        try await assertParity("Qwen2.5-7B-Instruct-4bit", "AC-2")
    }

    // MARK: - AC-3 MoE Qwen3 (~17GB — separately gated)

    func testAC3_MoEQwen3Coder30B_ParityWithRealGather() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPROVIDER_RUN_PAGED_PARITY_MOE"] == "1",
            "set MACPROVIDER_RUN_PAGED_PARITY_MOE=1 to run the heavy 30B MoE paged parity (~17GB)"
        )
        try await assertParity("Qwen3-Coder-30B-A3B-Instruct-4bit", "AC-3")
    }
}
