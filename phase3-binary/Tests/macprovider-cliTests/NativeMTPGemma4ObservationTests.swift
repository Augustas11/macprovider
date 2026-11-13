import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-048-R002 (0.1.94) `gemma4_mtp_v1` embedded checkpoint: an MLX affine
/// 8-bit target with bfloat16 scales in the target shards, and the
/// unquantized bfloat16 assistant in `model-mtp.safetensors`.
final class NativeMTPGemma4ObservationTests: XCTestCase {
    private struct TensorFixture {
        let name: String
        let dtype: String
        let shape: [Int]
    }

    /// A 4-row module with 64 logical inputs at 8 bits (one group of 64).
    private func quantized(_ module: String, bits: Int = 8, scaleDType: String = "BF16") -> [TensorFixture] {
        [
            TensorFixture(name: "\(module).weight", dtype: "U32", shape: [4, 64 * bits / 32]),
            TensorFixture(name: "\(module).scales", dtype: scaleDType, shape: [4, 1]),
            TensorFixture(name: "\(module).biases", dtype: scaleDType, shape: [4, 1]),
        ]
    }

    /// The target shards' layout: quantized tied embeddings and projections,
    /// bf16 norms, and the audio/vision namespaces the text loader drops.
    private func targetTensors() -> [TensorFixture] {
        quantized("language_model.model.embed_tokens")
            + quantized("language_model.model.layers.0.self_attn.q_proj")
            + quantized("language_model.model.layers.0.mlp.down_proj")
            + quantized("embed_audio.embedding_projection")
            + quantized("embed_vision.embedding_projection")
            + [
                TensorFixture(name: "language_model.model.layers.0.input_layernorm.weight", dtype: "BF16", shape: [64]),
                TensorFixture(name: "language_model.model.layers.0.layer_scalar", dtype: "BF16", shape: [1]),
                TensorFixture(name: "language_model.model.norm.weight", dtype: "BF16", shape: [64]),
                // Unpaired rank-2 bf16 weight under a dropped root.
                TensorFixture(name: "vision_embedder.patch_dense.weight", dtype: "BF16", shape: [64, 128]),
                TensorFixture(name: "vision_embedder.pos_embedding", dtype: "BF16", shape: [8, 2, 64]),
            ]
    }

    private func assistantTensors() -> [TensorFixture] {
        [
            TensorFixture(name: "language_model.mtp.model.embed_tokens.weight", dtype: "BF16", shape: [32, 16]),
            TensorFixture(name: "language_model.mtp.model.layers.0.self_attn.q_proj.weight", dtype: "BF16", shape: [16, 16]),
            TensorFixture(name: "language_model.mtp.model.layers.0.layer_scalar", dtype: "BF16", shape: [1]),
            TensorFixture(name: "language_model.mtp.model.norm.weight", dtype: "BF16", shape: [16]),
        ]
    }

    private func config(edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        let quantization: [String: Any] = ["group_size": 64, "bits": 8, "mode": "affine"]
        var value: [String: Any] = [
            "architectures": ["Gemma4UnifiedForConditionalGeneration"],
            "model_type": "gemma4_unified",
            "text_config": [
                "model_type": "gemma4_unified_text",
                "num_hidden_layers": 1,
                "mtp_num_hidden_layers": 4,
                "mtp_assistant_config": [
                    "model_type": "gemma4_unified_assistant",
                    "dtype": "bfloat16",
                    "text_config": ["num_hidden_layers": 4],
                ] as [String: Any],
            ] as [String: Any],
            "quantization": quantization,
            "quantization_config": quantization,
        ]
        edit(&value)
        return value
    }

    private func editText(_ config: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
        var text = config["text_config"] as! [String: Any]
        edit(&text)
        config["text_config"] = text
    }

