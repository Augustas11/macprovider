# BUILD_SPEC_015_IMPL — Verifiable inference receipts v0.1.3 implementation (write prompt)

**You are starting a fresh session in `/Users/augstar/macprovider-poc`. You have no memory of prior conversations. Read this prompt end-to-end before writing any code.**

Your job is to implement SPEC-015 v0.1.3 (`specs/SPEC-015-receipts.md`,
LOCKED 2026-06-22) across the `phase3-binary` (Swift),
`phase4-coordinator` (Go), and `phase5-gateway` (Go) modules. v0.1.3
covers **non-streaming receipts only**; streaming is explicitly out
of scope. There is NO code in the repo today implementing receipts —
`grep -r receipt phase3-binary phase4-coordinator phase5-gateway`
returns zero matches. This prompt is the implementation contract that
closes the README line-22 vapor claim for non-streaming chat
completions.

## What you are building

A signed inference receipt per non-streaming `POST /v1/chat/completions`
response. The receipt is a base64-encoded ed25519 signature over a
JCS-canonicalized seven-field tuple, transported on a new
`X-MacProvider-Receipt` HTTP response header. The provider holds the
signing key in macOS Keychain; the coordinator surfaces the public
key on `/poolz`; the gateway forwards the header untouched. See
`specs/SPEC-015-receipts.md` for the full normative contract — every
"MUST/MUST NOT/SHOULD" in that file is binding here.

## Repo conventions you MUST honour

1. **House style:** existing implementation patterns live in
   `phase3-binary/Sources/macprovider-cli/`,
   `phase4-coordinator/internal/`,
   `phase5-gateway/internal/`. Match the existing testing,
   error-handling, and logging idioms in each module.
2. **No locked-spec edits beyond the three named candidate
   annotations.** v0.1.3 ANNOTATES three additive extensions:
   - **SPEC-001 v1.5 → v1.6:** optional `provider_receipt_public_key`
     field on the v2 `auth_request` initial-stage frame ONLY (NOT
     proof-stage). Absorb in Step 0.
   - **SPEC-002 v1.3.5 → v1.4:** two optional fields on each
     `/poolz` provider row: `receipt_pubkey` and
     `receipt_pubkey_prev`. Absorb in Step 0.
   - **SPEC-006 v0.8.3 → v0.9:** `X-MacProvider-Receipt` on the
     response-pass-through allowlist (§17). Absorb in Step 0.
   ANY other edit to SPEC-001/002/005/006/008/011/013 text is OUT OF
   SCOPE and is a critical violation. If you find yourself needing
   to change a locked spec, STOP and surface the issue — the
   resolution is either an additive seam or a separate spec PR.
3. **Audit-loop discipline (NON-NEGOTIABLE, per
   `feedback-build-audit-loop` memory):** after each numbered Step
   below, author
   `specs/AUDIT_SPEC_015_IMPL_STEP_N_PROMPT.md`, fire it at codex
   via `omc ask codex`, fix the findings, re-audit with
   `R<n+1>_PROMPT.md` if needed, loop until **0 CRITICAL, 0 MAJOR**
   for that step. Only then proceed to Step N+1. Existing pattern:
   SPEC-013 ran 21 audit rounds across 11 BUILD steps; SPEC-015
   should expect similar density.
4. **Branching:** create `impl/spec-015-step-NN` branches off
   `main` per logical PR group (see §"PR grouping" below). Do NOT
   develop on local `main`. Follow `CLAUDE.md` PR workflow:
   feature branch → IMPL audit loop on branch → push → PR →
   squash-merge → `git reset --hard origin/main` locally.
5. **Test corpus must exist by Step 11.** ACs 1–17 from SPEC-015
   §14 are the deterministic acceptance gate; every AC must have a
   mechanically-runnable test by the time the implementation is
   ready for the integration-acceptance run in Step 11.
6. **`implementation-notes.html` per module.** As you work,
   maintain a running
   `phase3-binary/implementation-notes.html`,
   `phase4-coordinator/implementation-notes.html`, and
   `phase5-gateway/implementation-notes.html` that capture:
   - Design decisions where the spec was ambiguous.
   - Deviations from the spec and why.
   - Tradeoffs and alternatives considered.
   - Open questions for operator review.
7. **No silent capability degradation.** If a step uncovers that an
   AC is not satisfiable as written, STOP and surface the gap. Do
   NOT relax the AC; either fix the implementation or escalate
   back to a SPEC-015 v0.2 spec revision.

## Files you should read before writing code

1. `specs/SPEC-015-receipts.md` v0.1.3 — the full normative contract.
   Read every section. Bias toward §3 (tuple), §4 (prompt
   canonicalization), §5 (output canonicalization), §6 (wire), §7
   (keypair lifecycle), §14 (ACs).
