import CryptoKit
import Foundation
import XCTest
@testable import macprovider_cli

/// SPEC-048-R002 (0.1.130) `inkling2_dspark_v1` embedded checkpoint: the oMLX
/// oQ4e mixed target (global affine 4-bit group 64, affine 8-bit and NVFP4
/// overrides) and the unquantized bfloat16 DSpark draft in `mtp.safetensors`.
final class NativeMTPInkling2ObservationTests: XCTestCase {
    private struct TensorFixture {
        let name: String
        let dtype: String
        let shape: [Int]
    }

    private static let affine8Module = "model.layers.0.mlp.down_proj"
    private static let nvfp4Module = "model.layers.0.mlp.experts.gate_proj"

    private func affine(_ module: String, scaleDType: String = "BF16", biases: Bool = true) -> [TensorFixture] {
        [
            TensorFixture(name: "\(module).weight", dtype: "U32", shape: [4, 8]),
            TensorFixture(name: "\(module).scales", dtype: scaleDType, shape: [4, 1]),
        ] + (biases ? [TensorFixture(name: "\(module).biases", dtype: scaleDType, shape: [4, 1])] : [])
    }

    private func nvfp4(_ module: String, scaleDType: String = "U8", biases: Bool = false) -> [TensorFixture] {
        [
            TensorFixture(name: "\(module).weight", dtype: "U32", shape: [4, 8]),
            TensorFixture(name: "\(module).scales", dtype: scaleDType, shape: [4, 4]),
        ] + (biases ? [TensorFixture(name: "\(module).biases", dtype: "BF16", shape: [4, 4])] : [])
    }

    private func targetTensors() -> [TensorFixture] {
        affine("model.embed_tokens")
            + affine("model.layers.0.self_attn.q_proj")
            + affine(Self.affine8Module)
            + nvfp4(Self.nvfp4Module)
            + affine("lm_head")
            + [
                TensorFixture(name: "model.layers.0.input_layernorm.weight", dtype: "BF16", shape: [64]),
                TensorFixture(name: "model.layers.0.mlp.router.e_score_correction_bias", dtype: "F32", shape: [8]),
                TensorFixture(name: "model.norm.weight", dtype: "BF16", shape: [64]),
            ]
    }

    private func draftTensors(layers: Int = 3) -> [TensorFixture] {
        [
            TensorFixture(name: "fuse_weight", dtype: "BF16", shape: [64, 256]),
            TensorFixture(name: "mask_embed", dtype: "BF16", shape: [64]),
            TensorFixture(name: "markov_head.hidden_out.weight", dtype: "BF16", shape: [64, 16]),
            TensorFixture(name: "markov_head.hidden_out.bias", dtype: "BF16", shape: [64]),
            TensorFixture(name: "norm.weight", dtype: "BF16", shape: [64]),
        ] + (0 ..< layers).flatMap { layer in
            [
                TensorFixture(name: "layers.\(layer).input_layernorm.weight", dtype: "BF16", shape: [64]),
                TensorFixture(name: "layers.\(layer).self_attn.q_proj.weight", dtype: "BF16", shape: [64, 64]),
            ]
        }
    }

    private func quantization(edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var value: [String: Any] = [
            "bits": 4, "group_size": 64, "mode": "affine",
            Self.affine8Module: ["bits": 8, "group_size": 64, "mode": "affine"] as [String: Any],
            Self.nvfp4Module: ["bits": 4, "group_size": 16, "mode": "nvfp4"] as [String: Any],
        ]
        edit(&value)
        return value
    }

    private func config(edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var value: [String: Any] = [
            "model_type": "inkling2_loop",
            "architectures": ["Inkling2LoopForConditionalGeneration"],
            "text_config": ["model_type": "inkling2_loop_text", "hidden_size": 64] as [String: Any],
            "mtp_config": [
                "block_size": 8, "markov_rank": 256, "hidden_size": 64, "num_hidden_layers": 3,
            ] as [String: Any],
            "quantization": quantization(),
        ]
        edit(&value)
        return value
    }

    private func editDraft(_ config: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
        var draft = config["mtp_config"] as! [String: Any]
        edit(&draft)
        config["mtp_config"] = draft
    }

