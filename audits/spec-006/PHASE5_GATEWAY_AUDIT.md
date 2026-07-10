# Phase 5 Gateway code audit (Codex, 2026-05-29T05:31:15Z)

## Summary
- 1 CRITICAL finding
- 8 MAJOR findings
- 2 MINOR findings
- 0 QUESTIONS

## CRITICAL findings

F-C1. Missing non-overridable Tier 1 disclosure on `/v1/models`

    Location: phase5-gateway/internal/router/server.go:370
    Finding: `handleModels` authenticates and then blindly proxies the coordinator `/v1/models` body to the buyer. It never injects the SPEC-006 v0.6 top-level `tier1_disclosure` block (`version`, `plaintext_to_provider`, `model_identity`, `hardware_attestation`, `tier2_milestone`). The handler also copies coordinator non-2xx responses as-is instead of normalizing them.
    Why it matters: SPEC-006 v0.6 § 5.3.1 makes this disclosure mandatory, automatic, and non-operator-overridable. Missing it reopens the external audit's Tier 1 expectation-drift finding at the public buyer surface.
    Recommended fix: Decode the coordinator models envelope, add a hardcoded `tier1_disclosure` object with exactly `{"version":"v0.6","plaintext_to_provider":true,"model_identity":"provider_reported","hardware_attestation":"none","tier2_milestone":"future"}`, reject/sanitize attempts to override it, and add tests that assert the field is present on successful `/v1/models` responses. Normalize coordinator failures to the gateway OpenAI error envelope.

## MAJOR findings

F-M1. Live GitHub OAuth callback rejects the normal provider redirect

    Location: phase5-gateway/internal/router/server.go:180
    Finding: `handleGitHubCallback` reads `redirect_uri` from the callback query and rejects the request if the query parameter is absent. GitHub redirects back with `code` and `state`; it does not echo `redirect_uri` as an application query parameter. The passing tests always append `&redirect_uri=...`, which masks the live flow.
    Why it matters: AC-4 is marked PARTIAL for live GitHub testing, but this is not merely missing live evidence; the code path appears to fail before token exchange in a real OAuth callback.
    Recommended fix: Bind the redirect URI to the stored state at `/auth/github/start` and look it up during state consumption, or derive the callback URL from the configured allowlist/request host. Add a test for `/auth/github/callback?code=ok&state=<state>` with no `redirect_uri` query.

F-M2. Streaming disconnect accounting does not implement the cancel-usage contract

    Location: phase5-gateway/internal/router/server.go:847
    Finding: On client disconnect the gateway relies on `X-MacProvider-Cancel-Usage` from the initial HTTP response headers, then falls back to byte estimation. SPEC-006 § 7.2 requires the gateway to send a cancellation to the coordinator and settle from the provider's `inference_response_end.usage` when present. Usage produced after cancellation cannot arrive in initial response headers. `TestStreamingQuotaReservationAndSettlement` sets that synthetic header before the stream starts, so it does not prove the required cancel-response path.
    Why it matters: This can systematically estimate usage for v1.2.4 providers even when exact cancel usage is available, undermining D-CROSS-1 and the H-005 settlement invariant.
    Recommended fix: Add/consume an explicit coordinator cancellation/usage path for streaming disconnects, or a real trailer/body contract if that is what the coordinator exposes. Test a disconnect where usage becomes available only after cancellation, not as a pre-stream header.

F-M3. Per-model degraded calculation does not match SPEC-002 FR-B1

    Location: phase5-gateway/internal/router/server.go:1075
    Finding: `aggregateStatus` only counts ready providers into each model row, then marks a model degraded when ready count is zero or ready slots are zero. SPEC-002 FR-B1 says a model is degraded if all providers are unavailable/draining, fewer than 50% of registered providers for the model are ready, or all providers' `slots_free` are zero.
    Why it matters: A model with one ready provider and several degraded/busy/unavailable providers can be reported as not degraded even when fewer than 50% are ready, violating D-CROSS-4 and buyer-visible status semantics.
    Recommended fix: Track total registered providers, ready providers, unavailable/draining providers, and total slots_free per model across all states; compute degraded exactly from the three SPEC-002 predicates. Add tests for the `<50% ready` branch and all-unavailable/draining branch.

