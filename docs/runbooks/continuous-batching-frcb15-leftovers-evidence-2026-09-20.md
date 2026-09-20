# FR-CB15 leftovers — Studio evidence, 2026-09-20

Harness: `msb-throughput --scenario leftovers|msb03|msb05` on the compiled
scheduler path (`decodeLockstepWindow`). Buyer `continuous_batching` stayed
**off**. Live v1.8.170 slots stayed at 4. Do not canary 170.

JSON: [`data/cb-frcb15-leftovers-2026-09-20/`](data/cb-frcb15-leftovers-2026-09-20/).
Local artifact paths were replaced with the catalog model id before check-in.

MoE promotion review (flag stays false):
[`continuous-batching-moe-promotion-review-2026-09-20.md`](continuous-batching-moe-promotion-review-2026-09-20.md).

## Header

- **Date:** 2026-09-20
- **Operator:** augstar
- **Provider id:** non-production test drive; no coordinator join, no buyer traffic, no receipts
- **Binary:** `feat/spec038-frcb15-leftovers` built on-box (Swift release), run from `run/` co-located with candidate v1.8.170 `mlx.metallib`
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1, AC power
- **Live serve:** v1.8.170 `live.malibu.provider` stayed up on port 8080
- **Model:** `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`

## Results

| Leftover | Result | Notes |
| --- | --- | --- |
| Usage / receipt attribution | **pass** | Four ragged rows: distinct request IDs, `prompt_tokens` 512/1024/1536/2048, `completion_tokens` 256 each, `cached_prompt_tokens` 0, `eligible_owner`. Isolation: cancelled row `not_eligible` / 0 completion; healthy row `eligible_owner` / 32. |
| MSB-03 ragged | **pass 1.73×** | 512/1024/1536/2048 prompts, 256 decode, 3 runs. Aggregate 188.5 tok/s vs serial 108.9 tok/s. Short-row p95 TTFT 1.06× its serial baseline (gate ≤2×). Peak RSS 33.0 GB. |
| MSB-05 Q1 native parallel | **0.81×** (documented) | Two concurrent `generate()` streams, 1024/256, 3 runs. Aggregate 85.9 tok/s vs serial 106.4 tok/s. `ModelContainer` serializes; this is why shared-forward CB exists. |
| MSB-05 Q2 oMLX oracle | **unavailable** | No pinned oMLX v0.4.4 `BatchGenerator` sidecar on this host. Not faked. |
| Temp-0 exact token match | **fail at index 9** | 32 greedy tokens, 1-row scheduler vs serial `generate()`, and both batched rows vs their own serial. First divergence index 9. This is FR-CB6 accumulation-order / compiled-graph numeric tolerance, not cross-row leak (usage IDs stay distinct; isolation cancel did not contaminate the healthy row). |
| Failure isolation | **pass** | Cancel `msb-cancel` after first token (window=1); cancelled `completion_tokens=0`, healthy finished length 32. Unit fixtures remain: `testAC3CancellationIsIdempotentAndLeavesHealthyRowRunning`, `testAC17AC24MidDecodeAllocatorExtensionFailureFailsOnlyThatRowAndReleasesBlocks`, `testAC11BatchForwardFailureCleansEveryParticipatingRow`. |
| Warm-swap / drain | **pass (scheduler drain)** | Two active rows completed `length` / `eligible_owner` / 32 tokens; queued `rejected`; drain permit issued and valid; post-drain submit rejected. Did **not** swap live 170 weights. Model-hash receipt parity stays on unit fixtures (`HTTPServerReceiptTests`, `ModelRuntimeSwapTests`, `testAC10DrainTimeoutFailsClosedAndLeavesOldWorkOnItsSnapshot`). |
| Durable replay | **pass (local harness)** | Same request ID: first `eligible_owner`, replay `non_settling_replay`, tokens match. The in-process `ContinuousBatchRuntimeReplayAuthority` stub is still **not** packaged-RC activation evidence. |

## What this does not enable

Packaged RC, buyer canary, slot raise, and `moePromotionEvidenceAvailable=true`
on production `ModelRuntime` stay out. MSB-02/04 already passed on the
scheduler lockstep window (1.44× / 1.94×). MSB-03 now passes too. Native
serial-parallel does not scale. Exact greedy token identity vs `generate()`
is not bit-identical under the compiled lockstep graph; record the SHA pair
and do not treat that miss as a cross-request leak.

## Secrets redaction check

Harness JSON is token counts, tokens/sec, RSS, scenario flags, and usage
field integers. Checked-in files use the catalog model id, not the on-box
snapshot path.
