# SPEC-048 native MTP: why packed target verify costs ~2x an ordinary step (#1770)

Lab branch `lab/mtp-verify-profile` (local only). Measured 2026-10-01 on the Mac
Studio M3 Ultra 256 GB, live :8080 paused through
`/Users/a1/lab-cb-sampling/bench.sh`, isolated in-process runs only.
Depth 1, greedy, 384-token prompts, 256 output tokens, fork `c4bc346`.

Raw results on the Studio:

- Window 1 (baseline, commit `d0ec6da7`): `/Users/a1/mtp-verify-profile-20261001T035641Z/`
  (`micro-*.log`, `micro-compiled-*.log`, `bench-*-depth{1,0}.jsonl`, `sample-depth0-b.txt`)
- Window 2 (fix, commit `552ed20a` + `fork-validate-offsets-no-astype.diff`):
  `/Users/a1/mtp-verify-profile-20261001T042729Z/`

## Answer

The 2x is two separate costs, roughly half each at 2 slots:

1. **Path overhead (fixable now, ~7.5 ms/round at 2 slots, ~10 ms at 8).**
   `validateMTPPackedCacheOffsets` (fork, `MTPPackedTargetVerification.swift`)
   reads each cache's int32 `batchOffset` with `asArray(Int.self)`. The dtype
   mismatch schedules an `astype` kernel and a blocking GPU wait per cache layer:
   40 round trips per verify on A3B, 64 on 27B, plus one more in
   `extractMTPPackedContinuationStates`. `sample` attributes ~78% of verify
   graph-build CPU time to that line (1302 of ~1750 samples). Per-row
   `topTokenIDs` adds 2 more blocking round trips per row.
