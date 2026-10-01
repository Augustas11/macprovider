# SPEC-048 native MTP: small-M 4-bit quantized matmul kernel prototype (#1770)

Lab branch `lab/qmv-smallm` (local only, based on `lab/mtp-mlx-0323`, mlx-swift
0.32.3 / mlx v0.32.2). Measured 2026-10-01 on the Mac Studio M3 Ultra 256 GB
(60-core GPU, gen 15 `d`). Follows `MLX_SMALLM_PROBE_2026-10-01.md`.

Code:

- `phase3-binary/Sources/macprovider-cli/SmallMQMVKernel.swift`: the
  `MLXFast.metalKernel` kernels and `SmallMQuantizedLinear` (lab routing).
- `phase3-binary/Sources/macprovider-cli/MLXSmallMProbeKernelModes.swift`:
  `mlx-smallm-probe --mode kcheck|kbench|kreal`.
- `native-mtp-forward-microbench --smallm-qmv off|auto|<config>`, and
  `mlx-smallm-probe --mode greedy --smallm-qmv ...`.

Raw logs are on the Studio in `/Users/a1/qmv-smallm-window-<UTC>/` (six
windows). Scripts are in `/Users/a1/qmv-smallm-lab/`.

## Answer

The kernel reads each weight tile once for all M ≤ 8 rows, and its cost is
flat from M=1 to M=8. On the big 27B and lm_head shapes it is **1.9-2.6x
faster than `qmv_wide` at M=8** and 1.4-1.6x faster than `qmm` at M=12-16.
That clears the 1.5x go/no-go bar at M=8. It does **not** reach
"M=1 cost at M≤8". On the M3 Ultra the flat floor is about **1.75x the M=1
`qmv` time** (131 µs vs 75 µs on 17408x5120). The kernel therefore loses at
M ≤ 3, breaks even at M=4, and wins from M=5. The likely limit is the
8x8x8 `simdgroup_multiply_accumulate` rate: time does not change with M, and
cutting x loads or dequant ALU work did not move it.

End to end on 27B with `--smallm-qmv auto` (M ≥ 5 routed), `[B,2]/[B,1]` at
B=4 drops from 1.69 to 1.27. `[B,1]` at B=8 drops from 81.9 to 62.5 ms.
A3B does not improve: its dense shapes are small, and routed-expert
`gather_qmv` dominates.

## Kernel design

`y[M,N] = x[M,K] · dequant(Wq[N,K/8] u32, scales/biases[N,K/64])^T`, 4-bit
affine, group 64, bf16/fp16 activations, float accumulation. M, K, N, tiling,
and fragment type are template constants, so one pipeline is built per shape.

**`mma`** (the variant kept) computes `y^T = W · x^T` with 8x8
`simdgroup_matrix`:

- A is an 8-row × 8-k weight tile; B is an 8-k × 8-m tile of x^T. One MMA
  serves all M ≤ 8 rows. M=9-16 uses two B tiles.
- Inside each 128-k chunk the k index is permuted (logical step s, column kk →
  physical k = kk·16 + s). Each A lane then dequantizes from one 16-byte load
  per row, and each B lane reads 16 contiguous activations per row with two
  16-byte loads. Columns m ≥ M are zero and are never stored.
- NT 8-row tiles per threadgroup; KS simdgroups split K and reduce through
  threadgroup memory.
- `-act` builds the A/B fragments in the activation dtype (bf16 × bf16 → fp32
  MMA). The default builds fp32 fragments.

Variants tried and dropped:

- **`rb`**: a register-blocked scalar kernel with qmv_fast tiling. It is
  bound by per-row x reloads through L1, at 1.8-3.5x slower than MLX.
- **`mmas`**: an MMA on raw 4-bit integers, with scale and bias applied once
  per group. It was 5-15% slower.
- **The first `mma` k-permutation**: its 2x x-load redundancy did not change
  the floor.

## Correctness

