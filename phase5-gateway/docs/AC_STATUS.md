# SPEC-006 v0.6 Acceptance Status

Phase E local status as of 2026-05-29. "Automated" means covered by Go tests in this module. "Manual pending" means it needs Pearl, GitHub, SDK, or front-door deployment evidence.

| AC | Status | Evidence / gap |
|---|---|---|
| AC-1 service boundary | Pass | Separate `phase5-gateway` module, binary, systemd template. |
| AC-2 coordinator local binding | Manual pending | nginx/systemd drafts route gateway to loopback coordinator; Pearl `ss` check not run. |
| AC-3 public endpoint allowlist | Partial | `TestPublicEndpointAllowlistDoesNotExposeCoordinatorInternals` blocks coordinator internals; nginx returns JSON 404 for `/admin/`, `/v1/pool/check`, `/poolz`, and fallback routes. `/healthz` is intentionally exposed as a gateway-local probe and `/ws/provider` is PG-2 guarded. nginx live dry run pending. |
| AC-4 GitHub OAuth signup | Partial | Mock OAuth end-to-end issues one-time key with normal callback `code` + `state` only; live GitHub app not tested. |
| AC-5 key hash storage | Pass | `TestKeyHashStorage`. |
| AC-6 OpenAI SDK compatibility | Partial | OpenAI-shaped mock chat flow passes; Python/JS SDK smoke not run. |
| AC-7 streaming | Partial | Streaming relay and reservation behavior are covered; `TestStreamingQuotaReservationAndSettlementUsesDisconnectEstimation` covers the v1 disconnect byte-estimation fallback. Provider-reported cancel actuals require coordinator relay support tracked in AC-37. |
| AC-8 quota enforcement | Pass | `TestQuotaExhaustionReturns429`. |
| AC-9 demo quota | Pass | Demo token issuance/forgery/rate limiting plus chat-token quota: `TestDemoChatQuotaExhaustionIsSeparateFromAccountQuota`. |
| AC-10 concurrency cap | Pass | Storage-backed per-account active request reservations: `TestAccountConcurrencyCap`, `TestConcurrencyReservationCapAndRelease`. |
| AC-11 provider transparency | Pass | Header strip, status redaction, and XFF-spoof rejection tests: `TestProviderPinningHeadersStripped`, `TestStatusRedactionAndPoolzCacheFlush`, `TestClientIPDetectionRejectsForgedXFF`. |
| AC-12 model aggregation | Partial | Gateway forwards coordinator `/v1/models` and injects non-overridable Tier 1 disclosure via `TestModelsResponseIncludesTier1Disclosure`; aggregation remains coordinator-owned and needs live coordinator proof. |
| AC-13 status shape | Pass | `TestStatusRedactionAndPoolzCacheFlush`, `TestDegradedCalculationMatchesFRB1`, `TestModelsResponseIncludesTier1Disclosure`. |
| AC-14 demo-only kill switch | Pass | `TestDemoOnlyKillSwitchPausesDemoOnly`. |
| AC-15 all-public-api kill switch | Pass | `TestKillSwitchPersistsAcrossRestart`. |
| AC-16 capacity Tier 1 | Pass | `TestCapacityTierOneClosesSignupButExistingKeyWorks`. |
| AC-17 capacity Tier 2 | Pass | Tier 1 sustained firing escalates to Tier 2 and halves account quota: `TestCapacityTierTwoHalvesQuotaAndTierThreePauses`. |
| AC-18 capacity Tier 3 | Pass | Budget/provider-drop signal escalates to Tier 3 and pauses all public API: `TestCapacityTierTwoHalvesQuotaAndTierThreePauses`. |
| AC-19 feedback endpoint | Partial | Rating validation and append storage pass; duplicate POST is deduped in summary, not as one stored event. |
| AC-20 dashboard rating widget | Manual pending | Front-door work is out of scope for this module. |
| AC-21 error envelopes | Partial | Main tested errors and unknown gateway routes use OpenAI envelopes via `TestNotFoundReturnsOpenAIEnvelope`; full 400/401/403/404/429/502/503/504 matrix not separately enumerated. |
| AC-22 append-only usage | Pass | SQLite append-only triggers, usage settlement tests, and 24h reservation reclaim via `TestExpiredReservationsReclaimedAfter24h`. |
| AC-23 sub-ms auth lookup | Pass | Storage fixture benchmark test enforces p95 <1 ms. |
| AC-24 front-door migration | Manual pending | Requires deployed Vercel/front-door inspection. |
| AC-25 docs completeness | Partial | Gateway README/runbook complete; front-door docs not updated. |
| AC-26 OAuth callback allowlist | Pass | `TestOAuthCallbackAllowlist` verifies disallowed callbacks are rejected at OAuth start/config time and normal GitHub callbacks do not require a synthetic `redirect_uri` query. |
| AC-27 token revocation latency | Pass | `TestKeyRevocationLatency`. |
| AC-28 kill-switch persistence | Pass | `TestKillSwitchPersistsAcrossRestart`. |
| AC-29 OAuth state CSRF defense | Pass | `TestOAuthStateCSRF`. |
| AC-30 OAuth scope minimization | Pass | `TestOAuthScopeMinimization`. |
| AC-31 key rotation preserves history | Pass | `TestKeyRotationPreservesHistory`. |
| AC-32 capacity tier de-escalation | Pass | `TestCapacityTierDeescalation`. |
| AC-33 feedback summary shape | Pass | `TestFeedbackSummaryAggregation`. |
| AC-34 provider-pinning header strip | Pass | `TestProviderPinningHeadersStripped`. |
| AC-35 demo token forgery rejected | Pass | `TestDemoTokenValidation`. |
| AC-36 quota refund on 504 zero completion | Pass | `TestQuotaSettlement504ZeroCompletion`. |
| AC-37 streaming quota reservation and settlement | Partial | `TestStreamingQuotaReservationAndSettlementUsesDisconnectEstimation` verifies reservation-before-first-byte, prompt plus `ceil(bytes/4)` settlement, and upstream coordinator request cancellation on buyer disconnect. Real WS-tunneled `inference_response_end` carrying cancel `usage` is not relayed to the gateway in v1, so exact cancel actuals remain a coordinator integration follow-up. |

Known launch blockers before production: live GitHub OAuth, live OpenAI SDK smoke, Pearl nginx/systemd verification, and front-door migration/docs checks.
