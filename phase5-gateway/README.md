# Mac Provider Buyer API Gateway

Phase 5 gateway implementation for SPEC-006 v0.9.13. The gateway is intentionally separate from `phase4-coordinator`: the coordinator remains router-only, while the gateway owns buyer identity, API keys, quota reservations, usage events, feedback events, audit events, status shaping, and kill switches.

## What Is Implemented

- `cmd/gateway` entrypoint with config loading, SQLite migration, HTTP serving, and SIGINT/SIGTERM shutdown.
- `gateway.yaml` schema and `gateway.yaml.example`.
- Storage interfaces in `internal/storage` for auth, accounts, keys, usage/quota, feedback, audit, and capacity.
- SQLite v1 backend with WAL mode, lookup indexes, append-only triggers, and transactional quota reservation via `BEGIN IMMEDIATE`.
- GitHub OAuth start/callback with stored state-bound redirect URI, callback allowlist at OAuth start, scope minimization, signup rate limit, Tier 1 signup closure, and one-time API key issuance.
- Minimal `/account` handoff page that displays a newly issued key once and clears the handoff cookie.
- HMAC/SHA API key generation, hash-only storage, validation, rotation, revocation, and account-history preservation.
- HMAC demo-session token issuance/validation with per-IP issuance limits and demo-only kill switch.
- `/v1/models`, `/v1/usage`, `/v1/chat/completions`, `/v1/status`, `/v1/feedback`, `/healthz`; experimental `/v1/messages` only when `features.anthropic_messages_enabled` is set.
- OpenAI-shaped chat forwarding to `coordinator.buyer_url`, including SSE pass-through and buyer disconnect cancellation.
- `/v1/models`, `/v1/usage`, `/v1/chat/completions`, optional stateless `/v1/responses`, `/v1/status`, `/v1/feedback`, `/healthz`.
- OpenAI-shaped chat forwarding to `coordinator.buyer_url`, including SSE pass-through and buyer disconnect cancellation; the optional Responses facade translates into the same billed path.
- Quota reservation/settlement for success, 503 refund, 502/504 prompt-only or partial usage, demo chat usage, provider-reported streaming actuals, and byte-estimation fallback for legacy/observe traffic. Covered SPEC-022 enforce traffic retains receipt authority: missing declared finality holds the reservation for reconciliation, and facade validation errors cannot authorize a fallback debit.
- Chat/Responses admission rejects duplicate or noncanonical recognized request fields before reservation and dispatch, preventing case-dependent token-cap interpretation across services.
- Storage-backed per-account concurrency caps.
- Inbound and outbound `X-MacProvider-*` stripping plus UUID-v4 `X-Request-ID` generation/forwarding.
- Buyer-safe `/v1/status` from coordinator `/poolz` with redaction and 10-second cache.
- Operator endpoints for feedback summary, kill-switch toggles, capacity signals, Tier 2 quota reduction, Tier 3 public pause, and capacity-tier de-escalation.
- Deployment templates in `dist/` and AC status matrix in `docs/AC_STATUS.md`.

Known gaps before production are documented in `docs/AC_STATUS.md`: live GitHub OAuth, live OpenAI SDK smoke, Pearl nginx/systemd verification, and front-door migration/docs checks.

## OAuth Handoff Custody

OAuth `return_to` redirects carry a five-minute, single-use handoff token. The
database stores its hash and account-bound issuance intent, not an API key.
Exchange generates the key in memory and atomically stores only its hash while
consuming the intent. The handoff callback does not also deliver a key cookie.
Direct `/account` delivery remains available, including when intent persistence
fails; failed or expired handoffs require a fresh OAuth flow with `action=mint`.

Schema version 12 invalidates every legacy plaintext handoff, including consumed
rows, and replaces the table without its `api_key` column. Stop the old gateway
before upgrading and migrate before serving requests; do not run old and new
binaries against the same database. In-flight legacy handoffs must restart OAuth.
Older binaries refuse the version-12 database. A rollback must follow the existing
snapshot/drain/reconciliation policy, not simply restore a snapshot after new
auth or billing traffic has occurred.

This migration does not revoke existing API keys or erase historical database
pages, WAL files, snapshots or backups containing old handoffs. Assess those
copies and authorize any necessary key revocation or retention cleanup separately;
do not print recovered keys or assume logical row deletion erased old secrets.

## Receipt Finality Recovery

