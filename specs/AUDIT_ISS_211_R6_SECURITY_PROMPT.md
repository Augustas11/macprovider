# AUDIT — ISS-211 R6 — SECURITY lens

## Task

R6 security re-audit. R5 surfaced 1 MEDIUM exposing a fundamental
internal-vs-external `request_id` confusion in my SPEC-002 §11
narrative. R6 reframes the entire §11 section.

Branch: `spec/iss-211-coordinator-account-scope`.

## R6 deltas

- SPEC-002 §11 "Money-path: same-provider cross-account collision"
  subsection deleted — described a non-existent attack class
  (assumed internal request_id collisions are real, which they
  aren't given UUID v4 server-side minting).
- SPEC-002 §11 "Money-path: AttemptN derivation" reframed as
  defense-in-depth with explicit internal-vs-external identity
  distinction.
- SPEC-006 §906 + §2323 reworded so `X-Request-ID` is a
  correlation value, not a unique row identity.

## What to audit

1. Does the rewritten SPEC-002 §11 accurately bound the attack
   surface for #211? Specifically: the actual collision class
   is `external_request_id` (buyer-supplied), which the
   composite `(account_id, external_request_id)` reconciliation
   key fully addresses. There is no money-path or audit-trail
   gap I've missed by deleting the same-provider subsection.
2. Does the SPEC-006 §906 rewording correctly differentiate
   `request_id` (correlation) from the composite PK identity
   (uniqueness)? Specifically: does it still tell implementers
   to enforce uniqueness on the composite key, not on
   `request_id` alone?
3. Is there any residual claim in any spec that suggests an
   attacker can engineer a coordinator-internal `request_id`
   collision? (There shouldn't be — UUID v4 entropy makes
   this infeasible.)

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
