import Foundation
import MacProviderCore
import MLXLMCommon
@testable import macprovider_cli
import XCTest

/// SPEC-049-R010 and R007 item 8 (v0.6.0), SPEC-037 v0.2.2: the KV disk tier
/// may be on while the provider serves the privacy class. A privacy-class
/// request never looks up, writes or restores a disk-tier entry, whatever key
/// or fleet grant it carries; ordinary fleet traffic still persists and
/// restores. Headless: a recording cold tier stands in for the encrypted store.
final class PrivacyKVDiskBypassTests: XCTestCase {
    private let key = "conv:kvs-synth:shared"

    func testPrivacyPathBypassInvariantHolds() {
        XCTAssertFalse(ModelRuntime.coldTierAdmits(provenance: .privacy))
        XCTAssertFalse(ModelRuntime.allowsConversationCacheLease(provenance: .privacy, nativeAllows: true))
        XCTAssertFalse(KVDiskCacheGate.persists(conversationKey: key, provenance: .privacy))
        XCTAssertFalse(KVIngestProvenance.privacy.mayPersistRequestDerivedState)
        XCTAssertFalse(ContinuousBatchRuntimeReplayAuthority.persistsClaim(for: .privacy))
        XCTAssertTrue(PrivacyRuntimeHardening.privacyReplayClaimStaysInMemory())
        XCTAssertTrue(PrivacyRuntimeHardening.privacyPathBypassesDiskSinks())
        // Every reusable-cache sink follows the one provenance policy.
        for provenance in KVIngestProvenance.allCases {
            let allowed = provenance.mayUseReusableKVCache
            XCTAssertEqual(allowed, provenance != .privacy, "\(provenance)")
            XCTAssertEqual(ModelRuntime.coldTierAdmits(provenance: provenance), allowed, "\(provenance)")
            XCTAssertEqual(
                ModelRuntime.allowsConversationCacheLease(provenance: provenance, nativeAllows: true), allowed, "\(provenance)")
            if !allowed {
                XCTAssertFalse(KVDiskCacheGate.persists(conversationKey: key, provenance: provenance), "\(provenance)")
            }
        }
    }

    /// Adversarial shapes: a synthetic key, a valid fleet grant for the same
    /// key, and both. None gives a privacy request a cold-tier context.
    func testPrivacyRequestGetsNoColdContextWhateverKeyOrGrant() throws {
        let (authority, root) = makeAuthority()
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try authority.authorize(conversationKey: key, generation: 1)
        let base = try request()
        let shapes: [(String, ChatCompletionRequest)] = [
            ("synthetic_key", base.withConversationKey(key).withIngestProvenance(.privacy)),
            ("fleet_grant", base.withFleetCacheGrant(grant).withIngestProvenance(.privacy)),
            ("relay_path_shape", base.withIngestProvenance(.privacy).withConversationKey(nil)),
        ]
        for (name, privacy) in shapes {
            XCTAssertNil(coldContext(privacy), name)
        }
        // The same shapes outside the privacy class do reach the tier.
        XCTAssertEqual(coldContext(base.withConversationKey(key).withIngestProvenance(.directHTTP))?.eligible, true)
        XCTAssertEqual(coldContext(base.withIngestProvenance(.relay).withFleetCacheGrant(grant))?.eligible, true)
    }

    /// Worst case: even if a privacy request reached the conversation cache,
    /// with a persisted entry waiting for its key, the disk tier sees no
    /// lookup, write, restore or telemetry, before or after a restart.
    func testPrivacyRequestNeverLooksUpWritesOrRestoresDiskTier() async throws {
        let (authority, root) = makeAuthority()
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try authority.authorize(conversationKey: key, generation: 1)
        let privacy = try request().withFleetCacheGrant(grant).withIngestProvenance(.privacy)
        let cold = coldContext(privacy)
        XCTAssertNil(cold)

        let tier = RecordingColdTier()
        tier.promoteResult = candidate(tokens: tokens(0 ..< 64))
        let cache = ConversationCache(config: Self.cacheConfig, coldTier: tier)
        let lease = try await XCTUnwrapAsync(await cache.begin(
            conversationKey: key, incomingTokens: tokens(0 ..< 72), modelID: "model-a", kvBits: nil, cold: cold))
        XCTAssertEqual(lease.cachedPromptTokens, 0, "no restore from disk")
        await cache.commit(lease, cache: layers(offset: 80), fullTokens: tokens(0 ..< 80), cold: cold)

        let restarted = ConversationCache(config: Self.cacheConfig, coldTier: tier)
        let next = try await XCTUnwrapAsync(await restarted.begin(
            conversationKey: key, incomingTokens: tokens(0 ..< 96), modelID: "model-a", kvBits: nil, cold: cold))
        XCTAssertEqual(next.cachedPromptTokens, 0, "no restore after restart")
        await restarted.abort(next)

        XCTAssertEqual(tier.calls, [], "the privacy path made no disk-tier call")
    }

