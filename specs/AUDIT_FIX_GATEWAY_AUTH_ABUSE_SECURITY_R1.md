# Security Audit: Gateway Public Auth Perimeter R1

Review the implementation on branch `fix/deepsec-gateway-auth-abuse`.

Scope:
- `phase5-gateway/internal/config/config.go`
- `phase5-gateway/cmd/gateway/main.go`
- `phase5-gateway/internal/router/server.go`
- `phase5-gateway/internal/router/oauth.go`
- `phase5-gateway/internal/router/admin.go`
- `phase5-gateway/internal/storage/sqlite/store.go`
- `phase5-gateway/internal/storage/sqlite/migrate.go`

Security invariants to verify:
- OAuth handlers do not execute when `GitHubOAuthEnabled=false`, including
  direct handler invocation or accidental registration.
- Unauthenticated callers cannot force persistent database writes on gateway
  public endpoints.
- Per-IP public issuance ceilings are enforced under concurrent load without
  check-then-insert races.
- OAuth state rows cannot grow unbounded and cannot outlive the expected TTL.
- Feedback is bounded on both write and read paths.

Report findings by severity: CRITICAL, HIGH, MEDIUM, LOW, INFO. Include file
and line references. The pass condition is 0 CRITICAL, 0 HIGH, 0 MEDIUM, and
0 LOW findings because this is an externally reachable path.
