#if DEBUG || MACPROVIDER_LAB_HARNESS
import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Lab prototype for issue #1770 (A3B small-batch MoE): SIMT 4-bit affine
/// (group 64) kernels for M = 1...8 activation rows per launch.
///
/// Layout (llama.cpp `mul_mv_ext` shape, MLX affine g64 weights): LPR lanes
/// share one weight row; each lane loads 16 contiguous weight bytes (32
/// nibbles) per step, so the LPR lanes of a row read 16 * LPR contiguous
/// bytes (a full 128-byte line at LPR = 8). Each lane dequantizes its 32
/// weights once (q * s + b, float) and applies them to every activation row,
/// accumulating R x MM floats. Activations are read either straight from
/// device memory and converted per lane (XS = 0) or converted once per
/// threadgroup into padded threadgroup memory (XS = 1). Lane partial sums
/// are combined with simd_shuffle_xor in a fixed butterfly, then KS K-split
/// simdgroups are summed in a fixed order. Nothing in the reduction order
/// depends on M or on how many tokens share an expert, so a row's result is
/// bit-identical at M = 1 and M = 8 (batch invariant).
///
/// Grouped MoE: `bucket` turns router indices into per-expert token lists
/// (one threadgroup, one thread per expert, stable pair order) and `gather`
/// runs one threadgroup per (active expert slot, row tile) over every token
/// routed to that expert, with the same inner loop. Gate and up projections
/// are fused (R = 2: one gate row and one up row per lane) and the SiLU
/// product is applied in the epilogue.
enum MoESmallM {
    static let header = """
        inline void vb_x8(const device bfloat16_t* p, thread float* o) {
          const uint4 a = *((const device uint4*)p);
          o[0] = as_type<float>(a.x << 16); o[1] = as_type<float>(a.x & 0xffff0000u);
          o[2] = as_type<float>(a.y << 16); o[3] = as_type<float>(a.y & 0xffff0000u);
          o[4] = as_type<float>(a.z << 16); o[5] = as_type<float>(a.z & 0xffff0000u);
          o[6] = as_type<float>(a.w << 16); o[7] = as_type<float>(a.w & 0xffff0000u);
        }
        inline void vb_x8(const device half* p, thread float* o) {
          const half4 a = ((const device half4*)p)[0];
          const half4 b = ((const device half4*)p)[1];
          o[0] = float(a.x); o[1] = float(a.y); o[2] = float(a.z); o[3] = float(a.w);
          o[4] = float(b.x); o[5] = float(b.y); o[6] = float(b.z); o[7] = float(b.w);
        }
        inline void vb_x4(const device bfloat16_t* p, threadgroup float* o) {
          const uint2 a = *((const device uint2*)p);
          *((threadgroup float4*)o) = float4(
              as_type<float>(a.x << 16), as_type<float>(a.x & 0xffff0000u),
              as_type<float>(a.y << 16), as_type<float>(a.y & 0xffff0000u));
        }
        inline void vb_x4(const device half* p, threadgroup float* o) {
          *((threadgroup float4*)o) = float4(*((const device half4*)p));
        }
        """

    /// Common prologue. Rows of this lane: rowBase + r * RPS + lr.
    /// Staging area: KS x MM x KBP floats, 32-value chunks padded by 4 floats
    /// so the LPR chunk reads of one instruction hit distinct banks.
    static let prologue = """
          constexpr int KW = K / 8;
          constexpr int KG = K / 64;
          constexpr int KPS = K / KS;
          constexpr int RPS = 32 / LPR;
          constexpr int KB = LPR * 32;
          constexpr int KBP = KB + LPR * 4;
          threadgroup float red[(KS > 1 ? NT * (KS - 1) : 1) * R * MM * 32];
          threadgroup float xs_all[XS == 1 ? KS * MM * KBP : 4];
          const int lane = int(thread_index_in_simdgroup);
          const int sg = int(simdgroup_index_in_threadgroup);
          const int tile = sg / KS;
          const int sgk = sg % KS;
          const int kl = lane % LPR;
          const int lr = lane / LPR;
          threadgroup float* xs = xs_all + (XS == 1 ? sgk * MM * KBP : 0);
          const int kbeg = sgk * KPS;
          const int kend = kbeg + KPS;
          float acc[R][MM];
        """

