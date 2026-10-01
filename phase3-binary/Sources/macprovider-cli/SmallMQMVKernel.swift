#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MLX
import MLXNN

/// Lab prototype for issue #1770: 4-bit affine (group 64) quantized matmul for
/// small M (2...16 rows) that streams every weight tile once and applies it to
/// all M rows, instead of MLX `qmv` (one weight pass per row) or `qmv_wide`
/// (one weight pass per 5 rows, per-row scalar x loads).
///
/// y[M, N] = x[M, K] . dequant(w[N, K/8], scales[N, K/64], biases[N, K/64])^T
///
/// Two variants:
/// - `rb` (register-blocked scalar): same tiling as MLX `qmv_fast` (2
///   simdgroups x R output rows per threadgroup, 16 k-values per lane per
///   512-k block). Each lane dequantizes its R x 16 weights once into floats,
///   then loads each x row's 16 values with two 16-byte loads and does R x 16
///   FMAs per row. ALU cost per weight is about 3 + M + M/R lane ops.
/// - `mma` (simdgroup_matrix 8x8): computes y^T = W . x^T with W as the A
///   fragment. The k index inside a 128-k chunk is permuted so that each lane's
///   A elements come from one 16-byte weight load per 8-row tile, and the same
///   permutation is applied to the x (B fragment) side. KS simdgroups split K
///   inside a threadgroup and reduce through threadgroup memory.
///
/// Both accumulate in float and write the activation dtype. Reduction order
/// differs from MLX, so results are not bit-identical to `quantizedMM`.
enum SmallMQMV {
    enum Variant: String, CaseIterable {
        case rb
        case mma
        case mmas
    }

    static let header = """
        inline void smallm_load_x16(const device bfloat16_t* p, thread float* o) {
          const device uint4* q = (const device uint4*)p;
          uint4 a = q[0];
          uint4 c = q[1];
          uint u[8] = {a.x, a.y, a.z, a.w, c.x, c.y, c.z, c.w};
          for (int i = 0; i < 8; i++) {
            o[2 * i] = as_type<float>(u[i] << 16);
            o[2 * i + 1] = as_type<float>(u[i] & 0xffff0000u);
          }
        }
        inline void smallm_load_x16(const device half* p, thread float* o) {
          const device half4* q = (const device half4*)p;
          for (int i = 0; i < 4; i++) {
            half4 h = q[i];
            o[4 * i] = float(h.x);
            o[4 * i + 1] = float(h.y);
            o[4 * i + 2] = float(h.z);
            o[4 * i + 3] = float(h.w);
          }
        }
        // Low (hi = 0) or high (hi = 1) 16-bit activation of a packed pair.
        template <typename T, typename AT>
        inline AT smallm_x_at(uint word, int hi) {
          const ushort h = hi ? ushort(word >> 16) : ushort(word & 0xffffu);
          if constexpr (metal::is_same_v<T, AT>) {
            return as_type<AT>(h);
          } else if constexpr (metal::is_same_v<T, bfloat16_t>) {
            return AT(as_type<float>(uint(h) << 16));
          } else {
            return AT(float(as_type<half>(h)));
          }
        }
        // Pick the activation of a packed 16-bit pair: xshift 16 = low, 0 = high.
        template <typename T, typename AT>
        inline AT smallm_x_pick(uint word, uint xshift) {
          const uint bits = (word << xshift) & 0xffff0000u;
          if constexpr (metal::is_same_v<T, AT>) {
            return as_type<AT>(ushort(bits >> 16));
          } else if constexpr (metal::is_same_v<T, bfloat16_t>) {
            return AT(as_type<float>(bits));
          } else {
            return AT(float(as_type<half>(ushort(bits >> 16))));
          }
        }
        """

