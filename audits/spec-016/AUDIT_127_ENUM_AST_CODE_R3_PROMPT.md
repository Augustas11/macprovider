# Issue #127 r3 — CODE-lane closure audit

You are the **code** lane of the r3 closure audit for issue #127. r2
returned 0 CRITICAL/HIGH/MEDIUM + 1 LOW: the reserved-marker regex
matched `NOT RESERVED` because space satisfied both word boundaries.
Fixed in r3 by anchoring the marker to start-of-line. Stay narrowly
in your lane.

## r2 finding → r3 fix

- **r2 L1** (NOT RESERVED still matches): the regex changed from
  `(^|[^A-Z0-9_-])(FORWARD-COMPAT|RESERVED)([^A-Z0-9_-]|$)` (word-
  boundary anywhere) to
  `(?m)^\s*(?:[*-]\s+)?(FORWARD-COMPAT|RESERVED)(\W|$)` (start-of-
  line, optional list-marker prefix). New `TestReservedMarkerRE`
  pins the contract: must-reserve set (FORWARD-COMPAT v0.3+:, RESERVED
  (do not delete), * RESERVED *, - RESERVED for SPEC-016, FORWARD-COMPAT:
  pending v0.4, two-line "context\nRESERVED ...") and must-NOT-reserve
  set (NOT RESERVED, DEFINITELY NOT-RESERVED ..., NOT FORWARD-COMPAT
  yet, "may someday be RESERVED", "intentionally UNRESERVED", "this
  RESERVED-LIKE thing", empty string).

## Files in scope (`git diff origin/main` for r3 delta only)

- `phase7-verify/internal/verify/enum_drift_test.go`:
  - `reservedMarkerRE` constant rewritten with multi-line anchor.
  - Doc comment on the constant explains accepted/rejected forms.
  - New `TestReservedMarkerRE` test (6+7 cases).
  - Existing drift table case `negated reserved-marker prose still
    flags unused constant` now also covers a leading-prose `NOT
    RESERVED` line.
- `phase7-verify/internal/verify/implementation-notes.md`:
  - "Reserved-reason convention" section updated to match the
    tightened semantics; calls out `TestReservedMarkerRE` as the
    pinned-contract test.

## Verification ask

1. Confirm the new regex correctly accepts the live verify.go form
   `// FORWARD-COMPAT v0.3+: reserved enum value.` (the doc comment
   on `reasonBundlePubkeyProviderMismatch`). Note `go/ast`'s
   `CommentGroup.Text()` strips the `//` markers.
2. Confirm the new regex rejects all the `mustNotReserve` cases in
   `TestReservedMarkerRE`.
3. Are there any remaining marker grammar bypasses? E.g.
   - Trailing-line markers like a one-line block `/* RESERVED */`?
   - Tab-only leading whitespace? (`\s` includes tabs.)
   - Unicode whitespace? (`\s` in Go RE2 is ASCII whitespace by
     default.)
4. Does the doc comment on `reservedMarkerRE` accurately describe
   the regex semantics?

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

Write to `specs/127_ENUM_AST_CODE_R3_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM AND the r2 L1 is closed, end with:
`VERDICT: code lane r3 READY TO MERGE`
