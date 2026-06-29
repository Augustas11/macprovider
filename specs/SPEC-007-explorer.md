# SPEC-007 - Internal Operator Protocol Explorer
Dependency lines: depends on `specs/SPEC-002-coordinator.md`, `specs/SPEC-005-billing.md`, `specs/SPEC-006-buyer-api.md`, `specs/SPEC-007-explorer-design.md`, and `specs/SPEC-007-operator-decisions.md`.
Normative language in this document uses RFC 2119 meanings for MUST, MUST NOT, SHOULD,
SHOULD NOT, and MAY. SPEC-007 v0.3 defines an internal, read-only,
single-operator explorer for the Mac Provider protocol. The explorer is an operator
cockpit. It is not a public explorer. It is not a control plane. It is not a
settlement mutator. It is not a parallel analytics store.
## 1. Change log
| Version | Date | Author | Summary |
|---|---|---|---|
| v0.4 | 2026-06-29 | docs+impl (ISS-231) | Closes the v0.3 R2 architect lane deferrals from PR #221. **§6.4 (gateway session-detail):** `matched_account_ids` MUST be capped at N=10 entries in the 409 ambiguity response; the SQL UNION carries `LIMIT 11` so the handler detects overflow without inflating the row set. When the underlying union produces >10 distinct account_ids the response MUST include `"matched_account_ids_truncated": true` and the gateway MUST emit an `audit_events` row at WARN with the full list (post-hoc investigation). Bounds operator log noise + protects the 409 response body against malicious collision floods. **§5.6 + §6.4 (path-segment typing, deprecation-window mode):** the `{request_id}` path-segment MAY now carry a typed prefix — `int_<coordinator-internal request_id>` for §5.6, `ext_<external_request_id>` for §6.4. Untyped (legacy bare-id) calls remain accepted in v0.4 BUT both handlers MUST emit a `payout_explorer_path_segment_untyped` audit row (severity=WARN, fields: `endpoint, request_id, ts_utc`) to surface the deprecation. **v0.5 will reject untyped with `400 session_id_untyped`.** Typed-prefix mode closes the path-segment-overload class properly — pre-v0.3 lookup-order disambiguation is no longer the contract authority. **IMPL:** `phase5-gateway/internal/storage/sqlite/explorer.go::explorerAccountIDsForRequest` gains `LIMIT 11`; gateway 409 handler computes the truncation flag + emits the WARN audit row; gateway + coordinator session-detail handlers parse the typed prefix when present and emit deprecation WARN when untyped. **Tests:** `TestExplorerAccountIDsForRequest_CapAt10WithTruncationFlag`, `TestExplorerSessionDetail_TypedPrefixIsParsedCorrectly`, `TestExplorerSessionDetail_UntypedEmitsDeprecationAudit` pin the new contracts. Three-lane codex audit findings in `specs/SPEC-007-v0-4-audit.md`. |
| v0.3 | 2026-06-29 | docs+impl (ISS-212) | Composite-PK addendum reflecting the gateway PK schema landed in #196 + the coordinator-side composite reconciliation key landed in #211 (PR #224 / SPEC-002 v1.5.0). **§6.4 (gateway session-detail):** `(account_id, request_id)` is the physical identity for `usage_events`, `quota_reservations`, `concurrency_reservations`, `feedback_events`, and `audit_events`; `request_id` alone is only a logical join key. Optional `?account_id=` disambiguation query parameter; `409 ambiguous_request_id` response with `matched_account_ids[]` computed over ALL FIVE account-keyed session-detail tables (R2: extended from the three reservation/usage tables to include feedback_events and audit_events — buyer-attachable feedback would otherwise cross-pollinate a 200 response). Window-contract split between scoped/unscoped paths; `idx_usage_request` supports the unscoped path. Forbidden-fields block. **§6.1:** endpoint-specific error-exception note covering §6.4's OpenAI-compatible 409 envelope. **§5.6 (coordinator session-detail):** path-segment is the coordinator-internal `request_id` only in v0.3 (path-segment overload deferred to v0.4). Both-or-nothing gateway-proxy rule: the coordinator MUST forward `external_request_id` + `?account_id=` (NOT the internal id) when proxying, and MUST NOT proxy when either field is missing on the resolved row — incomplete-identity rows return `gateway: {"error": {"code": "gateway_identity_unavailable"}}` with `partial=false` and full coordinator-side detail. Unknown coordinator-internal `request_id` returns 404 regardless of gateway data. §14.7.1 added to document the new identity-unavailable failure mode; UI MUST distinguish it from `gateway_unavailable`. **§7.5 (cross-component join keys):** rewritten to split intra-coordinator joins (on internal `request_id`) from cross-service joins (on the composite `(account_id, external_request_id)` ⇔ `(account_id, request_id)`). **AC-7:** updated to seed coordinator rows carrying composite identity, assert gateway proxy uses `external_request_id` + `?account_id=` (not the internal id), exercise the cross-account isolation case (two coordinator rows with the same external_request_id route to different accounts), and exercise the legacy NULL-account "no proxy → gateway_identity_unavailable" sub-case. **IMPL:** `phase5-gateway/internal/storage/sqlite/explorer.go` `explorerAccountIDsForRequest` extended to union all five tables; new regression `TestExplorerSessionDetailAmbiguityExtendedToFeedbackAndAudit` pins the feedback/audit cross-pollination guard. **Paired:** SPEC-007-explorer-design.md §2.8 GAP-closed pointer updated to SPEC-002 v1.5.0 / #211. Three-lane codex audit findings + dispositions in `specs/SPEC-007-v0-3-audit.md`. |
| triage 2026-06-26 | 2026-06-26 | docs/OPEN_QUESTIONS.md | M-3 through M-12 (deferred-to-v0.3 audit findings) closed as unrecoverable — the underlying audit document was never persisted to the repo and the findings list is not reconstructible from history. If operator-explorer concerns recur, run a fresh audit cycle and number anew. No version bump; no normative change. |
| v0.2 | 2026-06-01 | operator | resolved B-1 by dropping the explorer bearer env knob and pinning bearer source to `auth.operator_key`; resolved B-2 by making SPEC-005 payout mutation a future payout-rail contract; resolved B-3 with D15 shared gateway admin bearer; resolved M-1 with exact `email` and prefix `email_prefix` semantics; resolved M-2 with per-endpoint window knobs. Deferred to v0.3: M-3 through M-12. Future infra follow-up: coordinator `env:` resolution for `auth.operator_key`. |
| v0.1 | 2026-06-01 | operator | initial draft against locked decisions D1-D14 |
## 2. Locked decisions
This section records the locked operator pre-commitments from `specs/SPEC-007-operator-decisions.md`. This section is read-only documentation. It introduces no alternatives. It does not relitigate design space.
### 2.1 D1 - Hosting
**A** - coordinator-served `/admin/explorer/` for v1; same origin as coordinator admin endpoints; no new public app, DNS target, or Vercel admin-to-backend bridge. Do not put explorer routes in the public buyer console.
### 2.2 D2 - Frontend technology
**A** - static dashboard for v1; dense operational tables, filters, status strips, and manual refresh are enough; no SPA framework or charting dependency unless a later measured workflow requires it.
### 2.3 D3 - Auth
**A** - reuse the existing coordinator operator bearer for v1; the explorer is equivalent to `/admin/*`; no RBAC, OAuth, multi-tenant sessions, or separate read-only token in v1. If the route is exposed outside the operator's private path, Cloudflare Access or Tailscale may be used as an outer gate without changing the application auth contract.
### 2.4 D4 - Gateway buyer data path
**A** - add bounded read-only gateway admin endpoints for buyer/account/key/usage data and proxy the explorer-facing summaries through coordinator `/admin/explorer/*`; keep gateway ownership of buyer data; do not copy buyer tables into coordinator storage.
### 2.5 D5 - Buyer endpoints
**A** - include buyer/API-key directory visibility in v1 through read-only gateway endpoints; the operator's original ask explicitly includes buyers and tokens, so deferring this would leave the cockpit incomplete.
### 2.6 D6 - Provider event history
**A** - v1 shows current provider state from `/poolz` and recent request/ledger-derived activity only; no new durable provider session/event table, reconnect counter table, or uptime history in v1. Mark reconnect and restart history as explicit gaps for a later observability spec.
### 2.7 D7 - In-flight requests
**A** - v1 session views are based on durable completed attempts from `request_log` plus ledger/gateway joins; no in-flight request table or live in-flight endpoint in v1.
### 2.8 D8 - Activity transport
**A** - polling in v1: overview/health/activity use bounded intervals and pause when hidden; no SSE endpoint in v1. Design activity cursors so SSE can wrap the same feed later if needed.
### 2.9 D9 - Public-safe tagging
**A** - keep operator-only/public-aggregate/public-redacted/public-raw tags in the normative spec and design notes, but do not add tag metadata to v1 endpoint responses. Endpoint schemas stay operationally lean while preserving future public-explorer guidance.
### 2.10 D10 - Operator economics
**A** - show operator share, provider share, gross credits, reconciliation deltas, fault/quarantine counts, and settlement-ready totals internally; public explorer promotion must remove or aggregate operator-only economics.
### 2.11 D11 - Settlement rows
**A** - include read-only settlement-ready rows and settlement history in v1; SPEC-005 already emits `ledger_payout_ready`, and SPEC-007 explorer may observe but must not claim, consume, void, or pay rows.
### 2.12 D12 - Index posture
**A** - start with existing indexes plus bounded date windows, cursors, limits, and query timeouts; add only indexes required by implementation tests or measured slow queries. No materialized rollups or proactive analytics indexes in v1.
### 2.13 D13 - Public explorer scope
**A** - public explorer is a later SPEC; v1 is internal-only and may expose operator-only fields behind admin auth. Do not build redaction endpoints, public schemas, or public rate limits in SPEC-007 v1.
### 2.14 D14 - V1 success bar
**A** - v1 succeeds when the operator can answer the core operational questions in under two minutes using tables, status strips, filters, and detail views; analytics-grade charts, long-horizon BI, and public explorer polish are later work.
### 2.15 D15 - Gateway explorer bearer model
**A** - Gateway explorer routes reuse `coordinator.operator_key` for v0.2; no distinct
gateway explorer bearer. section 10.5 excludes compromised-coordinator threat; existing
gateway `/admin/*` surface shares the key; splitting explorer-only secret is
undermotivated and would require AC-3 to reject configs that work today. Reconsider when
a future spec migrates all gateway admin endpoints to a gateway-side bearer.
## 3. Terms and definitions
### 3.1 Explorer
The explorer is the internal operator-only protocol visibility surface served from coordinator `/admin/explorer/`. The explorer MUST be read-only. The explorer MUST NOT mutate coordinator state. The explorer MUST NOT mutate gateway state. The explorer MUST NOT write settlement state.
### 3.2 View
A view is one rendered operator screen or tab in the static dashboard. A view MAY combine multiple read-only endpoint responses. A view MUST continue rendering unaffected panels when another panel fails.
### 3.3 Overview
Overview is the shallow first-load summary that answers whether the protocol is alive and whether accounting looks sane. Overview is fed by `/admin/explorer/overview`.
### 3.4 Activity feed
Activity feed is a cursor-paginated list of recent protocol events derived from existing append-only tables and request logs. Activity feed MUST use polling in v1. Activity feed MUST NOT expose SSE in v1. Activity feed cursors MUST be monotonic and resumable.
### 3.5 Session detail
Session detail is the per-`request_id` detail view for completed request attempts. The repo does not currently have a shared durable `session_id`. For v1, `request_id` is the session-detail lookup key.
### 3.6 Buyer directory
Buyer directory is the gateway-owned list of accounts, identities, API keys, usage, quota, reservations, feedback, and last activity. The coordinator MUST NOT copy buyer tables into coordinator SQLite.
### 3.7 Provider directory
Provider directory is the coordinator-owned list of live providers plus provider token state and ledger-derived economics. Live state comes from `phase4-coordinator/internal/pool/provider.go`. Token state comes from `provider_tokens`. Economics come from SPEC-005 ledger tables.
### 3.8 Ledger view
Ledger view is the read-only table of `ledger_request_credits` rows joined to `ledger_operator_credits` and related snapshots. Ledger view MUST NOT write ledger rows.
### 3.9 Settlement view
Settlement view is the read-only table of `ledger_payout_ready` rows. Settlement view
MAY show `ready`, `consumed`, and `voided` rows. Settlement view MUST NOT claim rows.
Settlement view MUST NOT consume rows. Settlement view MUST NOT void rows. Settlement
view MUST NOT pay rows. SPEC-005 section 4.5.1 references a payout-rail consumer that writes
`ledger_payout_ready.status` in {`consumed`, `voided`}. That consumer is a future spec,
NOT SPEC-007 v0.2. SPEC-007 v0.2 MUST NOT execute the payout-rail consumer contract.
### 3.10 Health view
Health view is the read-only snapshot of coordinator health, gateway health, pool health, reconciliation health, capacity state, and reservation drift.
### 3.11 Operator bearer
Operator bearer is the existing coordinator admin bearer used by `/admin/*`. The current coordinator code stores it as `auth.operator_key` in `phase4-coordinator/internal/config/config.go`. The current gateway configuration uses `coordinator.operator_key`, commonly loaded through `env:COORDINATOR_OPERATOR_KEY`, when it calls coordinator admin surfaces. SPEC-007 reuses the coordinator operator bearer for coordinator `/admin/explorer/*`.
### 3.12 Gateway explorer admin auth
Gateway explorer admin auth is the existing gateway `/admin/*` authorization model. The
gateway validates `Authorization: Bearer <coordinator.operator_key>` for
`/admin/explorer/*` exactly as it does for the rest of the gateway admin surface. SPEC-007
v0.2 introduces no distinct gateway-only explorer secret.
### 3.13 Outer gate
Outer gate means Cloudflare Access, Tailscale, or equivalent network-level access control in front of the coordinator admin origin. An outer gate MAY be used. An outer gate MUST NOT replace application bearer checks. An outer gate MUST NOT change the explorer endpoint contract.
### 3.14 Bounded window
Bounded window is a required maximum time range for any endpoint that reads an unbounded table. The server MUST reject requests beyond the endpoint's maximum window.
### 3.15 Cursor
Cursor is an opaque token that resumes a deterministic ordered scan. Cursors MUST be stable across concurrent inserts. Cursors MUST include enough ordering state to avoid duplicate or missing rows within a paginated traversal.
### 3.16 Polling interval
Polling interval is the client-side delay between automatic refresh requests while a tab is visible. The UI MUST enforce the minimum interval configured by the coordinator.
### 3.17 Hidden-tab pause
Hidden-tab pause means the static bundle stops all automatic polling when `document.visibilityState` is not `visible`. Manual refresh MAY still be available after the tab becomes visible again.
### 3.18 Operator-only
`operator-only` is a privacy tag for raw fields that MUST NOT appear in a future public explorer without removal, aggregation, or redaction. Tags live in this spec and design metadata only. V1 endpoint schemas MUST NOT include tag metadata.
### 3.19 Public-aggregate
`public-aggregate` is a privacy tag for fields that MAY be safe in public only after aggregation.
### 3.20 Public-redacted
`public-redacted` is a privacy tag for fields that MAY be safe in public only after deterministic redaction is specified by a later SPEC.
### 3.21 Public-raw
`public-raw` is a privacy tag for fields that MAY be safe to show as-is in a future public explorer. Public-raw tagging in this spec is not permission to ship public endpoints in v1.
## 4. Architecture
### 4.1 Service topology
The operator browser loads a static dashboard from the coordinator origin. The route
prefix is `/admin/explorer/`. An optional outer gate MAY sit before the coordinator
origin. The coordinator MUST authenticate every `/admin/explorer/*` request with the
existing coordinator operator bearer. After coordinator auth, a coordinator explorer
handler MAY read local coordinator SQLite. After coordinator auth, a coordinator
explorer handler MAY proxy a read-only request to the gateway. The gateway MUST
authenticate proxied explorer requests with the same `coordinator.operator_key` bearer
used by the rest of gateway `/admin/*`. The gateway bearer MUST NOT be sent to the
operator browser.
### 4.2 Diagram-grade flow
```text
operator browser
  -> optional Cloudflare Access or Tailscale outer gate
  -> coordinator /admin/explorer/* with Authorization: Bearer <operator bearer>
       -> local coordinator SQLite reads
       -> live coordinator pool reads
       -> HTTPS proxy to gateway /admin/explorer/* with Authorization: Bearer <coordinator.operator_key>
            -> gateway SQLite reads
```
The operator browser MUST call only the coordinator origin. The operator browser MUST NOT call gateway admin endpoints directly. The coordinator MUST NOT proxy mutating gateway admin endpoints. The coordinator MUST NOT perform verb or query translation for pass-through gateway explorer proxy paths. **Exemption (v0.3 / §5.6):** the session-detail endpoint MAY translate its inbound path-segment (coordinator-internal `request_id`) into the gateway-side composite key — `GET /admin/explorer/sessions/<external_request_id>?account_id=<account_id>` — derived from the resolved `request_log` row. This is the both-or-nothing safety contract required to avoid embedding wrong-account gateway data; the translation is a SPEC-007 v0.3 requirement, not a verb/query-translation violation.
### 4.3 Process model
SPEC-007 MUST NOT introduce a new long-lived service. SPEC-007 MUST NOT introduce a new public DNS target. SPEC-007 MUST NOT introduce a new Vercel project.
The explorer consists of:
- New read-only handlers inside the existing coordinator binary.
- A small embedded static HTML/CSS/JS bundle inside the coordinator binary.
- New read-only gateway handlers under gateway `/admin/explorer/*`.
- Bounded proxy calls from coordinator to gateway.
### 4.4 State boundaries
The coordinator owns:
- `request_log`, from `phase4-coordinator/internal/requestlog/store.go`.
- `ledger_request_credits`, from `phase4-coordinator/internal/billing/store.go`.
- `ledger_operator_credits`, from `phase4-coordinator/internal/billing/store.go`.
- `ledger_payout_ready`, from `phase4-coordinator/internal/billing/store.go`.
- `ledger_reconciliation_runs`, from `phase4-coordinator/internal/billing/store.go`.
- `ledger_config_snapshots`, from `phase4-coordinator/internal/billing/store.go`.
- `ledger_provider_identity_snapshots`, from `phase4-coordinator/internal/billing/store.go`.
- `provider_tokens`, from `phase4-coordinator/internal/auth/tokens.go`.
- Live provider pool state, from `phase4-coordinator/internal/pool/provider.go`.
The gateway owns:
- `accounts`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `account_identities`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `api_keys`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `api_key_events`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `usage_events`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `quota_reservations`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `concurrency_reservations`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `feedback_events`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `signup_events`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `demo_session_events`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `demo_usage_events`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `audit_events`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `capacity_signal_events`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
- `runtime_config`, from `phase5-gateway/internal/storage/sqlite/migrate.go`.
### 4.5 Coordinator charter preservation
SPEC-002 defines the coordinator as a router plus billing state owner. SPEC-007 read-only explorer handlers are in charter because they expose existing router, pool, request-log, and billing state to the operator. SPEC-007 MUST NOT add analytics-grade ETL. SPEC-007 MUST NOT add materialized rollups in v1. SPEC-007 MUST NOT add a durable provider-event table in v1. SPEC-007 MUST NOT copy gateway buyer tables into coordinator storage.
### 4.6 Static asset surface
The coordinator MUST serve a small static bundle under `/admin/explorer/`. The bundle MUST be embedded into the coordinator binary with Go `embed.FS`. The current repo already uses `embed.FS` for gateway pages in `phase5-gateway/internal/router/pages.go`. The current coordinator does not yet use `embed.FS` for static pages. SPEC-007 implementation MUST add coordinator-side `embed.FS` for the explorer.
### 4.7 Read-only invariant
Every `/admin/explorer/*` route MUST be side-effect-free. Every `/admin/explorer/*` route MUST use `GET`. Every non-`GET` request to `/admin/explorer/*` MUST return 405 or 404. Explorer handlers MUST NOT call mutating coordinator functions. Explorer handlers MUST NOT call mutating gateway functions. Explorer handlers MUST NOT insert, update, or delete rows. Explorer handlers MUST NOT trigger SPEC-005 reconciliation writes.
## 5. Read-only endpoint surface (coordinator)
### 5.1 Common coordinator endpoint contract
All coordinator explorer API endpoints live under `/admin/explorer/*`.
All coordinator explorer API endpoints MUST require:
- `Authorization: Bearer <coordinator operator bearer>`.
All coordinator explorer API endpoints MUST return JSON.
All coordinator explorer API endpoints MUST return:
- `Cache-Control: no-store`.
- `Content-Type: application/json`.
All coordinator explorer API endpoints MUST enforce a server-side query timeout. Default coordinator query timeout is 1500 milliseconds. The timeout MAY be lowered by config. The timeout MUST NOT exceed 5000 milliseconds. Every list endpoint MUST support `limit`. Default list limit is 50. Maximum list limit is 200. Every unbounded list endpoint MUST support `cursor`. Cursor values are opaque strings. The coordinator MUST reject malformed cursor values with 400. The coordinator MUST reject unsupported filters with 400. The coordinator MUST reject date windows wider than the endpoint maximum with 400.
The coordinator common error envelope is:
```json
{
  "error": {
    "code": "string",
    "message": "string",
    "source": "coordinator",
    "retryable": false
  }
}
```
Allowed common errors:
- 400 `invalid_request`.
- 401 `invalid_operator_token`.
- 404 `not_found`.
- 405 `method_not_allowed`.
- 408 `query_timeout`.
- 502 `gateway_bad_response`.
- 503 `gateway_unavailable`.
- 500 `internal_error`.
The existing coordinator code currently uses both 401-style admin errors in `phase4-coordinator/internal/ws/server.go` and 403-style billing admin errors in `phase4-coordinator/internal/billing/endpoints.go`. SPEC-007 coordinator explorer endpoints MUST use 401 for missing or invalid operator bearer to align browser-facing admin behavior.
### 5.2 Cursor contract
For timestamped coordinator tables, cursor order MUST be deterministic.
The canonical list ordering is:
- Newest first for operator display.
- Tie-broken by the table primary key or stable source ID.
A list cursor MUST encode:
- schema version.
- primary timestamp.
- source name or table name.
- source ID or row ID.
- direction.
Cursor payloads MAY be base64url-encoded JSON. Cursor payloads MUST be treated as opaque by clients. Concurrent inserts newer than the first page MUST NOT cause missing or duplicate rows while the operator pages older rows. Activity feed cursors MUST additionally support `since_cursor` for polling newer events.
### 5.3 Bounded window defaults
Unless an endpoint overrides this section:
- `from` is inclusive.
- `to` is exclusive.
- If omitted, `to` defaults to server current UTC time.
- If omitted, `from` defaults to `to - 24h`.
- Maximum window is `explorer.sessions_max_window_days` by default.
- Date-time values MUST be RFC3339 UTC timestamps.
- Day-only values MUST be rejected except where explicitly allowed.
### 5.4 `GET /admin/explorer/overview`
Method and path:
- `GET /admin/explorer/overview`.
Purpose:
- Return one shallow snapshot for the first screen.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `include_gateway`: optional boolean, default `true`.
- `window`: optional enum, `24h` or `7d`, default `24h`.
Request bounds:
- `window` MUST NOT exceed `7d`.
- `include_gateway=false` MUST skip gateway proxy calls.
Response schema:
```json
{
  "checked_at_utc": "string",
  "protocol_status": "ok|degraded|unavailable",
  "coordinator": {
    "health": "ok|unavailable",
    "started_at_utc": "string|null"
  },
  "gateway": {
    "health": "ok|unavailable|unknown",
    "capacity_tier": 0,
    "public_api_paused": false,
    "demo_paused": false,
    "error": null
  },
  "pool": {
    "total_providers": 0,
    "ready_providers": 0,
    "busy_providers": 0,
    "degraded_providers": 0,
    "draining_providers": 0,
    "unavailable_providers": 0,
    "models_available": ["string"],
    "slots_free": 0,
    "slots_total": 0
  },
  "traffic": {
    "requests_window": 0,
    "tokens_window": 0,
    "error_count_window": 0,
    "retry_count_window": 0
  },
  "buyers": {
    "active_accounts_window": 0,
    "new_accounts_window": 0,
    "active_api_keys": 0,
    "error": null
  },
  "ledger": {
    "current_window_provider_credits": 0,
    "total_gross_credits": 0,
    "total_provider_credits": 0,
    "total_operator_credits": 0,
    "pending_payout_count": 0,
    "pending_payout_credits": 0,
    "quarantined_count": 0,
    "fault_count": 0
  },
  "reconciliation": {
    "last_run_id": 0,
    "last_status": "complete|failed|running|null",
    "last_delta_credits": 0,
    "last_finished_at_utc": "string|null"
  }
}
```
Underlying coordinator sources:
- `/poolz` logic from `phase4-coordinator/internal/ws/server.go`.
- Live provider fields from `phase4-coordinator/internal/pool/provider.go`.
- `request_log`.
- `ledger_request_credits`.
- `ledger_operator_credits`.
- `ledger_payout_ready`.
- `ledger_reconciliation_runs`.
Underlying gateway endpoints:
- `GET /admin/explorer/health`.
- `GET /admin/explorer/buyers?summary=true`.
Timeout:
- 1500 ms local budget.
- 2000 ms total gateway proxy budget.
Error behavior:
- Gateway timeout MUST NOT fail the whole overview.
- Gateway timeout MUST set `gateway.health` to `unknown`.
- Gateway timeout MUST set buyer summary `error.code` to `gateway_unavailable`.
- Local query timeout MUST return 408 `query_timeout`.
### 5.5 `GET /admin/explorer/sessions`
Method and path:
- `GET /admin/explorer/sessions`.
Purpose:
- Return completed request attempts from `request_log` with joined ledger and
  optional gateway usage fields.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `from`: optional RFC3339 UTC timestamp.
