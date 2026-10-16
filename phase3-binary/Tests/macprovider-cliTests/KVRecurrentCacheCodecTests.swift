import Foundation
@testable import macprovider_cli
import XCTest

final class KVRecurrentCacheCodecTests: XCTestCase {
    func testStoreV2WritePromotionRuntimeAndReadAcceptsRecurrentSentinelGeometry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kv-v2-envelope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = KVDiskCacheStoreConfig(
            root: root, namespaceID: "ns-v2-envelope",
            maxBytes: 16 * 1024 * 1024, maxEntries: 8, maxEntryBytes: 8 * 1024 * 1024,
            retentionSeconds: 3600, stagingMaxBytes: 8 * 1024 * 1024,
            writeStagingMaxBytes: 8 * 1024 * 1024, minFreeBytes: 1024,
            promotionMaxSeconds: 5, eligibilityTTLSeconds: 900)
        config.freeSpaceOverride = 1 << 30
        let store = KVDiskCacheStore(
            config: config, keychain: KVInMemoryKeychain(), sink: KVRecordingEventSink())
        try await store.activate()

        let adapter = KVConversationColdTierAdapter(
            store: store, namespaceID: "ns-v2-envelope", eligibilityTTLSeconds: 900)
        let key = "conv:kvs-synth:v2-envelope"
        let tokens: [Int32] = [10, 11, 12]
        let layers: [KVCacheLayerPayload] = [
            .attention(KVLayerPayload(
                layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 1, 3, 2], dtype: .f16,
                cacheOffset: 3, keyBytes: Data(repeating: 0x11, count: 12),
                valueBytes: Data(repeating: 0x22, count: 12))),
            .recurrent(layerIndex: 1, classID: "MambaCache", cacheOffset: 3),
        ]
        let recurrentLayout = KVRecurrentLayerRecord(layerIndex: 1, slots: [
            .init(slotIndex: 0, dims: [1, 2], dtype: .f16, byteCount: 4),
            .init(slotIndex: 1, dims: [1, 3], dtype: .f32, byteCount: 12),
        ])
        let checkpoints = [KVRecurrentCheckpointPayload(tokenCount: 3, layers: [
            .init(layerIndex: 1, slots: [
                .init(slotIndex: 0, dims: [1, 2], dtype: .f16, bytes: Data(repeating: 0x33, count: 4)),
                .init(slotIndex: 1, dims: [1, 3], dtype: .f32, bytes: Data(repeating: 0x44, count: 12)),
            ]),
        ])]
        let modelSHA = String(repeating: "b", count: 64)
        let tokenizerSHA = String(repeating: "c", count: 64)
        let templateSHA = String(repeating: "d", count: 64)
        let identity = KVIdentityCore(
            requestModel: "mixed", servedModelID: "mixed-served", modelSHA256: modelSHA,
            catalogRevision: "r1", tokenizerID: "mixed-served", tokenizerConfigSHA256: tokenizerSHA,
            chatTemplateSHA256: templateSHA, kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil)
        let writeIdentity = KVWriteIdentity(
            codecID: KVDiskCacheFormat.recurrentCodecID,
            requestModel: identity.requestModel, servedModelID: identity.servedModelID,
            modelSHA256: modelSHA, catalogRevision: identity.catalogRevision,
            tokenizerID: identity.tokenizerID, tokenizerConfigSHA256: tokenizerSHA,
            chatTemplateSHA256: templateSHA, abiEpoch: KVBuildIdentity.recurrentABIEpoch,
            mlxSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision,
            mlxVersion: KVBuildIdentity.mlxVersion, cacheClass: KVDiskCacheFormat.recurrentCacheClass,
            layerCount: layers.count, kvBits: nil, kvGroupSize: nil, kvQuantMode: nil,
            kvQuantPolicy: nil, decodePath: KVBuildIdentity.decodePathOrdinary, keyEpoch: 1)
        let nowMillis = Int(Date().timeIntervalSince1970 * 1000)
        let write = try await store.writeColdSnapshot(
            rawKey: key, tokens: tokens, layers: [], layersV2: layers,
            recurrentCheckpoints: checkpoints, identity: writeIdentity,
            sampledPurgeGeneration: 0, commitSequence: 1, createdAtMillis: nowMillis,
            eligibleUntilMillis: nowMillis + 900_000, incarnation: "inc-v2", nowMillis: nowMillis)
        guard case .committed = write else {
            await store.deactivate()
            return XCTFail("codec-v2 fixture must commit, got \(write)")
        }

        let template = [
            KVLayerGeometry(
                layerIndex: 0, classID: "KVCacheSimple", layoutVersion: 2,
                ndim: 4, dims: [1, 1, 1, 2], dtype: .f16, sequenceAxis: 2),
            KVLayerGeometry(
                layerIndex: 1, classID: "MambaCache", layoutVersion: 2,
                ndim: 0, dims: [], dtype: .f16, sequenceAxis: 0),
        ]
        let runtime = adapter.promotionRuntime(
            identity: identity, template: template, epoch: await store.currentEpoch,
            recurrentLayouts: [recurrentLayout])
        let result = try await store.read(
            rawKey: key, runtime: runtime, nowMillis: nowMillis, emitHitEvent: false)
        guard case let .hit(hit) = result else {
            await store.deactivate()
            return XCTFail("ndim=0 recurrent sentinel must survive envelope validation, got \(result)")
        }
        XCTAssertEqual(hit.tokens, tokens)
        XCTAssertEqual(hit.decodedV2?.layers, layers)
        XCTAssertEqual(hit.decodedV2?.checkpoints, checkpoints)
        await store.deactivate()
    }

    func testCodecV2RoundTripsOrderedMixedLayersAndCompleteCheckpoints() throws {
        let tokens: [Int32] = [10, 11, 12]
        let attention = KVLayerPayload(
            layerIndex: 0, classID: "KVCacheSimple", ndim: 4, dims: [1, 1, 3, 2], dtype: .f16,
            cacheOffset: 3, keyBytes: Data(repeating: 0x11, count: 12),
            valueBytes: Data(repeating: 0x22, count: 12))
        let slots = [
            KVRecurrentSlotPayload(slotIndex: 0, dims: [1, 2], dtype: .f16, bytes: Data(repeating: 0x33, count: 4)),
            KVRecurrentSlotPayload(slotIndex: 1, dims: [1, 3], dtype: .f32, bytes: Data(repeating: 0x44, count: 12)),
        ]
        let layers: [KVCacheLayerPayload] = [
            .attention(attention), .recurrent(layerIndex: 1, classID: "MambaCache", cacheOffset: 3),
        ]
        let checkpoints = [
            KVRecurrentCheckpointPayload(
                tokenCount: 3, layers: [KVRecurrentLayerPayload(layerIndex: 1, slots: slots)]),
        ]
        let segments = try KVPayloadCodecV2.encodeSegments(tokens: tokens, layers: layers, checkpoints: checkpoints)
        let encoded = segments.reduce(into: Data()) { $0.append($1) }
        let layerRecords = [
            KVLayerRecord(layerIndex: 0, classID: "KVCacheSimple", layoutVersion: 2, ndim: 4, dims: [1, 1, 3, 2], dtype: .f16),
            KVLayerRecord(layerIndex: 1, classID: "MambaCache", layoutVersion: 2, ndim: 0, dims: [], dtype: .f16, cacheOffset: 3),
        ]
        let checkpointRecords = [
            KVRecurrentCheckpointRecord(tokenCount: 3, layers: [
                KVRecurrentLayerRecord(layerIndex: 1, slots: [
                    .init(slotIndex: 0, dims: [1, 2], dtype: .f16, byteCount: 4),
                    .init(slotIndex: 1, dims: [1, 3], dtype: .f32, byteCount: 12),
                ]),
            ]),
        ]

        XCTAssertEqual(
            encoded.count,
            KVDiskCacheFormat.decodedLengthV2(
                tokenCount: tokens.count, layers: layerRecords, checkpoints: checkpointRecords))
        let decoded = try KVPayloadCodecV2.decode(
            encoded, expectedDecodedLength: encoded.count,
            expectedLayers: layerRecords, expectedCheckpoints: checkpointRecords)
        XCTAssertEqual(decoded, KVDecodedPayloadV2(tokens: tokens, layers: layers, checkpoints: checkpoints))
    }

    func testCodecV2RejectsIncompleteRecurrentCoverageBeforeEncoding() {
        let layers: [KVCacheLayerPayload] = [
            .recurrent(layerIndex: 0, classID: "MambaCache", cacheOffset: 1),
            .recurrent(layerIndex: 1, classID: "MambaCache", cacheOffset: 1),
        ]
        let incomplete = KVRecurrentCheckpointPayload(
            tokenCount: 1,
            layers: [KVRecurrentLayerPayload(layerIndex: 0, slots: [])])
        XCTAssertThrowsError(
            try KVPayloadCodecV2.encodeSegments(tokens: [1], layers: layers, checkpoints: [incomplete]))
    }

    func testCodecV2RejectsPayloadSlotLengthMismatchBeforeMLXRestore() throws {
        let layers: [KVCacheLayerPayload] = [.recurrent(layerIndex: 0, classID: "MambaCache", cacheOffset: 1)]
        let slots = [
            KVRecurrentSlotPayload(slotIndex: 0, dims: [1, 2], dtype: .f16, bytes: Data(count: 4)),
            KVRecurrentSlotPayload(slotIndex: 1, dims: [1, 2], dtype: .f16, bytes: Data(count: 4)),
        ]
        let checkpoints = [KVRecurrentCheckpointPayload(
            tokenCount: 1, layers: [.init(layerIndex: 0, slots: slots)])]
        let encoded = try KVPayloadCodecV2.encodeSegments(tokens: [1], layers: layers, checkpoints: checkpoints)
            .reduce(into: Data()) { $0.append($1) }
        let records = [KVLayerRecord(
            layerIndex: 0, classID: "MambaCache", layoutVersion: 2,
            ndim: 0, dims: [], dtype: .f16, cacheOffset: 1)]
        let mismatched = [KVRecurrentCheckpointRecord(tokenCount: 1, layers: [
            .init(layerIndex: 0, slots: [
                .init(slotIndex: 0, dims: [1, 2], dtype: .f16, byteCount: 6),
                .init(slotIndex: 1, dims: [1, 2], dtype: .f16, byteCount: 4),
            ]),
        ])]
        XCTAssertThrowsError(try KVPayloadCodecV2.decode(
            encoded, expectedDecodedLength: encoded.count,
            expectedLayers: records, expectedCheckpoints: mismatched))
    }

    func testCodecV2ManifestRoundTripsClosedCheckpointGrammar() throws {
        let layerRecords = [
            KVLayerRecord(layerIndex: 0, classID: "KVCacheSimple", layoutVersion: 2, ndim: 4, dims: [1, 1, 1, 2], dtype: .f16),
            KVLayerRecord(layerIndex: 1, classID: "MambaCache", layoutVersion: 2, ndim: 0, dims: [], dtype: .f16, cacheOffset: 1),
        ]
        let checkpoints = [KVRecurrentCheckpointRecord(tokenCount: 1, layers: [
            .init(layerIndex: 1, slots: [
                .init(slotIndex: 0, dims: [1, 2], dtype: .f16, byteCount: 4),
                .init(slotIndex: 1, dims: [1, 3], dtype: .f32, byteCount: 12),
            ]),
        ])]
        let decodedLength = try XCTUnwrap(KVDiskCacheFormat.decodedLengthV2(
            tokenCount: 1, layers: layerRecords, checkpoints: checkpoints))
        let manifest = KVDiskManifest(
            schemaID: KVDiskCacheFormat.manifestSchemaID, codecID: KVDiskCacheFormat.recurrentCodecID,
            namespaceID: "ns", keyEpoch: 1, indexHMAC: String(repeating: "a", count: 64),
            generation: 1, commitSequence: 1, purgeGeneration: 0,
            requestModel: "mixed", servedModelID: "mixed", modelSHA256: String(repeating: "b", count: 64),
            catalogRevision: "r", tokenizerID: "tok",
            tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), abiEpoch: 2,
            mlxSwiftLMRevision: "rev", mlxVersion: "mlx", cacheClass: KVDiskCacheFormat.recurrentCacheClass,
            layerCount: layerRecords.count, layers: layerRecords, recurrentCheckpoints: checkpoints,
            kvBits: nil, kvGroupSize: nil, kvQuantMode: nil, kvQuantPolicy: nil,
            decodePath: "ordinary", tokenCount: 1, createdAtMillis: 1, eligibleUntilMillis: 2,
            decodedLength: decodedLength,
            chunks: [.init(ordinal: 0, ctLength: decodedLength, nonce: Data(repeating: 7, count: 12))],
            blobLength: decodedLength + 40, blobSHA256: String(repeating: "e", count: 64))
        let data = try KVManifestCodec.encode(manifest)
        XCTAssertEqual(try KVManifestCodec.decode(data, maxBlobBytes: Int.max), manifest)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rawCheckpoints = try XCTUnwrap(object["recurrent_checkpoints"] as? [[String: Any]])
        var rawLayers = try XCTUnwrap(rawCheckpoints[0]["layers"] as? [[String: Any]])
        rawLayers.removeLast()
        rawCheckpoints[0]["layers"] = rawLayers
        object["recurrent_checkpoints"] = rawCheckpoints
        XCTAssertThrowsError(try KVManifestCodec.decode(
            JSONSerialization.data(withJSONObject: object), maxBlobBytes: Int.max))
    }
}
