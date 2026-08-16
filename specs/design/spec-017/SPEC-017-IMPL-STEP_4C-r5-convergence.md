# SPEC-017 IMPL Step 4.C — Convergence Record (round 1 in-progress)

Branch: `impl/spec-017-step-1` / PR #173
Step 4.B base: `022cd55` (per
`specs/SPEC-017-IMPL-STEP_4B-{arch,code,security}-r{3,4}-audit.md`).
Step 4.C scope: structured-log events, Prometheus metrics with
label hygiene, OPS.md runbook + §6.6.2 disclosure obligation +
sign-off template, public CHANGELOG, AC-20 CI assertion, metric-
label hygiene test, end-of-impl 22-AC sweep.

This is the round-1 in-progress convergence record. The audit
loop is still open; the file will be re-stamped at each audit
round until all three lanes return 0 CRITICAL + 0 HIGH + 0 MEDIUM.

## §6.6.2 sign-off template (quoted verbatim from `OPS.md` §10.5)

```
PARTNER-KEY PRODUCTION ISSUANCE SIGN-OFF — SPEC-017 v0.1.8 §6.6.2

SPEC-014 v0.9 commit SHA       : <fill: 40-char SHA>
SPEC-014 v0.9 portal deploy date: <fill: YYYY-MM-DD>
Provider-creation disclosure live: <fill: YES/NO + date>
Existing-provider disclosure live: <fill: YES/NO + date>
Operator name + role            : <fill: e.g. "augstar — sole operator">
Signed off at                   : <fill: ISO 8601 UTC>
```

**Live production sign-off status: NOT YET SATISFIED.**

SPEC-014 v0.9 commit SHA + date both disclosure surfaces went
live = **NOT YET — remains a cutover prerequisite before first
production partner-key issuance.** Per BUILD §2 Step 4.C v11
ARCH r10 H1: this convergence file may be sealed with the live
deployment still pending. The Step 4.C PR merges with this
template + the runbook checkbox in OPS.md; the live sign-off is
the operator-side cutover act executed AFTER the merge.

## End-of-implementation 22-AC sweep

Each row records: owner step, test file/path, last green CI run
or local PASS evidence. AC-22 was added in v0.1.8.

