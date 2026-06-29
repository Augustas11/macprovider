# SPEC-007 Design Exploration

## 1. Operator's framing

Mac Provider now has protocol motion that the operator cannot see as a protocol.

The operator's problem statement is:

> We have built the macprovider protocol - but I as operator don't have
> any visibility into what's happening inside the protocol: buyers,
> sessions, tokens, providers. I want a protocol explorer like
> antfeed.org, but internal-only for now.

This is not a request for a public explorer yet.

It is a request for an internal operations cockpit.

The viewer is one operator.

The surface is read-only.

The dashboard should answer:

- Are buyers actively using the network?
- Which sessions or request attempts are happening?
- Which providers are connected, routable, degraded, or gone?
- Which API keys and accounts are active?
- Which models are receiving traffic?
- Which ledger rows are accruing credits?
- Which settlement-ready rows exist?
- Whether reconciliation is clean or drifting.
- Whether the gateway and coordinator disagree about health.

SPEC-005 changed the urgency.

Before SPEC-005, the coordinator had provider pool state and request logs.

After SPEC-005, the coordinator also has provider-credit ledger rows, operator-credit rows, settlement-ready rows,
reconciliation runs, quarantine reasons, and provider earnings endpoints.

Decision log Entry 39 in `beta/DECISION_CRITERIA.md` records that the SPEC-005 billing implementation shipped with
ledger tables, settlement, reconciliation, payout claim hardening, and all SPEC-005 endpoints.

That makes visibility operational, not cosmetic.

The operator now needs to inspect real economic state and real request history at a glance.

"What's happening" decomposes into six visibility classes.

First, live routing state: providers, slots, models, health, pool state, and public gateway status.

Second, request activity: recent attempts, latency, status, retry, errors, usage, provider, and ledger result.

Third, buyer/account activity: accounts, API keys, quotas, reservations, usage, feedback, and last active time.

Fourth, provider economics: credits, settlement windows, pending payouts, faults, quarantines, and rate-card context.

Fifth, reconciliation: buyer-equivalent credits, provider gross credits, delta, missing rows, orphan rows, and SPEC-007
claim audit rows.

Sixth, operational drift: provider reconnects, stale heartbeats, warm-up failures, gateway capacity tiers, public API
pause, demo pause, and coordinator/gateway reachability.

The explorer should not become a control plane.

Existing mutating surfaces stay where they are:

- Provider admission stays on coordinator `/admin/*`.
- Gateway kill switches stay on gateway `/admin/*`.
- Provider token issuance stays in the coordinator CLI.
- Payout consumption remains a later SPEC-007 action.

This document is a design exploration.

It maps the decision space.

It ends with locked-decision questions.

It is not a normative SPEC-007 v0.1.

## 2. What the coordinator already knows

The key architectural boundary is already established.

`specs/SPEC-002-coordinator.md` keeps the coordinator focused on routing, provider pool state, request logging, and
billing state.

`specs/SPEC-006-buyer-api.md` and `phase5-gateway/README.md` put buyer identity, API keys, quota, public status shaping,
feedback, capacity controls, and kill switches in `phase5-gateway/`.

The explorer may read both surfaces.

It must not create a parallel data store.

### 2.1 Coordinator endpoint inventory

Evidence:

- `phase4-coordinator/internal/ws/server.go` - `phase4-coordinator/internal/ws/admin_endpoints.go` -
`phase4-coordinator/internal/billing/endpoints.go` - `phase4-coordinator/cmd/coordinator/main.go` -
`specs/SPEC-002-coordinator.md` - `specs/SPEC-005-billing.md`

Coordinator buyer HTTP endpoints:

- `GET /v1/models` returns OpenAI-style model list plus Mac Provider
  extensions such as provider count, max context tokens, total slots, and optional Tier-2 metadata.
- `POST /v1/chat/completions` routes non-streaming and streaming chat
  requests to providers, logs attempts, and writes SPEC-005 ledger rows.
- `GET /healthz` reports coordinator health.

Coordinator operator/provider endpoints:

- `GET /poolz` returns live provider pool state.  - `POST /admin/blacklist` drains or blacklists a provider.  - `GET
/admin/provisional` returns provisional admission records.  - `POST /admin/promote/{provider_id}` promotes a provisional
provider at
  runtime.
- `POST /admin/reject/{provider_id}` rejects a provider and drains the
  active session when present.

SPEC-005 billing endpoints:

- `GET /admin/ledger/summary` returns total gross credits, total provider
  credits, total operator credits, current-window provider credits, pending payout count, pending payout credits,
  quarantined count, fault count, and last reconciliation delta.
- `GET /admin/ledger/providers` returns a paginated provider economics
  directory with total credits, current-window credits, pending payout credits, last activity, fault count, quarantine
  count, and attestation class.
- `GET /admin/ledger/reconcile?from=YYYY-MM-DD&to=YYYY-MM-DD` computes a
  bounded admin reconciliation window and records a reconciliation run.
- `GET /providers/{provider_id}/earnings` returns provider-authenticated
  earnings when provider tokens are enabled.

Internal coordinator endpoint:

- `DELETE /internal/sticky?account_id=...` is called by the gateway to
  purge account-scoped sticky affinity.

The explorer can add read-only routes under `/admin/explorer/*`.

It should not change existing admin semantics.

### 2.2 Coordinator live provider state

Evidence:

- `phase4-coordinator/internal/pool/provider.go` - `phase4-coordinator/internal/ws/server.go`

The in-memory provider registry exposes the current provider picture.

Provider fields available today:

- `provider_id` - `assigned_id` - `hostname` - `model_id` - `model_params_b` - `ram_gb` - `max_context_tokens` -
`max_concurrency` - `slots_free` - `slots_total` - `throughput_tps_estimate` - `model_load_time_ms` - `endpoint_url` -
`tier` - `inference_path` - `admitted_at` - `http_forwarding_only` - `state` - `last_heartbeat_at` - `last_activity_at`
- `connected_at` - `binary_version` - `model_hash` - `hash_status` - `encrypted_leg` - `attestation_status`

This is authoritative for "now."

It is not a durable connection history.

Gaps:

- **[GAP]** No durable `provider_sessions` table.  - **[GAP]** No durable `provider_state_events` table.  - **[GAP]** No
durable coordinator restart table.  - **[GAP]** Provider reconnect counts live in logs/monitoring, not SQLite.

### 2.3 Coordinator request log table

Evidence:

- `phase4-coordinator/internal/requestlog/store.go` - `specs/SPEC-002-coordinator.md` - `specs/SPEC-005-billing.md`

