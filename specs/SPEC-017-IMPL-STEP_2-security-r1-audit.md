# SPEC-017 IMPL Step 2 — SECURITY audit r1

Branch: `impl/spec-017-step-1` / PR #173  
Diff audited: `b4993274bea617bcee494e77baf705abafc01b82..7e28ec28634590f85e82a8dd0562304b2bd31f49`  
Lens: role isolation, provider identity, secret handling, defense-in-depth, Step 3/4 attack surface.

Required reading completed: `CLAUDE.md`; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` §1, §5, §2 Step 2; `specs/SPEC-017-network-stats-api.md` v0.1.8 §1.5, §6.1, §6.4, §6.6.2, §6.6.3, §7.2, §7.3, plus §9 rollup details where needed; `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`; `specs/SPEC-017-IMPL-STEP_1-r4-convergence.md`; memory notes `provider-auth-unauthenticated-end-to-end`, `audit-loop-catches-billing-ledger-drift`, and `c2-gate-gateway-credential-validation-asymmetry`; Step 2 diff; PR #173 body via `gh pr view`.

Validation run:

- `git diff --name-status b499327..HEAD` — Step 2 rollup package + coordinator/config wiring identified.
- `git diff --check b499327..HEAD` — PASS.
- `go test ./internal/stats/rollup ./internal/stats` from `phase4-coordinator/` — PASS.
- `rg` checks found no Step 2 rollup references to `provider_session`, `provider_handshake`, raw `provider_visibility_audit`/`partner_keys` mutation, raw `token_hash`, or Origin-dependent rollup logic.

## Category Verdicts

A. Role + pool isolation: **PASS**. Production wiring calls `statsrollup.New(statsPools.Rollup, ...)` only (`cmd/coordinator/main.go:218`), `stats.Open` uses write-pool sizing for rollup (`internal/stats/stats.go:199-204`, `264-270`), and smoke keeps the `stats_rollup` deny probe on `partner_keys` (`internal/stats/stats.go:330-335`). No Step 2 rollup code attempts `partner_keys` or `provider_visibility_audit` mutation.

B. Identity trust: **FAIL — CRITICAL**. Work-ledger rows join `provider_tokens`, but rewards-only leaderboard rows can be materialized from `provider_rewards_ledger` without any `provider_tokens` join.

C. Bucket / projection invariant: **PASS**. Storage writes exact `$` into `earnings_usd`, `earnings_work_usd`, and `earnings_rewards_usd` (`rollup/leaderboard.go:376-399`) and computes storage-time `earnings_bucket` through pinned thresholds (`rollup/bucket.go:24-77`). Step 3 still owns public redaction.

D. Drift + late events + AC-20: **PASS**. Drift logs include event/window/axis/provider sample/ratios only (`rollup/rebuild.go:170-179`), and no Step 2 fixture seeds `provider_visibility_audit`. Late-event insertion helper writes only `stats_late_events` and is currently not wired into the full-recompute v0.1 path.

E. Configuration safety: **PASS**. Backfill enum, non-negative USD factor, retention floor/clamp+warn, and drift bounds are validated in config/runner paths (`internal/config/config.go:1039-1057`, `rollup/config.go:119-140`, `rollup/runner.go:50-64`).

F. Provider-rewards-ledger handling: **FAIL — CRITICAL via B1**. Ledger use is limited to `rewards_populated` and rewards aggregation, but the rewards aggregation bypasses the authenticated provider identity filter before contributing leaderboard rows.

G. Process isolation: **FAIL — MEDIUM**. Panics are recovered at goroutine scope, so the coordinator survives, but the affected per-table job exits instead of continuing/restarting on later ticks.

## Findings

### CRITICAL 1 — Rewards-only leaderboard rows bypass the `provider_tokens` trust source

Evidence:

- `aggregateWorkPerProvider` correctly joins `ledger_request_credits` to `provider_tokens` before emitting a provider id (`phase4-coordinator/internal/stats/rollup/leaderboard.go:174-188`).
- `aggregateRewardsPerProvider` reads `provider_rewards_ledger.provider_id` directly with no `provider_tokens` join (`phase4-coordinator/internal/stats/rollup/leaderboard.go:215-221`).
- `computeLeaderboardRows` unions provider ids from both `work` and `rewards` maps (`phase4-coordinator/internal/stats/rollup/leaderboard.go:124-130`), so a provider present only in `provider_rewards_ledger` is materialized into `stats_leaderboard_*` with exact storage dollars (`phase4-coordinator/internal/stats/rollup/leaderboard.go:144-155`, `376-399`).
- The existing trust-source integration test covers an unauthenticated `ledger_request_credits` row (`rollup_integration_test.go:581-619`) but does not seed a `provider_rewards_ledger` row for a provider absent from `provider_tokens`.

Why this is CRITICAL:

The Step 1 decision record pins that every Step 2 leaderboard `provider_id` must trace through SPEC-002 v1.4 §7 `provider_tokens`; `[[provider-auth-unauthenticated-end-to-end]]` is the exact reason. A rewards-only row for `p_spoof` can currently enter the public leaderboard storage without that authenticated join. Even if `provider_rewards_ledger` is operator-defined, Step 2 is still materializing a leaderboard identity from a source that is not the authenticated trust table.

Required fix:

Filter rewards aggregation through `provider_tokens`, for example:

```sql
SELECT prl.provider_id, COALESCE(SUM(prl.amount_usd), 0) AS amount
  FROM provider_rewards_ledger prl
  JOIN provider_tokens pt ON pt.provider_id = prl.provider_id
 WHERE ($1 = 0 OR prl.unix_ts >= $1)
 GROUP BY prl.provider_id
