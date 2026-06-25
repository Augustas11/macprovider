# SPEC-017 — Network Stats API

**Version:** 0.1 (2026-06-25, initial draft. Adopts locked Q1–Q4 design picks from codex advisor round of 2026-06-25 (artifact at `.omc/artifacts/ask/codex-i-m-designing-a-public-network-stats-api-for-macprovider-a-d-2026-06-25T18-18-42-442Z.md`): (Q1) separate rollup pipeline, (Q2) public overview + optional API keys on leaderboard, (Q3) bucketed earnings default + provider opt-in for exact `$`, (Q4) embed in coordinator binary. Pending codex round-1 audit.)
**Status:** Draft (design-only — no IMPL until v0.1 LOCKED and a separate `BUILD_SPEC_017_IMPL_PROMPT.md` written).
**Depends on:** SPEC-002 v1.4 (coordinator binary hosts the new `/v1/stats/*` mount; §4.2 §7.2 isolation seams), SPEC-005 v0.3 (billing settlement defines `work` $ semantics in §5.1 and tokens-out accounting in §11.4), SPEC-006 v0.9 (public-surface header conventions, error envelope shape, version-prefix path style), SPEC-014 v0.8 (provider portal consumes same-origin authenticated `$` visibility — visibility-toggle UI is a follow-up SPEC-014 v0.9 candidate, not in this SPEC), SPEC-016 v0.1.19 (payout pipeline defines `rewards` $ semantics; locked version TBD — re-pin at SPEC-017 v0.1 LOCK time).

---

## Change log

Audit-narrative-by-round detail lives in the per-round audit files under
`specs/SPEC-017-rN-audit.md` (one file per codex round). The change-log
entries below are one-liners per version pointing at the corresponding
audit file. Per [[feedback-spec-audit-file-convention]], audit narrative
does NOT live in this SPEC body.

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
SPEC-014 v0.9 follow-up will add the **earnings-visibility toggle UI**
that flips a provider between bucketed (default) and exact `$` display;
v0.1 of this SPEC defines only the storage column, the API behaviour,
and the audit-log shape.

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
this SPEC's data only via a shared `providers.public_earnings_mode`
column.

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
provider whose `public_earnings_mode = 'bucketed'`. Buckets per window
are defined in §6.2. Providers MAY opt in via the SPEC-014 v0.9 portal
toggle to surface exact `$` publicly; the API column `public_earnings_mode`
governs which path the rollup produces.

Same-origin authenticated portal views see exact `$` **for the
logged-in provider's own row only**, regardless of mode (§6.4).

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

Per-provider column `public_earnings_mode IN ('bucketed','exact')`.
Default for new providers and grandfathered providers at cutover is
`bucketed`. Changes are logged to an audit table (§6.5).

### 3.7 Partner key

An opaque bearer token issued by the operator. Format: `mpk_` prefix
+ 32 url-safe base64 chars. Stored in the new `partner_keys` table
(§5.3). The token MUST NOT appear in any log line, only its
`partner_keys.id` and `partner_keys.label` MAY appear.

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
  zone (§5.5).

### 4.3 Wire surface summary

| Endpoint | Auth | Cacheable | Partner-only fields |
|---|---|---|---|
| `GET /v1/stats/overview` | None | yes, public | no |
| `GET /v1/stats/leaderboard` | Optional `Bearer <partner_key>` | yes; key MAY unlock a separate cache projection | yes, behind key |
| `GET /v1/stats/health` | None | short cache (10s) | no |

`HEAD` MUST be supported on every `GET`. `OPTIONS` MUST return CORS
preflight per §5.6. Any other verb MUST return `405 Method Not Allowed`
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
  (preflight handled per §5.6).

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

- `503 Service Unavailable` — see §5.7.

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
  `public_earnings_mode = 'exact'`, in which case the value is a USD
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
`public_earnings_mode`. This is a deliberate trade: the partner key
acts as an attribution and accountability surface (operator can
revoke), in exchange for trusted exposure of bucketed providers'
exact figures. See §6.6 for the legal posture this requires.

**Response headers (public projection).**

- `Content-Type: application/json; charset=utf-8`
- `Cache-Control: public, max-age=60, s-maxage=60, stale-while-revalidate=120`
- `Vary: Accept-Encoding, Origin, Authorization`
- `ETag: W/"<sha256-of-body>"`

