# SPEC-017 IMPL Step 2 CODE audit — round 1

Branch: `impl/spec-017-step-1`  
Diff audited: `b499327..HEAD` (`7e28ec2`)  
Lens: CODE — SQL correctness, transaction boundaries, error handling, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts

- A. SQL correctness vs schema: **FAIL** — leaderboard window queries lack exclusive upper bounds and normal work-only providers panic before insert.
- B. Transaction boundaries: **FAIL** — Shape C uses a transaction, but per-row leaderboard timestamps diverge from the transaction/tick health timestamp.
- C. Concurrency: **FAIL** — panic recovery logs and exits the goroutine; it does not restart the per-table scheduler.
- D. Drift detection + late events: **FAIL** — drift comparison exists, but the required late-event insertion path is explicitly skipped.
- E. rewards_populated: **PASS with coverage caveat** — uses `EXISTS` and `window_label`; not coupled transactionally to leaderboard ticks, but Step 1 chose lookup-table storage.
- F. Bucket + left-join + provider identity: **FAIL** — provider-token join exists, bucket function is pure, but the visibility "left-join" is loaded and discarded rather than shaping persisted rows.
- G. Backfill + main.go integration: **PASS with caveat** — rollup starts only when stats pools are opened from `cfg.Stats.Enabled`; live snapshot provider remains zero-stubbed.
- H. Tests: **FAIL** — required integration assertions are missing/overclaimed, and local integration execution is blocked by missing rootless Docker.

## Findings

### CRITICAL

1. `phase4-coordinator/internal/stats/rollup/leaderboard.go:134`
   - Evidence: `computeLeaderboardRows` unions `work` and `rewards` provider IDs, then does `r := rewards[pid]` and `rewardsUSD := r.amount`; for a provider with work rows and no `provider_rewards_ledger` row, the zero-value `rewardsAgg.amount` is `nil`. Line 139 calls `new(big.Rat).Add(workUSD, rewardsUSD)`, which panics on that nil operand.
   - Why: Empty rewards ledger is the v0.1 cutover default per SPEC §9.1a, so normal production work-only providers can kill every leaderboard tick. The runner's panic handler then exits that job goroutine, so the component stops ticking.
   - Fix: Default missing reward aggregates to `big.NewRat(0, 1)` before arithmetic, and add an integration/unit test with work rows plus an empty rewards ledger that proves all four leaderboard windows populate and health advances.

2. `phase4-coordinator/internal/stats/rollup/late_events.go:10`
   - Evidence: The file states v0.1 "does NOT proactively INSERT" into `stats_late_events`; `recordLateEvent` is only a future helper and has no caller. The required H.3 scenario (`T-60h lands in stats_late_events`) is not implemented.
   - Why: SPEC §9.3 requires 30d/all late events older than the 48h lookback to be recorded in `stats_late_events` for nightly reconciliation/forensics. An implementation-authored v0.2 deferral cannot override locked v0.1 Step 2 behavior.
   - Fix: Implement the 30d/all late-event detection path using `LateEventsLookbackHours`, call `recordLateEvent` for older corrections, and add the required T-30h/T-60h integration test.

### HIGH

1. `phase4-coordinator/internal/stats/rollup/leaderboard.go:174`
   - Evidence: `aggregateWorkPerProvider` filters only `EXTRACT(EPOCH FROM lrc.ts_utc) >= $1`; `aggregateRewardsPerProvider` likewise filters only `unix_ts >= $1`. Neither accepts or applies the tick's `now` as an exclusive upper bound.
   - Why: SPEC §6.2 and the audit prompt require bucket/window semantics of `[a, b)`. These queries can include future-dated rows or rows inserted with timestamps after the tick boundary, while `rewards_populated` correctly uses `unix_ts < end`. That creates inconsistent snapshots and wrong ranks.
   - Fix: Pass `now`/`endUnix` into both aggregate queries and filter `lrc.ts_utc >= window_start AND lrc.ts_utc < tick_now`, `unix_ts >= window_start AND unix_ts < tick_now`. Add boundary tests for rows exactly at lower bound, exactly at upper bound, and future rows.

