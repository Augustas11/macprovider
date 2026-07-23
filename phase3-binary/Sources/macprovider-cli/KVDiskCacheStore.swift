/// KVDiskCacheStore — SPEC-037 disk-tier core: one actor per provider namespace.
///
/// Owns activation (flock single-writer with bounded-backoff retry + recovery),
/// the write path (immutable snapshot → budget/geometry/quota/floor checks → the
/// exact FR-KVP3 fsync commit protocol with a mutation-lane pre-publication
/// recheck), the read path (manifest load with fstat bounds → four-category
/// validation → chunk decrypt/verify under the staging budget → decoded payload),
/// the FR-KVP8 purge primitive (single-key tombstone-first 5-step ordering with
/// purge-generation fencing + DEK destruction; purge-all via epoch rotation),
/// LRU/retention eviction with DEK lifecycle, telemetry via the FR-KVP12 closed
/// reason-code enum + injectable event sink, and the inspection snapshot.
///
/// This is the stage 1-2 store core. ModelRuntime/ConversationCache integration,
/// config plumbing, CLI wiring, and the ingest-provenance synthetic gate land in a
/// later stage; the write path here accepts an already-built immutable snapshot and
/// the read path returns restored layer state for the caller to promote.
///
/// Reference: specs/SPEC-037-kv-survival-restart.md FR-KVP3/5/6/7/8/9/10/12, §5, §5a.

import CryptoKit
import Darwin
import Foundation
import MLX
import MLXLMCommon

// MARK: - Event sink (FR-KVP12)

/// One telemetry event. Keyed by the truncated index hash — never raw keys, raw
/// index values, or token content.
struct KVEvent: Sendable, Equatable {
    let code: KVReasonCode
    let detail: KVReasonDetail?
    let indexHashPrefix: String?
    let fields: [String: String]

    init(_ code: KVReasonCode, detail: KVReasonDetail? = nil,
         indexHashPrefix: String? = nil, fields: [String: String] = [:]) {
        self.code = code
        self.detail = detail
        self.indexHashPrefix = indexHashPrefix
        self.fields = fields
    }
}

protocol KVEventSink: Sendable {
    func emit(_ event: KVEvent)
}

