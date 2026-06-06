# SPEC-001 — Phase 3 Binary: Mac Provider Inference CLI

**Version:** 1.3 (2026-06-06, SPEC-010 v1.5 + SPEC-011 v0.5 absorption)
**Revision:** v1.3 absorbs the binary-side surface of LOCKED SPEC-010 v1.5 (Provider Model Catalog) and LOCKED SPEC-011 v0.5 (Operator-Pushed Warm Swap), and adds the first normative documentation of the v2 `auth_request` two-stage handshake. L-1 baseline preserved: with neither `--supported-models` nor `--enable-warm-swap` set, a v1.3 binary introduces no NEW SPEC-010 or SPEC-011 fields, sockets, or runtime state beyond the SPEC-010 R-3.6.2 single-entry `supported_models: [model_id]` default emission, which SPEC-010 v1.5 §4.1 establishes as observably indistinguishable from a pre-SPEC-010 binary on routing, `/v1/status`, and `/v1/models`. The v2 `auth_request` first-connect frame type is unchanged from existing v1.2.x binaries (already in code per SPEC-010 v1.5 §3.1.A; v1.3 normatively documents the contract for the first time).

**Change log v1.3:**
- **v1.3 (2026-06-06, SPEC-010 v1.5 + SPEC-011 v0.5 absorption):** Adds binary-side surface for two now-LOCKED companion specs. SPEC-010 v1.5 adds `--supported-models` / `--publish-supported-models` flags, gains the two optional v2 `auth_request` initial-stage fields, gains local pre-flight validation per R-3.6.3. SPEC-011 v0.5 adds `--enable-warm-swap` opt-in gate, `--swap-drain-timeout-seconds`, `--ctl-socket-path`, `--switch-state-path` flags on `serve`; adds the `models` subcommand with `list / switch / status` actions; mandates a `ModelRuntime` refactor from immutable `let container` to actor-isolated mutable `current_container` with an atomic-swap state machine; adds an opt-in heartbeat extension carrying `model_hash` (raw lowercase hex) and `loading: bool`; adds a newline-delimited JSON control socket protocol on a macOS-native `$TMPDIR`-based path. ALSO adds a new normative §6.7 v2 `auth_request` handshake section — the v2 contract has been in code since v1.2.x but was never normatively documented in SPEC-001; v1.3 closes that gap. L-1 baseline preserved: with neither flag set, a v1.3 binary introduces no NEW SPEC-010/SPEC-011 fields, sockets, or runtime state beyond the SPEC-010 R-3.6.2 single-entry `supported_models: [model_id]` default (which SPEC-010 v1.5 §4.1 establishes as observably indistinguishable from a pre-SPEC-010 binary on routing, `/v1/status`, and `/v1/models`).

**Change log v1.2.4:**
- **v1.2.4 (2026-05-29, audit response, concurrency reality alignment):** Aligns the RAM-tier max_concurrency documentation to the Swift runtime's enforced semaphore-of-1 reality (H-003 from the 2026-05-29 independent security audit). Spec previously documented per-tier defaults >1; runtime always overrode to 1. No code change required. Future parallel generation deferred to a SPEC-001 v1.3 candidate pending runtime validation.

**Change log v1.2.3:**
- § 6.1 `/v1/models`: producers MUST emit model `id` values with unescaped forward slashes (`/`) by suppressing the legal-but-cosmetic `\/` JSON escape. Consumers MUST continue to tolerate both encodings for backward compatibility.
- § 6.6 `inference_response_end`: when sent in response to `cancel_request`, providers MUST include actual token usage so downstream gateways, accounting systems, and billing infrastructure can settle cancellation usage exactly instead of estimating.

**Change log v1.2.2:**
- § 6.5 coordinator `drain` message: post-drain reconnect is now explicitly normative. After `drain_status: complete` and WS close, the provider MUST re-enter the startup reconnect loop; first reconnect attempt MUST occur within 15 seconds; three consecutive reconnect failures MUST log WARN with attempt count and last error; the process MUST NOT exit.
- § 6.2 `/v1/chat/completions`: model identifier comparison is ASCII case-insensitive. This matches legacy `mlx_lm.server` behavior and prevents buyer-visible 404 storms from harmless casing differences.
- § 6.1 `/v1/models`: the `id` field may contain `/` or the RFC 8259 `\/` escape; consumers MUST tolerate both. Producers SHOULD prefer unescaped `/` for readability.

**Change log v1.2:**
- § 6.5 hello message: added OPTIONAL `endpoint_url` field (string or null). Absence or null means "route inference through this WebSocket" (WS-tunneled mode). Non-empty string means "I am reachable at this HTTPS URL" (HTTP-forwarding mode). Existing v1.1.x binaries do not send this field; the coordinator falls back to its static `config.providers[]` map.
- § 6.5 hello_ack message: added OPTIONAL `tier` field ("pinned" or "provisional") and OPTIONAL `recommended_binary_version` field (string). Both informational.
- Added § 6.6 "Inference message types" — four new WS message types (`inference_request`, `inference_response_chunk`, `inference_response_end`, `cancel_request`) for WS-tunneled mode. These are NORMATIVELY SCOPED to providers operating in WS-tunneled mode only.
- Added FR-21 through FR-32 covering WS-tunneled inference handling.
- Added AC-11 through AC-15 covering WS-tunneled inference acceptance.
- Added OQ-4 (WS frame size limits) and OQ-5 (per-provider WS write buffer high-water mark).

**Change log v1.2.1:**
- § 6.6: restored request_id demux error handling from SPEC-003 v0.1 FR-A4 (C3 fix): unknown request_id → warn + discard; duplicate active request_id → nak `duplicate_request_id`; completed request_id cleanup rules.
- OQ-3: closed as resolved by SPEC-003 v0.3 FR-C1/FR-C2 (M7 fix).
- OQ-4, OQ-5: restored full rationale paragraphs from SPEC-003 v0.1 (M6 fix).
- § 6.5: clarified endpoint_url absence text to reference SPEC-002 v1.1.1 § 3 for final mode resolution (m2 fix).

> **Backward compatibility.** Phase 3 binaries implementing SPEC-001
> v1.1.4 (or earlier v1.1.x patches v1.1.2, v1.1.3) remain FULLY
> COMPLIANT with the MANDATORY portion of SPEC-001 v1.2 without any
> code change, recompile, or reinstall. The new § 6.6 (Inference
> message types) is NORMATIVELY SCOPED to providers operating in
> WS-tunneled mode, signalled by the absence of `endpoint_url` in
> their `hello` message AND the absence of a corresponding
> `endpoint_url` in the coordinator's `config.providers[]` entry for
> their `provider_id`. Operator-configured pinned providers (e.g.,
> M4 and M1 as of 2026-05-28, both running v1.1.x binaries with
> coordinator-side static endpoint_url entries) operate in HTTP-
> forwarding mode and MUST NEVER receive § 6.6 messages from the
> coordinator. Coordinators (SPEC-002 v1.1) MUST verify routing mode
> via § 3 mode resolution before dispatching any § 6.6 message.
> v1.1.x binaries that receive an unexpected § 6.6 message SHOULD
> respond with `nak code=unknown_message_type` per § 6.5 nak
> semantics; coordinators that observe such a nak MUST mark the
> routing-mode resolution buggy and not retry, treating the provider
> as HTTP-forwarding-only for that session.

**Change log since v1.1.3:**
- § 6.5 coordinator `drain` message: after `drain_status: complete` and WS close, the provider's internal state machine MUST reset to `ready` (assuming the local HTTP server is healthy, which is the only path that reaches `drainFromCoordinator`). The coordinator has no implicit `draining → ready` transition; if the provider's status field carries over from the previous session into the first heartbeat of the next session, the provider stays excluded from routing indefinitely.
- Implementation fix in phase3-binary v1.1.4: `drainFromCoordinator()` calls `providerStatus.setState(.ready)` after the WS close. Bug surfaced same day as v1.1.3 ship when the first FORCE_RESTART of the coordinator left M4 stuck at `state=draining` post-reconnect.

**Change log v1.1.3:**
- § 6.5 coordinator `drain` message: now explicitly normative — drain stops coordinator registration only and MUST NOT terminate the provider's local buyer HTTP server. The provider continues serving direct-to-tunnel buyer traffic across coordinator restarts.
- Implementation fix in phase3-binary v1.1.3: `drainAndExit()` (full process shutdown, used by local SIGTERM) is split from `drainFromCoordinator()` (drop WS, keep HTTP server, reconnect after grace).

**Change log v1.1.2:**
- § 6.5 hello message: `provider_id` field now explicitly normative — it is the operator-issued stable identifier from SPEC-002's static `config.providers[]` map. Example value updated; misleading "uuid-of-this-instance" placeholder removed.
- § 6.5 added normative paragraph immediately after the hello example explaining the relationship to SPEC-002 Finding F-2 and what happens on mismatch (WS close 4002 `unknown_provider_id`).

---

## 0. Operator-paste invocation block

```
Implement SPEC-001. As you work, maintain a running
phase3-binary/implementation-notes.html that captures anything I should
know about how the implementation diverges from or interprets the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Mission

The Phase 3 binary (`macprovider-cli`) is a Swift command-line tool that
runs on Apple Silicon Macs and replaces `mlx_lm.server` as the inference
layer for Mac Provider contributors. It wraps `mlx-swift-lm` to serve
OpenAI-compatible HTTP inference, strips the SSE quirks and stop-token
leakage observed in Phase 1 and Phase 2, enforces per-hardware context
limits to prevent Metal OOM crashes, and speaks a coordinator WebSocket
protocol so a future Phase 4 VPS coordinator can route buyer requests to
a pool of contributor Macs. The binary ships as a signed macOS CLI that
a contributor runs in a single terminal alongside a Cloudflare tunnel or
behind the Phase 4 coordinator.

---

## 2. Scope

### In Tier 1 launch scope (build now)

- Swift CLI binary targeting macOS 14+ on Apple Silicon (M1 through M4)
- Config loader: YAML config file, CLI flag overrides, env var fallbacks
- Model loading via `mlx-swift-lm` (single model per process)
- HTTP server on configurable local port (default 8080)
- `/v1/models` endpoint (OpenAI-compatible)
- `/v1/chat/completions` endpoint (streaming and non-streaming, OpenAI-compatible)
- `/v1/health` local diagnostics endpoint
- SSE streaming with clean OpenAI format (no keepalive comments)
- Stop-token defensive stripping derived from model's `tokenizer_config.json`
- Streaming usage chunk synthesis (mlx_lm.server omits this)
- Two-stage context length pre-flight (envelope size + token count)
- Per-RAM-tier capacity computation at startup (8 GB, 16 GB, 32 GB+ tiers)
- Bounded concurrent request queue with configurable max concurrency
- Mid-stream client disconnect detection and slot release within 5 seconds
- Graceful SIGTERM handling: drain in-flight requests before exit
- Outbound coordinator WebSocket client (connects to configurable URL)
- Coordinator handshake with tier, model, capacity, and throughput metadata
- Capacity heartbeat at configurable interval
- Health state reporting over WebSocket (ready, busy, degraded, draining, unavailable)
- Post-wake warm-up inference before accepting buyer traffic
- Startup self-test: load model, run one inference, verify output
- Structured logging to stdout (JSON lines format)
- macOS code signing (Developer ID, not notarized for v1)
- `THIRD_PARTY_NOTICES.md` shipping with the binary
- Operator-opt-in capability advertisement per SPEC-010 v1.5 §3.6
  (`--supported-models`, `--publish-supported-models`). Default
  OFF; when on, the v2 `auth_request` initial-stage frame carries
  `supported_models[]` and `publishes_supported_models: true`.
- Operator-opt-in warm model swap per SPEC-011 v0.5 §3.1-§3.9
  (`--enable-warm-swap`). Default OFF; when on, enables the
  `models switch <id>` operator workflow, the in-process runtime
  state machine, the control socket, and the extended heartbeat
  fields. Closes arm64golf canary operator pains #1 (multi-minute
  restart loop to change served model) and #2 (red-dashboard / WS
  reconnect on swap).

### In Tier 2 roadmap scope (designed-in but not implemented)

- `TrustGate` middleware: request-level trust evaluation (attestation-based auth)
- `InputDecryptor` middleware: buyer-side encrypted prompt decryption
- `ResponseSeal` middleware: output signing or encryption for buyer verification
- `AttestationProvider` coordinator component: hardware attestation proof on handshake
- Coordinator tier capability upgrade (`tier: 1` to `tier: 2`)

Each of these is a named Swift protocol with a Tier 1 no-op (passthrough)
implementation. The request handler chain has explicit insertion points
for each. See Section 3 for hook-point diagram.

### Out of scope

- Multi-model rotation within a single process (operator restarts with different model)
- Billing, payment, or reward distribution logic
- Coordinator implementation (Phase 4 separate SPEC)
- Smart router logic (Phase 4/5)
- Buyer authentication or authorization (Tier 2)
- Privacy attestation implementation (Tier 2)
- Web UI, dashboard, or contributor portal
- Contributor onboarding flow beyond "run this binary"
- Antseed seller plugin integration (coordinator's responsibility)
- Automatic model downloading (contributor pre-downloads via `huggingface-cli`)
- Provider authentication to coordinator (deferred to SPEC-002)

---

## 3. Architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                          macprovider-cli                            │
│                                                                     │
│  ┌───────────┐    ┌───────────┐    ┌──────────────────────────┐    │
│  │ CLI Entry  │──→│ Config    │──→│ Model Loader              │    │
│  │ (ArgumentP │    │ Loader    │    │ (mlx-swift-lm wrapper)    │    │
│  │  arser)    │    │ (YAML +   │    │                          │    │
│  │            │    │  CLI +env)│    │ Reads tokenizer_config   │    │
│  └───────────┘    └───────────┘    │ for stop-token list      │    │
│                                     └────────────┬─────────────┘    │
│                                                   │                  │
│  ┌────────────────────────────────────────────────┼────────────┐    │
│  │                 HTTP Server (Swift NIO)         │            │    │
│  │                 Bound to 127.0.0.1:{port}       │            │    │
│  │                                                 │            │    │
│  │  Incoming request                               │            │    │
│  │       │                                         │            │    │
│  │       ▼                                         │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Request Router   │   /v1/models → static JSON│            │    │
│  │  │                  │   /v1/health → health JSON │            │    │
│  │  │   404 for unknown paths                      │            │    │
│  │  │   405 for wrong methods                      │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           │ /v1/chat/completions                  │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Request          │  JSON parse, schema check,  │            │    │
│  │  │ Validator        │  tool validation, model     │            │    │
│  │  │                  │  match. Reject → 400/404    │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Pre-flight       │  Stage 1: envelope size     │            │    │
│  │  │ Stage 1          │  check (raw bytes).         │            │    │
│  │  │                  │  Reject → HTTP 413          │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐  ← TIER 2 HOOK POINT      │            │    │
│  │  │ [TrustGate]      │  Tier 1: passthrough       │            │    │
│  │  │                  │  Tier 2: attestation check  │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐  ← TIER 2 HOOK POINT      │            │    │
│  │  │ [InputDecryptor] │  Tier 1: SKIP (no-op)      │            │    │
│  │  │                  │  Tier 2: decrypt prompt     │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Pre-flight       │  Stage 2: tokenize prompt,  │            │    │
│  │  │ Stage 2          │  check token count against  │            │    │
│  │  │                  │  RAM cap. Reject → 413     │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Request Queue    │  Bounded concurrency.      │            │    │
│  │  │                  │  Beyond limit → HTTP 429   │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      ▼            │    │
│  │  ┌────────────────────────────────────────────────┐          │    │
│  │  │ Inference Engine                                │          │    │
│  │  │ (mlx-swift-lm generate / stream)               │          │    │
│  │  │ Tracks prompt_tokens + completion_tokens        │          │    │
│  │  └────────────────────────────┬───────────────────┘          │    │
│  │                                │                              │    │
│  │                                ▼                              │    │
│  │  ┌─────────────────┐  ← TIER 2 HOOK POINT                   │    │
│  │  │ [ResponseSeal]   │  Tier 1: passthrough                    │    │
│  │  │                  │  Tier 2: sign/encrypt output            │    │
│  │  └────────┬────────┘                                         │    │
│  │           ▼                                                   │    │
│  │  ┌──────────────────────────────────────────────────┐        │    │
│  │  │ Response Formatter                                │        │    │
│  │  │  Stop-token stripping, SSE framing,               │        │    │
│  │  │  usage chunk synthesis, JSON envelope              │        │    │
│  │  └──────────────────────────────────────────────────┘        │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │ Coordinator Client (outbound WebSocket)                      │    │
│  │                                                              │    │
│  │  ┌───────────────┐  ┌──────────────┐  ┌─────────────────┐  │    │
│  │  │ Handshake +    │  │ Capacity     │  │ Health State    │  │    │
│  │  │ Tier Announce  │  │ Heartbeat    │  │ Reporter        │  │    │
│  │  └───────────────┘  └──────────────┘  └─────────────────┘  │    │
│  │                                                              │    │
│  │  ┌─────────────────────────┐  ← TIER 2 HOOK POINT          │    │
│  │  │ [AttestationProvider]    │  Tier 1: omitted from handshake│    │
│  │  │                         │  Tier 2: sends attestation blob │    │
│  │  └─────────────────────────┘                                │    │
│  │                                                              │    │
│  │  ┌──────────────────────────────────────────────────┐       │    │
│  │  │ Inbound: preflight, drain, warm_up               │       │    │
│  │  │ Outbound: hello, heartbeat, state_update,         │       │    │
│  │  │           drain_status, preflight_ack, nak        │       │    │
│  │  └──────────────────────────────────────────────────┘       │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌──────────────┐    ┌──────────────────┐                          │
│  │ Logger        │    │ Metrics Counters  │                          │
│  │ (SwiftLog,    │    │ (in-process,      │                          │
│  │  JSON lines)  │    │  exposed on       │                          │
│  │               │    │  /v1/health)      │                          │
│  └──────────────┘    └──────────────────┘                          │
└─────────────────────────────────────────────────────────────────────┘
```

