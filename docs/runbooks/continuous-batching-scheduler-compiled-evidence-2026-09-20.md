# Continuous-batching throughput — scheduler compiled lockstep, 2026-09-20

Follow-up to [`continuous-batching-contiguous-throughput-evidence-2026-09-20.md`](continuous-batching-contiguous-throughput-evidence-2026-09-20.md).

The contiguous harness proved the Mac Studio can scale (1.57× / 2.23× / 3.02× at 2/4/8). This bundle drives the **same compiled lockstep window through `PagedKVSharedForwardBackend`**, which is what `ContinuousBatchScheduler.runDecodeStep` calls. Command: `msb-throughput --engine paged --compile`.

Prefill still writes per-row `PagedKVCache`. Timed decode packs that KV into stock `KVCacheSimple` `[B, S]`, runs `MLX.compile()` inside one `container.perform`, then writes the window back. Buyer `continuous_batching` stays **off**.

## Header

- **Date:** 2026-09-20
- **Operator:** augstar
- **Provider id:** non-production test drive; no coordinator join, no buyer traffic, no receipts
- **Measurement seam:** `macprovider-cli msb-throughput --engine paged --compile`
- **Binary:** `feat/spec038-compiled-scheduler-decode` built on-box, run from `run/` co-located with candidate v1.8.170 `mlx.metallib`
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1, AC power
- **Live serve:** v1.8.170 `live.malibu.provider` stayed up on port 8080 for the whole run
- **Workload:** 1024 prompt tokens/row, 128 timed decode tokens/row, temperature 0, 1 warmup + 3 timed runs

JSON artifacts: [`data/cb-throughput-2026-09-20-scheduler-compiled/`](data/cb-throughput-2026-09-20-scheduler-compiled/).

## Result: the scheduler backend now scales on the production MoE tuple

Qwen3-Coder-30B-A3B-Instruct-4bit vs production serial `generate()` (~106 tok/s). Peak RSS ~33 GB.

| Rows | Serial | 1-row (this engine) | Aggregate | vs serial | vs 1-row |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 106.6 | 99.6 | 164.8 | **1.55×** | 1.65× |
| 4 | 105.7 | 97.7 | 233.1 | **2.20×** | 2.39× |

MSB-04 (>1.3× at 2 rows) and MSB-02 (>1.5× at 4 rows) both pass against production serial. 1-row of this engine is 98–100 tok/s, in the same band as contiguous compiled 1-row (~100) rather than the earlier paged-wrapper 65 tok/s.

An earlier compiled-paged attempt that compiled over `PagedKVBatchLayerCache` itself only reached 1.04× / 1.59×. The win is compiling `KVCacheSimple`, not tracing the paged wrapper.

## What this enables, and what it does not

The production `ModelRuntime` now constructs `PagedKVSharedForwardBackend(compiledDecode: true)`. The scheduler's per-token `decode(rows:)` reuses the same compiled session; the harness window is the lockstep burst the scheduler can call when no join is pending (`decodeLockstepWindow`).

Buyer `continuous_batching` still stays **off** until the remaining FR-CB15 items land on a packaged RC: usage/receipt under the serve path, MSB-03 ragged, MSB-05, temp-0 parity, failure isolation, warm-swap, durable replay, and a separately reviewed MoE promotion (`moePromotionEvidenceUnavailable` still fail-closes Qwen3-Coder). Do not raise `max_concurrency_override` on v1.8.170. Do not flip canary on 170.

Independent serial `generate()` slots still do not scale (4k B=1..8 aggregate stayed ~27 tok/s). Throughput concurrency is this compiled shared-forward path.

## Secrets redaction check

`msb-throughput` emits token counts, tokens/sec, RSS MB, engine/compile flags, and model tuple metadata only.
