# AUDIT_SPEC_017_IMPL_STEP_2 — Code lane

Operator-paste prompt to audit the **Step 2 IMPL code** (rollup
pipeline) from the CODE lens — query correctness, transaction
boundaries, error handling, idempotency, idiomatic Go, dependency
hygiene, test adequacy.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_2-code-rM-audit.md` (fresh per round).

---

```
=== BEGIN PROMPT ===

You are auditing the Step 2 IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) from the CODE lens — bugs,
incorrect SQL, race conditions, leaks, idiomatic Go, tests.

Output: specs/SPEC-017-IMPL-STEP_2-code-rM-audit.md (round M;
fresh per round).

Severity model:
- CRITICAL — a bug that ships Step 2 broken OR a contract
  violation Step 3 inherits (e.g. transaction boundary that
  leaves stats_* in inconsistent state under panic, race in
  per-table scheduling that misses ticks for one component,
  rewards_populated boolean inverted, drift detection
  comparison wrong direction).
- HIGH — a real bug with a workaround (e.g. forgotten ORDER BY
  in a leaderboard tie-break, off-by-one in window boundary,
  retry storm on a single-tick failure).
- MEDIUM — style / clarity / minor correctness; two conforming
  sessions resolve the same way once flagged.
- LOW — polish.
- INFO — observations.

## Critical constraints

1. The rollup is the FIRST time SPEC-017 writes Postgres rows.
   Patterns set here propagate to every future stats write.
   Any pattern future steps would have to undo is HIGH or
   CRITICAL.
2. Each tick is transactional. A panic mid-tick MUST NOT leave
   `stats_components_health.generated_at` advanced without the
   corresponding row write.
3. Shape C atomicity (§9.4 v0.1.8): rebuild MUST be wrapped in
   a single BEGIN/COMMIT with READ COMMITTED isolation; failed
   transactions MUST roll back leaving the pre-rebuild snapshot
   intact. The test must prove (i) failed-rebuild rollback,
   (ii) MVCC no-empty-state for concurrent readers, (iii)
   post-commit equivalence.
4. Late-event retention DELETE runs AFTER the rebuild commits
   (BUILD §2 Step 2 + §9.3). Same-tx coupling is CRITICAL.
5. Drift detection per axis (earnings/tokens/jobs) — NOT a
   single aggregate "did anything differ" check.
   Per-axis specifically because operators want to know which
   counter drifted.
6. Cadence implementation: use `time.NewTicker` with a stop
   channel tied to the shutdown context. A `time.Sleep` loop
   is a regression (no stop signal).

## Required reading

1. `specs/BUILD_SPEC_017_IMPL_PROMPT.md` §2 Step 2.
2. `specs/SPEC-017-network-stats-api.md` v0.1.8 §6.2, §9.1,
   §9.1a, §9.2, §9.3, §9.4, §9.5, §9.6, §9.7.
3. The Step 2 diff.
4. `phase4-coordinator/internal/billing/store.go:44-180` — the
   actual SPEC-005 v0.3 ledger column shapes the rollup
   queries against (note that the live production store is
   SQLite but Step 2 queries a Postgres-shape mirror — the
   column NAMES are normative, the TYPES adapt; the IMPL
   author is expected to use Postgres TIMESTAMPTZ in the
   rollup queries even though the live billing store uses
   TEXT ts_utc).
5. `phase4-coordinator/internal/auth/tokens.go:247` — the
   `provider_tokens` table shape Step 2 joins on for
   provider-identity authentication.

## Code audit categories

### A. SQL correctness vs schema
A.1  Every rollup query INSERTs the full column list per the
     locked §9.1 stats_* table. Missing columns cause NOT NULL
     violations.
A.2  Type-correct comparisons: NUMERIC(18,2) for $ totals,
     BIGINT for tokens/jobs, TIMESTAMPTZ for windows.
A.3  Window boundary arithmetic: `now() - INTERVAL '24 hours'`
     for the 24h window; matching for 7d / 30d. The `all`
     window starts at `partial_history_since` (when set) or
     epoch.
A.4  ORDER BY is deterministic for rank computation (tie-break
     by `provider_id` text). Non-deterministic ranks cause
     pseudonym churn between ticks.
A.5  Bucket computation uses `>=` for inclusive lower bound and
     `<` for exclusive upper bound, matching §6.2 `[a, b)`.

### B. Transaction boundaries
B.1  Each per-tick UPSERT or DELETE+INSERT runs in one
     transaction. The corresponding
     `stats_components_health` UPDATE runs in the SAME
     transaction. Otherwise a panic between write and health
     update lies about freshness.
