# SPEC-048 native MTP: A3B small-batch MoE kernels (#1770)

Lab branch `lab/moe-smallm` (local only, based on `lab/qmv-smallm`,
mlx-swift 0.32.3 / mlx v0.32.2). Measured 2026-10-01 on the Mac Studio M3
Ultra 256 GB with Qwen3.6-35B-A3B 4-bit (40 layers, 30 linear-attention +
10 full-attention, 256 experts, 8 routed + 1 shared, hidden 2048, expert
512, affine g64; router and shared-expert gate are 8-bit). Follows
`QMV_SMALLM_KERNEL_2026-10-01.md`.

Code (all `#if DEBUG || MACPROVIDER_LAB_HARNESS`):

- `phase3-binary/Sources/macprovider-cli/MoESmallMKernel.swift`: the
  `MLXFast.metalKernel` kernels, `LabMoEBlock` (drop-in for
  `Qwen35SparseMoeBlock` with stock/grouped routed paths, ablation switches
  and router capture) and `ZeroQuantizedLinear` (ablation stand-in).
- `phase3-binary/Sources/macprovider-cli/MLXMoESmallMProbeModes.swift`:
  `mlx-smallm-probe --mode overlap|greal|gbench|flips`.
- `SmallMQMVKernel.swift`: `vb-*` configs route the dense kernel through the
  existing `kcheck/kbench/kreal` modes and `--smallm-qmv`.
- `native-mtp-forward-microbench`: `--moe-smallm off|stock|grouped`,
  `--moe-inline-bucket`, `--ablate attnproj,router,routed,shared,lmhead`,
  `--token-source random|text`, `--gate-up-tiling`, `--down-tiling`,
  `--moe-mm`.

Raw logs: Studio `/Users/a1/moe-smallm-window-<UTC>/` (three windows),
scripts in `/Users/a1/moe-smallm-lab/`.

## Answer

Neither kernel moves A3B much. On M3 Ultra the A3B `[B, w]` forward is
bound by per-kernel latency, not by weight bandwidth, so streaming each
expert once instead of once per (token, expert) pair saves little.

- Routed experts plus router are 33-43% of GPU time. At `[1,1]` the expert
  matmuls alone move 480 MB in about 1.8 ms, which is about 270 GB/s against
  800 GB/s peak. The router adds about 1.3 ms of small kernels. MLX's
  `gather_qmv` already gets most of the expert reuse through the cache.
- The grouped kernel, with the inline-bucket variant, is faster than MLX on
  the routed-expert block for T ≤ 8 verify tokens: 1.04-1.24x on real weights
  timed independently, 0.95-1.20x in a dependent chain. It reaches parity at
  T = 16 and is slower above that.
- End to end, that is a 3-5% GPU-time cut at B ≤ 4. About 0.5 ms per forward
  of extra `metalKernel` host graph-build time cancels it.
- The SIMT dense kernel matches MLX `qmv` at M = 1-2 and loses to `qmv_wide`
  from M = 3. M3 Ultra has too little ALU per byte for M FMAs per weight.
  The `lab/qmv-smallm` MMA kernel stays the better dense path at M ≥ 5.

Both kernels are bit batch invariant: a row's output is the same at M = 1 and
inside an M-row call. That property is the one durable result for MTP
exactness.

## 1a. Where A3B small-M time goes

Ablation inside the real forward (dense caches, 384-token prefill, plain
variant, GPU eval p50 ms, 20 iterations, `--token-source text`). Each
column is the time removed when that part is skipped:

- **attn proj**: every attention and linear-attention `QuantizedLinear`
  returns zeros.
- **router+routed**: the routed-expert branch is removed. MLX then prunes the
  now-unused router graph as well.
- **shared**: the shared expert and its gate are removed.
- **lm_head**: lm_head returns zeros.
- **other**: the remainder: attention/SDPA, gated-delta recurrence, conv,
  norms, embedding, residuals and the combine.

