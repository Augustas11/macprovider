// GLM-5.3-Flash native decode lab bench (epic #2029).
//
// Usage: GLMBench <model_dir> [mode] [--prompt N] [--steps N] [--wired]
// Modes (one model load each):
//   (default)        pipelined greedy decode tok/s
//   --studio         unwired vs wired step time, fused vs op path (median of 31)
//   --profile        per-layer synchronous segment timings (sync dominated;
//                    use --module-census / --census for dispatch counts)
//   --oracle F.json  teacher-forced top-16 logit diffs vs a glm-parity oracle
//                    for all-fused, hyper-connection op path and all-op configs
//   --gpu-profile    GPU busy vs wall time per step; with MLX_MAX_OPS_PER_BUFFER=0,
//                    GPU time, bound bytes and bandwidth per kernel and family
//   --census         compute dispatches per decode step by kernel name
//   --module-census  dispatches per module (MoE, dense FFN, KDA, DSA, head)
//   --*-exact        fused vs op path exactness on the loaded weights
//                    (kda, hc, router, moe, dsa, deferred)
//   --random         real shapes from config.json with seeded random weights
// GPU runs only in an announced lab window; never beside a serving provider.
import Foundation
import MLX
import MLXLMCommon
import MLXNN

@testable import MLXLLM

// Usage: GLMBench <model_dir> [--prompt N] [--steps N] [--profile] [--sync]
let args = CommandLine.arguments
func opt(_ name: String, _ def: Int) -> Int {
    if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) { return v }
    return def
}
func optString(_ name: String) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return nil
}
let dir = URL(fileURLWithPath: args[1])
let promptLen = opt("--prompt", 1024)
let steps = opt("--steps", 32)
let profile = args.contains("--profile")
let syncEach = args.contains("--sync")

Memory.cacheLimit = 4096 << 20
if ["--census", "--module-census", "--gpu-profile"].contains(where: CommandLine.arguments.contains) { DispatchCensus.install() }

let configData = try Data(contentsOf: dir.appendingPathComponent("config.json"))
let base = try JSONDecoder().decode(BaseConfiguration.self, from: configData)
let config = try JSONDecoder().decode(GLM5NextConfiguration.self, from: configData)
let model = GLM5NextModel(config)
let t0 = Date()
if args.contains("--random") {
    // Real shapes and per-layer bit widths, seeded random values.
    let plq = base.perLayerQuantization!
    quantize(model: model) { path, _ in
        if path.hasSuffix("mlp.gate") || path.contains("conv1d") { return nil }
        return plq.quantization(layer: path)?.asTuple
    }
    let params = model.parameters().flattened()
    var i: UInt64 = 0
    let updated: [(String, MLXArray)] = params.map { key, value in
        i += 1
        let rs = MLXRandom.RandomState(seed: i)
        let v: MLXArray = withRandomState(rs) {
            if value.dtype == .uint32 {
                return MLXArray.full(value.shape, values: MLXArray(UInt32(0x89AB_CDEF)), type: UInt32.self)
            }
            if key.hasSuffix(".scales") { return (0.002 + 0.001 * MLXRandom.uniform(0 ..< 1, value.shape)).asType(value.dtype) }
            if key.hasSuffix(".biases") { return (-0.015 * MLXRandom.uniform(0 ..< 1, value.shape) - 0.008).asType(value.dtype) }
            if key.hasSuffix("norm.weight") || key.hasSuffix("layernorm.weight") || key.hasSuffix("scale") { return MLXArray.ones(value.shape).asType(value.dtype) }
            return (0.02 * MLXRandom.normal(value.shape)).asType(value.dtype)
        }
        eval(v)
        return (key, v)
    }
    model.update(parameters: ModuleParameters.unflattened(updated))
    eval(model)
} else {
    try loadWeights(
        modelDirectory: dir, model: model, perLayerQuantization: base.perLayerQuantization)
}
model.train(false)  // as ModelContext does
print("hc_deferred_exact=\(glm5NextHCDeferredExact)")
if args.contains("--no-deferred") || args.contains("--no-fused") {
    model.languageModel.model.deferredDecode = false
}
if args.contains("--no-fused") {
    for layer in model.languageModel.model.layers {
        layer.attnHC.fusedDecode = false
        layer.ffnHC.fusedDecode = false
        (layer.selfAttn as? GLM5NextLinearAttention)?.fusedDecode = false
        (layer.mlp as? GLM5NextMoE)?.gate.fusedDecode = false
        (layer.selfAttn as? GLM5NextAttention)?.indexer?.fusedDecode = false
    }
}
print("load_s=\(String(format: "%.1f", Date().timeIntervalSince(t0))) active_gb=\(Double(Memory.activeMemory) / 1e9)")

