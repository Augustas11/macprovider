# SPEC-017 IMPL Step 2 CODE audit - round 10

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `7bf90d0` (`impl(017): Step 2 - round-9 CODE fixes (incremental rewards first_seen parity + gofmt)`)
Prior round: `specs/SPEC-017-IMPL-STEP_2-code-r9-audit.md`
Lens: CODE - query correctness, transaction boundaries, error handling, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts

- A. SQL correctness vs schema: **PASS** - INSERT column lists match the locked stats schemas; leaderboard/timeseries windows use half-open bounds; ranks tie-break deterministically by `provider_id`; the round-9 incremental rewards `first_seen_at` gap is closed.
- B. Transaction boundaries: **PASS** - data writes and `stats_components_health` success updates remain in the same transaction; Shape C rebuild uses explicit `sql.LevelReadCommitted`; late-event retention stays after rebuild commit.
- C. Concurrency: **PASS** - component goroutines are started once, use `time.NewTicker`, stop on shutdown context cancellation, and recover per tick without unbounded restart recursion.
- D. Drift detection + late events: **PASS** - drift is emitted per axis over `pre union rebuilt`, late-event insertion remains idempotent under an advisory lock, and retention is a separate retryable DELETE.
- E. rewards_populated: **PASS** - the rollup uses `EXISTS`, writes `stats_rewards_populated.window_label`, and preserves the empty-ledger `false` default.
- F. Bucket + left-join + provider identity: **PASS** - bucket computation is pure and tested; rollup queries use authenticated provider IDs through the distinct `provider_tokens` relation; provider visibility defaults are loaded via a left join.
- G. Backfill + main.go integration: **PASS** - rollup startup is gated on `stats.enabled`, maps partial/full config into rollup config, uses `shutdownCtx`, and drains on shutdown.
- H. Tests: **PASS** - unit/static coverage passes locally; the new round-9 regression test covers incremental rewards `first_seen_at` parity. Postgres integration tests remain locally blocked by unavailable rootless Docker, same as round 9.

## Findings

### CRITICAL

- None.

### HIGH

- None.

### MEDIUM

- None.

### LOW

- None.

### INFO

- Round-9 MEDIUM is closed in code: `computeLeaderboardRowForProvider` now selects both `MIN(prl.unix_ts)` and `MAX(prl.unix_ts)` for rewards (`phase4-coordinator/internal/stats/rollup/incremental.go:305`) and merges rewards first/last timestamps with work first/last using earliest-first and latest-last semantics (`phase4-coordinator/internal/stats/rollup/incremental.go:329`).
- Round-9 MEDIUM is closed in tests: `TestRollupIncrementalRewardsFirstSeenParity` seeds three rewards rows, runs bootstrap plus an incremental tick, and asserts `first_seen_at` remains the earliest reward timestamp while `last_seen_at` remains the latest (`phase4-coordinator/internal/stats/rollup_integration_test.go:1662`).
- Round-9 LOW is closed: `gofmt -l phase4-coordinator/internal/stats/rollup phase4-coordinator/internal/stats/rollup_integration_test.go phase4-coordinator/cmd/coordinator/main.go phase4-coordinator/internal/config/config.go` produced no output.
- Shape C remains conforming: nightly rebuild computes rows before the transaction, begins with `sql.LevelReadCommitted`, DELETE+INSERTs both 30d and all leaderboards plus health updates in one transaction, commits once, then runs late-event retention separately (`phase4-coordinator/internal/stats/rollup/rebuild.go:31`).
- Verification passed: `go test -count=1 ./internal/stats/rollup ./internal/stats`.
- Verification passed: `go test -count=1 ./...`.
- Verification passed: `go test -count=1 -run 'TestDepguardForbiddenImportRule|TestForbidigoOSExitRule' ./internal/stats`.
- Verification passed: `make lint-coordinator` (`golangci-lint run --config=.golangci.yml ./...`) reported `0 issues`.
- Verification passed: `git diff --check origin/main...HEAD -- phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go phase4-coordinator/internal/config/config.go`.
- Verification blocked locally: `go test -count=1 -tags integration -run 'TestRollupIncrementalRewardsFirstSeenParity|TestRollupNoMultiplicationOnRevokedTokenHistory|TestShapeCRebuild_FailedRollback|TestShapeCRebuild_MVCCNoEmptyState|TestRollupDriftDetectedAndRebuildWins|TestRollupLateEventsRetention' ./internal/stats` panicked before assertions with `rootless Docker not found` from testcontainers.

## Final Verdict

Counts: **0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 10 INFO**

Verdict: **READY TO LOCK**.

Round 10 verifies the round-9 CODE finding and gofmt issue are closed. No CRITICAL, HIGH, or MEDIUM CODE findings remain.
