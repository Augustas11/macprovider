// Lab-only executable mirror of Tests/MLXLMTests/Qwen35FusedMoETests.swift
// for hosts without XCTest (Command Line Tools only). Not committed.
import Foundation
import MLX
import MLXLMCommon
import MLXNN
@testable import MLXLLM

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ label: String) {
    if !ok { failures += 1; print("FAIL \(label)") } else { print("ok   \(label)") }
}
func makeBlock(seed: UInt64, expectFusable: Bool = true) throws -> Qwen35SparseMoeBlock {
    let json = """
        {"hidden_size": 2048, "num_experts": 256, "num_experts_per_tok": 8,
         "moe_intermediate_size": 256, "shared_expert_intermediate_size": 256,
         "norm_topk_prob": true}
        """
    let config = try JSONDecoder().decode(Qwen35TextConfiguration.self, from: Data(json.utf8))
    MLXRandom.seed(seed)
    let block = Qwen35SparseMoeBlock(config)
    let params = block.parameters().flattened().map { key, value -> (String, MLXArray) in
        let scaled = key == "gate.weight" ? value * 16 : value
        return (key, scaled.asType(.bfloat16))
    }
    block.update(parameters: ModuleParameters.unflattened(params))
    quantize(model: block) { path, _ in
        path == "gate" || path == "shared_expert_gate" ? (64, 8) : (64, 4)
    }
    eval(block)
    if expectFusable { check(Qwen35FusedMoE.isFusable(block), "fusable seed=\(seed)") }
    return block
}
func input(_ tokens: Int, seed: UInt64) -> MLXArray {
    MLXRandom.seed(seed)
    let x = MLXRandom.normal([1, tokens, 2048]).asType(.bfloat16)
    eval(x); return x
}
func bitEqual(_ a: [MLXArray], _ b: [MLXArray], _ label: String) {
    guard a.count == b.count else { check(false, "\(label) count"); return }
    for (i, (x, y)) in zip(a, b).enumerated() {
        let diff = (x .!= y).asType(.int32).sum().item(Int.self)
        check(diff == 0, "\(label) call \(i) (\(diff) differ)")
    }
}
func fused(_ b: Qwen35SparseMoeBlock, _ x: MLXArray) -> MLXArray {
    guard let y = Qwen35FusedMoE.forward(b, x) else {
        check(false, "expected fused path shape=\(x.shape)"); return x
    }
    return y
}

print("enabled=\(Qwen35FusedMoE.enabled)")
// 1. Prefill-shaped 8-token row falls back to stock.
do {
    let block = try makeBlock(seed: 4)
    let x = input(8, seed: 48)
    check(Qwen35FusedMoE.forward(block, x) == nil, "8-token row returns nil")
    let automatic = block(x); let stock = block.stockForward(x); eval(automatic, stock)
    bitEqual([automatic], [stock], "8-token row automatic stock fallback")
}
// 2. Default fused at T=1.
do {
    let block = try makeBlock(seed: 5)
    let x = input(1, seed: 51)
    let a = block(x); let f = fused(block, x); eval(a, f)
    bitEqual([a], [f], "T=1 automatic fused path")
}
// 3. Overlapping calls (one stream / two streams) match serial.
do {
    let blocks = [try makeBlock(seed: 1), try makeBlock(seed: 2)]
    for tokens in [1, 2, 4, 7] {
        var calls: [(Qwen35SparseMoeBlock, MLXArray)] = []
        for (b, block) in blocks.enumerated() {
            for v in 0 ..< 2 { calls.append((block, input(tokens, seed: UInt64(100 * tokens + 10 * b + v)))) }
        }
        var serial: [MLXArray] = []
        for (block, x) in calls { let y = fused(block, x); eval(y); serial.append(y) }
        for _ in 0 ..< 3 {
            let together = calls.map { fused($0.0, $0.1) }; eval(together)
            bitEqual(together, serial, "T=\(tokens) one stream")
            let half = calls.count / 2
            let a = Stream.withNewDefaultStream { calls[..<half].map { fused($0.0, $0.1) } }
            let b = Stream.withNewDefaultStream { calls[half...].map { fused($0.0, $0.1) } }
            eval(a + b)
            bitEqual(a + b, serial, "T=\(tokens) two streams")
        }
    }
}
// 4. Batch invariance + agreement with stock, T=2/4/7.
do {
    let block = try makeBlock(seed: 3)
    for tokens in [2, 4, 7] {
        let x = input(tokens, seed: UInt64(7 + tokens))
        let f = fused(block, x)
        let singles = concatenated((0 ..< tokens).map { fused(block, x[0..., $0 ..< ($0 + 1)]) }, axis: 1)
        let stock = block.stockForward(x)
        eval(f, singles, stock)
        bitEqual([f], [singles], "T=\(tokens) batch invariance")
        let ff = f.asType(.float32), s = stock.asType(.float32)
        let rel = (sqrt(((ff - s) * (ff - s)).sum()) / sqrt((s * s).sum())).item(Float.self)
        check(rel < 0.02, "T=\(tokens) fused vs stock rel \(rel)")
    }
}
// 5. NEW: chunked decode/verify batches above 7 flattened tokens.
do {
    let block = try makeBlock(seed: 6)
    for (rows, rowTokens) in [(8, 1), (9, 1), (16, 1), (4, 2), (5, 2), (8, 2)] {
        MLXRandom.seed(UInt64(1000 + 10 * rows + rowTokens))
        let x = MLXRandom.normal([rows, rowTokens, 2048]).asType(.bfloat16); eval(x)
        let batched = fused(block, x)
        let automatic = block(x)
        var singles: [MLXArray] = []
        for r in 0 ..< rows { for t in 0 ..< rowTokens { singles.append(fused(block, x[r ..< (r + 1), t ..< (t + 1)])) } }
        let expected = concatenated(singles, axis: 0).reshaped(x.shape)
        eval(batched, automatic, expected)
        let label = "rows=\(rows) rowTokens=\(rowTokens)"
        check(batched.shape == x.shape, "\(label) shape")
        bitEqual([batched], [expected], "\(label) batch invariance")
        bitEqual([automatic], [batched], "\(label) automatic fused path")
    }
}
// 6. NEW: mismatched quantized companion layout is not fusable.
do {
    for key in ["shared_expert.down_proj.scales", "switch_mlp.gate_proj.biases"] {
        let block = try makeBlock(seed: 8, expectFusable: false)
        let params = Dictionary(uniqueKeysWithValues: block.parameters().flattened())
        guard let original = params[key] else { check(false, "missing \(key)"); continue }
        let truncated = original[.ellipsis, 0 ..< (original.dim(-1) - 1)]
        _ = block.update(parameters: ModuleParameters.unflattened([(key, truncated)]))
        eval(block)
        check(!Qwen35FusedMoE.isFusable(block), "\(key) mismatched layout not fusable")
        check(Qwen35FusedMoE.forward(block, input(1, seed: 81)) == nil, "\(key) mismatched layout forward nil")
    }
}
print(failures == 0 ? "qwen35_fused_chunked_harness=PASS" : "qwen35_fused_chunked_harness=FAIL failures=\(failures)")
exit(failures == 0 ? 0 : 1)
