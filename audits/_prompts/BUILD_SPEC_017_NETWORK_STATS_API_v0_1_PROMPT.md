# BUILD_SPEC_017 — Network Stats API v0.1 (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing anything.**

Your job is to write `specs/SPEC-017-network-stats-api.md` v0.1 — a normative spec for a **public, partner-consumable Network Stats HTTP API** that serves the existing dashboards on `console.malibu.tech` and `portal.malibu.tech`, AND is contractually stable enough for external partners to embed on their own sites.

## Why this exists (read first)

Two dashboards already render the same data shape today:

1. **Overview** — tokens served, requests, nodes online, GB/s bandwidth, GPU/CPU cores, unified RAM, network power, utilization, models serving, avg tok/req, and 30-minute `requests/minute` + `tokens/minute` timeseries (split input vs output).
2. **Leaderboard** — pseudonymized provider rankings (`beamy-puppy-4259` style handles) over rolling windows `24h | 7d | 30d | all`, sortable by `earnings | tokens | jobs`, with `$` split into `work` (per-request inference earnings) and `rewards` (network incentives).

Both views are rendered by the same Network Statistics widget today, but the data path is ad-hoc per-surface. Goal of SPEC-017: **one contract, three consumers (console, portal, partners).** No bespoke dashboard endpoints; no partner forks of the schema; no embedded-iframe special case.

This SPEC is the v0.1 floor: read-only endpoints, rollup-table-backed, edge-cached. A v0.2 embed badge (`<script>`-style one-liner) is explicitly out of scope here.

## Locked design decisions (do not re-litigate; cite this section in §2 "Design rationale")

These four were settled via a codex advisor round on 2026-06-25 (artifact at `.omc/artifacts/ask/codex-i-m-designing-a-public-network-stats-api-for-macprovider-a-d-2026-06-25T18-18-42-442Z.md`). The SPEC MUST adopt these picks and the audit loop MAY challenge only the *details* below them, not the picks themselves:

1. **Data source — separate rollup pipeline.** A scheduled job (define cadence, suggest 30s for hot windows, 5m for `30d`/`all`) reads coordinator OLTP tables and writes narrow `stats_overview_*`, `stats_leaderboard_*`, `stats_timeseries_*` tables that the API queries cheaply. The stats API MUST NOT issue ad-hoc aggregate queries against billing/session tables on the request path.
2. **Auth model — public overview, optional API keys for leaderboard.** `/v1/overview` and `/v1/health` are fully public (rate-limited by IP at nginx/Cloudflare). `/v1/leaderboard` is public for a baseline shape but accepts an `Authorization: Bearer <key>` for partners that need higher rate limits or extra (contractually stable) fields.
3. **Earnings sensitivity — provider opt-out with bucketed default.** Default policy for new providers: `$` earnings are exposed as **bucketed/ranked** values in the public API (e.g. `$$$ / $$ / $`, or rank-only); exact `$` requires explicit provider opt-in. Existing providers default to bucketed at v0.1 cutover. `tokens` and `jobs` remain visible unconditionally. Same-origin authenticated portal/console views see exact `$` for the provider's own row regardless of opt-in state.
4. **Hosting — embed in the existing coordinator Go binary.** Routes mount under `coordinator.malibu.tech/v1/stats/*` (or a reverse-proxied public hostname pointing at the same binary; specify the chosen pattern). No new service. Handler-level isolation MUST be specified so a stats handler bug cannot reach billing/session internals (suggest a separate `internal/stats` package with read-only DB role).

## Repo conventions you MUST honour

1. **Naming.** `specs/SPEC-017-network-stats-api.md`. Verify SPEC-017 is the next free number with `ls specs/SPEC-*.md | grep -oE 'SPEC-[0-9]+' | sort -u | tail -5`.
2. **Header format (mandatory, line 3 is version of record):**
   ```
   # SPEC-017 — Network Stats API

   **Version:** 0.1 (2026-MM-DD, initial draft)
   **Depends on:** SPEC-002 vX.Y, SPEC-005 vA.B, SPEC-014 vC.D, SPEC-016 vE.F
   ```
   Use today's date. Look up the current locked versions of dependency SPECs from each one's line 3.
