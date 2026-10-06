// Lab-only executable mirror of GatedDeltaTests.testCheckpointedUpdateMatchesSplitUpdate
// for hosts without XCTest (Command Line Tools only), extended to the
// Qwen3.6 A3B GDN head layout. Not committed to the fork.
import Foundation
import MLX
import MLXLMCommon

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0
func check(_ ok: Bool, _ label: String) {
    checks += 1
    if !ok { failures += 1; print("FAIL \(label)") } else { print("ok   \(label)") }
}

func run(B: Int, T: Int, Hk: Int, Dk: Int, Hv: Int, Dv: Int, seed: UInt64) {
    MLXRandom.seed(seed)
    let dt = DType.bfloat16
    let q = MLXRandom.normal([B, T, Hk, Dk]).asType(dt)
    let k = MLXRandom.normal([B, T, Hk, Dk]).asType(dt)
    let v = MLXRandom.normal([B, T, Hv, Dv]).asType(dt)
    let a = MLXRandom.normal([B, T, Hv]).asType(dt)
    let b = MLXRandom.normal([B, T, Hv]).asType(dt)
    let aLog = (MLXRandom.normal([Hv]) * MLXArray(0.1)).asType(dt)
    let dtBias = MLXRandom.normal([Hv]).asType(dt)
    let initial = MLXRandom.normal([B, Hv, Dv, Dk]).asType(.float32)
    // Last row right-padded by one column when B > 1.
    var maskValues = [Bool](repeating: true, count: B * T)
    if B > 1 { maskValues[B * T - 1] = false }
    let padded = MLXArray(maskValues, [B, T])
    for mask in [nil, padded] as [MLXArray?] {
        for split in 1 ..< T {
            let (y, ckpt, final) = gatedDeltaUpdateCheckpointed(
                q: q, k: k, v: v, a: a, b: b, aLog: aLog, dtBias: dtBias,
                state: initial, mask: mask, checkpointAfter: split)
            let (y1, s1) = gatedDeltaUpdate(
                q: q[0..., ..<split], k: k[0..., ..<split], v: v[0..., ..<split],
                a: a[0..., ..<split], b: b[0..., ..<split], aLog: aLog, dtBias: dtBias,
                state: initial, mask: mask.map { $0[0..., ..<split] })
            let (y2, s2) = gatedDeltaUpdate(
                q: q[0..., split...], k: k[0..., split...], v: v[0..., split...],
                a: a[0..., split...], b: b[0..., split...], aLog: aLog, dtBias: dtBias,
                state: s1, mask: mask.map { $0[0..., split...] })
            let ySplit = concatenated([y1, y2], axis: 1)
            eval(y, ckpt, final, ySplit, s1, s2)
            let label = "B=\(B) T=\(T) Hk=\(Hk) Dk=\(Dk) Hv=\(Hv) Dv=\(Dv) split=\(split) masked=\(mask != nil)"
            check(arrayEqual(y, ySplit).item(Bool.self), "\(label) y bit-identical")
            check(arrayEqual(ckpt, s1).item(Bool.self), "\(label) checkpoint bit-identical")
            check(arrayEqual(final, s2).item(Bool.self), "\(label) final bit-identical")
        }
    }
}

// Tiny unit shape, then the Qwen3.6 35B-A3B linear-attention layout
// (16 key heads x 128, 32 value heads x 128) at native verify widths.
run(B: 2, T: 6, Hk: 2, Dk: 32, Hv: 4, Dv: 16, seed: 42)
for (B, T) in [(1, 2), (1, 3), (2, 2), (2, 7), (8, 2)] {
    run(B: B, T: T, Hk: 16, Dk: 128, Hv: 32, Dv: 128, seed: UInt64(100 + B * 10 + T))
}
print("checks=\(checks) failures=\(failures)")
print("gdn_checkpoint_harness=\(failures == 0 ? "PASS" : "FAIL")")
exit(failures == 0 ? 0 : 1)
