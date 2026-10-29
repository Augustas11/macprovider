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
    static let recurrentABIEpoch = 2
    static let promptSnapshotABIEpoch = 3
    /// The REAL pinned mlx-swift-lm git revision (HIGH-8). Bump on any dependency
    /// change: `KVBuildIdentityDriftTests` parses Package.resolved and fails CI if
    /// this drifts from the resolved pin. A different pin ⇒ a different ABI ⇒ all
    /// prior ciphertext hard-misses (accepted — this tier is an optimization).
    static let mlxSwiftLMRevision = "921724503ab01a4590ac098c5a718dae708819cf"
    /// The mlx-swift release the pinned revision is based on. Package.resolved
    /// carries no version for a fork revision pin; when it does carry one,
    /// `KVBuildIdentityDriftTests` requires this to equal it.
    static let mlxSwiftVersion = "0.32.3"
    /// The REAL pinned mlx-swift git revision (HIGH-8). Same bump-on-change rule;
    /// `KVBuildIdentityDriftTests` checks it against Package.resolved.
    static let mlxSwiftRevision = "29d3b93375cc56cd2649b40e4310a8bc445e9874"
    /// The envelope `mlx_version` string (FR-KVP4(a)6). It carries the exact
    /// mlx-swift revision as well as the version, so a revision-only pin change
    /// (e.g. a fork moving its MLX core submodule) still hard-misses prior
    /// ciphertext without changing the closed manifest field set.
    static let mlxVersion = "\(mlxSwiftVersion)+\(mlxSwiftRevision)"
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
    private let memoryBudget: ConversationCacheMemoryBudget
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
    /// Process-local bounded write-volume admission. A one-minute fixed window caps
    /// deep-copied plaintext admitted to the writer at 1 GiB, preventing a stream of
    /// individually-valid commits from turning the cold tier into sustained disk I/O.
    /// Charging occurs before the copy and is intentionally not refunded on later
    /// displacement/failure: attempted churn still consumed the bounded work budget.
    private static let writeVolumeWindowSeconds: TimeInterval = 60
    private static let writeVolumeWindowBytes = 1024 * 1024 * 1024
    private var writeVolumeWindowStartedAt = Date()
    private var writeVolumeBytes = 0

    /// Item 3: atomically reserve `estimate` bytes against the aggregate write-live
    /// budget. Returns false (reject) when the running total plus `estimate` would
    /// exceed `writeStagingMaxBytes`. A successful reservation MUST be released exactly
    /// once via `releaseWriteLive`.
    func reserveWriteLive(_ estimate: Int, volumeBytes: Int? = nil) -> Bool {
        writeLiveLock.lock(); defer { writeLiveLock.unlock() }
        guard writeLiveBytes + estimate <= writeStagingMaxBytes else { return false }
        let volume = volumeBytes ?? estimate
        let now = Date()
        if now.timeIntervalSince(writeVolumeWindowStartedAt) >= Self.writeVolumeWindowSeconds {
            writeVolumeWindowStartedAt = now
            writeVolumeBytes = 0
        }
        guard volume <= Self.writeVolumeWindowBytes - writeVolumeBytes else { return false }
        writeLiveBytes += estimate
        writeVolumeBytes += volume
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
    private var recurrentGeometryTemplates: [String: [KVRecurrentLayerRecord]] = [:]

    /// CRITICAL-2 — the current key epoch, cached synchronously so `captureSnapshot`
    /// can stamp the epoch at commit time (NOT at persist time). Seeded + refreshed
    /// by the store's epoch observer (activation + rotation).
    private let epochLock = NSLock()
    private var cachedEpoch = 1

    /// FR-KVP9 single promotion: the store's slot ends when `read` returns, but MLX
    /// restoration still holds the decoded bytes. This slot spans read + restore so a
    /// concurrent candidate misses instead of overlapping that allocation.
    private let restoreLock = NSLock()
    private var restoreInFlight = false

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
         incarnation: String = UUID().uuidString,
         memoryBudget: ConversationCacheMemoryBudget = .system) {
        self.store = store
        self.namespaceID = namespaceID
        self.eligibilityTTLSeconds = eligibilityTTLSeconds
        self.writeStagingMaxBytes = writeStagingMaxBytes
        self.maxEntryBytes = maxEntryBytes
        self.stagingMaxBytes = stagingMaxBytes
        self.incarnation = incarnation
        self.memoryBudget = memoryBudget
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

    /// Seed the codec-v2 envelope from the actual warmed model caches. This reads
    /// only shapes/dtypes and retains no MLX arrays. Returns false when the topology
    /// is unsupported or recurrent state has not been populated by warmup.
    @discardableResult
    func seedTemplate(servedModelID: String, layers: [KVCache]) -> Bool {
        let recurrentIndices = layers.indices.filter { layers[$0] is ArraysCache }
        guard !recurrentIndices.isEmpty else { return false }
        let checkpoint = RecurrentStateCheckpoint(
            tokenCount: 1,
            states: Dictionary(uniqueKeysWithValues: recurrentIndices.compactMap { index in
                let state = layers[index].state
                return state.isEmpty ? nil : (index, state)
            }))
        guard let geometry = KVRecurrentCacheSerialization.geometry(
            layers: layers, checkpoints: [checkpoint]) else { return false }
        let template = geometry.layers.map { record in
            KVLayerGeometry(
                layerIndex: record.layerIndex, classID: record.classID,
                layoutVersion: record.layoutVersion, ndim: record.ndim,
                dims: record.dims, dtype: record.dtype,
                sequenceAxis: record.classID == "KVCacheSimple" ? max(0, record.ndim - 2) : 0)
        }
        templateLock.lock()
        if geometryTemplates[servedModelID] == nil {
            geometryTemplates[servedModelID] = template
            recurrentGeometryTemplates[servedModelID] = geometry.recurrent
        }
        templateLock.unlock()
        return true
    }

    /// codec-v3 constructor topology can be seeded from empty model caches: no
    /// GPU forward and no tensor copies are needed for first-restart promotion.
    @discardableResult
    func seedPromptSnapshotTemplate(servedModelID: String, layers: [KVCache]) -> Bool {
        guard let template = KVPromptSnapshotCodec.template(layers: layers) else { return false }
        templateLock.lock()
        geometryTemplates[servedModelID] = template
        recurrentGeometryTemplates.removeValue(forKey: servedModelID)
        templateLock.unlock()
        return true
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
    func promotionRuntime(
        identity: KVIdentityCore, template: [KVLayerGeometry], epoch: Int,
        recurrentLayouts: [KVRecurrentLayerRecord] = []
    ) -> KVRuntimeIdentity {
        let recurrent = !recurrentLayouts.isEmpty
        let prompt = template.first?.layoutVersion == 3
        return KVRuntimeIdentity(
            codecID: prompt ? KVDiskCacheFormat.promptSnapshotCodecID : (recurrent ? KVDiskCacheFormat.recurrentCodecID : KVDiskCacheFormat.codecID),
            recurrentLayerLayouts: recurrentLayouts,
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
            abiEpoch: prompt ? KVBuildIdentity.promptSnapshotABIEpoch : (recurrent ? KVBuildIdentity.recurrentABIEpoch : KVBuildIdentity.abiEpoch),
            mlxSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision,
            mlxVersion: KVBuildIdentity.mlxVersion,
            cacheClass: prompt ? KVDiskCacheFormat.promptSnapshotCacheClass : (recurrent ? KVDiskCacheFormat.recurrentCacheClass : (KVDiskCacheFormat.allowlistedCacheClasses.first ?? "KVCacheSimple")),
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
        guard identity.kvBits == nil, identity.kvGroupSize == nil,
              identity.kvQuantMode == nil, identity.kvQuantPolicy == nil else { return nil }
        templateLock.lock()
        let template = geometryTemplates[identity.servedModelID]
        let recurrentLayouts = recurrentGeometryTemplates[identity.servedModelID] ?? []
        templateLock.unlock()
        guard let template, !template.isEmpty else { return nil } // no live geometry to validate against
        restoreLock.lock()
        let claimed = !restoreInFlight
        if claimed { restoreInFlight = true }
        restoreLock.unlock()
        guard claimed else { return nil }
        defer { restoreLock.lock(); restoreInFlight = false; restoreLock.unlock() }
        guard memoryBudget.admitsStaging(bytes: stagingMaxBytes) else { return nil }
        let epoch = await store.currentEpoch
        let runtime = promotionRuntime(
            identity: identity, template: template, epoch: epoch,
            recurrentLayouts: recurrentLayouts)
        let result = try? await store.read(
            rawKey: conversationKey, runtime: runtime, nowMillis: Self.nowMillis(), emitHitEvent: false)
        guard let result, case let .hit(hit) = result else { return nil }
        let restored: ConversationCacheLayers
        if let prompt = hit.promptSnapshot {
            guard let snapshot = KVPromptSnapshotCodec.restore(prompt) else { return nil }
            memoryBudget.observe(layers: snapshot, tokenCount: hit.tokens.count)
            restored = snapshot
        } else if let decodedV2 = hit.decodedV2 {
            guard let recurrent = KVRecurrentCacheSerialization.restore(decodedV2) else { return nil }
            restored = recurrent
        } else {
            restored = ConversationCacheLayers(KVCacheSerialization.restore(hit.layers))
        }
        let prefix = (try? await store.currentIndex(rawKey: conversationKey)).flatMap { $0 }.map { String($0.prefix(8)) } ?? ""
        return ColdPromotionCandidate(
            layers: restored,
            canonicalTokens: hit.tokens,
            keyHashPrefix: prefix,
            bytesRead: hit.bytesRead,
            decryptMillis: hit.decryptMillis,
            peakStagingBytes: hit.peakStagingBytes,
            modelSHA256: identity.modelSHA256 ?? "",
            catalogRevision: identity.catalogRevision,
            kvBits: identity.kvBits,
            codecID: hit.promptSnapshot != nil ? KVDiskCacheFormat.promptSnapshotCodecID : (hit.decodedV2 == nil ? KVDiskCacheFormat.codecID : KVDiskCacheFormat.recurrentCodecID),
            createdAtMillis: hit.createdAtMillis,
            eligibleUntilMillis: hit.eligibleUntilMillis)
    }

    func finishPromotion(_ candidate: ColdPromotionCandidate, accepted: Bool, rejectionReason: String?) async {
        if accepted {
            await store.notePromotedHit(
                prefixHash: candidate.keyHashPrefix, bytesRead: candidate.bytesRead,
                decryptMillis: candidate.decryptMillis, peakStagingBytes: candidate.peakStagingBytes,
                modelSHA256: candidate.modelSHA256, catalogRevision: candidate.catalogRevision,
                kvBits: candidate.kvBits, codecID: candidate.codecID)
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
        guard identity.kvBits == nil, identity.kvGroupSize == nil,
              identity.kvQuantMode == nil, identity.kvQuantPolicy == nil else { return nil }
        // Only the v1-allowlisted unquantized class is serializable; any other
        // cache class skips persistence (byte-identical hot behavior for it).
        // MEDIUM-A/LOW/INFO: make that skip OBSERVABLE instead of a silent no-op. A
        // tier-eligible request can legitimately hold a non-KVCacheSimple cache —
        // model families that override `newCache` and ignore `maxKVSize` (gpt-oss,
        // gemma-4, nemotron), hot-cache reuse of a rotating cache seeded by a
        // relay/tier2 request, or mid-generation `kvBits` quantization. Emit a
        // `disk_write_skipped(unsupported_cache_class)` carrying the runtime class
        // name, then still fail safe to miss (return nil) as before.
        let prompt = layers.promptSnapshot
        let hasRecurrent = !prompt && ConversationCacheLayers.hasRecurrentLayers(layers.layers)
        let caches = layers.layers as? [KVCacheSimple]
        guard prompt || caches != nil || hasRecurrent else {
            // Report the FIRST layer that is NOT KVCacheSimple: for a heterogeneous
            // array whose layer 0 IS KVCacheSimple but a later layer fails the cast,
            // reporting layer 0's class would be misleadingly "KVCacheSimple". Fall
            // back to the first layer's class, or "empty".
            let className = (layers.layers.first(where: { !($0 is KVCacheSimple) }) ?? layers.layers.first)
                .map { String(describing: type(of: $0)) } ?? "empty"
            Task { [store] in await store.noteUnsupportedCacheClassSkipped(rawKey: conversationKey, cacheClass: className) }
            return nil
        }

        // HIGH-5 — estimate the decoded size from GEOMETRY (no byte copy) and skip an
        // oversized snapshot BEFORE the deep copy, so a huge cache can never be copied
        // only to be rejected by the store.
        let estimatedDecoded = prompt ? KVPromptSnapshotCodec.estimatedLength(layers, tokens: fullTokens) : hasRecurrent
            ? KVRecurrentCacheSerialization.estimatedDecodedLength(
                layers: layers.layers, checkpoints: layers.recurrentCheckpoints,
                tokenCount: fullTokens.count)
            : caches.flatMap { KVCacheSerialization.estimatedDecodedLength($0, tokenCount: fullTokens.count) }
        guard let estimatedDecoded else {
            FileHandle.standardError.write(Data("event=kv_disk_cache action=capture_skipped reason=estimate_unavailable token_count=\(fullTokens.count) layers=\(layers.layers.count)\n".utf8))
            return nil
        }
        // The store caps the on-disk size (decoded + chunk framing + manifest), so check
        // the same estimate here and never copy an entry the store will reject.
        guard estimatedDecoded <= maxEntryBytes,
              KVDiskCacheStore.estimateDiskBytes(decodedLength: estimatedDecoded) <= maxEntryBytes else {
            FileHandle.standardError.write(Data("event=kv_disk_cache action=capture_skipped reason=max_entry_bytes decoded=\(estimatedDecoded) cap=\(maxEntryBytes) knob=max_entry_bytes\n".utf8))
            Task { [store] in await store.noteWriteBudgetSkipped(rawKey: conversationKey) }
            return nil
        }
        // FR-KVP9 / write-side budget: an entry that could never be promoted MUST
        // NOT be written. Skip BEFORE the deep copy (SPEC-037 §3). The silent
        // KVS-01a drops were oversize prompts, not this ceiling on the 1600-token class.
        let (promotionEstimate, promotionOverflow) = estimatedDecoded.multipliedReportingOverflow(by: hasRecurrent || prompt ? 2 : 1)
        guard !promotionOverflow, promotionEstimate <= stagingMaxBytes else {
            FileHandle.standardError.write(Data("event=kv_disk_cache action=capture_skipped reason=exceeds_promotion_ceiling decoded=\(estimatedDecoded) required=\(promotionOverflow ? "overflow" : String(promotionEstimate)) cap=\(stagingMaxBytes) knob=staging_max_bytes\n".utf8))
            Task { [store] in await store.notePromotionCeilingSkipped(rawKey: conversationKey) }
            return nil
        }
        let writeFootprint = estimatedDecoded + activeSealFootprint(decoded: estimatedDecoded)
        guard writeFootprint <= writeStagingMaxBytes else {
            FileHandle.standardError.write(Data("event=kv_disk_cache action=capture_skipped reason=write_staging decoded=\(estimatedDecoded) footprint=\(writeFootprint) cap=\(writeStagingMaxBytes) knob=write_staging_max_bytes\n".utf8))
            Task { [store] in await store.noteWriteBudgetSkipped(rawKey: conversationKey) }
            return nil
        }

        // Item 3 (FR-KVP3): ONE aggregate write-live reservation held across the whole
        // persist lifetime. Reserve atomically BEFORE the deep copy; if it would exceed
        // the aggregate budget, REJECT (disk_write_skipped, detail=write_budget) rather
        // than copying. The reservation is NOT released here — it is carried with the
        // snapshot as a single-release token and released once by the persist Task
        // (completion, cancellation, or displacement). Multiple indices therefore cannot
        // each retain a ceiling-sized snapshot concurrently.
        guard memoryBudget.admitsStaging(bytes: writeFootprint),
              reserveWriteLive(writeFootprint, volumeBytes: estimatedDecoded) else {
            Task { [store] in await store.noteWriteBudgetSkipped(rawKey: conversationKey) }
            return nil
        }
        // From here, any early return before building the snapshot MUST release the
        // reservation (the snapshot that would otherwise carry it is not produced).
        var reservationHandedOff = false
        defer { if !reservationHandedOff { releaseWriteLive(writeFootprint) } }

        let payloads: [KVLayerPayload]
        let payloadsV2: [KVCacheLayerPayload]
        let checkpointPayloads: [KVRecurrentCheckpointPayload]
        let promptPayload: KVPromptSnapshotPayload?
        if prompt {
            guard let snapshot = KVPromptSnapshotCodec.capture(layers, tokens: fullTokens) else { return nil }
            promptPayload = snapshot
            payloads = []
            payloadsV2 = []
            checkpointPayloads = []
        } else if hasRecurrent {
            promptPayload = nil
            guard let recurrent = KVRecurrentCacheSerialization.snapshot(
                layers: layers.layers, checkpoints: layers.recurrentCheckpoints) else { return nil }
            payloads = []
            payloadsV2 = recurrent.layers
            checkpointPayloads = recurrent.checkpoints
        } else {
            promptPayload = nil
            guard let caches, let serialized = KVCacheSerialization.snapshotLayers(caches) else { return nil }
            payloads = serialized
            payloadsV2 = []
            checkpointPayloads = []
        }

        // Learn/refresh the live-model geometry template for future promotions.
        let template: [KVLayerGeometry]
        let recurrentTemplate: [KVRecurrentLayerRecord]
        if prompt, let topology = KVPromptSnapshotCodec.template(layers: layers.layers) {
            template = topology
            recurrentTemplate = []
        } else if hasRecurrent,
           let geometry = KVRecurrentCacheSerialization.geometry(
               layers: layers.layers, checkpoints: layers.recurrentCheckpoints) {
            template = geometry.layers.map { record in
                KVLayerGeometry(
                    layerIndex: record.layerIndex, classID: record.classID,
                    layoutVersion: record.layoutVersion, ndim: record.ndim,
                    dims: record.dims, dtype: record.dtype,
                    sequenceAxis: record.classID == "KVCacheSimple" ? max(0, record.ndim - 2) : 0)
            }
            recurrentTemplate = geometry.recurrent
        } else {
            template = Self.liveGeometryTemplate(fromPayloads: payloads, tokenCount: fullTokens.count)
            recurrentTemplate = []
        }
        templateLock.lock()
        geometryTemplates[identity.servedModelID] = template
        recurrentGeometryTemplates[identity.servedModelID] = recurrentTemplate
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
            codecID: prompt ? KVDiskCacheFormat.promptSnapshotCodecID : (hasRecurrent ? KVDiskCacheFormat.recurrentCodecID : KVDiskCacheFormat.codecID),
            requestModel: identity.requestModel,
            servedModelID: identity.servedModelID,
            modelSHA256: identity.modelSHA256 ?? "",
            catalogRevision: identity.catalogRevision,
            tokenizerID: identity.tokenizerID,
            tokenizerConfigSHA256: identity.tokenizerConfigSHA256,
            chatTemplateSHA256: identity.chatTemplateSHA256,
            abiEpoch: prompt ? KVBuildIdentity.promptSnapshotABIEpoch : (hasRecurrent ? KVBuildIdentity.recurrentABIEpoch : KVBuildIdentity.abiEpoch),
            mlxSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision,
            mlxVersion: KVBuildIdentity.mlxVersion,
            cacheClass: prompt ? KVDiskCacheFormat.promptSnapshotCacheClass : (hasRecurrent ? KVDiskCacheFormat.recurrentCacheClass : (payloads.first?.classID ?? "KVCacheSimple")),
            layerCount: prompt ? layers.layers.count : (hasRecurrent ? payloadsV2.count : payloads.count),
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
            layersV2: payloadsV2,
            recurrentCheckpoints: checkpointPayloads,
            promptSnapshot: promptPayload,
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
        let result = try? await store.writeColdSnapshot(
            rawKey: snapshot.rawKey, tokens: snapshot.tokens, layers: snapshot.layers,
            layersV2: snapshot.layersV2, recurrentCheckpoints: snapshot.recurrentCheckpoints,
            promptSnapshot: snapshot.promptSnapshot,
            identity: snapshot.identity, sampledPurgeGeneration: snapshot.sampledPurgeGeneration,
            commitSequence: snapshot.commitSequence,
            createdAtMillis: snapshot.createdAtMillis, eligibleUntilMillis: snapshot.eligibleUntilMillis,
            incarnation: snapshot.incarnation, nowMillis: Self.nowMillis())
        if case .committed? = result { await snapshot.onPersisted?() }
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