| [B,w] | total | attn proj | router+routed | (router alone) | shared | lm_head | other |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1,1 | 9.47 | 1.99 | 3.16 (33%) | 1.34 | 0.93 | 0.55 | 2.84 |
| 1,2 | 11.39 | 2.90 | 4.19 (37%) | 1.28 | 0.83 | 0.60 | 2.87 |
| 2,1 | 11.44 | 2.88 | 4.26 (37%) | 1.36 | 0.77 | 0.61 | 2.92 |
| 2,2 | 14.56 | 3.83 | 5.85 (40%) | 1.44 | 0.97 | 0.96* | 2.95 |
| 4,1 | 14.78 | 3.98 | 5.91 (40%) | 1.56 | 0.95 | 0.96 | 2.98 |
| 4,2 | 20.04 | 5.73 | 8.26 (41%) | — | 1.07 | 1.25 | 3.73 |
| 8,1 | 20.54 | 5.86 | 8.52 (41%) | — | 1.28 | 1.68 | 3.20 |
| 8,2 | 29.33 | 9.14 | 12.58 (43%) | — | 1.52 | 2.39 | 3.70 |

"Router alone" comes from window 1. There the router was replaced by fixed
synthetic indices (8 distinct experts per token) while the routed path kept
running. The figure is valid while synthetic and real distinct counts are
close (T ≤ 4). From T = 8 the synthetic set has more distinct experts, so the
estimate is confounded and is omitted. \* The text-token lm_head cell was
noise (negative), so the random-token value is shown. Random-token totals
agree within 1-3%.

Three things stand out:

- At `[1,1]` the router (an 8-bit 256x2048 gate, a precise softmax,
  argPartition, takeAlong and a normalize) costs about 1.3 ms. That is about
  33 µs per layer, almost as much as the 1.8 ms of routed expert matmuls.
- The routed path moves about 480 MB per `[1,1]` forward (40 x 8 x 1.5 MB) in
  roughly 1.8 ms, which is about 270 GB/s.
- Graph build adds another 1.4-1.6 ms on the host.

## 1b. Expert overlap (real routing)

The 8 realistic prompts were greedy-decoded for 64 tokens with router
capture on all 40 layers. A verify set is B rows × (1+k) consecutive decode
positions. The table gives the distinct experts per layer, averaged over
layers and window starts.

| B | k | tokens | pairs | distinct mean (p10-p90) | pairs/distinct | max tokens on one expert |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0 | 1 | 8 | 8.0 | 1.00 | 1.0 |
| 1 | 1 | 2 | 16 | 13.4 (11-16) | 1.19 | 1.8 |
| 1 | 2 | 3 | 24 | 18.1 (14-22) | 1.32 | 2.5 |
| 1 | 3 | 4 | 32 | 22.3 (17-27) | 1.44 | 3.2 |
| 2 | 0 | 2 | 16 | 15.8 | 1.01 | 1.2 |
| 2 | 1 | 4 | 32 | 26.4 (23-30) | 1.21 | 2.2 |
| 2 | 2 | 6 | 48 | 35.4 (30-41) | 1.36 | 3.1 |
| 2 | 3 | 8 | 64 | 43.3 (36-50) | 1.48 | 3.9 |
| 4 | 0 | 4 | 32 | 29.4 (26-32) | 1.09 | 2.0 |
| 4 | 1 | 8 | 64 | 46.7 (39-53) | 1.37 | 3.5 |
| 4 | 2 | 12 | 96 | 60.4 (50-70) | 1.59 | 4.9 |
| 4 | 3 | 16 | 128 | 71.8 (60-84) | 1.78 | 6.3 |
| 8 | 0 | 8 | 64 | 52.8 (46-58) | 1.21 | 3.1 |
| 8 | 1 | 16 | 128 | 78.3 (67-88) | 1.63 | 5.6 |
| 8 | 2 | 24 | 192 | 96.5 (83-110) | 1.99 | 8.0 |
| 8 | 3 | 32 | 256 | 110.8 (95-126) | 2.31 | 10.4 |

Consecutive positions of one row share experts much more than different rows
do. At k = 1 a second position adds about 5.4 new experts per row, against 8
for an unrelated token. The best possible weight-traffic cut for a `[B,2]`
verify is 1.2-1.6x.

## 2. Kernels

