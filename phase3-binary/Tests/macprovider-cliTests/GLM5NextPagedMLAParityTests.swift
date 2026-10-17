// SPEC-039 FR-PKV4 / AC-20 — `glm5_next` paged MLA exact parity on the real
// admitted artifact.
//
// Greedy-generates with the stock `GLM5NextAttentionCache` and with
// `PagedMLALatentCache` (parity scaffold: the latent and the pooled keys are
// both read back through the registered `macprovider_paged_kv_gather_v1`
// kernel over one reversed block order), both prefilled in production
// 512-token chunks, and checks every FR-PKV4 `glm5_next` rule:
//   1. block size a multiple of `index_kpool`; both buffers on one table,
//      non-identity permutation;
//   2. prompt of at least `index_topk + 2 x block` tokens (dense bypass off);
//   3. decode crosses a latent block boundary and completes a pool window;
//   4. gather on the latent and the pooled keys of every sparse layer in every
//      prefill chunk and decode forward (exact call count);
//   5. byte-equal row-local pending window (and every other cache array);
//   6. at least 48 exact greedy tokens.
// It then runs the attach-time probes the runtime uses
// (`PagedKVRuntimeParityProbe`) and checks they meet the measurement gate.
//
// Environment-gated (real weights): set MACPROVIDER_GLM53_ARTIFACT_DIR to the
// admitted artifact directory. Skipped without it.

import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import XCTest

@testable import MacProviderCore
@testable import macprovider_cli

final class GLM5NextPagedMLAParityTests: XCTestCase {
    private static let blockSize = 256
    private static let generatedTokens = 48
    private static let chunk = ContinuousBatchSchedulerConfiguration.defaultPromptChunkTokens

