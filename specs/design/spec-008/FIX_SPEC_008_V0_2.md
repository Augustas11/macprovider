# Fix prompt — SPEC-008 v0.2

Operator-paste prompt that produces **SPEC-008 v0.2** by resolving every
finding from the Round 1 audit report (`specs/SPEC-008-audit.md`).

The audit found 2 CRITICAL, 17 MAJOR, 1 MINOR, and 1 QUESTION.  Neither
CRITICAL requires reopening the four-pillar/three-phase architecture; both are
precision fixes.  The verdict was **READY WITH FIX PASS**, so this prompt
drives that fix pass before Phase 1 implementation begins.

Run in **Codex** or **Claude Code**.  Expected duration: ~2-3 hours.
Input: `specs/SPEC-008-tier2.md` (v0.1).  Output: same file, bumped to v0.2.
No code is written; this is a spec revision session.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are revising SPEC-008 v0.1 to produce v0.2.

Input:  /Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md
Audit:  /Users/augstar/macprovider-poc/specs/SPEC-008-audit.md
Output: same file, in-place.  Bump version header to 0.2 and add a v0.2
change-log entry that lists every finding ID resolved.

You are NOT redesigning the spec.  You are making targeted surgical fixes
to the sections called out in the audit.  The four-pillar structure, phase
order, Tier-1 default-preservation rule, clean-room constraint, and
survivability certificate all stand.  Fix precisely what the audit found;
do not expand scope or reorganize sections.

Work finding-by-finding in the order below.  After all fixes, do one pass
to confirm that internal cross-references and AC numbering are still
consistent.  If a fix creates a new term, add it to §3.

---

## CRITICAL fixes (must land before Phase 1 BUILD)

### C1 — Default config MUST NOT activate Tier-2 API or log behavior

**Audit location:** §4.3, §5.7, AC-T2-5.

**What is wrong:** §4.3 says the coordinator MAY compute and log Tier-2
evidence when fields are present.  §5.7 says the `hash_verification` object
appears when "Phase 1 is active, meaning a catalog is configured, a provider
reports model_hash, or tier2.require_hash_verified is enabled."  Both clauses
allow Tier-2 behavior to activate with no config change, violating the hard
rule that a default-config binary produces no new log lines, routing changes,
API fields, or buyer-visible responses.

**Required fixes:**

1. §4.3 — Replace the "MAY compute and log" sentence.  The coordinator MUST
   NOT compute Tier-2 evidence, emit Tier-2 audit events, change routing
   decisions, or add Tier-2 fields to any response unless at least one of:
   - `tier2.catalog_path` is non-empty, OR
   - any `tier2.require_*` enforcement key is true, OR
   - a new `tier2.observe_enabled: false` flag is explicitly set to true.
   Add `tier2.observe_enabled` to the config table in §11 with default false,
   validation that it MUST be false when all other tier2 keys are defaults,
   and a note that it exists to allow observe-without-enforce deployments.

2. §5.7 — Rewrite the presence condition for the `hash_verification` object.
   It MUST appear only when at least one of:
   - `tier2.catalog_path` is non-empty, OR
   - `tier2.require_hash_verified: true`, OR
   - `tier2.observe_enabled: true`.
   With all tier2.* keys at defaults and no `catalog_path`, `/v1/models` MUST
   be byte-identical to the Tier-1 response.

3. AC-T2-5 — Expand the acceptance criterion to assert ALL of the following
   under a default-config deployment (every tier2.* key at its default,
   no catalog_path, no provider Tier-2 evidence):
   - provider selection is unchanged,
   - `/v1/models` response is byte-identical to Tier-1 baseline,
   - `/v1/chat/completions` responses are byte-identical,
   - no `T2.*` audit/log events are emitted,
   - no Tier-2 fields (`hash_verified`, `hash_verification`, `attested`,
     `attestation`, `tier2_session`, `tier2_milestone`) appear in any response.

