# Mac Provider Buyer API Gateway

Phase 5 gateway implementation for SPEC-006 v0.5. The gateway is intentionally separate from `phase4-coordinator`: the coordinator remains router-only, while the gateway owns buyer identity, API keys, quota reservations, usage events, feedback events, audit events, status shaping, and kill switches.

## What Is Implemented

- `cmd/gateway` entrypoint with config loading, SQLite migration, HTTP serving, and SIGINT/SIGTERM shutdown.
- `gateway.yaml` schema and `gateway.yaml.example`.
- Storage interfaces in `internal/storage` for auth, accounts, keys, usage/quota, feedback, audit, and capacity.
- SQLite v1 backend with WAL mode, lookup indexes, append-only triggers, and transactional quota reservation via `BEGIN IMMEDIATE`.
- GitHub OAuth start/callback with stored state, callback allowlist, scope minimization, signup rate limit, Tier 1 signup closure, and one-time API key issuance.
- Minimal `/account` handoff page that displays a newly issued key once and clears the handoff cookie.
- HMAC/SHA API key generation, hash-only storage, validation, rotation, revocation, and account-history preservation.
- HMAC demo-session token issuance/validation with per-IP issuance limits and demo-only kill switch.
- `/v1/models`, `/v1/usage`, `/v1/chat/completions`, `/v1/status`, `/v1/feedback`.
- OpenAI-shaped chat forwarding to `coordinator.buyer_url`, including SSE pass-through and buyer disconnect cancellation.
- Quota reservation/settlement for success, 503 refund, 502/504 prompt-only or partial usage, demo chat usage, provider-reported streaming actuals, and byte-estimation fallback.
- Storage-backed per-account concurrency caps.
- Inbound and outbound `X-MacProvider-*` stripping plus `X-Request-ID` generation/forwarding.
- Buyer-safe `/v1/status` from coordinator `/poolz` with redaction and 10-second cache.
- Operator endpoints for feedback summary, kill-switch toggles, capacity signals, Tier 2 quota reduction, Tier 3 public pause, and capacity-tier de-escalation.
- Deployment templates in `dist/` and AC status matrix in `docs/AC_STATUS.md`.

Known gaps before production are documented in `docs/AC_STATUS.md`: live GitHub OAuth, live OpenAI SDK smoke, Pearl nginx/systemd verification, and front-door migration/docs checks.

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
base_url = https://api.streamvc.live/v1
api_key = <mp_* key>
```

## Deployment To Pearl

Templates:

- `dist/macprovider-gateway.service`
- `dist/nginx-api.streamvc.live.conf`
- `dist/deploy-pearl-vps.md`

Production deployment is a separate operator-authorized step. The intended Pearl layout is:

- `/opt/macprovider/gateway`
- `/opt/macprovider/gateway.yaml`
- `/var/lib/macprovider/gateway.db`
- `/etc/macprovider/gateway.env`
- `/etc/systemd/system/macprovider-gateway.service`
- `/etc/nginx/sites-available/api.streamvc.live`

Required deployment checks:

```sh
systemd-analyze verify /etc/systemd/system/macprovider-gateway.service
nginx -t
/opt/macprovider/gateway --config /opt/macprovider/gateway.yaml --check
curl -i https://api.streamvc.live/v1/status
```

The API nginx site proxies public `/v1/*`, `/auth/*`, and `/account` to `127.0.0.1:9443`, except `/v1/pool/check` returns 404. Operator `/admin/*` endpoints stay off the public API nginx site and should be reached only through a trusted operator path such as loopback or a private tunnel. Coordinator `/poolz`, `/healthz`, and `/ws/provider` are not exposed on `api.streamvc.live`.

## Storage And Quota

SQLite is the v1 storage backend for the single-gateway-instance Pearl VPS deployment. Handler packages depend on `internal/storage` interfaces only; future PostgreSQL, Cloudflare D1, or Workers KV migrations should stay behind those interfaces.

Usage, feedback, audit, demo usage, API-key event, and capacity signal tables are append-only at the database trigger layer. Quota reservation is storage-backed and settled after upstream completion or cancellation.

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
go test ./internal/router -run 'TestOAuthCallbackAllowlist|TestOAuthStateCSRF|TestOAuthScopeMinimization|TestKeyRevocationLatency|TestKeyRotationPreservesHistory|TestDemoTokenValidation|TestProviderPinningHeadersStripped|TestQuotaSettlement504ZeroCompletion|TestStreamingQuotaReservationAndSettlement'
go test ./internal/router -run 'TestKillSwitchPersistsAcrossRestart|TestStatusRedactionAndPoolzCacheFlush|TestFeedbackSummaryAggregation|TestCapacityTierDeescalation'
go test ./internal/router -run 'TestCrossAccountKeyRevocationRejected|TestDemoChatQuotaExhaustionIsSeparateFromAccountQuota|TestAccountConcurrencyCap|TestModelsCoordinatorUnavailableReturns503|TestCapacityTierTwoHalvesQuotaAndTierThreePauses|TestDemoOnlyKillSwitchPausesPlaygroundFeedback|TestRealIPTakesPrecedenceOverSpoofedForwardedFor'
```

The storage tests include a 10,000-key auth lookup fixture and fail if p95 validation latency is not below 1 ms on local SQLite.
