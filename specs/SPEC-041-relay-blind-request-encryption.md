# SPEC-041 - Relay-Blind Request Encryption

**Version:** 0.1.0
Status: draft
Owner: @Augustas11
Issue: https://github.com/Augustas11/macprovider/issues/928
Audit history: Initial draft for issue #928. This SPEC is not build-ready until the code, security, architecture, adversarial-verifier, and product-design critic lanes report 0 Critical, 0 High, and 0 Medium findings.

```json
{
  "spec_id": "SPEC-041",
  "title": "Relay-Blind Request Encryption",
  "version": "0.1.0",
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
    "rationale": "Relay-blind buyer privacy is a new authority domain. The first implementation must land default-off with local tests and no conformance promotion until signed journey-result evidence exists."
  }
}
```

## 1. Purpose and scope

MacProvider currently routes buyer inference through a gateway and coordinator that can observe request content. SPEC-008 Pillar B encrypts only the coordinator-to-provider leg; it explicitly does not hide prompts from the coordinator. SPEC-041 defines a separate relay-blind request mode that lets a buyer require the gateway and coordinator to route, reserve quota, disclose status, and settle usage without seeing prompt or tool content.

In scope for v0.1:

- provider-advertised relay-blind encryption keys and capability status;
- buyer request envelopes that keep only routing and billing metadata in cleartext;
- gateway admission and typed fail-closed errors when relay-blind mode is required but unavailable;
- coordinator forwarding of relay-blind encrypted payloads without decrypting prompt content;
- provider-side decryption immediately before the existing OpenAI-compatible validation/runtime path;
- receipt, status, model, and diagnostic labels that disclose whether the request was plaintext, provider-leg encrypted only, relay-blind encrypted, or rejected before dispatch;
- local test vectors for key announcement, envelope validation, downgrade rejection, replay/freshness rejection, and default-off compatibility.

SPEC-041 v0.1 successful relay-blind execution is scoped to `chat_completions` only. `responses` and `messages` MAY advertise `unsupported`, but MUST NOT accept required relay-blind encrypted content until a later SPEC revision defines client-side or provider-side canonical translation for those endpoint families.

Out of scope for v0.1:

- hiding cleartext routing metadata such as canonical model id, request id, stream flag, endpoint family, capped token reservation, and capability requirement;
- hiding request content from the selected provider process or provider operator;
- confidential compute, hardware-private prompts, or proof that the selected provider did not log plaintext after decryption;
- changing SPEC-005 billing arithmetic, SPEC-015 receipt tuple signatures, or SPEC-022 verified-model settlement finality;
- encrypting provider responses to hide completions from the gateway/coordinator. That is a future bidirectional privacy mode and MUST NOT be implied by v0.1 request encryption.

## 2. Authority and dependencies

SPEC-041 owns the authority domain `relay-blind-request-encryption`: provider relay-blind key advertisement, buyer request encryption envelope, gateway/coordinator fail-closed admission, downgrade semantics, relay-blind status labels, relay-blind audit redaction, and provider-side request decryption before existing inference validation.

SPEC-001 owns the provider wire protocol. SPEC-041 can define relay-blind key and envelope semantics, but any provider WebSocket or HTTP field that carries those records MUST remain compatible with SPEC-001 framing, authentication, and old-provider behavior.

SPEC-002 owns coordinator admission and routing. SPEC-041 extends coordinator admission with relay-blind key cache and fail-closed routing checks, but MUST NOT bypass SPEC-002 request lifecycle, provider assignment, capacity accounting, cancellation, or request-log ownership.

SPEC-003 owns provider onboarding identity. SPEC-041 relies on provider identity for buyer-verifiable relay-blind key records; key records MUST be signed by an authenticated provider identity accepted under SPEC-003/SPEC-001, not by the gateway or coordinator alone.

SPEC-005 owns billing arithmetic and settlement formulas. SPEC-041 constrains relay-blind clear-cap settlement inputs, but MUST NOT redefine SPEC-005 delivered-output settlement, over-report handling, payout math, or ledger ownership.

SPEC-006 owns the buyer API error envelope and OpenAI-compatible route shape. SPEC-041 extends the buyer API with relay-blind metadata and error codes but MUST preserve existing plaintext behavior when the feature is disabled or not requested. Public buyer key discovery MUST use opaque provider bindings and MUST NOT expose stable provider IDs unless SPEC-006 is amended to allow that exposure.

