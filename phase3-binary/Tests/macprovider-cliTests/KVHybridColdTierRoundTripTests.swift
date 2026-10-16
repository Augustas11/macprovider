import Foundation
import MLX
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// #2015 — SPEC-037 R015 codec-v2 capture on hybrid (recurrent + attention)
/// caches. On Qwen3.6 every first-turn capture logged `estimate_unavailable`:
/// the batched serial hand-off left recurrent layers as empty placeholders, and
/// the geometry records omitted the recurrent `captured_offset` the size
/// equation charges. These tests pin the estimator, the size the served model
/// really needs, and the capture → write → promote → restore round trip.
final class KVHybridColdTierRoundTripTests: XCTestCase {

    // MARK: - Qwen3.6-35B-A3B sizes (pure arithmetic, no MLX)

    /// Real geometry of `mlx-community/Qwen3.6-35B-A3B-4bit`: 40 layers, every
    /// 4th full attention (10 × KVCacheSimple, 2 KV heads × 256, bf16) and 30
    /// gated-delta layers (MambaCache: conv [1,3,8192] bf16, state [1,32,128,128]
    /// f32). The acceptance prompts were ~6.4k tokens with up to three checkpoints.
    func testQwen36EntrySizesFitLargeHostDefaultsButNeverTheSmallDefault() throws {
        let tokens = 6408
        let checkpoint = qwen36CheckpointRecord(tokenCount: tokens)
        let perCheckpoint = 4 + 4 + 30 * (4 + 2 + (2 + 1 + 24 + 1 + 8 + 49_152) + (2 + 1 + 32 + 1 + 8 + 2_097_152))
        XCTAssertEqual(perCheckpoint, 64_391_708, "~61.4 MiB of recurrent state per checkpoint")

        var sizes: [Int] = []
        for count in 1...3 {
            let records = (0..<count).map { qwen36CheckpointRecord(tokenCount: tokens - 2 + $0) }
            sizes.append(try XCTUnwrap(KVDiskCacheFormat.decodedLengthV2(
                tokenCount: tokens, layers: qwen36LayerRecords(tokens: tokens), checkpoints: records)))
        }
        XCTAssertEqual(sizes, [195_654_726, 260_046_434, 324_438_142])
        XCTAssertEqual(sizes[1] - sizes[0], perCheckpoint)
        XCTAssertEqual(checkpoint.layers.count, 30)

        let small = KVDiskCacheConfig.defaultStagingMaxBytes
        let large = KVDiskCacheConfig.largeHostStagingMaxBytes
        for size in sizes {
            // Promotion staging for codec-v2 is twice the decoded size (FR-KVP3/9).
            XCTAssertGreaterThan(2 * size, small, "256 MiB can never promote a Qwen3.6 6.4k entry")
            XCTAssertLessThanOrEqual(2 * size, large, "the large-host default fits up to three checkpoints")
        }
    }

    // MARK: - Estimator on hybrid cache shapes (MLX)

    func testEstimatorIsExactForPopulatedHybridCaches() throws {
        try requireMLX()
        let fixture = HybridFixture(tokenCount: 40, checkpointTokenCounts: [20, 40])
        let estimate = try XCTUnwrap(KVRecurrentCacheSerialization.estimatedDecodedLength(
            layers: fixture.layers, checkpoints: fixture.checkpoints, tokenCount: fixture.tokens.count))
        let snapshot = try XCTUnwrap(KVRecurrentCacheSerialization.snapshot(
            layers: fixture.layers, checkpoints: fixture.checkpoints))
        let encoded = try KVPayloadCodecV2.encodeSegments(
            tokens: fixture.tokens, layers: snapshot.layers, checkpoints: snapshot.checkpoints)
        XCTAssertEqual(estimate, encoded.reduce(0) { $0 + $1.count }, "estimate equals the encoded payload")
    }

