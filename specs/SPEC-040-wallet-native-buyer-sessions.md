# SPEC-040 - Wallet-Native Buyer Sessions

**Version:** 0.1.8
Status: draft
Owner: @Augustas11
Issue: https://github.com/Augustas11/macprovider/issues/930
Audit history: SPEC audit round 1 found blocking account-binding, replay, settlement-recovery, and product-contract gaps. C/H/M findings must be closed before this SPEC is treated as build-ready.

```json
{
  "spec_id": "SPEC-040",
  "title": "Wallet-Native Buyer Sessions",
  "version": "0.1.8",
  "path": "specs/SPEC-040-wallet-native-buyer-sessions.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["wallet-buyer-session"],
  "supersedes": [],
  "depends_on": ["SPEC-005", "SPEC-006", "SPEC-015", "SPEC-022"],
  "implementation_status": "local-validation-pass",
  "production_status": "not-deployed",
  "last_reconciled_commit": "b907cd7e+working-tree",
  "last_reconciled_at": "2026-08-13",
  "evidence": [
    "journeys/evidence/JOURNEY-WALLET-SESSION-LOCAL-VALIDATION-2026-08-13.md"
  ],
  "requirement_id_migration": "complete",
  "gap": {
    "verdict": "PASS_LOCAL",
    "owner": "@Augustas11",
    "issue": "https://github.com/Augustas11/macprovider/issues/930",
    "rationale": "v0.1.8 local implementation validates the default-off Ed25519 existing-account wallet-session rail through gateway storage/router/auth tests, spec governance checks, and local journey evidence. Production deployment, old-binary rollback rehearsal on a released artifact, and PR approval remain separate release gates."
  }
}
```

## 1. Purpose and scope

MacProvider's buyer surface currently assumes a long-lived gateway API key. That works for conventional developers, but autonomous agents and wallet-native applications need a bounded credential they can create from wallet custody and hand to a request loop without granting indefinite account access.

SPEC-040 defines a default-off gateway-enforced buyer session rail:

- an already authenticated gateway account authorizes a wallet challenge for that account;
- the wallet holder signs the gateway-issued challenge and registers a short-lived session key;
- the gateway returns an opaque `mps_` session bearer credential distinct from API keys;
- every session-authenticated route is authenticated by the bearer and by an Ed25519 request signature from the registered session key;
- every session request is checked for expiry, revocation, replay, model allowlist, per-request cap, and total session cap before coordinator dispatch;
- successful usage is written through existing quota reservation, usage_events, settlement journal, coordinator request_log, receipt, and billing paths.

The v0.1 implementation is a **hybrid bridge to the existing quota ledger**, not a prepaid balance ledger. A session limits exposure inside one gateway account and never creates an independent source of accounting truth. API-key traffic remains accepted and semantically unchanged.

In scope for v0.1:

- Gateway-local wallet identities and wallet-session tables.
- Account-owner authorization of wallet challenges using the existing active gateway account credential. Wallet-only onboarding into a new funded account is a separate product protocol and MUST NOT be inferred by this SPEC.
- A dependency-free wallet proof envelope with `ed25519` public-key wallets. v0.1 is an agent-held-key session rail, not a production claim for mainstream browser/EVM wallet UX.
- Session registration from a server-issued signed challenge with nonce, audience, account, expiry, caps, model allowlist, and session public key.
- Opaque gateway-issued `mps_` session bearer credentials with HMAC-hashed storage, status, and revocation.
- Ed25519 per-request signatures from the registered session key over method, canonical route, request id, raw body digest, timestamp, and semantic headers.
- Admission checks for `POST /v1/chat/completions`, `POST /v1/responses`, and `POST /v1/messages` when those endpoints are enabled.
- Buyer-safe session status, usage, list, and revocation endpoints.
- Audit events that identify account, keyed wallet fingerprint, session id, caps, status transitions, and rejection reason without logging raw private material, bearer secrets, prompts, outputs, or raw wallet signatures.

Out of scope for v0.1:

- On-chain balance checks, escrow, token transfers, or prepaid credit accounting.
- Wallet-only creation of a funded gateway account.
- Provider payout formula changes, receipt tuple changes, or separate settlement ledgers.
- Trusting a buyer-supplied model price, token count, or provider selection hint.
- Browser wallet UX, hosted wallet-connect modals, and EIP-712/secp256k1 verification. Those are future wallet-algorithm and product-surface extensions; v0.1 MUST fail closed for them and MUST NOT be marketed as mainstream EVM wallet support.

## 2. Dependencies and authority

- **SPEC-005** owns billing and settlement arithmetic. SPEC-040 MUST NOT change provider credit eligibility, payout math, or billable usage formulas.
- **SPEC-006** owns the buyer API gateway error contract and OpenAI-compatible request/response surface. SPEC-040 consumes that surface and adds session-auth variants.
- **SPEC-015** owns inference receipts. SPEC-040 MUST NOT add wallet or session fields to provider receipts in v0.1.
- **SPEC-022** owns verified model settlement finality. SPEC-040 sessions compose with the existing gateway reservation and settlement journal paths.

SPEC-040 owns the authority domain `wallet-buyer-session`: wallet identity registration semantics, wallet proof envelope, session credential format, session request-signing contract, session cap and replay enforcement, revocation, buyer-safe session status/usage APIs, and the mapping from wallet-session usage to existing account-scoped gateway accounting.