SPEC-008 owns Tier-2 trust evidence and provider-leg encryption. SPEC-041 MUST NOT describe SPEC-008 Pillar B as relay-blind or buyer-to-provider end-to-end encryption. A request can be relay-blind without Tier-2 provider-leg encryption, and can use Tier-2 provider-leg encryption without being relay-blind; buyer-facing disclosure MUST distinguish those states.

SPEC-015 owns inference receipts. SPEC-041 v0.1 MAY add buyer/gateway status headers and gateway-side audit fields, but MUST NOT require providers to change the v0.4 receipt tuple. Any later receipt-tuple field addition requires a SPEC-015 version bump.

SPEC-022 owns verified model settlement. Relay-blind requests MUST settle through existing gateway/coordinator usage paths and MUST NOT create a parallel settlement ledger. Because the relay cannot derive the current SPEC-015/SPEC-022 plaintext prompt hash, relay-blind traffic MUST NOT be promoted as positive verified-model-settlement conformant until SPEC-015/SPEC-022 define a relay-blind digest or receipt contract.

SPEC-040 owns wallet-native buyer sessions. A wallet session MAY require relay-blind mode per request, but relay-blind encryption MUST NOT weaken SPEC-040 request signatures, replay checks, expiry, revocation, model allowlist, or spend caps.

## 3. Terms

| Term | Meaning |
|---|---|
| Relay | Gateway and coordinator components that route buyer requests before selected-provider execution. |
| Relay-blind request | A request whose prompt/tool/input content is encrypted for the selected provider before it reaches the gateway/coordinator. |
| Clear routing metadata | The minimal unencrypted fields needed to authenticate the buyer, choose a model/provider, reserve quota, enforce endpoint policy, and correlate settlement. |
| Relay-blind key record | Provider-signed X25519 public key record with key id, expiry, algorithm, model/capability scope, provider identity binding, and deterministic digest. |
| Provider binding | Opaque gateway/coordinator handle that selects a routable provider/key without disclosing a stable provider id to buyers. The binding is authenticated by the provider-signed key record digest and relay admission state. |
| Request envelope | Closed JSON object submitted by the buyer containing clear metadata plus an encrypted inner OpenAI-compatible request body. |
| Downgrade | Any path that silently sends plaintext when the buyer required relay-blind mode, or silently routes to a provider/key other than the one authenticated by the envelope. |

## 4. Normative requirements

### SPEC-041-R001 - Default-off posture and disclosure

Relay-blind request encryption MUST be default-off unless the gateway and coordinator enable explicit relay-blind admission and at least one provider advertises a usable relay-blind key for the requested model.

Existing plaintext API-key, demo, and wallet-session requests MUST behave unchanged when they do not opt in. Existing SPEC-008 provider-leg encryption disclosure MUST remain separate and MUST retain the `coordinator_to_provider_only` scope.

`/v1/models` and buyer-safe diagnostics MUST expose a relay-blind capability object only when relay-blind config or provider evidence is active. The object MUST be endpoint-family scoped. For v0.1, `chat_completions` MAY report relay-blind availability, while `responses` and `messages` MUST report `unsupported` for required relay-blind encrypted content.

For each endpoint family, the disclosure object MUST separate required-mode capability from pool composition:

- `required_mode`: `unsupported`, `available`, or `required_unavailable`;
- `pool_composition`: `none`, `all_relay_blind_capable`, or `mixed`;
- `capable_provider_count` and `incapable_provider_count` where buyer-safe and already derivable from aggregate routing metadata;
- `required_unavailable` - request-time requirement could not be satisfied.

Product copy MUST NOT say "end-to-end encrypted," "confidential compute," "private from provider," or "provider cannot read prompts" for SPEC-041 v0.1.

### SPEC-041-R002 - Provider key advertisement and lifecycle

A provider that supports relay-blind requests MUST advertise a provider-signed relay-blind key record during authenticated provider registration or heartbeat. The relay MAY distribute the record to buyers, but the relay MUST NOT be the trust anchor for buyer encryption. The signed record MUST contain:

- `alg: "x25519-hkdf-sha256-a256gcm-v1"`;
- `kid`, computed as base64url(SHA256(canonical immutable key record)[0:16]);
- raw X25519 public key encoded as canonical unpadded base64url;
- `not_before_unix` and `expires_at_unix`;
- supported canonical model ids;
- maximum encrypted request bytes;
- endpoint families, with v0.1 success limited to `chat_completions`;
- authenticated provider identity or provider identity key fingerprint;
- signature algorithm and provider signature over the canonical signed key record, including validity bounds.

The coordinator MUST reject malformed, unsigned, signature-invalid, expired, future-skewed, duplicate-`kid`, unsupported-algorithm, weak-scope, or overbroad key records. Relay-blind keys MUST be bound to the authenticated provider identity and assigned session. A key from one provider MUST NOT be used for another provider, even when both serve the same model. Buyer-side encryption MUST verify the provider signature over the signed key record, including `not_before_unix` and `expires_at_unix`, and bind the signed key-record digest; a gateway-authorized discovery response by itself is not sufficient proof for relay blindness.

The `kid` canonical immutable key record MUST include exactly `alg`, raw public key, provider identity key fingerprint, supported canonical model ids, maximum encrypted request bytes, endpoint families, and the provider signature algorithm. It MUST exclude `not_before_unix`, `expires_at_unix`, heartbeat timestamps, availability counters, and transport metadata. The provider-signed canonical key record MUST include the immutable key record plus `not_before_unix` and `expires_at_unix`; buyers and relays MUST evaluate expiry from the signed record only. Extending a validity window for the same immutable key record therefore keeps the same `kid` but requires a fresh provider signature over the new signed key record, and is allowed only when the new signed record is monotonic, non-overlapping with revoked material, and still inside coordinator freshness bounds. Reusing a `kid` with different immutable key material MUST be rejected as key substitution.

Canonical key-record encoding is deterministic binary framing, not JSON serialization. The immutable key-record digest input MUST encode fields in this exact order: `alg`, raw X25519 public key bytes, provider identity key fingerprint bytes, supported canonical model ids, maximum encrypted request bytes, endpoint families, and provider signature algorithm. Strings and byte arrays MUST be length-prefixed with unsigned 32-bit big-endian lengths. Unsigned integer fields MUST be unsigned 64-bit big-endian. Supported canonical model ids and endpoint families MUST be sorted lexicographically before encoding and each element MUST be individually length-prefixed. The provider-signed canonical key record MUST use the same framing and append `not_before_unix` and `expires_at_unix` as signed 64-bit big-endian Unix seconds after the immutable record fields. Provider signatures MUST cover that canonical signed key-record byte sequence exactly.

Providers MUST rotate relay-blind keys before expiry. Gateway/coordinator caches MUST fail closed after expiry and MUST NOT route required relay-blind requests to stale keys. Providers MUST be able to revoke a relay-blind key before expiry via an authenticated SPEC-001/SPEC-003-compatible provider message to the coordinator. The coordinator MUST durably mark the `kid` revoked, MUST reject any later required relay-blind request or route reservation that references the revoked `kid`, and MUST preserve revocation state across restarts until at least the original key expiry plus replay retention. Gateway key caches MUST observe revocation no later than their configured key-cache TTL and MUST fail closed while revocation freshness is unknown.

### SPEC-041-R003 - Buyer envelope and cryptographic binding

A relay-blind buyer request MUST use a closed JSON request envelope. The clear envelope MUST include only:

- `version: "relay-blind-request-v1"`;
- `mode: "required"`;
- endpoint family, which MUST be `chat_completions` for successful v0.1 relay-blind execution;
- canonical model id;
- provider executable model id from the route reservation;
- stream flag;
- buyer request id;
- clear maximum output tokens and input-token upper bound;
- reservation token cap;
- opaque provider binding returned by a gateway route-reservation response;
- signed relay-blind key-record digest;
- selected relay-blind `kid`;
- buyer ephemeral X25519 public key;
- request replay nonce;
- issued-at timestamp;
- AEAD algorithm and ciphertext fields.

The encrypted plaintext MUST be the exact OpenAI-compatible request body the provider will validate, including prompts, tool schemas, response-format schemas, and other request content. The clear envelope MUST NOT contain `messages`, `input`, prompt text, tool schemas, response JSON schemas, attachments, raw conversation tags, API keys, wallet secrets, or provider tokens.

