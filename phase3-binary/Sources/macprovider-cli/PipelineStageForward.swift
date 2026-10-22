import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MacProviderCore

// Issue #2084 stage forward: one pipeline stage of a decoder-only model, holding only
// its own layers' weights and KV caches.
//
// The model classes in the pinned mlx-swift-lm fork keep their decoder blocks
// internal (Qwen2/Qwen3 even fileprivate), so this file never calls a block
// directly. Instead each stage is a stock model instance built from a rewritten
// config with only the stage's layers (weights renamed `a..<b` -> `0..<n`), and two
// public MLXNN seams adapt its edges:
//
//   * a non-first stage swaps `model.embed_tokens` for an `Embedding` subclass that
//     passes the incoming hidden state through instead of looking up tokens;
//   * a non-last stage is built with one extra, unloaded layer whose
//     `input_layernorm` is an `RMSNorm` subclass recording its input. That input is
//     exactly the residual stream after the stage's last real layer. Only the
//     recorded array is evaluated, so MLX's lazy graph never runs the extra layer,
//     the final norm or the LM head.
//
// The last stage keeps the real final norm and LM head and returns logits. The stock
// forward runs the same ops in the same order as the single-process model, so a
// greedy staged decode must match it token for token.

enum PipelineStageError: Error, CustomStringConvertible {
    case unsupportedModelType(String)
    case invalidLayerRange(lower: Int, upper: Int, total: Int)
    case invalidConfig(String)
    case noWeights(URL)
    case surgery(String)
    case missingCapture
    case unsupportedActivationDType(String)
    case activationShape([Int])

    var description: String {
        switch self {
        case .unsupportedModelType(let type):
            return "model_type '\(type)' is not supported for pipeline stages (supported: \(PipelineStageModel.supportedModelTypes.sorted().joined(separator: ", ")))"
        case .invalidLayerRange(let lower, let upper, let total):
            return "layer range \(lower):\(upper) is not a non-empty sub-range of 0:\(total)"
        case .invalidConfig(let detail):
            return "invalid model config: \(detail)"
        case .noWeights(let directory):
            return "no .safetensors weights in \(directory.path)"
        case .surgery(let detail):
            return "stage module surgery failed: \(detail)"
        case .missingCapture:
            return "stage forward did not record the boundary hidden state"
        case .unsupportedActivationDType(let dtype):
            return "activation dtype \(dtype) cannot be shipped between stages"
        case .activationShape(let shape):
            return "activation shape \(shape) is not [batch, tokens, hidden]"
        }
    }
}

/// Records the residual stream entering the extra layer of a non-last stage.
final class PipelineStageCaptureNorm: RMSNorm {
    private(set) var captured: MLXArray?

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        captured = x
        return super.callAsFunction(x)
    }

    func take() -> MLXArray? {
        defer { captured = nil }
        return captured
    }
}

/// Passes the previous stage's hidden state through where the model embeds tokens.
/// Tied-embedding models still project logits through the real table on the last
/// stage, so `asLinear` delegates to the wrapped embedding.
final class PipelineStageInputEmbedding: Embedding {
    let tied: Embedding

    init(wrapping tied: Embedding) {
        self.tied = tied
        super.init(weight: MLXArray.zeros([1, 1]))
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray { x }

    override func asLinear(_ x: MLXArray) -> MLXArray { tied.asLinear(x) }
}

struct PipelineStagePlan: Equatable, Sendable {
    let layers: Range<Int>
    let totalLayers: Int

    var isFirst: Bool { layers.lowerBound == 0 }
    var isLast: Bool { layers.upperBound == totalLayers }

    init(layers: Range<Int>, totalLayers: Int) throws {
        guard !layers.isEmpty, layers.lowerBound >= 0, layers.upperBound <= totalLayers else {
            throw PipelineStageError.invalidLayerRange(
                lower: layers.lowerBound, upper: layers.upperBound, total: totalLayers)
        }
        self.layers = layers
        self.totalLayers = totalLayers
    }
}

final class PipelineStageModel {
    /// Families whose layers are uniform, whose embedding is used unscaled, and whose
    /// block reads `input_layernorm` first, which is what the two seams rely on.
    /// GLM-5-Next carries hyper-connection streams across layers and is not here.
    static let supportedModelTypes: Set<String> = ["llama", "mistral", "qwen2", "qwen3", "deepseek_v3"]

    let plan: PipelineStagePlan
    let modelType: String
    let hiddenSize: Int
    let model: any LLMModel
    private let capture: PipelineStageCaptureNorm?

