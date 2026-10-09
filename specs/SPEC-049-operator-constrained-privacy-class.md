# SPEC-049 - Operator-Constrained Privacy Class

**Version:** 0.2.2
Status: draft
Owner: @Augustas11
Issue: https://github.com/Augustas11/macprovider/issues/1749
Audit history: v0.1.0 is the initial default-off Beta contract. v0.2.0 replaces per-provider operator pinning with automatic enrollment, release-derived code approval, and an operator-signed buyer identity directory. Neither version promotes conformance or production deployment.

```json
{
  "spec_id": "SPEC-049",
  "title": "Operator-Constrained Privacy Class",
  "version": "0.2.2",
  "path": "specs/SPEC-049-operator-constrained-privacy-class.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["operator-constrained-privacy-class"],
  "supersedes": [],
  "depends_on": ["SPEC-001", "SPEC-002", "SPEC-006", "SPEC-008", "SPEC-015", "SPEC-022", "SPEC-025", "SPEC-041", "SPEC-042"],
  "implementation_status": "pending-reconciliation",
  "production_status": "not-deployed",
  "last_reconciled_commit": null,
  "last_reconciled_at": null,
  "evidence": [],
  "requirement_id_migration": "complete",
  "gap": {
    "verdict": "DECISION_REQUIRED",
    "owner": "@Augustas11",
    "issue": "https://github.com/Augustas11/macprovider/issues/1749",
    "rationale": "SPEC-049 defines the Beta operator-constrained privacy class. v0.2.0 adds automatic provider enrollment, release-derived code approval, and the operator-signed identity directory; the coordinator, gateway, and buyer client stay default-off and the provider enters the class only on an eligible signed host. The signed JOURNEY-PRIVACY-CLASS-BETA hardware result for the v0.1 requirement set is committed (#1839, #1864), and the v0.1.4 one-time staged-canary exception is recorded (§8.1, Entry 249) and superseded for v0.2.0 code by §8.2. The bounded CLI224 eligible-network activation exception is recorded in §8.3 and Entry 251; live buyer confirmation, a full signed v0.2 journey and SPEC-049-R023 remain pending. No conformance or production promotion is made by this draft."
  }
}
```

## 1. Purpose, scope, and claims

SPEC-049 defines a Beta privacy class, `operator_constrained_beta_v1`, layered on the SPEC-041 relay-blind pilot. The coordinator, gateway, and buyer client keep the class off until configured. A provider enters it automatically when it runs an eligible signed release (SPEC-049-R024), and the coordinator enrolls its keys without a per-provider operator step (SPEC-049-R025). SPEC-041 hides request content from the gateway and coordinator but leaves responses visible to relays and places no constraint on how the provider operator handles plaintext. SPEC-049 adds three things on top of SPEC-041:

1. response encryption from the provider runtime to the buyer reference client, so response content is also hidden from the gateway and coordinator;
2. a provider runtime mode that, on a genuine approved signed release, blocks or refuses the documented ordinary operator access paths to plaintext; and
3. a coordinator routing gate that admits privacy-class work only to providers whose freshly signed runtime posture proves that mode is in force, with no failover and no silent downgrade.

The provider runtime reads plaintext to infer. SPEC-049 does not hide content from the provider runtime. It constrains the ordinary paths by which the person operating the provider Mac could read that plaintext.

### 1.1 Exact claim

The single assurance label for this class is `device_bound_self_attested_beta`. The exact claim is:

> The provider runtime reads plaintext to infer. On a genuine, approved, signed release runtime, the documented ordinary operator access paths are blocked or refused by routing: debugger attach, core dumps, logs, traces, receipts, disk cache, plaintext proxy or subprocess, dev or debug builds, and SIP-off hosts. Posture and code identity are self-reported by the runtime and signed with a device-bound Secure Enclave key. That key is not bound to the code signature, so an operator who modifies the runtime binary can forge them.

Buyer-facing surfaces carry the exact scope string, protection lists, and residual-risk lists fixed in SPEC-049-R020.

### 1.2 Non-claims

The privacy class MUST NOT be described as confidential compute, a hardware enclave, a TEE, provider-blind inference, end-to-end encryption that excludes the provider, code-bound attestation, remote attestation of the executing binary, anonymous routing, unlinkable settlement, protection against a root or kernel-level operator, or proof that the provider did not retain plaintext. It does not hide request metadata (account, model, sizes, timing, token counts, status) from relays.

### 1.3 Scope

In scope for v0.2: the global pool only; endpoint family `chat_completions` only; stream and non-stream; the SPEC-041 reference buyer client (`relay-blind-client`) as the only decrypting client; native in-process MLX serving only; Secure Enclave posture keys and relay-blind identities enrolled automatically on the first attested session (operator-configured pins still override); code identities approved from signed release metadata plus an operator allow-list and deny list; buyer identity pins distributed through the operator-signed identity directory.

Out of scope for v0.2: `responses` and `messages` endpoint families; browser or third-party clients; loopback, subprocess, or IPC runtimes; any Trusted Pool or other pool-scoped request (rejected under SPEC-042-R009, see SPEC-049-R022); code-bound attestation; MDA SIP/SecureBoot evaluation; production activation.

### 1.4 Carry-forward from earlier planning