    /// Shared inner loop + reductions. Expects wr[R], sr[R], brr[R] (row
    /// pointers), xr[MM] (activation rows), cnt (live rows, uniform per
    /// threadgroup). Leaves full sums in acc of lanes kl == 0 of sgk == 0.
    static let inner = """
          for (int r = 0; r < R; r++) {
            for (int m = 0; m < MM; m++) {
              acc[r][m] = 0.0f;
            }
          }
          for (int kb0 = kbeg; kb0 < kend; kb0 += KB) {
            if (XS == 1) {
              for (int idx = (tile * 32 + lane) * 4; idx < cnt * KB; idx += NT * 128) {
                const int m = idx / KB;
                const int k = idx % KB;
                if (m < cnt) {
                  vb_x4(xr[m] + kb0 + k, xs + m * KBP + k + (k / 32) * 4);
                }
              }
              threadgroup_barrier(mem_flags::mem_threadgroup);
            }
            const int kk = kb0 + kl * 32;
            uint4 wq[R];
            float ws[R];
            float wb[R];
            for (int r = 0; r < R; r++) {
              wq[r] = *((const device uint4*)(wr[r] + kk / 8));
              ws[r] = float(sr[r][kk / 64]);
              wb[r] = float(brr[r][kk / 64]);
            }
            for (int j = 0; j < 4; j++) {
              float wd[R][8];
              for (int r = 0; r < R; r++) {
                for (int i = 0; i < 8; i++) {
                  wd[r][i] = fma(float(extract_bits(wq[r][j], 4 * i, 4)), ws[r], wb[r]);
                }
              }
              for (int m = 0; m < MM; m++) {
                if (m < cnt) {
                  float xf[8];
                  if (XS == 1) {
                    const threadgroup float4* xp = (const threadgroup float4*)(xs + m * KBP + kl * 36 + 8 * j);
                    const float4 a = xp[0];
                    const float4 b = xp[1];
                    xf[0] = a.x; xf[1] = a.y; xf[2] = a.z; xf[3] = a.w;
                    xf[4] = b.x; xf[5] = b.y; xf[6] = b.z; xf[7] = b.w;
                  } else {
                    vb_x8(xr[m] + kk + 8 * j, xf);
                  }
                  for (int r = 0; r < R; r++) {
                    for (int i = 0; i < 8; i++) {
                      acc[r][m] = fma(xf[i], wd[r][i], acc[r][m]);
                    }
                  }
                }
              }
            }
            if (XS == 1) {
              threadgroup_barrier(mem_flags::mem_threadgroup);
            }
          }
          for (int r = 0; r < R; r++) {
            for (int m = 0; m < MM; m++) {
              if (m < cnt) {
                float v = acc[r][m];
                for (int o = 1; o < LPR; o <<= 1) {
                  v += simd_shuffle_xor(v, ushort(o));
                }
                acc[r][m] = v;
              }
            }
          }
          if (KS > 1) {
            if (sgk > 0) {
              for (int r = 0; r < R; r++) {
                for (int m = 0; m < cnt; m++) {
                  red[(((tile * (KS - 1) + sgk - 1) * R + r) * MM + m) * 32 + lane] = acc[r][m];
                }
              }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (sgk == 0) {
              for (int j = 1; j < KS; j++) {
                for (int r = 0; r < R; r++) {
                  for (int m = 0; m < cnt; m++) {
                    acc[r][m] += red[(((tile * (KS - 1) + j - 1) * R + r) * MM + m) * 32 + lane];
                  }
                }
              }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
          }
        """

