# AUDIT — ISS-211 R3 — ARCHITECT lens

## Task

R3 architect re-audit. R2 surfaced 3 MEDIUMs (one duplicate of code-
lens R2 finding, plus SPEC-005 dep + SPEC-006 merge-order pointer).
All three are now addressed.

Branch: `spec/iss-211-coordinator-account-scope`.

## R3 deltas (relative to R2)

- `endpoints.go:302-318` account-scoped attempt_n derivation in
  `buyerEquivalentCredits` (admin reconcile).
- `specs/SPEC-005-billing.md` v0.3.1: dep bump to SPEC-002 v1.5.0
  + SPEC-006 v0.9.1; §4.2 / §8.2 fallback-attempt-ordinal text
  scoped by `(account_id, request_id)` with legacy NULL fallback.
- `specs/SPEC-006-buyer-api.md` SPEC-007 §6.4 pointer softened to
  merge-order-safe wording.

## What to audit

1. Is the SPEC corpus now coherent end-to-end on the v1.5.0 model?
   - SPEC-002 v1.5.0 (request_log composite key)
   - SPEC-005 v0.3.1 (attempt-ordinal grouping scoped)
   - SPEC-006 v0.9.1 (gateway forward + bearer-pairing)
   - SPEC-007 v0.2.1 (gateway composite-PK addendum — pending PR #221)
   Do they tell one consistent story? Any text that still claims
   the pre-v1.5.0 reconciliation key?
2. SPEC-005 v0.3.1 references that "IMPL parallel — hotpath.go,
   recovery.go, and endpoints.go admin reconcile — already carries
   this scoping". Is that claim still true after R3? Are there
   other IMPL sites SPEC-005 v0.3.1 should call out as honoring
   the new contract?
3. The explorer deferral remains in place. The SPEC-002 v1.5.0
   explorer-deferral text now interacts with SPEC-005 v0.3.1's
   normative grouping rule. Does an explorer query that reads
   `request_log` and surfaces `account_id` need to be in scope
   for #211 to fully close, or is the current "audit reads via
   direct SQL" guidance sufficient?
4. SPEC-005 v0.3.1's depends-on bump to SPEC-006 v0.9.1 — is
   that bump independently meaningful, or did it just chain
   because of SPEC-002? Look for SPEC-005 text that depends on
   SPEC-006 v0.9.1 normative content specifically.
5. Any architectural smell that R3 introduces (e.g., the
   bearer-pairing being a transitional shim vs the long-term
   shape from R2 architect concern #2)?

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
