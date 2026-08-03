import Foundation
import MacProviderCore
import MLX
import MLXLMCommon
import MLXNN
@testable import macprovider_cli
import XCTest

/// SPEC-037 stage 5 — the hot<->cold orchestration inside `ConversationCache`:
/// lazy promotion feeding the UNCHANGED predicate (AC-1 accounting identity),
/// the availability difference vs a tier-disabled cache (AC-7), FR-KVP8 hot-lease
/// purge fencing (AC-4 additions), and synchronous snapshot-at-commit gated by the
/// synthetic-key context (AC-9). All run headless against a fake cold tier and the
/// existing offset-only `KVCacheSimple`/`ArraysCache` layer doubles — no MLX Metal
/// runtime and no Keychain entitlement. The live MLX bridge + real store are
/// exercised by `KVDiskCacheStoreTests.testKVCacheSimpleBridgeRoundTrip`
/// (KV_ENABLE_MLX_TESTS) and the KVS-01a harness.
final class KVConversationColdTierTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeColdTier: ConversationColdTier, @unchecked Sendable {
        var sampledGen = 0
        var promoteResult: ColdPromotionCandidate?
        var captureReturnsNil = false
        private let lock = NSLock()
        private(set) var captured: [ConversationColdSnapshot] = []
        private(set) var finished: [(accepted: Bool, reason: String?)] = []
        private(set) var promoteCalls = 0

        func sampledPurgeGeneration(conversationKey: String) async -> Int { sampledGen }

        func promoteCandidate(conversationKey: String, identity: KVIdentityCore) async -> ColdPromotionCandidate? {
            lock.lock(); promoteCalls += 1; lock.unlock()
            return promoteResult
        }

        func finishPromotion(_ candidate: ColdPromotionCandidate, accepted: Bool, rejectionReason: String?) async {
            lock.lock(); finished.append((accepted, rejectionReason)); lock.unlock()
        }

        func captureSnapshot(conversationKey: String, layers: ConversationCacheLayers,
                             fullTokens: [Int32], sampledPurgeGeneration: Int,
                             identity: KVIdentityCore, nowMillis: Int) -> ConversationColdSnapshot? {
            if captureReturnsNil { return nil }
            let snap = ConversationColdSnapshot(
                rawKey: conversationKey, tokens: fullTokens, layers: [], identity: Self.writeIdentity,
                sampledPurgeGeneration: sampledPurgeGeneration, commitSequence: 1,
                createdAtMillis: nowMillis, eligibleUntilMillis: nowMillis, incarnation: "test")
            lock.lock(); captured.append(snap); lock.unlock()
            return snap
        }

        func enqueuePersist(_ snapshot: ConversationColdSnapshot) {
            lock.lock(); enqueued.append(snapshot); lock.unlock()
        }
        func cancelPendingPersist(conversationKey: String) async -> Bool {
            lock.lock(); defer { lock.unlock() }
            perKeyCancels.append(conversationKey)
            return pendingKeys.remove(conversationKey) != nil
        }
        func cancelPendingPersists() async { lock.lock(); cancelledPersists += 1; lock.unlock() }
        func drainPendingPersists(timeoutSeconds: Int) async {}
        func noteReadIdentityUnavailable(conversationKey: String) async {
            lock.lock(); readIdentityUnavailableKeys.append(conversationKey); lock.unlock()
        }
        func noteWriteSkippedIdentityUnavailable(conversationKey: String) async {
            lock.lock(); writeIdentityUnavailableKeys.append(conversationKey); lock.unlock()
        }
        private(set) var readIdentityUnavailableKeys: [String] = []
        private(set) var writeIdentityUnavailableKeys: [String] = []
        var readIdentityUnavailable: [String] { lock.lock(); defer { lock.unlock() }; return readIdentityUnavailableKeys }
        var writeIdentityUnavailable: [String] { lock.lock(); defer { lock.unlock() }; return writeIdentityUnavailableKeys }

        private(set) var enqueued: [ConversationColdSnapshot] = []
        private(set) var cancelledPersists = 0
        /// Keys the test asserts had a pending persist (drives `cancelPendingPersist`).
        var pendingKeys: Set<String> = []
        private(set) var perKeyCancels: [String] = []
        var perKeyCancelKeys: [String] { lock.lock(); defer { lock.unlock() }; return perKeyCancels }

        var capturedSnapshots: [ConversationColdSnapshot] { lock.lock(); defer { lock.unlock() }; return captured }
        var enqueuedSnapshots: [ConversationColdSnapshot] { lock.lock(); defer { lock.unlock() }; return enqueued }
        var cancelPersistCount: Int { lock.lock(); defer { lock.unlock() }; return cancelledPersists }
        var finishedOutcomes: [(accepted: Bool, reason: String?)] { lock.lock(); defer { lock.unlock() }; return finished }
        var promotionCallCount: Int { lock.lock(); defer { lock.unlock() }; return promoteCalls }