    static let denseSource = """
        \(prologue)
          const int rowBase = (int(threadgroup_position_in_grid.x) * NT + tile) * RPS * R;
          const device uint32_t* wr[R];
          const device T* sr[R];
          const device T* brr[R];
          for (int r = 0; r < R; r++) {
            const int row = rowBase + r * RPS + lr;
            wr[r] = w + row * KW;
            sr[r] = scales + row * KG;
            brr[r] = biases + row * KG;
          }
          // MROWS activation rows in passes of MM rows (weights re-read per
          // pass, from cache); the pass size never changes reduction order.
          for (int m0 = 0; m0 < MROWS; m0 += MM) {
            const int cnt = min(MM, MROWS - m0);
            const device T* xr[MM];
            for (int m = 0; m < MM; m++) {
              xr[m] = x + (m0 + min(m, cnt - 1)) * K;
            }
        \(inner)
            if (sgk == 0 && kl == 0) {
              for (int r = 0; r < R; r++) {
                for (int m = 0; m < MM; m++) {
                  if (m < cnt) {
                    y[(m0 + m) * N + rowBase + r * RPS + lr] = static_cast<T>(acc[r][m]);
                  }
                }
              }
            }
          }
        """

    /// MODE 1: gate/up fused (w0 = gate, w1 = up, R = 2, same row for both),
    /// x row = pair / TOPK, y = silu(gate) * up. MODE 2: one projection
    /// (w0 only, rows rowBase + r * RPS + lr), x row = pair. Output row =
    /// pair. Tokens beyond MM are processed in further passes.
    static let gatherSource = """
        \(prologue)
          const int slot = int(threadgroup_position_in_grid.y);
          const int c = counts[slot];
          if (c == 0) {
            return;
          }
          const int e = experts[slot];
          constexpr int RO = MODE == 1 ? 1 : R;
          const int rowBase = (int(threadgroup_position_in_grid.x) * NT + tile) * RPS * RO;
          const device uint32_t* wr[R];
          const device T* sr[R];
          const device T* brr[R];
          for (int r = 0; r < R; r++) {
            const int row = e * N + rowBase + (MODE == 1 ? 0 : r * RPS) + lr;
            const bool second = MODE == 1 && r == 1;
            wr[r] = (second ? w1 : w0) + row * KW;
            sr[r] = (second ? s1 : s0) + row * KG;
            brr[r] = (second ? b1 : b0) + row * KG;
          }
          for (int m0 = 0; m0 < c; m0 += MM) {
            const int cnt = min(MM, c - m0);
            const device T* xr[MM];
            for (int m = 0; m < MM; m++) {
              const int p = pairs[slot * TMAX + m0 + min(m, cnt - 1)];
              xr[m] = x + (MODE == 1 ? p / TOPK : p) * K;
            }
        \(inner)
            if (sgk == 0 && kl == 0) {
              for (int m = 0; m < MM; m++) {
                if (m < cnt) {
                  const int p = pairs[slot * TMAX + m0 + m];
                  if (MODE == 1) {
                    const float g = float(static_cast<T>(acc[0][m]));
                    const float u = float(static_cast<T>(acc[1][m]));
                    y[p * N + rowBase + lr] = static_cast<T>(g / (1.0f + metal::exp(-g)) * u);
                  } else {
                    for (int r = 0; r < R; r++) {
                      y[p * N + rowBase + r * RPS + lr] = static_cast<T>(acc[r][m]);
                    }
                  }
                }
              }
            }
          }
        """

    /// Gather variant without the bucket launch: one threadgroup row per
    /// router pair p. A threadgroup keeps going only if p is the first pair
    /// of its expert; each simdgroup then lists that expert's pairs in
    /// ascending order (prefix sums over the P indices) in threadgroup memory.
    static let gatherInlineSource: String = {
        let head = """
              const int slot = int(threadgroup_position_in_grid.y);
              const int c = counts[slot];
              if (c == 0) {
                return;
              }
              const int e = experts[slot];
            """
        let inlineHead = """
              threadgroup int plist_all[NT * KS * TMAX];
              threadgroup int* plist = plist_all + sg * TMAX;
              const int slot = int(threadgroup_position_in_grid.y);
              const uint ev = inds[slot];
              bool earlier = false;
              int c = 0;
              for (int q0 = 0; q0 < P; q0 += 32) {
                const int q = q0 + lane;
                const bool match = q < P && inds[q] == ev;
                earlier = earlier || (match && q < slot);
                const int pos = simd_prefix_exclusive_sum(match ? 1 : 0);
                if (match) {
                  plist[c + pos] = q;
                }
                c += simd_sum(match ? 1 : 0);
              }
              if (simd_any(earlier)) {
                return;
              }
              simdgroup_barrier(mem_flags::mem_threadgroup);
              const int e = int(ev);
            """
        precondition(gatherSource.contains(head))
        return gatherSource.replacingOccurrences(of: head, with: inlineHead)
            .replacingOccurrences(of: "pairs[slot * TMAX + ", with: "plist[")
    }()