Synthetic weights and real 27B/A3B weights were tested. The real-weight set
was every 4-bit linear in layers 3 (full attention) and 4 (linear attention),
plus lm_head, with real final hidden states as x for K = hidden.

- **Error vs the fp32 dequantized reference.** Max relative error is
  2.7-4.7e-3, which is bf16 output rounding. The max abs error equals MLX
  batched's within 1.00-1.06x. The one exception is 1.39x for fp32-fragment
  27B at M=16, where the comparison is against `qmm`. MLX `qmv` at M=1 is
  less accurate: its abs error is 1.4-2.5x larger than ours.
- **Bit identity.** Neither variant is bit-identical to MLX `qmv` M=1 rows:
  83-94% of bf16 outputs differ by an ulp, and MLX `qmv_wide` vs qmv rows also
  differs on 80-90% of outputs. With fp32 fragments the kernel is effectively
  bit-identical to `qmv_wide` at M=2-8: 0.0-1.0% of elements differ. With
  `-act` fragments about 40% of elements differ, at the same error magnitude.
- **lm_head argmax over 136 real hidden rows**, chunked into M=2/4/8/16:
  1 flip vs per-row `qmv`. MLX batched (`qmv_wide`/`qmm`) has the same
  1 flip. fp32-exact has 2-4 flips vs `qmv`. Both models, all M.
- **Greedy, 64 tokens, `auto` vs off.** rows=4 is identical (not routed).
  rows=8/16 diverge only at the near-tie positions that already flip between
  MLX paths: 27B row 0 at step 1, A3B rows 0/3 at steps 1-36. This is the
  same drift class as R005, so a serve integration needs new parity fixtures.

## µs per matmul, MLX `quantizedMM` / `mma-nt4-ks2-act` (speedup)

Independent matmuls (window 4). Weights stream from DRAM (≥1 GiB of distinct
copies).

| N x K | M=1 | M=2 | M=4 | M=5 | M=8 | M=12 | M=16 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 17408x5120 | 75 / 131 (0.58x) | 84 / 134 (0.63x) | 128 / 134 (0.96x) | 175 / 134 (1.31x) | 264 / 132 (1.99x) | 346 / 227 (1.53x) | 347 / 241 (1.44x) |
| 5120x17408 | 80 / 141 (0.57x) | 101 / 143 (0.71x) | 167 / 143 (1.17x) | 228 / 143 (1.60x) | 331 / 143 (2.32x) | 393 / 257 (1.53x) | 393 / 273 (1.44x) |
| 10240x5120 | 46 / 77 | 52 / 79 | 82 / 79 (1.04x) | 114 / 79 (1.44x) | 175 / 78 (2.25x) | 204 / 136 (1.50x) | 204 / 144 (1.42x) |
| 12288x5120 | 53 / 92 | 61 / 94 | 98 / 95 (1.04x) | 136 / 95 (1.44x) | 205 / 93 (2.20x) | 245 / 162 (1.51x) | 246 / 173 (1.42x) |
| 6144x5120 | 28 / 47 | 32 / 49 | 49 / 49 (1.02x) | 68 / 49 (1.40x) | 115 / 48 (2.39x) | 132 / 81 (1.62x) | 132 / 87 (1.53x) |
| 5120x6144 | 28 / 49 | 33 / 50 | 51 / 50 (1.03x) | 68 / 49 (1.38x) | 123 / 49 (2.51x) | 135 / 83 (1.64x) | 135 / 87 (1.55x) |
| 1024x5120 | 6 / 9 | 8 / 9 | 11 / 9 | 14 / 10 | 19 / 10 (1.87x) | 27 / 14 | 28 / 17 |
| 248320x5120 | 991 / 1707 (0.58x) | 1508 / 1769 | 2791 / 1752 (1.59x) | 3968 / 1755 (2.26x) | 4508 / 1709 (2.64x) | 4697 / 3091 (1.52x) | 4701 / 3305 (1.42x) |
| 8192x2048 | 15 / 25 | 16 / 26 | 24 / 26 | 30 / 26 (1.17x) | 46 / 25 (1.85x) | 71 / 43 (1.64x) | 74 / 47 (1.56x) |
| 4096x2048 | 8 / 13 | 9 / 13 | 13 / 13 | 15 / 15 | 24 / 13 (1.89x) | 38 / 22 | 50 / 24 (2.11x) |
| 2048x4096 | 9 / 15 | 11 / 15 | 15 / 13 | 19 / 16 | 29 / 13 (2.20x) | 43 / 22 | 56 / 24 (2.37x) |
| 512x2048, 2048x512 | 3 / 3-4 | 3 / 3-4 | 3-5 / 3-4 | 3-5 / 3-4 | 6 / 3-4 | 6-7 / 4 | 7-8 / 4-5 |
| 248320x2048 | 422 / 726 (0.58x) | 464 / 756 | 798 / 757 (1.05x) | 1091 / 755 (1.44x) | 1498 / 741 (2.02x) | 1916 / 1286 (1.49x) | 1924 / 1412 (1.36x) |

