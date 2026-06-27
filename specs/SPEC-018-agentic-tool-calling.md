# SPEC-018 — Agentic tool calling (provider-side response synthesis)

**Version:** 0.1.1 (2026-06-27, round-1 audit absorption — re-scoped to "first-turn wire-shape compatibility certificate" + security (a)+(b))
**Depends on:** SPEC-001 v1.6, SPEC-002 v1.4.1, SPEC-006 v0.9, SPEC-008 (Pillar A model-hash trust layer — referenced by §10a), SPEC-011 v0.5 (warm-swap heartbeat `model_hash` — referenced by §10a), SPEC-015 v0.3 (receipts canonical output binding — see AC-17)
**Status:** Draft

## Change log

- **v0.1.1 (2026-06-27, round-1 audit absorption):** Re-scoped from "Ring-1 product" to "first-turn OpenAI tool-call wire-shape compatibility certificate" after PD C-1 + Architect M-3 found Ring-1 framing did not survive turn 2 of any real agent session. §3 detection grammar tightened to require `modelID` substring match (Security C-1 (a)) — content-sentinel-only detection is no longer normative. §1 adds buyer-side validation obligation (Security C-1 (b)). §10 split into §10a "Required for full Ring-1 product (v0.2 targets)" — multi-turn provider acceptance, model-hash → family registry leveraging the live SPEC-008/SPEC-011 `model_hash` infrastructure, prompt-echo guard, token-incremental streaming promotion, structured `malformed_tool_call` signal — and §10b "Future enhancements" — structured output, prefix-cache signaling (SPEC-006 header-allowlist allocation required, no concrete header reserved), `max_tool_calls` cap, SDK examples. §7 made informative; gateway YAML normative authority returned to SPEC-002 / SPEC-006. §8.4 adds commit-worthy delta minimal-shape validation (Security H-1). Multiple AC reshuffles (split, parametric, scope). Round narrative: `specs/SPEC-018-r1-audit.md`; per-lane findings: `specs/SPEC-018-{architect,code,security,product-design}-r1-audit.md`.
- **v0.1 (2026-06-27, initial draft):** Post-hoc ratification of cf2f135, c823a96, and 7b8b1be as the network's tool-calling baseline. Superseded by v0.1.1 round-1 absorption.

## 1. Scope

SPEC-018 defines OpenAI-compatible tool-calling wire compatibility for provider-side response synthesis on the macprovider network.

**v0.1 product surface: a first-turn OpenAI tool-call wire-shape compatibility certificate.** A buyer MAY point an OpenAI-shaped client at the buyer-side gateway and receive a single assistant tool-call response that the client can parse without macprovider-specific response adapters. v0.1 does NOT certify full multi-turn client-side agent loops; the current phase3 provider rejects `role: "tool"` messages and assistant-history `tool_calls[]` with HTTP 400 `unsupported_tool_messages` (AC-14). Full client-side agent loop support — what users running Cline, Cursor, Aider, OpenCode, Continue, Zed, Claude Code, or any other OpenAI-shape agent framework actually need — is the v0.2 deliverable per §10a.

The agent loop runs on the buyer's machine. The model runs on the seller. The network is the marketplace and transport.

A macprovider seller MUST emit OpenAI-wire-compatible `tool_calls[]` when a supported model output grammar produces tool calls under the §3 detection rules and a request supplies enabled tools.

A macprovider seller MUST NOT execute tools on behalf of the buyer. The seller's job ends at emitting the `tool_calls[]` array.

**Buyer-side validation obligation (Security C-1 (b)):** Emitted `tool_calls[]` reflect the underlying model's output as parsed by §3 detection grammars. macprovider does NOT semantically validate `tool_calls[].function.name` or `function.arguments` against the buyer's tool policy or intent. Buyer-side agent frameworks MUST validate emitted tool calls against agent policy before executing them. Treat emitted tool calls with the same trust posture you would apply to a model running on local hardware: parsed output, not provider-verified intent.

The following products are out of scope for SPEC-018 entirely:

- Ring 2: provider-side agent execution, where a provider runs the agent loop locally with sandbox, filesystem, shell, or network egress authority. That product is reserved for SPEC-019.
- Ring 3: provider-hosted MCP servers reachable from the model's tool loop. That product is reserved for SPEC-020.

