---
role: architect-audit
version: 1.0
date: 2026-07-02
target_pr: v1.7.6 default-tier fallthrough + swap tolerance (Track A1 + A2a)
lens: ARCHITECTURE — layering, contracts, evolution
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# ARCHITECT audit — SPEC-023 v1.7.6 discovery-tier + swap tolerance

You are an architecture-review specialist. Audit for structural
issues, contract stability, and blast-radius concerns.

## Context

v1.7.6 fixes a "provider drops out after install" cliff by:

1. **A1 — Rate-card default fallthrough** at
   `RateCardProjection.rowForRecommendation`. Aligns client-side
   scoring with coord-side `RateFor` fallback semantics
   (`phase4-coordinator/internal/billing/formula.go:52`).
2. **A2a — Swap tolerance** by dropping `!benchmark.swapDetected`
   from `isEligible` and `donorModeCompatible`. Emits a
   `swap_observed_under_load` warning instead.

Bundled: new `rateCardDefaultTierUsed` warning surfaces when the
default row is used for a recommended candidate.

## What to audit

### 1. Client / coord contract alignment

Client `rowForRecommendation` now mirrors coord `RateFor` fallback
behavior. Confirm:
- Both fall through to the same key (`"default"`).
- Both handle namespace-normalized keys the same way.
- Neither returns a "fake" row when the underlying data is missing.
- Any evolution path where these two would diverge (e.g., if coord
  ships a new fallback tier like "discovery-tier"), does the client
  need parallel updates or is it decoupled?

### 2. Rate-card row schema stability

The rate-card v1 schema documents `rows: Map<String, Row>` with an
implicit `"default"` sentinel. Confirm:
- SPEC-023 (or upstream rate-card spec) records `"default"` as a
  reserved key
- Any Mac operator running v1.7.5 who upgrades to v1.7.6 gets the
  new behavior automatically (no config migration)

### 3. Warning enum evolution

Two new cases added to `AutotuneRecommendWarning`. Consider:
- Persistence: warnings appear in `AutotuneRecommendResult` (in-memory
  only via `humanTranscript`). Are they also persisted anywhere that
  would need schema migration?
- Downstream consumers of `warnings.rawValue.sorted()` — anyone
  parsing this string list who would break on unknown values? Grep
  for consumers.
- Warning names: `rate_card_default_tier_used`,
  `swap_observed_under_load` — do they collide with existing warnings
  or future-planned ones?

### 4. Eligibility-gate philosophy

The gate is now:
- swap: soft
- thermal: hard
- TPS/TTFT under-gate: hard
- RAM/tier under-gate: hard

Is this the right split? Should thermal ALSO be relaxed (with warning)
in future? What's the general principle for soft vs. hard?

### 5. Interaction with v1.7.5 diagnostics

v1.7.5 introduced `probe_diagnostics` (modelKey → reason string) for
`.infeasible` results and pre-probe gate rejections. v1.7.6 relaxes
the swap gate — a swap-detected candidate is now `.feasible` and
eligible, but the v1.7.5 diagnostics loop ALSO records `"feasible but
swap detected"` (see `benchmarks()` in AutotuneRecommend.swift). Confirm:
- Both the warning and the diagnostic co-exist coherently
- User sees consistent signal in `humanTranscript` and
  `last-recommendation.json`

### 6. SPEC-023 document alignment

`specs/SPEC-023-installer-autotune-recommend.md` is locked at v0.1.
This PR adds two new warnings and changes eligibility semantics.
Does SPEC-023 need a v0.2 note recording:
- Default-row fallthrough as a normative behavior?
- Swap-detected as a soft-signal (with warning) rather than hard-block?

## Files to read

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
- `phase4-coordinator/internal/billing/formula.go`
- `specs/SPEC-023-installer-autotune-recommend.md`
- `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift`

## Reply format

```
## ARCHITECT audit — v1.7.6

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

Findings must cite file:line and describe a concrete future scenario.
