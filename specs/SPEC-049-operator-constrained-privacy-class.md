# SPEC-049 - Operator-Constrained Privacy Class

**Version:** 0.2.0
Status: draft
Owner: @Augustas11
Issue: https://github.com/Augustas11/macprovider/issues/1749
Audit history: v0.1.0 is the initial default-off Beta contract. v0.2.0 adds the default-off `code_bound_attested` assurance label backed by Apple App Attest (issue #1840). Neither version promotes conformance or production deployment.

```json
{
  "spec_id": "SPEC-049",
  "title": "Operator-Constrained Privacy Class",
  "version": "0.2.0",
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
    "rationale": "SPEC-049 v0.2.0 defines the default-off Beta operator-constrained privacy class and the default-off code_bound_attested assurance label (issue #1840). The v0.1.0 surface is implemented locally with tests. The v0.2.0 code-bound surface (SPEC-049-R024..SPEC-049-R034) is implemented locally and default-off in the coordinator, the provider, and the Malibu.app supervisor, with unit tests. Signed JOURNEY-PRIVACY-CLASS-BETA and JOURNEY-PRIVACY-CLASS-CODE-BOUND hardware evidence, a committed real macOS 27 attestation fixture, the staged canary, and three-lane audits remain pending. No conformance or production promotion is made by this draft."
  }
}
```

## 1. Purpose, scope, and claims

SPEC-049 defines a default-off Beta privacy class, `operator_constrained_beta_v1`, layered on the SPEC-041 relay-blind pilot. SPEC-041 hides request content from the gateway and coordinator but leaves responses visible to relays and places no constraint on how the provider operator handles plaintext. SPEC-049 adds three things on top of SPEC-041:

1. response encryption from the provider runtime to the buyer reference client, so response content is also hidden from the gateway and coordinator;
2. a provider runtime mode that, on a genuine approved signed release, blocks or refuses the documented ordinary operator access paths to plaintext; and
3. a coordinator routing gate that admits privacy-class work only to providers whose freshly signed runtime posture proves that mode is in force, with no failover and no silent downgrade.

The provider runtime reads plaintext to infer. SPEC-049 does not hide content from the provider runtime. It constrains the ordinary paths by which the person operating the provider Mac could read that plaintext.

### 1.1 Exact claims

The class has two assurance labels. A provider session carries exactly one of them at a time, chosen by the coordinator from what it verified (SPEC-049-R024), never by the provider's own assertion.

`device_bound_self_attested_beta` is the default label. Its exact claim is:

> The provider runtime reads plaintext to infer. On a genuine, approved, signed release runtime, the documented ordinary operator access paths are blocked or refused by routing: debugger attach, core dumps, logs, traces, receipts, disk cache, plaintext proxy or subprocess, dev or debug builds, and SIP-off hosts. Posture and code identity are self-reported by the runtime and signed with a device-bound Secure Enclave key. That key is not bound to the code signature, so an operator who modifies the runtime binary can forge them.

`code_bound_attested` (v0.2.0, default off) is granted only when every requirement SPEC-049-R024..SPEC-049-R034 holds. Its exact claim is:

> The provider runtime reads plaintext to infer. On a genuine, approved, signed release runtime, the documented ordinary operator access paths are blocked or refused by routing, as for the Beta label. In addition, each posture statement is signed by an App Attest key that Apple certified as belonging to the team-signed Malibu.app (`tech.malibu.app`) on a Mac whose key access policy reported SIP and Full Security at enrollment. That attested app verified, by kernel audit token, that the inference process is the team-signed `live.malibu.provider.cli` with an approved cdhash and hardened, non-debugged code-signing flags. An operator who modifies or re-signs the runtime binary or Malibu.app cannot produce such a posture. The coordinator, not the buyer, verifies the Apple attestation. A kernel or firmware compromise with SIP on, a compromised team signing key, or Apple itself can still defeat the claim.

Buyer-facing surfaces carry the exact scope string, protection lists, and residual-risk lists fixed in SPEC-049-R020 for the label the request was served under.

### 1.2 Non-claims

The privacy class MUST NOT be described as confidential compute, a hardware enclave, a TEE, provider-blind inference, end-to-end encryption that excludes the provider, anonymous routing, unlinkable settlement, protection against a root or kernel-level operator, or proof that the provider did not retain plaintext. It does not hide request metadata (account, model, sizes, timing, token counts, status) from relays. Under `device_bound_self_attested_beta` it MUST NOT be described as code-bound attestation or remote attestation of the executing binary. Under `code_bound_attested` it MAY be described only by the exact SPEC-049-R020 strings; it MUST NOT be described as Apple attesting the inference binary directly (Apple attests Malibu.app; Malibu.app checks the inference binary), as buyer-verifiable attestation, or as proof of the GPU, unified-memory, or swap state.

### 1.3 Scope

In scope for v0.1: the global pool only; endpoint family `chat_completions` only; stream and non-stream; the SPEC-041 reference buyer client (`relay-blind-client`) as the only decrypting client; native in-process MLX serving only; operator-pinned Secure Enclave posture keys; operator-approved code identities.

In scope for v0.2: the `code_bound_attested` label for a provider whose `macprovider-cli` runs as the supervised child of Malibu.app on macOS 27 or later in a logged-in user session, with an App Attest key in the Malibu.app main process; App Attest enrollment and per-posture assertions verified by the coordinator; the buyer's optional assurance requirement on the reservation. Every v0.1 scope limit still applies to both labels.

Out of scope: `responses` and `messages` endpoint families; browser or third-party clients; loopback, subprocess, or IPC runtimes for plaintext (the v0.2 supervisor channel carries no plaintext, SPEC-049-R025); any Trusted Pool or other pool-scoped request (rejected under SPEC-042-R009, see SPEC-049-R022); buyer-side verification of the Apple attestation; App Attest in daemons, extensions, the standalone CLI, or development (`appattestdevelop`) environments; App Attest fraud-metric receipt evaluation; MDA SIP/SecureBoot evaluation; production activation.

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
- **Modifying operator.** An operator who patches, rebuilds, or re-signs the runtime binary or Malibu.app. Under `device_bound_self_attested_beta` the Secure Enclave posture key is device-bound and not code-bound (§2.4), so this adversary can forge posture and code identity; the label does not constrain this adversary and discloses it as a residual risk. Under `code_bound_attested` this adversary is constrained (§2.6).
- **Privileged operator.** Root with SIP bypass, kernel extension, firmware, or hardware access, or a kernel compromise while SIP stays on. Not constrained under either label; disclosed.

### 2.3 Trust boundary

The trust boundary is the address space of one approved, signed, hardened-runtime provider process on a host reporting SIP on. Under `code_bound_attested` the Malibu.app main process that holds the App Attest key and checks the child is also inside the boundary; it never holds request or response plaintext. Inside that boundary plaintext exists in memory. Everything outside it (relays, other local processes, disk, logs, other users) is outside the boundary. The buyer reference client is the other end of the boundary and is trusted by its own user.

### 2.4 Why Beta posture is self-attested

The release CLI cannot carry a `keychain-access-groups` entitlement without a provisioning profile, so the Secure Enclave identity falls back to a keychain item without an access group or to a file-backed CryptoKit Secure Enclave key blob. Either way the key is bound to the device's Secure Enclave but any process of the same user can ask the Secure Enclave to sign with it. A modified binary running as the same user can therefore produce a valid signature over a forged posture statement. The posture signature proves "a process on the pinned device signed this", not "the approved code signed this". Both backends are equally device-bound and not code-bound and both are eligible in Beta; making the file backend ineligible would leave no eligible provider.

### 2.5 Residual risks (Beta label)

The following residual risks are accepted for `device_bound_self_attested_beta` and MUST be disclosed by SPEC-049-R020:

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

### 2.6 Code-bound posture (`code_bound_attested`)

App Attest became available on macOS 27, only to a full Mac app's main bundle running in a user session; it is not available to daemons, extensions, or the standalone CLI. SPEC-049 therefore uses a supervisor-attestor model:

- The App Attest key lives in the Malibu.app main process (bundle identifier `tech.malibu.app`, team pinned by coordinator configuration). Apple's attestation certifies that the key was generated for App ID `<team>.tech.malibu.app`. macOS refuses to launch a re-signed copy that keeps the App Attest entitlement, and a re-signed copy without it receives a key whose relying-party hash does not match the App ID (hardware spike, issue #1840, 2026-10-04).
- On macOS 27 the attestation carries the key access-control extension (aclBlob). Apple documents one exact value for a key attested with SIP and Full Security on; the coordinator requires that value at enrollment.
- Malibu.app spawns `macprovider-cli` (signing identifier `live.malibu.provider.cli`) and, before every enrollment and every posture assertion, verifies the child's dynamic code signature by the kernel audit token of the authenticated local channel: `anchor apple generic`, the pinned team, the identifier, the approved cdhash, and the code-signing flags. A patched or re-signed child fails this check.
- Each posture statement then carries an App Attest assertion over its canonical framing. The coordinator verifies it with the enrolled key and a durably persisted, strictly increasing counter.

Compared with §2.4, the posture signer is no longer "any process of the same user on the pinned device" but "the Apple-certified, team-signed Malibu.app on a SIP-on, Full-Security host, after it checked the inference child". Apple certifies the app, not the child; the child's identity is proven by the attested app's check.

### 2.7 Residual risks (code-bound label)

The following residual risks remain under `code_bound_attested` and MUST be disclosed by SPEC-049-R020:

- a kernel or firmware compromise while SIP stays on can subvert the app's child check or the runtime's memory;
- physical or hardware attacks;
- GPU and unified-memory residue after a request;
- encrypted swap and hibernation images containing plaintext pages;
- compromise of the live runtime process (memory-safety bug, malicious model artifact);
- a malicious signed release or supply-chain compromise;
- a compromised team signing key can sign a malicious app or child that passes every check;
- Apple is the root of trust for the attestation, the aclBlob semantics, and the key binding;
- SIP and Full Security are attested by the aclBlob at enrollment only; later postures carry only the checked child's own `csr_check` result;
- the label is verified by the coordinator; the buyer trusts the coordinator for it and cannot verify the Apple attestation itself;
- register and stack residue in crash reports;
- immutable Swift `String` copies of the prompt cannot be zeroized;
- relays observe sizes, timing, and token counts.

## 3. Authority and composition

SPEC-049 owns authority domain `operator-constrained-privacy-class`: the privacy-class marker and its end-to-end binding, the posture statement and its verification, privacy key records and key attestations, response encryption, the privacy routing gate, quarantine and kill switch, the privacy error inventory, and privacy disclosure strings.

- **SPEC-041** owns relay-blind identities, key records, pins, envelopes, the transcript, reservations, consume, opaque dispatch, the provider execution journal, accounting, and the relay-blind error inventory. SPEC-049 extends SPEC-041 closed schemas only by the named additions in SPEC-041 §2 (`privacy_key_records`, `privacy-class-reservation-v1`, the `privacy_class` dispatch key, and the two privacy rejection `error_code` values), only when the privacy class is requested. Every SPEC-041 obligation continues to apply to privacy-class work; SPEC-049 only adds constraints. A privacy-class request is a SPEC-041 relay-blind request plus the SPEC-049 marker.
- **SPEC-042** owns pool selection. SPEC-042-R009 stays in force: every pool-scoped privacy-class request is rejected (SPEC-049-R022).
- **SPEC-008** owns provider Tier-2 trust evidence, including the Secure Enclave session key. SPEC-049 consumes it only as a cross-check (SPEC-049-R004) and does not create a new trust tier. The posture key pin is an operator-pinned privacy identity, not an admission credential. Neither privacy assurance label, including `code_bound_attested`, is a SPEC-008 trust tier, and an enrolled App Attest key is not an admission credential.
- **SPEC-015** owns receipts. The v0.4 tuple is unchanged; privacy-class work emits no positive receipt (SPEC-041-R006).
- **SPEC-022** owns verified-model settlement. Unchanged; privacy-class work is excluded as relay-blind work is.
- **SPEC-005** owns settlement arithmetic. Unchanged.
- **SPEC-001** owns provider wire framing. SPEC-049 adds the `privacy_class` field on `inference_request`, the `privacy_posture_challenge` / `privacy_posture_response` messages, the `privacy_key_records` advertisement field, and (v0.2) the `privacy_app_attest_enroll_request` / `privacy_app_attest_enroll_challenge` / `privacy_app_attest_enrollment` / `privacy_app_attest_enroll_result` messages.
- **SPEC-002** owns assignment and lifecycle. SPEC-049 adds gate checks without bypassing them.
- **SPEC-006** owns public errors, headers, and JSON/SSE compatibility. SPEC-049 adds the header and error codes in §4.

## 4. Canonical primitives and wire schemas

### 4.1 Primitives

All encodings follow SPEC-041 §3: canonical unpadded base64url; u32-length-prefixed strings and byte strings; u64 big-endian unsigned integers; signed 64-bit big-endian Unix seconds; booleans as u64 `0`/`1`; set-like arrays as a u32 count followed by u32-length-framed elements in strictly ascending byte order with no duplicates. Every JSON object in this section is closed: decoders reject duplicate, unknown, missing, or null fields, non-integer numeric forms, wrong JSON types, and trailing values. `code_cdhash` is exactly 40 lowercase hexadecimal characters (the 20-byte code directory hash). Constant strings:

| Name | Value |
|---|---|
| Privacy class | `operator_constrained_beta_v1` |
| Assurance (Beta) | `device_bound_self_attested_beta` |
| Assurance (code-bound, v0.2) | `code_bound_attested` |
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
| Code-bound posture version (v0.2) | `privacy-posture-v2` |
| Code-bound posture signing domain (v0.2) | `macprovider/spec049/posture/v2` |
| App Attest enrollment version (v0.2) | `privacy-app-attest-enrollment-v1` |
| App Attest enrollment signing domain (v0.2) | `macprovider/spec049/app-attest-enrollment/v1` |
| Supervisor bundle identifier (v0.2) | `tech.malibu.app` |
| Supervised child signing identifier (v0.2) | `live.malibu.provider.cli` |
| App Attest environment (v0.2) | `production` |

v0.2 App Attest constants (SPEC-049-R028, SPEC-049-R031):

| Name | Value |
|---|---|
| Attestation format | `apple-appattest` |
| Trust anchor | Apple App Attestation Root CA; SHA-256 of its DER encoding `1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32` |
| Nonce extension OID | `1.2.840.113635.100.8.2`, value `SEQUENCE { [1] EXPLICIT OCTET STRING (32 bytes) }` |
| aclBlob extension OID | `1.2.840.113635.100.8.6` |
| Required aclBlob octet string (SIP and Full Security), standard base64 | `MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB` (66 bytes; SHA-256 `4de4539b20e1d672b3b45a6f9c67c48db560c79a556f91b0fb8c96dd32d0b165`) |
| Production aaguid | the 16 bytes `appattest` followed by seven `0x00` bytes |
| Rejected aaguid | `appattestdevelop` (development) and every other value |
| App ID | `<team_id>.tech.malibu.app`, where `<team_id>` is `privacy_class.code_bound.team_id` |
| rpIdHash | SHA-256 of the UTF-8 App ID |
| Required child CS flags | `CS_VALID 0x00000001`, `CS_HARD 0x00000100`, `CS_KILL 0x00000200`, `CS_RUNTIME 0x00010000` (mask `0x00010301`) |
| Forbidden child CS flags | `CS_ADHOC 0x00000002`, `CS_GET_TASK_ALLOW 0x00000004`, `CS_INVALID_ALLOWED 0x00000020`, `CS_DEBUGGED 0x10000000` (mask `0x10000026`) |

### 4.2 Header marker

`X-MacProvider-Privacy-Class: operator_constrained_beta_v1`. Any other value, repeated header, or list value is invalid. The buyer sends it on the reservation and the chat request. The gateway strips every buyer-supplied copy at ingress and re-sets exactly one trusted copy on each upstream coordinator request (reservation, consume, chat) after validating the buyer's value. The coordinator echoes it on a successful privacy-class chat response. On that same response the coordinator sets exactly one `X-MacProvider-Privacy-Posture-Verified-At` header to the decimal Unix seconds of the posture verification time used by the dispatch-time gate; the gateway strips any buyer-supplied copy, requires exactly one positive integer value or returns `privacy_class_unconfirmed` without writing the body, copies the value into `usage.macprovider.privacy.posture_verified_at_unix`, and does not forward the header to the buyer.

v0.2 adds two headers (SPEC-049-R032):

- `X-MacProvider-Privacy-Assurance-Required: code_bound_attested`, sent by the buyer on the reservation request only. It is the only valid value; any other value, a repeated header, a list value, or the header without the class marker is invalid. The gateway strips every buyer-supplied copy at ingress and, after validating it, re-sets exactly one trusted copy on the upstream reservation request only. Absent the header, the reservation may select a key record of either label.
- `X-MacProvider-Privacy-Assurance`, set by the coordinator to exactly one value on a successful privacy-class chat response: the `privacy_assurance` of the reservation, which MUST equal the assurance of the posture used by the dispatch-time gate. The gateway strips any buyer-supplied copy, requires exactly one value that is one of the two assurance labels or returns `privacy_class_unconfirmed` without writing the body, selects the SPEC-049-R020 string set for that label, and forwards exactly that one value to the buyer as the SPEC-049-R020 response header.

### 4.3 `privacy-posture-v1` statement

A `device_bound_self_attested_beta` session sends `privacy-posture-v1`. The closed statement JSON contains exactly these fields; the signing framing encodes the domain string first and then every field in this order:

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

The challenge message is unchanged in v0.2. A `version: 1` response carries a `privacy-posture-v1` statement and is the only response a `device_bound_self_attested_beta` session sends. A `version: 2` response (§4.10) carries a `privacy-posture-v2` statement and an App Attest assertion and is sent only by a session whose App Attest key the coordinator acknowledged as `enrolled` (§4.11). The coordinator selects the decoder by `version` and MUST reject any other value.

### 4.5 `privacy_key_records` and `privacy-key-attestation-v1`

Privacy key records are advertised only in the `privacy_key_records` field of `hello`, `auth_request`, and `heartbeat`, never in `relay_blind_key_records`. Each element is the closed object:

```json
{
  "key_record": { "...": "complete SPEC-041-R002 signed key record" },
  "privacy_key_attestation": {
    "version": "privacy-key-attestation-v1",
    "key_record_digest": "<SPEC-041 key_record_digest>",
    "privacy_class": "operator_constrained_beta_v1",
    "assurance": "<device_bound_self_attested_beta | code_bound_attested>",
    "binary_version": "<provider binaryVersion>",
    "code_cdhash": "<40 lowercase hex>",
    "not_before_unix": 0,
    "expires_at_unix": 0
  },
  "signature": "<base64url raw 64-byte Ed25519 over the attestation framing>"
}
```

The attestation framing is the domain string `macprovider/spec049/key-attestation/v1` followed by the attestation fields in the order shown, strings as strings and times as i64. `key_record_digest`, `not_before_unix`, and `expires_at_unix` MUST equal the embedded key record's values. `assurance` is `device_bound_self_attested_beta` unless the provider's App Attest key was acknowledged `enrolled` in the current session, in which case it is `code_bound_attested` (SPEC-049-R032). A record set holds at most 8 elements.

### 4.6 `privacy-class-reservation-v1`

The reservation request body is the unchanged SPEC-041-R004 closed request; the privacy class is selected only by the header. The closed success response is the SPEC-041-R004 response field set with `version` set to `privacy-class-reservation-v1` plus exactly these additional fields:

- `privacy_class`: `operator_constrained_beta_v1`;
- `privacy_assurance`: the `assurance` of the reserved key record's attestation, which MUST equal the assurance of the session's verified posture (SPEC-049-R032);
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

v0.2 adds no public error code. An invalid `X-MacProvider-Privacy-Assurance-Required` header returns `privacy_class_downgrade_rejected`; no eligible `code_bound_attested` provider for a reservation that requires it returns `privacy_class_unavailable`; a missing, repeated, or invalid coordinator `X-MacProvider-Privacy-Assurance` value, or one that differs from the reservation's `privacy_assurance`, returns `privacy_class_unconfirmed`. App Attest enrollment and assertion failures are provider-side WebSocket outcomes and stored reason codes (§4.12), never buyer-facing errors.

### 4.10 `privacy-posture-v2` statement and `version: 2` response (v0.2)

A session whose App Attest key is `enrolled` sends `privacy-posture-v2`. The closed statement JSON contains fields 1..24 of §4.3 with identical names, types, framing, and constraints, except that field 1 `version` is `privacy-posture-v2`, followed by exactly these fields. The signing framing encodes the domain string `macprovider/spec049/posture/v2` first and then fields 1..34 in this order:

| # | Field | JSON type | Framing | Constraint |
|---|---|---|---|---|
| 25 | `assurance` | string | string | `code_bound_attested` |
| 26 | `app_attest_key_id` | string | raw 32 bytes | base64url of the enrolled App Attest keyId |
| 27 | `supervisor_team_id` | string | string | equals `privacy_class.code_bound.team_id` and field 10 `team_id` |
| 28 | `supervisor_bundle_id` | string | string | `tech.malibu.app` |
| 29 | `supervisor_bundle_version` | string | string | Malibu.app `CFBundleVersion`, 1..64 printable ASCII; recorded, not approved |
| 30 | `child_cdhash` | string | string | 40 lowercase hex; the cdhash the supervisor read from the child's dynamic code for this statement; equals field 9 `code_cdhash` |
| 31 | `child_signing_identifier` | string | string | `live.malibu.provider.cli`; equals field 11 `signing_identifier` |
| 32 | `child_cs_flags` | integer | u64 | 0..4294967295; the child's dynamic code-signing flags read by the supervisor; contains every required flag and no forbidden flag of §4.1 |
| 33 | `child_checked_at_unix` | integer | i64 | supervisor clock when the child check for this statement completed; within ±5 seconds of field 7 `issued_at_unix` |
| 34 | `child_channel_peer_verified` | boolean | u64 | the local channel peer's kernel audit token identifies the child process the supervisor spawned; MUST be `true` |

The `version: 2` response is the closed object:

```json
{
  "type": "privacy_posture_response",
  "version": 2,
  "statement": { "...": "closed privacy-posture-v2 object" },
  "se_signature": "<base64url DER ECDSA-P256-SHA256 over the v2 posture framing>",
  "identity_signature": "<base64url raw 64-byte Ed25519 over the v2 posture framing>",
  "app_attest_assertion": "<base64url of the App Attest assertion object>"
}
```

The encoded response is at most 12288 bytes. `app_attest_assertion` is the unmodified output of `DCAppAttestService.generateAssertion` for the enrolled key with `clientDataHash = SHA-256(v2 posture framing bytes)`. Decoded, it is 1..2048 bytes and is exactly one definite-length CBOR map with exactly two text-string keys and no trailing bytes: `signature`, a byte string holding an ASN.1 DER ECDSA P-256 signature of at most 72 bytes, and `authenticatorData`, a byte string laid out as bytes 0..31 rpIdHash, byte 32 flags (not interpreted; real macOS 27 assertions set the AT bit with no attested credential data), bytes 33..36 the signature counter as u32 big-endian. `authenticatorData` is exactly 37 bytes, or longer only when the bytes after offset 37 are exactly one definite-length CBOR map (an extensions map, not otherwise interpreted); its total length is at most 512 bytes.

### 4.11 App Attest enrollment messages (v0.2)

All four messages travel over the authenticated provider WebSocket of the live assigned session. Provider to coordinator:

```json
{"type": "privacy_app_attest_enroll_request", "version": 1, "app_attest_key_id": "<base64url 32 bytes>"}
```

Coordinator to provider, only when the key is not yet enrolled and enrollment may proceed (SPEC-049-R027):

```json
{"type": "privacy_app_attest_enroll_challenge", "version": 1, "app_attest_key_id": "<echo>", "challenge": "<base64url 32 random bytes>", "issued_at_unix": 0}
```

Provider to coordinator:

```json
{
  "type": "privacy_app_attest_enrollment",
  "version": 1,
  "statement": { "...": "closed privacy-app-attest-enrollment-v1 object" },
  "attestation": "<base64url of the App Attest attestation object>",
  "se_signature": "<base64url DER ECDSA-P256-SHA256 over the enrollment framing>",
  "identity_signature": "<base64url raw 64-byte Ed25519 over the enrollment framing>"
}
```

The encoded enrollment is at most 32768 bytes and the decoded `attestation` at most 16384 bytes. `attestation` is the unmodified output of `DCAppAttestService.attestKey` with `clientDataHash = SHA-256(enrollment framing bytes)`.

Coordinator to provider, in reply to a request or an enrollment, or unsolicited under SPEC-049-R033:

```json
{"type": "privacy_app_attest_enroll_result", "version": 1, "app_attest_key_id": "<echo>", "status": "enrolled"}
```

`status` is exactly one of `enrolled`, `reenroll_required`, `unavailable`, or `rejected` (SPEC-049-R027).

The closed `privacy-app-attest-enrollment-v1` statement contains exactly these fields; the signing framing encodes the domain string `macprovider/spec049/app-attest-enrollment/v1` first and then every field in this order:

| # | Field | JSON type | Framing | Constraint |
|---|---|---|---|---|
| 1 | `version` | string | string | `privacy-app-attest-enrollment-v1` |
| 2 | `privacy_class` | string | string | `operator_constrained_beta_v1` |
| 3 | `provider_id` | string | string | authenticated provider ID, 1..128 printable ASCII |
| 4 | `assigned_session` | string | string | current assigned session, 1..128 printable ASCII |
| 5 | `challenge` | string | raw 32 bytes | base64url of the outstanding enrollment challenge |
| 6 | `app_attest_key_id` | string | raw 32 bytes | base64url of the keyId being enrolled; equals the request |
| 7 | `team_id` | string | string | equals `privacy_class.code_bound.team_id` |
| 8 | `bundle_id` | string | string | `tech.malibu.app` |
| 9 | `environment` | string | string | `production` |
| 10 | `se_public_key` | string | raw 64 bytes | base64url of the X || Y coordinates of the provider Secure Enclave posture key; equals the SPEC-049-R004 pin |
| 11 | `identity_public_key` | string | raw 32 bytes | base64url of the SPEC-041 Ed25519 identity public key; equals the SPEC-041 identity pin |
| 12 | `child_cdhash` | string | string | 40 lowercase hex; read by the supervisor from the child's dynamic code |
| 13 | `child_cs_flags` | integer | u64 | 0..4294967295; contains every required flag and no forbidden flag of §4.1 |
| 14 | `supervisor_bundle_version` | string | string | Malibu.app `CFBundleVersion`, 1..64 printable ASCII |
| 15 | `issued_at_unix` | integer | i64 | supervisor clock |

### 4.12 Durable App Attest key record and reason codes (v0.2)

The coordinator stores enrolled keys in table `privacy_app_attest_keys` of the configured relay-blind SQLite store, one row per keyId: `provider_id`; `app_attest_key_id` (32 bytes, unique across all rows); `public_key` (the 65-byte uncompressed P-256 point from the attestation leaf); `team_id`; `se_public_key_sha256` and `identity_public_key_sha256` (SHA-256 of the pinned values bound at enrollment); `enrolled_at_unix`; `last_counter` (0..4294967295, 0 at enrollment); `state` (`active` or `revoked`); `revoked_reason` (a code below, null while active); `revoked_at_unix`. At most one row per `provider_id` is `active`. Revoked rows are kept, and a revoked keyId can never become active again.

Reason codes are bounded strings written to the store and coordinator logs; they are never buyer-facing.

| Reason code | Quarantine | Trigger |
|---|---:|---|
| `app_attest_attestation_invalid` | yes | any SPEC-049-R028 attestation check other than the aclBlob fails |
| `app_attest_acl_mismatch` | yes | the aclBlob extension is absent or differs from the required value |
| `app_attest_binding_mismatch` | yes | an enrollment statement field or signature disagrees with the session, the challenge, the configured team, the pins, or the request, or the keyId is enrolled to another provider |
| `app_attest_assertion_invalid` | yes | any SPEC-049-R031 assertion check other than the counter fails |
| `app_attest_counter_regression` | yes | an assertion counter is less than or equal to the stored `last_counter` |
| `supervisor_child_check_failed` | yes | `child_cs_flags`, `child_cdhash`, `child_signing_identifier`, `child_checked_at_unix`, or `child_channel_peer_verified` violates §4.10 or §4.11, or `child_cdhash` is not approved |
| `assurance_mismatch` | yes | a key attestation or posture lists a record whose `assurance` differs from the posture's label |
| `assurance_regression` | yes | a `version: 1` posture or a `device_bound_self_attested_beta` key attestation arrives in a session after its key was acknowledged `enrolled` |
| `superseded` | no | the provider enrolled a different key |
| `binding_stale` | no | the SE or identity pin no longer matches the hash stored at enrollment, or the configured team changed |
| `counter_exhausted` | no | `last_counter` reached 4294967295 |
| `operator_revoked` | no | `coordinator-cli privacy-class revoke-app-attest-key --provider --reason` |

## 5. Normative requirements

### SPEC-049-R001 - Default-off in every component

The provider (`privacy_class_beta: false`, flag `--privacy-class-beta`), coordinator (`privacy_class.enabled: false`), gateway (`features.privacy_class.enabled: false`), and reference client (`--privacy-class` absent) MUST each default the privacy class off. A privacy-class request MUST succeed only when all four are enabled and SPEC-041 relay-blind support is enabled in every component. Enabling the privacy class in a component whose relay-blind support is disabled MUST fail configuration validation. Disabling the privacy class MUST leave plaintext, SPEC-008, and SPEC-041 relay-blind behavior unchanged.

### SPEC-049-R002 - Honest claim and forbidden labels

Every buyer-facing surface that mentions the privacy class MUST use the class `operator_constrained_beta_v1`, the assurance label the work was actually served under, and the exact SPEC-049-R020 strings for that label. That label is `device_bound_self_attested_beta` unless SPEC-049-R024 grants `code_bound_attested`. No surface, header, response field, documentation, or marketing derived from this implementation MAY claim confidential compute, a hardware enclave or TEE, provider-blind inference, or end-to-end encryption that excludes the provider, and none MAY claim code-bound attestation except through the exact `code_bound_attested` strings of SPEC-049-R020 for work served under that label. The assurance label MUST NOT be mapped onto, upgraded to, or reported as any SPEC-008 trust tier.

### SPEC-049-R003 - Closed posture statement

The provider MUST produce, and the coordinator MUST accept only, in a `version: 1` response, a `privacy-posture-v1` statement with exactly the §4.3 field set, types, constraints, and framing order, signed over framing bytes that begin with the domain `macprovider/spec049/posture/v1`. The coordinator MUST reject unknown, duplicate, missing, or null fields, an unsorted or duplicated `privacy_key_record_digests` set, a response over 8192 bytes, and any field whose value violates §4.3. The coordinator MUST recompute the framing from the parsed fields and MUST NOT verify signatures over provider-supplied framing bytes. A `version: 2` response is held to the same rules against the §4.10 field set, the `macprovider/spec049/posture/v2` domain, and the 12288-byte limit; every v1 check of SPEC-049-R004..SPEC-049-R006 applies to its fields 1..24. A `version: 1` response with a `privacy-posture-v1` statement stays valid for `device_bound_self_attested_beta` sessions without change.

### SPEC-049-R004 - Identity binding

The coordinator MUST verify `se_signature` as ECDSA-P256-SHA256 against the operator-pinned `privacy_class.provider_se_public_keys[provider_id]` (raw 64-byte uncompressed point, base64-encoded in configuration) and MUST verify `identity_signature` as Ed25519 against the SPEC-041 operator identity pin for the same provider. A provider without both pins MUST be ineligible. If the authenticated session also carries a SPEC-008 Tier-2 Secure Enclave key, that key MUST equal the posture pin; a mismatch is a quarantine trigger (SPEC-049-R017). `provider_id` and `assigned_session` in the statement MUST equal the authenticated live session that received the challenge. `se_key_backend` MUST be in `privacy_class.allowed_se_key_backends` (default `["file", "keychain"]`).

### SPEC-049-R005 - Challenge freshness

The coordinator MUST send each eligible-candidate session (one with accepted privacy key records) a `privacy_posture_challenge` with a fresh 32-byte random nonce every `posture_challenge_interval_seconds` (bounds 15..300, default 60). It MUST accept a response only if: the nonce is an exact echo of the outstanding challenge for that session; it arrives within `posture_response_timeout_seconds` (default 10); `issued_at_unix` is within ±30 seconds of coordinator time; and `sequence` is strictly greater than the last accepted sequence for that session. Each nonce is single-use. Eligibility derived from a verified posture MUST expire `posture_max_age_seconds` (default 150, at least interval plus timeout, at most 600) after coordinator verification. Posture state is in memory only: after a coordinator restart or session close every provider MUST be ineligible until a new posture verifies. A missed or late response makes the provider ineligible without quarantine.

### SPEC-049-R006 - Approved code identity and required posture values

A posture MUST be accepted only when `(team_id, signing_identifier, code_cdhash)` matches an entry of `privacy_class.approved_code_identities` whose `expires_at` is in the future and, when the entry names `binary_version`, that value matches too. The statement MUST report `hardened_runtime=true`, `library_validation=true`, `get_task_allow=false`, `cs_debugged=false`, `p_traced=false`, `pt_deny_attach_applied=true`, `core_dumps_disabled=true`, `sip_enabled=true`, `diagnostic_env_clear=true`, `kv_disk_tier_disabled=true`, and `runtime_source=native_mlx`. Approved identities are populated by the operator from signed release metadata (runbook §6); a provider can never add itself.

### SPEC-049-R007 - Provider hardening before network

When privacy mode is enabled the provider MUST apply the following sequence after the canonical re-exec decision and before any credential load, model load, local HTTP server, or coordinator connection, and MUST exit non-zero with a bounded reason code on any failure:

1. set RLIMIT_CORE soft and hard limits to 0;
2. call `ptrace(PT_DENY_ATTACH)`;
3. confirm P_TRACED is clear via `sysctl kern.proc.pid`;
4. read `csops(CS_OPS_STATUS)` and require CS_VALID, CS_HARD, CS_KILL, and CS_RUNTIME, refusing CS_DEBUGGED and CS_GET_TASK_ALLOW;
5. validate its own code signature (`SecCodeCopySelf`, `SecCodeCheckValidity`), read cdhash and team identifier, and refuse the entitlements `com.apple.security.get-task-allow`, `com.apple.security.cs.disable-library-validation`, and `com.apple.security.cs.allow-dyld-environment-variables`;
6. require SIP on via `csr_check`, treating an unavailable symbol as SIP off;
7. refuse when any `DYLD_*`, `MACPROVIDER_CB_TRACE`, `MACPROVIDER_PERF_TRACE`, `MACPROVIDER_KEEPALIVE_DEBUG`, or `MACPROVIDER_ALLOW_TEST_FIXTURES` environment variable is set;
8. refuse a loopback runtime, an enabled KV disk tier, relay-blind disabled, or a missing state directory.

Unsigned, ad-hoc-signed, dev, and debug builds therefore cannot start in privacy mode. Immediately before decrypting every privacy-class request the provider MUST re-check P_TRACED and CS_DEBUGGED; on failure it MUST NOT decrypt, MUST send SPEC-041-R005 bound rejection evidence with `error_code: privacy_class_posture_stale`, and MUST permanently stop posture responses and privacy key advertisement for the process lifetime. A test-fixture posture source MAY be injected only in the test fixture binary gated by `MACPROVIDER_ALLOW_TEST_FIXTURES=1`, which by step 7 can never run in production privacy mode.

### SPEC-049-R008 - Ephemeral privacy keys and key attestation

The privacy-class X25519 private key MUST exist only in process memory and MUST NOT be written to disk, keychain, logs, or state files. Each privacy key record lifetime (`expires_at_unix - not_before_unix`) MUST be at most 3600 seconds; rotation is by in-memory replacement or process restart. Privacy key records MUST be advertised only in `privacy_key_records` (§4.5), each with a valid `privacy-key-attestation-v1` signed by the SPEC-041 Ed25519 identity, and MUST NOT appear in `relay_blind_key_records`. The coordinator MUST verify the key record per SPEC-041-R002, the attestation signature against the identity pin, field equality with the record, and that `code_cdhash` is approved (SPEC-049-R006), and MUST store accepted records with key class `privacy`. The privacy execution journal and any privacy state live under `<state>/privacy/` with SPEC-041-R005 modes and content limits.

### SPEC-049-R009 - In-process native runtime only

Only the in-process `native_mlx` runtime MAY serve privacy-class work. The provider MUST NOT pass privacy-class plaintext through a loopback HTTP runtime, a subprocess, an IPC hop, or any network socket. Privacy-class work MUST arrive only over the authenticated coordinator WebSocket; the provider's local HTTP server MUST NOT accept, route, or expose privacy-class requests.

### SPEC-049-R010 - Sink suppression

For every privacy-class request the provider MUST produce no SPEC-015 receipt, no KV telemetry, no egress or performance trace, no conversation-cache entry or lookup, and no KV disk-tier write. No component MAY write prompt bytes, completion bytes, decrypted request JSON, frame plaintext, shared secrets, or key bytes to any log, trace, error message, metric label, crash breadcrumb, SQLite store, or state file. Errors carry bounded codes and digests only.

### SPEC-049-R011 - Plaintext lifetime

The provider SHOULD zero decrypted request bytes and its copy of the shared-secret bytes immediately after the request is parsed, and SHOULD zero each response plaintext buffer immediately after it is sealed. Deviation is acceptable only where the language type is immutable and cannot be zeroed (Swift `String` values holding prompt or completion text, and CryptoKit-owned key storage, which zeroes on deallocation); that deviation MUST be disclosed in the SPEC-049-R020 residual risks.

### SPEC-049-R012 - End-to-end marker binding

The header marker (§4.2), the reservation version (§4.6), the reservation row's privacy flag, the opaque dispatch context key, and the `inference_request` field (§4.7) MUST agree for every request. The coordinator MUST compare the header with the stored reservation privacy flag at consume and at chat, in both directions. The gateway and coordinator MUST reject the header on a non-envelope (plaintext) body before quota or dispatch. A privacy-mode provider MUST reject relay-blind dispatch that lacks the marker, and a provider not in privacy mode MUST reject relay-blind dispatch that carries the marker; both rejections occur before decryption with SPEC-041-R005 bound rejection evidence carrying `error_code: privacy_class_downgrade_rejected`. Every such mismatch MUST surface as `privacy_class_downgrade_rejected`.

### SPEC-049-R013 - Routing gate at every phase

At reservation, at consume, and immediately before dispatch, the coordinator MUST re-evaluate all of: the privacy class is enabled in configuration; the durable kill switch is not set (SPEC-049-R018); the provider is not quarantined; a verified posture for the same live session is no older than `posture_max_age_seconds`; the reserved privacy key digest is listed in that posture; the posture cdhash is still approved and unexpired; the key record is fresh and unrevoked with known revocation freshness; and the live WebSocket session is the one bound by the reservation. A privacy-class reservation MUST select only privacy-class key records, and a non-privacy relay-blind reservation MUST NOT select them. Failure before consume returns `privacy_class_unavailable` or `privacy_class_disabled`; failure between consume and dispatch burns the reservation, refunds held quota, and returns `privacy_class_posture_stale` or `privacy_class_disabled`. There MUST be no failover, retry, alternate provider, downgrade to plain SPEC-041 relay-blind, or downgrade to plaintext.

### SPEC-049-R014 - Response AEAD

The provider MUST seal every privacy-class response exactly as §4.8 specifies: response key and nonce prefix from the SPEC-041 transcript with the SPEC-049 labels, nonce as prefix plus u64 big-endian sequence, the exact frame AAD, the closed frame and final-frame schemas, contiguous sequence from 0, and exactly one final frame as the last frame. On cancellation or runtime error after decryption the provider MUST still emit an authenticated final frame with status `cancelled` or `error` when its WebSocket is writable. The response key MUST differ from the request key; reusing a nonce under one response key is forbidden.

### SPEC-049-R015 - Opaque relay of responses

The coordinator and gateway MUST forward privacy frames byte-for-byte, MUST NOT decode, parse, or log ciphertext, and MUST NOT treat a missing `choices` field in a privacy frame as an error. They MAY bound and annotate only the clear usage chunk or non-stream `usage` object. Settlement uses the clear usage bounded by the SPEC-041-R006 caps. On `unknown_postdispatch` the coordinator MUST settle known input only and MUST record a delivered-output estimate of 0, because it cannot count output from ciphertext. After a 200 response for a privacy-class request without exactly one coordinator privacy-class echo and exactly one positive `X-MacProvider-Privacy-Posture-Verified-At` value (§4.2), the gateway MUST return `privacy_class_unconfirmed` without writing the body.

### SPEC-049-R016 - Buyer verification

The reference client MUST, before encryption, verify the reservation version is `privacy-class-reservation-v1`, the key record against the operator pin per SPEC-041-R002, the key attestation signature against the same pin, attestation field equality with the record, `privacy_assurance` equal to the key attestation's `assurance` and to one of the two labels, and, when the buyer passed `--privacy-assurance-required code_bound_attested`, `privacy_assurance` equal to `code_bound_attested`; a predispatch mismatch aborts before encryption with nothing sent. After the response it MUST decrypt every frame, enforce contiguous sequence from 0, exactly one final frame, no frame after the final frame, a final status of `complete` for success, clear usage equal to the final frame's usage after cap bounding, the SPEC-049-R020 response headers with `X-MacProvider-Privacy-Assurance` equal to the reservation's `privacy_assurance`, and `usage.macprovider.privacy` equal to the SPEC-049-R020 string set for that label. Any failure after send MUST exit non-zero with a message ending `do not resubmit` and MUST NOT print undecrypted or partially verified content as a success.

### SPEC-049-R017 - Quarantine and key revocation

On a posture signature failure, an unapproved or expired code identity, any SPEC-049-R006 required value violated, a sequence regression, a `code_cdhash` change within one session, a key attestation cdhash differing from the session's verified posture cdhash, a SPEC-008 Secure Enclave key mismatch, or any reason code marked for quarantine in §4.12 (SPEC-049-R033), the coordinator MUST durably quarantine the provider for `privacy_class.quarantine_seconds` (default 86400) and durably revoke all of its privacy key records. A quarantined provider MUST be ineligible across coordinator restarts until expiry or explicit operator unquarantine. A posture timeout or missed challenge MUST make the provider ineligible without quarantine.

### SPEC-049-R018 - Durable kill switch

A durable `privacy_class_control` row with `disabled = 1` MUST block privacy-class reservation, consume, and dispatch from the next request onward and MUST move every held predispatch privacy-class reservation to `rejected` with quota refund. A store read error MUST be treated as disabled. The control is operated with `coordinator-cli privacy-class status|disable --reason|enable|quarantine --provider --reason --seconds|unquarantine --provider` against the configured relay-blind SQLite store. Disabling never affects plain SPEC-041 relay-blind or plaintext traffic.

### SPEC-049-R019 - Shared error inventory

The coordinator and gateway MUST implement the identical §4.9 code set with the identical HTTP status, retryable flag, and retry action, and each MUST have a completeness test against one shared inventory fixture. Neither component MAY emit a privacy code outside the inventory or remap one to a generic error.

### SPEC-049-R020 - Exact disclosure strings

Successful privacy-class responses MUST carry these response headers, where `<assurance>` is the label the request was served under (§4.2):

```text
X-MacProvider-Privacy-Class: operator_constrained_beta_v1
X-MacProvider-Privacy-Assurance: <assurance>
X-MacProvider-Response-Encryption: buyer_provider_aead_v1
```

`usage.macprovider.privacy` (non-stream `usage` object and stream clear usage chunk) MUST be the closed object `{class, assurance, scope, protects, does_not_protect, residual_risks, posture_verified_at_unix}` with `class` and `assurance` as above, `posture_verified_at_unix` from the coordinator's `X-MacProvider-Privacy-Posture-Verified-At` header on that chat response (§4.2), and the exact values below for that assurance, in this order.

#### Strings for `device_bound_self_attested_beta`

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

#### Strings for `code_bound_attested` (v0.2)

`scope`:

```text
request_and_response_content_hidden_from_relays; provider_runtime_reads_plaintext; ordinary_operator_access_paths_constrained_on_approved_signed_runtime; posture_signed_by_apple_attested_malibu_app_key; runtime_code_identity_checked_by_attested_app_not_by_apple; sip_and_full_security_attested_at_enrollment; label_verified_by_coordinator_not_by_buyer
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
10. `modified_or_resigned_runtime_binary_refused_by_attested_app_check`
11. `modified_or_resigned_malibu_app_cannot_sign_posture`
12. `posture_replay_refused_by_attested_counter`

`does_not_protect`:

1. `provider_runtime_reads_plaintext_to_infer`
2. `request_metadata_visible_to_relays`
3. `confidential_compute_or_hardware_enclave_execution`
4. `end_to_end_encryption_excluding_the_provider`
5. `pool_scoped_requests`
6. `kernel_or_firmware_compromise_with_sip_on`
7. `compromised_team_signing_key`

`residual_risks`:

1. `kernel_or_firmware_compromise_with_sip_on`
2. `physical_or_hardware_attack`
3. `gpu_and_unified_memory_residue`
4. `encrypted_swap_and_hibernation_images`
5. `compromise_of_the_live_runtime_process`
6. `malicious_signed_release_or_supply_chain`
7. `compromised_team_signing_key`
8. `apple_is_root_of_trust_for_app_attest`
9. `sip_and_full_security_attested_at_enrollment_only`
10. `label_verified_by_coordinator_not_by_buyer`
11. `crash_report_register_and_stack_residue`
12. `immutable_prompt_strings_not_zeroized`
13. `relays_observe_sizes_timing_and_token_counts`

#### Model listing and client output

`/v1/models` MAY expose `tier1_disclosure.operator_constrained_privacy` (omitted when the class is disabled) with `version: privacy-class-disclosure-v1`, class, assurance `device_bound_self_attested_beta`, that label's scope and lists, plus per-model buyer-safe `capable_provider_count` and `incapable_provider_count` derived only from currently eligible sessions of either label. When code-bound is enabled (SPEC-049-R034) it MAY also expose the sibling `tier1_disclosure.operator_constrained_privacy_code_bound` with the same closed shape and version, assurance `code_bound_attested`, that label's scope and lists, and counts derived only from currently eligible `code_bound_attested` sessions; it is omitted otherwise. The reference client MUST print the class, the served assurance, its scope, and its residual risks on stderr for every privacy-class run. These strings change only by a SPEC-049 version bump.

### SPEC-049-R021 - Automated redaction proof

An automated integration test MUST run privacy-class stream and non-stream requests with a canary prompt and a canary completion and MUST prove that neither canary, nor the base64url of the buyer ephemeral key or any derived key, appears in provider, coordinator, or gateway stdout/stderr, any SQLite store, the provider state directory, or the scenario temporary directories. The same suite MUST cover plaintext downgrade, header strip and inject, envelope replay, wrong key record, stale posture, revoked and quarantined providers, unapproved cdhash, debugger-attached posture, tampered and truncated responses, and the kill switch.

### SPEC-049-R022 - Composition limits

Any privacy-class request with a nonempty pool selection or other pool intent MUST be rejected with `privacy_class_downgrade_rejected` before reservation, quota, or dispatch, preserving SPEC-042-R009. Accounting, positive-receipt and reward exclusion, and SPEC-022 observe-mode limits follow SPEC-041-R006 unchanged. SPEC-005 arithmetic, the SPEC-015 v0.4 receipt tuple, and SPEC-022 finality are unchanged.

### SPEC-049-R023 - Promotion gate

This SPEC MUST remain `draft` with production status `not-deployed`, and every SPEC-049 requirement MUST remain non-conformant, until all of: the automated suites of SPEC-049-R021 and the unit/vector tests for every requirement pass; a signed `JOURNEY-PRIVACY-CLASS-BETA` result from a signed and notarized release on real hardware is committed; a staged canary rollout with an explicit activation exception under specs/PROCESS.md is recorded; and code, security, and architecture audits of the full diff report 0 Critical, 0 High, and 0 Medium findings. SPEC-049-R024..SPEC-049-R034 additionally require: coordinator verifier tests against a committed fixture of a real macOS 27 Developer ID attestation and at least two assertions (public material only), with negative vectors for a wrong rpIdHash, the development aaguid, a nonzero attestation counter, a missing or different aclBlob, a missing nonce extension, a chain to any other root, a bad assertion signature, and a counter regression; and a signed `JOURNEY-PRIVACY-CLASS-CODE-BOUND` result from a signed, notarized Malibu.app release on macOS 27 or later. The `code_bound_attested` label MUST NOT be served outside an isolated test coordinator before that.

### SPEC-049-R024 - Code-bound assurance label

The coordinator MUST grant `code_bound_attested` to a provider session only while all of the following hold: code-bound is enabled in the coordinator (SPEC-049-R034); the provider is not quarantined; the session is in the enrolled state, meaning the coordinator sent it `privacy_app_attest_enroll_result` with `enrolled` for a key that is still `active` in `privacy_app_attest_keys` and bound to the session's provider and current pins (SPEC-049-R027, SPEC-049-R029); the session's latest verified posture is a `version: 2` response that passed SPEC-049-R003..SPEC-049-R006, SPEC-049-R030, and SPEC-049-R031 and is no older than `posture_max_age_seconds`; and the reserved key record's attestation carries `code_bound_attested`. A session not in the enrolled state that passes the v0.1 checks keeps `device_bound_self_attested_beta` unchanged; a provider that never enrolls is never affected by v0.2. The coordinator MUST NOT derive the label from any unverified provider field, MUST NOT turn a failed code-bound check into the Beta label within the same session (it makes the session ineligible or quarantines it under SPEC-049-R033; only a coordinator-sent `reenroll_required` ends the enrolled state, after which a `version: 1` posture may earn the Beta label again), and MUST re-evaluate the label at reservation, consume, and dispatch as part of SPEC-049-R013. Neither label is a SPEC-008 trust tier.

### SPEC-049-R025 - Supervisor-attestor platform and key custody

Only the Malibu.app main executable MAY generate, attest, or use the App Attest key: bundle identifier `tech.malibu.app`, signed with Developer ID by the pinned team, notarized, carrying a Developer ID provisioning profile that grants `com.apple.developer.devicecheck.app-attest-opt-in`, running on macOS 27 or later in a logged-in user session with `DCAppAttestService.isSupported` true. The supervisor MUST NOT attest or assert for any process other than its verified supervised child (SPEC-049-R026), and MUST attest or assert only over a framing it recomputed itself from a `privacy-app-attest-enrollment-v1` or `privacy-posture-v2` statement whose supervisor-owned fields (§4.10 fields 25..34; §4.11 fields 7..9 and 12..14) it filled from its own observations. It MUST refuse a child-supplied draft whose `code_cdhash`, `signing_identifier`, or `team_id` differs from what it observed. `macprovider-cli` MUST NOT hold, request, or emulate an App Attest key. A provider not running as the supervised child of such an app (standalone CLI, LaunchAgent or daemon, macOS older than 27, App Attest unsupported, or code-bound disabled in the provider) MUST send only `version: 1` postures and Beta key attestations and MUST NOT send enrollment requests. The supervisor-child channel carries only statement fields, attestation and assertion objects, and status; it MUST NOT carry request or response plaintext, SPEC-041 or SPEC-049 envelope keys, or Secure Enclave or identity private keys, so SPEC-049-R009 is unchanged.

### SPEC-049-R026 - Dynamic child code-identity check

Before every attestation and every assertion the supervisor MUST, in this order:

1. accept the request only on its authenticated local channel (an XPC connection or a Unix-domain socket that the supervisor created and handed only to the child it spawned) and take the peer's audit token from the kernel (`xpc_connection_get_audit_token` or `LOCAL_PEERTOKEN`), never from a message field;
2. require the audit token's PID and PID version to identify the running child process it spawned;
3. obtain the child's `SecCode` from the audit token (`kSecGuestAttributeAudit`) and require `SecCodeCheckValidity` to pass against the requirement `anchor apple generic and identifier "live.malibu.provider.cli" and certificate leaf[subject.OU] = "<team_id>" and cdhash H"<approved cdhash>"`, where `<team_id>` is the supervisor's own team and the approved cdhash is that of the `macprovider-cli` executable embedded in and sealed by the supervisor's own validated bundle;
4. read the child's dynamic code-signing flags by audit token (`csops_audittoken` with `CS_OPS_STATUS`) and require every required flag and no forbidden flag of §4.1, so CS_VALID, CS_HARD, CS_KILL, and CS_RUNTIME are set and CS_DEBUGGED and CS_GET_TASK_ALLOW are clear;
5. read the dynamic cdhash (`kSecCodeInfoUnique`) and fill `child_cdhash`, `child_signing_identifier`, `child_cs_flags`, `child_checked_at_unix`, and `child_channel_peer_verified` from these observations.

On any failure the supervisor MUST NOT attest or assert, MUST terminate the child, MUST NOT respawn a privacy-mode child for the rest of its process lifetime, and MUST record a bounded local reason code. The coordinator independently re-checks the reported values (SPEC-049-R030).

### SPEC-049-R027 - App Attest enrollment

A provider in privacy mode under the supervisor MUST send `privacy_app_attest_enroll_request` only after its privacy key records were accepted in the session, with at most one outstanding request per session. The coordinator MUST reply:

- `unavailable` when code-bound is disabled, the provider is quarantined, a store read fails, a challenge is already outstanding for the session, or issuing a challenge would exceed `privacy_class.code_bound.max_enrollments_per_provider_per_day` challenges in the trailing 24 hours;
- `enrolled`, without a new attestation, when the keyId is the provider's `active` key and its stored pin hashes and team equal the current configuration;
- `reenroll_required` when the keyId is revoked for this provider, or is its active key with a stale binding (which the coordinator first revokes as `binding_stale`);
- `rejected`, with quarantine reason `app_attest_binding_mismatch`, when the keyId is enrolled, active or revoked, to a different provider;
- otherwise a `privacy_app_attest_enroll_challenge` with a fresh 32-byte random challenge bound to the session and keyId and usable once.

The enrollment MUST arrive within 60 seconds of the challenge with `issued_at_unix` within ±30 seconds of coordinator time and an exact echo of the challenge; otherwise the coordinator discards the challenge and replies `unavailable` without quarantine. A closed-schema or size violation of the enrollment, or a failure under SPEC-049-R028 or SPEC-049-R029, MUST yield `rejected` and quarantine with the matching §4.12 reason. On success the coordinator MUST, in one durably committed SQLite transaction, revoke any other active key of the provider as `superseded` and insert the new key as `active` with `last_counter` 0, and only then reply `enrolled`; a commit failure yields `unavailable` without quarantine.

After `enrolled` the provider MUST replace every advertised privacy key record with records attested `code_bound_attested` before its next posture response and MUST send only `version: 2` postures for the rest of the session. After `unavailable` it continues as Beta and MAY retry no sooner than 300 seconds later. After `reenroll_required` it MUST discard the keyId, generate a new key, and enroll it. After `rejected` it MUST NOT enroll again in that process lifetime. An enrollment attestation is sent once per key; later sessions present the same keyId and receive `enrolled`.

### SPEC-049-R028 - Coordinator attestation verification

The coordinator MUST verify every enrollment as follows and reject on the first failure:

1. the statement satisfies §4.11; `se_signature` verifies as ECDSA-P256-SHA256 and `identity_signature` as Ed25519 over the recomputed enrollment framing against the SPEC-049-R004 pins; `provider_id`, `assigned_session`, `challenge`, `app_attest_key_id`, `team_id`, `bundle_id`, `environment`, `se_public_key`, and `identity_public_key` equal the session, the outstanding challenge, the request, the configuration, and the pins (reason `app_attest_binding_mismatch`);
2. `attestation` decodes as exactly one definite-length CBOR map with exactly the text keys `fmt`, `attStmt`, and `authData`; `fmt` is `apple-appattest`; `attStmt` is a map with exactly `x5c` (an array of at least two byte strings, each a DER X.509 certificate) and `receipt` (a nonempty byte string, not otherwise evaluated);
3. `x5c[0]` is the leaf and is not a CA; every later element is a CA certificate with valid basic constraints; each certificate's signature verifies under the next one, and the last under the Apple App Attestation Root CA, which is compiled into the coordinator and checked at startup against the §4.1 SHA-256 DER fingerprint; every certificate is within its validity period at verification time with at most 300 seconds of skew;
4. the leaf public key is P-256 and SHA-256 of its 65-byte uncompressed point equals `app_attest_key_id`;
5. with `clientDataHash = SHA-256(enrollment framing)` and `nonce = SHA-256(authData || clientDataHash)`, the leaf carries extension `1.2.840.113635.100.8.2` exactly once, its value has the §4.1 shape, and its octets equal `nonce`;
6. `authData` has rpIdHash equal to SHA-256 of the App ID, the AT flag set, counter 0, the production aaguid, a 32-byte credentialId equal to `app_attest_key_id`, and a COSE credential public key with kty 2 (EC2), alg -7 (ES256), crv 1 (P-256), and x and y equal to the leaf key;
7. the authenticator extensions map is OPTIONAL: real macOS 27 Developer ID attestations carry none. When bytes follow the credential public key they MUST be exactly one CBOR map, and if it contains `apple_validation_category_01` the value MUST be 6 (Developer ID); other entries are not interpreted;
8. the leaf carries extension `1.2.840.113635.100.8.6` exactly once; its value is a DER SEQUENCE with exactly one element, either an OCTET STRING or a constructed context-specific tag wrapping exactly one OCTET STRING, and those octets equal the §4.1 required aclBlob byte for byte (reason `app_attest_acl_mismatch`);
9. `child_cdhash`, with the configured team and `live.malibu.provider.cli`, matches an unexpired `privacy_class.approved_code_identities` entry, and `child_cs_flags` satisfies the §4.1 masks (reason `supervisor_child_check_failed`).

Failures of steps 2..7 use reason `app_attest_attestation_invalid`. The coordinator MUST NOT contact Apple during verification; fraud-metric receipt evaluation is out of scope.

### SPEC-049-R029 - Key binding

An enrolled key MUST be bound to its `provider_id`, the configured team, and the SHA-256 of the Secure Enclave and identity pins in force at enrollment (§4.12). A provider has at most one `active` key; a keyId is enrolled to at most one provider ever; a revoked keyId MUST never become active again. On every `version: 2` posture the coordinator MUST confirm that the referenced keyId is the session's enrolled key, is still `active`, belongs to the session's `provider_id`, and still matches the current pins and team. A stale binding revokes the key as `binding_stale`, ends the session's enrolled state, sends `reenroll_required`, and makes the session ineligible without quarantine. The SPEC-049-R004 Secure Enclave and identity signatures remain mandatory on every `version: 2` posture, so the App Attest key is used together with the pinned keys, never instead of them.

### SPEC-049-R030 - Closed code-bound posture

The provider MUST produce, and the coordinator MUST accept only, `version: 2` responses that satisfy §4.10. In addition to SPEC-049-R003..SPEC-049-R006 on fields 1..24, the coordinator MUST require `assurance` `code_bound_attested`; `app_attest_key_id` equal to the session's enrolled key; `supervisor_team_id` equal to the configured team and to `team_id`; `supervisor_bundle_id` `tech.malibu.app`; `child_cdhash` equal to `code_cdhash`; `child_signing_identifier` and `signing_identifier` both `live.malibu.provider.cli`; `child_cs_flags` satisfying the §4.1 masks; `child_checked_at_unix` within ±5 seconds of `issued_at_unix`; and `child_channel_peer_verified` true. A violation of fields 30..34 is quarantine reason `supervisor_child_check_failed`. A `version: 2` response from a session not in the enrolled state is rejected and makes the session ineligible without quarantine. A `version: 1` response from a session in the enrolled state is quarantine reason `assurance_regression`.

### SPEC-049-R031 - Assertion verification and durable counter

For every `version: 2` posture the coordinator MUST, after all other posture checks pass:

1. decode `app_attest_assertion` with the closed §4.10 shape;
2. require the rpIdHash to equal SHA-256 of the App ID;
3. compute `clientDataHash = SHA-256(recomputed v2 posture framing)` and `nonce = SHA-256(authenticatorData || clientDataHash)`;
4. verify `signature` as an ASN.1 DER ECDSA P-256 signature with SHA-256 over the message `nonce` (that is, over the digest SHA-256(`nonce`)) under the stored `public_key` of the session's enrolled key;
5. require the counter to be strictly greater than the stored `last_counter`;
6. durably commit the new counter with a conditional update of the `active` row whose `last_counter` is below the new value, requiring exactly one updated row, before marking the posture verified.

Failures of steps 1..4 are quarantine reason `app_attest_assertion_invalid`; a failure of step 5 is quarantine reason `app_attest_counter_regression`. A store error or zero updated rows in step 6 makes the session ineligible without quarantine and leaves the posture unverified. The counter MUST never be held only in memory and survives coordinator restarts. A counter of 4294967295 is accepted once, after which the key is revoked as `counter_exhausted` and the session receives `reenroll_required`.

### SPEC-049-R032 - Assurance propagation and buyer requirement

The provider MUST attest key records `code_bound_attested` only in the enrolled state and `device_bound_self_attested_beta` otherwise. The coordinator MUST drop, without quarantine, a `code_bound_attested` key attestation from a session not in the enrolled state; MUST quarantine with `assurance_regression` a `device_bound_self_attested_beta` key attestation from a session in the enrolled state; and MUST quarantine with `assurance_mismatch` a posture whose `privacy_key_record_digests` names a record of the other label. The gateway MUST validate and forward `X-MacProvider-Privacy-Assurance-Required` exactly as §4.2 states, rejecting an invalid header with `privacy_class_downgrade_rejected` before quota. With that header the coordinator MUST reserve only a `code_bound_attested` record of a session currently granted that label under SPEC-049-R024, or return `privacy_class_unavailable`; without it the coordinator MAY reserve a record of either label. The reservation stores its `privacy_assurance`, and at consume and dispatch the session's current label MUST still equal it: a mismatch before consume returns `privacy_class_unavailable`, and after consume it burns the reservation, refunds held quota, and returns `privacy_class_posture_stale`. A reservation's label is never upgraded or downgraded. The coordinator MUST set `X-MacProvider-Privacy-Assurance` on the successful chat response, and the gateway MUST handle it as §4.2 states. The reference client MUST accept `--privacy-assurance-required code_bound_attested` and MUST verify it under SPEC-049-R016. A v0.1.0 reference client rejects a `code_bound_attested` reservation before encryption, with nothing sent; clients that may meet a code-bound provider MUST be v0.2.0.

### SPEC-049-R033 - Key lifecycle, quarantine, and fail-closed behaviour

When its key becomes unusable (`DCError.invalidKey` or any other App Attest error that the key cannot be used, including after a reinstall or an app update, or a `reenroll_required` reply), the supervisor MUST discard the keyId and enroll a new key; until a new `enrolled` reply the session can hold only the Beta label. The coordinator MUST durably revoke a key, with a §4.12 reason code, before any later eligibility decision that depends on it, and MUST send an unsolicited `reenroll_required` to a live session whose key it revokes without quarantine; `reenroll_required` ends the session's enrolled state. `coordinator-cli privacy-class revoke-app-attest-key --provider --reason` revokes the active key as `operator_revoked`, and `coordinator-cli privacy-class status` lists each key's keyId, state, `last_counter`, and reason, never private material. Every §4.12 reason marked for quarantine MUST trigger the SPEC-049-R017 durable quarantine and privacy key record revocation, and MUST also revoke the provider's active App Attest key with that reason; unquarantine never reactivates a key. Code-bound fails closed: when it is disabled, when the compiled Apple root fails its startup fingerprint check, or when the key store cannot be read or written, no session is granted `code_bound_attested`, enrollment replies `unavailable`, and `version: 2` postures stay unverified. None of these conditions grants the Beta label to a session in the enrolled state. Session enrolled state is in memory and ends with the session or a coordinator restart; durable key rows and counters persist, so a reconnecting provider re-presents its keyId and receives `enrolled` without a new attestation.

### SPEC-049-R034 - Code-bound configuration, default off

Code-bound MUST default off in every component that has a switch: the coordinator (`privacy_class.code_bound.enabled: false`), the provider (Malibu.app setting `privacyCodeBound` false and `macprovider-cli` flag `--privacy-code-bound` absent), and the reference client (`--privacy-assurance-required` absent). The gateway has no separate switch; its existing privacy-class switch covers both labels. When enabled the coordinator MUST require `privacy_class.enabled: true`, `privacy_class.code_bound.team_id` (exactly 10 uppercase ASCII letters or digits), and `privacy_class.code_bound.max_enrollments_per_provider_per_day` (default 3, bounds 1..10), and MUST fail configuration validation otherwise. The Apple root, the aclBlob value, the production aaguid, the bundle identifier, and the child signing identifier are compiled constants, not configuration; no configuration enables the development environment. Disabling code-bound MUST leave `device_bound_self_attested_beta`, plain SPEC-041 relay-blind, and plaintext behaviour unchanged.

## 6. Operator runbook requirement

The normative operator procedure is `docs/runbooks/privacy-class-beta-operations.md` (created with the implementation). It covers: collecting the provider Secure Enclave public key and relay-blind identity through `macprovider-cli privacy-class identity`; deriving `approved_code_identities` entries from a signed release binary; enabling each component; the incident procedure (kill switch, quarantine, key revocation, rotation by restart); and the residual-risk tables of §2.5 and §2.7. From v0.2 it also covers: the Apple Developer portal App Attest capability and Developer ID provisioning profile for `tech.malibu.app`; enabling code-bound (SPEC-049-R034); reading App Attest key state and revoking a key (SPEC-049-R033); and re-enrollment after key loss. Tooling and documentation MUST never print private key bytes.

## 7. Implementation, tests, and journeys

The authoritative mapping is `specs/CONFORMANCE.json`. SPEC-049-R001..SPEC-049-R023 map to `JOURNEY-PRIVACY-CLASS-BETA`; SPEC-049-R024..SPEC-049-R034 map to `JOURNEY-PRIVACY-CLASS-CODE-BOUND`; implementation and test selectors are added as the implementation lands. v0.2 planned surfaces: Malibu.app App Attest supervisor and child check; provider enrollment and `version: 2` posture; the coordinator attestation and assertion verifier with the compiled Apple root, the key store, and the CLI; gateway assurance headers; reference-client assurance requirement; and verifier vectors from the real macOS 27 hardware attestation. Planned surfaces: shared Go privacy crypto and types in both relay-blind modules with a byte-identity parity check; Swift crypto parity against the shared vector `test/fixtures/relay-blind/privacy-response-v1.json`; provider hardening, posture responder, and response sealing; coordinator configuration, store, posture verification, routing gate, and kill-switch CLI; gateway marker, opaque relay, and disclosure; reference-client verification; and the cross-service redaction and adversarial integration suite.

## 8. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-049-R001`..`SPEC-049-R023` | `DECISION_REQUIRED` | `@Augustas11` | `#1749` | Implementation, automated tests, signed hardware journey, staged canary, three-lane audits |
| `SPEC-049-R024`..`SPEC-049-R034` (code-bound) | `DECISION_REQUIRED` | `@Augustas11` | `#1840` | Malibu.app supervisor and App Attest implementation, coordinator verifier with real-hardware vectors, signed `JOURNEY-PRIVACY-CLASS-CODE-BOUND` result, three-lane audits |
| Trusted Pool composition | `DECISION_REQUIRED` | `@Augustas11` | follow-up of `#1749` | SPEC-042-R009 amendment binding pool identity into AAD and posture |

## 9. Evidence

No evidence is attached. Physical evidence requires a signed `JOURNEY-PRIVACY-CLASS-BETA` result produced on Apple Silicon hardware running a signed and notarized release. The v0.2 design rests on the #1840 App Attest hardware spike (macOS 27.0.1, 2026-10-04, recorded on issue #1840): a Developer ID Malibu.app received a key and attestation that verified against the pinned root with the required aclBlob; two assertions verified with increasing counters; a re-signed app was refused launch or received a non-matching rpIdHash; a re-signed child failed the app's check. That spike is design input, not conformance evidence.

## 10. Changelog and history

- 0.1.0 - Initial default-off Beta contract: exact claim and non-claims; threat model with device-bound, not code-bound, self-attested posture; closed posture statement, key attestation, reservation, dispatch marker, and response AEAD schemas; routing gate with no failover or downgrade; quarantine and durable kill switch; shared error inventory; exact disclosure strings; redaction proof; promotion gate. Carries forward the Product Build 2/Build 4 decisions (#1643, #1645, PR #1471) and keeps SPEC-042-R009.
- 0.1.0 - Successful privacy-class chat responses carry `X-MacProvider-Privacy-Posture-Verified-At` from the dispatch-time gate for the gateway. The gateway does not store that timestamp, and the header is not a buyer response header.
- 0.2.0 - Adds the default-off `code_bound_attested` assurance label (issue #1840) using a Malibu.app supervisor-attestor with Apple App Attest: exact claim, non-claims, and threat model with code-bound residual risks; `privacy-posture-v2` and the `version: 2` posture response with an App Attest assertion; App Attest enrollment messages and statement; coordinator attestation verification against the pinned Apple App Attestation Root CA with the required SIP and Full Security aclBlob and an optional authenticator extensions map; assertion verification with a durably persisted strictly increasing counter; key binding, lifecycle, quarantine reasons, and fail-closed rules; buyer assurance requirement header and coordinator assurance header; code-bound disclosure strings; SPEC-049-R024..SPEC-049-R034 and `JOURNEY-PRIVACY-CLASS-CODE-BOUND`. `privacy-posture-v1` and the Beta strings are unchanged; no new public error code.
