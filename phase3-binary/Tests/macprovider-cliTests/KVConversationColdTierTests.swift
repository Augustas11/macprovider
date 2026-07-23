import MLXLMCommon
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
                             identity: KVIdentityCore) -> ConversationColdSnapshot? {
            if captureReturnsNil { return nil }
            let snap = ConversationColdSnapshot(
                rawKey: conversationKey, tokens: fullTokens, layers: [], identity: Self.writeIdentity,
                sampledPurgeGeneration: sampledPurgeGeneration, commitSequence: 1,
                createdAtMillis: 0, eligibleUntilMillis: 0, incarnation: "test")
            lock.lock(); captured.append(snap); lock.unlock()
            return snap
        }

        func enqueuePersist(_ snapshot: ConversationColdSnapshot) {
            lock.lock(); enqueued.append(snapshot); lock.unlock()
        }
        func cancelPendingPersists() async { lock.lock(); cancelledPersists += 1; lock.unlock() }
        func drainPendingPersists(timeoutSeconds: Int) async {}

        private(set) var enqueued: [ConversationColdSnapshot] = []
        private(set) var cancelledPersists = 0

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
}
