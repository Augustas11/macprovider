import Foundation
import MLX
import MLXLMCommon
@testable import macprovider_cli
import XCTest

final class KVPromptSnapshotCodecTests: XCTestCase {
    private func fixture(head: Bool = true) -> KVPromptSnapshotPayload {
        // Use varied bf16 bit patterns in the latent bytes: this exercises raw
        // storage, never a float conversion.
        let bytes = Data((0..<160).map { UInt8(truncatingIfNeeded: $0 * 71) })
        let empty = KVPromptSnapshotTensor(dims: [0], dtype: .f32, bytes: Data())
        let attention = KVPromptSnapshotLayer(classID: "GLM5NextAttentionCache",
            parameters: [4, 16, 256], metadata: ["4"], offset: 40,
            tensors: [.init(dims: [1, 1, 40, 2], dtype: .bf16, bytes: bytes)] + Array(repeating: empty, count: 5))
        let recurrent = KVPromptSnapshotLayer(classID: "MambaCache", parameters: [], metadata: ["2", "0,1"], offset: 0,
            tensors: [.init(dims: [1, 2, 2], dtype: .f16, bytes: Data(repeating: 3, count: 8)),
                      .init(dims: [1, 1, 2, 2], dtype: .f32, bytes: Data(repeating: 7, count: 16))])
        return KVPromptSnapshotPayload(tokens: Array(0..<40), layers: [attention, recurrent],
            head: head ? [attention] : [], resumeBoundaryPlan: true,
            nextPosition: head ? 40 : 0, foldedNextToken: head ? 61 : 0)
    }

    private func encoded(_ payload: KVPromptSnapshotPayload) throws -> Data {
        try KVPromptSnapshotCodec.encodeSegments(payload).reduce(into: Data()) { $0.append($1) }
    }

    func testBinaryArchivePreservesTargetHeadAndBfloat16Bytes() throws {
        for head in [false, true] {
            let source = fixture(head: head)
            let data = try encoded(source)
            XCTAssertEqual(try KVPromptSnapshotCodec.decode(data,
                expectedLayers: KVPromptSnapshotCodec.records(source), tokenCount: 40), source)
            XCTAssertThrowsError(try KVPromptSnapshotCodec.decode(data + Data([0]),
                expectedLayers: KVPromptSnapshotCodec.records(source), tokenCount: 40))
            XCTAssertThrowsError(try KVPromptSnapshotCodec.decode(Data(data.dropLast()),
                expectedLayers: KVPromptSnapshotCodec.records(source), tokenCount: 40))
        }
    }

    func testArchiveRejectsWrongTopologyAndIncoherentHeadPair() throws {
        let source = fixture()
        var wrong = KVPromptSnapshotCodec.records(source)
        wrong[0] = KVLayerRecord(layerIndex: 0, classID: "GLM5NextAttentionCache", layoutVersion: 3,
                                ndim: 3, dims: [8, 16, 256], dtype: .i32)
        XCTAssertThrowsError(try KVPromptSnapshotCodec.decode(encoded(source), expectedLayers: wrong, tokenCount: 40))
        let bad = KVPromptSnapshotPayload(tokens: source.tokens, layers: source.layers, head: source.head,
            resumeBoundaryPlan: true, nextPosition: 39, foldedNextToken: source.foldedNextToken)
        XCTAssertThrowsError(try encoded(bad))
        let unknown = KVPromptSnapshotLayer(classID: "UntrustedCache", parameters: [], metadata: [], offset: 0, tensors: [])
        XCTAssertThrowsError(try encoded(.init(tokens: source.tokens, layers: [unknown], head: [],
            resumeBoundaryPlan: true, nextPosition: 0, foldedNextToken: 0)))
    }