    func testAC20_GLM5NextPagedMLAExactParityOnTheAdmittedArtifact() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["MACPROVIDER_GLM53_ARTIFACT_DIR"], !raw.isEmpty else {
            throw XCTSkip("MACPROVIDER_GLM53_ARTIFACT_DIR is not set")
        }
        let directory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }

        // The catalog identity's verified layout, from the artifact's own config.
        let capabilities = ModelRuntime.pagedKVModelCapabilities(
            modelID: "zai-org/glm-5.3-flash",
            configJSONData: configData
        )
        let layout = try XCTUnwrap(capabilities.sparseAttention, "artifact config is not the admitted glm5_next layout")
        XCTAssertTrue(capabilities.hybridDecoderArchitectureVerified)
        // Rule 1: one block table holds whole pool windows.
        XCTAssertTrue(PagedMLALatentCache.blockSizeIsValid(Self.blockSize, kpool: layout.indexKpool))
        let span = capabilities.attachProbePromptTokens(blockSizeTokens: Self.blockSize)
        XCTAssertGreaterThanOrEqual(span, layout.indexTopk + 2 * Self.blockSize)
        // Rule 2 and 3: past `index_topk` before decode, and the decode
        // crosses the next latent block boundary (16 tokens in) and completes
        // pool windows (the prompt ends on a window boundary).
        let promptCount = span + Self.blockSize - 16
        XCTAssertEqual(promptCount % layout.indexKpool, 0)
        XCTAssertGreaterThan(promptCount, layout.indexTopk)

        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: #huggingFaceTokenizerLoader()
        )
        let seed = await container.perform { context in
            context.tokenizer.encode(text: Self.seedText, addSpecialTokens: true)
        }
        let prompt = Self.varied(seed, count: promptCount)

        let outcome: Outcome = try await container.perform { context in
            let model = context.model
            let stockCaches = try model.newCache(parameters: nil)
            let kinds = try stockCaches.map { try XCTUnwrap(PagedKVSharedForwardBackend.CacheKind.recognized(from: $0)) }
            XCTAssertTrue(ModelRuntime.measuredMixedPagedKVTopology(kinds, modelCapabilities: capabilities))
            let sparseIndices = kinds.indices.filter { kinds[$0].isPagedMLA }

            let stock = Self.greedy(model: model, prompt: prompt, caches: stockCaches)

            PagedKVCache.resetGatherDiagnostics()
            let binding = Self.detachedBinding()
            let pagedCaches: [KVCache] = kinds.map { kind in
                guard case .pagedMLA(let kpool) = kind else { return MambaCache() }
                return PagedMLALatentCache(
                    kpool: kpool,
                    blockSizeTokens: Self.blockSize,
                    maxPhysicalBlocks: 1024,
                    poolEpoch: 1,
                    binding: binding,
                    reconstructViaGather: true
                )
            }
            let paged = Self.greedy(model: model, prompt: prompt, caches: pagedCaches)
            let calls = PagedKVCache.gatherKernelCalls

            var stateMismatches: [String] = []
            for index in stockCaches.indices {
                let lhs = stockCaches[index].state
                let rhs = pagedCaches[index].state
                guard lhs.count == rhs.count else {
                    stateMismatches.append("layer \(index): \(lhs.count) vs \(rhs.count) arrays")
                    continue
                }
                for (slot, (a, b)) in zip(lhs, rhs).enumerated() where !Self.equal(a, b) {
                    stateMismatches.append("layer \(index) state[\(slot)] \(a.shape) vs \(b.shape)")
                }
            }
            let pendingWindows = sparseIndices.map { index -> Int in
                let state = pagedCaches[index].state
                return state.count > 2 ? (state[2].size == 0 ? 0 : state[2].dim(1)) : -1
            }
            return Outcome(
                stock: stock,
                paged: paged,
                sparseLayers: sparseIndices.count,
                gatherCalls: calls,
                maxLogicalBlocks: PagedKVCache.maxLogicalBlocksObserved,
                nonIdentity: PagedKVCache.observedNonIdentityPermutation,
                stateMismatches: stateMismatches,
                pendingWindows: pendingWindows,
                finalOffset: pagedCaches[sparseIndices[0]].offset
            )
        }

        print("  [AC-20 glm5_next] prompt=\(promptCount) tokens=\(outcome.paged.count) sparseLayers=\(outcome.sparseLayers) "
            + "gatherCalls=\(outcome.gatherCalls) maxLogicalBlocks=\(outcome.maxLogicalBlocks) "
            + "nonIdentity=\(outcome.nonIdentity) pending=\(outcome.pendingWindows) stateMismatches=\(outcome.stateMismatches.count)")
        // Rule 6.
        XCTAssertEqual(outcome.stock.count, Self.generatedTokens)
        XCTAssertEqual(outcome.paged, outcome.stock, "paged MLA greedy tokens diverged from the stock cache")
        // Rule 4: every sparse layer gathers its latent and its pooled keys in
        // every forward (prefill chunks, then one forward per token).
        let forwards = PagedKVRuntimeParityProbe.prefillChunkForwards(promptTokens: promptCount) + Self.generatedTokens
        XCTAssertEqual(outcome.sparseLayers, layout.layerTypes.filter { $0 == PagedKVSparseAttentionLayout.sparseLayerType }.count)
        XCTAssertEqual(outcome.gatherCalls, outcome.sparseLayers * forwards * 2)
        // Rule 1: a non-degenerate, non-identity layout.
        XCTAssertGreaterThanOrEqual(outcome.maxLogicalBlocks, 3)
        XCTAssertTrue(outcome.nonIdentity)
        // Rule 3: the decode crossed a block boundary and completed a window.
        // The last generated token is sampled, not appended, so the caches hold
        // the prompt plus all but the last generated token.
        let decoded = Self.generatedTokens - 1
        XCTAssertEqual(outcome.finalOffset, promptCount + decoded)
        XCTAssertGreaterThan(
            PagedKVBlockLayout.blockCount(tokens: promptCount + decoded, blockSizeTokens: Self.blockSize),
            PagedKVBlockLayout.blockCount(tokens: promptCount, blockSizeTokens: Self.blockSize)
        )
        XCTAssertGreaterThanOrEqual(decoded, layout.indexKpool)
        // Rule 5: every cache array, the pending window included, byte-equal;
        // the window is non-empty so the comparison covers it.
        XCTAssertEqual(outcome.stateMismatches, [])
        XCTAssertTrue(outcome.pendingWindows.allSatisfy { $0 == (promptCount + decoded) % layout.indexKpool })
        XCTAssertNotEqual((promptCount + decoded) % layout.indexKpool, 0)

        // The attach-time probes on the same identity meet the measurement gate.
        let probe = await PagedKVRuntimeParityProbe.runParityProbe(
            container: container,
            modelID: "zai-org/glm-5.3-flash",
            blockSizeTokens: Self.blockSize,
            maxPhysicalBlocks: 1024,
            promptTokens: Self.varied(seed, count: span),
            nNew: 32
        )
        print("  [AC-20 glm5_next attach probe] established=\(probe.established) nLayers=\(probe.nLayers) "
            + "nForwards=\(probe.nForwards) gatherCalls=\(probe.gatherKernelCalls)")
        XCTAssertTrue(probe.established)
        XCTAssertEqual(probe.nLayers, outcome.sparseLayers)
        XCTAssertEqual(probe.gatherKernelCalls, probe.nLayers * probe.nForwards * 2)
        XCTAssertGreaterThanOrEqual(probe.maxLogicalBlocks, 3)
        XCTAssertTrue(probe.nonIdentityPermutation)
    }

    // MARK: - Harness

    private struct Outcome: Sendable {
        let stock: [Int]
        let paged: [Int]
        let sparseLayers: Int
        let gatherCalls: Int
        let maxLogicalBlocks: Int
        let nonIdentity: Bool
        let stateMismatches: [String]
        let pendingWindows: [Int]
        let finalOffset: Int
    }

    private static let seedText = """
        Harbor log, autumn survey. The tide tables list the morning low at 06:12 and the \
        evening high at 18:47; the pilot boat moved the red channel buoy two lengths east \
        after the gale. Inventory: 14 coils of mooring line, 3 spare lamp mantles, 41 litres \
        of kerosene, one cracked lens awaiting the glazier from the mainland. Notes on the \
        fishing fleet: the Marigold returned light, the Petrel reported a seal colony on the \
        north skerry, and the ferry schedule shifts to winter hours on the first Monday.
        """

    /// `count` prompt tokens that do not repeat with a short period: the seed
    /// tokens interleaved with a slowly varying offset into the seed.
    private static func varied(_ seed: [Int], count: Int) -> [Int] {
        guard !seed.isEmpty else { return [] }
        return (0 ..< count).map { index in
            seed[(index * 7 + index / seed.count) % seed.count]
        }
    }

    /// Production chunking: 512-token prompt chunks, the last chunk samples
    /// the first token, then one forward per token.
    private static func greedy(model: any LanguageModel, prompt: [Int], caches: [KVCache]) -> [Int] {
        var offset = 0
        while prompt.count - offset > chunk {
            let tokens = MLXArray(prompt[offset ..< offset + chunk].map(Int32.init)).reshaped([1, chunk])
            _ = model(tokens, cache: caches)
            eval(caches.flatMap { $0.state })
            offset += chunk
        }
        var input = MLXArray(prompt[offset...].map(Int32.init)).reshaped([1, prompt.count - offset])
        var out: [Int] = []
        for _ in 0 ..< generatedTokens {
            let logits = model(input, cache: caches)
            let width = logits.dim(logits.ndim - 1)
            let flat = logits.reshaped([-1, width])
            let next = argMax(flat[flat.dim(0) - 1], axis: -1).item(Int32.self)
            eval(caches.flatMap { $0.state })
            out.append(Int(next))
            input = MLXArray([next]).reshaped([1, 1])
        }
        return out
    }

    private static func equal(_ lhs: MLXArray, _ rhs: MLXArray) -> Bool {
        lhs.shape == rhs.shape && lhs.dtype == rhs.dtype && (lhs.size == 0 || all(lhs .== rhs).item(Bool.self))
    }

    private static func detachedBinding() -> PagedKVStorageBinding {
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "glm5-next-ac20", poolEpoch: 1)
        return PagedKVStorageBinding(
            handle: handle,
            blockSizeTokens: blockSize,
            maxLogicalTokens: blockSize * 1024,
            currentTable: PagedKVBlockTable(
                handleID: handle.handleID,
                blockSizeTokens: blockSize,
                logicalTokenCount: 0,
                physicalBlocks: [],
                tailValidTokenCount: 0,
                poolEpoch: 1
            ),
            poolEpoch: 1
        )
    }
}