Missing declared settlement trailers do not authorize a local debit. The gateway
holds the reservation and persists its local usage candidate, bound to the exact
reservation generation, before attempting observe-mode recovery. Reconciliation
can recover that candidate after an authority outage or gateway restart without
substituting receipt totals for locally observed usage.
Retry order is persisted so unavailable older requests cannot monopolize bounded
reconciliation batches across restarts.

Deploy the coordinator update first: recovery requires its authenticated
`mode_scope_complete` signal, a matching request scope containing the current
`X-MacProvider-Internal-Request-ID`, and the recognized observe policy. The
`required_internal_request_id` lookup fence prevents an earlier logged retry from
authorizing recovery before the current attempt is visible. Older coordinator
responses, incomplete or mixed scopes, and unavailable
authority leave the candidate held. Enforce-mode receipt finality remains
authoritative; local facade validation cannot replace it. Observe fallback is not
a verified-receipt or privacy-conformance claim.

Schema version 12 also stores recovery candidates. Historical holds created before
candidate persistence are not automatically reconstructed; assess those through
the existing reconciliation and operator procedures.
Requests without the current-attempt header also cannot create an automatically
recoverable observe candidate. Their empty binding is persisted as a hold that
cannot enter unbound reconciliation; deploy the coordinator first to avoid these
holds.

## Local Development

```sh
cd phase5-gateway
cp gateway.yaml.example gateway.yaml
export COORDINATOR_OPERATOR_KEY=dev-operator-key
export MACPROVIDER_KEY_HASH_SECRET=dev-key-hash-secret
export MACPROVIDER_DEMO_SIGNING_SECRET=dev-demo-secret
export GITHUB_OAUTH_CLIENT_ID=dev-client-id
export GITHUB_OAUTH_CLIENT_SECRET=dev-client-secret
go test ./...
go run ./cmd/gateway -config gateway.yaml -check
go run ./cmd/gateway -config gateway.yaml
```

By default the gateway listens on `127.0.0.1:9443`, forwards buyer requests to coordinator `127.0.0.1:8443`, and reads coordinator operator status from `127.0.0.1:8444`.

## API Smoke

Issue or obtain an API key, then:

```sh
curl -i -H "Authorization: Bearer $MP_API_KEY" http://127.0.0.1:9443/v1/models
curl -i -H "Authorization: Bearer $MP_API_KEY" http://127.0.0.1:9443/v1/usage
curl -i http://127.0.0.1:9443/v1/status
curl -i -H "Authorization: Bearer $MP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama","max_tokens":64,"messages":[{"role":"user","content":"hello"}]}' \
  http://127.0.0.1:9443/v1/chat/completions
```

OpenAI SDK configuration uses:

```text
base_url = https://api.malibu.tech/v1
api_key = <mp_* key>
```

Experimental Anthropic Messages compatibility can be enabled locally with:

```yaml
features:
  anthropic_messages_enabled: true
```

When enabled, `POST /v1/messages` accepts supported text and client-tool
Anthropic Messages requests, translates them into the existing
`/v1/chat/completions` gateway path, and translates the response back into the
Anthropic Message/SSE shape. It is a compatibility facade, not a separate
settlement path. Unsupported Anthropic features such as images, documents,
server tools, beta headers, thinking, and `top_k` are rejected before provider
dispatch.

SPEC-015 receipt compatibility live checks are opt-in because they require a running provider, coordinator, gateway, and valid API key. Run these from the repo root:

```sh
(
  cd test/integration && \
  SPEC015_SDK_COMPAT_LIVE=1 \
  MACPROVIDER_SPEC015_GATEWAY_URL=https://api.malibu.tech \
  MACPROVIDER_SPEC015_API_KEY=$MP_API_KEY \
    go test . -run TestSpec015SDKCompatLiveRunner -count=1
)

SPEC015_NGINX_ECHO_URL='https://api.malibu.tech/operator-echo-url' make test-dist
```

Issue #379 HTTP/2 live checks are also opt-in. The default `make test-dist`
run records an explicit skip so CI does not depend on Pearl or spend buyer
quota. Run the read-only ALPN and `/healthz` probe with:

```sh
MACPROVIDER_HTTP2_LIVE=1 \
MACPROVIDER_HTTP2_GATEWAY_URL=https://api.malibu.tech \
  bash phase4-coordinator/dist/test/check_nginx_http2_live_test.sh
```