2. `specs/SPEC-015-audit.md` rounds 1–4 — the audit history that
   shaped v0.1.3. Each round's findings explain WHY certain choices
   are what they are (e.g. why streaming is deferred, why rotation
   is reconnect-based, why `model_id` is ASCII-only).
3. `specs/BUILD_SPEC_015_RECEIPTS_v0_1_PROMPT.md` — the originating
   prompt that produced the spec. Useful context for what the
   operator's strategic intent was.
4. `specs/SPEC-001-phase3-binary.md` v1.5 §6.7 — the v2 `auth_request`
   handshake that gains the new field in Step 0.
5. `specs/SPEC-002-coordinator.md` v1.3.5 §7 — the `/poolz` surface
   that gains the new fields in Step 0.
6. `specs/SPEC-005-billing.md` v0.3 §3 X-1 + §4 — the
   `effective_completion_tokens` semantics the receipt's
   `tokens_out` reuses unchanged.
7. `specs/SPEC-006-buyer-api.md` v0.8.3 §17 — the
   `X-MacProvider-*` header allowlist that gains
   `X-MacProvider-Receipt` in Step 0.
8. `specs/SPEC-008-tier2.md` v0.3 §5.5 — the existing
   `provider_ecdh_public_key` pattern that `provider_receipt_public_key`
   mirrors.
9. `specs/SPEC-011-operator-pushed-warm-swap.md` v0.5 §3.4 / R-3.8.3 —
   the drain semantics §7.4 of SPEC-015 composes with.
10. `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` — the
    in-house JCS canonicalizer that v0.1.3 §3.2 mandates be extended
    with NFC normalization + RFC 8785 §3.2.2.3 float handling.
11. `phase4-coordinator/internal/ws/server.go` and
    `phase4-coordinator/internal/pool/provider.go` — the coordinator
    surface where the `provider_receipt_public_key` parse + storage
    + `/poolz` exposure work happens.
12. `phase5-gateway/internal/router/server.go` — the gateway surface
    where the response-header allowlist update happens.
13. `beta/DECISION_CRITERIA.md` Entry 82 — the lock record and
    operator follow-up list for SPEC-015.

## Step decomposition (11 steps)

Each step is sized for ~1–3 hours of focused codex work plus a
focused audit round. Stay disciplined: complete each step's IMPL
audit before starting the next.

---

### Step 0 — Locked-spec candidate absorption

**What lands:** edit `specs/SPEC-001-phase3-binary.md`,
`specs/SPEC-002-coordinator.md`, and `specs/SPEC-006-buyer-api.md`
line-3 versions and add the three named candidate annotations.

**Files modified:**
- `specs/SPEC-001-phase3-binary.md` line 3 version bump to v1.6;
  §6.7.1 initial-stage field table gains a `provider_receipt_public_key`
  row (string base64-32-byte, optional, NOT REQUIRED by parser).
  Add a §6.7.5 SPEC-015 reference subsection citing the field's
  source. No proof-stage change.
- `specs/SPEC-002-coordinator.md` line 3 version bump to v1.4; §7
  `/poolz` response shape adds optional `receipt_pubkey` (string
  base64 nullable) and `receipt_pubkey_prev` (object nullable with
  `pubkey`, `rotated_at`, `expires_at`). Add §7.x cross-ref to
  SPEC-015.
- `specs/SPEC-006-buyer-api.md` line 3 version bump to v0.9; §17.x
  response-header allowlist gains `X-MacProvider-Receipt`. Add
  cross-ref to SPEC-015 §6.1.

**What does NOT land:** no code changes; no implementation. This
step is normative spec absorption only. The candidate annotations
named in SPEC-015 §1.3 become locked in their respective specs.

**Change-log entries:** each absorbed spec gets a new top-of-file
change-log block citing the SPEC-015 v0.1.3 LOCK and naming this as
the absorption commit.

**ACs touched:** AC-2, AC-3, AC-17 become parser-spec-grounded.

