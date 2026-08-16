# SPEC-018 v0.2 — Design Synthesis

**Date:** 2026-06-27
**Anchor framework:** Cline (locked)
**Scope:** 4 deliverables (#1 multi-turn, #4 streaming, #6 tool_call_id, #7 byte cap). #2 registry, #3 prompt-echo, #5 malformed signal **deferred to v0.3**.
**Source:** Codex 4-lane design pass (`specs/DESIGN_SPEC_018_v0_2_0N_*.md`) on top of locked SPEC-018 v0.1.5.

This document synthesizes the codex design pass into a coherent v0.2 design plan. It is **input to** the v0.2 BUILD SPEC prompt, not the SPEC itself. The SPEC body is drafted next; codex audit-loop applies before lock.

---

## 1. Scope decision (locked)

**Question:** is SPEC-018 v0.2 the full agentic product, or the narrowest "Cline drop-in works" surface?

**Answer:** narrow. v0.2 ships the minimum set required for "point Cline at coordinator.malibu.tech → Cline completes a real multi-turn coding session." The strategic governance layer (#2 model-hash registry), defense-in-depth (#3 prompt-echo guard), and buyer-side diagnostics (#5 structured `malformed_tool_call` signal) move to v0.3 — they are real and we will want them, but they are not blocking the Cline drop-in promise.

**v0.3 already designed** (codex pass complete, files preserved under `specs/v0_3-design/`): registry options A/B/C with curation models; prompt-echo incremental detector with 256-byte tolerance; structured `usage.macprovider_malformed_tool_call` schema with 6-value `reason` enum.

## 2. Anchor framework + v0.2 release gate

Cline is the v0.2 release-gate framework. Other §1-listed frameworks (Aider, OpenCode, Continue, Vercel AI SDK, LangChain ChatOpenAI, LlamaIndex OpenAI, Pydantic-AI OpenAIModel, n8n) are best-effort observation only — they may piggyback compatibility but do not gate release.

**v0.2 release pass criteria** (combined from codex #1 + #4 + #7):

1. Cline session runs end-to-end through gateway → coordinator → v0.2 phase3 provider (not direct provider-only).
2. ≥ 20 provider turns after the initial user request.
3. ≥ 30 total tool calls/results across the session.
4. Tool surface MUST include: `list_files`, `search_files`, `read_file`, `write_to_file` (or equivalent edit tool), `execute_command`. `browser_action` is optional.
5. ≥ 3 file edits across ≥ 2 files.
6. ≥ 2 `execute_command` runs, with at least one failing command followed by a successful recovery turn.
7. ≥ 1 assistant-history `tool_calls[]` echo + matching `role:"tool"` result after turn 1.
8. ≥ 1 `write_to_file` of ≥ 64 KiB content with incremental stream visibility (first `function.arguments` delta within 1500 ms of provider recognizing the tool-call opening; ≥ 3 deltas before `finish_reason:"tool_calls"`).
9. Session completes with no `unsupported_tool_messages`, no provider-side 5xx, no malformed pre-commit tool delta.

---

## 3. Deliverable #1 — Multi-turn provider acceptance (closes AC-14)

### Normative posture: stateless OpenAI-replay-compatible

Provider accepts full `messages[]` replay each turn. No session-scoped state. Buyer is responsible for replaying conversation history. Provider validates only the in-request tool-call chain.

### Code locations (live in `/Users/augstar/macprovider-spec-018-v0-2/`)

**Current rejection paths to remove:**
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:909` `validateToolCallingV1Scope`
- Call sites: `:344` (`acquireRequestHandle` pre-streaming), `:395` (`completeWithServedSnapshot` pre-non-streaming)
- Exact rejection: `:924` (rejects `role:"tool"` with HTTP 400 `unsupported_tool_messages`), `:931` (rejects assistant `tool_calls[]` same code)

**Implementation catch (load-bearing):**
`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:194` already validates assistant `tool_calls[]`, `:202` already validates tool messages, BUT `ChatMessage` struct at `:175` stores only `role` + `content`. **Deleting the rejection alone is insufficient** — assistant `tool_calls` and `tool_call_id` would be silently lost before prompt rendering.

**Required edits:**
- Extend `ChatMessage` to preserve `toolCallID: String?` and `toolCalls: [ToolCall]?` fields
- Replace `request.messages.map { $0.mlxMessage }` at `ModelRuntime.swift:374`, `:428`, `:513` with a renderer that has access to the full OpenAI message objects
- Add `phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift` — selects Qwen/Llama prompt-history rendering by family. Family selection uses modelID-match in v0.2 (same rule as parser side per v0.1.5 §3.2); model_hash-binding moves with v0.3 #2 registry.

### MLX chat-template threading

The parser-family registry should NOT also own the inverse renderer. Output parsing (markup → OpenAI shape) and history rendering (OpenAI shape → native markup) are related but distinct concerns. Add a **separate tool prompt-template profile** keyed by family — registered alongside the parser-family table. In v0.3 the profile keys move to verified `model_hash`; v0.2 uses modelID for symmetry with §3.2.

Rationale (codex #1, verified): upstream MLX `Chat.Message` only carries `role` and `content`, so the existing `ChatMessage.mlxMessage` adapter cannot carry assistant tool calls into templates. Reference: https://github.com/ml-explore/mlx-swift-examples/blob/9bff95ca5f0b9e8c021acc4d71a2bbe4a7441631/Libraries/MLXLMCommon/Chat.swift

### Assistant-history `tool_calls[]` echo

**Choose option (b):** validate format + cross-message consistency, then re-render into the model's native tool-call markup so the model "sees" its prior calls.

Rejected:
- (a) Ignore structured fields → breaks multi-turn agent state.
- (c) Reject if model_hash doesn't match originally-minting family → no provenance store in v0.2; would block legitimate Cline conversation resume after warm-swap.

### Tool-result content size cap

**Cap: 256 KiB UTF-8 bytes per individual `role:"tool"` message `content`.**

Distinct from deliverable #7 (which sets the response-side `function.arguments` cap to 1 MiB). The request-side `role:"tool"` content is a buyer-provided tool result — typically `read_file` output. 256 KiB matches realistic file-read use cases and bounds prompt-render memory.

**Failure:** HTTP 413 `tool_result_too_large`, OpenAI-style error envelope, `param: "messages[i].content"`. Reject whole request — do NOT truncate (silent truncation changes the file/command output the model reasons over, hurting coding correctness).

### Receipt canonicalization (SPEC-015 v0.3 binding)

**No schema change needed.** v0.2 keeps SPEC-015 v0.3 receipt shape.

Verified (codex #1): `PromptCanonicalizer.swift:5` already canonicalizes `messages`, including `tool_call_id` and `tool_calls` at `:31`. Output canonicalization remains one assistant turn via `OutputCanonicalizer.swift:50`. A multi-turn prompt's `prompt_hash` correctly changes when `tool_call_id` or assistant-history `tool_calls[]` changes — this needs **regression test coverage** in v0.2 IMPL (not a SPEC change).

### Failure mode table (request-side)

| Shape | v0.2 behavior |
|---|---|
| `role:"tool", content:""` | Accept. Empty command output is legitimate. |
| `role:"tool", content:null` | HTTP 400 `invalid_request`, `param:"messages[i].content"` |
| `role:"tool"` missing `tool_call_id` | HTTP 400 `invalid_request`, `param:"messages[i].tool_call_id"` |
| `tool_call_id` failing format regex (see #6) | HTTP 400 `invalid_tool_call_id` |
| `tool_call_id` no prior assistant `tool_calls[].id` in same request | HTTP 400 `tool_call_id_not_found` |
| Duplicate tool result for same ID | HTTP 400 `duplicate_tool_call_id` |
| Assistant `tool_calls[]` malformed (depth/shape) | HTTP 400 `invalid_tools` |
| Assistant-history `function.arguments` > **1 MiB** | HTTP 413 `tool_call_arguments_too_large` (aligned to #7 response-side cap) |
| `role:"tool"` content > 256 KiB | HTTP 413 `tool_result_too_large` |

**Coordinator** must mirror these early at `phase4-coordinator/internal/buyer/server.go:3089`. Existing coordinator request structs already preserve `tool_call_id` and `tool_calls` at `:1234`. (No coordinator data-model changes needed; only validation additions.)

### Cross-cutting: provider-output malformed deltas remain provider faults

Provider-output malformed pre-commit deltas continue to follow v0.1.5 settlement-protection: HTTP 502 + `FaultBreakerQualifying` via `server.go:2394` + `billing_recorder.go:176` + `formula.go:112` → zero credits. v0.2 does NOT change this path.

---

## 4. Deliverable #6 — Multi-turn `tool_call_id` validation rule

### Posture: format-only stateless validation + strict request-internal cross-message consistency

Provider MUST NOT require that an incoming `tool_call_id` was minted by the current process, session, or identity. Goal is OpenAI compatibility + reject malformed conversation graphs + preserve cross-session Cline conversation resume. Not authenticity proof — buyer already controls request body.

### Two distinct regex domains

**Provider-emitted IDs** (newly synthesized assistant `tool_calls[].id` values):
```
^call_[a-f0-9]{32}$
```
Preserves v0.1.5 §2.1 (lowercase hyphenless UUID-hex) and §10c (`call_` prefix locked).

**Request-accepted IDs** (assistant-history `tool_calls[].id` + `role:"tool".tool_call_id`):
```
^call_[A-Za-z0-9]{16,64}$
```
Wider — accepts OpenAI's mixed-case alphanumeric `call_...` shape used by upstream openai-python conversations. 16-char minimum gives ~95 bits if random. 64-char maximum bounds prompt-render abuse surface.

Rejected suffix chars: `_`, `-`, `.`, `/`, `:`, whitespace, non-ASCII, empty. Future cryptographic-binding ID format (`call_<random>_<mac>`) is **not v0.2-compatible**; would require a later SPEC change preserving the `call_` prefix.

### Cross-message consistency rules (must validate before inference)

1. Every assistant-history `tool_calls[].id` MUST match request-accepted regex.
2. Every `role:"tool"` MUST have non-empty `tool_call_id` matching request-accepted regex.
3. `role:"tool"` MUST appear after the assistant message whose `tool_calls[]` contains the same ID.
4. Within a single request, each `tool_call_id` MUST appear in exactly one assistant `tool_calls[]` entry.
5. Within a single request, each assistant `tool_calls[].id` MAY have zero or one matching `role:"tool"` result (zero handles last-turn-with-pending-call shapes).
6. A `role:"tool"` MUST NOT reuse a `tool_call_id` already used by an earlier `role:"tool"` in the same request.
7. A `role:"tool"` whose `tool_call_id` does not match an earlier assistant `tool_calls[].id` in the same request MUST be rejected.

### Failure response shape

HTTP 400 + OpenAI-style error envelope, `type: "invalid_request_error"`. Four normative codes:

- `invalid_tool_call_id` — ID missing or format invalid
- `tool_call_id_not_found` — `role:"tool"` references no earlier assistant tool call
- `duplicate_tool_call_id` — same ID in multiple assistant `tool_calls[]` or multiple `role:"tool"` results
- `tool_call_result_out_of_order` — `role:"tool"` appears before its assistant tool call

All four are NOT fault-breaker-qualifying. No credits committed. No receipt generated (no inference ran).

### Cross-session reuse — MUST be accepted

A Cline conversation saved after a successful turn, resumed through a fresh provider process or fresh WS connection, includes prior assistant `tool_calls[].id` and matching `role:"tool".tool_call_id` values. Provider validates format + request-internal consistency, does NOT check a live minted-ID registry, proceeds to inference. **Release-gating** for v0.2.

### Buyer-fabricated IDs — MUST be accepted

If format-valid and request-internally consistent. The model may believe the fabricated context; buyer pays for the inference; no money-path implication (no retroactive settlement decisions on prior turns).

---

## 5. Deliverable #7 — Per-call `function.arguments` byte cap

### Constants (raise from v0.1.5's 256 KiB)

```
SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP     = 1_048_576   // 1 MiB
SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP = 2_097_152   // 2 MiB
SPEC018_ARGUMENTS_MAX_JSON_DEPTH        = 32          // unchanged from v0.1.5
```

Inclusive comparison: `byte_len <= cap` succeeds.

**Byte length domain:** UTF-8 byte length of the **final unescaped** `function.arguments` string value (what an OpenAI client gets after JSON/SSE parsing and fragment concatenation). NOT the outer response JSON with string-escape overhead.

### Why 1 MiB / 2 MiB

- **Legitimate Cline use:** `write_to_file` carries full file contents inside the argument object. 256 KiB blocks realistic generated docs, formatted JSON, bundled configs. 1 MiB leaves room for ~500 KiB file + argument-object overhead.
- **Attack resistance:** Pathological 10 MB streams rejected at 10% of target. Single tool call cannot become unbounded settlement object.
- **Model context:** 1 MiB is at or beyond what useful local code models emit in one completion; higher only adds DoS surface for unusual workflows that should use segmented writes.
- **No public Cline p95 evidence** — v0.2 release gate is fixture-based + Cline-smoke-based (write a generated 512 KiB–1 MiB file successfully).

### Parser ↔ coordinator alignment

Parser-side runtime validator and coordinator §8.4 commit-worthy validator MUST use **identical constants** and **identical byte-counting function** (UTF-8 byte length of decoded unescaped string).

- Stricter parser → framework-visible drift.
- Stricter coordinator → wasted provider work; provider-visible success becomes buyer-visible failure.

One cap, enforced twice. Parser protects provider memory + streaming state. Coordinator protects settlement + catches buggy or hostile providers.

### Multi-call: BOTH limits enforced

- Each individual `tool_calls[i].function.arguments` MUST be ≤ 1 MiB.
- Sum of all `function.arguments` UTF-8 byte lengths in the response MUST be ≤ 2 MiB.

Per-call failure reason: `byte_cap_exceeded`. Aggregate failure reason: `response_byte_cap_exceeded`. (These would map to the v0.3 `usage.macprovider_malformed_tool_call.reason` enum; v0.2 doesn't yet ship the structured signal, so the failure surfaces as coordinator 502 + `FaultBreakerQualifying` and parser-side fallback-to-content with an internal log.)

### Configurability — NONE on public wire in v0.2

MUST NOT be buyer-negotiable. MUST NOT be operator-configurable on the public SPEC-018 v0.2 wire. Operators MAY run private experiments; a deployment advertising SPEC-018 v0.2 compliance MUST accept baseline fixtures and enforce identical values at parser + coordinator.

Future negotiation (`X-MacProvider-Args-Cap` request header chain) is deferred — provider-local misconfig would otherwise turn a wire guarantee into a route lottery.

### §10c forward-compat

Future v0.2.x MAY raise either cap. MUST NOT lower either for default no-header behavior. MUST NOT change inclusive boundary rule. MUST NOT change byte-counting domain (UTF-8 unescaped). Lowering requires a major SPEC bump or explicit buyer opt-in.

---

## 6. Deliverable #4 — Token-incremental streaming promotion

### Release posture: streaming-default for v0.2 Cline-targeted compatible models + operator kill switch

Buffered-default would technically preserve safety but would fail the Cline anchor goal. Streaming is the headline UX in v0.2.

**Kill switch:** operator config to force buffered-to-end streaming. Per-provider downgrade triggered automatically on malformed incremental streams.

### Wire format

Confirmed matches openai-python v2.44.0 (baseline pinned in v0.1.5 `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt`):

```sse
data: {"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_<32hex>","type":"function","function":{"name":"write_to_file","arguments":""}}]},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"content\":\""}}]},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"<2KB chunk>"}}]},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\",\"path\":\"/tmp/demo.txt\"}"}}]},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]
```

First delta carries `id`, `type`, `function.name`. Subsequent deltas carry incremental `function.arguments` string fragments. Buyer concatenates by `index`.

### Byte-equivalence with non-streaming

**Pick streaming-native with a single canonical output builder.** The provider MUST use the same canonical byte stream for both. Non-streaming = full accumulated canonical bytes. Streaming = prefixes of those same bytes. Chunk boundaries are transport-only and MUST NOT affect the final accumulated `function.arguments`.

Harder than "generate full then chunk" but only this delivers Cline-visible progress AND byte equivalence with the AC-23 regression test.

### Commit-vs-settlement split (§8.4 v0.2 update)

**v0.2 splits §8.4 commit semantics:**
- **Incremental-open validator** — runs before emitting ANY `tool_calls[]` chunk. Checks: verified model family, non-empty declared `function.name`, stable `index`, minted `id`, `type:"function"`, first argument fragment is a JSON-string fragment. Once passed → buyer-visible streaming commit is allowed.
- **Final-close validator** — runs at end-of-stream. Checks: concatenated `arguments` parses as JSON object, depth ≤ 32, per-call bytes ≤ 1 MiB, per-response bytes ≤ 2 MiB. Once passed → **money-path settlement commit** is finalized.

If final-close validator fails AFTER any tool-call delta was emitted to the buyer, the stream terminates with a structured error frame (using the same wire shape as the v0.3-deferred `malformed_tool_call` schema — but v0.2 emits it inside an OpenAI-style `error` object on a terminating SSE frame, not as `usage.macprovider_*` since v0.3 owns the `usage` field). Coordinator marks `FaultBreakerQualifying`, zero provider-positive settlement.

**OpenAI streams have no withdrawal primitive.** v0.2 MUST NOT attempt "cancel that, treat as content" after streaming has begun.

### Coordinator pass-through paths to update

- WS streaming relay: `phase4-coordinator/internal/buyer/server.go:2119` (`forwardWSStreaming`)
- Direct HTTP streaming: `:2279` (`forwardStreaming`)
- **Current tool delta validator at `:2674` requires complete valid JSON-object arguments** — INCOMPATIBLE with OpenAI incremental fragments. Must be replaced with the split incremental-open + final-close validator pair.

Add a streaming-side analogue to v0.1.5 AC-24: provider SSE bytes containing split `tool_calls[].function.arguments` MUST reach the buyer byte-identical, for both WS-backed and direct HTTP paths.

### AC-23s — streaming forward-compat regression test extension

Extension of v0.1.5 AC-23. Pin baseline SDK from `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt` (`openai==2.44.0`). Mock `/v1/chat/completions`. Same request returns:
- Non-streaming response with fixed `id`, `created`, `model`, and `tool_calls[0].function.arguments`
- Streaming SSE response splitting the same `arguments` string into `["", "{\"content\":\"", <2KB chunks>..., "\",\"path\":\"/tmp/demo.txt\"}"]`

Accumulate streaming with pinned openai-python streaming reader. Assert:
- No SDK parse error
- Accumulated `id`, `type`, `name`, `finish_reason` match non-streaming
- Concatenated `function.arguments` bytes equal non-streaming exactly
- Unknown additive fields tolerated

---

## 7. Cross-cutting interactions resolved

| Interaction | Resolution |
|---|---|
| #1 multi-turn ↔ #6 tool_call_id | Validate first (request-time, format-only stateless per #6), then render (inference-time, native markup per #1 option b). |
| #1 multi-turn ↔ #7 byte cap | Request-side assistant-history `function.arguments` cap aligns to **1 MiB** (matches response-side); HTTP 413 `tool_call_arguments_too_large`. Request-side `role:"tool"` content cap is **256 KiB** (different domain — tool-result text, not tool-call arguments); HTTP 413 `tool_result_too_large`. |
| #4 streaming ↔ #7 byte cap | Streaming enforces per-call + per-response caps incrementally via accumulators; final-close validator gates settlement. Mid-stream cap-cross → terminating SSE error frame + `[DONE]` + `FaultBreakerQualifying`. |
| #4 streaming ↔ §8.4 (v0.1.5) | §8.4 splits into incremental-open (buyer-visible commit) + final-close (settlement commit). Non-streaming behavior unchanged. |
| Provider-output settlement protection | v0.1.5 money-path (HTTP 502 + `FaultBreakerQualifying` → zero credits via `billing_recorder.go:176` + `formula.go:112`) preserved unchanged. |
| Receipt canonicalization (SPEC-015 v0.3) | No schema change. PromptCanonicalizer.swift:5 already handles `tool_call_id` and `tool_calls`. Add multi-turn regression tests in IMPL. |

---

## 8. §10c forward-compat impact

**v0.2 does NOT break v0.1.3 wire shape.** Verified:

- v0.1.3 `call_[a-f0-9]{32}` ID format preserved for provider-emitted IDs.
- v0.1.3 non-streaming response shape (`role`, `content`, `tool_calls[]`, `finish_reason:"tool_calls"`) unchanged via `HTTPServer.swift:819`.
- AC-14 (`unsupported_tool_messages`) transitions from error path to success path — §10c explicitly permits this (additive direction).
- Streaming chunks accumulate byte-equivalently to non-streaming canonical output — AC-23s gates this.
- Byte cap raises from 256 KiB to 1 MiB — additive (more accepted), permitted by §10c.

**One §10c addition needed in v0.2:** lock the 1 MiB per-call + 2 MiB per-response constants as v0.2.0 baseline. Future v0.2.x MAY raise; MUST NOT lower.

---

## 9. v0.2 AC numbering (renumbered to avoid codex collisions)

v0.1.5 last used AC-24. v0.2 ACs start at AC-25.

| AC | Deliverable | Description |
|---|---|---|
| AC-25 | #1 | Multi-turn end-to-end Cline session passes (criteria in §2) |
| AC-26 | #1 | `role:"tool"` accepted with valid `content` + `tool_call_id`; renders into native markup |
| AC-27 | #1 | Assistant-history `tool_calls[]` echo accepted + rendered (option b) |
| AC-28 | #1 | Tool-result content > 256 KiB → HTTP 413 `tool_result_too_large` |
| AC-29 | #1 | Multi-turn prompt_hash regression — changes when `tool_call_id` or assistant-history `tool_calls[]` changes |
| AC-30 | #6 | Provider-emitted ID format `^call_[a-f0-9]{32}$` preserved |
| AC-31 | #6 | Request-accepted ID format `^call_[A-Za-z0-9]{16,64}$` for both assistant history and `role:"tool"` references |
| AC-32 | #6 | Cross-message consistency rules 1-7 enforced; pass cases accepted, fail cases rejected with one of 4 normative codes |
| AC-33 | #6 | Cross-session Cline resume accepted (no minted-ID registry check) |
| AC-34 | #6 | Buyer-fabricated but format-valid IDs accepted |
| AC-35 | #7 | Constants: per-call ≤ 1 MiB, per-response ≤ 2 MiB, depth ≤ 32, identical at parser + coordinator |
| AC-36 | #7 | Per-call cap inclusive at 1_048_576 bytes (succeeds); 1_048_577 fails |
| AC-37 | #7 | Aggregate cap inclusive at 2_097_152 bytes (succeeds); +1 fails as `response_byte_cap_exceeded` |
| AC-38 | #7 | Byte counting is UTF-8 of unescaped final argument string (not character count, not escaped JSON) |
| AC-39 | #7 | Streaming mid-stream cap-cross → terminating SSE error frame + `[DONE]` + `FaultBreakerQualifying` + zero credits |
| AC-40 | #4 | Streaming wire shape matches OpenAI v2.44.0 (first delta has id/type/name; subsequent have arguments fragments) |
| AC-41 | #4 | Streaming byte-equivalence with non-streaming — accumulated `function.arguments` byte-identical |
| AC-42 | #4 | §8.4 v0.2 split: incremental-open before any tool-call chunk; final-close gates settlement |
| AC-43 | #4 | AC-23s streaming forward-compat regression: openai==2.44.0 accumulates v0.2 stream byte-equivalent to non-streaming |
| AC-44 | #4 | Cline `write_to_file` ≥ 64 KiB: first arguments delta within 1500 ms, ≥ 3 deltas before `finish_reason:"tool_calls"` |
| AC-45 | #4 | Operator kill switch — disable streaming forces buffered-to-end behavior; auto-downgrade per-provider on malformed streams |

(AC-46+ reserved for v0.3 deferred deliverables.)

---

## 10. Deferred to v0.3 (codex design already complete)

| # | Deliverable | Status | Files |
|---|---|---|---|
| #2 | Model-hash → tool-call-family registry | Designed (Option A/B/C analyzed; codex recommendation in artifact) | `specs/DESIGN_SPEC_018_v0_2_02_MODEL_HASH_REGISTRY.md` → preserve as `specs/v0_3-design/02-registry.md` |
| #3 | Prompt-echo guard | Designed (incremental detector, 256-byte threshold) | `specs/DESIGN_SPEC_018_v0_2_03_PROMPT_ECHO_GUARD.md` → preserve as `specs/v0_3-design/03-echo-guard.md` |
| #5 | Structured `malformed_tool_call` signal | Designed (`usage.macprovider_malformed_tool_call` schema; 6-value reason enum) | `specs/DESIGN_SPEC_018_v0_2_05_MALFORMED_SIGNAL.md` → preserve as `specs/v0_3-design/05-malformed-signal.md` |

v0.3 sequencing dependency: #2 registry should land first (it gates #1's family selection from modelID → model_hash). #3 echo guard is independent. #5 signal is the buyer-side diagnostic contract — depends on having well-defined fail reasons, which v0.2 covers internally via §8.4 split and #7 caps; v0.3 just exposes them.

---

## 11. Next steps

1. **Archive v0.3-design** — move #2/#3/#5 design files to `specs/v0_3-design/` so the v0.2 specs/ folder is clean.
2. **Write `specs/BUILD_SPEC_018_v0_2_PROMPT.md`** — converts this synthesis into a codex-executable spec-authoring prompt.
3. **Fire codex** against the BUILD prompt to draft `specs/SPEC-018-agentic-tool-calling.md` v0.2.
4. **Codex 4-lane audit loop** (architect / code / security / product-design) per [[feedback-three-lane-codex-audits]] until 0/0/0.
5. **Claude blind-spot pass** (critic + narrative analyst) per the v0.1.5 precedent — caught 3 lock-blocking HIGH issues codex missed.
6. **Open v0.2 SPEC PR** (alone, not bundled — v0.2 is scope expansion, not incremental).
7. **After v0.2 SPEC merges:** write IMPL prompt covering ModelRuntime.swift edits, ChatMessage extension, ToolPromptRenderer addition, server.go validator split, AC-23s test, Cline-smoke recorded session.
8. **Open v0.2 IMPL PR.**

The synthesis is opinionated and decision-complete. The BUILD prompt next will translate it into the SPEC body codex drafts.
