import Foundation
import MLXLMCommon

/// SPEC-037 stage 5 — concrete `ConversationColdTier` bridging the hot
/// `ConversationCache` to the serve-owned `KVDiskCacheStore` actor. It performs
/// the MLX <-> on-disk layer materialization via the stage-1 `KVCacheSerialization`
/// bridge and keeps every hot-path cost synchronous and bounded (`captureSnapshot`
/// deep-copies tensor bytes; the actual disk write and all Keychain/actor work is
/// deferred to `persist`/`promoteCandidate`).
final class KVConversationColdTierAdapter: ConversationColdTier {
    private let store: KVDiskCacheStore
    private let eligibilityTTLSeconds: Int
    /// Creating write's incarnation identifier (ownership-checked DEK cleanup, FR-KVP6).
    private let incarnation: String

    init(store: KVDiskCacheStore, eligibilityTTLSeconds: Int, incarnation: String = UUID().uuidString) {
        self.store = store
        self.eligibilityTTLSeconds = eligibilityTTLSeconds
        self.incarnation = incarnation
    }

    private static func nowMillis() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    func sampledPurgeGeneration(conversationKey: String) async -> Int {
        (try? await store.highWatermark(rawKey: conversationKey)) ?? 0
    }

    func promoteCandidate(conversationKey: String, runtime: KVRuntimeIdentity) async -> ColdPromotionCandidate? {
        let result = try? await store.read(
            rawKey: conversationKey, runtime: runtime, nowMillis: Self.nowMillis(), emitHitEvent: false)
        guard let result, case let .hit(hit) = result else { return nil }
        // Materialize KVCacheSimple layers from the validated cold entry (stage-1 bridge).
        let caches = KVCacheSerialization.restore(hit.layers)
        let prefix = (try? await store.currentIndex(rawKey: conversationKey)).flatMap { $0 }.map { String($0.prefix(8)) } ?? ""
        return ColdPromotionCandidate(
            layers: ConversationCacheLayers(caches),
            canonicalTokens: hit.tokens,
            keyHashPrefix: prefix,
            bytesRead: hit.bytesRead,
            decryptMillis: hit.decryptMillis,
            peakStagingBytes: hit.peakStagingBytes)
    }

    func finishPromotion(_ candidate: ColdPromotionCandidate, accepted: Bool, rejectionReason: String?) async {
        if accepted {
            await store.notePromotedHit(
                prefixHash: candidate.keyHashPrefix, bytesRead: candidate.bytesRead,
                decryptMillis: candidate.decryptMillis, peakStagingBytes: candidate.peakStagingBytes)
        } else {
            await store.notePromoteRejected(prefixHash: candidate.keyHashPrefix, reason: rejectionReason ?? "unknown")
        }
    }

    func captureSnapshot(
        conversationKey: String,
        layers: ConversationCacheLayers,
        fullTokens: [Int32],
        sampledPurgeGeneration: Int,
        identity: KVWriteIdentity
    ) -> ConversationColdSnapshot? {
        // Only the v1-allowlisted unquantized class is serializable; any other
        // cache class skips persistence (byte-identical hot behavior for it).
        guard let caches = layers.layers as? [KVCacheSimple] else { return nil }
        guard let payloads = KVCacheSerialization.snapshotLayers(caches) else { return nil }
        let createdAt = Self.nowMillis()
        return ConversationColdSnapshot(
            rawKey: conversationKey,
            tokens: fullTokens,
            layers: payloads,
            identity: identity,
            sampledPurgeGeneration: sampledPurgeGeneration,
            createdAtMillis: createdAt,
            eligibleUntilMillis: createdAt + eligibilityTTLSeconds * 1000,
            incarnation: incarnation)
    }

    func persist(_ snapshot: ConversationColdSnapshot) async {
        _ = try? await store.writeColdSnapshot(
            rawKey: snapshot.rawKey, tokens: snapshot.tokens, layers: snapshot.layers,
            identity: snapshot.identity, sampledPurgeGeneration: snapshot.sampledPurgeGeneration,
            createdAtMillis: snapshot.createdAtMillis, eligibleUntilMillis: snapshot.eligibleUntilMillis,
            incarnation: snapshot.incarnation, nowMillis: Self.nowMillis())
    }
}
