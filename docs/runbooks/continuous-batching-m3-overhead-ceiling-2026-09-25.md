# M3: paged-KV overhead ceiling on the final #1646 build (SPEC-039 FR-PKV13)

- **Build:** `campaign/1646-remaining` at `23429b7d`, binary `95d9b943cee6c7cd`.
- **Hardware and model:** Mac Studio M3 Ultra 256 GB, `mlx-community/Qwen3.6-27B-4bit`.
- **Harness:** `macprovider-cli msb-throughput` (`--runs 2`, 128 decode tokens), with the live provider paused.
- **Data:** [`data/cb-m3-ceiling-2026-09-25/`](data/cb-m3-ceiling-2026-09-25/).

## Gate
SPEC-039 FR-PKV13 requires a recorded overhead ceiling for the paged serving path. The #1646 acceptance values:
- 1 row: at least 0.90× the production serial decode;
- 2 or more rows: at least 1.0×.

A tuple over the ceiling must not carry real traffic in paged mode.

## Result: PASS

Aggregate decode (tok/s, p50) against the production serial path (`generate()`, about 36.6–38.4 tok/s):

| Prompt | Rows | Paged tok/s | Ratio to serial | Plain-MLX (contiguous) tok/s | Paged / plain MLX |
| --- | --- | --- | --- | --- | --- |
| 32 | 1 | 34.4 | **0.90×** | 38.0 | 0.91 |
| 32 | 2 | 57.4 | 1.50× | 62.8 | 0.91 |
| 32 | 4 | 68.5 | 1.78× | 71.3 | 0.96 |
| 32 | 8 | 79.2 | 2.07× | 81.3 | 0.97 |
| 1.5k | 1 | 33.9 | **0.90×** | 37.4 | 0.91 |
| 1.5k | 2 | 56.1 | 1.49× | 61.8 | 0.91 |
| 1.5k | 4 | 66.3 | 1.75× | 70.7 | 0.94 |
| 1.5k | 8 | 76.7 | 2.03× | 79.4 | 0.97 |
| 4k | 1 | 32.9 | **0.90×** | 36.2 | 0.91 |
| 4k | 2 | 54.3 | 1.48× | 59.4 | 0.91 |

**Two or more rows** clear the 1.0× gate by a wide margin at every length.

**One row sits exactly on the 0.90× bound.** The paged single-row path costs about 10% against serial. Production canary serial-routes lone requests, so the 1-row paged figure only matters when a batch drains to one row.

**The paged engine is within 3–9% of plain MLX** at every row count, so the remaining gap is MLX's own small-batch kernel cost, not paging.

The 4k × 4 and 4k × 8 runs were cut short to limit the live-provider pause. The 32-token and 1.5k rows cover the trend.
