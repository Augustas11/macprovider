# BUILD_SPEC_017_IMPL — Network Stats API implementation (write prompt)

**You are starting a fresh session in the macprovider-poc repo (`https://github.com/Augustas11/macprovider`). You have no memory of prior conversations. Read this prompt end-to-end before writing any code.**

**Before editing anything, verify your workspace:**

```bash
pwd                                    # confirm you are in a macprovider checkout
git status -sb                         # confirm clean and on the right branch
ls specs/SPEC-017-network-stats-api.md # confirm SPEC has merged to your branch
```

If `specs/SPEC-017-network-stats-api.md` is not present at HEAD on your branch, the SPEC-017 v0.1 LOCK PR has not merged yet — STOP and check the PR status before proceeding.

Your job is to implement [`specs/SPEC-017-network-stats-api.md`](SPEC-017-network-stats-api.md) — the public Network Stats HTTP API for `/v1/stats/{overview,leaderboard,health}` served from the existing coordinator binary, plus the rollup pipeline that feeds it, plus the four DB roles that isolate it. The SPEC is the **single controlling contract** for this work; every section of this prompt cites SPEC-017 §-numbers and you MUST verify those §-references against the merged SPEC at HEAD before encoding them.

## 0. Controlling contract

- **SPEC:** [`specs/SPEC-017-network-stats-api.md`](SPEC-017-network-stats-api.md) at **v0.1.7** (LOCKED on commit `4a26826` on the v0.1 LOCK branch; codex round-8 declared READY TO LOCK at 0/0/0 on the Claude critic+designer fix pass on top of the prior v0.1.6 LOCK). Re-read every "MUST / MUST NOT / SHOULD" in the SPEC before you write the corresponding IMPL code. Every section heading referenced below (`§5.1`, `§7.2.2`, `§9.1`, etc.) points at the merged SPEC.
- **v0.1.7 deltas vs v0.1.6 (binding for this prompt):** the Claude fix pass that produced v0.1.7 changed the contract in ways the IMPL author MUST honor:
  - §5.2 public projection NO LONGER exposes `totals.earnings_usd`, `totals.earnings_work_usd`, or `totals.earnings_rewards_usd`. The public `totals` object carries only `tokens`, `jobs`, `active_accounts`.
  - §5.2 public projection ships ONE bucket axis (`earnings_bucket`) and ONE exact field (`exact_earnings`). The earlier per-axis buckets (`earnings_work_bucket`, `earnings_rewards_bucket`) and per-axis exact fields (`exact_earnings_work`, `exact_earnings_rewards`) are REMOVED. Partner-key projection still has per-axis exact-$ (`earnings_work_usd`, `earnings_rewards_usd`).
  - §5.2 adds top-level `partial_history_since` (RFC 3339, present per §9.7 rules) and `meta.rewards_populated` (REQUIRED boolean).
  - §5.2 public projection `Vary` header DROPS `Authorization` (only the partner-key projection varies on it).
  - §5.2 partner-key projection MUST NEVER emit `Access-Control-Allow-Origin: *`. §5.7 row 3 is split into "browser context (Origin present)" and "server-to-server (Origin absent)".
  - §5.3 `/v1/stats/health` components map now has 7 keys: `overview`, `timeseries_rpm`, `timeseries_tpm`, `leaderboard_24h`, `leaderboard_7d`, `leaderboard_30d`, `leaderboard_all`. The single `timeseries` key is removed.
  - §5.4.3 mandates that the Origin-rejection 401 path MUST perform the same `sha256 + SELECT by token_hash` work as the no-row 401 path before short-circuiting. AC-18 is now a three-way ±20% timing test (no-row, revoked, rejected-origin).
  - §5.4.3 + §5.7 require RFC 6454 ASCII serialization on every Origin comparison (lowercase scheme + host; default ports `:80`/`:443` stripped; trailing slash/path/query rejected as "absent Origin").
  - §5.7 `Access-Control-Max-Age` is `60` (was `3600`). Operator MAY raise via runtime config to ≤300; >300 requires a SPEC bump.
  - §6.1 `provider_visibility` adds `blocked_from_partner_projection BOOLEAN NOT NULL DEFAULT FALSE` (v0.1 column stub — schema present, rollup does NOT consume it).
  - §6.2 strips per-axis buckets; bucket boundary semantics are pinned (`[a, b)` brackets, comparisons against `NUMERIC(18,2)` exact value).
  - §6.6.2 adds a launch-sequencing precondition: PRODUCTION partner-key issuance under §5.4.2 MUST NOT begin until SPEC-014 v0.9 disclosure UI ships AND the operator runbook records a sign-off. Step 4.C OWNS the gate (delivers the runbook checkbox, disclosure copy, and sign-off template); Step 4.A implements the CLI itself and is NOT blocked — staging key issuance for AC fixtures, partner-side integration dry-runs, and CI work proceeds normally. The gate is an operator-side cutover act on production issuance, not a code-write or PR-merge gate.
  - §9.1 stats_leaderboard_* schemas remove `earnings_work_bucket` and `earnings_rewards_bucket` columns. `stats_components_health.component` enum now has 7 values (timeseries split).
  - §9.1a adds normative `meta.rewards_populated` semantics; the rollup pre-computes per window (denormalized column or small lookup table — IMPL-author choice).
  - §9.2 pins overview `_total` fields as cumulative all-time counters.
  - §9.3 pins `stats_late_events` 90-day retention (operator-configurable, ≥30 days).
  - §9.4 pins nightly rebuild MUST execute in a single PostgreSQL transaction (Shape A temp-table swap OR Shape B atomic table rename).
  - §11 Q9 is now CLOSED (per-axis buckets stripped). Q11 is PARTIAL (column stub landed; rollup semantic still v0.2).
- **Per-round SPEC audit detail:** [`specs/SPEC-017-r1-audit.md`](SPEC-017-r1-audit.md) through [`specs/SPEC-017-r8-audit.md`](SPEC-017-r8-audit.md). Skim these for the *why* behind individual SPEC requirements — many normative paragraphs close a specific audit finding (e.g. round-2 C1 the partner-key 47-char format, round-2 C2 the deferred rewards-source semantics, round-4 M2 the implementation-authored OLTP source grants, round-6 M1 the BIGSERIAL backing-sequence grants, round-8 Claude H1–H5 + M1–M7 + designer D-H1/H2/M1).
- **Per-round IMPL-prompt audit detail:** [`specs/SPEC-017-IMPL-PROMPT-arch-rN-audit.md`](SPEC-017-IMPL-PROMPT-arch-r1-audit.md) / `-code-` / `-security-` for each round. This version of the prompt absorbed round-1..6 findings across all three lanes (the round-5/6 SPEC-v0.1.6 convergence) plus the v0.1.7 re-anchor pass (new rounds opened from this commit forward).
- **Locked design rationale:** [`specs/SPEC-017-advisor-round-2026-06-25.md`](SPEC-017-advisor-round-2026-06-25.md) records the four LOCKED Q1-Q4 picks (separate rollup pipeline, public overview + optional partner keys on leaderboard, bucketed-default earnings + provider opt-in, embed in coordinator binary). **DO NOT re-litigate any of those picks in this IMPL.**
- **Decision rationale:** [`beta/DECISION_CRITERIA.md`](../beta/DECISION_CRITERIA.md) Entry 90 records why one-contract-three-consumers, why bucketed default, why partner keys on leaderboard only, and why embed-not-split.

**The IMPL author's job is to encode the SPEC, not to re-question it.** If you find yourself disagreeing with a normative requirement, STOP and surface the disagreement to the operator — do NOT silently deviate. If you find an ambiguity, file a SPEC v0.2 candidate; do NOT resolve it in code.

## 1. Pre-flight checklist — operator-action prerequisites

SPEC-017 has no operator-prerequisite section analogous to SPEC-016's hot-wallet gate. The locked SPEC already pins behavior for both hostname patterns (§7.1: both `coordinator.streamvc.live/v1/stats/*` and `stats.streamvc.live` work) and both backfill postures (§9.7 Path A default + Path B opt-in). The IMPL author MUST implement BOTH paths and BOTH backfill modes; operator selection applies at cutover/config, not at code-write time.

That said, four items need confirmation BEFORE kickoff (two implementation-shape items + two security-gate items), and four items are HARD prereqs before production cutover (deploy gates, not code gates).

**Pre-kickoff confirmation items (not code gates):**

1. **Hostname pattern (§7.1, §11 Q6).** Locked SPEC pins (c) both. Operator confirms the v0.1 cutover surfaces both hostnames; if operator wants only (a) or (b), file a SPEC v0.1.8 candidate FIRST and re-audit — do NOT silently deviate in code.
2. **Backfill posture (§9.7, §11 Q7).** Both Path A (partial-history forward + `partial_history_since` field) and Path B (full OLTP backfill before nginx flips on) are implementable in code. Operator picks at cutover via a config flag the IMPL author MUST expose; default = Path A per [[macprovider-vercel-demo]] thin-ship pattern. The Step 2 rollup code MUST support both modes; the cutover runbook (Step 4) records which mode is selected for production.

**Pre-kickoff security-gate items:**

3. **Pin SPEC-016 dependency version at IMPL time.** SPEC-017 v0.1.7 cites SPEC-016 v0.1.19. If SPEC-016 has moved beyond v0.1.19 by IMPL time, the IMPL author MUST re-check that the §9.1a rewards-source deferral is still honest against the newer SPEC-016. If SPEC-016 v0.2+ defines a work/rewards split, surface it; do NOT silently rewire `earnings_rewards_usd` to the new source — that would close §11 Q13 in code instead of in SPEC, which violates the audit-loop convention.
4. **Provider-identity trust source (security gate).** Per [[provider-auth-unauthenticated-end-to-end]] (XSEC-1), live beta operation has historically run with `require_provider_tokens=false` and attacker-controlled hello frames could impersonate pinned providers. SPEC-017 MUST NOT amplify unauthenticated provider identity into a public leaderboard. Before Step 2 rollup code, verify the OLTP `provider_id` column the rollup reads from is sourced from authenticated `provider_token` plumbing (per SPEC-002 v1.4 §7), NOT from raw hello-frame payloads. If production still has unauthenticated provider IDs, the IMPL author MUST gate the rollup to filter for authenticated rows OR block public cutover until the auth gap is closed. Surface this to the operator before writing Step 2 code.

**Production-cutover deploy gates (operator side, MUST be discharged before nginx flip — but DO NOT block IMPL code-write or staging deploys):**

5. **Postgres roles + DSN provisioning (HARD before any Pearl deploy of stats code).** Operator creates the Postgres roles and their passwords on the Pearl Postgres instance, applies the §9.1 / §6.1 / §6.5 / §5.4.1 migrations, and installs the four DSNs (`stats_reader_dsn`, `stats_rollup_dsn`, `provider_portal_dsn`, optionally `partner_keys_writer_dsn`) in the coordinator config/secrets store. Step 1's startup smoke verifies the DSNs and roles via a staging deploy BEFORE any Pearl rollout. The coordinator binary MUST be fail-closed: on startup, if `stats.enabled = true` and any required DSN is missing or any required role fails connection smoke, the process MUST refuse to start. If `stats.enabled = false` (default until cutover), the `/v1/stats/*` mux subtree is NOT registered with the HTTP router — requests to `/v1/stats/*` return a standard `404 Not Found` from the coordinator's existing mux fallback (NOT a custom JSON envelope with `code: "stats_disabled"`, which would violate the §5.9 closed code vocabulary). The rest of the coordinator runs normally.
6. **DNS for `stats.streamvc.live`.** Operator points the new vhost at the same Pearl VPS IP as `coordinator.streamvc.live`. SOFT prereq — IMPL builds and unit-tests without DNS in place; integration smoke needs it.
7. **Cloudflare configuration.** If Cloudflare fronts the new vhost (recommended per §5.6 / §7.4), operator configures rate-limit zones and bot-management rules before public cutover. SOFT prereq.
8. **Nginx server-block on Pearl.** Operator deploys the new server-block (§7.4 + Step 4 directives below) and verifies TLS, cache directives, header strip on `Authorization`, dedicated `limit_req_zone`, fail-closed burst (§5.6 enforced via `nodelay`). SOFT prereq for IMPL but a HARD prereq for production cutover.

**Out of scope (NOT prereqs) — SPEC-014 v0.9 has THREE distinct surfaces; treat each separately:**

The v6 prompt conflated "SPEC-014 v0.9" into a single blob; per ARCH r6 H2 the three surfaces have different gate semantics:

1. **SPEC-014 v0.9 visibility-toggle UI** (the portal page that calls `INSERT ... ON CONFLICT (provider_id) DO UPDATE` against `provider_visibility`). NOT a SPEC-017 code-write prereq, NOT a public-cutover prereq, NOT a Step 4.C convergence prereq. SPEC-017 v0.1 IMPL ships the storage (`provider_visibility`), the API behavior (left-join with bucketed default), and the CI fixture coverage for AC-10 / AC-19 / AC-20. If this surface has not landed at SPEC-017 cutover, defaults take effect (all providers `bucketed`) and no production blocker exists.
2. **SPEC-014 v0.9 §6.6.2 disclosure UI** (the portal copy informing providers that partner keys see exact $). NOT a Step 4.C **PR** convergence prereq — the Step 4.C PR may merge with the runbook checkbox in `OPS.md` and the cutover-runbook template in place but the live portal sign-off still pending. IS a HARD gate before the **first production partner-key issuance** (the operator-side cutover act, NOT a PR merge act). Staging keys for AC fixture work + partner integration dry-runs are exempt.
3. **§11 Q12 canonical UI consumer.** SPEC-017 v0.1 is API-only; the UI consumer lands in a follow-up SPEC. Console and portal rendering MAY proceed in parallel by separate teams; SPEC-017 cutover does not gate on UI consumer existing.

