# #584 physical per-tier floors and thermal/memory baseline matrix

Companion to Partial #584 (PR #690 liveness split + FR-CAN22 floor) and the
FR-CAN23 correlation package (`phase4-coordinator/internal/canarycorr`).

This document does **not** authorize Pearl canary re-enable. It defines the
evidence matrix operators must collect before any go/no-go.

Issue: https://github.com/Augustas11/macprovider/issues/584  
Normative bar: `specs/SPEC-031-canary-degrade-sanctions.md` §16  
Buyer path: `test/e2e/canary-buyer/` (qualification is ops-only, isolated)

## Hardware tiers (collect separately)

| Tier code | Hardware class | Memory | Primary models (examples) | Notes |
|-----------|----------------|--------|---------------------------|-------|
| T-M1-8 | Apple M1 | 8 GB | Llama 3.2 3B (4bit class) | Incident host class (2026-07-13 collapse) |
| T-M2-16 | Apple M2 / M2 Pro | 16 GB | 7–8B class | Optional if fleet has none |
| T-M-series-high | M-series | ≥32 GB | Qwen3-Coder-30B-A3B 4bit, Qwen3-8B | Pearl Air class |
| T-other | other Apple Silicon | as deployed | fleet actuals only | Do not invent hosts |

Do not use generic “15 tok/s” as a cross-tier floor. Each cell needs its own
approved raw baseline with provenance.

## Per-model / per-tier floor record (required fields)

For every (tier, model) pair that qualification or liveness will gate:

| Field | Requirement |
|-------|-------------|
| `model_id` | Exact catalog / serving model id |
| `hardware_tier` | From table above |
| `cli_version` + `compatibility_set_id` | Signed set identity under test |
| `sample_size` | ≥30 successful qualification samples unless waived in Decision Log |
| `cold_ttft_p50/p95` | Cold process / cold model load |
| `warm_ttft_p50/p95` | Warm weights already resident |
| `tok_s_p50/p95` | Sustained decode under the qualification token budget |
| `variance_notes` | stdev or IQR; reject if unstable |
| `floor_tok_s` | Approved gate: typically ≤ p50 × 0.7 with safety margin; never above measured p50 |
| `thermal_state` | idle / warm / sustained; skin or `powermetrics` summary if available |
| `power_source` | `ac` or `battery` (both required for portable Macs) |
| `memory_pressure` | free RAM, jetsam/pressure level before and after |
| `rss_growth_mb` | provider RSS delta across the run; compare to `CANARY_MAX_MEMORY_GROWTH_MB` |
| `artifact_path` | Operator-local path; no secrets in GitHub comments |
| `approver` + UTC | Signed acceptance of the floor numbers |

## Thermal / memory notes (how to collect)

1. **Idle baseline (5 min):** no canary, provider Ready, record RSS + thermal sample.
2. **Warm qualification (isolated, non-routable target):** one attempt only; hard
   request/token/time budgets from Partial #690; no retry.
3. **Sustained cell (bounded):** repeat qualification cadence for an operator-approved
   window (default ≤15 min wall). Abort on adaptive observer trip; never amplify.
4. **Thermal pressure cell:** run after sustained cell while CPU/GPU are warm; record
   whether tok/s remains above `floor_tok_s` and heartbeats stay fresh.
5. **Memory pressure cell:** note competing apps only if representative; do not
   deliberately OOM production providers. Prefer a spare Mac.
6. **AC vs battery (portables):** duplicate warm cell on each power source.
7. **Stream / heartbeat fault injection:** only on isolated non-Pearl targets;
   prove adaptive abort + recovery soak without pool emptying (FR-CAN22).

## Multi-provider correlation (FR-CAN23) — when the matrix needs ≥2

Before enabling coordinator canary sanctions on a model with ≥2 Ready providers:

- Hermetic FR-CAN23 package tests must be green
  (`go test ./internal/canarycorr/`).
- Live wiring Partial must be merged (this design package alone is not enough).
- Floor residual: peers that lift capacity must show **observed-serving** evidence
  (recent buyer-relay success), not only request-independent routability.
- Physical: a shared bad challenge must produce discard + operator alert with
  **zero** durable containment (no automatic bank rollback / fingerprint suspend).

## Cadence gate (operating day)

After floors exist, one normal operating day of **liveness-only** scheduled runs
(still behind approval) must show:

- stable heartbeats;
- no disconnect / restart / drain attributed to canary load;
- expected Ready pool after every recovery soak;
- zero automatic full-probe retries.

## Emergency-disable gate

Complete `ops/runbooks/584-emergency-disable-drill.md` on Pearl with retained
artifacts before any timer flip.

## Closure order (do not reorder)

1. Hermetic software Partials (liveness split, FR-CAN22, FR-CAN23 package) — code
2. Physical baseline matrix (this file) — ops
3. Pearl emergency-disable drill — ops
4. Independent signed go/no-go — ops
5. Separately reviewed timer + enable-gate change — ops
6. Only then consider `pool.canary_enabled=true` under SPEC-031 §16

## Explicit non-goals

- Enabling Pearl canary from this document
- Using Pearl as the thermal/memory fault-injection host without approval
- Closing #540 (AEAD) or #585 (updater) from canary baselines
- Clearing `exc-canary-disabled-enable-gate` without the full list above
