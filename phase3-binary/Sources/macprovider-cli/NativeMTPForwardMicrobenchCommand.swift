#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Lab control C3 for issue #1770: raw target-model forward cost on dense
/// (non-paged) caches for `[B, w]` inputs, with no scheduler or paged bridge.
/// Prints one JSON line per configuration.
struct NativeMTPForwardMicrobenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "native-mtp-forward-microbench",
        abstract: "Lab-only raw target forward timing for [B,1] vs [B,2] inputs.",
        shouldDisplay: false
    )

    @Option(name: .customLong("model-dir"), help: "Target model snapshot directory.")
    var modelDir: String

    @Option(name: .customLong("batches"), help: "Comma-separated batch sizes.")
    var batches: String = "1,2,4,8,16"

    @Option(name: .customLong("widths"), help: "Comma-separated input widths per row.")
    var widths: String = "1,2"

    @Option(name: .customLong("variants"), help: "Comma-separated: plain, emit, emitckpt, compiled.")
    var variants: String = "plain,emitckpt"

    @Option(name: .customLong("prompt-tokens"), help: "Prefill tokens per row before timing.")
    var promptTokens: Int = 384

    @Option(name: .customLong("warmup"))
    var warmup: Int = 5

    @Option(name: .customLong("iters"))
    var iters: Int = 30

    @Option(name: .customLong("smallm-qmv"), help: "Lab: route QuantizedLinear M>=2 through SmallMQMV (off, auto, or a config).")
    var smallmQMV: String = "off"

    @Option(name: .customLong("moe-smallm"), help: "Lab: A3B MoE block path (off, stock, grouped).")
    var moeSmallM: String = "off"

    @Option(name: .customLong("ablate"), help: "Lab cost split: comma list of attnproj, router, routed, shared, lmhead.")
    var ablate: String = "none"

    @Option(name: .customLong("gate-up-tiling"), help: "Lab: grouped gate/up tiling r-lpr-ks-nt-xs.")
    var gateUpTiling: String?

    @Option(name: .customLong("token-source"), help: "Lab: random token ids (default) or text (consecutive real-text tokens per row).")
    var tokenSource: String = "random"

    @Option(name: .customLong("moe-mm"), help: "Lab: grouped max tokens per expert per weight pass.")
    var moeMM: Int?

    @Flag(name: .customLong("moe-inline-bucket"), help: "Lab: grouped kernels find expert pairs themselves (no bucket launch).")
    var moeInlineBucket = false

    @Option(name: .customLong("down-tiling"), help: "Lab: grouped down tiling r-lpr-ks-nt-xs.")
    var downTiling: String?

    func run() async throws {
        try MoESmallM.applyTilingOverrides(gateUp: gateUpTiling, down: downTiling)
        if let moeMM { MoESmallM.maxTokensPerPass = moeMM }
        MoESmallM.inlineBucket = moeInlineBucket
        let batchSizes = batches.split(separator: ",").compactMap { Int($0) }
        let widthValues = widths.split(separator: ",").compactMap { Int($0) }
        let variantValues = variants.split(separator: ",").map(String.init)
        guard !batchSizes.isEmpty, !widthValues.isEmpty, promptTokens > 0, iters > 0 else {
            throw ValidationError("invalid microbench arguments")
        }
        await Qwen35TextMTPRegistration.register()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: URL(fileURLWithPath: modelDir, isDirectory: true),
            using: #huggingFaceTokenizerLoader()
        )
        let moeNotes = try await MLXSmallMProbeCommand.installMoELab(moe: moeSmallM, ablate: ablate, container: container)
        let routed = try await MLXSmallMProbeCommand.installSmallMRouting(smallmQMV, container: container)
        let smallmLabel = smallmQMV
        let moeLabel = moeSmallM
        let tokenLabel = tokenSource
        var textPool: [Int32]?
        if tokenSource == "text" {
            textPool = await container.perform { context in
                let text = Array(repeating: MLXSmallMProbeCommand.moePrompts.joined(separator: " "), count: 64)
                    .joined(separator: "\n")
                return context.tokenizer.encode(text: text).map { Int32($0) }
            }
        }
        let pool = textPool
        let ablateLabel = ablate
        let promptTokens = self.promptTokens
        let warmup = self.warmup
        let iters = self.iters
        let modelName = URL(fileURLWithPath: modelDir).deletingLastPathComponent().lastPathComponent
        for variant in variantValues {
            for width in widthValues {
                for batch in batchSizes {
                    let line = try await container.perform { context -> String in
                        try Self.measure(
                            model: context.model,
                            modelName: modelName,
                            variant: variant,
                            batch: batch,
                            width: width,
                            promptTokens: promptTokens,
                            warmup: warmup,
                            iters: iters,
                            pool: pool
                        )
                    }
                    print(line.dropLast() + ",\"smallm_qmv\":\"\(smallmLabel)\",\"smallm_routed_layers\":\(routed)"
                        + ",\"moe_smallm\":\"\(moeLabel)\",\"moe_tiling\":\"\(MoESmallM.gateUpTiling)/\(MoESmallM.downTiling)/mm\(MoESmallM.maxTokensPerPass)\(MoESmallM.inlineBucket ? "/ib" : "")\",\"token_source\":\"\(tokenLabel)\",\"ablate\":\"\(ablateLabel)\",\"moe_notes\":\"\(moeNotes)\"}")
                    fflush(stdout)
                }
            }
        }
    }

    private static func measure(
        model: any LanguageModel,
        modelName: String,
        variant: String,
        batch: Int,
        width: Int,
        promptTokens: Int,
        warmup: Int,
        iters: Int,
        pool: [Int32]? = nil
    ) throws -> String {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(batch * 31 + width)
        // Text mode: row r reads consecutive pool tokens from its own cursor.
        var cursors = (0 ..< batch).map { $0 * 977 }
        func nextTokens(_ count: Int) -> [Int32] {
            if let pool {
                let per = count / batch
                return (0 ..< batch).flatMap { r -> [Int32] in
                    let start = cursors[r]
                    cursors[r] += per
                    return (0 ..< per).map { pool[(start + $0) % pool.count] }
                }
            }
            return (0 ..< count).map { _ in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int32(1_000 + Int((seed >> 33) % 40_000))
            }
        }
        let cache = try model.newCache(parameters: nil)
        let prompt = MLXArray(nextTokens(batch * promptTokens), [batch, promptTokens])
        let prefill = model(LMInput.Text(tokens: prompt), cache: cache, state: nil)
        eval(prefill.logits)
        eval(cache)
        Stream().synchronize()

        let compiledStep = variant == "compiled"
            ? CompiledDecodeStep(model: model, cache: cache, enabled: true)
            : nil
        var graphMS: [Double] = []
        var evalMS: [Double] = []
        var hostMS: [Double] = []
        for iteration in 0 ..< (warmup + iters) {
            let tokens = MLXArray(nextTokens(batch * width), [batch, width])
            eval(tokens)
            Stream().synchronize()
            let t0 = DispatchTime.now().uptimeNanoseconds
            var outputs: [MLXArray]
            let logits: MLXArray
            if let compiledStep {
                logits = compiledStep.step(tokens)
                outputs = [logits]
            } else {
                var state: LMOutput.State?
                if variant == "emit" || variant == "emitckpt" {
                    var value = LMOutput.State()
                    value[mtpEmitFlagKey] = true
                    if variant == "emitckpt", width > 1 {
                        value[mtpCacheCheckpointIndexKey] = 1
                    }
                    state = value
                }
                let output = model(LMInput.Text(tokens: tokens), cache: cache, state: state)
                logits = output.logits
                outputs = [logits]
                if let hidden = output.state?[mtpLastHiddenStatesKey] {
                    outputs.append(hidden)
                }
            }
            outputs.append(contentsOf: cache.flatMap(\.state))
            let t1 = DispatchTime.now().uptimeNanoseconds
            eval(outputs)
            Stream().synchronize()
            let t2 = DispatchTime.now().uptimeNanoseconds
            _ = argMax(logits.reshaped([batch * width, -1]), axis: -1).asArray(Int32.self)
            let t3 = DispatchTime.now().uptimeNanoseconds
            if iteration >= warmup {
                graphMS.append(Double(t1 - t0) / 1e6)
                evalMS.append(Double(t2 - t1) / 1e6)
                hostMS.append(Double(t3 - t2) / 1e6)
            }
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func quantile(_ values: [Double], _ q: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
        }
        let record: [String: Any] = [
            "schema": "macprovider.native-mtp-forward-microbench.v1",
            "model": modelName,
            "variant": variant,
            "batch": batch,
            "width": width,
            "tokens_per_forward": batch * width,
            "prompt_tokens": promptTokens,
            "iters": iters,
            "graph_build_ms_p50": median(graphMS),
            "gpu_eval_ms_p50": median(evalMS),
            "gpu_eval_ms_p10": quantile(evalMS, 0.1),
            "gpu_eval_ms_p90": quantile(evalMS, 0.9),
            "argmax_host_ms_p50": median(hostMS),
            "total_ms_p50": median(zip(zip(graphMS, evalMS), hostMS).map { $0.0 + $0.1 + $1 }),
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
