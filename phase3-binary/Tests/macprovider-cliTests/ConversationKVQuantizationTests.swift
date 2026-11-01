import Foundation
import MLX
import MLXLMCommon
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// #965: a reusable conversation cache honours the configured `kvBits` on the
/// serial path. mlx-swift-lm #312 is fixed only inside that package (its
/// `KVCacheStorage` is package-scoped), so the serial path quantizes the cache
/// it owns and never gives its iterator `kvBits`; a commit must agree with its
/// canonical token ledger.
final class ConversationKVQuantizationTests: XCTestCase {
    override func invokeTest() {
        Device.withDefaultDevice(Device(.cpu)) {
            super.invokeTest()
        }
    }

    override class func setUp() {
        super.setUp()
        Device.setDefault(device: Device(.cpu))
    }

    func testSerialConversationKeepsConfiguredKVBitsUnlessColdTierOrImage() {
        XCTAssertEqual(ModelRuntime.effectiveKVBits(
            configured: 8, conversationKey: "conv:buyer-1", serialQuantizedConversation: true), 8)
        XCTAssertEqual(ModelRuntime.effectiveKVBits(
            configured: 4, conversationKey: "conv:buyer-1", serialQuantizedConversation: true), 4)
        // Cold-tier-eligible and continuous-batching callers pass false: fp16.
        XCTAssertNil(ModelRuntime.effectiveKVBits(
            configured: 8, conversationKey: "conv:kvs-synth:a", serialQuantizedConversation: false))
        XCTAssertNil(ModelRuntime.effectiveKVBits(configured: 8, conversationKey: "conv:buyer-1"))
        XCTAssertNil(ModelRuntime.effectiveKVBits(
            configured: 8, conversationKey: "conv:buyer-1", containsImage: true, serialQuantizedConversation: true))
        XCTAssertEqual(ModelRuntime.effectiveKVBits(configured: 8, conversationKey: nil), 8)
        XCTAssertNil(ModelRuntime.effectiveKVBits(configured: nil, conversationKey: "conv:buyer-1",
                                                  serialQuantizedConversation: true))
    }

    func testLeasedConversationIteratorNeverQuantizes() {
        let base = GenerateParameters(maxKVSize: 4096, kvBits: 8)
        let leased = ModelRuntime.serveIteratorParameters(
            base, forceSimpleKV: true, reusedCache: true, leasedConversationCache: true)
        XCTAssertNil(leased.kvBits)
        XCTAssertNil(leased.maxKVSize)
        let oneShot = ModelRuntime.serveIteratorParameters(base, forceSimpleKV: false, reusedCache: false)
        XCTAssertEqual(oneShot.kvBits, 8)
        XCTAssertEqual(oneShot.maxKVSize, 4096)
    }

    func testProviderOwnedConversationCacheQuantizesPrefilledSimpleLayersOnly() throws {
        try requireMetallib()
        let filled = simpleCache(tokens: 40)
        let empty = KVCacheSimple()
        let quantized = try filled.toQuantized(groupSize: 64, bits: 8)
        let rotating = RotatingKVCache(maxSize: 64)
        let layers: [KVCache] = [filled, empty, quantized, rotating]

        let owned = try ModelRuntime.providerOwnedConversationCache(layers, kvBits: 8, groupSize: 64)

        let converted = try XCTUnwrap(owned[0] as? QuantizedKVCache)
        XCTAssertEqual(converted.offset, 40)
        XCTAssertEqual(converted.bits, 8)
        XCTAssertTrue(same(owned[1], empty), "an empty layer waits for its first prefill")
        XCTAssertTrue(same(owned[2], quantized), "a reused quantized layer is kept as is")
        XCTAssertTrue(same(owned[3], rotating))
        let unchanged = try ModelRuntime.providerOwnedConversationCache(layers, kvBits: nil, groupSize: 64)
        XCTAssertTrue(zip(unchanged, layers).allSatisfy { same($0, $1) })
    }

    func testLedgerReconcileAcceptsExactOffsets() {
        let layers: [KVCache] = [offsetCache(10), offsetCache(10), ArraysCache(size: 1)]
        XCTAssertTrue(ModelRuntime.reconcileConversationCacheLedger(
            layers, ledgerTokenCount: 10, terminalModelStopStripped: false))
        XCTAssertEqual(layers[0].offset, 10)
    }

    /// The iterator feeds an end-of-sequence token to the cache before the
    /// generation loop drops it from the output, so the cache is one ahead.
    func testLedgerReconcileTrimsTheStrippedStopToken() {
        let layers: [KVCache] = [offsetCache(11), offsetCache(11)]
        XCTAssertTrue(ModelRuntime.reconcileConversationCacheLedger(
            layers, ledgerTokenCount: 10, terminalModelStopStripped: true))
        XCTAssertEqual(layers.map(\.offset), [10, 10])
    }

    func testLedgerReconcileRefusesAnExtraPositionWithoutAStrippedStop() {
        let layers: [KVCache] = [offsetCache(11)]
        XCTAssertFalse(ModelRuntime.reconcileConversationCacheLedger(
            layers, ledgerTokenCount: 10, terminalModelStopStripped: false))
        XCTAssertEqual(layers[0].offset, 11, "a refused commit leaves the cache untouched")
    }

    /// mlx-swift-lm #312 signature: the caller's layer stopped at the prompt
    /// while the ledger also holds the generated tokens.
    func testLedgerReconcileRefusesAStaleShortCache() {
        let layers: [KVCache] = [offsetCache(6), offsetCache(10)]
        XCTAssertFalse(ModelRuntime.reconcileConversationCacheLedger(
            layers, ledgerTokenCount: 10, terminalModelStopStripped: true))
        XCTAssertEqual(layers.map(\.offset), [6, 10])
    }

