# SPEC-015 — Verifiable inference receipts

**Version:** 0.1.3 (2026-06-22, round-3 audit fix pass — LOCK candidate)
**Depends on:** SPEC-001 v1.5, SPEC-002 v1.3.5, SPEC-005 v0.3, SPEC-006 v0.8.3, SPEC-008 v0.3, SPEC-011 v0.5, SPEC-013 v0.3

**Change log v0.1.3:**
- Round-3 codex audit fix pass against `specs/SPEC-015-audit.md`
  (round 3 = 0 CRITICAL, 1 MAJOR, 3 MINOR; verdict READY WITH FIX
  PASS). Findings resolved:
  - **M1 (residual streaming normative clauses):** §5.2, §5.3, §5.4
    streaming/cancellation paragraphs and §12 streaming rows are
    now explicitly informative forward-compatibility guidance for
    v0.2+; v0.1.x emits NO receipt on any streaming path
    (regardless of finish_reason). Buyer-disconnect post-completion
    on a non-streaming response continues to receive a receipt
    with normal `finish_reason=stop` semantics — that is not a
    streaming case.
  - **m1 (§8.1 "one new field"):** corrected to "two new fields"
    matching §1.3.
  - **m2 (AC-11 stale "control frame" wording):** rewritten to
    reference reconnect-based rotation acceptance.
  - **m3 (v0.1.1 labels in v0.1.2 prose):** replaced with v0.1.3
    where the clause describes the current contract; v0.1 / v0.1.1
    / v0.1.2 retained only inside changelog and historical-design
    discussion.

**Change log v0.1.2:**
- Round-2 codex audit fix pass against `specs/SPEC-015-audit.md`
  (4 CRITICAL, 4 MAJOR, 2 MINOR; verdict DESIGN ROUND NEEDED).
  Findings resolved:
  - **C1 (`X-MacProvider-Receipt-Pending` unauthorized 2nd X-MacProvider-*
    header):** The pending correlator header is REMOVED. v0.1.2 adds
    exactly ONE buyer-visible response header
    (`X-MacProvider-Receipt`) as the only SPEC-006 v0.9 candidate
    allowlist addition. §6.3 rewritten to be silent on the wire side
    for streaming.
  - **C2 (rotation control frame outside SPEC-001 candidate):**
    The `provider_receipt_public_key_rotate` WS control frame is
    REMOVED. v0.1.2 rotation is via reconnect: the binary closes the
    current WS, generates a fresh keypair, reconnects with the new
    `provider_receipt_public_key` in the existing v2 `auth_request`
    initial-stage frame. The coordinator infers rotation by
    comparing the new pubkey against the previously-known one for
    this `provider_id`. §7.5 rewritten; §7.5.1 (rotate frame schema)
    deleted.
  - **C3 (streaming deferral drifts from BUILD prompt):** v0.1.2
    explicitly narrows the SPEC-015 v0.1.x mission to
    **non-streaming responses only**. Streaming receipts are NOT in
    v0.1.x; they are v0.2+ scope with explicit READMe/mission
    truth-in-advertising guidance. The BUILD prompt's "MUST be
    present, but where" question is answered as "not present in
    v0.1.x; v0.2+ design". §1.1, §1.2, §6, §15 Q5 rewritten.
  - **C4 (contradictory retention MUST/SHOULD):** The §6.3 SHOULD
    permitting bounded server-side retention is REMOVED. v0.1.2
    pins server-side receipt-body persistence as PROHIBITED. A v0.2+
    streaming-receipt design will name its own retention contract
    or use buyer-held-only delivery.
  - **M1 (`/poolz` candidate field count):** §1.3 now explicitly
    names the two SPEC-002 v1.4 candidate fields:
    `receipt_pubkey` and `receipt_pubkey_prev`.
  - **M2 (AC-9 non-executable):** AC-9 dropped from the normative
    list; the byte-equivalence invariant moves to §5.5 informative.
    ACs renumbered 1–17.
  - **M3 (`model_id` verbatim + NFC):** `model_id` is now pinned as
    ASCII-only per SPEC-001 v1.5 §6.4 (which is already
    ASCII-oriented), so NFC normalization is a no-op for
    `model_id`. NFC normalization applies only to natural-language
    strings in messages/output. §3.1, §3.2, §4.2 wording aligned.
  - **M4 (rotation Keychain write race):** v0.1.2 rotation writes
    the new key to Keychain only AFTER coordinator acceptance via
    successful reconnect auth. If the reconnect fails, the binary
    keeps the previous key active. §7.5 rewritten.
  - **m1 (v0.1 changelog mentions SSE):** added a parenthetical
    note on the v0.1 change-log entry that v0.1.1+ supersedes the
    SSE delivery design.
  - **m2 (SPEC-011 §3.8 citation):** corrected to SPEC-011 v0.5
    R-3.8.3 drain semantics.

**Change log v0.1.1:**
- Round-1 codex audit fix pass against `specs/SPEC-015-audit.md`
  (3 CRITICAL, 8 MAJOR, 4 MINOR, 2 QUESTIONS). Findings resolved:
  - **C1 (streaming SDK incompat):** Streaming receipt delivery is
    deferred to v0.x pending a verified OpenAI-SDK-compatible
    encoding. v0.1.1 emits `X-MacProvider-Receipt` on non-streaming
    responses ONLY. Streaming responses are accompanied by a
    `X-MacProvider-Receipt-Pending: <request_id>` response header for
    forward compatibility; the receipt body itself is NOT included in
    the SSE stream in v0.1.1. §6.3 rewritten; §15 Q5 expanded.
  - **C2 (proof-stage auth_request scope):** `provider_receipt_public_key`
    is restricted to the SPEC-001 v1.5 §6.7.1 initial-stage frame
    only. The proof-stage echo is dropped. §7.2 rewritten.
  - **C3 (coordinator ALTER TABLE):** v0.1.1 no longer prescribes
    SPEC-002 storage mechanics. The coordinator MUST surface the
    pubkey on `/poolz` (SPEC-002 v1.4 candidate, unchanged); the
    durable-storage mechanism is named by the future BUILD spec, not
    pinned here. §7.3 and §13 rewritten.
  - **M1 / q2 (prompt-hash field coverage):** the prompt canonical
    object expands from 10 to 16 keys, adding `presence_penalty`,
    `frequency_penalty`, `logit_bias`, `logprobs`, `top_logprobs`,
    `n`. §4.2 updated.
  - **M2 (JCS reuse mismatch):** v0.1.1 names two required additive
    extensions to `RFC8785JCS.swift` — RFC 8785 §3.2.2.3 float
    handling and an explicit NFC normalization step on string inputs.
    §3.2 rewritten.
  - **M3 (grace window mixed time+count):** v0.1.1 uses a single
    7-day time-based grace window; the request-count threshold is
    dropped. §7.5.2, AC-12 updated.
  - **M4 (AC-R8 byte-identity impossible):** AC-8 now requires the
    streaming response carries a pending request_id correlator, not
    byte-identity. AC-9 unchanged on `output_hash`.
  - **M5 (Keychain race):** §7.1 now requires atomic insert-or-load
    on `errSecDuplicateItem`.
  - **M6 (audit event field-list contradiction):** §11 names exact
    four fields once.
  - **M7 (CLI name drift):** the manual rotation flag is now
    `macprovider rotate-key`, matching the BUILD prompt.
  - **M8 (README schema divergence not explained):** new §16.1
    compatibility table.
  - **m1 (RFC 8895):** corrected to WHATWG HTML SSE.
  - **m2 (AC numbering):** AC-R1..R18 → AC-1..18.
  - **m3 (model_id wording):** clarified case-insensitive match,
    verbatim storage.
  - **m4 (README line range):** corrected to 117–128.
  - **q1 (provider_id in tuple):** RESOLVED. Provider identity in
    the receipt is the pubkey itself; `provider_id` remains
    out-of-band via `/poolz`. Rationale added to §3.1.

**Change log v0.1 (historical; SSE delivery design + AC numbering
superseded by v0.1.1/v0.1.2):**
- Initial draft following the design rationale captured in §2.
- Defines the per-response signed receipt: a base64 ed25519 signature
  over a JCS-canonicalized seven-field tuple (`model_id`, `prompt_hash`,
  `output_hash`, `provider_pubkey`, `ttft_ms`, `tokens_out`, `unix_ts`).
- Specifies prompt and output canonicalization, the
  `X-MacProvider-Receipt` wire header for both non-streaming and SSE
  responses, the provider ed25519 keypair lifecycle (Keychain storage,
  publication on the v2 `auth_request` initial-stage frame, manual
  rotation with a grace window), and the v0.1 pubkey trust root
  (`/poolz`).
- Defers model-hash binding to SPEC-011's domain (v0.3+ in this SPEC),
  buyer verification CLI to v0.2, on-chain anchoring outside scope,
  request_id replay binding to Open Q2, and cross-segment route binding
  to Open Q3.
- Acceptance criteria AC-1 through AC-18 are deterministic and
  implementer-verifiable.

---

## 0. Operator-paste invocation block

