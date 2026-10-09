# #1906 gap isolation (2026-10-09)

Question: why do mlx-lm and oMLX out-serve our runtime at 8–16 concurrent
requests on the served Qwen3.6-35B-A3B artifact (see
`../runtime-compare-2026-10-09/`)?

## Valid results

| Cell | mlx-lm 0.31.3 / MLX 0.31.2 | mlx-lm 0.32.0 / MLX 0.32.3 | Ours, window 16 (MLX 0.31.4) |
| --- | --- | --- | --- |
| Prompt-heavy, 8 | 170.9 | 190.2 | 137.1 |
| Prompt-heavy, 16 | 183.9 | 209.8 | 149.2 |
| Output-heavy, 8 | 230.0 | 255.6 | 207.7 |
| Output-heavy, 16 | 262.8 | 321.1 | 269.8 |

- MLX 0.32 vs 0.31 is worth +11–22% to the same mlx-lm server.
- On the same MLX generation, ours at window 16 matches mlx-lm on
  output-heavy 16 (270 vs 263) and trails on prompt-heavy (149 vs 184 at 16):
  prompt scheduling remains a real lever after the MLX upgrade.

## Invalid results (kept in `sweep-raw.jsonl` for the record)

From 11:03 UTC until the bench fix, the live provider (CLI 1.8.230, swapped
in at 10:50 UTC) kept 8 requests generating through every "pause": a pause
stops admission only. The first isolation run's output-heavy mlx-lm cells,
all `ours-w16-stock` cells and the model-level paged/contiguous cells ran
next to those 8 live streams and must not be used. Its contiguous-cache cell
(252 vs 188 tok/s for paged at 8 rows, same contended conditions) is only a
hint for the paged-cache lever.

`scripts/lab/cb-studio/bench.sh` now waits until live reports
`requests_in_flight: 0` (`LIVE_DRAINED`) before measuring.

## Not run

Clean stock-vs-fused MoE and paged-vs-contiguous cells were stopped by
operator decision: they must be re-measured on the upgraded mlx-swift-lm
3.32.3 / MLX 0.32.3 build anyway.
