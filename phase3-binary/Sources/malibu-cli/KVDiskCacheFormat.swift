/// KVDiskCacheFormat — SPEC-037 §5a format v1 normative encoding.
///
/// This file owns the byte-level on-disk contract for the KV survival disk
/// tier: the manifest model (closed field lists), its RFC 8785 (JCS) canonical
/// encoding, the non-circular AAD projection (manifest minus `blob_sha256` plus
/// a 4-byte big-endian chunk ordinal), the four-category envelope validation of
/// FR-KVP4 mapped to the §5 reason codes, the self-delimiting payload codec with
/// the exact overflow-checked `decoded_length` equation, the parsing bounds, and
/// the `KVS1`-magic chunk frame encode/decode.
///
/// It performs no I/O and touches no Keychain: the store (KVDiskCacheStore) and
/// key hierarchy (KVDiskCacheKeys) layer on top. Every constant here is fixed by
/// SPEC-037 and MUST NOT drift.
///
/// Reference: specs/SPEC-037-kv-survival-restart.md §3, §4 (FR-KVP4/5/6), §5, §5a.

import CryptoKit
import Foundation

// MARK: - Fixed identifiers and bounds (SPEC-037 §5a)

enum KVDiskCacheFormat {
    /// Manifest schema identifier (FR-KVP4(a)1).
    static let manifestSchemaID = "kvsurv-manifest-v1"
    /// Payload codec identifier (FR-KVP4(a)1).
    static let codecID = "kvsurv-codec-v1"
    /// Chunk frame magic (§5a blob framing).
    static let chunkMagic = Data("KVS1".utf8)

    // Parsing bounds (§5a "Bounds"). Violations → disk_miss_corrupt before allocation.
    static let manifestMaxBytes = 64 * 1024                 // 64 KiB manifest cap
    static let maxLayers = 512
    static let maxNdim = 8
    static let maxDim: UInt64 = 1 << 32                     // each dim ≤ 2^32
    static let maxChunks = 4096
    static let maxChunkCiphertextBytes = 64 * 1024 * 1024   // 64 MiB per chunk
    static let maxStringBytes = 1024                        // strings ≤ 1 KiB
    static let maxTokenCount = 200_000                      // hot-tier token cap
    static let chunkNonceBytes = 12
    static let gcmTagBytes = 16

    /// The v1 serialization allowlist: exactly the unquantized standard cache class.
    static let allowlistedCacheClasses: Set<String> = ["KVCacheSimple"]
}

// MARK: - Codec dtype enum (§5a payload codec)

/// The on-disk dtype enum used by both the manifest `dtype` field and the codec
/// per-layer record. Distinct from MLX's `DType` so the byte contract is stable
/// even if the engine renames or reorders its enum.
enum KVCodecDType: Int, Sendable, CaseIterable, Equatable {
    case f16 = 1
    case bf16 = 2
    case f32 = 3
    case i32 = 4
    case u32 = 5

    /// Size in bytes of one element (drives the `decoded_length` equation).
    var byteSize: Int {
        switch self {
        case .f16, .bf16: return 2
        case .f32, .i32, .u32: return 4
        }
    }
}

// MARK: - Reason codes (FR-KVP12 closed enum) and detail reasons

/// Exhaustive, normative reason-code enum (FR-KVP12). The store emits these; the
/// format layer returns the read/promotion-phase subset from validation.
enum KVReasonCode: String, Sendable, CaseIterable, Equatable {
    // read / promotion phase
    case diskHit = "disk_hit"
    case diskPromoteRejected = "disk_promote_rejected"
    case diskMissAbsent = "disk_miss_absent"
    case diskMissEnvelope = "disk_miss_envelope"
    case diskMissCorrupt = "disk_miss_corrupt"
    case diskMissExpired = "disk_miss_expired"
    case diskMissTombstoned = "disk_miss_tombstoned"
    case diskMissIO = "disk_miss_io"
    case diskMissBusy = "disk_miss_busy"
    case diskMissBudget = "disk_miss_budget"
    case diskMissIdentityUnavailable = "disk_miss_identity_unavailable"
    // write phase
    case diskWriteCommitted = "disk_write_committed"
    case diskWriteSkipped = "disk_write_skipped"
    // lifecycle
    case diskEvictQuota = "disk_evict_quota"
    case diskEvictRetention = "disk_evict_retention"
    // control plane
    case diskStoreQuarantined = "disk_store_quarantined"
    case purgeOK = "purge_ok"
    case purgeFailed = "purge_failed"
}

/// Detail reasons carried as associated values where SPEC-037 names them
/// (e.g. `keychain_unavailable`, `clock_rollback`, `exceeds_promotion_ceiling`,
/// `identity_unavailable`).
enum KVReasonDetail: String, Sendable, Equatable {
    case keychainUnavailable = "keychain_unavailable"
    case clockRollback = "clock_rollback"
    case exceedsPromotionCeiling = "exceeds_promotion_ceiling"
    case identityUnavailable = "identity_unavailable"
    case promotionDeadline = "promotion_deadline"
    case quotaExhausted = "quota_exhausted"
    case freeSpaceFloor = "free_space_floor"
    case perEntryCap = "per_entry_cap"
    case allowlistRemoved = "allowlist_removed"
    case geometryUnvalidated = "geometry_unvalidated"
    case fenceLost = "fence_lost"
    case snapshotDisplaced = "snapshot_displaced"
    case ioError = "io_error"
    case readOnlyFilesystem = "read_only_filesystem"
    case dekCreateFailed = "dek_create_failed"
    case dekDestroyed = "dek_destroyed"
    case fstatFailed = "fstat_failed"
    case oversizedManifest = "oversized_manifest"
    /// A read/promotion refused because an INCOMPLETE tombstone durably blocks the
    /// index (a purge started but has not been completion-marked). Derived from
    /// durable state, so it fails closed across a purge failure AND a restart until
    /// recovery finishes the purge (Item 1, FR-KVP8 fail-closed revocation).
    case purgePending = "purge_pending"
    /// A write refused because the aggregate write-live staging budget
    /// (`write_staging_max_bytes`) is exhausted across all concurrent snapshots
    /// (Item 3, FR-KVP3 RAM-DoS bound).
    case writeBudget = "write_budget"
    /// A commit for a tier-eligible request produced a cache class outside the v1
    /// serialization allowlist (`{"KVCacheSimple"}`), so it cannot be persisted.
    /// Sources: model families that override `newCache` and ignore `maxKVSize`
    /// (e.g. gpt-oss, gemma-4, nemotron), hot-cache reuse of a rotating cache first
    /// populated by a relay/tier2 request, or mid-generation `kvBits` quantization
    /// replacing the layers. The v1 allowlist is by design; this makes the skip
    /// OBSERVABLE instead of a silent no-op.
    case unsupportedCacheClass = "unsupported_cache_class"
}

/// Read/promotion-phase result of manifest parse + envelope validation. `ok`
/// carries the validated manifest so the store can proceed to chunk decrypt.
enum KVReadOutcome: Sendable, Equatable {
    case ok(KVDiskManifest)
    case miss(KVReasonCode, KVReasonDetail?)

    static func miss(_ code: KVReasonCode) -> KVReadOutcome { .miss(code, nil) }
}

// MARK: - Manifest model (§5a closed field lists)

/// One `layers[]` record. Closed key set `{layer_index, class_id,
/// layout_version, ndim, dims[], dtype}` (FR-KVP4(a)8, §5a).
struct KVLayerRecord: Sendable, Equatable {
    let layerIndex: Int
    let classID: String
    let layoutVersion: Int
    let ndim: Int
    let dims: [Int]
    let dtype: KVCodecDType
}

/// One `chunks[]` record. Closed key set `{ordinal, ct_length, nonce}` (§5a).
struct KVChunkRecord: Sendable, Equatable {
    let ordinal: Int
    let ctLength: Int
    /// 96-bit nonce, stored base16 in JSON; raw 12 bytes here.
    let nonce: Data
}

