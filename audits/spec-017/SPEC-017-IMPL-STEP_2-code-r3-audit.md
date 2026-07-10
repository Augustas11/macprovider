# SPEC-017 IMPL Step 2 CODE audit - round 3

Branch: `impl/spec-017-step-1`
Diff audited: `origin/main...HEAD` at `745128e210436ad73f3e846375a161dfb9e463b5`
Prior round: `specs/SPEC-017-IMPL-STEP_2-code-r2-audit.md`
Lens: CODE - SQL correctness, transaction boundaries, error handling, idempotency, idiomatic Go, dependency hygiene, test adequacy.

## Category Verdicts

- A. SQL correctness vs schema: **FAIL** - token rollups do not implement SPEC-005 effective completion-token semantics for `usage_source = 'byte_estimated'`.
- B. Transaction boundaries: **PASS** - per-table writes and health updates are transaction-coupled; Shape C uses `sql.LevelReadCommitted`; retention remains post-commit.
- C. Concurrency: **PASS** - tickers use `time.NewTicker`, stop on context cancellation, and late-event anti-join insertion is serialized by an advisory lock.
- D. Drift detection + late events: **PASS with coverage gap** - per-axis drift math now uses `max(rebuild, 1)` and late-event insertion is present, but the required integration proof is still absent.
- E. rewards_populated: **PASS** - uses `EXISTS`, `window_label`, and false bootstrap semantics.
- F. Bucket + left-join + provider identity: **PASS** - provider-token joins are present, bucket boundaries are tested, and the v0.1 `blocked_from_partner_projection` branch was removed.
- G. Backfill + main.go integration: **PASS** - rollup starts only with stats pools, uses `shutdownCtx`, and drains after shutdown cancellation.
- H. Tests: **FAIL** - byte-estimated token rows are untested, drift has only unit helper coverage, and Shape C post-commit equivalence is still count-only.

## Findings

### CRITICAL

- None.

### HIGH

1. `phase4-coordinator/internal/stats/rollup/leaderboard.go:237`
   - Evidence: leaderboard token aggregation uses `COALESCE(SUM(lrc.prompt_tokens + lrc.completion_tokens), 0)`. `overview.go:118`, `timeseries.go:116`, and `late_events.go:62` similarly read only `completion_tokens` for output/effective token counts. SPEC-005 defines `effective_completion_tokens = estimated_completion_tokens when usage_source = byte_estimated` (`specs/SPEC-005-billing.md:483-486`), and those ledger columns are nullable (`specs/SPEC-005-billing.md:1630-1650`).
   - Why: A valid byte-estimated row can have `completion_tokens = NULL` and `estimated_completion_tokens > 0`. The current leaderboard expression turns `prompt_tokens + NULL` into NULL, so the row can contribute zero tokens to `stats_leaderboard_*` token totals/ranks. Overview `tokens_out`, TPM timeseries `output_tokens`, and `stats_late_events.delta_tokens` also undercount the same valid SPEC-005 path.
   - Fix: Use one effective-token SQL expression everywhere the rollup counts output/served tokens, e.g. `COALESCE(prompt_tokens,0)` plus `CASE usage_source WHEN 'byte_estimated' THEN COALESCE(estimated_completion_tokens,0) WHEN 'null_error' THEN 0 ELSE COALESCE(completion_tokens,0) END`. Add integration fixtures with `usage_source='byte_estimated'`, `completion_tokens=NULL`, and `estimated_completion_tokens>0` for overview, TPM, leaderboard token rank, and late-event delta.

### MEDIUM

1. `phase4-coordinator/internal/stats/rollup_integration_test.go:29`
   - Evidence: the integration-test header still claims "Drift > 0.5% fires `stats_rollup_drift_detected` AND rebuild value wins", but `rg` finds no integration `Test*Drift`. Current drift tests are unit-level helper checks in `phase4-coordinator/internal/stats/rollup/rebuild_test.go:17` and redaction-shape checks at `rebuild_test.go:67`.
   - Why: Required H.5 is integration, not just unit math. The current tests do not prove `RunNightlyRebuild` snapshots the pre-rebuild rows, emits the structured event through the real rebuild path, and leaves the committed table with the rebuild value.
   - Fix: Add an integration test that seeds an incremental `stats_leaderboard_all` row with one axis below/above the rebuilt OLTP truth, captures the zerolog output from `RunNightlyRebuild`, asserts `stats_rollup_drift_detected` with the expected `axis`, and asserts the committed leaderboard row equals the rebuild value.

2. `phase4-coordinator/internal/stats/rollup_integration_test.go:586`
   - Evidence: `TestShapeCRebuild_MVCCNoEmptyState` only asserts the post-rebuild `COUNT(*)` is 5 at lines 586-593. It no longer checks that the committed rows equal the rebuilt source query exactly. The failed-rollback test similarly records only `COUNT(*)` at lines 466-503.
   - Why: Required H.2 has three sub-assertions, including post-commit equivalence. Count-only assertions can pass after rank, bucket, token, earnings, or provider-id drift, so the test does not yet prove the Shape C rebuild committed the exact rebuilt snapshot.
   - Fix: Capture an ordered expected row set for R1 from the same OLTP fixture (provider_id, ranks, earnings, tokens, jobs, bucket, first/last seen as applicable) and compare it to `SELECT ... FROM stats_leaderboard_all ORDER BY provider_id` after commit. For failed rollback, compare R0 rows before/after, not just row count.

### LOW

- None.

### INFO

- `cd phase4-coordinator && go test ./internal/stats/rollup ./internal/stats` passed.
- `cd phase4-coordinator && go test ./internal/config ./internal/stats/rollup ./internal/stats` passed.
- `cd phase4-coordinator && go test ./...` passed.
- `cd phase4-coordinator && go test -tags integration -run 'TestRollup|TestShapeC' ./internal/stats` could not run here because testcontainers panicked with `rootless Docker not found`.
- `git diff --check origin/main...HEAD` is currently blocked by trailing whitespace in existing prior audit markdown files (`SPEC-017-IMPL-STEP_2-*-r1/r2-audit.md`), not by the Go files inspected in this round.

## Final Verdict

Counts: **0 CRITICAL / 1 HIGH / 2 MEDIUM / 0 LOW / 5 INFO**

Verdict: **NOT READY TO LOCK**.

`READY TO LOCK` requires 0 CRITICAL + 0 HIGH + 0 MEDIUM. Round 3 is blocked by incorrect token aggregation for SPEC-005 byte-estimated ledger rows and by missing/insufficient required integration proofs for drift and Shape C post-commit equivalence.