    /// One threadgroup, thread e = expert e. Slots are the active experts in
    /// ascending expert order; each slot's pair list is in ascending pair
    /// order. Slots past the active count get count 0.
    static let bucketSource = """
          const int e = int(thread_position_in_grid.x);
          const int lane = int(thread_index_in_simdgroup);
          const int sg = int(simdgroup_index_in_threadgroup);
          const int nsg = int(simdgroups_per_threadgroup);
          int cnt = 0;
          if (e < E) {
            for (int p = 0; p < P; p++) {
              cnt += int(inds[p]) == e ? 1 : 0;
            }
          }
          const int active = cnt > 0 ? 1 : 0;
          const int pre = simd_prefix_exclusive_sum(active);
          const int tot = simd_sum(active);
          threadgroup int sgt[32];
          if (lane == 0) {
            sgt[sg] = tot;
          }
          threadgroup_barrier(mem_flags::mem_threadgroup);
          int base = 0;
          int all = 0;
          for (int i = 0; i < nsg; i++) {
            base += i < sg ? sgt[i] : 0;
            all += sgt[i];
          }
          if (active) {
            const int slot = base + pre;
            experts[slot] = e;
            counts[slot] = cnt;
            int c = 0;
            for (int p = 0; p < P; p++) {
              if (int(inds[p]) == e) {
                pairs[slot * TMAX + c] = p;
                c++;
              }
            }
          }
          if (e >= all && e < SLOTS) {
            counts[e] = 0;
            experts[e] = 0;
          }
        """

    nonisolated(unsafe) static let denseKernel = MLXFast.metalKernel(
        name: "moe_smallm_vb_dense",
        inputNames: ["x", "w", "scales", "biases"],
        outputNames: ["y"],
        source: denseSource,
        header: header
    )

    nonisolated(unsafe) static let gatherKernel = MLXFast.metalKernel(
        name: "moe_smallm_vb_gather",
        inputNames: ["x", "w0", "s0", "b0", "w1", "s1", "b1", "experts", "counts", "pairs"],
        outputNames: ["y"],
        source: gatherSource,
        header: header
    )

    nonisolated(unsafe) static let gatherInlineKernel = MLXFast.metalKernel(
        name: "moe_smallm_vb_gather_inline",
        inputNames: ["x", "w0", "s0", "b0", "w1", "s1", "b1", "inds"],
        outputNames: ["y"],
        source: gatherInlineSource,
        header: header
    )

    nonisolated(unsafe) static let bucketKernel = MLXFast.metalKernel(
        name: "moe_smallm_bucket",
        inputNames: ["inds"],
        outputNames: ["experts", "counts", "pairs"],
        source: bucketSource
    )

    struct Tiling: CustomStringConvertible {
        var r: Int
        var lpr: Int
        var ks: Int
        var nt: Int
        var xs: Int

        var description: String { "r\(r)-l\(lpr)-ks\(ks)-nt\(nt)-xs\(xs)" }

        /// Threadgroup memory at MM = 8 (the largest per-launch row count).
        var threadgroupBytes: Int {
            let red = (ks > 1 ? nt * (ks - 1) : 1) * r * 8 * 32 * 4
            let stage = xs == 1 ? ks * 8 * (lpr * 32 + lpr * 4) * 4 : 16
            return red + stage
        }
    }

    /// Tiling from the shape only (never from M), so results are batch
    /// invariant. Rows per simdgroup = (32 / lpr) * r; aim for >= 512
    /// simdgroups with KS <= 2, then pack 4 simdgroups per threadgroup.
    static func denseTiling(n: Int, k: Int, r: Int, lpr: Int, xs: Int, ks fixedKS: Int? = nil) -> Tiling? {
        let rowsPerSG = (32 / lpr) * r
        guard n % rowsPerSG == 0 else { return nil }
        let tiles = n / rowsPerSG
        var ks = fixedKS ?? 1
        if fixedKS == nil {
            while ks < 2, tiles * ks < 512, k % (lpr * 32 * ks * 2) == 0 {
                ks *= 2
            }
        }
        guard k % (lpr * 32 * ks) == 0 else { return nil }
        var nt = max(1, 4 / ks)
        while nt > 1, tiles % nt != 0 {
            nt /= 2
        }
        let t = Tiling(r: r, lpr: lpr, ks: ks, nt: nt, xs: xs)
        return t.threadgroupBytes <= 32768 ? t : nil
    }

