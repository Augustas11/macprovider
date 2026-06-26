# SPEC-017 IMPL Step 2 CODE audit - round 6

Branch: `impl/spec-017-step-1` / PR #173  
HEAD audited: `f2e2415` (`impl(017): Step 2 - round-5 audit fixes (visibility seam, drift union, late-event GREATEST, Shape C content-equality)`)  
Prior round: `specs/SPEC-017-IMPL-STEP_2-code-r5-audit.md`  
Lens: CODE - query correctness, transaction boundaries, error handling, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts

- A. SQL correctness vs schema: **FAIL** - table column lists and Postgres-shape source columns are present, but bucket assignment is computed before the rollup rounds USD to the stored `NUMERIC(18,2)` value.
- B. Transaction boundaries: **PASS** - per-tick data writes and corresponding `stats_components_health` success updates are transaction-coupled; Shape C uses `sql.LevelReadCommitted`; late-event retention runs after rebuild commit.
- C. Concurrency: **PASS** - schedulers use `time.NewTicker`, stop on context cancellation, recover per tick, and serialize late-event anti-join insertion with an advisory lock.
- D. Drift detection + late events: **FAIL** - round-5 late-event `GREATEST(created_at_utc, updated_at_utc)` fix is present and tested, but the drift event payload still does not match the pinned structured-log field schema.
- E. rewards_populated: **PASS** - uses `EXISTS`, persists by `window_label`, and preserves empty-ledger false semantics.
- F. Bucket + left-join + provider identity: **FAIL** - provider-token joins and visibility defaults are present, but the bucket function is fed unrounded rational USD instead of the stored `NUMERIC(18,2)` value.
- G. Backfill + main.go integration: **PASS** - rollup starts only when `cfg.Stats.Enabled`, uses `shutdownCtx`, drains on shutdown, and maps partial/full backfill config into the rollup package.
- H. Tests: **FAIL** - round-5 Shape C content equality and updated-row late-event coverage are added, but bucket tests miss the sub-cent-to-boundary storage mismatch; integration-tag tests could not run locally because Docker/testcontainers is unavailable.

## Findings

### CRITICAL

- None.

### HIGH

1. `phase4-coordinator/internal/stats/rollup/leaderboard.go:196`
   - Evidence: `computeLeaderboardRows` computes `totalUSD := workUSD + rewardsUSD` and calls `Bucket(window, totalUSD)` before `insertLeaderboardRow` persists the same total with `r.EarningsTotalUSD.FloatString(2)` at `phase4-coordinator/internal/stats/rollup/leaderboard.go:516`. `Bucket` compares the unrounded rational against `$0.01`, `$5`, `$50`, etc. at `phase4-coordinator/internal/stats/rollup/bucket.go:32`. The test corpus even names a `$0.005` case at `phase4-coordinator/internal/stats/rollup/bucket_test.go:24`, but the helper at `bucket_test.go:116` truncates it to cents before calling `Bucket`, so the test does not exercise the real rollup value.
   - Why: SPEC §6.2 says bucket assignment compares against the stored `NUMERIC(18,2)` value. With the current code, credits that produce `$4.995` are written as `earnings_usd = 5.00` but bucketed as `$` because the pre-storage rational is still `< 5`; credits that produce `$0.005` are written as `0.01` but bucketed as `-`. That makes the public bucket disagree with the persisted earnings value at exact contract boundaries.
   - Fix: normalize work/reward/total USD to the same two-decimal value that will be stored before calling `Bucket` and before rank comparison, preferably by a shared helper that returns a `NUMERIC(18,2)`-equivalent `*big.Rat` plus the SQL string. Add tests for `$0.005 -> "$"` after storage rounding and `$4.995 -> "$$"` / `$49.995 -> "$$$"` on the 24h window.

### MEDIUM

1. `phase4-coordinator/internal/stats/rollup/rebuild.go:222`
   - Evidence: the drift event logs `event`, `window`, `axis`, `provider_id_sample`, `delta_ratio`, `rebuild_value`, `incremental_value`, and `threshold`. The pinned observability contract in `specs/BUILD_SPEC_017_IMPL_PROMPT.md:654` names `stats_rollup_drift_detected (component, axis, divergence_pct, rebuild_value, incremental_value)`, and the CODE audit checklist asks for `component=`, `axis=`, `delta=`, sample `provider_id`, and `window`.
   - Why: the event is per-axis and redacted, but downstream Step 4 alerting will have to special-case `window` to infer the component and `delta_ratio` to infer divergence. This is exactly the kind of first-writer structured-log shape future steps should not inherit silently.
   - Fix: add `component` (`leaderboard_30d` / `leaderboard_all`) and either rename or duplicate `delta_ratio` as `divergence_pct` or `delta` per the pinned schema. Keep `window`, `provider_id_sample`, `rebuild_value`, `incremental_value`, and `threshold` if useful.

### LOW

- None.

### INFO

- Round-5 HIGH is closed in code: late-event detection now filters on `GREATEST(lrc.created_at_utc, COALESCE(lrc.updated_at_utc, lrc.created_at_utc)) > $3` with a TIMESTAMPTZ `lastOK` parameter (`phase4-coordinator/internal/stats/rollup/late_events.go:76`), and `TestRollupLateEventUpdatedAtCorrection` covers the updated-row correction path (`phase4-coordinator/internal/stats/rollup_integration_test.go:1444`).
- Round-5 MEDIUM is closed in tests: Shape C post-commit equivalence now compares ranks, USD splits, tokens/jobs, and bucket against `ComputeLeaderboardRowsForTest` output (`phase4-coordinator/internal/stats/rollup_integration_test.go:642`).
- `go test -count=1 ./internal/stats/rollup ./internal/stats` passed.
- `go test -count=1 ./...` passed.
- `gofmt -l internal/stats/rollup internal/stats/rollup_integration_test.go cmd/coordinator/main.go internal/config/config.go` produced no output.
- `git diff --check origin/main...HEAD -- phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go phase4-coordinator/internal/config/config.go` passed.
- `go test -count=1 -tags integration -run 'TestRollupLateEventUpdatedAtCorrection|TestShapeCRebuild_MVCCNoEmptyState|TestRollupDriftFiresOnProviderDeletedByRebuild|TestRollupLateEventDetection' ./internal/stats` could not execute in this environment because testcontainers panicked with `rootless Docker not found`.

## Final Verdict

Counts: **0 CRITICAL / 1 HIGH / 1 MEDIUM / 0 LOW / 6 INFO**

Verdict: **NOT READY TO LOCK**.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 6 verifies the prior late-event and Shape C blockers are closed, but the Step 2 code is still blocked by bucket computation using pre-storage USD precision and by a drift-log payload that does not match the pinned structured schema.