Run the authenticated point-request, 8-way parallel benchmarks, and curl SSE
compatibility probe with a valid API key in
`MACPROVIDER_HTTP2_API_KEY_FILE`, `MACPROVIDER_HTTP2_API_KEY`, `MP_API_KEY`,
`BUYER_TOKEN`, or `~/.config/macprovider/buyer-api-key`. Prefer the file form
so the token does not enter child-process environments:

```sh
MACPROVIDER_HTTP2_LIVE=1 \
MACPROVIDER_HTTP2_RUN_TRANSPORT_BENCH=1 \
MACPROVIDER_HTTP2_RUN_CHAT_BENCH=1 \
MACPROVIDER_HTTP2_RUN_SSE=1 \
MACPROVIDER_HTTP2_MODEL='<live model id if /v1/models is empty>' \
MACPROVIDER_HTTP2_API_KEY_FILE=~/.config/macprovider/buyer-api-key \
MACPROVIDER_HTTP2_GATEWAY_URL=https://api.malibu.tech \
  bash phase4-coordinator/dist/test/check_nginx_http2_live_test.sh
```

`MACPROVIDER_HTTP2_RUN_TRANSPORT_BENCH=1` uses authenticated
`GET /v1/models` to measure the buyer-facing nginx/gateway transport path
without depending on current MLX provider slot capacity.
`MACPROVIDER_HTTP2_RUN_BENCH=1` is a legacy alias for this transport smoke.
`MACPROVIDER_HTTP2_RUN_CHAT_BENCH=1` is the issue-closing benchmark: it uses
authenticated `POST /v1/chat/completions`, so it requires enough live gateway
account concurrency and provider slot capacity for the 8-request fan-out.
Before spending chat requests, the harness requires the selected model to
advertise `total_slots >= 8`; set
`MACPROVIDER_HTTP2_ALLOW_LOW_CAPACITY_CHAT_BENCH=1` only when intentionally
running the negative-capacity check.

Both benchmarks constrain HTTP/2 and HTTP/1.1 to one shared client connection:
HTTP/2 must multiplex the 8-request fan-out on that connection, while HTTP/1.1
serializes on that same connection shape. A benchmark fails unless HTTP/2
parallel p95 is lower than the forced HTTP/1.1 comparison and the HTTP/2 point
request stays within `MACPROVIDER_HTTP2_POINT_REGRESSION_FACTOR` of HTTP/1.1,
default `1.20`. `MACPROVIDER_HTTP2_RUN_SSE=1` is a curl chat-stream smoke; pair
it with the SDK compatibility runner below for full OpenAI-compatible client
evidence.
For non-default `MACPROVIDER_HTTP2_GATEWAY_URL` values, pass the target token
explicitly as `MACPROVIDER_HTTP2_API_KEY_FILE` or
`MACPROVIDER_HTTP2_API_KEY`; generic key fallbacks are only used for
`https://api.malibu.tech` unless
`MACPROVIDER_HTTP2_ALLOW_GENERIC_KEY_FOR_CUSTOM_GATEWAY=1` is set.

Pair that with the existing SDK streaming compatibility runner when a live
provider is advertising a model:

```sh
(
  cd test/integration && \
  SPEC015_SDK_COMPAT_LIVE=1 \
  MACPROVIDER_SPEC015_GATEWAY_URL=https://api.malibu.tech \
  MACPROVIDER_SPEC015_MODEL="$MACPROVIDER_HTTP2_MODEL" \
  MACPROVIDER_SPEC015_API_KEY=$MP_API_KEY \
    go test . -run TestSpec015SDKCompatLiveRunner -count=1
)
```

## Deployment To Pearl

Templates:

- `dist/macprovider-gateway.service`
- `dist/nginx-api.malibu.tech.conf`
- `dist/deploy-pearl-vps.md`

Production deployment is a separate operator-authorized step. The intended Pearl layout is:

- `/opt/macprovider/gateway`
- `/opt/macprovider/gateway.yaml`
- `/var/lib/macprovider/gateway.db`
- `/etc/macprovider/gateway.env`
- `/etc/systemd/system/macprovider-gateway.service`
- `/etc/nginx/sites-available/api.malibu.tech`

Required deployment checks:

```sh
systemd-analyze verify /etc/systemd/system/macprovider-gateway.service
nginx -t
/opt/macprovider/gateway --config /opt/macprovider/gateway.yaml --check
curl -i https://api.malibu.tech/v1/status
```