**(a) Dense `vb` (SIMT, llama.cpp `mul_mv_ext` shape on MLX affine g64).**

- LPR lanes share one weight row. At LPR = 8 the 8 lanes read one full
  128-byte line per step. Each lane loads 16 weight bytes (32 nibbles).
- Each weight is dequantized once (`q*s + b`, float), then applied with FMAs
  to every activation row in registers.
- Activations are read with uniform/broadcast loads and converted per lane
  (`xs0`), or staged once per threadgroup as float in padded threadgroup
  memory (`xs1`).
- Lane partial sums go through a fixed `simd_shuffle_xor` butterfly, and the
  K-split simdgroups are summed in a fixed order. M rows run in in-kernel
  passes of ≤ 8.
- Tiling depends only on the shape, so reduction order never depends on M.

It deviates from the brief in one place. The brief proposed applying the
group bias as `s·Σx·q + b·Σx`. The kernel dequantizes instead, because that
costs 1 extra op per weight against M/R extra ops per weight for `Σx`. Both
are float-exact to the same order.

The first layout gave each lane its own row (no lane split). It thrashed L1:
every load instruction touched 32 lines. It was 6x slower on lm_head at R = 4.

**(b) Grouped MoE.**

- `bucket` is one threadgroup with one thread per expert. A prefix sum lists
  the active experts in ascending order, each with its pairs in ascending
  order.
- `gather` MODE 1 fuses gate and up (R = 2: a gate row and an up row per lane)
  and applies SiLU·up in the epilogue. Gate and up are rounded to bf16 first,
  as the stock path does. MODE 2 is down.
- Each threadgroup is one (active expert, row tile). It applies the
  dequantized weights to every token routed to that expert, using the same
  inner loop as (a), in passes of MM tokens. MM = 2 is best: MM = 8 costs
  registers and occupancy.
- Bucketing costs about 8 µs per layer (a serial scan in one threadgroup). The
  `--moe-inline-bucket` variant removes that launch. It launches one
  threadgroup row per router pair. A threadgroup continues only if its pair
  is the first one for that expert. It then builds the pair list with
  `simd_prefix_exclusive_sum` over the P ≤ 128 indices.
- Output is per pair `[T, 8, 2048]` and is combined by the stock
  `weightedExpertSum`.

## 3. Kernel µs vs MLX

### Dense, independent matmuls

Weights stream from DRAM (≥ 1 GiB of copies). Each cell is MLX / best `vb`
(of r1-l8-xs0, r2-l8-xs0, r2-l8) / `lab/qmv-smallm` MMA (`mma-nt2-ks4-act`),
in µs.

| N x K (A3B role) | M=1 | M=2 | M=3 | M=4 | M=8 | M=16 |
|---|---:|---:|---:|---:|---:|---:|
| 8192x2048 (q_proj, in_proj_qkv) | 14.5 / 15.3 / 30.5 | 15.5 / 17.7 / 27.7 | 19.2 / 19.9 / 27.5 | 24 / 25 / 28 | 45 / 56 / 27 | 74 / 112 / 57 |
| 4096x2048 (in_proj_z) | 7.7 / 7.9 / 13.1 | 8.3 / 8.8 / 13.9 | 9.9 / 10.3 / 14.7 | 12.3 / 13.1 / 14.0 | 23 / 29 / 14 | 45 / 56 / 29 |
| 2048x4096 (o_proj, out_proj) | 8.4 / 7.9 / 13.2 | 8.7 / 9.1 / 14.1 | 10.3 / 10.5 / 14.8 | 12.9 / 13.1 / 14.0 | 24 / 29 / 14 | 46 / 76 / 29 |
| 512x2048 (k/v, shared gate/up) | 3.2 / 3.3 / 3.6 | 3.3 / 3.2 / 3.5 | 3.2 / 3.3 / 3.4 | 3.2 / 3.5 / 3.2 | 5.0 / 5.3 / 3.3 | 6.5 / 8.5 / 4.6 |
| 2048x512 (shared down) | 3.2 / 3.3 / 4.0 | 3.9 / 3.5 / 4.1 | 4.9 / 4.2 / 4.5 | 4.9 / 4.1 / 4.3 | 5.6 / 5.2 / 4.8 | 6.9 / 8.7 / 5.2 |
| 248320x2048 (lm_head) | 416 / 445 / 763 | 456 / 494 / 812 | 582 / 582 / 814 | 767 / 733 / 816 | 1498 / 1674 / 966 | 1927 / 3329 / 1767 |

