# SPEC-017 IMPL Step 2 — Architecture Audit Round 5

Branch: `impl/spec-017-step-1`  
HEAD audited: `a3844aa` (`impl(017): Step 2 — round-4 audit fixes (rewards last_seen + late-event watermark)`)  
Diff base: Step 1 converged tip `b499327`  
Auditor lane: ARCHITECTURE  
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_2-arch-r1-audit.md`
- `specs/SPEC-017-IMPL-STEP_2-arch-r2-audit.md`
- `specs/SPEC-017-IMPL-STEP_2-arch-r3-audit.md`
- `specs/SPEC-017-IMPL-STEP_2-arch-r4-audit.md`

Verdict: **NOT READY TO LOCK** — 0 CRITICAL + 2 HIGH + 0 MEDIUM + 0 LOW + 0 INFO

Validation evidence:
- Read required Step 2 kickoff, locked SPEC-017 v0.1.8 sections, Step 1 trust-source decision, `004_grants.up.sql`, and ARCH r1-r4 audits.
- `git diff --name-status b499327..HEAD` shows Step 2 changes confined to coordinator config/main wiring, `internal/stats/rollup/`, rollup integration tests, stats pool wiring, `.gitignore`, and audit prompt/output files.
- `go test ./internal/stats/rollup` from `phase4-coordinator/`: **PASS**.
- `go test ./internal/stats/...` from `phase4-coordinator/`: **PASS**.
- `go test ./cmd/coordinator -run TestNonExistent` from `phase4-coordinator/`: **PASS** compile smoke, no tests to run.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats/rollup`: **PASS** — imports are standard library plus `github.com/rs/zerolog`; no forbidden `internal/stats`, `internal/stats/store`, `internal/explorer`, `internal/ws`, or `internal/auth` imports.
- `go test -tags=integration ./internal/stats -run 'TestRollup(Backfill|Retention|Blocked|LateEvent|RewardsOnly|Ignores|Generated|WorkOnly|ShapeC|Drift)' -count=1`: **BLOCKED LOCALLY** by testcontainers panic `rootless Docker not found`.

## Category Verdicts

A. Rollup scope vs Step 2 / Step 3 boundary: **HIGH** — the diff stays out of handlers, partner-key CLI, and nginx, but the rollup still leaves the provider-visibility projection tuple to Step 3 instead of baking the §6.1 left-join/default seam into Step 2.

B. Per-table jobs vs §9.2 cadences: **PASS** — the seven health components are spawned at the locked cadences, rpm/tpm health is split, and tick-level panic recovery preserves independent restartability.

C. Shape C rebuild + drift + retention: **HIGH** — Shape C DELETE+INSERT and post-commit retention are present, and the round-4 30d aging fix is directionally correct, but drift detection skips providers that disappear from the full recompute.

D. Backfill posture + provider-identity trust: **PASS** — `partial` requires `partial_history_since`, `full` forces no lower bound, and work/rewards provider identities join through `provider_tokens`.

E. rewards_populated computation: **PASS** — the rollup pre-computes `stats_rewards_populated` from `provider_rewards_ledger`; this Step 2 diff introduces no request-path computation.

F. Bucket computation + left-join: **HIGH** — bucket thresholds are rollup-side and numeric, but the provider-visibility left-join/default tuple is read and discarded rather than becoming a rollup-owned production seam.

G. Package layout + import-graph lint: **PASS** — rollup code is contained under `internal/stats/rollup/`, imports stay within the allowlist, and no rollup `os.Exit` / `log.Fatal` usage is present.

H. Failure modes + main.go integration: **PASS** — `cmd/coordinator/main.go` starts the rollup only when `stats.enabled=true`, uses `statsPools.Rollup`, ties it to `shutdownCtx`, and cancels before draining.

## Findings

### HIGH 1 — provider_visibility is not actually a rollup-owned left-join/default seam

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:132`

Evidence snippet:

```go
// The function loads `provider_visibility` (the §6.1 left-join
// data) for join-evidence completeness, but per the round-2
// audit fix the rollup MUST NOT branch on
// `blocked_from_partner_projection` in v0.1
...
// The `mode` column is read but not persisted — Step 3's
// handler reads it directly from `provider_visibility` for the
// public/partner projection split (with default tuple bucketed
// via COALESCE).
```

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:153`