```
Implement SPEC-015 v0.1. As you work, maintain a running
phase3-binary/implementation-notes.html and (when coordinator/gateway
work begins) phase4-coordinator/implementation-notes.html and
phase5-gateway/implementation-notes.html that capture anything I
should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Scope and mission

SPEC-015 defines **per-response signed receipts** for MacProvider
inference: a small, transport-attached, offline-verifiable proof that
binds the response a buyer received to the provider that produced it,
the prompt that requested it, and a small set of provider-reported
quality signals.

This is the v0.1 normative floor. It pins:

- The receipt tuple and its canonical encoding.
- The signature algorithm.
- The wire transport (HTTP response header on non-streaming
  responses only; streaming responses carry no v0.1.x receipt — see
  §6.3).
- The provider keypair lifecycle (generation, storage, publication,
  manual rotation).
- The v0.1 pubkey trust root.
- Behavior on receipt-issuance failure.

The `README.md` line 22 ("Every response will carry a signed receipt
binding (prompt, output, provider) — verifiable inference, without a
datacenter (planned, not yet implemented)") and the §"Roadmap"
schema block at `README.md:117-128` describe the product surface. As
of v0.1 LOCK, `grep -r receipt phase3-binary phase4-coordinator
phase5-gateway` returns zero implementation; this SPEC is the
contract that closes that gap.

### 1.1 In scope (v0.1.x)

v0.1.x covers **non-streaming chat completions only**. Streaming is
out of scope for v0.1.x; see §1.2 and §15 Q5 for the deferral.

- The receipt tuple and JCS canonical encoding.
- ed25519 signature algorithm and base64 encoding.
- Prompt canonicalization rules.
- Output canonicalization rules (for non-streaming responses; the
  byte-equivalence invariant in §5.5 is forward-compatibility
  guidance for the v0.2+ streaming design but is not testable in
  v0.1.x).
- Tool-call commitment inside `output_hash`.
- The `X-MacProvider-Receipt` HTTP response header value format.
- Receipt-emission preconditions and the explicit omission cases
  (non-streaming responses only).
- Provider keypair generation, macOS Keychain storage, and publication
  on the SPEC-001 v2 `auth_request` initial-stage frame via a new
  parser-optional `provider_receipt_public_key` field annotated as a
  SPEC-001 v1.6 candidate extension.
- Manual key rotation (`macprovider rotate-key`) performed via WS
  reconnect — no new control frames; the rotated pubkey is
  republished on the next `auth_request` initial-stage frame using
  the existing single-field SPEC-001 v1.6 candidate.
- Pubkey trust root: the coordinator's `/poolz` JSON gains exactly
  two per-provider fields: `receipt_pubkey` (current) and
  `receipt_pubkey_prev` (previous, populated for 7 days after
  rotation). This is the SPEC-002 v1.4 candidate annotation.
- Acceptance criteria implementers can mechanically verify.

### 1.2 Out of scope for v0.1.x

SPEC-015 v0.1.x does NOT specify:

- **Streaming chat completions.** Streaming `POST /v1/chat/completions`
  responses do NOT carry receipts in v0.1.x. The round-1 audit C1 + the
  round-2 audit C1/C3 surfaced that the OpenAI Python and JavaScript
  SDKs JSON-parse every non-`[DONE]` SSE `data:` payload and that
  v0.1's proposed terminal `event: receipt` block would raise on a
  base64 receipt string. v0.1.2 chose to narrow the v0.1.x mission
  to non-streaming receipts rather than introduce a second
  buyer-visible header (which would itself exceed the SPEC-006 v0.9
  candidate scope). Streaming receipts are v0.2+; the design space
  is summarized in §15 Q5. README and operator-facing copy MUST be
  honest that v0.1.x receipts only cover non-streaming requests.
- **Buyer verification CLI.** `macprovider verify <receipt.json>` is a
  separate work item tracked as v0.2. v0.1 issues receipts; v0.2
  verifies them. State of v0.2: not started; this SPEC will bump to
  v0.2 with the verifier surface once that work begins.
- **Model-hash binding.** Whether the receipt commits to which
  *weights* ran (sha256 of the loaded model) is SPEC-011's territory.
  SPEC-011 v0.5 §3.3.1 already specifies provider-reported
  `heartbeat.model_hash` (raw 64-character lowercase hex). Folding
  that into the receipt tuple — so a buyer can verify "which weights
  served me" — is deferred to SPEC-015 v0.3+ contingent on
  SPEC-011's catalog-signing posture (operator decision per
  `beta/DECISION_CRITERIA.md` Entry 80, Q3 tier-2 posture). v0.1
  binds *which name was requested* and *what content was produced*,
  not which weights served it.
- **On-chain anchoring.** Periodic Merkle roots of issued receipts
  posted anywhere durable (chain, AntFeed, ENS-published manifest) are
  gated on a Cluster D-tokens go/no-go decision the operator has not
  made. v0.1 says nothing about it.
- **Request-id binding for replay-style verification.** Whether the
  receipt commits to a `request_id` and where the buyer would obtain
  its expected `request_id` is unresolved. See §15 Q2.
- **Multi-segment route binding.** Once Cluster F sharding lands a
  single response may have multiple provider segments; receipt-per-
  segment vs receipt-per-response with embedded route list is
  unresolved. See §15 Q3. v0.1 assumes one provider per response.
- **TUF-style trust-root signing of `/poolz`.** v0.1 acknowledges the
  trust root is operator-mutable (the coordinator publishes the
  pubkey list); strengthening it is v0.3+. See §15 Q1.

### 1.3 Relationship to locked specs

SPEC-001 v1.5 remains the authoritative provider binary and provider
WebSocket protocol. SPEC-015 v0.1 **MUST NOT** edit SPEC-001 v1.5
text; it ANNOTATES one additive, parser-optional field
(`provider_receipt_public_key`) on the v2 `auth_request` initial-stage
frame, marked here as a SPEC-001 v1.6 candidate extension. Until that
candidate field lands in SPEC-001 the field MUST NOT appear on the
wire from a v1.5 binary; the receipt-issuing path on the provider
side is enabled only by a binary at SPEC-001 v1.6 or later. This
mirrors SPEC-008's SPEC-001 v2.0 annotation pattern.

SPEC-002 v1.3.5 remains the authoritative coordinator router spec.
SPEC-015 v0.1.x ANNOTATES exactly two additive, optional response
fields on each `/poolz` provider object — `receipt_pubkey` (current
pubkey) and `receipt_pubkey_prev` (previous pubkey populated only
during the 7-day rotation grace window) — marked here as a single
SPEC-002 v1.4 candidate annotation pair. SPEC-002 §7 surfaces
(`/poolz` shape, internal forwarding) are otherwise unchanged.

SPEC-005 v0.3 remains the authoritative billing/settlement spec.
SPEC-015 v0.1 reuses SPEC-005's effective completion-token accounting
unmodified: `tokens_out` in the receipt is the same `int64` value the
billing path uses for `effective_completion_tokens` per
SPEC-005 §4 derivation. SPEC-015 v0.1 MUST NOT change SPEC-005's
formula, refund matrix, or null-usage error treatment.

SPEC-006 v0.8.3 remains the authoritative gateway buyer-API spec.
SPEC-015 v0.1 adds one buyer-visible response header
(`X-MacProvider-Receipt`) and registers it on the SPEC-006 §17
response-pass-through allowlist as a SPEC-006 v0.9 candidate
extension. SPEC-006 §17 header-strip rules (the gateway strips any
non-allowlisted `X-MacProvider-*` response header) otherwise apply
unchanged. The OpenAI SDK drop-in contract is preserved: the receipt
header is additive metadata; absence does not break SDK clients;
presence does not violate any OpenAI shape because OpenAI clients
ignore unknown response headers.

SPEC-008 v0.3 remains the authoritative Tier-2 trust layer. SPEC-015
v0.1 is orthogonal to SPEC-008. Specifically:

- Receipt issuance is independent of Pillar A model-hash verification
  (SPEC-008 §5.3). A receipt issued under v0.1 makes no claim about
  weight identity; SPEC-008 Pillar A makes that claim separately at
  admission and routing time.
- Receipt issuance is independent of Pillar B encrypted-leg AEAD
  (SPEC-008 §6). The receipt is computed over the cleartext request
  and response as observed at the provider; if the provider-leg is
  later AEAD-encrypted per Pillar B, the receipt is still computed
  over the same plaintext at the provider boundary before encryption.
- Receipt issuance is independent of Pillar C attestation. v0.1's
  trust root for the provider receipt pubkey is `/poolz`. If Pillar C
  is enabled, the attestation token does NOT bind the receipt key;
  v0.3+ MAY re-anchor receipt pubkeys to Pillar C attestations.
- Receipt field names MUST NOT collide with SPEC-008 wire fields.
  This SPEC uses `provider_receipt_public_key` to distinguish from
  SPEC-008 `provider_ecdh_public_key` (`auth_request` initial-stage
  per SPEC-001 v1.5 §6.7.1).

SPEC-011 v0.5 remains the authoritative warm-swap spec. Receipt
issuance MUST observe a model swap: a receipt MUST NOT be emitted for
a response whose model load changed mid-response (SPEC-011 v0.5
R-3.8.3 drain semantics already prevent this, but §7.4 below makes
the invariant explicit on the receipt side).

SPEC-013 v0.3 remains the authoritative `autotune` CLI subcommand
spec. SPEC-015 v0.1 reuses
`phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` (added by
SPEC-013) for canonical encoding; no parallel canonicalizer is
permitted.

### 1.4 North-star requirement

A buyer who has fetched a provider's receipt pubkey from `/poolz` MUST
be able to verify, offline, that:

1. The response they hold came from a provider holding that pubkey,
2. The response was bound to a prompt they can canonicalize and hash
   themselves to compare against `prompt_hash`,
3. The output they hold canonicalizes to a digest matching
   `output_hash`,
4. The provider-reported `ttft_ms`, `tokens_out`, and `unix_ts` are
   committed to the signed tuple and cannot be silently revised after
   the fact.

If any of (1)–(4) fails for a verifier that follows §3 canonicalization
correctly, the receipt is invalid and the verifier MUST reject it.

A buyer who does NOT trust `/poolz` (operator-mutable list) MUST
explicitly acknowledge that the v0.1 trust root is the coordinator
operator. v0.3+ stronger roots are §15 Q1.

---

## 2. Design rationale (informative)

The "verifiable inference" tag in the README is the central
differentiator from operator-trusted inference networks. The bar is
not academic ZK-verifiable inference (covered in
`doc/internal/zk-verifiable-inference-design.md` as exploratory) — it
is the minimum mechanism that lets a buyer prove a specific provider
served a specific prompt-output pair.

v0.1's design choices and their justifications:

- **ed25519 over JCS-canonical JSON.** ed25519 keys are small (32-byte
  pubkey, 64-byte signature), signing is fast (~50 µs on Apple Silicon),
  and the algorithm is widely implemented. JCS (RFC 8785) gives an
  unambiguous canonical form for JSON that survives field-order
  permutations and floating-point representation; the in-house Swift
  implementation at
  `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` is
  battle-tested by SPEC-013.
- **Seven-field tuple.** The set was chosen to cover the four
  buyer-observable claims (model name, prompt content, output content,
  provider identity) plus three provider-reported quality signals
  (ttft, output token count, timestamp). It deliberately does NOT
  cover model-hash, request-id, or route — those are scoped to
  v0.3+, v0.2 verification, and Open Q3 respectively.
- **Response header transport.** A header is the lowest-friction
  surface that OpenAI clients tolerate unchanged. Body inclusion was
  rejected: it would force every buyer SDK to learn a new response
  shape and would break OpenAI SDK drop-in (SPEC-006 §C.1).
- **Streaming receipts deferred to v0.2+.** Two rejected designs
  (v0.1 terminal `event: receipt` SSE block and v0.1.1
  `X-MacProvider-Receipt-Pending` correlator header) demonstrated
  that an SDK-compatible streaming receipt transport needs its own
  design pass. v0.1.x explicitly carries no receipt on streaming
  responses; v0.2+ will design the streaming transport. See §6.3
  and §15 Q5.
- **Manual rotation with a time-based grace window.** Auto-rotation
  has operational hazards (key churn, in-flight verification
  failures); v0.1.1 defers it. Manual rotation is a CLI flag; the
  coordinator retains the previous pubkey for **7 days** after the
  new one is published, so receipts that left the provider under
  the old key remain verifiable while a buyer is still polling
  `/poolz`. The v0.1 draft mixed a time threshold with a
  request-count threshold; the round-1 audit M3 flagged the mix as
  unimplementable without a counter contract; v0.1.1 uses time
  only.

---

## 3. Receipt content and canonical encoding

### 3.1 The receipt tuple

Every receipt is a JCS-canonicalized JSON object with EXACTLY the
following seven fields and no others:

| Field | Type | Definition |
|---|---|---|
| `model_id` | string | The buyer-requested model identifier. SPEC-001 v1.5 §6.4 model identifiers are ASCII-only and matched case-insensitively; v0.1.3 inherits this and requires `model_id` strings in the tuple to be ASCII-only. The receipt stores the original buyer-submitted `model` string verbatim (no case-fold). Because the string is ASCII-only, the §3.2 NFC normalization step is a no-op on this field; conformant verifiers MUST reject any receipt whose `model_id` contains a non-ASCII byte. |
| `prompt_hash` | string | Lowercase hex sha256 of the JCS-canonical encoding of the canonical prompt object defined in §4. 64 lowercase hex characters, no `sha256:` prefix. |
| `output_hash` | string | Lowercase hex sha256 of the JCS-canonical encoding of the canonical output object defined in §5. 64 lowercase hex characters, no `sha256:` prefix. |
| `provider_pubkey` | string | Base64 (standard, padded, no URL-safe substitution) of the provider's 32-byte ed25519 public key. Exactly 44 ASCII characters. |
| `ttft_ms` | int64 | Time-to-first-token in milliseconds, measured at the provider from request-accepted to first-output-byte-emitted. Non-negative. For non-streaming responses, this is the full generation latency. |
| `tokens_out` | int64 | Provider-reported output token count, the same `int64` value SPEC-005 §4 names `effective_completion_tokens`. Non-negative. See §7.6 for null-usage and error cases. |
| `unix_ts` | int64 | Provider's response-completion timestamp, Unix seconds UTC. Non-negative. Provider clock; see §15 Q4 for cross-check semantics. |

**Field omissions and extras.** A receipt object MUST contain
EXACTLY these seven keys. Verifiers MUST reject receipts with missing
or extra keys. There are no optional fields in v0.1.

**Why `provider_id` is NOT in the tuple (resolves audit q1).** The
buyer's cryptographic root of trust in the receipt is the
`provider_pubkey` field. The human/operator-facing `provider_id`
ULID is the coordinator's mutable label for that pubkey in `/poolz`
(§8). v0.1's design choice is to bind only the pubkey because:

1. The pubkey is the unforgeable identity for verification — a buyer
   who has fetched `(provider_id, receipt_pubkey)` from `/poolz`
   already trusts that mapping or does not.
2. Including `provider_id` would double-bind to an operator-mutable
   label without strengthening the cryptographic claim.
3. If `/poolz` later strengthens to a TUF-style signed root (§15 Q1),
   the trust upgrade lands on the `/poolz` side without re-signing
   historical receipts.

A v0.x+ MAY revisit this if §15 Q1 trust-root strengthening lands and
the operator wants the receipt to commit to a stable opaque
identifier independent of the pubkey.

**Types.** `model_id`, `prompt_hash`, `output_hash`, and
`provider_pubkey` are JSON strings. `ttft_ms`, `tokens_out`, and
`unix_ts` are JSON numbers that fit in int64. Implementations MUST
serialize them as JSON integers (no decimal point, no exponent) and
verifiers MUST reject any non-integer numeric encoding. JCS already
constrains numeric formatting to a canonical decimal representation;
v0.1 forbids fractional or exponential numerics for these three
fields explicitly.

### 3.2 Canonical encoding for signing

Let `T` be the receipt tuple object. The signing input MUST be
`JCS(T)` as defined by RFC 8785, with the additive profile pinned
below. The implementation reuses
`phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` and MUST
extend it with two clearly-named additions:

1. **Object key order:** UTF-16 code-unit lexicographic, per
   RFC 8785 §3.2.3. Already implemented at
   `RFC8785JCS.swift:44-46`.
2. **String escape rules:** RFC 8785 §3.2.2.5. Already implemented
   at `RFC8785JCS.swift:48-75` for U+0000–U+001F, `"`, `\\`, and
   U+FFFD.
