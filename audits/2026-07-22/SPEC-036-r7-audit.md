# SPEC-036 — Round-7 SPEC audit (5 lanes) + warn_only sweep

**Date:** 2026-07-22 · **Reviewed revision:** `299419aa`

## Round-7 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| codex code | 0 | 2 | 2 | 0 |
| codex security | 0 | 1 | 0 | 0 |
| codex architect | 0 | 1 | 2 | 0 |
| claude adversarial | 0 | 0 | 0 | 0 (ACCEPT, no regression) |
| claude product-design | 0 | 0 | 0 | 1 (ACCEPT) |

**Both Claude lanes CLEARED the 0 C/H/M bar.** The adversarial lane re-verified every
R6 edit as fail-closed-tightening (and noted R6 had closed a manual-rollback fail-safe
gap it had missed at R6). Product converged 7H/5M→0H/0M across R3–R7.

The codex HIGHs were one coherent "sweep both sides" residual: the R6 warn_only
Preserved-adverse-state exception landed in §3+FR-16 but not in the parallel
restatements (FR-1, FR-11, FR-15, Migration, AC-7/AC-13), plus schema-completeness
items (hardware-class result echo, all-profile digest in FR-4, threshold-record field
schema + measured-FP).

## Fixes
- Swept the warn_only clean-key / preserved-adverse-state qualifier through FR-1,
  FR-11, FR-15, and the FR-16 breaker-effect paragraph; scoped the preserved set to
  provider-attributable state + breaker holds (coordinator-attributable blocks go
  dormant during an availability downgrade); AC-13 extended to prove manual+auto
  downgrade keep adjudicated quarantines/breaker holds money-blocking.
- Added `hardware_runtime_class` to the FR-6 result identity echoes (reject on mismatch).
- Added `covered_sampling_profile_set_digest` to the FR-4 closed capture.
- Replaced FR-8 threshold-record prose labels with exact closed JSON keys and added the
  measured-false-quarantine evidence fields the FR-8 enforce gate requires.
- Swept the ≥10-identity hard floor (removed "when available") through §6.1 and §8 dec 4.

## Convergence
Both money-path adversarial and product-design lanes at 0 C/H/M; codex residual was a
mechanical sweep now applied. Round-8 codex-only verification confirms.
