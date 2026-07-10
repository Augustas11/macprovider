---
role: security-audit
version: 1.0
date: 2026-07-03
target_pr: v1.7.9 soft-signal TPS + TTFT eligibility gates (Track A5)
lens: SECURITY
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# SECURITY audit — v1.7.9 soft TPS + TTFT gates

Audit for security-relevant defects on the current diff.

## Context

v1.7.9 relaxes two eligibility gates in
`AutotuneRecommendEngine.isEligible` and
`donorModeCompatible`:
- `benchmark.sustainedTPS >= min_sustained_tps` → soft signal
- `benchmark.ttftMS <= max_4k_ttft_ms` → soft signal

Thermal throttle remains a hard block. The real financial gate
(`expected_net_usd_per_hour >= $0.005/hr`) is unchanged; it's
applied post-selection in `recommend()`.

This is a CLIENT-side install-time recommendation change. Runtime
billing is unchanged; coord's `RateFor` still authoritatively prices
each session.

## Security-relevant surfaces

### 1. Economic exploitation via inflated eligibility

Provider could try to serve under-nominal-quality inference and
still get recommended. Consider:
- Buyers get slower-than-catalog TPS from the provider. Is there
  a channel by which the buyer OR the coord penalizes this at
  billing time? (Coord bills per-token, not per-second, so provider
  earns proportionally less — no financial harm to network.)
- Reputation impact — do buyers observe "this provider is slow"
  and gradient away? Depends on demand-rank feedback.
- Does the `tps_below_gate` warning surface to any billing/routing
  system that would reprice? (No — warning is client-side only.)

### 2. Thermal-throttle asymmetry

Thermal throttle stays hard-block, TPS/TTFT go soft. Is this the
right split? Argument for:
- Thermal-throttled TPS is unreliable — could rebound in production
  and confuse routing.
- TPS/TTFT below gate is a REAL, stable measurement — routing can
  trust it and price accordingly.

Confirm this reasoning holds under adversarial scenarios (e.g. a
provider that oscillates in and out of thermal throttle to game
the eligibility window).

### 3. donor mode inheritance

`donorModeCompatible` also drops TPS/TTFT checks. Any candidate
that would have been rejected for donor mode is now admitted. Is
there any adversarial case where a rogue provider abuses donor
mode with grossly under-spec hardware? Donor mode pays no credits,
so no financial exploit.

### 4. Warning as trust signal

`tps_below_gate` / `ttft_above_gate` warnings surface via
`.warnings` array and stderr output. Not persisted to
`last-recommendation.json` (that carries `probe_diagnostics`
separately). Could an attacker suppress these warnings by
tampering with the catalog SHA (already checked upstream via
signature verify)?

## Files to read

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
  (esp. `AutotuneRecommendWarning`, `isEligible`,
  `donorModeCompatible`, warning-attach loop in `recommend()`)

## Reply format

```
## SECURITY audit — v1.7.9

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