    /// Bytes of weights this stage materialized.
    let weightBytes: Int

    /// Number of layer caches the stage's own (real) layers use; a non-last stage has
    /// one more cache entry for the never-evaluated capture layer.
    var realLayerCount: Int { plan.layers.count }

    static func readConfig(directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PipelineStageError.invalidConfig("config.json is not an object")
        }
        return config
    }

    static func totalLayers(config: [String: Any]) throws -> Int {
        guard let total = config["num_hidden_layers"] as? Int, total > 0 else {
            throw PipelineStageError.invalidConfig("num_hidden_layers missing")
        }
        return total
    }

    /// Build and load one stage. Model construction goes through the fork's model-type
    /// registry (an actor); everything after it is synchronous.
    static func load(directory: URL, layers: Range<Int>) async throws -> PipelineStageModel {
        let config = try readConfig(directory: directory)
        guard let modelType = config["model_type"] as? String else {
            throw PipelineStageError.invalidConfig("model_type missing")
        }
        guard supportedModelTypes.contains(modelType) else {
            throw PipelineStageError.unsupportedModelType(modelType)
        }
        let plan = try PipelineStagePlan(layers: layers, totalLayers: try totalLayers(config: config))
        let builtLayers = plan.layers.count + (plan.isLast ? 0 : 1)
        let configData = try JSONSerialization.data(
            withJSONObject: try stageConfig(config, plan: plan, builtLayers: builtLayers))
        let created = try await LLMTypeRegistry.shared.createModel(configuration: configData, modelType: modelType)
        guard let model = created as? any LLMModel else {
            throw PipelineStageError.unsupportedModelType(modelType)
        }
        return try PipelineStageModel(
            directory: directory, config: config, plan: plan, configData: configData, model: model)
    }

