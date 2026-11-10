import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import XCTest
@testable import macprovider_cli

/// SPEC-048-R002 (0.1.35/0.1.36/0.1.80) `glm5_next_mtp_v1` embedded checkpoint
/// in the post-sanitize and the Hugging Face pre-sanitize layouts, and
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

    /// Names that collide with a post-sanitize key, that the loader would drop
    /// silently, or that it leaves unmapped (a module the model lacks).
    func testEmbeddedObservationRejectsCollidingDroppedOrUnmappedNames() throws {
        let rejected: [TensorFixture] = [
            TensorFixture(name: "language_model.mtp.1.block.input_layernorm.weight", dtype: "BF16", shape: [64]),
            // Same loader key as `language_model.model.norm.weight`.
            TensorFixture(name: "model.language_model.norm.weight", dtype: "BF16", shape: [64]),
            // A second next-N layer (index num_hidden_layers + 1).
            TensorFixture(name: "language_model.model.layers.2.input_layernorm.weight", dtype: "BF16", shape: [64]),
            TensorFixture(name: "language_model.mtp.0.shared_head.norm.weight", dtype: "BF16", shape: [64]),
            // Same loader key as `...layers.0.attn_hc.fn`.
            TensorFixture(name: "language_model.model.layers.0.hc_attn_fn", dtype: "F32", shape: [24, 64]),
            // No `kv_b_proj.weight`, so the loader leaves it unsplit.
            TensorFixture(name: "language_model.model.layers.0.self_attn.kv_b_proj.scales", dtype: "BF16", shape: [8, 1]),
            // No k/v parts, so the loader leaves it unconcatenated.
            TensorFixture(name: "language_model.model.layers.0.self_attn.q_conv1d.weight", dtype: "BF16", shape: [4, 4, 1]),
            // Experts not numbered from 0, so the loader leaves them unstacked.
            TensorFixture(name: "language_model.model.layers.0.mlp.experts.1.down_proj.weight", dtype: "BF16", shape: [8, 64]),
            TensorFixture(name: "vision_tower_extra.weight", dtype: "BF16", shape: [8]),
            // Same loader key as `language_model.lm_head.weight`.
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

    // MARK: Hugging Face pre-sanitize layout (0.1.80)

    private static let hfOverrides: [String: [String: Any]] = [
        "lm_head": ["bits": 8, "group_size": 64],
        "model.language_model.embed_tokens": ["bits": 8, "group_size": 64],
        "model.language_model.layers.0.mlp.experts.0.up_proj": ["bits": 8, "group_size": 64],
        "model.language_model.layers.0.mlp.experts.1.up_proj": ["bits": 8, "group_size": 64],
        "model.language_model.layers.0.self_attn.kv_b_proj": ["bits": 5, "group_size": 64],
        // The next-N layer's attention, stored as layer num_hidden_layers.
        "model.language_model.layers.1.self_attn.o_proj": ["bits": 6, "group_size": 64],
    ]

    /// The same model as `baseTensors` in the layout the Hugging Face
    /// checkpoint ships: `model.language_model.*`, per-expert weights, raw
    /// `hc_*` / forget-gate / conv / `kv_b_proj` names, a quantized router
    /// gate and the next-N layer at index `num_hidden_layers`.
    private func hfTensors() -> [TensorFixture] {
        quantized("lm_head", bits: 8)
            + quantized("model.language_model.embed_tokens", bits: 8)
            + quantized("model.language_model.layers.0.mlp.experts.0.up_proj", bits: 8)
            + quantized("model.language_model.layers.0.mlp.experts.1.up_proj", bits: 8)
            + quantized("model.language_model.layers.0.mlp.experts.0.down_proj", bits: 4)
            + quantized("model.language_model.layers.0.mlp.experts.1.down_proj", bits: 4)
            + quantized("model.language_model.layers.0.self_attn.kv_b_proj", bits: 5)
            // 4 experts x hidden_size 64 at 4 bits, one group of 64.
            + quantized("model.language_model.layers.0.mlp.gate", bits: 4)
            + quantized("model.language_model.layers.1.self_attn.o_proj", bits: 6)
            + [
                TensorFixture(name: "model.language_model.norm.weight", dtype: "BF16", shape: [64]),
                TensorFixture(name: "model.language_model.layers.0.input_layernorm.weight", dtype: "BF16", shape: [64]),
                TensorFixture(name: "model.language_model.layers.0.hc_attn_fn", dtype: "F32", shape: [24, 64]),
                TensorFixture(name: "model.language_model.layers.0.self_attn.A_log", dtype: "F32", shape: [4]),
                TensorFixture(name: "model.language_model.layers.0.self_attn.q_conv1d.weight", dtype: "BF16", shape: [4, 4, 1]),
                TensorFixture(name: "model.language_model.layers.0.self_attn.k_conv1d.weight", dtype: "BF16", shape: [4, 4, 1]),
                TensorFixture(name: "model.language_model.layers.0.self_attn.v_conv1d.weight", dtype: "BF16", shape: [4, 4, 1]),
                TensorFixture(name: "model.language_model.layers.1.eh_proj.weight", dtype: "BF16", shape: [64, 128]),
                TensorFixture(name: "model.language_model.layers.1.enorm.weight", dtype: "BF16", shape: [64]),
                TensorFixture(name: "model.language_model.layers.1.shared_head.norm.weight", dtype: "BF16", shape: [64]),
                // Next-N copies of the head and embedding the loader drops.
                TensorFixture(name: "model.language_model.layers.1.shared_head.head.weight", dtype: "BF16", shape: [8, 64]),
                TensorFixture(name: "model.language_model.layers.1.embed_tokens.weight", dtype: "BF16", shape: [8, 64]),
                TensorFixture(name: "model.visual.merger.proj.weight", dtype: "BF16", shape: [8, 8]),
            ]
    }

    private func hfConfig(overrides: [String: [String: Any]] = NativeMTPGLM5NextObservationTests.hfOverrides) -> [String: Any] {
        config(overrides: overrides) { config in
            var text = config["text_config"] as! [String: Any]
            text["hidden_size"] = 64
            config["text_config"] = text
        }
    }

    func testEmbeddedObservationAcceptsTheHuggingFacePreSanitizeLayout() throws {
        try withDirectory(config: hfConfig(), tensors: hfTensors()) { directory in
            let pair = try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory)
            XCTAssertTrue(pair.embedded)
            XCTAssertEqual(pair.target.format, .mlxAffine4(bits: 4, groupSize: 64))
            let byName = Dictionary(uniqueKeysWithValues: pair.target.tensorPairs.map { ($0.weightName, $0) })
            // Per-expert overrides resolve through the stacked switch_mlp module.
            XCTAssertEqual(byName["model.language_model.layers.0.mlp.experts.1.up_proj.weight"]?.bitsPerValue, 8)
            XCTAssertEqual(byName["model.language_model.layers.0.mlp.experts.1.down_proj.weight"]?.bitsPerValue, 4)
            // `kv_b_proj` resolves through embed_q / unembed_out.
            XCTAssertEqual(byName["model.language_model.layers.0.self_attn.kv_b_proj.weight"]?.bitsPerValue, 5)
            XCTAssertEqual(byName["model.language_model.layers.0.self_attn.kv_b_proj.weight"]?.logicalInputColumns, 64)
            // The router gate's width comes from its shapes against hidden_size.
            XCTAssertEqual(byName["model.language_model.layers.0.mlp.gate.weight"]?.bitsPerValue, 4)
            XCTAssertEqual(byName["model.language_model.layers.0.mlp.gate.weight"]?.groupSize, 64)
            // The next-N layer loads as mtp.0.block.
            XCTAssertEqual(byName["model.language_model.layers.1.self_attn.o_proj.weight"]?.bitsPerValue, 6)

            let representation = try NativeMTPArtifactObserver.affineRepresentation(for: pair)
            // Overrides are recorded under their config keys, as signed.
            XCTAssertEqual(
                representation.perLayerExceptions,
                Self.hfOverrides.keys.map { "target/\($0)" }.sorted()
            )
            XCTAssertTrue(representation.unquantizedExceptions.isEmpty)
        }
    }

    func testHuggingFaceLayoutRejectsForeignCollidingAndUnmappedNames() throws {
        let cases: [(tensors: [TensorFixture], reported: String)] = [
            // A namespace no layout maps under language_model.model / lm_head / mtp.0.
            (hfTensors() + [TensorFixture(name: "transformer.h.0.attn.weight", dtype: "BF16", shape: [64])],
             "transformer.h.0.attn.weight"),
            // A second next-N layer.
            (hfTensors() + [TensorFixture(name: "model.language_model.layers.2.input_layernorm.weight", dtype: "BF16", shape: [64])],
             "model.language_model.layers.2.input_layernorm.weight"),
            // Both layouts for one tensor: the loader would keep one silently.
            (hfTensors() + [TensorFixture(name: "language_model.model.norm.weight", dtype: "BF16", shape: [64])],
             "model.language_model.norm.weight"),
            // Stacking the existing switch_mlp key over per-expert weights.
            (hfTensors() + [TensorFixture(name: "model.language_model.layers.0.mlp.switch_mlp.down_proj.weight", dtype: "BF16", shape: [2, 4, 64])],
             "model.language_model.layers.0.mlp.experts.0.down_proj.weight"),
            // Expert 0 missing: the loader leaves expert 1 unstacked.
            (hfTensors().filter { !$0.name.contains(".mlp.experts.0.down_proj.") },
             "model.language_model.layers.0.mlp.experts.1.down_proj.biases"),
        ]
        for (tensors, reported) in cases {
            try withDirectory(config: hfConfig(), tensors: tensors) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory), reported) { error in
                    XCTAssertEqual(
                        error as? NativeMTPArtifactObservationError,
                        .incompatibleSafetensorsHeaders("glm5_next tensor namespace \(reported)"),
                        reported
                    )
                }
            }
        }
    }

    func testHuggingFaceLayoutRejectsPerExpertOverridesThatDisagree() throws {
        var overrides = Self.hfOverrides
        overrides["model.language_model.layers.0.mlp.experts.1.up_proj"] = ["bits": 6, "group_size": 64]
        try withDirectory(config: hfConfig(overrides: overrides), tensors: hfTensors()) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedQuantization("mlx_affine_4bit conflicting module override")
                )
            }
        }
    }

    func testEmbeddedObservationRejectsACheckpointWithoutTheMTPLayer() throws {
        var overrides = Self.overrides
        overrides["language_model.mtp.0.block.self_attn.embed_q"] = nil
        let tensors = baseTensors().filter { !$0.name.hasPrefix("language_model.mtp.") }
        try withDirectory(config: config(overrides: overrides), tensors: tensors) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("glm5_next missing mtp.0 layer")
                )
            }
        }
    }

    /// Pins the observer's copy of the GLM5Next name rules to the pinned
    /// fork: the keys `GLM5NextModel.sanitize(weights:)` produces, and the
    /// module paths `sanitize(perLayerQuantization:)` adds, must equal the
    /// observer's. A fork bump that changes the mapping fails here.
    func testLoaderKeyMappingMatchesThePinnedGLM5NextSanitizer() throws {
        let model = GLM5NextModel(try ConversationPromptSnapshotTests.tinyGLMConfiguration())
        let hiddenLayers = 6
        func floats(_ shape: [Int]) -> MLXArray { MLXArray.zeros(shape, dtype: .bfloat16) }

        var weights: [String: MLXArray] = [
            "model.language_model.embed_tokens.weight": floats([64, 64]),
            "model.language_model.norm.weight": floats([64]),
            "lm_head.weight": floats([64, 64]),
            "model.visual.merger.proj.weight": floats([8, 8]),
            "model.language_model.layers.0.input_layernorm.weight": floats([64]),
            "model.language_model.layers.0.hc_attn_fn": floats([24, 64]),
            "model.language_model.layers.0.hc_ffn_base": floats([24]),
            "model.language_model.layers.0.self_attn.A_log": floats([2]),
            "model.language_model.layers.0.self_attn.dt_bias": floats([64]),
            "model.language_model.layers.0.self_attn.f_a_proj.weight": floats([8, 64]),
            "model.language_model.layers.0.self_attn.q_conv1d.weight": floats([4, 4, 1]),
            "model.language_model.layers.0.self_attn.k_conv1d.weight": floats([4, 4, 1]),
            "model.language_model.layers.0.self_attn.v_conv1d.weight": floats([4, 4, 1]),
            // An incomplete conv triple stays as written.
            "model.language_model.layers.1.self_attn.q_conv1d.weight": floats([4, 4, 1]),
            // [heads * (qk_nope + v), kv_lora_rank]
            "model.language_model.layers.3.self_attn.kv_b_proj.weight": floats([128, 32]),
            // A quantized router gate: [experts, hidden_size * 4 / 32].
            "model.language_model.layers.4.mlp.gate.weight": MLXArray.zeros([4, 8], dtype: .uint32),
            "model.language_model.layers.4.mlp.gate.scales": floats([4, 1]),
            "model.language_model.layers.4.mlp.gate.biases": floats([4, 1]),
            // Experts not numbered from 0 stay unstacked.
            "model.language_model.layers.5.mlp.experts.1.up_proj.weight": floats([8, 8]),
            // The next-N layer (index num_hidden_layers) and a second one.
            "model.language_model.layers.6.eh_proj.weight": floats([64, 128]),
            "model.language_model.layers.6.enorm.weight": floats([64]),
            "model.language_model.layers.6.hnorm.weight": floats([64]),
            "model.language_model.layers.6.shared_head.norm.weight": floats([64]),
            "model.language_model.layers.6.shared_head.head.weight": floats([64, 64]),
            "model.language_model.layers.6.embed_tokens.weight": floats([64, 64]),
            "model.language_model.layers.6.input_layernorm.weight": floats([64]),
            "model.language_model.layers.7.input_layernorm.weight": floats([64]),
        ]
        for expert in 0..<4 {
            weights["model.language_model.layers.4.mlp.experts.\(expert).gate_proj.weight"] = floats([8, 8])
        }
        for expert in 0..<2 {
            weights["model.language_model.layers.6.mlp.experts.\(expert).down_proj.weight"] = floats([8, 8])
        }

        let sanitized = Set(model.sanitize(weights: weights).keys)
        let textKeys = Set(weights.keys.compactMap {
            NativeMTPArtifactObserver.glm5NextTextKey($0, hiddenLayers: hiddenLayers)
        })
        let observed = Set(NativeMTPArtifactObserver.glm5NextLoaderNames(textKeys: textKeys).values.joined())
        XCTAssertEqual(observed, sanitized)

        let quantizationKeys = [
            "lm_head",
            "model.language_model.embed_tokens",
            "model.language_model.layers.0.self_attn.f_a_proj",
            "model.language_model.layers.3.self_attn.kv_b_proj",
            "model.language_model.layers.4.mlp.experts.2.gate_proj",
            "model.language_model.layers.6.eh_proj",
            "model.language_model.layers.6.shared_head.norm",
            "model.language_model.layers.6.shared_head.head",
            "model.language_model.layers.6.self_attn.o_proj",
            "language_model.model.layers.0.self_attn.o_proj",
            "model.visual.merger.proj",
        ]
        let perLayer = BaseConfiguration.PerLayerQuantization(
            quantization: BaseConfiguration.Quantization(groupSize: 64, bits: 4),
            perLayerQuantization: Dictionary(
                uniqueKeysWithValues: quantizationKeys.map { ($0, BaseConfiguration.QuantizationOption.skip) }
            )
        )
        let sanitizedPaths = Set(model.sanitize(perLayerQuantization: perLayer).perLayerQuantization.keys)
        var observedPaths = Set(quantizationKeys)
        for key in quantizationKeys {
            for path in NativeMTPArtifactObserver.glm5NextQuantizationModulePaths(key, hiddenLayers: hiddenLayers) {
                observedPaths.insert("language_model." + path)
            }
        }
        XCTAssertEqual(observedPaths, sanitizedPaths)
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
    /// are loaded). Set MACPROVIDER_GLM53_ARTIFACT_DIR to the snapshot. The
    /// override count is per artifact: base GLM-5.3-Flash records 554, the
    /// uncensored Solstice build 543. Set MACPROVIDER_GLM53_EXPECTED_OVERRIDES
    /// for an artifact other than the base build. The name stays as recorded
    /// in the v1.8.256 admission evidence.
    func testRealGLM53ArtifactObservesWith554Overrides() throws {
        guard let path = ProcessInfo.processInfo.environment["MACPROVIDER_GLM53_ARTIFACT_DIR"], !path.isEmpty else {
            throw XCTSkip("MACPROVIDER_GLM53_ARTIFACT_DIR not set")
        }
        let pair = try NativeMTPArtifactObserver.observeEmbedded(targetDirectory: URL(fileURLWithPath: path, isDirectory: true))
        let representation = try NativeMTPArtifactObserver.affineRepresentation(for: pair)
        let expected = ProcessInfo.processInfo.environment["MACPROVIDER_GLM53_EXPECTED_OVERRIDES"]
            .flatMap(Int.init) ?? 554
        XCTAssertEqual(representation.perLayerExceptions.count, expected)
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
