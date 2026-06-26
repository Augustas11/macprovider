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

- **SPEC:** [`specs/SPEC-017-network-stats-api.md`](SPEC-017-network-stats-api.md) at v0.1.6 (LOCKED on commit `f381143` on the v0.1 LOCK branch; codex round-7 declared READY TO LOCK at 0/0/0 over 7 sequential rounds). Re-read every "MUST / MUST NOT / SHOULD" in the SPEC before you write the corresponding IMPL code. Every section heading referenced below (`§5.1`, `§7.2.2`, `§9.1`, etc.) points at the merged SPEC.
- **Per-round SPEC audit detail:** [`specs/SPEC-017-r1-audit.md`](SPEC-017-r1-audit.md) through [`specs/SPEC-017-r7-audit.md`](SPEC-017-r7-audit.md). Skim these for the *why* behind individual SPEC requirements — many normative paragraphs close a specific audit finding (e.g. round-2 C1 the partner-key 47-char format, round-2 C2 the deferred rewards-source semantics, round-4 M2 the implementation-authored OLTP source grants, round-6 M1 the BIGSERIAL backing-sequence grants).
- **Per-round IMPL-prompt audit detail:** [`specs/SPEC-017-IMPL-PROMPT-arch-rN-audit.md`](SPEC-017-IMPL-PROMPT-arch-r1-audit.md) / `-code-` / `-security-` for each round. This v2 of the prompt absorbed round-1 findings across all three lanes (3 CRITICAL + 21 HIGH + 13 MEDIUM + 3 LOW).
- **Locked design rationale:** [`specs/SPEC-017-advisor-round-2026-06-25.md`](SPEC-017-advisor-round-2026-06-25.md) records the four LOCKED Q1-Q4 picks (separate rollup pipeline, public overview + optional partner keys on leaderboard, bucketed-default earnings + provider opt-in, embed in coordinator binary). **DO NOT re-litigate any of those picks in this IMPL.**
- **Decision rationale:** [`beta/DECISION_CRITERIA.md`](../beta/DECISION_CRITERIA.md) Entry 90 records why one-contract-three-consumers, why bucketed default, why partner keys on leaderboard only, and why embed-not-split.

**The IMPL author's job is to encode the SPEC, not to re-question it.** If you find yourself disagreeing with a normative requirement, STOP and surface the disagreement to the operator — do NOT silently deviate. If you find an ambiguity, file a SPEC v0.2 candidate; do NOT resolve it in code.

## 1. Pre-flight checklist — operator-action prerequisites

SPEC-017 has no operator-prerequisite section analogous to SPEC-016's hot-wallet gate. The locked SPEC already pins behavior for both hostname patterns (§7.1: both `coordinator.streamvc.live/v1/stats/*` and `stats.streamvc.live` work) and both backfill postures (§9.7 Path A default + Path B opt-in). The IMPL author MUST implement BOTH paths and BOTH backfill modes; operator selection applies at cutover/config, not at code-write time.

That said, four items need confirmation BEFORE kickoff (two implementation-shape items + two security-gate items), and four items are HARD prereqs before production cutover (deploy gates, not code gates).

**Pre-kickoff confirmation items (not code gates):**

1. **Hostname pattern (§7.1, §11 Q6).** Locked SPEC pins (c) both. Operator confirms the v0.1 cutover surfaces both hostnames; if operator wants only (a) or (b), file a SPEC v0.1.7 candidate FIRST and re-audit — do NOT silently deviate in code.
2. **Backfill posture (§9.7, §11 Q7).** Both Path A (partial-history forward + `partial_history_since` field) and Path B (full OLTP backfill before nginx flips on) are implementable in code. Operator picks at cutover via a config flag the IMPL author MUST expose; default = Path A per [[macprovider-vercel-demo]] thin-ship pattern. The Step 2 rollup code MUST support both modes; the cutover runbook (Step 4) records which mode is selected for production.

**Pre-kickoff security-gate items:**

3. **Pin SPEC-016 dependency version at IMPL time.** SPEC-017 v0.1.6 cites SPEC-016 v0.1.19. If SPEC-016 has moved beyond v0.1.19 by IMPL time, the IMPL author MUST re-check that the §9.1a rewards-source deferral is still honest against the newer SPEC-016. If SPEC-016 v0.2+ defines a work/rewards split, surface it; do NOT silently rewire `earnings_rewards_usd` to the new source — that would close §11 Q13 in code instead of in SPEC, which violates the audit-loop convention.
4. **Provider-identity trust source (security gate).** Per [[provider-auth-unauthenticated-end-to-end]] (XSEC-1), live beta operation has historically run with `require_provider_tokens=false` and attacker-controlled hello frames could impersonate pinned providers. SPEC-017 MUST NOT amplify unauthenticated provider identity into a public leaderboard. Before Step 2 rollup code, verify the OLTP `provider_id` column the rollup reads from is sourced from authenticated `provider_token` plumbing (per SPEC-002 v1.4 §7), NOT from raw hello-frame payloads. If production still has unauthenticated provider IDs, the IMPL author MUST gate the rollup to filter for authenticated rows OR block public cutover until the auth gap is closed. Surface this to the operator before writing Step 2 code.

