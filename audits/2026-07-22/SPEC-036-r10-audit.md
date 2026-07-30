# SPEC-036 — Round-10 codex verification + total truth table

**Date:** 2026-07-23 · **Reviewed revision:** `21980179`

## Round-10 result (codex; Claude lanes ACCEPTED since R6/R7)

| Lane | C | H | M |
|---|---:|---:|---:|
| codex code | 0 | 1 | 4 |
| codex security | 0 | 1 | 1 |
| codex architect | 0 | 0 | 3 |

The architect lane reached 0 HIGH. The single shared HIGH (code+security) was one
completeness gap: the mode×origin truth table omitted the `SPEC-036 observe × SPEC-022
enforce` combination, and downstream consumers (FR-10/11/16/Migration) didn't all
explicitly gate on the predicate.

## Fixes
- **Total truth table:** the table now covers SPEC-036 `{enforce, warn_only, observe}`
  × SPEC-022 {enforce, not} (warn_only and observe grouped identically as non-enforce);
  an explicit statement requires every downstream consumer to gate on the
  `effective_adverse_state` predicate; the telemetry→enforce re-adjudication path is
  defined (fresh enforce-mode evidence = new enforce_preserved adjudication).
- **Breaker reason precedence:** the breaker reason applies only when no
  higher-precedence non-payable condition matches (drift/blocks outrank it).
- **FR-16 rollback scoped to the predicate** (provider-attributable + breaker survive;
  coordinator-attributable dormant).
- **Exhaustive measurement-validation precedence** + `inconclusive:model_swap` and
  `inconclusive:coordinator_reference_fault` in the FR-9 closed enum.
- **Measured-FP ground truth:** defined against a maintainer-adjudicated known-good
  calibration cohort (`known_good_cohort_digest`); observable would-quarantine rate,
  not a proof of honest computation.
- **Self-contained coordinator audit-signing profile** (Ed25519, `signing_key_id`,
  versioned directory, rotation overlap, historical retention, revocation).
- **K=256 retry binding** to the same K=64 attempt (`retry_of_probe_id`, same key/
  positions/reference digests).

## Convergence
Both money-path adversarial and product-design lanes ACCEPTED (0 C/H/M) since R6/R7;
codex converged 18H→1H, the last HIGH being a table-completeness gap now closed. Any
residual after the round-11 confirmation is carried as a documented MEDIUM/LOW with
maintainer sign-off per repo audit discipline (no unbounded re-cycling).
