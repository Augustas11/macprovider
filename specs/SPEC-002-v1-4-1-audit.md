CRITICAL (0):

HIGH (0):

MEDIUM (3):
  M1. `mint_failed` is documented as a `/poolz` row enum even though current WS flow never publishes such a row
      Evidence: specs/SPEC-002-coordinator.md:1434; phase4-coordinator/internal/ws/server.go:667; phase4-coordinator/internal/ws/server.go:713; phase4-coordinator/internal/ws/server.go:968
      Fix:     Either state that `mint_failed` is a defined/reserved AuthState not currently emitted on registered `/poolz` rows, or change the coordinator to publish an observable non-routable row and define its aggregation policy.

  M2. The aggregation rule omits provider-count counters that the gateway already excludes
      Evidence: specs/SPEC-002-coordinator.md:1438; phase5-gateway/internal/router/server.go:605; phase5-gateway/internal/router/server.go:608; phase5-gateway/internal/router/server.go:624; specs/SPEC-006-buyer-api.md:1763
      Fix:     Add top-level `Pool.TotalProviders` and per-model `ProviderCount` to the `bearerless_duplicate` exclusion rule if they are buyer-facing eligible-provider counts, or explicitly define them as raw pool counts and align the gateway implementation.

  M3. The all-bearerless summary fallback remains ambiguous and can reintroduce excluded rows into buyer-visible totals
      Evidence: specs/SPEC-002-coordinator.md:1440; phase5-gateway/internal/router/server.go:654; phase5-gateway/internal/router/server.go:655; phase5-gateway/internal/router/server_test.go:1037
      Fix:     Specify that auth-state-aware consumers MUST NOT use coordinator `summary` fallback to repopulate excluded provider counters when `/poolz.pool` rows are present, or explicitly define top-level totals as raw operator-visible counts.

LOW (2):
  L1. The SPEC-003 dependency line misattributes the full enum provenance to v0.8.3
      Evidence: specs/SPEC-002-coordinator.md:4; specs/SPEC-003-open-onboarding.md:8; specs/SPEC-003-open-onboarding.md:20; specs/SPEC-003-open-onboarding.md:597
      Fix:     Reference the current SPEC-003 FR-C9.4 composed contract and say the base AuthState values came from the v0.8.3 line while `mint_failed` was added by v0.8.4.

  L2. SPEC-006 remains stale for the new `/v1/status` aggregation invariant
      Evidence: specs/SPEC-002-coordinator.md:1438; specs/SPEC-006-buyer-api.md:1284; specs/SPEC-006-buyer-api.md:1288; specs/SPEC-006-buyer-api.md:1763
      Fix:     Add a SPEC-006 pointer or follow-up amendment so implementers reading the gateway spec alone see the `auth_state == "bearerless_duplicate"` exclusion rule.

QUESTIONS (2):
  Q1. Should `Pool.TotalProviders` on `/v1/status` intentionally mean buyer-routable eligible providers, matching the current gateway implementation, or raw coordinator-visible sessions?
  Q2. Is `mint_failed` intended to become operator-visible in `/poolz`, or is it only a fail-closed internal AuthState marker returned before the session is registered?