var wiredTicket: WiredMemoryTicket?
if args.contains("--wired") {
    // Same ticket as ModelRuntime.residentWeightsTicket (provider fix).
    let cap = GPU.maxRecommendedWorkingSetBytes() ?? 0
    let ticket = WiredMemoryTicket(size: cap, policy: MLXLMCommon.WiredFixedPolicy(limit: cap), manager: .shared, kind: .active)
    let applied = await ticket.start()
    wiredTicket = ticket
    print("wired_limit_applied=\(applied) cap=\(cap)")
}
let ballastGB = opt("--ballast-gb", 0)
var ballast: [MLXArray] = []
for _ in 0 ..< ballastGB {
    let b = MLXArray.ones([1 << 28], dtype: .float32)  // 1 GiB, kept alive, never touched again
    eval(b)
    ballast.append(b)
}
if ballastGB > 0 { print("ballast_gb=\(ballastGB) active_gb=\(Double(Memory.activeMemory) / 1e9)") }
let text = model.languageModel
let cache = try model.newCache(parameters: nil)
let prompt = withRandomState(MLXRandom.RandomState(seed: 3)) {
    MLXRandom.randInt(0 ..< 150000, [1, promptLen]).asType(.int32)
}

struct Oracle: Decodable {
    let prompt: [Int]
    let greedy: [Int]
    let top_idx: [[Int]]
    let top_logit: [[Float]]
}
let oracle: Oracle? = try optString("--oracle").map {
    try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
}
let promptTokens: MLXArray = oracle.map { MLXArray($0.prompt.map(Int32.init)).reshaped(1, -1) } ?? prompt
let pf0 = Date()
var start = 0
var last = MLXArray(0)
while start < promptTokens.dim(1) {
    let end = min(start + 2048, promptTokens.dim(1))
    last = model(promptTokens[0..., start ..< end], cache: cache)[0, -1, 0...].asType(.float32)
    eval(last)
    start = end
}
let pfs = Date().timeIntervalSince(pf0)
print("prefill_tps=\(String(format: "%.1f", Double(promptTokens.dim(1)) / pfs))")

var token = argMax(last, axis: -1)
eval(token)

