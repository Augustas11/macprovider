# SPEC-017 IMPL Step 2 CODE audit - round 8

Branch: `impl/spec-017-step-1` / PR #173  
HEAD audited: `6fd71a5` (`round-7 CODE fix: stale bucket precision test expectation`)  
Prior round: `specs/SPEC-017-IMPL-STEP_2-code-r7-audit.md`  
Lens: CODE - query correctness, transaction boundaries, error handling, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts

- A. SQL correctness vs schema: **FAIL** - stats writes use full column lists and correct NUMERIC/TIMESTAMPTZ/BIGINT shapes, but source queries join raw `provider_tokens` rows and can multiply aggregates when a provider has revoked/reissued token history.
- B. Transaction boundaries: **PASS** - overview/timeseries/leaderboard writes update data and `stats_components_health` in the same transaction; Shape C uses `sql.LevelReadCommitted`; late-event retention runs after rebuild commit.
- C. Concurrency: **PASS** - per-component goroutines use `time.NewTicker`, stop on context cancellation, recover per tick, and keep rpm/tpm failures isolated.
- D. Drift detection + late events: **PASS** - drift detection is per axis over `pre union rebuilt`, uses `max(rebuild, 1)`, and logs structured component/window/axis/divergence fields; late-event inserts are serialized with an advisory lock and retention is separate from rebuild.
- E. rewards_populated: **PASS** - uses `EXISTS`, writes `stats_rewards_populated.window_label`, and preserves false empty-ledger bootstrap semantics.
- F. Bucket + left-join + provider identity: **FAIL** - bucket precision and visibility defaults are correct, and round 7 closed the stale `p_tiny` test, but provider identity joins must collapse `provider_tokens` to distinct provider IDs before joining OLTP rows.
- G. Backfill + main.go integration: **PASS** - rollup starts only when `stats.enabled` opens the stats pools, maps partial/full backfill into rollup config, uses `shutdownCtx`, and drains on shutdown.
- H. Tests: **FAIL** - required coverage is broad, but the `provider_tokens` integration stub has `provider_id` as a primary key and cannot catch the raw-join multiplication bug present against the actual auth schema.

## Findings

### CRITICAL

- None.

### HIGH

1. `phase4-coordinator/internal/stats/rollup/overview.go:124`, `phase4-coordinator/internal/stats/rollup/timeseries.go:38`, `phase4-coordinator/internal/stats/rollup/timeseries.go:126`, `phase4-coordinator/internal/stats/rollup/leaderboard.go:285`, `phase4-coordinator/internal/stats/rollup/leaderboard.go:336`, `phase4-coordinator/internal/stats/rollup/incremental.go:274`, `phase4-coordinator/internal/stats/rollup/incremental.go:300`, `phase4-coordinator/internal/stats/rollup/late_events.go:73`
   - Evidence: each rollup query joins source rows with raw `provider_tokens pt ON pt.provider_id = ...`. The actual auth table is `id INTEGER PRIMARY KEY`, `token_hash UNIQUE`, `provider_id`, `revoked_at` (`phase4-coordinator/internal/auth/tokens.go:247`), and it enforces only one **unrevoked** token per provider via a partial unique index (`phase4-coordinator/internal/auth/tokens.go:375`). Revoked historical rows for the same provider remain valid table rows. The Step 2 integration stub masks this by declaring `provider_tokens(provider_id TEXT PRIMARY KEY)` (`phase4-coordinator/internal/stats/rollup_integration_test.go:85`).
   - Why: after any provider-token revocation/reissue history, one ledger row can join N token rows for the same provider. That inflates overview token/request totals, rpm/tpm buckets, leaderboard earnings/tokens/jobs, incremental recomputes, rewards totals, and late-event rows. This is SQL correctness against the required auth schema, and it ships wrong public stats once normal token lifecycle creates duplicate historical `provider_id` rows.
   - Fix: do not join raw `provider_tokens`. Join against a distinct authenticated provider-ID relation, e.g. `JOIN (SELECT DISTINCT provider_id FROM provider_tokens WHERE provider_id <> '') pt ON pt.provider_id = lrc.provider_id` (or add `revoked_at IS NULL` only if the intended policy is current-active providers rather than authenticated-ever historical rows). Apply the same relation in work, rewards, timeseries, overview, incremental, visibility-load, and late-event paths. Update the integration fixture to match the real table shape (`id`, `revoked_at`, partial active uniqueness) and add a regression that seeds one active plus one revoked token for the same provider and asserts aggregates are not doubled.

### MEDIUM

- None.

### LOW

- None.

### INFO

- Round-7 HIGH is closed: `TestRollupLeaderboard24hBucketsAndLeftJoin` now seeds `p_tiny` with `4_000` credits (`$0.004`) and keeps the `"-"` expectation coherent with the round-6 stored-`NUMERIC(18,2)` bucket precision fix (`phase4-coordinator/internal/stats/rollup_integration_test.go:242` and `phase4-coordinator/internal/stats/rollup_integration_test.go:249`).
- Shape C source review: `runNightlyRebuild` computes rebuilt rows, starts `BeginTx` with `sql.LevelReadCommitted`, performs DELETE+INSERT for both `30d` and `all`, updates the matching health rows inside the same transaction, commits, then runs late-event retention separately (`phase4-coordinator/internal/stats/rollup/rebuild.go:54`, `phase4-coordinator/internal/stats/rollup/rebuild.go:70`, `phase4-coordinator/internal/stats/rollup/rebuild.go:78`, `phase4-coordinator/internal/stats/rollup/rebuild.go:83`, `phase4-coordinator/internal/stats/rollup/rebuild.go:97`).
- Verification passed: `go test -count=1 ./internal/stats/rollup ./internal/stats`.
- Verification passed: `go test -count=1 ./...`.
- Verification passed: `go test -count=1 -run 'TestDepguardForbiddenImportRule|TestForbidigoOSExitRule' ./internal/stats`.
- Verification passed: `make lint-coordinator` (`golangci-lint run --config=.golangci.yml ./...`) reported `0 issues`.
- Verification passed: `gofmt -l internal/stats/rollup internal/stats/rollup_integration_test.go cmd/coordinator/main.go internal/config/config.go` produced no output.
- Verification passed: `git diff --check origin/main...HEAD -- phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go phase4-coordinator/internal/config/config.go`.
- Verification blocked locally: `go test -count=1 -tags integration -run 'TestRollupLeaderboard24hBucketsAndLeftJoin|TestShapeCRebuild_FailedRollback|TestShapeCRebuild_MVCCNoEmptyState|TestRollupDriftDetectedAndRebuildWins|TestRollupLateEventsRetention' ./internal/stats` panicked before assertions with `rootless Docker not found` from testcontainers.

## Final Verdict

Counts: **0 CRITICAL / 1 HIGH / 0 MEDIUM / 0 LOW / 9 INFO**

Verdict: **NOT READY TO LOCK**.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 8 verifies the round-7 bucket test blocker is closed, but Step 2 still has a HIGH query-correctness bug: raw `provider_tokens` joins can multiply rollup aggregates under normal provider-token revocation/reissue history.