Coordinator changes are out of scope and are a hard v0.1 acceptance criterion. Gateway `usage_events.(account_id, request_id)` MUST reconcile to coordinator `request_log.(account_id, external_request_id)`. SPEC-040 MUST NOT repurpose coordinator `request_log.request_id`, which remains coordinator-generated.

## 3. Terms

| Term | Meaning |
|---|---|
| Wallet identity | A normalized wallet key namespace plus keyed public-key fingerprint owned by one gateway account. |
| Account-authorized challenge | Gateway-issued nonce record created only after validating an owning account credential and binding account, wallet fingerprint, requested caps, expiry, model allowlist, audience, and session public key. |
| Wallet proof envelope | Versioned JCS JSON object signed by the wallet holder, proving the wallet accepted the account-authorized challenge. |
| Session key | A client-held Ed25519 signing key named in the wallet proof and proven on every session request. It binds high-frequency requests to the wallet-authorized session. |
| Session bearer | Gateway-issued opaque `mps_` credential used in `Authorization: Bearer` after registration. It is not an API key and is stored only by HMAC hash. |
| Session cap | The maximum total tokens a wallet session may reserve or settle before it becomes exhausted. |
| Per-request cap | The maximum reservation token count one request may reserve under the session. |
| Replay material | The tuple `(resolved_session_id, request_id, method, canonical_route, semantic_headers_sha256, raw_body_sha256)` authenticated by the session key and stored before dispatch. |

## 4. Normative requirements

### SPEC-040-R001 - Account-authorized challenge and wallet proof registration

The gateway MUST expose account-authorized challenge and registration endpoints:

- `POST /auth/wallet-sessions/challenges`
- `POST /auth/wallet-sessions`

Both endpoints are MacProvider gateway extension endpoints, not OpenAI-compatible inference endpoints.

Challenge creation MUST require an active owning account credential using the existing API-key authentication path. The gateway MUST derive `account_id` from that credential; it MUST reject any request body `account_id` that is absent when required by the schema or conflicts with the authenticated principal. Demo credentials, operator credentials, expired API keys, inactive accounts, and wallet-session bearers MUST NOT create challenges in v0.1.

The challenge endpoint MUST reject non-positive caps, `per_request_token_cap > total_token_cap`, requested expiry beyond `auth.wallet_sessions.max_session_ttl_seconds`, empty model allowlists, unknown models, ambiguous model aliases, malformed wallet/session keys, and request bodies exceeding the configured size limit. The same model canonicalization/catalog lookup MUST be used for challenge storage, inference admission, and `/v1/models` filtering. The gateway MAY accept explicit catalog aliases only when the catalog maps them to the same canonical route model; namespace spoofing and class-alias expansion are forbidden.

The challenge endpoint MUST generate a CSPRNG nonce of at least 128 bits, store only a nonce hash, and bind the nonce to all of the following before returning it:

- authenticated `account_id`;
- wallet namespace and wallet public key fingerprint;
- audience;
- requested expiry;
- per-request token cap;
- total token cap;
- normalized model allowlist;
- session public key;
- purpose `wallet-session-registration-v1`;
- challenge expiry no longer than 5 minutes.

The registration endpoint MUST require the same active owning account credential, derive `account_id` from that credential, verify the wallet proof against the stored challenge, consume the challenge exactly once, bind or confirm the wallet identity for that account, enforce per-account and per-wallet active-session caps, create the wallet session, and mint the session bearer in one transaction. A blocked account, conflicting wallet-to-account binding, revoked wallet identity, consumed challenge, expired challenge, expired proof, unsupported algorithm, active-session cap breach, or inactive account MUST prevent session creation. Parallel redemption attempts for the same challenge MUST yield exactly one created session. Parallel redemption attempts for different valid challenges at the account or wallet active-session cap MUST NOT exceed that cap.

v0.1 MUST support `ed25519` wallet proofs using raw 32-byte public keys encoded as canonical base64url without padding. Unsupported algorithms, including EIP-712/secp256k1 before its implementation lands, MUST fail closed with `wallet_algorithm_unsupported`.

### SPEC-040-R002 - Account binding, authorization, and compatibility

A wallet identity MUST be bound to exactly one gateway account for a given `(wallet_namespace, wallet_fingerprint)`. The first binding and every later session for that wallet identity MUST be authorized by the owning account credential. A wallet signature alone proves wallet custody only; it MUST NOT authorize spending an existing gateway account.

Existing API-key authentication MUST continue to work without requiring any wallet table lookup, wallet header, request signature, or session cap. API keys remain prefixed `mp_`; wallet sessions are fixed to `mps_` in v0.1. The credential parser MUST route by an explicit credential kind and MUST reject ambiguous or multiple credentials. Neither the API-key prefix nor the session prefix may be configured to prefix-match the other.

For `/v1/messages`, the existing `X-Api-Key` compatibility alias MAY carry either an `mp_` API key or an `mps_` session bearer, but an `mps_` bearer MUST still satisfy all wallet-session request-signature and replay rules. API-key behavior on `/v1/chat/completions`, `/v1/responses`, `/v1/messages`, `/v1/models`, and existing auth endpoints MUST be unchanged when wallet sessions are disabled.

