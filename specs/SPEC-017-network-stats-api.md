# SPEC-017 — Network Stats API

**Version:** 0.1.9 (2026-07-29, **LOCKED** — A6 label-honesty patch adds explicit `/v1/stats/overview` source labels for synthetic hardware capacity estimates without changing the 14 numeric metrics. v0.1.8 lock history: codex round-10 returned 0 CRITICAL + 0 MAJOR + 0 MINOR + 0 QUESTIONS, verdict READY TO LOCK. Round 10 narrative: `specs/SPEC-017-r10-audit.md`. Round 9 (initial v0.1.8 draft) returned 0C+2M; v0.1.8 fix pass absorbed M1 (removed `partner_keys.rate_limit_burst` column + CLI flag) and M2 (added §5.6 auth-failure tier + AC-22). r10 closure narrative: `specs/SPEC-017-r10-audit.md`. The v0.1.8 deltas vs v0.1.7 came from the 3-lane IMPL-prompt audit surfacing two SPEC contradictions: (1) §9.4 named rebuild Shape A/B but §7.2.2 grant set lacks the required privileges — v0.1.8 added Shape C (single-tx DELETE+INSERT) executable under locked grants; (2) §5.6 "burst 120" was inconsistent with AC-8 — v0.1.8 dropped burst from both tiers + added Authorization-aware nginx keying + auth-failure tier limiter + AC-22. Trajectory across 10 rounds: r1 3C+10M+5m, r2 2C+5M+2m, r3 0C+4M+3m, r4 0C+4M+2m, r5 0C+2M+2m, r6 0C+1M+1m, r7 0/0/0 → LOCK v0.1.6, r8 0/0/0 → LOCK v0.1.7 (Claude fix pass), r9 0C+2M+0m, r10 0/0/0 → LOCK v0.1.8 (IMPL-audit-driven SPEC fix pass).)
**Status:** **LOCKED** at v0.1.9 (2026-07-29). v0.1.8 was the prior LOCK; v0.1.9 supersedes it for A6 label-honesty source labels while preserving the separately audited v0.1.8 implementation-prompt history. The §11 open questions remain genuine v0.2+ design questions, not v0.1 blockers.
**Depends on:** SPEC-002 v1.4 (coordinator binary hosts the new `/v1/stats/*` mount; §4.2 §7.2 isolation seams), SPEC-005 v0.3 (billing settlement defines `work` $ semantics in §5.1 and tokens-out accounting in §11.4), SPEC-006 v0.9 (version-prefix path style and public-surface conventions; SPEC-017 does NOT claim error-envelope compatibility with SPEC-006 — see §5.9), SPEC-014 v0.8 (provider portal consumes own-provider exact earnings via its own surfaces — visibility-toggle UI is a follow-up SPEC-014 v0.9 candidate, not in this SPEC), SPEC-016 v0.1.19 (payout pipeline; v0.1.19 does NOT normatively define a `rewards` split — SPEC-017 defers that source semantic to operator-defined ledger per §9.1a + Q13).

---

## Change log

Audit-narrative-by-round detail lives in the per-round audit files under
`specs/SPEC-017-rN-audit.md` (one file per codex round). The change-log
entries below are one-liners per version pointing at the corresponding
audit file. Per [[feedback-spec-audit-file-convention]], audit narrative
does NOT live in this SPEC body.

**v0.1.8 (2026-06-26, draft — IMPL-prompt-audit-driven SPEC fix pass):**
The 3-lane codex IMPL-prompt audit on the v0.1.7-anchored IMPL prompt
surfaced two SPEC contradictions that could only be resolved by a
SPEC bump:

- **§9.4 vs §7.2.2 grant mismatch:** §9.4 listed Shape A (TRUNCATE) and
  Shape B (ALTER RENAME + DROP) as the nightly-rebuild atomicity
  shapes, but the locked §7.2.2 `stats_rollup` role has only
  SELECT/INSERT/UPDATE/DELETE on the rollup tables. Both shapes are
  inexecutable. v0.1.8 adds **Shape C** (single-transaction DELETE +
  INSERT) which IS executable under the locked grants. Shapes A and B
  remain documented as alternatives that require an operator-side
  grant widening; Shape C is the v0.1 default. PostgreSQL MVCC
  guarantees the leaderboard handler never observes an empty state
  during the Shape C transaction.
