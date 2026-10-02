#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import Tokenizers

/// Lab probe for issue #1770 follow-up: fused small-T MoE kernels for
/// Qwen3.6-35B-A3B (mlx-swift-lm fork `perf/a3b-fused-moe`). Prints one JSON
/// line per measurement.
///
/// Modes:
/// - `layer`: per-layer MoE output error vs an fp32 reference on real
///   hidden states, stock vs fused, plus fused batch invariance.
/// - `forward`: `[B, w]` forward host graph-build ms and GPU eval ms per
///   fused mode, dense caches.
/// - `flips`: teacher-forced argmax flips vs the stock `[B, 1]` greedy path.
/// - `greedy`: free-running greedy decode parity, fused vs stock.
/// - `moe`: per-layer MoE timing chain over real inputs; with `--stop-afters`
///   it also times the router-only and router+gate/up prefixes (stock and fused)
///   and reports gate/up GB/s over the distinct-expert bytes.
/// - `concurrency`: fused calls built without an eval between them (same block
///   and different blocks, one stream and two streams) must be bit-equal to the
///   same calls evaluated one at a time.
struct A3BFusedMoEBenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "a3b-fused-moe-bench",
        abstract: "Lab-only fused MoE kernel probe for Qwen3.5/3.6 MoE.",
        shouldDisplay: false
    )

    @Option(name: .customLong("model-dir")) var modelDir: String
    @Option(name: .customLong("modes")) var modes: String = "layer,forward,flips,greedy"
    @Option(name: .customLong("batches")) var batches: String = "1,2,4,8"
    @Option(name: .customLong("widths")) var widths: String = "1,2"
    @Option(name: .customLong("fused-modes")) var fusedModes: String = "off,router,full"
    @Option(name: .customLong("layer-tokens")) var layerTokens: String = "1,2,4,8,16"
    @Option(name: .customLong("prompt-tokens")) var promptTokens: Int = 384
    @Option(name: .customLong("warmup")) var warmup: Int = 5
    @Option(name: .customLong("iters")) var iters: Int = 30
    @Option(name: .customLong("decode-tokens")) var decodeTokens: Int = 64
    @Option(name: .customLong("flip-batches")) var flipBatches: String = "1,4,8"
    @Option(name: .customLong("gate-up-rows")) var gateUpRows: Int?
    @Option(name: .customLong("down-rows")) var downRows: Int?
    @Option(name: .customLong("down-sgs")) var downSGs: Int?
    @Option(name: .customLong("kernel-version")) var kernelVersion: Int?
    @Option(name: .customLong("router-rows")) var routerRows: Int?
    @Option(name: .customLong("gate-up-tokens")) var gateUpTokens: Int?
    @Option(name: .customLong("down-tpb")) var downTPB: Int?
    @Option(name: .customLong("stop-after")) var stopAfter: Int?
    @Option(name: .customLong("stop-afters")) var stopAfters: String = "0"
    @Option(name: .customLong("gate-up-v3-rows")) var gateUpV3Rows: Int?
    @Option(name: .customLong("gate-up-v3-sgs")) var gateUpV3SGs: Int?
    @Option(name: .customLong("gate-up-v3-chunk")) var gateUpV3Chunk: Int?
    @Option(name: .customLong("gate-up-v3-stage")) var gateUpV3Stage: Int?
    @Option(name: .customLong("max-t")) var maxT: Int?
    @Option(name: .customLong("concurrency-rounds")) var concurrencyRounds: Int = 4

    static let prompts: [String] = [
        "Explain how a hash map handles collisions, compare chaining with open addressing, and give the time complexity of insert and lookup in the average and worst case.",
        "Write a Python function that parses an ISO 8601 timestamp with a timezone offset and returns the number of seconds since the Unix epoch, with tests.",
        "Summarize the causes of the French Revolution in five bullet points, then explain which one historians debate the most and why.",
        "A train leaves the station at 9:40 and travels 210 kilometers at an average speed of 84 kilometers per hour. When does it arrive? Show the steps.",
        "Translate the following into German and keep the tone formal: We regret to inform you that the shipment has been delayed until next Tuesday.",
        "Describe the difference between TCP congestion control algorithms Reno, Cubic and BBR, and when an operator would pick each one in production.",
        "Write a short story opening, three paragraphs, about a lighthouse keeper who discovers that the light has been signalling to someone across the sea.",
        "List the steps to debug a memory leak in a long-running Swift server process on macOS, including which Instruments templates to use.",
    ]

    func run() async throws {
        if let gateUpRows { Qwen35FusedMoE.gateUpRows = gateUpRows }
        if let downRows { Qwen35FusedMoE.downRows = downRows }
        if let downSGs { Qwen35FusedMoE.downSimdgroups = downSGs }
        if let kernelVersion { Qwen35FusedMoE.kernelVersion = kernelVersion }
        if let routerRows { Qwen35FusedMoE.routerRows = routerRows }
        if let gateUpTokens { Qwen35FusedMoE.gateUpTokens = gateUpTokens }
        if let downTPB { Qwen35FusedMoE.downTokensPerBlock = downTPB }
        if let stopAfter { Qwen35FusedMoE.labStopAfter = stopAfter }
        if let gateUpV3Rows { Qwen35FusedMoE.gateUpV3Rows = gateUpV3Rows }
        if let gateUpV3SGs { Qwen35FusedMoE.gateUpV3Simdgroups = gateUpV3SGs }
        if let gateUpV3Chunk { Qwen35FusedMoE.gateUpV3Chunk = gateUpV3Chunk }
        if let gateUpV3Stage { Qwen35FusedMoE.gateUpV3Stage = gateUpV3Stage != 0 }
        if let maxT { Qwen35FusedMoE.maxTokens = maxT }
        await Qwen35TextMTPRegistration.register()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: URL(fileURLWithPath: modelDir, isDirectory: true),
            using: #huggingFaceTokenizerLoader()
        )
        let ints: (String) -> [Int] = { $0.split(separator: ",").compactMap { Int($0) } }
        let fused = fusedModes.split(separator: ",").compactMap {
            Qwen35FusedMoE.Mode(rawValue: String($0))
        }
        let pool: [Int32] = await container.perform { context in
            let text = Array(repeating: Self.prompts.joined(separator: " "), count: 64)
                .joined(separator: "\n")
            return context.tokenizer.encode(text: text).map { Int32($0) }
        }
        let promptIds: [[Int32]] = await container.perform { context in
            Self.prompts.map { p in context.tokenizer.encode(text: p).map { Int32($0) } }
        }
        let (batchValues, widthValues, layerT, flipB) = (
            ints(batches), ints(widths), ints(layerTokens), ints(flipBatches)
        )
        let (warmup, iters, promptTokens, decodeTokens, rounds) = (
            warmup, iters, promptTokens, decodeTokens, concurrencyRounds
        )
        let stops = ints(stopAfters)
        for mode in modes.split(separator: ",").map(String.init) {
            switch mode {
            case "layer":
                try await container.perform { context in
                    try Self.layerCheck(model: context.model, pool: pool, tokenCounts: layerT)
                }
            case "moe":
                try await container.perform { context in
                    try Self.moeChain(
                        model: context.model, pool: pool, tokenCounts: layerT, modes: fused,
                        stops: stops, warmup: warmup, iters: iters)
                }
            case "concurrency":
                try await container.perform { context in
                    try Self.concurrency(
                        model: context.model, pool: pool, tokenCounts: layerT, rounds: rounds)
                }
            case "forward":
                for f in fused {
                    for width in widthValues {
                        for batch in batchValues {
                            let line = try await container.perform { context in
                                try Self.forward(
                                    model: context.model, fused: f, batch: batch, width: width,
                                    promptTokens: promptTokens, warmup: warmup, iters: iters,
                                    pool: pool)
                            }
                            print(line)
                            fflush(stdout)
                        }
                    }
                }
            case "flips":
                for b in flipB {
                    try await container.perform { context in
                        try Self.flips(
                            model: context.model, prompts: promptIds, batch: b,
                            widths: widthValues, decodeTokens: decodeTokens)
                    }
                }
            case "greedy":
                try await container.perform { context in
                    try Self.greedy(
                        model: context.model, prompts: promptIds, decodeTokens: decodeTokens)
                }
            default:
                throw ValidationError("unknown mode \(mode)")
            }
        }
        Qwen35FusedMoE.mode = .off
    }

    static func emit(_ record: [String: Any]) {
        var record = record
        for (k, v) in record { if let d = v as? Double, !d.isFinite { record[k] = "\(d)" } }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }

    // MARK: - layer

    private static func moeBlocks(_ model: any LanguageModel) -> [(Int, Module)] {
        guard let module = model as? Module else { return [] }
        var blocks: [(Int, Module)] = []
        for (key, m) in module.namedModules() where key.hasSuffix(".mlp") {
            guard Qwen35FusedMoE.labIsFusable(m), let range = key.range(of: "layers.") else {
                continue
            }
            let rest = key[range.upperBound...]
            if let idx = Int(rest.prefix { $0.isNumber }) { blocks.append((idx, m)) }
        }
        return blocks.sorted { $0.0 < $1.0 }
    }

    private static func dequant(_ p: [String: MLXArray], _ name: String, bits: Int) -> MLXArray {
        dequantized(
            p["\(name).weight"]!, scales: p["\(name).scales"]!, biases: p["\(name).biases"]!,
            groupSize: 64, bits: bits
        ).asType(.float32)
    }

    private static func dequantExperts(
        _ p: [String: MLXArray], _ name: String, _ experts: MLXArray
    ) -> MLXArray {
        dequantized(
            take(p["\(name).weight"]!, experts, axis: 0),
            scales: take(p["\(name).scales"]!, experts, axis: 0),
            biases: take(p["\(name).biases"]!, experts, axis: 0),
            groupSize: 64, bits: 4
        ).asType(.float32)
    }

    /// Stock router replica: 8-bit qmm (bf16 out), precise softmax, argPartition.
    private static func stockRouter(_ p: [String: MLXArray], _ x: MLXArray) -> MLXArray {
        var gates = quantizedMM(
            x, p["gate.weight"]!, scales: p["gate.scales"]!, biases: p["gate.biases"]!,
            transpose: true, groupSize: 64, bits: 8)
        gates = softmax(gates, axis: -1, precise: true)
        let kth = gates.dim(-1) - 8
        return argPartition(gates, kth: kth, axis: -1)[.ellipsis, kth...]
    }

    /// fp32 reference with fp32 routing. Returns (y [T, H], sorted indices [T, 8]).
    private static func reference(_ p: [String: MLXArray], _ x: MLXArray) -> (MLXArray, [[Int32]])
    {
        let xf = x.asType(.float32)
        let gw = dequant(p, "gate", bits: 8)
        let logits = matmul(xf, gw.T)
        let probs = softmax(logits, axis: -1)
        let order = argSort(-probs, axis: -1)[0..., ..<8]
        eval(order)
        let tokens = x.dim(0)
        var rows: [MLXArray] = []
        var sel: [[Int32]] = []
        let sgw = dequant(p, "shared_expert_gate", bits: 8)
        let shg = dequant(p, "shared_expert.gate_proj", bits: 4)
        let shu = dequant(p, "shared_expert.up_proj", bits: 4)
        let shd = dequant(p, "shared_expert.down_proj", bits: 4)
        for t in 0 ..< tokens {
            let xt = xf[t ..< (t + 1)]
            let idx = order[t]
            let pr = take(probs[t], idx)
            let sc = pr / pr.sum()
            let g = dequantExperts(p, "switch_mlp.gate_proj", idx)  // [8, I, H]
            let u = dequantExperts(p, "switch_mlp.up_proj", idx)
            let d = dequantExperts(p, "switch_mlp.down_proj", idx)  // [8, H, I]
            let xg = matmul(g, xt.T).squeezed(axis: -1)  // [8, I]
            let xu = matmul(u, xt.T).squeezed(axis: -1)
            let act = (xg * sigmoid(xg)) * xu
            let yk = matmul(d, expandedDimensions(act, axis: -1)).squeezed(axis: -1)  // [8, H]
            let routed = (yk * expandedDimensions(sc, axis: -1)).sum(axis: 0)
            let sg = matmul(shg, xt.T).squeezed(axis: -1)
            let su = matmul(shu, xt.T).squeezed(axis: -1)
            let sy = matmul(shd, expandedDimensions((sg * sigmoid(sg)) * su, axis: -1))
                .squeezed(axis: -1)
            let gate = sigmoid(matmul(sgw, xt.T).squeezed())
            rows.append(routed + gate * sy)
            sel.append(idx.asArray(Int32.self).sorted())
        }
        return (stacked(rows, axis: 0), sel)
    }

    private static func sortedRows(_ inds: MLXArray) -> [[Int32]] {
        let k = inds.dim(-1)
        let flat = inds.asType(.int32).reshaped([-1]).asArray(Int32.self)
        return stride(from: 0, to: flat.count, by: k).map { Array(flat[$0 ..< ($0 + k)]).sorted() }
    }

    static func layerCheck(model: any LanguageModel, pool: [Int32], tokenCounts: [Int]) throws {
        let maxT = tokenCounts.max() ?? 16
        var taps: [MLXArray] = []
        Qwen35FusedMoE.mode = .off
        Qwen35FusedMoE.inputTap = { taps.append($0) }
        let cache = model.newCache(parameters: nil)
        let ids = MLXArray(Array(pool.prefix(64 + maxT)), [1, 64 + maxT])
        let out = model(LMInput.Text(tokens: ids), cache: cache, state: nil)
        eval(out.logits)
        eval(taps)
        Qwen35FusedMoE.inputTap = nil
        let blocks = moeBlocks(model)
        guard taps.count == blocks.count, !blocks.isEmpty else {
            throw ValidationError("tap count \(taps.count) != blocks \(blocks.count)")
        }
        for tcount in tokenCounts {
            var relStock: [Double] = []
            var relFused: [Double] = []
            var relFusedVsStock: [Double] = []
            var maxAbsFusedVsStock: Double = 0
            var identical = 0
            var total = 0
            var selFusedVsStock = 0
            var selRefVsStock = 0
            var invarianceMismatchRows = 0
            var compared = 0
            for (li, (_, block)) in blocks.enumerated() {
                let h = taps[li].dim(-1)
                // Real hidden rows 64 ..< 64+T (past the prompt start).
                let x = taps[li].reshaped([-1, h])[64 ..< (64 + tcount)]
                let layer = block as! UnaryLayer
                let params = Dictionary(uniqueKeysWithValues: block.parameters().flattened())
                // Evaluate each fused call on its own: the v2 router's per-block
                // completion counter assumes one in-flight call per block.
                Qwen35FusedMoE.mode = .off
                let stock = layer(x.reshaped([1, tcount, h])).reshaped([tcount, h])
                eval(stock)
                Qwen35FusedMoE.mode = .full
                let fused = layer(x.reshaped([1, tcount, h])).reshaped([tcount, h])
                eval(fused)
                var singles: [MLXArray] = []
                for t in 0 ..< tcount {
                    singles.append(layer(x[t ..< (t + 1)].reshaped([1, 1, h])).reshaped([1, h]))
                    eval(singles[t])
                }
                let single = concatenated(singles, axis: 0)
                Qwen35FusedMoE.mode = .off
                let stockSel = sortedRows(stockRouter(params, x))
                Qwen35FusedMoE.mode = .full
                let fusedRouter = Qwen35FusedMoE.labRouter(block, x)!.0
                eval(fusedRouter)
                Qwen35FusedMoE.mode = .off
                let fusedSel = sortedRows(fusedRouter)
                let (ref, refSel) = reference(params, x)
                eval(stock, fused, single, ref)
                var agree: [Int] = []
                for t in 0 ..< tcount {
                    if fusedSel[t] != stockSel[t] { selFusedVsStock += 1 }
                    if refSel[t] != stockSel[t] { selRefVsStock += 1 }
                    if fusedSel[t] == stockSel[t] && refSel[t] == stockSel[t] { agree.append(t) }
                }
                let invRows = (fused .!= single).any(axis: -1).asType(.int32).sum().item(Int.self)
                invarianceMismatchRows += invRows
                guard !agree.isEmpty else { continue }
                let rows = MLXArray(agree.map { Int32($0) })
                let s = take(stock, rows, axis: 0).asType(.float32)
                let f = take(fused, rows, axis: 0).asType(.float32)
                let r = take(ref, rows, axis: 0)
                let rn = sqrt((r * r).sum()).item(Double.self)
                relStock.append(sqrt(((s - r) * (s - r)).sum()).item(Double.self) / rn)
                relFused.append(sqrt(((f - r) * (f - r)).sum()).item(Double.self) / rn)
                let sn = sqrt((s * s).sum()).item(Double.self)
                relFusedVsStock.append(sqrt(((f - s) * (f - s)).sum()).item(Double.self) / sn)
                maxAbsFusedVsStock = max(maxAbsFusedVsStock, abs(f - s).max().item(Double.self))
                identical += (f .== s).asType(.int32).sum().item(Int.self)
                total += f.size
                compared += agree.count
            }
            let mean: ([Double]) -> Double = { $0.isEmpty ? 0 : $0.reduce(0, +) / Double($0.count) }
            emit([
                "schema": "macprovider.a3b-fused-moe.layer.v1",
                "tokens": tcount,
                "layers": blocks.count,
                "rows_compared": compared,
                "rel_err_stock_vs_fp32_mean": mean(relStock),
                "rel_err_stock_vs_fp32_max": relStock.max() ?? 0,
                "rel_err_fused_vs_fp32_mean": mean(relFused),
                "rel_err_fused_vs_fp32_max": relFused.max() ?? 0,
                "rel_err_fused_vs_stock_mean": mean(relFusedVsStock),
                "max_abs_fused_vs_stock": maxAbsFusedVsStock,
                "frac_bitequal_fused_vs_stock": total == 0 ? 0 : Double(identical) / Double(total),
                "selection_diff_fused_vs_stock_tokens": selFusedVsStock,
                "selection_diff_fp32_vs_stock_tokens": selRefVsStock,
                "fused_batch_invariance_mismatch_rows": invarianceMismatchRows,
            ])
        }
    }

    // MARK: - moe chain

    private static func captureTaps(model: any LanguageModel, pool: [Int32], count: Int)
        throws -> [MLXArray]
    {
        var taps: [MLXArray] = []
        Qwen35FusedMoE.mode = .off
        Qwen35FusedMoE.inputTap = { taps.append($0) }
        let cache = model.newCache(parameters: nil)
        let ids = MLXArray(Array(pool.prefix(count)), [1, count])
        eval(model(LMInput.Text(tokens: ids), cache: cache, state: nil).logits)
        eval(taps)
        Qwen35FusedMoE.inputTap = nil
        return taps
    }

    /// Times the MoE blocks alone on real captured inputs: a dependent chain
    /// over every layer, `x_{l+1} = tap_{l+1} + 0 * y_l` (the two glue ops are
    /// the same for every mode). `stops` 1 / 2 time the router-only and
    /// router + gate/up prefixes; for stock, the same stock graph prefixes.
    static func moeChain(
        model: any LanguageModel, pool: [Int32], tokenCounts: [Int],
        modes: [Qwen35FusedMoE.Mode], stops: [Int], warmup: Int, iters: Int
    ) throws {
        let maxT = tokenCounts.max() ?? 16
        let taps = try captureTaps(model: model, pool: pool, count: 64 + maxT)
        let modules = moeBlocks(model).map(\.1)
        let blocks = modules.map { $0 as! UnaryLayer }
        let zero = MLXArray(Float(0)).asType(.bfloat16)
        // Bytes per expert: packed 4-bit weights plus bf16 scales and biases.
        let h = taps[0].dim(-1)
        let inter = 512
        let gateUpBytes = Double(2 * inter * h / 2 + 2 * 2 * inter * (h / 64) * 2)
        let downBytes = Double(h * inter / 2 + 2 * h * (inter / 64) * 2)
        for tcount in tokenCounts {
            let xs = taps.map { $0.reshaped([-1, h])[64 ..< (64 + tcount)].reshaped([1, tcount, h]) }
            eval(xs)
            var distinct: [Int] = []
            for (l, m) in modules.enumerated() {
                let inds = Qwen35FusedMoE.labRouter(m, xs[l])!.0
                distinct.append(Set(inds.asType(.int32).asArray(Int32.self)).count)
            }
            let distinctMean = Double(distinct.reduce(0, +)) / Double(max(distinct.count, 1))
            for mode in modes {
                var byStop: [Int: Double] = [:]
                for stop in stops {
                    if mode == .router && stop > 0 { continue }
                    Qwen35FusedMoE.mode = mode
                    Qwen35FusedMoE.labStopAfter = mode == .full ? stop : 0
                    let call: (Int, MLXArray) -> MLXArray = { l, x in
                        if mode == .off && stop > 0 {
                            return Qwen35FusedMoE.labStockStage(modules[l], x, stopAfter: stop)!
                        }
                        return blocks[l](x)
                    }
                    var graph: [Double] = []
                    var gpu: [Double] = []
                    for it in 0 ..< (warmup + iters) {
                        Stream().synchronize()
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        var y = call(0, xs[0])
                        for l in 1 ..< blocks.count { y = call(l, xs[l] + zero * y) }
                        let t1 = DispatchTime.now().uptimeNanoseconds
                        eval(y)
                        Stream().synchronize()
                        let t2 = DispatchTime.now().uptimeNanoseconds
                        if it >= warmup {
                            graph.append(Double(t1 - t0) / 1e3 / Double(blocks.count))
                            gpu.append(Double(t2 - t1) / 1e3 / Double(blocks.count))
                        }
                    }
                    Qwen35FusedMoE.mode = .off
                    Qwen35FusedMoE.labStopAfter = 0
                    let med: ([Double]) -> Double = { $0.sorted()[$0.count / 2] }
                    byStop[stop] = med(gpu)
                    emit([
                        "schema": "macprovider.a3b-fused-moe.moe-chain.v2",
                        "tokens": tcount, "fused": mode.rawValue, "layers": blocks.count,
                        "stop_after": stop,
                        "graph_us_per_layer_p50": med(graph), "gpu_us_per_layer_p50": med(gpu),
                        "distinct_experts_mean": distinctMean,
                        "kernel_version": Qwen35FusedMoE.kernelVersion,
                        "gate_up_v3": [
                            Qwen35FusedMoE.gateUpV3Rows, Qwen35FusedMoE.gateUpV3Simdgroups,
                            Qwen35FusedMoE.gateUpV3Chunk, Qwen35FusedMoE.gateUpV3Stage ? 1 : 0,
                        ],
                        "gate_up_tokens_v2": Qwen35FusedMoE.gateUpTokens,
                        "down_tpb_v2": Qwen35FusedMoE.downTokensPerBlock,
                        "kernel_objects": Qwen35FusedMoE.labKernelCount,
                    ])
                }
                if let s1 = byStop[1], let s2 = byStop[2] {
                    let gu = s2 - s1
                    var record: [String: Any] = [
                        "schema": "macprovider.a3b-fused-moe.stage.v1",
                        "tokens": tcount, "fused": mode.rawValue,
                        "distinct_experts_mean": distinctMean,
                        "router_glue_us": s1, "gate_up_us": gu,
                        "gate_up_gbps": (distinctMean + 1) * gateUpBytes / gu / 1e3,
                    ]
                    if let s0 = byStop[0] {
                        record["layer_us"] = s0
                        record["rest_us"] = s0 - s2
                        record["down_gbps"] = (distinctMean + 1) * downBytes / (s0 - s2) / 1e3
                    }
                    emit(record)
                }
            }
        }
    }

    // MARK: - concurrency

    /// Builds several fused MoE calls with no eval between them (the same block
    /// on two inputs and several blocks; one stream, then two streams) and
    /// checks every result is bit-equal to the same call evaluated alone.
    static func concurrency(
        model: any LanguageModel, pool: [Int32], tokenCounts: [Int], rounds: Int
    ) throws {
        let maxT = tokenCounts.max() ?? 16
        let taps = try captureTaps(model: model, pool: pool, count: 64 + 2 * maxT)
        let modules = Array(moeBlocks(model).map(\.1).prefix(4))
        let blocks = modules.map { $0 as! UnaryLayer }
        let h = taps[0].dim(-1)
        let savedMax = Qwen35FusedMoE.maxTokens
        Qwen35FusedMoE.maxTokens = max(savedMax, maxT)
        defer {
            Qwen35FusedMoE.maxTokens = savedMax
            Qwen35FusedMoE.mode = .off
        }
        Qwen35FusedMoE.mode = .full
        for tcount in tokenCounts {
            var calls: [(Int, MLXArray)] = []
            for l in 0 ..< blocks.count {
                for v in 0 ..< 2 {
                    let start = 64 + v * tcount
                    let x = taps[l].reshaped([-1, h])[start ..< (start + tcount)]
                        .reshaped([1, tcount, h])
                    calls.append((l, x))
                }
            }
            eval(calls.map(\.1))
            let before = Qwen35FusedMoE.fusedCalls
            var serial: [MLXArray] = []
            for (l, x) in calls {
                let y = blocks[l](x)
                eval(y)
                serial.append(y)
            }
            let fusedTaken = Qwen35FusedMoE.fusedCalls - before == calls.count
            func mismatches(_ ys: [MLXArray]) -> (Int, Int) {
                var arrays = 0
                var elements = 0
                for (a, b) in zip(ys, serial) {
                    let n = (a .!= b).asType(.int32).sum().item(Int.self)
                    if n > 0 { arrays += 1 }
                    elements += n
                }
                return (arrays, elements)
            }
            var oneStream = (0, 0)
            var twoStreams = (0, 0)
            for _ in 0 ..< rounds {
                // One stream: every call in one graph, evaluated together.
                let ys = calls.map { blocks[$0.0]($0.1) }
                eval(ys)
                let m1 = mismatches(ys)
                oneStream = (oneStream.0 + m1.0, oneStream.1 + m1.1)
                // Two streams: half the calls on each new stream, one eval.
                let half = calls.count / 2
                let ya = Stream.withNewDefaultStream {
                    calls[..<half].map { blocks[$0.0]($0.1) }
                }
                let yb = Stream.withNewDefaultStream {
                    calls[half...].map { blocks[$0.0]($0.1) }
                }
                eval(ya + yb)
                let m2 = mismatches(ya + yb)
                twoStreams = (twoStreams.0 + m2.0, twoStreams.1 + m2.1)
            }
            emit([
                "schema": "macprovider.a3b-fused-moe.concurrency.v1",
                "tokens": tcount, "calls": calls.count, "blocks": blocks.count,
                "rounds": rounds, "fused_taken": fusedTaken,
                "kernel_version": Qwen35FusedMoE.kernelVersion,
                "one_stream_mismatch_arrays": oneStream.0,
                "one_stream_mismatch_elements": oneStream.1,
                "two_streams_mismatch_arrays": twoStreams.0,
                "two_streams_mismatch_elements": twoStreams.1,
            ])
        }
    }

    // MARK: - forward

    static func forward(
        model: any LanguageModel, fused: Qwen35FusedMoE.Mode, batch: Int, width: Int,
        promptTokens: Int, warmup: Int, iters: Int, pool: [Int32]
    ) throws -> String {
        var cursors = (0 ..< batch).map { $0 * 977 }
        func next(_ per: Int) -> [Int32] {
            (0 ..< batch).flatMap { r -> [Int32] in
                let start = cursors[r]
                cursors[r] += per
                return (0 ..< per).map { pool[(start + $0) % pool.count] }
            }
        }
        Qwen35FusedMoE.mode = .off
        let cache = model.newCache(parameters: nil)
        let prompt = MLXArray(next(promptTokens), [batch, promptTokens])
        let prefill = model(LMInput.Text(tokens: prompt), cache: cache, state: nil)
        eval(prefill.logits)
        eval(cache)
        Stream().synchronize()
        Qwen35FusedMoE.mode = fused
        let callsBefore = Qwen35FusedMoE.fusedCalls
        var graphMS: [Double] = []
        var evalMS: [Double] = []
        for iteration in 0 ..< (warmup + iters) {
            let tokens = MLXArray(next(width), [batch, width])
            eval(tokens)
            Stream().synchronize()
            let t0 = DispatchTime.now().uptimeNanoseconds
            let output = model(LMInput.Text(tokens: tokens), cache: cache, state: nil)
            var outputs = [output.logits]
            outputs.append(contentsOf: cache.flatMap(\.state))
            let t1 = DispatchTime.now().uptimeNanoseconds
            eval(outputs)
            Stream().synchronize()
            let t2 = DispatchTime.now().uptimeNanoseconds
            if iteration >= warmup {
                graphMS.append(Double(t1 - t0) / 1e6)
                evalMS.append(Double(t2 - t1) / 1e6)
            }
        }
        let calls = Qwen35FusedMoE.fusedCalls - callsBefore
        Qwen35FusedMoE.mode = .off
        func q(_ v: [Double], _ f: Double) -> Double {
            let s = v.sorted()
            return s[min(s.count - 1, Int(Double(s.count) * f))]
        }
        let record: [String: Any] = [
            "schema": "macprovider.a3b-fused-moe.forward.v1",
            "fused": fused.rawValue,
            "batch": batch,
            "width": width,
            "tokens_per_forward": batch * width,
            "iters": iters,
            "fused_block_calls_per_forward": Double(calls) / Double(warmup + iters),
            "kernel_objects": Qwen35FusedMoE.labKernelCount,
            "kernel_version": Qwen35FusedMoE.kernelVersion,
            "max_t": Qwen35FusedMoE.maxTokens,
            "graph_build_ms_p50": q(graphMS, 0.5),
            "gpu_eval_ms_p50": q(evalMS, 0.5),
            "gpu_eval_ms_p10": q(evalMS, 0.1),
            "gpu_eval_ms_p90": q(evalMS, 0.9),
            "total_ms_p50": q(zip(graphMS, evalMS).map { $0 + $1 }, 0.5),
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - flips / greedy

    private static func rowPrompts(_ prompts: [[Int32]], batch: Int) -> (MLXArray, Int) {
        let len = prompts.map(\.count).min()!
        let rows = (0 ..< batch).map { prompts[$0 % prompts.count].prefix(len) }
        return (MLXArray(rows.flatMap { Array($0) }, [batch, len]), len)
    }

    /// Stock greedy: returns generated tokens [B][n] and stock top-2 margins.
    private static func stockGreedy(
        model: any LanguageModel, prompt: MLXArray, batch: Int, n: Int
    ) -> ([[Int32]], [[Float]]) {
        Qwen35FusedMoE.mode = .off
        let cache = model.newCache(parameters: nil)
        var logits = model(LMInput.Text(tokens: prompt), cache: cache, state: nil).logits[
            0..., -1, 0...]
        var toks: [[Int32]] = Array(repeating: [], count: batch)
        var margins: [[Float]] = Array(repeating: [], count: batch)
        for _ in 0 ..< n {
            let lf = logits.asType(.float32)
            let top = argMax(lf, axis: -1).asType(.int32)
            let sorted = MLX.sorted(lf, axis: -1)
            let margin = sorted[0..., -1] - sorted[0..., -2]
            eval(top, margin)
            let ta = top.asArray(Int32.self)
            let ma = margin.asArray(Float.self)
            for b in 0 ..< batch {
                toks[b].append(ta[b])
                margins[b].append(ma[b])
            }
            logits = model(
                LMInput.Text(tokens: top.reshaped([batch, 1])), cache: cache, state: nil
            ).logits[0..., -1, 0...]
        }
        return (toks, margins)
    }

    /// Teacher-forced argmax over the stock token stream in chunks of `width`.
    /// Position i predicts token i+1 of the generated stream.
    private static func teacherForced(
        model: any LanguageModel, prompt: MLXArray, toks: [[Int32]], width: Int,
        mode: Qwen35FusedMoE.Mode
    ) -> [[Int32]] {
        let batch = toks.count
        Qwen35FusedMoE.mode = .off
        let cache = model.newCache(parameters: nil)
        eval(model(LMInput.Text(tokens: prompt), cache: cache, state: nil).logits)
        Qwen35FusedMoE.mode = mode
        let n = toks[0].count - 1
        var preds: [[Int32]] = Array(repeating: [], count: batch)
        var i = 0
        while i + width <= n {
            let chunk = (0 ..< batch).flatMap { Array(toks[$0][i ..< (i + width)]) }
            let logits = model(
                LMInput.Text(tokens: MLXArray(chunk, [batch, width])), cache: cache, state: nil
            ).logits
            let top = argMax(logits.asType(.float32), axis: -1).asType(.int32)
            let ta = top.asArray(Int32.self)
            for b in 0 ..< batch { preds[b].append(contentsOf: ta[(b * width) ..< ((b + 1) * width)]) }
            i += width
        }
        Qwen35FusedMoE.mode = .off
        return preds
    }

    static func flips(
        model: any LanguageModel, prompts: [[Int32]], batch: Int, widths: [Int], decodeTokens: Int
    ) throws {
        let (prompt, len) = rowPrompts(prompts, batch: batch)
        let (toks, margins) = stockGreedy(
            model: model, prompt: prompt, batch: batch, n: decodeTokens + 1)
        let stock1 = teacherForced(model: model, prompt: prompt, toks: toks, width: 1, mode: .off)
        for width in widths {
            for mode in [Qwen35FusedMoE.Mode.off, .full] {
                let preds = teacherForced(
                    model: model, prompt: prompt, toks: toks, width: width, mode: mode)
                var flipsVsGreedy = 0
                var flipsVsStock1 = 0
                var positions = 0
                var flipMargins: [Float] = []
                for b in 0 ..< batch {
                    for (i, p) in preds[b].enumerated() {
                        positions += 1
                        if p != toks[b][i + 1] {
                            flipsVsGreedy += 1
                            flipMargins.append(margins[b][i + 1])
                        }
                        if i < stock1[b].count, p != stock1[b][i] { flipsVsStock1 += 1 }
                    }
                }
                let nearTies = margins.flatMap { $0.dropFirst() }.filter { $0 < 0.25 }.count
                emit([
                    "schema": "macprovider.a3b-fused-moe.flips.v1",
                    "batch": batch, "width": width, "fused": mode.rawValue,
                    "prompt_tokens": len, "positions": positions,
                    "flips_vs_stock_greedy": flipsVsGreedy,
                    "flips_vs_stock_tf_w1": flipsVsStock1,
                    "flip_stock_margins": flipMargins.map { Double($0) },
                    "stock_near_ties_lt_0_25": nearTies,
                ])
            }
        }
    }

    static func greedy(model: any LanguageModel, prompts: [[Int32]], decodeTokens: Int) throws {
        var matches: [Int] = []
        for p in prompts {
            let prompt = MLXArray(p, [1, p.count])
            let (stock, margins) = stockGreedy(model: model, prompt: prompt, batch: 1, n: decodeTokens)
            Qwen35FusedMoE.mode = .full
            let cache = model.newCache(parameters: nil)
            Qwen35FusedMoE.mode = .off
            var logits = model(LMInput.Text(tokens: prompt), cache: cache, state: nil).logits[
                0..., -1, 0...]
            Qwen35FusedMoE.mode = .full
            var fused: [Int32] = []
            for _ in 0 ..< decodeTokens {
                let top = argMax(logits.asType(.float32), axis: -1).asType(.int32)
                fused.append(top.item(Int32.self))
                logits = model(
                    LMInput.Text(tokens: top.reshaped([1, 1])), cache: cache, state: nil
                ).logits[0..., -1, 0...]
            }
            Qwen35FusedMoE.mode = .off
            let prefix = zip(stock[0], fused).prefix { $0 == $1 }.count
            matches.append(prefix)
            emit([
                "schema": "macprovider.a3b-fused-moe.greedy.v1",
                "prompt_tokens": p.count, "decode_tokens": decodeTokens,
                "matching_prefix": prefix,
                "divergence_stock_margin": prefix < decodeTokens ? Double(margins[0][prefix]) : -1,
            ])
        }
        emit([
            "schema": "macprovider.a3b-fused-moe.greedy-summary.v1",
            "prompts": matches.count,
            "full_match": matches.filter { $0 == decodeTokens }.count,
            "matching_prefixes": matches,
        ])
    }
}
#endif