---

### C2 — Cryptographic key material and raw attestation tokens are missing from the audit forbidden-field list

**Audit location:** §12.1, §15.2, §15.3, AC-T2-25.

**What is wrong:** §12.1's forbidden-field list covers API keys, provider
bearer tokens, raw prompts, completions, account IDs, conversation tags, and
routing_internal.conversation_key.  It does not mention ECDH private keys,
X25519 shared secrets, HKDF PRKs/OKMs, AEAD keys, raw attestation tokens,
JWS bodies, challenge bytes (outside the challenge exchange itself), or other
raw cryptographic proof material introduced by Pillars B and C.

**Required fixes:**

1. §12.1 — Extend the "MUST NOT include" list to add:
   - ECDH private keys (coordinator and provider),
   - X25519 shared secrets and HKDF-derived PRKs/OKMs,
   - AEAD session keys and per-frame nonces beyond the key ID (`kid`),
   - raw attestation token bytes or JWS body,
   - raw attestation challenge bytes (only `challenge_id` / truncated prefix
     is permitted),
   - unredacted trust-root certificate material or private signing keys.
   The `kid` (key ID derived from key transcript hash) is permitted.
   The `challenge_id` (a short coordinator-assigned identifier or the first 8
   bytes base64url-encoded) is permitted.

2. §15.2 T2.B required fields — Confirm the list allows `kid` but not raw
   key bytes.  Add a note: "MUST NOT include shared secret, AEAD key, or
   per-frame nonce."

3. §15.3 T2.C required fields — Replace `challenge_id` with a clear
   definition: the coordinator-assigned short ID for the challenge attempt,
   not the raw 32-byte challenge value.  Add: "MUST NOT include raw
   attestation token bytes or JWS body."

4. AC-T2-25 — Extend the acceptance criterion to also check that Tier-2
   audit events do not include: ECDH private keys, shared secrets, HKDF keys,
   AEAD keys, raw attestation token bytes, and raw challenge bytes.

---

## MAJOR fixes

### M1 — Hash-mismatch routing contradiction

**Audit location:** §5.5 and §5.6.

**What is wrong:** §5.5 says hash_mismatch and hash_invalid MUST exclude the
provider.  §5.6 then says hash status MUST NOT change routing when
require_hash_verified is false, except that a catalogued mismatch SHOULD be
excluded.  SHOULD versus MUST on known-bad state is a contradiction.

**Required fix:** In §5.6, change the default-off routing rule to: when
`tier2.require_hash_verified: false`, `hash_mismatch` and `hash_invalid` for a
catalogued model MUST be excluded from routing (not SHOULD).  Only
`uncatalogued` and `catalog_unavailable` are permissive at default.
Rationale sentence: "The coordinator has positive evidence of a false
advertised identity; routing to that provider serves the wrong model."

---

### M2 — Tier-2 buyer error envelopes are under-specified

**Audit location:** §4.5, §5.6, §6.8, §7.6.

**What is wrong:** Error envelopes for Tier-2 conditions give HTTP status and
a machine code but no `error.type`, exact message template, or streaming
behavior contract.  SPEC-006 §4 locks the error envelope vocabulary.

**Required fix:** Add a new §4.6 "Tier-2 error table" immediately after the
routing integration section.  The table MUST include one row per error code:

| Code | HTTP | error.type | Message (template) | Streaming: committed? |
|---|---|---|---|---|
| tier2_hash_verified_required | 503 | server_error | No hash-verified provider available for model {model_id}. | N/A — pre-selection |
| tier2_encrypted_leg_required | 503 | server_error | No Pillar-B encrypted provider available for model {model_id}. | N/A |
| tier2_attestation_required | 503 | server_error | No attested provider available for model {model_id}. | N/A |
| tier2_hard_pin_predicate_failed | 400 | invalid_request | Hard-pinned provider {provider_id} does not satisfy enabled Tier-2 predicates. | N/A |
| tier2_hash_mismatch | 503 | server_error | Provider {provider_id} hash verification failed; excluded from pool. | N/A |
| tier2_aead_decrypt_failed | 502 | server_error | Provider response authentication failed. | If post-commit: emit error SSE event, close stream. |
| tier2_output_encoding_invalid | 502 | server_error | Provider response encoding validation failed. | If post-commit: emit error SSE event, close stream. |