/// Default sink: `conv_cache`-style structured stderr, matching the hot tier.
struct KVStderrEventSink: KVEventSink {
    func emit(_ event: KVEvent) {
        var line = "event=kv_disk_cache code=\(event.code.rawValue)"
        if let detail = event.detail { line += " detail=\(detail.rawValue)" }
        if let prefix = event.indexHashPrefix { line += " index_hash=\(prefix)" }
        for key in event.fields.keys.sorted() {
            line += " \(key)=\(event.fields[key] ?? "")"
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// Test sink collecting events in order.
final class KVRecordingEventSink: KVEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [KVEvent] = []
    var events: [KVEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func emit(_ event: KVEvent) { lock.lock(); _events.append(event); lock.unlock() }
    func codes(_ code: KVReasonCode) -> Int { events.filter { $0.code == code }.count }
    func reset() { lock.lock(); _events.removeAll(); lock.unlock() }
}

// MARK: - Failpoints (crash-consistency testing, AC-3/AC-4)

/// Ordering boundaries at which a test may inject a simulated crash (the injected
/// error aborts after the side effects performed up to that boundary, modeling a
/// power loss there). Default: no injection.
enum KVFailpoint: String, Sendable, CaseIterable {
    // write path (FR-KVP3 commit protocol)
    case afterDEKCreate
    case afterMkdirBeforeParentFsync
    case afterBlobFsync
    case afterEntryDirFsync
    case afterManifestTempFsync
    case insideMutationLaneBeforeRename
    case afterRenameBeforeDirFsync
    // single-key purge (FR-KVP8)
    case purgeAfterIncompleteTombstone
    case purgeAfterHighWatermark
    case purgeAfterDEKDestroy
    case purgeAfterUnlink
    // epoch rotation (FR-KVP6)
    case rotationAfterJournal
    case rotationAfterMasterCreate
    case rotationAfterEpochCommit
    case rotationAfterOldDelete
}

struct KVInjectedCrash: Error, Equatable {
    let point: KVFailpoint
}

// MARK: - Value types

/// Envelope identity a snapshot carries immutably from hot-tier commit (FR-KVP3).
struct KVWriteIdentity: Sendable, Equatable {
    let requestModel: String
    let servedModelID: String
    let modelSHA256: String
    let catalogRevision: String
    let tokenizerID: String
    let tokenizerConfigSHA256: String
    let chatTemplateSHA256: String
    let abiEpoch: Int
    let mlxSwiftLMRevision: String
    let mlxVersion: String
    let cacheClass: String
    let layerCount: Int
    let kvBits: Int?
    let kvGroupSize: Int?
    let kvQuantMode: String?
    let kvQuantPolicy: String?
    let decodePath: String
    /// Key epoch sampled at commit; the write is skipped if it is no longer current.
    let keyEpoch: Int
}

/// Immutable write snapshot captured synchronously at hot-tier `commit()` while the
/// per-key lease is held (FR-KVP3). Nothing observed after this instant may alter it.
struct KVWriteSnapshot: Sendable {
    /// Raw conversation key (used only in-process to compute/verify the index; never
    /// logged or persisted).
    let rawKey: String
    /// Precomputed HMAC index under `identity.keyEpoch`.
    let indexHMAC: String
    let tokens: [Int32]
    let layers: [KVLayerPayload]
    let identity: KVWriteIdentity
    /// High-watermark sampled at hot-lease acquisition (FR-KVP8 stamping rule).
    let sampledPurgeGeneration: Int
    /// Monotonic per-index commit sequence allocated under the hot lease.
    let commitSequence: Int
    let createdAtMillis: Int
    let eligibleUntilMillis: Int
    /// Creating write's incarnation identifier (ownership-checked DEK cleanup).
    let incarnation: String
}

/// A successful read: decoded tokens + restored per-layer state, plus telemetry.
struct KVReadHit: Sendable {
    let tokens: [Int32]
    let layers: [KVLayerPayload]
    let bytesRead: Int
    let decryptMillis: Int
    let peakStagingBytes: Int
}

enum KVReadResult: Sendable {
    case hit(KVReadHit)
    case miss(KVReasonCode, KVReasonDetail?)
    static func miss(_ code: KVReasonCode) -> KVReadResult { .miss(code, nil) }
}

enum KVWriteResult: Sendable, Equatable {
    case committed(generation: Int, commitSequence: Int)
    case skipped(KVReasonDetail)
}

enum KVPurgeResult: Sendable, Equatable {
    case ok(entriesRemoved: Int, bytesFreed: Int)
    case failed(KVReasonDetail)
}

/// FR-KVP12 inspection snapshot.
struct KVInspection: Sendable, Equatable {
    let namespaceID: String
    let bytesUsed: Int
    let entryCount: Int
    let maxBytes: Int
    let maxEntries: Int
    let freeSpaceHeadroom: Int
    let keyEpoch: Int
    let tombstoneCount: Int
    let keychainItemCount: Int
    let eligibilityTTLSeconds: Int
    let purgeHighWatermarkEntries: Int
    let counters: [String: Int]
}

// MARK: - Configuration

struct KVDiskCacheStoreConfig: Sendable {
    var root: URL
    var namespaceID: String
    var maxBytes: Int
    var maxEntries: Int
    var maxEntryBytes: Int
    var retentionSeconds: Int
    var stagingMaxBytes: Int            // read/promotion ceiling (≤ 256 MiB)
    var writeStagingMaxBytes: Int       // write/snapshot ceiling (≤ 1 GiB)
    var minFreeBytes: Int
    var promotionMaxSeconds: Int
    var eligibilityTTLSeconds: Int      // hot-tier TTL, for the inspection surface
    /// Non-evictable metadata reserve (FR-KVP7): default 4 MiB.
    var metadataReserveBytes: Int = 4 * 1024 * 1024
    /// Test hook: override host free-space (bytes). Nil ⇒ real statvfs.
    var freeSpaceOverride: Int? = nil

    static let promotionCeilingHardMax = 256 * 1024 * 1024   // FR-KVP9
    static let writeStagingHardMax = 1024 * 1024 * 1024      // FR-KVP3
}

// MARK: - Namespace metadata (control document, FR-KVP7)

/// The fsync-protected control document. Serialized as JSON, atomically replaced.
struct KVNamespaceMetadata: Sendable, Equatable {
    var providerNamespaceID: String
    var keyEpoch: Int
    var schemaID: String
    var codecID: String
    /// Purge-generation high-watermark map: index → generation. Capped at 4096.
    var purgeHighWatermarks: [String: Int]
    /// Monotonically non-decreasing wall-clock high-water, Unix ms.
    var clockHighWaterMillis: Int
    /// Open rotation-intent journal entry (nil when none).
    var rotationJournal: KVRotationJournal?

    static let maxBytes = 256 * 1024   // FR-KVP7 control-plane bound
    static let highWatermarkCap = 4096 // FR-KVP7

    func highWatermark(for index: String) -> Int { purgeHighWatermarks[index] ?? 0 }
}

struct KVRotationJournal: Sendable, Equatable {
    var from: Int
    var to: Int
    var phase: String   // "created" | "committed" | "old_deleted"
}

// MARK: - Tombstone (FR-KVP8)

/// Durable per-(epoch, index) purge record. Phase-aware: an incomplete tombstone
/// drives recovery to finish steps 2–4; a complete tombstone gates re-admission.
struct KVTombstone: Sendable, Equatable {
    var epoch: Int
    var index: String
    var purgeGeneration: Int
    var complete: Bool
}

// MARK: - Errors

enum KVStoreError: Error, Equatable {
    case lockUnavailable
    case quarantined(KVReasonDetail)
    case io(String)
}

// MARK: - Store actor

actor KVDiskCacheStore {
    private let config: KVDiskCacheStoreConfig
    private let keys: KVKeyManager
    private let sink: any KVEventSink
    private let naming: KVKeychainNaming

    /// Test-only failpoint injector: throws `KVInjectedCrash` at the named boundary.
    private var failpoint: (@Sendable (KVFailpoint) throws -> Void)?

    /// Test-only directory-fsync failure injection (HIGH-7): throw at the k-th
    /// (1-based) `fsyncDirectory` call to model a filesystem that fails to durably
    /// commit a directory entry. Nil ⇒ no injection.
    private var dirFsyncFailAt: Int?
    private var dirFsyncCount = 0

    // Activation state
    private var lockFD: Int32 = -1
    private var activated = false
    private var quarantined: KVReasonDetail?
    private var dormantForClock = false

    // In-memory control-plane mirror (authoritative on disk)
    private var metadata: KVNamespaceMetadata
    /// Per-index last committed generation and commit sequence.
    private var lastGeneration: [String: Int] = [:]
    private var lastCommitSequence: [String: Int] = [:]
    /// Running committed byte accounting (blobs + manifests of live entries).
    private var committedBytes = 0
    /// Live entry indices with their committed byte size and last-eligible-use ms.
    private var liveEntries: [String: KVLiveEntry] = [:]
    /// At most one promotion in flight namespace-wide (FR-KVP9 back-pressure).
    private var promotionInFlight = false
    /// Cumulative counters per reason code (inspection surface).
    private var counters: [String: Int] = [:]

    /// SPEC-037 FR-KVP8 hot-tier purge callbacks (CRITICAL-1). Set by the serve
    /// wiring once the hot `ConversationCache` is attached, so the purge path can
    /// drop the matching hot entry / invalidate outstanding leases BEFORE it
    /// unlinks the on-disk generation (single-key) or completes epoch rotation
    /// (purge-all). Nil while no hot tier is attached (control-plane-only process).
    private var hotPurgeSingle: (@Sendable (String) async -> Void)?
    private var hotPurgeAll: (@Sendable () async -> Void)?

    struct KVLiveEntry: Sendable, Equatable {
        var bytes: Int
        var lastUsedMillis: Int
        var generation: Int
    }

    // MARK: Init

    init(config: KVDiskCacheStoreConfig, keychain: any KVKeychain, sink: any KVEventSink = KVStderrEventSink()) {
        self.config = config
        self.keys = KVKeyManager(keychain: keychain, namespaceID: config.namespaceID)
        self.naming = KVKeychainNaming(namespaceID: config.namespaceID)
        self.sink = sink
        self.metadata = KVNamespaceMetadata(
            providerNamespaceID: config.namespaceID,
            keyEpoch: 1,
            schemaID: KVDiskCacheFormat.manifestSchemaID,
            codecID: KVDiskCacheFormat.codecID,
            purgeHighWatermarks: [:],
            clockHighWaterMillis: 0,
            rotationJournal: nil)
    }

    func setFailpoint(_ hook: (@Sendable (KVFailpoint) throws -> Void)?) {
        failpoint = hook
    }

    /// Test-only (HIGH-7): fail the k-th subsequent `fsyncDirectory` call. Resets the
    /// call counter. Pass nil to disable.
    func injectDirFsyncFailure(atCall k: Int?) {
        dirFsyncFailAt = k
        dirFsyncCount = 0
    }

    /// Wire the hot-tier purge callbacks (CRITICAL-1). `single` receives the raw
    /// conversation key (the hot tier keys on the trimmed raw key, not the HMAC
    /// index); `all` clears every hot entry and fences outstanding leases.
    func setHotPurgeHooks(
        single: (@Sendable (String) async -> Void)?,
        all: (@Sendable () async -> Void)?
    ) {
        hotPurgeSingle = single
        hotPurgeAll = all
    }

    private func crashIf(_ point: KVFailpoint) throws {
        try failpoint?(point)
    }

    // MARK: Paths

    private var namespaceDir: URL { config.root.appendingPathComponent(namespaceDigest, isDirectory: true) }
    private var entriesDir: URL { namespaceDir.appendingPathComponent("entries", isDirectory: true) }
    private var tombstonesDir: URL { namespaceDir.appendingPathComponent("tombstones", isDirectory: true) }
    private var metadataURL: URL { namespaceDir.appendingPathComponent("meta.json") }
    private var lockURL: URL {
        config.root.appendingPathComponent(".locks", isDirectory: true)
            .appendingPathComponent("\(namespaceDigest).lock")
    }
    private func entryDir(_ index: String) -> URL { entriesDir.appendingPathComponent(index, isDirectory: true) }

    /// Stable digest of the namespace ID for on-disk naming (hides the raw provider ID).
    private var namespaceDigest: String {
        let d = SHA256.hash(data: Data(config.namespaceID.utf8))
        return d.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Activation (FR-KVP7)

    /// Acquire the single-writer lock (bounded-backoff retry) and run all recovery.
    /// Returns true on activation; false when the lock stays unavailable (transient
    /// dormancy — the caller retries opportunistically). Throws on quarantine.
    @discardableResult
    func activate(retryDeadline: Date = Date().addingTimeInterval(2)) throws -> Bool {
        if activated { return true }
        if let detail = quarantined { throw KVStoreError.quarantined(detail) }

        try ensureDirectories()
        guard try acquireLock(deadline: retryDeadline) else { return false }

        do {
            try loadMetadata()
            // Bootstrap the current-epoch master on first activation. Keychain
            // unavailability here is tolerated (tier stays dormant, not quarantined).
            do {
                try ensureEpochMaster()
            } catch let e as KVKeychainError where isUnavailable(e) {
                // dormant for keychain; reads/writes will surface keychain_unavailable
            }
            try recoverRotationJournal()
            try recoverTombstones()
            try sweepOrphansAndAccount()
            activated = true
            notifyEpoch()
            return true
        } catch let crash as KVInjectedCrash {
            throw crash
        } catch {
            releaseLock()
            quarantine(.ioError)
            throw KVStoreError.quarantined(.ioError)
        }
    }

    /// Release the lock and mark inactive (graceful shutdown / test teardown).
    func deactivate() {
        releaseLock()
        activated = false
    }

    private func ensureEpochMaster() throws {
        if try keys.epochMaster(epoch: metadata.keyEpoch) == nil {
            try keys.createEpochMaster(epoch: metadata.keyEpoch, incarnation: "bootstrap-\(UUID().uuidString)")
        }
    }

    /// Compute the current-epoch HMAC index for a raw conversation key. Returns nil
    /// when the epoch master is unavailable (dormancy). Callers building a write
    /// snapshot use this to stamp `indexHMAC`; never logs the raw key.
    func currentIndex(rawKey: String) throws -> String? {
        try keys.computeIndex(rawKey: rawKey, epoch: metadata.keyEpoch)
    }

    /// Current key epoch (for snapshot identity + tests).
    var currentEpoch: Int { metadata.keyEpoch }

    /// Last published commit sequence for a raw key's current-epoch index (0 when
    /// none / keychain unavailable). Seeds the adapter's synchronous per-index
    /// commit-sequence counter so post-restart writes are not rejected as stale
    /// (CRITICAL-2). Never logs the raw key.
    func lastPublishedCommitSequence(rawKey: String) -> Int {
        guard let index = try? currentIndex(rawKey: rawKey) else { return 0 }
        return lastCommitSequence[index] ?? 0
    }

    /// Observer invoked (synchronously, on the actor) whenever the current key epoch
    /// is established or changes, so the cold-tier adapter can cache it for the
    /// synchronous `captureSnapshot` epoch stamp (CRITICAL-2). Called at activation
    /// and after every rotation phase that commits a new epoch.
    private var epochObserver: (@Sendable (Int) -> Void)?
    func setEpochObserver(_ observer: (@Sendable (Int) -> Void)?) {
        epochObserver = observer
        observer?(metadata.keyEpoch)
    }
    private func notifyEpoch() { epochObserver?(metadata.keyEpoch) }

    /// Current live purge-generation high-watermark for a raw key's index.
    func highWatermark(rawKey: String) throws -> Int {
        guard let index = try currentIndex(rawKey: rawKey) else { return 0 }
        return metadata.highWatermark(for: index)
    }

    private func ensureDirectories() throws {
        try createDir(config.root)
        try createDir(config.root.appendingPathComponent(".locks", isDirectory: true))
        try createDir(namespaceDir)
        try createDir(entriesDir)
        try createDir(tombstonesDir)
    }

    private func acquireLock(deadline: Date) throws -> Bool {
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw KVStoreError.io("lock open failed errno=\(errno)") }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0 else {
            close(fd)
            throw KVStoreError.io("lock inode unsafe")
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                close(fd)
                throw KVStoreError.io("flock failed errno=\(errno)")
            }
            if Date() >= deadline {
                close(fd)
                return false   // transient dormancy
            }
            usleep(20_000)
        }
        lockFD = fd
        return true
    }

    private func releaseLock() {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }

    // MARK: - Metadata persistence (fsync + atomic rename)

    private func loadMetadata() throws {
        guard fileExists(metadataURL) else {
            try persistMetadata()   // first activation writes the initial doc
            return
        }
        let data = try readBounded(metadataURL, maxBytes: KVNamespaceMetadata.maxBytes)
        guard let parsed = KVMetadataCodec.decode(data) else {
            quarantine(.ioError)
            throw KVStoreError.quarantined(.ioError)
        }
        metadata = parsed
    }

    private func persistMetadata() throws {
        let data = try KVMetadataCodec.encode(metadata)
        guard data.count <= KVNamespaceMetadata.maxBytes else {
            throw KVStoreError.io("namespace metadata exceeds 256 KiB")
        }
        try writeFileAtomic(data, to: metadataURL)
    }

    // MARK: - Clock high-water (FR-KVP10)

    /// Advance the persisted wall-clock high-water to `nowMillis` (durable, fsync)
    /// before any eligibility decision is acted on. Returns false ⇒ clock-rollback
    /// dormancy (current wall-clock is below the mark).
    private func advanceClock(nowMillis: Int) throws -> Bool {
        if nowMillis < metadata.clockHighWaterMillis {
            dormantForClock = true
            return false
        }
        dormantForClock = false
        if nowMillis > metadata.clockHighWaterMillis {
            metadata.clockHighWaterMillis = nowMillis
            try persistMetadata()
        }
        return true
    }

    // MARK: - Write path (FR-KVP3)

    /// Persist an immutable snapshot. Never blocks or fails the hot commit; returns a
    /// typed skip reason or the committed generation. Requires activation.
    @discardableResult
    func write(_ snapshot: KVWriteSnapshot, nowMillis: Int) throws -> KVWriteResult {
        guard activated else { return skip(.ioError, snapshot) }
        if let detail = quarantined { return skip(detail, snapshot) }

        // Clock integrity: a rollback below the high-water skips writes.
        guard try advanceClock(nowMillis: nowMillis) else { return skip(.clockRollback, snapshot) }

        // Key epoch must still be current (a warm-swap/rotation after commit skips).
        guard snapshot.identity.keyEpoch == metadata.keyEpoch else { return skip(.fenceLost, snapshot) }

        // Allowlist check.
        guard KVDiskCacheFormat.allowlistedCacheClasses.contains(snapshot.identity.cacheClass) else {
            return skip(.allowlistRemoved, snapshot)
        }

        // Geometry pre-check: the §5a decoded_length equation (same as read-side).
        let geometry = snapshot.layers.map {
            KVDiskCacheFormat.LayerGeometryInput(classID: $0.classID, ndim: $0.ndim, dims: $0.dims, dtype: $0.dtype)
        }
        guard let decodedLength = KVDiskCacheFormat.decodedLength(tokenCount: snapshot.tokens.count, layers: geometry) else {
            return skip(.geometryUnvalidated, snapshot)
        }
        // An entry that could never be promoted MUST NOT be written.
        guard decodedLength <= config.stagingMaxBytes, decodedLength <= KVDiskCacheStoreConfig.promotionCeilingHardMax else {
            return skip(.exceedsPromotionCeiling, snapshot)
        }
        // Write-live budget (RAM-DoS bound).
        guard decodedLength <= config.writeStagingMaxBytes else { return skip(.exceedsPromotionCeiling, snapshot) }
        guard decodedLength <= config.maxEntryBytes else { return skip(.perEntryCap, snapshot) }

        // Estimate on-disk size (ciphertext ≈ plaintext + per-chunk framing/tag).
        let estimatedDiskBytes = estimateDiskBytes(decodedLength: decodedLength)
        guard estimatedDiskBytes <= config.maxEntryBytes else { return skip(.perEntryCap, snapshot) }

        // Free-space floor.
        guard hostFreeBytes() - estimatedDiskBytes >= config.minFreeBytes else {
            return skip(.freeSpaceFloor, snapshot)
        }

        // Quota reservation (evict LRU to fund, honoring the metadata reserve).
        guard try reserveQuota(estimatedDiskBytes, nowMillis: nowMillis) else {
            return skip(.quotaExhausted, snapshot)
        }

        // Write ordering: drop a stale snapshot (commit sequence ≤ last published).
        if let last = lastCommitSequence[snapshot.indexHMAC], snapshot.commitSequence <= last {
            committedBytes -= estimatedDiskBytes   // release the reservation
            return skip(.snapshotDisplaced, snapshot)
        }

        do {
            let result = try commitEntry(snapshot, decodedLength: decodedLength, nowMillis: nowMillis)
            return result
        } catch let crash as KVInjectedCrash {
            throw crash
        } catch let e as KVKeychainError where isUnavailable(e) {
            committedBytes -= estimatedDiskBytes
            return skip(.dekCreateFailed, snapshot)
        } catch {
            committedBytes -= estimatedDiskBytes
            return skip(.ioError, snapshot)
        }
    }

    private func commitEntry(_ snapshot: KVWriteSnapshot, decodedLength: Int, nowMillis: Int) throws -> KVWriteResult {
        let writeStarted = Date()
        let index = snapshot.indexHMAC
        let dir = entryDir(index)
        let newEntry = !fileExists(dir)

        // DEK: ONE shared entry DEK across generations (HIGH-4). A replacement write
        // REUSES the committed generation's DEK — creating a fresh DEK would
        // delete-then-add, destroying the previous generation's key, so a crash
        // before the new manifest rename would leave the still-committed generation
        // undecryptable. A fresh DEK is created only when none exists (first write,
        // or after a purge/eviction crypto-shredded it).
        let dek: Data
        let createdFreshDEK: Bool
        if let existing = try keys.entryDEK(epoch: metadata.keyEpoch, index: index) {
            dek = existing
            createdFreshDEK = false
        } else {
            dek = try keys.createEntryDEK(epoch: metadata.keyEpoch, index: index, incarnation: snapshot.incarnation)
            createdFreshDEK = true
        }
        try crashIf(.afterDEKCreate)

        // Allocate the generation (max committed + 1).
        let generation = (lastGeneration[index] ?? 0) + 1

        do {
            if newEntry {
                try createDir(dir)
                try crashIf(.afterMkdirBeforeParentFsync)
                try fsyncDirectory(entriesDir)
            }

            // Build plaintext payload, chunk it, and seal each chunk under the DEK.
            let plaintext = try KVPayloadCodec.encode(tokens: snapshot.tokens, layers: snapshot.layers)
            precondition(plaintext.count == decodedLength, "codec length must equal decoded_length")
            let chunkSize = max(1, min(plaintext.count, KVDiskCacheFormat.maxChunkCiphertextBytes))
            var plaintextChunks: [Data] = []
            var pos = 0
            while pos < plaintext.count {
                let end = min(pos + chunkSize, plaintext.count)
                plaintextChunks.append(plaintext.subdata(in: pos ..< end))
                pos = end
            }
            if plaintextChunks.isEmpty { plaintextChunks.append(Data()) }

            // Chunk table is known pre-encryption (GCM preserves length). Build it, then
            // finalize the manifest sans blob hash to derive the AAD.
            var chunkRecords: [KVChunkRecord] = []
            var nonces: [Data] = []
            for (ordinal, chunk) in plaintextChunks.enumerated() {
                let nonce = KVKeyManager.randomBytes(KVDiskCacheFormat.chunkNonceBytes)
                nonces.append(nonce)
                chunkRecords.append(KVChunkRecord(ordinal: ordinal, ctLength: chunk.count, nonce: nonce))
            }
            // blob_length is AAD-bound (only blob_sha256 is omitted from the AAD), and
            // it is fully known before encryption: GCM ciphertext length == plaintext
            // length, so each frame is (ct_length + 40) bytes. Compute it up front so
            // the AAD projection is stable between seal and read.
            let frameOverhead = 4 + 4 + 4 + KVDiskCacheFormat.chunkNonceBytes + KVDiskCacheFormat.gcmTagBytes
            let blobLength = plaintextChunks.reduce(0) { $0 + $1.count + frameOverhead }
            var manifest = buildManifest(
                snapshot: snapshot, generation: generation, decodedLength: decodedLength,
                chunks: chunkRecords, blobLength: blobLength, blobSHA256: String(repeating: "0", count: 64))

            // Seal each chunk with its nonce + the AAD projection, assemble the blob.
            var blob = Data()
            for (ordinal, chunk) in plaintextChunks.enumerated() {
                let aad = try manifest.aad(ordinal: ordinal)
                let sealed = try KVChunkCryptoSealFixedNonce(plaintext: chunk, dek: dek, aad: aad, nonce: nonces[ordinal])
                let frame = try KVChunkFrame.encode(ordinal: ordinal, nonce: nonces[ordinal],
                                                    ciphertext: sealed.ciphertext, tag: sealed.tag)
                blob.append(frame)
            }
            precondition(blob.count == blobLength, "blob length must match the pre-encryption estimate")
            let blobSHA = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
            // Only blob_sha256 changes (out of the AAD), so the sealed AAD stays valid.
            manifest = buildManifest(
                snapshot: snapshot, generation: generation, decodedLength: decodedLength,
                chunks: chunkRecords, blobLength: blobLength, blobSHA256: blobSHA)

            // Commit protocol: blob (O_EXCL) → fsync → entry dir fsync.
            let blobURL = dir.appendingPathComponent("gen-\(generation).blob")
            try writeFileExclusive(blob, to: blobURL)
            try crashIf(.afterBlobFsync)
            try fsyncDirectory(dir)
            try crashIf(.afterEntryDirFsync)

            // Manifest → unique temp → fsync.
            let manifestData = try KVManifestCodec.encode(manifest)
            guard manifestData.count <= KVDiskCacheFormat.manifestMaxBytes else {
                throw KVStoreError.io("manifest exceeds cap")
            }
            let tempURL = dir.appendingPathComponent("manifest.json.tmp.\(UUID().uuidString)")
            try writeFileExclusive(manifestData, to: tempURL)
            try crashIf(.afterManifestTempFsync)

            // Mutation lane: re-verify epoch/fence/newest, then atomic rename.
            try crashIf(.insideMutationLaneBeforeRename)
            guard metadata.keyEpoch == snapshot.identity.keyEpoch else {
                try? FileManager.default.removeItem(at: tempURL)
                try? FileManager.default.removeItem(at: blobURL)
                return skip(.fenceLost, snapshot)
            }
            guard snapshot.sampledPurgeGeneration >= metadata.highWatermark(for: index) else {
                try? FileManager.default.removeItem(at: tempURL)
                try? FileManager.default.removeItem(at: blobURL)
                return skip(.fenceLost, snapshot)
            }
            if let last = lastCommitSequence[index], snapshot.commitSequence <= last {
                try? FileManager.default.removeItem(at: tempURL)
                try? FileManager.default.removeItem(at: blobURL)
                return skip(.snapshotDisplaced, snapshot)
            }
            let manifestURL = dir.appendingPathComponent("manifest.json")
            // Reclaim the superseded generation's bytes (compaction retains the DEK).
            let previousBytes = liveEntries[index]?.bytes ?? 0
            let previousGen = lastGeneration[index]
            guard rename(tempURL.path, manifestURL.path) == 0 else {
                throw KVStoreError.io("manifest rename failed errno=\(errno)")
            }
            try crashIf(.afterRenameBeforeDirFsync)
            try fsyncDirectory(dir)

            // Delete the superseded blob (compaction), keep the shared DEK.
            if let previousGen, previousGen != generation {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("gen-\(previousGen).blob"))
            }

            // Publish in-memory state.
            let entryBytes = blob.count + manifestData.count
            committedBytes += entryBytes - previousBytes
            liveEntries[index] = KVLiveEntry(bytes: entryBytes, lastUsedMillis: nowMillis, generation: generation)
            lastGeneration[index] = generation
            lastCommitSequence[index] = snapshot.commitSequence

            emit(.diskWriteCommitted, indexHashPrefix: indexPrefix(index), fields: [
                "generation": "\(generation)",
                "commit_sequence": "\(snapshot.commitSequence)",
                "serialized_bytes": "\(blob.count)",
                "write_ms": "\(Int(Date().timeIntervalSince(writeStarted) * 1000))",
            ])
            return .committed(generation: generation, commitSequence: snapshot.commitSequence)
        } catch let crash as KVInjectedCrash {
            // Simulated crash: leave on-disk side effects; abort-path DEK cleanup is
            // ownership-checked so a delayed abort cannot delete a re-created DEK.
            throw crash
        } catch {
            // Real failure: ownership-checked abort deletion — ONLY when THIS write
            // created the DEK fresh (HIGH-4). A reused DEK backs a still-committed
            // prior generation and must survive this write's failure.
            if createdFreshDEK {
                try? keys.destroyEntryDEKIfOwnedBy(epoch: metadata.keyEpoch, index: index, incarnation: snapshot.incarnation)
            }
            throw error
        }
    }

    private func buildManifest(snapshot: KVWriteSnapshot, generation: Int, decodedLength: Int,
                               chunks: [KVChunkRecord], blobLength: Int, blobSHA256: String) -> KVDiskManifest {
        let id = snapshot.identity
        let layerRecords = snapshot.layers.map {
            KVLayerRecord(layerIndex: $0.layerIndex, classID: $0.classID, layoutVersion: layoutVersion(for: $0),
                          ndim: $0.ndim, dims: $0.dims, dtype: $0.dtype)
        }
        return KVDiskManifest(
            schemaID: KVDiskCacheFormat.manifestSchemaID,
            codecID: KVDiskCacheFormat.codecID,
            namespaceID: config.namespaceID,
            keyEpoch: metadata.keyEpoch,
            indexHMAC: snapshot.indexHMAC,
            generation: generation,
            commitSequence: snapshot.commitSequence,
            purgeGeneration: snapshot.sampledPurgeGeneration,
            requestModel: id.requestModel,
            servedModelID: id.servedModelID,
            modelSHA256: id.modelSHA256,
            catalogRevision: id.catalogRevision,
            tokenizerID: id.tokenizerID,
            tokenizerConfigSHA256: id.tokenizerConfigSHA256,
            chatTemplateSHA256: id.chatTemplateSHA256,
            abiEpoch: id.abiEpoch,
            mlxSwiftLMRevision: id.mlxSwiftLMRevision,
            mlxVersion: id.mlxVersion,
            cacheClass: id.cacheClass,
            layerCount: id.layerCount,
            layers: layerRecords,
            kvBits: id.kvBits,
            kvGroupSize: id.kvGroupSize,
            kvQuantMode: id.kvQuantMode,
            kvQuantPolicy: id.kvQuantPolicy,
            decodePath: id.decodePath,
            tokenCount: snapshot.tokens.count,
            createdAtMillis: snapshot.createdAtMillis,
            eligibleUntilMillis: snapshot.eligibleUntilMillis,
            decodedLength: decodedLength,
            chunks: chunks,
            blobLength: blobLength,
            blobSHA256: blobSHA256)
    }

    /// Per-layer layout version. v1 fixes it to 1 for the allowlisted class; the
    /// caller may thread a distinct value once layouts diverge (ABI-epoch bump).
    private func layoutVersion(for layer: KVLayerPayload) -> Int { 1 }

    private func estimateDiskBytes(decodedLength: Int) -> Int {
        // ciphertext == plaintext length; framing per chunk = 4+4+4+12+16 = 40.
        let chunks = max(1, (decodedLength + KVDiskCacheFormat.maxChunkCiphertextBytes - 1) / KVDiskCacheFormat.maxChunkCiphertextBytes)
        return decodedLength + chunks * 40 + KVDiskCacheFormat.manifestMaxBytes
    }

    // MARK: - Read path (FR-KVP4/5/9)

    /// Attempt a cold hit for `rawKey` against the live runtime identity. Returns the
    /// decoded tokens + restored layer state, or a typed miss reason. `runtime`
    /// carries every live-identity input (a nil `modelSHA256` ⇒ identity unavailable).
    /// - Parameter emitHitEvent: when false, a successful restore returns the hit
    ///   WITHOUT emitting `disk_hit`; the caller (the runtime promotion adapter)
    ///   emits exactly one terminal code after the hot predicate accepts/rejects
    ///   the restored layers (§5 row 25). Miss codes are always emitted here.
    func read(rawKey: String, runtime: KVRuntimeIdentity, nowMillis: Int, emitHitEvent: Bool = true) throws -> KVReadResult {
        guard activated else { return .miss(.diskMissIO, .ioError) }
        if let detail = quarantined { return .miss(.diskMissIO, detail) }

        // Clock-rollback dormancy (FR-KVP10).
        guard try advanceClock(nowMillis: nowMillis) else {
            emitMiss(.diskMissIO, detail: .clockRollback)
            return .miss(.diskMissIO, .clockRollback)
        }

        // Keychain / index availability. A missing epoch master ⇒ dormancy.
        let index: String
        do {
            guard let computed = try keys.computeIndex(rawKey: rawKey, epoch: metadata.keyEpoch) else {
                return .miss(.diskMissIO, .keychainUnavailable)
            }
            index = computed
        } catch let e as KVKeychainError where isUnavailable(e) {
            return .miss(.diskMissIO, .keychainUnavailable)
        }

        // Back-pressure: at most one promotion in flight namespace-wide.
        guard !promotionInFlight else { return .miss(.diskMissBusy) }

        let prefix = indexPrefix(index)
        let dir = entryDir(index)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard fileExists(manifestURL) else { return .miss(.diskMissAbsent) }

        // Manifest load bounded by fstat (§5a) → structural parse (corrupt).
        let manifestData: Data
        do {
            manifestData = try readBounded(manifestURL, maxBytes: KVDiskCacheFormat.manifestMaxBytes)
        } catch {
            emitMiss(.diskMissIO, detail: .ioError, prefix: prefix); return .miss(.diskMissIO, .ioError)
        }
        let manifest: KVDiskManifest
        do {
            manifest = try KVManifestCodec.decode(manifestData, maxBlobBytes: config.maxEntryBytes)
        } catch {
            emitMiss(.diskMissCorrupt, prefix: prefix); return .miss(.diskMissCorrupt)
        }

        // Four-category envelope validation completes before any payload byte.
        let runtimeForFence = KVRuntimeIdentity(
            namespaceID: runtime.namespaceID, keyEpoch: runtime.keyEpoch, indexHMAC: index,
            requestModel: runtime.requestModel, servedModelID: runtime.servedModelID, modelSHA256: runtime.modelSHA256,
            catalogRevision: runtime.catalogRevision, tokenizerID: runtime.tokenizerID,
            tokenizerConfigSHA256: runtime.tokenizerConfigSHA256, chatTemplateSHA256: runtime.chatTemplateSHA256,
            abiEpoch: runtime.abiEpoch, mlxSwiftLMRevision: runtime.mlxSwiftLMRevision, mlxVersion: runtime.mlxVersion,
            cacheClass: runtime.cacheClass, layerCount: runtime.layerCount, layers: runtime.layers,
            kvBits: runtime.kvBits, kvGroupSize: runtime.kvGroupSize, kvQuantMode: runtime.kvQuantMode,
            kvQuantPolicy: runtime.kvQuantPolicy, decodePath: runtime.decodePath,
            liveHighWatermark: metadata.highWatermark(for: index))
        switch KVEnvelopeValidator.validate(manifest, runtime: runtimeForFence, nowMillis: nowMillis) {
        case .miss(let code, let detail):
            emitMiss(code, detail: detail, prefix: prefix)
            return .miss(code, detail)
        case .ok:
            break
        }

        // Entry DEK: absent/destroyed ⇒ tombstoned (revocation authority, FR-KVP8).
        let dek: Data
        do {
            guard let loaded = try keys.entryDEK(epoch: metadata.keyEpoch, index: index) else {
                emitMiss(.diskMissTombstoned, detail: .dekDestroyed, prefix: prefix)
                return .miss(.diskMissTombstoned, .dekDestroyed)
            }
            dek = loaded
        } catch let e as KVKeychainError where isUnavailable(e) {
            emitMiss(.diskMissIO, detail: .keychainUnavailable, prefix: prefix)
            return .miss(.diskMissIO, .keychainUnavailable)
        }

        // Promotion staging ceiling (declared decoded size).
        guard manifest.decodedLength <= config.stagingMaxBytes else {
            emitMiss(.diskMissBudget, detail: .exceedsPromotionCeiling, prefix: prefix)
            return .miss(.diskMissBudget, .exceedsPromotionCeiling)
        }

        promotionInFlight = true
        defer { promotionInFlight = false }
        let deadline = Date().addingTimeInterval(TimeInterval(config.promotionMaxSeconds))
        let started = Date()

        // Blob load + structural SHA-256 fast-fail (FR-KVP4c) before AEAD.
        let blobURL = dir.appendingPathComponent("gen-\(manifest.generation).blob")
        let blob: Data
        do {
            blob = try readBounded(blobURL, maxBytes: manifest.blobLength)
        } catch {
            emitMiss(.diskMissIO, detail: .ioError, prefix: prefix); return .miss(.diskMissIO, .ioError)
        }
        guard blob.count == manifest.blobLength else {
            emitMiss(.diskMissCorrupt, prefix: prefix); return .miss(.diskMissCorrupt)
        }
        let actualSHA = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        guard actualSHA == manifest.blobSHA256 else {
            emitMiss(.diskMissCorrupt, prefix: prefix); return .miss(.diskMissCorrupt)
        }

        // Frame decode + per-chunk AEAD open under the AAD projection.
        let frames: [KVParsedFrame]
        do {
            frames = try KVChunkFrame.decodeBlob(blob, chunkTable: manifest.chunks)
        } catch {
            emitMiss(.diskMissCorrupt, prefix: prefix); return .miss(.diskMissCorrupt)
        }
        var plaintext = Data()
        for frame in frames {
            if Date() > deadline {
                emitMiss(.diskMissIO, detail: .promotionDeadline, prefix: prefix)
                return .miss(.diskMissIO, .promotionDeadline)
            }
            let aad: Data
            do { aad = try manifest.aad(ordinal: frame.ordinal) } catch {
                emitMiss(.diskMissCorrupt, prefix: prefix); return .miss(.diskMissCorrupt)
            }
            do {
                let opened = try KVChunkCrypto.open(nonce: frame.nonce, ciphertext: frame.ciphertext,
                                                    tag: frame.tag, dek: dek, aad: aad)
                plaintext.append(opened)
            } catch {
                emitMiss(.diskMissCorrupt, prefix: prefix); return .miss(.diskMissCorrupt)
            }
            guard plaintext.count <= config.stagingMaxBytes else {
                emitMiss(.diskMissBudget, detail: .exceedsPromotionCeiling, prefix: prefix)
                return .miss(.diskMissBudget, .exceedsPromotionCeiling)
            }
        }

        // Payload decode with the exact self-delimiting length check.
        let decoded: KVDecodedPayload
        do {
            decoded = try KVPayloadCodec.decode(plaintext, expectedDecodedLength: manifest.decodedLength,
                                                layerCount: manifest.layerCount)
        } catch {
            emitMiss(.diskMissCorrupt, prefix: prefix); return .miss(.diskMissCorrupt)
        }
        guard decoded.tokens.count == manifest.tokenCount else {
            emitMiss(.diskMissCorrupt, prefix: prefix); return .miss(.diskMissCorrupt)
        }

        // Update LRU last-eligible-use.
        if var entry = liveEntries[index] { entry.lastUsedMillis = nowMillis; liveEntries[index] = entry }

        let elapsedMillis = Int(Date().timeIntervalSince(started) * 1000)
        if emitHitEvent {
            emit(.diskHit, indexHashPrefix: prefix, fields: [
                "restore_bytes": "\(blob.count)",
                "decrypt_ms": "\(elapsedMillis)",
                "peak_staging_bytes": "\(plaintext.count)",
            ])
        }
        return .hit(KVReadHit(tokens: decoded.tokens, layers: decoded.layers,
                              bytesRead: blob.count, decryptMillis: elapsedMillis,
                              peakStagingBytes: plaintext.count))
    }

    /// Runtime cold-tier adapter entry point (FR-KVP3): compute the HMAC index and
    /// allocate a restart-safe monotonic commit sequence (recovered at activation
    /// as max-committed+1), then write — all inside the actor so concurrent commits
    /// for one key cannot collide on a sequence. The synchronous deep copy of
    /// tensor bytes already happened at hot-tier commit (`captureSnapshot`).
    func writeColdSnapshot(
        rawKey: String, tokens: [Int32], layers: [KVLayerPayload], identity: KVWriteIdentity,
        sampledPurgeGeneration: Int, commitSequence: Int, createdAtMillis: Int, eligibleUntilMillis: Int,
        incarnation: String, nowMillis: Int
    ) throws -> KVWriteResult {
        guard activated else { return .skipped(.ioError) }
        if let detail = quarantined { return .skipped(detail) }
        // CRITICAL-2: `identity.keyEpoch` is the epoch captured synchronously at
        // hot-tier commit (NOT the current epoch). A queued pre-purge-all snapshot
        // whose captured epoch no longer matches is rejected here, so it can never
        // be restamped into the new epoch and survive crypto-shredding.
        guard identity.keyEpoch == metadata.keyEpoch else { return .skipped(.fenceLost) }
        guard let index = try currentIndex(rawKey: rawKey) else {
            emit(.diskWriteSkipped, detail: .keychainUnavailable)
            return .skipped(.keychainUnavailable)
        }
        // The commit sequence is allocated under the hot lease (adapter-held per-index
        // counter). A sequence not newer than the last published one is dropped by
        // `write()` as `snapshot_displaced`, so two commits publish in commit order
        // regardless of persist-Task scheduling.
        let snapshot = KVWriteSnapshot(
            rawKey: rawKey, indexHMAC: index, tokens: tokens, layers: layers, identity: identity,
            sampledPurgeGeneration: sampledPurgeGeneration, commitSequence: commitSequence,
            createdAtMillis: createdAtMillis, eligibleUntilMillis: eligibleUntilMillis, incarnation: incarnation)
        return try write(snapshot, nowMillis: nowMillis)
    }

    /// Emit `disk_hit` for a promotion the hot predicate accepted (§5 row 25). Kept
    /// separate from `read` so the terminal code is emitted once, after the hot
    /// tier confirms reuse.
    func notePromotedHit(prefixHash: String, bytesRead: Int, decryptMillis: Int, peakStagingBytes: Int) {
        emit(.diskHit, indexHashPrefix: prefixHash, fields: [
            "restore_bytes": "\(bytesRead)",
            "decrypt_ms": "\(decryptMillis)",
            "peak_staging_bytes": "\(peakStagingBytes)",
        ])
    }

    /// Emit `disk_promote_rejected` when the hot predicate rejected restored layers.
    func notePromoteRejected(prefixHash: String, reason: String) {
        emit(.diskPromoteRejected, indexHashPrefix: prefixHash, fields: ["hot_reason": reason])
    }

    // MARK: - Purge (FR-KVP8)

    /// Single-key purge with the exact tombstone-first 5-step ordering. Idempotent
    /// and fail-closed: any partial failure leaves the tombstone in place.
    @discardableResult
    func purge(rawKey: String) async throws -> KVPurgeResult {
        guard activated else { return .failed(.ioError) }
        if let detail = quarantined { return .failed(detail) }

        let index: String
        do {
            guard let computed = try keys.computeIndex(rawKey: rawKey, epoch: metadata.keyEpoch) else {
                return .failed(.keychainUnavailable)
            }
            index = computed
        } catch let e as KVKeychainError where isUnavailable(e) {
            return .failed(.keychainUnavailable)
        }

        let dir = entryDir(index)
        let hadArtifacts = fileExists(dir)
        let inFlight = false   // stage 1-2: no queued writers modeled outside the actor
        // A purge of an index with no artifacts and no in-flight work no-ops the map.
        if !hadArtifacts && !inFlight && metadata.purgeHighWatermarks[index] == nil {
            emit(.purgeOK, indexHashPrefix: indexPrefix(index), fields: ["entries_removed": "0", "bytes_freed": "0"])
            return .ok(entriesRemoved: 0, bytesFreed: 0)
        }

        let newGeneration = metadata.highWatermark(for: index) + 1
        do {
            // (1) incomplete tombstone carrying the incremented purge generation,
            //     fsync + dir fsync, THEN advance + fsync the high-watermark.
            try writeTombstone(KVTombstone(epoch: metadata.keyEpoch, index: index,
                                           purgeGeneration: newGeneration, complete: false))
            try crashIf(.purgeAfterIncompleteTombstone)
            try setHighWatermark(index: index, generation: newGeneration)
            try crashIf(.purgeAfterHighWatermark)

            // (3, hot half) Drop the matching hot entry and fence any outstanding
            // lease's commit BEFORE the on-disk generation is unlinked (CRITICAL-1).
            // The high-watermark is already durable, so a racing disk write is also
            // fenced; this closes the RAM side so a subsequent same-key begin() is a
            // cold_start miss and a pre-purge lease's commit() reinserts nothing.
            await hotPurgeSingle?(rawKey)

            let bytesFreed = try completePurgeSteps(index: index, generation: newGeneration)
            emit(.purgeOK, indexHashPrefix: indexPrefix(index),
                 fields: ["entries_removed": hadArtifacts ? "1" : "0", "bytes_freed": "\(bytesFreed)"])
            return .ok(entriesRemoved: hadArtifacts ? 1 : 0, bytesFreed: bytesFreed)
        } catch let crash as KVInjectedCrash {
            throw crash
        } catch let e as KVKeychainError where isUnavailable(e) {
            emit(.purgeFailed, indexHashPrefix: indexPrefix(index), fields: ["detail": KVReasonDetail.keychainUnavailable.rawValue])
            return .failed(.keychainUnavailable)
        } catch {
            emit(.purgeFailed, indexHashPrefix: indexPrefix(index), fields: ["detail": KVReasonDetail.ioError.rawValue])
            return .failed(.ioError)
        }
    }

    /// Steps 2–4 + completion mark. Recovery re-runs exactly these for an incomplete
    /// tombstone.
    private func completePurgeSteps(index: String, generation: Int) throws -> Int {
        // (2) destroy the entry DEK and verify absence — the revocation instant.
        try keys.destroyEntryDEK(epoch: metadata.keyEpoch, index: index)
        try crashIf(.purgeAfterDEKDestroy)

        // (3) remove hot-tier entry / cancel in-flight — integration wires the hot
        //     callback; here we drop in-memory publication state for the index.
        let freed = liveEntries[index]?.bytes ?? 0
        liveEntries.removeValue(forKey: index)
        lastGeneration.removeValue(forKey: index)
        lastCommitSequence.removeValue(forKey: index)

        // (4) delete generations + manifest, fsync entry dir.
        let dir = entryDir(index)
        if fileExists(dir) {
            try? FileManager.default.removeItem(at: dir)
        }
        try fsyncDirectory(entriesDir)
        committedBytes = max(0, committedBytes - freed)
        try crashIf(.purgeAfterUnlink)

        // Mark the tombstone complete (fsync + dir fsync). New writes admitted only now.
        try writeTombstone(KVTombstone(epoch: metadata.keyEpoch, index: index,
                                       purgeGeneration: generation, complete: true))
        return freed
    }

    /// Purge-all via epoch rotation (FR-KVP6/8). Fences the namespace, invalidates
    /// in-memory state, and rotates the key epoch through the intent journal, then
    /// verifies old-epoch Keychain material is absent before reporting success.
    @discardableResult
    func purgeAll() async throws -> KVPurgeResult {
        guard activated else { return .failed(.ioError) }
        if let detail = quarantined { return .failed(detail) }
        do {
            let bytesFreed = committedBytes
            let entries = liveEntries.count
            // Clear ALL hot entries and invalidate every outstanding lease's pending
            // commit BEFORE epoch rotation completes and before purge_ok (CRITICAL-1).
            await hotPurgeAll?()
            // Fence + invalidate all in-memory publication state, then rotate.
            try rotateEpoch()
            liveEntries.removeAll()
            lastGeneration.removeAll()
            lastCommitSequence.removeAll()
            committedBytes = 0
            emit(.purgeOK, fields: ["entries_removed": "\(entries)", "bytes_freed": "\(bytesFreed)", "mode": "all"])
            return .ok(entriesRemoved: entries, bytesFreed: bytesFreed)
        } catch let crash as KVInjectedCrash {
            throw crash
        } catch {
            emit(.purgeFailed, fields: ["detail": KVReasonDetail.ioError.rawValue, "mode": "all"])
            return .failed(.ioError)
        }
    }

    // MARK: - Epoch rotation (FR-KVP6 crash-safe ordering)

    private func rotateEpoch() throws {
        let from = metadata.keyEpoch
        let to = from + 1
        // (0) durable rotation-intent journal entry before any key operation.
        metadata.rotationJournal = KVRotationJournal(from: from, to: to, phase: "created")
        try persistMetadata()
        try crashIf(.rotationAfterJournal)
        try driveRotationForward()
    }

    /// Drive an open rotation journal forward through its remaining phases. Called at
    /// activation for an open journal and inline by `rotateEpoch`.
    private func driveRotationForward() throws {
        guard let journal = metadata.rotationJournal else { return }
        let incarnation = "rotate-\(journal.to)-\(UUID().uuidString)"

        if journal.phase == "created" {
            // (1) create + verify epoch-(to) master.
            try keys.createEpochMaster(epoch: journal.to, incarnation: incarnation)
            try crashIf(.rotationAfterMasterCreate)
            // (2) durably commit the new epoch + reset the high-watermark map.
            metadata.keyEpoch = journal.to
            metadata.purgeHighWatermarks = [:]
            metadata.rotationJournal = KVRotationJournal(from: journal.from, to: journal.to, phase: "committed")
            try persistMetadata()
            notifyEpoch()   // CRITICAL-2: adapter caches the new epoch for capture-time stamping.
            try crashIf(.rotationAfterEpochCommit)
        }

        if metadata.rotationJournal?.phase == "committed" || journal.phase == "committed" {
            // (3) delete epoch-(from) Keychain items and verify absence.
            try keys.deleteEpochItems(epoch: journal.from)
            metadata.rotationJournal = KVRotationJournal(from: journal.from, to: journal.to, phase: "old_deleted")
            try persistMetadata()
            try crashIf(.rotationAfterOldDelete)
        }

        // (4) delete old-epoch files best-effort; (5) clear the journal.
        removeOldEpochFiles(epoch: journal.from)
        metadata.rotationJournal = nil
        try persistMetadata()
    }

    private func removeOldEpochFiles(epoch: Int) {
        // v1 keeps files under one entries/ tree; a full purge-all clears entries.
        if fileExists(entriesDir) {
            try? FileManager.default.removeItem(at: entriesDir)
            try? createDir(entriesDir)
            try? fsyncDirectory(namespaceDir)   // best-effort cleanup after rotation
        }
    }

    // MARK: - Uninstall (FR-KVP8 --forget)

    /// Rotate the epoch, delete the namespace directory, and delete all namespace
    /// Keychain items (enumerated by service prefix). The lock (held from outside the
    /// deleted tree) is retained until deletions verify.
    func purgeAllAndForget() async throws -> KVPurgeResult {
        let result = try await purgeAll()
        if case .failed = result { return result }
        do {
            try keys.deleteAllNamespaceItems()
            if fileExists(namespaceDir) {
                try FileManager.default.removeItem(at: namespaceDir)
            }
            return result
        } catch {
            return .failed(.ioError)
        }
    }

    // MARK: - Quota / eviction (FR-KVP7)

    /// Reserve `bytes` against the data budget (total minus the metadata reserve),
    /// evicting LRU entries to fund the write. Returns false when it cannot be funded.
    private func reserveQuota(_ bytes: Int, nowMillis: Int) throws -> Bool {
        let dataBudget = max(0, config.maxBytes - config.metadataReserveBytes)
        // Evict by entry count first.
        while liveEntries.count >= config.maxEntries {
            guard try evictOneLRU(nowMillis: nowMillis) else { return false }
        }
        while committedBytes + bytes > dataBudget {
            guard try evictOneLRU(nowMillis: nowMillis) else { return false }
        }
        guard committedBytes + bytes <= dataBudget else { return false }
        committedBytes += bytes
        return true
    }

    /// Evict the least-recently-eligible-used entry; destroys its DEK (crypto-shred).
    @discardableResult
    private func evictOneLRU(nowMillis: Int) throws -> Bool {
        guard let victim = liveEntries.min(by: { $0.value.lastUsedMillis < $1.value.lastUsedMillis })?.key else {
            return false
        }
        try destroyWholeEntry(index: victim, reason: .diskEvictQuota)
        return true
    }

    /// Whole-entry eviction: destroy the DEK (verify), then reclaim files + bytes.
    private func destroyWholeEntry(index: String, reason: KVReasonCode) throws {
        try keys.destroyEntryDEK(epoch: metadata.keyEpoch, index: index)
        let freed = liveEntries[index]?.bytes ?? 0
        let dir = entryDir(index)
        if fileExists(dir) { try? FileManager.default.removeItem(at: dir) }
        try fsyncDirectory(entriesDir)
        liveEntries.removeValue(forKey: index)
        lastGeneration.removeValue(forKey: index)
        lastCommitSequence.removeValue(forKey: index)
        committedBytes = max(0, committedBytes - freed)
        emit(reason, indexHashPrefix: indexPrefix(index), fields: ["bytes_freed": "\(freed)"])
    }

    /// Retention compaction (FR-KVP10): evict entries whose creation predates the
    /// retention deadline. Retention is a cleanup deadline, not a reuse extension.
    func runRetention(nowMillis: Int) throws {
        let cutoff = nowMillis - config.retentionSeconds * 1000
        for (index, entry) in liveEntries where entry.lastUsedMillis < cutoff {
            try destroyWholeEntry(index: index, reason: .diskEvictRetention)
        }
    }

    // MARK: - High-watermark map (FR-KVP7/8)

    private func setHighWatermark(index: String, generation: Int) throws {
        // Cap: reaching 4096 forces an epoch rotation (resets the map, preserves
        // revocation via crypto-shred).
        if metadata.purgeHighWatermarks[index] == nil,
           metadata.purgeHighWatermarks.count >= KVNamespaceMetadata.highWatermarkCap {
            try rotateEpoch()
            return
        }
        metadata.purgeHighWatermarks[index] = generation
        try persistMetadata()
    }

    // MARK: - Recovery (FR-KVP7)

    private func recoverRotationJournal() throws {
        guard metadata.rotationJournal != nil else { return }
        try driveRotationForward()
    }

    private func recoverTombstones() throws {
        guard fileExists(tombstonesDir) else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: tombstonesDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? readBounded(file, maxBytes: 64 * 1024),
                  let tomb = KVTombstoneCodec.decode(data) else {
                quarantine(.ioError)
                throw KVStoreError.quarantined(.ioError)
            }
            // Recovery FIRST re-advances + persists the high-watermark if metadata is
            // behind, THEN re-runs the destructive steps for an incomplete tombstone.
            if metadata.highWatermark(for: tomb.index) < tomb.purgeGeneration {
                metadata.purgeHighWatermarks[tomb.index] = tomb.purgeGeneration
                try persistMetadata()
            }
            if !tomb.complete {
                _ = try completePurgeSteps(index: tomb.index, generation: tomb.purgeGeneration)
            }
        }
    }

