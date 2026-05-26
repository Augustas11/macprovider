# SPEC-001 — Phase 3 Binary: Mac Provider Inference CLI

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
- Context length pre-flight: tokenize prompt, reject with HTTP 413 if exceeds safe capacity
- Per-RAM-tier capacity computation at startup (8 GB, 16 GB, 32 GB+ tiers)
- Bounded concurrent request queue with configurable max concurrency
- Mid-stream client disconnect detection and slot release within 5 seconds
- Graceful SIGTERM handling: drain in-flight requests before exit
- Outbound coordinator WebSocket client (connects to configurable URL)
- Coordinator handshake with tier, model, capacity, and throughput metadata
- Capacity heartbeat at configurable interval
- Health state reporting over WebSocket (awake, degraded, unreachable distinction)
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
- Secure enclave key derivation for identity binding

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
│  │  │ Request Router   │   /v1/models              │            │    │
│  │  │ /v1/models       │──→ static JSON            │            │    │
│  │  │ /v1/chat/complet │                            │            │    │
│  │  │ /v1/health       │──→ health JSON             │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           │ /v1/chat/completions                  │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Context          │  Tokenize prompt,          │            │    │
│  │  │ Pre-flight       │  check against RAM cap.    │            │    │
│  │  │                  │  Reject → HTTP 413         │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐  ← TIER 2 HOOK POINT      │            │    │
│  │  │ [TrustGate]      │  Tier 1: passthrough       │            │    │
│  │  │                  │  Tier 2: attestation check  │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐  ← TIER 2 HOOK POINT      │            │    │
│  │  │ [InputDecryptor] │  Tier 1: passthrough       │            │    │
│  │  │                  │  Tier 2: decrypt prompt     │            │    │
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
│  │  └────────────────────────────────┬───────────────┘          │    │
│  │                                    │                          │    │
│  │                                    ▼                          │    │
│  │  ┌─────────────────┐  ← TIER 2 HOOK POINT                   │    │
│  │  │ [ResponseSeal]   │  Tier 1: passthrough                    │    │
│  │  │                  │  Tier 2: sign/encrypt output            │    │
│  │  └────────┬────────┘                                         │    │
│  │           ▼                                                   │    │
│  │  ┌──────────────────────────────────────────────────┐        │    │
│  │  │ Response Formatter                                │        │    │
│  │  │ • Stop-token stripping                            │        │    │
│  │  │ • SSE framing (data: prefix, [DONE])              │        │    │
│  │  │ • Usage chunk synthesis (streaming)               │        │    │
│  │  │ • Non-streaming JSON envelope                     │        │    │
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
│  │  │ Inbound commands: pre-flight, drain, warm-up     │       │    │
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

### Tier 2 hook points summary

| Hook point | Location | Tier 1 behavior | Tier 2 behavior |
|---|---|---|---|
| `TrustGate` | Request chain, after pre-flight | Passthrough (all requests accepted) | Validate buyer attestation token |
| `InputDecryptor` | Request chain, before inference | Passthrough (plaintext prompts) | Decrypt buyer-encrypted prompt |
| `ResponseSeal` | Response chain, after inference | Passthrough (plaintext output) | Sign or encrypt output |
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

**FR-3. Chat completions — streaming.**
`POST /v1/chat/completions` with `stream: true` returns an SSE stream
of chat completion chunks. Each chunk is a valid OpenAI-format delta.
The stream terminates with `data: [DONE]`.

**FR-4. SSE stream format compliance.**
Every SSE line in a streaming response uses the `data: ` prefix (with
exactly one space). No blank `data:` lines between chunks. Each
`data: {...}` payload is valid JSON. The final line is `data: [DONE]`.
Content-Type header is `text/event-stream; charset=utf-8`. Connection
is not chunked-transfer but true SSE.

**FR-5. No SSE keepalive comments.**
The binary never emits SSE comment lines (lines starting with `:`).
Phase 1 found `mlx_lm.server` emits `: keepalive N/M` lines that break
strict SSE parsers. This quirk is eliminated — the binary controls the
SSE output directly.

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

**FR-8. Context length pre-flight.**
Before submitting a request to the inference engine, the binary tokenizes
the full prompt (system + messages) using the loaded model's tokenizer
and computes the expected token count. If the count exceeds the safe
context capacity for the current hardware tier (see FR-9), the request
is rejected with HTTP 413 and a JSON error body:
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
is FIFO. Queued requests that are cancelled by the client before
reaching the inference engine are silently removed from the queue.