Dependent chains (window 6, `kbench --serial`) model a forward pass, where
kernels cannot overlap. Each number includes about 15-20 µs of chain glue.
Here the kernel's floor is a larger share: `mma-nt2-ks4-act` M=8 vs MLX:

| Shape | MLX µs | kernel µs |
|---|---:|---:|
| 17408x5120 | 262 | 181 |
| 5120x17408 | 272 | 200 |
| 6144x5120 | 113 | 81 |
| 8192x2048 | 69 | 53 |
| 1024x5120 | 37 | 38 |
| 2048x4096 | 43 | 39 |
| lm_head 27B | 3149 | 1977 |

At M=1 the kernel costs 1.6-2.3x MLX.

## End-to-end forward (C3 micro-bench, total ms p50, dense caches, plain, 20 iters, window 6)

`auto` routes M ≥ 5 through `mma-act`: NT=2/KS=4 for M ≤ 8, and NT=4/KS=2 for
M = 9-16. Tensors with N < 4096 use KS=8, and N < 512 stays on MLX.
M = B·w; M ≤ 4 and M > 16 are unchanged.

| Model | B | off `[B,1]` | auto `[B,1]` | off `[B,2]` | auto `[B,2]` | off `[B,3]` | auto `[B,3]` | off 2/1 | auto 2/1 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 27B | 1 | 28.78 | 28.88 | 32.61 | 32.96 | 39.93 | 40.00 | 1.13 | 1.14 |
| 27B | 2 | 32.77 | 33.10 | 47.35* | 53.86* | 65.60 | **59.72** | 1.44 | 1.63* |
| 27B | 4 | 47.99 | 48.17 | 80.90 | **61.27** | 141.50 | **115.83** | 1.69 | **1.27** |
| 27B | 8 | 81.92 | **62.50** | 140.72 | **115.01** | 146.96 | 147.70 | 1.72 | 1.84 |
| A3B | 2 | 13.23 | 13.19 | 16.44 | 16.35 | 19.08 | 19.98 | 1.24 | 1.24 |
| A3B | 4 | 16.66 | 16.64 | 21.91 | 21.86 | 27.16 | 30.93 | 1.32 | 1.31 |
| A3B | 8 | 22.39 | 22.27 | 30.99 | 32.33 | 37.00 | 36.93 | 1.38 | 1.45 |

\* 27B `[2,2]` is M=4, which is not routed. 47-54 ms is run-to-run
bimodality of the unrouted path: off measured 54.06 in window 4.

The C3 total includes about 2 ms more graph build at 27B. Each
`MLXFast.metalKernel` call regenerates and hashes its source on the host
(about 4 µs × 497 layers).

