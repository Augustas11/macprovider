# Issue #127 r2 — SECURITY-lane closure audit

You are the **security** lane of the r2 closure audit for issue #127.
r1 returned 0 CRITICAL/HIGH/MEDIUM and 4 LOWs; LOWs L1–L3 (which the
code lane graded MEDIUM) are addressed in r2. Stay narrowly in your
lane.

## r1 security findings → r2 fixes

- **r1 L1** (Duplicate Go reason string values can collapse): fixed
  via dup detection on the `expected` map build (also graded
  code-lane M2).
- **r1 L2** (Non-literal `reasonXxx` constants silently ignored):
  fixed via explicit `*ast.BasicLit`/string-kind check (also graded
  code-lane M1).
- **r1 L3** (Reserved-marker substring match): replaced with a
  compiled regex that requires non-alphanumeric boundaries on both
  sides of FORWARD-COMPAT/RESERVED.
- **r1 L4** (Schema reader tied to 3-branch `oneOf` layout):
  accepted — the test fails loudly if a future schema revision moves
  reason values to a different combinator, prompting explicit test
  update.

## Files in scope (`git diff origin/main` for r2)

- `phase7-verify/internal/verify/enum_drift_test.go` — see r1
  delta description in `specs/AUDIT_127_ENUM_AST_CODE_R2_PROMPT.md`.
- `phase7-verify/internal/verify/implementation-notes.md` — new
  "Reserved-reason convention" subsection documenting the
  FORWARD-COMPAT/RESERVED marker convention for future contributors.

## Security verification ask

1. Confirm each r1 fix actually closes the drift surface it claimed
   to close. The original concern was the test design's gap, NOT a
   live security incident.
2. Word-boundary regex: does it match what a future contributor
   would naturally write? E.g. `// FORWARD-COMPAT v0.3+: ...`,
   `// RESERVED (do not delete)`, `* RESERVED *` at column 0. Any
   intended marker form that the regex would reject?
3. The implementation-notes.md doc: does it accurately describe
   what the test enforces, or could the prose drift from the code?
4. Are there any drift modes still uncaught? Trace.

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

Write to `specs/127_ENUM_AST_SECURITY_R2_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM AND each r1 LOW is either closed or
explicitly accepted, end with: `VERDICT: security lane r2 READY TO
MERGE`
