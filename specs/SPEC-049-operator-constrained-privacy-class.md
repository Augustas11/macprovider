# SPEC-049 - Operator-Constrained Privacy Class

**Version:** 0.1.4
Status: draft
Owner: @Augustas11
Issue: https://github.com/Augustas11/macprovider/issues/1749
Audit history: v0.1.0 is the initial default-off Beta contract. It does not promote conformance or production deployment.

```json
{
  "spec_id": "SPEC-049",
  "title": "Operator-Constrained Privacy Class",
  "version": "0.1.4",
  "path": "specs/SPEC-049-operator-constrained-privacy-class.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["operator-constrained-privacy-class"],
  "supersedes": [],
  "depends_on": ["SPEC-001", "SPEC-002", "SPEC-006", "SPEC-008", "SPEC-015", "SPEC-022", "SPEC-041", "SPEC-042"],
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
    "rationale": "SPEC-049 defines the default-off Beta operator-constrained privacy class. It is implemented and unit-tested, default-off in every component. The signed JOURNEY-PRIVACY-CLASS-BETA hardware result is committed (#1839, #1864), and a one-time staged-canary activation exception is recorded (§8.1, Entry 249). The canary outcome and SPEC-049-R023 promotion are pending. No conformance or production promotion is made by this draft."
  }
}
```

## 1. Purpose, scope, and claims

SPEC-049 defines a default-off Beta privacy class, `operator_constrained_beta_v1`, layered on the SPEC-041 relay-blind pilot. SPEC-041 hides request content from the gateway and coordinator but leaves responses visible to relays and places no constraint on how the provider operator handles plaintext. SPEC-049 adds three things on top of SPEC-041:

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

In scope for v0.1: the global pool only; endpoint family `chat_completions` only; stream and non-stream; the SPEC-041 reference buyer client (`relay-blind-client`) as the only decrypting client; native in-process MLX serving only; operator-pinned Secure Enclave posture keys; operator-approved code identities.

Out of scope for v0.1: `responses` and `messages` endpoint families; browser or third-party clients; loopback, subprocess, or IPC runtimes; any Trusted Pool or other pool-scoped request (rejected under SPEC-042-R009, see SPEC-049-R022); code-bound attestation; MDA SIP/SecureBoot evaluation; production activation.

### 1.4 Carry-forward from earlier planning

