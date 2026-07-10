# Issue #127 r2 — CODE-lane closure audit

You are the **code** lane of the r2 closure audit for issue #127. r1
returned 2 MEDIUM findings + 1 LOW. Each has been addressed; this r2
audit verifies the fixes only. Stay narrowly in your lane.

## r1 findings → r2 fixes

- **r1 M1** (AST silently ignores reason consts without explicit literal
  values): now returns an error if `i >= len(vs.Values)` OR
  `vs.Values[i]` is not a `*ast.BasicLit` of `token.STRING`. New table
  cases `reason constant without explicit value` and `reason constant
  with non-string-literal value` exercise both branches.
- **r1 M2** (Duplicate Go reason values collapse before bijection
  check): the `expected` map build now checks for prior entry and
  returns `"reason constants X and Y both declare wire value %q;
  values must be unique"`. New table case `two go constants with the
  same wire value` exercises it.
- **r1 L1** (Reserved-marker substring match accepts negated prose
  like "NOT RESERVED"): replaced `strings.Contains` with a compiled
  regex `reservedMarkerRE` that matches FORWARD-COMPAT/RESERVED only
  as standalone tokens (non-alphanumeric boundary on each side). New
  table case `negated reserved-marker prose still flags unused
  constant` confirms `// DEFINITELY NOT-RESERVED and not
  FORWARD-COMPATIBLE.` does NOT count as reserved.

## Files in scope (`git diff origin/main` for r2)

- `phase7-verify/internal/verify/enum_drift_test.go` — added M1 error
  returns, M2 dup check, L1 regex helper, 4 new table cases.

## Verification ask

Read the r1 audit findings at `specs/127_ENUM_AST_CODE_audit.md` and
the current `enum_drift_test.go`. For each r1 finding, confirm the
fix is correct and the new table case actually exercises the failure
mode (would have failed before the fix).

Are there NEW issues introduced by the r2 deltas? Specifically:
- The regex `(^|[^A-Z0-9_-])(FORWARD-COMPAT|RESERVED)([^A-Z0-9_-]|$)` —
  any corner case where intended reserved markers fail to match?
- Returning early from the const-walk loop (rather than skipping)
  changes a previously-soft skip into a hard error. Confirm this is
  the desired semantic.
- The dup-value error names the prior constant — Go map iteration
  order is non-deterministic, so the "prior" name will be whichever
  the iteration saw first. Is this a flaky error message? (It does
  fail the test the same way either order, but the message text
  differs.)

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/127_ENUM_AST_CODE_R2_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM AND all three r1 findings are resolved, end
with: `VERDICT: code lane r2 READY TO MERGE`