    private init(
        directory: URL,
        config: [String: Any],
        plan: PipelineStagePlan,
        configData: Data,
        model: any LLMModel
    ) throws {
        guard let modelType = config["model_type"] as? String,
              let hiddenSize = config["hidden_size"] as? Int, hiddenSize > 0
        else {
            throw PipelineStageError.invalidConfig("model_type or hidden_size missing")
        }
        self.plan = plan
        self.modelType = modelType
        self.hiddenSize = hiddenSize

        var weights = try Self.loadStageWeights(directory: directory, plan: plan)
        weights = model.sanitize(weights: weights, metadata: [:])

        let base = try JSONDecoder().decode(BaseConfiguration.self, from: configData)
        // `perLayerQuantization` also carries a uniform quantization as its default.
        if let perLayer = base.perLayerQuantization {
            quantize(model: model) { path, _ in
                guard weights["\(path).scales"] != nil else { return nil }
                return perLayer.quantization(layer: path)?.asTuple
            }
        }
        // Every loaded tensor must land; modules this stage never evaluates (other
        // stages' embedding/head, the capture layer) are left unloaded on purpose.
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.noUnusedKeys, .shapeMismatch])
        let loaded = Array(weights.values)
        eval(loaded)
        self.weightBytes = loaded.reduce(0) { $0 + $1.nbytes }
        self.model = model

        let modules = Dictionary(model.namedModules(), uniquingKeysWith: { first, _ in first })
        if !plan.isFirst {
            guard let inner = modules["model"], let embedding = modules["model.embed_tokens"] as? Embedding else {
                throw PipelineStageError.surgery("model.embed_tokens not found")
            }
            try inner.update(
                modules: ModuleChildren(values: ["embed_tokens": .value(PipelineStageInputEmbedding(wrapping: embedding))]),
                verify: .noUnusedKeys)
            guard Dictionary(model.namedModules(), uniquingKeysWith: { first, _ in first })["model.embed_tokens"]
                is PipelineStageInputEmbedding
            else {
                throw PipelineStageError.surgery("model.embed_tokens was not replaced")
            }
        }
        if plan.isLast {
            self.capture = nil
        } else {
            let key = "model.layers.\(plan.layers.count)"
            guard let extraLayer = modules[key], let norm = modules["\(key).input_layernorm"] as? RMSNorm else {
                throw PipelineStageError.surgery("\(key).input_layernorm not found")
            }
            let capture = PipelineStageCaptureNorm(dimensions: hiddenSize, eps: norm.eps)
            try extraLayer.update(
                modules: ModuleChildren(values: ["input_layernorm": .value(capture)]), verify: .noUnusedKeys)
            guard Dictionary(model.namedModules(), uniquingKeysWith: { first, _ in first })["\(key).input_layernorm"]
                === capture
            else {
                throw PipelineStageError.surgery("\(key).input_layernorm was not replaced")
            }
            self.capture = capture
            guard try model.newCache(parameters: nil).last is KVCacheSimple else {
                throw PipelineStageError.surgery("capture layer cache is not KVCacheSimple; it could not be re-seeded per step")
            }
        }
    }

    func newCache() throws -> [KVCache] {
        try model.newCache(parameters: nil)
    }

    /// Run the stage. A first stage takes token ids `[B, L]` (int32); any other stage
    /// takes the previous stage's hidden state `[B, L, hidden]`. Returns the boundary
    /// hidden state `[B, L, hidden]`, or logits `[B, L, vocab]` on the last stage,
    /// evaluated together with this stage's KV caches.
    func forward(_ input: MLXArray, cache: [KVCache]) throws -> MLXArray {
        if let capture {
            refreshCaptureLayerCache(cache)
            _ = model(input, cache: cache)
            guard let hidden = capture.take() else { throw PipelineStageError.missingCapture }
            eval([hidden] + cache.prefix(realLayerCount).flatMap { $0.innerState() })
            return hidden
        }
        let logits = model(input, cache: cache)
        eval([logits] + cache.flatMap { $0.innerState() })
        return logits
    }

    /// Extend this stage's KV with `input` without producing its output. On the last
    /// stage only the caches are evaluated, so a fill-only prefill chunk never runs
    /// the final norm or the LM head over its tokens.
    func fill(_ input: MLXArray, cache: [KVCache]) throws {
        guard capture == nil else {
            _ = try forward(input, cache: cache)
            return
        }
        _ = model(input, cache: cache)
        eval(cache.flatMap { $0.innerState() })
    }

    /// The capture layer's attention is built but never evaluated. Its cache must still
    /// agree in length with the real caches (shapes are checked when ops are built), and
    /// it must not chain lazy updates across steps, so it is re-seeded each step with
    /// unevaluated zeros shaped like the first real layer's cache.
    private func refreshCaptureLayerCache(_ cache: [KVCache]) {
        guard let extra = cache.last as? KVCacheSimple, cache.count == realLayerCount + 1 else { return }
        // Before the first step every cache is empty and the capture cache is still fresh.
        let state = cache[0].state
        guard state.count == 2 else { return }
        extra.state = [MLXArray.zeros(state[0].shape, dtype: state[0].dtype),
                       MLXArray.zeros(state[1].shape, dtype: state[1].dtype)]
    }

    // MARK: - Config and weights

    /// Rewrite `config.json` for a stage: layer count, per-layer lists, per-layer
    /// quantization keys, and DeepSeek's dense-prefix boundary all move with the
    /// `a..<b` -> `0..<n` renumbering.
    static func stageConfig(_ config: [String: Any], plan: PipelineStagePlan, builtLayers: Int) throws -> [String: Any] {
        var stage = config
        let total = plan.totalLayers
        stage["num_hidden_layers"] = builtLayers
        for (key, value) in config {
            guard let list = value as? [Any], list.count == total else { continue }
            var sliced = Array(list[plan.layers])
            if builtLayers > sliced.count, let last = sliced.last { sliced.append(last) }
            stage[key] = sliced
        }
        if let dense = config["first_k_dense_replace"] as? Int {
            stage["first_k_dense_replace"] = max(0, dense - plan.layers.lowerBound)
        }
        if let freq = config["moe_layer_freq"] as? Int, freq > 1 {
            // Renumbering shifts `layer % freq`; only a range aligned to the frequency keeps it.
            guard plan.layers.lowerBound % freq == 0 else {
                throw PipelineStageError.invalidConfig("moe_layer_freq \(freq) needs a stage start aligned to it")
            }
        }
        for quantKey in ["quantization", "quantization_config"] {
            guard let quant = config[quantKey] as? [String: Any] else { continue }
            var rewritten = [String: Any]()
            for (key, value) in quant {
                if let layerKey = renameLayerKey(key, plan: plan) {
                    if let renamed = layerKey { rewritten[renamed] = value }
                } else {
                    rewritten[key] = value
                }
            }
            stage[quantKey] = rewritten
        }
        return stage
    }

    /// `nil` when `key` names no layer; `.some(nil)` when it names a layer outside
    /// the stage; `.some(renamed)` otherwise.
    static func renameLayerKey(_ key: String, plan: PipelineStagePlan) -> String?? {
        let prefix = "model.layers."
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        let digits = rest.prefix(while: \.isNumber)
        guard let index = Int(digits) else { return nil }
        guard plan.layers.contains(index) else { return .some(nil) }
        return .some(prefix + String(index - plan.layers.lowerBound) + rest.dropFirst(digits.count))
    }

    /// Load only the tensors this stage owns. MLX's safetensors loader is lazy, so
    /// tensors filtered out here are never read from disk.
    static func loadStageWeights(directory: URL, plan: PipelineStagePlan) throws -> [String: MLXArray] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw PipelineStageError.noWeights(directory) }
        var all = [String: MLXArray]()
        for file in files {
            all.merge(try loadArrays(url: file)) { _, new in new }
        }
        let hasHead = all.keys.contains { $0.hasPrefix("lm_head.") }
        var weights = [String: MLXArray]()
        for (key, value) in all {
            if let layerKey = renameLayerKey(key, plan: plan) {
                if let renamed = layerKey { weights[renamed] = value }
            } else if key.hasPrefix("model.embed_tokens.") {
                if plan.isFirst || (plan.isLast && !hasHead) { weights[key] = value }
            } else if key.hasPrefix("lm_head.") || key.hasPrefix("model.norm.") {
                if plan.isLast { weights[key] = value }
            } else {
                weights[key] = value
            }
        }
        return weights
    }
}