    func testLedgerReconcileChecksQuantizedLayers() throws {
        try requireMetallib()
        let quantized = try simpleCache(tokens: 11).toQuantized(groupSize: 64, bits: 8)
        XCTAssertTrue(ModelRuntime.reconcileConversationCacheLedger(
            [quantized], ledgerTokenCount: 10, terminalModelStopStripped: true))
        XCTAssertEqual(quantized.offset, 10)
        XCTAssertFalse(ModelRuntime.reconcileConversationCacheLedger(
            [quantized], ledgerTokenCount: 12, terminalModelStopStripped: true))
    }

    /// A quantized hot entry reuses only a quantized lease, and trims by the
    /// ledger like an unquantized one.
    func testQuantizedEntryHitsOnlyTheSameKVBitsAndTrimsByLedger() async throws {
        try requireMetallib()
        let cache = makeConversationCacheForTest(config: .init(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900))
        let tokens = (0 ..< 64).map(Int32.init)
        let firstValue = await cache.begin(
            conversationKey: "conv:quantized", incomingTokens: tokens, modelID: "m", kvBits: 8)
        let first = try XCTUnwrap(firstValue)
        let layer = try simpleCache(tokens: 64).toQuantized(groupSize: 64, bits: 8)
        await cache.commit(first, cache: ConversationCacheLayers([layer]), fullTokens: tokens)

        let swappedValue = await cache.begin(
            conversationKey: "conv:quantized", incomingTokens: tokens + [99], modelID: "m", kvBits: nil)
        let swapped = try XCTUnwrap(swappedValue)
        XCTAssertNil(swapped.reusableCache, "kvBits mismatch is a miss")
        await cache.abort(swapped)

        let secondValue = await cache.begin(
            conversationKey: "conv:quantized2", incomingTokens: tokens, modelID: "m", kvBits: 8)
        let second = try XCTUnwrap(secondValue)
        let layer2 = try simpleCache(tokens: 64).toQuantized(groupSize: 64, bits: 8)
        await cache.commit(second, cache: ConversationCacheLayers([layer2]), fullTokens: tokens)
        let diverged = Array(tokens.prefix(48)) + [7, 7, 7]
        let hitValue = await cache.begin(
            conversationKey: "conv:quantized2", incomingTokens: diverged, modelID: "m", kvBits: 8)
        let hit = try XCTUnwrap(hitValue)
        XCTAssertEqual(hit.cachedPromptTokens, 48)
        XCTAssertTrue(same(hit.reusableCache?.layers.first, layer2))
        XCTAssertEqual(layer2.offset, 48)
        await cache.abort(hit)
    }

    /// SPEC-037: quantized reusable state never reaches the disk tier.
    func testColdTierSkipsQuantizedLayers() async throws {
        try requireMetallib()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-quant-cold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = KVDiskCacheStoreConfig(
            root: root, namespaceID: "ns-quant-cold",
            maxBytes: 64 * 1024 * 1024, maxEntries: 8, maxEntryBytes: 16 * 1024 * 1024,
            retentionSeconds: 3600, stagingMaxBytes: 16 * 1024 * 1024,
            writeStagingMaxBytes: 16 * 1024 * 1024, minFreeBytes: 1024,
            promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        config.freeSpaceOverride = 1 << 30
        let store = KVDiskCacheStore(config: config, keychain: KVInMemoryKeychain(), sink: KVRecordingEventSink())
        try await store.activate()
        let adapter = KVConversationColdTierAdapter(
            store: store, namespaceID: "ns-quant-cold", eligibilityTTLSeconds: 900,
            writeStagingMaxBytes: config.writeStagingMaxBytes, maxEntryBytes: config.maxEntryBytes,
            stagingMaxBytes: config.stagingMaxBytes)
        adapter.cacheEpoch(await store.currentEpoch)
        let identity = KVIdentityCore(
            requestModel: "m", servedModelID: "m-served", modelSHA256: String(repeating: "b", count: 64),
            catalogRevision: "r1", tokenizerID: "m-served", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil)
        let quantized = try simpleCache(tokens: 40).toQuantized(groupSize: 64, bits: 8)
        let snapshot = adapter.captureSnapshot(
            conversationKey: "conv:kvs-synth:quantized", layers: ConversationCacheLayers([quantized]),
            fullTokens: (0 ..< 40).map(Int32.init), sampledPurgeGeneration: 0, identity: identity,
            nowMillis: Int(Date().timeIntervalSince1970 * 1000))
        XCTAssertNil(snapshot)
        await store.deactivate()
    }

    /// Building MLX tensors needs the default metallib even on the CPU device.
    private func requireMetallib() throws {
        let testBundle = Bundle(for: Self.self)
        guard PagedKVMetallibGate.defaultMetallibExists(
            bundleURL: testBundle.resourceURL, executableURL: testBundle.executableURL) else {
            throw XCTSkip("MLX default metallib is unavailable in this test host")
        }
    }

    private func same(_ lhs: KVCache?, _ rhs: KVCache) -> Bool {
        lhs.map { ($0 as AnyObject) === (rhs as AnyObject) } ?? false
    }

    private func offsetCache(_ offset: Int) -> KVCacheSimple {
        let cache = KVCacheSimple()
        cache.offset = offset
        return cache
    }

    private func simpleCache(tokens: Int) -> KVCacheSimple {
        let cache = KVCacheSimple()
        let keys = MLXArray((0 ..< (2 * tokens * 64)).map { Float($0 % 97) / 97 }, [1, 2, tokens, 64])
        _ = cache.update(keys: keys, values: keys * 2)
        return cache
    }
}
