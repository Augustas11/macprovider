#if DEBUG || MACPROVIDER_LAB_HARNESS
import Accelerate
import Darwin
import Foundation
import MacProviderCore
import MLX

/// Trace audit lab opening (#2419): block `l` at position `p` of a committed
/// request, recomputed in float32 from the stored float16 residuals.
///
/// The provider reads the stored block-l inputs of positions 0...p (K and V
/// of every earlier position are recomputed from them), the committed next
/// residual at p (block l+1 input, or the final residual for the last
/// block) and the token pair at p, and recomputes the block with the
/// checkpoint's weights (dequantized to float32; matmuls in Accelerate
/// float32). The opening carries every committed leaf it used with its
/// RFC 6962 inclusion path, and the recomputed internal leaves.
struct TraceAuditLabModelConfig {
    let hidden: Int
    let heads: Int
    let kvHeads: Int
    let headDim: Int
    let intermediate: Int
    let blocks: Int
    let rmsEps: Float
    let ropeTheta: Double
    let ropeTraditional: Bool
    let ropeScaling: [String: Any]?
    let quantization: [String: Any]?
    let modelType: String

    init(modelDirectory: URL) throws {
        let data = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        guard let c = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TraceAuditStoreError.io("config.json")
        }
        func int(_ k: String) -> Int? { (c[k] as? NSNumber)?.intValue }
        guard let hidden = int("hidden_size"), let heads = int("num_attention_heads"),
              let blocks = int("num_hidden_layers"), let intermediate = int("intermediate_size") else {
            throw TraceAuditStoreError.io("config.json fields")
        }
        self.hidden = hidden
        self.heads = heads
        self.kvHeads = int("num_key_value_heads") ?? heads
        self.headDim = int("head_dim") ?? hidden / heads
        self.intermediate = intermediate
        self.blocks = blocks
        self.rmsEps = (c["rms_norm_eps"] as? NSNumber)?.floatValue ?? 1e-6
        self.ropeTheta = (c["rope_theta"] as? NSNumber)?.doubleValue ?? 10_000
        self.ropeTraditional = (c["rope_traditional"] as? Bool) ?? false
        self.ropeScaling = c["rope_scaling"] as? [String: Any]
        self.quantization = (c["quantization"] as? [String: Any]) ?? (c["quantization_config"] as? [String: Any])
        self.modelType = (c["model_type"] as? String) ?? ""
    }

    /// Inverse RoPE frequencies, as mlx-lm builds them (default, linear,
    /// llama3). Linear scaling divides positions by the factor.
    func ropeInverseFrequencies() -> (inv: [Double], positionScale: Double) {
        let half = headDim / 2
        var freqs = (0 ..< half).map { pow(ropeTheta, Double(2 * $0) / Double(headDim)) }
        var positionScale = 1.0
        let type = (ropeScaling?["type"] as? String) ?? (ropeScaling?["rope_type"] as? String)
        let factor = (ropeScaling?["factor"] as? NSNumber)?.doubleValue ?? 1
        if type == "linear" {
            positionScale = 1 / factor
        } else if type == "llama3" {
            let low = (ropeScaling?["low_freq_factor"] as? NSNumber)?.doubleValue ?? 1
            let high = (ropeScaling?["high_freq_factor"] as? NSNumber)?.doubleValue ?? 4
            let old = (ropeScaling?["original_max_position_embeddings"] as? NSNumber)?.doubleValue ?? 8192
            let lowWave = old / low
            let highWave = old / high
            freqs = freqs.map { f in
                let wave = 2 * Double.pi * f
                if wave > lowWave { return f * factor }
                if wave > highWave && wave < lowWave {
                    let smooth = (old / wave - low) / (high - low)
                    return f / ((1 - smooth) / factor + smooth)
                }
                return f
            }
        }
        return (freqs.map { 1 / $0 }, positionScale)
    }

    func quantization(for path: String) -> (groupSize: Int, bits: Int)? {
        guard let q = quantization else { return nil }
        if let layer = q[path] as? [String: Any] {
            return ((layer["group_size"] as? NSNumber)?.intValue ?? 64, (layer["bits"] as? NSNumber)?.intValue ?? 4)
        }
        if q[path] as? Bool == false { return nil }
        return ((q["group_size"] as? NSNumber)?.intValue ?? 64, (q["bits"] as? NSNumber)?.intValue ?? 4)
    }
}

