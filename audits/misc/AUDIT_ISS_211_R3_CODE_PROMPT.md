# AUDIT — ISS-211 R3 — CODE lens

## Task

R3 re-audit of issue #211 SPEC + IMPL bundle. R2 surfaced 1 MEDIUM
on the code lens that has now been addressed.

Branch: `spec/iss-211-coordinator-account-scope`.

## R3 deltas (relative to R2)

- `phase4-coordinator/internal/billing/endpoints.go:302-318`:
  `buyerEquivalentCredits` `prior`-attempt subquery now scopes by
  `prior.account_id IS rl.account_id AND prior.request_id = rl.request_id`
  using SQLite `IS` (preserves legacy NULL-cluster behavior).
- `specs/SPEC-005-billing.md`: version bump v0.3 → v0.3.1, SPEC-002
  dependency bumped to v1.5.0, SPEC-006 to v0.9.1; §4.2 and §8.2
  fallback attempt-ordinal grouping text scoped by
  `(account_id, request_id)` with legacy NULL-account_id fallback.
- `specs/SPEC-006-buyer-api.md`: cross-PR pointer to SPEC-007 §6.4
  softened to merge-order-safe wording mirroring SPEC-002.

## What to audit

1. Does the endpoints.go R3 fix produce the same legacy-NULL
   semantics as hotpath.go and recovery.go did? (Sanity-check the
   SQLite `IS` invariant.)
2. Are there any remaining `request_log` scans in
   `phase4-coordinator/internal/` (excluding the documented
   explorer deferral) that still use unscoped `request_id`?
3. Does SPEC-005 v0.3.1's "Until then, derive the fallback ordinal
   by sorting rows with the same `(account_id, request_id)`" text
   accurately reflect what hotpath.go / recovery.go / endpoints.go
   actually do? Watch for SPEC mandates that IMPL doesn't actually
   honor.
4. The endpoints.go fix adds inline scoping but does NOT add a
   regression test. Is that defensible? (Hot-path and recovery both
   have parallel regressions in `store_test.go`.)
5. Any other code drift introduced by R3?

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

- Explorer surface (deferred).
- Pre-R3 findings (assume R2 disposition is correct).