    /// Sweep orphan temp/blob files and rebuild committed-byte accounting from
    /// surviving manifests (recovers generation/commit-sequence high-water).
    private func sweepOrphansAndAccount() throws {
        committedBytes = 0
        liveEntries.removeAll()
        guard fileExists(entriesDir) else { return }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: entriesDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let index = dir.lastPathComponent
            let manifestURL = dir.appendingPathComponent("manifest.json")
            // Sweep temp files always.
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in contents where file.lastPathComponent.hasPrefix("manifest.json.tmp.") {
                try? FileManager.default.removeItem(at: file)
            }
            guard fileExists(manifestURL),
                  let data = try? readBounded(manifestURL, maxBytes: KVDiskCacheFormat.manifestMaxBytes),
                  let manifest = try? KVManifestCodec.decode(data, maxBlobBytes: config.maxEntryBytes) else {
                // No committed manifest ⇒ orphan generation; sweep the whole dir.
                try? FileManager.default.removeItem(at: dir)
                continue
            }
            // Sweep non-current generation blobs (orphans from an interrupted compaction).
            for file in contents where file.pathExtension == "blob" && file.lastPathComponent != "gen-\(manifest.generation).blob" {
                try? FileManager.default.removeItem(at: file)
            }
            let blobURL = dir.appendingPathComponent("gen-\(manifest.generation).blob")
            let blobBytes = (try? fileSize(blobURL)) ?? 0
            let entryBytes = blobBytes + data.count
            committedBytes += entryBytes
            liveEntries[index] = KVLiveEntry(bytes: entryBytes, lastUsedMillis: manifest.createdAtMillis, generation: manifest.generation)
            lastGeneration[index] = manifest.generation
            lastCommitSequence[index] = manifest.commitSequence
        }
        try fsyncDirectory(entriesDir)
    }

    // MARK: - Inspection (FR-KVP12)

    func inspect() -> KVInspection {
        let tombstoneCount = (try? FileManager.default.contentsOfDirectory(atPath: tombstonesDir.path))?.filter { $0.hasSuffix(".json") }.count ?? 0
        let kcCount = (try? keys.keychainItemCount()) ?? 0
        return KVInspection(
            namespaceID: config.namespaceID,
            bytesUsed: committedBytes,
            entryCount: liveEntries.count,
            maxBytes: config.maxBytes,
            maxEntries: config.maxEntries,
            freeSpaceHeadroom: hostFreeBytes(),
            keyEpoch: metadata.keyEpoch,
            tombstoneCount: tombstoneCount,
            keychainItemCount: kcCount,
            eligibilityTTLSeconds: config.eligibilityTTLSeconds,
            purgeHighWatermarkEntries: metadata.purgeHighWatermarks.count,
            counters: counters)
    }

    // MARK: - Telemetry helpers

    private func emit(_ code: KVReasonCode, detail: KVReasonDetail? = nil,
                      indexHashPrefix: String? = nil, fields: [String: String] = [:]) {
        counters[code.rawValue, default: 0] += 1
        sink.emit(KVEvent(code, detail: detail, indexHashPrefix: indexHashPrefix, fields: fields))
    }

    private func emitMiss(_ code: KVReasonCode, detail: KVReasonDetail? = nil, prefix: String? = nil) {
        emit(code, detail: detail, indexHashPrefix: prefix)
    }

    private func skip(_ detail: KVReasonDetail, _ snapshot: KVWriteSnapshot) -> KVWriteResult {
        emit(.diskWriteSkipped, detail: detail, indexHashPrefix: indexPrefix(snapshot.indexHMAC))
        return .skipped(detail)
    }

    private func quarantine(_ detail: KVReasonDetail) {
        quarantined = detail
        emit(.diskStoreQuarantined, detail: detail)
    }

    /// Truncated index hash for logging (never the raw index value).
    private func indexPrefix(_ index: String) -> String { String(index.prefix(8)) }

    private func isUnavailable(_ e: KVKeychainError) -> Bool {
        if case .unavailable = e { return true }
        return false
    }

    // MARK: - Tombstone persistence

    private func writeTombstone(_ tomb: KVTombstone) throws {
        let url = tombstonesDir.appendingPathComponent("\(tomb.epoch)-\(tomb.index).json")
        let data = try KVTombstoneCodec.encode(tomb)
        try writeFileAtomic(data, to: url)
        try fsyncDirectory(tombstonesDir)
    }

    // MARK: - Free space

    private func hostFreeBytes() -> Int {
        if let override = config.freeSpaceOverride { return override }
        var st = statvfs()
        guard statvfs(namespaceDir.path, &st) == 0 else { return Int.max }
        return Int(st.f_bavail) * Int(st.f_frsize)
    }

    // MARK: - Low-level fs helpers (0700/0600, O_NOFOLLOW, fsync + atomic rename)

    @discardableResult
    private func createDir(_ url: URL) throws -> URL {
        if !fileExists(url) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        return url
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }

    /// Bounded read: fstat before read, reject oversize (§5a). O_NOFOLLOW, owner check.
    private func readBounded(_ url: URL, maxBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw KVStoreError.io("open failed errno=\(errno)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid() else {
            throw KVStoreError.io("fstat/owner check failed")
        }
        guard info.st_size <= maxBytes else { throw KVStoreError.io("file exceeds bound") }
        let size = Int(info.st_size)
        var buffer = Data(count: size)
        let readCount = buffer.withUnsafeMutableBytes { ptr -> Int in
            guard let base = ptr.baseAddress, size > 0 else { return 0 }
            return Darwin.read(fd, base, size)
        }
        guard readCount == size else { throw KVStoreError.io("short read") }
        return buffer
    }

    /// Atomic write: unique O_EXCL temp in the destination directory, fsync, rename,
    /// fsync dir. Files are 0600.
    private func writeFileAtomic(_ data: Data, to dest: URL) throws {
        let dir = dest.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(dest.lastPathComponent).tmp.\(UUID().uuidString)")
        try writeFileExclusive(data, to: temp)
        guard rename(temp.path, dest.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw KVStoreError.io("rename failed errno=\(errno)")
        }
        try fsyncDirectory(dir)
    }

    /// Create a file with O_EXCL | O_NOFOLLOW at 0600, write all bytes, fsync fd.
    private func writeFileExclusive(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw KVStoreError.io("exclusive create failed errno=\(errno) path=\(url.lastPathComponent)") }
        defer { close(fd) }
        var written = 0
        try data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            while written < data.count {
                let n = Darwin.write(fd, base + written, data.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw KVStoreError.io("write failed errno=\(errno)")
                }
                written += n
            }
        }
        guard fsync(fd) == 0 else { throw KVStoreError.io("fsync failed errno=\(errno)") }
    }

    /// Fsync a directory, throwing on open OR fsync failure (HIGH-7). A swallowed
    /// directory fsync failure would let `disk_write_committed` claim durability the
    /// filesystem never provided; propagating it turns the commit into a
    /// `disk_write_skipped` instead. Best-effort cleanup call sites use `try?`.
    private func fsyncDirectory(_ url: URL) throws {
        dirFsyncCount += 1
        if let k = dirFsyncFailAt, dirFsyncCount == k {
            throw KVStoreError.io("injected dir fsync failure at call \(k)")
        }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw KVStoreError.io("dir open for fsync failed errno=\(errno)") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw KVStoreError.io("dir fsync failed errno=\(errno)") }
    }
}