**Production-cutover deploy gates (operator side, MUST be discharged before nginx flip — but DO NOT block IMPL code-write or staging deploys):**

5. **Postgres roles + DSN provisioning (HARD before any Pearl deploy of stats code).** Operator creates the Postgres roles and their passwords on the Pearl Postgres instance, applies the §9.1 / §6.1 / §6.5 / §5.4.1 migrations, and installs the four DSNs (`stats_reader_dsn`, `stats_rollup_dsn`, `provider_portal_dsn`, optionally `partner_keys_writer_dsn`) in the coordinator config/secrets store. Step 1's startup smoke verifies the DSNs and roles via a staging deploy BEFORE any Pearl rollout. The coordinator binary MUST be fail-closed: on startup, if `stats.enabled = true` and any required DSN is missing or any required role fails connection smoke, the process MUST refuse to start. If `stats.enabled = false` (default until cutover), the stats subtree mounts as a 503 stub (`{"status":"down","reason":"stats_disabled"}`) and the rest of the coordinator runs normally.
6. **DNS for `stats.streamvc.live`.** Operator points the new vhost at the same Pearl VPS IP as `coordinator.streamvc.live`. SOFT prereq — IMPL builds and unit-tests without DNS in place; integration smoke needs it.
7. **Cloudflare configuration.** If Cloudflare fronts the new vhost (recommended per §5.6 / §7.4), operator configures rate-limit zones and bot-management rules before public cutover. SOFT prereq.
8. **Nginx server-block on Pearl.** Operator deploys the new server-block (§7.4 + Step 4 directives below) and verifies TLS, cache directives, header strip on `Authorization`, dedicated `limit_req_zone`, fail-closed burst (§5.6 enforced via `nodelay`). SOFT prereq for IMPL but a HARD prereq for production cutover.

**Out of scope (NOT prereqs):**

- **SPEC-014 v0.9 portal toggle UI.** Per SPEC-017 §1.4 and §6.3, the SPEC-014 v0.9 candidate is a follow-up. SPEC-017 v0.1 IMPL ships storage (`provider_visibility`), API behavior, and CI fixture coverage for AC-10 / AC-19 / AC-20. If SPEC-014 v0.9 has not landed at SPEC-017 cutover, defaults take effect (all providers `bucketed`) and no production blocker exists.
- **§11 Q12 canonical UI consumer.** SPEC-017 v0.1 is API-only; the UI consumer lands in a follow-up SPEC. Console and portal rendering MAY proceed in parallel by separate teams; SPEC-017 cutover does not gate on UI consumer existing.

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
- **Rollup package** (`internal/stats/rollup`) — MAY import billing/session/pool/explorer read-only paths but MUST NOT import `internal/stats` or `internal/stats/store` (one-way: rollup writes through the rollup role, never reads through the handler role).

The lint (e.g. `depguard`) MUST be configured with both boundaries and MUST run in CI on every PR (AC-16). The lint MUST also forbid `os.Exit`, `log.Fatal`, `log.Fatalf`, and equivalent process-terminating calls anywhere under `internal/stats/*` to preserve the §7.3 recover-middleware guarantee.

**Schema migrations under `phase4-coordinator/internal/stats/migrations/`:**

