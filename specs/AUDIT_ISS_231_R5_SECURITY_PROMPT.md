# Audit: ISS-231 R5 security lens — final convergence

R4 returned 0/0/1/0 (sec). R5 verifies on `322696c`.

## R4 sec finding

- **MEDIUM (deferred to #246)**: detail-fetch helpers use
  optional-predicate that SQLite plans as SCAN. Deferred as a
  perf-follow-up because the affected path is operator-only +
  auth-gated; the ambiguity probe (the actual #231 surface) AND
  the scoped-path use the new indexes correctly. v0.4 change-log
  links #246.

Expect 0/0/0/N if the deferral is accepted. Look for ANY remaining
in-scope defect.

End with `## Convergence X/X/X/X → DECISION`.