/// Lazily loaded checkpoint arrays (MLX reads a tensor when it is evaluated).
final class TraceAuditLabWeightSource {
    let directory: URL
    let config: TraceAuditLabModelConfig
    private let arrays: [String: MLXArray]

    init(modelDirectory: URL) throws {
        self.directory = modelDirectory
        self.config = try TraceAuditLabModelConfig(modelDirectory: modelDirectory)
        var arrays: [String: MLXArray] = [:]
        let shards = try FileManager.default.contentsOfDirectory(atPath: modelDirectory.path)
            .filter { $0.hasSuffix(".safetensors") }.sorted()
        for shard in shards {
            for (key, value) in try loadArrays(url: modelDirectory.appendingPathComponent(shard)) {
                arrays[key] = value
            }
        }
        self.arrays = arrays
    }

    func array(_ key: String) -> MLXArray? { arrays[key] }
}

/// Float32 weights of one block, `[out, in]` row-major.
struct TraceAuditLabBlockWeights {
    struct Matrix {
        let rows: Int
        let cols: Int
        let values: [Float]
        let bias: [Float]?
    }

    let inputNorm: [Float]
    let postNorm: [Float]
    let q: Matrix, k: Matrix, v: Matrix, o: Matrix
    let gate: Matrix, up: Matrix, down: Matrix

    static func load(_ source: TraceAuditLabWeightSource, block: Int) throws -> TraceAuditLabBlockWeights {
        let prefix = "model.layers.\(block)."
        func vector(_ key: String) throws -> [Float] {
            guard let a = source.array(prefix + key) else { throw TraceAuditStoreError.io("missing \(prefix)\(key)") }
            return a.asType(.float32, stream: .cpu).asArray(Float.self)
        }
        func matrix(_ name: String) throws -> Matrix {
            guard let w = source.array("\(prefix)\(name).weight") else {
                throw TraceAuditStoreError.io("missing \(prefix)\(name).weight")
            }
            let dense: MLXArray
            if let scales = source.array("\(prefix)\(name).scales") {
                let q = source.config.quantization(for: "\(prefix)\(name)") ?? (64, 4)
                dense = dequantized(
                    w, scales: scales, biases: source.array("\(prefix)\(name).biases"),
                    groupSize: q.groupSize, bits: q.bits, stream: .cpu
                ).asType(.float32, stream: .cpu)
            } else {
                dense = w.asType(.float32, stream: .cpu)
            }
            let bias = try source.array("\(prefix)\(name).bias").map { _ in try vector("\(name).bias") }
            return Matrix(rows: dense.dim(0), cols: dense.dim(1), values: dense.asArray(Float.self), bias: bias)
        }
        return TraceAuditLabBlockWeights(
            inputNorm: try vector("input_layernorm.weight"),
            postNorm: try vector("post_attention_layernorm.weight"),
            q: try matrix("self_attn.q_proj"), k: try matrix("self_attn.k_proj"),
            v: try matrix("self_attn.v_proj"), o: try matrix("self_attn.o_proj"),
            gate: try matrix("mlp.gate_proj"), up: try matrix("mlp.up_proj"), down: try matrix("mlp.down_proj")
        )
    }
}

enum TraceAuditLabOpening {
    struct Leaves {
        var n1 = [Float](), q = [Float](), k = [Float](), v = [Float](), att = [Float](), o = [Float]()
        var hMid = [Float](), n2 = [Float](), gate = [Float](), up = [Float](), glu = [Float](), down = [Float]()
        var next = [Float]()
    }

