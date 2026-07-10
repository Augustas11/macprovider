---
role: code-audit
version: 1.0
date: 2026-07-02
target_pr: v1.7.6 default-tier fallthrough + swap tolerance (Track A1 + A2a)
lens: CODE — correctness, edge cases, coding errors
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# CODE audit — SPEC-023 v1.7.6 default-tier fallthrough + swap tolerance

You are a code-review specialist. Independently audit this change for
correctness bugs and coding errors. Report findings CRITICAL / HIGH /
MEDIUM / LOW / INFO with file:line references and a concrete defect
scenario. Do not speculate — findings must reproduce on the current diff.

## Context

macprovider-cli v1.7.5 closed one drop-out mode (probe timeout fix
in Stage1Iterator + `.infeasible(reason:)` persistence). A follow-up
M5 32GB fresh-install QA on 2026-07-02 revealed a second, larger
drop-out mode: **provider hardware that CAN run a model, gets told
"donor mode only" and drops out.**

Two root causes:
1. **`RateCardProjection.rowForRecommendation`** refused to return
   the "default" row for arbitrary model keys. Client would decline
   to recommend a probe-feasible model without a specific rate-card
   entry. But **coord's `RateFor` at
   `phase4-coordinator/internal/billing/formula.go:52`** already
   falls through to "default" when no specific row exists — meaning
   the coord will pay for served inference on ANY model. Client's
   veto was purely defensive and produced the drop-out cliff.
2. **`isEligible` and `donorModeCompatible`** hard-blocked any
   benchmark with `swapDetected == true`. On the M5 32GB, all 3
   probe-feasible candidates (llama-3.1-8b, gpt-oss-20b,
   qwen3-coder-30b-a3b) triggered swap under a 4000-token probe.
   Every one was eligible-by-TPS/TTFT but blocked. Real production
   demand doesn't always hit 4K context — hard-blocking on swap
   under a synthetic worst-case probe was too aggressive.

## The change (Track A1 + A2a bundled)

### A1 — Rate-card default-row fallthrough

At [`AutotuneRecommend.swift`](phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift)
`rowForRecommendation`:
- If exact match, return it.
- If normalized-key match (and normalized != "default"), return it.
- Otherwise, fall through to `rows["default"]` if present.
- Otherwise nil.

New warning `AutotuneRecommendWarning.rateCardDefaultTierUsed` = `rate_card_default_tier_used`
is inserted at scoring time when the resolved row's key is "default"
but the model isn't literally "default".

### A2a — Swap tolerance + `swapObservedUnderLoad` warning

`isEligible` (paid) and `donorModeCompatible` (donor) drop the
`!benchmark.swapDetected` guard. `!benchmark.thermalThrottleDetected`
stays a hard-block because thermal-throttled TPS readings are
unreliable (they may be optimistic vs cold-start production).

New warning `AutotuneRecommendWarning.swapObservedUnderLoad` = `swap_observed_under_load`
is inserted at scoring time when any recommended candidate's
benchmark has swap detected.

### Version bump

`CoordinatorClient.binaryVersion`: `1.7.5` → `1.7.6`. Test assertion
strings updated.

## Tests added

- `testRateCardFallsThroughToDefaultForArbitraryModelKey`
- `testRateCardReturnsNilWhenNoDefaultAndNoMatch`
- `testRateCardPrefersSpecificRowOverDefault`
- `testRecommendationEmitsRateCardDefaultTierWarningWhenSpecificRowMissing`
- `testRecommendationNoDefaultTierWarningWhenSpecificRowPresent`
- `testSwapDetectedNoLongerBlocksEligibilityButEmitsWarning`
- `testThermalThrottleStillHardBlocksEligibility`
- `testDonorModeInheritsSwapRelaxation`
- `testDonorModeStillRejectsThermalThrottle`

Prior test `testNoCoordinatorDefaultFallbackUnlessCandidateKeyIsDefault`
was INVERTED (it encoded the pre-v1.7.6 behavior) — the new tests above
cover the new v1.7.6 contract.

Full suite: **791/791 pass** (was 781, +10 net: 8 new + 3 renamed - 1
inverted).

## What to audit

1. **`rowForRecommendation` correctness** — is the fallthrough order
   correct? Any way an arbitrary key can bypass a normalized-key
   match and hit the default? Any way the default row is returned
   when the caller expects a specific-row miss?
2. **Warning insertion sites** — is `rateCardDefaultTierUsed` only
   inserted when a *recommended* candidate uses default (vs. when
   any candidate is scored against default)? Same for
   `swapObservedUnderLoad`. Consider whether the warning should fire
   only for candidates in the top-scored set vs. every scored candidate.
3. **Eligibility guard changes** — is the swap gate correctly removed
   from BOTH `isEligible` and `donorModeCompatible`? Is thermal still
   correctly hard-blocked?
4. **Donor-mode integration** — with `donorModeCompatible` relaxed on
   swap, do the M5-32GB donor-mode scenarios still land correctly?
5. **Determinism / ordering** — the `warnings` set uses `Set<T>` +
   `.map(\.rawValue).sorted()` — should be deterministic. Confirm the
   new raw values don't introduce ordering surprises.
6. **Regressions on existing tests** — any test that relied on the
   old "no fallthrough" behavior implicitly? Search for callers of
   `rowForRecommendation` in tests.

## Files to read

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift`
- `phase4-coordinator/internal/billing/formula.go` (for RateFor
  reference — no changes here, just confirm client/coord align)

## Reply format

```
## CODE audit — v1.7.6

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