3. **NEW (extension required for v0.1.3): NFC normalization on
   natural-language strings.** Every JSON string value entering the
   canonical form that may contain non-ASCII bytes — specifically,
   prompt/output canonical-object string fields per §§4–5 — MUST be
   Unicode-normalized to NFC (Unicode 15.1) BEFORE escape.
   Implementations MUST extend `RFC8785JCS.swift` with a pre-escape
   NFC step using `String.precomposedStringWithCanonicalMapping`.
   Pre-normalized inputs (already NFC) are a no-op. Tuple-level
   string fields (`model_id`, `prompt_hash`, `output_hash`,
   `provider_pubkey`) are ASCII-only by their respective field
   definitions (§3.1), so NFC is a no-op on those fields by
   construction.
4. **NEW (extension required for v0.1.3): JSON number handling for
   floats.** RFC 8785 §3.2.2.3 specifies the canonical decimal
   representation for JSON numbers including IEEE 754 doubles.
   `RFC8785JCS.swift` v1 supports only `int`; v0.1.3 receipt
   implementations MUST extend `RFC8785JCS.swift`'s `Value` enum
   with a `double(Double)` case implementing RFC 8785 §3.2.2.3 (the
   ECMAScript `Number.prototype.toString` derived format). The
   prompt canonical object (§4) contains `temperature`, `top_p`,
   `presence_penalty`, `frequency_penalty` as floats and is the
   driver for this extension.
5. No whitespace, no insignificant separators, no trailing newline.

The signing input is the UTF-8 bytes of `JCS(T)`.

The receipt tuple itself (§3.1) contains only strings and integers,
so the receipt SIGNING step itself does not exercise the float
extension. Floats appear in the §4 prompt canonical object that
feeds `prompt_hash`. Both extensions are MANDATORY for a v0.1.3
conformant provider implementation; an implementation lacking either
MUST NOT emit receipts.

### 3.3 Signature

`SIG = ed25519_sign(provider_receipt_private_key, UTF-8(JCS(T)))`.

`SIG` is exactly 64 bytes. The on-wire encoding is base64 (standard,
padded; no URL-safe substitution) — exactly 88 ASCII characters.

### 3.4 Receipt object on the wire

The full receipt artifact transmitted on the wire is the
JCS-canonical tuple plus the signature. The `X-MacProvider-Receipt`
header value MUST be:

```
<base64(JCS(T))>.<base64(SIG)>
```

