# Phase 5 Gateway FIX regression audit (Codex, 2026-05-29T06:03:25Z)

Auditor note: `specs/AUDIT_PHASE5_GATEWAY_V2_PROMPT.md` asked for a Claude Code run. This file was produced by Codex in the current workspace, so the model label is kept honest.

## Summary

- 0 CRITICAL findings
- 1 MAJOR finding
- 1 MINOR finding
- Overall verdict: NARROW FIX NEEDED

The FIX commit `7783256` touched the expected 11 files and closes the Tier 1 disclosure, OAuth callback, degraded status, XFF trust, nginx PG-2, 404 envelope, UUID v4 request ID, panic logging, and health probe findings in code. Locked specs were not modified. The main remaining problem is the F-M2/AC-37 evidence: the implementation and cited test do not prove the exact SPEC-006 cancel-usage contract because the actuals branch gets usage from the `/v1/chat/completions/cancel` HTTP response, not from a post-cancel `inference_response_end` on the stream. The reaper also runs hourly but has no configurable interval knob.

## Closure verification (Category A, 11 items)

- F-C1: CLOSED. `/v1/models` injects top-level `tier1_disclosure` after decoding coordinator JSON (`phase5-gateway/internal/router/server.go:405`). `makeTier1Disclosure` returns hardcoded constants only: `version=v0.6`, `plaintext_to_provider=true`, `model_identity=provider_reported`, `hardware_attestation=none`, `tier2_milestone=future` (`phase5-gateway/internal/router/server.go:720`). `TestModelsResponseIncludesTier1Disclosure` proves an upstream disclosure is overwritten (`phase5-gateway/internal/router/server_test.go:136`).
- F-M1: CLOSED. Callback no longer reads a `redirect_uri` query parameter; it consumes stored state and retrieves the redirect URI from storage (`phase5-gateway/internal/router/server.go:186`). State cookie/hash validation remains in place, and the retrieved URI is still checked against `callbackAllowed` before exchange (`phase5-gateway/internal/router/server.go:193`, `phase5-gateway/internal/router/server.go:198`). Startup config still rejects an empty callback allowlist (`phase5-gateway/internal/config/config.go:253`).
- F-M2: PARTIAL. The gateway sends a bounded cancel request (`phase5-gateway/internal/router/server.go:976`) and falls back to byte estimation (`phase5-gateway/internal/router/server.go:969`, `phase5-gateway/internal/router/server.go:973`). However, the actual-usage branch is settled from the cancel endpoint HTTP response (`phase5-gateway/internal/router/server.go:965`, `phase5-gateway/internal/router/server.go:999`), and the cited test returns `{"usage":...}` from `/v1/chat/completions/cancel` (`phase5-gateway/internal/router/server_test.go:553`). It does not exercise a real `inference_response_end` carried after cancel on the stream. See Major M1.
- F-M3: CLOSED. `computeDegraded` implements all FR-B1 predicates: no providers, all unavailable/draining, less than 50% ready, or zero free slots (`phase5-gateway/internal/router/server.go:1249`). `TestDegradedCalculationMatchesFRB1` covers all four positive cases and a negative case (`phase5-gateway/internal/router/server_test.go:345`).
- F-M4: PARTIAL. Storage reclaims active reservations with `expires_at <= now` (`phase5-gateway/internal/storage/sqlite/store.go:743`), `ReserveQuota` reaps before counting active reservations (`phase5-gateway/internal/storage/sqlite/store.go:362`), and main starts a context-cancellable hourly goroutine (`phase5-gateway/cmd/gateway/main.go:49`, `phase5-gateway/cmd/gateway/main.go:79`). `TestExpiredReservationsReclaimedAfter24h` proves a 25h-old reservation no longer blocks quota (`phase5-gateway/internal/storage/sqlite/store_test.go:330`). The only gap is configurability of the hourly interval. See Minor m1.
- F-M5: CLOSED. `clientIP` trusts only `X-Real-IP`, otherwise `RemoteAddr`; it never reads `X-Forwarded-For` (`phase5-gateway/internal/router/server.go:1506`). `TestClientIPDetectionRejectsForgedXFF` covers trusted real IP, forged XFF rejection, and RemoteAddr fallback (`phase5-gateway/internal/router/integration_test.go:394`).
- F-M6: CLOSED. nginx defines `limit_req_zone` and `limit_conn_zone` for `$binary_remote_addr` (`phase5-gateway/dist/nginx-api.streamvc.live.conf:10`) and applies both to `/ws/provider` (`phase5-gateway/dist/nginx-api.streamvc.live.conf:105`). The Pearl runbook calls out PG-2 controls (`phase5-gateway/dist/deploy-pearl-vps.md:15`).
- F-M7: CLOSED. Gateway fallback returns the OpenAI envelope (`phase5-gateway/internal/router/server.go:424`), and nginx returns JSON envelopes for `/admin/`, `/v1/pool/check`, `/poolz`, and fallback routes (`phase5-gateway/dist/nginx-api.streamvc.live.conf:42`, `phase5-gateway/dist/nginx-api.streamvc.live.conf:87`, `phase5-gateway/dist/nginx-api.streamvc.live.conf:117`). Gateway test coverage exists at `TestNotFoundReturnsOpenAIEnvelope` (`phase5-gateway/internal/router/server_test.go:631`); nginx evidence is static config, not a live `nginx -t`.
- F-M8: CLOSED. `isUUIDLike` requires version nibble `4` and RFC variant (`phase5-gateway/internal/router/server.go:1646`), and middleware replaces invalid/non-v4 inbound IDs with generated v4 IDs (`phase5-gateway/internal/router/server.go:122`). Test covers v1/v3/v5 and malformed inputs plus a valid v4 pass-through (`phase5-gateway/internal/router/server_test.go:637`).
- F-m1: CLOSED. Panic recovery logs at `slog.Error` with panic value and stack (`phase5-gateway/internal/router/server.go:133`). Test verifies both `"boom"` and stack text are present (`phase5-gateway/internal/router/server_test.go:667`).
- F-m2: CLOSED. `/healthz` is registered (`phase5-gateway/internal/router/server.go:111`), returns `{"status":"ok"}` after `Ping` succeeds and 503 `{"status":"unavailable"}` on DB failure (`phase5-gateway/internal/router/server.go:410`). It is excluded from public pause handling (`phase5-gateway/internal/router/server.go:1354`) and has both success/failure tests (`phase5-gateway/internal/router/server_test.go:689`, `phase5-gateway/internal/router/server_test.go:709`).

