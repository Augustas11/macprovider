# SPEC-017 IMPL Step 2 CODE audit - round 7

Branch: `impl/spec-017-step-1` / PR #173  
HEAD audited: `a012fbd` (`round-6 CODE fixes committed`)  
Prior round: `specs/SPEC-017-IMPL-STEP_2-code-r6-audit.md`  
Lens: CODE - query correctness, transaction boundaries, error handling, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts

- A. SQL correctness vs schema: **PASS** - rollup writes full §9.1 column lists, uses Postgres-shape source names and TIMESTAMPTZ windows, keeps deterministic rank tie-breaks, and now rounds to `NUMERIC(18,2)` before bucket comparison and storage.
- B. Transaction boundaries: **PASS** - per-table data writes and `stats_components_health` success updates share transactions; Shape C uses `sql.LevelReadCommitted`; late-event retention runs only after rebuild commit.
- C. Concurrency: **PASS** - schedulers use `time.NewTicker`, stop on context cancellation, recover per tick without recursive restart loops, and isolate per-component failures.
- D. Drift detection + late events: **PASS** - drift comparison is per-axis over `pre ∪ rebuilt`, uses `max(rebuild, 1)`, and the structured log now includes `component` plus `divergence_pct`; late-event detection covers updated old rows and remains idempotent under an advisory lock.
- E. rewards_populated: **PASS** - uses `EXISTS`, writes `stats_rewards_populated.window_label`, and preserves false empty-ledger bootstrap semantics.
- F. Bucket + left-join + provider identity: **PASS** for implementation code - provider-token joins, visibility `LEFT JOIN` + `COALESCE` defaults, and pre-bucket cent rounding are present. Test corpus has a blocker listed below.
- G. Backfill + main.go integration: **PASS** - rollup starts only when stats are enabled, maps partial/full backfill into rollup config, uses `shutdownCtx`, and drains on shutdown.
- H. Tests: **FAIL** - unit coverage for the round-6 fixes exists and passes, but one required integration test still asserts the pre-fix bucket behavior for `$0.005`.

## Findings

### CRITICAL

- None.

### HIGH

1. `phase4-coordinator/internal/stats/rollup_integration_test.go:280`
   - Evidence: the round-7 implementation correctly rounds `$0.005` to `$0.01` before bucketing at `phase4-coordinator/internal/stats/rollup/leaderboard.go:200` and `phase4-coordinator/internal/stats/rollup/leaderboard.go:202`, and `TestRoundToCentsBucketBoundaries` pins `$0.005 -> "0.01" -> "$"` at `phase4-coordinator/internal/stats/rollup/bucket_test.go:139`. However, `TestRollupLeaderboard24hBucketsAndLeftJoin` seeds `p_tiny` with `5_000` credits (`$0.005`) at `phase4-coordinator/internal/stats/rollup_integration_test.go:245` and still expects `earnings_bucket = "-"` at `phase4-coordinator/internal/stats/rollup_integration_test.go:280`.
   - Why: SPEC §6.2 says bucket comparison uses the stored `NUMERIC(18,2)` value; after the round-6 fix, the stored value is `0.01`, so the expected bucket is `"$"`, not `"-"`. This stale integration assertion will fail in any environment that can run the `integration` tag and it leaves the required Step 2 integration corpus contradicting the lock-level bucket contract.
   - Fix: update the integration fixture/comment/assertion to expect `p_tiny` storage `earnings_usd = "0.01"` and `earnings_bucket = "$"`, or change that fixture to a strictly-below-half-cent value such as `4_000` credits if the test wants to keep a `"-"` case. Keep the existing `$4.99`, `$5.00`, `$49.99`, `$50.00`, and half-cent unit cases.

### MEDIUM

- None.

### LOW

- None.

### INFO

- Round-6 HIGH is closed in implementation code: `computeLeaderboardRows` rounds work, rewards, and total USD before `Bucket` and before storage (`phase4-coordinator/internal/stats/rollup/leaderboard.go:200`, `phase4-coordinator/internal/stats/rollup/leaderboard.go:202`, `phase4-coordinator/internal/stats/rollup/leaderboard.go:522`); the incremental path mirrors it (`phase4-coordinator/internal/stats/rollup/incremental.go:340`, `phase4-coordinator/internal/stats/rollup/incremental.go:342`, `phase4-coordinator/internal/stats/rollup/incremental.go:455`).
- Round-6 MEDIUM is closed: drift logs include `component` and `divergence_pct` at `phase4-coordinator/internal/stats/rollup/rebuild.go:233` and `phase4-coordinator/internal/stats/rollup/rebuild.go:237`, with unit coverage at `phase4-coordinator/internal/stats/rollup/rebuild_test.go:84` and `phase4-coordinator/internal/stats/rollup/rebuild_test.go:87`.
- `go test -count=1 ./internal/stats/rollup ./internal/stats` passed.
- `go test -count=1 ./...` passed.
- `gofmt -l internal/stats/rollup internal/stats/rollup_integration_test.go cmd/coordinator/main.go internal/config/config.go` produced no output.
- `git diff --check origin/main...HEAD -- phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go phase4-coordinator/internal/config/config.go` passed.
- `go test -count=1 -tags integration -run TestRollupLeaderboard24hBucketsAndLeftJoin ./internal/stats` could not reach the assertion locally because testcontainers panicked with `rootless Docker not found`; the stale assertion is source-evident.

## Final Verdict

Counts: **0 CRITICAL / 1 HIGH / 0 MEDIUM / 0 LOW / 6 INFO**

Verdict: **NOT READY TO LOCK**.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 7 verifies both prior implementation blockers are closed, but the Step 2 integration test suite still encodes the old bucket precision behavior and must be corrected before lock.
