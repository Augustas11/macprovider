import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-048-R002 (0.1.35/0.1.36) `glm5_next_mtp_v1` embedded checkpoint and
/// SPEC-023-R024 (v0.22.27) override widths and exception bound.
final class NativeMTPGLM5NextObservationTests: XCTestCase {
    private struct TensorFixture {
        let name: String
        let dtype: String
        let shape: [Int]
    }

    private static let overrides: [String: [String: Any]] = [
        "language_model.lm_head": ["bits": 8, "group_size": 64, "mode": "affine"],
        "language_model.model.embed_tokens": ["bits": 8, "group_size": 64, "mode": "affine"],
        "language_model.model.layers.0.self_attn.b_proj": ["bits": 5, "group_size": 64, "mode": "affine"],
        "language_model.model.layers.0.self_attn.o_proj": ["bits": 6, "group_size": 64, "mode": "affine"],
        "language_model.mtp.0.block.self_attn.embed_q": ["bits": 5, "group_size": 64, "mode": "affine"],
    ]

    /// A 4-row module with 64 logical inputs at `bits` (one group of 64).
    private func quantized(_ module: String, bits: Int) -> [TensorFixture] {
        [
            TensorFixture(name: "\(module).weight", dtype: "U32", shape: [4, 64 * bits / 32]),
            TensorFixture(name: "\(module).scales", dtype: "BF16", shape: [4, 1]),
            TensorFixture(name: "\(module).biases", dtype: "BF16", shape: [4, 1]),
        ]
    }

    private func baseTensors() -> [TensorFixture] {
        quantized("language_model.lm_head", bits: 8)
            + quantized("language_model.model.embed_tokens", bits: 8)
            + quantized("language_model.model.layers.0.self_attn.b_proj", bits: 5)
            + quantized("language_model.model.layers.0.self_attn.o_proj", bits: 6)
            + quantized("language_model.model.layers.0.mlp.down_proj", bits: 4)
            + quantized("language_model.mtp.0.block.self_attn.embed_q", bits: 5)
            + [
                TensorFixture(name: "language_model.model.norm.weight", dtype: "BF16", shape: [64]),
                TensorFixture(name: "language_model.model.layers.0.attn_hc.fn", dtype: "F32", shape: [24, 64]),
                TensorFixture(name: "language_model.model.layers.0.attn_hc.base", dtype: "F32", shape: [24]),
                TensorFixture(name: "language_model.model.layers.0.mlp.gate.weight", dtype: "F32", shape: [8, 64]),
                TensorFixture(name: "language_model.model.layers.0.self_attn.conv1d.weight", dtype: "BF16", shape: [12, 4, 1]),
                TensorFixture(name: "language_model.model.layers.0.self_attn.indexer.index_kpool_compress_ape", dtype: "BF16", shape: [4, 16]),
                TensorFixture(name: "language_model.model.layers.0.self_attn.indexer.index_kpool_compress_gate", dtype: "BF16", shape: [16, 64]),
                TensorFixture(name: "language_model.mtp.0.eh_proj.weight", dtype: "BF16", shape: [64, 128]),
                TensorFixture(name: "language_model.mtp.0.block.mlp.gate.weight", dtype: "F32", shape: [8, 64]),
                // Vision tensors the GLM5Next loader drops.
                TensorFixture(name: "vision_model.blocks.0.attn.qkv.weight", dtype: "BF16", shape: [12, 8]),
                TensorFixture(name: "visual.merger.proj.weight", dtype: "BF16", shape: [8, 8]),
            ]
    }

    private func config(
        overrides: [String: [String: Any]] = NativeMTPGLM5NextObservationTests.overrides,
        edit: (inout [String: Any]) -> Void = { _ in }
    ) -> [String: Any] {
        var quantization: [String: Any] = ["group_size": 64, "bits": 4, "mode": "affine"]
        for (key, value) in overrides { quantization[key] = value }
        var value: [String: Any] = [
            "architectures": ["Glm5NextForConditionalGeneration"],
            "model_type": "glm5_next",
            "text_config": [
                "model_type": "glm5_next_text",
                "num_hidden_layers": 1,
                "num_nextn_predict_layers": 1,
            ],
            "quantization": quantization,
            "quantization_config": quantization,
        ]
        edit(&value)
        return value
    }

