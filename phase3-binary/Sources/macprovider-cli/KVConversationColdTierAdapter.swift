import CryptoKit
import Foundation
import MLXLMCommon

/// SPEC-037 stage 5 — build-pinned envelope identity constants (FR-KVP4 items 6,
/// 10). The ABI epoch and pinned revision strings MUST be bumped by an explicit
/// code change whenever cache-class state layout, the serializer, or the MLX
/// tensor ABI changes incompatibly (any bump hard-misses all prior ciphertext —
/// cache invalidation on upgrade is accepted, this tier is an optimization).
enum KVBuildIdentity {
    static let abiEpoch = 1
    static let mlxSwiftLMRevision = "mlx-swift-lm@spec037-v1"
    static let mlxVersion = "mlx-swift@spec037-v1"
    static let decodePathOrdinary = "ordinary"
}

extension KVIdentityCore {
    /// Build the per-request identity core from what ModelRuntime has directly.
    /// The persisted class is always the unquantized `KVCacheSimple`, so the KV
    /// quantization tuple is `nil` (matching the shipped `kvBits == nil` envelope
    /// value). Tokenizer/template hashes are derived deterministically from the
    /// canonical model hash: within a build a different artifact ⇒ different hash
    /// ⇒ miss, and the same artifact round-trips (v0.1 resolution — the artifact
    /// hash already covers the packaged tokenizer + template; separate live file
    /// hashing is a future refinement).
    static func build(
        requestModel: String, servedModelID: String, modelSHA256: String?, catalogRevision: String
    ) -> KVIdentityCore {
        func derive(_ tag: String) -> String {
            guard let hash = modelSHA256 else { return "" }
            return SHA256.hash(data: Data((tag + ":" + hash).utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return KVIdentityCore(
            requestModel: requestModel, servedModelID: servedModelID, modelSHA256: modelSHA256,
            catalogRevision: catalogRevision, tokenizerID: servedModelID,
            tokenizerConfigSHA256: derive("tok"), chatTemplateSHA256: derive("tmpl"),
            kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil)
    }
}

/// SPEC-037 stage 5 — concrete `ConversationColdTier` bridging the hot
/// `ConversationCache` to the serve-owned `KVDiskCacheStore` actor. It performs
/// the MLX <-> on-disk layer materialization via the stage-1 `KVCacheSerialization`
/// bridge and keeps every hot-path cost synchronous and bounded (`captureSnapshot`
/// deep-copies tensor bytes; the actual disk write and all Keychain/actor work is
/// deferred to `persist`/`promoteCandidate`).
///
/// The adapter owns the **live-model geometry template** (per served model ID),
/// learned from each write. Envelope validation on promotion compares this
/// live-model template against the persisted manifest, so a warm-swap to a
/// different geometry/dtype/layer-count is a miss even when the served model ID
/// or hash somehow matches. The template is process-local: a served model that
/// has not yet committed in the current process has no template, so its first
/// post-restart turn cannot promote until it commits once (documented residual;
/// closing it needs load-time geometry capture).
final class KVConversationColdTierAdapter: ConversationColdTier {
    private let store: KVDiskCacheStore
    private let namespaceID: String
    private let eligibilityTTLSeconds: Int
    /// Creating write's incarnation identifier (ownership-checked DEK cleanup, FR-KVP6).
    private let incarnation: String

    /// Live-model per-layer geometry template, keyed by served model ID. Guarded
    /// by its own lock so the synchronous `captureSnapshot` and async
    /// `promoteCandidate` can both touch it without an actor hop.
    private let templateLock = NSLock()
    private var geometryTemplates: [String: [KVLayerGeometry]] = [:]

    init(store: KVDiskCacheStore, namespaceID: String, eligibilityTTLSeconds: Int,
         incarnation: String = UUID().uuidString) {
        self.store = store
        self.namespaceID = namespaceID
        self.eligibilityTTLSeconds = eligibilityTTLSeconds
        self.incarnation = incarnation
    }

    private static func nowMillis() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    // MARK: - FR-KVP8 stamping

    func sampledPurgeGeneration(conversationKey: String) async -> Int {
        (try? await store.highWatermark(rawKey: conversationKey)) ?? 0
    }

    // MARK: - FR-KVP9 promotion

    func promoteCandidate(conversationKey: String, identity: KVIdentityCore) async -> ColdPromotionCandidate? {
        guard identity.modelSHA256 != nil else { return nil }   // identity_unavailable
        templateLock.lock()
        let template = geometryTemplates[identity.servedModelID]
        templateLock.unlock()
        guard let template, !template.isEmpty else { return nil } // no live geometry to validate against
        let epoch = await store.currentEpoch
        let runtime = KVRuntimeIdentity(
            namespaceID: namespaceID,
            keyEpoch: epoch,
            indexHMAC: "",                 // recomputed inside read()
            requestModel: identity.requestModel,
            servedModelID: identity.servedModelID,
            modelSHA256: identity.modelSHA256,
            catalogRevision: identity.catalogRevision,
            tokenizerID: identity.tokenizerID,
            tokenizerConfigSHA256: identity.tokenizerConfigSHA256,
            chatTemplateSHA256: identity.chatTemplateSHA256,
            abiEpoch: KVBuildIdentity.abiEpoch,
            mlxSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision,
            mlxVersion: KVBuildIdentity.mlxVersion,
            cacheClass: KVDiskCacheFormat.allowlistedCacheClasses.first ?? "KVCacheSimple",
            layerCount: template.count,
            layers: template,
            kvBits: identity.kvBits,
            kvGroupSize: identity.kvGroupSize,
            kvQuantMode: identity.kvQuantMode,
            kvQuantPolicy: identity.kvQuantPolicy,
            decodePath: KVBuildIdentity.decodePathOrdinary,
            liveHighWatermark: 0)          // overridden inside read()
        let result = try? await store.read(
            rawKey: conversationKey, runtime: runtime, nowMillis: Self.nowMillis(), emitHitEvent: false)
        guard let result, case let .hit(hit) = result else { return nil }
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

    // MARK: - FR-KVP3 snapshot-at-commit

    func captureSnapshot(
        conversationKey: String,
        layers: ConversationCacheLayers,
        fullTokens: [Int32],
        sampledPurgeGeneration: Int,
        identity: KVIdentityCore
    ) -> ConversationColdSnapshot? {
        guard identity.modelSHA256 != nil else { return nil }         // identity_unavailable
        // Only the v1-allowlisted unquantized class is serializable; any other
        // cache class skips persistence (byte-identical hot behavior for it).
        guard let caches = layers.layers as? [KVCacheSimple] else { return nil }
        guard let payloads = KVCacheSerialization.snapshotLayers(caches) else { return nil }

        // Learn/refresh the live-model geometry template for future promotions.
        let template = payloads.map { payload -> KVLayerGeometry in
            let seqAxis = payload.dims.firstIndex(of: fullTokens.count) ?? max(0, payload.ndim - 2)
            return KVLayerGeometry(
                layerIndex: payload.layerIndex, classID: payload.classID, layoutVersion: 1,
                ndim: payload.ndim, dims: payload.dims, dtype: payload.dtype, sequenceAxis: seqAxis)
        }
        templateLock.lock()
        geometryTemplates[identity.servedModelID] = template
        templateLock.unlock()

        let writeIdentity = KVWriteIdentity(
            requestModel: identity.requestModel,
            servedModelID: identity.servedModelID,
            modelSHA256: identity.modelSHA256 ?? "",
            catalogRevision: identity.catalogRevision,
            tokenizerID: identity.tokenizerID,
            tokenizerConfigSHA256: identity.tokenizerConfigSHA256,
            chatTemplateSHA256: identity.chatTemplateSHA256,
            abiEpoch: KVBuildIdentity.abiEpoch,
            mlxSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision,
            mlxVersion: KVBuildIdentity.mlxVersion,
            cacheClass: payloads.first?.classID ?? "KVCacheSimple",
            layerCount: payloads.count,
            kvBits: identity.kvBits,
            kvGroupSize: identity.kvGroupSize,
            kvQuantMode: identity.kvQuantMode,
            kvQuantPolicy: identity.kvQuantPolicy,
            decodePath: KVBuildIdentity.decodePathOrdinary,
            keyEpoch: 0)                    // filled from the live epoch inside the store
        let createdAt = Self.nowMillis()
        return ConversationColdSnapshot(
            rawKey: conversationKey,
            tokens: fullTokens,
            layers: payloads,
            identity: writeIdentity,
            sampledPurgeGeneration: sampledPurgeGeneration,
            createdAtMillis: createdAt,
            eligibleUntilMillis: createdAt + eligibilityTTLSeconds * 1000,
            incarnation: incarnation)
    }

    func persist(_ snapshot: ConversationColdSnapshot) async {
        // Stamp the live key epoch into the write identity at publish time.
        let epoch = await store.currentEpoch
        var identity = snapshot.identity
        identity = KVWriteIdentity(
            requestModel: identity.requestModel, servedModelID: identity.servedModelID,
            modelSHA256: identity.modelSHA256, catalogRevision: identity.catalogRevision,
            tokenizerID: identity.tokenizerID, tokenizerConfigSHA256: identity.tokenizerConfigSHA256,
            chatTemplateSHA256: identity.chatTemplateSHA256, abiEpoch: identity.abiEpoch,
            mlxSwiftLMRevision: identity.mlxSwiftLMRevision, mlxVersion: identity.mlxVersion,
            cacheClass: identity.cacheClass, layerCount: identity.layerCount, kvBits: identity.kvBits,
            kvGroupSize: identity.kvGroupSize, kvQuantMode: identity.kvQuantMode,
            kvQuantPolicy: identity.kvQuantPolicy, decodePath: identity.decodePath, keyEpoch: epoch)
        _ = try? await store.writeColdSnapshot(
            rawKey: snapshot.rawKey, tokens: snapshot.tokens, layers: snapshot.layers,
            identity: identity, sampledPurgeGeneration: snapshot.sampledPurgeGeneration,
            createdAtMillis: snapshot.createdAtMillis, eligibleUntilMillis: snapshot.eligibleUntilMillis,
            incarnation: snapshot.incarnation, nowMillis: Self.nowMillis())
    }
}
