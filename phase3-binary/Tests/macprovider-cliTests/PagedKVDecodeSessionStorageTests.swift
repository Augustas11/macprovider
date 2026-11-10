import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// A decode session's batch buffers are the only K/V of the rows riding it:
/// rows hold no buffers of their own while attached and get an exact copy of
/// their history back when they leave the batch (finish, eviction, a prompt
/// chunk) or are written outside it. Greedy tokens must match each row run
/// alone and a plain serial `KVCacheSimple` run.
final class PagedKVDecodeSessionStorageTests: XCTestCase {
    private static let blockSizeTokens = 16
    private static let maxPhysicalBlocks = 1024
    private static let chunkTokens = ContinuousBatchSchedulerConfiguration.defaultPromptChunkTokens

    // MARK: - Batch layer cache

    /// Ragged rows attached to one batch: every step's presented K/V and each
    /// row's own view of its history equal a row cache that took the same
    /// updates alone. A row leaving the batch gets that same history in
    /// buffers of its own, and a row written outside the batch (update, trim)
    /// copies its history out first, so the batch and the row stay exact.
    func testAttachedRowsMatchStandaloneRowsAndGetTheirHistoryBackOnLeaving() throws {
        try requireMetal()
        let lengths = [5, 17, 33]
        let heads = 2
        let dim = 4
        MLXRandom.seed(2275)
        let rows = lengths.map { _ in Self.rowCache() }
        let references = lengths.map { _ in Self.rowCache() }
        for (index, length) in lengths.enumerated() {
            let keys = MLXRandom.normal([1, heads, length, dim])
            let values = MLXRandom.normal([1, heads, length, dim])
            _ = rows[index].update(keys: keys, values: values)
            _ = references[index].update(keys: keys, values: values)
        }

        let batch = PagedKVSharedForwardBackend.batchLayerCacheForTest(rowCaches: rows, attachRows: true)
        XCTAssertTrue(rows.allSatisfy { !$0.holdsOwnKVBuffers }, "attached rows must not keep their own K/V")
        try Self.assertRows(rows, equal: references, "after attach")

        func step(_ label: String) throws {
            let keys = MLXRandom.normal([rows.count, heads, 1, dim])
            let values = MLXRandom.normal([rows.count, heads, 1, dim])
            let (presentedKeys, presentedValues) = batch.update(keys: keys, values: values)
            for (index, reference) in references.enumerated() {
                _ = reference.update(
                    keys: keys[index ..< index + 1, 0..., 0..., 0...],
                    values: values[index ..< index + 1, 0..., 0..., 0...]
                )
                let stored = reference.state
                let tokens = reference.storedTokens
                XCTAssertTrue(arrayEqual(presentedKeys[index ..< index + 1, 0..., ..<tokens, 0...], stored[0]).item(Bool.self), "\(label) row \(index) keys")
                XCTAssertTrue(arrayEqual(presentedValues[index ..< index + 1, 0..., ..<tokens, 0...], stored[1]).item(Bool.self), "\(label) row \(index) values")
            }
            try Self.assertRows(rows, equal: references, label)
        }

        for index in 0 ..< 3 { try step("step \(index)") }
        XCTAssertTrue(rows.allSatisfy { !$0.holdsOwnKVBuffers }, "in-batch steps must not copy K/V into the rows")

        // A prompt chunk (or any write) on an attached row copies its history
        // out, then appends; the batch rebuilds from the rows on its next step.
        let chunkKeys = MLXRandom.normal([1, heads, 3, dim])
        let chunkValues = MLXRandom.normal([1, heads, 3, dim])
        _ = rows[1].update(keys: chunkKeys, values: chunkValues)
        _ = references[1].update(keys: chunkKeys, values: chunkValues)
        XCTAssertTrue(rows[1].holdsOwnKVBuffers)
        try Self.assertRows(rows, equal: references, "after an outside write")
        rows[2].trim(4)
        references[2].trim(4)
        try Self.assertRows(rows, equal: references, "after an outside trim")
        try step("step after outside writes")

        PagedKVSharedForwardBackend.detachBatchRowsForTest(batch)
        XCTAssertTrue(rows.allSatisfy(\.holdsOwnKVBuffers), "rows leaving the batch must own their K/V")
        try Self.assertRows(rows, equal: references, "after leaving")
        // The rows' copies are their own: they keep decoding alone exactly.
        for (row, reference) in zip(rows, references) {
            let keys = MLXRandom.normal([1, heads, 1, dim])
            let values = MLXRandom.normal([1, heads, 1, dim])
            _ = row.update(keys: keys, values: values)
            _ = reference.update(keys: keys, values: values)
        }
        try Self.assertRows(rows, equal: references, "decoding alone after leaving")
    }

