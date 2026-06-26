# SPEC-017 IMPL Step 2 CODE audit - round 9

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `9704ac2` (`impl(017): Step 2 - round-8 CODE fix (raw provider_tokens JOIN multiplied aggregates under revoke/reissue history)`)
Prior round: `specs/SPEC-017-IMPL-STEP_2-code-r8-audit.md`
Lens: CODE - query correctness, transaction boundaries, error handling, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts

- A. SQL correctness vs schema: **FAIL** - the round-8 raw `provider_tokens` multiplication bug is closed, but the 30d/all incremental provider recompute now still loses rewards-side `MIN(unix_ts)` and can overwrite `first_seen_at` with a later timestamp.
- B. Transaction boundaries: **PASS** - overview, timeseries, full leaderboard ticks, incremental leaderboard updates, and Shape C rebuild keep data writes plus health updates in the same transaction; retention remains post-commit.
- C. Concurrency: **PASS** - per-component goroutines are started once, use `time.NewTicker`, stop tickers on context cancellation, and recover per tick without sharing mutable query state.
- D. Drift detection + late events: **PASS** - drift remains per-axis over `pre union rebuilt`, logs structured component/window/axis/value fields, and late-event retention is a separate retryable DELETE after rebuild commit.
- E. rewards_populated: **PASS** - the rollup uses `EXISTS`, persists by `window_label`, and preserves the empty-ledger `false` default.
- F. Bucket + left-join + provider identity: **PASS** - all rollup query sites now join through a distinct authenticated provider relation; the test stub mirrors the real auth schema with revoked rows and a regression for one active plus two revoked tokens.
- G. Backfill + main.go integration: **PASS** - rollup startup remains gated on `stats.enabled`, partial/full config is mapped into rollup config, `shutdownCtx` controls cancellation, and shutdown drains the runner.
- H. Tests: **FAIL** - broad unit/integration coverage exists and the round-8 regression test was added, but no test covers incremental rewards `first_seen_at` parity with the full recompute path.

## Findings

### CRITICAL

- None.

### HIGH

- None.

### MEDIUM

1. `phase4-coordinator/internal/stats/rollup/incremental.go:296`
   - Evidence: the incremental 30d/all provider-scoped rewards query selects only `COALESCE(SUM(prl.amount_usd), 0)` and `MAX(prl.unix_ts)` (`incremental.go:296-304`). The full recompute path selects both `MIN(prl.unix_ts)` and `MAX(prl.unix_ts)` (`leaderboard.go:330-339`) and explicitly chooses the earliest work-or-rewards timestamp for `FirstSeenAt` (`leaderboard.go:216-223`). The incremental path then sets `w.firstSeen` to the rewards max timestamp only when there is no work timestamp (`incremental.go:324-332`), and never compares a rewards min timestamp against an existing work first timestamp.
   - Why: after the initial bootstrap or nightly Shape C rebuild writes a correct row, any later 30d/all incremental update for that provider can overwrite `first_seen_at` with the latest rewards timestamp for rewards-only providers, or fail to preserve an earlier rewards timestamp for mixed work+rewards providers. Step 3 inherits `first_seen_at` from the rollup storage for the partner-key projection, so the row is internally inconsistent until the next nightly rebuild.
   - Fix: make `computeLeaderboardRowForProvider` mirror the full recompute semantics: select both `MIN(prl.unix_ts)` and `MAX(prl.unix_ts)`, compare rewards min against `w.firstSeen`, compare rewards max against `w.lastSeen`, and persist those merged values. Add an integration regression that seeds multiple rewards rows plus a later incremental-triggering row, runs bootstrap then incremental update, and asserts `first_seen_at` remains the earliest work-or-rewards timestamp.

### LOW

1. `phase4-coordinator/internal/stats/rollup_integration_test.go:1573`
   - Evidence: `gofmt -l internal/stats/rollup internal/stats/rollup_integration_test.go cmd/coordinator/main.go internal/config/config.go` prints `internal/stats/rollup_integration_test.go`. `gofmt -d internal/stats/rollup_integration_test.go` shows the only delta is doc-comment formatting around the SQL fragment comment at lines 1573-1574.
   - Why: this is not a runtime bug and `make lint-coordinator` still reports `0 issues`, but Step 2 had previously been clean under the same gofmt smoke.
   - Fix: adjust or shorten that comment so `gofmt -l` is empty again.

### INFO

- Round-8 HIGH is closed in code: `authenticatedProvidersRelation` collapses `provider_tokens` to `SELECT DISTINCT provider_id FROM provider_tokens WHERE provider_id <> ''` (`phase4-coordinator/internal/stats/rollup/oltp_tokens.go:51-76`), and the rollup code has no raw `JOIN provider_tokens` query site left outside comments.
- Round-8 HIGH is closed in tests: the integration stub now uses `id BIGSERIAL PRIMARY KEY`, `token_hash UNIQUE`, `provider_id`, `revoked_at`, and a partial active-provider unique index (`phase4-coordinator/internal/stats/rollup_integration_test.go:93-102`); `TestRollupNoMultiplicationOnRevokedTokenHistory` seeds one active plus two revoked token rows and asserts leaderboard and overview aggregates are not multiplied (`phase4-coordinator/internal/stats/rollup_integration_test.go:1577-1652`).
- Shape C source review remains conforming: `runNightlyRebuild` computes rows before the transaction, begins with `sql.LevelReadCommitted`, performs DELETE+INSERT and health updates in one transaction for both 30d and all, commits once, then runs late-event retention separately (`phase4-coordinator/internal/stats/rollup/rebuild.go:31-100`).
- Verification passed: `go test -count=1 ./internal/stats/rollup ./internal/stats`.
- Verification passed: `go test -count=1 ./...`.
- Verification passed: `go test -count=1 -run 'TestDepguardForbiddenImportRule|TestForbidigoOSExitRule' ./internal/stats`.
- Verification passed: `make lint-coordinator` (`golangci-lint run --config=.golangci.yml ./...`) reported `0 issues`.
- Verification passed: `git diff --check origin/main...HEAD -- phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go phase4-coordinator/internal/config/config.go`.
- Verification blocked locally: `go test -count=1 -tags integration -run 'TestRollupNoMultiplicationOnRevokedTokenHistory|TestShapeCRebuild_FailedRollback|TestShapeCRebuild_MVCCNoEmptyState|TestRollupDriftDetectedAndRebuildWins|TestRollupLateEventsRetention' ./internal/stats` panicked before assertions with `rootless Docker not found` from testcontainers.

## Final Verdict

Counts: **0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 9 INFO**

Verdict: **NOT READY TO LOCK**.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 9 verifies the round-8 provider-token multiplication bug is closed, but Step 2 still has one MEDIUM query-correctness gap in the incremental rewards timestamp path.
