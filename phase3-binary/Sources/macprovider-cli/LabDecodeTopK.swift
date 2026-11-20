#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Issue #2443 lab hook: the top-k logits the serial route's sampler sees at
/// chosen decode indices, with the exact prompt and generated token ids before
/// each one, so `scripts/lab/parity-grid/decode_topk.py` can feed mlx-lm the
/// same ids. Off unless `MACPROVIDER_LAB_DECODE_TOPK` names an absolute file;
/// the call sites exist only in MACPROVIDER_LAB_HARNESS builds.
///
/// - `MACPROVIDER_LAB_DECODE_TOPK_INDICES`: comma-separated decode indices
///   (0 is the first generated token). Required.
/// - `MACPROVIDER_LAB_DECODE_TOPK_K`: entries per record, 2...64, default 5.
/// - `MACPROVIDER_LAB_DECODE_TOPK_LAYERS=1`: also record, at each chosen index,
///   the last-position hidden state entering every decoder layer and the final
///   norm (`layers.N.input_layernorm` and `model.norm` inputs), so
///   `layer_trace.py` can find the first layer that leaves mlx-lm's spread.
///   Installs `Tap` norms into the loaded model; they compute exactly what the
///   norms they replace compute.
///
/// The processor passes logits through unchanged. A recorded index evaluates
/// its logits once; other steps add no evaluation.
enum LabDecodeTopK {
    static let pathKey = "MACPROVIDER_LAB_DECODE_TOPK"
    static let indicesKey = "MACPROVIDER_LAB_DECODE_TOPK_INDICES"
    static let kKey = "MACPROVIDER_LAB_DECODE_TOPK_K"
    static let layersKey = "MACPROVIDER_LAB_DECODE_TOPK_LAYERS"
    static let schema = "macprovider.lab-decode-topk.v1"

    struct Configuration: Sendable, Equatable {
        let path: String
        let indices: Set<Int>
        let k: Int
        var layers = false
    }

    struct ConfigurationError: Error, CustomStringConvertible {
        let description: String
    }

    static func configuration(environment: [String: String]) throws -> Configuration? {
        guard let path = environment[pathKey], !path.isEmpty else { return nil }
        guard (path as NSString).isAbsolutePath, !path.utf8.contains(0) else {
            throw ConfigurationError(description: "\(pathKey) must be an absolute path")
        }
        let rawIndices = (environment[indicesKey] ?? "").split(separator: ",", omittingEmptySubsequences: false)
        let indices = rawIndices.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !rawIndices.isEmpty, indices.count == rawIndices.count,
              indices.allSatisfy({ (0...(1 << 20)).contains($0) }) else {
            throw ConfigurationError(description: "\(indicesKey) must list decode indices 0...1048576")
        }
        var k = 5
        if let rawK = environment[kKey] {
            guard let parsed = Int(rawK), (2...64).contains(parsed) else {
                throw ConfigurationError(description: "\(kKey) must be 2...64")
            }
            k = parsed
        }
        var layers = false
        if let rawLayers = environment[layersKey], !rawLayers.isEmpty {
            guard rawLayers == "1" || rawLayers == "0" else {
                throw ConfigurationError(description: "\(layersKey) must be 0 or 1")
            }
            layers = rawLayers == "1"
        }
        return Configuration(path: path, indices: Set(indices), k: k, layers: layers)
    }