Messages MUST NOT reveal raw hashes, keys, attestation tokens, or
trust-root details.  Placeholders like `{model_id}` are literal substitution
variables; implementations MUST substitute the actual value.

---

### M3 — Response-direction AEAD AAD is not defined

**Audit location:** §6.5, §6.7, §10.7.

**What is wrong:** §6.5 defines canonical AAD for inference_request
(direction: "c2p").  §10.7 shows inference_response_chunk with an `enc.aad`
field but does not define its schema.

**Required fix:** In §6.5, rename the existing AAD definition as
"§6.5.1 Request AAD (c2p)" and add "§6.5.2 Response AAD (p2c)" immediately
after.  Response AAD MUST use deterministic JSON with these fields:

```json
{
  "type": "inference_response_chunk",
  "direction": "p2c",
  "request_id": "req-...",
  "seq": 0,
  "provider_id": "m4-anon",
  "assigned_id": "provider-pool-id",
  "stream": true
}
```

Response AAD MUST NOT include routing_internal.conversation_key, raw buyer
conversation tags, raw account_id, or sticky-entry IDs (mirroring §6.5.1).
The coordinator verifies p2c AAD before decrypting and before applying Pillar D.

---

### M4 — AEAD decrypt-failure behavior is missing

**Audit location:** §6.7, §12.3, §15.2.

**What is wrong:** aead_decrypt_failed is named as an audit event but the
spec does not define what the coordinator does when authentication fails.

**Required fix:** Add a §6.7.1 "Decryption failure handling" paragraph:

Pre-commit failure (no buyer bytes written):
- Log MAJOR T2.B aead_decrypt_failed.
- MUST NOT forward unauthenticated bytes to buyer.
- Close or quarantine the provider session; emit T2.B encrypted_leg_session_closed.
- Return tier2_aead_decrypt_failed (HTTP 502) per the §4.6 error table.
- SPEC-002 failover MAY be attempted for non-hard-pinned requests using a
  different eligible provider; hard-pinned requests MUST fail.

Post-commit failure (streaming bytes already sent to buyer):
- Log MAJOR T2.B aead_decrypt_failed.
- MUST NOT forward additional bytes from the failed frame.
- Emit a streaming SSE error event and close the buyer stream.
- Close the provider session.
- No retry or failover is attempted after buyer commit.

---

### M5 — Attestation token encoding and max length are unspecified

**Audit location:** §7.4, §10.4.

**What is wrong:** token field is "base64url-or-JWS-token" with no max
length, encoding constraint, or rejection code for oversized tokens.

**Required fix:** In §7.4 and §10.4, add:

- Accepted encodings: (a) base64url-encoded raw DER/CBOR bytes, or (b) compact
  JWS (three dot-separated base64url segments).  No other encodings are
  accepted.
- Maximum encoded token length: 16384 bytes (16 KiB).  Coordinators MUST
  reject tokens exceeding this length with error code
  `tier2_attestation_token_too_large` (HTTP 400, type `invalid_request`),
  logged as T2.C attestation_failed.
- Malformed tokens (not valid base64url, not valid compact JWS, or decoded
  bytes not parseable as the declared format) MUST be rejected with
  `tier2_attestation_token_invalid` (HTTP 400, type `invalid_request`).
- Add both new codes to the §4.6 error table.

---

### M6 — Key and token material are not forbidden in buyer errors, auth responses, or close reasons

**Audit location:** §6.8, §7.6, §10.5, §10.9.

