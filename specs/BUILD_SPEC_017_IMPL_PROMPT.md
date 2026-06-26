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

- **SPEC:** [`specs/SPEC-017-network-stats-api.md`](SPEC-017-network-stats-api.md) at **v0.1.8** (LOCKED on commit `62468cb` on the v0.1 LOCK branch; codex round-10 declared READY TO LOCK at 0/0/0 on the IMPL-prompt-audit-driven SPEC fix pass on top of the prior v0.1.7 LOCK). v0.1.8 added **Shape C** to §9.4 (single-transaction DELETE+INSERT executable under the locked §7.2.2 grant set; the only v0.1 default), reconciled §5.6 with AC-8 (dropped burst from both tiers; added Authorization-aware nginx keying; added auth-failure tier limiter), removed `partner_keys.rate_limit_burst` from §5.4.1 and `--burst` from the CLI, and added AC-22 verifying the auth-failure tier. Re-read every "MUST / MUST NOT / SHOULD" in the SPEC before you write the corresponding IMPL code. Every section heading referenced below (`§5.1`, `§7.2.2`, `§9.1`, etc.) points at the merged SPEC.
- **v0.1.8 deltas vs v0.1.7 (binding for this prompt):**
  - §9.4 now lists **three** rebuild shapes — Shape A (TRUNCATE swap), Shape B (atomic rename), and **Shape C (single-tx DELETE + INSERT)**. Shape C is the only one executable under the locked §7.2.2 grant set; the v0.1 IMPL MUST use Shape C unless the operator widens grants for A/B at deploy time.
  - §5.6 dropped the `burst` column from the table view at v0.1.8. Public tier is a hard 60 req/min per IP per endpoint; partner tier a hard 600 req/min per key per endpoint; no LONG-TERM burst absorption. Erratum 2026-06-26: the nginx production directive is `limit_req zone=<name> burst=59 nodelay;` — burst=59 is the SHORT-TERM bucket capacity nginx requires to admit AC-8's named 60-request burst before the 61st returns 429. Sustained throughput stays at 60/min via the unchanged `rate=60r/m` refill. See SPEC §5.6 erratum + this prompt §4.B for the full reconciliation. Step 4.B is no longer hard-blocked.
  - §5.6 added **Authorization-aware nginx keying** — the public-tier `limit_req_zone` MUST NOT throttle Authorization-bearing requests at the edge. Use either an `nginx map` (public RL key empty when Authorization is present) OR a split location block.
  - §5.6 added the **auth-failure tier**: an in-process per-IP+endpoint bucket running BEFORE the §5.4.3 hash+SELECT, floor 300 req/min per IP, that catches floods of invalid/revoked/rejected-origin Authorization-bearing requests on the direct-to-coordinator path. AC-22 verifies.
  - §5.4.1 removed the `rate_limit_burst INT` column; §5.4.2 removed the `--burst` CLI flag. The v0.1.8 hard-limit model has no per-key burst.
  - §10 added **AC-22** for the auth-failure tier.