    /// x: [M, K] row-contiguous, M rows in passes of denseRowsPerPass (the
    /// pass size never changes reduction order); w: [N, K/8] uint32;
    /// scales/biases: [N, K/64].
    static func dense(
        _ x: MLXArray, w: MLXArray, scales: MLXArray, biases: MLXArray, tiling: Tiling
    ) -> MLXArray {
        let m = x.dim(0)
        let k = x.dim(1)
        let n = w.dim(0)
        let dtype = x.dtype
        let rowsPerSG = (32 / tiling.lpr) * tiling.r
        let groups = n / rowsPerSG / tiling.nt
        let threads = 32 * tiling.ks * tiling.nt
        return denseKernel(
            [x, w, scales.asType(dtype), biases.asType(dtype)],
            template: [
                ("T", dtype), ("MROWS", m), ("MM", min(m, denseRowsPerPass)), ("R", tiling.r), ("KS", tiling.ks),
                ("NT", tiling.nt),
                ("LPR", tiling.lpr), ("XS", tiling.xs), ("K", k), ("N", n),
            ],
            grid: (groups * threads, 1, 1),
            threadGroup: (threads, 1, 1),
            outputShapes: [[m, n]],
            outputDTypes: [dtype]
        )[0]
    }

    /// Dense activation rows per weight pass (lab knob).
    nonisolated(unsafe) static var denseRowsPerPass = 8

    struct QWeight {
        let w: MLXArray
        let scales: MLXArray
        let biases: MLXArray

        var experts: Int { w.dim(0) }
        var outDims: Int { w.dim(1) }
        var inDims: Int { w.dim(2) * 8 }
    }

    /// Per-expert token lists from router indices [T, TOPK].
    static func bucket(_ inds: MLXArray, experts: Int) -> (experts: MLXArray, counts: MLXArray, pairs: MLXArray, slots: Int, tmax: Int) {
        let t = inds.dim(0)
        let topk = inds.dim(1)
        let p = t * topk
        let slots = min(experts, p)
        let threads = (experts + 31) / 32 * 32
        let out = bucketKernel(
            [inds.reshaped([p])],
            template: [("E", experts), ("P", p), ("SLOTS", slots), ("TMAX", t)],
            grid: (threads, 1, 1),
            threadGroup: (threads, 1, 1),
            outputShapes: [[slots], [slots], [slots * t]],
            outputDTypes: [.int32, .int32, .int32]
        )
        return (out[0], out[1], out[2], slots, t)
    }

    /// Grouped-kernel tiling, fixed per projection (never per token count).
    /// gate/up: R = 2 (gate row + up row). down: R = 1.
    /// Tokens per expert handled per weight pass (MM); more tokens on one
    /// expert take further passes. Does not change any reduction order.
    nonisolated(unsafe) static var maxTokensPerPass = 2
    nonisolated(unsafe) static var gateUpTiling = Tiling(r: 2, lpr: 8, ks: 1, nt: 4, xs: 0)
    nonisolated(unsafe) static var downTiling = Tiling(r: 1, lpr: 4, ks: 1, nt: 4, xs: 0)

    static func parseTiling(_ text: String) -> Tiling? {
        let v = text.split(separator: "-").compactMap { Int($0) }
        guard v.count == 5 else { return nil }
        return Tiling(r: v[0], lpr: v[1], ks: v[2], nt: v[3], xs: v[4])
    }

    static func applyTilingOverrides(gateUp: String?, down: String?) throws {
        if let gateUp {
            guard let t = parseTiling(gateUp), t.r == 2 else { throw CocoaError(.formatting) }
            gateUpTiling = t
        }
        if let down {
            guard let t = parseTiling(down) else { throw CocoaError(.formatting) }
            downTiling = t
        }
    }