if args.contains("--dsa-exact") {
    // Fused vs op indexer selection on the real DSA layer, several decode steps.
    let attn = text.model.layers[3].selfAttn as! GLM5NextAttention
    let indexer = attn.indexer!
    let base = cache[3] as! GLM5NextAttentionCache
    var allEqual = true
    for step in 0 ..< 6 {
        let x = withRandomState(MLXRandom.RandomState(seed: UInt64(300 + step))) {
            (0.5 * MLXRandom.normal([1, 1, 4096])).asType(.bfloat16)
        }
        let c = base.copy() as! GLM5NextAttentionCache
        let qResid = attn.qALayerNorm(attn.qAProj(x))
        _ = c.appendLatent(expandedDimensions(attn.kvALayerNorm(attn.kvAProj(x)), axis: 1))
        let pooled = indexer.updatePools(x, cache: c)
        indexer.fusedDecode = false
        let a = indexer.select(x, qResid: qResid, pooledKeys: pooled, kvLength: c.offset)
        indexer.fusedDecode = true
        let b = indexer.select(x, qResid: qResid, pooledKeys: pooled, kvLength: c.offset)
        eval(a, b)
        let eq = a.shape == b.shape && arrayEqual(a, b).item(Bool.self)
        if !eq { allEqual = false }
        print("step \(step): kv=\(c.offset) pools=\(pooled?.dim(1) ?? 0) shape=\(b.shape) equal=\(eq)")
        _ = base.appendLatent(expandedDimensions(attn.kvALayerNorm(attn.kvAProj(x)), axis: 1))
        _ = indexer.updatePools(x, cache: base)
    }
    print("dsa select bitwise=\(allEqual)")
    exit(0)
}
if args.contains("--moe-exact") {
    let moe = text.model.layers[3].mlp as! GLM5NextMoE
    var equal = 0
    var worst: Float = 0
    for seed in 0 ..< 100 {
        let x = withRandomState(MLXRandom.RandomState(seed: UInt64(2000 + seed))) {
            (Float(seed % 5 + 1) * 0.4 * MLXRandom.normal([1, 1, 4096])).asType(.bfloat16)
        }
        moe.gate.fusedDecode = false
        let a = moe(x)
        moe.gate.fusedDecode = true
        let b = moe(x)
        eval(a, b)
        if arrayEqual(a, b).item(Bool.self) { equal += 1 }
        worst = max(worst, abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self))
    }
    print("moe: bitwise=\(equal)/100 max|d|=\(worst)")
    exit(0)
}
if args.contains("--router-exact") {
    let gate = (text.model.layers[3].mlp as! GLM5NextMoE).gate
    var idxEqual = 0, scoreEqual = 0, n = 0
    var worst: Float = 0
    for seed in 0 ..< 200 {
        let x = withRandomState(MLXRandom.RandomState(seed: UInt64(1000 + seed))) {
            (Float(seed % 4 + 1) * 0.5 * MLXRandom.normal([1, 1, 4096])).asType(.bfloat16)
        }
        gate.fusedDecode = false
        let (io, so) = gate(x)
        gate.fusedDecode = true
        let (ik, sk) = gate(x)
        eval(io, so, ik, sk)
        n += 1
        if arrayEqual(io, ik).item(Bool.self) { idxEqual += 1 }
        if arrayEqual(so, sk).item(Bool.self) { scoreEqual += 1 }
        worst = max(worst, abs(so - sk).max().item(Float.self))
        if seed == 0 { print("dtypes op=\(io.dtype),\(so.dtype) fused=\(ik.dtype),\(sk.dtype) shape=\(ik.shape) idx=\(ik.asArray(UInt32.self)) vs \(io.asArray(UInt32.self))") }
    }
    print("router: indices_equal=\(idxEqual)/\(n) scores_bitwise=\(scoreEqual)/\(n) max|dscore|=\(worst)")
    exit(0)
}
if args.contains("--hc-exact") {
    for (li, layer) in text.model.layers.enumerated() {
        for (name, hc, norm) in [("attn", layer.attnHC, layer.inputLayerNorm), ("ffn", layer.ffnHC, layer.postAttentionLayerNorm)] {
            let x = withRandomState(MLXRandom.RandomState(seed: UInt64(7 + li))) {
                (0.5 * MLXRandom.normal([1, 1, 4, 4096])).asType(.bfloat16)
            }
            let z = MLXFast.rmsNorm(x.asType(.float32).reshaped(1, 1, 4 * 4096), weight: MLXArray.mlxNone, eps: hc.normEps)
            let mixOps = matmul(z, hc.fn.T)
            let mixK = glm5NextHCMix(x, fn: hc.fn, eps: hc.normEps)!
            hc.fusedDecode = false
            let (nOps, pOps, cOps) = hc.normalizedBranchInput(x, norm: norm)
            hc.fusedDecode = true
            let (nK, pK, cK) = hc.normalizedBranchInput(x, norm: norm)
            eval(mixOps, mixK, nOps, pOps, cOps, nK, pK, cK)
            let direct = glm5NextHCNorm(x, mixes: mixK, scale: hc.scale, base: hc.base, normWeight: norm.weight, sinkhornIterations: hc.sinkhornIterations, hcEps: hc.hcEps, normEps: norm.eps)
            if li == 0 { print("direct_engaged=\(direct != nil) scale=\(hc.scale.shape) \(hc.scale.dtype) base=\(hc.base.shape) \(hc.base.dtype) mixes=\(mixK.shape) training=\(hc.training)") }
            let mixBit = arrayEqual(mixOps, mixK).item(Bool.self)
            let dn = abs(nOps.asType(.float32) - nK.asType(.float32)).max().item(Float.self)
            let nBitFrac = (nOps .== nK).asType(.float32).mean().item(Float.self)
            let dp = abs(pOps - pK).max().item(Float.self)
            let dc = abs(cOps - cK).max().item(Float.self)
            print("L\(li) \(name): mix_bitwise=\(mixBit) max|dmix|=\(abs(mixOps - mixK).max().item(Float.self)) normed max|d|=\(dn) equal_frac=\(nBitFrac) post max|d|=\(dp) comb max|d|=\(dc) normdt=\(norm.weight.dtype)")
        }
    }
    exit(0)
}
if args.contains("--kda-engaged") {
    let attn = text.model.layers[0].selfAttn as! GLM5NextLinearAttention
    let mc = cache[0] as! MambaCache
    let x = (0.5 * MLXRandom.normal([1, 1, 4096])).asType(.bfloat16)
    let r = glm5NextKDADecodeStep(
        q: attn.qProj(x), k: attn.kProj(x), v: attn.vProj(x),
        aPre: attn.forgetGate.project(x), gatePre: attn.gBProj(attn.gAProj(x)), bRaw: attn.bProj(x),
        convState: mc[0]!, convWeight: attn.conv1d.weight,
        aLog: attn.forgetGate.aLog, dtBias: attn.forgetGate.dtBias, normWeight: attn.oNorm.weight,
        state: mc[1]!, heads: attn.numHeads, headDim: attn.headDim,
        lowerBound: attn.forgetGate.lowerBound!, normEps: attn.oNorm.eps)
    print("engaged=\(r != nil) qdt=\(attn.qProj(x).dtype) conv=\(mc[0]!.shape) \(mc[0]!.dtype) w=\(attn.conv1d.weight.shape) \(attn.conv1d.weight.dtype) norm=\(attn.oNorm.weight.dtype) alog=\(attn.forgetGate.aLog.dtype) dt=\(attn.forgetGate.dtBias.dtype) b=\(attn.bProj(x).dtype) a=\(attn.forgetGate.project(x).dtype) state=\(mc[1]!.dtype)")
    exit(0)
}
if args.contains("--kda-exact") {
    // Fused vs op path on real layer weights over several decode steps from the prefilled cache.
    for li in 0 ..< 3 {
        let attn = text.model.layers[li].selfAttn as! GLM5NextLinearAttention
        let base = cache[li] as! MambaCache
        let fusedCache = base.copy() as! MambaCache
        let opCache = base.copy() as! MambaCache
        var worstY: Float = 0, worstS: Float = 0, worstC: Float = 0
        var bitwise = true
        for step in 0 ..< 6 {
            let x = withRandomState(MLXRandom.RandomState(seed: UInt64(100 + step))) {
                (0.5 * MLXRandom.normal([1, 1, 4096])).asType(.bfloat16)
            }
            attn.fusedDecode = true
            let yf = attn(x, cache: fusedCache)
            attn.fusedDecode = false
            let yo = attn(x, cache: opCache)
            attn.fusedDecode = true
            eval(yf, yo, fusedCache[0]!, fusedCache[1]!, opCache[0]!, opCache[1]!)
            let dy = abs(yf.asType(.float32) - yo.asType(.float32)).max().item(Float.self)
            let ds = abs(fusedCache[1]! - opCache[1]!).max().item(Float.self)
            let dc = abs(fusedCache[0]!.asType(.float32) - opCache[0]!.asType(.float32)).max().item(Float.self)
            if !(arrayEqual(yf, yo).item(Bool.self) && arrayEqual(fusedCache[1]!, opCache[1]!).item(Bool.self) && arrayEqual(fusedCache[0]!, opCache[0]!).item(Bool.self)) { bitwise = false }
            worstY = max(worstY, dy); worstS = max(worstS, ds); worstC = max(worstC, dc)
        }
        print("layer \(li): bitwise=\(bitwise) max|dy|=\(worstY) max|dstate|=\(worstS) max|dconv|=\(worstC) offset=\(fusedCache.offset)/\(opCache.offset)")
    }
    exit(0)
}
if args.contains("--ops") {
    let attn = text.model.layers[0].selfAttn as! GLM5NextLinearAttention
    let mc = cache[0] as! MambaCache
    let x = (0.1 * MLXRandom.normal([1, 1, 4096])).asType(.bfloat16)
    eval(x)
    let n = 64
    func bench(_ name: String, _ f: (MLXArray) -> MLXArray, _ x0: MLXArray) {
        var y = x0
        eval(f(y))
        let t = Date()
        for _ in 0 ..< n { y = f(y) }
        eval(y)
        print(String(format: "%@ us_per_op=%.1f", name, Date().timeIntervalSince(t) * 1e6 / Double(n)))
    }
    // Each f maps its output back to an input of the same shape so the chain is dependent.
    bench("qProj4096x8192", { attn.qProj($0)[0..., 0..., ..<4096] }, x)
    bench("oProj8192x4096", { attn.oProj(concatenated([$0, $0], axis: -1)) }, x)
    let convIn = concatenated([mc[0]!, concatenated([attn.qProj(x), attn.kProj(x), attn.vProj(x)], axis: -1)], axis: 1)
    eval(convIn)
    bench("conv1d_grouped", { y in concatenated([convIn[0..., ..<3, 0...], silu(attn.conv1d(y))], axis: 1) }, convIn)
    bench("rmsnorm_f32", { MLXFast.rmsNorm($0.asType(.float32), weight: MLXArray.mlxNone, eps: 1e-8).asType(.bfloat16) }, x)
    bench("sigmoid", { sigmoid($0) }, x)
    bench("add", { $0 + 1 }, x)
    let fg = attn.forgetGate
    bench("forget_gate", { fg($0).reshaped(1, 1, 8192)[0..., 0..., ..<4096].asType(.bfloat16) }, x)
    let shape = [1, 1, 64, 128]
    let q = (0.1 * MLXRandom.normal(shape)).asType(.bfloat16)
    let st = mc[1]!
    let g = MLXArray.ones(shape, dtype: .float32) * 0.9
    let beta = MLXArray.ones([1, 1, 64], dtype: .bfloat16) * 0.5
    eval(q, g, beta)
    bench("gated_delta_state", { s in gatedDeltaUpdateVectorized(q: q, k: q, v: q, g: g, beta: beta, state: s, useKernel: true).1 }, st)
    let hc = text.model.layers[0].attnHC
    let hx = (0.1 * MLXRandom.normal([1, 1, 4, 4096])).asType(.bfloat16)
    eval(hx)
    bench("hc_collapse", { h in let (a, _, _) = hc(h); return broadcast(expandedDimensions(a, axis: 2), to: [1, 1, 4, 4096]) }, hx)
    let moe = text.model.layers[3].mlp as! GLM5NextMoE
    bench("moe_layer", { moe($0) }, x)
    bench("moe_gate_select", { y in let (i, w) = moe.gate(y); return y + (i.asType(.bfloat16).sum() + w.asType(.bfloat16).sum()) * 0 }, x)
    let dense = text.model.layers[0].mlp as! GLM5NextMLP
    bench("dense_mlp", { dense($0) }, x)
    exit(0)
}
if args.contains("--kda-profile") {
    // Sub-op synchronous timing of KDA layer 0 at decode, after warm-up.
    let attn = text.model.layers[0].selfAttn as! GLM5NextLinearAttention
    let mc = cache[0] as! MambaCache
    let x = (0.1 * MLXRandom.normal([1, 1, 4096])).asType(.bfloat16)
    eval(x)
    for rep in 0 ..< 4 {
        var t = Date()
        var line = "rep \(rep):"
        func lap(_ name: String, _ arrays: MLXArray...) {
            eval(arrays)
            line += String(format: " %@=%.2f", name, Date().timeIntervalSince(t) * 1000)
            t = Date()
        }
        let (B, L) = (1, 1)
        let mixed = concatenated([attn.qProj(x), attn.kProj(x), attn.vProj(x)], axis: -1)
        lap("qkv", mixed)
        let convInput = concatenated([mc[0]!, mixed], axis: 1)
        let convOut = silu(attn.conv1d(convInput))
        lap("conv", convOut)
        let parts = split(convOut, indices: [attn.projectionDim, 2 * attn.projectionDim], axis: -1)
        let shape = [B, L, attn.numHeads, attn.headDim]
        let eps = 1e-6 / Float(attn.headDim)
        let scale = pow(Float(attn.headDim), -0.5)
        let q = (MLXFast.rmsNorm(parts[0].reshaped(shape).asType(.float32), weight: MLXArray.mlxNone, eps: eps) * (scale * scale)).asType(x.dtype)
        let k = (MLXFast.rmsNorm(parts[1].reshaped(shape).asType(.float32), weight: MLXArray.mlxNone, eps: eps) * scale).asType(x.dtype)
        let v = parts[2].reshaped(shape)
        lap("qknorm", q, k, v)
        let decay = attn.forgetGate(x)
        lap("forget", decay)
        let beta = sigmoid(attn.bProj(x))
        lap("beta", beta)
        let (out, _) = gatedDeltaUpdateVectorized(q: q, k: k, v: v, g: decay, beta: beta, state: mc[1], useKernel: true)
        lap("delta", out)
        let gate = attn.gBProj(attn.gAProj(x)).reshaped(shape)
        lap("gate", gate)
        let y = attn.oProj(attn.oNorm(out, gate: gate).reshaped(B, L, -1))
        lap("onorm+oproj", y)
        print(line)
    }
    // Whole layer, unsynced inside, 20 reps.
    var t0 = Date()
    for _ in 0 ..< 20 { let mc2 = mc.copy() as! MambaCache; eval(attn(x, cache: mc2)) }
    print(String(format: "kda_layer_ms=%.2f", Date().timeIntervalSince(t0) * 1000 / 20))
    let moeLayer = text.model.layers[3]
    let mlp = moeLayer.mlp as! GLM5NextMoE
    t0 = Date()
    for _ in 0 ..< 20 { eval(mlp(x)) }
    print(String(format: "moe_ms=%.2f", Date().timeIntervalSince(t0) * 1000 / 20))
    let dense = text.model.layers[0].mlp as! GLM5NextMLP
    t0 = Date()
    for _ in 0 ..< 20 { eval(dense(x)) }
    print(String(format: "dense_mlp_ms=%.2f", Date().timeIntervalSince(t0) * 1000 / 20))
    let hc = text.model.layers[0].attnHC
    let hx = (0.1 * MLXRandom.normal([1, 1, 4, 4096])).asType(.bfloat16)
    eval(hx)
    t0 = Date()
    for _ in 0 ..< 20 { let (a, b, c) = hc(hx); eval(a, b, c) }
    print(String(format: "hc_collapse_ms=%.2f", Date().timeIntervalSince(t0) * 1000 / 20))
    t0 = Date()
    for _ in 0 ..< 20 { eval(MLXArray(0) + 1) }
    print(String(format: "empty_eval_ms=%.2f", Date().timeIntervalSince(t0) * 1000 / 20))
    exit(0)
}
if args.contains("--deferred-exact") {
    let c1 = cache.map { $0.copy() }
    let c2 = cache.map { $0.copy() }
    var tok = token
    for step in 0 ..< 8 {
        text.model.deferredDecode = true
        let a = model(tok.reshaped(1, 1), cache: c1)
        text.model.deferredDecode = false
        let b = model(tok.reshaped(1, 1), cache: c2)
        eval(a, b)
        let eq = arrayEqual(a, b).item(Bool.self)
        print("step \(step): logits_bitwise=\(eq) max|d|=\(abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self))")
        tok = argMax(b[0, -1, 0...], axis: -1)
    }
    exit(0)
}
if args.contains("--module-census") {
    let x = (0.5 * MLXRandom.normal([1, 1, 4096])).asType(.bfloat16)
    eval(x)
    let moe = text.model.layers[3].mlp as! GLM5NextMoE
    let dense = text.model.layers[0].mlp as! GLM5NextMLP
    let kda = text.model.layers[0].selfAttn as! GLM5NextLinearAttention
    let dsa = text.model.layers[3].selfAttn as! GLM5NextAttention
    let modules: [(String, () -> MLXArray)] = [
        ("moe_ffn", { moe(x) }),
        ("dense_ffn", { dense(x) }),
        ("kda_attn", { kda(x, cache: (cache[0] as! MambaCache).copy() as? MambaCache) }),
        ("dsa_attn", { dsa(x, cache: (cache[3].copy() as! GLM5NextAttentionCache), previousTopk: nil).0 }),
        ("head", { text.lmHead!(text.model.norm(x)) }),
    ]
    for (name, f) in modules {
        eval(f())
        DispatchCensus.counts = [:]
        DispatchCensus.enabled = true
        eval(f())
        DispatchCensus.enabled = false
        print("== \(name)")
        DispatchCensus.report(steps: 1)
    }
    exit(0)
}
if args.contains("--gpu-profile") {
    // Per-kernel GPU time: run with MLX_MAX_OPS_PER_BUFFER=0 so each command
    // buffer holds one kernel. Without it, the per-step GPU busy time and the
    // command-buffer count still show how much of a step the GPU is idle.
    var tok = token
    for _ in 0 ..< 3 {
        tok = argMax(model(tok.reshaped(1, 1), cache: cache)[0, -1, 0...], axis: -1)
        eval(tok)
    }
    let steps = opt("--profile-steps", 20)
    DispatchCensus.reset()
    DispatchCensus.enabled = true
    let t0 = Date()
    for _ in 0 ..< steps {
        tok = argMax(model(tok.reshaped(1, 1), cache: cache)[0, -1, 0...], axis: -1)
        eval(tok)
    }
    let wall = Date().timeIntervalSince(t0) / Double(steps)
    DispatchCensus.enabled = false
    DispatchCensus.group.wait()
    let busy = DispatchCensus.busyPerStep(steps: steps)
    let ops = ProcessInfo.processInfo.environment["MLX_MAX_OPS_PER_BUFFER"] ?? "default"
    print(String(format: "gpu-profile ops_per_buffer=%@ wall_ms=%.2f gpu_busy_ms=%.2f idle_ms=%.2f cmdbufs/step=%.1f dispatches/step=%.1f", ops, wall * 1e3, busy * 1e3, (wall - busy) * 1e3, Double(DispatchCensus.intervals.count) / Double(steps), Double(DispatchCensus.counts.values.reduce(0, +)) / Double(steps)))
    if ops == "0" { DispatchCensus.gpuReport(steps: steps) }
    exit(0)
}
if args.contains("--census") {
    // N synchronous decode steps for dispatch counting under xctrace.
    var tok = token
    for _ in 0 ..< 3 {  // warm-up (pipeline compiles)
        tok = argMax(model(tok.reshaped(1, 1), cache: cache)[0, -1, 0...], axis: -1)
        eval(tok)
    }
    if args.contains("--no-fused-census") {
        text.model.deferredDecode = false
        for layer in text.model.layers {
            layer.attnHC.fusedDecode = false
            layer.ffnHC.fusedDecode = false
            (layer.selfAttn as? GLM5NextLinearAttention)?.fusedDecode = false
            (layer.mlp as? GLM5NextMoE)?.gate.fusedDecode = false
        }
    }
    let steps = opt("--census-steps", 10)
    DispatchCensus.enabled = true
    for _ in 0 ..< steps {
        tok = argMax(model(tok.reshaped(1, 1), cache: cache)[0, -1, 0...], axis: -1)
        eval(tok)
    }
    DispatchCensus.enabled = false
    DispatchCensus.report(steps: steps)
    exit(0)
}
func setFused(_ on: Bool) {
    text.model.deferredDecode = on
    for layer in text.model.layers {
        layer.attnHC.fusedDecode = on
        layer.ffnHC.fusedDecode = on
        (layer.selfAttn as? GLM5NextLinearAttention)?.fusedDecode = on
        (layer.mlp as? GLM5NextMoE)?.gate.fusedDecode = on
        (layer.selfAttn as? GLM5NextAttention)?.indexer?.fusedDecode = on
    }
}
/// Steady-state decode step (ms): median of `n` synchronous steps after 3 warm-ups.
func stepMedian(_ label: String, _ n: Int) -> Double {
    var tok = token
    var times: [Double] = []
    for rep in 0 ..< (n + 3) {
        let a = Date()
        let next = argMax(model(tok.reshaped(1, 1), cache: cache)[0, -1, 0...], axis: -1)
        eval(next)
        if rep >= 3 { times.append(Date().timeIntervalSince(a) * 1000) }
        tok = next
    }
    times.sort()
    let median = times[times.count / 2]
    print(String(format: "%@ step_ms_median=%.2f tok_s=%.2f min=%.2f max=%.2f", label, median, 1000 / median, times.first!, times.last!))
    return median
}
if let oracle {
    // Teacher-forced decode against the oracle's top-16 logits per config.
    func configure(_ name: String) {
        let hcOn = name == "fused"
        let othersOn = name != "all-op"
        text.model.deferredDecode = hcOn
        for layer in text.model.layers {
            layer.attnHC.fusedDecode = hcOn
            layer.ffnHC.fusedDecode = hcOn
            (layer.selfAttn as? GLM5NextLinearAttention)?.fusedDecode = othersOn
            (layer.mlp as? GLM5NextMoE)?.gate.fusedDecode = othersOn
            (layer.selfAttn as? GLM5NextAttention)?.indexer?.fusedDecode = othersOn
        }
    }
    let steps = min(oracle.top_idx.count, opt("--oracle-steps", 16))
    for name in ["fused", "hc-op", "all-op"] {
        configure(name)
        let c = cache.map { $0.copy() }
        var logits = last
        var line = "\(name):"
        var worst: (Float, Int, Int) = (0, 0, 0)
        for step in 0 ..< steps {
            if step > 0 {
                logits = model(MLXArray([Int32(oracle.greedy[step - 1])]).reshaped(1, 1), cache: c)[0, -1, 0...]
                    .asType(.float32)
            }
            let idx = oracle.top_idx[step]
            let got = take(logits, MLXArray(idx.map(Int32.init))).asArray(Float.self)
            var stepMax: Float = 0
            var rank = 0
            for (r, (g, o)) in zip(got, oracle.top_logit[step]).enumerated() where abs(g - o) > stepMax {
                stepMax = abs(g - o)
                rank = r
            }
            let top = argMax(logits).item(Int.self)
            line += String(format: " %.3g%@", stepMax, top == oracle.greedy[step] ? "" : "!")
            if stepMax > worst.0 { worst = (stepMax, step, rank) }
        }
        print(line)
        let (d, st, r) = worst
        print(String(format: "  worst step %d: |d|=%.4f at oracle rank %d (token %d, oracle %.4f)", st, d, r, oracle.top_idx[st][r], oracle.top_logit[st][r]))
    }
    configure("fused")
    if !args.contains("--studio") && !profile { exit(0) }
}
if args.contains("--studio") {
    // One load: the residency fix and the fused kernels measured on the full model.
    if wiredTicket == nil {
        _ = stepMedian("unwired fused", 5)
        let cap = GPU.maxRecommendedWorkingSetBytes() ?? 0
        let ticket = WiredMemoryTicket(size: cap, policy: MLXLMCommon.WiredFixedPolicy(limit: cap), manager: .shared, kind: .active)
        print("wired_limit_applied=\(await ticket.start()) cap=\(cap)")
        wiredTicket = ticket
    }
    _ = stepMedian("wired fused", 31)
    setFused(false)
    _ = stepMedian("wired op-path", 31)
    setFused(true)
    _ = stepMedian("wired fused again", 31)
}
if profile {
    // Per-layer synchronous timing of one decode step, repeated.
    let inner = text.model
    for rep in 0 ..< 3 {
        var h = repeated(
            expandedDimensions(inner.embedTokens(token.reshaped(1, 1)), axis: 2),
            count: inner.hcMult, axis: 2)
        eval(h)
        var topk: MLXArray?
        var line = "rep \(rep):"
        for (i, layer) in inner.layers.enumerated() {
            // attn half
            let s0 = Date()
            let (collapsed, post, comb) = layer.attnHC(h)
            eval(collapsed, post, comb)
            let s1 = Date()
            let normed = layer.inputLayerNorm(collapsed)
            var attention: MLXArray
            if layer.isLinear {
                attention = (layer.selfAttn as! GLM5NextLinearAttention)(
                    normed, cache: cache[i] as? MambaCache)
            } else {
                var t: MLXArray?
                (attention, t) = (layer.selfAttn as! GLM5NextAttention)(
                    normed, cache: cache[i] as? GLM5NextAttentionCache, previousTopk: topk)
                topk = t
            }
            eval(attention)
            let s2 = Date()
            let hh = glm5NextHCExpandForBench(attention, h, post, comb)
            let (ffnIn, ffnPost, ffnComb) = layer.ffnHC(hh)
            eval(ffnIn, ffnPost, ffnComb)
            let s3 = Date()
            let ffnOut = (layer.mlp as! UnaryLayer)(layer.postAttentionLayerNorm(ffnIn))
            eval(ffnOut)
            let s4 = Date()
            h = glm5NextHCExpandForBench(ffnOut, hh, ffnPost, ffnComb)
            eval(h)
            let s5 = Date()
            func ms(_ a: Date, _ b: Date) -> String { String(format: "%.1f", b.timeIntervalSince(a) * 1000) }
            line += "\n  L\(i) \(layer.isLinear ? "kda" : "dsa") \(layer.mlp is GLM5NextMoE ? "moe" : "mlp"): attnHC=\(ms(s0, s1)) attn=\(ms(s1, s2)) ffnHC=\(ms(s2, s3)) ffn=\(ms(s3, s4)) expand=\(ms(s4, s5))"
        }
        let s6 = Date()
        let logits = text.lmHead!(inner.norm(h.mean(axis: 2)))
        eval(logits)
        line += String(format: "\n  head=%.1f", Date().timeIntervalSince(s6) * 1000)
        print(line)
        token = argMax(logits[0, -1, 0...], axis: -1)
        eval(token)
    }
    exit(0)
}