    func testEmbeddedObservationAcceptsTheOQ4eTargetAndABF16Draft() throws {
        try withDirectory(config: config(), target: targetTensors(), draft: draftTensors()) { directory in
            let pair = try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory)
            XCTAssertTrue(pair.embedded)
            guard case .mlxOQ4e(let groupSize, let manifest) = pair.target.format else {
                return XCTFail("expected the oQ4e target format, got \(pair.target.format)")
            }
            XCTAssertEqual(groupSize, 64)
            XCTAssertEqual(pair.target.format.sidecarQuantizationLabel, "mlx_oq4e")
            XCTAssertEqual(pair.mtp.format, .unquantized(dtype: "bf16"))
            XCTAssertEqual(pair.mtp.format.sidecarQuantizationLabel, "bf16")
            XCTAssertEqual(pair.target.mtpPredictionLayerCount, 3)
            XCTAssertEqual(pair.mtp.mtpPredictionLayerCount, 3)

            // The target manifest is the canonical form of the config's
            // quantization object, overrides grouped under `overrides`.
            let quantization = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any]
            )
            XCTAssertEqual(quantization["bits"] as? Int, 4)
            XCTAssertEqual(quantization["group_size"] as? Int, 64)
            XCTAssertEqual(quantization["mode"] as? String, "affine")
            XCTAssertEqual(quantization["overrides"] as? NSDictionary, [
                Self.affine8Module: ["bits": 8, "group_size": 64, "mode": "affine"] as [String: Any],
                Self.nvfp4Module: ["bits": 4, "group_size": 16, "mode": "nvfp4"] as [String: Any],
            ] as NSDictionary)

            let representation = try NativeMTPArtifactObserver.inkling2DSparkRepresentation(for: pair)
            XCTAssertEqual(representation, try NativeMTPArtifactObserver.affineRepresentation(for: pair))
            XCTAssertEqual(representation.groupSize, 64)
            XCTAssertTrue(representation.perLayerExceptions.isEmpty)
            XCTAssertTrue(representation.unquantizedExceptions.isEmpty)
            let document = try XCTUnwrap(
                JSONSerialization.jsonObject(with: representation.manifestBytes) as? [String: Any]
            )
            XCTAssertEqual(document["schema"] as? String, "macprovider.native-mtp-representation.v1")
            XCTAssertEqual(document["mtp"] as? NSDictionary, ["dtype": "bfloat16"] as NSDictionary)
            let target = try XCTUnwrap(document["target"] as? [String: Any])
            XCTAssertEqual(target["kind"] as? String, "mlx_oq4e")
            XCTAssertEqual(target["quantization_sha256"] as? String, Self.sha256Hex(Data(manifest.utf8)))
            XCTAssertEqual(representation.manifestSHA256, Self.sha256Hex(representation.manifestBytes))
        }
    }

    func testModelsNativeMTPIdentityInspectsInklingSnapshot() throws {
        try withDirectory(config: config(), target: targetTensors(), draft: draftTensors()) { directory in
            let tokenizerBytes = Data(#"{"version":"1.0","model":{}}"#.utf8)
            let tokenizerConfigBytes = Data(#"{"chat_template":"{{ messages }}"}"#.utf8)
            try tokenizerBytes.write(to: directory.appendingPathComponent("tokenizer.json"))
            try tokenizerConfigBytes.write(to: directory.appendingPathComponent("tokenizer_config.json"))

            let pair = try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory)
            let expectedRep = try NativeMTPArtifactObserver.inkling2DSparkRepresentation(for: pair)
            let configBytes = try Data(contentsOf: directory.appendingPathComponent("config.json"))

            let identity = try ModelsNativeMTPIdentity.inspect(modelDirectory: directory)
            XCTAssertTrue(identity.embedded)
            XCTAssertEqual(identity.mtpHeadCount, 3)
            XCTAssertEqual(identity.quantizationKind, "mlx_oq4e")
            XCTAssertEqual(identity.blockSizeElements, 64)
            XCTAssertEqual(identity.representationManifestSHA256, expectedRep.manifestSHA256)
            XCTAssertEqual(identity.tokenizerSHA256, Self.sha256Hex(tokenizerBytes))
            XCTAssertEqual(identity.mtpManifestSHA256, Self.sha256Hex(configBytes))
            XCTAssertNotNil(identity.cbTokenizerSHA256)
            XCTAssertNotNil(identity.chatTemplateSHA256)
            XCTAssertNotNil(identity.artifactHash)
            XCTAssertEqual(identity.decodePathDigest, DecodePathIdentity.digest)
            XCTAssertTrue(identity.cbHardwareClass.hasPrefix("apple-silicon:"))
            XCTAssertEqual(identity.cbKernelIdentifier, PagedKVGatherKernel.registeredKernelName)

            let json = identity.jsonObject
            XCTAssertEqual(json["schema"] as? String, ModelsNativeMTPIdentity.schemaVersion)
            XCTAssertEqual(json["cb_hardware_class"] as? String, identity.cbHardwareClass)
            XCTAssertEqual(json["cb_kernel_identifier"] as? String, PagedKVGatherKernel.registeredKernelName)
            let quant = try XCTUnwrap(json["quantization"] as? [String: Any])
            XCTAssertEqual(quant["kind"] as? String, "mlx_oq4e")
            XCTAssertEqual(quant["representation_manifest_sha256"] as? String, expectedRep.manifestSHA256)
        }
    }

    func testRepresentationBindsTheQuantizationObject() throws {
        func digest(_ edit: @escaping (inout [String: Any]) -> Void) throws -> String {
            var result = ""
            let edited = config { $0["quantization"] = self.quantization(edit: edit) }
            try withDirectory(config: edited, target: targetTensors(), draft: draftTensors()) { directory in
                let pair = try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory)
                result = try NativeMTPArtifactObserver.inkling2DSparkRepresentation(for: pair).manifestSHA256
            }
            return result
        }
        let base = try digest { _ in }
        // An override moving one module to 4-bit affine is a different artifact.
        let moved = try digest { $0[Self.affine8Module] = ["bits": 4, "group_size": 64, "mode": "affine"] as [String: Any] }
        XCTAssertNotEqual(base, moved)
        XCTAssertEqual(base, try digest { _ in })
    }

    func testEmbeddedObservationRejectsConfigIdentityDrift() throws {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("architectures", { $0["architectures"] = ["Inkling2LoopForConditionalGeneration", "Other"] }),
            ("text model_type", { $0["text_config"] = ["model_type": "inkling2_text", "hidden_size": 64] as [String: Any] }),
            ("no draft config", { $0["mtp_config"] = nil }),
            ("block size", { self.editDraft(&$0) { $0["block_size"] = 4 } }),
            ("markov rank", { self.editDraft(&$0) { $0["markov_rank"] = 0 } }),
            ("draft hidden size", { self.editDraft(&$0) { $0["hidden_size"] = 32 } }),
            ("two draft layers", { self.editDraft(&$0) { $0["num_hidden_layers"] = 2 } }),
            ("no draft layer count", { self.editDraft(&$0) { $0["num_hidden_layers"] = nil } }),
            ("no quantization", { $0["quantization"] = nil }),
            ("8-bit global", { $0["quantization"] = self.quantization { $0["bits"] = 8 } }),
            ("group 32 global", { $0["quantization"] = self.quantization { $0["group_size"] = 32 } }),
            ("mxfp8 override", { $0["quantization"] = self.quantization {
                $0[Self.nvfp4Module] = ["bits": 8, "group_size": 32, "mode": "mxfp8"] as [String: Any]
            } }),
            ("nvfp4 group 32", { $0["quantization"] = self.quantization {
                $0[Self.nvfp4Module] = ["bits": 4, "group_size": 32, "mode": "nvfp4"] as [String: Any]
            } }),
            ("unquantized override", { $0["quantization"] = self.quantization { $0[Self.affine8Module] = false } }),
            ("extra override key", { $0["quantization"] = self.quantization {
                $0[Self.affine8Module] = ["bits": 8, "group_size": 64, "mode": "affine", "extra": 1] as [String: Any]
            } }),
            ("override of no module", { $0["quantization"] = self.quantization {
                $0["model.layers.9.mlp.down_proj"] = ["bits": 8, "group_size": 64, "mode": "affine"] as [String: Any]
            } }),
        ]
        for (label, edit) in cases {
            try withDirectory(config: config(edit: edit), target: targetTensors(), draft: draftTensors()) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), label)
            }
        }
    }

    func testEmbeddedObservationRejectsTensorsOutsideTheAdmittedLayout() throws {
        let plain = targetTensors().filter { !$0.name.hasPrefix(Self.affine8Module) && !$0.name.hasPrefix(Self.nvfp4Module) }
        let targetCases: [(String, [TensorFixture])] = [
            ("affine u8 scales", plain + affine(Self.affine8Module, scaleDType: "U8") + nvfp4(Self.nvfp4Module)),
            ("affine f16 scales", plain + affine(Self.affine8Module, scaleDType: "F16") + nvfp4(Self.nvfp4Module)),
            ("affine without biases", plain + affine(Self.affine8Module, biases: false) + nvfp4(Self.nvfp4Module)),
            ("nvfp4 bf16 scales", plain + affine(Self.affine8Module) + nvfp4(Self.nvfp4Module, scaleDType: "BF16")),
            ("nvfp4 with biases", plain + affine(Self.affine8Module) + nvfp4(Self.nvfp4Module, biases: true)),
            ("f16 tensor", targetTensors() + [
                TensorFixture(name: "model.layers.0.post_attention_layernorm.weight", dtype: "F16", shape: [64]),
            ]),
            ("unpacked weight", targetTensors().map {
                $0.name == "lm_head.weight" ? TensorFixture(name: $0.name, dtype: "BF16", shape: [4, 64]) : $0
            }),
        ]
        for (label, target) in targetCases {
            try withDirectory(config: config(), target: target, draft: draftTensors()) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), label)
            }
        }
        let draftCases: [(String, [TensorFixture])] = [
            ("f16 draft", draftTensors() + [
                TensorFixture(name: "layers.0.mlp.up_proj.weight", dtype: "F16", shape: [64, 64]),
            ]),
            ("quantized draft", draftTensors() + [
                TensorFixture(name: "layers.0.mlp.up_proj.weight", dtype: "U32", shape: [64, 8]),
                TensorFixture(name: "layers.0.mlp.up_proj.scales", dtype: "BF16", shape: [64, 1]),
            ]),
            ("draft namespace", draftTensors() + [
                TensorFixture(name: "model.norm.weight", dtype: "BF16", shape: [64]),
            ]),
            ("fourth draft layer", draftTensors() + [
                TensorFixture(name: "layers.3.input_layernorm.weight", dtype: "BF16", shape: [64]),
            ]),
            ("padded layer index", draftTensors() + [
                TensorFixture(name: "layers.01.input_layernorm.weight", dtype: "BF16", shape: [64]),
            ]),
            ("missing draft layer", draftTensors(layers: 2)),
        ]
        for (label, draft) in draftCases {
            try withDirectory(config: config(), target: targetTensors(), draft: draft) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), label)
            }
        }
        try withDirectory(config: config(), target: targetTensors(), draft: nil) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), "no draft file")
        }
    }

    func testRepresentationRequiresTheInklingPairShape() throws {
        func observation(
            target: NativeMTPObservedArtifactFormat = .mlxOQ4e(groupSize: 64, quantizationManifest: "{}"),
            mtp: NativeMTPObservedArtifactFormat = .unquantized(dtype: "bf16"),
            layers: Int = 3,
            embedded: Bool = true
        ) -> NativeMTPArtifactPairObservation {
            NativeMTPArtifactPairObservation(
                target: NativeMTPArtifactObservation(format: target, mtpPredictionLayerCount: layers, tensorPairs: []),
                mtp: NativeMTPArtifactObservation(format: mtp, mtpPredictionLayerCount: layers, tensorPairs: []),
                embedded: embedded
            )
        }
        XCTAssertNoThrow(try NativeMTPArtifactObserver.inkling2DSparkRepresentation(for: observation()))
        XCTAssertThrowsError(try NativeMTPArtifactObserver.inkling2DSparkRepresentation(
            for: observation(target: .mlxOQ4e(groupSize: 32, quantizationManifest: "{}"))))
        XCTAssertThrowsError(try NativeMTPArtifactObserver.inkling2DSparkRepresentation(
            for: observation(target: .mlxAffine4(bits: 4, groupSize: 64))))
        XCTAssertThrowsError(try NativeMTPArtifactObserver.inkling2DSparkRepresentation(
            for: observation(mtp: .unquantized(dtype: "f16"))))
        XCTAssertThrowsError(try NativeMTPArtifactObserver.inkling2DSparkRepresentation(for: observation(layers: 2)))
        XCTAssertThrowsError(try NativeMTPArtifactObserver.inkling2DSparkRepresentation(for: observation(embedded: false)))
        // The Gemma 4 path does not accept the oQ4e target either.
        XCTAssertThrowsError(try NativeMTPArtifactObserver.embeddedAssistantRepresentation(for: observation()))
    }

    // MARK: - Fixtures

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func withDirectory(
        config: [String: Any],
        target: [TensorFixture],
        draft: [TensorFixture]?,
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMTPInkling2ObservationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("config.json"))
        let split = target.count / 2
        try safetensorsBytes(tensors: Array(target[..<split]))
            .write(to: directory.appendingPathComponent("model-00001-of-00002.safetensors"))
        try safetensorsBytes(tensors: Array(target[split...]))
            .write(to: directory.appendingPathComponent("model-00002-of-00002.safetensors"))
        if let draft {
            try safetensorsBytes(tensors: draft)
                .write(to: directory.appendingPathComponent(NativeMTPArtifactObserver.inkling2DraftWeightFileName))
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
