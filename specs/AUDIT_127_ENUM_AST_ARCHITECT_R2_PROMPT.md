# Issue #127 r2 — ARCHITECT-lane closure audit

You are the **architect** lane of the r2 closure audit for issue
#127. r1 returned 0 CRITICAL/HIGH/MEDIUM and 1 LOW (document the
FORWARD-COMPAT/RESERVED convention outside the test). Stay narrowly
in your lane.

## r1 architect finding → r2 fix

- **r1 L1** (Reserved-marker convention should be documented outside
  the test): added a new "Reserved-reason convention" subsection at
  the end of the existing "Reasons" section in
  `phase7-verify/internal/verify/implementation-notes.md`. The
  section describes:
  - WHO uses the marker (`TestReasonEnumBijection` AST walker)
  - WHAT triggers it (declared but never referenced in non-test
    source)
  - WHICH tokens it recognizes (FORWARD-COMPAT, RESERVED)
  - HOW it matches (standalone tokens, not substring match)

## Files in scope (`git diff origin/main` for r2)

- `phase7-verify/internal/verify/enum_drift_test.go` — see r1
  code/security delta described in
  `specs/AUDIT_127_ENUM_AST_CODE_R2_PROMPT.md`.
- `phase7-verify/internal/verify/implementation-notes.md` — new
  "Reserved-reason convention" subsection.

## Architect verification ask

1. Is the implementation-notes addition at the right location
   (under "Reasons" rather than "Warning Merge Strategy" or
   elsewhere)?
2. Does it overpromise — for instance by suggesting the marker
   convention extends to warnings or result types? The r1 audit
   explicitly said "defer any extension to warnings/result
   constants to a separate PR." Confirm the doc respects that
   scope.
3. The PR is still test-only + one doc paragraph. Is the
   single-source-of-truth boundary unchanged from r1 (Go consts ↔
   schema; SPEC remains human-maintained authority)?
4. Closing #127 as the last v1.0.1-followup-labeled issue — worth
   calling out in the PR body? (Same r1 question.)

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

Write to `specs/127_ENUM_AST_ARCHITECT_R2_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM AND the implementation-notes addition is
architecturally sound, end with: `VERDICT: architect lane r2 READY
TO MERGE`
