# AUDIT — ISS-212 R5 — SECURITY lens

## Task

R5 security re-audit. R4 surfaced 2 MEDIUMs:
- **S7 (fixed):** URL construction bug — `?account_id=` was
  path-escaped, never reached the gateway. Fixed by separating
  path and rawQuery.
- **S8 (fixed):** fallback paths (unscoped external or internal
  id) still risked wrong-account 200 embed. Tightened to
  "both-or-nothing" contract.

Branch: `spec/iss-212-explorer-composite-pk`.

## What to audit

1. Does the "both-or-nothing" contract eliminate ALL paths
   where the coordinator could embed wrong-account gateway data?
   Walk through:
   - Internal id resolves → has external + account → proxy with
     composite key → matching account's row returned. SAFE.
   - Internal id resolves → has external but NULL account
     (legacy/pre-v0.9.1 row) → NO proxy. Operator sees
     `gateway_identity_unavailable`. SAFE.
   - Internal id resolves → empty external (no inbound
     X-Request-ID) → NO proxy. SAFE.
   - Internal id NOT found → coordinator returns 404 from
     `SessionDetail` → handler hits gateway-only fallback path
     (uses `requestID` directly). Is THAT still secure given
     the new both-or-nothing contract? Let me re-check.
2. The gateway-only fallback at the top of `handleSessionDetail`
   (when SessionDetail returns ErrNoRows AND GatewayBaseURL is
   set, it proxies `/admin/explorer/sessions/{requestID}` raw)
   — does this re-expose the wrong-account-200 class for
   path-segment values that don't match any internal request_id?
3. Any new attack surface introduced by the
   `gateway_identity_unavailable` error code (e.g., does an
   attacker gain info from knowing the coordinator skipped the
   proxy)?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