    /// Equal-length rows take the lockstep path, which writes only the batch:
    /// a window end moves the attached rows' lengths without copying K/V, and
    /// leaving hands back the full history.
    func testLockstepAttachedRowsSyncLengthsAndLeaveWithTheirHistory() throws {
        try requireMetal()
        let heads = 2
        let dim = 4
        MLXRandom.seed(2276)
        let rows = (0 ..< 2).map { _ in Self.rowCache() }
        let references = (0 ..< 2).map { _ in Self.rowCache() }
        for index in rows.indices {
            let keys = MLXRandom.normal([1, heads, 20, dim])
            let values = MLXRandom.normal([1, heads, 20, dim])
            _ = rows[index].update(keys: keys, values: values)
            _ = references[index].update(keys: keys, values: values)
        }
        let batch = PagedKVSharedForwardBackend.batchLayerCacheForTest(rowCaches: rows, attachRows: true)
        for _ in 0 ..< 4 {
            let keys = MLXRandom.normal([2, heads, 1, dim])
            let values = MLXRandom.normal([2, heads, 1, dim])
            _ = batch.update(keys: keys, values: values)
            for index in rows.indices {
                _ = references[index].update(
                    keys: keys[index ..< index + 1, 0..., 0..., 0...],
                    values: values[index ..< index + 1, 0..., 0..., 0...]
                )
            }
        }
        // Window end: `syncRowsFromBatch` moves lengths; rows stay attached.
        PagedKVSharedForwardBackend.syncBatchRowsForTest(batch)
        XCTAssertTrue(rows.allSatisfy { !$0.holdsOwnKVBuffers })
        try Self.assertRows(rows, equal: references, "after window sync")
        PagedKVSharedForwardBackend.detachBatchRowsForTest(batch)
        XCTAssertTrue(rows.allSatisfy(\.holdsOwnKVBuffers))
        try Self.assertRows(rows, equal: references, "after leaving")
    }

    /// A row joining a session: packing the new batch one layer at a time and
    /// dropping each replaced layer right after keeps the peak near the new
    /// batch alone. Packing every layer lazily held the old batch, the joining
    /// row's own K/V and the new batch together. The rows keep exact K/V.
    func testLayerByLayerSessionReplacementFreesTheOldBatchAndJoiningRowCopy() throws {
        try requireMetal()
        let layers = 8
        let heads = 8
        let dim = 64
        let lengths = [512, 1_024, 2_048]
        let joiningLength = 4_096
        let previousCacheLimit = Memory.cacheLimit
        Memory.cacheLimit = 0
        defer { Memory.cacheLimit = previousCacheLimit }

        func setUp(_ salt: Int) -> (old: [any KVCache], rows: [[PagedKVCache]], references: [[PagedKVCache]]) {
            MLXRandom.seed(UInt64(2300 + salt))
            var old: [any KVCache] = []
            var rows: [[PagedKVCache]] = []
            var references: [[PagedKVCache]] = []
            for _ in 0 ..< layers {
                let layerRows = (lengths + [joiningLength]).map { _ in Self.rowCache() }
                let layerReferences = (lengths + [joiningLength]).map { _ in Self.rowCache() }
                for (index, length) in (lengths + [joiningLength]).enumerated() {
                    let keys = MLXRandom.normal([1, heads, length, dim]).asType(.float16)
                    let values = MLXRandom.normal([1, heads, length, dim]).asType(.float16)
                    _ = layerRows[index].update(keys: keys, values: values)
                    _ = layerReferences[index].update(keys: keys, values: values)
                }
                eval(layerRows.flatMap(\.state), layerReferences.flatMap(\.state))
                let batch = PagedKVSharedForwardBackend.batchLayerCacheForTest(
                    rowCaches: Array(layerRows.prefix(lengths.count)), attachRows: true
                )
                PagedKVSharedForwardBackend.materializeBatchForTest(batch)
                old.append(batch)
                rows.append(layerRows)
                references.append(layerReferences)
            }
            return (old, rows, references)
        }

        func join(layerByLayer: Bool) throws -> Int {
            var (old, rows, references) = setUp(layerByLayer ? 1 : 0)
            Memory.clearCache()
            Memory.peakMemory = 0
            let base = Memory.activeMemory
            var joined: [any KVCache] = []
            for layer in 0 ..< layers {
                joined.append(PagedKVSharedForwardBackend.batchLayerCacheForTest(rowCaches: rows[layer], attachRows: true))
                if layerByLayer {
                    PagedKVSharedForwardBackend.materializeBatchForTest(joined[layer])
                    PagedKVSharedForwardBackend.releaseBatchForTest(old[layer])
                }
            }
            if !layerByLayer {
                old.forEach(PagedKVSharedForwardBackend.detachBatchRowsForTest)
                joined.forEach(PagedKVSharedForwardBackend.materializeBatchForTest)
            }
            old.removeAll()
            let peak = Memory.peakMemory - base
            for layer in 0 ..< layers {
                XCTAssertTrue(rows[layer].allSatisfy { !$0.holdsOwnKVBuffers }, "layer \(layer)")
                try Self.assertRows(rows[layer], equal: references[layer], "layer \(layer)")
            }
            joined.removeAll()
            rows.removeAll()
            references.removeAll()
            return peak
        }

        let lazyPeak = try join(layerByLayer: false)
        let layerPeak = try join(layerByLayer: true)
        // Per layer: old batch 3 x 2048 tokens, joining row 4096, new batch
        // 4 x (4096 + growth) tokens, fp16.
        let tokenBytes = heads * dim * 2 * 2
        let oldAndJoining = layers * (3 * 2_048 + joiningLength) * tokenBytes
        XCTAssertLessThan(layerPeak, lazyPeak - oldAndJoining / 2, "lazy \(lazyPeak) layer-by-layer \(layerPeak)")
    }

