# AUDIT — ISS-212 R4 — SECURITY lens

## Task

R4 security re-audit. R3 surfaced 1 MEDIUM (coordinator handlers.go
forwarding internal request_id to gateway, risking wrong-account
200 embed). R4 addressed it via the gateway-proxy contract change.

Branch: `spec/iss-212-explorer-composite-pk`.

## R4 deltas

- `phase4-coordinator/internal/explorer/handlers.go`
  `handleSessionDetail` now forwards
  `/admin/explorer/sessions/{external_request_id}?account_id=...`
  when the resolved row carries non-empty external_request_id +
  account_id. The wrong-account-200-embed attack class is closed.
- `phase5-gateway/internal/storage/sqlite/explorer.go` now
  filters empty-string account_id from the ambiguity union so
  audit_events rows (which default to '') do not surface as
  `matched_account_ids` entries containing "".

## What to audit

1. Does the new gateway-proxy URL contract close the R3 attack
   vector completely, or is there a residual path (e.g., the
   "fallback to internal id when external is empty") that's
   still exploitable?
2. Does the empty-string filter eliminate the bogus-`""`-in-
   matched_account_ids surface? Is there a downstream consumer
   that now silently gets fewer matches than it expects?
3. Any new attack surface introduced by the helper
   `firstNonEmptyAttempt`'s scan-the-attempts behavior?
   (e.g., does picking the FIRST non-empty value let an
   attacker influence which external_request_id/account_id is
   forwarded by seeding extra rows?)

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
