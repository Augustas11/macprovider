# SPEC-041 - Relay-Blind Request Encryption

**Version:** 0.2.0
Status: draft
Owner: @Augustas11
Issue: https://github.com/Augustas11/macprovider/issues/928
Audit history: v0.2.0 reconciles the default-off pilot contract before full implementation. It does not promote conformance or production deployment.

```json
{
  "spec_id": "SPEC-041",
  "title": "Relay-Blind Request Encryption",
  "version": "0.2.0",
  "path": "specs/SPEC-041-relay-blind-request-encryption.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["relay-blind-request-encryption"],
  "supersedes": [],
  "depends_on": ["SPEC-001", "SPEC-002", "SPEC-003", "SPEC-005", "SPEC-006", "SPEC-008", "SPEC-015", "SPEC-022", "SPEC-040"],
  "implementation_status": "pending-reconciliation",
  "production_status": "not-deployed",
  "last_reconciled_commit": null,
  "last_reconciled_at": null,
  "evidence": [],
  "requirement_id_migration": "complete",
  "gap": {
    "verdict": "DECISION_REQUIRED",
    "owner": "@Augustas11",
    "issue": "https://github.com/Augustas11/macprovider/issues/928",
    "rationale": "The default-off global-pool pilot has local implementation and test evidence. Promotion still requires independently trusted deployment journey evidence, full readiness reconciliation, and production activation evidence; local ephemeral test signatures do not satisfy those gates. See audits/privacy-pool-v01-implementation.md."
  }
}
```

## 1. Purpose, scope, and claims

SPEC-041 defines a default-off `chat_completions` pilot in which a buyer encrypts request content for one selected provider before the request reaches the gateway or coordinator. The gateway and coordinator still see buyer authentication, model, caps, routing bindings, request identifiers, ciphertext size, status, settlement metadata, and the provider response. The provider reads the decrypted request. The required buyer-facing scope string is:

`request_content_hidden_from_relays; provider_reads_request; responses_visible_to_relays`

The pilot MUST NOT be called end-to-end encryption, confidential compute, private from the provider, anonymous routing, unlinkable settlement, or proof that the provider did not retain plaintext. SPEC-008 provider-leg encryption remains a separate `coordinator_to_provider_only` property.

Successful v0.1 pilot execution is limited to the global pool and `chat_completions`. Required relay-blind requests for `responses` or `messages` are unsupported. Any nonempty pool selection, including a pool whose policy requires relay-blind mode, MUST be rejected before reservation, quota, or dispatch under SPEC-042-R009. This SPEC does not activate a production Trusted Pool or Privacy Pool.

The pilot does not change SPEC-005 arithmetic, the SPEC-015 v0.4 receipt tuple, SPEC-022 finality, or response visibility. It MUST NOT fabricate a plaintext request snapshot or prompt hash from ciphertext or an envelope digest.

## 2. Authority and composition

SPEC-041 owns relay-blind provider key records, buyer pins, encryption envelopes, reservations, relay-blind admission, downgrade resistance, provider decryption, privacy outcome disclosure, and relay-blind redaction.

- SPEC-001 owns provider authentication and inference wire framing. Relay-blind dispatch uses the existing `inference_request` outer message with the explicit body encoding in R005.
- SPEC-002 owns provider assignment, capacity, request lifecycle, cancellation, and coordinator `request_log`. SPEC-041 adds binding and state constraints without bypassing those owners.
- SPEC-003 owns provider identity/onboarding. The dedicated pilot signing identity is an additional operator-pinned identity, not an admission credential.
- SPEC-005 owns ordinary accounting and delivered-output settlement. SPEC-041 supplies bounded clear inputs and an exclusion marker.
- SPEC-006 owns public routes, errors, headers, JSON, and SSE compatibility.
- SPEC-008 owns coordinator-to-provider encryption. Its disclosure and keys are distinct from this pilot.
- SPEC-015 owns receipts. The v0.4 tuple is unchanged and is unavailable as positive evidence for relay-blind work.
- SPEC-022 owns verified-model settlement. Relay-blind work cannot produce positive verified-model settlement or SPEC-022 verified-work rewards in this pilot; ordinary SPEC-005 provider payment remains in scope.
- SPEC-040 owns wallet authentication and request signatures. Wallet signatures bind the exact relay-blind transaction.
- SPEC-042 owns pool selection. Its current R009 requires rejection of every pool-scoped relay-blind request.

