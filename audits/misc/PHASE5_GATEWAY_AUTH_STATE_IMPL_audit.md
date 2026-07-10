CRITICAL (0):
  (none)

HIGH (0):
  (none)

MEDIUM (1):
  M1. Summary fallback can reintroduce excluded ready capacity after all detailed rows are skipped
      Evidence: phase5-gateway/internal/router/server.go:597
      Evidence: phase5-gateway/internal/router/server.go:605
      Evidence: phase5-gateway/internal/router/server.go:654
      Evidence: phase5-gateway/internal/router/server.go:656
      Evidence: phase5-gateway/internal/router/server_test.go:1046
      Fix:     Apply the summary fallback only when the coordinator omitted detailed pool rows, e.g. `len(poolz.Pool) == 0`, and add a regression case with only `auth_state:"bearerless_duplicate"` rows plus `summary.ready > 0`.

LOW (2):
  L1. `mint_failed` and unknown future auth states are not pinned by tests
      Evidence: phase5-gateway/internal/router/server.go:605
      Evidence: phase5-gateway/internal/router/server_test.go:1002
      Fix:     Add a table test proving empty, `bearer_validated`, `self_minted`, `mint_failed`, and an unknown string aggregate normally while only `bearerless_duplicate` is skipped.

  L2. Gateway mirrors the coordinator enum with an unguarded string literal
      Evidence: phase5-gateway/internal/router/server.go:605
      Evidence: phase4-coordinator/internal/pool/provider.go:80
      Fix:     Keep the local literal or local gateway const because `phase4-coordinator/internal` cannot be imported, but add a repo-level contract test or static check comparing it to `pool.AuthBearerlessDuplicate` / SPEC-002 text.

QUESTIONS (1):
  Q1. Should buyer-facing `pool.total_providers` be a routable-capacity count or a present-provider count? The loop excludes bearerless duplicates before `TotalProviders++`, but the fallback restores coordinator `summary.total_providers` for an all-bearerless pool; SPEC-002 v1.4.1 explicitly names Ready / slots / availability but not `TotalProviders`.