- `to`: optional RFC3339 UTC timestamp.
- `status`: optional integer HTTP status.
- `model`: optional string exact match.
- `provider_id`: optional string.
- `account_id`: optional string.
- `request_id`: optional string exact match.
- `error_code`: optional string exact match.
- `quarantined`: optional boolean.
- `limit`: optional integer, default 50, max 200.
- `cursor`: optional opaque cursor.
- `include_gateway`: optional boolean, default `true`.
Window contract:
- Default window is `explorer.sessions_default_window_hours` hours.
- Maximum window is `explorer.sessions_max_window_days` days.
- If `request_id` is supplied, `from` and `to` MAY be omitted.
Cursor contract:
- Cursor ordering MUST be by `request_log.ts_utc DESC, request_log.id DESC`.
- Cursor MUST encode `ts_utc` and `id`.
Response schema:
```json
{
  "sessions": [
    {
      "request_log_id": 0,
      "timestamp_utc": "string",
      "request_id": "string",
      "attempt_n": 0,
      "model": "string",
      "provider_id": "string|null",
      "provider_assigned_id": "string|null",
      "account_id": "string|null",
      "demo": false,
      "stream": false,
      "status": 200,
      "error_code": "string|null",
      "prompt_tokens": 0,
      "completion_tokens": 0,
      "total_tokens": 0,
      "usage_source": "provider_reported|byte_estimated|null_error|null",
      "latency_ms": 0.0,
      "routing_ms": 0.0,
      "retried": false,
      "gross_credits": 0,
      "provider_credits": 0,
      "operator_credits": 0,
      "fault_flag": "none|breaker_qualifying|null_usage_error|null",
      "quarantined": false,
      "quarantine_reason": "string|null",
      "quota_reservation_status": "active|settled|refunded|expired|null",
      "gateway_outcome": "string|null",
      "feedback_rating": 0
    }
  ],
  "next_cursor": "string|null",
  "window": {
    "from_utc": "string",
    "to_utc": "string"
  },
  "partial": false,
  "warnings": []
}
```
Underlying coordinator sources:
- `request_log.id`.
- `request_log.ts_utc`.
- `request_log.request_id`.
- `request_log.model`.
- `request_log.provider_assigned_id`.
- `request_log.prompt_tokens`.
- `request_log.completion_tokens`.
- `request_log.total_tokens`.
- `request_log.latency_ms`.
- `request_log.routing_ms`.
- `request_log.status`.
- `request_log.stream`.
- `request_log.error_code`.
- `request_log.retried`.
- `ledger_request_credits`.
- `ledger_operator_credits`.
- `ledger_provider_identity_snapshots`.
Underlying gateway sources:
- `GET /admin/explorer/buyers` when `account_id` filtering is required.
- `GET /admin/explorer/activity` for request-scoped usage and feedback rows.
Timeout:
- 1500 ms local budget.
- 2000 ms gateway proxy budget if `include_gateway=true`.
Error behavior:
- Missing or invalid bearer MUST return 401.
- Invalid date range MUST return 400.
- Local timeout MUST return 408.
- Gateway failure MUST return 200 with `partial=true` when local data succeeds.
### 5.6 `GET /admin/explorer/sessions/{request_id}`
Method and path:
- `GET /admin/explorer/sessions/{request_id}`.
Purpose:
- Return one completed request's attempts and all read-only joined context.
Identity model (v0.3):
- The path-segment `{request_id}` is the coordinator-internal
  `request_log.request_id` (UUID v4 minted server-side per buyer
  request — see SPEC-002 v1.5.0 §11). It is NOT the inbound
  `X-Request-ID`; that buyer-supplied value lives in
  `request_log.external_request_id`. **v0.3 limitation:** the
  explorer has no UI / endpoint surface for resolving by
  `external_request_id` (the §5.5 sessions list does not yet
  filter by it either). An operator who starts from a buyer-facing
  ticket carrying a buyer-supplied `X-Request-ID` MUST resolve
  the corresponding internal `request_id` out-of-band (direct
  SQL against the operator's SQLite copy:
  `SELECT request_id FROM request_log WHERE external_request_id = ? AND account_id = ?`)
  before navigating to the session-detail surface. The v0.4
  path-segment-overload future enhancement will surface this in
  the UI (see "Deferred to v0.4" below).
- For gateway proxy to `GET /admin/explorer/sessions/...` on the
  gateway, the coordinator MUST proxy ONLY when the resolved row
  supplies BOTH a non-empty `external_request_id` AND a non-empty
  `account_id`. In that case it MUST forward
  `GET /admin/explorer/sessions/<external_request_id>?account_id=<account_id>`
  using a real HTTP query parameter (NOT a path-escaped string).
  When either component is missing (legacy pre-v1.5.0-coordinator
  row, v1.5.0 row written from a pre-v0.9.1 gateway, or a
  direct legacy buyer call with no `X-Request-ID`), the
  coordinator MUST NOT proxy — it returns the coordinator-side
  detail with a `gateway` object of shape
  `{"error":{"code":"gateway_identity_unavailable"}}`. Forwarding
  with a partial key — unscoped `external_request_id`, OR the
  coordinator-internal `request_id` — would risk the gateway
  interpreting it as a buyer-supplied X-Request-ID and returning
  an unrelated account's row that the coordinator would embed
  under unrelated coordinator-side data. The both-or-nothing
  contract eliminates that risk.