**What is wrong:** Error paths for buyer responses, v2 auth_response.error,
and WebSocket close reasons have no redaction rule.  These paths can leak the
same material that §12.1 forbids from audit logs.

**Required fix:** Add a §4.7 "Tier-2 redaction rule" section (before the
pillar sections):

All Tier-2 error messages, auth_response.error.message values, and WebSocket
close reasons MUST use generic human-readable text that identifies the failure
class (e.g., "attestation failed", "key exchange failed") and MUST NOT include:
- raw ECDH or AEAD keys, nonces, or secrets,
- raw attestation token bytes or JWS bodies,
- expected or reported cryptographic hashes beyond a truncated prefix
  (maximum 8 hex characters),
- raw API keys, provider bearer tokens, account IDs, or conv: values,
- unredacted trust-root certificate details.

Add a cross-reference to §4.7 in §6.8, §7.6, §10.5, and §10.9.

---

### M7 — Encrypted-leg fallback logging is SHOULD and conditional

**Audit location:** §6.8.

**What is wrong:** When require_encrypted_leg is false, fallback logging to
T2.B is SHOULD and only when an encrypted provider exists for the same model.
This allows silent cleartext fallback.

**Required fix:** In §6.8, change the fallback logging to MUST when
`tier2.observe_enabled: true` or when any Pillar B configuration key is
non-default (i.e., `encrypted_leg_aead` has been changed, or any
`encrypted_leg_*` threshold is set, or an encrypted provider exists for the
model).  Pure Tier-1 deployments with no Pillar B config and no v2 providers
remain exempt and unchanged.

---

### M8 — Pillar D global flag and per-control flags conflict

**Audit location:** §8.2, §8.3-8.5, §9.3, §11.1, §13.3.

**What is wrong:** behavioral_safety_enabled, encoding_validation_enabled, and
response_time_anomaly_enabled are each independently defined but the
precedence and disclosure mapping is not explicit.

**Required fix:** Add a §8.6 "Pillar D flag precedence matrix" table (before
the existing AC section, renumbering if needed):

| behavioral_safety_enabled | output_size_cap_bytes | encoding_validation_enabled | response_time_anomaly_enabled | Effective state | untrusted_provider_safety |
|---|---|---|---|---|---|
| false | any | any | any | disabled | "none" |
| true | 0 | false | false | size cap disabled; all controls off | "none" |
| true | >0 | false | false | size cap only | "partial" |
| true | 0 | true | false | encoding only | "partial" |
| true | 0 | false | true | TTFT only | "partial" |
| true | >0 | true | true | all controls | "enforced" |
| true | >0 | true | false | cap + encoding | "partial" |
| true | >0 | false | true | cap + TTFT | "partial" |
| true | 0 | true | true | encoding + TTFT | "partial" |

"enforced" requires size cap active (>0), encoding validation on, and TTFT
anomaly logging on.  Any missing control makes the state "partial".

---

### M9 — Completion encoding/control-character validation boundary is vague

**Audit location:** §8.4.

**What is wrong:** "control characters outside \t, \n, and \r" is not
precise.  The validation target (raw frame, SSE framing, JSON envelope, decoded
completion) is not specified.

**Required fix:** In §8.4, replace the bullet with explicit definitions:

Forbidden byte ranges (after Pillar B decryption, before buyer write):
- C0 range U+0000–U+001F, except: U+0009 (TAB), U+000A (LF), U+000D (CR).
- U+007F (DEL).
- C1 range U+0080–U+009F.

Validation targets:
- Streaming: applied to the decoded completion text extracted from each SSE
  `data:` field.  JSON string escapes (e.g. ` `) in the SSE payload are
  decoded before validation; the escaped byte value is subject to the
  forbidden-range check.
- Non-streaming: applied to the decoded completion text from the `content`
  field of the response JSON body.  Invalid JSON in the body is rejected
  separately per the existing invalid-JSON bullet.
