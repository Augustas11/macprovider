/goal

Working directory: /Users/augstar/macprovider-poc

Read `specs/SPEC-007-explorer.md` (v0.2, ~2,600 lines) in full before
writing any code. Pay special attention to:

  section 2    locked decisions D1-D15 (read-only; do not relitigate)
  section 3    invariants, especially section 3.9 read-only invariant
  section 4    architecture (browser -> coordinator -> gateway proxy)
  section 5    coordinator /admin/explorer/* endpoint specs
  section 6    gateway /admin/explorer/* endpoint specs (read-only)
  section 7    data sources and join keys (request_id is canonical)
  section 8    nine views and per-field privacy tags
  section 9    polling contract (hidden-tab pause, 60 RPM cap)
  section 10   auth (shared coordinator bearer; D15)
  section 11   static asset surface (embed.FS, no third-party JS)
  section 13   coordinator.yaml additions (per-endpoint window knobs)
  section 14   failure modes (gateway timeout -> 200 partial=true)
  section 15   29 acceptance criteria; each MUST be testable
  section 16   audit categories
  section 17   explicit out-of-scope (do not implement these)

Also read:
  - `specs/SPEC-007-operator-decisions.md` (D1-D15, especially D15)
  - `specs/FIX_SPEC_007_V0_2.md` (decision rationale for v0.2 changes)
  - `phase5-gateway/internal/config/config.go` (resolveEnvValue pattern)
  - `phase5-gateway/internal/router/server.go:1898-1904` (existing
    operatorAuthorized — gateway explorer routes reuse this per D15)
  - `phase4-coordinator/internal/ws/server.go:1456-1458` (coordinator
    operator bearer check)

Hard scope guardrails — do NOT do any of these:

  1. Do NOT implement any mutating endpoint. Settlement claim/consume/
     void, key issuance, provider admission, kill switches stay on
     existing /admin/* surfaces. Explorer is read-only.
  2. Do NOT add new tables, materialized rollups, or analytics stores.
     All reads come from existing coordinator and gateway SQLite.
  3. Do NOT add a durable provider event / session / reconnect table
     (D6 deferred). Per-pool live state only.
  4. Do NOT add SSE / WebSocket endpoints (D8 polling-only in v1).
  5. Do NOT introduce a third-party JS framework. Static bundle is
     plain HTML/CSS/JS embedded via `embed.FS`.
  6. Do NOT add a distinct gateway-only bearer for explorer routes.
     Per D15, gateway /admin/explorer/* reuses `coordinator.operator_key`
     via the existing `operatorAuthorized` middleware.
  7. Do NOT add `env:` resolution to coordinator config in this run.
     OQ deferred to a separate follow-up. `auth.operator_key` stays
     a literal YAML string.

After completing each Part below, run the relevant build check:

  cd phase4-coordinator && GOCACHE=/private/tmp/macprovider-go-build-cache go build ./...
  cd phase5-gateway && GOCACHE=/private/tmp/macprovider-go-build-cache go build ./...

Fix any build errors before moving to the next Part. Run the full test
suites only at PART G.

---

## PART A — Coordinator config additions

File: `phase4-coordinator/internal/config/config.go`

Add an `ExplorerConfig` struct and wire it into the root Config struct.
Follow the existing pattern (YAML tags, setDefaults, validate).

  type ExplorerConfig struct {
      Enabled                       bool   `yaml:"enabled"`
      BindPath                      string `yaml:"bind_path"`
      GatewayBaseURL                string `yaml:"gateway_base_url"`
      GatewayTimeoutMs              int    `yaml:"gateway_timeout_ms"`
      QueryTimeoutMs                int    `yaml:"query_timeout_ms"`
      PollMinIntervalSeconds        int    `yaml:"poll_min_interval_seconds"`
      ActivityMaxWindowDays         int    `yaml:"activity_max_window_days"`
      ActivityDefaultWindowHours    int    `yaml:"activity_default_window_hours"`
      BuyersMaxWindowDays           int    `yaml:"buyers_max_window_days"`
      BuyersDefaultWindowHours      int    `yaml:"buyers_default_window_hours"`
      LedgerMaxWindowDays           int    `yaml:"ledger_max_window_days"`
      LedgerDefaultWindowHours      int    `yaml:"ledger_default_window_hours"`
      SessionsMaxWindowDays         int    `yaml:"sessions_max_window_days"`
      SessionsDefaultWindowHours    int    `yaml:"sessions_default_window_hours"`
      SettlementsMaxWindowDays      int    `yaml:"settlements_max_window_days"`
      SettlementsDefaultWindowHours int    `yaml:"settlements_default_window_hours"`
      RequestsPerMinuteCap          int    `yaml:"requests_per_minute_cap"`
  }

Wire into root Config:
  Explorer ExplorerConfig `yaml:"explorer"`

Defaults in `setDefaults()` (mirror section 13 of the spec exactly):
  Enabled                       = false
  BindPath                      = "/admin/explorer/"
  GatewayTimeoutMs              = 1500
  QueryTimeoutMs                = 3000
  PollMinIntervalSeconds        = 5
  ActivityMaxWindowDays         = 7
  ActivityDefaultWindowHours    = 24
  BuyersMaxWindowDays           = 31
  BuyersDefaultWindowHours      = 168
  LedgerMaxWindowDays           = 31
  LedgerDefaultWindowHours      = 168
  SessionsMaxWindowDays         = 7
  SessionsDefaultWindowHours    = 24
  SettlementsMaxWindowDays      = 180
  SettlementsDefaultWindowHours = 720
  RequestsPerMinuteCap          = 60

Validation in `validate()`:
  - If Enabled is true, AuthConfig.OperatorKey MUST be non-empty.
  - BindPath MUST begin with `/admin/explorer/` and end with `/`.
  - All *_max_window_days MUST be between 1 and 31 except
    SettlementsMaxWindowDays (31..365).
  - All *_default_window_hours MUST be between 1 and
    (corresponding *_max_window_days * 24).
  - GatewayTimeoutMs in 100..10000, QueryTimeoutMs in 100..30000,
    PollMinIntervalSeconds in 1..60, RequestsPerMinuteCap in 1..600.
  - If Enabled is true and GatewayBaseURL is non-empty, it MUST begin
    with `http://` or `https://`. Empty GatewayBaseURL is allowed and
    disables the buyer-proxy panels (section 14 graceful degradation).

Build check (coordinator).

---

## PART B — Gateway read-only explorer endpoints

File: `phase5-gateway/internal/router/server.go`

Add the following routes under the existing `/admin/*` mux. They all
reuse the existing `operatorAuthorized` middleware (D15 — same bearer
as the rest of gateway `/admin/*`).

  GET  /admin/explorer/buyers
  GET  /admin/explorer/buyers/{account_id}
  GET  /admin/explorer/sessions
  GET  /admin/explorer/sessions/{request_id}
  GET  /admin/explorer/activity
  GET  /admin/explorer/health

Response schemas: see SPEC-007 sections 6.2 through 6.6. Match field
names and types exactly. Every list endpoint MUST:
  - accept `cursor` (opaque string), `limit` (int, default 50, max 200),
    `window_hours` (int, default per spec), and any endpoint-specific
    filters per section 6.
  - clamp window_hours to the corresponding max from coordinator
    config-equivalent constants defined locally in gateway (mirror the
    same numbers; gateway is the producer, coordinator is the proxy).
  - return JSON `{ "items": [...], "next_cursor": "..." | null,
    "partial": false, "error": null }`.

Implementation notes:
  - Storage layer: extend `phase5-gateway/internal/storage/sqlite/` with
    read-only query methods. NO new tables. NO schema migrations.
  - For the buyer email filter (section 6.2): accept both `email`
    (exact, case-folded) and `email_prefix` (prefix, case-folded). Both
    present MUST return 400 with `error.code='bad_request'`.
  - Activity feed sources (section 6.5): `usage_events`,
    `quota_reservations`, `feedback_events`, `audit_events`,
    `capacity_signal_events`, `signup_events`, `demo_usage_events`,
    `demo_session_events`. Merge by `created_at_utc DESC`. Cursor is
    `{ts}_{table}_{rowid}` opaque base64. Cursor MUST be monotonic so
    a later SSE wrapper layer can reuse the same feed (D8).
  - Demo events have no `account_id` — emit `account_id=null` and
    `link_target=""` per section 8 deferral note.
  - Health endpoint (section 6.6): emit usage_events / demo_usage_events
    / quota_reservations / signup_events row counts over the configured
    window. These ARE surfaced in the coordinator-side health response
    per the M-9 deferral note in the audit; gateway emits them so a
    future v0.3 reconciliation can wire them into coordinator response.

Auth check:
  - Every `/admin/explorer/*` route uses the existing
    `operatorAuthorized` middleware (`server.go:1898-1904`). Do NOT
    add a new auth middleware. Do NOT introduce a separate bearer.

Bounded queries:
  - Wrap every read with a context using `QueryTimeoutMs` equivalent
    (define a gateway-side constant `explorerQueryTimeoutMs = 3000`).
  - Use prepared statements. No string-built SQL.

Build check (gateway).

---

## PART C — Coordinator explorer storage helpers

Files: `phase4-coordinator/internal/billing/store.go` (add read-only
methods), `phase4-coordinator/internal/requestlog/store.go` (add
read-only methods), and one new file
`phase4-coordinator/internal/explorer/store.go` for explorer-specific
joins that cross billing + requestlog.

Add read-only query methods (no inserts, updates, or deletes) for:
  - Recent sessions list (joins `request_log` + `ledger_request_credits`
    by `request_id`).
  - Session detail by `request_id` (joins request_log, ledger rows,
    `ledger_provider_identity_snapshots`).
  - Providers list (live pool snapshot + `provider_tokens` join).
  - Provider detail by `provider_id`.
  - Recent ledger entries with bounded window.
  - Settlements list from `ledger_payout_ready` (read-only).
  - Health snapshot (reconciliation delta from
    `ledger_reconciliation_runs`, coordinator uptime, pool size).

Hard rule: every method in `internal/explorer/store.go` MUST take a
read-only sql.Conn or sql.Tx and MUST be unable to mutate. Add a
package-level comment asserting "read-only invariant per SPEC-007
section 3.9; mutating queries MUST NOT be added to this file."

For `token_status` mapping per the audit M-7 deferral:
  - 'active' iff `provider_tokens` row exists with `revoked_at IS NULL`
    and `provider_id != ''`.
  - 'revoked' iff `revoked_at IS NOT NULL`.
  - 'missing' iff no row for the given `provider_id`.
  - Filter out the row with empty `provider_id`.

For `gateway.health` enum (section 5.13):
  - 'ok': gateway returned 200 with `gateway_health="ok"`.
  - 'unavailable': gateway returned 200 with `gateway_health!="ok"`,
    OR returned non-200 with body.
  - 'unknown': transport error (timeout, connection refused), OR
    `gateway_base_url` empty.

Build check (coordinator).

---

## PART D — Coordinator HTTP handlers

File: new `phase4-coordinator/internal/explorer/handlers.go`

Define one handler per coordinator endpoint in section 5 of the spec.
Mount them under `BindPath` (default `/admin/explorer/`) in
`phase4-coordinator/internal/ws/server.go`. Every handler MUST:

  1. Use the existing `authorizedOperator` check (server.go:1456-1458)
     gated on `cfg.Auth.OperatorKey`. Bad bearer => 401.
  2. Wrap the request in a context with `QueryTimeoutMs` budget.
  3. Honor the corresponding `*_max_window_days` and
     `*_default_window_hours` config knobs (per PART A).
  4. Return JSON per the schemas in section 5. Use the common envelope
     `{ "...", "partial": bool, "error": null | {...} }`.
  5. Return 404 for unknown ids, 400 for malformed params (with
     `error.code='bad_request'`), 502 for gateway proxy failures (with
     `error.code='gateway_bad_response'` or `'gateway_unauthorized'`
     per the audit m-2 deferral note), 500 only for storage errors.
  6. MUST NOT execute any write SQL. Static-analysis check: grep the
     handler file for `INSERT|UPDATE|DELETE|CREATE|DROP|ALTER` after
     implementation; expect zero matches.

Endpoints to implement (paths and methods per section 5):
  GET  /admin/explorer/overview
  GET  /admin/explorer/sessions
  GET  /admin/explorer/sessions/{request_id}
  GET  /admin/explorer/providers
  GET  /admin/explorer/providers/{provider_id}
  GET  /admin/explorer/buyers              (proxies to gateway)
  GET  /admin/explorer/buyers/{account_id} (proxies to gateway)
  GET  /admin/explorer/ledger
  GET  /admin/explorer/settlements
  GET  /admin/explorer/settlements/{payout_id}
  GET  /admin/explorer/health
  GET  /admin/explorer/activity
  GET  /admin/explorer/activity/{event_id}
  GET  /admin/explorer/feedback            (per section 8.9)

For mutating verbs on settlement paths (section 5.12):
  POST/PATCH/DELETE /admin/explorer/settlements -> 405 with
  `Allow: GET` header. POST/PATCH/DELETE on individual settlement ids
  -> 404 (the route doesn't exist; serve 404 via mux default).

Session detail `partial=true` semantics (audit M-11):
  - Both coordinator + gateway have data: partial=false.
  - Coordinator has data, gateway unreachable: partial=true,
    `gateway` block omitted or set to error envelope.
  - Coordinator has no rows, gateway has no rows: 404.
  - Coordinator has no rows, gateway has data: partial=false, empty
    arrays for `attempts`, `ledger_rows`, `provider_identity_snapshots`.

Gateway proxy layer (sections 5.9, 5.10 — buyers endpoints):
  - Use `http.Client` with `GatewayTimeoutMs` budget.
  - Authorize with `Authorization: Bearer <auth.operator_key>` (D15).
  - Gateway base URL from `explorer.gateway_base_url` config.
  - If `gateway_base_url` is empty: return 503 with
    `error.code='gateway_disabled'` and `error.detail='explorer.gateway_base_url not configured'`.
  - On gateway 4xx/5xx or transport error: surface as 502 with
    `error.code='gateway_bad_response'` (or `'gateway_unauthorized'`
    if gateway returned 401/403). Do NOT propagate gateway error
    bodies verbatim — strip and log.

CSP and security headers (section 11.4):
  - `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'`
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY`
  - `Referrer-Policy: no-referrer`
  - Apply to both static assets and JSON API responses.

Capture coordinator boot time once at process start (`startedAtUTC =
time.Now().UTC()`) and expose via the overview + health endpoints
per audit m-11.

Build check (coordinator).

---

## PART E — Static dashboard bundle

Directory: new `phase4-coordinator/internal/explorer/static/`

Layout:
  static/
    index.html
    css/dashboard.css
    js/dashboard.js
    js/views/overview.js
    js/views/sessions.js
    js/views/providers.js
    js/views/buyers.js
    js/views/ledger.js
    js/views/settlements.js
    js/views/activity.js
    js/views/health.js
    js/views/feedback.js
    js/lib/api.js
    js/lib/poll.js

Embed with `//go:embed static` in a new file
`phase4-coordinator/internal/explorer/static.go`:

  //go:embed static
  var staticFS embed.FS

Mount the bundle at `BindPath` (i.e. `/admin/explorer/`) in the
coordinator mux. The HTML at `index.html` MUST:

  - Be served at GET `/admin/explorer/` (200) and
    `/admin/explorer/index.html` (200). Trailing-slash redirect for
    `/admin/explorer` (no slash) -> 301 to `/admin/explorer/`.
  - Prompt the operator for the coordinator bearer on first load
    (paste into a password input; stored in `sessionStorage` only,
    NOT `localStorage`).
  - Render all nine views per section 8 in a single-page tabbed
    layout. No SPA framework. Use vanilla JS + small render helpers.
  - Use `fetch()` with `Authorization: Bearer <key>` header pulled
    from sessionStorage on every call.
  - Implement hidden-tab pause via `document.visibilityState` listener.
  - Implement the 60 RPM client cap by serializing fetches and
    rejecting any fetch that would exceed the cap; log to console.

Per-view refresh intervals (section 9):
  - Overview: 30s
  - Live state / providers: 10s
  - Activity feed: 15s
  - Sessions, buyers, ledger, settlements: manual refresh only
  - Health: 30s
  - Feedback: 30s

Cross-view links (audit M-8 deferral acknowledged but still implement
the minimum from section 8.10):
  - Activity row `request_id` -> session detail view.
  - Session detail `account_id` -> buyer detail view.
  - Session detail `provider_id` -> provider detail view.
  - Provider detail settlement rows -> settlement detail view.
  - Health card last reconciliation -> ledger view with filtered window.

CSS guidance:
  - Dense operational tables, monospace for ids and hashes.
  - Status strips (green=ok, amber=degraded, red=down) for each view.
  - No icons fetched from CDNs. No web fonts. System font stack only.

Bundle size target: < 80 KB gzipped (section 11). Run
`gzip -c phase4-coordinator/internal/explorer/static/* | wc -c` after
authoring to verify.

Build check (coordinator).

---

## PART F — Tests

Test files to author:

  phase4-coordinator/internal/config/config_explorer_test.go
  phase4-coordinator/internal/explorer/handlers_test.go
  phase4-coordinator/internal/explorer/store_test.go
  phase5-gateway/internal/router/explorer_test.go
  phase5-gateway/internal/storage/sqlite/explorer_test.go

Coverage requirements — at minimum one test per AC from section 15
(AC-1 through AC-29). Test names MUST encode the AC number:
`TestAC01_BearerRequired`, `TestAC02_BadBearerRejected`, etc.

Critical ACs to verify deterministically:

  AC-1  bearer required on every coordinator route.
  AC-2  bad bearer => 401.
  AC-3  gateway explorer routes accept coordinator.operator_key
        (D15); bogus bearer => 401.
  AC-4  overview loads in < 500ms with seeded data.
  AC-5  sessions list cursor stable across new inserts.
  AC-6  session detail joins request_log + ledger + gateway usage.
  AC-7  provider list reflects live pool state.
  AC-8  ledger view respects bounded window.
  AC-9  settlements view read-only — POST/PATCH/DELETE => 405/404.
  AC-10 health view surfaces reconciliation delta.
  AC-11 activity cursor monotonic + replay returns contiguous slice.
  AC-12 polling pauses on hidden tab (test the visibilitychange
        listener wiring; do NOT spawn a real browser).
  AC-13 gateway-unreachable degradation: explorer returns partial=true.
  AC-14 reconcile delta visible; reconnect/restart counts NULL (OQ-4).
  AC-19 60 RPM cap (test server-side cap if implemented, else
        client-side serialization in dashboard.js — verify with a
        unit test that loads dashboard.js into a headless V8/node
        runner; if too complex, test the JS by reading it and
        asserting the cap constant + serialization logic exist).
  AC-20 gateway health enum mapping covers ok/unavailable/unknown.
  AC-23 deferred endpoints don't exist (GET on each forbidden path
        returns 404).
  AC-25 D14 traversal — automated test that walks
        overview -> seeded session -> seeded buyer -> seeded provider
        -> seeded ledger -> seeded settlement -> health, asserting
        each step's response shape.
  AC-28 no explorer writes — `BEGIN IMMEDIATE; SELECT count(*),
        max(rowid) FROM <each table> ; ROLLBACK;` before and after a
        full explorer crawl; assert all counts and maxes unchanged.
  AC-29 buyer email filter — seed three accounts with case-variants;
        verify exact + prefix + 400 on both-present.

Seed data helpers: place under
`phase4-coordinator/internal/explorer/testdata/seed.go`. Seed at
least: 3 buyers (different emails), 2 providers, 5 sessions across
those buyers and providers, 10 ledger rows, 2 settlement-ready rows,
1 reconciliation run.

Test infra:
  - Use the existing `phase4-coordinator/internal/...` test helpers
    where they exist; do not introduce a new test framework.
  - SQLite test DBs go in `t.TempDir()`.
  - For gateway proxy tests, spin up a `httptest.Server` mimicking
    gateway responses; verify coordinator handler behavior for both
    happy path and timeout / 401 / 5xx.

Build check (both binaries).

---

## PART G — Full test suite + commit

Run, in order:
  cd phase4-coordinator && GOCACHE=/private/tmp/macprovider-go-build-cache go test ./...
  cd phase5-gateway && GOCACHE=/private/tmp/macprovider-go-build-cache go test ./...

All tests MUST pass. Fix flakes by determinism — do NOT skip or
xfail any test. If a test is hard to make deterministic, simplify
the implementation; the spec is the contract, not the test harness.

Static-analysis sweep:
  grep -rE 'INSERT|UPDATE|DELETE|CREATE TABLE|DROP|ALTER' \
    phase4-coordinator/internal/explorer/ \
    phase5-gateway/internal/router/explorer*.go \
    phase5-gateway/internal/storage/sqlite/explorer*.go
  Expect zero matches outside of test setup.

Bundle size sweep:
  gzip -c phase4-coordinator/internal/explorer/static/index.html \
       phase4-coordinator/internal/explorer/static/css/*.css \
       phase4-coordinator/internal/explorer/static/js/**/*.js \
    | wc -c
  Expect < 80000 bytes.

End-to-end manual smoke (the one you DO run locally):
  - Start coordinator with `explorer.enabled=true`, point
    `explorer.gateway_base_url` at a local gateway.
  - curl with bearer, see 200 on /admin/explorer/overview.
  - curl without bearer, see 401.
  - Open http://localhost:<port>/admin/explorer/ in a browser; paste
    bearer; verify the nine views render and refresh.

Commit:
  git add -p   # stage only the implementation diff; do NOT stage
               # any build artifacts under */dist/.
  git commit -m "feat(spec-007): v0.2 explorer — coordinator handlers, gateway endpoints, static bundle"

Do NOT push.

---

## Handback

When done, print:
  - Test summary: pass/fail per package.
  - Static-analysis sweep result.
  - Bundle gzipped size.
  - Manual smoke result (the curl chain + browser load).
  - One-line readiness statement: "SPEC-007 v0.2 implementation
    ready for operator review" OR a precise list of what is still
    open with reasons.
