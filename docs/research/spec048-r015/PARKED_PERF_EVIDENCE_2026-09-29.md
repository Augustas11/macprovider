# SPEC-048 native MTP performance work — parked 2026-09-29

This branch parks the native-MTP round-overhead work for issue #1770. It is not
merged. The correctness and admission fixes shipped separately on
`campaign/native-mtp-r015`.

## Why it is parked

Measured on the Mac Studio M3 Ultra 256 GB serving `qwen/qwen3.6-35b-a3b`
(4-bit target, `mlx-community/Qwen3.6-35B-A3B-MTP-4bit` drafter, depth 1,
greedy, 384-token prompts, 256 output tokens, live provider paused through
`/Users/a1/lab-cb-sampling/bench.sh`):

| Slots | Ordinary tok/s | Native MTP tok/s | Ratio | Acceptance |
|---|---:|---:|---:|---:|
| 2 | 122.6 | 80.9 | 0.66x | 90% |
| 4 | 175.3 | 107.1 | 0.61x | 89% |
| 8 | 233.8 | 133.5 | 0.57x | 87% |

Per scheduler round (profiled run, before the fixes on this branch):

| Cell | Path | Target forward | Drafter commit | Drafter propose | Tokens/round | ms/token |
|---|---|---:|---:|---:|---:|---:|
| 2 slots | ordinary | 14.1 ms | - | - | 2 | 7.0 |
| 2 slots | native | 27.8 ms | 11.6 ms | 2.2 ms | 3.7 | 11.2 |
| 8 slots | ordinary | 25.3 ms | - | - | 8 | 3.2 |
| 8 slots | native | 51.0 ms | 31.5 ms | 8.5 ms | 14.1 | 6.4 |

Projected ceiling with every identified fix: about 1.3x at 2 slots and about
break-even at 8 slots. At 8 busy rows the A3B is largely compute-bound, so
depth-1 MTP does not raise saturated-node throughput. Eligibility is also near
zero for current traffic: v0.1 is greedy-only and requires the whole prompt to
fit one 512-token prefill chunk (`ModelRuntime.nativeMTPFullPromptPrefillTokenLimit`).

## What this branch contains

- Lab-only round profiling (`NativeMTPRoundProfile.swift`, `MACPROVIDER_NATIVE_MTP_PROFILE=1`)
  and `native-mtp-bench --ordinary-self-check`.
- Batched drafter integration behind `MACPROVIDER_MLX_PACKED_DRAFTER`, needing the
  fork branch `Augustas11/mlx-swift-lm` `perf/mtp-packed-drafter` (packed
  stateful-drafter API; `fork-batched-drafter.diff`). Compiled on the Studio;
  parity and throughput were NOT measured (run stopped at operator request).
- Proposed SPEC-048 R005 amendment (0.1.12) tolerating bounded bf16 batch-kernel
  drift. NOT adopted. Root cause: MLX `get_qmv_batch_limit` switches qmv→qmm at
  packed M>=12 on M3 Ultra for K/N>4096; Qwen3.5-9B was bit-exact at 5 slots
  (M=10) and drifted at 6 slots (M=12), all divergences at margins <=0.25.

## Revisit when

- A latency or low-concurrency tier is wanted (MTP's value on this hardware), or
- depth > 1 plus speculative sampling (temperature > 0) and chunked-prefill
  hidden-state capture are scoped as SPEC-048 v0.2, or
- an upstream mlx-swift-lm tag ships packed stateful drafting.
