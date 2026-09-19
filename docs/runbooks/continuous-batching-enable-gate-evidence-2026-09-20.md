# Continuous-Batching Throughput Evidence — 2026-09-20

FR-CB15 / MSB-01..05 measurement per
[`continuous-batching-enable-gate.md`](continuous-batching-enable-gate.md).
Sanitized: token counts and tokens/sec only; no tokens, keys, or bearer headers.

## Header (runbook Evidence Template)

- **Date:** 2026-09-20
- **Operator:** augstar
- **Provider id:** non-production test drive; no coordinator join, no buyer traffic, no receipts
- **Measurement seam:** `macprovider-cli msb-throughput` (drives `PagedKVSharedForwardBackend`
  directly, mirroring `ContinuousBatchScheduler.runDecodeStep`; NOT the buyer-serve path)
- **Binary under test:** `perf/spec038-msb-throughput-harness`, built on-box (Swift 6.3.3,
  `swift build -c release`), co-located with candidate v1.8.170 `mlx.metallib` +
  `mlx-swift_Cmlx.bundle`
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1, AC power,
  no thermal/perf warnings recorded
- **Model tuple:** `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` (MoE, `requiresMoE=true`),
  snapshot `6e302ea604ad9ab206367e2c501d1571023e7b6d`, 4-bit, `KVCacheSimple` class, no `kv_bits`,
  48 KV layers
- **Paged-KV tuple:** `blockSizeTokens=16`, `maxPhysicalBlocks=1024` — the production
  `PagedKVConfig` defaults, i.e. the tuple an operator would actually enable
- **Workload:** 1024 prompt tokens/row, 256 timed decode tokens/row, temperature 0, distinct
  topical prompt per row, 1 warmup + 5 timed runs, decode-only wall-clock (one untimed warm
  step after prefill produces the TTFT-boundary token, then the timed window)

## Correctness precondition (proven separately, merged)

Attach eligibility + per-request isolation on the real model were proven prior:
`parity established=true (3072/3072)`, `batched-isolation proven=true crossRowDivergences=0`,
`measure OK: paged-KV attach eligible`. FR-CB6 numerical tolerance (#1608) and attach gates
(#1597) are merged to `main`. This bundle measures **throughput only**.

## Results (production tuple, block size 16)

Production serial single-stream (today's serve decode path, `generate()` over
`KVCacheSimple`, same 1024-token prompt as the batched rows): **106.4 tok/s**
decode p50 (CV < 0.3%).

Paged-KV continuous-batching aggregate decode throughput:

| Rows | Paged single-row (tok/s) | Aggregate TG (tok/s) | Uplift vs paged 1-row | Aggregate ÷ serial 106.4 | Per-row fraction | Peak RSS | Agg CV |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 (MSB-04) | 35.2 | 42.3 | 1.20× | **0.40×** | 0.60 | 32.2 GB | 0.2% |
| 4 (MSB-02) | 35.4 | 46.5 | 1.31× | **0.44×** | 0.33 | 32.3 GB | 0.4% |
| 6 | 35.3 | 47.5 | 1.34× | **0.45×** | 0.22 | 32.3 GB | 0.1% |
| 8 | 34.9 | 46.8 | 1.34× | **0.44×** | 0.17 | 32.4 GB | 0.1% |

- **MSB-01 baseline:** serial 106.4 tok/s; paged single-row ~35 tok/s. Stable (all CV < 0.4%),
  zero correctness/row failures, peak RSS 32 GB ≪ 85%-of-256 GB (217.6 GB) bound.
- **MSB-04 (2-row MoE):** aggregate 42.3 tok/s = **1.20×** paged single-row; below the MSB-04
  gate of **>1.3×**. Per-row 0.60 (≥0.45 ✓) but the gate is not met, and aggregate is only
  0.40× the serial serve rate.
- **MSB-02 (4-row):** aggregate 46.5 tok/s = 1.31× paged single-row; below the MSB-02 gate of
  **>1.5×**.
- **Concurrency sweep (6, 8 rows):** aggregate **saturates at ~47 tok/s and then declines**
  (42.3 → 46.5 → 47.5 → 46.8); per-row throughput collapses (0.60 → 0.17). Batching never
  approaches the 106.4 tok/s serial rate at any tested concurrency.

## Interpretation

At the production block size (16), the paged-KV engine's single-row decode (35.4 tok/s) is
only ~33% of the production serial decode (105.9 tok/s): ~28 ms/token vs ~9 ms/token, an ~19
ms/token **Metal paged-gather tax** (each 1280-token row spans ~80 physical blocks the gather
kernel must reconstruct every step). Per-step block-allocator bookkeeping is a handful of
in-process actor hops (microseconds in the single-threaded measurement window), so the gap is
the gather cost, not harness overhead — confirmed by the saturating/declining aggregate curve
(fixed CPU overhead would amortize toward linear scaling).

MoE compounds this: the model's value is sparse expert activation, so batching distinct rows
activates *more* total experts and yields little weight-reuse benefit — the batched uplift
saturates at ~1.35× regardless of depth.

Block size is a real lever: at a non-production `blockSizeTokens=256` the paging tax roughly
halves (paged single-row 57 tok/s; aggregate reaches 0.89× serial at 8 rows), but production
uses 16 for KV memory efficiency. Neither tuple beats serial.

**Net:** on the production tuple, continuous batching would roughly **halve** the box's token
throughput (aggregate ≤ 0.45× serial) while adding concurrency/latency headroom. It is not a
throughput or earnings win on Qwen3-Coder-30B-A3B here.

- **MSB-03 (ragged prompts):** not run — harness uses equal-length prompts. Follow-up.
- **MSB-05 (vs oMLX oracle):** not run — no pinned oMLX sidecar on this box. Follow-up.

## Secrets redaction check

`msb-throughput` emits only token counts, tokens/sec, RSS MB, and model tuple metadata. No
provider/buyer tokens, keys, or authorization headers are printed. Confirmed.

## Decision

**Keep `continuous_batching: off` on this tuple for throughput purposes.** The FR-CB15 /
MSB-04 throughput gate is **not met**: measured aggregate batched throughput saturates at
≤0.45× the serial serve rate at 2–8 concurrent rows on the production paged-KV tuple.
Correctness (attach + FR-CB6 isolation) remains proven; the paging engine is ready for
capacity/latency use cases (many concurrent long-context streams within a flat ~32 GB RSS),
but continuous batching is not a throughput/earnings win on this MoE model.

**Follow-ups (do before any canary reconsideration):**
1. Reduce the paged-gather per-token cost (kernel / larger effective block, streamed gather) —
   the dominant tax; a ~2–3× gather speedup is the minimum needed to reach serial parity.
2. Re-measure on a dense (non-MoE) catalog model, where batching weight-reuse is far higher.
3. MSB-03 (ragged) and MSB-05 (oMLX oracle) for scheduler fairness and an upper-bound oracle.
4. Measure current N-independent-serial-stream aggregate (MSB-05 Q1) to confirm the serial
   baseline under real concurrency (contention may lower it, narrowing the gap).