    // MARK: - Backend decode sessions

    /// Mixed-length rows (one past the 512-token chunk) decode in shared
    /// sessions that keep their batch across another row's prompt chunks,
    /// gain a row, lose a row, and take back a row that decoded alone. Every
    /// row's greedy tokens equal the row decoded alone and a serial
    /// `KVCacheSimple` run, and rows hold no K/V of their own while they ride
    /// a session.
    func testMixedLengthSessionsMatchSerialTokensAndRowsLeaveWithExactCaches() async throws {
        try requireMetal()
        let target = try Self.tinyQwen3()
        let prompts: [String: [Int]] = [
            "a": Self.tinyPrompt(length: 37, salt: 1),
            "b": Self.tinyPrompt(length: 130, salt: 2),
            "c": Self.tinyPrompt(length: 300, salt: 3),
            "d": Self.tinyPrompt(length: 610, salt: 4),
        ]

        let shared = try Rows(target: target, prompts: prompts)
        for id in ["a", "b", "c"] { try await shared.prefillAll(id) }
        try await shared.decode(["a", "b", "c"], steps: 3)
        let firstChunkFinished = try await shared.finishedPrefill(chunkOf: "d")
        XCTAssertFalse(firstChunkFinished)
        for id in ["a", "b", "c"] {
            XCTAssertEqual(shared.backend.rowHoldsOwnKVForTest(requestID: id), false, "\(id) during another row's prefill")
        }
        try await shared.decode(["a", "b", "c"], steps: 2)
        let lastChunkFinished = try await shared.finishedPrefill(chunkOf: "d")
        XCTAssertTrue(lastChunkFinished)
        try await shared.decode(["a", "b", "c", "d"], steps: 4)
        // `a` leaves the batch: the next session releases it.
        try await shared.decode(["b", "c", "d"], steps: 3)
        XCTAssertEqual(shared.backend.rowHoldsOwnKVForTest(requestID: "a"), true, "a left the batch")
        XCTAssertEqual(shared.backend.rowHoldsOwnKVForTest(requestID: "b"), false)
        try await shared.decode(["a"], steps: 3)
        for id in ["b", "c", "d"] {
            XCTAssertEqual(shared.backend.rowHoldsOwnKVForTest(requestID: id), true, "\(id) left the batch")
        }
        try await shared.decode(["a", "b", "c", "d"], steps: 2)

        for id in prompts.keys.sorted() {
            let count = shared.generated[id]!.count
            let lone = try Rows(target: target, prompts: [id: prompts[id]!])
            try await lone.prefillAll(id)
            while lone.generated[id]!.count < count {
                try await lone.decode([id], steps: 1)
            }
            XCTAssertEqual(shared.generated[id], lone.generated[id], "\(id) diverged from the row decoded alone")
            XCTAssertEqual(
                shared.generated[id],
                try Self.serialGreedy(target: target, prompt: prompts[id]!, tokens: count),
                "\(id) diverged from serial KVCacheSimple"
            )
        }
        XCTAssertGreaterThan(Set(shared.generated.values.flatMap { $0 }).count, 2, "tokens degenerated")
    }