    static let rbSource = """
          constexpr int SG = 2;
          constexpr int KW = K / 8;
          constexpr int KG = K / 64;
          const int lane = int(thread_index_in_simdgroup);
          const int n0 = (int(threadgroup_position_in_grid.x) * SG + int(simdgroup_index_in_threadgroup)) * R;
          float acc[M][R];
          for (int m = 0; m < M; m++) {
            for (int r = 0; r < R; r++) {
              acc[m][r] = 0.0f;
            }
          }
          for (int k0 = 0; k0 < K; k0 += 512) {
            const int kk = k0 + 16 * lane;
            float wd[R][16];
            for (int r = 0; r < R; r++) {
              const int row = n0 + r;
              const uint2 q = *((const device uint2*)(w + row * KW + kk / 8));
              const float s = float(scales[row * KG + kk / 64]);
              const float b = float(biases[row * KG + kk / 64]);
              for (int j = 0; j < 8; j++) {
                wd[r][j] = fma(float((q.x >> (4 * j)) & 0xfu), s, b);
                wd[r][8 + j] = fma(float((q.y >> (4 * j)) & 0xfu), s, b);
              }
            }
            for (int m = 0; m < M; m++) {
              float xv[16];
              smallm_load_x16(x + m * K + kk, xv);
              for (int r = 0; r < R; r++) {
                float a = 0.0f;
                for (int i = 0; i < 16; i++) {
                  a = fma(xv[i], wd[r][i], a);
                }
                acc[m][r] += a;
              }
            }
          }
          for (int m = 0; m < M; m++) {
            for (int r = 0; r < R; r++) {
              const float v = simd_sum(acc[m][r]);
              if (lane == 0) {
                y[m * N + n0 + r] = static_cast<T>(v);
              }
            }
          }
        """

    // Lane coordinates in an 8x8 simdgroup_matrix (MLX steel BaseMMAFrag):
    // lane holds [fm][fn] and [fm][fn + 1].
    // A = W tile (row n, col kk), B = x^T tile (row kk, col m), C = y^T (n, m).
    // Inside a 128-k chunk, logical (step s in 0..15, kk) maps to physical
    // k = kk * 16 + s. An A lane (row fm, cols fn, fn + 1) then reads the 16
    // contiguous bytes at k = fn * 16 ... + 31 of its row (one uint4: nibble s
    // of words 0-1 for kk = fn, of words 2-3 for kk = fn + 1), and a B lane
    // (row kk = fm) reads the 16 contiguous activations at k = fm * 16 of each
    // of its two x rows (two uint4). Both halves of the A lane's 32 values lie
    // in one 64-k group, so one scale/bias pair per row per chunk.
    static let mmaSource = """
          constexpr int KW = K / 8;
          constexpr int KG = K / 64;
          constexpr int MT = (M + 7) / 8;
          constexpr int NCHUNK = K / 128;
          const int lane = int(thread_index_in_simdgroup);
          const int sg = int(simdgroup_index_in_threadgroup);
          const int qid = lane / 4;
          const int fm = (qid & 4) + ((lane / 2) % 4);
          const int fn = (qid & 2) * 2 + (lane % 2) * 2;
          const int n0 = int(threadgroup_position_in_grid.x) * NT * 8;
          const int wk_off = fn * 16;
          const int xk_off = fm * 16;

          simdgroup_matrix<float, 8, 8> C[NT][MT];
          for (int t = 0; t < NT; t++) {
            for (int u = 0; u < MT; u++) {
              C[t][u] = make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
            }
          }

          for (int c = sg; c < NCHUNK; c += KS) {
            const int k0 = c * 128;
            uint4 wq[NT];
            float ws[NT];
            float wb[NT];
            for (int t = 0; t < NT; t++) {
              const int row = n0 + t * 8 + fm;
              wq[t] = *((const device uint4*)(w + row * KW + (k0 + wk_off) / 8));
              ws[t] = float(scales[row * KG + (k0 + wk_off) / 64]);
              wb[t] = float(biases[row * KG + (k0 + wk_off) / 64]);
            }
            // Columns m >= M are zero and never stored.
            uint4 xa[MT][2][2];
            for (int u = 0; u < MT; u++) {
              for (int e = 0; e < 2; e++) {
                const int m = u * 8 + fn + e;
                if (m < M) {
                  const device uint4* xp = (const device uint4*)(x + m * K + k0 + xk_off);
                  xa[u][e][0] = xp[0];
                  xa[u][e][1] = xp[1];
                } else {
                  xa[u][e][0] = uint4(0);
                  xa[u][e][1] = uint4(0);
                }
              }
            }
            for (int s = 0; s < 16; s++) {
              simdgroup_matrix<AT, 8, 8> B[MT];
              for (int u = 0; u < MT; u++) {
                for (int e = 0; e < 2; e++) {
                  B[u].thread_elements()[e] = smallm_x_at<T, AT>(xa[u][e][s / 8][(s % 8) / 2], s % 2);
                }
              }
              for (int t = 0; t < NT; t++) {
                simdgroup_matrix<AT, 8, 8> A;
                A.thread_elements()[0] = AT(fma(float(extract_bits(wq[t][s / 8], 4 * (s % 8), 4)), ws[t], wb[t]));
                A.thread_elements()[1] = AT(fma(float(extract_bits(wq[t][2 + s / 8], 4 * (s % 8), 4)), ws[t], wb[t]));
                for (int u = 0; u < MT; u++) {
                  simdgroup_multiply_accumulate(C[t][u], A, B[u], C[t][u]);
                }
              }
            }
          }

          threadgroup float red[KS > 1 ? KS * NT * MT * 64 : 1];
          if (KS > 1) {
            for (int t = 0; t < NT; t++) {
              for (int u = 0; u < MT; u++) {
                for (int e = 0; e < 2; e++) {
                  red[((sg * NT + t) * MT + u) * 64 + lane * 2 + e] = C[t][u].thread_elements()[e];
                }
              }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
          }
          if (sg == 0) {
            for (int t = 0; t < NT; t++) {
              for (int u = 0; u < MT; u++) {
                for (int e = 0; e < 2; e++) {
                  float v = C[t][u].thread_elements()[e];
                  for (int j = 1; j < KS; j++) {
                    v += red[((j * NT + t) * MT + u) * 64 + lane * 2 + e];
                  }
                  const int m = u * 8 + fn + e;
                  const int n = n0 + t * 8 + fm;
                  if (m < M) {
                    y[m * N + n] = static_cast<T>(v);
                  }
                }
              }
            }
          }
        """

