# Issue #127 r3 — ARCHITECT-lane closure audit

You are the **architect** lane of the r3 closure audit for issue
#127. r2 verdict was READY TO MERGE (0/0/0/0). r3's only delta is
tightening the reserved-marker regex and updating the doc comment —
no architectural surface changes. Stay narrowly in your lane.

## r3 deltas vs r2

- Regex grammar tightened: substring/word-boundary → start-of-line
  with optional list-marker prefix.
- New `TestReservedMarkerRE` pins the must-reserve vs must-NOT-
  reserve cases.
- "Reserved-reason convention" doc updated to match the tightened
  semantics.

## Architect verification ask

1. Does the r3 delta affect the architectural single-source-of-truth
   boundary you blessed in r2? (Probably no — the marker is still a
   doc-comment opt-out signal, just with a stricter grammar.)
2. Is the doc-comment grammar choice (line-leading marker) the right
   convention to formalize for future contributors? It matches how
   Go conventionally writes annotation tags (`// TODO:`, `// FIXME:`,
   `// Deprecated:`) — all line-leading.
3. Anything in the r3 doc change that overpromises or under-specifies
   the convention?

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

Write to `specs/127_ENUM_AST_ARCHITECT_R3_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with: `VERDICT: architect lane r3
READY TO MERGE`
