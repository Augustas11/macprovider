# AUDIT_SPEC_017_IMPL_STEP_2 — Architecture lane

Operator-paste prompt to audit the **Step 2 IMPL code** (rollup
pipeline) under PR `Augustas11/macprovider#173` from the
architecture lens.

Audit target is the **Step 2 implementation diff** layered on top
of the converged Step 1 (HEAD `b499327` or later). SPEC-017
v0.1.8 is LOCKED; `BUILD_SPEC_017_IMPL_PROMPT.md` is the
controlling kickoff; `specs/SPEC-017-IMPL-STEP_1-r4-convergence.md`
is the Step 1 convergence record.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM. LOW + INFO MAY be deferred and
acknowledged in the convergence file.

Each round writes
`specs/SPEC-017-IMPL-STEP_2-arch-rM-audit.md` — new file per
round, NEVER append.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 2 IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) of github.com/Augustas11/macprovider,
from the ARCHITECTURE lens.

Output: specs/SPEC-017-IMPL-STEP_2-arch-rM-audit.md (round M;
fresh file per round, never append).

Severity model:
- CRITICAL — Step 2 code would brick Step 3/4 (e.g. handler
  contract that the rollup cannot satisfy, ALTER on a stats_*
  table the locked grants forbid, mux registration that violates
  the §C.4 disabled-state invariant), OR violates a locked SPEC
  invariant (e.g. rebuild atomicity broken, drift detection
  silenced, rewards_populated computed on the request path
  instead of in the rollup, provider-identity sourced from
  hello-frame instead of provider_tokens per the Step 1 trust-
  source decision).
- HIGH — would force a v0.2 fix-round within the first month,
  structurally misaligns Step 2 with Steps 3/4 (e.g. rollup
  writes a stats_* column the handler-side Step 3 doesn't
  enumerate), or omits a structural seam BUILD §2 Step 2 pins.
- MEDIUM — two conforming Step 2 sessions could resolve a Step
  2 decision differently; missing structural guidance bleeds
  into Step 3's audit.
- LOW — polish / quality / non-blocking.
- INFO — observations.

## Critical constraints to honor while auditing

1. SPEC-017 v0.1.8 is LOCKED. Findings that would require a
   SPEC change are HIGH or CRITICAL; do NOT propose SPEC
   changes as fixes; propose Step 2 code rewrites.
