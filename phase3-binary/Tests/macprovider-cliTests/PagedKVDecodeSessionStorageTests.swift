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

    /// `finish` runs on the scheduler actor while a decode window may be
    /// packing the surviving rows on the container (#2338: a terminal delivery
    /// landing during the next window). It must leave every row cache alone
    /// until the container is free; releasing the session in `finish` cut a
    /// surviving row's layer history to one window
    /// (`paged_kv_block_table_mismatch`). The surviving row still decodes
    /// exactly afterwards.
    func testFinishDuringAContainerOperationLeavesSurvivingRowsUntouched() async throws {
        try requireMetal()
        let target = try Self.tinyQwen3()
        let prompts: [String: [Int]] = [
            "a": Self.tinyPrompt(length: 37, salt: 11),
            "b": Self.tinyPrompt(length: 70, salt: 12),
        ]
        let shared = try Rows(target: target, prompts: prompts)
        for id in ["a", "b"] { try await shared.prefillAll(id) }
        try await shared.decode(["a", "b"], steps: 3)
        XCTAssertEqual(shared.backend.rowHoldsOwnKVForTest(requestID: "b"), false, "b rides the session")

        let backend = shared.backend
        let survivingRowUntouched = try await backend.withTargetLockForTest {
            backend.finish(requestID: "a")
            return backend.rowHoldsOwnKVForTest(requestID: "b") == false
        }
        XCTAssertTrue(survivingRowUntouched, "finish released the session while the container was busy")

        try await shared.decode(["b"], steps: 4)
        let count = shared.generated["b"]!.count
        XCTAssertEqual(
            shared.generated["b"],
            try Self.serialGreedy(target: target, prompt: prompts["b"]!, tokens: count),
            "b diverged from serial KVCacheSimple after a finished during a container operation"
        )
    }

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

    fileprivate static func rowCache() -> PagedKVCache {
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
    fileprivate static func tinyQwen3() throws -> Qwen3Model {
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

    fileprivate static func tinyPrompt(length: Int, salt: Int) -> [Int] {
        var state = UInt64(truncatingIfNeeded: 0x9E37_79B9 &+ salt)
        return (0 ..< length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % 32)
        }
    }

    /// Serial reference: one `KVCacheSimple` per layer, the same 512-token
    /// prompt chunks, greedy decode.
    fileprivate static func serialGreedy(target: Qwen3Model, prompt: [Int], tokens: Int) throws -> [Int] {
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

    fileprivate final class Rows {
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

/// #2396: the scheduler calls `finish` from a finished row's terminal
/// delivery while the next decode window already runs on the model
/// container (every one of the Studio overlaps logged an active operation).
/// `finish` must therefore touch no row cache. It released the dropped
/// session, which detached the remaining rows' layer caches while that window
/// was repacking the same caches into its new batch. A layer packed from a
/// half-detached row got no K/V, started a fresh lockstep buffer at the
/// window's first token, and the row recorded that layer with 8 tokens
/// against a 467-token block table (`paged_kv_block_table_mismatch`).
///
/// CPU device, random two-layer weights. Building the weights still loads
/// the default metallib (a CI host aborted in `mlx_random_key`), so a host
/// without one skips, like the other MLX-array tests.
final class PagedKVDecodeSessionFinishTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        MLXTestDevice.pinProcessCPUDefaultWithoutMetallib()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard MLXTestDevice.metallibAvailable else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    override func invokeTest() {
        guard MLXTestDevice.metallibAvailable else { return super.invokeTest() }
        Device.withDefaultDevice(Device(.cpu)) {
            super.invokeTest()
        }
    }

    /// Two equal-length rows ride one lockstep session (the Studio failure:
    /// `r2` and `r0` at 458 tokens), one row finishes, and the other decodes
    /// on alone. `finish` leaves the remaining row attached to the dropped
    /// session's buffers; the next window repacks it on the container, and
    /// its greedy tokens equal the row decoded alone and a serial run.
    func testFinishLeavesRemainingRowCachesToTheNextWindow() async throws {
        let target = try PagedKVDecodeSessionStorageTests.tinyQwen3()
        let prompts: [String: [Int]] = [
            "a": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 21),
            "b": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 22),
        ]
        let shared = try PagedKVDecodeSessionStorageTests.Rows(target: target, prompts: prompts)
        try await shared.prefillAll("a")
        try await shared.prefillAll("b")
        try await shared.decode(["a", "b"], steps: 2)
        XCTAssertEqual(shared.backend.rowHoldsOwnKVForTest(requestID: "b"), false, "b rides the session")

        // The retained record keeps the finished row's caches.
        let finishedLayers = shared.backend.rowPagedCachesForTest(requestID: "a")
        XCTAssertEqual(finishedLayers.count, 2)
        let finishedTokens = shared.committed("a")
        shared.backend.finish(requestID: "a")
        XCTAssertEqual(
            shared.backend.rowHoldsOwnKVForTest(requestID: "b"), false,
            "finish must not touch another row's caches: a window running beside it repacks them"
        )

        try await shared.decode(["b"], steps: 3)
        // The next window releases the session finish dropped: the finished
        // row's caches hold their own copy, so they pin no batch buffer.
        XCTAssertTrue(finishedLayers.allSatisfy(\.holdsOwnKVBuffers), "a still rides the dropped batch")
        XCTAssertEqual(finishedLayers.map(\.offset), [finishedTokens, finishedTokens])
        try await shared.decode(["b"], steps: 2)
        let count = shared.generated["b"]!.count
        let lone = try PagedKVDecodeSessionStorageTests.Rows(target: target, prompts: ["b": prompts["b"]!])
        try await lone.prefillAll("b")
        while lone.generated["b"]!.count < count {
            try await lone.decode(["b"], steps: 1)
        }
        XCTAssertEqual(shared.generated["b"], lone.generated["b"], "b diverged from the row decoded alone")
        XCTAssertEqual(
            shared.generated["b"],
            try PagedKVDecodeSessionStorageTests.serialGreedy(target: target, prompt: prompts["b"]!, tokens: count),
            "b diverged from serial KVCacheSimple"
        )
    }

    /// The Studio interleaving, replayed deterministically: a window rebuilds
    /// its session for `b` while `a`'s `finish` runs on another thread. The
    /// window waits after the previous session synced until `finish` is
    /// halfway through detaching one of `b`'s layers (out of its batch slot,
    /// not yet holding its own copy), then packs `b`, and only then lets the
    /// detach complete. Every layer of `b` must still hold `b`'s history: the
    /// window records `b` against its block table and `b` decodes the same
    /// tokens as alone. Before the fix the packed layer got no K/V and the
    /// window threw `paged_kv_block_table_mismatch`.
    func testFinishBesideARebuildingWindowKeepsEveryLayerOfTheRemainingRow() async throws {
        let target = try PagedKVDecodeSessionStorageTests.tinyQwen3()
        let prompts: [String: [Int]] = [
            "a": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 31),
            "b": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 32),
        ]
        let shared = try PagedKVDecodeSessionStorageTests.Rows(target: target, prompts: prompts)
        try await shared.prefillAll("a")
        try await shared.prefillAll("b")
        try await shared.decode(["a", "b"], steps: 2)
        let backend = shared.backend
        let bLayers = Set(backend.rowPagedCachesForTest(requestID: "b").map(ObjectIdentifier.init))
        XCTAssertEqual(bLayers.count, 2)

        let state = InterleavingState()
        let midDetach = DispatchSemaphore(value: 0)
        let packed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        PagedKVCache.detachObserverForTest = { cache in
            guard bLayers.contains(ObjectIdentifier(cache)), state.claim("paused") else { return }
            midDetach.signal()
            _ = packed.wait(timeout: .now() + 5)
        }
        backend.rebuildObserverForTest = { point in
            switch point {
            case "prev_synced" where state.claim("finish_started"):
                DispatchQueue.global().async {
                    backend.finish(requestID: "a")
                    finished.signal()
                }
                // Without a detach in `finish` this times out and the window
                // goes on, as it does in production.
                state.record(midDetach.wait(timeout: .now() + 0.5) == .success ? "finish_detached_b" : "finish_left_b")
            case "packed" where state.claim("packed"):
                packed.signal()
            default:
                break
            }
        }
        defer {
            PagedKVCache.detachObserverForTest = nil
            backend.rebuildObserverForTest = nil
        }

        try await shared.decode(["b"], steps: 3)
        _ = finished.wait(timeout: .now() + 5)
        XCTAssertTrue(state.has("finish_started"), "the window never rebuilt its session")
        XCTAssertFalse(state.has("finish_detached_b"), "finish detached b's caches while a window repacked them")
        let committed = shared.committed("b")
        XCTAssertEqual(backend.rowPagedCachesForTest(requestID: "b").map(\.offset), [committed, committed])

        try await shared.decode(["b"], steps: 2)
        let count = shared.generated["b"]!.count
        let lone = try PagedKVDecodeSessionStorageTests.Rows(target: target, prompts: ["b": prompts["b"]!])
        try await lone.prefillAll("b")
        while lone.generated["b"]!.count < count {
            try await lone.decode(["b"], steps: 1)
        }
        XCTAssertEqual(shared.generated["b"], lone.generated["b"], "b diverged from the row decoded alone")
    }

    /// The invariant behind both off-container sites (`finish` and the
    /// native-MTP verify entry): a row cache leaves a batch only while some
    /// caller holds the backend's model container (its target lock). Windows
    /// still release the sessions those sites dropped, so detaches happen.
    func testRowCachesLeaveTheirBatchOnlyInsideTheModelContainer() async throws {
        let target = try PagedKVDecodeSessionStorageTests.tinyQwen3()
        let prompts: [String: [Int]] = [
            "a": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 41),
            "b": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 42),
            "c": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 43),
        ]
        let shared = try PagedKVDecodeSessionStorageTests.Rows(target: target, prompts: prompts)
        for id in ["a", "b", "c"] { try await shared.prefillAll(id) }
        try await shared.decode(["a", "b", "c"], steps: 2)
        let backend = shared.backend
        let state = InterleavingState()
        PagedKVCache.detachObserverForTest = { _ in
            state.record(backend.targetLockHeldForTest() ? "inside" : "outside")
        }
        defer { PagedKVCache.detachObserverForTest = nil }

        // A finished row: `finish` runs beside windows.
        backend.finish(requestID: "a")
        XCTAssertFalse(state.has("outside"), "finish detached row caches outside the model container")
        try await shared.decode(["b", "c"], steps: 2)

        // Native-MTP verify drops the decode session before its container
        // hop. This backend has no drafter, so the round itself fails.
        let handle = shared.handles["b"]!
        let binding = try await shared.allocator.binding(for: handle)
        _ = try? await backend.verifyNativeMTPPackedRound(rows: [ContinuousBatchNativeMTPVerifyInput(
            requestID: "b",
            currentToken: shared.generated["b"]!.last!,
            proposalTokens: [1],
            generatedTokens: shared.generated["b"]!,
            samplerSeed: 0,
            binding: binding,
            blockTable: binding.currentTable,
            committedKVTokenCount: shared.committed("b"),
            verifiedInputTokenCount: 2,
            targetKVTokenCount: shared.committed("b") + 2,
            packedRowIndex: 0,
            samplerStep: shared.generated["b"]!.count
        )])
        XCTAssertFalse(state.has("outside"), "native-MTP verify detached row caches outside the model container")
        XCTAssertTrue(state.has("inside"), "no window released a dropped session")
    }

    /// A finished row's retained record is read and trimmed off the model
    /// container (`reattachPagedKVCache`, `trimRecordedContiguousCache`)
    /// while a window may be detaching the same caches from the session they
    /// left. A reader beside a detach sees the whole row, never the instant
    /// between leaving the batch slot and holding its own copy.
    func testReaderBesideADetachSeesTheWholeRow() throws {
        let row = PagedKVDecodeSessionStorageTests.rowCache()
        MLXRandom.seed(2396)
        _ = row.update(keys: MLXRandom.normal([1, 2, 20, 4]), values: MLXRandom.normal([1, 2, 20, 4]))
        let batch = PagedKVSharedForwardBackend.batchLayerCacheForTest(rowCaches: [row], attachRows: true)
        XCTAssertFalse(row.holdsOwnKVBuffers)

        let state = InterleavingState()
        let read = DispatchSemaphore(value: 0)
        PagedKVCache.detachObserverForTest = { cache in
            guard cache === row, state.claim("paused") else { return }
            DispatchQueue.global().async {
                let stored = row.state
                state.record(stored.count == 2 && stored[0].dim(2) == 20 && row.storedTokens == 20 ? "whole" : "torn")
                read.signal()
            }
            // A reader that waits for the detach to finish times out here.
            _ = read.wait(timeout: .now() + 0.3)
        }
        defer { PagedKVCache.detachObserverForTest = nil }
        PagedKVSharedForwardBackend.detachBatchRowsForTest(batch)
        _ = read.wait(timeout: .now() + 5)
        XCTAssertTrue(state.has("paused"))
        XCTAssertTrue(state.has("whole"), "a reader saw the row between its batch slot and its own copy")
        XCTAssertTrue(row.holdsOwnKVBuffers)
        XCTAssertEqual(row.state.first?.dim(2), 20)
    }

    /// Two rows of one session end in the same window: `finish(a)` retires
    /// the session, and `b`'s terminal commit runs before any decode window
    /// could release it. The commit must find `b` holding its own K/V and end
    /// with its full history plus the committed token: the same K/V as the
    /// same batch whose `a` has not finished.
    func testTerminalCommitAfterABatchMatesFinishSeesItsOwnFullHistory() async throws {
        let target = try PagedKVDecodeSessionStorageTests.tinyQwen3()
        let prompts: [String: [Int]] = [
            "a": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 51),
            "b": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 52),
        ]
        func batchCommittingB(finishingA: Bool) async throws -> (PagedKVDecodeSessionStorageTests.Rows, Int) {
            let rows = try PagedKVDecodeSessionStorageTests.Rows(target: target, prompts: prompts)
            try await rows.prefillAll("a")
            try await rows.prefillAll("b")
            try await rows.decode(["a", "b"], steps: 2)
            XCTAssertEqual(rows.backend.rowHoldsOwnKVForTest(requestID: "b"), false, "b rides the session")
            let committed = rows.committed("b")
            if finishingA { rows.backend.finish(requestID: "a") }
            let handle = rows.handles["b"]!
            _ = try await rows.allocator.extend(handle, by: 1)
            let binding = try await rows.allocator.binding(for: handle)
            try await rows.backend.commitTerminalKV(ContinuousBatchTerminalKVCommitInput(
                requestID: "b",
                currentToken: rows.generated["b"]!.last!,
                binding: binding,
                blockTable: binding.currentTable,
                committedKVTokenCount: committed,
                targetKVTokenCount: committed + 1
            ))
            return (rows, committed)
        }

        let (finished, committed) = try await batchCommittingB(finishingA: true)
        let layers = finished.backend.rowPagedCachesForTest(requestID: "b")
        XCTAssertEqual(layers.count, 2)
        XCTAssertTrue(layers.allSatisfy(\.holdsOwnKVBuffers), "b still rides the retired batch")
        XCTAssertEqual(layers.map(\.offset), [committed + 1, committed + 1])
        XCTAssertEqual(layers.map(\.storedTokens), [committed + 1, committed + 1])

        let (reference, _) = try await batchCommittingB(finishingA: false)
        XCTAssertEqual(
            try finished.backend.rowTargetCacheDigestForTest(requestID: "b"),
            try reference.backend.rowTargetCacheDigestForTest(requestID: "b"),
            "b's committed K/V differs from the same batch without a's finish"
        )
    }

    /// 551d145f5: `commitTerminalKV` releases retired sessions before its
    /// forward, so the forward never writes a row that still rides a retired
    /// session's batch. The test above cannot see that release: the forward's
    /// first write to each layer copies the row out of the batch anyway, and
    /// the release `finish` schedules on the container may run first. Here
    /// the commit queues on the held container before `finish(a)` runs, so
    /// the container (it serves waiters in order) runs the commit ahead of
    /// that scheduled release. Every layer of `b` must then leave the retired
    /// batch before the forward writes any layer of `b`.
    ///
    /// Without the release the forward's write to layer 1 detaches it after
    /// layer 0 already holds the committed token. If the commit task has not
    /// queued within the wait below, `finish`'s release runs first and the
    /// test passes either way; it never fails with the release in place.
    func testTerminalCommitReleasesARetiredSessionBeforeItsForward() async throws {
        let target = try PagedKVDecodeSessionStorageTests.tinyQwen3()
        let prompts: [String: [Int]] = [
            "a": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 61),
            "b": PagedKVDecodeSessionStorageTests.tinyPrompt(length: 40, salt: 62),
        ]
        let rows = try PagedKVDecodeSessionStorageTests.Rows(target: target, prompts: prompts)
        try await rows.prefillAll("a")
        try await rows.prefillAll("b")
        try await rows.decode(["a", "b"], steps: 2)
        let backend = rows.backend
        XCTAssertEqual(backend.rowHoldsOwnKVForTest(requestID: "b"), false, "b rides the session")

        let committed = rows.committed("b")
        let currentToken = rows.generated["b"]!.last!
        let handle = rows.handles["b"]!
        _ = try await rows.allocator.extend(handle, by: 1)
        let binding = try await rows.allocator.binding(for: handle)
        let bLayers = backend.rowPagedCachesForTest(requestID: "b")
        XCTAssertEqual(bLayers.count, 2)
        XCTAssertEqual(bLayers.map(\.offset), [committed, committed])
        let bIDs = Set(bLayers.map(ObjectIdentifier.init))

        let state = InterleavingState()
        PagedKVCache.detachObserverForTest = { cache in
            guard bIDs.contains(ObjectIdentifier(cache)) else { return }
            state.record("b_detached")
            if bLayers.contains(where: { $0.offset != committed }) {
                state.record("b_written_while_attached")
            }
        }
        defer { PagedKVCache.detachObserverForTest = nil }

        // Hold the model container, as the window running beside `finish` does.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holder = Task {
            try await backend.withTargetLockForTest {
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success, "the container holder never ran")

        let commit = Task {
            try await backend.commitTerminalKV(ContinuousBatchTerminalKVCommitInput(
                requestID: "b",
                currentToken: currentToken,
                binding: binding,
                blockTable: binding.currentTable,
                committedKVTokenCount: committed,
                targetKVTokenCount: committed + 1
            ))
        }
        // Let the commit queue on the container ahead of `finish`'s release.
        try await Task.sleep(nanoseconds: 200_000_000)
        backend.finish(requestID: "a")
        release.signal()
        try await holder.value
        try await commit.value

        XCTAssertTrue(state.has("b_detached"), "b never left the retired batch")
        XCTAssertFalse(
            state.has("b_written_while_attached"),
            "the terminal commit's forward wrote b while b still rode the retired session's batch"
        )
        XCTAssertTrue(bLayers.allSatisfy(\.holdsOwnKVBuffers), "b still rides the retired batch")
        XCTAssertEqual(bLayers.map(\.offset), [committed + 1, committed + 1])
    }
}

/// Flags shared by a test and the threads it interleaves.
private final class InterleavingState: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: Set<String> = []

    /// Sets `flag`; true only for the first caller.
    func claim(_ flag: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flags.insert(flag).inserted
    }

    func record(_ flag: String) {
        lock.lock()
        flags.insert(flag)
        lock.unlock()
    }

    func has(_ flag: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flags.contains(flag)
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
