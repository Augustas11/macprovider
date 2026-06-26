# BUILD_SPEC_017_IMPL — Network Stats API implementation (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing any code.**

Your job is to implement [`specs/SPEC-017-network-stats-api.md`](SPEC-017-network-stats-api.md) — the public Network Stats HTTP API for `/v1/stats/{overview,leaderboard,health}` served from the existing coordinator binary, plus the rollup pipeline that feeds it, plus the four DB roles that isolate it. The SPEC is the **single controlling contract** for this work; every section of this prompt cites SPEC-017 §-numbers and you MUST verify those §-references against the merged SPEC at HEAD before encoding them.

## 0. Controlling contract

- **SPEC:** [`specs/SPEC-017-network-stats-api.md`](SPEC-017-network-stats-api.md) at v0.1.6 (LOCKED on commit `f381143` on the v0.1 LOCK branch; codex round-7 declared READY TO LOCK at 0/0/0 over 7 sequential rounds). Re-read every "MUST / MUST NOT / SHOULD" in the SPEC before you write the corresponding IMPL code. Every section heading referenced below (`§5.1`, `§7.2.2`, `§9.1`, etc.) points at the merged SPEC.
- **Per-round audit detail:** [`specs/SPEC-017-r1-audit.md`](SPEC-017-r1-audit.md) through [`specs/SPEC-017-r7-audit.md`](SPEC-017-r7-audit.md). Skim these for the *why* behind individual SPEC requirements — many normative paragraphs close a specific audit finding (e.g. round-2 C1 the partner-key 47-char format, round-2 C2 the deferred rewards-source semantics, round-4 M2 the implementation-authored OLTP source grants, round-6 M1 the BIGSERIAL backing-sequence grants).
- **Locked design rationale:** [`specs/SPEC-017-advisor-round-2026-06-25.md`](SPEC-017-advisor-round-2026-06-25.md) records the four LOCKED Q1-Q4 picks (separate rollup pipeline, public overview + optional partner keys on leaderboard, bucketed-default earnings + provider opt-in, embed in coordinator binary). **DO NOT re-litigate any of those picks in this IMPL.**
- **Decision rationale:** [`beta/DECISION_CRITERIA.md`](../beta/DECISION_CRITERIA.md) Entry 90 records why one-contract-three-consumers, why bucketed default, why partner keys on leaderboard only, and why embed-not-split.

**The IMPL author's job is to encode the SPEC, not to re-question it.** If you find yourself disagreeing with a normative requirement, STOP and surface the disagreement to the operator — do NOT silently deviate. If you find an ambiguity, file a SPEC v0.2 candidate; do NOT resolve it in code.

## 1. Pre-flight checklist — operator-action prerequisites

These prerequisites are NOT in the SPEC (no §9 equivalent for SPEC-017 — the SPEC is operator-prerequisite-free in the sense that it does not gate on hot-wallet provisioning the way SPEC-016 does). They are nonetheless required before IMPL kickoff. The IMPL author MAY proceed in parallel with operator discharge of items 4-6 (DNS / nginx / Cloudflare) because they don't block code writing; items 1-3 MUST be discharged first.