| AC    | Owner step      | Test location (path::test name)                                                                                                  | Status |
|-------|-----------------|----------------------------------------------------------------------------------------------------------------------------------|--------|
| AC-1  | Step 3          | `phase4-coordinator/internal/stats/handlers_integration_test.go::TestAC1_OverviewLockedShape`                                    | PASS (Step 3 r8 LOCKED) |
| AC-2  | Step 3          | `phase4-coordinator/internal/stats/handlers_integration_test.go::TestAC2_OverviewETag304RoundTrip`                               | PASS |
| AC-3  | Step 3 + Step 4.B | `internal/stats/handlers_integration_test.go::TestAC3_*` + `dist/test/check_nginx_stats_test.sh::AC-3 nginx-tier`               | PASS |
| AC-4  | Step 3          | `internal/stats/handlers_integration_test.go::TestAC4_LeaderboardLockedShape`                                                    | PASS |
| AC-5  | Step 3          | `internal/stats/handlers_integration_test.go::TestAC5_LeaderboardPagination`                                                     | PASS |
| AC-6  | Step 3          | `internal/stats/handlers_integration_test.go::TestAC6_PartnerProjection`                                                          | PASS |
| AC-7  | Step 3          | `internal/stats/handlers_integration_test.go::TestAC7_HealthMap` (+ §9.5 budgets in `health_status_test.go`)                     | PASS |
| AC-8  | Step 4.B        | `phase4-coordinator/dist/test/check_nginx_stats_test.sh::AC-8 60+1 envelope`                                                      | PASS (CI / docker-gated) |
| AC-9  | Step 1          | `internal/stats/integration_test.go::TestAC9_StatsReaderPermissionDeniedOnLedger`                                                | PASS |
| AC-10 | Step 1          | `internal/stats/integration_test.go::TestAC10_ProviderVisibilityCommitAndRollback`                                                | PASS |
| AC-11 | Step 3          | `internal/stats/handlers_integration_test.go::TestAC11_RealPanicRecovery_RedactionSweep`                                          | PASS |
| AC-12 | Step 3          | `internal/stats/handlers_integration_test.go::TestAC12_ETagRoundTrip`                                                             | PASS |
| AC-13 | Step 3          | `internal/stats/handlers_integration_test.go::TestAC13_PreflightOPTIONS`                                                          | PASS |
| AC-14 | Step 3          | `internal/stats/handlers_integration_test.go::TestAC14_StaleSeededOverview`                                                       | PASS |
| AC-15 | Step 3 + 4.A + 4.B + 4.C | handler logs: `TestStep4C_StatsRequestServedEvent`; recover panic: `TestStep4C_StatsHandlerPanicEvent`; CLI journalctl: `cmd/coordinator/partnerkeys_integration_test.go::TestIssueJournalStreamSuppresses`; nginx logs: `dist/test/check_nginx_stats_test.sh::AC-15 access-log redaction`; metric labels: `internal/stats/metrics/metrics_test.go::TestLabelHygiene` + `internal/stats/step4c_integration_test.go::TestStep4C_WiredMux_MetricLabelHygiene` | PASS |
| AC-16 | Step 1          | `.golangci.yml` depguard rules + CI lint job                                                                                      | PASS (every PR) |
| AC-17 | Step 4.A        | `cmd/coordinator/partnerkeys_integration_test.go::TestAC17_IssueLockedSPECCommand` + `_Subprocess`                                | PASS |
| AC-18 | Step 3          | `internal/stats/handlers_integration_test.go::TestAC18_TimingStatistical` (100 samples per row)                                  | PASS |
| AC-19 | Step 1 + Step 3 | Step 1: `integration_test.go::TestAC19_LeftJoinDefault`; Step 3: handler integration of same                                      | PASS |
| AC-20 | Step 1 + Step 4.C | `internal/stats/integration_test.go::TestAC20_NoOperatorExactAuditRow` (runs on every PR via `make test-coordinator-integration`) | PASS |
| AC-21 | Step 3          | `internal/stats/handlers_integration_test.go::TestAC21_405Envelope`                                                               | PASS |
| AC-22 | Step 3          | `internal/stats/handlers_integration_test.go::TestAC22_AuthFailureTier_SQLCounter` (≤300 SELECTs assertion)                       | PASS |

## Step 4.C round-1 closures

Round-1 ARCH/CODE/SECURITY found 1 CRITICAL + 5 HIGH + 4 MEDIUM
unique findings; round-2 fixes landed on top of `2130a87`:

- ARCH C1 + CODE H4 + SECURITY C1 — convergence file missing.
  **Closed by this file.** Sign-off template quoted verbatim; live
  deployment status explicitly recorded as NOT YET.
- ARCH H1 — `stats_handler_panic` field-set drift; extra
  `stats_handler_panic_stack` event widened public taxonomy.
  Closed: middleware now emits ONLY the locked `stats_handler_panic`
  event with `route` + `request_id` fields; the debug stack dump
  is no longer tagged as a `stats_*` event. (Round-2 ARCH M2 /
  CODE H2 follow-on narrowed the event further by removing
  `panic_type` — that triage hint now lives on the untagged
  debug-only stack line.)
- ARCH H2 / SECURITY H1 — `stats_partner_key_issued` contained
  `prefix` (token-derived) + `created_at` (outside locked set).
  Closed: event now emits `id`, `label`, `created_by`,
  `rotated_from_id` only.
- ARCH H3 — CHANGELOG missing per-step PR refs. Closed: per-step
  table now carries a PR column (each row cites #173 for this
  release; future releases will split).
- CODE H1 — auth-failure 429s mislabeled as `tier=public`.
  REOPENED + RE-CLOSED in round 2: round-1's
  `tier="auth_failure"` fix violated BUILD's closed
  `{public, partner}` label vocabulary. Round-2 ARCH M1 reverted
  to the closed set; auth-failure 429s remain labeled
  `tier="public"`, differentiated operationally via
  `endpoint=leaderboard + status=429` (only path that runs the
  auth-failure tier per §4.3) versus public-limiter 429s on
  `/overview` + `/health`. Round-3 CODE H1 (separate finding —
  immutable `r.WithContext` propagation) closed by moving
  `PartnerKeyID` onto the mutable `requestObs` struct pointer.
