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
        XCTAssertTrue(PrivacyRuntimeHardening.privacyPathBypassesKVDiskTier())
        for provenance in [KVIngestProvenance.directHTTP, .relay, .tier2, .unknown] {
            XCTAssertTrue(ModelRuntime.coldTierAdmits(provenance: provenance), "\(provenance)")
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