2. `phase4-coordinator/internal/stats/rollup/runner.go:135`
   - Evidence: `spawnTick` has a single outer `defer recover`; after a panic it logs and optionally calls `healthFail`, then the goroutine returns. There is no loop that recreates the ticker or continues to the next interval.
   - Why: SPEC §9.6 says a panic should be recovered and the job scheduler for that table restarted. Current behavior turns any panic into a permanent per-component outage until process restart.
   - Fix: Move panic recovery inside the per-tick execution path or wrap the ticker loop in a bounded restart loop. Ensure panic tests prove later ticks still run and `stats_components_health.generated_at` advances after recovery.

3. `phase4-coordinator/internal/stats/rollup/leaderboard.go:375`
   - Evidence: `runLeaderboardTick` captures `now` and writes health with that timestamp, but `insertLeaderboardRow` calls `time.Now().UTC()` independently for every row's `generated_at`.
   - Why: SPEC §5.2 requires the response `generated_at` to match `stats_leaderboard_<window>.generated_at` for the requested window. A single snapshot table can contain many `generated_at` values, none guaranteed to equal `stats_components_health.generated_at`, making Step 3's handler/ETag/staleness behavior nondeterministic.
   - Fix: Pass the tick/rebuild timestamp into `insertLeaderboardRow` and use the same value for every row and the corresponding health update. Add an assertion that each leaderboard table has exactly one `generated_at` per tick and that it equals the component health row.

4. `phase4-coordinator/internal/stats/rollup_integration_test.go:10`
   - Evidence: The test header claims coverage for RPM/TPM failure isolation and drift alerting, but the file only defines tests through `TestRollupIgnoresUnauthenticatedProviders`; `rg` shows no `Test*Drift`, no RPM/TPM test, and no late-event insertion test.
   - Why: Required Step 2 tests H.1, H.3, H.5, and H.10 are absent, and the existing tests would have caught the nil rewards panic if the Docker-backed suite had been runnable. Overclaimed coverage is especially risky here because Step 2 sets the first Postgres write patterns.
   - Fix: Add explicit tests for rpm-only failure/tpm freshness, late-event insertion and nightly reconciliation, per-axis drift event emission plus rebuild-wins, divide-by-zero drift computation, and generated_at consistency. Keep the test header synchronized with actual test functions.

### MEDIUM

1. `phase4-coordinator/internal/stats/rollup/leaderboard.go:119`
   - Evidence: `loadProviderVisibility` reads `mode` and `blocked_from_partner_projection`, but the result is discarded at line 136. The persisted leaderboard schema contains only `earnings_bucket`; no persisted value records the effective `COALESCE(v.mode, 'bucketed')` / `COALESCE(v.blocked_from_partner_projection, FALSE)` tuple.
   - Why: The audit prompt requires the left-join semantics to be part of the rollup path. If Step 3 is expected to re-read `provider_visibility`, this Step 2 code and comment are misleading; if Step 3 is expected to read only rollup output, the effective mode/block fields are missing.
   - Fix: Either remove the unused visibility load and document that Step 3 owns the left join, or persist the effective visibility fields in a Step-1-approved storage shape. Do not leave a read-only no-op masquerading as enforcement.

### LOW

- None.

### INFO

- `go test ./internal/stats/rollup ./internal/stats` passed locally.
- `go test -tags integration -run 'TestRollup|TestShapeC' ./internal/stats` could not run in this environment because testcontainers panicked with `rootless Docker not found`.

## Final Verdict

Counts: **2 CRITICAL / 4 HIGH / 1 MEDIUM / 0 LOW / 2 INFO**

Verdict: **NOT READY TO LOCK**.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM. This round is blocked by a normal-path leaderboard panic, missing required late-event writes, incorrect `[start,end)` window boundaries, non-restarting panic recovery, generated-at inconsistency, and required integration coverage gaps.