    /// Grouped SwitchGLU: x [T, K], inds [T, TOPK] -> [T, TOPK, N_down].
    /// `stages` < 3 stops early for cost attribution: 1 = bucket only
    /// (returns counts), 2 = bucket + gate/up (returns the activation).
    static func groupedSwitchGLU(
        _ x: MLXArray, inds: MLXArray, gate: QWeight, up: QWeight, down: QWeight, stages: Int = 3
    ) -> MLXArray {
        let t = x.dim(0)
        let k = x.dim(1)
        let topk = inds.dim(1)
        let dtype = x.dtype
        if inlineBucket {
            return groupedInline(x, inds: inds, gate: gate, up: up, down: down, stages: stages)
        }
        let b = bucket(inds, experts: gate.experts)
        if stages == 1 { return b.counts }
        let mm = min(maxTokensPerPass, t >= 8 ? 8 : (t >= 4 ? 4 : (t >= 2 ? 2 : 1)))
        let hidden = gate.outDims
        func launch(_ inputs: [MLXArray], mode: Int, tl: Tiling, kIn: Int, nOut: Int) -> MLXArray {
            let rowsPerSG = (32 / tl.lpr) * (mode == 1 ? 1 : tl.r)
            let groups = nOut / rowsPerSG / tl.nt
            let threads = 32 * tl.ks * tl.nt
            return gatherKernel(
                inputs + [b.experts, b.counts, b.pairs],
                template: [
                    ("T", dtype), ("MODE", mode), ("MM", mm), ("R", tl.r), ("KS", tl.ks), ("NT", tl.nt),
                    ("LPR", tl.lpr), ("XS", tl.xs), ("K", kIn), ("N", nOut), ("TOPK", topk), ("TMAX", b.tmax),
                ],
                grid: (groups * threads, b.slots, 1),
                threadGroup: (threads, 1, 1),
                outputShapes: [[t * topk, nOut]],
                outputDTypes: [dtype]
            )[0]
        }
        let act = launch(
            [x, gate.w, gate.scales, gate.biases, up.w, up.scales, up.biases],
            mode: 1, tl: gateUpTiling, kIn: k, nOut: hidden)
        if stages == 2 { return act }
        let y = launch(
            [act, down.w, down.scales, down.biases, down.w, down.scales, down.biases],
            mode: 2, tl: downTiling, kIn: hidden, nOut: down.outDims)
        return y.reshaped([t, topk, down.outDims])
    }

    /// Skip the bucket launch (gather kernels find their expert's pairs).
    nonisolated(unsafe) static var inlineBucket = false

    static func groupedInline(
        _ x: MLXArray, inds: MLXArray, gate: QWeight, up: QWeight, down: QWeight, stages: Int
    ) -> MLXArray {
        let t = x.dim(0)
        let k = x.dim(1)
        let topk = inds.dim(1)
        let p = t * topk
        let dtype = x.dtype
        let flat = inds.reshaped([p]).asType(.uint32)
        let mm = min(maxTokensPerPass, t >= 8 ? 8 : (t >= 4 ? 4 : (t >= 2 ? 2 : 1)))
        let hidden = gate.outDims
        func launch(_ inputs: [MLXArray], mode: Int, tl: Tiling, kIn: Int, nOut: Int) -> MLXArray {
            let rowsPerSG = (32 / tl.lpr) * (mode == 1 ? 1 : tl.r)
            let groups = nOut / rowsPerSG / tl.nt
            let threads = 32 * tl.ks * tl.nt
            return gatherInlineKernel(
                inputs + [flat],
                template: [
                    ("T", dtype), ("MODE", mode), ("MM", mm), ("R", tl.r), ("KS", tl.ks), ("NT", tl.nt),
                    ("LPR", tl.lpr), ("XS", tl.xs), ("K", kIn), ("N", nOut), ("TOPK", topk), ("TMAX", t), ("P", p),
                ],
                grid: (groups * threads, p, 1),
                threadGroup: (threads, 1, 1),
                outputShapes: [[p, nOut]],
                outputDTypes: [dtype]
            )[0]
        }
        if stages == 1 { return flat }
        let act = launch(
            [x, gate.w, gate.scales, gate.biases, up.w, up.scales, up.biases],
            mode: 1, tl: gateUpTiling, kIn: k, nOut: hidden)
        if stages == 2 { return act }
        let y = launch(
            [act, down.w, down.scales, down.biases, down.w, down.scales, down.biases],
            mode: 2, tl: downTiling, kIn: hidden, nOut: down.outDims)
        return y.reshaped([t, topk, down.outDims])
    }

