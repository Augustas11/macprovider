import CryptoKit
import Foundation
@testable import macprovider_cli
import XCTest

/// SPEC-037 §5a format-level conformance: JCS/AAD golden fixtures, decoded_length
/// numeric golden vectors, chunk-frame round trips, per-field envelope mutations →
/// reason codes, parsing bounds, composed/decomposed Unicode key canonicalization,
/// and the HKDF derivation conformance vector.
final class KVDiskCacheFormatTests: XCTestCase {

    // MARK: - decoded_length golden vectors (§5a exact equation)

    func testDecodedLengthGoldenVectors() {
        // Empty payload: 4 (token-count word) + 0.
        XCTAssertEqual(KVDiskCacheFormat.decodedLength(tokenCount: 0, layers: []), 4)

        // One f16 layer, dims=[1,2,2,2] (Π=8), classID 13 bytes, token_count=2.
        //   token part  = 4 + 4·2 = 12
        //   framing     = 4 + 2 + 13 + 1 + 8·4 + 1 + 8 = 61
        //   tensors     = 2·(8 + 8·2) = 48
        //   total       = 12 + 61 + 48 = 121
        let one = KVDiskCacheFormat.LayerGeometryInput(classID: "KVCacheSimple", ndim: 4, dims: [1, 2, 2, 2], dtype: .f16)
        XCTAssertEqual(KVDiskCacheFormat.decodedLength(tokenCount: 2, layers: [one]), 121)

        // Two f32 layers, dims=[1,4,5,8] (Π=160), token_count=5.
        //   token part  = 4 + 4·5 = 24
        //   framing/lyr = 61 ; tensors/lyr = 2·(8 + 160·4) = 1296 ; layer = 1357
        //   total       = 24 + 2·1357 = 2738
        let big = KVDiskCacheFormat.LayerGeometryInput(classID: "KVCacheSimple", ndim: 4, dims: [1, 4, 5, 8], dtype: .f32)
        XCTAssertEqual(KVDiskCacheFormat.decodedLength(tokenCount: 5, layers: [big, big]), 2738)
    }

    func testDecodedLengthOverflowReturnsNil() {
        let huge = KVDiskCacheFormat.LayerGeometryInput(
            classID: "KVCacheSimple", ndim: 4, dims: [Int(Int32.max), Int(Int32.max), Int(Int32.max), Int(Int32.max)], dtype: .f32)
        XCTAssertNil(KVDiskCacheFormat.decodedLength(tokenCount: 1, layers: [huge]))
    }

    // MARK: - JCS golden + AAD projection

    func testManifestJCSIsDeterministicAndKeySorted() throws {
        let manifest = Self.referenceManifest()
        let a = try manifest.jcsCanonicalData()
        let b = try manifest.jcsCanonicalData()
        XCTAssertEqual(a, b, "JCS canonicalization must be deterministic")

        // Top-level object keys are emitted in sorted order.
        let s = String(data: a, encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("{\"abi_epoch\":"), "first sorted key must be abi_epoch, got: \(s.prefix(40))")
        XCTAssertTrue(s.contains("\"blob_sha256\":"))
    }

    func testJCSGoldenDigestPin() throws {
        // Regression pin: the canonical byte layout for the reference manifest must
        // not drift silently. Update only on an intentional §5a format change.
        let manifest = Self.referenceManifest()
        let digest = SHA256.hash(data: try manifest.jcsCanonicalData()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "6643d59f87408e39bd362b64cdd816bb2f68020cce9bcdf2f6e1b2d86b2ef58e")
    }