The buyer MUST derive an ephemeral X25519 key per request. The request replay nonce is clear routing metadata used only for freshness/replay state. The AEAD nonce is derived, not buyer-supplied cleartext. The transcript MUST frame the clear envelope fields excluding `ciphertext` and `tag`; it MUST include the opaque provider binding, signed key-record digest, `kid`, buyer ephemeral public key, buyer account/session binding, endpoint family, canonical model id, provider executable model id, buyer request id, stream flag, clear maximum output tokens, input-token upper bound, reservation cap, request replay nonce, and issued-at timestamp. For API-key requests, the binding is the opaque account binding returned by route reservation, not the raw API key or stable account id. For wallet-session requests, the binding is the opaque wallet-session binding or session public key returned by route reservation. The binding MUST be present whenever a route-reservation response is used. Keys and nonces MUST be derived as:

```text
shared_secret = X25519(buyer_ephemeral_private, provider_relay_blind_public)
transcript = SHA256("macprovider/spec041/relay-blind/transcript/v1" || framed clear envelope fields_without_ciphertext_or_tag)
request_key = HKDF-SHA256(shared_secret, transcript, "macprovider/spec041/request/aead/v1", 32)
aead_nonce = HKDF-SHA256(shared_secret, transcript, "macprovider/spec041/request/aead-nonce/v1", 12)
```

The `framed clear envelope fields` in the transcript computation MUST use the same deterministic binary length-prefixed encoding required for AAD. The AEAD AAD MUST authenticate all clear envelope fields except `ciphertext` and `tag`, including the opaque provider binding, signed key-record digest, relay-blind `kid`, buyer ephemeral public key, buyer account/session binding, endpoint family, canonical model id, provider executable model id, request id, stream flag, clear maximum output tokens, input-token upper bound, reservation cap, request replay nonce, and issued-at timestamp. AAD MUST use deterministic binary length-prefixed framing, not Go map order or pretty JSON.

For SPEC-040 wallet sessions, the wallet-session semantic signature MUST cover the exact relay-blind request envelope bytes or their canonical digest, the requested relay-blind mode, opaque provider binding, signed key-record digest, `kid`, and issued-at timestamp. A gateway MUST reject wallet-session relay-blind requests when the wallet signature covers a different body, privacy mode, route, model, cap, or provider/key binding.

### SPEC-041-R004 - Gateway and coordinator fail-closed admission

Before constructing a relay-blind envelope, the buyer MUST obtain a gateway route-reservation response. SPEC-041 v0.1 has one buyer-facing reservation route: `POST /v1/relay-blind/route-reservations`. The route MUST be mounted even when relay-blind admission is disabled; disabled or unavailable admission MUST return a typed relay-blind error rather than an untyped 404. The route requires the same buyer authentication class as the eventual inference request, including wallet-session authentication when the eventual request uses a wallet session. The request body MUST be closed-schema and contain endpoint family, canonical model id, stream flag, requested maximum output tokens, input-token upper bound, and requested encrypted byte bound; it MUST NOT contain prompt/tool/input content.

The route-reservation response MUST be closed-schema and contain an opaque provider binding, opaque buyer account or wallet-session binding for transcript/AAD use, signed key-record digest, complete provider-signed key record, `kid`, endpoint family, canonical model id, provider executable model id, maximum encrypted request bytes, clear-cap limits, expiry, cache policy `no-store`, and failover policy. The route reservation MUST be short-lived, single-use, and bound to the authenticated buyer account or wallet session. Gateway key discovery MAY be used only to populate read-only disclosure and MUST NOT mint an opaque provider binding usable for inference. For required mode, cross-provider failover is disabled: if the bound provider/key cannot serve the request, the relay MUST reject and require a fresh route reservation plus fresh buyer envelope rather than replaying ciphertext to another provider.

When a buyer marks relay-blind mode `required`, the gateway MUST reject before quota reservation or coordinator dispatch unless:

- relay-blind feature flags are enabled;
- the buyer credential is valid;
- the clear envelope is syntactically valid and closed-schema;
- the model id is canonical and allowed for the buyer/session;
- a routable provider matching the opaque provider binding has the signed, bound, non-expired key record and `kid`;
- reservation caps are within account/session limits;
- request id, request replay nonce, buyer ephemeral public key, timestamp, and envelope digest have not been replayed inside the configured retention window;
- relay-blind metadata admission and replay storage are inside configured per-account/session rate, row, and byte ceilings.

