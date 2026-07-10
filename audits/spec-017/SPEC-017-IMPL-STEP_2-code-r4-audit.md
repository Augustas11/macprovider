# SPEC-017 IMPL Step 2 CODE audit - round 4

Branch: `impl/spec-017-step-1` / PR #173
HEAD audited: `80377fe` (`impl(017): Step 2 - round-4 audit fixes (aging-out + stale-comment cleanup)`)
Prior round: `specs/SPEC-017-IMPL-STEP_2-code-r3-audit.md`
Lens: CODE - SQL correctness, transaction boundaries, error handling, idempotency, idiomatic Go, dependency hygiene, test adequacy.

Note: the branch advanced from round-3 fix `a70d75a` to `80377fe` while this audit was in progress; findings below reference current HEAD line numbers.

## Category Verdicts

- A. SQL correctness vs schema: **FAIL** - reward-only rows created by full recompute still have `last_seen_at = NULL`, which the incremental 30d path treats as a drop-out.
- B. Transaction boundaries: **PASS** - per-tick writes and health updates are transaction-coupled; Shape C uses `sql.LevelReadCommitted`; retention remains post-commit.
- C. Concurrency: **PASS with caveat** - tickers use `time.NewTicker` and stop on context cancellation; late-event duplicate insertion is serialized by advisory lock.
- D. Drift detection + late events: **FAIL** - late-event detection records old source rows by event timestamp alone, not by "arrived after last processed" semantics.
- E. rewards_populated: **PASS** - uses `EXISTS`, `window_label`, and false bootstrap semantics.
- F. Bucket + left-join + provider identity: **PASS** - provider-token joins and deterministic bucket/rank paths are present; v0.1 no longer branches on `blocked_from_partner_projection`.
- G. Backfill + main.go integration: **PASS** - rollup starts only with stats pools, uses `shutdownCtx`, and drains after cancellation.
- H. Tests: **FAIL** - Shape C rollback/equivalence tests still compare counts/provider sets rather than full row snapshots.

## Findings

### CRITICAL

- None.

### HIGH

1. `phase4-coordinator/internal/stats/rollup/leaderboard.go:184` and `phase4-coordinator/internal/stats/rollup/incremental.go:378`
   - Evidence: the full recompute path unions work and rewards providers, but `aggregateRewardsPerProvider` returns only `amount` (`leaderboard.go:283-309`). `computeLeaderboardRows` then writes `FirstSeenAt: w.firstSeen` and `LastSeenAt: w.lastSeen` (`leaderboard.go:197-207`), so a rewards-only provider gets persisted with `last_seen_at = NULL` via `insertLeaderboardRow` (`leaderboard.go:436-460`). The incremental drop-out query now selects `last_seen_at IS NULL` as a delete candidate (`incremental.go:378-381`) and deletes it unless the provider is in the active update set (`incremental.go:394-395`). Bootstrap and nightly rebuild both use the full recompute path, so the current incremental-side rewards timestamp fix does not protect reward-only rows inserted by those paths.
   - Why: a valid rewards-only provider inside the 30d window can disappear on the next incremental tick even though its `provider_rewards_ledger.unix_ts` is still in `[window_start, now)`. This violates the 30d windowed leaderboard contract and makes the live snapshot disagree with the next nightly rebuild.
   - Fix: make the full recompute path carry rewards min/max timestamps too, and populate `first_seen_at` / `last_seen_at` from work OR rewards before insert. Add an integration test that seeds a rewards-only provider inside 30d, runs bootstrap, runs a subsequent incremental tick with no new activity, and asserts the row remains until the rewards timestamp actually ages out.

2. `phase4-coordinator/internal/stats/rollup/late_events.go:60`
   - Evidence: `detectLateEvents` inserts any work row with `EXTRACT(EPOCH FROM lrc.ts_utc) < cutoff` and inside the window (`late_events.go:60-77`), and any rewards row with `prl.unix_ts < cutoff` (`late_events.go:82-99`). It does not filter by an arrival/update watermark such as `ledger_request_credits.created_at_utc` / `updated_at_utc` from SPEC-005 (`phase4-coordinator/internal/billing/store.go:71-72`), nor does it receive the prior `last_ok_at`. The test only inserts the T-60h row after bootstrap (`rollup_integration_test.go:1089-1094`), so it misses ordinary historical T-60h rows that were already included by a full recompute.
   - Why: `stats_late_events` is supposed to capture corrections that arrive after a snapshot and are older than the lookback. The current query records old history solely because the event timestamp is old. On bootstrap, after downtime, or after any full recompute, normal historical rows can be logged as "late", bloating the forensic table and making operator drift diagnosis unreliable.
   - Fix: gate late-event candidates by "first observed or updated after the previous successful tick" using a Postgres mirror of `created_at_utc` / `updated_at_utc`, a monotonic source-row watermark, or another explicit arrival signal. Do not run late-event detection for bootstrap rows already folded into the full recompute. Add tests for both cases: T-60h present before bootstrap is not recorded as late, while T-60h inserted/updated after last_ok is recorded.

### MEDIUM

1. `phase4-coordinator/internal/stats/rollup_integration_test.go:470`
   - Evidence: `TestShapeCRebuild_FailedRollback` snapshots only `COUNT(*)` before and after the failed rebuild (`rollup_integration_test.go:470-507`). `TestShapeCRebuild_MVCCNoEmptyState` checks the post-commit count and then only the committed `provider_id` set (`rollup_integration_test.go:590-633`).
   - Why: BUILD Step 2 requires failed-rebuild rollback, MVCC no-empty-state, and post-commit equivalence. Count/provider-set checks can pass while ranks, earnings, tokens, jobs, buckets, or timestamps are wrong. That still under-proves the first Postgres write pattern Step 3 will inherit.
   - Fix: capture ordered full row snapshots for R0 and R1 using all leaderboard columns that participate in the contract, compare R0 before/after failed rollback, and compare the committed R1 rows exactly against the rebuilt source query after successful Shape C commit.

### LOW

1. `phase4-coordinator/internal/stats/rollup/incremental.go`
   - Evidence: `gofmt -l phase4-coordinator/internal/stats/rollup/incremental.go ...` reports `phase4-coordinator/internal/stats/rollup/incremental.go`.
   - Why: the current local change is not gofmt-clean. This is not a behavior bug, but it should be fixed before lock.
   - Fix: run `gofmt` on `incremental.go` after the active incremental changes settle.

### INFO

- `cd phase4-coordinator && go test ./internal/stats/rollup ./internal/stats` passed.
- `cd phase4-coordinator && go test ./...` passed.
- `cd phase4-coordinator && go test -tags integration -c ./internal/stats` passed.
- `cd phase4-coordinator && go test -tags integration -run TestRollupOverviewTick ./internal/stats` could not execute locally because testcontainers panicked with `rootless Docker not found`.
- `git diff --check -- phase4-coordinator/internal/stats/rollup/incremental.go phase4-coordinator/internal/stats/rollup/late_events.go phase4-coordinator/internal/stats/rollup_integration_test.go` passed.

## Final Verdict

Counts: **0 CRITICAL / 2 HIGH / 1 MEDIUM / 1 LOW / 5 INFO**

Verdict: **NOT READY TO LOCK**.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 4 is blocked by reward-only 30d rows being deleted after full recompute, late-event detection over-recording old history as late corrections, and Shape C tests still under-proving full rollback/equivalence.