## 3. Canonical primitives

All base64url values are RFC 4648 URL-safe encoding without padding. SHA-256 outputs are 32 raw bytes before encoding. Strings and byte strings use an unsigned 32-bit big-endian byte length followed by exact bytes. Unsigned integers use unsigned 64-bit big-endian encoding. Unix times use signed 64-bit big-endian seconds. Booleans use unsigned 64-bit `0` or `1` where an envelope field is specified as `u64`.

Every set-like array is encoded as an unsigned 32-bit big-endian element count followed by individually u32-length-framed elements, sorted in byte-lexicographic ascending order, with no duplicates. A decoder MUST reject unsorted, duplicated, missing-count, over-count, under-count, or trailing elements; it MUST NOT normalize them.

## 4. Normative requirements

### SPEC-041-R001 - Default-off pilot and honest disclosure

Gateway, coordinator, provider runtime, and buyer tooling MUST each default relay-blind support off. A required request succeeds only when every component is enabled, the assigned live provider/session has fresh authenticated key evidence, and all durable stores are available and fresh. Mixed versions or uncertain stores fail before quota.

`/v1/models` and status surfaces MAY expose relay-blind capability only from fresh evidence. Each endpoint family reports `required_mode` as `unsupported`, `available`, or `required_unavailable`, plus the exact scope string above and these settlement labels:

- `verified_model_settlement: unavailable_for_relay_blind_request`
- `usage_settlement: standard_usage_settlement_and_clear_cap_enforcement_still_apply`

Each endpoint-family object also reports `pool_composition` as `none`, `all_relay_blind_capable`, or `mixed`, and MAY report buyer-safe `capable_provider_count` and `incapable_provider_count` when derived from aggregate routing metadata. Required-mode capability remains separate from composition.

Capability is model-scoped. A signed record that does not include the requested model cannot contribute to availability and MUST NOT be filtered or rewritten after signing. The reference CLI MUST always disclose the request-only limitations with a satisfied result, using safe metadata on stderr and response content on stdout.

### SPEC-041-R002 - Dedicated provider identities, keys, and pins

Each participating provider has a durable Ed25519 relay-blind identity signing key and a rotatable X25519 request-encryption key. The Ed25519 identity MUST be distinct from provider admission credentials, SPEC-015 receipt keys, SPEC-008 ECDH keys, and all X25519 encryption keys. The coordinator accepts its public key only when operator configuration independently pins it to the authenticated provider ID and current assigned session. Provider self-assertion, admission identity reuse, receipt-key reuse, or a relay-supplied record alone is insufficient. The fingerprint is `base64url(SHA256(raw 32-byte Ed25519 public key))`.

The immutable key-record framing encodes exactly, in order: `alg` (`x25519-hkdf-sha256-a256gcm-v1`), raw 32-byte X25519 public key, raw 32-byte relay-blind identity fingerprint, canonical model IDs array, `max_encrypted_request_bytes`, endpoint families array, and `signature_algorithm` (`ed25519`). Model scope contains 1..16 unique canonical IDs, each 1..128 printable ASCII bytes; the endpoint list is exactly one `chat_completions` element. `max_encrypted_request_bytes` is 1..1048576. Signed times are nonnegative signed-64 values with `not_before_unix < expires_at_unix`, lifetime at most 24 hours, and accepted future skew at most 60 seconds. `kid = base64url(first16(SHA256(immutable_framing)))`.

The signed key-record framing is the immutable framing followed exactly by `not_before_unix` and `expires_at_unix`. The provider signature is raw 64-byte Ed25519 over this signed framing. `key_record_digest = base64url(SHA256(signed_framing))`; the signature is not part of that digest. The JSON record carries the same fields, `kid`, `key_record_digest`, and canonical unpadded base64url signature. Relays and buyers MUST independently recompute every derived field and verify signature, time, scope, bounds, and exact framing.

Registration or heartbeat advertises complete signed records only on an authenticated provider session. The coordinator rejects malformed, invalid, future-skewed, expired, overbroad, substituted, duplicate, revoked, wrong-provider, wrong-session, or unsupported records. Same-`kid` renewal may only extend a validity window monotonically for byte-identical immutable framing and a new valid signature. A changed immutable field with the same `kid` is substitution and MUST be rejected.

