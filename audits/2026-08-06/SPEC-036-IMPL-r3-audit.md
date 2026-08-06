# SPEC-036 IMPL — Round-3 BUILD audit (3 codex lanes) + fixes

**Date:** 2026-08-06

## Round-3 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| codex code-correctness | 0 | 1 | 3 | 0 |
| codex security / money-path | 0 | 1 | 0 | 0 |
| codex architecture / spec-fidelity | 0 | 0 | 3 | 1 |

Convergence trend: R1 (3C / 9H) → R2 (0C / 13H) → **R3 (0C / 2H / 6M / 1L)**. Two
rounds with zero CRITICAL; HIGH collapsing. All lanes reconfirmed the architecture and
the round-1/2 fixes.

## Fixes (all C/H/M addressed)

1. **Malformed composite SPEC-022 binding paid through** (code-H1): `Evaluate` now runs
   `Capture.compositeBindingUnreadable` BEFORE the not-enforce early return — a capture
   with a missing binding fails closed `compute_integrity_unreadable` instead of being
   mistaken for a legitimate SPEC-022-not-enforcing row.
2. **Payable with incomplete reference quorum** (sec-H1): `missingEnforceEvidence` now
   requires the admissibility digest, fault-check version, `ReferenceQuorumCount >= 2`,
   `len(ReferenceEventDigests) >= quorum`, and no empty digests — a two-reference
   independent quorum must be provable before payout.
3. **Tombstones stored as bare booleans** (code-M1): tombstones now store the
   adjudication origin and are gated through `EffectiveAdverseState`; a telemetry-only
   lineage tombstone is dormant and never blocks onboarding/routing.
4. **Calibration FP evidence not range-checked** (code-M2): reject non-finite/negative
   numerator, rate, budget, and tail-mass feasibility outside [0,1]; numerator ≤ denom.
5. **Reference distributions not validated before fault** (code-M3): reference
   distributions are checked (finite probs in [0,1], total mass ≤ 1, top-K dedup/subset)
   before the fault comparison — an impossible distribution is `schema_invalid`, never
   silently clamped to admissible TV 0.
6. **Enforce activation permitted an empty policy** (arch-M1): `ActivationCheck` now
   requires all FR-1 load-bearing coverage/identity fields and exactly one of
   target_model_hash / signed_catalog_selector; the AC-10 positive fixture populates a
   real covered policy.
7. **Flapping had no lookback/audit semantics** (arch-M2): `FlappingCanary` carries
   id+timestamp, `EvaluateFlapping` filters to `lookback_window_days` of now, and
   `FlappingEvidence` records contributing canary ids (+ approver/clear evidence fields).
8. **Breaker transition-set/boundary not in the settlement digest** (arch-M3): the fixed
   in-scope transition set and `activates_at_or_above` boundary are bound into
   `Policy.Digest`.

## Carried LOW (documented)

- **arch-L1** `overlayState.quarantineCandWindow` is an unpruned counter (ancient
  sub-threshold risk can still contribute to swap-laundering escalation). This
  **over-blocks, never mis-pays**, and enforce is not reachable in v0.1. Carried as a
  documented LOW; a rolling-window prune (timestamps like the abusive/onboarding
  accumulators) is the follow-up.

Added tests: composite-binding + incomplete-reference-evidence fail-closed, empty/dual
selector policy refusal, flapping stale-canary lookback + evidence ids, calibration
range checks.

## Post-fix state

`go build ./...`, `go vet`, `golangci-lint` green; all 17 AC fixtures pass. Round-4
verification recorded separately.