    func testEncryptedArchiveSurvivesRestartAndHonorsIdentityAndPurge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kv-prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var config = KVDiskCacheStoreConfig(root: root, namespaceID: "prompt-tests", maxBytes: 64 << 20,
            maxEntries: 64, maxEntryBytes: 16 << 20, retentionSeconds: 259200,
            stagingMaxBytes: 16 << 20, writeStagingMaxBytes: 16 << 20, minFreeBytes: 1024,
            promotionMaxSeconds: 5, eligibilityTTLSeconds: 259200)
        config.freeSpaceOverride = 1 << 30
        let keys = KVInMemoryKeychain()
        let source = fixture()
        let core = identity()
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let key = "conv:kvs-synth:prompt"
        let store = KVDiskCacheStore(config: config, keychain: keys, sink: KVRecordingEventSink())
        try await store.activate()
        let writeIdentity = KVWriteIdentity(codecID: KVDiskCacheFormat.promptSnapshotCodecID,
            requestModel: core.requestModel, servedModelID: core.servedModelID, modelSHA256: core.modelSHA256!,
            catalogRevision: core.catalogRevision, tokenizerID: core.tokenizerID,
            tokenizerConfigSHA256: core.tokenizerConfigSHA256, chatTemplateSHA256: core.chatTemplateSHA256,
            abiEpoch: KVBuildIdentity.promptSnapshotABIEpoch, mlxSwiftLMRevision: KVBuildIdentity.mlxSwiftLMRevision,
            mlxVersion: KVBuildIdentity.mlxVersion, cacheClass: KVDiskCacheFormat.promptSnapshotCacheClass,
            layerCount: source.layers.count, kvBits: nil, kvGroupSize: nil, kvQuantMode: nil,
            kvQuantPolicy: nil, decodePath: KVBuildIdentity.decodePathOrdinary, keyEpoch: await store.currentEpoch)
        let result = try await store.writeColdSnapshot(rawKey: key, tokens: source.tokens, layers: [],
            promptSnapshot: source, identity: writeIdentity, sampledPurgeGeneration: 0, commitSequence: 1,
            createdAtMillis: now, eligibleUntilMillis: now + 259200000, incarnation: "test", nowMillis: now)
        guard case .committed = result else { await store.deactivate(); return XCTFail("archive write: \(result)") }
        await store.deactivate()

        let restarted = KVDiskCacheStore(config: config, keychain: keys, sink: KVRecordingEventSink())
        try await restarted.activate()
        let adapter = KVConversationColdTierAdapter(store: restarted, namespaceID: config.namespaceID, eligibilityTTLSeconds: 259200)
        let template = KVPromptSnapshotCodec.records(source).map {
            KVLayerGeometry(layerIndex: $0.layerIndex, classID: $0.classID, layoutVersion: 3,
                            ndim: $0.ndim, dims: $0.dims, dtype: $0.dtype, sequenceAxis: -1)
        }
        let runtime = adapter.promotionRuntime(identity: core, template: template, epoch: await restarted.currentEpoch)
        let read = try await restarted.read(rawKey: key, runtime: runtime, nowMillis: now + 1000)
        guard case .hit(let hit) = read else { await restarted.deactivate(); return XCTFail("restart read: \(read)") }
        XCTAssertEqual(hit.promptSnapshot, source)
        let wrongRuntime = adapter.promotionRuntime(identity: identity(modelHash: "e"), template: template, epoch: await restarted.currentEpoch)
        let wrongRead = try await restarted.read(rawKey: key, runtime: wrongRuntime, nowMillis: now + 1001)
        guard case .miss(.diskMissEnvelope, _) = wrongRead else { await restarted.deactivate(); return XCTFail("identity must miss") }
        _ = try await restarted.purge(rawKey: key)
        let purged = try await restarted.read(rawKey: key, runtime: runtime, nowMillis: now + 1002)
        await restarted.deactivate()
        guard case .miss = purged else { return XCTFail("purged archive must not restore") }
    }

    func testMLXCaptureEstimateAndRestoreAreByteExact() throws {
        guard ProcessInfo.processInfo.environment["KV_ENABLE_MLX_TESTS"] == "1" else { throw XCTSkip("MLX fixture opt-in") }
        let source = fixture()
        let restored = try XCTUnwrap(KVPromptSnapshotCodec.restore(source))
        let estimate = try XCTUnwrap(KVPromptSnapshotCodec.estimatedLength(restored, tokens: source.tokens))
        let captured = try XCTUnwrap(KVPromptSnapshotCodec.capture(restored, tokens: source.tokens))
        XCTAssertEqual(captured, source)
        XCTAssertEqual(try encoded(captured).count, estimate)
        XCTAssertEqual(restored.nativeMTPDrafter?.nextPosition, source.tokens.count)
    }

    private func identity(modelHash: String = "b") -> KVIdentityCore {
        KVIdentityCore(requestModel: "glm", servedModelID: "glm-served", modelSHA256: String(repeating: modelHash, count: 64),
            catalogRevision: "r1", tokenizerID: "glm-served", tokenizerConfigSHA256: String(repeating: "c", count: 64),
            chatTemplateSHA256: String(repeating: "d", count: 64), kvBits: nil, kvGroupSize: nil,
            kvQuantMode: nil, kvQuantPolicy: nil)
    }
}
