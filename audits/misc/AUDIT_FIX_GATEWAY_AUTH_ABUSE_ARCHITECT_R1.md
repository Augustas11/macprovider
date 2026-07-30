# Architecture Audit: Gateway Public Auth Perimeter R1

Review the implementation on branch `fix/deepsec-gateway-auth-abuse`.

Scope:
- `phase5-gateway/internal/config/config.go`
- `phase5-gateway/cmd/gateway/main.go`
- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/router/oauth.go`
- `phase5-gateway/internal/router/admin.go`
- `phase5-gateway/internal/storage/sqlite/store.go`
- `phase5-gateway/internal/storage/sqlite/migrate.go`

Assess whether the implementation uses the right ownership boundaries:
configuration owns tunables, router owns request policy and status mapping,
storage owns atomicity and migration compatibility, and main owns lifecycle
goroutines. Check whether the design is maintainable without broad refactors,
new dependencies, or hidden coupling between public endpoints.

Report findings by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO. Include file
and line references. The pass condition is 0 CRITICAL, 0 HIGH, and 0 MEDIUM
findings.
