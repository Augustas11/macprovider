#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MLX
import MLXLMCommon
import MLXNN
import XCTest
@testable import macprovider_cli

final class LabDecodeTopKTests: XCTestCase {
    override func invokeTest() {
        Device.withDefaultDevice(Device(.cpu)) {
            super.invokeTest()
        }
    }

    override class func setUp() {
        super.setUp()
        MLXTestDevice.pinProcessCPUDefaultWithoutMetallib()
    }

    func testUnsetIsOffAndLeavesComponentsUnchanged() throws {
        XCTAssertNil(try LabDecodeTopK.configuration(environment: [:]))
        XCTAssertNil(try LabDecodeTopK.configuration(environment: [LabDecodeTopK.pathKey: ""]))
        let components = try LabDecodeTopK.appending(to: GenerationComponents(), promptTokenIDs: [1], environment: [:])
        XCTAssertNil(components.logitProcessorFactory)
    }

    func testConfigurationParsesAndFailsClosed() throws {
        let path = "/private/tmp/topk.jsonl"
        XCTAssertEqual(
            try LabDecodeTopK.configuration(environment: [
                LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "15, 0", LabDecodeTopK.kKey: "8",
            ]),
            LabDecodeTopK.Configuration(path: path, indices: [0, 15], k: 8))
        XCTAssertEqual(
            try LabDecodeTopK.configuration(environment: [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "3"])?.k, 5)
        XCTAssertEqual(
            try LabDecodeTopK.configuration(environment: [
                LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "3", LabDecodeTopK.layersKey: "1",
            ])?.layers, true)
        XCTAssertEqual(
            try LabDecodeTopK.configuration(environment: [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "3"])?.layers,
            false)
        for bad in [
            [LabDecodeTopK.pathKey: "relative.jsonl", LabDecodeTopK.indicesKey: "1"],
            [LabDecodeTopK.pathKey: path],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "1,x"],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "-1"],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "1,"],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "1", LabDecodeTopK.kKey: "1"],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "1", LabDecodeTopK.kKey: "65"],
            [LabDecodeTopK.pathKey: path, LabDecodeTopK.indicesKey: "1", LabDecodeTopK.layersKey: "yes"],
        ] {
            XCTAssertThrowsError(try LabDecodeTopK.configuration(environment: bad), "\(bad)")
        }
    }

    /// Drives the processor the way TokenIterator does (process, sample,
    /// didSample) and checks it records exactly the chosen indices, with the
    /// ids before each, passes logits through unchanged and keeps bf16 values.
    func testRecordsChosenIndicesWithPrefixIdsAndUnchangedLogits() throws {
        // Evaluating MLX arrays loads the metallib; CI runners have none.
        try XCTSkipUnless(MLXTestDevice.metallibAvailable, "no mlx.metallib on this host")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("topk.jsonl")
        let components = try LabDecodeTopK.appending(
            to: GenerationComponents(), promptTokenIDs: [7, 8, 9],
            environment: [LabDecodeTopK.pathKey: file.path, LabDecodeTopK.indicesKey: "1,2", LabDecodeTopK.kKey: "3"])
        var processor = try XCTUnwrap(components.logitProcessorFactory?())
        processor.prompt(MLXArray([Int32(9)]))
        let steps: [[Float]] = [
            [0, 5, 1, 2],
            [23.875, 1, 23.375, 23.5],
            [3, 2, 1, 4],
        ]
        for values in steps {
            let logits = MLXArray(values).asType(.bfloat16).reshaped([1, 4])
            let out = processor.process(logits: logits)
            XCTAssertEqual(out.asType(.float32).asArray(Float.self), values)
            processor.didSample(token: argMax(out, axis: -1))
        }
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let records = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["schema"] as? String, LabDecodeTopK.schema)
        XCTAssertEqual(records[0]["decode_index"] as? Int, 1)
        XCTAssertEqual(records[0]["prompt_token_ids"] as? [Int], [7, 8, 9])
        XCTAssertEqual(records[0]["generated_token_ids"] as? [Int], [1])
        XCTAssertEqual(records[0]["top_ids"] as? [Int], [0, 3, 2])
        XCTAssertEqual(records[0]["top_logits"] as? [Double], [23.875, 23.5, 23.375])
        XCTAssertEqual(records[0]["dtype"] as? String, "bfloat16")
        XCTAssertEqual(records[1]["decode_index"] as? Int, 2)
        XCTAssertEqual(records[1]["generated_token_ids"] as? [Int], [1, 0])
        XCTAssertEqual(records[1]["top_ids"] as? [Int], [3, 0, 1])
        XCTAssertNil(records[0]["layers"])
    }

    func testTapPathsInstallOnceAndRejectUnknownShapes() throws {
        // Building the toy model's norms evaluates MLX arrays, which loads the metallib.
        try XCTSkipUnless(MLXTestDevice.metallibAvailable, "no mlx.metallib on this host")
        let root = ToyRoot(layers: 2)
        let sink = try LabDecodeTopK.installTaps(in: root)
        XCTAssertEqual(sink.names, ["model.layers.0.input_layernorm", "model.layers.1.input_layernorm", "model.norm"])
        let modules = Dictionary(root.namedModules(), uniquingKeysWith: { first, _ in first })
        for (ordinal, name) in sink.names.enumerated() {
            let tap = try XCTUnwrap(modules[name] as? LabDecodeTopK.Tap, name)
            XCTAssertEqual(tap.ordinal, ordinal)
            XCTAssertEqual(tap.eps, 1e-6)
        }
        XCTAssertTrue(try LabDecodeTopK.installTaps(in: root) === sink, "a second request reuses the taps")
        XCTAssertNil(sink.snapshot(), "no forward ran yet")
        XCTAssertEqual(sink.extraNames, [])

        let withSublayer = try LabDecodeTopK.installTaps(in: ToyRoot(layers: 2), sublayer: 1)
        XCTAssertEqual(withSublayer.extraNames,
            ["model.layers.1.post_attention_layernorm", "model.layers.1.pre_feedforward_layernorm"])
        XCTAssertThrowsError(try LabDecodeTopK.installTaps(in: ToyRoot(layers: 2), sublayer: 2))
        XCTAssertThrowsError(try LabDecodeTopK.configuration(environment: [
            LabDecodeTopK.pathKey: "/private/tmp/x.jsonl", LabDecodeTopK.indicesKey: "0",
            LabDecodeTopK.sublayerKey: "1",
        ]), "a sub-layer needs the layer taps")
        XCTAssertEqual(try LabDecodeTopK.configuration(environment: [
            LabDecodeTopK.pathKey: "/private/tmp/x.jsonl", LabDecodeTopK.indicesKey: "0",
            LabDecodeTopK.layersKey: "1", LabDecodeTopK.sublayerKey: "18",
        ])?.sublayer, 18)

        let noFinal = ToyInner(layers: 1)
        XCTAssertThrowsError(try LabDecodeTopK.tapPaths(in: noFinal))
        XCTAssertThrowsError(
            try LabDecodeTopK.appending(
                to: GenerationComponents(), promptTokenIDs: [1],
                environment: [
                    LabDecodeTopK.pathKey: "/private/tmp/x.jsonl", LabDecodeTopK.indicesKey: "0",
                    LabDecodeTopK.layersKey: "1",
                ]),
            "layer taps without a model fail closed")
    }

    /// Taps leave the forward bit-identical and the record carries each
    /// layer's last-position input from the forward that made the logits.
    func testLayerTapsRecordLastPositionInputsAndKeepOutputs() throws {
        try XCTSkipUnless(MLXTestDevice.metallibAvailable, "no mlx.metallib on this host")
        let root = ToyRoot(layers: 2)
        let x = MLXArray((0 ..< 12).map { Float($0) * 0.25 - 1 }).asType(.bfloat16).reshaped([1, 3, 4])
        let before = root(x)
        let sink = try LabDecodeTopK.installTaps(in: root, sublayer: 1)
        let after = root(x)
        XCTAssertEqual(before.asType(.float32).asArray(Float.self), after.asType(.float32).asArray(Float.self))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let configuration = LabDecodeTopK.Configuration(
            path: dir.appendingPathComponent("t.jsonl").path, indices: [0], k: 2, layers: true)
        let recorder = LabDecodeTopK.Recorder(configuration: configuration, promptTokenIDs: [1], taps: sink)
        let record = recorder.record(logits: after[0..., -1, 0...])
        let layers = try XCTUnwrap(record["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.map { $0["tap"] as? String }, sink.names)
        let h0 = x[0, -1]
        let h1 = root.model.layers[0](x)[0, -1]
        let h2 = root.model.layers[1](root.model.layers[0](x))[0, -1]
        for (entry, expected) in zip(layers, [h0, h1, h2]) {
            XCTAssertEqual(entry["values"] as? [Double], expected.asType(.float32).asArray(Float.self).map(Double.init))
            XCTAssertEqual(entry["dtype"] as? String, String(describing: expected.dtype))
        }
        // Only the sub-layer norm that ran is reported: its input is layer 1's
        // post-attention state.
        let sublayer = try XCTUnwrap(record["sublayer"] as? [[String: Any]])
        XCTAssertEqual(sublayer.map { $0["tap"] as? String }, ["model.layers.1.pre_feedforward_layernorm"])
        let attended = root.model.layers[1].attention(root.model.layers[0](x))[0, -1]
        XCTAssertEqual(sublayer[0]["values"] as? [Double], attended.asType(.float32).asArray(Float.self).map { Double($0) })
    }
}

/// A two-level tree shaped like the LLM models: `model.layers.N.input_layernorm`
/// and `model.norm`.
private final class ToyLayer: Module {
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforward: RMSNorm
    /// Never called, like a norm a model fuses into a kernel.
    @ModuleInfo(key: "post_attention_layernorm") var postAttention: RMSNorm
    let scale: Float

    init(scale: Float) {
        self.scale = scale
        self._inputLayernorm.wrappedValue = RMSNorm(dimensions: 4, eps: 1e-6)
        self._preFeedforward.wrappedValue = RMSNorm(dimensions: 4, eps: 1e-6)
        self._postAttention.wrappedValue = RMSNorm(dimensions: 4, eps: 1e-6)
    }

    func attention(_ x: MLXArray) -> MLXArray { x + inputLayernorm(x) * scale }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = attention(x)
        return h + preFeedforward(h) * 0.5
    }
}

private final class ToyInner: Module {
    @ModuleInfo(key: "layers") var layers: [ToyLayer]
    @ModuleInfo(key: "head") var head: RMSNorm

    init(layers count: Int) {
        self._layers.wrappedValue = (0 ..< count).map { ToyLayer(scale: Float($0 + 1)) }
        self._head.wrappedValue = RMSNorm(dimensions: 4, eps: 1e-6)
    }
}

private final class ToyRoot: Module {
    @ModuleInfo(key: "model") var model: ToyModel

    init(layers count: Int) {
        self._model.wrappedValue = ToyModel(layers: count)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { model(x) }
}

private final class ToyModel: Module {
    @ModuleInfo(key: "layers") var layers: [ToyLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    init(layers count: Int) {
        self._layers.wrappedValue = (0 ..< count).map { ToyLayer(scale: Float($0 + 1)) }
        self._norm.wrappedValue = RMSNorm(dimensions: 4, eps: 1e-6)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        norm(layers.reduce(x) { h, layer in layer(h) })
    }
}
#endif
