# SPEC-017 IMPL Step 2 CODE audit - round 5

Branch: `impl/spec-017-step-1` / PR #173  
HEAD audited: `a3844aa` (`impl(017): Step 2 - round-4 audit fixes (rewards last_seen + late-event watermark)`)  
Prior round: `specs/SPEC-017-IMPL-STEP_2-code-r4-audit.md`  
Lens: CODE - SQL correctness, transaction boundaries, error handling, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts

- A. SQL correctness vs schema: **PASS** - full stats table column lists, effective-token semantics, deterministic rank tie-breaks, provider-token joins, and `[start,end)` leaderboard/timeseries bounds are present.
- B. Transaction boundaries: **PASS** - per-tick data writes and health updates are transaction-coupled; Shape C uses `sql.LevelReadCommitted`; late-event retention runs after rebuild commit.
- C. Concurrency: **PASS** - per-table schedulers use `time.NewTicker`, stop on context cancellation, recover panics per tick, and serialize late-event anti-join inserts with an advisory lock.
- D. Drift detection + late events: **FAIL** - per-axis drift math is correct, but late-event detection misses updates to existing old billing rows because it keys arrival only on `created_at_utc`.
- E. rewards_populated: **PASS** - uses `EXISTS`, persists by `window_label`, and preserves empty-ledger false semantics.
- F. Bucket + left-join + provider identity: **PASS** - bucket logic is pure/tested, no-row visibility defaults are covered, v0.1 no longer branches on `blocked_from_partner_projection`, and rollup sources authenticated providers through `provider_tokens`.
- G. Backfill + main.go integration: **PASS** - rollup starts only with `cfg.Stats.Enabled`, uses `shutdownCtx`, drains on shutdown, and maps partial/full backfill config into the rollup package.
- H. Tests: **FAIL** - required integration breadth is much improved, but Shape C post-commit equivalence is still provider-set-only rather than exact rebuilt-row equality; the late-event suite also lacks the SPEC-005 update-correction path.

## Findings

### CRITICAL

- None.

### HIGH

1. `phase4-coordinator/internal/stats/rollup/late_events.go:72`
   - Evidence: late-event detection records work rows only when `EXTRACT(EPOCH FROM lrc.created_at_utc) > $3`. The SPEC-005 ledger shape also has `updated_at_utc` for corrected existing rows (`phase4-coordinator/internal/billing/store.go:71-72`), but the rollup integration stub includes only `created_at_utc` (`phase4-coordinator/internal/stats/rollup_integration_test.go:75`) and no test updates an old row after `last_ok_at`.
   - Why: SPEC §9.3 is about billing-row corrections arriving after a snapshot. A common correction shape is "old row updated after last_ok_at", not only "new old-timestamp row inserted after last_ok_at". Current code misses an updated T-60h billing row, so it neither folds into the incremental live snapshot nor lands in `stats_late_events`; operators lose the forensic late-event signal until nightly rebuild drift is noticed.
   - Fix: mirror `updated_at_utc` into the Postgres OLTP shape and filter on an arrival watermark such as `GREATEST(lrc.created_at_utc, COALESCE(lrc.updated_at_utc, lrc.created_at_utc)) > $last_ok_at` using a TIMESTAMPTZ parameter, not truncated Unix seconds. Add an integration test where a T-60h row exists before bootstrap, is updated after `last_ok_at`, remains out of the live incremental snapshot, and is inserted once into `stats_late_events`.

### MEDIUM

1. `phase4-coordinator/internal/stats/rollup_integration_test.go:641`
   - Evidence: the Shape C success test claims "post-commit equivalence is per-provider content-equality", but lines 646-674 build an expected provider-id set and query only `SELECT provider_id FROM stats_leaderboard_all`. It does not compare ranks, earnings, token/job totals, bucket, pseudonym, or first/last seen values against the rebuilt R1 snapshot.
   - Why: BUILD Step 2 H.2 requires post-commit equivalence, not just no-empty-state plus provider membership. A rebuild that commits the right providers with wrong `rank_*`, `earnings_*`, `tokens`, `jobs`, or `earnings_bucket` would still pass this test, leaving the first Postgres Shape C write pattern under-proved.
   - Fix: after the successful rebuild, build the expected R1 row set from the OLTP fixture or from `computeLeaderboardRows` through a test seam, then compare every contract column from `stats_leaderboard_all ORDER BY provider_id`. Keep the existing count-polling MVCC assertion, but make equivalence a full-row assertion.

### LOW

- None.

### INFO

- Round-4 reward-only row loss is fixed in code: full recompute now carries rewards `MIN/MAX(unix_ts)` into `first_seen_at` / `last_seen_at`, and the incremental provider path also combines rewards `last_unix_ts`.
- `go test -count=1 ./internal/stats/rollup ./internal/stats` passed.
- `go test ./...` passed.
- `gofmt -l` over the Step 2 touched Go paths produced no output.
- `git diff --check origin/main...HEAD -- phase4-coordinator/internal/stats phase4-coordinator/cmd/coordinator/main.go phase4-coordinator/internal/config/config.go` passed.
- `go test -tags integration -run 'TestRollup|TestShapeC' ./internal/stats` could not execute in this environment because testcontainers panicked with `rootless Docker not found`.

## Final Verdict

Counts: **0 CRITICAL / 1 HIGH / 1 MEDIUM / 0 LOW / 6 INFO**

Verdict: **NOT READY TO LOCK**.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 5 is blocked by the late-event watermark missing `updated_at_utc` corrections and by Shape C post-commit equivalence still being provider-set-only rather than exact rebuilt-row equality.