    // `mmas`: like `mma`, but the A fragment holds the raw 4-bit integers
    // (exact in bf16/fp16/fp32) and scale/bias are applied once per 64-k group:
    //   y[m][n] += s[n,g] * sum_k q[n,k] x[m,k] + b[n,g] * sum_k x[m,k].
    // One group per iteration; logical (step s in 0..7, kk) maps to physical
    // k = (kk / 2) * 16 + 2 s + (kk % 2), so an A lane reads 8 bytes per row and
    // a B lane reads 16 consecutive activations per row. The per-group x sum is
    // a butterfly over the lanes sharing fn (lane bits 1, 2, 4).
    static let mmasSource = """
          constexpr int KW = K / 8;
          constexpr int KG = K / 64;
          constexpr int MT = (M + 7) / 8;
          const int lane = int(thread_index_in_simdgroup);
          const int sg = int(simdgroup_index_in_threadgroup);
          const int qid = lane / 4;
          const int fm = (qid & 4) + ((lane / 2) % 4);
          const int fn = (qid & 2) * 2 + (lane % 2) * 2;
          const int n0 = int(threadgroup_position_in_grid.x) * NT * 8;
          const uint xshift = (fm % 2) == 0 ? 16u : 0u;
          const int wk_off = (fn / 2) * 16;
          const int xk_off = (fm / 2) * 16;

          float acc[NT][MT][2];
          for (int t = 0; t < NT; t++) {
            for (int u = 0; u < MT; u++) {
              acc[t][u][0] = 0.0f;
              acc[t][u][1] = 0.0f;
            }
          }

          for (int g = sg; g < KG; g += KS) {
            const int k0 = g * 64;
            uint2 wq[NT];
            float ws[NT];
            float wb[NT];
            for (int t = 0; t < NT; t++) {
              const int row = n0 + t * 8 + fm;
              wq[t] = *((const device uint2*)(w + row * KW + (k0 + wk_off) / 8));
              ws[t] = float(scales[row * KG + g]);
              wb[t] = float(biases[row * KG + g]);
            }
            uint4 xa[MT][2][2];
            for (int u = 0; u < MT; u++) {
              for (int e = 0; e < 2; e++) {
                const int m = u * 8 + fn + e;
                const int mr = m < M ? m : M - 1;
                const device uint4* xp = (const device uint4*)(x + mr * K + k0 + xk_off);
                xa[u][e][0] = xp[0];
                xa[u][e][1] = xp[1];
              }
            }
            simdgroup_matrix<float, 8, 8> G[NT][MT];
            for (int t = 0; t < NT; t++) {
              for (int u = 0; u < MT; u++) {
                G[t][u] = make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
              }
            }
            float xsum[MT][2];
            for (int u = 0; u < MT; u++) {
              xsum[u][0] = 0.0f;
              xsum[u][1] = 0.0f;
            }
            for (int s = 0; s < 8; s++) {
              simdgroup_matrix<AT, 8, 8> B[MT];
              for (int u = 0; u < MT; u++) {
                for (int e = 0; e < 2; e++) {
                  const AT v = smallm_x_pick<T, AT>(xa[u][e][s / 4][s % 4], xshift);
                  B[u].thread_elements()[e] = v;
                  xsum[u][e] += float(v);
                }
              }
              for (int t = 0; t < NT; t++) {
                const uint word = wq[t][s / 4];
                simdgroup_matrix<AT, 8, 8> A;
                A.thread_elements()[0] = AT(float(extract_bits(word, 8 * (s % 4), 4)));
                A.thread_elements()[1] = AT(float(extract_bits(word, 8 * (s % 4) + 4, 4)));
                for (int u = 0; u < MT; u++) {
                  simdgroup_multiply_accumulate(G[t][u], A, B[u], G[t][u]);
                }
              }
            }
            for (int u = 0; u < MT; u++) {
              for (int e = 0; e < 2; e++) {
                float v = xsum[u][e];
                v += simd_shuffle_xor(v, 2);
                v += simd_shuffle_xor(v, 4);
                v += simd_shuffle_xor(v, 16);
                xsum[u][e] = v;
              }
            }
            for (int t = 0; t < NT; t++) {
              for (int u = 0; u < MT; u++) {
                for (int e = 0; e < 2; e++) {
                  acc[t][u][e] += fma(ws[t], G[t][u].thread_elements()[e], wb[t] * xsum[u][e]);
                }
              }
            }
          }

          threadgroup float red[KS > 1 ? KS * NT * MT * 64 : 1];
          if (KS > 1) {
            for (int t = 0; t < NT; t++) {
              for (int u = 0; u < MT; u++) {
                for (int e = 0; e < 2; e++) {
                  red[((sg * NT + t) * MT + u) * 64 + lane * 2 + e] = acc[t][u][e];
                }
              }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
          }
          if (sg == 0) {
            for (int t = 0; t < NT; t++) {
              for (int u = 0; u < MT; u++) {
                for (int e = 0; e < 2; e++) {
                  float v = acc[t][u][e];
                  for (int j = 1; j < KS; j++) {
                    v += red[((j * NT + t) * MT + u) * 64 + lane * 2 + e];
                  }
                  const int m = u * 8 + fn + e;
                  if (m < M) {
                    y[m * N + n0 + t * 8 + fm] = static_cast<T>(v);
                  }
                }
              }
            }
          }
        """