**Response headers (partner-key projection).**

- Same as above, but `Cache-Control: private, max-age=30, s-maxage=30`.
- The `Authorization` header MUST be considered part of the cache key
  at every layer below the origin (`Vary: Authorization` does this for
  CDNs that honor it; nginx-level rate-limit zones MUST be keyed on
  `partner_keys.id`, not on the raw token).

**Errors.**

- `400` invalid `window`/`sort`/`limit`
- `401` invalid or revoked `Authorization`
- `429` rate limit exceeded (§5.5)
- `503` rollup stale beyond §5.7 budget

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

- `status` — `"ok"` if every component is within its SLA (§4.1 of the
  rollup spec, §5.7), `"degraded"` if any component is beyond budget,
  `"down"` if `overview` or `leaderboard_24h` is beyond `2× budget`.
- `rollup_lag_seconds` — wall-clock seconds between now and the oldest
  component's `generated_at`.

**Response headers.**

- `Cache-Control: public, max-age=10, s-maxage=10` (intentionally
  short: health is meant to drift in real time).
- `Vary: Accept-Encoding, Origin`

**Errors.** This endpoint MUST return `200` even when components are
degraded — partners use the JSON `status` field to drive their own UI.
A non-200 response from `/health` means the coordinator process itself
is unhealthy, not the rollup.

### 5.4 Partner-only field stability contract

Fields under §5.2's partner-key projection are covered by the §8
versioning policy: they MUST NOT change shape or be removed without a
`/v2/*` version bump and a documented 6-month sunset window. New
partner-only fields MAY be added additively at any time without a
version bump.

Public-projection fields share the same contract; partner-only is
just a tighter accountability surface.

### 5.5 Rate limits

| Tier | Per-IP limit | Per-key limit | Burst | Enforced at |
|---|---|---|---|---|
| Public anon | 60 req/min per IP per endpoint | n/a | 120 | nginx `limit_req_zone` (primary), in-process bucket (fallback) |
| Partner keyed | n/a | 600 req/min per key per endpoint | 1200 | in-process bucket keyed by `partner_keys.id` |

Both tiers MUST return `429 Too Many Requests` on exhaustion, with
`Retry-After: <seconds>` and a JSON body per §5.8. nginx is the
primary enforcement layer for the public tier so a misbehaving
partner cannot starve the coordinator process; the in-process bucket
exists as a defense-in-depth fallback.

Cloudflare bot-management and CAPTCHA challenges MAY be layered above
nginx; the SPEC does not mandate them but does not preclude them.

### 5.6 CORS

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

### 5.7 Staleness and 503 budget

- `/v1/stats/overview` MUST serve a 503 if `stats_overview_current.generated_at`
  is older than `120 seconds` (4× the normal 30s cadence).
- `/v1/stats/leaderboard` MUST serve a 503 if the requested window's
  `stats_leaderboard_<window>.generated_at` is older than `2× the
  window's documented refresh cadence` from §4.4.
- A 503 from this surface MUST include `Retry-After: 30` and a JSON
  body per §5.8 with `code: "stats_stale"`.

`/v1/stats/health` MUST NOT return 503 for stale rollups (§5.3); a 503
from `/health` reflects the coordinator process itself.

### 5.8 Error envelope

Every non-2xx response MUST use this exact shape:

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
| `stats_stale` | 503 | rollup older than §5.7 budget |
| `internal` | 500 | unhandled; MUST NOT leak stack/SQL |

`retry_after_seconds` is present only for `rate_limited` and
`stats_stale`.

---

## 6. Earnings visibility model

### 6.1 Storage

A new column on the existing `providers` table:

```
public_earnings_mode TEXT NOT NULL DEFAULT 'bucketed'
  CHECK (public_earnings_mode IN ('bucketed', 'exact'))
```

Migration MUST set `'bucketed'` for every existing provider at cutover.
The default for INSERTs is `'bucketed'`. The portal MUST NOT permit
new-provider onboarding to set `'exact'` without an explicit
post-onboarding action by the provider; see §6.5.

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

Q1 in §11 flags whether these stay absolute or shift to percentile-based
in v0.2.

### 6.3 Provider opt-in flow (cross-SPEC handoff)

The actual toggle UI is a SPEC-014 v0.9 follow-up. v0.1 of this SPEC
pins only:

- A SQL UPDATE `providers SET public_earnings_mode = $1 WHERE id = $2`
  is the sole state transition path.
- The provider-portal API endpoint that triggers this UPDATE MUST
  require provider authentication (SPEC-014 §authn) and MUST log to
  the audit table in §6.5.
- The change takes effect on the next rollup snapshot; v0.1 makes no
  guarantee of sub-30s propagation.

### 6.4 Same-origin authenticated views

The same `GET /v1/stats/leaderboard` endpoint serves console, portal,
and partners. The portal MUST NOT depend on this endpoint to surface
the logged-in provider's own exact `$`; the portal's existing
SPEC-014 surfaces already expose own-provider exact earnings.

This SPEC makes no special-case behaviour for `Origin:
portal.streamvc.live`. The endpoint is uniform.

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

By default, every provider's `$` is bucketed publicly. The portal's
opt-in screen (SPEC-014 v0.9) MUST display: "When you enable exact
earnings display, the public API will publish your USD earnings per
window. This is visible to anyone, including partners' websites." The
provider's affirmative click is the consent record; the audit row in
§6.5 is the durable evidence.

Operator MAY override `'exact' → 'bucketed'` (but not the reverse)
without provider consent in response to a legal hold or operator
incident. Operator MUST NOT flip a provider to `'exact'` without the
provider's affirmative consent.

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
  stats_health