Revocation is authenticated, durable, and retained through at least the maximum accepted signed expiry plus replay retention. Unknown revocation freshness makes the key unavailable. Every reservation and dispatch rechecks the authenticated live provider session, operator identity pin, signed record, expiry, and revocation.

The buyer MUST receive a public-only pin by an authenticated operator channel outside the gateway/coordinator path and invoke the reference CLI with `--identity-pin /absolute/local/file.json`. Network URL pins, discovery-derived defaults, TOFU, and automatic old/new acceptance are forbidden. The closed pin schema is:

```json
{
  "version": "relay-blind-pilot-pin-v1",
  "identity_public_key": "<base64url 32-byte Ed25519 public key>",
  "fingerprint": "<base64url SHA-256 raw public key>",
  "models": ["<canonical model>"],
  "endpoint_families": ["chat_completions"],
  "not_before_unix": 0,
  "expires_at_unix": 0,
  "revoked": false
}
```

`models` is nonempty, canonical, unique, sorted, and subject to the same 1..16 and 1..128-byte limits. `endpoint_families` is exactly `["chat_completions"]`. A reservation returns a complete signed record scoped to exactly the requested canonical model so wallet-model visibility never depends on relay-side filtering of a broader signed record. The CLI rejects missing, malformed, mismatched, out-of-window, revoked, or out-of-scope pins before encryption or network send and prints only the fingerprint and safe status. Rotation or recovery replaces the operator pin and invalidates all old reservations/envelopes. Offline buyers receive revocation/replacement out of band; the pilot makes no global instantaneous-revocation claim.

The CLI reads a pin through a bounded regular-file descriptor, not a pathname-following convenience API: at most 16 KiB; no symlink component; no group/world-writable file or ancestor; owner is the current uid or root; directory descriptors remain open during no-follow `openat` traversal; and the final descriptor is `fstat`-checked before exact bounded read. A sticky temporary test root is a fixture exception, not production acceptance. Production pins SHOULD live under a 0700 `~/.config/macprovider` ancestry with a 0600 or 0644 public pin. Tests cover file and parent symlinks, writable file/parent, wrong owner where privileges permit, pathname replacement after open, valid descriptor reads, and overflow.

### SPEC-041-R003 - Closed envelope and cryptographic transcript

The closed envelope JSON contains exactly: `version`, `mode`, `endpoint_family`, `model`, `provider_model`, `stream`, `request_id`, `max_output_tokens`, `input_token_upper_bound`, `reservation_token_cap`, `provider_binding`, `buyer_binding`, `key_record_digest`, `kid`, `buyer_ephemeral_public_key`, `request_replay_nonce`, `issued_at_unix`, `algorithm`, `ciphertext`, and `tag`. JSON decoding rejects duplicate/unknown/null fields, non-integer numeric forms, and trailing values; `stream` is a JSON boolean. `version` is `relay-blind-request-v1`; `mode` is `required`; `endpoint_family` is `chat_completions`; `algorithm` is `x25519-hkdf-sha256-a256gcm-v1`. Model, provider model, and request ID are 1..128 printable ASCII bytes; models are canonical IDs. Caps are positive integers no greater than 2^31-1, checked-add without overflow, and `reservation_token_cap == input_token_upper_bound + max_output_tokens`. `issued_at_unix` is nonnegative and inside configured skew. `provider_binding` and `buyer_binding` are random 32-byte values represented as 43-byte canonical base64url text; `buyer_binding` is reservation-local and contains no raw or stable account/session identifier. `kid` and `key_record_digest` are canonical base64url text of exactly 22 and 43 ASCII bytes. The public-key and replay-nonce fields decode to exactly 32 bytes. Ciphertext decodes to 1..1048576 bytes and AES-GCM `tag` to exactly 16 bytes.

Every base64url decoder rejects padding, whitespace, non-URL alphabet, nonzero trailing bits, and any encoding that does not round-trip byte-for-byte to the canonical unpadded form. Signing public keys, signatures, and fingerprints decode to exactly 32, 64, and 32 bytes. Strings are UTF-8 framed; list sorting is by UTF-8 bytes, with pilot identifiers restricted to ASCII as above.

