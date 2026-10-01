#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import Tokenizers

/// A3B small-batch MoE modes of `mlx-smallm-probe` (#1770):
/// - `overlap`: greedy-decodes 8 real prompts with router capture, then
///   counts distinct routed experts per layer among B x (1 + k) verify tokens
///   (B rows, 1 + k consecutive decode positions) vs B x (1 + k) x TOPK pairs.
/// - `greal`: the same captured MoE inputs and router indices per layer;
///   grouped kernel vs MLX gather_qmm correctness (vs an fp32 reference) and
///   per-layer timing over all layers (weights stream from DRAM).
/// - `flips`: teacher-forced [B, w] decode over stock-greedy tokens, stock vs
///   lab kernels; argmax flips and max |logit delta| on final logits.
extension MLXSmallMProbeCommand {
    static let moePrompts = [
        "Explain how a heat pump moves heat from a cold place to a warm place, step by step.",
        "Write a short Python function that returns the n-th Fibonacci number iteratively.",
        "List three differences between TCP and UDP and when you would choose each one.",
        "Summarize the plot of a story about a lighthouse keeper who finds a message in a bottle.",
        "What are the main causes of inflation, and how do central banks respond to it?",
        "Translate into French: The weather is nice today, so we will walk to the market.",
        "Describe the water cycle for a ten-year-old in a few short sentences.",
        "Give me a checklist for reviewing a pull request that changes a database schema.",
    ]

    struct MoECapture {
        /// [layer][step] -> x [rows, K]
        var x: [Int: [MLXArray]] = [:]
        /// [layer][step][row] -> expert ids
        var inds: [Int: [[[Int32]]]] = [:]
        var layers: [Int] { x.keys.sorted() }
        var steps = 0
        var rows = 0
    }

    static func loadA3B(_ modelDir: String) async throws -> ModelContainer {
        await Qwen35TextMTPRegistration.register()
        return try await LLMModelFactory.shared.loadContainer(
            from: URL(fileURLWithPath: modelDir, isDirectory: true),
            using: #huggingFaceTokenizerLoader()
        )
    }

    /// Greedy decode of the 8 prompts (rows batched, truncated to the shortest
    /// prompt) with per-step router capture on every MoE layer.
    static func captureDecode(context: ModelContext, steps: Int) throws -> MoECapture {
        let rows = moePrompts.count
        let encoded = moePrompts.map { context.tokenizer.encode(text: $0) }
        let length = encoded.map(\.count).min() ?? 0
        let flat = encoded.flatMap { $0.prefix(length).map { Int32($0) } }
        let cache = try context.model.newCache(parameters: nil)
        LabMoEBlock.captured = nil
        var logits = context.model(LMInput.Text(tokens: MLXArray(flat, [rows, length])), cache: cache, state: nil).logits
        var cap = MoECapture()
        cap.rows = rows
        for _ in 0 ..< steps {
            let next = argMax(logits[0..., -1], axis: -1).asType(.int32)
            LabMoEBlock.captured = []
            logits = context.model(LMInput.Text(tokens: next.reshaped([rows, 1])), cache: cache, state: nil).logits
            let entries = LabMoEBlock.captured ?? []
            LabMoEBlock.captured = nil
            eval([logits] + entries.flatMap { [$0.1, $0.2] })
            for (layer, x, inds) in entries {
                cap.x[layer, default: []].append(x)
                let flatInds = inds.asType(.int32).asArray(Int32.self)
                let topk = inds.dim(1)
                cap.inds[layer, default: []].append((0 ..< rows).map { r in Array(flatInds[r * topk ..< (r + 1) * topk]) })
            }
            cap.steps += 1
        }
        return cap
    }