```go
visibility, err := loadProviderVisibility(ctx, db)
```

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:180`

```go
_ = visibility[pid] // intentional read; do NOT branch on .Blocked in v0.1
```

Why: Locked SPEC §6.1 says the rollup MUST left-join `provider_visibility` when producing the leaderboard projection, and BUILD §2 Step 2 ARCH r7 H2 says Step 2 owns the provider-visibility left-join/default tuple, not just Step 1 fixtures plus Step 3 projection. The round-5 prompt classifies deferring this to the handler as HIGH. Current code performs a separate `SELECT provider_id, mode, blocked_from_partner_projection FROM provider_visibility`, discards the result for every provider, and explicitly states that Step 3's handler will read `provider_visibility` directly. The only integration fixture touching visibility is `blocked_from_partner_projection = TRUE` still appears in storage; there is no Step 2 fixture proving explicit `exact`, explicit `bucketed`, and no-row default tuples are materialized by the rollup seam.

Minimal fix: Make provider visibility part of the rollup production path rather than a discarded side read. A minimal compliant shape is to have the leaderboard source build an internal projection tuple via `LEFT JOIN provider_visibility pv ON pv.provider_id = pt.provider_id` with `COALESCE(pv.mode, 'bucketed')` and `COALESCE(pv.blocked_from_partner_projection, FALSE)`, while still not branching on `blocked_from_partner_projection` in v0.1. Add Step 2 integration fixtures for no row, explicit `mode='exact'`, and explicit `mode='bucketed'` so the default tuple is proven before Step 3 handler redaction.

### HIGH 2 — drift detection misses providers deleted by the full recompute

File: `phase4-coordinator/internal/stats/rollup/rebuild.go:143`

Evidence snippet:

```go
func emitDriftEvents(window string, pre map[string]preRebuildRow, rebuilt []leaderboardRow, threshold float64, logger zerolog.Logger) {
    if threshold <= 0 {
        threshold = 0.005
    }
    for _, r := range rebuilt {
        prev, ok := pre[r.ProviderID]
        if !ok {
            continue
        }
        emitDriftIfExceeds(window, "earnings", r.ProviderID, ratToFloat(prev.Earnings), ratToFloat(r.EarningsTotalUSD), threshold, logger)
```

Why: SPEC §9.4 says the nightly rebuild doubles as drift detection: if the full recompute differs from the incremental snapshot by more than 0.5% on any axis, `stats_rollup_drift_detected` fires and the rebuild value wins. This loop only iterates providers present in the rebuilt set. If an incremental snapshot contains a stale provider that the full recompute correctly removes, the Shape C transaction deletes that provider but `emitDriftEvents` never compares its pre-rebuild earnings/tokens/jobs against zero and never emits the drift event. That silently hides exactly the stale-extra-row class the nightly rebuild is supposed to surface to operators.

Minimal fix: Compare the union of provider IDs from `pre` and `rebuilt`. Treat missing rebuilt rows as zero values and missing pre rows as zero values, then run the same per-axis threshold check. Add a drift test that manually inserts or corrupts a `stats_leaderboard_all` row for a provider with no current source rows, runs `RunNightlyRebuild`, asserts the row is deleted, and asserts `stats_rollup_drift_detected` fires with that provider sample.

## Previously Flagged r4 Item

- ARCH r4 HIGH 1 (30d incremental merge does not age inactive providers' rolling-window totals): **mostly closed** — `a3844aa` adds an aging-out candidate slice for 30d and combines rewards timestamps into `last_seen_at`. The local integration test that would exercise the full containerized path is blocked by missing rootless Docker, but the code now covers the exact stale-contribution shape r4 identified.

## Final Verdict

`READY TO LOCK`: **NO**

Blocking count:
- CRITICAL: 0
- HIGH: 2
- MEDIUM: 0
- LOW: 0
- INFO: 0

Required before lock: make the provider-visibility left-join/default tuple an actual Step 2 rollup seam rather than handler-deferred state, and extend nightly drift detection to compare providers that disappear from the full recompute.