The canonical AAD framing encodes exactly, in this order: `version`, `mode`, `endpoint_family`, `model`, `provider_model`, `stream` as u64 0/1, `request_id`, `max_output_tokens`, `input_token_upper_bound`, `reservation_token_cap`, `provider_binding`, `buyer_binding`, canonical base64url `key_record_digest` text, canonical base64url `kid` text, raw buyer ephemeral public-key bytes, raw request replay-nonce bytes, `issued_at_unix`, and `algorithm`. Ciphertext and tag are excluded. There are no optional, implicit, map-ordered, JSON-canonicalized, pool, or trailing fields.

The buyer creates a fresh X25519 ephemeral private key and replay nonce for each reservation and rejects an all-zero shared secret. Derivation is exact:

```text
aad = exact canonical framed clear-envelope bytes above
transcript = SHA256("macprovider/spec041/relay-blind/transcript/v1" || aad)
shared_secret = X25519(buyer_ephemeral_private, provider_x25519_public)
request_key = HKDF-SHA256(shared_secret, transcript, "macprovider/spec041/request/aead/v1", 32)
aead_nonce = HKDF-SHA256(shared_secret, transcript, "macprovider/spec041/request/aead-nonce/v1", 12)
```

HKDF uses the 32-byte X25519 shared secret as IKM, the 32-byte transcript digest as salt, and the literal ASCII info strings shown above. AAD is the framed bytes, not the transcript digest. Cross-language golden vectors include negative vectors for every framing, integer, base64url, array, size, and time ambiguity in this section.

AES-256-GCM encrypts the exact UTF-8 bytes of the closed OpenAI-compatible chat request using `aad`. The inner body includes all request content and MUST match the clear endpoint, model, provider model mapping, stream flag, output cap, input cap, reservation cap, tools, structured-output rules, and byte limit when checked at the provider. No prompt, message, tool schema, response schema, attachment, bearer, private key, or raw account/session identifier appears outside ciphertext.

For a SPEC-040 wallet session, the semantic signature covers the exact envelope bytes or their canonical digest plus route, requested privacy mode, `provider_binding`, `buyer_binding`, `key_record_digest`, `kid`, model, caps, and `issued_at_unix`. The gateway-provided trusted internal `X-MacProvider-Wallet-Session` identifies the session to the coordinator; a browser-supplied value is never authority. Gateway ingress strips any buyer-supplied internal wallet-session or execution-authorization header and overwrites trusted internal values after authentication. Wallet success performs metadata replay admission once as part of atomic inference admission; it MUST NOT double-consume replay state while preserving SPEC-040 signature, revocation, model, and cap checks.

### SPEC-041-R004 - Reservation, consume, and durable coordinator authority

Public and coordinator buyer-port `POST /v1/relay-blind/route-reservations` preserve the existing closed request schema exactly: `endpoint_family`, `model`, `stream`, `max_output_tokens`, `input_token_upper_bound`, and `encrypted_request_bytes`. It rejects duplicate, unknown, null, trailing, malformed, noncanonical, overflowed, or out-of-bound fields before state creation. The route is mounted even when disabled so valid requests receive typed `relay_blind_disabled`, never an untyped 404. Every response sets `Cache-Control: no-store` and `Pragma: no-cache`. The public route uses the eventual request's normal API-key or signed wallet-session authentication. Pool selection is not a body field. Any nonempty pool-selection header or other authenticated pool intent is rejected before reservation, quota, or dispatch under SPEC-042-R009. The gateway forwards closed metadata with existing trusted gateway Authorization and trusted account/session context. The coordinator rejects non-gateway callers.

The successful closed response contains exactly: `version: relay-blind-reservation-v1`, `provider_binding`, `buyer_binding`, `key_record_digest`, `key_record`, `kid`, `endpoint_family`, `model`, `provider_model`, `stream`, `max_encrypted_request_bytes`, `max_output_tokens`, `input_token_upper_bound`, `reservation_token_cap`, `expires_at_unix`, `cache_policy: no-store`, and `failover_policy: disabled`. It contains no stable provider ID or assigned-session ID. Public success and error metadata MUST NOT expose `X-Provider-Id` or any equivalent stable peer identifier. TTL is at most 30 seconds and no later than signed key expiry.

