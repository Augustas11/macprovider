# AUDIT — ISS-212 R1 — SECURITY lens

## Task

Audit the SPEC-007 v0.2.1 addendum in `specs/SPEC-007-explorer.md`
(see § 6.4 rewrite for `GET /admin/explorer/sessions/{request_id}`)
for **SECURITY-lens issues** an operator-cockpit reviewer would flag:

- Does the addendum's `matched_account_ids` disclosure in the
  `409 ambiguous_request_id` body open an information leak that
  would not have existed under the prior `request_id`-only model?
  (The endpoint is bearer-gated on `coordinator.operator_key`,
  i.e. operator-only — but evaluate whether the SPEC's MUST around
  returning the full set is appropriate, or should be bounded.)
- Could a buyer-controlled `X-Request-ID` be weaponized via the
  unscoped lookup path the SPEC newly endorses (e.g. enumerating
  account_ids by submitting a UUID and waiting for an operator
  to investigate)? Should the SPEC require the scoped path for
  any operator workflow that handles untrusted request_id input?
- Does the SPEC's claim that the handler MUST NOT 409 when
  `account_id` is supplied accidentally permit cross-account
  exposure (e.g. is there guidance to verify the supplied
  `account_id` actually owns the row, not just to scope the
  query)? Is the existing implementation that simply scopes the
  WHERE clause sufficient for the SPEC's auth model, given the
  operator bearer is the only credential?
- Are there any forbidden-field omissions that should be repeated
  in this § 6.4 rewrite (e.g. `api_keys.key_hash`,
  `demo_usage_events.demo_token_hash` per § 6.3 conventions)?

Cross-reference `phase5-gateway/internal/router/explorer.go`
`handleExplorerSessionDetail` and `phase5-gateway/internal/storage/types.go`
for the actual response surface.

## Severity bar

Report ONLY CRITICAL, HIGH, or MEDIUM. Each finding:

```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: ...
SUGGESTED FIX: <minimal SPEC edit>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

## Out of scope

- The composite-PK design in #196 itself.
- Auth model for `/admin/explorer/*` (locked in D3 / § 2.3).
- Coordinator-side reconciliation key (issue #211).