    func testEmbeddedObservationAcceptsAnEightBitTargetAndABF16Assistant() throws {
        try withDirectory(config: config(), target: targetTensors(), assistant: assistantTensors()) { directory in
            let pair = try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory)
            XCTAssertTrue(pair.embedded)
            XCTAssertEqual(pair.target.format, .mlxAffine4(bits: 8, groupSize: 64))
            XCTAssertEqual(pair.target.format.sidecarQuantizationLabel, "mlx_affine_8bit")
            XCTAssertEqual(pair.mtp.format, .unquantized(dtype: "bf16"))
            XCTAssertEqual(pair.mtp.format.sidecarQuantizationLabel, "bf16")
            XCTAssertEqual(pair.target.mtpPredictionLayerCount, 4)
            XCTAssertEqual(pair.mtp.mtpPredictionLayerCount, 4)
            // Only the language model's quantized modules; the dropped audio and
            // vision projections are not target weights.
            XCTAssertEqual(
                pair.target.tensorPairs.map(\.weightName).sorted(),
                [
                    "language_model.model.embed_tokens.weight",
                    "language_model.model.layers.0.mlp.down_proj.weight",
                    "language_model.model.layers.0.self_attn.q_proj.weight",
                ]
            )
            XCTAssertTrue(pair.target.tensorPairs.allSatisfy { $0.bitsPerValue == 8 && $0.logicalInputColumns == 64 })

            let representation = try NativeMTPArtifactObserver.affineRepresentation(for: pair)
            XCTAssertEqual(representation, try NativeMTPArtifactObserver.embeddedAssistantRepresentation(for: pair))
            XCTAssertEqual(representation.groupSize, 64)
            XCTAssertTrue(representation.perLayerExceptions.isEmpty)
            XCTAssertTrue(representation.unquantizedExceptions.isEmpty)
            let manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: representation.manifestBytes) as? [String: Any]
            )
            XCTAssertEqual(manifest["schema"] as? String, "macprovider.native-mtp-representation.v1")
            XCTAssertEqual(manifest["mtp"] as? NSDictionary, ["dtype": "bfloat16"] as NSDictionary)
            let target = try XCTUnwrap(manifest["target"] as? [String: Any])
            XCTAssertEqual(target["bits"] as? Int, 8)
            XCTAssertEqual(target["group_size"] as? Int, 64)
        }
    }

    func testEmbeddedObservationRejectsConfigIdentityDrift() throws {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("model_type", { $0["model_type"] = "gemma4" }),
            ("architectures", { $0["architectures"] = ["Gemma4UnifiedForConditionalGeneration", "Other"] }),
            ("text model_type", { self.editText(&$0) { $0["model_type"] = "gemma4_text" } }),
            ("assistant model_type", { self.editText(&$0) { text in
                var assistant = text["mtp_assistant_config"] as! [String: Any]
                assistant["model_type"] = "gemma4_assistant"
                text["mtp_assistant_config"] = assistant
            } }),
            ("assistant dtype", { self.editText(&$0) { text in
                var assistant = text["mtp_assistant_config"] as! [String: Any]
                assistant["dtype"] = "float16"
                text["mtp_assistant_config"] = assistant
            } }),
            ("no assistant config", { self.editText(&$0) { $0["mtp_assistant_config"] = nil } }),
            ("depth mismatch", { self.editText(&$0) { $0["mtp_num_hidden_layers"] = 2 } }),
            ("4-bit target", { config in
                config["quantization"] = ["group_size": 64, "bits": 4, "mode": "affine"]
                config["quantization_config"] = config["quantization"]
            }),
            ("module override", { config in
                let quantization: [String: Any] = [
                    "group_size": 64, "bits": 8, "mode": "affine",
                    "language_model.model.layers.0.mlp.down_proj": ["group_size": 64, "bits": 4, "mode": "affine"],
                ]
                config["quantization"] = quantization
                config["quantization_config"] = quantization
            }),
            ("unquantized module", { config in
                let quantization: [String: Any] = [
                    "group_size": 64, "bits": 8, "mode": "affine",
                    "language_model.model.layers.0.mlp.down_proj": false,
                ]
                config["quantization"] = quantization
                config["quantization_config"] = quantization
            }),
            ("no quantization", { config in
                config["quantization"] = nil
                config["quantization_config"] = nil
            }),
        ]
        for (label, edit) in cases {
            try withDirectory(config: config(edit: edit), target: targetTensors(), assistant: assistantTensors()) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), label)
            }
        }
    }

    func testEmbeddedObservationRejectsTensorsOutsideTheAdmittedLayout() throws {
        let targetCases: [(String, [TensorFixture])] = [
            ("4-bit module", targetTensors() + quantized("language_model.model.layers.0.mlp.up_proj", bits: 4)),
            ("f16 scales", targetTensors() + quantized("language_model.model.layers.0.mlp.up_proj", scaleDType: "F16")),
            ("assistant in target shard", targetTensors() + [
                TensorFixture(name: "language_model.mtp.model.norm.weight", dtype: "BF16", shape: [16]),
            ]),
            ("rotary cache", targetTensors() + [
                TensorFixture(name: "language_model.model.layers.0.self_attn.rotary_emb.inv_freq", dtype: "F32", shape: [4]),
            ]),
            ("activation range", targetTensors() + [
                TensorFixture(name: "language_model.model.layers.0.mlp.down_proj.input_max", dtype: "BF16", shape: [1]),
            ]),
            ("look-alike dropped root", targetTensors() + [
                TensorFixture(name: "vision_embedder_extra.weight", dtype: "BF16", shape: [8]),
            ]),
            ("untied head", targetTensors() + quantized("language_model.lm_head")),
            ("unprefixed key", targetTensors() + [
                TensorFixture(name: "layers.0.input_layernorm.weight", dtype: "BF16", shape: [64]),
            ]),
        ]
        for (label, target) in targetCases {
            try withDirectory(config: config(), target: target, assistant: assistantTensors()) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), label)
            }
        }
        let assistantCases: [(String, [TensorFixture])] = [
            ("f16 assistant", assistantTensors() + [
                TensorFixture(name: "language_model.mtp.model.layers.0.mlp.up_proj.weight", dtype: "F16", shape: [16, 16]),
            ]),
            ("quantized assistant", assistantTensors() + quantized("language_model.mtp.model.layers.0.mlp.up_proj")),
            ("assistant namespace", assistantTensors() + [
                TensorFixture(name: "language_model.model.norm.weight", dtype: "BF16", shape: [64]),
            ]),
        ]
        for (label, assistant) in assistantCases {
            try withDirectory(config: config(), target: targetTensors(), assistant: assistant) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), label)
            }
        }
        try withDirectory(config: config(), target: targetTensors(), assistant: nil) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), "no assistant file")
        }
    }

    // MARK: - Fixtures

    private func withDirectory(
        config: [String: Any],
        target: [TensorFixture],
        assistant: [TensorFixture]?,
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMTPGemma4ObservationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("config.json"))
        // Two target shards, as the published checkpoint splits them.
        let split = target.count / 2
        try safetensorsBytes(tensors: Array(target[..<split]))
            .write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        try safetensorsBytes(tensors: Array(target[split...]))
            .write(to: directory.appendingPathComponent("model-00002-of-00002.safetensors"))
        if let assistant {
            try safetensorsBytes(tensors: assistant)
                .write(to: directory.appendingPathComponent(NativeMTPArtifactObserver.gemma4AssistantWeightFileName))
        }
        try body(directory)
    }

    private func safetensorsBytes(tensors: [TensorFixture]) throws -> Data {
        var header: [String: Any] = [:]
        var offset = 0
        for tensor in tensors {
            let bytes = tensor.shape.reduce(1, *) * bytesPerElement(tensor.dtype)
            header[tensor.name] = ["dtype": tensor.dtype, "shape": tensor.shape, "data_offsets": [offset, offset + bytes]]
            offset += bytes
        }
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var length = UInt64(headerData.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(headerData)
        data.append(Data(repeating: 0, count: offset))
        return data
    }

    private func bytesPerElement(_ dtype: String) -> Int {
        switch dtype {
        case "F16", "BF16": return 2
        case "F32", "U32": return 4
        default: return 1
        }
    }
}
