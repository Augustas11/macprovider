# AUDIT — ISS-211 R4 — SECURITY lens

## Task

R4 security re-audit. R3 returned ZERO FINDINGS. R4 deltas are
limited to:
- hotpath.go branchless `IS ?` rewrite (alignment, not new logic).
- SPEC-002 / SPEC-005 wording updates to NULL-with-NULL clustering.

Branch: `spec/iss-211-coordinator-account-scope`.

## What to audit

1. Does the hotpath.go change open any new attack surface? The
   query is parameterized; the `nil` binding goes to a bound
   parameter, not an SQL string. Verify no string interpolation.
2. Does the IS-clustering for NULL rows enable a downgrade attack
   where an attacker who can suppress `X-MacProvider-Account` on
   the gateway hot path turns the unscoped-fallback into a
   NULL-with-NULL bucket — does that change the money-safety
   guarantee? (Pre-R4: NULL fell into "all rows with this
   request_id" bucket → over-count → ambiguous_attempt_n
   zero-credit. Post-R4: NULL falls into "all NULL-account rows
   with this request_id" bucket → smaller count → less likely to
   over-count, but still safe.)

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
