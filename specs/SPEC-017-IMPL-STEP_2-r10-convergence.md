# SPEC-017 IMPL Step 2 — Convergence Record (round 10)

Branch: `impl/spec-017-step-1` / PR #173
HEAD at convergence: `7bf90d0`
Step 1 base: `b499327` (converged 4-round loop, see
`specs/SPEC-017-IMPL-STEP_1-r4-convergence.md`)
Step 2 scope: rollup pipeline (overview / timeseries / leaderboard /
rewards_populated / Shape C nightly rebuild / late events /
incremental merge / drift detection) under
`phase4-coordinator/internal/stats/rollup/`.

## Lock targets

Per BUILD §2.1: each of three independent codex lanes (ARCH / CODE /
SECURITY) must return **0 CRITICAL + 0 HIGH + 0 MEDIUM** before the
step is considered converged. LOW + INFO MAY be deferred and are
acknowledged here.

## Final round counts

| Lane     | Round | Verdict       | Counts                        |
|----------|-------|---------------|-------------------------------|
| ARCH     | r6    | READY TO LOCK | 0C / 0H / 0M / 0L / 1 INFO    |
| SECURITY | r6    | READY TO LOCK | 0C / 0H / 0M / 0L / 0 INFO    |
| CODE     | r10   | READY TO LOCK | 0C / 0H / 0M / 0L / 10 INFO   |

All three lanes hit lock criteria at HEAD `7bf90d0`.

## Per-round trajectory

### ARCH

| Round | Tip       | Notable findings                                              | Closures |
|-------|-----------|---------------------------------------------------------------|----------|
| r1    | initial   | 4 CRIT — Shape C atomic, identity trust, drift, rebuild scope | r2       |
| r2    | r1 fixes  | 1 HIGH unanimous (blocked_from_partner_projection branch)     | r3       |
| r3    | r2 fixes  | 1 HIGH (no incremental-merge for 30d/all)                     | r4       |
| r4    | r3 fixes  | 1 HIGH (incremental missed aging-out providers)               | r5       |
| r5    | r4 fixes  | 2 HIGH (visibility seam, drift union)                         | r6       |
| **r6**| **r5 fixes** | **0/0/0 — LOCKED**                                          | —        |

### SECURITY

| Round | Tip       | Notable findings                                  | Closures |
|-------|-----------|---------------------------------------------------|----------|
| r1    | initial   | 1 CRIT (rewards bypass), 2 HIGH                   | r2       |
| r2    | r1 fixes  | 1 MED comment drift; runtime password literal     | r3       |
| r3    | r2 fixes  | **0/0/0 — LOCKED**                                | —        |
| r4    | r3 fixes  | LOW comment drift only                            | r5       |
| r5    | r4 fixes  | **0/0/0/0 — LOCKED**                              | —        |
| **r6**| **r5 fixes** | **0/0/0 — LOCKED** (visibility delta verified)  | —        |

### CODE

| Round | Tip       | Notable findings                                              | Closures |
|-------|-----------|---------------------------------------------------------------|----------|
| r1    | initial   | 4 CRIT (work-only panic, rewards bypass, atomic, late events) | r2       |
| r2    | r1 fixes  | 3 HIGH (timeseries health stale, partial backfill, advisory)  | r3       |
| r3    | r2 fixes  | 1 HIGH effective-token + 2 MED                                | r4       |
| r4    | r3 fixes  | 1 HIGH rewards last_seen, 1 HIGH late-event watermark         | r5       |
| r5    | r4 fixes  | 1 HIGH updated_at_utc, 1 MED Shape C content equality         | r6       |
| r6    | r5 fixes  | 1 HIGH bucket precision NUMERIC(18,2), 1 MED drift schema     | r7       |
| r7    | r6 fixes  | 1 HIGH stale p_tiny test expectation                          | r8       |
| r8    | r7 fix    | 1 HIGH raw provider_tokens JOIN multiplication                | r9       |
| r9    | r8 fix    | 1 MED incremental rewards MIN(unix_ts), 1 LOW gofmt           | r10      |
| **r10**| **r9 fixes**| **0/0/0/0/10 INFO — LOCKED**                                | —        |