**FR-12. Graceful SIGTERM drain.**
On receiving SIGTERM, the binary:
1. Stops accepting new HTTP connections.
2. Sends a `drain` status to the coordinator (if connected).
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

**FR-14. Tier capability announcement.**
On successful WebSocket handshake, the binary sends a `hello` message
that includes `tier: 1`. This field is the Tier 2 upgrade vector — a
future binary version sends `tier: 2` with an attached attestation blob
from the `AttestationProvider` hook. The coordinator uses this to
advertise tier-aware routing to buyers.

**FR-15. Health state reporting.**
The binary reports its health state to the coordinator via the WebSocket.
States, informed by Phase 2 decision log entry D1 (502 vs 530 routing):

| State | Meaning | Coordinator action |
|---|---|---|
| `ready` | Accepting requests, model loaded | Route traffic normally |
| `busy` | All request slots occupied | Hold traffic, retry in ~5s |
| `degraded` | Post-wake warm-up in progress (see FR-16) | Hold traffic briefly |
| `draining` | SIGTERM received, finishing in-flight | Stop routing, wait for close |
| `unavailable` | Model load failed or fatal error | Remove from pool |

State transitions are sent as WebSocket messages whenever the state
changes. The coordinator should interpret a WebSocket close without a
prior `draining` message as an unclean disconnect (the 530-equivalent
from D1) and remove the provider from the pool until reconnection.

**FR-16. Post-wake warm-up hook.**
Phase 2 decision log entry D2 found a -12% throughput dip on the first
request after a Mac wakes from sleep. The binary detects wake events
(via IOKit power notifications or by detecting that wall-clock time
jumped forward significantly since last activity) and runs a synthetic
warm-up inference (a short fixed prompt, result discarded) before
transitioning from `degraded` to `ready`. During warm-up, the binary
reports `degraded` state to the coordinator, which should not route
buyer traffic until `ready` resumes.

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
- `current_slots_free`: real-time availability
- `throughput_tps_estimate`: measured tok/s from the startup self-test
- `ram_gb`: total system RAM

The coordinator cannot assume bigger Mac = faster. It must route by
`throughput_tps_estimate` and `max_context_tokens` to match buyer
requests optimally.

### Operations

**FR-18. Health endpoint.**
`GET /v1/health` returns a JSON object with the binary's current state:
model loaded (bool), model id, uptime seconds, requests served (total),
requests in-flight, requests queued, total errors, memory usage (RSS),
current health state (from FR-15), and the per-tier capacity values.
This endpoint is unauthenticated and intended for local diagnostics
(the contributor checking their own binary). It is not exposed through
the coordinator.

**FR-19. Configuration layering.**
Configuration is loaded in this precedence order (highest wins):
1. CLI flags (`--port`, `--model`, `--coordinator`, `--config`, etc.)
2. Environment variables (`MACPROVIDER_PORT`, `MACPROVIDER_MODEL`, etc.)
3. Config file (YAML, default path: `~/.macprovider/config.yaml`)
4. Built-in defaults

The config file schema includes at minimum: `port`, `model` (HuggingFace
model path), `coordinator_url`, `log_format` (`json` or `text`),
`max_context_override`, `max_concurrency_override`, `drain_timeout_s`,
`warmup_enabled` (bool).

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
a clear diagnostic message. It does not hang, segfault, or leave
orphaned Metal processes. The diagnostic message includes: what failed,
the model path attempted, available memory, and a suggested action.

**NFR-5. Build system.**
Swift Package Manager only. No Xcode project file required (though one
may be generated for IDE convenience). No Xcode-only dependencies. The
binary builds with `swift build -c release` on any Mac with Xcode
command-line tools and Swift 5.9+.

**NFR-6. Code signing.**
The release binary is signed with a Developer ID certificate for macOS
Gatekeeper approval. First version is not notarized (notarization
requires an Apple Developer Program subscription and adds review
latency). Contributors may need to right-click → Open on first launch,
or the operator provides a `xattr -d com.apple.quarantine` instruction.