/// The atomically-replaced per-entry manifest (`manifest.json`). Field set is the
/// closed required-field list of §5a; missing or unknown fields reject the manifest.
struct KVDiskManifest: Sendable, Equatable {
    let schemaID: String
    let codecID: String
    let namespaceID: String
    let keyEpoch: Int
    let indexHMAC: String            // lowercase base16
    let generation: Int
    let commitSequence: Int
    let purgeGeneration: Int
    let requestModel: String
    let servedModelID: String
    let modelSHA256: String          // lowercase base16
    let catalogRevision: String
    let tokenizerID: String
    let tokenizerConfigSHA256: String
    let chatTemplateSHA256: String
    let abiEpoch: Int
    let mlxSwiftLMRevision: String
    let mlxVersion: String
    let cacheClass: String
    let layerCount: Int
    let layers: [KVLayerRecord]
    /// Unquantized caches encode these four as JSON `null` (matching `kvBits == nil`).
    let kvBits: Int?
    let kvGroupSize: Int?
    let kvQuantMode: String?
    let kvQuantPolicy: String?
    let decodePath: String
    let tokenCount: Int
    let createdAtMillis: Int          // Unix ms UTC
    let eligibleUntilMillis: Int      // Unix ms UTC
    let decodedLength: Int
    let chunks: [KVChunkRecord]
    let blobLength: Int
    let blobSHA256: String            // lowercase base16
}

// MARK: - Runtime identity (FR-KVP4(a) exact-match inputs)

/// Live per-layer geometry the envelope is matched against. The sequence axis is
/// entry-specific (sized to `token_count`) and excluded from the exact-match; all
/// other dims, plus class/dtype/ndim/layout, are byte-equality checked.
struct KVLayerGeometry: Sendable, Equatable {
    let layerIndex: Int
    let classID: String
    let layoutVersion: Int
    let ndim: Int
    /// Full dims; the value at `sequenceAxis` is ignored (compared to token_count).
    let dims: [Int]
    let dtype: KVCodecDType
    let sequenceAxis: Int
}

/// The complete set of live-identity inputs an eligible hit must match
/// byte-for-byte (FR-KVP4(a) items 1–10), plus the recomputed HMAC index and the
/// live purge-generation high-watermark for the fence (a′). A `nil` in any
/// required field signals FR-KVP4 "live identity completeness" (→
/// `disk_miss_identity_unavailable`).
struct KVRuntimeIdentity: Sendable, Equatable {
    let namespaceID: String
    let keyEpoch: Int
    let indexHMAC: String
    let requestModel: String
    let servedModelID: String
    let modelSHA256: String?          // nil ⇒ identity unavailable
    let catalogRevision: String
    let tokenizerID: String
    let tokenizerConfigSHA256: String
    let chatTemplateSHA256: String
    let abiEpoch: Int
    let mlxSwiftLMRevision: String
    let mlxVersion: String
    let cacheClass: String
    let layerCount: Int
    let layers: [KVLayerGeometry]
    let kvBits: Int?
    let kvGroupSize: Int?
    let kvQuantMode: String?
    let kvQuantPolicy: String?
    let decodePath: String
    /// Live purge-generation high-watermark for the index (FR-KVP8 fence).
    let liveHighWatermark: Int
}

// MARK: - Errors

enum KVFormatError: Error, Equatable {
    case overflow
    case encodeFailed(String)
    case jcsFailed(String)
}

// MARK: - Little-endian byte helpers

enum KVByteWriter {
    static func u16LE(_ value: Int) throws -> Data {
        guard value >= 0, value <= Int(UInt16.max) else { throw KVFormatError.overflow }
        let v = UInt16(value)
        return Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
    }

    static func u32LE(_ value: Int) throws -> Data {
        guard value >= 0, value <= Int(UInt32.max) else { throw KVFormatError.overflow }
        let v = UInt32(value)
        var out = Data(count: 4)
        out[0] = UInt8(v & 0xff)
        out[1] = UInt8((v >> 8) & 0xff)
        out[2] = UInt8((v >> 16) & 0xff)
        out[3] = UInt8((v >> 24) & 0xff)
        return out
    }

    static func i32LE(_ value: Int32) -> Data {
        let v = UInt32(bitPattern: value)
        var out = Data(count: 4)
        out[0] = UInt8(v & 0xff)
        out[1] = UInt8((v >> 8) & 0xff)
        out[2] = UInt8((v >> 16) & 0xff)
        out[3] = UInt8((v >> 24) & 0xff)
        return out
    }

    static func u64LE(_ value: Int) throws -> Data {
        guard value >= 0 else { throw KVFormatError.overflow }
        let v = UInt64(value)
        var out = Data(count: 8)
        for i in 0 ..< 8 {
            out[i] = UInt8((v >> (8 * i)) & 0xff)
        }
        return out
    }

    static func u32BE(_ value: Int) throws -> Data {
        guard value >= 0, value <= Int(UInt32.max) else { throw KVFormatError.overflow }
        let v = UInt32(value)
        var out = Data(count: 4)
        out[0] = UInt8((v >> 24) & 0xff)
        out[1] = UInt8((v >> 16) & 0xff)
        out[2] = UInt8((v >> 8) & 0xff)
        out[3] = UInt8(v & 0xff)
        return out
    }
}

/// Bounds-checked forward reader over a `Data` buffer.
///
/// Item 4 (FR-KVP9 read-peak): reads DIRECTLY from the backing `Data` via an index
/// cursor and copies out only the exact slice `readBytes` requests — it never
/// materializes a whole-buffer `[UInt8]` duplicate. The streaming decoder creates a
/// fresh reader over its residual on every parse iteration; a `[UInt8](data)` copy
/// there duplicated the ENTIRE residual (up to a 64 MiB chunk) co-resident with the
/// residual and the freshly materialized tensor — an unaccounted read-side peak.
struct KVByteReader {
    private let data: Data
    private let base: Data.Index
    private(set) var offset: Int = 0

    init(_ data: Data) { self.data = data; self.base = data.startIndex }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset == data.count }

    private func byte(_ i: Int) -> Int { Int(data[base + i]) }

    mutating func readU16LE() -> Int? {
        guard remaining >= 2 else { return nil }
        let v = byte(offset) | (byte(offset + 1) << 8)
        offset += 2
        return v
    }

    mutating func readU32LE() -> Int? {
        guard remaining >= 4 else { return nil }
        let v = byte(offset)
            | (byte(offset + 1) << 8)
            | (byte(offset + 2) << 16)
            | (byte(offset + 3) << 24)
        offset += 4
        return v
    }

    mutating func readI32LE() -> Int32? {
        guard let raw = readU32LE() else { return nil }
        return Int32(bitPattern: UInt32(raw))
    }

    mutating func readU8() -> Int? {
        guard remaining >= 1 else { return nil }
        let v = byte(offset)
        offset += 1
        return v
    }

    mutating func readU64LE() -> Int? {
        guard remaining >= 8 else { return nil }
        var v: UInt64 = 0
        for i in 0 ..< 8 {
            v |= UInt64(byte(offset + i)) << (8 * i)
        }
        offset += 8
        // Reject values that would not fit an Int (defensive; codec caps prevent this).
        guard v <= UInt64(Int.max) else { return nil }
        return Int(v)
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        let start = base + offset
        let slice = Data(data[start ..< start + count])   // only the requested slice
        offset += count
        return slice
    }
}

// MARK: - Overflow-checked decoded_length (§5a exact equation)

extension KVDiskCacheFormat {
    /// Per-layer geometry sufficient to compute `decoded_length`.
    struct LayerGeometryInput: Sendable, Equatable {
        let classID: String
        let ndim: Int
        let dims: [Int]        // full serialized shape incl. sequence axis
        let dtype: KVCodecDType
    }

