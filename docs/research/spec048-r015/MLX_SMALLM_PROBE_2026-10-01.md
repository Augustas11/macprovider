# SPEC-048 native MTP: MLX small-M quantized matmul, old vs new MLX pin (#1770)

Lab branch `lab/mtp-mlx-0323` (local only). Measured 2026-10-01 on the Mac Studio
M3 Ultra 256 GB (60-core GPU, Metal arch gen 15 `d`). Live :8080 was paused
through `/Users/a1/lab-cb-sampling/bench.sh`. All runs were isolated and
in-process, with no coordinator.

| Pin | mlx-swift | vendored mlx core | mlx-swift-lm fork |
|---|---|---|---|
| old | 0.31.4 `dc43e62d` | v0.31.1 `ce45c525` | `c4bc3461` |
| new | 0.32.3 `19601207` | v0.32.2 `1f8e74e3` | `3cb88f19` (branch `lab/mtp-mlx-0323` = `c4bc3461` + mlx-swift floor 0.32.3, no other change) |

mlx-swift 0.32.3 vendors mlx **v0.32.2**, not v0.32.3. Core v0.32.3 only adds
#4572, which changes the gather_qmm_rhs prefill path. Decode never reaches that
path on A3B because it needs `B/E >= 4` with E=256. The fork's MTP backport and
the MacProvider sources build unchanged against 0.32.3 on Swift 6.3.3. Porting
onto upstream mlx-swift-lm 3.32.3 was not needed for this question. That port is
159 commits and includes upstream's own Qwen3.5 MTP.

Raw results on the Studio are in `/Users/a1/mlx0323-window-20261001T051517Z/`
(`micro-*`, `greedy-*`, `qmm-*`).

## Answer