1. **Decide hostname pattern (§7.1, §11 Q6).** Operator picks one of (a) `/v1/stats/*` on `coordinator.streamvc.live` only, (b) add a separate `stats.streamvc.live` server-block reverse-proxying to the same binary on the same path, or (c) both. v0.1.6 §7.1 currently pins (c); if the operator wants (a) or (b) for IMPL, file a SPEC v0.1.7 candidate FIRST and re-audit — do NOT silently deviate.
2. **Decide backfill posture (§9.7, §11 Q7).** Operator picks Path A (partial-history forward + `partial_history_since` field on `30d`/`all` responses) or Path B (full OLTP backfill before nginx flips on). v0.1.6 §9.7 supports both; the IMPL author MUST be told which before writing the `30d`/`all` rollup. Default operator-bias toward Path A per [[macprovider-vercel-demo]] / [[project-macprovider-m0-complete]] thin-ship pattern; Path B is heavier and requires operator-scheduled downtime.
3. **Pin SPEC-016 dependency version at IMPL time.** SPEC-017 v0.1.6 cites SPEC-016 v0.1.19. If SPEC-016 has moved beyond v0.1.19 by IMPL time, the IMPL author MUST re-check that the §9.1a rewards-source deferral is still honest against the newer SPEC-016. If SPEC-016 v0.2+ defines a work/rewards split, surface it; do NOT silently rewire `earnings_rewards_usd` to the new source — that would close §11 Q13 in code instead of in SPEC, which violates the audit-loop convention.
4. **DNS for `stats.streamvc.live`.** Operator points the new vhost at the same Pearl VPS IP as `coordinator.streamvc.live`. SOFT prereq — IMPL can build and unit-test without DNS in place; integration smoke needs it.
5. **Cloudflare configuration.** If Cloudflare fronts the new vhost (recommended per §5.6 / §7.4), operator configures the rate-limit zones and bot-management rules before public cutover. SOFT prereq.
6. **Nginx server-block on Pearl.** Operator deploys the new server-block (§7.4) and verifies TLS, cache directives, header strip on `Authorization`, and the dedicated `limit_req_zone`. SOFT prereq for IMPL but a HARD prereq for production cutover.

Without items 1, 2, 3, IMPL is blocked. Without items 4-6, IMPL ships to a non-cutover-ready environment (build complete, deploy gated).

## 2. Stepped-IMPL decomposition — 4 steps + 4 audit loops

This SPEC is structurally simpler than SPEC-016 (no chain interactions, no money path beyond display, no dual-loader machinery) but partner-facing wire surface + role isolation + rollup correctness still warrants stepped IMPL with per-step audit. Single-step IMPL was considered and REJECTED: the §7.2 four-role grant model + §5.4 partner-key contract + §9.1 table schemas are each non-trivial enough that bundling them with the HTTP handlers would lose audit-lens clarity.

The recommended PR grouping mirrors the steps 1:1 (one PR per step). Per [[pr-rebase-silent-dependency-regression]], rebase each PR on the merged tip of the previous one before pushing.

### Step 1 — Schema + DB roles + grant inventory

**What lands:**

- New package directory `phase4-coordinator/internal/stats/` per §4.2. Cross-package boundary discipline (§7.6): `internal/stats/` MUST NOT import `internal/billing/`, `internal/explorer/`, `internal/ws/`, or `internal/auth/` (other than a minimal Bearer parser). IMPL audit MUST include an import-graph test (AC-16) asserting these denies.
- Schema migrations under `phase4-coordinator/internal/stats/migrations/`:
  - [§9.1] All `stats_*` and `stats_components_health` tables + `stats_late_events` per the normative DDL in SPEC-017 §9.1 (verbatim — no schema drift).
  - [§9.1a] `provider_rewards_ledger` skeleton table (operator-populated; rollup-readable only).
  - [§6.1] `provider_visibility` side table (PRIMARY KEY `provider_id`, DEFAULT `'bucketed'`).
  - [§6.5] `provider_visibility_audit` table (BIGSERIAL `id`).
  - [§5.4.1] `partner_keys` table (BIGSERIAL `id`, hashed `token_hash`, all columns per §5.4.1).
- Postgres roles per §7.2:
  - `stats_reader` (§7.2.1) — request-path SELECT on `stats_*` + `partner_keys` + `provider_visibility`.
  - `stats_rollup` (§7.2.2) — SELECT, INSERT, UPDATE, DELETE on `stats_*` + `stats_late_events`; SELECT on `provider_visibility`, `provider_rewards_ledger`; USAGE+SELECT on `stats_late_events_id_seq`; plus IMPL-authored OLTP source SELECTs against the locked SPEC-002 v1.4 + SPEC-005 v0.3 inventory at IMPL time (see §7.2.2 normative note).
  - `provider_portal` (§7.2.3) — INSERT/UPDATE on `provider_visibility`, INSERT on `provider_visibility_audit`, USAGE+SELECT on `provider_visibility_audit_id_seq`.
  - `partner_keys_writer` (§7.2.4) — UPDATE (last_used_at) on `partner_keys`. OPTIONAL role; create iff the operator chooses to populate `last_used_at`.