3. **Change log section** at the top (newest first). Per [[feedback-spec-audit-file-convention]] (and the SPEC-016 retrofit at v0.1.19), audit-narrative-by-round MUST NOT live in the SPEC body. Change-log entries are one-liners pointing at `specs/SPEC-017-rN-audit.md` files.
4. **Numbered sections** like every other SPEC. Look at `specs/SPEC-006-buyer-api.md` (public surface, header conventions) and `specs/SPEC-014-provider-portal.md` (read-only surface) for house style.
5. **Acceptance criteria** at the bottom: numbered `AC-1`, `AC-2` etc. that an implementer can mechanically verify (status codes, schema fields, rate-limit behaviour, cache headers).
6. **House voice:** terse, normative, MUST/SHOULD/MAY per RFC 2119. No marketing prose. State invariants, not aspirations.

## What v0.1 MUST normatively pin

### §3 Endpoints — exact wire shape

For each of `GET /v1/overview`, `GET /v1/leaderboard`, `GET /v1/health`:

- Full request: query parameters (allowed values, defaults, validation), accepted headers (`Authorization`, `Accept`, `Origin`), CORS allowlist (which origins get `Access-Control-Allow-Origin`).
- Full response: HTTP status codes (200, 400, 401 on bad key, 429, 5xx semantics), response headers (`Cache-Control`, `ETag`, `X-Stats-Generated-At`, `Vary`), JSON schema (exact field names, types, units, nullability).
- Cache behaviour: documented `max-age` per endpoint, whether `Authorization` varies the cache (MUST specify; default recommendation: API key does NOT vary the standard cache but unlocks a separate `?fields=extra` projection that has its own cache key), `stale-while-revalidate` allowance.
- Error envelope: a single consistent shape (`{"error": {"code": "...", "message": "..."}}`).

The `/v1/overview` JSON MUST cover every field on the rendered Overview tab (see screenshots referenced in the [[macprovider-vercel-demo]] context and current console.malibu.tech source). The `/v1/leaderboard` JSON MUST cover the Rankings table including the work/rewards split, with the bucketed-vs-exact `$` field handled per §6.

### §4 Rollup pipeline

Define the `stats_*` table shapes and refresh cadence:

- `stats_overview_current` — single-row latest snapshot, refreshed every 30s (negotiable in the audit if there's a coordinator-load argument).
- `stats_timeseries_rpm_30m` / `stats_timeseries_tpm_30m` — bucketed 1-minute granularity, 30-row rolling window.
- `stats_leaderboard_<window>` — one row per provider per window, refreshed at the cadence the SPEC chooses; pin a separate cadence for `24h`/`7d` (suggest 1-5 min) versus `30d`/`all` (suggest hourly).
- Late-event correction: define how late-arriving billing rows (e.g. a settlement reconciled 20 minutes after the fact) are reflected — full window recompute, or incremental backfill with a watermark?
- All-time accumulation: `all` is NOT cheap to recompute. Pin whether it's an incremental accumulator (with a written reconciliation procedure for drift) or a nightly full recompute with intra-day staleness allowance.
- Freshness SLA: state the maximum staleness budget for each endpoint and what happens on rollup-job failure (serve stale with `X-Stats-Generated-At` reflecting truth? 503?).

### §5 Auth & rate limits

- Public tier: documented per-IP rate limit (suggest 60 req/min per endpoint, 600 burst), enforced at nginx or Cloudflare; the SPEC MUST pick a layer and justify.
- Partner tier: `Authorization: Bearer <key>` format, key issuance procedure (operator-issued, stored where, rotation policy), per-key rate limit (suggest 600 req/min, 6000 burst), and a stable list of "extra fields" a key unlocks (define them in the leaderboard schema with a `partner_only: true` annotation).
- CORS allowlist: `*` for public endpoints? Just `console.malibu.tech` + `portal.malibu.tech` for the keyed-extra-fields projection? Pin.
- Contract stability statement: which fields are partner-stable (covered by a documented deprecation policy with X-month notice), which are explicitly experimental (and how is that surfaced — `_experimental_` field prefix?).

### §6 Earnings visibility

- Default state for providers: bucketed/ranked `$`. Specify the buckets (e.g. `$$$ ≥ $25 / $$ ≥ $5 / $ < $5` per window, OR rank-only with no `$` at all — pick one and justify).
- Opt-in mechanism: how a provider expresses "show exact `$`" — portal toggle, CLI flag, signed message? v0.1 MAY defer the UI to a separate SPEC-014 follow-up but MUST pin the storage column and the API behaviour change.
- Existing providers at cutover: bucketed by default (no grandfathering of exact-$ display).
- Same-origin view: portal/console authenticated views see exact `$` for the **logged-in provider's own row** regardless of opt-in. Other providers' rows still respect their opt-in state.
- Audit trail: changes to a provider's visibility state MUST be logged with timestamp and the actor that performed the change.

### §7 Hosting & isolation

- Mount path: `/v1/stats/*` under the coordinator binary (default) or a separate public hostname (`stats.malibu.tech`) reverse-proxied to the same binary. Pin one.
- DB access: stats handlers MUST connect with a read-only Postgres role that has SELECT on `stats_*` only and is denied access to billing/session OLTP tables. Define the role name and the migration that creates it.
- Failure isolation: a stats handler panic MUST NOT kill the coordinator process. Specify the recover middleware boundary.
- nginx/Cloudflare config: document the cache directive overrides, rate-limit zones, and any header stripping (e.g. strip `Authorization` from logs on the public tier).
- Read replica: state whether a Postgres read replica is required or whether the rollup job's load on the primary is acceptable. If the primary is fine for v0.1, document the threshold at which a replica becomes mandatory (e.g. `>10k provider rows` or `>1M req/min`).

### §8 Versioning & deprecation

- URL versioning: `/v1/*` is the only public contract surface at v0.1.
- Field additions: backwards-compatible (additive) field additions do NOT require a version bump.
- Field removals or semantic changes: require `/v2/*` introduction with documented overlap period (suggest 6 months minimum).
- Deprecation header: define a `Sunset` and `Deprecation` header pattern per RFC 8594.
- Versioned changelog: pin where it lives (suggest `docs/network-stats-api/CHANGELOG.md`).

## What v0.1 MUST explicitly defer (do not creep)

- **Embed badge** (`<script src=".../badge.js">`). v0.2 work item. Reference it in §1 as future, do not design here.
- **WebSocket/SSE live push.** v0.1 is poll + edge cache. Live push is a v0.3+ concern once partner demand is real.
- **GraphQL surface.** Out of scope. REST + JSON only.
- **Per-provider drill-down** (`/v1/provider/<id>`). Distinct surface, gated on the Earnings sensitivity policy being battle-tested.
- **Authenticated partner dashboards.** Partner-side UIs that need per-key analytics. Not in scope.
- **Cross-region replicas.** Pearl VPS is the single backend in v0.1. Multi-region is a v0.4+ infra concern.
- **Webhook events** (e.g. "provider X passed threshold Y"). Out of scope.

## Files you should read before writing

- `README.md` — current public framing of the network
- `specs/SPEC-002-coordinator.md` — coordinator-side contract; line 3 is current version. Stats handlers mount here.
- `specs/SPEC-005-billing.md` — settlement semantics for what counts as a "request" and what `tokens_out` means. Leaderboard `work` $ derives from this.
- `specs/SPEC-006-buyer-api.md` — public-surface SPEC; house style for `/v1/*` HTTP endpoints. Use as the closest stylistic neighbour.
- `specs/SPEC-014-provider-portal.md` — provider-side read surface; line 3 is current version. The same-origin authenticated $-visibility case interacts with this SPEC.
- `specs/SPEC-016-payout-pipeline.md` — payout flow; the `rewards` $ figure in the leaderboard derives from here. Line 3 is current version (currently 0.1.21 draft as of 2026-06-25, locked version TBD).
- `beta/DECISION_CRITERIA.md` — recent entries for context; the entry that lands SPEC-017 will append here.
- `phase4-coordinator/` (the Go binary) — look for the existing dashboard handlers and how they currently aggregate to confirm the rollup-pipeline scope is right.

## Audit-loop discipline (NON-NEGOTIABLE)

Per the rule documented in `~/.claude/projects/-Users-augstar-macprovider-poc/memory/feedback-spec-audit-loop-before-pr.md` and `feedback-codex-only-audits.md`:

> Freshly-written SPECs go through codex audit → fix → re-audit → loop until 0 CRITICAL/MAJOR BEFORE push/PR. **Audits MUST use codex via `omc ask codex` or `/ccg`, NOT Claude internal subagents** (code-reviewer, security-reviewer, architect). The audit-loop discipline depends on diverse-model lens.

After writing v0.1, your workflow is:

1. Save `specs/SPEC-017-network-stats-api.md` on a feature branch off `origin/main`. Branch name suggestion: `spec/017-network-stats-api-v0-1`. **Per [[feedback-worktree-when-handoff-expected]] and [[sessions-are-worktree-isolated]], do this work in a fresh git worktree.** Do NOT push yet.
2. Author `specs/AUDIT_SPEC_017_V0_1_PROMPT.md` — an audit prompt asking codex to find CRITICAL, MAJOR, MINOR findings against v0.1. Look at `specs/AUDIT_SPEC_016_R20_PROMPT.md` for the recent format.
3. Run the audit via `omc ask codex` (resolve current invocation in `CLAUDE.md` and the `ask` skill if anything has moved).
4. Apply fixes. Bump to v0.1.1 / v0.2 per findings. Write a per-round audit file at `specs/SPEC-017-rN-audit.md` (do NOT inline narrative in the SPEC body). Re-audit.
5. Loop until **0 CRITICAL, 0 MAJOR**. MINORs MAY be deferred if genuinely out of scope but each one MUST be acknowledged in the change log entry.
6. ONLY THEN push the branch and open a PR. Do not skip step 5 even if the original spec-writing prompt (this file) feels exhaustive.

Existing SPECs typically went through 3–5 audit rounds; SPEC-016 went 21. Expect at least 3 rounds here given the public API surface and the privacy/visibility model.

## Open questions to flag (do not resolve in v0.1)

Surface these in a final §"Open questions" section so the audit loop has a clear target:

- **Q1 — Bucket boundaries.** Are `$$$ / $$ / $` the right buckets, and do they get re-anchored as the network scales (e.g. `$$$` means "top 10% earner by window" rather than absolute `$25+`)?
- **Q2 — Partner key issuance UX.** Self-serve via portal, operator-issued via Slack DM, or both? v0.1 can pin "operator-issued only" but the audit will push on this.
- **Q3 — Leaderboard pagination.** Single-shot `limit=N` (suggest `N≤100`) or proper cursor-based pagination? Probably the former for v0.1, but pin the upper bound.
- **Q4 — Anonymization stability.** Are pseudonyms stable across versions/restarts, and what's the rotation policy if a provider requests a new pseudonym (e.g. after a near-deanonymization incident)?
- **Q5 — Mixed-window queries.** Should `/v1/leaderboard?window=24h,7d` (comma list) be supported for partner efficiency, or do partners hit the endpoint twice?
- **Q6 — `stats.malibu.tech` vs `/v1/stats/*` on coordinator host.** Locked decision is "embed in coordinator binary" but the public hostname pattern is still open. Audit will challenge.
- **Q7 — Backfill on cutover.** When SPEC-017 ships, do `7d`/`30d`/`all` windows compute from full historical billing data (backfill required), or from rollup-start-date forward (cleaner but partner-facing values look small for the first 30 days)?

## Quality bar

A great v0.1 reads like SPEC-006 or SPEC-014: every section answers "what does code MUST do, what does it MAY do, what happens on the edge." Every claim has a citation (file:line, RFC number, other SPEC §, screenshot). No "TBD" — defer cleanly with "v0.X+ — out of scope for v0.1, see §X" or push to Open questions.

A bad v0.1 hand-waves rollup cadence, lists endpoints without exact schemas, invents API field names that collide with portal/console internal shapes, or skips the visibility model. The audit loop will catch this; better to catch it yourself first.

## Final deliverables when you're done

1. `specs/SPEC-017-network-stats-api.md` at the version that passed the audit loop with 0 CRITICAL/MAJOR.
2. `specs/AUDIT_SPEC_017_V0_1_PROMPT.md` plus per-round audit files `specs/SPEC-017-rN-audit.md` for every round run.
3. A pushed branch and an open PR linking the SPEC, the audit prompt, and each round's audit file.
4. An appended entry to `beta/DECISION_CRITERIA.md` noting SPEC-017 v0.X LOCKED, what landed, why this v ships now, deferred items.
5. **NO implementation.** v0.1 is normative spec only. Implementation is a separate `BUILD_SPEC_017_IMPL_PROMPT.md`, written after v0.1 locks. Per [[feedback-bundle-spec-impl-one-pr]], the rule about bundling SPEC+IMPL into one PR applies to *downstream incremental versions*, not the net-new v0.1 SPEC — v0.1 ships SPEC-only.

**You're not done when the spec exists. You're done when the audit loop closes and the PR is open.**