    /// `components` with the recorder appended when the hook is configured;
    /// unchanged otherwise. `promptTokenIDs` is the complete prompt, including
    /// any prefix a reused cache already holds.
    static func appending(
        to components: GenerationComponents,
        promptTokenIDs: [Int],
        model: (any LanguageModel)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GenerationComponents {
        guard let configuration = try configuration(environment: environment) else { return components }
        let taps: TapSink?
        if configuration.layers {
            guard let root = model as? Module else {
                throw ConfigurationError(description: "\(layersKey)=1 needs the loaded model")
            }
            taps = try installTaps(in: root)
        } else {
            taps = nil
        }
        return components.appendingLogitProcessor {
            Recorder(configuration: configuration, promptTokenIDs: promptTokenIDs, taps: taps)
        }
    }

    // MARK: - Layer taps

    /// The latest forward's last-position input to each tapped norm.
    final class TapSink: @unchecked Sendable {
        let names: [String]
        private let lock = NSLock()
        private var latest: [Int: MLXArray] = [:]

        init(names: [String]) { self.names = names }

        func store(_ x: MLXArray, ordinal: Int) {
            let last = x.reshaped([-1, x.dim(-1)])[-1]
            lock.withLock { latest[ordinal] = last }
        }

        /// Ordinal-ordered vectors, nil unless every tap fired.
        func snapshot() -> [MLXArray]? {
            lock.withLock {
                let out = names.indices.compactMap { latest[$0] }
                return out.count == names.count ? out : nil
            }
        }
    }

    /// An RMSNorm that records its input, then computes exactly what the norm
    /// it replaces computes (same weight array, same eps, same kernel).
    final class Tap: RMSNorm {
        let sink: TapSink
        let ordinal: Int

        init(replacing norm: RMSNorm, sink: TapSink, ordinal: Int) {
            self.sink = sink
            self.ordinal = ordinal
            super.init(dimensions: norm.weight.dim(0), eps: norm.eps)
            update(parameters: ModuleParameters(values: ["weight": .value(norm.weight)]))
        }

        override func callAsFunction(_ x: MLXArray) -> MLXArray {
            sink.store(x, ordinal: ordinal)
            return super.callAsFunction(x)
        }
    }

    /// Tap names in forward order: `layers.N.input_layernorm` (the input to
    /// layer N, so layer 0 sees the scaled embeddings), then the final norm
    /// (the last layer's output). Paths keep the model's own prefix.
    static func tapPaths(in root: Module) throws -> [String] {
        var layerPaths: [(Int, String)] = []
        var finals: [String] = []
        for (path, module) in root.namedModules() where module is RMSNorm {
            let parts = path.split(separator: ".").map(String.init)
            if parts.count >= 3, parts[parts.count - 1] == "input_layernorm",
               parts[parts.count - 3] == "layers", let n = Int(parts[parts.count - 2]) {
                layerPaths.append((n, path))
            } else if parts.count >= 2, parts.last == "norm", parts[parts.count - 2] == "model" {
                finals.append(path)
            }
        }
        layerPaths.sort { $0.0 < $1.0 }
        guard !layerPaths.isEmpty, layerPaths.map(\.0) == Array(0 ..< layerPaths.count), finals.count == 1 else {
            throw ConfigurationError(description:
                "layer taps need layers.N.input_layernorm (0...N contiguous) and one model.norm RMSNorm; "
                + "found \(layerPaths.count) layer norms and \(finals.count) final norms")
        }
        return layerPaths.map(\.1) + finals
    }

    /// Replaces each tapped norm with a `Tap` once per loaded model and
    /// returns the shared sink; later requests reuse the installed taps.
    static func installTaps(in root: Module) throws -> TapSink {
        let paths = try tapPaths(in: root)
        let modules = Dictionary(root.namedModules(), uniquingKeysWith: { first, _ in first })
        if let first = modules[paths[0]] as? Tap {
            return first.sink
        }
        let sink = TapSink(names: paths)
        for (ordinal, path) in paths.enumerated() {
            guard let norm = modules[path] as? RMSNorm else {
                throw ConfigurationError(description: "\(path) is not an RMSNorm")
            }
            let parts = path.split(separator: ".").map(String.init)
            let parentPath = parts.dropLast().joined(separator: ".")
            guard let parent = parentPath.isEmpty ? root : modules[parentPath] else {
                throw ConfigurationError(description: "\(parentPath) not found")
            }
            let tap = Tap(replacing: norm, sink: sink, ordinal: ordinal)
            try parent.update(modules: ModuleChildren(values: [parts.last!: .value(tap)]), verify: .noUnusedKeys)
        }
        let installed = Dictionary(root.namedModules(), uniquingKeysWith: { first, _ in first })
        guard paths.allSatisfy({ installed[$0] is Tap }) else {
            throw ConfigurationError(description: "layer taps were not installed")
        }
        return sink
    }

    struct Recorder: LogitProcessor {
        let configuration: Configuration
        let promptTokenIDs: [Int]
        let taps: TapSink?
        private let lastIndex: Int
        private var step = 0
        private var sampled: [MLXArray] = []

        init(configuration: Configuration, promptTokenIDs: [Int], taps: TapSink? = nil) {
            self.configuration = configuration
            self.promptTokenIDs = promptTokenIDs
            self.taps = taps
            self.lastIndex = configuration.indices.max() ?? 0
        }

        mutating func prompt(_ prompt: MLXArray) {}

        func process(logits: MLXArray) -> MLXArray {
            guard configuration.indices.contains(step) else { return logits }
            do {
                try LabOutputTokenCapture.appendRecord(record(logits: logits), path: configuration.path)
            } catch {
                FileHandle.standardError.write(Data("lab decode top-k: index \(step) not recorded: \(error)\n".utf8))
            }
            return logits
        }

        mutating func didSample(token: MLXArray) {
            if step < lastIndex { sampled.append(token) }
            step += 1
        }

        /// One record for the current step. `logits` is the sampler's
        /// `[rows, vocab]` input; row 0 is recorded.
        func record(logits: MLXArray) -> [String: Any] {
            let row = logits.reshaped([-1, logits.dim(-1)])[0]
            let values = row.asType(.float32)
            let k = min(configuration.k, row.dim(0))
            let order = argSort(-values)[0 ..< k]
            let top = take(values, order)
            let generated = sampled.isEmpty
                ? MLXArray([Int32]()) : concatenated(sampled.map { $0.reshaped([-1]).asType(.int32) })
            eval(order, top, generated)
            var out: [String: Any] = [
                "schema": LabDecodeTopK.schema,
                "decode_index": step,
                "prompt_token_ids": promptTokenIDs,
                "generated_token_ids": generated.asArray(Int32.self).map(Int.init),
                "top_ids": order.asArray(Int32.self).map(Int.init),
                "top_logits": top.asArray(Float.self).map(Double.init),
                "dtype": String(describing: row.dtype),
            ]
            if let taps {
                // The forward that produced these logits is the latest one
                // every tap saw: process runs right after it, before the next.
                if let vectors = taps.snapshot() {
                    let values = vectors.map { $0.asType(.float32) }
                    eval(values)
                    out["layers"] = zip(taps.names, zip(vectors, values)).map { name, pair in
                        [
                            "tap": name, "dtype": String(describing: pair.0.dtype),
                            "values": pair.1.asArray(Float.self).map { Double($0) },
                        ] as [String: Any]
                    }
                } else {
                    out["layers_error"] = "not every tap fired before this step"
                }
            }
            return out
        }
    }
}
#endif
