# SPEC-001 — Phase 3 Binary: Mac Provider Inference CLI

**Version:** 1.1.2 (2026-05-28, normative provider_id clarification — see Decision log Entry 13)
**Revision:** v1.1.1 addressed audit findings from `specs/SPEC-001-audit.md`. v1.1.2 clarifies provider_id semantics to match SPEC-002 v1.0.4 § 7.1.

**Change log since v1.1.1:**
- § 6.5 hello message: `provider_id` field now explicitly normative — it is the operator-issued stable identifier from SPEC-002's static `config.providers[]` map. Example value updated; misleading "uuid-of-this-instance" placeholder removed.
- § 6.5 added normative paragraph immediately after the hello example explaining the relationship to SPEC-002 Finding F-2 and what happens on mismatch (WS close 4002 `unknown_provider_id`).
- No FR changes. v1.1.2 is documentation-only — the phase3-binary implementation already gained config/env/CLI support for stable provider_id in the same patch cycle.

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
hardware tier, and computes a safe maximum context length and concurrency
limit. Starting estimates (refined by runtime measurement):

| RAM tier | Max context (tokens) | Max concurrency | Rationale |
|---|---|---|---|
| 8 GB | 20,000 | 1 | Phase 1: OOM at ~26K on M1 8GB; 20K with headroom |
| 16 GB | 50,000 | 2 | Proportional from 8 GB data; KV cache scales linearly |
| 32 GB | 120,000 | 4 | Conservative for large models |
| 64 GB+ | 200,000 | 8 | Upper bound; model-dependent |

These values are defaults. The config file can override them per tier.
If the binary detects available memory at startup is significantly less
than expected for the tier (e.g., heavy background apps), it logs a
warning and reduces the advertised capacity proportionally.

**FR-10. Mid-stream disconnect cleanup.**
When a client disconnects during a streaming response, the binary
detects the broken connection (via NIO channel close event), cancels
the in-flight inference task, and releases the request slot. The slot
must be available for a new request within 5 seconds of disconnect
detection. Phase 2 adversarial testing (`midstream_disconnect` workload)
found `mlx_lm.server` handles this via `BrokenPipeError`; the binary
must do at least as well, without leaking long-running generation.

**FR-11. Concurrent request handling with bounded queue.**
The binary accepts multiple simultaneous requests up to the concurrency
limit for the hardware tier (FR-9). Requests beyond the limit are
queued. If the queue exceeds a configurable depth (default: 2x
concurrency limit), new requests are rejected with HTTP 429 and a
`Retry-After` header estimating when a slot may free up. The queue
is FIFO with no time-based eviction in v1. Queued requests that are
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
- `max_concurrency`: computed from FR-9
- `slots_free`: real-time availability (matches heartbeat schema in § 6.5)
- `slots_total`: total inference slots configured for this provider
- `throughput_tps_estimate`: measured tok/s from the startup self-test
- `ram_gb`: total system RAM

The coordinator MAY use these fields to route by actual measured
performance rather than assumed hardware capability. The binary's
responsibility ends at sending accurate values.

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
| `model` | string | Must match the loaded model's id. Mismatch returns 404. |
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
| 6 | Model match (`model` field vs loaded model) | 404 `model_not_found` |
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
    "max_concurrency": 2,
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
  "max_concurrency": 2,
  "throughput_tps_estimate": 19.8,
  "binary_version": "0.1.0",
  "attestation": null
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

#### Handshake acknowledgement (C->P)
```json
{
  "type": "hello_ack",
  "coordinator_version": 1,
  "assigned_id": "provider-pool-id",
  "heartbeat_interval_s": 30
}
```

The coordinator may override the heartbeat interval.

#### Capacity heartbeat (P->C) — sent every `heartbeat_interval_s`
```json
{
  "type": "heartbeat",
  "status": "ready",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 2,
  "slots_free": 1,
  "slots_total": 2,
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
    "slots_free": 2,
    "slots_total": 2,
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

#### Drain signal (C->P) — coordinator tells provider to stop
```json
{
  "type": "drain"
}
```

Provider responds by entering the `draining` state (same as SIGTERM
behavior in FR-12), sends `drain_status` updates, then closes the
WebSocket cleanly after all in-flight requests complete.

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

**OQ-3. Binary distribution method.**
NFR-6 specifies code signing. How does the binary reach contributors?
Options: GitHub Releases download, Homebrew tap, direct link from
operator. The spec does not specify distribution — that's an operational
decision. Homebrew tap would be the smoothest contributor experience.

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
│       ├── WarmupManager.swift          # FR-16
│       ├── SelfTest.swift               # FR-20
│       ├── Middleware/
│       │   ├── TrustGate.swift          # Tier 2 hook (passthrough)
│       │   ├── InputDecryptor.swift     # Tier 2 hook (passthrough)
│       │   └── ResponseSeal.swift       # Tier 2 hook (passthrough)
│       └── Logging.swift                # NFR-7
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