    /// Same worst case against the real encrypted store and adapter: a persisted
    /// entry under the privacy request's own key stays untouched, and the store
    /// records no read, write, promotion or telemetry event, across a restart.
    func testPrivacyRequestLeavesRealPersistedEntryUntouched() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-kv-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = KVRecordingEventSink()
        let keychain = KVInMemoryKeychain()
        var store = try await seededStore(root: root, keychain: keychain, sink: sink)
        let before = await store.inspect()
        var counterBaseline = before.counters
        XCTAssertEqual(before.entryCount, 1)
        sink.reset()

        let (authority, authorityRoot) = makeAuthority()
        defer { try? FileManager.default.removeItem(at: authorityRoot) }
        let grant = try authority.authorize(conversationKey: key, generation: 1)
        let privacy = try request().withConversationKey(key).withFleetCacheGrant(grant).withIngestProvenance(.privacy)
        let cold = coldContext(privacy)
        XCTAssertNil(cold)

        for run in 0 ..< 2 {  // first process, then a restart: a new store over the same root and keychain
            if run == 1 {
                XCTAssertEqual(sink.events.map(\.code), [], "no disk-tier event before the restart")
                await store.deactivate()
                store = KVDiskCacheStore(config: Self.storeConfig(root: root), keychain: keychain, sink: sink)
                try await store.activate()
                sink.reset()
                counterBaseline = await store.inspect().counters  // counters are per process
            }
            let adapter = KVConversationColdTierAdapter(store: store, namespaceID: "ns-privacy", eligibilityTTLSeconds: 900)
            adapter.seedTemplate(servedModelID: "served-a", template: KVConversationColdTierAdapter.seedGeometryTemplate(
                fromPayloads: [KVLayerPayload(
                    layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, 1, 4], dtype: .f32,
                    cacheOffset: 1, keyBytes: Data(), valueBytes: Data())]))
            let cache = ConversationCache(config: Self.cacheConfig, coldTier: adapter)
            let lease = try await XCTUnwrapAsync(await cache.begin(
                conversationKey: key, incomingTokens: tokens(0 ..< 48), modelID: "model-a", kvBits: nil, cold: cold))
            XCTAssertEqual(lease.cachedPromptTokens, 0)
            await cache.commit(lease, cache: layers(offset: 56), fullTokens: tokens(0 ..< 56), cold: cold)
            await cache.drainColdWrites(timeoutSeconds: 1)
        }

        XCTAssertEqual(sink.events.map(\.code), [], "no disk-tier event after the restart")
        let after = await store.inspect()
        XCTAssertEqual(after.entryCount, before.entryCount)
        XCTAssertEqual(after.bytesUsed, before.bytesUsed)
        XCTAssertEqual(after.counters, counterBaseline)
        await store.deactivate()
    }

    /// The disk tier stays useful for ordinary traffic in the same process:
    /// a fleet-granted relay turn persists, and after a restart its next turn
    /// restores from disk.
    func testNonPrivateFleetRequestStillPersistsAndRestoresFromDisk() async throws {
        let (authority, root) = makeAuthority()
        defer { try? FileManager.default.removeItem(at: root) }
        let fleetKey = "conv:tenant-conversation"
        let grant = try authority.authorize(conversationKey: fleetKey, generation: 1)
        let relay = try request().withIngestProvenance(.relay).withFleetCacheGrant(grant)
        let cold = try XCTUnwrap(coldContext(relay))
        XCTAssertTrue(cold.eligible)

        let writer = RecordingColdTier()
        let cache = ConversationCache(config: Self.cacheConfig, coldTier: writer)
        let first = try await XCTUnwrapAsync(await cache.begin(
            conversationKey: fleetKey, incomingTokens: tokens(0 ..< 56), modelID: "model-a", kvBits: nil,
            cold: cold, fleetGrant: grant))
        await cache.commit(first, cache: layers(offset: 64), fullTokens: tokens(0 ..< 64), cold: cold)
        XCTAssertEqual(writer.count("capture"), 1)
        XCTAssertEqual(writer.count("enqueue"), 1)

        let reader = RecordingColdTier()
        reader.promoteResult = candidate(tokens: tokens(0 ..< 64))
        let restarted = ConversationCache(config: Self.cacheConfig, coldTier: reader)
        let second = try await XCTUnwrapAsync(await restarted.begin(
            conversationKey: fleetKey, incomingTokens: tokens(0 ..< 64) + tokens(200 ..< 210),
            modelID: "model-a", kvBits: nil, cold: cold, fleetGrant: grant))
        XCTAssertEqual(second.cachedPromptTokens, 64, "turn two restores the persisted prefix")
        XCTAssertEqual(reader.count("promote"), 1)
        XCTAssertEqual(reader.finished.map(\.accepted), [true])
        await restarted.abort(second)
    }

    // MARK: - Helpers

    private static let cacheConfig = ConversationCache.Config(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900)

    private func coldContext(_ request: ChatCompletionRequest) -> ConversationColdContext? {
        ModelRuntime.coldContext(
            for: request,
            tierAttached: true,
            allowBuyerKeys: true,
            servedModelID: "model-a",
            modelSHA256: String(repeating: "b", count: 64),
            catalogRevision: "r1",
            tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64))
    }

    /// One committed `KVCacheSimple` entry for `key`, written through the real store.
    private static func storeConfig(root: URL) -> KVDiskCacheStoreConfig {
        var config = KVDiskCacheStoreConfig(
            root: root, namespaceID: "ns-privacy",
            maxBytes: 1 << 30, maxEntries: 16, maxEntryBytes: 1 << 28,
            retentionSeconds: 3600, stagingMaxBytes: 1 << 28, writeStagingMaxBytes: 1 << 28,
            minFreeBytes: 1 << 20, promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        config.freeSpaceOverride = 1 << 34
        return config
    }

    private func seededStore(
        root: URL, keychain: KVInMemoryKeychain, sink: KVRecordingEventSink
    ) async throws -> KVDiskCacheStore {
        let store = KVDiskCacheStore(config: Self.storeConfig(root: root), keychain: keychain, sink: sink)
        try await store.activate()
        let seq = 40
        let byteCount = 2 * seq * 4 * KVCodecDType.f32.byteSize
        let identity = KVWriteIdentity(
            requestModel: "model-a", servedModelID: "served-a", modelSHA256: String(repeating: "b", count: 64),
            catalogRevision: "r1", tokenizerID: "served-a", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: KVBuildIdentity.abiEpoch,
            mlxSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision, mlxVersion: KVBuildIdentity.mlxVersion,
            cacheClass: "KVCacheSimple", layerCount: 1, kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil, decodePath: KVBuildIdentity.decodePathOrdinary, keyEpoch: 1)
        let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
        let index = try await store.currentIndex(rawKey: key)
        let sampled = try await store.highWatermark(rawKey: key)
        let snapshot = KVWriteSnapshot(
            rawKey: key, indexHMAC: try XCTUnwrap(index),
            tokens: Array(0 ..< Int32(seq)),
            layers: [KVLayerPayload(
                layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, seq, 4], dtype: .f32,
                cacheOffset: seq, keyBytes: Data(count: byteCount), valueBytes: Data(count: byteCount))],
            identity: identity, sampledPurgeGeneration: sampled,
            commitSequence: 1, createdAtMillis: nowMillis, eligibleUntilMillis: nowMillis + 3_600_000,
            incarnation: "inc-seed")
        guard case .committed = try await store.write(snapshot, nowMillis: nowMillis) else {
            XCTFail("seed entry must commit")
            throw CancellationError()
        }
        return store
    }

    private func request() throws -> ChatCompletionRequest {
        try ChatCompletionRequest.parse(data: JSONSerialization.data(withJSONObject: [
            "model": "model-a",
            "messages": [["role": "user", "content": "hello"]],
            "max_tokens": 8,
        ]))
    }

    private func makeAuthority() -> (FleetConversationCacheAuthority, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-kv-bypass-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (FleetConversationCacheAuthority(storageURL: root.appendingPathComponent("floors.json")), root)
    }

    private func tokens(_ range: Range<Int>) -> [Int32] { range.map(Int32.init) }

    private func layers(offset: Int) -> ConversationCacheLayers {
        let cache = KVCacheSimple()
        cache.offset = offset
        return ConversationCacheLayers([cache])
    }

    private func candidate(tokens: [Int32]) -> ColdPromotionCandidate {
        ColdPromotionCandidate(
            layers: layers(offset: tokens.count), canonicalTokens: tokens, keyHashPrefix: "abcd1234",
            bytesRead: 42, decryptMillis: 1, peakStagingBytes: 42)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

/// Records every `ConversationColdTier` call by name.
private final class RecordingColdTier: ConversationColdTier, @unchecked Sendable {
    var promoteResult: ColdPromotionCandidate?
    private let lock = NSLock()
    private var recorded: [String] = []
    private var finishedOutcomes: [(accepted: Bool, reason: String?)] = []

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var finished: [(accepted: Bool, reason: String?)] { lock.lock(); defer { lock.unlock() }; return finishedOutcomes }
    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }

    private func record(_ name: String) { lock.lock(); recorded.append(name); lock.unlock() }

    func sampledPurgeGeneration(conversationKey: String) async -> Int { record("sampled_generation"); return 0 }

    func promoteCandidate(conversationKey: String, identity: KVIdentityCore) async -> ColdPromotionCandidate? {
        record("promote")
        return promoteResult
    }

    func finishPromotion(_ candidate: ColdPromotionCandidate, accepted: Bool, rejectionReason: String?) async {
        record("finish_promotion")
        lock.lock(); finishedOutcomes.append((accepted, rejectionReason)); lock.unlock()
    }

    func captureSnapshot(
        conversationKey: String, layers: ConversationCacheLayers, fullTokens: [Int32],
        sampledPurgeGeneration: Int, identity: KVIdentityCore, nowMillis: Int
    ) -> ConversationColdSnapshot? {
        record("capture")
        return ConversationColdSnapshot(
            rawKey: conversationKey, tokens: fullTokens, layers: [], identity: Self.writeIdentity,
            sampledPurgeGeneration: sampledPurgeGeneration, commitSequence: 1,
            createdAtMillis: nowMillis, eligibleUntilMillis: nowMillis, incarnation: "test")
    }

    func enqueuePersist(_ snapshot: ConversationColdSnapshot) { record("enqueue") }
    func cancelPendingPersist(conversationKey: String) async -> Bool { record("cancel_pending"); return false }
    func cancelPendingPersists() async { record("cancel_all") }
    func drainPendingPersists(timeoutSeconds: Int) async { record("drain") }
    func noteReadIdentityUnavailable(conversationKey: String) async { record("read_identity_unavailable") }
    func noteWriteSkippedIdentityUnavailable(conversationKey: String) async { record("write_identity_unavailable") }

    private static let writeIdentity = KVWriteIdentity(
        requestModel: "model-a", servedModelID: "model-a", modelSHA256: String(repeating: "b", count: 64),
        catalogRevision: "r1", tokenizerID: "model-a", tokenizerConfigSHA256: String(repeating: "c", count: 64),
        chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 1, mlxSwiftLMRevision: "x",
        mlxVersion: "y", cacheClass: "KVCacheSimple", layerCount: 1, kvBits: nil, kvGroupSize: nil,
        kvQuantMode: nil, kvQuantPolicy: nil, decodePath: "ordinary", keyEpoch: 1)
}
