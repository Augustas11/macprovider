# Qwen3.6-27B continuous batching: Studio evidence, 2026-09-24 (#1646 / #1731)

This is the lab round for the goal of running the Mac Studio live provider on
`qwen/qwen3.6-27b` with continuous batching. The live provider was paused for
the whole window at the operator's request, so nothing else was resident. The
build is a lab Swift release built on the box (`--no-join`, isolated config and
credential root). As with M3, the ceiling check has to be re-recorded on the
packaged RC before it gates an enable.

Raw data: [`data/cb-qwen36-2026-09-24/`](data/cb-qwen36-2026-09-24/).

## Tuple

Mac Studio M3 Ultra 256 GB, macOS 26.4.1; `qwen/qwen3.6-27b` @ `518ef47c…`
(`Qwen3_5ForConditionalGeneration`, dense, 64 layers, three linear-attention
layers for every full-attention layer). Paged KV covers only the 16
full-attention layers (64 KiB/token, fp16), and the GatedDeltaNet state is
packed per row (`cache_class: mixed`). Other settings:
`continuous_batching: canary`, `max_concurrency_override: 8`, queue limit 16,
and accepted tuple `{qwen/qwen3.6-27b, mixed, fp16, requires_moe: false,
apple-silicon:Apple M3 Ultra:ram-256gb}`. Batching covers first turns only
(the #1731 scope); positive cached-prompt tokens stay serial.

Builds:

| Label | Binary SHA-256 | Source |
| --- | --- | --- |
| `final` | `f5f2f69a…` | `d1445f91` |
| `cap2g` | `9b137a2e…` | `4d88854d` with `mlx_cache_limit_mb: 2048` |

## Startup proof (`startup-probe.txt`)

On Qwen3.6, the first two isolation challenge pairs produce the same serial
reference at some step, which gives the probe no way to prove isolation.
`87ba9771` makes the probe walk its ordered pairs until one is distinguishing
(`firstDistinguishingIsolationProbe`). Pair 2 proves it: `proven=true
rowsDecoded=2 rowFailures=0 crossRowDivergences=0
challengeDistinguishing=true`. Paged parity was also established on all 16
paged layers (1024/1024 gather calls, non-identity permutation).

## Throughput (interleaved A/B, `*/ab.jsonl`)

Serial and batched runs were interleaved per (rows, repeat). Each request
produced 256 greedy completion tokens. Each cell is the median of 3 repeats.
Every run was clean: 0 errors and 0 contaminated samples.

| Rows | Serial tok/s | Batched `final` | ÷ serial | Batched `cap2g` | ÷ serial |
| --- | --- | --- | --- | --- | --- |
| 1 | 36.6 | 33.2 | **0.91×** | 33.4 | **0.91×** |
| 2 | 37.0 | 52.0 | **1.41×** | 54.4 | **1.47×** |
| 4 | 37.1 | 61.0 | **1.64×** | 60.4 | **1.63×** |
| 8 | 37.2 | 69.0 | **1.86×** | 68.3 | **1.83×** |

The run meets the FR-PKV13 ceiling recorded for M3: 1 row ≥ 0.90× and 2+ rows
≥ 1.0×. The one-row margin is thin (0.91×), so the packaged-RC re-record must
repeat it. The `ab.jsonl` build label `q36_f3f210fa` is a stale script label;
`binary.txt` is authoritative.

## Correctness

- **Isolation (`final/isolate.jsonl`):** every row in five scenarios is exact
  against serial. The scenarios are 4× the same prompt, 3 and 4 ragged rows,
  4 ragged rows staggered by 0.5 s, and a long row next to a short one.
- **Cross-row (`*/crossrow.jsonl`, 80 tokens, distinct prompts):** 2/2 and 4/4
  rows are exact. At 8 rows, 7/8 are exact. Row 7 diverges late, at char 83
  of 288, with no leak signal: its best prefix match against any other row is
  0 characters. This is the same padded-attention accumulation-order
  divergence recorded for M3 ragged rows. Both builds show the identical
  pattern.
- **Long rows (`final/parity-*-1024.json`):** two 1024-token rows complete
  batched with `finish: length`. Their content differs from serial after the
  divergence point, within the same tolerance as above. It is not claimed as
  exact.
- `failures.txt` is empty for both builds: 0 forward failures.

## Memory: MLX buffer cache (`*/footprint-timeline.txt`)

Without a limit, MLX's `Memory.cacheLimit` defaults to the memory limit, so
freed decode buffers are kept. The process footprint grew to **48 GB** and
stayed there after the load ended. With `mlx_cache_limit_mb: 2048`
(`4d88854d`, also `MACPROVIDER_MLX_CACHE_LIMIT_MB`), the footprint settled at
**16–17 GB** after the same workload, and throughput did not drop (table
above). This matters because the same growth on the live provider (~130 GB)
together with a lab serve caused the jetsam kills recorded in the M3 evidence.
The live enable sets the limit.

## Hang soak (`soak/`, build `cap2g`)

The AC-25 lifecycle suite plus serial/batched probe pairs ran for 8 iterations
over 15 minutes: **520 requests, 0 timeouts (60 s stall bound), 0 errors**,
with no stall captures.

## Enable configuration derived from this round

```yaml
model: qwen/qwen3.6-27b
continuous_batching: canary
max_concurrency_override: 8
mlx_cache_limit_mb: 2048
continuous_batching_accepted_tuples:
  - model_id: qwen/qwen3.6-27b
    cache_class: mixed
    kv_dtype: fp16
    requires_moe: false
    hardware_class: "apple-silicon:Apple M3 Ultra:ram-256gb"
```

This goes on the live provider only after #1716 merges and the signed CLI
containing it is installed. Verification uses real traffic: `/v1/status`
shows CB active, the observed batch depth exceeds 1, and footprint headroom
holds over time.

## What this does not claim

- No earnings or fleet-capacity claim, and nothing about other hardware.
- No exact-token parity for late ragged divergence.
- Nothing about multi-turn requests with cached prompt tokens, which stay
  serial.