### Tier 2 request chain ordering (hard architecture constraint)

The request chain is Tier-aware. The critical ordering difference:

**Tier 1 path:** Validate → Stage 1 pre-flight → [TrustGate: pass] →
Stage 2 pre-flight (tokenize) → Queue → Inference → [ResponseSeal: pass] → Format

**Tier 2 path:** Validate → Stage 1 pre-flight (envelope bytes) →
[TrustGate: attest] → [InputDecryptor: decrypt] →
Stage 2 pre-flight (tokenize plaintext) → Queue → Inference →
[ResponseSeal: sign/encrypt] → Format

`InputDecryptor` MUST run before Stage 2 pre-flight in Tier 2, because
encrypted prompts cannot be tokenized. Stage 1 (envelope byte-size
check) runs before decryption in both tiers as a fast-reject for
obviously oversized payloads.

### Tier 2 hook points summary

| Hook point | Location | Tier 1 behavior | Tier 2 behavior |
|---|---|---|---|
| `TrustGate` | After Stage 1 pre-flight | Passthrough (all requests accepted) | Validate buyer attestation token |
| `InputDecryptor` | Before Stage 2 pre-flight | Skip entirely | Decrypt buyer-encrypted prompt |
| `ResponseSeal` | After inference, before formatter | Passthrough (plaintext output) | Sign or encrypt output |
| `AttestationProvider` | Coordinator handshake | Omitted from handshake payload | Provides hardware attestation blob |

Each hook point is a Swift protocol. Tier 1 ships with a single conforming
struct (e.g. `PassthroughTrustGate`). Tier 2 adds alternative conformances
without modifying the request chain.

---

## 4. Functional requirements

### Core HTTP endpoints

**FR-1. Model listing endpoint.**
`GET /v1/models` returns a JSON response containing the currently-loaded
model identifier. Response shape matches the OpenAI models endpoint
(see Section 6). The model list always contains exactly one entry — the
model loaded at startup. If no model is loaded (startup failure), the
endpoint returns HTTP 503.

**FR-2. Chat completions — non-streaming.**
`POST /v1/chat/completions` with `stream: false` (or `stream` omitted)
accepts an OpenAI-format chat completion request and returns a single
JSON response with the full completion. The response includes
`usage.prompt_tokens` and `usage.completion_tokens` with accurate counts.
Full request schema and validation rules are in Section 6.2.

**FR-3. Chat completions — streaming.**
`POST /v1/chat/completions` with `stream: true` returns an SSE stream
of chat completion chunks. Each chunk is a valid OpenAI-format delta.
The stream terminates with `data: [DONE]`.

**FR-4. SSE stream format compliance.**
Every SSE line in a streaming response uses the `data: ` prefix (with
exactly one space). No blank `data:` lines between chunks. Each
`data: {...}` payload is valid JSON. The final line is `data: [DONE]`.
Content-Type header is `text/event-stream; charset=utf-8`. The response
uses HTTP/1.1 chunked transfer encoding (which is the normal transport
for SSE when Content-Length is unknown). The binary produces valid SSE
event framing; transport encoding is handled by Swift NIO.

**FR-5. No SSE keepalive comments.**
The binary never emits SSE comment lines (lines starting with `:`).
Phase 1 found `mlx_lm.server` emits `: keepalive N/M` lines that break
strict SSE parsers. The binary controls SSE output directly and does
not proxy `mlx_lm.server` — it generates SSE from its own inference.

### Response quality

**FR-6. Stop-token defensive stripping.**
At model load time, the binary reads the model's `tokenizer_config.json`
and extracts all special tokens (`eos_token`, `bos_token`, entries in
`added_tokens_decoder` where `special: true`). These tokens are compiled
into a stripping filter applied to every generated token before it is
sent to the client. Phase 1 observed `<|eot_id|>` leaking on Llama and
`<|end|>` on Phi. Phase 2 day-0 data showed 0% leakage — likely
upstream `mlx-lm` fixed it — but the binary implements defensive
stripping regardless because:
- Upstream fixes can regress.
- The binary may run older `mlx-lm` model checkpoints.
- The cost of stripping is negligible; the cost of leaking is visible to buyers.

**FR-7. Streaming usage chunk synthesis.**
When streaming, the binary emits a final chunk before `[DONE]` that
contains a `usage` field with `prompt_tokens` and `completion_tokens`.
The binary counts tokens during generation — it does not rely on the
upstream model server to report usage. Phase 2 confirmed that
`mlx_lm.server` omits usage from SSE streams entirely; the Phase 3
binary fixes this.

Format of the usage chunk:
```json
{"id":"chatcmpl-...","object":"chat.completion.chunk","created":1234567890,
 "model":"...","choices":[],"usage":{"prompt_tokens":150,"completion_tokens":42,"total_tokens":192}}
```
Note: `choices` is an empty array in the usage-only chunk. This matches
the OpenAI convention adopted by most proxy-compatible clients.

### Safety and capacity

**FR-8. Two-stage context length pre-flight.**
Pre-flight is split into two stages to support Tier 2 encrypted prompts
without rewriting the chain:

**Stage 1 — Envelope size check (both Tier 1 and Tier 2).**
Before any decryption, check the raw HTTP request body size in bytes.
If the body exceeds a configurable maximum (default: 10 MB), reject
with HTTP 413 immediately. This is a fast-reject for obviously oversized
payloads and does not require tokenization.

**Stage 2 — Token-count pre-flight (after decrypt in Tier 2; immediately in Tier 1).**
Tokenize the full plaintext prompt (system + messages) using the loaded
model's tokenizer and compute the expected token count. If the count
exceeds the safe context capacity for the current hardware tier (FR-9),
reject with HTTP 413 and a JSON error body:
```json
{"error":{"message":"Prompt length (28400 tokens) exceeds this provider's safe capacity (20000 tokens).","type":"context_length_exceeded","param":"messages","code":"context_length_exceeded"}}
```

This prevents the Metal GPU OOM crash observed in Phase 1 at ~26K tokens
on M1 8GB. The binary never forwards a prompt to the inference engine
if it might exceed capacity.

**FR-9. Per-RAM-tier capacity advertisement.**
At startup, the binary reads `hw.memsize` (via `sysctl`), determines the
hardware tier, and computes a safe maximum context length and advertised
concurrency limit. Starting context estimates are refined by runtime
measurement; default concurrency is locked to the runtime-safe value:

| RAM tier | Max context (tokens) | Max concurrency | Rationale |
|---|---|---|---|
| 8 GB | 20,000 | 1 | Phase 1: OOM at ~26K on M1 8GB; 20K with headroom |
| 16 GB | 50,000 | 1 | Context capacity scales with RAM; generation remains serialized |
| 32 GB | 120,000 | 1 | Conservative context capacity for large models; generation remains serialized |
| 64 GB+ | 200,000 | 1 | Upper context bound; generation remains serialized |

Until provider runtime parallel generation is proven safe under MLX
(catalog reasoning, memory pressure analysis, stability validation),
advertised `max_concurrency` MUST be 1 for all RAM tiers. The provider
runtime enforces this via a process-local semaphore of 1 around MLX
generation calls. Operators MAY set `max_concurrency_override` in
`~/.config/macprovider/config.yaml` (or via
`MACPROVIDER_MAX_CONCURRENCY_OVERRIDE` env) for experimental use, but
the default and recommended value is 1.

This is a deliberate safety floor, not an architectural ceiling. A
future SPEC-001 revision MAY raise the default when parallel generation
has been validated under concurrent buyer load without quality, latency,
or memory regressions. Until then, consumers (coordinator routing,
buyer-API gateways, capacity reporting) MUST treat advertised values >1
as opt-in operator overrides, not normative defaults.

The context values are defaults. `max_context_override` can override the
context limit. If the binary detects available memory at startup is
significantly less than expected for the tier (e.g., heavy background
apps), it logs a warning and reduces the advertised context capacity
proportionally.

**FR-10. Mid-stream disconnect cleanup.**
When a client disconnects during a streaming response, the binary
detects the broken connection (via NIO channel close event), cancels
the in-flight inference task, and releases the request slot. The slot
must be available for a new request within 5 seconds of disconnect
detection. Phase 2 adversarial testing (`midstream_disconnect` workload)
found `mlx_lm.server` handles this via `BrokenPipeError`; the binary
must do at least as well, without leaking long-running generation.

**FR-11. Concurrent request handling with bounded queue.**
The binary accepts simultaneous requests up to advertised
`max_concurrency` (FR-9). The normative default is 1; values >1 are
operator overrides for experimental use. Requests beyond the advertised
limit are queued. If the queue exceeds a configurable depth (default:
2x concurrency limit), new requests are rejected with HTTP 429 and a
`Retry-After` header estimating when a slot may free up. The queue is
FIFO with no time-based eviction in v1. Queued requests that are
cancelled by the client before reaching the inference engine are
silently removed from the queue.

**FR-12. Graceful SIGTERM drain.**
On receiving SIGTERM, the binary:
1. Stops accepting new HTTP connections.
2. Sends a `drain_status` message to the coordinator (if connected).
3. Waits for all in-flight requests to complete, up to a configurable
   timeout (default: 30 seconds).
4. Force-cancels any remaining requests after the timeout.
5. Closes the coordinator WebSocket.
6. Exits with code 0.

On SIGINT (Ctrl-C), same behavior with a shorter default timeout
(5 seconds). Double SIGINT forces immediate exit.

### Coordinator protocol

**FR-13. Outbound coordinator WebSocket.**
The binary maintains a persistent outbound WebSocket connection to a
coordinator URL. The URL is configurable via CLI flag (`--coordinator`),
env var (`MACPROVIDER_COORDINATOR_URL`), or config file. If no
coordinator URL is configured, the binary runs in standalone mode
(local HTTP server only, no WebSocket). If the WebSocket connection
drops, the binary reconnects with exponential backoff (1s, 2s, 4s, ...
capped at 60s). The coordinator is a Phase 4 dependency; the binary
ships with the client protocol fully implemented, tested against a mock.
Provider authentication to the coordinator is out of scope for this
binary (deferred to SPEC-002).

**FR-14. Tier capability announcement.**
On successful WebSocket handshake, the binary sends a `hello` message
that includes `tier: 1`. This field is the Tier 2 upgrade vector — a
future binary version sends `tier: 2` with an attached attestation blob
from the `AttestationProvider` hook.

**FR-15. Health state reporting.**
The binary reports its health state to the coordinator via the WebSocket.
States, informed by Phase 2 decision log entry D1 (502 vs 530 routing):

| State | Meaning |
|---|---|
| `ready` | Accepting requests, model loaded |
| `busy` | All request slots occupied |
| `degraded` | Post-wake warm-up in progress (see FR-16) |
| `draining` | SIGTERM received, finishing in-flight |
| `unavailable` | Model load failed or fatal error |

State transitions are sent as `state_update` WebSocket messages
whenever the state changes (see Section 6.5). A WebSocket close
without a prior `draining` message indicates an unclean disconnect
(the 530-equivalent from D1).

**FR-16. Post-wake warm-up hook.**
Phase 2 decision log entry D2 found a -12% throughput dip on the first
request after a Mac wakes from sleep. The binary detects wake events
(via IOKit power notifications or by detecting that wall-clock time
jumped forward significantly since last activity) and runs a synthetic
warm-up inference (a short fixed prompt, result discarded) before
transitioning from `degraded` to `ready`. During warm-up, the binary
reports `degraded` state to the coordinator.

The coordinator can also send an explicit `warm_up` command over the
WebSocket to trigger this behavior.

**FR-17. Capacity advertisement includes model and throughput.**
Phase 2 decision log entry D4 found that smaller-model-on-slower-hardware
(Llama 3B on M1 8GB: 22-25 tok/s) outperformed bigger-model-on-faster-hardware
(Qwen 7B on M4 16GB: 17-20 tok/s). The capacity heartbeat message
must include:

- `model_id`: the loaded model's HuggingFace identifier
- `model_params_b`: approximate parameter count in billions
- `max_context_tokens`: computed from FR-9
- `max_concurrency`: computed from FR-9 (1 by default; higher only by operator override)
- `slots_free`: real-time availability (matches heartbeat schema in § 6.5)
- `slots_total`: total inference slots configured for this provider
- `throughput_tps_estimate`: measured tok/s from the startup self-test
- `ram_gb`: total system RAM

The coordinator MAY use these fields to route by actual measured
performance rather than assumed hardware capability. The binary's
responsibility ends at sending accurate values.

### WS-tunneled inference (v1.2)

**Normative scope.** FR-21 through FR-32 apply ONLY to providers
operating in WS-tunneled mode. Providers in HTTP-forwarding mode
are not affected by these requirements.

**FR-21. Inference request handling.**
On receiving `inference_request` (§ 6.6), the provider:
1. Parses the embedded `body` field through the existing request
   validation pipeline (§ 6.2).
2. Runs inference through the existing pipeline (validation,
   pre-flight, queue, inference engine, response formatter) but
   captures output internally instead of writing to an HTTP response.
3. For streaming requests: emits each SSE chunk as an
   `inference_response_chunk` WS message.
4. For non-streaming requests: emits the complete response as a single
   `inference_response_chunk` followed by `inference_response_end`.
5. On completion or error, sends `inference_response_end` with the
   appropriate status.

**FR-22. Streaming response emission.**
For `stream: true` inference requests, the provider emits one
`inference_response_chunk` per SSE event. Each chunk's `data` field
contains the SSE event line (including `data: ` prefix and `\n\n`
terminator). The `seq` field increments from 0. The final chunk
contains `data: [DONE]\n\n`, followed by `inference_response_end`.

**FR-23. Non-streaming response emission.**
For `stream: false` inference requests, the provider emits a single
`inference_response_chunk` with `seq: 0` containing the complete JSON
response body, followed by `inference_response_end`.

**FR-24. Request ID correlation.**
Every `inference_response_chunk` and `inference_response_end` MUST
carry the `request_id` from the originating `inference_request`. The
provider MUST NOT reuse or reassign `request_id` values.

