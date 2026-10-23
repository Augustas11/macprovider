import Foundation
@testable import MacProviderCore
@testable import macprovider_cli
import XCTest

/// Issue #2084 slice 3: `shard-bench --plan` reads planner inputs from a model
/// directory's config and safetensors headers.
final class ShardBenchPlanTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    /// A safetensors file whose header names `tensors` (name -> byte length) back to
    /// back, followed by that many zero bytes.
    private func writeSafetensors(_ tensors: [(String, Int)], to url: URL) throws {
        var header = [String: Any]()
        var offset = 0
        for (name, size) in tensors {
            header[name] = ["dtype": "U8", "shape": [size], "data_offsets": [offset, offset + size]]
            offset += size
        }
        let json = try JSONSerialization.data(withJSONObject: header)
        var data = Data()
        withUnsafeBytes(of: UInt64(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(Data(count: offset))
        try data.write(to: url)
    }

    private func modelDirectory(config: [String: Any], files: [[(String, Int)]]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shard-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
        for (index, tensors) in files.enumerated() {
            try writeSafetensors(tensors, to: directory.appendingPathComponent("model-\(index).safetensors"))
        }
        return directory
    }

    func testModelInputComesFromHeadersAndConfig() throws {
        let directory = try modelDirectory(
            config: ["model_type": "deepseek_v3", "num_hidden_layers": 3, "num_attention_heads": 4,
                     "qk_nope_head_dim": 8, "qk_rope_head_dim": 4, "v_head_dim": 8, "hidden_size": 32],
            files: [
                [("model.embed_tokens.weight", 100), ("model.layers.0.self_attn.q_proj.weight", 10),
                 ("model.layers.0.mlp.gate_proj.weight", 5)],
                [("model.layers.1.mlp.experts.0.weight", 40), ("model.layers.2.mlp.experts.0.weight", 60),
                 ("model.layers.3.mtp.weight", 999), ("model.norm.weight", 3), ("lm_head.weight", 100),
                 ("extra.rotary.weight", 7)],
            ])
        let input = try ShardBenchPlanInput.model(directory: directory)
        XCTAssertEqual(input.modelType, "deepseek_v3")
        XCTAssertEqual(input.model.layerWeightBytes, [15, 40, 60], "layer 3 (an MTP head past num_hidden_layers) is not loaded")
        XCTAssertEqual(input.model.embeddingBytes, 100)
        XCTAssertEqual(input.model.headBytes, 103)
        XCTAssertEqual(input.model.sharedBytes, 7)
        XCTAssertEqual(input.model.kvBytesPerTokenPerLayer, 4 * (8 + 4 + 8) * 2)

        let plan = try ShardPlacementPlanner.plan(
            members: try ShardBenchPlanInput.members("a=1000,b=1000"), model: input.model, contextTokens: 2)
        XCTAssertEqual(plan.stages.map(\.layerStart), [0, 2])
        XCTAssertEqual(plan.stages.last?.layerEnd, 3)
    }

    func testTiedEmbeddingCountsAsTheHeadAndGQAKV() throws {
        let directory = try modelDirectory(
            config: ["model_type": "llama", "num_hidden_layers": 2, "num_attention_heads": 8,
                     "num_key_value_heads": 2, "hidden_size": 64],
            files: [[("model.embed_tokens.weight", 50), ("model.layers.0.w", 9), ("model.layers.1.w", 9), ("model.norm.weight", 1)]])
        let input = try ShardBenchPlanInput.model(directory: directory)
        XCTAssertEqual(input.model.headBytes, 51)
        XCTAssertEqual(input.model.kvBytesPerTokenPerLayer, 2 * 2 * 8 * 2)
    }

    func testMemberAndSizeParsing() throws {
        let members = try ShardBenchPlanInput.members("studio=480GB:2,air=214GiB,mini=1000")
        XCTAssertEqual(members, [
            ShardPlacementMember(id: "studio", usableMemoryBytes: 480_000_000_000, computeWeight: 2),
            ShardPlacementMember(id: "air", usableMemoryBytes: 214 * 1_073_741_824),
            ShardPlacementMember(id: "mini", usableMemoryBytes: 1000),
        ])
        XCTAssertThrowsError(try ShardBenchPlanInput.members("studio"))
        XCTAssertThrowsError(try ShardBenchPlanInput.members("studio=lots"))
        XCTAssertThrowsError(try ShardBenchPlanInput.members("studio=10GB:fast"))
        XCTAssertThrowsError(try ShardBenchPlanInput.bytes("-5GB"))
    }
}