**Test corpus:** none — spec text only.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_0_PROMPT.md`. Audit asks
codex to verify (a) the three absorptions are additive-only, (b)
no other text changed in the locked specs, (c) the change-log
entries are accurate, (d) the field/header names match SPEC-015
verbatim. LOCK gate: 0 CRITICAL, 0 MAJOR.

**PR:** Step 0 lands as a separate PR FIRST (`spec/001-v1-6-002-v1-4-006-v0-9-absorb`) before any code work begins. This is required because SPEC-001 v1.6 must be the locked authority by the time Step 5's coordinator parser changes ship.

---

### Step 1 — JCS canonicalizer extensions (Swift)

**What lands:** extend
`phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` with the
two SPEC-015 §3.2 mandatory additions:

1. NFC normalization on string values before escaping. Use
   `String.precomposedStringWithCanonicalMapping`.
2. RFC 8785 §3.2.2.3 JSON number handling for IEEE 754 doubles. Add
   a `case double(Double)` to the `Value` enum. The Swift
   implementation of the ECMAScript-derived number-to-string is
   non-trivial — reuse a tested algorithm (the JCS reference
   implementations in the RFC's reference repo are MIT-licensed and
   can be ported).

**Files modified/created:**
- `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift` (modify)
- `phase3-binary/Tests/macprovider-cliTests/RFC8785JCSTests.swift`
  (modify or create)

**ACs touched:** AC-5, AC-6 (canonical hash reproducibility).

**Test corpus (minimum):**
- NFC normalization tests: decomposed vs precomposed string inputs
  produce the same canonical string.
- ASCII no-op tests: a pure-ASCII string is unchanged by the NFC
  step.
- Double formatting tests: known double values produce known
  RFC 8785 §3.2.2.3 outputs. Cover: 0.0, -0.0, 1.0, 1.1, 1e-7, 1e20,
  Double.nan (which MUST throw or be rejected — JCS forbids NaN),
  Double.infinity (also forbidden).
- Existing int / bool / null / string / array / object behavior
  unchanged by the extensions.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_1_PROMPT.md`. Audit
verifies: (a) NFC is applied pre-escape, not post-escape; (b)
double formatting matches RFC 8785 §3.2.2.3 exactly; (c) NaN/Inf
are rejected; (d) tuple-tier ASCII fields hash unchanged from
pre-extension; (e) the extension is BACKWARD-COMPATIBLE — every
existing test in `RFC8785JCSTests.swift` still passes byte-for-byte
on inputs that contain only the old types.

---

### Step 2 — Keychain keypair lifecycle (Swift)

**What lands:** new `ReceiptKeyStore.swift` providing the atomic
insert-or-load pattern from SPEC-015 §7.1.

**Files modified/created:**
- `phase3-binary/Sources/macprovider-cli/ReceiptKeyStore.swift`
  (new): the Keychain interaction. Public API:
  ```swift
  protocol ReceiptKeyStoring {
      func loadOrGenerate(providerId: String) throws -> Curve25519.Signing.PrivateKey
      func loadCurrent(providerId: String) throws -> Curve25519.Signing.PrivateKey?
      func storeNew(providerId: String, privateKey: Curve25519.Signing.PrivateKey) throws
      func swapToCurrent(providerId: String, newKey: Curve25519.Signing.PrivateKey) throws
      // swapToCurrent: move existing current → `.prev` slot, install newKey at current
  }

  struct KeychainReceiptKeyStore: ReceiptKeyStoring { ... }
  ```
- `phase3-binary/Sources/macprovider-cli/InMemoryReceiptKeyStore.swift`
  (new): an in-memory implementation for tests.
- `phase3-binary/Tests/macprovider-cliTests/ReceiptKeyStoreTests.swift`
  (new).

**Keychain attributes per SPEC-015 §7.1:**
- `kSecClass = kSecClassGenericPassword`
- `kSecAttrService = "com.streamvc.macprovider.receipt-key"`
- `kSecAttrAccount = <provider_id>`
- `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- `kSecAttrSynchronizable = false`

**Race-condition handling:** on `errSecDuplicateItem` from
`SecItemAdd`, discard the generated keypair and reload via
`SecItemCopyMatching`. This is mandatory per §7.1.

**ACs touched:** AC-1.

**Test corpus (minimum):**
- First launch with a fresh provider_id generates a new keypair
  and stores it.
- Second launch with the same provider_id loads the SAME private
  key bytes.
- Different provider_ids produce different keypairs.
- Race simulation: two concurrent `loadOrGenerate` calls with the
  same provider_id resolve to the same final stored key (one
  loses the race; both return the winning key).
- `swapToCurrent` moves the prior key to the `.prev` slot
  atomically.
- The 7-day auto-cleanup of stale `.prev` items on launch is tested
  via injection of a fake clock.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_2_PROMPT.md`. Verify:
(a) Keychain attributes match SPEC-015 §7.1 byte-for-byte; (b)
race handling on `errSecDuplicateItem` works; (c) the protocol
abstraction is clean enough for downstream injection in Step 3;
(d) the in-memory implementation is byte-equivalent to the Keychain
one for test purposes.

---

### Step 3 — Receipt construction (Swift)

**What lands:** new `ReceiptBuilder.swift` that takes a request +
response + provider key + clock and emits the
`<base64-tuple>.<base64-sig>` header value.