**FR-25. Multiplexing.**
The provider handles up to `max_concurrency` concurrent
`inference_request` messages on a single WebSocket. By default this is
1; higher values are experimental operator overrides per FR-9. Each
concurrent request is tracked by its `request_id`. The provider's
`slots_free` heartbeat field reflects WS-tunneled requests as well as
local HTTP requests.

**FR-26. Cancellation handling.**
On receiving `cancel_request` (§ 6.6), the provider aborts the
in-flight inference for the specified `request_id` within 5 seconds.
The provider sends `inference_response_end` with `status: "cancelled"`
to acknowledge. If the `request_id` is unknown or already completed,
the provider sends `inference_response_end` with
`status: "cancelled"` and `chunks_sent: 0` (idempotent).

**FR-27. Error mapping.**
Inference errors map to `status` values in `inference_response_end`:

| Error condition | `status` value |
|---|---|
| Successful completion | `"complete"` |
| Client cancelled | `"cancelled"` |
| Model not loaded | `"error_model_not_loaded"` |
| Context length exceeded | `"error_context_exceeded"` |
| Queue full | `"error_queue_full"` |
| Internal inference error | `"error_internal"` |

**FR-28. Provider-side write buffer backpressure.**
Per § 6.6 "Backpressure — provider-side write buffer": 256-chunk
buffer per request, pause generation on full, resume at 50%.

**FR-29. Local HTTP server coexistence.**
The provider's local HTTP server (§ 6.0–6.4) continues to run
alongside WS-tunneled inference. WS-tunneled inference is an
additional code path, not a replacement. The local HTTP server is
used for `GET /v1/health` diagnostics and for direct-tunnel buyer
traffic (if the provider also has a public URL).

**FR-30. Drain interaction.**
Coordinator-initiated drain (§ 6.5 drain message) MUST NOT terminate
WS-tunneled inference for in-flight requests. The provider completes
all outstanding `inference_request` responses before closing the
WebSocket. This composes with the v1.1.3 `drainFromCoordinator()` path
(drop WS, keep HTTP, reconnect after grace).

**FR-31. Endpoint URL in hello.**
The provider sends `endpoint_url` in hello per § 6.5 if it has a
configured public URL. If omitted or null, the coordinator treats
this provider as WS-tunneled. See § 6.5 for field semantics.

**FR-32. Hello_ack tier and version fields.**
The provider parses `tier` and `recommended_binary_version` from
hello_ack per § 6.5. Logs the tier on connection. Warns if
binary_version < recommended_binary_version.

### Operations

**FR-18. Health endpoint.**
`GET /v1/health` returns a JSON object with the binary's current state:
model loaded (bool), model id, uptime seconds, requests served (total),
requests in-flight, requests queued, total errors, memory usage (RSS),
current health state (from FR-15), and the per-tier capacity values.
This endpoint is unauthenticated and intended for local diagnostics
(the contributor checking their own binary). It is not exposed through
the coordinator. Returns 200 when healthy, 503 when degraded or
unavailable (same JSON body shape, different `status` value).

**FR-19. Configuration layering.**
Configuration is loaded in this precedence order (highest wins):
1. CLI flags (`--port`, `--model`, `--coordinator`, `--config`, etc.)
2. Environment variables (`MACPROVIDER_PORT`, `MACPROVIDER_MODEL`, etc.)
3. Config file (YAML, default path: `~/.config/macprovider/config.yaml`,
   override with `--config` or `MACPROVIDER_CONFIG`)
4. Built-in defaults

The config file schema includes at minimum: `port`, `model` (HuggingFace
model path), `coordinator_url`, `log_format` (`json` or `text`),
`log_file` (optional path; if set, logs are also written to this file),
`max_context_override`, `max_concurrency_override`, `drain_timeout_s`,
`warmup_enabled` (bool), `max_request_body_bytes` (Stage 1 pre-flight limit).

**FR-20. Startup self-test.**
On launch, after loading the model, the binary runs a single short
inference (fixed prompt: `"Hello"`, max_tokens: 5) and verifies that:
- The model produces non-empty output.
- Token counting works (prompt_tokens > 0, completion_tokens > 0).
- Output does not contain leaked stop tokens.
- Wall time is under 30 seconds.

If the self-test fails, the binary logs the failure details and exits
with code 1. The self-test result (throughput in tok/s) is used as the
`throughput_tps_estimate` in FR-17.

---

## 5. Non-functional requirements

**NFR-1. Throughput parity.**
The binary achieves at least 90% of `mlx_lm.server`'s throughput on an
identical model and hardware configuration, measured as tokens per second
on a standardized 200-token generation from a 500-token prompt. Both
streaming and non-streaming modes meet this bar.

**NFR-2. Cold start time.**
From `macprovider-cli start` to the first request being serviceable
(model loaded, self-test passed, HTTP server listening): under 30
seconds on M4 hardware with a 7B 4-bit model. Under 60 seconds on M1
8GB with a 3B 4-bit model.

**NFR-3. Memory stability.**
Under sustained load (continuous requests at 80% of max concurrency for
24 hours), RSS memory growth does not exceed 5% above the post-startup
baseline. No unbounded growth in heap allocations, file descriptors,
or NIO event loop resources.

**NFR-4. Startup robustness.**
If the model path is invalid, the model files are corrupt, or the model
requires more memory than available, the binary exits with code 1 and
a clear diagnostic message to stderr. It does not hang, segfault, or
leave orphaned Metal processes. The diagnostic message includes: what
failed, the model path attempted, available memory, and a suggested
action. No partial server state is left running.

**NFR-5. Build system.**
Swift Package Manager only. No Xcode project file required (though one
may be generated for IDE convenience). No Xcode-only dependencies.
The binary builds on any Mac with Xcode command-line tools and Swift 5.9+.

**NFR-6. Code signing.**
The release binary is signed with a Developer ID certificate for macOS
Gatekeeper approval. First version is not notarized (notarization
requires an Apple Developer Program subscription and adds review
latency). Contributors may need to right-click -> Open on first launch,
or the operator provides a `xattr -d com.apple.quarantine` instruction.

**NFR-7. Logging.**
All log output goes to stdout in structured JSON lines format by
default. Each log line includes: ISO 8601 timestamp, log level, message,
and structured fields (request_id, model, latency_ms, etc.). A `text`
format option is available for human readability during development.
Log level is configurable via `--log-level` (default: `info`). The
binary never logs prompt content or response content at `info` level
(privacy default). `debug` level may log truncated previews. If
`log_file` is set in config, logs are also appended to that file.

**NFR-8. No network calls on startup except coordinator.**
The binary does not phone home, check for updates, or make any outbound
HTTP requests at startup. The only outbound connection is the optional
coordinator WebSocket. The tokenizer config for stop-token derivation
must be bundled with the model files locally (it is — HuggingFace
model repos include `tokenizer_config.json`).

---

## 6. Interface contracts

### 6.0. Global HTTP behavior

**Unknown paths:** Any request to a path not defined below returns
HTTP 404:
```json
{"error":{"message":"Not found","type":"invalid_request_error","code":"path_not_found"}}
```

**Wrong method:** A request with an unsupported HTTP method returns
HTTP 405 with an `Allow` header listing the supported methods.

**Malformed JSON body:** If the request body of a POST is not valid
JSON, return HTTP 400:
```json
{"error":{"message":"Invalid JSON in request body","type":"invalid_request_error","code":"invalid_json"}}
```

**Streaming errors after headers sent:** If an error occurs after the
SSE response headers have been sent (e.g., inference engine failure
mid-stream), emit a final SSE event with the error, then `[DONE]`:
```
data: {"error":{"message":"Inference engine error","type":"server_error","code":"internal_error"}}

data: [DONE]

```
Do not change the HTTP status code mid-stream.

### 6.1. GET /v1/models

**Request:** No body. No required headers.

**Response (200):**
```json
{
  "object": "list",
  "data": [
    {
      "id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "object": "model",
      "created": 1716768000,
      "owned_by": "macprovider"
    }
  ]
}
```

`created` is the binary's start time as a Unix timestamp. `id` is the
model's HuggingFace identifier as passed in config. `owned_by` is
always `"macprovider"`.

The `id` field returned by `/v1/models` MUST be emitted with
unescaped forward-slash characters (`/`). Producers MUST set their JSON
encoder to suppress the legal-but-cosmetic `\/` escape — for Swift
`JSONEncoder`, this means
`outputFormatting.formUnion(.withoutEscapingSlashes)`.

Consumers MUST tolerate the escaped form `\/` for backward compatibility
with pre-v1.2.4 phase3-binaries (the v1.2.0..v1.2.2 series may emit
either form depending on encoder defaults). RFC 8259 § 7 permits both,
so consumer tolerance is required by spec.

The producer-side MUST applies to v1.2.4 and later. v1.2.3 binary
happens to already comply but was not specifically required to; this
clause catches the spec up to v1.2.3's behavior and locks it for
v1.2.4+.

Example legacy response (with `\/`), which consumers MUST still tolerate:

```json
{
  "object": "list",
  "data": [
    {
      "id": "mlx-community\/Llama-3.2-3B-Instruct-4bit",
      "object": "model",
      "owned_by": "macprovider",
      "created": 0
    }
  ]
}
```

**Response (503):** Returned if model is not loaded.
```json
{
  "error": {
    "message": "Model not loaded",
    "type": "server_error",
    "code": "model_not_loaded"
  }
}
```

### 6.2. POST /v1/chat/completions

#### Request schema

**Required fields:**

| Field | Type | Constraint |
|---|---|---|
| `model` | string | Must match the loaded model's id using ASCII case-insensitive comparison. Mismatch returns 404. |
| `messages` | array | Non-empty array of message objects. |

**Optional fields:**

| Field | Type | Default | Constraint |
|---|---|---|---|
| `max_tokens` | int | Remaining context capacity | Must be > 0 |
| `temperature` | float | 1.0 | 0.0 to 2.0 |
| `top_p` | float | 1.0 | 0.0 to 1.0 |
| `n` | int | 1 | MUST be 1. Values > 1 rejected with 400 (single-tenant). |
| `stream` | bool | false | |
| `stream_options` | object | null | `{include_usage: bool}`. Per FR-7, binary always emits the usage chunk when `stream=true`; a client-provided `include_usage=false` is silently ignored (not an error). Documented to remove ambiguity for buyers expecting strict opt-out semantics. |
| `stop` | string or array | null | Max 4 stop sequences. |
| `presence_penalty` | float | 0.0 | -2.0 to 2.0 |
| `frequency_penalty` | float | 0.0 | -2.0 to 2.0 |
| `seed` | int | null | Passed to MLX for deterministic decoding if supported. |
| `user` | string | null | Logged at DEBUG level for diagnostics only. |
| `response_format` | object | `{type:"text"}` | `type` is `"text"` or `"json_object"`. `"json_object"` engages MLX structured-decoding hint if available. Any other value rejected with 400. |
| `tools` | array | null | Parsed and validated syntactically (see below). |
| `tool_choice` | string or object | null | Parsed, not acted upon in Tier 1. |

Unknown top-level fields are silently ignored (forward-compatible) and
logged at DEBUG level.

The `model` field in `/v1/chat/completions` requests and the `id`
field returned by `/v1/models` are compared case-insensitively in
ASCII by the provider. A request for `Mlx-Community/Llama-...` against
a provider hosting `mlx-community/Llama-...` MUST be served, not
404'd. This matches `mlx_lm.server` behavior and mirrors the existing
case-insensitivity of HTTP header field names (RFC 9110 § 5.1).
Non-ASCII code points in model identifiers are out of scope; provider
behavior with such identifiers is undefined.

#### Per-message validation

Each entry in `messages` must satisfy:

| Role | Required fields | Rules |
|---|---|---|
| `"system"` | `content` (string) | Must be non-empty string. |
| `"user"` | `content` (string) | Must be non-empty string. No multimodal content arrays in Tier 1. |
| `"assistant"` | `content` (string) or `tool_calls` (array) | At least one must be present and non-null. `content` may be null if `tool_calls` is present. Both null/absent -> 400. |
| `"tool"` | `tool_call_id` (string), `content` (string) | Both required. |

Any other `role` value is rejected with 400.

#### Tool-call validation

**`tools` array** (top-level request field): Each tool object must have
`type: "function"` and a `function` object with `name` (string) and
`parameters` (valid JSON Schema object). If any tool is malformed,
reject with 400:
```json
{"error":{"message":"Invalid tools[0]: missing function.name","type":"invalid_request_error","code":"invalid_tools"}}
```

**`tool_calls` in assistant messages** (message history): Each entry
must have `id` (string), `type: "function"`, and `function` with `name`
(string) and `arguments` (string containing valid JSON). If `arguments`
is not valid JSON, reject with 400.

The binary validates tool shapes syntactically but does not execute
tool calls in Tier 1.

#### Validation order

The request handler processes validation in this sequence. The first
failure short-circuits:

| Step | Check | Failure response |
|---|---|---|
| 1 | JSON parse | 400 `invalid_json` |
| 2 | Required fields present (`messages` non-empty) | 400 `invalid_request` |
| 3 | Field types and ranges (temperature, top_p, n, etc.) | 400 `invalid_request` |
| 4 | Per-message role and content validation | 400 `invalid_request` |
| 5 | Tool/tool_call shape validation (if present) | 400 `invalid_tools` |
| 6 | Model match (`model` field vs loaded model, ASCII case-insensitive) | 404 `model_not_found` |
| 7 | Stage 1 pre-flight (envelope bytes) | 413 `context_length_exceeded` |
| 8 | Stage 2 pre-flight (token count) | 413 `context_length_exceeded` |
| 9 | Queue admission | 429 `rate_limit_exceeded` |

#### Non-streaming response (200)

```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1716768000,
  "model": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I help you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 25,
    "completion_tokens": 9,
    "total_tokens": 34
  }
}
```

`id` is a unique identifier per request (format: `chatcmpl-{uuid-hex}`).
`finish_reason` is `"stop"` (natural end or stop token hit) or `"length"`
(max_tokens reached).

#### Error responses

| Status | Condition | Error code |
|---|---|---|
| 400 | Missing/invalid fields, malformed tools, n>1 | `invalid_request` or `invalid_tools` |
| 404 | `model` field doesn't match loaded model | `model_not_found` |
| 413 | Prompt exceeds context capacity (FR-8) | `context_length_exceeded` |
| 429 | Request queue full (FR-11) | `rate_limit_exceeded` |
| 503 | Model not loaded or draining | `model_not_loaded` |

All error responses use the OpenAI error envelope:
```json
{"error":{"message":"...","type":"...","param":null,"code":"..."}}
```

Note: HTTP 500 is not an expected response. Internal inference errors
are caught and returned as structured errors (400 for input issues,
503 for model issues). If a 500 escapes, it indicates a bug in the
binary. See AC-2.

#### v1.3 provider CLI additions (serve + models)

The `macprovider-cli` top-level subcommand inventory gains `models` as
the sixth subcommand alongside the existing `serve`, `status`,
`self-test`, `update`, and `uninstall` commands. The `models`
subcommand has actions `models list`, `models switch <model-id>
[--force]`, and `models status` per SPEC-011 v0.5 §3.1. `--force`
suppresses ONLY the CLI-side cooldown soft guard per SPEC-011 v0.5
R-3.1.3; it does not bypass supported-model validation or concurrent
load rejection.

The `serve` command gains the following additive flags:

- `--supported-models <ids>` — comma-separated list of HuggingFace
  model IDs or local paths per SPEC-010 v1.5 R-3.6.1. Resolution
  priority is CLI > ENV (`MACPROVIDER_SUPPORTED_MODELS`) > config key
  `supported_models: [string]`. Default unset. When unset after
  resolution, the binary MUST send `supported_models: [model_id]`
  (single-entry) on the v2 `auth_request` initial-stage frame per
  SPEC-010 v1.5 R-3.6.2 and AC-19. This single-entry default is the
  L-1 baseline: it does not change observable routing or `/v1/status`
  shape relative to a pre-SPEC-010 binary per SPEC-010 v1.5 §4.1
  back-compat analysis. Local pre-flight per SPEC-010 v1.5 R-3.6.3
  validates `model_id ∈ supported_models` (case-folded), array length
  <= 64, and each entry <= 256 UTF-8 bytes. Validation failures exit
  code 2 with specific stderr per SPEC-010 v1.5 R-3.6.3 / R-3.1.9.