    /// The single exact, overflow-checked `decoded_length` equation of §5a. Used by
    /// the FR-KVP3 write-side estimate, the FR-KVP9 `disk_miss_budget` trigger, and
    /// FR-KVP4(c) recomputation. Returns `nil` on any overflow or invalid geometry.
    ///
    /// `4 + 4·token_count`
    ///  `+ Σ layers ( 4 + 2 + |class_id bytes| + 1 + 8·ndim + 1 + 8`
    ///  `           + 2·(8 + Π(dims)·dtype_size) )`
    static func decodedLength(tokenCount: Int, layers: [LayerGeometryInput]) -> Int? {
        func add(_ a: Int, _ b: Int) -> Int? {
            let (r, o) = a.addingReportingOverflow(b)
            return o ? nil : r
        }
        func mul(_ a: Int, _ b: Int) -> Int? {
            let (r, o) = a.multipliedReportingOverflow(by: b)
            return o ? nil : r
        }
        guard tokenCount >= 0 else { return nil }
        // 4 (token-count word) + 4·token_count (i32 token array)
        guard let tokenArrayBytes = mul(4, tokenCount) else { return nil }
        guard var total = add(4, tokenArrayBytes) else { return nil }

        for layer in layers {
            guard layer.ndim >= 0, layer.ndim <= maxNdim, layer.dims.count == layer.ndim else {
                return nil
            }
            let classBytes = Data(layer.classID.utf8).count
            // per-layer framing: layer_index(4) + class-ID len(2) + class bytes + ndim(1)
            //                   + dims(8·ndim) + dtype(1) + cache_offset(8)
            guard let dimsBytes = mul(8, layer.ndim) else { return nil }
            var framing = 0
            for piece in [4, 2, classBytes, 1, dimsBytes, 1, 8] {
                guard let next = add(framing, piece) else { return nil }
                framing = next
            }
            // element count = Π(dims)
            var elements = 1
            for d in layer.dims {
                guard d >= 0, UInt64(d) <= maxDim else { return nil }
                guard let next = mul(elements, d) else { return nil }
                elements = next
            }
            guard let tensorBytes = mul(elements, layer.dtype.byteSize) else { return nil }
            // 2·(8 + tensorBytes): K and V, each a u64 length prefix + row-major bytes
            guard let onePrefixed = add(8, tensorBytes) else { return nil }
            guard let bothTensors = mul(2, onePrefixed) else { return nil }
            guard let layerTotal = add(framing, bothTensors) else { return nil }
            guard let next = add(total, layerTotal) else { return nil }
            total = next
        }
        return total
    }
}

// MARK: - JCS manifest encoding + AAD projection

extension KVDiskManifest {
    /// Build the RFC 8785 JCS value for this manifest. When `omitBlobSHA256` is
    /// true the `blob_sha256` field is dropped — that projection is the AAD base
    /// (§5a non-circular AAD).
    func jcsValue(omitBlobSHA256: Bool) -> RFC8785JCS.Value {
        func intVal(_ v: Int) -> RFC8785JCS.Value { .int(v) }
        func strVal(_ v: String) -> RFC8785JCS.Value { .string(v) }
        func optIntOrNull(_ v: Int?) -> RFC8785JCS.Value { v.map { .int($0) } ?? .null }
        func optStrOrNull(_ v: String?) -> RFC8785JCS.Value { v.map { .string($0) } ?? .null }

        let layerValues: [RFC8785JCS.Value] = layers.map { layer in
            .object([
                "layer_index": .int(layer.layerIndex),
                "class_id": .string(layer.classID),
                "layout_version": .int(layer.layoutVersion),
                "ndim": .int(layer.ndim),
                "dims": .array(layer.dims.map { .int($0) }),
                "dtype": .int(layer.dtype.rawValue),
            ])
        }
        let chunkValues: [RFC8785JCS.Value] = chunks.map { chunk in
            .object([
                "ordinal": .int(chunk.ordinal),
                "ct_length": .int(chunk.ctLength),
                "nonce": .string(KVHex.encode(chunk.nonce)),
            ])
        }

        var fields: [String: RFC8785JCS.Value] = [
            "schema_id": strVal(schemaID),
            "codec_id": strVal(codecID),
            "namespace_id": strVal(namespaceID),
            "key_epoch": intVal(keyEpoch),
            "index_hmac": strVal(indexHMAC),
            "generation": intVal(generation),
            "commit_sequence": intVal(commitSequence),
            "purge_generation": intVal(purgeGeneration),
            "request_model": strVal(requestModel),
            "served_model_id": strVal(servedModelID),
            "model_sha256": strVal(modelSHA256),
            "catalog_revision": strVal(catalogRevision),
            "tokenizer_id": strVal(tokenizerID),
            "tokenizer_config_sha256": strVal(tokenizerConfigSHA256),
            "chat_template_sha256": strVal(chatTemplateSHA256),
            "abi_epoch": intVal(abiEpoch),
            "mlx_swift_lm_revision": strVal(mlxSwiftLMRevision),
            "mlx_version": strVal(mlxVersion),
            "cache_class": strVal(cacheClass),
            "layer_count": intVal(layerCount),
            "layers": .array(layerValues),
            "kv_bits": optIntOrNull(kvBits),
            "kv_group_size": optIntOrNull(kvGroupSize),
            "kv_quant_mode": optStrOrNull(kvQuantMode),
            "kv_quant_policy": optStrOrNull(kvQuantPolicy),
            "decode_path": strVal(decodePath),
            "token_count": intVal(tokenCount),
            "created_at": intVal(createdAtMillis),
            "eligible_until": intVal(eligibleUntilMillis),
            "decoded_length": intVal(decodedLength),
            "chunks": .array(chunkValues),
            "blob_length": intVal(blobLength),
        ]
        if !omitBlobSHA256 {
            fields["blob_sha256"] = strVal(blobSHA256)
        }
        return .object(fields)
    }

    /// Full JCS canonical bytes of the manifest (for `manifest.json` serialization).
    /// Uses the RAW code-point JCS path (M-10): the shared error-envelope JCS
    /// NFC-normalizes string values, which would collapse composed vs decomposed
    /// forms in identity/AAD fields and let a decomposed-key manifest authenticate
    /// against a composed live identity (and vice versa). The KV manifest codec must
    /// preserve the exact code points it was built from.
    func jcsCanonicalData() throws -> Data {
        do {
            let s = try RFC8785JCS.canonicalStringRawStrings(jcsValue(omitBlobSHA256: false))
            return Data(s.utf8)
        } catch {
            throw KVFormatError.jcsFailed("\(error)")
        }
    }

    /// The AAD for chunk `ordinal`: JCS(manifest without `blob_sha256`) ‖ BE32(ordinal).
    /// Raw code-point JCS (M-10) — see `jcsCanonicalData`.
    func aad(ordinal: Int) throws -> Data {
        let base: Data
        do {
            let s = try RFC8785JCS.canonicalStringRawStrings(jcsValue(omitBlobSHA256: true))
            base = Data(s.utf8)
        } catch {
            throw KVFormatError.jcsFailed("\(error)")
        }
        var out = base
        out.append(try KVByteWriter.u32BE(ordinal))
        return out
    }
}

// MARK: - Hex helpers

enum KVHex {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ string: String) -> Data? {
        guard string.count % 2 == 0 else { return nil }
        var out = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index ..< next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

// MARK: - Manifest JSON codec (parse with strict bounds + coherence)

enum KVManifestParseError: Error, Equatable {
    /// Structural / integrity failure → maps to disk_miss_corrupt.
    case corrupt(String)
}

enum KVManifestCodec {
    /// Serialize a manifest to its JCS canonical bytes for `manifest.json`.
    static func encode(_ manifest: KVDiskManifest) throws -> Data {
        try manifest.jcsCanonicalData()
    }

    /// Parse and structurally validate a manifest. Enforces §5a bounds, the closed
    /// required-field list (missing OR unknown field rejects), the `decoded_length`
    /// recomputation, the chunk-table coherence, and the blob-length/frame-size
    /// consistency. All failures are integrity failures (`disk_miss_corrupt`).
    ///
    /// Envelope (identity/lifecycle/fence) checks are NOT done here — call
    /// `KVEnvelopeValidator.validate` after a successful parse.
    static func decode(_ data: Data, maxBlobBytes: Int) throws -> KVDiskManifest {
        guard data.count <= KVDiskCacheFormat.manifestMaxBytes else {
            throw KVManifestParseError.corrupt("manifest exceeds 64 KiB cap")
        }
        try scanNoDuplicateKeys(data)
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any] else {
            throw KVManifestParseError.corrupt("manifest is not a JSON object")
        }

