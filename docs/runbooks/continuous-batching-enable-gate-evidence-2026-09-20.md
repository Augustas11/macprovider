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
- **Workload:** 1024 prompt tokens/row, 256 decode tokens/row, temperature 0, distinct prompt
  per row, 1 warmup + 5 timed runs, decode-only wall-clock (TTFT/prefill excluded)

## Correctness precondition (proven separately, merged)

Attach eligibility + per-request isolation on the real model were proven prior:
`parity established=true (3072/3072)`, `batched-isolation proven=true crossRowDivergences=0`,
`measure OK: paged-KV attach eligible`. FR-CB6 numerical tolerance (#1608) and attach gates
(#1597) are merged to `main`. This bundle measures **throughput only**.

## Results

Production serial single-stream (today's serve decode path, `decode-bench`, `KVCacheSimple`):
**105.6 tok/s** decode p50 (prefill 1931 tok/s).

Paged-KV continuous-batching aggregate decode throughput:

| Rows | Paged single-row (tok/s) | Aggregate TG (tok/s) | Uplift vs paged 1-row | Aggregate vs serial 105.6 | Per-row fraction | Peak RSS | CV |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 (MSB-04) | 57.1 | 68.6 | 1.20× | 0.65× | 0.60 | 32.3 GB | 0.0% |
| 4 (MSB-02) | 57.0 | 81.5 | 1.43× | 0.77× | 0.36 | 32.2 GB | 0.3% |
| 6 | 57.2 | 89.3 | 1.56× | 0.85× | 0.26 | 32.2 GB | 0.2% |
| 8 | 56.8 | 93.7 | 1.65× | 0.89× | 0.21 | 32.3 GB | 0.2% |

- **MSB-01 baseline:** serial 105.6 tok/s; paged single-row 57 tok/s. Stable (CV < 0.3%),
  zero correctness failures, peak RSS 32 GB ≪ 85%-of-256 GB (217.6 GB) bound.
- **MSB-04 (2-row MoE):** aggregate 68.6 tok/s = **1.20×** the paged single-row baseline.
  Below the runbook/RESEARCH_232 MSB-04 gate of **>1.3×**. Per-row 0.60 (≥0.45 ✓) but the
  gate is not met.
- **MSB-02 (4-row):** aggregate 81.5 tok/s = 1.43× paged single-row; below the MSB-02 gate
  of **>1.5×**.
- **Concurrency sweep (6, 8 rows):** aggregate rises monotonically but concavely
  (68.6 → 81.5 → 89.3 → 93.7; deltas 12.9 / 7.8 / 4.4), asymptoting near ~100 tok/s and
  **never exceeding the 105.6 tok/s serial rate within 2–8 rows.**

## Interpretation

The paged-KV engine's own single-row decode (57 tok/s) is ~54% of the production serial
decode (105.6 tok/s). The per-token gap is ~8 ms (17.5 ms paged vs 9.5 ms serial). Per-step
block-allocator bookkeeping is a handful of in-process actor hops (microseconds in the
single-threaded measurement window), so the gap is the **Metal paged-gather tax**, not harness
overhead — confirmed by the sub-linear aggregate scaling (fixed CPU overhead would amortize to
near-linear scaling; the observed concave curve is GPU-forward cost rising with batch depth).

MoE compounds this: the model's value is sparse expert activation, so batching distinct rows
activates *more* total experts and yields less weight-reuse benefit than dense-model batching —
consistent with the modest 1.20× at 2-way.

**Net:** on this exact tuple, continuous batching increases the paged engine's aggregate
throughput (1.20×–1.65×) but does not beat today's serial serve rate at any tested concurrency.
Enabling it would trade raw throughput for concurrency/latency, not gain tokens/sec.

- **MSB-03 (ragged prompts):** not run — harness uses equal-length prompts. Follow-up.
- **MSB-05 (vs oMLX oracle):** not run — no pinned oMLX sidecar on this box. Follow-up.

## Secrets redaction check

`msb-throughput` emits only token counts, tokens/sec, RSS MB, and model tuple metadata. No
provider/buyer tokens, keys, or authorization headers are printed. Confirmed.

## Decision

**Keep `continuous_batching: off` on this tuple for throughput purposes.** The FR-CB15 /
MSB-04 throughput gate is **not met**: measured aggregate batched throughput is below the
serial serve rate at 2–8 concurrent rows. Correctness (attach + FR-CB6 isolation) remains
proven; the paging engine is ready for capacity/latency use cases, but continuous batching is
not a throughput/earnings win on Qwen3-Coder-30B-A3B here.

**Follow-ups (do before any canary reconsideration):**
1. Reduce the paged-gather per-token cost (kernel) — the dominant tax.
2. Re-measure on a dense (non-MoE) catalog model, where batching weight-reuse is higher.
3. MSB-03 (ragged) and MSB-05 (oMLX oracle) for scheduler fairness and an upper-bound oracle.
4. Measure current N-independent-serial-stream aggregate (MSB-05 Q1) to confirm the serial
   baseline under real concurrency.
