import ArgumentParser
import CryptoKit
import Foundation
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Issue #2084 SPEC-051-R006/R008: a member holding only its stage's files proves them
/// against the full snapshot manifest, and its fit is judged on its stage alone.
final class ShardStageArtifactTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shard-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A safetensors file whose header names `tensors` (name -> byte length).
    private func safetensors(_ tensors: [(String, Int)]) throws -> Data {
        var offset = 0
        var header = [String: Any]()
        for (name, bytes) in tensors {
            header[name] = ["dtype": "U8", "shape": [bytes], "data_offsets": [offset, offset + bytes]]
            offset += bytes
        }
        header["__metadata__"] = ["format": "pt"]
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var data = Data()
        withUnsafeBytes(of: UInt64(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(Data(repeating: 0xAB, count: offset))
        return data
    }

    private struct Snapshot {
        let files: [String: Data]
        let manifest: Data
        var hash: String { ContentAddressedManifest.sha256Hex(manifest) }
    }

    /// A four-layer llama snapshot in two shards: the embedding and layers 0-1 in the
    /// first, layers 2-3, the final norm and (unless tied) the head in the second.
    private func snapshot(tiedHead: Bool = false) throws -> Snapshot {
        var first: [(String, Int)] = [("model.embed_tokens.weight", 64)]
        var second: [(String, Int)] = [("model.norm.weight", 8)]
        for layer in 0..<4 {
            let tensors = [("model.layers.\(layer).self_attn.q_proj.weight", 100 + layer), ("model.layers.\(layer).mlp.up_proj.weight", 200)]
            if layer < 2 { first += tensors } else { second += tensors }
        }
        if !tiedHead { second.append(("lm_head.weight", 64)) }
        var weightMap = [String: String]()
        for (name, _) in first { weightMap[name] = "model-00001-of-00002.safetensors" }
        for (name, _) in second { weightMap[name] = "model-00002-of-00002.safetensors" }
        let config: [String: Any] = [
            "model_type": "llama", "num_hidden_layers": 4, "hidden_size": 8, "num_attention_heads": 2, "num_key_value_heads": 2,
        ]
        let files: [String: Data] = [
            "config.json": try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            "tokenizer.json": Data(#"{"version":"1.0"}"#.utf8),
            ShardStageArtifact.indexFile: try JSONSerialization.data(withJSONObject: ["weight_map": weightMap], options: [.sortedKeys]),
            "model-00001-of-00002.safetensors": try safetensors(first),
            "model-00002-of-00002.safetensors": try safetensors(second),
        ]
        let manifest = files.keys.sorted().map { path -> String in
            let data = files[path]!
            return "\(path)\n\(data.count)\n\(ContentAddressedManifest.sha256Hex(data))\n"
        }.joined()
        return Snapshot(files: files, manifest: Data(manifest.utf8))
    }

    private func write(_ snapshot: Snapshot, only paths: [String]? = nil, into name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in snapshot.files where paths?.contains(path) ?? true {
            try data.write(to: directory.appendingPathComponent(path))
        }
        return directory
    }

    private func manifestURL(_ snapshot: Snapshot) throws -> URL {
        let url = root.appendingPathComponent("manifest-\(UUID().uuidString)")
        try snapshot.manifest.write(to: url)
        return url
    }

    private let shared = ["config.json", "tokenizer.json", ShardStageArtifact.indexFile]

    func testManifestIsTheFullSnapshotsSignedHash() throws {
        let snapshot = try snapshot()
        let full = try write(snapshot, into: "full")
        XCTAssertEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: full), snapshot.hash,
                       "the manifest's SHA-256 is the snapshot-manifest artifact hash of the whole snapshot")
    }

    func testEachStageNeedsOnlyItsOwnShards() throws {
        let snapshot = try snapshot()
        let map = try ShardStageArtifact.weightMap(snapshot.files[ShardStageArtifact.indexFile]!)
        let paths = Array(snapshot.files.keys)
        let head = try ShardStageArtifact.files(snapshotPaths: paths, weightMap: map, plan: try PipelineStagePlan(layers: 0..<2, totalLayers: 4))
        XCTAssertEqual(head.weightFiles, ["model-00001-of-00002.safetensors"])
        XCTAssertEqual(head.required, (shared + ["model-00001-of-00002.safetensors"]).sorted())
        let tail = try ShardStageArtifact.files(snapshotPaths: paths, weightMap: map, plan: try PipelineStagePlan(layers: 2..<4, totalLayers: 4))
        XCTAssertEqual(tail.weightFiles, ["model-00002-of-00002.safetensors"])
        // A tied head: the last stage needs the embedding's shard too.
        let tied = try self.snapshot(tiedHead: true)
        let tiedTail = try ShardStageArtifact.files(
            snapshotPaths: Array(tied.files.keys), weightMap: try ShardStageArtifact.weightMap(tied.files[ShardStageArtifact.indexFile]!),
            plan: try PipelineStagePlan(layers: 2..<4, totalLayers: 4))
        XCTAssertEqual(tiedTail.weightFiles, ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"])
        XCTAssertFalse(tiedTail.hasHead)
        // An index naming a file outside the snapshot is refused.
        XCTAssertThrowsError(try ShardStageArtifact.files(
            snapshotPaths: shared, weightMap: map, plan: try PipelineStagePlan(layers: 0..<2, totalLayers: 4)))
    }

    func testAStageDirectoryVerifiesAgainstTheManifestAndCountsItsTensors() throws {
        let snapshot = try snapshot()
        let stage = try write(snapshot, only: shared + ["model-00002-of-00002.safetensors"], into: "tail")
        let inventory = try ShardStageArtifact.verify(
            directory: stage, manifestURL: try manifestURL(snapshot), expectedSHA256: snapshot.hash, layers: 2..<4)
        XCTAssertEqual(inventory.files.weightFiles, ["model-00002-of-00002.safetensors"])
        let tailBytes: Int64 = 102 + 200 + 103 + 200 + 8 + 64
        XCTAssertEqual(inventory.stageWeightBytes, tailBytes, "layers 2-3, the final norm and the head")
        // The whole stage directory does not hash to the artifact: only the manifest proves it.
        XCTAssertNotEqual(try ModelArtifactVerifier.canonicalArtifactHash(directory: stage), snapshot.hash)
        // A head stage: its own shard and layers, the embedding, no head.
        let head = try write(snapshot, only: shared + ["model-00001-of-00002.safetensors"], into: "head")
        let headInventory = try ShardStageArtifact.verify(
            directory: head, manifestURL: try manifestURL(snapshot), expectedSHA256: snapshot.hash, layers: 0..<2)
        let headBytes: Int64 = 64 + 100 + 200 + 101 + 200
        XCTAssertEqual(headInventory.stageWeightBytes, headBytes)
    }

    func testAStageDirectoryIsRefusedWhenItsFilesDoNotProveTheArtifact() throws {
        let snapshot = try snapshot()
        let manifest = try manifestURL(snapshot)
        func refused(_ directory: URL, layers: Range<Int> = 2..<4, expected: String? = nil, manifestURL: URL? = nil, _ fragment: String) {
            XCTAssertThrowsError(try ShardStageArtifact.verify(
                directory: directory, manifestURL: manifestURL ?? manifest, expectedSHA256: expected ?? snapshot.hash, layers: layers)) { error in
                XCTAssertTrue(String(describing: error).contains(fragment), "\(fragment): \(error)")
            }
        }
        // The tail's shard is missing.
        refused(try write(snapshot, only: shared + ["model-00001-of-00002.safetensors"], into: "wrong-shard"), "need model-00002-of-00002.safetensors")
        // A file outside the artifact.
        let extra = try write(snapshot, only: shared + ["model-00002-of-00002.safetensors"], into: "extra")
        try Data("x".utf8).write(to: extra.appendingPathComponent("notes.txt"))
        refused(extra, "is not part of artifact")
        // A stage file whose bytes differ from its manifest entry.
        let tampered = try write(snapshot, only: shared + ["model-00002-of-00002.safetensors"], into: "tampered")
        var bytes = snapshot.files["model-00002-of-00002.safetensors"]!
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: tampered.appendingPathComponent("model-00002-of-00002.safetensors"))
        refused(tampered, "does not match its manifest entry")
        // A manifest that is not the signed artifact's.
        let good = try write(snapshot, only: shared + ["model-00002-of-00002.safetensors"], into: "good")
        refused(good, expected: String(repeating: "0", count: 64), "snapshot manifest")
        // The config is part of every stage.
        refused(try write(snapshot, only: ["tokenizer.json", ShardStageArtifact.indexFile, "model-00002-of-00002.safetensors"], into: "no-config"),
                "config.json is missing")
    }

    func testStageFitUsesTheStagesOwnWeightsAndKVShare() throws {
        let snapshot = try snapshot()
        let stage = try write(snapshot, only: shared + ["model-00002-of-00002.safetensors"], into: "fit")
        let inventory = try ShardStageArtifact.verify(
            directory: stage, manifestURL: try manifestURL(snapshot), expectedSHA256: snapshot.hash, layers: 2..<4)
        // Per token: 4 layers x 2 KV heads x head_dim 4 x K and V x 2 bytes = 128; the
        // stage holds half the layers: 64 bytes per token per sequence.
        let roomy = ShardStageArtifact.fit(inventory: inventory, slots: 8, contextTokens: 1000, hardwareMemoryGB: 64)
        XCTAssertTrue(roomy.fits, roomy.detail)
        let demand: UInt64 = 8 * 1000 * 64
        XCTAssertEqual(roomy.kvDemandBytes, demand)
        XCTAssertEqual(roomy.stageWeightBytes, inventory.stageWeightBytes)
        // On a Mac with nothing to spare after the safety margin the stage cannot hold KV.
        let cramped = ShardStageArtifact.fit(inventory: inventory, slots: 8, contextTokens: 1000, hardwareMemoryGB: 1)
        XCTAssertFalse(cramped.fits)
        XCTAssertEqual(cramped.kvBudgetBytes, 0)
        XCTAssertThrowsError(try ShardGroupServe.proveStage(
            directory: stage, expectedSHA256: snapshot.hash,
            scope: ShardStageScope(snapshotManifestPath: try manifestURL(snapshot).path, layers: 2..<4), layers: 2..<4, slots: 8,
            hardwareMemoryGB: 1)) { error in
            guard case ShardStageArtifactError.doesNotFit = error else { return XCTFail("\(error)") }
        }
    }

    /// R3-C01: a DeepSeek-V3 stage is sized by the expanded per-head keys and
    /// values its attention caches, not the latent single-Mac estimate.
    func testDeepSeekStageFitCountsTheExpandedKVTheStageAllocates() throws {
        let config = try JSONSerialization.data(withJSONObject: [
            "model_type": "deepseek_v3", "num_hidden_layers": 4, "hidden_size": 64, "num_attention_heads": 4,
            "kv_lora_rank": 16, "qk_nope_head_dim": 8, "qk_rope_head_dim": 4, "v_head_dim": 8,
        ])
        // 4 heads x (8 + 4 + 8) x 2 bytes = 160 bytes per token per layer; the
        // stage holds 2 layers; 8 sequences of 1000 tokens.
        XCTAssertEqual(
            ShardStageArtifact.stageKVDemandBytes(configData: config, stageLayers: 2, totalLayers: 4, slots: 8, contextTokens: 1000),
            160 * 2 * 1000 * 8)
        let latent = try XCTUnwrap(AutotuneModelContextCap.kvCacheBytesPerToken(configData: config))
        XCTAssertLessThan(UInt64(latent) * 1000 * 8 / 2, 160 * 2 * 1000 * 8, "the latent estimate is the undercount")
    }

    func testProveStageCoversAStageDirectoryAndAWholeSnapshot() throws {
        let snapshot = try snapshot()
        let stage = try write(snapshot, only: shared + ["model-00002-of-00002.safetensors"], into: "prove-stage")
        let scope = ShardStageScope(snapshotManifestPath: try manifestURL(snapshot).path, layers: 2..<4)
        let proof = try ShardGroupServe.proveStage(
            directory: stage, expectedSHA256: snapshot.hash, scope: scope, layers: 2..<4, slots: 4, hardwareMemoryGB: 64)
        XCTAssertEqual(proof.digest, snapshot.hash, "every stage reports the full artifact digest")
        XCTAssertTrue(proof.weightsVerified)
        XCTAssertTrue(proof.fit.fits)
        XCTAssertThrowsError(try ShardGroupServe.proveStage(
            directory: stage, expectedSHA256: nil, scope: scope, layers: 2..<4, slots: 4, hardwareMemoryGB: 64),
            "a stage directory needs the signed hash")
        let full = try write(snapshot, into: "prove-full")
        let whole = try ShardGroupServe.proveStage(
            directory: full, expectedSHA256: snapshot.hash, scope: nil, layers: 0..<2, slots: 4, hardwareMemoryGB: 64)
        XCTAssertEqual(whole.digest, snapshot.hash)
        let headBytes: Int64 = 64 + 100 + 200 + 101 + 200
        XCTAssertEqual(whole.fit.stageWeightBytes, headBytes)
    }

    func testServePreflightVerifiesAStageDirectoryAndServesOnlyAPoolEntry() async throws {
        let snapshot = try snapshot()
        let stage = try write(snapshot, only: shared + ["model-00002-of-00002.safetensors"], into: "preflight")
        let scope = ShardStageScope(snapshotManifestPath: try manifestURL(snapshot).path, layers: 2..<4)
        var config = AppConfig.defaults()
        config.model = "test-public-model"
        config.modelArtifactPath = stage.path
        config.modelArtifactSHA256 = snapshot.hash
        let lab = try await ServeCommand.runModelArtifactPreflightOutcome(&config, joiningCoordinator: false, shardStage: scope)
        XCTAssertEqual(lab.runtimeBinding?.loadSHA256, snapshot.hash)
        XCTAssertEqual(lab.runtimeBinding?.loadPath, URL(fileURLWithPath: stage.path).standardizedFileURL.path)
        XCTAssertNil(lab.catalogTrust)
        // Without the stage scope the partial directory fails the whole-snapshot hash.
        var whole = config
        do {
            _ = try await ServeCommand.runModelArtifactPreflightOutcome(&whole, joiningCoordinator: false)
            XCTFail("a partial directory is not the whole artifact")
        } catch {
            XCTAssertEqual(error as? ExitCode, ExitCode(2))
        }
        // Joining the coordinator, a stage directory serves only a pool entry.
        var joining = config
        do {
            _ = try await ServeCommand.runModelArtifactPreflightOutcome(&joining, joiningCoordinator: true, shardStage: scope)
            XCTFail("a stage directory never serves a catalog row")
        } catch {
            XCTAssertEqual(error as? ExitCode, ExitCode(2))
        }
        joining.poolModelID = "pool/AbCdEfGhIjKlMnOpQrStUv/test-model"
        let pool = try await ServeCommand.runModelArtifactPreflightOutcome(&joining, joiningCoordinator: true, shardStage: scope)
        XCTAssertEqual(pool.runtimeBinding?.authoritySHA256, snapshot.hash)
        // A stage file that changed fails the preflight.
        var bytes = snapshot.files["model-00002-of-00002.safetensors"]!
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: stage.appendingPathComponent("model-00002-of-00002.safetensors"))
        do {
            _ = try await ServeCommand.runModelArtifactPreflightOutcome(&joining, joiningCoordinator: true, shardStage: scope)
            XCTFail("a changed stage file must fail")
        } catch {
            XCTAssertEqual(error as? ExitCode, ExitCode(2))
        }
    }

    func testConfigsCarryTheSnapshotManifest() throws {
        let head = ShardGroupHeadConfig(
            groupEpoch: 1, headLayerEnd: 2,
            stages: [ShardGroupStageConfig(memberDeviceID: "mac-b", endpoint: "h:1", layerStart: 2, layerEnd: 4)],
            maxConcurrency: 2, snapshotManifest: "/tmp/m")
        XCTAssertEqual(head.stageScope, ShardStageScope(snapshotManifestPath: "/tmp/m", layers: 0..<2))
        var relative = head
        relative.snapshotManifest = "relative/m"
        XCTAssertThrowsError(try relative.validate())
        let member = ShardMemberConfig(
            groupProviderID: "mac-a", groupEpoch: 1, stageIndex: 1, layerStart: 2, layerEnd: 4, listen: "0.0.0.0:7101",
            snapshotManifest: "/tmp/m")
        XCTAssertNoThrow(try member.validate())
        XCTAssertEqual(member.stageScope?.layers, 2..<4)
        XCTAssertNil(ShardMemberConfig(groupProviderID: "mac-a", groupEpoch: 1, stageIndex: 1, layerStart: 2, layerEnd: 4, listen: "0.0.0.0:7101").stageScope)
    }
}