2. **Model cost (not a path bug).** On this hardware a `[B,2]` forward costs
   about the same as a `[2B,1]` forward on both models. Neither model is
   bandwidth-bound at these sizes: below MLX's qmv->qmm switch, quantized matvec
   (and A3B's per-(token,expert) gather_qmv) cost grows with the token count.
   So depth-1 verify is 1.27-1.47x an ordinary step on A3B and 1.63-1.76x on
   27B, even with zero path overhead.

Hypotheses ranked:

| Hypothesis | Verdict | Evidence |
|---|---|---|
| H3 host syncs | **Main path cost** | 41 `astype`+wait round trips per verify (offset validation) + 2/row top-token transfers; fixed in window 2: verify 28.7 -> 21.2 ms (2 slots) |
| H5 token-count-scaled kernels | **Main model cost** | micro `[B,2]` ≈ `[2B,1]` on both models (table C3) |
| H2 recurrent checkpoint | Small | emitckpt vs plain `[B,2]`: A3B +1.4 ms (2 slots), +1.9 ms (8); 27B +3.1/+2.6 ms |
| H1 compiled ordinary graph | Refuted | `compiled_ordinary_steps=0`: serve path builds the backend with `compiledDecode: false`, and hybrid layouts cannot compile. Compile would save only ~1.7 ms (micro) |
| H4 paged gather/scatter | Negligible | prepare + transactions + state store = 0.5 ms (2 slots), 1.6 ms (8) |

## C3: raw target forward, dense caches, no bridge (total p50 ms = graph + GPU eval + argmax)

Qwen3.6-35B-A3B 4-bit:

| B | `[B,1]` plain | `[B,2]` plain | `[B,2]` emit+ckpt | ratio plain | `[B,1]` compiled | `[B,2]` compiled |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 11.31 | 13.27 | 14.44 | 1.17 | - | - |
| 2 | 13.39 | 17.01 | 18.40 | 1.27 | 11.65 | 15.26 |
| 4 | 17.31 | 23.12 | 24.61 | 1.34 | 15.40 | 21.41 |
| 8 | 23.51 | 32.66 | 34.59 | 1.39 | 21.62 | 30.89 |
| 16 | 33.88 | 54.84 | 58.72 | 1.62 | 32.27 | 51.21 |

Qwen3.6-27B 4-bit (dense, hybrid GDN):

| B | `[B,1]` plain | `[B,2]` plain | `[B,2]` emit+ckpt | ratio plain | `[B,1]` compiled | `[B,2]` compiled |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 29.00 | 34.69 | 37.40 | 1.20 | - | - |
| 2 | 34.58 | 58.04 | 61.14 | 1.68 | 32.26 | 55.33 |
| 4 | 58.33 | 101.22 | 103.85 | 1.74 | 55.50 | 97.68 |
| 8 | 102.05 | 166.11 | 168.69 | 1.63 | 99.28 | 161.38 |
| 16 | 168.40 | 168.40 | 174.74 | 1.00 | 157.28 | 157.61 |

Token count, not shape, sets the cost: A3B `[2,2]` 17.01 vs `[4,1]` 17.31;
`[8,2]` 32.66 vs `[16,1]` 33.88. 27B `[2,2]` 58.04 vs `[4,1]` 58.33. 27B is
flat from 16 to 32 tokens: past the qmm switch, extra tokens are almost free.
Graph build is ~1.5 ms plain, ~2.1-2.9 ms with emit+checkpoint, ~0.5 ms compiled.
Compiled replay does not advance Swift cache offsets, so treat those timings as approximate.

## Scheduler sub-phases (ms per round; ordinary = per lockstep step)

Each boundary calls `Stream().synchronize()`, so CPU graph build and GPU
execution are charged separately. Profiling adds about one sync per round.

A3B, baseline (window 1) and with the fix (window 2):

| Sub-phase | ord s2 | native d1 s2 | native d0 s2 | **fixed** d1 s2 | ord s8 | native d1 s8 | native d0 s8 | **fixed** d1 s8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| a prepare caches/inputs | 0.02 | 0.21 | 0.23 | 0.21 | 0.06 | 0.73 | 0.75 | 0.73 |
| b graph build (CPU) | 1.92 | **9.81** | **9.60** | 2.65 | 2.80 | **10.94** | **10.24** | 3.95 |
| c forward GPU eval | 12.26 | 17.19 | 13.08 | 17.65 | 22.07 | 35.98 | 25.94 | 36.53 |
| d checkpoint txns | - | 0.29 | 0.28 | 0.28 | - | 0.87 | 0.84 | 0.87 |
| e top tokens / sample | 0.30 | 1.07 | 0.60 | 0.33 | 0.32 | 3.92 | 2.22 | 0.38 |
| e2 parity trace (lab) | - | 0.04 | 0.04 | 0.05 | - | 0.17 | 0.17 | 0.16 |
| f state store/writeback | 0.01 | 0.02 | 0.02 | 0.02 | 0.04 | 0.02 | 0.02 | 0.02 |
| **target forward total** | **14.52** | **28.68** | **23.90** | **21.23** | **25.31** | **52.69** | **40.25** | **42.71** |
| rows / tokens per round | 1.89 / 1 each | 1.98 / 3.82 | 1.99 / 2.00 | 1.99 / 3.84 | 6.61 / 1 each | 7.54 / 14.12 | 7.88 / 7.91 | 7.57 / 14.12 |
| target ms per committed token | 7.68 | 7.51 | 11.95 | **5.53** | 3.83 | 3.73 | 5.09 | **3.02** |
| explicit host syncs / round | 2 | 6.9 (+41 hidden) | 5.0 (+41) | 4.0 | 2 | 23.5 (+41) | 16.8 (+41) | 9.6 |
| aggregate tok/s (profiled) | 120.4 | 101.4 | 65.4 | **126.1** | 233.3 | 164.6 | 123.2 | **185.8** |

Depth 0 (C2) runs the packed path with one position per row, the same token
count as an ordinary step. It still costs 23.9 vs 14.5 ms at 2 slots, which
isolates ~9.4 ms of path overhead. Almost all of it is graph build (9.6 ms
against 1.9 ms) and top-token transfer. GPU eval is within 0.8 ms of ordinary.

Qwen3.6-27B:

| Sub-phase | ord s2 | native d1 s2 | **fixed** d1 s2 | ord s8 | native d1 s8 | **fixed** d1 s8 |
|---|---:|---:|---:|---:|---:|---:|
| b graph build (CPU) | 2.40 | 15.48 | 3.66 | 3.93 | 17.46 | 5.48 |
| c forward GPU eval | 33.80 | 60.69 | 61.20 | 98.35 | 173.21 | 173.05 |
| e top tokens / sample | 0.32 | 1.12 | 0.36 | 0.35 | 4.23 | 0.43 |
| **target forward total** | **36.57** | **78.22** | **66.15** | **102.83** | **197.87** | **181.98** |
| target ms per committed token | 19.35 | 20.80 | 17.59 | 15.56 | 13.52 | 12.48 |
| aggregate tok/s (profiled) | 42.0 | 34.9 | 39.3 | 52.5 | 47.3 | 49.7 |

Parity flags and acceptance are unchanged by the fix. A3B s2 accepted 239/268 and
251/256 both before and after. The `parity_hard_mismatch` blocks are the same
set as the baseline and as depth 0, which is the known qmv/qmm drift (R005 proposal).

## Fix and expected verify cost

1. Fork: read offsets as `Int32` (`fork-validate-offsets-no-astype.diff`, two
   lines). Better still, validate the host `[Int]` row maps and never touch an
   MLXArray. Removes 41 (A3B) or 65 (27B) GPU round trips per verify.
2. App: `packedTopTokenIDs` uses one argmax and one host transfer per round
   (`PagedKVRuntimeBridge.swift`).

Measured after both changes: A3B verify **21.2 ms** at 2 slots (was 28.7) and
**42.7 ms** at 8 slots (was 52.7). That is **5.5 / 3.0 ms per committed token**,
against ordinary 7.7 / 3.8. Native A3B at 2 slots now beats ordinary
(126 vs 120 tok/s profiled).

What remains is model cost (GPU 17.7 ms against 12.3 ms ordinary at 2 slots) plus
~2.7 ms graph build. Further headroom:

- Drop the emit+checkpoint split when no row has a proposal. Saves 1-2 ms GPU (H2).
- Compile the packed `[B,2]` verify graph. Saves ~1-1.5 ms CPU, but needs the
  offset-advance bug fixed first.
- The remaining ~1.4x `[B,2]`/`[B,1]` GPU ratio is MLX kernel behavior
  (qmv/gather_qmv cost scaling with token count below the qmm switch). Only
  kernel work can recover it: a weight-reusing small-M quantized matmul, or
  tuning `get_qmv_batch_limit`.
- Separately, `acceptance_commit` costs 3.2 / 12.2 ms per round on A3B, which is
  now the next-largest native overhead. Recurrent `commit` evals once per row
  per layer.

## Commands

```bash
# build (Studio)
cd /Users/a1/macprovider-mtp-verify-profile/phase3-binary
swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS
cp -c /Users/a1/macprovider-mtp-r015/phase3-binary/.build/arm64-apple-macosx/release/mlx.metallib .build/arm64-apple-macosx/release/
# window 1 (micro + bench + compiled)
PROVIDER_COMMIT=d0ec6da733bccad3e01562f01ad2254cc8f943a3 \
  nohup /Users/a1/lab-cb-sampling/bench.sh /Users/a1/mtp-verify-profile-window.sh > /Users/a1/mtp-verify-profile-window.log 2>&1 &
# window 2 (fix; fork diff applied to .build/checkouts/mlx-swift-lm)
PHASES=bench BENCH_SPECS="q36-a3b:qwen/qwen3.6-35b-a3b:depth1 q36-27b:qwen/qwen3.6-27b:depth1" \
  PROVIDER_COMMIT=552ed20ab58aead0948eb45d8584abb8bb7fd934 \
  nohup /Users/a1/lab-cb-sampling/bench.sh /Users/a1/mtp-verify-profile-window.sh > /Users/a1/mtp-verify-profile-window2.log 2>&1 &
# micro-bench shape
macprovider-cli native-mtp-forward-microbench --model-dir ~/.cache/macprovider-mtp-e2e/q36-a3b/target \
  --batches 1,2,4,8,16 --widths 1,2 --variants plain,emitckpt --iters 30 --warmup 5
# bench env: MACPROVIDER_NATIVE_MTP_E2E=1 MACPROVIDER_NATIVE_MTP_PROFILE=1 [MACPROVIDER_NATIVE_MTP_LAB_FORCE_DEPTH0=1]
```

Window 1 03:56:41-04:23:35Z (LIVE_RESUMED). Window 2 04:27:29-04:43:17Z
(LIVE_RESUMED). Pearl `malibu-buyer-runner-studio` was stopped before each
window and restarted after; it reported `active` at the end. A first attempt at
03:53Z failed in 1.5 min with no metallib next to the binary and measured nothing
(`/Users/a1/mtp-verify-profile-window-attempt1-nometallib.log`). Live resumed
03:56:09Z.