That is: standard padded base64 of the UTF-8 bytes of `JCS(T)`,
then a literal ASCII period (`0x2E`), then standard padded base64
of the 64-byte signature. No whitespace, no other delimiters, no
trailing characters.

The two base64 segments are independently decodable so a verifier
can reconstruct `JCS(T)` and check `ed25519_verify(provider_pubkey,
JCS(T), SIG)`. This format was chosen over JWS (compact serialization)
because v0.1 does not need a header (no algorithm agility, no key id
indirection — `provider_pubkey` is in the payload). A v0.x+ may
migrate to JWS once algorithm agility is needed; that migration is
NOT part of v0.1.

**Maximum size.** `JCS(T)` is bounded by the field sizes:
`model_id` ≤ 256 bytes (SPEC-001 v1.5 model-id constraint),
`prompt_hash`/`output_hash` = 64 hex chars each, `provider_pubkey` =
44 chars, three int64 numerals ≤ 20 chars each. With JSON
overhead, `JCS(T)` ≤ 600 bytes; base64 expands by 4/3, so the header
value is ≤ ~830 ASCII bytes. Implementations MUST permit a
generous `X-MacProvider-Receipt` header up to 4096 bytes to leave
headroom for v0.2+ field additions and to avoid edge-case nginx
truncation.

---

## 4. Prompt canonicalization

The `prompt_hash` field commits to the buyer's request. The
canonicalization rule MUST be deterministic across implementations so
a verifier with the same request body produces the same hash.

### 4.1 Source of the prompt

The provider canonicalizes the **request body it received** at the
point of inference, NOT the buyer's original HTTP body. For the v0.1
single-provider routing case (one provider per response, see §1.2)
the gateway-to-coordinator-to-provider forwarding preserves the
relevant fields byte-for-byte; see §4.5 for the normative subset.

### 4.2 The canonical prompt object

The provider MUST construct the canonical prompt object as follows:

```
{
  "model": <request.model>,                          // verbatim string
  "messages": [<canonical_message>, ...],            // see §4.3
  "tools": [<canonical_tool>, ...] | null,           // see §4.4
  "temperature": <float|null>,
  "top_p": <float|null>,
  "max_tokens": <int|null>,
  "stop": <string|array<string>|null>,
  "seed": <int|null>,
  "response_format": <object|null>,
  "tool_choice": <string|object|null>,
  "presence_penalty": <float|null>,
  "frequency_penalty": <float|null>,
  "logit_bias": <object|null>,
  "logprobs": <bool|null>,
  "top_logprobs": <int|null>,
  "n": <int|null>
}
```

A field that is absent from the request body MUST be encoded as JSON
`null` in the canonical prompt object. The object MUST contain
EXACTLY these sixteen keys; no other request fields enter
`prompt_hash` in v0.1.

The sixteen keys are the union of OpenAI chat-completion fields the
provider observes and that materially affect the output distribution
or the response shape. The audit-driven expansion from v0.1's
ten-key list closed the "weak prompt binding" gap surfaced in the
round-1 audit M1: `presence_penalty`, `frequency_penalty`,
`logit_bias`, `logprobs`, `top_logprobs`, and `n` were missing in
v0.1 and could have let two responses differ on sampling while their
receipts hashed identical prompts.

Implementations MUST NOT include OpenAI fields outside this list
(`user`, `stream`, `stream_options`, `store`, `metadata`,
`function_call`, `functions`, etc.) even if the buyer sent them.
v0.1.3 deliberately excludes fields that are non-deterministic on
the provider side (`stream`, `stream_options`) or operationally
noisy (`user`, `metadata`), and excludes legacy aliases
(`function_call`, `functions`) in favor of `tools` and
`tool_choice`. A v0.2+ may widen the subset; verifiers built against
v0.1.3 MUST hash exactly these sixteen keys.

### 4.3 Canonical message object

Each message in `messages` MUST canonicalize to:

```
{
  "role": <string>,                                  // "system" | "user" | "assistant" | "tool"
  "content": <canonical_content>,                    // string or array; see §4.3.1
  "name": <string|null>,
  "tool_call_id": <string|null>,                     // for role:"tool" messages
  "tool_calls": [<canonical_tool_call>, ...] | null  // for role:"assistant" with tool calls
}
```

Each message MUST contain EXACTLY these five keys; fields absent from
the buyer-supplied message are encoded as JSON `null`.

#### 4.3.1 Canonical content

`content` is one of:

- A JSON string (the common case for text-only messages). The string
  MUST be Unicode-normalized to NFC (Unicode 15.1 stabilization). A
  request that contains pre-NFC content (decomposed sequences,
  legacy escapes) is normalized at the provider before hashing.
- A JSON array of content parts, used for OpenAI multimodal-style
  messages. Each part MUST canonicalize to one of:
  - `{"type":"text","text":<nfc-string>}`
  - `{"type":"image_url","image_url":{"url":<string>,"detail":<string|null>}}`
  - `{"type":"input_audio","input_audio":{"data":<string>,"format":<string>}}`
  Each part object MUST contain EXACTLY the keys named for its type.

If the buyer sent `content: null` (legacy OpenAI shape for
assistant tool-call messages), the canonical form is JSON `null`.

#### 4.3.2 Newline and whitespace handling

Within a content string:

- `\r\n` and bare `\r` MUST be normalized to `\n` before NFC.
- Trailing whitespace MUST NOT be stripped. Some prompts legitimately
  end with whitespace and a strip would silently change `prompt_hash`.
- Leading whitespace MUST NOT be stripped, same reason.
- Internal whitespace runs MUST NOT be collapsed.

### 4.4 Canonical tool object

Each tool in `tools` MUST canonicalize to:

```
{
  "type": "function",
  "function": {
    "name": <string>,
    "description": <string|null>,
    "parameters": <json-schema-object|null>
  }
}
```

`parameters` is a JSON Schema object as supplied; JCS canonicalizes
the object recursively. v0.1 does NOT reorder or normalize the
schema beyond JCS's standard sort.

### 4.5 The provider-observed request body

The §4.1–§4.4 fields MUST be passed end-to-end from buyer to provider
without modification. SPEC-006 v0.8.3 §17 already enforces this for
the OpenAI request body (gateway forwards the body verbatim);
SPEC-002 v1.3.5 §5 already enforces it on the coordinator. Receipts
issued under v0.1 inherit this invariant. If a future gateway or
coordinator change rewrites any of the §4.2 fields between buyer and
provider (e.g. coercing `temperature` defaults), receipts will fail
verification against the buyer's raw body — this is a deliberate
detection mechanism, not a bug.

---

## 5. Output canonicalization

The `output_hash` field commits to the output the provider produced.

### 5.1 The canonical output object

The provider MUST construct the canonical output object as follows:

```
{
  "content": <nfc-string>,                           // see §5.2
  "tool_calls": [<canonical_tool_call>, ...] | null, // see §5.3
  "finish_reason": <string>                          // v0.1.x non-streaming: "stop" | "length" | "tool_calls" | "content_filter" | "error" (v0.2+ streaming may add "cancelled")
}
```

The object MUST contain EXACTLY these three keys.

### 5.2 `content`

- For non-streaming responses (the only receipt-bearing path in
  v0.1.x): the full `choices[0].message.content` string as the
  provider produced it, NFC-normalized.
- For responses where the assistant message contains ONLY tool calls
  (no text content), `content` is the JSON empty string `""`.
- For responses with no content emitted at all (e.g., immediate
  error after token allocation), see §5.4.

*Informative forward-compatibility note (v0.2+):* a future
streaming receipt design will need to canonicalize the concatenated
`choices[0].delta.content` chunks. NFC normalization across chunk
boundaries is not associative, so a future v0.2+ design MUST NFC-
normalize the concatenated result once at end-of-stream, not
per-chunk. This guidance is not testable in v0.1.x and binds only
the v0.2+ streaming design.

`\r\n` → `\n` and bare `\r` → `\n` apply, identical to §4.3.2.
No whitespace stripping.

### 5.3 `tool_calls`

If the assistant emitted one or more tool calls, the receipt commits
to all of them inside `output_hash`, not as a separate field. Each
tool call MUST canonicalize to:

```
{
  "id": <string>,
  "type": "function",
  "function": {
    "name": <string>,
    "arguments": <string>      // the JSON-stringified argument blob the assistant emitted, byte-for-byte
  }
}
```

For non-streaming responses in v0.1.x, a single completed tool call
MUST appear with its full `arguments` string. Tool calls MUST appear
in `tool_calls` in the emission order the assistant produced them.

*Informative forward-compatibility note (v0.2+):* the OpenAI SSE
shape emits `choices[0].delta.tool_calls[].function.arguments` as a
partial string across many chunks. A v0.2+ streaming receipt design
MUST concatenate those deltas in emission order to match the
non-streaming `arguments` byte-for-byte. Not testable in v0.1.x.

The `arguments` field is a string, NOT a parsed JSON object. v0.1
deliberately commits to the byte-exact string the assistant emitted
so a verifier can rebuild it from streaming chunks without parsing
hazards. A v0.x+ may add a parsed-object commitment alongside, but
v0.1's `output_hash` covers the string form only.

### 5.4 `finish_reason`

`finish_reason` is the same value SPEC-005 §3 maps to billing
treatment. For v0.1.x non-streaming receipts, `finish_reason` is one
of `"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`, or
`"error"`. When the provider returns SPEC-001 null-usage error
classes (`error_model_not_loaded`, `error_context_exceeded`,
`error_queue_full`, `error_internal`), `finish_reason` MUST be
`"error"` and `content` is the empty string. See §7.6 for the
emission rule in this case.