**Partly a version problem.** mlx v0.32.2 adds `qmv_wide` (#3764), which
reuses each dequantized weight group across up to 5 input rows. On M3 Ultra
it cuts dense small-M matmul cost by up to 2.7x (lm_head M=8) and cuts 27B
`[B,1]` forward time by 5-20%. It does **not** make small-M bandwidth-flat.
`qmv_wide` still costs 1.1x / 1.75x / 3.5x M=1 at M=2/4/8. The qmm path that
takes over at M>=12 runs at about 145 GB/s, versus about 700 GB/s for M=1 qmv.
The `[B,2]/[B,1]` ratio barely moves: 27B goes from 1.67 to 1.44 at B=2 and
from 1.62 to 1.72 at B=8. A3B is unchanged at B<=8. Getting to roughly 1.1
needs kernel work.

## C3 micro-bench (total ms p50, dense caches, plain, 20 iters)

Qwen3.6-27B 4-bit:

| B | old `[B,1]` | new `[B,1]` | old `[B,2]` | new `[B,2]` | old `[B,3]` | new `[B,3]` | old 2/1 | new 2/1 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 29.11 | 28.83 | 34.73 | 33.07 | 46.45 | 39.99 | 1.19 | 1.15 |
| 2 | 34.81 | 33.04 | 58.13 | 47.51 | 93.09 | 65.73 | 1.67 | 1.44 |
| 4 | 58.52 | 48.15 | 101.24 | 81.07 | 174.35 | 142.16 | 1.73 | 1.68 |
| 8 | 102.21 | 82.12 | 166.08 | 141.25 | 186.15 | 147.39 | 1.62 | 1.72 |
| 16 | 168.72 | 143.84 | 168.18 | 149.95 | 290.85 | 273.16 | 1.00 | 1.04 |

Qwen3.6-35B-A3B 4-bit:

| B | old `[B,1]` | new `[B,1]` | old `[B,2]` | new `[B,2]` | old `[B,3]` | new `[B,3]` | old 2/1 | new 2/1 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 11.34 | 11.25 | 13.31 | 13.08 | 14.91 | 14.60 | 1.17 | 1.16 |
| 2 | 13.43 | 13.14 | 17.11 | 16.45 | 20.59 | 19.31 | 1.27 | 1.25 |
| 4 | 17.31 | 16.65 | 23.25 | 22.12 | 28.67 | 27.78 | 1.34 | 1.33 |
| 8 | 23.58 | 22.43 | 32.74 | 31.63 | 44.26 | 38.27 | 1.39 | 1.41 |
| 16 | 33.97 | 32.90 | 54.97 | 44.84 | 77.31 | 63.67 | 1.62 | 1.36 |

The old-pin numbers reproduce the earlier verify-profile C3 run within 1%.

## Isolated 4-bit g64 bf16 quantized matmul (`mlx-smallm-probe --mode qmm`)

Each matmul cycles through at least 1 GiB of distinct weight copies, so
weights stream from DRAM. Values are µs per matmul (p50), with effective
weight GB/s in parentheses.

| N x K | pin | M=1 | M=2 | M=4 | M=8 | M=11 | M=12 | M=16 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 17408x5120 (27B gate/up) | old | 75 (670) | 98 | 170 | 321 | 443 | 359 | 358 (140) |
| | new | 76 (663) | 84 | 133 | 266 | 376 | 346 | 349 (143) |
| 5120x17408 (27B down) | old | 79 | 108 | 180 | 324 | 436 | 395 | 396 |
| | new | 80 | 121 | 173 | 312 | 438 | 396 | 398 |
| 248320x5120 (27B lm_head) | old | 991 (721) | 1889 | 3678 | 7149 | 7518 | 4826 | 4835 (148) |
| | new | 979 (730) | 1175 | 2068 | 3989 | 5535 | 4699 | 4699 (152) |
| 248320x2048 (A3B lm_head) | old | 412 | 703 | 1281 | 2476 | 2748 | 1975 | 1978 |
| | new | 411 | 441 | 725 | 1427 | 2040 | 1920 | 1919 |
| 8192x2048 | old | 15 | 18 | 33 | 62 | 86 | 67 | 68 |
| | new | 14 | 15 | 23 | 44 | 65 | 72 | 75 |

Full M=1..16 curves are in `qmm-{old,new}.log`.

## Kernel path, from code

The paths below are under `mlx/backend/metal/` in the vendored mlx. The model
forward of `[B,w]` passes contiguous x, so the matmul sees `M = B*w`
(`quantized.cpp` `QuantizedMatmul::eval_gpu`).

- **Old, v0.31.1.** `quantized.cpp:1315-1318` uses qmm when
  `M >= get_qmv_batch_limit(K,N)`. Otherwise it uses `dispatch_qmv` → `qmv`
  (`qmv_fast` when `N%8==0 && K%512==0`). M3 Ultra is gen 15 `d`, so the
  `else / case 'd'` branch at `quantized.cpp:84-125` returns 12 when either
  dimension is above 4096, 18 when both are at most 4096, and 32 when both are
  at most 2048. The `qmv` grid is `grid_dims(M, N/8, B)` (`quantized.cpp:254`).
  Each threadgroup handles **one input row** against 8 output rows
  (`kernels/quantized.h:780-786`, `x += tid.x * in_vec_size`). Every row
  therefore re-streams the whole weight matrix, and the cache does not absorb
  it: cost is about `M x t(1)` up to M=11. The step down at M=12 is the
  switch to `qmm_t`. On 2048x2048 there is no step until 32, which matches
  the table.
- **New, v0.32.2.** `dispatch_qmv` (`quantized.cpp:1762`) routes
  `M >= 2 && use_qmv_wide` to `qmv_wide`. `use_qmv_wide` (`:538`) is true for
  affine on gen >= 15, so M3 Ultra qualifies. `qmv_wide` (`:561`) uses
  `n_tiles = ceil(M/5)` with up to 5 vectors per threadgroup, so weights are
  re-read `ceil(M/5)` times instead of M times. The per-vector FMA loop
  (`kernels/quantized.h:989+`) becomes ALU-bound past M≈3, which is why the
  gain fades. For 'd' parts, `get_qmv_batch_limit` (`:85-145`) is unchanged
  (#3791 only raises the limit on non-'d' gen 15/17). M>=12 now goes to
  `qmm_splitk` (`:1807-1813`), which is no faster than `qmm` here.
- **A3B experts.** `GatherQMM` (old `:1376-1426`, new `:1898-1940`) sends
  decode to `gather_qmv`, with grid `(M=1, N/8, tokens*top_k)` (old `:885`,
  new `:1332`). That is one weight pass per (token, expert) pair, and the
  kernel is unchanged in v0.32.2. `gather_qmm_rhs` needs `B/E >= 4`, which
  never holds with E=256. Most of A3B's B-scaling is extra distinct experts,
  which is real bandwidth. The rest is low-occupancy `gather_qmv` on 512x2048
  experts.

**Kernel identity verification.** A metallib-stripping probe
(`--mode kernel-name`) could not name the kernels. mlx-swift builds MLX in JIT
mode: mlx-swift `Package.swift:293` excludes `nojit_kernels.cpp`. Quantized
kernels are compiled at runtime from the vendored sources, so `mlx.metallib`
does not matter for them and every probe returned without error. The timing
signatures confirm the dispatch above:

- Old shows linear growth to M=11, then the M=12 step, on every shape with a
  dimension above 4096. 2048x2048 shows no step.
- New shows the ceil(M/5) tile steps on lm_head: 5→6 is nearly flat, and 8→9
  jumps by 41%.

## Greedy parity, ordinary decode, 64 tokens, dense cache

Prompts are raw text without a chat template, truncated to the shortest
prompt (15 tokens).

| Model | rows=1 | rows=4, first divergent step per row |
|---|---|---|
| A3B | identical (64/64) | 4, 52, -, - |
| 27B | identical (64/64) | -, 52, -, 5 |

M=1 decode keeps `qmv`, so single-row output is bit-identical. With 4 rows
(M=4), the new pin runs `qmv_wide`, which reduces in a different order. That
causes greedy near-tie flips. This is the same drift class as the existing
qmv/qmm R005 drift, and it is not a correctness bug. A serve-path bump would
need fresh parity fixtures. The B=1 vs B=4 comparison within one pin is not
meaningful: the B=1 run uses the full prompt and the B=4 run uses the
truncated one.

## Attainable ratio with kernel work

Fitting `T(M) = 289 units × t_matmul(M) + other(M)` to 27B gives
other ≈ 6-9 ms. One unit is 17408x5120; the model has about 289 units
including lm_head. The fit matches both pins within about 10%.

A bandwidth-bound small-M kernel (1-2 weight passes for M<=8, then
compute-bound at about 2·M·N·K / ~28 TFLOPS) would bring a unit to
≈75-85 µs for M<=8 and ≈110-130 µs at M=16. That gives these targets:

- 27B `[B,2]/[B,1]`: ≈1.05-1.15 for B<=4, ≈1.3-1.4 at B=8.
  Today it is 1.44-1.72.
- A3B: ≈1.15-1.2, since distinct experts dominate.
  Today it is 1.25-1.41.

Candidates:

1. A simdgroup-matrix small-M affine kernel for M=2..16 that dequantizes each
   weight tile once.
2. Lowering the M3-Ultra 'd' qmm threshold, after first fixing qmm/qmm_splitk
   efficiency at M=12-16, which currently runs at about 145 GB/s.
3. An expert-grouped gather kernel for decode.

## Commands

```bash
# local (Studio has CLT only, so there is no Metal toolchain there)
#   metallib for new pin = scripts/build-mlx-metallib.sh + kernels dot, searchsorted,
#   steel_gemm_segmented_nax (new in v0.32.2), built against mlx 1f8e74e3
# Studio builds
cd /Users/a1/macprovider-mtp-mlx0323-old/phase3-binary   # = ade858ce (old pin)
swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS
cp -c /Users/a1/macprovider-mtp-r015/phase3-binary/.build/arm64-apple-macosx/release/mlx.metallib .build/arm64-apple-macosx/release/
cd /Users/a1/macprovider-mtp-mlx0323/phase3-binary        # = new pin
swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS
# window (script: /Users/a1/mlx0323-lab/window.sh)
ssh pearl 'sudo systemctl stop malibu-buyer-runner-studio.service'
nohup /Users/a1/lab-cb-sampling/bench.sh /Users/a1/mlx0323-lab/window.sh > /Users/a1/mlx0323-lab/window.log 2>&1 &
ssh pearl 'sudo systemctl start malibu-buyer-runner-studio.service'
# probes
macprovider-cli native-mtp-forward-microbench --model-dir $FIX/$d/target --batches 1,2,4,8,16 --widths 1,2,3 --variants plain --iters 20 --warmup 3
macprovider-cli mlx-smallm-probe --mode greedy --model-dir $FIX/$d/target --batches 1,4 --decode-tokens 64
macprovider-cli mlx-smallm-probe --mode qmm --max-m 16 --iters 10 --warmup 3
```

Window: LIVE_PAUSED 05:15:16Z, WINDOW_DONE 05:22:19Z, LIVE_RESUMED 05:23:24Z.
Pearl `malibu-buyer-runner-studio` was stopped before the window and started
after it, and reported `active`. Live status afterwards: `Provider is ready`.