- **§5.6 burst vs AC-8 (v0.1.8 erratum 2026-06-26):** §5.6 v0.1.6/.7
  named "burst 120" for the public tier; v0.1.8 drops the burst
  column from the §5.6 table because long-term burst absorption was
  the actual contract being refuted by AC-8. The mechanically correct
  production directive is `limit_req zone=<name> burst=59 nodelay;`
  — admits exactly 60 immediate, rejects the 61st with 429, and
  refills at strict 1 token/sec so sustained throughput stays at
  60/min. Earlier v0.1.8 SPEC text said "no `burst=` parameter"; that
  was incorrect on nginx semantics (with default burst=0 the bucket
  admits only 1 immediate, failing AC-8's "60 succeed" assertion).
  The locked production posture is `burst=59 nodelay` per the
  erratum in §5.6 below.
- **Authorization-aware nginx keying (v0.1.8 §5.6 addition):** the
  public-tier `limit_req_zone` MUST NOT throttle Authorization-bearing
  requests at the edge (partner-keyed traffic is rate-limited by
  `partner_keys.rate_limit_rpm` in-process per §5.4.7 and would
  otherwise be double-counted). The SPEC pins two acceptable nginx
  shapes (map-based bypass OR split location block) and a companion
  test for the partner-tier no-throttle invariant.

Lock target: codex round-9 against v0.1.8 returns 0/0/0. Round
narrative path: `specs/SPEC-017-r9-audit.md`.

**v0.1.7 (2026-06-26, LOCKED — codex round-8 0/0/0):** Two Claude subagents (critic adversarial
verifier + product designer) audited v0.1.6 against codex's blind spots.
Critic returned 0 CRITICAL + 5 HIGH + 7 MEDIUM (+ LOW omitted per fix
scope); designer returned 2 HIGH + 1 MEDIUM. v0.1.7 absorbs every HIGH
and MEDIUM:

- **H1** (§5.7, §5.2): partner-key projection MUST NEVER emit
  `Access-Control-Allow-Origin: *`. When the matched key has empty
  `allowed_origins` and a browser `Origin` is present, ACAO echoes the
  Origin and emits `Allow-Credentials: true`; when Origin is absent
  (non-browser context), ACAO is omitted entirely. The §5.7 decision
  table is rewritten accordingly.
- **H2** (§5.2): public projection drops `Authorization` from its `Vary`
  header (the response does not branch on it). Only the partner-key
  projection carries `Vary: ..., Authorization`. Edge cache no longer
  fragments by malformed `Authorization` variations.
- **H3** (§5.2): public projection's `totals.earnings_usd` /
  `_work_usd` / `_rewards_usd` are stripped. Public `totals` keeps
  `tokens`, `jobs`, `active_accounts` only. Partner-key projection
  retains exact-$ totals. Removes the correlation attack where
  `totals.earnings_usd` + per-row `rank_earnings` + `tokens` let
  partners back-out approximate exact-$ for bucketed top-N.
- **H4** (§5.2, §9.7): `partial_history_since` is added to the §5.2
  JSON shape and field-level rules. Partner clients MUST tolerate both
  presence and omission.
- **H5** (§5.4.3, AC-18): the Origin-rejection 401 path MUST perform
  the same `sha256 + SELECT by token_hash` work as the no-row 401 path
  before short-circuiting. AC-18 is extended to assert ±20% timing
  equivalence across no-row, revoked, AND rejected-origin 401 paths.
- **M1** (§5.3, §9.1): `timeseries` is split into `timeseries_rpm` and
  `timeseries_tpm` components in `stats_components_health` and in the
  `/v1/stats/health` JSON. The single conflated `timeseries` component
  is removed.
- **M2** (§5.1.1, §9.2): cumulative-vs-windowed semantics pinned.
  `tokens_in_total`, `tokens_out_total`, `requests_total`, and
  `tokens_served_total` (overview) are cumulative all-time counters.
  All `stats_leaderboard_*` figures are windowed. §9.2 source-query
  column rewritten to remove the "or all-time for cumulative fields"
  ambiguity.
- **M3** (§9.1, §9.3): `stats_late_events` retention pinned. The
  nightly job MUST DELETE `stats_late_events` rows older than 90 days
  (operator-configurable, must be ≥30 days).
- **M4** (§5.4.3, §5.7): RFC 6454 ASCII serialization comparison
  pinned. Origin comparison is case-insensitive on scheme and host,
  default ports stripped (`:80` for http, `:443` for https), trailing
  slash/path/query rejected.
- **M5** (§9.4): nightly rebuild MUST execute in a single PostgreSQL
  transaction so the leaderboard never serves a half-rebuilt state.
- **M6** (§6.2): bucket-boundary semantics pinned. Comparisons use the
  `NUMERIC(18,2)` underlying value; bracket notation `[a, b)` means a
  is inclusive and b is exclusive (e.g. `$5.00 → $$`, `$4.99 → $`).
- **M7** (§5.7): `Access-Control-Max-Age` dropped from 3600 to 60 so
  partner-key revocation propagates to browser preflight within a
  minute, not an hour.
- **D-H1** (§6.1, §6.6.2): `blocked_from_partner_projection BOOLEAN`
  column stub added to `provider_visibility`. v0.1 semantics defer to
  v0.2 (rollup does not yet consume the column); the storage shape is
  pinned so v0.2 portal work has somewhere to write. §6.6.2 adds a
  launch-sequencing block: production partner-key issuance under
  §5.4.2 MUST NOT begin until SPEC-014 v0.9 disclosure UI ships.
- **D-H2** (§5.2, §9.1a): top-level `meta.rewards_populated` boolean
  added to `/v1/stats/leaderboard`. Signals whether
  `provider_rewards_ledger` has any rows in the requested window.
  Partner dashboards use this to decide whether to render the rewards
  split or treat it as "rewards data not yet available."
- **D-M1** (§5.2, §6.2, §9.1): per-axis buckets stripped from v0.1.
  Public and partner responses now expose only `earnings_bucket`
  (computed against total `work + rewards`). The
  `earnings_work_bucket` / `earnings_rewards_bucket` JSON fields and
  the matching DB columns are removed; partner-only exact-$
  per-axis (`earnings_work_usd`, `earnings_rewards_usd`) preserves the
  fidelity for trusted partners. §11 Q9 is marked CLOSED (resolved by
  the strip).

Codex round 8 confirmed lock: 0 CRITICAL + 0 MAJOR + 0 MINOR + 0
QUESTIONS, READY TO LOCK. Round narrative: `specs/SPEC-017-r8-audit.md`.

**v0.1.6 (2026-06-25, LOCKED):** Round 7 returned 0 CRITICAL + 0
MAJOR + 0 MINOR + 0 QUESTIONS, verdict READY TO LOCK. v0.1.6 is
the LOCKED v0.1 of the Network Stats API contract — IMPL work is
unblocked. Round-7 closure narrative: `specs/SPEC-017-r7-audit.md`.

**v0.1.6 (2026-06-25, draft — codex round-6 fix pass on v0.1.5):**
Round 6 returned 0 CRITICAL + 1 MAJOR + 1 MINOR. Fixes: M1 added
`GRANT USAGE, SELECT ON SEQUENCE` for every BIGSERIAL backing
sequence (`stats_late_events_id_seq` to `stats_rollup`;
`provider_visibility_audit_id_seq` to `provider_portal`;
`partner_keys_id_seq` is operator-CLI-only and not granted to any
DB role); m1 AC-13 tightened to require exactly 204 (matches §5.7).
Lock target met at r7.

**v0.1.5 (2026-06-25, draft — codex round-5 fix pass on v0.1.4):**
Round 5 returned 0 CRITICAL + 2 MAJOR + 2 MINOR. Fixes: M1 added
`method_not_allowed` (HTTP 405) to §5.9 closed code vocabulary and
AC-21; M2 added SELECT grants to `stats_rollup` on its own
`stats_*` tables to enable §9.3 incremental merge / §9.4 drift
detection without violating role isolation; m1 §7.2.1 cross-ref
§7.2.4 -> §7.2.5; m2 §12 advisor entry de-duplicated.
Lock target: r6 returns 0 CRITICAL + 0 MAJOR.

**v0.1.4 (2026-06-25, draft — codex round-4 fix pass on v0.1.3):**
Round 4 returned 0 CRITICAL + 4 MAJOR + 2 MINOR. Fixes: M1 §1.5 C3
final stale "stats_* only" wording rewritten to point at §7.2.1
request-path grant set; M2 §7.2.2 rollup grant list switched to
implementation-authored non-normative (the placeholder names that
didn't exist in locked deps removed), AC-9 updated to test against
a locked SPEC-005 ledger table; M3 §5.3 health-status thresholds
aligned with §9.6 single source of truth (degraded = beyond §9.5
target, down = beyond §5.8 503 budget); M4 §6.2 split rule for
bucket-boundary changes: reserved-slot additions stay additive,
threshold changes are breaking. m1 §7.2 role count corrected;
§5.4.3 cross-ref §7.2.5 -> §7.2.4. m2 RFC 9745 added to §12.
Full narrative: `specs/SPEC-017-r4-audit.md`.

**v0.1.3 (2026-06-25, draft — codex round-3 fix pass on v0.1.2):**
Round 3 returned 0 CRITICAL + 4 MAJOR + 3 MINOR. Fixes: M1 swept
stale "stats_* only" / "exactly match" / "SELECT-only" wording across
§1.5 C4, §4.2, §5.4.3, §7.2.1, §9.1; replaced §7.2.2 SQL placeholder
with enumerated grants; routed `partner_keys.last_used_at` updates
through a separate role. M2 decoupled CORS preflight from
keyed-GET auth: preflight echoes Origin if it matches any
configured partner allowlist OR returns `*`; per-key allowlist
enforcement remains on GET. M3 §12 reference reworded so SPEC-016
is cited for payout-pipeline context only, rewards semantics points
at §9.1a + Q13. M4 §11 Q2 rewritten as a v0.2+ question ("when and
how to add self-serve") instead of contradicting §5.4.2 v0.1
operator-only rule. m1 noted; m2 §8.3 Deprecation citation also
updated to RFC 9745, and example Unix timestamp corrected to match
the prose date; m3 §6.6.2 cross-ref fixed to Q11 and §11 reordered
numerically. Full narrative: `specs/SPEC-017-r3-audit.md`.

**v0.1.2 (2026-06-25, draft — codex round-2 fix pass on v0.1.1):**
Round 2 returned 2 CRITICAL + 5 MAJOR + 2 MINOR. Fixes: C1 pinned
unambiguous partner-key token format (47 chars total); C2 deferred
rewards-source semantics to operator-defined ledger (Q13 new in §11);
M1 added a CORS decision table covering all six (key, origin)
combinations; M2 removed "additional fields" from §1.1 mission; M3
split §7.2 grant inventories into request-path-readable vs
rollup-internal vs SPEC-017-owned (no more "exactly match" claim);
M4 made §5.9 error envelope self-contained without claiming
SPEC-006 envelope compat; M5 pinned `stale_after = generated_at +
s-maxage` formula on leaderboard; m1 noted (advisor mirror is
sufficient); m2 updated §8.4 to cite RFC 9745 for `Deprecation`.
Full narrative: `specs/SPEC-017-r2-audit.md`.

**v0.1.1 (2026-06-25, draft — codex round-1 fix pass on v0.1):**
Round 1 returned READY-WITH-FIX-PASS at 3/10/5. Fixes: C1 added
normative `stats_*` table shapes (§9.1); C2 added partner-key
issuance/storage/rotation contract (§5.4 + §3.7 expanded); C3
replaced shared-`providers` storage assumption with the new
SPEC-017-owned `provider_visibility` side table (§6.1); MAJORs
M1-M10 absorbed; MINORs m1-m5 absorbed. Full narrative:
`specs/SPEC-017-r1-audit.md`.

**v0.1 (2026-06-25, initial draft):** Initial draft following the
locked design decisions and the structure of the `BUILD_SPEC_017_NETWORK_STATS_API_v0_1_PROMPT.md` write prompt. No audit rounds yet.

---

## 1. Scope

### 1.1 Mission

Publish one stable HTTP contract — under `/v1/stats/*` on the
coordinator — for the macprovider network's read-only summary
statistics, consumed by three classes of clients:

1. `console.streamvc.live` — buyer-facing public web surface.
2. `portal.streamvc.live` — seller-facing provider portal
   (SPEC-014). The portal consumes the same public contract for
   network stats; own-provider exact earnings come from SPEC-014-owned
   surfaces, NOT from a special projection here.
3. **External partners** — third-party websites embedding network
   stats on their own pages, via a documented, versioned, edge-cacheable
   JSON contract.

The mission is **one contract, three consumers**. No bespoke
dashboard endpoints; no partner forks of the schema; no embedded-iframe
special case.

### 1.2 In scope (v0.1)

- `GET /v1/stats/overview` — single-snapshot network counters and 30-minute
  `requests/minute` + `tokens/minute` timeseries.
- `GET /v1/stats/leaderboard` — rolling-window pseudonymized provider
  rankings by `earnings` | `tokens` | `jobs` over `24h | 7d | 30d | all`.
- `GET /v1/stats/provider/<provider_id>` — bearer-gated per-provider
  drill-down. The bearer MUST be bound server-side to the same
  `provider_id`; provider keys are never exposed to browser clients for
  client-side filtering.
- `GET /v1/stats/health` — generated-at timestamp + rollup-pipeline
  liveness signal.
- A rollup pipeline writing into narrow `stats_*` Postgres tables
  consumed exclusively by the API.
- Two-tier auth: public (IP rate-limited) and optional `Authorization:
  Bearer <partner_key>` for higher limits + partner-only fields.
- Bucketed earnings as the default public visibility for `$`, with a
  per-provider opt-in for exact `$` display.
- Embed in the existing coordinator Go binary; no new service.

### 1.3 Out of scope for v0.1

The following are explicit deferrals. The audit loop MUST NOT push these
back into v0.1.

- **Embed badge** (`<script src=".../badge.js">` one-liner). Future
  v0.2+ work item.
- **WebSocket/SSE live push.** v0.1 is HTTP poll + edge cache only.
- **GraphQL surface.** REST + JSON only.
- Provider-owned mutation of the public visibility mode remains out of
  scope; the provider drill-down read surface is server-filtered and
  bearer-bound.
- **Authenticated partner dashboards / per-key analytics UI.**
- **Cross-region replicas.** Pearl VPS is the single backend.
- **Webhook events** (e.g. "provider X passed threshold Y").
- **Buyer-facing leaderboards** (which providers I bought from most).
  Future, distinct SPEC.

### 1.4 Relationship to existing surfaces

This SPEC does NOT modify the existing operator-bearer-gated
**explorer** at `/admin/explorer/*` (SPEC-002 §7.8, implemented at
`phase4-coordinator/internal/explorer/handlers.go`). Explorer is
internal-ops admin; SPEC-017 is public read. Both run inside the same
coordinator binary but use distinct DB roles (§7.2), distinct mount
paths, distinct rate-limit zones, and distinct request loggers.

This SPEC does NOT extend the buyer API (SPEC-006). Buyers do not
consume `/v1/stats/*` on the hot path; SPEC-006 v0.9 remains unchanged.

This SPEC does NOT extend the seller portal contract (SPEC-014). A
SPEC-014 v0.9 candidate follow-up will add the **earnings-visibility
toggle UI** that flips a provider between bucketed (default) and
exact `$` display; v0.1 of this SPEC defines only the storage table
(`provider_visibility`), the API behaviour, and the audit-log shape.

This SPEC does NOT pin the in-repo location of the UI consumer that
will render the Overview and Leaderboard screenshots that motivated
SPEC-017. The current `frontdoor/console/index.html` is a buyer-side
dashboard rendering a different shape; the screenshot-style Network
Statistics widget lives on the vercel preview today (see
[[macprovider-vercel-demo]]). Where the canonical UI consumer
lands at production launch is a downstream UI-SPEC question — see
§11 Q12.

### 1.5 Critical constraints

C1. **Same contract, three consumers.** A field MUST NOT be added only
for one consumer's UI convenience. If console wants a derived view,
console computes it from the same JSON partner sees.

C2. **Public dollar values are bucketed by default.** Pseudonymization
alone is not a privacy model; once network revenue scales, exact `$` per
provider becomes correlatable to real-world operators.

C3. **No request-path queries against billing/session OLTP.** A
stats handler MUST query only the §7.2.1 request-path-readable
grant set (the `stats_*` projections plus the SPEC-017-owned side
tables `partner_keys` and `provider_visibility`) and MUST NOT
issue queries against billing/session/pool OLTP source tables. Hot
OLTP tables stay protected.

C4. **No handler-level access to billing internals.** The stats DB role
has the request-path readable grant set defined in §7.2.1 (a strict
subset that excludes billing/session OLTP).

C5. **Edge-cacheable.** Every `GET` MUST return `Cache-Control` that lets
nginx/Cloudflare serve a non-trivial cached body without contacting the
origin on every request.

C6. **No state mutation.** v0.1 has no `POST`/`PUT`/`DELETE`. All
visibility-toggle writes live on the SPEC-014 portal surface and reach
this SPEC's data only via the SPEC-017-owned `provider_visibility`
side table (§6.1). v0.1 does NOT extend, alter, or assume any
`providers` table in the locked SPEC-002 / SPEC-016 schemas.

---

## 2. Locked decisions (design rationale)

The four picks below are LOCKED at v0.1 per the codex advisor round of
2026-06-25. The audit loop MAY challenge the *details* below each
heading; it MUST NOT challenge the pick itself.

### 2.1 Data source — separate rollup pipeline (Q1: pick B)

A scheduled rollup job inside the coordinator binary reads OLTP
billing/session/pool tables and writes narrow `stats_overview_current`,
`stats_timeseries_*`, and `stats_leaderboard_<window>` tables. The API
queries the §7.2.1 request-path readable set only (the `stats_*`
projections plus the SPEC-017-owned side tables required at request
time; never the OLTP billing/session tables).

**Why this and not (a) materialized views or (c) on-demand:**

- Materialized views refreshing every 30s over hot billing tables would
  serialize against OLTP write paths; the network already has ~1.6M
  requests/window and is climbing.
- On-demand aggregation can't serve the `all`-time window cheaply, and
  partner traffic spikes would land directly on the OLTP planner.
- Rollup tables decouple read latency from write load and give a clean
  place to enforce visibility policy (the rollup itself can produce both
  exact and bucketed columns; the API picks based on the provider's opt-in
  state).

### 2.2 Auth model — public overview, optional keys on leaderboard (Q2: pick B)

- `GET /v1/stats/overview` — fully public, per-IP rate-limited.
- `GET /v1/stats/health` — fully public, per-IP rate-limited.
- `GET /v1/stats/leaderboard` — public for the baseline schema, with an
  optional `Authorization: Bearer <partner_key>` unlocking higher
  rate-limit quotas and a stable set of partner-only fields (§5.4).

**Why this and not (a) fully public or (c) keys required:**

- Data on `/v1/stats/overview` is already broadcast in the public
  console; keys here would add friction without secrecy gain.
- Leaderboard is the scrape-attractive surface and the partner-facing
  surface; keys give the operator attribution, quota control, abuse
  handling, and a path to ship partner-only fields without forking the
  schema.

### 2.3 Earnings visibility — bucketed default + provider opt-in (Q3: pick B)

The public `/v1/stats/leaderboard` body never includes exact `$` for a
provider whose `provider_visibility.mode = 'bucketed'` (or who has no
`provider_visibility` row at all). Buckets per window are defined in
§6.2. Providers MAY opt in via the SPEC-014 v0.9 portal toggle to
surface exact `$` publicly; the `provider_visibility.mode` column
governs which path the rollup produces (§6.1).

The portal MUST surface own-provider exact `$` to the logged-in
provider via SPEC-014-owned surfaces (e.g. the portal earnings
dashboard), NOT via a special projection of `/v1/stats/leaderboard`.
This endpoint serves the same JSON regardless of `Origin`; see §6.4
for the uniformity invariant.

**Why this and not (a) fine-as-is or (c) strip-all-$:**

- Pseudonyms (`beamy-puppy-4259`) are stable across windows and partially
  deanonymizable by a sophisticated correlator; once `$52/7d` becomes
  `$520/7d`, the disclosure stops being benign.
- Tokens and jobs remain visible for network transparency — buyers and
  partners can still tell big providers from small.
- Provider consent for exact-$ display is the privacy-correct default.

### 2.4 Hosting — embed in coordinator binary (Q4: pick A)

`/v1/stats/*` mounts inside the existing coordinator Go binary on the
Pearl VPS, behind the existing nginx fronting `coordinator.streamvc.live`
and a new `stats.streamvc.live` server-block that reverse-proxies to the
same binary on the same path. No new long-running service.

**Why this and not (b) split service or (c) static snapshot:**

- 30–60s edge caching plus precomputed `stats_*` tables makes the
  request-path cost negligible.
- Operator-tax for another service (binary, systemd unit, deploy
  pipeline, monitoring) is not justified by current traffic or by any
  security threat model that survives §7.2 isolation.
- A pure static-snapshot solution loses the partner API-key tier (which
  needs request-time auth) and the partner-only field projections.

---

## 3. Terms and definitions

### 3.1 Stats consumer

Any HTTP client reading `/v1/stats/*`. Three classes:

- **Console** — `console.streamvc.live` (buyer-facing public web).
- **Portal** — `portal.streamvc.live` (provider portal, SPEC-014).
- **Partner** — any third-party origin; treated as fully external.

### 3.2 Rollup window

One of `24h | 7d | 30d | all`. All rolling, ending at the rollup
snapshot's `generated_at` (NOT calendar-day-aligned, NOT month-aligned).

### 3.3 Pseudonym

A stable opaque string per provider (e.g. `beamy-puppy-4259`). Stable
across windows and across `generated_at` snapshots. Rotation is an open
question (Q4 of §11).

### 3.4 Bucketed earnings

A coarse, non-monotonic surrogate for exact `$` per window. v0.1
defines three buckets per window per metric (`$`/`$$`/`$$$`) keyed by
absolute thresholds (§6.2).

### 3.5 Exact earnings

The `$` value in USD with two-decimal precision, summed over the
window. The window is the same rolling-window definition as §3.2.

### 3.6 Public earnings mode

A SPEC-017-owned row in the new `provider_visibility` side table
(§6.1) with `mode IN ('bucketed','exact')`. Default for any
provider absent from `provider_visibility`, or present with
`mode = 'bucketed'`, is **bucketed**. Changes are logged to
`provider_visibility_audit` (§6.5).

### 3.7 Partner key

An opaque bearer token issued by the operator. Format:

```
mpk_<43 chars of unpadded base64url(32 random bytes)>
```

Exactly:

- 4-character literal namespace prefix `mpk_`.
- 43 characters of unpadded base64url (RFC 4648 §5) encoding of 32
  cryptographically random bytes (32 bytes = 256 bits of entropy).
  Unpadded base64url of 32 bytes is `ceil(32 × 4 / 3) − 0` = 43
  characters (the standard padded length is 44; v0.1 strips the
  trailing `=`).
- Total token length: 47 characters. Validation MUST reject any
  token whose length is not 47, whose first 4 characters are not
  `mpk_`, or whose remaining 43 characters contain any character
  outside `[A-Za-z0-9_-]`.

Full contract — issuance, hashed storage, rotation, revocation,
allowed-origin validation, rate-limit keying — is pinned in §5.4.
The token MUST NOT appear in any log line, response body, or metric
label; only its `partner_keys.id` (opaque, non-secret) and
`partner_keys.label` MAY appear.

### 3.8 Edge cache

The HTTP cache enforced by nginx and/or Cloudflare in front of the
coordinator. Origin response `Cache-Control` and `Vary` headers drive
edge behaviour; nginx/CF MAY override `max-age` downward for incident
response but MUST NOT lengthen it.

---

## 4. Architecture

### 4.1 Service topology

```
   ┌─ console.streamvc.live ─┐
   │                          │
   │ portal.streamvc.live ────┼──► nginx (Pearl) ──► coordinator binary
   │                          │     (TLS, rate-zone,    │
   │ stats.streamvc.live ─────┘      edge cache)         ├─► /admin/explorer/* (existing)
   │                                                     │
   │ <partner origins>  ────────► Cloudflare ──► nginx ──┴─► /v1/stats/*  (new)
   └──────────────────────────                                │
                                                              └─► stats_* tables (read-only role)
                                                                         ▲
                                                                         │
                                                              rollup job ┴── billing/session/pool tables
```

`/v1/stats/*` lives inside the same Go process as the existing
explorer. Both reach Postgres but via distinct DB roles; see §7.2.

### 4.2 New components

- `phase4-coordinator/internal/stats/` — new Go package for the public
  handlers. MUST NOT import `phase4-coordinator/internal/billing/` or
  `phase4-coordinator/internal/explorer/`.
- `phase4-coordinator/internal/stats/rollup/` — new subpackage for the
  rollup job. MAY import billing/session/pool packages (read-only) since
  it runs out-of-band, not on the request path.
- `phase4-coordinator/internal/stats/store/` — narrow read-only DAO over
  `stats_*` tables, used exclusively by handlers.
- Postgres role `stats_reader` — `SELECT` on the request-path
  readable set defined in §7.2.1 (`stats_*` projections + the
  SPEC-017-owned side tables needed at request time); explicitly
  denied on billing/session/pool tables. Created by a new migration
  in §7.2.
- nginx server-block for `stats.streamvc.live` reverse-proxying to the
  same coordinator backend on `/v1/stats/*`, with a dedicated rate-limit
  zone (§5.6).

### 4.3 Wire surface summary

| Endpoint | Auth | Cacheable | Partner-only fields |
|---|---|---|---|
| `GET /v1/stats/overview` | None | yes, public | no |
| `GET /v1/stats/leaderboard` | Optional `Bearer <partner_key>` | yes; key MAY unlock a separate cache projection | yes, behind key |
| `GET /v1/stats/provider/<provider_id>` | Required `Bearer <partner_key>` bound to `provider_id` | no; private only | yes, for that provider only |
| `GET /v1/stats/health` | None | short cache (10s) | no |

`HEAD` MUST be supported on every `GET`. `OPTIONS` MUST return CORS
preflight per §5.7. Any other verb MUST return `405 Method Not Allowed`
with `Allow: GET, HEAD, OPTIONS`.

---

## 5. Endpoints — exact wire shape

### 5.1 `GET /v1/stats/overview`

**Request.**

- No path parameters.
- No required query parameters.
- Optional query: none in v0.1; unknown query parameters MUST be
  ignored (not rejected) to keep the contract forward-compatible.
- Headers: `Accept: application/json` (default if omitted), `Origin`
  (preflight handled per §5.7).

**Response (200 OK).**

```json
{
  "generated_at": "2026-06-25T18:14:00Z",
  "stale_after": "2026-06-25T18:14:30Z",
  "network": {
    "tokens_served_total": 4431300000,
    "tokens_in_total":      3419800000,
    "tokens_out_total":     1011500000,
    "requests_total":       1600000,
    "nodes_online":         327,
    "nodes_hardware_attested": 286,
    "bandwidth_gb_per_s":   148953,
    "network_power_kw":     50.8,
    "network_utilization_pct": 18,
    "gpu_cores_total":      11636,
    "cpu_cores_total":      5190,
    "unified_ram_gb_total": 30068,
    "avg_tokens_per_request": 2848,
    "models_serving":       5,
    "capacity_estimate_sources": {
      "bandwidth_gb_per_s": "estimated_from_hardware_profile_or_provider_reported_summary",
      "network_power_kw": "estimated_from_hardware_profile_or_provider_reported_summary",
      "gpu_cores_total": "estimated_from_hardware_profile_or_provider_reported_summary",
      "cpu_cores_total": "estimated_from_hardware_profile_or_provider_reported_summary",
      "unified_ram_gb_total": "provider_reported_or_profiled"
    }
  },
  "timeseries": {
    "rpm_30m": {
      "bucket_seconds": 60,
      "points": [
        {"t":"2026-06-25T17:45:00Z","value": 73},
        {"t":"2026-06-25T17:46:00Z","value": 81}
      ]
    },
    "tpm_30m": {
      "bucket_seconds": 60,
      "points": [
        {"t":"2026-06-25T17:45:00Z","input_tokens": 92000, "output_tokens": 28000}
      ]
    }
  }
}
```

**Field-level normative rules.**

- `generated_at` — RFC 3339 UTC timestamp of the rollup snapshot used to
  produce this body. MUST match `stats_overview_current.generated_at`
  exactly.
- `stale_after` — `generated_at + Cache-Control: s-maxage`. Clients MAY
  use this as a hint; servers do not enforce.
- `network.*` — integers and floats per the table in §5.1.1, plus the
  `capacity_estimate_sources` label object. The label object is
  operator-facing metadata; it is not a hardware attestation signal.
- `timeseries.rpm_30m.points` — exactly 30 points, one per minute,
  newest last. If the rollup pipeline has fewer than 30 minutes of
  history (e.g. cold start), the array MUST still be exactly 30 entries
  long with `"value": null` for the missing minutes (NOT zero — null
  distinguishes "no data" from "zero traffic").
- `timeseries.tpm_30m.points` — same shape but with `input_tokens` and
  `output_tokens` instead of `value`.

**Response headers.**

- `Content-Type: application/json; charset=utf-8`
- `Cache-Control: public, max-age=30, s-maxage=30, stale-while-revalidate=60`
- `ETag: W/"<sha256-of-body>"` (weak ETag; computed once per rollup
  snapshot and reused until `generated_at` advances)
- `X-Stats-Generated-At: 2026-06-25T18:14:00Z` (mirrors body field for
  cache key debugging)
- `Vary: Accept-Encoding, Origin` (no `Authorization` — overview ignores
  it)

**Errors.**

- `503 Service Unavailable` — see §5.8.

### 5.1.1 Overview field schema

All `_total` fields below are **cumulative all-time counters** (since
rollup-start), NOT 24h-windowed values. They mirror the cumulative-
counter mental model partners and operators expect from a "total"
suffix. The `stats_leaderboard_*` figures (§5.2, §9.1) are **windowed**;
the suffix distinction is normative.

| Field | Type | Unit | Semantics | Source |
|---|---|---|---|---|
| `tokens_served_total` | int64 | tokens | cumulative all-time | `stats_overview_current.tokens_in + tokens_out` |
| `tokens_in_total` | int64 | tokens | cumulative all-time | `stats_overview_current.tokens_in` |
| `tokens_out_total` | int64 | tokens | cumulative all-time | `stats_overview_current.tokens_out` |
| `requests_total` | int64 | count | cumulative all-time | `stats_overview_current.requests` |
| `nodes_online` | int32 | count | live (point-in-time snapshot) | live pool registry snapshot, cached 30s |
| `nodes_hardware_attested` | int32 | count | live (point-in-time snapshot) | subset of `nodes_online` with `attestation_ok = true` |
| `bandwidth_gb_per_s` | int64 | GB/s | live (point-in-time snapshot) | sum of `provider_bandwidth_gbps` over online nodes |
| `network_power_kw` | float64 | kW | live (point-in-time snapshot) | sum of `provider_estimated_power_kw` over online nodes |
| `network_utilization_pct` | int32 | percent (0–100) | recent-window load average | recent-window load average |
| `gpu_cores_total` | int32 | count | live (point-in-time snapshot) | sum over online providers |
| `cpu_cores_total` | int32 | count | live (point-in-time snapshot) | sum over online providers (P+E) |
| `unified_ram_gb_total` | int32 | GB | live (point-in-time snapshot) | sum over online providers |
| `avg_tokens_per_request` | int32 | tokens | cumulative all-time | `tokens_served_total / max(1, requests_total)` |
| `models_serving` | int32 | count | live (point-in-time snapshot) | distinct `model_id` advertised by ≥1 online provider |
| `capacity_estimate_sources` | object | labels | source metadata | stable string labels for synthetic capacity fields; `bandwidth_gb_per_s`, `network_power_kw`, `gpu_cores_total`, and `cpu_cores_total` MUST be labeled as estimates derived from hardware profiles or provider-reported hardware summaries, not as attested inventory |

All integer fields MUST fit in JSON-safe `int64` (≤ 2^53 − 1). The
rollup MUST clamp at ingestion if any source overflows; clamp events
MUST be logged.

### 5.2 `GET /v1/stats/leaderboard`

**Request.**

- Optional query:
  - `window` — one of `24h | 7d | 30d | all`. Default `24h`. Invalid
    values return `400`.
  - `sort` — one of `earnings | tokens | jobs`. Default `earnings`.
    Invalid values return `400`.
  - `limit` — integer `[1, 100]`. Default `50`. Invalid (non-integer,
    out of range) returns `400`.
- Headers: `Accept`, optional `Authorization: Bearer <partner_key>`.
- An invalid or revoked `Authorization` header returns `401`. An
  absent `Authorization` header is fine; it just routes through the
  public projection.

**Response (200 OK, public projection).**

```json
{
  "generated_at": "2026-06-25T18:14:00Z",
  "stale_after":   "2026-06-25T18:15:00Z",
  "window":        "30d",
  "sort":          "earnings",
  "limit":         50,
  "partial_history_since": "2026-04-12T00:00:00Z",
  "meta": {
    "rewards_populated": false
  },
  "totals": {
    "tokens":            2525400000,
    "jobs":              900700,
    "active_accounts":   302
  },
  "rows": [
    {
      "rank": 1,
      "pseudonym": "beamy-puppy-4259",
      "earnings_bucket": "$$$",
      "tokens": 119900000,
      "jobs":   55300,
      "exact_earnings": null
    }
  ]
}
```

**Field-level normative rules.**

- `generated_at` — RFC 3339 UTC timestamp of the rollup snapshot used
  to produce this body. MUST match
  `stats_leaderboard_<window>.generated_at` for the requested window.
- `stale_after` — formula: `generated_at + Cache-Control: s-maxage`
  (i.e. for the public projection's `s-maxage=60`, `stale_after =
  generated_at + 60s`). Mechanically derivable; partners SHOULD use
  it as a "display freshness indicator" rather than a hard
  invalidation deadline. NOTE: this is NOT the §9.5 target staleness
  (which is the rollup-side budget) and NOT the §5.8 503 budget
  (which is the hard staleness ceiling); the three are intentionally
  distinct timescales.
- `partial_history_since` — optional, RFC 3339 UTC. Present iff the
  operator chose §9.7 Path A (partial backfill) AND the rollup's
  earliest in-window data point is more recent than the canonical
  window start (e.g. for `window=30d`, less than 30 days of history
  has accumulated). Once the rollup has fully overlapped its window,
  the field MAY be omitted (additive removal, NOT a breaking change
  per §8.2). Partner clients MUST tolerate both presence and
  omission and SHOULD surface a "window is short" badge in their UI
  while the field is present. See §9.7 for the operator-side
  emission rule.
- `meta.rewards_populated` — boolean. `true` iff
  `provider_rewards_ledger` (§9.1a) has at least one row with
  `unix_ts` inside the requested window. `false` otherwise (including
  the v0.1 cutover state where the ledger ships empty). When `false`,
  every row's `earnings_rewards_usd` (partner projection) is `0.00`
  by construction; partner dashboards SHOULD treat the rewards split
  as "not yet available" rather than as a meaningful zero. The field
  is REQUIRED in every response — partners MAY rely on it without a
  presence check.
- `pseudonym` — stable per provider across snapshots and across windows
  (§3.3). Length ≤ 32 chars, `[a-z0-9-]` only.
- `earnings_bucket` — one of `"$"`, `"$$"`, `"$$$"`, or the string
  `"-"` (provider had zero `$` in the window). Values defined in
  §6.2. v0.1 ships only this single-axis bucket; per-axis
  (work/rewards) buckets are NOT exposed publicly to avoid the
  combined-axis disclosure leak §11 Q9 previously deferred. Partners
  who need the work/rewards split MUST use the partner-key
  projection's exact-$ fields below.
- `exact_earnings` — single-axis exact USD figure for total earnings
  (`work + rewards`), with two-decimal precision. ALWAYS present in
  the JSON to keep the schema stable across opt-in changes; value is
  `null` in the public projection unless the provider has
  `provider_visibility.mode = 'exact'`, in which case it is the USD
  float. Per-axis exact-$ split is partner-key-only.
- `totals.tokens / totals.jobs / totals.active_accounts` — windowed
  sums over the same `(window, sort, limit)` page. `tokens` and
  `jobs` are int64 windowed sums; `active_accounts` is the distinct
  count of providers with `≥1 job` in the window. Public projection
  does NOT expose `totals.earnings_*` — windowed exact-$ totals are
  partner-key-only (§5.2 partner projection) to prevent the
  `totals.earnings_usd / rank_earnings / tokens` correlation attack
  on bucketed top-N providers.
- `rank` — 1-based within the returned page, recomputed against the
  selected `sort` axis.

**Response (200 OK, partner-key projection).**

Identical to the public projection, with the following additive
fields:

```json
{
  "totals": {
    "earnings_usd":        1300.0,
    "earnings_work_usd":     77.0,
    "earnings_rewards_usd": 1223.0,
    "tokens":          2525400000,
    "jobs":               900700,
    "active_accounts":       302
  },
  "rows": [
    {
      "earnings_usd":         52.00,
      "earnings_work_usd":     3.87,
      "earnings_rewards_usd": 48.13,
      "first_seen_at":        "2026-04-12T11:24:00Z",
      "last_seen_at":         "2026-06-25T18:01:00Z"
    }
  ]
}
```

`totals.earnings_usd / earnings_work_usd / earnings_rewards_usd`
(windowed exact-$ sums) and the per-row `earnings_usd /
earnings_work_usd / earnings_rewards_usd / first_seen_at /
last_seen_at` are partner-key-only. They surface exact `$` for ALL
providers regardless of `provider_visibility.mode`. This is a
deliberate trade: the partner key acts as an attribution and
accountability surface (operator can revoke), in exchange for
trusted exposure of bucketed providers' exact figures. See §6.6 for
the legal posture this requires AND the launch-sequencing
precondition (§6.6.2: partner-key issuance MUST NOT begin in
production until SPEC-014 v0.9 disclosure UI ships).

**Deprecation note.** The broad partner-key leaderboard projection is
kept for one release cycle for existing dashboards. New browser
clients MUST use `/v1/stats/provider/<provider_id>` for exact
per-provider earnings. That route performs server-side filtering from
the bearer's `partner_keys.provider_id` binding and returns `403` when
the path provider does not match the bearer. No partner key or provider
filter secret may be shipped to browser code for client-side filtering.

**Response headers (public projection).**

- `Content-Type: application/json; charset=utf-8`
- `Cache-Control: public, max-age=60, s-maxage=60, stale-while-revalidate=120`
- `Vary: Accept-Encoding, Origin` (NOT `Authorization` — the public
  projection does not branch on it; including `Authorization` here
  would fragment edge cache by every malformed/probe `Authorization`
  variation)
- `ETag: W/"<sha256-of-body>"`
- `X-Stats-Generated-At: <generated_at>` (mirrors the `generated_at`
  field for cache-key debugging; partner clients MUST tolerate this
  header on every `/v1/stats/*` response)

**Response headers (partner-key projection).**

- Same as above EXCEPT:
  - `Cache-Control: private, max-age=30, s-maxage=30` (the partner
    projection MUST NOT be cached by any shared cache).
  - `Vary: Accept-Encoding, Origin, Authorization` (the partner
    projection branches on `Authorization`; `Vary: Authorization`
    here is meaningful because the underlying cache directive is
    `private`, so the only consumer of `Vary` is the partner's own
    browser/SDK cache).
  - `Access-Control-Allow-Origin` — see §5.7. The partner-key
    projection MUST NEVER emit `Access-Control-Allow-Origin: *`
    because §5.7 row 4 mandates `Access-Control-Allow-Credentials:
    true`, and per the Fetch spec a credentialed response with
    `Allow-Origin: *` is rejected by browsers. The handler echoes
    the matched `Origin` (with empty `allowed_origins`, the Origin
    is echoed as-presented after RFC 6454 normalization; with
    non-empty `allowed_origins`, the request is rejected at auth
    unless Origin exact-matches an allowlist entry per §5.4.3).
  - When `Authorization` is present-and-valid but `Origin` is absent
    (server-to-server context), `Access-Control-Allow-Origin` is
    omitted entirely. Browsers don't reach this code path; non-browser
    partner clients ignore CORS headers.
- nginx-level rate-limit zones MUST be keyed on `partner_keys.id`, not
  on the raw token (§5.6 and §5.4.7).

**Errors.**

- `400` invalid `window`/`sort`/`limit`
- `401` invalid or revoked `Authorization`
- `429` rate limit exceeded (§5.6)
- `503` rollup stale beyond §5.8 budget

### 5.2a `GET /v1/stats/provider/<provider_id>`

Returns exact windowed stats for one provider. The request MUST carry
`Authorization: Bearer <partner_key>`, and the matched `partner_keys`
row MUST have `provider_id = <provider_id>`. Missing bearer returns
`401`; a valid bearer bound to a different provider returns `403` with
the `unauthorized` error code from §5.9. Successful responses are
`Cache-Control: private, max-age=30, s-maxage=30` and `Vary:
Accept-Encoding, Origin, Authorization`.

The route exists so browser clients do not receive a partner key and
then filter an all-provider exact leaderboard client-side. The server
performs the provider binding and returns only the requested provider's
row.

### 5.3 `GET /v1/stats/health`

**Request.** No query parameters, no auth.

**Response (200 OK).**

```json
{
  "status": "ok",
  "generated_at":      "2026-06-25T18:14:00Z",
  "rollup_lag_seconds": 12,
  "components": {
    "overview":         {"status": "ok", "generated_at": "2026-06-25T18:14:00Z"},
    "timeseries_rpm":   {"status": "ok", "generated_at": "2026-06-25T18:14:00Z"},
    "timeseries_tpm":   {"status": "ok", "generated_at": "2026-06-25T18:14:00Z"},
    "leaderboard_24h":  {"status": "ok", "generated_at": "2026-06-25T18:13:00Z"},
    "leaderboard_7d":   {"status": "ok", "generated_at": "2026-06-25T18:10:00Z"},
    "leaderboard_30d":  {"status": "ok", "generated_at": "2026-06-25T17:30:00Z"},
    "leaderboard_all":  {"status": "ok", "generated_at": "2026-06-25T17:00:00Z"}
  }
}
```

The `components` map has exactly 7 entries (`overview`,
`timeseries_rpm`, `timeseries_tpm`, and four `leaderboard_*` keys).
The earlier single `timeseries` key is removed because the two
timeseries tables (§9.1 `stats_timeseries_rpm_30m` /
`stats_timeseries_tpm_30m`) drift independently and conflating them
hides single-axis rollup-job failure. Partners reading the health
JSON MUST match exact keys; an unknown key is treated as a new
additive component per §8.2.

**Field-level rules.**

- `status` — `"ok"` if every component is within its SLA (§9.5 target
  staleness), `"degraded"` if any component is beyond target,
  `"down"` if `overview` or `leaderboard_24h` is beyond its §5.8 503
  budget.
- `rollup_lag_seconds` — wall-clock seconds between now and the oldest
  component's `generated_at`.

**Response headers.**

- `Cache-Control: public, max-age=10, s-maxage=10` (intentionally
  short: health is meant to drift in real time).
- `Vary: Accept-Encoding, Origin`
- `X-Stats-Generated-At: <generated_at>` (mirrors body field)

**Errors.** This endpoint MUST return `200` even when components are
degraded — partners use the JSON `status` field to drive their own UI.
A non-200 response from `/health` means the coordinator process itself
is unhealthy, not the rollup.

### 5.4 Partner-key contract

A partner key is an opaque bearer token (§3.7). The full lifecycle —
issuance, hashed storage, rotation, revocation, allowed-origin
validation, and rate-limit keying — is pinned in this section. The
implementation MUST honor every clause; the contract is partner-facing
and not negotiable per partner.

#### 5.4.1 `partner_keys` table

```sql
CREATE TABLE partner_keys (
  id                BIGSERIAL PRIMARY KEY,
  label             TEXT NOT NULL,
  token_hash        BYTEA NOT NULL,
  token_hash_alg    TEXT NOT NULL DEFAULT 'sha256',
  prefix            TEXT NOT NULL,
  provider_id       TEXT,
  allowed_origins   TEXT[] NOT NULL DEFAULT '{}',
  rate_limit_rpm    INT  NOT NULL DEFAULT 600,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by        TEXT NOT NULL,
  revoked_at        TIMESTAMPTZ,
  revoked_reason    TEXT,
  rotated_from_id   BIGINT REFERENCES partner_keys(id),
  last_used_at      TIMESTAMPTZ,
  UNIQUE (token_hash)
);
CREATE INDEX ON partner_keys (prefix);
CREATE INDEX ON partner_keys (provider_id) WHERE provider_id IS NOT NULL;
```

The `partner_keys.id BIGSERIAL` backing sequence
(`partner_keys_id_seq`) is consumed only by the operator CLI
(`coordinator partner-keys issue`, §5.4.2) and the optional
`partner_keys_writer` role (§7.2.4) does NOT need sequence USAGE
since its grant is UPDATE-only on a single column. The CLI runs as
the database superuser or as a dedicated migration role outside
the runtime role inventory; v0.1 does NOT pin which (this is an
operator-deployment detail).

Field rules:

- `token_hash` — `sha256` of the raw token bytes, stored binary, NOT
  the raw token. The raw token MUST NOT be persisted server-side
  anywhere; once shown to the operator at issuance time it is unrecoverable.
- `prefix` — the first 8 characters of the raw token (including the
  `mpk_` namespace). Stored for log-correlation and last-4 display
  in operator tooling, NOT for auth.
- `provider_id` — optional server-side binding for
  `/v1/stats/provider/<provider_id>`. A key without this binding cannot
  access provider drill-down, even if it remains temporarily accepted
  for the deprecated broad partner leaderboard projection.
- `allowed_origins` — an array of exact-match origin strings (e.g.
  `https://partner.example.com`). Empty array means "no Origin
  restriction" — public partner usage from any origin. See §5.7 CORS
  rules for how this interacts with browser-side embedding.
- `rate_limit_rpm` — per-key per-endpoint hard limit. The operator
  MAY set a higher value per key; the API MUST clamp to the
  configured value from `partner_keys`, not to a global default. There
  is NO burst column on the partner-key path in v0.1.8 (dropped to
  match the §5.6 hard-limit/no-burst reconciliation with AC-8;
  earlier drafts had `rate_limit_burst INT DEFAULT 1200` which was
  inconsistent with the v0.1.8 deterministic 601st-returns-429 rule).
- `revoked_at` — once set, the key MUST be rejected with 401. Lookup
  is by `token_hash`, so a revoked key cannot be reactivated by clearing
  `revoked_at` without operator action.
- `rotated_from_id` — when a key is rotated (§5.4.4), the new key row
  points at the predecessor for audit-trail continuity.

#### 5.4.2 Issuance flow (v0.1)

v0.1 issuance is **operator-driven only**. Self-serve issuance is
deferred to a future SPEC-014 v0.10+ candidate (referenced in §11
Q2). Concretely:

1. Operator runs a coordinator CLI subcommand
   `coordinator partner-keys issue --label "Acme Corp dashboard"
   [--allowed-origin https://acme.example.com] [--rpm 600]`. v0.1.8
   removed the `--burst` flag — there is no per-key burst column
   anymore.
2. The subcommand:
   a. Generates 32 cryptographically random bytes via the system
      CSPRNG.
   b. Encodes those bytes as 43-character unpadded base64url (RFC
      4648 §5 alphabet, no `=` padding).
   c. Prefixes with `mpk_` to form the 47-character raw token.
   d. Computes `sha256(raw_token_utf8_bytes)`.
   e. INSERTs into `partner_keys` with `token_hash = <that sha256>`,
      `prefix = <first 8 characters of raw_token>` (always begins
      with `mpk_`), and the operator-provided label/origin/limits.
   f. Prints the raw token to stdout exactly once.
3. The operator delivers the token to the partner via a side channel
   (email, signed message). The repository never persists the raw
   token.

#### 5.4.3 Authentication on request — decision table

The branch on `(Authorization header, Origin header)` is fully
enumerated below. Implementations MUST match this table exactly;
prose ambiguity in earlier drafts is superseded here.

| Authorization | partner_keys row | Origin | Result |
|---|---|---|---|
| absent | n/a | n/a | **200 public projection** (no key path). |
| present, hash matches a row, `revoked_at IS NULL`, `allowed_origins = '{}'` (empty array) | matched, active | absent or any value | **200 partner projection**. CORS per §5.7. |
| present, hash matches a row, `revoked_at IS NULL`, `allowed_origins` non-empty | matched, active | absent | **401 `unauthorized`**. Non-empty allowlist requires an Origin header. |
| present, hash matches a row, `revoked_at IS NULL`, `allowed_origins` non-empty | matched, active | exact-match in `allowed_origins` | **200 partner projection**. CORS echoes `Origin`. |
| present, hash matches a row, `revoked_at IS NULL`, `allowed_origins` non-empty | matched, active | not in `allowed_origins` | **401 `unauthorized`** (NOT 403; avoids leaking key existence to non-allowlisted Origins). |
| present, hash does NOT match a row | none | any | **401 `unauthorized`**. |
| present, hash matches a row, `revoked_at IS NOT NULL` | matched, revoked | any | **401 `unauthorized`** (handler MUST NOT distinguish from "no match" in response shape or latency). |

Operational rules:

1. The handler MUST compute `sha256(<token>)` and SELECT by
   `token_hash` for every keyed request; there is no in-memory key
   cache in v0.1.
2. The handler MAY update `last_used_at` on success (best effort,
   not transactional with the response). Because `stats_reader` has
   only SELECT on `partner_keys` (§7.2.1), this UPDATE MUST be
   dispatched to a separate, narrowly-grant-scoped role
   `partner_keys_writer` (§7.2.4) — typically via a background
   channel/queue, NOT inline on the response path. v0.1
   implementations MAY also simply skip the `last_used_at` update
   if the operator decides the audit value is not worth the extra
   role.
3. On success, all rate-limit accounting (§5.6) MUST key on
   `partner_keys.id`, NOT on the raw token or on the client IP.
4. **Timing-equivalence (binding):** the 401 latencies for "no row"
   (no `token_hash` match), "revoked" (match with `revoked_at IS NOT
   NULL`), and "rejected origin" (match with non-empty
   `allowed_origins` whose entries do not contain a normalized Origin)
   MUST all be indistinguishable within ±20% (AC-18). This forces the
   handler to perform the SAME `sha256 + SELECT by token_hash` work
   on every 401 path. The "rejected origin" path MUST NOT
   short-circuit on the Origin check before doing the hash+SELECT —
   doing so would let an attacker confirm a key's existence by
   timing a rejected-Origin probe against a non-existent-key probe.
5. **RFC 6454 Origin normalization:** all Origin comparisons (this
   section + §5.7 preflight) MUST normalize per RFC 6454 §6.2 ASCII
   serialization before comparing:
   - Scheme is lowercased.
   - Host is lowercased; IDN MUST be ASCII-encoded (Punycode) first.
   - Default ports are stripped (`:80` for http, `:443` for https).
   - Trailing slash, path, query string, or fragment makes the
     header malformed; the handler MUST treat such an Origin header
     as if absent (and apply the "absent Origin" branch from the
     §5.4.3 decision table).
   The `allowed_origins` array values are operator-supplied at CLI
   issuance time and MUST already be in this normalized form;
   `coordinator partner-keys issue` MUST reject any
   `--allowed-origin` value that does not parse to its own
   normalized form (idempotency check).

Note on the "absent Origin + non-empty allowlist" rule: this is the
deliberate choice that a non-empty `allowed_origins` array means
"this key is intended for browser-side embedding only; reject any
non-browser context." A partner who wants both browser and
server-side usage MUST be issued either two keys or one key with
`allowed_origins = '{}'`.

#### 5.4.4 Rotation

Operator rotates a key by issuing a new key with
`--rotate-from <existing_id>`. The CLI MUST:

1. INSERT a new row with `rotated_from_id = <existing_id>`.
2. Leave the old row's `revoked_at` NULL initially (overlap window).
3. Print the new raw token to stdout exactly once.

The operator MAY set `revoked_at` on the predecessor at any time via
`coordinator partner-keys revoke --id <id> --reason "rotated"`. v0.1
does not pin a maximum overlap window; the operator MUST document
revocation cadence in the partner's onboarding email.

#### 5.4.5 Revocation

`coordinator partner-keys revoke --id <id> --reason "<text>"` sets
`revoked_at = now()` and `revoked_reason = <text>`. Revocation takes
effect on the next request; v0.1 does NOT define a cache invalidation
mechanism (the per-request lookup IS the revocation enforcement
point).

#### 5.4.6 Log redaction

No log line — application, nginx, journald, metric label, or trace
span — MAY contain the raw token, `token_hash`, or any substring of
the random portion. The `prefix` field (8 chars) MAY appear in logs
for correlation. The `partner_keys.id` and `partner_keys.label` MAY
appear in logs.

#### 5.4.7 Cache keying interaction

The partner-key projection (§5.2) is private to the key. The §5.6
rate-limit zones MUST key on `partner_keys.id`, not on a `Vary:
Authorization` substring of the raw token. nginx-level caches MUST
NOT cache the partner projection (the §5.2 `Cache-Control: private`
plus the §5.6 rate-limit pattern enforces this).

### 5.5 Partner-only field stability contract

Fields under §5.2's partner-key projection are covered by the §8
versioning policy: they MUST NOT change shape or be removed without a
`/v2/*` version bump and a documented 6-month sunset window. New
partner-only fields MAY be added additively at any time without a
version bump.

Public-projection fields share the same contract; partner-only is
just a tighter accountability surface.

### 5.6 Rate limits

| Tier | Per-IP limit | Per-key limit | Enforced at |
|---|---|---|---|
| Public anon (no `Authorization`) | 60 req/min per IP per endpoint | n/a | nginx `limit_req_zone` (primary), in-process bucket (fallback) |
| Partner keyed (success) | n/a | 600 req/min per key per endpoint | in-process bucket keyed by `partner_keys.id` |
| Auth-failure (v0.1.8 — `Authorization` present but produces 401 per §5.4.3 rows 3/5/6/7) | 300 req/min per IP per endpoint (5× public floor) | n/a | in-process bucket keyed on client IP, runs BEFORE the §5.4.3 hash+SELECT |

**v0.1.8 reconciliation with AC-8.** Earlier drafts (v0.1.6 / v0.1.7)
named "burst 120" / "burst 1200" in this table. That was mechanically
inconsistent with AC-8 (which requires the 61st request from the
same IP within 60s to return 429) under plain nginx `limit_req`
semantics: a 120-token burst would absorb the 61st request, not
reject it. v0.1.8 drops the burst column from the §5.6 table. The
public tier is a hard 60 req/min per IP per endpoint; the partner
tier is a hard 600 req/min per key per endpoint. The locked
sustained-rate contract is 60/min (public) and 600/min/key
(partner); there is no LONG-TERM burst amplification.

**v0.1.8 erratum (added 2026-06-26 during the SPEC-017 v0.1.8
end-of-implementation adversarial audit).** The earlier text of
this paragraph said "AC-8 is now mechanically achievable with
`limit_req zone=<name> nodelay;` (no `burst=` parameter)". That
was incorrect on nginx semantics: with the default `burst=0` the
initially-empty leaky bucket admits at most 1 request immediately
and then strictly 1 request per second; a tight burst of 60
requests within the same second produces 1 successful response
and 59 immediate 429s, failing AC-8's "60 succeed" assertion. The
mechanically correct production directive is:

```nginx
limit_req zone=<name> burst=59 nodelay;
```

This admits the first 60 requests immediately (1 in-rate token +
59 burst capacity) and rejects the 61st with 429 + `Retry-After:
60` + the §5.9 envelope. The `rate=60r/m` refill (= 1 token/sec)
is unchanged, so over any 60-second window after the bucket is
spent, no more than 60 additional requests are admitted —
sustained throughput remains exactly 60/min. The `burst=59 nodelay`
parameter is a SHORT-TERM bucket capacity for the
mechanical AC-8 contract; it is NOT long-term burst absorption.
The phrase "no burst absorption" in this section refers to
sustained-throughput amplification, NOT to the short-term bucket
capacity nginx requires to admit the AC's named 60-request burst.

Implementations MUST use `burst=59 nodelay` on every public-tier
stats `limit_req` directive. The partner tier (in-process bucket)
similarly admits 600 immediate then strict 1/100ms refill;
"no burst absorption" applies to the sustained rate in the same
sense.

Both tiers MUST return `429 Too Many Requests` on exhaustion, with
`Retry-After: <seconds>` and a JSON body per §5.9. nginx is the
primary enforcement layer for the public tier so a misbehaving
partner cannot starve the coordinator process; the in-process bucket
exists as a defense-in-depth fallback.
When nginx generates the 429 before the Go handler resolves the
request projection, it MUST use the public CORS branch from §5.7:
`Access-Control-Allow-Origin: *` and no
`Access-Control-Allow-Credentials`.

**Auth-failure tier (v0.1.8 binding).** Because the public nginx
limiter is keyed empty for Authorization-bearing requests (per the
nginx-keying rule below), the implementation MUST place an
in-process per-IP+endpoint bucket on the failed-bearer path BEFORE
the §5.4.3 hash + SELECT executes. Otherwise a flood of
syntactically-bearer-shaped invalid/revoked/rejected-origin requests
could drive unbounded `partner_keys` lookup load on the
direct-to-coordinator surface. The floor is 300 req/min per IP per
endpoint (5× the public floor); the operator MAY tighten via
runtime config. The bucket MUST NOT differentiate by Origin
validation result, no-match vs revoked-match, or any other branch
that would create a timing/cardinality side-channel on key existence
(per §5.4.3 rule 4). Returns `429` with `Retry-After` and the §5.9
`rate_limited` envelope on exhaustion. AC-22 (added in v0.1.8 §10)
verifies this.

**Authorization-aware nginx keying (v0.1.8).** The public-tier
`limit_req_zone` MUST NOT throttle Authorization-bearing requests at
the edge — partner-keyed traffic is rate-limited by
`partner_keys.rate_limit_rpm` in-process (§5.4.7) and would otherwise
be double-counted. Auth-failure traffic is rate-limited by the
auth-failure tier above (in-process, pre-hash-SELECT), so it ALSO
does NOT need to flow through the public-tier nginx limiter. The nginx config MUST either:

- (a) Use an `nginx map` so the public `limit_req_zone` key is empty
  when `Authorization` is present (effectively bypassing the public
  limiter for keyed requests):
  ```nginx
  map $http_authorization $public_rl_key {
      ""      $binary_remote_addr;
      default "";
  }
  limit_req_zone $public_rl_key zone=stats_public:10m rate=60r/m;
  ```
- (b) Split keyed traffic into a separate location block that does
  NOT carry the public `limit_req` directive.

The IMPL author picks (a) or (b); the test (AC-8 keyed-bypass
companion) MUST send 100+ requests with a valid partner key through
nginx and assert ALL succeed at the edge layer (in-process partner
bucket may still cap them per §5.6 partner-tier — that's the
authoritative limit for keyed traffic).

Cloudflare bot-management and CAPTCHA challenges MAY be layered above
nginx; the SPEC does not mandate them but does not preclude them.

### 5.7 CORS

§5.4.3 owns the (Authorization, Origin) branch decision for
authenticated requests. This section pins the `Access-Control-*`
response headers that each branch emits. All Origin comparisons in
this table use the RFC 6454 normalization rule pinned in §5.4.3
rule 5.

| # | Branch | Request kind | `Access-Control-Allow-Origin` | Other CORS headers |
|---|---|---|---|---|
| 1 | `/overview`, `/health`, anonymous | any Origin or none | `*` | `Access-Control-Allow-Methods: GET, HEAD, OPTIONS` |
| 2 | `/leaderboard` public (no key) | any Origin or none | `*` | same as above |
| 3 | `/leaderboard` partner-key, `allowed_origins = '{}'`, browser context (Origin present) | Origin present | echo normalized `Origin` (NEVER `*`) | same as above, plus `Access-Control-Allow-Credentials: true` |
| 4 | `/leaderboard` partner-key, `allowed_origins = '{}'`, server-to-server (Origin absent) | Origin absent | omit `Access-Control-Allow-Origin` entirely | omit `Access-Control-Allow-Credentials` |
| 5 | `/leaderboard` partner-key, `allowed_origins` non-empty, Origin matches allowlist | matched Origin | echo normalized `Origin` (NEVER `*`) | same as row 3, plus `Access-Control-Allow-Credentials: true` |
| 6 | `/leaderboard` partner-key, `allowed_origins` non-empty, Origin not in allowlist | rejected at auth (§5.4.3) | omit (401 response carries no CORS allow header) | n/a |
| 7 | `/leaderboard` partner-key, `allowed_origins` non-empty, Origin absent | rejected at auth (§5.4.3) | omit | n/a |

The previous draft's row 3 emitted `Access-Control-Allow-Origin: *`
for the partner-key path when `allowed_origins = '{}'`. That was
broken: per the Fetch spec, a credentialed response with
`Access-Control-Allow-Origin: *` is rejected by browsers, and the
partner projection is precisely the credentialed path. The v0.1.7
rule above splits row 3 into "browser context (Origin present)" and
"server-to-server (Origin absent)" so the partner projection never
emits `*` in a credentialed response.

**Preflight (`OPTIONS`).** Browser CORS preflight does NOT carry
the actual `Authorization` token (only `Access-Control-Request-Headers:
Authorization` advertises that the GET will). The handler therefore
CANNOT evaluate per-key allowlists at preflight time, and MUST NOT
try. Preflight uses a permissive, key-agnostic rule:

- `OPTIONS /v1/stats/*` returns 204 with empty body.
- `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`.
- `Access-Control-Allow-Headers: Authorization, Content-Type`.
- `Access-Control-Max-Age: 60` (v0.1.6 had `3600`; lowered in v0.1.7
  so partner-key revocation propagates to the browser preflight
  cache within a minute, not within an hour). Operators MAY raise
  via runtime config, but MUST NOT exceed 300 seconds (5 min) for
  v0.1; raising further requires a SPEC bump because it widens the
  revocation tail.
- `Access-Control-Allow-Origin`: normalize the request's `Origin`
  per §5.4.3 rule 5. If the normalized Origin matches **any** entry
  in the operator-configured global partner-origin allowlist
  (collected as the union of every active `partner_keys.allowed_origins`
  array, plus the well-known origins `https://console.streamvc.live`
  and `https://portal.streamvc.live`), echo the normalized Origin
  and also emit `Access-Control-Allow-Credentials: true`. Otherwise
  emit `*` and DO NOT emit `Allow-Credentials`.

Per-key allowlist enforcement is the responsibility of the actual
GET (§5.4.3); preflight permissiveness MUST NOT be interpreted by
clients or implementations as a guarantee that the GET will
succeed.

### 5.8 Staleness and 503 budget

The freshness SLA table in §9.5 is the single source of truth for
each endpoint's 503 budget. Implementations MUST use the §9.5
budgets verbatim; the prose below is informative.

- `/v1/stats/overview` MUST serve a 503 when
  `stats_overview_current.generated_at` is older than the §9.5
  budget (`120s`).
- `/v1/stats/leaderboard` MUST serve a 503 when the requested
  window's `stats_leaderboard_<window>.generated_at` is older than
  the §9.5 budget for that window.
- A 503 from this surface MUST include `Retry-After: 30` and a JSON
  body per §5.9 with `code: "stats_stale"`.

`/v1/stats/health` MUST NOT return 503 for stale rollups (§5.3); a 503
from `/health` reflects the coordinator process itself.

### 5.9 Error envelope

This envelope is SPEC-017-local. SPEC-017 does NOT claim
error-envelope compatibility with SPEC-006 v0.9 (the buyer API uses
its own envelope shape with additional fields). Partners reusing a
SPEC-006-aware client SHOULD NOT assume schema parity; this is a
narrower envelope by design.

`304 Not Modified` is exempt from the JSON envelope: it MUST be
returned with an empty body and the headers required by RFC 7232
(`ETag`, `Cache-Control`, `Vary`) PLUS the projection-aware CORS
headers from §5.7 (`Access-Control-Allow-Origin`,
`Access-Control-Allow-Credentials` on partner projection,
`Access-Control-Max-Age` on preflight). v0.1.8 erratum
(2026-06-26): the Fetch spec requires `Access-Control-Allow-Origin`
on every cross-origin response including 304; a 304 without ACAO
silently fails as a CORS error in browsers issuing conditional
GETs from `console.streamvc.live` / `portal.streamvc.live`. The
earlier text omitted CORS from the 304 carveout, which would
break browser-side partner integrations. All other non-2xx
responses MUST use the exact shape below.

```json
{
  "error": {
    "code":    "rate_limited",
    "message": "Per-IP rate limit of 60 req/min exceeded.",
    "retry_after_seconds": 12
  }
}
```

Code vocabulary (closed set for v0.1):

| `code` | HTTP | When |
|---|---|---|
| `bad_request` | 400 | malformed `window`/`sort`/`limit` |
| `unauthorized` | 401 or 403 | invalid or revoked `Authorization`; valid bearer not authorized for the requested provider returns 403 |
| `method_not_allowed` | 405 | request verb not in `Allow: GET, HEAD, OPTIONS` (§4.3); response MUST also carry `Allow: GET, HEAD, OPTIONS` |
| `rate_limited` | 429 | per-IP or per-key bucket exhausted |
| `stats_stale` | 503 | rollup older than §5.8 budget |
| `internal` | 500 | unhandled; MUST NOT leak stack/SQL |

`retry_after_seconds` is present only for `rate_limited` and
`stats_stale`.

---

## 6. Earnings visibility model

### 6.1 Storage — `provider_visibility` side table (SPEC-017-owned)

v0.1 does NOT alter, extend, or assume any `providers` table. The
locked SPEC-002 v1.4 and SPEC-016 v0.1.19 storage models do not
guarantee a `providers` table exists. Instead, SPEC-017 owns a new
side table keyed by the provider identifier in use across the rest
of the system (`provider_tokens.provider_id` per SPEC-002 §7;
matching string type).

```sql
CREATE TABLE provider_visibility (
  provider_id                       TEXT PRIMARY KEY,
  mode                              TEXT NOT NULL DEFAULT 'bucketed'
                                    CHECK (mode IN ('bucketed','exact')),
  blocked_from_partner_projection   BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at                        TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Semantics:

- A provider with NO row in `provider_visibility` is treated as
  `mode = 'bucketed'` AND `blocked_from_partner_projection = FALSE`.
  This is the implicit default for new and pre-existing providers;
  cutover does NOT require backfill.
- The portal (SPEC-014 v0.9 candidate) writes to this table on
  toggle. SPEC-017 v0.1 does NOT specify the portal's HTTP handler;
  it only pins the storage shape.
- The rollup MUST left-join `provider_visibility` when producing the
  leaderboard projection; absence of a row is equivalent to the
  default tuple above.
- `blocked_from_partner_projection` is a **column stub** in v0.1.
  The v0.1 rollup does NOT consume it (partner-key projection still
  surfaces exact-$ for every provider per §5.2 and §6.6.2). The
  column is pinned now so SPEC v0.2 portal work has a stable
  storage shape to write into without a migration. §11 Q11 tracks
  the v0.2 semantic — whether opt-out blocks the partner projection
  entirely, replaces it with bucketed values, or surfaces a marker
  field. v0.1 implementations MUST add the column at schema-create
  time and MUST NOT branch on it.

This table is owned by SPEC-017. Adding the column to a future
`providers` table (if SPEC-002 or SPEC-016 introduces one in a later
version) is a v0.2+ migration concern, not a v0.1 LOCK gate.

### 6.2 Bucket thresholds (v0.1)

Absolute USD thresholds per row, computed by the rollup against the
provider's total earnings (`work + rewards`) over the window:

| Bucket | 24h | 7d | 30d | all |
|---|---|---|---|---|
| `-` (zero) | `< $0.01` | `< $0.01` | `< $0.01` | `< $0.01` |
| `$` | `[$0.01, $5)` | `[$0.01, $25)` | `[$0.01, $100)` | `[$0.01, $250)` |
| `$$` | `[$5, $50)` | `[$25, $250)` | `[$100, $1000)` | `[$250, $5000)` |
| `$$$` | `≥ $50` | `≥ $250` | `≥ $1000` | `≥ $5000` |

v0.1.7 ships **one** bucket axis only — `earnings_bucket`, computed
against the total `work + rewards` `NUMERIC(18,2)` figure per
provider per window. The previous draft's per-axis buckets
(`earnings_work_bucket`, `earnings_rewards_bucket`) are removed
because (a) per-axis disclosure increases the leakable surface
without commensurate partner value (§11 Q9 deferred this), and (b)
until `provider_rewards_ledger` is populated (§9.1a), the
`rewards` axis is `$0.00` for every provider and the bucket is
mechanically `"-"` — leaking the empty-state signal to clients. Partners
who need the work/rewards split MUST use the partner-key projection's
exact-$ fields (`earnings_work_usd`, `earnings_rewards_usd`).

**Bucket-boundary semantics (v0.1.7).** Bracket notation `[a, b)`
means `a` is inclusive and `b` is exclusive. Comparisons are against
the underlying `NUMERIC(18,2)` value of `earnings_usd` (sum of
`earnings_work_usd + earnings_rewards_usd`) per provider per window:

- `$5.00 → $$` (lower bound, inclusive).
- `$4.99 → $` (just below `$$` floor).
- `$49.99 → $$`; `$50.00 → $$$`.
- No additional rounding occurs at bucket-assignment time;
  `NUMERIC(18,2)` is already two-decimal exact. The rollup MUST
  compare against the stored numeric value, NOT a stringified
  representation.

**Threshold rationale (v0.1).** Boundaries are absolute USD figures
chosen against the **current beta network's revenue density** —
SPEC-016 v0.1.19 is still pre-IMPL and the current 7d leaderboard
shows top earners at ~$52 (see the
`SPEC-017-advisor-round-2026-06-25.md` artifact for the screenshot
snapshot). At those magnitudes, `$$$` at `≥ $250 / 7d` correctly
marks a clear top tier without exposing meaningful operator-level
information. As the network grows, the absolute boundaries will
under-fit (everyone tops out at `$$$`); Q1 in §11 flags whether
v0.2 shifts to percentile-of-network-revenue.

**Bucket-rule additivity boundary (v0.1).** Two operator changes
have different versioning implications and the SPEC is explicit
about both:

- **Additive (no SPEC bump):** introducing a new bucket VALUE
  (e.g. `$$$$` to extend the high end). Existing thresholds for
  `$`, `$$`, `$$$` are unchanged; clients that already tolerate
  the future-reserved set (§8.2.1) absorb the new label
  transparently.
- **Breaking (SPEC bump required):** changing the THRESHOLDS
  behind existing labels (e.g. raising `$$$` floor from `$250/7d`
  to `$500/7d`). Even though the wire shape is unchanged, the
  meaning of an existing field changes; partner dashboards that
  compare bucket labels over time would silently break. This is a
  field-meaning change per §8.3 and requires `/v2/*` overlap or a
  documented changelog entry with a coordinated partner-notification
  cadence (operator-defined; not pinned by v0.1).

The threshold values for v0.1 are pinned in the table above.
Until v0.2 ships percentile-based buckets (§11 Q1), operators
SHOULD prefer adding new reserved values over re-anchoring
existing ones.

### 6.3 Provider opt-in flow (cross-SPEC handoff)

The actual toggle UI is a SPEC-014 v0.9 candidate follow-up. v0.1 of
this SPEC pins only:

- The sole state-transition path is an `INSERT ... ON CONFLICT
  (provider_id) DO UPDATE SET mode = EXCLUDED.mode, updated_at = now()`
  against `provider_visibility` (§6.1).
- The provider-portal API endpoint that triggers this state
  transition MUST require provider authentication per SPEC-014 v0.8
  §2 (the portal authn section in the locked SPEC-014) and MUST
  insert a row into `provider_visibility_audit` (§6.5) within the
  same database transaction.
- The change takes effect on the next rollup snapshot for the
  affected window; v0.1 makes no guarantee of sub-30s propagation
  on shorter windows or sub-§9.2-cadence propagation on longer
  windows.
- SPEC-017 v0.1 does NOT require SPEC-014 v0.9 to be merged before
  this SPEC can lock. Until the portal toggle ships, the visibility
  defaults to `bucketed` for every provider; the table simply has
  zero rows, which is semantically identical to "everyone bucketed."

### 6.4 Same-origin uniformity invariant

`GET /v1/stats/leaderboard` serves console, portal, and partners
with identical JSON given identical inputs (window, sort, limit,
Authorization). The implementation MUST NOT inspect `Origin` to
decide what to return. There is no Origin-conditional projection,
no Origin-conditional `$` exposure, and no Origin-conditional row
filtering.

Own-provider exact earnings, when needed by a logged-in provider in
the portal UI, MUST come from a SPEC-014-owned surface (e.g. the
portal's earnings dashboard endpoints), NOT from a special
projection of this endpoint. SPEC-014 v0.8 §2 already pins the
portal's authn surface; v0.9 will add the SPEC-017-aligned
visibility toggle but will NOT make this endpoint privileged.

### 6.5 Audit table

```sql
CREATE TABLE provider_visibility_audit (
  id           BIGSERIAL PRIMARY KEY,
  provider_id  TEXT NOT NULL,
  old_mode     TEXT NOT NULL,
  new_mode     TEXT NOT NULL,
  actor_kind   TEXT NOT NULL CHECK (actor_kind IN ('provider','operator')),
  actor_id     TEXT NOT NULL,
  changed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  source_ip    INET,
  user_agent   TEXT
);
CREATE INDEX ON provider_visibility_audit (provider_id, changed_at);
```

Every visibility-mode change MUST insert a row. Operator-driven
changes (e.g. legal request) MUST set `actor_kind = 'operator'`.

### 6.6 Legal posture

#### 6.6.1 Public-projection consent

By default, every provider's `$` is bucketed publicly. The portal's
opt-in screen (SPEC-014 v0.9 candidate) MUST display copy
substantially equivalent to: "When you enable exact earnings
display, the public Network Stats API will publish your USD
earnings per window. This is visible to anyone on the public
internet, including partners' websites and any third party that
caches or republishes our data." The provider's affirmative click
is the consent record; the audit row in §6.5 is the durable
evidence.

#### 6.6.2 Partner-key projection — broader exposure

Operator-issued partner keys (§5.4) intentionally surface exact `$`
for ALL providers, including providers with `mode = 'bucketed'`.
This is the design's trade: the partner key is an attribution and
revocability surface (the operator can revoke per §5.4.5), in
exchange for trusted exposure to a small, named set of partners.

The portal's onboarding flow MUST disclose this at the same time the
provider account is created, in copy substantially equivalent to:
"Bucketed earnings are hidden from the public Network Stats API, but
trusted partners with an operator-issued API key see your exact
earnings figures. The operator maintains the list of trusted
partners and can revoke a partner's key at any time." Acknowledgment
of this disclosure is part of the SPEC-014 v0.9 portal flow; v0.1 of
this SPEC defines only the disclosure obligation, not the UI.

**Launch-sequencing precondition (v0.1.7, binding):** production
issuance of partner keys under §5.4.2 — that is, any
`coordinator partner-keys issue` invocation on a non-staging
coordinator that produces a key delivered to a real partner — MUST
NOT begin until **all** of the following are true on the live
Pearl coordinator:

1. SPEC-014 v0.9 has merged and is deployed to
   `portal.streamvc.live`.
2. The §6.6.2 disclosure copy (above) is being shown on the
   provider-account creation page AND on a static portal page that
   every existing provider is shown on their next portal login
   (one-time disclosure for pre-existing accounts).
3. The operator runbook (out of scope for this SPEC) has a
   recorded sign-off entry naming the SPEC-014 v0.9 commit SHA and
   the date both disclosure surfaces went live.

Operators MAY issue **staging** keys against staging coordinators
for AC-1..AC-21 fixture work, smoke testing, and partner-side
dry-run integration BEFORE the SPEC-014 v0.9 surface ships;
staging keys MUST NOT be returnable on a production response. The
keys themselves are distinguishable by the `prefix` (§5.4.1) plus
the operator's record of which environment issued them, NOT by a
namespace flag in the token — the network has no protocol field
for "staging vs production keys" and v0.1.7 does not add one.

Providers who object to partner-key exposure of their bucketed
earnings have no v0.1 wire mechanism to suppress it
(`provider_visibility.blocked_from_partner_projection` is a v0.1.7
column stub per §6.1; the rollup does not yet consume it). §11 Q11
tracks the v0.2 semantic.

#### 6.6.3 Operator override direction

Operator MAY override `'exact' → 'bucketed'` (silencing the public
projection) without provider consent in response to a legal hold or
operator incident. Operator MUST NOT flip a provider to `'exact'`
without the provider's affirmative consent recorded in §6.5 with
`actor_kind = 'provider'`. The check is mechanical: any
`provider_visibility_audit` row with `new_mode = 'exact'` MUST have
`actor_kind = 'provider'`; a row with `new_mode = 'exact'` and
`actor_kind = 'operator'` is a contract violation surfaced by a
periodic operator audit script (the script itself is out of scope
for v0.1).

---

## 7. Hosting and isolation

### 7.1 Mount path and hostname

- Primary mount: `/v1/stats/*` on the coordinator binary's HTTP server,
  alongside `/admin/explorer/*` and existing surfaces.
- Public hostname: `stats.streamvc.live` — new nginx server-block on
  Pearl, TLS via the same cert pipeline as the other `*.streamvc.live`
  vhosts, proxies to the coordinator backend on the same `/v1/stats/*`
  path.
- `coordinator.streamvc.live/v1/stats/*` MUST also work (no host
  rewrite) so that internal consumers can hit the surface without DNS
  changes. Partners are documented to use `stats.streamvc.live`.

### 7.2 DB role isolation

SPEC-017 splits its DB grants across three required roles —
`stats_reader` (§7.2.1), `stats_rollup` (§7.2.2), `provider_portal`
(§7.2.3) — plus one optional role `partner_keys_writer` (§7.2.4)
that is only required when the operator chooses to populate
`partner_keys.last_used_at`. §7.2.5 documents the connection-pool
isolation contract that ties these together. Each role's
read/write surface is enumerated below; the union of these grant
sets covers all tables defined in §9.1 and §9.1a plus the
SPEC-017-owned `provider_visibility` and `provider_visibility_audit`
tables.

#### 7.2.1 `stats_reader` — request-path handler role

```sql
CREATE ROLE stats_reader LOGIN PASSWORD '<from-env>';
REVOKE ALL ON SCHEMA public FROM stats_reader;
GRANT USAGE ON SCHEMA public TO stats_reader;
GRANT SELECT ON
  stats_overview_current,
  stats_timeseries_rpm_30m,
  stats_timeseries_tpm_30m,
  stats_leaderboard_24h,
  stats_leaderboard_7d,
  stats_leaderboard_30d,
  stats_leaderboard_all,
  stats_components_health,
  provider_visibility,
  partner_keys
TO stats_reader;
```

These are the **request-path readable** tables. Notes:

- `stats_components_health` feeds `/v1/stats/health` (§5.3).
- `provider_visibility` is SELECT-only at request time (the rollup
  joins it; the handler does not query it directly). The handler
  role still needs the grant because the rollup runs as a separate
  role but the handler's leaderboard projection MAY left-join
  `provider_visibility` defensively in case of stale rollup data.
- `partner_keys` is required for the authn flow (§5.4.3).

Explicit denies (request-path role MUST NOT have these grants):

- `provider_visibility_audit` — write-only at request time; not
  read by handlers.
- `stats_late_events` (§9.1, §9.3) — rollup-internal only.
- `provider_rewards_ledger` (§9.1a) — rollup-internal only.
- Any OLTP billing/session/pool table — enforced by the connection
  isolation in §7.2.5.

#### 7.2.2 `stats_rollup` — rollup job role

SPEC-017 v0.1 normatively pins ONLY the **write** grants for the
rollup role (the `stats_*` tables it owns) plus the SPEC-017-owned
read grants (`provider_visibility`, `provider_rewards_ledger`).
The OLTP **source** read grants are deliberately left
implementation-authored against the locked SPEC-002 v1.4 / SPEC-005
v0.3 source-table inventory at IMPL time — that inventory has
evolved enough across recent dependency versions that hardcoding a
list here would silently drift. The IMPL prompt
(`BUILD_SPEC_017_IMPL_PROMPT.md`) will enumerate the exact source
tables against the locked dependency line-3 at the moment of IMPL.

Normatively pinned grants:

```sql
CREATE ROLE stats_rollup LOGIN PASSWORD '<from-env>';
REVOKE ALL ON SCHEMA public FROM stats_rollup;
GRANT USAGE ON SCHEMA public TO stats_rollup;
GRANT SELECT, INSERT, UPDATE, DELETE ON
  stats_overview_current,
  stats_timeseries_rpm_30m,
  stats_timeseries_tpm_30m,
  stats_leaderboard_24h,
  stats_leaderboard_7d,
  stats_leaderboard_30d,
  stats_leaderboard_all,
  stats_components_health,
  stats_late_events
TO stats_rollup;
-- SELECT on the rollup-owned stats_* tables is required for the
-- §9.3 incremental merge (30d/all windows merge late events into
-- the existing snapshot) and the §9.4 drift detection (nightly
-- rebuild compares against the incremental snapshot).
GRANT SELECT ON
  provider_visibility,
  provider_rewards_ledger
TO stats_rollup;
-- BIGSERIAL backing-sequence privileges required for the
-- stats_late_events INSERT path (§9.3).
GRANT USAGE, SELECT ON SEQUENCE stats_late_events_id_seq TO stats_rollup;
-- + IMPL-authored SELECT grants on the locked OLTP source tables
-- per SPEC-002 v1.4 §7 (provider/session) and SPEC-005 v0.3 §10
-- (billing/ledger). See BUILD_SPEC_017_IMPL_PROMPT.md for the
-- exact list at IMPL time.
```

The rollup role MUST NOT have any grant on `partner_keys` or
`provider_visibility_audit`. The IMPL-authored OLTP source grant
list MUST be additive only to the normative grants above; any
write grant or non-OLTP additional grant added to `stats_rollup`
is a contract violation surfaced by an operator-side schema-audit
script (out of scope for v0.1).

#### 7.2.3 `provider_portal` — portal toggle role (SPEC-014 v0.9 candidate)

```sql
CREATE ROLE provider_portal LOGIN PASSWORD '<from-env>';
REVOKE ALL ON SCHEMA public FROM provider_portal;
GRANT USAGE ON SCHEMA public TO provider_portal;
GRANT SELECT, INSERT, UPDATE ON provider_visibility TO provider_portal;
GRANT INSERT ON provider_visibility_audit TO provider_portal;
-- BIGSERIAL backing-sequence privilege required for the
-- provider_visibility_audit INSERT path (§6.5).
GRANT USAGE, SELECT ON SEQUENCE provider_visibility_audit_id_seq TO provider_portal;
```

This role is referenced by SPEC-014 v0.9 candidate; SPEC-017 v0.1
pins the grant set for that role here so the portal IMPL has a
locked target. No `stats_*` grants. No OLTP grants.

**v0.1.8 erratum (added 2026-06-26).** The grant set was widened
from `INSERT, UPDATE` to `SELECT, INSERT, UPDATE` on
`provider_visibility`. The portal's bucketed-vs-exact toggle uses
an UPSERT path that requires `SELECT` to read the prior row state
before the conditional UPDATE (the portal does not blindly INSERT
because that would clobber audit history). The earlier minimum
grant was insufficient under Postgres' RLS-free `ON CONFLICT`
shape. `SELECT` is scoped to the role; the portal still cannot
read any `stats_*` table, the OLTP ledger, or `partner_keys`. The
implementation migration at
`internal/stats/migrations/004_grants.up.sql:86-118` documents
this deviation inline.

#### 7.2.4 `partner_keys_writer` — last_used_at writer

```sql
CREATE ROLE partner_keys_writer LOGIN PASSWORD '<from-env>';
REVOKE ALL ON SCHEMA public FROM partner_keys_writer;
GRANT USAGE ON SCHEMA public TO partner_keys_writer;
GRANT UPDATE (last_used_at) ON partner_keys TO partner_keys_writer;
```

Used by a background channel/queue worker that consumes
`(partner_keys.id, observed_at)` pairs from the request path and
issues the UPDATE out-of-band (§5.4.3 step 2). This role has
column-scoped UPDATE on `partner_keys.last_used_at` only — it
cannot mutate hash, allowed_origins, rate_limit_*, or revoked_at.
SPEC-017 v0.1 does NOT pin the channel transport (in-process
buffered channel, NATS subject, etc.); the operator MAY pick. If
the operator chooses to skip `last_used_at` updates entirely, this
role MAY be omitted.

#### 7.2.5 Connection-pool isolation

The stats handlers MUST connect with `stats_reader` and MUST NOT
share a `*sql.DB` instance with the explorer or billing handlers.
A separate `*sql.DB` enforces this at compile/runtime; AC-9 verifies
the role denies billing-table SELECT. The rollup job's `*sql.DB`
uses `stats_rollup`; the portal's uses `provider_portal`; the
last-used writer (if present) uses `partner_keys_writer`. No two
roles MAY be the same.

### 7.3 Process isolation

A panic in any `/v1/stats/*` handler MUST NOT crash the coordinator
process. The HTTP mux MUST wrap the stats subtree in a `recover`
middleware that logs the panic and returns a 500 with the §5.9
envelope.

### 7.4 nginx config

A new nginx server-block (a new file under
`scripts/nginx/snippets/stats.conf` or similar — exact path is an IMPL
choice) MUST:

- Define `limit_req_zone` for `/v1/stats/overview`, `/v1/stats/leaderboard`,
  `/v1/stats/health` separately.
- Add headers per the §5.7 CORS policy.
- Strip the `Authorization` header from access logs.
- Set `proxy_cache_path` for the public projections only.
- Honor `Vary: Authorization` by NOT caching the partner-key projection
  at nginx (let the in-process handler emit `Cache-Control: private`).

### 7.5 Read-replica posture

v0.1 does NOT require a Postgres read replica. The rollup job is the
heaviest load this SPEC adds, and it runs out-of-band against the
primary at a documented cadence.

**Threshold rationale (v0.1).** Pearl Postgres monitoring records 7-day
OLTP CPU utilization in 5% buckets; a 5% delta is the smallest signal
the current monitoring can reliably attribute to a single load source.
A higher threshold (e.g. 10%) risks accumulating compounding load
unnoticed; a lower threshold (e.g. 1%) is below the monitoring's
attribution noise floor and would generate false positives. If the
rollup primary impact exceeds 5% of OLTP CPU over a 7-day window
(measurable via existing Pearl Postgres monitoring), a read-replica
migration becomes mandatory and a separate spec/SPEC-017 v0.2 work
item is triggered.

### 7.6 Failure isolation from existing surfaces

`internal/stats` MUST NOT import:

- `internal/billing/*`
- `internal/explorer/*`
- `internal/ws/*` (provider WS server)
- `internal/auth/*` other than a minimal Bearer parser

The package layout enforces this via the Go import graph; a CI lint
(e.g. `go vet` plus a custom check or `depguard`) MUST reject imports
that cross these boundaries.

---

## 8. Versioning and deprecation

### 8.1 URL version

`/v1/stats/*` is the only public contract surface at v0.1. The string
`v1` in the path is the API version; never bump on field additions.

### 8.2 Compatible changes

Additive changes MAY ship without a version bump and MUST be
documented in the public-facing changelog (§8.5). Permitted additive
changes:

- New top-level JSON fields (any endpoint).
- New nested metadata fields under existing JSON objects when they only
  label or describe sibling values and do not change sibling value
  semantics; clients MUST ignore unknown object members.
- New optional query params with safe defaults.
- New error codes appended to the §5.9 vocabulary, subject to §8.2.1
  forward-compat rules below.
- New bucket VALUES appended to the §6.2 `$/$$/$$$/-` set, subject
  to §8.2.1 forward-compat rules below. Changing the THRESHOLD
  behind an existing bucket value is NOT additive; see §6.2 and
  §8.3.
- Additive `partner_keys` row fields.

### 8.2.1 Forward-compat rules for closed enums

Bucket values (§6.2) and error codes (§5.9) are defined as closed
sets at v0.1. Because adding a value to a closed set can silently
break generated clients, partner dashboards, and validators, the
following forward-compat rules apply to any v0.x addition:

- The SPEC MUST reserve `$$$$` (next bucket up) and `$$$$$` (one
  above that) as **future-reserved** values at v0.1 LOCK; clients
  MUST tolerate seeing them in a response without error even though
  v0.1 will never emit them.
- The SPEC MUST reserve `code: "unknown_*"` as a future-reserved
  error code prefix; clients MUST treat any unknown `code` value as
  if it were a generic transient error (retry per `retry_after_seconds`
  if present, else surface as a generic failure).
- Adding any value NOT in the future-reserved set requires a
  `/v2/*` bump (per §8.3).
- The public changelog (§8.5) MUST cite which future-reserved slot
  a new value consumes.

### 8.3 Breaking changes

Field removals, field-meaning changes, error-code repurposing, or
window-vocabulary changes MUST ship behind `/v2/*` with a minimum
**6-month** overlap window during which `/v1/*` continues to serve the
prior shape, and a `Deprecation` header per RFC 9745 on every `/v1/*`
response during overlap.

### 8.4 Sunset header

Once a `/v1/*` endpoint enters deprecation, every response MUST carry:

- `Deprecation: @<unix_ts>` — RFC 9745 structured-field date format
  giving the deprecation effective timestamp (e.g.
  `Deprecation: @1782086400` for 2026-06-22T00:00:00Z).
- `Sunset: Fri, 25 Dec 2026 00:00:00 GMT` — RFC 8594 / RFC 7231
  IMF-fixdate format with correct day-of-week giving the planned
  removal date.
- `Link: <https://docs.streamvc.live/network-stats-api/v2-migration>;
  rel="deprecation"` — RFC 9745 `rel="deprecation"` link relation
  pointing at the partner-facing migration guide.

Citations: `Sunset` is defined by RFC 8594; the `Deprecation` header
and `rel="deprecation"` link relation are defined by RFC 9745
(supersedes the obsolete `Deprecation: true` form).

### 8.5 Public changelog location

A versioned changelog MUST live at
`docs/network-stats-api/CHANGELOG.md` in this repo, with one entry per
shipped change (additive or breaking). Each entry MUST cite the PR
number and the SPEC version that introduced the change.

---

## 9. Rollup pipeline

### 9.1 Table schemas (normative)

Every `stats_*` and `stats_components_health` table is owned by
SPEC-017 and defined here. The grant inventory across §7.2.1 /
§7.2.2 / §7.2.3 partitions these tables by role; the union covers
every table in this §9.1, plus the SPEC-017-owned `provider_visibility`
/ `provider_visibility_audit` / `partner_keys` (defined in their
respective sections) and the §9.1a `provider_rewards_ledger`. There
is no single role with SELECT on the full union — that is the
design.

```sql
CREATE TABLE stats_overview_current (
  singleton                BOOLEAN PRIMARY KEY DEFAULT TRUE
    CHECK (singleton = TRUE),
  generated_at             TIMESTAMPTZ NOT NULL,
  tokens_in                BIGINT NOT NULL,
  tokens_out               BIGINT NOT NULL,
  requests                 BIGINT NOT NULL,
  nodes_online             INT NOT NULL,
  nodes_hardware_attested  INT NOT NULL,
  bandwidth_gb_per_s       BIGINT NOT NULL,
  network_power_kw         DOUBLE PRECISION NOT NULL,
  network_utilization_pct  INT NOT NULL,
  gpu_cores_total          INT NOT NULL,
  cpu_cores_total          INT NOT NULL,
  unified_ram_gb_total     INT NOT NULL,
  models_serving           INT NOT NULL
);

CREATE TABLE stats_timeseries_rpm_30m (
  bucket_start             TIMESTAMPTZ PRIMARY KEY,
  requests                 BIGINT NOT NULL
);

CREATE TABLE stats_timeseries_tpm_30m (
  bucket_start             TIMESTAMPTZ PRIMARY KEY,
  input_tokens             BIGINT NOT NULL,
  output_tokens            BIGINT NOT NULL
);

CREATE TABLE stats_leaderboard_24h (
  provider_id              TEXT NOT NULL,
  pseudonym                TEXT NOT NULL,
  generated_at             TIMESTAMPTZ NOT NULL,
  rank_earnings            INT NOT NULL,
  rank_tokens              INT NOT NULL,
  rank_jobs                INT NOT NULL,
  earnings_usd             NUMERIC(18,2) NOT NULL DEFAULT 0,
  earnings_work_usd        NUMERIC(18,2) NOT NULL DEFAULT 0,
  earnings_rewards_usd     NUMERIC(18,2) NOT NULL DEFAULT 0,
  earnings_bucket          TEXT NOT NULL,
  tokens                   BIGINT NOT NULL DEFAULT 0,
  jobs                     BIGINT NOT NULL DEFAULT 0,
  first_seen_at            TIMESTAMPTZ,
  last_seen_at             TIMESTAMPTZ,
  PRIMARY KEY (provider_id)
);
CREATE INDEX ON stats_leaderboard_24h (rank_earnings);
CREATE INDEX ON stats_leaderboard_24h (rank_tokens);
CREATE INDEX ON stats_leaderboard_24h (rank_jobs);
-- stats_leaderboard_7d, stats_leaderboard_30d, stats_leaderboard_all
-- have IDENTICAL schemas to stats_leaderboard_24h above. The schema
-- is shared so the handler can parametrize the table name by window.
--
-- v0.1.7 removed earnings_work_bucket and earnings_rewards_bucket
-- (per-axis buckets are no longer exposed; §6.2 strips them and §5.2
-- ships only `earnings_bucket`). The exact-$ work/rewards split is
-- preserved in earnings_work_usd and earnings_rewards_usd for the
-- partner-key projection.

CREATE TABLE stats_components_health (
  component                TEXT PRIMARY KEY,
    -- exactly one of:
    --   'overview',
    --   'timeseries_rpm', 'timeseries_tpm',
    --   'leaderboard_24h', 'leaderboard_7d',
    --   'leaderboard_30d', 'leaderboard_all'
    -- v0.1.7 split the single 'timeseries' key into
    -- 'timeseries_rpm' and 'timeseries_tpm' so single-axis rollup-job
    -- failure is visible (the two tables drift independently).
  generated_at             TIMESTAMPTZ NOT NULL,
  last_ok_at               TIMESTAMPTZ NOT NULL,
  last_error_at            TIMESTAMPTZ,
  last_error_message       TEXT
);

CREATE TABLE stats_late_events (
  id                       BIGSERIAL PRIMARY KEY,
  recorded_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  event_unix_ts            BIGINT NOT NULL,
  provider_id              TEXT NOT NULL,
  delta_usd                NUMERIC(18,2),
  delta_tokens             BIGINT,
  source_billing_row       TEXT
);
```

JSON-to-column mapping for `/v1/stats/overview` (§5.1):

| JSON field | Source column |
|---|---|
| `network.tokens_served_total` | `tokens_in + tokens_out` |
| `network.tokens_in_total` | `tokens_in` |
| `network.tokens_out_total` | `tokens_out` |
| `network.requests_total` | `requests` |
| `network.nodes_online` | `nodes_online` |
| `network.nodes_hardware_attested` | `nodes_hardware_attested` |
| `network.bandwidth_gb_per_s` | `bandwidth_gb_per_s` |
| `network.network_power_kw` | `network_power_kw` |
| `network.network_utilization_pct` | `network_utilization_pct` |
| `network.gpu_cores_total` | `gpu_cores_total` |
| `network.cpu_cores_total` | `cpu_cores_total` |
| `network.unified_ram_gb_total` | `unified_ram_gb_total` |
| `network.avg_tokens_per_request` | derived: `(tokens_in+tokens_out) / max(1, requests)` |
| `network.models_serving` | `models_serving` |
| `network.capacity_estimate_sources` | derived labels; no database column |

The `provider_id → pseudonym` mapping is deterministic per provider
and persisted in `stats_leaderboard_*.pseudonym`. The mapping
function is operator-owned; v0.1 does NOT pin the function (§11 Q4
flags pseudonym-rotation policy).

### 9.1a Rewards source — deferred to operator-defined ledger

SPEC-016 v0.1.19 (the locked dependency) defines the payout pipeline
but does NOT normatively define a work-vs-rewards split. SPEC-017
v0.1 therefore does NOT claim a locked source for
`earnings_rewards_usd`. Instead:

1. The leaderboard schema retains the `earnings_rewards_*` columns
   so partners can build against a stable shape today.
2. The rollup MUST source these columns from an operator-defined
   ledger table `provider_rewards_ledger` whose shape is pinned
   here in skeleton:

   ```sql
   CREATE TABLE provider_rewards_ledger (
     id            BIGSERIAL PRIMARY KEY,
     provider_id   TEXT NOT NULL,
     unix_ts       BIGINT NOT NULL,
     amount_usd    NUMERIC(18,2) NOT NULL,
     reason        TEXT,
     external_ref  TEXT
   );
   CREATE INDEX ON provider_rewards_ledger (provider_id, unix_ts);
   ```

3. The economic semantics of WHEN and HOW a row lands in
   `provider_rewards_ledger` (e.g. ramp incentives, hardware-tier
   bonuses, on-chain rewards mirror) are **out of scope for v0.1**
   and are deferred to either (a) a future SPEC-016 v0.2+ revision
   that splits work/rewards normatively, or (b) a new SPEC dedicated
   to network incentives. See §11 Q13.
4. Until that source spec lands, the operator MAY ship with zero
   rows in `provider_rewards_ledger`. In that case
   `earnings_rewards_usd` is `0.00` for every row (partner
   projection); the public surface remains a stable contract.
5. The leaderboard handler MUST set the top-level response field
   `meta.rewards_populated` (§5.2) to:
   - `true` iff `SELECT 1 FROM provider_rewards_ledger WHERE
     unix_ts >= <window_start_unix> AND unix_ts < <window_end_unix>
     LIMIT 1` returns a row at rollup time;
   - `false` otherwise (including the v0.1 cutover state, where
     the ledger ships empty for every window).

   The rollup pre-computes `rewards_populated` per window and
   persists it (e.g. as a denormalized column on
   `stats_components_health` keyed by `leaderboard_<window>`, or
   as a small `stats_rewards_populated` lookup table — the storage
   shape is implementation-authored; the wire field is normative).
   The handler MUST NOT compute `rewards_populated` synchronously
   from `provider_rewards_ledger` on the request path.

This is the cleanest honest path: the partner-facing schema is
locked at v0.1; the economic source is decoupled; partners get a
machine-readable signal for whether the rewards split is meaningful
yet. A future SPEC bump of the rewards source does NOT require a
`/v2/*` URL bump.

### 9.2 Cadence

| Table | Refresh cadence | Source query shape |
|---|---|---|
| `stats_overview_current` | every 30s | `tokens_in / tokens_out / requests` are cumulative all-time counters (SUM since rollup-start, NOT a 24h window). Live point-in-time columns (`nodes_online`, `nodes_hardware_attested`, `bandwidth_gb_per_s`, `network_power_kw`, `gpu_cores_total`, `cpu_cores_total`, `unified_ram_gb_total`, `models_serving`) are snapshots of the pool registry. `network_utilization_pct` is the recent-window load average. |
| `stats_timeseries_rpm_30m` | every 30s, rolling | aggregate per-minute counts last 30 minutes |
| `stats_timeseries_tpm_30m` | every 30s, rolling | aggregate per-minute tokens last 30 minutes |
| `stats_leaderboard_24h` | every 60s | per-provider sums over last 24h (windowed) |
| `stats_leaderboard_7d` | every 5 min | per-provider sums over last 7d (windowed) |
| `stats_leaderboard_30d` | every 30 min | per-provider sums over last 30d (windowed) |
| `stats_leaderboard_all` | every 6 hours | per-provider sums since rollup-start (windowed; `window=all` is the cumulative-since-rollup-start window) |

These are the v0.1 floors. The operator MAY tighten them in production
without a SPEC change; loosening them requires a SPEC bump.

**Cumulative vs windowed (v0.1.7, binding):** the `/v1/stats/overview`
endpoint exposes cumulative-all-time counters with the `_total`
suffix. The `/v1/stats/leaderboard` endpoint exposes windowed sums
parametrized by `?window=`. The two timescales never alias — a
single number on overview is never the same number on leaderboard,
because the overview is cumulative and the leaderboard is windowed.
The exception is `window=all`: a `stats_leaderboard_all` per-provider
sum IS over the same since-rollup-start range as the overview's
`_total` counters, but on a per-provider rather than network-wide
basis.

### 9.3 Late-event correction

Billing-row corrections that arrive after a window's snapshot was
written:

- For `24h` and `7d` windows — every refresh recomputes the FULL window
  from OLTP; late events fold in naturally at the next refresh tick.
  No incremental backfill machinery in v0.1.
- For `30d` and `all` windows — full recompute is too expensive. The
  rollup job MUST scan a configurable look-back of `last_processed_at
  - 48h` to `now` and merge corrections into the existing snapshot.
  Late events older than 48h are recorded in a `stats_late_events`
  table for periodic full-rebuild operator action.
- A full rebuild of `stats_leaderboard_all` (and `30d`) MUST run nightly
  at a low-traffic UTC hour (operator-configured; default 09:00 UTC,
  chosen because Pearl VPS billing-event volume historically dips
  60-80% between 06:00–10:00 UTC per the existing operator
  observability — see [[m2-4-archive-rotate-operator-actions]] for the
  established off-hours operator pattern), reconciling against OLTP
  truth and overwriting the incremental snapshot.

**Threshold rationale for 48h (v0.1).** SPEC-005 v0.3 §X-1 null-usage
settlements reconcile within 24h in the worst case; doubling that to
48h gives a 1× operator-safety margin against unforeseen reconciliation
delays. Older late events are infrequent enough to handle via the
nightly full-rebuild (operator-action gate) rather than per-tick
merging. The threshold is operator-configurable in the rollup
config; raising it makes the per-tick merge more expensive but does
not break the contract.

**`stats_late_events` retention (v0.1.7, binding).** The nightly
full-rebuild job MUST also DELETE `stats_late_events` rows with
`recorded_at < now() - INTERVAL '90 days'` after the rebuild
completes successfully (i.e. after the §9.4 atomic-swap transaction
commits). Without this retention rule the table grows unbounded on a
busy network. Operators MAY raise the retention via config but MUST
NOT set it below 30 days (the floor protects after-the-fact
forensic investigation of stale billing-row corrections). Lowering
below 30 days requires a SPEC bump.

### 9.4 All-time accumulation vs recompute

`stats_leaderboard_all` is incrementally accumulated between nightly
rebuilds (§9.3). The nightly job rebuilds from scratch and overwrites,
which doubles as a drift-detection mechanism: if the rebuild differs
from the incremental snapshot by more than 0.5% on any axis, an alert
fires and the rebuild value wins.

**Rebuild atomicity (v0.1.7, tightened in v0.1.8).** The nightly
rebuild MUST execute in a single PostgreSQL transaction so the
leaderboard never serves a half-rebuilt state. Three implementation
shapes are acceptable; the operator picks one and pins it in the
rollup config. **Shape C is the only shape executable under the
v0.1.7 §7.2.2 `stats_rollup` grant set (SELECT/INSERT/UPDATE/DELETE
on the `stats_*` tables); Shapes A and B require additional
privileges that v0.1 does NOT grant and require either an operator
deploy-time grant widening OR a SPEC v0.2 widening of §7.2.2.** Until
then, IMPL code MUST use Shape C.

- **Shape A — temp-table swap inside transaction** (requires
  `TRUNCATE` + temp-table creation privilege beyond v0.1 §7.2.2):
  ```sql
  BEGIN;
  CREATE TEMP TABLE _new_leaderboard_all (LIKE stats_leaderboard_all
    INCLUDING ALL) ON COMMIT DROP;
  -- INSERT computed rows into _new_leaderboard_all ...
  TRUNCATE stats_leaderboard_all;
  INSERT INTO stats_leaderboard_all SELECT * FROM _new_leaderboard_all;
  COMMIT;
  ```
- **Shape B — atomic table rename** (requires `ALTER TABLE RENAME`
  + `DROP TABLE` privilege beyond v0.1 §7.2.2):
  ```sql
  BEGIN;
  -- INSERT computed rows into stats_leaderboard_all_new ...
  ALTER TABLE stats_leaderboard_all RENAME TO stats_leaderboard_all_old;
  ALTER TABLE stats_leaderboard_all_new RENAME TO stats_leaderboard_all;
  DROP TABLE stats_leaderboard_all_old;
  COMMIT;
  ```
- **Shape C — single-transaction DELETE + INSERT** (v0.1.8 addition,
  executable under the locked §7.2.2 grants):
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
  PostgreSQL MVCC means concurrent `stats_reader` SELECTs see the
  pre-DELETE snapshot until the transaction commits, then see the
  post-INSERT snapshot. There is no window where the handler observes
  an empty leaderboard. Shape C is the v0.1 default.

A failed transaction MUST roll back without disturbing the running
incremental snapshot. The rebuild MUST NOT interleave per-provider
UPSERT operations against the live `stats_leaderboard_all` outside
a transaction.

The `stats_leaderboard_30d` nightly rebuild (§9.3) is subject to the
same atomicity rule.

**Threshold rationale for 0.5% (v0.1).** Postgres `NUMERIC(18,2)`
plus the rollup's incremental accumulation pattern produces sub-1¢
rounding drift per provider per tick. Across 327 providers and ~6h
of ticks between rebuilds, accumulated drift of <0.5% is
indistinguishable from arithmetic noise; ≥0.5% indicates a logic
bug (missed billing row, double-count, wrong window boundary) and
warrants an operator page. A tighter threshold (e.g. 0.1%) would
false-positive on legitimate arithmetic noise; a looser one (e.g.
2%) would silently hide a class of leaderboard-correctness bugs.

### 9.5 Freshness SLA

| Endpoint | Target staleness | 503 budget (§5.8) |
|---|---|---|
| `/v1/stats/overview` | 30s | 120s |
| `/v1/stats/leaderboard?window=24h` | 60s | 300s |
| `/v1/stats/leaderboard?window=7d` | 5 min | 30 min |
| `/v1/stats/leaderboard?window=30d` | 30 min | 4 hours |
| `/v1/stats/leaderboard?window=all` | 6 hours | 24 hours |
| `/v1/stats/health` | n/a (advisory) | n/a |

### 9.6 Failure modes

- Rollup job missed its tick: continue serving the previous snapshot
  with its existing `generated_at`. The health endpoint thresholds
  are pinned by §5.3 against the §9.5 target staleness (for
  `degraded`) and the §5.8 503 budget (for `down`). The two
  thresholds are NOT a 1×/2× ratio — they are two distinct
  operator-meaningful budgets and §5.3 is the single source of
  truth.
- Rollup job hit a SQL error: log to the audit logger, increment a
  metric counter (`stats_rollup_errors_total`), retry on next tick.
- Rollup job hit a panic: recover middleware logs and restarts the job
  scheduler for that table; an explicit operator runbook entry is
  required (cross-ref: a new operator-runbook section, not in this
  SPEC).

### 9.7 Backfill on cutover

v0.1 does NOT mandate full historical backfill of `stats_leaderboard_30d`
and `stats_leaderboard_all` before public-endpoint cutover. The
operator MAY choose either path:

**Path A — partial history (default for v0.1, lightweight):** ship
with rollup-start-date forward only. The `/v1/stats/leaderboard`
response for `30d` and `all` windows MUST include a top-level
`partial_history_since` RFC 3339 timestamp (the response shape is
pinned in §5.2). This is the additive v0.1 schema field; partners
are responsible for surfacing the "window is short" caveat in their
UI. Concretely:

- For `window=30d`, the field is REQUIRED in the response as long as
  `partial_history_since` is **less than** 30 days in the past (i.e.
  the rollup has accumulated under 30 days of history). Once the
  rollup has ≥30 days of history, the field MAY be omitted (additive
  removal, not breaking per §8.2 — partner clients MUST tolerate
  omission).
- For `window=all`, the field is REQUIRED as long as the rollup has
  accumulated less than the operator-defined `all` floor (e.g. 90
  days). Once the rollup has accumulated more, the field MAY be
  omitted.
- For `window=24h` and `window=7d`, the field is OMITTED (those
  windows are short enough that the rollup-start lag is irrelevant
  in production after the first week).

The §5.2 example body shows `partial_history_since` present; an
omitted-field example would simply drop the line.

**Path B — full backfill (operator opt-in, heavier):** populate
`stats_leaderboard_30d` and `stats_leaderboard_all` from full
historical OLTP billing data before flipping the nginx server-block.
On this path the `partial_history_since` field is omitted from
day 1.

The choice between A and B is an operator runbook concern, not a
SPEC LOCK gate. Q7 in §11 keeps the decision open for v0.2.

---

## 10. Acceptance criteria

An implementer MUST verify all ACs below before declaring SPEC-017 v0.1
implemented. Each is mechanically checkable in tests or an operator
runbook step.

- **AC-1.** `GET /v1/stats/overview` returns 200 with the §5.1 JSON
  shape, all 14 numeric `network.*` metrics present, the
  `network.capacity_estimate_sources` object present for the synthetic
  capacity labels, and exactly 30 points in each timeseries.
- **AC-2.** `GET /v1/stats/leaderboard` with no `window` query returns
  the `24h` window. With invalid `window=foo` returns 400 with
  `code: "bad_request"`.
- **AC-3.** `GET /v1/stats/leaderboard` returns 401 with
  `code: "unauthorized"` when an `Authorization: Bearer mpk_invalid`
  header is sent.
- **AC-4.** Public leaderboard rows for providers with
  `provider_visibility.mode = 'bucketed'` (or no `provider_visibility`
  row) have the single `exact_earnings` field present as JSON `null`
  (NOT missing). The v0.1.7 public projection exposes only
  `exact_earnings`; the previous per-axis fields
  `exact_earnings_work` / `exact_earnings_rewards` are removed.
- **AC-5.** Public leaderboard rows for providers with
  `provider_visibility.mode = 'exact'` have `exact_earnings` populated
  with a USD float to two-decimal precision (total `work + rewards`).
- **AC-6.** Partner-key leaderboard rows ALWAYS have `earnings_usd`,
  `earnings_work_usd`, `earnings_rewards_usd` populated regardless of
  `provider_visibility.mode`. The partner-key projection's top-level
  `totals.earnings_usd`, `totals.earnings_work_usd`, and
  `totals.earnings_rewards_usd` are ALSO populated; the public
  projection MUST NOT include any of those `totals.earnings_*` keys
  (asserted negatively in AC-6 — public response is rejected if any
  `totals.earnings_*` key is present).
- **AC-7.** `GET /v1/stats/health` returns 200 even when components
  are `degraded`. Returns non-200 ONLY when the coordinator process
  itself is unhealthy.
- **AC-8.** A 61st request from the same IP in a 60s window to
  `/v1/stats/overview` returns 429 with `Retry-After` and
  `code: "rate_limited"`.
- **AC-9.** `stats_reader` Postgres role MUST return a
  permission-denied error on any SELECT against a locked SPEC-005
  v0.3 ledger table — the test MUST pick at least one of
  `ledger_request_credits`, `ledger_operator_credits`,
  `ledger_payout_ready`, or `ledger_reconciliation_runs` (per
  SPEC-005 v0.3 §10) and assert denial. Permission denied, NOT
  "relation does not exist", is the assertion target.
- **AC-10.** Toggling `provider_visibility.mode` via the portal
  (SPEC-014 v0.9 candidate handler) inserts exactly one row into
  `provider_visibility_audit` with `actor_kind = 'provider'`,
  transactionally with the visibility-table UPSERT (§6.3).
- **AC-11.** A panic in a `/v1/stats/*` handler does NOT crash the
  coordinator process; the next `/healthz` check on the coordinator
  returns OK and the panic is logged with `event=stats_handler_panic`.
- **AC-12.** A request to `/v1/stats/overview` with
  `If-None-Match: <ETag from prior response>` returns 304 Not Modified
  with no body, provided `generated_at` has not advanced.
- **AC-13.** `OPTIONS /v1/stats/leaderboard` returns 204 (NOT 200; §5.7
  normatively pins 204) with an empty body,
  `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`, and
  `Access-Control-Allow-Headers: Authorization, Content-Type`.
- **AC-14.** When `stats_overview_current.generated_at` is more than
  120 seconds old, `/v1/stats/overview` returns 503 with
  `code: "stats_stale"` and `Retry-After: 30`.
- **AC-15.** No log line from `/v1/stats/*` handlers contains the raw
  `Authorization` header value; only `partner_keys.id` and
  `partner_keys.label` appear.
- **AC-16.** `internal/stats` Go package's import graph does NOT include
  `internal/billing`, `internal/explorer`, `internal/ws`, or any
  symbol from `internal/auth` other than a minimal Bearer parser
  (the explicit boundary set from §7.6), enforced by a CI lint that
  fails on any new import added to the forbidden set.
- **AC-17.** `coordinator partner-keys issue --label X` (§5.4.2)
  prints exactly one 47-character token starting with `mpk_` to
  stdout, INSERTs a row into `partner_keys` with `token_hash =
  sha256(raw_token_utf8_bytes)` and `length(prefix) = 8`, and the
  raw token does NOT appear in any log line, journald entry, or DB
  row after subprocess exit. The 43 characters after `mpk_` MUST
  match `/^[A-Za-z0-9_-]{43}$/` (no padding).
- **AC-18.** A request to `/v1/stats/leaderboard` with
  `Authorization: Bearer <revoked_token>` returns 401 with
  `code: "unauthorized"`. The v0.1.7 timing-equivalence assertion
  (§5.4.3 rule 4) is a three-way comparison: the 401 latencies for
  (a) `Bearer mpk_invalid` (no-row), (b) `Bearer <revoked_token>`
  (matched but revoked), and (c) `Bearer <valid_token>` with
  `Origin: https://attacker.example` against a key whose
  `allowed_origins` does NOT contain that origin (rejected-origin)
  MUST all fall within ±20% of each other. The implementation MUST
  perform `sha256 + SELECT by token_hash` in all three paths,
  including (c); short-circuiting on Origin before the hash+SELECT
  is a contract violation.
- **AC-19.** A SELECT against `provider_visibility` for a `provider_id`
  with no row returns zero rows; the leaderboard projection treats
  this as `mode = 'bucketed'` AND `blocked_from_partner_projection =
  FALSE` (§6.1 left-join semantics). AC verified by inserting a
  leaderboard row for a never-toggled provider and asserting
  `exact_earnings` is JSON null in the public projection (single
  field per v0.1.7; the per-axis exact-$ fields have been removed
  from the public projection).
- **AC-20.** No `provider_visibility_audit` row exists with
  `new_mode = 'exact' AND actor_kind = 'operator'` (§6.6.3 mechanical
  check). Verified by a SQL fixture and a CI assertion.
- **AC-21.** `POST /v1/stats/overview` (or any verb other than GET,
  HEAD, OPTIONS against any `/v1/stats/*` path) returns 405 with
  `Allow: GET, HEAD, OPTIONS` and the §5.9 envelope
  `{"error":{"code":"method_not_allowed", ...}}`.
- **AC-22 (v0.1.8).** Auth-failure rate limit per §5.6: from a single
  client IP, issue 301 requests in 60s to
  `/v1/stats/leaderboard` each carrying `Authorization: Bearer
  mpk_invalid_<random>`. The 301st request MUST return `429` with
  `code: "rate_limited"` and `Retry-After`. SQL instrumentation MUST
  show that the `partner_keys` SELECT count for those 301 requests is
  ≤300 (the auth-failure bucket cap), proving the limiter ran BEFORE
  the §5.4.3 hash+SELECT and did not leak key-existence work to
  flood traffic. AC-18 timing samples MUST run below this threshold.

---

## 11. Open questions (for the audit loop)

These are explicitly NOT decided in v0.1. The audit loop should
challenge each and propose pins for v0.2.

- **Q1 — Bucket boundaries.** Are the absolute thresholds in §6.2 the
  right model, or should buckets shift to percentile-of-network-revenue
  (e.g. `$$$` = top 10% earner by window) so that the disclosure
  surface stays uniform as the network scales? Absolute is simpler;
  percentile re-anchors automatically.
- **Q2 — Partner key issuance UX (v0.2+).** v0.1 §5.4.2 pins
  operator-only issuance via the `coordinator partner-keys issue` CLI;
  self-serve is NOT permitted in v0.1. Q2 is a forward-looking design
  question for v0.2: WHEN and HOW should self-serve issuance be
  introduced — portal-flow only, on-chain attestation, both? Should
  self-serve keys carry a lower default rate-limit tier? Should
  self-serve keys be locked to a single `allowed_origins` entry by
  default? Resolution gated on partner volume / abuse signals after
  v0.1 ships.
- **Q3 — Leaderboard pagination.** Single-shot `limit ≤ 100` is the
  v0.1 contract. Should v0.2 introduce cursor-based pagination
  (`cursor=<opaque>`) for partner deep-rank queries? The
  pseudonymization model interacts: cursor must be window-stable.
- **Q4 — Pseudonym rotation.** Are pseudonyms stable forever, stable
  per major SPEC version, or rotatable on provider request (e.g. after
  a near-deanonymization incident)? Stability has UX benefits for
  partners but is a worse privacy story.
- **Q5 — Mixed-window queries.** Should `window=24h,7d` (comma list)
  be supported for partner efficiency, or do partners hit the
  endpoint twice? Single-window keeps the cache key simple.
- **Q6 — Hostname pattern.** Locked decision is "embed in coordinator
  binary" (§2.4) but the public hostname is open between (a) using
  `coordinator.streamvc.live/v1/stats/*` only, (b) adding a separate
  `stats.streamvc.live` server-block, or (c) both. §7.1 currently pins
  (c); audit may push back.
- **Q7 — Backfill on cutover.** §9.7 allows partial-history rollout
  with a `partial_history_since` field. Is that acceptable for partner
  trust, or MUST full backfill be a hard gate before nginx flips on?
- **Q8 — `models_serving` exact semantics.** §5.1.1 defines it as
  "distinct `model_id` advertised by ≥1 online provider." Should it
  count attested-only, or all? The provider portal currently surfaces
  attested-only.
- **Q9 — Bucket value when work and rewards differ in tier (CLOSED in
  v0.1.7).** Resolved by D-M1 in the v0.1.7 fix pass: v0.1 ships only
  the single `earnings_bucket` axis (computed against total
  `work + rewards`). The per-axis buckets `earnings_work_bucket` and
  `earnings_rewards_bucket` are removed from §5.2 and §9.1. Partners
  who need the work/rewards split MUST use the partner-key projection's
  exact-$ fields. The combined-axis-disclosure concern Q9 raised is no
  longer reachable in the v0.1 wire surface.
- **Q10 — Empty-row policy.** If a provider has zero traffic over a
  window, does it appear in the leaderboard? v0.1 implicitly excludes
  it (sort by earnings/tokens/jobs places it last; limit caps
  visibility). Should there be an explicit `include_inactive=false`
  default with `include_inactive=true` opt-in for partners?
- **Q11 — Partner-projection opt-out (PARTIAL in v0.1.7).** §6.6.2
  documents that partner keys see exact `$` for every provider,
  including providers with `mode = 'bucketed'`. v0.1.7 added the
  `provider_visibility.blocked_from_partner_projection BOOLEAN`
  column stub (§6.1) so the storage shape is pinned; v0.1 rollup
  does NOT consume it. Q11 v0.2 question is now narrower: WHEN the
  rollup honors the column (next IMPL milestone), what should the
  partner-key projection return for a blocked provider — drop the
  row entirely, return bucketed-only (matching public), or surface
  a `blocked_from_partner_projection: true` marker? Surfaced by
  codex round 1, q1.
- **Q12 — Network Stats UI canonical consumer.** The current
  in-repo `frontdoor/console/index.html` is a buyer-side dashboard,
  not the screenshot-style Network Statistics widget that motivated
  this SPEC; that widget lives on the vercel preview today (see
  [[macprovider-vercel-demo]]). Q12 asks where the canonical UI
  consumer of `/v1/stats/*` will live at production launch:
  (a) embedded in `frontdoor/console/index.html` as a new section,
  (b) a new `frontdoor/network-stats/*` mini-app, or (c) lifted from
  the vercel preview into the in-repo console. v0.1 of the API is
  agnostic; this is a follow-up SPEC-? UI spec. Surfaced by codex
  round 1, q2.
- **Q13 — Rewards source semantics.** §9.1a defers `earnings_rewards_*`
  source semantics to an operator-defined `provider_rewards_ledger`
  table whose population logic v0.1 does NOT pin. SPEC-016 v0.1.19
  (the locked payout-pipeline SPEC) intentionally does not split
  work vs rewards. Should v0.2: (a) wait for SPEC-016 v0.2 to define
  the split normatively, (b) introduce a dedicated network-incentives
  SPEC, or (c) leave `provider_rewards_ledger` operator-config
  permanently and treat it as a hostable plug-in surface? Surfaced
  by codex round 2 C2.

---

## 12. References

- `frontdoor/console/index.html` (the existing console stats grid)
- `phase4-coordinator/internal/explorer/handlers.go` (existing
  operator-only explorer; pattern for window parsing, bearer auth,
  in-process rate limiter)
- `specs/SPEC-002-coordinator.md` §4.2, §7.2 (coordinator binary
  topology)
- `specs/SPEC-005-billing.md` §5.1, §11.4 (work-$ semantics, tokens-out
  accounting)
- `specs/SPEC-006-buyer-api.md` §2.2, §3 (public-surface conventions)
- `specs/SPEC-014-provider-portal.md` (portal UI surfaces; v0.9
  candidate will add the earnings-visibility toggle)
- `specs/SPEC-016-payout-pipeline.md` (payout-pipeline operator
  context only; SPEC-017 does NOT derive `rewards-$` semantics
  from SPEC-016 v0.1.19 — see §9.1a and §11 Q13 for the deferred
  source-spec decision)
- RFC 7234 (HTTP caching), RFC 8594 (Sunset header), RFC 9745
  (Deprecation header + `rel="deprecation"` link relation), RFC 4648
  (base64url encoding for partner-key format §3.7), RFC 7232 (304 Not
  Modified semantics §5.9), RFC 2119 (MUST / SHOULD / MAY)
- `specs/design/spec-017/SPEC-017-advisor-round-2026-06-25.md` (codex advisor
  round establishing the four locked decisions Q1-Q4 of §2;
  canonical in-repo copy — the source `omc ask` artifact lives
  outside the worktree and is not citable from inside this SPEC)
