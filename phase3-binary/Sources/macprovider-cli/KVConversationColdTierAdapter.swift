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
/// or hash somehow matches. The template is seeded at cold-tier attach / model
/// load from the ACTUAL loaded `KVCacheSimple` geometry (HIGH-1,
/// `seedTemplate`), so the FIRST post-restart request can promote (SPEC-037
/// KVS-01a); commits thereafter refresh it. When the seed is unavailable
/// (MLX/Metal absent, or a non-`KVCacheSimple` runtime), the model's first
/// post-restart turn falls back to a fresh prefill until it commits once.
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
    /// Aggregate write-live reservation (Item 3, FR-KVP3 RAM-DoS bound). ONE budget
    /// (`writeStagingMaxBytes`) covers all write-side memory held simultaneously —
    /// every pending snapshot's deep copy plus the active serializer/codec buffers.
    /// A reservation is taken atomically BEFORE the deep copy (rejecting the commit if
    /// it would exceed the budget) and released exactly once when the persist Task
    /// finishes/cancels/is displaced — NOT at capture return. This bounds the true
    /// simultaneous write-side residency, so multiple indices cannot each retain a
    /// ceiling-sized snapshot concurrently.
    private let writeLiveLock = NSLock()
    private var writeLiveBytes = 0

    /// Item 3: atomically reserve `estimate` bytes against the aggregate write-live
    /// budget. Returns false (reject) when the running total plus `estimate` would
    /// exceed `writeStagingMaxBytes`. A successful reservation MUST be released exactly
    /// once via `releaseWriteLive`.
    func reserveWriteLive(_ estimate: Int) -> Bool {
        writeLiveLock.lock(); defer { writeLiveLock.unlock() }
        guard writeLiveBytes + estimate <= writeStagingMaxBytes else { return false }
        writeLiveBytes += estimate
        return true
    }

    /// Item 3: release a previously-taken write-live reservation (idempotent-safe for a
    /// zero-byte token). Never over-releases below zero.
    func releaseWriteLive(_ bytes: Int) {
        guard bytes > 0 else { return }
        writeLiveLock.lock(); writeLiveBytes = max(0, writeLiveBytes - bytes); writeLiveLock.unlock()
    }

    /// Test-only: the current aggregate write-live reservation (asserts no leak).
    var writeLiveBytesForTest: Int {
        writeLiveLock.lock(); defer { writeLiveLock.unlock() }; return writeLiveBytes
    }

    /// Test-only (HIGH-3): the aggregate write-live footprint reserved for a snapshot of
    /// the given decoded size — decoded PLUS the active seal footprint. Used to assert a
    /// near-ceiling snapshot reserves more than `decoded`, so the true seal-time peak
    /// cannot exceed `writeStagingMaxBytes`.
    func writeFootprintForTest(decoded: Int) -> Int { decoded + activeSealFootprint(decoded: decoded) }

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

    // MARK: - HIGH-1 load-time geometry seeding (SPEC-037 KVS-01a)

    /// Build the live-model geometry template that `captureSnapshot` learns from a
    /// committed entry's layer payloads. Factored out so `ModelRuntime`'s load-time
    /// seed (below) and the commit-time learn produce byte-identical geometry. The
    /// sequence axis is derived STRUCTURALLY as the rank-4 `KVCacheSimple` layout axis
    /// (`ndim - 2` — the `seq` axis of `[batch, kvHeads, seq, headDim]`), identical to
    /// `seedGeometryTemplate`. This must not key off a payload dim that equals
    /// `tokenCount`: for a shape like `[1,32,32,128]` with tokenCount=32 that would pick
    /// axis 1 (kvHeads) instead of the real seq axis 2, and a commit would overwrite the
    /// correct load-seed with a wrong-axis template. The v1 allowlist is
    /// KVCacheSimple-only, whose seq axis is always `ndim - 2`.
    static func liveGeometryTemplate(fromPayloads payloads: [KVLayerPayload], tokenCount: Int) -> [KVLayerGeometry] {
        payloads.map { payload in
            KVLayerGeometry(
                layerIndex: payload.layerIndex, classID: payload.classID, layoutVersion: 1,
                ndim: payload.ndim, dims: payload.dims, dtype: payload.dtype,
                sequenceAxis: max(0, payload.ndim - 2))
        }
    }

    /// HIGH-1 — build the seed template from a freshly warmed `KVCacheSimple`'s layer
    /// payloads at model-load time. The sequence axis is keyed structurally to the
    /// rank-4 `KVCacheSimple` layout (`ndim - 2` — the axis mlx writes KV into for the
    /// `[batch, kvHeads, seq, headDim]` state), so it is derived without depending on
    /// the (possibly ambiguous, e.g. 1-token) warmup sequence length. For
    /// `KVCacheSimple` this equals the axis `captureSnapshot` records for any real
    /// multi-token commit, so a seeded promotion validates identically. A wrong axis
    /// or stale template can only ever cause a validation MISS (the store still
    /// re-checks every FR-KVP4 field against the live manifest) — never a wrong
    /// promotion; the template only supplies the EXPECTED geometry to compare against.
    static func seedGeometryTemplate(fromPayloads payloads: [KVLayerPayload]) -> [KVLayerGeometry] {
        payloads.map { payload in
            KVLayerGeometry(
                layerIndex: payload.layerIndex, classID: payload.classID, layoutVersion: 1,
                ndim: payload.ndim, dims: payload.dims, dtype: payload.dtype,
                sequenceAxis: max(0, payload.ndim - 2))
        }
    }

    /// HIGH-1 — seed the live-model geometry template at cold-tier attach / model
    /// load, BEFORE request admission, so the FIRST post-restart request for
    /// `servedModelID` can promote a persisted entry (SPEC-037 KVS-01a) instead of
    /// missing until some other conversation commits in-process. Never overwrites a
    /// template already learned from an in-process commit (that one is at least as
    /// fresh as this load-time seed).
    func seedTemplate(servedModelID: String, template: [KVLayerGeometry]) {
        guard !template.isEmpty else { return }
        templateLock.lock()
        if geometryTemplates[servedModelID] == nil { geometryTemplates[servedModelID] = template }
        templateLock.unlock()
    }

    /// Test-only: whether a live-model geometry template is present for the served model.
    func hasGeometryTemplateForTest(servedModelID: String) -> Bool {
        templateLock.lock(); defer { templateLock.unlock() }
        return geometryTemplates[servedModelID]?.isEmpty == false
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

    /// Assemble the read-time runtime envelope from the per-request identity core plus
    /// the owned live-model geometry `template` and the build-pinned ABI fields — so
    /// write and read derive identical envelopes. Factored out of `promoteCandidate`
    /// so the load-time-seeding mechanism can be validated headlessly against
    /// `store.read` (whose hit returns raw `KVLayerPayload` bytes), without the
    /// `MLXArray` restore below that needs a Metal runtime.
    func promotionRuntime(identity: KVIdentityCore, template: [KVLayerGeometry], epoch: Int) -> KVRuntimeIdentity {
        KVRuntimeIdentity(
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
    }

    /// Test-only: the currently-owned live-model geometry template for a served model.
    func geometryTemplateForTest(servedModelID: String) -> [KVLayerGeometry]? {
        templateLock.lock(); defer { templateLock.unlock() }
        return geometryTemplates[servedModelID]
    }

    func promoteCandidate(conversationKey: String, identity: KVIdentityCore) async -> ColdPromotionCandidate? {
        guard identity.modelSHA256 != nil else { return nil }   // identity_unavailable
        templateLock.lock()
        let template = geometryTemplates[identity.servedModelID]
        templateLock.unlock()
        guard let template, !template.isEmpty else { return nil } // no live geometry to validate against
        let epoch = await store.currentEpoch
        let runtime = promotionRuntime(identity: identity, template: template, epoch: epoch)
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
            peakStagingBytes: hit.peakStagingBytes,
            modelSHA256: identity.modelSHA256 ?? "",
            catalogRevision: identity.catalogRevision,
            kvBits: identity.kvBits)
    }

    func finishPromotion(_ candidate: ColdPromotionCandidate, accepted: Bool, rejectionReason: String?) async {
        if accepted {
            await store.notePromotedHit(
                prefixHash: candidate.keyHashPrefix, bytesRead: candidate.bytesRead,
                decryptMillis: candidate.decryptMillis, peakStagingBytes: candidate.peakStagingBytes,
                modelSHA256: candidate.modelSHA256, catalogRevision: candidate.catalogRevision,
                kvBits: candidate.kvBits)
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
        // only to be rejected by the store.
        guard let estimatedDecoded = KVCacheSerialization.estimatedDecodedLength(caches, tokenCount: fullTokens.count),
              estimatedDecoded <= maxEntryBytes,
              estimatedDecoded <= stagingMaxBytes else {
            return nil
        }

        // HIGH-3 — the write-live budget must cover the ACTIVE seal footprint, not just
        // the decoded snapshot. During the store's streaming seal, on top of the deep copy
        // one chunk plaintext + its sealed ciphertext(+tag) + one frame + the manifest
        // buffer are simultaneously live. Reserve that worst-case footprint (not merely
        // `estimatedDecoded`) so a near-ceiling snapshot cannot exceed write_staging_max
        // during sealing — it is rejected up front instead.
        let writeFootprint = estimatedDecoded + activeSealFootprint(decoded: estimatedDecoded)
        guard writeFootprint <= writeStagingMaxBytes else { return nil }

        // Item 3 (FR-KVP3): ONE aggregate write-live reservation held across the whole
        // persist lifetime. Reserve atomically BEFORE the deep copy; if it would exceed
        // the aggregate budget, REJECT (disk_write_skipped, detail=write_budget) rather
        // than copying. The reservation is NOT released here — it is carried with the
        // snapshot as a single-release token and released once by the persist Task
        // (completion, cancellation, or displacement). Multiple indices therefore cannot
        // each retain a ceiling-sized snapshot concurrently.
        guard reserveWriteLive(writeFootprint) else {
            Task { [store] in await store.noteWriteBudgetSkipped(rawKey: conversationKey) }
            return nil
        }
        // From here, any early return before building the snapshot MUST release the
        // reservation (the snapshot that would otherwise carry it is not produced).
        var reservationHandedOff = false
        defer { if !reservationHandedOff { releaseWriteLive(writeFootprint) } }

        guard let payloads = KVCacheSerialization.snapshotLayers(caches) else { return nil }

        // Learn/refresh the live-model geometry template for future promotions.
        let template = Self.liveGeometryTemplate(fromPayloads: payloads, tokenCount: fullTokens.count)
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
        // The reservation is handed off to the snapshot (single-release token); the
        // persist Task releases it exactly once.
        reservationHandedOff = true
        return ConversationColdSnapshot(
            rawKey: conversationKey,
            tokens: fullTokens,
            layers: payloads,
            identity: writeIdentity,
            sampledPurgeGeneration: sampledPurgeGeneration,
            commitSequence: seq,
            createdAtMillis: createdAt,
            eligibleUntilMillis: createdAt + eligibilityTTLSeconds * 1000,
            incarnation: incarnation,
            reservedWriteBytes: writeFootprint)
    }

    /// HIGH-3 — worst-case ACTIVE seal memory held (beyond the deep-copied snapshot) by
    /// `KVDiskCacheStore.commitEntry`'s streaming seal: one chunk plaintext + its sealed
    /// ciphertext(+GCM tag) + one framed chunk + the manifest buffer are co-resident.
    /// Chunk size is bounded by the codec's max chunk ciphertext length.
    private func activeSealFootprint(decoded: Int) -> Int {
        let chunkLen = max(1, min(decoded, KVDiskCacheFormat.maxChunkCiphertextBytes))
        let frameOverhead = 4 + 4 + 4 + KVDiskCacheFormat.chunkNonceBytes + KVDiskCacheFormat.gcmTagBytes
        let chunkPlaintext = chunkLen
        let sealedCiphertext = chunkLen + KVDiskCacheFormat.gcmTagBytes
        let framedChunk = chunkLen + frameOverhead
        return chunkPlaintext + sealedCiphertext + framedChunk + KVDiskCacheFormat.manifestMaxBytes
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
        // Item 3: release the single-release write-live reservation exactly once, on
        // EVERY exit — completion, cancellation (skipped doWrite), or displacement (a
        // newer commit cancelled this Task). This is the sole release site for a
        // snapshot's reservation, so the aggregate budget cannot leak.
        defer {
            releaseWriteLive(snapshot.reservedWriteBytes)
            taskLock.lock()
            if pendingGen[snapshot.rawKey] == gen { pendingTasks.removeValue(forKey: snapshot.rawKey) }
            taskLock.unlock()
        }
        if !Task.isCancelled { await doWrite(snapshot) }
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
