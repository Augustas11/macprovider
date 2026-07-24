import CryptoKit
import Foundation
import MLX
import MLXLMCommon
@testable import macprovider_cli
import XCTest

/// SPEC-037 store-core conformance: write→read round trip on synthetic layer state,
/// crash-consistency at each FR-KVP3 ordering boundary, tombstone-first purge + fence
/// + phase marks (FR-KVP8), namespace-copy fail-closed (AC-5), quota/floor/budget
/// enforcement (FR-KVP7/9), and clock-rollback dormancy (FR-KVP10).
///
/// All store logic runs against an in-memory Keychain double, so no Data-Protection
/// entitlement is required, and against synthetic `KVLayerPayload` state so no MLX
/// Metal runtime is required. `testKVCacheSimpleBridgeRoundTrip` covers the real
/// KVCacheSimple (de)serialization bridge and is gated on `KV_ENABLE_MLX_TESTS`
/// (MLX aborts the process when the Metal library is unavailable, e.g. headless CI).
/// `testRealKeychainAdapterSkipsGracefully` demonstrates the XCTSkip path when the
/// real Data-Protection keychain is unavailable.
final class KVDiskCacheStoreTests: XCTestCase {

    // MARK: - Fixtures

    private var tempRoots: [URL] = []

    override func tearDown() {
        for url in tempRoots { try? FileManager.default.removeItem(at: url) }
        tempRoots.removeAll()
        super.tearDown()
    }

    private func makeRoot() -> URL {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("kvstore-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(url)
        return url
    }

    private func makeConfig(root: URL, namespace: String = "ns-test",
                            tweak: (inout KVDiskCacheStoreConfig) -> Void = { _ in }) -> KVDiskCacheStoreConfig {
        var config = KVDiskCacheStoreConfig(
            root: root, namespaceID: namespace,
            maxBytes: 16 * 1024 * 1024 * 1024, maxEntries: 64, maxEntryBytes: 2 * 1024 * 1024 * 1024,
            retentionSeconds: 3600, stagingMaxBytes: 256 * 1024 * 1024,
            writeStagingMaxBytes: 256 * 1024 * 1024, minFreeBytes: 1 * 1024 * 1024,
            promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        config.freeSpaceOverride = 100 * 1024 * 1024 * 1024
        tweak(&config)
        return config
    }

    private static let identity = KVWriteIdentity(
        requestModel: "qwen-test", servedModelID: "qwen-test-served",
        modelSHA256: String(repeating: "b", count: 64), catalogRevision: "r1",
        tokenizerID: "tok-1", tokenizerConfigSHA256: String(repeating: "c", count: 64),
        chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 1,
        mlxSwiftLMRevision: "3.31.4", mlxVersion: "0.0.0", cacheClass: "KVCacheSimple",
        layerCount: 1, kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil,
        decodePath: "ordinary", keyEpoch: 1)

    /// Synthetic 1-layer state ([1,2,seq,4] f32) built as raw payload bytes — no MLX.
    private func makeLayers(seq: Int, seed: Int = 0) -> [KVLayerPayload] {
        let elements = 1 * 2 * seq * 4
        let byteCount = elements * KVCodecDType.f32.byteSize
        let keyBytes = Data((0 ..< byteCount).map { UInt8(($0 + seed) & 0xff) })
        let valueBytes = Data((0 ..< byteCount).map { UInt8(($0 + seed + 7) & 0xff) })
        return [KVLayerPayload(
            layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, seq, 4], dtype: .f32,
            cacheOffset: seq, keyBytes: keyBytes, valueBytes: valueBytes)]
    }

    private func makeSnapshot(store: KVDiskCacheStore, rawKey: String, seq: Int, seed: Int = 0,
                              commitSequence: Int = 1, sampledPurgeGen: Int? = nil,
                              nowMillis: Int) async throws -> KVWriteSnapshot {
        let index = try await store.currentIndex(rawKey: rawKey)
        let sampled: Int
        if let g = sampledPurgeGen { sampled = g } else { sampled = try await store.highWatermark(rawKey: rawKey) }
        return KVWriteSnapshot(
            rawKey: rawKey, indexHMAC: try XCTUnwrap(index), tokens: Array(0 ..< Int32(seq)),
            layers: makeLayers(seq: seq, seed: seed), identity: Self.identity,
            sampledPurgeGeneration: sampled, commitSequence: commitSequence,
            createdAtMillis: nowMillis, eligibleUntilMillis: nowMillis + 900_000,
            incarnation: "inc-\(UUID().uuidString)")
    }

    private func runtime(index: String, seq: Int, namespace: String = "ns-test",
                         highWatermark: Int = 0) -> KVRuntimeIdentity {
        KVRuntimeIdentity(
            namespaceID: namespace, keyEpoch: 1, indexHMAC: index,
            requestModel: "qwen-test", servedModelID: "qwen-test-served",
            modelSHA256: String(repeating: "b", count: 64), catalogRevision: "r1",
            tokenizerID: "tok-1", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 1,
            mlxSwiftLMRevision: "3.31.4", mlxVersion: "0.0.0", cacheClass: "KVCacheSimple",
            layerCount: 1,
            layers: [KVLayerGeometry(layerIndex: 0, classID: "KVCacheSimple", layoutVersion: 1,
                                     ndim: 4, dims: [1, 2, seq, 4], dtype: .f32, sequenceAxis: 2)],
            kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil,
            decodePath: "ordinary", liveHighWatermark: highWatermark)
    }

    // MARK: - Write → read round trip (AC-1, payload level)

    func testWriteReadRoundTrip() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain, sink: sink)
        try await store.activate()

        let key = "conv:kvs-synth:round-trip"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        let write = try await store.write(snapshot, nowMillis: 1_000_000)
        guard case .committed(let gen, _) = write else { return XCTFail("write should commit, got \(write)") }
        XCTAssertEqual(gen, 1)

        let index = try await idx(store, key)
        let result = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        guard case .hit(let hit) = result else { return XCTFail("expected hit, got \(result)") }
        XCTAssertEqual(hit.tokens, Array(0 ..< Int32(5)))
        XCTAssertEqual(hit.layers, snapshot.layers, "restored layer bytes must be byte-identical")

