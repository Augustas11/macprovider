You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine
resolution admin surface) for CODE-correctness concerns, ROUND 3.

# Repository context

- `specs/SPEC-005-billing.md` on branch `spec/005-v0-4-quarantine-resolution`,
  commit `c54e834`.
- R3 — R2 produced findings; R2 fix-pass is in the current commit.
  Verify R2 findings closed AND look for NEW defects.
- R2 CODE findings:
  - C2-H1: Missing-operator auth status contradiction
  - C2-H2: UNIQUE error mapping named a non-unique index
  - C2-H3: §11.3 response example missed `rows_force_resolved_in_range`
  - C2-H4: Settlement-sweep INSERT OR settle (should be sequential)
  - C2-M1: §4.10 still described `operator_id` as free-form
  - C2-M2: Reader predicates falsely called "exhaustive"
  - C2-M3: AC-Q045 seeded 3 rows but asserted 4

# Audit scope (CODE lens)

Same scope as R1/R2 — schema correctness, endpoint contract
correctness, audit payload completeness, reader-side widening,
concurrency, cross-spec consistency, AC coverage.

ALSO: any defect INTRODUCED by the R2 fix-pass — e.g. the new
route-layer-config flag, the SPEC-016 503 gate, the
`operator_attribution` payload field, the new ACs Q053/Q054.

# Severity

- **CRITICAL** = SPEC defect that would corrupt the ledger / cause
  double-credit / cause silent money loss.
- **HIGH** = SPEC defect that would force IMPL ambiguity / cause
  test failures / produce non-deterministic behavior.
- **MEDIUM** = clarity gap.
- **LOW** = wording.

# Output

```
[SEVERITY] <short title>

Location: <§ anchor or line range>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

If an R2 finding is closed, do NOT re-list. Audit the R3 text AS
WRITTEN.