- CODE H2 — nightly rebuild errors/panics didn't increment
  `stats_rollup_errors_total`. Closed: both the rebuild error
  and panic paths increment the counter for
  `leaderboard_30d` + `leaderboard_all`.
- CODE H3 — `stats_rollup_tick_completed` emitted empty
  `component` for the `rewards_populated` tick. Closed: ticks
  with `c == ""` skip the event (rewards_populated is scalar per
  §6.4 and isn't a §9.5 component).
- CODE H5 — new event emitters untested. Closed: added
  `internal/stats/step4c_integration_test.go` covering
  `stats_request_served` + `stats_handler_panic` field sets +
  wired-mux metric-label hygiene.
- ARCH M1 / CODE M1 — hygiene test was package-synthetic; missing
  Origin-fragment scan. Closed: package test now scans for an
  Origin fragment; wired-mux integration test drives real
  requests through `stats.NewMuxWithMetrics` and asserts no
  attacker-supplied substring lands in any label.
- CODE M2 — `stats_rollup_lag_seconds` untested. Closed in
  round 3: the per-tick SQL pass moved into
  `internal/stats/rollup/observer.go::ObserveRollupLagOnce`, and
  the wired hygiene integration test now drives the gauge through
  that real production helper instead of a synthetic Set() call.
  `cmd/coordinator/main.go::observeRollupLag` is now a thin 15-s
  ticker over the same helper.
- CODE M3 — OPS.md missing "if this fails" recovery paragraphs.
  Closed: §10.1 / 10.2 / 10.3 / 10.4 each carry an
  **If this fails** block.
- ARCH/CODE L1 — whitespace at EOF in Step 4.B r4 audit file.
  Closed via trailing-newline normalization.

## Per-lane trajectory (LOCKED at r5 / r2)

| Lane     | Round | Verdict                | Counts                          |
|----------|-------|------------------------|---------------------------------|
| ARCH     | r1    | NOT READY TO LOCK      | 1C / 3H / 1M / 1L / 9 INFO      |
| ARCH     | r2    | NOT READY TO LOCK      | 0C / 0H / 3M / 1L / 10 INFO     |
| ARCH     | r3    | REQUEST CHANGES        | 0C / 0H / 1M / 1L / 12 INFO     |
| ARCH     | r4    | REQUEST CHANGES        | 0C / 0H / 1M / 1L / 13 INFO     |
| ARCH     | r5    | **READY TO LOCK**      | 0C / 0H / 0M / 0L / 15 INFO     |
| CODE     | r1    | NOT READY TO LOCK      | 0C / 5H / 3M / 2L / various INFO |
| CODE     | r2    | NOT READY TO LOCK      | 0C / 2H / 2M / 0L / various      |
| CODE     | r3    | NOT READY TO LOCK      | 0C / 0H / 3M / 2L / 9 INFO       |
| CODE     | r4    | NOT READY TO LOCK      | 0C / 0H / 2M / 0L / 10 INFO      |
| CODE     | r5    | **READY TO LOCK**      | 0C / 0H / 0M / 0L / 12 INFO      |
| SECURITY | r1    | NOT CONVERGED          | 1C / 1H / 0M / 2L / 8 INFO      |
| SECURITY | r2    | **READY TO LOCK**      | 0C / 0H / 0M / 2L / 9 INFO       |

All three lanes locked. Step 4.C **CONVERGED** on HEAD `fef509c`.

## Round-4 + round-5 closure (added at lock)

### Round 4 (HEAD `bb7c77e`)

- ARCH r4 M1 + CODE r4 M1 — wired hygiene test still had three
  shape gaps: non-SPEC-shaped seeded token, deny list missing
  the actual seeded token/prefix/generic `mpk_`, and no
  family-presence inventory check. **Closed in round 4**: bearer
  is now a SPEC-shaped `mpk_` + 43-char body; deny list now
  includes `{bearer, prefix, "mpk_", "mpk_garbage", "garbage",
  "evil.malibu.tech", "Bearer ", "token_hash"}`; before the
  label scan the test asserts every required family
  (`stats_request_total`, `stats_partner_key_request_total`,
  `stats_rollup_lag_seconds`, `stats_rollup_errors_total`,
  `stats_rate_limit_exceeded_total`) has at least one gathered
  sample; the partner request asserts 200 (test seeds
  `provider_tokens` + ledger row + drives one rollup tick
  beforehand).
- CODE r4 M2 — partner-key issue/revoke event landing tests
  lived behind `//go:build integration` in `cmd/coordinator/`,
  but `make test-coordinator-integration` only ran
  `./internal/stats/...`. **Closed in round 4**: target expanded
  to also run `./cmd/coordinator/...`. The existing CI workflow
  at `.github/workflows/ci.yml:186-187` invokes the make target
  unchanged.
- ARCH r4 L1 — stale "legacy `delta_ratio` kept for backward
  compatibility" comment in `rollup/rebuild.go`. **Closed in
  round 4**: comment reworded — `delta_ratio` was removed from
  the locked `stats_*` event by round-2 ARCH M2 and survives
  only on the untagged debug-only triage line.

### Round 5 (HEAD `fef509c`)

ARCH r5 and CODE r5 both returned **READY TO LOCK** at
0C / 0H / 0M / 0L. ARCH r5 produced 15 INFO entries; CODE r5
produced 12 INFO entries plus an explicit "Round-4 closure
checks" section confirming all three round-4 blockers closed.
SECURITY had already locked at r2. Nine lanes total locked
across Step 4 (4.A ARCH/CODE/SECURITY + 4.B ARCH/CODE/SECURITY
+ 4.C ARCH/CODE/SECURITY).

## Step 4.C deliverables (cumulative)

### Structured-log events (`internal/stats/...`)
- `stats_request_served` — access-log middleware
  (`middleware.go::accessLogMiddleware`).
- `stats_rollup_tick_completed` — rollup runner success path
  (`rollup/runner.go::runOne`).
- `stats_rollup_drift_detected` — rebuild path (existing Step 2
  surface; kept).
- `stats_handler_panic` — recover middleware
  (`middleware.go::recoverMiddleware`); fields: route + request_id
  only (round-2 ARCH M2 / CODE H2 narrowed by removing
  `panic_type`; triage detail lives on an untagged debug-only
  stack-dump line).
- `stats_partner_key_issued` — CLI issue
  (`cmd/coordinator/partnerkeys.go::runPartnerKeysIssue`); fields:
  id, label, created_by, rotated_from_id only.
- `stats_partner_key_revoked` — CLI revoke
  (`cmd/coordinator/partnerkeys.go::runPartnerKeysRevoke`); fields:
  id, reason, actor.

### Prometheus metrics (`internal/stats/metrics/metrics.go`)
- `stats_request_total{endpoint, status, tier}` — Counter
- `stats_partner_key_request_total{partner_key_id}` — Counter
- `stats_rollup_lag_seconds{component}` — Gauge
- `stats_rollup_errors_total{component}` — Counter
- `stats_rate_limit_exceeded_total{tier, endpoint}` — Counter

### OPS.md runbook (`OPS.md` §10)
- 10.1 Rotating a partner key (+ "If this fails")
- 10.2 Revoking a partner key in incident (+ "If this fails")
- 10.3 Restarting the rollup scheduler (+ "If this fails")
- 10.4 Emergency provider-visibility revert (+ "If this fails")
- 10.5 §6.6.2 partner-key exact-$ disclosure obligation +
  sign-off template + NOT YET SATISFIED annotation.

### Public changelog
- `docs/network-stats-api/CHANGELOG.md` v0.1.8 entry; per-step PR
  column.

### Tests
- `internal/stats/metrics/metrics_test.go::TestLabelHygiene` —
  package-level synthetic label scan with denylist + Origin frag.
- `internal/stats/step4c_integration_test.go::TestStep4C_*` —
  wired-mux + new-emitter coverage.