*Informative forward-compatibility note (v0.2+):* the OpenAI SDKs
treat a buyer disconnect on a streaming response as
`finish_reason="cancelled"`. v0.1.x streaming requests carry no
receipt regardless of `finish_reason`; a v0.2+ design that emits
streaming receipts will need to canonicalize the cancelled case.

### 5.5 The `output_hash` invariant (informative; forward-compat)

v0.1.x receipts cover non-streaming responses only (§6.3). The
canonical output object defined in §5.1–§5.3 is therefore exercised
only by non-streaming output.

For forward compatibility with v0.2+ streaming receipts: when a
v0.2+ design adds streaming receipts, identical output bytes
emitted in streaming and non-streaming modes MUST hash to the same
`output_hash`. v0.1.x §5.2's "concatenated output" guidance is
preserved to support that future invariant; in v0.1.x it has no
testable consequence and is informative.

---

## 6. Wire transport

### 6.1 Header name

The receipt is delivered in the HTTP response as:

```
X-MacProvider-Receipt: <base64(JCS(T))>.<base64(SIG)>
```

The header name `X-MacProvider-Receipt` is NEW in SPEC-015 v0.1.
SPEC-006 v0.8.3 §17 lists `X-MacProvider-Provider`,
`X-MacProvider-Route`, `X-MacProvider-Session`,
`X-MacProvider-Conversation`, `X-MacProvider-Internal-Conv`,
`X-MacProvider-Pref`, `X-MacProvider-Retry`. `X-MacProvider-Receipt`
does not collide. SPEC-006 v0.9 (candidate, deferred to SPEC-015 v0.1
+ SPEC-006 v0.9 absorption) MUST add `X-MacProvider-Receipt` to the
buyer-facing response-pass-through allowlist so the gateway does not
strip it on the buyer hop.

### 6.2 Non-streaming responses

For a non-streaming `POST /v1/chat/completions` (request body
`stream: false` or absent), the provider MUST emit
`X-MacProvider-Receipt` on the inference response. The header value
is set BEFORE the response body is written. The header is forwarded
by coordinator and gateway untouched.

### 6.3 Streaming responses (out of scope in v0.1.x)

v0.1.x DOES NOT issue receipts for streaming
`POST /v1/chat/completions` responses. Provider, coordinator, and
gateway MUST treat a streaming request as receipt-free: no
`X-MacProvider-Receipt` header is emitted; no SSE event is added;
no `data:` payload is altered. The SSE stream's wire shape is
exactly what SPEC-001 v1.5 and SPEC-006 v0.8.3 already specify.

This is a deliberate v0.1.x scope narrowing in response to round-1
audit C1 and round-2 audit C1/C3. Both rounds established that:

- The v0.1 plan to emit a terminal `event: receipt` SSE block is
  incompatible with the OpenAI Python and JavaScript SDKs' stream
  loops (Python: `openai/_streaming.py`; JavaScript:
  `openai-node/streaming.ts`).
- The v0.1.1 plan to emit an `X-MacProvider-Receipt-Pending`
  correlator header introduces a second buyer-visible
  `X-MacProvider-*` response header that exceeds the single-field
  SPEC-006 v0.9 candidate allowlist annotation.
- Embedding the receipt as an extra field on the final
  chat-completion chunk is unverified across SDK versions and
  needs its own SDK-compatibility study.

v0.2+ will design a streaming receipt transport with an
SDK-compatibility ACs. Until then, README and operator-facing copy
MUST disclose that v0.1.x receipts cover non-streaming responses
only. A buyer who needs receipts for streaming traffic in v0.1.x
has two options:

1. Issue the same request non-streaming and verify against a
   pinned `seed` (idempotent if the model is deterministic).
2. Wait for v0.2+ streaming receipt body delivery.

§15 Q5 is the open design question for streaming receipts.

### 6.4 Omission cases

For non-streaming responses, the receipt MUST be omitted (no
`X-MacProvider-Receipt` header) in the following cases:

1. The provider's receipt keypair has not yet been generated (first
   launch before Keychain setup completes). See §7.1.
2. The buyer disconnected before any token was emitted AND the
   provider has no committed `tokens_out` value (`tokens_out: 0` is
   committable; see §7.6).
3. The response was served by a SPEC-001 binary at version `< v1.6`
   (no `provider_receipt_public_key` published).
4. The model swap mid-response invariant is violated (see §7.4) — the
   provider MUST close the response with a 500-class error and MUST
   NOT emit a receipt.
5. The request was streaming. v0.1.x emits no receipts for streaming
   responses (§6.3).

When a receipt is omitted, the provider MUST NOT emit a placeholder,
empty value, or `X-MacProvider-Receipt: omitted` sentinel. Header
absence is the signal.

---

## 7. Provider keypair lifecycle

### 7.1 Generation

On first launch of `phase3-binary serve` at SPEC-001 v1.6 or later,
the binary MUST perform an atomic insert-or-load against macOS
Keychain to obtain its receipt private key:

1. Construct the Keychain query with:
   - `kSecClass = kSecClassGenericPassword`
   - `kSecAttrService = "com.streamvc.macprovider.receipt-key"`
   - `kSecAttrAccount = <provider_id>`
   - `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
   - `kSecAttrSynchronizable = false`
2. Attempt `SecItemCopyMatching` with that query. If a record is
   present, decode the 32-byte raw private key from `kSecValueData`
   and skip to step 5.
3. If `SecItemCopyMatching` returns `errSecItemNotFound`, generate a
   fresh ed25519 keypair using
   `CryptoKit.Curve25519.Signing.PrivateKey.init()` and call
   `SecItemAdd` with the query plus
   `kSecValueData = privateKey.rawRepresentation`.
4. If `SecItemAdd` returns `errSecDuplicateItem`, another `serve`
   process won the race: discard the just-generated keypair, repeat
   step 2 to load the winning private key, then proceed. The binary
   MUST NOT cache the lost candidate.
5. Cache the loaded private key for the lifetime of the `serve`
   process. Refresh from Keychain on `SIGHUP` or process restart.

The atomic insert-or-load above closes the round-1 audit M5 race:
two simultaneous `serve` launches with the same `provider_id` MUST
converge to a single private key (the first SecItemAdd wins; the
loser falls back to load).

The pubkey is derivable from the private key; the binary MUST NOT
store the pubkey separately. The Keychain item is per-`provider_id`
so reinstalling the binary with a different `provider_id` produces a
different keypair.

### 7.2 Publication on WS auth

On the next v2 `auth_request` initial-stage frame (SPEC-001 v1.5
§6.7.1, candidate extension SPEC-001 v1.6), the binary MUST add the
optional field:

```
"provider_receipt_public_key": "<base64-32-byte-ed25519-public-key>"
```

The field name is `provider_receipt_public_key` to mirror the
existing SPEC-008 `provider_ecdh_public_key` field and to make the
key purpose unambiguous. Encoding is standard padded base64 (44
ASCII characters).

The field MUST be parser-optional on the coordinator side (a
pre-v1.6 binary that does NOT carry the field MUST still admit
successfully; the coordinator MUST treat that provider as
non-receipt-issuing and the gateway MUST NOT emit
`X-MacProvider-Receipt` for responses routed through that provider).

**The proof-stage frame (SPEC-001 v1.5 §6.7.2) is NOT modified by
v0.1.1.** The round-1 audit C2 surfaced that the v0.1 plan to echo
`provider_receipt_public_key` on the proof-stage frame exceeds the
single-field SPEC-001 v1.6 candidate boundary; SPEC-001 v1.5 R-6.7.6
limits proof-stage byte-identity rules to `supported_models[]` and
`publishes_supported_models`. v0.1.1 restricts the candidate
annotation to the initial-stage frame ONLY. A future SPEC-015
revision that needs proof-stage echo MUST file it as a separate
SPEC-001 candidate with its own compatibility analysis.

### 7.3 Coordinator receipt-pubkey surface

The coordinator stores `provider_receipt_public_key` on the in-memory
provider struct alongside the existing `provider_ecdh_public_key`
storage (see `phase4-coordinator/internal/pool/provider.go`,
SPEC-008 v0.3 §5.5). The field MUST be exposed on `/poolz` per §8
below; that exposure (with `receipt_pubkey` and
`receipt_pubkey_prev`) is the SPEC-002 v1.4 candidate annotation
v0.1.3 pins.

**Persistence across restart is an implementation concern, not a
v0.1.3 normative requirement.** The round-1 audit C3 surfaced that
the v0.1 plan to mandate
`ALTER TABLE providers ADD COLUMN receipt_pubkey TEXT` exceeds the
`/poolz` SPEC-002 v1.4 candidate boundary AND prescribes a schema
(`providers` table) that does not exist in the locked SPEC-002
v1.3.5 surface. v0.1.3 deliberately scopes the SPEC-002 candidate
annotation to the `/poolz` shape change and defers the
durable-storage mechanism to the implementation BUILD spec
(`BUILD_SPEC_015_IMPL_*_PROMPT.md`, not yet written).

The implementation BUILD spec MAY choose any of:

- In-memory only on the coordinator: providers republish their
  pubkey on every reconnect, the coordinator never persists. This
  is acceptable because reconnect is the existing recovery path
  (SPEC-002 v1.3.5 §4 admission semantics).
- Durable in a new SPEC-002 candidate column on the existing
  `provider_tokens` or admission audit table, named as a separate
  SPEC-002 candidate annotation.
- Durable in a v0.x dedicated `receipt_pubkeys` table.

v0.1.3 ACs 10–11 verify the runtime surface (the pubkey is exposed
on `/poolz`, the rotation grace window behavior holds) without
asserting a specific storage mechanism.

### 7.4 Rotation under model swap

A receipt MUST commit to a single provider running a single set of
weights for the duration of the response. If a SPEC-011 v0.5 warm
swap is initiated mid-response, the in-flight response MUST drain
under the old `ModelRuntime` per SPEC-011 §3.8.4. The receipt is
emitted from the same `ModelRuntime` instance that produced the
output; no special handling is required for the receipt itself.

If a binary or coordinator bug causes a mid-response swap that
violates the drain invariant, the provider MUST close the response
with an HTTP 500 error envelope and MUST NOT emit a receipt. This is
a fail-closed default; the alternative (emit a receipt over partial
output) would silently weaken the binding.

### 7.5 Manual rotation (via reconnect)

v0.1.x defines manual rotation only. Auto-rotation is deferred to a
later version.

The binary MUST support the CLI flag:

```
macprovider rotate-key
```

Rotation is performed via WebSocket reconnect, NOT via a new control
frame. The round-2 audit C2 established that introducing a new
provider→coordinator WS frame would exceed the single-field
SPEC-001 v1.6 candidate annotation. The reconnect-based design
reuses the already-authorized initial-stage `auth_request` field.

When `macprovider rotate-key` is invoked:

1. The binary generates a fresh ed25519 keypair IN MEMORY ONLY. The
   new keypair is NOT yet written to Keychain.
2. The binary closes the current WS connection cleanly.
3. The binary opens a fresh WS connection and sends a v2
   `auth_request` initial-stage frame carrying the NEW
   `provider_receipt_public_key`.
4. If the coordinator accepts the auth and proof stages (returning
   `auth_response.accepted=true`), the binary atomically swaps
   Keychain:
   - Move the existing Keychain item at
     `(service=com.streamvc.macprovider.receipt-key,
       account=<provider_id>)` to
     `(service=com.streamvc.macprovider.receipt-key.prev,
       account=<provider_id>)`.
   - Add the new keypair at the original `(service, account)`.
   The `.prev` Keychain item is retained for a 7-day operator
   recovery window and is auto-deleted by the next `serve` launch
   that detects it older than 7 days.
5. If the reconnect fails (coordinator rejects auth, network down,
   timeout), the binary discards the in-memory new keypair, restores
   the WS connection using the OLD Keychain-resident key, and
   surfaces the rotation failure to the operator
   (`macprovider rotate-key` exits non-zero with a clear error
   message).
6. The coordinator infers rotation by comparing the new pubkey
   against the previously-known one for this `provider_id`. On
   detection:
   - The coordinator moves the prior pubkey to `receipt_pubkey_prev`
     with `rotated_at = now`.
   - Sets `receipt_pubkey` to the new value.
   - Updates `/poolz` accordingly (§8).
7. The binary signs all NEW receipts emitted after step 4 with the
   new private key. There is no in-flight rotation window for the
   PROVIDER side — by construction the old key is unreachable from
   the moment a new WS connection is established.

The previous-pubkey grace window described in §7.5.1 covers buyers
whose `/poolz` cache still points at the old key at rotation time.

#### 7.5.1 Grace window semantics

During the grace window, the coordinator's `/poolz` response carries
both pubkeys:

```
"receipt_pubkey": "<new-base64>",
"receipt_pubkey_prev": {
  "pubkey": "<old-base64>",
  "rotated_at": <unix-seconds>,
  "expires_at": <unix-seconds>
}
```

`expires_at` is `rotated_at + 7 * 86400`. After expiration the
coordinator removes the `receipt_pubkey_prev` block. v0.2 verifiers
MUST accept receipts signed under either `receipt_pubkey` or
`receipt_pubkey_prev` during the grace window.

The grace window is time-only in v0.1.3. A v0.x+ may add a
request-count-bounded short-circuit (e.g. "after the rotated
provider has signed 10000 receipts under the new key, the previous
key MAY be retired early"), but that requires a counter contract
v0.1.3 deliberately does not pin.

### 7.6 Null-usage / error receipts

When the provider returns a SPEC-001 null-usage error
(`error_model_not_loaded`, `error_context_exceeded`,
`error_queue_full`, `error_internal`) per SPEC-005 v0.3 §3 X-1 row:

- `tokens_out` MUST be `0`.
- `output_hash` MUST be the sha256 hex of the canonical output object
  with `content=""`, `tool_calls=null`, `finish_reason="error"`.
- `ttft_ms` MUST be the elapsed milliseconds from request-accepted
  to error-emitted (i.e. the "time to error", which is
  observationally useful for the buyer).
- `unix_ts` is set normally.

The receipt is emitted. This is deliberate: the buyer paying zero
under SPEC-005 X-1 still gets a signed acknowledgement that the
provider was reached and produced an error response. This closes a
SPEC-006 v0.8.2 ambiguity: the v0.8.2 X-1 row debited the buyer
zero quota but said nothing about whether the buyer learned what
the provider did.

If the provider was never reached (gateway-internal failure,
coordinator preflight rejection, no provider available), no receipt
is emitted because there is no provider to sign one. The error
envelope SPEC-006 §H normalizes the response shape; the absence of
`X-MacProvider-Receipt` distinguishes "provider never ran this" from
"provider ran and errored".

---

## 8. Pubkey trust root

### 8.1 v0.1 trust root: `/poolz`

Buyers retrieve the provider receipt pubkey from the coordinator's
`/poolz` endpoint (SPEC-002 v1.3.5 §7). v0.1.x ANNOTATES two new fields
per provider object, marked as SPEC-002 v1.4 candidate:

```
{
  "provider_id": "p_01HK4Z3VYE...",
  "state": "ready",
  "model": "...",
  ...
  "receipt_pubkey": "<base64-32-byte-ed25519>" | null,
  "receipt_pubkey_prev": null | { "pubkey": "...", "rotated_at": ..., "expires_at": ... }
}
```

`receipt_pubkey` is `null` for providers whose binary is at SPEC-001
< v1.6 (no key published). Such providers MUST NOT have
`X-MacProvider-Receipt` headers on responses they serve; the gateway
MUST omit the header if the upstream coordinator's chosen provider
has `receipt_pubkey: null`.

`receipt_pubkey_prev` is `null` outside the rotation grace window.

### 8.2 Buyer fetch ergonomics

Buyers SHOULD cache `/poolz` responses for short windows (≤ 60
seconds) to avoid hammering the endpoint on every verification.
SPEC-002 v1.3.5 already permits `/poolz` caching at this cadence per
§7.4.

### 8.3 Operator-mutability and the limits of v0.1's trust root

The coordinator operator can rewrite `/poolz` at any time; v0.1's
trust root is therefore "the coordinator operator does not lie about
which pubkey corresponds to which provider". This is consistent with
the rest of the MacProvider Tier-1 trust posture (SPEC-006 v0.8.3
§1.6) and is acknowledged in the README:

> Buyer prompts and provider responses are processed as plaintext on
> provider hardware … This is acceptable for cooperative deployments
> where buyer and provider have an established trust relationship; it
> is NOT a private-inference guarantee.

A stronger trust root — TUF-style operator-signed `/poolz`, an
external anchor at AntFeed, or a Cluster D-token-anchored registry —
is §15 Q1 and explicitly out of scope for v0.1. Implementers
documenting v0.1 to buyers MUST be honest about this limit; v0.1
receipts protect against provider misbehavior, NOT against
coordinator-operator misbehavior.

### 8.4 Future migration off `/poolz`

When a v0.3+ stronger root lands, the wire format of receipts
(§3.4) MUST be unchanged. Only `provider_pubkey` source-of-truth
changes. This forward-compatibility commitment is binding on v0.1
implementers: do NOT bake `/poolz`-specific assumptions into the
verification path; the verifier takes a `provider_pubkey` argument
out-of-band and verifies against it.

---

## 9. Receipt emission timeline

For a non-streaming response:

```
t0: provider receives request from coordinator
t1: provider begins inference (load model, accept prompt)
t2: first output token emitted             → ttft_ms = (t2 - t1) / ms
t3: last output token emitted, finish_reason set, tokens_out known
t4: provider canonicalizes prompt object → prompt_hash
t5: provider canonicalizes output object → output_hash
t6: provider builds tuple T with unix_ts = floor(t3 / second)
t7: provider computes SIG = ed25519_sign(privkey, JCS(T))
t8: provider writes X-MacProvider-Receipt header
t9: provider writes response body
```

Streaming responses are out of scope in v0.1.x (§6.3); no receipt
is emitted, no header is added, and steps t4–t9 do not run on the
streaming path.

---

## 10. Verifier algorithm (informative; v0.2 normative)

A buyer with the receipt header value and the provider pubkey
(fetched from `/poolz`) verifies as follows:

```
1. Split the header value on the first '.' → (b64_tuple, b64_sig).
2. Decode JCS_T = base64_decode(b64_tuple).
3. Decode SIG = base64_decode(b64_sig). Reject if len(SIG) != 64.
4. Parse JCS_T as JSON to confirm well-formed and contains exactly
   the seven SPEC-015 §3.1 keys.