    func testAADOmitsBlobSHAAndAppendsBigEndianOrdinal() throws {
        let manifest = Self.referenceManifest()
        let aad = try manifest.aad(ordinal: 0x01020304)
        // The AAD base uses the RAW code-point JCS path (M-10).
        let base = try RFC8785JCS.canonicalStringRawStrings(manifest.jcsValue(omitBlobSHA256: true))
        let baseData = Data(base.utf8)
        // blob_sha256 must not appear in the AAD projection.
        XCTAssertFalse(base.contains("blob_sha256"))
        // AAD == base ‖ BE32(ordinal).
        XCTAssertEqual(aad.count, baseData.count + 4)
        XCTAssertEqual(Array(aad.suffix(4)), [0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(aad.prefix(baseData.count), baseData)
    }

    /// M-10: the KV manifest codec must NOT NFC-normalize string values, so a
    /// composed vs decomposed identity field yields DISTINCT manifest bytes and
    /// DISTINCT AAD. (The shared error-envelope JCS normalizes; the KV codec uses
    /// the raw code-point path.)
    func testManifestCodecPreservesComposedVsDecomposed() throws {
        // U+00E9 (é, composed) vs U+0065 U+0301 (e + combining acute, decomposed).
        let composed = Self.mutate(Self.referenceManifest()) { $0.servedModelID = "caf\u{00E9}-model" }
        let decomposed = Self.mutate(Self.referenceManifest()) { $0.servedModelID = "cafe\u{0301}-model" }
        let cBytes = try composed.jcsCanonicalData()
        let dBytes = try decomposed.jcsCanonicalData()
        XCTAssertNotEqual(cBytes, dBytes, "composed and decomposed identities must not collapse in the manifest")
        let cAAD = try composed.aad(ordinal: 0)
        let dAAD = try decomposed.aad(ordinal: 0)
        XCTAssertNotEqual(cAAD, dAAD, "composed and decomposed identities must not collapse in the AAD")
    }

    // MARK: - Manifest parse round trip + bounds

    func testManifestEncodeDecodeRoundTrip() throws {
        let manifest = Self.consistentManifest()
        let data = try KVManifestCodec.encode(manifest)
        let decoded = try KVManifestCodec.decode(data, maxBlobBytes: 2 * 1024 * 1024 * 1024 - 1)
        XCTAssertEqual(decoded, manifest)
    }

    func testManifestRejectsUnknownField() throws {
        let manifest = Self.consistentManifest()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try KVManifestCodec.encode(manifest)) as? [String: Any])
        object["surprise"] = 1
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try KVManifestCodec.decode(data, maxBlobBytes: Int.max))
    }

    func testManifestRejectsMissingField() throws {
        let manifest = Self.consistentManifest()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try KVManifestCodec.encode(manifest)) as? [String: Any])
        object.removeValue(forKey: "token_count")
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try KVManifestCodec.decode(data, maxBlobBytes: Int.max))
    }

    func testManifestRejectsDuplicateKey() {
        let dup = Data(#"{"schema_id":"a","schema_id":"b"}"#.utf8)
        XCTAssertThrowsError(try KVManifestCodec.decode(dup, maxBlobBytes: Int.max))
    }

    func testManifestRejectsOversize() {
        let big = Data(count: KVDiskCacheFormat.manifestMaxBytes + 1)
        XCTAssertThrowsError(try KVManifestCodec.decode(big, maxBlobBytes: Int.max))
    }

    func testManifestRejectsMismatchedDecodedLength() throws {
        var manifest = Self.consistentManifest()
        manifest = Self.withDecodedLength(manifest, manifest.decodedLength + 1)
        let data = try KVManifestCodec.encode(manifest)
        XCTAssertThrowsError(try KVManifestCodec.decode(data, maxBlobBytes: Int.max)) { error in
            guard case KVManifestParseError.corrupt = error else { return XCTFail("expected corrupt") }
        }
    }

    /// HIGH-6: the parser rejects a manifest whose Σ ct_length disagrees with
    /// decoded_length (before any allocation), even when blob_length stays coherent
    /// with the frame sizes.
    func testManifestRejectsCtLengthIncoherentWithDecodedLength() throws {
        let manifest = Self.consistentManifest()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try KVManifestCodec.encode(manifest)) as? [String: Any])
        var chunks = try XCTUnwrap(object["chunks"] as? [[String: Any]])
        let framing = 4 + 4 + 4 + KVDiskCacheFormat.chunkNonceBytes + KVDiskCacheFormat.gcmTagBytes
        // Shrink ct_length below decoded_length while keeping blob_length coherent
        // with the frame size, so ONLY the Σ ct_length == decoded_length check fires.
        chunks[0]["ct_length"] = 100
        object["chunks"] = chunks
        object["blob_length"] = 100 + framing
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try KVManifestCodec.decode(data, maxBlobBytes: Int.max)) { error in
            guard case KVManifestParseError.corrupt = error else { return XCTFail("expected corrupt") }
        }
    }

    // MARK: - Payload codec round trip

    func testPayloadCodecRoundTrip() throws {
        let tokens: [Int32] = [1, 2, 3, -4, 5]
        let layer = KVLayerPayload(
            layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 2, 5, 2], dtype: .f16,
            cacheOffset: 5, keyBytes: Data(repeating: 0xAB, count: 1 * 2 * 5 * 2 * 2),
            valueBytes: Data(repeating: 0xCD, count: 1 * 2 * 5 * 2 * 2))
        let encoded = try KVPayloadCodec.encode(tokens: tokens, layers: [layer])
        let expectedLen = KVDiskCacheFormat.decodedLength(
            tokenCount: tokens.count,
            layers: [.init(classID: layer.classID, ndim: layer.ndim, dims: layer.dims, dtype: layer.dtype)])
        XCTAssertEqual(encoded.count, expectedLen)
        let decoded = try KVPayloadCodec.decode(encoded, expectedDecodedLength: encoded.count, layerCount: 1)
        XCTAssertEqual(decoded.tokens, tokens)
        XCTAssertEqual(decoded.layers, [layer])
    }

    func testPayloadCodecRejectsLengthMismatch() throws {
        let encoded = try KVPayloadCodec.encode(tokens: [1, 2], layers: [])
        XCTAssertThrowsError(try KVPayloadCodec.decode(encoded, expectedDecodedLength: encoded.count + 1, layerCount: 0))
    }

    // MARK: - Chunk frame round trip

    func testChunkFrameRoundTrip() throws {
        let nonce = Data(repeating: 0x11, count: 12)
        let ciphertext = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let tag = Data(repeating: 0x22, count: 16)
        let frame = try KVChunkFrame.encode(ordinal: 0, nonce: nonce, ciphertext: ciphertext, tag: tag)
        XCTAssertEqual(frame.prefix(4), KVDiskCacheFormat.chunkMagic)
        let table = [KVChunkRecord(ordinal: 0, ctLength: ciphertext.count, nonce: nonce)]
        let parsed = try KVChunkFrame.decodeBlob(frame, chunkTable: table)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0], KVParsedFrame(ordinal: 0, nonce: nonce, ciphertext: ciphertext, tag: tag))
    }

    func testChunkFrameRejectsNonceMismatch() throws {
        let nonce = Data(repeating: 0x11, count: 12)
        let frame = try KVChunkFrame.encode(ordinal: 0, nonce: nonce, ciphertext: Data([1]), tag: Data(repeating: 0, count: 16))
        let wrongTable = [KVChunkRecord(ordinal: 0, ctLength: 1, nonce: Data(repeating: 0x99, count: 12))]
        XCTAssertThrowsError(try KVChunkFrame.decodeBlob(frame, chunkTable: wrongTable))
    }

    func testChunkFrameRejectsReorderedOrdinal() throws {
        let n0 = Data(repeating: 0x01, count: 12), n1 = Data(repeating: 0x02, count: 12)
        var blob = try KVChunkFrame.encode(ordinal: 1, nonce: n1, ciphertext: Data([1]), tag: Data(repeating: 0, count: 16))
        blob.append(try KVChunkFrame.encode(ordinal: 0, nonce: n0, ciphertext: Data([2]), tag: Data(repeating: 0, count: 16)))
        let table = [KVChunkRecord(ordinal: 0, ctLength: 1, nonce: n0), KVChunkRecord(ordinal: 1, ctLength: 1, nonce: n1)]
        XCTAssertThrowsError(try KVChunkFrame.decodeBlob(blob, chunkTable: table))
    }

    // MARK: - Envelope validation: per-field mutation → reason code (AC-2)

    func testEnvelopeValidatesReference() {
        let (manifest, runtime) = Self.validPair()
        guard case .ok = KVEnvelopeValidator.validate(manifest, runtime: runtime, nowMillis: 1_000_500) else {
            return XCTFail("reference pair should validate")
        }
    }

    func testEnvelopeModelSHAMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        let mutated = Self.mutate(manifest) { $0.modelSHA256 = String(repeating: "f", count: 64) }
        assertMiss(mutated, runtime, .diskMissEnvelope)
    }

    func testEnvelopeServedModelMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.servedModelID = "other" }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeRequestModelMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.requestModel = "alias-x" }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeCatalogRevisionMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.catalogRevision = "r99" }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeTokenizerMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.tokenizerConfigSHA256 = String(repeating: "a", count: 64) }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeChatTemplateMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.chatTemplateSHA256 = String(repeating: "b", count: 64) }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeABIEpochMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.abiEpoch = 999 }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeMLXRevisionMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.mlxSwiftLMRevision = "deadbeef" }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeKVBitsNullVsNumberIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        // Reference is unquantized (null). A number is an exact-match mismatch.
        assertMiss(Self.mutate(manifest) { $0.kvBits = 4 }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeNamespaceMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.namespaceID = "other-ns" }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeKeyEpochMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.keyEpoch = 7 }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeIndexMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.indexHMAC = String(repeating: "0", count: 64) }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeDecodePathMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.decodePath = "speculative" }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeLayoutVersionMismatchIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        let mutated = Self.mutate(manifest) { m in
            m.layers = m.layers.map {
                KVLayerRecord(layerIndex: $0.layerIndex, classID: $0.classID, layoutVersion: 42,
                              ndim: $0.ndim, dims: $0.dims, dtype: $0.dtype)
            }
        }
        assertMiss(mutated, runtime, .diskMissEnvelope)
    }

    func testEnvelopeSchemaUnknownIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        assertMiss(Self.mutate(manifest) { $0.schemaID = "kvsurv-manifest-v9" }, runtime, .diskMissEnvelope)
    }

    func testEnvelopeExpiredIsExpired() {
        let (manifest, runtime) = Self.validPair()
        // now beyond eligible_until.
        assertMiss(manifest, runtime, .diskMissExpired, nowMillis: manifest.eligibleUntilMillis + 1)
    }

    func testEnvelopeCreationInFutureIsEnvelope() {
        let (manifest, runtime) = Self.validPair()
        // now before creation.
        assertMiss(manifest, runtime, .diskMissEnvelope, nowMillis: manifest.createdAtMillis - 1)
    }

    func testEnvelopeFenceBelowHighWatermarkIsTombstoned() {
        let (manifest, base) = Self.validPair()
        let runtime = Self.withHighWatermark(base, manifest.purgeGeneration + 1)
        assertMiss(manifest, runtime, .diskMissTombstoned)
    }

    func testEnvelopeIdentityUnavailableWhenModelHashNil() {
        let (manifest, base) = Self.validPair()
        let runtime = Self.withModelSHA(base, nil)
        assertMiss(manifest, runtime, .diskMissIdentityUnavailable)
    }

    func testEnvelopeSequenceAxisTokenCountMismatchIsCorrupt() {
        // A manifest whose seq-axis dim disagrees with token_count is an integrity fault.
        let (manifest, runtime) = Self.validPair()
        let mutated = Self.mutate(manifest) { m in
            m.layers = m.layers.map {
                var dims = $0.dims; dims[2] = dims[2] + 1   // seq axis = 2
                return KVLayerRecord(layerIndex: $0.layerIndex, classID: $0.classID, layoutVersion: $0.layoutVersion,
                                     ndim: $0.ndim, dims: dims, dtype: $0.dtype)
            }
        }
        assertMiss(mutated, runtime, .diskMissCorrupt)
    }

    // MARK: - Unicode canonical key equivalence (AC-1)

    func testComposedAndDecomposedKeysCanonicalizeToSameBytes() {
        // Build from explicit scalars so the source file's own normalization can't
        // collapse the two forms before the test runs.
        let composed = "conv:kvs-synth:caf" + String(UnicodeScalar(0x00E9)!)      // é precomposed
        let decomposed = "conv:kvs-synth:cafe" + String(UnicodeScalar(0x0301)!)   // e + combining acute
        XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars))
        XCTAssertEqual(KVCanonicalKey.canonicalBytes(composed), KVCanonicalKey.canonicalBytes(decomposed))
    }

    func testCanonicalKeyTrimsWhitespace() {
        XCTAssertEqual(KVCanonicalKey.canonicalBytes("  conv:kvs-synth:x \n"),
                       KVCanonicalKey.canonicalBytes("conv:kvs-synth:x"))
    }

    // MARK: - HKDF derivation conformance vector

    func testHKDFIndexKeyConformanceVector() {
        let master = Data((0 ..< 32).map { UInt8($0) })   // 00,01,...,1f
        let key = KVKeyManager.deriveIndexKey(epochMaster: master, epoch: 1)
        let hex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        // Regression pin over salt="macprovider-kv-v1", info="index/1", L=32.
        XCTAssertEqual(hex, "0e0c3cd702efe95091a9265e98ca3a026e66e4ff94a4e5a0876f3a71ef657bbb")
    }

    func testHKDFIndexKeyIsEpochDistinct() {
        let master = Data(repeating: 7, count: 32)
        let k1 = KVKeyManager.deriveIndexKey(epochMaster: master, epoch: 1)
        let k2 = KVKeyManager.deriveIndexKey(epochMaster: master, epoch: 2)
        XCTAssertNotEqual(k1.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
    }

    // MARK: - Helpers

    private func assertMiss(_ manifest: KVDiskManifest, _ runtime: KVRuntimeIdentity,
                            _ expected: KVReasonCode, nowMillis: Int = 1_000_500,
                            file: StaticString = #filePath, line: UInt = #line) {
        switch KVEnvelopeValidator.validate(manifest, runtime: runtime, nowMillis: nowMillis) {
        case .miss(let code, _):
            XCTAssertEqual(code, expected, file: file, line: line)
        case .ok:
            XCTFail("expected miss \(expected.rawValue), got ok", file: file, line: line)
        }
    }

    /// A fully-populated reference manifest (fixed values) for JCS/AAD golden pins.
    static func referenceManifest() -> KVDiskManifest {
        KVDiskManifest(
            schemaID: KVDiskCacheFormat.manifestSchemaID, codecID: KVDiskCacheFormat.codecID,
            namespaceID: "ns-ref", keyEpoch: 1, indexHMAC: String(repeating: "a", count: 64),
            generation: 3, commitSequence: 9, purgeGeneration: 0,
            requestModel: "qwen-ref", servedModelID: "qwen-ref-served",
            modelSHA256: String(repeating: "b", count: 64), catalogRevision: "r1",
            tokenizerID: "tok-1", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 1,
            mlxSwiftLMRevision: "3.31.4", mlxVersion: "0.0.0", cacheClass: "KVCacheSimple",
            layerCount: 1,
            layers: [KVLayerRecord(layerIndex: 0, classID: "KVCacheSimple", layoutVersion: 1, ndim: 4, dims: [1, 2, 2, 2], dtype: .f16)],
            kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil,
            decodePath: "ordinary", tokenCount: 2, createdAtMillis: 1_000_000, eligibleUntilMillis: 1_900_000,
            decodedLength: 121,
            chunks: [KVChunkRecord(ordinal: 0, ctLength: 121, nonce: Data(repeating: 0x11, count: 12))],
            blobLength: 121 + 40, blobSHA256: String(repeating: "e", count: 64))
    }

    /// A manifest whose decoded_length + chunk table + blob_length are internally
    /// consistent, so it round-trips through decode.
    static func consistentManifest() -> KVDiskManifest {
        referenceManifest()   // reference is already consistent (single chunk = decoded_length)
    }

    static func withDecodedLength(_ m: KVDiskManifest, _ value: Int) -> KVDiskManifest {
        mutate(m) { $0.decodedLength = value }
    }

    /// A valid (manifest, runtime) pair for envelope tests.
    static func validPair() -> (KVDiskManifest, KVRuntimeIdentity) {
        let manifest = referenceManifest()
        let runtime = KVRuntimeIdentity(
            namespaceID: "ns-ref", keyEpoch: 1, indexHMAC: manifest.indexHMAC,
            requestModel: "qwen-ref", servedModelID: "qwen-ref-served",
            modelSHA256: String(repeating: "b", count: 64), catalogRevision: "r1",
            tokenizerID: "tok-1", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 1,
            mlxSwiftLMRevision: "3.31.4", mlxVersion: "0.0.0", cacheClass: "KVCacheSimple",
            layerCount: 1,
            layers: [KVLayerGeometry(layerIndex: 0, classID: "KVCacheSimple", layoutVersion: 1, ndim: 4, dims: [1, 2, 2, 2], dtype: .f16, sequenceAxis: 2)],
            kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil,
            decodePath: "ordinary", liveHighWatermark: 0)
        return (manifest, runtime)
    }

    static func withHighWatermark(_ r: KVRuntimeIdentity, _ hw: Int) -> KVRuntimeIdentity {
        KVRuntimeIdentity(
            namespaceID: r.namespaceID, keyEpoch: r.keyEpoch, indexHMAC: r.indexHMAC,
            requestModel: r.requestModel, servedModelID: r.servedModelID, modelSHA256: r.modelSHA256,
            catalogRevision: r.catalogRevision, tokenizerID: r.tokenizerID,
            tokenizerConfigSHA256: r.tokenizerConfigSHA256, chatTemplateSHA256: r.chatTemplateSHA256,
            abiEpoch: r.abiEpoch, mlxSwiftLMRevision: r.mlxSwiftLMRevision, mlxVersion: r.mlxVersion,
            cacheClass: r.cacheClass, layerCount: r.layerCount, layers: r.layers,
            kvBits: r.kvBits, kvGroupSize: r.kvGroupSize, kvQuantMode: r.kvQuantMode,
            kvQuantPolicy: r.kvQuantPolicy, decodePath: r.decodePath, liveHighWatermark: hw)
    }

    static func withModelSHA(_ r: KVRuntimeIdentity, _ sha: String?) -> KVRuntimeIdentity {
        KVRuntimeIdentity(
            namespaceID: r.namespaceID, keyEpoch: r.keyEpoch, indexHMAC: r.indexHMAC,
            requestModel: r.requestModel, servedModelID: r.servedModelID, modelSHA256: sha,
            catalogRevision: r.catalogRevision, tokenizerID: r.tokenizerID,
            tokenizerConfigSHA256: r.tokenizerConfigSHA256, chatTemplateSHA256: r.chatTemplateSHA256,
            abiEpoch: r.abiEpoch, mlxSwiftLMRevision: r.mlxSwiftLMRevision, mlxVersion: r.mlxVersion,
            cacheClass: r.cacheClass, layerCount: r.layerCount, layers: r.layers,
            kvBits: r.kvBits, kvGroupSize: r.kvGroupSize, kvQuantMode: r.kvQuantMode,
            kvQuantPolicy: r.kvQuantPolicy, decodePath: r.decodePath, liveHighWatermark: r.liveHighWatermark)
    }

    /// Mutable projection to rebuild a manifest with a single field changed.
    struct MutableManifest {
        var m: KVDiskManifest
        var schemaID: String { get { m.schemaID } set { m = Self.rebuild(m, schemaID: newValue) } }
        var namespaceID: String { get { m.namespaceID } set { m = Self.rebuild(m, namespaceID: newValue) } }
        var keyEpoch: Int { get { m.keyEpoch } set { m = Self.rebuild(m, keyEpoch: newValue) } }
        var indexHMAC: String { get { m.indexHMAC } set { m = Self.rebuild(m, indexHMAC: newValue) } }
        var requestModel: String { get { m.requestModel } set { m = Self.rebuild(m, requestModel: newValue) } }
        var servedModelID: String { get { m.servedModelID } set { m = Self.rebuild(m, servedModelID: newValue) } }
        var modelSHA256: String { get { m.modelSHA256 } set { m = Self.rebuild(m, modelSHA256: newValue) } }
        var catalogRevision: String { get { m.catalogRevision } set { m = Self.rebuild(m, catalogRevision: newValue) } }
        var tokenizerConfigSHA256: String { get { m.tokenizerConfigSHA256 } set { m = Self.rebuild(m, tokenizerConfigSHA256: newValue) } }
        var chatTemplateSHA256: String { get { m.chatTemplateSHA256 } set { m = Self.rebuild(m, chatTemplateSHA256: newValue) } }
        var abiEpoch: Int { get { m.abiEpoch } set { m = Self.rebuild(m, abiEpoch: newValue) } }
        var mlxSwiftLMRevision: String { get { m.mlxSwiftLMRevision } set { m = Self.rebuild(m, mlxSwiftLMRevision: newValue) } }
        var kvBits: Int? { get { m.kvBits } set { m = Self.rebuild(m, kvBits: newValue) } }
        var decodePath: String { get { m.decodePath } set { m = Self.rebuild(m, decodePath: newValue) } }
        var decodedLength: Int { get { m.decodedLength } set { m = Self.rebuild(m, decodedLength: newValue) } }
        var layers: [KVLayerRecord] { get { m.layers } set { m = Self.rebuild(m, layers: newValue) } }

        static func rebuild(
            _ m: KVDiskManifest, schemaID: String? = nil, namespaceID: String? = nil, keyEpoch: Int? = nil,
            indexHMAC: String? = nil, requestModel: String? = nil, servedModelID: String? = nil,
            modelSHA256: String? = nil, catalogRevision: String? = nil, tokenizerConfigSHA256: String? = nil,
            chatTemplateSHA256: String? = nil, abiEpoch: Int? = nil, mlxSwiftLMRevision: String? = nil,
            kvBits: Int?? = nil, decodePath: String? = nil, decodedLength: Int? = nil, layers: [KVLayerRecord]? = nil
        ) -> KVDiskManifest {
            KVDiskManifest(
                schemaID: schemaID ?? m.schemaID, codecID: m.codecID, namespaceID: namespaceID ?? m.namespaceID,
                keyEpoch: keyEpoch ?? m.keyEpoch, indexHMAC: indexHMAC ?? m.indexHMAC, generation: m.generation,
                commitSequence: m.commitSequence, purgeGeneration: m.purgeGeneration,
                requestModel: requestModel ?? m.requestModel, servedModelID: servedModelID ?? m.servedModelID,
                modelSHA256: modelSHA256 ?? m.modelSHA256, catalogRevision: catalogRevision ?? m.catalogRevision,
                tokenizerID: m.tokenizerID, tokenizerConfigSHA256: tokenizerConfigSHA256 ?? m.tokenizerConfigSHA256,
                chatTemplateSHA256: chatTemplateSHA256 ?? m.chatTemplateSHA256, abiEpoch: abiEpoch ?? m.abiEpoch,
                mlxSwiftLMRevision: mlxSwiftLMRevision ?? m.mlxSwiftLMRevision, mlxVersion: m.mlxVersion,
                cacheClass: m.cacheClass, layerCount: m.layerCount, layers: layers ?? m.layers,
                kvBits: kvBits ?? m.kvBits, kvGroupSize: m.kvGroupSize, kvQuantMode: m.kvQuantMode,
                kvQuantPolicy: m.kvQuantPolicy, decodePath: decodePath ?? m.decodePath, tokenCount: m.tokenCount,
                createdAtMillis: m.createdAtMillis, eligibleUntilMillis: m.eligibleUntilMillis,
                decodedLength: decodedLength ?? m.decodedLength, chunks: m.chunks, blobLength: m.blobLength,
                blobSHA256: m.blobSHA256)
        }
    }

    static func mutate(_ m: KVDiskManifest, _ apply: (inout MutableManifest) -> Void) -> KVDiskManifest {
        var mm = MutableManifest(m: m)
        apply(&mm)
        return mm.m
    }
}