/// Activation (de)serialization for the frame codec. The boundary tensor ships in the
/// model's own dtype so the receiving stage sees bit-identical input.
enum PipelineActivationCodec {
    static func encode(_ array: MLXArray) throws -> (dtype: ShardTensorDType, shape: [UInt32], payload: Data) {
        let dtype: ShardTensorDType
        switch array.dtype {
        case .bfloat16: dtype = .bfloat16
        case .float16: dtype = .float16
        case .float32: dtype = .float32
        default: throw PipelineStageError.unsupportedActivationDType(String(describing: array.dtype))
        }
        guard array.ndim == 3 else { throw PipelineStageError.activationShape(array.shape) }
        let data = array.asData(access: .copy)
        return (dtype, array.shape.map { UInt32($0) }, data.data)
    }

    static func decode(dtype: ShardTensorDType, shape: [UInt32], payload: Data) throws -> MLXArray {
        let mlxType: DType
        switch dtype {
        case .bfloat16: mlxType = .bfloat16
        case .float16: mlxType = .float16
        case .float32: mlxType = .float32
        case .none, .int32: throw PipelineStageError.unsupportedActivationDType(String(describing: dtype))
        }
        guard shape.count == 3 else { throw PipelineStageError.activationShape(shape.map { Int($0) }) }
        return MLXArray(payload, shape.map { Int($0) }, dtype: mlxType)
    }
}

/// Last-stage sampling: greedy at temperature 0, otherwise a categorical draw from
/// the temperature-scaled distribution (MLX's global seeded generator).
/// One request's sampler on the last stage. Greedy at temperature 0; otherwise the
/// stock top-p sampler with its own random state, so concurrent requests do not
/// share a stream and a seeded request is reproducible.
final class PipelineStageSampler {
    private let sampler: TopPSampler?

    init(_ control: ShardRequestControl) {
        sampler = control.temperature > 0
            ? TopPSampler(temperature: control.temperature, topP: control.topP, seed: control.seed)
            : nil
    }

    func sample(logits: MLXArray) -> Int {
        let last = logits[0..., -1, 0...]
        guard let sampler else { return argMax(last, axis: -1).item(Int.self) }
        return sampler.sample(logits: last).item(Int.self)
    }
}

/// Top-k logit summary of the last position, the same on the last stage and the
/// reference so teacher-forced parity compares like with like.
enum PipelineLogitSummarizer {
    static func summarize(logits: MLXArray, topK: Int) -> ShardLogitSummary {
        let row = logits[0, -1].asType(.float32)
        let logSumExp = row.logSumExp(axis: -1)
        let order = argSort(-row, axis: -1)[0 ..< min(topK, row.dim(0))]
        let logprobs = row.take(order, axis: 0) - logSumExp
        eval(order, logprobs, logSumExp)
        return ShardLogitSummary(
            topTokens: order.asType(.int32).asArray(Int32.self),
            topLogprobs: logprobs.asArray(Float.self),
            logSumExp: logSumExp.item(Float.self))
    }
}
