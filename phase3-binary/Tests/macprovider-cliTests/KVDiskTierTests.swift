import Foundation
import MacProviderCore
@testable import macprovider_cli
import XCTest

/// SPEC-037 FR-KVP11 synthetic-key gate + FR-KVP8/KVP12 coordinator control
/// plane. The gate matrix and the standalone purge/status round trip run in CI
/// (in-memory Keychain double, synthetic `KVLayerPayload` state — no MLX). The
/// live-MLX snapshot-at-commit/promotion path and its AC-1/AC-8 fixtures land in
/// stage 5 alongside the ModelRuntime data-path wiring.
final class KVDiskTierTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDown() {
        for url in tempRoots { try? FileManager.default.removeItem(at: url) }
        tempRoots.removeAll()
        super.tearDown()
    }

    private func makeRoot() -> URL {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("kvtier-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(url)
        return url
    }

    // MARK: - Synthetic-key gate (FR-KVP11)

    func testGateAdmitsSyntheticOnDirectHTTP() {
        XCTAssertTrue(KVDiskCacheGate.persists(conversationKey: "conv:kvs-synth:alpha", provenance: .directHTTP))
    }

    func testGateRefusesSyntheticOnRelayAndTier2() {
        XCTAssertFalse(KVDiskCacheGate.persists(conversationKey: "conv:kvs-synth:alpha", provenance: .relay))
        XCTAssertFalse(KVDiskCacheGate.persists(conversationKey: "conv:kvs-synth:alpha", provenance: .tier2))
        XCTAssertFalse(KVDiskCacheGate.persists(conversationKey: "conv:kvs-synth:alpha", provenance: .unknown))
    }

    func testGateRefusesNonSyntheticConvKeyOnDirectHTTP() {
        // A coordinator-derived buyer key (base64url HMAC suffix, no `:`).
        XCTAssertFalse(KVDiskCacheGate.persists(conversationKey: "conv:AbC0d3f-hmacSuffix", provenance: .directHTTP))
    }

    func testGateRefusesEmptySuffixAndNil() {
        XCTAssertFalse(KVDiskCacheGate.persists(conversationKey: "conv:kvs-synth:", provenance: .directHTTP))
        XCTAssertFalse(KVDiskCacheGate.persists(conversationKey: nil, provenance: .directHTTP))
    }

    func testGateTrimsWhitespace() {
        XCTAssertTrue(KVDiskCacheGate.persists(conversationKey: "  conv:kvs-synth:x  ", provenance: .directHTTP))
    }

    // MARK: - Coordinator control plane (FR-KVP8/KVP12)

    private static let identity = KVWriteIdentity(
        requestModel: "qwen-test", servedModelID: "qwen-test-served",
        modelSHA256: String(repeating: "b", count: 64), catalogRevision: "r1",
        tokenizerID: "tok-1", tokenizerConfigSHA256: String(repeating: "c", count: 64),
        chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 1,
        mlxSwiftLMRevision: "3.31.4", mlxVersion: "0.0.0", cacheClass: "KVCacheSimple",
        layerCount: 1, kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil,
        decodePath: "ordinary", keyEpoch: 1)

    private func makeLayers(seq: Int) -> [KVLayerPayload] {
        let byteCount = 1 * 2 * seq * 4 * KVCodecDType.f32.byteSize
        return [KVLayerPayload(
            layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, seq, 4], dtype: .f32,
            cacheOffset: seq, keyBytes: Data(count: byteCount), valueBytes: Data(count: byteCount))]
    }

    private func makeTier(root: URL) -> KVDiskTier {
        let config = KVDiskCacheConfig(enabled: true, directory: root.path, minFreeBytes: 1024 * 1024)
        return KVDiskTier(config: config, namespaceID: "ns-tier",
                          eligibilityTTLSeconds: 900,
                          keychain: KVInMemoryKeychain(), sink: KVRecordingEventSink())
    }

    private func writeEntry(_ tier: KVDiskTier, key: String, seq: Int, nowMillis: Int) async throws {
        let index = try await tier.store.currentIndex(rawKey: key)
        let sampled = try await tier.store.highWatermark(rawKey: key)
        let snapshot = KVWriteSnapshot(
            rawKey: key, indexHMAC: try XCTUnwrap(index), tokens: Array(0 ..< Int32(seq)),
            layers: makeLayers(seq: seq), identity: Self.identity,
            sampledPurgeGeneration: sampled, commitSequence: 1,
            createdAtMillis: nowMillis, eligibleUntilMillis: nowMillis + 900_000,
            incarnation: "inc-\(UUID().uuidString)")
        let result = try await tier.store.write(snapshot, nowMillis: nowMillis)
        guard case .committed = result else {
            XCTFail("write should commit, got \(result)"); return
        }
    }

    func testStatusReportsEmptyNamespace() async throws {
        let tier = makeTier(root: makeRoot())
        let inspection = await tier.status()
        XCTAssertEqual(inspection?.entryCount, 0)
        XCTAssertEqual(inspection?.keyEpoch, 1)
        XCTAssertEqual(inspection?.eligibilityTTLSeconds, 900)
        await tier.shutdown()
    }

    func testPurgeSingleKeyRemovesEntry() async throws {
        let tier = makeTier(root: makeRoot())
        let activated = await tier.activateForControlPlane(); XCTAssertTrue(activated)
        let key = "conv:kvs-synth:purge-me"
        try await writeEntry(tier, key: key, seq: 5, nowMillis: 1_000_000)

        let before = await tier.status()
        XCTAssertEqual(before?.entryCount, 1)

        let result = await tier.purge(rawKey: key)
        guard case let .ok(removed, freed) = result else {
            return XCTFail("expected purge_ok, got \(result)")
        }
        XCTAssertEqual(removed, 1)
        XCTAssertGreaterThan(freed, 0)

        let after = await tier.status()
        XCTAssertEqual(after?.entryCount, 0)
        await tier.shutdown()
    }

    /// CRITICAL-1: the real purge path must clear the hot tier (RAM) as well as
    /// disk, and fence any outstanding lease so its commit reinserts nothing. Drives
    /// `KVDiskTier.purge` with the hot-purge hooks wired exactly as
    /// `ModelRuntime.attachKVDiskTier` wires them.
    func testPurgeClearsHotTierAndFencesOutstandingLease() async throws {
        let tier = makeTier(root: makeRoot())
        let activated = await tier.activateForControlPlane(); XCTAssertTrue(activated)
        let cache = ConversationCache()
        await tier.store.setHotPurgeHooks(
            single: { key in await cache.purgeHot(conversationKey: key) },
            all: { await cache.purgeAllHot() })

        let key = "conv:kvs-synth:hot-and-disk"
        // Disk side: a committed generation the purge must unlink.
        try await writeEntry(tier, key: key, seq: 6, nowMillis: 1_000_000)
        let diskBefore = await tier.status()?.entryCount; XCTAssertEqual(diskBefore, 1)

        // Hot side: seed an entry (cold_start begin → commit), then acquire an
        // outstanding HIT lease that will attempt to commit after the purge.
        let seedOpt = await cache.begin(
            conversationKey: key, incomingTokens: Array(0 ..< 32), modelID: "m", kvBits: nil)
        let seed = try XCTUnwrap(seedOpt)
        await cache.commit(seed, cache: ConversationCacheLayers([]), fullTokens: Array(0 ..< 40))
        let hotBefore = await cache.snapshotStats().entries; XCTAssertEqual(hotBefore, 1)
        let staleOpt = await cache.begin(
            conversationKey: key, incomingTokens: Array(0 ..< 48), modelID: "m", kvBits: nil)
        let stale = try XCTUnwrap(staleOpt)
        XCTAssertNotNil(stale.reusableCache, "precondition: outstanding lease is a hit")

        // Drive the real purge path.
        guard case .ok = await tier.purge(rawKey: key) else { return XCTFail("purge failed") }

        // Disk generation gone.
        let diskAfter = await tier.status()?.entryCount; XCTAssertEqual(diskAfter, 0)

        // The pre-purge lease's commit reinserts nothing (fenced).
        await cache.commit(stale, cache: ConversationCacheLayers([]), fullTokens: Array(0 ..< 48))
        let hotAfter = await cache.snapshotStats().entries
        XCTAssertEqual(hotAfter, 0, "purge must drop the hot entry and the fenced commit must not reinsert")

        // A subsequent same-key begin is a cold_start miss.
        let afterOpt = await cache.begin(
            conversationKey: key, incomingTokens: Array(0 ..< 48), modelID: "m", kvBits: nil)
        let after = try XCTUnwrap(afterOpt)
        XCTAssertNil(after.reusableCache, "subsequent same-key begin must be a cold_start miss")
        XCTAssertEqual(after.cachedPromptTokens, 0)
        await cache.abort(after)
        await tier.shutdown()
    }

    /// CRITICAL-1 purge-all half: clears every hot entry and fences leases before
    /// the epoch rotation completes.
    func testPurgeAllClearsHotTier() async throws {
        let tier = makeTier(root: makeRoot())
        let activated = await tier.activateForControlPlane(); XCTAssertTrue(activated)
        let cache = ConversationCache()
        await tier.store.setHotPurgeHooks(
            single: { key in await cache.purgeHot(conversationKey: key) },
            all: { await cache.purgeAllHot() })

        let seedOpt = await cache.begin(
            conversationKey: "conv:kvs-synth:x", incomingTokens: Array(0 ..< 32), modelID: "m", kvBits: nil)
        let seed = try XCTUnwrap(seedOpt)
        await cache.commit(seed, cache: ConversationCacheLayers([]), fullTokens: Array(0 ..< 40))
        let staleOpt = await cache.begin(
            conversationKey: "conv:kvs-synth:x", incomingTokens: Array(0 ..< 48), modelID: "m", kvBits: nil)
        let stale = try XCTUnwrap(staleOpt)
        _ = try XCTUnwrap(stale.reusableCache)

        guard case .ok = await tier.purgeAll() else { return XCTFail("purge-all failed") }

        await cache.commit(stale, cache: ConversationCacheLayers([]), fullTokens: Array(0 ..< 48))
        let hotAfter = await cache.snapshotStats().entries
        XCTAssertEqual(hotAfter, 0, "purge-all fences the outstanding lease's commit")
        await tier.shutdown()
    }

    /// M-13 / FR-KVP7: serve-lock contention is transient, not permanent dormancy —
    /// the tier retries with bounded backoff and runs full activation once the lock
    /// is released.
    func testServeLockDormancyRetriesUntilAcquired() async throws {
        let root = makeRoot()
        let holder = makeTier(root: root)
        let held = await holder.activateForControlPlane(); XCTAssertTrue(held)

        let contender = makeTier(root: root)
        let outcome = await contender.activateForServeDetailed()
        XCTAssertEqual(outcome, .dormantLock, "lock held by holder ⇒ dormant, retry")

        let acquired = expectation(description: "retry acquires the lock after release")
        let task = Task { await contender.retryActivationUntilAcquired { acquired.fulfill() } }

        // Release the holder's lock; the background retry must then acquire it.
        await holder.shutdown()
        await fulfillment(of: [acquired], timeout: 20)
        task.cancel()
        await contender.shutdown()
    }

    func testPurgeAbsentKeyNoOps() async throws {
        let tier = makeTier(root: makeRoot())
        let result = await tier.purge(rawKey: "conv:kvs-synth:never-written")
        guard case let .ok(removed, freed) = result else {
            return XCTFail("expected purge_ok, got \(result)")
        }
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(freed, 0)
        await tier.shutdown()
    }

    func testPurgeAllRotatesEpoch() async throws {
        let tier = makeTier(root: makeRoot())
        let activated = await tier.activateForControlPlane(); XCTAssertTrue(activated)
        try await writeEntry(tier, key: "conv:kvs-synth:a", seq: 4, nowMillis: 1_000_000)
        try await writeEntry(tier, key: "conv:kvs-synth:b", seq: 4, nowMillis: 1_000_000)

        let epochBefore = await tier.status()?.keyEpoch
        let result = await tier.purgeAll()
        guard case .ok = result else { return XCTFail("expected purge_ok, got \(result)") }

        let after = await tier.status()
        XCTAssertEqual(after?.entryCount, 0)
        XCTAssertEqual(after?.keyEpoch, (epochBefore ?? 1) + 1, "purge-all rotates the key epoch")
        await tier.shutdown()
    }

    /// FR-KVP8: control plane must remain functional while the tier is disabled
    /// (a disabled tier still has purgeable residue).
    func testPurgeWorksWhileDisabled() async throws {
        let root = makeRoot()
        // First write under an enabled coordinator, then purge under a disabled one.
        let enabled = makeTier(root: root)
        let activatedEnabled = await enabled.activateForControlPlane(); XCTAssertTrue(activatedEnabled)
        try await writeEntry(enabled, key: "conv:kvs-synth:disabled-purge", seq: 4, nowMillis: 1_000_000)
        await enabled.shutdown()

        let disabledConfig = KVDiskCacheConfig(enabled: false, directory: root.path, minFreeBytes: 1024 * 1024)
        let disabled = KVDiskTier(config: disabledConfig, namespaceID: "ns-tier",
                                  keychain: KVInMemoryKeychain(), sink: KVRecordingEventSink())
        // Note: a fresh in-memory keychain cannot decrypt the prior entry, but the
        // purge control path (tombstone + high-watermark + best-effort unlink) still
        // runs and reports success regardless of `enabled`.
        let result = await disabled.purge(rawKey: "conv:kvs-synth:disabled-purge")
        if case .failed(let d) = result { XCTFail("disabled purge should not fail: \(d)") }
        await disabled.shutdown()
    }

    // MARK: - Snapshot immutability contract (FR-KVP3, payload level)

    /// The write-side snapshot deep-copies layer bytes (`KVCacheSerialization`
    /// uses `MLXArray.asData(access: .copy)`), so the captured `KVLayerPayload`
    /// is a value snapshot that a later in-place trim of the source cannot race.
    /// Verified here at the `Data` value-semantics level; the live-MLX equivalent
    /// (mutating KVCacheSimple layers post-commit) is the stage-5 AC-9 fixture.
    func testCapturedPayloadBytesAreValueCopies() {
        var source = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let payload = KVLayerPayload(
            layerIndex: 0, classID: "KVCacheSimple", ndim: 1, dims: [8], dtype: .u32,
            cacheOffset: 2, keyBytes: source, valueBytes: source)
        source[0] = 0xFF  // mutate the source after capture
        XCTAssertEqual(payload.keyBytes.first, 1, "captured bytes must not track later source mutation")
        XCTAssertEqual(payload.valueBytes.first, 1)
    }
}