Reservation binds immutably to the authenticated account/session, live provider ID and assigned session, signed record digest and `kid`, canonical and provider models, endpoint, stream, all caps, byte bound, and explicit empty pool selection. Key discovery does not reserve capacity or quota. Existing provider capacity is acquired only at dispatch.

Before quota or dispatch, the gateway calls internal `POST /v1/relay-blind/consume` with the exact envelope and same trusted account/session context. The closed success response contains exactly `version: relay-blind-consume-v1`, `provider_binding`, `buyer_binding`, `envelope_digest`, `execution_authorization`, `consumed_at_unix`, and `expires_at_unix`. Consumption cannot dispatch. The authorization is opaque outside the coordinator and stored only as a hash in durable state. Buyer-supplied execution authorization is stripped; trusted authorization is carried only on the internal dispatch hop and stripped before any provider runtime/upstream request header set.

Recovery uses authenticated internal `POST /v1/relay-blind/status` with exactly `provider_binding_digest` and `envelope_digest`, each canonical base64url SHA-256. The closed response contains `version: relay-blind-status-v1`, `state`, `internal_request_id`, `validated`, nullable `input_tokens`, nullable `completion_tokens`, `effective_privacy_outcome`, and `retry_action: do_not_resubmit`. Input is present exactly when authenticated usage is known; completion is present only for `terminal`. This endpoint never dispatches. It atomically fences expired `reserved` or `consumed_predispatch` rows to `rejected` before reporting them; fresh rows remain held to avoid a concurrent dispatch/refund race. `unknown_postdispatch` is irreversible and settles known input and locally recorded delivered output only. Usage knowledge and satisfied privacy are independent facts.

Coordinator SQLite metadata is durable and bounded: key records keyed `(provider_id,kid)`; revocations keyed `(provider_id,kid)` with the R002 retention deadline; and reservations keyed random `provider_binding`, with unique `buyer_binding`, account/session, provider/assigned session, record digest/`kid`, models, stream, caps, byte bound, expiry, state, envelope digest, execution-authorization hash, and created/consumed/dispatched/terminal timestamps.

The atomic state machine is `available -> consumed -> dispatched -> terminal`. Only an exact authenticated envelope may conditionally change `available` to `consumed`; the transition happens before quota or dispatch. Quota failure, disabled/unavailable outcome, expiry, denial, and applicable terminal rejection burn the reservation/envelope and never restore `available`. The coordinator arms dispatch exactly once after revalidation and capacity/quota admission. Duplicate, uncertain, or recovered dispatched work MUST NOT dispatch again. Indexed expiry, row/byte/rate ceilings, and bounded sanitized audits prevent rejection-state amplification. Persistent store error or unknown freshness disables availability.

Gateway replay state remains durable across restart and configuration cycling and is checked before rate/capacity classification. Applicable single-use material is durably recorded before disabled/unavailable rejection, so a later configuration change cannot revive it. Coordinator consumption and dispatch state independently prevent duplicate dispatch. There is no network retry of consume or dispatch; uncertainty fails closed.

The acceptance state names are fixed. Coordinator owns `reserved -> consumed_predispatch -> dispatched -> terminal`, with `rejected` and `unknown_postdispatch` terminal fences. Provider owns `claimed -> validated -> terminal`; a restarted `claimed` or `validated` entry becomes `unknown_postdispatch` and never reexecutes. Gateway owns `quota_held` followed by the existing settled/refunded/pending journal states. Reservation or `consumed_predispatch` alone never permits billing. Cancel, timeout, key/session staleness, or component restart before dispatch burns material, refunds held quota, and returns `new_reservation_and_envelope` when otherwise retryable. After dispatch, cancel, timeout, disconnect, restart uncertainty, or terminal-evidence loss becomes `unknown_postdispatch`, never resubmits, and bills only known usage/delivered output through existing recovery with `do_not_resubmit`. Provider terminal-evidence loss preserves the durable terminal claim while coordinator/gateway reconcile accounting. Tests cover every transition/crash cut and duplicate settlement delivery.

### SPEC-041-R005 - Opaque provider wire, decryption, and execution claim