if args.contains("--split") {
    var tok = token
    for rep in 0 ..< 12 {
        let a = Date()
        let logits = model(tok.reshaped(1, 1), cache: cache)[0, -1, 0...]
        let next = argMax(logits, axis: -1)
        let b = Date()
        eval(next)
        let c = Date()
        if rep >= 4 { print(String(format: "build_ms=%.2f eval_ms=%.2f", b.timeIntervalSince(a) * 1000, c.timeIntervalSince(b) * 1000)) }
        tok = next
    }
    exit(0)
}
// Pipelined greedy decode (as TokenIterator / glm-parity).
var tokens: [Int] = []
var topLogits: [Float] = []
var pending = token
let d0 = Date()
var stepTimes: [Double] = []
for step in 0 ..< steps {
    let s = Date()
    let logits = model(pending.reshaped(1, 1), cache: cache)[0, -1, 0...].asType(.float32)
    let next = argMax(logits, axis: -1)
    if syncEach { eval(next) } else { asyncEval(next) }
    tokens.append(pending.item(Int.self))
    if args.contains("--dump-logits"), step < 16 { topLogits.append(logits.max().item(Float.self)) }
    pending = next
    stepTimes.append(Date().timeIntervalSince(s))
    _ = step
}
eval(pending)
let ds = Date().timeIntervalSince(d0)
print("decode_tps=\(String(format: "%.2f", Double(steps) / ds)) step_ms=\(stepTimes.prefix(8).map { String(format: "%.0f", $0 * 1000) }) peak_gb=\(Double(Memory.peakMemory) / 1e9)")
print("tokens=\(tokens.prefix(32))")
if !topLogits.isEmpty { print("top_logits=\(topLogits)") }
_ = ballast.count
if let wiredTicket { _ = await wiredTicket.end() }

func glm5NextHCExpandForBench(_ x: MLXArray, _ residual: MLXArray, _ post: MLXArray, _ comb: MLXArray) -> MLXArray {
    let expanded = expandedDimensions(post, axis: -1) * expandedDimensions(x, axis: 2).asType(.float32)
    let mixed = matmul(comb.swappedAxes(-1, -2), residual.asType(.float32))
    return (expanded + mixed).asType(x.dtype)
}
