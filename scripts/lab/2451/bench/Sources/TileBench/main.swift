// #2451 tile microbench. Method, cells and verdict: scripts/lab/2451/tiles.py.
//
// usage: TileBench run PLAN.json OUT.json
//        TileBench hook-check dense|gather
//
// run: for every plan cell, random affine bf16 weights at the cell's shape (seeded, group 64)
// and a random bf16 input, then blocks in the order control, t1, control, t2, ..., control with
// the cell's env var set to each block's tile (setenv; the fork reads it on every call). Each
// block: two warm calls (the first JIT-compiles a new tile), the output's bits against the
// control output (bf16 viewed as uint16, differing elements counted on the GPU), then `samples`
// samples of `iters` back-to-back calls evaluated together, recorded as ms per call.
// hook-check: sets an invalid tile and runs one call; the fork's hook must throw, so this exits
// non-zero with the env var name on stderr. Exit 3 means the hook is absent.
import Foundation
import MLX

struct Cell: Decodable {
    let id: String
    let family: String
    let name: String
    let rows: Int
    let routing: String?
    let env: String
    let tiles: [String]
    let n: Int
    let k: Int
    let bits: Int
    let count: Int
    let experts: Int?
    let top_k: Int?
    let expert_counts: [Int]?
}

struct Plan: Decodable {
    let seed: Int
    let samples: Int
    let target_ms: Double
    let group_size: Int
    let cells: [Cell]
}

func say(_ s: String) {
    print(s)
    fflush(stdout)
}

func fail(_ s: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(("TileBench: " + s + "\n").data(using: .utf8)!)
    exit(code)
}

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func cpuBrand() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    return String(cString: buf)
}

struct QWeight {
    let wq: MLXArray
    let scales: MLXArray
    let biases: MLXArray
}

/// Affine-quantized random weights [experts?, n, k], built in slices of at most 32 experts.
func makeWeight(experts: Int?, n: Int, k: Int, bits: Int, groupSize: Int, seed: UInt64) -> QWeight {
    var key = MLXRandom.key(seed)
    let total = experts ?? 1
    var parts: [(MLXArray, MLXArray, MLXArray)] = []
    var done = 0
    while done < total {
        let e = min(32, total - done)
        let split = MLXRandom.split(key: key)
        key = split.0
        let shape = experts == nil ? [n, k] : [e, n, k]
        let w = MLXRandom.normal(shape, dtype: .bfloat16, scale: 0.02, key: split.1)
        let q = quantized(w, groupSize: groupSize, bits: bits)
        guard let b = q.biases else { fail("quantized() returned no biases") }
        eval(q.wq, q.scales, b)
        parts.append((q.wq, q.scales, b))
        done += e
    }
    if parts.count == 1 {
        return QWeight(wq: parts[0].0, scales: parts[0].1, biases: parts[0].2)
    }
    let w = QWeight(
        wq: concatenated(parts.map { $0.0 }, axis: 0),
        scales: concatenated(parts.map { $0.1 }, axis: 0),
        biases: concatenated(parts.map { $0.2 }, axis: 0))
    eval(w.wq, w.scales, w.biases)
    return w
}

func setTile(_ env: String, _ tile: String) {
    guard setenv(env, tile, 1) == 0 else { fail("setenv \(env) failed") }
}

func hookCheck(_ family: String) -> Never {
    let gs = 64
    if family == "dense" {
        let w = makeWeight(experts: nil, n: 256, k: 512, bits: 8, groupSize: gs, seed: 1)
        let x = MLXRandom.normal([1, 64, 512], dtype: .bfloat16, key: MLXRandom.key(2))
        setTile("MLX_LAB_2451_QMM_TILE", "7,7,7")
        let y = quantizedMM(x, w.wq, scales: w.scales, biases: w.biases, transpose: true, groupSize: gs, bits: 8)
        eval(y)
    } else if family == "gather" {
        let w = makeWeight(experts: 4, n: 256, k: 512, bits: 4, groupSize: gs, seed: 1)
        let idx = MLXArray((0 ..< 64).map { UInt32($0 / 16) })
        let x = MLXRandom.normal([64, 1, 512], dtype: .bfloat16, key: MLXRandom.key(2))
        setTile("MLX_LAB_2451_GQMM_RHS_TILE", "7,7,7,7,7")
        let y = gatherQuantizedMM(
            x, w.wq, scales: w.scales, biases: w.biases, rhsIndices: idx, transpose: true,
            groupSize: gs, bits: 4, sortedIndices: true)
        eval(y)
    } else {
        fail("hook-check dense|gather")
    }
    say("HOOK_ABSENT \(family): an invalid tile did not throw")
    exit(3)
}