TO stats_reader;
```

The stats handlers MUST connect with this role and MUST NOT share a
connection pool with the explorer or billing handlers. A separate
`*sql.DB` instance enforces this; tests MUST verify the connection
attempt to billing tables fails.

The rollup job runs with a separate role (`stats_rollup`) that has
SELECT on OLTP tables and INSERT/UPDATE on `stats_*`. The two roles
MUST NOT be the same.

### 7.3 Process isolation

A panic in any `/v1/stats/*` handler MUST NOT crash the coordinator
process. The HTTP mux MUST wrap the stats subtree in a `recover`
middleware that logs the panic and returns a 500 with the §5.8
envelope.

### 7.4 nginx config

A new nginx server-block (a new file under
`scripts/nginx/snippets/stats.conf` or similar — exact path is an IMPL
choice) MUST:

- Define `limit_req_zone` for `/v1/stats/overview`, `/v1/stats/leaderboard`,
  `/v1/stats/health` separately.
- Add headers per the §5.6 CORS policy.
- Strip the `Authorization` header from access logs.
- Set `proxy_cache_path` for the public projections only.
- Honor `Vary: Authorization` by NOT caching the partner-key projection
  at nginx (let the in-process handler emit `Cache-Control: private`).

### 7.5 Read-replica posture

v0.1 does NOT require a Postgres read replica. The rollup job is the
heaviest load this SPEC adds, and it runs out-of-band against the
primary at a documented cadence.

If the rollup primary impact exceeds 5% of OLTP CPU over a 7-day window
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

Additive changes (new top-level fields, new optional query params with
defaults, new buckets, new error codes appended to the §5.8 vocabulary)
MAY ship without a version bump and MUST be documented in the
public-facing changelog (§8.5).

### 8.3 Breaking changes

Field removals, field-meaning changes, error-code repurposing, or
window-vocabulary changes MUST ship behind `/v2/*` with a minimum
**6-month** overlap window during which `/v1/*` continues to serve the
prior shape, and a `Deprecation` header per RFC 8594 on every `/v1/*`
response during overlap.

### 8.4 Sunset header

Once a `/v1/*` endpoint enters deprecation, every response MUST carry:

- `Deprecation: true`
- `Sunset: Tue, 25 Dec 2026 00:00:00 GMT` (whatever the operator-decided
  sunset date is, RFC 8594 format)
- `Link: <https://docs.streamvc.live/network-stats-api/v2-migration>;
  rel="deprecation"`

### 8.5 Public changelog location

A versioned changelog MUST live at
`docs/network-stats-api/CHANGELOG.md` in this repo, with one entry per
shipped change (additive or breaking). Each entry MUST cite the PR
number and the SPEC version that introduced the change.

---

## 9. Rollup pipeline

### 9.1 Cadence

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

### 9.2 Late-event correction

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
  at a low-traffic UTC hour (suggest 09:00 UTC), reconciling against
  OLTP truth and overwriting the incremental snapshot.

### 9.3 All-time accumulation vs recompute

`stats_leaderboard_all` is incrementally accumulated between nightly
rebuilds (§9.2). The nightly job rebuilds from scratch and overwrites,
which doubles as a drift-detection mechanism: if the rebuild differs
from the incremental snapshot by more than 0.5% on any axis, an alert
fires and the rebuild value wins.

### 9.4 Freshness SLA

| Endpoint | Target staleness | 503 budget (§5.7) |
|---|---|---|
| `/v1/stats/overview` | 30s | 120s |
| `/v1/stats/leaderboard?window=24h` | 60s | 300s |
| `/v1/stats/leaderboard?window=7d` | 5 min | 30 min |
| `/v1/stats/leaderboard?window=30d` | 30 min | 4 hours |
| `/v1/stats/leaderboard?window=all` | 6 hours | 24 hours |
| `/v1/stats/health` | n/a (advisory) | n/a |

### 9.5 Failure modes

- Rollup job missed its tick: continue serving the previous snapshot
  with its existing `generated_at`; health endpoint reports `degraded`
  if past target staleness, `down` if past 2× target.
- Rollup job hit a SQL error: log to the audit logger, increment a
  metric counter (`stats_rollup_errors_total`), retry on next tick.
- Rollup job hit a panic: recover middleware logs and restarts the job
  scheduler for that table; an explicit operator runbook entry is
  required (cross-ref: a new operator-runbook section, not in this
  SPEC).

### 9.6 Backfill on cutover

When SPEC-017 first ships, `stats_leaderboard_30d` and
`stats_leaderboard_all` MUST be populated from full historical OLTP
billing data before the public endpoints are enabled. The cutover
runbook (operator follow-up, not in this SPEC) gates the nginx
server-block activation on the backfill completing.

If full backfill is operationally infeasible, the operator MAY ship
with rollup-start-date forward only, in which case the public response
for `30d` and `all` MUST include a top-level `partial_history_since`
RFC 3339 timestamp; this is an additive field (§8.2) and does not
require a SPEC bump.

---

## 10. Acceptance criteria

An implementer MUST verify all ACs below before declaring SPEC-017 v0.1
implemented. Each is mechanically checkable in tests or an operator
runbook step.

- **AC-1.** `GET /v1/stats/overview` returns 200 with the §5.1 JSON
  shape, all 13 `network.*` fields present, and exactly 30 points in
  each timeseries.
- **AC-2.** `GET /v1/stats/leaderboard` with no `window` query returns
  the `24h` window. With invalid `window=foo` returns 400 with
  `code: "bad_request"`.
- **AC-3.** `GET /v1/stats/leaderboard` returns 401 with
  `code: "unauthorized"` when an `Authorization: Bearer mpk_invalid`
  header is sent.
- **AC-4.** Public leaderboard rows for providers with
  `public_earnings_mode = 'bucketed'` have `exact_earnings*` fields
  present as JSON `null` (NOT missing).
- **AC-5.** Public leaderboard rows for providers with
  `public_earnings_mode = 'exact'` have `exact_earnings*` fields
  populated with USD floats to two-decimal precision.
- **AC-6.** Partner-key leaderboard rows ALWAYS have `earnings_usd`,
  `earnings_work_usd`, `earnings_rewards_usd` populated regardless of
  `public_earnings_mode`.
- **AC-7.** `GET /v1/stats/health` returns 200 even when components
  are `degraded`. Returns non-200 ONLY when the coordinator process
  itself is unhealthy.
- **AC-8.** A 61st request from the same IP in a 60s window to
  `/v1/stats/overview` returns 429 with `Retry-After` and
  `code: "rate_limited"`.
- **AC-9.** `stats_reader` Postgres role CANNOT execute
  `SELECT 1 FROM billing_ledger LIMIT 1`; the query MUST return a
  permission-denied error.
- **AC-10.** Toggling `public_earnings_mode` via the portal inserts
  exactly one row into `provider_visibility_audit` with `actor_kind =
  'provider'`.
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
  `internal/billing` or `internal/explorer` (enforced by a CI lint).

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
- **Q7 — Backfill on cutover.** §9.6 allows partial-history rollout
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
- `.omc/artifacts/ask/codex-i-m-designing-a-public-network-stats-api-for-macprovider-a-d-2026-06-25T18-18-42-442Z.md`
  (codex advisor round establishing the four locked decisions)