This SPEC carries forward the following decisions from the stale Product Build 2 and Build 4 planning (issues #1643 and #1645, PR #1471), which are otherwise superseded by this contract:

- exact provider binding before encryption: the buyer encrypts only to one exact provider key record bound by the reservation, never to a pool or a class of providers;
- at-most-once send with no failover: a privacy-class envelope is dispatched at most once to exactly the reserved provider session, and any postdispatch uncertainty recovers with `do_not_resubmit`;
- no silent downgrade: a request that asked for the privacy class either receives the privacy class end to end or fails with a typed error; it never falls back to SPEC-041 relay-blind without the class, to SPEC-008 provider-leg encryption, or to plaintext;
- unknown revocation freshness means the key is unavailable.

Trusted Pool composition remains rejected under SPEC-042-R009. Binding pool identity, manifest digest, and generation into the privacy-class AAD and posture is a follow-up that requires a SPEC-042 amendment first.

## 2. Threat model

### 2.1 Protected asset

The protected asset is the plaintext of one privacy-class request and its response: messages, tool definitions, response schemas, generated content, and any derived key material (the SPEC-041 shared secret, request key, and the SPEC-049 response key). Request metadata that SPEC-041 leaves in the clear remains in the clear.

### 2.2 Adversaries and capabilities

- **Relays (gateway, coordinator, their operators, and their logs/stores).** They see buyer authentication, model, caps, sizes, timing, token counts, status, and opaque ciphertext. They MUST NOT obtain request or response plaintext.
- **Ordinary provider operator.** A non-root user, or an administrator acting through ordinary tools, on the provider Mac who runs the approved signed release unmodified and tries to read plaintext through: attaching a debugger (`lldb`, `dtrace` pid provider, `task_for_pid`); inducing core dumps; reading logs, trace output, receipts, telemetry, or state files; reading the KV disk tier or conversation cache; routing the runtime through a plaintext loopback proxy or subprocess; running a dev, debug, unsigned, or re-signed build; or running on a host with System Integrity Protection disabled. The privacy class constrains this adversary.
- **Modifying operator.** An operator who patches or rebuilds the runtime binary. Because the Secure Enclave posture key is device-bound and not code-bound (§2.4), this adversary can forge posture and code identity. The privacy class does not constrain this adversary; it is disclosed as a residual risk.
- **Privileged operator.** Root with SIP bypass, kernel extension, firmware, or hardware access. Not constrained; disclosed.

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
- relays observe sizes, timing, and token counts.

## 3. Authority and composition

SPEC-049 owns authority domain `operator-constrained-privacy-class`: the privacy-class marker and its end-to-end binding, the posture statement and its verification, privacy key records and key attestations, response encryption, the privacy routing gate, quarantine and kill switch, the privacy error inventory, and privacy disclosure strings.

- **SPEC-041** owns relay-blind identities, key records, pins, envelopes, the transcript, reservations, consume, opaque dispatch, the provider execution journal, accounting, and the relay-blind error inventory. SPEC-049 extends SPEC-041 closed schemas only by the named additions in SPEC-041 §2 (`privacy_key_records`, `privacy-class-reservation-v1`, the `privacy_class` dispatch key, and the two privacy rejection `error_code` values), only when the privacy class is requested. Every SPEC-041 obligation continues to apply to privacy-class work; SPEC-049 only adds constraints. A privacy-class request is a SPEC-041 relay-blind request plus the SPEC-049 marker.
- **SPEC-042** owns pool selection. SPEC-042-R009 stays in force: every pool-scoped privacy-class request is rejected (SPEC-049-R022).
- **SPEC-008** owns provider Tier-2 trust evidence, including the Secure Enclave session key. SPEC-049 consumes it only as a cross-check (SPEC-049-R004) and does not create a new trust tier. The posture key pin is an operator-pinned privacy identity, not an admission credential.
- **SPEC-015** owns receipts. The v0.4 tuple is unchanged and privacy-class work never emits one. Its only receipt is the content-free §N.13 `relay-blind-settlement-v1` receipt (SPEC-049-R010).
- **SPEC-022** owns verified-model settlement. Privacy-class work is excluded from `verified` as relay-blind work is. Under `enforce` it settles only through the SPEC-022 R-14 relay-blind lane as `relay_blind_settled`.
- **SPEC-005** owns settlement arithmetic. Unchanged.
- **SPEC-001** owns provider wire framing. SPEC-049 adds the `privacy_class` field on `inference_request` and the `privacy_posture_challenge` / `privacy_posture_response` messages and `privacy_key_records` advertisement field.
- **SPEC-002** owns assignment and lifecycle. SPEC-049 adds gate checks without bypassing them.
- **SPEC-006** owns public errors, headers, and JSON/SSE compatibility. SPEC-049 adds the header and error codes in §4.

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
| `privacy_class_disabled` | 503 | no | `none` | the privacy class is disabled by configuration or the kill switch at the emitting component |
| `privacy_class_unavailable` | 503 | no | `none` | no eligible provider, quarantined provider, unapproved code identity, or reservation-version mismatch before consume |
| `privacy_class_downgrade_rejected` | 400 | no | `none` | invalid header value, header on a plaintext body, header/reservation mismatch, marker mismatch at the provider, or pool-scoped privacy request |
| `privacy_class_posture_stale` | 503 | yes | `new_reservation_and_envelope` | posture expired or session changed between reservation and dispatch, or the provider pre-decrypt recheck failed with bound rejection evidence |
| `privacy_class_unconfirmed` | 500 | no | `do_not_resubmit` | a dispatched privacy request returned without exactly one privacy-class echo and exactly one positive `X-MacProvider-Privacy-Posture-Verified-At` value, or privacy completion cannot be confirmed |

`do_not_resubmit` overrides every predispatch action when postdispatch uncertainty exists, exactly as in SPEC-041-R006. SPEC-041-R007 codes continue to apply to the relay-blind layer of the same request.

## 5. Normative requirements

### SPEC-049-R001 - Default-off in every component

The provider (`privacy_class_beta: false`, flag `--privacy-class-beta`), coordinator (`privacy_class.enabled: false`), gateway (`features.privacy_class.enabled: false`), and reference client (`--privacy-class` absent) MUST each default the privacy class off. A privacy-class request MUST succeed only when all four are enabled and SPEC-041 relay-blind support is enabled in every component. Enabling the privacy class in a component whose relay-blind support is disabled MUST fail configuration validation. Disabling the privacy class MUST leave plaintext, SPEC-008, and SPEC-041 relay-blind behavior unchanged.

### SPEC-049-R002 - Honest claim and forbidden labels

Every buyer-facing surface that mentions the privacy class MUST use the class `operator_constrained_beta_v1`, the assurance `device_bound_self_attested_beta`, and the exact SPEC-049-R020 strings. No surface, header, response field, documentation, or marketing derived from this implementation MAY claim confidential compute, a hardware enclave or TEE, provider-blind inference, code-bound attestation, or end-to-end encryption that excludes the provider. The assurance label MUST NOT be mapped onto, upgraded to, or reported as any SPEC-008 trust tier.

### SPEC-049-R003 - Closed posture statement

The provider MUST produce, and the coordinator MUST accept only, a `privacy-posture-v1` statement with exactly the §4.3 field set, types, constraints, and framing order, signed over framing bytes that begin with the domain `macprovider/spec049/posture/v1`. The coordinator MUST reject unknown, duplicate, missing, or null fields, an unsorted or duplicated `privacy_key_record_digests` set, a response over 8192 bytes, and any field whose value violates §4.3. The coordinator MUST recompute the framing from the parsed fields and MUST NOT verify signatures over provider-supplied framing bytes.

### SPEC-049-R004 - Identity binding

The coordinator MUST verify `se_signature` as ECDSA-P256-SHA256 against the operator-pinned `privacy_class.provider_se_public_keys[provider_id]` (raw 64-byte uncompressed point, base64-encoded in configuration) and MUST verify `identity_signature` as Ed25519 against the SPEC-041 operator identity pin for the same provider. A provider without both pins MUST be ineligible. If the authenticated session also carries a SPEC-008 Tier-2 Secure Enclave key, that key MUST equal the posture pin; a mismatch is a quarantine trigger (SPEC-049-R017). `provider_id` and `assigned_session` in the statement MUST equal the authenticated live session that received the challenge. `se_key_backend` MUST be in `privacy_class.allowed_se_key_backends` (default `["file", "keychain"]`).

### SPEC-049-R005 - Challenge freshness

The coordinator MUST send each eligible-candidate session (one with accepted privacy key records) a `privacy_posture_challenge` with a fresh 32-byte random nonce every `posture_challenge_interval_seconds` (bounds 15..300, default 60). These periodic interval challenges are mandatory for every session with accepted privacy key records. A session whose accepted key set first appears or changes (a new or rotated record) is additionally challenged immediately; a heartbeat re-advertising an unchanged key set MUST NOT trigger an extra challenge. It MUST accept a response only if: the nonce is an exact echo of the outstanding challenge for that session; it arrives within `posture_response_timeout_seconds` (default 10); `issued_at_unix` is within ±30 seconds of coordinator time; and `sequence` is strictly greater than the last accepted sequence for that session. Each nonce is single-use. Eligibility derived from a verified posture MUST expire `posture_max_age_seconds` (default 150, at least interval plus timeout, at most 600) after coordinator verification. Posture state is in memory only: after a coordinator restart or session close every provider MUST be ineligible until a new posture verifies. A missed or late response makes the provider ineligible without quarantine.

### SPEC-049-R006 - Approved code identity and required posture values

A posture MUST be accepted only when `(team_id, signing_identifier, code_cdhash)` matches an entry of `privacy_class.approved_code_identities` whose `expires_at` is in the future and, when the entry names `binary_version`, that value matches too. The statement MUST report `hardened_runtime=true`, `library_validation=true`, `get_task_allow=false`, `cs_debugged=false`, `p_traced=false`, `pt_deny_attach_applied=true`, `core_dumps_disabled=true`, `sip_enabled=true`, `diagnostic_env_clear=true`, `kv_disk_tier_disabled=true`, and `runtime_source=native_mlx`. Approved identities are populated by the operator from signed release metadata (runbook §6); a provider can never add itself.

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

The privacy-class X25519 private key MUST exist only in process memory and MUST NOT be written to disk, keychain, logs, or state files. Each privacy key record lifetime (`expires_at_unix - not_before_unix`) MUST be at most 3600 seconds; rotation is by in-memory replacement or process restart. Privacy key records MUST be advertised only in `privacy_key_records` (§4.5), each with a valid `privacy-key-attestation-v1` signed by the SPEC-041 Ed25519 identity, and MUST NOT appear in `relay_blind_key_records`. The coordinator MUST verify the key record per SPEC-041-R002, the attestation signature against the identity pin, field equality with the record, and that `code_cdhash` is approved (SPEC-049-R006), and MUST store accepted records with key class `privacy`. The privacy execution journal and any privacy state live under `<state>/privacy/` with SPEC-041-R005 modes and content limits.

### SPEC-049-R009 - In-process native runtime only

Only the in-process `native_mlx` runtime MAY serve privacy-class work. The provider MUST NOT pass privacy-class plaintext through a loopback HTTP runtime, a subprocess, an IPC hop, or any network socket. Privacy-class work MUST arrive only over the authenticated coordinator WebSocket; the provider's local HTTP server MUST NOT accept, route, or expose privacy-class requests.

### SPEC-049-R010 - Sink suppression

For every privacy-class request the provider MUST produce no SPEC-015 v0.4 receipt and no receipt containing any value derived from plaintext request or response content, no KV telemetry, no egress or performance trace, no conversation-cache entry or lookup, and no KV disk-tier write. No component MAY write prompt bytes, completion bytes, decrypted request JSON, frame plaintext, shared secrets, or key bytes to any log, trace, error message, metric label, crash breadcrumb, SQLite store, or state file. Errors carry bounded codes and digests only. When the dispatch carries SPEC-001-R005 `relay_blind_settlement` metadata, the provider MUST produce at most one SPEC-015 §N.13 `relay-blind-settlement-v1` receipt for the attempt and no other receipt artifact; it produces exactly one once the attempt has a pinned model handle and validated usage, and otherwise withholds it as SPEC-001-R005 item 3 requires (missing evidence under SPEC-022 R-14.6). Its response digest covers the §4.8 ciphertext frames, and it is never written to a log, trace, or state file.

### SPEC-049-R011 - Plaintext lifetime

The provider SHOULD zero decrypted request bytes and its copy of the shared-secret bytes immediately after the request is parsed, and SHOULD zero each response plaintext buffer immediately after it is sealed. Deviation is acceptable only where the language type is immutable and cannot be zeroed (Swift `String` values holding prompt or completion text, and CryptoKit-owned key storage, which zeroes on deallocation); that deviation MUST be disclosed in the SPEC-049-R020 residual risks.

### SPEC-049-R012 - End-to-end marker binding

The header marker (§4.2), the reservation version (§4.6), the reservation row's privacy flag, the opaque dispatch context key, and the `inference_request` field (§4.7) MUST agree for every request. The coordinator MUST compare the header with the stored reservation privacy flag at consume and at chat, in both directions. The gateway and coordinator MUST reject the header on a non-envelope (plaintext) body before quota or dispatch. A privacy-mode provider MUST reject relay-blind dispatch that lacks the marker, and a provider not in privacy mode MUST reject relay-blind dispatch that carries the marker; both rejections occur before decryption with SPEC-041-R005 bound rejection evidence carrying `error_code: privacy_class_downgrade_rejected`. Every such mismatch MUST surface as `privacy_class_downgrade_rejected`.

### SPEC-049-R013 - Routing gate at every phase

At reservation, at consume, and immediately before dispatch, the coordinator MUST re-evaluate all of: the privacy class is enabled in configuration; the durable kill switch is not set (SPEC-049-R018); the provider is not quarantined; a verified posture for the same live session is no older than `posture_max_age_seconds`; the reserved privacy key digest is listed in that posture; the posture cdhash is still approved and unexpired; the key record is fresh and unrevoked with known revocation freshness; and the live WebSocket session is the one bound by the reservation. A privacy-class reservation MUST select only privacy-class key records, and a non-privacy relay-blind reservation MUST NOT select them. Failure before consume returns `privacy_class_unavailable` or `privacy_class_disabled`; failure between consume and dispatch burns the reservation, refunds held quota, and returns `privacy_class_posture_stale` or `privacy_class_disabled`. There MUST be no failover, retry, alternate provider, downgrade to plain SPEC-041 relay-blind, or downgrade to plaintext.

### SPEC-049-R014 - Response AEAD

The provider MUST seal every privacy-class response exactly as §4.8 specifies: response key and nonce prefix from the SPEC-041 transcript with the SPEC-049 labels, nonce as prefix plus u64 big-endian sequence, the exact frame AAD, the closed frame and final-frame schemas, contiguous sequence from 0, and exactly one final frame as the last frame. On cancellation or runtime error after decryption the provider MUST still emit an authenticated final frame with status `cancelled` or `error` when its WebSocket is writable. The response key MUST differ from the request key; reusing a nonce under one response key is forbidden.

### SPEC-049-R015 - Opaque relay of responses

The coordinator and gateway MUST forward privacy frames byte-for-byte, MUST NOT decode, parse, or log ciphertext, and MUST NOT treat a missing `choices` field in a privacy frame as an error. They MAY bound and annotate only the clear usage chunk or non-stream `usage` object. Settlement uses the clear usage bounded by the SPEC-041-R006 caps. On `unknown_postdispatch` the coordinator MUST settle known input only and MUST record a delivered-output estimate of 0, because it cannot count output from ciphertext. Under SPEC-022 `enforce` that row is recorded but becomes payable only with a `relay_blind_settled` verdict (SPEC-022 R-14.6). After a 200 response for a privacy-class request without exactly one coordinator privacy-class echo and exactly one positive `X-MacProvider-Privacy-Posture-Verified-At` value (§4.2), the gateway MUST return `privacy_class_unconfirmed` without writing the body.

### SPEC-049-R016 - Buyer verification

The reference client MUST, before encryption, verify the reservation version is `privacy-class-reservation-v1`, the key record against the operator pin per SPEC-041-R002, the key attestation signature against the same pin, attestation field equality with the record, and `privacy_assurance` equal to `device_bound_self_attested_beta`. After the response it MUST decrypt every frame, enforce contiguous sequence from 0, exactly one final frame, no frame after the final frame, a final status of `complete` for success, clear usage equal to the final frame's usage after cap bounding, and the SPEC-049-R020 response headers. Any failure after send MUST exit non-zero with a message ending `do not resubmit` and MUST NOT print undecrypted or partially verified content as a success.

### SPEC-049-R017 - Quarantine and key revocation

On a posture signature failure, an unapproved or expired code identity, any SPEC-049-R006 required value violated, a sequence regression, a `code_cdhash` change within one session, a key attestation cdhash differing from the session's verified posture cdhash, or a SPEC-008 Secure Enclave key mismatch, the coordinator MUST durably quarantine the provider for `privacy_class.quarantine_seconds` (default 86400) and durably revoke all of its privacy key records. A quarantined provider MUST be ineligible across coordinator restarts until expiry or explicit operator unquarantine. A posture timeout or missed challenge MUST make the provider ineligible without quarantine.

### SPEC-049-R018 - Durable kill switch

A durable `privacy_class_control` row with `disabled = 1` MUST block privacy-class reservation, consume, and dispatch from the next request onward and MUST move every held predispatch privacy-class reservation to `rejected` with quota refund. A store read error MUST be treated as disabled. The control is operated with `coordinator-cli privacy-class status|disable --reason|enable|quarantine --provider --reason --seconds|unquarantine --provider` against the configured relay-blind SQLite store. Disabling never affects plain SPEC-041 relay-blind or plaintext traffic.

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

`/v1/models` MAY expose `tier1_disclosure.operator_constrained_privacy` (omitted when the class is disabled) with `version: privacy-class-disclosure-v1`, the same class, assurance, scope, and lists, plus per-model buyer-safe `capable_provider_count` and `incapable_provider_count` derived only from currently eligible sessions. The reference client MUST print the class, assurance, scope, and residual risks on stderr for every privacy-class run. These strings change only by a SPEC-049 version bump.

### SPEC-049-R021 - Automated redaction proof

An automated integration test MUST run privacy-class stream and non-stream requests with a canary prompt and a canary completion and MUST prove that neither canary, nor the base64url of the buyer ephemeral key or any derived key, appears in provider, coordinator, or gateway stdout/stderr, any SQLite store, the provider state directory, or the scenario temporary directories. It MUST also prove that the `relay-blind-settlement-v1` receipt and every row derived from it contain no canary, no plaintext-derived hash (no SHA-256 of the canary prompt, the canary completion, or the decrypted request or response), and no key material. The same suite MUST cover plaintext downgrade, header strip and inject, envelope replay, wrong key record, stale posture, revoked and quarantined providers, unapproved cdhash, debugger-attached posture, tampered and truncated responses, and the kill switch.

### SPEC-049-R022 - Composition limits

Any privacy-class request with a nonempty pool selection or other pool intent MUST be rejected with `privacy_class_downgrade_rejected` before reservation, quota, or dispatch, preserving SPEC-042-R009. Accounting, positive-receipt and reward exclusion, and SPEC-022 mode limits follow SPEC-041-R006: under `enforce`, privacy-class work settles only through the SPEC-022 R-14 lane, and under `off` and `observe` the SPEC-041-R006 rules apply. SPEC-005 arithmetic and the SPEC-015 v0.4 receipt tuple are unchanged. SPEC-022 finality changes only by the R-14 `relay_blind_settled` outcome, which is never `verified`.

### SPEC-049-R023 - Promotion gate

This SPEC MUST remain `draft` with production status `not-deployed`, and every SPEC-049 requirement MUST remain non-conformant, until all of: the automated suites of SPEC-049-R021 and the unit/vector tests for every requirement pass; a signed `JOURNEY-PRIVACY-CLASS-BETA` result from a signed and notarized release on real hardware is committed; a staged canary rollout with an explicit activation exception under specs/PROCESS.md is recorded; and code, security, and architecture audits of the full diff report 0 Critical, 0 High, and 0 Medium findings.

## 6. Operator runbook requirement

The normative operator procedure is `docs/runbooks/privacy-class-beta-operations.md` (created with the implementation). It covers: collecting the provider Secure Enclave public key and relay-blind identity through `macprovider-cli privacy-class identity`; deriving `approved_code_identities` entries from a signed release binary; enabling each component; the incident procedure (kill switch, quarantine, key revocation, rotation by restart); and the residual-risk table of §2.5. Tooling and documentation MUST never print private key bytes.

## 7. Implementation, tests, and journeys

The authoritative mapping is `specs/CONFORMANCE.json`. All SPEC-049 requirements map to `JOURNEY-PRIVACY-CLASS-BETA`; implementation and test selectors are added as the implementation lands. Planned surfaces: shared Go privacy crypto and types in both relay-blind modules with a byte-identity parity check; Swift crypto parity against the shared vector `test/fixtures/relay-blind/privacy-response-v1.json`; provider hardening, posture responder, and response sealing; coordinator configuration, store, posture verification, routing gate, and kill-switch CLI; gateway marker, opaque relay, and disclosure; reference-client verification; and the cross-service redaction and adversarial integration suite.

## 8. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-049-R001`..`SPEC-049-R023` | `DECISION_REQUIRED` | `@Augustas11` | `#1749` | Implementation, automated tests, signed hardware journey, staged canary, three-lane audits |
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
  - **One provider.** Exactly one provider is pinned in `privacy_class.provider_se_public_keys` and `relay_blind.identity_public_keys`, under the same provider id: the operator's Mac Studio `mp-5aad6b654611666e16edf83dc0f326eb`. Coordinator validation accepts more than one pin, so this one-provider limit is an operator configuration control, checked by the operator against this section before each restart. Any added pin requires a new dated exception.
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
  1. Engage the durable kill switch: `coordinator-cli privacy-class disable --config /opt/macprovider/coordinator.yaml --reason ...`. It needs no restart. Privacy-class requests then fail with `privacy_class_disabled`, while relay-blind and plaintext traffic are unaffected.
  2. If needed, quarantine the provider: `coordinator-cli privacy-class quarantine --config /opt/macprovider/coordinator.yaml --provider mp-5aad6b654611666e16edf83dc0f326eb --reason ... --seconds ...`.
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

## 9. Evidence

- `journeys/evidence/privacy-class-beta-20261006T043016Z.journey-result.signed.json`: the signed `JOURNEY-PRIVACY-CLASS-BETA` result (protected run 37430812962). The release is signed acceptance candidate `1.8.215` on Apple Silicon (Mac Studio). It is evidence-only and cannot satisfy a conformant row while SPEC-049-R023 is open (§8.1).
- `journeys/evidence/privacy-class-beta-20261006T043016Z.redacted.json` and its bundle: the reviewed redacted evidence (#1864).

## 10. Changelog and history

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
