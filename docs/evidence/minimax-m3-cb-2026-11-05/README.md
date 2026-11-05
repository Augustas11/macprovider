# MiniMax M3.1-Flash paged cache + continuous batching: Studio validation (2026-11-05)

Related: #2189

## Setup

- Host: Mac Studio M3 Ultra 256 GB. Model `minimaxai/minimax-m3.1-flash`,
  artifact `mlx-community--MiniMax-M3.1-Flash-oQ3e-mtp` (60 block-sparse
  layers, 3-bit experts, block selection from 2,048 keys).
- Lab binaries are `swift build -c release` lab-harness builds of the PR
  branch. They use the signed release `mlx.metallib` (sha256 `589e56e0...a094`)
  and mlx-swift-lm `3.32.3-macprovider.24` (`39ccc0e`). Each window ran with
  the live provider paused and the model loaded once.
- Reference: mlx-vlm greedy decode of the same artifact.
- Window 2 ran at source `923d1b771` + `be645f33a` + `8d6273adb` (throughput, long
  context). Window 3 ran at `5a931d2f7` (serial prefill stride; parity and CB
  exactness). Windows 5 and 5b ran only the self-check, at `352fcfc55` and
  `069a852a7`. Neither fix changes decode numerics. `352fcfc55` leaves the
  decode-path digest unchanged. `069a852a7` drops a `maxKVSize` cap that the
  MiniMax M3 caches never applied. Windows 1 to 4 never reached a self-check
  decision because CB did not attach.
- Lab-only diagnostics (env-gated step timing and probe tracing) ran from a
  separate uncommitted build. They are not part of the PR and are described
  below only as diagnosis.

## Results

| Cell | Gate | Result | Verdict |
| --- | --- | --- | --- |
| Greedy parity vs mlx-vlm, 1k/8k (code, doc) | greedy tokens match the reference | code-8k, doc-1k match 128/128. code-1k diverges at 77 (ref margin 0.125), doc-8k at 52 (ref margin 0.0); CB picked the reference's 2nd token both times | 2/4 exact; 2 diverge at a near-tie |
| CB exactness, rows [1024, 8192, 1024, 8192] | batched == serial | 160 tokens/row identical, all rows | PASS |
| CB exactness, rows [2000, 1960, 2100, 1900] (straddle 2048) | batched == serial | identical, all rows (code-2100 diverged at token 3 before `5a931d2f7`) | PASS |
| ContinuousBatchingSelfCheck | attach + self-check decides | attach probe proven (rows 2, 0 failures, 0 cross-row divergences). Self-check `granted`, 4 slots, every rung conformant with no divergent rows: gain 1.17x (2 rows), 1.29x (3), 1.36x (4) | PASS |
| msb 1k, 1 row | CB ≥ 0.95x serial | 26.0 vs 29.0 tok/s = 0.90x | FAIL |
| msb 1k, 4 rows | aggregate ≥ 1.8x serial | 38.7 tok/s = 1.34x serial (1.50x CB 1-row) | FAIL |
| msb 1k, 4 rows paged engine | (reference) | 38.8 tok/s = 1.34x | - |
| 8k, 1 row | (measure) | serial 20.4, CB 18.8 tok/s (0.92x); TTFT 34.7 s / 34.8 s | - |
| 32k, 1 row | (measure) | serial 16.2, CB 15.2 tok/s (0.94x); TTFT 173 s / 174 s | - |
| Peak footprint | (measure) | 187 GB (1k) to 218 GB (32k) | - |

Files: `parity.json` and `parity-vs-mlx-vlm.txt` (window 3);
`msb-sched-rows1.json`, `msb-sched-rows4.json`, `msb-paged-rows4.json`,
`long-8k.json` and `long-32k.json` (window 2); `selfcheck-attach-probe-pass-capacity-fail.log`
(window 5); `selfcheck-granted.log` and `selfcheck-status.json` (window 5b).

## Diagnosis of the throughput cells

- 1 row: the CB step costs a constant ~4 ms more than serial at every context
  (1k, 8k, 32k), so KV copies are ruled out. Step timing: 34.4 ms graph build +
  4.0 ms GPU wait = 38.3 ms, against ~34.5 ms serial. Evaluating cache state
  each step changed nothing. Raising the command-buffer size moved time from
  build to wait at the same total. The gap is GPU-side, in the batched graph,
  and not yet attributed.
- 4 rows: 102.7 ms per step, 2.68x the 1-row step. Top-4 routing over 128
  experts touches ~15 distinct experts per layer at 4 rows, about 2.5x the
  1-row expert bytes. Decode is bandwidth-bound on expert weights, which puts
  the ceiling near 1.6x without kernel work. The 1.8x gate looks unreachable
  for this model on this host.

## Fixes found by these windows

- `5a931d2f7`: a `minimax_m3` row prefills in the serial stride. A balanced
  chunk crossing the 2,048-key selection threshold changed numerics
  (SPEC-038 v0.3.35).
- `352fcfc55`: the batched-isolation attach probe compares `pagedIndexedKV`
  rows against the production serial iterator. mlx-vlm's own incremental
  decode differs from its full recompute on this model (prompt B: incremental
  `[256, 4160, 46165]`, recompute after 256 gives 490), so the recompute
  reference rejected rows that matched serial exactly and CB never attached.
- `069a852a7`: MiniMax M3 serve parameters carry no `maxKVSize`, as for
  GLM-5-Next and DeepSeek V4. Its sparse caches keep the whole context for
  the indexer, and with the 64k serve cap mlx-swift-lm's explicit-cache check
  failed the self-check's serial baseline (and any serial request) with
  `incompatibleCapacity(expected: 65536, count: 60)`.
