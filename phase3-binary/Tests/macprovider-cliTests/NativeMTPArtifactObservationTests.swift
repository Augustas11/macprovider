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

    /// The pinned loader reads an absent `mode` as affine, so bits=8 without
    /// a mode is an 8-bit affine claim and fails the global 4-bit gate.
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
                    .unsupportedQuantization("mlx affine requires bits=4")
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
                "mode": "affine",
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
            "mode": "affine",
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
                "mode": "affine",
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
                "mode": "affine",
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
                "mode": "affine",
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
                "mode": "affine",
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
                "mode": "affine",
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

        let unsignedExceptionConfig = #"{"quantization":{"mode":"affine","bits":4,"group_size":64},"native_mtp_representation":{"unquantized_layer_exceptions":["model.layers.0.mlp.down_proj"]},"text_config":{"mtp_num_hidden_layers":2}}"#
        try withRawFixture(
            configData: Data(unsignedExceptionConfig.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "BF16", shape: [2, 64]),
            ]))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("packed tensor model.layers.0.mlp.down_proj.weight dtype BF16")
                )
            }
        }

        let unpairedScaleConfig = #"{"quantization":{"mode":"affine","bits":4,"group_size":64},"native_mtp_representation":{"unpaired_scale_exceptions":["model.layers.1.mlp.down_proj.scales"]},"text_config":{"mtp_num_hidden_layers":2}}"#
        try withRawFixture(
            configData: Data(unpairedScaleConfig.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
                tensor("model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
                tensor("model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
                tensor("model.layers.1.mlp.down_proj.scales", dtype: "F16", shape: [2, 1]),
            ]))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedQuantization("mlx affine unpaired scale exceptions are not admissible")
                )
            }
        }

        let paddingExceptionConfig = #"{"quantization":{"mode":"affine","bits":4,"group_size":64},"native_mtp_representation":{"padding_exceptions":["model.layers.0.mlp.down_proj.weight"]},"text_config":{"mtp_num_hidden_layers":2}}"#
        try withRawFixture(
            configData: Data(paddingExceptionConfig.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(tensors: [
                tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
                tensor("model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
                tensor("model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
            ]))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedQuantization("mlx affine padding exceptions are not admissible")
                )
            }
        }
    }

    /// Real mlx-community Qwen3.6-35B-A3B-4bit shape: `"mode": "affine"`
    /// globally plus 8-bit router gates declared as per-module overrides.
    func testAffineModeSpellingAndPerModuleEightBitOverrides() throws {
        let gate = "language_model.model.layers.0.mlp.gate"
        let baseTensors = [
            tensor("language_model.model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
            tensor("language_model.model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
            tensor("language_model.model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
            // 8-bit: 16 U32 columns * 4 values = 64 inputs -> one group of 64.
            tensor("\(gate).weight", dtype: "U32", shape: [4, 16]),
            tensor("\(gate).scales", dtype: "BF16", shape: [4, 1]),
            tensor("\(gate).biases", dtype: "BF16", shape: [4, 1]),
        ]
        try withFixture(
            quantization: ["mode": "affine", "bits": 4, "group_size": 64, gate: ["bits": 8, "group_size": 64]],
            tensors: baseTensors
        ) { directory in
            let observation = try NativeMTPArtifactObserver.observe(directory: directory)
            XCTAssertEqual(observation.format, .mlxAffine4(bits: 4, groupSize: 64))
            let gatePair = try XCTUnwrap(observation.tensorPairs.first { $0.weightName == "\(gate).weight" })
            XCTAssertEqual(gatePair.bitsPerValue, 8)
            XCTAssertEqual(gatePair.logicalInputColumns, 64)
        }

        // Without the override the 8-bit tensor is read as 4-bit and fails closed.
        try withFixture(
            quantization: ["mode": "affine", "bits": 4, "group_size": 64],
            tensors: baseTensors
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .incompatibleSafetensorsHeaders("scale block count for \(gate).weight")
                )
            }
        }

        let rejected: [([String: Any], String)] = [
            (["model.layers.9.mlp.gate": ["bits": 8, "group_size": 64]], "mlx_affine_4bit unmatched module override"),
            ([gate: ["bits": 3, "group_size": 64]], "mlx affine module override bits"),
            ([gate: ["bits": 8, "group_size": 48]], "mlx affine module override group_size"),
            ([gate: ["bits": 8, "group_size": 64, "mode": "mxfp8"]], "mlx affine module override mode"),
            ([gate: ["bits": 8, "group_size": 64, "extra": 1]], "mlx affine module override unknown key"),
            ([gate: "8bit"], "mlx affine malformed module override"),
        ]
        for (override, reason) in rejected {
            var quantization: [String: Any] = ["mode": "affine", "bits": 4, "group_size": 64, gate: ["bits": 8, "group_size": 64]]
            for (key, value) in override { quantization[key] = value }
            try withFixture(quantization: quantization, tensors: baseTensors) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                    XCTAssertEqual(error as? NativeMTPArtifactObservationError, .unsupportedQuantization(reason))
                }
            }
        }

        // `affine` still means 4-bit globally; other global widths stay rejected.
        try withFixture(
            quantization: ["mode": "affine", "bits": 8, "group_size": 64],
            tensors: baseTensors
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedQuantization("mlx affine requires bits=4")
                )
            }
        }
    }

    /// The standalone drafter loader rewrites `fc.weight` to `mtp.fc.weight`
    /// and looks per-layer quantization up by that exact path, so only an
    /// `mtp.`-keyed override or `false` entry is consumed. A bare `fc` key is
    /// ignored by the loader (global 4-bit applies) and must fail closed here.
    func testStandaloneOverrideAndFalseKeysUseExactLoaderPath() throws {
        let target = try makeFixtureDirectory(
            name: "target",
            quantization: ["mode": "affine", "bits": 4, "group_size": 64],
            mtpLayerCount: 2,
            tensors: [
                tensor("language_model.model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
                tensor("language_model.model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
                tensor("language_model.model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
            ]
        )
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        let drafterTensors = [
            // 8-bit, group 32: 8 U32 columns * 4 values = 32 inputs -> one group.
            tensor("fc.weight", dtype: "U32", shape: [2, 8]),
            tensor("fc.scales", dtype: "BF16", shape: [2, 1]),
            tensor("fc.biases", dtype: "BF16", shape: [2, 1]),
            tensor("norm.weight", dtype: "BF16", shape: [2, 32]),
        ]
        func drafter(_ quantization: [String: Any]) throws -> URL {
            try makeFixtureDirectory(
                name: "drafter",
                quantization: ["mode": "affine", "bits": 4, "group_size": 64].merging(quantization) { $1 },
                mtpLayerCount: 2,
                tensors: drafterTensors
            )
        }

        let exact = try drafter(["mtp.fc": ["bits": 8, "group_size": 32], "mtp.norm": false])
        defer { try? FileManager.default.removeItem(at: exact.deletingLastPathComponent()) }
        let observation = try NativeMTPArtifactObserver.observePair(targetDirectory: target, mtpDirectory: exact).mtp
        XCTAssertEqual(observation.affineModuleOverrides["mtp.fc"], .init(bits: 8, groupSize: 32))
        XCTAssertEqual(observation.unquantizedModules, ["mtp.norm"])
        XCTAssertEqual(observation.tensorPairs.first?.bitsPerValue, 8)
        XCTAssertEqual(observation.tensorPairs.first?.groupSize, 32)

        let bareOverride = try drafter(["fc": ["bits": 8, "group_size": 32], "mtp.norm": false])
        defer { try? FileManager.default.removeItem(at: bareOverride.deletingLastPathComponent()) }
        XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(targetDirectory: target, mtpDirectory: bareOverride)) { error in
            XCTAssertEqual(error as? NativeMTPArtifactObservationError, .unsupportedQuantization("mlx_affine_4bit unmatched module override"))
        }

        let bareFalse = try drafter(["mtp.fc": ["bits": 8, "group_size": 32], "norm": false])
        defer { try? FileManager.default.removeItem(at: bareFalse.deletingLastPathComponent()) }
        XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(targetDirectory: target, mtpDirectory: bareFalse)) { error in
            XCTAssertEqual(error as? NativeMTPArtifactObservationError, .incompatibleSafetensorsHeaders("packed tensor norm.weight dtype BF16"))
        }
    }

    /// Spellings the pinned loader never decodes cannot make an artifact look
    /// affine to the observer.
    func testObserverAcceptsOnlyTheLoaderQuantizationGrammar() throws {
        let packed = [
            tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
            tensor("model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
            tensor("model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
        ]
        // Absent mode is the loader's affine default; quant_method is skipped.
        try withFixture(quantization: ["bits": 4, "group_size": 64, "quant_method": "fp8"], tensors: packed) { directory in
            XCTAssertEqual(try NativeMTPArtifactObserver.observe(directory: directory).format, .mlxAffine4(bits: 4, groupSize: 64))
        }
        let rejected: [([String: Any], NativeMTPArtifactObservationError)] = [
            (["mode": "mlx_affine_4bit", "bits": 4, "group_size": 64], .unsupportedQuantization("mlx_affine_4bit")),
            (["mode": "Affine", "bits": 4, "group_size": 64], .unsupportedQuantization("Affine")),
            (["mode": "affine", "bits": 4, "groupSize": 64], .missingQuantizationMetadata("group_size")),
        ]
        for (quantization, expected) in rejected {
            try withFixture(quantization: quantization, tensors: packed) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                    XCTAssertEqual(error as? NativeMTPArtifactObservationError, expected)
                }
            }
        }

        // Only `quantization` is decoded; a lone `quantization_config` is not.
        let configOnly = #"{"quantization_config":{"mode":"affine","bits":4,"group_size":64},"torch_dtype":"bfloat16","text_config":{"mtp_num_hidden_layers":2}}"#
        try withRawFixture(
            configData: Data(configOnly.utf8),
            safetensors: [("model.safetensors", try safetensorsBytes(tensors: packed))]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(error as? NativeMTPArtifactObservationError, .missingQuantizationMetadata("quantization"))
            }
        }

        // The loader quantizes only where `<module>.scales` exists.
        for scaleSuffix in ["scale", "weight_scale"] {
            try withFixture(
                quantization: ["mode": "affine", "bits": 4, "group_size": 64],
                tensors: [
                    tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
                    tensor("model.layers.0.mlp.down_proj.\(scaleSuffix)", dtype: "BF16", shape: [2, 1]),
                    tensor("model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
                ]
            ) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory), scaleSuffix)
            }
        }

        // Per-module override mode is a case-sensitive QuantizationMode.
        let gate = "model.layers.0.mlp.gate"
        try withFixture(
            quantization: ["mode": "affine", "bits": 4, "group_size": 64, gate: ["bits": 8, "group_size": 64, "mode": "Affine"]],
            tensors: packed + [
                tensor("\(gate).weight", dtype: "U32", shape: [4, 16]),
                tensor("\(gate).scales", dtype: "BF16", shape: [4, 1]),
                tensor("\(gate).biases", dtype: "BF16", shape: [4, 1]),
            ]
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(error as? NativeMTPArtifactObservationError, .unsupportedQuantization("mlx affine module override mode"))
            }
        }
    }

    /// A `false` entry must name a consumed floating module: on a packed
    /// module the loader would skip quantizing and fail on the unused scales,
    /// and an entry naming nothing is unmanifested metadata.
    func testFalseEntriesMustMatchConsumedFloatingModules() throws {
        let packed = [
            tensor("model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
            tensor("model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
            tensor("model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
        ]
        try withFixture(
            quantization: ["mode": "affine", "bits": 4, "group_size": 64, "model.layers.0.mlp.down_proj": false],
            tensors: packed
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(error as? NativeMTPArtifactObservationError, .unsupportedQuantization("mlx_affine_4bit unquantized module has packed weights"))
            }
        }
        try withFixture(
            quantization: ["mode": "affine", "bits": 4, "group_size": 64, "model.layers.9.mlp.down_proj": false],
            tensors: packed
        ) { directory in
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                XCTAssertEqual(error as? NativeMTPArtifactObservationError, .unsupportedQuantization("mlx_affine_4bit unmatched unquantized module"))
            }
        }
    }

    /// Nothing is filtered by name any more: optimizer-like tensors the
    /// loader would keep (and then reject as unused keys) are observed, and
    /// target names outside the loader's language-model namespace fail closed.
    func testTargetObservesEveryLoaderConsumedTensorName() throws {
        let packed = [
            tensor("language_model.model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
            tensor("language_model.model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
            tensor("language_model.model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
        ]
        let drafter = try makeFixtureDirectory(
            name: "drafter",
            quantization: ["mode": "affine", "bits": 4, "group_size": 64],
            mtpLayerCount: 1,
            tensors: [
                tensor("fc.weight", dtype: "U32", shape: [2, 8]),
                tensor("fc.scales", dtype: "BF16", shape: [2, 1]),
                tensor("fc.biases", dtype: "BF16", shape: [2, 1]),
            ]
        )
        defer { try? FileManager.default.removeItem(at: drafter.deletingLastPathComponent()) }
        let cases: [(TensorFixture, NativeMTPArtifactObservationError)] = [
            (tensor("language_model.model.layers.0.mlp.adam_m.weight", dtype: "BF16", shape: [2, 64]),
             .incompatibleSafetensorsHeaders("packed tensor language_model.model.layers.0.mlp.adam_m.weight dtype BF16")),
            (tensor("optimizer.state.0.weight", dtype: "BF16", shape: [64]),
             .incompatibleSafetensorsHeaders("target tensor namespace optimizer.state.0.weight")),
            (tensor("language_model.extra.weight", dtype: "BF16", shape: [64]),
             .incompatibleSafetensorsHeaders("target tensor namespace language_model.extra.weight")),
            // The loader's discard predicate has no dot: these would be
            // silently dropped, so they are not the documented vision tower.
            (tensor("vision_tower_evil.weight", dtype: "BF16", shape: [2, 64]),
             .incompatibleSafetensorsHeaders("target tensor namespace vision_tower_evil.weight")),
            (tensor("model.visualizer.weight", dtype: "BF16", shape: [2, 64]),
             .incompatibleSafetensorsHeaders("target tensor namespace model.visualizer.weight")),
        ]
        for (extra, expected) in cases {
            let target = try makeFixtureDirectory(
                name: "target",
                quantization: ["mode": "affine", "bits": 4, "group_size": 64],
                mtpLayerCount: 1,
                tensors: packed + [extra]
            )
            defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(targetDirectory: target, mtpDirectory: drafter)) { error in
                XCTAssertEqual(error as? NativeMTPArtifactObservationError, expected)
            }
        }

        // The dotted vision tower is dropped exactly as the loader drops it,
        // whatever its representation.
        let visionTarget = try makeFixtureDirectory(
            name: "target",
            quantization: ["mode": "affine", "bits": 4, "group_size": 64],
            mtpLayerCount: 1,
            tensors: packed + [
                tensor("vision_tower.blocks.0.attn.qkv.weight", dtype: "U32", shape: [6, 2]),
                tensor("model.visual.blocks.0.norm.weight", dtype: "BF16", shape: [6, 2]),
            ]
        )
        defer { try? FileManager.default.removeItem(at: visionTarget.deletingLastPathComponent()) }
        let observation = try NativeMTPArtifactObserver.observePair(targetDirectory: visionTarget, mtpDirectory: drafter)
        XCTAssertEqual(observation.target.tensorPairs.map(\.weightName), ["language_model.model.layers.0.mlp.down_proj.weight"])
    }

    /// The standalone loader matches `mtp.` case-sensitively; `MTP.` is an
    /// unprefixed key it would rewrite to `mtp.MTP.`, which no module consumes.
    func testDrafterNamespaceIsCaseSensitive() throws {
        let target = try makeFixtureDirectory(
            name: "target",
            dtype: "bfloat16",
            mtpLayerCount: 1,
            tensors: [tensor("language_model.model.layers.0.mlp.down_proj.weight", dtype: "BF16")]
        )
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        for name in ["MTP.layers.0.mlp.gate.weight", "Mtp.fc.weight", "FC.weight", "Layers.0.mlp.gate.weight"] {
            let drafter = try makeFixtureDirectory(name: "drafter", dtype: "bfloat16", mtpLayerCount: 1,
                                                   tensors: [tensor(name, dtype: "BF16")])
            defer { try? FileManager.default.removeItem(at: drafter.deletingLastPathComponent()) }
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(targetDirectory: target, mtpDirectory: drafter)) { error in
                XCTAssertEqual(error as? NativeMTPArtifactObservationError,
                               .incompatibleSafetensorsHeaders("mtp tensor namespace \(name)"))
            }
        }
    }

    func testAffineRepresentationManifestIsCanonicalAndOrderIndependent() throws {
        let targetOverridesA = [
            "model.layers.1.mlp.gate": NativeMTPAffineModuleOverride(bits: 8, groupSize: 64),
            "model.layers.0.mlp.gate": NativeMTPAffineModuleOverride(bits: 4, groupSize: 32),
        ]
        let targetOverridesB = [
            "model.layers.0.mlp.gate": NativeMTPAffineModuleOverride(bits: 4, groupSize: 32),
            "model.layers.1.mlp.gate": NativeMTPAffineModuleOverride(bits: 8, groupSize: 64),
        ]
        func pair(overrides: [String: NativeMTPAffineModuleOverride]) -> NativeMTPArtifactPairObservation {
            NativeMTPArtifactPairObservation(
                target: NativeMTPArtifactObservation(
                    format: .mlxAffine4(bits: 4, groupSize: 64),
                    mtpPredictionLayerCount: 1,
                    tensorPairs: [],
                    affineModuleOverrides: overrides,
                    unquantizedModules: ["model.embed_tokens"]
                ),
                mtp: NativeMTPArtifactObservation(
                    format: .mlxAffine4(bits: 4, groupSize: 64),
                    mtpPredictionLayerCount: 1,
                    tensorPairs: [],
                    affineModuleOverrides: ["layers.0.mlp.gate": NativeMTPAffineModuleOverride(bits: 8, groupSize: 64)],
                    unquantizedModules: ["norm"]
                )
            )
        }

        let first = try NativeMTPArtifactObserver.affineRepresentation(for: pair(overrides: targetOverridesA))
        let second = try NativeMTPArtifactObserver.affineRepresentation(for: pair(overrides: targetOverridesB))
        XCTAssertEqual(first.manifestBytes, second.manifestBytes)
        XCTAssertEqual(first.manifestSHA256, second.manifestSHA256)
        XCTAssertEqual(first.perLayerExceptions, [
            "mtp/layers.0.mlp.gate",
            "target/model.layers.0.mlp.gate",
            "target/model.layers.1.mlp.gate",
        ])
        XCTAssertEqual(first.unquantizedExceptions, ["mtp/norm", "target/model.embed_tokens"])
        XCTAssertEqual(
            String(decoding: first.manifestBytes, as: UTF8.self),
            #"{"mtp":{"bits":4,"group_size":64,"overrides":{"layers.0.mlp.gate":{"bits":8,"group_size":64}},"unquantized":["norm"]},"schema":"macprovider.native-mtp-representation.v1","target":{"bits":4,"group_size":64,"overrides":{"model.layers.0.mlp.gate":{"bits":4,"group_size":32},"model.layers.1.mlp.gate":{"bits":8,"group_size":64}},"unquantized":["model.embed_tokens"]}}"#
        )
    }

    func testAffineRepresentationRejectsInvalidGlobalAndOverrideWidths() throws {
        func pair(
            format: NativeMTPObservedArtifactFormat = .mlxAffine4(bits: 4, groupSize: 64),
            override: NativeMTPAffineModuleOverride
        ) -> NativeMTPArtifactPairObservation {
            let target = NativeMTPArtifactObservation(
                format: format,
                mtpPredictionLayerCount: 1,
                tensorPairs: [],
                affineModuleOverrides: ["model.layers.0.mlp.gate": override]
            )
            let mtp = NativeMTPArtifactObservation(
                format: format,
                mtpPredictionLayerCount: 1,
                tensorPairs: []
            )
            return NativeMTPArtifactPairObservation(target: target, mtp: mtp)
        }

        XCTAssertThrowsError(try NativeMTPArtifactObserver.affineRepresentation(
            for: pair(format: .mlxAffine4(bits: 8, groupSize: 64), override: .init(bits: 8, groupSize: 64))
        )) { error in
            XCTAssertEqual(
                error as? NativeMTPArtifactObservationError,
                .unsupportedQuantization("affine representation requires matching global 4-bit formats")
            )
        }
        for override in [
            NativeMTPAffineModuleOverride(bits: 3, groupSize: 64),
            NativeMTPAffineModuleOverride(bits: 8, groupSize: 48),
        ] {
            XCTAssertThrowsError(try NativeMTPArtifactObserver.affineRepresentation(for: pair(override: override))) { error in
                XCTAssertEqual(
                    error as? NativeMTPArtifactObservationError,
                    .unsupportedQuantization("invalid affine manifest override")
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
            mtpLayerCount: 3,
            tensors: [tensor("layers.0.mlp.down_proj.weight", dtype: "BF16")]
        )
        defer {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: drafter.deletingLastPathComponent())
        }

        XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(
            targetDirectory: target,
            mtpDirectory: drafter
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
            mtpLayerCount: 2,
            tensors: [tensor("layers.0.mlp.down_proj.weight", dtype: "BF16")]
        )
        let extraDrafter = try makeFixtureDirectory(
            name: "drafter-extra",
            dtype: "bfloat16",
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
            mtpDirectory: cleanDrafter
        )) { error in
            XCTAssertEqual(
                error as? NativeMTPArtifactObservationError,
                .incompatibleSafetensorsHeaders("target tensor namespace model.mtp.moment.down_proj.weight")
            )
        }
        XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(
            targetDirectory: cleanTarget,
            mtpDirectory: extraDrafter
        )) { error in
            XCTAssertEqual(
                error as? NativeMTPArtifactObservationError,
                .incompatibleSafetensorsHeaders("mtp tensor namespace extra.layers.0.mlp.down_proj.weight")
            )
        }
    }

    /// Namespaces the pinned standalone-drafter loader actually consumes
    /// (`qwenMTPSanitizeWeights` prefixes each key with `mtp.`).
    func testStandaloneDrafterNamespaceMatchesLoaderLayout() throws {
        let target = try makeFixtureDirectory(
            name: "target",
            dtype: "bfloat16",
            mtpLayerCount: 1,
            tensors: [tensor("language_model.model.layers.0.mlp.down_proj.weight", dtype: "BF16")]
        )
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        let accepted = ["fc.weight", "layers.0.self_attn.q_proj.weight", "norm.weight",
                        "pre_fc_norm_embedding.weight", "pre_fc_norm_hidden.weight", "mtp.layers.0.mlp.gate.weight"]
        for name in accepted {
            let drafter = try makeFixtureDirectory(name: "drafter", dtype: "bfloat16", mtpLayerCount: 1,
                                                   tensors: [tensor(name, dtype: "BF16")])
            defer { try? FileManager.default.removeItem(at: drafter.deletingLastPathComponent()) }
            XCTAssertNoThrow(try NativeMTPArtifactObserver.observePair(targetDirectory: target, mtpDirectory: drafter), name)
        }
        for name in ["model.layers.0.mlp.down_proj.weight", "lm_head.weight", "embed_tokens.weight", "fc", "mtp.model.norm.weight"] {
            let drafter = try makeFixtureDirectory(name: "drafter", dtype: "bfloat16", mtpLayerCount: 1,
                                                   tensors: [tensor(name, dtype: "BF16")])
            defer { try? FileManager.default.removeItem(at: drafter.deletingLastPathComponent()) }
            XCTAssertThrowsError(try NativeMTPArtifactObserver.observePair(targetDirectory: target, mtpDirectory: drafter)) { error in
                XCTAssertEqual(error as? NativeMTPArtifactObservationError,
                               .incompatibleSafetensorsHeaders("mtp tensor namespace \(name)"))
            }
        }
    }

    /// Real mlx-community Qwen3.5/3.6 targets keep norms, SSM parameters,
    /// conv kernels, and the discarded vision tower in floating point.
    func testQuantizedArtifactAcceptsNeverQuantizedFloatingTensors() throws {
        let packed = [
            tensor("language_model.model.layers.0.mlp.down_proj.weight", dtype: "U32", shape: [2, 8]),
            tensor("language_model.model.layers.0.mlp.down_proj.scales", dtype: "BF16", shape: [2, 1]),
            tensor("language_model.model.layers.0.mlp.down_proj.biases", dtype: "BF16", shape: [2, 1]),
        ]
        let floating = [
            tensor("language_model.model.layers.0.input_layernorm.weight", dtype: "BF16", shape: [64]),
            tensor("language_model.model.layers.0.linear_attn.A_log", dtype: "F32", shape: [4]),
            tensor("language_model.model.layers.0.linear_attn.dt_bias", dtype: "BF16", shape: [4]),
            tensor("language_model.model.layers.0.linear_attn.conv1d.weight", dtype: "BF16", shape: [8, 4, 1]),
            tensor("vision_tower.blocks.0.attn.qkv.weight", dtype: "BF16", shape: [6, 2]),
            tensor("vision_tower.patch_embed.proj.weight", dtype: "BF16", shape: [2, 2, 2, 2, 1]),
        ]
        try withFixture(quantization: ["mode": "affine", "bits": 4, "group_size": 64], tensors: packed + floating) { directory in
            let observation = try NativeMTPArtifactObserver.observe(directory: directory)
            XCTAssertEqual(observation.format, .mlxAffine4(bits: 4, groupSize: 64))
            XCTAssertEqual(observation.tensorPairs.map(\.weightName), ["language_model.model.layers.0.mlp.down_proj.weight"])
        }

        let failClosed: [(TensorFixture, String)] = [
            // Unscaled rank-2 language-model weight: an unexpectedly unquantized Linear.
            (tensor("language_model.model.layers.0.mlp.up_proj.weight", dtype: "BF16", shape: [2, 64]),
             "packed tensor language_model.model.layers.0.mlp.up_proj.weight dtype BF16"),
            // Rank-3 floating tensor that is not a conv kernel.
            (tensor("language_model.model.layers.0.mlp.experts.weight", dtype: "BF16", shape: [2, 2, 64]),
             "packed tensor language_model.model.layers.0.mlp.experts.weight dtype BF16"),
            // Rank-1 integer tensor is not a floating parameter.
            (tensor("language_model.model.layers.0.input_layernorm.weight", dtype: "U32", shape: [64]),
             "packed tensor language_model.model.layers.0.input_layernorm.weight shape"),
        ]
        for (extra, reason) in failClosed {
            try withFixture(quantization: ["mode": "affine", "bits": 4, "group_size": 64], tensors: packed + [extra]) { directory in
                XCTAssertThrowsError(try NativeMTPArtifactObserver.observe(directory: directory)) { error in
                    XCTAssertEqual(error as? NativeMTPArtifactObservationError, .incompatibleSafetensorsHeaders(reason))
                }
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
        let config = #"{"quantization":{"mode":"affine","bits":4,"group_size":64},"text_config":{"mtp_num_hidden_layers":2}}"#
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