    // MARK: - Fixtures

    private static func rowCache() -> PagedKVCache {
        let handle = PagedKVBlockTableHandle(id: UUID(), conversationKey: "session-storage-test", poolEpoch: 1)
        let binding = PagedKVStorageBinding(
            handle: handle,
            blockSizeTokens: blockSizeTokens,
            maxLogicalTokens: 4096,
            currentTable: PagedKVBlockTable(
                handleID: handle.handleID,
                blockSizeTokens: blockSizeTokens,
                logicalTokenCount: 0,
                physicalBlocks: [],
                tailValidTokenCount: 0,
                poolEpoch: 1
            ),
            poolEpoch: 1
        )
        return PagedKVCache(
            blockSizeTokens: blockSizeTokens,
            maxPhysicalBlocks: maxPhysicalBlocks,
            poolEpoch: 1,
            binding: binding,
            initialOffset: 0,
            reconstructViaGather: false
        )
    }

    private static func assertRows(
        _ rows: [PagedKVCache],
        equal references: [PagedKVCache],
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for (index, (row, reference)) in zip(rows, references).enumerated() {
            XCTAssertEqual(row.offset, reference.offset, "\(label) row \(index) offset", file: file, line: line)
            XCTAssertEqual(row.storedTokens, reference.storedTokens, "\(label) row \(index) stored", file: file, line: line)
            let state = row.state
            let expected = reference.state
            XCTAssertEqual(state.count, 2, "\(label) row \(index) state", file: file, line: line)
            guard state.count == 2, expected.count == 2 else { continue }
            XCTAssertTrue(arrayEqual(state[0], expected[0]).item(Bool.self), "\(label) row \(index) keys", file: file, line: line)
            XCTAssertTrue(arrayEqual(state[1], expected[1]).item(Bool.self), "\(label) row \(index) values", file: file, line: line)
        }
    }

    /// Two-layer KV-only Qwen3 with random weights.
    private static func tinyQwen3() throws -> Qwen3Model {
        let configuration = try JSONDecoder().decode(Qwen3Configuration.self, from: Data("""
            {
              "hidden_size": 16,
              "num_hidden_layers": 2,
              "intermediate_size": 32,
              "num_attention_heads": 2,
              "num_key_value_heads": 1,
              "head_dim": 8,
              "rms_norm_eps": 1e-6,
              "vocab_size": 32,
              "rope_theta": 100000.0,
              "max_position_embeddings": 4096,
              "tie_word_embeddings": false
            }
            """.utf8))
        MLXRandom.seed(2274)
        let target = Qwen3Model(configuration)
        eval(target)
        return target
    }

