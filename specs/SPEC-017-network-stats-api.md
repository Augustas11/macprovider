# SPEC-017 — Network Stats API

**Version:** 0.1.1 (2026-06-25, draft — codex round-1 fix pass. Round 1 returned 3 CRITICAL + 10 MAJOR + 5 MINOR against v0.1: C1 added §9.1 normative `stats_*` table shapes; C2 added §5.4 partner-key contract; C3 replaced `providers.public_earnings_mode` with the SPEC-017-owned `provider_visibility` side table. MAJORs M1-M10 absorbed (14-field schema sync, §2.3 same-origin rewording, §5.7→§9.5 budget alignment, §7.2 grant list, §5.8 304 exemption, §9.6 backfill softening, §8.2 enum forward-compat, X-Stats-Generated-At everywhere, threshold rationales, `TBD` removed). MINORs m1-m5 also absorbed. Pending codex round-2 confirmation. Full r1 findings: `specs/SPEC-017-r1-audit.md`.)
**Status:** Draft (design-only — no IMPL until v0.1 LOCKED and a separate `BUILD_SPEC_017_IMPL_PROMPT.md` written).
**Depends on:** SPEC-002 v1.4 (coordinator binary hosts the new `/v1/stats/*` mount; §4.2 §7.2 isolation seams), SPEC-005 v0.3 (billing settlement defines `work` $ semantics in §5.1 and tokens-out accounting in §11.4), SPEC-006 v0.9 (public-surface header conventions, error envelope shape, version-prefix path style), SPEC-014 v0.8 (provider portal consumes own-provider exact earnings via its own surfaces — visibility-toggle UI is a follow-up SPEC-014 v0.9 candidate, not in this SPEC), SPEC-016 v0.1.19 (payout pipeline defines `rewards` $ semantics).

---

## Change log

Audit-narrative-by-round detail lives in the per-round audit files under
`specs/SPEC-017-rN-audit.md` (one file per codex round). The change-log
entries below are one-liners per version pointing at the corresponding
audit file. Per [[feedback-spec-audit-file-convention]], audit narrative
does NOT live in this SPEC body.

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
   (SPEC-014); same-origin authenticated views see additional fields.
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
- **Per-provider drill-down** (`/v1/stats/provider/<id>`). Distinct
  surface; gated on earnings-visibility policy being battle-tested.
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

C3. **No request-path queries against billing/session OLTP.** A stats
handler MUST hit `stats_*` tables only. Hot OLTP tables stay protected.

C4. **No handler-level access to billing internals.** The stats DB role
has `SELECT` on `stats_*` only.

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
queries `stats_*` only.

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

An opaque bearer token issued by the operator. Format: `mpk_`
prefix + 32 url-safe base64 chars (33 chars total once the prefix is
counted; the prefix is a literal namespace marker, not part of the
random entropy). Full contract — issuance, hashed storage, rotation,
revocation, allowed-origin validation, rate-limit keying — is pinned
in §5.4. The token MUST NOT appear in any log line, response body, or
metric label; only its `partner_keys.id` (opaque, non-secret) and
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
- Postgres role `stats_reader` — `SELECT` on `stats_*` only; explicitly
  denied on billing/session/pool tables. Created by a new migration in
  §7.2.
- nginx server-block for `stats.streamvc.live` reverse-proxying to the
  same coordinator backend on `/v1/stats/*`, with a dedicated rate-limit
  zone (§5.6).

### 4.3 Wire surface summary

| Endpoint | Auth | Cacheable | Partner-only fields |
|---|---|---|---|
| `GET /v1/stats/overview` | None | yes, public | no |
| `GET /v1/stats/leaderboard` | Optional `Bearer <partner_key>` | yes; key MAY unlock a separate cache projection | yes, behind key |
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
    "models_serving":       5
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
- `network.*` — integers and floats per the table in §5.1.1.
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