5. Check provider_pubkey matches the pubkey the buyer trusts.
6. ed25519_verify(provider_pubkey, JCS_T, SIG). Reject on failure.
7. Canonicalize the buyer's recorded request prompt per §4 →
   prompt_hash_local. Reject if != receipt.prompt_hash.
8. Canonicalize the buyer's recorded response output per §5 →
   output_hash_local. Reject if != receipt.output_hash.
9. (Optional) Check unix_ts is within an operator-set skew window
   from the buyer's record of when the response was received.
```

v0.1 informatively specifies this algorithm; v0.2 will ship a
normative `macprovider verify <receipt-json>` CLI that implements it
in tested code and updates the SPEC to v0.2-locked verifier
semantics.

---

## 11. Audit categories

The following audit categories are added (SPEC-006 v0.9 candidate
absorption; tracked locally for now):

- `receipt_issued`: emitted by the provider when a receipt is written
  to the response. Event-specific fields: `model_id`, `tokens_out`,
  `ttft_ms`, `unix_ts`. The audit-record envelope (`provider_id`,
  `request_id`, event timestamp) is inherited from the common
  SPEC-005 v0.3 §6 audit-sink envelope and MUST NOT be duplicated
  inside the event-specific block. Implementations MUST NOT log the
  receipt's `provider_pubkey`, `prompt_hash`, `output_hash`, or
  signature into the audit sink: the receipt is a buyer-held proof,
  not a server-side audit row.
- `receipt_omitted`: emitted by the provider/coordinator/gateway when
  a receipt is suppressed per §6.4. Fields: `provider_id`,
  `request_id`, `reason` (`pre_v1_6_binary` | `no_keypair` |
  `model_swap_violation` | `pre_token_cancel` | `streaming_request`).
- `receipt_rotation_detected`: emitted by the coordinator when a
  reconnecting provider's `auth_request.provider_receipt_public_key`
  differs from the previously-known pubkey for that `provider_id`.
  Fields: `provider_id`, `old_pubkey`, `new_pubkey`, `rotated_at`.
  This event replaces the v0.1/v0.1.1 `receipt_rotate_request` and
  `receipt_rotate_invalid` events, which are no longer emitted
  because v0.1.2 rotation is reconnect-based, not control-frame
  based.

`receipt_issued` is a high-cardinality event (one per response). Its
audit destination is the existing SPEC-005 v0.3 §6 billing audit
sink; the four event-specific scalar fields named above
(`model_id`, `tokens_out`, `ttft_ms`, `unix_ts`) plus the inherited
audit envelope are the complete v0.1.3 audit shape.

---

## 12. Failure modes summary

All rows below describe **non-streaming** `POST /v1/chat/completions`
behavior. Streaming requests carry no receipt regardless of outcome.

| Condition | Receipt? | Header value | finish_reason | tokens_out |
|---|---|---|---|---|
| Normal non-streaming completion | yes (header) | populated | `stop` \| `length` \| `tool_calls` \| `content_filter` | reported |
| Streaming request (any outcome) | no (v0.1.x out of scope; v0.2+ design pending) | absent | n/a | n/a |
| Buyer HTTP disconnect mid-response on non-streaming | no | absent | n/a | n/a (provider has no full response to commit to and no buyer to deliver a receipt to) |
| Provider returns SPEC-001 null-usage error | yes | populated | `error` | `0` |
| Pre-v1.6 binary | no | absent | n/a | n/a |
| Model swap drain violation (defensive) | no, 500 returned | absent | n/a | n/a |
| Gateway/coordinator internal failure (provider never reached) | no | absent | n/a | n/a |

SPEC-005 v0.3 §X-1 settlement semantics for non-streaming
disconnects continue to apply on the billing side; v0.1.x simply
declines to emit a receipt for the partial-response disconnect case
because there is no buyer-deliverable receipt to commit to. A
v0.2+ design that captures partial-response receipts is open
design space.

---

## 13. Storage and persistence

v0.1.3 pins ONLY the provider-side Keychain storage (because the
private key is a security-critical artifact) and the audit-log
emission (because audit events are observable behavior). Coordinator
and gateway storage are implementation concerns named in the future
BUILD spec, per the §7.3 deferral.

| Surface | Field | Type | Notes |
|---|---|---|---|
| Provider Keychain | `com.streamvc.macprovider.receipt-key/<provider_id>` | 32-byte raw ed25519 private key | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `Synchronizable=false` |
| Coordinator memory | `Provider.ReceiptPubkey []byte` | 32 bytes | populated on auth, lifetime tied to WS session unless the BUILD spec adds durable storage |
| Audit log | `receipt_issued` event | JSON | per response, fields per §11 |

The coordinator and gateway MUST NOT store the receipt value (the
`X-MacProvider-Receipt` header bytes) server-side under v0.1.x. The
receipt is buyer-held proof; persisting it server-side would defeat
the offline-verifiability property and create a server-side trove
of prompt/output digests the operator does not need. There is no
exception in v0.1.x: streaming receipts are out of scope (§6.3), so
no server-side retention is needed for any v0.1.x receipt path. A
future v0.2+ streaming-receipt design that needs server-side
storage MUST name its own retention contract and re-establish the
buyer-held-proof posture or accept the v0.1.x divergence
explicitly.

---

## 14. Acceptance criteria

Each AC is independently verifiable from outside this SPEC.

**AC-1.** A v1.6 `phase3-binary serve` process on first launch
generates an ed25519 keypair, stores it in macOS Keychain at
service `com.streamvc.macprovider.receipt-key` account
`<provider_id>`, and on a fresh launch with the same `provider_id`
reads the same private key bytes from Keychain (verify by computing
the public key from the stored private key and comparing against the
expected pubkey).

**AC-2.** A v1.6 binary's v2 `auth_request` initial-stage frame
carries `provider_receipt_public_key` as a 44-character base64
string. Decoding it yields exactly 32 bytes.

**AC-3.** A v1.5 binary (pre-v1.6) does NOT carry
`provider_receipt_public_key` on the auth frame; the coordinator
admits it successfully and its `/poolz` row shows
`receipt_pubkey: null`.

**AC-4.** For a v1.6 provider serving a non-streaming
`POST /v1/chat/completions` with a fixed model, prompt, and
`temperature: 0`, the response carries an `X-MacProvider-Receipt`
header. The value parses as `<base64>.<base64>`. The first base64
decodes to UTF-8 JSON containing exactly the seven SPEC-015 §3.1
keys; the second base64 decodes to exactly 64 bytes.

**AC-5.** For the same request as AC-4, recomputing the canonical
prompt object per §4 and hashing it yields a 64-character lowercase
hex string identical to `receipt.prompt_hash`.

**AC-6.** For the same request as AC-4, recomputing the canonical
output object per §5 from the response body and hashing it yields a
64-character lowercase hex string identical to `receipt.output_hash`.

**AC-7.** For the same request as AC-4,
`ed25519_verify(receipt.provider_pubkey, base64_decode(b64_tuple),
base64_decode(b64_sig))` returns true.

**AC-8.** For a streaming `POST /v1/chat/completions`, the response
carries NO `X-MacProvider-Receipt` header AND NO additional
`X-MacProvider-*` response header beyond what SPEC-006 v0.8.3 §17
already allowlists. The SSE stream itself is exactly what SPEC-001
v1.5 and SPEC-006 v0.8.3 already specify (no extra `event:` blocks,
no non-OpenAI-shaped `data:` payloads). Receipts for streaming
requests are out of scope in v0.1.x.

**AC-9.** The OpenAI Python SDK ≥ v1.0 and the OpenAI JavaScript
SDK ≥ v4.0, with `base_url` pointing at the SPEC-006 gateway, MUST
complete `chat.completions.create(...)` (non-streaming) AND
`chat.completions.create(stream=True)` successfully against a v1.6
provider. The non-streaming response carries an
`X-MacProvider-Receipt` header (which the SDK ignores transparently);
the streaming response carries no SPEC-015 wire changes. The SDK
MUST NOT raise on either request shape.

**AC-10.** Running `macprovider rotate-key` on a connected
v1.6 binary causes the binary to close its current WS connection
and reconnect with a freshly-generated keypair in the v2
`auth_request` initial-stage `provider_receipt_public_key` field.
On successful reconnect, the coordinator's `/poolz` row for this
provider reflects the new pubkey under `receipt_pubkey` and the old
pubkey under `receipt_pubkey_prev` with
`rotated_at` = the reconnect time. The next response after rotation
is signed with the new key. If reconnect fails (coordinator rejects
auth or network failure), the CLI exits non-zero, the Keychain
state is unchanged, and the binary continues signing with the old
key on its restored WS session.

**AC-11.** During the 7-day rotation grace window, a buyer who
fetches `/poolz`, sees `receipt_pubkey_prev.expires_at` in the
future, and verifies a receipt against `receipt_pubkey_prev.pubkey`
succeeds for receipts whose `unix_ts` is between
`receipt_pubkey_prev.rotated_at - 60` and
`receipt_pubkey_prev.expires_at`. The −60 s slack covers in-flight
requests on the old key at rotation time (a provider may have begun
signing a receipt with the old key up to ~60 s before the
reconnect-based rotation was accepted by the coordinator).

**AC-12.** A SPEC-001 null-usage error response (e.g.
`error_model_not_loaded`) on a v1.6 provider carries an
`X-MacProvider-Receipt` header with `tokens_out: 0`,
`output_hash` equal to the sha256 of the canonical output object
`{"content":"","tool_calls":null,"finish_reason":"error"}`, and
verifies cleanly against the provider pubkey.

**AC-13.** A request that the gateway rejects before reaching any
provider (auth failure, quota exhausted, kill switch on) does NOT
carry an `X-MacProvider-Receipt` header.

**AC-14.** A non-streaming request routed to a coordinator-recorded
provider whose `receipt_pubkey` is `null` (pre-v1.6 binary) does
NOT carry an `X-MacProvider-Receipt` header.

**AC-15.** The `X-MacProvider-Receipt` header value is ≤ 4096
ASCII bytes for the v0.1.3 tuple shape; nginx between gateway and
buyer MUST be configured (or already configured) to forward headers
of this size without truncation.

**AC-16.** The receipt-issuing path MUST NOT introduce >5 ms p95
overhead over the existing SPEC-001 v1.5 baseline for a
1024-output-token completion on the smallest supported model. The
overhead is dominated by SHA-256 + ed25519_sign on a payload of ≤
600 bytes; on Apple Silicon, both are sub-millisecond.

**AC-17.** The SPEC-001 v1.6 candidate annotation
(`provider_receipt_public_key` field on `auth_request` initial-stage
ONLY) MUST be parser-optional on the coordinator: a v1.6 binary
that omits the field due to keypair-generation failure MUST still
admit successfully, the coordinator MUST log
`receipt_omitted: reason=no_keypair`, and the provider MUST be
flagged in its `/poolz` row as `receipt_pubkey: null` until a
subsequent reconnect with the field present.

---

## 15. Open questions

These are flagged for v0.x audit cycles and are NOT resolved in
v0.1. Implementers MUST NOT pin behavior in v0.1 that pre-decides
these.

**Q1: Stronger trust root.** Should `/poolz` pubkey publication
eventually be signed by an offline operator key (TUF-style) or
anchored to an external registry (AntFeed provider listing, an
on-chain Cluster D-token registry)? v0.1 is honest about
operator-mutability. v0.3+ candidate.

**Q2: Replay-resistance and request-id binding.** The receipt does
NOT bind `request_id`. A malicious replay of the response body to a
different buyer would yield the same `output_hash` for the same
prompt. Should the receipt commit to `request_id` or a buyer-supplied
nonce? If so, where does the buyer obtain its expected `request_id`?
v0.2 verifier scope or v0.3+ depending on operator decision.

**Q3: Cross-provider routing.** Once Cluster F sharding lands, a
single response may span multiple provider segments. Receipt-per-
segment with a buyer-side concatenation rule, or receipt-per-response
with an embedded route list signed by an aggregating coordinator?
v0.4+ candidate.

**Q4: Timestamp trust.** `unix_ts` is provider-reported. Should the
buyer cross-check against the coordinator's response timestamp, and
what skew window is acceptable? v0.2 verifier scope.

**Q5: Streaming receipt delivery mechanism.** v0.1's terminal
`event: receipt` SSE block was rejected in the round-1 audit (C1)
because the OpenAI Python and JavaScript SDKs JSON-parse every
non-`[DONE]` `data:` payload and would raise on a base64 receipt
string. v0.1.1's `X-MacProvider-Receipt-Pending` correlator header
was rejected in the round-2 audit (C1) because it added a second
buyer-visible `X-MacProvider-*` response header outside the single
SPEC-006 v0.9 candidate allowlist annotation. v0.1.2 therefore drops
streaming receipt delivery entirely.

v0.2+ MUST choose one of:

(a) An OpenAI-shape extra field on the final chat-completion chunk
    (e.g. `x_macprovider_receipt` on the last `data: {...}` payload).
    Requires verifying that both SDKs' Pydantic / zod parsers
    tolerate the extra field across pinned versions.
(b) A separate `GET /v1/receipts/<request_id>` endpoint on the
    gateway, with a clearly-bounded retention contract and
    buyer-correlator delivery via an SPEC-006 v0.x candidate
    response header annotation.
(c) An HTTP trailer when the buyer SDK supports it (rare today).
(d) Acceptance that streaming requests never carry receipts — the
    buyer who needs a receipt issues a non-streaming equivalent.

v0.1.2 makes NO choice. The wire format §3.4 of the receipt body
itself MUST remain unchanged across (a)/(b)/(c)/(d). The §6 wire
contract for non-streaming responses is locked in v0.1.2 and v0.2+
MUST NOT change it.

**Q6: Model-hash binding (SPEC-011 cross-cut).** Folding
`heartbeat.model_hash` (SPEC-011 v0.5 §3.3.1) into the receipt
tuple makes the receipt commit to which weights served the buyer.
Gated on SPEC-011 catalog-signing readiness (`beta/DECISION_CRITERIA.md`
Entry 80, Q3 tier-2 posture). v0.3+ candidate.

---

## 16. README compatibility and references

### 16.1 README v1 schema → SPEC-015 v0.1.1 compatibility table

The README §"Roadmap" block at lines 117–128 sketches a v1 receipt
schema. SPEC-015 v0.1.1 changes several field names and conventions
relative to that sketch. The differences are deliberate; the audit
M8 finding required explicit per-field justification.

| README sketch field | SPEC-015 v0.1.1 field | Change | Why |
|---|---|---|---|
| `model` | `model_id` | Renamed | Matches SPEC-001 v1.5 §6.4 and SPEC-002 v1.3.5 naming; `model_id` is the canonical identifier in the rest of the corpus. |
| `prompt_hash: "sha256:7c3f..."` | `prompt_hash: "<64 lowercase hex>"` | Prefix stripped | The receipt only ever uses sha256; embedding the algorithm name doubles the payload and invites parser ambiguity. Verifiers know the algorithm from the SPEC version. |
| `output_hash: "sha256:9b2a..."` | `output_hash: "<64 lowercase hex>"` | Prefix stripped | Same as `prompt_hash`. |
| `provider_id: "m1-anon"` | (NOT in tuple; in `/poolz` only) | Field removed from receipt | The cryptographic identity is the pubkey; `provider_id` is an operator-mutable label and is intentionally out-of-band via `/poolz`. See §3.1 "Why `provider_id` is NOT in the tuple". |
| `provider_pubkey: "ed25519:..."` | `provider_pubkey: "<44-char base64>"` | Algorithm prefix stripped | Same reasoning as the hash prefixes; v0.1.1 pins ed25519. Algorithm agility is v0.x+. |
| `ttft_ms: 646` | `ttft_ms: <int64>` | Unchanged semantics | Pinned as int64. |
| `tokens_out: 142` | `tokens_out: <int64>` | Unchanged semantics | Reused from SPEC-005 §4 `effective_completion_tokens`. |
| `ts: "2026-06-04T12:34:56Z"` | `unix_ts: <int64 Unix seconds UTC>` | Renamed + integerized | RFC3339 strings introduce a canonicalization surface (decimal subseconds, timezone offsets, separator characters) that doesn't add value; integer Unix seconds is unambiguous. |
| `sig: "ed25519:..."` | (transported as the post-`.` segment of the `X-MacProvider-Receipt` header value, not as a tuple field) | Moved out of tuple, prefix stripped | The signature MUST NOT be inside the signed payload. v0.1.1's `<base64-tuple>.<base64-sig>` envelope keeps the two cleanly separated. |
| "issued by the gateway" (README §"Roadmap" prose) | Issued by the PROVIDER | Architectural change | The gateway does not know the provider's private key, by design. Provider-side signing is what makes the receipt verifiable against `/poolz`'s `receipt_pubkey` without trusting the operator. The README will be updated when v0.1.1 lands to reflect provider-side issuance. |

### 16.2 References

- README.md:22 — the verifiable-inference vapor claim this SPEC
  closes.
- README.md:117–128 — the v1 receipt schema sketch (compatibility
  table above explains each deviation).
- `audits/2026-06-10/REPO_AUDIT.md` — Open Question 1 (receipts
  unimplemented) the audit raised.
- `beta/DECISION_CRITERIA.md` Entries 79–81 — operator context for
  the 2-person beta posture in which v0.1 ships.
- SPEC-001 v1.5 §6.7 — v2 `auth_request` handshake, which v0.1
  annotates with the `provider_receipt_public_key` field.
- SPEC-002 v1.3.5 §7 — `/poolz` shape, which v0.1 annotates with
  `receipt_pubkey`.
- SPEC-005 v0.3 §3 X-1 row — null-usage settlement, which v0.1's
  §7.6 receipt for null-usage errors composes with.
- SPEC-005 v0.3 §4 — `effective_completion_tokens` derivation,
  which `tokens_out` reuses.
- SPEC-006 v0.8.3 §17 — header allowlist; SPEC-015 v0.1 adds
  `X-MacProvider-Receipt` to the response pass-through allowlist as
  a SPEC-006 v0.9 candidate.
- SPEC-008 v0.3 §5.3, §6 — Pillar A model-hash and Pillar B
  encrypted-leg semantics; v0.1 is orthogonal to both.
- SPEC-011 v0.5 §3.3.1, §3.8 — `model_hash` heartbeat and warm-swap
  drain; v0.1's §7.4 invariant relies on §3.8.
- SPEC-013 v0.3 — `autotune` subcommand; this SPEC reuses
  `RFC8785JCS.swift` from SPEC-013's implementation.
- RFC 8785 — JSON Canonicalization Scheme.
- RFC 8032 — EdDSA / ed25519.
- `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` —
  in-house JCS implementation.