Table: `request_log`.

Columns:

- `id INTEGER PRIMARY KEY AUTOINCREMENT` - `ts_utc TEXT NOT NULL` - `request_id TEXT NOT NULL` - `model TEXT NOT NULL` -
`provider_assigned_id TEXT NULL` - `prompt_tokens INTEGER NULL` - `completion_tokens INTEGER NULL` - `total_tokens
INTEGER NULL` - `latency_ms REAL NOT NULL` - `routing_ms REAL NOT NULL` - `status INTEGER NOT NULL` - `stream INTEGER
NOT NULL` - `buyer_ip TEXT NOT NULL DEFAULT ''` - `error TEXT NULL` - `error_code TEXT NULL` - `pref_header TEXT NULL` -
`provider_header TEXT NULL` - `retried INTEGER NOT NULL DEFAULT 0`

Indexes:

- `idx_request_log_ts_utc ON request_log(ts_utc)`.  - `idx_request_log_request_id_id ON request_log(request_id, id)`.

Explorer uses:

- Recent request feed.  - Request/session detail.  - Latency and routing latency summaries.  - Status/error/retry
summaries.  - Join to SPEC-005 ledger rows on coordinator-internal `request_id`.  - Join to gateway usage rows on the composite `(account_id, external_request_id)` ⇔ gateway `(account_id, request_id)` reconciliation key (SPEC-002 v1.5.0 / #211). For pre-#211 rows with NULL `account_id`, the explorer's §5.6 session-detail handler does NOT proxy to the gateway (returns `gateway_identity_unavailable`); out-of-process audit tooling MAY join on `external_request_id` alone with documented cross-account ambiguity.

Gaps:

- **[GAP]** No coordinator-side `key_id`.  - **[GAP]** No stored
`attempt_n`; SPEC-005 derives attempt order from
  `(request_id, id)`.
- **[GAP]** No durable in-flight request table.  - **[GAP]** No request body digest or response byte count.

### 2.4 Coordinator provider token table

Evidence:

- `phase4-coordinator/internal/auth/tokens.go`

Table: `provider_tokens`.

Columns:

- `id INTEGER PRIMARY KEY AUTOINCREMENT` - `token_hash TEXT NOT NULL UNIQUE` - `token_prefix TEXT NOT NULL` -
`provider_id TEXT NOT NULL DEFAULT ''` - `provider_name TEXT NOT NULL` - `created_at TEXT NOT NULL` - `revoked_at TEXT
DEFAULT NULL` - `last_used_at TEXT DEFAULT NULL`

Index:

- `idx_token_hash ON provider_tokens(token_hash)`.

Explorer uses:

- Provider-token issuance status.  - Token revocation status.  - Last provider token use.  - Readiness for
`auth.require_provider_tokens`.

Gaps:

- **[GAP]** No read-only provider token directory endpoint.  - **[GAP]** No provider token purpose/tier field.

The explorer must never show `token_hash`.

### 2.5 Coordinator ledger tables

Evidence:

- `phase4-coordinator/internal/billing/store.go` - `specs/SPEC-005-billing.md`

Table: `ledger_request_credits`.

Columns:

- `id` - `request_id` - `attempt_n` - `provider_id` - `provider_assigned_id` - `ts_utc` - `model` - `status` - `stream`
- `prompt_tokens` - `completion_tokens` - `estimated_completion_tokens` - `usage_source` - `prompt_rate_per_mtok` -
`completion_rate_per_mtok` - `global_multiplier_ppm` - `gross_credits` - `provider_share_bps` - `provider_credits` -
`fault_flag` - `attestation_class` - `settled` - `settlement_id` - `quarantined` - `quarantine_reason` -
`recovery_source` - `created_at_utc` - `updated_at_utc`

Indexes:

- Unique `(request_id, attempt_n, provider_id)`.  - `idx_lrc_provider_ts`.  - `idx_lrc_unsettled`.  - `idx_lrc_request`.
- `idx_lrc_quarantine`.  - `idx_lrc_fault`.

Table: `ledger_operator_credits`.

Columns:

- `id` - `request_credit_id` - `request_id` - `attempt_n` - `provider_id` - `ts_utc` - `gross_credits` -
`operator_share_bps` - `operator_credits` - `fault_flag` - `created_at_utc`

Indexes:

- `idx_loc_request`.  - `idx_loc_provider_ts`.  - `idx_loc_ts`.

Table: `ledger_payout_ready`.

Columns:

- `id` - `provider_id` - `window_start_utc` - `window_end_utc` - `cadence_days` - `source_credit_count` -
`gross_credits` - `provider_credits` - `operator_credits` - `min_payout_credits` - `payout_currency` -
`payout_external_id` - `status` - `idempotency_key` - `created_at_utc`

Indexes and guards:

- Unique provider/window.  - Unique idempotency key.  - `idx_lpr_provider_status`.  - `idx_lpr_status`.  - Terminal
status trigger for consumed/voided rows.

Table: `ledger_reconciliation_runs`.

Columns:

- `id` - `run_type` - `from_utc` - `to_utc` - `request_log_rows_scanned` - `missing_credit_rows_created` -
`orphan_credit_rows_quarantined` - `buyer_equivalent_credits` - `provider_gross_credits` -
`reconciliation_delta_credits` - `started_at_utc` - `finished_at_utc` - `status` - `error` - `created_at_utc`

Indexes:

- `idx_lrr_type_started`.  - `idx_lrr_range`.

Table: `ledger_config_snapshots`.

Columns:

- `id` - `effective_at_utc` - `config_hash` - `provider_share_bps` - `global_multiplier_ppm` - `rate_card_json` -
`created_at_utc`

Index:

- `idx_lcs_effective_at`.

Table: `ledger_provider_identity_snapshots`.

Columns:

- `id` - `request_id` - `attempt_n` - `provider_assigned_id` - `provider_id` - `resolved_from` -
`pool_session_started_at_utc` - `created_at_utc`

Indexes:

- `idx_lpis_request`.  - `idx_lpis_provider`.

Explorer uses:

- Provider economics.  - Ledger request detail.  - Settlement history.  - Pending payout queue.  - Quarantine queue.  -
Rate-card context.  - Reconciliation health.  - SPEC-007 handoff readiness.

Gaps:

- **[GAP]** No USDC balance table.  - **[GAP]** No external payout transaction table.  - **[GAP]** `payout_currency` and
`payout_external_id` are future-facing
  nullable fields.

### 2.6 Gateway endpoint inventory

Evidence:

- `phase5-gateway/README.md` - `phase5-gateway/internal/router/server.go` - `specs/SPEC-006-buyer-api.md`

Gateway public/authenticated endpoints:

- `GET /auth/github/start` - `GET /auth/github/callback` - `POST /auth/demo-session` - `GET /auth/api-keys` - `POST
/auth/api-keys` - `POST /auth/api-keys/{key_id}/revoke` - `GET /account` - `GET /docs` - `GET /v1/models` - `GET
/v1/usage` - `POST /v1/chat/completions` - `DELETE /v1/sticky` - `GET /v1/status` - `POST /v1/feedback` - `GET /healthz`

Gateway operator endpoints:

- `GET /admin/feedback-summary` - `POST /admin/kill-switch` - `POST /admin/capacity-signal` - `POST
/admin/capacity-tier/evaluate`

Gaps:

- **[GAP]** No read-only `GET /admin/buyers`.  - **[GAP]** No read-only `GET /admin/buyers/{account_id}`.  - **[GAP]**
No read-only operator API-key directory.  - **[GAP]** No read-only capacity state endpoint separate from mutating
  capacity controls.

### 2.7 Gateway SQLite tables

Evidence:

- `phase5-gateway/internal/storage/sqlite/migrate.go` - `phase5-gateway/README.md`

Table: `accounts`.

Columns: `account_id`, `status`, `quota_class`, `concurrency_class`, `created_at`.

Table: `account_identities`.

Columns: `account_id`, `provider`, `provider_user_id`, `email`, `created_at`.

Table: `oauth_states`.

Columns: `state_hash`, `session_id`, `redirect_uri`, `client_ip`, `created_at`, `expires_at`, `consumed_at`.

Table: `api_keys`.

Columns: `key_id`, `account_id`, `key_hash`, `key_hash_prefix`, `status`, `created_at`, `revoked_at`.

Table: `api_key_events`.

Columns: `event_id`, `key_id`, `account_id`, `request_id`, `event_type`, `actor`, `created_at`.

Table: `usage_events`.

Columns: `request_id`, `account_id`, `demo_identity`, `window_date`, `prompt_tokens`, `completion_tokens`,
`total_tokens`, `token_source`, `outcome`, `created_at`.

Table: `quota_reservations`.

Columns: `account_id`, `request_id`, `window_date`, `reserved_tokens`, `settled_tokens`, `status`, `expires_at`,
`created_at`, `settled_at`.

Table: `concurrency_reservations`.

Columns: `account_id`, `request_id`, `status`, `expires_at`, `created_at`, `released_at`.

Table: `feedback_events`.

Columns: `event_id`, `request_id`, `account_id`, `scope`, `rating`, `comment`, `created_at`.

Table: `signup_events`.

Columns: `event_id`, `account_id`, `client_ip`, `provider`, `created_at`.

Table: `demo_session_events`.

Columns: `event_id`, `client_ip`, `created_at`.

Table: `demo_usage_events`.

Columns: `request_id`, `client_ip`, `demo_token_hash`, `window_date`, `total_tokens`, `created_at`.

Table: `audit_events`.

Columns: `event_id`, `request_id`, `account_id`, `actor`, `event_type`, `payload_json`, `created_at`.

Table: `capacity_signal_events`.

Columns: `event_id`, `signal`, `value`, `threshold`, `firing`, `created_at`.

Table: `runtime_config`.

Columns: `key`, `value`, `updated_at`.

Gateway indexes cover:

- account identity lookup.  - OAuth state lookup.  - API key hash and account lookup.  - API key events by key.  - usage
by account/date and created_at.  - quota active account/date and expiration.  - concurrency active account lookup.  -
feedback request and created_at lookup.  - signup IP/time lookup.  - demo session IP/time lookup.  - demo usage
IP/token/date lookup.  - audit request and created_at lookup.  - capacity signal/time lookup.

Append-only triggers protect:

- `usage_events`.  - `feedback_events`.  - `audit_events`.  - `api_key_events`.  - `demo_usage_events`.  -
`capacity_signal_events`.  - `signup_events`.  - `demo_session_events`.

Explorer uses:

- Buyer directory.  - API-key directory.  - Usage/quota view.  - Feedback view.  - Audit/capacity events.  - Public/demo
pause state through runtime config.

### 2.8 Cross-component join keys

Available joins:

- **Intra-coordinator** (single coordinator-internal id):
  coordinator-internal `request_log.request_id` joins to
  `ledger_request_credits.request_id`,
  `ledger_operator_credits.request_id`, and
  `ledger_provider_identity_snapshots.request_id`.
  `request_log.request_id` is server-minted (UUID v4 per buyer
  request — see SPEC-002 v1.5.0 §11); it does NOT travel to the
  gateway.
- **Cross-service** (coordinator ⇔ gateway, MUST be account-scoped):
  coordinator `(request_log.account_id, request_log.external_request_id)`
  ⇔ gateway `(account_id, request_id)` across all five account-keyed
  session-detail tables (`usage_events`, `quota_reservations`,
  `concurrency_reservations`, `feedback_events`, `audit_events`).
  After SPEC-002 v1.5.0 / #211 the composite is the reconciliation
  key; `external_request_id` alone is a logical correlation value
  only, ambiguous on cross-account `X-Request-ID` collisions
  (#196 / #211). See SPEC-007 § 6.4 v0.3 ambiguity contract.
- **Legacy NULL-account fallback:** rows written by pre-v1.5.0
  coordinators OR by v1.5.0 coordinators serving pre-v0.9.1
  gateway traffic carry NULL `account_id`. Tooling MUST gate
  per-row (`account_id IS NOT NULL`), not per-schema; see
  SPEC-002 v1.5.0 §11 "Deploy ordering".
- `provider_id` joins live pool state to provider tokens and ledger rows.  - `account_id` joins gateway accounts,
identities, keys, usage, quota,
  concurrency, feedback, and audit rows.
- `key_id` joins API keys and API key events.

Gaps:

- **[GAP]** No shared durable `session_id` across gateway, coordinator,
  and provider.
- **[GAP]** Demo usage is not tied to a stable account
  (`account_id` is a per-call `"demo:<ip>"` synthetic).
- **Closed by SPEC-002 v1.5.0 / #211:** the previous "no
  coordinator-side buyer identity" gap. Coordinator `request_log`
  now carries `account_id`; the composite
  `(account_id, external_request_id)` is the reconciliation key
  joining coordinator `request_log` to gateway session-detail
  tables. Pre-#211 rows persist with NULL `account_id`: the
  explorer §5.6 session-detail handler does NOT proxy such rows
  to the gateway (returns `gateway_identity_unavailable`), while
  out-of-process audit tooling MAY join on `external_request_id`
  alone with documented cross-account ambiguity. See SPEC-002
  v1.5.0 §11.

## 3. What the operator wants to see

The explorer should be view-first, not table-first.

### 3.1 Overview

Question:

Is the protocol alive and are the accounting numbers sane?

Data sources:

- Coordinator `/poolz`.  - Gateway `/v1/status`.  - Coordinator `/admin/ledger/summary`.  -
`ledger_reconciliation_runs`.  - Gateway account and usage tables through a new read-only endpoint.

Fields:

- protocol status.  - coordinator checked time.  - gateway health.  - total providers.  - ready providers.  - degraded
providers.  - unavailable providers.  - models available.  - slots free.  - requests today.  - tokens today.  - active
accounts.  - current-window provider credits.  - pending payout count.  - pending payout credits.  - quarantined ledger
rows.  - last reconciliation delta credits.  - capacity tier.  - public API pause state.  - demo pause state.

Recommendation:

Make this one shallow snapshot endpoint.

### 3.2 Live state

Question:

What can route right now?

Data sources:

- Coordinator `/poolz`.  - Gateway `/v1/status` for the public-safe view.

Fields:

- provider ID.  - assigned ID.  - hostname.  - model ID.  - state.  - tier.  - inference path.  - slots free.  - slots
total.  - max concurrency.  - max context tokens.  - RAM GB.  - throughput estimate.  - last heartbeat.  - last
activity.  - connected at.  - binary version.  - model hash.  - hash status.  - encrypted leg.  - attestation status.  -
endpoint URL.

Gaps:

- **[GAP]** No durable connect/disconnect history.

### 3.3 Activity feed

Question:

What just happened?

Data sources:

- `request_log`.  - `ledger_request_credits`.  - `ledger_payout_ready`.  - `ledger_reconciliation_runs`.  - gateway
`usage_events`.  - gateway `api_key_events`.  - gateway `audit_events`.  - gateway `feedback_events`.  - gateway
`capacity_signal_events`.

Fields:

- event time.  - event type.  - severity.  - request ID.  - account ID.  - key ID.  - provider ID.  - model ID.  -
status.  - error code.  - tokens.  - credits.  - link target.

Gaps:

- **[GAP]** No unified event table.  - **[GAP]** Provider state transitions are not durable rows.

Recommendation:

Build v1 from existing append-only tables and request logs.

Treat provider transition history as a later enhancement unless the operator locks a tiny event table.

### 3.4 Sessions and requests

Question:

Which request attempts succeeded, failed, retried, or produced ledger rows?

Data sources:

- `request_log`.  - `ledger_request_credits`.  - `ledger_provider_identity_snapshots`.  - gateway `usage_events`.  -
gateway `quota_reservations`.  - gateway `feedback_events`.

Fields:

- timestamp.  - request ID.  - attempt number.  - model.  - provider ID.  - provider assigned ID.  - account ID.  - demo
indicator.  - stream flag.  - HTTP status.  - error code.  - prompt tokens.  - completion tokens.  - total tokens.  -
usage source.  - latency ms.  - routing ms.  - retried flag.  - gross credits.  - provider credits.  - fault flag.  -
quarantined flag.  - quarantine reason.  - quota reservation status.  - gateway outcome.  - feedback rating.

Gaps:

- **[GAP]** Attempt number is derived unless stored later.  - **[GAP]** Account ID requires gateway join.  - **[GAP]**
In-flight request visibility requires new live state.

### 3.5 Buyers

Question:

Who is using the network and how much quota are they consuming?

Data sources:

- `accounts`.  - `account_identities`.  - `api_keys`.  - `api_key_events`.  - `usage_events`.  - `quota_reservations`.
- `concurrency_reservations`.  - `feedback_events`.  - `signup_events`.  - `audit_events`.

Fields:

- account ID.  - account status.  - identity provider.  - provider user ID.  - email.  - quota class.  - concurrency
class.  - account created time.  - API key ID.  - API key hash prefix.  - API key status.  - key created time.  - key
revoked time.  - daily tokens used.  - daily tokens reserved.  - daily token limit.  - daily tokens remaining.  - active
concurrency reservations.  - last usage time.  - last request ID.  - feedback count.  - average rating.

Gaps:

- **[GAP]** Gateway needs read-only buyer directory endpoints.  - **[GAP]** Last active time is computed unless
materialized later.

### 3.6 Providers

Question:

Which Macs are connected and what have they earned?

Data sources:

- `/poolz`.  - `provider_tokens`.  - `ledger_request_credits`.  - `ledger_payout_ready`.  -
`ledger_provider_identity_snapshots`.  - `ledger_config_snapshots`.  - `ledger_reconciliation_runs`.

Fields:

- provider ID.  - assigned ID.  - hostname.  - state.  - tier.  - model ID.  - binary version.  - slots free.  - slots
total.  - max context tokens.  - throughput estimate.  - token prefix.  - token status.  - token created time.  - token
last used time.  - token revoked time.  - total provider credits.  - current-window credits.  - pending payout credits.
- last payout-ready row.  - fault count.  - quarantined count.  - models served.  - rate-card excerpt.  - attestation
class.

Gaps:

- **[GAP]** No token directory endpoint.  - **[GAP]** No durable uptime/reconnect table.

### 3.7 Tokens and economics

Question:

How much work happened and how did it turn into credits?

Data sources:

- `ledger_request_credits`.  - `ledger_operator_credits`.  - `ledger_payout_ready`.  - `ledger_config_snapshots`.  -
gateway `usage_events`.  - gateway `demo_usage_events`.

Fields:

- prompt tokens.  - completion tokens.  - total tokens.  - provider-reported tokens.  - byte-estimated tokens.  -
null-error rows.  - gross credits.  - provider credits.  - operator credits.  - provider share bps.  - operator share
bps.  - prompt rate per Mtok.  - completion rate per Mtok.  - global multiplier ppm.  - pending payout count.  - pending
payout credits.  - settled row count.  - unsettled row count.  - settlement window.  - payout status.

Notes:

The prompt mentions USDC ledger balance.

The current repo has internal credits and nullable future payout fields, not a USDC balance.

### 3.8 Health

Question:

Are the protocol invariants drifting?

Data sources:

- Coordinator `/healthz`.  - Coordinator `/poolz`.  - Gateway `/healthz`.  - Gateway `/v1/status`.  -
`ledger_reconciliation_runs`.  - `ledger_request_credits`.  - gateway `audit_events`.  - gateway
`capacity_signal_events`.  - gateway `quota_reservations`.

Fields:

- coordinator health.  - gateway health.  - public status.  - pool total providers.  - pool ready providers.  - last
reconciliation status.  - last reconciliation delta.  - quarantined rows.  - split delta rows.  - fault rows.  -
capacity tier.  - capacity signals firing.  - public API pause.  - demo pause.  - active quota reservations.  - expired
quota reservations.  - active concurrency reservations.  - provider reconnect count.  - coordinator restart count.

Gaps:

- **[GAP]** Reconnect count and restart count are not durable tables.  - **[GAP]** Exact gateway HTTP error rate needs a
request log table or log
  query path.

### 3.9 Feedback and quality

Question:

What did users say, and what happened on the request they rated?

Data sources:

- `feedback_events`.  - `usage_events`.  - `request_log`.  - `ledger_request_credits`.

Fields:

- feedback event ID.  - request ID.  - account ID.  - scope.  - rating.  - comment.  - feedback created time.  - request
status.  - model.  - provider ID.  - latency.  - error code.

Notes:

Feedback comments are operator-only.

Aggregate ratings can become public aggregate later.

## 4. Endpoint surface

The coordinator can expose a read-only namespace:

- `GET /admin/explorer/overview` - `GET /admin/explorer/sessions` - `GET /admin/explorer/sessions/{request_id}` - `GET
/admin/explorer/providers` - `GET /admin/explorer/providers/{provider_id}` - `GET /admin/explorer/buyers` - `GET
/admin/explorer/buyers/{account_id}` - `GET /admin/explorer/ledger` - `GET /admin/explorer/settlements` - `GET
/admin/explorer/health` - `GET /admin/explorer/activity` - `GET /admin/explorer/stream`

This is the explored surface.

The normative spec should lock a smaller v1 subset.

### 4.1 Overview

`GET /admin/explorer/overview`

Returns:

- Pool summary.  - Model summary.  - Ledger summary.  - Last reconciliation.  - Quarantine count.  - Pending payout
summary.  - Optional gateway buyer/capacity summary.

Recommendation:

Use one fat but shallow overview endpoint.

Keep tables behind smaller endpoints.

### 4.2 Sessions

`GET /admin/explorer/sessions`

Filters:

- `from` - `to` - `status` - `model` - `provider_id` - `account_id` - `request_id` - `error_code` - `quarantined` -
`limit` - `cursor`

`GET /admin/explorer/sessions/{request_id}`

Path segment (v0.3):

- `{request_id}` is the coordinator-internal `request_log.request_id`
  (server-minted UUID v4). It is NOT the buyer-supplied
  `X-Request-ID` — that lives in `request_log.external_request_id`.
  Operators starting from a buyer-facing ticket carrying an
  `X-Request-ID` MUST resolve the internal id via direct SQL in
  v0.3 (UI surface for external-id lookup is deferred to v0.4).
  See SPEC-007 §5.6 v0.3.

Gateway proxy (v0.3 both-or-nothing):

- The coordinator forwards
  `GET /admin/explorer/sessions/<external_request_id>?account_id=<account_id>`
  to the gateway ONLY when the resolved coordinator row supplies
  BOTH a non-empty `external_request_id` AND a non-empty
  `account_id`. Otherwise the coordinator does NOT proxy and the
  response carries `gateway: {"error": {"code":
  "gateway_identity_unavailable"}}`. Gateway-side ambiguity is
  documented in SPEC-007 §6.4 v0.3 — the coordinator surface
  never exposes the 409 itself in v0.3 (the path-segment-overload
  + 409 surfacing is deferred to v0.4).

Returns:

- All request attempts.  - Ledger rows.  - Provider identity snapshots.  - Gateway usage rows (only when proxy fires).  - Quota reservation.  -
Feedback rows.

Pagination should be mandatory for lists.

### 4.3 Providers

`GET /admin/explorer/providers`

Returns live state plus economics summary.

`GET /admin/explorer/providers/{provider_id}`

Returns:

- Live state.  - Recent request attempts.  - Earnings summary.  - Token status.  - Payout-ready rows.  -
Fault/quarantine history.

This should reuse existing `GET /admin/ledger/providers` logic and add live pool plus token metadata.

### 4.4 Buyers

Buyer data is gateway-owned.

Options:

- Coordinator proxies gateway read-only admin endpoints.  - UI calls gateway read-only admin endpoints directly.  -
Buyer directory is deferred.

Recommendation:

Add gateway read-only endpoints and let the coordinator proxy summaries only if one-origin UI simplicity is worth it.

Do not copy buyer tables into coordinator storage.

### 4.5 Ledger

`GET /admin/explorer/ledger`

Filters:

- `from` - `to` - `provider_id` - `model` - `usage_source` - `fault_flag` - `settled` - `quarantined` - `limit` -
`cursor`

Reads:

- `ledger_request_credits`.  - `ledger_operator_credits`.  - `ledger_config_snapshots`.

Cursor should be stable by timestamp and row ID.

### 4.6 Settlements

`GET /admin/explorer/settlements`

Filters:

- `provider_id` - `status` - `from` - `to` - `limit` - `cursor`

Reads:

- `ledger_payout_ready`.  - Related aggregate credit counts.  - Latest reconciliation for the window if available.

It must not claim, consume, void, or pay rows.

### 4.7 Health

`GET /admin/explorer/health`

Returns:

- Coordinator health.  - Gateway health.  - Pool status.  - Last reconciliation status.  - Capacity state.  - Quarantine
summary.  - Fault summary.  - Expired reservation summary.  - Public/demo pause state.

Restart and reconnect counts require new event storage or log-based integration.

### 4.8 Activity

`GET /admin/explorer/activity`

Build the feed from:

- `request_log`.  - `ledger_request_credits`.  - `ledger_payout_ready`.  - `ledger_reconciliation_runs`.  - gateway
`api_key_events`.  - gateway `audit_events`.  - gateway `feedback_events`.  - gateway `capacity_signal_events`.

Provider connection events should be a later addition unless the operator locks a durable event table.

### 4.9 Stream

`GET /admin/explorer/stream`

SSE is optional.

Polling every 15-30 seconds is probably enough for one operator.

Recommendation:

Lock polling for v1.

Design the feed so SSE can wrap it later.

### 4.10 Gateway data path

Option A:

Coordinator proxies gateway read-only admin data.

Pros:

- One UI origin.  - One operator auth path.  - Gateway admin URL stays private.

Cons:

- Coordinator becomes a read-only aggregator for buyer data.

Option B:

UI calls gateway directly.

Pros:

- Cleaner ownership.  - Less coordinator code.

Cons:

- Two backend origins.  - More auth/CORS work.

Option C:

No buyer directory in v1.

Pros:

- Fastest.

Cons:

- Misses the operator's explicit buyer visibility request.

Recommendation:

Use read-only gateway endpoints.

Proxy through coordinator only for UI simplicity.

## 5. Frontend surface

The explorer is an internal operator dashboard.

It should be dense, operational, and read-only.

It should not be a marketing page.

Relevant repo context:

- `beta/web/` and `web-three-lime-59.vercel.app` existed as the earlier
  Vercel demo path.
- `frontdoor/console/` is the current static console surface deployed at
  `console.streamvc.live`.

The build prompt says operator preference leans toward Next.js from the Vercel history.

Current repo history also shows a later static front-door choice.

The spec should lock a hosting decision explicitly.

### 5.1 Existing Vercel project

Shape:

Add a protected explorer route to the existing Vercel project.

Pros:

- Fast UI iteration.  - Fits Next.js if the project already uses it.  - Avoids growing the coordinator binary.

Cons:

- Mixes demo/front-door and operations.  - Needs secure access from Vercel to admin endpoints.  - Exposes an internal
cockpit on public infrastructure.

### 5.2 Separate Vercel project

Shape:

Host `explorer.streamvc.live`.

Pros:

- Clean separation.  - Still fast UI iteration.  - Good if Next.js is desired.

Cons:

- New deploy target.  - New DNS/auth surface.  - Backend admin access still needs careful design.

### 5.3 Coordinator-served static dashboard

Shape:

Serve `/admin/explorer/` from coordinator or from static files beside the coordinator deployment.

Pros:

- Same origin as coordinator admin endpoints.  - Reuses existing admin gate.  - No new public app.  - Best match for
internal-only v1.

Cons:

- UI iteration follows coordinator/Pearl deployment path.  - Coordinator deploy bundle grows.

Recommendation:

Default to coordinator-served static dashboard for v1.

Use Vercel only if the operator values rich Next.js iteration over minimal ops surface.

Do not put explorer routes in the public buyer console.

### 5.4 UI shape

Tabs:

- Overview.  - Activity.  - Sessions.  - Buyers.  - Providers.  - Ledger.  - Settlements.  - Health.

Controls:

- Date range.  - Search by request ID.  - Search by account ID.  - Search by provider ID.  - Filters.  - Cursor
pagination.  - Manual refresh.  - Optional live toggle.

No charting library is required for v1.

Simple tables and status strips are enough.

## 6. Auth

The v1 threat model is single-operator access.

It is not:

- public abuse prevention.  - multi-tenant dashboard authorization.  - support-staff roles.  - provider self-service
administration.  - public redaction.  - key theft mitigation beyond admin route isolation.

The explorer is equivalent to `/admin/*`.

### 6.1 Existing admin bearer

The coordinator already checks:

- `Authorization: Bearer <operator_key>`

Pros:

- No new secret.  - Matches existing billing endpoints.  - Works well with coordinator-served UI.

Cons:

- Same token protects read-only and mutating admin routes.  - Browser token handling needs care.

Recommendation:

Use this for coordinator-served internal v1.

### 6.2 Separate explorer token

Shape:

Add `OPERATOR_EXPLORER_TOKEN` or config equivalent.

Pros:

- Read-only token can rotate separately.  - Lower blast radius for hosted UI.

Cons:

- New secret and branch to test.

Recommendation:

Use only for Vercel-hosted explorer or if the operator wants read-only separation.

### 6.3 Cloudflare Access, Tailscale, or IP allowlist

Pros:

- Strong outer gate.  - Avoids relying only on bearer token in browser.

Cons:

- More operations.  - IP allowlists are brittle.

Recommendation:

Use Cloudflare Access or Tailscale if the route is public-hosted.

Treat IP allowlist as defense in depth, not primary auth.

### 6.4 GitHub OAuth

Pros:

- Friendly browser login.  - Good fit for Vercel.  - Can allow only the operator's account.

Cons:

- More code and callback/session surface.  - Overkill for coordinator-served static v1.

Recommendation:

Use only if Vercel is chosen.

### 6.5 Default auth recommendation

Coordinator-served route:

- Existing operator bearer.  - Optional Cloudflare Access or Tailscale outside it.

Vercel route:

- GitHub OAuth allowlist or Cloudflare Access.  - Separate read-only explorer token to backend.

Do not build RBAC.

Do not build multi-tenant auth.

## 7. Refresh model

The explorer should not become a polling load test.

One operator may still open multiple tabs.

The UI must pause hidden tabs.

### 7.1 Overview

Mode:

- Page-load fetch.  - Manual refresh.  - Optional 30-second refresh.

Budget:

- One shallow snapshot per visible tab every 30 seconds.

### 7.2 Live state

Mode:

- Poll every 10 seconds while visible.  - Pause when hidden.

Budget:

- One `/poolz`-backed request per visible tab every 10 seconds.

### 7.3 Activity feed

Mode:

- Poll every 15 seconds by cursor.  - SSE later if needed.

Budget:

- Limit 50 events per response.

### 7.4 Sessions

Mode:

- Page-load fetch.  - Manual refresh.  - Optional live toggle at 30 seconds.

Budget:

- Default limit 50.  - Max limit 200.  - Require cursor or date window for history.

### 7.5 Session detail

Mode:

- Page-load fetch.  - Manual refresh.  - No automatic refresh after completion.

Budget:

- One request ID.

### 7.6 Buyers

Mode:

- Page-load fetch.  - Manual refresh.  - Optional 60-second refresh.

Budget:

- Default limit 50.  - Max limit 200.

### 7.7 Providers

Mode:

- Live state every 10 seconds.  - Economics every 30 seconds.

Budget:

- Live from memory.  - Economics from indexed provider ledger queries.

### 7.8 Ledger

Mode:

- Page-load fetch.  - Manual refresh.  - No default auto-refresh.

Budget:

- Default last 24 hours.  - Limit 100.  - Max limit 200.

### 7.9 Settlements

Mode:

- Page-load fetch.  - Manual refresh.  - Optional 60-second refresh while pending rows exist.

Budget:

- Pending rows first.  - History paginated.

### 7.10 Health

Mode:

- Poll every 30 seconds.  - Manual refresh.

Budget:

- Summary queries only.

### 7.11 Global guardrails

Client guardrails:

- Pause hidden tabs.  - Stop aggressive polling after repeated errors.  - Show stale timestamp.  - Keep manual refresh.

Server guardrails:

- Enforce max limits.  - Cap date windows.  - Use context timeouts.  - Avoid unbounded aggregates.

## 8. Performance & operational budget

The explorer should add negligible load for one operator.

The main risk is unbounded scans over growing SQLite tables.

### 8.1 Cheap queries

Cheap with existing structures:

- `/poolz` from memory.  - `/healthz`.  - `ledger_payout_ready WHERE status='ready'` via `idx_lpr_status`.  -
`ledger_request_credits WHERE provider_id=?` via `idx_lrc_provider_ts`.  - `ledger_request_credits WHERE request_id=?`
via `idx_lrc_request`.  - `ledger_request_credits WHERE quarantined=?` via `idx_lrc_quarantine`.  - `request_log WHERE
ts_utc >= ?` via `idx_request_log_ts_utc`.  - `request_log WHERE request_id=?` via `idx_request_log_request_id_id`.  -
Gateway `usage_events WHERE account_id=? AND window_date=?`.  - Gateway active quota reservations by
account/date/status.  - Gateway active concurrency reservations by account/status.

### 8.2 Queries needing care

Top buyers by tokens last 24h:

- Source: gateway `usage_events`.  - Mark: **[INDEX]** or later daily account rollup if usage grows.

Top providers by credits last 24h:

- Source: `ledger_request_credits`.  - Mark: **[INDEX]** consider `(ts_utc, provider_id)` if scans show cost.

Buyer last-active directory:

- Source: gateway `usage_events`.  - Mark: **[CACHE]** later if `MAX(created_at) GROUP BY account_id` gets slow.

Activity feed:

- Source: multiple tables.  - Mark: **[INDEX]** ensure each source has a usable event timestamp index.

Provider reconnect count:

- Source: absent today.  - Mark: **[GAP]** and later **[CACHE]** if event table arrives.

Gateway error rate:

- Source: partial from usage/audit events; exact HTTP rate needs gateway
  request log or log query.
- Mark: **[GAP]**.

### 8.3 Worst-case refresh

A visible tab with overview, live state, activity, and health polling should issue roughly 10-15 requests per minute.

That is acceptable.

Five visible tabs can multiply this.

The UI should pause hidden tabs and avoid second-level polling.

### 8.4 SQLite posture

Explorer reads should:

- Be bounded.  - Be indexed.  - Use short timeouts.  - Avoid writes.  - Avoid `SELECT *`.  - Avoid whole-history
aggregates on page load.

Do not add materialized caches in v1 unless measured queries require them.

Possible later caches:

- Daily account usage rollup.  - Daily provider credits rollup.  - Provider state transition rollup.  - Hourly model
latency rollup.

## 9. Forward path to public explorer

Every field below is tagged as:

- `operator-only` - never safe publicly.  - `public-aggregate` - safe only as an aggregate.  - `public-redacted` - safe
with redaction.  - `public-raw` - safe as-is.

Internal v1 may show operator-only fields.

A future public explorer must not.

### 9.1 Overview tags

- protocol status: `public-raw` - coordinator checked time: `public-aggregate` - gateway health: `public-raw` - total
providers: `public-aggregate` - ready providers: `public-aggregate` - degraded providers: `public-aggregate` -
unavailable providers: `public-aggregate` - models available: `public-raw` - slots free: `public-aggregate` - requests
today: `public-aggregate` - tokens today: `public-aggregate` - active accounts: `public-aggregate` - current-window
provider credits: `public-aggregate` - pending payout count: `public-aggregate` - pending payout credits:
`public-aggregate` - quarantined ledger rows: `operator-only` - last reconciliation delta credits: `public-aggregate` if
rounded - capacity tier: `public-raw` - public API pause state: `public-raw` - demo pause state: `public-raw`

### 9.2 Live provider tags

- provider ID: `public-redacted` - assigned ID: `operator-only` - hostname: `operator-only` - model ID: `public-raw` -
state: `public-aggregate` - tier: `operator-only` raw, `public-aggregate` counts - inference path: `public-aggregate` -
slots free: `public-aggregate` - slots total: `public-aggregate` - max concurrency: `public-aggregate` - max context
tokens: `public-raw` - RAM GB: `public-aggregate` - throughput estimate: `public-aggregate` - last heartbeat:
`operator-only` - last activity: `operator-only` - connected at: `operator-only` - binary version: `operator-only` -
model hash: `public-redacted` only if catalog is public - hash status: `public-aggregate` - encrypted leg:
`public-aggregate` - attestation status: `public-aggregate` - endpoint URL: `operator-only`

### 9.3 Activity and request tags

- event time: `public-aggregate` if bucketed - event type: `public-aggregate` - severity: `operator-only` - request ID:
`public-redacted` - attempt number: `operator-only` - account ID: `operator-only` - key ID: `operator-only` - provider
ID: `public-redacted` - provider assigned ID: `operator-only` - model ID/model: `public-raw` - demo indicator/demo
identity: `operator-only` - stream flag: `public-aggregate` - HTTP status/status: `public-aggregate` - error code:
`public-aggregate` - prompt tokens: `public-aggregate` - completion tokens: `public-aggregate` - total tokens/tokens:
`public-aggregate` - usage source: `public-aggregate` - latency ms: `public-aggregate` - routing ms: `public-aggregate`
- retried flag: `public-aggregate` - gross credits/credits: `public-aggregate` - provider credits: `public-aggregate` -
fault flag: `operator-only` raw, `public-aggregate` count - quarantined flag: `operator-only` - quarantine reason:
`operator-only` - quota reservation status: `operator-only` - gateway outcome: `public-aggregate` - feedback rating:
`operator-only` raw, `public-aggregate` aggregate - link target: `operator-only`

### 9.4 Buyer tags

- account ID: `operator-only` - account status: `operator-only` - identity provider: `operator-only` raw,
`public-aggregate` count - provider user ID: `operator-only` - email: `operator-only` - quota class: `operator-only` -
concurrency class: `operator-only` - account created time: `operator-only` - API key ID: `operator-only` - API key hash
prefix: `operator-only` - API key status: `operator-only` - key created time: `operator-only` - key revoked time:
`operator-only` - daily tokens used: `operator-only` per account, `public-aggregate` total - daily tokens reserved:
`operator-only` - daily token limit: `operator-only` - daily tokens remaining: `operator-only` - active concurrency
reservations: `operator-only` - last usage time: `operator-only` - last request ID: `operator-only` - feedback count:
`operator-only` per account, `public-aggregate` total - average rating: `operator-only` per account, `public-aggregate`
total

### 9.5 Provider economics tags

- token prefix: `operator-only` - token status: `operator-only` - token created time: `operator-only` - token last used
time: `operator-only` - token revoked time: `operator-only` - total provider credits: `public-aggregate` -
current-window credits: `public-aggregate` - pending payout credits: `public-aggregate` - last payout-ready row:
`operator-only` raw, `public-aggregate` summary - fault count: `public-aggregate` - quarantined count: `operator-only` -
models served: `public-raw` - rate-card excerpt: `public-raw` if rates are public - attestation class:
`public-aggregate`

### 9.6 Ledger and settlement tags

- provider-reported tokens: `public-aggregate` - byte-estimated tokens: `public-aggregate` - null-error rows:
`operator-only` raw, `public-aggregate` count - operator credits: `operator-only` - provider share bps: `public-raw` if
split is public - operator share bps: `operator-only` - prompt rate per Mtok: `public-raw` if rates are public -
completion rate per Mtok: `public-raw` if rates are public - global multiplier ppm: `public-raw` if rates are public -
pending payout count: `public-aggregate` - settled row count: `public-aggregate` - unsettled row count:
`public-aggregate` - settlement window: `public-raw` - payout status: `public-aggregate` - payout row ID:
`operator-only` - payout currency: `public-raw` once public payout rail exists - payout external ID: `operator-only`
until SPEC-007 public rules exist - idempotency key: `operator-only` - config hash: `operator-only` - recovery source:
`operator-only`

### 9.7 Health and feedback tags

- coordinator health: `public-raw` - public status: `public-raw` - pool total providers: `public-aggregate` - pool ready
providers: `public-aggregate` - last reconciliation status: `public-aggregate` - split delta rows: `operator-only` -
fault rows: `operator-only` raw, `public-aggregate` count - capacity signals firing: `public-aggregate` - active quota
reservations: `operator-only` - expired quota reservations: `operator-only` - provider reconnect count: `operator-only`
raw, `public-aggregate` count - coordinator restart count: `operator-only` raw, `public-aggregate` count - feedback
event ID: `operator-only` - scope: `operator-only` - rating: `operator-only` raw, `public-aggregate` aggregate -
comment: `operator-only` - feedback created time: `operator-only` - request status: `public-aggregate`

### 9.8 Public promotion by view

Overview:

Keep status, model availability, provider counts, request counts, token counts, and rounded credit totals.

Drop account IDs, request IDs, quarantine details, and raw reconciliation internals.

Live state:

Keep aggregate model capacity.

Drop hostnames, assigned IDs, endpoint URLs, token state, and exact heartbeat times.

Activity:

Public version should be an aggregate timeline, not raw events.

Sessions:

Public version should show aggregates unless a redacted request-ID contract is intentionally designed.

Buyers:

No raw public buyer view.

Only aggregate account counts and usage totals survive.

Providers:

Public version can show counts by model and redacted provider labels if the operator chooses.

It must drop hostnames, assigned IDs, endpoint URLs, and token state.

Ledger:

Public version can show aggregate credits and windows.

It must drop idempotency keys, operator share, row IDs, quarantine reasons, and recovery metadata.

Settlements:

Public version waits for a later payout/public explorer SPEC.

Health:

Public version can show up/idle/degraded/down and aggregate availability.

It must drop operational security details.

## 10. Open questions for operator (LOCKED-DECISIONS section)

**Q1. Hosting (§5).** Coordinator-served `/admin/explorer/` (recommended), separate Vercel project, or old Vercel route?
Trade-off: coordinator-served is fewer moving parts; Vercel is faster for rich UI iteration.

**Q2. Frontend technology (§5).** Static dashboard (recommended) or Next.js? Trade-off: static matches internal-only
ops; Next.js may speed tables and filters if hosted on Vercel.

**Q3. Auth (§6).** Existing coordinator operator bearer (recommended), separate explorer token, or GitHub OAuth?
Trade-off: existing auth is simplest; separate auth lowers blast radius for public-hosted UI.

**Q4. Gateway buyer data (§4.10).** Coordinator proxy to gateway read-only endpoints (recommended), UI calls gateway
directly, or omit buyers from v1? Trade-off: proxying gives one origin; direct calls keep ownership cleaner but
complicate auth/CORS.

**Q5. Buyer endpoints (§3.5).** Add gateway read-only buyer endpoints in v1 (recommended) or defer buyer directory?
Trade-off: buyers are explicit in the operator ask; deferral makes v1 easier but incomplete.

**Q6. Provider event history (§2.2, §3.2, §3.8).** Rely on live `/poolz` plus logs for v1 (recommended), or add a
durable provider event table?  Trade-off: live-only is smaller; event rows unlock reconnect and uptime history.

**Q7. In-flight requests (§3.4).** Show completed attempts only in v1 (recommended), or add an in-flight endpoint?
Trade-off: completed attempts are durable now; in-flight visibility requires new live state.

**Q8. Activity transport (§4.9).** Polling (recommended) or SSE in v1?  Trade-off: polling is enough for one operator;
SSE gives a better live ticker but adds complexity.

**Q9. Public-safe tagging (§9).** Keep tags in the spec/design (recommended), or include tags in endpoint schemas now?
Trade-off: schema tags future-proof clients but add noise before a public explorer exists.

**Q10. Operator economics (§3.7, §9.6).** Show operator share internally (recommended), or hide it from the dashboard?
Trade-off: internal audit needs it; public explorer must drop it.

**Q11. Settlement rows (§3.7, §4.6).** Include settlement-ready rows in v1 (recommended), or wait for payout rail
design? Trade-off: SPEC-005 already emits them; mutating payout remains later.

**Q12. Index posture (§8).** Add only measured-needed indexes (recommended), or proactively add provider/time and buyer
rollup indexes?  Trade-off: measured indexes keep migrations narrow; proactive indexes may avoid early slowness.

**Q13. Public explorer scope (§9).** Treat public explorer as later SPEC (recommended), or include redaction endpoints
now? Trade-off: later SPEC honors internal-only v1; early redaction reduces future rework but expands scope.

**Q14. V1 success bar (§1).** Success means one operator can answer live state, recent activity, buyers, providers,
ledger, settlements, and health in under two minutes (recommended), or require analytics-grade charts?  Trade-off: the
cockpit answers the current pain; analytics can follow real operator use.