SPEC-018 v0.1.1 ratifies the as-built response-synthesis behavior in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift`, `OutputCanonicalizer.swift`, `ModelRuntime.swift`, `HTTPServer.swift`, `InferenceRelay.swift`, coordinator relay pass-through, and gateway pass-through, with two normative deltas vs the as-built that the v0.1.1 IMPL prompt will patch: §3 `modelID`-match-required tightening and §8.4 commit-worthy delta minimal-shape validation. All other §2–§8 behavior is post-hoc ratification.

### 1.1 Known v0.1 limitations (single user-facing callout)

A buyer or operator reading this SPEC should know up front that v0.1 has the following user-visible limitations. These are not bugs; they are scope. Each is closed in §10a as a v0.2 deliverable.

1. **First-turn only.** `role:"tool"` messages and assistant-history `tool_calls[]` are rejected at the provider boundary (AC-14). A real agent session running Cline / Cursor / Aider against macprovider will succeed on turn 1 and fail on turn 2.
2. **Buffered-to-end streaming for tool calls.** When streaming is enabled with tool-enabled requests, the tool-call SSE event fires only after generation completes. Users see a pause, then the complete tool call, instead of token-incremental `arguments` deltas (§4, Q1).
3. **No structured `malformed_tool_call` signal.** Parse failures fall back to plain assistant content (§5). Buyers cannot programmatically distinguish "normal model text" from "recognized tool-call parse failed."
4. **No model-hash-bound grammar selection.** v0.1 selects parser grammar by `modelID` substring match (§3, §10a v0.2 target). A provider whose advertised modelID matches a declared family is trusted at the modelID level; cryptographic binding to the loaded model hash uses the live SPEC-008 Pillar A + SPEC-011 v0.5 `model_hash` infrastructure but is a v0.2 deliverable.
5. **No prompt-echo guard.** A model that echoes hostile tool-call markup from a poisoned prompt is not rejected by the parser; the buyer-side validation obligation in §1 is the v0.1 mitigation, with a normative parser-side guard committed to §10a v0.2.

## 2. Response Wire Shape: Non-Streaming

When provider-side parsing produces one or more tool calls, the buyer-visible HTTP response MUST be an OpenAI chat-completions response.

The response MUST contain:

- `choices[0].message.role = "assistant"`.
- `choices[0].message.content = null` in the v0.1 as-built provider when any `tool_calls` are present.
- `choices[0].message.tool_calls`, an array of tool-call objects.
- `choices[0].finish_reason = "tool_calls"`.

Each `tool_calls[]` object MUST have:

- `id`: an opaque string.
- `type = "function"`.
- `function.name`: the parsed function name.
- `function.arguments`: a JSON-encoded string, not a JSON object.

This shape is implemented in `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:776-828`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:566-615`, and `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift:16-38`.

### 2.1 ID Generation

For each parsed tool call, the provider MUST mint an ID of the form:

```text
call_<uuid-hex-lowercase-without-hyphens>
```

The v0.1 as-built implementation uses Swift `UUID().uuidString`, removes hyphens, lowercases the result, and prefixes it with `call_`.

IDs are non-deterministic (≥122 bits of entropy from the platform UUID generator). A retry of the same model output is not required to reproduce the same IDs. Implementations MUST NOT use an incrementing per-response scheme if that scheme can collide across calls in the same response.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:59-75` and `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:77-94`.

### 2.2 Multi-Call Ordering

When the underlying model output contains N recognized tool calls, the provider MUST preserve textual order. `tool_calls[0]` MUST correspond to the first recognized call in the model output, `tool_calls[1]` to the second, and so on.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:29-50`; locked by `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:21-30`.

### 2.3 `arguments` String Encoding

The provider MUST emit `function.arguments` as a string containing a JSON object.

The v0.1 canonicalization rules are:

- Missing `arguments` or `parameters` MUST serialize as `{}`.
- Explicit `null` arguments MUST NOT produce a tool call; the response falls back to plain assistant content.
- JSON object arguments decoded from a structured object MUST be serialized with sorted keys, no insignificant whitespace, and without escaping `/`.
- JSON string arguments MUST be validated as a JSON object and MUST be emitted byte-for-byte as supplied by the model after validation. (Validation-only — not re-canonicalized; SDKs MUST JSON-parse and schema-validate before execution.)
- Python-style keyword arguments MUST be converted to a JSON object string with sorted keys, no insignificant whitespace, and without escaping `/`.
- Non-object argument values MUST NOT produce a tool call; the response falls back to plain assistant content.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:238-264`, `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:96-123`, and `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:169-188`.

### 2.4 Content Interleaving

The parser can collect prose outside tool-call delimiters as cleaned content. The v0.1 provider runtime discards that cleaned content whenever at least one tool call is parsed and returns tool calls only. Therefore, when the model emits prose before, between, or after recognized tool calls, the buyer-visible non-streaming message MUST contain `content = null` and the parsed `tool_calls[]`.

Source: parser behavior in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:29-50`; runtime discard in `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:826-839`; response emission in `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:819-828`.

