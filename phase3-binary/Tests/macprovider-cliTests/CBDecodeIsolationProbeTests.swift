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
//   MACPROVIDER_DECODE_ISOLATION_WINDOW=<steps per lockstep window> (optional,
//     default the serve window, 16)
//   MACPROVIDER_DECODE_ISOLATION_STEPS=<total steps> (optional, default the window)
//   MACPROVIDER_DECODE_ISOLATION_ROWS_PER_FORWARD=<n> (optional; default the
//     device decode row bound, 0 = every row in one forward)
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
        // Rows decode in lockstep windows of this many steps on one set of
        // batch caches, as the serve path does (16 for every layout).
        let window = Int(environment["MACPROVIDER_DECODE_ISOLATION_WINDOW"] ?? "")
            ?? ModelRuntime.servePathDecodeLockstepWindow(cacheKinds: [.recurrentMamba, .pagedAttention])
        let steps = Int(environment["MACPROVIDER_DECODE_ISOLATION_STEPS"] ?? "") ?? max(4, window)
        // Rows per decode forward: the device decode row bound (capped) by
        // default; MACPROVIDER_DECODE_ISOLATION_ROWS_PER_FORWARD=0 puts every
        // row in one forward (uncapped).
        let rowsPerForward: Int = {
            let raw = Int(environment["MACPROVIDER_DECODE_ISOLATION_ROWS_PER_FORWARD"] ?? "")
            if raw == 0 { return Int.max }
            return raw ?? ContinuousBatchDecodeRouteBound.maxDecodeRowsPerForward(
                architecture: ModelRuntime.metalArchitectureForQuantizedRoutes()
            )
        }()
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
            let rowIDs = rows.map { ids[$0] }
            var done = 0
            while done < steps {
                let windowSteps = min(window, steps - done)
                // The scheduler decodes at most `rowsPerForward` rows in one
                // forward and the rest in consecutive forwards.
                for start in stride(from: 0, to: rowIDs.count, by: rowsPerForward) {
                    let part = Array(rowIDs[start ..< min(start + rowsPerForward, rowIDs.count)])
                    let perStep = try await backend.sharedDecodeLogitsForTest(
                        requestIDs: part,
                        tokens: part.map { current[$0]! },
                        steps: windowSteps
                    )
                    for logits in perStep {
                        for (index, id) in part.enumerated() {
                            let next = logits[index].indices.max { logits[index][$0] < logits[index][$1] }!
                            result[id, default: ([], [])].logits.append(logits[index])
                            result[id, default: ([], [])].tokens.append(next)
                            current[id] = next
                        }
                    }
                }
                done += windowSteps
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
                print("decode-isolation rows=\(lengths.count) rows_per_forward=\(rowsPerForward == Int.max ? "all" : String(rowsPerForward)) window=\(window) row=\(row) keys=\(lengths[row]) step=\(step) logits_bitwise=\(equal) max_abs_diff=\(gap) lone_token=\(lone.tokens[step]) batched_token=\(shared.tokens[step])")
                if !equal || lone.tokens[step] != shared.tokens[step] {
                    failures.append("row \(row) (\(lengths[row]) keys) step \(step): max |diff| \(gap)")
                }
            }
        }
        XCTAssertEqual(failures, [], "batched decode rows differ from their lone runs")
    }

    /// Packed native-MTP verification: each row verifies `width` columns
    /// (its last token and `width - 1` proposals), so a shared verify feeds
    /// rows x width tokens into every quantized matmul. Each row's verify
    /// logits must be bit-identical to the same row verified alone.
    /// `MACPROVIDER_DECODE_ISOLATION_VERIFY_WIDTH` (default 2, one proposal, the
    /// hybrid packed-verify maximum) sets the width.
    func testServedModelVerifyRowsMatchTheirLoneLogitsBitwise() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["MACPROVIDER_DECODE_ISOLATION_MODEL"], !directory.isEmpty,
              environment["MACPROVIDER_DECODE_ISOLATION_VERIFY"] == "1"
        else {
            throw XCTSkip("set MACPROVIDER_DECODE_ISOLATION_MODEL and MACPROVIDER_DECODE_ISOLATION_VERIFY=1")
        }
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
        let lengths = (environment["MACPROVIDER_DECODE_ISOLATION_LENGTHS"] ?? "600,901,1501,3000,9000")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let width = Int(environment["MACPROVIDER_DECODE_ISOLATION_VERIFY_WIDTH"] ?? "") ?? 2
        // Target tokens per verify forward: the backend's device bound by
        // default; MACPROVIDER_DECODE_ISOLATION_ROWS_PER_FORWARD=0 verifies
        // every row in one forward (uncapped).
        let verifyTokensPerForward = environment["MACPROVIDER_DECODE_ISOLATION_ROWS_PER_FORWARD"] == "0"
            ? Int.max
            : PagedKVSharedForwardBackend.deviceVerifyTokenBound
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

        func run(_ rows: [Int]) async throws -> [String: [Float]] {
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
            var tokenRows: [[Int]] = []
            for row in rows {
                let prompt = prompts[row]
                let handle = try await allocator.allocate(conversationKey: ids[row], maxTokens: prompt.count + width + 8)
                var first = 0
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
                    if end == prompt.count { first = try XCTUnwrap(output.first?.sampledToken, ids[row]) }
                }
                // Fixed proposals: the verify forward's numerics do not depend
                // on whether they would be accepted.
                tokenRows.append([first] + (1 ..< width).map { 2_000 + 37 * $0 + row })
            }
            // The backend verifies a round in consecutive forwards of at most
            // `verifyTokensPerForward` target tokens (rows x width).
            var logits: [[Float]] = []
            for group in PagedKVSharedForwardBackend.verifyGroups(
                widths: tokenRows.map(\.count),
                maxTokens: verifyTokensPerForward
            ) {
                logits += try await backend.sharedVerifyLogitsForTest(
                    requestIDs: group.map { ids[rows[$0]] },
                    tokenRows: Array(tokenRows[group])
                )
            }
            return Dictionary(uniqueKeysWithValues: zip(rows.map { ids[$0] }, logits))
        }

        let batched = try await run(Array(lengths.indices))
        var failures: [String] = []
        for row in lengths.indices {
            let id = ids[row]
            let lone = try await run([row])[id]!
            let shared = batched[id]!
            let gap = zip(lone, shared).map { abs($0 - $1) }.max() ?? 0
            let vocabulary = lone.count / width
            let argmax = { (logits: [Float]) in
                (0 ..< width).map { column in
                    let slice = logits[column * vocabulary ..< (column + 1) * vocabulary]
                    return slice.indices.max { slice[$0] < slice[$1] }! - column * vocabulary
                }
            }
            print("verify-isolation rows=\(lengths.count) tokens_per_forward=\(verifyTokensPerForward == Int.max ? "all" : String(verifyTokensPerForward)) width=\(width) row=\(row) keys=\(lengths[row]) logits_bitwise=\(lone == shared) max_abs_diff=\(gap) lone_top=\(argmax(lone)) batched_top=\(argmax(shared))")
            if lone != shared { failures.append("row \(row) (\(lengths[row]) keys): max |diff| \(gap)") }
        }
        XCTAssertEqual(failures, [], "batched verify rows differ from their lone runs")
    }
}