### SPEC-040-R003 - Session bearer custody

The gateway MUST mint session bearer credentials with the fixed `mps_` prefix, at least 256 bits of CSPRNG entropy, and no embedded account/session data. The gateway MUST store only HMAC-SHA256 bearer hashes under `auth.wallet_sessions.bearer_hash_keys`, a key-id-indexed secret map loaded through the existing environment secret resolver. `auth.wallet_sessions.current_bearer_hash_key_id` selects the key for new bearers, and previous key ids MAY validate existing sessions until their configured retirement. Every bearer hash secret MUST be at least 256 bits and MUST be distinct from API-key, coordinator, OAuth, demo-token, and wallet-fingerprint secrets. Startup MUST reject missing current keys, duplicate key ids, weak secrets, and retirement configurations that would invalidate unexpired sessions without an explicit operator override.

Bearer comparisons MUST be constant-time after HMAC derivation. The raw bearer MUST be returned only once in the registration response and MUST never appear in URLs, cookies, logs, audit events, panic output, error responses, or metrics labels. All wallet-session routes, all wallet-session errors that include account/session state, and `/v1/models` responses filtered by a session MUST set `Cache-Control: no-store`, `Pragma: no-cache`, and a `Vary` header that includes at least `Authorization` and `X-Api-Key` while preserving existing required members such as `Origin`. Browser-visible CORS preflight for mounted wallet-session-capable routes MUST allow `X-MacProvider-Session-Timestamp` and `X-MacProvider-Session-Signature`.

Session bearers MUST validate through a separate lookup path from API keys so a session cannot be listed, rotated, or treated as a long-lived API key.

### SPEC-040-R004 - Pre-dispatch atomic admission and cap enforcement

For every wallet-session inference request, the gateway MUST reject before coordinator dispatch when any of these checks fails:

- session is expired, revoked, exhausted, or bound to an inactive account;
- request signature is missing, stale, too far in the future, malformed, bound to a different session, or invalid;
- client-supplied `X-Request-ID` is missing or is not UUIDv4;
- request model is not in the session allowlist;
- reservation token count exceeds the session per-request cap;
- cumulative session exposure would exceed the total session cap;
- gateway account daily quota would reject the same request.

Session per-request and total-cap admission MUST use the same reservation token count as existing account quota admission for that entrypoint, including prompt headroom and maximum output tokens. Session exposure is settled session usage plus every unsettled/nonterminal session reservation not conclusively refunded, including active, pending, held, quarantined, stale-held, and recovery-pending effects. Settled reservations that are already represented in settled usage MUST NOT be counted a second time. The wallet-session allowlist MUST be checked against the same canonical route model IDs produced by challenge creation; `/v1/models` filtering MUST use that same representation.

The gateway MUST implement one serialized storage primitive for session inference admission, backed by SQLite `BEGIN IMMEDIATE` or stronger. That primitive MUST validate session/account state, validate replay material, insert or reuse the replay record, insert the account quota reservation, insert the session reservation, and return a claimed-but-not-dispatched decision atomically. Revocation MUST serialize against this primitive. Later account concurrency failure MUST release both the account reservation and the session reservation atomically before dispatch.

### SPEC-040-R005 - Request signing, replay, and idempotency

Every route authenticated by an `mps_` session bearer MUST require:

- `Authorization: Bearer mps_...` or, for `/v1/messages` compatibility only, `X-Api-Key: mps_...`;
- a client-supplied UUIDv4 `X-Request-ID` before gateway request-id middleware replacement;
- `X-MacProvider-Session-Timestamp`;
- `X-MacProvider-Session-Signature`.

The request signature MUST be Ed25519 over a domain-separated JCS object with a closed field set:

```json
{
  "version": "wallet-session-request-v1",
  "session_id": "ws_...",
  "method": "POST",
  "canonical_route": "/v1/chat/completions",
  "request_id": "12121212-1212-4212-8212-121212121212",
  "raw_body_sha256": "<base64url sha256>",
  "semantic_headers_sha256": "<base64url sha256>",
  "timestamp_unix": 1782863990
}
```

`signed.session_id` MUST equal the session id resolved from the bearer before signature, replay, or admission processing. Replay and accounting MUST key exclusively by the bearer-resolved session identity. Reusing one session public key across two sessions MUST NOT allow cross-session replay.

`canonical_route` is the normalized public route template, not a raw path with untrusted path traversal:

- `/v1/chat/completions`
- `/v1/responses`
- `/v1/messages`
- `/v1/models`
- `/auth/wallet-sessions/{session_id}`
- `/auth/wallet-sessions/{session_id}/usage`

Session self-service is allowed only for the bearer-resolved session id; therefore the `{session_id}` path parameter MUST equal the bearer-resolved session id and `signed.session_id`. Account-key management routes do not require session signatures. `GET /auth/wallet-sessions` is account-key-only in v0.1 and MUST NOT accept `mps_` bearers. `POST /auth/wallet-sessions/challenges` and `POST /auth/wallet-sessions` are account-key-authenticated registration routes and do not use the session-signature envelope.

