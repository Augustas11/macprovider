import Foundation
@testable import macprovider_cli
import XCTest

final class NativeMTPArtifactObservationTests: XCTestCase {
    func testUnquantizedObservationRejectsMissingFloat32AndGarbageDType() throws {
        try withFixture(dtype: nil) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedDType("missing")
                )
            }
        }

        try withFixture(dtype: "float32") { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedDType("float32")
                )
            }
        }

        try withFixture(dtype: "banana") { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedDType("banana")
                )
            }
        }
    }

    func testUnquantizedObservationAcceptsExplicitBF16AndFP16Only() throws {
        try withFixture(dtype: "bfloat16", tensors: [
            tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16"),
        ]) { directory in
            let observation = try NativeMTPArtifactObserver.observe(directory: directory)
            XCTAssertEqual(observation.format, .unquantized(dtype: "bf16"))
            XCTAssertEqual(observation.mtpPredictionLayerCount, 2)
        }

        try withFixture(dtype: "float16", tensors: [
            tensor("model.layers.0.mlp.down_proj.weight", dtype: "F16"),
        ]) { directory in
            let observation = try NativeMTPArtifactObserver.observe(directory: directory)
            XCTAssertEqual(observation.format, .unquantized(dtype: "fp16"))
            XCTAssertEqual(observation.mtpPredictionLayerCount, 2)
        }
    }

    func testQuantizedBitsEightWithoutModeRejects() throws {
        try withFixture(
            quantization: [
                "bits": 8,
                "group_size": 32,
            ],
            tensors: mxfp8Tensors()
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .missingQuantizationMetadata("mode")
                )
            }
        }
    }

    func testGenericFP8ClaimRejectsEvenWithFP8Headers() throws {
        try withFixture(
            quantization: [
                "mode": "fp8",
                "bits": 8,
                "group_size": 32,
            ],
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "F8_E4M3", shape: [2, 64]),
                tensor("model.layers.0.mlp.down_proj.scales", dtype: "F16", shape: [2, 2]),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedQuantization("fp8")
                )
            }
        }
    }

    func testMXFP8FailsClosedUntilScaleEncodingIsVerified() throws {
        try withFixture(
            quantization: [
                "mode": "mxfp8",
                "bits": 8,
                "group_size": 32,
            ],
            tensors: mxfp8Tensors()
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedQuantization("mlx_mxfp8 scale dtype unverified")
                )
            }
        }
    }

    func testFractionalJSONIntegersRejectInsteadOfTruncating() throws {
        let fractionalBitsConfig = #"{"quantization":{"mode":"mxfp8","bits":8.5,"group_size":32},"text_config":{"mtp_num_hidden_layers":2}}"#
        try withRawFixture(
            configData: Data(fractionalBitsConfig.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(tensors: mxfp8Tensors()))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .missingQuantizationMetadata("bits")
                )
            }
        }

        let fractionalLayerConfig = #"{"torch_dtype":"bfloat16","text_config":{"mtp_num_hidden_layers":2.5}}"#
        try withRawFixture(
            configData: Data(fractionalLayerConfig.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16"),
            ]))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .missingMTPPredictionLayerCount
                )
            }
        }

        let config = #"{"torch_dtype":"bfloat16","text_config":{"mtp_num_hidden_layers":2}}"#
        let fractionalShape = #"{"model.layers.0.mlp.down_proj.weight":{"dtype":"BF16","shape":[1,1.5],"data_offsets":[0,2]}}"#
        try withRawFixture(
            configData: Data(config.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(headerJSON: fractionalShape, payloadBytes: 2))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                guard case .malformedSafetensors(let reason) = error as? NativeMTPArtifactObservationError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("dimension"))
            }
        }

        let fractionalOffset = #"{"model.layers.0.mlp.down_proj.weight":{"dtype":"BF16","shape":[1,1],"data_offsets":[0,2.5]}}"#
        try withRawFixture(
            configData: Data(config.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(headerJSON: fractionalOffset, payloadBytes: 3))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                guard case .malformedSafetensors(let reason) = error as? NativeMTPArtifactObservationError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("offsets"))
            }
        }
    }

    func testQuantizedPackedDTypeMustMatchExactFormatDensity() throws {
        try withFixture(
            quantization: [
                "mode": "mxfp8",
                "bits": 8,
                "group_size": 32,
            ],
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "U16", shape: [2, 64]),
                tensor("model.layers.0.mlp.down_proj.scales", dtype: "F16", shape: [2, 2]),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedQuantization("mlx_mxfp8 scale dtype unverified")
                )
            }
        }

        try withFixture(
            quantization: [
                "mode": "mlx_affine_4bit",
                "bits": 4,
                "group_size": 64,
            ],
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "U8", shape: [2, 8]),
                tensor("model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
                tensor("model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("packed tensor model.layers.0.mlp.down_proj.weight dtype U8")
                )
            }
        }
    }

    func testAffineFourRejectsUnpairedMismatchedAndPaddedHeaders() throws {
        let quantization: [String: Any] = [
            "mode": "mlx_affine_4bit",
            "bits": 4,
            "group_size": 64,
        ]
        try withFixture(
            quantization: quantization,
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
                tensor("model.layers.0.mlp.other.scales", dtype: "F16", shape: [2, 1]),
                tensor("model.layers.0.mlp.down_proj.biases", dtype: "F16", shape: [2, 1]),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("missing scale pair for model.layers.0.mlp.down_proj.weight")
                )
            }
        }

        try withFixture(
            quantization: quantization,
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
                tensor("model.layers.0.mlp.down_proj.scales", dtype: "F16", shape: [2, 2]),
                tensor("model.layers.0.mlp.down_proj.biases", dtype: "F16", shape: [2, 2]),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("scale block count for model.layers.0.mlp.down_proj.weight")
                )
            }
        }

        try withFixture(
            quantization: quantization,
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 9]),
                tensor("model.layers.0.mlp.down_proj.scales", dtype: "F16", shape: [2, 2]),
                tensor("model.layers.0.mlp.down_proj.biases", dtype: "F16", shape: [2, 2]),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("undeclared padding for model.layers.0.mlp.down_proj.weight")
                )
            }
        }
    }

    func testAffineFourRequiresExactMetadataAndPackedHeaders() throws {
        try withFixture(
            quantization: [
                "mode": "mlx_affine_4bit",
                "bits": 4,
                "group_size": 64,
            ],
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
                tensor("model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
                tensor("model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
            ]
        ) { directory in
            let observation = try NativeMTPArtifactObserver.observe(directory: directory)
            XCTAssertEqual(observation.format, .mlxAffine4(bits: 4, groupSize: 64))
        }

        try withFixture(
            quantization: [
                "mode": "mlx_affine_4bit",
                "bits": 4,
                "group_size": 64,
            ],
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
                tensor("model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("missing bias pair for model.layers.0.mlp.down_proj.weight")
                )
            }
        }

        try withFixture(
            quantization: [
                "mode": "mlx_affine_4bit",
                "bits": 8,
                "group_size": 64,
            ],
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
                tensor("model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
                tensor("model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedQuantization("mlx affine requires bits=4")
                )
            }
        }
    }

    func testQuantizationFalseEntriesAllowOnlyDeclaredUnquantizedLayers() throws {
        try withFixture(
            quantization: [
                "mode": "mlx_affine_4bit",
                "bits": 4,
                "group_size": 64,
                "model.layers.0.mlp.down_proj": false,
            ],
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16", shape: [2, 64]),
            ]
        ) { directory in
            let observation = try NativeMTPArtifactObserver.observe(directory: directory)
            XCTAssertEqual(observation.format, .mlxAffine4(bits: 4, groupSize: 64))
            XCTAssertTrue(observation.tensorPairs.isEmpty)
        }

        try withFixture(
            quantization: [
                "mode": "mlx_affine_4bit",
                "bits": 4,
                "group_size": 64,
            ],
            tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16", shape: [2, 64]),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("packed tensor model.layers.0.mlp.down_proj.weight dtype BF16")
                )
            }
        }
    }

    func testTargetAndDrafterLayerDriftFailsClosed() throws {
        let target = try makeFixtureDirectory(
            name: "target",
            dtype: "bfloat16",
            mtpLayerCount: 2,
            tensors: [tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16")]
        )
        let drafter = try makeFixtureDirectory(
            name: "drafter",
            dtype: "bfloat16",
            modelType: "qwen3_5_mtp",
            mtpLayerCount: 3,
            tensors: [tensor("norm.weight", dtype: "BF16")]
        )
        defer {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: drafter.deletingLastPathComponent())
        }

        XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(
            targetDirectory: target,
            mtpDirectory: drafter,
            familyAdapter: "qwen3_5_mtp_v1",
            sourceLayout: "separate_artifact"
        )) { error in
            XCTAssertEqual(
                error as? NativeMTPArtifactObservationError,
                .observationDrift("mtp_num_hidden_layers")
            )
        }
    }

    func testSeparateArtifactTensorNamespacesRejectEmbeddedOrExtraWeights() throws {
        let cleanTarget = try makeFixtureDirectory(
            name: "target",
            dtype: "bfloat16",
            mtpLayerCount: 2,
            tensors: [tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16")]
        )
        let embeddedMTPInTarget = try makeFixtureDirectory(
            name: "target-with-mtp",
            dtype: "bfloat16",
            mtpLayerCount: 2,
            tensors: [tensor("model.mtp.moment.down_proj.weight", dtype: "BF16")]
        )
        let cleanDrafter = try makeFixtureDirectory(
            name: "drafter",
            dtype: "bfloat16",
            modelType: "qwen3_5_mtp",
            mtpLayerCount: 2,
            tensors: [tensor("norm.weight", dtype: "BF16")]
        )
        let extraDrafter = try makeFixtureDirectory(
            name: "drafter-extra",
            dtype: "bfloat16",
            modelType: "qwen3_5_mtp",
            mtpLayerCount: 2,
            tensors: [tensor("extra.layers.0.mlp.down_proj.weight", dtype: "BF16")]
        )
        defer {
            try? FileManager.default.removeItem(at: cleanTarget.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: embeddedMTPInTarget.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: cleanDrafter.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: extraDrafter.deletingLastPathComponent())
        }

        XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(
            targetDirectory: embeddedMTPInTarget,
            mtpDirectory: cleanDrafter,
            familyAdapter: "qwen3_5_mtp_v1",
            sourceLayout: "separate_artifact"
        )) { error in
            XCTAssertEqual(
                error as? NativeMTPArtifactObservationError,
                .incompatibleSafetensorsHeaders("target tensor namespace model.mtp.moment.down_proj.weight")
            )
        }
        XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(
            targetDirectory: cleanTarget,
            mtpDirectory: extraDrafter,
            familyAdapter: "qwen3_5_mtp_v1",
            sourceLayout: "separate_artifact"
        )) { error in
            XCTAssertEqual(
                error as? NativeMTPArtifactObservationError,
                .incompatibleSafetensorsHeaders("mtp tensor namespace extra.layers.0.mlp.down_proj.weight")
            )
        }
    }

    func testQwen35StandaloneDrafterAcceptsExactQuantizedNamespace() throws {
        let quantization: [String: Any] = [
            "mode": "mlx_affine_4bit",
            "bits": 4,
            "group_size": 64,
            "layers.0.input_layernorm.weight": false,
            "layers.0.post_attention_layernorm.weight": false,
            "layers.0.self_attn.k_norm.weight": false,
            "layers.0.self_attn.q_norm.weight": false,
            "norm.weight": false,
            "pre_fc_norm_embedding.weight": false,
            "pre_fc_norm_hidden.weight": false,
        ]
        let target = try makeFixtureDirectory(
            name: "target",
            quantization: [
                "mode": "mlx_affine_4bit",
                "bits": 4,
                "group_size": 64,
            ],
            mtpLayerCount: 1,
            tensors: quantizedTriplet("model.layers.0.mlp.down_proj")
        )
        let drafter = try makeFixtureDirectory(
            name: "drafter",
            quantization: quantization,
            modelType: "qwen3_5_mtp",
            mtpLayerCount: 1,
            tensors: qwen35StandaloneDrafterTensors()
        )
        defer {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: drafter.deletingLastPathComponent())
        }

        let observation = try NativeMTPArtifactObserver.observePair(
            targetDirectory: target,
            mtpDirectory: drafter,
            familyAdapter: "qwen3_5_mtp_v1",
            sourceLayout: "separate_artifact"
        )

        XCTAssertEqual(qwen35StandaloneDrafterTensors().count, 31)
        XCTAssertEqual(observation.mtp.tensorPairs.count, 8)
        XCTAssertEqual(observation.mtp.format, .mlxAffine4(bits: 4, groupSize: 64))
    }

    func testQwen35StandaloneDrafterRejectsTargetOwnedEmbeddingAndLMHead() throws {
        let target = try makeFixtureDirectory(
            name: "target",
            dtype: "bfloat16",
            mtpLayerCount: 1,
            tensors: [tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16")]
        )
        defer {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
        }

        for name in ["embed_tokens.weight", "lm_head.weight"] {
            let drafter = try makeFixtureDirectory(
                name: "drafter-\(name.replacingOccurrences(of: ".", with: "-"))",
                dtype: "bfloat16",
                modelType: "qwen3_5_mtp",
                mtpLayerCount: 1,
                tensors: [tensor(name, dtype: "BF16")]
            )
            defer { try? FileManager.default.removeItem(at: drafter.deletingLastPathComponent()) }

            XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(
                targetDirectory: target,
                mtpDirectory: drafter,
                familyAdapter: "qwen3_5_mtp_v1",
                sourceLayout: "separate_artifact"
            )) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("mtp tensor namespace \(name)")
                )
            }
        }
    }

    func testQwen35StandaloneDrafterFailsClosedForUnadmittedConfigOrSourceLayout() throws {
        let target = try makeFixtureDirectory(
            name: "target",
            dtype: "bfloat16",
            mtpLayerCount: 1,
            tensors: [tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16")]
        )
        let wrongModelType = try makeFixtureDirectory(
            name: "wrong-model-type",
            dtype: "bfloat16",
            modelType: "qwen3_5",
            mtpLayerCount: 1,
            tensors: [tensor("norm.weight", dtype: "BF16")]
        )
        let correctDrafter = try makeFixtureDirectory(
            name: "correct-drafter",
            dtype: "bfloat16",
            modelType: "qwen3_5_mtp",
            mtpLayerCount: 1,
            tensors: [tensor("norm.weight", dtype: "BF16")]
        )
        defer {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: wrongModelType.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: correctDrafter.deletingLastPathComponent())
        }

        XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(
            targetDirectory: target,
            mtpDirectory: wrongModelType,
            familyAdapter: "qwen3_5_mtp_v1",
            sourceLayout: "separate_artifact"
        ))
        XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(
            targetDirectory: target,
            mtpDirectory: correctDrafter,
            familyAdapter: "qwen3_5_mtp_v1",
            sourceLayout: "embedded"
        ))
        XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(
            targetDirectory: target,
            mtpDirectory: correctDrafter,
            familyAdapter: "unknown",
            sourceLayout: "separate_artifact"
        ))
    }

    func testQwen35StandaloneDrafterRejectsNoncanonicalLayerIndices() throws {
        let target = try makeFixtureDirectory(
            name: "target",
            dtype: "bfloat16",
            mtpLayerCount: 1,
            tensors: [tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16")]
        )
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }

        for layer in ["00", "+0", "-0"] {
            let tensorName = "layers.\(layer).input_layernorm.weight"
            let drafter = try makeFixtureDirectory(
                name: "drafter-\(layer.replacingOccurrences(of: "+", with: "plus").replacingOccurrences(of: "-", with: "minus"))",
                dtype: "bfloat16",
                modelType: "qwen3_5_mtp",
                mtpLayerCount: 1,
                tensors: [tensor(tensorName, dtype: "BF16")]
            )
            defer { try? FileManager.default.removeItem(at: drafter.deletingLastPathComponent()) }

            XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(
                targetDirectory: target,
                mtpDirectory: drafter,
                familyAdapter: "qwen3_5_mtp_v1",
                sourceLayout: "separate_artifact"
            )) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("mtp tensor namespace \(tensorName)")
                )
            }
        }
    }

    func testLayerCountMayComeFromRootOrTextConfigAndMustBeBounded() throws {
        try withFixture(dtype: "bfloat16", mtpLayerCount: 64, layerCountPlacement: .root) { directory in
            let observation = try NativeMTPArtifactObserver.observe(directory: directory)
            XCTAssertEqual(observation.mtpPredictionLayerCount, 64)
        }

        try withFixture(dtype: "bfloat16", mtpLayerCount: 65, layerCountPlacement: .textConfig) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .invalidMTPPredictionLayerCount
                )
            }
        }
    }

    func testConfigReadIsBoundedNoFollowAndRejectsDuplicateKeys() throws {
        try withRawFixture(
            configData: Data(repeating: UInt8(ascii: " "), count: NativeMTPArtifactObserver.maxConfigBytes + 1),
            safetensors: [("model.safetensors", try safetensorsBytes(tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16"),
            ]))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                guard case .malformedConfig(let reason) = error as? NativeMTPArtifactObservationError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("file too large"))
            }
        }

        let duplicateKeyConfig = #"{"torch_dtype":"bfloat16","torch_dtype":"float16","text_config":{"mtp_num_hidden_layers":2}}"#
        try withRawFixture(
            configData: Data(duplicateKeyConfig.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16"),
            ]))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                guard case .malformedConfig(let reason) = error as? NativeMTPArtifactObservationError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("duplicateKey"))
            }
        }
    }

    func testSafetensorsHeadersRejectDuplicatesAndBoundCumulativeBytes() throws {
        let config = #"{"torch_dtype":"bfloat16","text_config":{"mtp_num_hidden_layers":2}}"#
        let duplicateTensorHeader = #"{"model.layers.0.mlp.down_proj.weight":{"dtype":"BF16","shape":[1,1],"data_offsets":[0,2]},"model.layers.0.mlp.down_proj.weight":{"dtype":"BF16","shape":[1,1],"data_offsets":[0,2]}}"#
        try withRawFixture(
            configData: Data(config.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(headerJSON: duplicateTensorHeader, payloadBytes: 2))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                guard case .malformedSafetensors(let reason) = error as? NativeMTPArtifactObservationError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("duplicateKey"))
            }
        }

        let singleTensorShard = #"{"model.layers.0.mlp.down_proj.weight":{"dtype":"BF16","shape":[1,1],"data_offsets":[0,2]}}"#
        try withRawFixture(
            configData: Data(config.utf8),
            safetensors: [
                ("model-00001.safetensors", try safetensorsBytes(headerJSON: singleTensorShard, payloadBytes: 2)),
                ("model-00002.safetensors", try safetensorsBytes(headerJSON: singleTensorShard, payloadBytes: 2)),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                guard case .malformedSafetensors(let reason) = error as? NativeMTPArtifactObservationError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("duplicate tensor"))
            }
        }

        let paddedHeader = #"{}"# + String(
            repeating: " ",
            count: NativeMTPArtifactObserver.maxSafetensorsHeaderBytes - 2
        )
        let largeShards = try (0..<5).map { index in
            ("model-\(index).safetensors", try safetensorsBytes(headerJSON: paddedHeader, payloadBytes: 0))
        }
        try withRawFixture(
            configData: Data(config.utf8),
            safetensors: largeShards
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .malformedSafetensors("cumulative header bytes")
                )
            }
        }
    }

    func testSafetensorsOffsetsAndFileSizeMustBeConsistent() throws {
        let config = #"{"torch_dtype":"bfloat16","text_config":{"mtp_num_hidden_layers":2}}"#
        let validHeader = #"{"model.layers.0.mlp.down_proj.weight":{"dtype":"BF16","shape":[1,1],"data_offsets":[0,2]}}"#
        var truncated = Data()
        var declaredLength = UInt64(validHeader.utf8.count + 4).littleEndian
        truncated.append(withUnsafeBytes(of: &declaredLength) { Data($0) })
        truncated.append(Data(validHeader.utf8))
        try withRawFixture(
            configData: Data(config.utf8),
            safetensors: [("model.safetensors", truncated)]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                guard case .malformedSafetensors(let reason) = error as? NativeMTPArtifactObservationError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("truncated header"))
            }
        }

        let outOfRangeHeader = #"{"model.layers.0.mlp.down_proj.weight":{"dtype":"BF16","shape":[1,1],"data_offsets":[0,4]}}"#
        try withRawFixture(
            configData: Data(config.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(headerJSON: outOfRangeHeader, payloadBytes: 2))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                guard case .malformedSafetensors(let reason) = error as? NativeMTPArtifactObservationError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("offsets out of range"))
            }
        }

        let overlapHeader = #"{"a.weight":{"dtype":"BF16","shape":[1,1],"data_offsets":[0,2]},"b.weight":{"dtype":"BF16","shape":[1,1],"data_offsets":[1,3]}}"#
        try withRawFixture(
            configData: Data(config.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(headerJSON: overlapHeader, payloadBytes: 3))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                guard case .malformedSafetensors(let reason) = error as? NativeMTPArtifactObservationError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("overlapping tensor offsets"))
            }
        }
    }

    func testSafetensorsShapeAndArithmeticBoundsFailClosed() throws {
        let config = #"{"quantization":{"mode":"mlx_affine_4bit","bits":4,"group_size":64},"text_config":{"mtp_num_hidden_layers":2}}"#
        let hugeDimensionHeader = #"{"model.layers.0.mlp.down_proj.weight":{"dtype":"U32","shape":[2,1073741825],"data_offsets":[0,8]},"model.layers.0.mlp.down_proj.scales":{"dtype":"F16","shape":[2,1],"data_offsets":[8,12]},"model.layers.0.mlp.down_proj.biases":{"dtype":"F16","shape":[2,1],"data_offsets":[12,16]}}"#
        try withRawFixture(
            configData: Data(config.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(headerJSON: hugeDimensionHeader, payloadBytes: 16))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                guard case .malformedSafetensors(let reason) = error as? NativeMTPArtifactObservationError else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertTrue(reason.contains("dimension"))
            }
        }

        let byteSpanMismatchHeader = #"{"model.layers.0.mlp.down_proj.weight":{"dtype":"U32","shape":[2,8],"data_offsets":[0,1]},"model.layers.0.mlp.down_proj.scales":{"dtype":"F16","shape":[2,1],"data_offsets":[1,5]},"model.layers.0.mlp.down_proj.biases":{"dtype":"F16","shape":[2,1],"data_offsets":[5,9]}}"#
        try withRawFixture(
            configData: Data(config.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(headerJSON: byteSpanMismatchHeader, payloadBytes: 9))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("packed tensor model.layers.0.mlp.down_proj.weight byte span")
                )
            }
        }
    }

    func testRecursiveSafetensorsTraversalMirrorsMLXAndRejectsHiddenWeightsOrSymlinkPaths() throws {
        let config = #"{"torch_dtype":"bfloat16","text_config":{"mtp_num_hidden_layers":2}}"#
        try withRawFixture(configData: Data(config.utf8), safetensors: []) { directory in
            try Data().write(to: directory.appendingPathComponent(".gitattributes"))
            let nested = directory.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try safetensorsBytes(tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16"),
            ]).write(to: nested.appendingPathComponent("part.safetensors"))

            let observation = try NativeMTPArtifactObserver.observe(directory: directory)
            XCTAssertEqual(observation.format, .unquantized(dtype: "bf16"))
        }

        try withRawFixture(configData: Data(config.utf8), safetensors: []) { directory in
            let hidden = directory.appendingPathComponent(".cache", isDirectory: true)
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            try safetensorsBytes(tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16"),
            ]).write(to: hidden.appendingPathComponent(".model.safetensors"))

            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .malformedSafetensors("hidden safetensors")
                )
            }
        }

        try withRawFixture(configData: Data(config.utf8), safetensors: []) { directory in
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("NativeMTPArtifactObservationTests-outside-\(UUID().uuidString)")
            try safetensorsBytes(tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16"),
            ]).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            XCTAssertEqual(symlink(outside.path, directory.appendingPathComponent("model.safetensors").path), 0)

            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .malformedSafetensors("symlink path")
                )
            }
        }
    }

    private enum LayerCountPlacement {
        case root
        case textConfig
    }

    private struct TensorFixture {
        let name: String
        let dtype: String
        let shape: [Int]
    }

    private func tensor(_ name: String, dtype: String, shape: [Int] = [1, 1]) -> TensorFixture {
        TensorFixture(name: name, dtype: dtype, shape: shape)
    }

    private func mxfp8Tensors() -> [TensorFixture] {
        [
            tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 16]),
            tensor("model.layers.0.mlp.down_proj.scales", dtype: "U8", shape: [2, 2]),
        ]
    }

    private func quantizedTriplet(_ base: String) -> [TensorFixture] {
        [
            tensor("\(base).weight", dtype: "U32", shape: [2, 8]),
            tensor("\(base).scales", dtype: "BF16", shape: [2, 1]),
            tensor("\(base).biases", dtype: "BF16", shape: [2, 1]),
        ]
    }

    private func qwen35StandaloneDrafterTensors() -> [TensorFixture] {
        var tensors = quantizedTriplet("fc")
        for projection in ["down_proj", "gate_proj", "up_proj"] {
            tensors.append(contentsOf: quantizedTriplet("layers.0.mlp.\(projection)"))
        }
        for projection in ["k_proj", "o_proj", "q_proj", "v_proj"] {
            tensors.append(contentsOf: quantizedTriplet("layers.0.self_attn.\(projection)"))
        }
        tensors.append(contentsOf: [
            tensor("layers.0.input_layernorm.weight", dtype: "BF16"),
            tensor("layers.0.post_attention_layernorm.weight", dtype: "BF16"),
            tensor("layers.0.self_attn.k_norm.weight", dtype: "BF16"),
            tensor("layers.0.self_attn.q_norm.weight", dtype: "BF16"),
            tensor("norm.weight", dtype: "BF16"),
            tensor("pre_fc_norm_embedding.weight", dtype: "BF16"),
            tensor("pre_fc_norm_hidden.weight", dtype: "BF16"),
        ])
        return tensors
    }

    private func withFixture(
        dtype: String? = "bfloat16",
        quantization: [String: Any]? = nil,
        mtpLayerCount: Int = 2,
        layerCountPlacement: LayerCountPlacement = .textConfig,
        tensors: [TensorFixture]? = nil,
        _ body: (URL) throws -> Void
    ) throws {
        let fixtureTensors = tensors ?? [
            TensorFixture(name: "model.layers.0.mlp.down_proj.weight", dtype: "BF16", shape: [1, 1]),
        ]
        let directory = try makeFixtureDirectory(
            name: UUID().uuidString,
            dtype: dtype,
            quantization: quantization,
            mtpLayerCount: mtpLayerCount,
            layerCountPlacement: layerCountPlacement,
            tensors: fixtureTensors
        )
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try body(directory)
    }

    private func withRawFixture(
        configData: Data,
        safetensors: [(String, Data)],
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMTPArtifactObservationTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try configData.write(to: directory.appendingPathComponent("config.json"))
        for (name, data) in safetensors {
            try data.write(to: directory.appendingPathComponent(name))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try body(directory)
    }

    private func makeFixtureDirectory(
        name: String,
        dtype: String? = "bfloat16",
        quantization: [String: Any]? = nil,
        modelType: String? = nil,
        mtpLayerCount: Int,
        layerCountPlacement: LayerCountPlacement = .textConfig,
        tensors: [TensorFixture]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeMTPArtifactObservationTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var config: [String: Any] = [:]
        if let dtype {
            config["torch_dtype"] = dtype
        }
        if let quantization {
            config["quantization"] = quantization
        }
        if let modelType {
            config["model_type"] = modelType
        }
        switch layerCountPlacement {
        case .root:
            config["mtp_num_hidden_layers"] = mtpLayerCount
        case .textConfig:
            config["text_config"] = ["mtp_num_hidden_layers": mtpLayerCount]
        }
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("config.json"))
        try safetensorsBytes(tensors: tensors)
            .write(to: directory.appendingPathComponent("model.safetensors"))
        return directory
    }

    private func safetensorsBytes(tensors: [TensorFixture]) throws -> Data {
        var header: [String: Any] = [:]
        var offset = 0
        for tensor in tensors {
            let bytes = tensor.shape.reduce(1, *) * bytesPerElement(dtype: tensor.dtype)
            header[tensor.name] = [
                "dtype": tensor.dtype,
                "shape": tensor.shape,
                "data_offsets": [offset, offset + bytes],
            ]
            offset += bytes
        }
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var length = UInt64(headerData.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(headerData)
        data.append(Data(repeating: 0, count: offset))
        return data
    }

    private func safetensorsBytes(headerJSON: String, payloadBytes: Int) throws -> Data {
        var length = UInt64(headerJSON.utf8.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(Data(headerJSON.utf8))
        data.append(Data(repeating: 0, count: payloadBytes))
        return data
    }

    private func bytesPerElement(dtype: String) -> Int {
        switch dtype.uppercased() {
        case "U8", "I8", "F8_E4M3", "F8_E5M2":
            return 1
        case "F16", "BF16", "U16", "I16":
            return 2
        case "F32", "U32", "I32":
            return 4
        default:
            return 1
        }
    }
}