**Files modified/created:**
- `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift`
  (new). Public API:
  ```swift
  struct ReceiptInput {
      let modelId: String              // ASCII-only per §3.1
      let request: ChatCompletionRequest  // for prompt canonicalization
      let outputContent: String        // for output canonicalization
      let outputToolCalls: [ToolCall]? // optional
      let finishReason: String         // §5.4 v0.1.x non-streaming subset
      let ttftMs: Int64
      let tokensOut: Int64
      let unixTsSeconds: Int64
  }

  struct ReceiptBuilder {
      let keyStore: ReceiptKeyStoring
      init(keyStore: ReceiptKeyStoring) { ... }
      func build(providerId: String, input: ReceiptInput) throws -> String
      // returns the X-MacProvider-Receipt header value
  }
  ```
- `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift`
  (new): builds the §4 16-key canonical prompt object.
- `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift`
  (new): builds the §5 3-key canonical output object.
- `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift`
  (new).
- `phase3-binary/Tests/macprovider-cliTests/PromptCanonicalizerTests.swift`
  (new).
- `phase3-binary/Tests/macprovider-cliTests/OutputCanonicalizerTests.swift`
  (new).

**ACs touched:** AC-4 (encoding), AC-5 (prompt_hash), AC-6
(output_hash), AC-7 (signature verifies), AC-12 (null-usage error
receipt — `tokens_out=0`, empty content, finish_reason=error).

**Test corpus (minimum):**
- Known-good prompt vectors: a fixed `ChatCompletionRequest` with
  the 16 documented keys produces a specific `prompt_hash` value
  (lock this in a test fixture).
- Known-good output vectors: a fixed `(content, tool_calls,
  finish_reason)` produces a specific `output_hash`.
- Tool-call commitment: assistant emits one tool call with a
  specific arguments string → that string is byte-for-byte inside
  `output_hash`.
- Null-usage error receipt: `tokens_out=0`, `content=""`,
  `finish_reason="error"` produces the documented sha256 in
  SPEC-015 AC-12.
- Sign + self-verify: build a receipt, parse it back, verify
  ed25519 against the same pubkey, succeed.
