# Issue #127 r3 — SECURITY-lane closure audit

You are the **security** lane of the r3 closure audit for issue #127.
r2 graded the reserved-marker regex still permissive (NOT READY TO
MERGE) — it would silence the unused-constant check on a doc comment
containing "NOT RESERVED" because space satisfied both word
boundaries. r3 tightens the marker to require start-of-line anchoring.
Stay narrowly in your lane.

## r2 finding → r3 fix

- **r2 L1** (Reserved-marker regex still broader than the standalone-
  token convention): regex changed to
  `(?m)^\s*(?:[*-]\s+)?(FORWARD-COMPAT|RESERVED)(\W|$)`. New
  `TestReservedMarkerRE` pins must-reserve vs must-NOT-reserve sets.
  Doc updated in implementation-notes.md.

## Files in scope (`git diff origin/main` for r3 delta only)

- `phase7-verify/internal/verify/enum_drift_test.go` — regex
  constant + doc comment + new pinned-contract test.
- `phase7-verify/internal/verify/implementation-notes.md` — updated
  "Reserved-reason convention" section.

## Security verification ask

1. Does the new regex close the r2 L1 gap? Test each of these by
   eye:
   - `NOT RESERVED` (line-start "NOT" before marker) — must reject.
   - `DEFINITELY NOT-RESERVED and not FORWARD-COMPATIBLE.` —
     must reject.
   - `// NOT FORWARD-COMPAT yet` — must reject.
   - `FORWARD-COMPAT v0.3+: ...` (live verify.go form) — must accept.
   - `RESERVED (do not delete)` — must accept.
   - `* RESERVED *` (list-marker bullet) — must accept.
   - `\n  - RESERVED for SPEC-016` (indented bullet on second line)
     — must accept (multi-line mode).
2. Are there ways an attacker (or accidental contributor) could
   smuggle the marker past the regex? Consider:
   - Mixed-case `Reserved` (lowercase fragment) — should fail.
   - Marker on a CONTINUATION line of a single comment, after
     leading prose — `// Note: this is\nFORWARD-COMPAT: ...`. The
     `(?m)` flag should accept this. Is that intended?
3. Does the doc in implementation-notes.md accurately describe the
   semantics?

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

Write to `specs/127_ENUM_AST_SECURITY_R3_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM AND r2 L1 is closed, end with:
`VERDICT: security lane r3 READY TO MERGE`