## 3. Detection Grammar

The provider does not receive structured tool calls from the underlying MLX model. It receives plain text and parses recognized model-family output grammars.

**§3 is the normative source of truth for v0.1 model-family tool-call grammars.** The implementation source is the implementation of this section. Any detector, sentinel, modelID match, grammar path, or family-family priority not represented in §3 is non-compliant until a SPEC-018 version bump.

### 3.1 Family table

| Family | `modelID` match (required) | Body grammar | Argument field | Source |
|---|---|---|---|---|
| Qwen2.5 / Qwen3 native | `modelID` substring contains `qwen2.5` | `<tool_call>{...}</tool_call>` JSON body | `arguments` preferred; `parameters` accepted as fallback | `ToolCallParser.swift:451-491` |
| Qwen coding-tuned | `modelID` substring contains `qwen2.5` (Qwen coding-tuned models advertise as Qwen2.5 derivatives) | `<tool_call>name(key=value, ...)</tool_call>` Python-style call | keyword args | `ToolCallParser.swift:77-123`, `ToolCallParser.swift:451-491` |
| Llama 3.3 MLX | `modelID` substring contains `llama-3.3` | `<\|python_tag\|>{...}<\|eom_id\|>` JSON body, OR `<\|python_tag\|>name(key=value)<\|eom_id\|>` Python-style body | `parameters` preferred for JSON body; `arguments` accepted as fallback; keyword args for Python-style body | `ToolCallParser.swift:451-491` |

### 3.2 modelID match required (Security C-1 (a))

Family detection MUST require a `modelID` substring match against §3.1. Content-sentinel detection alone (the presence of `<tool_call>` or `<|python_tag|>` in raw model output without a matching `modelID`) is NOT a normative trigger in v0.1. Output containing recognized sentinels but no `modelID` family match MUST be emitted as plain assistant content; no `tool_calls[]` are synthesized.

Rationale: the v0.1 design closes the prompt-injection vector identified in Security C-1 / Q6, where a model could be prompted to echo `<tool_call>{"name":"declared_tool",…}</tool_call>` and the parser would synthesize a legitimate-looking tool call. With `modelID` match required, a provider that has not advertised a tool-call-capable family does not synthesize tool calls regardless of model output content. v0.2 closes the residual case — a tool-call-capable model echoing hostile content — via the §10a model-hash → family registry binding and the prompt-echo guard.

### 3.3 Body parsing

For JSON bodies, the body MUST parse as a JSON object with a non-empty string `name`. For Python-style bodies, the body MUST parse as `name(key=value, ...)` where `name` and keys are Python identifiers and values are supported string, boolean, null, integer, or decimal literals.

### 3.4 Ambiguous duplicate argument keys

Ambiguous duplicate argument keys means any of the following:

- duplicate keys in the top-level JSON call object;
- duplicate keys in a nested JSON `arguments` or `parameters` object;
- duplicate keys in a JSON string supplied as `arguments` or `parameters`;
- duplicate keyword names in a Python-style call.

The v0.1 provider rejects ambiguous duplicate keys by abandoning tool-call synthesis and falling back to plain assistant content. It does not silently choose first-key-wins or last-key-wins.

Source: JSON duplicate validator in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:266-448`; Python keyword duplicate rejection in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:96-123`; locked by `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:125-159`.

### 3.5 Fallback to plain content

If grammar detection fails, parsing fails, the function name is not declared in the request's enabled tools, or a value cannot be represented as a JSON-object `arguments` string, the provider MUST treat the model output as plain assistant content and MUST NOT emit `tool_calls[]`.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-27`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:826-839`.

### 3.6 Multi-family priority and mixed sentinels

When the buyer-supplied `modelID` substring-matches more than one family row in §3.1, deterministic precedence is declared by table order: the first matching row in §3.1 selects the parser family. (At v0.1, no `modelID` matches more than one row, but the rule is normative.)

When model output contains sentinels from multiple families simultaneously (e.g. both `<tool_call>` and `<|python_tag|>`), the parser MUST treat the output as malformed and fall back to plain assistant content. This closes the cross-family bypass surface identified in Security m-1.

### 3.7 Adding a new family

A new model family's tool-call grammar MUST land via a SPEC-018 version bump that updates §3.1 and §3.2. Parser PRs MUST NOT mutate this table silently. A parser change that adds a new detector, sentinel, modelID match, or grammar path without a corresponding SPEC-018 §3 update is non-compliant.