This SPEC carries forward the following decisions from the stale Product Build 2 and Build 4 planning (issues #1643 and #1645, PR #1471), which are otherwise superseded by this contract:

- exact provider binding before encryption: the buyer encrypts only to one exact provider key record bound by the reservation, never to a pool or a class of providers;
- at-most-once send with no failover: a privacy-class envelope is dispatched at most once to exactly the reserved provider session, and any postdispatch uncertainty recovers with `do_not_resubmit`;
- no silent downgrade: a request that asked for the privacy class either receives the privacy class end to end or fails with a typed error; it never falls back to SPEC-041 relay-blind without the class, to SPEC-008 provider-leg encryption, or to plaintext;
- unknown revocation freshness means the key is unavailable.

Trusted Pool composition remains rejected under SPEC-042-R009. Binding pool identity, manifest digest, and generation into the privacy-class AAD and posture is a follow-up that requires a SPEC-042 amendment first.

### 1.5 v0.2 automatic enrollment

v0.1 required the operator to copy each provider's Secure Enclave public key and relay-blind identity into coordinator configuration, to add each signed release's code identity by hand, and to hand every buyer a per-provider pin file. v0.2 replaces those steps, by explicit operator decision, with:

1. provider default-on: an eligible signed release on a SIP-on host enters privacy mode and creates its keys without a flag (SPEC-049-R024);
2. automatic enrollment: the first posture that verifies under an approved code identity durably binds the provider's keys to its authenticated provider ID, and a later different key quarantines instead of replacing it (SPEC-049-R025, SPEC-049-R026);
3. release-derived approval: every signed release whose `pearl-release.json` carries the SPEC-025 §6.2.1 `provider_code_identity` is approved without a configuration edit (SPEC-049-R027);
4. an operator-signed identity directory that the buyer client verifies against one pinned directory key (SPEC-049-R028).

The claim of §1.1 and the non-claims of §1.2 are unchanged. §2.6 states what enrollment adds to the trust base.

## 2. Threat model

### 2.1 Protected asset

The protected asset is the plaintext of one privacy-class request and its response: messages, tool definitions, response schemas, generated content, and any derived key material (the SPEC-041 shared secret, request key, and the SPEC-049 response key). Request metadata that SPEC-041 leaves in the clear remains in the clear.

### 2.2 Adversaries and capabilities

- **Relays (gateway, coordinator, their operators, and their logs/stores).** They see buyer authentication, model, caps, sizes, timing, token counts, status, and opaque ciphertext. They MUST NOT obtain request or response plaintext.
- **Ordinary provider operator.** A non-root user, or an administrator acting through ordinary tools, on the provider Mac who runs the approved signed release unmodified and tries to read plaintext through: attaching a debugger (`lldb`, `dtrace` pid provider, `task_for_pid`); inducing core dumps; reading logs, trace output, receipts, telemetry, or state files; reading the KV disk tier or conversation cache; routing the runtime through a plaintext loopback proxy or subprocess; running a dev, debug, unsigned, or re-signed build; or running on a host with System Integrity Protection disabled. The privacy class constrains this adversary.
- **Modifying operator.** An operator who patches or rebuilds the runtime binary. Because the Secure Enclave posture key is device-bound and not code-bound (§2.4), this adversary can forge posture and code identity. The privacy class does not constrain this adversary; it is disclosed as a residual risk.
- **Privileged operator.** Root with SIP bypass, kernel extension, firmware, or hardware access. Not constrained; disclosed.
- **Credential holder.** Anyone who holds a provider's admission credential and can open an authenticated provider session for its provider ID, including from a different Mac. Before enrollment this adversary can enroll keys it controls (§2.6). After enrollment it cannot replace the enrolled keys without a quarantine (SPEC-049-R026).
- **Coordinator operator and coordinator host.** The coordinator holds the enrollment table and the online directory signing key (SPEC-049-R028). Whoever controls the coordinator host can enroll or sign a provider identity of its choice and route privacy-class requests to it. v0.1 kept the buyer pin outside the coordinator path; v0.2 puts the coordinator in the buyer's trust path for provider identity. Disclosed (§2.6).

### 2.3 Trust boundary

The trust boundary is the address space of one approved, signed, hardened-runtime provider process on a host reporting SIP on. Inside that boundary plaintext exists in memory. Everything outside it (relays, other local processes, disk, logs, other users) is outside the boundary. The buyer reference client is the other end of the boundary and is trusted by its own user.

### 2.4 Why posture is self-attested

The release CLI cannot carry a `keychain-access-groups` entitlement without a provisioning profile, so the Secure Enclave identity falls back to a keychain item without an access group or to a file-backed CryptoKit Secure Enclave key blob. Either way the key is bound to the device's Secure Enclave but any process of the same user can ask the Secure Enclave to sign with it. A modified binary running as the same user can therefore produce a valid signature over a forged posture statement. The posture signature proves "a process on the pinned device signed this", not "the approved code signed this". Both backends are equally device-bound and not code-bound and both are eligible in Beta; making the file backend ineligible would leave no eligible provider.

### 2.5 Residual risks

The following residual risks are accepted for Beta and MUST be disclosed by SPEC-049-R020:

- a modified binary can forge posture because the Secure Enclave key is device-bound, not code-bound;
- root, SIP bypass, kernel, or firmware compromise;
- physical or hardware attacks;
- GPU and unified-memory residue after a request;
- encrypted swap and hibernation images containing plaintext pages;
- compromise of the live runtime process (memory-safety bug, malicious model artifact);
- a malicious signed release or supply-chain compromise;
- register and stack residue in crash reports;
- the Secure Boot security level is not evaluated;
- immutable Swift `String` copies of the prompt cannot be zeroized;
- relays observe sizes, timing, and token counts;
- provider identity is enrolled on the first attested session of a provider ID (§2.6);
- the coordinator operator signs the provider identity directory (§2.6).

### 2.6 What automatic enrollment trusts

Enrollment is trust on first attested use, bound to the authenticated provider ID. The coordinator enrolls a provider's Secure Enclave public key and relay-blind identity public key on the first posture that, for that provider ID's live authenticated session, is signed by both claimed keys over the coordinator's fresh nonce, reports every SPEC-049-R006 required value, matches an approved and not denied code identity, and matches the session's SPEC-008 Secure Enclave key when the session carries one.

Enrollment protects against:

- a later session for the same provider ID replacing an enrolled key: any different key quarantines the provider and is never enrolled automatically (SPEC-049-R026);
- one identity key or Secure Enclave key serving two provider IDs at once;
- a relay substituting a buyer pin: the buyer accepts only directory entries signed by its pinned directory key, unexpired, and not revoked (SPEC-049-R028);
- a stale buyer view: a directory older than its signed expiry is rejected, and a quarantined or re-enrolled identity is published as revoked.

Enrollment does not protect against:

- whoever first completes an attested session for a provider ID. Posture is self-attested and device-bound, not code-bound (§2.4), so a modifying operator or a credential holder who connects first is enrolled exactly like the genuine device;
- a compromised coordinator host or operator, which can enroll, sign, and route to an identity of its choice. A buyer who must exclude the coordinator from identity trust uses an out-of-band `--identity-pin`, and an operator who must pin a specific device uses the configuration pins, which override enrollment (SPEC-049-R004);
- the residual risks of §2.5, which are unchanged.

## 3. Authority and composition

SPEC-049 owns authority domain `operator-constrained-privacy-class`: the privacy-class marker and its end-to-end binding, the posture statement and its verification, privacy key records and key attestations, the enrollment claim and the durable enrollment of privacy identities, release-derived code approval, the operator-signed identity directory, response encryption, the privacy routing gate, quarantine and kill switch, the privacy error inventory, and privacy disclosure strings.

- **SPEC-041** owns relay-blind identities, key records, pins, envelopes, the transcript, reservations, consume, opaque dispatch, the provider execution journal, accounting, and the relay-blind error inventory. SPEC-049 extends SPEC-041 closed schemas only by the named additions in SPEC-041 §2 (`privacy_key_records`, `privacy-class-reservation-v1`, the `privacy_class` dispatch key, and the two privacy rejection `error_code` values), only when the privacy class is requested. Every SPEC-041 obligation continues to apply to privacy-class work; SPEC-049 only adds constraints. A privacy-class request is a SPEC-041 relay-blind request plus the SPEC-049 marker.
- **SPEC-042** owns pool selection. SPEC-042-R009 stays in force: every pool-scoped privacy-class request is rejected (SPEC-049-R022).
- **SPEC-008** owns provider Tier-2 trust evidence, including the Secure Enclave session key. SPEC-049 consumes it only as a cross-check (SPEC-049-R004) and does not create a new trust tier. The enrolled or operator-pinned posture key is a privacy identity, not an admission credential.
- **SPEC-015** owns receipts. The v0.4 tuple is unchanged and privacy-class work never emits one. Its only receipt is the content-free §N.13 `relay-blind-settlement-v1` receipt (SPEC-049-R010).
- **SPEC-022** owns verified-model settlement. Privacy-class work is excluded from `verified` as relay-blind work is. Under `enforce` it settles only through the SPEC-022 R-14 relay-blind lane as `relay_blind_settled`.
- **SPEC-005** owns settlement arithmetic. Unchanged.
- **SPEC-025** owns the signed `pearl-release.json` and its §6.2.1 `provider_code_identity`. SPEC-049 consumes that field as an approval source (SPEC-049-R027) and does not change it.
- **SPEC-001** owns provider wire framing. SPEC-049 adds the `privacy_class` field on `inference_request`, the `privacy_posture_challenge` / `privacy_posture_response` messages, and the `privacy_key_records` and `privacy_enrollment` advertisement fields.
- **SPEC-002** owns assignment and lifecycle. SPEC-049 adds gate checks without bypassing them.
- **SPEC-006** owns public errors, headers, and JSON/SSE compatibility. SPEC-049 adds the header and error codes in §4 and the `GET /v1/privacy-class/directory` route (SPEC-049-R028).

## 4. Canonical primitives and wire schemas

### 4.1 Primitives

All encodings follow SPEC-041 §3: canonical unpadded base64url; u32-length-prefixed strings and byte strings; u64 big-endian unsigned integers; signed 64-bit big-endian Unix seconds; booleans as u64 `0`/`1`; set-like arrays as a u32 count followed by u32-length-framed elements in strictly ascending byte order with no duplicates. Every JSON object in this section is closed: decoders reject duplicate, unknown, missing, or null fields, non-integer numeric forms, wrong JSON types, and trailing values. `code_cdhash` is exactly 40 lowercase hexadecimal characters (the 20-byte code directory hash). Constant strings:

| Name | Value |
|---|---|
| Privacy class | `operator_constrained_beta_v1` |
| Assurance | `device_bound_self_attested_beta` |
| Response encryption | `buyer_provider_aead_v1` |
| Posture version | `privacy-posture-v1` |
| Posture signing domain | `macprovider/spec049/posture/v1` |
| Key attestation version | `privacy-key-attestation-v1` |
| Key attestation signing domain | `macprovider/spec049/key-attestation/v1` |
| Reservation version | `privacy-class-reservation-v1` |
| Response version | `privacy-response-v1` |
| Final frame version | `privacy-response-final-v1` |
| Response key label | `macprovider/spec049/response/aead/v1` |
| Response nonce-prefix label | `macprovider/spec049/response/nonce-prefix/v1` |
| Response AAD label | `privacy-response-v1` |
| Enrollment claim version | `privacy-enrollment-v1` |
| Identity directory version | `privacy-identity-directory-v1` |
| Identity directory envelope version | `privacy-identity-directory-envelope-v1` |
| Identity directory signing domain | `macprovider/spec049/identity-directory/v1` |

### 4.2 Header marker

`X-MacProvider-Privacy-Class: operator_constrained_beta_v1`. Any other value, repeated header, or list value is invalid. The buyer sends it on the reservation and the chat request. The gateway strips every buyer-supplied copy at ingress and re-sets exactly one trusted copy on each upstream coordinator request (reservation, consume, chat) after validating the buyer's value. The coordinator echoes it on a successful privacy-class chat response. On that same response the coordinator sets exactly one `X-MacProvider-Privacy-Posture-Verified-At` header to the decimal Unix seconds of the posture verification time used by the dispatch-time gate; the gateway strips any buyer-supplied copy, requires exactly one positive integer value or returns `privacy_class_unconfirmed` without writing the body, copies the value into `usage.macprovider.privacy.posture_verified_at_unix`, and does not forward the header to the buyer.

### 4.3 `privacy-posture-v1` statement

The closed statement JSON contains exactly these fields; the signing framing encodes the domain string first and then every field in this order:

| # | Field | JSON type | Framing | Constraint |
|---|---|---|---|---|
| 1 | `version` | string | string | `privacy-posture-v1` |
| 2 | `privacy_class` | string | string | `operator_constrained_beta_v1` |
| 3 | `provider_id` | string | string | authenticated provider ID, 1..128 printable ASCII |
| 4 | `assigned_session` | string | string | current assigned session, 1..128 printable ASCII |
| 5 | `nonce` | string | raw 32 bytes | base64url of the coordinator challenge nonce |
| 6 | `sequence` | integer | u64 | strictly increasing per provider process |
| 7 | `issued_at_unix` | integer | i64 | provider clock |
| 8 | `binary_version` | string | string | provider `binaryVersion` |
| 9 | `code_cdhash` | string | string | 40 lowercase hex |
| 10 | `team_id` | string | string | 10-character Apple team identifier |
| 11 | `signing_identifier` | string | string | code-signing identifier |
| 12 | `hardened_runtime` | boolean | u64 | CS_RUNTIME set |
| 13 | `library_validation` | boolean | u64 | library validation enforced, no `disable-library-validation` |
| 14 | `get_task_allow` | boolean | u64 | `get-task-allow` entitlement or CS_GET_TASK_ALLOW present |
| 15 | `cs_debugged` | boolean | u64 | CS_DEBUGGED set |
| 16 | `p_traced` | boolean | u64 | P_TRACED set |
| 17 | `pt_deny_attach_applied` | boolean | u64 | `ptrace(PT_DENY_ATTACH)` succeeded |
| 18 | `core_dumps_disabled` | boolean | u64 | RLIMIT_CORE soft and hard are 0 |
| 19 | `sip_enabled` | boolean | u64 | `csr_check` reports SIP on |
| 20 | `runtime_source` | string | string | `native_mlx` |
| 21 | `diagnostic_env_clear` | boolean | u64 | none of the refused environment variables (SPEC-049-R007) present |
| 22 | `kv_disk_tier_disabled` | boolean | u64 | KV disk tier off |
| 23 | `se_key_backend` | string | string | `keychain` or `file` |
| 24 | `privacy_key_record_digests` | array of strings | set | SPEC-041 `key_record_digest` values of every privacy key record currently advertised, 0..8 elements |

### 4.4 Posture challenge and response messages

Coordinator to provider, over the authenticated provider WebSocket:

```json
{"type": "privacy_posture_challenge", "version": 1, "nonce": "<base64url 32 random bytes>", "issued_at_unix": 0}
```

Provider to coordinator:

```json
{
  "type": "privacy_posture_response",
  "version": 1,
  "statement": { "...": "closed privacy-posture-v1 object" },
  "se_signature": "<base64url DER ECDSA-P256-SHA256 over the posture framing>",
  "identity_signature": "<base64url raw 64-byte Ed25519 over the posture framing>"
}
```

The encoded response is at most 8192 bytes. `se_signature` is made with the provider's Secure Enclave P-256 key; `identity_signature` is made with the SPEC-041 relay-blind Ed25519 identity key.

### 4.5 `privacy_key_records` and `privacy-key-attestation-v1`

Privacy key records are advertised only in the `privacy_key_records` field of `hello`, `auth_request`, and `heartbeat`, never in `relay_blind_key_records`. Each element is the closed object:

```json
{
  "key_record": { "...": "complete SPEC-041-R002 signed key record" },
  "privacy_key_attestation": {
    "version": "privacy-key-attestation-v1",
    "key_record_digest": "<SPEC-041 key_record_digest>",
    "privacy_class": "operator_constrained_beta_v1",
    "assurance": "device_bound_self_attested_beta",
    "binary_version": "<provider binaryVersion>",
    "code_cdhash": "<40 lowercase hex>",
    "not_before_unix": 0,
    "expires_at_unix": 0
  },
  "signature": "<base64url raw 64-byte Ed25519 over the attestation framing>"
}
```

The attestation framing is the domain string `macprovider/spec049/key-attestation/v1` followed by the attestation fields in the order shown, strings as strings and times as i64. `key_record_digest`, `not_before_unix`, and `expires_at_unix` MUST equal the embedded key record's values. A record set holds at most 8 elements.

### 4.6 `privacy-class-reservation-v1`

The reservation request body is the unchanged SPEC-041-R004 closed request; the privacy class is selected only by the header. The closed success response is the SPEC-041-R004 response field set with `version` set to `privacy-class-reservation-v1` plus exactly these additional fields:

- `privacy_class`: `operator_constrained_beta_v1`;
- `privacy_assurance`: `device_bound_self_attested_beta`;
- `privacy_key_attestation`: the closed attestation object of §4.5 for the reserved `key_record`;
- `privacy_key_attestation_signature`: its Ed25519 signature;
- `privacy_posture_verified_at_unix`: the coordinator verification time of the posture that listed this key digest.

A `relay-blind-reservation-v1` response never carries these fields; a `privacy-class-reservation-v1` response always carries all of them.

### 4.7 Dispatch marker

The SPEC-041 opaque dispatch context and the SPEC-001 `inference_request` both carry `"privacy_class": "operator_constrained_beta_v1"` for privacy-class work and omit the key otherwise. Under SPEC-008 wrapping the field is inside the protected payload.

### 4.8 Response encryption

Keys derive from the SPEC-041-R003 transcript and shared secret of the same envelope:

```text
transcript   = SHA256("macprovider/spec041/relay-blind/transcript/v1" || aad)
response_key = HKDF-SHA256(shared_secret, transcript, "macprovider/spec049/response/aead/v1", 32)
nonce_prefix = HKDF-SHA256(shared_secret, transcript, "macprovider/spec049/response/nonce-prefix/v1", 4)
nonce(seq)   = nonce_prefix || u64be(seq)
frame_aad    = frame("privacy-response-v1") || frame(envelope_digest text) || frame(kid text)
               || frame(request_id) || u64(stream) || u64(seq) || u64(final)
```

`frame()` is the SPEC-041 u32-length string framing; `envelope_digest` is the canonical base64url SPEC-041 envelope digest; `stream` and `final` are u64 `0`/`1`. Each frame is AES-256-GCM over its plaintext with `frame_aad`; `ciphertext` is base64url of ciphertext followed by the 16-byte tag.

Frame plaintexts:

- **Stream:** each non-final frame's plaintext is the exact bytes of one SSE event the ordinary path would have emitted for that request, including content deltas, finish, and the ordinary usage event and `data: [DONE]`.
- **Non-stream:** frame 0 is the exact ordinary JSON response body.
- **Final frame (both):** the closed JSON `{"version":"privacy-response-final-v1","status":"complete|error|cancelled","prompt_tokens":n,"completion_tokens":n}` with nonnegative integers.

`seq` starts at 0, is contiguous, is less than 2^32, and exactly one frame has `final: true`, which is the last frame.

Stream wire, forwarded opaquely by relays:

```text
data: {"object":"macprovider.privacy_frame","version":"privacy-response-v1","seq":0,"final":false,"ciphertext":"<b64url>"}

data: {"object":"macprovider.privacy_frame","version":"privacy-response-v1","seq":N,"final":true,"ciphertext":"<b64url>"}

data: {"object":"chat.completion.chunk","model":"<canonical model>","choices":[],"usage":{"prompt_tokens":n,"completion_tokens":n,"total_tokens":n}}

data: [DONE]
```

Non-stream wire:

```json
{
  "object": "macprovider.privacy_response",
  "version": "privacy-response-v1",
  "frames": [
    {"object": "macprovider.privacy_frame", "version": "privacy-response-v1", "seq": 0, "final": false, "ciphertext": "<b64url>"},
    {"object": "macprovider.privacy_frame", "version": "privacy-response-v1", "seq": 1, "final": true, "ciphertext": "<b64url>"}
  ],
  "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
}
```

The clear usage chunk and the non-stream `usage` object are the only clear content. The gateway MAY add only `usage.macprovider` (SPEC-041-R006 metadata plus `usage.macprovider.privacy`, SPEC-049-R020) to them.

### 4.9 Error inventory

All errors use SPEC-006-compatible envelopes with bounded `error.macprovider` metadata, `retryable`, and `retry_action` as in SPEC-041-R006.

| Code | HTTP | Retryable | Retry action | Emitted when |
|---|---:|---:|---|---|
| `privacy_class_disabled` | 503 | no | `none` | the privacy class is disabled by configuration or the kill switch at the emitting component, including the identity directory route |
| `privacy_class_unavailable` | 503 | no | `none` | no eligible provider, quarantined provider, unapproved code identity, reservation-version mismatch before consume, or an identity directory that cannot be built or signed |
| `privacy_class_downgrade_rejected` | 400 | no | `none` | invalid header value, header on a plaintext body, header/reservation mismatch, marker mismatch at the provider, or pool-scoped privacy request |
| `privacy_class_posture_stale` | 503 | yes | `new_reservation_and_envelope` | posture expired or session changed between reservation and dispatch, or the provider pre-decrypt recheck failed with bound rejection evidence |
| `privacy_class_unconfirmed` | 500 | no | `do_not_resubmit` | a dispatched privacy request returned without exactly one privacy-class echo and exactly one positive `X-MacProvider-Privacy-Posture-Verified-At` value, or privacy completion cannot be confirmed |

`do_not_resubmit` overrides every predispatch action when postdispatch uncertainty exists, exactly as in SPEC-041-R006. SPEC-041-R007 codes continue to apply to the relay-blind layer of the same request.

### 4.10 `privacy-enrollment-v1` claim

A provider in privacy mode advertises, beside `privacy_key_records` in `hello`, `auth_request`, and `heartbeat`, the closed object:

```json
{
  "version": "privacy-enrollment-v1",
  "identity_public_key": "<canonical base64url raw 32-byte Ed25519 relay-blind identity public key>",
  "se_public_key": "<canonical standard base64 raw 64-byte P-256 X||Y Secure Enclave public key>"
}
```

The claim is public material and carries no signature of its own. The coordinator never trusts it alone: it uses the claimed keys only to verify the provider's own key records and the next posture response, and enrolls them only under SPEC-049-R025. A field is omitted, never null. A provider that advertises no privacy key records omits the claim.

### 4.11 `privacy-identity-directory-v1`

The closed directory payload:

```json
{
  "version": "privacy-identity-directory-v1",
  "privacy_class": "operator_constrained_beta_v1",
  "issued_at_unix": 0,
  "expires_at_unix": 0,
  "entries": [
    {
      "identity_public_key": "<canonical base64url raw 32-byte Ed25519 public key>",
      "fingerprint": "<canonical base64url SHA-256 of the raw identity public key>",
      "se_public_key_fingerprint": "<canonical base64url SHA-256 of the raw 64-byte P-256 X||Y point>",
      "source": "enrolled|operator_pin",
      "enrolled_at_unix": 0,
      "revoked": false
    }
  ]
}
```

`expires_at_unix - issued_at_unix` is 60..3600. `entries` holds 0..4096 elements sorted by `fingerprint` in strictly ascending byte order with no duplicate fingerprint. `fingerprint` MUST equal the SPEC-041 fingerprint of `identity_public_key`. Entries carry no provider ID and no model scope: the key record that the reservation returns is signed by the identity and carries its own model scope (SPEC-041-R002).

The signed envelope, which is the exact response body of the directory route:

```json
{
  "version": "privacy-identity-directory-envelope-v1",
  "key_id": "<canonical base64url SHA-256 of the raw 32-byte Ed25519 directory public key>",
  "payload": "<canonical base64url of the exact UTF-8 payload bytes>",
  "signature": "<canonical base64url raw 64-byte Ed25519 signature>"
}
```

The signature covers `frame("macprovider/spec049/identity-directory/v1") || frame(payload bytes)` with the SPEC-041 u32 length framing. Verifiers decode `payload`, verify the signature over those exact bytes, and only then parse them as the closed payload; they never re-serialize JSON to verify. The envelope is at most 1 MiB.
## 5. Normative requirements

### SPEC-049-R001 - Enablement in every component

The coordinator (`privacy_class.enabled: false`), gateway (`features.privacy_class.enabled: false`), and reference client (`--privacy-class` absent) MUST each default the privacy class off. The provider defaults to automatic mode (SPEC-049-R024): it enters privacy mode only on an eligible host, and an explicit opt-out (`privacy_class_beta: false`, `--no-privacy-class-beta`, `MACPROVIDER_PRIVACY_CLASS_BETA=false`, or any explicit `relay_blind_enabled` value) keeps it out; an explicit `relay_blind_enabled: true` keeps plain SPEC-041 relay-blind. A privacy-class request MUST succeed only when the provider is in privacy mode, the other three are enabled, and SPEC-041 relay-blind support is enabled in every component. Enabling the privacy class in a coordinator or gateway whose relay-blind support is disabled, or forcing it on in a provider whose relay-blind support is explicitly disabled, MUST fail configuration validation. Disabling the privacy class at the coordinator, gateway, or client MUST leave plaintext, SPEC-008, and SPEC-041 relay-blind behavior unchanged.

### SPEC-049-R002 - Honest claim and forbidden labels

Every buyer-facing surface that mentions the privacy class MUST use the class `operator_constrained_beta_v1`, the assurance `device_bound_self_attested_beta`, and the exact SPEC-049-R020 strings. No surface, header, response field, documentation, or marketing derived from this implementation MAY claim confidential compute, a hardware enclave or TEE, provider-blind inference, code-bound attestation, or end-to-end encryption that excludes the provider. The assurance label MUST NOT be mapped onto, upgraded to, or reported as any SPEC-008 trust tier.

### SPEC-049-R003 - Closed posture statement

The provider MUST produce, and the coordinator MUST accept only, a `privacy-posture-v1` statement with exactly the §4.3 field set, types, constraints, and framing order, signed over framing bytes that begin with the domain `macprovider/spec049/posture/v1`. The coordinator MUST reject unknown, duplicate, missing, or null fields, an unsorted or duplicated `privacy_key_record_digests` set, a response over 8192 bytes, and any field whose value violates §4.3. The coordinator MUST recompute the framing from the parsed fields and MUST NOT verify signatures over provider-supplied framing bytes.

### SPEC-049-R004 - Identity binding

For each provider ID the coordinator MUST resolve the Secure Enclave key and the relay-blind identity key independently, in this precedence: an operator configuration pin (`privacy_class.provider_se_public_keys[provider_id]`, raw 64-byte point in standard base64; `relay_blind.identity_public_keys[provider_id]`, raw 32-byte key in canonical base64url); otherwise the provider's active durable enrollment (SPEC-049-R025); otherwise, only as an enrollment candidate, the key named by the live session's `privacy-enrollment-v1` claim (§4.10). A configured Secure Enclave pin without a configured identity pin for the same provider MUST fail configuration validation. The coordinator MUST verify `se_signature` as ECDSA-P256-SHA256 against the resolved Secure Enclave key and `identity_signature` as Ed25519 against the resolved identity key. A provider for which either key cannot be resolved MUST be ineligible without quarantine. If the authenticated session also carries a SPEC-008 Tier-2 Secure Enclave key, that key MUST equal the resolved Secure Enclave key; a mismatch is a quarantine trigger (SPEC-049-R017). `provider_id` and `assigned_session` in the statement MUST equal the authenticated live session that received the challenge. `se_key_backend` MUST be in `privacy_class.allowed_se_key_backends` (default `["file", "keychain"]`).

### SPEC-049-R005 - Challenge freshness

The coordinator MUST send each eligible-candidate session (one with accepted privacy key records) a `privacy_posture_challenge` with a fresh 32-byte random nonce every `posture_challenge_interval_seconds` (bounds 15..300, default 60). These periodic interval challenges are mandatory for every session with accepted privacy key records. A session whose accepted key set first appears or changes (a new or rotated record) is additionally challenged immediately; a heartbeat re-advertising an unchanged key set MUST NOT trigger an extra challenge. It MUST accept a response only if: the nonce is an exact echo of the outstanding challenge for that session; it arrives within `posture_response_timeout_seconds` (default 10); `issued_at_unix` is within ±30 seconds of coordinator time; and `sequence` is strictly greater than the last accepted sequence for that session. Each nonce is single-use. Eligibility derived from a verified posture MUST expire `posture_max_age_seconds` (default 150, at least interval plus timeout, at most 600) after coordinator verification. Posture state is in memory only: after a coordinator restart or session close every provider MUST be ineligible until a new posture verifies. A missed or late response makes the provider ineligible without quarantine.

### SPEC-049-R006 - Approved code identity and required posture values

A posture MUST be accepted only when `(team_id, signing_identifier, code_cdhash, binary_version)` is approved, evaluated in this order:

1. a `code_cdhash` listed in `privacy_class.denied_code_cdhashes` is denied;
2. otherwise, when any `privacy_class.approved_code_identities` entry names the same `(team_id, signing_identifier, code_cdhash)`, configuration governs: the identity is approved only if such an entry has `expires_at` in the future and, when it names `binary_version`, that value matches. An expired entry therefore withdraws a release-derived approval;
3. otherwise the identity is approved only if it equals a release-derived identity of SPEC-049-R027, including its `binary_version`.

A denied identity is a quarantine trigger (SPEC-049-R017). An identity that is merely not approved (an unknown, expired, or not yet published cdhash) MUST make the provider ineligible without quarantine and MUST NOT enroll it, so a signed release that providers install before the coordinator holds its metadata is refused by routing, not quarantined. The statement MUST report `hardened_runtime=true`, `library_validation=true`, `get_task_allow=false`, `cs_debugged=false`, `p_traced=false`, `pt_deny_attach_applied=true`, `core_dumps_disabled=true`, `sip_enabled=true`, `diagnostic_env_clear=true`, `kv_disk_tier_disabled=true`, and `runtime_source=native_mlx`. A provider can never approve its own code identity.

### SPEC-049-R007 - Provider hardening before network

When privacy mode is enabled the provider MUST apply the following sequence after the canonical re-exec decision and before any credential is resolved into the runtime configuration, used, or transmitted, and before any model load, local HTTP server, or coordinator connection, and MUST exit non-zero with a bounded reason code on any failure:

1. set RLIMIT_CORE soft and hard limits to 0;
2. call `ptrace(PT_DENY_ATTACH)`;
3. confirm P_TRACED is clear via `sysctl kern.proc.pid`;
4. read `csops(CS_OPS_STATUS)` and require CS_VALID, CS_HARD, CS_KILL, and CS_RUNTIME, refusing CS_DEBUGGED and CS_GET_TASK_ALLOW;
5. validate its own code signature (`SecCodeCopySelf`, `SecCodeCheckValidity`), read cdhash and team identifier, and refuse the entitlements `com.apple.security.get-task-allow`, `com.apple.security.cs.disable-library-validation`, and `com.apple.security.cs.allow-dyld-environment-variables`;
6. require SIP on via `csr_check`, treating an unavailable symbol as SIP off;
7. refuse when any `MACPROVIDER_CB_TRACE`, `MACPROVIDER_PERF_TRACE`, `MACPROVIDER_KEEPALIVE_DEBUG`, or `MACPROVIDER_ALLOW_TEST_FIXTURES` environment variable is set, and refuse when any `DYLD_*` environment variable is observed. On a binary that passes items 4 and 5, the hardened runtime without the `com.apple.security.cs.allow-dyld-environment-variables` entitlement prunes `DYLD_*` before `main`, so those variables are inert and the in-process check cannot observe them. The in-process `DYLD_*` refusal remains as defense in depth for a runtime that does not prune them, which items 4 and 5 already refuse. Acceptance evidence for `DYLD_*` is inertness (no injected library is loaded and dyld emits no diagnostic output), not a refusal exit;
8. refuse a loopback runtime, an enabled KV disk tier, relay-blind disabled, or a missing state directory.

Unsigned, ad-hoc-signed, dev, and debug builds therefore cannot start in privacy mode. Reading the provider's own configuration file before this sequence is not a credential resolution. A same-user process that could observe that window is the operator (§2.2), whose own same-user-readable configuration already holds the credential, and same-user Secure Enclave and process access is already in scope of §2.4 and §2.5. Immediately before decrypting every privacy-class request the provider MUST re-check P_TRACED and CS_DEBUGGED; on failure it MUST NOT decrypt, MUST send SPEC-041-R005 bound rejection evidence with `error_code: privacy_class_posture_stale`, and MUST permanently stop posture responses and privacy key advertisement for the process lifetime. A test-fixture posture source MAY be injected only in a debug or test build of the fixture command, gated by `MACPROVIDER_ALLOW_TEST_FIXTURES=1`, which by step 7 can never run in production privacy mode.

### SPEC-049-R008 - Ephemeral privacy keys and key attestation

The privacy-class X25519 private key MUST exist only in process memory and MUST NOT be written to disk, keychain, logs, or state files. Each privacy key record lifetime (`expires_at_unix - not_before_unix`) MUST be at most 3600 seconds; rotation is by in-memory replacement or process restart. Privacy key records MUST be advertised only in `privacy_key_records` (§4.5), each with a valid `privacy-key-attestation-v1` signed by the SPEC-041 Ed25519 identity, and MUST NOT appear in `relay_blind_key_records`. The coordinator MUST verify the key record per SPEC-041-R002 and the attestation signature against the identity key resolved by SPEC-049-R004, field equality with the record, and that `code_cdhash` is approved for the attested `binary_version` (SPEC-049-R006; a denied cdhash quarantines, an unapproved one rejects the advertisement without quarantine), and MUST store accepted records with key class `privacy`. Records verified only against an enrollment-candidate claim are stored but cannot pass the routing gate until a posture verifies and enrolls the provider (SPEC-049-R025). The privacy execution journal and any privacy state live under `<state>/privacy/` with SPEC-041-R005 modes and content limits.

### SPEC-049-R009 - In-process native runtime only

Only the in-process `native_mlx` runtime MAY serve privacy-class work. The provider MUST NOT pass privacy-class plaintext through a loopback HTTP runtime, a subprocess, an IPC hop, or any network socket. Privacy-class work MUST arrive only over the authenticated coordinator WebSocket; the provider's local HTTP server MUST NOT accept, route, or expose privacy-class requests.

### SPEC-049-R010 - Sink suppression

For every privacy-class request the provider MUST produce no SPEC-015 v0.4 receipt and no receipt containing any value derived from plaintext request or response content, no KV telemetry, no egress or performance trace, no conversation-cache entry or lookup, and no KV disk-tier write. No component MAY write prompt bytes, completion bytes, decrypted request JSON, frame plaintext, shared secrets, or key bytes to any log, trace, error message, metric label, crash breadcrumb, SQLite store, or state file. Errors carry bounded codes and digests only. When the dispatch carries SPEC-001-R005 `relay_blind_settlement` metadata, the provider MUST produce at most one SPEC-015 §N.13 `relay-blind-settlement-v1` receipt for the attempt and no other receipt artifact; it produces exactly one once the attempt has a pinned model handle and validated usage, and otherwise withholds it as SPEC-001-R005 item 3 requires (missing evidence under SPEC-022 R-14.6). Its response digest covers the §4.8 ciphertext frames, and it is never written to a log, trace, or state file.

### SPEC-049-R011 - Plaintext lifetime

The provider SHOULD zero decrypted request bytes and its copy of the shared-secret bytes immediately after the request is parsed, and SHOULD zero each response plaintext buffer immediately after it is sealed. Deviation is acceptable only where the language type is immutable and cannot be zeroed (Swift `String` values holding prompt or completion text, and CryptoKit-owned key storage, which zeroes on deallocation); that deviation MUST be disclosed in the SPEC-049-R020 residual risks.

### SPEC-049-R012 - End-to-end marker binding

The header marker (§4.2), the reservation version (§4.6), the reservation row's privacy flag, the opaque dispatch context key, and the `inference_request` field (§4.7) MUST agree for every request. The coordinator MUST compare the header with the stored reservation privacy flag at consume and at chat, in both directions. The gateway and coordinator MUST reject the header on a non-envelope (plaintext) body before quota or dispatch. A privacy-mode provider MUST reject relay-blind dispatch that lacks the marker, and a provider not in privacy mode MUST reject relay-blind dispatch that carries the marker; both rejections occur before decryption with SPEC-041-R005 bound rejection evidence carrying `error_code: privacy_class_downgrade_rejected`. Every such mismatch MUST surface as `privacy_class_downgrade_rejected`.

### SPEC-049-R013 - Routing gate at every phase

Privacy-class model scopes follow SPEC-041-R004: both exact names of one uniquely matched pinned signed-catalog row may be advertised. The buyer-selected signed name remains unchanged through every cryptographic and routing binding. No general billing-equivalence expansion is allowed.

At reservation, at consume, and immediately before dispatch, the coordinator MUST re-evaluate all of: the privacy class is enabled in configuration; the durable kill switch is not set (SPEC-049-R018); the provider is not quarantined; a verified posture for the same live session is no older than `posture_max_age_seconds`; the reserved privacy key digest is listed in that posture; the posture cdhash is still approved and unexpired; the key record is fresh and unrevoked with known revocation freshness; and the live WebSocket session is the one bound by the reservation. A privacy-class reservation MUST select only privacy-class key records, and a non-privacy relay-blind reservation MUST NOT select them. Failure before consume returns `privacy_class_unavailable` or `privacy_class_disabled`; failure between consume and dispatch burns the reservation, refunds held quota, and returns `privacy_class_posture_stale` or `privacy_class_disabled`. There MUST be no failover, retry, alternate provider, downgrade to plain SPEC-041 relay-blind, or downgrade to plaintext.

### SPEC-049-R014 - Response AEAD

The provider MUST seal every privacy-class response exactly as §4.8 specifies: response key and nonce prefix from the SPEC-041 transcript with the SPEC-049 labels, nonce as prefix plus u64 big-endian sequence, the exact frame AAD, the closed frame and final-frame schemas, contiguous sequence from 0, and exactly one final frame as the last frame. On cancellation or runtime error after decryption the provider MUST still emit an authenticated final frame with status `cancelled` or `error` when its WebSocket is writable. The response key MUST differ from the request key; reusing a nonce under one response key is forbidden.

### SPEC-049-R015 - Opaque relay of responses

The coordinator and gateway MUST forward privacy frames byte-for-byte, MUST NOT decode, parse, or log ciphertext, and MUST NOT treat a missing `choices` field in a privacy frame as an error. They MAY bound and annotate only the clear usage chunk or non-stream `usage` object. Settlement uses the clear usage bounded by the SPEC-041-R006 caps. On `unknown_postdispatch` the coordinator MUST settle known input only and MUST record a delivered-output estimate of 0, because it cannot count output from ciphertext. Under SPEC-022 `enforce` that row is recorded but becomes payable only with a `relay_blind_settled` verdict (SPEC-022 R-14.6). After a 200 response for a privacy-class request without exactly one coordinator privacy-class echo and exactly one positive `X-MacProvider-Privacy-Posture-Verified-At` value (§4.2), the gateway MUST return `privacy_class_unconfirmed` without writing the body.

### SPEC-049-R016 - Buyer verification

The reference client MUST, before encryption, verify the reservation version is `privacy-class-reservation-v1`, the key record against the buyer pin per SPEC-041-R002 (the `--identity-pin` file when given, otherwise the SPEC-049-R028 directory entry whose fingerprint equals the record's `identity_fingerprint`), the key attestation signature against the same pin, attestation field equality with the record, and `privacy_assurance` equal to `device_bound_self_attested_beta`. After the response it MUST decrypt every frame, enforce contiguous sequence from 0, exactly one final frame, no frame after the final frame, a final status of `complete` for success, clear usage equal to the final frame's usage after cap bounding, and the SPEC-049-R020 response headers. Any failure after send MUST exit non-zero with a message ending `do not resubmit` and MUST NOT print undecrypted or partially verified content as a success.

### SPEC-049-R017 - Quarantine and key revocation

On a posture signature failure, a denied code identity, any SPEC-049-R006 required value violated, a sequence regression, a `code_cdhash` change within one session, a key attestation cdhash differing from the session's verified posture cdhash, a SPEC-008 Secure Enclave key mismatch, or an enrollment key change (SPEC-049-R026), the coordinator MUST durably quarantine the provider for `privacy_class.quarantine_seconds` (default 86400) and durably revoke all of its privacy key records. If the durable quarantine write fails, the coordinator MUST hold the quarantine in memory, treat the provider as quarantined, and retry the write on every later check until it succeeds, unless an operator `unquarantine` or `reenroll` of that provider is recorded after the failure, which drops the held quarantine. A quarantined provider MUST be ineligible across coordinator restarts until expiry or explicit operator unquarantine, and its identity directory entry MUST be published as revoked while the quarantine lasts. A posture timeout, a missed challenge, an unapproved but not denied code identity, or an unresolvable key MUST make the provider ineligible without quarantine.

### SPEC-049-R018 - Durable kill switch

A durable `privacy_class_control` row with `disabled = 1` MUST block privacy-class reservation, consume, and dispatch from the next request onward and MUST move every held predispatch privacy-class reservation to `rejected` with quota refund. A store read error MUST be treated as disabled. The control is operated with `coordinator-cli privacy-class status|disable --reason|enable|quarantine --provider --reason --seconds|unquarantine --provider|reenroll --provider --reason` against the configured relay-blind SQLite store; `status` also lists active and revoked enrollments with the provider ID, public key fingerprints, and enrolling code identity, never key bytes. Disabling never affects plain SPEC-041 relay-blind or plaintext traffic.

### SPEC-049-R019 - Shared error inventory

The coordinator and gateway MUST implement the identical §4.9 code set with the identical HTTP status, retryable flag, and retry action, and each MUST have a completeness test against one shared inventory fixture. Neither component MAY emit a privacy code outside the inventory or remap one to a generic error.

### SPEC-049-R020 - Exact disclosure strings

Successful privacy-class responses MUST carry these response headers:

```text
X-MacProvider-Privacy-Class: operator_constrained_beta_v1
X-MacProvider-Privacy-Assurance: device_bound_self_attested_beta
X-MacProvider-Response-Encryption: buyer_provider_aead_v1
```

`usage.macprovider.privacy` (non-stream `usage` object and stream clear usage chunk) MUST be the closed object `{class, assurance, scope, protects, does_not_protect, residual_risks, posture_verified_at_unix}` with `class` and `assurance` as above, `posture_verified_at_unix` from the coordinator's `X-MacProvider-Privacy-Posture-Verified-At` header on that chat response (§4.2), and these exact values in this order.

`scope`:

```text
request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_self_attested_device_bound_not_code_bound
```

`protects`:

1. `request_content_from_gateway_and_coordinator`
2. `response_content_from_gateway_and_coordinator`
3. `debugger_attach_to_approved_signed_runtime`
4. `core_dumps_of_approved_signed_runtime`
5. `prompt_and_completion_in_provider_logs_traces_receipts_and_telemetry`
6. `prompt_and_completion_in_provider_disk_and_conversation_caches`
7. `plaintext_proxy_or_subprocess_runtime_hop`
8. `dev_debug_unsigned_or_unapproved_builds_refused_by_routing`
9. `sip_disabled_hosts_refused_by_routing`

`does_not_protect`:

1. `provider_runtime_reads_plaintext_to_infer`
2. `operator_running_a_modified_runtime_binary`
3. `request_metadata_visible_to_relays`
4. `confidential_compute_or_hardware_enclave_execution`
5. `end_to_end_encryption_excluding_the_provider`
6. `pool_scoped_requests`

`residual_risks`:

1. `modified_binary_can_forge_posture_se_key_device_bound_not_code_bound`
2. `root_sip_bypass_kernel_or_firmware_compromise`
3. `physical_or_hardware_attack`
4. `gpu_and_unified_memory_residue`
5. `encrypted_swap_and_hibernation_images`
6. `compromise_of_the_live_runtime_process`
7. `malicious_signed_release_or_supply_chain`
8. `crash_report_register_and_stack_residue`
9. `secure_boot_level_not_evaluated`
10. `immutable_prompt_strings_not_zeroized`
11. `relays_observe_sizes_timing_and_token_counts`
12. `provider_identity_enrolled_on_first_attested_session`
13. `coordinator_operator_signs_provider_identity_directory`

`/v1/models` MAY expose `tier1_disclosure.operator_constrained_privacy` (omitted when the class is disabled) with `version: privacy-class-disclosure-v1`, the same class, assurance, scope, and lists, plus per-model buyer-safe `capable_provider_count` and `incapable_provider_count` derived only from currently eligible sessions. The reference client MUST print the class, assurance, scope, and residual risks on stderr for every privacy-class run. These strings change only by a SPEC-049 version bump.

### SPEC-049-R021 - Automated redaction proof

An automated integration test MUST run privacy-class stream and non-stream requests with a canary prompt and a canary completion and MUST prove that neither canary, nor the base64url of the buyer ephemeral key or any derived key, appears in provider, coordinator, or gateway stdout/stderr, any SQLite store, the provider state directory, or the scenario temporary directories. It MUST also prove that the `relay-blind-settlement-v1` receipt and every row derived from it contain no canary, no plaintext-derived hash (no SHA-256 of the canary prompt, the canary completion, or the decrypted request or response), and no key material. The same suite MUST cover plaintext downgrade, header strip and inject, envelope replay, wrong key record, stale posture, revoked and quarantined providers, unapproved cdhash, debugger-attached posture, tampered and truncated responses, and the kill switch. It MUST also run a provider with no operator pins that the coordinator enrolls automatically, with the buyer pin taken from the signed identity directory, and MUST cover an enrollment key change (quarantine and a revoked directory entry), a directory signed by another key, and an expired directory.

### SPEC-049-R022 - Composition limits

Any privacy-class request with a nonempty pool selection or other pool intent MUST be rejected with `privacy_class_downgrade_rejected` before reservation, quota, or dispatch, preserving SPEC-042-R009. Accounting, positive-receipt and reward exclusion, and SPEC-022 mode limits follow SPEC-041-R006: under `enforce`, privacy-class work settles only through the SPEC-022 R-14 lane, and under `off` and `observe` the SPEC-041-R006 rules apply. SPEC-005 arithmetic and the SPEC-015 v0.4 receipt tuple are unchanged. SPEC-022 finality changes only by the R-14 `relay_blind_settled` outcome, which is never `verified`.

### SPEC-049-R023 - Promotion gate

This SPEC MUST remain `draft` with production status `not-deployed`, and every SPEC-049 requirement MUST remain non-conformant, until all of: the automated suites of SPEC-049-R021 and the unit/vector tests for every requirement pass; a signed `JOURNEY-PRIVACY-CLASS-BETA` result from a signed and notarized release on real hardware is committed; a staged canary rollout with an explicit activation exception under specs/PROCESS.md is recorded; and code, security, and architecture audits of the full diff report 0 Critical, 0 High, and 0 Medium findings.

### SPEC-049-R024 - Provider automatic mode and eligibility

The provider MUST resolve privacy mode from non-secret inputs (flag > `MACPROVIDER_PRIVACY_CLASS_BETA` > `privacy_class_beta`), before any credential is resolved (SPEC-049-R007 ordering), into exactly one of:

- **forced**: an explicit true. Relay-blind support is turned on unless it is explicitly disabled, which is a configuration error. The SPEC-049-R007 refusal (non-zero exit with bounded reason codes) is unchanged.
- **off**: an explicit false, any explicit `relay_blind_enabled` value (flag, environment, or configuration) while the class is unset, or an autotune candidate or `--no-join` run. An explicit `false` opts out; an explicit `true` keeps the operator's plain SPEC-041 relay-blind serving and its `relay_blind_key_records`, which a coordinator without the privacy class still understands.
- **automatic**: the class and `relay_blind_enabled` are both unset. The provider MUST first run a read-only eligibility check that does not call `ptrace` or `setrlimit`: arm64; `csops(CS_OPS_STATUS)` readable with CS_VALID, CS_HARD, CS_KILL, and CS_RUNTIME set and CS_DEBUGGED and CS_GET_TASK_ALLOW clear; a valid code signature with a 40-hex cdhash, a team identifier, and a signing identifier; none of the SPEC-049-R007 refused entitlements; SIP on; P_TRACED clear; none of the SPEC-049-R007 refused environment variables; the native in-process runtime; the KV disk tier off; the Secure Enclave identity loads or is created; and the relay-blind state directory (the configured one, else `~/.config/macprovider/relay-blind`) opens or is created with the SPEC-041 custody modes. When every check passes, the provider turns on relay-blind support and privacy mode with that state directory and runs the full SPEC-049-R007 hardening. The configuration snapshot that was checked MUST be the one that serves: if the credential-resolving read differs in any input the check or hardening used, automatic mode serves ordinarily (`auto_hardening_failed reasons=configuration_changed`) and forced mode refuses to start. A fallback to ordinary serving after the automatic check MUST refuse to start instead if the serving snapshot forces the class on. When any check fails, the provider MUST stay in ordinary serving, MUST NOT advertise privacy key records or an enrollment claim, and MUST log one line `privacy_class auto_ineligible reasons=<bounded codes>`. When the SPEC-049-R007 hardening then fails, the provider MUST NOT enter privacy mode, MUST log `privacy_class auto_hardening_failed reasons=<bounded codes>`, and MUST continue ordinary serving instead of exiting; process-wide hardening already applied (core dumps off, `PT_DENY_ATTACH`) stays applied.

In privacy mode the provider creates its relay-blind Ed25519 identity and its Secure Enclave P-256 key on first use, keeps both across restarts and upgrades, and advertises the §4.10 claim beside its privacy key records. Unsigned, ad-hoc-signed, dev, and debug builds, SIP-off hosts, loopback runtimes, and KV-disk-tier hosts therefore serve ordinary traffic and never enter the class automatically.

### SPEC-049-R025 - Automatic enrollment

When a posture response arrives for a live authenticated session whose provider has no active enrollment and whose two keys are not both configuration-pinned, the coordinator MUST enroll that provider only if one verification of that response passes every check: both signatures verify under the resolved keys (SPEC-049-R004, with the session's §4.10 claim supplying each key that is not configuration-pinned); `provider_id` and `assigned_session` match the live session; SPEC-049-R005 nonce, skew, sequence, and timeout; every SPEC-049-R006 required value; an approved and not denied code identity; the SPEC-008 Secure Enclave key equals the resolved key when the session carries one; the key backend is allowed; the kill switch is not set; and the provider is not quarantined. Enrollment inserts one durable row in the relay-blind store table `privacy_class_enrollment` bound to the authenticated provider ID, holding the identity public key, the Secure Enclave public key, their SPEC-041-style fingerprints, the enrolling posture's `team_id`, `signing_identifier`, `code_cdhash`, and `binary_version`, and the enrollment time. The enrolling session MUST still be the live, unreplaced session that received the challenge, checked under the same lock that session replacement holds, and every key digest its posture lists MUST still be fresh and unrevoked for that session, checked inside the same store transaction as the insert, so a replaced session or one whose keys a concurrent `reenroll` revoked cannot enroll. The row MUST be committed before that posture counts as verified; a store failure leaves the provider ineligible. That row is the pin for every later key record, key attestation, and posture of the provider.

There MUST be at most one active enrollment per provider ID. An identity public key or Secure Enclave public key that is active in another provider's enrollment MUST NOT be enrolled; that provider stays ineligible without quarantine. A key advertisement, a claim, or a posture that fails any check never creates or changes an enrollment. A provider whose two keys are both configuration-pinned is never enrolled. Enrollments survive coordinator restarts; posture eligibility stays in memory per SPEC-049-R005, and the kill switch and quarantine semantics of SPEC-049-R017 and SPEC-049-R018 are unchanged.

### SPEC-049-R026 - Key change quarantine and re-enrollment

After enrollment, a §4.10 claim or a posture whose identity key or Secure Enclave key, where not configuration-pinned, differs from the active enrollment MUST NOT replace the enrollment. The coordinator MUST quarantine the provider under SPEC-049-R017 with reason `privacy_enrollment_key_changed`, which revokes its privacy key records, and MUST keep the enrollment active so its directory entry is published as revoked while the quarantine lasts. Quarantine expiry does not change the enrollment, so the same different key quarantines again. The re-enrollment path is the operator command `coordinator-cli privacy-class reenroll --provider <id> --reason <text>`, which in one transaction marks the active enrollment revoked with that reason and time, revokes the provider's privacy key records, rejects its held predispatch privacy reservations, and clears its quarantine; the next posture that passes SPEC-049-R025 enrolls the provider's current keys. Revoked enrollments are published as `revoked: true` for 30 days. Operator configuration pins override enrollment (SPEC-049-R004). v0.2 has no in-band signed key rotation.

### SPEC-049-R027 - Approved code identities from signed release metadata

When `privacy_class.release_code_identities.metadata_dir` and `privacy_class.release_code_identities.public_key_path` are configured, the coordinator MUST load release-derived identities at startup and again at every posture challenge interval. It reads each regular, non-symlink file named `<name>.json` that has a regular, non-symlink sibling `<name>.json.sig` (each file at most 1 MiB; when more than 256 pairs are present, only the 256 newest by `v<major>.<minor>.<patch>` tag are read and the rest are reported as rejected, so growth drops the oldest releases and never the whole set), verifies the signature as DER ECDSA-P256-SHA256 over the exact file bytes against the PEM SubjectPublicKeyInfo P-256 release signing key (the key the Pearl updater and `scripts/provider-code-identity.py --emit-approved-identity` verify), and parses the top-level `provider_code_identity` object strictly per SPEC-025 §6.2.1: exactly its seven fields, `signing_identifier` `live.malibu.provider.cli`, a 10-character team identifier, `binary_version` X.Y.Z, and exactly one `arm64` slice with a 40-hex `code_cdhash`. Each verified object contributes one approved identity `(team_id, signing_identifier, code_cdhash, binary_version)` without an expiry. A file that fails any check contributes nothing and is logged by name only. A directory that cannot be read yields an empty release-derived set until the next successful load, so the failure is closed. The Pearl updater, on installing a verified release whose signed `pearl-release.json` carries `provider_code_identity`, MUST write that file and its signature byte for byte into the metadata directory as `<tag>.json` and `<tag>.json.sig`, so every signed CLI release is approved without a configuration edit. Withdrawal is by `denied_code_cdhashes` or by an expired `approved_code_identities` entry (SPEC-049-R006).

### SPEC-049-R028 - Operator-signed identity directory

**Key and custody.** The directory is signed with a dedicated Ed25519 key, `privacy-identity-directory-v1`, distinct from the release signing key, the SPEC-023 static-feed keys (for example `streamvc-autotune-static-v4`), and every catalog, receipt, admission, and relay-blind key. The directory changes whenever a provider enrolls or is quarantined, so it is signed online by the coordinator; offline static-feed keys MUST NOT be placed on the coordinator host. `coordinator-cli privacy-class directory-keygen --out <absolute path>` creates the key: it writes the 32-byte seed as canonical base64url into a new file with mode 0600 (exclusive create, no symlink) and prints only the public key and its `key_id`. The coordinator loads it from `privacy_class.directory.signing_key_path`, which is required when the class is enabled and MUST name a regular, non-symlink file with mode 0600 or 0400 owned by the coordinator user or root. Private key bytes MUST never be logged or printed. Rotation is a new key, a coordinator restart, and a new buyer pin; a compromised key is replaced the same way and old buyer pins MUST be withdrawn.

**Content.** The coordinator MUST publish one §4.11 entry per provider whose identity key and Secure Enclave key both resolve (SPEC-049-R004) from configuration pins (`source: operator_pin`) or an active enrollment (`source: enrolled`, including a provider whose identity key is configuration-pinned but whose Secure Enclave key is enrolled), with `revoked: true` while the provider is quarantined, plus each enrollment revoked in the last 30 days as `revoked: true`. `issued_at_unix` is the signing time and `expires_at_unix` is that time plus `privacy_class.directory.ttl_seconds` (60..3600, default 300). The coordinator MAY reuse one signed envelope for at most 15 seconds. A store error MUST fail the route closed with `privacy_class_unavailable`, never serve a partial directory.

**Routes.** The coordinator serves `GET /v1/privacy-class/directory` on its gateway-context buyer port. The gateway serves `GET /v1/privacy-class/directory` to buyers authenticated with an API key as for a reservation (a wallet session has no signed-request profile for this route in v0.2 and is refused with `privacy_class_unavailable`; wallet-session buyers pin with `--identity-pin`), forwards the coordinator's 200 body byte for byte (at most 1 MiB) with `Cache-Control: no-store`, maps errors to the §4.9 inventory, and adds no trust: it does not verify, re-sign, filter, or cache the directory. Both routes return `privacy_class_disabled` when the class is disabled in that component.

**Buyer.** `relay-blind-client --privacy-class` without `--identity-pin` MUST take the directory public key from `--directory-public-key` (canonical base64url raw 32-byte Ed25519) or `MACPROVIDER_PRIVACY_DIRECTORY_PUBLIC_KEY`, pinned once by the buyer from an operator channel outside the gateway and coordinator path. Before the reservation it fetches the directory from the gateway, and MUST reject it unless the envelope is closed and at most 1 MiB, `key_id` equals the pinned key's fingerprint, the signature verifies over the exact payload bytes, the payload is closed and valid per §4.11, `issued_at_unix` is at most 60 seconds in the future, and the current time is before `expires_at_unix`. After the reservation it selects the entry whose `fingerprint` equals the key record's `identity_fingerprint`; a missing or revoked entry MUST fail before encryption. The in-memory pin is the SPEC-041-R002 pin with that identity key and fingerprint, the key record's models (which MUST include the requested model), `chat_completions`, and the directory's validity window. `--identity-pin` overrides the directory and is required with a wallet session. A buyer that needs no coordinator in its identity trust path uses `--identity-pin`.

## 6. Operator runbook requirement

The normative operator procedure is `docs/runbooks/privacy-class-beta-operations.md`. It covers: enabling the coordinator with automatic enrollment, release-derived approval, and the directory key; generating and holding the directory key and distributing its public key to buyers; the provider opt-out and the eligibility log lines; the optional configuration pins that override enrollment; enabling the gateway and the buyer client; the incident procedure (kill switch, quarantine, enrollment key change, re-enrollment, key revocation, rotation by restart, directory key rotation); and the residual-risk table of §2.5. Tooling and documentation MUST never print private key bytes.

## 7. Implementation, tests, and journeys

The authoritative mapping is `specs/CONFORMANCE.json`. All SPEC-049 requirements map to `JOURNEY-PRIVACY-CLASS-BETA`; implementation and test selectors are added as the implementation lands. Planned surfaces: shared Go privacy crypto and types in both relay-blind modules with a byte-identity parity check; Swift crypto parity against the shared vector `test/fixtures/relay-blind/privacy-response-v1.json`; provider hardening, posture responder, and response sealing; coordinator configuration, store, posture verification, routing gate, and kill-switch CLI; gateway marker, opaque relay, and disclosure; reference-client verification; and the cross-service redaction and adversarial integration suite. v0.2 adds: provider automatic-mode eligibility and the enrollment claim; the coordinator enrollment table, key-change quarantine, `reenroll` and `directory-keygen` CLI, release-derived approval loader, and directory signer and route; the Pearl updater release-identity staging; the gateway directory passthrough; the shared directory verifier in both relay-blind modules under the parity check; and client directory auto-pin.

## 8. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-049-R001`..`SPEC-049-R028` | `DECISION_REQUIRED` | `@Augustas11` | `#1749` | Implementation, automated tests, signed hardware journey on a v0.2 release, staged canary, three-lane audits |
| In-band signed key rotation | `DECISION_REQUIRED` | `@Augustas11` | follow-up of `#1749` | A rotation statement signed by the enrolled keys; v0.2 re-enrolls only through the operator |
| Code-bound posture key | `DECISION_REQUIRED` | `@Augustas11` | follow-up of `#1749` | Malibu.app-embedded provider with `keychain-access-groups`; a new label requires a SPEC-049 amendment first |
| Trusted Pool composition | `DECISION_REQUIRED` | `@Augustas11` | follow-up of `#1749` | SPEC-042-R009 amendment binding pool identity into AAD and posture |

### 8.1 Limited activation exception: staged production canary (2026-10-06)

This is the one-time limited activation exception that `specs/PROCESS.md` allows and that SPEC-049-R023 requires before promotion. It is recorded in `beta/DECISION_CRITERIA.md` Entry 249. It does not mark any SPEC-049 requirement conformant, and this SPEC stays `draft`.

- **Scope.** Production Pearl (`coordinator.malibu.tech`, `api.malibu.tech`), with every limit below:
  - **Coordinator configuration:**
    - `coordinator.require_gateway_context: true`;
    - `settlement.verified_model_settlement_mode: enforce`;
    - `relay_blind.enabled: true`, with a non-empty `relay_blind.sqlite_path` and `relay_blind.enforce_settlement_profile: relay-blind-settlement-v1` (SPEC-022 R-14);
    - `privacy_class.enabled: true`, with `privacy_class.allowed_se_key_backends: [file, keychain]`.
  - **One provider.** Exactly one provider is pinned in `privacy_class.provider_se_public_keys` and `relay_blind.identity_public_keys`, under the same provider id: the operator's pinned canary provider (its id is recorded in the operator's private configuration). Coordinator validation accepts more than one pin, so this one-provider limit is an operator configuration control, checked by the operator against this section before each restart. Any added pin requires a new dated exception.
  - **One approved code identity.** `approved_code_identities` holds exactly one entry for the signed and notarized release `1.8.217`: team `YF7XNRJUG4`, identifier `live.malibu.provider.cli`, cdhash `df44bcf4ef55e543eb49c75187e868b0fce1a8a2`, `binary_version: "1.8.217"`, and `expires_at` no later than this exception's expiry. These are the predicates the coordinator enforces. The release binary sha256 `a6ea51d7ad19359a21fac63995194523264035fbca2ab32dceeede9d9da739bb` is evidence only; the coordinator does not check it.
  - **Provider.** On the pinned provider only, set `relay_blind_enabled: true`, `privacy_class_beta: true`, and an absolute `relay_blind_state_directory` outside any repository (0700, owned by the provider user). The provider serves the signed `1.8.217` binary. No other provider sets `privacy_class_beta`.
  - **Gateway.** The gateway sets `features.relay_blind_requests.enabled` and `features.privacy_class.enabled`. The gateway has no per-buyer allowlist, so any authenticated non-demo buyer may request the class with the reference `relay-blind-client --privacy-class`, and `/v1/models` discloses it. Every such request is served only by the pinned provider, or fails with a typed SPEC-049 error; there is no fallback.
  - **Exclusions.** Pool-scoped and demo requests stay excluded (§2.5). Every other provider is unchanged.
- **Evidence.**
  - The signed `JOURNEY-PRIVACY-CLASS-BETA` result `journeys/evidence/privacy-class-beta-20261006T043016Z.journey-result.signed.json`, signed by protected run 37430812962 over the reviewed evidence from #1864. That evidence covers the physical run on the Mac Studio of the signed and notarized acceptance candidate `1.8.215` (cdhash `3214ffcc6b706507f9a268cfb400da5c74287ff6`, commit `cab10eabb`), and every contract step passed.
  - The automated SPEC-049 suites.
  - The three-lane audits of the implementation PRs, including #1853 (round 3 at 0/0/0).
  - The canary runs `1.8.217`, which carries the same privacy-class and relay-blind settlement code as `1.8.215` plus the fused A3B MoE decode path (#1832). The journey was not re-run on `1.8.217`; the staged canary is its production check.
- **Rollback.**
  1. Engage the durable kill switch: `coordinator-cli privacy-class disable --config <coordinator-config> --config-overlay <coordinator-overlay> --reason ...`. Use the running coordinator's base config and overlay; omit `--config-overlay` only when startup uses no overlay. Older CLIs without this flag require a prepared effective config containing both files' settings. It needs no restart. Privacy-class requests then fail with `privacy_class_disabled`, while relay-blind and plaintext traffic are unaffected.
  2. If needed, quarantine the provider: `coordinator-cli privacy-class quarantine --config <coordinator-config> --config-overlay <coordinator-overlay> --provider <pinned-provider-id> --reason ... --seconds ...`, using the same effective-config procedure.
  3. Remove the `privacy_class` and `relay_blind` coordinator blocks and the gateway feature flags, and restart each service. The restart takes seconds and needs no runtime updater apply.
  4. Turn off `privacy_class_beta` and `relay_blind_enabled` on the provider, and restart it.

  Disable triggers: any posture rejection on the pinned provider, any typed downgrade or failover anomaly, any non-`relay_blind_settled` privacy settlement outcome, or any redaction or settlement finding.
- **Expiry.** `2026-10-20T00:00:00Z`. After that the kill switch is engaged and the configuration removed, unless a new dated exception, or promotion under SPEC-049-R023, replaces this one.
- **Unresolved journey and residuals.** SPEC-049-R023 promotion still needs a signed result whose residuals are closed. These are carried from #1864:
  - five observations backed by indirect or procedure evidence: the hardening-complete time, the frame sequence, the posture challenge rows, P_TRACED/CS_DEBUGGED, and the DYLD environment;
  - the self-referential salted canary-needle commitment;
  - the startup outbound QUIC flow observed before the coordinator session.

  - The signed journey covers the `1.8.215` binary, not the activated `1.8.217`. The shared privacy code is asserted from source lineage, not proven cryptographically, and the fused A3B decode path of `1.8.217` is not journey-tested. The staged canary on the pinned provider is the only production check for `1.8.217`.

  All are tracked on #1749.

### 8.2 v0.2.0 supersedes the §8.1 scope

§8.1 is the record of the v0.1.4 staged canary, and it stays valid only for coordinator, gateway, and provider code at 0.1.x. Its scope limits (exactly one provider pinned by configuration, exactly one approved code identity, and `privacy_class_beta: true` on that one provider only) are configuration controls for v0.1 operator pinning. Under v0.2.0 the same configuration no longer bounds the class: providers enter automatically (SPEC-049-R024) and the coordinator enrolls them (SPEC-049-R025). Therefore:

- §8.1 does not authorize running v0.2.0 code with `privacy_class.enabled: true` in production. A coordinator built from v0.2.0 code is deployed under §8.1 only with the class disabled (the kill switch engaged or the `privacy_class` block removed).
- Production activation of v0.2.0 automatic enrollment requires a new dated limited activation exception under `specs/PROCESS.md`, recorded in `beta/DECISION_CRITERIA.md`, that replaces §8.1 and states its own network-wide scope, rollback, and expiry, or SPEC-049-R023 promotion.
- The §8.1 evidence (the signed `1.8.215` journey result and the `1.8.217` canary) covers the v0.1 requirement set. It does not cover SPEC-049-R024 through SPEC-049-R028, which need a signed journey on a v0.2 release.

### 8.3 Limited activation exception: eligible-network Beta (2026-10-09)

This dated exception supersedes §8.1 for v0.2 automatic enrollment, as recorded
in decision-log Entry 251. It authorizes staged activation, not conformance
promotion. SPEC-049 remains draft and SPEC-049-R023 remains open.

- **Exact scope.** Existing providers and new joins may enroll only after all
  existing signature, authenticated-session, device/key, fresh-posture, native
  in-process, hardening and KV-disk-off gates pass. Explicit provider opt-outs
  remain authoritative. Ineligible providers retain ordinary service; an
  explicit private request never downgrades or fails over to plaintext.
- **Approved release.** Signed/notarized CLI `1.8.224`, team `YF7XNRJUG4`,
  identifier `live.malibu.provider.cli`, CDHash
  `94b66febaee9ac7265dc0fe1a6ad87559ff602b8`. Verify its release metadata and
  signature before configuration. No other code identity is authorized by
  this exception. Any explicit approval expires no later than this exception.
  Release-derived approval, if used, is restricted to this verified identity;
  staging another release requires a superseding dated decision.
- **Coordinator/gateway.** Use reviewed runtime containing #1871/#1892;
  gateway-context enforcement, durable relay-blind storage, production enforce
  settlement and `relay-blind-settlement-v1` remain required. Existing provider
  identity and device pins remain overrides, not network allowlists, and are
  preserved. Approval of the release allows all otherwise eligible providers
  to enroll; the signed Studio buyer canary must pass before activation is
  declared successful.
  Automatic enrollment retains first-session identity trust and key-change
  quarantine. Use the dedicated directory signing key and distribute its
  public key independently of the buyer gateway. Preserve credentials and
  existing identities. Configuration changes do not authorize a new runtime
  release or unrelated catalog/CB changes.
- **Buyers.** Authenticated non-demo buyers use the reference privacy client
  with a verified explicit identity pin or operator-key-pinned signed directory.
  Pool/demo exclusions, exact model scope, disclosure strings and settlement
  requirements remain unchanged.
- **Evidence.** Retain §9's signed 16-step baseline and its stated limitations;
  #1871/#1892 reviewed implementations and passing CI; post-#1895 Studio source
  `2329c3ae036477b1c747dcf0cf6c4ab6fc480027` release/debug builds, native exact
  artifact/catalog stream/nonstream checks, and six isolated encrypted-stack
  E2Es (11.606s, no skips). The encrypted cases use a debug fixture, not signed
  native posture. Activation additionally requires the actual signed 224
  identity and real private stream/nonstream buyer confirmation. Reuse unchanged
  qualification; do not represent source/fixture proofs as that confirmation.
- **Unresolved journey and residuals.** Entry 249's residuals remain. A full
  signed v0.2 journey for R024–R028 has not run; these requirements are not
  promoted. Device-bound self-attested posture, first authenticated claimant
  enrollment, online directory-key trust, and all §2 residual risks remain
  disclosed without stronger claims. This exception does not complete #1749
  or the physical promotion gate.
- **Rollback/incident.** Disable the durable privacy kill switch using the
  running base plus overlay; private requests then fail closed while ordinary
  traffic continues. Quarantine/revoke affected providers when appropriate.
  Disable class configuration if necessary, preserving unrelated configuration.
  Wrong identity/key admission, plaintext downgrade, redaction failure or a
  private settlement outcome other than `relay_blind_settled` triggers immediate
  disablement. Expected ineligibility itself is not an incident.
- **Expiry.** `2026-10-20T00:00:00Z`. Engage the kill switch and withdraw this
  approval at expiry unless a new dated decision replaces it. No automatic
  release-identity reload may extend this date. Owner: @Augustas11.

## 9. Evidence

- `journeys/evidence/privacy-class-beta-20261006T043016Z.journey-result.signed.json`: the signed `JOURNEY-PRIVACY-CLASS-BETA` result (protected run 37430812962). The release is signed acceptance candidate `1.8.215` on Apple Silicon (Mac Studio). It is evidence-only and cannot satisfy a conformant row while SPEC-049-R023 is open (§8.1).
- `journeys/evidence/privacy-class-beta-20261006T043016Z.redacted.json` and its bundle: the reviewed redacted evidence (#1864).

## 10. Changelog and history

- 0.2.2 - Dated eligible-network activation exception (§8.3, Entry 251), limited
  to signed CLI224, with staged real-buyer confirmation, unchanged admission
  and disclosure, explicit missing-journey evidence, rollback and expiry.
  No wire, requirement or conformance promotion.

- 0.1.0 - Initial default-off Beta contract: exact claim and non-claims; threat model with device-bound, not code-bound, self-attested posture; closed posture statement, key attestation, reservation, dispatch marker, and response AEAD schemas; routing gate with no failover or downgrade; quarantine and durable kill switch; shared error inventory; exact disclosure strings; redaction proof; promotion gate. Carries forward the Product Build 2/Build 4 decisions (#1643, #1645, PR #1471) and keeps SPEC-042-R009.
- 0.1.0 - Successful privacy-class chat responses carry `X-MacProvider-Privacy-Posture-Verified-At` from the dispatch-time gate for the gateway. The gateway does not store that timestamp, and the header is not a buyer response header.
- 0.1.1 - SPEC-049-R007 hardening precedes any credential being resolved into the runtime configuration, used, or transmitted, rather than any credential load; reading the operator's own configuration file earlier is not a credential resolution, and a same-user observer is the operator already in scope. Test-fixture posture sources compile only into debug and test builds. No wire, schema, or routing change.
- 0.1.2 - SPEC-049-R007 item 7: on a hardened-runtime binary without the allow-dyld-environment-variables entitlement (items 4 and 5), dyld prunes `DYLD_*` before `main`, so the variables are inert and the in-process check cannot see them; the in-process `DYLD_*` refusal stays as defense in depth, and `DYLD_*` acceptance evidence is inertness rather than a refusal exit. `MACPROVIDER_*` diagnostic variables remain refusals. Hardware basis: the #1839 journey on signed 1.8.214, where `DYLD_INSERT_LIBRARIES=/nonexistent.dylib DYLD_PRINT_LIBRARIES=1 macprovider-cli --version` printed only the version and exited 0. SPEC-049-R005: interval challenges every `posture_challenge_interval_seconds` remain mandatory for every session with accepted privacy keys; a new or rotated key set additionally triggers an immediate challenge, and a heartbeat re-advertising an unchanged key set triggers no extra challenge. The embedded gap rationale now records the implementation as unit-tested, with signed hardware evidence (#1839) and production activation pending. No wire, schema, or routing change.
- 0.1.3 - Issue #1851, enforce-compatible relay-blind settlement. SPEC-049-R010: no SPEC-015 v0.4 receipt and no receipt with a plaintext-derived value; at most one content-free SPEC-015 §N.13 `relay-blind-settlement-v1` receipt per attempt when the dispatch carries `relay_blind_settlement` (withheld, as missing evidence, before a pinned model handle with validated usage exists), with the response digest over ciphertext frames. SPEC-049-R021: the redaction proof covers that receipt and its rows. SPEC-049-R015 notes that under `enforce` the `unknown_postdispatch` row is payable only with that verdict. SPEC-049-R022: the observe-only limit is dropped; under `enforce` privacy-class work settles only through SPEC-022 R-14 as `relay_blind_settled`, never `verified`. Composition bullets updated. No claim, disclosure string, posture, key, envelope, or response-AEAD change.
- 0.1.4 - §8.1 records the one-time limited activation exception under `specs/PROCESS.md` for a staged production canary:
  - one pinned provider;
  - the signed `1.8.217` code identity;
  - enforce settlement;
  - any authenticated non-demo buyer through the reference client, with the class disclosed on `/v1/models` while it is active;
  - the kill switch first for rollback;
  - expiry `2026-10-20T00:00:00Z`;
  - the residuals carried from #1864.

  §9 attaches the signed `JOURNEY-PRIVACY-CLASS-BETA` result. No requirement becomes conformant. The normative text (wire, schema, routing, claim, disclosure strings) does not change; the exception only switches the existing default-off behavior on within this scope.
- 0.1.5 - Editorial: §8.1 replaces an operator-specific provider identifier and host path with placeholders; the actual values are kept in the operator's private configuration. Rollback examples clarify use of the running coordinator's effective base/overlay configuration. No requirement, activation scope, or expiry change.
- 0.2.0 - Issue #1749, automatic enrollment by operator decision. The provider defaults to automatic mode and enters privacy mode only on an eligible signed, SIP-on, hardened host, falling back to ordinary serving otherwise (R024, R001). The coordinator resolves keys from configuration pins, then a durable enrollment, then the provider's new `privacy-enrollment-v1` claim (§4.10, R004) and enrolls on the first fully verified posture (R025); a later different key quarantines and only `coordinator-cli privacy-class reenroll` re-enrolls (R026). Approved code identities also come from signed `pearl-release.json` `provider_code_identity` metadata written by the Pearl updater, with a deny list and configuration override (R027, R006); an unapproved but not denied identity is ineligible without quarantine (R006, R017). A dedicated online Ed25519 key signs the new identity directory, served through the gateway, which the reference client verifies against one pinned key instead of per-provider pin files (§4.11, R028, R016). The threat model adds the credential-holder and coordinator-host adversaries and §2.6, and two residual-risk strings are added to R020. SPEC-041 discovery is amended in SPEC-041 v0.5.0. No envelope, posture statement, key record, reservation, response-AEAD, or settlement change. §8.2 supersedes the §8.1 scope for v0.2.0 code: §8.1 stays the record of the v0.1.4 staged canary and governs only coordinator code at 0.1.x, and production activation of automatic enrollment needs a new dated exception or SPEC-049-R023 promotion. Builds on 0.1.5.