    /// x: `[rows, cols]`; returns `[rows, m.rows]` (+ bias).
    static func linear(_ x: [Float], rows: Int, _ m: TraceAuditLabBlockWeights.Matrix) -> [Float] {
        var y = [Float](repeating: 0, count: rows * m.rows)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(m.rows), Int32(m.cols),
            1, x, Int32(m.cols), m.values, Int32(m.cols), 0, &y, Int32(m.rows)
        )
        if let bias = m.bias {
            for r in 0 ..< rows { for j in 0 ..< m.rows { y[r * m.rows + j] += bias[j] } }
        }
        return y
    }

    static func rmsNorm(_ x: [Float], rows: Int, weight: [Float], eps: Float) -> [Float] {
        let h = weight.count
        var out = [Float](repeating: 0, count: rows * h)
        for r in 0 ..< rows {
            var ss: Float = 0
            for j in 0 ..< h { ss += x[r * h + j] * x[r * h + j] }
            let scale = 1 / (ss / Float(h) + eps).squareRoot()
            for j in 0 ..< h { out[r * h + j] = x[r * h + j] * scale * weight[j] }
        }
        return out
    }

    /// Rotates `[rows, heads * headDim]` in place, row r at position `positions[r]`.
    static func rope(
        _ x: inout [Float], rows: Int, heads: Int, positions: [Int], config: TraceAuditLabModelConfig
    ) {
        let d = config.headDim
        let half = d / 2
        let (inv, scale) = config.ropeInverseFrequencies()
        for r in 0 ..< rows {
            let pos = Double(positions[r]) * scale
            for h in 0 ..< heads {
                let base = r * heads * d + h * d
                for i in 0 ..< half {
                    let angle = pos * inv[i]
                    let c = Float(cos(angle)), s = Float(sin(angle))
                    let (ia, ib) = config.ropeTraditional ? (base + 2 * i, base + 2 * i + 1) : (base + i, base + i + half)
                    let a = x[ia], b = x[ib]
                    x[ia] = a * c - b * s
                    x[ib] = a * s + b * c
                }
            }
        }
    }

    /// `inputs`: block-l inputs of positions 0...p, `[p+1, hidden]`.
    static func recompute(
        inputs: [Float], position p: Int, config: TraceAuditLabModelConfig, weights w: TraceAuditLabBlockWeights
    ) -> Leaves {
        let H = config.hidden, d = config.headDim, nh = config.heads, nkv = config.kvHeads
        let n = p + 1
        let normAll = rmsNorm(inputs, rows: n, weight: w.inputNorm, eps: config.rmsEps)
        var out = Leaves()
        out.n1 = Array(normAll[p * H ..< (p + 1) * H])
        out.q = linear(out.n1, rows: 1, w.q)
        let kAll = linear(normAll, rows: n, w.k)
        let vAll = linear(normAll, rows: n, w.v)
        out.k = Array(kAll[p * nkv * d ..< (p + 1) * nkv * d])
        out.v = Array(vAll[p * nkv * d ..< (p + 1) * nkv * d])
        var qr = out.q
        rope(&qr, rows: 1, heads: nh, positions: [p], config: config)
        var kr = kAll
        rope(&kr, rows: n, heads: nkv, positions: Array(0 ..< n), config: config)
        let scale = 1 / Float(d).squareRoot()
        let rep = nh / nkv
        var att = [Float](repeating: 0, count: nh * d)
        var scores = [Float](repeating: 0, count: n)
        for h in 0 ..< nh {
            let g = h / rep
            var maxScore = -Float.infinity
            for j in 0 ..< n {
                var s: Float = 0
                for i in 0 ..< d { s += qr[h * d + i] * kr[j * nkv * d + g * d + i] }
                scores[j] = s * scale
                maxScore = max(maxScore, scores[j])
            }
            var total: Float = 0
            for j in 0 ..< n { scores[j] = exp(scores[j] - maxScore); total += scores[j] }
            for j in 0 ..< n {
                let pj = scores[j] / total
                for i in 0 ..< d { att[h * d + i] += pj * vAll[j * nkv * d + g * d + i] }
            }
        }
        out.att = att
        out.o = linear(att, rows: 1, w.o)
        let x = Array(inputs[p * H ..< (p + 1) * H])
        out.hMid = zip(x, out.o).map { $0 + $1 }
        out.n2 = rmsNorm(out.hMid, rows: 1, weight: w.postNorm, eps: config.rmsEps)
        out.gate = linear(out.n2, rows: 1, w.gate)
        out.up = linear(out.n2, rows: 1, w.up)
        out.glu = zip(out.gate, out.up).map { g, u in g / (1 + exp(-g)) * u }
        out.down = linear(out.glu, rows: 1, w.down)
        out.next = zip(out.hMid, out.down).map { $0 + $1 }
        return out
    }


    struct Committed {
        let blocks: Int
        let hidden: Int
        let positions: Int
        let promptPositions: Int
        let root: String
        let key: String
        let directory: URL
    }

    static func loadCommitted(directory: URL, requestID: String) throws -> Committed {
        let key = TraceAuditStore.key(for: requestID)
        let data = try Data(contentsOf: directory.appendingPathComponent("\(key).meta.json"))
        guard let meta = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = (meta["blocks"] as? NSNumber)?.intValue,
              let hidden = (meta["hidden_size"] as? NSNumber)?.intValue,
              let positions = (meta["positions"] as? NSNumber)?.intValue,
              let prompt = (meta["prompt_positions"] as? NSNumber)?.intValue,
              let root = meta["root"] as? String else {
            throw TraceAuditStoreError.notCommitted
        }
        return Committed(
            blocks: blocks, hidden: hidden, positions: positions, promptPositions: prompt,
            root: root, key: key, directory: directory
        )
    }

    static func readBytes(_ url: URL, offset: Int, count: Int) throws -> [UInt8] {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw TraceAuditStoreError.io("open \(url.lastPathComponent)") }
        defer { close(fd) }
        var out = [UInt8](repeating: 0, count: count)
        try out.withUnsafeMutableBytes { raw in
            var got = 0
            while got < count {
                let n = pread(fd, raw.baseAddress! + got, count - got, off_t(offset + got))
                guard n > 0 else { throw TraceAuditStoreError.io("pread \(url.lastPathComponent)") }
                got += n
            }
        }
        return out
    }

    static func float16ToFloat(_ bytes: [UInt8]) -> [Float] {
        bytes.withUnsafeBytes { raw in raw.bindMemory(to: Float16.self).map { Float($0) } }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static let magic = Array("MPTRACEOPEN1\n".utf8)
    /// SPEC-036 FR-31 bound.
    static let maximumOpeningBytes = 160 << 20

    /// Writes a `trace_opening_v1` lab file for `points` (FR-31) and returns
    /// size and timing facts. Layout: magic, u64le JSON length, JSON header
    /// (`request`, `draws`, `leaves` = sorted opened leaf indices, `proof` =
    /// multiproof nodes `[level, index, hex]`), the committed leaf payloads in
    /// index order (2*H bytes per residual leaf, 8 per token pair), then the
    /// provider's internal leaves of block and prompt points (float32 LE, not
    /// committed, no proofs, recomputed with Accelerate). `internal_float32`
    /// offsets count from the start of that last section.
    static func write(
        directory: URL, requestID: String, points: TraceAuditChallengePoints,
        source: TraceAuditLabWeightSource, to output: URL,
        nonceHex: String? = nil
    ) throws -> [String: Any] {
        let started = Date()
        let c = try loadCommitted(directory: directory, requestID: requestID)
        let config = source.config
        guard config.hidden == c.hidden, config.blocks == c.blocks else {
            throw TraceAuditStoreError.io("model does not match trace")
        }
        let L = c.blocks
        let stride = (L + 1) * c.hidden * 2
        let vector = c.hidden * 2
        let resid = directory.appendingPathComponent("\(c.key).resid")
        let tokens = try readBytes(directory.appendingPathComponent("\(c.key).tokens"), offset: 0, count: c.positions * 8)
        let leafCount = c.positions * TraceAuditLeaf.leavesPerPosition(blocks: L)
        let lh = try readBytes(directory.appendingPathComponent("\(c.key).lh"), offset: 0, count: leafCount * 32)
        let tree = TraceAuditMerkleTree(leafHashes: (0 ..< leafCount).map { Data(lh[$0 * 32 ..< ($0 + 1) * 32]) })
        guard let root = tree.root(), hex(root) == c.root else {
            throw TraceAuditStoreError.io("leaf hashes do not give the committed root")
        }
        let treeSeconds = Date().timeIntervalSince(started)

        // Leaves to open (FR-31): block/prompt points carry block-l inputs at
        // 0..p and the next leaf; output points carry the final residual at p;
        // plus every prompt block-0 leaf and every token pair.
        var opened = Set<Int>()
        let computed: [(String, TraceAuditPoint)] = points.blockPoints.map { ("block", $0) }
            + [("prompt", points.promptPoint)]
        var draws: [[String: Any]] = []
        for (role, point) in computed {
            let (l, p) = (point.block, point.position)
            guard l >= 0, l < L, p >= 0, p < c.positions else { throw TraceAuditStoreError.io("point out of range") }
            for j in 0 ... p {
                opened.insert(TraceAuditLeaf.index(kind: .blockInput, block: l, position: j, blocks: L))
            }
            let next = TraceAuditLeaf.index(kind: l + 1 == L ? .finalResidual : .blockInput, block: l + 1, position: p, blocks: L)
            opened.insert(next)
            draws.append(["role": role, "block": l, "position": p, "next_leaf": next])
        }
        for p in points.outputPositions {
            guard p >= 0, p < c.positions else { throw TraceAuditStoreError.io("point out of range") }
            let leaf = TraceAuditLeaf.index(kind: .finalResidual, block: 0, position: p, blocks: L)
            opened.insert(leaf)
            draws.append(["role": "output", "position": p, "leaf": leaf])
        }
        for j in 0 ..< c.promptPositions {
            opened.insert(TraceAuditLeaf.index(kind: .blockInput, block: 0, position: j, blocks: L))
        }
        for j in 0 ..< c.positions {
            opened.insert(TraceAuditLeaf.index(kind: .tokenPair, block: 0, position: j, blocks: L))
        }
        let leafList = opened.sorted()
        let proof = tree.multiproof(opened: opened)

        // Committed payloads in index order, then the provider's internal
        // leaves (not committed, no proofs) for block and prompt points.
        var payloads = Data()
        for index in leafList {
            let position = index / (L + 2)
            let j = index % (L + 2)
            payloads.append(contentsOf: j <= L
                ? try readBytes(resid, offset: position * stride + j * vector, count: vector)
                : Array(tokens[position * 8 ..< position * 8 + 8]))
        }
        var internalBlob = Data()
        var computeSeconds = 0.0
        var blockCache: (Int, TraceAuditLabBlockWeights)?
        for (n, (_, point)) in computed.enumerated() {
            let (l, p) = (point.block, point.position)
            var inputs = [Float]()
            inputs.reserveCapacity((p + 1) * c.hidden)
            for j in 0 ... p {
                inputs += float16ToFloat(try readBytes(resid, offset: j * stride + l * vector, count: vector))
            }
            let weights: TraceAuditLabBlockWeights
            if let cached = blockCache, cached.0 == l {
                weights = cached.1
            } else {
                weights = try TraceAuditLabBlockWeights.load(source, block: l)
                blockCache = (l, weights)
            }
            let t0 = Date()
            let leaves = recompute(inputs: inputs, position: p, config: config, weights: weights)
            computeSeconds += Date().timeIntervalSince(t0)
            var internalRows: [String: [Int]] = [:]
            for (name, values) in [
                ("n1", leaves.n1), ("q", leaves.q), ("k", leaves.k), ("v", leaves.v), ("att", leaves.att),
                ("o", leaves.o), ("h_mid", leaves.hMid), ("n2", leaves.n2), ("g", leaves.gate), ("u", leaves.up),
                ("glu", leaves.glu), ("d", leaves.down), ("next", leaves.next),
            ] {
                internalRows[name] = [internalBlob.count, values.count]
                values.withUnsafeBytes { internalBlob.append(contentsOf: $0) }
            }
            draws[n]["internal_float32"] = internalRows
        }
        let header: [String: Any] = [
            "type": "trace_opening_v1",
            "schema": "macprovider.trace-audit-lab.opening.v2",
            "request": [
                "request_id": requestID,
                "root": c.root,
                "nonce_1": nonceHex ?? NSNull(),
                "blocks": L,
                "hidden_size": c.hidden,
                "positions": c.positions,
                "prompt_positions": c.promptPositions,
                "leaf_count": leafCount,
                "activation_dtype": "float16",
                "internal_dtype": "float32",
            ] as [String: Any],
            "draws": draws,
            "leaves": leafList,
            "proof": proof.map { [$0.level, $0.index, hex($0.hash)] as [Any] },
            "payload_bytes": payloads.count,
        ]
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var file = Data(magic)
        var length = UInt64(json.count).littleEndian
        withUnsafeBytes(of: &length) { file.append(contentsOf: $0) }
        file.append(json)
        file.append(payloads)
        file.append(internalBlob)
        try file.write(to: output, options: .atomic)
        _ = chmod(output.path, 0o600)
        let roles = computed.map { ($0.0, $0.1.position) } + points.outputPositions.map { ("output", $0) }
        return [
            "bytes": file.count,
            "over_cap": file.count > maximumOpeningBytes,
            "leaves_opened": leafList.count,
            "proof_nodes": proof.count,
            "points": roles.map { ["role": $0.0, "position": $0.1] },
            "tree_seconds": treeSeconds,
            "recompute_seconds": computeSeconds,
            "total_seconds": Date().timeIntervalSince(started),
        ]
    }
}
#endif