Relay-blind work uses the SPEC-001 `inference_request` outer message and its existing SPEC-008 wrapping when enabled. It adds `body_encoding: relay-blind-request-v1`, authenticated inside the SPEC-008 payload; a non-SPEC-008 frame carries the same marker. The body is the exact relay-blind envelope JSON, not synthetic chat JSON. Provider and coordinator cross-check marker and namespace. Unknown/mismatched encoding is rejected without plaintext parsing.

`provider_model` binds the advertised canonical provider wire selector. The provider resolves that selector through its configured catalog alias to the executable model and pins the same runtime handle for tokenization and generation, preventing model replacement between validation and inference. This pilot does not attest an executable artifact or weight hash and makes no SPEC-022 verified-model claim.

Coordinator dispatch is typed opaque, WebSocket-only, and bound to the exact assigned session. It MUST NOT parse ciphertext as chat, rewrite it, use HTTP fallback, fail over, or move it to another provider. Every boundary independently recomputes the envelope digest.

The coordinator opaque branch occurs before ordinary chat-body validation. Streaming and WebSocket nonstream callbacks bypass plaintext dispatch-body conversion and plaintext route-snapshot recording. Failover has an explicit pinned/no-retry branch and HTTP transport rejects relay-blind mode. Enforce-mode is rechecked at reservation, consume, and immediately before dispatch. Tests assert zero plaintext-hash snapshots, receipt-settlement metadata, failover-candidate advancement, or next-provider calls for queue-full, NAK, timeout, cancel, and disconnect paths.

Before decryption or runtime entry, the provider durably claims execution identity derived from binary-framed `buyer_binding`, `provider_binding`, `kid`, `request_id`, and envelope digest. The journal lives under an operator-configured state directory outside the repository; directory mode is 0700 and files are 0600. Filename is SHA256 of those framed fields. Claim uses exclusive create followed by file fsync and directory fsync. Terminal update uses atomic rename followed by file and directory fsync. Entries contain only digest, state, times, and caps, never request body, ciphertext, or keys. They are retained through replay retention plus active execution.

Journal error, capacity exhaustion, or uncertain recovery fails closed. A claimed or uncertain entry after restart always rejects duplicate execution. Crash before claim may be retried only through the same coordinator recovery decision without creating new envelope material; crash after claim, after decrypt, after first token, or during terminal persistence MUST NOT execute again.

After a successful claim, the provider authenticates/decrypts and applies the existing chat validation path. It cross-checks all clear fields, byte bounds, inner schema, model, stream, requested output, actual tokenized input against `input_token_upper_bound`, reservation cap, tools, and structured output before inference. Client/envelope faults use `relay_blind_ciphertext_invalid`; a transient provider-internal decryption subsystem fault uses `relay_blind_decrypt_failed`. Errors and logs contain bounded digests and codes only.

Only the provider may produce `relay_blind_validation`. A `validated` fact is permitted only after decryption, schema checks, and actual token-cap validation but before generation. The object binds `execution_auth_digest`, `envelope_digest`, `kid`, `provider_binding_digest`, `buyer_binding_digest`, `assigned_session`, `request_id`, `state: validated`, `input_tokens`, `input_token_upper_bound`, and `max_output_tokens`. Terminal evidence repeats the same context with terminal state and final usage. The coordinator sends `execution_auth_digest` and `assigned_session` as authenticated opaque dispatch context, inside SPEC-008 protection when active; the provider independently recomputes envelope and binding digests. The coordinator accepts evidence only from the exact live authenticated WebSocket session and only when every field matches its durable dispatch row. Delayed prior-session, misassociated, duplicate-contradictory, or relay-generated evidence cannot mark satisfied or settle provider-reported usage. Under SPEC-008 the evidence is inside the protected response payload; otherwise authenticated WebSocket transport is mandatory. Validated and terminal facts are persisted before success disclosure. Missing or uncertain evidence remains unavailable.

Before generation, the provider may instead send bound `state: rejected` evidence with `input_tokens: 0` and `error_code` equal to `relay_blind_ciphertext_invalid` or `relay_blind_decrypt_failed`. It binds the same execution, session, envelope, key, buyer, provider, and cap fields; terminal rejection repeats that context. This evidence proves rejection without inference, never satisfied privacy or billable input, and permits existing quota refund after durable rejection. The provider claim remains burned across restart. Missing or contradictory rejection evidence remains held for reconciliation.