`raw_body_sha256` is computed over the pre-translation HTTP request body bytes. Signed metadata routes (`GET /v1/models`, self status, self usage, and self revoke) MUST reject non-empty request bodies; their body hash is SHA-256 of the empty byte string. Query strings are forbidden on `mps_` self-service and `/v1/models` routes in v0.1; signed self-usage is summary-only. Paginated account-key list/usage may use query parameters because those routes are not session-authenticated. `X-MacProvider-Session-Timestamp` MUST equal `timestamp_unix` in the signed object. Default freshness is max age 300 seconds and max future skew 30 seconds, configurable only to a stricter value in production. Requests outside the freshness window fail with `wallet_session_signature_stale`. Replay records MUST be retained for at least the active session lifetime plus the settlement recovery window; if a deployment cannot prove retention for a session, it MUST reject that session's signed requests rather than prune replay rows early.

`semantic_headers_sha256` uses the v0.1 header profile below. The canonical byte grammar is a UTF-8 sequence of `lowercase-name ":" single-value "\n"` records sorted by lowercase name. Optional whitespace around values is trimmed; internal whitespace is preserved; repeated headers in the signed profile are rejected; covered headers absent from the request are omitted. Headers not in the profile are not signed, except any behavior-affecting header added later MUST be added to this profile before it can affect wallet-session traffic. Authorization, cookies, bearer values, and signatures MUST NOT be included.

| Route | Covered semantic headers |
|---|---|
| `/v1/chat/completions` | `accept`, `idempotency-key`, `x-macprovider-conversation`, `x-macprovider-retry` |
| `/v1/responses` | `accept`, `idempotency-key`, `x-macprovider-conversation`, `x-macprovider-retry` |
| `/v1/messages` | `accept`, `anthropic-version`, `anthropic-beta`, `idempotency-key`, `x-macprovider-conversation`, `x-macprovider-retry` |
| `/v1/models` | none |
| `/auth/wallet-sessions/{session_id}` | none |
| `/auth/wallet-sessions/{session_id}/usage` | none |

The gateway MUST store replay material before dispatch with state `claimed`. A replay record may move only through `claimed`, `dispatch_armed`, `dispatched`, and one terminal state. Exactly one dispatch owner is allowed. A duplicate with different replay material MUST return `wallet_session_replay_mismatch` before any reservation. A duplicate with identical replay material while the first request is in flight, or after a terminal state when no stored response replay exists, MUST return `wallet_session_duplicate_request` without dispatch and without a new reservation. v0.1 does not require response replay caching. Signed management/model requests use the same request-id replay table but create no budget reservation and have terminal state `metadata_only`.

Signed metadata/model requests MUST use one serialized metadata-admission transaction that atomically validates session state, signature freshness, replay material, per-session/account/IP metadata rate limits, and hard per-session replay-row/byte ceilings before inserting the metadata replay row. Temporal metadata throttling MUST return `wallet_session_rate_limited` with valid retry metadata. Hard replay-row/byte ceiling exhaustion MUST return `wallet_session_replay_capacity_exhausted`, is not retryable for the same session, and MUST NOT prune live replay protection.

Wallet-session traffic MUST NOT use idless dedupe that adopts a gateway-generated request id. Missing or invalid client request ids MUST fail before account or session reservation.

### SPEC-040-R006 - Settlement composition and recovery

Wallet-session usage MUST settle into the existing account-scoped quota reservation, `usage_events`, settlement journal, coordinator `request_log`, receipt, and billing surfaces. The authoritative billable join remains gateway `usage_events.(account_id, request_id)` to coordinator `request_log.(account_id, external_request_id)`.

The gateway MUST persist an immutable account/request-to-session mapping before dispatch. Settlement journal records, settlement recovery, `settleRequest`, `settleAfterCommit`, fallback `EnsureUsageEvent`, refund, hold/quarantine, and reconciliation paths MUST carry `session_id`, session reservation tokens, and the intended session effect when a request used a wallet session.

Before coordinator dispatch, the gateway MUST durably create a provisional wallet-session dispatch arm in the journal or an equivalent transactionally recoverable table. This provisional arm records reservation identity, session identity, route, request id, dispatch timestamp, and recovery policy, but not final token totals or outcome. It covers recovery from `dispatch_armed` through finalization, including crashes before coordinator dispatch and the post-dispatch/pre-final-usage window. If provisional arming fails, the gateway MUST NOT dispatch; it MUST refund/release both account and session reservations. After usage is known, finalization MUST atomically write or link the authoritative usage event and move the provisional arm to a terminal finalized, refunded, or held/quarantined state. Finalization failure after buyer bytes have already been delivered MUST stop further delivery when possible and MUST durably keep both account and session exposure held/quarantined through the existing provisional arm; it cannot retract bytes already delivered and MUST NOT refund/reopen session exposure unless reconciliation proves no billable work occurred. Recovery of an unfinalized provisional arm MUST NOT guess token totals; it MUST reconcile through coordinator finality/request-log evidence when available or keep both account and session exposure held/quarantined until an operator or automated reconciler resolves it. Existing API-key traffic may keep its current fail-open journal behavior; wallet-session traffic may not.

Account reservation and session reservation transitions MUST be idempotent and transactionally consistent for settle, refund, and hold effects. Cap calculations MUST include settled session usage plus every reservation not conclusively refunded, including active, pending, held, quarantined, stale-held, and recovery-pending effects. A crash after bytes are delivered MUST NOT reopen session budget without a matching account usage event, and a crash before dispatch MUST NOT permanently consume session budget without a recoverable account/session hold or refund path.