## 4. Streaming Wire Shape

When `stream = true`, the buyer-visible response MUST use OpenAI-style SSE chat-completion chunks.

The v0.1 as-built streaming behavior is buffered-to-end for tool-enabled requests. It is not token-incremental for tool calls. v0.2 promotes token-incremental streaming per §10a.

The provider MUST emit an initial chunk with:

- `choices[0].delta.role = "assistant"`;
- `choices[0].delta.content = ""`;
- `choices[0].finish_reason = null`.

When one or more tool calls are parsed, the provider MUST then emit one SSE event containing `choices[0].delta.tool_calls[]`. That event fires only after underlying generation completes and provider-side parsing succeeds.

Each streamed tool call delta MUST contain:

- `index`: zero-based array index matching the non-streaming `tool_calls[]` order;
- `id`: the complete provider-minted call ID;
- `type = "function"`;
- `function.name`: the complete function name;
- `function.arguments`: the complete final `arguments` string.

The v0.1 stream does not split `function.arguments` into additive partial substrings. Concatenation across deltas for a given `index` is therefore a single-fragment concatenation and MUST reproduce the non-streaming `function.arguments` string byte-for-byte.

After the tool-call delta event, the provider MUST emit a terminator chunk with:

- `choices[0].delta = {}`;
- `choices[0].finish_reason = "tool_calls"`.

The provider MAY then emit a usage chunk with `choices = []` and MUST end the stream with `[DONE]`.

`delta.content` and `delta.tool_calls` MUST NOT appear in the same SSE event in v0.1.

If tool parsing fails in a tool-enabled streaming request, the provider emits plain content after generation completes and uses the non-tool finish reason (`stop` or `length`).

Source: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:481-603`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:433-556`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:387-509`.

## 5. Error Taxonomy

SPEC-001 identifies `malformed_tool_call` as an adversarial workload name in its error-taxonomy acceptance coverage. SPEC-018 v0.1 does not ratify `malformed_tool_call` as a provider response-synthesis API error code; §10a promotes it to a structured signal in v0.2.

The v0.1 response-synthesis error behavior is:

- malformed recognized tool-call bodies fall back to plain assistant content;
- undeclared function names fall back to plain assistant content;
- duplicate JSON or Python argument keys fall back to plain assistant content;
- explicit `null`, non-object, or invalid JSON arguments fall back to plain assistant content;
- output containing recognized sentinels but no `modelID` family match falls back to plain assistant content (§3.2);
- output containing sentinels from multiple families simultaneously falls back to plain assistant content (§3.6);
- unsupported `tool_choice` values other than omitted, `null`, or `"auto"` produce HTTP 400 with code `unsupported_tool_choice`;
- current phase3 provider input containing `role: "tool"` or assistant history `tool_calls[]` produces HTTP 400 with code `unsupported_tool_messages`.

Source: fallback behavior in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-27`; provider scope validation in `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:909-940`; tests in `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:99-155`.

SPEC-018 v0.1 imposes no `max_tool_calls` limit and no per-call `function.arguments` byte cap. No `tool_call_limit_exceeded` error exists in v0.1. §10b reserves both as future-enhancement candidates; §10a promotes a structured `malformed_tool_call` signal to v0.2.

If the underlying model reaches `max_tokens` mid-tool-call and no complete tool call can be parsed, the provider MUST NOT emit a partial tool call. It emits plain assistant content with `finish_reason = "length"` when the token limit is reached.

Source: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:451-465`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:567-590`.

Coordinator request validation for malformed assistant-history `tool_calls[]` remains governed by SPEC-001 and SPEC-002. The coordinator uses HTTP 400 with code `invalid_tools` for invalid request-side tool schema.

Source: `phase4-coordinator/internal/buyer/server.go:2940-3007`.

## 6. Multi-Turn Round Trip

SPEC-001 and SPEC-002 define the request half for assistant-history `tool_calls[]` and `role: "tool"` messages. SPEC-018 adds the response-side ID invariant.

The provider-minted `tool_calls[].id` is opaque. A buyer-side agent framework that sends a subsequent `role: "tool"` message MUST echo the exact ID in `tool_call_id`. Coordinator and gateway components MUST NOT rewrite, canonicalize, strip, or reorder provider-minted IDs.

The coordinator MUST treat request-side `tool_calls` and `tool_call_id` values as pass-through fields after validation. This ratifies SPEC-002's value-typed pass-through rule for `tool_calls`.

