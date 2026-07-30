# SPEC-017 IMPL Step 2 - SECURITY audit r4

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `a70d75a` (`impl(017): Step 2 - implement SPEC section 9.3 incremental-merge for 30d/all`)
Round-3 SECURITY lock point: `745128e`
Round-3 LOW fix: `9297f0d`
Round-4 delta audited: `745128e..a70d75a`; full Step 2 diff spot-checked against `origin/main...HEAD`.
Lens: role isolation, provider identity, secret handling, defense-in-depth, and Step 3/4 attack surfaces.

Required reading completed: `CLAUDE.md`; `specs/BUILD_SPEC_017_IMPL_PROMPT.md` section 1 prereqs, section 5 critical constraints, and section 2 Step 2; `specs/SPEC-017-network-stats-api.md` v0.1.8 sections 1.5, 6.1, 6.4, 6.6.2, 6.6.3, 7.2, 7.3, 9.3, and 9.4; `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`; `specs/SPEC-017-IMPL-STEP_2-security-r1-audit.md`; `specs/SPEC-017-IMPL-STEP_2-security-r2-audit.md`; `specs/SPEC-017-IMPL-STEP_2-security-r3-audit.md`; memory notes `provider-auth-unauthenticated-end-to-end`, `audit-loop-catches-billing-ledger-drift`, and `c2-gate-gateway-credential-validation-asymmetry`; PR #173 body via `gh pr view`.

Validation run:

- `git show --name-only 9297f0d` and `git show --name-only a70d75a` - round-3 LOW comment fix and round-4 incremental files identified.
- `rg` sweeps found no Step 2 rollup references to `provider_session`, `provider_handshake`, raw hello-frame identity sources, runtime `Origin` branching, runtime `token_hash` logging, rollup mutation of `partner_keys`, rollup mutation of `provider_visibility_audit`, or production Shape A/B SQL (`TRUNCATE`, `ALTER TABLE RENAME`, `DROP TABLE`).
- `go test ./internal/stats/rollup/...` from `phase4-coordinator/` - PASS.
- `go test ./internal/stats/rollup -run 'TestEmitDriftPayloadRedaction|TestClassifyPanic|TestConfigValidate|TestConfigDefaultsApplied' -count=1` - PASS.
- `go test ./internal/stats -run 'TestOpenMissingDSNFailClosed|TestPoolsCloseNilSafe' -count=1` - PASS.
- `go test -tags=integration -c ./internal/stats/` - PASS compile.
- Targeted integration execution for the rollup/security tests could not run locally because testcontainers panicked with `rootless Docker not found`. This is an environment gap, not an implementation failure.
- `git diff --check origin/main...HEAD` - FAIL only on pre-existing trailing whitespace in older Step 2 audit markdown files; no inspected implementation file or this r4 audit file is implicated.

## Category Verdicts

A. Role + pool isolation: PASS. Production wiring still constructs the runner with `statsrollup.New(statsPools.Rollup, ...)` only (`phase4-coordinator/cmd/coordinator/main.go:240-255`), `stats.Open` gives the rollup role the write-pool tuning (`phase4-coordinator/internal/stats/stats.go:193-204`, `stats.go:264-270`), and the grant inventory gives `stats_rollup` no grant on `partner_keys` or `provider_visibility_audit` (`phase4-coordinator/internal/stats/migrations/004_grants.up.sql:52-75`). Round-4 incremental code uses the injected rollup `db` only and adds no alternate pool path (`phase4-coordinator/internal/stats/rollup/incremental.go:53-100`).

B. Identity trust: PASS. The new incremental active-provider query is sourced from `provider_tokens` and only sees work/rewards rows through `EXISTS` checks keyed by that authenticated provider id (`phase4-coordinator/internal/stats/rollup/incremental.go:181-204`). Provider-scoped incremental recompute also joins `provider_tokens` for both work and rewards (`incremental.go:224-264`). Existing full-recompute paths retain the same trust-source joins (`phase4-coordinator/internal/stats/rollup/leaderboard.go:227-291`), and PR #173 still records the trust-source decision and links `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.

C. Bucket / projection invariant: PASS. The round-3 LOW comment drift in `leaderboard.go` is fixed: comments now state that `blocked_from_partner_projection` is read only as a v0.1 stub and must not affect storage (`phase4-coordinator/internal/stats/rollup/leaderboard.go:31-40`, `leaderboard.go:131-139`, `leaderboard.go:168-179`). Both full and incremental paths continue storing exact `earnings_usd`, `earnings_work_usd`, and `earnings_rewards_usd` while computing a single storage-time `earnings_bucket` (`leaderboard.go:431-461`, `phase4-coordinator/internal/stats/rollup/incremental.go:277-294`, `incremental.go:356-391`).

