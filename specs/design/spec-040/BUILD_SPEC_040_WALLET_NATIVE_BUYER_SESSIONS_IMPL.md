# BUILD_SPEC_040_WALLET_NATIVE_BUYER_SESSIONS_IMPL

Implement the v0.1 Ed25519 existing-account agent-session slice of issue #930 against `SPEC-040-wallet-native-buyer-sessions.md` v0.1.8. Do not claim full #930 closure for mainstream wallet algorithms, browser wallet UX, or wallet-only account funding; those require follow-up issue/spec work.

## Target result

Ship a default-off gateway wallet-session rail that lets an existing gateway account authorize a wallet-held bounded buyer session, then use a short-lived `mps_` session bearer plus session-key signatures for inference requests. Usage must settle through existing gateway quota reservations, `usage_events`, settlement journal, coordinator `request_log.external_request_id`, receipts, and billing surfaces. Existing API-key behavior must remain unchanged.

## Required implementation shape

1. Add gateway configuration under `auth.wallet_sessions`:
   - `enabled`
   - fixed bearer prefix `mps_` (not operator-configurable in v0.1)
   - `max_session_ttl_seconds`
   - `max_challenge_ttl_seconds`
   - `max_total_token_cap`
   - `max_per_request_token_cap`
   - `max_active_sessions_per_account`
   - `max_active_sessions_per_wallet`
   - challenge/session issuance limits
   - bounded request-body sizes for challenge and registration
   - `bearer_hash_keys` with key ids and env resolution through the existing secret resolver
   - `current_bearer_hash_key_id`
   - optional previous/retiring bearer hash key ids
   - stable `wallet_fingerprint_secret` with rotation rejected in v0.1
   - request-signature max age and future skew settings.
   - metadata request rate limits and replay row/byte ceilings.

   Startup validation must require wallet-session bearer hash keys and wallet fingerprint secret only when enabled, require at least 256 bits of secret material, reject reuse with API-key/coordinator/OAuth/demo secrets, reject impossible cap/TTL/session-limit/freshness/metadata-limit settings, reject fingerprint-secret rotation in v0.1, reject retirement configs that invalidate unexpired sessions without explicit override, and reject any credential-prefix ambiguity.

2. Add SQLite storage and interfaces for:
   - account-authorized challenges with hashed nonce, purpose, account id, wallet fingerprint, requested caps/expiry/model allowlist/session public key, expiry, and consumed timestamp;
   - wallet identities bound to accounts;
   - wallet sessions with status, expiry, caps, normalized model allowlist, hashed bearer plus key id, wallet fingerprint, raw verification public key as restricted storage, session public key, and revoked metadata;
   - per-session replay records keyed by session id/request id with method, canonical route, semantic headers hash, raw body hash, state, account reservation id, session reservation id, terminal state, and timestamps;
   - session budget reservations and settlement rollup;
   - immutable account/request-to-session mapping used by settlement recovery.

   Implement one `BEGIN IMMEDIATE` or stronger inference-admission primitive that validates session/account state, request signature preconditions, model allowlist, per-request cap, total session exposure, replay state, account quota, and inserts both account and session reservations atomically. Implement one serialized metadata-admission primitive that atomically validates session state, request signature preconditions, replay state, metadata rate limits, and hard replay row/byte ceilings before inserting metadata replay rows. Implement a dispatch-fence primitive that rechecks revocation/expiry/account state and moves replay state from `claimed` to `dispatch_armed` immediately before coordinator dispatch after provisional recovery arming succeeds. Implement idempotent finalize/settle/refund/hold/quarantine/stale-held transitions for both reservations.