## AC_STATUS.md honesty (Category B)

- AC-3: Honest Partial. `TestPublicEndpointAllowlistDoesNotExposeCoordinatorInternals` exists and checks gateway-internal surfaces do not expose coordinator internals (`phase5-gateway/internal/router/integration_test.go:440`). nginx JSON 404 evidence is static config, and AC_STATUS keeps live dry-run pending (`phase5-gateway/docs/AC_STATUS.md:9`).
- AC-4: Honest Partial. The mock OAuth callback now uses only `code` and `state` (`phase5-gateway/internal/router/integration_test.go:46`), and AC_STATUS correctly leaves live GitHub untested (`phase5-gateway/docs/AC_STATUS.md:10`).
- AC-7: Not fully honest. `TestStreamingQuotaReservationAndSettlement` exists and verifies reservation-before-first-byte plus settlement/fallback (`phase5-gateway/internal/router/server_test.go:541`), but its actuals branch is cancel-response usage, not `inference_response_end` usage. Same root as Major M1.
- AC-11: Honest. Header stripping, status redaction, and forged-XFF rejection tests exist and assert meaningful semantics (`phase5-gateway/internal/router/server_test.go:306`, `phase5-gateway/internal/router/server_test.go:438`, `phase5-gateway/internal/router/integration_test.go:394`).
- AC-12: Honest Partial. The gateway injects disclosure and the test proves non-overridability; AC_STATUS correctly says aggregation remains coordinator-owned (`phase5-gateway/docs/AC_STATUS.md:18`).
- AC-13: Honest. Status redaction and FR-B1 degraded tests exist and assert values, not only shape (`phase5-gateway/internal/router/server_test.go:306`, `phase5-gateway/internal/router/server_test.go:345`).
- AC-21: Honest Partial. Gateway 404 envelope test exists; full matrix is explicitly not claimed (`phase5-gateway/docs/AC_STATUS.md:27`).
- AC-22: Honest. Append-only event tests exist, and the reaper marks reservation rows expired without mutating usage events (`phase5-gateway/internal/storage/sqlite/store_test.go:118`, `phase5-gateway/internal/storage/sqlite/store.go:748`).
- AC-26: Honest. `TestOAuthCallbackAllowlist` rejects disallowed start redirects and accepts a normal callback without a query `redirect_uri` (`phase5-gateway/internal/router/server_test.go:37`).
- AC-37: Not honest enough. AC_STATUS says the cited test exercises the real cancel-request usage path (`phase5-gateway/docs/AC_STATUS.md:43`), but the test does not prove the normative `inference_response_end` path required by SPEC-006 (`specs/SPEC-006-buyer-api.md:1506`). See Major M1.

