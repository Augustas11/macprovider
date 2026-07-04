# AUDIT_FIX_COORDINATOR_PERIMETER_SECURITY_R1

Security audit for Wave 4 coordinator perimeter hardening. Bar: report all issues; expected exit is `0 LOW` or better.

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

Verify these invariants:
- No account-scoped write happens before the caller is authenticated as that account.
- Coordinator buyer chat refuses requests lacking valid gateway context when `coordinator.require_gateway_context: true`.
- WS admission slots are strictly capped under concurrent handshakes; failed auth releases its reservation.
- Provider-controlled strings on the WS surface are bounded before reaching persistent storage.
- Encrypted end-frame routing/completion uses only the AAD-bound `request_id`; plaintext tampering cannot complete a different active request.
- Relay per-request buffer growth is bounded; excess triggers a clean request drop and metric increment.
- Coordinator OAuth state is bound to the initiating browser and expires; unauthenticated start probes cannot grow DB rows unbounded.
- Settlement output rejects duplicate JSON keys so buyer-visible bytes cannot diverge from what settlement scans.

Return findings first, ordered by severity with concrete exploitability and file/line references. If no issues, say `0 C/H/M/L findings`.
