#if DEBUG || MACPROVIDER_LAB_HARNESS
import ArgumentParser
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Lab probe for issue #1770: isolates MLX small-M 4-bit quantized matmul cost
/// from the model, and checks greedy-decode parity across MLX pins.
///
/// Modes (one JSON line per measurement):
/// - `qmm`: `quantizedMM` on synthetic bf16 4-bit g64 weights, M = 1...max-m.
///   Cycles through enough distinct weight copies (>= 1 GiB) that the system
///   cache cannot hold them, so each matmul streams its weights from DRAM.
/// - `kernel-name`: one GPU quantized matmul whose inputs were built on the CPU
///   stream. Run next to a metallib that lacks the quantized kernels, MLX fails
///   with the exact kernel name its dispatcher picked for that M.
/// - `greedy`: ordinary greedy decode on dense caches for a real model, rows
///   batched together; prints generated token ids per row.
struct MLXSmallMProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mlx-smallm-probe",
        abstract: "Lab-only small-M quantized matmul and greedy parity probe.",
        shouldDisplay: false
    )

    @Option(help: "qmm, kernel-name, greedy, kcheck, kbench, or kreal.")
    var mode: String = "qmm"

    @Option(help: "Comma-separated NxK weight shapes (out x in).")
    var shapes: String = "17408x5120,5120x17408,248320x5120,2048x2048,8192x2048,248320x2048"

    @Option(name: .customLong("max-m"))
    var maxM: Int = 16

    @Option(name: .customLong("m"), help: "Rows for kernel-name mode.")
    var m: Int = 2

    @Option(name: .customLong("model-dir"), help: "Target model snapshot directory (greedy).")
    var modelDir: String?

    @Option(help: "Comma-separated row counts for greedy mode.")
    var batches: String = "1,4"

    @Option(name: .customLong("decode-tokens"))
    var decodeTokens: Int = 64

    @Option(name: .customLong("warmup"))
    var warmup: Int = 3

    @Option(name: .customLong("iters"))
    var iters: Int = 10

    @Option(help: "Comma-separated SmallMQMV configs (kcheck/kbench/kreal), e.g. rb-r4,mma-nt1-ks4.")
    var configs: String = "rb-r4,mma-nt1-ks4"

    @Option(help: "Comma-separated M values for kcheck/kbench/kreal (default 1...max-m).")
    var ms: String?

    @Option(name: .customLong("smallm-qmv"), help: "greedy: route QuantizedLinear M>=2 through SmallMQMV (off, auto, or a config).")
    var smallmQMV: String = "off"

    func run() async throws {
        switch mode {
        case "qmm":
            try runQMM()
        case "kernel-name":
            try runKernelName()
        case "greedy":
            try await runGreedy()
        case "kcheck":
            try runKernelCheck()
        case "kbench":
            try runKernelBench()
        case "kreal":
            try await runKernelReal()
        default:
            throw ValidationError("unknown mode \(mode)")
        }
    }

    func parsedShapes() throws -> [(n: Int, k: Int)] {
        try shapes.split(separator: ",").map { item in
            let parts = item.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { throw ValidationError("bad shape \(item)") }
            return (parts[0], parts[1])
        }
    }

    static func emit(_ record: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    private func runQMM() throws {
        for (n, k) in try parsedShapes() {
            let packedBytes = n * k / 2 + 2 * (n * k / 64) * 2 // 4-bit weights + bf16 scales/biases
            let copies = max(4, (1 << 30) / packedBytes + 1)
            var weights: [(MLXArray, MLXArray, MLXArray?)] = []
            for c in 0 ..< copies {
                let w = MLXRandom.normal([n, k], key: MLXRandom.key(UInt64(c + 1))).asType(.bfloat16) * 0.02
                let q = quantized(w, groupSize: 64, bits: 4)
                eval(q.wq, q.scales, q.biases!)
                weights.append((q.wq, q.scales, q.biases))
            }
            Stream().synchronize()
            var baseline = 0.0
            for rows in 1 ... maxM {
                let x = MLXRandom.normal([rows, k], key: MLXRandom.key(UInt64(1000 + rows))).asType(.bfloat16)
                eval(x)
                var samples: [Double] = []
                for iteration in 0 ..< (warmup + iters) {
                    let outs = weights.map { w, s, b in
                        quantizedMM(x, w, scales: s, biases: b, transpose: true, groupSize: 64, bits: 4)
                    }
                    Stream().synchronize()
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    eval(outs)
                    Stream().synchronize()
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    if iteration >= warmup {
                        samples.append(Double(t1 - t0) / 1e6 / Double(copies))
                    }
                }
                let sorted = samples.sorted()
                let p50 = sorted[sorted.count / 2]
                if rows == 1 { baseline = p50 }
                try Self.emit([
                    "schema": "macprovider.mlx-smallm-probe.qmm.v1",
                    "n": n, "k": k, "m": rows, "copies": copies,
                    "ms_per_matmul_p50": p50,
                    "ms_per_matmul_min": sorted.first ?? 0,
                    "weight_gbps_p50": Double(packedBytes) / (p50 / 1e3) / 1e9,
                    "ratio_vs_m1": p50 / baseline,
                ])
            }
            weights.removeAll()
            Memory.clearCache()
        }
    }

    private func runKernelName() throws {
        guard let (n, k) = try parsedShapes().first else { throw ValidationError("no shape") }
        let cpu = StreamOrDevice.device(.cpu)
        let w = MLXRandom.normal([n, k], key: MLXRandom.key(1), stream: cpu).asType(.bfloat16, stream: cpu)
        let q = quantized(w, groupSize: 64, bits: 4, stream: cpu)
        let x = MLXRandom.normal([m, k], key: MLXRandom.key(2), stream: cpu).asType(.bfloat16, stream: cpu)
        eval(q.wq, q.scales, q.biases!, x)
        print("KERNEL_PROBE n=\(n) k=\(k) m=\(m) dispatching on gpu")
        fflush(stdout)
        let y = quantizedMM(
            x, q.wq, scales: q.scales, biases: q.biases, transpose: true,
            groupSize: 64, bits: 4, stream: .device(.gpu))
        eval(y)
        print("KERNEL_PROBE_NO_ERROR")
    }

    private func runGreedy() async throws {
        guard let modelDir else { throw ValidationError("--model-dir required") }
        await Qwen35TextMTPRegistration.register()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: URL(fileURLWithPath: modelDir, isDirectory: true),
            using: #huggingFaceTokenizerLoader()
        )
        let routed = try await Self.installSmallMRouting(smallmQMV, container: container)
        let smallmLabel = smallmQMV
        let texts = [
            "Explain how a heat pump moves heat from a cold place to a warm place, step by step.",
            "Write a short Python function that returns the n-th Fibonacci number iteratively.",
            "List three differences between TCP and UDP and when you would choose each one.",
            "Summarize the plot of a story about a lighthouse keeper who finds a message in a bottle.",
        ]
        let rowCounts = batches.split(separator: ",").compactMap { Int($0) }
        let steps = decodeTokens
        let modelName = URL(fileURLWithPath: modelDir).deletingLastPathComponent().lastPathComponent
        for rows in rowCounts {
            let line = try await container.perform { context -> String in
                let encoded = (0 ..< rows).map { context.tokenizer.encode(text: texts[$0 % texts.count]) }
                let length = encoded.map(\.count).min() ?? 0
                let flat = encoded.flatMap { $0.prefix(length).map { Int32($0) } }
                let cache = try context.model.newCache(parameters: nil)
                var logits = context.model(
                    LMInput.Text(tokens: MLXArray(flat, [rows, length])), cache: cache, state: nil
                ).logits
                var generated = Array(repeating: [Int](), count: rows)
                for _ in 0 ..< steps {
                    let next = argMax(logits[0..., -1], axis: -1).asType(.int32)
                    let ids = next.asArray(Int32.self)
                    for r in 0 ..< rows { generated[r].append(Int(ids[r])) }
                    logits = context.model(
                        LMInput.Text(tokens: next.reshaped([rows, 1])), cache: cache, state: nil
                    ).logits
                }
                let record: [String: Any] = [
                    "schema": "macprovider.mlx-smallm-probe.greedy.v1",
                    "model": modelName, "rows": rows, "prompt_tokens": length,
                    "smallm_qmv": smallmLabel, "smallm_routed_layers": routed,
                    "tokens": generated,
                ]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                return String(decoding: data, as: UTF8.self)
            }
            print(line)
            fflush(stdout)
        }
    }
}
#endif