F-M4. Expired quota reservations are never reclaimed

    Location: phase5-gateway/internal/storage/sqlite/store.go:354
    Finding: `ReserveQuota` calls `dailyUsageTx`, and `dailyUsageTx` sums every `status = 'active'` quota reservation without checking `expires_at` or marking expired rows. There is no reaper job elsewhere.
    Why it matters: SPEC-006 § 7.2 requires failed reservations to expire and be reclaimed within 24 hours. A crash or ignored settlement error can strand quota forever for the UTC window, causing avoidable 429s for buyers.
    Recommended fix: Inside the same `BEGIN IMMEDIATE` transaction, mark active reservations with `expires_at <= now` as `expired` before summing reserved tokens, or run a bounded startup/periodic reaper. Add a storage test proving expired reservations no longer count against quota.

F-M5. Gateway trusts buyer-controlled `X-Forwarded-For` when `X-Real-IP` is absent

    Location: phase5-gateway/internal/router/server.go:1346
    Finding: `clientIP` uses `X-Real-IP` first, but falls back to the first `X-Forwarded-For` value. If the gateway is reached directly or nginx is misconfigured, buyers can choose their client IP for demo-token binding, demo issuance limits, and signup limits.
    Why it matters: The audit prompt requires gateway code to use the nginx-set value and not trust buyer-controlled XFF. This fallback creates a rate-limit and demo-token bypass path outside nginx.
    Recommended fix: Trust only `X-Real-IP` from the configured reverse proxy path, otherwise use `RemoteAddr`; if XFF support is required, gate it behind a trusted-proxy configuration and strip inbound XFF at the proxy. Update tests to avoid treating raw XFF as authoritative.

F-M6. PG-2 proxy rate limits for `/ws/provider` are absent from the nginx artifact

    Location: phase5-gateway/dist/nginx-api.streamvc.live.conf:1
    Finding: The nginx template has no `limit_req_zone`, no `limit_conn_zone`, and no `/ws/provider` location applying them. It returns 404 for `/ws/provider` on `api.streamvc.live`, but SPEC-002 v1.1.5 PG-2 requires proxy-layer rate and connection caps before the coordinator WebSocket upgrade on the provider/coordinator surface.
    Why it matters: The production launch gate requires the proxy controls wherever `/ws/provider` is exposed. The checked-in deployment artifact does not provide them, so Pearl deployment could pass this gateway template while leaving PG-2 unimplemented on the coordinator-facing site.
    Recommended fix: Add the PG-2 `limit_req_zone` and `limit_conn_zone` declarations and include/apply the `/ws/provider` location in the coordinator-facing nginx config artifact or runbook that will be deployed with Pearl. Verify with `nginx -t` during deployment.

F-M7. Unknown routes and nginx-denied routes do not use the OpenAI error envelope

    Location: phase5-gateway/internal/router/server.go:95
    Finding: `http.ServeMux` handles unmatched gateway paths with Go's default plain-text 404. The nginx template also returns bare `404` for `/admin/`, `/poolz`, `/healthz`, `/ws/provider`, and the fallback `/`. These errors bypass `writeError`.
    Why it matters: SPEC-006 and the audit prompt require OpenAI-shaped error envelopes on all gateway error responses. Clients and SDK smoke tests can see non-JSON responses for simple typo or denied public-surface paths.
    Recommended fix: Install a final `mux.HandleFunc("/")` that writes `{"error": ...}` for all unmatched gateway paths, and use nginx `error_page` or proxy denied paths to a gateway envelope endpoint if public denied routes must be JSON.

F-M8. Inbound `X-Request-ID` validation accepts non-v4 UUID-shaped strings

    Location: phase5-gateway/internal/router/server.go:1504
    Finding: `isUUIDLike` checks length, dashes, and hex characters only. It does not require UUID version 4 or the RFC 4122 variant bits, even though SPEC-006 § 5.1 says inbound IDs may be accepted only if they are UUID v4.
    Why it matters: D-CROSS-3 depends on request IDs as the cross-service join key. Accepting arbitrary UUID-like buyer input weakens the invariant and can also create avoidable request-id collision behavior because `usage_events.request_id` is globally primary-keyed.
    Recommended fix: Replace `isUUIDLike` with strict UUID-v4 validation (`v[14] == '4'` and variant in `8|9|a|b|A|B`) or always generate a fresh gateway UUID while preserving an inbound ID only as a separate diagnostic field.

