# SPEC-036 — Round-12 codex confirmation (4 of 5 lanes CLEAN)

**Date:** 2026-07-23 · **Reviewed revision:** `cc626684`

| Lane | C | H | M |
|---|---:|---:|---:|
| claude adversarial | 0 | 0 | 0 (ACCEPT, R6/R7) |
| claude product-design | 0 | 0 | 0 (ACCEPT, R7) |
| codex security | 0 | 0 | 0 (CLEAN, R11) |
| codex architect | 0 | 0 | 0 (CLEAN, R12) |
| codex code | 0 | 0 | 4 (R12) |

Four of five lanes are at 0 C/H/M. The codex code lane's four residual MEDIUMs were
one real spec fix (the inherited four-prompt cap was not enforced in the closed
request schema) plus three AC-coverage completeness items.

## Fixes (round 12)
- Enforced the four-distinct-prompt / eight-position bound in the closed request
  schema; added it (plus `retry_of_probe_id` and the measurement-validation
  precedence) to AC-3.
- AC-10: added the SPEC-022-subordination, measured-FP, hardware-class, TTL, and named
  stable-device/operator-identity-authority activation-refusal fixtures.
- AC-13: made table-driven over the full FR-3 `effective_adverse_state` matrix
  (all three SPEC-036 modes incl. `observe`, both SPEC-022 states, both origins, all
  attribution classes, and the telemetry→enforce re-adjudication path).
- AC-16: made table-driven over every FR-3 mapping table + precedence-collision fixtures.

Per the "don't re-run passed lanes" rule, only the codex code lane is re-run next.