func run(planPath: String, outPath: String) {
    guard let data = FileManager.default.contents(atPath: planPath) else { fail("cannot read \(planPath)") }
    let plan: Plan
    do { plan = try JSONDecoder().decode(Plan.self, from: data) } catch { fail("plan: \(error)") }
    let gs = plan.group_size
    for env in ["MLX_LAB_2451_QMM_TILE", "MLX_LAB_2451_GQMM_RHS_TILE"] { unsetenv(env) }
    var weights: [String: QWeight] = [:]
    var cellsOut: [[String: Any]] = []
    let t0 = nowMs()
    say("BENCH_START cells=\(plan.cells.count) samples=\(plan.samples) target_ms=\(plan.target_ms) device=\(cpuBrand())")
    for (ci, cell) in plan.cells.enumerated() {
        let gather = cell.family == "gather"
        let wkey = "\(cell.family)-\(cell.n)-\(cell.k)-\(cell.bits)"
        if weights[wkey] == nil {
            weights[wkey] = makeWeight(
                experts: gather ? cell.experts : nil, n: cell.n, k: cell.k, bits: cell.bits, groupSize: gs,
                seed: UInt64(plan.seed) &* 1_000_003 &+ UInt64(cell.n &* 31 &+ cell.k &* 7 &+ cell.bits))
        }
        let w = weights[wkey]!
        let xkey = MLXRandom.key(UInt64(plan.seed) &+ UInt64(ci) &+ 17)
        let call: () -> MLXArray
        if gather {
            guard let counts = cell.expert_counts, let topK = cell.top_k, counts.count == cell.experts,
                counts.reduce(0, +) == cell.rows * topK
            else { fail("\(cell.id): bad expert_counts") }
            var idx: [UInt32] = []
            idx.reserveCapacity(cell.rows * topK)
            for (e, c) in counts.enumerated() { idx.append(contentsOf: repeatElement(UInt32(e), count: c)) }
            let indices = MLXArray(idx)
            let x = MLXRandom.normal([cell.rows * topK, 1, cell.k], dtype: .bfloat16, key: xkey)
            eval(x, indices)
            call = {
                gatherQuantizedMM(
                    x, w.wq, scales: w.scales, biases: w.biases, rhsIndices: indices, transpose: true,
                    groupSize: gs, bits: cell.bits, sortedIndices: true)
            }
        } else {
            let x = MLXRandom.normal([1, cell.rows, cell.k], dtype: .bfloat16, key: xkey)
            eval(x)
            call = {
                quantizedMM(
                    x, w.wq, scales: w.scales, biases: w.biases, transpose: true, groupSize: gs,
                    bits: cell.bits)
            }
        }
        guard cell.tiles.count >= 2 else { fail("\(cell.id): needs a control and a candidate") }
        let control = cell.tiles[0]
        var order: [String] = [control]
        for t in cell.tiles.dropFirst() { order += [t, control] }

        // Control output and iteration count.
        setTile(cell.env, control)
        let ref = call()
        eval(ref)
        eval(call())
        let c0 = nowMs()
        let probe = (0 ..< 3).map { _ in call() }
        eval(probe)
        let perCall = max((nowMs() - c0) / 3, 1e-3)
        let iters = min(256, max(1, Int((plan.target_ms / perCall).rounded(.up))))
        let refBits = ref.view(dtype: .uint16)

        var blocks: [[String: Any]] = []
        var bitsOut: [String: Any] = [:]
        for tile in order {
            setTile(cell.env, tile)
            let y = call()
            eval(y)
            eval(call())
            if tile != control && bitsOut[tile] == nil {
                let diff = notEqual(y.view(dtype: .uint16), refBits).asType(.int32).sum()
                let d = Int(diff.item(Int32.self))
                bitsOut[tile] = ["elems_diff": d, "elems": y.size]
            }
            var samples: [Double] = []
            for _ in 0 ..< plan.samples {
                var ys: [MLXArray] = []
                ys.reserveCapacity(iters)
                let s0 = nowMs()
                for _ in 0 ..< iters { ys.append(call()) }
                eval(ys)
                samples.append((nowMs() - s0) / Double(iters))
            }
            blocks.append([
                "tile": tile, "role": tile == control ? "control" : "candidate", "iters": iters,
                "samples_ms": samples,
            ])
        }
        setTile(cell.env, control)
        let meds = blocks.map { b -> Double in
            let s = (b["samples_ms"] as! [Double]).sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        let medStr = zip(order, meds).map { "\($0.0)=\(String(format: "%.4f", $0.1))" }.joined(separator: " ")
        let diffs = cell.tiles.dropFirst().map { t -> String in
            let d = (bitsOut[t] as! [String: Any])["elems_diff"] as! Int
            return "\(t):\(d)"
        }.joined(separator: " ")
        say("BENCH_CELL \(ci + 1)/\(plan.cells.count) \(cell.id) iters=\(iters) median_ms \(medStr) elems_diff \(diffs)")
        cellsOut.append([
            "id": cell.id, "family": cell.family, "name": cell.name, "rows": cell.rows,
            "routing": cell.routing.map { $0 as Any } ?? NSNull(), "n": cell.n, "k": cell.k, "bits": cell.bits,
            "count": cell.count, "env": cell.env, "blocks": blocks, "bits_vs_control": bitsOut,
        ])
        if gather { Memory.clearCache() }
    }
    let doc: [String: Any] = [
        "device": cpuBrand(), "core": ProcessInfo.processInfo.environment["TILE_BENCH_CORE"] ?? "unknown",
        "seed": plan.seed, "samples": plan.samples, "target_ms": plan.target_ms,
        "elapsed_s": (nowMs() - t0) / 1000, "cells": cellsOut,
    ]
    do {
        let out = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
        try out.write(to: URL(fileURLWithPath: outPath))
    } catch { fail("write \(outPath): \(error)") }
    say("BENCH_DONE cells=\(cellsOut.count) elapsed_s=\(String(format: "%.0f", (nowMs() - t0) / 1000))")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "run" where args.count == 4: run(planPath: args[2], outPath: args[3])
case "hook-check" where args.count == 3: hookCheck(args[2])
default: fail("usage: TileBench run PLAN.json OUT.json | TileBench hook-check dense|gather")
}
