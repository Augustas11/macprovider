# AUDIT — ISS-211 R7 — SECURITY lens

## Task

R7 security re-audit. R6 surfaced 2 MEDIUMs that have now been
addressed (SPEC-002 §1403 + changelog line 42).

Branch: `spec/iss-211-coordinator-account-scope`.

## R7 deltas

- `specs/SPEC-002-coordinator.md` §11 FR-B9 paragraph + v1.5.0
  changelog bullet 1 both clarified that internal `request_id`
  is server-minted and doesn't naturally collide across
  accounts; account scoping is defense-in-depth.
- Code comments in hotpath.go / recovery.go / endpoints.go
  reworded to the same framing.

## What to audit

1. Any residual SPEC or code claim that an attacker can engineer
   coordinator-internal `request_id` collisions as a real
   attack surface?
2. Is the defense-in-depth framing strong enough that a future
   reader would not accidentally remove the scoping under the
   reasoning "we don't need this because internal request_ids
   don't collide"?
3. Any new attack surface from the R7 wording changes?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM. Each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: ...
SUGGESTED FIX: <minimal>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

## Out of scope

- SPEC-007 §1591 (deferred to PR #221).
