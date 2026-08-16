# BUILD_SPEC_041_RELAY_BLIND_REQUEST_ENCRYPTION_IMPL

Implement the v0.1 default-off gateway admission and disclosure slice of issue #928 against `SPEC-041-relay-blind-request-encryption.md` v0.1.0. Do not claim full relay-blind request encryption, provider-side decryption, successful encrypted inference, or verified-model settlement support; those require provider/coordinator wire work and future SPEC-015/SPEC-022 receipt support.

## Target result

Ship an additive gateway feature flag that keeps existing plaintext API-key, demo, wallet-session, `/v1/models`, settlement, receipts, and SPEC-008 provider-leg encryption behavior unchanged when disabled. When enabled without provider-signed relay-blind key evidence, the gateway must expose buyer-safe endpoint-scoped disclosure and reject required relay-blind route reservations or encrypted requests before quota reservation or coordinator dispatch using SPEC-006-compatible typed errors.

## Required implementation shape

1. Add gateway config under `features.relay_blind_requests`:
   - `enabled` default `false`;
   - replay retention, timestamp skew, route reservation TTL, and max encrypted request bytes defaults that are positive but do not require secrets or provider keys while disabled;
   - metadata admission rate plus replay row/byte ceilings that prevent reject-path replay/audit storage amplification;
   - validation that rejects enabled configs with non-positive retention/TTL/byte bounds, impossible timestamp skew, or unsupported future algorithm values.

2. Add buyer-facing route reservation endpoint:
   - mount `POST /v1/relay-blind/route-reservations` unconditionally so disabled relay-blind admission returns a typed relay-blind error rather than an untyped 404;
   - require normal buyer authentication, including wallet-session authentication and the route-reservation request signature normally required for wallet-session protected requests, but do not require the later inference-envelope signature at reservation time because that envelope is constructed after reservation;
   - set `Cache-Control: no-store` and `Pragma: no-cache` on every response;
   - accept only closed-schema metadata needed for a reservation: endpoint family, canonical model id, stream flag, max output tokens, input-token upper bound, and encrypted byte bound;
   - disabled v0.1 must reject every otherwise valid chat reservation with non-retryable `relay_blind_disabled`;
   - enabled-but-no-key-evidence v0.1 must reject every otherwise valid chat reservation with non-retryable `relay_blind_required_unavailable` until real provider-signed key evidence exists; buyers must obtain a fresh reservation/envelope before any later attempt;
   - reject malformed, non-closed-schema, over-limit, or internally inconsistent reservation metadata with non-retryable `relay_blind_route_reservation_invalid`;
   - reject well-formed unsupported endpoint families (`responses`, `messages`, unknown values) with non-retryable `relay_blind_endpoint_unsupported` before any coordinator dispatch.

3. Add required-mode inference admission guard:
   - detect relay-blind encrypted envelopes on `/v1/chat/completions`, `/v1/responses`, and `/v1/messages` by closed-schema `version: "relay-blind-request-v1"` and `mode: "required"` before route-specific plaintext schema parsing;
   - treat every body using the `relay-blind-request-*` version namespace as relay-shaped, including unsupported versions, and reject it before plaintext parsing so future-version probes cannot dispatch as plaintext;
   - reject disabled mode with non-retryable `relay_blind_disabled` before parsing as plaintext or reserving quota;
   - reject enabled-but-no-provider-key-evidence mode with non-retryable `relay_blind_required_unavailable` before account request-rate admission, quota reservation, or coordinator dispatch;
   - reject malformed envelope shape with `relay_blind_envelope_invalid`;
   - reject noncanonical or overlong clear model ids with `relay_blind_envelope_invalid` / `relay_blind_route_reservation_invalid` before audit emission;
   - reject overlong or non-printable clear envelope metadata before replay storage or audit emission, and store/index fixed digests for attacker-controlled replay material;
   - enforce configured or disabled-mode default `issued_at_unix` freshness and durable replay state before required-mode audit/unavailable/unsupported outcomes;
   - record relay replay material durably across API-key, demo, and wallet-session envelopes keyed by account/session binding, buyer request id, replay nonce, buyer ephemeral public key, `kid`, provider binding, and envelope digest;
   - reject exact replay before retryable relay-blind metadata or replay-capacity limits, then run a relay-blind-specific API-key/demo metadata admission limiter before new replay/audit writes without consuming the plaintext chat request-rate bucket;
   - for wallet-session relay-blind route reservations and envelope rejects, run the existing SPEC-040 body-bound metadata admission path after signature verification so replay/rate checks still apply without creating quota reservations;
   - reject well-formed required relay-blind envelopes for unsupported endpoint families with `relay_blind_endpoint_unsupported`;
   - reject `mode: "opportunistic"` and every non-`required` relay-blind mode with `relay_blind_downgrade_rejected` in v0.1; plaintext fallback requires a separate plaintext request and must never be inferred from an encrypted envelope;
   - preserve required-mode envelope handling on `/v1/responses` and `/v1/messages` even when those plaintext feature flags are disabled; non-relay plaintext requests on disabled endpoint families keep the existing 404 behavior;
   - for relay-blind retryable 503 errors, buyer retry means a fresh route reservation and fresh envelope, never resubmission of the same encrypted envelope; `relay_blind_required_unavailable` is permanent for the same request in this admission-only slice;
   - audit required-mode rejections with bounded metadata only: endpoint family, required mode class, effective outcome, model, request/account/session identifiers; never raw envelope/ciphertext/decrypted prompt material.
   - do not log prompt fields, ciphertext, raw envelope body, API keys, wallet bearer values, or signatures.

