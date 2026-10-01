#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import Tokenizers

/// SmallMQMV prototype modes of `mlx-smallm-probe` (#1770):
/// - `kcheck`: synthetic weights; error vs an fp32 dequantized reference, and
///   bit identity vs MLX per-row qmv (M=1 calls) and batched quantizedMM.
/// - `kbench`: DRAM-streaming timing vs MLX quantizedMM per shape and M.
/// - `kreal`: real model weights (one full-attention layer, one linear-attention
///   layer, lm_head) with real final hidden states; lm_head argmax flips.
extension MLXSmallMProbeCommand {
    func parsedConfigs() throws -> [SmallMQMV.Config] {
        try configs.split(separator: ",").map { item in
            guard let config = SmallMQMV.Config.parse(String(item)) else {
                throw ValidationError("bad config \(item)")
            }
            return config
        }
    }

    func parsedMs() -> [Int] {
        if let ms { return ms.split(separator: ",").compactMap { Int($0) } }
        return Array(1 ... maxM)
    }

    /// Installs SmallMQuantizedLinear routing: "off", "auto", or a fixed config.
    static func installSmallMRouting(_ spec: String, container: ModelContainer) async throws -> Int {
        guard spec != "off" else { return 0 }
        if spec != "auto" {
            guard let config = SmallMQMV.Config.parse(spec) else { throw ValidationError("bad --smallm-qmv \(spec)") }
            SmallMQuantizedLinear.fixedConfig = config
        }
        return await container.perform { context in
            SmallMQuantizedLinear.install(in: context.model)
        }
    }

    private static func maxAbs(_ a: MLXArray, _ b: MLXArray) -> Float {
        abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
    }

    private static func errorRecord(
        ours: MLXArray, exact: MLXArray, perRow: MLXArray, batched: MLXArray
    ) -> [String: Any] {
        let scale = abs(exact).max().item(Float.self)
        let errOurs = maxAbs(ours, exact)
        let errBatched = maxAbs(batched, exact)
        let errPerRow = maxAbs(perRow, exact)
        let mismatchPerRow = (ours .!= perRow).asType(.float32).mean().item(Float.self)
        let mismatchBatched = (ours .!= batched).asType(.float32).mean().item(Float.self)
        let batchedVsPerRow = (batched .!= perRow).asType(.float32).mean().item(Float.self)
        return [
            "max_abs_exact": scale,
            "ours_max_abs_err": errOurs, "ours_max_rel_err": errOurs / max(scale, 1e-30),
            "mlx_batched_max_abs_err": errBatched, "mlx_qmv_rows_max_abs_err": errPerRow,
            "ours_vs_qmv_rows_mismatch_frac": mismatchPerRow,
            "ours_vs_mlx_batched_mismatch_frac": mismatchBatched,
            "mlx_batched_vs_qmv_rows_mismatch_frac": batchedVsPerRow,
            "ours_bit_identical_qmv_rows": mismatchPerRow == 0,
        ]
    }

    private static func references(
        x: MLXArray, wq: MLXArray, scales: MLXArray, biases: MLXArray, wf: MLXArray
    ) -> (exact: MLXArray, perRow: MLXArray, batched: MLXArray) {
        let m = x.dim(0)
        let exact = matmul(x.asType(.float32), wf.transposed())
        let perRow = concatenated(
            (0 ..< m).map { i in
                quantizedMM(x[i ..< i + 1], wq, scales: scales, biases: biases, transpose: true, groupSize: 64, bits: 4)
            }, axis: 0)
        let batched = quantizedMM(x, wq, scales: scales, biases: biases, transpose: true, groupSize: 64, bits: 4)
        eval(exact, perRow, batched)
        return (exact, perRow, batched)
    }

    func runKernelCheck() throws {
        let configs = try parsedConfigs()
        for (n, k) in try parsedShapes() {
            let w = MLXRandom.normal([n, k], key: MLXRandom.key(7)).asType(.bfloat16) * 0.02
            let q = quantized(w, groupSize: 64, bits: 4)
            let wf = dequantized(q.wq, scales: q.scales, biases: q.biases!, groupSize: 64, bits: 4).asType(.float32)
            eval(q.wq, q.scales, q.biases!, wf)
            for m in parsedMs() {
                let x = MLXRandom.normal([m, k], key: MLXRandom.key(UInt64(100 + m))).asType(.bfloat16)
                let ref = Self.references(x: x, wq: q.wq, scales: q.scales, biases: q.biases!, wf: wf)
                for config in configs where SmallMQMV.supports(m: m, n: n, k: k, config: config, dtype: .bfloat16) {
                    let ours = SmallMQMV.matmul(x, w: q.wq, scales: q.scales, biases: q.biases!, config: config)
                    eval(ours)
                    var record = Self.errorRecord(ours: ours, exact: ref.exact, perRow: ref.perRow, batched: ref.batched)
                    record["schema"] = "macprovider.mlx-smallm-probe.kcheck.v1"
                    record["n"] = n
                    record["k"] = k
                    record["m"] = m
                    record["config"] = config.description
                    try Self.emit(record)
                }
            }
        }
    }