D. Drift + late events + AC-20: PASS with one LOW documentation finding below. The incremental path records late events after the incremental transaction and does not fold older-than-lookback rows into the live snapshot until the nightly Shape C rebuild (`phase4-coordinator/internal/stats/rollup/incremental.go:78-91`, `phase4-coordinator/internal/stats/rollup_integration_test.go:1047-1167`). Late-event work and rewards scans join `provider_tokens` and write only `stats_late_events` (`phase4-coordinator/internal/stats/rollup/late_events.go:57-99`). The rollup still has no code path inserting `provider_visibility_audit`; AC-20 fixtures seed only allowed provider-exact or operator-bucketed rows (`phase4-coordinator/internal/stats/integration_test.go:289-305`, `integration_test.go:440-475`).

E. Configuration safety: PASS. `usd_per_million_credits` remains non-negative validated with an explicit tested default (`phase4-coordinator/internal/config/config.go:502-510`, `config.go:1053-1058`, `phase4-coordinator/internal/stats/rollup/config.go:70-75`, `config.go:125-130`). `late_events_retention_days` defaults to 90, clamps `(0,30)` to 30 with warning, and rejects negative values (`phase4-coordinator/internal/stats/rollup/runner.go:50-63`, `phase4-coordinator/internal/config/config.go:1044-1051`). Backfill mode remains limited to `partial` or `full`, with `partial` failing closed if `partial_history_since` is missing or unparsable in the coordinator startup translation (`phase4-coordinator/cmd/coordinator/main.go:206-238`).

F. Provider-rewards-ledger handling: PASS. Round-4 incremental code uses `provider_rewards_ledger` only for active-provider discovery and provider-scoped rewards aggregation, both through `provider_tokens` joins (`phase4-coordinator/internal/stats/rollup/incremental.go:197-202`, `incremental.go:254-264`). Existing rewards usage remains limited to `rewards_populated`, rewards aggregation, and late-event rewards scans (`phase4-coordinator/internal/stats/rollup/rewards.go:47-54`, `phase4-coordinator/internal/stats/rollup/leaderboard.go:278-291`, `phase4-coordinator/internal/stats/rollup/late_events.go:81-99`). No UPDATE or INSERT to `provider_rewards_ledger` appears.

G. Process isolation: PASS. Per-tick panic recovery still catches a failed table job, logs only a type classification, writes redacted health failure context, and returns to that job's ticker loop (`phase4-coordinator/internal/stats/rollup/runner.go:136-211`). The classifier remains type-name only and is covered by a secret-shaped payload regression test (`runner.go:213-228`, `phase4-coordinator/internal/stats/rollup/rebuild_test.go:89-121`). The goroutine-level backstop remains defense-in-depth and does not crash the coordinator (`runner.go:150-160`).

## Findings

### LOW 1 - `late_events.go` still says incremental merge is deferred

Evidence:

- The newly added incremental path routes `leaderboard_30d` and `leaderboard_all` through `runLeaderboardIncrementalTick` after bootstrap (`phase4-coordinator/internal/stats/rollup/runner.go:92-105`).
- `runLeaderboardIncrementalTick` implements the expected lookback scan, active-provider recompute, drop-out deletion, rerank, health update, and late-event recording (`phase4-coordinator/internal/stats/rollup/incremental.go:15-91`, `incremental.go:94-179`).
- The integration test documents and compiles the new behavior: a T-60h row inserted after bootstrap lands in `stats_late_events`, stays out of the live 30d snapshot, and then appears after nightly Shape C rebuild (`phase4-coordinator/internal/stats/rollup_integration_test.go:1047-1167`).
- The `detectLateEvents` comment still says the v0.1 simplification defers incremental merge and cadence ticks still full-recompute the window (`phase4-coordinator/internal/stats/rollup/late_events.go:38-41`).

Risk:

This is not a role, identity, secret, or projection bug. The executable path and tests implement the intended incremental semantics. It is a LOW maintenance/security-review hazard because a future Step 3/4 or v0.2 modifier could rely on the stale comment and misunderstand when older-than-lookback corrections become visible.

Recommended fix:

Update the `detectLateEvents` comment to match the current contract: 30d/all cadence ticks use the incremental merge path after bootstrap, and `detectLateEvents` records older-than-lookback authenticated OLTP rows for nightly Shape C reconciliation.

## Positive Security Observations

- The r3 `leaderboard.go` LOW comment drift is fixed at `9297f0d`.
- The r4 SPEC section 9.3 incremental implementation did not reintroduce the r1 rewards-only trust-source bypass; both full and incremental rewards paths join `provider_tokens`.
- The r4 incremental implementation did not reintroduce the r2 blocked-stub suppression bug; `blocked_from_partner_projection` remains non-branching in v0.1.
- Same-origin uniformity is preserved: Step 2 storage computation still does not inspect Origin, Authorization, partner-key rows, or per-key input.
- Shape C remains the only rebuild shape in production code and stays within the locked `stats_rollup` grant set.

## Final Verdict

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 1
INFO: 0

READY TO LOCK.

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 4 meets the lock target. The lone LOW finding is comment drift only; it should be cleaned before the next implementation step, but it does not block the Step 2 security lock.
