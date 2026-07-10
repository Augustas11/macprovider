# AUDIT — ISS-211 R5 — ARCHITECT lens

## Task

R5 architect re-audit. R4 surfaced 1 HIGH + 4 MEDIUM. All five
addressed in R5.

Branch: `spec/iss-211-coordinator-account-scope`.

## R5 deltas (relative to R4)

- `specs/SPEC-002-coordinator.md` §11: new "Money-path:
  same-provider cross-account collision" subsection documents
  the ledger-PK known limitation, explains exposure bound, and
  points at the follow-up tracking issue.
- `specs/SPEC-002-coordinator.md` v1.5.0 changelog "Deploy
  ordering" bullet rewritten: PRAGMA only for the absent-column
  case; per-row `account_id IS NOT NULL` for everything else.
- `specs/SPEC-002-coordinator.md` §11 live request_log contract
  paragraph: "row order within a `request_id`" →
  "row order within an `(account_id, request_id)` group" + IS
  clustering callout.
- `specs/SPEC-006-buyer-api.md` §1.5: clarifies
  "base relationship v1.1.5; current dependency v1.5.0".
- New regression tests
  (`TestWriteHotPath_SameProviderCrossAccountCollisionBehavior`,
  `TestReconcileEndpoint_AccountScopedRequestIDCollisionCleanDelta`).

## What to audit

1. Has the corpus converged on the v1.5.0 model with no
   contradictions between SPEC-002 / SPEC-005 / SPEC-006?
   Sweep every live (non-changelog) reference to attempt
   grouping, request_log identity, or reconciliation key.
2. Are there any other places in SPEC-002 v1.5.0 (or downstream
   specs) that imply column presence is the audit-switch?
3. The new SPEC-002 §11 "same-provider cross-account collision"
   subsection acknowledges a known limitation. Is the
   tracking-issue note specific enough (file / line / migration
   scope) that a future implementer can pick it up without
   re-deriving the problem statement?
4. Are there any remaining cross-spec dependency lines that
   point at obsolete versions in live body text?

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