Dependent chains (`--serial`) show the same ordering.

The `xs1` staging was slower than `xs0` on M3 Ultra, by up to 2x at M ≥ 2. On
the local M5 they were equal.

### Grouped MoE, synthetic weights at the measured overlap

These are full routed blocks (gate + up + SiLU + down) in µs per layer, over
6 independent layer copies. They include about 30 µs per layer of eval
overhead, which is the same on both sides.

| T | distinct | MLX `gather_qmm` | grouped (bucket) | grouped (inline) | inline speedup |
|---:|---:|---:|---:|---:|---:|
| 1 | 8 | 83 | 78 | 67 | 1.24x |
| 2 | 13 | 103 | 99 | 75 | 1.37x |
| 4 | 26 | 140 | 138 | 107 | 1.30x |
| 8 | 47 | 194 | 204 | 174 | 1.12x |
| 8 | 53 | 202 | 218 | 185 | 1.09x |
| 16 | 78 | 293 | 304 | 282 | 1.04x |

### Grouped MoE, real A3B weights and real routing

All 40 layers, with the real post-norm MoE inputs and router indices
captured from decode. Values are µs per layer, `--moe-inline-bucket`.

| B | w | T | distinct | MLX indep | grouped indep | x | MLX serial | grouped serial | x |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 1 | 8.0 | 47.8 | 45.8 | 1.04 | 68.0 | 56.9 | 1.20 |
| 1 | 2 | 2 | 11.5 | 57.4 | 46.3 | 1.24 | 85.9 | 75.2 | 1.14 |
| 2 | 1 | 2 | 15.5 | 60.8 | 51.2 | 1.19 | 89.2 | 83.8 | 1.07 |
| 2 | 2 | 4 | 23.1 | 87.9 | 73.3 | 1.20 | 121.0 | 117.1 | 1.03 |
| 4 | 1 | 4 | 25.7 | 93.7 | 81.2 | 1.15 | 124.5 | 123.3 | 1.01 |
| 4 | 2 | 8 | 37.4 | 148.6 | 129.8 | 1.15 | 182.5 | 192.9 | 0.95 |
| 8 | 1 | 8 | 50.1 | 161.4 | 146.6 | 1.10 | 194.9 | 198.8 | 0.98 |
| 8 | 2 | 16 | 69.4 | 256.0 | 257.3 | 0.99 | 293.9 | 318.9 | 0.92 |
| 8 | 4 | 32 | 101.6 | 462.9 | 499.9 | 0.93 | — | — | — |

With the separate bucket launch, the independent figures were 0.96-1.07x.

## Correctness

**Dense `vb`.**

- Max relative error vs the fp32 dequantized reference is 1.9-4.5e-3 on
  synthetic and real A3B weights (layers 3/4 and lm_head, real final hidden
  states). That equals MLX batched abs error. At M = 1 the abs error is
  1.3-3.6x lower than MLX `qmv`.
- Rows are bit batch invariant: each row alone (M = 1) against inside the
  M-row call has 0 mismatches, for every shape and every M from 1 to 16.
- lm_head argmax over 136 real hidden rows has 1 flip vs per-row `qmv`, the
  same as MLX batched. Against fp32 it has 3-4 flips; MLX `qmv` has 2-3.

**Grouped.** On real weights, all 40 layers, it has max relative error 5.0-8.6e-3
vs an fp32 `gather_qmm` reference. MLX's own `gather_qmm` has 1.0-2.4e-2.
Token 0 computed alone equals token 0 inside the T-token call, bit for bit,
for every (B, w). About 86% of bf16 outputs differ from MLX by about 1 ulp.

**Final logits (`flips`).** Prompts are greedy-decoded by the stock path, then
teacher-forced as `[B, w]` forwards with stock vs lab kernels. Results are
argmax flips over 48 positions × rows.