The gateway and coordinator MUST NOT decrypt relay-blind ciphertext. They may validate envelope shape, clear metadata syntax and byte bounds, provider signature validity, key availability, provider binding, endpoint family, provider executable model id, clear maximum output tokens, input-token upper bound, reservation cap, metadata admission capacity, and replay state. A required relay-blind request MUST never fall back to plaintext, an unbound key, an expired key, a substituted provider binding, rewritten model id, cross-provider failover target, or a provider not authenticated by the envelope. Public buyer diagnostics MUST identify the opaque binding and key state without exposing stable provider IDs unless SPEC-006 explicitly permits that exposure.

SPEC-041 v0.1 does not define opportunistic plaintext fallback. A relay-blind envelope MUST never be converted into plaintext by the gateway or coordinator. Any request body that uses the `relay-blind-request-*` version namespace is relay-shaped even when the exact version is unsupported, and MUST be rejected with a typed relay-blind error before route-specific plaintext parsing. A buyer that wants plaintext fallback must submit a separate plaintext OpenAI-compatible request after receiving a typed relay-blind rejection; that separate request is governed by existing plaintext semantics and MUST NOT be described as relay-blind.

### SPEC-041-R005 - Provider decryption and validation boundary

The selected provider MUST decrypt the relay-blind request immediately before invoking its existing request validation/runtime path. The decrypted body MUST be parsed by the same validation rules as a plaintext OpenAI-compatible chat-completions request. Decryption success MUST NOT bypass max-body, model, stream, tool, structured-output, prefix-cache, or token-limit validation. The decrypted request MUST match the clear endpoint family, canonical model id, provider executable model id, stream flag, maximum output tokens, and reservation/input upper bounds; mismatches MUST fail before inference and billing.

Provider decryption failure, unsupported envelope version, key mismatch, stale `kid`, malformed AAD, bad ciphertext/tag, or decrypted-body validation failure MUST return a typed provider error without logging plaintext or ciphertext beyond bounded digests. Providers MUST classify envelope-material failures as `relay_blind_ciphertext_invalid` when the failure is attributable to client/envelope material, including AEAD tag authentication failure, `kid` not found or mismatched, unrecognized envelope version, envelope field inconsistency, bad AAD, or decrypted body mismatch with clear caps. Providers MUST classify `relay_blind_decrypt_failed` only when the failure is attributable to a transient provider-internal decryption-service error and the same envelope would be expected to succeed on a fresh provider instance. Provider and coordinator retry/idempotency state MUST be keyed by account/session binding when present, opaque provider binding, `kid`, buyer request id, and envelope digest. SPEC-041 v0.1 route reservations and relay-blind envelopes are single-use: any replay detected before dispatch MUST return `relay_blind_replay` without inference or quota reservation, including byte-identical replays. Replay detection for previously seen envelope material MUST take precedence over retryable relay-blind metadata rate or replay-capacity limit classification; a duplicate MUST NOT be masked as `relay_blind_metadata_rate_limited`. Post-dispatch network retries MUST use existing internal request recovery and MUST NOT re-submit the encrypted envelope as a new inference. Pre-dispatch failures MUST not create billable usage. Post-dispatch failures MUST settle according to existing SPEC-005 rules for delivered output only, but MUST NOT claim SPEC-022 positive verified-model-settlement conformance until SPEC-015/SPEC-022 add relay-blind digest support.

The replay-state store MUST be durable across gateway/coordinator restarts and MUST remain effective for at least the configured replay-retention window after each recorded entry's creation time. Disabling and re-enabling relay-blind configuration MUST NOT clear replay-state entries whose retention window has not elapsed.

### SPEC-041-R006 - Settlement, receipts, and accounting

Relay-blind requests MUST use existing account/session quota reservation, gateway `usage_events`, coordinator `request_log`, settlement journal, and receipt-finality paths. The clear reservation cap is an upper bound only. Until SPEC-015/SPEC-022 define relay-blind receipt support, billable input tokens MUST be the lesser of provider-reported input tokens and the buyer-declared clear input-token upper bound, and billable output tokens MUST remain bounded by the clear maximum output tokens and existing delivered-output rules. Provider-reported usage above those clear caps MUST be rejected or clamped before settlement according to the existing over-report policy, and MUST emit relay-blind audit metadata.