The gain is smaller than isolated timing predicts. In a forward pass the
matmuls are serialized, and this kernel's per-launch floor is relatively
higher (see the chain table). What matters for MTP is the 27B verify row
`[B,2]`: at B=4 it becomes 1.27x `[B,1]`, against the probe doc's 1.05-1.15
target for B ≤ 4. At B=8 the `[B,1]` baseline itself drops 24%, so the ratio
hides an absolute gain: `[8,2]` goes from 140.7 to 115.0 ms.

## Verdict and integration path

Partly promising. The bar (≥1.5x over `qmv_wide` at M=4..8) is met at M=6-8
on 27B and lm_head shapes. It is not met at M=4, which is break-even. The
27B M=5-16 forward gain is 18-24%. A3B shows no gain. The MMA-rate floor
(~1.75x M=1) caps what any `simdgroup_matrix` design can reach on M3; the
non-matrix designs tried here were worse.

Recommended path is an **mlx-swift fork patch**: add an `affine_qmv_mma`
kernel to the vendored `quantized.h` and a dispatch rule in
`dispatch_qmv` (gen-15 `d`, M ≥ 5, N·K ≥ ~30M, else `qmv_wide`). Reasons:

- It removes the about 2 ms/forward host cost of `metalKernel`.
- It keeps the qmv/qmv_wide fallback inside one primitive.
- It lets the kernel be tuned per shape without app-side module swapping.

The in-app `metalKernel` route works as a lab flag only. It has a per-call
JIT/source-hash cost and replaces modules, which the paged/CB bridges would
also need to honor.

An upstream PR to ml-explore/mlx is worth filing after the fork carries it.
The kernel is device-generic Metal, and the M5 neural-accelerator path
(`*_nax`) already covers newer parts, so the PR should target gen ≤ 15.

Before any serve use, the following are open:

- A gather variant for A3B experts (not attempted).
- An M=4 floor below `qmv_wide`.
- Parity fixtures for the near-tie drift.

## Windows (bench.sh, live :8080 paused, auto-resumed)

| # | LIVE_PAUSED | LIVE_RESUMED | Content |
|---|---|---|---|
| 1 | 05:41:28 | 05:45:39 | kbench rb/mma v1, kreal |
| 2 | 05:52:32 | 05:58:28 | act fragments, micro, greedy |
| 3 | 06:02:10 | 06:09:05 | mmas, micro, greedy |
| 4 | 06:14:39 | 06:22:21 | mma v2 permutation, micro, greedy |
| 5 | 06:40:27 | 06:48:13 | chain probe v0, NT/KS micro, kreal v2 |
| 6 | 06:53:37 | 06:59:05 | chain kbench, auto micro, greedy |

Pearl `malibu-buyer-runner-studio` was stopped before each window and started
after it, and reported `active` each time. Another agent's
`mtp-r015-window.sh` windows ran between ours, and we never overlapped one.
After window 6, live status was `Provider is ready` and buyer-runner was
`active`.

## Commands

```bash
cd /Users/a1/macprovider-mtp-qmv-smallm/phase3-binary
swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS
B=.build/arm64-apple-macosx/release/macprovider-cli
$B mlx-smallm-probe --mode kcheck --shapes 64x512,48x5120 --ms 1,3,8,9,16 --configs mma-nt4-ks2-act,mma-nt2-ks2
$B mlx-smallm-probe --mode kbench [--serial] --shapes 17408x5120,... --ms 1,2,4,5,8,12,16 --configs mma-nt4-ks2-act
$B mlx-smallm-probe --mode kreal --model-dir $FIX/q36-27b/target --ms 1,2,4,8,16 --configs mma-nt4-ks2-act
$B native-mtp-forward-microbench --model-dir $FIX/q36-27b/target --batches 1,2,4,8 --widths 1,2,3 --variants plain --iters 20 --warmup 3 --smallm-qmv auto
$B mlx-smallm-probe --mode greedy --model-dir $FIX/q36-27b/target --batches 4,8,16 --smallm-qmv auto
```