Source: request validation in `specs/SPEC-001-phase3-binary.md:950-979` and `specs/SPEC-002-coordinator.md:2280-2318`; coordinator implementation in `phase4-coordinator/internal/buyer/server.go:1236-1240` and `phase4-coordinator/internal/buyer/server.go:2940-3007`.

**v0.1 implementation limitation (closed in §10a v0.2):** the current phase3 provider rejects multi-turn tool-result messages at the provider boundary with `unsupported_tool_messages`. Therefore, SPEC-018 v0.1 ratifies response synthesis and transport pass-through, but it does not certify a full second-turn provider request after tool execution. This is the v0.2 deliverable — the gate between "wire-shape compatibility certificate" and "actual Ring-1 product release" — per §10a.

Source: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:920-940`; test coverage in `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:124-155`.

## 7. Gateway Timeout Co-Requirement (informative)

Tool-call buffered-to-end response synthesis (§4) creates first-header latency on non-streaming requests: headers do not arrive at the gateway until the provider finishes generation and response synthesis. For large coding-class models (Qwen3-Coder-30B-class on M4) first-response latency can exceed 10 seconds, which was the pre-c823a96 gateway `ResponseHeaderTimeout` default.

c823a96 raised the default to 60 seconds; the current as-built gateway default is 300 seconds with validation requiring `coordinator_header_timeout_seconds >= coordinator_request_seconds`.

§7 is **informative** in SPEC-018: the normative authority for gateway YAML configuration is SPEC-006 (buyer API gateway), and the normative authority for the coordinator-side request/header timeout ordering is SPEC-002 (coordinator). Compliant deployments of tool-call workloads MUST satisfy the SPEC-002 / SPEC-006 timeout invariants. SPEC-018 records the rationale tying tool-call buffered-to-end synthesis to first-header latency so that a SPEC-006 amendment can absorb explicit tool-call-workload guidance.

Source for the current gateway timeout machinery: `phase5-gateway/internal/config/config.go:123-127`, `phase5-gateway/internal/config/config.go:183`, `phase5-gateway/internal/config/config.go:361-373`, `phase5-gateway/internal/config/config.go:462-475`, and `phase5-gateway/cmd/gateway/main.go:81-95`.

## 8. Coordinator and Gateway Pass-Through Invariants

Every transport component between provider runtime and buyer client MUST preserve tool-call fields opaquely unless this SPEC or an upstream SPEC explicitly authorizes validation.

### 8.1 Provider HTTP Server

The provider HTTP server emits the OpenAI non-streaming and streaming shapes. It MUST serialize `tool_calls[]` without raw model delimiters.

Source: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:776-891`; shape tests in `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:53-97` and `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:223-262`.

### 8.2 InferenceRelay

InferenceRelay MUST preserve the generated OpenAI JSON/SSE payloads as `data` strings when forwarding over the coordinator WebSocket relay. It MUST NOT parse, strip, reorder, or canonicalize `tool_calls[]`.

Source: non-streaming forward in `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:269-309`; streaming forward in `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:387-509`; frame send helpers in `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:532-564` and `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:566-650`.

### 8.3 Coordinator WebSocket Relay

The coordinator WebSocket relay MUST treat provider chunks as opaque payloads. It MUST route `InferenceResponseChunk.data` and `InferenceResponseEnd` frames by request ID and MUST NOT inspect tool-call fields.

Late encrypted frames for recently retired requests MUST be consumed according to c823a96 cleanup behavior and MUST NOT surface as spurious relay failures.

Source: `phase4-coordinator/internal/ws/relay.go:525-581`, `phase4-coordinator/internal/ws/relay.go:583-722`, `phase4-coordinator/internal/ws/relay.go:211-250`; frame shape in `phase4-coordinator/internal/ws/messages.go:199-225`.

### 8.4 Coordinator Buyer HTTP Forwarding

For WebSocket-backed non-streaming responses, the coordinator MUST write the provider response body bytes to the buyer without semantic rewriting. For WebSocket-backed streaming responses, it MUST write SSE chunks without rewriting `tool_calls[]`.

For direct provider HTTP streaming, the coordinator MAY inspect SSE events only to determine whether a response is commit-worthy. A `delta.tool_calls[]` event is **commit-worthy only if** the delta validates as minimal OpenAI tool-call shape:

- `index`: integer ≥ 0
- `id`: non-empty string
- `type == "function"`
- `function.name`: non-empty string
- `function.arguments`: present and parseable as a JSON string

Malformed pre-commit tool-call deltas (e.g. `{"choices":[{"delta":{"tool_calls":[{}]}}]}`) MUST NOT commit the response and MUST NOT settle provider-positive usage. This closes the Security H-1 commit-on-bogus-delta path; the IMPL prompt will add the validator to the coordinator commit-signal code path.

