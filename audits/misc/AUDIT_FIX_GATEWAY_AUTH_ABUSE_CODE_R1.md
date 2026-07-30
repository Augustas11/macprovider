# Code Audit: Gateway Public Auth Perimeter R1

Review the implementation on branch `fix/deepsec-gateway-auth-abuse`.

Scope:
- `phase5-gateway/internal/config/config.go`
- `phase5-gateway/cmd/gateway/main.go`
- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/router/oauth.go`
- `phase5-gateway/internal/router/admin.go`
- `phase5-gateway/internal/storage/sqlite/store.go`
- `phase5-gateway/internal/storage/sqlite/migrate.go`

Check for correctness, test adequacy, migration safety, interface drift, and
regressions against existing gateway behavior. Pay particular attention to
OAuth feature flag enforcement, atomic public issuance reservations, OAuth state
TTL/cap/pruning, authenticated-only internal-header audit writes, and bounded
feedback write/read paths.

Report findings by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO. Include file
and line references. The pass condition is 0 CRITICAL, 0 HIGH, and 0 MEDIUM
findings.