        let required: Set<String> = [
            "schema_id", "codec_id", "namespace_id", "key_epoch", "index_hmac",
            "generation", "commit_sequence", "purge_generation", "request_model",
            "served_model_id", "model_sha256", "catalog_revision", "tokenizer_id",
            "tokenizer_config_sha256", "chat_template_sha256", "abi_epoch",
            "mlx_swift_lm_revision", "mlx_version", "cache_class", "layer_count",
            "layers", "kv_bits", "kv_group_size", "kv_quant_mode", "kv_quant_policy",
            "decode_path", "token_count", "created_at", "eligible_until",
            "decoded_length", "chunks", "blob_length", "blob_sha256",
        ]
        let present = Set(object.keys)
        guard present == required else {
            let missing = required.subtracting(present)
            let unknown = present.subtracting(required)
            throw KVManifestParseError.corrupt(
                "manifest field set mismatch missing=\(missing.sorted()) unknown=\(unknown.sorted())")
        }

        func str(_ key: String, maxLen: Int = KVDiskCacheFormat.maxStringBytes) throws -> String {
            guard let v = object[key] as? String, Data(v.utf8).count <= maxLen else {
                throw KVManifestParseError.corrupt("field \(key) not a bounded string")
            }
            return v
        }
        func hex(_ key: String) throws -> String {
            let v = try str(key)
            guard KVHex.decode(v) != nil else {
                throw KVManifestParseError.corrupt("field \(key) not lowercase base16")
            }
            guard v == v.lowercased() else {
                throw KVManifestParseError.corrupt("field \(key) not lowercase")
            }
            return v
        }
        func intVal(_ key: String, min: Int = 0, max: Int = Int(Int32.max)) throws -> Int {
            guard let n = object[key] as? NSNumber, isIntegral(n) else {
                throw KVManifestParseError.corrupt("field \(key) not an integer")
            }
            let value = n.intValue
            guard value >= min, value <= max else {
                throw KVManifestParseError.corrupt("field \(key) out of range")
            }
            return value
        }
        // JSON-safe millisecond range: allow full positive Int (bounded by 2^53 in
        // practice; NSNumber preserves the value). Millis are non-negative.
        func millis(_ key: String) throws -> Int {
            guard let n = object[key] as? NSNumber, isIntegral(n) else {
                throw KVManifestParseError.corrupt("field \(key) not an integer millisecond value")
            }
            let value = n.intValue
            guard value >= 0 else { throw KVManifestParseError.corrupt("field \(key) negative") }
            return value
        }
        func optInt(_ key: String) throws -> Int? {
            if object[key] is NSNull { return nil }
            guard let n = object[key] as? NSNumber, isIntegral(n), !isBool(n) else {
                throw KVManifestParseError.corrupt("field \(key) not integer|null")
            }
            return n.intValue
        }
        func optStr(_ key: String) throws -> String? {
            if object[key] is NSNull { return nil }
            guard let v = object[key] as? String,
                  Data(v.utf8).count <= KVDiskCacheFormat.maxStringBytes else {
                throw KVManifestParseError.corrupt("field \(key) not string|null")
            }
            return v
        }

        let tokenCount = try intVal("token_count", max: KVDiskCacheFormat.maxTokenCount)
        let layerCount = try intVal("layer_count", max: KVDiskCacheFormat.maxLayers)

        // layers[]
        guard let rawLayers = object["layers"] as? [Any] else {
            throw KVManifestParseError.corrupt("layers not an array")
        }
        guard rawLayers.count <= KVDiskCacheFormat.maxLayers, rawLayers.count == layerCount else {
            throw KVManifestParseError.corrupt("layers count mismatch or over bound")
        }
        var layers: [KVLayerRecord] = []
        layers.reserveCapacity(rawLayers.count)
        for (i, rawLayer) in rawLayers.enumerated() {
            guard let layer = rawLayer as? [String: Any] else {
                throw KVManifestParseError.corrupt("layer \(i) not an object")
            }
            let layerKeys: Set<String> = ["layer_index", "class_id", "layout_version", "ndim", "dims", "dtype"]
            guard Set(layer.keys) == layerKeys else {
                throw KVManifestParseError.corrupt("layer \(i) field set mismatch")
            }
            guard let li = (layer["layer_index"] as? NSNumber).flatMap({ isIntegral($0) ? $0.intValue : nil }),
                  li >= 0, li <= KVDiskCacheFormat.maxLayers else {
                throw KVManifestParseError.corrupt("layer \(i) layer_index invalid")
            }
            guard let cls = layer["class_id"] as? String,
                  Data(cls.utf8).count <= KVDiskCacheFormat.maxStringBytes else {
                throw KVManifestParseError.corrupt("layer \(i) class_id invalid")
            }
            guard let lv = (layer["layout_version"] as? NSNumber).flatMap({ isIntegral($0) ? $0.intValue : nil }),
                  lv >= 0 else {
                throw KVManifestParseError.corrupt("layer \(i) layout_version invalid")
            }
            guard let ndim = (layer["ndim"] as? NSNumber).flatMap({ isIntegral($0) ? $0.intValue : nil }),
                  ndim >= 0, ndim <= KVDiskCacheFormat.maxNdim else {
                throw KVManifestParseError.corrupt("layer \(i) ndim invalid")
            }
            guard let rawDims = layer["dims"] as? [Any], rawDims.count == ndim else {
                throw KVManifestParseError.corrupt("layer \(i) dims count mismatch")
            }
            var dims: [Int] = []
            dims.reserveCapacity(ndim)
            for rawDim in rawDims {
                guard let n = rawDim as? NSNumber, isIntegral(n) else {
                    throw KVManifestParseError.corrupt("layer \(i) dim not integer")
                }
                let d = n.intValue
                guard d >= 0, UInt64(d) <= KVDiskCacheFormat.maxDim else {
                    throw KVManifestParseError.corrupt("layer \(i) dim out of bound")
                }
                dims.append(d)
            }
            guard let dtypeRaw = (layer["dtype"] as? NSNumber).flatMap({ isIntegral($0) ? $0.intValue : nil }),
                  let dtype = KVCodecDType(rawValue: dtypeRaw) else {
                throw KVManifestParseError.corrupt("layer \(i) dtype invalid")
            }
            layers.append(KVLayerRecord(
                layerIndex: li, classID: cls, layoutVersion: lv,
                ndim: ndim, dims: dims, dtype: dtype))
        }

        // chunks[]
        guard let rawChunks = object["chunks"] as? [Any] else {
            throw KVManifestParseError.corrupt("chunks not an array")
        }
        guard rawChunks.count >= 1, rawChunks.count <= KVDiskCacheFormat.maxChunks else {
            throw KVManifestParseError.corrupt("chunk count out of bound")
        }
        var chunks: [KVChunkRecord] = []
        chunks.reserveCapacity(rawChunks.count)
        for (i, rawChunk) in rawChunks.enumerated() {
            guard let chunk = rawChunk as? [String: Any] else {
                throw KVManifestParseError.corrupt("chunk \(i) not an object")
            }
            guard Set(chunk.keys) == ["ordinal", "ct_length", "nonce"] else {
                throw KVManifestParseError.corrupt("chunk \(i) field set mismatch")
            }
            guard let ordinal = (chunk["ordinal"] as? NSNumber).flatMap({ isIntegral($0) ? $0.intValue : nil }),
                  ordinal >= 0, ordinal < KVDiskCacheFormat.maxChunks else {
                throw KVManifestParseError.corrupt("chunk \(i) ordinal invalid")
            }
            guard let ctLength = (chunk["ct_length"] as? NSNumber).flatMap({ isIntegral($0) ? $0.intValue : nil }),
                  ctLength >= 0, ctLength <= KVDiskCacheFormat.maxChunkCiphertextBytes else {
                throw KVManifestParseError.corrupt("chunk \(i) ct_length invalid")
            }
            guard let nonceHex = chunk["nonce"] as? String,
                  let nonce = KVHex.decode(nonceHex),
                  nonce.count == KVDiskCacheFormat.chunkNonceBytes,
                  nonceHex == nonceHex.lowercased() else {
                throw KVManifestParseError.corrupt("chunk \(i) nonce invalid")
            }
            chunks.append(KVChunkRecord(ordinal: ordinal, ctLength: ctLength, nonce: nonce))
        }
        // ordinals contiguous 0..count-1, no gaps or duplicates
        for (i, chunk) in chunks.enumerated() where chunk.ordinal != i {
            throw KVManifestParseError.corrupt("chunk ordinals not contiguous from 0")
        }

