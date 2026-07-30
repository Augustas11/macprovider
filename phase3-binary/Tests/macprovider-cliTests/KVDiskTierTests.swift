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

    // MARK: - FR-KVP8 purge admission fences (CRITICAL R2)

    /// Actor-safe capture of a value produced inside a `@Sendable` purge callback.
    private actor ValueBox<T: Sendable> {
        var value: T?
        func set(_ v: T) { value = v }
    }

    private func snapshot(for tier: KVDiskTier, key: String, seq: Int, sampled: Int,
                          commitSequence: Int, nowMillis: Int) async throws -> KVWriteSnapshot {
        let index = try await tier.store.currentIndex(rawKey: key)
        return KVWriteSnapshot(
            rawKey: key, indexHMAC: try XCTUnwrap(index), tokens: Array(0 ..< Int32(seq)),
            layers: makeLayers(seq: seq), identity: Self.identity,
            sampledPurgeGeneration: sampled, commitSequence: commitSequence,
            createdAtMillis: nowMillis, eligibleUntilMillis: nowMillis + 900_000,
            incarnation: "inc-\(UUID().uuidString)")
    }

    private func runtimeIdentity(for tier: KVDiskTier, key: String) async throws -> KVRuntimeIdentity {
        let index = try await tier.store.currentIndex(rawKey: key)
        let id = Self.identity
        return KVRuntimeIdentity(
            namespaceID: "ns-tier", keyEpoch: 1, indexHMAC: try XCTUnwrap(index),
            requestModel: id.requestModel, servedModelID: id.servedModelID, modelSHA256: id.modelSHA256,
            catalogRevision: id.catalogRevision, tokenizerID: id.tokenizerID,
            tokenizerConfigSHA256: id.tokenizerConfigSHA256, chatTemplateSHA256: id.chatTemplateSHA256,
            abiEpoch: id.abiEpoch, mlxSwiftLMRevision: id.mlxSwiftLMRevision, mlxVersion: id.mlxVersion,
            cacheClass: id.cacheClass, layerCount: id.layerCount,
            layers: [KVLayerGeometry(layerIndex: 0, classID: "KVCacheSimple", layoutVersion: 1,
                                     ndim: 4, dims: [1, 2, 32, 4], dtype: .f32, sequenceAxis: 2)],
            kvBits: id.kvBits, kvGroupSize: id.kvGroupSize, kvQuantMode: id.kvQuantMode,
            kvQuantPolicy: id.kvQuantPolicy, decodePath: id.decodePath, liveHighWatermark: 0)
    }

    /// CRITICAL (a)/(b): a HOT-ONLY purge (no disk artifacts) must still advance the
    /// durable high-watermark, so a snapshot that sampled the pre-purge watermark
    /// (queued before the first disk write) can never publish afterward.
    func testHotOnlyPurgeAdvancesWatermarkAndFencesQueuedSnapshot() async throws {
        let tier = makeTier(root: makeRoot())
        let __act = await tier.activateForControlPlane(); XCTAssertTrue(__act)
        let cache = ConversationCache()
        await tier.store.setHotPurgeHooks(
            single: { key in await cache.purgeHot(conversationKey: key) },
            all: { await cache.purgeAllHot() })

        let key = "conv:kvs-synth:hot-only"
        // Hot-only: seed a RAM entry with no disk generation.
        let seedOpt = await cache.begin(
            conversationKey: key, incomingTokens: Array(0 ..< 32), modelID: "m", kvBits: nil)
        let seed = try XCTUnwrap(seedOpt)
        await cache.commit(seed, cache: ConversationCacheLayers([]), fullTokens: Array(0 ..< 40))
        let __e0 = await tier.status()?.entryCount; XCTAssertEqual(__e0, 0, "precondition: no disk artifacts")

        // A snapshot captured (sampled) before the purge would carry HWM 0.
        let sampledBefore = try await tier.store.highWatermark(rawKey: key)
        XCTAssertEqual(sampledBefore, 0)

        // Purge a hot-only key: must NOT no-op — the watermark advances.
        guard case .ok = await tier.purge(rawKey: key) else { return XCTFail("purge failed") }
        let sampledAfter = try await tier.store.highWatermark(rawKey: key)
        XCTAssertGreaterThan(sampledAfter, sampledBefore, "hot-only purge must advance the watermark")

        // The queued (pre-purge-sampled) snapshot is now fenced at write time.
        let stale = try await snapshot(for: tier, key: key, seq: 40, sampled: sampledBefore,
                                       commitSequence: 1, nowMillis: 1_000_000)
        let result = try await tier.store.write(stale, nowMillis: 1_000_000)
        guard case .skipped(.fenceLost) = result else {
            return XCTFail("queued pre-purge snapshot must be fenced, got \(result)")
        }
        let __e1 = await tier.status()?.entryCount; XCTAssertEqual(__e1, 0, "no disk entry may be published post-purge")
        await tier.shutdown()
    }

    /// CRITICAL (b): a write sampled DURING the purge suspension (the `hotPurgeSingle`
    /// callback) is denied by the per-index admission fence.
    func testWriteDuringPurgeSuspensionIsFenced() async throws {
        let tier = makeTier(root: makeRoot())
        let __act = await tier.activateForControlPlane(); XCTAssertTrue(__act)
        let key = "conv:kvs-synth:interleave"
        try await writeEntry(tier, key: key, seq: 6, nowMillis: 1_000_000)

        let box = ValueBox<KVWriteResult>()
        await tier.store.setHotPurgeHooks(
            single: { [self] _ in
                // Runs while `purge` is suspended: a fresh, current-epoch write for the
                // same index must be rejected because the fence is already raised.
                if let snap = try? await snapshot(for: tier, key: key, seq: 8, sampled: 0,
                                                  commitSequence: 99, nowMillis: 1_000_001),
                   let r = try? await tier.store.write(snap, nowMillis: 1_000_001) {
                    await box.set(r)
                }
                return true
            }, all: {})

        guard case .ok = await tier.purge(rawKey: key) else { return XCTFail("purge failed") }
        let interleaved = await box.value
        guard case .skipped(.fenceLost) = interleaved else {
            return XCTFail("write during purge suspension must be fence_lost, got \(String(describing: interleaved))")
        }
        await tier.shutdown()
    }

    /// CRITICAL (c): during a purge-all namespace fence, a promotion read AND a new
    /// write are both denied so no old-epoch data resurfaces across the suspension.
    func testReadAndWriteDuringPurgeAllAreFenced() async throws {
        let tier = makeTier(root: makeRoot())
        let __act = await tier.activateForControlPlane(); XCTAssertTrue(__act)
        let key = "conv:kvs-synth:ns-fence"
        try await writeEntry(tier, key: key, seq: 6, nowMillis: 1_000_000)

        let readBox = ValueBox<KVReadResult>()
        let writeBox = ValueBox<KVWriteResult>()
        await tier.store.setHotPurgeHooks(single: { _ in false }, all: { [self] in
            if let runtime = try? await runtimeIdentity(for: tier, key: key),
               let r = try? await tier.store.read(rawKey: key, runtime: runtime, nowMillis: 1_000_001, emitHitEvent: false) {
                await readBox.set(r)
            }
            if let snap = try? await snapshot(for: tier, key: key, seq: 8, sampled: 0,
                                              commitSequence: 99, nowMillis: 1_000_001),
               let w = try? await tier.store.write(snap, nowMillis: 1_000_001) {
                await writeBox.set(w)
            }
        })

        guard case .ok = await tier.purgeAll() else { return XCTFail("purge-all failed") }
        guard case .miss(.diskMissBusy, _) = await readBox.value else {
            return XCTFail("promotion read during purge-all must be fenced, got \(String(describing: await readBox.value))")
        }
        guard case .skipped(.fenceLost) = await writeBox.value else {
            return XCTFail("write during purge-all must be fenced, got \(String(describing: await writeBox.value))")
        }
        await tier.shutdown()
    }

    /// CRITICAL (d): a single-key purge that crosses the 4096 high-watermark cap
    /// routes through the namespace-fence rotation, which clears the hot tier via
    /// `hotPurgeAll` (not just the one index).
    func testHighWatermarkCapPurgeClearsHotTier() async throws {
        let tier = makeTier(root: makeRoot())
        let __act = await tier.activateForControlPlane(); XCTAssertTrue(__act)
        let cache = ConversationCache()
        await tier.store.setHotPurgeHooks(
            single: { key in await cache.purgeHot(conversationKey: key) },
            all: { await cache.purgeAllHot() })

        // Seed an unrelated hot entry that ONLY a namespace-wide invalidation clears.
        let other = "conv:kvs-synth:bystander"
        let seedOpt = await cache.begin(
            conversationKey: other, incomingTokens: Array(0 ..< 32), modelID: "m", kvBits: nil)
        let seed = try XCTUnwrap(seedOpt)
        await cache.commit(seed, cache: ConversationCacheLayers([]), fullTokens: Array(0 ..< 40))
        let __h0 = await cache.snapshotStats().entries; XCTAssertEqual(__h0, 1)

        // Fill the watermark map to the cap so purging a NEW key forces rotation.
        await tier.store.seedPurgeWatermarksForTest(count: KVNamespaceMetadata.highWatermarkCap)

        let key = "conv:kvs-synth:cap-trigger"
        // Give the key hot state so the purge is not a no-op.
        let s2Opt = await cache.begin(
            conversationKey: key, incomingTokens: Array(0 ..< 32), modelID: "m", kvBits: nil)
        let s2 = try XCTUnwrap(s2Opt)
        await cache.commit(s2, cache: ConversationCacheLayers([]), fullTokens: Array(0 ..< 40))

        let epochBefore = await tier.store.currentEpoch
        guard case .ok = await tier.purge(rawKey: key) else { return XCTFail("cap purge failed") }
        let epochAfter = await tier.store.currentEpoch
        XCTAssertEqual(epochAfter, epochBefore + 1, "cap purge must rotate the epoch")
        let hotAfter = await cache.snapshotStats().entries
        XCTAssertEqual(hotAfter, 0, "cap-triggered rotation must clear the whole hot tier, including the bystander")
        await tier.shutdown()
    }

    /// M-D: a purge whose entry-directory unlink fails must report purge_failed and
    /// retain the byte accounting (the entry is NOT counted as removed) so a later
    /// retry can complete the deletion.
    func testPurgeReportsFailureWhenUnlinkFails() async throws {
        let tier = makeTier(root: makeRoot())
        let __act = await tier.activateForControlPlane(); XCTAssertTrue(__act)
        let key = "conv:kvs-synth:unlink-fail"
        try await writeEntry(tier, key: key, seq: 5, nowMillis: 1_000_000)
        let __c0 = await tier.status()?.entryCount; XCTAssertEqual(__c0, 1)

        await tier.store.injectUnlinkFailure(true)
        let failed = await tier.purge(rawKey: key)
        guard case .failed = failed else { return XCTFail("expected purge_failed, got \(failed)") }
        // Accounting retained: the entry still counts (ciphertext still on disk).
        let midCount = await tier.status()?.entryCount
        XCTAssertEqual(midCount, 1, "a failed unlink must not decrement accounting")

        // Retry after the fault clears completes the deletion.
        await tier.store.injectUnlinkFailure(false)
        guard case .ok = await tier.purge(rawKey: key) else { return XCTFail("retry purge failed") }
        let finalCount = await tier.status()?.entryCount
        XCTAssertEqual(finalCount, 0, "retry after the fault clears completes the purge")
        await tier.shutdown()
    }

    /// M-F: the retention tick samples the CURRENT wall time, so an IDLE process (no
    /// reads/writes advancing the persisted clock) still cleans up entries past their
    /// creation-based retention deadline.
    func testIdleRetentionTickSamplesWallClock() async throws {
        let tier = makeTier(root: makeRoot())
        let __act = await tier.activateForControlPlane(); XCTAssertTrue(__act)
        let key = "conv:kvs-synth:idle-retain"
        // Create an entry; the write advances the persisted clock only to this instant.
        try await writeEntry(tier, key: key, seq: 5, nowMillis: 1_000_000)
        let __c0 = await tier.status()?.entryCount; XCTAssertEqual(__c0, 1)

        // No further request activity. A retention tick that (incorrectly) reused the
        // persisted clock high-water would never pass the deadline. Sampling real time
        // far past creation + retention window must evict it.
        let retentionSeconds = tier.config.retentionMinutes * 60
        let farFuture = 1_000_000 + (retentionSeconds + 60) * 1000
        await tier.store.setSweepClockForTest { farFuture }
        await tier.store.runRetentionTickForTest()

        let finalCount = await tier.status()?.entryCount
        XCTAssertEqual(finalCount, 0, "idle retention tick must evict entries past their retention deadline")
        await tier.shutdown()
    }

    /// HIGH-3: an unreadable tombstone directory must fail CLOSED — recovery
    /// quarantines the namespace rather than treating it as "no tombstones" (which
    /// would silently drop the purge fence and let a revoked entry re-admit).
    func testUnreadableTombstoneDirQuarantines() async throws {
        let tier = makeTier(root: makeRoot())
        let __act = await tier.activateForControlPlane(); XCTAssertTrue(__act)
        await tier.store.injectTombstoneListFailure(true)
        do {
            try await tier.store.runTombstoneRecoveryForTest()
            XCTFail("recovery must throw on an unreadable tombstone directory")
        } catch {
            // expected: quarantine
        }
        let quarantined = await tier.store.isQuarantinedForTest
        XCTAssertTrue(quarantined, "an unreadable tombstone dir must quarantine, never fail-open")
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