- `--publish-supported-models <bool>` — opt-in flag per SPEC-010
  v1.5 R-3.6.4. Default `false`. Resolution priority is CLI > ENV
  (`MACPROVIDER_PUBLISH_SUPPORTED_MODELS`) > config key
  `publish_supported_models: bool`, mirroring `--supported-models` per
  SPEC-010 v1.5 AC-10. When `true`, populates
  `publishes_supported_models: true` on the v2 `auth_request`
  initial-stage frame per SPEC-010 v1.5 R-3.1.6 and AC-21. When
  `false` (default), the field is omitted from the wire per SPEC-010
  v1.5 AC-21 unless a future locked SPEC-010 revision requires
  explicit `false` emission.
- `--enable-warm-swap` — opt-in gate per SPEC-011 v0.5 R-3.1.0.
  Boolean: presence enables; explicit `=true` / `=false` are supported.
  Default DISABLED. When disabled, the binary MUST NOT open the
  control socket, MUST NOT host the §6.8 state machine (legacy
  synchronous load path remains), and MUST NOT emit `loading` or
  `model_hash` heartbeat fields. This preserves the SPEC-011 v0.5 L-1
  byte-identical default (no NEW SPEC-011 fields, sockets, or state
  appear on the wire or on disk when the flag is absent). This flag
  is exclusive to `serve`; it is not valid on `models <subcommand>`.
- `--swap-drain-timeout-seconds <N>` — drain budget per SPEC-011
  v0.5 §3.4 and R-3.9.1. Default `20`. Range `5 <= N <= 600` per
  SPEC-011 v0.5 R-3.9.1; out-of-range values cause `serve` to exit
  code 2 with stderr diagnostic at startup per R-3.9.1. Only
  meaningful when `--enable-warm-swap` is set.
- `--ctl-socket-path <path>` — override the macOS-native default per
  SPEC-011 v0.5 R-3.1.5. Default `$TMPDIR/macprovider-cli/ctl.sock`,
  resolved via `FileManager.default.temporaryDirectory`. Socket parent
  directory mode is `0700`; socket mode is `0600`. Only meaningful when
  `--enable-warm-swap` is set.
- `--switch-state-path <path>` — override the cooldown state file per
  SPEC-011 v0.5 R-3.1.4. Default
  `$HOME/Library/Application Support/macprovider-cli/last-switch.ts`.

### 6.3. POST /v1/chat/completions (streaming)

**Request:** Same as 6.2, with `"stream": true`.

**Response:** `Content-Type: text/event-stream; charset=utf-8`

First chunk includes `delta.role`:
```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1716768000,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

```

Content chunks:
```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1716768000,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

```

Final content chunk has `finish_reason`:
```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1716768000,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

```

Usage chunk (FR-7), immediately before `[DONE]`:
```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1716768000,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[],"usage":{"prompt_tokens":25,"completion_tokens":9,"total_tokens":34}}

```

Terminator:
```
data: [DONE]

```

Each SSE event is followed by two newlines (`\n\n`). No comment lines.
No blank `data:` lines between events.

### 6.4. GET /v1/health

**Response (200 when healthy, 503 when degraded/unavailable):**
```json
{
  "status": "ready",
  "model": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_loaded": true,
  "uptime_s": 3600,
  "requests_total": 142,
  "requests_in_flight": 1,
  "requests_queued": 0,
  "errors_total": 3,
  "memory_rss_mb": 4200,
  "capacity": {
    "ram_gb": 16,
    "ram_tier": "16GB",
    "max_context_tokens": 50000,
    "max_concurrency": 1,
    "throughput_tps_estimate": 19.8
  }
}
```

Same JSON body shape at both 200 and 503. The `status` field
distinguishes the state.

### 6.5. Coordinator WebSocket envelope

All messages are JSON. Direction indicated as C->P (coordinator to
provider) or P->C (provider to coordinator).

#### Handshake (P->C) — sent on WebSocket open
```json
{
  "type": "hello",
  "version": 1,
  "tier": 1,
  "provider_id": "m4-anon",
  "hostname": "Johns-MacBook-Pro.local",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 1,
  "throughput_tps_estimate": 19.8,
  "binary_version": "0.1.0",
  "attestation": null,
  "endpoint_url": null
}
```

**`provider_id` is normative and stable (v1.1.2 clarification).** It is
the operator-issued identifier that the coordinator looks up in its
static `config.providers[]` map (SPEC-002 v1.0.4 § 7.1, Finding F-2).
The same `provider_id` MUST be reused across reconnects, restarts, and
binary upgrades — it represents the persistent identity of this
provider in the trust pool, not the lifetime of the current process.

Concretely, the phase3-binary obtains `provider_id` from (in priority
order):
1. `--provider-id` CLI flag
2. `MACPROVIDER_PROVIDER_ID` environment variable
3. `provider_id` field in the YAML config file

If none are set, the binary generates a per-instance UUID as a fallback
suitable for development and local testing only. Production
coordinators will reject any unrecognized `provider_id` with WebSocket
close code **4002 `unknown_provider_id`** (per § 6.5 close codes and
SPEC-002 FR-P13), so dev-fallback UUIDs cannot connect to a production
pool without first being enumerated in the coordinator config.

`attestation` is `null` in Tier 1. Tier 2 populates it with the
`AttestationProvider` hook output.

**`endpoint_url` determines inference routing mode (v1.2 addition).**
This field is OPTIONAL (may be absent or null). When present and
non-empty, it declares the provider's HTTPS endpoint for HTTP-
forwarding mode (same as SPEC-002 v1.0.4's static `config.providers[]`
endpoint_url, but now self-reported by the provider). When absent or
null, the provider operates in WS-tunneled mode and receives inference
traffic via § 6.6 messages over this WebSocket.

When `endpoint_url` is absent or null in hello, this is the provider-
side signal for WS-tunneled mode. The coordinator's final mode
determination uses BOTH the hello field AND the static
`config.providers[]` map; see SPEC-002 v1.1.1 § 3 for the complete
mode resolution rule. Existing v1.1.x binaries do not send
`endpoint_url`; the coordinator resolves their mode via the static
config map. Net: zero binary changes required for existing providers.

#### Handshake acknowledgement (C->P)
```json
{
  "type": "hello_ack",
  "coordinator_version": 1,
  "assigned_id": "provider-pool-id",
  "heartbeat_interval_s": 30,
  "tier": "pinned",
  "recommended_binary_version": "1.2.0"
}
```

The coordinator may override the heartbeat interval.

**`tier` and `recommended_binary_version` (v1.2 addition).** Both
fields are OPTIONAL and informational.

`tier` is `"pinned"` or `"provisional"` (see SPEC-002 v1.1 § 7.5 for
admission tier semantics). The provider uses this for display purposes
(e.g., `macprovider-cli status` output) and MUST NOT change its
inference behavior based on tier.

`recommended_binary_version` is a semver string. If the provider's
`binary_version` (from hello) is older than this value, the provider
SHOULD log a warning: "A newer version is available (vX.Y.Z). Run
'macprovider-cli update' to upgrade." The coordinator does NOT enforce
the version — providers running older binaries continue to function.

#### Capacity heartbeat (P->C) — sent every `heartbeat_interval_s`
```json
{
  "type": "heartbeat",
  "status": "ready",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 1,
  "slots_free": 1,
  "slots_total": 1,
  "throughput_tps_estimate": 19.8,
  "requests_served_since_last": 12,
  "avg_latency_ms_since_last": 450.0,
  "throughput_tps_since_last": 18.5
}
```

Static fields (`model_id`, `model_params_b`, `ram_gb`, `max_context_tokens`,
`max_concurrency`) are repeated in every heartbeat so the coordinator can
re-establish state after a coordinator restart without requiring a new
handshake.

#### State update (P->C) — sent on state change, independent of heartbeat
```json
{
  "type": "state_update",
  "state": "degraded",
  "reason": "post-wake warm-up in progress",
  "since": "2026-05-27T14:30:00Z",
  "metrics_snapshot": {
    "slots_free": 1,
    "slots_total": 1,
    "requests_served_since_last": 0,
    "avg_latency_ms_since_last": null,
    "throughput_tps_since_last": null
  }
}
```

`state` is one of `ready`, `busy`, `degraded`, `draining`, `unavailable`.
Fired whenever the state changes, independent of the heartbeat schedule.

#### Drain status (P->C) — sent during drain sequence
```json
{
  "type": "drain_status",
  "phase": "in_progress",
  "inflight_requests": 2,
  "estimated_drain_seconds": 15
}
```

`phase` is `"starting"` (SIGTERM just received), `"in_progress"` (waiting
for in-flight requests), or `"complete"` (all drained, about to close
WebSocket). Sent when the binary enters drain (FR-12) or receives a
coordinator `drain` command.

#### Pre-flight check (C->P) — coordinator asks before routing
```json
{
  "type": "preflight",
  "request_id": "buyer-req-uuid",
  "estimated_tokens": 8500
}
```

#### Pre-flight response (P->C)
```json
{
  "type": "preflight_ack",
  "request_id": "buyer-req-uuid",
  "accepted": true,
  "estimated_wait_ms": 0
}
```

If `accepted` is false, the provider includes a reason and relevant context:

| Reason | Additional fields | Meaning |
|---|---|---|
| `context_exceeds_capacity` | `max_context_tokens` | Prompt too large for this provider |
| `queue_full` | `estimated_wait_ms` | All slots and queue occupied |
| `draining` | — | Provider is shutting down |
| `model_not_loaded` | — | Model failed to load or is loading |
| `unhealthy` | — | Provider in unavailable state |
| `tier_mismatch` | `provider_tier` | Coordinator requested Tier 2 but binary is Tier 1 |

Example rejection:
```json
{
  "type": "preflight_ack",
  "request_id": "buyer-req-uuid",
  "accepted": false,
  "reason": "context_exceeds_capacity",
  "max_context_tokens": 50000
}
```

#### Drain signal (C->P) — coordinator tells provider to stop registering
```json
{
  "type": "drain"
}
```

**Normative (v1.1.3 clarification).** The coordinator-initiated drain
stops *coordinator registration only*. On receipt the provider MUST:

1. Send `state_update` with `state: "draining"`.
2. Send the `drain_status` sequence: `starting` → `in_progress` →
   `complete` (matching the SIGTERM path in FR-12, since the
   coordinator's accounting is symmetric).
3. Wait for in-flight coordinator-routed requests to complete (subject
   to `drain_timeout_s`).
4. Close the WebSocket cleanly (close code 1000).
5. Attempt to reconnect to the coordinator after a grace period
   (recommended: 10–15 s, longer than typical coordinator restart).

After sending `drain_status: complete` and closing the WebSocket, the
provider MUST re-enter the same reconnect loop used at process start.
The first reconnect attempt MUST occur within 15 seconds of the WS
close (matching the coordinator-side grace period defined in SPEC-002
§ 6). If the first three reconnect attempts fail in a row, the provider
MUST log at WARN level with the attempt count and the last error; it
MUST NOT exit the process. The reconnect cadence follows the same
backoff as the initial-connect path.

This requirement exists because conflating drain with process exit was
the bug fixed in v1.1.3 (Entry 18); v1.1.3/v1.1.4 then exposed a second
bug where reconnect was structurally enabled but not exercised
post-drain. The implementation MUST treat post-drain reconnect as a
first-class path with its own test coverage, not a side effect of the
connect loop's natural retry.

The provider MUST NOT terminate its local buyer HTTP server in
response to this message. The local server continues to serve
direct-to-tunnel buyer traffic (e.g., `https://m4.streamvc.live/...`)
across the coordinator's drain/restart cycle. Coordinator drain is
about pool membership, not provider lifetime.

The local SIGTERM drain (FR-12) is the only path that ends the
provider process. Implementations MUST keep these two drain paths
distinct — conflating them (i.e., calling `exit()` on coordinator
drain) breaks tunnel-direct buyer traffic during every coordinator
restart and is a critical bug. This was discovered the hard way in
phase3-binary v1.1.2 during the first coordinator redeploy on
2026-05-28 (see Decision log Entry 15).

#### Warm-up command (C->P)
```json
{
  "type": "warm_up"
}
```

Provider runs the warm-up inference (FR-16) and responds with a
`state_update` transitioning to `ready`.

#### Negative acknowledgement (P->C) — protocol error response
```json
{
  "type": "nak",
  "in_reply_to": "preflight",
  "error": {
    "code": "unknown_message_type",
    "message": "Unrecognized message type: 'foo'"
  }
}
```

Sent when the binary receives a malformed or unrecognized coordinator
message. The binary continues operating; a `nak` is informational.

### 6.6. Inference message types (WS-tunneled mode)

**Normative scope.** This section applies ONLY to providers operating
in WS-tunneled mode (determined by the absence of `endpoint_url` in
their `hello` AND the absence of a corresponding `endpoint_url` in the
coordinator's `config.providers[]` entry). Providers operating in
HTTP-forwarding mode MUST NEVER receive these messages from the
coordinator. If an HTTP-forwarding provider receives an
`inference_request`, it SHOULD respond with
`nak code=unknown_message_type` per § 6.5 nak semantics.

Four message types enable the coordinator to deliver buyer inference
requests to providers over the existing WebSocket connection, receive
streamed responses, and propagate cancellations.

#### inference_request (C→P)

Sent by the coordinator when routing a buyer request to a WS-tunneled
provider.

```json
{
  "type": "inference_request",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "stream": true,
  "body": "{\"model\":\"mlx-community/Qwen2.5-7B-Instruct-4bit\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":100,\"stream\":true}"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"inference_request"` |
| `request_id` | string | Yes | UUID assigned by coordinator. Format: `req-{uuid}`. Used for response correlation and cancellation. |
| `stream` | boolean | Yes | Whether the buyer requested streaming. Determines whether the provider sends `inference_response_chunk` per token (true) or a single chunk with the full response (false). |
| `body` | string | Yes | The buyer's original request body, JSON-serialized as a string. The provider parses this as if it were a `POST /v1/chat/completions` request body per § 6.2. |

**Why `body` is a string, not an embedded object:** The buyer's
request may contain fields the coordinator does not parse
(forward-compat). Serializing as a string preserves the exact byte
sequence, avoiding any JSON round-trip lossy-ness (e.g., floating-point
precision, key ordering). The provider parses `body` through its
existing request validation pipeline (§ 6.2).

**Size limit:** The coordinator MUST NOT send an `inference_request`
whose total WS frame size exceeds 16 MB. This accommodates the largest
legal request body (10 MB per FR-8 Stage 1) plus envelope overhead.

#### inference_response_chunk (P→C)

Sent by the provider for each SSE chunk (streaming) or for the
complete response (non-streaming).

```json
{
  "type": "inference_response_chunk",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "seq": 0,
  "data": "data: {\"id\":\"chatcmpl-abc123\",\"object\":\"chat.completion.chunk\",\"created\":1716768000,\"model\":\"mlx-community/Qwen2.5-7B-Instruct-4bit\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"inference_response_chunk"` |
| `request_id` | string | Yes | Matches the `inference_request.request_id` |
| `seq` | integer | Yes | Zero-based monotonically increasing sequence number within this `request_id`. Used for gap detection and debugging. |
| `data` | string | Yes | For streaming: one SSE event line (including `data: ` prefix and trailing `\n\n`). For non-streaming: the complete JSON response body (no SSE framing). |

**Streaming (`stream: true`):** The provider emits one
`inference_response_chunk` per SSE event that it would have written
to an HTTP response. This includes the `data: [DONE]\n\n` event,
sent as the final chunk before `inference_response_end`.

**Non-streaming (`stream: false`):** The provider emits a single
`inference_response_chunk` with `seq: 0` containing the complete JSON
response body (same shape as § 6.2 non-streaming response). The `data`
field contains the raw JSON string (no `data: ` prefix, no SSE framing).

#### inference_response_end (P→C)

Sent by the provider when inference is complete, cancelled, or failed.

```json
{
  "type": "inference_response_end",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "status": "complete",
  "chunks_sent": 47,
  "usage": {
    "prompt_tokens": 25,
    "completion_tokens": 46,
    "total_tokens": 71
  }
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"inference_response_end"` |
| `request_id` | string | Yes | Matches the `inference_request.request_id` |
| `status` | string | Yes | One of: `"complete"`, `"cancelled"`, `"error_model_not_loaded"`, `"error_context_exceeded"`, `"error_queue_full"`, `"error_internal"` |
| `chunks_sent` | integer | Yes | Total `inference_response_chunk` messages sent for this request. Coordinator verifies it received all chunks. |
| `usage` | object | No | Token usage. Present when `status` is `"complete"` and when `status` is `"cancelled"` in response to `cancel_request`. Contains `prompt_tokens`, `completion_tokens`, `total_tokens`. |
| `error` | string | No | Human-readable error message. Present when `status` starts with `"error_"`. |

When `inference_response_end` is sent in response to a `cancel_request`
(per § 6.6's cancel handling), the provider MUST include a `usage` field
in the `inference_response_end` message with:

- `prompt_tokens`: the tokens consumed for the input prompt.
- `completion_tokens`: the actual number of tokens generated before
  cancellation was honored (may be 0 if cancel arrived before generation
  started).
- `total_tokens`: `prompt_tokens + completion_tokens`.

This requirement enables downstream consumers (gateways per SPEC-006,
accounting systems, billing infrastructure) to settle usage exactly
rather than estimating. Estimation produces small but consistent under-
or over-counts that compound across high-volume cancellation scenarios.

Pre-v1.2.4 phase3-binaries (v1.2.3 and earlier) MAY omit the `usage`
field in cancel-response `inference_response_end`. Consumers SHOULD
fall back to estimation when usage is absent (gateway example:
`ceil(bytes_emitted_so_far / 4)` per SPEC-006 v0.4 D-CROSS-1).

**Invariant:** After sending `inference_response_end`, the provider
MUST NOT send any more `inference_response_chunk` messages for that
`request_id`.

#### cancel_request (C→P)

Sent by the coordinator when the buyer disconnects or the request
times out.

```json
{
  "type": "cancel_request",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "reason": "buyer_disconnected"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"cancel_request"` |
| `request_id` | string | Yes | The `request_id` of the inference to cancel |
| `reason` | string | Yes | One of: `"buyer_disconnected"`, `"timeout"`, `"coordinator_shutdown"` |

**Provider behavior on receipt:**
1. If the `request_id` is currently being processed: abort inference,
   release the slot, send `inference_response_end` with
   `status: "cancelled"`.
2. If the `request_id` is unknown (already completed or never
   received): send `inference_response_end` with
   `status: "cancelled"` and `chunks_sent: 0`. This is idempotent.
3. If the `request_id` is in the provider's request queue (not yet
   started): remove from queue, send `inference_response_end` with
   `status: "cancelled"` and `chunks_sent: 0`.

#### Request ID lifecycle and error handling

**Unknown request_id (coordinator-side).** If the coordinator receives
an `inference_response_chunk` or `inference_response_end` with a
`request_id` it did not issue (or that has already been cleaned up),
the coordinator MUST log at warn level and discard the frame. The
coordinator MUST NOT propagate unknown-`request_id` data to any buyer.
The coordinator MUST NOT close the WebSocket — the stale frame may be
from a request that completed or timed out moments ago.

**Duplicate active request_id (provider-side).** The coordinator MUST
NEVER reuse a `request_id` while the prior request with that ID is
still in-flight (i.e., no `inference_response_end` received and no
coordinator-side timeout expired). If a provider receives an
`inference_request` with a `request_id` that is already in its active
map, this is a coordinator protocol error. The provider MUST send
`nak` with `code: "duplicate_request_id"` and the original request
continues unaffected. The provider MUST NOT start a second inference
for the duplicate ID.

**Completed request_id cleanup.**
- **Coordinator:** Removes a `request_id` from its active map after
  receiving `inference_response_end` OR after the coordinator-side
  timeout expires (SPEC-002 `routing.request_timeout_s`, default 300 s).
- **Provider:** Removes a `request_id` from its active map upon
  sending `inference_response_end` OR upon receiving `cancel_request`
  and sending the acknowledging `inference_response_end`.

#### Ordering guarantees

**Within a single `request_id`:** The provider MUST send
`inference_response_chunk` messages in `seq` order (0, 1, 2, ...).
The coordinator MUST relay them to the buyer in `seq` order. If a
chunk arrives out of order, the coordinator buffers it for up to 5
seconds waiting for the missing chunk. If the gap is not filled, the
coordinator treats it as a provider error, sends `cancel_request`, and
returns HTTP 502 to the buyer.

**Across `request_id` values:** No ordering guarantee. Chunks from
different requests may interleave freely. The `request_id` is the
demultiplexing key.

#### Multiplexing

A single provider WebSocket carries up to N concurrent inference
requests, where N is the provider's advertised `max_concurrency` (from
`hello`/`heartbeat`). By default N is 1; higher values are explicit
operator overrides. The coordinator MUST NOT send more than N
concurrent `inference_request` messages. Each WS text frame is one
complete JSON message — no multi-frame messages, no application-layer
fragmentation.

#### Retransmission policy

**No retransmission at the application layer.** If the WS connection
drops, all outstanding requests on that connection are failed. TCP
guarantees in-order delivery on an established connection. WS frame
loss only happens on connection failure, at which point all in-flight
state is lost. Application-layer retransmission adds complexity without
benefit for the v1 single-WS architecture.

#### Backpressure — provider-side write buffer

The provider maintains a bounded write buffer for outgoing
`inference_response_chunk` messages per active `request_id`:

- **Buffer size:** 256 chunks per request. At 30 tok/s, this absorbs
  ~8.5 seconds of WS write latency.
- **High-water behavior:** If the per-request buffer fills, the
  provider pauses token generation for that request. The provider
  MUST NOT drop chunks — every generated token must be delivered or
  the response is corrupt.
- **Buffer drain:** The provider resumes generation when the buffer
  drops below 50% capacity (128 chunks). This hysteresis prevents
  rapid pause/resume oscillation.

### 6.7. v2 `auth_request` handshake (NEW in v1.3)

Locked SPEC-001 v1.2.4 §6.5 documents the legacy `hello` handshake.
The v2 `auth_request` two-stage handshake has been in code since
SPEC-001 v1.2.x but was never normatively documented in SPEC-001; this
section closes that gap. The legacy `hello` handshake at §6.5 remains
the back-compat reconnect path. The v2 `auth_request` handshake is the
modern first-connect path that supports the SPEC-010 fields and the
SPEC-008 Tier-2 attestation hooks.

#### 6.7.1. Initial-stage frame (P->C)

R-6.7.1 The binary MUST send the v2 initial-stage frame with
`type == "auth_request"`, `version == 2`, and `stage == "initial"` per
SPEC-010 v1.5 R-3.1.1 through R-3.1.10 and the parser-required field
table in SPEC-010 v1.5 §3.1.A.

The initial-stage frame field table is the SPEC-010 v1.5 §3.1.A table:

| Field | JSON name | Type | Parser requiredness | Notes |
|---|---|---|---|---|
| Message type | `type` | string, exactly `"auth_request"` | REQUIRED by frame validator | parser rejects with `bad_message_type` otherwise |
| Protocol version | `version` | int, exactly `2` | REQUIRED by frame validator | parser rejects with `bad_version` otherwise |
| Stage | `stage` | string, exactly `"initial"` here | REQUIRED by frame validator | parser routes to `parseAuthInitial` for `"initial"`, `parseAuthProof` for `"proof"` |
| Provider ID | `provider_id` | string ULID | REQUIRED by `parseAuthInitial` | |
| Hostname | `hostname` | string | REQUIRED by `parseAuthInitial` | struct tag is `omitempty` but parser requires it |
| Loaded model | `model_id` | string | REQUIRED by `parseAuthInitial` | struct tag is `omitempty` but parser requires it |
| Model hash | `model_hash` | string sha256-hex | optional | SPEC-008 Pillar A |
| Model params (B) | `model_params_b` | float | REQUIRED by `parseAuthInitial` | |
| RAM (GB) | `ram_gb` | int | REQUIRED by `parseAuthInitial` | |
| Max context tokens | `max_context_tokens` | int | REQUIRED by `parseAuthInitial` | |
| Max concurrency | `max_concurrency` | int | REQUIRED by `parseAuthInitial` | |
| Throughput TPS estimate | `throughput_tps_estimate` | float | REQUIRED by `parseAuthInitial` | |
| Model load time | `model_load_time_ms` | int64 | optional | |
| Binary version | `binary_version` | string | REQUIRED by `parseAuthInitial` | |
| Endpoint URL | `endpoint_url` | string pointer (nullable) | optional | |
| Provider ECDH public key | `provider_ecdh_public_key` | string base64 | REQUIRED by `parseAuthInitial` | SPEC-008 Tier-2 |
| Tier-2 capabilities | `tier2_capabilities` | object `{encrypted_leg: bool, attestation: bool, aead_suites: []string}` | REQUIRED by `parseAuthInitial` | SPEC-008 Tier-2 |
| Supported models | `supported_models` | array of strings | optional, ADDED by SPEC-010 v1.5 | rules per SPEC-010 v1.5 R-3.1.1 through R-3.1.9 and R-3.6.1 through R-3.6.3 |
| Publishes supported models | `publishes_supported_models` | bool | optional, ADDED by SPEC-010 v1.5 | rules per SPEC-010 v1.5 R-3.1.6 and R-3.6.4 |

R-6.7.2 The binary MUST populate the frame from the same flag
resolution as legacy `hello`: `provider_id` from CLI > ENV > config and
`model_id` from `--model`, plus SPEC-010 fields resolved per §6.2 and
SPEC-010 v1.5 R-3.6.1 through R-3.6.4.

R-6.7.3 The `supported_models[]` and `publishes_supported_models`
fields are SPEC-010 fields controlled by `--supported-models` /
`--publish-supported-models` per SPEC-010 v1.5 R-3.6.1 and R-3.6.4,
independent of the SPEC-011 heartbeat/control-socket gate per
SPEC-011 v0.5 R-3.1.0 and R-3.3.0. `supported_models[]` is ALWAYS
emitted by a v1.3 binary on the v2 `auth_request` initial-stage
frame: when `--supported-models` is set after CLI/ENV/config
resolution, the resolved list is emitted; when unset, the binary
MUST emit `supported_models: [model_id]` (single-entry) per SPEC-010
v1.5 R-3.6.2 and AC-19. `publishes_supported_models` is the bool
that the operator opts into; when `false` (default), the field is
OMITTED from the wire per SPEC-010 v1.5 AC-21; when `true`, the
field is emitted as `publishes_supported_models: true`. They MUST
NOT be treated as warm-swap heartbeat fields.

Wire example with all parser-required fields plus SPEC-010 additions
(structure copied from SPEC-010 v1.5 §3.1.B):

```json
{
  "type": "auth_request",
  "version": 2,
  "stage": "initial",
  "provider_id": "p_01HK4Z3VYE...",
  "hostname": "mac-mini-01.local",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.6,
  "ram_gb": 64,
  "max_context_tokens": 32768,
  "max_concurrency": 1,
  "throughput_tps_estimate": 42.5,
  "binary_version": "1.3.0",
  "provider_ecdh_public_key": "<base64url-32-byte-x25519-public-key>",
  "tier2_capabilities": {
    "encrypted_leg": false,
    "attestation": false,
    "aead_suites": []
  },
  "supported_models": [
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/Llama-3.1-8B-Instruct-4bit",
    "mlx-community/Mistral-7B-Instruct-v0.3-4bit"
  ],
  "publishes_supported_models": true
}
```

Tier-2 fields (`provider_ecdh_public_key`, `tier2_capabilities`) are
parser-required in the v2 initial-stage frame and remain handled by the
existing SPEC-008 v0.3 §5.3-§5.7 pipeline. v1.3 adds no encrypted-leg,
attestation, or TEE behavior beyond current SPEC-008 scope.

#### 6.7.2. Proof-stage frame (P->C)

R-6.7.4 The binary MUST send the v2 proof-stage frame with the
SPEC-010 v1.5 §3.1.C field set and MUST echo the coordinator-generated
`auth_attempt_id` from the prior `auth_challenge` per SPEC-010 v1.5
R-3.1.10.

| Field | JSON name | Type | Parser requiredness | Notes |
|---|---|---|---|---|
| Message type | `type` | string, exactly `"auth_request"` | REQUIRED by frame validator | shared with initial stage |
| Protocol version | `version` | int, exactly `2` | REQUIRED by frame validator | shared with initial stage |
| Stage | `stage` | string, exactly `"proof"` | REQUIRED by frame validator | parser routes to `parseAuthProof` |
| Auth attempt ID | `auth_attempt_id` | string | REQUIRED by `parseAuthProof` | echoes coordinator-generated value from prior `auth_challenge` |
| Provider ID | `provider_id` | string | REQUIRED by `parseAuthProof` | must match initial-stage provider ID |
| Attestation token | `attestation_token` | JSON raw | conditional per SPEC-008 Tier-2 | |
| Supported models | `supported_models` | array of strings | optional, ADDED by SPEC-010 v1.5 R-3.1.10 | absent is not a mismatch |
| Publishes supported models | `publishes_supported_models` | bool | optional, ADDED by SPEC-010 v1.5 R-3.1.10 | absent is not a mismatch |

R-6.7.5 The coordinator generates `auth_attempt_id` at
`phase4-coordinator/internal/ws/server.go:354`
(`authAttemptID := "auth-" + s.newUUID()`). The binary MUST NOT
generate this value; it echoes the value received on `auth_challenge`
on the proof-stage frame per SPEC-010 v1.5 R-3.1.10.

R-6.7.6 If the binary re-sends `supported_models[]` or
`publishes_supported_models` on the proof-stage frame, the values MUST
be byte-identical to the initial-stage values per SPEC-010 v1.5
R-3.1.10.

#### 6.7.3. Two opt-ins, four matrix cells

R-6.7.7 The binary MUST treat SPEC-010 catalog publication and
SPEC-011 warm swap as orthogonal opt-ins per SPEC-010 v1.5 R-3.6.1 /
R-3.6.4 and SPEC-011 v0.5 R-3.1.0 / R-3.3.0.

| `--supported-models` | `--enable-warm-swap` | Behavior cell |
|---|---|---|
| unset | unset | LEGACY-EQUIVALENT: v2 `auth_request` initial-stage frame emits `supported_models: [model_id]` (single-entry) per SPEC-010 v1.5 R-3.6.2 / AC-19; `publishes_supported_models` is OMITTED per SPEC-010 v1.5 R-3.6.4 / AC-21; no `model_hash` or `loading` heartbeat fields per SPEC-011 v0.5 R-3.3.0; no control socket per SPEC-011 v0.5 R-3.1.0. This is the L-1 baseline cell: no NEW SPEC-010 or SPEC-011 surface beyond the single-entry catalog (which SPEC-010 v1.5 §4.1 establishes as observably indistinguishable from a pre-SPEC-010 binary on routing, `/v1/status`, and `/v1/models`). Buyer HTTP behavior is unchanged from SPEC-001 v1.2.4. |
| set | unset | SPEC-010 only: provider publishes the explicit catalog list per SPEC-010 v1.5 R-3.6.1, with `publishes_supported_models: true` (when `--publish-supported-models=true`) per SPEC-010 v1.5 R-3.6.4. No warm swap; no `model_hash` / `loading` heartbeat fields per SPEC-011 v0.5 R-3.3.0; no control socket per SPEC-011 v0.5 R-3.1.0. |
| unset | set | SPEC-011 only: warm swap enabled per SPEC-011 v0.5 R-3.1.0; heartbeat carries `model_hash` / `loading` per SPEC-011 v0.5 R-3.3.0 / R-3.3.1; effective catalog is `supported_models: [model_id]` (single-entry, from R-3.6.2 default resolution) and `publishes_supported_models` remains OMITTED per SPEC-010 v1.5 R-3.6.4 / AC-21. |
| set | set | BOTH: explicit catalog emitted per SPEC-010 v1.5 R-3.6.1 / R-3.6.4 and warm swap surfaces enabled per SPEC-011 v0.5 R-3.1.0 / R-3.3.0. |

#### 6.7.4. Back-compat with legacy hello

R-6.7.8 A v1.3 binary uses v2 `auth_request` for the first connection
attempt with a coordinator per SPEC-010 v1.5 §3.1 and R-3.1.1 through
R-3.1.10, whether or not either opt-in is set.

R-6.7.9 The legacy `hello` handshake at §6.5 remains the reconnect
mid-session path per SPEC-011 v0.5 §3.8 and R-3.8.3, including WS drop
reconnect after a warm-swap-in-flight.

R-6.7.10 A pre-v1.3 (v1.2.x) binary uses legacy `hello` on first
connect; the coordinator accepts both paths per SPEC-010 v1.5 §3.1 and
SPEC-011 v0.5 R-3.8.3 compatibility notes.

### 6.8. Warm-swap opt-in gate + runtime state machine (NEW in v1.3)

SPEC-011 v0.5 §2 L-1 locks the byte-identical default and L-2 locks
operator initiation. The §6.8 state machine, §6.9 control socket, and
§6.10 heartbeat extension activate ONLY when the operator invokes
`serve` with `--enable-warm-swap`. In disabled mode, the binary follows
the SPEC-001 v1.2.4 synchronous-load path: the current `ModelRuntime`
actor populates a single immutable container at boot.

#### 6.8.1. ModelRuntime refactor (REQUIRED when warm swap enabled)

R-6.8.1 When `--enable-warm-swap` is enabled, the existing immutable
`let container` / `let modelID` / `let modelHash` fields in
`ModelRuntime` (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
lines 25-68, 86-147) MUST be refactored to actor-isolated mutable state
per SPEC-011 v0.5 R-3.2.1.

R-6.8.2 The actor MUST expose `currentContainer() -> ModelContainer`
for snapshot reads and `swap(new: ModelContainer, newID: String,
newHash: String)` for atomic replacement per SPEC-011 v0.5 R-3.2.1 and
R-3.2.4.

#### 6.8.2. State enumeration

R-6.8.3 Runtime state values are `ready`, `loading`, `draining`, and
`failed` with the semantics of SPEC-011 v0.5 R-3.2.3. The SPEC-011
v0.5 §3.2 state machine diagram is incorporated by reference and MUST
NOT be redrawn here.

#### 6.8.3. Inference-while-loading rejection

R-6.8.4 In `loading` or `draining`, NEW HTTP inference requests to the
binary MUST be rejected with HTTP 503 and OpenAI envelope
`{error: {type: "service_unavailable", code: "provider_loading"}}` per
SPEC-011 v0.5 R-3.2.3 and R-3.4.4. In-flight requests started in
`ready` MUST continue to completion using their snapshot reference per
SPEC-011 v0.5 R-3.2.2.

#### 6.8.4. No-starve rule

R-6.8.5 The async load task MUST run on Swift task isolation distinct
from the WebSocket receive loop, the WebSocket send loop including
heartbeat emission, and the HTTP inference server accept loop per
SPEC-011 v0.5 R-3.2.5. Heartbeat MUST continue at the negotiated
cadence throughout `loading` and `draining`, anchoring SPEC-002 §11
J.1's v1.1.6 35s heartbeat-miss kill incident as cited by SPEC-011
v0.5 R-3.2.5.

#### 6.8.5. Rollback semantics

R-6.8.6 If async load fails, `current_container` remains unchanged,
state transitions `loading -> failed -> ready`, heartbeat emits
`loading: false` with the OLD `model_id` and OLD `model_hash`, the CLI
receives typed `switch_progress` with `state: "failed"` and REQUIRED
`reason`, and the CLI exits code 5 per SPEC-011 v0.5 R-3.2.6.

#### 6.8.6. Boot path unchanged

R-6.8.7 Startup-time synchronous load (`--model X` at boot) populates
`current_container` once and transitions directly to `ready` without
going through `loading` per SPEC-011 v0.5 R-3.2.7. This preserves
existing boot semantics and L-1 back-compat.

### 6.9. Control socket protocol (NEW in v1.3)

R-6.9.1 The serve process MUST refuse to open the control socket unless
`--enable-warm-swap` was passed to `serve` per SPEC-011 v0.5 R-3.1.0
and R-3.1.5. In disabled mode, the socket MUST be absent.

The macOS-native default path is `$TMPDIR/macprovider-cli/ctl.sock`,
resolved via `FileManager.default.temporaryDirectory`, per SPEC-011
v0.5 R-3.1.5. Why not `$XDG_RUNTIME_DIR`: that variable is a Linux /
freedesktop convention and is not set on stock macOS; SPEC-011 v0.5
R-3.1.5 records the empirical platform check.

#### 6.9.1. Wire format

R-6.9.2 The control socket protocol is newline-delimited JSON and every
frame MUST include a REQUIRED `type` field per SPEC-011 v0.5 R-3.1.5.
Messages with missing or unknown `type` MUST be discarded, and the
receiver MUST close the connection with an error log line per SPEC-011
v0.5 R-3.1.5.

The SPEC-011 v0.5 R-3.1.5 field reference table is incorporated here:
`type`, `target_model_id`, `requested_at_ms`, `accepted`, `reason`,
`current_target`, `seconds_remaining`, `state`, `elapsed_ms`,
`current_model_id`, and `runtime_state` retain the requiredness and
enum constraints from SPEC-011 v0.5 R-3.1.5.

#### 6.9.2. Frame types

R-6.9.3 The binary MUST implement the SPEC-011 v0.5 R-3.1.5 frame
schemas for `switch_request`, `status_request`, `switch_ack`,
`switch_progress`, and `status_response`.

R-6.9.4 `switch_ack` frames MUST include the REQUIRED `type:
"switch_ack"` field and the REQUIRED `accepted` field per SPEC-011
v0.5 R-3.1.5 and R-3.7.3.

#### 6.9.3. Detection precedence

R-6.9.5 The `models` CLI MUST use the SPEC-011 v0.5 R-3.1.5.x
three-case detection precedence: ENOENT exits 4 with
`"macprovider-cli serve is not running on this host (no control socket
at <socket_path>)"`; ECONNREFUSED exits 4 with `"stale control socket
at <socket_path> (no listener); remove the file and restart serve"`;
connect-success plus missing `status_response` within 2s exits 4 with
`"serve is running but warm-swap is not enabled (or serve is
unresponsive); restart serve with --enable-warm-swap"`.

#### 6.9.4. Permissions and lifecycle

R-6.9.6 Socket parent directory mode MUST be `0700` and socket mode
MUST be `0600`; the socket opens on `serve` startup only when
`--enable-warm-swap` is set and closes on `serve` shutdown per
SPEC-011 v0.5 R-3.1.5. Stale-socket reclaim after ECONNREFUSED requires
operator removal of the socket file before restart per SPEC-011 v0.5
R-3.1.5.x case 2.

### 6.10. Heartbeat extension (NEW in v1.3, additive when warm-swap opt-in is enabled)

§6.10 specifies what the BINARY emits. COORDINATOR-side handling,
including the hash-clearing REPLACEMENT for `ApplyHeartbeat` at
`phase4-coordinator/internal/pool/provider.go:411-432`, is covered by
the SPEC-002 v1.3.5 candidate per SPEC-011 v0.5 §6.2 and is NOT in
scope for SPEC-001 v1.3.

#### 6.10.1. Opt-in gating

R-6.10.1 The `model_hash` and `loading` heartbeat fields MUST be
emitted by the binary ONLY when `--enable-warm-swap` is enabled (per
R-3.1.0 of SPEC-011 v0.5); in disabled mode, both fields MUST be omitted
from the wire entirely per SPEC-011 v0.5 R-3.3.0. This preserves L-1
byte-identical default.

#### 6.10.2. Field definitions

R-6.10.2 `model_hash` MUST be a raw 64-character lowercase hex string
matching the output of `modelWeightArtifactManifestHash()` at
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:294-325`
(which formats the SHA-256 of the artifact manifest via the
`hexString()` byte→hex helper at
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:340`) per
SPEC-011 v0.5 R-3.3.1.