New/updated test evidence entries:

- `TestModelsResponseIncludesTier1Disclosure`: present and semantic.
- `TestClientIPDetectionRejectsForgedXFF`: present and semantic.
- `TestNotFoundReturnsOpenAIEnvelope`: present for gateway fallback.
- `TestExpiredReservationsReclaimedAfter24h`: present and semantic.
- `TestXRequestIDValidationRejectsNonV4`: present and semantic.
- `TestPanicRecoveryLogsPanicAndReturnsEnvelope`: present and semantic.
- `TestHealthzReturnsOK`: present; failure path is additionally covered by `TestHealthzReturns503WhenDBUnreachable`.

## Regression risk (Category C)

- New bugs introduced: one MAJOR AC/closure bug around F-M2 test/contract mismatch; one MINOR config gap for the reaper interval.
- Reaper safety: The goroutine is context-cancellable on SIGTERM and logs DB errors without crashing (`phase5-gateway/cmd/gateway/main.go:79`). Storage uses a `BEGIN IMMEDIATE` transaction and commits/rolls back cleanly (`phase5-gateway/internal/storage/sqlite/store.go:602`).
- OAuth callback security: Removal of query `redirect_uri` did not weaken CSRF; state hash + session cookie consumption remains one-time, and the stored redirect URI is re-allowlisted before exchange (`phase5-gateway/internal/router/server.go:188`, `phase5-gateway/internal/router/server.go:193`, `phase5-gateway/internal/router/server.go:198`).
- Streaming cancel goroutine cleanup: The watcher and scanner wait are bounded by context or `streaming_cancel_ms`; after fallback the handler returns and closes the upstream body via the existing defer (`phase5-gateway/internal/router/server.go:834`, `phase5-gateway/internal/router/server.go:1002`).
- Error envelopes: New fallback/error paths reviewed in the patch use `writeError` or explicit JSON health bodies; no new plain-text gateway errors found.
- Resource/schema risk: No new DB handles or file handles found. The reaper is idempotent (`UPDATE ... WHERE status = 'active' AND expires_at <= ?`), and migrations were not changed.

## Locked-spec untouched (Category D)

- SPEC-001 diff status: empty.
- SPEC-002 diff status: empty.
- SPEC-003 diff status: empty.
- SPEC-006 diff status: empty.

Verified with `git diff -- specs/SPEC-001-phase3-binary.md specs/SPEC-002-coordinator.md specs/SPEC-003-open-onboarding.md specs/SPEC-006-buyer-api.md`, which produced no output.

## Operator pre-commitment preservation (Category E)

- D1: Preserved. The reaper is process-local scheduling, but state remains SQLite-backed; no new in-process quota/rate state was added.
- D2: Preserved. Demo HMAC logic was not modified by the FIX delta; only IP-source test helpers changed from XFF to `X-Real-IP`.
- D3: Preserved except for the F-M2 proof gap. Existing refund/settlement matrix paths remain in `forwardNonStreamingChat` and `forwardStreamingChat`; provider-unavailable refunds, 504 prompt-only, and estimated fallbacks remain.
- D-CROSS-1: Partially preserved. Byte-estimation fallback remains (`phase5-gateway/internal/router/server.go:973`), but the actuals proof is not the normative `inference_response_end` path. See Major M1.
- D-CROSS-2: Preserved. `/v1/pool/check` remains nginx-denied on the API gateway site and coordinator-owned.
- D-CROSS-3: Preserved/tightened. UUID v4 validation is stricter.
- D-CROSS-4: Preserved. Degraded definition now matches FR-B1.
- D-CROSS-5: Preserved. No tier-coupling change found in the FIX delta.
- D-CROSS-6: Preserved. No logprobs handling change found in the FIX delta.

