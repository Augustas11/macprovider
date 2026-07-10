# SPEC-017 IMPL Step 2 — Architecture Audit Round 1

Branch: `impl/spec-017-step-1`  
Diff base: Step 1 converged tip `b499327`  
Auditor lane: ARCHITECTURE  
Verdict: **NOT READY TO LOCK** — 2 CRITICAL + 4 HIGH + 0 MEDIUM

Validation evidence:
- Read required Step 2 kickoff, locked SPEC-017 v0.1.8, Step 1 convergence record, trust-source decision, grants, and Step 2 diff.
- `git diff --name-status b499327..HEAD` shows Step 2 rollup package plus config/main wiring and audit prompts.
- `go test ./internal/stats/rollup` from `phase4-coordinator/` passes, but only covers package unit tests; the blockers below are architecture/contract gaps not disproven by that run.

## Category Verdicts

A. Rollup scope vs Step 2 / Step 3 boundary: **HIGH** — rollup mostly stays in its package, but the required provider-visibility left-join is loaded then ignored rather than baked into rollup production semantics.

B. Per-table jobs vs §9.2 cadences: **HIGH** — all seven component jobs exist at the expected default cadences, but panic recovery terminates the panicking job goroutine instead of continuing/restarting it.

C. Shape C rebuild + drift + retention: **CRITICAL/HIGH** — Shape C primitives are used per table, but `30d` and `all` rebuilds are not in one transaction, and the pinned late-event correction path is explicitly deferred.

D. Backfill posture + provider-identity trust: **CRITICAL/HIGH** — work rows join `provider_tokens`, but reward-only leaderboard rows do not; `BackfillMode` is validated but not used to select full vs partial behavior.

E. rewards_populated computation: **PASS** — rollup pre-computes `stats_rewards_populated` from `provider_rewards_ledger`; no request-path computation appears in this Step 2 diff.

F. Bucket computation + left-join: **HIGH** — bucket thresholds are encoded in rollup, but the `provider_visibility` left-join/default tuple is not actually applied.

G. Package layout + import-graph lint: **PASS** — new rollup code is under `internal/stats/rollup/`, does not import forbidden packages, and contains no `os.Exit` / `log.Fatal`.

H. Failure modes + main.go integration: **HIGH** — main starts the runner from `statsPools.Rollup` under `stats.enabled`, but per-job panic recovery does not continue the failed job.

## Findings

