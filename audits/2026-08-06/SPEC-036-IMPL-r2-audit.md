# SPEC-036 IMPL — Round-2 BUILD audit (3 codex lanes) + fixes

**Date:** 2026-08-06
**Reviewed:** full IMPL diff after round-1 fixes.

## Round-2 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| codex code-correctness | 0 | 8 | 1 | 0 |
| codex security / money-path | 0 | 2 | 0 | 0 |
| codex architecture / spec-fidelity | 0 | 3 | 1 | 0 |

Severity fell sharply from round 1 (which had 3 CRITICAL): **0 CRITICAL** in round 2.
All lanes reconfirmed the round-1 key-algebra fixes are correct and the architecture is
sound. The round-2 findings are deeper money-path refinements and spec-fidelity of
digest preimages — the audit converging on precision, not looping.

## Fixes (all C/H/M addressed; consolidated across the three lanes)

1. **Malformed captures could pay** (code-H1, sec-H1): added `Capture.structurallyUnreadable`
   (unknown state/origin/admissibility/coverage-mode enum, inconsistent breaker, adverse
   state with missing origin) run BEFORE the mode branch — fails closed
   `compute_integrity_unreadable` in EVERY mode when SPEC-022 enforces; and
   `Capture.missingEnforceEvidence` (policy/coverage digests, reference set id/digests,
   covered sampler stage) gating the enforce payable path. Added `Mode.Known()`,
   `State.Known()`, `AdjudicationOrigin.Known()`, `SamplingProfileCoverageMode.Known()`.
2. **State consumers bypassed effective_adverse_state** (code-H2, sec-H2, arch-H3):
   `ResolveState` now returns the adjudication origin and gates overlay/swap returns
   through `EffectiveAdverseState` (a dormant telemetry-only overlay persists but falls
   through to positive-state recomputation, never blocking routing). Onboarding gates
   `InheritedOverlay` the same way. `RecordCanary` stamps the risk origin so swap blocks
   inherit it; swap escalation no longer launders telemetry → enforce_preserved.
3. **Clear rule too weak** (code-H3): the pass streak resets on ANY non-pass canary, and
   `AttemptClear` now requires current fresh admissible reference evidence.
4. **Zero-quorum admission** (code-H4): `ComputeAdmissibility` fails closed when
   `MinQuorum < 2` or `FreshnessTTLMillis <= 0`.
5. **Reference fault compared by slice index** (code-H5): positions are now aligned by
   `(prompt_id, position_index)` before pairwise TV.
6. **K=64 retry median not per-reference** (code-H6): `RequiresK256Retry` evaluates the
   median predicates per reference so one reference cannot be masked by a flat median.
7. **Enabled flapping had no implementation** (code-H7): added `flapping.go` — the FR-10
   flapping trigger (per-canary margins, median/position metrics, count conjunction,
   action, both clear-rule variants) + `Store.ApplyFlapping`, with AC-4 numeric fixtures.
8. **Calibration validation too weak** (code-H8): validates the full 8-tuple against the
   covered key, enforces the FR-8 threshold floors, and rejects non-finite/negative values.
9. **Non-normative digest preimages** (code-M1, arch-H2): `PositionSetDigest` and
   `CoveredProfileSetDigest` now digest the raw canonical sorted arrays (no wrapper).
10. **Capture snapshot preimage used Go field names** (arch-H1): added snake_case JSON
    tags to the `Capture` FR-4 object (settlement-verification-only fields excluded).
11. **Incomplete FR-6 validation** (arch-M1): `ValidateMeasurementPosition` validates
    provider top-K ordering by probability (token-id tie-break); `ValidateRequestBounds`
    rejects negative `position_index` (plus nonce-length/expiry/K256-retry from round 1).

Added tests: AC-4 flapping (numeric fixtures, both metrics, action, clear-rule variants),
AC-1 8-tuple mismatch + floor refusal, AC-3 per-reference K-retry, cross-provider window
isolation, telemetry-origin dormancy, reference covered-key/position-set binding.

## Post-fix state

`go build ./...`, `go vet`, `golangci-lint` green; all 17 AC fixtures pass. Round-3
re-audit recorded separately.