**NFR-7. Logging.**
All log output goes to stdout in structured JSON lines format by
default. Each log line includes: ISO 8601 timestamp, log level, message,
and structured fields (request_id, model, latency_ms, etc.). A `text`
format option is available for human readability during development.
Log level is configurable via `--log-level` (default: `info`). The
binary never logs prompt content or response content at `info` level
(privacy default). `debug` level may log truncated previews.

**NFR-8. No network calls on startup except coordinator.**
The binary does not phone home, check for updates, or make any outbound
HTTP requests at startup. The only outbound connection is the optional
coordinator WebSocket. The tokenizer config for stop-token derivation
must be bundled with the model files locally (it is — HuggingFace
model repos include `tokenizer_config.json`).

---

## 6. Interface contracts

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

### 6.2. POST /v1/chat/completions (non-streaming)

**Request:**
```json
{
  "model": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Hello"}
  ],
  "max_tokens": 200,
  "temperature": 0.7,
  "top_p": 0.9,
  "stream": false,
  "stop": ["STOP"]
}
```

Required fields: `messages` (array of `{role, content}` objects).
Optional fields: `model` (ignored — uses loaded model), `max_tokens`
(default: 512), `temperature` (default: 1.0), `top_p` (default: 1.0),
`stream` (default: false), `stop` (array of strings, optional).
`tool_calls`, `tools`, `response_format`, and other OpenAI fields are
accepted and silently ignored in Tier 1 (forward-compatible).

**Response (200):**
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
`finish_reason` is `"stop"` (natural end or stop token hit), `"length"`
(max_tokens reached), or `"content_filter"` (reserved for Tier 2).

**Error responses:**

| Status | Condition | Error code |
|---|---|---|
| 400 | Missing or invalid `messages` | `invalid_request` |
| 413 | Prompt exceeds context capacity (FR-8) | `context_length_exceeded` |
| 429 | Request queue full (FR-11) | `rate_limit_exceeded` |
| 500 | Inference engine error | `internal_error` |
| 503 | Model not loaded or draining | `model_not_loaded` |

All error responses use the OpenAI error envelope:
```json
{"error": {"message": "...", "type": "...", "param": null, "code": "..."}}
```

### 6.3. POST /v1/chat/completions (streaming)

**Request:** Same as 6.2, with `"stream": true`.

**Response:** `Content-Type: text/event-stream; charset=utf-8`

Each SSE event:
```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1716768000,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

```