    func runKernelBench() throws {
        let configs = try parsedConfigs()
        for (n, k) in try parsedShapes() {
            let packedBytes = n * k / 2 + 2 * (n * k / 64) * 2
            let copies = max(4, (1 << 30) / packedBytes + 1)
            var weights: [(MLXArray, MLXArray, MLXArray)] = []
            for c in 0 ..< copies {
                let w = MLXRandom.normal([n, k], key: MLXRandom.key(UInt64(c + 1))).asType(.bfloat16) * 0.02
                let q = quantized(w, groupSize: 64, bits: 4)
                eval(q.wq, q.scales, q.biases!)
                weights.append((q.wq, q.scales, q.biases!))
            }
            Stream().synchronize()
            for m in parsedMs() {
                let x = MLXRandom.normal([m, k], key: MLXRandom.key(UInt64(1000 + m))).asType(.bfloat16)
                eval(x)
                var record: [String: Any] = [
                    "schema": "macprovider.mlx-smallm-probe.kbench.v1",
                    "n": n, "k": k, "m": m, "copies": copies, "serial": serial,
                ]
                let candidates: [(String, (MLXArray, MLXArray, MLXArray) -> MLXArray)] =
                    [("mlx", { w, s, b in
                        quantizedMM(x, w, scales: s, biases: b, transpose: true, groupSize: 64, bits: 4)
                    })]
                    + configs.filter { SmallMQMV.supports(m: m, n: n, k: k, config: $0, dtype: .bfloat16) }
                    .map { config in
                        (config.description, { w, s, b in SmallMQMV.matmul(x, w: w, scales: s, biases: b, config: config) })
                    }
                for (label, fn) in candidates {
                    var samples: [Double] = []
                    if serial {
                        // One matmul per eval: per-kernel latency incl. tail
                        // effects, as in a model forward (dependent matmuls).
                        for iteration in 0 ..< (warmup + iters) {
                            for (w, s, b) in weights {
                                let out = fn(w, s, b)
                                let t0 = DispatchTime.now().uptimeNanoseconds
                                eval(out)
                                Stream().synchronize()
                                let t1 = DispatchTime.now().uptimeNanoseconds
                                if iteration >= warmup { samples.append(Double(t1 - t0) / 1e3) }
                            }
                        }
                        let sorted = samples.sorted()
                        record["us_\(label)"] = sorted[sorted.count / 2]
                        record["us_min_\(label)"] = sorted.first ?? 0
                        continue
                    }
                    for iteration in 0 ..< (warmup + iters) {
                        let outs = weights.map { w, s, b in fn(w, s, b) }
                        Stream().synchronize()
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        eval(outs)
                        Stream().synchronize()
                        let t1 = DispatchTime.now().uptimeNanoseconds
                        if iteration >= warmup {
                            samples.append(Double(t1 - t0) / 1e3 / Double(copies))
                        }
                    }
                    let sorted = samples.sorted()
                    record["us_\(label)"] = sorted[sorted.count / 2]
                    record["us_min_\(label)"] = sorted.first ?? 0
                }
                try Self.emit(record)
            }
            weights.removeAll()
            Memory.clearCache()
        }
    }