## MINOR findings

F-m1. Panic recovery returns an envelope but drops the panic from logs

    Location: phase5-gateway/internal/router/server.go:128
    Finding: The recovery middleware catches panics and returns a JSON error, but does not log the panic value or stack.
    Why it matters: This satisfies the buyer envelope part but leaves production operators without forensic evidence for unexpected handler panics.
    Recommended fix: Log the panic value, request ID, path, and a bounded stack trace before writing the generic envelope.

F-m2. No gateway-local health probe exists

    Location: phase5-gateway/internal/router/server.go:95
    Finding: The gateway exposes `/v1/status`, but there is no lightweight `/healthz` or equivalent local process/DB probe for systemd or a load balancer. The public nginx site explicitly returns 404 for `/healthz`.
    Why it matters: Operators can use `/v1/status`, but it depends on coordinator `/poolz` reachability and is not a minimal "gateway process + storage is alive" probe.
    Recommended fix: Add a loopback-only or nginx-private `/healthz` endpoint that checks process readiness and optionally a cheap DB ping, while keeping coordinator `/healthz` unexposed on `api.streamvc.live`.

## Operator questions surfaced

None.

## Category coverage notes
- Category A, Security pitfalls: SQL statements are parameterized; append-only triggers exist for usage/feedback/audit; HMAC checks use `hmac.Equal`; see F-M5 for XFF trust and F-m1 for partial panic recovery logging.
- Category B, Spec compliance / pre-commitments: D1 storage abstraction and SQLite single-instance posture are present; D2 demo tokens are HMAC/IP/expiry-backed; D3 refund paths exist; see F-C1, F-M2, F-M3, F-M4, and F-M8 for spec deviations.
- Category C, AC honesty: PASS claims for key hashing, revocation, rotation, quota exhaustion, 504 zero completion, provider header stripping, demo-token validation, and status redaction were spot-checked. AC-4 and AC-37 are not honest enough as currently tested; see F-M1 and F-M2.
- Category D, H-002 production invariants: PG-1 is coordinator-side and not bypassed by gateway; PG-2 is missing from the deployment artifact; PG-4 coordinator 4xx handling is normalized for chat errors; PG-5 alerting remains represented by operator capacity signals, not an external alert hook.
- Category E, Tier 1 disclosure: Blocking failure; see F-C1.
- Category F, Operational concerns: Startup validation covers callback allowlist, demo signing secret, and coordinator operator key; graceful shutdown exists; see F-M6, F-M7, and F-m2 for deployment/health gaps.
- Category G, Code quality: Interfaces are migration-friendly and storage tests are meaningful in several places; see F-M2 for a hand-wavy test fixture and F-M4 for missing lifecycle cleanup.

## Verdict
- READY WITH NARROW FIX PASS

The findings are code/config fixes rather than architecture redesign, but Pearl deployment should not proceed before fixing F-C1. After the Tier 1 disclosure is enforced and the major OAuth/accounting/proxy/status issues are addressed or explicitly dispositioned, a narrow static re-audit plus Pearl `nginx -t` / `systemd-analyze verify` dry-run is appropriate.

## Self-verification
- Walked audit categories A through G.
- Each finding has a file:line location.
- Each CRITICAL/MAJOR finding has a concrete recommended fix.
- AC_STATUS PASS claims spot-checked against test bodies: `TestKeyHashStorage`, `TestKeyRevocationLatency`, `TestKeyRotationPreservesHistory`, `TestQuotaSettlement504ZeroCompletion`, `TestStreamingQuotaReservationAndSettlement`, `TestQuotaExhaustionReturns429`, `TestProviderPinningHeadersStripped`, `TestDemoTokenValidation`, `TestOAuthCallbackAllowlist`, and `TestOAuthStateCSRF`.
- Locked operator pre-commitments D1, D2, D3, and D-CROSS-1 through D-CROSS-6 checked at code level; deviations are called out above.
- Tier 1 disclosure surface verified in `/v1/models` handler code and found missing.
- SPEC-001/002/003/006 were read-only during this audit; only this audit report was added.