Session state MAY store a session-local usage rollup, but that rollup MUST be derived from or reconciled with gateway usage rows and MUST NOT become a parallel billable ledger.

### SPEC-040-R007 - Revocation and expiry

The gateway MUST expose buyer-safe revocation for a wallet session and MUST make revocation effective for the next request without waiting for cache expiry. Revocation MUST serialize with admission and dispatch fencing. The authorization and dispatch linearization point is the transaction that successfully creates the provisional dispatch arm and moves replay state from `claimed` to `dispatch_armed`; that transaction MUST recheck session status, expiry, account status, and reservation state. A request already in `dispatch_armed` MAY proceed to coordinator dispatch and then move to `dispatched` for recovery observation even if revocation commits after that linearization point. After revocation commits, no later `claimed` record may become `dispatch_armed`.

Already `dispatch_armed` or `dispatched` requests MAY complete under their existing account/session reservations, but still-`claimed` requests MUST be canceled and both reservations refunded or held without coordinator dispatch after revocation or expiry. Expired sessions MUST be excluded from new admission even if replay material was previously claimed but not dispatched. Expired challenge and session records MAY be pruned only after their recovery windows have elapsed.

### SPEC-040-R008 - Buyer-safe status, usage, and management APIs

The gateway MUST expose this endpoint matrix:

| Endpoint | Auth | Purpose | Budget consumption |
|---|---|---|---|
| `POST /auth/wallet-sessions/challenges` | owning `mp_` API key | Create an account-authorized challenge | none |
| `POST /auth/wallet-sessions` | owning `mp_` API key plus wallet proof | Mint one session bearer | none |
| `GET /auth/wallet-sessions` | owning `mp_` API key only | List sessions for the authenticated account | none |
| `GET /auth/wallet-sessions/{session_id}` | owning `mp_` API key or matching signed `mps_` session | Status for one account-owned/self session | none |
| `GET /auth/wallet-sessions/{session_id}/usage` | owning `mp_` API key or matching signed `mps_` session | Safe usage summary/detail for account keys; summary-only for session self-service | none |
| `DELETE /auth/wallet-sessions/{session_id}` | owning `mp_` API key or matching signed `mps_` session | Revoke one account-owned/self session | none |
| `GET /v1/models` | `mp_` API key, demo credential, or valid signed `mps_` session | Model discovery; sessions see only allowed models | none |
| inference endpoints | `mp_` API key, demo credential, or valid signed `mps_` session | Paid inference | account/session reservations for sessions |

Demo credentials and operator credentials MUST NOT inspect, list, create, or revoke wallet sessions unless a later SPEC explicitly grants that authority. All management storage queries MUST be account-scoped, and session-bearer self-service MUST reject cross-session IDs.

List responses MUST include session ids, status, expiry, caps, remaining budget, allowed models, created/revoked timestamps, aggregate usage, and a cursor when more rows exist. Status responses MUST include one session's status, expiry, caps, remaining budget, allowed models, created/revoked timestamps, and aggregate usage. Account-key usage detail responses MUST use cursor/limit pagination with a maximum page size no greater than 100 and bounded time ranges; they MUST include request ids, usage event ids when available, quota reservation ids when available, session reservation ids, model, token counts, terminal status, timestamps, and reconciliation status. Session self-usage responses are summary-only in v0.1 and MUST NOT accept pagination query parameters. IDs returned to buyers MUST be opaque and type-scoped; raw database rowids MUST NOT be exposed. `/v1/models` session filtering MUST prune every nested model identifier, alias, supported-model list, catalog disclosure, and metadata field that would reveal a model outside the session's canonical allowlist. Responses MUST NOT expose bearer hashes, raw bearer credentials, wallet private material, raw prompts, raw outputs, provider receipt signatures, or unrelated account sessions.

### SPEC-040-R009 - Error contract, observability, and privacy

Session failures MUST use the SPEC-006 error envelope with stable machine-readable codes. The v0.1 wallet-session error table is normative:

| Code | HTTP | Retryable | Safe message | Agent remediation |
|---|---:|---|---|---|
| `wallet_sessions_disabled` | 404 | no | Wallet sessions are not enabled. | Use an API key or target a gateway with the feature enabled. |
| `wallet_account_auth_required` | 401 | no | An owning account credential is required. | Authenticate challenge/registration with the account API key. |
| `wallet_account_mismatch` | 403 | no | Wallet request does not match the authenticated account. | Use the account that created the challenge. |
| `invalid_wallet_session` | 401 | no | Invalid wallet session. | Use the issued `mps_` bearer exactly as returned, or create a new session. |
| `wallet_algorithm_unsupported` | 400 | no | Wallet algorithm is not supported by this gateway. | Use Ed25519 v0.1 or wait for the algorithm extension. |
| `wallet_canonical_invalid` | 400 | no | Wallet-session request is invalid. | Rebuild canonical JSON, base64url, semantic headers, and signed-byte material. |
| `wallet_challenge_expired` | 400 | no | Wallet challenge expired. | Request a new challenge. |
| `wallet_challenge_consumed` | 409 | no | Wallet challenge was already used. | Request a new challenge; investigate duplicate clients. |
| `wallet_identity_conflict` | 403 | no | Wallet identity cannot be used with this account. | Use the account that owns the wallet identity or register a different wallet identity. |
| `wallet_signature_invalid` | 401 | no | Wallet signature invalid. | Recompute challenge proof canonical bytes and sign with the wallet key. |
| `wallet_session_signature_invalid` | 401 | no | Wallet-session signature is invalid. | Recompute request canonical bytes and sign with the session key. |
| `wallet_session_signature_stale` | 401 | no | Wallet-session signature timestamp is outside the allowed window. | Re-sign the same request with current server-aligned time. |
| `wallet_session_active_cap_exceeded` | 409 | no | Wallet-session active cap exceeded. | Revoke an old active session or wait for expiry before creating another session. |
| `wallet_session_body_forbidden` | 400 | no | Wallet-session metadata requests do not accept bodies. | Send signed metadata requests without a body or query string unless the endpoint explicitly allows it. |
| `wallet_session_cap_invalid` | 400 | no | Wallet-session caps are invalid. | Request caps within gateway-configured bounds. |
| `wallet_session_challenge_failed` | 400 | no | Wallet-session challenge request failed. | Correct challenge account, model, expiry, and cap inputs. |
| `wallet_session_expiry_invalid` | 400 | no | Wallet-session expiry is invalid. | Choose an expiry after the current time and within the maximum session TTL. |
| `wallet_session_expired` | 401 | no | Wallet session expired. | Create a new bounded session. |
| `wallet_session_inactive` | 401 | no | Wallet session is inactive. | Create or select an active session. |
| `wallet_session_revoked` | 401 | no | Wallet session was revoked. | Create or select a valid session. |
| `wallet_session_exhausted` | 402 | no | Wallet session budget is exhausted. | Create a new session with budget or reduce usage. |
| `wallet_session_model_not_allowed` | 403 | no | Model is not allowed for this wallet session. | Use an allowed model or create a session with a different allowlist. |
| `wallet_session_not_found` | 404 | no | Wallet session not found. | Use an account-owned session id or create a new session. |
| `wallet_session_scope_mismatch` | 403 | no | Wallet session does not match the signed request scope. | Sign the route for the same session id and endpoint being accessed. |
| `wallet_session_query_forbidden` | 400 | no | Wallet-session signed metadata request does not accept query parameters. | Move pagination to account-key usage detail or sign the exact no-query self-service path. |
| `wallet_session_request_cap_exceeded` | 400 | no | Request exceeds this session's per-request cap. | Reduce max tokens or create a larger session. |
| `wallet_session_request_id_required` | 400 | no | Wallet-session requests require a client request id. | Send UUIDv4 `X-Request-ID`. |
| `wallet_session_replay_mismatch` | 409 | no | Request id was reused with different signed material. | Generate a new request id for different content. |
| `wallet_session_duplicate_request` | 409 | no | Request id is already in use for this session. | Wait for the first request or query usage/status. |
| `wallet_session_rate_limited` | 429 | yes | Wallet-session request rate limit reached. | Back off until the `Retry-After` or `X-RateLimit-Reset` value emitted by the relevant limiter. |
| `wallet_session_replay_capacity_exhausted` | 409 | no | Wallet-session replay capacity is exhausted. | Create a new session or wait for this session to expire and prune. |
| `wallet_session_storage_conflict` | 409 | yes | Wallet-session state changed concurrently. | Retry with fresh state. |
| `wallet_session_admission_failed` | 500 | no | Wallet-session admission failed. | Treat as gateway failure; retry only after operator health recovers. |
| `wallet_session_issuance_failed` | 500 | no | Could not create wallet session. | Treat as gateway failure; retry only after operator health recovers. |
| `wallet_session_load_failed` | 500 | no | Could not load wallet sessions. | Treat as gateway failure; retry only after operator health recovers. |
| `wallet_session_lookup_failed` | 500 | no | Could not validate wallet session. | Treat as gateway failure; retry only after operator health recovers. |
| `wallet_session_store_failed` | 500 | no | Wallet-session store failed. | Treat as gateway failure; retry only after operator health recovers. |

Audit events MUST be emitted for challenge creation, session creation, rejection, revocation, expiry, replay rejection, cap exhaustion, and settlement reconciliation failure. Audit payloads MUST include reason codes and identifiers sufficient for operator reconciliation without logging bearer secrets, raw wallet signatures, prompts, outputs, or raw public keys.

`wallet_session_rate_limited` MUST include either positive `Retry-After` seconds or `X-RateLimit-Reset` epoch seconds, and the SPEC-006 envelope retry metadata MUST agree with that header.

Wallet fingerprints in audit and status surfaces MUST be keyed pseudonyms: HMAC over `(wallet_namespace, wallet_public_key)` using `auth.wallet_sessions.wallet_fingerprint_secret`, a stable dedicated secret distinct from bearer-hash and other operator secrets. Fingerprint-secret rotation is forbidden in v0.1. Raw wallet public keys MAY be stored only in restricted gateway storage for verification and MUST NOT appear in buyer-visible responses unless a later privacy review allows it.

### SPEC-040-R010 - Configuration, abuse bounds, migration safety, and evidence gate