### CRITICAL 1 — reward-only leaderboard rows bypass the provider_tokens trust source

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:215`

Evidence snippet:

```go
func aggregateRewardsPerProvider(ctx context.Context, db *sql.DB, sinceUnix int64) (map[string]rewardsAgg, error) {
    const q = `
        SELECT provider_id, COALESCE(SUM(amount_usd), 0) AS amount
          FROM provider_rewards_ledger
         WHERE ($1 = 0 OR unix_ts >= $1)
         GROUP BY provider_id
    `
```

Why: The Step 1 trust-source decision requires every `provider_id` materialized into any `stats_*` table to trace through SPEC-002 `provider_tokens`. `computeLeaderboardRows` unions `work` and `rewards`; a provider present only in `provider_rewards_ledger` is therefore materialized into `stats_leaderboard_*` without the required authenticated join.

Minimal fix: Change the rewards aggregate to join `provider_tokens` and group by `pt.provider_id`, then add an integration fixture with a reward row for `p_spoof` absent from `provider_tokens` and assert no `stats_leaderboard_*` row is written.

### CRITICAL 2 — nightly 30d/all rebuilds are not atomic as one transaction

File: `phase4-coordinator/internal/stats/rollup/rebuild.go:30`

Evidence snippet:

```go
func runNightlyRebuild(ctx context.Context, db *sql.DB, cfg Config, logger zerolog.Logger) error {
    for _, window := range []string{"30d", "all"} {
        if err := rebuildWindow(ctx, db, cfg, window, logger); err != nil {
            return fmt.Errorf("nightly rebuild %s: %w", window, err)
        }
    }
```

and `rebuildWindow` opens/commits its own transaction:

```go
tx, err := db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
...
if err := tx.Commit(); err != nil {
```

Why: The audit prompt and SPEC §9.4 require the nightly rebuild of `stats_leaderboard_all` and `stats_leaderboard_30d` to execute in a single PostgreSQL transaction using Shape C DELETE+INSERT. This implementation commits one table, then starts the other. A failure after the first commit leaves one nightly snapshot rebuilt and the other stale, breaking the locked rebuild atomicity invariant.

Minimal fix: Compute both rebuilt row sets first, then open one `BEGIN ISOLATION LEVEL READ COMMITTED` transaction that deletes/inserts both `stats_leaderboard_30d` and `stats_leaderboard_all` plus their health updates before one commit. Add a test that forces the second table insert to fail and proves both tables remain at the pre-rebuild snapshot.

### HIGH 1 — Step 2 defers the required late-event correction path to v0.2

File: `phase4-coordinator/internal/stats/rollup/late_events.go:10`

Evidence snippet:

```go
// IMPL-authored v0.1 simplification (surface for SPEC v0.2):
...
//   - 24h, 7d, 30d, all ticks all do a full per-cadence
//     recompute (DELETE + INSERT, see leaderboard.go).
...
//     `recordLateEvent` below is reachable from a future v0.2
//     IMPL of the incremental path.
```

Why: BUILD §2 Step 2 pins the v0.1 late-event correction behavior: 30d/all ticks scan a 48h lookback, fold in corrections inside the lookback, and record older events into `stats_late_events` for nightly reconciliation. The implementation explicitly does not wire this path, so the `stats_late_events` table becomes retention-only scaffolding rather than a working Step 2 seam.

Minimal fix: Implement the 30d/all incremental correction path now, call `recordLateEvent` for older-than-lookback corrections, and add the required integration test: `T-30h` folds into the 30d snapshot while `T-60h` lands in `stats_late_events`.

### HIGH 2 — BackfillMode does not actually select partial vs full rollup behavior

File: `phase4-coordinator/cmd/coordinator/main.go:209`

Evidence snippet:

```go
rollupCfg := statsrollup.Config{
    BackfillMode:            cfg.Stats.Rollup.BackfillMode,
    PartialHistorySinceUnix: parseRFC3339Unix(cfg.Stats.Rollup.PartialHistorySince),
```

and the rollup uses only the unix boundary:

```go
since := windowStart(window, now, cfg.PartialHistorySinceUnix)
```

Why: BUILD §2 Step 2 requires both backfill modes to be implemented and selected by `cfg.Stats.Rollup.BackfillMode`. Here `BackfillMode` is only validated; the runtime boundary is determined solely by whether `partial_history_since` parses to non-zero. A stale `partial_history_since` with `backfill_mode: full` still truncates `all`/overview/rewards to partial history, and an invalid partial timestamp silently becomes full history.

Minimal fix: Translate config with mode-aware behavior: for `full`, force `PartialHistorySinceUnix = 0`; for `partial`, require a valid RFC3339 `partial_history_since` when configured for cutover and fail startup on parse errors. Add tests for partial and full mode selection.

### HIGH 3 — provider_visibility is loaded but not applied as the rollup left-join/default tuple

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:119`

Evidence snippet:

```go
visibility, err := loadProviderVisibility(ctx, db)
...
_ = visibility[pid] // visibility tuple is read by the handler; rollup ensures the left-join row exists in the leaderboard regardless of mode/blocked
```

Why: BUILD §2 Step 2 ARCH r7 H2 and SPEC §6.1 require the rollup to left-join `provider_visibility`; absence must default to `mode='bucketed' AND blocked_from_partner_projection=FALSE`. This code performs a standalone SELECT and discards the result. The comment says the handler reads the tuple, which is exactly the boundary the prompt marks HIGH when deferred to the handler.

Minimal fix: Make the leaderboard source query explicitly left-join `provider_visibility` and coalesce the default tuple while computing/writing the row. Add fixtures for no visibility row, explicit `exact`, and explicit `bucketed`; assert rollup behavior is proven before any Step 3 handler projection.

### HIGH 4 — per-job panic recovery stops the failed job instead of continuing it

File: `phase4-coordinator/internal/stats/rollup/runner.go:131`

Evidence snippet:

```go
go func() {
    defer r.wg.Done()
    defer func() {
        if rec := recover(); rec != nil {
            ...
            _ = healthFail(context.Background(), r.db, c, time.Now().UTC(), fmt.Sprintf("panic: %v", rec))
        }
    }()
    ...
    r.runOne(ctx, name, c, fn)
    for {
        ...
        case <-ticker.C:
            r.runOne(ctx, name, c, fn)
```

Why: Recovering in a defer around the whole goroutine prevents coordinator-wide crash, but after `recover` the goroutine returns. SPEC §9.6 / audit category H.2 require each job's recover middleware to update health and continue, so a panic in `leaderboard_24h` should not permanently stop that component until process restart.

Minimal fix: Move panic recovery inside the per-tick execution wrapper so each tick's panic is converted to a health failure and the ticker loop continues. Add a unit test with a job that panics on the first call and succeeds on the second tick.

## Final Verdict

`READY TO LOCK`: **NO**

Blocking count:
- CRITICAL: 2
- HIGH: 4
- MEDIUM: 0
- LOW: 0
- INFO: 0

Required before lock: fix the provider-token trust-source bypass, make the nightly 30d/all rebuild one transaction, implement the Step 2 late-event correction seam, make `BackfillMode` behaviorally authoritative, apply the `provider_visibility` left-join/default tuple in rollup production, and keep panicked jobs alive after health-fail recording.