After commit, the coordinator MUST pass bytes through without rewriting `tool_calls[]`.

Source: `phase4-coordinator/internal/buyer/server.go:1982-2195`, `phase4-coordinator/internal/buyer/server.go:2320-2473`, `phase4-coordinator/internal/buyer/server.go:2482-2605`; commit-signal tests in `phase4-coordinator/internal/buyer/server_internal_test.go:70-103`.

### 8.5 Gateway

The gateway MUST forward non-streaming response bodies and streaming SSE lines without semantic rewriting of `tool_calls[]`.

The streaming gateway MAY parse delta strings for token-estimate enforcement. It MUST count generated `function.arguments` string bytes and MUST NOT count `id`, `type`, or `name` strings as generated output.

Source: `phase5-gateway/internal/router/chat_proxy.go:237-516`, `phase5-gateway/internal/router/chat_proxy.go:652-717`; tests in `phase5-gateway/internal/router/server_test.go:2516-2580`.

## 9. Acceptance Criteria

AC-1. Given a request with enabled tool `foo`, `modelID` substring-matching `qwen2.5`, and model output `<tool_call>{"name":"foo","arguments":{"a":1}}</tool_call>`, the buyer-visible non-streaming response contains `choices[0].message.tool_calls[0].function.name == "foo"` and `choices[0].message.tool_calls[0].function.arguments == "{\"a\":1}"`.

AC-2. When any tool call is emitted, `choices[0].finish_reason == "tool_calls"`.

AC-3. For multiple recognized calls in one model output, response array order matches textual order.

AC-4. Response `tool_calls[].id` values start with `call_`, contain a lower-case hyphenless UUID suffix derived from a fresh ≥122-bit-entropy UUID, and are observed unique within the test response. (Non-collision is invariant by construction; no explicit per-response de-duplication loop is required.)

AC-5. Ambiguous duplicate argument keys produce no `tool_calls[]`; the response falls back to plain assistant content instead of first-key-wins or last-key-wins.

AC-6. Malformed recognized tool-call bodies produce no `tool_calls[]`; the response falls back to plain assistant content.

AC-7. Streaming tool-call responses contain no raw `<tool_call>`, `</tool_call>`, `<|python_tag|>`, or `<|eom_id|>` delimiters.

AC-8. Streaming tool-call responses emit one complete `delta.tool_calls[]` event after generation completes, followed by a terminator chunk with `finish_reason == "tool_calls"`.

AC-9. Concatenating streamed `function.arguments` fragments by `index` reproduces the non-streaming `function.arguments` string byte-for-byte. In v0.1 this is a single-fragment concatenation.

AC-10. `delta.content` and `delta.tool_calls` do not appear in the same SSE event.

AC-11. Coordinator WebSocket relay preserves provider-emitted `tool_calls[]` JSON across `InferenceResponseChunk.data` without stripping, reordering, or canonicalizing fields.

AC-12. Gateway non-streaming and streaming forwarding preserves provider-emitted `tool_calls[]` fields without semantic rewriting.

AC-13. `tool_choice` values other than omitted, `null`, or `"auto"` fail with HTTP 400 code `unsupported_tool_choice` at the current provider boundary.

AC-14. Current provider requests containing `role: "tool"` messages or assistant-history `tool_calls[]` fail with HTTP 400 code `unsupported_tool_messages`. (v0.1 ratifies this as the first-turn-only limitation; closed in §10a v0.2.)

AC-15a. **Code default + validation (CI-verifiable).** Gateway default `coordinator_header_timeout_seconds` is 300; validation rejects configurations where `coordinator_header_timeout_seconds < coordinator_request_seconds`. Verified by `phase5-gateway/internal/config/config_test.go:22-55`.

AC-15b. **Live deploy evidence (release smoke / manual evidence).** Live tool-call workload deployments configure `timeouts.coordinator_header_timeout_seconds >= 60`. Verified by the deploy-gate script `phase4-coordinator/dist/check-deploy-config.sh:268-281` and an operator-recorded JSON artifact from the live gateway YAML.

AC-16a. **First-turn wire-shape smoke (CI-local).** An OpenAI Python SDK 1.x client pointed at the buyer URL parses the first assistant tool-call response for the canonical `get_weather`-style loop without response adapters. Covered by `test/integration/tool_calling/openai_tool_call_e2e.py:14-18`, `:147-165`.

