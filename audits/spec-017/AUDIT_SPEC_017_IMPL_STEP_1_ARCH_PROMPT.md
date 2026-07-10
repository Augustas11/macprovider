# AUDIT_SPEC_017_IMPL_STEP_1 — Architecture lane

Operator-paste prompt to audit the **Step 1 IMPL code** (schema +
DB roles + grant inventory + DSN wiring + lint config + Step 1
tests) under PR `impl/spec-017-step-1`, from the architecture lens.

Audit target is the **Step 1 implementation diff**, NOT the SPEC and
NOT the BUILD prompt. SPEC-017 v0.1.8 is LOCKED;
`specs/BUILD_SPEC_017_IMPL_PROMPT.md` is the controlling kickoff and
has already converged at 0/0/0 across its own three lanes. Your job
is to find problems in HOW the Step 1 code encodes the contract.

Severity model: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock
target: 0 CRITICAL + 0 HIGH + 0 MEDIUM. LOW + INFO MAY be deferred
and acknowledged in the convergence file.

Each round writes a fresh file
`specs/SPEC-017-IMPL-STEP_1-arch-rM-audit.md` — new file per round,
NEVER append.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 1 IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` of github.com/Augustas11/macprovider, from
the ARCHITECTURE lens.

Output: specs/SPEC-017-IMPL-STEP_1-arch-rM-audit.md (round M; fresh
file per round, never append).

Severity model:
- CRITICAL — Step 1 code would brick Step 2/3/4 (e.g. schema shape
  the rollup cannot execute under, role grant set inconsistent with
  the locked §7.2 inventory, package layout that violates the
  import-graph the SPEC pins) OR violates a locked SPEC invariant
  in a way that cannot be fixed without re-opening the SPEC.
- HIGH — would force a v0.2 fix-round within the first month,
  structurally misaligns Step 1 with Steps 2/3/4 (e.g. config
  surface for `partial_history_since` placed on a DB table instead
  of coordinator config per v11 ARCH r10 C1), or omits a structural
  seam the BUILD prompt pinned.
- MEDIUM — two conforming Step 1 sessions could resolve a Step 1
  decision differently; or missing structural guidance bleeds into
  Step 2's audit.
- LOW — polish / quality / non-blocking.
- INFO — observations.

## Critical constraints to honor while auditing

1. SPEC-017 v0.1.8 is LOCKED. Findings that would require a SPEC
   change are HIGH or CRITICAL; do NOT propose SPEC changes as
   fixes, propose Step 1 code rewrites.
2. The Step 1 scope is fixed by BUILD §2 Step 1: schema migrations
   + Postgres roles + grant inventory + per-role *sql.DB wiring +
   depguard lint + Step 1 tests. Out-of-scope items in the diff
   (HTTP handlers, rollup queries, CLI subcommands, nginx config,
   observability events) are CRITICAL scope creep.
3. The four locked design picks (separate rollup pipeline, public
   overview + optional partner keys on leaderboard, bucketed-
   default + opt-in exact, embed in coordinator binary) MUST NOT
   be flipped by anything in Step 1. Any migration or role grant
   that would silently flip one is CRITICAL.
4. Package layout pin: `internal/stats/` (flat) for handlers,
   `internal/stats/store/` for the read-side DAO,
   `internal/stats/rollup/` for the rollup job. Any deviation is
   HIGH unless the diff names the deviation and the BUILD prompt
   allows it.
5. Per-role *sql.DB pools: one DSN per active runtime role, one
   *sql.DB per pool, no shared pools. `partner_keys_writer_dsn` is
   CONDITIONAL on `stats.partner_keys.last_used_at_updates_enabled
   = true` (default false) per BUILD §2 Step 1. Any deviation is
   HIGH.
6. `partial_history_since` MUST live in coordinator config, NOT a
   DB table (v11 ARCH r10 C1). Any new `stats_rollup_state` table
   or equivalent is CRITICAL.
7. The CLI operator DSN (Step 4.A) is SEPARATE from the four
   runtime roles — Step 1 MUST NOT bind partner-key CLI to any
   runtime role's pool. If Step 1's main.go opens a CLI pool, that
   is HIGH (Step 4.A scope creep).

## Required reading

1. `specs/BUILD_SPEC_017_IMPL_PROMPT.md` — controlling kickoff,
   especially §0 controlling-contract, §1 prereqs, §2.0 PR
   workflow, §2.1 audit-lane gate, §2 Step 1 section, §2.4 AC
   matrix, §5 critical constraints, §6 deferrals.
2. `specs/SPEC-017-network-stats-api.md` v0.1.8 — the locked
   contract. §5.4.1 (`partner_keys`), §6.1 (`provider_visibility`
   + blocked_from_partner_projection stub), §6.5
   (provider_visibility_audit), §7.2 (role grants exactly, per
   §7.2.1 / §7.2.2 / §7.2.3 / §7.2.4), §9.1 (table DDLs), §9.1a
   (rewards_populated semantics), §9.7 (backfill posture).
3. The Step 1 diff itself: `git diff origin/main...impl/spec-017-step-1`.
4. `specs/SPEC-017-IMPL-PROMPT-v0_1_8-convergence.md` — the 18
   absorbed findings explain why each MUST in the BUILD prompt
   exists.

## Architecture audit categories

### A. Schema correctness vs locked SPEC §9.1 / §6.1 / §6.5 / §5.4.1
A.1  Does every locked SPEC DDL appear verbatim in the migration?
     Specifically: `stats_overview_current`, `stats_timeseries_rpm_30m`,
     `stats_timeseries_tpm_30m`, four `stats_leaderboard_*`,
     `stats_components_health`, `stats_late_events`.
A.2  `stats_leaderboard_*` shared schema: column set MUST NOT
     include `earnings_work_bucket` or `earnings_rewards_bucket`
     (v0.1.7 removed them). Including them is CRITICAL.
A.3  `stats_components_health.component` 7-row enum:
     `overview`, `timeseries_rpm`, `timeseries_tpm`,
     `leaderboard_24h`, `leaderboard_7d`, `leaderboard_30d`,
     `leaderboard_all`. Any single `timeseries` row instead of
     split is CRITICAL.
A.4  `stats_components_health` MUST NOT have a `status` column
     (derived at request time per §5.3); columns are
     `component, generated_at, last_ok_at, last_error_at,
     last_error_message`. A `status` column is CRITICAL.
A.5  `provider_visibility` PK `provider_id`, DEFAULT `'bucketed'`,
     PLUS `blocked_from_partner_projection BOOLEAN NOT NULL DEFAULT
     FALSE` column stub (v0.1.7 §6.1). Missing stub column is
     CRITICAL; v0.1 rollup MUST NOT consume it.
A.6  `provider_visibility_audit` BIGSERIAL `id` (so the locked
     `provider_portal` USAGE,SELECT-on-sequence grant has a real
     sequence to point at).
A.7  `partner_keys` (§5.4.1) — `BIGSERIAL id`, `token_hash`,
     `prefix`, `label`, `allowed_origins`, `rate_limit_rpm`,
     `created_by TEXT NOT NULL`, `rotated_from_id`,
     `created_at`, `revoked_at`, `revoked_reason`, `last_used_at`.
     v0.1.8 REMOVED `rate_limit_burst`. Presence of
     `rate_limit_burst` is CRITICAL.
A.8  `provider_rewards_ledger` skeleton (operator-populated; v0.1
     may be empty) + `rewards_populated` storage (lookup table OR
     denormalized column — pick one and pin). Missing
     `rewards_populated` storage is HIGH (Step 2 has nothing to
     write to).
A.9  Bootstrap-row seed: migration MUST pre-seed all SEVEN
     `stats_components_health` rows with sentinel timestamps so
     NOT NULL constraints survive first-tick failure. Missing
     bootstrap seed is HIGH.

### B. Postgres role inventory vs §7.2
B.1  `stats_reader` — SELECT on exactly the §7.2.1 enumeration:
     7 leaderboard/timeseries/overview tables +
     `stats_components_health` + `provider_visibility` +
     `partner_keys` + the chosen `rewards_populated` storage.
     Explicit deny on `stats_late_events`,
     `provider_rewards_ledger`, `provider_visibility_audit`, and
     all OLTP billing/session/pool tables. Any extra grant is
     CRITICAL.
B.2  `stats_rollup` — SELECT/INSERT/UPDATE/DELETE on the 7
     `stats_*` writer tables + `stats_late_events` +
     `rewards_populated` storage. SELECT on `provider_visibility`
     + `provider_rewards_ledger`. USAGE,SELECT on
     `stats_late_events_id_seq`. PLUS IMPL-authored SELECT on
     SPEC-002 + SPEC-005 OLTP source tables. Deny on
     `partner_keys`, `provider_visibility_audit`. Any deviation
     is CRITICAL.
B.3  `stats_rollup` MUST NOT have TRUNCATE / ALTER / DROP on any
     `stats_*` table. The §9.4 Shape C rebuild uses
     DELETE+INSERT in a single transaction; Shape A/B grants
     would widen the role inventory beyond the locked SPEC.
     Presence of TRUNCATE/ALTER/DROP grants is CRITICAL.
B.4  `provider_portal` — INSERT,UPDATE on `provider_visibility`;
     INSERT on `provider_visibility_audit`; USAGE,SELECT on
     `provider_visibility_audit_id_seq`. Deny on all `stats_*`
     tables and OLTP. Any deviation is CRITICAL.
B.5  `partner_keys_writer` — SKIPPED by default for v0.1 per
     BUILD §2 Step 1 resolution. If the migration creates the
     role unconditionally (without the
     `last_used_at_updates_enabled` flag), that is HIGH.
B.6  Re-verify SPEC-002 + SPEC-005 OLTP source-table names at
     IMPL time against the live SPECs (line 3 versions). If the
     diff hard-codes table names that have drifted from
     SPEC-005 v0.3 / SPEC-002 v1.4, that is HIGH.

### C. DB-connection mechanics vs BUILD §2 Step 1
C.1  One DSN per active runtime role, one *sql.DB per pool, no
     shared pools. Sharing pools across roles is CRITICAL.
C.2  `partner_keys_writer_dsn` only required when
     `stats.partner_keys.last_used_at_updates_enabled = true`.
     Required by default is HIGH.
C.3  Startup fail-closed: if `stats.enabled = true` and any
     required runtime DSN is missing OR any required role smoke
     fails, the process MUST refuse to start. Permissive
     fallback is CRITICAL.
C.4  `stats.enabled = false` (default until cutover) — the
     `/v1/stats/*` mux subtree MUST NOT register. A registered
     subtree returning a custom `stats_disabled` JSON envelope
     violates §5.9 closed code vocabulary and is CRITICAL.
C.5  CLI operator DSN (`coordinator.partner_keys_admin_dsn`) is
     SEPARATE from runtime roles. If Step 1's main.go opens a
     pool for it, that is HIGH (Step 4.A scope creep). Step 1
     MAY add the config field for it; it MUST NOT instantiate.

### D. Package layout + import-graph lint vs §7.6 + AC-16
D.1  Package layout: `phase4-coordinator/internal/stats/` (flat;
     handlers — Step 3 fills),
     `phase4-coordinator/internal/stats/store/` (read DAO —
     Step 3 fills), `phase4-coordinator/internal/stats/rollup/`
     (rollup job — Step 2 fills),
     `phase4-coordinator/internal/stats/migrations/` (Step 1
     SQL). Any deviation is HIGH.
D.2  depguard rules (AC-16): request-path packages
     (`internal/stats`, `internal/stats/store`) MUST NOT import
     `internal/billing`, `internal/explorer`, `internal/ws`,
     `internal/auth` (except a named Bearer-parser allowlist
     symbol). Rollup MAY import billing/session/pool read-only;
     MUST NOT import `internal/explorer`. Both directions
     enforced is the bar.
D.3  depguard rules MUST forbid `os.Exit` / `log.Fatal` /
     `log.Fatalf` anywhere under `internal/stats/*` (preserves
     §7.3 recover-middleware guarantee). Missing is HIGH.
D.4  The AC-16 lint fixture MUST be a COMPILABLE import of a
     forbidden path (e.g. `internal/billing`) under
     `internal/stats`, asserted-by-name (e.g. `depguard:
     forbidden import`), not a non-zero exit code. A
     non-compilable fixture path is CRITICAL — the failure
     would be a compiler error, not the lint diagnostic.

### E. Test coverage vs §2.4 AC matrix Step 1 share
E.1  AC-9 — `stats_reader` permission-denied on
     `SELECT 1 FROM ledger_request_credits LIMIT 1` (NOT
     "relation does not exist"). Test against at least one of
     `ledger_request_credits`, `ledger_operator_credits`,
     `ledger_payout_ready`, `ledger_reconciliation_runs`. Other
     wording is HIGH.
E.2  AC-10 — both subcases (commit path with `p1`, rollback
     path with `p_rollback`); assert
     `blocked_from_partner_projection = FALSE` after toggle.
     Missing either subcase is HIGH.
E.3  AC-16 — depguard fixture asserted-by-name.
E.4  AC-19 — SQL fixture proves left-join no-row default tuple
     `mode = 'bucketed' AND blocked_from_partner_projection =
     FALSE`. Step 3 owns the handler assertion; Step 1 owns the
     fixture. Missing fixture is HIGH.
E.5  AC-20 — CI SQL assertion that
     `SELECT COUNT(*) FROM provider_visibility_audit WHERE
     new_mode = 'exact' AND actor_kind = 'operator'` returns 0.
     Per BUILD §2.4 this MUST run on every PR. Wrapping the
     assertion in an integration-only suite that doesn't run on
     PR is HIGH.

### F. Cross-step seams to Step 2/3/4
F.1  Does Step 1 add the config struct fields Steps 2/3 need
     (`stats.enabled`, `stats.rollup.backfill_mode`,
     `stats.rollup.partial_history_since`,
     `stats.rollup.late_events_retention_days`,
     `stats.partner_keys.last_used_at_updates_enabled`,
     `stats.cors.access_control_max_age_seconds`,
     `stats.trusted_proxies`, etc.) so Steps 2/3 don't have to
     touch config a second time?
F.2  Does Step 1 leak handler / rollup code? Any concrete HTTP
     handler, rollup tick query, or partner-key CLI command
     committed in Step 1 is CRITICAL scope creep.
F.3  Does Step 1 introduce any unreviewed external dependency
     beyond the Postgres driver + testcontainers-go +
     golangci-lint? E.g. an unexpected ORM, query builder, or
     observability lib. If yes, HIGH unless surfaced in the PR
     description.

## Output format

For each category above (A-F), emit:

- A category heading + a one-line verdict (e.g. `A. Schema correctness — 0 CRITICAL / 1 HIGH / 0 MEDIUM`).
- A finding subsection for each issue, formatted:

  - `**[SEVERITY] {short title}**`
  - `**Where:** <file:line>` or `<table/role name>` or
    `<package path>`.
  - `**Evidence:** <the smallest verbatim diff snippet that
    proves the finding>`.
  - `**Why it matters:** <one or two sentences linking to the
    locked SPEC § or BUILD-prompt §>`.
  - `**Fix:** <minimal code-rewrite suggestion in the Step 1
    diff; NOT a SPEC change>`.

- At the end of the file, a verdict block:
  ```
  Verdict: <READY TO LOCK | NEEDS FIX>
  CRITICAL: <n>
  HIGH: <n>
  MEDIUM: <n>
  LOW: <n>
  INFO: <n>
  ```

`READY TO LOCK` means 0 CRITICAL + 0 HIGH + 0 MEDIUM. Anything
else is `NEEDS FIX`.

=== END PROMPT ===
```