## Lock commits

| Lane      | Lock tip   | Lane HEAD recording the lock                |
|-----------|------------|---------------------------------------------|
| ARCH r6   | `f2e2415`  | round-5 fixes (visibility seam + drift union) |
| SECURITY r6 | `f2e2415` | same (round-5 delta introduced no regressions) |
| CODE r10  | `7bf90d0`  | round-9 fixes (incremental rewards parity + gofmt) |

## Live CI signal at convergence

`gh pr checks 173` at `7bf90d0`:

- `phase4-coordinator (stats Postgres AC-9/10/19/20)` — PASS
- `phase4-coordinator (go vet + test)` — PASS
- `phase4-coordinator (golangci-lint depguard AC-16)` — PASS
- `phase5-gateway (go vet + test)` — PASS
- `phase7-verify (go vet + test)` — PASS
- `phase7-verify integration (fixtures)` — PASS
- `integration (cross-service)` — PASS
- `spec-014-v0-2-gate` — PASS
- `deploy tooling (check-deploy-config gate)` — PASS
- `spec-015-acceptance` — in progress (unrelated to Step 2)
- `phase3-binary (swift test)` — in progress (unrelated to Step 2)

The live Postgres integration suite — exercising the
testcontainers-based rollup harness — passes at the convergence
tip. Audit lanes were locally Docker-blocked from running the
integration suite; the live CI rig is the source of truth and
catches the same surface (e.g. round-7 stale `p_tiny` seed,
round-8 raw `provider_tokens` JOIN multiplication regression
would have failed CI had the bug shipped).

## Deferred items

None at LOCK level. The 10 INFO entries on CODE r10 are all
positive observations (verifications passed, prior findings
closed) — no deferred work.

## Step 2 deliverables (cumulative on `7bf90d0`)

### Schema + grants (Step 1, unchanged)
- 5 migrations: tables, bootstrap rows, NOLOGIN roles, grants,
  OLTP source grants
- Postgres advisory lock on migrations.Apply
- `stats_rewards_populated.window_label` PK (PG keyword fix)

### Rollup runtime (Step 2)
- `internal/stats/rollup/` package — runner, per-table jobs
- Per-tick panic recovery (NOT goroutine-level); type-name-only
  panic classification (no message leak)
- Per-table `time.NewTicker`; shutdownCtx cancellation; drain
- `Pools.Rollup` injected; no boot-time migrations through the
  rollup role

### Per-table jobs
- Overview tick: cumulative tokens_in/out + requests via
  effective-token SQL; live snapshot from injected
  `SnapshotProvider` (interface; `ZeroSnapshotProvider` default)
- Timeseries rpm/tpm 30-min rolling; `bucketEnd` truncated
  separately from `now` so health freshness is per-second
- Leaderboard per window {24h, 7d, 30d, all}:
  - JOIN through `authenticatedProvidersRelation` (DISTINCT
    provider_id from provider_tokens) — closes raw-JOIN
    multiplication under revoke/reissue history
  - work + rewards aggregates via `JOIN provider_tokens` for
    SPEC-002 v1.4 §7 trust-source enforcement
  - `provider_visibility` LEFT JOIN with COALESCE defaults
    (`mode='bucketed'`, `blocked=FALSE`); v0.1 does NOT branch
    on `blocked_from_partner_projection`
  - Bucket comparison after `roundToCents` so the stored
    NUMERIC(18,2) value agrees with the bucket at $0.005,
    $4.995, $49.995, $99.995 boundaries
  - Deterministic ranks with `provider_id` tie-break
  - `generated_at` = single tick `now` for every row
- Incremental 30d/all per SPEC §9.3:
  - bootstrap → full recompute; subsequent → lookback + active
    providers + aging-out slice + drop-out deletion + rerank
  - rewards aggregate selects both `MIN(unix_ts)` and
    `MAX(unix_ts)`; merged via earliest-first / latest-last
    semantics