| Field | Type | Unit | Source |
|---|---|---|---|
| `tokens_served_total` | int64 | tokens | `stats_overview_current.tokens_in + tokens_out` |
| `tokens_in_total` | int64 | tokens | `stats_overview_current.tokens_in` |
| `tokens_out_total` | int64 | tokens | `stats_overview_current.tokens_out` |
| `requests_total` | int64 | count | `stats_overview_current.requests` |
| `nodes_online` | int32 | count | live pool registry snapshot, cached 30s |
| `nodes_hardware_attested` | int32 | count | subset of `nodes_online` with `attestation_ok = true` |
| `bandwidth_gb_per_s` | int64 | GB/s | sum of `provider_bandwidth_gbps` over online nodes |
| `network_power_kw` | float64 | kW | sum of `provider_estimated_power_kw` over online nodes |
| `network_utilization_pct` | int32 | percent (0–100) | recent-window load average |
| `gpu_cores_total` | int32 | count | sum over online providers |
| `cpu_cores_total` | int32 | count | sum over online providers (P+E) |
| `unified_ram_gb_total` | int32 | GB | sum over online providers |
| `avg_tokens_per_request` | int32 | tokens | `tokens_served_total / max(1, requests_total)` |
| `models_serving` | int32 | count | distinct `model_id` advertised by ≥1 online provider |

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
  "stale_after":   "2026-06-25T18:18:00Z",
  "window":        "7d",
  "sort":          "earnings",
  "limit":         50,
  "totals": {
    "earnings_usd":      1300.0,
    "earnings_work_usd": 77.0,
    "earnings_rewards_usd": 1200.0,
    "tokens":            2525400000,
    "jobs":              900700,
    "active_accounts":   302
  },
  "rows": [
    {
      "rank": 1,
      "pseudonym": "beamy-puppy-4259",
      "earnings_bucket": "$$$",
      "earnings_work_bucket": "$",
      "earnings_rewards_bucket": "$$$",
      "tokens": 119900000,
      "jobs":   55300,
      "exact_earnings": null,
      "exact_earnings_work": null,
      "exact_earnings_rewards": null
    }
  ]
}
```

**Field-level normative rules.**

- `pseudonym` — stable per provider across snapshots and across windows
  (§3.3). Length ≤ 32 chars, `[a-z0-9-]` only.
- `earnings_bucket`, `earnings_work_bucket`, `earnings_rewards_bucket`
  — one of `"$"`, `"$$"`, `"$$$"`, or the string `"-"` (provider had
  zero `$` in the window). Values defined in §6.2.
- `exact_earnings*` — these fields are ALWAYS present in the JSON to
  keep the schema stable across opt-in changes. Their value is `null`
  in the public projection unless the provider has
  `provider_visibility.mode = 'exact'`, in which case the value is a USD
  float with two-decimal precision.
- `rank` — 1-based within the returned page, recomputed against the
  selected `sort` axis.

**Response (200 OK, partner-key projection).**

Identical to the public projection, plus the following partner-only
fields per row:

```json
{
  "earnings_usd":         52.00,
  "earnings_work_usd":     3.87,
  "earnings_rewards_usd": 48.13,
  "first_seen_at":        "2026-04-12T11:24:00Z",
  "last_seen_at":         "2026-06-25T18:01:00Z"
}
```

Partner-only fields surface exact `$` for ALL providers regardless of
`provider_visibility.mode`. This is a deliberate trade: the partner key
acts as an attribution and accountability surface (operator can
revoke), in exchange for trusted exposure of bucketed providers'
exact figures. See §6.6 for the legal posture this requires.

**Response headers (public projection).**

- `Content-Type: application/json; charset=utf-8`
- `Cache-Control: public, max-age=60, s-maxage=60, stale-while-revalidate=120`
- `Vary: Accept-Encoding, Origin, Authorization`
- `ETag: W/"<sha256-of-body>"`
- `X-Stats-Generated-At: <generated_at>` (mirrors the `generated_at`
  field for cache-key debugging; partner clients MUST tolerate this
  header on every `/v1/stats/*` response)

**Response headers (partner-key projection).**

- Same as above, but `Cache-Control: private, max-age=30, s-maxage=30`.
- The `Authorization` header MUST be considered part of the cache key
  at every layer below the origin (`Vary: Authorization` does this for
  CDNs that honor it; nginx-level rate-limit zones MUST be keyed on
  `partner_keys.id`, not on the raw token).

**Errors.**

- `400` invalid `window`/`sort`/`limit`
- `401` invalid or revoked `Authorization`
- `429` rate limit exceeded (§5.6)
- `503` rollup stale beyond §5.8 budget

### 5.3 `GET /v1/stats/health`

**Request.** No query parameters, no auth.

**Response (200 OK).**

```json
{
  "status": "ok",
  "generated_at":      "2026-06-25T18:14:00Z",
  "rollup_lag_seconds": 12,
  "components": {
    "overview":    {"status": "ok", "generated_at": "2026-06-25T18:14:00Z"},
    "timeseries":  {"status": "ok", "generated_at": "2026-06-25T18:14:00Z"},
    "leaderboard_24h": {"status": "ok", "generated_at": "2026-06-25T18:13:00Z"},
    "leaderboard_7d":  {"status": "ok", "generated_at": "2026-06-25T18:10:00Z"},
    "leaderboard_30d": {"status": "ok", "generated_at": "2026-06-25T17:30:00Z"},
    "leaderboard_all": {"status": "ok", "generated_at": "2026-06-25T17:00:00Z"}
  }
}
```

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
  allowed_origins   TEXT[] NOT NULL DEFAULT '{}',
  rate_limit_rpm    INT  NOT NULL DEFAULT 600,
  rate_limit_burst  INT  NOT NULL DEFAULT 1200,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by        TEXT NOT NULL,
  revoked_at        TIMESTAMPTZ,
  revoked_reason    TEXT,
  rotated_from_id   BIGINT REFERENCES partner_keys(id),
  last_used_at      TIMESTAMPTZ,
  UNIQUE (token_hash)
);
CREATE INDEX ON partner_keys (prefix);
```

Field rules:

- `token_hash` — `sha256` of the raw token bytes, stored binary, NOT
  the raw token. The raw token MUST NOT be persisted server-side
  anywhere; once shown to the operator at issuance time it is unrecoverable.
- `prefix` — the first 8 characters of the raw token (including the
  `mpk_` namespace). Stored for log-correlation and last-4 display
  in operator tooling, NOT for auth.
- `allowed_origins` — an array of exact-match origin strings (e.g.
  `https://partner.example.com`). Empty array means "no Origin
  restriction" — public partner usage from any origin. See §5.7 CORS
  rules for how this interacts with browser-side embedding.
- `rate_limit_rpm` / `rate_limit_burst` — per-key per-endpoint limits.
  The operator MAY set higher values per key; the API MUST clamp to
  the configured values from `partner_keys`, not to a global default.
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
   [--allowed-origin https://acme.example.com] [--rpm 600] [--burst 1200]`.
2. The subcommand generates 32 random bytes, prefixes with `mpk_`,
   url-safe base64-encodes the random bytes, hashes the resulting
   token, INSERTs into `partner_keys`, and prints the raw token to
   stdout exactly once.
3. The operator delivers the token to the partner via a side channel
   (email, signed message). The repository never persists the raw
   token.

#### 5.4.3 Authentication on request

For each request carrying `Authorization: Bearer <token>`:

1. The handler MUST extract `<token>`, compute `sha256(<token>)`, and
   SELECT the matching `partner_keys` row by `token_hash`.
2. If no row matches OR `revoked_at IS NOT NULL`, return 401 with
   `code: "unauthorized"`. The handler MUST NOT distinguish the two
   cases in the response (timing attack resistance).
3. If the row matches, the handler MAY update `last_used_at` (best
   effort, not transactional with the response).
4. If `allowed_origins` is non-empty AND the request's `Origin` header
   is not in that array, return 401 (NOT 403, to avoid leaking the
   existence of the key to non-allowlisted callers).
5. On success, all rate-limit accounting (§5.6) MUST key on
   `partner_keys.id`, NOT on the raw token or on the client IP.

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

| Tier | Per-IP limit | Per-key limit | Burst | Enforced at |
|---|---|---|---|---|
| Public anon | 60 req/min per IP per endpoint | n/a | 120 | nginx `limit_req_zone` (primary), in-process bucket (fallback) |
| Partner keyed | n/a | 600 req/min per key per endpoint | 1200 | in-process bucket keyed by `partner_keys.id` |

Both tiers MUST return `429 Too Many Requests` on exhaustion, with
`Retry-After: <seconds>` and a JSON body per §5.9. nginx is the
primary enforcement layer for the public tier so a misbehaving
partner cannot starve the coordinator process; the in-process bucket
exists as a defense-in-depth fallback.

Cloudflare bot-management and CAPTCHA challenges MAY be layered above
nginx; the SPEC does not mandate them but does not preclude them.

### 5.7 CORS

- `/v1/stats/overview` and `/v1/stats/health` — `Access-Control-Allow-Origin:
  *`. Partner-friendly.
- `/v1/stats/leaderboard` public projection — `Access-Control-Allow-Origin:
  *`.
- `/v1/stats/leaderboard` partner-key projection — `Access-Control-Allow-Origin:
  <Origin>` echoed when `Origin` is on the allowlist
  (`console.streamvc.live`, `portal.streamvc.live`, and any origin
  whitelisted in a partner key's `partner_keys.allowed_origins`
  array). All other origins receive `*` plus the public projection
  (auth header rejected with 401 if it was sent from a non-allowlisted
  Origin, to discourage embedding the key in browser-side code).

Preflight: respond to `OPTIONS` with
`Access-Control-Allow-Methods: GET, HEAD, OPTIONS`,
`Access-Control-Allow-Headers: Authorization, Content-Type`,
`Access-Control-Max-Age: 3600`.

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

`304 Not Modified` is exempt from this envelope: it MUST be returned
with an empty body and only the headers required by RFC 7232 (`ETag`,
`Cache-Control`, `Vary`). All other non-2xx responses MUST use the
exact shape below.

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
| `unauthorized` | 401 | invalid or revoked `Authorization` |
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
  provider_id  TEXT PRIMARY KEY,
  mode         TEXT NOT NULL DEFAULT 'bucketed'
               CHECK (mode IN ('bucketed','exact')),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Semantics:

- A provider with NO row in `provider_visibility` is treated as
  `mode = 'bucketed'`. This is the implicit default for new and
  pre-existing providers; cutover does NOT require backfill.
- The portal (SPEC-014 v0.9 candidate) writes to this table on
  toggle. SPEC-017 v0.1 does NOT specify the portal's HTTP handler;
  it only pins the storage shape.
- The rollup MUST left-join `provider_visibility` when producing the
  leaderboard projection; absence of a row is equivalent to
  `mode = 'bucketed'`.

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

Work and rewards each get their own bucket (computed against the
same thresholds, scoped to that metric). The rationale is that a
provider with `work $0.50 + rewards $50` should not get `$$$` on
both fields — the disclosure surface is per-axis.

**Threshold rationale (v0.1).** Boundaries are absolute USD figures
chosen against the **current beta network's revenue density** —
SPEC-016 v0.1.19 is still pre-IMPL and the current 7d leaderboard
shows top earners at ~$52 (see the
`SPEC-017-advisor-round-2026-06-25.md` artifact for the screenshot
snapshot). At those magnitudes, `$$$` at `≥ $250 / 7d` correctly
marks a clear top tier without exposing meaningful operator-level
information. As the network grows, the absolute boundaries will
under-fit (everyone tops out at `$$$`); Q1 in §11 flags whether
v0.2 shifts to percentile-of-network-revenue. Until then, the
operator MAY tighten the boundaries (e.g. raise `$$$` floor) as an
additive change without a SPEC bump, provided the future-reserved
slots `$$$$` and `$$$$$` are introduced per §8.2.1.

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

Providers who object to partner-key exposure of their bucketed
earnings have no v0.1 mechanism to suppress it. Q1' in §11
explicitly flags whether v0.2 should add a per-provider "block from
partner projection" toggle.

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

A new Postgres role `stats_reader`:

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
  provider_visibility
TO stats_reader;
```

The grant list MUST match the `stats_*` and SPEC-017-owned table
inventory in §9.1 exactly. The `stats_components_health` table feeds
`/v1/stats/health` (§5.3); the `provider_visibility` table is
read-only at request time (writes come via the SPEC-014 portal
surface using a different role). `provider_visibility_audit` is
write-only at request time and is NOT in the handler's grant list.
`stats_late_events` (§9.3) is rollup-internal and is NOT in the
handler's grant list either.

The stats handlers MUST connect with this role and MUST NOT share a
connection pool with the explorer or billing handlers. A separate
`*sql.DB` instance enforces this; tests MUST verify the connection
attempt to billing tables fails.

The rollup job runs with a separate role `stats_rollup` that has
SELECT on OLTP tables and INSERT/UPDATE on `stats_*` plus
`stats_late_events`. The two roles MUST NOT be the same. The portal
toggle (SPEC-014 v0.9) runs with a third role `provider_portal`
which has INSERT/UPDATE on `provider_visibility` and INSERT on
`provider_visibility_audit`; it does NOT have any grant on `stats_*`.

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
- New optional query params with safe defaults.
- New error codes appended to the §5.9 vocabulary, subject to §8.2.1
  forward-compat rules below.
- New bucket values appended to the §6.2 `$/$$/$$$/-` set, subject
  to §8.2.1 forward-compat rules below.
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
prior shape, and a `Deprecation` header per RFC 8594 on every `/v1/*`
response during overlap.

### 8.4 Sunset header

Once a `/v1/*` endpoint enters deprecation, every response MUST carry:

- `Deprecation: true`
- `Sunset: Fri, 25 Dec 2026 00:00:00 GMT` (whatever the operator-decided
  sunset date is, RFC 8594 / RFC 7231 IMF-fixdate format with
  correct day-of-week)
- `Link: <https://docs.streamvc.live/network-stats-api/v2-migration>;
  rel="deprecation"`

### 8.5 Public changelog location

A versioned changelog MUST live at
`docs/network-stats-api/CHANGELOG.md` in this repo, with one entry per
shipped change (additive or breaking). Each entry MUST cite the PR
number and the SPEC version that introduced the change.

---

## 9. Rollup pipeline

### 9.1 Table schemas (normative)

Every `stats_*` and `stats_components_health` table is owned by
SPEC-017 and defined here. The handler's grant list in §7.2 MUST
match this inventory exactly.

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
  earnings_work_bucket     TEXT NOT NULL,
  earnings_rewards_bucket  TEXT NOT NULL,
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

CREATE TABLE stats_components_health (
  component                TEXT PRIMARY KEY,
    -- one of: 'overview', 'timeseries',
    --        'leaderboard_24h', 'leaderboard_7d',
    --        'leaderboard_30d', 'leaderboard_all'
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

The `provider_id → pseudonym` mapping is deterministic per provider
and persisted in `stats_leaderboard_*.pseudonym`. The mapping
function is operator-owned; v0.1 does NOT pin the function (§11 Q4
flags pseudonym-rotation policy).

### 9.2 Cadence

| Table | Refresh cadence | Source query shape |
|---|---|---|
| `stats_overview_current` | every 30s | aggregate over last 24h (or all-time for cumulative fields) |
| `stats_timeseries_rpm_30m` | every 30s, rolling | aggregate per-minute counts last 30 minutes |
| `stats_timeseries_tpm_30m` | every 30s, rolling | aggregate per-minute tokens last 30 minutes |
| `stats_leaderboard_24h` | every 60s | per-provider sums over last 24h |
| `stats_leaderboard_7d` | every 5 min | per-provider sums over last 7d |
| `stats_leaderboard_30d` | every 30 min | per-provider sums over last 30d |
| `stats_leaderboard_all` | every 6 hours | per-provider sums since rollup-start |

These are the v0.1 floors. The operator MAY tighten them in production
without a SPEC change; loosening them requires a SPEC bump.

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

### 9.4 All-time accumulation vs recompute

`stats_leaderboard_all` is incrementally accumulated between nightly
rebuilds (§9.3). The nightly job rebuilds from scratch and overwrites,
which doubles as a drift-detection mechanism: if the rebuild differs
from the incremental snapshot by more than 0.5% on any axis, an alert
fires and the rebuild value wins.

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
  with its existing `generated_at`; health endpoint reports `degraded`
  if past target staleness, `down` if past 2× target.
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
`partial_history_since` RFC 3339 timestamp. This is the additive
v0.1 schema field; partners are responsible for surfacing the
"window is short" caveat in their UI. Until `partial_history_since`
is more than 30 days in the past (for `30d`) or more than the
operator-defined `all` floor in the past, this field is REQUIRED in
the response; once the rollup has accumulated enough history, the
field MAY be omitted (additive, not breaking — partner clients MUST
tolerate omission).

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
  shape, all 14 `network.*` fields present (per the §5.1.1 schema
  table), and exactly 30 points in each timeseries.
- **AC-2.** `GET /v1/stats/leaderboard` with no `window` query returns
  the `24h` window. With invalid `window=foo` returns 400 with
  `code: "bad_request"`.
- **AC-3.** `GET /v1/stats/leaderboard` returns 401 with
  `code: "unauthorized"` when an `Authorization: Bearer mpk_invalid`
  header is sent.
- **AC-4.** Public leaderboard rows for providers with
  `provider_visibility.mode = 'bucketed'` (or no `provider_visibility`
  row) have `exact_earnings*` fields
  present as JSON `null` (NOT missing).
- **AC-5.** Public leaderboard rows for providers with
  `provider_visibility.mode = 'exact'` have `exact_earnings*` fields
  populated with USD floats to two-decimal precision.
- **AC-6.** Partner-key leaderboard rows ALWAYS have `earnings_usd`,
  `earnings_work_usd`, `earnings_rewards_usd` populated regardless of
  `provider_visibility.mode`.
- **AC-7.** `GET /v1/stats/health` returns 200 even when components
  are `degraded`. Returns non-200 ONLY when the coordinator process
  itself is unhealthy.
- **AC-8.** A 61st request from the same IP in a 60s window to
  `/v1/stats/overview` returns 429 with `Retry-After` and
  `code: "rate_limited"`.
- **AC-9.** `stats_reader` Postgres role CANNOT execute
  `SELECT 1 FROM billing_ledger LIMIT 1`; the query MUST return a
  permission-denied error.
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
- **AC-13.** `OPTIONS /v1/stats/leaderboard` returns 204 (or 200) with
  `Access-Control-Allow-Methods: GET, HEAD, OPTIONS` and
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
  prints the raw token exactly once to stdout, INSERTs a row into
  `partner_keys` with `token_hash = sha256(raw_token)`, and the raw
  token does NOT appear in any log line, journald entry, or DB row
  after subprocess exit.
- **AC-18.** A request to `/v1/stats/leaderboard` with
  `Authorization: Bearer <revoked_token>` returns 401 with
  `code: "unauthorized"`. The 401 latency MUST be within ±20% of the
  401 latency for `Bearer mpk_invalid` (timing-attack resistance, §5.4.3).
- **AC-19.** A SELECT against `provider_visibility` for a `provider_id`
  with no row returns zero rows; the leaderboard projection treats
  this as `mode = 'bucketed'` (§6.1 left-join semantics). AC verified
  by inserting a leaderboard row for a never-toggled provider and
  asserting `exact_earnings*` are JSON null in the public projection.
- **AC-20.** No `provider_visibility_audit` row exists with
  `new_mode = 'exact' AND actor_kind = 'operator'` (§6.6.3 mechanical
  check). Verified by a SQL fixture and a CI assertion.

---

## 11. Open questions (for the audit loop)

These are explicitly NOT decided in v0.1. The audit loop should
challenge each and propose pins for v0.2.

- **Q1 — Bucket boundaries.** Are the absolute thresholds in §6.2 the
  right model, or should buckets shift to percentile-of-network-revenue
  (e.g. `$$$` = top 10% earner by window) so that the disclosure
  surface stays uniform as the network scales? Absolute is simpler;
  percentile re-anchors automatically.
- **Q2 — Partner key issuance UX.** Self-serve via portal,
  operator-issued via Slack DM, or both? v0.1 pins "operator-issued
  only" by default in §3.7 but does not normatively forbid self-serve.
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
- **Q9 — Bucket value when work and rewards differ in tier.** §6.2
  computes per-axis. If a provider has `work $0.50 + rewards $50` over
  24h, the row shows `earnings_bucket = "$$$"` (combined ≥ $50),
  `earnings_work_bucket = "$"`, `earnings_rewards_bucket = "$$$"`.
  Is the combined-bucket disclosure too revealing on its own?
- **Q10 — Empty-row policy.** If a provider has zero traffic over a
  window, does it appear in the leaderboard? v0.1 implicitly excludes
  it (sort by earnings/tokens/jobs places it last; limit caps
  visibility). Should there be an explicit `include_inactive=false`
  default with `include_inactive=true` opt-in for partners?
- **Q11 — Partner-projection opt-out.** §6.6.2 documents that partner
  keys see exact `$` for every provider, including providers with
  `mode = 'bucketed'`. Should v0.2 add a per-provider "block from
  partner projection" toggle so providers can suppress exact $
  exposure across BOTH public and partner surfaces? The legal
  posture works either way; the question is whether the partner-trust
  bargain is good enough as the operator-issued, operator-revocable
  surface it is in v0.1. Surfaced by codex round 1, q1.
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
- `specs/SPEC-016-payout-pipeline.md` §5.1 (rewards-$ semantics)
- RFC 7234 (HTTP caching), RFC 8594 (Sunset header), RFC 2119 (MUST /
  SHOULD / MAY)
- `specs/SPEC-017-advisor-round-2026-06-25.md` (mirror of the source artifact at `.omc/artifacts/ask/codex-i-m-designing-a-public-network-stats-api-for-macprovider-a-d-2026-06-25T18-18-42-442Z.md` in the main checkout)
  (codex advisor round establishing the four locked decisions)
