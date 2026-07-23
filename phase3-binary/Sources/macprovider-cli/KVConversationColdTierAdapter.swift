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
    /// The REAL pinned mlx-swift-lm git revision (HIGH-8). Bump on any dependency
    /// change: `KVBuildIdentityDriftTests` parses Package.resolved and fails CI if
    /// this drifts from the resolved pin. A different pin ⇒ a different ABI ⇒ all
    /// prior ciphertext hard-misses (accepted — this tier is an optimization).
    static let mlxSwiftLMRevision = "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"
    /// The REAL pinned mlx-swift package version (HIGH-8). Same bump-on-change rule.
    static let mlxVersion = "0.31.4"
    static let decodePathOrdinary = "ordinary"
}

extension KVIdentityCore {
    /// Build the per-request identity core from what ModelRuntime has directly. The
    /// persisted class is always the unquantized `KVCacheSimple`, so the KV
    /// quantization tuple is `nil` (matching the shipped `kvBits == nil` envelope
    /// value). Tokenizer/template hashes are the REAL live tokenizer-config +
    /// chat-template byte hashes computed at model load (HIGH-8) — never derived from
    /// the model hash. The caller (ModelRuntime.coldContext) supplies them and
    /// suppresses the cold tier entirely when they are unavailable.
    static func build(
        requestModel: String, servedModelID: String, modelSHA256: String?, catalogRevision: String,
        tokenizerConfigSHA256: String, chatTemplateSHA256: String
    ) -> KVIdentityCore {
        KVIdentityCore(
            requestModel: requestModel, servedModelID: servedModelID, modelSHA256: modelSHA256,
            catalogRevision: catalogRevision, tokenizerID: servedModelID,
            tokenizerConfigSHA256: tokenizerConfigSHA256, chatTemplateSHA256: chatTemplateSHA256,
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
    /// Write-live budget ceilings (HIGH-5): reject an oversized snapshot BEFORE the
    /// deep copy so a huge cache can never be copied only to be skipped by the store.
    private let writeStagingMaxBytes: Int
    private let maxEntryBytes: Int
    private let stagingMaxBytes: Int
    /// Instantaneous write-live reservation (RAM bound). Captures are actor-serialized
    /// by ConversationCache, so this bounds the copy-in-flight bytes.
    private let writeLiveLock = NSLock()
    private var writeLiveBytes = 0

    /// Live-model per-layer geometry template, keyed by served model ID. Guarded
    /// by its own lock so the synchronous `captureSnapshot` and async
    /// `promoteCandidate` can both touch it without an actor hop.
    private let templateLock = NSLock()
    private var geometryTemplates: [String: [KVLayerGeometry]] = [:]

    /// CRITICAL-2 — the current key epoch, cached synchronously so `captureSnapshot`
    /// can stamp the epoch at commit time (NOT at persist time). Seeded + refreshed
    /// by the store's epoch observer (activation + rotation).
    private let epochLock = NSLock()
    private var cachedEpoch = 1

    /// CRITICAL-2 — per-index (keyed by raw conversation key) monotonic commit
    /// sequence, allocated synchronously under the hot lease. Seeded from the store's
    /// last published sequence at `sampledPurgeGeneration` (begin-time) so
    /// post-restart writes are not rejected as stale.
    private let seqLock = NSLock()
    private var seqCounters: [String: Int] = [:]

    /// HIGH-5 / CRITICAL-2 — one pending persist Task per index. A newer commit
    /// displaces an unstarted older one; purge-all cancels all; shutdown drains.
    private let taskLock = NSLock()
    private var pendingTasks: [String: Task<Void, Never>] = [:]
    private var pendingGen: [String: Int] = [:]

    init(store: KVDiskCacheStore, namespaceID: String, eligibilityTTLSeconds: Int,
         writeStagingMaxBytes: Int = KVDiskCacheStoreConfig.writeStagingHardMax,
         maxEntryBytes: Int = KVDiskCacheStoreConfig.writeStagingHardMax,
         stagingMaxBytes: Int = KVDiskCacheStoreConfig.promotionCeilingHardMax,
         incarnation: String = UUID().uuidString) {
        self.store = store
        self.namespaceID = namespaceID
        self.eligibilityTTLSeconds = eligibilityTTLSeconds
        self.writeStagingMaxBytes = writeStagingMaxBytes
        self.maxEntryBytes = maxEntryBytes
        self.stagingMaxBytes = stagingMaxBytes
        self.incarnation = incarnation
    }

    /// Cache the current key epoch (store epoch observer). Called synchronously on
    /// the store actor at activation and after each rotation epoch commit.
    func cacheEpoch(_ epoch: Int) {
        epochLock.lock(); cachedEpoch = epoch; epochLock.unlock()
    }

    private func currentCachedEpoch() -> Int {
        epochLock.lock(); defer { epochLock.unlock() }; return cachedEpoch
    }

    private static func nowMillis() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    // MARK: - FR-KVP8 stamping

    func sampledPurgeGeneration(conversationKey: String) async -> Int {
        let gen = (try? await store.highWatermark(rawKey: conversationKey)) ?? 0
        // CRITICAL-2 — seed the synchronous commit-sequence counter from the store's
        // last published sequence for this key, so the first post-restart commit
        // allocates a sequence newer than any recovered manifest.
        let lastSeq = await store.lastPublishedCommitSequence(rawKey: conversationKey)
        seqLock.lock()
        if (seqCounters[conversationKey] ?? 0) < lastSeq { seqCounters[conversationKey] = lastSeq }
        seqLock.unlock()
        return gen
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
        identity: KVIdentityCore,
        nowMillis: Int
    ) -> ConversationColdSnapshot? {
        guard identity.modelSHA256 != nil else { return nil }         // identity_unavailable
        // Only the v1-allowlisted unquantized class is serializable; any other
        // cache class skips persistence (byte-identical hot behavior for it).
        guard let caches = layers.layers as? [KVCacheSimple] else { return nil }

        // HIGH-5 — estimate the decoded size from GEOMETRY (no byte copy) and skip an
        // oversized snapshot BEFORE the deep copy, so a huge cache can never be copied
        // only to be rejected by the store. Then reserve the write-live bytes for the
        // copy and release on every exit via defer.
        guard let estimatedDecoded = KVCacheSerialization.estimatedDecodedLength(caches, tokenCount: fullTokens.count),
              estimatedDecoded <= writeStagingMaxBytes,
              estimatedDecoded <= maxEntryBytes,
              estimatedDecoded <= stagingMaxBytes else {
            return nil
        }
        writeLiveLock.lock(); writeLiveBytes += estimatedDecoded; writeLiveLock.unlock()
        defer { writeLiveLock.lock(); writeLiveBytes -= estimatedDecoded; writeLiveLock.unlock() }

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

        // CRITICAL-2 — capture the key epoch AND allocate the commit sequence
        // synchronously, under the still-held hot lease. The epoch is the store's
        // cached current epoch; a purge-all rotation after this instant makes the
        // captured epoch stale, so the store rejects this snapshot rather than
        // restamping it into (and thereby resurrecting it under) the new epoch.
        let capturedEpoch = currentCachedEpoch()
        seqLock.lock()
        let seq = (seqCounters[conversationKey] ?? 0) + 1
        seqCounters[conversationKey] = seq
        seqLock.unlock()

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
            keyEpoch: capturedEpoch)        // CRITICAL-2: captured at commit, not at persist
        // M-B: derive creation/eligibility from the EXACT hot-commit instant passed
        // in — NOT a wall-clock read taken after the deep copy above, which would
        // gain the copy duration beyond the hot TTL.
        let createdAt = nowMillis
        return ConversationColdSnapshot(
            rawKey: conversationKey,
            tokens: fullTokens,
            layers: payloads,
            identity: writeIdentity,
            sampledPurgeGeneration: sampledPurgeGeneration,
            commitSequence: seq,
            createdAtMillis: createdAt,
            eligibleUntilMillis: createdAt + eligibilityTTLSeconds * 1000,
            incarnation: incarnation)
    }

    // MARK: - Bounded async write queue (one pending per index)

    func enqueuePersist(_ snapshot: ConversationColdSnapshot) {
        taskLock.lock()
        // Displace an unstarted older pending write for this index (HIGH-5).
        pendingTasks[snapshot.rawKey]?.cancel()
        let gen = (pendingGen[snapshot.rawKey] ?? 0) + 1
        pendingGen[snapshot.rawKey] = gen
        let task = Task { [self] in await runPersist(snapshot, gen: gen) }
        pendingTasks[snapshot.rawKey] = task
        taskLock.unlock()
    }

    private func runPersist(_ snapshot: ConversationColdSnapshot, gen: Int) async {
        if !Task.isCancelled { await doWrite(snapshot) }
        taskLock.lock()
        if pendingGen[snapshot.rawKey] == gen { pendingTasks.removeValue(forKey: snapshot.rawKey) }
        taskLock.unlock()
    }

    private func doWrite(_ snapshot: ConversationColdSnapshot) async {
        // No restamping: the identity already carries the epoch captured at commit,
        // and the commit sequence was allocated under the hot lease (CRITICAL-2).
        _ = try? await store.writeColdSnapshot(
            rawKey: snapshot.rawKey, tokens: snapshot.tokens, layers: snapshot.layers,
            identity: snapshot.identity, sampledPurgeGeneration: snapshot.sampledPurgeGeneration,
            commitSequence: snapshot.commitSequence,
            createdAtMillis: snapshot.createdAtMillis, eligibleUntilMillis: snapshot.eligibleUntilMillis,
            incarnation: snapshot.incarnation, nowMillis: Self.nowMillis())
    }

    func cancelPendingPersist(conversationKey: String) async -> Bool {
        taskLock.lock()
        let task = pendingTasks.removeValue(forKey: conversationKey)
        if task != nil { pendingGen[conversationKey, default: 0] += 1 }
        taskLock.unlock()
        task?.cancel()
        await task?.value   // ensure a started write cannot publish after the purge
        return task != nil
    }

    func cancelPendingPersists() async {
        taskLock.lock()
        let tasks = Array(pendingTasks.values)
        pendingTasks.removeAll()
        for key in pendingGen.keys { pendingGen[key, default: 0] += 1 }
        taskLock.unlock()
        for task in tasks { task.cancel() }
        // Await so no in-flight write can publish into the rotated epoch.
        for task in tasks { await task.value }
    }

    // MARK: - FR-KVP12 identity-unavailable telemetry

    func noteReadIdentityUnavailable(conversationKey: String) async {
        await store.noteIdentityUnavailableRead(rawKey: conversationKey)
    }

    func noteWriteSkippedIdentityUnavailable(conversationKey: String) async {
        await store.noteIdentityUnavailableWrite(rawKey: conversationKey)
    }

    func drainPendingPersists(timeoutSeconds: Int) async {
        taskLock.lock(); let tasks = Array(pendingTasks.values); taskLock.unlock()
        guard !tasks.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in tasks { await task.value } }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeoutSeconds)) * 1_000_000_000)
            }
            _ = await group.next()   // whichever completes first (all drained OR timeout)
            group.cancelAll()
            // M-A: cancelling the GROUP's children does not unblock the drainer child's
            // `await task.value` on the underlying persist tasks. Cancel those tasks so
            // queued (unstarted) writes resolve immediately and the timeout truly bounds
            // the drain rather than blocking on unfinished work past the deadline.
            for task in tasks { task.cancel() }
        }
    }
}