AC-16b. **Framework-level smoke (release smoke / manual evidence).** When v0.1 is configured against at least one OpenAI-shape agent framework (one of: Cline, Aider, OpenCode, Continue, Vercel AI SDK), the first assistant tool-call response parses without macprovider-specific adapters. Per AC-14, the second turn is expected to fail; the framework-level smoke confirms first-turn shape parity, not multi-turn loop completion.

AC-17. For non-streaming receipt-bearing responses, SPEC-015 v0.3 §5.1–§5.3 canonical output object includes canonicalized `tool_calls[]` when tool calls are emitted. (Streaming receipts are out of scope per SPEC-015 v0.3.)

AC-18. A non-streaming Qwen3-Coder-class tool-call response completes through any production gateway deployment satisfying the SPEC-002 / SPEC-006 timeout invariants. Marked as **release smoke / manual evidence**: the integration runner `test/integration/tool_calling/openai_tool_call_e2e.py` produces a JSON artifact recording the `OPENAI_BASE_URL`, model SKU, response shape, and completion latency. v0.1 does not pin a specific public deployment URL.

AC-19. **modelID-match-required (Security C-1 (a)).** A request with enabled tools whose `modelID` does NOT substring-match any §3.1 family row produces no `tool_calls[]`, even when the underlying model output contains recognized sentinel markup (`<tool_call>`, `<|python_tag|>`). The response is emitted as plain assistant content.

AC-20. **Buyer-side validation obligation visibility (Security C-1 (b)).** Public documentation (README, examples, AC-16a/AC-16b harnesses) MUST state that emitted `tool_calls[]` reflect model output, not provider-verified intent, and that buyer-side agent frameworks MUST validate before execution. macprovider MUST NOT semantically validate `tool_calls[].function.name` or `function.arguments` against the buyer's tool policy.

AC-21. **Commit-worthy delta minimal-shape validation (Security H-1).** The coordinator commit-signal code path (§8.4) MUST validate that any `delta.tool_calls[]` event chosen as commit-worthy has integer `index`, non-empty `id` string, `type == "function"`, non-empty `function.name`, and parseable `function.arguments` JSON string. Malformed pre-commit deltas (e.g. `[{}]`) MUST NOT commit the response or settle provider-positive usage. Verified by a new coordinator test on the commit-signal path.

AC-22. **Mixed-sentinel fallback (Security m-1).** Output containing sentinels from multiple §3.1 families simultaneously (e.g. both `<tool_call>` and `<|python_tag|>` in the same response) produces no `tool_calls[]`; the response falls back to plain assistant content.

## 10. Future versions — Required, then Enhancement

### 10a. Required for full Ring-1 product (v0.2 normative targets)

Each item below is a v0.2 deliverable that gates the "actual Ring-1 product" release. A user running Cline / Cursor / Aider / OpenCode against macprovider for real coding work needs ALL of these, not just some:

1. **Multi-turn provider acceptance.** Provider accepts `role: "tool"` messages and assistant-history `tool_calls[]` without rejecting at the provider boundary. Closes AC-14 limitation. This is the gate between v0.1 wire-shape-certificate and v0.2 actual-product.
2. **Model-hash → family registry (closes Security C-1 path (c)).** Extends the live SPEC-008 Pillar A + SPEC-011 v0.5 `model_hash` infrastructure (already plumbed in `phase4-coordinator/internal/pool/provider.go:158-162`, `phase4-coordinator/internal/buyer/server.go:3743-3764`, and the `/v1/status` `model_hash` block) with a registry mapping `model_hash` → tool-call grammar family. The parser selects grammar from the verified loaded `model_hash`, not from the buyer-supplied `modelID` substring. Design questions: where the registry lives (binary, coordinator-pushed, community-signed), curation model, behavior when `model_hash` is unknown. These resolve as part of v0.2 SPEC design.
3. **Prompt-echo guard.** Parser refuses to synthesize `tool_calls[]` whose entire markup (sentinel + body + close-sentinel) appears verbatim in the request prompt content. Closes the residual prompt-injection vector where a tool-call-capable model echoes hostile content from a poisoned user prompt.
4. **Token-incremental streaming promotion.** Tool-call streaming MAY emit `delta.tool_calls[].function.arguments` as additive partial substrings as generation proceeds. Release gate: SDK compatibility, byte-equivalence of concatenated deltas vs. non-streaming `arguments`, and parse-failure fallback tests pass. v0.1 ratifies buffered-to-end (§4); v0.2 promotes.
5. **Structured `malformed_tool_call` signal.** Parse failures (malformed body, duplicate keys, undeclared name, sentinel-without-modelID, mixed sentinels) surface as a structured response-side signal — e.g. a `malformed_tool_call` field in the response object or a response header — so buyers can programmatically distinguish "normal model text" from "recognized tool-call parse failed." Replaces the current silent plain-content fallback observability gap (Security M-3).
6. **Multi-turn `tool_call_id` validation (Q3 closure).** Defines the buyer-side rule when a `role:"tool"` message echoes a `tool_call_id` that does not match any provider-minted ID — accept-and-treat-as-untracked, reject as `invalid_tool_call_id`, or behave per a SPEC-018-defined policy.
7. **`function.arguments` size cap (Q4 closure).** Defines a per-call and per-response cap on `function.arguments` byte length with fail-closed behavior. Closes the Security M-1 parser-DoS vector.