- [§9.1] verbatim DDL for `stats_overview_current`, `stats_timeseries_rpm_30m`, `stats_timeseries_tpm_30m`, `stats_leaderboard_24h`, `stats_leaderboard_7d`, `stats_leaderboard_30d`, `stats_leaderboard_all` (shared schema per the SPEC's `-- IDENTICAL` comment), `stats_components_health` (columns: `component`, `generated_at`, `last_ok_at`, `last_error_at`, `last_error_message` — NO `status` column; health JSON `status` field is DERIVED at request time per §5.3 from freshness thresholds, see Step 3), `stats_late_events`.
- [§9.1a] `provider_rewards_ledger` skeleton table (operator-populated; rollup-readable; v0.1 may be empty).
- [§6.1] `provider_visibility` (PK `provider_id`, DEFAULT `'bucketed'`).
- [§6.5] `provider_visibility_audit` (BIGSERIAL `id`).
- [§5.4.1] `partner_keys` (BIGSERIAL `id`, hashed `token_hash`, **`created_by TEXT NOT NULL`** explicitly — the CLI MUST populate this from the operator principal, see Step 4 CLI flags). All columns per §5.4.1 verbatim.

**Postgres role inventory per §7.2 (enumerate each — do NOT use `stats_*` shorthand, since shorthand sweeps in rollup-internal tables):**

- `stats_reader` (§7.2.1) — request-path role.
  - SELECT on EXACTLY: `stats_overview_current`, `stats_timeseries_rpm_30m`, `stats_timeseries_tpm_30m`, `stats_leaderboard_24h`, `stats_leaderboard_7d`, `stats_leaderboard_30d`, `stats_leaderboard_all`, `stats_components_health`, `provider_visibility`, `partner_keys`.
  - Explicit deny: `stats_late_events` (rollup-internal per §9.1, §9.3), `provider_rewards_ledger` (rollup-internal per §9.1a), `provider_visibility_audit` (write-only at request time), and any OLTP billing/session/pool table.
- `stats_rollup` (§7.2.2) — rollup job role.
  - SELECT, INSERT, UPDATE, DELETE on the eight `stats_*` tables plus `stats_components_health` plus `stats_late_events`.
  - SELECT on `provider_visibility`, `provider_rewards_ledger`.
  - `USAGE, SELECT ON SEQUENCE stats_late_events_id_seq`.
  - PLUS IMPL-authored SELECT grants on the locked SPEC-002 + SPEC-005 OLTP source tables (the SPEC-005 ledger tables per §10 — typically `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs`, plus `provider_tokens` from SPEC-002 §7). Re-verify the dependency-line-3 versions at IMPL time per §1 prereq 3.
  - Explicit deny: `partner_keys`, `provider_visibility_audit`.
- `provider_portal` (§7.2.3) — portal toggle role.
  - INSERT, UPDATE on `provider_visibility`.
  - INSERT on `provider_visibility_audit`.
  - `USAGE, SELECT ON SEQUENCE provider_visibility_audit_id_seq`.
  - Explicit deny: any `stats_*`, any OLTP table.
- `partner_keys_writer` (§7.2.4) — OPTIONAL.
  - Column-scoped UPDATE on `partner_keys (last_used_at)` — NOT row-level UPDATE.
  - **PLUS column-scoped SELECT on `partner_keys (id)`** — the worker's `UPDATE partner_keys SET last_used_at = $1 WHERE id = $2` SQL pattern requires SELECT privilege on `id` to evaluate the WHERE clause in PostgreSQL. Without this, the column-scoped UPDATE alone is insufficient and the worker fails at runtime. SPEC-017 §7.2.4 names "UPDATE (last_used_at) only" as the intent; the IMPL must add the minimal SELECT(id) needed to make that intent executable, and the SECURITY audit lane MUST verify the grant is narrowed to `(id)` and NOT widened to row-level SELECT (which would expose `token_hash` and other columns).
  - Optional: skip the role if the operator chooses to not populate `last_used_at`.

**DB connection mechanics (bridge to current coordinator pattern):**

Per current code at [`phase4-coordinator/cmd/coordinator/main.go`](../phase4-coordinator/cmd/coordinator/main.go), the coordinator currently opens SQLite stores from one `storage.db_path` shared across billing, explorer, admission, canary. SPEC-017 requires Postgres roles with separate `*sql.DB` instances per role (§7.2.5). The IMPL author MUST:

- Add Postgres DSN config block under `storage.postgres.*` (driver: `lib/pq` or `pgx`; pick one consistent with the rest of the project — verify against [`go.mod`](../phase4-coordinator/go.mod)).
- One DSN per role (`stats_reader_dsn`, `stats_rollup_dsn`, `provider_portal_dsn`, `partner_keys_writer_dsn`).
- One `*sql.DB` per role, instantiated in `cmd/coordinator/main.go` startup and passed to its owning package. NO shared pools.
- A startup smoke that each pool can connect with its role and FAILS to query a deny-list table (verified by AC-9 in tests).

**Tests for Step 1:**

- Unit: every `CREATE TABLE` round-trips via the migration runner (e.g. `golang-migrate`) up and down without orphans.
- Integration (AC-9, mapped here from the AC matrix below): `stats_reader` returns permission-denied on `SELECT 1 FROM ledger_request_credits LIMIT 1` (NOT "relation does not exist"). Verify against at least one of `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs` (the locked SPEC-005 v0.3 tables, re-verified at IMPL time).
- Integration: `partner_keys_writer` runs the actual worker SQL `UPDATE partner_keys SET last_used_at = $1 WHERE id = $2` and SUCCEEDS (proves both `UPDATE(last_used_at)` and `SELECT(id)` grants are present). Then `UPDATE partner_keys SET allowed_origins = $1 WHERE id = $2` returns permission-denied (allowed_origins not in the column UPDATE grant). Then `SELECT token_hash FROM partner_keys WHERE id = $1` returns permission-denied (token_hash not in the column SELECT grant). The three-fixture test proves the narrowing is exact.
- Integration: `provider_portal` SELECT against any `stats_*` table returns permission-denied; INSERT to `provider_visibility_audit` succeeds with a row whose BIGSERIAL `id` was assigned (sequence grant works).
- Integration (AC-16 lint smoke): a deliberate test package adding `import "phase4-coordinator/internal/billing"` under `internal/stats` (test fixture only, NOT shipped) fails `make lint`. Verify the rule applies to `internal/auth` too (other than the named Bearer-parser allowlist symbol).
- Integration: `os.Exit("test")` under `internal/stats/` fails `make lint`.
- Integration (AC-19, mapped here): SQL fixture inserts a `stats_leaderboard_24h` row for `provider_id = 'never-toggled-xyz'` with NO matching `provider_visibility` row; assert the left-join in Step 3's handler treats this as `mode = 'bucketed'` (verified end-to-end in Step 3).
- Integration (AC-20, mapped here): SQL CI assertion that `SELECT COUNT(*) FROM provider_visibility_audit WHERE new_mode = 'exact' AND actor_kind = 'operator'` returns 0; failure means the operator-side process violated §6.6.3.
- Integration (AC-10 concrete transaction test): SPEC-017 v0.1 does not ship the portal handler (SPEC-014 v0.9 follow-up), but the storage contract MUST be tested at Step 1 using a test harness that drives the same `provider_portal` role. Test shape:
  - BEGIN transaction with `provider_portal` role.
  - `INSERT INTO provider_visibility (provider_id, mode) VALUES ('p1', 'bucketed') ON CONFLICT DO UPDATE SET mode = 'exact', updated_at = now()` (the UPSERT pattern SPEC-014 v0.9 will use).
  - `INSERT INTO provider_visibility_audit (provider_id, old_mode, new_mode, actor_kind, actor_id, source_ip, user_agent) VALUES ('p1', 'bucketed', 'exact', 'provider', 'p1', '127.0.0.1', 'test')`.
  - COMMIT.
  - Assert: exactly one row in `provider_visibility_audit` for `provider_id = 'p1'`, with `new_mode = 'exact' AND actor_kind = 'provider'`.
  - Repeat with intentional error before commit (force ROLLBACK); assert: no rows in either table (transactional atomicity).
  - This proves the storage contract is mechanically achievable under the `provider_portal` grant set; the SPEC-014 v0.9 handler PR will reuse this test fixture as a regression smoke.

**Step 1 audit prompt authoring** (BEFORE writing step 1 code): three lanes, files named per §2.1.

### Step 2 — Rollup pipeline

**Subpackage location:** `phase4-coordinator/internal/stats/rollup/`. Uses `stats_rollup` `*sql.DB`. MAY import billing/session/pool/explorer read-only paths since the rollup runs out-of-band.

**Provider-identity trust gate (per §1 prereq 4):** before writing rollup queries, verify the OLTP `provider_id` source field is sourced from authenticated `provider_token` plumbing (SPEC-002 v1.4 §7). If not, filter the rollup to authenticated rows OR block public cutover. The IMPL author MUST document the trust-source decision in the Step 2 PR description, and the SECURITY audit lane MUST verify the decision is consistent with [[provider-auth-unauthenticated-end-to-end]].

**Per-table refresh jobs at the §9.2 cadences:**

- `stats_overview_current` every 30s.
- `stats_timeseries_rpm_30m` / `stats_timeseries_tpm_30m` every 30s, rolling 30-minute window.
- `stats_leaderboard_24h` every 60s.
- `stats_leaderboard_7d` every 5 minutes.
- `stats_leaderboard_30d` every 30 minutes (incremental merge per §9.3).
- `stats_leaderboard_all` every 6 hours (incremental + nightly rebuild at operator-configured UTC hour, default 09:00 UTC, per §9.3).

**Late-event correction per §9.3:** 48h look-back for `30d`/`all`; older events recorded in `stats_late_events`; nightly full-rebuild reconciles.

**Drift detection per §9.4:** nightly rebuild compares against incremental snapshot; `>0.5%` divergence on any axis emits `stats_rollup_drift_detected` structured-log event AND records the divergence in the operator alerting pipeline (Step 4); rebuild value wins.

**`stats_components_health` updates and bootstrap:** each job UPSERTs its `generated_at` + `last_ok_at` on success, OR `last_error_at` + `last_error_message` on failure (and leaves `generated_at` / `last_ok_at` at their last successful values if they exist; sets them to an explicit "never succeeded" sentinel if not). There is NO `status` column on this table — the JSON `status` field exposed by `/v1/stats/health` (§5.3) is DERIVED at request time from `generated_at` vs §9.5 target staleness vs §5.8 503 budget.

**Bootstrap rule (pin this):** the migration MUST pre-seed all six component rows (`overview`, `timeseries`, `leaderboard_24h`, `leaderboard_7d`, `leaderboard_30d`, `leaderboard_all`) with `generated_at = epoch` (or operator-configured `bootstrap_generated_at`) and `last_ok_at = epoch`. This guarantees the NOT NULL constraints are satisfied even if the first rollup tick fails before any success, AND it guarantees `/v1/stats/health` derives `status = "down"` for any component whose first tick has not succeeded yet (because `now - epoch > §5.8 budget`). A test MUST verify "first tick fails before any success" produces `status = "down"` without violating NOT NULL.

**Backfill posture (both modes implemented; operator chooses at cutover):** per §9.7, implement both Path A (rollup-start-date forward + `partial_history_since` field set on `30d`/`all` responses while the window is shorter than its label) and Path B (synchronous backfill from full OLTP history before flipping `stats.streamvc.live` server-block on). Operator-config flag `stats.rollup.backfill_mode = "partial"|"full"` selects at runtime; default `"partial"`.

**`partner_keys.last_used_at` channel:** updates routed via a buffered in-process Go channel (`chan partnerKeyTouch`) consumed by a dedicated worker running on the `partner_keys_writer` `*sql.DB` (per §5.4.3 step 2 + §7.2.4). The buffered-channel pattern keeps the response path off the write; channel buffer size + drop-on-overflow policy is the IMPL author's choice but MUST NOT block the response path. MAY be a no-op (worker not started) if the operator skips this update.

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
- Integration: a rollup tick advances `stats_*.generated_at`; `stats_components_health` rows update accordingly.
- Integration (health SLA derivation against `stats_components_health` — NOT `stats_overview_current`): seed or age the `stats_components_health` row for `component = 'overview'` so that `now - generated_at > 120s` (past the §5.8 503 budget). Call `GET /v1/stats/health` (Step 3 dependency, OR run against a Step 3 stub if Step 3 has not landed). Assert JSON `status = "down"` per §5.3. Separately, the AC-14 test for `/v1/stats/overview` 503 lives in Step 3 and seeds `stats_overview_current.generated_at > 120s` directly — that is a different path (the request handler's freshness check, not the health-derivation path).
- Integration: late event at `T-30h` folds into `30d` snapshot on next refresh; event at `T-60h` lands in `stats_late_events` (the rollup role can write here; the handler role cannot read it per §7.2.1).
- Integration: drift > 0.5% triggers `stats_rollup_drift_detected` event AND rebuild value wins (assert `stats_leaderboard_all.<axis>` matches rebuild, not incremental).
- Property: `provider_id → pseudonym` mapping is deterministic per provider (same `provider_id` → same pseudonym across snapshots; pseudonym is stable per provider per §3.3).
- Integration (both backfill modes, rollup-state only — handler-response assertion is Step 3): set `stats.rollup.backfill_mode = "partial"` and run Path A backfill; assert the persisted rollup-state metadata (e.g. a `rollup_state.partial_history_since` row, or equivalent persisted source the handler will read) records the start timestamp. Set `= "full"` and run Path B backfill; assert the persisted metadata records no `partial_history_since` (or sets it to NULL). Step 3 will own the test that `/v1/stats/leaderboard?window=30d` JSON exposes or omits the field accordingly.

**Step 2 audit prompt authoring**: three lanes.

### Step 3 — HTTP handlers + error envelope + CORS + auth + redaction

**Package location:** `phase4-coordinator/internal/stats/` (flat — handlers, mux wiring, recover middleware all live here per the existing `internal/explorer/` pattern). Subpackage `phase4-coordinator/internal/stats/store/` houses the DAO that the handlers call. Uses `stats_reader` `*sql.DB`.

**Handlers (mount under `/v1/stats/*` per §7.1, exposed on BOTH `coordinator.streamvc.live/v1/stats/*` and `stats.streamvc.live/v1/stats/*` via the same binary):**

- `GET /v1/stats/overview` — §5.1 JSON shape, 14 `network.*` fields, 30-point timeseries with `null` (NOT zero) for missing minutes (§5.1 field rules).
- `GET /v1/stats/leaderboard` — §5.2 wire shape. Validation:
  - `window`: one of `24h | 7d | 30d | all`. Default `24h` per §5.2 (NOT per AC-2 — AC-2 only checks window default + invalid window). Invalid → 400 `bad_request`.
  - `sort`: one of `earnings | tokens | jobs`. Default `earnings`. Invalid → 400.
  - `limit`: integer in `[1, 100]` per §5.2. Default `50`. Out-of-range or non-integer → 400 (this is §5.2's normative bound, NOT AC-2).
  - Unknown query params MUST be ignored, not rejected.
- `GET /v1/stats/health` — §5.3 shape; returns 200 even when components are degraded; non-200 only when the coordinator process itself is unhealthy. The JSON `status` field is DERIVED at request time from `stats_components_health` rows + §9.5 thresholds + §5.8 budgets, NOT read from a `status` column.

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
- Any in-process comparison of secret-derived bytes MUST use `subtle.ConstantTimeCompare` — do NOT use `==`, `bytes.Equal`, or string comparison.
- Rows 6 and 7 MUST have indistinguishable response latency (±20% variance per AC-18 statistical test of 100+ requests).
- On success, route `last_used_at` update through the `chan partnerKeyTouch` channel (NOT inline SQL on the response path).

**CORS per §5.7 — preflight is key-agnostic** (browsers don't send Authorization on preflight). The handler MUST NOT evaluate per-key allowlist at OPTIONS time. Per-key allowlist enforced ONLY on GET. CORS allowed origins MUST use exact-match strings; sibling-subdomain wildcards (e.g. `*.streamvc.live`) FORBIDDEN — `console.streamvc.live`, `portal.streamvc.live`, `stats.streamvc.live` have distinct trust roles.

Preflight returns exactly **204** (NOT 200 — AC-13 verifies, do not permit a 200 escape hatch) with empty body, `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`, `Access-Control-Allow-Headers: Authorization, Content-Type`, `Access-Control-Max-Age: 3600`. `Access-Control-Allow-Origin` follows §5.7:

- **Origin is on the global partner-origin allowlist** (the union of every active `partner_keys.allowed_origins` array + `console.streamvc.live` + `portal.streamvc.live`) → `Access-Control-Allow-Origin: <Origin>` (echoed) AND `Access-Control-Allow-Credentials: true`.
- **Origin is NOT on the global allowlist** → `Access-Control-Allow-Origin: *` (no credentials).

The subsequent GET is then evaluated by the §5.4.3 7-row decision table EXACTLY. Preflight permissiveness MUST NOT be interpreted by clients or implementations as a guarantee that the GET will succeed:

- If the GET has no `Authorization`, the public projection applies (row 1).
- If the GET has a valid key with non-empty `allowed_origins` and the Origin is not in the key's allowlist, the GET returns 401 (row 5) regardless of what preflight returned.
- If the GET has a revoked key, the GET returns 401 (row 7).

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

`Vary` headers per §5.1 / §5.2 / §5.3 (notably `Vary: Accept-Encoding, Origin, Authorization` on `/leaderboard` so edge caches don't mix keyed and public projections).

**`X-Stats-Generated-At` header on every `/v1/stats/*` response** per §5.1 / §5.2 / §5.3.

**Middleware stack (pinned — exactly this order, outermost to innermost):**

The recover-vs-redaction ordering issue is resolved by pinning a single stack and giving the recover middleware its own first-line `Authorization` strip. The chain MUST be:

1. **Redaction-context middleware (outermost):** runs first on the inbound request. Reads `Authorization`, replaces it with `REDACTED` in the request's logging context, and stores the parsed bearer token in a goroutine-local handle for the auth dispatcher (the only consumer). Every downstream log/trace/metric emitter reads from the redacted context, NOT the raw request header.
2. **Recover middleware:** wraps the entire `/v1/stats/*` subtree (all methods including GET, HEAD, OPTIONS, and the 405 path for other verbs). On panic: log `event=stats_handler_panic` (structured) using the REDACTED context — so `Authorization` is already `REDACTED`, no raw token, no `token_hash`, no raw SQL, no stack in the public log line. Stack MAY go to a debug-only sink. The recover middleware MUST ALSO perform its own first-line `Authorization` strip as defense-in-depth (in case the redaction context is bypassed for any reason); this is the SECURITY guarantee.
3. **Access-logging / tracing middleware:** reads only the redacted context.
4. **Auth dispatcher:** reads the goroutine-local bearer handle from step 1, hashes via `sha256(token_utf8_bytes)`, performs SELECT, enforces §5.4.3 7-row decision table.
5. **Rate-limit middleware (in-process):** keys on client IP (public tier) or `partner_keys.id` (partner tier).
6. **Handler:** computes JSON, returns response. Recover MUST be set on `500 internal` with §5.9 envelope on panic.

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
- **AC-4** bucketed providers → `exact_earnings*: null` in public projection.
- **AC-5** exact providers → `exact_earnings*` populated with 2-decimal float.
- **AC-6** partner-key projection populates `earnings_usd` / `earnings_work_usd` / `earnings_rewards_usd` for ALL rows regardless of mode.
- **AC-7** health 200 even when degraded.
- **AC-11** panic recovery (injected panic; assert /healthz survives + `event=stats_handler_panic` logged with redaction).
- **AC-12** 304 round-trip on If-None-Match.
- **AC-13** OPTIONS `/v1/stats/leaderboard` returns EXACTLY 204 with empty body, `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`, `Access-Control-Allow-Headers: Authorization, Content-Type`.
- **AC-14** `stats_overview_current.generated_at` aged > 120s → 503 with `stats_stale` envelope + `Retry-After: 30`.
- **AC-15** log-redaction sweep across journalctl, nginx logs (via Step 4 integration), structured logs, traces, metric labels. Assert no raw token, no `token_hash`, no random-portion substring.
- **AC-18** timing-attack statistical test (100+ requests for rows 6 and 7 of §5.4.3 table; assert variance ≤ 20%).
- **AC-19** end-to-end fixture: provider with no `provider_visibility` row appears in leaderboard with `exact_earnings*: null` (bucketed default via left-join semantics).
- **AC-21** POST `/v1/stats/overview` → 405 with `Allow` header AND `method_not_allowed` envelope.

Additionally for Step 3 specifically:
- **Cache-Control header assertions** for all four (endpoint, projection) cells in the table above.
- **`X-Stats-Generated-At`** present on every `/v1/stats/*` response.
- **§5.4.3 7-row decision-table test** — one fixture per row, including the absent-Origin case (row 3).
- **CORS sibling-subdomain reject test** — `Origin: https://evil.streamvc.live` rejected; `Origin: https://portal.streamvc.live` accepted only if EXACTLY in allowlist.
- **503 stale not debited from rate-limit bucket** — issue 100 stale requests, then 60 fresh; assert all 60 fresh succeed.
- **`partial_history_since` exposure** — seed `rollup_state.partial_history_since = <timestamp>` (Path A fixture from Step 2); call `GET /v1/stats/leaderboard?window=30d`; assert response includes top-level `partial_history_since` matching the seeded value. Seed `partial_history_since = NULL` (Path B fixture); call same endpoint; assert the field is OMITTED. Both fixtures share the Step 2 rollup state.
- **Constant-time comparison** — code inspection / unit test that token-derived comparisons use `subtle.ConstantTimeCompare`.

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

The SECURITY audit lane MUST produce findings in each of 4.A, 4.B, 4.C — a SECURITY lane that finds zero issues in any one subsection is suspicious.

#### 4.A Partner-key CLI lifecycle

**`coordinator partner-keys issue` subcommand per §5.4.2:**

Flags:

- `--label "<text>"` (required) — human-readable label.
- `--allowed-origin <url>` (repeatable, optional) — populates `allowed_origins`. Multiple = allowlist. Empty = no Origin restriction.
- `--rpm <int>` (default 600) — populates `rate_limit_rpm`.
- `--burst <int>` (default 1200) — populates `rate_limit_burst`.
- `--created-by <text>` (required — the `created_by TEXT NOT NULL` column per §5.4.1; populate from operator principal or current OS user; CI test verifies the row's `created_by` is non-empty).
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

- AC-17: `coordinator partner-keys issue --label X --created-by ops@example.com` prints exactly one 47-character token starting with `mpk_`, body matches `/^[A-Za-z0-9_-]{43}$/`, INSERTs a row with non-empty `created_by`. Subprocess exit followed by `journalctl --since=...` shows the raw token does NOT appear; `token_hash` does NOT appear; the 43-char random body substring does NOT appear.
- Rotation overlap: issue key A; issue key B with `--rotate-from <A>`; assert both unlock the partner projection BEFORE revoking A; then `revoke --id <A>`; assert A returns 401 on the very next request while B still works.
- CLI smoke: `partner-keys revoke --id 99999` (non-existent) returns clean error, NOT a panic.

#### 4.B Edge / nginx / rate-limit / cache

**Nginx server-block on Pearl** for `stats.streamvc.live` AND a path-prefix block for `coordinator.streamvc.live/v1/stats/*`. Required directives:

- `limit_req_zone` declaration per endpoint at the `http` block (defines the zone — no `nodelay` here; `nodelay` is invalid on `limit_req_zone`).
- `limit_req zone=<name> burst=<n> nodelay;` directive applied to each endpoint's `location` block (fail-closed; 429 returns immediately, NOT queued-then-served per SECURITY H3).
- `limit_req_status 429;` per endpoint location.
- Strip `Authorization` header from access logs (`log_format` excludes `$http_authorization`, or use `set $authorization "REDACTED"` pattern).
- `proxy_cache_path` for public projections ONLY. The partner-key projection (carries `Cache-Control: private`) MUST NOT be cached at nginx — gate via `proxy_cache_bypass $http_authorization` so any request with `Authorization` bypasses the cache.
- `proxy_set_header X-Forwarded-For` per existing coordinator pattern.
- TLS per existing cert pipeline.

**Cloudflare integration (optional):** rate-limit and bot-management rules at the edge layered above nginx. MUST NOT cache responses with `Cache-Control: private`.

**Tests for 4.B:**

- AC-8 (nginx rate-limit): from a single client IP, issue 60 requests to `/v1/stats/overview` within 60s; assert all succeed. 61st returns 429 with `Retry-After` set, `code: "rate_limited"`. Test against the nginx surface, NOT the in-process fallback.
- nginx config validates (`nginx -t`); the new server-block serves a 200 from `/v1/stats/health`.
- Edge-cache cross-contamination test: issue keyed request, then anonymous request from same IP within s-maxage; assert keyed response was NOT served to the anonymous request (different body, no exact-$ leak). Verify `Vary: Authorization` is honored AND `Cache-Control: private` on keyed responses prevents nginx caching.
- Burst behavior: at the rate-limit threshold, excess requests are REJECTED with 429 promptly, NOT delayed (verifies `nodelay`).
- Subdomain trust: request from `Origin: https://evil.streamvc.live` is rejected at the application layer (Step 3 CORS test); nginx forwards the request (does not block at edge).

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

**Public changelog** `docs/network-stats-api/CHANGELOG.md` per §8.5, with v0.1.6 entry citing the PR numbers (one per step) and the SPEC version.

**Partner-key broader-exposure provider disclosure (§6.6.2 — HARD cutover deliverable):**

SPEC-017 §6.6.2 requires that providers be disclosed, at onboarding time, that "trusted partners with an operator-issued API key see your exact earnings figures, even when your public mode is `bucketed`." This is part of the privacy posture. Step 4.C MUST deliver:

1. **Disclosure copy** added to `OPS.md` under a section "Partner-key exact-dollar exposure — provider disclosure obligation," substantially equivalent to the §6.6.2 SPEC text. The operator-runbook copy is the source of truth until SPEC-014 v0.9 lands the in-portal disclosure.
2. **Onboarding-flow tracker** entry in the SPEC-014 v0.9 follow-up issue noting: "Add §6.6.2 disclosure copy to the provider-account-creation flow."
3. **Cutover-runbook gate:** before the first production partner key is issued via `coordinator partner-keys issue`, the operator MUST EITHER (a) verify SPEC-014 v0.9 has landed AND the in-portal disclosure copy is live, OR (b) confirm in the cutover runbook that all currently-onboarded providers have been notified via an alternative channel (email, broadcast). The runbook checkbox is part of the Step 4.C deliverable.

This obligation does NOT block public cutover (the public `/v1/stats/leaderboard` projection is bucketed by default). It DOES block the first partner-key issuance for production use. Test partner keys against staging are exempt.

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
| AC-15 | Step 3 + Step 4.A | log/metric/trace sweep across journalctl, nginx logs, metrics |
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
- `specs/SPEC-017-r1-audit.md` through `r7-audit.md` — skim for the why behind each MUST.
- `specs/SPEC-017-IMPL-PROMPT-{arch,code,security}-r1-audit.md` — round-1 findings absorbed into this v2 prompt.
- [`specs/SPEC-002-coordinator.md`](SPEC-002-coordinator.md) — line 3 (current locked version), §4 (provider state), §7 (HTTP surfaces). Stats handlers mount here.
- [`specs/SPEC-005-billing.md`](SPEC-005-billing.md) — line 3, §5.1 (work-$ semantics), §10 (ledger tables, the OLTP source for the rollup), §11.4 (tokens-out accounting).
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
- **§11 Q9 combined-bucket disclosure.** v0.1 ships per-axis bucketing.
- **§11 Q10 empty-row policy.** v0.1 ships implicit exclusion.
- **§11 Q11 partner-projection opt-out.** v0.1 ships partner-key exposure of all rows.
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
2. `docs/network-stats-api/CHANGELOG.md` written with the v0.1.6 LOCK + IMPL entry (Step 4.C).
3. `OPS.md` updated with: partner-key rotation runbook, partner-key revocation runbook, rollup-restart runbook, emergency `exact → bucketed` suppression runbook (operator may suppress; operator MUST NOT exact-enable).
4. `beta/DECISION_CRITERIA.md` Entry NN added: "SPEC-017 v0.1.6 IMPL shipped (Pearl deploy date, monitoring snapshot, partner-key issuance count, AC sweep result, top-N leaderboard validation against a known provider)."
5. Operator-side cutover runbook: backfill mode selection (Path A or B), partner-key issuance for the first N partners, nginx flip, public announcement.

**You are not done when the code compiles. You are done when:**

- All four step audit loops close at `0 CRITICAL + 0 HIGH + 0 MEDIUM` per lane.
- All 21 ACs in the §2.4 matrix verified in CI on the merged tip of `main`.
- Pearl deploy serves `/v1/stats/health` returning `{"status": "ok"}` with a `generated_at` within the §9.5 SLA.
- A partner key issued via CLI unlocks the partner projection on `/v1/stats/leaderboard`.
- A bucketed provider's `exact_earnings_*` field appears as JSON `null` in the public projection.
- An `exact`-mode provider's row appears with the exact `$` value.
- A 61st request from a single IP returns 429 with `Retry-After` per AC-8 (nginx tier).
- The CI assertion AC-20 finds zero `new_mode = 'exact' AND actor_kind = 'operator'` rows.
- The redaction sweep finds zero raw-token / `token_hash` / random-portion-substring occurrences across journalctl, nginx logs, structured logs, metric labels, response bodies.
- The three SPEC-014 follow-up items (portal toggle UI, operator-portal canonical UI, etc.) are documented in OPS.md as non-blocking follow-ups, not as cutover gates.

**SPEC-017 v0.1.6 IMPL is a public partner-facing contract.** Treat the audit-loop discipline as load-bearing, not ceremonial.