- Connection-pool isolation per §7.2.5: separate `*sql.DB` instances per role.

**Tests:**

- Unit: every `CREATE TABLE` round-trips via golang-migrate / equivalent.
- Integration: `stats_reader` returns permission-denied on a SELECT against a locked SPEC-005 v0.3 ledger table (AC-9 — pick `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, or `ledger_reconciliation_runs`). The assertion target is permission-denied, NOT "relation does not exist."
- Integration: `partner_keys_writer` cannot UPDATE columns other than `last_used_at`.
- Integration: `provider_portal` cannot SELECT any `stats_*` table.
- Lint: import-graph CI rule rejects `internal/stats/* → internal/billing|internal/explorer|internal/ws` (AC-16). Recommend `depguard`-style enforcement so future imports fail in CI.

**Step 1 audit prompt** lives at `specs/AUDIT_SPEC_017_IMPL_STEP_1_PROMPT.md` (you author it, mirror the SPEC-016 step audit prompts under `specs/AUDIT_SPEC_016_IMPL_STEP_1_*_PROMPT.md`). Three audit lanes per the SPEC-016 pattern: ARCH, CODE, SECURITY. Run until `0 CRITICAL + 0 MAJOR` per [[feedback-codex-only-audits]] (codex, not Claude internal subagents).

### Step 2 — Rollup pipeline

**What lands:**

- `phase4-coordinator/internal/stats/rollup/` subpackage. MAY import billing/session/pool packages (read-only) since the rollup runs out-of-band, not on the request path. Connects with `stats_rollup` role.
- Per-table refresh jobs at the §9.2 cadences:
  - `stats_overview_current` every 30s.
  - `stats_timeseries_rpm_30m` / `stats_timeseries_tpm_30m` every 30s, rolling 30-minute window.
  - `stats_leaderboard_24h` every 60s.
  - `stats_leaderboard_7d` every 5 minutes.
  - `stats_leaderboard_30d` every 30 minutes (incremental merge per §9.3).
  - `stats_leaderboard_all` every 6 hours (incremental + nightly rebuild at operator-configured UTC hour, default 09:00 UTC, per §9.3).
- Late-event correction per §9.3: 48h look-back for `30d`/`all`; older events recorded in `stats_late_events`; nightly full-rebuild reconciles.
- Drift detection per §9.4: nightly rebuild compares against incremental snapshot; `>0.5%` divergence on any axis fires `stats_rollup_drift_detected` operator event; rebuild value wins.
- `stats_components_health` updates: each table's job UPSERTs its `generated_at` + `last_ok_at` on success, `last_error_at` + `last_error_message` on failure (per §5.3).
- Backfill on cutover per §9.7: write per-component cutover routine. Default to Path A (partial-history forward + `partial_history_since` field) unless operator selected Path B in §1 prereq 2.
- `partner_keys.last_used_at` updates routed via a buffered in-process channel consumed by `partner_keys_writer` role connection (per §5.4.3 step 2 + §7.2.4). MAY be a no-op if the operator chose to skip this update.

**Tests:**

- Unit: each rollup query produces deterministic output on a fixture OLTP corpus.
- Integration: rollup snapshot advances `generated_at` per its cadence; SLA breach (kill rollup, observe `stale_after` increment) results in `stats_components_health.status = 'degraded'` per §5.3 / §9.5.
- Integration: late event at `T-30h` (within 48h lookback) folds into `30d` snapshot on next refresh; event at `T-60h` (outside lookback) lands in `stats_late_events`.
- Integration: drift > 0.5% triggers alert AND rebuild value wins (assert `stats_leaderboard_all.<axis>` matches rebuild, not incremental).
- Property: pseudonym mapping is deterministic per `provider_id` (same `provider_id` → same pseudonym across snapshots).

**Step 2 audit prompt** at `specs/AUDIT_SPEC_017_IMPL_STEP_2_PROMPT.md`. Three lanes: ARCH, CODE, SECURITY. Audit until `0 CRITICAL + 0 MAJOR`.

### Step 3 — HTTP handlers + error envelope + CORS + 405

**What lands:**

- `phase4-coordinator/internal/stats/handlers/` subpackage. Mounts under `/v1/stats/*` per §7.1. Connects with `stats_reader` role.
- Handlers:
  - `GET /v1/stats/overview` — §5.1 JSON shape, 14 `network.*` fields, 30-point timeseries with `null` (NOT zero) for missing minutes (§5.1 field rules).
  - `GET /v1/stats/leaderboard` — §5.2 wire shape. Validation of `window` (`24h|7d|30d|all`), `sort` (`earnings|tokens|jobs`), `limit` (`[1,100]`). Boundary cases (`limit=0` and `limit=101`) return 400 per AC-2.
  - `GET /v1/stats/health` — §5.3 shape; returns 200 even when components are degraded.
- Partner-key authn flow per §5.4.3 decision table (6-row branch). Auth dispatcher MUST:
  - Use the timing-attack-resistant pattern: compute `sha256(<token>)` and SELECT by `token_hash` for every keyed request; equal latency for "no match" vs "revoked" (AC-18 verifies ±20% latency tolerance).
  - Route `last_used_at` UPDATE to the `partner_keys_writer` channel (NOT inline on the response path).
  - Enforce `allowed_origins` (§5.4.3 row 5: non-empty + Origin not in allowlist → 401, NOT 403).
- CORS per §5.7 decision table. Preflight (`OPTIONS`) MUST be key-agnostic per §5.7 preflight rule (browsers don't send Authorization on preflight); per-key allowlist enforced only on GET. AC-13 requires preflight return exactly 204.
- Error envelope per §5.9 closed code vocabulary (`bad_request`, `unauthorized`, `method_not_allowed`, `rate_limited`, `stats_stale`, `internal`). 304 exempt per §5.9 first paragraph.
- 405 handling per §4.3: any verb other than GET/HEAD/OPTIONS against any `/v1/stats/*` returns `405` with `Allow: GET, HEAD, OPTIONS` AND the §5.9 envelope `{"error":{"code":"method_not_allowed",...}}` (AC-21).
- ETag + 304 per §5.1 / AC-12: weak ETag = `sha256(body)` computed once per rollup snapshot; If-None-Match comparison returns 304 with empty body when `generated_at` has not advanced.
- 503 staleness handler per §5.8 / §9.5 budgets (AC-14 verifies 120s for overview).
- `X-Stats-Generated-At` header on every `/v1/stats/*` response per §5.1 / §5.2 / §5.3.
- Process isolation per §7.3: stats subtree wrapped in recover middleware that logs `event=stats_handler_panic` and returns 500 with the §5.9 envelope (AC-11).
- Rate limiting per §5.6: public tier via nginx `limit_req_zone` (primary, AC-8 verifies via 61st request from same IP returns 429 with `Retry-After`); in-process bucket as fallback. Partner tier in-process bucket keyed on `partner_keys.id` (NOT raw token).

**Tests:**

- Unit: every AC-1 through AC-21 has a deterministic fixture-driven test. Acceptance criteria failures fail CI.
- Integration: full request-response cycle against a seeded rollup snapshot. Verify JSON shape exact-match against `specs/SPEC-017-network-stats-api.md` §5.1 / §5.2 / §5.3 examples (within timestamp variance).
- Integration: 405 envelope shape per AC-21.
- Integration: 304 round-trip per AC-12.
- Integration: timing-attack resistance per AC-18 (statistical test over 100+ requests).
- Integration: log-redaction per AC-15 (assert no raw `Authorization` header value appears in `journalctl --unit=coordinator`).
- Integration: panic recovery per AC-11 (inject a panic via test handler, assert /healthz survives).

**Step 3 audit prompt** at `specs/AUDIT_SPEC_017_IMPL_STEP_3_PROMPT.md`. Three lanes: ARCH, CODE, SECURITY. Audit until `0 CRITICAL + 0 MAJOR`.

### Step 4 — Partner-key CLI + nginx config + observability

**What lands:**

- `coordinator partner-keys issue` CLI subcommand per §5.4.2:
  - Generates 32 cryptographically random bytes via the system CSPRNG.
  - 43-char unpadded base64url (RFC 4648 §5) encoding.
  - Prefix `mpk_` to form the 47-character raw token.
  - Compute `sha256(raw_token_utf8_bytes)`.
  - INSERT into `partner_keys` with `token_hash`, `prefix` (first 8 chars), label, allowed_origins, rate_limit_*.
  - Print raw token to stdout exactly once.
  - AC-17 verifies length=47, prefix=`mpk_`, body matches `/^[A-Za-z0-9_-]{43}$/`, and the token does NOT appear in any log line after subprocess exit.
- `coordinator partner-keys revoke --id <id> --reason "<text>"` CLI per §5.4.5.
- `coordinator partner-keys rotate-from --id <id>` CLI per §5.4.4.
- Nginx server-block per §7.4: `limit_req_zone`s per endpoint; `Authorization` header strip from access logs; cache directives per §5.1 / §5.2 / §5.3 response headers; CORS preflight pass-through (the in-process handler emits the actual CORS response per §5.7).
- Cloudflare integration (optional, §5.6): rate-limit and bot-management rules at the edge; bot-detection challenges MAY be layered above nginx.
- Observability:
  - Structured log events: `stats_request_served` (endpoint, status, latency, generated_at), `stats_rollup_tick_completed` (component, generated_at, duration), `stats_rollup_drift_detected` (§9.4), `stats_handler_panic` (§7.3), `stats_partner_key_issued`, `stats_partner_key_revoked`.
  - Prometheus metrics (or equivalent): `stats_request_total{endpoint,status}`, `stats_rollup_lag_seconds{component}`, `stats_rollup_errors_total{component}` (§9.6), `stats_rate_limit_exceeded_total{tier,endpoint}`.
  - BetterStack/UptimeRobot integration: monitor `/v1/stats/health` JSON `status` field; alert on `down` or `degraded` for > N minutes (operator threshold).
- Operator runbook entries under `OPS.md` for: rotating a partner key, revoking a partner key in incident, restarting the rollup scheduler after a panic-restart loop, flipping a provider from `bucketed` → `exact` via the SPEC-014 v0.9 portal (or operator CLI fallback for emergencies).
- Public changelog `docs/network-stats-api/CHANGELOG.md` per §8.5 with v0.1.6 entry citing the PR number and the SPEC version.

**Tests:**

- Integration: `coordinator partner-keys issue --label test` produces a valid 47-char token, INSERTs a row, and the raw token does NOT appear in `journalctl` (AC-17).
- Integration: nginx config validates (`nginx -t`), the new server-block serves a 200 from `/v1/stats/health`.
- Integration: a 61st request from the same IP triggers 429 at nginx (NOT at the coordinator) per §5.6 primary-enforcement note.
- Smoke: full deploy to a staging Pearl-equivalent VPS; verify all four endpoints serve, CORS works for an allowlist origin, partner key unlocks the partner projection, public projection shows bucketed providers as `exact_earnings*: null`.

**Step 4 audit prompt** at `specs/AUDIT_SPEC_017_IMPL_STEP_4_PROMPT.md`. Three lanes: ARCH, CODE, SECURITY. Audit until `0 CRITICAL + 0 MAJOR`. SECURITY lane is especially important here (partner-key CLI, log redaction, nginx config).

## 3. Per-step audit-loop discipline (NON-NEGOTIABLE)

Per [[feedback-codex-only-audits]] and the SPEC audit-loop convention:

- Each step gets a three-lane codex audit: ARCH, CODE, SECURITY. ARCH catches structural drift from the SPEC; CODE catches implementation bugs; SECURITY catches missed isolation / leak / timing-attack issues.
- Each audit-lane round writes a fresh file: `specs/SPEC-017-IMPL-STEP_N-{arch,code,security}-rM-audit.md`.
- Loop each lane until `0 CRITICAL + 0 MAJOR`. MINOR findings MAY be deferred to a follow-up issue but each one MUST be acknowledged in the step's CONVERGED commit.
- After all three lanes converge, write `specs/SPEC-017-IMPL-STEP_N-rM-convergence.md` summarizing the closure.
- ONLY THEN open the step's PR.
- Per the SPEC-016 step-PR pattern, each step PR is bundled as: code + step's audit prompts + step's per-round audit files + convergence file.

**Author the audit prompts FIRST per step** (before writing code). The audit prompt's existence is the gate that says "this step's scope is bounded." Without it the temptation is to scope-creep across step boundaries.

## 4. Files you should read before writing

- [`specs/SPEC-017-network-stats-api.md`](SPEC-017-network-stats-api.md) — the LOCKED contract. Read fully, all 12 sections, 21 ACs.
- [`specs/SPEC-017-advisor-round-2026-06-25.md`](SPEC-017-advisor-round-2026-06-25.md) — locked Q1-Q4 design picks.
- [`specs/SPEC-017-r1-audit.md`](SPEC-017-r1-audit.md) through `r7-audit.md` — skim for the why behind each MUST.
- [`specs/SPEC-002-coordinator.md`](SPEC-002-coordinator.md) — line 3 (current locked version), §4 (provider state), §7 (HTTP surfaces). Stats handlers mount here.
- [`specs/SPEC-005-billing.md`](SPEC-005-billing.md) — line 3, §5.1 (work-$ semantics), §10 (ledger tables, the OLTP source for the rollup), §11.4 (tokens-out accounting).
- [`specs/SPEC-006-buyer-api.md`](SPEC-006-buyer-api.md) — line 3, §17 (header strip / X-MacProvider-* allowlist). Verify `X-Stats-Generated-At` does NOT collide.
- [`specs/SPEC-014-provider-portal.md`](SPEC-014-provider-portal.md) — line 3, §2 (authn). The SPEC-014 v0.9 candidate will own the visibility-toggle UI; SPEC-017 IMPL provides the storage column it writes to.
- [`specs/SPEC-016-payout-pipeline.md`](SPEC-016-payout-pipeline.md) — line 3 (re-pin at IMPL time; if SPEC-016 has split work/rewards by then, surface it in §1 prereq 3).
- [`phase4-coordinator/internal/explorer/handlers.go`](../phase4-coordinator/internal/explorer/handlers.go) — existing operator-bearer-gated explorer surface. PATTERN reuse (window parsing, bearer auth, in-process rate limiter); do NOT extend the explorer's surface.
- [`frontdoor/console/index.html`](../frontdoor/console/index.html) — existing console stats grid. Verify `/v1/stats/overview` JSON covers every field the current console renders; if not, surface the gap (§11 Q12 may need closure earlier than v0.2).
- [`beta/DECISION_CRITERIA.md`](../beta/DECISION_CRITERIA.md) Entry 90 — the LOCK record.

## 5. Critical constraints to honor while implementing

These are non-negotiable boundaries the SPEC pins:

1. **One contract, three consumers (§1.5 C1).** No field MAY be added only for console's or portal's UI convenience.
2. **Public dollar values are bucketed by default (§1.5 C2, §6.1).** Default `provider_visibility.mode = 'bucketed'`; no row → bucketed.
3. **No request-path queries against billing/session OLTP (§1.5 C3, §7.2.1).** Stats handlers query only the §7.2.1 request-path-readable grant set.
4. **No handler-level access to billing internals (§1.5 C4, §7.6).** Import-graph lint enforced.
5. **Edge-cacheable (§1.5 C5).** Every `GET` returns `Cache-Control` per the SPEC.
6. **No state mutation in this SPEC (§1.5 C6).** No POST/PUT/DELETE on `/v1/stats/*`. Visibility toggle writes come via SPEC-014 v0.9 portal flow.
7. **Same-origin uniformity (§6.4).** The endpoint MUST NOT inspect `Origin` for `$` exposure.
8. **Partner-key authn timing-attack resistance (§5.4.3, AC-18).** Same hash + SELECT pattern for "no match" and "revoked"; latency variance ≤ 20%.
9. **Log redaction (§5.4.6, AC-15).** No raw token, no `token_hash`, no substring of random portion in any log line.
10. **Process isolation (§7.3, AC-11).** Recover middleware on the stats subtree.

## 6. What this IMPL MUST explicitly defer (do not creep)

These are SPEC v0.2+ items. The IMPL author MUST NOT close any of these in code without first opening a SPEC PR.

- **§11 Q1 percentile-based buckets.** v0.1 ships absolute thresholds.
- **§11 Q2 self-serve partner-key issuance.** v0.1 ships operator-only via CLI.
- **§11 Q3 cursor-based pagination.** v0.1 ships single-shot `limit ≤ 100`.
- **§11 Q4 pseudonym rotation policy.** v0.1 ships stable per provider; rotation deferred.
- **§11 Q5 mixed-window queries (`window=24h,7d`).** v0.1 ships single-window only.
- **§11 Q6 hostname pattern variants.** Pinned at §1 prereq 1 above; do NOT decide in code.
- **§11 Q7 backfill posture.** Pinned at §1 prereq 2 above; do NOT decide in code.
- **§11 Q8 `models_serving` attested-vs-all.** v0.1 ships per §5.1.1 definition; if the operator wants attested-only, SPEC PR first.
- **§11 Q9 combined-bucket disclosure.** v0.1 ships per-axis bucketing per §6.2.
- **§11 Q10 empty-row policy.** v0.1 ships implicit exclusion; `include_inactive=true` opt-in is v0.2.
- **§11 Q11 partner-projection opt-out.** v0.1 ships partner-key exposure of all rows.
- **§11 Q12 canonical UI consumer.** v0.1 of THIS SPEC is API-only; UI lands in a follow-up SPEC.
- **§11 Q13 rewards-source semantics.** v0.1 ships operator-defined `provider_rewards_ledger`; the population source is operator-config and MAY be empty.
- **Embed badge** (`<script src=".../badge.js">`).
- **WebSocket/SSE live push.** v0.1 ships poll + edge cache.
- **GraphQL surface.** REST + JSON only.
- **Per-provider drill-down** (`/v1/stats/provider/<id>`).
- **Authenticated partner dashboards / per-key analytics UI.**
- **Cross-region replicas / multi-region.**
- **Webhook events.**

## 7. Final deliverables when you're done

Per-step:

1. PR for Step N, containing the step's code + tests + step audit prompts + per-lane per-round audit files + convergence file.
2. CI green: import-graph lint, unit tests, integration tests, smoke tests against a seeded fixture corpus.
3. Each AC mechanically verified in CI.

End-of-implementation:

1. All four step PRs merged.
2. `docs/network-stats-api/CHANGELOG.md` written with the v0.1.6 LOCK + IMPL entry.
3. `OPS.md` updated with partner-key rotation runbook, rollup-restart runbook, visibility-toggle emergency CLI fallback.
4. `beta/DECISION_CRITERIA.md` Entry NN added: "SPEC-017 v0.1.6 IMPL shipped (Pearl deploy date, monitoring snapshot, partner-key issuance count, top-N leaderboard validation against a known provider)."
5. Operator-side cutover runbook: backfill (Path A or B per §1 prereq 2), partner-key issuance for the first N partners, nginx flip, public announcement.

**You are not done when the code compiles. You are done when:**

- All four step audit loops close at 0 CRITICAL + 0 MAJOR.
- All 21 ACs verified in CI on the merged tip of `main`.
- Pearl deploy serves `/v1/stats/health` returning `{"status": "ok"}` with a `generated_at` within the §9.5 SLA.
- A partner key issued via CLI unlocks the partner projection on `/v1/stats/leaderboard`.
- A bucketed provider's `exact_earnings_*` field appears as JSON `null` in the public projection.
- An `exact`-mode provider's row appears with the exact `$` value.
- A 61st request from a single IP returns 429 with `Retry-After` per AC-8.
- The console / portal renders the new endpoints without UI regression (or, if §1 prereq 1 picks a `stats.streamvc.live` standalone, the new domain works from any allowlisted Origin).

**SPEC-017 v0.1.6 IMPL is a public partner-facing contract.** Treat the audit-loop discipline as load-bearing, not ceremonial.