- **v0.1.7 deltas vs v0.1.6 (historical context; superseded where v0.1.8 says otherwise — v11 ARCH r10 M1 fix):** the Claude fix pass that produced v0.1.7 changed the contract in the ways listed below; v0.1.8 then layered the Shape C / burst / auth-failure / nginx-keying clarifications on top. Where the bullets below name a §9.4 Shape A/B option, treat that as superseded by Shape C per v0.1.8 §9.4 and the deltas list above. The other v0.1.7 deltas (Vary, ACAO, RFC 6454 normalization, etc.) remain in force as written:
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
- **Per-round SPEC audit detail:** [`specs/SPEC-017-r1-audit.md`](SPEC-017-r1-audit.md) through [`specs/SPEC-017-r10-audit.md`](SPEC-017-r10-audit.md). Skim these for the *why* behind individual SPEC requirements — many normative paragraphs close a specific audit finding (e.g. round-2 C1 the partner-key 47-char format, round-2 C2 the deferred rewards-source semantics, round-4 M2 the implementation-authored OLTP source grants, round-6 M1 the BIGSERIAL backing-sequence grants, round-8 Claude H1–H5 + M1–M7 + designer D-H1/H2/M1, round-9 IMPL-audit-driven §9.4 Shape C + §5.6 burst drop + §5.6 auth-failure tier, round-10 lock).
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
- **`partial_history_since` and `backfill_mode` — coordinator config, NOT a DB table (v11 ARCH r10 C1 fix; supersedes v10 ARCH r9 H1's `stats_rollup_state` table proposal):** the v10 prompt pinned a new `stats_rollup_state` table in Step 1, but that table is not declared in locked SPEC §9.1 and granting `stats_reader` SELECT on it would widen the locked §7.2 role inventory in the IMPL prompt — which the controlling-contract semantics in §0 forbid. The cross-step seam for `partial_history_since` is closed via coordinator config instead:
  - `stats.rollup.backfill_mode = "partial" | "full"` (default `"partial"`, per §9.7 Path A default).
  - `stats.rollup.partial_history_since = "<RFC 3339 timestamp>"` — the rollup-start date when `backfill_mode = "partial"`; UNSET when `backfill_mode = "full"`. Operator sets at cutover; both values are read-once at coordinator startup and made available to both the rollup package (Step 2) and the handler package (Step 3) via a shared in-process `*config.Stats` struct passed through `cmd/coordinator/main.go`.
  - **Step 2 (rollup):** consults `Config.Stats.Rollup.BackfillMode` to decide Path A vs Path B and `Config.Stats.Rollup.PartialHistorySince` to determine the rollup-start boundary; does NOT write to any new table.
  - **Step 3 (handler):** consults `Config.Stats.Rollup.PartialHistorySince` to decide whether to emit the `partial_history_since` JSON field per §5.2 / §9.7 (present iff non-empty AND the requested window is `30d` or `all` AND `now() - <partial_history_since>` is less than the window length). No DB grant needed; the handler reads config from `Context`/struct injection.
  - **Operator action at cutover (documented in OPS.md Step 4.C):** if Path A is selected, the operator sets both config values to the rollup-start timestamp. If Path B is selected, the operator leaves `partial_history_since` unset / empty. Changing modes after cutover requires a config edit + coordinator restart; v0.1 does NOT support a hot-swap.
  No new table is created in Step 1; no new grants are added to §7.2; the locked DB role inventory is preserved.
- [§6.1] `provider_visibility` (PK `provider_id`, DEFAULT `'bucketed'`, **plus the v0.1.7 `blocked_from_partner_projection BOOLEAN NOT NULL DEFAULT FALSE` column stub**). The v0.1 rollup does NOT consume `blocked_from_partner_projection` (§6.1 semantics + §11 Q11). The column MUST be created at schema-create time and the migration MUST include a test that the column exists with the correct default. The handler MUST NOT branch on it in v0.1.
- [§6.5] `provider_visibility_audit` (BIGSERIAL `id`).
- [§5.4.1] `partner_keys` (BIGSERIAL `id`, hashed `token_hash`, **`created_by TEXT NOT NULL`** explicitly — the CLI MUST populate this from the operator principal, see Step 4 CLI flags). All columns per §5.4.1 verbatim.

**Postgres role inventory per §7.2 (enumerate each — do NOT use `stats_*` shorthand, since shorthand sweeps in rollup-internal tables):**

- `stats_reader` (§7.2.1) — request-path role.
  - SELECT on EXACTLY: `stats_overview_current`, `stats_timeseries_rpm_30m`, `stats_timeseries_tpm_30m`, `stats_leaderboard_24h`, `stats_leaderboard_7d`, `stats_leaderboard_30d`, `stats_leaderboard_all`, `stats_components_health`, `provider_visibility`, `partner_keys`, **PLUS the v0.1.7 `rewards_populated` storage** (e.g. `stats_rewards_populated` if you used the lookup-table shape; if you denormalized into `stats_components_health`, no extra grant needed — the handler still reads via the existing `stats_components_health` grant). v11 ARCH r10 C1: `partial_history_since` is NOT a DB-grant seam; it lives in coordinator config (read-once at startup), so no table appears in this SELECT list for it.
  - Explicit deny: `stats_late_events` (rollup-internal per §9.1, §9.3), `provider_rewards_ledger` (rollup-internal per §9.1a), `provider_visibility_audit` (write-only at request time), and any OLTP billing/session/pool table.
- `stats_rollup` (§7.2.2) — rollup job role.
  - SELECT, INSERT, UPDATE, DELETE on EXACTLY: `stats_overview_current`, `stats_timeseries_rpm_30m`, `stats_timeseries_tpm_30m`, `stats_leaderboard_24h`, `stats_leaderboard_7d`, `stats_leaderboard_30d`, `stats_leaderboard_all`, `stats_components_health`, `stats_late_events`, **PLUS write privileges (SELECT, INSERT, UPDATE, DELETE) on the v0.1.7 `rewards_populated` storage if you chose the lookup-table shape** — the rollup is the writer of this signal. v11 ARCH r10 C1: `partial_history_since` is config, not a table; no grant change here either.
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

**Nightly rebuild atomicity (v0.1.8 §9.4) — pin this:** the nightly rebuild of `stats_leaderboard_all` (and `stats_leaderboard_30d`) MUST execute in a single PostgreSQL transaction so the leaderboard never serves a half-rebuilt state. SPEC v0.1.8 §9.4 lists three shapes — Shape A (temp-table swap with `TRUNCATE`), Shape B (atomic rename), and **Shape C (single-tx DELETE + INSERT)**. **Shape C is the only one executable under the locked §7.2.2 `stats_rollup` grant set (SELECT/INSERT/UPDATE/DELETE only); Shapes A/B require `TRUNCATE`/`ALTER`/`DROP` privileges that the locked grants do NOT include.** v0.1 IMPL MUST use Shape C unless the operator widens grants at deploy time:

- **Shape C (v0.1 default per SPEC v0.1.8 §9.4):**
  ```sql
  BEGIN ISOLATION LEVEL READ COMMITTED;
  DELETE FROM stats_leaderboard_all;
  INSERT INTO stats_leaderboard_all (provider_id, pseudonym, generated_at,
    rank_earnings, rank_tokens, rank_jobs, earnings_usd, earnings_work_usd,
    earnings_rewards_usd, earnings_bucket, tokens, jobs, first_seen_at,
    last_seen_at)
  SELECT ... FROM ... ; -- the rebuilt source query
  COMMIT;
  ```
  Atomicity guarantee (from SPEC §9.4): PostgreSQL MVCC means concurrent `stats_reader` SELECTs see the pre-DELETE snapshot until the transaction commits, then see the post-INSERT snapshot. There is no window where the handler observes an empty leaderboard. A failed transaction MUST roll back, leaving the pre-rebuild state intact.

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
- Integration (both backfill modes, config-driven — handler-response assertion is Step 3): set `stats.rollup.backfill_mode = "partial"` AND `stats.rollup.partial_history_since = "2026-04-12T00:00:00Z"` in coordinator config; restart coordinator; assert the rollup package's `Config.Stats.Rollup.PartialHistorySince` equals the config value AND backfill behavior follows Path A. Then set `backfill_mode = "full"` AND unset `partial_history_since`; restart; assert Path B behavior. (v11 ARCH r10 C1 — config-driven, NOT a new DB table.) Step 3 will own the test that `/v1/stats/leaderboard?window=30d` JSON exposes or omits the field based on the same shared in-process `*config.Stats` struct.
- Integration (v0.1.8 — Shape C rebuild atomicity per §9.4): Shape C is the v0.1 default per SPEC §9.4. Three sub-assertions, each Shape-C-specific (no Shape A/B artifacts like `_old` tables or temp tables exist under Shape C):
  1. **Failed-rebuild rollback:** seed `stats_leaderboard_all` with a known row set R0. Begin a Shape C rebuild that intentionally raises a SQL error after the DELETE but before the COMMIT (e.g. INSERT a row that violates a CHECK constraint, then catch). Assert `SELECT * FROM stats_leaderboard_all` STILL equals R0 — the transaction rolled back without disturbing the running snapshot.
  2. **Successful-rebuild no-empty-state (the MVCC invariant Shape C exists to satisfy):** start a second `stats_reader` connection that polls `SELECT count(*) FROM stats_leaderboard_all` every 10ms. In parallel, run a successful Shape C rebuild that swaps R0 for R1. Assert EVERY observation by the reader is either `count(R0)` or `count(R1)`, NEVER 0 and NEVER a mixed partial count. This proves PostgreSQL MVCC delivers the §9.4 atomicity guarantee under Shape C.
  3. **Post-commit equivalence:** after the successful rebuild commits, assert `SELECT * FROM stats_leaderboard_all` equals R1 exactly (the rebuilt source query).
  Shape A and Shape B specific assertions (temp-table dropped, `_old` table removed) MUST NOT appear in the v0.1 test corpus — those shapes are unreachable under the locked §7.2.2 grants and require operator-side grant widening to deploy.
- Integration (v0.1.7 — `stats_late_events` retention per §9.3): seed `stats_late_events` rows with `recorded_at = now() - INTERVAL '100 days'` AND `recorded_at = now() - INTERVAL '30 days'`. Run the nightly job. Assert the 100-day-old row is DELETED; the 30-day-old row is preserved. Set `stats.rollup.late_events_retention_days = 15` and assert the IMPL refuses to start (or clamps + logs — match the pinned behavior).
- Integration (v0.1.7 — `rewards_populated` computation per §9.1a + §5.2): with empty `provider_rewards_ledger`, run a rollup tick and assert the persisted `rewards_populated` value for each of `{24h, 7d, 30d, all}` is `false`. Insert one `provider_rewards_ledger` row with `unix_ts` inside the 7d window; re-run the tick; assert `rewards_populated[7d] = true` AND `rewards_populated[24h] = false` (assuming the inserted unix_ts is older than 24h ago).
- Integration (ARCH r7 H2 — Step 2 OWNS rollup `provider_visibility` left-join + bucket computation, NOT just Step 1 fixture + Step 3 projection): the rollup MUST left-join `provider_visibility` when producing `stats_leaderboard_*` rows. Absence of a row defaults to `mode = 'bucketed'` AND `blocked_from_partner_projection = FALSE` (per §6.1). The rollup MUST compute `earnings_bucket` from the stored `NUMERIC(18,2)` total per §6.2 boundary semantics. Test fixtures MUST include:
  - A provider with NO `provider_visibility` row → `stats_leaderboard_24h.earnings_bucket` computed against thresholds; rollup produces the row.
  - A provider with `provider_visibility.mode = 'exact'` → row populated (Step 3 then exposes `exact_earnings` per §5.2).
  - A provider with `provider_visibility.mode = 'bucketed'` explicitly → row populated (Step 3 then exposes `exact_earnings: null` in public projection).
  - Bucket-boundary fixtures: provider with `earnings_usd = 4.99` → `earnings_bucket = '$'`; `5.00` → `'$$'`; `49.99` → `'$$'`; `50.00` → `'$$$'` (against the 24h window thresholds). These prove the §6.2 `[a, b)` boundary semantics are encoded in the rollup, NOT only the handler.
  Keep Step 3 as projection / redaction verification on seeded `stats_leaderboard_*` rows; Step 2 is the first place these defaulting and bucket-computation semantics are proven.

**Step 2 audit prompt authoring**: three lanes.

### Step 3 — HTTP handlers + error envelope + CORS + auth + redaction

**Package location:** `phase4-coordinator/internal/stats/` (flat — handlers, mux wiring, recover middleware all live here per the existing `internal/explorer/` pattern). Subpackage `phase4-coordinator/internal/stats/store/` houses the DAO that the handlers call. Uses `stats_reader` `*sql.DB`.

**Handlers (mount under `/v1/stats/*` per §7.1, exposed on BOTH `coordinator.streamvc.live/v1/stats/*` and `stats.streamvc.live/v1/stats/*` via the same binary):**

- `GET /v1/stats/overview` — §5.1 JSON shape, 14 `network.*` fields, 30-point timeseries with `null` (NOT zero) for missing minutes (§5.1 field rules). **v0.1.7 reminder:** the `_total` fields are CUMULATIVE all-time counters (per §9.2).
- `GET /v1/stats/leaderboard` — §5.2 wire shape. **v0.1.7 binding deltas vs v0.1.6:**
  - Public projection `totals` object carries ONLY `tokens`, `jobs`, `active_accounts`. The handler MUST NOT emit `totals.earnings_usd`, `totals.earnings_work_usd`, or `totals.earnings_rewards_usd` on the public projection. AC-6 negatively asserts this.
  - Public projection rows carry ONE bucket field (`earnings_bucket`) and ONE exact field (`exact_earnings`). Do NOT emit `earnings_work_bucket`, `earnings_rewards_bucket`, `exact_earnings_work`, or `exact_earnings_rewards` on the public projection (the storage no longer carries the per-axis buckets either).
  - Every response MUST include `meta.rewards_populated` (REQUIRED boolean, sourced from the v0.1.7 `rewards_populated` storage written by Step 2).
  - Responses to `?window=30d` AND `?window=all` MUST include the top-level `partial_history_since` RFC 3339 timestamp when `Config.Stats.Rollup.PartialHistorySince` (per coordinator config, v11 ARCH r10 C1 — NOT a DB table) is non-empty AND `now() - <partial_history_since>` is less than the requested window's length. Omit the field entirely when the config value is empty (Path B) OR when the rollup has fully overlapped its window (per §9.7). Responses to `?window=24h` AND `?window=7d` MUST NEVER include the field.
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

The handler MUST enforce this split — using `ACAO: *` on any partner-key projection response (rows 3, 4, and 5 of the locked v0.1.8 §5.7 table — empty-allowlist browser context, empty-allowlist server-to-server, and non-empty-allowlist matched Origin) is a CRITICAL bug. The public `/leaderboard` no-key response (row 2) MUST still emit `ACAO: *` per locked §5.7 — do NOT apply the partner-key `ACAO != *` rule to it. (v13 CODE r12 001 fix: the v12 prompt incorrectly named "rows 2/3/4" which would have implementers reject `ACAO: *` on the legitimate public row 2.) The SECURITY audit lane MUST sweep for this with a fixture that drives all 7 §5.7 rows.

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

**`X-Stats-Generated-At` header on every non-304 `/v1/stats/*` response** per §5.1 / §5.2 / §5.3 (CODE r8 M2 fix). 304 Not Modified is exempt per locked §5.9 — a 304 carries ONLY the RFC 7232 headers `ETag`, `Cache-Control`, and `Vary` with an empty body. Do NOT emit `X-Stats-Generated-At` on 304 responses. The Step 3 test list narrows the blanket assertion to non-304 responses; the AC-12 round-trip test asserts the absence of `X-Stats-Generated-At` on the 304 response specifically.

**Middleware stack (pinned — exactly this order, outermost to innermost):**

The recover-vs-redaction ordering issue is resolved by pinning a single stack and giving the recover middleware its own first-line `Authorization` strip. The v0.1.7 SECURITY r4 H1 added the **pre-auth coarse limiter** between access-logging and the auth dispatcher so invalid/revoked/rejected-origin probes hitting a nginx-bypassed direct-to-coordinator surface cannot drive unbounded `sha256 + SELECT by token_hash` work. The chain MUST be:

1. **Redaction-context middleware (outermost):** runs first on the inbound request. Reads `Authorization`, replaces the header value with `REDACTED` in the request's logging context (`r.Header.Set` or a request-clone pattern), and stores the parsed bearer token in `r.Context()` under an unexported typed key — e.g. `type authKey struct{}` + `r = r.WithContext(context.WithValue(r.Context(), authKey{}, parsedToken))`. The auth dispatcher (step 5 below) retrieves the token via `r.Context().Value(authKey{})`. NO goroutine-local storage, NO package globals, NO `sync.Map` keyed by goroutine ID — those patterns are non-idiomatic Go and unsafe under concurrent serving. The unexported typed key prevents accidental cross-package retrieval. Every downstream log/trace/metric emitter reads ONLY the redacted header context; the raw token in `r.Context()` is consumed by the auth dispatcher and discarded after the SELECT.
2. **Recover middleware:** wraps the entire `/v1/stats/*` subtree (all methods including GET, HEAD, OPTIONS, and the 405 path for other verbs). On panic: log `event=stats_handler_panic` (structured) using the REDACTED context — so `Authorization` is already `REDACTED`, no raw token, no `token_hash`, no raw SQL, no stack in the public log line. Stack MAY go to a debug-only sink. The recover middleware MUST ALSO perform its own first-line `Authorization` strip as defense-in-depth (in case the redaction context is bypassed for any reason); this is the SECURITY guarantee.
3. **Access-logging / tracing middleware:** reads only the redacted context.
4. **Auth-failure tier limiter (v0.1.8 SPEC §5.6 auth-failure tier + SECURITY r5 H1 trusted-proxy fix + ARCH r8 C1 / CODE r9 H1 scoping fix) — per-IP, NOT keyed on partner_keys.id, SCOPED to Authorization-present requests only:** runs BEFORE the auth dispatcher. **The limiter MUST NOT debit absent-Authorization requests** — anonymous traffic is governed by the public tier (60 req/min per IP, nginx primary + in-process fallback), not the auth-failure 300 rpm bucket. **The limiter MUST NOT cap valid partner-key traffic** — successful 200 partner projection requests are governed by the in-process per-`partner_keys.id` 600 rpm bucket (per §5.6 partner tier), not the auth-failure bucket. The locked §5.6 v0.1.8 auth-failure tier is scoped exclusively to "Authorization-present requests that produce 401 per §5.4.3 rows 3/5/6/7."
   - **Reserve-then-refund pattern (pinned implementation shape):** because the handler does not know whether an Authorization-bearing request will produce 200 or 401 until after the `sha256 + SELECT`, the implementation reserves a slot in the auth-failure bucket BEFORE the hash+SELECT (so AC-22 is provable), then REFUNDS the slot if the auth dispatcher returns 200 (so valid partner keys are not double-counted against both the failed-bearer bucket and the partner tier). The 300 rpm cap thus tracks only the 401-producing fraction of Authorization-bearing traffic.
   - **Absent Authorization is skipped entirely** — the middleware checks `r.Header.Get("Authorization") == ""` and short-circuits to the next middleware without touching the auth-failure bucket. Anonymous flooding is the public tier's job (nginx primary, in-process fallback in middleware step 6 below).
   - **Client-IP derivation MUST use a trusted-proxy allowlist:**
     - If the immediate peer (`r.RemoteAddr`) is in the operator-configured trusted-proxy allowlist (e.g. `["127.0.0.1/32", "10.0.0.0/8"]` for nginx running on localhost or in a private network), parse the first `X-Forwarded-For` hop AFTER the trusted proxy as the client IP.
     - Otherwise (direct-to-coordinator, no trusted proxy in front), use `r.RemoteAddr` directly. The implementation MUST NOT trust `X-Forwarded-For` from an untrusted immediate peer.
   Per SPEC §5.6 v0.1.8 auth-failure tier, the floor is 300 req/min per IP per endpoint (5× the public floor). On exceed: return 429 with §5.9 `rate_limited` envelope BEFORE the auth dispatcher runs ANY `sha256 + SELECT` work. AC-22 verifies. AC-18 timing samples MUST be taken below this threshold so timing equivalence is measured on non-limited 401s.
5. **Auth dispatcher:** reads the bearer token from `r.Context().Value(authKey{})` (set in step 1), hashes via `sha256(token_utf8_bytes)`, performs SELECT against `partner_keys`, enforces §5.4.3 7-row decision table.
6. **Post-auth success rate-limit middleware (per-tier, per-endpoint):** keys on the **(tier subject, endpoint)** tuple per SPEC §5.6 ("60 req/min per IP per endpoint" / "600 req/min per key per endpoint"). The endpoint identifier is the route token (e.g. `"overview"`, `"leaderboard"`, `"health"`). v12 CODE r11 002 fix: the v11 prompt said "client IP or `partner_keys.id`" without the endpoint dimension — that would have let 60 `/overview` requests exhaust quota for `/leaderboard` on the same IP. Concrete keys:
   - **Public tier success bucket:** key = `(client_ip, endpoint)`, limit = 60 req/min (per §5.6, defense-in-depth when nginx is bypassed).
   - **Partner tier:** key = `(partner_keys.id, endpoint)`, limit = `partner_keys.rate_limit_rpm` (default 600). Per §5.6 + §5.4.7.
   Tracks successful 2xx accounting only; stale-503 responses MUST NOT debit this bucket (so a rollup outage does not exhaust quotas for healthy clients). The auth-failure bucket above is also `(client_ip, endpoint)`-keyed for the same reason. A Step 3 test MUST prove: 50 `/v1/stats/overview` requests + 50 `/v1/stats/leaderboard` requests from the same IP both succeed (separate per-endpoint buckets, neither hits 60); 61 of either kind on its own returns 429.
7. **Handler:** computes JSON, returns response. Recover MUST be set on `500 internal` with §5.9 envelope on panic.

**Tests for the auth-failure tier (v0.1.8 AC-22 + SECURITY r5 H1 + ARCH r8 C1 / CODE r9 H1):**

- Direct-to-coordinator (nginx bypassed) flood test from a single socket: send 350 `/v1/stats/leaderboard` requests in 60s with `Authorization: Bearer mpk_invalid_<random>`. Assert: the 301st request returns 429 with §5.9 envelope BEFORE the auth dispatcher runs a SELECT (verify via SQL query counter — the `partner_keys` SELECT count for the test client IP MUST be ≤300 even though 350 requests were sent).
- **Scoping test — absent Authorization is NOT debited (v0.1.8 ARCH r8 C1):** from one client IP, send 350 `/v1/stats/leaderboard` requests with NO `Authorization` header. Assert: ALL 350 reach the public-tier limiter (60 rpm) and produce normal public 200 or 429 from the public tier; the auth-failure bucket counter for the test IP is 0. This proves absent-Authorization traffic is governed by the public tier alone.
- **Scoping test — valid partner key is NOT capped at 300 rpm (v0.1.8 ARCH r8 C1):** seed a valid partner key with `rate_limit_rpm = 600`. From one client IP, send 500 `/v1/stats/leaderboard` requests in 60s with `Authorization: Bearer <valid_token>`. Assert: ALL 500 succeed at 200 partner projection (the partner tier's 600 rpm is the only cap; the auth-failure 300 rpm bucket reserved-then-refunded the slot on each 200 — final auth-failure counter for the test IP is 0 after the test). This proves valid keys are not double-counted. (Note: the partner tier itself only fires 429 at the 601st request, not the 501st — the v9 prompt had the wrong number; v10 ARCH r9 M1 corrected.)
- **Spoofed `X-Forwarded-For` test (SECURITY r5 H1):** from the same single socket, rotate `X-Forwarded-For` header across 350 distinct synthetic IPs. Assert: with the trusted-proxy allowlist EMPTY (direct-to-coordinator), the 301st request STILL returns 429 — the limiter ignores the spoofed header and keys on `r.RemoteAddr`. With the trusted-proxy allowlist INCLUDING `127.0.0.1/32` AND the connection actually coming through localhost nginx, the rotated `X-Forwarded-For` values produce distinct per-IP buckets and the test rate stays below the limit per IP. This proves both: untrusted XFF is ignored, trusted XFF is parsed.
- Nginx-surface real-IP test: real proxied requests through nginx (with `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for`) group by the actual client IP correctly.
- AC-18 statistical test (rows 5/6/7) MUST run at a request rate below the auth-failure threshold (i.e. ≤270 req/min sustained) so timing samples are not coupled to 429 responses. Pin the rate explicitly in the test setup.

Returns `500 internal` with the §5.9 envelope and `Content-Type: application/json; charset=utf-8`. AC-11 verifies via an injected panic in a test handler that `/healthz` (the coordinator's own liveness endpoint) survives.

**Redaction invariants (apply across the whole stack, AC-15 + SECURITY H1):**

- Forbid raw token, `token_hash`, and any substring of the random 43-char token portion from appearing anywhere: structured logs, nginx access logs (via nginx config in Step 4), Prometheus/metric labels, trace spans, response bodies, error messages.
- **Log allowance (different from metric allowance):** logs MAY reference `partner_keys.id` (integer), `partner_keys.label`, and the 8-char `prefix` (the prefix is permitted in logs for human correlation per SPEC §5.4.6).
- **Metric allowance (tighter than log allowance):** metric labels MAY reference `partner_keys.id` (integer) and bounded enums (e.g. `tier ∈ {"public","partner"}`). Metric labels MUST NOT include `prefix`, `partner_keys.label` (operator text), `token_hash`, raw token, any random-substring, Origin string, or untrusted user input. See SECURITY M5 + ARCH H3 / CODE-R2-007 for why metrics is tighter than logs (metric cardinality + external observability retention).

**Rate limiting per §5.6 (v0.1.8 three-tier model):**

- **Public tier (no Authorization)** — nginx `limit_req_zone` is PRIMARY (configured in Step 4.B), in-process bucket is FALLBACK. Hard 60 req/min **per (IP, endpoint)** tuple; no LONG-TERM burst absorption (short-term `burst=59 nodelay` bucket is mechanically required at the nginx layer for AC-8's "60 succeed; 61st 429s" contract — see §5.6 v0.1.8 erratum + Step 4.B nginx directive). Per SPEC §5.6, the endpoint dimension is mandatory.
- **Partner tier (valid Authorization → 200 partner projection)** — in-process bucket keyed on **(partner_keys.id, endpoint)** (NOT raw token, NOT prefix). Hard limit per `partner_keys.rate_limit_rpm` (default 600). v0.1.8 removed the `rate_limit_burst` column; IMPL MUST clamp to `rate_limit_rpm` per-row, no burst.
- **Auth-failure tier (Authorization present → 401 per §5.4.3 rows 3/5/6/7)** — in-process bucket pre-auth (see middleware stack step 4 above), keyed on **(IP, endpoint)** with trusted-proxy-allowlist client-IP derivation. Floor 300 req/min. Runs BEFORE `sha256+SELECT` so invalid-bearer floods cannot drive unbounded DB lookups. AC-22 verifies.
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
- **`X-Stats-Generated-At`** present on every NON-304 `/v1/stats/*` response (CODE r8 M2 — 304 path per §5.9 carries only RFC 7232 headers). A separate AC-12 sub-assertion verifies the 304 response does NOT carry `X-Stats-Generated-At`.
- **§5.4.3 7-row decision-table test** — one fixture per row, including the absent-Origin case (row 3).
- **CORS sibling-subdomain reject test** — `Origin: https://evil.streamvc.live` rejected; `Origin: https://portal.streamvc.live` accepted only if EXACTLY in allowlist.
- **CORS partner-key projection NEVER `ACAO: *` test (v0.1.7 H1)** — drive all 7 §5.7 rows; assert that for partner-key projection rows (rows 3, 4, 5 in v0.1.7), the response `Access-Control-Allow-Origin` is either the echoed normalized Origin (when set) OR omitted entirely (server-to-server context), NEVER `*`. Also assert `Allow-Credentials: true` is paired with the echoed-Origin case and omitted in the server-to-server case.
- **RFC 6454 Origin normalization test (v0.1.7 M4)** — seed `partner_keys.allowed_origins = ARRAY['https://acme.example']` (non-empty allowlist; the key is active, not revoked). Send requests with `Origin: HTTPS://Acme.Example`, `https://acme.example:443`, `https://acme.example/`, `https://acme.example?foo=bar`. Assert:
  - First two (case-insensitive scheme/host + default-port stripped) → 200 partner projection (row 4 of §5.4.3 — exact allowlist match after normalization).
  - Third and fourth (trailing slash, query string) → MALFORMED Origin → treated as ABSENT Origin → with non-empty allowlist the locked §5.4.3 branch is **row 3**: `401 unauthorized` AFTER the same `sha256 + SELECT by token_hash` work as rows 5/6/7 (timing equivalence with row 3 is implied but AC-18 only requires equivalence across rows 5/6/7 — the test MUST still observe that row 3's latency falls within the same ±20% band as rows 5/6/7 since they share the hash+SELECT path).
  - Separate empty-allowlist fixture: seed a different key with `allowed_origins = '{}'`; send `Origin: https://acme.example/` (malformed) — treated as absent — with empty allowlist this is row 2 of §5.4.3 → 200 partner projection (no Origin restriction). Pin this distinction so the implementer doesn't conflate "allowlist enforces Origin requirement" with "malformed Origin always rejects."
- **503 stale not debited from rate-limit bucket** — issue 100 stale requests, then 60 fresh; assert all 60 fresh succeed.
- **`partial_history_since` exposure (v0.1.7 H4)** — set `stats.rollup.partial_history_since = <timestamp>` AND `stats.rollup.backfill_mode = "partial"` in coordinator config (Path A fixture per v11 ARCH r10 C1); restart coordinator (or inject the config via the test harness's `*config.Stats` wiring); call `GET /v1/stats/leaderboard?window=30d` AND `?window=all`; assert response includes top-level `partial_history_since` matching the configured value (both windows). Call `?window=24h` AND `?window=7d`; assert the field is OMITTED on both (per §9.7). Set `partial_history_since` empty AND `backfill_mode = "full"` (Path B fixture); restart/re-inject; call `?window=30d`; assert the field is OMITTED. All fixtures share the same `*config.Stats` struct injection pattern.
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
- **v0.1.8 removed `--burst`** — the `rate_limit_burst` column no longer exists in `partner_keys` (v0.1.8 hard-limit model has no per-key burst). The CLI MUST NOT accept the `--burst` flag; the test suite includes a negative assertion that the bare flag produces a clear error.
- `--created-by <text>` (OPTIONAL — if omitted, defaults to a non-empty operator principal: `$USER@$(hostname)` from environment, or `"unknown@<hostname>"` if `$USER` is unset; populates the `created_by TEXT NOT NULL` column per §5.4.1). The default MUST be non-empty so the locked SPEC AC-17 command `coordinator partner-keys issue --label X` (NO `--created-by` flag) still passes argument validation, generates a token, and INSERTs a row with non-empty `created_by`. CI tests run BOTH the bare AC-17 command AND the explicit `--created-by ops@example.com` variant.
- `--rotate-from <existing_id>` (optional) — see rotation flow below.

Issuance flow:

1. Generate 32 cryptographically random bytes via the system CSPRNG.
2. Encode unpadded base64url (RFC 4648 §5, no `=` padding) → 43-character body.
3. Prefix with `mpk_` → 47-character raw token (length math: `mpk_` is 4 chars + 43 base64url chars = 47).
4. Compute `token_hash = sha256(raw_token_utf8_bytes)`.
5. INSERT into `partner_keys` with: `token_hash`, `token_hash_alg = 'sha256'`, `prefix = <first 8 chars of raw token>` (always begins `mpk_`), `label`, `allowed_origins`, `rate_limit_rpm`, `created_by`, `rotated_from_id` (if `--rotate-from` was passed, else NULL). v0.1.8 removed `rate_limit_burst` from the column list per SPEC §5.4.1.
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

- `limit_req_zone` declaration per endpoint at the `http` block (defines the zone). v0.1.8 SPEC §5.6 erratum (2026-06-26): the public-tier zone declaration MUST use `rate=60r/m` and the location block MUST use `limit_req zone=<name> burst=59 nodelay;`. The `burst=59` short-term bucket capacity (1 in-rate token + 59 burst = 60 immediate) is mechanically required for AC-8's "60 succeed; 61st 429s" contract — the earlier "no `burst=` parameter" text was incorrect on nginx semantics (default burst=0 admits at most 1 immediate, failing the AC). Sustained throughput remains 60/min because `rate=60r/m` refill is unchanged. See SPEC §5.6 v0.1.8 erratum for the full reconciliation.
- `limit_req_status 429;` per endpoint location.

**v0.1.8 — Authorization-aware nginx keying (binding, per SPEC §5.6).** The public-tier `limit_req_zone` MUST NOT throttle Authorization-bearing requests at the edge. The IMPL author picks one of these two shapes:

- **Shape (a) — map-based bypass, with per-endpoint zones (v12 CODE r11 002 fix):**
  ```nginx
  map $http_authorization $public_rl_key {
      ""      $binary_remote_addr;
      default "";
  }
  # Separate zone per endpoint so /overview, /leaderboard, /health do
  # NOT share a 60-rpm quota per IP. SPEC §5.6 mandates per-endpoint.
  limit_req_zone $public_rl_key zone=stats_overview:10m rate=60r/m;
  limit_req_zone $public_rl_key zone=stats_leaderboard:10m rate=60r/m;
  limit_req_zone $public_rl_key zone=stats_health:10m rate=60r/m;
  ```
  Each endpoint's `location` block references its own zone (e.g. `limit_req zone=stats_overview nodelay;` inside `location /v1/stats/overview`). When `Authorization` is present, the key is empty and the limiter does not count the request. v11 used a single shared `stats_public` zone, which would have let 60 `/overview` requests exhaust quota for `/leaderboard` on the same IP — that's CODE r11 002.
- **Shape (b) — named-location dispatch (mechanically valid alternative; CODE r9 M2 fix replaces the prior `if ($http_authorization)` sketch which would have failed `nginx -t`; v12 CODE r11 002 adds per-endpoint zones):**
  ```nginx
  map $http_authorization $auth_present {
      ""      "0";
      default "1";
  }
  # Per-endpoint zones — same rationale as Shape (a).
  limit_req_zone $binary_remote_addr zone=stats_overview:10m rate=60r/m;
  limit_req_zone $binary_remote_addr zone=stats_leaderboard:10m rate=60r/m;
  limit_req_zone $binary_remote_addr zone=stats_health:10m rate=60r/m;

  location /v1/stats/leaderboard {
      error_page 418 = @keyed_pass_leaderboard;
      if ($auth_present = "1") { return 418; }
      limit_req zone=stats_leaderboard nodelay;
      limit_req_status 429;
      proxy_pass http://coordinator;
  }

  location @keyed_pass_leaderboard {
      # keyed path: NO public limit_req; in-process per-key bucket caps in coordinator
      proxy_pass http://coordinator;
  }
  # Mirror the pattern for /v1/stats/overview and /v1/stats/health with their own zones.
  ```
  The `error_page 418 = @keyed_pass` + `return 418` pattern is nginx's documented mechanism for conditional location dispatch and DOES pass `nginx -t`. The `if` directive is used only with `return`, which is one of the four directives nginx officially supports inside `if`.

The IMPL author picks (a) or (b); **shape (a) is preferred** because it has fewer moving parts. Both pass `nginx -t` and both bypass the public limiter for Authorization-bearing requests. Step 4.B test `nginx -t` MUST pass and the keyed-through-nginx companion test (≥100 valid-keyed requests/min through nginx from one IP, none rejected at the edge) MUST pass.

Either way, valid partner-key traffic flows through nginx un-throttled at the public tier; the partner-tier limit (600 req/min per `partner_keys.id`) is enforced **in-process** per §5.6 partner tier and §5.4.7. The auth-failure tier (300 req/min per IP, in-process, pre-hash-SELECT per SPEC §5.6) catches invalid-bearer floods — see Step 3 middleware stack.

**SECURITY r5 C1 fix — `proxy_no_cache` alongside `proxy_cache_bypass`:** nginx `proxy_cache_bypass` only governs whether the response is **read from** the cache; it does NOT prevent the response from being **saved to** the cache. The partner-key projection carries exact `$` for ALL providers (SPEC §6.6.2) and MUST never be persisted at the edge. The nginx config MUST set BOTH:

```nginx
proxy_cache_bypass $http_authorization;   # do not serve from cache when Authorization is present
proxy_no_cache     $http_authorization;   # do not save to cache when Authorization is present (SECURITY r5 C1)
```

A test MUST assert that after a successful partner-key request through nginx, the cache directory contains NO entry for that URL+Authorization combination (verify via `proxy_cache_path` filesystem inspection or by issuing an anonymous follow-up request and asserting the cache status header shows `MISS`/`BYPASS` rather than `HIT`).

- Strip `Authorization` header from access logs (`log_format` excludes `$http_authorization`, or use `set $authorization "REDACTED"` pattern).
- `proxy_cache_path` for public projections ONLY (per the bypass+no-cache pair above).
- `proxy_set_header X-Forwarded-For` per existing coordinator pattern.
- TLS per existing cert pipeline.

**Cloudflare integration (optional):** rate-limit and bot-management rules at the edge layered above nginx. MUST NOT cache responses with `Cache-Control: private`.

**Tests for 4.B:**

- AC-8 (nginx rate-limit): from a single client IP, issue 60 requests to `/v1/stats/overview` within 60s; assert all succeed. 61st returns 429 with `Retry-After` set, `code: "rate_limited"`. Test against the nginx surface, NOT the in-process fallback.
- nginx config validates (`nginx -t`); the new server-block serves a 200 from `/v1/stats/health`.
- Edge-cache cross-contamination test (v0.1.7-aware): issue keyed request, then anonymous request from same IP within s-maxage; assert keyed response was NOT served to the anonymous request (different body, no exact-$ leak). The protection mechanism in v0.1.7 is `Cache-Control: private` on the partner-key projection — nginx MUST NOT cache it. `Vary: Authorization` ONLY appears on the partner-key projection (v0.1.7 H2: public projection no longer carries `Vary: Authorization` — including it on the public projection would fragment edge cache by every malformed `Authorization` variation without any branch on Authorization in the response).
- Anonymous edge-cache equivalence (v0.1.7 — replacement for the prior `Bearer garbage` cache test): issue TWO anonymous public requests within s-maxage; assert nginx serves the same cached response body to both (proving the public projection caches across truly anonymous requests). Do NOT use `Authorization: Bearer garbage` as the second request — per locked AC-3, ANY present-but-invalid Bearer token MUST return `401 unauthorized` (the `proxy_cache_bypass $http_authorization` directive earlier in this section ensures any request carrying `Authorization` bypasses the public cache and reaches the handler, which then returns 401 per the §5.4.3 decision table). The earlier draft of this test (v7 commit `c45d644`) incorrectly told nginx to serve a cached public 200 to a `Bearer garbage` request — that contradicted AC-3 and the §5.4.3 row-6 hash+SELECT timing-equivalence rule. The v0.1.7 fix-pass commit removed it.
- AC-3 nginx-tier confirmation (v0.1.7): send `GET /v1/stats/leaderboard` with `Authorization: Bearer garbage` through nginx; assert the response status is 401 with `code: "unauthorized"` (the handler reaches the §5.4.3 row-6 branch via the `proxy_cache_bypass $http_authorization` rule — nginx forwards every Authorization-bearing request to the coordinator) AND the response does NOT come from any cached public 200.
- **§5.6 keyed-through-nginx bypass companion test (v0.1.8 ARCH r8 H1):** seed a valid partner key with `rate_limit_rpm = 600`. From a single client IP, issue 100 `/v1/stats/leaderboard` requests through nginx in 60s, each carrying `Authorization: Bearer <valid_token>`. Assert: nginx forwards ALL 100 to the coordinator (none rejected at the edge with `Retry-After`); the responses are 200 partner projection. This proves the Authorization-aware keying (map or split location below) actually bypasses the public 60 rpm limiter for valid keyed traffic. The companion test deliberately stays below the 600 rpm partner-tier cap so the only 429 surface that could fire is the unwanted public-tier double-throttle; if the test sees a public-tier 429, the nginx config is wrong.
- **§5.6 per-endpoint isolation test (v12 CODE r11 002):** from a single client IP with no Authorization, issue 50 `/v1/stats/overview` requests followed by 50 `/v1/stats/leaderboard` requests through nginx in 60s. Assert: ALL 100 succeed at nginx (each endpoint has its own 60-rpm zone per the per-endpoint zone declarations above; the two zones do not share a quota). Then issue a 61st `/v1/stats/overview` request from the same IP within the same 60s; assert 429. Then issue a 51st `/v1/stats/leaderboard` request from the same IP; assert 200 (leaderboard still has 10 tokens left in its own zone). This proves the endpoint dimension is honored in the nginx config.
- **`proxy_no_cache` write-suppression test (SECURITY r5 C1):** issue a partner-key request through nginx; inspect the nginx `proxy_cache_path` directory after the response. Assert NO cache entry exists for the URL+Authorization combination. Then issue an anonymous follow-up request to the same URL within s-maxage; assert the response carries cache status `MISS` or `BYPASS` (NOT `HIT`) — proving no shared cache served partner-projection bytes to an anonymous client.
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

**Public changelog** `docs/network-stats-api/CHANGELOG.md` per §8.5, with v0.1.8 entry citing the PR numbers (one per step) and the SPEC version.

**Partner-key broader-exposure provider disclosure (§6.6.2 — HARD cutover deliverable, v0.1.7-tightened):**

SPEC-017 §6.6.2 requires that providers be disclosed, at onboarding time, that "trusted partners with an operator-issued API key see your exact earnings figures, even when your public mode is `bucketed`." This is part of the privacy posture. **v0.1.7 turned this from a SHOULD into a hard launch-sequencing MUST.** Step 4.C MUST deliver:

1. **Disclosure copy** added to `OPS.md` under a section "Partner-key exact-dollar exposure — provider disclosure obligation," substantially equivalent to the §6.6.2 SPEC text. The operator-runbook copy is the source of truth until SPEC-014 v0.9 lands the in-portal disclosure.
2. **Onboarding-flow tracker** entry in the SPEC-014 v0.9 follow-up issue noting: "Add §6.6.2 disclosure copy to the provider-account-creation flow AND a one-time disclosure to every pre-existing provider on next portal login."
3. **Cutover-runbook gate (v0.1.7 — BLOCKING):** production issuance of partner keys (any `coordinator partner-keys issue` invocation on a production coordinator that produces a key delivered to a real partner) MUST NOT begin until ALL THREE conditions are true on the live Pearl coordinator (per SPEC §6.6.2):
   - (a) SPEC-014 v0.9 has merged AND is deployed to `portal.streamvc.live`.
   - (b) The §6.6.2 disclosure copy is being shown on the provider-account creation page AND on a static portal page that every existing provider is shown on their next portal login.
   - (c) The operator runbook has a recorded sign-off entry naming the SPEC-014 v0.9 commit SHA and the date both disclosure surfaces went live.

   This is a HARD gate, not a recommendation. Operators MAY issue STAGING keys against staging coordinators for AC-1..AC-21 fixture work, partner integration dry-runs, and pre-production smoke BEFORE the SPEC-014 v0.9 surface ships. Staging keys MUST NOT be returnable on a production response. The keys themselves are distinguishable by the operator's record of which environment issued them, NOT by a namespace flag in the token — there is no protocol field for "staging vs production keys" in v0.1.7.

**Step 4.C PR convergence vs production-issuance distinction (v11 ARCH r10 H1):** the Step 4.C PR MUST add the runbook checkbox and the verbatim sign-off template to `OPS.md`. The Step 4.C convergence file MUST quote the template and EXPLICITLY state whether live production sign-off is already satisfied (e.g. "SPEC-014 v0.9 commit SHA + date both disclosure surfaces went live = NOT YET — remains a cutover prerequisite before first production partner-key issuance"). If not satisfied, that does NOT block the Step 4.C PR merge — it remains a **cutover prerequisite** (operator-side, executed AFTER Step 4 merges), NOT a **PR merge prerequisite** (audit-side, executed BEFORE Step 4 merges). This split is binding: a fresh IMPL author or audit lane MUST NOT block Step 4.C convergence on a live SPEC-014 v0.9 deployment that has not yet shipped.

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
| AC-22 (v0.1.8) | Step 3 | auth-failure tier limiter — 301st invalid-bearer request returns 429 before sha256+SELECT runs; SQL counter ≤300; combined with SECURITY r5 H1 spoofed-XFF + trusted-proxy tests |

End-of-implementation: re-run ALL 22 ACs (v0.1.8 added AC-22) as a final smoke against the merged main; this is a Step 4.C deliverable.

## 3. Per-step audit-loop discipline (NON-NEGOTIABLE)

Per [[feedback-codex-only-audits]] and the SPEC audit-loop convention:

- Each step gets three codex audit lanes: ARCH, CODE, SECURITY. ARCH catches structural drift from the SPEC; CODE catches implementation bugs; SECURITY catches missed isolation / leak / timing-attack issues.
- Each lane round writes a fresh file `specs/SPEC-017-IMPL-STEP_N-{arch,code,security}-rM-audit.md`.
- **Convergence target:** `0 CRITICAL + 0 HIGH + 0 MEDIUM` per lane. LOW + INFO findings MAY be deferred and acknowledged in a `specs/SPEC-017-IMPL-STEP_N-rM-convergence.md` file before the step's PR opens.
- Author each step's audit prompts FIRST (BEFORE writing code). The audit prompt's existence is the gate that says "this step's scope is bounded."

## 4. Files you should read before writing

- [`specs/SPEC-017-network-stats-api.md`](SPEC-017-network-stats-api.md) — the LOCKED contract. Read fully, all 12 sections, 21 ACs.
- [`specs/SPEC-017-advisor-round-2026-06-25.md`](SPEC-017-advisor-round-2026-06-25.md) — locked Q1-Q4 design picks.
- `specs/SPEC-017-r1-audit.md` through `r10-audit.md` — skim for the why behind each MUST. r8 was the v0.1.7 lock audit (Claude critic+designer fix pass); r9 surfaced the §9.4 / §7.2.2 grant mismatch + the §5.6 / AC-8 burst inconsistency; r10 locked v0.1.8 with Shape C + burst dropped + auth-failure tier added. This prompt anchors to v0.1.8.
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
2. `docs/network-stats-api/CHANGELOG.md` written with the v0.1.8 LOCK + IMPL entry (Step 4.C).
3. `OPS.md` updated with: partner-key rotation runbook, partner-key revocation runbook, rollup-restart runbook, emergency `exact → bucketed` suppression runbook (operator may suppress; operator MUST NOT exact-enable), AND the §6.6.2 partner-key-disclosure obligation copy + the cutover-runbook checkbox for the launch-sequencing gate.
4. `beta/DECISION_CRITERIA.md` Entry NN added: "SPEC-017 v0.1.8 IMPL shipped (Pearl deploy date, monitoring snapshot, partner-key issuance count + the cutover-runbook checkbox satisfied, AC sweep result, top-N leaderboard validation against a known provider)."
5. Operator-side cutover runbook: backfill mode selection (Path A or B), partner-key issuance for the first N partners (gated on §6.6.2 launch-sequencing precondition), nginx flip, public announcement.

**You are not done when the code compiles. You are done when:**

- All four step audit loops close at `0 CRITICAL + 0 HIGH + 0 MEDIUM` per lane.
- All 22 ACs (v0.1.8 added AC-22 for the auth-failure tier limiter) in the §2.4 matrix verified in CI on the merged tip of `main`.
- Pearl deploy serves `/v1/stats/health` returning `{"status": "ok"}` with a `generated_at` within the §9.5 SLA, and the `components` map has exactly 7 keys (`overview`, `timeseries_rpm`, `timeseries_tpm`, four `leaderboard_*` per v0.1.7 M1).
- A partner key issued via CLI unlocks the partner projection on `/v1/stats/leaderboard`, with `Access-Control-Allow-Origin` echoing the partner's Origin (NEVER `*`) and `Access-Control-Allow-Credentials: true` per v0.1.7 H1.
- A bucketed provider's `exact_earnings` field appears as JSON `null` in the public projection (SINGLE field per v0.1.7 D-M1; the per-axis fields no longer exist).
- An `exact`-mode provider's row appears with the exact `$` value in `exact_earnings`.
- The public response carries `meta.rewards_populated: false` while `provider_rewards_ledger` is empty, and switches to `true` for windows that overlap with seeded ledger rows.
- The public response carries no `totals.earnings_*` keys (v0.1.7 H3) and the partner-key response carries all three.
- A 61st request from a single IP returns 429 with `Retry-After` per AC-8 (nginx tier). v0.1.8 reconciled §5.6 with AC-8 by dropping `burst` — Step 4.B is no longer blocked.
- A 301st invalid-bearer request from a single IP returns 429 per AC-22 (auth-failure tier, in-process, pre-hash-SELECT).
- The CI assertion AC-20 finds zero `new_mode = 'exact' AND actor_kind = 'operator'` rows.
- The redaction sweep finds zero raw-token / `token_hash` / random-portion-substring occurrences across journalctl, nginx logs, structured logs, metric labels, response bodies.
- **SPEC-014 v0.9 surface split in the final checklist (v10 ARCH r9 H2 — do NOT collapse these three surfaces back into one bullet):**
  - **SPEC-014 v0.9 visibility-toggle UI**: documented in OPS.md as a non-blocking follow-up. NOT a cutover gate for ANY part of SPEC-017 v0.1.8.
  - **§11 Q12 canonical UI consumer**: documented in OPS.md as a non-blocking follow-up. NOT a cutover gate.
  - **SPEC-014 v0.9 §6.6.2 disclosure UI**: non-blocking for public bucketed API cutover, **HARD-BLOCKING before the first production partner-key issuance**. The Step 4.C cutover-runbook checkbox MUST be checked AND the verbatim sign-off text (SPEC-014 v0.9 commit SHA + date both disclosure surfaces went live) MUST be recorded BEFORE any `coordinator partner-keys issue` invocation on a production coordinator that produces a key delivered to a real partner. Staging keys for AC fixtures + partner integration dry-runs are exempt.

**SPEC-017 v0.1.8 IMPL is a public partner-facing contract.** Treat the audit-loop discipline as load-bearing, not ceremonial.
