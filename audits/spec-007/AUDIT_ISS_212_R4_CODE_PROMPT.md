# AUDIT — ISS-212 R4 — CODE lens

## Task

R4 code re-audit. R3 surfaced 2 MEDIUMs (audit_events empty-string
account_id + §531 stale underlying-sources block). Both addressed
in R4.

Branch: `spec/iss-212-explorer-composite-pk`.

## R4 deltas (relative to R3)

- `phase5-gateway/internal/storage/sqlite/explorer.go`
  `explorerAccountIDsForRequest` now filters `AND account_id != ''`
  on every UNION branch, so audit_events rows inserted with the
  default empty-string account_id (and any future writers that
  fall back to empty) no longer pollute `matched_account_ids`.
- `specs/SPEC-007-explorer.md` §5.6 reworked: identity model
  describes path-segment as coordinator-internal `request_id`
  only in v0.3; path-segment-overload deferred to v0.4 with
  explicit "Deferred to v0.4" subsection.
- `specs/SPEC-007-explorer.md` §5.6 underlying-sources block
  updated to describe coordinator-side intra-coordinator joins
  by internal `request_id` AND the gateway-proxy URL using
  `external_request_id` + `account_id`.
- `phase4-coordinator/internal/explorer/store.go`
  `SessionDetail` SELECT extended to read `external_request_id`
  and `account_id` from `request_log`.
- `phase4-coordinator/internal/explorer/handlers.go`
  `handleSessionDetail` now derives `external_request_id` +
  `account_id` from the resolved attempts and forwards
  `GET /admin/explorer/sessions/{external_request_id}?account_id=<account_id>`
  to the gateway. Falls back to forwarding internal id when
  external is empty (legacy / no-X-Request-ID).
- New test
  `TestSessionDetailGatewayProxyUsesExternalRequestIDAndAccountID`
  pins the gateway-proxy URL contract.

## What to audit

1. Does the empty-string filter on `explorerAccountIDsForRequest`
   cover every UNION branch?
2. Does the new `firstNonEmptyAttempt` helper in
   `handlers.go` correctly scan only the `attempts` slice (which
   is `[]map[string]any` from `queryMaps`) and return the FIRST
   non-empty `external_request_id` + `account_id`?
3. The fallback "if external_request_id empty, forward internal
   id" path — is it correctly handled, or does it silently leave
   the operator with a wrong-account 200 risk the SPEC doesn't
   warn about? (The §5.6 ambiguity contract has a paragraph on
   this; verify code matches the SPEC promise.)
4. Any remaining stale `request_id`-only join/lookup claim in
   the rewritten §5.6 or §531 block?

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM.

If zero findings, respond exactly: `ZERO FINDINGS`.
