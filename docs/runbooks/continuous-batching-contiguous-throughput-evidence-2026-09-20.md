# Continuous-batching throughput — contiguous compiled path, 2026-09-20

Follow-up to [`continuous-batching-enable-gate-evidence-2026-09-20.md`](continuous-batching-enable-gate-evidence-2026-09-20.md) and the adversarial note on PR #1623.

The earlier paged-gather harness proved the **SPEC-039 gather backend cannot beat serial**. This bundle measures the **throughput ceiling** on the same Mac Studio: stock `KVCacheSimple`, batch dimension B, one `container.perform` for the decode window, tokens kept as GPU arrays, `MLX.compile()`. Command: `msb-throughput --engine contiguous --compile`.

Sanitized: token counts and tokens/sec only.

## Header

- **Date:** 2026-09-20
- **Operator:** augstar
- **Provider id:** non-production test drive; no coordinator join, no buyer traffic, no receipts
- **Measurement seam:** `macprovider-cli msb-throughput --engine contiguous --compile`
- **Binary:** worktree `perf/spec038-msb-throughput-harness` built on-box (Swift 6.3.3), run from `run/` co-located with candidate v1.8.170 `mlx.metallib` + `mlx-swift_Cmlx.bundle`
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1, AC power
- **Workload:** 1024 prompt tokens/row, 128 timed decode tokens/row, temperature 0, distinct topical prompt per row, 1 warmup + 3 timed runs, decode-only wall-clock

JSON artifacts: [`data/cb-throughput-2026-09-20-contiguous/`](data/cb-throughput-2026-09-20-contiguous/).

## Result: batching scales on this machine

### Llama-3.1-8B-Instruct-4bit (dense)

Serial `generate()` p50 is ~121 tok/s. Contiguous 1-row is ~114 tok/s (same engine, no 3× tax).

| Rows | Serial | 1-row | Aggregate | vs serial | vs 1-row |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 120.9 | 114.0 | 189.4 | **1.57×** | 1.66× |
| 4 | 121.4 | 114.4 | 226.5 | **1.87×** | 1.98× |
| 8 | 121.2 | 114.2 | 261.3 | **2.16×** | 2.29× |

Peak RSS 8.8 GB. MSB-02 (>1.5× at 4 rows) and MSB-04 (>1.3× at 2 rows) both pass vs production serial.

### Qwen3-32B-4bit (dense, similar weight size to the production 30B)

| Rows | Serial | 1-row | Aggregate | vs serial | vs 1-row |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 32.1 | 31.3 | 49.9 | **1.56×** | 1.59× |
| 4 | 32.1 | 31.3 | 57.2 | **1.78×** | 1.83× |
| 8 | 32.0 | 31.2 | 64.0 | **2.00×** | 2.05× |

Peak RSS 35.4 GB.

### Qwen3-Coder-30B-A3B-Instruct-4bit (production MoE)

This is the tuple whose paged-gather path topped out at 42–47 tok/s (0.45× serial). Same box, same model, contiguous compiled path:

| Rows | Serial | 1-row | Aggregate | vs serial | vs 1-row |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 105.9 | 99.7 | 166.5 | **1.57×** | 1.67× |
| 4 | 105.6 | 99.1 | 235.9 | **2.23×** | 2.38× |
| 8 | 106.7 | 100.0 | 322.3 | **3.02×** | 3.22× |

Peak RSS 33.0 GB, flat across 2–8 rows (same ~32 GB envelope as the paged runs).

MSB-02 and MSB-04 **pass** on the live MoE tuple against production serial.

## What this attributes

The 2026-09-20 paged evidence is unchanged and still correct **for that backend**: reverse-gather `PagedKVCache.update` + per-row concat + per-token `container.perform` + `asArray` cannot beat serial.

It was **not** a Mac Studio RAM/hardware limit, and it was **not** a structural MoE batching impossibility. Contiguous 1-row is 99.7 tok/s vs gather 1-row ~35 tok/s vs serial 106 tok/s. Removing the gather/orchestration tax closes the 3× hole; shared-forward batching then scales.

MoE 8-row aggregate (322 tok/s) outscales dense 32B 8-row (64 tok/s) because ~3B active parameters leave more headroom for weight reuse across the shared attention path.

## What this does not enable

- Buyer-serve `continuous_batching` stays **off**. The scheduler still drives `PagedKVSharedForwardBackend` per decode step. This bundle is the ceiling proof, not an enable-gate package (no packaged RC identity, no usage/receipt attribution under the serve path, no warm-swap).
- Production `PagedKVSharedForwardBackend` now skips the reverse-gather on the hot path (`reconstructViaGather: false`). Parity fixtures still force gather. A same-tuple 2-row paged run after that change is still **0.53× serial** (55.5 vs 105.8 tok/s; 1-row 45.2 vs gather-era 35). Skip-gather is necessary but not sufficient: the scheduler-shaped per-token actor hop + per-row concat still loses. The compiled lockstep loop is the path that scales.
- Ragged MSB-03 and an oMLX/llama.cpp oracle (MSB-05) are still unrun.

## Secrets redaction check

`msb-throughput` emits only token counts, tokens/sec, RSS MB, engine/compile flags, and model tuple metadata. Confirmed on every JSON in this bundle.

## Decision

**Continuous batching can scale throughput on this Mac Studio.** On the production MoE tuple the contiguous compiled path delivers 1.57× / 2.23× / 3.02× serial at 2 / 4 / 8 rows. Keep buyer `continuous_batching: off` until the scheduler decode loop uses this engine (or an equivalent skip-gather + compiled inner loop) and the remaining FR-CB15 serve proofs land. Do not treat the earlier gather-backend failure as a reason to stop.