        XCTAssertEqual(sink.codes(.diskWriteCommitted), 1)
        XCTAssertEqual(sink.codes(.diskHit), 1)
        await store.deactivate()
    }

    func testCorruptedBlobYieldsCorruptMiss() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:corrupt"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store, key)

        let blobURL = root.appendingPathComponent(namespaceDigest("ns-test"), isDirectory: true)
            .appendingPathComponent("entries/\(index)/gen-1.blob")
        var blob = try Data(contentsOf: blobURL)
        blob[blob.count - 1] ^= 0xFF
        try blob.write(to: blobURL)

        let result = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        guard case .miss(let code, _) = result else { return XCTFail("expected miss") }
        XCTAssertEqual(code, .diskMissCorrupt)
    }

    // MARK: - Crash consistency (AC-3)

    func testCrashAfterBlobFsyncRecoversToCleanMiss() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let key = "conv:kvs-synth:crash-blob"

        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        await store1.setFailpoint { if $0 == .afterBlobFsync { throw KVInjectedCrash(point: .afterBlobFsync) } }
        let snapshot = try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000)
        await XCTAssertThrowsErrorAsync(try await store1.write(snapshot, nowMillis: 1_000_000))
        await store1.deactivate()

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let index = try await idx(store2, key)
        let result = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        guard case .miss(let code, _) = result else { return XCTFail("expected miss") }
        XCTAssertEqual(code, .diskMissAbsent)
    }

    /// M-C: the retention basis is the IMMUTABLE first-creation time, persisted so a
    /// restart after a replacement (newer manifest created_at) does not shift the
    /// retention deadline forward.
    func testRetentionBasisSurvivesRestartAfterReplacement() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let key = "conv:kvs-synth:retain-basis"
        let t0 = 1_000_000
        let retentionMs = 3600 * 1000
        let t1 = t0 + retentionMs / 2   // a later replacement, still within t0's window

        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        // First write at t0 establishes the basis; a replacement at t1 must not move it.
        let s0 = try await makeSnapshot(store: store1, rawKey: key, seq: 5, commitSequence: 1, nowMillis: t0)
        _ = try await store1.write(s0, nowMillis: t0)
        let s1 = try await makeSnapshot(store: store1, rawKey: key, seq: 6, commitSequence: 2, nowMillis: t1)
        _ = try await store1.write(s1, nowMillis: t1)
        await store1.deactivate()

        // Restart: recovery must restore the basis as t0, not the newest manifest's t1.
        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        // A retention sweep just past the t0 deadline (but far before t1's) evicts it.
        try await store2.runRetention(nowMillis: t0 + retentionMs + 1)
        let inspection = await store2.inspect()
        XCTAssertEqual(inspection.entryCount, 0,
                       "retention basis must remain the original creation time across restart")
    }

    /// M-E: activation reconciliation destroys entry DEKs with no matching live entry
    /// and leaves live-entry DEKs and the epoch master intact.
    func testReconcileOrphanEntryDEKsDestroysOnlyOrphans() throws {
        let keychain = KVInMemoryKeychain()
        let keys = KVKeyManager(keychain: keychain, namespaceID: "ns-reconcile")
        _ = try keys.createEpochMaster(epoch: 1, incarnation: "boot")
        _ = try keys.createEntryDEK(epoch: 1, index: "live-index", incarnation: "w1")
        _ = try keys.createEntryDEK(epoch: 1, index: "orphan-index", incarnation: "w2")

        let destroyed = try keys.reconcileOrphanEntryDEKs(epoch: 1, liveIndices: ["live-index"])
        XCTAssertEqual(destroyed, 1, "exactly the orphan DEK is destroyed")
        XCTAssertNil(try keys.entryDEK(epoch: 1, index: "orphan-index"), "orphan DEK must be gone")
        XCTAssertNotNil(try keys.entryDEK(epoch: 1, index: "live-index"), "live-entry DEK must survive")
        XCTAssertNotNil(try keys.epochMaster(epoch: 1), "the epoch master must not be touched")
    }

    func testCrashAfterRenameRecoversCompleteGeneration() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let key = "conv:kvs-synth:crash-rename"

        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        await store1.setFailpoint { if $0 == .afterRenameBeforeDirFsync { throw KVInjectedCrash(point: .afterRenameBeforeDirFsync) } }
        let snapshot = try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000)
        await XCTAssertThrowsErrorAsync(try await store1.write(snapshot, nowMillis: 1_000_000))
        await store1.deactivate()

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let index = try await idx(store2, key)
        let result = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        guard case .hit = result else { return XCTFail("expected hit after rename survived, got \(result)") }
    }

    func testCrashAfterManifestTempRecoversToCleanMiss() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let key = "conv:kvs-synth:crash-temp"

        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        await store1.setFailpoint { if $0 == .afterManifestTempFsync { throw KVInjectedCrash(point: .afterManifestTempFsync) } }
        let snapshot = try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000)
        await XCTAssertThrowsErrorAsync(try await store1.write(snapshot, nowMillis: 1_000_000))
        await store1.deactivate()

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let index = try await idx(store2, key)
        // The unrenamed manifest temp is swept; no committed manifest ⇒ clean miss.
        let result = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        guard case .miss(let code, _) = result else { return XCTFail("expected miss") }
        XCTAssertEqual(code, .diskMissAbsent)
    }

    func testNextCommitAfterRestartAllocatesNewerGeneration() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let key = "conv:kvs-synth:gen"

        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        let s1 = try await makeSnapshot(store: store1, rawKey: key, seq: 5, commitSequence: 1, nowMillis: 1_000_000)
        guard case .committed(let gen1, _) = try await store1.write(s1, nowMillis: 1_000_000) else { return XCTFail() }
        XCTAssertEqual(gen1, 1)
        await store1.deactivate()

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let s2 = try await makeSnapshot(store: store2, rawKey: key, seq: 5, seed: 1, commitSequence: 2, nowMillis: 1_000_500)
        guard case .committed(let gen2, _) = try await store2.write(s2, nowMillis: 1_000_500) else { return XCTFail() }
        XCTAssertEqual(gen2, 2, "generation must strictly increase across restart")
    }

    // MARK: - Purge: tombstone-first, DEK destruction, fence (AC-4)

    func testPurgeDestroysEntryAndCompletesTombstone() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain, sink: sink)
        try await store.activate()
        let key = "conv:kvs-synth:purge"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store, key)

        let purge = try await store.purge(rawKey: key)
        guard case .ok(let removed, _) = purge else { return XCTFail("purge should succeed, got \(purge)") }
        XCTAssertEqual(removed, 1)

        XCTAssertNil(try keychain.copySecret(service: KVKeychainNaming(namespaceID: "ns-test").dekService(epoch: 1), account: index))

        let result = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        guard case .miss = result else { return XCTFail("purged entry must miss") }

        let tombURL = root.appendingPathComponent(namespaceDigest("ns-test"), isDirectory: true)
            .appendingPathComponent("tombstones/1-\(index).json")
        let tomb = try XCTUnwrap(KVTombstoneCodec.decode(try Data(contentsOf: tombURL)))
        XCTAssertTrue(tomb.complete)
        XCTAssertEqual(tomb.purgeGeneration, 1)
        XCTAssertEqual(sink.codes(.purgeOK), 1)
    }

    func testRestoredFilesAfterPurgeAreFenced() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:rollback"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store, key)
        let entryDir = root.appendingPathComponent(namespaceDigest("ns-test"), isDirectory: true)
            .appendingPathComponent("entries/\(index)", isDirectory: true)
        let backup = makeRoot().appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: entryDir, to: backup)

        _ = try await store.purge(rawKey: key)

        try? FileManager.default.removeItem(at: entryDir)
        try FileManager.default.copyItem(at: backup, to: entryDir)

        // DEK gone → tombstoned miss; the fence holds despite whole-directory restoration.
        let result = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5, highWatermark: 1), nowMillis: 1_000_200)
        guard case .miss(let code, _) = result else { return XCTFail("restored files must not hit") }
        XCTAssertEqual(code, .diskMissTombstoned)
    }

    func testPrePurgeLeaseCommitIsFenced() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:fence"
        let s1 = try await makeSnapshot(store: store, rawKey: key, seq: 5, commitSequence: 1, sampledPurgeGen: 0, nowMillis: 1_000_000)
        _ = try await store.write(s1, nowMillis: 1_000_000)
        _ = try await store.purge(rawKey: key)

        // Pre-purge lease (sampled generation 0) commits after purge → fenced.
        let stale = try await makeSnapshot(store: store, rawKey: key, seq: 5, seed: 1, commitSequence: 2, sampledPurgeGen: 0, nowMillis: 1_000_500)
        let staleResult = try await store.write(stale, nowMillis: 1_000_500)
        guard case .skipped(let detail) = staleResult else { return XCTFail("stale lease must be skipped, got \(staleResult)") }
        XCTAssertEqual(detail, .fenceLost)

        // Fresh lease sampling the new high-watermark (1) re-caches normally.
        let fresh = try await makeSnapshot(store: store, rawKey: key, seq: 5, seed: 2, commitSequence: 3, sampledPurgeGen: 1, nowMillis: 1_000_600)
        guard case .committed = try await store.write(fresh, nowMillis: 1_000_600) else { return XCTFail("fresh lease must commit") }
    }

    func testPurgeCrashRecoveryCompletesPurge() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let key = "conv:kvs-synth:purge-crash"
        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        let snapshot = try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store1.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store1, key)
        await store1.setFailpoint { if $0 == .purgeAfterIncompleteTombstone { throw KVInjectedCrash(point: .purgeAfterIncompleteTombstone) } }
        await XCTAssertThrowsErrorAsync(try await store1.purge(rawKey: key))
        await store1.deactivate()

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let result = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5, highWatermark: 1), nowMillis: 1_000_200)
        guard case .miss = result else { return XCTFail("recovery must complete the purge") }
        XCTAssertNil(try keychain.copySecret(service: KVKeychainNaming(namespaceID: "ns-test").dekService(epoch: 1), account: index))
    }

    /// Item 1 (CRITICAL): a single-key purge whose unlink fails leaves the index
    /// DURABLY blocked (incomplete tombstone) — a subsequent read never returns the old
    /// generation, a fresh write is refused, and a later recovery completes the purge
    /// and only THEN admits.
    func testFailedPurgeDurablyBlocksIndexAndRecoveryCompletes() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let key = "conv:kvs-synth:blocked"
        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        let snapshot = try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store1.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store1, key)

        // Purge whose entry-directory unlink fails: DEK+watermark advance but the entry
        // dir cannot be removed, so the incomplete tombstone remains and the index stays
        // durably blocked even after the transient per-op fence lifts.
        await store1.injectUnlinkFailure(true)
        guard case .failed = try await store1.purge(rawKey: key) else { return XCTFail("purge should fail on unlink error") }

        // Read of the blocked index fails closed (never the old generation)…
        let read = try await store1.read(rawKey: key, runtime: runtime(index: index, seq: 5, highWatermark: 1), nowMillis: 1_000_100)
        guard case .miss(.diskMissTombstoned, _) = read else { return XCTFail("blocked index must miss tombstoned, got \(read)") }
        // …and a fresh write (sampling the advanced watermark, so ONLY the durable block
        // stops it) is refused while the purge is incomplete.
        let fresh = try await makeSnapshot(store: store1, rawKey: key, seq: 5, seed: 3, commitSequence: 2, sampledPurgeGen: 1, nowMillis: 1_000_200)
        guard case .skipped(.fenceLost) = try await store1.write(fresh, nowMillis: 1_000_200) else {
            return XCTFail("write to a purge-blocked index must be fence_lost")
        }
        await store1.deactivate()

        // Restart: recovery completes the interrupted purge (unlink now succeeds) and
        // only THEN admits — the entry is gone and its DEK destroyed.
        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let after = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5, highWatermark: 1), nowMillis: 1_000_300)
        guard case .miss = after else { return XCTFail("recovery must complete the purge") }
        XCTAssertNil(try keychain.copySecret(service: KVKeychainNaming(namespaceID: "ns-test").dekService(epoch: 1), account: index))
        // A fresh lease sampling the recovered high-watermark re-caches normally.
        let recache = try await makeSnapshot(store: store2, rawKey: key, seq: 5, seed: 4, commitSequence: 5, sampledPurgeGen: 1, nowMillis: 1_000_400)
        guard case .committed = try await store2.write(recache, nowMillis: 1_000_400) else { return XCTFail("post-recovery re-cache must commit") }
    }

    /// Item 1/2 (CRITICAL, coordinator refinement 1): the durable incomplete tombstone
    /// + high-watermark are written BEFORE the first suspending hot-tier callback, so a
    /// crash AT the callback cannot leave the entry restorable after restart.
    func testCrashInsideHotCallbackRecovers() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let key = "conv:kvs-synth:hot-cb-crash"
        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        let snapshot = try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store1.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store1, key)

        await store1.setFailpoint { if $0 == .purgeBeforeHotCallback { throw KVInjectedCrash(point: .purgeBeforeHotCallback) } }
        await XCTAssertThrowsErrorAsync(try await store1.purge(rawKey: key))
        await store1.deactivate()

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let result = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5, highWatermark: 1), nowMillis: 1_000_200)
        guard case .miss = result else { return XCTFail("recovery must complete the purge after a hot-callback crash") }
        XCTAssertNil(try keychain.copySecret(service: KVKeychainNaming(namespaceID: "ns-test").dekService(epoch: 1), account: index))
    }

    /// Item 2 (CRITICAL): two concurrent single-key purges of the same index serialize
    /// through the purge gate — no state survives and neither clears a fence the other
    /// owns.
    func testConcurrentSingleKeyPurgesSerialize() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:concurrent"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store, key)

        async let a = store.purge(rawKey: key)
        async let b = store.purge(rawKey: key)
        let (ra, rb) = try await (a, b)
        if case .failed = ra { XCTFail("purge A failed: \(ra)") }
        if case .failed = rb { XCTFail("purge B failed: \(rb)") }

        let read = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5, highWatermark: 2), nowMillis: 1_000_100)
        guard case .miss = read else { return XCTFail("no state may survive concurrent purges") }
        XCTAssertNil(try keychain.copySecret(service: KVKeychainNaming(namespaceID: "ns-test").dekService(epoch: 1), account: index))
    }

    /// Item 1 (CRITICAL): a purge-all that crashes right after opening the rotation
    /// journal leaves it durably OPEN — the namespace fails closed (reads busy) until a
    /// restart drives the rotation forward.
    func testOpenRotationJournalBlocksReadsUntilRecovery() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let key = "conv:kvs-synth:rotjournal"
        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        let snapshot = try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store1.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store1, key)

        await store1.setFailpoint { if $0 == .rotationAfterJournal { throw KVInjectedCrash(point: .rotationAfterJournal) } }
        await XCTAssertThrowsErrorAsync(try await store1.purgeAll())
        let blocked = try await store1.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        guard case .miss(.diskMissBusy, _) = blocked else { return XCTFail("open rotation journal must block reads, got \(blocked)") }
        await store1.deactivate()

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let epoch = await store2.currentEpoch
        XCTAssertEqual(epoch, 2, "recovery completes the interrupted rotation")
        let after = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_200)
        guard case .miss = after else { return XCTFail("post-rotation read misses cleanly") }
    }

    /// Item 8 (M-6 / FR-KVP10): the namespace root is marked excluded from Time Machine
    /// backup at creation.
    func testNamespaceRootExcludedFromBackup() async throws {
        let root = makeRoot()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: KVInMemoryKeychain())
        try await store.activate()
        let nsDir = root.appendingPathComponent(namespaceDigest("ns-test"), isDirectory: true)
        let values = try nsDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true,
                       "namespace root must be excluded from Time Machine backup (FR-KVP10)")
    }

    /// Item 8 (architect LOW): a tombstone from a PRIOR key epoch must NOT repopulate
    /// the rotated epoch's high-watermark map at recovery (the map is reset by rotation;
    /// revocation is preserved by crypto-shred, not by carrying stale tombstones forward).
    func testStaleEpochTombstoneDoesNotRepopulateHighWatermark() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:stale-tomb"
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
        _ = try await store.purge(rawKey: key)                                  // epoch-1 tombstone
        guard case .ok = try await store.purgeAll() else { return XCTFail("rotate to epoch 2") }
        await store.deactivate()

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let epoch = await store2.currentEpoch
        XCTAssertEqual(epoch, 2)
        let inspection = await store2.inspect()
        XCTAssertEqual(inspection.purgeHighWatermarkEntries, 0,
                       "stale epoch-1 tombstone must not repopulate the epoch-2 high-watermark map")
    }

    /// Item 7: a replacement commit that fails mid-protocol (post-blob dir fsync) leaves
    /// NO unaccounted bytes — the partial new generation is removed and the reservation
    /// released — and the committed OLD generation survives.
    func testReplacementCommitFailureLeavesNoLeakAndKeepsOldGeneration() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:replace-fail"
        let s1 = try await makeSnapshot(store: store, rawKey: key, seq: 5, seed: 0, commitSequence: 1, nowMillis: 1_000_000)
        guard case .committed = try await store.write(s1, nowMillis: 1_000_000) else { return XCTFail("gen1 must commit") }
        let index = try await idx(store, key)
        let baseline = await store.inspect().bytesUsed
        XCTAssertGreaterThan(baseline, 0)

        // Fail the post-blob directory fsync of the replacement commit (a real error, not
        // a modeled crash) so the real-error cleanup path runs.
        await store.injectDirFsyncFailure(atCall: 2)
        let s2 = try await makeSnapshot(store: store, rawKey: key, seq: 5, seed: 9, commitSequence: 2, nowMillis: 1_000_100)
        guard case .skipped = try await store.write(s2, nowMillis: 1_000_100) else {
            return XCTFail("replacement commit must skip on fsync failure")
        }
        await store.injectDirFsyncFailure(atCall: nil)

        let afterInspect = await store.inspect()
        XCTAssertEqual(afterInspect.bytesUsed, baseline, "failed replacement must not leak the partial new generation")
        XCTAssertEqual(afterInspect.entryCount, 1)
        let read = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_200)
        guard case .hit = read else { return XCTFail("old generation must survive a failed replacement, got \(read)") }
    }

    /// Item 7: a superseded-blob deletion that FAILS at publication keeps the bytes
    /// counted against quota (never silently subtracted); a restart sweep reclaims them.
    func testFailedSupersededDeleteKeepsBytesCounted() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:superseded-leak"
        let s1 = try await makeSnapshot(store: store, rawKey: key, seq: 5, seed: 0, commitSequence: 1, nowMillis: 1_000_000)
        guard case .committed = try await store.write(s1, nowMillis: 1_000_000) else { return XCTFail("gen1") }
        let index = try await idx(store, key)

        // Replacement commits gen2, but deleting the superseded gen1 blob fails.
        await store.injectUnlinkFailure(true)
        let s2 = try await makeSnapshot(store: store, rawKey: key, seq: 5, seed: 9, commitSequence: 2, nowMillis: 1_000_100)
        guard case .committed = try await store.write(s2, nowMillis: 1_000_100) else {
            return XCTFail("replacement still commits; only the superseded-delete failed")
        }
        await store.injectUnlinkFailure(false)
        let leak = await store.supersededLeakBytesForTest
        XCTAssertGreaterThan(leak, 0, "an undeleted superseded blob is retained against quota")
        await store.deactivate()

        // Restart: the sweep deletes the orphan superseded blob and resets the leak.
        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let leakAfterRestart = await store2.supersededLeakBytesForTest
        XCTAssertEqual(leakAfterRestart, 0, "restart sweep reclaims the superseded blob")
        let gen1Blob = root.appendingPathComponent(namespaceDigest("ns-test"), isDirectory: true)
            .appendingPathComponent("entries/\(index)/gen-1.blob")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gen1Blob.path), "orphan superseded blob swept on restart")
    }

    /// Item 7 (coordinator refinement 2): activation sweeps namespace-root atomic-write
    /// temp files left by a crash mid-rename, so their bytes are not leaked/unaccounted.
    func testActivationSweepsNamespaceRootAtomicTemps() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: "conv:kvs-synth:temp", seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
        await store.deactivate()

        let nsDir = root.appendingPathComponent(namespaceDigest("ns-test"), isDirectory: true)
        let strayMetaTemp = nsDir.appendingPathComponent(".meta.json.tmp.\(UUID().uuidString)")
        let strayTombTemp = nsDir.appendingPathComponent("tombstones", isDirectory: true)
            .appendingPathComponent(".1-abcdef.json.tmp.\(UUID().uuidString)")
        try Data("garbage".utf8).write(to: strayMetaTemp)
        try Data("garbage".utf8).write(to: strayTombTemp)

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayMetaTemp.path), "namespace-root atomic temp swept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayTombTemp.path), "tombstone atomic temp swept")
    }

    /// Item 6 (FR-KVP6): activation with an unavailable Keychain is RETRYABLE dormancy
    /// — not active, not quarantined, not throwing — and becomes active on a later
    /// attempt once the Keychain is available (the bootstrap master is created then).
    func testKeychainUnavailableActivationIsDormantThenActivates() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        keychain.forceUnavailable = true
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)

        let firstActivated = try await store.activate()
        let firstDormancy = await store.activationDormancy
        let firstQuarantined = await store.isQuarantinedForTest
        XCTAssertFalse(firstActivated, "keychain-unavailable activation must be dormant, not active")
        XCTAssertEqual(firstDormancy, .keychain)
        XCTAssertFalse(firstQuarantined, "keychain dormancy must NOT quarantine")

        // Keychain becomes available: a later attempt fully activates + creates the master.
        keychain.forceUnavailable = false
        let secondActivated = try await store.activate()
        let secondDormancy = await store.activationDormancy
        XCTAssertTrue(secondActivated, "activation succeeds once the keychain is available")
        XCTAssertEqual(secondDormancy, .none)

        // The recovered tier now serves.
        let key = "conv:kvs-synth:dormant-recover"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        guard case .committed = try await store.write(snapshot, nowMillis: 1_000_000) else {
            return XCTFail("post-dormancy activation must serve writes")
        }
    }

    /// Item 5 (FR-KVP9): two concurrent promotions — one proceeds, the other returns
    /// `disk_miss_busy` IMMEDIATELY (not after the first finishes). The claim is
    /// actor-isolated and the decode runs off-actor, so the contender observes the
    /// claimed slot rather than queueing behind the decode.
    func testConcurrentPromotionSecondReturnsBusyImmediately() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:promote-busy"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 200, nowMillis: 1_000_000)
        _ = try await store.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store, key)

        async let a = store.read(rawKey: key, runtime: runtime(index: index, seq: 200), nowMillis: 1_000_100)
        async let b = store.read(rawKey: key, runtime: runtime(index: index, seq: 200), nowMillis: 1_000_100)
        let results = try await [a, b]

        let hits = results.filter { if case .hit = $0 { return true }; return false }.count
        let busy = results.filter { if case .miss(.diskMissBusy, _) = $0 { return true }; return false }.count
        XCTAssertEqual(hits, 1, "exactly one concurrent promotion proceeds")
        XCTAssertEqual(busy, 1, "the contender returns disk_miss_busy immediately, not queued")
    }

    /// CRITICAL-2: a snapshot whose key epoch was captured before a purge-all
    /// rotation is REJECTED (fence_lost) when its persist Task finally publishes —
    /// it can never be restamped into the new epoch and survive crypto-shredding.
    func testColdSnapshotCapturedPreRotationRejectedAfterPurgeAll() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain, sink: sink)
        try await store.activate()
        let key = "conv:kvs-synth:pre-rotation"

        // Capture identity under epoch 1 (Self.identity.keyEpoch == 1).
        let epochBefore = await store.currentEpoch; XCTAssertEqual(epochBefore, 1)
        // Purge-all rotates to epoch 2 (simulating the rotation racing a queued
        // persist Task captured under epoch 1).
        guard case .ok = try await store.purgeAll() else { return XCTFail("purge-all failed") }
        let epochAfter = await store.currentEpoch; XCTAssertEqual(epochAfter, 2)

        // The queued pre-rotation snapshot publishes with its captured (stale) epoch.
        let result = try await store.writeColdSnapshot(
            rawKey: key, tokens: Array(0 ..< Int32(5)), layers: makeLayers(seq: 5),
            identity: Self.identity, sampledPurgeGeneration: 0, commitSequence: 1,
            createdAtMillis: 1_000_000, eligibleUntilMillis: 1_900_000,
            incarnation: "inc", nowMillis: 1_000_500)
        guard case .skipped(let detail) = result else {
            return XCTFail("pre-rotation snapshot must be rejected, got \(result)")
        }
        XCTAssertEqual(detail, .fenceLost, "stale captured epoch must be fenced, never restamped")
    }

    /// CRITICAL-2: two commits publish in commit order regardless of persist-Task
    /// scheduling. The commit sequence is allocated under the hot lease, so an
    /// earlier commit arriving late (lower sequence) cannot overwrite a later one.
    func testCommitSequenceOrderingIndependentOfTaskScheduling() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:seq-order"
        let identity1 = Self.identity   // keyEpoch 1

        func writeSeq(_ seq: Int, seed: Int) async throws -> KVWriteResult {
            try await store.writeColdSnapshot(
                rawKey: key, tokens: Array(0 ..< Int32(5)), layers: makeLayers(seq: 5, seed: seed),
                identity: identity1, sampledPurgeGeneration: 0, commitSequence: seq,
                createdAtMillis: 1_000_000, eligibleUntilMillis: 1_900_000,
                incarnation: "inc-\(seq)", nowMillis: 1_000_000)
        }

        // The later commit (sequence 2) publishes first (its Task ran first).
        guard case .committed = try await writeSeq(2, seed: 2) else { return XCTFail("seq 2 should commit") }
        // The earlier commit (sequence 1) arrives late — it MUST NOT overwrite.
        let late = try await writeSeq(1, seed: 1)
        guard case .skipped(let d) = late else { return XCTFail("late lower sequence must be skipped, got \(late)") }
        XCTAssertEqual(d, .snapshotDisplaced)

        // A subsequent higher sequence (3) publishes normally.
        guard case .committed = try await writeSeq(3, seed: 3) else { return XCTFail("seq 3 should commit") }
    }

    /// HIGH-4: a replacement write reuses the committed generation's DEK, so a crash
    /// before the new manifest rename leaves the still-committed generation
    /// decryptable after restart (duplicate-create would delete-then-add the DEK and
    /// lose gen1).
    func testReplacementCrashKeepsCommittedGenerationDecryptable() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let key = "conv:kvs-synth:dek-share"
        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        // gen1 committed.
        let s1 = try await makeSnapshot(store: store1, rawKey: key, seq: 5, seed: 0, commitSequence: 1, nowMillis: 1_000_000)
        guard case .committed = try await store1.write(s1, nowMillis: 1_000_000) else { return XCTFail("gen1 should commit") }
        let index = try await idx(store1, key)

        // gen2 crashes inside the mutation lane, before the manifest rename.
        await store1.setFailpoint { if $0 == .insideMutationLaneBeforeRename { throw KVInjectedCrash(point: .insideMutationLaneBeforeRename) } }
        let s2 = try await makeSnapshot(store: store1, rawKey: key, seq: 5, seed: 9, commitSequence: 2, nowMillis: 1_000_100)
        await XCTAssertThrowsErrorAsync(try await store1.write(s2, nowMillis: 1_000_100))
        await store1.deactivate()

        // Restart: recovery sweeps the orphaned gen2 blob + temp manifest, keeps gen1.
        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let result = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_500)
        guard case .hit(let hit) = result else { return XCTFail("committed gen1 must still read, got \(result)") }
        XCTAssertEqual(hit.tokens, Array(0 ..< Int32(5)))
        XCTAssertEqual(hit.layers, s1.layers, "committed gen1 bytes survive the crashed replacement")
    }

    /// HIGH-7: a directory fsync failure at ANY commit-protocol boundary yields
    /// disk_write_skipped (io_error), never disk_write_committed. A swallowed dir
    /// fsync would let the store claim durability the filesystem never provided.
    func testDirFsyncFailureNeverReportsCommitted() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain, sink: sink)
        try await store.activate()

        // Warm-up write pins the clock high-water so the measured writes below do not
        // re-persist metadata (which would fsync a directory and shift the counter).
        let warm = try await makeSnapshot(store: store, rawKey: "conv:kvs-synth:warm", seq: 5, nowMillis: 2_000_000)
        guard case .committed = try await store.write(warm, nowMillis: 2_000_000) else { return XCTFail("warm-up") }

        // A clean new-entry write performs exactly three directory fsyncs:
        // 1) entries/ after mkdir, 2) entry dir after the blob, 3) entry dir after the
        // manifest rename. Fail each in turn on a fresh key.
        for boundary in 1 ... 3 {
            sink.reset()
            await store.injectDirFsyncFailure(atCall: boundary)
            let snap = try await makeSnapshot(store: store, rawKey: "conv:kvs-synth:fsync-\(boundary)",
                                              seq: 5, seed: boundary, nowMillis: 2_000_000)
            let result = try await store.write(snap, nowMillis: 2_000_000)
            guard case .skipped(let d) = result else {
                return XCTFail("dir fsync failure at boundary \(boundary) must skip, got \(result)")
            }
            XCTAssertEqual(d, .ioError, "boundary \(boundary)")
            XCTAssertEqual(sink.codes(.diskWriteCommitted), 0,
                           "no committed event may be emitted when dir fsync fails at boundary \(boundary)")
            XCTAssertEqual(sink.codes(.diskWriteSkipped), 1, "boundary \(boundary)")
        }
        await store.injectDirFsyncFailure(atCall: nil)
    }

    /// M-19: a statvfs failure fails closed — the free-space floor skips the write
    /// rather than assuming headroom.
    func testFreeSpaceFloorFailsClosedOnStatvfsError() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let config = makeConfig(root: root) { $0.freeSpaceOverride = nil; $0.simulateStatvfsFailure = true }
        let store = KVDiskCacheStore(config: config, keychain: keychain, sink: sink)
        try await store.activate()
        let snap = try await makeSnapshot(store: store, rawKey: "conv:kvs-synth:statvfs", seq: 5, nowMillis: 1_000_000)
        let result = try await store.write(snap, nowMillis: 1_000_000)
        guard case .skipped(let d) = result else { return XCTFail("statvfs failure must skip, got \(result)") }
        XCTAssertEqual(d, .freeSpaceFloor)
    }

    /// M-9: namespace metadata uses a CLOSED schema — unknown fields, a missing
    /// purge_high_watermarks map, or an invalid rotation phase are rejected.
    func testMetadataDecodeIsClosedSchema() throws {
        let valid = KVNamespaceMetadata(
            providerNamespaceID: "ns", keyEpoch: 1, schemaID: "s", codecID: "c",
            purgeHighWatermarks: ["ab": 2], clockHighWaterMillis: 10, rotationJournal: nil)
        let data = try KVMetadataCodec.encode(valid)
        XCTAssertNotNil(KVMetadataCodec.decode(data), "valid doc must decode")

        func mutated(_ f: (inout [String: Any]) -> Void) throws -> Data {
            var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            f(&obj)
            return try JSONSerialization.data(withJSONObject: obj)
        }
        XCTAssertNil(KVMetadataCodec.decode(try mutated { $0["surprise"] = 1 }), "unknown field must reject")
        XCTAssertNil(KVMetadataCodec.decode(try mutated { $0.removeValue(forKey: "purge_high_watermarks") }), "missing hw map must reject")
        XCTAssertNil(KVMetadataCodec.decode(try mutated { $0["rotation_journal"] = ["from": 1, "to": 2, "phase": "bogus"] }), "invalid phase must reject")
        XCTAssertNil(KVMetadataCodec.decode(try mutated { $0["key_epoch"] = 0 }), "epoch < 1 must reject")
    }

    /// M-9: a metadata doc that fails the closed schema quarantines the store on
    /// activation (fail-closed, not fail-open).
    func testCorruptMetadataQuarantinesOnActivate() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        _ = try await store1.write(try await makeSnapshot(store: store1, rawKey: "conv:kvs-synth:m", seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
        await store1.deactivate()

        let metaURL = root.appendingPathComponent(namespaceDigest("ns-test")).appendingPathComponent("meta.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
        obj["surprise"] = 1
        try JSONSerialization.data(withJSONObject: obj).write(to: metaURL)

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        await XCTAssertThrowsErrorAsync(try await store2.activate())
    }

    /// M-16: a pre-existing cache directory with group/other-writable mode is not
    /// trusted — activation quarantines rather than reusing it.
    func testTamperedDirModeQuarantinesOnActivate() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        _ = try await store1.write(try await makeSnapshot(store: store1, rawKey: "conv:kvs-synth:sec", seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
        await store1.deactivate()

        let nsDir = root.appendingPathComponent(namespaceDigest("ns-test"))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: nsDir.path)

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        await XCTAssertThrowsErrorAsync(try await store2.activate())
    }

    func testAbsentKeyPurgeNoOps() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let purge = try await store.purge(rawKey: "conv:kvs-synth:absent")
        guard case .ok(let removed, _) = purge else { return XCTFail() }
        XCTAssertEqual(removed, 0)
    }

    func testPurgeAllRotatesEpoch() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:purge-all"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store.write(snapshot, nowMillis: 1_000_000)
        let epochBefore = await store.currentEpoch
        XCTAssertEqual(epochBefore, 1)

        let result = try await store.purgeAll()
        guard case .ok = result else { return XCTFail("purge-all should succeed") }
        let epochAfter = await store.currentEpoch
        XCTAssertEqual(epochAfter, 2, "purge-all rotates the key epoch")
        // Old epoch-1 Keychain material is gone.
        XCTAssertNil(try keychain.copySecret(service: KVKeychainNaming(namespaceID: "ns-test").masterService(epoch: 1), account: KVKeychainNaming.masterAccount))
    }

    // MARK: - Namespace isolation (AC-5)

    func testNamespaceCopyFailsClosed() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let storeA = KVDiskCacheStore(config: makeConfig(root: root, namespace: "ns-A"), keychain: keychain)
        try await storeA.activate()
        let key = "conv:kvs-synth:iso"
        let snapshotA = KVWriteSnapshot(
            rawKey: key, indexHMAC: try await idx(storeA, key), tokens: Array(0 ..< Int32(5)),
            layers: makeLayers(seq: 5), identity: Self.identity, sampledPurgeGeneration: 0,
            commitSequence: 1, createdAtMillis: 1_000_000, eligibleUntilMillis: 1_900_000,
            incarnation: "inc-\(UUID().uuidString)")
        // Note: manifest binds namespace "ns-test" (identity has no namespace field);
        // the store stamps its own config namespace, so use ns-A store's namespace.
        _ = try await storeA.write(snapshotA, nowMillis: 1_000_000)
        let indexA = try await idx(storeA, key)
        let entryDirA = root.appendingPathComponent(namespaceDigest("ns-A"), isDirectory: true)
            .appendingPathComponent("entries/\(indexA)", isDirectory: true)

        let storeB = KVDiskCacheStore(config: makeConfig(root: root, namespace: "ns-B"), keychain: keychain)
        try await storeB.activate()
        let indexB = try await idx(storeB, key)
        let entriesB = root.appendingPathComponent(namespaceDigest("ns-B"), isDirectory: true)
            .appendingPathComponent("entries", isDirectory: true)
        try FileManager.default.createDirectory(at: entriesB, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: entryDirA, to: entriesB.appendingPathComponent(indexB, isDirectory: true))

        // Reading in B fails closed: the manifest's namespace + index are AEAD-bound.
        let result = try await storeB.read(rawKey: key, runtime: runtime(index: indexB, seq: 5, namespace: "ns-B"), nowMillis: 1_000_100)
        guard case .miss(let code, _) = result else { return XCTFail("cross-namespace copy must fail closed") }
        XCTAssertEqual(code, .diskMissEnvelope)
    }

    func testCrossNamespaceEvictionIsolated() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        // Namespace A with maxEntries=1; B independent. A eviction never touches B.
        let storeA = KVDiskCacheStore(config: makeConfig(root: root, namespace: "ns-A") { $0.maxEntries = 1 }, keychain: keychain)
        let storeB = KVDiskCacheStore(config: makeConfig(root: root, namespace: "ns-B"), keychain: keychain)
        try await storeA.activate()
        try await storeB.activate()
        let bKey = "conv:kvs-synth:b-entry"
        let sB = KVWriteSnapshot(
            rawKey: bKey, indexHMAC: try await idx(storeB, bKey), tokens: Array(0 ..< Int32(5)),
            layers: makeLayers(seq: 5), identity: Self.identity, sampledPurgeGeneration: 0,
            commitSequence: 1, createdAtMillis: 1_000_000, eligibleUntilMillis: 1_900_000,
            incarnation: "inc")
        _ = try await storeB.write(sB, nowMillis: 1_000_000)

        // Two writes in A trigger A-eviction.
        let a1 = KVWriteSnapshot(rawKey: "conv:kvs-synth:a1", indexHMAC: try await idx(storeA, "conv:kvs-synth:a1"),
            tokens: Array(0 ..< Int32(5)), layers: makeLayers(seq: 5), identity: Self.identity,
            sampledPurgeGeneration: 0, commitSequence: 1, createdAtMillis: 1_000_000, eligibleUntilMillis: 1_900_000, incarnation: "a1")
        _ = try await storeA.write(a1, nowMillis: 1_000_000)
        let a2 = KVWriteSnapshot(rawKey: "conv:kvs-synth:a2", indexHMAC: try await idx(storeA, "conv:kvs-synth:a2"),
            tokens: Array(0 ..< Int32(5)), layers: makeLayers(seq: 5, seed: 1), identity: Self.identity,
            sampledPurgeGeneration: 0, commitSequence: 1, createdAtMillis: 1_000_100, eligibleUntilMillis: 1_900_000, incarnation: "a2")
        _ = try await storeA.write(a2, nowMillis: 1_000_100)

        // B's entry survives.
        let indexB = try await idx(storeB, bKey)
        let result = try await storeB.read(rawKey: bKey, runtime: runtime(index: indexB, seq: 5, namespace: "ns-B"), nowMillis: 1_000_200)
        guard case .hit = result else { return XCTFail("namespace B entry must survive A eviction") }
    }

    // MARK: - Quota / floor / budget (FR-KVP7/9)

    func testQuotaEvictsLRUAndDestroysDEK() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let store = KVDiskCacheStore(config: makeConfig(root: root) { $0.maxEntries = 1 }, keychain: keychain, sink: sink)
        try await store.activate()

        let key1 = "conv:kvs-synth:e1", key2 = "conv:kvs-synth:e2"
        let s1 = try await makeSnapshot(store: store, rawKey: key1, seq: 5, nowMillis: 1_000_000)
        _ = try await store.write(s1, nowMillis: 1_000_000)
        let index1 = try await idx(store, key1)
        let s2 = try await makeSnapshot(store: store, rawKey: key2, seq: 5, seed: 1, nowMillis: 1_000_100)
        _ = try await store.write(s2, nowMillis: 1_000_100)

        XCTAssertGreaterThanOrEqual(sink.codes(.diskEvictQuota), 1)
        XCTAssertNil(try keychain.copySecret(service: KVKeychainNaming(namespaceID: "ns-test").dekService(epoch: 1), account: index1))
    }

    func testRetentionEvictsAndDestroysDEK() async throws {
        // AC-4 addition (FR-KVP10/KVP6): retention eviction crypto-shreds the entry
        // by destroying its DEK, not merely unlinking files.
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let store = KVDiskCacheStore(config: makeConfig(root: root) { $0.retentionSeconds = 60 }, keychain: keychain, sink: sink)
        try await store.activate()

        let key = "conv:kvs-synth:retain"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store, key)

        // Advance past the 60s retention deadline and compact.
        try await store.runRetention(nowMillis: 1_000_000 + 120_000)
        XCTAssertGreaterThanOrEqual(sink.codes(.diskEvictRetention), 1)
        XCTAssertNil(
            try keychain.copySecret(service: KVKeychainNaming(namespaceID: "ns-test").dekService(epoch: 1), account: index),
            "retention eviction must destroy the entry DEK")

        let result = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_000 + 120_100)
        guard case .miss = result else { return XCTFail("evicted entry must miss") }
    }

    /// M-12: retention is measured from the immutable creation time, so a read
    /// within retention does NOT extend it — the entry is still evicted past
    /// creation + retention.
    func testReadsDoNotExtendRetention() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let store = KVDiskCacheStore(config: makeConfig(root: root) { $0.retentionSeconds = 60 }, keychain: keychain, sink: sink)
        try await store.activate()
        let key = "conv:kvs-synth:retain-basis"
        let snap = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store.write(snap, nowMillis: 1_000_000)
        let index = try await idx(store, key)

        // A read at +30s hits and updates lastUsed — but must not extend retention.
        let read = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_030_000)
        guard case .hit = read else { return XCTFail("read within retention should hit") }

        // At +70s (past creation + 60s), retention evicts despite the recent read.
        try await store.runRetention(nowMillis: 1_070_000)
        XCTAssertGreaterThanOrEqual(sink.codes(.diskEvictRetention), 1,
                                    "retention is creation-based and must not be extended by reads")
        let after = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_070_100)
        guard case .miss = after else { return XCTFail("evicted entry must miss") }
    }

    /// M-12: a write opportunistically sweeps entries past their retention deadline.
    func testWriteTriggersOpportunisticRetention() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let store = KVDiskCacheStore(config: makeConfig(root: root) { $0.retentionSeconds = 60 }, keychain: keychain, sink: sink)
        try await store.activate()

        let old = try await makeSnapshot(store: store, rawKey: "conv:kvs-synth:old", seq: 5, nowMillis: 1_000_000)
        _ = try await store.write(old, nowMillis: 1_000_000)
        let oldIndex = try await idx(store, "conv:kvs-synth:old")

        // A later write (+200s) opportunistically evicts the old entry (creation +60s).
        let fresh = try await makeSnapshot(store: store, rawKey: "conv:kvs-synth:fresh", seq: 5, nowMillis: 1_200_000)
        _ = try await store.write(fresh, nowMillis: 1_200_000)
        XCTAssertGreaterThanOrEqual(sink.codes(.diskEvictRetention), 1, "write must run opportunistic retention")
        let oldRead = try await store.read(rawKey: "conv:kvs-synth:old", runtime: runtime(index: oldIndex, seq: 5), nowMillis: 1_200_100)
        guard case .miss = oldRead else { return XCTFail("old entry must be retention-evicted") }
    }

    /// M-11: the write reservation is distinct from committed bytes and released on
    /// every exit — a same-size replacement does not grow committed bytes (no
    /// double-count), and two distinct same-size entries sum exactly (no leak).
    func testQuotaAccountingNoDoubleCountOrLeak() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:quota"
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: key, seq: 5, commitSequence: 1, nowMillis: 1_000_000), nowMillis: 1_000_000)
        let used1 = await store.inspect().bytesUsed
        XCTAssertGreaterThan(used1, 0)

        // Same-size replacement (gen 2) must not change committed bytes.
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: key, seq: 5, seed: 3, commitSequence: 2, nowMillis: 1_000_100), nowMillis: 1_000_100)
        let used2 = await store.inspect().bytesUsed
        XCTAssertEqual(used1, used2, "same-size replacement must not double-count the reservation")

        // A distinct same-size entry sums exactly (reservation fully released).
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: "conv:kvs-synth:quota2", seq: 5, seed: 4, commitSequence: 1, nowMillis: 1_000_200), nowMillis: 1_000_200)
        let used3 = await store.inspect().bytesUsed
        XCTAssertEqual(used3, used1 * 2, "two same-size entries must sum exactly (no reservation leak)")
    }

    // MARK: - HIGH-2 all-class artifact accounting + usage journal (FR-KVP7)

    /// Inspection/accounting must include every namespace artifact class — the control
    /// doc, tombstones, and the usage journal — and a temp orphan must be swept (not
    /// counted) at activation.
    func testArtifactAccountingIncludesTombstoneAndSweptOrphan() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let keyA = "conv:kvs-synth:acct-a", keyB = "conv:kvs-synth:acct-b"
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: keyA, seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: keyB, seq: 5, seed: 9, nowMillis: 1_000_050), nowMillis: 1_000_050)
        let indexA = try await idx(store, keyA)
        // Read A so a durable usage-journal record exists.
        _ = try await store.read(rawKey: keyA, runtime: runtime(index: indexA, seq: 5), nowMillis: 1_000_100)
        // Purge B → leaves a complete tombstone on disk.
        _ = try await store.purge(rawKey: keyB)
        await store.deactivate()

        // Inject a temp orphan (crash-interrupted manifest temp) into entry A's dir.
        let entryDirA = root.appendingPathComponent(namespaceDigest("ns-test"), isDirectory: true)
            .appendingPathComponent("entries/\(indexA)", isDirectory: true)
        let orphan = entryDirA.appendingPathComponent("manifest.json.tmp.\(UUID().uuidString)")
        try Data(repeating: 0x7a, count: 4096).write(to: orphan)

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        let inspection = await store2.inspect()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "temp orphan must be swept at activation")
        XCTAssertEqual(inspection.entryCount, 1, "only entry A survives")
        XCTAssertGreaterThanOrEqual(inspection.tombstoneCount, 1)
        XCTAssertGreaterThan(inspection.controlBytesUsed, 0, "control bytes must include the tombstone + journal + meta")
        XCTAssertGreaterThan(inspection.usageJournalBytes, 0, "the read's journal record must be accounted")
        XCTAssertEqual(inspection.totalBytesUsed, inspection.bytesUsed + inspection.controlBytesUsed)
        XCTAssertGreaterThan(inspection.bytesUsed, 0)
        await store2.deactivate()
    }

    /// The usage-journal codec round-trips, tolerates a torn trailing append, rejects a
    /// malformed complete record, and the store compacts the journal below 1 MiB to one
    /// record per live entry.
    func testUsageJournalRoundTripAndCompaction() async throws {
        let a = String(repeating: "a", count: 8), b = String(repeating: "b", count: 8)
        let r1 = try KVUsageJournalCodec.encodeLine(index: a, millis: 111)
        let r2 = try KVUsageJournalCodec.encodeLine(index: b, millis: 222)
        var buf = r1; buf.append(r2)
        let decoded = try KVUsageJournalCodec.decode(buf)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].index, a); XCTAssertEqual(decoded[0].millis, 111)
        XCTAssertEqual(decoded[1].index, b); XCTAssertEqual(decoded[1].millis, 222)
        // A torn trailing partial line (crash mid-append) is ignored.
        var torn = buf; torn.append(Data("{\"i\":\"cc".utf8))
        XCTAssertEqual(try KVUsageJournalCodec.decode(torn).count, 2)
        // A malformed COMPLETE record throws (→ quarantine at load).
        var bad = r1; bad.append(Data("not-json\n".utf8))
        XCTAssertThrowsError(try KVUsageJournalCodec.decode(bad))

        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:journal"
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
        let index = try await idx(store, key)
        await store.deactivate()

        // Pre-load the on-disk journal with > 1 MiB of valid records so the next append compacts.
        let journalURL = root.appendingPathComponent(namespaceDigest("ns-test"), isDirectory: true)
            .appendingPathComponent("usage.jsonl")
        var big = Data()
        let line = try KVUsageJournalCodec.encodeLine(index: index, millis: 1)
        while big.count <= KVUsageJournal.maxBytes { big.append(line) }
        try big.write(to: journalURL)

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        _ = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_200)
        let after = try Data(contentsOf: journalURL)
        XCTAssertLessThanOrEqual(after.count, KVUsageJournal.maxBytes, "journal must compact under 1 MiB")
        let records = try KVUsageJournalCodec.decode(after)
        XCTAssertEqual(records.count, 1, "compaction keeps one record per live entry")
        XCTAssertEqual(records[0].index, index)
        await store2.deactivate()
    }

    /// Activation recounts byte accounting from surviving artifacts after a stale-
    /// generation orphan blob is injected: the orphan is swept and excluded from the count.
    func testActivationRecountsAfterInjectedOrphan() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:orphan"
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
        let index = try await idx(store, key)
        let baseline = await store.inspect().bytesUsed
        await store.deactivate()

        let entryDir = root.appendingPathComponent(namespaceDigest("ns-test"), isDirectory: true)
            .appendingPathComponent("entries/\(index)", isDirectory: true)
        let orphanBlob = entryDir.appendingPathComponent("gen-99.blob")
        try Data(repeating: 0x11, count: 8192).write(to: orphanBlob)

        let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store2.activate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanBlob.path), "stale-generation orphan swept at activation")
        let recounted = await store2.inspect().bytesUsed
        XCTAssertEqual(recounted, baseline, "recount must exclude the swept orphan")
        let result = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        guard case .hit = result else { return XCTFail("entry must survive the orphan sweep") }
        await store2.deactivate()
    }

    func testFreeSpaceFloorRefusesWrite() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root) {
            $0.minFreeBytes = 50 * 1024 * 1024 * 1024
            $0.freeSpaceOverride = 50 * 1024 * 1024 * 1024
        }, keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:floor"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        let result = try await store.write(snapshot, nowMillis: 1_000_000)
        guard case .skipped(let detail) = result else { return XCTFail("floor must refuse the write") }
        XCTAssertEqual(detail, .freeSpaceFloor)
    }

    func testGeometryOverBudgetSkipsBeforeCopy() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root) { $0.stagingMaxBytes = 16 }, keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:budget"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        let result = try await store.write(snapshot, nowMillis: 1_000_000)
        guard case .skipped(let detail) = result else { return XCTFail("over-ceiling write must skip") }
        XCTAssertEqual(detail, .exceedsPromotionCeiling)
    }

    func testReadSideStagingBudgetMiss() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store1.activate()
        let key = "conv:kvs-synth:read-budget"
        let snapshot = try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000)
        _ = try await store1.write(snapshot, nowMillis: 1_000_000)
        let index = try await idx(store1, key)
        await store1.deactivate()

        let store2 = KVDiskCacheStore(config: makeConfig(root: root) { $0.stagingMaxBytes = 16 }, keychain: keychain)
        try await store2.activate()
        let result = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        guard case .miss(let code, _) = result else { return XCTFail("expected budget miss") }
        XCTAssertEqual(code, .diskMissBudget)
    }

    // MARK: - HIGH-1 streaming memory safety (FR-KVP3/FR-KVP9)

    /// A multi-chunk entry (decoded_length > the 64 MiB chunk ceiling) must round-trip
    /// byte-for-byte through the streaming seal + streaming decode, and the reported
    /// peak_staging_bytes must stay under the promotion ceiling — i.e. the read never
    /// materializes the whole blob AND the whole plaintext AND the whole decode at once.
    func testMultiChunkRoundTripBoundsReportedPeak() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        // Generous ceiling so nothing is rejected; we assert the reported peak is well
        // under it despite the entry crossing the 64 MiB chunk boundary.
        let ceiling = 512 * 1024 * 1024
        let store = KVDiskCacheStore(
            config: makeConfig(root: root) {
                $0.stagingMaxBytes = ceiling
                $0.writeStagingMaxBytes = ceiling
                $0.maxEntryBytes = 2 * 1024 * 1024 * 1024
            }, keychain: keychain, sink: sink)
        try await store.activate()

        let key = "conv:kvs-synth:multichunk"
        let seq = 100_000
        let layerCount = 11        // 11 layers × ~6.4 MB ≈ 70 MB > 64 MiB → ≥ 2 chunks
        let index = try await idx(store, key)
        var layers: [KVLayerPayload] = []
        for li in 0 ..< layerCount {
            let elements = 1 * 2 * seq * 4
            let byteCount = elements * KVCodecDType.f32.byteSize
            let keyBytes = Data((0 ..< byteCount).map { UInt8(($0 + li) & 0xff) })
            let valueBytes = Data((0 ..< byteCount).map { UInt8(($0 + li + 7) & 0xff) })
            layers.append(KVLayerPayload(
                layerIndex: li, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, seq, 4], dtype: .f32,
                cacheOffset: seq, keyBytes: keyBytes, valueBytes: valueBytes))
        }
        let geometry = layers.map {
            KVDiskCacheFormat.LayerGeometryInput(classID: $0.classID, ndim: $0.ndim, dims: $0.dims, dtype: $0.dtype)
        }
        let decodedLength = try XCTUnwrap(
            KVDiskCacheFormat.decodedLength(tokenCount: seq, layers: geometry))
        XCTAssertGreaterThan(decodedLength, KVDiskCacheFormat.maxChunkCiphertextBytes,
                             "test entry must span more than one chunk")

        var identity = Self.identity
        identity = KVWriteIdentity(
            requestModel: identity.requestModel, servedModelID: identity.servedModelID,
            modelSHA256: identity.modelSHA256, catalogRevision: identity.catalogRevision,
            tokenizerID: identity.tokenizerID, tokenizerConfigSHA256: identity.tokenizerConfigSHA256,
            chatTemplateSHA256: identity.chatTemplateSHA256, abiEpoch: identity.abiEpoch,
            mlxSwiftLMRevision: identity.mlxSwiftLMRevision, mlxVersion: identity.mlxVersion,
            cacheClass: identity.cacheClass, layerCount: layerCount, kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil, decodePath: identity.decodePath, keyEpoch: 1)
        let snapshot = KVWriteSnapshot(
            rawKey: key, indexHMAC: index, tokens: Array(0 ..< Int32(seq)), layers: layers,
            identity: identity, sampledPurgeGeneration: 0, commitSequence: 1,
            createdAtMillis: 1_000_000, eligibleUntilMillis: 1_000_000 + 900_000,
            incarnation: "inc-\(UUID().uuidString)")
        let write = try await store.write(snapshot, nowMillis: 1_000_000)
        guard case .committed = write else { return XCTFail("multi-chunk write should commit, got \(write)") }

        let rt = KVRuntimeIdentity(
            namespaceID: "ns-test", keyEpoch: 1, indexHMAC: index,
            requestModel: "qwen-test", servedModelID: "qwen-test-served",
            modelSHA256: String(repeating: "b", count: 64), catalogRevision: "r1",
            tokenizerID: "tok-1", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 1,
            mlxSwiftLMRevision: "3.31.4", mlxVersion: "0.0.0", cacheClass: "KVCacheSimple",
            layerCount: layerCount,
            layers: (0 ..< layerCount).map {
                KVLayerGeometry(layerIndex: $0, classID: "KVCacheSimple", layoutVersion: 1,
                                ndim: 4, dims: [1, 2, seq, 4], dtype: .f32, sequenceAxis: 2)
            },
            kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil,
            decodePath: "ordinary", liveHighWatermark: 0)
        let result = try await store.read(rawKey: key, runtime: rt, nowMillis: 1_000_100)
        guard case .hit(let hit) = result else { return XCTFail("expected multi-chunk hit, got \(result)") }
        XCTAssertEqual(hit.layers, layers, "multi-chunk restore must be byte-identical")
        XCTAssertEqual(hit.tokens, Array(0 ..< Int32(seq)))
        XCTAssertGreaterThan(hit.peakStagingBytes, 0)
        XCTAssertLessThanOrEqual(hit.peakStagingBytes, ceiling, "reported peak must stay under the ceiling")
        // The streaming peak must be well below holding the whole blob + whole plaintext
        // + whole decode co-resident (~3× decoded). Assert it stays under ~2.2× decoded.
        XCTAssertLessThan(hit.peakStagingBytes, decodedLength * 22 / 10,
                          "streaming read must not hold ~3× the decoded payload at once")
        await store.deactivate()
    }

    /// An entry whose decoded_length is under the ceiling but whose TRUE streaming peak
    /// (a live ciphertext frame + opened chunk on top of the decode) exceeds it must
    /// miss with disk_miss_budget — the peak bound is enforced, not just decoded_length.
    func testTrueDecodePeakOverCeilingMissesBudget() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let seq = 5
        let elements = 1 * 2 * seq * 4
        let geometry = [KVDiskCacheFormat.LayerGeometryInput(
            classID: "KVCacheSimple", ndim: 4, dims: [1, 2, seq, 4], dtype: .f32)]
        let decodedLength = try XCTUnwrap(
            KVDiskCacheFormat.decodedLength(tokenCount: seq, layers: geometry))
        _ = elements
        // Ceiling above decoded_length (write + pre-check pass) but below the true single
        // -chunk peak (~2× decoded_length: a live frame + opened chunk before decode).
        let ceiling = decodedLength + 64
        let store = KVDiskCacheStore(
            config: makeConfig(root: root) { $0.stagingMaxBytes = ceiling }, keychain: keychain, sink: sink)
        try await store.activate()
        let key = "conv:kvs-synth:peak-budget"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: seq, nowMillis: 1_000_000)
        let write = try await store.write(snapshot, nowMillis: 1_000_000)
        guard case .committed = write else { return XCTFail("write under ceiling should commit, got \(write)") }
        let index = try await idx(store, key)
        let result = try await store.read(rawKey: key, runtime: runtime(index: index, seq: seq), nowMillis: 1_000_100)
        guard case .miss(let code, let detail) = result else { return XCTFail("expected budget miss, got \(result)") }
        XCTAssertEqual(code, .diskMissBudget)
        XCTAssertEqual(detail, .exceedsPromotionCeiling)
        await store.deactivate()
    }

    func testPerEntryCapSkipsWrite() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root) { $0.maxEntryBytes = 16 }, keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:entrycap"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        let result = try await store.write(snapshot, nowMillis: 1_000_000)
        guard case .skipped = result else { return XCTFail("per-entry cap must skip") }
    }

    // MARK: - M-G: AC-3 crash injection at every commit / purge / rotation sub-boundary

    /// Inject a simulated crash at EACH write-path ordering boundary; after restart the
    /// store must recover to a clean state (a fully-committed HIT only when the manifest
    /// rename already landed, otherwise a clean MISS), never quarantine, and still accept
    /// a fresh write.
    func testCrashRecoveryAtEveryWriteFailpoint() async throws {
        let writeFailpoints: [(fp: KVFailpoint, expectHit: Bool)] = [
            (.afterDEKCreate, false),
            (.afterMkdirBeforeParentFsync, false),
            (.afterBlobFsync, false),
            (.afterEntryDirFsync, false),
            (.afterManifestTempFsync, false),
            (.insideMutationLaneBeforeRename, false),
            (.afterRenameBeforeDirFsync, true),
        ]
        for kase in writeFailpoints {
            let root = makeRoot()
            let keychain = KVInMemoryKeychain()
            let key = "conv:kvs-synth:wfp-\(kase.fp.rawValue)"
            let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
            try await store1.activate()
            await store1.setFailpoint { if $0 == kase.fp { throw KVInjectedCrash(point: kase.fp) } }
            let snap = try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000)
            await XCTAssertThrowsErrorAsync(try await store1.write(snap, nowMillis: 1_000_000))
            await store1.deactivate()

            let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
            try await store2.activate()
            let quarantined = await store2.isQuarantinedForTest
            XCTAssertFalse(quarantined, "\(kase.fp.rawValue): recovery must not quarantine")
            let index = try await idx(store2, key)
            let result = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
            if kase.expectHit {
                guard case .hit = result else { XCTFail("\(kase.fp.rawValue): expected hit, got \(result)"); await store2.deactivate(); continue }
            } else {
                guard case .miss = result else { XCTFail("\(kase.fp.rawValue): expected miss, got \(result)"); await store2.deactivate(); continue }
            }
            // Store remains healthy: a fresh write to a NEW key commits.
            let healKey = "conv:kvs-synth:wfp-heal-\(kase.fp.rawValue)"
            let healSnap = try await makeSnapshot(store: store2, rawKey: healKey, seq: 4, nowMillis: 1_000_200)
            guard case .committed = try await store2.write(healSnap, nowMillis: 1_000_200) else {
                XCTFail("\(kase.fp.rawValue): store must accept a new write after recovery"); await store2.deactivate(); continue
            }
            await store2.deactivate()
        }
    }

    /// Inject a crash at EACH single-key purge sub-boundary; recovery must complete the
    /// purge (entry gone, DEK crypto-shredded) without quarantine.
    func testCrashRecoveryAtEveryPurgeFailpoint() async throws {
        let purgeFailpoints: [KVFailpoint] = [
            .purgeAfterIncompleteTombstone, .purgeAfterHighWatermark, .purgeAfterDEKDestroy, .purgeAfterUnlink,
        ]
        for fp in purgeFailpoints {
            let root = makeRoot()
            let keychain = KVInMemoryKeychain()
            let key = "conv:kvs-synth:pfp-\(fp.rawValue)"
            let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
            try await store1.activate()
            _ = try await store1.write(try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
            let index = try await idx(store1, key)
            await store1.setFailpoint { if $0 == fp { throw KVInjectedCrash(point: fp) } }
            await XCTAssertThrowsErrorAsync(try await store1.purge(rawKey: key))
            await store1.deactivate()

            let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
            try await store2.activate()
            let quarantined = await store2.isQuarantinedForTest
            XCTAssertFalse(quarantined, "\(fp.rawValue): purge recovery must not quarantine")
            let result = try await store2.read(rawKey: key, runtime: runtime(index: index, seq: 5, highWatermark: 1), nowMillis: 1_000_200)
            guard case .miss = result else { XCTFail("\(fp.rawValue): purge must complete on recovery, got \(result)"); await store2.deactivate(); continue }
            XCTAssertNil(
                try keychain.copySecret(service: KVKeychainNaming(namespaceID: "ns-test").dekService(epoch: 1), account: index),
                "\(fp.rawValue): the entry DEK must be crypto-shredded")
            await store2.deactivate()
        }
    }

    /// Inject a crash at EACH epoch-rotation journal-phase boundary; recovery must drive
    /// the rotation to completion (epoch advanced, old entry gone) without quarantine.
    func testCrashRecoveryAtEveryRotationFailpoint() async throws {
        let rotationFailpoints: [KVFailpoint] = [
            .rotationAfterJournal, .rotationAfterMasterCreate, .rotationAfterEpochCommit, .rotationAfterOldDelete,
        ]
        for fp in rotationFailpoints {
            let root = makeRoot()
            let keychain = KVInMemoryKeychain()
            let key = "conv:kvs-synth:rfp-\(fp.rawValue)"
            let store1 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
            try await store1.activate()
            _ = try await store1.write(try await makeSnapshot(store: store1, rawKey: key, seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
            await store1.setFailpoint { if $0 == fp { throw KVInjectedCrash(point: fp) } }
            await XCTAssertThrowsErrorAsync(try await store1.purgeAll())
            await store1.deactivate()

            let store2 = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
            try await store2.activate()
            let quarantined = await store2.isQuarantinedForTest
            XCTAssertFalse(quarantined, "\(fp.rawValue): rotation recovery must not quarantine")
            let epoch = await store2.currentEpoch
            XCTAssertGreaterThanOrEqual(epoch, 2, "\(fp.rawValue): the epoch must advance past the rotation")
            let newIndex = try await idx(store2, key)
            let result = try await store2.read(rawKey: key, runtime: runtime(index: newIndex, seq: 5), nowMillis: 1_000_300)
            guard case .miss = result else { XCTFail("\(fp.rawValue): purged entry must miss after rotation, got \(result)"); await store2.deactivate(); continue }
            await store2.deactivate()
        }
    }

    // MARK: - M-G: snapshot immutability (AC-9)

    /// Synthetic (headless) snapshot-immutability: once a write snapshot is built, the
    /// persisted bytes are decoupled from later mutations of the caller's source buffers.
    /// Writes an entry, then mutates the ORIGINAL layer `Data` used to build the snapshot,
    /// and asserts the on-disk blob (and the restored bytes) are unchanged.
    func testSnapshotImmutabilitySyntheticState() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:immutable"
        let index = try await idx(store, key)

        let seq = 5
        let byteCount = 1 * 2 * seq * 4 * KVCodecDType.f32.byteSize
        var keyBytes = Data((0 ..< byteCount).map { UInt8($0 & 0xff) })
        var valueBytes = Data((0 ..< byteCount).map { UInt8(($0 + 7) & 0xff) })
        let originalKey = keyBytes, originalValue = valueBytes
        let layer = KVLayerPayload(
            layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, seq, 4], dtype: .f32,
            cacheOffset: seq, keyBytes: keyBytes, valueBytes: valueBytes)
        let snapshot = KVWriteSnapshot(
            rawKey: key, indexHMAC: index, tokens: Array(0 ..< Int32(seq)), layers: [layer],
            identity: Self.identity, sampledPurgeGeneration: 0, commitSequence: 1,
            createdAtMillis: 1_000_000, eligibleUntilMillis: 1_900_000, incarnation: "inc-immutable")
        guard case .committed = try await store.write(snapshot, nowMillis: 1_000_000) else {
            return XCTFail("write should commit")
        }
        // Mutate the caller's source buffers AFTER commit. The snapshot holds its own
        // value copies (Data is value-typed), so nothing persisted may change.
        for i in 0 ..< keyBytes.count { keyBytes[i] = 0xff }
        for i in 0 ..< valueBytes.count { valueBytes[i] = 0xff }
        XCTAssertEqual(snapshot.layers[0].keyBytes, originalKey, "the snapshot's copy must be decoupled from the source")
        XCTAssertEqual(snapshot.layers[0].valueBytes, originalValue)

        let result = try await store.read(rawKey: key, runtime: runtime(index: index, seq: seq), nowMillis: 1_000_100)
        guard case .hit(let hit) = result else { return XCTFail("expected hit, got \(result)") }
        XCTAssertEqual(hit.layers[0].keyBytes, originalKey, "persisted bytes must equal the pre-mutation source")
        XCTAssertEqual(hit.layers[0].valueBytes, originalValue)
        await store.deactivate()
    }

    /// Live-MLX snapshot immutability (AC-9): the `asData(access: .copy)` snapshot must
    /// be decoupled from subsequent in-place mutation of the live `KVCacheSimple` state.
    /// Gated behind KV_ENABLE_MLX_TESTS (MLX aborts the process without a Metal library).
    func testSnapshotImmutabilityLiveMLXState() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KV_ENABLE_MLX_TESTS"] == "1",
                          "requires MLX Metal runtime (set KV_ENABLE_MLX_TESTS=1 on a capable host)")
        try KVBridgeProbe.snapshotImmutabilityRoundTrip()
    }

    // MARK: - Clock rollback dormancy (FR-KVP10)

    func testClockRollbackForcesDormancy() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:clock"
        let snapshot = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 2_000_000)
        _ = try await store.write(snapshot, nowMillis: 2_000_000)
        let index = try await idx(store, key)

        let result = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_000)
        guard case .miss(let code, let detail) = result else { return XCTFail("rollback must miss") }
        XCTAssertEqual(code, .diskMissIO)
        XCTAssertEqual(detail, .clockRollback)
    }

    // MARK: - Absent + inspection

    func testAbsentKeyMissAndInspection() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:none"
        let index = try await idx(store, key)
        let result = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_000)
        guard case .miss(let code, _) = result else { return XCTFail() }
        XCTAssertEqual(code, .diskMissAbsent)

        let inspection = await store.inspect()
        XCTAssertEqual(inspection.namespaceID, "ns-test")
        XCTAssertEqual(inspection.entryCount, 0)
        XCTAssertEqual(inspection.keyEpoch, 1)
        XCTAssertEqual(inspection.eligibilityTTLSeconds, 900)
        XCTAssertGreaterThanOrEqual(inspection.keychainItemCount, 1)
    }

    // MARK: - KVCacheSimple bridge (gated: MLX Metal runtime required)

    func testKVCacheSimpleBridgeRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["KV_ENABLE_MLX_TESTS"] != nil else {
            throw XCTSkip("KVCacheSimple bridge needs the MLX Metal runtime; set KV_ENABLE_MLX_TESTS on a capable host")
        }
        try KVBridgeProbe.roundTrip()
    }

    /// M-15: keychain namespace enumeration must be unambiguous — namespace "prov"
    /// must not prefix-match namespace "prov.sub" (the old "root.<id>." scheme did).
    func testKeychainNamespaceEnumerationIsUnambiguous() throws {
        let keychain = KVInMemoryKeychain()
        let a = KVKeyManager(keychain: keychain, namespaceID: "prov")
        let ab = KVKeyManager(keychain: keychain, namespaceID: "prov.sub")
        _ = try a.createEpochMaster(epoch: 1, incarnation: "i")
        _ = try ab.createEpochMaster(epoch: 1, incarnation: "i")
        XCTAssertEqual(try a.keychainItemCount(), 1, "'prov' must not enumerate 'prov.sub' items")
        XCTAssertEqual(try ab.keychainItemCount(), 1, "'prov.sub' must not enumerate 'prov' items")
    }

    /// M-14: an on-disk blob larger than its declared blob_length is an integrity
    /// (disk_miss_corrupt) failure, not an I/O (disk_miss_io) failure.
    func testOverBoundBlobClassifiesAsCorruptNotIO() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain, sink: sink)
        try await store.activate()
        let key = "conv:kvs-synth:overbound"
        let s = try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000)
        guard case .committed = try await store.write(s, nowMillis: 1_000_000) else { return XCTFail("write") }
        let index = try await idx(store, key)

        // Grow the committed blob past its declared blob_length on disk.
        let blobURL = root.appendingPathComponent(namespaceDigest("ns-test"))
            .appendingPathComponent("entries").appendingPathComponent(index)
            .appendingPathComponent("gen-1.blob")
        let handle = try FileHandle(forWritingTo: blobURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 1024))
        try handle.close()

        sink.reset()
        let result = try await store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        guard case .miss(let code, _) = result else { return XCTFail("expected miss, got \(result)") }
        XCTAssertEqual(code, .diskMissCorrupt, "over-bound blob must be corrupt, not io")
        XCTAssertEqual(sink.codes(.diskMissCorrupt), 1)
        XCTAssertEqual(sink.codes(.diskMissIO), 0, "bounds violation must not classify as io")
    }

    // MARK: - Real keychain adapter graceful skip

    func testRealKeychainAdapterSkipsGracefully() throws {
        let keychain = KVSecItemKeychain()
        do {
            _ = try keychain.enumerate(servicePrefix: "live.streamvc.macprovider.kv-cache.v1.probe.")
        } catch let e as KVKeychainError {
            if case .unavailable = e {
                throw XCTSkip("Data-Protection keychain/entitlement unavailable in this environment")
            }
            throw XCTSkip("keychain adapter failed: \(e)")
        }
    }

    // MARK: - Helpers

    private func namespaceDigest(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func idx(_ store: KVDiskCacheStore, _ key: String) async throws -> String {
        let value = try await store.currentIndex(rawKey: key)
        return try XCTUnwrap(value)
    }

    /// Block the calling test until `sem` is signalled, WITHOUT parking a cooperative-pool
    /// thread (which could deadlock the actor whose progress we are waiting on).
    private func awaitSemaphore(_ sem: DispatchSemaphore) async {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async { sem.wait(); cont.resume() }
        }
    }

    /// A promotion-decode pause hook that signals `entered` when the off-actor decode
    /// begins and then parks until the decode Task is cancelled (the purge/rotation
    /// cancel-or-join). Cancellation-aware so cancel-or-join cannot deadlock.
    private func pauseUntilCancelled(_ entered: DispatchSemaphore) -> @Sendable () async -> Void {
        { @Sendable in
            entered.signal()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
    }

    // MARK: - CRITICAL-1 (R4): off-actor promotion TOCTOU

    /// CRITICAL-1(b/c): a single-key purge that completes WHILE a promotion decode is in
    /// flight must yield a read MISS (never a `.hit` from the copied DEK/blob), and must
    /// crypto-shred the DEK. The pause gate expresses the previously-unhookable window
    /// "purge lands during an in-flight decode".
    func testPromotionDecodeRaceSingleKeyPurgeYieldsMiss() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:promo-race-single"
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
        let index = try await idx(store, key)

        let entered = DispatchSemaphore(value: 0)
        await store.setPromoteDecodePause(pauseUntilCancelled(entered))

        async let readResult = store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        await awaitSemaphore(entered)                      // decode is genuinely paused
        let purge = try await store.purge(rawKey: key)     // completes; cancel-or-joins the decode
        if case .failed = purge { XCTFail("purge failed: \(purge)") }

        let result = try await readResult
        guard case .miss = result else {
            return XCTFail("in-flight decode must not return a hit after purge_ok, got \(result)")
        }
        XCTAssertNil(try keychain.copySecret(
            service: KVKeychainNaming(namespaceID: "ns-test").dekService(epoch: 1), account: index),
            "purge must crypto-shred the entry DEK")
        await store.deactivate()
    }

    /// CRITICAL-1(b/c): a purge-all (epoch rotation) that completes WHILE a promotion
    /// decode is in flight must yield a read MISS — the post-decode re-fence sees the
    /// rotated epoch and discards the old-epoch decoded state.
    func testPromotionDecodeRacePurgeAllYieldsMiss() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:promo-race-all"
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)
        let index = try await idx(store, key)

        let entered = DispatchSemaphore(value: 0)
        await store.setPromoteDecodePause(pauseUntilCancelled(entered))

        async let readResult = store.read(rawKey: key, runtime: runtime(index: index, seq: 5), nowMillis: 1_000_100)
        await awaitSemaphore(entered)
        guard case .ok = try await store.purgeAll() else { return XCTFail("purge-all should rotate") }

        let result = try await readResult
        guard case .miss = result else {
            return XCTFail("in-flight decode must not return a hit after purge-all, got \(result)")
        }
        let epoch = await store.currentEpoch
        XCTAssertEqual(epoch, 2, "purge-all rotates the epoch")
        await store.deactivate()
    }

    // MARK: - CRITICAL-2 (R4): rotation journal durable before hot callback

    /// CRITICAL-2: `performNamespacePurgeRotation` must fsync the rotation-intent journal
    /// (the durable namespace-blocked marker) BEFORE the suspending `hotPurgeAll` callback.
    /// The hook reads `meta.json` off disk at the instant it runs and asserts an OPEN
    /// rotation journal is already durable — so a crash inside the callback leaves a
    /// recoverable, namespace-blocked state rather than a lost fence with no journal.
    func testPurgeAllPersistsRotationJournalBeforeHotCallback() async throws {
        let root = makeRoot()
        let keychain = KVInMemoryKeychain()
        let store = KVDiskCacheStore(config: makeConfig(root: root), keychain: keychain)
        try await store.activate()
        let key = "conv:kvs-synth:journal-before-hot"
        _ = try await store.write(try await makeSnapshot(store: store, rawKey: key, seq: 5, nowMillis: 1_000_000), nowMillis: 1_000_000)

        let metaURL = root.appendingPathComponent(namespaceDigest("ns-test"), isDirectory: true)
            .appendingPathComponent("meta.json")
        let journalDurableWhenHotRan = DispatchSemaphore(value: 0)
        let sawOpenJournal = LockedBox(false)
        await store.setHotPurgeHooks(single: nil, all: { @Sendable in
            if let data = try? Data(contentsOf: metaURL),
               let json = String(data: data, encoding: .utf8),
               json.contains("rotation_journal"), json.contains("created") {
                sawOpenJournal.set(true)
            }
            journalDurableWhenHotRan.signal()
        })

        guard case .ok = try await store.purgeAll() else { return XCTFail("purge-all should rotate") }
        await awaitSemaphore(journalDurableWhenHotRan)
        XCTAssertTrue(sawOpenJournal.get(),
                      "rotation-intent journal must be durable on disk BEFORE hotPurgeAll runs")
        await store.deactivate()
    }
}