    nonisolated(unsafe) static let mmasKernel = MLXFast.metalKernel(
        name: "smallm_qmv_mmas",
        inputNames: ["x", "w", "scales", "biases"],
        outputNames: ["y"],
        source: mmasSource,
        header: header
    )

    nonisolated(unsafe) static let rbKernel = MLXFast.metalKernel(
        name: "smallm_qmv_rb",
        inputNames: ["x", "w", "scales", "biases"],
        outputNames: ["y"],
        source: rbSource,
        header: header
    )

    nonisolated(unsafe) static let mmaKernel = MLXFast.metalKernel(
        name: "smallm_qmv_mma",
        inputNames: ["x", "w", "scales", "biases"],
        outputNames: ["y"],
        source: mmaSource,
        header: header
    )

    struct Config: CustomStringConvertible {
        var variant: Variant
        /// rb: output rows per simdgroup. mma: 8-row tiles per threadgroup.
        var rows: Int
        /// mma only: simdgroups splitting K inside one threadgroup.
        var kSplit: Int
        /// mma only: A/B fragment element type ("f32" or "act" = activation dtype).
        var fragAct: Bool = false
        /// Routing only: smallest row count sent to the kernel (below it, MLX
        /// qmv / qmv_wide is already close to the M=1 cost).
        var minRows: Int = 4

        var description: String {
            variant == .rb ? "rb-r\(rows)" : "\(variant.rawValue)-nt\(rows)-ks\(kSplit)" + (fragAct ? "-act" : "")
        }

        static func parse(_ text: String) -> Config? {
            let parts = text.split(separator: "-").map(String.init)
            guard let first = parts.first, let variant = Variant(rawValue: first) else { return nil }
            var config = Config(variant: variant, rows: variant == .rb ? 4 : 1, kSplit: 4)
            for part in parts.dropFirst() {
                if part.hasPrefix("nt"), let v = Int(part.dropFirst(2)) { config.rows = v }
                if part.hasPrefix("r"), let v = Int(part.dropFirst(1)) { config.rows = v }
                if part.hasPrefix("ks"), let v = Int(part.dropFirst(2)) { config.kSplit = v }
                if part == "act" { config.fragAct = true }
                if part.hasPrefix("min"), let v = Int(part.dropFirst(3)) { config.minRows = v }
            }
            return config
        }