3. Add `phase5-gateway/internal/auth` wallet proof and request-signature verification:
   - RFC 8785/JCS canonical proof bytes and request bytes;
   - closed schemas and duplicate JSON field rejection before canonicalization;
   - canonical unpadded base64url validation by decode-and-reencode comparison;
   - integer range checks and float rejection;
   - `ed25519` signature verification using stdlib only;
   - keyed wallet fingerprint derivation;
   - request-signature envelope support for inference, `/v1/models`, and session self-service GET/DELETE routes;
   - deterministic semantic-header profiles for chat, responses, and messages, including canonical `Accept`;
   - UUIDv4-only request-id validation before middleware replacement;
   - timestamp max-age/future-skew validation and replay retention enforcement;
   - fail-closed unsupported algorithms with `wallet_algorithm_unsupported`;
   - no private material, raw public keys, signatures, prompts, outputs, or raw bearers in logs/audits/errors.

4. Add gateway routes:
   - `POST /auth/wallet-sessions/challenges` authenticated by the owning `mp_` API key;
   - `POST /auth/wallet-sessions` authenticated by the owning `mp_` API key plus wallet proof;
   - `GET /auth/wallet-sessions` authenticated by owning `mp_` API key;
   - `GET /auth/wallet-sessions/{session_id}` authenticated by owning `mp_` API key or matching signed `mps_` session;
   - `GET /auth/wallet-sessions/{session_id}/usage` authenticated by owning `mp_` API key or matching signed `mps_` session;
   - `DELETE /auth/wallet-sessions/{session_id}` authenticated by owning `mp_` API key or matching signed `mps_` session.

   Add wallet-session read methods to `router.ReadStore` and storage read interfaces. GET list/status/usage handlers must use `s.readStore()`; POST/DELETE/admission/settlement stay on the write store. All wallet-session routes, session-filtered `/v1/models`, and wallet-session errors containing account/session state must set `Cache-Control: no-store`, `Pragma: no-cache`, and a `Vary` header that includes at least `Authorization` and `X-Api-Key` while preserving existing values such as `Origin`. Browser-visible CORS preflight for mounted wallet-session-capable routes must allow `X-MacProvider-Session-Timestamp` and `X-MacProvider-Session-Signature`. Demo/operator credentials must not create/list/revoke wallet sessions in v0.1.

5. Extend request authentication:
   - parse credential kind explicitly (`mp_` API key vs fixed `mps_` session);
   - session bearer validates separately from API keys;
   - `authenticateAny` returns a usage subject with account id plus optional wallet session id and session key;
   - `/v1/models` may authenticate with signed sessions, must not consume budget, must use empty-body signature semantics, and must filter to the session allowlist;
   - `/v1/chat/completions`, `/v1/responses`, and `/v1/messages` reserve and settle both account quota and session budget for session traffic;
   - `/v1/messages` may keep the existing `X-Api-Key` alias for `mps_`, but all session request-signing requirements still apply.

6. Enforce before coordinator dispatch:
   - owning account active;
   - session expiry/revocation/exhaustion;
   - client-supplied UUIDv4 `X-Request-ID` before middleware replacement;
   - Ed25519 request signature over domain-separated JCS bytes;
   - bearer-resolved session id equals the signed session id;
   - method, canonical route template, raw pre-translation body hash, and semantic header hash binding;
   - replay mismatch/duplicate state machine;
   - normalized model allowlist;
   - per-request cap and total cap using the exact same `reservationTokens` value as account quota;
   - account quota before dispatch;
   - account concurrency after admission, with atomic release of both reservations if concurrency is denied;
   - dispatch fence recheck before coordinator dispatch.

7. Thread session state through settlement:
   - extend `usageSubject`, settlement journal records, recovery lookup, `settleRequest`, `settleAfterCommit`, fallback `EnsureUsageEvent`, refund, hold/quarantine, and reconciliation paths with optional wallet-session fields;
   - add a provisional wallet-session dispatch arm before coordinator dispatch; the provisional arm must not contain guessed final token totals and must recover crashes before final usage by coordinator finality/request-log evidence or hold/quarantine;
   - wallet-session traffic must not fail open to dispatch when provisional recovery arming fails; finalization failure after delivered buyer bytes must stop further delivery where possible and keep account/session exposure held or quarantined through the provisional arm;
   - preserve coordinator semantics by joining gateway `usage_events.(account_id, request_id)` to coordinator `request_log.(account_id, external_request_id)`;
   - keep provider receipt fields, billing arithmetic, payout math, and coordinator request-log semantics unchanged.