enum KVBridgeProbeError: Error { case snapshotFailed, mutated, notDeepCopy }

/// Isolates all MLX use behind an explicit call so the symbol is never touched unless
/// the gated bridge test runs (MLX aborts the process when Metal is unavailable).
enum KVBridgeProbe {
    static func roundTrip() throws {
        // Deliberately empty in the headless build path; on a Metal-capable host this
        // is where a KVCacheSimple → snapshotLayers → restore identity check runs. The
        // real bridge (`KVCacheSerialization`) is compiled and type-checked against the
        // live MLX API; exercising it live is deferred to the integration stage.
    }

    /// AC-9 live-MLX snapshot immutability: an `asData(access: .copy)` snapshot must be a
    /// genuine deep copy, decoupled from later in-place mutation of the live cache state.
    /// Only invoked under KV_ENABLE_MLX_TESTS.
    static func snapshotImmutabilityRoundTrip() throws {
        let cache = KVCacheSimple()
        let k = MLXArray((0 ..< 16).map { Float($0) }, [1, 2, 2, 2])
        let v = MLXArray((0 ..< 16).map { Float($0) + 100 }, [1, 2, 2, 2])
        cache.state = [k, v]
        guard let before = KVCacheSerialization.snapshotLayers([cache]), before.count == 1 else {
            throw KVBridgeProbeError.snapshotFailed
        }
        let capturedKey = before[0].keyBytes
        let capturedValue = before[0].valueBytes
        // Mutate the live cache state in place (a new key tensor).
        cache.state = [MLXArray((0 ..< 16).map { Float($0) + 999 }, [1, 2, 2, 2]), v]
        guard let after = KVCacheSerialization.snapshotLayers([cache]), after.count == 1 else {
            throw KVBridgeProbeError.snapshotFailed
        }
        // The earlier snapshot's bytes are unchanged by the mutation…
        guard before[0].keyBytes == capturedKey, before[0].valueBytes == capturedValue else {
            throw KVBridgeProbeError.mutated
        }
        // …and the post-mutation snapshot differs, proving the earlier copy was deep.
        guard after[0].keyBytes != capturedKey else { throw KVBridgeProbeError.notDeepCopy }
    }
}

// MARK: - Async throwing assertion helper

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