Until SPEC-015/SPEC-022 define a relay-blind request digest and receipt/snapshot tuple, relay-blind traffic MUST be excluded only from positive verified-model-settlement claims, not from ordinary usage settlement. For the v0.1 admission-only slice where no successful relay-blind inference is possible, the required buyer-facing settlement metadata surface is `/v1/models` under `tier1_disclosure.relay_blind_request_encryption.settlement`, with `verified_model_settlement: "unavailable_for_relay_blind_request"` and `usage_settlement: "standard_usage_settlement_and_clear_cap_enforcement_still_apply"`. A later implementation that enables successful relay-blind inference MUST emit the same two values on the per-request buyer surface that carries usage or receipt metadata: non-streaming responses MUST use `usage.macprovider.settlement`, streaming responses MUST include it in the final usage/terminal metadata event if such event is enabled, and receipt-finality surfaces MUST carry equivalent fields only after SPEC-015 defines the relay-blind digest tuple. The gateway MUST NOT reuse plaintext prompt-hash evidence to imply relay-blind verified settlement.

The gateway MUST record requested privacy mode separately from effective privacy outcome. Requested mode values are `none` or `relay_blind_required`. Effective outcome values are `plaintext`, `provider_leg_encrypted`, `relay_blind_satisfied`, or `relay_blind_unavailable`. Gateway and coordinator logs MUST contain only request ids, account/session ids, model ids, opaque provider bindings or provider ids where already internal, key ids, envelope/ciphertext SHA-256 digests, status, and reason codes. Raw prompts, tool schemas, decrypted bodies, ciphertext bodies, buyer ephemeral private keys, provider private keys, and API/session bearer secrets MUST NOT be logged.

### SPEC-041-R007 - Error contract and downgrade resistance

SPEC-041 adds these SPEC-006-compatible error codes:

| Code | HTTP | Retryable | Meaning |
|---|---:|---|---|
| `relay_blind_disabled` | 503 | no | Relay-blind request encryption is operator-disabled. |
| `relay_blind_required_unavailable` | 503 | no | No currently routable provider satisfies the required relay-blind mode for the requested model; the same route reservation/envelope MUST NOT be retried. |
| `relay_blind_key_expired` | 503 | yes | The selected relay-blind key is expired or outside its validity window. |
| `relay_blind_envelope_invalid` | 400 | no | The clear envelope is malformed, not closed-schema, exceeds bounds, or is inconsistent with the request route. |
| `relay_blind_route_reservation_invalid` | 400 | no | The route-reservation metadata is malformed, not closed-schema, exceeds bounds, or is inconsistent before any encrypted envelope exists. |
| `relay_blind_endpoint_unsupported` | 400 | no | The request is well-formed, but the requested endpoint family does not support relay-blind request encryption in this version. |
| `relay_blind_replay` | 409 | no | Request id, nonce, or envelope digest was already seen in the replay retention window; resubmission is not permitted regardless of whether the material is byte-identical or different. |
| `relay_blind_metadata_rate_limited` | 429 | yes | Relay-blind metadata admission or replay-state capacity is temporarily saturated before quota reservation or dispatch. |
| `relay_blind_downgrade_rejected` | 400 | no | The request attempted fallback, plaintext dispatch, any mode value other than `required`, or provider/key substitution while relay-blind was required. |
| `relay_blind_decrypt_failed` | 502 | yes | The provider reported an internal relay-blind decrypt service failure before inference commit. |
| `relay_blind_ciphertext_invalid` | 400 | no | The provider could not authenticate the envelope because AAD, ciphertext, tag, key, or envelope material was client-invalid or inconsistent. |
| `relay_blind_committed_failed` | 500 | no | The provider reported relay-blind failure after inference commit; settlement follows delivered-output rules and buyers MUST NOT retry automatically. |
| `relay_blind_provider_unsupported` | 503 | yes | The selected provider does not support relay-blind requests for the model/endpoint. |

