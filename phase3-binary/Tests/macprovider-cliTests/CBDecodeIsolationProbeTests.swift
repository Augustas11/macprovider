// SPEC-038 FR-CB2 decode-isolation probe on a served model (Studio only).
//
// Rows of different lengths are prefilled alone, then decoded together in one
// shared forward (the backend's uncompiled decode step) and, separately, each
// row alone. Every step's last-position logits must be bit-identical and the
// greedy tokens equal. Row lengths default to 600/901/1501/3000/9000 tokens,
// spanning the one-pass / two-pass switch (1024 keys) of the vector attention
// kernels and their partition-count switches.
//
// Heavy real-model fixture, skipped unless set:
//   MACPROVIDER_DECODE_ISOLATION_MODEL=<model directory>
//   MACPROVIDER_DECODE_ISOLATION_LENGTHS=600,901,1501,3000,9000 (optional)
//   MACPROVIDER_DECODE_ISOLATION_STEPS=4 (optional)
// The fused A3B MoE path follows `MLX_LM_QWEN35_FUSED_MOE` as in serving.

import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import XCTest

@testable import MacProviderCore
@testable import macprovider_cli

final class CBDecodeIsolationProbeTests: XCTestCase {
    func testServedModelDecodeRowsMatchTheirLoneLogitsBitwise() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["MACPROVIDER_DECODE_ISOLATION_MODEL"], !directory.isEmpty else {
            throw XCTSkip("set MACPROVIDER_DECODE_ISOLATION_MODEL to a local model directory")
        }
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        let lengths = (environment["MACPROVIDER_DECODE_ISOLATION_LENGTHS"] ?? "600,901,1501,3000,9000")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let steps = Int(environment["MACPROVIDER_DECODE_ISOLATION_STEPS"] ?? "") ?? 4
        let container = try await LLMModelFactory.shared.loadContainer(
            from: URL(fileURLWithPath: directory),
            using: #huggingFaceTokenizerLoader()
        )
        let cacheKinds = try await container.perform { context in
            try context.model.newCache(parameters: nil as GenerateParameters?).map { cache in
                try XCTUnwrap(PagedKVSharedForwardBackend.CacheKind.recognized(from: cache))
            }
        }
        let ids = lengths.indices.map { "row-\($0)" }
        let prompts = lengths.enumerated().map { row, length in
            (0 ..< length).map { 1_000 + ($0 * 7_919 + row * 104_729) % 30_000 }
        }

        func run(_ rows: [Int]) async throws -> [String: (logits: [[Float]], tokens: [Int])] {
            let blockSize = 32
            let blocks = 4_096
            let backend = PagedKVSharedForwardBackend(
                container: container,
                blockSizeTokens: blockSize,
                maxPhysicalBlocks: blocks,
                poolEpoch: 1,
                layerCount: cacheKinds.count,
                cacheKinds: cacheKinds
            )
            let allocator = try PagedKVBlockAllocator(blockSizeTokens: blockSize, maxPhysicalBlocks: blocks)
            var current: [String: Int] = [:]
            for row in rows {
                let prompt = prompts[row]
                let handle = try await allocator.allocate(conversationKey: ids[row], maxTokens: prompt.count + steps + 8)
                // Each row prefills alone, in the scheduler's 512-token chunks.
                for start in stride(from: 0, to: prompt.count, by: 512) {
                    let end = min(start + 512, prompt.count)
                    _ = try await allocator.extend(handle, by: end - start)
                    let output = try await backend.prefill(rows: [ContinuousBatchPrefillInput(
                        requestID: ids[row],
                        promptTokens: Array(prompt[start ..< end]),
                        binding: try await allocator.binding(for: handle),
                        promptTokenOffset: start,
                        committedKVTokenCount: start,
                        targetKVTokenCount: end,
                        isFinalChunk: end == prompt.count
                    )])
                    XCTAssertNil(output.first?.failureCode, ids[row])
                    if end == prompt.count {
                        current[ids[row]] = try XCTUnwrap(output.first?.sampledToken, ids[row])
                    }
                }
            }
            var result: [String: (logits: [[Float]], tokens: [Int])] = [:]
            for _ in 0 ..< steps {
                let rowIDs = rows.map { ids[$0] }
                let logits = try await backend.sharedDecodeLogitsForTest(
                    requestIDs: rowIDs,
                    tokens: rowIDs.map { current[$0]! }
                )
                for (index, id) in rowIDs.enumerated() {
                    let next = logits[index].indices.max { logits[index][$0] < logits[index][$1] }!
                    result[id, default: ([], [])].logits.append(logits[index])
                    result[id, default: ([], [])].tokens.append(next)
                    current[id] = next
                }
            }
            return result
        }

        let batched = try await run(Array(lengths.indices))
        var failures: [String] = []
        for row in lengths.indices {
            let id = ids[row]
            let lone = try await run([row])[id]!
            let shared = batched[id]!
            for step in 0 ..< steps {
                let equal = lone.logits[step] == shared.logits[step]
                let gap = zip(lone.logits[step], shared.logits[step]).map { abs($0 - $1) }.max() ?? 0
                print("decode-isolation row=\(row) keys=\(lengths[row]) step=\(step) logits_bitwise=\(equal) max_abs_diff=\(gap) lone_token=\(lone.tokens[step]) batched_token=\(shared.tokens[step])")
                if !equal || lone.tokens[step] != shared.tokens[step] {
                    failures.append("row \(row) (\(lengths[row]) keys) step \(step): max |diff| \(gap)")
                }
            }
        }
        XCTAssertEqual(failures, [], "batched decode rows differ from their lone runs")
    }
}