// MARK: - Fixed-nonce seal (internal: nonce chosen before manifest finalization)

/// Seal with a caller-chosen nonce so the chunk table (nonces + ct_lengths) can be
/// built before the manifest/AAD is finalized (GCM ciphertext length == plaintext
/// length, so ct_length is known pre-encryption).
func KVChunkCryptoSealFixedNonce(plaintext: Data, dek: Data, aad: Data, nonce: Data) throws -> KVChunkCrypto.Sealed {
    let gcmNonce = try AES.GCM.Nonce(data: nonce)
    let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: dek), nonce: gcmNonce, authenticating: aad)
    return KVChunkCrypto.Sealed(nonce: nonce, ciphertext: box.ciphertext, tag: box.tag)
}

// MARK: - Control-plane JSON codecs (bounded, fsync-protected docs)

enum KVMetadataCodec {
    static func encode(_ m: KVNamespaceMetadata) throws -> Data {
        var object: [String: Any] = [
            "provider_namespace_id": m.providerNamespaceID,
            "key_epoch": m.keyEpoch,
            "schema_id": m.schemaID,
            "codec_id": m.codecID,
            "purge_high_watermarks": m.purgeHighWatermarks,
            "clock_high_water_ms": m.clockHighWaterMillis,
        ]
        if let journal = m.rotationJournal {
            object["rotation_journal"] = ["from": journal.from, "to": journal.to, "phase": journal.phase]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> KVNamespaceMetadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let namespaceID = object["provider_namespace_id"] as? String,
              let epoch = object["key_epoch"] as? Int,
              let schemaID = object["schema_id"] as? String,
              let codecID = object["codec_id"] as? String,
              let clockHW = object["clock_high_water_ms"] as? Int else { return nil }
        let hwRaw = (object["purge_high_watermarks"] as? [String: Any]) ?? [:]
        var hw: [String: Int] = [:]
        for (k, v) in hwRaw { if let n = v as? Int { hw[k] = n } }
        var journal: KVRotationJournal?
        if let j = object["rotation_journal"] as? [String: Any],
           let from = j["from"] as? Int, let to = j["to"] as? Int, let phase = j["phase"] as? String {
            journal = KVRotationJournal(from: from, to: to, phase: phase)
        }
        return KVNamespaceMetadata(
            providerNamespaceID: namespaceID, keyEpoch: epoch, schemaID: schemaID, codecID: codecID,
            purgeHighWatermarks: hw, clockHighWaterMillis: clockHW, rotationJournal: journal)
    }
}

enum KVTombstoneCodec {
    static func encode(_ t: KVTombstone) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "epoch": t.epoch, "index": t.index,
            "purge_generation": t.purgeGeneration, "complete": t.complete,
        ], options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> KVTombstone? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let epoch = object["epoch"] as? Int,
              let index = object["index"] as? String,
              let gen = object["purge_generation"] as? Int,
              let complete = object["complete"] as? Bool else { return nil }
        return KVTombstone(epoch: epoch, index: index, purgeGeneration: gen, complete: complete)
    }
}

