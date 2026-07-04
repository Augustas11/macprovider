# AUDIT_FIX_COORDINATOR_PERIMETER_ARCHITECT_R1

Architecture review for Wave 4 coordinator perimeter hardening.

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

Assess:
- Whether the gateway-context invariant is enforced at the right boundary and remains compatible with the gateway module.
- Whether typed account context in requestlog is strong enough to prevent accidental unauthenticated account-scoped writes.
- Whether admission reserve/release semantics are simple enough to maintain and do not conflict with persistence.
- Whether relay AAD binding and buffer caps fit the current provider session model without hidden ordering contracts.
- Whether OAuth state origin binding uses an appropriate secret and migration strategy.
- Whether settlement duplicate-key rejection is the right canonicalization approach for the current response pipeline.
- Whether config defaults and example YAML make the security posture explicit for operators.

Return findings first, ordered by severity with file/line references. If no issues, say `0 C/H/M/L findings` and identify any residual design risks.
