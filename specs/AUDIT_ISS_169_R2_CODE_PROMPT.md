You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine
resolution admin surface) for CODE-correctness concerns, ROUND 2.

# Repository context

- This is `specs/SPEC-005-billing.md` in repo `Augustas11/macprovider`
  (branch `spec/005-v0-4-quarantine-resolution`, commit `b8afc03`).
- This is R2 — R1 produced findings documented in
  `specs/SPEC-005-v0-4-r1-audit.md`. The fix-pass is in the current
  draft. Verify the fixes ACTUALLY CLOSE the R1 CODE findings AND
  look for any NEW defects introduced by the fix-pass.
- The R1 CODE findings to verify-as-closed:
  - C-H1: 200 vs 409 response shapes contradict
  - C-H2: Audit-insert cannot satisfy same-transaction requirement
  - C-H3: UNIQUE race vs 404/422 preconditions
  - C-H4: Reader-side filter table SQL / column-name drift
  - C-H5: §11.3 reconcile aggregation not widened
  - C-M1: Endpoint validation has reachable unspecified responses
  - C-M2: Schema CHECKs don't capture endpoint sanitization rules
  - C-M3: AC-Q040..Q046 leave normative clauses unpinned

# Audit scope (CODE lens)

Same scope as R1 — schema correctness, endpoint contract
correctness, audit payload completeness, reader-side widening,
concurrency, cross-spec consistency, AC coverage.

ALSO: any defect INTRODUCED by the R1 fix-pass — e.g. the new
SQL fragments compiling, the new response code table being
exhaustive, the new ACs being properly deterministic and
fixture-runnable.

# Severity vocabulary

- **CRITICAL** = SPEC defect that would corrupt the ledger / cause
  double-credit / cause silent money loss.
- **HIGH** = SPEC defect that would force IMPL ambiguity / cause
  test failures / produce non-deterministic behavior.
- **MEDIUM** = clarity gap that risks IMPL drift but does not force
  a wrong outcome.
- **LOW** = wording, redundancy, minor inconsistency.

# Output

Plain text. For each finding:

```
[SEVERITY] <short title>

Location: <§ anchor or line range>
Concern: <what is wrong>
Evidence: <quote the offending text>
Fix: <one-sentence proposed change>
```

End with a tally line: `Tally: <C>/<H>/<M>/<L>`.

If no findings: `Tally: 0/0/0/0 ACCEPT`.

If an R1 finding is now closed, do NOT re-list it; only list NEW
issues OR issues NOT actually closed by the fix-pass.

Do NOT propose new features. Audit the v0.4 R2 text AS WRITTEN.