    /// MLX reference for the same computation (what SwitchGLU does).
    static func stockSwitchGLU(
        _ x: MLXArray, inds: MLXArray, gate: QWeight, up: QWeight, down: QWeight
    ) -> MLXArray {
        let t = x.dim(0)
        let topk = inds.dim(1)
        var xe = expandedDimensions(x, axes: [-2, -3]) // [T, 1, 1, K]
        var idx = inds
        var inv = MLXArray()
        let doSort = inds.size >= 64
        if doSort {
            (xe, idx, inv) = gatherSort(x: xe, indices: inds)
        }
        func g(_ v: MLXArray, _ q: QWeight) -> MLXArray {
            gatherQuantizedMM(
                v, q.w, scales: q.scales, biases: q.biases, rhsIndices: idx, transpose: true,
                groupSize: 64, bits: 4, sortedIndices: doSort)
        }
        let a = compiledSiluProduct(g(xe, gate), g(xe, up))
        var y = g(a, down)
        if doSort {
            y = scatterUnsort(x: y, invOrder: inv, shape: inds.shape)
        }
        return y.reshaped([t, topk, down.outDims])
    }
}

/// Lab replacement for Qwen35SparseMoeBlock: same math, with routed-expert
/// path selection, ablation switches for cost attribution, and router
/// capture for overlap statistics.
final class LabMoEBlock: Module, UnaryLayer {
    enum Routed: String {
        case stock
        case grouped
    }

    nonisolated(unsafe) static var routed: Routed = .stock
    nonisolated(unsafe) static var ablateRouter = false
    nonisolated(unsafe) static var ablateRouted = false
    nonisolated(unsafe) static var ablateShared = false
    /// When non-nil, every call appends (layer, x [T, K], inds [T, TOPK]).
    nonisolated(unsafe) static var captured: [(Int, MLXArray, MLXArray)]?

    let layer: Int
    let topK: Int
    let normTopkProb: Bool
    let numExperts: Int
    let gate: UnaryLayer
    let switchMLP: SwitchGLU
    let sharedExpert: UnaryLayer
    let sharedExpertGate: UnaryLayer
    let gateW: MoESmallM.QWeight
    let upW: MoESmallM.QWeight
    let downW: MoESmallM.QWeight