R-6.10.3 `loading: bool` MUST reflect the §6.8 state machine:
`true` in `loading` or `draining`, `false` in `ready`, per SPEC-011
v0.5 R-3.3.3 and R-3.2.3.

#### 6.10.3. Emission cadence

R-6.10.4 Heartbeat MUST continue at the SPEC-002 §7.1 negotiated
cadence throughout all state-machine states per SPEC-011 v0.5 R-3.2.5.
The `loading: true` transition is communicated by the first heartbeat
after state enters `loading`; the new `model_hash` is communicated by
the first heartbeat after atomic swap into `ready` per SPEC-011 v0.5
R-3.2.4 step 4.

#### 6.10.4. Hash source-of-truth on reconnect (WS drop)

R-6.10.5 After a WS drop mid-swap, the binary reconnects via legacy
`hello` per SPEC-011 v0.5 §3.8 and R-3.8.3. The `hello.model_hash`
field MUST carry the hash of the container currently referenced by
`current_container` at reconnect time, not the in-progress load target.
If the swap was mid-`loading` when the WS dropped, the load continues
independently of the WS; on reconnect `hello.model_hash` is the OLD
hash, and the next post-reconnect heartbeat carries the new hash once
the swap completes per SPEC-011 v0.5 R-3.8.3.

### 6.11. Concurrent switch + WS drop policies (NEW in v1.3)

#### 6.11.1. Concurrent operator-pushed switch

R-6.11.1 If `models switch <Y>` arrives while a prior `models switch
<X>` is still in `loading` or `draining`, the serve process MUST reply
with typed `switch_ack` `{type: "switch_ack", accepted: false, reason:
"loading_in_progress", current_target: "X"}` per SPEC-011 v0.5 R-3.7.1.
The CLI MUST exit code 3 per SPEC-011 v0.5 R-3.1.2.

R-6.11.2 The serve process MUST NOT queue the second switch per
SPEC-011 v0.5 R-3.7.2.

#### 6.11.2. WS drop mid-load

R-6.11.3 WS drop MUST NOT abort an in-flight load; the in-process state
machine continues independently of WS connectivity per SPEC-011 v0.5
R-3.8.1 and R-3.8.5.

R-6.11.4 Reconnect uses legacy `hello` per SPEC-011 v0.5 R-3.8.3, not
v2 `auth_request`. Reconnect carries the same `provider_id` identity
and the OLD `model_hash` while the load remains in progress, using the
§6.10.4 source-of-truth rule per SPEC-011 v0.5 R-3.8.3.

#### 6.11.3. Cooldown soft guard

R-6.11.5 The CLI tracks last-switch timestamp at the macOS-native state
file path defined by §6.2 `--switch-state-path`; default cooldown window
is 10s and `--force` suppresses ONLY the CLI-side soft guard per
SPEC-011 v0.5 R-3.1.4 and R-3.1.3.

---

## 7. Dependencies and references

### 7.1. Direct dependencies (use as libraries)

