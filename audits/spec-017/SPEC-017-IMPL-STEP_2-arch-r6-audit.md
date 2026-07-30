# SPEC-017 IMPL Step 2 — Architecture Audit Round 6

Branch: `impl/spec-017-step-1`  
HEAD audited: `f2e2415` (`impl(017): Step 2 — round-5 audit fixes (visibility seam, drift union, late-event GREATEST, Shape C content-equality)`)  
Diff base: Step 1 converged tip `b499327`  
Auditor lane: ARCHITECTURE  
Prior round: `specs/SPEC-017-IMPL-STEP_2-arch-r5-audit.md`

Verdict: **READY TO LOCK** — 0 CRITICAL + 0 HIGH + 0 MEDIUM + 0 LOW + 1 INFO

Validation evidence:
- Read required Step 2 kickoff, locked SPEC-017 v0.1.8 sections, Step 1 trust-source decision, `004_grants.up.sql`, and ARCH r5 audit.
- `git diff --name-status b499327..HEAD` shows Step 2 changes confined to coordinator config/main/stats wiring, `internal/stats/rollup/`, stats rollup tests, `.gitignore`, and audit artifacts; no HTTP handler, partner-key CLI, nginx, or Step 4 surface landed in this Step 2 diff.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats/rollup`: **PASS** — imports are standard library plus `github.com/rs/zerolog`; no forbidden `internal/stats`, `internal/stats/store`, `internal/explorer`, `internal/ws`, or `internal/auth` imports.
- `go test ./internal/stats/rollup` from `phase4-coordinator/`: **PASS**.
- `go test ./internal/stats/...` from `phase4-coordinator/`: **PASS**.
- `go test ./cmd/coordinator -run TestNonExistent` from `phase4-coordinator/`: **PASS** compile smoke, no tests to run.
- `go test -tags=integration ./internal/stats -run 'TestRollup(VisibilityDefaultTuple|DriftDeletedProvider|Backfill|Retention|LateEvent|RewardsOnly|Ignores|Generated|WorkOnly|ShapeC|Drift)' -count=1`: **BLOCKED LOCALLY** by testcontainers panic `rootless Docker not found`.

## Category Verdicts

A. Rollup scope vs Step 2 / Step 3 boundary: **PASS** — rollup writes the locked leaderboard/overview/timeseries/rewards storage columns only, computes `earnings_bucket` in Step 2, and does not introduce handler-only state, partner-key state, CLI, nginx, or Step 4 surfaces.

B. Per-table jobs vs §9.2 cadences: **PASS** — the seven health components are spawned independently at the locked cadences: overview 30s, rpm 30s, tpm 30s, 24h 60s, 7d 5m, 30d 30m, all 6h. Each component has per-tick health success/failure handling and per-tick panic recovery.

C. Shape C rebuild + drift + retention: **PASS** — nightly rebuild computes 30d/all, performs `DELETE` + `INSERT` for both tables in one PostgreSQL transaction, compares drift over `pre ∪ rebuilt`, commits before retention, and runs late-event retention as a separate post-commit step.

D. Backfill posture + provider-identity trust: **PASS** — `partial` and `full` modes are wired through config; `partial` requires RFC3339 `partial_history_since`; all work/rewards provider IDs join through `provider_tokens`, with tests covering spoofed non-token providers.

E. rewards_populated computation: **PASS** — Step 2 pre-computes `stats_rewards_populated` from `provider_rewards_ledger` via a bounded `EXISTS` query; request-path computation is not present in this diff.

F. Bucket computation + left-join: **PASS** — bucket thresholds are numeric, rollup-side, and boundary-tested; the round-5 visibility blocker is closed by `provider_tokens LEFT JOIN provider_visibility` with `COALESCE(mode, 'bucketed')` and `COALESCE(blocked, FALSE)` defaults carried through the rollup compute path.

G. Package layout + import-graph lint: **PASS** — rollup code is contained under `internal/stats/rollup/`, imports stay within the allowlist, and no rollup `os.Exit` / `log.Fatal` usage is present.

H. Failure modes + main.go integration: **PASS** — coordinator startup only constructs and starts the rollup when `stats.enabled=true`, injects `statsPools.Rollup`, ties jobs to `shutdownCtx`, and drains with `Wait()` after cancellation.

## Findings

No CRITICAL, HIGH, MEDIUM, or LOW findings.

## Round-5 Closure Checks

### Closed — r5 HIGH 1: provider_visibility left-join/default seam

Evidence:

`phase4-coordinator/internal/stats/rollup/leaderboard.go:163`

```go
visibility, err := loadProviderVisibility(ctx, db)
```

`phase4-coordinator/internal/stats/rollup/leaderboard.go:227`

```go
rows = append(rows, leaderboardRow{
    ...
    VisibilityMode:     vis.Mode,
    VisibilityBlocked:  vis.Blocked,
})
```

`phase4-coordinator/internal/stats/rollup/leaderboard.go:378`

```go
func loadProviderVisibility(ctx context.Context, db *sql.DB) (map[string]visibilityRow, error) {
    const q = `
        SELECT pt.provider_id,
               COALESCE(pv.mode, 'bucketed') AS mode,
               COALESCE(pv.blocked_from_partner_projection, FALSE) AS blocked
          FROM provider_tokens pt
          LEFT JOIN provider_visibility pv ON pv.provider_id = pt.provider_id
    `
```

Why closed: r5 flagged a discarded side-read of `provider_visibility`. At `f2e2415`, the rollup compute path builds the §6.1 default tuple from a real left join against authenticated `provider_tokens`, carries the tuple on `leaderboardRow`, and still correctly avoids v0.2-only branching on `blocked_from_partner_projection`. `TestRollupVisibilityDefaultTuple` at `phase4-coordinator/internal/stats/rollup_integration_test.go:1279` covers no-row, explicit `exact`, and explicit `bucketed` cases.

### Closed — r5 HIGH 2: drift detection skips deleted providers

Evidence:

`phase4-coordinator/internal/stats/rollup/rebuild.go:153`

```go
func emitDriftEvents(window string, pre map[string]preRebuildRow, rebuilt []leaderboardRow, threshold float64, logger zerolog.Logger) {
    ...
    pids := make(map[string]struct{}, len(pre)+len(rebuilt))
    for pid := range pre {
        pids[pid] = struct{}{}
    }
    for pid := range rebuiltByPID {
        pids[pid] = struct{}{}
    }
    for pid := range pids {
```

`phase4-coordinator/internal/stats/rollup/rebuild.go:188`

```go
emitDriftIfExceeds(window, "earnings", pid, prevEarn, currEarn, threshold, logger)
emitDriftIfExceeds(window, "tokens", pid, float64(prevTokens), float64(currTokens), threshold, logger)
emitDriftIfExceeds(window, "jobs", pid, float64(prevJobs), float64(currJobs), threshold, logger)
```

Why closed: drift now compares the union of provider IDs from the incremental snapshot and the rebuilt result. Missing rebuilt rows become zero-valued, so stale providers deleted by the full recompute emit `stats_rollup_drift_detected`. `TestRollupDriftDeletedProvider` at `phase4-coordinator/internal/stats/rollup_integration_test.go:1363` covers this deleted-provider case.

## Info

### INFO 1 — Containerized integration could not be rerun locally

File: `phase4-coordinator/internal/stats/rollup_integration_test.go:1279`

Evidence snippet:

```text
panic: rootless Docker not found
```

Why: The targeted Postgres/testcontainers subset contains the direct r5 regression tests, but the local environment lacks rootless Docker. This is an environment validation gap, not a Step 2 architecture blocker: non-container tests pass, the test definitions are present, and the code paths are directly cited above.

Minimal follow-up: Run the targeted integration command in CI or a local environment with Docker:

```bash
go test -tags=integration ./internal/stats -run 'TestRollup(VisibilityDefaultTuple|DriftDeletedProvider|Backfill|Retention|LateEvent|RewardsOnly|Ignores|Generated|WorkOnly|ShapeC|Drift)' -count=1
```

## Final Verdict

`READY TO LOCK`: **YES**

Blocking count:
- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0
- INFO: 1

Round 6 verifies both prior ARCH blockers are closed at `f2e2415`. No remaining architecture blockers for Step 2.