Two conforming IMPL authors disagreeing on whether the Step 4.C PR can merge before SPEC-014 v0.9 ships was the ambiguity ARCH r6 H2 caught. The split above resolves it: the **PR** merges with the runbook template; the **first production partner-key issuance** is the act that requires the live portal disclosure + operator sign-off.

## 2. Stepped-IMPL decomposition — 4 steps + 4 audit loops

This SPEC is structurally simpler than SPEC-016 (no chain interactions, no money path beyond display, no dual-loader machinery) but partner-facing wire surface + role isolation + rollup correctness still warrants stepped IMPL with per-step audit. Single-step IMPL was considered and REJECTED.

### 2.0 Mandatory PR workflow (load-bearing)

Per [[pr-rebase-silent-dependency-regression]] and [[macprovider-required-review-merge-pattern]]:

- **One PR per step (mandatory, not recommended).** Two steps MUST NOT land in the same PR. Combining loses the per-step audit-lens benefit.
- **Branch naming:** `impl/spec-017-step-N` where N ∈ {1, 2, 3, 4}.
- **Branch creation:** for step N>1, create from the squash-merged tip of step N-1:
  ```bash
  git checkout main
  git fetch origin
  git reset --hard origin/main          # mirror origin, discard any local divergence per [[pr-merge-workflow-rule]]
  git checkout -b impl/spec-017-step-N
  ```
- **Before push / open PR:** `git fetch origin && git rebase origin/main` — squash-merge of step N-1 means main has advanced.
- **Step N+1 MUST NOT open** until step N has squash-merged AND local main has been reset to origin/main.
- **No force push to main.** Per per-repo memory.

### 2.1 Per-step audit-lane gate

Each step gets three codex audit lanes: **ARCH**, **CODE**, **SECURITY**. Audit prompts live at:

- `specs/AUDIT_SPEC_017_IMPL_STEP_N_ARCH_PROMPT.md`
- `specs/AUDIT_SPEC_017_IMPL_STEP_N_CODE_PROMPT.md`
- `specs/AUDIT_SPEC_017_IMPL_STEP_N_SECURITY_PROMPT.md`

Per-lane per-round audit files: `specs/SPEC-017-IMPL-STEP_N-{arch,code,security}-rM-audit.md`.

**Convergence target:** `0 CRITICAL + 0 HIGH + 0 MEDIUM` per lane. LOW + INFO findings MAY be deferred and acknowledged in a `specs/SPEC-017-IMPL-STEP_N-rM-convergence.md` summary file before the step's PR opens.

**Audit cost expectation:** 4 PRs × 3 lanes × ~1-3 rounds per lane = ~12-36 codex audits across the IMPL. SPEC-016 IMPL averaged ~3 rounds per step lane; SPEC-017 is structurally simpler so expect closer to ~1-2 rounds per lane. Plan accordingly; do NOT schedule public cutover until ALL convergence files exist.

Audits MUST use codex via `omc ask codex` per [[feedback-codex-only-audits]] (NOT Claude internal subagents).

### Step 1 — Schema + DB roles + grant inventory

**Package layout (pin this, do not deviate):**

- `phase4-coordinator/internal/stats/` — HTTP handler package. Stats request-path code lives here. Mirrors the existing flat `internal/explorer/` pattern but with subpackages for non-handler concerns.
- `phase4-coordinator/internal/stats/store/` — DAO over the `stats_*` request-path-readable inventory. Uses the `stats_reader` `*sql.DB`.
- `phase4-coordinator/internal/stats/rollup/` — rollup job subpackage. Step 2 lands here. Uses the `stats_rollup` `*sql.DB`.

**Import-graph rules (CI-enforced lint per AC-16 + step-1 deny + step-2 carve-out):**

Two distinct boundaries the lint MUST distinguish:

- **Request-path packages** (`internal/stats`, `internal/stats/store`) — MUST NOT import `internal/billing`, `internal/explorer`, `internal/ws`, or `internal/auth` (except a minimal Bearer parser whose exact symbol the IMPL author names in the lint allowlist; e.g. `BearerToken(string) (token string, ok bool)`).
- **Rollup package** (`internal/stats/rollup`) — MAY import EXACTLY billing/session/pool read-only paths (the SPEC §4.2 carve-out). MUST NOT import `internal/explorer` (an operator-only admin surface; SPEC AC-16 names it in the forbidden set), MUST NOT import `internal/ws`, MUST NOT import `internal/auth` beyond a minimal helper if needed (same allowlist as request-path packages). MUST NOT import `internal/stats` or `internal/stats/store` (one-way: rollup writes through the rollup role, never reads through the handler role). If the rollup needs data currently exposed only through explorer helpers, factor those helpers into a neutral read-only package OR query through the rollup DAO/SQL layer directly.

The lint (e.g. `depguard`) MUST be configured with both boundaries and MUST run in CI on every PR (AC-16). The lint MUST also forbid `os.Exit`, `log.Fatal`, `log.Fatalf`, and equivalent process-terminating calls anywhere under `internal/stats/*` to preserve the §7.3 recover-middleware guarantee.

**Schema migrations under `phase4-coordinator/internal/stats/migrations/`:**