        let decodedLength = try intVal("decoded_length", max: Int.max)
        let blobLength = try intVal("blob_length", max: max(0, maxBlobBytes))

        // decoded_length recomputation (FR-KVP4c): equals §5a equation from geometry.
        let geometry = layers.map {
            KVDiskCacheFormat.LayerGeometryInput(classID: $0.classID, ndim: $0.ndim, dims: $0.dims, dtype: $0.dtype)
        }
        guard let recomputed = KVDiskCacheFormat.decodedLength(tokenCount: tokenCount, layers: geometry),
              recomputed == decodedLength else {
            throw KVManifestParseError.corrupt("decoded_length does not recompute")
        }

        // blob_length equals Σ frame sizes, AND Σ ct_length equals decoded_length
        // (HIGH-6). GCM ciphertext length == plaintext length, so the chunk ciphertext
        // bytes must sum to exactly the declared decoded payload length. Both checks
        // run in the parser, BEFORE any blob/plaintext allocation, so an incoherent
        // manifest is rejected as corrupt before a single payload byte is read.
        var frameTotal = 0
        var ctTotal = 0
        for chunk in chunks {
            // magic(4)+ordinal(4)+ct_length(4)+nonce(12)+ciphertext(ct_length)+tag(16)
            let framing = 4 + 4 + 4 + KVDiskCacheFormat.chunkNonceBytes + KVDiskCacheFormat.gcmTagBytes
            let (withCipher, o1) = chunk.ctLength.addingReportingOverflow(framing)
            guard !o1 else { throw KVManifestParseError.corrupt("frame size overflow") }
            let (sum, o2) = frameTotal.addingReportingOverflow(withCipher)
            guard !o2 else { throw KVManifestParseError.corrupt("blob length overflow") }
            frameTotal = sum
            let (ctSum, o3) = ctTotal.addingReportingOverflow(chunk.ctLength)
            guard !o3 else { throw KVManifestParseError.corrupt("ct_length overflow") }
            ctTotal = ctSum
        }
        guard frameTotal == blobLength else {
            throw KVManifestParseError.corrupt("blob_length disagrees with chunk frame sizes")
        }
        guard ctTotal == decodedLength else {
            throw KVManifestParseError.corrupt("Σ ct_length disagrees with decoded_length")
        }

        return KVDiskManifest(
            schemaID: try str("schema_id"),
            codecID: try str("codec_id"),
            namespaceID: try str("namespace_id"),
            keyEpoch: try intVal("key_epoch"),
            indexHMAC: try hex("index_hmac"),
            generation: try intVal("generation"),
            commitSequence: try intVal("commit_sequence"),
            purgeGeneration: try intVal("purge_generation"),
            requestModel: try str("request_model"),
            servedModelID: try str("served_model_id"),
            modelSHA256: try hex("model_sha256"),
            catalogRevision: try str("catalog_revision"),
            tokenizerID: try str("tokenizer_id"),
            tokenizerConfigSHA256: try hex("tokenizer_config_sha256"),
            chatTemplateSHA256: try hex("chat_template_sha256"),
            abiEpoch: try intVal("abi_epoch"),
            mlxSwiftLMRevision: try str("mlx_swift_lm_revision"),
            mlxVersion: try str("mlx_version"),
            cacheClass: try str("cache_class"),
            layerCount: layerCount,
            layers: layers,
            kvBits: try optInt("kv_bits"),
            kvGroupSize: try optInt("kv_group_size"),
            kvQuantMode: try optStr("kv_quant_mode"),
            kvQuantPolicy: try optStr("kv_quant_policy"),
            decodePath: try str("decode_path"),
            tokenCount: tokenCount,
            createdAtMillis: try millis("created_at"),
            eligibleUntilMillis: try millis("eligible_until"),
            decodedLength: decodedLength,
            chunks: chunks,
            blobLength: blobLength,
            blobSHA256: try hex("blob_sha256"))
    }

    private static func isIntegral(_ n: NSNumber) -> Bool {
        if isBool(n) { return false }
        // Reject non-integral doubles (e.g. 1.5); accept whole-number NSNumbers.
        let type = String(cString: n.objCType)
        if type == "d" || type == "f" {
            return n.doubleValue.rounded() == n.doubleValue
                && abs(n.doubleValue) <= 9_007_199_254_740_992  // 2^53
        }
        return true
    }

    private static func isBool(_ n: NSNumber) -> Bool {
        n === (kCFBooleanTrue as NSNumber) || n === (kCFBooleanFalse as NSNumber)
            || CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Minimal recursive duplicate-key scan (no dependency on other files).
    private static func scanNoDuplicateKeys(_ data: Data) throws {
        var scanner = KVJSONDuplicateKeyScanner(data)
        try scanner.validate()
    }
}

/// Self-contained duplicate-key scanner mirroring the repo's strict-JSON pattern;
/// rejects duplicate object keys at any nesting level and trailing bytes.
private struct KVJSONDuplicateKeyScanner {
    private let bytes: [UInt8]
    private var index = 0
    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func validate() throws {
        skipWS()
        try parseValue()
        skipWS()
        guard index == bytes.count else { throw KVManifestParseError.corrupt("trailing bytes") }
    }
    private mutating func parseValue() throws {
        guard index < bytes.count else { throw KVManifestParseError.corrupt("unexpected end") }
        switch bytes[index] {
        case 0x7B: try parseObject()
        case 0x5B: try parseArray()
        case 0x22: _ = try parseString()
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        default: try parseNumber()
        }
    }
    private mutating func parseObject() throws {
        index += 1; skipWS()
        var keys = Set<String>()
        if consume(0x7D) { return }
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else { throw KVManifestParseError.corrupt("object key") }
            let key = try parseString()
            guard keys.insert(key).inserted else { throw KVManifestParseError.corrupt("duplicate key \(key)") }
            skipWS()
            guard consume(0x3A) else { throw KVManifestParseError.corrupt("colon") }
            skipWS(); try parseValue(); skipWS()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw KVManifestParseError.corrupt("separator") }
            skipWS()
        }
    }
    private mutating func parseArray() throws {
        index += 1; skipWS()
        if consume(0x5D) { return }
        while true {
            try parseValue(); skipWS()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw KVManifestParseError.corrupt("array separator") }
            skipWS()
        }
    }
    private mutating func parseString() throws -> String {
        let start = index; index += 1; var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if escaped { escaped = false; continue }
            if byte == 0x5C { escaped = true }
            else if byte == 0x22 {
                let token = Data(bytes[start ..< index])
                guard let decoded = try? JSONDecoder().decode(String.self, from: token) else {
                    throw KVManifestParseError.corrupt("string")
                }
                return decoded
            } else if byte < 0x20 { throw KVManifestParseError.corrupt("control char") }
        }
        throw KVManifestParseError.corrupt("unterminated string")
    }
    private mutating func parseNumber() throws {
        let start = index
        while index < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw KVManifestParseError.corrupt("number") }
        let token = Data(bytes[start ..< index])
        guard (try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed])) is NSNumber else {
            throw KVManifestParseError.corrupt("number")
        }
    }
    private mutating func literal(_ s: String) throws {
        let expected = Array(s.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index ..< index + expected.count]) == expected else {
            throw KVManifestParseError.corrupt("literal")
        }
        index += expected.count
    }
    private mutating func skipWS() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }
    private mutating func consume(_ b: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == b else { return false }
        index += 1; return true
    }
}

// MARK: - Envelope validation (FR-KVP4 categories a, a', b)