    init?(_ block: Module, layer: Int) {
        let mods = Dictionary(uniqueKeysWithValues: block.namedModules().map { ($0.0, $0.1) })
        let mirror = Dictionary(
            Mirror(reflecting: block).children.compactMap { c in c.label.map { ($0, c.value) } },
            uniquingKeysWith: { a, _ in a })
        guard let gate = mods["gate"] as? UnaryLayer,
              let sw = mods["switch_mlp"] as? SwitchGLU,
              let shared = mods["shared_expert"] as? UnaryLayer,
              let sharedGate = mods["shared_expert_gate"] as? UnaryLayer,
              let topK = mirror["topK"] as? Int,
              let norm = mirror["normTopkProb"] as? Bool,
              let numExperts = mirror["numExperts"] as? Int
        else { return nil }
        func q(_ key: String) -> MoESmallM.QWeight? {
            guard let m = mods["switch_mlp.\(key)"] as? QuantizedSwitchLinear, m.bits == 4, m.groupSize == 64,
                  m.mode == .affine
            else { return nil }
            let p = Dictionary(uniqueKeysWithValues: m.parameters().flattened())
            guard let w = p["weight"], let s = p["scales"], let b = p["biases"] else { return nil }
            return MoESmallM.QWeight(w: w, scales: s, biases: b)
        }
        guard let g = q("gate_proj"), let u = q("up_proj"), let d = q("down_proj") else { return nil }
        self.layer = layer
        self.topK = topK
        self.normTopkProb = norm
        self.numExperts = numExperts
        self.gate = gate
        self.switchMLP = sw
        self.sharedExpert = shared
        self.sharedExpertGate = sharedGate
        self.gateW = g
        self.upW = u
        self.downW = d
        super.init()
        self.freeze()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let lead = Array(x.shape.dropLast())
        let t = x.size / x.dim(-1)
        var inds: MLXArray
        var scores: MLXArray
        if Self.ablateRouter {
            // Fixed, varied routing (8 distinct experts per token) with
            // uniform weights: the routed path still sees realistic shapes.
            let base = MLXArray((0 ..< Int32(t * topK)).map { ($0 * 37 + 11) % Int32(numExperts) }, [t, topK])
            inds = base.asType(.uint32).reshaped(lead + [topK])
            scores = MLXArray.ones(lead + [topK], dtype: x.dtype) / Float(topK)
        } else {
            var gates = gate(x)
            gates = MLX.softmax(gates, axis: -1, precise: true)
            let kth = gates.dim(-1) - topK
            inds = MLX.argPartition(gates, kth: kth, axis: -1)[.ellipsis, kth...]
            scores = MLX.takeAlong(gates, inds, axis: -1)
            if normTopkProb {
                scores = scores / scores.sum(axis: -1, keepDims: true)
            }
        }
        if Self.captured != nil {
            Self.captured!.append((layer, x.reshaped([t, -1]), inds.reshaped([t, topK])))
        }
        var out: MLXArray?
        if !Self.ablateRouted {
            let y: MLXArray
            switch Self.routed {
            case .stock:
                y = switchMLP(x, inds)
            case .grouped:
                if t <= 64, x.dtype == .bfloat16 || x.dtype == .float16 {
                    y = MoESmallM.groupedSwitchGLU(
                        x.reshaped([t, -1]), inds: inds.reshaped([t, topK]), gate: gateW, up: upW, down: downW
                    ).reshaped(lead + [topK, downW.outDims])
                } else {
                    y = switchMLP(x, inds)
                }
            }
            out = weightedExpertSum(y, scores)
        }
        if !Self.ablateShared {
            let s = sigmoid(sharedExpertGate(x)) * sharedExpert(x)
            out = out.map { $0 + s } ?? s
        }
        return out ?? MLXArray.zeros(x.shape, dtype: x.dtype)
    }

    /// Replaces every Qwen3.5 MoE block (outside the MTP head). Returns count.
    @discardableResult
    static func install(in model: Module) -> Int {
        var updates: [(String, Module)] = []
        for (key, module) in model.namedModules()
        where String(describing: type(of: module)) == "Qwen35SparseMoeBlock" && !key.contains("mtp") {
            let parts = key.split(separator: ".")
            guard let i = parts.firstIndex(of: "layers"), i + 1 < parts.count, let layer = Int(parts[i + 1]),
                  let lab = LabMoEBlock(module, layer: layer)
            else { continue }
            updates.append((key, lab))
        }
        if !updates.isEmpty {
            _ = model.update(modules: ModuleChildren.unflattened(updates))
        }
        return updates.count
    }
}

/// Ablation stand-in: a QuantizedLinear that returns zeros of the right shape.
final class ZeroQuantizedLinear: QuantizedLinear {
    init(_ other: QuantizedLinear) {
        super.init(
            weight: other.weight, bias: other.bias, scales: other.scales, biases: other.biases,
            groupSize: other.groupSize, bits: other.bits, mode: other.mode)
        self.freeze()
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXArray.zeros(Array(x.shape.dropLast()) + [weight.dim(0)], dtype: x.dtype)
    }

    /// Replaces QuantizedLinear modules whose key matches `filter`.
    @discardableResult
    static func install(in model: Module, where filter: (String) -> Bool) -> Int {
        var updates: [(String, Module)] = []
        for (key, module) in model.leafModules().flattened() {
            if let q = module as? QuantizedLinear, !(q is ZeroQuantizedLinear), filter(key), !key.contains("mtp") {
                updates.append((key, ZeroQuantizedLinear(q)))
            }
        }
        if !updates.isEmpty {
            _ = model.update(modules: ModuleChildren.unflattened(updates))
        }
        return updates.count
    }
}
#endif
