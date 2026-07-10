# AUDIT — ISS-211 R3 — SECURITY lens

## Task

R3 security re-audit. R2 returned ZERO FINDINGS. R3 changes are
SPEC-only (SPEC-005 v0.3.1 dep bump, SPEC-006 merge-order pointer
softening) plus one SQL scoping fix in `endpoints.go:302-318`.

Branch: `spec/iss-211-coordinator-account-scope`.

## R3 deltas (relative to R2)

- `phase4-coordinator/internal/billing/endpoints.go`:
  admin reconcile `buyerEquivalentCredits` `prior`-attempt subquery
  scoped by `(account_id, request_id)`.
- `specs/SPEC-005-billing.md`: v0.3.1 bump.
- `specs/SPEC-006-buyer-api.md`: merge-order-safe pointer wording.

## What to audit

1. Does the endpoints.go scoping change open any new attack
   surface? (The query is admin-only, behind operator bearer; the
   change is a stricter scope, not a looser one.)
2. SPEC-005 v0.3.1 says "ambiguous rows in that group MUST be
   quarantined". Does this change the quarantine semantics for
   the all-NULL-account_id legacy case in a way that could
   silently quarantine money? (My read: NO — the group
   degrades to same-request_id grouping, identical to pre-v0.3.1.)
3. Any new defense-in-depth gap introduced by the R3 SPEC text?

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