| Dependency | License (SPDX) | Version pin | Purpose |
|---|---|---|---|
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-examples) | MIT | Tag `2.29.1`, commit `9bff95ca5f0b9e8c021acc4d71a2bbe4a7441631` (verified 2026-05-27). Build session may bump with documented reason in implementation-notes.html. | MLX model loading and inference |
| [swift-nio](https://github.com/apple/swift-nio) | Apache-2.0 | 2.65.0 (starting pin) | HTTP server and WebSocket client |
| [swift-log](https://github.com/apple/swift-log) | Apache-2.0 | 1.6.0 (starting pin) | Structured logging |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | 1.5.0 (starting pin) | CLI flag parsing |
| [Yams](https://github.com/jpsim/Yams) | MIT | 5.1.0 (starting pin) | YAML config parsing |

**Runtime requirements:** Swift 5.9+, macOS 14+ (Sonoma), Apple Silicon.

Version pins are starting points. The build session may bump versions
after testing, with a documented reason in `implementation-notes.html`.

Provider authentication to coordinator is specified in SPEC-002 and is
out of scope for this binary's wire protocol.

### 7.2 Reference hygiene — strict clean-room for d-inference

This binary is built strict clean-room with respect to d-inference.

PROHIBITED references for this spec and the Phase 3 binary build:
- The d-inference GitHub repository (https://github.com/Layr-Labs/d-inference)
- Any d-inference source files, including the README and config files
- Any third-party analyses that quote or reproduce d-inference source
- Reverse-engineered analyses of any compiled Darkbloom binary

Reason: the DARKBLOOM LICENSE AGREEMENT (Eigen Labs, Inc., copyright 2026;
SPDX NOASSERTION; canonical URL https://github.com/Layr-Labs/d-inference/blob/master/LICENSE
as inspected 2026-05-27) explicitly prohibits in Section 3 the use of the
Software to "provide, operate, or enable any hosted service, platform,
marketplace, or product that offers AI inference coordination, private
inference services, or decentralized compute marketplace capabilities
that compete with Darkbloom." Mac Provider fits this description.

PERMITTED references:
- Darkbloom / Eigen Labs published academic papers (cite by URL/DOI)
- Darkbloom blog posts, conference talks, marketing pages (public)
- Third-party reviews that do NOT reproduce d-inference source
- mlx-swift-lm (MIT, Apple/mlx-swift-examples, unrelated to Darkbloom)
- swift-nio, swift-log, swift-argument-parser (Apache 2.0)
- Yams (MIT)
- Apple MLX documentation
- OpenAI API reference (https://platform.openai.com/docs/api-reference)
- HuggingFace tokenizer_config.json schema
- This repository: Phase 1 results/REPORT.md, Phase 2 DECISION_CRITERIA.md,
  harness.py, workloads_adversarial.py

Patent analysis is separate from license. Darkbloom holds patents around
their privacy/attestation model. Tier 1 of this binary does not implement
that model; Tier 2 hooks are designed-in but unimplemented. Patent risk
analysis for Tier 2 is deferred to its eventual SPEC.

If during implementation you are uncertain how Darkbloom solved a problem,
STOP and add an open question to implementation-notes.html. Do not resolve
it by reading their source.

### 7.3. Public spec sources

- Darkbloom / Eigen Labs published academic papers (cite by URL/DOI)
- [Apple MLX documentation](https://ml-explore.github.io/mlx-swift/latest/)
- [OpenAI API reference](https://platform.openai.com/docs/api-reference/chat)
- [HuggingFace tokenizer_config.json](https://huggingface.co/docs/transformers/main_classes/tokenizer) schema

### 7.4. Internal sources

- Phase 1 evidence: `results/REPORT.md`
- Phase 2 decision log: `beta/DECISION_CRITERIA.md`
- Phase 2 adversarial workloads: `beta/workloads_adversarial.py`
- Phase 2 stop-token derivation: `beta/stop_tokens.py`
- Phase 2 harness: `beta/harness.py`

---

## 8. Phase 1 + 2 findings the binary must encode

This section maps every decision log entry from
`beta/DECISION_CRITERIA.md` to functional requirements.

### Coverage matrix

| Decision log entry | Coverage | FRs | Notes |
|---|---|---|---|
| D1 — 502 vs 530 routing | Fully covered (binary scope) | FR-13, FR-15 | Backoff/tunnel-signal logic is coordinator-side; deferred to SPEC-002 |
| D2 — Post-wake throughput dip | Fully covered | FR-16 | |
| D3 — Stop-token leakage status | Fully covered | FR-6 | Defensive; may be no-op if upstream clean |
| D4 — Cross-provider throughput inversion | Fully covered (binary scope) | FR-17, FR-20 | Buyer-facing model choice is coordinator-side; deferred to SPEC-002 |
| D5 — Timeline compression | Process-only | — | No binary behavior; accelerated Phase 3 timeline by 11 days |

### v1.2.4 audit lesson — advertised vs enforced capability

Advertised provider capability MUST match enforced runtime capability.
Spec values that the code never realizes are a drift class equivalent to
Entry 18's SIGTERM=drain conflation and Entry 19's WithTokenValidator
always-on: both produce silent failures of the form "the system
describes a capability that does not exist in practice." Future spec
revisions documenting capacity MUST cite the code path that realizes
them.

### D1 — 502 vs 530 routing distinction

**Observation:** M4 sleep transition produced two distinct failure modes:
HTTP 502 (Cloudflare tunnel up, mlx_lm.server down, persisted ~14 min)
then HTTP 530 (full tunnel disconnect). Tunnel API `conns_active_at`
lagged actual buyer-visible failure.

**FR mapping:**
- **FR-15** (health state reporting): The binary reports `degraded` vs
  `unavailable` states via `state_update` messages.
- **FR-13** (coordinator WebSocket): Clean WebSocket close protocol
  allows the coordinator to distinguish graceful shutdown from crash.

Backoff behavior (e.g., short 30s retry for degraded providers) and
tunnel-signal monitoring (`cfd_tunnel` connection count) are coordinator
responsibilities, deferred to SPEC-002.

### D2 — Post-wake throughput dip

**Observation:** M4 post-wake first request was -12% throughput vs
baseline. mlx weights survived sleep but first inference was slower.

**FR mapping:**
- **FR-16** (warm-up hook): Binary detects wake events and runs a
  synthetic inference before accepting buyer traffic. Reports `degraded`
  during warm-up, `ready` after.

### D3 — Stop-token leakage status

**Observation:** Day-0 showed 0% stop-token leakage on both Qwen (M4)
and Llama (M1), contradicting Phase 1 which observed leakage on every
short response. Likely upstream `mlx-lm` update fixed stripping.

**FR mapping:**
- **FR-6** (defensive stripping): Still implemented, but no longer
  considered critical-path. The binary reads `tokenizer_config.json`
  and strips defensively. If upstream is clean, the stripping is a no-op
  with negligible cost.

### D4 — Cross-provider throughput inversion

**Observation:** Llama 3B on M1 8GB (22-25 tok/s) outperformed Qwen 7B
on M4 16GB (17-20 tok/s). Even TTFT favored M1 (646 vs 708 ms).

**FR mapping:**
- **FR-17** (capacity includes model + throughput): The capacity
  heartbeat includes `model_params_b` and `throughput_tps_estimate`.
  The coordinator MAY use these to route by actual measured performance.
- **FR-20** (startup self-test): The self-test measures tok/s, which
  becomes the `throughput_tps_estimate` in the capacity advertisement.

Buyer-facing model-size choice or auto-routing by latency/quality
preference is a coordinator responsibility, deferred to SPEC-002.

### D5 — Timeline compression

**Observation:** Day 0 already captured 3 Phase 3 spec changes. 14-day
timeline compressed to 3 days.

**Classification:** Process-only. No binary behavior; this decision
accelerated Phase 3 start by 11 days. Intentionally excluded from FR
mapping per the "every row maps" rule because it has no binary-level
requirement.

### Additional Phase 1 findings (from REPORT.md)

**Metal GPU OOM at ~26K tokens on M1 8GB:**
- **FR-8** (context pre-flight): Tokenize and reject before inference.
- **FR-9** (per-RAM capacity): 8 GB tier capped at 20K tokens.

**SSE keepalive comments (`: keepalive N/M`):**
- **FR-5** (no keepalive comments): Binary generates its own SSE; does
  not proxy `mlx_lm.server`.

**Extra response fields (`system_fingerprint`, `tool_calls`):**
- **FR-2, FR-3**: The binary's responses include only the standard
  OpenAI fields. No extra fields. Clean contract.

**Server stops on client disconnect (BrokenPipeError):**
- **FR-10** (disconnect cleanup): Binary must do at least as well, with
  a guaranteed 5-second slot release.

**mlx_lm.server omits usage from SSE streams:**
- **FR-7** (usage synthesis): Binary counts tokens and emits usage chunk.

---

## 9. Acceptance criteria

**AC-1 through AC-10 must ALL pass for the binary to be considered
build-complete. No partial passes. No operator waivers without an
explicit waiver entry in `implementation-notes.html` explaining why.**

**AC-1. Phase 2 cooperative workload parity.**
All 6 cooperative workloads from `beta/workloads.py` (`short_chat`,
`medium_with_system`, `long_context`, `code_completion`, `agent_style`,
`streaming_check`) pass when the Phase 2 harness targets the binary's
HTTP endpoint instead of `mlx_lm.server`. Pass means: HTTP 200,
response content non-empty, throughput within 10% of Phase 2 baseline
for the same model and hardware. Baseline values are in
`beta/DECISION_CRITERIA.md` pre-launch facts table.

**Run by:** `cd beta && python harness.py --config config-phase3-test.yaml --batch cooperative --verbose`
where `config-phase3-test.yaml` points `tunnel_url` at the binary's local endpoint.
The build session creates this fixture file.

**AC-2. Phase 2 adversarial workload survival.**
Each adversarial workload (`retry_storm`, `concurrent_burst_8way`,
`midstream_disconnect`, `malformed_tool_call`, `long_context_oom_probe`)
must complete with NO HTTP 500 responses. Acceptable responses during
adversarial load are: 200 (success), 400 (malformed request),
413 (payload too large), 429 (rate limited / queue full). The binary
must remain healthy (passes `GET /v1/health` with 200) within 30
seconds of workload completion. Any 500 response or process crash is
a hard failure of AC-2.

**Run by:** `cd beta && python harness.py --config config-phase3-test.yaml --batch adversarial --verbose`

**AC-3. 24-hour soak test.**
On M4 hardware with a 7B 4-bit model, the binary runs for 24 hours
under continuous load (one request every 5 seconds, mixed workloads).
Criteria: zero crashes, zero process restarts, memory RSS growth <5%
from post-startup baseline, no file descriptor leaks, no degradation
in throughput beyond 5% from hour-1 to hour-24.

**Run by:** `phase3-binary/scripts/soak-test.sh` — created during the
build session. Wraps a long-running harness invocation with a
memory-pressure monitor that samples RSS every 60 seconds.

**AC-4. Harness swap compatibility.**
`beta/harness.py` can be configured (by changing `tunnel_url` in
`config-phase3-test.yaml` to the binary's local endpoint) and run with
`--batch cooperative` with zero test failures. The harness's SSE
parsing, stop-token detection, and response validation all pass
without modification.

**Run by:** Same command as AC-1. AC-4 verifies that the existing
harness code requires zero modifications.

**AC-5. Coordinator mock integration.**
The binary connects to a mock coordinator (a simple WebSocket echo
server that validates JSON message shapes) and successfully:
1. Sends a `hello` message with all required fields.
2. Receives a `hello_ack` and honors the `heartbeat_interval_s`.
3. Sends at least 3 capacity heartbeats with all FR-17 fields.
4. Responds to a `preflight` request with a valid `preflight_ack`.
5. Responds to a `drain` command by entering draining state, sending
   `drain_status` messages, and closing the WebSocket.

**Run by:** `phase3-binary/scripts/test-coordinator.sh` — created during
the build session. Spins up a mock WebSocket server that exchanges
handshake, 5 heartbeats, a preflight check, and a drain command.

**AC-6. Graceful SIGTERM drain.**
With 3 in-flight streaming requests, sending SIGTERM causes the binary
to drain all requests to completion within 30 seconds. `drain_status`
messages are logged. Zero mid-stream response truncations. The binary
exits with code 0.

**Run by:** Manual test during build. Start 3 concurrent streaming
requests, send `kill -TERM <pid>`, verify all 3 complete and binary exits 0.

**AC-7. Post-wake warm-up.**
After receiving a `warm_up` command from the coordinator, the first
real request shows throughput within 95% of the long-running baseline
(measured as tok/s on `short_chat` workload).

**Run by:** Send `warm_up` via mock coordinator, then fire `short_chat`
via harness, compare tok/s to baseline from AC-1.

**AC-8. Health endpoint.**
`GET /v1/health` returns 200 with JSON containing at minimum: `status`,
`model`, `uptime_s`, `requests_in_flight`, `requests_queued`,
`capacity.max_concurrency`. Returns 503 with same JSON shape when the
binary is in `degraded` or `unavailable` state.

**Run by:** `curl -s http://localhost:8080/v1/health | python -m json.tool`
during AC-1 run (healthy) and during model-load-failure test (unhealthy).

**AC-9. Config precedence.**
Override `port` at each precedence layer and verify the binary binds
to the correct port: CLI flag beats env var beats config file beats
default.

**Run by:** Manual test during build with 4 invocations.

**AC-10. Startup self-test failure.**
Point the binary at a nonexistent model path. Verify: exits with code 1,
prints diagnostic to stderr, no HTTP server starts, no partial state.

**Run by:** `macprovider-cli --model /nonexistent/path 2>&1; echo "exit: $?"`

**AC-11. WS-tunneled inference (non-streaming).**
A mock coordinator sends `inference_request` with `stream: false` over
the WebSocket. The binary processes it through the existing inference
pipeline, returns `inference_response_chunk` with the complete response
and `inference_response_end` with `status: "complete"`.

**Run by:** `phase3-binary/scripts/test-ws-inference.sh`

**AC-12. WS-tunneled inference (streaming).**
A mock coordinator sends `inference_request` with `stream: true`. The
binary returns multiple `inference_response_chunk` messages (one per
SSE event) with monotonically increasing `seq` values, followed by
`inference_response_end`. Time-to-first-chunk is within 100 ms of the
local HTTP streaming baseline.

**Run by:** `phase3-binary/scripts/test-ws-streaming.sh`

**AC-13. Cancellation acknowledgement.**
A mock coordinator sends `inference_request` then `cancel_request`
after 2 chunks are received. The binary aborts inference and sends
`inference_response_end` with `status: "cancelled"` within 5 seconds.
The request slot is freed (verifiable via `/v1/health`).

**Run by:** `phase3-binary/scripts/test-ws-cancellation.sh`

**AC-14. Concurrent multiplexing.**
A mock coordinator sends 3 concurrent `inference_request` messages
(the binary sets `max_concurrency_override: 3` for the test).
All 3 produce interleaved `inference_response_chunk` messages on the
same WebSocket. All 3 complete successfully with correct `request_id`
correlation.

**Run by:** `phase3-binary/scripts/test-ws-multiplexing.sh`

**AC-15. Backward compatibility — unknown message type.**
A mock coordinator sends `{"type": "inference_request", ...}` to a
binary running in HTTP-forwarding mode (or a v1.1.x binary). The
binary responds with `nak code=unknown_message_type` per § 6.5 nak
semantics. The binary remains healthy and continues heartbeating.

**Run by:** `phase3-binary/scripts/test-ws-nak-fallback.sh`

**AC-16. Post-drain reconnect.**
With the binary running and joined to a local coordinator at
`state: ready`, the operator sends a drain directive (for example,
`POST /admin/drain?provider_id=<id>` on the coordinator's provider
port). The binary MUST:

1. Reply `drain_status: complete` per § 6.5.
2. Close the WS.
3. Within 30 seconds of the close, send a fresh `hello` over a new WS.
4. Reach `state: ready` again in the coordinator pool within 60 seconds
   total elapsed from drain initiation.

**Run by:** Tail both the binary log (look for `reconnect attempt 1`)
and the coordinator's `/poolz` endpoint while issuing the drain
directive.

**AC-17. Cancel-usage normative reporting.**
With the binary running and joined to a local coordinator, the
coordinator sends a `cancel_request` mid-stream after `N` tokens of
generated output. The binary MUST: (1) honor the cancel within the
existing cancellation latency budget; (2) send `inference_response_end`
with `usage.prompt_tokens` > 0, `usage.completion_tokens` == `N` (the
actual generated count), and `usage.total_tokens` ==
`prompt_tokens + N`.

**Run by:** Mock coordinator unit test plus hardware integration test
against a local coordinator.

**AC-18.0. L-1 baseline default — no NEW SPEC-010/SPEC-011 surface.**
A v1.3 binary built per this spec, invoked with neither
`--supported-models` nor `--enable-warm-swap`, MUST satisfy ALL of:
(a) v2 `auth_request` initial-stage frame emits
`supported_models: [model_id]` (single-entry) per SPEC-010 v1.5
R-3.6.2 / AC-19 and OMITS `publishes_supported_models` per SPEC-010
v1.5 R-3.6.4 / AC-21;
(b) heartbeat frame OMITS `model_hash` and `loading` fields entirely
(REAL byte-identical, not "additional fields tolerated") per SPEC-011
v0.5 R-3.3.0 / AC-18;
(c) no control socket file exists at
`$TMPDIR/macprovider-cli/ctl.sock` while serve is running per
SPEC-011 v0.5 R-3.1.0 / R-3.1.5 / AC-18;
(d) coordinator-observable routing, `/v1/status`, and `/v1/models`
behavior is indistinguishable from a pre-SPEC-010 binary per SPEC-010
v1.5 §4.1 back-compat analysis.
This is the L-1 BASELINE cell, scoped to "no NEW SPEC-010/SPEC-011
fields, sockets, or runtime state" — the single-entry catalog default
is part of SPEC-010 v1.5's locked binding contract and is the
back-compat-equivalent baseline. Traces to SPEC-011 v0.5 AC-18 and
SPEC-010 v1.5 AC-2 + AC-19 + AC-21.

**AC-18.1. SPEC-010 opt-in.**
A v1.3 binary invoked with `--supported-models A,B,C
--publish-supported-models=true --model A` MUST send v2
`auth_request` initial-stage with `supported_models: [A, B, C]`,
`publishes_supported_models: true`, and `model_id: A`. Traces to
SPEC-010 v1.5 AC-1 and AC-21.

**AC-18.2. SPEC-010 pre-flight.**
A v1.3 binary invoked with `--supported-models A,B --model C` MUST
exit code 2 BEFORE opening the coordinator WS with stderr containing
`"--model C not in --supported-models"`. Traces to SPEC-010 v1.5 AC-9.

**AC-18.3. SPEC-011 opt-in gate — disabled mode (ENOENT path).**
A v1.3 binary `serve` started without `--enable-warm-swap` MUST NOT
create any file at `$TMPDIR/macprovider-cli/ctl.sock`. A
`macprovider-cli models list` invocation against that binary MUST
take the R-6.9.5 / R-3.1.5.x ENOENT case-1 path: exit code 4 with
stderr containing `"macprovider-cli serve is not running on this
host (no control socket at"` (followed by the resolved socket path).
Traces to SPEC-011 v0.5 AC-18 case-1 and SPEC-001 v1.3 R-6.9.5.

**AC-18.4. SPEC-011 opt-in gate — enabled mode.**
A v1.3 binary `serve --enable-warm-swap` MUST create the control socket
with mode `0600` and parent dir mode `0700`. Traces to SPEC-011 v0.5
AC-22 and AC-26.

**AC-18.5. macOS-native socket path.**
The default control socket path resolves to
`$TMPDIR/macprovider-cli/ctl.sock` via
`FileManager.default.temporaryDirectory`. Linux/freedesktop runtime-dir
environment paths MUST NOT appear anywhere in the binary's runtime path
resolution; they are unset on stock macOS. Traces to SPEC-011 v0.5
AC-26.

**AC-18.6. Atomic swap.**
Under `models switch <Y>` while serving an in-flight inference request,
the in-flight request MUST complete using the OLD weights; a NEW
request arriving AFTER atomic swap completion MUST be served by the NEW
weights. No caller observes mixed state. Traces to SPEC-011 v0.5 AC-9.

**AC-18.7. No-starve heartbeat.**
Heartbeat cadence MUST NOT pause during `loading` or `draining`. A
SPEC-002 §7.1 heartbeat-miss threshold MUST NOT be triggered by a model
swap. Traces to SPEC-011 v0.5 AC-12.

**AC-18.8. Heartbeat hash format.**
When `--enable-warm-swap` is set, `model_hash` on heartbeat frames MUST
be a 64-char lowercase hex string with no `sha256:` prefix and no
uppercase characters. Traces to SPEC-011 v0.5 AC-10 and AC-20.

**AC-18.9. Four matrix cells.**
Test matrix exercises all four cells of the SPEC-010 × SPEC-011 opt-in
matrix per §6.7.3. Each cell's expected wire behavior is verified by
capturing the v2 `auth_request` frame and first heartbeat:
- Cell 1 (unset/unset): frame carries `supported_models: [model_id]`
  per SPEC-010 v1.5 R-3.6.2 / AC-19; OMITS `publishes_supported_models`
  per SPEC-010 v1.5 R-3.6.4 / AC-21; heartbeat OMITS `model_hash` /
  `loading` per SPEC-011 v0.5 R-3.3.0 / AC-18.
- Cell 2 (set/unset): frame carries the explicit `supported_models[]`
  list; `publishes_supported_models: true` when
  `--publish-supported-models=true`; heartbeat OMITS SPEC-011 fields.
- Cell 3 (unset/set): frame carries `supported_models: [model_id]`
  per R-3.6.2; OMITS `publishes_supported_models`; heartbeat carries
  `model_hash` (raw lowercase hex) and `loading` per SPEC-011 v0.5
  R-3.3.1 / AC-10 / AC-20.
- Cell 4 (set/set): frame carries explicit catalog + heartbeat carries
  SPEC-011 fields.
Each cell's expected shape is byte-asserted against the captured frame,
not "additional fields tolerated." Traces to SPEC-010 v1.5 AC-1, AC-2,
AC-19, AC-21 and SPEC-011 v0.5 AC-10, AC-18, AC-20, AC-23.

**AC-18.10. NEW §6.7 v2 handshake documented.**
The SPEC-001 v1.3 §6.7 v2 `auth_request` handshake section is
consistent with the SPEC-010 v1.5 §3.1.A field table by byte-for-byte
field comparison. No field appears in one and not the other. Traces to
SPEC-010 v1.5 AC-16 and AC-18.

**AC-18.11. No drift in §6.5.**
SPEC-001 v1.3 §6.5 (Coordinator WebSocket envelope — legacy `hello`
handshake) is byte-identical to SPEC-001 v1.2.4 §6.5. v1.3 adds the v2
handshake as a new §6.7; it does NOT modify the legacy `hello`
documentation. Verifiable by `diff` of the two versions' §6.5 sections.
Traces to SPEC-011 v0.5 AC-18 and SPEC-010 v1.5 AC-16.

**AC-18.12. Control-socket detection precedence — ECONNREFUSED.**
A v1.3 binary `serve --enable-warm-swap` running with a stale socket
file at `$TMPDIR/macprovider-cli/ctl.sock` left by a prior crashed
process (file exists but no listener) MUST cause `macprovider-cli
models list` to take the R-6.9.5 / R-3.1.5.x ECONNREFUSED case-2
path: exit code 4 with stderr containing `"stale control socket at"`
and `"remove the file and restart serve"`. Traces to SPEC-011 v0.5
R-3.1.5.x case 2 and SPEC-001 v1.3 R-6.9.5.

**AC-18.13. Control-socket detection precedence — handshake timeout.**
If the binary connects to the control socket successfully but no
`status_response` arrives within 2 seconds, `macprovider-cli models
list` MUST take the R-6.9.5 / R-3.1.5.x case-3 path: exit code 4
with stderr containing `"serve is running but warm-swap is not
enabled (or serve is unresponsive)"`. Traces to SPEC-011 v0.5
R-3.1.5.x case 3 and SPEC-001 v1.3 R-6.9.5.

**AC-18.14. Cooldown soft guard + `--force` bypass.**
A v1.3 binary `serve --enable-warm-swap` that has successfully
processed a `models switch <X>` within the last 10 seconds MUST cause
the next `macprovider-cli models switch <Y>` to exit code 6 with
stderr containing `"swap on cooldown for"` and `"Re-issue with
--force to bypass"` per SPEC-011 v0.5 R-3.1.4 / R-3.1.2 step 4. The
same invocation with `--force` MUST bypass ONLY the cooldown soft
guard and proceed to step 4 acceptance (or rejection on other
grounds) per SPEC-011 v0.5 R-3.1.3. `--force` MUST NOT bypass the
SPEC-010 R-3.6.3 pre-flight validation (verified by AC-18.2 path).
Traces to SPEC-011 v0.5 R-3.1.2 / R-3.1.3 / R-3.1.4 and AC-24.

**AC-18.15. WS drop reconnect uses legacy `hello`, not v2.**
A v1.3 binary `serve --enable-warm-swap` whose WebSocket connection
drops mid-load MUST reconnect using the legacy §6.5 `hello`
handshake per R-6.11.4 and SPEC-011 v0.5 R-3.8.3 / §3.8 — NOT a
fresh v2 `auth_request`. The reconnect `hello.model_hash` MUST carry
the hash of the container currently referenced by
`current_container` at reconnect time per R-6.10.5 (the OLD hash if
the swap is still in-flight). The first post-reconnect heartbeat
after atomic swap MUST carry the new `model_hash`. Traces to
SPEC-011 v0.5 R-3.8.3 / §3.8 and SPEC-001 v1.3 R-6.10.5 / R-6.11.4.

**AC-18.16. Runtime state-value enumeration.**
A v1.3 binary `serve --enable-warm-swap` runtime MUST expose
exactly the four observable state values defined in §6.8.2 /
SPEC-011 v0.5 R-3.2.3: `ready`, `loading`, `draining`, `failed`.
Status responses on the control socket MUST report one of `ready`,
`loading`, `draining` per SPEC-011 v0.5 R-3.1.5 `runtime_state`
enum (the `failed` state is internal-only-transient per R-3.2.3 and
MUST NOT appear in `status_response.runtime_state`). Traces to
SPEC-011 v0.5 R-3.2.3 and R-3.1.5 field reference.

---

## 10. Open questions for operator

**OQ-1. Streaming usage chunk — client compatibility.**
FR-7 specifies the usage chunk with `choices: []`. Some clients (e.g.,
LiteLLM, certain OpenAI SDK versions) may not expect a chunk with empty
choices. Alternative: embed usage in the final content chunk alongside
`finish_reason`. The spec picks `choices: []` (matches OpenAI's current
behavior as of May 2025). Operator should confirm which downstream
clients will consume this and test.

**OQ-2. Tier announcement format.**
FR-14 sends `tier: 1` as an integer. Should this be a version string
(`"tier-1"`) or a structured object (`{"level": 1, "capabilities": [...]}`)
to allow for tier 1.5 or partial upgrades? The spec picks integer for
simplicity. Tier 2 SPEC can revisit if needed.

**OQ-3. Binary distribution method.** RESOLVED in SPEC-003 v0.3
FR-C1, FR-C2. Distribution channel is GitHub Releases via
`https://get.streamvc.live/install.sh`. No longer an open question.

**OQ-4. WS frame size limit for large completions.**
A 32K-token streaming response at ~5 bytes/token generates ~160 KB of
SSE data, split across ~32,000 `inference_response_chunk` messages
(one per token). Each chunk is small (~200-500 bytes including
envelope). The concern is not individual frame size but total message
count and WS throughput. At 30 tok/s, that's 30 WS frames/s — well
within typical WS capacity. But a non-streaming response for a 32K
completion would be a single `inference_response_chunk` with a ~200 KB
`data` field, which fits in one WS text frame (gobwas/ws default max:
unbounded; network MTU handles fragmentation).

**Current position:** No explicit frame size limit in the protocol.
The 16 MB coordinator-side limit on `inference_request` (§ 6.6) is
sufficient. Non-streaming responses are bounded by `max_tokens`
(provider-enforced) and should not exceed a few MB. Monitor during
AC-12 testing. If WS throughput is a bottleneck, consider chunking
non-streaming responses.

**OQ-5. Provider-side WS write buffer sizing.**
FR-28 specifies 256 chunks per request as the provider-side write
buffer (§ 6.6 "Backpressure — provider-side write buffer"). This is a
starting estimate — 256 absorbs ~8.5 seconds of WS write latency at
30 tok/s. In practice the buffer should rarely fill because WS writes
are fast on local networks.

**Scope:** This OQ concerns the **provider-side** buffer only
(gobwas/ws or URLSessionWebSocketTask config on the binary). The
coordinator-side write buffer sizing is SPEC-002 v1.1.1 OQ-10.

**Current position:** 256 is a conservative default. Tune based on
production telemetry.

---

## 11. Implementation hand-off

### Hand-off to implementer

The build session should follow this sequence. Each step has a clear
deliverable that can be tested before moving to the next.

**Step 1. Create Swift package.**
Initialize `phase3-binary/` as a Swift Package Manager project. Add
dependencies per Section 7.1 version pins. Verify the package resolves
and compiles an empty main.

**Step 2. CLI entry and config loader.**
Implement argument parsing (FR-19) and YAML config loading. The binary
accepts `--port`, `--model`, `--coordinator`, `--config`, `--log-level`.
Deliverable: `macprovider-cli --help` prints usage.

**Step 3. Model loader.**
Wrap `mlx-swift-lm` to load a model from a HuggingFace path. Read
`tokenizer_config.json` and extract special tokens for FR-6. Deliverable:
binary loads a model and prints its parameter count to stdout.

**Step 4. /v1/models endpoint.**
Stand up a minimal Swift NIO HTTP server. Implement `GET /v1/models`
returning the loaded model, plus global 404/405 handling. Deliverable:
`curl localhost:8080/v1/models` returns valid JSON matching Section 6.1.

**Step 5. /v1/chat/completions non-streaming.**
Implement `POST /v1/chat/completions` with `stream: false`. Wire the
full request validation chain (Section 6.2), inference, stop-token
stripping, and response formatting. Deliverable: valid completion with
usage; malformed requests return 400.

**Step 6. SSE streaming.**
Add `stream: true` support. Implement the SSE framing (FR-4), usage
chunk synthesis (FR-7), and stop-token stripping on streamed tokens.
Deliverable: streaming response with clean deltas, usage chunk before
`[DONE]`.

**Step 7. Context pre-flight and capacity.**
Implement FR-8 (two-stage pre-flight) and FR-9 (per-RAM capacity at
startup). Deliverable: a prompt exceeding the context cap returns
HTTP 413.

**Step 8. Request queue and concurrency.**
Implement FR-11 (bounded queue with HTTP 429). Wire disconnect
detection (FR-10). Deliverable: requests beyond max concurrency are
queued; beyond queue depth get 429.

**Step 9. Coordinator WebSocket client.**
Implement FR-13 (outbound WebSocket), FR-14 (hello + tier), FR-15
(health states + state_update), FR-16 (warm-up), FR-17 (capacity
heartbeat with all fields). Test against a mock WebSocket server.
Deliverable: binary connects, sends hello, heartbeats, responds to
preflight and drain.

**Step 10. Graceful shutdown and self-test.**
Implement FR-12 (SIGTERM drain with drain_status messages) and FR-20
(startup self-test). Deliverable: binary passes self-test on start;
SIGTERM drains and exits cleanly.

**Step 11. Acceptance testing.**
Run AC-1 through AC-10. Fix issues. Deliver a binary that passes all
acceptance criteria.

### File structure (expected)

```
phase3-binary/
├── Package.swift
├── Sources/
│   └── macprovider-cli/
│       ├── main.swift
│       ├── Config.swift                 # FR-19
│       ├── ModelLoader.swift            # Step 3, FR-6
│       ├── StopTokenFilter.swift        # FR-6
│       ├── HTTPServer.swift             # Swift NIO server setup
│       ├── Router.swift                 # Route dispatch, 404/405
│       ├── RequestValidator.swift       # Section 6.2 validation chain
│       ├── ModelsHandler.swift          # FR-1
│       ├── ChatCompletionsHandler.swift # FR-2, FR-3
│       ├── HealthHandler.swift          # FR-18
│       ├── SSEWriter.swift              # FR-4, FR-5, FR-7
│       ├── ContextPreflight.swift       # FR-8 (both stages)
│       ├── CapacityManager.swift        # FR-9, FR-11
│       ├── CoordinatorClient.swift      # FR-13, FR-14, FR-15, FR-17
│       ├── ModelsSubcommand.swift       # §6.2, §6.9 models list/switch/status
│       ├── ControlSocket.swift          # §6.9 newline-delimited JSON control socket
│       ├── RuntimeStateMachine.swift    # §6.8 state machine + atomic swap
│       ├── WarmupManager.swift          # FR-16
│       ├── SelfTest.swift               # FR-20
│       ├── Middleware/
│       │   ├── TrustGate.swift          # Tier 2 hook (passthrough)
│       │   ├── InputDecryptor.swift     # Tier 2 hook (passthrough)
│       │   └── ResponseSeal.swift       # Tier 2 hook (passthrough)
│       └── Logging.swift                # NFR-7
│   └── MacProviderCore/
│       └── SupportedModels.swift        # §6.2 SPEC-010 resolution/pre-flight
├── Tests/
│   └── macprovider-cliTests/
│       ├── RequestValidatorTests.swift
│       ├── StopTokenFilterTests.swift
│       ├── ContextPreflightTests.swift
│       ├── SSEWriterTests.swift
│       ├── CoordinatorClientTests.swift
│       └── CapacityManagerTests.swift
├── scripts/
│   ├── soak-test.sh                     # AC-3
│   └── test-coordinator.sh              # AC-5
├── implementation-notes.html            # Populated by build session
└── THIRD_PARTY_NOTICES.md
```

Expected v1.3 implementation modifications to existing files:

- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` —
  refactored per §6.8.1 from immutable `let` fields to actor-isolated
  mutable `current_container`.
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` —
  extended v2 `auth_request` builder to emit SPEC-010 fields when
  opt-in flags are set; heartbeat builder gains opt-in-gated
  `model_hash` / `loading` fields per §6.10. Existing `helloMessage`
  hash source-of-truth follows §6.10.4 on reconnect.
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` — adds
  `models` subcommand to the existing subcommand list (currently lines
  7-15).

---

## Appendix A: References used during spec writing

| Source | What was taken |
|---|---|
| `HANDOFF.md` | Full project context, Phase 1 findings, strategic decisions, differentiation |
| `results/REPORT.md` | Phase 1 evidence: OOM at ~26K, SSE quirks, latency data, concurrency data |
| `beta/PHASE2_UPGRADED_PLAN.md` | Phase 2 design upgrades: adversarial crons, corpus sampling, companion telemetry |
| `beta/DECISION_CRITERIA.md` | Decision log entries D1-D5: 502/530 routing, post-wake dip, stop-token status, throughput inversion, timeline compression |
| `beta/harness.py` | SSE parsing approach, per-model leak detection pattern, adversarial workload runner interface |
| `beta/workloads_adversarial.py` | Adversarial workload definitions: retry_storm, OOM probe, burst, disconnect, malformed |
| `beta/stop_tokens.py` | Stop-token derivation from tokenizer_config.json: extraction logic, caching, fallback |
| OpenAI API reference | Chat completions request/response schema, SSE streaming format, error envelope |
| `specs/SPEC-001-audit.md` | Audit findings (2 CRITICAL, 17 MAJOR, 9 MINOR) driving v1.1 revision |

**Clean-room note:** v1.0 (2026-05-27) consulted the d-inference public
README for repo structure and license verification. v1.1 established
strict clean-room policy (Section 7.2). No d-inference source files
were read during either v1.0 or v1.1. The v1.0 README consultation
predates the clean-room policy and is recorded here for transparency.
No further d-inference references are permitted.
