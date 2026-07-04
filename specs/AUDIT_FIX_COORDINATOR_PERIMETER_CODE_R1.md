# AUDIT_FIX_COORDINATOR_PERIMETER_CODE_R1

Review the Wave 4 coordinator perimeter implementation for code correctness, regressions, and missing tests.

Scope:
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/settlement_output.go`
- `phase4-coordinator/internal/requestlog/store.go`
- `phase4-coordinator/internal/ws/server.go`
- `phase4-coordinator/internal/ws/messages.go`
- `phase4-coordinator/internal/ws/admission.go`
- `phase4-coordinator/internal/ws/relay.go`
- `phase4-coordinator/internal/ws/auth_github.go`
- `phase4-coordinator/internal/config/config.go`

Check:
- Middleware ordering: authenticated gateway context must run before idempotency reservation and request-log writes.
- `requestlog.AuthenticatedAccount` must be used on the new authenticated account-scoped write paths.
- Admission pending reservations must release on successful registration and on failed/error paths.
- WS parser caps must reject oversized provider-controlled fields before persistence.
- Relay AAD/end-frame routing must not complete the wrong request.
- Relay buffer accounting must reject oversized provider bursts without breaking existing chunk/end ordering.
- OAuth state schema migration, creation, consume, TTL, and rate limiting must be correct for existing DBs.
- Duplicate JSON key detection must reject nested duplicate keys without rejecting valid output.

Return findings first, ordered by severity with concrete file/line references. If no issues, say `0 C/H/M/L findings` and list the tests you would expect to see.