## CRITICAL findings

No CRITICAL findings.

## MAJOR findings

**M1 - AC-37/F-M2 still does not prove the normative cancel-usage path.**

Severity: MAJOR

Locations:
- `phase5-gateway/internal/router/server.go:964`
- `phase5-gateway/internal/router/server.go:976`
- `phase5-gateway/internal/router/server_test.go:553`
- `phase5-gateway/docs/AC_STATUS.md:43`
- `specs/SPEC-006-buyer-api.md:1506`

What is wrong: SPEC-006 requires the gateway to send a cancel request, then settle actual usage from the provider's `inference_response_end` carrying `usage`. The implementation does have a bounded `waitForCancelUsage(scanner, ...)` path, but it first accepts usage directly from the `/v1/chat/completions/cancel` HTTP response. The cited test's actuals branch only exercises that cancel HTTP response: the mock returns `{"usage":...}` when `r.URL.Path == "/v1/chat/completions/cancel"`, closes the stream after `cancelSeen`, and never emits a post-cancel SSE frame representing `inference_response_end`.

Why it matters: This repeats the AC-honesty class of the original F-M2 issue. The old synthetic-header shortcut is gone, but AC-37 still passes through a test fixture that does not prove the normative wire behavior. A coordinator/provider implementation that only sends usage in `inference_response_end` could regress without this test catching it.

Fix recommendation: Change `TestStreamingQuotaReservationAndSettlement` so the actuals branch returns no usage from the cancel HTTP response, then emits a post-cancel stream event shaped like the coordinator/provider `inference_response_end` carrying `usage`. Assert the gateway waits for that frame and settles to provider-reported actuals. Keep a second branch where the post-cancel frame omits usage and the gateway falls back to byte estimation. Update AC_STATUS to describe the precise evidence.

## MINOR findings

**m1 - Reservation reaper interval is hardcoded, not configurable.**

Severity: MINOR

Locations:
- `phase5-gateway/cmd/gateway/main.go:91`
- `phase5-gateway/internal/config/config.go:110`
- `phase5-gateway/gateway.yaml.example:67`

What is wrong: The V2 regression prompt asks to verify that the quota reservation reaper runs at a configurable interval with a 1h default. The code starts the reaper and uses the correct hourly cadence, but `time.NewTicker(time.Hour)` is hardcoded and there is no config field for a reaper interval.

Why it matters: This does not break the SPEC-006 "within 24 hours" behavior and is not deployment-blocking. It does leave operators without a knob for test/staging acceleration or incident response.

Fix recommendation: Add a small config field such as `timeouts.reservation_reaper_interval_s` or `storage.reservation_reaper_interval_s`, default it to 3600, validate it positive, and pass it into `runReservationReaper`.

## Verdict + rationale

NARROW FIX NEEDED. The 11-patch FIX cycle is mostly sound: the critical Tier 1 disclosure now actually lands, OAuth callback state handling is safer, degraded status matches FR-B1, XFF spoofing is blocked, nginx PG-2 controls and JSON 404 envelopes are present, request IDs are v4-only, panic logs include stack details, and `/healthz` is implemented. Locked specs and operator pre-commitments stayed intact. The remaining blocker is narrow but important: AC-37 still overclaims evidence for the streaming cancel actuals path because the test does not exercise `inference_response_end` usage. Fix that test/implementation proof and optionally make the reaper interval configurable; no design round is needed.

## Self-verification

- [x] Read commit `7783256`'s diff for all 11 patched files.
- [x] Spot-checked each of the 11 F-* findings' code change.
- [x] Verified each of the 10 updated AC_STATUS entries cites a test name that exists and checked whether the body verifies the claim.
- [x] Verified locked specs (SPEC-001/002/003/006) diff is empty.
- [x] Verified operator pre-commitments (D1, D2, D3, D-CROSS-1..6) preserved or explicitly flagged.
- [x] No live tests run.
- [x] No suggestion to modify locked specs.
- [x] Verdict reflects findings count and severity honestly.