Wallet sessions MUST be default-off unless `auth.wallet_sessions.enabled` is true. Gateway startup validation MUST require bearer hash keys and wallet fingerprint secret only when the feature is enabled, reject impossible cap/TTL/session-count/freshness settings, reject weak or reused secrets, and reject prefix collisions. v0.1 uses fixed bearer prefix `mps_`.

The gateway MUST enforce bounded request sizes for challenge/registration bodies, per-IP and per-account/per-wallet issuance rate limits, per-session/account/IP metadata request rate limits, hard per-session replay-record/byte ceilings, maximum active sessions per account and wallet identity, short challenge expiry, request-signature freshness, and pruning of expired challenges/sessions/replay records after recovery windows. These bounds MUST be configurable with safe defaults.

Schema-only additive migrations MAY run while wallet sessions are disabled, but this SPEC does not require old binaries to open a database after the new binary stamps an unknown `schema_migrations` version. The accepted rollback posture is fail-closed old-binary startup plus operator restore from the pre-deploy database snapshot only before any post-snapshot buyer/auth/money-path traffic is served. If post-snapshot traffic has occurred, rollback requires maintenance/drain plus preservation and reconciliation of every post-snapshot gateway effect before the old binary may serve traffic. Disabled runtime mode MUST mount no wallet-session creation/list/status/usage/revoke routes. Existing shared routes that are still mounted, such as inference and `/v1/models`, MUST return `wallet_sessions_disabled` when presented with an `mps_` credential while the feature is disabled; unmounted wallet-session extension endpoints MAY return the gateway's normal SPEC-006 404. Disabled mode MUST NOT require wallet-session secrets and MUST leave API-key, demo, quota, settlement, and existing auth behavior unchanged. Local implementation evidence MUST cover fresh disabled startup, enable-after-upgrade, disable-after-use, and idempotent migration reruns. Release acceptance evidence MUST additionally cover fail-closed old-binary rollback against a post-migration DB, successful old-binary startup after snapshot restore with zero post-snapshot rows, and the drain/reconciliation gate when post-snapshot traffic exists.

Promotion out of draft MUST include signed journey results for account-authorized registration, signed inference admission and metadata access, concurrent cap enforcement, revocation race, settlement recovery, status/usage IDOR resistance, and disabled-mode coexistence. Five-lane audit must report 0 Critical, 0 High, and 0 Medium findings before implementation can be treated as accepted.

## 5. Product and algorithm gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| EIP-712/secp256k1 wallet support | OUT_OF_SCOPE_V0_1 | @Augustas11 | https://github.com/Augustas11/macprovider/issues/930 | Follow-up SPEC must decide dependency placement, chain namespace, address derivation, EIP-712 typed data, and wallet UX. |
| Production browser wallet UX | OUT_OF_SCOPE_V0_1 | @Augustas11 | https://github.com/Augustas11/macprovider/issues/930 | Browser/app product flow and wallet-provider support matrix. |
| Wallet-only account funding/onboarding | OUT_OF_SCOPE_V0_1 | @Augustas11 | https://github.com/Augustas11/macprovider/issues/930 | Separate account-claim/funding protocol that cannot target an existing account without account authority. |

## 6. Evidence

Local automated evidence is captured in `journeys/evidence/JOURNEY-WALLET-SESSION-LOCAL-VALIDATION-2026-08-13.md`.

Validated locally on 2026-08-13:

- `go test ./... -count=1` from `phase5-gateway`.
- `go test ./internal/storage/sqlite -run 'Wallet(Session|Registration|Reaper|Stale|Seal)' -count=1` from `phase5-gateway`.
- `go test ./internal/router -run 'WalletSession|GatewayErrorCodeCompleteness' -count=1` from `phase5-gateway`.
- `python3 scripts/check_spec_governance.py`.
- `python3 scripts/gen_spec_index.py --check`.
- `git diff --check`.

This evidence covers account-authorized challenge creation, session creation, canonical proof verification, request signatures, cap enforcement, expiry, replay rejection, revocation, `/v1/models` nested filtering, status/usage authorization, API-key coexistence, gateway money-path settlement into existing `usage_events`, and wallet-session settlement recovery/reconciliation paths. Production deployment, released-old-binary rollback rehearsal, and PR approval remain out of scope for this local implementation pass.

## 7. Current contract notes

The first implementation intentionally chooses signed reservations over prepaid credits: a wallet authorizes bounded exposure inside an already owned gateway account, the gateway reserves account quota and session budget atomically, and delivered usage settles through the existing ledger. This preserves reconciliation because the authoritative billable record remains gateway `usage_events.(account_id, request_id)` joined to coordinator `request_log.(account_id, external_request_id)`.

Wallet proof and request-signature objects use RFC 8785 JSON Canonicalization Scheme (JCS), matching the repository's existing signed-receipt canonicalization posture. Implementations MUST use closed schemas; reject unknown fields; reject duplicate JSON object names before canonicalization; define all integer fields as signed-free decimal JSON numbers within `int64` bounds; reject floats; preserve decoded Unicode strings exactly as JCS specifies without NFC/NFD transformation; and require canonical unpadded base64url by decode-and-reencode comparison. Test vectors MUST include composed and decomposed Unicode strings when a signed field can contain non-ASCII.

The wallet proof signed object has this exact closed field set:

```json
{
  "version": "wallet-session-proof-v1",
  "challenge_id": "wch_...",
  "aud": "https://api.malibu.tech",
  "account_id": "acct_...",
  "wallet_namespace": "ed25519",
  "wallet_public_key": "<base64url raw public key>",
  "session_public_key": "<base64url raw public key>",
  "nonce": "<base64url server nonce>",
  "expires_at_unix": 1782864000,
  "per_request_token_cap": 512,
  "total_token_cap": 5000,
  "model_allowlist": ["llama"]
}
```

The registration body transports `wallet_signature` outside the signed object. The session request body transports `X-MacProvider-Session-Signature` outside the signed object. Test vectors MUST include the exact signed bytes for one challenge and one request.

Challenge creation request wrapper, challenge response wrapper, registration request wrapper, and registration response wrapper are also closed schemas. Unknown fields MUST be rejected. Stored challenge values are authoritative; unsigned wrapper fields in the registration request MUST NOT override the stored account, caps, expiry, model allowlist, wallet key, session key, audience, or nonce.

Challenge request example:

```json
{
  "wallet_namespace": "ed25519",
  "wallet_public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  "session_public_key": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
  "expires_at_unix": 1782864000,
  "per_request_token_cap": 512,
  "total_token_cap": 5000,
  "model_allowlist": ["llama"]
}
```

Challenge response example:

```json
{
  "challenge_id": "wch_01HZX6Y7K4C2Q9E6J8Q0V7Z2PF",
  "aud": "https://api.malibu.tech",
  "account_id": "acct_example",
  "nonce": "AQIDBAUGBwgJCgsMDQ4PEA",
  "expires_at_unix": 1782864000,
  "challenge_expires_at_unix": 1782863400,
  "proof_version": "wallet-session-proof-v1",
  "model_allowlist": ["llama"]
}
```

Registration request example:

```json
{
  "proof": {
    "version": "wallet-session-proof-v1",
    "challenge_id": "wch_01HZX6Y7K4C2Q9E6J8Q0V7Z2PF",
    "aud": "https://api.malibu.tech",
    "account_id": "acct_example",
    "wallet_namespace": "ed25519",
    "wallet_public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "session_public_key": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    "nonce": "AQIDBAUGBwgJCgsMDQ4PEA",
    "expires_at_unix": 1782864000,
    "per_request_token_cap": 512,
    "total_token_cap": 5000,
    "model_allowlist": ["llama"]
  },
  "wallet_signature": "<base64url ed25519 signature>"
}
```

Registration response example:

```json
{
  "session_id": "ws_01HZX72GJQYQE5Y7P1S2X4K6MN",
  "session_bearer": "mps_<returned-once>",
  "expires_at_unix": 1782864000,
  "per_request_token_cap": 512,
  "total_token_cap": 5000,
  "model_allowlist": ["llama"]
}
```

Signed inference header example:

```http
POST /v1/chat/completions
Authorization: Bearer mps_<redacted>
X-Request-ID: 12121212-1212-4212-8212-121212121212
X-MacProvider-Session-Timestamp: 1782863990
X-MacProvider-Session-Signature: <base64url ed25519 signature>
```

The implementation MUST add deterministic test vectors containing the exact JCS signed bytes and SHA-256 digests for the registration proof and the signed inference request above, after replacing placeholder keys/signatures with generated fixture keys.

## 8. Changelog and history

- 0.1.8 - Split active-session cap errors from budget exhaustion and aligned wallet identity conflict remediation with cross-account binding semantics.
- 0.1.7 - Clarified rollback evidence boundaries: local implementation validates disabled and additive-migration behavior, while released-old-binary rollback rehearsal remains a release acceptance gate.
- 0.1.6 - Recorded local implementation evidence, pending signed journey promotion, and remaining production/non-deployment gates.
- 0.1.5 - Closed Low audit clarifications: provisional dispatch arms cover `dispatch_armed` through finalization, and CORS preflight must allow wallet-session signature headers.
- 0.1.4 - Closed final SPEC audit C/H/M gaps: `claimed -> dispatch_armed` linearization, post-delivery finalization hold semantics, serialized metadata admission, and non-retryable replay-capacity exhaustion.
- 0.1.3 - Closed SPEC audit round 3 C/H/M gaps: provisional pre-dispatch recovery arm, post-snapshot rollback drain/reconciliation, signed `Accept`, RFC 8785 Unicode preservation, metadata replay ceilings, disabled-mode routing, summary-only session self-usage, nested `/v1/models` pruning, rate-limit backoff headers, and corrected journey mappings.
- 0.1.2 - Closed SPEC audit round 2 C/H/M gaps: signed metadata routes, deterministic semantic-header grammar, dispatch fence after revocation, wallet-session journal-arm semantics, rollback snapshot posture, request freshness/retention, retryability, key rotation config, R001 journey mapping, and closed wire examples.
- 0.1.1 - Closed SPEC audit round 1 C/H/M design gaps: account-authorized challenge, request signatures, JCS canonicalization, atomic admission, session-aware settlement recovery, endpoint/error matrices, fixed prefix/secret custody, migration semantics, authority graph, and signed journey gates.
- 0.1.0 - Drafted for issue #930. Chooses gateway-local signed sessions bridged to existing quota/usage/billing ledgers; `ed25519` proof support is v0.1, EIP-712/secp256k1 remains an explicit gap.
