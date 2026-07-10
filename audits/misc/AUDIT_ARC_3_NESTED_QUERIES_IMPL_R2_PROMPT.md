# ARC-3 nested-query unwind IMPL Audit Prompt — Round 2 (closure verification)

You are an IMPL auditor running ROUND 2 on the phase4-coordinator
nested-cursor refactor for issue #21 / ARCH-3. Round 1 produced
`specs/ARC_3_NESTED_QUERIES_IMPL_audit.md` with 0 CRITICAL / 0 HIGH /
1 MEDIUM / 0 LOW / 0 QUESTIONS. The author has fixed the finding. Your
job is **closure verification**, not a fresh audit:

1. State PASS / PARTIAL / FAIL on the M1 finding based on the current
   branch state.
2. Re-audit fresh — surface any NEW issue the fix introduced.

## Branch / commit
- Branch: `fix/arc-3-nested-queries`
- Worktree: `../macprovider-arc-3-nested-queries`
- Read: `git diff origin/main -- phase4-coordinator/`

## Round-1 finding to verify closure on

- **M1.** `buyerEquivalentCredits` no longer preserves the 503
  skip-before-parse behavior — a malformed ts on a 503 row was ignored
  on origin/main but turned into a hard error in r1 of this refactor.
  - Evidence: `phase4-coordinator/internal/billing/endpoints.go:319`
    (r1).
  - Fix expected: move the 503 filter ahead of `time.Parse`, OR carry
    the raw ts text through the first pass and parse only when the
    row will contribute to the credit total.

## Audit lenses for fresh issues (apply briefly)

- Does the new second-pass-parse correctly bubble parse errors only
  for non-503 rows? (Original behavior: parse errors on non-503 rows
  → hard error; parse errors on 503 rows → silently skipped.)
- Did the rename `ts` → `tsText` in the scratch struct miss any
  consumer that still expects a parsed `time.Time`?
- Any other 503-implicit-filter assumption elsewhere in
  `buyerEquivalentCredits` that the refactor disturbed?
- Spot-check the three OTHER refactored sites (rebuildLegacy-
  ConfigSnapshots, providers handler, RecoverLedger/snapshotAtTx) for
  drift introduced by the r1→r2 patch.

## Output format

```
CLOSURE on round-1 findings:
  M1: PASS|PARTIAL|FAIL — <one line>

NEW FINDINGS (round 2):
CRITICAL (N):
  ...
HIGH (N):
  ...
MEDIUM (N):
  ...
LOW (N):
  ...
QUESTIONS (N):
  ...
```

Use CRITICAL/HIGH/MEDIUM/LOW severity. Write the report to
`specs/ARC_3_NESTED_QUERIES_IMPL_r2_audit.md`.

If M1 closes AND zero NEW CRITICAL/HIGH/MEDIUM, end the report with:
`VERDICT: READY TO MERGE arc-3 nested-query unwind`