First chunk includes `delta.role`:
```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1716768000,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

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

**Response (200):**
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

### 6.5. Coordinator WebSocket envelope

All messages are JSON. Direction indicated as C→P (coordinator to
provider) or P→C (provider to coordinator).

#### Handshake (P→C) — sent on WebSocket open
```json
{
  "type": "hello",
  "version": 1,
  "tier": 1,
  "provider_id": "uuid-of-this-instance",
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

`attestation` is `null` in Tier 1. Tier 2 populates it with the
`AttestationProvider` hook output.

#### Handshake acknowledgement (C→P)
```json
{
  "type": "hello_ack",
  "coordinator_version": 1,
  "assigned_id": "provider-pool-id",
  "heartbeat_interval_s": 30
}
```

The coordinator may override the heartbeat interval.

#### Capacity heartbeat (P→C) — sent every `heartbeat_interval_s`
```json
{
  "type": "heartbeat",
  "status": "ready",
  "slots_free": 1,
  "slots_total": 2,
  "requests_served_since_last": 12,
  "avg_latency_ms_since_last": 450.0,
  "throughput_tps_since_last": 18.5
}
```

`status` is one of the health states from FR-15.

#### Pre-flight check (C→P) — coordinator asks before routing
```json
{
  "type": "preflight",
  "request_id": "buyer-req-uuid",
  "estimated_tokens": 8500
}
```

#### Pre-flight response (P→C)
```json
{
  "type": "preflight_ack",
  "request_id": "buyer-req-uuid",
  "can_serve": true,
  "estimated_wait_ms": 0
}
```

If `can_serve` is false, the provider includes a reason:
```json
{
  "type": "preflight_ack",
  "request_id": "buyer-req-uuid",
  "can_serve": false,
  "reason": "context_exceeds_capacity"
}
```

#### Drain signal (C→P) — coordinator tells provider to stop
```json
{
  "type": "drain"
}
```

Provider responds by entering the `draining` state (same as SIGTERM
behavior in FR-12) and sends state updates until all in-flight requests
complete, then closes the WebSocket cleanly.

#### Warm-up command (C→P)
```json
{
  "type": "warm_up"
}
```

Provider runs the warm-up inference (FR-16) and responds with a
state transition to `ready` via the next heartbeat.

---

## 7. Dependencies and references

### 7.1. Direct dependencies (use as libraries)

| Dependency | License (SPDX) | Purpose |
|---|---|---|
| [mlx-swift-lm](https://github.com/apple/mlx-swift-examples) | MIT | MLX model loading and inference |
| [swift-nio](https://github.com/apple/swift-nio) | Apache-2.0 | HTTP server and WebSocket client |
| [swift-log](https://github.com/apple/swift-log) | Apache-2.0 | Structured logging |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | CLI flag parsing |
| [Yams](https://github.com/jpsim/Yams) | MIT | YAML config parsing |

**Runtime requirements:** Swift 5.9+, macOS 14+ (Sonoma), Apple Silicon.

### 7.2. Reference implementation (study with discipline)

**Darkbloom d-inference** — https://github.com/layr-labs/d-inference

- **License:** Proprietary, all rights reserved. **Not open source.**
  SPDX: `LicenseRef-Proprietary`
- **Operating principle:** Informed by, not copied. The build prompt and
  this spec originally assumed d-inference was open source. Verification
  at spec-write time (2026-05-27) confirmed the license is proprietary.
  This strengthens the decision to build our own binary rather than fork.
- **Repo structure observed:** `coordinator/`, `provider/`,
  `provider-swift/`, `console-ui/`, `landing/`, `libs/`, `enclave/`,
  `deploy/`, `docs/`, `scripts/`, `tests/`, `e2e/`, `papers/`
- **What was studied from the public README:** That the Swift provider
  uses `mlx-swift-lm` for inference via Metal, confirming our dependency
  choice. Architecture shape (coordinator + provider + Swift CLI).
- **PERMITTED conceptual study (public README and non-privacy source):**
  Server bootstrap pattern, `mlx-swift-lm` wiring, OpenAI HTTP compat
  layer shape, SSE streaming approach, model loading, graceful shutdown.
- **NOT studied, NOT replicated:** Privacy modules, attestation,
  secure enclave, key derivation, sealed encryption. Directories:
  `enclave/`, anything with `privacy`, `attest`, `sealed`, `crypto`
  in the path. Their privacy stack is patented.
- **Attribution:** The shipped binary includes a `THIRD_PARTY_NOTICES.md`
  crediting Darkbloom d-inference as architectural reference for
  non-privacy components, citing the proprietary license.

### 7.3. Public spec sources

- Darkbloom academic paper (conceptual architecture reference)
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

### D1 — 502 vs 530 routing distinction

**Observation:** M4 sleep transition produced two distinct failure modes:
HTTP 502 (Cloudflare tunnel up, mlx_lm.server down, persisted ~14 min)
then HTTP 530 (full tunnel disconnect). Tunnel API `conns_active_at`
lagged actual buyer-visible failure.

**FR mapping:**
- **FR-15** (health state reporting): The binary reports `degraded` vs
  `unavailable` states. The coordinator distinguishes these: `degraded`
  means "hold traffic, may recover soon" (the 502 equivalent); a
  WebSocket close without `draining` means "remove from pool" (the 530
  equivalent).
- **FR-13** (coordinator WebSocket): Clean WebSocket close protocol
  ensures the coordinator can distinguish graceful shutdown from crash.

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
  heartbeat includes `model_params_b` and `throughput_tps_estimate` so
  the coordinator can route by actual measured performance, not assumed
  hardware superiority.
- **FR-20** (startup self-test): The self-test measures tok/s, which
  becomes the `throughput_tps_estimate` in the capacity advertisement.

### D5 — Timeline compression

**Observation:** Day 0 already captured 3 Phase 3 spec changes. 14-day
timeline compressed to 3 days.

**FR mapping:** No direct FR. This decision accelerated Phase 3 start
by 11 days. The binary spec (this document) benefits from landing sooner
while Phase 2 data is fresh.

### Additional Phase 1 findings (from REPORT.md)

**Metal GPU OOM at ~26K tokens on M1 8GB:**
- **FR-8** (context pre-flight): Tokenize and reject before inference.
- **FR-9** (per-RAM capacity): 8 GB tier capped at 20K tokens.

**SSE keepalive comments (`: keepalive N/M`):**
- **FR-5** (no keepalive comments): Binary controls SSE output directly.

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

**AC-1. Phase 2 cooperative workload parity.**
All 6 cooperative workloads from `beta/workloads.py` (`short_chat`,
`medium_with_system`, `long_context`, `code_completion`, `agent_style`,
`streaming_check`) pass when the Phase 2 harness (`beta/harness.py`)
targets the binary's HTTP endpoint instead of `mlx_lm.server`. Pass
means: HTTP 200, response content non-empty, throughput within 10% of
Phase 2 baseline for the same model and hardware. Baseline values are
in `beta/DECISION_CRITERIA.md` pre-launch facts table.

**AC-2. Phase 2 adversarial workload survival.**
All 5 adversarial workloads from `beta/workloads_adversarial.py`
(`retry_storm`, `long_context_oom_probe`, `concurrent_burst_8way`,
`midstream_disconnect`, `malformed_tool_call`) complete without
crashing the binary or its host process. "Complete" means the binary
is still serving requests after each workload finishes. The binary
may return error responses (429, 413, 500) during adversarial load;
it must not crash, hang, or require restart.

**AC-3. 24-hour soak test.**
On M4 hardware with a 7B 4-bit model, the binary runs for 24 hours
under continuous load (one request every 5 seconds, mixed workloads).
Criteria: zero crashes, zero process restarts, memory RSS growth <5%
from post-startup baseline, no file descriptor leaks, no degradation
in throughput beyond 5% from hour-1 to hour-24.

**AC-4. Harness swap compatibility.**
`beta/harness.py` can be configured (by changing `tunnel_url` in
`config.yaml` to the binary's local endpoint) and run with
`--batch cooperative` with zero test failures. The harness's SSE
parsing, stop-token detection, and response validation all pass
without modification.

**AC-5. Coordinator mock integration.**
The binary connects to a mock coordinator (a simple WebSocket echo
server that validates JSON message shapes) and successfully:
1. Sends a `hello` message with all required fields.
2. Receives a `hello_ack` and honors the `heartbeat_interval_s`.
3. Sends at least 3 capacity heartbeats.
4. Responds to a `preflight` request with a valid `preflight_ack`.
5. Responds to a `drain` command by entering draining state and
   closing the WebSocket after in-flight requests complete.

---

## 10. Open questions for operator

**OQ-1. Streaming usage chunk — client compatibility.**
FR-7 specifies the usage chunk with `choices: []`. Some clients (e.g.,
LiteLLM, certain OpenAI SDK versions) may not expect a chunk with empty
choices. Alternative: embed usage in the final content chunk alongside
`finish_reason`. The spec picks `choices: []` (matches OpenAI's current
behavior as of May 2025). Operator should confirm which downstream
clients will consume this and test.

**OQ-2. Model field in request — honor or ignore?**
The spec (FR-2) says the `model` field in the request body is ignored
because the binary loads a single model. Alternative: if the `model`
field doesn't match the loaded model, return HTTP 404. This would be
more correct but could break clients that hardcode a different model
name. Spec picks "ignore" for maximum compatibility. Revisit if
multi-model support is added.

**OQ-3. Coordinator URL discovery.**
FR-13 specifies three discovery methods: CLI flag, env var, config file.
Should there be a fourth: mDNS/Bonjour discovery for a coordinator
running on the local network? This could simplify local development but
adds complexity. The spec omits it — the coordinator URL is always
explicit. Operator confirm.

**OQ-4. Logging destination.**
NFR-7 sends all logs to stdout, suitable for `launchd` / Console.app
capture. Should the binary also write to a local SQLite database (like
the Phase 2 companion script) for self-reporting? This would let the
contributor see their own stats without the operator's report. The spec
omits it — stdout only for v1. The `/v1/health` endpoint provides
real-time stats. A future version could add a `--log-db` option.

**OQ-5. Tier announcement format.**
FR-14 sends `tier: 1` as an integer. Should this be a version string
(`"tier-1"`) or a structured object (`{"level": 1, "capabilities": [...]}`)
to allow for tier 1.5 or partial upgrades? The spec picks integer for
simplicity. Tier 2 SPEC can revisit if needed.

**OQ-6. Config file location.**
FR-19 defaults to `~/.macprovider/config.yaml`. Alternative:
`~/.config/macprovider/config.yaml` (XDG convention) or alongside the
binary. The spec picks `~/.macprovider/` because it matches the Phase 2
companion script's location and is Mac-conventional. Operator confirm.

**OQ-7. WebSocket authentication.**
FR-13 specifies a bare WebSocket connection to the coordinator. In
production, the coordinator will need to authenticate providers. Should
the binary include a bearer token in the WebSocket upgrade headers?
The spec leaves this as a coordinator-side design decision (Phase 4
SPEC). The binary should accept a `coordinator_token` config field and
send it as a Bearer token in the upgrade request if present.

**OQ-8. Queue behavior under sustained overload.**
FR-11 rejects with HTTP 429 when the queue is full. Should the queue
have a time-based eviction (e.g., queued requests older than 30 seconds
auto-rejected)? Long queue wait times degrade buyer experience. The
spec picks fixed-depth FIFO with no timeout. Operator may want
time-based eviction added.

**OQ-9. Binary distribution method.**
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
dependencies: `mlx-swift-lm`, `swift-nio`, `swift-log`,
`swift-argument-parser`, `Yams`. Verify `swift build` compiles an
empty main.

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
returning the loaded model. Deliverable: `curl localhost:8080/v1/models`
returns valid JSON matching Section 6.1.

**Step 5. /v1/chat/completions non-streaming.**
Implement `POST /v1/chat/completions` with `stream: false`. Wire
request parsing, inference, stop-token stripping, and response
formatting. Deliverable: `curl -X POST ... -d '{"messages":[...]}'`
returns a valid completion with usage.

**Step 6. SSE streaming.**
Add `stream: true` support. Implement the SSE framing (FR-4), usage
chunk synthesis (FR-7), and stop-token stripping on streamed tokens.
Deliverable: streaming response with no keepalive comments, clean
deltas, usage chunk before `[DONE]`.

**Step 7. Context pre-flight and capacity.**
Implement FR-8 (tokenize and reject) and FR-9 (per-RAM capacity at
startup). Deliverable: a prompt exceeding the context cap returns
HTTP 413.

**Step 8. Request queue and concurrency.**
Implement FR-11 (bounded queue with HTTP 429). Wire disconnect
detection (FR-10). Deliverable: requests beyond max concurrency are
queued; beyond queue depth get 429.

**Step 9. Coordinator WebSocket client.**
Implement FR-13 (outbound WebSocket), FR-14 (hello + tier), FR-15
(health states), FR-16 (warm-up), FR-17 (capacity heartbeat). Test
against a mock WebSocket server. Deliverable: binary connects, sends
hello, heartbeats, responds to preflight and drain.

**Step 10. Graceful shutdown and self-test.**
Implement FR-12 (SIGTERM drain) and FR-20 (startup self-test).
Deliverable: binary passes self-test on start; SIGTERM drains and exits
cleanly.

**Step 11. Acceptance testing.**
Run AC-1 through AC-5. Fix issues. Deliver a binary that passes all
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
│       ├── Router.swift                 # Route dispatch
│       ├── ModelsHandler.swift          # FR-1
│       ├── ChatCompletionsHandler.swift # FR-2, FR-3
│       ├── HealthHandler.swift          # FR-18
│       ├── SSEWriter.swift              # FR-4, FR-5, FR-7
│       ├── ContextPreflight.swift       # FR-8
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
│       ├── StopTokenFilterTests.swift
│       ├── ContextPreflightTests.swift
│       ├── SSEWriterTests.swift
│       ├── CoordinatorClientTests.swift
│       └── CapacityManagerTests.swift
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
| d-inference GitHub README (https://github.com/layr-labs/d-inference) | Repo structure, license verification (proprietary), confirmation that mlx-swift-lm is used for Metal inference |
| OpenAI API reference | Chat completions request/response schema, SSE streaming format, error envelope |

**d-inference files NOT opened:** Any file in `enclave/`, `privacy/`,
`attestation/`, `sealed/`, `crypto/` directories, or any file with
`privacy`, `attest`, `sealed`, or `crypto` in the path. Only the
public README and repo file listing were consulted.
