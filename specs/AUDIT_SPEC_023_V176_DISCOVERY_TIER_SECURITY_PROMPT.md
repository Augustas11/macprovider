---
role: security-audit
version: 1.0
date: 2026-07-02
target_pr: v1.7.6 default-tier fallthrough + swap tolerance (Track A1 + A2a)
lens: SECURITY — trust, integrity, economic exploit, DoS
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# SECURITY audit — SPEC-023 v1.7.6 discovery-tier + swap tolerance

You are a security-review specialist. Audit this change for
security-relevant defects: trust-boundary crossings, data integrity,
economic exploitation, DoS surface expansion.

## Context

v1.7.6 changes two eligibility gates in autotune-recommend:

1. **Rate-card default fallthrough** — `rowForRecommendation` now
   returns the `default` row when no specific row matches.
2. **Swap tolerance** — `isEligible` and `donorModeCompatible`
   no longer hard-block on `benchmark.swapDetected`. Instead a
   `swap_observed_under_load` warning is inserted at scoring time.
   Thermal throttle remains a hard-block.

Both changes are **client-side** (macprovider-cli autotune-recommend
scoring). Coord-side rate-card enforcement is unchanged — coord's
`RateFor` already had the default-fallback semantics; client is
now aligning with it.

## Security-relevant surfaces

### 1. Money-path economic exposure

The default row on Pearl is currently:
- `prompt_rate_per_mtok`: 500,000 credits (= $0.50/M at $1/M credits)
- `completion_rate_per_mtok`: 1,000,000 credits (= $1.00/M)
- `provider_share_bps`: 9000 (90%)
- `global_multiplier_ppm`: 1,000,000

Coord will pay this rate for served inference of any model. Consider:

- Can a provider game the recommend flow to serve an *arbitrary*
  model against `default` pricing and extract disproportionate
  credits (vs. what a specific-row rate would allow)?
- Coord's `RateFor` fallback is authoritative for BILLING — client-side
  recommend only affects WHICH model to install. Billing side is
  unchanged. Confirm the concern is about install-time economic
  guidance, not runtime billing manipulation.
- Is there a case where the default row's rates are much HIGHER than
  a specific row (i.e., the coord accidentally over-pays)? Look at
  current Pearl values and compare.

### 2. Model-catalog trust

`rowForRecommendation` fallthrough only applies when the model is IN
the signed candidate catalog (`request.candidateCatalog.rows[modelKey]`
is checked at scoring time — see `recommend()`). Confirm attacker
cannot inject an unauthorized model into the recommend flow via the
default fallthrough.

### 3. Swap-tolerance eligibility

`swapDetected` in `benchmark` is a local telemetry signal from
`ProbeSafetyAssessment.assess`. Malicious tampering would require
local compromise. Confirm this is the right threat model.

But: could a provider deliberately trigger `swapDetected` (e.g., by
loading random memory before autotune) to skip a specific eligibility
path? Under v1.7.5 this would DE-CREDIT the candidate; under v1.7.6
it only inserts a warning. Is there a scenario where the provider
BENEFITS from the swap gate being relaxed?

### 4. Thermal-throttle asymmetry

Swap is relaxed; thermal-throttle stays hard-blocked. The two flags
have different threat/utility profiles. Confirm this asymmetry is
correct:
- Swap: probe measures under memory pressure → but production may
  not hit swap → soft signal.
- Thermal: probe measures under throttling → TPS reading may be
  optimistic → hard block correct.

### 5. Warning trust boundary

`rateCardDefaultTierUsed` and `swapObservedUnderLoad` warnings are
inserted at scoring time and surface to the operator via `humanTranscript`
+ persisted `probe_diagnostics`. Any way an attacker can suppress
these warnings by manipulating candidate catalog or rate-card content?

## Non-goals to explicitly ignore

- Ed25519 signing correctness of static feeds (unchanged in v1.7.6)
- HTTP/S transport security (unchanged)
- Notary/signing (unchanged)

## Files to read

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
  (esp. `rowForRecommendation`, `recommend()`, `isEligible`,
  `donorModeCompatible`)
- `phase4-coordinator/internal/billing/formula.go` (RateFor and
  its callers — is the client change consistent with coord's
  authoritative billing path?)

## Reply format

```
## SECURITY audit — v1.7.6

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

Reject speculative "harden by also doing X" without an attack scenario.