        static let writeIdentity = KVWriteIdentity(
            requestModel: "m", servedModelID: "m", modelSHA256: String(repeating: "b", count: 64),
            catalogRevision: "r", tokenizerID: "m", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 1, mlxSwiftLMRevision: "x",
            mlxVersion: "y", cacheClass: "KVCacheSimple", layerCount: 1, kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil, decodePath: "ordinary", keyEpoch: 1)
    }

    private func identity() -> KVIdentityCore {
        KVIdentityCore(
            requestModel: "model-a", servedModelID: "model-a", modelSHA256: String(repeating: "b", count: 64),
            catalogRevision: "r", tokenizerID: "model-a", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil)
    }

    private func context(eligible: Bool) -> ConversationColdContext {
        ConversationColdContext(eligible: eligible, identity: identity())
    }

    private func int32Range(_ range: Range<Int>) -> [Int32] { range.map(Int32.init) }

    private func trimmableCache(offset: Int) -> KVCacheSimple {
        let cache = KVCacheSimple()
        cache.offset = offset
        return cache
    }

    private func candidate(canonicalTokens: [Int32], offset: Int) -> ColdPromotionCandidate {
        ColdPromotionCandidate(
            layers: ConversationCacheLayers([trimmableCache(offset: offset)]),
            canonicalTokens: canonicalTokens, keyHashPrefix: "abcd1234",
            bytesRead: 42, decryptMillis: 1, peakStagingBytes: 42)
    }

    private static let config = ConversationCache.Config(maxConversations: 8, maxTokens: 200_000, ttlSeconds: 900)

    // MARK: - AC-1: promotion feeds the unchanged predicate; accounting is identical

    func testPromotedHitAccountingMatchesHotHit() async {
        let fake = FakeColdTier()
        fake.promoteResult = candidate(canonicalTokens: int32Range(0..<64), offset: 64)
        let cache = ConversationCache(config: Self.config, coldTier: fake)

        let incoming = int32Range(0..<57) + int32Range(100..<112)   // LCP 57 vs the 64-token cold entry
        let hit = await cache.begin(
            conversationKey: "conv:kvs-synth:promote", incomingTokens: incoming,
            modelID: "model-a", kvBits: nil, cold: context(eligible: true))

        XCTAssertEqual(hit?.cachedPromptTokens, 57, "promoted hit reports the exact LCP, identical to a hot hit")
        XCTAssertEqual(hit?.trimBy, 7)
        XCTAssertEqual(hit?.lcp, 57)
        XCTAssertLessThanOrEqual(hit?.cachedPromptTokens ?? 0, incoming.count, "cached ≤ full prompt length")
        XCTAssertTrue(hit?.promotedFromCold ?? false)
        XCTAssertEqual(fake.finishedOutcomes.count, 1)
        XCTAssertTrue(fake.finishedOutcomes.first?.accepted ?? false, "accepted promotion emits disk_hit")
        await cache.abort(hit!)
    }

    // MARK: - AC-7: availability difference — enabled promotes, disabled misses

    func testAvailabilityDifferenceEnabledVsDisabled() async {
        let incoming = int32Range(0..<57) + int32Range(100..<112)

        // Tier disabled ⇒ cold-start miss, cached=0 (byte-identical to today).
        let plain = ConversationCache(config: Self.config)
        let plainLease = await plain.begin(
            conversationKey: "conv:kvs-synth:x", incomingTokens: incoming, modelID: "model-a", kvBits: nil)
        XCTAssertEqual(plainLease?.cachedPromptTokens, 0)
        await plain.abort(plainLease!)

        // Tier enabled + eligible ⇒ the only difference is hit availability.
        let fake = FakeColdTier()
        fake.promoteResult = candidate(canonicalTokens: int32Range(0..<64), offset: 64)
        let enabled = ConversationCache(config: Self.config, coldTier: fake)
        let hit = await enabled.begin(
            conversationKey: "conv:kvs-synth:x", incomingTokens: incoming, modelID: "model-a",
            kvBits: nil, cold: context(eligible: true))
        XCTAssertEqual(hit?.cachedPromptTokens, 57)
        XCTAssertEqual(hit?.key, plainLease?.key, "same key envelope, differing only in availability")
        await enabled.abort(hit!)
    }

    // MARK: - AC-9 / non-gated invariant: non-eligible key never promotes or persists

    func testNonEligibleKeyNeitherPromotesNorPersists() async {
        let fake = FakeColdTier()
        fake.promoteResult = candidate(canonicalTokens: int32Range(0..<64), offset: 64)
        let cache = ConversationCache(config: Self.config, coldTier: fake)

        let tokens = int32Range(0..<64)
        let lease = await cache.begin(
            conversationKey: "conv:not-synth", incomingTokens: tokens, modelID: "model-a",
            kvBits: nil, cold: context(eligible: false))
        XCTAssertEqual(lease?.cachedPromptTokens, 0, "no promotion for a non-gated key")
        XCTAssertEqual(fake.promotionCallCount, 0)
        await cache.commit(lease!, cache: ConversationCacheLayers([trimmableCache(offset: 64)]),
                           fullTokens: tokens, cold: context(eligible: false))
        XCTAssertTrue(fake.capturedSnapshots.isEmpty, "no snapshot captured for a non-gated key")
    }

    // MARK: - HIGH-4: identity-unavailable telemetry (FR-KVP12)

    /// The pure gate + identity-availability resolver maps a gated key missing ANY live
    /// identity input to `identity_unavailable`, a fully-available gated key to eligible,
    /// and a non-gated key to inert (no reason, not eligible).
    func testColdContextResolutionMapsEachMissingIdentityInput() {
        let m = "model-a", s = "served-a"
        let h = String(repeating: "b", count: 64), c = String(repeating: "c", count: 64), t = String(repeating: "d", count: 64)
        let cat = "catalog-rev-1"

        let full = ConversationColdContext.resolve(
            gated: true, requestModel: m, servedModelID: s, modelSHA256: h,
            catalogRevision: cat, tokenizerConfigSHA256: c, chatTemplateSHA256: t)
        XCTAssertTrue(full.eligible); XCTAssertNil(full.identityUnavailableReason)

        // Each of the four live-identity inputs, individually nil on a gated key.
        let cases: [(name: String, model: String?, cat: String?, tok: String?, tmpl: String?)] = [
            ("model_hash", nil, cat, c, t),
            ("catalog_revision", h, nil, c, t),
            ("tokenizer_hash", h, cat, nil, t),
            ("template_hash", h, cat, c, nil),
        ]
        for kase in cases {
            let ctx = ConversationColdContext.resolve(
                gated: true, requestModel: m, servedModelID: s, modelSHA256: kase.model,
                catalogRevision: kase.cat, tokenizerConfigSHA256: kase.tok, chatTemplateSHA256: kase.tmpl)
            XCTAssertFalse(ctx.eligible, "\(kase.name) must not be eligible")
            XCTAssertEqual(ctx.identityUnavailableReason, .identityUnavailable, "\(kase.name)")
        }

        let nonGated = ConversationColdContext.resolve(
            gated: false, requestModel: m, servedModelID: s, modelSHA256: h,
            catalogRevision: cat, tokenizerConfigSHA256: c, chatTemplateSHA256: t)
        XCTAssertFalse(nonGated.eligible)
        XCTAssertNil(nonGated.identityUnavailableReason, "non-gated is inert, not identity_unavailable")
    }

    /// End-to-end through a real store + adapter + cache: a gated request with
    /// unavailable identity emits `disk_miss_identity_unavailable` on the read (begin)
    /// and `disk_write_skipped(identity_unavailable)` on the commit, and nothing is
    /// promoted or persisted.
    func testGatedIdentityUnavailableEmitsCodesAndDoesNotPersist() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvidu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = KVInMemoryKeychain()
        let sink = KVRecordingEventSink()
        var config = KVDiskCacheStoreConfig(
            root: root, namespaceID: "ns-test",
            maxBytes: 1 << 30, maxEntries: 16, maxEntryBytes: 1 << 28,
            retentionSeconds: 3600, stagingMaxBytes: 1 << 28, writeStagingMaxBytes: 1 << 28,
            minFreeBytes: 1 << 20, promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        config.freeSpaceOverride = 1 << 34
        let store = KVDiskCacheStore(config: config, keychain: keychain, sink: sink)
        try await store.activate()
        let adapter = KVConversationColdTierAdapter(
            store: store, namespaceID: "ns-test", eligibilityTTLSeconds: 900)
        let cache = ConversationCache(config: Self.config)
        await cache.attachColdTier(adapter)

        // Gated key, but the context carries identityUnavailableReason (a live-identity
        // input was missing at coldContext resolution).
        let placeholder = KVIdentityCore.build(
            requestModel: "m", servedModelID: "m", modelSHA256: nil, catalogRevision: "",
            tokenizerConfigSHA256: "", chatTemplateSHA256: "")
        let ctx = ConversationColdContext(
            eligible: false, identity: placeholder, identityUnavailableReason: .identityUnavailable)

        let key = "conv:kvs-synth:id-unavailable"
        let tokens = int32Range(0..<20)
        let lease = await cache.begin(
            conversationKey: key, incomingTokens: tokens, modelID: "m", kvBits: nil, cold: ctx)
        XCTAssertNil(lease?.reusableCache, "identity-unavailable read is a miss (no promotion)")
        await cache.commit(lease!, cache: ConversationCacheLayers([trimmableCache(offset: tokens.count)]),
                           fullTokens: tokens, cold: ctx)

        XCTAssertGreaterThanOrEqual(sink.codes(.diskMissIdentityUnavailable), 1,
                                    "read attempt must emit disk_miss_identity_unavailable")
        XCTAssertGreaterThanOrEqual(sink.codes(.diskWriteSkipped), 1,
                                    "commit must emit disk_write_skipped")
        XCTAssertTrue(sink.events.contains { $0.code == .diskMissIdentityUnavailable && $0.detail == .identityUnavailable })
        XCTAssertTrue(sink.events.contains { $0.code == .diskWriteSkipped && $0.detail == .identityUnavailable })

        let entryCount = await store.inspect().entryCount
        XCTAssertEqual(entryCount, 0, "nothing may be persisted for an identity-unavailable request")
        await store.deactivate()
    }

    // MARK: - AC-9: snapshot captured synchronously at commit for a gated key

    func testGatedCommitCapturesSnapshotWithCommittedTokens() async {
        let fake = FakeColdTier()
        let cache = ConversationCache(config: Self.config, coldTier: fake)
        let tokens = int32Range(0..<40)
        let lease = await cache.begin(
            conversationKey: "conv:kvs-synth:snap", incomingTokens: tokens, modelID: "model-a",
            kvBits: nil, cold: context(eligible: true))
        let fullTokens = tokens + int32Range(200..<205)
        await cache.commit(lease!, cache: ConversationCacheLayers([trimmableCache(offset: fullTokens.count)]),
                           fullTokens: fullTokens, cold: context(eligible: true))
        XCTAssertEqual(fake.capturedSnapshots.count, 1, "exactly one synchronous snapshot at commit")
        XCTAssertEqual(fake.capturedSnapshots.first?.tokens, fullTokens,
                       "snapshot records the committed canonical token sequence")
    }

    /// M-B: creation/eligibility derive from the EXACT hot-commit instant passed into
    /// captureSnapshot, not a wall-clock read taken after the deep copy.
    func testCaptureUsesExactCommitInstant() async {
        let fake = FakeColdTier()
        let cache = ConversationCache(config: Self.config, coldTier: fake)
        let tokens = int32Range(0..<40)
        let lease = await cache.begin(
            conversationKey: "conv:kvs-synth:instant", incomingTokens: tokens, modelID: "model-a",
            kvBits: nil, cold: context(eligible: true))
        let commitNow = Date(timeIntervalSince1970: 12345.5)   // *1000 is exact in Double
        await cache.commit(lease!, cache: ConversationCacheLayers([trimmableCache(offset: tokens.count)]),
                           fullTokens: tokens, now: commitNow, cold: context(eligible: true))
        XCTAssertEqual(fake.capturedSnapshots.first?.createdAtMillis, 12_345_500,
                       "captureSnapshot must receive the exact hot-commit instant in ms")
    }

    // MARK: - AC-4: a pre-purge hot lease finishing after purge reinserts nothing

    func testSingleKeyPurgeFencesInFlightCommit() async {
        let fake = FakeColdTier()
        let cache = ConversationCache(config: Self.config, coldTier: fake)
        let key = "conv:kvs-synth:fence"
        let tokens = int32Range(0..<64)

        let lease = await cache.begin(
            conversationKey: key, incomingTokens: tokens, modelID: "model-a", kvBits: nil,
            cold: context(eligible: true))
        // A purge lands during the request, after the lease sampled its stamp.
        await cache.purgeHot(conversationKey: key)
        await cache.commit(lease!, cache: ConversationCacheLayers([trimmableCache(offset: 64)]),
                           fullTokens: tokens, cold: context(eligible: true))

        // Nothing was reinserted into RAM: a fresh begin is a cold start.
        fake.promoteResult = nil
        let after = await cache.begin(
            conversationKey: key, incomingTokens: tokens + [99], modelID: "model-a", kvBits: nil,
            cold: context(eligible: true))
        XCTAssertEqual(after?.cachedPromptTokens, 0, "fenced commit must not repopulate the hot tier")
        XCTAssertTrue(fake.capturedSnapshots.isEmpty, "a fenced commit persists nothing to disk either")
        await cache.abort(after!)
    }

    /// FR-KVP8 (a)/(b): a single-key purge cancels the key's queued cold-tier persist
    /// (so a snapshot queued before its first disk write never publishes) and reports
    /// that the hot tier held live state even when there is no resident RAM entry.
    func testSingleKeyPurgeCancelsPendingPersistAndReportsState() async {
        let fake = FakeColdTier()
        let cache = ConversationCache(config: Self.config, coldTier: fake)
        let key = "conv:kvs-synth:pending"

        // Model a queued-but-unpublished persist for the key.
        fake.pendingKeys = [key]
        let hadState = await cache.purgeHot(conversationKey: key)
        XCTAssertTrue(hadState, "purge of a key with a pending persist must report hot/pending state")
        XCTAssertEqual(fake.perKeyCancelKeys, [key], "the key's pending persist must be cancelled")

        // A key with neither hot nor pending state reports no state.
        let empty = await cache.purgeHot(conversationKey: "conv:kvs-synth:absent")
        XCTAssertFalse(empty, "purge of an absent key reports no hot/pending state")
    }

    func testPurgeAllFencesInFlightCommit() async {
        let fake = FakeColdTier()
        let cache = ConversationCache(config: Self.config, coldTier: fake)
        let key = "conv:kvs-synth:fenceall"
        let tokens = int32Range(0..<64)

        let lease = await cache.begin(
            conversationKey: key, incomingTokens: tokens, modelID: "model-a", kvBits: nil,
            cold: context(eligible: true))
        await cache.purgeAllHot()
        await cache.commit(lease!, cache: ConversationCacheLayers([trimmableCache(offset: 64)]),
                           fullTokens: tokens, cold: context(eligible: true))

        fake.promoteResult = nil
        let after = await cache.begin(
            conversationKey: key, incomingTokens: tokens + [99], modelID: "model-a", kvBits: nil,
            cold: context(eligible: true))
        XCTAssertEqual(after?.cachedPromptTokens, 0, "purge-all invalidates every outstanding lease's commit")
        await cache.abort(after!)
    }

    // MARK: - §5 row 25: a promoted candidate failing the predicate is disk_promote_rejected

    func testPromotedCandidateFailingPredicateIsRejected() async {
        let fake = FakeColdTier()
        // Cold entry too short: LCP < the 32 threshold ⇒ predicate rejects it.
        fake.promoteResult = candidate(canonicalTokens: int32Range(0..<10), offset: 10)
        let cache = ConversationCache(config: Self.config, coldTier: fake)
        let incoming = int32Range(0..<10) + int32Range(50..<60)
        let lease = await cache.begin(
            conversationKey: "conv:kvs-synth:reject", incomingTokens: incoming, modelID: "model-a",
            kvBits: nil, cold: context(eligible: true))
        XCTAssertEqual(lease?.cachedPromptTokens, 0, "rejected promotion serves a fresh miss")
        XCTAssertEqual(fake.finishedOutcomes.count, 1)
        XCTAssertFalse(fake.finishedOutcomes.first?.accepted ?? true)
        XCTAssertEqual(fake.finishedOutcomes.first?.reason, "prefix_diverged")
        await cache.abort(lease!)
    }

    // MARK: - Item 3: aggregate write-live budget (FR-KVP3 RAM-DoS bound)

    private func makeAdapter(writeStagingMaxBytes: Int) -> (KVConversationColdTierAdapter, KVDiskCacheStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvadapter-\(UUID().uuidString)", isDirectory: true)
        let config = KVDiskCacheStoreConfig(
            root: root, namespaceID: "ns-adapter",
            maxBytes: 16 * 1024 * 1024, maxEntries: 64, maxEntryBytes: 8 * 1024 * 1024,
            retentionSeconds: 3600, stagingMaxBytes: 256 * 1024 * 1024,
            writeStagingMaxBytes: writeStagingMaxBytes, minFreeBytes: 1024 * 1024,
            promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        let store = KVDiskCacheStore(config: config, keychain: KVInMemoryKeychain(), sink: KVRecordingEventSink())
        let adapter = KVConversationColdTierAdapter(
            store: store, namespaceID: "ns-adapter", eligibilityTTLSeconds: 900,
            writeStagingMaxBytes: writeStagingMaxBytes)
        return (adapter, store)
    }

    /// Item 3: N concurrent ceiling-sized reservations — only those fitting the
    /// AGGREGATE budget are admitted; the rest are rejected. Releasing frees the
    /// budget again, and after all releases nothing leaks.
    func testWriteLiveBudgetAggregateReservationAndNoLeak() {
        let (adapter, _) = makeAdapter(writeStagingMaxBytes: 1000)
        XCTAssertTrue(adapter.reserveWriteLive(400))
        XCTAssertTrue(adapter.reserveWriteLive(400))
        XCTAssertFalse(adapter.reserveWriteLive(400), "aggregate budget exhausted → reject")
        XCTAssertEqual(adapter.writeLiveBytesForTest, 800, "only the fitting reservations are held")
        adapter.releaseWriteLive(400)
        XCTAssertTrue(adapter.reserveWriteLive(400), "release frees budget for a new reservation")
        adapter.releaseWriteLive(400)
        adapter.releaseWriteLive(400)
        XCTAssertEqual(adapter.writeLiveBytesForTest, 0, "no leak after all releases")
    }

    /// Item 3: the reservation is carried with the snapshot and released exactly once
    /// by the persist Task — completion (or, here, a skipped write against an inactive
    /// store) drains the aggregate budget back to zero.
    func testPersistTaskReleasesWriteLiveReservation() async {
        let (adapter, _) = makeAdapter(writeStagingMaxBytes: 4096)
        XCTAssertTrue(adapter.reserveWriteLive(500))
        XCTAssertEqual(adapter.writeLiveBytesForTest, 500)
        let snap = ConversationColdSnapshot(
            rawKey: "conv:kvs-synth:release", tokens: [], layers: [],
            identity: FakeColdTier.writeIdentity, sampledPurgeGeneration: 0, commitSequence: 1,
            createdAtMillis: 0, eligibleUntilMillis: 0, incarnation: "i", reservedWriteBytes: 500)
        adapter.enqueuePersist(snap)
        await adapter.drainPendingPersists(timeoutSeconds: 5)
        XCTAssertEqual(adapter.writeLiveBytesForTest, 0, "persist Task releases the single-release reservation exactly once")
    }

    // MARK: - HIGH-1: load-time geometry seeding enables first post-restart promotion

    /// Build a real store with one persisted entry whose envelope matches the live
    /// build identity, returning the store + the identity a promotion must present.
    private func makeSeededStoreWithEntry(
        root: URL, namespaceID: String, key: String, dims: [Int], seq: Int
    ) async throws -> (KVDiskCacheStore, KVIdentityCore) {
        var config = KVDiskCacheStoreConfig(
            root: root, namespaceID: namespaceID,
            maxBytes: 1 << 30, maxEntries: 16, maxEntryBytes: 1 << 28,
            retentionSeconds: 3600, stagingMaxBytes: 1 << 28, writeStagingMaxBytes: 1 << 28,
            minFreeBytes: 1 << 20, promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        config.freeSpaceOverride = 1 << 34
        let store = KVDiskCacheStore(config: config, keychain: KVInMemoryKeychain(), sink: KVRecordingEventSink())
        try await store.activate()

        let modelSHA = String(repeating: "b", count: 64)
        let tokCfg = String(repeating: "c", count: 64)
        let tmpl = String(repeating: "d", count: 64)
        let elementCount = dims.reduce(1, *)
        let byteCount = elementCount * KVCodecDType.f32.byteSize
        let layers = [KVLayerPayload(
            layerIndex: 0, classID: "KVCacheSimple", ndim: dims.count, dims: dims, dtype: .f32,
            cacheOffset: seq, keyBytes: Data(count: byteCount), valueBytes: Data(count: byteCount))]
        // The persisted envelope MUST carry the live build identity so promotion's
        // full FR-KVP4 validation passes against it (the seed only supplies geometry).
        let writeIdentity = KVWriteIdentity(
            requestModel: "model-a", servedModelID: "served-a", modelSHA256: modelSHA,
            catalogRevision: "r1", tokenizerID: "served-a", tokenizerConfigSHA256: tokCfg,
            chatTemplateSHA256: tmpl, abiEpoch: KVBuildIdentity.abiEpoch,
            mlxSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision, mlxVersion: KVBuildIdentity.mlxVersion,
            cacheClass: "KVCacheSimple", layerCount: 1, kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil, decodePath: KVBuildIdentity.decodePathOrdinary, keyEpoch: 1)
        let index = try await store.currentIndex(rawKey: key)
        let sampled = try await store.highWatermark(rawKey: key)
        // promoteCandidate reads with the REAL wall clock, so the entry must be
        // eligible relative to "now" — not a fixed past instant (which would expire).
        let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
        let snapshot = KVWriteSnapshot(
            rawKey: key, indexHMAC: try XCTUnwrap(index), tokens: Array(0 ..< Int32(seq)),
            layers: layers, identity: writeIdentity, sampledPurgeGeneration: sampled,
            commitSequence: 1, createdAtMillis: nowMillis, eligibleUntilMillis: nowMillis + 3_600_000,
            incarnation: "inc-seed")
        guard case .committed = try await store.write(snapshot, nowMillis: nowMillis) else {
            XCTFail("seed entry must commit"); return (store, identity())
        }
        let promoteIdentity = KVIdentityCore(
            requestModel: "model-a", servedModelID: "served-a", modelSHA256: modelSHA,
            catalogRevision: "r1", tokenizerID: "served-a", tokenizerConfigSHA256: tokCfg,
            chatTemplateSHA256: tmpl, kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil)
        return (store, promoteIdentity)
    }

    /// HIGH-1 (SPEC-037 KVS-01a) — a FRESH adapter (no prior in-process commit),
    /// given a seeded geometry template + an existing store manifest, promotes the
    /// first matching request. Without the seed the same first request cannot
    /// promote (no live geometry to validate against) — proving the fix closes the
    /// restart-survival gap. Fully headless: synthetic/injected geometry, no MLX.
    func testSeededTemplateEnablesFirstPostRestartPromotionHeadless() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvseed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "conv:kvs-synth:seed"
        let seq = 40
        let (store, promoteIdentity) = try await makeSeededStoreWithEntry(
            root: root, namespaceID: "ns-seed", key: key, dims: [1, 2, seq, 4], seq: seq)

        // WITHOUT a seed: a fresh adapter has no live geometry ⇒ the first request
        // cannot promote (the pre-fix restart-survival gap).
        let unseeded = KVConversationColdTierAdapter(store: store, namespaceID: "ns-seed", eligibilityTTLSeconds: 900)
        let missBeforeSeed = await unseeded.promoteCandidate(conversationKey: key, identity: promoteIdentity)
        XCTAssertNil(missBeforeSeed, "without a seeded template the first post-restart request cannot promote")

        // WITH a load-time seed (synthetic 1-token warmup geometry, seq len ignored):
        // the seeded envelope validates and the store returns a HIT for the first
        // request. Driven through `store.read` (whose hit carries raw byte payloads)
        // rather than the full `promoteCandidate`, whose MLXArray restore needs Metal
        // — the full restore path is covered by the MLX-gated test below.
        let seeded = KVConversationColdTierAdapter(store: store, namespaceID: "ns-seed", eligibilityTTLSeconds: 900)
        let warmupPayloads = [KVLayerPayload(
            layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, 1, 4], dtype: .f32,
            cacheOffset: 1, keyBytes: Data(), valueBytes: Data())]
        let template = KVConversationColdTierAdapter.seedGeometryTemplate(fromPayloads: warmupPayloads)
        seeded.seedTemplate(servedModelID: "served-a", template: template)
        XCTAssertTrue(seeded.hasGeometryTemplateForTest(servedModelID: "served-a"))

        let ownedTemplate = try XCTUnwrap(seeded.geometryTemplateForTest(servedModelID: "served-a"))
        let epoch = await store.currentEpoch
        let runtime = seeded.promotionRuntime(identity: promoteIdentity, template: ownedTemplate, epoch: epoch)
        let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
        let result = try await store.read(rawKey: key, runtime: runtime, nowMillis: nowMillis, emitHitEvent: false)
        guard case let .hit(hit) = result else {
            return XCTFail("seeded template must make the FIRST request a store hit, got \(result)")
        }
        XCTAssertEqual(hit.tokens, Array(0 ..< Int32(seq)),
                       "promotion validates against the persisted canonical token sequence")
        await store.deactivate()
    }

    /// HIGH-1 — the seed template built from a warmup cache with a DIFFERENT
    /// (mismatched) per-layer geometry only ever causes a MISS, never a wrong
    /// promotion: full FR-KVP4 validation still runs against the live manifest.
    func testSeededTemplateWithWrongGeometryStillMisses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvseedwrong-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "conv:kvs-synth:seed-wrong"
        let seq = 40
        let (store, promoteIdentity) = try await makeSeededStoreWithEntry(
            root: root, namespaceID: "ns-seed-wrong", key: key, dims: [1, 2, seq, 4], seq: seq)

        let seeded = KVConversationColdTierAdapter(store: store, namespaceID: "ns-seed-wrong", eligibilityTTLSeconds: 900)
        // Wrong head_dim (8 instead of the persisted 4) ⇒ non-seq geometry mismatch.
        let wrongPayloads = [KVLayerPayload(
            layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, 1, 8], dtype: .f32,
            cacheOffset: 1, keyBytes: Data(), valueBytes: Data())]
        seeded.seedTemplate(servedModelID: "served-a",
                            template: KVConversationColdTierAdapter.seedGeometryTemplate(fromPayloads: wrongPayloads))
        let candidate = await seeded.promoteCandidate(conversationKey: key, identity: promoteIdentity)
        XCTAssertNil(candidate, "a wrong seeded geometry must MISS, never wrongly promote")
        await store.deactivate()
    }

    /// HIGH-1 — the load-time seed derives the SAME per-layer template geometry that
    /// `captureSnapshot` learns from a real multi-token commit (equivalence proof for
    /// `KVCacheSimple`'s rank-4 [batch, kvHeads, seq, headDim] layout).
    func testSeedTemplateMatchesCaptureSnapshotDerivation() {
        // A realistic committed shape with a unique, multi-token sequence length.
        let committed = [
            KVLayerPayload(layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 8, 57, 128],
                           dtype: .f16, cacheOffset: 57, keyBytes: Data(), valueBytes: Data()),
            KVLayerPayload(layerIndex: 1, classID: "KVCacheSimple", ndim: 4, dims: [1, 8, 57, 128],
                           dtype: .f16, cacheOffset: 57, keyBytes: Data(), valueBytes: Data()),
        ]
        let learned = KVConversationColdTierAdapter.liveGeometryTemplate(fromPayloads: committed, tokenCount: 57)
        // A 1-token warmup produces the same NON-seq geometry; the seq-axis value is ignored.
        let warmup = [
            KVLayerPayload(layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 8, 1, 128],
                           dtype: .f16, cacheOffset: 1, keyBytes: Data(), valueBytes: Data()),
            KVLayerPayload(layerIndex: 1, classID: "KVCacheSimple", ndim: 4, dims: [1, 8, 1, 128],
                           dtype: .f16, cacheOffset: 1, keyBytes: Data(), valueBytes: Data()),
        ]
        let seeded = KVConversationColdTierAdapter.seedGeometryTemplate(fromPayloads: warmup)
        XCTAssertEqual(seeded.count, learned.count)
        for (s, l) in zip(seeded, learned) {
            XCTAssertEqual(s.sequenceAxis, l.sequenceAxis, "seed and commit agree on the sequence axis (ndim-2)")
            XCTAssertEqual(s.ndim, l.ndim)
            XCTAssertEqual(s.dtype, l.dtype)
            XCTAssertEqual(s.classID, l.classID)
            XCTAssertEqual(s.layoutVersion, l.layoutVersion)
            // Non-seq axes must match exactly (they are what validation compares).
            for axis in 0 ..< l.dims.count where axis != l.sequenceAxis {
                XCTAssertEqual(s.dims[axis], l.dims[axis], "non-seq dim \(axis) must match")
            }
        }
    }

    /// FINDING D — a commit whose sequence length COLLIDES with another dim (e.g.
    /// `[1,32,32,128]`, tokenCount=32) must still learn the structural seq axis
    /// `ndim - 2` (axis 2), NOT the first dim equal to tokenCount (axis 1, kvHeads).
    /// A wrong axis here would overwrite the correct load-time seed and later miss /
    /// corrupt normal-length promotions.
    func testLiveGeometryTemplateUsesStructuralAxisOnTokenCountCollision() {
        let collided = [
            KVLayerPayload(layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 32, 32, 128],
                           dtype: .f16, cacheOffset: 32, keyBytes: Data(), valueBytes: Data()),
        ]
        let learned = KVConversationColdTierAdapter.liveGeometryTemplate(fromPayloads: collided, tokenCount: 32)
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned[0].sequenceAxis, 2, "seq axis must be ndim-2, not the kvHeads dim that also equals tokenCount")

        // And it is byte-identical to the load-time seed for the same shape.
        let seeded = KVConversationColdTierAdapter.seedGeometryTemplate(fromPayloads: collided)
        XCTAssertEqual(seeded[0].sequenceAxis, learned[0].sequenceAxis, "seed and commit agree even under collision")
        XCTAssertEqual(seeded[0].dims, learned[0].dims)
        XCTAssertEqual(seeded[0].ndim, learned[0].ndim)
        XCTAssertEqual(seeded[0].dtype, learned[0].dtype)
        XCTAssertEqual(seeded[0].classID, learned[0].classID)
        XCTAssertEqual(seeded[0].layoutVersion, learned[0].layoutVersion)
    }

    /// HIGH-1 (MLX-gated) — seed from a REAL `KVCacheSimple` populated via MLX and
    /// promote on the first request. Gated on KV_ENABLE_MLX_TESTS (MLX aborts the
    /// process without a Metal library).
    func testSeededTemplateFromRealCachePromotesFirstRequestMLX() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KV_ENABLE_MLX_TESTS"] == "1",
                          "requires MLX Metal runtime (set KV_ENABLE_MLX_TESTS=1 on a capable host)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvseedmlx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A real cache: shape [1, 2, 2, 2] f32, so seq len 2, head_dim 2, 2 kv heads.
        let realCache = KVCacheSimple()
        realCache.state = [
            MLXArray((0 ..< 8).map { Float($0) }, [1, 2, 2, 2]),
            MLXArray((0 ..< 8).map { Float($0) + 100 }, [1, 2, 2, 2]),
        ]
        let realPayloads = try XCTUnwrap(KVCacheSerialization.snapshotLayers([realCache]))
        let seq = 2
        let key = "conv:kvs-synth:seed-mlx"
        let (store, promoteIdentity) = try await makeSeededStoreWithEntry(
            root: root, namespaceID: "ns-seed-mlx", key: key, dims: [1, 2, seq, 2], seq: seq)

        let seeded = KVConversationColdTierAdapter(store: store, namespaceID: "ns-seed-mlx", eligibilityTTLSeconds: 900)
        seeded.seedTemplate(servedModelID: "served-a",
                            template: KVConversationColdTierAdapter.seedGeometryTemplate(fromPayloads: realPayloads))
        let candidate = await seeded.promoteCandidate(conversationKey: key, identity: promoteIdentity)
        XCTAssertNotNil(candidate, "seed from a real MLX cache lets the first request promote")
        XCTAssertEqual(candidate?.canonicalTokens, Array(0 ..< Int32(seq)))
        await store.deactivate()
    }

    /// HIGH-3: the write-live reservation must cover the ACTIVE seal footprint (one chunk
    /// plaintext + sealed ciphertext(+tag) + one frame + the manifest buffer), not just
    /// the decoded snapshot. So a snapshot whose decoded size sits AT the write-staging
    /// ceiling has a true footprint that EXCEEDS the budget and is rejected — where the
    /// old decoded-only reservation would have admitted it and then overrun during sealing.
    func testWriteFootprintCoversActiveSealBuffers() {
        let ceiling = 256 * 1024 * 1024
        let (adapter, _) = makeAdapter(writeStagingMaxBytes: ceiling)
        XCTAssertGreaterThan(adapter.writeFootprintForTest(decoded: 1_000_000), 1_000_000,
                             "footprint must exceed decoded size to cover the active seal buffers")
        XCTAssertGreaterThan(adapter.writeFootprintForTest(decoded: ceiling), ceiling,
                             "a decoded-at-ceiling snapshot's true write footprint exceeds the budget → reject")
    }

    // MARK: - SPEC-037 FR-KVP1: serve newCache → captureSnapshot persist invariant

    /// PRIMARY GUARD (headless, ungated) — the exact invariant the serve `newCache`
    /// branches on. mlx-swift-lm's `LanguageModel.newCache` builds a `RotatingKVCache`
    /// when `maxKVSize != nil` and a serializable `KVCacheSimple` only when it is nil.
    /// `makeServeGenerateParameters` always sets `maxKVSize = maxContextTokens`, so
    /// before the fix EVERY serve request got a RotatingKVCache, `captureSnapshot`'s
    /// `as? [KVCacheSimple]` cast failed, and the disk tier silently persisted nothing.
    /// `cacheParameters` must drop `maxKVSize` for a tier-eligible request and leave it
    /// untouched otherwise. This runs in normal CI with no MLX.
    func testCacheParametersDropsMaxKVSizeOnlyForEligibleRequests() {
        let maxContextTokens = 4096
        let base = GenerateParameters(
            maxTokens: 128, maxKVSize: maxContextTokens, kvBits: nil,
            temperature: 0.0, topP: 1.0, prefillStepSize: 512)

        let eligible = ModelRuntime.cacheParameters(base, forceSimpleKV: true)
        XCTAssertNil(eligible.maxKVSize,
                     "tier-eligible request → maxKVSize nil so newCache builds a serializable KVCacheSimple")

        let buyer = ModelRuntime.cacheParameters(base, forceSimpleKV: false)
        XCTAssertEqual(buyer.maxKVSize, maxContextTokens,
                       "non-eligible request keeps the rotating-cache bound unchanged")

        // The KV-size selection must not perturb any other generation parameter.
        XCTAssertEqual(eligible.maxTokens, base.maxTokens)
        XCTAssertEqual(eligible.prefillStepSize, base.prefillStepSize)
        XCTAssertEqual(eligible.temperature, base.temperature)
        XCTAssertEqual(eligible.topP, base.topP)
    }

    /// MLX-gated commit-time serialization proof — verifies ONLY that the adapter's
    /// `captureSnapshot` produces a non-nil snapshot for a POPULATED `KVCacheSimple`
    /// (the `as? [KVCacheSimple]` cast succeeds and `snapshotLayers` serializes a real
    /// one-token MLX state). It does NOT drive the serve `newCache` site — the cache is
    /// constructed directly here, so this cannot catch a regression that reverts the
    /// eligible branch to build a RotatingKVCache. That serve-site invariant is pinned
    /// separately and headlessly by `testEligibleServeNewCacheProducesKVCacheSimple`.
    ///
    /// No model weights are loadable in the unit harness, so — exactly like
    /// `testSeededTemplateFromRealCachePromotesFirstRequestMLX` and `KVBridgeProbe` — we
    /// construct a `KVCacheSimple` and populate it with a real one-token MLX state.
    /// Gated on KV_ENABLE_MLX_TESTS (MLX aborts the process without a Metal library).
    func testEligibleServeCacheCaptureSnapshotPersistsMLX() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KV_ENABLE_MLX_TESTS"] == "1",
                          "requires MLX Metal runtime (set KV_ENABLE_MLX_TESTS=1 on a capable host)")

        // The eligible serve path drops maxKVSize → newCache builds a KVCacheSimple.
        let base = GenerateParameters(
            maxTokens: 1, maxKVSize: 4096, kvBits: nil,
            temperature: 0.0, topP: 1.0, prefillStepSize: 512)
        let eligibleParams = ModelRuntime.cacheParameters(base, forceSimpleKV: true)
        XCTAssertNil(eligibleParams.maxKVSize, "eligible params must be the KVCacheSimple selector")

        // A real KVCacheSimple as produced by the eligible-path newCache, populated by a
        // one-token prefill: shape [batch=1, kvHeads=2, seq=1, headDim=2] f32.
        let realCache = KVCacheSimple()
        realCache.offset = 1
        realCache.state = [
            MLXArray((0 ..< 4).map { Float($0) }, [1, 2, 1, 2]),
            MLXArray((0 ..< 4).map { Float($0) + 100 }, [1, 2, 1, 2]),
        ]

        let (adapter, _) = makeAdapter(writeStagingMaxBytes: 1 << 28)
        let snapshot = adapter.captureSnapshot(
            conversationKey: "conv:kvs-synth:persist-mlx",
            layers: ConversationCacheLayers([realCache]),
            fullTokens: [0],
            sampledPurgeGeneration: 0,
            identity: identity(),
            nowMillis: Int(Date().timeIntervalSince1970 * 1000))
        XCTAssertNotNil(snapshot,
            "eligible-path KVCacheSimple serializes → captureSnapshot non-nil (the cast a RotatingKVCache fails)")
    }

    /// PRIMARY SERVE-SITE GUARD (headless, ungated) — pins the production serve
    /// cache-allocation helper `ModelRuntime.serveCache(...)` that BOTH serve sites
    /// (non-streaming ModelRuntime.swift + streaming) now delegate to as one-line calls.
    /// It drives a REAL `LanguageModel.newCache` and asserts eligible → `[KVCacheSimple]`
    /// (so `captureSnapshot`'s `as? [KVCacheSimple]` cast can serialize it) and
    /// non-eligible → `RotatingKVCache`. Because the serve sites are trivial delegations,
    /// a regression that drops the eligibility wrapper (reverting to
    /// `newCache(parameters:)`) must change `serveCache` itself — caught here. The fake
    /// model uses the STOCK `KVCacheDimensionProvider` newCache (the same default real
    /// catalog models such as Llama/Qwen3 inherit), so the class selection here is the
    /// production one. Runs in normal CI: `newCache` is pure allocation, no Metal.
    func testEligibleServeNewCacheProducesKVCacheSimple() {
        let model = FakeDimensionModel(layers: 3)
        let base = GenerateParameters(
            maxTokens: 128, maxKVSize: 4096, kvBits: nil,
            temperature: 0.0, topP: 1.0, prefillStepSize: 512)

        // Eligible branch: serveCache(eligible:true) drops maxKVSize via cacheParameters
        // → the production serve allocation builds [KVCacheSimple].
        let eligibleCaches = ModelRuntime.serveCache(model: model, baseParameters: base, eligible: true)
        XCTAssertNotNil(eligibleCaches as? [KVCacheSimple],
            "eligible serveCache must build [KVCacheSimple] so captureSnapshot's cast succeeds")
        XCTAssertEqual(eligibleCaches.count, 3, "one cache per layer")

        // Non-eligible branch keeps maxKVSize → RotatingKVCache (non-simple): the cast
        // captureSnapshot rejects, which is exactly why the eligible branch must differ.
        let buyerCaches = ModelRuntime.serveCache(model: model, baseParameters: base, eligible: false)
        XCTAssertNil(buyerCaches as? [KVCacheSimple],
            "non-eligible serveCache keeps maxKVSize → a rotating (non-simple) cache")
        XCTAssertTrue(buyerCaches.allSatisfy { $0 is RotatingKVCache },
            "non-eligible params must select RotatingKVCache")
    }

    func testPagedKVCacheClassProbeUsesUnforcedServeParameters() {
        let model = FakeDimensionModel(layers: 3)
        let base = GenerateParameters(
            maxTokens: 128, maxKVSize: 4096, kvBits: nil,
            temperature: 0.0, topP: 1.0, prefillStepSize: 512)

        let forced = ModelRuntime.serveCache(model: model, baseParameters: base, eligible: true)
        XCTAssertNotNil(forced as? [KVCacheSimple])

        let observed = ModelRuntime.pagedKVRuntimeCacheClass(model: model, baseParameters: base)
        XCTAssertEqual(observed, "RotatingKVCache")
    }

    func testPagedKVCacheSeamRegistersKernelWithoutExecutingMetal() async throws {
        let proofModelID = "mlx-community/Qwen-Test"
        let proofModelSHA256 = String(repeating: "a", count: 64)
        let proofTokenizerSHA256 = String(repeating: "b", count: 64)
        let proofChatTemplateSHA256 = String(repeating: "c", count: 64)
        let proof = PagedKVHardwareSizingProof(
            modelID: proofModelID,
            modelSHA256: proofModelSHA256,
            tokenizerSHA256: proofTokenizerSHA256,
            chatTemplateSHA256: proofChatTemplateSHA256,
            modelFamily: "qwen",
            hardwareClass: "apple-silicon-test",
            metallibSHA256: String(repeating: "d", count: 64),
            kernelIdentifier: PagedKVGatherKernel.registeredKernelName,
            blockSizeTokens: 2,
            maxPhysicalBlocks: 4,
            maxResidentTokens: 8,
            parityLabel: "sdpa-parity-v1"
        )
        let decision = PagedKVAttachGate.decide(
            config: PagedKVConfig(enabled: true, blockSizeTokens: 2, maxPhysicalBlocks: 4),
            runtimeCacheClass: "KVCacheSimple",
            kvBits: nil,
            modelID: proofModelID,
            modelSHA256: proofModelSHA256,
            tokenizerSHA256: proofTokenizerSHA256,
            chatTemplateSHA256: proofChatTemplateSHA256,
            modelFamily: "qwen",
            requiresMoEDispatch: false,
            gates: PagedKVGates(
                identityAvailable: true,
                observedHardwareClass: "apple-silicon-test",
                metallibAvailable: true,
                kernelRegistered: true,
                parityEstablished: true,
                hardwareSizingProof: proof,
                observedMetallibSHA256: proof.metallibSHA256,
                observedKernelIdentifier: proof.kernelIdentifier,
                observedParityLabel: proof.parityLabel,
                engineBridgeAvailable: true
            )
        )
        let descriptor = try XCTUnwrap(decision.descriptor)
        let allocator = try PagedKVBlockAllocator(blockSizeTokens: 2, maxPhysicalBlocks: 4)
        let handle = try await allocator.allocate(conversationKey: "conv:paged", maxTokens: 8, initialTokens: 0)
        let binding = try await allocator.binding(for: handle)
        let paged = PagedKVCache(descriptor: descriptor, binding: binding)

        XCTAssertEqual(PagedKVGatherKernel.registeredKernelName, "macprovider_paged_kv_gather_v1")
        XCTAssertTrue(PagedKVGatherKernel.source.contains("block_ids[logical_block]"))
        XCTAssertEqual(paged.offset, 0)
        XCTAssertEqual(paged.maxSize, 8)
        XCTAssertEqual(paged.metaState.first, "macprovider_paged_kv_v1")
    }

    /// SPEC-037 MEDIUM-A/LOW/INFO — a tier-eligible commit holding a NON-KVCacheSimple
    /// cache must skip OBSERVABLY: `disk_write_skipped(detail=unsupported_cache_class)`
    /// carrying the runtime class name, then still fail safe to a miss. Proves the
    /// silence in `captureSnapshot`'s `as? [KVCacheSimple]` cast failure is gone (the
    /// defect was the SILENCE, not the v1-allowlist limitation).
    func testCaptureSnapshotEmitsObservableUnsupportedCacheClassSkip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvucc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = KVRecordingEventSink()
        let config = KVDiskCacheStoreConfig(
            root: root, namespaceID: "ns-ucc",
            maxBytes: 1 << 28, maxEntries: 16, maxEntryBytes: 1 << 26,
            retentionSeconds: 3600, stagingMaxBytes: 1 << 28, writeStagingMaxBytes: 1 << 28,
            minFreeBytes: 1 << 20, promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        let store = KVDiskCacheStore(config: config, keychain: KVInMemoryKeychain(), sink: sink)
        let adapter = KVConversationColdTierAdapter(
            store: store, namespaceID: "ns-ucc", eligibilityTTLSeconds: 900,
            writeStagingMaxBytes: 1 << 28)

        // A RotatingKVCache is a real non-allowlisted cache class — exactly what a
        // gpt-oss/gemma-4/nemotron serve, a rotating hot-cache reuse, or a mid-generation
        // kv-quantized run would leave a tier-eligible request holding.
        let rotating = RotatingKVCache(maxSize: 256, keep: 4)
        let snapshot = adapter.captureSnapshot(
            conversationKey: "conv:kvs-synth:unsupported",
            layers: ConversationCacheLayers([rotating]),
            fullTokens: int32Range(0..<8),
            sampledPurgeGeneration: 0,
            identity: identity(),
            nowMillis: Int(Date().timeIntervalSince1970 * 1000))
        XCTAssertNil(snapshot, "a non-KVCacheSimple cache must still fail safe to a miss (nil)")

        // The skip is emitted from a detached Task; poll briefly for the observable event.
        var event: KVEvent?
        for _ in 0..<200 {
            if let e = sink.events.first(where: {
                $0.code == .diskWriteSkipped && $0.detail == .unsupportedCacheClass
            }) {
                event = e
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let skip = try XCTUnwrap(event,
            "captureSnapshot must emit disk_write_skipped(unsupported_cache_class), not swallow the skip")
        XCTAssertEqual(skip.fields["cache_class"], "RotatingKVCache",
            "the skip must surface the actual runtime cache class, not just a bare reason")
    }

    /// Minimal headless `LanguageModel` whose `newCache` is the stock
    /// `KVCacheDimensionProvider` implementation (RotatingKVCache when `maxKVSize` is
    /// set, KVCacheSimple when nil) — the same default real catalog models inherit.
    /// Only `newCache` is exercised; `prepare` is never called (no weights, no Metal).
    private final class FakeDimensionModel: Module, LanguageModel, KVCacheDimensionProvider {
        let kvHeads: [Int]
        init(layers: Int) {
            self.kvHeads = Array(repeating: 1, count: layers)
            super.init()
        }
        func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
            fatalError("prepare is not exercised by the newCache cache-class invariant test")
        }
    }
}