Errors MUST use the existing OpenAI-compatible error envelope and retry metadata. For relay-blind 503 codes that are explicitly `retryable: true`, the buyer may attempt a fresh relay-blind transaction after obtaining a new route reservation and constructing a new envelope with a fresh ephemeral key, request id or idempotency material as required by the buyer contract, replay nonce, and ciphertext. `relay_blind_required_unavailable` is intentionally non-retryable for the same request because the v0.1 admission-only slice cannot make progress by replaying a single-use route reservation/envelope; any later attempt MUST start from fresh reservation and envelope material. Buyers MUST NOT replay the same route reservation or encrypted envelope after any relay-blind 503, because the original reservation/envelope is single-use and may subsequently return `relay_blind_replay`. For relay-blind errors, the explicit `retryable` field and this retry action MUST take precedence over generic HTTP-status retry heuristics. Required-mode rejection MUST happen before buyer-visible provider output. Required-mode rejections and downgrade rejections MUST be audited with bounded metadata only.

### SPEC-041-R008 - Configuration, compatibility, and evidence gate

Relay-blind configuration MUST be default-off. Startup validation MUST reject enabled configs with missing replay-retention bounds, impossible timestamp skew, unsupported algorithms, weak key-cache TTLs, or response disclosure settings that would claim relay-blind support when no provider key evidence is active. Disabled relay-blind configuration fields MUST NOT reject startup unless they can affect plaintext behavior. Runtime handling of relay-shaped disabled-mode requests MUST still enforce positive default freshness and replay-retention bounds so disabling and later re-enabling relay-blind admission cannot turn a previously rejected single-use envelope into fresh material.

The first implementation MUST be additive and reversible: disabling relay-blind mode must leave plaintext API-key traffic, wallet-session traffic, demo traffic, `/v1/models`, settlement, receipts, and Tier-2 provider-leg encryption unchanged.

Rollout MUST be staged so mixed binaries fail safely:

1. Old providers/coordinators/gateways MUST ignore or reject unknown relay-blind fields without changing plaintext behavior.
2. Coordinator key ingestion MAY land before buyer admission, but required relay-blind buyer traffic MUST still fail closed until gateway, coordinator, and provider support are all enabled.
3. Gateway `/v1/models` disclosure MAY expose `unsupported`/`available`/`mixed` only from fresh provider-signed key evidence; stale cache or coordinator uncertainty MUST report unsupported or fail closed.
4. Provider decryption support MUST land before required-mode success is enabled for that provider binding.
5. Rollback by disabling relay-blind config at any component MUST reject required relay-blind requests before quota reservation and MUST NOT affect plaintext or SPEC-008 provider-leg encrypted traffic.

Promotion out of draft requires:

- local tests for default-off behavior, required-mode unavailable failure, closed-schema envelope rejection, provider-signed key-record rejection, wallet-signature envelope binding, replay rejection, downgrade rejection, stale key rejection, provider decryption failure, settlement exclusion labels, mixed-binary rollback, and disclosure labels;
- a signed journey result for a successful relay-blind non-streaming request on an isolated provider;
- a signed journey result for required-mode unavailable fail-closed behavior;
- five-lane audit to 0 Critical, 0 High, and 0 Medium findings.

## 5. Product and security gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| Bidirectional response privacy | OUT_OF_SCOPE_V0_1 | @Augustas11 | https://github.com/Augustas11/macprovider/issues/928 | Future SPEC must define encrypted provider response chunks and buyer-side decryption without breaking streaming, settlement, and output safety. |
| Confidential compute / private from provider | OUT_OF_SCOPE_V0_1 | @Augustas11 | https://github.com/Augustas11/macprovider/issues/928 | Hardware-backed confidential runtime design and attestation evidence; cannot be inferred from request encryption. |
| Mainstream browser/client SDK envelope helpers | DEFERRED | @Augustas11 | https://github.com/Augustas11/macprovider/issues/928 | Product design and SDK compatibility review after the wire contract is accepted. |

## 6. Evidence

No implementation evidence is attached in v0.1.0. This SPEC remains draft and non-conformant until the audit loop closes and the implementation records local validation evidence.

## 7. Changelog and history

- 0.1.0 - Initial relay-blind request encryption draft for issue #928. Separates relay-blind buyer privacy from SPEC-008 provider-leg encryption, defines provider key advertisement, closed buyer envelope, fail-closed admission, settlement compatibility, error taxonomy, and evidence gates.