- The coordinator MUST NOT reject SSE framing control bytes (newlines,
  colons in `data:` lines) that are part of valid SSE framing; only the
  completion text payload is checked.

---

### M10 — SPEC-001 v2.0 version negotiation is absent

**Audit location:** §10.1.

**What is wrong:** Old providers send hello; v2 providers send auth_request.
The coordinator cannot tell whether a malformed v1 hello is a bad v1 message
or a v2 attempt.  No negotiation surface is defined.

**Required fix:** Add a §10.1.1 "First-message dispatch rule":

The coordinator MUST apply this deterministic rule to the provider's first
WebSocket message:
1. If the message parses as JSON and `type == "auth_request"` and
   `version == 2`, process as SPEC-001 v2.0 auth flow.
2. If the message parses as JSON and `type == "hello"` and `version == 1`,
   process as SPEC-001 v1 (Tier-1 semantics).
3. Otherwise, close the WebSocket with close code 4000 and reason
   "unrecognized auth message" (per §4.7 redaction: no internal detail).

The coordinator MUST NOT send any frame before the provider's first message.
No welcome or capability frame is required in v0.1; the first-message type
field is sufficient for dispatch.

Future: a §10.1.2 placeholder notes that a coordinator-capability frame MAY
be defined in a SPEC-001 v2.1 annotation if bidirectional negotiation is
needed for cipher-suite selection before the provider sends auth_request.

---

### M11 — `tier2.*` config reload semantics are undefined

**Audit location:** §5.2, §11.

**What is wrong:** The spec does not say which tier2 keys require restart vs
support hot reload, or what happens to existing sessions when enforcement
flags change.

**Required fix:** Add a §11.5 "Config lifecycle table":

| Config key | Reload behavior | Effect on existing sessions |
|---|---|---|
| catalog_path / catalog_public_key | Startup only.  Change requires restart. | N/A |
| require_hash_verified | Hot-reloadable (SIGHUP or equivalent). | Existing provider sessions are re-evaluated at next request; no mid-request ejection. |
| require_encrypted_leg | Hot-reloadable. | Existing unencrypted sessions are not immediately closed; re-evaluated at next provider reconnect or new session. |
| encrypted_leg_aead / rekey thresholds | Startup only. | N/A |
| require_attestation | Hot-reloadable. | Existing sessions are re-evaluated at next request. |
| attestation_roots / attestation_formats | Startup only. | N/A |
| attestation_max_age_s | Hot-reloadable. | Applies to next attestation validation. |
| behavioral_safety_enabled / Pillar D flags | Hot-reloadable. | Applied to next response chunk after reload completes. |
| observe_enabled | Hot-reloadable. | Applies to next provider registration or request. |

Startup-only keys MUST cause coordinator startup failure if invalid.
Hot-reloadable keys log a reload event at INFO when changed.

---

### M12 — Coordinator restart behavior for encrypted sessions is undefined

**Audit location:** §6.9, §12.3.

**What is wrong:** Pillar B keys are per-session in-memory.  SPEC-002 says
providers reconnect after restart but SPEC-008 does not specify the Pillar B
key invalidation behavior.

**Required fix:** Add a §6.10 "Coordinator restart behavior":

Coordinator restart invalidates all in-memory Pillar B session keys.
- In-flight encrypted requests that have not yet committed buyer bytes MUST
  fail per SPEC-002's existing disconnect/timeout rules; the buyer receives
  the SPEC-002 503 or gateway error.
- In-flight streaming responses already committed to buyers MUST be treated as
  stream-closed; the buyer receives an incomplete stream.
- After restart, providers that reconnect MUST perform a fresh v2 auth
  handshake and key exchange before any encrypted frames are processed.
- If the coordinator can emit a T2.B event before shutdown, it SHOULD log
  `T2.B coordinator_restart_session_invalidated` for each active encrypted
  session at INFO severity.

