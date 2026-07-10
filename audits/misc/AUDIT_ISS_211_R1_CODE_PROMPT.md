# AUDIT — ISS-211 R1 — CODE lens

## Task

Audit the SPEC + IMPL bundle for issue #211 (coordinator-side
account-scoped reconciliation key, follow-up to #196) for
**CODE-lens drift between spec and implementation**:

Branch: `spec/iss-211-coordinator-account-scope`.

### SPEC changes to verify
- `specs/SPEC-002-coordinator.md` v1.5.0 change-log + §11 FR-B9
  request_log schema + §11 indexes block + §11 deploy-ordering +
  §11 money-path-AttemptN sub-section + §7.2
  X-MacProvider-Account forward contract.
- `specs/SPEC-006-buyer-api.md` v0.9.1 change-log + gateway forward
  header requirement.

### IMPL changes to verify against
- `phase4-coordinator/internal/requestlog/store.go`: account_id
  column added to canonical CREATE TABLE, ensureColumns migration,
  Row struct field, insert() binding,
  idx_request_log_account_external_request_id in MigrateIndexes.
- `phase4-coordinator/internal/buyer/server.go`:
  sanitizeAccountID helper, reading X-MacProvider-Account in
  handleChatCompletions, plumbing through newBillingRecorder.
- `phase4-coordinator/internal/buyer/billing_recorder.go`: struct
  field accountID, constructor parameter, Row{} write.
- `phase4-coordinator/internal/billing/hotpath.go`: AttemptN COUNT
  scope (account_id, request_id) when reqRow.AccountID != "",
  fallback to unscoped when empty.
- `phase5-gateway/internal/router/chat_proxy.go`: hoisted
  X-MacProvider-Account out of the sticky-routing conditional.
- New tests in
  `phase4-coordinator/internal/billing/store_test.go`
  (`TestWriteHotPath_AccountScopedRequestIDCollisionDoesNotQuarantine`)
  and
  `phase5-gateway/internal/router/server_test.go`
  (positive assertion in `TestProviderPinningHeadersStripped`,
  updated assertion in `TestStickyConversationIgnoredForDemoTraffic`).

### Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM findings of these classes:
- SPEC text describes behavior the code doesn't implement.
- Code implements behavior the SPEC doesn't describe.
- New SQL statement uses a column or index that doesn't exist on
  fresh installs OR on migrated installs.
- Money-path math (hotpath.go AttemptN derivation) drifts from
  the SPEC's stated invariant.
- A SPEC MUST has no corresponding code branch (e.g. "MUST
  tolerate absent header" with no empty-string handling).
- Backwards-compat: a code path that worked pre-v1.5.0 stops
  working without the SPEC saying so.

Format each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: <what the SPEC says vs what the code does>
SUGGESTED FIX: <minimal>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

### Out of scope
- Explorer surface SELECT'ing account_id (intentionally deferred
  to a follow-up; #211 closes on reconciliation-key only).
- The #196 gateway composite-PK design itself.
- ISS-197 v1.4.3 R-2 external_request_id clarifications (separate).
