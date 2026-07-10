# SPEC-017 IMPL Step 2 — Architecture Audit Round 4

Branch: `impl/spec-017-step-1`  
HEAD audited: `a70d75a` (`impl(017): Step 2 — implement SPEC §9.3 incremental-merge for 30d/all`)  
Diff base: Step 1 converged tip `b499327`  
Auditor lane: ARCHITECTURE  
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_2-arch-r1-audit.md`
- `specs/SPEC-017-IMPL-STEP_2-arch-r2-audit.md`
- `specs/SPEC-017-IMPL-STEP_2-arch-r3-audit.md`

Verdict: **NOT READY TO LOCK** — 0 CRITICAL + 1 HIGH + 0 MEDIUM + 0 LOW + 0 INFO

Validation evidence:
- Read required Step 2 kickoff, locked SPEC-017 v0.1.8 sections, Step 1 trust-source decision, `004_grants.up.sql`, and prior ARCH r1/r2/r3 audits.
- `git diff --name-status b499327..HEAD` shows Step 2 changes confined to coordinator config/main wiring, `internal/stats/rollup/`, rollup integration tests, stats pool wiring, `.gitignore`, and audit prompt/output files.
- Re-checked the new round-4 target commit `a70d75a`: `leaderboard_30d` and `leaderboard_all` now route through `runLeaderboardIncrementalTick`, and the prior r3 full-recompute blocker is no longer present in that form.
- `go test ./internal/stats/rollup` from `phase4-coordinator/`: **PASS**.
- `go test ./internal/stats/...` from `phase4-coordinator/`: **PASS**.
- `go test ./cmd/coordinator -run TestNonExistent` from `phase4-coordinator/`: **PASS** compile smoke, no tests to run.
- `go list -f '{{.ImportPath}} {{join .Imports "\n"}}' ./internal/stats/rollup`: **PASS** — imports are standard library plus `github.com/rs/zerolog`; no forbidden `internal/stats`, `internal/stats/store`, `internal/explorer`, `internal/ws`, or `internal/auth` imports.
- `go test -tags=integration ./internal/stats -run 'TestRollup(Backfill|Retention|Blocked|LateEvent|RewardsOnly|Ignores|Generated|WorkOnly)' -count=1`: **BLOCKED LOCALLY** by testcontainers panic `rootless Docker not found`.

## Category Verdicts

A. Rollup scope vs Step 2 / Step 3 boundary: **PASS** — no handler, partner-key CLI, nginx, or Step 4 implementation appears in the Step 2 diff; rollup storage columns remain the Step 3 consumption surface.

B. Per-table jobs vs §9.2 cadences: **PASS** — all seven health components are spawned at the locked cadences, rpm/tpm health remains split, and tick-level panic recovery preserves independent restartability.

C. Shape C rebuild + drift + retention: **HIGH** — Shape C rebuild and post-commit retention are implemented, and the r3 full-recompute cadence blocker is partly closed, but the 30d incremental merge does not preserve the rolling-window contract for inactive providers whose old rows age out between ticks.

D. Backfill posture + provider-identity trust: **PASS** — both backfill modes are wired, `partial` requires `partial_history_since`, and work/rewards provider identities join through `provider_tokens`.

E. rewards_populated computation: **PASS** — the rollup pre-computes `stats_rewards_populated` from `provider_rewards_ledger`; the Step 2 diff introduces no request-path computation.

F. Bucket computation + left-join: **PASS** — bucket thresholds are rollup-side and use numeric arithmetic; provider visibility is loaded with the v0.1 no-row default semantics and the blocked stub is not consumed.

G. Package layout + import-graph lint: **PASS** — rollup code is contained under `internal/stats/rollup/`, imports stay within the allowlist, and no rollup `os.Exit` / `log.Fatal` usage is present.

H. Failure modes + main.go integration: **PASS** — rollup starts only when stats pools exist, is tied to `shutdownCtx`, uses `statsPools.Rollup`, and the prior defer-ordering drain issue is fixed.

## Findings

### HIGH 1 — 30d incremental merge does not age inactive providers' rolling-window totals

File: `phase4-coordinator/internal/stats/rollup/incremental.go:98`

Evidence snippet:

```go
// Step 1: find providers with new activity in
// `[lookback_start, now)`.
activeProvs, err := queryActiveProvidersInLookback(ctx, db, lookbackStart, endUnix)
```

File: `phase4-coordinator/internal/stats/rollup/incremental.go:105`

```go
// Step 2: for each active provider, recompute the full
// window aggregate (provider-scoped).
```

File: `phase4-coordinator/internal/stats/rollup/incremental.go:145`

```go
// Delete drop-outs FIRST: providers in the snapshot whose
// last_seen_at is older than the window-start boundary
// AND not in our update set.
```

File: `phase4-coordinator/internal/stats/rollup/incremental.go:323`

```go
q := fmt.Sprintf(`SELECT provider_id FROM %s WHERE EXTRACT(EPOCH FROM last_seen_at) < $1`, table)
```

Why: SPEC §9.2 defines `stats_leaderboard_30d` as "per-provider sums over last 30d (windowed)" at a 30-minute cadence, and §9.3 requires the 30d job to merge corrections into the existing snapshot instead of full-recomputing. The new path only recomputes providers with activity in `[last_ok_at - lookback, now)` and otherwise deletes providers whose `last_seen_at` has fully fallen before the current window start. That misses the common rolling-window case where a provider has no new activity, remains active inside the window, but some older contributing rows cross out of the 30d boundary between ticks. Those stale rows remain counted until the nightly rebuild, so Step 3 can serve inflated `earnings_usd`, `tokens`, `jobs`, and rank fields for up to a day despite the locked 30-minute 30d cadence.

Rewards-only rows are an even sharper instance of the same architectural gap: `computeLeaderboardRowForProvider` populates `last_seen_at` from work rows only, so a rewards-only provider can have a `NULL` `last_seen_at`; the drop-out query above will not match it after its reward ages out of the 30d window.

Minimal fix: Extend the 30d incremental candidate set beyond "providers with new lookback activity." On each 30d tick, also recompute providers with any currently materialized contribution crossing the old-window-start to new-window-start boundary, including rewards-only contributions. A straightforward implementation is to track or query providers with source rows in the expired slice and union them with the lookback-active set, then recompute each provider's full current 30d aggregate and delete when empty. Add an integration test where a provider has rows at `now-29d23h45m` and `now-1d`, then a later tick advances `now` past the older row with no new activity; assert the old row is removed from 30d totals/ranks before the nightly rebuild. Include a rewards-only variant with no work `last_seen_at`.

## Previously Flagged r3 Items

- ARCH r3 HIGH 1 (§9.3 incremental merge seam deferred): **partially closed** — `a70d75a` adds an incremental cadence path and proves T-60h rows do not fold into the live snapshot before the nightly rebuild, but the rolling-window aging case above still blocks the 30d architecture contract.
- ARCH r3 LOW 1 (rollup drain defer ordering): **closed** — `cmd/coordinator/main.go` now combines `stopBackground()` and `statsRollup.Wait()` in one defer, so cancellation precedes draining on non-signal return paths.

## Final Verdict

`READY TO LOCK`: **NO**

Blocking count:
- CRITICAL: 0
- HIGH: 1
- MEDIUM: 0
- LOW: 0
- INFO: 0

Required before lock: make the `stats_leaderboard_30d` incremental tick age out expired source contributions for providers without new lookback activity, including rewards-only providers, while preserving the existing `provider_tokens` trust-source join and nightly Shape C reconciliation.