    func testEstimatorCoversArraysCacheRecurrentLayers() throws {
        try requireMLX()
        let fixture = HybridFixture(tokenCount: 40, checkpointTokenCounts: [40], recurrentClass: .arrays)
        let estimate = try XCTUnwrap(KVRecurrentCacheSerialization.estimatedDecodedLength(
            layers: fixture.layers, checkpoints: fixture.checkpoints, tokenCount: fixture.tokens.count))
        let snapshot = try XCTUnwrap(KVRecurrentCacheSerialization.snapshot(
            layers: fixture.layers, checkpoints: fixture.checkpoints))
        let encoded = try KVPayloadCodecV2.encodeSegments(
            tokens: fixture.tokens, layers: snapshot.layers, checkpoints: snapshot.checkpoints)
        XCTAssertEqual(estimate, encoded.reduce(0) { $0 + $1.count })
    }

    /// Capture still fails closed on an incomplete live recurrent layer: the fix
    /// is that the producer hands over complete state, not that capture accepts less.
    func testEstimatorRejectsEmptyOrPaddedRecurrentLayers() throws {
        try requireMLX()
        let fixture = HybridFixture(tokenCount: 40, checkpointTokenCounts: [40])
        var empty = fixture.layers
        empty[0] = MambaCache()
        XCTAssertNil(KVRecurrentCacheSerialization.estimatedDecodedLength(
            layers: empty, checkpoints: fixture.checkpoints, tokenCount: 40))

        var padded = fixture.layers
        let paddedCache = MambaCache(leftPadding: [1])
        paddedCache.state = fixture.layers[0].state
        padded[0] = paddedCache
        XCTAssertNil(KVRecurrentCacheSerialization.estimatedDecodedLength(
            layers: padded, checkpoints: fixture.checkpoints, tokenCount: 40))

        XCTAssertNil(KVRecurrentCacheSerialization.estimatedDecodedLength(
            layers: fixture.layers, checkpoints: [], tokenCount: 40), "no checkpoint, nothing reusable")
    }

    // MARK: - capture → write → promote → restore (MLX)

