# SPEC-017 IMPL Step 2 — Architecture Audit Round 2

Branch: `impl/spec-017-step-1`  
HEAD audited: `134ddc4` (`impl(017): Step 2 — round-1 audit fixes (4C + 6H + 2M)`)  
Diff base: Step 1 converged tip `b499327`  
Auditor lane: ARCHITECTURE  
Prior round checked: `specs/SPEC-017-IMPL-STEP_2-arch-r1-audit.md`  
Verdict: **NOT READY TO LOCK** — 0 CRITICAL + 3 HIGH + 0 MEDIUM + 1 LOW

Validation evidence:
- Read required Step 2 kickoff, locked SPEC-017 v0.1.8 sections, Step 1 trust-source decision, `004_grants.up.sql`, and prior ARCH r1 audit.
- `git diff --name-status b499327..HEAD` shows Step 2 changes confined to coordinator config/main wiring, `internal/stats/rollup/`, rollup integration tests, stats pool wiring, and audit prompt/output files.
- Re-checked r1 blockers: rewards aggregation now joins `provider_tokens`; nightly rebuild now wraps both `30d` and `all` DELETE+INSERT in one transaction; retention runs after commit; panic recovery is per tick; `BackfillMode` is mode-aware for `full` but still accepts a partial mode with no boundary; provider visibility was over-corrected into v0.2 blocked-provider semantics.

## Category Verdicts

A. Rollup scope vs Step 2 / Step 3 boundary: **HIGH** — the rollup now consumes `blocked_from_partner_projection` and removes providers from storage, which implements the deferred v0.2 partner-projection opt-out instead of leaving Step 3 to project v0.1 rows.

B. Per-table jobs vs §9.2 cadences: **PASS / LOW** — all seven health components are spawned at the locked cadences and per-tick panic recovery continues the job; the clamp+warn retention floor behavior is not pinned by a focused unit test.

C. Shape C rebuild + drift + retention: **HIGH** — the r1 atomicity blocker is closed, and retention is post-commit, but the 30d/all cadence path still full-recomputes and explicitly defers the §9.3 incremental-merge seam to v0.2.

D. Backfill posture + provider-identity trust: **HIGH** — provider identity is now filtered through `provider_tokens`, but `backfill_mode = "partial"` can start with no `partial_history_since`, making Path A behave like Path B while Step 3 has no required field to emit.

E. rewards_populated computation: **PASS** — `stats_rewards_populated` is pre-computed from `provider_rewards_ledger`; no request-path computation appears in this Step 2 diff.

F. Bucket computation + left-join: **HIGH** — bucket thresholds are in rollup and absent visibility rows default through the in-memory join, but the blocked flag is incorrectly load-bearing in v0.1.

G. Package layout + import-graph lint: **PASS** — rollup code is under `internal/stats/rollup/`, imports no forbidden packages, and contains no `os.Exit` / `log.Fatal`.

H. Failure modes + main.go integration: **PASS** — `cmd/coordinator/main.go` starts the runner from `statsPools.Rollup` only when stats are enabled, ties it to `shutdownCtx`, and the r1 per-job panic-recovery issue is closed.

## Findings