        /// Default choice used by the forward routing flag ("auto").
        static let auto = Config(variant: .mma, rows: 2, kSplit: 2)
    }

    /// Whether the kernel supports this problem; callers fall back to
    /// `quantizedMM` otherwise.
    static func supports(m: Int, n: Int, k: Int, config: Config, dtype: DType) -> Bool {
        guard m >= 1, m <= 16, dtype == .bfloat16 || dtype == .float16 else { return false }
        switch config.variant {
        case .rb:
            return k % 512 == 0 && n % (2 * config.rows) == 0
        case .mma:
            return k % 128 == 0 && n % (8 * config.rows) == 0
        case .mmas:
            return k % 64 == 0 && n % (8 * config.rows) == 0
        }
    }

    /// x: [M, K] row-contiguous; w: [N, K/8] uint32; scales/biases: [N, K/64].
    static func matmul(
        _ x: MLXArray, w: MLXArray, scales: MLXArray, biases: MLXArray, config: Config
    ) -> MLXArray {
        let m = x.dim(0)
        let k = x.dim(1)
        let n = w.dim(0)
        let dtype = x.dtype
        switch config.variant {
        case .rb:
            let groups = n / (2 * config.rows)
            return rbKernel(
                [x, w, scales.asType(dtype), biases.asType(dtype)],
                template: [("T", dtype), ("M", m), ("R", config.rows), ("K", k), ("N", n)],
                grid: (groups * 64, 1, 1),
                threadGroup: (64, 1, 1),
                outputShapes: [[m, n]],
                outputDTypes: [dtype]
            )[0]
        case .mma, .mmas:
            let groups = n / (8 * config.rows)
            let threads = 32 * config.kSplit
            return (config.variant == .mma ? mmaKernel : mmasKernel)(
                [x, w, scales.asType(dtype), biases.asType(dtype)],
                template: [
                    ("T", dtype), ("AT", config.fragAct ? dtype : DType.float32),
                    ("M", m), ("NT", config.rows), ("KS", config.kSplit),
                    ("K", k), ("N", n),
                ],
                grid: (groups * threads, 1, 1),
                threadGroup: (threads, 1, 1),
                outputShapes: [[m, n]],
                outputDTypes: [dtype]
            )[0]
        }
    }
}

/// Lab-only QuantizedLinear that routes 4-bit g64 affine inputs with
/// 2 <= rows <= 16 through `SmallMQMV`; everything else keeps `quantizedMM`.
final class SmallMQuantizedLinear: QuantizedLinear {
    nonisolated(unsafe) static var fixedConfig: SmallMQMV.Config?

    init(_ other: QuantizedLinear) {
        super.init(
            weight: other.weight, bias: other.bias, scales: other.scales, biases: other.biases,
            groupSize: other.groupSize, bits: other.bits, mode: other.mode)
        self.freeze()
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let k = x.dim(-1)
        let rows = x.size / k
        let n = weight.dim(0)
        var config = Self.fixedConfig ?? SmallMQMV.Config.auto
        // Narrow outputs give too few threadgroups; split K wider, and leave
        // the tiny projections (linear-attention in_proj_a/b, N <= 64) to MLX.
        if config.variant != .rb, n < 4096 {
            config.kSplit = max(config.kSplit, 8)
        }
        guard rows >= config.minRows, n >= 512, bits == 4, groupSize == 64, mode == .affine, let biases,
              weight.ndim == 2,
              SmallMQMV.supports(m: rows, n: n, k: k, config: config, dtype: x.dtype)
        else {
            return super.callAsFunction(x)
        }
        var y = SmallMQMV.matmul(
            x.reshaped([rows, k]), w: weight, scales: scales, biases: biases, config: config)
        y = y.reshaped(Array(x.shape.dropLast()) + [n])
        if let bias {
            y = y + bias
        }
        return y
    }

    /// Replaces every eligible QuantizedLinear in `model`. Returns the count.
    @discardableResult
    static func install(in model: Module) -> Int {
        var updates: [(String, Module)] = []
        for (key, module) in model.leafModules().flattened() {
            if let q = module as? QuantizedLinear, !(q is SmallMQuantizedLinear),
               q.bits == 4, q.groupSize == 64, q.mode == .affine, q.biases != nil
            {
                updates.append((key, SmallMQuantizedLinear(q)))
            }
        }
        if !updates.isEmpty {
            _ = model.update(modules: ModuleChildren.unflattened(updates))
        }
        return updates.count
    }
}
#endif
