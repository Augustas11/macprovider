# Issue #1906: CB depth on the 256 GB M3 Ultra (lab, 2026-10-09)

Model `qwen/qwen3.6-35b-a3b` (4-bit, artifact `3fed776d…`), Mac Studio M3 Ultra
256 GB. Worktree `swift build -c release` binary
`ea42fd7226bf599ef8afd54136467c3c2199ef9b9ad018bf2b3df96ae2c3c73d` with the
absolute served-depth bound raised to 32. Isolated loopback serve
(`--no-join --autotune-candidate`), `continuous_batching: canary`, the live
`:8080` provider paused for every measured run (`bench.sh`), released 1.8.224
metallib `84e48718…`, `mlx_cache_limit_mb: 2048`.

Load: `scripts/lab/cb-studio/depth_sweep.py`. N closed-loop workers, unique
salted prompts (no prefix reuse), greedy, streamed. Throughput counts only
tokens emitted inside the measured window. Reasoning and content tokens both
count.

## Serve, 1536-token prompts, 256 output tokens (`sweep-2026-10-09/`)

| Depth | Fused agg tok/s | Stock agg tok/s | TTFT p50 / p95 (fused) | ITL p50 / p95 ms (fused) | Per-stream decode (fused) |
| --- | --- | --- | --- | --- | --- |
| 4 | 103.1 | 102.0 | 1.9 / 3.0 s | 22 / 45 | 32.4 |
| 8 | 114.8 | 115.6 | 2.3 / 4.4 s | 37 / 301 | 17.1 |
| 12 | 118.2 | 121.9 | 2.9 / 6.0 s | 51 / 421 | 11.9 |
| 16 | 126.8 | 133.8 | 5.6 / 9.2 s | 66 / 552 | 9.6 |
| 24 | 139.5 | 141.6 | 11.3 / 14.0 s | 102 / 664 | 6.9 |
| 32 | 134.4 | 138.8 | > 90 s per request | — | — |

Zero errors at every depth. Fused vs stock MoE decode
(`MLX_LM_QWEN35_FUSED_MOE=0`) is a wash at 4–8 rows and stock is 1–5% ahead
at 12–24. The fused kernel splits each decode call into chunks of at most 7
tokens, so at depth it runs several kernel passes where stock runs one.

## Split: decode ceiling vs prefill cost (`split-2026-10-09/`)

| Rows | Model-level paged decode (`msb-throughput`, no HTTP/prefill) | Serve, 128-token prompts | Serve, 1536-token prompts (fused) |
| --- | --- | --- | --- |
| 8 | 253.3 | 222.4 | 114.8 |
| 16 | 302.7 | 246.3 | 126.8 |
| 32 | 349.7 | 273.2 | 134.4 |

Short-prompt serve TTFT p95 stays under 0.7 s at every depth. Per-stream
decode falls to 15.8 tok/s at 16 rows and 8.7 at 32.

## Findings

1. **Decode alone gains little past 8 rows.** The decode ceiling rises
   1.20x from 8 to 16 rows and 1.38x from 8 to 32. Per-stream decode halves
   with each doubling.
2. **Prefill is the throughput sink at today's depth.** With 1536-token
   prompts the serve delivers 45% of the 8-row decode ceiling. With 128-token
   prompts it delivers 88%. From the 8-row numbers (0.45 req/s × 1536 prompt
   tokens over about 48% of GPU time), the effective prefill rate under load is
   about 1.4k tok/s.
3. **Why prefill is slow under load.** The scheduler batches prompt chunks
   only for rows at the same offset with the same chunk length
   (`ContinuousBatchScheduler.runPrefillStep`,
   `PagedKVRuntimeBridge.canSharePrefillForward`). Staggered arrivals almost
   never line up, so each 512-token chunk usually runs alone while decode
   waits. That is also what produces the ITL p95 stalls of 300–660 ms.
4. **Depth and TTFT.** With long prompts, TTFT p95 crosses the 8 s
   calibration ceiling at 16 rows. With short prompts, 32 rows still has a
   sub-second TTFT.

## Consequences for the campaign

- A per-class depth above 8 is worth up to about 1.2x (16 rows) for
  short-prompt traffic at an acceptable TTFT. It must be measured, not fixed:
  the calibration TTFT ceiling has to bound it, because long-prompt traffic
  breaches at 16.
- The larger lever is prefill efficiency at the current depth: up to about
  2.2x on long-prompt traffic at 8 rows. That is shared prefill across rows
  at different offsets, issue scope item 4.