    func runKernelReal() async throws {
        guard let modelDir else { throw ValidationError("--model-dir required") }
        let configs = try parsedConfigs()
        let msList = parsedMs()
        await Qwen35TextMTPRegistration.register()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: URL(fileURLWithPath: modelDir, isDirectory: true),
            using: #huggingFaceTokenizerLoader()
        )
        let modelName = URL(fileURLWithPath: modelDir).deletingLastPathComponent().lastPathComponent
        let texts = [
            "Explain how a heat pump moves heat from a cold place to a warm place, step by step.",
            "Write a short Python function that returns the n-th Fibonacci number iteratively.",
            "List three differences between TCP and UDP and when you would choose each one.",
            "Summarize the plot of a story about a lighthouse keeper who finds a message in a bottle.",
            "What are the main causes of inflation, and how do central banks respond to it?",
            "Translate into French: The weather is nice today, so we will walk to the market.",
            "Describe the water cycle for a ten-year-old in a few short sentences.",
            "Give me a checklist for reviewing a pull request that changes a database schema.",
        ]
        let lines = try await container.perform { context -> [String] in
            // Real final hidden states (lm_head inputs) for every prompt position.
            var hiddenRows: [MLXArray] = []
            for text in texts {
                let ids = context.tokenizer.encode(text: text).map { Int32($0) }
                let cache = try context.model.newCache(parameters: nil)
                var state = LMOutput.State()
                state[mtpEmitFlagKey] = true
                let out = context.model(
                    LMInput.Text(tokens: MLXArray(ids, [1, ids.count])), cache: cache, state: state)
                guard let hidden = out.state?[mtpLastHiddenStatesKey] else {
                    throw ValidationError("model did not emit hidden states")
                }
                hiddenRows.append(hidden.reshaped([-1, hidden.dim(-1)]))
            }
            let hidden = concatenated(hiddenRows, axis: 0)
            eval(hidden)
            let hiddenSize = hidden.dim(1)
            var out: [String] = []
            func record(_ r: [String: Any]) throws {
                let data = try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys])
                out.append(String(decoding: data, as: UTF8.self))
            }
            let layers = context.model.leafModules().flattened().compactMap { key, module -> (String, QuantizedLinear)? in
                guard let q = module as? QuantizedLinear, q.bits == 4, q.groupSize == 64, q.biases != nil,
                      !key.contains("mtp")
                else { return nil }
                let wanted = key.contains("layers.3.") || key.contains("layers.4.") || key.hasSuffix("lm_head")
                return wanted ? (key, q) : nil
            }
            for (key, layer) in layers {
                let n = layer.weight.dim(0)
                let k = layer.weight.dim(1) * 8
                let wf = dequantized(
                    layer.weight, scales: layer.scales, biases: layer.biases!, groupSize: 64, bits: 4
                ).asType(.float32)
                eval(wf)
                for m in msList {
                    let x: MLXArray = k == hiddenSize
                        ? hidden[0 ..< m]
                        : MLXRandom.normal([m, k], key: MLXRandom.key(UInt64(m))).asType(.bfloat16)
                    let ref = Self.references(
                        x: x, wq: layer.weight, scales: layer.scales, biases: layer.biases!, wf: wf)
                    for config in configs where SmallMQMV.supports(m: m, n: n, k: k, config: config, dtype: x.dtype) {
                        let ours = SmallMQMV.matmul(
                            x, w: layer.weight, scales: layer.scales, biases: layer.biases!, config: config)
                        eval(ours)
                        var r = Self.errorRecord(ours: ours, exact: ref.exact, perRow: ref.perRow, batched: ref.batched)
                        r["schema"] = "macprovider.mlx-smallm-probe.kreal.v1"
                        r["model"] = modelName
                        r["layer"] = key
                        r["n"] = n
                        r["k"] = k
                        r["m"] = m
                        r["x_source"] = k == hiddenSize ? "final_hidden" : "random_normal"
                        r["config"] = config.description
                        try record(r)
                    }
                }
                guard key.hasSuffix("lm_head") else { continue }
                // Argmax flips over all real hidden rows, chunked by M.
                let total = hidden.dim(0)
                let refArg = argMax(
                    concatenated(
                        (0 ..< total).map { i in
                            quantizedMM(hidden[i ..< i + 1], layer.weight, scales: layer.scales,
                                        biases: layer.biases!, transpose: true, groupSize: 64, bits: 4)
                        }, axis: 0), axis: -1)
                let exactArg = argMax(matmul(hidden.asType(.float32), wf.transposed()), axis: -1)
                eval(refArg, exactArg)
                for m in msList where m >= 2 {
                    let usable = (total / m) * m
                    var flipsBatched = 0
                    var flipsExactQmv = 0
                    var flipsOurs: [String: Int] = [:]
                    var flipsOursExact: [String: Int] = [:]
                    for start in stride(from: 0, to: usable, by: m) {
                        let xs = hidden[start ..< start + m]
                        let r = refArg[start ..< start + m]
                        let e = exactArg[start ..< start + m]
                        let b = argMax(quantizedMM(xs, layer.weight, scales: layer.scales, biases: layer.biases!,
                                                   transpose: true, groupSize: 64, bits: 4), axis: -1)
                        flipsBatched += (b .!= r).asType(.int32).sum().item(Int.self)
                        flipsExactQmv += (e .!= r).asType(.int32).sum().item(Int.self)
                        for config in configs where SmallMQMV.supports(m: m, n: n, k: k, config: config, dtype: xs.dtype) {
                            let o = argMax(SmallMQMV.matmul(xs, w: layer.weight, scales: layer.scales,
                                                            biases: layer.biases!, config: config), axis: -1)
                            flipsOurs[config.description, default: 0] += (o .!= r).asType(.int32).sum().item(Int.self)
                            flipsOursExact[config.description, default: 0] += (o .!= e).asType(.int32).sum().item(Int.self)
                        }
                    }
                    try record([
                        "schema": "macprovider.mlx-smallm-probe.kreal-argmax.v1",
                        "model": modelName, "m": m, "rows": usable,
                        "mlx_batched_flips_vs_qmv_rows": flipsBatched,
                        "fp32_exact_flips_vs_qmv_rows": flipsExactQmv,
                        "ours_flips_vs_qmv_rows": flipsOurs,
                        "ours_flips_vs_fp32_exact": flipsOursExact,
                    ])
                }
            }
            return out
        }
        for line in lines {
            print(line)
        }
        fflush(stdout)
    }
}
#endif
