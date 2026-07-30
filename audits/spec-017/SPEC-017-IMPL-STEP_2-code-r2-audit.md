# SPEC-017 IMPL Step 2 CODE audit — round 2

Branch: `impl/spec-017-step-1`  
Diff audited: `origin/main...HEAD` at `134ddc448b2296f0b6370942a3649b55fb26669d`  
Prior round: `specs/SPEC-017-IMPL-STEP_2-code-r1-audit.md`  
Lens: CODE — SQL correctness, transaction boundaries, error handling, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts

- A. SQL correctness vs schema: **PASS with caveat** — full leaderboard column lists and `[start,end)` bounds are now present, but drift math still diverges from the pinned formula.
- B. Transaction boundaries: **PASS** — per-table data writes and health updates are transaction-coupled; Shape C uses `sql.LevelReadCommitted` and commits before retention.
- C. Concurrency: **FAIL** — late-event insertion is not concurrency-idempotent across the independently scheduled `30d` and `all` jobs.
- D. Drift detection + late events: **FAIL** — late-event idempotency can race, and drift denominator logic is not the required `max(rebuild, 1)` formula.
- E. rewards_populated: **PASS** — uses `EXISTS`, `window_label`, and false bootstrap semantics.
- F. Bucket + left-join + provider identity: **FAIL** — provider-token joins and bucket logic are present, but the rollup now branches on the v0.1 `blocked_from_partner_projection` stub, which the locked spec forbids.
- G. Backfill + main.go integration: **PASS** — rollup starts only when stats pools are opened, uses `shutdownCtx`, and drains on shutdown.
- H. Tests: **FAIL** — mandatory Shape C coverage is broken/too weak, and required drift plus rpm/tpm failure-isolation tests are still overclaimed.

## Findings

### CRITICAL

- None.

### HIGH

1. `phase4-coordinator/internal/stats/rollup/leaderboard.go:174`
   - Evidence: `computeLeaderboardRows` loads `provider_visibility`, then skips any provider with `v.Blocked` at lines 174-176. The new regression test at `phase4-coordinator/internal/stats/rollup_integration_test.go:734` asserts that `blocked_from_partner_projection = TRUE` excludes the provider from `stats_leaderboard_24h`.
   - Why: Locked SPEC §6.1 says `blocked_from_partner_projection` is a v0.1 column stub and that v0.1 implementations "MUST NOT branch on it"; §6.6.2 says the rollup does not consume it yet, and BUILD §11 Q11 repeats that partner projection still surfaces exact dollars for all providers in v0.1. This code makes a v0.2 semantic load-bearing in Step 2 and writes tests that preserve the wrong contract.
   - Fix: Remove the `Blocked` filter from rollup storage. Keep no-row/default visibility coverage, but make a blocked-row fixture prove the provider still appears in `stats_leaderboard_*` for v0.1. Leave any blocked-provider projection behavior to a future SPEC bump.

2. `phase4-coordinator/internal/stats/rollup/late_events.go:50`
   - Evidence: `detectLateEvents` deduplicates with `NOT EXISTS` on `source_billing_row` at lines 50-53 and 70-73, but both `leaderboard_30d` and `leaderboard_all` call it after their ticks (`leaderboard.go:94`) and those jobs are independent goroutines (`runner.go:92-97`). With READ COMMITTED, concurrent `INSERT ... SELECT ... NOT EXISTS` statements can both observe no row and insert the same source row because the schema has no unique constraint.
   - Why: Step 2 is setting the first stats write patterns. The late-events table is meant to be idempotent forensic input; duplicate rows from normal scheduler concurrency make reconciliation and operator diagnosis noisy and nondeterministic.
   - Fix: Give late-event detection a single owner, or enforce source-row uniqueness with a spec-compatible storage change before using `ON CONFLICT DO NOTHING`. If the schema cannot change in Step 2, serialize the detector with a transaction-scoped advisory lock and add a concurrent `30d`/`all` test.

3. `phase4-coordinator/internal/stats/rollup_integration_test.go:482`
   - Evidence: `TestShapeCRebuild_FailedRollback` adds `CHECK (false) NOT VALID` to a table that already contains R0, then immediately runs `VALIDATE CONSTRAINT` at lines 488-490. PostgreSQL validation checks existing rows, so this fails before `RunNightlyRebuild` executes. The MVCC test also seeds R0 and R1 with the same count (`3`) and only checks "not zero" at lines 571-583, so it cannot prove "R0 or R1, never mixed partial" as required.
   - Why: BUILD §2 Step 2 requires Shape C tests to prove failed-rebuild rollback, MVCC no-empty-state, and post-commit equivalence. The current failed-rollback test does not reach the rebuild path, and the MVCC test cannot detect a mixed partial state.
   - Fix: Do not validate the temporary `CHECK (false) NOT VALID`; PostgreSQL enforces it for future inserts while preserving R0. For MVCC, use distinguishable R0/R1 row sets and assert every observation equals exactly one complete snapshot, not merely `count != 0`.

### MEDIUM

1. `phase4-coordinator/internal/stats/rollup/rebuild.go:158`
   - Evidence: `emitDriftIfExceeds` divides by `current` unless it is zero, then by `prev`; the required audit formula is `(rebuild - incremental) / max(rebuild, 1) > 0.005` per axis. There is no unit test for divide-by-zero or zero-on-both-sides; `rg` finds only config default/range tests for drift.
   - Why: For sub-unit rebuild values, this overstates drift and can page operators on noise the spec intentionally suppresses with `max(rebuild, 1)`. Per-axis logging exists, but the comparison is not the pinned comparison.
   - Fix: Compute `denom := math.Max(current, 1)` using the rebuild value, compare absolute delta per axis, and add unit tests for zero/zero, zero/current, and sub-unit values.

2. `phase4-coordinator/internal/stats/rollup_integration_test.go:15`
   - Evidence: The test header claims rpm-only failure isolation and drift alert coverage at lines 15-16 and 29-30, but `rg` finds no `Test*Drift`, no rpm-only failure test, and no divide-by-zero drift unit test.
   - Why: Required H.1, H.5, and H.10 remain unproven after r1. This matters because the first Postgres writer patterns need regression coverage before Step 3 consumes the health and drift signals.
   - Fix: Add tests that force only `timeseries_rpm` to fail while `timeseries_tpm` stays fresh, verify `stats_rollup_drift_detected` plus rebuild-wins on each axis, and cover drift denominator zero cases.

### LOW

- None.

### INFO

- `go test ./internal/stats/rollup ./internal/stats` passed locally.
- `go test -tags integration -run 'TestRollup|TestShapeC' ./internal/stats` could not run in this environment because testcontainers panicked with `rootless Docker not found`.

## Final Verdict

Counts: **0 CRITICAL / 3 HIGH / 2 MEDIUM / 0 LOW / 2 INFO**

Verdict: **NOT READY TO LOCK**.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 2 is blocked by a v0.1 visibility contract violation, a late-event duplicate race, broken/insufficient Shape C test coverage, incorrect drift denominator logic, and missing required failure/drift tests.