8. Add tests:
   - config validation/default-off behavior, secret/prefix collision rejection, bearer hash key rotation, wallet fingerprint secret stability/rotation rejection, timestamp freshness bounds, metadata rate limits, replay row/byte ceilings;
   - local implementation tests for storage migration idempotence, disabled compatibility, enable-after-upgrade, and disable-after-use; release acceptance must separately rehearse fail-closed old-binary rollback against a post-migration DB, successful old-binary startup after snapshot restore when zero post-snapshot rows exist, and the drain/reconciliation gate when post-snapshot traffic exists;
   - account-authorized challenge creation, invalid cap/expiry/allowlist rejection, conflicting body account id rejection, wallet-only registration rejection, challenge expiry, duplicate/parallel challenge redemption, and parallel unique-challenge attempts at active-session caps;
   - successful wallet session creation;
   - invalid signature, duplicate nonce/challenge, wrong audience, unsupported algorithm, malformed canonical JSON, unknown fields, duplicate fields, non-canonical base64url, composed/decomposed Unicode JCS vectors;
   - exact signed-byte/hash test vectors for challenge proof and request signatures;
   - request signature success/failure for chat, responses, messages, `/v1/models`, status, usage, and self-revoke;
   - signed metadata rejects non-empty bodies and query strings; account-key usage detail supports bounded pagination while session self-usage is summary-only;
   - missing/generated request id rejection for session traffic;
   - stale/future timestamp rejection, replay after retention pruning rejection, signed session-id mismatch rejection, parallel metadata replay ceiling enforcement, temporal metadata rate-limit retry metadata, and non-retryable replay-cap exhaustion;
   - expired/revoked/exhausted/wrong-model/per-request-cap rejections before dispatch;
   - replay duplicate same material vs material mismatch, with no double dispatch and no double reservation;
   - concurrent total-cap exhaustion with parallel requests;
   - concurrency denial releases both account and session reservations;
   - revocation race for `claimed` requests that must not advance through the `dispatch_armed` fence after revocation or expiry;
   - settlement updates existing `usage_events` and session usage;
   - provisional dispatch arm failure before coordinator dispatch, crash after dispatch arm before coordinator dispatch, crash after coordinator dispatch before first buyer byte, crash after first streaming byte before final usage, finalization failure after delivered bytes with stop-further-delivery/hold semantics, settle failure, fallback insert, recovery, refund, hold/quarantine, and reconciliation session effects;
   - `/v1/models` session auth filters allowed models without budget consumption and prunes nested supported-model/alias/catalog disclosures outside the allowlist;
   - rate-limited issuance and metadata requests emit envelope/header-aligned retry metadata;
   - status/list/usage/revoke account scoping, self-session access, read-store use for GETs, pagination/range limits, opaque IDs, CORS preflight allowance for session signature headers, CORS Vary preservation, and cross-account/session IDOR rejection;
   - disabled mode: shared mounted routes return `wallet_sessions_disabled` for `mps_` credentials, while unmounted wallet extension endpoints may return normal SPEC-006 404;
   - API-key/demo traffic still succeeds without wallet-session state.

## Non-goals

- Do not add a new dependency for secp256k1/EIP-712 in this implementation.
- Do not add wallet-only account funding/onboarding.
- Do not change provider receipt fields, billing arithmetic, payout math, or coordinator request-log semantics.
- Do not add browser wallet UI.

## Audit gate

Before implementation, rerun the five SPEC review lanes over the full spec/build/governance diff and fix until all lanes report 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.

After implementation, run five review lanes over the full implementation diff as it will land:

- codex code
- codex security
- codex architect
- adversarial verificator
- product-design critic

Fix and re-run until all lanes report 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings. LOW/INFO may be carried only with explicit rationale.