enum KVEnvelopeValidator {
    /// Validate a structurally-parsed manifest against the live runtime identity.
    /// Categories: identity completeness → integrity (seq-axis coherence) → lifecycle
    /// (expiry) → exact-match identity (a) → fence (a′). Single-fault fixtures each
    /// resolve to exactly their §5 reason code. `nowMillis` is the evaluation
    /// timestamp already advanced past the clock high-water (FR-KVP10).
    static func validate(
        _ manifest: KVDiskManifest,
        runtime: KVRuntimeIdentity,
        nowMillis: Int
    ) -> KVReadOutcome {
        // Live identity completeness (FR-KVP4): a missing live input cannot compare.
        guard let liveModelSHA = runtime.modelSHA256 else {
            return .miss(.diskMissIdentityUnavailable, .identityUnavailable)
        }

        // Integrity: sequence axis of each layer must equal token_count (row 13).
        for geometry in runtime.layers {
            guard let record = manifest.layers.first(where: { $0.layerIndex == geometry.layerIndex }) else {
                return .miss(.diskMissEnvelope)   // layer set mismatch (row 6)
            }
            guard geometry.sequenceAxis >= 0, geometry.sequenceAxis < record.dims.count else {
                return .miss(.diskMissCorrupt)
            }
            guard record.dims[geometry.sequenceAxis] == manifest.tokenCount else {
                return .miss(.diskMissCorrupt)
            }
        }

        // Lifecycle: expiry (row 15).
        guard nowMillis <= manifest.eligibleUntilMillis else {
            return .miss(.diskMissExpired)
        }

        // (a) exact-match identity fields ------------------------------------------
        // 1: schema/codec IDs known (row 9)
        guard manifest.schemaID == KVDiskCacheFormat.manifestSchemaID,
              manifest.codecID == KVDiskCacheFormat.codecID else {
            return .miss(.diskMissEnvelope)
        }
        // 2: namespace + key epoch (row 10)
        guard manifest.namespaceID == runtime.namespaceID,
              manifest.keyEpoch == runtime.keyEpoch else {
            return .miss(.diskMissEnvelope)
        }
        // 3: HMAC index (row 11)
        guard manifest.indexHMAC == runtime.indexHMAC else {
            return .miss(.diskMissEnvelope)
        }
        // creation_time in the future (row 14)
        guard manifest.createdAtMillis <= nowMillis else {
            return .miss(.diskMissEnvelope)
        }
        // 4: predicate model string + served canonical identity (rows 2,3)
        guard manifest.requestModel == runtime.requestModel,
              manifest.servedModelID == runtime.servedModelID,
              manifest.modelSHA256 == liveModelSHA,
              manifest.catalogRevision == runtime.catalogRevision else {
            return .miss(.diskMissEnvelope)
        }
        // 5: tokenizer + template identities (row 4)
        guard manifest.tokenizerID == runtime.tokenizerID,
              manifest.tokenizerConfigSHA256 == runtime.tokenizerConfigSHA256,
              manifest.chatTemplateSHA256 == runtime.chatTemplateSHA256 else {
            return .miss(.diskMissEnvelope)
        }
        // 6: serialization ABI epoch + pinned revisions (row 8)
        guard manifest.abiEpoch == runtime.abiEpoch,
              manifest.mlxSwiftLMRevision == runtime.mlxSwiftLMRevision,
              manifest.mlxVersion == runtime.mlxVersion else {
            return .miss(.diskMissEnvelope)
        }
        // 7: cache class allowlist + class + layer count + per-layer geometry (rows 6,7)
        guard KVDiskCacheFormat.allowlistedCacheClasses.contains(manifest.cacheClass),
              manifest.cacheClass == runtime.cacheClass,
              manifest.layerCount == runtime.layerCount,
              manifest.layers.count == runtime.layers.count else {
            return .miss(.diskMissEnvelope)
        }
        for geometry in runtime.layers {
            guard let record = manifest.layers.first(where: { $0.layerIndex == geometry.layerIndex }),
                  record.classID == geometry.classID,
                  record.layoutVersion == geometry.layoutVersion,
                  record.ndim == geometry.ndim,
                  record.dtype == geometry.dtype,
                  record.dims.count == geometry.dims.count else {
                return .miss(.diskMissEnvelope)
            }
            for axis in 0 ..< record.dims.count where axis != geometry.sequenceAxis {
                guard record.dims[axis] == geometry.dims[axis] else {
                    return .miss(.diskMissEnvelope)
                }
            }
        }
        // 9: kv quantization tuple, incl. null-vs-number distinction (row 5)
        guard manifest.kvBits == runtime.kvBits,
              manifest.kvGroupSize == runtime.kvGroupSize,
              manifest.kvQuantMode == runtime.kvQuantMode,
              manifest.kvQuantPolicy == runtime.kvQuantPolicy else {
            return .miss(.diskMissEnvelope)
        }
        // 10: decode path class ordinary (row 12)
        guard manifest.decodePath == runtime.decodePath else {
            return .miss(.diskMissEnvelope)
        }

        // (a′) fence field: purge generation ≥ live high-watermark (row 19)
        guard manifest.purgeGeneration >= runtime.liveHighWatermark else {
            return .miss(.diskMissTombstoned)
        }

        return .ok(manifest)
    }
}

// MARK: - Payload codec (kvsurv-codec-v1) — self-delimiting plaintext

/// One layer's decrypted state to (de)serialize.
struct KVLayerPayload: Sendable, Equatable {
    let layerIndex: Int
    let classID: String
    let ndim: Int
    let dims: [Int]
    let dtype: KVCodecDType
    let cacheOffset: Int
    let keyBytes: Data
    let valueBytes: Data
}

/// The full decrypted payload: canonical token sequence + per-layer state.
struct KVDecodedPayload: Sendable, Equatable {
    let tokens: [Int32]
    let layers: [KVLayerPayload]
}

enum KVPayloadCodec {
    /// Encode tokens + layers into the self-delimiting codec-v1 plaintext.
    static func encode(tokens: [Int32], layers: [KVLayerPayload]) throws -> Data {
        // Concatenate the ordered segments. Byte-identical to `encodeSegments` joined.
        var out = Data()
        for segment in try encodeSegments(tokens: tokens, layers: layers) { out.append(segment) }
        return out
    }

    /// Encode tokens + layers into an ORDERED list of codec-v1 byte segments whose
    /// concatenation is exactly the `encode(...)` plaintext (HIGH-1). The large
    /// per-layer key/value tensor bytes are appended as references to the caller's
    /// existing `Data` (no copy); only the small framing headers are freshly built. A
    /// streaming sealer consumes these segments chunk-by-chunk so the whole plaintext
    /// is never materialized as one buffer.
    static func encodeSegments(tokens: [Int32], layers: [KVLayerPayload]) throws -> [Data] {
        var segments: [Data] = []
        var header = Data()
        header.append(try KVByteWriter.u32LE(tokens.count))
        for token in tokens { header.append(KVByteWriter.i32LE(token)) }
        segments.append(header)
        for layer in layers {
            guard layer.dims.count == layer.ndim else { throw KVFormatError.overflow }
            guard layer.ndim >= 0, layer.ndim <= 255 else { throw KVFormatError.overflow }
            // element-count consistency guard: byte lengths must equal Π(dims)·size
            let expected = try expectedTensorBytes(dims: layer.dims, dtype: layer.dtype)
            guard layer.keyBytes.count == expected, layer.valueBytes.count == expected else {
                throw KVFormatError.encodeFailed("tensor byte length disagrees with dims")
            }
            var pre = Data()
            pre.append(try KVByteWriter.u32LE(layer.layerIndex))
            let classBytes = Data(layer.classID.utf8)
            pre.append(try KVByteWriter.u16LE(classBytes.count))
            pre.append(classBytes)
            pre.append(Data([UInt8(layer.ndim)]))
            for dim in layer.dims { pre.append(try KVByteWriter.u64LE(dim)) }
            pre.append(Data([UInt8(layer.dtype.rawValue)]))
            pre.append(try KVByteWriter.u64LE(layer.cacheOffset))
            pre.append(try KVByteWriter.u64LE(layer.keyBytes.count))
            segments.append(pre)
            segments.append(layer.keyBytes)
            segments.append(try KVByteWriter.u64LE(layer.valueBytes.count))
            segments.append(layer.valueBytes)
        }
        return segments
    }