### SPEC-041-R006 - Accounting, receipts, rewards, and disclosure

Relay-blind work uses existing quota, SPEC-005 settlement, gateway `usage_events`/journal, and coordinator `request_log`; there is no parallel ledger. Existing records gain bounded additive facts: `requested_privacy_mode`, `effective_privacy_outcome`, `relay_blind_envelope_digest`, `relay_blind_key_record_digest`, `relay_blind_kid`, `relay_blind_provider_binding_digest`, durable clear caps, and an explicit positive-receipt/reward exclusion. Existing default values mean plaintext. Recovery preserves the same caps/outcome and at most one settlement.

The pilot may operate only while the effective SPEC-022 settlement mode is `observe`. `enforce` MUST reject relay-blind reservation/admission before quota with no exemption or global weakening. Relay-blind work is excluded from positive SPEC-015 receipt claims, SPEC-022 mirrored/verified status, SPEC-022 verified-work rewards, and every positive verified-work aggregate. Ordinary SPEC-005 usage settlement, provider earnings, payment, and payout-readiness accounting continue under their existing rules. No SPEC-015 v0.4 receipt metadata is attached.

Billable input is `min(provider_reported_input_tokens, input_token_upper_bound)`; unknown input defaults to zero and MUST NOT be estimated from ciphertext. Provider actual tokenized input above the declared bound rejects before inference. Output uses existing delivered-output rules and is bounded by `max_output_tokens`. Existing refunds, partial-output accounting, finality, request logs, usage events, and journals remain authoritative.

A gateway failure after attempting consumption may return the existing `relay_blind_required_unavailable` code with `retryable: false` and transaction-phase `error.macprovider.retry_action: new_reservation_and_envelope`. This means starting a fresh transaction after resolving the cause, never automatically retrying the failed HTTP request or reusing its envelope. Feature/model unavailability before consumption retains `retry_action: none`. Replay and postdispatch uncertainty always use `do_not_resubmit`, which overrides every predispatch action. The response may also expose `X-MacProvider-Relay-Blind-Retry-Action` for that predispatch phase.

Requested privacy mode is exactly `none` or `relay_blind_required`. Effective outcome is exactly `plaintext`, `provider_leg_encrypted`, `relay_blind_satisfied`, or `relay_blind_unavailable`. `relay_blind_satisfied` is recorded only after the provider authenticates, decrypts, validates the body, and the coordinator accepts the bound validation evidence. Unknown execution is never satisfied. Buyer surfaces carry requested/effective outcome, the exact scope string, settlement labels, and `retry_action`: `new_reservation_and_envelope` for retryable predispatch failure, `do_not_resubmit` for replay or postdispatch uncertainty/commit, and `none` for success. Non-stream JSON uses `usage.macprovider`; bounded JSON errors use `error.macprovider`; SSE usage, terminal, and error events use `macprovider`. Privacy metadata headers carry the same requested/effective outcome. A disconnected buyer cannot receive a cancellation event, but durable audit and settlement retain the truthful terminal state.

### SPEC-041-R007 - Errors, retry, and downgrade resistance

All errors use SPEC-006-compatible envelopes and bounded `macprovider` metadata.

| Code | HTTP | Retryable | Retry action |
|---|---:|---:|---|
| `relay_blind_disabled` | 503 | no | `none` |
| `relay_blind_required_unavailable` | 503 | no | `none` |
| `relay_blind_key_expired` | 503 | yes | `new_reservation_and_envelope` |
| `relay_blind_envelope_invalid` | 400 | no | `none` |
| `relay_blind_route_reservation_invalid` | 400 | no | `none` |
| `relay_blind_endpoint_unsupported` | 400 | no | `none` |
| `relay_blind_replay` | 409 | no | `do_not_resubmit` |
| `relay_blind_metadata_rate_limited` | 429 | yes | `new_reservation_and_envelope` |
| `relay_blind_downgrade_rejected` | 400 | no | `none` |
| `relay_blind_decrypt_failed` | 502 | yes | `new_reservation_and_envelope` |
| `relay_blind_ciphertext_invalid` | 400 | no | `none` |
| `relay_blind_committed_failed` | 500 | no | `do_not_resubmit` |
| `relay_blind_provider_unsupported` | 503 | yes | `new_reservation_and_envelope` |

