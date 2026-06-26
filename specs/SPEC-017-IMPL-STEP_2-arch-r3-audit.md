# SPEC-017 IMPL Step 2 — Architecture Audit Round 3

Branch: `impl/spec-017-step-1`  
HEAD audited: `745128e` (`impl(017): Step 2 — round-2 audit fixes`)  
Diff base: Step 1 converged tip `b499327`  
Auditor lane: ARCHITECTURE  
Prior rounds checked:
- `specs/SPEC-017-IMPL-STEP_2-arch-r1-audit.md`
- `specs/SPEC-017-IMPL-STEP_2-arch-r2-audit.md`

Verdict: **NOT READY TO LOCK** — 0 CRITICAL + 1 HIGH + 0 MEDIUM + 2 LOW

Validation evidence:
- Read required Step 2 kickoff, locked SPEC-017 v0.1.8 sections, Step 1 trust-source decision, `004_grants.up.sql`, and prior ARCH r1/r2 audits.
- `git diff --name-status b499327..HEAD` shows Step 2 changes confined to coordinator config/main wiring, `internal/stats/rollup/`, rollup integration tests, stats pool wiring, `.gitignore`, and audit prompt/output files.
- `go test ./internal/stats/...` from `phase4-coordinator/`: **PASS**.
- `go test ./cmd/coordinator -run TestNonExistent` from `phase4-coordinator/`: **PASS** compile smoke, no tests to run.
- `go test -tags=integration ./internal/stats -run 'TestRollup(Backfill|Retention|Blocked|LateEvent|RewardsOnly|Ignores|Generated|WorkOnly)' -count=1`: **BLOCKED LOCALLY** by testcontainers panic `rootless Docker not found`.

## Category Verdicts

A. Rollup scope vs Step 2 / Step 3 boundary: **PASS / LOW** — round-2 fixes removed the v0.2 `blocked_from_partner_projection` behavior and no handler/partner-key/nginx implementation appears in the Step 2 diff. Some stale comments still describe the removed blocked-provider behavior.

B. Per-table jobs vs §9.2 cadences: **PASS** — the seven health components are spawned at the locked cadences, split rpm/tpm health is preserved, and per-tick panic recovery continues the job.

C. Shape C rebuild + drift + retention: **HIGH** — the nightly Shape C rebuild now covers `30d` and `all` in one transaction and retention runs post-commit, but the cadence path still full-recomputes `30d`/`all` and explicitly defers the §9.3 incremental-merge seam.

D. Backfill posture + provider-identity trust: **PASS** — `backfill_mode = "partial"` now requires a valid `partial_history_since`; `full` forces a zero lower bound; work and rewards aggregates join `provider_tokens`.

E. rewards_populated computation: **PASS** — `stats_rewards_populated` is pre-computed by the rollup from `provider_rewards_ledger`; no request-path computation is introduced.

F. Bucket computation + left-join: **PASS / LOW** — bucket thresholds are encoded in rollup and the blocked flag is no longer load-bearing. Stale comments still claim blocked providers are excluded.

G. Package layout + import-graph lint: **PASS** — `go list` for `internal/stats/rollup` shows only standard-library imports plus `zerolog`; no forbidden package imports and no `os.Exit` / `log.Fatal` in rollup code.

H. Failure modes + main.go integration: **PASS / LOW** — signal-driven shutdown cancels `shutdownCtx` before return, so rollup goroutines drain. The defer ordering is fragile on non-signal server-return paths.

## Findings

### HIGH 1 — 30d/all cadence ticks still full-recompute and defer the §9.3 incremental merge seam

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:15`

Evidence snippet:

```go
// runLeaderboardTick recomputes a single `stats_leaderboard_*`
// window from scratch. The window argument is one of
// {"24h", "7d", "30d", "all"}.
```

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:74`

```go
if _, err := tx.ExecContext(ctx, fmt.Sprintf(`DELETE FROM %s`, table)); err != nil {
```

File: `phase4-coordinator/internal/stats/rollup/late_events.go:38`

```go
// v0.1 simplification: SPEC §9.3 incremental-merge optimization
// stays deferred (cadence ticks still full-recompute the
// window).
```

Why: SPEC-017 §9.3 says `30d` and `all` full recompute is too expensive and the rollup job **MUST** scan `last_processed_at - 48h` to `now`, merge corrections into the existing snapshot, and record older late events for nightly full rebuild. BUILD §2 Step 2 repeats that `stats_leaderboard_30d` is "incremental merge per §9.3" and `stats_leaderboard_all` is "incremental + nightly rebuild." The current implementation does a per-cadence `DELETE FROM stats_leaderboard_30d/all` followed by full source aggregation, then records older rows in `stats_late_events` for forensics/nightly reconciliation.