Each B has 48 positions per row. "lab vs stock" is the same `[B, w]` with
the lab kernels against the stock kernels. "[B,1] vs [B,2]" is the same path
run at both shapes.

| Lab path | B | lab vs stock, w=1 | lab vs stock, w=2 | stock [B,1] vs [B,2] | lab [B,1] vs [B,2] |
|---|---:|---:|---:|---:|---:|
| grouped MoE only | 4 | 1 / 192 | 1 / 192 | 0 | 0 |
| grouped MoE only | 8 | 4 / 384 | 5 / 384 | 5 | 6 |
| grouped MoE + `vb` dense | 4 | 2 / 192 | 2 / 192 | 0 | 0 |
| grouped MoE + `vb` dense | 8 | 4 / 384 | 5 / 384 | 5 | **0** |

- Every lab-vs-stock flip falls among the stock near-ties (top-2 margin
  < 0.25: 4-15 positions). That is the same drift class as R005 and
  `QMV_SMALLM_KERNEL`.
- Max |Δlogit| is 3-8.5 after 48 teacher-forced steps. Recurrent-state drift
  through the 30 gated-delta layers compounds the ulp-level differences.
- With every 4-bit linear and the routed experts on the batch-invariant
  kernels, `[8,1]` and `[8,2]` agree on all 384 argmaxes. Stock MLX flips 5
  of them between those shapes.
- Not yet invariant: the 8-bit router and shared-expert gate (MLX `qmv`),
  SDPA, and the gated-delta kernel. Logits were not compared for bit
  equality.

## 3b. End-to-end forward

`native-mtp-forward-microbench`, A3B, dense caches, plain variant, 384-token
prefill, 30 iterations. Each figure is the mean of two runs (runs agreed
within 1%). Token ids are consecutive real text per row (`--token-source
text`), so routing overlap is realistic. Random ids give the same totals
within 1-5%.

Total ms p50, which includes graph build:

| B | stock [B,1] | stock [B,2] | 2/1 | grouped [B,1] | grouped [B,2] | 2/1 | grouped+vb [B,1] | grouped+vb [B,2] | 2/1 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 11.20 | 13.14 | 1.17 | 11.21 | 13.12 | 1.17 | 13.25 | 14.92 | 1.13 |
| 2 | 13.19 | 16.47 | 1.25 | 13.21 | 16.69 | 1.26 | 15.03 | 19.81 | 1.32 |
| 4 | 16.71 | 22.28 | 1.33 | 16.89 | 23.09 | 1.37 | 19.99 | 29.46 | 1.47 |
| 8 | 22.64 | 31.74 | 1.40 | 23.17 | 33.72 | 1.46 | 29.72 | 46.36 | 1.56 |

"grouped" is the grouped MoE with inline bucket, dense stock. "grouped+vb"
also routes every 4-bit linear through `vb-r2-xs0`.

GPU eval only, stock vs grouped, in ms:

| B | [B,1] | [B,2] |
|---:|---:|---:|
| 1 | 9.55 → 9.19 (-3.8%) | 11.50 → 11.12 (-3.3%) |
| 2 | 11.53 → 11.13 (-3.5%) | 14.81 → 14.68 (-0.9%) |
| 4 | 15.02 → 14.87 (-1.0%) | 20.40 → 21.04 (+3.1%) |
| 8 | 20.77 → 21.12 (+1.7%) | 29.91 → 31.70 (+6.0%) |

Graph build rises from 1.4 to 1.75 ms (80 extra `metalKernel` calls per
forward). With `vb` dense it reaches 3.1 ms (391 calls). Window 1 measured
the bucketed (non-inline) grouped path on random ids, and it was worse:
`[8,2]` GPU 35.3 ms.

## Verdict and integration path

**No-go on M3 Ultra as built, for A3B throughput.** The `[B,2]/[B,1]` ratio
does not improve: 1.17/1.25/1.33/1.40 stock against 1.17/1.26/1.37/1.46
grouped.