2. The Step 2 scope is fixed by BUILD §2 Step 2: rollup
   pipeline under `phase4-coordinator/internal/stats/rollup/`.
   Out-of-scope items in the diff (HTTP handlers, partner-key
   CLI subcommands, nginx config, observability events beyond
   the rollup's own emit) are CRITICAL scope creep.
3. The four locked design picks (separate rollup pipeline,
   public overview + optional partner keys on leaderboard,
   bucketed-default + opt-in exact, embed in coordinator
   binary) MUST NOT be flipped. Any rollup query that silently
   surfaces exact $ for `mode='bucketed'` providers is
   CRITICAL.
4. **Provider-identity trust source (Step 1 decision record
   at `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`).**
   The rollup MUST join on SPEC-002 v1.4 §7 `provider_tokens`
   when materializing `provider_id` in any `stats_*` table.
   Joining on `provider_session` / `provider_handshake` / any
   raw hello-frame surface — even via a view — is CRITICAL.
5. **Shape C rebuild atomicity (§9.4 v0.1.8).** Nightly rebuild
   of `stats_leaderboard_all` AND `stats_leaderboard_30d` MUST
   execute in a single PostgreSQL transaction using
   DELETE+INSERT. Shapes A (TRUNCATE) and B (ALTER RENAME)
   require privileges the locked §7.2.2 grants do NOT include —
   their use is CRITICAL.
6. **`meta.rewards_populated` MUST be pre-computed by the
   rollup** (§9.1a + §5.2). The request-path role does NOT have
   SELECT on `provider_rewards_ledger`; if the diff computes
   rewards_populated synchronously from `provider_rewards_ledger`
   on the request path, that is CRITICAL.
7. **Late-event retention DELETE runs AFTER the §9.4 rebuild
   transaction commits, NOT in the same transaction** (BUILD §2
   Step 2 v0.1.7 §9.3). Same-tx is HIGH.
8. **`stats_late_events_retention_days` floor 30** per SPEC
   §9.3. Below-floor config MUST fail-closed at startup OR
   clamp+warn per BUILD §2 Step 2 (pick one and pin in tests).
   Silently accepting below-floor is HIGH.
9. **provider_visibility left-join semantics** per BUILD §2
   Step 2 ARCH r7 H2: rollup MUST left-join `provider_visibility`
   when producing `stats_leaderboard_*` rows; absence defaults to
   `mode='bucketed' AND blocked_from_partner_projection=FALSE`.
   Not doing the left-join in the rollup (deferring to the
   handler) is HIGH.
10. **Bucket computation in the rollup** per BUILD §2 Step 2
    ARCH r7 H2: rollup MUST compute `earnings_bucket` from the
    stored `NUMERIC(18,2)` total per §6.2 boundary semantics.
    Computing in the handler is HIGH.

## Required reading

1. `specs/BUILD_SPEC_017_IMPL_PROMPT.md` §2 Step 2, §2.4 AC
   matrix, §5 critical constraints, §6 deferrals.
2. `specs/SPEC-017-network-stats-api.md` v0.1.8 §6.2 (bucket
   thresholds + semantics), §6.6.2 (partner-key broader
   exposure), §9.1 (table DDLs), §9.1a (rewards source +
   rewards_populated), §9.2 (cadences), §9.3 (late events +
   retention), §9.4 (rebuild atomicity Shape C + drift), §9.5
   (freshness SLA), §9.6 (failure modes), §9.7 (backfill).
3. The Step 2 diff (any commit on `impl/spec-017-step-1` since
   the Step 1 convergence at `d1df592` or later — `b499327` is
   the post-Step-1 CI-fix tip).
4. `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md` — the
   provider-identity decision Step 2 MUST honor.
5. `phase4-coordinator/internal/stats/migrations/004_grants.up.sql`
   — what `stats_rollup` is actually allowed to do.

## Architecture audit categories

### A. Rollup scope vs Step 2 / Step 3 boundary
A.1  Does the rollup produce EXACTLY the columns Step 3 will
     consume? `earnings_bucket` computed in rollup (not
     handler) per ARCH r7 H2.
A.2  Does the rollup AVOID writing handler-only state (no
     `rate_limit_*`, no `last_used_at`, no partner-key state)?
A.3  Does the rollup leave Step 4 surfaces alone (no nginx
     config, no partner-key CLI subcommand bleed)?

### B. Per-table jobs vs §9.2 cadences
B.1  All 7 components present? Each at its locked cadence?
     `overview` 30s, `timeseries_rpm` + `timeseries_tpm` each
     30s rolling, `leaderboard_24h` 60s, `_7d` 5min, `_30d`
     30min, `_all` 6h.
B.2  Each job updates its OWN stats_components_health row on
     success AND failure. rpm-only failure preserves tpm's
     `last_ok_at`.
B.3  Each job is independently restartable per §9.6 (panic in
     one job does not take down the others).

### C. Shape C rebuild + drift + retention
C.1  Nightly rebuild for `stats_leaderboard_all` AND
     `stats_leaderboard_30d` uses Shape C (DELETE+INSERT in one
     tx). Not Shape A (TRUNCATE) or Shape B (ALTER RENAME).
     Either alternate shape is CRITICAL.
C.2  Drift detection runs DURING the nightly rebuild,
     comparing incremental snapshot against full-recompute
     value per axis (`earnings`, `tokens`, `jobs`). >0.5%
     divergence emits `stats_rollup_drift_detected` structured
     log event (with axis + delta + provider_id sample).
C.3  Late-event retention DELETE runs AFTER the rebuild tx
     commits (same job, separate idempotent step). Same-tx
     would couple a retention bug to the rebuild atomicity.

### D. Backfill posture + provider-identity trust
D.1  Both backfill modes implementable (Path A partial; Path B
     full). Operator selects via
     `cfg.Stats.Rollup.BackfillMode`.
D.2  When BackfillMode = "partial", `partial_history_since` is
     consumed as the rollup-start boundary; Step 3 emits the
     wire field.
D.3  Rollup queries source `provider_id` via JOIN on
     `provider_tokens` (the authenticated source per the Step
     1 decision record). No fallback to
     `provider_session` / `provider_handshake` or any raw
     hello-frame surface.

### E. rewards_populated computation
E.1  Rollup computes rewards_populated per window:
     EXISTS (SELECT 1 FROM provider_rewards_ledger
     WHERE unix_ts >= <window_start> AND unix_ts < <window_end>).
E.2  Result persisted to `stats_rewards_populated`
     (window_label PK). The handler MUST NOT compute this
     on the request path.

### F. Bucket computation + left-join
F.1  Bucket boundaries match §6.2 table EXACTLY:
     24h `< $0.01 → "-"`, `[0.01, 5) → "$"`, `[5, 50) → "$$"`,
     `≥ 50 → "$$$"`; 7d / 30d / all per the table.
F.2  Bucket comparison uses the stored NUMERIC(18,2) value,
     NOT a string serialization.
F.3  Bucket boundary semantics: `[a, b)` lower inclusive,
     upper exclusive. `$5.00 → "$$"`, `$4.99 → "$"`, `$50.00
     → "$$$"`, `$49.99 → "$$"`.
F.4  Rollup left-joins `provider_visibility`; absent row
     defaults to `mode='bucketed' AND blocked=FALSE`. Both
     defaults baked in.

### G. Package layout + import-graph lint (Step 1 invariants)
G.1  Rollup files under `internal/stats/rollup/` only.
     `internal/stats` and `internal/stats/store` MUST NOT
     reach for rollup-only logic.
G.2  Rollup imports stay within the depguard allowlist: MAY
     touch billing/session/pool READ-ONLY paths; MUST NOT
     import `internal/explorer`, `internal/ws`,
     `internal/auth`, `internal/stats`, `internal/stats/store`.
G.3  No `os.Exit` / `log.Fatal` anywhere in rollup code (the
     forbidigo rule covers this).

### H. Failure modes + main.go integration
H.1  `cmd/coordinator/main.go` starts the rollup goroutines
     only when `stats.enabled=true`, ties them to the
     existing `shutdownCtx`, and drains on shutdown.
H.2  Per-job panic does NOT crash the coordinator. Each job's
     goroutine has its own recover middleware that updates the
     job's `stats_components_health` row and continues.
H.3  Rollup uses ONLY `statsPools.Rollup` for writes; never
     touches `statsPools.Reader` (request-path) or
     `statsPools.ProviderPortal`.

## Output format

Per-category one-line verdict + per-finding entries (severity,
file:line, evidence snippet, why, minimal fix). Final verdict
block.

`READY TO LOCK` iff 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