Required mode fails closed before quota when unavailable. No generic 503 helper may replay a reservation, consume call, dispatch call, or ciphertext. A retryable result authorizes only a wholly new reservation, ephemeral key, nonce, request identifier, and envelope. Replay classification takes precedence over rate/capacity classification. Any `relay-blind-request-*` namespace is relay-shaped and can never enter plaintext parsing. Any mode other than `required`, provider/key substitution, HTTP fallback, cross-provider failover, altered model/caps, or plaintext conversion is `relay_blind_downgrade_rejected`.

Both gateway and coordinator MUST implement the same emitted-code inventory, HTTP/retry map, retry action, and completeness guard. Persisted request facts determine recovered terminal classification.

### SPEC-041-R008 - Staging, evidence, and promotion gate

Implementation follows five default-off stages:

1. provider identity/key framing, authenticated advertisement, rotation, revocation, pin workflow, and shared public test vectors;
2. closed reservation/consume APIs, durable state, gateway replay, wallet/API authentication, and reference buyer encryption;
3. typed opaque dispatch, provider journal, decryption, validation, and at-most-once execution;
4. ordinary settlement, positive receipt/reward exclusion, and truthful JSON/header/SSE disclosure;
5. real buyer -> gateway -> coordinator -> Swift provider nonstream/stream success, cancellation, partial output, loss, timeout, and restart recovery.

No stage may enable buyer success before all preceding stages and their fail-closed checks work. Disabling any component rejects required requests before quota and leaves plaintext, wallet, demo, SPEC-008, receipt, and ordinary pool behavior unchanged.

Configuration MUST retain positive bounds for replay retention, timestamp skew, route-reservation TTL, key-cache freshness, maximum encrypted bytes, metadata admission rate, replay rows, and replay bytes. Enabled configuration rejects nonpositive/impossible bounds, unsupported algorithms, or disclosure that lacks fresh provider evidence. Disabled fields do not break plaintext startup, but disabled relay-shaped requests still use safe freshness/replay defaults so configuration cycling cannot revive old material.

Promotion requires shared Go/Swift vectors; focused state, framing, tamper, low-order X25519, pin, replay, crash-injection, accounting, streaming, and mixed-version tests; broad module build/test/vet gates; successful signed isolated-provider journeys for success and required-unavailable; and independent code, security, architecture, adversarial-verifier, and product-design reviews with zero Critical, High, or Medium findings. Hardware proof and production activation evidence are separate dependencies. Until those exist, this SPEC remains `draft`, `pending-reconciliation`, and `not-deployed`, and CONFORMANCE requirements remain pending.

## 5. Operator custody runbook requirement

The normative operator procedure is [Relay-blind pilot key and pin custody](../docs/runbooks/relay-blind-pilot-key-custody.md). It covers initial creation, provider-ID binding, public pin distribution, planned rotation, emergency revocation, custody loss, local restore, and reservation invalidation. Private Ed25519 and X25519 material, journal output, and helper output MUST stay outside repository roots/worktrees in operator-selected 0700 directories with 0600 files. Documentation and tooling MUST never print private bytes. Recovery verifies identity through the public fingerprint and independently configured provider binding; it does not silently create a new trust root.

## 6. Evidence

Local implementation and verification evidence is recorded in [the pilot audit](../audits/privacy-pool-v01-implementation.md). No promotion evidence is attached. Existing admission-only implementation references remain historical partial work and do not satisfy this full pilot profile.

## 7. Changelog and history

- 0.2.0 - Reconciled the complete default-off global-pool pilot: dedicated operator-pinned Ed25519 identity and buyer pin; exact key/envelope framing; opaque buyer binding; reservation/consume state; typed opaque provider wire and journal; observe-mode settlement with receipt/reward exclusion; truthful per-request disclosure; and five-stage implementation/recovery gate. Status remains draft, pending-reconciliation, and not-deployed.
- 0.1.0 - Initial relay-blind request encryption draft and admission-only gateway slice. That slice remains historical partial implementation and is superseded as an implementation plan by the v0.2.0 five-stage build plan.