    func testEmbeddedObservationAcceptsAPostSanitizeCheckpointWithFiveSixEightBitOverrides() throws {
        try withDirectory(config: config(), tensors: baseTensors()) { directory in
            let pair = try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory)
            XCTAssertTrue(pair.embedded)
            XCTAssertEqual(pair.target, pair.mtp)
            XCTAssertEqual(pair.target.format, .mlxAffine4(bits: 4, groupSize: 64))
            XCTAssertEqual(pair.target.mtpPredictionLayerCount, 1)
            let byName = Dictionary(uniqueKeysWithValues: pair.target.tensorPairs.map { ($0.weightName, $0) })
            XCTAssertEqual(byName["language_model.model.layers.0.self_attn.b_proj.weight"]?.bitsPerValue, 5)
            XCTAssertEqual(byName["language_model.model.layers.0.self_attn.b_proj.weight"]?.logicalInputColumns, 64)
            XCTAssertEqual(byName["language_model.model.layers.0.self_attn.o_proj.weight"]?.bitsPerValue, 6)
            XCTAssertEqual(byName["language_model.model.layers.0.self_attn.o_proj.weight"]?.logicalInputColumns, 64)
            XCTAssertEqual(byName["language_model.model.layers.0.mlp.down_proj.weight"]?.bitsPerValue, 4)

            let representation = try NativeMTPArtifactObserver.affineRepresentation(for: pair)
            // Recorded once, under target/, including the next-N module.
            XCTAssertEqual(
                representation.perLayerExceptions,
                Self.overrides.keys.map { "target/\($0)" }.sorted()
            )
            XCTAssertTrue(representation.unquantizedExceptions.isEmpty)
            let manifest = try XCTUnwrap(
                JSONSerialization.jsonObject(with: representation.manifestBytes) as? [String: Any]
            )
            XCTAssertEqual(manifest["mtp"] as? NSDictionary, manifest["target"] as? NSDictionary)
        }
    }

    func testEmbeddedObservationRejectsConfigIdentityDrift() throws {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("model_type", { $0["model_type"] = "glm5" }),
            ("architectures", { $0["architectures"] = ["Glm5NextForConditionalGeneration", "Other"] }),
            ("text model_type", { config in
                var text = config["text_config"] as! [String: Any]
                text["model_type"] = "glm5_next"
                config["text_config"] = text
            }),
            ("nextn count", { config in
                var text = config["text_config"] as! [String: Any]
                text["num_nextn_predict_layers"] = 2
                config["text_config"] = text
            }),
        ]
        for (label, edit) in cases {
            try withDirectory(config: config(edit: edit), tensors: baseTensors()) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), label)
            }
        }
    }

    func testEmbeddedObservationRejectsNamesTheLoaderWouldRewriteOrDrop() throws {
        let rejected: [TensorFixture] = [
            TensorFixture(name: "language_model.mtp.1.block.input_layernorm.weight", dtype: "BF16", shape: [64]),
            TensorFixture(name: "mtp.0.enorm.weight", dtype: "BF16", shape: [64]),
            TensorFixture(name: "model.language_model.norm.weight", dtype: "BF16", shape: [64]),
            // A DeepSeek-style next-N layer at index num_hidden_layers.
            TensorFixture(name: "language_model.model.layers.1.input_layernorm.weight", dtype: "BF16", shape: [64]),
            TensorFixture(name: "language_model.mtp.0.shared_head.norm.weight", dtype: "BF16", shape: [64]),
            TensorFixture(name: "language_model.model.layers.0.hc_attn_fn", dtype: "F32", shape: [24, 64]),
            TensorFixture(name: "language_model.model.layers.0.self_attn.kv_b_proj.weight", dtype: "BF16", shape: [8, 64]),
            TensorFixture(name: "language_model.model.layers.0.self_attn.q_conv1d.weight", dtype: "BF16", shape: [4, 4, 1]),
            TensorFixture(name: "language_model.model.layers.0.self_attn.A_log", dtype: "F32", shape: [4]),
            TensorFixture(name: "language_model.model.layers.0.mlp.experts.0.down_proj.weight", dtype: "BF16", shape: [8, 64]),
            TensorFixture(name: "vision_tower_extra.weight", dtype: "BF16", shape: [8]),
            TensorFixture(name: "lm_head.weight", dtype: "BF16", shape: [8, 64]),
        ]
        for tensor in rejected {
            try withDirectory(config: config(), tensors: baseTensors() + [tensor]) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), tensor.name) { error in
                    XCTAssertEqual(
                        error as? NativeMTPArtifactObservationError,
                        .incompatibleSafetensorsHeaders("glm5_next tensor namespace \(tensor.name)"),
                        tensor.name
                    )
                }
            }
        }
    }

    func testEmbeddedObservationRejectsAnUnlistedUnpairedFloatingWeight() throws {
        let extra = TensorFixture(name: "language_model.model.layers.0.self_attn.q_b_proj.weight", dtype: "BF16", shape: [8, 64])
        try withDirectory(config: config(), tensors: baseTensors() + [extra]) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory))
        }
    }

    func testOverrideWidthsOtherThanFourFiveSixEightFailClosed() throws {
        for bits in [2, 3, 7] {
            var overrides = Self.overrides
            overrides["language_model.model.layers.0.self_attn.b_proj"] = ["bits": bits, "group_size": 64]
            try withDirectory(config: config(overrides: overrides), tensors: baseTensors()) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory)) { error in
                    XCTAssertEqual(
                        error as? NativeMTPArtifactObservationError,
                        .unsupportedQuantization("mlx affine module override bits"),
                        "bits \(bits)"
                    )
                }
            }
        }
    }

    /// A separate-artifact pair records target and MTP overrides under their
    /// own prefixes; up to 1024 entries are admitted (SPEC-023 v0.22.27).
    func testAffineRepresentationAdmitsUpTo1024Exceptions() throws {
        func pair(count: Int) -> NativeMTPArtifactPairObservation {
            var overrides: [String: NativeMTPAffineModuleOverride] = [:]
            for index in 0..<count {
                overrides[String(format: "language_model.model.layers.%04d.mlp.down_proj", index)] =
                    NativeMTPAffineModuleOverride(bits: index % 2 == 0 ? 5 : 6, groupSize: 64)
            }
            let target = NativeMTPArtifactObservation(
                format: .mlxAffine4(bits: 4, groupSize: 64),
                mtpPredictionLayerCount: 1,
                tensorPairs: [],
                affineModuleOverrides: overrides
            )
            return NativeMTPArtifactPairObservation(target: target, mtp: target, embedded: true)
        }
        XCTAssertEqual(try NativeMTPArtifactObserver.affineRepresentation(for: pair(count: 1024)).perLayerExceptions.count, 1024)
        XCTAssertThrowsError(try NativeMTPArtifactObserver.affineRepresentation(for: pair(count: 1025))) { error in
            XCTAssertEqual(
                error as? NativeMTPArtifactObservationError,
                .unsupportedQuantization("mlx affine too many per-layer exceptions")
            )
        }
    }

    /// Lab-only: observe the real GLM-5.3-Flash artifact's headers (no weights
    /// are loaded). Set MACPROVIDER_GLM53_ARTIFACT_DIR to the snapshot.
    func testRealGLM53ArtifactObservesWith554Overrides() throws {
        guard let path = ProcessInfo.processInfo.environment["MACPROVIDER_GLM53_ARTIFACT_DIR"], !path.isEmpty else {
            throw XCTSkip("MACPROVIDER_GLM53_ARTIFACT_DIR not set")
        }
        let pair = try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: URL(fileURLWithPath: path, isDirectory: true))
        let representation = try NativeMTPArtifactObserver.affineRepresentation(for: pair)
        XCTAssertEqual(representation.perLayerExceptions.count, 554)
        XCTAssertTrue(representation.perLayerExceptions.allSatisfy { $0.hasPrefix("target/") })
        XCTAssertTrue(representation.unquantizedExceptions.isEmpty)
        XCTAssertEqual(representation.groupSize, 64)
        print("glm53 representation_manifest_sha256=\(representation.manifestSHA256)")
    }

    private func withDirectory(
        config: [String: Any],
        tensors: [TensorFixture],
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMTPGLM5NextObservationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("config.json"))
        try safetensorsBytes(tensors: tensors).write(to: directory.appendingPathComponent("model.safetensors"))
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