    func runOverlap() async throws {
        guard let modelDir else { throw ValidationError("--model-dir required") }
        let container = try await Self.loadA3B(modelDir)
        let steps = decodeTokens
        let batchList = batches.split(separator: ",").compactMap { Int($0) }
        let lines = try await container.perform { context -> [String] in
            let installed = LabMoEBlock.install(in: context.model)
            let cap = try Self.captureDecode(context: context, steps: steps)
            var out: [String] = []
            for b in batchList where b <= cap.rows {
                for k in 0 ... 3 {
                    let w = 1 + k
                    var distinct: [Double] = []
                    var maxPer: [Double] = []
                    var perLayerMean: [Int: Double] = [:]
                    for layer in cap.layers {
                        var layerSum = 0.0
                        var layerN = 0
                        for p in 0 ... (cap.steps - w) {
                            var counts: [Int32: Int] = [:]
                            for r in 0 ..< b {
                                for j in 0 ..< w {
                                    for e in cap.inds[layer]![p + j][r] { counts[e, default: 0] += 1 }
                                }
                            }
                            distinct.append(Double(counts.count))
                            maxPer.append(Double(counts.values.max() ?? 0))
                            layerSum += Double(counts.count)
                            layerN += 1
                        }
                        perLayerMean[layer] = layerSum / Double(max(layerN, 1))
                    }
                    let sorted = distinct.sorted()
                    let tokens = b * w
                    let pairs = tokens * 8
                    let mean = distinct.reduce(0, +) / Double(distinct.count)
                    let record: [String: Any] = [
                        "schema": "macprovider.mlx-smallm-probe.moe-overlap.v1",
                        "batch": b, "k": k, "tokens": tokens, "pairs": pairs,
                        "moe_layers": installed, "windows_per_layer": cap.steps - w + 1,
                        "distinct_mean": mean,
                        "distinct_p10": sorted[sorted.count / 10],
                        "distinct_p50": sorted[sorted.count / 2],
                        "distinct_p90": sorted[sorted.count * 9 / 10],
                        "distinct_min": sorted.first ?? 0, "distinct_max": sorted.last ?? 0,
                        "pairs_per_distinct": Double(pairs) / mean,
                        "max_tokens_per_expert_mean": maxPer.reduce(0, +) / Double(maxPer.count),
                        "layer_distinct_mean_min": perLayerMean.values.min() ?? 0,
                        "layer_distinct_mean_max": perLayerMean.values.max() ?? 0,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    out.append(String(decoding: data, as: UTF8.self))
                }
            }
            return out
        }
        for line in lines { print(line) }
        fflush(stdout)
    }

    func runGroupedReal() async throws {
        guard let modelDir else { throw ValidationError("--model-dir required") }
        let container = try await Self.loadA3B(modelDir)
        let steps = max(decodeTokens, 24)
        let batchList = batches.split(separator: ",").compactMap { Int($0) }
        let widthList = (widths ?? "1,2,3,4").split(separator: ",").compactMap { Int($0) }
        let warmup = self.warmup
        let iters = self.iters
        let serial = self.serial
        let lines = try await container.perform { context -> [String] in
            LabMoEBlock.install(in: context.model)
            let cap = try Self.captureDecode(context: context, steps: steps)
            let blocks = Dictionary(uniqueKeysWithValues: context.model.namedModules().compactMap { _, m -> (Int, LabMoEBlock)? in
                (m as? LabMoEBlock).map { ($0.layer, $0) }
            })
            let layers = cap.layers
            var out: [String] = []
            func emit(_ r: [String: Any]) throws {
                let data = try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys])
                out.append(String(decoding: data, as: UTF8.self))
            }
            let p0 = 8
            for b in batchList where b <= cap.rows {
                for w in widthList where p0 + w <= cap.steps {
                    let t = b * w
                    // Token order matches a [B, w] forward flattened row-major.
                    var xs: [Int: MLXArray] = [:]
                    var inds: [Int: MLXArray] = [:]
                    for layer in layers {
                        let rowsX = (0 ..< b).flatMap { r in (0 ..< w).map { j in cap.x[layer]![p0 + j][r ..< r + 1] } }
                        xs[layer] = concatenated(rowsX, axis: 0)
                        let ids = (0 ..< b).flatMap { r in (0 ..< w).flatMap { j in cap.inds[layer]![p0 + j][r] } }
                        inds[layer] = MLXArray(ids, [t, 8]).asType(.uint32)
                    }
                    eval(Array(xs.values) + Array(inds.values))
                    // Correctness on every layer.
                    var errOurs: Float = 0
                    var errStock: Float = 0
                    var relOurs: Float = 0
                    var relStock: Float = 0
                    var mismatch = 0.0
                    var invariant = true
                    var distinctSum = 0
                    for layer in layers {
                        let blk = blocks[layer]!
                        let x = xs[layer]!
                        let ix = inds[layer]!
                        let ours = MoESmallM.groupedSwitchGLU(x, inds: ix, gate: blk.gateW, up: blk.upW, down: blk.downW)
                        let stock = MoESmallM.stockSwitchGLU(x, inds: ix, gate: blk.gateW, up: blk.upW, down: blk.downW)
                        func f32(_ q: MoESmallM.QWeight) -> MoESmallM.QWeight {
                            .init(w: q.w, scales: q.scales.asType(.float32), biases: q.biases.asType(.float32))
                        }
                        let ref = MoESmallM.stockSwitchGLU(
                            x.asType(.float32), inds: ix, gate: f32(blk.gateW), up: f32(blk.upW), down: f32(blk.downW))
                        let single = MoESmallM.groupedSwitchGLU(
                            x[0 ..< 1], inds: ix[0 ..< 1], gate: blk.gateW, up: blk.upW, down: blk.downW)
                        eval(ours, stock, ref, single)
                        let scale = abs(ref).max().item(Float.self)
                        let eo = abs(ours.asType(.float32) - ref).max().item(Float.self)
                        let es = abs(stock.asType(.float32) - ref).max().item(Float.self)
                        errOurs = max(errOurs, eo)
                        errStock = max(errStock, es)
                        relOurs = max(relOurs, eo / max(scale, 1e-30))
                        relStock = max(relStock, es / max(scale, 1e-30))
                        mismatch += Double((ours .!= stock).asType(.float32).mean().item(Float.self))
                        if (single .!= ours[0 ..< 1]).asType(.int32).sum().item(Int.self) != 0 { invariant = false }
                        distinctSum += Set(ix.asType(.int32).asArray(Int32.self)).count
                    }
                    // Timing: all layers per iteration (independent or dependent chain).
                    func time(_ fn: (MLXArray, MLXArray, LabMoEBlock) -> MLXArray) -> (Double, Double) {
                        var samples: [Double] = []
                        for iteration in 0 ..< (warmup + iters) {
                            var outs: [MLXArray] = []
                            var prev: MLXArray?
                            for layer in layers {
                                var x = xs[layer]!
                                if serial, let prev {
                                    x = x + 0 * prev.sum().asType(x.dtype)
                                }
                                let y = fn(x, inds[layer]!, blocks[layer]!)
                                outs.append(y)
                                prev = y
                            }
                            Stream().synchronize()
                            let t0 = DispatchTime.now().uptimeNanoseconds
                            eval(outs)
                            Stream().synchronize()
                            let t1 = DispatchTime.now().uptimeNanoseconds
                            if iteration >= warmup {
                                samples.append(Double(t1 - t0) / 1e3 / Double(layers.count))
                            }
                        }
                        let sorted = samples.sorted()
                        return (sorted[sorted.count / 2], sorted.first ?? 0)
                    }
                    let stockT = time { x, ix, blk in
                        MoESmallM.stockSwitchGLU(x, inds: ix, gate: blk.gateW, up: blk.upW, down: blk.downW)
                    }
                    let oursT = time { x, ix, blk in
                        MoESmallM.groupedSwitchGLU(x, inds: ix, gate: blk.gateW, up: blk.upW, down: blk.downW)
                    }
                    let bucketT = time { _, ix, blk in
                        MoESmallM.bucket(ix, experts: blk.gateW.experts).counts
                    }
                    try emit([
                        "schema": "macprovider.mlx-smallm-probe.moe-greal.v1",
                        "batch": b, "width": w, "tokens": t, "pairs": t * 8, "layers": layers.count,
                        "serial": serial,
                        "distinct_mean": Double(distinctSum) / Double(layers.count),
                        "us_per_layer_mlx": stockT.0, "us_per_layer_mlx_min": stockT.1,
                        "us_per_layer_grouped": oursT.0, "us_per_layer_grouped_min": oursT.1,
                        "us_per_layer_bucket_only": bucketT.0,
                        "speedup": stockT.0 / oursT.0,
                        "ours_max_abs_err": errOurs, "mlx_max_abs_err": errStock,
                        "ours_max_rel_err": relOurs, "mlx_max_rel_err": relStock,
                        "ours_vs_mlx_mismatch_frac_mean": mismatch / Double(layers.count),
                        "ours_token0_batch_invariant": invariant,
                    ])
                }
            }
            return out
        }
        for line in lines { print(line) }
        fflush(stdout)
    }

    func runFlips() async throws {
        guard let modelDir else { throw ValidationError("--model-dir required") }
        let container = try await Self.loadA3B(modelDir)
        let dense = smallmQMV
        if dense != "off" {
            guard let config = SmallMQMV.Config.parse(dense) else { throw ValidationError("bad --smallm-qmv \(dense)") }
            SmallMQuantizedLinear.fixedConfig = config
        }
        let steps = decodeTokens
        let rowsList = batches.split(separator: ",").compactMap { Int($0) }
        let widthList = (widths ?? "1,2").split(separator: ",").compactMap { Int($0) }
        let lines = try await container.perform { context -> [String] in
            LabMoEBlock.install(in: context.model)
            let routedDense = dense == "off" ? 0 : SmallMQuantizedLinear.install(in: context.model)
            func setLab(_ on: Bool) {
                LabMoEBlock.routed = on ? .grouped : .stock
                SmallMQuantizedLinear.enabled = on
            }
            var out: [String] = []
            for rows in rowsList {
                let encoded = (0 ..< rows).map { context.tokenizer.encode(text: Self.moePrompts[$0 % Self.moePrompts.count]) }
                let length = encoded.map(\.count).min() ?? 0
                let prompt = MLXArray(encoded.flatMap { $0.prefix(length).map { Int32($0) } }, [rows, length])
                // Stock greedy tokens.
                setLab(false)
                var cache = try context.model.newCache(parameters: nil)
                var logits = context.model(LMInput.Text(tokens: prompt), cache: cache, state: nil).logits
                var gen: [[Int32]] = Array(repeating: [], count: rows)
                for _ in 0 ..< steps {
                    let next = argMax(logits[0..., -1], axis: -1).asType(.int32)
                    let ids = next.asArray(Int32.self)
                    for r in 0 ..< rows { gen[r].append(ids[r]) }
                    logits = context.model(LMInput.Text(tokens: next.reshaped([rows, 1])), cache: cache, state: nil).logits
                }
                let genArr = MLXArray(gen.flatMap { $0 }, [rows, steps])
                for w in widthList {
                    var argmaxes: [[Int32]] = []
                    var allLogits: [MLXArray] = []
                    for lab in [false, true] {
                        setLab(lab)
                        cache = try context.model.newCache(parameters: nil)
                        _ = context.model(LMInput.Text(tokens: prompt), cache: cache, state: nil).logits
                        var am: [MLXArray] = []
                        var lg: [MLXArray] = []
                        var p = 0
                        while p + w <= steps {
                            let chunk = genArr[0..., p ..< p + w]
                            let l = context.model(LMInput.Text(tokens: chunk), cache: cache, state: nil).logits
                            let lf = l.asType(.float32)
                            am.append(argMax(lf, axis: -1).asType(.int32))
                            lg.append(lf)
                            eval(am.last!, lg.last!)
                            p += w
                        }
                        argmaxes.append(concatenated(am, axis: 1).asArray(Int32.self))
                        allLogits.append(concatenated(lg, axis: 1))
                    }
                    let flips = zip(argmaxes[0], argmaxes[1]).filter { $0 != $1 }.count
                    let delta = abs(allLogits[0] - allLogits[1]).max().item(Float.self)
                    let scale = abs(allLogits[0]).max().item(Float.self)
                    // Near-ties: positions where stock's top-2 margin is below 0.25.
                    let top2 = sorted(allLogits[0], axis: -1)[.ellipsis, (-2)...]
                    let margin = top2[.ellipsis, 1] - top2[.ellipsis, 0]
                    let nearTies = (margin .< 0.25).asType(.int32).sum().item(Int.self)
                    let record: [String: Any] = [
                        "schema": "macprovider.mlx-smallm-probe.moe-flips.v1",
                        "rows": rows, "width": w, "positions": argmaxes[0].count, "prompt_tokens": length,
                        "smallm_qmv": dense, "smallm_routed_layers": routedDense, "moe": "grouped",
                        "argmax_flips": flips, "max_abs_logit_delta": delta, "max_abs_logit": scale,
                        "stock_near_ties_lt_0_25": nearTies,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    out.append(String(decoding: data, as: UTF8.self))
                }
            }
            setLab(false)
            return out
        }
        for line in lines { print(line) }
        fflush(stdout)
    }

    /// Synthetic grouped-MoE check + timing: E = 256 experts, hidden 2048,
    /// expert 512, TOPK 8, T tokens drawn from a pool of D experts (every pool
    /// expert used), several layer copies so weights stream from DRAM.
    func runGroupedBench() throws {
        let tokenList = parsedMs().filter { $0 <= 64 }
        var distinctFor: [Int: [Int]] = [:]
        for item in (distinct ?? "").split(separator: ",") {
            let kv = item.split(separator: ":").compactMap { Int($0) }
            if kv.count == 2 { distinctFor[kv[0], default: []].append(kv[1]) }
        }
        let e = 256, hidden = 2048, inter = 512, topk = 8
        let copies = max(1, copiesOverride ?? 6)
        func qw(_ out: Int, _ inp: Int, _ seed: UInt64) -> MoESmallM.QWeight {
            let w = MLXRandom.normal([e, out, inp], key: MLXRandom.key(seed)).asType(.bfloat16) * 0.02
            let q = quantized(w, groupSize: 64, bits: 4)
            eval(q.wq, q.scales, q.biases!)
            return .init(w: q.wq, scales: q.scales, biases: q.biases!)
        }
        var layers: [(MoESmallM.QWeight, MoESmallM.QWeight, MoESmallM.QWeight)] = []
        for c in 0 ..< copies {
            layers.append((qw(inter, hidden, UInt64(10 * c + 1)), qw(inter, hidden, UInt64(10 * c + 2)),
                           qw(hidden, inter, UInt64(10 * c + 3))))
            Memory.clearCache()
        }
        var rng: UInt64 = 0x1234_5678
        func next() -> Int {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(rng >> 33)
        }
        for t in tokenList {
            let ds = distinctFor[t] ?? [min(e, t * topk)]
            for d0 in ds {
                let d = max(topk, min(d0, min(e, t * topk)))
                // Pool of d experts; token i takes 8 consecutive pool entries
                // starting at i * 8 mod d (covers the pool), shuffled pool.
                var pool = Array(0 ..< e)
                for i in stride(from: e - 1, to: 0, by: -1) { pool.swapAt(i, next() % (i + 1)) }
                pool = Array(pool.prefix(d))
                var ids: [Int32] = []
                for i in 0 ..< t {
                    var chosen: [Int32] = []
                    var j = (i * topk) % d
                    while chosen.count < topk {
                        let v = Int32(pool[j % d])
                        if !chosen.contains(v) { chosen.append(v) }
                        j += 1
                    }
                    ids += chosen
                }
                let inds = MLXArray(ids, [t, topk]).asType(.uint32)
                let x = MLXRandom.normal([t, hidden], key: MLXRandom.key(UInt64(500 + t))).asType(.bfloat16)
                eval(inds, x)
                let (g, u, dn) = layers[0]
                let ours = MoESmallM.groupedSwitchGLU(x, inds: inds, gate: g, up: u, down: dn)
                let stock = MoESmallM.stockSwitchGLU(x, inds: inds, gate: g, up: u, down: dn)
                func f32(_ q: MoESmallM.QWeight) -> MoESmallM.QWeight {
                    .init(w: q.w, scales: q.scales.asType(.float32), biases: q.biases.asType(.float32))
                }
                let ref = MoESmallM.stockSwitchGLU(x.asType(.float32), inds: inds, gate: f32(g), up: f32(u), down: f32(dn))
                let single = MoESmallM.groupedSwitchGLU(x[0 ..< 1], inds: inds[0 ..< 1], gate: g, up: u, down: dn)
                eval(ours, stock, ref, single)
                let scale = abs(ref).max().item(Float.self)
                let eo = abs(ours.asType(.float32) - ref).max().item(Float.self)
                let es = abs(stock.asType(.float32) - ref).max().item(Float.self)
                let invariant = (single .!= ours[0 ..< 1]).asType(.int32).sum().item(Int.self) == 0
                func time(_ fn: (MLXArray, MoESmallM.QWeight, MoESmallM.QWeight, MoESmallM.QWeight) -> MLXArray) -> (Double, Double) {
                    var samples: [Double] = []
                    for iteration in 0 ..< (warmup + iters) {
                        var outs: [MLXArray] = []
                        var xi = x
                        for (g, u, dn) in layers {
                            let y = fn(xi, g, u, dn)
                            outs.append(y)
                            if serial { xi = x + 0 * y.sum().asType(x.dtype) }
                        }
                        Stream().synchronize()
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        eval(outs)
                        Stream().synchronize()
                        let t1 = DispatchTime.now().uptimeNanoseconds
                        if iteration >= warmup { samples.append(Double(t1 - t0) / 1e3 / Double(copies)) }
                    }
                    let sorted = samples.sorted()
                    return (sorted[sorted.count / 2], sorted.first ?? 0)
                }
                let st = time { xi, g, u, dn in MoESmallM.stockSwitchGLU(xi, inds: inds, gate: g, up: u, down: dn) }
                let gr = time { xi, g, u, dn in MoESmallM.groupedSwitchGLU(xi, inds: inds, gate: g, up: u, down: dn) }
                let gr1 = time { xi, g, u, dn in MoESmallM.groupedSwitchGLU(xi, inds: inds, gate: g, up: u, down: dn, stages: 1) }
                let gr2 = time { xi, g, u, dn in MoESmallM.groupedSwitchGLU(xi, inds: inds, gate: g, up: u, down: dn, stages: 2) }
                try Self.emit([
                    "schema": "macprovider.mlx-smallm-probe.moe-gbench.v1",
                    "tokens": t, "pairs": t * topk, "distinct": d, "copies": copies, "serial": serial,
                    "gateup_tiling": MoESmallM.gateUpTiling.description, "down_tiling": MoESmallM.downTiling.description, "mm": MoESmallM.maxTokensPerPass,
                    "us_mlx": st.0, "us_min_mlx": st.1, "us_grouped": gr.0, "us_min_grouped": gr.1,
                    "speedup": st.0 / gr.0,
                    "us_grouped_bucket_only": gr1.0, "us_grouped_bucket_gateup": gr2.0,
                    "ours_max_abs_err": eo, "mlx_max_abs_err": es, "ours_max_rel_err": eo / max(scale, 1e-30),
                    "mlx_max_rel_err": es / max(scale, 1e-30),
                    "ours_vs_mlx_mismatch_frac": (ours .!= stock).asType(.float32).mean().item(Float.self),
                    "ours_token0_batch_invariant": invariant,
                ])
            }
        }
    }

    /// Microbench install: `--moe-smallm off|stock|grouped`, `--ablate`
    /// comma list of attnproj, router, routed, shared, lmhead.
    static func installMoELab(moe: String, ablate: String, container: ModelContainer) async throws -> String {
        let parts = Set(ablate.split(separator: ",").map(String.init).filter { !$0.isEmpty && $0 != "none" })
        let known: Set<String> = ["attnproj", "router", "routed", "shared", "lmhead"]
        guard parts.isSubset(of: known) else { throw ValidationError("bad --ablate \(ablate)") }
        guard ["off", "stock", "grouped"].contains(moe) else { throw ValidationError("bad --moe-smallm \(moe)") }
        let needsLab = moe != "off" || !parts.intersection(["router", "routed", "shared"]).isEmpty
        return await container.perform { context in
            var notes: [String] = []
            if needsLab {
                notes.append("moe_blocks=\(LabMoEBlock.install(in: context.model))")
                LabMoEBlock.routed = moe == "grouped" ? .grouped : .stock
                LabMoEBlock.ablateRouter = parts.contains("router")
                LabMoEBlock.ablateRouted = parts.contains("routed")
                LabMoEBlock.ablateShared = parts.contains("shared")
            }
            if parts.contains("attnproj") {
                notes.append("zero_attn=\(ZeroQuantizedLinear.install(in: context.model) { $0.contains("self_attn.") || $0.contains("linear_attn.") })")
            }
            if parts.contains("lmhead") {
                notes.append("zero_lm_head=\(ZeroQuantizedLinear.install(in: context.model) { $0.hasSuffix("lm_head") })")
            }
            return notes.joined(separator: ";")
        }
    }
}
#endif