Sticky state loss on coordinator restart remains governed by SPEC-004 §2
(cold-routing after in-memory loss).  Pillar B key loss does not extend or
modify sticky TTL.

---

### M13 — Disclosure phase transitions and `tier2.phase` are incomplete

**Audit location:** §9.1, §9.2, §9.3, §13.2.

**What is wrong:** §13.2 introduces `tier2.phase: 0` but allowed values and
transition rules are not defined.  Phase 3 can be enabled independently.

**Required fix:** Replace the `tier2.phase` field in the §13.2 disclosure
object with a derived field computed from active pillar state.  The field MUST
be removed from coordinator.yaml config (it is not operator-settable).  Instead
add to §13.2:

`tier2.phase` in the disclosure response MUST be computed as follows:
- 0: no tier2 pillar is active (catalog_path empty, observe_enabled false, all
  require_* false, behavioral_safety_enabled false).
- 1: Pillar A is active (catalog_path non-empty or require_hash_verified true),
  and Pillars B/C are not.
- 2: Pillars B or C are active (require_encrypted_leg or require_attestation
  true, or encrypted/attested providers exist and observe_enabled true).
  Pillar A may or may not be active.
- 3: Pillar D is active (behavioral_safety_enabled true) regardless of B/C.
  If B/C are also active, phase is still 3.
- "mixed": Pillar D is active but Pillars B/C are not (operator deployed Phase 3
  independently before Phase 2).

Remove §11 `tier2.phase` config entry.  Add `phase` to §11.5 as computed/read-only.

---

### M14 — Tier-2 predicates are not re-applied on retry and failover

**Audit location:** §4.5.

**What is wrong:** The spec places Tier-2 predicates in the selection pipeline
but does not state that they apply on every subsequent provider choice
(preflight advancement, failover, retry).

**Required fix:** In §4.5, after the four-step pipeline, add:

Enabled Tier-2 predicates (hash verified, encrypted leg, attested) are
**eligibility filters**, not one-time initial-selection gates.  They MUST be
re-applied on every provider selection attempt:
- SPEC-002 preflight advancement (when the initially selected provider fails
  preflight),
- SPEC-002 F-4 failover (when the selected provider disconnects mid-request),
- SPEC-004 retry (when a sticky-preferred provider fails and class resolution
  selects an alternative),
- hard-pin validation (when a buyer-supplied pin is evaluated).

A provider that is ineligible under enabled Tier-2 predicates MUST be treated
as ineligible at each of these steps, not re-admitted because it was
previously considered.

---

### M15 — v2 auth_request example uses `max_concurrency: 2`

**Audit location:** §10.2.

**What is wrong:** The example uses max_concurrency 2.  Locked SPEC-001 v1.2.4
says the default advertised max_concurrency MUST be 1 for all RAM tiers until
parallel generation is validated.  A future SPEC-001 v2.0 BUILD session may
copy this example and regress Decision log Entry 24 / H-003.

**Required fix:** Change the §10.2 auth_request example to
`"max_concurrency": 1`.  Add an inline comment:
`// default: 1 per SPEC-001 v1.2.4 §FR-9; increase only after parallel-generation validation`

---

### M16 — AC-T2-5 default-preservation check is too narrow

**Audit location:** §14 AC-T2-5.

(This is resolved together with C1.  The AC-T2-5 expansion in C1 fix item 3
already covers this finding.  Confirm the expanded criterion includes all five
bullets listed in C1 item 3.  Mark M16 closed as part of the C1 fix.)

---

### M17 — TTFT anomaly AC conflicts with default minimum threshold

**Audit location:** §8.5, §11.1, AC-T2-21.

**What is wrong:** §11.1 defaults response_time_anomaly_min_ms to 10000.
AC-T2-21 tests a TTFT above 5000 ms with baseline 1000 ms and factor 5, but
5000 < 10000 so the threshold formula yields 10000 and the test would pass
5000 ms without firing.