    /// Decode codec-v1 plaintext. `expectedDecodedLength` is the manifest's
    /// recomputed `decoded_length`; the consumed byte total MUST equal both it and
    /// the input length (§5a self-delimiting requirement). Any shortfall/overrun,
    /// bound violation, or inconsistency is a corrupt failure.
    static func decode(_ data: Data, expectedDecodedLength: Int, layerCount: Int) throws -> KVDecodedPayload {
        guard data.count == expectedDecodedLength else {
            throw KVManifestParseError.corrupt("payload length disagrees with decoded_length")
        }
        var reader = KVByteReader(data)
        guard let tokenCount = reader.readU32LE(), tokenCount <= KVDiskCacheFormat.maxTokenCount else {
            throw KVManifestParseError.corrupt("token count invalid")
        }
        var tokens: [Int32] = []
        tokens.reserveCapacity(tokenCount)
        for _ in 0 ..< tokenCount {
            guard let token = reader.readI32LE() else {
                throw KVManifestParseError.corrupt("token array truncated")
            }
            tokens.append(token)
        }
        var layers: [KVLayerPayload] = []
        layers.reserveCapacity(layerCount)
        for _ in 0 ..< layerCount {
            guard let layerIndex = reader.readU32LE(), layerIndex <= KVDiskCacheFormat.maxLayers else {
                throw KVManifestParseError.corrupt("layer_index invalid")
            }
            guard let classLen = reader.readU16LE(), classLen <= KVDiskCacheFormat.maxStringBytes,
                  let classData = reader.readBytes(classLen),
                  let classID = String(data: classData, encoding: .utf8) else {
                throw KVManifestParseError.corrupt("class id invalid")
            }
            guard let ndim = reader.readU8(), ndim <= KVDiskCacheFormat.maxNdim else {
                throw KVManifestParseError.corrupt("ndim invalid")
            }
            var dims: [Int] = []
            dims.reserveCapacity(ndim)
            for _ in 0 ..< ndim {
                guard let dim = reader.readU64LE(), UInt64(dim) <= KVDiskCacheFormat.maxDim else {
                    throw KVManifestParseError.corrupt("dim invalid")
                }
                dims.append(dim)
            }
            guard let dtypeRaw = reader.readU8(), let dtype = KVCodecDType(rawValue: dtypeRaw) else {
                throw KVManifestParseError.corrupt("dtype invalid")
            }
            guard let cacheOffset = reader.readU64LE() else {
                throw KVManifestParseError.corrupt("cache_offset invalid")
            }
            let expected = try? expectedTensorBytes(dims: dims, dtype: dtype)
            guard let expectedBytes = expected else {
                throw KVManifestParseError.corrupt("tensor geometry overflow")
            }
            guard let keyLen = reader.readU64LE(), keyLen == expectedBytes,
                  let keyBytes = reader.readBytes(keyLen) else {
                throw KVManifestParseError.corrupt("key tensor invalid")
            }
            guard let valLen = reader.readU64LE(), valLen == expectedBytes,
                  let valBytes = reader.readBytes(valLen) else {
                throw KVManifestParseError.corrupt("value tensor invalid")
            }
            layers.append(KVLayerPayload(
                layerIndex: layerIndex, classID: classID, ndim: ndim, dims: dims,
                dtype: dtype, cacheOffset: cacheOffset, keyBytes: keyBytes, valueBytes: valBytes))
        }
        guard reader.isAtEnd else {
            throw KVManifestParseError.corrupt("trailing payload bytes")
        }
        return KVDecodedPayload(tokens: tokens, layers: layers)
    }

    static func expectedTensorBytes(dims: [Int], dtype: KVCodecDType) throws -> Int {
        var elements = 1
        for d in dims {
            guard d >= 0 else { throw KVFormatError.overflow }
            let (r, o) = elements.multipliedReportingOverflow(by: d)
            guard !o else { throw KVFormatError.overflow }
            elements = r
        }
        let (bytes, o) = elements.multipliedReportingOverflow(by: dtype.byteSize)
        guard !o else { throw KVFormatError.overflow }
        return bytes
    }
}

/// Incremental codec-v1 decoder (HIGH-1 streaming read). Fed one decrypted chunk
/// plaintext at a time; parses and emits complete token-header / layer records as soon
/// as their bytes are available, dropping consumed bytes so the whole plaintext is
/// never held. The bounds/consistency checks and error mapping mirror
/// `KVPayloadCodec.decode` exactly, so a payload that round-trips one way round-trips
/// the other. `residualBytes` (unconsumed scratch) and `decodedBytes` (emitted layer
/// key+value bytes) let the store track a true live-memory high-water.
final class KVStreamingPayloadDecoder {
    private var residual = Data()
    private var tokens: [Int32]?
    private var layers: [KVLayerPayload] = []
    private let expectedDecodedLength: Int
    private let layerCount: Int
    private var consumedTotal = 0
    private(set) var decodedBytes = 0
    /// Item 4 (FR-KVP9): the true internal read-side high-water — the maximum, over
    /// every parse checkpoint, of (unconsumed residual + materialized layer bytes)
    /// co-resident at that instant. Sampled AFTER each layer materializes (the source
    /// residual bytes are still live until the subsequent `commit` drops them), so it
    /// captures the frame ⋂ residual ⋂ tensor co-residency the pre-decode measurement
    /// missed. The store adds the still-held frame and enforces the ceiling on it.
    private(set) var peakBytes = 0

    var residualBytes: Int { residual.count }

    init(expectedDecodedLength: Int, layerCount: Int) {
        self.expectedDecodedLength = expectedDecodedLength
        self.layerCount = layerCount
        layers.reserveCapacity(layerCount)
    }

    /// Append a decrypted chunk plaintext and parse every complete record now available.
    func feed(_ data: Data) throws {
        guard consumedTotal + residual.count + data.count <= expectedDecodedLength else {
            throw KVManifestParseError.corrupt("payload length exceeds decoded_length")
        }
        if residual.isEmpty { residual = data } else { residual.append(data) }
        // Account the residual-only co-residency (before any layer parses this chunk).
        peakBytes = max(peakBytes, residual.count + decodedBytes)
        try drain()
    }

    /// Finalize: require the token header, all declared layers, exact byte consumption,
    /// and no trailing bytes — the §5a self-delimiting guarantees.
    func finish() throws -> KVDecodedPayload {
        try drain()
        guard let tokens else { throw KVManifestParseError.corrupt("token header absent") }
        guard layers.count == layerCount else {
            throw KVManifestParseError.corrupt("layer count short")
        }
        guard residual.isEmpty else { throw KVManifestParseError.corrupt("trailing payload bytes") }
        guard consumedTotal == expectedDecodedLength else {
            throw KVManifestParseError.corrupt("payload length disagrees with decoded_length")
        }
        return KVDecodedPayload(tokens: tokens, layers: layers)
    }

    /// Parse complete records from the front of `residual`, checkpointing after each so a
    /// partial record is left buffered for the next `feed`.
    private func drain() throws {
        while true {
            var reader = KVByteReader(residual)
            if tokens == nil {
                guard let tokenCount = reader.readU32LE() else { return }
                guard tokenCount <= KVDiskCacheFormat.maxTokenCount else {
                    throw KVManifestParseError.corrupt("token count invalid")
                }
                var parsed: [Int32] = []
                parsed.reserveCapacity(tokenCount)
                for _ in 0 ..< tokenCount {
                    guard let token = reader.readI32LE() else { return }   // need more bytes
                    parsed.append(token)
                }
                tokens = parsed
                commit(consumed: reader.offset)
                continue
            }
            if layers.count >= layerCount { return }
            guard let layer = try parseLayer(&reader) else { return }   // incomplete → wait
            layers.append(layer)
            decodedBytes += layer.keyBytes.count + layer.valueBytes.count
            // Item 4: sample the true co-resident peak AT materialization, BEFORE
            // `commit` drops the consumed source bytes — residual still holds the just
            // -parsed layer's source, so this counts source ⋂ tensor simultaneously.
            peakBytes = max(peakBytes, residual.count + decodedBytes)
            commit(consumed: reader.offset)
        }
    }

