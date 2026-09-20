# Continuous-batching throughput — scheduler lockstep window, 2026-09-20

Follow-up to [`continuous-batching-scheduler-compiled-evidence-2026-09-20.md`](continuous-batching-scheduler-compiled-evidence-2026-09-20.md).

That bundle proved the compiled lockstep window on `PagedKVSharedForwardBackend`. Production `ContinuousBatchScheduler.runDecodeStep` still called one-token `decode(rows:)` unless nothing was waiting to join. This slice wires `decodeLockstepWindow` into the scheduler (queue-empty / no in-flight prefill) and re-measures through `ContinuousBatchScheduler.submit`. Command: `msb-throughput --engine scheduler --compile`.

Buyer `continuous_batching` stays **off**. Live v1.8.170 slots stay at 4. Do not canary 170.

## Header

- **Date:** 2026-09-20
- **Operator:** augstar
- **Provider id:** non-production test drive; no coordinator join, no buyer traffic, no receipts
- **Measurement seam:** `macprovider-cli msb-throughput --engine scheduler --compile`
- **Binary:** `feat/spec038-scheduler-lockstep-window` built on-box (Swift release), run from `run/` co-located with candidate v1.8.170 `mlx.metallib`
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1, AC power
- **Live serve:** v1.8.170 `live.malibu.provider` stayed up on port 8080 for the whole run (pid 83717)
- **Workload:** 1024 prompt tokens/row, 128 timed decode tokens/row, temperature 0, 1 warmup + 3 timed runs

JSON artifacts: [`data/cb-throughput-2026-09-20-scheduler-window/`](data/cb-throughput-2026-09-20-scheduler-window/). Local artifact paths in the raw harness output were replaced with the catalog model id before check-in.

## Result: the serve-path scheduler now scales on the production MoE tuple

Qwen3-Coder-30B-A3B-Instruct-4bit vs production serial `generate()` (~106 tok/s). Peak RSS ~33 GB. Timed window is `decodeLockstepWindow` only (prefill excluded). `one_token_decode_calls=0` on every run.

| Rows | Serial | 1-row (scheduler) | Aggregate | vs serial | vs 1-row |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 106.4 | 96.7 | 153.0 | **1.44×** | 1.58× |
| 4 | 106.4 | 96.5 | 206.5 | **1.94×** | 2.14× |

MSB-04 (>1.3× at 2 rows) and MSB-02 (>1.5× at 4 rows) both pass against production serial.

Engine-direct compiled paged window was 1.55× / 2.20×. The scheduler path is a small tax (admission stagger: 1-row used 1 window call, 2-row used 3, 4-row used 7) and still clears both gates. That tax is join/prefill interleaving, not a return to per-token `container.perform` hops.

## What this enables, and what it does not

`ContinuousBatchScheduler` now calls `decodeLockstepWindow` when the admission queue, in-flight binding checks, and active prefill set are empty, capped by `maxDecodeLockstepWindow` (production 16; this harness used 128 so the timed burst is one hop when rows start together). A queued row forces the next hop back to one token (FR-CB5). The backend returns every sampled token; the scheduler applies them sequentially for stop, stream, and receipt.

Buyer `continuous_batching` still stays **off** until a packaged RC canary. FR-CB15 leftover measurements (MSB-03, MSB-05 Q1, usage, isolation, drain, replay) are in [`continuous-batching-frcb15-leftovers-evidence-2026-09-20.md`](continuous-batching-frcb15-leftovers-evidence-2026-09-20.md). MoE promotion review (flag stays false): [`continuous-batching-moe-promotion-review-2026-09-20.md`](continuous-batching-moe-promotion-review-2026-09-20.md). Do not raise `max_concurrency_override` on v1.8.170. Do not flip canary on 170.

## Secrets redaction check

`msb-throughput` emits token counts, tokens/sec, RSS MB, engine/compile flags, and model tuple metadata. Checked-in JSON uses the catalog model id, not the on-box artifact path.