### HIGH 1 — rollup implements deferred `blocked_from_partner_projection` semantics

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:132`

Evidence snippet:

```go
// providers with
// `blocked_from_partner_projection = TRUE` are EXCLUDED from
// the leaderboard storage entirely
...
v, present := visibility[pid]
if present && v.Blocked {
    continue
}
```

Companion test locks the same behavior:

File: `phase4-coordinator/internal/stats/rollup_integration_test.go:734`

```go
// blocked_from_partner_projection = TRUE excludes provider from
// leaderboard storage entirely (v0.1.7 column stub becomes
// load-bearing here).
```

Why: Locked BUILD §6 defers §11 Q11 partner-projection opt-out: the `blocked_from_partner_projection` column is a v0.1 stub, and "the v0.1 rollup does NOT consume it." SPEC §6.6.2 also says partner keys surface exact dollars for all providers. This code makes the flag load-bearing and removes a provider from every leaderboard table, so Step 3 cannot produce the locked v0.1 public or partner projection for that provider.

Minimal fix: Keep the provider-visibility read/left-join/default tuple for `mode` defaulting evidence, but do not branch on `blocked_from_partner_projection` in v0.1. Replace `TestRollupBlockedProviderExcluded` with a test that proves a `blocked_from_partner_projection = TRUE` row is still materialized in `stats_leaderboard_*` and that absence still defaults to `mode='bucketed' AND blocked=FALSE` for the join contract.

### HIGH 2 — `backfill_mode = "partial"` can start without a rollup-start boundary

File: `phase4-coordinator/cmd/coordinator/main.go:214`

Evidence snippet:

```go
case "partial":
    if cfg.Stats.Rollup.PartialHistorySince == "" {
        // Allow empty for dev/test: partial mode with
        // no boundary behaves identically to full at
        // the OLTP-scan layer. The §9.7 Step 3
        // `partial_history_since` JSON field is only
        // emitted when a boundary is set.
        partialUnix = 0
```

Why: BUILD §2 Step 2 and SPEC §9.7 require Path A partial-history mode to use `partial_history_since` as the rollup-start boundary, and Step 3 emits the same value on `30d`/`all` responses while history is short. With the current default (`backfill_mode` defaults to `partial`) and an empty boundary, the rollup runs with `PartialHistorySinceUnix = 0`, which is full-history behavior, while Step 3 has no timestamp to emit. Two conforming Step 2/3 implementers could now disagree about whether `"partial"` means Path A or an implicit Path B.

Minimal fix: When stats are enabled and `backfill_mode = "partial"`, require a non-empty RFC3339 `partial_history_since` before starting the rollup. Keep `backfill_mode = "full"` as the explicit way to force `PartialHistorySinceUnix = 0`. Add a coordinator/config test for partial+missing, partial+bad timestamp, partial+valid timestamp, and full+empty.

### HIGH 3 — 30d/all per-cadence path still full-recomputes and defers the §9.3 incremental merge seam

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:15`

Evidence snippet:

```go
// runLeaderboardTick recomputes a single `stats_leaderboard_*`
// window from scratch.
...
if _, err := tx.ExecContext(ctx, fmt.Sprintf(`DELETE FROM %s`, table)); err != nil {
```

File: `phase4-coordinator/internal/stats/rollup/late_events.go:26`

```go
// the SPEC §9.3 INCREMENTAL MERGE optimization is deferred.
...
// but the incremental-merge optimization itself
// (avoiding the full recompute) remains a v0.2 candidate.
```

Why: SPEC §9.3 is not just an optimization note: for `30d` and `all`, it says full recompute is too expensive, the cadence job MUST scan a `last_processed_at - 48h` lookback and merge corrections into the existing snapshot, and events older than the lookback are recorded into `stats_late_events` for the nightly full rebuild. This implementation full-recomputes `30d` and `all` on every cadence tick, so an older-than-lookback event is both recorded in `stats_late_events` and already folded into the live snapshot before the nightly rebuild. That omits the structural incremental seam Step 2 is supposed to hand to Step 3/4 operations.

Minimal fix: Split leaderboard cadence behavior by window. Keep full recompute for `24h` and `7d`; implement the `30d`/`all` incremental merge using a persisted last-processed boundary and the configurable lookback; record older events without folding them into the live snapshot until `RunNightlyRebuild`. Add a test that a `T-60h` event is recorded in `stats_late_events` but does not change the 30d/all live snapshot until the nightly rebuild.

### LOW 1 — retention floor clamp+warn is not pinned by a focused test

File: `phase4-coordinator/internal/stats/rollup/runner.go:50`

Evidence snippet:

```go
if applied.LateEventsRetentionDays > 0 && applied.LateEventsRetentionDays < 30 {
    logger.Warn().
        Int("requested", applied.LateEventsRetentionDays).
        Int("clamped_to", 30).
        Msg("stats.rollup.late_events_retention_days below SPEC §9.3 floor; clamping to 30 days")
    applied.LateEventsRetentionDays = 30
}
```

Why: The implementation chose the allowed clamp+warn posture, so this is not a behavior blocker. BUILD §2 Step 2 also says the chosen behavior must be pinned in tests; the current unit tests cover defaults and invalid lookback, and integration covers default 90-day retention, but no test asserts `15` clamps to `30` and emits the warning path.

Minimal fix: Add a unit test around `New` with `LateEventsRetentionDays = 15`, asserting construction succeeds and the effective retention is 30. If logger capture is already available, assert the warning event too; otherwise assert the behavior and leave log capture to CODE lane.

## Previously Flagged r1 Items

- ARCH r1 CRITICAL 1 (rewards-only provider bypasses `provider_tokens`): **closed** — `aggregateRewardsPerProvider` joins `provider_tokens`.
- ARCH r1 CRITICAL 2 (30d/all rebuild not one transaction): **closed** — `runNightlyRebuild` computes both row sets, opens one transaction, writes both tables, then commits.
- ARCH r1 HIGH 1 (late-event path deferred): **partially closed / still HIGH** — `stats_late_events` is now populated, but the §9.3 incremental-merge cadence seam is explicitly deferred.
- ARCH r1 HIGH 2 (`BackfillMode` not authoritative): **partially closed / still HIGH** — `full` forces zero boundary and invalid partial timestamps fail, but partial+empty still behaves as full.
- ARCH r1 HIGH 3 (`provider_visibility` loaded but ignored): **over-corrected / still HIGH** — visibility is now applied, but it consumes the deferred blocked flag.
- ARCH r1 HIGH 4 (per-job panic recovery stops job): **closed** — recovery moved inside `runOne`, so a panicking tick records health failure and the ticker continues.

## Final Verdict

`READY TO LOCK`: **NO**

Blocking count:
- CRITICAL: 0
- HIGH: 3
- MEDIUM: 0
- LOW: 1
- INFO: 0

Required before lock: remove v0.2 blocked-provider behavior from the rollup, make partial backfill require a real rollup-start timestamp when stats are enabled, and implement the §9.3 incremental merge seam for `30d`/`all` cadence ticks instead of full-recomputing those windows every tick.