    func testHybridCaptureWritePromoteRestoreRoundTrip() async throws {
        try requireMLX()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-hybrid-roundtrip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = KVDiskCacheStoreConfig(
            root: root, namespaceID: "ns-hybrid-roundtrip",
            maxBytes: 64 * 1024 * 1024, maxEntries: 8, maxEntryBytes: 16 * 1024 * 1024,
            retentionSeconds: 3600, stagingMaxBytes: 16 * 1024 * 1024,
            writeStagingMaxBytes: 16 * 1024 * 1024, minFreeBytes: 1024,
            promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        config.freeSpaceOverride = 1 << 30
        let store = KVDiskCacheStore(config: config, keychain: KVInMemoryKeychain(), sink: KVRecordingEventSink())
        try await store.activate()
        let adapter = KVConversationColdTierAdapter(
            store: store, namespaceID: "ns-hybrid-roundtrip", eligibilityTTLSeconds: 900,
            writeStagingMaxBytes: config.writeStagingMaxBytes, maxEntryBytes: config.maxEntryBytes,
            stagingMaxBytes: config.stagingMaxBytes)
        adapter.cacheEpoch(await store.currentEpoch)

        let fixture = HybridFixture(tokenCount: 40, checkpointTokenCounts: [20, 40])
        let key = "conv:kvs-synth:hybrid-roundtrip"
        let identity = KVIdentityCore(
            requestModel: "hybrid", servedModelID: "hybrid-served", modelSHA256: String(repeating: "b", count: 64),
            catalogRevision: "r1", tokenizerID: "hybrid-served", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil)
        let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
        let snapshot = try XCTUnwrap(adapter.captureSnapshot(
            conversationKey: key,
            layers: ConversationCacheLayers(fixture.layers, recurrentCheckpoints: fixture.checkpoints),
            fullTokens: fixture.tokens, sampledPurgeGeneration: 0, identity: identity, nowMillis: nowMillis),
            "a complete hybrid cache must be captured, not skipped as estimate_unavailable")
        XCTAssertEqual(snapshot.identity.codecID, KVDiskCacheFormat.recurrentCodecID)
        XCTAssertEqual(snapshot.recurrentCheckpoints.map(\.tokenCount), [20, 40])

        let write = try await store.writeColdSnapshot(
            rawKey: snapshot.rawKey, tokens: snapshot.tokens, layers: snapshot.layers,
            layersV2: snapshot.layersV2, recurrentCheckpoints: snapshot.recurrentCheckpoints,
            identity: snapshot.identity, sampledPurgeGeneration: snapshot.sampledPurgeGeneration,
            commitSequence: snapshot.commitSequence, createdAtMillis: snapshot.createdAtMillis,
            eligibleUntilMillis: snapshot.eligibleUntilMillis, incarnation: snapshot.incarnation,
            nowMillis: nowMillis)
        adapter.releaseWriteLive(snapshot.reservedWriteBytes)
        guard case .committed = write else {
            await store.deactivate()
            return XCTFail("codec-v2 hybrid entry must commit, got \(write)")
        }

        let candidate = await adapter.promoteCandidate(conversationKey: key, identity: identity)
        await store.deactivate()
        let promoted = try XCTUnwrap(candidate, "the written hybrid entry must promote")
        XCTAssertEqual(promoted.canonicalTokens, fixture.tokens)
        XCTAssertEqual(promoted.codecID, KVDiskCacheFormat.recurrentCodecID)
        let restored = promoted.layers
        XCTAssertEqual(restored.layers.count, fixture.layers.count)
        XCTAssertEqual(restored.recurrentCheckpoints.map(\.tokenCount), [20, 40])
        for (index, original) in fixture.layers.enumerated() {
            let layer = restored.layers[index]
            XCTAssertEqual(String(describing: type(of: layer)), String(describing: type(of: original)))
            XCTAssertEqual(layer.offset, original.offset, "layer \(index) offset")
            XCTAssertEqual(bytes(layer.state), bytes(original.state), "layer \(index) live state")
        }
        for (restoredCheckpoint, original) in zip(restored.recurrentCheckpoints, fixture.checkpoints) {
            XCTAssertEqual(Set(restoredCheckpoint.states.keys), Set(original.states.keys))
            for (index, state) in original.states {
                XCTAssertEqual(bytes(restoredCheckpoint.states[index] ?? []), bytes(state),
                               "checkpoint \(original.tokenCount) layer \(index)")
            }
        }
    }

    /// The adapter applies the store's on-disk size (decoded + framing + manifest)
    /// before copying, so an entry the store would reject is never copied.
    func testCaptureSkipsEntryWhoseDiskSizeExceedsMaxEntryBytes() async throws {
        try requireMLX()
        let fixture = HybridFixture(tokenCount: 40, checkpointTokenCounts: [40])
        let decoded = try XCTUnwrap(KVRecurrentCacheSerialization.estimatedDecodedLength(
            layers: fixture.layers, checkpoints: fixture.checkpoints, tokenCount: 40))
        let (store, adapter, root) = try await makeStoreAndAdapter(maxEntryBytes: decoded, stagingMaxBytes: 16 << 20)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = adapter.captureSnapshot(
            conversationKey: "conv:kvs-synth:hybrid-cap",
            layers: ConversationCacheLayers(fixture.layers, recurrentCheckpoints: fixture.checkpoints),
            fullTokens: fixture.tokens, sampledPurgeGeneration: 0, identity: hybridIdentity(),
            nowMillis: Int(Date().timeIntervalSince1970 * 1000))
        XCTAssertNil(snapshot, "decoded fits but decoded + framing + manifest does not")
        await store.deactivate()
    }

    /// Promotion charges codec-v2 entries twice their decoded size on the read
    /// side too, so lowering the ceiling after a write cannot overrun it.
    func testPromotionChargesRecurrentEntryTwiceOnRead() async throws {
        try requireMLX()
        let fixture = HybridFixture(tokenCount: 40, checkpointTokenCounts: [40])
        let decoded = try XCTUnwrap(KVRecurrentCacheSerialization.estimatedDecodedLength(
            layers: fixture.layers, checkpoints: fixture.checkpoints, tokenCount: 40))
        let keychain = KVInMemoryKeychain()
        let (writer, writerAdapter, root) = try await makeStoreAndAdapter(
            maxEntryBytes: 16 << 20, stagingMaxBytes: 16 << 20, keychain: keychain)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "conv:kvs-synth:hybrid-read-ceiling"
        let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
        let snapshot = try XCTUnwrap(writerAdapter.captureSnapshot(
            conversationKey: key,
            layers: ConversationCacheLayers(fixture.layers, recurrentCheckpoints: fixture.checkpoints),
            fullTokens: fixture.tokens, sampledPurgeGeneration: 0, identity: hybridIdentity(), nowMillis: nowMillis))
        let write = try await commit(snapshot, to: writer, nowMillis: nowMillis)
        writerAdapter.releaseWriteLive(snapshot.reservedWriteBytes)
        guard case .committed = write else { return XCTFail("fixture must commit, got \(write)") }
        await writer.deactivate()

        // Same namespace: a ceiling between 1x and 2x the decoded size misses;
        // a ceiling with room for both copies promotes.
        for (ceiling, promotes) in [(decoded + 1, false), (16 << 20, true)] {
            let (reader, readerAdapter, _) = try await makeStoreAndAdapter(
                maxEntryBytes: 16 << 20, stagingMaxBytes: ceiling, keychain: keychain, root: root)
            XCTAssertTrue(readerAdapter.seedTemplate(servedModelID: "hybrid-served", layers: fixture.layers))
            let candidate = await readerAdapter.promoteCandidate(conversationKey: key, identity: hybridIdentity())
            XCTAssertEqual(candidate != nil, promotes, "ceiling \(ceiling) for decoded \(decoded)")
            await reader.deactivate()
        }
    }

    private func makeStoreAndAdapter(
        maxEntryBytes: Int, stagingMaxBytes: Int, keychain: KVInMemoryKeychain = KVInMemoryKeychain(),
        root existingRoot: URL? = nil
    ) async throws -> (KVDiskCacheStore, KVConversationColdTierAdapter, URL) {
        let root = existingRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-hybrid-\(UUID().uuidString)", isDirectory: true)
        var config = KVDiskCacheStoreConfig(
            root: root, namespaceID: "ns-hybrid",
            maxBytes: 64 << 20, maxEntries: 8, maxEntryBytes: maxEntryBytes,
            retentionSeconds: 3600, stagingMaxBytes: stagingMaxBytes,
            writeStagingMaxBytes: 16 << 20, minFreeBytes: 1024,
            promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        config.freeSpaceOverride = 1 << 30
        let store = KVDiskCacheStore(config: config, keychain: keychain, sink: KVRecordingEventSink())
        try await store.activate()
        let adapter = KVConversationColdTierAdapter(
            store: store, namespaceID: "ns-hybrid", eligibilityTTLSeconds: 900,
            writeStagingMaxBytes: config.writeStagingMaxBytes, maxEntryBytes: maxEntryBytes,
            stagingMaxBytes: stagingMaxBytes)
        adapter.cacheEpoch(await store.currentEpoch)
        return (store, adapter, root)
    }

    private func commit(
        _ snapshot: ConversationColdSnapshot, to store: KVDiskCacheStore, nowMillis: Int
    ) async throws -> KVWriteResult {
        try await store.writeColdSnapshot(
            rawKey: snapshot.rawKey, tokens: snapshot.tokens, layers: snapshot.layers,
            layersV2: snapshot.layersV2, recurrentCheckpoints: snapshot.recurrentCheckpoints,
            identity: snapshot.identity, sampledPurgeGeneration: snapshot.sampledPurgeGeneration,
            commitSequence: snapshot.commitSequence, createdAtMillis: snapshot.createdAtMillis,
            eligibleUntilMillis: snapshot.eligibleUntilMillis, incarnation: snapshot.incarnation,
            nowMillis: nowMillis)
    }

    private func hybridIdentity() -> KVIdentityCore {
        KVIdentityCore(
            requestModel: "hybrid", servedModelID: "hybrid-served", modelSHA256: String(repeating: "b", count: 64),
            catalogRevision: "r1", tokenizerID: "hybrid-served", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil)
    }

    // MARK: - Fixture

    private enum RecurrentClass { case mamba, arrays }

    /// Qwen3.6-shaped miniature: three recurrent layers then one attention layer.
    private struct HybridFixture {
        let tokens: [Int32]
        let layers: [KVCache]
        let checkpoints: [RecurrentStateCheckpoint]

        init(tokenCount: Int, checkpointTokenCounts: [Int], recurrentClass: RecurrentClass = .mamba) {
            tokens = (0..<tokenCount).map(Int32.init)
            func recurrentState(seed: Float) -> [MLXArray] {
                [
                    MLXArray((0..<(3 * 8)).map { Float($0) + seed }, [1, 3, 8]).asType(.bfloat16),
                    MLXArray((0..<(2 * 4 * 4)).map { Float($0) * 0.5 + seed }, [1, 2, 4, 4]),
                ]
            }
            checkpoints = checkpointTokenCounts.map { count in
                RecurrentStateCheckpoint(
                    tokenCount: count,
                    states: Dictionary(uniqueKeysWithValues: (0..<3).map { ($0, recurrentState(seed: Float(count * 10 + $0))) }))
            }
            let terminal = checkpoints.last
            var built: [KVCache] = (0..<3).map { index in
                let cache: ArraysCache = recurrentClass == .mamba ? MambaCache() : ArraysCache(size: 2)
                if let state = terminal?.states[index] { cache.state = state }
                return cache
            }
            let attention = KVCacheSimple()
            attention.state = [
                MLXArray((0..<(2 * tokenCount * 4)).map { Float($0) }, [1, 2, tokenCount, 4]).asType(.float16),
                MLXArray((0..<(2 * tokenCount * 4)).map { Float($0) + 1000 }, [1, 2, tokenCount, 4]).asType(.float16),
            ]
            built.append(attention)
            layers = built
        }
    }

    private func requireMLX() throws {
        guard PagedKVMetallibGate.defaultMetallibExists() else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    private func bytes(_ arrays: [MLXArray]) -> [Data] {
        arrays.map { $0.asData(access: .copy).data }
    }

    private func qwen36LayerRecords(tokens: Int) -> [KVLayerRecord] {
        (0..<40).map { index in
            index % 4 == 3
                ? KVLayerRecord(layerIndex: index, classID: "KVCacheSimple", layoutVersion: 2,
                                ndim: 4, dims: [1, 2, tokens, 256], dtype: .bf16)
                : KVLayerRecord(layerIndex: index, classID: "MambaCache", layoutVersion: 2,
                                ndim: 0, dims: [], dtype: .f16, cacheOffset: 0)
        }
    }

    private func qwen36CheckpointRecord(tokenCount: Int) -> KVRecurrentCheckpointRecord {
        KVRecurrentCheckpointRecord(tokenCount: tokenCount, layers: (0..<40).filter { $0 % 4 != 3 }.map { index in
            KVRecurrentLayerRecord(layerIndex: index, slots: [
                .init(slotIndex: 0, dims: [1, 3, 8192], dtype: .bf16, byteCount: 3 * 8192 * 2),
                .init(slotIndex: 1, dims: [1, 32, 128, 128], dtype: .f32, byteCount: 32 * 128 * 128 * 4),
            ])
        })
    }
}