- The grouped kernel's real gain is 10-24% of the routed-expert block at
  T ≤ 8, worth 3-4% of GPU time at B ≤ 2. The host cost of `metalKernel`
  cancels it, and from T ≥ 16 it is a loss.
- The dense SIMT kernel only reaches parity at M ≤ 2.
- The A3B small-M forward is a dispatch-latency problem: about 40 layers ×
  about 25 dependent small kernels. The router alone (6 tiny kernels per
  layer) costs about as much as the routed expert matmuls at `[1,1]`.
- "Other" plus attention projections take 50-55%, and none of that is
  weight bandwidth.

What would move A3B is **fewer launches per layer**, not better matmul inner
loops:

1. A fused router: 8-bit gate GEMV + softmax + top-8 + normalize in one
   kernel, saving about 1 ms per forward.
2. A fused routed block: inline bucket + gate/up/SiLU + down + weighted
   combine (+ shared expert) in one or two launches.
3. Removing per-call host JIT/hash.

That is the vLLM `fused_moe` and llama.cpp `mul_mm_id` direction, applied
at small T.

The one result worth keeping is **batch invariance**. The `vb` and grouped
kernels give bit-identical rows regardless of M or co-routed tokens. With
both on, `[8,1]` and `[8,2]` agree on every argmax where stock flips 5.
That matters more for MTP exactness, so verify rows reproduce the
`[B,1]` greedy path, than for speed.

**Integration path: an mlx-swift fork patch**, not in-app `metalKernel`.

- In-app costs 0.35-1.7 ms of host graph build per forward. That is the
  whole gain.
- It needs module swapping that the paged and CB bridges would also have to
  honor.

Concretely:

1. In the vendored mlx, add an `affine_gather_qmv_grouped` kernel. It is the
   inline-bucket gather with the `vb` inner loop.
2. Add a dispatch rule in `GatherQMM::eval_gpu`: transpose, M == 1,
   unsorted, B·topk ≤ 64.
3. Add a fused `gather_qmm_swiglu` primitive, so SwitchGLU gate/up/SiLU is
   one launch. This needs an mlx-swift-lm fork change in
   `SwitchGLU.callAsFunction`.
4. Keep the batch-invariant `vb` path behind a flag for exact-verify mode
   only. Its M ≥ 3 cost (and the MMA kernel's M ≤ 4 cost) makes it a
   correctness feature, not a speed one.

The next lab step is the fused router plus fused routed block, measured
against this split. Then re-measure on M5 (NAX), where MLX's own small-M
paths differ.

## Windows (bench.sh, live :8080 paused and auto-resumed)

| # | LIVE_PAUSED | LIVE_RESUMED | buyer-runner stop / start | Content |
|---|---|---|---|---|
| 1 | 14:16:45 | 14:22:23 | 14:16:45 / 14:23:20 (active) | overlap, greal, split, kbench, gbench sweep, kreal, e2e, flips |
| 2 | 14:32:16 | 14:36:05 | 14:32:16 / 14:36:51 (active) | router split, text split, inline greal/gbench, e2e, MoE-only flips |
| 3 | 15:11:17 | 15:14:57 | 15:11:17 / 15:15:52 (active) | clean e2e (2 reps), width flips |

All times are UTC. Every window was gated on no `bench.sh`/`llama-server`,
no listener on 19101-19131, and ≥ 10 min since the other agent's last
`LIVE_RESUMED`. After each window, `macprovider-cli status` reported
`Provider is ready`. No lab build connected to a coordinator.

**Incident during window 2.** Another agent's
`mtp-r015-a3b-deferred/window.sh` went through `bench.sh` and paused live at
14:34:19, while window 2 was still running.

- My last four runs (14:34:18-14:34:58) overlapped it. They are superseded by
  window 3 and are not used in the tables.
- My `bench.sh` trap resumed live at 14:36:05, inside their window, and my
  procedure started buyer-runner at 14:36:51.
- I stopped buyer-runner again at 14:37:33 to restore their isolation.
- Their window ended with `LIVE_RESUMED` 15:00:40, and buyer-runner was
  still inactive, so I started it at 15:06:07.

Build (Studio, metallib copied from the `lab/qmv-smallm` build):

```bash
swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS
```