### 10b. Future enhancements (no committed version)

Items below are interesting but neither v0.2-gating nor on a named timeline:

- Structured output `response_format: {"type":"json_schema", ...}` response synthesis. (Same parser surface as tool calling; promoted when the wire contract for §10a #4 streaming-incremental stabilizes.)
- Prefix-cache request/response signaling. Requires SPEC-006 header-allowlist allocation (SPEC-006 owns the `X-MacProvider-*` namespace per its §2.X header-allowlist machinery); no concrete header name is reserved in SPEC-018.
- Per-call or per-response `max_tool_calls` cap.
- SDK examples or helper libraries (Python, TypeScript) for tool-call workloads. SDK packaging lives in SPEC-006 / a dedicated SDK SPEC, not in SPEC-018 — wire-shape is normative here, library packaging is downstream.
- Promotion of `id` minting from a per-response opaque UUID to a `(provider_id, request_id, choice_index)`-scoped identifier (Security M-2 v0.3+ candidate).

## 11. Open Questions

Q1. v0.1 streaming is buffered-to-end for tool-enabled requests. The promotion path is committed to §10a #4 with a defined release gate. The remaining question: which agent framework's user-visible streaming behavior change (incremental tool-call rendering) is the v0.2 release-readiness signal — Cline, Aider, OpenCode, or all of them?

Q2. Should provider-minted tool-call IDs eventually be deterministic so retries reproduce the same IDs, or remain non-deterministic UUIDs? v0.1 is non-deterministic; §10b reserves a `(provider_id, request_id, choice_index)` rescope as a future enhancement.

Q5. How does SPEC-018 interact with SPEC-011 warm-swap if a model swap occurs mid-tool-call? Is the call invalidated, retried, or completed against the original model snapshot? This is a multi-SPEC design question that may need a SPEC-011 v0.6 amendment.

Q6. **RESOLVED in v0.1.1.** Content-sentinel-only detection is no longer normative (§3.2). Model-hash-bound grammar selection is committed to §10a #2. Prompt-echo guard is committed to §10a #3. Documented for change-log continuity.

Q7. Receipt canonicalization (SPEC-015 v0.3) covers canonicalized `tool_calls[]` in non-streaming output object. Does v0.4 need to additionally bind the raw model text (with delimiters) to detect parser-side rewriting, or is the canonicalized `tool_calls[]` binding sufficient evidence?

Q9. Should v0.2 or later preserve prose interleaved with tool calls as `message.content`, since the OpenAI contract permits content alongside `tool_calls[]`, or should macprovider continue discarding it (current §2.4)?

## 12. Non-Goals

Provider-side agent execution is not a SPEC-018 feature. A provider MUST NOT run buyer tools, shell commands, filesystem operations, network egress, MCP clients, or sandboxed agent loops under SPEC-018. That Ring-2 product is reserved for SPEC-019.

Provider-hosted MCP servers are not a SPEC-018 feature. A provider MUST NOT expose provider-local MCP servers to the model's tool loop under SPEC-018. That Ring-3 product is reserved for SPEC-020.

Buyer-side tool execution validation is not a SPEC-018 feature. macprovider transports `tool_calls[]`; it does NOT semantically validate them against the buyer's tool policy, the buyer's framework permissions, or any provider-side allowlist. The buyer-side agent framework is the authority on whether to execute (§1, AC-20).

Provider-side model-fingerprint validation (model_hash → family registry binding) is not a v0.1 feature; it is reserved for v0.2 per §10a #2.

Prompt-echo injection prevention is not a v0.1 feature; it is reserved for v0.2 per §10a #3.

SPEC-018 v0.1 does not define SDK convenience layers, structured-output `response_format`, prefix-cache headers, token-incremental tool-call streaming, or `max_tool_calls` rate caps. §10a names what v0.2 will add; §10b lists enhancements without a committed version.