    private static func tinyPrompt(length: Int, salt: Int) -> [Int] {
        var state = UInt64(truncatingIfNeeded: 0x9E37_79B9 &+ salt)
        return (0 ..< length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % 32)
        }
    }

    /// Serial reference: one `KVCacheSimple` per layer, the same 512-token
    /// prompt chunks, greedy decode.
    private static func serialGreedy(target: Qwen3Model, prompt: [Int], tokens: Int) throws -> [Int] {
        let cache = try target.newCache(parameters: nil)
        var logits: MLXArray?
        var offset = 0
        while offset < prompt.count {
            let end = min(offset + chunkTokens, prompt.count)
            logits = target(MLXArray(prompt[offset ..< end].map(Int32.init)).reshaped([1, end - offset]), cache: cache)
            offset = end
        }
        var generated: [Int] = []
        while generated.count < tokens {
            let next = argMax(logits![0, -1, 0...], axis: -1).item(Int.self)
            generated.append(next)
            logits = target(MLXArray([Int32(next)]).reshaped([1, 1]), cache: cache)
        }
        return generated
    }

    private final class Rows {
        let backend: PagedKVSharedForwardBackend
        let allocator: PagedKVBlockAllocator
        let prompts: [String: [Int]]
        var handles: [String: PagedKVBlockTableHandle] = [:]
        var prefilled: [String: Int] = [:]
        var generated: [String: [Int]] = [:]

        init(target: Qwen3Model, prompts: [String: [Int]]) throws {
            backend = PagedKVSharedForwardBackend(
                container: ModelContainer(context: ModelContext(
                    configuration: ModelConfiguration(id: "mlx-community/Qwen-Test"),
                    model: target,
                    processor: StandInUserInputProcessor(),
                    tokenizer: SessionStorageTokenizer()
                )),
                blockSizeTokens: PagedKVDecodeSessionStorageTests.blockSizeTokens,
                maxPhysicalBlocks: PagedKVDecodeSessionStorageTests.maxPhysicalBlocks,
                poolEpoch: 1,
                layerCount: 2,
                cacheKinds: [.pagedAttention, .pagedAttention]
            )
            allocator = try PagedKVBlockAllocator(
                blockSizeTokens: PagedKVDecodeSessionStorageTests.blockSizeTokens,
                maxPhysicalBlocks: PagedKVDecodeSessionStorageTests.maxPhysicalBlocks
            )
            self.prompts = prompts
        }

        /// Tokens the row's cache covers: the prompt and every generated
        /// token except the last, which has not been fed back.
        func committed(_ id: String) -> Int { prompts[id]!.count - 1 + generated[id]!.count }

        /// Prefills the row's next prompt chunk; true once its last chunk ran.
        func finishedPrefill(chunkOf id: String) async throws -> Bool {
            let prompt = prompts[id]!
            if handles[id] == nil {
                handles[id] = try await allocator.allocate(conversationKey: id, maxTokens: prompt.count + 128)
            }
            let handle = handles[id]!
            let offset = prefilled[id] ?? 0
            let end = min(offset + PagedKVDecodeSessionStorageTests.chunkTokens, prompt.count)
            _ = try await allocator.extend(handle, by: end - offset)
            let outputs = try await backend.prefill(rows: [ContinuousBatchPrefillInput(
                requestID: id,
                promptTokens: Array(prompt[offset ..< end]),
                binding: try await allocator.binding(for: handle),
                promptTokenOffset: offset,
                committedKVTokenCount: offset,
                targetKVTokenCount: end,
                isFinalChunk: end == prompt.count
            )])
            XCTAssertEqual(outputs.count, 1)
            XCTAssertNil(outputs.first?.failureCode)
            prefilled[id] = end
            guard end == prompt.count else { return false }
            generated[id] = [try XCTUnwrap(outputs.first?.sampledToken, "\(id) sampled no first token")]
            return true
        }

        func prefillAll(_ id: String) async throws {
            while try await !finishedPrefill(chunkOf: id) {}
        }

        func decode(_ ids: [String], steps: Int) async throws {
            var inputs: [ContinuousBatchDecodeInput] = []
            for id in ids {
                let handle = handles[id]!
                _ = try await allocator.extend(handle, by: steps)
                try await allocator.beginDecodeStep(handle)
                let binding = try await allocator.binding(for: handle)
                inputs.append(ContinuousBatchDecodeInput(
                    requestID: id,
                    currentToken: generated[id]!.last!,
                    generatedTokens: generated[id]!,
                    promptTokens: prompts[id]!,
                    samplerSeed: 0,
                    temperature: 0,
                    topP: 1,
                    presencePenalty: 0,
                    frequencyPenalty: 0,
                    binding: binding,
                    blockTable: binding.currentTable,
                    committedKVTokenCount: committed(id),
                    targetKVTokenCount: committed(id) + steps,
                    samplerStep: generated[id]!.count
                ))
            }
            let outcomes = try await backend.decodeLockstepWindow(rows: inputs, steps: steps)
            for id in ids {
                try await allocator.endDecodeStep(handles[id]!)
            }
            XCTAssertEqual(outcomes.count, ids.count)
            for (id, outcome) in zip(ids, outcomes) {
                guard case .output(let output) = outcome, output.requestID == id, output.tokens.count == steps else {
                    XCTFail("\(id) decode failed: \(outcome)")
                    throw CancellationError()
                }
                generated[id]!.append(contentsOf: output.tokens)
            }
        }
    }

    private func requireMetal() throws {
        let bundle = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists()
            || PagedKVMetallibGate.defaultMetallibExists(
                bundleURL: bundle.resourceURL, executableURL: bundle.executableURL)
        else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }
}

private struct SessionStorageTokenizer: Tokenizer {
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