- Shape C nightly rebuild:
  - DELETE+INSERT both 30d AND all in ONE
    `sql.LevelReadCommitted` transaction
  - drift detection over `pre ∪ rebuilt` (catches stale-row
    drop-outs); structured log includes `component`, `axis`,
    `divergence_pct`, `delta_ratio`, `provider_id_sample`
  - 90-day retention DELETE on `stats_late_events` post-commit
- Late events:
  - GREATEST(created_at_utc, COALESCE(updated_at_utc,
    created_at_utc)) > lastOK as TIMESTAMPTZ — catches SPEC-005
    correction UPDATEs, not just new inserts
  - Postgres advisory lock serializes concurrent 30d/all
    anti-join inserts
  - Rewards-side recording skipped in v0.1 (no arrival watermark
    in §9.1a schema; v0.2 unblocks)
- rewards_populated:
  - `EXISTS` query over `provider_rewards_ledger`; PK
    `window_label`; empty-ledger semantic is FALSE

### Configuration
- `stats.rollup.usd_per_million_credits` (default 1.0)
- `late_events_retention_days` (default 90, clamps (0,30) → 30
  with warning, rejects negative)
- `backfill_mode` `partial` or `full`; `partial` requires
  RFC3339 `partial_history_since` (fail-closed at startup)
- All cadences as SPEC §9.2 v0.1.7 pins

### Test coverage
- `phase4-coordinator/internal/stats/rollup_integration_test.go`
  — testcontainers-based suite, ~30 named tests including
  round-by-round regressions for each closed finding
- New round-5 to round-9 regressions:
  - `TestRollupVisibilityDefaultTuple`
  - `TestRollupDriftFiresOnProviderDeletedByRebuild`
  - `TestRollupLateEventUpdatedAtCorrection`
  - `TestShapeCRebuild_MVCCNoEmptyState` (full content equality)
  - `TestRollupNoMultiplicationOnRevokedTokenHistory`
  - `TestRollupIncrementalRewardsFirstSeenParity`
- `phase4-coordinator/internal/stats/rollup/bucket_test.go` —
  `TestRoundToCentsBucketBoundaries` covers $0.005 → "$",
  $4.995 → "$$", $49.995 → "$$$", $99.995 → "$$"
- `phase4-coordinator/internal/stats/rollup/rebuild_test.go` —
  drift redaction + `component` / `divergence_pct` shape
- Test seam `ComputeLeaderboardRowsForTest` for content-equality
  assertions

## Audit cycle observations (carry-over to Step 3)

- 10 rounds is on the upper end for a single step. Each round
  surfaced finer-grain issues exactly matching the
  [[audit-cycles-are-design-discovery]] pattern: visibility seam
  → drift union → late-event GREATEST → bucket precision →
  stale test → raw JOIN multiplication → incremental
  rewards first_seen. Convergence is non-monotonic in scope
  (round 8 broke ground on a real-schema gap that the stub
  masked).
- Live CI catches things audit lanes can't (rootless Docker
  blocked all 3 lanes from running the integration tests
  locally). The CI failure at `9d9b...` matched the audit's
  written finding 1:1 — the discipline is "both audit AND CI."
- The stub-schema-mirrors-real-auth-schema discipline
  (round-8) is a permanent rollup-test rule. Add to memory.

## Step 3 starting state

Step 3 will land HTTP handlers on top of this lock at
`7bf90d0`. The rollup's storage contract is now stable:
- `stats_overview_current` singleton, 14 columns
- `stats_timeseries_{rpm,tpm}_30m` 30 minute rolling
- `stats_leaderboard_{24h,7d,30d,all}` per-provider, ranks +
  bucketed earnings (NUMERIC(18,2)-aligned) + visibility tuple
- `stats_rewards_populated` per window_label
- `stats_components_health` 7 enum components with
  `generated_at` / `last_ok_at` / `last_error_at` /
  `last_error_message`
- `stats_late_events` for nightly reconciliation
- Drift events emitted as structured log
  (`stats_rollup_drift_detected` with `component` /
  `divergence_pct`)