4. Extend `/v1/models` disclosure:
   - preserve existing response when relay-blind config and provider evidence are both inactive;
   - when config is enabled, add an endpoint-family scoped `relay_blind_request_encryption` object under `tier1_disclosure`;
   - report `chat_completions.required_mode` as `required_unavailable` until key evidence exists;
   - report `responses.required_mode` and `messages.required_mode` as `unsupported` in v0.1;
   - split required-mode capability from pool composition and include counts only when derived from buyer-safe aggregate metadata;
   - include settlement metadata at `tier1_disclosure.relay_blind_request_encryption.settlement.verified_model_settlement` and `.usage_settlement` for this admission-only slice; do not add per-inference settlement metadata until successful relay-blind inference is implemented;
   - keep SPEC-008 provider-leg encryption disclosure separate and scoped to `coordinator_to_provider_only`.

5. Extend gateway error classification:
   - add SPEC-041 error codes to the retryable/permanent maps and emitted-code inventory;
   - retryable: `relay_blind_key_expired`, `relay_blind_decrypt_failed`, `relay_blind_provider_unsupported`, `relay_blind_metadata_rate_limited`;
   - permanent: `relay_blind_disabled`, `relay_blind_required_unavailable`, `relay_blind_envelope_invalid`, `relay_blind_route_reservation_invalid`, `relay_blind_endpoint_unsupported`, `relay_blind_replay`, `relay_blind_downgrade_rejected`, `relay_blind_ciphertext_invalid`, `relay_blind_committed_failed`;
   - document/lock that `relay_blind_committed_failed` maps to HTTP 500 when it is emitted by a future provider-decryption implementation, despite being present in the permanent classification map now.

6. Add focused tests:
   - config default-off does not require relay-blind provider evidence;
   - config enabled rejects invalid retention/TTL/skew/byte bounds;
   - disabled `/v1/models` output is byte-shape compatible and omits relay-blind disclosure;
   - enabled `/v1/models` includes endpoint-scoped relay-blind disclosure without overclaiming;
   - route reservations fail closed with no-store headers and no quota reservation;
   - required encrypted chat envelope fails closed before coordinator dispatch and quota reservation;
   - required encrypted chat rejects do not consume the account request-rate bucket or mask later plaintext traffic;
   - route-reservation and envelope clear token caps reject API-key/demo over-limit, overflow, and reservation-cap-inconsistent requests before dispatch, while wallet sessions keep wallet-specific cap errors;
   - stale timestamps and repeated relay-blind envelopes return typed non-retryable failures before audit/unavailable outcomes;
   - repeated signed wallet-session relay-blind reservation/envelope requests hit wallet replay admission without quota reservation;
   - API-key/demo relay-blind rejects hit relay-blind metadata rate and replay-capacity limits without consuming the plaintext chat request-rate bucket;
   - clear model metadata syntax is bounded before route reservation or envelope admission;
   - required-mode reject audits are emitted without raw ciphertext or prompt material;
   - opportunistic and malformed envelopes are rejected without plaintext fallback;
   - `/v1/responses` and `/v1/messages` do not accept required relay-blind encrypted content in v0.1, including when plaintext feature flags are disabled;
   - gateway error-code completeness remains green.

## Non-goals

- Do not implement X25519/HKDF/AES-GCM request encryption in this slice.
- Do not add provider heartbeat key advertisement or provider-side decryption.
- Do not change SPEC-015 receipt tuples, SPEC-022 verified settlement, billing arithmetic, payout math, or coordinator request-log semantics.
- Do not add opportunistic plaintext fallback.
- Do not expose stable provider IDs to buyers.

## Audit gate

Before implementation, the SPEC/governance diff must pass five lanes to 0 Critical, 0 High, and 0 Medium findings: codex code, codex security, codex architect, adversarial verifier, and product design critic. The requested local `omx ask claude` adversarial verifier and product design critic lanes completed after operator re-authentication for the SPEC-first pass; the next Claude rerun is intentionally skipped per operator instruction, so native audit lanes remain the final zero-C/H/M gate for implementation.

After implementation, run review lanes over the full implementation diff as it will land:

- codex code
- codex security
- codex architect
- adversarial verifier
- product design critic

Fix and rerun until all lanes report 0 Critical, 0 High, and 0 Medium findings. Low/Info may be carried only with explicit rationale.