**Required fix:** Update AC-T2-21 to specify its own test configuration that
overrides the default:

```
Given: behavioral_safety_enabled: true, response_time_anomaly_enabled: true,
       response_time_anomaly_factor: 5, response_time_anomaly_min_ms: 0,
       provider baseline model_load_time_ms: 1000.
When: a provider response has TTFT 5001 ms.
Then: T2.D response_time_anomaly is logged at WARN.
      The response is not rejected solely for TTFT.
```

Add a note: "response_time_anomaly_min_ms: 0 disables the minimum floor and
is suitable for acceptance testing.  Production deployments MAY set a higher
floor to reduce noise."

---

## MINOR fix

### m1 — Survivability section citation polish

**Audit location:** §2.1–§2.5.

**Required fix:**
- In §2.1–§2.4, add exact section citations for the Tier-1 mechanisms
  described.  Examples: cite "SPEC-006 §1.3" and "SPEC-006 §F-1.5" in the
  invariant headers; cite "SPEC-004 §4" for sticky map state in §2.4; cite
  "SPEC-002 §5" for preflight/disconnect behavior in §2.4.
- In §2.5, enumerate the conclusion bullets as explicit invariants:
  "(a) sticky keys remain gateway-derived and account-scoped,
   (b) sticky keys remain coordinator-internal,
   (c) sticky deletion remains authenticated and account-scoped,
   (d) sticky TTL remains coordinator-enforced."
  matching the letter labels used in §2.1–§2.4.

---

## QUESTION resolution

### q1 — Catalog trust model

**Audit location:** §5.2, §11.1, §16.

**Required resolution:** Add a §5.2.1 "Catalog key trust model" paragraph:

The `tier2.catalog_public_key` is an operator-supplied Ed25519 public key.
The trust model is:
- The key is pinned by the operator at deployment time (trust-on-first-config,
  not trust-on-first-use).
- No external certificate authority or revocation endpoint is required.
- Key rotation requires an operator-controlled restart with a new
  `catalog_public_key`.  The old key is no longer valid after restart.
- A compromised catalog key is in scope for operator rotation (by updating
  config and restarting) but out of scope for any automatic cryptographic
  mitigation in v0.1.
- Key format: Ed25519 public key, 32 bytes, encoded as base64url-unpadded.

Add §16 operator question 5: "Confirm that the operator-supplied trust-on-config
model for catalog_public_key is acceptable, or specify a distribution/CA-backed
alternative."

---

## Final pass instructions

After all targeted fixes above are applied:

1. Bump the version header to "0.2" and set the date to today.

2. Add a v0.2 change-log entry in the header that lists:
   "v0.2: Resolves audit findings C1, C2, M1-M17, m1, q1.  Adds §4.6 error
   table, §4.7 redaction rule, §6.5.2 response AAD, §6.7.1 decrypt-failure
   handling, §6.10 restart behavior, §8.6 flag precedence matrix, §10.1.1
   first-message dispatch, §11.5 config lifecycle table.  Adds tier2.observe_enabled
   to §11.  Expands AC-T2-5 and AC-T2-21.  Removes tier2.phase from config;
   makes phase a computed disclosure field.  No architectural changes."

3. Check all section cross-references updated to new section numbers.

4. Check §3 terms: add any new terms introduced (observe_enabled semantics,
   challenge_id definition, "pre-commit / post-commit" distinction).

5. Check the AC count.  New ACs for error codes (M2) and new sub-ACs may
   raise the count above 26.  Renumber and update §14 header accordingly.

6. Do NOT change SPEC-001, SPEC-002, SPEC-004, or SPEC-006.
   Do NOT add new features beyond the scope of the audit findings.
   Do NOT change the four-pillar architecture, phase order, survivability
   certificate, or any Tier-1 default-preservation rule.

=== END PROMPT ===
```
