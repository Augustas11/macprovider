# AUDIT — ISS-211 R5 — SECURITY lens

## Task

R5 security re-audit. R4 returned ZERO FINDINGS. R5 deltas
document a known limitation in SPEC-002 §11 (same-provider
cross-account collision) and add a regression test pinning the
behavior.

Branch: `spec/iss-211-coordinator-account-scope`.

## What to audit

1. Does the new SPEC-002 §11 "same-provider cross-account
   collision" subsection accurately describe the attack
   surface? Specifically:
   - Can an attacker trigger the UNIQUE collision intentionally
     to deny service to another account?
   - Probability bound: requires guessing victim's X-Request-ID,
     routing-layer picking same provider, winning the race to
     insert first. UUID v4 entropy + utilization-favoring
     selection make this operationally infeasible. Verify this
     reasoning.
2. Is the deferred ledger-PK-account-scoping clearly documented
   as a known limitation rather than a closed concern, so
   operators reading v1.5.0 can decide whether to gate
   deployment on the follow-up?
3. Any new attack surface from the R5 SPEC text additions?

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