- [§9.1] verbatim DDL for `stats_overview_current`, `stats_timeseries_rpm_30m`, `stats_timeseries_tpm_30m`, `stats_leaderboard_24h`, `stats_leaderboard_7d`, `stats_leaderboard_30d`, `stats_leaderboard_all` (shared schema per the SPEC's `-- IDENTICAL` comment; **v0.1.7** removed `earnings_work_bucket` and `earnings_rewards_bucket` columns — DO NOT add them back), `stats_components_health` (columns: `component`, `generated_at`, `last_ok_at`, `last_error_at`, `last_error_message` — NO `status` column; health JSON `status` field is DERIVED at request time per §5.3 from freshness thresholds, see Step 3; **v0.1.7** the `component` enum has 7 values: `overview`, `timeseries_rpm`, `timeseries_tpm`, `leaderboard_24h`, `leaderboard_7d`, `leaderboard_30d`, `leaderboard_all`), `stats_late_events`.
- [§9.1a] `provider_rewards_ledger` skeleton table (operator-populated; rollup-readable; v0.1 may be empty). The rollup additionally MUST persist a `meta.rewards_populated` boolean per window (Step 2; storage shape is implementation-authored — e.g. a `stats_rewards_populated (window TEXT PRIMARY KEY, populated BOOLEAN, generated_at TIMESTAMPTZ)` lookup table OR a column on `stats_components_health` — pick one and pin in the Step 1 migration so the Step 3 handler has somewhere to read from).
- [§6.1] `provider_visibility` (PK `provider_id`, DEFAULT `'bucketed'`, **plus the v0.1.7 `blocked_from_partner_projection BOOLEAN NOT NULL DEFAULT FALSE` column stub**). The v0.1 rollup does NOT consume `blocked_from_partner_projection` (§6.1 semantics + §11 Q11). The column MUST be created at schema-create time and the migration MUST include a test that the column exists with the correct default. The handler MUST NOT branch on it in v0.1.
- [§6.5] `provider_visibility_audit` (BIGSERIAL `id`).
- [§5.4.1] `partner_keys` (BIGSERIAL `id`, hashed `token_hash`, **`created_by TEXT NOT NULL`** explicitly — the CLI MUST populate this from the operator principal, see Step 4 CLI flags). All columns per §5.4.1 verbatim.

**Postgres role inventory per §7.2 (enumerate each — do NOT use `stats_*` shorthand, since shorthand sweeps in rollup-internal tables):**

- `stats_reader` (§7.2.1) — request-path role.
  - SELECT on EXACTLY: `stats_overview_current`, `stats_timeseries_rpm_30m`, `stats_timeseries_tpm_30m`, `stats_leaderboard_24h`, `stats_leaderboard_7d`, `stats_leaderboard_30d`, `stats_leaderboard_all`, `stats_components_health`, `provider_visibility`, `partner_keys`, **PLUS the v0.1.7 `rewards_populated` storage** (e.g. `stats_rewards_populated` if you used the lookup-table shape; if you denormalized into `stats_components_health`, no extra grant needed — the handler still reads via the existing `stats_components_health` grant).
  - Explicit deny: `stats_late_events` (rollup-internal per §9.1, §9.3), `provider_rewards_ledger` (rollup-internal per §9.1a), `provider_visibility_audit` (write-only at request time), and any OLTP billing/session/pool table.
- `stats_rollup` (§7.2.2) — rollup job role.
  - SELECT, INSERT, UPDATE, DELETE on EXACTLY: `stats_overview_current`, `stats_timeseries_rpm_30m`, `stats_timeseries_tpm_30m`, `stats_leaderboard_24h`, `stats_leaderboard_7d`, `stats_leaderboard_30d`, `stats_leaderboard_all`, `stats_components_health`, `stats_late_events` (9 tables total — enumerated per SPEC §7.2.2; do NOT use a `stats_*` shorthand), **PLUS write privileges (SELECT, INSERT, UPDATE, DELETE) on the v0.1.7 `rewards_populated` storage if you chose the lookup-table shape** — the rollup is the writer of this signal.
  - SELECT on `provider_visibility`, `provider_rewards_ledger`.
  - `USAGE, SELECT ON SEQUENCE stats_late_events_id_seq` (plus any sequence backing a `rewards_populated` lookup table if applicable).
  - PLUS IMPL-authored SELECT grants on the locked SPEC-002 + SPEC-005 OLTP source tables (the SPEC-005 v0.3 ledger tables defined in §4.3-§4.8 — typically `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs` — plus `provider_tokens` from SPEC-002 §7). SPEC-005 §10 covers crash recovery and reconciliation, not table definitions. Re-verify the dependency-line-3 versions at IMPL time per §1 prereq 3.
  - Explicit deny: `partner_keys`, `provider_visibility_audit`.
- `provider_portal` (§7.2.3) — portal toggle role.
  - INSERT, UPDATE on `provider_visibility`.
  - INSERT on `provider_visibility_audit`.
  - `USAGE, SELECT ON SEQUENCE provider_visibility_audit_id_seq`.
  - Explicit deny: any `stats_*`, any OLTP table.
- `partner_keys_writer` (§7.2.4) — **OPTIONAL and DEFAULT-OFF for v0.1 IMPL.**
  - SPEC §7.2.4 grants ONLY `UPDATE (last_used_at) ON partner_keys` — column-scoped, no SELECT on any column. In PostgreSQL, the worker's natural `UPDATE partner_keys SET last_used_at = $1 WHERE id = $2` pattern requires SELECT privilege on `id` to evaluate the WHERE clause, which the locked SPEC does NOT grant. This makes the role's natural worker SQL inexecutable under the locked grants.
  - **Resolution for v0.1 IMPL: skip the role entirely.** Do NOT create `partner_keys_writer`, do NOT start the worker, do NOT populate `last_used_at`. The `last_used_at` column stays NULL for v0.1 — the operator loses last-used visibility but the role isolation stays exactly as the SPEC locks it.
  - If a future operator wants `last_used_at` populated, the IMPL author MUST surface a SPEC v0.2 candidate (e.g. SECURITY DEFINER stored procedure + EXECUTE grant, or narrowed `SELECT(id) + UPDATE(last_used_at)` documented in the SPEC) — do NOT widen the grant in IMPL prompt or code without SPEC approval.

**DB connection mechanics (bridge to current coordinator pattern):**

Per current code at [`phase4-coordinator/cmd/coordinator/main.go`](../phase4-coordinator/cmd/coordinator/main.go), the coordinator currently opens SQLite stores from one `storage.db_path` shared across billing, explorer, admission, canary. SPEC-017 requires Postgres roles with separate `*sql.DB` instances per role (§7.2.5). The IMPL author MUST:

- Add Postgres DSN config block under `storage.postgres.*` (driver: `lib/pq` or `pgx`; pick one consistent with the rest of the project — verify against [`go.mod`](../phase4-coordinator/go.mod)).
- One DSN per **required** runtime role: `stats_reader_dsn`, `stats_rollup_dsn`, `provider_portal_dsn`. These three are always required when `stats.enabled = true`; startup MUST fail-closed if any is missing.
- **`partner_keys_writer_dsn` is CONDITIONAL on a separate enable flag (v0.1.7 — `partner_keys_writer` role is skipped by default per §7.2.4 resolution above):** the DSN, the role, the pool, and any background worker MUST only be configured/opened/smoked when `stats.partner_keys.last_used_at_updates_enabled = true` (default `false` for v0.1). When the flag is false, the startup MUST NOT require the DSN, MUST NOT open a pool, and MUST NOT smoke-connect — three conforming v0.1 deployments will have no `partner_keys_writer_dsn` set. AC-15 / AC-17 do NOT require this pool. A future SPEC v0.2 may flip this default after pinning an executable grant pattern.
- One `*sql.DB` per active role, instantiated in `cmd/coordinator/main.go` startup and passed to its owning package. NO shared pools.
- **CLI / migration / superuser DSN — separate from runtime roles (v0.1.7):** `coordinator partner-keys issue` / `revoke` / `list` subcommands (Step 4.A) MUST use a SEPARATE operator DSN (e.g. `coordinator.partner_keys_admin_dsn` in config, or read from env at CLI invocation time). The CLI MUST NOT use `stats_reader_dsn` (SELECT only, AC-17 INSERT fails), `stats_rollup_dsn` (explicit deny on `partner_keys`), `provider_portal_dsn` (no partner_keys grant), or `partner_keys_writer_dsn` (column-scoped UPDATE only). The operator DSN connects as the database superuser OR a dedicated migration role outside the four runtime roles, per SPEC §5.4.1. Document the DSN's grant requirements in `OPS.md`: at minimum, `INSERT, SELECT, UPDATE` on `partner_keys` plus `USAGE, SELECT ON SEQUENCE partner_keys_id_seq`. AC-17 test setup MUST configure this DSN explicitly; using a runtime role for AC-17 is a contract violation.
- A startup smoke that each ACTIVE pool can connect with its role and FAILS to query a deny-list table (verified by AC-9 in tests). The CLI operator DSN does NOT participate in startup smoke (it's invoked at CLI subcommand time, not at coordinator boot).

**Tests for Step 1:**

- Unit: every `CREATE TABLE` round-trips via the migration runner (e.g. `golang-migrate`) up and down without orphans.
- Integration (AC-9, mapped here from the AC matrix below): `stats_reader` returns permission-denied on `SELECT 1 FROM ledger_request_credits LIMIT 1` (NOT "relation does not exist"). Verify against at least one of `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs` (the locked SPEC-005 v0.3 tables, re-verified at IMPL time).
- Integration: if `partner_keys_writer` role exists in this deploy, run `UPDATE partner_keys SET last_used_at = $1 WHERE id = $2` and document the result. Per SPEC §7.2.4 the locked grant is column-scoped UPDATE only with no SELECT; the WHERE clause likely fails with permission-denied. This is the EXPECTED behavior — record it in the test output as "writer-disabled per locked SPEC, last_used_at remains NULL for v0.1." A passing v0.1 IMPL skips this role entirely; the test exists to PROVE the SPEC's grant-narrowing intent is preserved, not to make the worker run.
- Integration: `provider_portal` SELECT against any `stats_*` table returns permission-denied; INSERT to `provider_visibility_audit` succeeds with a row whose BIGSERIAL `id` was assigned (sequence grant works).
- Integration (AC-16 lint smoke): a deliberate test package adding `import "<module-path>/internal/billing"` under `internal/stats` (where `<module-path>` is the value in [`phase4-coordinator/go.mod`](../phase4-coordinator/go.mod) — verify before authoring the test; e.g. `github.com/augstar/macprovider-coordinator/internal/billing`) fails `make lint`. The test fixture MUST be a COMPILABLE import so the failure is from the depguard / import-graph lint diagnostic, NOT a compiler error from a bad import path. The lint output MUST be asserted by name (e.g. `depguard: forbidden import`), not just a non-zero exit code. Verify the rule applies to `<module-path>/internal/auth` too (other than the named Bearer-parser allowlist symbol).
- Integration: a deliberate test file under `internal/stats/` calling `os.Exit(1)` (NOT `os.Exit("test")` — `os.Exit` takes an int and the wrong signature would fail typechecking before the lint runs) fails `make lint` with the named "no-process-termination-in-stats" rule. Same assertion-by-name discipline.
- Integration (AC-19, mapped here): SQL fixture inserts a `stats_leaderboard_24h` row for `provider_id = 'never-toggled-xyz'` with NO matching `provider_visibility` row; assert the left-join in Step 3's handler treats this as `mode = 'bucketed'` (verified end-to-end in Step 3).
- Integration (AC-20, mapped here): SQL CI assertion that `SELECT COUNT(*) FROM provider_visibility_audit WHERE new_mode = 'exact' AND actor_kind = 'operator'` returns 0; failure means the operator-side process violated §6.6.3.
- Integration (AC-10 concrete transaction test): SPEC-017 v0.1 does not ship the portal handler (SPEC-014 v0.9 follow-up), but the storage contract MUST be tested at Step 1 using a test harness that drives the same `provider_portal` role. The UPSERT shape is pinned by SPEC §6.3 — note the explicit conflict target on `(provider_id)`, which is required by PostgreSQL for `DO UPDATE`.

  **Subcase A — `bucketed → exact` toggle (commit path):**
  ```sql
  -- 1. Setup: pre-seed p1 as bucketed (outside the provider_portal transaction; any role with INSERT privilege works in fixture setup).
  -- The v0.1.7 column `blocked_from_partner_projection` is omitted from the INSERT and falls to its DEFAULT FALSE.
  INSERT INTO provider_visibility (provider_id, mode) VALUES ('p1', 'bucketed');

  -- 2. Toggle transaction, run as provider_portal role:
  BEGIN;
  INSERT INTO provider_visibility (provider_id, mode)
  VALUES ('p1', 'exact')
  ON CONFLICT (provider_id) DO UPDATE
    SET mode = EXCLUDED.mode, updated_at = now();
  INSERT INTO provider_visibility_audit
    (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
  VALUES
    ('p1', 'bucketed', 'exact', 'provider', 'p1', '127.0.0.1', 'test');
  COMMIT;
  ```
  Assert BOTH:
  - `SELECT mode, blocked_from_partner_projection FROM provider_visibility WHERE provider_id = 'p1'` returns `'exact', FALSE` (the toggle did not touch the v0.1.7 stub column; rollup is not consuming it in v0.1; this assertion proves the column exists with its default after a `DO UPDATE` that does not mention it).
  - `SELECT COUNT(*) FROM provider_visibility_audit WHERE provider_id = 'p1' AND old_mode = 'bucketed' AND new_mode = 'exact' AND actor_kind = 'provider'` returns exactly `1`.

  **Subcase B — rollback path (uses a DISTINCT provider so subcase A's state is undisturbed):**
  ```sql
  BEGIN;
  INSERT INTO provider_visibility (provider_id, mode) VALUES ('p_rollback', 'exact');
  INSERT INTO provider_visibility_audit
    (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent)
  VALUES
    ('p_rollback', 'bucketed', 'exact', 'provider', 'p_rollback', '127.0.0.1', 'test');
  -- intentional error to force ROLLBACK; e.g. RAISE EXCEPTION or violate a constraint:
  INSERT INTO provider_visibility (provider_id, mode) VALUES ('p_rollback', 'bucketed'); -- PK conflict, no ON CONFLICT clause → error → transaction aborts
  COMMIT; -- has no effect since the prior error already aborted
  ```
  Assert:
  - `SELECT COUNT(*) FROM provider_visibility WHERE provider_id = 'p_rollback'` returns `0`.
  - `SELECT COUNT(*) FROM provider_visibility_audit WHERE provider_id = 'p_rollback'` returns `0`.

  This proves the storage contract is mechanically achievable under the `provider_portal` grant set AND transactional. The SPEC-014 v0.9 handler PR will reuse this test fixture as a regression smoke.

**Step 1 audit prompt authoring** (BEFORE writing step 1 code): three lanes, files named per §2.1.

### Step 2 — Rollup pipeline

**Subpackage location:** `phase4-coordinator/internal/stats/rollup/`. Uses `stats_rollup` `*sql.DB`. MAY import EXACTLY billing/session/pool read-only paths since the rollup runs out-of-band. MUST NOT import `internal/explorer` (operator-only admin surface; AC-16 forbidden set).

**Provider-identity trust gate (per §1 prereq 4):** before writing rollup queries, verify the OLTP `provider_id` source field is sourced from authenticated `provider_token` plumbing (SPEC-002 v1.4 §7). If not, filter the rollup to authenticated rows OR block public cutover. The IMPL author MUST document the trust-source decision in the Step 2 PR description, and the SECURITY audit lane MUST verify the decision is consistent with [[provider-auth-unauthenticated-end-to-end]].

**Per-table refresh jobs at the §9.2 cadences:**

- `stats_overview_current` every 30s. **v0.1.7 reminder (§9.2):** the `tokens_in / tokens_out / requests` columns are CUMULATIVE all-time counters (SUM since rollup-start), NOT a 24h window. Live point-in-time columns (`nodes_online`, `nodes_hardware_attested`, etc.) come from the pool registry snapshot.
- `stats_timeseries_rpm_30m` / `stats_timeseries_tpm_30m` every 30s, rolling 30-minute window. **v0.1.7 reminder:** these are now TWO independent rollup jobs writing to TWO independent `stats_components_health` rows (`timeseries_rpm` and `timeseries_tpm`), not a single conflated `timeseries` row.
- `stats_leaderboard_24h` every 60s.
- `stats_leaderboard_7d` every 5 minutes.
- `stats_leaderboard_30d` every 30 minutes (incremental merge per §9.3).
- `stats_leaderboard_all` every 6 hours (incremental + nightly rebuild at operator-configured UTC hour, default 09:00 UTC, per §9.3).

**Late-event correction per §9.3:** 48h look-back for `30d`/`all`; older events recorded in `stats_late_events`; nightly full-rebuild reconciles.

**`stats_late_events` retention (v0.1.7, §9.3):** the nightly full-rebuild job MUST also `DELETE FROM stats_late_events WHERE recorded_at < now() - INTERVAL '90 days'` AFTER the §9.4 atomic-swap transaction commits (NOT in the same transaction — retention DELETE is a separate, idempotent step that can be retried). Operator-configurable via `stats.rollup.late_events_retention_days`; the IMPL MUST refuse to start (or log + clamp + warn — pick one and pin in tests) if the config value is below 30. Default 90 days.

**Drift detection per §9.4:** nightly rebuild compares against incremental snapshot; `>0.5%` divergence on any axis emits `stats_rollup_drift_detected` structured-log event AND records the divergence in the operator alerting pipeline (Step 4); rebuild value wins.

**Nightly rebuild atomicity (v0.1.7, §9.4) — pin this:** the nightly rebuild of `stats_leaderboard_all` (and `stats_leaderboard_30d`) MUST execute in a single PostgreSQL transaction so the leaderboard never serves a half-rebuilt state. SPEC §9.4 names Shape A (temp-table swap with `TRUNCATE`) and Shape B (atomic rename with `ALTER TABLE ... RENAME` + `DROP TABLE`). **Both require privileges (`TRUNCATE`, `ALTER`, `DROP`, ownership) that are NOT in the locked `stats_rollup` grant set (§7.2.2 grants are SELECT/INSERT/UPDATE/DELETE only).** Until a SPEC v0.1.8 candidate either widens the grant set OR adds Shape C below to §9.4, the IMPL author MUST use:

- **Shape C (executable under the locked §7.2.2 grants) — single-transaction DELETE + INSERT:**
  ```sql
  BEGIN ISOLATION LEVEL READ COMMITTED;
  -- 1. Build the new rows into a CTE / sub-query.
  -- 2. Delete all existing rows.
  DELETE FROM stats_leaderboard_all;
  -- 3. INSERT the rebuilt rows from the same connection.
  INSERT INTO stats_leaderboard_all (provider_id, pseudonym, generated_at, rank_earnings, ...)
  SELECT ... FROM ... ; -- the rebuilt source query
  COMMIT;
  ```
  Atomicity guarantee: PostgreSQL MVCC means concurrent `stats_reader` SELECTs see the pre-DELETE snapshot until the transaction commits, then see the post-INSERT snapshot. There is no window where the handler observes an empty leaderboard. A failed transaction MUST roll back, leaving the pre-rebuild state intact.

The IMPL author MUST file a SPEC v0.1.8 candidate that EITHER (a) widens §7.2.2 to grant `TRUNCATE`/ALTER on the leaderboard tables to `stats_rollup` (re-enabling Shapes A/B), OR (b) adds Shape C explicitly to §9.4 as a §7.2.2-grant-compatible variant. Until that candidate locks, Shape C is the only executable atomicity-preserving shape under the locked grants. The IMPL author MUST NOT widen the role in code without the SPEC change.

The rebuild MUST NOT interleave per-provider UPSERT operations against the live table outside a transaction. A test MUST verify (i) a deliberately-aborted rebuild leaves the live table unchanged, AND (ii) a concurrent `stats_reader` query during a successful rebuild sees consistent state (never an empty leaderboard).

**`meta.rewards_populated` computation (v0.1.7, §9.1a + §5.2):** the rollup MUST compute, per window in `{24h, 7d, 30d, all}`, the boolean `rewards_populated = EXISTS (SELECT 1 FROM provider_rewards_ledger WHERE unix_ts >= <window_start_unix> AND unix_ts < <window_end_unix> LIMIT 1)`. The result is persisted in the v0.1.7 `rewards_populated` storage (the lookup table or denormalized column chosen in Step 1). The handler reads this signal on the request path — Step 3 MUST NOT compute it synchronously against `provider_rewards_ledger` (the handler role does not have SELECT on the ledger; that's by design per §7.2.1 deny list).

**`stats_components_health` updates and bootstrap:** each job UPSERTs its `generated_at` + `last_ok_at` on success, OR `last_error_at` + `last_error_message` on failure (and leaves `generated_at` / `last_ok_at` at their last successful values if they exist; sets them to an explicit "never succeeded" sentinel if not). There is NO `status` column on this table — the JSON `status` field exposed by `/v1/stats/health` (§5.3) is DERIVED at request time from `generated_at` vs §9.5 target staleness vs §5.8 503 budget.

**Bootstrap rule (pin this — v0.1.7 has 7 components, not 6):** the migration MUST pre-seed all seven component rows (`overview`, `timeseries_rpm`, `timeseries_tpm`, `leaderboard_24h`, `leaderboard_7d`, `leaderboard_30d`, `leaderboard_all`) with `generated_at = epoch` (or operator-configured `bootstrap_generated_at`) and `last_ok_at = epoch`. This guarantees the NOT NULL constraints are satisfied even if the first rollup tick fails before any success, AND it guarantees `/v1/stats/health` derives `status = "down"` for any component whose first tick has not succeeded yet (because `now - epoch > §5.8 budget`). A test MUST verify "first tick fails before any success" produces `status = "down"` without violating NOT NULL. The bootstrap MUST also seed the `rewards_populated` storage for all four windows at `false` (matching the v0.1 empty-ledger default).

**Backfill posture (both modes implemented; operator chooses at cutover):** per §9.7, implement both Path A (rollup-start-date forward + `partial_history_since` field set on `30d`/`all` responses while the window is shorter than its label) and Path B (synchronous backfill from full OLTP history before flipping `stats.streamvc.live` server-block on). Operator-config flag `stats.rollup.backfill_mode = "partial"|"full"` selects at runtime; default `"partial"`.

**`partner_keys.last_used_at` updates: NOT IMPLEMENTED in v0.1.** Per the `partner_keys_writer` resolution in Step 1, the role is skipped for v0.1 and `last_used_at` stays NULL. Step 2 implements NO worker, NO channel, and Step 3's auth dispatcher (§5.4.3 step 2) does NOT emit any `last_used_at` touch. The SPEC §5.4.3 "MAY update `last_used_at` (best effort)" is satisfied by the default-off path. A future SPEC v0.2 candidate that pins an executable grant pattern will unblock the worker; do NOT add it in v0.1 IMPL.

**Minimal fixture corpus for Step 2 tests** (mechanically reusable in Step 3 too):

A seed SQL file under `phase4-coordinator/internal/stats/testdata/` MUST contain at minimum:

- 2 active providers with `last_seen_at` within 5 min and `first_seen_at` > 48h ago.
- 1 provider with NO `provider_visibility` row (default-bucketed).
- 1 provider with `provider_visibility.mode = 'exact'` (audit row `actor_kind = 'provider'` inserted).
- 1 provider with `provider_visibility.mode = 'bucketed'` explicitly set.
- 1 `provider_rewards_ledger` row for one of the providers.
- 1 OLTP "late event" inside the 48h lookback window.
- 1 OLTP "late event" outside the 48h lookback window.
- 10+ billing rows / 5+ session rows spanning enough timestamps to validate all sort axes (`earnings`, `tokens`, `jobs`) and all windows (`24h`, `7d`, `30d`, `all`).

**Tests for Step 2:**

- Unit: each rollup query produces deterministic output on the seed corpus.
- Integration: a rollup tick advances the correct freshness markers per-table (NOT a `stats_*.generated_at` shorthand — `stats_timeseries_*` and `stats_late_events` have NO `generated_at` column per §9.1):
  - `stats_overview_current.generated_at` advances on every overview tick.
  - Each `stats_leaderboard_24h|7d|30d|all.generated_at` advances at its cadence.
  - `stats_timeseries_rpm_30m` / `stats_timeseries_tpm_30m` advance by INSERTing the newest `bucket_start` minute (the "freshness" signal for these tables is the newest `bucket_start`, not a `generated_at` column).
  - `stats_components_health.generated_at` AND `last_ok_at` update for each of the seven v0.1.7 components on success; `last_error_at` + `last_error_message` update on failure. The test MUST seed an rpm-only failure (timeseries_rpm tick fails, timeseries_tpm tick succeeds) and assert that `stats_components_health` reflects the split — only the failing component shows `last_error_*`, the other still shows fresh `generated_at`.
- Integration (rollup-state assertions only — handler-response tests are Step 3): seed or age the `stats_components_health` row for `component = 'overview'` so that `now - generated_at > 120s`. Assert the table state directly (`SELECT generated_at, last_error_at FROM stats_components_health WHERE component = 'overview'`). The corresponding `/v1/stats/health` JSON status assertion (`status = "down"`) lives in Step 3, seeded from this Step 2 fixture. Separately, AC-14 for `/v1/stats/overview` 503 also lives in Step 3 and seeds `stats_overview_current.generated_at > 120s` — a different code path (handler freshness check vs health derivation).
- Integration: late event at `T-30h` folds into `30d` snapshot on next refresh; event at `T-60h` lands in `stats_late_events` (the rollup role can write here; the handler role cannot read it per §7.2.1).
- Integration: drift > 0.5% triggers `stats_rollup_drift_detected` event AND rebuild value wins (assert `stats_leaderboard_all.<axis>` matches rebuild, not incremental).
- Property: `provider_id → pseudonym` mapping is deterministic per provider (same `provider_id` → same pseudonym across snapshots; pseudonym is stable per provider per §3.3).
- Integration (both backfill modes, rollup-state only — handler-response assertion is Step 3): set `stats.rollup.backfill_mode = "partial"` and run Path A backfill; assert the persisted rollup-state metadata (e.g. a `rollup_state.partial_history_since` row, or equivalent persisted source the handler will read) records the start timestamp. Set `= "full"` and run Path B backfill; assert the persisted metadata records no `partial_history_since` (or sets it to NULL). Step 3 will own the test that `/v1/stats/leaderboard?window=30d` JSON exposes or omits the field accordingly.
- Integration (v0.1.7 — rebuild atomicity per §9.4): run a deliberately-aborted nightly rebuild (e.g. inject a SQL error inside the transaction body); assert `SELECT * FROM stats_leaderboard_all` is unchanged from the pre-rebuild state. Then run a successful rebuild and assert the swap landed atomically (e.g. for Shape B the `_old` table no longer exists; for Shape A the temp table was dropped on commit).
- Integration (v0.1.7 — `stats_late_events` retention per §9.3): seed `stats_late_events` rows with `recorded_at = now() - INTERVAL '100 days'` AND `recorded_at = now() - INTERVAL '30 days'`. Run the nightly job. Assert the 100-day-old row is DELETED; the 30-day-old row is preserved. Set `stats.rollup.late_events_retention_days = 15` and assert the IMPL refuses to start (or clamps + logs — match the pinned behavior).
- Integration (v0.1.7 — `rewards_populated` computation per §9.1a + §5.2): with empty `provider_rewards_ledger`, run a rollup tick and assert the persisted `rewards_populated` value for each of `{24h, 7d, 30d, all}` is `false`. Insert one `provider_rewards_ledger` row with `unix_ts` inside the 7d window; re-run the tick; assert `rewards_populated[7d] = true` AND `rewards_populated[24h] = false` (assuming the inserted unix_ts is older than 24h ago).

**Step 2 audit prompt authoring**: three lanes.

### Step 3 — HTTP handlers + error envelope + CORS + auth + redaction

**Package location:** `phase4-coordinator/internal/stats/` (flat — handlers, mux wiring, recover middleware all live here per the existing `internal/explorer/` pattern). Subpackage `phase4-coordinator/internal/stats/store/` houses the DAO that the handlers call. Uses `stats_reader` `*sql.DB`.

**Handlers (mount under `/v1/stats/*` per §7.1, exposed on BOTH `coordinator.streamvc.live/v1/stats/*` and `stats.streamvc.live/v1/stats/*` via the same binary):**

- `GET /v1/stats/overview` — §5.1 JSON shape, 14 `network.*` fields, 30-point timeseries with `null` (NOT zero) for missing minutes (§5.1 field rules). **v0.1.7 reminder:** the `_total` fields are CUMULATIVE all-time counters (per §9.2).
- `GET /v1/stats/leaderboard` — §5.2 wire shape. **v0.1.7 binding deltas vs v0.1.6:**
  - Public projection `totals` object carries ONLY `tokens`, `jobs`, `active_accounts`. The handler MUST NOT emit `totals.earnings_usd`, `totals.earnings_work_usd`, or `totals.earnings_rewards_usd` on the public projection. AC-6 negatively asserts this.
  - Public projection rows carry ONE bucket field (`earnings_bucket`) and ONE exact field (`exact_earnings`). Do NOT emit `earnings_work_bucket`, `earnings_rewards_bucket`, `exact_earnings_work`, or `exact_earnings_rewards` on the public projection (the storage no longer carries the per-axis buckets either).
  - Every response MUST include `meta.rewards_populated` (REQUIRED boolean, sourced from the v0.1.7 `rewards_populated` storage written by Step 2).
  - Responses to `?window=30d` AND `?window=all` MUST include the top-level `partial_history_since` RFC 3339 timestamp when `rollup_state.partial_history_since` is non-NULL and within the window. Omit the field entirely when NULL or when the rollup has fully overlapped its window (per §9.7). Responses to `?window=24h` AND `?window=7d` MUST NEVER include the field.
  - Partner-key projection ADDS per-row `earnings_usd`, `earnings_work_usd`, `earnings_rewards_usd`, `first_seen_at`, `last_seen_at` AND adds `totals.earnings_usd`, `totals.earnings_work_usd`, `totals.earnings_rewards_usd`. These exact-$ fields surface for ALL providers regardless of `provider_visibility.mode` per §5.2 + §6.6.2.
  - Validation (unchanged from v0.1.6):
    - `window`: one of `24h | 7d | 30d | all`. Default `24h` per §5.2 (NOT per AC-2 — AC-2 only checks window default + invalid window). Invalid → 400 `bad_request`.
    - `sort`: one of `earnings | tokens | jobs`. Default `earnings`. Invalid → 400.
    - `limit`: integer in `[1, 100]` per §5.2. Default `50`. Out-of-range or non-integer → 400 (this is §5.2's normative bound, NOT AC-2).
    - Unknown query params MUST be ignored, not rejected.
- `GET /v1/stats/health` — §5.3 shape; returns 200 even when components are degraded; non-200 only when the coordinator process itself is unhealthy. The JSON `status` field is DERIVED at request time from `stats_components_health` rows + §9.5 thresholds + §5.8 budgets, NOT read from a `status` column. **v0.1.7 reminder:** the `components` map has 7 keys (`overview`, `timeseries_rpm`, `timeseries_tpm`, `leaderboard_24h`, `leaderboard_7d`, `leaderboard_30d`, `leaderboard_all`). The single `timeseries` key from v0.1.6 is REMOVED — the handler MUST NOT emit it.

**Partner-key authn flow per §5.4.3 — 7-row decision table** (NOT 6 — the absent-Origin reject case is row 3):

| Row | Authorization | `partner_keys` row | Origin | Result |
|---|---|---|---|---|
| 1 | absent | n/a | n/a | 200 public projection |
| 2 | present, matches active row, `allowed_origins = '{}'` | active | absent or any | 200 partner projection |
| 3 | present, matches active row, `allowed_origins` non-empty | active | absent | **401 `unauthorized`** |
| 4 | present, matches active row, `allowed_origins` non-empty | active | exact-match | 200 partner projection (CORS echoes `Origin`) |
| 5 | present, matches active row, `allowed_origins` non-empty | active | not in allowlist | 401 `unauthorized` (NOT 403) |
| 6 | present, no matching row | none | any | 401 `unauthorized` |
| 7 | present, matches row, `revoked_at IS NOT NULL` | matched-revoked | any | 401 `unauthorized` |

Implementation rules:

- ALWAYS compute `sha256(<token>_utf8_bytes)` and ALWAYS SELECT by `token_hash` for every keyed request — no in-memory key cache that would survive revocation per §5.4.5. No early-return on prefix mismatch (would create timing side-channel).
- **v0.1.7 (§5.4.3 rule 4) — origin-rejection 401 path MUST NOT short-circuit on Origin before the hash+SELECT.** Row 5 ("Origin not in allowlist") MUST perform the SAME `sha256 + SELECT by token_hash` work as rows 6/7 BEFORE evaluating the Origin allowlist. AC-18 is now a three-way ±20% timing test across rows 5, 6, 7 (statistical test of 100+ requests per row).
- **v0.1.7 (§5.4.3 rule 5 + §5.7) — RFC 6454 ASCII serialization on all Origin comparisons.** The handler MUST normalize the request `Origin` header BEFORE comparing against `allowed_origins`: lowercase scheme; lowercase host; IDN → Punycode; strip default ports (`:80` for http, `:443` for https); a header with trailing slash, path, query, or fragment MUST be treated as if absent (apply the "absent Origin" branch). The `coordinator partner-keys issue` CLI MUST validate `--allowed-origin` values against the same normalization (idempotency check — see Step 4.A).
- Any in-process comparison of secret-derived bytes MUST use `subtle.ConstantTimeCompare` — do NOT use `==`, `bytes.Equal`, or string comparison.
- Rows 5, 6, and 7 MUST have indistinguishable response latency (±20% variance per AC-18 three-way statistical test of 100+ requests per row).
- On success, do NOT touch `last_used_at` in v0.1 (per the §7.2.4 default-off resolution above). The auth dispatcher returns success directly; no channel emit, no SQL touch.

**CORS per §5.7 — preflight is key-agnostic** (browsers don't send Authorization on preflight). The handler MUST NOT evaluate per-key allowlist at OPTIONS time. Per-key allowlist enforced ONLY on GET. CORS allowed origins MUST use exact-match strings; sibling-subdomain wildcards (e.g. `*.streamvc.live`) FORBIDDEN — `console.streamvc.live`, `portal.streamvc.live`, `stats.streamvc.live` have distinct trust roles.

Preflight returns exactly **204** (NOT 200 — AC-13 verifies, do not permit a 200 escape hatch) with empty body, `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`, `Access-Control-Allow-Headers: Authorization, Content-Type`, **`Access-Control-Max-Age: 60`** (v0.1.7: was `3600` in v0.1.6; the SPEC lowered it so partner-key revocation propagates to the browser preflight cache within a minute, not within an hour; operator MAY raise via runtime config to a maximum of 300; >300 requires a SPEC bump). `Access-Control-Allow-Origin` follows §5.7, after applying RFC 6454 normalization to the request Origin:

- **Origin is on the global partner-origin allowlist** (the union of every active `partner_keys.allowed_origins` array + `https://console.streamvc.live` + `https://portal.streamvc.live`) → `Access-Control-Allow-Origin: <normalized Origin>` (echoed) AND `Access-Control-Allow-Credentials: true`.
- **Origin is NOT on the global allowlist** → `Access-Control-Allow-Origin: *` AND do NOT emit `Allow-Credentials`.

The subsequent GET is then evaluated by the §5.4.3 7-row decision table EXACTLY. Preflight permissiveness MUST NOT be interpreted by clients or implementations as a guarantee that the GET will succeed:

- If the GET has no `Authorization`, the public projection applies (row 1).
- If the GET has a valid key with non-empty `allowed_origins` and the Origin is not in the key's allowlist (after RFC 6454 normalization), the GET returns 401 (row 5) regardless of what preflight returned — AND the handler MUST still do the sha256+SELECT first (timing equivalence per v0.1.7 §5.4.3 rule 4).
- If the GET has a revoked key, the GET returns 401 (row 7).

**v0.1.7 — partner-key projection CORS MUST NEVER use `Access-Control-Allow-Origin: *`.** §5.7 row 3 of v0.1.6 is split into two rows in v0.1.7:

- Partner-key, `allowed_origins = '{}'`, browser context (Origin present): `Access-Control-Allow-Origin: <normalized Origin>` (echoed) + `Access-Control-Allow-Credentials: true`.
- Partner-key, `allowed_origins = '{}'`, server-to-server (Origin absent): OMIT `Access-Control-Allow-Origin` entirely; OMIT `Allow-Credentials`. Non-browser clients ignore CORS headers; this avoids the Fetch-spec violation where a credentialed response with `ACAO: *` is rejected by browsers.

The handler MUST enforce this split — using `ACAO: *` on any partner-key projection response (any of rows 2/3/4 of the v0.1.7 §5.7 table) is a CRITICAL bug. SECURITY audit lane MUST sweep for this with a fixture that drives all 7 §5.7 rows.

**Error envelope per §5.9 closed code vocabulary** — `bad_request`, `unauthorized`, `method_not_allowed`, `rate_limited`, `stats_stale`, `internal`. 304 exempt per §5.9 first paragraph. The IMPL author MUST NOT introduce new codes.

**405 handling per §4.3:** any verb other than GET/HEAD/OPTIONS against any `/v1/stats/*` path returns 405 with `Allow: GET, HEAD, OPTIONS` header AND the §5.9 envelope `{"error":{"code":"method_not_allowed",...}}` (AC-21).

**ETag + 304 per §5.1 / AC-12:** weak ETag = `sha256(body)` computed once per rollup snapshot. If-None-Match comparison returns 304 with empty body when `generated_at` has not advanced. 304 carries `ETag`, `Cache-Control`, `Vary` per RFC 7232.

**503 staleness handler per §5.8 / §9.5 budgets** (AC-14 verifies 120s for overview). 503 stale responses are emitted AFTER cheap auth/CORS validation but BEFORE the per-IP / per-key success-bucket debit — a rollup outage MUST NOT exhaust rate limits for healthy clients. A separate coarse abuse limiter still caps repeated stale polling.

**Cache-Control directives (normative — assert in tests):**

| Endpoint | Cache-Control |
|---|---|
| `/v1/stats/overview` | `public, max-age=30, s-maxage=30, stale-while-revalidate=60` |
| `/v1/stats/leaderboard` public projection | `public, max-age=60, s-maxage=60, stale-while-revalidate=120` |
| `/v1/stats/leaderboard` partner-key projection | `private, max-age=30, s-maxage=30` |
| `/v1/stats/health` | `public, max-age=10, s-maxage=10` |

**v0.1.7 `Vary` header rules** (binding — assert per-endpoint, per-projection in tests):

| Endpoint / projection | `Vary` |
|---|---|
| `/v1/stats/overview` | `Accept-Encoding, Origin` |
| `/v1/stats/leaderboard` public projection | `Accept-Encoding, Origin` (NOT `Authorization` — v0.1.7 H2 fix; the public projection does NOT branch on Authorization, so including it would fragment edge cache by every malformed Authorization variation) |
| `/v1/stats/leaderboard` partner-key projection | `Accept-Encoding, Origin, Authorization` (Cache-Control is `private`; the only consumer of `Vary: Authorization` is the partner's own browser/SDK cache) |
| `/v1/stats/health` | `Accept-Encoding, Origin` |

The handler MUST emit the Vary header for the projection actually returned (i.e. the public branch and partner-key branch of `/v1/stats/leaderboard` set different Vary headers). A keyed request that auth-fails with 401 takes the public-projection Vary (since the response carries no key-derived content).

**`X-Stats-Generated-At` header on every `/v1/stats/*` response** per §5.1 / §5.2 / §5.3.

**Middleware stack (pinned — exactly this order, outermost to innermost):**

The recover-vs-redaction ordering issue is resolved by pinning a single stack and giving the recover middleware its own first-line `Authorization` strip. The v0.1.7 SECURITY r4 H1 added the **pre-auth coarse limiter** between access-logging and the auth dispatcher so invalid/revoked/rejected-origin probes hitting a nginx-bypassed direct-to-coordinator surface cannot drive unbounded `sha256 + SELECT by token_hash` work. The chain MUST be:

1. **Redaction-context middleware (outermost):** runs first on the inbound request. Reads `Authorization`, replaces the header value with `REDACTED` in the request's logging context (`r.Header.Set` or a request-clone pattern), and stores the parsed bearer token in `r.Context()` under an unexported typed key — e.g. `type authKey struct{}` + `r = r.WithContext(context.WithValue(r.Context(), authKey{}, parsedToken))`. The auth dispatcher (step 5 below) retrieves the token via `r.Context().Value(authKey{})`. NO goroutine-local storage, NO package globals, NO `sync.Map` keyed by goroutine ID — those patterns are non-idiomatic Go and unsafe under concurrent serving. The unexported typed key prevents accidental cross-package retrieval. Every downstream log/trace/metric emitter reads ONLY the redacted header context; the raw token in `r.Context()` is consumed by the auth dispatcher and discarded after the SELECT.
2. **Recover middleware:** wraps the entire `/v1/stats/*` subtree (all methods including GET, HEAD, OPTIONS, and the 405 path for other verbs). On panic: log `event=stats_handler_panic` (structured) using the REDACTED context — so `Authorization` is already `REDACTED`, no raw token, no `token_hash`, no raw SQL, no stack in the public log line. Stack MAY go to a debug-only sink. The recover middleware MUST ALSO perform its own first-line `Authorization` strip as defense-in-depth (in case the redaction context is bypassed for any reason); this is the SECURITY guarantee.
3. **Access-logging / tracing middleware:** reads only the redacted context.
4. **Pre-auth coarse rate limiter (v0.1.7 SECURITY H1 fix) — per-IP, NOT keyed on partner_keys.id:** runs BEFORE the auth dispatcher. Keys on client IP (or `X-Forwarded-For` first IP per the existing coordinator pattern). Limits set to a coarse multiple of the §5.6 public tier (e.g. 5×60 req/min = 300 req/min per IP across `/v1/stats/*`). On exceed: return 429 with §5.9 `rate_limited` envelope BEFORE the auth dispatcher runs ANY `sha256 + SELECT` work. This protects the nginx-bypass code path (direct-to-coordinator) from flood-by-invalid-bearer probes that would otherwise drive unbounded `partner_keys` lookups. The pre-auth limiter MUST NOT differentiate by Authorization presence — any `/v1/stats/*` request (absent / present-valid / present-invalid / present-revoked / present-rejected-origin) consumes the same per-IP bucket. AC-18 timing samples MUST be taken below this threshold so timing equivalence is measured on non-limited 401s.
5. **Auth dispatcher:** reads the bearer token from `r.Context().Value(authKey{})` (set in step 1), hashes via `sha256(token_utf8_bytes)`, performs SELECT against `partner_keys`, enforces §5.4.3 7-row decision table.
6. **Post-auth success rate-limit middleware (per-tier):** keys on client IP (public tier success bucket per §5.6) or `partner_keys.id` (partner tier per §5.6 + §5.4.7). Tracks successful 2xx accounting only; stale-503 responses MUST NOT debit this bucket (so a rollup outage does not exhaust quotas for healthy clients). The public-tier bucket here is the "fallback when nginx is bypassed" surface §5.6 names.
7. **Handler:** computes JSON, returns response. Recover MUST be set on `500 internal` with §5.9 envelope on panic.

**Tests for the pre-auth limiter (SECURITY H1):**

- Direct-to-coordinator (nginx bypassed) flood test: send 350 `/v1/stats/leaderboard` requests in 60s with `Authorization: Bearer mpk_invalid_<random>` from a single client IP. Assert: the 301st request returns 429 with §5.9 envelope BEFORE the auth dispatcher runs a SELECT (verify via SQL query counter — the `partner_keys` SELECT count for the test client IP MUST be ≤300 even though 350 requests were sent). The pre-auth limiter catches the flood without consuming DB work for the excess.
- AC-18 statistical test (rows 5/6/7) MUST run at a request rate below the pre-auth threshold (i.e. ≤270 req/min sustained) so timing samples are not coupled to the pre-auth 429s. Pin the rate explicitly in the test setup.

Returns `500 internal` with the §5.9 envelope and `Content-Type: application/json; charset=utf-8`. AC-11 verifies via an injected panic in a test handler that `/healthz` (the coordinator's own liveness endpoint) survives.

**Redaction invariants (apply across the whole stack, AC-15 + SECURITY H1):**

- Forbid raw token, `token_hash`, and any substring of the random 43-char token portion from appearing anywhere: structured logs, nginx access logs (via nginx config in Step 4), Prometheus/metric labels, trace spans, response bodies, error messages.
- **Log allowance (different from metric allowance):** logs MAY reference `partner_keys.id` (integer), `partner_keys.label`, and the 8-char `prefix` (the prefix is permitted in logs for human correlation per SPEC §5.4.6).
- **Metric allowance (tighter than log allowance):** metric labels MAY reference `partner_keys.id` (integer) and bounded enums (e.g. `tier ∈ {"public","partner"}`). Metric labels MUST NOT include `prefix`, `partner_keys.label` (operator text), `token_hash`, raw token, any random-substring, Origin string, or untrusted user input. See SECURITY M5 + ARCH H3 / CODE-R2-007 for why metrics is tighter than logs (metric cardinality + external observability retention).

**Rate limiting per §5.6:**

- Public tier: nginx `limit_req_zone` is PRIMARY (configured in Step 4). In-process bucket is FALLBACK — defense-in-depth for the case nginx is bypassed (direct `coordinator.streamvc.live` access during a debugging window).
- Partner tier: in-process bucket keyed on `partner_keys.id` (NOT raw token, NOT prefix). Limits per `partner_keys.rate_limit_rpm` / `rate_limit_burst` columns; IMPL MUST clamp to per-row values, not a global default.
- 429 response includes `Retry-After: <seconds>` and §5.9 `rate_limited` envelope.

**Tests for Step 3 — AC-to-step matrix (replaces "every AC in Step 3"):**

Step 3 OWNS these ACs (writes the test):

- **AC-1** overview JSON shape (14 fields, 30-point timeseries).
- **AC-2** window default `24h` + invalid `window=foo` → 400.
- **AC-3** invalid `Bearer mpk_invalid` → 401 `unauthorized`.
- **AC-4** bucketed providers → SINGLE `exact_earnings: null` in public projection (v0.1.7: the per-axis fields are removed; the assertion is on one key, not three).
- **AC-5** exact providers → SINGLE `exact_earnings` populated with 2-decimal float (total `work + rewards`); per-axis exact-$ is partner-key-only.
- **AC-6** partner-key projection populates `earnings_usd` / `earnings_work_usd` / `earnings_rewards_usd` for ALL rows regardless of mode AND populates `totals.earnings_usd` / `totals.earnings_work_usd` / `totals.earnings_rewards_usd`. The PUBLIC projection MUST NOT contain any `totals.earnings_*` key (negatively asserted — v0.1.7 H3 fix).
- **AC-7** health 200 even when degraded. Plus the health derivation test, with two explicit fixtures (no ambiguity):
  - **`down` fixture:** seed `stats_components_health` row for `component = 'overview'` with `generated_at = now - 130s` (beyond the §9.5 120s 503 budget per §5.3). Call `GET /v1/stats/health`. Assert JSON `status = "down"` exactly.
  - **`degraded` fixture:** seed the same row with `generated_at = now - 45s` (beyond the §9.5 30s target staleness but within the 120s 503 budget). Call `GET /v1/stats/health`. Assert JSON `status = "degraded"` exactly.
- **AC-11** panic recovery (injected panic; assert /healthz survives + `event=stats_handler_panic` logged with redaction).
- **AC-12** 304 round-trip on If-None-Match.
- **AC-13** OPTIONS `/v1/stats/leaderboard` returns EXACTLY 204 with empty body, `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`, `Access-Control-Allow-Headers: Authorization, Content-Type`, AND `Access-Control-Max-Age: 60` (v0.1.7 lowered from 3600; assert this exact value).
- **AC-14** `stats_overview_current.generated_at` aged > 120s → 503 with `stats_stale` envelope + `Retry-After: 30`.
- **AC-15** (Step 3 share only — per the §2.4 matrix and ARCH r6 H1 split): handler structured-log redaction sweep + recover panic-log redaction + trace-span redaction. Assert no raw token, no `token_hash`, no random-portion substring across structured logs, panic logs, and trace spans produced by the handler stack. Do NOT include nginx access logs, CLI journalctl, or Prometheus metric labels in the Step 3 AC-15 sweep — those surfaces live in Step 4.A (CLI journalctl), Step 4.B (nginx access logs), and Step 4.C (metric labels) respectively. The §2.4 matrix is the single source of truth for the cross-step AC-15 split.
- **AC-18** three-way timing-attack statistical test (v0.1.7: 100+ requests for EACH of rows 5, 6, and 7 of §5.4.3 table; assert pairwise variance ≤ 20% across all three. Row 5 is rejected-origin: seed a valid key with `allowed_origins = ARRAY['https://allowed.example']`, then send `Authorization: Bearer <valid_token>` + `Origin: https://attacker.example`; assert the response is 401 AND the latency falls within ±20% of the no-row and revoked-row 401 latencies).
- **AC-19** end-to-end fixture: provider with no `provider_visibility` row appears in leaderboard with `exact_earnings: null` (single field; bucketed default via left-join semantics). The left-join MUST also default `blocked_from_partner_projection = FALSE` on the no-row case (v0.1.7 column stub, not consumed by the rollup but the left-join must produce the correct default tuple).
- **AC-21** POST `/v1/stats/overview` → 405 with `Allow` header AND `method_not_allowed` envelope.
- **HEAD support test (SPEC §4.3, v0.1.7-tightened per CODE r7 finding 007):** the SPEC requires HEAD on every GET. The handler's method switch MUST accept HEAD AND return the same status code + headers (Content-Type, Cache-Control, ETag, X-Stats-Generated-At, Vary, ACAO, Access-Control-Allow-Credentials when applicable) as the corresponding GET, but with an EMPTY response body. Three explicit test cases: `HEAD /v1/stats/overview`, `HEAD /v1/stats/leaderboard` (both public and partner-key projection — partner sends `Authorization`), `HEAD /v1/stats/health`. Assert (i) status = 200 (or 503 for stale path), (ii) headers identical to the GET response (compare header-by-header), (iii) body bytes = 0. The Go `net/http` `ServeMux` does not automatically handle HEAD; the implementer MUST explicitly add HEAD to the method allowlist alongside GET (per §4.3 + AC-21 negative assertion).

Additionally for Step 3 specifically:
- **Cache-Control header assertions** for all four (endpoint, projection) cells in the table above.
- **Vary header assertions (v0.1.7)** — public-projection `/v1/stats/leaderboard` response MUST have `Vary: Accept-Encoding, Origin` (NOT including `Authorization`); partner-key projection MUST have `Vary: Accept-Encoding, Origin, Authorization`. A 401 keyed-but-invalid response MUST take the public-projection Vary (the response body is not key-derived).
- **`X-Stats-Generated-At`** present on every `/v1/stats/*` response.
- **§5.4.3 7-row decision-table test** — one fixture per row, including the absent-Origin case (row 3).
- **CORS sibling-subdomain reject test** — `Origin: https://evil.streamvc.live` rejected; `Origin: https://portal.streamvc.live` accepted only if EXACTLY in allowlist.
- **CORS partner-key projection NEVER `ACAO: *` test (v0.1.7 H1)** — drive all 7 §5.7 rows; assert that for partner-key projection rows (rows 3, 4, 5 in v0.1.7), the response `Access-Control-Allow-Origin` is either the echoed normalized Origin (when set) OR omitted entirely (server-to-server context), NEVER `*`. Also assert `Allow-Credentials: true` is paired with the echoed-Origin case and omitted in the server-to-server case.
- **RFC 6454 Origin normalization test (v0.1.7 M4)** — seed `partner_keys.allowed_origins = ARRAY['https://acme.example']` (non-empty allowlist; the key is active, not revoked). Send requests with `Origin: HTTPS://Acme.Example`, `https://acme.example:443`, `https://acme.example/`, `https://acme.example?foo=bar`. Assert:
  - First two (case-insensitive scheme/host + default-port stripped) → 200 partner projection (row 4 of §5.4.3 — exact allowlist match after normalization).
  - Third and fourth (trailing slash, query string) → MALFORMED Origin → treated as ABSENT Origin → with non-empty allowlist the locked §5.4.3 branch is **row 3**: `401 unauthorized` AFTER the same `sha256 + SELECT by token_hash` work as rows 5/6/7 (timing equivalence with row 3 is implied but AC-18 only requires equivalence across rows 5/6/7 — the test MUST still observe that row 3's latency falls within the same ±20% band as rows 5/6/7 since they share the hash+SELECT path).
  - Separate empty-allowlist fixture: seed a different key with `allowed_origins = '{}'`; send `Origin: https://acme.example/` (malformed) — treated as absent — with empty allowlist this is row 2 of §5.4.3 → 200 partner projection (no Origin restriction). Pin this distinction so the implementer doesn't conflate "allowlist enforces Origin requirement" with "malformed Origin always rejects."
- **503 stale not debited from rate-limit bucket** — issue 100 stale requests, then 60 fresh; assert all 60 fresh succeed.
- **`partial_history_since` exposure (v0.1.7 H4)** — seed `rollup_state.partial_history_since = <timestamp>` (Path A fixture from Step 2); call `GET /v1/stats/leaderboard?window=30d` AND `?window=all`; assert response includes top-level `partial_history_since` matching the seeded value (both windows). Call `?window=24h` AND `?window=7d`; assert the field is OMITTED on both (per §9.7). Seed `partial_history_since = NULL` (Path B fixture); call `?window=30d`; assert the field is OMITTED. All fixtures share the Step 2 rollup state.
- **`meta.rewards_populated` exposure (v0.1.7 D-H2)** — empty `provider_rewards_ledger` fixture + Step 2 rollup tick → `meta.rewards_populated = false` on every window's response. Insert one ledger row inside the 7d window + tick → `?window=7d` returns `meta.rewards_populated = true`; `?window=24h` returns `false` (assuming the unix_ts is outside the 24h window).
- **Constant-time comparison** — code inspection / unit test that token-derived comparisons use `subtle.ConstantTimeCompare`.
- **Public response negatively asserts `totals.earnings_*` absence (v0.1.7 H3)** — `GET /v1/stats/leaderboard` (no Authorization); decode JSON; assert `totals.earnings_usd`, `totals.earnings_work_usd`, `totals.earnings_rewards_usd` are NOT present in the response body. Partner-key projection assertion (separate test) — same endpoint with valid `Authorization`; assert all three totals are present.
- **Public response single-bucket / single-exact-field test (v0.1.7 D-M1)** — assert response rows contain exactly `earnings_bucket` (string) and `exact_earnings` (float or null), and do NOT contain `earnings_work_bucket`, `earnings_rewards_bucket`, `exact_earnings_work`, or `exact_earnings_rewards`.

Step 3 does NOT own (handled in other steps per matrix in §2.4):

- AC-8 (rate-limit 61st request) — Step 4 (nginx integration test).
- AC-9 (`stats_reader` permission denied) — Step 1.
- AC-10 (`provider_visibility` toggle inserts audit row) — Step 1 SQL fixture (full UI handler is SPEC-014 v0.9).
- AC-16 (import-graph lint) — Step 1 CI lint.
- AC-17 (partner-key CLI tokens) — Step 4.
- AC-20 (no operator-exact audit row) — Step 1 CI SQL assertion.

**Step 3 audit prompt authoring**: three lanes.

### Step 4 — Partner-key CLI + nginx + observability

**Step 4 audit scope is split into three subsections** to prevent nginx/rate-limit work from masking CLI secret-handling or observability gaps (per ARCH M3):

- **4.A Partner-key CLI lifecycle** (issuance, rotation, revocation, log redaction).
- **4.B Edge / nginx / rate-limit / cache.**
- **4.C Observability, runbooks, changelog.**

The SECURITY audit lane MUST explicitly sweep each of 4.A, 4.B, 4.C in its category walk — a no-finding subsection MUST still record the evidence checked (token-handling steps, log-sink scans, metric-label enumeration, etc.). A clean 0/0/0 SECURITY result is acceptable iff all three subsections produce evidence; an empty or unmentioned subsection is itself an audit-coverage gap.

#### 4.A Partner-key CLI lifecycle

**`coordinator partner-keys issue` subcommand per §5.4.2:**

Flags:

- `--label "<text>"` (required) — human-readable label.
- `--allowed-origin <url>` (repeatable, optional) — populates `allowed_origins`. Multiple = allowlist. Empty = no Origin restriction. **v0.1.7 binding (§5.4.3 rule 5):** the CLI MUST validate each `--allowed-origin` value against the RFC 6454 ASCII serialization rule. Reject (non-zero exit, no INSERT) any value that does not parse to its own normalized form — e.g. `HTTPS://Acme.Example/` MUST be rejected (trailing slash, mixed case) and the operator MUST re-issue as `https://acme.example`. This is an idempotency check: a normalized value passes the check; a non-normalized value does not.
- `--rpm <int>` (default 600) — populates `rate_limit_rpm`.
- `--burst <int>` (default 1200) — populates `rate_limit_burst`.
- `--created-by <text>` (OPTIONAL — if omitted, defaults to a non-empty operator principal: `$USER@$(hostname)` from environment, or `"unknown@<hostname>"` if `$USER` is unset; populates the `created_by TEXT NOT NULL` column per §5.4.1). The default MUST be non-empty so the locked SPEC AC-17 command `coordinator partner-keys issue --label X` (NO `--created-by` flag) still passes argument validation, generates a token, and INSERTs a row with non-empty `created_by`. CI tests run BOTH the bare AC-17 command AND the explicit `--created-by ops@example.com` variant.
- `--rotate-from <existing_id>` (optional) — see rotation flow below.

Issuance flow:

1. Generate 32 cryptographically random bytes via the system CSPRNG.
2. Encode unpadded base64url (RFC 4648 §5, no `=` padding) → 43-character body.
3. Prefix with `mpk_` → 47-character raw token (length math: `mpk_` is 4 chars + 43 base64url chars = 47).
4. Compute `token_hash = sha256(raw_token_utf8_bytes)`.
5. INSERT into `partner_keys` with: `token_hash`, `token_hash_alg = 'sha256'`, `prefix = <first 8 chars of raw token>` (always begins `mpk_`), `label`, `allowed_origins`, `rate_limit_rpm`, `rate_limit_burst`, `created_by`, `rotated_from_id` (if `--rotate-from` was passed, else NULL).
6. Print raw token to stdout exactly ONCE. Process exit MUST NOT log the raw token anywhere — verified by the AC-17 assertion.

**Rotation per §5.4.4** — there is NO standalone `rotate-from` subcommand. Rotation is performed by `coordinator partner-keys issue --rotate-from <existing_id>`, which INSERTs a new row with `rotated_from_id = <existing_id>` and leaves the predecessor's `revoked_at = NULL` for the operator-decided overlap window.

**`coordinator partner-keys revoke --id <id> --reason "<text>"` per §5.4.5:** sets `revoked_at = now()` and `revoked_reason = <text>`. Revocation takes effect on the NEXT request (per-request hash + SELECT, no in-memory cache).

**No `coordinator partner-keys list-tokens` or similar that prints raw tokens** — the raw token cannot be re-printed after issuance time. The closest the CLI MAY surface is `partner-keys list` showing `id`, `label`, `prefix`, `created_at`, `revoked_at`, `last_used_at`.

**Tests for 4.A:**

- AC-17 (locked SPEC command): `coordinator partner-keys issue --label X` prints exactly one 47-character token starting with `mpk_`, body matches `/^[A-Za-z0-9_-]{43}$/`, INSERTs a row with non-empty `created_by` (auto-filled from `$USER@hostname` per the default rule above). Subprocess exit followed by `journalctl --since=...` shows the raw token does NOT appear; `token_hash` does NOT appear; the 43-char random body substring does NOT appear.
- AC-17 (explicit --created-by variant): `coordinator partner-keys issue --label X --created-by ops@example.com` does the same and the row's `created_by` is exactly `ops@example.com`.
- **v0.1.7 — `--allowed-origin` RFC 6454 idempotency validation:** `coordinator partner-keys issue --label X --allowed-origin https://acme.example` succeeds. `coordinator partner-keys issue --label X --allowed-origin HTTPS://Acme.Example/` exits non-zero with a clear error message naming the normalization rule; NO row is INSERTed. `coordinator partner-keys issue --label X --allowed-origin https://acme.example:443` exits non-zero (default port not stripped); operator re-runs with `https://acme.example`.
- Rotation overlap: issue key A; issue key B with `--rotate-from <A>`; assert both unlock the partner projection BEFORE revoking A; then `revoke --id <A>`; assert A returns 401 on the very next request while B still works.
- CLI smoke: `partner-keys revoke --id 99999` (non-existent) returns clean error, NOT a panic.

#### 4.B Edge / nginx / rate-limit / cache

**Nginx server-block on Pearl** for `stats.streamvc.live` AND a path-prefix block for `coordinator.streamvc.live/v1/stats/*`. Required directives:

- `limit_req_zone` declaration per endpoint at the `http` block (defines the zone — no `nodelay` here; `nodelay` is invalid on `limit_req_zone`).
- `limit_req zone=<name> nodelay;` (note: NO `burst=<n>` for the AC-8 surface — see below). Applied to each endpoint's `location` block.
- `limit_req_status 429;` per endpoint location.

**Burst conflict between locked §5.6 and locked AC-8 — Step 4.B is BLOCKED on SPEC reconciliation:**

SPEC §5.6 names "60 req/min, 120 burst" for the public tier. SPEC AC-8 requires "61st request from same IP within 60s returns 429 with `Retry-After`". With nginx semantics `rate=60r/m` and `burst=120 nodelay`, 61 requests within 60s would NOT trigger 429 — the 120-token burst budget would absorb the excess. The two pins are mechanically inconsistent in plain nginx.

**Both §5.6 and AC-8 are locked.** The IMPL author MUST NOT silently pick one over the other, AND the IMPL author MUST NOT accept an operator-recorded local divergence from either locked clause — an IMPL prompt cannot authorize shipping behavior that knowingly violates a locked contract clause (per ARCH r6 C2 / CODE r7 finding 003). Step 4.B production nginx rate-limit config is **HARD BLOCKED** until the controlling contract has one mechanical behavior. The only resolution is to lock a new SPEC version:

- **SPEC v0.1.8 reconciliation (the only acceptable path).** File a SPEC v0.1.8 candidate that reconciles §5.6 and AC-8 (e.g. clarifies that "Burst 120" applies to short legitimate spikes but the per-IP token bucket refill rate triggers AC-8's 429 at the 61st request inside the 60s window only when burst tokens are exhausted; OR drops the `120 burst` figure from §5.6 to align with the AC; OR rewords AC-8 to a higher request count consistent with the locked burst). Run the codex SPEC-audit loop on v0.1.8 until 0/0/0; lock; THEN start Step 4.B. The IMPL author MUST NOT open the Step 4.B production-nginx PR before this lock lands.

There is no operator-side waiver path. The previous "Path R2 — operator opts in to a divergence" option is REMOVED. An IMPL prompt cannot authorize behavior that fails either a locked SPEC clause or a locked AC — the controlling-contract semantics in §0 are absolute.

**For CI / fixture tests only (NEVER as the shipped production config):** a non-production test harness MAY use `limit_req zone=<name> nodelay;` (omit `burst=`) to demonstrate AC-8 mechanics deterministically. The test harness MUST be labeled `# test-only — not the shipped §5.6 config` in the nginx-config file and MUST NOT be loaded by the production deploy script. This makes AC-8 mechanically verifiable in CI without prejudicing the §5.6 vs AC-8 SPEC reconciliation.

Partner tier (`Authorization: Bearer mpk_*`) is in-process per §5.6 and does NOT use nginx `limit_req`, so the burst question doesn't apply there; the partner bucket uses `partner_keys.rate_limit_rpm` / `rate_limit_burst` columns directly.
- Strip `Authorization` header from access logs (`log_format` excludes `$http_authorization`, or use `set $authorization "REDACTED"` pattern).
- `proxy_cache_path` for public projections ONLY. The partner-key projection (carries `Cache-Control: private`) MUST NOT be cached at nginx — gate via `proxy_cache_bypass $http_authorization` so any request with `Authorization` bypasses the cache.
- `proxy_set_header X-Forwarded-For` per existing coordinator pattern.
- TLS per existing cert pipeline.

**Cloudflare integration (optional):** rate-limit and bot-management rules at the edge layered above nginx. MUST NOT cache responses with `Cache-Control: private`.

**Tests for 4.B:**

- AC-8 (nginx rate-limit): from a single client IP, issue 60 requests to `/v1/stats/overview` within 60s; assert all succeed. 61st returns 429 with `Retry-After` set, `code: "rate_limited"`. Test against the nginx surface, NOT the in-process fallback.
- nginx config validates (`nginx -t`); the new server-block serves a 200 from `/v1/stats/health`.
- Edge-cache cross-contamination test (v0.1.7-aware): issue keyed request, then anonymous request from same IP within s-maxage; assert keyed response was NOT served to the anonymous request (different body, no exact-$ leak). The protection mechanism in v0.1.7 is `Cache-Control: private` on the partner-key projection — nginx MUST NOT cache it. `Vary: Authorization` ONLY appears on the partner-key projection (v0.1.7 H2: public projection no longer carries `Vary: Authorization` — including it on the public projection would fragment edge cache by every malformed `Authorization` variation without any branch on Authorization in the response).
- Anonymous edge-cache equivalence (v0.1.7 — replacement for the prior `Bearer garbage` cache test): issue TWO anonymous public requests within s-maxage; assert nginx serves the same cached response body to both (proving the public projection caches across truly anonymous requests). Do NOT use `Authorization: Bearer garbage` as the second request — per locked AC-3, ANY present-but-invalid Bearer token MUST return `401 unauthorized` (the `proxy_cache_bypass $http_authorization` directive earlier in this section ensures any request carrying `Authorization` bypasses the public cache and reaches the handler, which then returns 401 per the §5.4.3 decision table). The earlier draft of this test (v7 commit `c45d644`) incorrectly told nginx to serve a cached public 200 to a `Bearer garbage` request — that contradicted AC-3 and the §5.4.3 row-6 hash+SELECT timing-equivalence rule. The v0.1.7 fix-pass commit removed it.
- AC-3 nginx-tier confirmation (v0.1.7): send `GET /v1/stats/leaderboard` with `Authorization: Bearer garbage` through nginx; assert the response status is 401 with `code: "unauthorized"` (the handler reaches the §5.4.3 row-6 branch via the `proxy_cache_bypass $http_authorization` rule — nginx forwards every Authorization-bearing request to the coordinator) AND the response does NOT come from any cached public 200.
- Burst behavior: at the rate-limit threshold, excess requests are REJECTED with 429 promptly, NOT delayed (verifies `nodelay`).
- Subdomain trust: request from `Origin: https://evil.streamvc.live` is rejected at the application layer (Step 3 CORS test); nginx forwards the request (does not block at edge).
- **AC-15 nginx access-log redaction (Step 4.B share):** send a keyed `/v1/stats/leaderboard` request through nginx using a valid `mpk_*` token. Wait for log flush. Scan the nginx access log file (path per the operator config) and assert ZERO occurrences of: the raw token string, the substring of the random 43-char body, the value `mpk_<any>` beyond what `prefix` legitimately carries in operator-permitted log lines, the literal `token_hash`, or any base64-like 43-char sequence. The expected log line shows `Authorization: REDACTED` or omits the header entirely per the §7.4 access-log strip directive.

#### 4.C Observability, runbooks, changelog

**Structured log events:**

- `stats_request_served` (endpoint, status, latency_ms, generated_at_age_ms, partner_key_id_or_null) — emitted via the central redaction middleware.
- `stats_rollup_tick_completed` (component, generated_at, duration_ms).
- `stats_rollup_drift_detected` (component, axis, divergence_pct, rebuild_value, incremental_value) — §9.4.
- `stats_handler_panic` (request_id, route — NO stack in public log, NO `Authorization`).
- `stats_partner_key_issued` (partner_keys.id, label, created_by, rotated_from_id_or_null). NOT the raw token.
- `stats_partner_key_revoked` (partner_keys.id, reason, actor).

**Prometheus metrics (label hygiene — see SECURITY M5):**

- `stats_request_total{endpoint, status, tier}` — tier is `"public"` or `"partner"`. NO partner_key label here (high cardinality + secret-derived risk).
- `stats_partner_key_request_total{partner_key_id}` — separate metric, label is the INTEGER id only. NO prefix, NO label-text, NO token-derived value.
- `stats_rollup_lag_seconds{component}`.
- `stats_rollup_errors_total{component}` (§9.6).
- `stats_rate_limit_exceeded_total{tier, endpoint}`.

**BetterStack/UptimeRobot monitor:** `/v1/stats/health` JSON `status` field; alert on `down` or `degraded` for > N minutes (operator-configured).

**Operator runbook entries** in `OPS.md`:

- **Rotating a partner key:** `coordinator partner-keys issue --rotate-from <id>`; deliver new token to partner via side channel; after operator-decided overlap window (default suggestion: 7 days), `coordinator partner-keys revoke --id <old>` with reason `"rotation completed"`.
- **Revoking a partner key in incident:** `coordinator partner-keys revoke --id <id> --reason "<incident>"`. Effect on next request.
- **Restarting the rollup scheduler after a panic-restart loop:** systemd unit pattern; recover middleware should prevent the panic from crashing the process, but if the rollup scheduler enters a tight error loop, the runbook step is to disable the offending component via config flag, investigate, then re-enable.
- **Emergency earnings-visibility suppression:** operator may flip a provider from `exact` → `bucketed` via an operator-only CLI `coordinator visibility revert --id <provider_id> --reason "<text>"`. This subcommand UPDATEs `provider_visibility.mode = 'bucketed'` and inserts a `provider_visibility_audit` row with `actor_kind = 'operator'`. **The CLI MUST refuse to write `mode = 'exact'` — there is no operator path to exact-enable a provider. The `bucketed → exact` direction is exclusively the SPEC-014 v0.9 provider-authenticated portal flow (or, if SPEC-014 v0.9 has not landed, a test fixture with `actor_kind = 'provider'` for CI assertion only — NEVER a production operator path).** AC-20 CI assertion catches any `new_mode = 'exact' AND actor_kind = 'operator'` row.

**Public changelog** `docs/network-stats-api/CHANGELOG.md` per §8.5, with v0.1.7 entry citing the PR numbers (one per step) and the SPEC version.

**Partner-key broader-exposure provider disclosure (§6.6.2 — HARD cutover deliverable, v0.1.7-tightened):**

SPEC-017 §6.6.2 requires that providers be disclosed, at onboarding time, that "trusted partners with an operator-issued API key see your exact earnings figures, even when your public mode is `bucketed`." This is part of the privacy posture. **v0.1.7 turned this from a SHOULD into a hard launch-sequencing MUST.** Step 4.C MUST deliver:

1. **Disclosure copy** added to `OPS.md` under a section "Partner-key exact-dollar exposure — provider disclosure obligation," substantially equivalent to the §6.6.2 SPEC text. The operator-runbook copy is the source of truth until SPEC-014 v0.9 lands the in-portal disclosure.
2. **Onboarding-flow tracker** entry in the SPEC-014 v0.9 follow-up issue noting: "Add §6.6.2 disclosure copy to the provider-account-creation flow AND a one-time disclosure to every pre-existing provider on next portal login."
3. **Cutover-runbook gate (v0.1.7 — BLOCKING):** production issuance of partner keys (any `coordinator partner-keys issue` invocation on a production coordinator that produces a key delivered to a real partner) MUST NOT begin until ALL THREE conditions are true on the live Pearl coordinator (per SPEC §6.6.2):
   - (a) SPEC-014 v0.9 has merged AND is deployed to `portal.streamvc.live`.
   - (b) The §6.6.2 disclosure copy is being shown on the provider-account creation page AND on a static portal page that every existing provider is shown on their next portal login.
   - (c) The operator runbook has a recorded sign-off entry naming the SPEC-014 v0.9 commit SHA and the date both disclosure surfaces went live.

   This is a HARD gate, not a recommendation. Operators MAY issue STAGING keys against staging coordinators for AC-1..AC-21 fixture work, partner integration dry-runs, and pre-production smoke BEFORE the SPEC-014 v0.9 surface ships. Staging keys MUST NOT be returnable on a production response. The keys themselves are distinguishable by the operator's record of which environment issued them, NOT by a namespace flag in the token — there is no protocol field for "staging vs production keys" in v0.1.7.

The cutover-runbook entry MUST be a checked box (rendered in the runbook markdown) and the Step 4.C convergence file MUST include the verbatim sign-off text.

This obligation does NOT block public cutover of the public `/v1/stats/leaderboard` projection (which is bucketed by default). It DOES block the first partner-key issuance for production use. Test partner keys against staging are exempt.

**Tests for 4.C:**

- Operator visibility CLI: `coordinator visibility revert --id <p>` works (writes audit row); `coordinator visibility exact --id <p>` does NOT exist (CLI flag absent OR subcommand rejects with clear error).
- CI assertion AC-20: `SELECT COUNT(*) FROM provider_visibility_audit WHERE new_mode = 'exact' AND actor_kind = 'operator'` returns 0; this runs in CI on every PR.
- Metric-label hygiene: scan emitted metrics under test load; no metric label contains raw token, `token_hash`, prefix, `Authorization` value, or untrusted origin string.
- BetterStack monitor smoke: hit `/v1/stats/health`; verify JSON parseable + `status` ∈ {`ok`, `degraded`, `down`}.

**Step 4 audit prompt authoring**: three lanes (4.A CLI, 4.B nginx/edge, 4.C observability/runbook).

### 2.4 AC-to-step ownership matrix (single source of truth)

| AC | Owner | Test type |
|---|---|---|
| AC-1 | Step 3 | handler unit + integration |
| AC-2 | Step 3 | handler unit |
| AC-3 | Step 3 | handler integration |
| AC-4 | Step 3 | handler integration (with Step 1 fixture) |
| AC-5 | Step 3 | handler integration (with Step 1 fixture) |
| AC-6 | Step 3 | handler integration (partner-key projection) |
| AC-7 | Step 3 | handler unit + Step 2 mock-component |
| AC-8 | Step 4.B | nginx integration |
| AC-9 | Step 1 | DB-role integration |
| AC-10 | Step 1 | SQL fixture + transaction test (UI handler is SPEC-014 v0.9; AC-10 verifies the storage shape) |
| AC-11 | Step 3 | injected panic |
| AC-12 | Step 3 | If-None-Match round-trip |
| AC-13 | Step 3 | OPTIONS preflight |
| AC-14 | Step 3 | seeded stale generated_at |
| AC-15 | Step 3 + Step 4.A + Step 4.B + Step 4.C | redaction sweep distributed: Step 3 covers handler structured logs + recover panic logs + trace spans; Step 4.A covers CLI journalctl; Step 4.B covers nginx access logs (send a keyed `/v1/stats/leaderboard` GET through nginx, then scan the access log for raw token / `Authorization` / `token_hash` / random-portion substring); Step 4.C covers Prometheus metric labels |
| AC-16 | Step 1 | CI lint |
| AC-17 | Step 4.A | CLI integration + journalctl assertion |
| AC-18 | Step 3 | timing statistical test (100+ requests) |
| AC-19 | Step 1 + Step 3 | SQL fixture (Step 1) + handler integration (Step 3) |
| AC-20 | Step 1 + Step 4.C | CI SQL assertion (runs on every PR) |
| AC-21 | Step 3 | 405 envelope test |

End-of-implementation: re-run ALL 21 ACs as a final smoke against the merged main; this is a Step 4.C deliverable.

## 3. Per-step audit-loop discipline (NON-NEGOTIABLE)

Per [[feedback-codex-only-audits]] and the SPEC audit-loop convention:

- Each step gets three codex audit lanes: ARCH, CODE, SECURITY. ARCH catches structural drift from the SPEC; CODE catches implementation bugs; SECURITY catches missed isolation / leak / timing-attack issues.
- Each lane round writes a fresh file `specs/SPEC-017-IMPL-STEP_N-{arch,code,security}-rM-audit.md`.
- **Convergence target:** `0 CRITICAL + 0 HIGH + 0 MEDIUM` per lane. LOW + INFO findings MAY be deferred and acknowledged in a `specs/SPEC-017-IMPL-STEP_N-rM-convergence.md` file before the step's PR opens.
- Author each step's audit prompts FIRST (BEFORE writing code). The audit prompt's existence is the gate that says "this step's scope is bounded."

## 4. Files you should read before writing

- [`specs/SPEC-017-network-stats-api.md`](SPEC-017-network-stats-api.md) — the LOCKED contract. Read fully, all 12 sections, 21 ACs.
- [`specs/SPEC-017-advisor-round-2026-06-25.md`](SPEC-017-advisor-round-2026-06-25.md) — locked Q1-Q4 design picks.
- `specs/SPEC-017-r1-audit.md` through `r8-audit.md` — skim for the why behind each MUST. r8 is the v0.1.7 lock audit and explains the Claude critic+designer fix pass that produced the v0.1.7 contract this prompt now anchors to.
- `specs/SPEC-017-IMPL-PROMPT-{arch,code,security}-rN-audit.md` for every available round — round-1..6 were the v0.1.6 IMPL convergence (ARCH r5, CODE r6, SECURITY r3 each reached 0/0/0); the next rounds opened with the v0.1.7 re-anchor (ARCH r6, CODE r7, SECURITY r4 — the round-N+1 fix-pass) and the loop continues from there.
- [`specs/SPEC-002-coordinator.md`](SPEC-002-coordinator.md) — line 3 (current locked version), §4 (provider state), §7 (HTTP surfaces). Stats handlers mount here.
- [`specs/SPEC-005-billing.md`](SPEC-005-billing.md) — line 3, §5.1 (work-$ semantics), §4.3-§4.8 (ledger table definitions, the OLTP source for the rollup), §10 (crash recovery / reconciliation behavior), §11.4 (tokens-out accounting).
- [`specs/SPEC-006-buyer-api.md`](SPEC-006-buyer-api.md) — line 3, §17 (header strip / X-MacProvider-* allowlist). Verify `X-Stats-Generated-At` does NOT collide.
- [`specs/SPEC-014-provider-portal.md`](SPEC-014-provider-portal.md) — line 3, §2 (authn). The SPEC-014 v0.9 candidate will own the visibility-toggle UI; SPEC-017 IMPL provides the storage and CI fixture coverage.
- [`specs/SPEC-016-payout-pipeline.md`](SPEC-016-payout-pipeline.md) — line 3 (re-pin at IMPL time; see §1 prereq 3).
- [`phase4-coordinator/internal/explorer/handlers.go`](../phase4-coordinator/internal/explorer/handlers.go) — existing handler PATTERN (window parsing, bearer auth, in-process rate limiter); do NOT extend explorer's surface.
- [`phase4-coordinator/cmd/coordinator/main.go`](../phase4-coordinator/cmd/coordinator/main.go) — current `*sql.DB` instantiation pattern (currently single shared SQLite store). SPEC-017 introduces per-role Postgres pools; this is the integration point.
- [`frontdoor/console/index.html`](../frontdoor/console/index.html) — existing console stats grid (different shape from SPEC-017 endpoints; §11 Q12 deferred).
- [`beta/DECISION_CRITERIA.md`](../beta/DECISION_CRITERIA.md) Entry 90 — the LOCK record.

## 5. Critical constraints to honor while implementing

Non-negotiable. Violations are CRITICAL findings in any IMPL audit lane.

1. **One contract, three consumers (§1.5 C1).** No field MAY be added only for console's or portal's UI convenience.
2. **Public dollar values are bucketed by default (§1.5 C2, §6.1).** Default `provider_visibility.mode = 'bucketed'`; no row → bucketed.
3. **No request-path queries against billing/session OLTP (§1.5 C3, §7.2.1).** Stats handlers query only the §7.2.1 enumerated request-path-readable grant set (NOT a `stats_*` shorthand).
4. **No handler-level access to billing internals (§1.5 C4, §7.6).** Import-graph lint enforced; rollup carve-out is explicit (Step 2).
5. **Edge-cacheable (§1.5 C5).** Every `GET` returns `Cache-Control` per §5.1/§5.2/§5.3 EXACT values.
6. **No state mutation in this SPEC (§1.5 C6).** No POST/PUT/DELETE on `/v1/stats/*`. Visibility-toggle writes come via SPEC-014 v0.9 portal flow (or operator emergency `exact` → `bucketed` revert only, per §6.6.3).
7. **Same-origin uniformity (§6.4).** The endpoint MUST NOT inspect `Origin` for `$` exposure.
8. **Partner-key authn timing-attack resistance (§5.4.3, AC-18).** Same hash + SELECT pattern for "no match" and "revoked"; latency variance ≤ 20%.
9. **Log redaction (§5.4.6, AC-15).** No raw token, no `token_hash`, no substring of random portion in any log line, nginx access log, structured log, trace span, metric label, or response body.
10. **Process isolation (§7.3, AC-11).** Recover middleware on the stats subtree, redacting `Authorization` before panic log emission.
11. **Operator MUST NOT exact-enable a provider (§6.6.3, AC-20).** No operator CLI flag, no admin endpoint, no DB script that writes `provider_visibility.mode = 'exact' AND actor_kind = 'operator'`. The only operator path for visibility is `exact → bucketed` (emergency suppression).
12. **Provider identity trust source (§1 prereq 4).** Rollup MUST source `provider_id` from authenticated `provider_token` plumbing, NOT from raw hello-frame payloads.

## 6. What this IMPL MUST explicitly defer (do not creep)

These are SPEC v0.2+ items. The IMPL author MUST NOT close any of these in code without first opening a SPEC PR.

- **§11 Q1 percentile-based buckets.** v0.1 ships absolute thresholds.
- **§11 Q2 self-serve partner-key issuance.** v0.1 ships operator-only via CLI.
- **§11 Q3 cursor-based pagination.** v0.1 ships single-shot `limit ≤ 100`.
- **§11 Q4 pseudonym rotation policy.** v0.1 ships stable per provider.
- **§11 Q5 mixed-window queries.** v0.1 ships single-window only.
- **§11 Q6 hostname pattern variants.** v0.1 implements BOTH hostnames (§7.1 default).
- **§11 Q7 backfill posture.** v0.1 implements BOTH paths; operator selects at cutover config.
- **§11 Q8 `models_serving` attested-vs-all.** v0.1 ships per §5.1.1.
- **§11 Q9 CLOSED in v0.1.7.** Per-axis buckets were stripped from v0.1; v0.1.7 ships only `earnings_bucket` (single axis on total `work + rewards`). Do NOT add `earnings_work_bucket` / `earnings_rewards_bucket` back in this IMPL.
- **§11 Q10 empty-row policy.** v0.1 ships implicit exclusion.
- **§11 Q11 partner-projection opt-out — PARTIAL in v0.1.7.** The `provider_visibility.blocked_from_partner_projection BOOLEAN` column stub is created in Step 1, but the v0.1 rollup does NOT consume it. The partner-key projection still surfaces exact `$` for ALL providers per §6.6.2. The v0.2 semantic — what the rollup returns for a blocked provider — is open. Do NOT branch on the column in v0.1.
- **§11 Q12 canonical UI consumer.** v0.1 is API-only.
- **§11 Q13 rewards-source semantics.** v0.1 ships operator-defined ledger (MAY be empty).
- Embed badge, WebSocket/SSE, GraphQL, per-provider drill-down, partner dashboards, cross-region, webhooks (per SPEC §1.3).

## 7. Final deliverables when you're done

Per-step:

1. PR for Step N, containing: code + tests + step audit prompts (ARCH, CODE, SECURITY) + per-lane per-round audit files + convergence file.
2. CI green: import-graph + os.Exit lint, unit tests, integration tests, smoke tests against the seeded fixture corpus.
3. ACs in the AC-to-step matrix mechanically verified.

End-of-implementation:

1. All four step PRs merged in order (step 1 → 2 → 3 → 4) with each rebased on the squash-merged tip of the previous.
2. `docs/network-stats-api/CHANGELOG.md` written with the v0.1.7 LOCK + IMPL entry (Step 4.C).
3. `OPS.md` updated with: partner-key rotation runbook, partner-key revocation runbook, rollup-restart runbook, emergency `exact → bucketed` suppression runbook (operator may suppress; operator MUST NOT exact-enable), AND the §6.6.2 partner-key-disclosure obligation copy + the cutover-runbook checkbox for the launch-sequencing gate.
4. `beta/DECISION_CRITERIA.md` Entry NN added: "SPEC-017 v0.1.7 IMPL shipped (Pearl deploy date, monitoring snapshot, partner-key issuance count + the cutover-runbook checkbox satisfied, AC sweep result, top-N leaderboard validation against a known provider)."
5. Operator-side cutover runbook: backfill mode selection (Path A or B), partner-key issuance for the first N partners (gated on §6.6.2 launch-sequencing precondition), nginx flip, public announcement.

**You are not done when the code compiles. You are done when:**

- All four step audit loops close at `0 CRITICAL + 0 HIGH + 0 MEDIUM` per lane.
- All 21 ACs in the §2.4 matrix verified in CI on the merged tip of `main`.
- Pearl deploy serves `/v1/stats/health` returning `{"status": "ok"}` with a `generated_at` within the §9.5 SLA, and the `components` map has exactly 7 keys (`overview`, `timeseries_rpm`, `timeseries_tpm`, four `leaderboard_*` per v0.1.7 M1).
- A partner key issued via CLI unlocks the partner projection on `/v1/stats/leaderboard`, with `Access-Control-Allow-Origin` echoing the partner's Origin (NEVER `*`) and `Access-Control-Allow-Credentials: true` per v0.1.7 H1.
- A bucketed provider's `exact_earnings` field appears as JSON `null` in the public projection (SINGLE field per v0.1.7 D-M1; the per-axis fields no longer exist).
- An `exact`-mode provider's row appears with the exact `$` value in `exact_earnings`.
- The public response carries `meta.rewards_populated: false` while `provider_rewards_ledger` is empty, and switches to `true` for windows that overlap with seeded ledger rows.
- The public response carries no `totals.earnings_*` keys (v0.1.7 H3) and the partner-key response carries all three.
- A 61st request from a single IP returns 429 with `Retry-After` per AC-8 (nginx tier) once the §5.6/AC-8 SPEC reconciliation has landed (Step 4.B is blocked on that — see Path R1/R2 under 4.B).
- The CI assertion AC-20 finds zero `new_mode = 'exact' AND actor_kind = 'operator'` rows.
- The redaction sweep finds zero raw-token / `token_hash` / random-portion-substring occurrences across journalctl, nginx logs, structured logs, metric labels, response bodies.
- The §6.6.2 launch-sequencing gate is discharged before the first production partner-key issuance.
- The three SPEC-014 follow-up items (portal toggle UI, operator-portal canonical UI, etc.) are documented in OPS.md as non-blocking follow-ups, not as cutover gates.

**SPEC-017 v0.1.7 IMPL is a public partner-facing contract.** Treat the audit-loop discipline as load-bearing, not ceremonial.