```

Add an integration test that inserts a rewards-only `provider_rewards_ledger` row for a provider not present in `provider_tokens` and asserts no `stats_leaderboard_*` row is produced.

### MEDIUM 1 — Per-table panic recovery stops the affected job instead of restarting it

Evidence:

- `spawnTick` installs `recover` as a defer around the entire goroutine (`phase4-coordinator/internal/stats/rollup/runner.go:131-146`).
- If `r.runOne` or the job function panics, the defer logs and health-fails, but the goroutine has already unwound past the ticker loop (`phase4-coordinator/internal/stats/rollup/runner.go:148-163`).
- SPEC §9.6 / audit category G.2 require a per-table panic to restart only that table's job, not permanently stop it.

Risk:

The coordinator process survives, but one rollup table can silently stop refreshing until coordinator restart. Step 3/4 then inherit a stale public projection surface and health state depends on freshness aging rather than the job actually restarting.

Required fix:

Move panic recovery inside the per-tick invocation, or wrap each `fn(ctx)` call with a `safeRunOne` that catches panics, updates that component's health row, then returns to the ticker loop. Add a test job that panics once and then succeeds on the next tick, proving the component keeps running.

### MEDIUM 2 — Panic logs and health rows record the raw panic payload

Evidence:

- The panic handler logs `.Interface("recovered", rec)` for table ticks and nightly rebuild (`phase4-coordinator/internal/stats/rollup/runner.go:136-143`, `187-193`).
- It also writes `fmt.Sprintf("panic: %v", rec)` into `stats_components_health.last_error_message` (`phase4-coordinator/internal/stats/rollup/runner.go:142-144`).

Risk:

The current rollup path does not handle raw partner tokens or DSNs, so I did not rate this as a direct leak. It is still below the redacted-context standard in G.1: future Step 3/4 caller mistakes or lower-layer panic payloads can persist arbitrary strings to structured logs and database health rows.

Required fix:

Replace raw panic serialization with a bounded redacted classification, e.g. type name + fixed message, and keep full internals only behind an operator-local debug mode that is explicitly barred from production.

## Positive Security Observations

- Pool isolation is correct in the live coordinator path: the rollup receives only `statsPools.Rollup` (`cmd/coordinator/main.go:218`), and Step 1 smoke still rejects miswired role DSNs.
- No Step 2 rollup code path attempts `provider_visibility_audit` INSERT/UPDATE/DELETE or `partner_keys` mutation.
- Bucket storage matches the Step 3 projection contract: exact storage values are preserved for partner projection, while bucket computation is stored separately.
- Drift detection logs pseudonymizable `provider_id_sample` and numeric drift data only; no DSN, token, token hash, partner key prefix, or Origin string is logged there.
- PR #173 body still contains the provider-identity trust-source decision and links `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.

## Final Verdict

CRITICAL: 1  
HIGH: 0  
MEDIUM: 2  
LOW: 0  
INFO: 0

**NOT READY TO LOCK.**

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM. The trust-source bypass for rewards-only leaderboard rows must be fixed before Step 2 can lock; the panic-recovery issues should be fixed in the same round because they are defense-in-depth requirements Step 3/4 will depend on.