Deferred to v0.4 (future enhancement, not in v0.3 IMPL):
- Path-segment overload (operator pastes `external_request_id`
  directly into the path) with `?account_id=` disambiguation
  and 409 ambiguous_request_id mirroring §6.4. v0.3 only
  resolves the path-segment as an internal id; an external
  lookup is left to v0.4 once an operator workflow demands it.
  **v0.4 (#231) status:** explicit overload via prefix typing
  has landed — `int_<request_id>` continues to resolve as a
  coordinator-internal id; `ext_<external_request_id>` (when an
  operator workflow demands it) resolves by re-issuing a scoped
  lookup against `request_log.external_request_id` then proxying
  to the gateway. The bare-id form remains accepted in v0.4
  with a deprecation WARN; v0.5 will reject it.
Path parameters:
- `request_id`: required string. **v0.3:** coordinator-internal
  billing id (UUID v4) only. **v0.4 (#231):** the coordinator
  handler MAY accept an `int_`-prefixed value (e.g.
  `int_<uuid>`) to mark the segment as a coordinator-internal
  `request_id` explicitly; the prefix is stripped before the SQL
  lookup runs. Untyped (bare-UUID) calls are still accepted in
  v0.4 BUT the handler MUST emit a
  `payout_explorer_path_segment_untyped` audit row at severity
  WARN. v0.5 will reject untyped with `400 session_id_untyped`.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `include_gateway`: optional boolean, default `true`.
- `account_id`: (v0.4, deferred) optional disambiguator for the
  path-segment-overload future enhancement; ignored in v0.3.
Window contract:
- No time window is required because `request_id` is an indexed key.
Ambiguity contract (v0.3):
- v0.3 path-segment is the coordinator-internal `request_id`
  (UUID v4, unique by construction); 409 cannot fire on this
  path. The 409 contract is reserved for the v0.4 path-segment-
  overload future enhancement; see "Deferred to v0.4" above.
- Per the both-or-nothing proxy contract in Identity model, the
  coordinator does NOT fall back to forwarding the
  coordinator-internal `request_id` to the gateway when the
  resolved row's `external_request_id` is empty or `account_id`
  is NULL. Such rows return `gateway: {"error": {"code":
  "gateway_identity_unavailable"}}` (see Response schema below
  + §14.7) — this is an expected legacy-identity-limit on
  pre-v1.5.0-coordinator rows or v1.5.0 rows written from a
  pre-v0.9.1 gateway, NOT a gateway failure. Coordinator-side
  detail (attempts, ledger, snapshots) is still returned.
Cursor contract:
- None.
Response schema:
```json
{
  "request_id": "string",
  "attempts": [
    {
      "request_log_id": 0,
      "attempt_n": 0,
      "timestamp_utc": "string",
      "model": "string",
      "provider_assigned_id": "string|null",
      "provider_id": "string|null",
      "stream": false,
      "status": 200,
      "error": "string|null",
      "error_code": "string|null",
      "prompt_tokens": 0,
      "completion_tokens": 0,
      "total_tokens": 0,
      "latency_ms": 0.0,
      "routing_ms": 0.0,
      "retried": false
    }
  ],
  "ledger_rows": [
    {
      "ledger_request_credit_id": 0,
      "attempt_n": 0,
      "provider_id": "string",
      "provider_assigned_id": "string|null",
      "model": "string",
      "status": 200,
      "stream": false,
      "prompt_tokens": 0,
      "completion_tokens": 0,
      "estimated_completion_tokens": 0,
      "usage_source": "provider_reported|byte_estimated|null_error",
      "prompt_rate_per_mtok": 0,
      "completion_rate_per_mtok": 0,
      "global_multiplier_ppm": 0,
      "gross_credits": 0,
      "provider_share_bps": 0,
      "provider_credits": 0,
      "operator_share_bps": 0,
      "operator_credits": 0,
      "fault_flag": "none|breaker_qualifying|null_usage_error",
      "attestation_class": "string|null",
      "settled": false,
      "settlement_id": 0,
      "quarantined": false,
      "quarantine_reason": "string|null",
      "recovery_source": "hot_path|startup_scan|nightly_reconcile"
    }
  ],
  "provider_identity_snapshots": [
    {
      "attempt_n": 0,
      "provider_assigned_id": "string",
      "provider_id": "string",
      "resolved_from": "pool_entry|response_header|admin_recovery",
      "pool_session_started_at_utc": "string|null",
      "created_at_utc": "string"
    }
  ],
  "gateway": {
    "account_id": "string|null",
    "demo_identity": "string|null",
    "usage_event": {},
    "quota_reservation": {},
    "concurrency_reservation": {},
    "feedback_events": [],
    "audit_events": [],
    "error": null
  },
  "partial": false
}
```
Gateway-section error shapes (v0.3):
- `"error": null` — gateway responded 2xx with detail rows.
- `"error": {"code": "gateway_unavailable"}` — coordinator
  attempted the gateway proxy but the gateway returned non-2xx,
  was unreachable, timed out, or the response could not be
  decoded. `partial=true` on the top-level response.
- `"error": {"code": "gateway_identity_unavailable"}` —
  coordinator did NOT proxy because the resolved `request_log`
  row lacks `external_request_id`, `account_id`, or both. This
  is an expected legacy-identity-limit on pre-v1.5.0-coordinator
  rows or v1.5.0 rows written from a pre-v0.9.1 gateway, NOT a
  gateway failure. `partial=false` and coordinator-side detail
  is still fully populated. UI rendering MUST distinguish this
  from `gateway_unavailable` (e.g., a quiet inline notice on
  the gateway panel rather than the failure-banner treatment
  `gateway_unavailable` warrants) so operators do not
  misinterpret legacy-identity rows as retryable gateway
  failures.
Underlying coordinator sources (intra-coordinator joins by internal `request_id`):
- `request_log` by coordinator-internal `request_id` (also reads
  `external_request_id` and `account_id` from the resolved row(s)
  for the gateway proxy forward).
- `ledger_request_credits` by `request_id`.
- `ledger_operator_credits` by `request_id` and `request_credit_id`.
- `ledger_provider_identity_snapshots` by `request_id`.
Underlying gateway endpoint:
- `GET /admin/explorer/sessions/{external_request_id}?account_id=<account_id>`
  (coordinator forwards the resolved row's `external_request_id`
  and `account_id`; see Identity model above for the security
  rationale). When either field is missing on the resolved row,
  the coordinator does NOT proxy — it returns `gateway: {"error":
  {"code": "gateway_identity_unavailable"}}` per the both-or-
  nothing contract.
Timeout:
- 1500 ms local budget.
- 2000 ms gateway proxy budget.
Error behavior:
- Unknown coordinator-internal `request_id` MUST return 404
  regardless of whether the path-segment value happens to match
  any gateway external_request_id (v0.3: path-segment is
  internal-id only — see Identity model + AC-7).
- Gateway unavailable on a proxied request MUST return 200 with
  `partial=true` and the gateway section carrying `error.code =
  "gateway_unavailable"` per §14.7 + Response schema.
- Coordinator-row resolved but the row lacks
  `external_request_id` or `account_id` MUST return 200 with
  `partial=false` and gateway section carrying `error.code =
  "gateway_identity_unavailable"` per the both-or-nothing rule
  + §14.7.1.
### 5.7 `GET /admin/explorer/providers`
Method and path:
- `GET /admin/explorer/providers`.
Purpose:
- Return live provider pool state joined with provider token state and
  ledger-derived economics.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `state`: optional enum `ready`, `busy`, `degraded`, `draining`, `unavailable`.
- `tier`: optional enum `pinned`, `provisional`, `rejected`.
- `model`: optional string exact match.
- `provider_id`: optional string exact match.
- `include_quarantined`: optional boolean, default `false`.
- `limit`: optional integer, default 50, max 200.
- `cursor`: optional opaque cursor.
Window contract:
- Economics summary defaults to the current SPEC-005 settlement window.
- Recent request counters use a default 24-hour window.
- Maximum recent request window is 7 days.
Cursor contract:
- Cursor ordering MUST be by `provider_id ASC`.
Response schema:
```json
{
  "providers": [
    {
      "provider_id": "string",
      "assigned_id": "string",
      "hostname": "string",
      "model_id": "string",
      "model_params_b": 0.0,
      "ram_gb": 0,
      "max_context_tokens": 0,
      "max_concurrency": 0,
      "slots_free": 0,
      "slots_total": 0,
      "throughput_tps_estimate": 0.0,
      "model_load_time_ms": 0,
      "endpoint_url": "string",
      "tier": "pinned|provisional|rejected",
      "inference_path": "http_forwarding|ws_tunneled",
      "admitted_at": "string",
      "http_forwarding_only": false,
      "state": "ready|busy|degraded|draining|unavailable",
      "last_heartbeat_at": "string",
      "last_activity_at": "string",
      "connected_at": "string",
      "binary_version": "string",
      "model_hash": "string",
      "hash_status": "hash_verified|hash_mismatch|hash_invalid|uncatalogued|catalog_unavailable|string",
      "encrypted_leg": false,
      "attestation_status": "attested|attestation_failed|attestation_stale|unsupported|not_required|string",
      "token_prefix": "string|null",
      "token_status": "active|revoked|missing|null",
      "token_created_at": "string|null",
      "token_last_used_at": "string|null",
      "token_revoked_at": "string|null",
      "total_provider_credits": 0,
      "current_window_credits": 0,
      "pending_payout_credits": 0,
      "fault_count": 0,
      "quarantined_count": 0,
      "attestation_class": "string|null"
    }
  ],
  "next_cursor": "string|null"
}
```
Underlying coordinator sources:
- Live pool registry from `phase4-coordinator/internal/pool/provider.go`.
- `provider_tokens`.
- `ledger_request_credits`.
- `ledger_payout_ready`.
- `ledger_provider_identity_snapshots`.
- `ledger_config_snapshots`.
Timeout:
- 1500 ms local budget.
Error behavior:
- Invalid filters MUST return 400.
- Local timeout MUST return 408.
### 5.8 `GET /admin/explorer/providers/{provider_id}`
Method and path:
- `GET /admin/explorer/providers/{provider_id}`.
Purpose:
- Return one provider's live state, token state, recent request attempts,
  payout-ready rows, fault/quarantine history, and rate-card context.
Path parameters:
- `provider_id`: required string.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `from`: optional RFC3339 UTC timestamp.
- `to`: optional RFC3339 UTC timestamp.
- `limit`: optional integer, default 50, max 200 for recent attempts.
- `cursor`: optional opaque cursor for recent attempts.
Window contract:
- Default recent-attempt window is last 24 hours.
- Maximum recent-attempt window is 7 days.
Cursor contract:
- Recent attempts cursor MUST be by `request_log.ts_utc DESC, request_log.id DESC`.
Response schema:
```json
{
  "provider_id": "string",
  "live": {},
  "token": {
    "token_prefix": "string|null",
    "provider_name": "string|null",
    "status": "active|revoked|missing",
    "created_at": "string|null",
    "revoked_at": "string|null",
    "last_used_at": "string|null"
  },
  "economics": {
    "total_provider_credits": 0,
    "current_window_credits": 0,
    "pending_payout_credits": 0,
    "pending_payout_count": 0,
    "fault_count": 0,
    "quarantined_count": 0,
    "models_served": ["string"],
    "rate_card_excerpt": {}
  },
  "recent_attempts": [],
  "payout_ready_rows": [],
  "next_cursor": "string|null"
}
```
Underlying coordinator sources:
- Live pool registry.
- `provider_tokens`.
- `request_log`.
- `ledger_request_credits`.
- `ledger_operator_credits`.
- `ledger_payout_ready`.
- `ledger_config_snapshots`.
Timeout:
- 1500 ms local budget.
Error behavior:
- Unknown `provider_id` MUST return 404 only if absent from live pool, token
  rows, and ledger rows.
### 5.9 `GET /admin/explorer/buyers`
Method and path:
- `GET /admin/explorer/buyers`.
Purpose:
- Proxy the gateway-owned buyer directory through the coordinator origin.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `from`: optional RFC3339 UTC timestamp.
- `to`: optional RFC3339 UTC timestamp.
- `status`: optional enum `active`, `blocked`.
- `quota_class`: optional string.
- `concurrency_class`: optional string.
- `account_id`: optional exact string.
- `email`: optional exact match. The server case-folds the parameter and stored row
  with NFKC plus ASCII-lowercase before comparison. The stored row is not modified.
- `email_prefix`: optional prefix match with the same case-fold rule. If both `email`
  and `email_prefix` are present, the endpoint MUST return 400 with
  `error.code='bad_request'` and `error.detail` identifying the conflict.
- `key_status`: optional enum `active`, `revoked`.
- `summary`: optional boolean, default `false`.
- `limit`: optional integer, default 50, max 200.
- `cursor`: optional opaque cursor.
Window contract:
- Default window is `explorer.buyers_default_window_hours` hours for usage and last
  activity.
- Maximum window is `explorer.buyers_max_window_days` days.
Cursor contract:
- Coordinator MUST pass the cursor through unchanged to gateway.
- Coordinator MUST NOT interpret gateway buyer cursors.
Response schema:
```json
{
  "buyers": [
    {
      "account_id": "string",
      "status": "active|blocked",
      "quota_class": "string",
      "concurrency_class": "string",
      "created_at": "string",
      "identities": [],
      "api_keys": [],
      "daily_tokens_used": 0,
      "daily_tokens_reserved": 0,
      "daily_token_limit": 0,
      "daily_tokens_remaining": 0,
      "active_concurrency_reservations": 0,
      "last_usage_time": "string|null",
      "last_request_id": "string|null",
      "feedback_count": 0,
      "average_rating": 0.0
    }
  ],
  "summary": {
    "active_accounts_window": 0,
    "new_accounts_window": 0,
    "active_api_keys": 0,
    "blocked_accounts": 0
  },
  "next_cursor": "string|null",
  "window": {
    "from_utc": "string",
    "to_utc": "string"
  }
}
```
Underlying gateway endpoint:
- `GET /admin/explorer/buyers`.
Coordinator behavior:
- Verify coordinator operator bearer.
- Add `Authorization: Bearer <coordinator.operator_key>` to the gateway proxy request.
- Proxy method, path, and query unchanged.
- Return gateway JSON unchanged except for transport-level gateway errors.
Timeout:
- 2500 ms total proxy budget.
Error behavior:
- Gateway unavailable MUST return 503 `gateway_unavailable`.
- Gateway 401/403 MUST be surfaced as 502 `gateway_bad_response` because the
  operator's coordinator bearer was already accepted.
### 5.10 `GET /admin/explorer/buyers/{account_id}`
Method and path:
- `GET /admin/explorer/buyers/{account_id}`.
Purpose:
- Proxy one gateway-owned buyer detail record through the coordinator origin.
Path parameters:
- `account_id`: required string.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `from`: optional RFC3339 UTC timestamp.
- `to`: optional RFC3339 UTC timestamp.
- `include_events`: optional boolean, default `true`.
- `limit`: optional integer, default 50, max 200 for event lists.
- `cursor`: optional opaque cursor for event lists.
Window contract:
- Default window is `explorer.buyers_default_window_hours` hours.
- Maximum window is `explorer.buyers_max_window_days` days.
Cursor contract:
- Coordinator MUST pass cursor unchanged to gateway.
Response schema:
```json
{
  "account_id": "string",
  "account": {
    "status": "active|blocked",
    "quota_class": "string",
    "concurrency_class": "string",
    "created_at": "string"
  },
  "identities": [],
  "api_keys": [],
  "usage": {
    "events": [],
    "tokens_window": 0,
    "tokens_today": 0,
    "last_usage_time": "string|null",
    "last_request_id": "string|null"
  },
  "quota": {
    "reservations": [],
    "active_reserved_tokens": 0,
    "expired_reservations": 0
  },
  "concurrency": {
    "active_reservations": 0,
    "reservations": []
  },
  "feedback": {
    "events": [],
    "count": 0,
    "average_rating": 0.0
  },
  "audit": {
    "events": []
  },
  "next_cursor": "string|null"
}
```
Underlying gateway endpoint:
- `GET /admin/explorer/buyers/{account_id}`.
Timeout:
- 2500 ms total proxy budget.
Error behavior:
- Gateway 404 MUST be surfaced as 404 `not_found`.
- Gateway unavailable MUST return 503 `gateway_unavailable`.
### 5.11 `GET /admin/explorer/ledger`
Method and path:
- `GET /admin/explorer/ledger`.
Purpose:
- Return recent ledger entries with operator share, provider share, and
  settlement/quarantine state.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `from`: optional RFC3339 UTC timestamp.
- `to`: optional RFC3339 UTC timestamp.
- `provider_id`: optional string.
- `model`: optional string.
- `usage_source`: optional enum `provider_reported`, `byte_estimated`, `null_error`.
- `fault_flag`: optional enum `none`, `breaker_qualifying`, `null_usage_error`.
- `settled`: optional boolean.
- `quarantined`: optional boolean.
- `limit`: optional integer, default 100, max 200.
- `cursor`: optional opaque cursor.
Window contract:
- Default window is `explorer.ledger_default_window_hours` hours.
- Maximum window is `explorer.ledger_max_window_days` days.
Cursor contract:
- Cursor ordering MUST be `ledger_request_credits.ts_utc DESC, ledger_request_credits.id DESC`.
Response schema:
```json
{
  "entries": [
    {
      "ledger_request_credit_id": 0,
      "request_id": "string",
      "attempt_n": 0,
      "provider_id": "string",
      "provider_assigned_id": "string|null",
      "ts_utc": "string",
      "model": "string",
      "status": 200,
      "stream": false,
      "prompt_tokens": 0,
      "completion_tokens": 0,
      "estimated_completion_tokens": 0,
      "usage_source": "provider_reported|byte_estimated|null_error",
      "prompt_rate_per_mtok": 0,
      "completion_rate_per_mtok": 0,
      "global_multiplier_ppm": 0,
      "gross_credits": 0,
      "provider_share_bps": 0,
      "provider_credits": 0,
      "operator_share_bps": 0,
      "operator_credits": 0,
      "fault_flag": "none|breaker_qualifying|null_usage_error",
      "attestation_class": "string|null",
      "settled": false,
      "settlement_id": 0,
      "quarantined": false,
      "quarantine_reason": "string|null",
      "recovery_source": "hot_path|startup_scan|nightly_reconcile",
      "created_at_utc": "string",
      "updated_at_utc": "string|null"
    }
  ],
  "next_cursor": "string|null",
  "window": {
    "from_utc": "string",
    "to_utc": "string"
  }
}
```
Underlying coordinator sources:
- `ledger_request_credits`.
- `ledger_operator_credits`.
- `ledger_config_snapshots`.
Timeout:
- 1500 ms local budget.
Error behavior:
- Excess window MUST return 400.
- Local timeout MUST return 408.
### 5.12 `GET /admin/explorer/settlements`
Method and path:
- `GET /admin/explorer/settlements`.
Purpose:
- Return `ledger_payout_ready` rows and settlement history read-only.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `provider_id`: optional string.
- `status`: optional enum `ready`, `consumed`, `voided`, default all.
- `from`: optional RFC3339 UTC timestamp on `window_end_utc`.
- `to`: optional RFC3339 UTC timestamp on `window_end_utc`.
- `limit`: optional integer, default 50, max 200.
- `cursor`: optional opaque cursor.
Window contract:
- Default window is `explorer.settlements_default_window_hours` hours.
- Maximum window is `explorer.settlements_max_window_days` days.
Cursor contract:
- Cursor ordering MUST be `ledger_payout_ready.window_end_utc DESC, ledger_payout_ready.id DESC`.
Response schema:
```json
{
  "settlements": [
    {
      "payout_ready_id": 0,
      "provider_id": "string",
      "window_start_utc": "string",
      "window_end_utc": "string",
      "cadence_days": 7,
      "source_credit_count": 0,
      "gross_credits": 0,
      "provider_credits": 0,
      "operator_credits": 0,
      "min_payout_credits": 0,
      "payout_currency": "string|null",
      "payout_external_id": "string|null",
      "status": "ready|consumed|voided",
      "idempotency_key": "string",
      "created_at_utc": "string",
      "latest_reconciliation": {
        "run_id": 0,
        "status": "complete|failed|running|null",
        "delta_credits": 0
      }
    }
  ],
  "next_cursor": "string|null"
}
```
Normative note:
- `payout_currency` and `payout_external_id` MUST be returned as `null` in v0.2
  because no payout-rail spec is active yet.
Underlying coordinator sources:
- `ledger_payout_ready`.
- `ledger_request_credits`.
- `ledger_reconciliation_runs`.
Timeout:
- 1500 ms local budget.
Read-only requirements:
- `POST /admin/explorer/settlements` MUST return 405 or 404.
- `PATCH /admin/explorer/settlements/{id}` MUST return 405 or 404.
- `DELETE /admin/explorer/settlements/{id}` MUST return 405 or 404.
- No explorer endpoint may call the SPEC-005 claim pattern.
### 5.13 `GET /admin/explorer/health`
Method and path:
- `GET /admin/explorer/health`.
Purpose:
- Return health and invariant drift across coordinator, pool, ledger, gateway,
  capacity, and reservations.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `include_gateway`: optional boolean, default `true`.
- `window`: optional enum `24h`, `7d`, default `24h`.
Window contract:
- Maximum window is 7 days.
Cursor contract:
- None.
Response schema:
```json
{
  "checked_at_utc": "string",
  "coordinator_health": "ok|unavailable",
  "gateway_health": "ok|unavailable|unknown",
  "public_status": "ok|degraded|paused|unknown",
  "pool_total_providers": 0,
  "pool_ready_providers": 0,
  "last_reconciliation_status": "complete|failed|running|null",
  "last_reconciliation_delta": 0,
  "quarantined_rows": 0,
  "split_delta_rows": 0,
  "fault_rows": 0,
  "capacity_tier": 0,
  "capacity_signals_firing": 0,
  "public_api_paused": false,
  "demo_paused": false,
  "active_quota_reservations": 0,
  "expired_quota_reservations": 0,
  "active_concurrency_reservations": 0,
  "provider_reconnect_count": null,
  "coordinator_restart_count": null,
  "gateway_error": null
}
```
Underlying coordinator sources:
- `/healthz`.
- Live pool registry.
- `ledger_reconciliation_runs`.
- `ledger_request_credits`.
- `ledger_operator_credits`.
Underlying gateway endpoint:
- `GET /admin/explorer/health`.
Timeout:
- 1500 ms local budget.
- 2000 ms gateway proxy budget.
Known limitations:
- Provider reconnect count is `null` in v1 because no durable provider event table exists.
- Coordinator restart count is `null` in v1 because no restart table exists.
### 5.14 `GET /admin/explorer/activity`
Method and path:
- `GET /admin/explorer/activity`.
Purpose:
- Return a merged recent activity feed from existing coordinator and gateway
  event sources.
Headers:
- `Authorization: Bearer <coordinator operator bearer>` is required.
Query parameters:
- `from`: optional RFC3339 UTC timestamp.
- `to`: optional RFC3339 UTC timestamp.
- `type`: optional event type filter.
- `severity`: optional enum `info`, `warn`, `error`.
- `request_id`: optional string.
- `account_id`: optional string.
- `provider_id`: optional string.
- `limit`: optional integer, default 50, max 200.
- `cursor`: optional opaque cursor for older events.
- `since_cursor`: optional opaque cursor for newer events.
- `include_gateway`: optional boolean, default `true`.
Window contract:
- Default window is `explorer.activity_default_window_hours` hours.
- Maximum window is `explorer.activity_max_window_days` days.
Cursor contract:
- Event order MUST be `event_time_utc DESC, source_rank DESC, source_id DESC`.
- `cursor` MUST page older events.
- `since_cursor` MUST poll newer events.
- A response MUST include `latest_cursor`.
- A response MUST include `next_cursor`.
- The same cursor format MUST be usable by a later SSE wrapper.
Response schema:
```json
{
  "events": [
    {
      "event_time_utc": "string",
      "event_type": "request_completed|ledger_credit|payout_ready|reconciliation|api_key_event|audit_event|feedback|capacity_signal",
      "severity": "info|warn|error",
      "source": "coordinator|gateway",
      "source_id": "string",
      "request_id": "string|null",
      "account_id": "string|null",
      "key_id": "string|null",
      "provider_id": "string|null",
      "model_id": "string|null",
      "status": "string|null",
      "error_code": "string|null",
      "tokens": 0,
      "credits": 0,
      "link_target": "string"
    }
  ],
  "latest_cursor": "string|null",
  "next_cursor": "string|null",
  "partial": false,
  "warnings": []
}
```
Underlying coordinator sources:
- `request_log`.
- `ledger_request_credits`.
- `ledger_payout_ready`.
- `ledger_reconciliation_runs`.
Underlying gateway endpoint:
- `GET /admin/explorer/activity`.
Timeout:
- 1500 ms local budget.
- 2000 ms gateway proxy budget.
Error behavior:
- Gateway failure MUST return 200 with `partial=true` when local events are available.
- Local timeout MUST return 408.
## 6. Read-only endpoint surface (gateway)
### 6.1 Common gateway endpoint contract
Gateway explorer endpoints live under `/admin/explorer/*` on the gateway. Gateway explorer endpoints are explorer-facing only. Gateway explorer endpoints are not part of the public buyer-facing surface in SPEC-006.
Gateway explorer endpoints MUST require:
- `Authorization: Bearer <coordinator.operator_key>`.
Gateway explorer endpoints MUST be side-effect-free. Gateway explorer endpoints MUST be idempotent. Gateway explorer endpoints MUST support only `GET`. Gateway explorer endpoints MUST accept the same coordinator operator bearer as the rest of gateway `/admin/*`. Gateway explorer endpoints MUST NOT accept buyer API keys. Gateway explorer endpoints MUST NOT accept demo tokens. Gateway explorer endpoints MUST NOT be exposed through public CORS.
Gateway explorer endpoint error envelope is:
```json
{
  "error": {
    "code": "string",
    "message": "string",
    "source": "gateway",
    "retryable": false
  }
}
```
Allowed common errors:
- 400 `invalid_request`.
- 401 `invalid_operator_token`.
- 404 `not_found`.
- 405 `method_not_allowed`.
- 408 `query_timeout`.
- 500 `internal_error`.
Endpoint-specific error exceptions:
- § 6.4 `GET /admin/explorer/sessions/{request_id}` MAY return
  `409 ambiguous_request_id` with an OpenAI-compatible error shape
  (`error.type`, `error.code`, `error.message`) plus top-level
  `request_id` and `matched_account_ids` fields. This exception
  predates and is shaped to match the gateway's OpenAI-compatible
  error surface so that operator UIs can render a disambiguation
  picker. The common-envelope `source` and `retryable` fields are
  omitted on this response.
Default gateway query timeout is 1500 milliseconds. Maximum gateway query timeout is 5000 milliseconds.
### 6.2 `GET /admin/explorer/buyers`
Method and path:
- `GET /admin/explorer/buyers`.
Purpose:
- Return account and API-key directory rows with bounded usage summaries.
Headers:
- `Authorization: Bearer <coordinator.operator_key>` is required.
Query parameters:
- `from`: optional RFC3339 UTC timestamp.
- `to`: optional RFC3339 UTC timestamp.
- `status`: optional enum `active`, `blocked`.
- `quota_class`: optional string.
- `concurrency_class`: optional string.
- `account_id`: optional exact string.
- `email`: optional exact match. The server case-folds the parameter and stored row
  with NFKC plus ASCII-lowercase before comparison. The stored row is not modified.
- `email_prefix`: optional prefix match with the same case-fold rule. If both `email`
  and `email_prefix` are present, the endpoint MUST return 400 with
  `error.code='bad_request'` and `error.detail` identifying the conflict.
- `key_status`: optional enum `active`, `revoked`.
- `summary`: optional boolean.
- `limit`: optional integer, default 50, max 200.
- `cursor`: optional opaque cursor.
Window contract:
- Default window is `explorer.buyers_default_window_hours` hours.
- Maximum window is `explorer.buyers_max_window_days` days.
Cursor contract:
- Cursor ordering MUST be `accounts.account_id ASC`.
- Cursor MUST remain stable across new accounts.
Response fields:
- `buyers[].account_id`: string.
- `buyers[].status`: string.
- `buyers[].quota_class`: string.
- `buyers[].concurrency_class`: string.
- `buyers[].created_at`: RFC3339 string.
- `buyers[].identities[].provider`: string.
- `buyers[].identities[].provider_user_id`: string.
- `buyers[].identities[].email`: string.
- `buyers[].api_keys[].key_id`: string.
- `buyers[].api_keys[].key_hash_prefix`: string.
- `buyers[].api_keys[].status`: string.
- `buyers[].api_keys[].created_at`: RFC3339 string.
- `buyers[].api_keys[].revoked_at`: RFC3339 string or empty string.
- `buyers[].daily_tokens_used`: integer.
- `buyers[].daily_tokens_reserved`: integer.
- `buyers[].daily_token_limit`: integer.
- `buyers[].daily_tokens_remaining`: integer.
- `buyers[].active_concurrency_reservations`: integer.
- `buyers[].last_usage_time`: RFC3339 string or null.
- `buyers[].last_request_id`: string or null.
- `buyers[].feedback_count`: integer.
- `buyers[].average_rating`: number or null.
- `summary.active_accounts_window`: integer.
- `summary.new_accounts_window`: integer.
- `summary.active_api_keys`: integer.
- `summary.blocked_accounts`: integer.
- `next_cursor`: string or null.
Underlying gateway tables:
- `accounts`.
- `account_identities`.
- `api_keys`.
- `usage_events`.
- `quota_reservations`.
- `concurrency_reservations`.
- `feedback_events`.
- `signup_events`.
Forbidden fields:
- `api_keys.key_hash` MUST NOT be returned.
- OAuth state rows MUST NOT be returned.
- Demo token hashes MUST NOT be returned.
### 6.3 `GET /admin/explorer/buyers/{account_id}`
Method and path:
- `GET /admin/explorer/buyers/{account_id}`.
Purpose:
- Return one account's identity, keys, usage, quota, feedback, and audit context.
Path parameters:
- `account_id`: required string.
Headers:
- `Authorization: Bearer <coordinator.operator_key>` is required.
Query parameters:
- `from`: optional RFC3339 UTC timestamp.
- `to`: optional RFC3339 UTC timestamp.
- `include_events`: optional boolean, default `true`.
- `limit`: optional integer, default 50, max 200.
- `cursor`: optional opaque cursor for event lists.
Window contract:
- Default window is `explorer.buyers_default_window_hours` hours.
- Maximum window is `explorer.buyers_max_window_days` days.
Cursor contract:
- Event cursor ordering MUST be `created_at DESC, source_id DESC`.
Response fields:
- `account.account_id`: string.
- `account.status`: string.
- `account.quota_class`: string.
- `account.concurrency_class`: string.
- `account.created_at`: RFC3339 string.
- `identities[].provider`: string.
- `identities[].provider_user_id`: string.
- `identities[].email`: string.
- `api_keys[].key_id`: string.
- `api_keys[].key_hash_prefix`: string.
- `api_keys[].status`: string.
- `api_keys[].created_at`: RFC3339 string.
- `api_keys[].revoked_at`: RFC3339 string or empty string.
- `usage.events[].request_id`: string.
- `usage.events[].demo_identity`: string.
- `usage.events[].window_date`: YYYY-MM-DD string.
- `usage.events[].prompt_tokens`: integer.
- `usage.events[].completion_tokens`: integer.
- `usage.events[].total_tokens`: integer.
- `usage.events[].token_source`: string.
- `usage.events[].outcome`: string.
- `usage.events[].created_at`: RFC3339 string.
- `quota.reservations[].request_id`: string.
- `quota.reservations[].window_date`: YYYY-MM-DD string.
- `quota.reservations[].reserved_tokens`: integer.
- `quota.reservations[].settled_tokens`: integer.
- `quota.reservations[].status`: string.
- `quota.reservations[].expires_at`: RFC3339 string.
- `quota.reservations[].created_at`: RFC3339 string.
- `quota.reservations[].settled_at`: RFC3339 string or empty string.
- `concurrency.reservations[].request_id`: string.
- `concurrency.reservations[].status`: string.
- `concurrency.reservations[].expires_at`: RFC3339 string.
- `concurrency.reservations[].created_at`: RFC3339 string.
- `concurrency.reservations[].released_at`: RFC3339 string or empty string.
- `feedback.events[].event_id`: string.
- `feedback.events[].request_id`: string.
- `feedback.events[].scope`: string.
- `feedback.events[].rating`: integer.
- `feedback.events[].comment`: string.
- `feedback.events[].created_at`: RFC3339 string.
- `audit.events[].event_id`: string.
- `audit.events[].request_id`: string.
- `audit.events[].actor`: string.
- `audit.events[].event_type`: string.
- `audit.events[].payload_json`: string.
- `audit.events[].created_at`: RFC3339 string.
- `next_cursor`: string or null.
Underlying gateway tables:
- `accounts`.
- `account_identities`.
- `api_keys`.
- `api_key_events`.
- `usage_events`.
- `quota_reservations`.
- `concurrency_reservations`.
- `feedback_events`.
- `audit_events`.
Forbidden fields:
- `api_keys.key_hash` MUST NOT be returned.
- `demo_usage_events.demo_token_hash` MUST NOT be returned.
### 6.4 `GET /admin/explorer/sessions/{request_id}`
Method and path:
- `GET /admin/explorer/sessions/{request_id}`.
Purpose:
- Return gateway-owned request context for a completed request.
Identity model:
- The physical identity of a gateway-owned request row is the composite
  `(account_id, request_id)` (see #196). `request_id` alone is a
  logical join key; the same buyer-supplied `X-Request-ID` MAY appear
  in `usage_events` rows belonging to different accounts. Operators
  MUST treat `request_id` as account-scoped when reconciling against
  gateway storage.
Path parameters:
- `request_id`: required string. **v0.4 path-segment typing
  (#231):** the gateway handler MAY accept an `ext_`-prefixed value
  (e.g. `ext_req-abc123`) to mark the segment as an
  `external_request_id` explicitly; the prefix is stripped before
  the SQL lookup runs. Untyped (bare) calls are still accepted in
  v0.4 for backward compatibility BUT the handler MUST emit a
  `payout_explorer_path_segment_untyped` `audit_events` row at
  severity WARN with `endpoint, request_id, ts_utc` to surface the
  upcoming v0.5 break. v0.5 will reject untyped with
  `400 session_id_untyped`.
Headers:
- `Authorization: Bearer <coordinator.operator_key>` is required.
Query parameters:
- `account_id`: optional string. When supplied, the handler scopes all
  sub-queries (`usage_events`, `quota_reservations`,
  `concurrency_reservations`, `feedback_events`, `audit_events`) by
  `(account_id, request_id)`. When omitted, the handler performs an
  unscoped lookup; if the unscoped lookup matches rows in more than one
  account it MUST return `409 ambiguous_request_id` (see ambiguity
  contract below).
Window contract:
- No time window is required.
  - For the **scoped path** (`?account_id=` supplied) all child
    tables use the composite PK `(account_id, request_id)` and the
    lookup is index-bounded.
  - For the **unscoped path** (`?account_id=` omitted) only
    `usage_events` carries a request-id-leading auxiliary index
    (`idx_usage_request ON usage_events(request_id)`); reservation
    and event tables (`quota_reservations`,
    `concurrency_reservations`, `feedback_events`, `audit_events`)
    are looked up by `request_id` against their composite PK and
    auxiliary indexes, which can scan a wider range. Operators
    SHOULD prefer the scoped path when an `account_id` is already
    known.
Cursor contract:
- None.
Ambiguity contract:
- If `account_id` is omitted and the unscoped lookup matches rows
  from more than one `account_id`, the handler MUST respond
  `409 Conflict` with the following body shape:
  ```json
  {
    "error": {
      "type": "invalid_request_error",
      "code": "ambiguous_request_id",
      "message": "request_id matches multiple accounts; supply ?account_id= to disambiguate"
    },
    "request_id": "<request_id>",
    "matched_account_ids": ["acct_A", "acct_B"],
    "matched_account_ids_truncated": false
  }
  ```
- `matched_account_ids` MUST be the set of distinct `account_id`
  values observed for `request_id` across ALL FIVE account-keyed
  session-detail tables: `usage_events`, `quota_reservations`,
  `concurrency_reservations`, `feedback_events`, and
  `audit_events`. The composite-PK schema permits the same
  `request_id` to legitimately appear in any of these tables for
  distinct accounts; in particular, feedback rows carry a
  caller-supplied `request_id` and so a buyer-attached feedback
  row from one account would otherwise cross-pollinate another
  account's 200 response on the unscoped path without triggering
  409. All five tables are therefore ambiguity-bearing sources.
  Clients SHOULD re-issue the request with one of the returned
  account IDs as the `?account_id=` query parameter. The handler
  MUST NOT 409 when `account_id` is supplied.
- **v0.4 bound (#231):** `matched_account_ids` MUST be capped at
  N=10 entries. When the underlying UNION resolves to >10 distinct
  account_ids the response MUST set
  `"matched_account_ids_truncated": true`; the field MUST be
  present and `false` on the non-truncated path so clients can
  rely on its presence. When truncation fires the gateway MUST
  also emit an `audit_events` row at severity WARN with the FULL
  unbounded account_id list under `event_payload.matched_account_ids`
  for post-hoc investigation. Cap protects the 409 body against
  malicious cross-account-collision floods and bounds operator
  log noise without losing forensic detail.
Response fields:
- `request_id`: string.
- `usage_event.request_id`: string.
- `usage_event.account_id`: string.
- `usage_event.demo_identity`: string.
- `usage_event.window_date`: string.
- `usage_event.prompt_tokens`: integer.
- `usage_event.completion_tokens`: integer.
- `usage_event.total_tokens`: integer.
- `usage_event.token_source`: string.
- `usage_event.outcome`: string.
- `usage_event.created_at`: RFC3339 string.
- `quota_reservation.account_id`: string.
- `quota_reservation.request_id`: string.
- `quota_reservation.status`: string.
- `quota_reservation.reserved_tokens`: integer.
- `quota_reservation.settled_tokens`: integer.
- `concurrency_reservation.account_id`: string.
- `concurrency_reservation.request_id`: string.
- `concurrency_reservation.status`: string.
- `feedback_events[]`: array.
- `audit_events[]`: array.
Underlying gateway tables:
- `usage_events` (primary key `(account_id, request_id)`; auxiliary
  index `idx_usage_request ON usage_events(request_id)` supports the
  unscoped lookup path).
- `quota_reservations`.
- `concurrency_reservations`.
- `feedback_events`.
- `audit_events`.
Forbidden fields:
- `api_keys.key_hash` MUST NOT be returned.
- `demo_usage_events.demo_token_hash` MUST NOT be returned.
- Any OAuth state / refresh-token / one-time-code material MUST NOT
  be returned.
### 6.5 `GET /admin/explorer/activity`
Method and path:
- `GET /admin/explorer/activity`.
Purpose:
- Return gateway-side activity feed fragments for coordinator merging.
Headers:
- `Authorization: Bearer <coordinator.operator_key>` is required.
Query parameters:
- `from`: optional RFC3339 UTC timestamp.
- `to`: optional RFC3339 UTC timestamp.
- `type`: optional event type filter.
- `account_id`: optional string.
- `request_id`: optional string.
- `limit`: optional integer, default 50, max 200.
- `cursor`: optional opaque cursor.
- `since_cursor`: optional opaque cursor.
Window contract:
- Default window is `explorer.activity_default_window_hours` hours.
- Maximum window is `explorer.activity_max_window_days` days.
Cursor contract:
- Event order MUST be `created_at DESC, source_rank DESC, source_id DESC`.
- `cursor` pages older events.
- `since_cursor` returns newer events.
Event sources:
- `usage_events`.
- `api_key_events`.
- `audit_events`.
- `feedback_events`.
- `capacity_signal_events`.
- `signup_events`.
- `demo_session_events`.
- `demo_usage_events`.
Response fields:
- `events[].event_time_utc`: RFC3339 string.
- `events[].event_type`: string.
- `events[].severity`: string.
- `events[].source`: `"gateway"`.
- `events[].source_id`: string.
- `events[].request_id`: string or null.
- `events[].account_id`: string or null.
- `events[].key_id`: string or null.
- `events[].provider_id`: null.
- `events[].model_id`: null.
- `events[].status`: string or null.
- `events[].error_code`: string or null.
- `events[].tokens`: integer or null.
- `events[].credits`: null.
- `events[].link_target`: string.
- `latest_cursor`: string or null.
- `next_cursor`: string or null.
### 6.6 `GET /admin/explorer/health`
Method and path:
- `GET /admin/explorer/health`.
Purpose:
- Return gateway health, capacity, pause, and reservation drift fields for the
  coordinator explorer health view.
Headers:
- `Authorization: Bearer <coordinator.operator_key>` is required.
Query parameters:
- `window`: optional enum `24h`, `7d`, default `24h`.
Window contract:
- Maximum window is 7 days.
Cursor contract:
- None.
Response fields:
- `checked_at_utc`: RFC3339 string.
- `gateway_health`: string.
- `public_status`: string.
- `capacity_tier`: integer.
- `capacity_signals_firing`: integer.
- `public_api_paused`: boolean.
- `demo_paused`: boolean.
- `active_accounts_window`: integer.
- `new_accounts_window`: integer.
- `active_api_keys`: integer.
- `active_quota_reservations`: integer.
- `expired_quota_reservations`: integer.
- `active_concurrency_reservations`: integer.
- `usage_events_window`: integer.
- `demo_usage_events_window`: integer.
- `feedback_events_window`: integer.
- `audit_events_window`: integer.
Underlying gateway tables:
- `accounts`.
- `api_keys`.
- `usage_events`.
- `demo_usage_events`.
- `quota_reservations`.
- `concurrency_reservations`.
- `feedback_events`.
- `audit_events`.
- `capacity_signal_events`.
- `runtime_config`.
## 7. Data sources and joins
### 7.1 Coordinator request source
`request_log` is the canonical coordinator completed-attempt source.
Columns used:
- `id`.
- `ts_utc`.
- `request_id`.
- `model`.
- `provider_assigned_id`.
- `prompt_tokens`.
- `completion_tokens`.
- `total_tokens`.
- `latency_ms`.
- `routing_ms`.
- `status`.
- `stream`.
- `buyer_ip`.
- `error`.
- `error_code`.
- `pref_header`.
- `provider_header`.
- `retried`.
Indexes used:
- `idx_request_log_ts_utc`.
- `idx_request_log_request_id_id`.
### 7.2 Coordinator ledger sources
`ledger_request_credits` is the canonical request-credit source.
Columns used:
- `id`.
- `request_id`.
- `attempt_n`.
- `provider_id`.
- `provider_assigned_id`.
- `ts_utc`.
- `model`.
- `status`.
- `stream`.
- `prompt_tokens`.
- `completion_tokens`.
- `estimated_completion_tokens`.
- `usage_source`.
- `prompt_rate_per_mtok`.
- `completion_rate_per_mtok`.
- `global_multiplier_ppm`.
- `gross_credits`.
- `provider_share_bps`.
- `provider_credits`.
- `fault_flag`.
- `attestation_class`.
- `settled`.
- `settlement_id`.
- `quarantined`.
- `quarantine_reason`.
- `recovery_source`.
- `created_at_utc`.
- `updated_at_utc`.
`ledger_operator_credits` is the canonical operator-credit source.
Columns used:
- `id`.
- `request_credit_id`.
- `request_id`.
- `attempt_n`.
- `provider_id`.
- `ts_utc`.
- `gross_credits`.
- `operator_share_bps`.
- `operator_credits`.
- `fault_flag`.
- `created_at_utc`.
`ledger_payout_ready` is the canonical settlement-ready source.
Columns used:
- `id`.
- `provider_id`.
- `window_start_utc`.
- `window_end_utc`.
- `cadence_days`.
- `source_credit_count`.
- `gross_credits`.
- `provider_credits`.
- `operator_credits`.
- `min_payout_credits`.
- `payout_currency`.
- `payout_external_id`.
- `status`.
- `idempotency_key`.
- `created_at_utc`.
`ledger_reconciliation_runs` is the canonical reconciliation source.
Columns used:
- `id`.
- `run_type`.
- `from_utc`.
- `to_utc`.
- `request_log_rows_scanned`.
- `missing_credit_rows_created`.
- `orphan_credit_rows_quarantined`.
- `buyer_equivalent_credits`.
- `provider_gross_credits`.
- `reconciliation_delta_credits`.
- `started_at_utc`.
- `finished_at_utc`.
- `status`.
- `error`.
- `created_at_utc`.
`ledger_config_snapshots` is the rate-card context source.
Columns used:
- `id`.
- `effective_at_utc`.
- `config_hash`.
- `provider_share_bps`.
- `global_multiplier_ppm`.
- `rate_card_json`.
- `created_at_utc`.
`ledger_provider_identity_snapshots` is the provider identity source.
Columns used:
- `id`.
- `request_id`.
- `attempt_n`.
- `provider_assigned_id`.
- `provider_id`.
- `resolved_from`.
- `pool_session_started_at_utc`.
- `created_at_utc`.
### 7.3 Coordinator provider-token source
`provider_tokens` is the provider token source.
Columns used:
- `id`.
- `token_prefix`.
- `provider_id`.
- `provider_name`.
- `created_at`.
- `revoked_at`.
- `last_used_at`.
Forbidden column:
- `token_hash` MUST NOT be returned.
### 7.4 Gateway buyer sources
Gateway account and buyer tables are read only through gateway `/admin/explorer/*`.
Tables and key columns:
- `accounts.account_id`.
- `accounts.status`.
- `accounts.quota_class`.
- `accounts.concurrency_class`.
- `accounts.created_at`.
- `account_identities.account_id`.
- `account_identities.provider`.
- `account_identities.provider_user_id`.
- `account_identities.email`.
- `account_identities.created_at`.
- `api_keys.key_id`.
- `api_keys.account_id`.
- `api_keys.key_hash_prefix`.
- `api_keys.status`.
- `api_keys.created_at`.
- `api_keys.revoked_at`.
- `api_key_events.event_id`.
- `api_key_events.key_id`.
- `api_key_events.account_id`.
- `api_key_events.request_id`.
- `api_key_events.event_type`.
- `api_key_events.actor`.
- `api_key_events.created_at`.
- `usage_events.request_id`.
- `usage_events.account_id`.
- `usage_events.demo_identity`.
- `usage_events.window_date`.
- `usage_events.prompt_tokens`.
- `usage_events.completion_tokens`.
- `usage_events.total_tokens`.
- `usage_events.token_source`.
- `usage_events.outcome`.
- `usage_events.created_at`.
- `quota_reservations.account_id`.
- `quota_reservations.request_id`.
- `quota_reservations.window_date`.
- `quota_reservations.reserved_tokens`.
- `quota_reservations.settled_tokens`.
- `quota_reservations.status`.
- `quota_reservations.expires_at`.
- `quota_reservations.created_at`.
- `quota_reservations.settled_at`.
- `concurrency_reservations.account_id`.
- `concurrency_reservations.request_id`.
- `concurrency_reservations.status`.
- `concurrency_reservations.expires_at`.
- `concurrency_reservations.created_at`.
- `concurrency_reservations.released_at`.
- `feedback_events.event_id`.
- `feedback_events.request_id`.
- `feedback_events.account_id`.
- `feedback_events.scope`.
- `feedback_events.rating`.
- `feedback_events.comment`.
- `feedback_events.created_at`.
- `audit_events.event_id`.
- `audit_events.request_id`.
- `audit_events.account_id`.
- `audit_events.actor`.
- `audit_events.event_type`.
- `audit_events.payload_json`.
- `audit_events.created_at`.
- `capacity_signal_events.event_id`.
- `capacity_signal_events.signal`.
- `capacity_signal_events.value`.
- `capacity_signal_events.threshold`.
- `capacity_signal_events.firing`.
- `capacity_signal_events.created_at`.
- `runtime_config.key`.
- `runtime_config.value`.
- `runtime_config.updated_at`.
Forbidden gateway columns:
- `api_keys.key_hash`.
- `oauth_states.state_hash`.
- `oauth_states.session_id`.
- `demo_usage_events.demo_token_hash`.
### 7.5 Cross-component join keys

**Intra-coordinator joins (single coordinator-internal request_id).**
`request_log.request_id` is the coordinator-internal billing id
(server-minted UUID v4 per buyer request; see SPEC-002 v1.5.0
§11 and `requestIDForBuyerRequest()`). It joins ONLY to other
coordinator-internal tables that carry the same internal id:
- `ledger_request_credits.request_id`.
- `ledger_operator_credits.request_id`.
- `ledger_provider_identity_snapshots.request_id`.

**Cross-service joins (gateway ↔ coordinator) MUST be account-scoped
under the composite key.** Coordinator `request_log.external_request_id`
is the inbound buyer-supplied `X-Request-ID` carried across the
gateway/coordinator boundary; coordinator `request_log.account_id`
is the gateway-forwarded subject account id. The reconciliation
join is:
- `(request_log.account_id, request_log.external_request_id)` ⇔
  gateway `(usage_events.account_id, usage_events.request_id)` ⇔
  `(quota_reservations.account_id, quota_reservations.request_id)` ⇔
  `(concurrency_reservations.account_id, concurrency_reservations.request_id)` ⇔
  `(feedback_events.account_id, feedback_events.request_id)` ⇔
  `(audit_events.account_id, audit_events.request_id)` ⇔
  `(api_key_events.account_id, api_key_events.request_id)`.

`external_request_id` alone is a logical correlation value, NOT a
unique row identity — the same buyer-supplied `X-Request-ID` MAY
appear in rows belonging to distinct accounts (the post-#196 / #211
cross-account collision class). Any reconciliation query that
ignores `account_id` is ambiguous on cross-account collisions.

Legacy rows with NULL `account_id` (pre-v1.5.0-coordinator rows OR
v1.5.0-coordinator rows written from a pre-v0.9.1 gateway) have NO
account-scoped reconciliation key. Out-of-process audit tooling
that reconciles such rows MAY use the prior `external_request_id`-
only key with the documented cross-account ambiguity, but the
explorer's §5.6 session-detail handler MUST NOT proxy such rows to
the gateway (see §5.6 both-or-nothing rule + `gateway_identity_unavailable`).
Tooling MUST gate this per-row, not per-schema (see SPEC-002 v1.5.0
§11 "Deploy ordering").
`provider_id` is an intra-coordinator join key.
`provider_id` joins:
- live pool provider `Provider.ProviderID`.
- `provider_tokens.provider_id`.
- `ledger_request_credits.provider_id`.
- `ledger_operator_credits.provider_id`.
- `ledger_payout_ready.provider_id`.
- `ledger_provider_identity_snapshots.provider_id`.
`account_id` is an intra-gateway join key.
`account_id` joins:
- `accounts.account_id`.
- `account_identities.account_id`.
- `api_keys.account_id`.
- `api_key_events.account_id`.
- `usage_events.account_id`.
- `quota_reservations.account_id`.
- `concurrency_reservations.account_id`.
- `feedback_events.account_id`.
- `audit_events.account_id`.
`key_id` is an intra-gateway join key.
`key_id` joins:
- `api_keys.key_id`.
- `api_key_events.key_id`.
### 7.6 Shared durable session limitation
The repo does not currently have a shared durable `session_id` across gateway, coordinator, and provider. SPEC-007 v1 MUST NOT introduce a `session_id`. SPEC-007 v1 MUST use `request_id` for session detail. Provider connect/disconnect sessions are not durable in v1. Demo usage is not tied to a stable account in v1.
## 8. Views (internal cockpit)
### 8.1 Overview
Operator question:
- Is the protocol alive and are accounting numbers sane?
Endpoints:
- `GET /admin/explorer/overview`.
Refresh model:
- Automatic refresh every 30 seconds while visible.
- Manual refresh always available.
- Hidden tabs MUST pause.
Fields:
| Field | Privacy tag |
|---|---|
| `protocol_status` | public-raw |
| `checked_at_utc` | public-aggregate |
| `coordinator.health` | public-raw |
| `gateway.health` | public-raw |
| `pool.total_providers` | public-aggregate |
| `pool.ready_providers` | public-aggregate |
| `pool.degraded_providers` | public-aggregate |
| `pool.unavailable_providers` | public-aggregate |
| `pool.models_available` | public-raw |
| `pool.slots_free` | public-aggregate |
| `pool.slots_total` | public-aggregate |
| `traffic.requests_window` | public-aggregate |
| `traffic.tokens_window` | public-aggregate |
| `buyers.active_accounts_window` | public-aggregate |
| `ledger.current_window_provider_credits` | public-aggregate |
| `ledger.total_gross_credits` | public-aggregate |
| `ledger.total_provider_credits` | public-aggregate |
| `ledger.total_operator_credits` | operator-only |
| `ledger.pending_payout_count` | public-aggregate |
| `ledger.pending_payout_credits` | public-aggregate |
| `ledger.quarantined_count` | operator-only |
| `ledger.fault_count` | public-aggregate |
| `reconciliation.last_delta_credits` | public-aggregate |
| `gateway.capacity_tier` | public-raw |
| `gateway.public_api_paused` | public-raw |
| `gateway.demo_paused` | public-raw |
### 8.2 Live state
Operator question:
- What can route right now?
Endpoints:
- `GET /admin/explorer/providers`.
- `GET /admin/explorer/health`.
Refresh model:
- Provider live state refreshes every 10 seconds while visible.
- Economics in the same view refreshes every 30 seconds while visible.
- Hidden tabs MUST pause.
Fields:
| Field | Privacy tag |
|---|---|
| `provider_id` | public-redacted |
| `assigned_id` | operator-only |
| `hostname` | operator-only |
| `model_id` | public-raw |
| `model_params_b` | public-aggregate |
| `state` | public-aggregate |
| `tier` | operator-only |
| `inference_path` | public-aggregate |
| `slots_free` | public-aggregate |
| `slots_total` | public-aggregate |
| `max_concurrency` | public-aggregate |
| `max_context_tokens` | public-raw |
| `ram_gb` | public-aggregate |
| `throughput_tps_estimate` | public-aggregate |
| `model_load_time_ms` | public-aggregate |
| `last_heartbeat_at` | operator-only |
| `last_activity_at` | operator-only |
| `connected_at` | operator-only |
| `binary_version` | operator-only |
| `model_hash` | public-redacted |
| `hash_status` | public-aggregate |
| `encrypted_leg` | public-aggregate |
| `attestation_status` | public-aggregate |
| `endpoint_url` | operator-only |
### 8.3 Activity feed
Operator question:
- What just happened?
Endpoints:
- `GET /admin/explorer/activity`.
Refresh model:
- Poll every 15 seconds by `since_cursor` while visible.
- Hidden tabs MUST pause.
- Manual refresh MUST be available.
Fields:
| Field | Privacy tag |
|---|---|
| `event_time_utc` | public-aggregate |
| `event_type` | public-aggregate |
| `severity` | operator-only |
| `source` | operator-only |
| `source_id` | operator-only |
| `request_id` | public-redacted |
| `account_id` | operator-only |
| `key_id` | operator-only |
| `provider_id` | public-redacted |
| `model_id` | public-raw |
| `status` | public-aggregate |
| `error_code` | public-aggregate |
| `tokens` | public-aggregate |
| `credits` | public-aggregate |
| `link_target` | operator-only |
### 8.4 Sessions and requests
Operator question:
- Which completed request attempts succeeded, failed, retried, or produced ledger rows?
Endpoints:
- `GET /admin/explorer/sessions`.
- `GET /admin/explorer/sessions/{request_id}`.
Refresh model:
- Page-load fetch.
- Manual refresh.
- Optional live toggle at 30 seconds while visible.
- Hidden tabs MUST pause.
Fields:
| Field | Privacy tag |
|---|---|
| `timestamp_utc` | public-aggregate |
| `request_id` | public-redacted |
| `attempt_n` | operator-only |
| `model` | public-raw |
| `provider_id` | public-redacted |
| `provider_assigned_id` | operator-only |
| `account_id` | operator-only |
| `demo` | operator-only |
| `stream` | public-aggregate |
| `status` | public-aggregate |
| `error` | operator-only |
| `error_code` | public-aggregate |
| `prompt_tokens` | public-aggregate |
| `completion_tokens` | public-aggregate |
| `total_tokens` | public-aggregate |
| `usage_source` | public-aggregate |
| `latency_ms` | public-aggregate |
| `routing_ms` | public-aggregate |
| `retried` | public-aggregate |
| `gross_credits` | public-aggregate |
| `provider_credits` | public-aggregate |
| `operator_credits` | operator-only |
| `fault_flag` | operator-only |
| `quarantined` | operator-only |
| `quarantine_reason` | operator-only |
| `quota_reservation_status` | operator-only |
| `gateway_outcome` | public-aggregate |
| `feedback_rating` | operator-only |
### 8.5 Buyers
Operator question:
- Who is using the network and how much quota are they consuming?
Endpoints:
- `GET /admin/explorer/buyers`.
- `GET /admin/explorer/buyers/{account_id}`.
Refresh model:
- Page-load fetch.
- Manual refresh.
- Optional 60-second refresh while visible.
- Hidden tabs MUST pause.
Fields:
| Field | Privacy tag |
|---|---|
| `account_id` | operator-only |
| `account.status` | operator-only |
| `identity.provider` | operator-only |
| `identity.provider_user_id` | operator-only |
| `identity.email` | operator-only |
| `quota_class` | operator-only |
| `concurrency_class` | operator-only |
| `account.created_at` | operator-only |
| `api_key.key_id` | operator-only |
| `api_key.key_hash_prefix` | operator-only |
| `api_key.status` | operator-only |
| `api_key.created_at` | operator-only |
| `api_key.revoked_at` | operator-only |
| `daily_tokens_used` | operator-only |
| `daily_tokens_reserved` | operator-only |
| `daily_token_limit` | operator-only |
| `daily_tokens_remaining` | operator-only |
| `active_concurrency_reservations` | operator-only |
| `last_usage_time` | operator-only |
| `last_request_id` | operator-only |
| `feedback_count` | operator-only |
| `average_rating` | operator-only |
### 8.6 Providers
Operator question:
- Which Macs are connected and what have they earned?
Endpoints:
- `GET /admin/explorer/providers`.
- `GET /admin/explorer/providers/{provider_id}`.
- `GET /admin/explorer/settlements`.
Refresh model:
- Live pool fields every 10 seconds while visible.
- Economics fields every 30 seconds while visible.
- Detail view manual refresh.
- Hidden tabs MUST pause.
Fields:
| Field | Privacy tag |
|---|---|
| `provider_id` | public-redacted |
| `assigned_id` | operator-only |
| `hostname` | operator-only |
| `state` | public-aggregate |
| `tier` | operator-only |
| `model_id` | public-raw |
| `binary_version` | operator-only |
| `slots_free` | public-aggregate |
| `slots_total` | public-aggregate |
| `max_context_tokens` | public-raw |
| `throughput_tps_estimate` | public-aggregate |
| `token_prefix` | operator-only |
| `token_status` | operator-only |
| `token_created_at` | operator-only |
| `token_last_used_at` | operator-only |
| `token_revoked_at` | operator-only |
| `total_provider_credits` | public-aggregate |
| `current_window_credits` | public-aggregate |
| `pending_payout_credits` | public-aggregate |
| `last_payout_ready_row` | operator-only |
| `fault_count` | public-aggregate |
| `quarantined_count` | operator-only |
| `models_served` | public-raw |
| `rate_card_excerpt` | public-raw |
| `attestation_class` | public-aggregate |
### 8.7 Tokens and economics
Operator question:
- How much work happened and how did it turn into credits?
Endpoints:
- `GET /admin/explorer/ledger`.
- `GET /admin/explorer/settlements`.
- `GET /admin/explorer/overview`.
Refresh model:
- Page-load fetch.
- Manual refresh.
- No default automatic refresh for ledger table.
- Optional 60-second settlement refresh while pending rows exist.
- Hidden tabs MUST pause.
Fields:
| Field | Privacy tag |
|---|---|
| `prompt_tokens` | public-aggregate |
| `completion_tokens` | public-aggregate |
| `total_tokens` | public-aggregate |
| `provider_reported_tokens` | public-aggregate |
| `byte_estimated_tokens` | public-aggregate |
| `null_error_rows` | operator-only |
| `gross_credits` | public-aggregate |
| `provider_credits` | public-aggregate |
| `operator_credits` | operator-only |
| `provider_share_bps` | public-raw |
| `operator_share_bps` | operator-only |
| `prompt_rate_per_mtok` | public-raw |
| `completion_rate_per_mtok` | public-raw |
| `global_multiplier_ppm` | public-raw |
| `pending_payout_count` | public-aggregate |
| `pending_payout_credits` | public-aggregate |
| `settled_row_count` | public-aggregate |
| `unsettled_row_count` | public-aggregate |
| `settlement_window` | public-raw |
| `payout_status` | public-aggregate |
| `payout_ready_id` | operator-only |
| `idempotency_key` | operator-only |
### 8.8 Health
Operator question:
- Are the protocol invariants drifting?
Endpoints:
- `GET /admin/explorer/health`.
Refresh model:
- Poll every 30 seconds while visible.
- Manual refresh.
- Hidden tabs MUST pause.
Fields:
| Field | Privacy tag |
|---|---|
| `coordinator_health` | public-raw |
| `gateway_health` | public-raw |
| `public_status` | public-raw |
| `pool_total_providers` | public-aggregate |
| `pool_ready_providers` | public-aggregate |
| `last_reconciliation_status` | public-aggregate |
| `last_reconciliation_delta` | public-aggregate |
| `quarantined_rows` | operator-only |
| `split_delta_rows` | operator-only |
| `fault_rows` | operator-only |
| `capacity_tier` | public-raw |
| `capacity_signals_firing` | public-aggregate |
| `public_api_paused` | public-raw |
| `demo_paused` | public-raw |
| `active_quota_reservations` | operator-only |
| `expired_quota_reservations` | operator-only |
| `active_concurrency_reservations` | operator-only |
| `provider_reconnect_count` | operator-only |
| `coordinator_restart_count` | operator-only |
### 8.9 Feedback and quality
Operator question:
- What did users say, and what happened on the request they rated?
Endpoints:
- `GET /admin/explorer/activity?type=feedback`.
- `GET /admin/explorer/sessions/{request_id}`.
- `GET /admin/explorer/buyers/{account_id}`.
Refresh model:
- Page-load fetch.
- Manual refresh.
- Optional 60-second refresh while visible.
- Hidden tabs MUST pause.
Fields:
| Field | Privacy tag |
|---|---|
| `feedback_event_id` | operator-only |
| `request_id` | public-redacted |
| `account_id` | operator-only |
| `scope` | operator-only |
| `rating` | operator-only |
| `comment` | operator-only |
| `feedback_created_at` | operator-only |
| `request_status` | public-aggregate |
| `model` | public-raw |
| `provider_id` | public-redacted |
| `latency_ms` | public-aggregate |
| `error_code` | public-aggregate |
## 9. Refresh and polling contract
### 9.1 Global rules
All automatic polling MUST pause when the tab is hidden. The UI MUST use `document.visibilityState` or equivalent browser visibility state. The UI MUST show stale timestamps for each panel. The UI MUST stop automatic polling after three consecutive errors for one panel. Manual refresh MUST remain available after polling stops. The UI MUST resume automatic polling only after the tab becomes visible and after the panel's next scheduled interval.
### 9.2 Per-view intervals
| View | Interval while visible | Hidden-tab behavior |
|---|---:|---|
| Overview | 30 seconds | pause |
| Live state | 10 seconds | pause |
| Activity feed | 15 seconds | pause |
| Sessions list | manual by default, optional 30 seconds | pause |
| Session detail | manual only | pause |
| Buyers | manual by default, optional 60 seconds | pause |
| Providers | 10 seconds live, 30 seconds economics | pause |
| Ledger | manual only | pause |
| Settlements | manual by default, optional 60 seconds while pending | pause |
| Health | 30 seconds | pause |
| Feedback and quality | manual by default, optional 60 seconds | pause |
### 9.3 Per-session request cap
A single visible operator browser session MUST NOT generate more than 60 explorer HTTP requests per minute across all views. The default first-screen steady state SHOULD stay at or below 15 requests per minute. The UI MUST coalesce refreshes fired within the same 250 ms frame. The UI MUST NOT poll a detail endpoint that is not currently visible. The UI MUST NOT poll every tab eagerly when the page loads.
### 9.4 Activity cursor contract
Activity cursors MUST be monotonic. Activity cursors MUST be resumable. Activity cursors MUST support polling newer events with `since_cursor`. Activity cursors MUST support paging older events with `cursor`. Activity cursor values MUST be opaque to clients. Activity cursor values MUST be stable enough that a later SSE endpoint can emit the same cursor after every event without redesigning the feed.
### 9.5 Server-side timeout contract
Every endpoint in sections 5-6 MUST enforce a server-side timeout. The timeout begins before the first SQLite query or gateway proxy request. If timeout fires before headers are written, the endpoint MUST return 408. If a gateway proxy times out after local coordinator data succeeds, the coordinator MAY return partial 200 for overview, health, sessions, and activity. The response MUST mark partial data explicitly.
## 10. Auth
### 10.1 Coordinator bearer
Coordinator explorer routes MUST reuse the existing coordinator operator bearer. The
current coordinator config key is `auth.operator_key`.
The current coordinator validation pattern compares:
- `Authorization: Bearer <auth.operator_key>`.
The explorer bearer source is exactly the string in `auth.operator_key`. SPEC-007 v0.2
does not add coordinator config env resolution. If the operator wants env-only secret
management, a future coordinator config-resolver work item MUST add that behavior
outside SPEC-007.
### 10.2 Gateway bearer
The gateway `/admin/explorer/*` routes MUST authenticate the caller with the same
bearer model used by the rest of `phase5-gateway/internal/router/server.go` `/admin/*`
routes: `Authorization: Bearer <coordinator.operator_key>`. No distinct gateway-only
secret is introduced in v0.2.
### 10.3 Browser token handling
The static dashboard MAY ask the operator to paste the coordinator bearer into browser memory. The static dashboard MUST NOT persist the bearer in localStorage. The static dashboard MUST NOT persist the bearer in indexedDB. The static dashboard MUST NOT send the bearer to any origin except the coordinator origin. The static dashboard MUST NOT know any gateway-side secret beyond the shared admin bearer that the coordinator uses server-side.
### 10.4 Outer gate composition
Cloudflare Access MAY sit before the coordinator. Tailscale MAY sit before the coordinator. An IP allowlist MAY be used as defense in depth. The coordinator application bearer remains required in all cases. Outer gates MUST NOT introduce multi-operator RBAC in v1. Outer gates MUST NOT change endpoint schemas.
### 10.5 Threat model exclusions
SPEC-007 v1 does not defend against:
- Multi-tenant dashboard authorization.
- Public internet abuse of a public explorer.
- Support-staff roles.
- Provider self-service administration.
- Public redaction guarantees.
- Buyer impersonation workflows.
- Key theft mitigation beyond admin route isolation and bearer hygiene.
- Compromised operator browser.
- Compromised coordinator host.
- Compromised gateway host.
## 11. Static asset surface
### 11.1 Repo location
Explorer static assets MUST live under:
- `phase4-coordinator/internal/explorer/static/`.
The coordinator HTTP handlers SHOULD live under:
- `phase4-coordinator/internal/explorer/`.
The implementation MAY choose a nearby package path if it keeps the same ownership boundary and imports no frontend framework.
### 11.2 Embedding
The coordinator MUST embed assets with Go `embed.FS`. The pattern SHOULD follow the gateway `embed.FS` usage in `phase5-gateway/internal/router/pages.go`.
The coordinator MUST serve:
- `/admin/explorer/`.
- `/admin/explorer/index.html`.
- `/admin/explorer/assets/*.css`.
- `/admin/explorer/assets/*.js`.
The coordinator MUST NOT serve source maps in production unless explicitly enabled by config.
### 11.3 Cache headers
`/admin/explorer/` and `/admin/explorer/index.html` MUST return:
- `Cache-Control: no-store`.
Fingerprintable assets MAY return:
- `Cache-Control: private, max-age=300`.
Because the explorer is admin-only, assets MUST NOT use public shared-cache semantics.
### 11.4 Security headers
Static explorer responses MUST set:
- `Content-Security-Policy`.
- `X-Content-Type-Options: nosniff`.
- `Referrer-Policy: no-referrer`.
- `Frame-Options` or CSP `frame-ancestors 'none'`.
The CSP MUST allow:
- `default-src 'none'`.
- `connect-src 'self'`.
- `style-src 'self' 'unsafe-inline'` only if inline CSS is used.
- `script-src 'self'` if JS is served as a separate asset.
The CSP MUST NOT allow third-party script origins. The CSP MUST NOT allow third-party connect origins.
### 11.5 Frontend technology
The bundle MUST be plain static HTML/CSS/JS. The bundle MUST NOT use React. The bundle MUST NOT use Next.js. The bundle MUST NOT use a charting dependency. The bundle MUST NOT fetch external fonts. The bundle MUST NOT make external network calls. The bundle MUST use dense operational tables, status strips, filters, detail drawers or detail panels, and manual refresh controls.
### 11.6 Load budget
A fresh operator session SHOULD load the static bundle in under 200 ms over a typical home connection to the coordinator origin. The compressed initial HTML/CSS/JS payload SHOULD stay under 150 KB. The bundle MUST lazy-load no external code.
## 12. Performance and operational budget
### 12.1 Overall posture
The explorer is designed for one operator. The explorer MUST add negligible load compared to inference traffic. The explorer MUST bound every query over growing SQLite tables. The explorer MUST avoid `SELECT *`. The explorer MUST avoid whole-history aggregates on page load. The explorer MUST avoid materialized rollups in v1.
### 12.2 Endpoint budgets
| Endpoint | Local budget | Gateway budget | Default limit | Max window |
|---|---:|---:|---:|---:|
| `/admin/explorer/overview` | 1500 ms | 2000 ms | n/a | 7d |
| `/admin/explorer/sessions` | 1500 ms | 2000 ms | 50 | 7d |
| `/admin/explorer/sessions/{request_id}` | 1500 ms | 2000 ms | n/a | n/a |
| `/admin/explorer/providers` | 1500 ms | n/a | 50 | 7d recent |
| `/admin/explorer/providers/{provider_id}` | 1500 ms | n/a | 50 | 7d recent |
| `/admin/explorer/buyers` | n/a | 2500 ms | 50 | 31d |
| `/admin/explorer/buyers/{account_id}` | n/a | 2500 ms | 50 | 31d |
| `/admin/explorer/ledger` | 1500 ms | n/a | 100 | 31d |
| `/admin/explorer/settlements` | 1500 ms | n/a | 50 | 180d |
| `/admin/explorer/health` | 1500 ms | 2000 ms | n/a | 7d |
| `/admin/explorer/activity` | 1500 ms | 2000 ms | 50 | 7d |
### 12.3 Existing usable indexes
The implementation SHOULD start with existing indexes:
- `idx_request_log_ts_utc`.
- `idx_request_log_request_id_id`.
- `idx_lrc_provider_ts`.
- `idx_lrc_unsettled`.
- `idx_lrc_request`.
- `idx_lrc_quarantine`.
- `idx_lrc_fault`.
- `idx_loc_request`.
- `idx_loc_provider_ts`.
- `idx_loc_ts`.
- `idx_lpr_provider_status`.
- `idx_lpr_status`.
- `idx_lrr_type_started`.
- `idx_lrr_range`.
- `idx_lcs_effective_at`.
- `idx_lpis_request`.
- `idx_lpis_provider`.
- `idx_token_hash`.
- `idx_account_identities_account`.
- `idx_api_keys_hash`.
- `idx_api_keys_account`.
- `idx_api_key_events_key`.
- `idx_usage_account_date`.
- `idx_usage_created_at`.
- `idx_quota_active_account_date`.
- `idx_quota_expires_at`.
- `idx_concurrency_active_account`.
- `idx_feedback_request`.
- `idx_feedback_created_at`.
- `idx_audit_request`.
- `idx_audit_created_at`.
- `idx_capacity_signal_created`.
### 12.4 Candidate indexes, not added unless measured
Per D12, these indexes are candidates only. They MUST NOT be added unless implementation tests or measured slow queries require them.
Candidate indexes:
- `idx_request_log_ts_id` on `request_log(ts_utc, id)`.
- `idx_lrc_ts_id` on `ledger_request_credits(ts_utc, id)`.
- `idx_lrc_model_ts_id` on `ledger_request_credits(model, ts_utc, id)`.
- `idx_lrc_provider_ts_id` on `ledger_request_credits(provider_id, ts_utc, id)`.
- `idx_lpr_status_window_id` on `ledger_payout_ready(status, window_end_utc, id)`.
- `idx_api_key_events_created_id` on `api_key_events(created_at, event_id)`.
- `idx_usage_created_account` on `usage_events(created_at, account_id)`.
- `idx_quota_request` on `quota_reservations(request_id)`.
- `idx_concurrency_request` on `concurrency_reservations(request_id)`.
- `idx_feedback_account_created` on `feedback_events(account_id, created_at)`.
- `idx_capacity_signal_created_id` on `capacity_signal_events(created_at, event_id)`.
### 12.5 Queries requiring care
Top buyers by tokens over a 31-day window MAY become slow. Buyer last-active directory MAY become slow if computed by `MAX(created_at) GROUP BY account_id`. Merged activity feed MAY become slow if any source lacks timestamp ordering. Top providers by credits over a 31-day window MAY become slow. Gateway exact HTTP error rate is not available from current storage. Provider reconnect count is not available from current storage. Coordinator restart count is not available from current storage.
## 13. Configuration
### 13.1 Coordinator YAML additions
`coordinator.yaml` MUST add an `explorer` block.
```yaml
explorer:
  enabled: false
  activity_default_window_hours: 24
  activity_max_window_days: 7
  activity_poll_seconds: 15
  bind_path: /admin/explorer/
  buyers_default_window_hours: 24
  buyers_max_window_days: 31
  buyers_poll_seconds: 60
  default_limit: 50
  gateway_base_url: ""
  gateway_timeout_ms: 2000
  health_poll_seconds: 30
  ledger_default_window_hours: 24
  ledger_max_window_days: 31
  live_state_poll_seconds: 10
  max_limit: 200
  max_requests_per_minute: 60
  overview_poll_seconds: 30
  poll_min_interval_seconds: 10
  providers_economics_poll_seconds: 30
  query_timeout_ms: 1500
  sessions_default_window_hours: 24
  sessions_max_window_days: 7
  settlements_default_window_hours: 744
  settlements_max_window_days: 180
  settlements_poll_seconds: 60
```
### 13.2 `explorer.enabled`
Type:
- boolean.
Default:
- `false`.
Behavior:
- `false` MUST disable static assets and API routes.
- `true` MUST enable static assets and API routes when auth config is valid.
Boundary behavior:
- Missing value MUST behave as `false`.
### 13.3 `explorer.bind_path`
Type:
- string.
Default:
- `/admin/explorer/`.
Behavior:
- Value MUST begin with `/admin/explorer/`.
- Value MUST end with `/`.
- Value MUST NOT be `/`.
Boundary behavior:
- Invalid value MUST fail coordinator startup when `explorer.enabled=true`.
### 13.4 Bearer source
The explorer bearer source is `auth.operator_key` verbatim. D3 already specifies bearer
reuse. An explorer-specific env resolver would either require new coordinator
config-loader plumbing outside v0.2 scope or silently equal `auth.operator_key`, making
the knob non-functional. If the operator wants env-only secret management, a separate
future coordinator config-resolver work item will add it.
### 13.5 `explorer.gateway_base_url`
Type:
- string URL.
Default:
- empty string.
Behavior:
- Empty string disables gateway panels and proxy endpoints.
- Non-empty string MUST be an absolute `http` or `https` URL.
Boundary behavior:
- Invalid URL MUST fail startup when `explorer.enabled=true`.
### 13.6 Gateway admin bearer
Coordinator proxy calls to gateway explorer endpoints MUST use
`Authorization: Bearer <coordinator.operator_key>`. SPEC-007 v0.2 adds no gateway-only
explorer secret and no coordinator config key for such a secret.
### 13.7 `explorer.query_timeout_ms`
Type:
- integer milliseconds.
Default:
- `1500`.
Behavior:
- Applies to local coordinator SQLite and live state reads.
Boundary behavior:
- Minimum accepted value is 100.
- Maximum accepted value is 5000.
- Values outside range MUST fail startup.
### 13.8 `explorer.gateway_timeout_ms`
Type:
- integer milliseconds.
Default:
- `2000`.
Behavior:
- Applies to coordinator-to-gateway proxy calls.
Boundary behavior:
- Minimum accepted value is 100.
- Maximum accepted value is 5000.
- Values outside range MUST fail startup.
### 13.9 Poll interval knobs
Type:
- integer seconds.
Keys:
- `explorer.poll_min_interval_seconds`.
- `explorer.overview_poll_seconds`.
- `explorer.live_state_poll_seconds`.
- `explorer.activity_poll_seconds`.
- `explorer.health_poll_seconds`.
- `explorer.buyers_poll_seconds`.
- `explorer.providers_economics_poll_seconds`.
- `explorer.settlements_poll_seconds`.
Behavior:
- Each interval MUST be at least `poll_min_interval_seconds`.
- `poll_min_interval_seconds` defaults to 10.
- `activity_poll_seconds` defaults to 15.
Boundary behavior:
- Any value below 5 MUST fail startup.
- Any value above 3600 MUST fail startup.
### 13.10 Limit and window knobs
Type:
- integers.
Keys:
- `explorer.max_requests_per_minute`.
- `explorer.default_limit`.
- `explorer.max_limit`.
- `explorer.activity_default_window_hours`.
- `explorer.activity_max_window_days`.
- `explorer.buyers_default_window_hours`.
- `explorer.buyers_max_window_days`.
- `explorer.ledger_default_window_hours`.
- `explorer.ledger_max_window_days`.
- `explorer.sessions_default_window_hours`.
- `explorer.sessions_max_window_days`.
- `explorer.settlements_default_window_hours`.
- `explorer.settlements_max_window_days`.
Defaults:
- `max_requests_per_minute`: 60.
- `default_limit`: 50.
- `max_limit`: 200.
- `activity_default_window_hours`: 24.
- `activity_max_window_days`: 7.
- `buyers_default_window_hours`: 24.
- `buyers_max_window_days`: 31.
- `ledger_default_window_hours`: 24.
- `ledger_max_window_days`: 31.
- `sessions_default_window_hours`: 24.
- `sessions_max_window_days`: 7.
- `settlements_default_window_hours`: 744.
- `settlements_max_window_days`: 180.
Boundary behavior:
- `max_requests_per_minute` MUST be between 10 and 120.
- `default_limit` MUST be between 1 and `max_limit`.
- `max_limit` MUST be between 1 and 200.
- Non-settlement default-window hour knobs MUST be between 1 and the matching
  endpoint max-window-days knob multiplied by 24.
- Settlement default-window hours MUST be between 1 and
  `settlements_max_window_days * 24`.
- `activity_max_window_days` MUST be between 1 and 31.
- `buyers_max_window_days` MUST be between 1 and 31.
- `ledger_max_window_days` MUST be between 1 and 31.
- `sessions_max_window_days` MUST be between 1 and 31.
- `settlements_max_window_days` MUST be between 31 and 365.
### 13.11 Gateway configuration additions
Gateway config MUST add:
```yaml
explorer:
  enabled: false
  activity_default_window_hours: 24
  activity_max_window_days: 7
  buyers_default_window_hours: 24
  buyers_max_window_days: 31
  default_limit: 50
  max_limit: 200
  query_timeout_ms: 1500
```
Gateway `explorer.enabled=false` MUST disable gateway `/admin/explorer/*`. Gateway
explorer routes MUST reuse the existing gateway admin bearer model. Gateway
`explorer.query_timeout_ms` MUST follow the same 100-5000 ms bounds. Gateway
`explorer.max_limit` MUST NOT exceed 200. Gateway activity and buyer window knobs MUST
follow the same bounds as their coordinator counterparts.
## 14. Failure modes
### 14.1 Status code map
Coordinator explorer endpoints MUST use 200 for complete success, 200 with `partial=true` for allowed partial panel degradation, 400 for invalid query parameters, 401 for missing or invalid coordinator operator bearer, 404 for unknown detail resources, 405 for non-GET methods, 408 for local query timeout, 502 for invalid gateway response or gateway auth misconfiguration, 503 for gateway unreachable on pure proxy endpoints, and 500 for unexpected coordinator errors.
Gateway explorer endpoints MUST use 200 for success, 400 for invalid query parameters,
401 for missing or invalid operator bearer, 404 for unknown detail resources, 405 for
non-GET methods, 408 for gateway query timeout, and 500 for unexpected gateway errors.
### 14.2 Gateway unreachable
If gateway is unreachable on `/admin/explorer/buyers`, coordinator MUST return 503. If gateway is unreachable on overview, sessions detail, health, or activity, coordinator MUST render local data when possible. The UI MUST show a single visible gateway-unavailable error strip for affected buyer panels. The UI MUST NOT duplicate the same gateway error in every row.
### 14.3 Ledger query timeout
If a ledger query times out before response headers, the endpoint MUST return 408 `query_timeout`. The UI MUST show a stale or unavailable state for only that panel. The UI MUST NOT discard successful panels.
### 14.4 Request-log query timeout
If a `request_log` query times out, sessions and activity endpoints MUST return 408 unless partial gateway-only data is explicitly requested by a later SPEC. V1 coordinator activity depends on local request-log reads.
### 14.5 Bearer missing or invalid
Missing coordinator bearer MUST return 401 `invalid_operator_token`. Invalid coordinator
bearer MUST return 401 `invalid_operator_token`. Missing gateway operator bearer MUST
return 401 `invalid_operator_token`. Invalid gateway operator bearer MUST return 401
`invalid_operator_token`. The static bundle MUST treat 401 as an auth failure and stop
automatic polling.
### 14.6 Outer-gate rejection
If Cloudflare Access or Tailscale rejects the operator before coordinator, the operator never reaches explorer application code. The explorer has no JSON contract for outer-gate rejection.
### 14.7 Partial data
Partial data MUST be explicit.
Partial data responses MUST include:
- `partial: true`.
- `warnings[]`.
- a source-specific error object where practical.
Partial data MUST NOT silently omit a failed source.
### 14.7.1 Gateway-section identity unavailable (v0.3, §5.6)
The session-detail endpoint MAY return HTTP 200 with `partial: false` AND a gateway section of shape `{"error": {"code": "gateway_identity_unavailable"}}`. This is NOT a partial-data state and NOT a gateway failure. It is the documented outcome when the resolved coordinator `request_log` row lacks `external_request_id`, `account_id`, or both — a legacy-identity-limit on pre-v1.5.0-coordinator rows or v1.5.0 rows written from a pre-v0.9.1 gateway. Coordinator-side detail (attempts, ledger rows, identity snapshots) is fully populated. Retrying does NOT make the gateway data appear; the operator's path is to query gateway storage out-of-band by `external_request_id` (or wait for the v0.4 path-segment-overload that will surface this in the UI). UI rendering MUST distinguish this state from `gateway_unavailable` so it does not appear as a retryable failure.
### 14.8 Cancellation paths
If the operator navigates away, the browser SHOULD abort in-flight fetches. The coordinator MUST propagate request context cancellation to SQLite queries and gateway proxy calls. The gateway MUST propagate request context cancellation to SQLite queries. Cancelled requests MUST NOT mutate state.
## 15. Acceptance criteria
### AC-1: coordinator bearer required
Verification:
- Start coordinator with `explorer.enabled=true`.
- Send `GET /admin/explorer/overview` without `Authorization`.
- Assert HTTP 401.
- Assert JSON error code is `invalid_operator_token`.
### AC-2: bad coordinator bearer rejected
Verification:
- Send `GET /admin/explorer/overview` with `Authorization: Bearer wrong`.
- Assert HTTP 401.
- Assert no explorer data fields are returned.
### AC-3: gateway explorer routes use shared admin bearer
Verification:
- Start gateway with explorer enabled and `coordinator.operator_key` configured.
- Call gateway `GET /admin/explorer/buyers` with `Authorization: Bearer bogus`.
- Assert HTTP 401.
- Call gateway `GET /admin/explorer/buyers` with
  `Authorization: Bearer <coordinator.operator_key>`.
- Assert HTTP 200.
- Start coordinator with `explorer.enabled=true`, `gateway_base_url` set, and no
  explorer-specific gateway admin secret configured.
- Assert startup succeeds.
### AC-4: gateway endpoint rejects non-admin bearers
Verification:
- Start gateway with explorer enabled.
- Send `GET /admin/explorer/buyers` with a buyer API key or demo token.
- Assert HTTP 401.
- Assert error code is `invalid_operator_token`.
### AC-5: overview performance
Verification:
- Seed coordinator SQLite with at least 100 `request_log` rows.
- Seed ledger tables with at least 100 request-credit rows.
- Seed one reconciliation run.
- Start gateway with at least 10 accounts.
- Request `GET /admin/explorer/overview`.
- Assert HTTP 200.
- Assert wall-clock handler duration is under 500 ms on the local test runner.
### AC-6: sessions cursor stable across inserts
Verification:
- Seed 60 `request_log` rows in one window.
- Request `GET /admin/explorer/sessions?limit=25`.
- Save `next_cursor`.
- Insert a newer `request_log` row.
- Request the next page with saved cursor.
- Assert no duplicate `request_log_id`.
- Assert no seeded row older than the first page boundary is skipped.
### AC-7: session detail joins request, ledger, and gateway under the composite key
Verification (v0.3 — path-segment is coordinator-internal `request_id`):
- Seed one row in coordinator `request_log` with internal
  `request_id = R_int`, `external_request_id = X`, `account_id = "acct_A"`.
- Seed matching `ledger_request_credits` keyed by `R_int`.
- Seed matching `ledger_operator_credits` keyed by `R_int`.
- Seed gateway `usage_events` with `(account_id, request_id) =
  ("acct_A", X)`. Coordinator-internal joins use `R_int`; the
  gateway proxy MUST forward `external_request_id` (`X`) +
  `?account_id=acct_A` so the gateway-side composite-PK lookup
  returns the matching account's row.
- Request `GET /admin/explorer/sessions/R_int`.
- Assert response contains coordinator attempt fields.
- Assert response contains ledger credit fields.
- Assert response contains gateway usage fields, scoped to
  `account_id = "acct_A"`.
- **Gateway-proxy URL sub-case (v0.3 §5.6 security contract):**
  inspect the outbound gateway HTTP request and assert the path
  is `/admin/explorer/sessions/X?account_id=acct_A` — NOT
  `/admin/explorer/sessions/R_int`. Forwarding the internal id
  risks the gateway interpreting it as an external_request_id
  and returning unrelated single-account data.
- **Cross-account isolation sub-case (v0.3 gateway-proxy
  guarantee):**
  - Additionally seed a second coordinator `request_log` row with
    internal `request_id = R_int2`, `external_request_id = X`,
    `account_id = "acct_B"`, plus a matching gateway
    `usage_events` row with `(account_id, request_id) =
    ("acct_B", X)`.
  - Request `GET /admin/explorer/sessions/R_int2`.
  - Assert the gateway-proxy URL is
    `/admin/explorer/sessions/X?account_id=acct_B` and the
    response contains only `acct_B`'s gateway data; `acct_A`'s
    rows MUST NOT appear.
- **Legacy NULL-account "no proxy" sub-case (both-or-nothing):**
  - Seed a coordinator `request_log` row with NULL `account_id`
    + non-empty `external_request_id` (pre-v0.9.1 gateway shape).
  - Request the session detail; assert the coordinator-side
    detail (attempts/ledger/snapshots) is returned with
    `gateway: {"error": {"code": "gateway_identity_unavailable"}}`.
    The coordinator MUST NOT proxy to the gateway because
    `account_id` is missing — the both-or-nothing contract
    treats this as an expected legacy-identity-limit, not a
    gateway failure.
  - Repeat for a row with non-NULL `account_id` but empty
    `external_request_id` (direct legacy buyer call with no
    inbound X-Request-ID): assert the same
    `gateway_identity_unavailable` outcome.

**Deferred to v0.4 (not required by AC-7 in v0.3):**
- Operator pasting `external_request_id` directly into the path
  segment and 409 `ambiguous_request_id` on cross-account
  collision when no `?account_id=` is supplied. The 409 contract
  for the gateway-side endpoint (§6.4) is normative in v0.3; the
  coordinator-side path-segment overload that would expose it is
  v0.4 work.
### AC-8: provider list reflects live pool
Verification:
- Start coordinator with two live providers in registry.
- Request `GET /admin/explorer/providers`.
- Assert both provider IDs appear.
- Change one provider state to `degraded`.
- Request again.
- Assert state reflects current registry state without requiring SQLite writes.
### AC-9: provider token hash never returned
Verification:
- Seed `provider_tokens` with `token_hash` and `token_prefix`.
- Request providers list and provider detail.
- Assert `token_prefix` is present.
- Assert `token_hash` string is absent from response body.
### AC-10: ledger bounded window enforced
Verification:
- Request `GET /admin/explorer/ledger` with a 32-day window.
- Assert HTTP 400.
- Request a 31-day window.
- Assert HTTP 200.
### AC-11: ledger view shows seeded entries
Verification:
- Seed three `ledger_request_credits` rows with matching operator rows.
- Request `GET /admin/explorer/ledger`.
- Assert all seeded `request_id` values appear.
- Assert `gross_credits`, `provider_credits`, and `operator_credits` match seeded values.
### AC-12: settlements visible read-only
Verification:
- Seed one `ledger_payout_ready` row with status `ready`.
- Request `GET /admin/explorer/settlements`.
- Assert row appears.
- Attempt `POST /admin/explorer/settlements`.
- Assert HTTP 405 or 404.
- Assert the seeded row remains `ready`.
### AC-13: consumed and voided settlement rows immutable through explorer
Verification:
- Seed one `consumed` row and one `voided` row.
- Request settlements list with `status=consumed`.
- Assert consumed row appears.
- Request settlements list with `status=voided`.
- Assert voided row appears.
- Attempt `PATCH` or `DELETE` under `/admin/explorer/settlements`.
- Assert HTTP 405 or 404.
- Assert database rows are unchanged.
### AC-14: health exposes reconciliation delta
Verification:
- Seed `ledger_reconciliation_runs` with latest `reconciliation_delta_credits=123`.
- Request `GET /admin/explorer/health`.
- Assert `last_reconciliation_delta` equals 123.
### AC-15: activity cursor monotonic
Verification:
- Seed coordinator and gateway events with known timestamps and IDs.
- Request `GET /admin/explorer/activity?limit=10`.
- Assert event order is deterministic.
- Save `next_cursor`.
- Request next page.
- Assert the second page starts strictly older than the first page boundary.
### AC-16: activity replay from cursor contiguous
Verification:
- Seed 40 activity-source rows.
- Traverse all pages with `limit=7`.
- Collect `source` plus `source_id`.
- Assert exactly 40 unique collected events.
- Assert no duplicates.
- Assert no gaps relative to the seeded set.
### AC-17: since_cursor returns newer events
Verification:
- Request activity and save `latest_cursor`.
- Insert two newer source events.
- Request `GET /admin/explorer/activity?since_cursor=<saved>`.
- Assert exactly the two newer events return.
- Assert returned `latest_cursor` advances.
### AC-18: polling pauses on hidden tab
Verification:
- Open explorer in a browser test harness.
- Mock `document.visibilityState` to `visible`.
- Assert scheduled fetches occur.
- Mock `document.visibilityState` to `hidden`.
- Wait two polling intervals.
- Assert no automatic fetch occurs.
- Restore `visible`.
- Assert polling resumes on the next scheduled interval.
### AC-19: per-session request cap enforced by client
Verification:
- Enable every auto-refreshing view in one browser session.
- Run for one minute while visible.
- Count explorer HTTP requests in the test server.
- Assert count is <= 60.
### AC-20: gateway-unreachable degradation
Verification:
- Start coordinator with `gateway_base_url` pointing to an unreachable port.
- Request `/admin/explorer/overview`.
- Assert HTTP 200 with local coordinator fields.
- Assert gateway fields indicate unavailable or unknown.
- Open UI.
- Assert one visible gateway-unavailable strip.
- Assert buyer panels do not render misleading zero data.
### AC-21: buyer directory path proxy
Verification:
- Start gateway with one account and valid `coordinator.operator_key`.
- Start coordinator with matching proxy config.
- Request coordinator `GET /admin/explorer/buyers`.
- Assert account appears.
- Assert browser-visible response came from coordinator origin.
- Assert gateway received the same path and query string.
### AC-22: buyer API key hash hidden
Verification:
- Seed gateway `api_keys.key_hash` and `key_hash_prefix`.
- Request coordinator `GET /admin/explorer/buyers/{account_id}`.
- Assert prefix appears.
- Assert full hash bytes or hex string do not appear.
### AC-23: no in-flight endpoint
Verification:
- Request `GET /admin/explorer/in-flight`.
- Assert HTTP 404.
- Search registered coordinator routes in tests.
- Assert no `/admin/explorer/in-flight` route exists.
### AC-24: no SSE endpoint
Verification:
- Request `GET /admin/explorer/stream`.
- Assert HTTP 404.
- Search registered coordinator routes in tests.
- Assert no SSE handler exists under `/admin/explorer/*`.
### AC-25: D14 two-minute traversal
Verification:
- Seed one provider.
- Seed one buyer.
- Seed one request/session.
- Seed one ledger entry.
- Seed one settlement row.
- Seed one health/reconciliation row.
- Open the rendered explorer UI.
- Start a timer.
- Navigate from overview to the seeded session, seeded buyer, seeded provider,
  seeded ledger entry, seeded settlement row, and health view.
- Assert all target records are visible.
- Assert traversal completes in under two minutes without direct URL entry.
### AC-26: static bundle has no third-party JS
Verification:
- Build coordinator.
- Extract or inspect embedded explorer assets.
- Assert no script references external origins.
- Assert no package imports React, Next.js, charting libraries, or external fonts.
### AC-27: endpoint methods are read-only
Verification:
- Enumerate every route registered under `/admin/explorer/*`.
- Assert every API route accepts `GET` only.
- Send `POST`, `PATCH`, and `DELETE` to each route.
- Assert each returns 405 or 404.
### AC-28: no explorer writes
Verification:
- Run tests with SQLite update hooks or before/after table checks.
- Call every explorer endpoint.
- Assert row counts and row hashes are unchanged for coordinator and gateway
  tables.
### AC-29: email filter semantics
Verification:
- Seed three accounts with emails `a@x`, `ab@x`, and `aB@x`.
- Request `GET /admin/explorer/buyers?email=ab@x`.
- Assert exactly one row returns, for the second account.
- Request `GET /admin/explorer/buyers?email_prefix=a`.
- Assert all three accounts return.
- Request `GET /admin/explorer/buyers?email_prefix=aB`.
- Assert only the third account returns after case-folding.
- Request with both `email` and `email_prefix` set.
- Assert HTTP 400.
## 16. Audit categories
SPEC-007 inherits applicable SPEC-005 audit categories for:
- ledger row integrity.
- settlement row integrity.
- reconciliation visibility.
- provider/operator split visibility.
- request-log read-only use.
- admin bearer enforcement.
Explorer-specific audit categories:
- Read-only invariant: no endpoint mutates state.
- Bearer enforcement on every route.
- Coordinator and gateway explorer routes share the existing admin bearer model.
- Bounded-window enforcement on every list endpoint.
- Limit enforcement on every list endpoint.
- Cursor monotonicity.
- Cursor replay contiguity.
- Gateway proxy path/query preservation.
- Gateway buyer ownership preserved.
- No buyer-table copy into coordinator SQLite.
- Ledger row immutability through explorer.
- `ledger_payout_ready` immutability through explorer.
- Provider token hash secrecy.
- API key hash secrecy.
- Hidden-tab polling pause.
- Per-session request cap.
- Partial-data warning correctness.
- Static asset CSP and no third-party JS.
- No SSE route in v1.
- No in-flight route in v1.
- No public redaction endpoints in v1.
- Forward-compatibility: every section 8 field has a privacy tag.
## 17. Out of scope (explicit)
SPEC-007 v1 does not cover a public explorer. SPEC-007 v1 does not cover an
antfeed.org-style public surface. SPEC-007 v1 does not cover public redaction endpoints.
SPEC-007 v1 does not cover public schemas. SPEC-007 v1 does not cover public rate
limits. SPEC-007 v1 does not cover mutating settlement claim. SPEC-007 v1 does not
cover settlement consume. SPEC-007 v1 does not cover settlement void. SPEC-007 v1 does
not cover payment execution. SPEC-007 v1 does not cover provider admission mutation.
SPEC-007 v1 does not cover provider promotion. SPEC-007 v1 does not cover provider
rejection. SPEC-007 v1 does not cover provider blacklist mutation. SPEC-007 v1 does not
cover key issuance. SPEC-007 v1 does not cover key revocation. SPEC-007 v1 does not
cover gateway kill-switch mutation. SPEC-007 v1 does not cover capacity-signal mutation.
SPEC-007 v1 does not cover in-flight request visibility. SPEC-007 v1 does not cover a
live in-flight endpoint. SPEC-007 v1 does not cover a durable provider session table.
SPEC-007 v1 does not cover a durable provider event table. SPEC-007 v1 does not cover a
provider reconnect counter table. SPEC-007 v1 does not cover coordinator restart
history. SPEC-007 v1 does not cover SSE. SPEC-007 v1 does not cover WebSocket activity
transport. SPEC-007 v1 does not cover analytics-grade charts. SPEC-007 v1 does not
cover BI rollups. SPEC-007 v1 does not cover long-horizon dashboards. SPEC-007 v1 does
not cover materialized analytics caches. SPEC-007 v1 does not cover an analytics
warehouse. SPEC-007 v1 does not cover per-buyer impersonation tools. SPEC-007 v1 does
not cover buyer-side admin actions. SPEC-007 v1 does not cover multi-operator RBAC.
SPEC-007 v1 does not cover OAuth login for the explorer. SPEC-007 v1 does not cover rate
limiting beyond the per-session polling cap and bounded query timeouts. SPEC-007 v1 does
not cover Vercel-hosted UI. SPEC-007 v1 does not cover Next.js. SPEC-007 v1 does not
cover any SPA framework. SPEC-007 v1 does not cover multi-region deployment. SPEC-007 v1
does not cover multi-coordinator deployment. SPEC-007 v1 does not cover email alerts.
SPEC-007 v1 does not cover Slack alerts. SPEC-007 v1 does not cover PagerDuty alerts.
SPEC-007 v1 does not cover USDC balance tracking because current repo storage contains
internal credits and nullable future payout fields, not a USDC balance table.
- Coordinator `env:` value resolution for `auth.operator_key`. SPEC-007 v0.2 does not
  require it; a future infra ticket will add it to
  `phase4-coordinator/internal/config/config.go` mirroring the existing gateway pattern.
- Migrating gateway `/admin/*` routes to a gateway-side bearer distinct from the
  coordinator operator key. A future spec MAY introduce that separation across all
  gateway admin endpoints; SPEC-007 v0.2 reuses the existing shared-key model.
## 18. Operator questions (open, post-locked)
### OQ-4: Future reconnect and restart history
D6 defers durable provider event storage. Health fields `provider_reconnect_count` and `coordinator_restart_count` are therefore `null` in v1. Should a later observability SPEC add a minimal append-only event table, or should reconnect/restart history stay log-derived?