B.2  Shape C rebuild's `BEGIN ISOLATION LEVEL READ COMMITTED`
     is explicit. Default isolation may differ across
     deployments.
B.3  Late-event retention DELETE is its own (non-transactional)
     statement OR a separate single-statement transaction —
     NEVER nested inside the rebuild tx.
B.4  `defer tx.Rollback()` followed by `tx.Commit()` is the
     canonical pattern — Rollback after Commit returns
     ErrTxDone, which is fine; reversed order risks
     double-commit on retry.

### C. Concurrency
C.1  Per-table goroutines are started ONCE; restart-on-panic
     loops do not unbounded-recurse.
C.2  Tickers are stopped on shutdown context cancellation; no
     goroutine leak.
C.3  No shared mutable state between per-table jobs (each job
     owns its query + write path).

### D. Drift detection + late events
D.1  Drift comparison: `(rebuild - incremental) / max(rebuild, 1)
     > 0.005` per axis. Division-by-zero guarded.
D.2  Drift log event is structured (zerolog), includes
     `component=`, `axis=`, `delta=`, sample `provider_id`,
     window. NO raw token, NO DSN.
D.3  Late-event INSERT into `stats_late_events` uses the
     BIGSERIAL sequence (USAGE,SELECT granted to stats_rollup
     per §7.2.2). The INSERT supplies `event_unix_ts`,
     `provider_id`, `delta_usd` OR `delta_tokens` (not both
     required), `source_billing_row`.
D.4  Retention DELETE: `recorded_at < now() - INTERVAL
     '<retention_days> days'`. Days from config; clamp-or-fail
     below 30 per the pinned behavior.

### E. rewards_populated
E.1  Per window, EXISTS query against provider_rewards_ledger
     (NOT COUNT(*) — EXISTS is the cheap probe).
E.2  Result UPSERTed into stats_rewards_populated by
     window_label (the renamed column from Step 1 — DO NOT
     reintroduce the reserved keyword `window`).
E.3  Default value `FALSE` for empty ledger; bootstrap rows
     from Step 1's 002 migration already cover this.

### F. Bucket + left-join + provider-identity
F.1  Bucket computation: hot-path call (one per provider per
     window). Implemented as a pure function on
     `(window, NUMERIC(18,2))` — easy to unit-test.
F.2  Left-join SQL: `LEFT JOIN provider_visibility v ON v.provider_id
     = pt.provider_id` and `COALESCE(v.mode, 'bucketed')` +
     `COALESCE(v.blocked_from_partner_projection, FALSE)`.
F.3  Provider-identity join: `JOIN provider_tokens pt ON
     pt.provider_id = lrc.provider_id` (or the
     downstream-from-pt surface). NO join on
     `provider_session` / `provider_handshake`.

### G. Backfill + main.go integration
G.1  Path A (partial): rollup queries OLTP from
     `partial_history_since` forward.
G.2  Path B (full): rollup queries OLTP from
     `(now() - <window length>)` for each window — same as
     Path A once history catches up.
G.3  main.go starts rollup goroutines only when
     `cfg.Stats.Enabled = true`; uses `shutdownCtx` for
     cancellation; defers drain.

### H. Tests (integration + unit)
H.1  Integration: each tick advances correct
     stats_components_health row; failed tick preserves
     last_ok_at; rpm-only failure leaves tpm fresh.
H.2  Integration: Shape C rebuild — three sub-assertions
     (failed-rebuild rollback, MVCC no-empty-state, post-commit
     equivalence).
H.3  Integration: late event at T-30h folds into 30d snapshot;
     T-60h lands in stats_late_events; nightly rebuild
     reconciles.
H.4  Integration: stats_late_events retention DELETE removes
     100-day row, preserves 30-day row.
H.5  Integration: drift > 0.5% triggers
     stats_rollup_drift_detected event AND rebuild value wins.
H.6  Integration: rewards_populated FALSE on empty ledger;
     TRUE when ledger row inside window.
H.7  Integration: bucket boundaries per §6.2 (4.99, 5.00, 49.99,
     50.00).
H.8  Integration: provider with no provider_visibility row
     produces a leaderboard row with bucketed semantics.
H.9  Unit: bucket function is a pure mapping —
     `(window, NUMERIC) -> "$"|"$$"|"$$$"|"-"`.
H.10 Unit: drift computation handles divide-by-zero +
     zero-on-both-sides.

## Output format

Per-category one-line verdict + per-finding entries (severity,
file:line, evidence, why, fix). Final verdict block.

`READY TO LOCK` iff 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