    /// Attempt to parse one layer record. Returns nil (no consumption) if `residual`
    /// does not yet hold the whole record; throws on a structural violation.
    private func parseLayer(_ reader: inout KVByteReader) throws -> KVLayerPayload? {
        guard let layerIndex = reader.readU32LE() else { return nil }
        guard layerIndex <= KVDiskCacheFormat.maxLayers else {
            throw KVManifestParseError.corrupt("layer_index invalid")
        }
        guard let classLen = reader.readU16LE() else { return nil }
        guard classLen <= KVDiskCacheFormat.maxStringBytes else {
            throw KVManifestParseError.corrupt("class id invalid")
        }
        guard let classData = reader.readBytes(classLen) else { return nil }
        guard let classID = String(data: classData, encoding: .utf8) else {
            throw KVManifestParseError.corrupt("class id invalid")
        }
        guard let ndim = reader.readU8() else { return nil }
        guard ndim <= KVDiskCacheFormat.maxNdim else {
            throw KVManifestParseError.corrupt("ndim invalid")
        }
        var dims: [Int] = []
        dims.reserveCapacity(ndim)
        for _ in 0 ..< ndim {
            guard let dim = reader.readU64LE() else { return nil }
            guard UInt64(dim) <= KVDiskCacheFormat.maxDim else {
                throw KVManifestParseError.corrupt("dim invalid")
            }
            dims.append(dim)
        }
        guard let dtypeRaw = reader.readU8() else { return nil }
        guard let dtype = KVCodecDType(rawValue: dtypeRaw) else {
            throw KVManifestParseError.corrupt("dtype invalid")
        }
        guard let cacheOffset = reader.readU64LE() else { return nil }
        let expected: Int
        do { expected = try KVPayloadCodec.expectedTensorBytes(dims: dims, dtype: dtype) }
        catch { throw KVManifestParseError.corrupt("tensor geometry overflow") }
        guard let keyLen = reader.readU64LE() else { return nil }
        guard keyLen == expected else { throw KVManifestParseError.corrupt("key tensor invalid") }
        guard let keyBytes = reader.readBytes(keyLen) else { return nil }
        guard let valLen = reader.readU64LE() else { return nil }
        guard valLen == expected else { throw KVManifestParseError.corrupt("value tensor invalid") }
        guard let valBytes = reader.readBytes(valLen) else { return nil }
        return KVLayerPayload(
            layerIndex: layerIndex, classID: classID, ndim: ndim, dims: dims,
            dtype: dtype, cacheOffset: cacheOffset, keyBytes: keyBytes, valueBytes: valBytes)
    }

    private func commit(consumed: Int) {
        consumedTotal += consumed
        // Rebase to a fresh 0-indexed Data so subsequent readers/appends never depend on
        // a slice's non-zero startIndex.
        residual = consumed >= residual.count ? Data() : Data(residual.dropFirst(consumed))
    }
}

// MARK: - Chunk frame encode/decode ("KVS1" framing, §5a blob)

struct KVParsedFrame: Sendable, Equatable {
    let ordinal: Int
    let nonce: Data
    let ciphertext: Data
    let tag: Data
}

/// Forward cursor over an ordered list of plaintext segments, yielding fixed-size
/// chunk buffers on demand (HIGH-1 streaming seal). At most one chunk buffer plus a
/// reference to the current source segment is resident; the whole plaintext is never
/// concatenated. The concatenation of every `next(_:)` result equals the concatenated
/// segments, so the on-disk chunk framing is byte-identical to the non-streaming path.
struct KVSegmentCursor {
    private let segments: [Data]
    private var segIndex = 0
    private var segOffset = 0
    private(set) var totalRemaining: Int

    init(_ segments: [Data]) {
        self.segments = segments
        self.totalRemaining = segments.reduce(0) { $0 + $1.count }
    }

    /// Pull exactly `count` bytes (or fewer only when the source is exhausted).
    mutating func next(_ count: Int) -> Data {
        var out = Data(capacity: count)
        var need = count
        while need > 0, segIndex < segments.count {
            let seg = segments[segIndex]
            let available = seg.count - segOffset
            if available <= 0 { segIndex += 1; segOffset = 0; continue }
            let take = min(need, available)
            let start = seg.startIndex + segOffset
            out.append(seg[start ..< start + take])
            segOffset += take
            need -= take
            if segOffset >= seg.count { segIndex += 1; segOffset = 0 }
        }
        totalRemaining -= out.count
        return out
    }
}

enum KVChunkFrame {
    /// Assemble one chunk frame: magic ‖ u32LE ordinal ‖ u32LE ct_length ‖ nonce(12)
    /// ‖ ciphertext ‖ tag(16).
    static func encode(ordinal: Int, nonce: Data, ciphertext: Data, tag: Data) throws -> Data {
        guard nonce.count == KVDiskCacheFormat.chunkNonceBytes else {
            throw KVFormatError.encodeFailed("nonce must be 12 bytes")
        }
        guard tag.count == KVDiskCacheFormat.gcmTagBytes else {
            throw KVFormatError.encodeFailed("tag must be 16 bytes")
        }
        var out = KVDiskCacheFormat.chunkMagic
        out.append(try KVByteWriter.u32LE(ordinal))
        out.append(try KVByteWriter.u32LE(ciphertext.count))
        out.append(nonce)
        out.append(ciphertext)
        out.append(tag)
        return out
    }

    /// Parse concatenated chunk frames. Verifies magic, contiguous ordinals from 0,
    /// and that frame nonce/ct_length agree with the manifest chunk table. Returns
    /// frames in ordinal order or throws corrupt.
    static func decodeBlob(_ data: Data, chunkTable: [KVChunkRecord]) throws -> [KVParsedFrame] {
        var frames: [KVParsedFrame] = []
        frames.reserveCapacity(chunkTable.count)
        try forEachFrame(data, chunkTable: chunkTable) { frames.append($0) }
        return frames
    }

    /// Streaming frame decode (HIGH-6): parse + verify one frame at a time and hand it
    /// to `body`, so the caller can AEAD-open and materialize per chunk WITHOUT
    /// retaining the full array of parsed frames alongside the accumulating plaintext.
    static func forEachFrame(
        _ data: Data, chunkTable: [KVChunkRecord], _ body: (KVParsedFrame) throws -> Void
    ) throws {
        var reader = KVByteReader(data)
        for expected in chunkTable {
            guard let magic = reader.readBytes(4), magic == KVDiskCacheFormat.chunkMagic else {
                throw KVManifestParseError.corrupt("chunk frame magic mismatch")
            }
            guard let ordinal = reader.readU32LE(), ordinal == expected.ordinal else {
                throw KVManifestParseError.corrupt("chunk frame ordinal mismatch")
            }
            guard let ctLength = reader.readU32LE(), ctLength == expected.ctLength,
                  ctLength <= KVDiskCacheFormat.maxChunkCiphertextBytes else {
                throw KVManifestParseError.corrupt("chunk frame ct_length mismatch")
            }
            guard let nonce = reader.readBytes(KVDiskCacheFormat.chunkNonceBytes),
                  nonce == expected.nonce else {
                // Manifest chunk-table nonce is authoritative; frame must equal it.
                throw KVManifestParseError.corrupt("chunk frame nonce mismatch")
            }
            guard let ciphertext = reader.readBytes(ctLength),
                  let tag = reader.readBytes(KVDiskCacheFormat.gcmTagBytes) else {
                throw KVManifestParseError.corrupt("chunk frame truncated")
            }
            try body(KVParsedFrame(ordinal: ordinal, nonce: nonce, ciphertext: ciphertext, tag: tag))
        }
        guard reader.isAtEnd else {
            throw KVManifestParseError.corrupt("trailing blob bytes")
        }
    }
}
