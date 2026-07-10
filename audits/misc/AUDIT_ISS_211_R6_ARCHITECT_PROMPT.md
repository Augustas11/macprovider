# AUDIT — ISS-211 R6 — ARCHITECT lens

## Task

R6 architect re-audit. R5 surfaced 1 HIGH + 5 MEDIUM. All six
addressed in R6.

Branch: `spec/iss-211-coordinator-account-scope`.

## R6 deltas (relative to R5)

- SPEC-006 §906 + §2323 (A13 HIGH): `X-Request-ID` is now a
  correlation value, not a unique row identity. Composite PK
  `(account_id, request_id)` is the physical identity.
- SPEC-006 §305 (A16): "SPEC-006 layers on SPEC-002 v1.1.5" →
  "Current dependency: SPEC-002 v1.5.0; base relationship
  established in v1.1.5".
- SPEC-002 AC-FR-B9-MULTI (A14): updated to `(account_id,
  request_id)` grouping under SQLite IS clustering.
- SPEC-005 AC-MULTIHOP + AC-ATTEMPT-FALLBACK (A15): updated to
  `(account_id, request_id)` grouping language.
- SPEC-002 §11 conceptual rewrite (driven by R5 security MEDIUM):
  internal request_id vs external_request_id distinction made
  explicit; ledger-PK known-limitation subsection deleted
  (it was based on a misread of the attack class); A17
  ("follow-up pointer not actionable") becomes moot.
- Regression test deleted (A18 root cause): it pinned an
  artificial same-internal-request_id scenario.

## What to audit

1. Has the corpus FULLY converged on the v1.5.0 model with the
   correct internal-vs-external `request_id` distinction?
   - SPEC-002 v1.5.0
   - SPEC-005 v0.3.1
   - SPEC-006 v0.9.1
   - SPEC-007 v0.2.1 (PR #221, gateway-side)
   Sweep every live (non-changelog) reference for stale
   "request_id is the row key" / "request_id alone is the
   reconciliation key" claims.
2. Does any remaining acceptance criterion or fixture instruction
   tell a future test author to use `request_id`-only grouping?
3. Are there cross-spec dependency-pin contradictions? (e.g.,
   SPEC-005 v0.3.1 dep line says SPEC-002 v1.5.0 but body claims
   v1.1.5 somewhere.)
4. The R5 architect MEDIUMs about ledger PK and tracking-issue
   follow-up are no longer relevant after the §11 conceptual
   rewrite. Confirm those concerns are genuinely moot, not
   silently elided.

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