- Sign + cross-implementation verify: a Go reference verifier (in
  the coordinator's tests, see Step 5) verifies a Swift-emitted
  receipt.
- model_id non-ASCII REJECT: a buyer-supplied non-ASCII model_id
  causes `ReceiptBuilder.build` to throw.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_3_PROMPT.md`. Verify:
(a) 16-key prompt object exactly matches SPEC-015 §4.2; (b) 3-key
output object exactly matches §5.1; (c) absent fields encode as
JSON `null` (not omitted); (d) the header value format
`<b64>.<b64>` is exact, no whitespace, single ASCII `.` separator;
(e) the null-usage receipt's `output_hash` matches the AC-12
fixture byte-for-byte.

---

### Step 4 — Wire emission on /v1/chat/completions (Swift)

**What lands:** wire `ReceiptBuilder` into the existing
non-streaming `/v1/chat/completions` handler in
`phase3-binary` so that successful AND null-usage-error responses
carry the `X-MacProvider-Receipt` header.

**Files modified:**
- The handler that emits the non-streaming response (likely under
  `phase3-binary/Sources/macprovider-cli/` — locate by `grep -r
  "v1/chat/completions" phase3-binary/`). Wire a
  `ReceiptBuilder` instance in, gated on availability of the key
  store.
- Confirm streaming path is UNCHANGED — no SPEC-015 wire bytes on
  the streaming response (§6.3 / AC-8).

**ACs touched:** AC-4 (header present on non-streaming), AC-8
(no streaming wire change), AC-15 (≤ 4096 bytes).

**Test corpus (minimum):**
- HTTP integration test: a fixed non-streaming request produces a
  response with `X-MacProvider-Receipt` header. Decode the header
  value and verify the tuple matches the request.
- HTTP integration test: a streaming request produces a response
  with NO `X-MacProvider-Receipt` header and NO other new
  X-MacProvider-* header. SSE stream is byte-equivalent to a
  SPEC-015-disabled binary.
- Pre-keypair launch: a binary launched without a Keychain
  keypair (e.g. fresh install before Step 2 setup completes)
  produces a response with NO header. No 500 — header just absent.
- Null-usage error path: a request that triggers
  `error_model_not_loaded` produces a response with the header
  populated per §7.6 (tokens_out=0, finish_reason=error).
- Header size check: a worst-case request with maximum-length
  model_id produces a header ≤ 4096 bytes.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_4_PROMPT.md`. Verify:
(a) the header is written BEFORE the response body (so streaming
clients that read headers early get it); (b) streaming path is
completely unmodified; (c) every §6.4 omission case is correctly
handled.

---

### Step 5 — SPEC-001 v1.6 `provider_receipt_public_key` (Swift emit + Go parse)

**What lands:**
- Swift (`phase3-binary`): emit the new optional field on the v2
  `auth_request` initial-stage frame.
- Go (`phase4-coordinator`): parse the optional field on
  `auth_request`, store on the in-memory Provider struct.

**Files modified/created:**
- Swift: locate the v2 `auth_request` builder (likely in
  `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
  or similar — `grep -r 'auth_request' phase3-binary/`). Add the
  optional field.
- Go: `phase4-coordinator/internal/ws/messages.go` adds the new
  field to the `AuthRequest` struct as `omitempty`. The frame
  validator at `phase4-coordinator/internal/ws/server.go` must
  accept the field as optional (validate base64 + 32-byte
  decode if present; absent is fine).
- Go: `phase4-coordinator/internal/pool/provider.go` adds a
  `ReceiptPubkey []byte` field to the Provider struct, populated
  on auth.

**ACs touched:** AC-2 (field present on v1.6), AC-3 (pre-v1.6
admits without field), AC-17 (parser-optional fallback).

**Test corpus (minimum):**
- Go unit test: an `auth_request` with the new field admits and
  records the pubkey. Decode succeeds; struct has correct bytes.
- Go unit test: an `auth_request` WITHOUT the new field admits
  cleanly (no parser rejection). Provider struct has nil
  `ReceiptPubkey`.
- Go unit test: an `auth_request` with the field set to an invalid
  base64 string OR a string that decodes to ≠ 32 bytes is REJECTED
  with a clear error (no silent acceptance).
- Swift integration test: a v1.6 binary's auth_request frame
  bytes contain `provider_receipt_public_key`. A pre-v1.6 binary
  (or a v1.6 binary in a degraded keypair-absent state) emits the
  frame WITHOUT the field.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_5_PROMPT.md`. Verify:
(a) the SPEC-001 v1.6 candidate annotation lands without modifying
the proof-stage frame; (b) the parser tolerance is correct
(unknown additive fields don't break frame validation on pre-v1.6
coordinators); (c) the keypair-absent fallback emits no field and
the coordinator logs `receipt_omitted: reason=no_keypair`.

---

### Step 6 — `/poolz` exposure (Go)

**What lands:** the coordinator's `/poolz` HTTP handler emits
`receipt_pubkey` (current) on every provider row, and
`receipt_pubkey_prev` (the rotated-out previous key with its
expiration) when applicable.

**Files modified:**
- `phase4-coordinator/internal/ws/server.go` or wherever
  `/poolz` is served (find via `grep -r 'func.*Poolz\|poolz' phase4-coordinator/`).
- The `/poolz` JSON serializer struct adds the two new optional
  fields (base64 string and nullable object respectively, per
  SPEC-015 §8.1).

**ACs touched:** AC-11 (grace window visibility on /poolz), AC-14
(null `receipt_pubkey` for pre-v1.6 providers).

**Test corpus (minimum):**
- Go contract test: `/poolz` JSON shape for a v1.6 provider
  includes `receipt_pubkey` populated.
- Go contract test: `/poolz` JSON shape for a pre-v1.6 provider
  has `receipt_pubkey: null`.
- Go contract test: during a simulated rotation grace window,
  `/poolz` carries `receipt_pubkey_prev` with the documented
  shape.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_6_PROMPT.md`. Verify:
(a) the fields are additive (no existing /poolz consumer breaks);
(b) the shape matches SPEC-002 v1.4 absorption from Step 0
exactly; (c) the `null` representation is consistent across
languages (Go `nil` → JSON `null`).

---

### Step 7 — `macprovider rotate-key` CLI + reconnect rotation (Swift + Go)

**What lands:**
- Swift CLI: a new `rotate-key` subcommand on `macprovider-cli`.
  Per SPEC-015 §7.5: generate a fresh keypair in memory, close the
  current WS, reconnect with the new pubkey on the
  `auth_request.provider_receipt_public_key` field, swap Keychain
  ONLY on successful auth.
- Go coordinator: detect rotation on reconnect by comparing the new
  pubkey against the previously-known one for this `provider_id`;
  move the old to `receipt_pubkey_prev` with `rotated_at = now`
  and `expires_at = rotated_at + 7 * 86400`.

**Files modified/created:**
- Swift: `phase3-binary/Sources/macprovider-cli/RotateKeyCommand.swift`
  (new).
- Swift: extend `CoordinatorClient.swift` (or equivalent) with a
  `reconnectWithNewKey(_:) throws` method that uses a candidate
  keypair for the next handshake and rolls back to the old key on
  failure.
- Go: rotation-detection logic in `phase4-coordinator/internal/ws/server.go`
  on the auth flow.
- Go: in-memory `RotationState` on the Provider struct to track
  `(receipt_pubkey, receipt_pubkey_prev, rotated_at)`.

**Persistence note:** SPEC-015 §7.3 deferred durable storage to the
BUILD spec. v0.1.3 ACs only verify the runtime surface. For this
PR, choose **in-memory only** (providers republish their pubkey on
every reconnect; the grace window state is lost on coordinator
restart). This is the simplest implementation and is acceptable
because the SPEC-002 v1.3.5 §4 admission semantics already require
provider reconnect on any coordinator restart. Document the choice
in `phase4-coordinator/implementation-notes.html`.

**ACs touched:** AC-10 (rotate-key flow), AC-11 (grace window).

**Test corpus (minimum):**
- Swift integration test: `macprovider rotate-key` against a fake
  coordinator generates a new key, reconnects, and on success
  swaps Keychain. The CLI exits 0; the next /v1/chat/completions
  receipt is signed with the new key.
- Swift integration test: `macprovider rotate-key` when the fake
  coordinator rejects the new auth returns CLI exit non-zero, the
  Keychain state is unchanged, and the binary's current WS session
  is restored using the OLD key.
- Go unit test: rotation-detection moves prior pubkey to
  `receipt_pubkey_prev` with correct `rotated_at` and
  `expires_at`. /poolz reflects both keys.
- Go unit test: after 7 days (simulated via injected clock), the
  `receipt_pubkey_prev` block is purged.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_7_PROMPT.md`. Verify:
(a) no new WS control frame was introduced (audit C2 from round 2
of the spec audit); (b) Keychain commit happens AFTER reconnect
acceptance, not before (audit M4); (c) the -60s slack in AC-11 is
correctly implemented (the grace window detection accepts receipts
signed up to 60s before `rotated_at`); (d) the in-memory-only
persistence decision is honestly documented.

---

### Step 8 — Gateway response-header allowlist (Go)

**What lands:** `phase5-gateway` adds `X-MacProvider-Receipt` to
the response-pass-through allowlist per SPEC-006 v0.9. The
gateway already strips every non-allowlisted `X-MacProvider-*`
response header; this step is purely allowlist expansion.

**Files modified:**
- `phase5-gateway/internal/router/server.go` (or wherever the
  response-header strip lives — `grep -rn 'X-MacProvider' phase5-gateway/internal/`).
- The allowlist data structure gains a new entry.

**ACs touched:** AC-4 (gateway forwards the receipt header).

**Test corpus (minimum):**
- Go contract test: when the coordinator response has
  `X-MacProvider-Receipt`, the gateway-emitted response also has
  it, byte-for-byte.
- Go contract test: when the coordinator response has a NON-allowlisted
  `X-MacProvider-Foo` header, the gateway strips it (regression
  check that the allowlist still discriminates).
- Go contract test: `X-MacProvider-Receipt-Pending` (the rejected
  v0.1.1 header from audit round 2) is NOT in the allowlist and IS
  stripped if a misbehaving provider emits it.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_8_PROMPT.md`. Verify:
(a) only `X-MacProvider-Receipt` is newly allowlisted; (b)
SPEC-006 v0.8.3 buyer-supplied-header strip rules at the request
boundary are unchanged; (c) the gateway does NOT log the receipt
value (which would defeat the buyer-held-proof property per
SPEC-015 §13).

---

### Step 9 — Audit log emission (Swift + Go)

**What lands:** the three audit event types from SPEC-015 §11:
- `receipt_issued` (per non-streaming response that emits a
  receipt) — provider-side.
- `receipt_omitted` with five reasons (`pre_v1_6_binary`,
  `no_keypair`, `model_swap_violation`, `pre_token_cancel`,
  `streaming_request`) — provider or coordinator depending on
  reason.
- `receipt_rotation_detected` — coordinator-side.

**Files modified:**
- Swift: provider-side audit emission. Reuse the existing audit
  sink (locate via `grep -r 'audit' phase3-binary/Sources/`).
- Go: coordinator-side audit emission. Reuse the existing
  audit-sink under `phase4-coordinator/internal/audit/`.

**ACs touched:** internal observability; no AC strictly mandates
audit events, but the SPEC-015 audit-prompt §G category requires
them.

**Test corpus (minimum):**
- Swift unit test: `receipt_issued` event for a successful
  non-streaming response carries the four named fields
  (`model_id`, `tokens_out`, `ttft_ms`, `unix_ts`) and NO
  `provider_pubkey`, `prompt_hash`, `output_hash`, or signature
  (privacy invariant per §11).
- Swift unit test: each `receipt_omitted` reason fires on the
  documented condition.
- Go unit test: `receipt_rotation_detected` fires when a
  reconnecting provider's pubkey changes.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_9_PROMPT.md`. Verify:
(a) no receipt body or hash leaks into the audit log; (b) the
five `receipt_omitted` reasons map 1:1 to §6.4 omission cases;
(c) the audit destination matches SPEC-005 v0.3 §6 audit-sink
shape.

---

### Step 10 — SDK compat + nginx config + perf bench

**What lands:**
- An integration test fixture that exercises both the OpenAI
  Python SDK ≥ v1.0 and the OpenAI JavaScript SDK ≥ v4.0 against
  the stack (provider + coordinator + gateway running locally).
  AC-9 requires both SDKs complete `chat.completions.create()`
  in non-streaming AND streaming modes without raising.
- nginx config update at
  `deploy/nginx/coordinator.streamvc.live.conf` and
  `deploy/nginx/api.streamvc.live.conf` to forward headers up to
  4096 bytes (`large_client_header_buffers` / `proxy_buffer_size`
  tuning).
- Perf bench: a microbenchmark in
  `phase3-binary/Tests/macprovider-cliTests/ReceiptPerfTests.swift`
  measuring p95 overhead of receipt construction (sha256 + JCS +
  ed25519_sign) on a 1024-output-token completion's payload. Per
  SPEC-015 AC-16: ≤ 5ms p95.

**ACs touched:** AC-9 (SDKs), AC-15 (nginx forwarding), AC-16
(perf).

**Test corpus (minimum):**
- Python SDK: a script that imports `openai`, points `base_url`
  at the local gateway, runs both non-streaming and streaming
  chat completions, expects both to succeed.
- JavaScript SDK: same in Node.
- nginx config: a curl test against the deployed nginx that
  echoes a 4096-byte header through without truncation.
- Perf: 1000 iterations of `ReceiptBuilder.build` measured; assert
  p95 < 5ms on Apple Silicon.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_10_PROMPT.md`. Verify:
(a) both SDKs are pinned to specific versions in the test
fixture (so a future SDK release that breaks compat surfaces as
a test failure, not a silent regression); (b) the nginx changes
are deploy-gate-tested (the existing `dist/check-deploy-config.sh`
or equivalent gate accepts them); (c) the perf bench is run on a
representative payload size (not a tiny synthetic).

---

### Step 11 — Final integration acceptance run

**What lands:** end-to-end acceptance test that runs ALL 17 SPEC-015
ACs against a freshly-deployed coordinator + gateway + provider
stack (local or staging).

**Files modified/created:**
- `test/integration/spec015/` (new directory): a runner that
  walks AC-1 through AC-17 and reports pass/fail with the
  specific verification step from SPEC-015 §14.
- Existing CI job `cross-service integration test` (per
  `cross-service-integration-test-landed` memory) gains the
  SPEC-015 ACs as a new sub-suite.

**ACs touched:** all 17.

**Test corpus:** the full SPEC-015 §14 AC suite, mechanically
executable from CI.

**IMPL audit:** `AUDIT_SPEC_015_IMPL_STEP_11_PROMPT.md`. The audit
is the LOCK gate for the implementation: each AC has a
deterministic test that runs in CI; no AC is "deferred to manual
verification"; any AC that proved unsatisfiable is documented as a
v0.2 spec revision proposal, not silently relaxed.

---

## PR grouping (recommended)

Each individual step has its own IMPL audit, but the PRs group
related steps for review efficiency:

- **PR A: Step 0 — locked-spec absorption.** SPEC-only, no code.
  Lands first so the SPEC-001 v1.6 / SPEC-002 v1.4 / SPEC-006 v0.9
  candidates become locked authority.
- **PR B: Steps 1–4 — provider-side receipt construction +
  emission.** All Swift; no coordinator or gateway changes. Lands
  the receipt-issuing capability behind a feature flag
  (`--enable-receipts=true`, default false in v0.1.x rollout) so
  the merge can sit on `main` without buyer-visible behavior change
  until activation.
- **PR C: Steps 5–7 — SPEC-001 v1.6 wire integration + /poolz +
  rotation.** Swift + Go. Lands the coordinator-side surface.
- **PR D: Steps 8–9 — gateway allowlist + audit log emission.**
  Go only.
- **PR E: Steps 10–11 — SDK compat tests + nginx + perf + final
  acceptance.** Cross-module; the AC-suite test runner is the
  LOCK gate for the implementation as a whole.

Each PR's audit-loop discipline is independent: PR B fully
audited to 0/0 before PR C opens, etc. Per
`pr-rebase-silent-dependency-regression` memory, rebase each PR
on the merged tip of the previous one before pushing.

## Feature flag rollout

Per `feedback-build-audit-loop` and SPEC-015's "no silent
capability degradation" rule, the provider-side receipt-emission
path SHOULD be gated on a `--enable-receipts` CLI flag (default
`false` for the v0.1.x rollout). This lets the implementation land
on `main` and be deployed to production providers without changing
buyer-visible behavior until the operator explicitly activates it.
Once activated for a provider, that provider's responses carry the
header and the operator can verify against /poolz.

This flag is NOT part of the SPEC-015 v0.1.3 normative contract; it
is an implementation-side rollout choice. Document it in
`phase3-binary/implementation-notes.html` and consider adding it as
a v0.1.4 SPEC absorption (clarifying that the flag's existence does
NOT change any AC's truth — when the flag is on, every AC must
pass).

## Acceptance / lock gate

The implementation is LOCKED when:

1. All 11 IMPL audits return 0 CRITICAL / 0 MAJOR.
2. Step 11's integration runner passes all 17 ACs in CI.
3. SDK compat test in Step 10 passes against the pinned SDK
   versions.
4. Perf bench in Step 10 confirms ≤ 5ms p95 overhead.
5. `beta/DECISION_CRITERIA.md` gets a new entry (likely Entry 83+
   depending on intervening commits) recording the IMPL lock with:
   - The 5 PRs that landed (links).
   - Each step's IMPL audit summary (rounds + final verdict).
   - Any operator-pending items (e.g. nginx config deploy to Pearl,
     feature-flag activation, rotation drill, etc).
   - Cross-cutting follow-ups (e.g. v0.2 spec authoring for
     streaming receipts per SPEC-015 §15 Q5, model-hash binding
     per Q6).

## Final deliverables when you're done

1. SPEC-001 v1.6, SPEC-002 v1.4, SPEC-006 v0.9 absorbed (PR A).
2. All `phase3-binary` Swift code lands across PRs B and C.
3. All `phase4-coordinator` and `phase5-gateway` Go code lands
   across PRs C and D.
4. Test corpus per step lands in each module's test directory.
5. `implementation-notes.html` for each module lands at PR-E
   merge time.
6. The 11 `AUDIT_SPEC_015_IMPL_STEP_N_PROMPT.md` files plus their
   audit-output files (`SPEC-015-IMPL-STEP_N-audit.md` or similar)
   are checked in.
7. DECISION_CRITERIA entry recording the implementation LOCK.
8. README.md line 22 + lines 117–128 are rewritten to remove the
   "planned, not yet implemented" caveat for the non-streaming
   path, with explicit truth-in-advertising about the streaming
   v0.2+ scope (per SPEC-015 §16.1 compatibility table).

**You're not done when the code compiles. You're not done when
the tests pass. You're done when:**

- The 11 IMPL audits each return 0 CRITICAL / 0 MAJOR,
- A live non-streaming `POST /v1/chat/completions` against the
  deployed stack returns a header that a buyer can verify offline
  against `/poolz`,
- The README no longer over-promises what isn't shipped, and
- The DECISION_CRITERIA entry is appended.

## Operator-pending items to anticipate (not in this BUILD scope)

These are foreseeable side-effects of the implementation; surface
them in implementation-notes.html as you encounter them:

1. **Pearl coordinator deploy** to ship the SPEC-001 v1.6 / SPEC-002
   v1.4 / SPEC-006 v0.9 candidates as runtime code. The deploy
   path is the existing
   `phase4-coordinator/dist/check-deploy-config.sh` +
   `deploy-pearl-vps.sh` flow.
2. **Feature flag activation** on at least one production provider
   to exercise the AC-9 SDK compatibility against real buyer
   traffic.
3. **Rotation drill** on a non-production provider to verify
   AC-10 / AC-11 against real Keychain semantics (the in-memory
   tests catch most issues but a real Keychain interaction can
   surface OS-version quirks).
4. **Buyer documentation** at `api.streamvc.live/docs` should
   gain a "Receipts" section once a buyer-side verifier exists
   (v0.2 scope, NOT here).

## What you must NOT do

- Do NOT implement streaming receipt body delivery. v0.1.x covers
  non-streaming only.
- Do NOT add a second buyer-visible `X-MacProvider-*` response
  header (the round-2 spec audit rejected
  `X-MacProvider-Receipt-Pending` for this reason).
- Do NOT introduce a new WS control frame for rotation (the
  round-2 spec audit rejected `provider_receipt_public_key_rotate`).
- Do NOT prescribe coordinator durable storage of the receipt
  pubkey beyond what SPEC-015 §7.3 deferred — in-memory + reconnect
  republish is the v0.1.x default; durable storage is a future
  SPEC-002 candidate.
- Do NOT log the receipt value, prompt_hash, output_hash, or
  signature into any server-side audit sink (§11 + §13).
- Do NOT silently relax any of the 17 ACs. If an AC proves
  unsatisfiable as written, surface it as a v0.2 spec proposal
  and STOP.

When in doubt, re-read `specs/SPEC-015-receipts.md` v0.1.3. Every
"MUST / MUST NOT" in that file is the contract you are implementing.
