# AUDIT — ISS-212 R3 — SECURITY lens

## Task

R3 security re-audit. R2 surfaced 2 MEDIUMs:
- **S4 (fixed):** ambiguity union extended to feedback_events
  and audit_events; SPEC + IMPL + regression test.
- **S5 (fixed):** §7.5 split intra-coordinator vs cross-service
  joins.

R1 deferral S1 (bounded `matched_account_ids`) is still deferred
in v0.3 with an explicit rationale in the audit-findings file.

Branch: `spec/iss-212-explorer-composite-pk`.

## What to audit

1. With the 5-table ambiguity union now in place, is there any
   remaining buyer-controllable surface that could cross-pollinate
   a 200 response on the unscoped path?
2. Does the §5.6 path-segment overload (internal request_id OR
   external_request_id) introduce any new attack vector — e.g.,
   can an attacker engineer a request_id that's interpreted as
   the wrong identity class?
3. Is the v0.3 audit-findings preamble's S1 deferral rationale
   defensible, or does the security calculus now warrant
   absorbing bounded `matched_account_ids` into this PR?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