The API nginx site proxies public `/v1/*`, `/auth/*`, `/account`, and `/healthz` to `127.0.0.1:9443`, except `/v1/pool/check` returns a JSON 404 envelope. Operator `/admin/*` endpoints stay off the public API nginx site and should be reached only through a trusted operator path such as loopback or a private tunnel. Coordinator `/poolz` is not exposed on `api.malibu.tech`. The `/ws/provider` route is present only with SPEC-002 PG-2 nginx `limit_req` and `limit_conn` controls before the WebSocket upgrade.

The gateway trusts nginx-set `X-Real-IP` only when the TCP peer is inside `proxy.trusted_cidrs` for buyer identity and rate-limit binding. The nginx site must overwrite `X-Forwarded-For` and set `X-Real-IP`; if the gateway is reached directly, from an untrusted peer, or nginx is misconfigured, raw buyer-supplied forwarding headers are ignored and the TCP remote address is used.

## Storage And Quota

SQLite is the v1 storage backend for the single-gateway-instance Pearl VPS deployment. Handler packages depend on `internal/storage` interfaces only; future PostgreSQL, Cloudflare D1, or Workers KV migrations should stay behind those interfaces.

Usage, feedback, audit, demo usage, API-key event, and capacity signal tables are append-only at the database trigger layer. Quota reservation is storage-backed and settled after upstream completion or cancellation. Active quota reservations expire after 24 hours; the gateway reclaims expired reservations before new quota admission and runs a background reaper every hour.

When provider usage is absent, the gateway estimates prompt or emitted completion tokens with `ceil(bytes / 4)` and records the source as `gateway_estimated`.

At capacity Tier 2 the effective account daily token quota is halved. At Tier 3 the gateway automatically pauses all public API traffic until an operator de-escalates capacity state or clears the persisted kill switch.

## Troubleshooting

- `401 missing_bearer_token` or `invalid_api_key`: check the `Authorization: Bearer mp_*` header and `MACPROVIDER_KEY_HASH_SECRET`.
- `403 api_key_revoked`: rotate/reissue the account key.
- `429 quota_exhausted`: inspect `/v1/usage` and `X-RateLimit-Reset`.
- `503 coordinator_unavailable`: check coordinator buyer URL and loopback binding.
- `503 provider_unavailable`: coordinator had no immediate provider slot; quota reservation is refunded.
- `503 public_api_paused`: operator all-public kill switch is active and persisted in `gateway.yaml`.
- `503 demo_paused`: demo-only kill switch is active; bearer-key traffic should still work.
- `504 provider_timeout`: prompt tokens are debited, completion tokens are zero unless upstream reports partial completion.

## Verification

```sh
go build ./...
go test ./...
go test ./internal/storage/... -cover
go test ./internal/router -run 'TestStrangerKeyOpenAIChatUsageFlow|TestQuotaExhaustionReturns429|TestProviderUnavailableReturns503AndRefunds|TestCapacityTierOneClosesSignupButExistingKeyWorks|TestDemoOnlyKillSwitchPausesDemoOnly|TestPublicEndpointAllowlistDoesNotExposeCoordinatorInternals'
go test ./internal/router -run 'TestOAuthCallbackAllowlist|TestOAuthStateCSRF|TestOAuthScopeMinimization|TestKeyRevocationLatency|TestKeyRotationPreservesHistory|TestDemoTokenValidation|TestProviderPinningHeadersStripped|TestQuotaSettlement504ZeroCompletion|TestStreamingQuotaReservationAndSettlement|TestModelsResponseIncludesTier1Disclosure'
go test ./internal/router -run 'TestKillSwitchPersistsAcrossRestart|TestStatusRedactionAndPoolzCacheFlush|TestFeedbackSummaryAggregation|TestCapacityTierDeescalation'
go test ./internal/router -run 'TestCrossAccountKeyRevocationRejected|TestDemoChatQuotaExhaustionIsSeparateFromAccountQuota|TestAccountConcurrencyCap|TestModelsCoordinatorUnavailableReturns503|TestCapacityTierTwoHalvesQuotaAndTierThreePauses|TestDemoOnlyKillSwitchPausesPlaygroundFeedback|TestClientIPDetectionRejectsForgedXFF|TestNotFoundReturnsOpenAIEnvelope|TestXRequestIDValidationRejectsNonV4|TestPanicRecoveryLogsPanicAndReturnsEnvelope|TestHealthzReturnsOK|TestHealthzReturns503WhenDBUnreachable'
```

The storage tests include a 10,000-key auth lookup fixture and fail if p95 validation latency is not below 1 ms on local SQLite.
