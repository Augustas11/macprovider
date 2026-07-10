# Cold/warm TTFT — calibration methodology & the three P2 deliverables

This document defines how the accumulated matrix (`--build-matrix`) becomes the
three P2 outputs. It is the **method**; the actual numbers land once the store has
enough samples (`sample_n >= COLDWARM_MIN_SAMPLES`, default 30, per cell). The
harness computes the recommendations mechanically (`recommendations` / `slo` in
the matrix JSON) so the calibration PR is a transcription, not a judgement call.

## The regime rule (non-negotiable)

- Calibrate `max_ttft_ms` against the **`canary_nonstream` warm** cell **only**.
  That is the exact regime the coordinator gate is evaluated against
  (`canary_probe.go` → `canaryMetricsFromTiming`, non-streaming → TTFT = full
  round-trip). **Never** calibrate the gate off `buyer_stream` TTFT — doing that
  is precisely what caused the 2026-07-09 ban-storm.
- Use the **`buyer_stream` cold** cell for the buyer-UX SLO — that is the number a
  real buyer feels on a cold first request.

## Deliverable 1 — calibrated `max_ttft_ms` per model class

**Formula (implemented in `recommendGates`):**

```
recommended_max_ttft_ms = ceil( canary_nonstream.warm.p99 × COLDWARM_HEADROOM / 500 ) × 500
```

with `COLDWARM_HEADROOM = 1.5` by default, rounded up to the nearest 500 ms.

**Gate on sufficiency:** a recommendation is only marked `enforce_ready: true`
when the warm `canary_nonstream` cell has `sample_n >= COLDWARM_MIN_SAMPLES`.
Below that the harness explicitly says *keep `max_ttft_ms >= 7000` and
`canary_latency_enforcement: observe`* — the current safe state.

**Return-to-enforce decision, per class.** A class may flip to `enforce` only if
**all** hold:
1. `enforce_ready: true` (enough warm samples).
2. The warm `canary_nonstream` p99 is **stable** across ≥ several days of the
   store (compare `first_seen` vs `last_seen` windows; no widening tail).
3. `canary_cold_start_grace_s` is sized to cover the worst cold load (Deliverable
   2's grace number) — otherwise a legitimate cold (re)connect trips the gate
   inside the grace window.

If any fails, the class stays in `observe`. **This is per-class**: the 30B may
stay observe (huge cold tail) while a small model with a tight warm envelope
returns to enforce.

**The PR this produces (audit-gated).** Editing `pool.model_class_challenges` /
`canary_latency_enforcement` is a security sanction gate (money-path-adjacent).
The change ships as a PR to:
- `phase4-coordinator/coordinator.opoi-v0-staging.yaml` (staging overlay), and
- the Pearl runtime overlay `coordinator.pearl-overlays.yaml` (the live source of
  truth — currently `max_ttft_ms: 7000, min_sustained_tps: 20`, grace 300 s,
  enforcement unset → `observe`),

through a **three-lane codex audit** (code / security / architect via
`omc ask codex`) to **0 CRITICAL / 0 HIGH / 0 MEDIUM** before merge, authored as
Augustas11. **Do not** hand-edit gate values from intuition — transcribe the
`enforce_ready` recommendation.

> **`min_sustained_tps` caveat.** The non-streaming `sustained_tps` metric is
> structurally unreliable (live: 17k–33k tok/s for a warm 30B, because it's
> `completion_tokens / total_round_trip` on a 16-token response). The harness
> records it but **does not** recommend a `min_sustained_tps` value. Leave it at
> the current advisory floor (20) and rely on the buyer-side decode-TPS signal
> from **P1** for real throughput regression detection.

## Deliverable 2 — idle-prewarm policy (measured)

The prod mac provider CLI runs with `--no-idle-prewarm`, so every (re)connect
cold-loads the 30B (~30–60 s of buyer unavailability). Prewarm telemetry exists
(commit `ed2f782`).

**The measured case (from the matrix):**
- `buyer_cold_minus_warm_p50_ms` = `buyer_stream.cold.p50 − buyer_stream.warm.p50`
  — the latency a real first request pays for a cold load. This is the cost
  idle-prewarm would hide.
- `canary_nonstream.cold.p99` and `.post_reboot.p99` — the worst cold load, which
  also sets the `canary_cold_start_grace_s` recommendation
  (`recommended_cold_start_grace_s = ceil(worst_cold_s × 1.25 / 10) × 10`).

**Recommendation framework** (fill from the accumulated deltas):
- **Enable idle-prewarm** if the cold→warm buyer delta is large (order tens of
  seconds — as observed) **and** connect/idle-evict churn is frequent enough that
  buyers routinely hit cold. The delta is the buyer-unavailability window prewarm
  removes.
- **Idle threshold:** set the prewarm trigger below the model-unload threshold so
  the model is re-warmed before the next buyer arrives, but high enough to avoid
  needless reloads on a busy provider. Derive from the observed inter-request gap
  distribution on the lab provider.
- **Battery guard:** on laptop providers, gate idle-prewarm on AC power (or a
  battery-level floor) so prewarm doesn't drain an unplugged Mac. Prewarm holding
  a 30B resident is a real power/thermal cost — off-AC should skip it.

## Deliverable 3 — buyer-UX cold-start SLO

From `buyer_stream.cold`:
- **`cold_start_ttft_p99_ms`** — the worst-case first-request TTFT a buyer sees.
  This is the stated cold-start ceiling the product can publish and monitor.
- Emitted as `macprovider_coldwarm_cold_start_ttft_p99_ms{model}`; alert when a
  live cold-start (correlate P1's `macprovider_canary_ttft_ms` spikes on
  provider reconnect) exceeds it.
- `sufficient_samples` flags whether the p99 rests on ≥ `COLDWARM_MIN_SAMPLES`
  cold cycles; don't publish an SLO off a thin sample.

## Current runtime baseline (Pearl, verified 2026-07-10)

- Live gate (`coordinator.pearl-overlays.yaml`): 30B `max_ttft_ms: 7000`,
  `min_sustained_tps: 20`; `canary_cold_start_grace_s: 300`; `canary_interval_s:
  45`; `canary_latency_enforcement` **unset → observe** (safe default).
- Observe-mode breach tail (24h, non-streaming regime): p50 ≈ 7.1 s, **p95 ≈ 65
  s, p99 ≈ 93 s, max ≈ 108 s**; `sustained_tps` reads 17k–33k (garbage). The warm
  *passing* envelope is not in the logs — the harness supplies it.
- Autotune per-model bench gates to reconcile against (streaming-side targets,
  `AutotuneRecommend.swift`): 30B `max_4k_ttft_ms: 3500`, gpt-oss-20b `2500`,
  qwen3-32b `4000`. These are **streaming** TTFT ceilings — related to the
  `buyer_stream` regime, **not** the `canary_nonstream` gate. Keep the two
  regimes' numbers distinct.

## Do-not-block rule

Per the P2 operating model: **do not block on merging the harness PR while it is
still accumulating data.** The harness (this directory) merges first as test-only
tooling; the calibration PR (Deliverable 1) follows once cells reach
`enforce_ready`, and it is the audit-gated one.
