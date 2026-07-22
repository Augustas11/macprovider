# SPEC-036 — Round-9 codex verification + matrix correction

**Date:** 2026-07-22 · **Reviewed revision:** `3fa7936a`

## Round-9 result (codex; Claude lanes converged at R7)

| Lane | C | H | M |
|---|---:|---:|---:|
| codex code | 0 | 1 | 6 |
| codex security | 0 | 2 | 0 |
| codex architect | 0 | 2 | 3 |

All lanes converged on one real bug I introduced in R8: the mode×origin matrix's
"effect active IFF provider-attributable/breaker" predicate wrongly made
coordinator-attributable blocks (`reference_missing`/`calibration_missing`/
`reference_fault`) dormant even under NORMAL enforce — a fail-open (a reference-missing
key could pay). Plus successor-origin inheritance, measurement-validation ordering, and
the recurring multi-arm-support framing.

## Fixes
- **Corrected the matrix to an exhaustive truth table** (`effective_adverse_state`
  predicate used by FR-3/FR-4/FR-10/FR-11/FR-16/Migration): under normal enforce (both
  SPEC-036 and SPEC-022 enforce) EVERY non-payable state fails closed
  (provider- AND coordinator-attributable); a SPEC-036-only downgrade keeps
  provider-attributable/breaker active while coordinator-attributable go dormant
  (availability); a SPEC-022 downgrade makes all dormant (no independent authority);
  telemetry_only never blocks. The origin/mode gating governs only downgrades, never a
  relaxation of normal-enforce fail-closed.
- **Successor-origin inheritance:** any successor overlay / swap-laundering block /
  lineage tombstone derived from `enforce_preserved` risk inherits `enforce_preserved`
  regardless of derivation-time mode (closes the warn_only-churn laundering path).
- **Measurement-validation precedence** (ordered: auth/replay → model_swap →
  position_mismatch → malformed → tail/k_retry) + added `inconclusive:model_swap` to the
  FR-9 coordinator enum (non-abusive).
- **Pairwise `[K,2K]` TV:** each provider-vs-reference TV uses SPEC-030 §FR-7's two-arm
  construction unchanged; only the wire carries the bounded union of pairwise supports.

## Convergence
The truth table is exhaustive over mode × origin × attribution; the pairwise reframe
uses the pinned SPEC-030 primitive. Round-10 confirms; both Claude money-path/product
lanes stand at 0 C/H/M (ACCEPT) since R6/R7.