Pearl-scale assessment: the deferral is operationally understandable for v0.1 volume, and it may be acceptable as an implementation shortcut if the team chooses to ship a known SPEC deviation. It is not acceptable under the locked audit contract: §9.3 is normative MUST language, and the audit prompt classifies omission of a structural Step 2 seam as HIGH. This also means a `T-60h` row is already folded into the live `30d/all` snapshot by the full recompute before the nightly rebuild, which is not the locked late-event correction shape.

Minimal fix: Split cadence behavior by window. Keep full recompute for `24h` and `7d`; implement a persisted last-processed boundary for `30d` and `all`, merge only the configurable lookback range into the existing snapshot, and record older-than-lookback events without changing the live snapshot until `RunNightlyRebuild`. Add a test that a `T-60h` event is recorded in `stats_late_events` but does not affect `stats_leaderboard_30d/all` until the nightly rebuild.

### LOW 1 — stale blocked-provider comments describe behavior round 2 removed

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:31`

Evidence snippet:

```go
// provider_visibility left-join applied at storage
// time — the rollup persists the EFFECTIVE
// `provider_visibility` tuple by skipping the provider's
// row entirely from leaderboard storage when
// `blocked_from_partner_projection = TRUE`
```

File: `phase4-coordinator/internal/stats/rollup/leaderboard.go:132`

```go
// providers with
// `blocked_from_partner_projection = TRUE` are EXCLUDED from
// the leaderboard storage entirely
```

Why: The executable code at `leaderboard.go:169-180` now intentionally reads `visibility[pid]` and does not branch on `.Blocked`, matching the round-2 fix. The stale comments still document the old v0.2 behavior and can mislead a Step 3/4 modifier into reintroducing the exact issue r2 closed.

Minimal fix: Replace those comment blocks with the current v0.1 invariant: the rollup may load the tuple to prove/default visibility semantics, but it must not branch on `blocked_from_partner_projection`; Step 3 performs projection/redaction and v0.2 defines any partner-projection suppression semantics.

### LOW 2 — rollup drain defer ordering is fragile outside the signal path

File: `phase4-coordinator/cmd/coordinator/main.go:183`

Evidence snippet:

```go
shutdownCtx, stopBackground := context.WithCancel(context.Background())
defer stopBackground()
```

File: `phase4-coordinator/cmd/coordinator/main.go:258`

```go
defer func() {
    if statsRollup != nil {
        statsRollup.Wait()
    }
}()
```

Why: Defers run LIFO, so on a non-signal return path the `statsRollup.Wait()` defer runs before the `stopBackground()` defer cancels `shutdownCtx`. The intended SIGINT/SIGTERM path calls `stopBackground()` explicitly before returning, so normal operator shutdown drains correctly. The ordering is still a fragile main.go integration edge: any future clean server-return path that does not call `stopBackground()` first can block forever waiting on still-running rollup goroutines.

Minimal fix: Combine the cleanup into one defer registered after `statsRollup` is declared, or register the defers so cancellation always precedes `Wait()`:

```go
defer func() {
    stopBackground()
    if statsRollup != nil {
        statsRollup.Wait()
    }
}()
```

## Previously Flagged r2 Items

- ARCH r2 HIGH 1 (rollup implements deferred `blocked_from_partner_projection` semantics): **closed behaviorally** — code no longer branches on `.Blocked`, and `TestRollupBlockedProviderStillAppearsInV01` pins the v0.1 behavior. Stale comments remain LOW 1.
- ARCH r2 HIGH 2 (`backfill_mode = "partial"` can start without a boundary): **closed** — `cmd/coordinator/main.go` now fails startup for partial+empty or partial+invalid timestamp and uses `full` for unconstrained history.
- ARCH r2 HIGH 3 (§9.3 incremental merge seam deferred): **still HIGH** — the implementation now documents the deferral explicitly, but the locked SPEC/BUILD contract still requires the seam.
- ARCH r2 LOW 1 (retention floor clamp+warn not pinned): **closed** — `TestRollupRetentionClampWarn` covers `LateEventsRetentionDays = 15`.

## Final Verdict

`READY TO LOCK`: **NO**

Blocking count:
- CRITICAL: 0
- HIGH: 1
- MEDIUM: 0
- LOW: 2
- INFO: 0

Required before lock: implement the §9.3 incremental-merge cadence path for `stats_leaderboard_30d` and `stats_leaderboard_all`, or explicitly accept this as a known locked-SPEC deviation outside the audit lock target. Under the requested lock target, the current Step 2 diff remains blocked.