// MARK: - KVCacheSimple (de)serialization bridge

/// Bridge between the allowlisted `KVCacheSimple` and the codec layer payload.
/// Snapshotting reads `state = [keys, values]` (already sliced to offset); restore
/// rebuilds arrays and sets `state` (the setter re-derives `offset`).
enum KVCacheSerialization {
    static func codecDType(_ dtype: DType) -> KVCodecDType? {
        switch dtype {
        case .float16: return .f16
        case .bfloat16: return .bf16
        case .float32: return .f32
        case .int32: return .i32
        case .uint32: return .u32
        default: return nil
        }
    }

    static func mlxDType(_ dtype: KVCodecDType) -> DType {
        switch dtype {
        case .f16: return .float16
        case .bf16: return .bfloat16
        case .f32: return .float32
        case .i32: return .int32
        case .u32: return .uint32
        }
    }

    /// Snapshot per-layer state from KVCacheSimple caches. Returns nil if any layer is
    /// empty, uses an unsupported dtype, or has mismatched K/V geometry (→ skip write).
    static func snapshotLayers(_ caches: [KVCacheSimple]) -> [KVLayerPayload]? {
        var out: [KVLayerPayload] = []
        for (i, cache) in caches.enumerated() {
            let state = cache.state
            guard state.count == 2 else { return nil }
            let k = state[0].asData(access: .copy)
            let v = state[1].asData(access: .copy)
            guard let dtype = codecDType(k.dType), codecDType(v.dType) == dtype else { return nil }
            guard k.shape == v.shape else { return nil }
            out.append(KVLayerPayload(
                layerIndex: i, classID: "KVCacheSimple", ndim: k.shape.count, dims: k.shape,
                dtype: dtype, cacheOffset: cache.offset, keyBytes: k.data, valueBytes: v.data))
        }
        return out
    }

    /// Rebuild KVCacheSimple caches from decoded layer payloads.
    static func restore(_ layers: [KVLayerPayload]) -> [KVCacheSimple] {
        var caches: [KVCacheSimple] = []
        for layer in layers.sorted(by: { $0.layerIndex < $1.layerIndex }) {
            let dtype = mlxDType(layer.dtype)
            let k = MLXArray(layer.keyBytes, layer.dims, dtype: dtype)
            let v = MLXArray(layer.valueBytes, layer.dims, dtype: dtype)
            let cache = KVCacheSimple()
            cache.state = [k, v]
            caches.append(cache)
        }
        return caches
    }
}
