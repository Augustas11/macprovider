# Issue #1906: ragged shared prefill (lab, 2026-10-09)

Same box, model and load as `../README.md`: Mac Studio M3 Ultra 256 GB,
`qwen/qwen3.6-35b-a3b` 4-bit (artifact `3fed776d…`), isolated loopback serve
(`--no-join --autotune-candidate --no-idle-prewarm`), `continuous_batching:
canary`, `mlx_cache_limit_mb: 2048`, `depth_sweep.py` with 1536-token prompts,
256 output tokens, 90 s window, 20 s warmup.

Change under test: prompt rows at different prompt offsets share one `[B, L]`
prefill forward when their chunk lengths match (SPEC-038 v0.3.9 FR-CB2). Each
row keeps its own RoPE offset and gets a per-row causal mask.

## Throughput (live provider paused, one window)

Binary `23ecbe50…` (ragged sharing on). The budget column is
`continuous_batch_prefill_tokens_per_iteration`. Baseline is the pre-change
serve from `../sweep-2026-10-09/` (fused MoE, budget 1024).

| Depth | Run | Agg tok/s | TTFT p50 / p95 s | ITL p50 / p95 ms | Per-stream decode |
| --- | --- | --- | --- | --- | --- |
| 8 | baseline | 114.8 | 2.3 / 4.4 | 37 / 301 | 17.1 |
| 8 | ragged, budget 1024 | 122.0 | 2.0 / 3.6 | 36 / 272 | 17.7 |
| 8 | ragged, budget 2048 | 132.1 | 3.8 / 5.5 | 37 / 74 | 21.0 |
| 16 | baseline | 126.8 | 5.6 / 9.2 | 66 / 552 | 9.6 |
| 16 | ragged, budget 1024 | 130.1 | 2.7 / 7.5 | 65 / 533 | 9.2 |
| 16 | ragged, budget 2048 | 136.5 | 4.0 / 8.1 | 64 / 520 | 9.7 |

Zero errors in every run. Raw rows: `bench-sweep.jsonl`.

- With budget 1024 a 1.5k prompt's ~417-token chunks fit two per forward, so
  the gain is small (+6% at 8 rows). Budget 2048 fits four: +15% aggregate at
  8 rows and ITL p95 falls from 301 to 74 ms. At 16 rows: +8%, and ITL p95
  stays above 500 ms.
- TTFT p50 rises at 8 rows (2.3 → 3.8 s): a row now waits for a four-row
  forward rather than running its chunk alone. TTFT p95 at 16 rows improves
  (9.2 → 8.1 s).
- The gain is far below the 2.2x prefill-free ceiling. A four-row ~1.7k-token
  forward costs nearly four single-row forwards here. Prefill at this chunk
  size is mostly compute-bound, so batching rows recovers per-forward overhead
  and decode stalls, not much compute.
- The default budget is raised to 2048 on this evidence.

## Correctness (not paused; contended GPU)

`msb-throughput --engine paged --scenario ragged-prefill --parity-tokens 48
--runs 6` (`ragged-parity.json`, binary `23ecbe50…`). For each of 6 prompt
sets, three rows (1100, 800 and 650 tokens) run in two plans:

- **Ragged plan.** Shared calls hold rows at offsets {300, 0}, {600, 300, 0}
  and {850, 550, 250}. The last of these is length 250: the final chunk of two
  rows.
- **Aligned control.** Every shared call sits at one offset. This is the shape
  shared prefill already used before this change.

Each row is compared against the same row prefilled alone over the identical
partition, on the first sampled token and 47 greedy decode tokens.

| Plan | Rows exact over 48 tokens | First-token match | Earliest divergence |
| --- | --- | --- | --- |
| Ragged | 13 / 18 | 18 / 18 | token 13 |
| Aligned control | 12 / 18 | 18 / 18 | token 13 |

Every divergence is late (token 13 or later) and occurs at the same rate as
the accepted equal-offset path. That pattern fits FR-CB6 accumulation-order
near-ties between `[B, L]` and `[1, L]` GEMMs, not a position or mask fault,
which would break the first token. Against the production serial path, ragged
rows match all 48 tokens in 17 of 18 rows.

Serve startup on the new binary (`serve-probes-and-groups.txt`):
`parity … established=true` and `batched-isolation … proven=true
rowFailures=0 crossRowDivergences=0`.

Unpaused depth sweeps with `MACPROVIDER_CB_TRACE=1` (`unpaused-sweep.jsonl`)
had zero errors at 8 and 16 rows. Traced shared prefills:

- Budget 1024: 45 ragged two-row forwards.
- Final binary at the new default: 43 four-row, 14 three-row and 15 two-row
  ragged forwards.

Throughput numbers from those runs are contended and not comparable.
