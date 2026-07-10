---
role: architect-audit
version: 1.0
date: 2026-07-03
target_pr: v1.7.9 soft-signal TPS + TTFT eligibility gates (Track A5)
lens: ARCHITECTURE
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# ARCHITECT audit — v1.7.9 soft TPS + TTFT gates

## Context

v1.7.9 relaxes TPS + TTFT catalog gates from hard-block to soft-signal.
Follows the v1.7.6 A2a pattern for swap. The financial gate
(`expected_net_usd_per_hour >= $0.005/hr paidThreshold`) is
unchanged.

Motivation: on M5 32GB Tier C, v1.7.8 measured qwen3-coder-30b-a3b at
23.4 TPS (vs 25 gate) — the candidate earns $0.0178/hr net (above
threshold) but was blocked by a catalog gate calibrated for larger
hardware. The user's directive: "we cannot accept situations where
32gb mac is not eligible."

Alternative was to lower the catalog `min_sustained_tps` values, but
the autotune-static-v2 private key isn't in the repo, so a catalog
re-sign wasn't possible this session. Ships now, defers a proper
catalog re-sign (with lower gates) to a follow-up.

## What to audit

### 1. Consistency with the A2a/A1 relaxation pattern

Now four eligibility gates are soft-signals: swap, rate-card-default,
tps, ttft. Only thermal + hard structural gates (RAM, tier,
runtime_status, demand.recommendable, signed benchmark admission)
remain hard. Is this the right split? What's the general principle?

Principle claim: soft = "provider-quality trade-off surfaced to
operator"; hard = "either catalog admission or physical
impossibility." Confirm this frames the split correctly.

### 2. What does `min_sustained_tps` mean now?

Semantically, `catalog.rows.<key>.bench_gate.min_sustained_tps` was
originally "required warm-service TPS floor". Post-v1.7.9 it's
"advisory — below this you get a warning." Should:
- SPEC-023 update the field description to soft-signal semantics?
- The field name change from `min_sustained_tps` to
  `target_sustained_tps`? (Semantic drift makes it easy to
  misinterpret later.)
- Add a companion field like `hard_min_sustained_tps` if the network
  ever wants a hard floor again?

### 3. Buyer QoS contract implications

Buyers may assume "if the network recommends a provider for model X,
they meet catalog QoS gates." That's no longer true. Consider:
- Is any buyer-side documentation making this assumption?
- Does the gateway (buyer-facing) need to expose TPS warnings?
- Rate-card-in-use identifies the tier the buyer pays for — soft-TPS
  gate silently degrades that tier's actual delivery.

### 4. Follow-up: catalog re-sign

The user explicitly asked for the private key to end up in the repo.
Task #39 tracks that. Once re-signed with lower gates, `.tpsBelowGate`
and `.ttftAboveGate` warnings should rarely fire. But they'll be
kept as safety nets. Confirm this evolution path makes sense.

### 5. Test extremes

`testDonorModeInheritsTPSAndTTFTRelaxation` uses TPS=1, TTFT=100_000ms.
A realistic donor should still probably be filtered by some sanity
gate (e.g. TPS < 0.5 = probably a broken provider). Is this test's
extreme case actually the right behavior, or does it argue for a
minimum-viable-TPS floor even in soft-signal mode?

## Files to read

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
- `specs/SPEC-023-installer-autotune-recommend.md`
- `phase3-binary/dist/static/autotune-candidates.json`

## Reply format

```
## ARCHITECT audit — v1.7.9

CRITICAL: <count>
HIGH: <count>
MEDIUM: <count>
LOW: <count>
INFO: <count>

### CRITICAL
[if none: "None."]
### HIGH
### MEDIUM
### LOW
### INFO
### Verdict
```
