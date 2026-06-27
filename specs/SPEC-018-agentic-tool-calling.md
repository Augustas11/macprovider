# SPEC-018 — Agentic tool calling (provider-side response synthesis)

**Version:** 0.1 (2026-06-27, initial draft — post-hoc ratification of cf2f135 + c823a96 + 7b8b1be)
**Depends on:** SPEC-001 v1.6, SPEC-002 v1.4.1, SPEC-006 v0.9
**Status:** Draft

## Change log

- v0.1 (2026-06-27): Initial draft — post-hoc ratification of cf2f135, c823a96, and 7b8b1be as the network's Ring-1 tool-calling baseline.

## 1. Scope

SPEC-018 defines OpenAI-compatible tool-calling wire compatibility for provider-side response synthesis on the macprovider network.

The v0.1 product surface is Ring 1 only: drop-in OpenAI `tool_calls` response wire shape for client-side agent frameworks. A buyer MAY point an OpenAI-shaped client at the buyer-side gateway and receive assistant tool-call responses that the client can parse without macprovider-specific response adapters.

The agent loop runs on the buyer's machine. The model runs on the seller. The network is the marketplace and transport.

A macprovider seller MUST emit OpenAI-wire-compatible `tool_calls[]` when a supported model output grammar produces tool calls and a request supplies enabled tools.

A macprovider seller MUST NOT execute tools on behalf of the buyer. The seller's job ends at emitting the `tool_calls[]` array.

The following products are out of scope for SPEC-018 entirely:

- Ring 2: provider-side agent execution, where a provider runs the agent loop locally with sandbox, filesystem, shell, or network egress authority. That product is reserved for SPEC-019.
- Ring 3: provider-hosted MCP servers reachable from the model's tool loop. That product is reserved for SPEC-020.

SPEC-018 v0.1 ratifies the as-built response-synthesis behavior in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift`, `OutputCanonicalizer.swift`, `ModelRuntime.swift`, `HTTPServer.swift`, `InferenceRelay.swift`, coordinator relay pass-through, and gateway pass-through.

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

IDs are non-deterministic. A retry of the same model output is not required to reproduce the same IDs. IDs MUST be unique within a multi-call response. Implementations MUST NOT use an incrementing per-response scheme if that scheme can collide across calls in the same response.

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
- JSON string arguments MUST be validated as a JSON object and MUST be emitted byte-for-byte as supplied by the model after validation.
- Python-style keyword arguments MUST be converted to a JSON object string with sorted keys, no insignificant whitespace, and without escaping `/`.
- Non-object argument values MUST NOT produce a tool call; the response falls back to plain assistant content.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:238-264`, `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:96-123`, and `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:169-188`.

### 2.4 Content Interleaving

The parser can collect prose outside tool-call delimiters as cleaned content. The v0.1 provider runtime discards that cleaned content whenever at least one tool call is parsed and returns tool calls only. Therefore, when the model emits prose before, between, or after recognized tool calls, the buyer-visible non-streaming message MUST contain `content = null` and the parsed `tool_calls[]`.

Source: parser behavior in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:29-50`; runtime discard in `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:826-839`; response emission in `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:819-828`.

## 3. Detection Grammar

The provider does not receive structured tool calls from the underlying MLX model. It receives plain text and parses recognized model-family output grammars.

The v0.1 grammar table is:

| Family | Detection pattern | Body grammar | Argument field | Source |
|---|---|---|---|---|
| Qwen2.5 / Qwen3 native | `modelID` contains `qwen2.5`, or raw output contains `<tool_call>` | `<tool_call>{...}</tool_call>` JSON body | `arguments` | `ToolCallParser.swift:451-491` |
| Qwen coding-tuned | raw output contains `<tool_call>` | `<tool_call>name(key=value, ...)</tool_call>` Python-style call | keyword args | `ToolCallParser.swift:77-123`, `ToolCallParser.swift:451-491` |
| Llama 3.3 MLX | `modelID` contains `llama-3.3`, or raw output contains `<\|python_tag\|>` | `<\|python_tag\|>{...}<\|eom_id\|>` JSON body or `<\|python_tag\|>name(key=value)<\|eom_id\|>` Python-style call | `parameters` for JSON body; keyword args for Python-style body | `ToolCallParser.swift:451-491` |

For JSON bodies, the body MUST parse as a JSON object with a non-empty string `name`. For Python-style bodies, the body MUST parse as `name(key=value, ...)` where `name` and keys are Python identifiers and values are supported string, boolean, null, integer, or decimal literals.

Ambiguous duplicate argument keys means any of the following:

- duplicate keys in the top-level JSON call object;
- duplicate keys in a nested JSON `arguments` or `parameters` object;
- duplicate keys in a JSON string supplied as `arguments` or `parameters`;
- duplicate keyword names in a Python-style call.

The v0.1 provider rejects ambiguous duplicate keys by abandoning tool-call synthesis and falling back to plain assistant content. It does not silently choose first-key-wins or last-key-wins.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:266-448`; locked by `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:125-159`.

If grammar detection fails, parsing fails, the function name is not declared in the request's enabled tools, or a value cannot be represented as a JSON-object `arguments` string, the provider MUST treat the model output as plain assistant content and MUST NOT emit `tool_calls[]`.

Source: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-27`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:826-839`.

If multiple family detectors could match the same output, the v0.1 detector checks Llama 3.3 before Qwen. Implementations MUST preserve this priority unless a later SPEC-018 version changes it.

A new model family's tool-call grammar MUST land via a SPEC-018 version bump. Parser PRs MUST NOT mutate this table silently.

## 4. Streaming Wire Shape

When `stream = true`, the buyer-visible response MUST use OpenAI-style SSE chat-completion chunks.

The v0.1 as-built streaming behavior is buffered-to-end for tool-enabled requests. It is not token-incremental for tool calls.

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

SPEC-001 identifies `malformed_tool_call` as an adversarial workload name in its error-taxonomy acceptance coverage. SPEC-018 v0.1 does not ratify `malformed_tool_call` as a provider response-synthesis API error code.

The v0.1 response-synthesis error behavior is:

- malformed recognized tool-call bodies fall back to plain assistant content;
- undeclared function names fall back to plain assistant content;
- duplicate JSON or Python argument keys fall back to plain assistant content;
- explicit `null`, non-object, or invalid JSON arguments fall back to plain assistant content;
- unsupported `tool_choice` values other than omitted, `null`, or `"auto"` produce HTTP 400 with code `unsupported_tool_choice`;
- current phase3 provider input containing `role: "tool"` or assistant history `tool_calls[]` produces HTTP 400 with code `unsupported_tool_messages`.

Source: fallback behavior in `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-27`; provider scope validation in `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:909-940`; tests in `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:99-155`.

SPEC-018 v0.1 imposes no `max_tool_calls` limit. No `tool_call_limit_exceeded` error exists in v0.1.

If the underlying model reaches `max_tokens` mid-tool-call and no complete tool call can be parsed, the provider MUST NOT emit a partial tool call. It emits plain assistant content with `finish_reason = "length"` when the token limit is reached.

Source: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:451-465`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:567-590`.

Coordinator request validation for malformed assistant-history `tool_calls[]` remains governed by SPEC-001 and SPEC-002. The coordinator uses HTTP 400 with code `invalid_tools` for invalid request-side tool schema.

Source: `phase4-coordinator/internal/buyer/server.go:2940-3007`.

## 6. Multi-Turn Round Trip

SPEC-001 and SPEC-002 define the request half for assistant-history `tool_calls[]` and `role: "tool"` messages. SPEC-018 adds the response-side ID invariant.

The provider-minted `tool_calls[].id` is opaque. A buyer-side agent framework that sends a subsequent `role: "tool"` message MUST echo the exact ID in `tool_call_id`. Coordinator and gateway components MUST NOT rewrite, canonicalize, strip, or reorder provider-minted IDs.

The coordinator MUST treat request-side `tool_calls` and `tool_call_id` values as pass-through fields after validation. This ratifies SPEC-002's value-typed pass-through rule for `tool_calls`.

Source: SPEC-002 `specs/SPEC-002-coordinator.md:1079-1085`, request validation in `specs/SPEC-002-coordinator.md:2280-2318`, and coordinator implementation in `phase4-coordinator/internal/buyer/server.go:1236-1240` and `phase4-coordinator/internal/buyer/server.go:2940-3007`.

V0.1 implementation limitation: the current phase3 provider rejects multi-turn tool-result messages at the provider boundary with `unsupported_tool_messages`. Therefore, SPEC-018 v0.1 ratifies response synthesis and transport pass-through, but it does not certify a full second-turn provider request after tool execution.

Source: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:920-940`; test coverage in `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:124-155`.

## 7. Gateway Timeout Co-Requirement

Commit c823a96 raised the gateway `ResponseHeaderTimeout` default from 10 seconds to 60 seconds because non-streaming large-model tool-call workloads can have first-response latency longer than 10 seconds. The current as-built gateway default is 300 seconds and validation requires the coordinator header timeout to be at least the coordinator request timeout.

Operators serving tool-call workloads MUST configure live gateway YAML with:

```yaml
timeouts:
  coordinator_header_timeout_seconds: >= 60
```

For current gateway builds, the configured value MUST also satisfy `coordinator_header_timeout_seconds >= coordinator_request_seconds`.

The rationale is specific to non-streaming tool-call requests: headers may not arrive until the provider finishes generation and response synthesis.

Source: historical c823a96 diff; current implementation in `phase5-gateway/internal/config/config.go:123-127`, `phase5-gateway/internal/config/config.go:183`, `phase5-gateway/internal/config/config.go:361-373`, `phase5-gateway/internal/config/config.go:462-475`, and `phase5-gateway/cmd/gateway/main.go:81-95`.

## 8. Coordinator and Gateway Pass-Through Invariants

Every transport component between provider runtime and buyer client MUST preserve tool-call fields opaquely unless this SPEC or an upstream SPEC explicitly authorizes validation.

### 8.1 Provider HTTP Server

The provider HTTP server emits the OpenAI non-streaming and streaming shapes. It MUST serialize `tool_calls[]` without raw model delimiters.

Source: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:776-891`; shape tests in `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:53-97` and `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:223-262`.

### 8.2 InferenceRelay

InferenceRelay MUST preserve the generated OpenAI JSON/SSE payloads as `data` strings when forwarding over the coordinator WebSocket relay. It MUST NOT parse, strip, reorder, or canonicalize `tool_calls[]`.

Source: `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:387-509`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:532-564`, and `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:566-650`.

### 8.3 Coordinator WebSocket Relay

The coordinator WebSocket relay MUST treat provider chunks as opaque payloads. It MUST route `InferenceResponseChunk.data` and `InferenceResponseEnd` frames by request ID and MUST NOT inspect tool-call fields.

Late encrypted frames for recently retired requests MUST be consumed according to c823a96 cleanup behavior and MUST NOT surface as spurious relay failures.

Source: `phase4-coordinator/internal/ws/relay.go:525-581`, `phase4-coordinator/internal/ws/relay.go:583-722`, `phase4-coordinator/internal/ws/relay.go:211-250`; frame shape in `phase4-coordinator/internal/ws/messages.go:199-225`.

### 8.4 Coordinator Buyer HTTP Forwarding

For WebSocket-backed non-streaming responses, the coordinator MUST write the provider response body bytes to the buyer without semantic rewriting. For WebSocket-backed streaming responses, it MUST write SSE chunks without rewriting `tool_calls[]`.

For direct provider HTTP streaming, the coordinator MAY inspect SSE events only to determine whether a response is commit-worthy. A non-empty `delta.tool_calls[]` is a commit-worthy OpenAI signal. After commit, the coordinator MUST pass bytes through without rewriting `tool_calls[]`.

Source: `phase4-coordinator/internal/buyer/server.go:1982-2195`, `phase4-coordinator/internal/buyer/server.go:2320-2473`, `phase4-coordinator/internal/buyer/server.go:2482-2605`; commit-signal tests in `phase4-coordinator/internal/buyer/server_internal_test.go:70-103`.

### 8.5 Gateway

The gateway MUST forward non-streaming response bodies and streaming SSE lines without semantic rewriting of `tool_calls[]`.

The streaming gateway MAY parse delta strings for token-estimate enforcement. It MUST count generated `function.arguments` string bytes and MUST NOT count `id`, `type`, or `name` strings as generated output.

Source: `phase5-gateway/internal/router/chat_proxy.go:237-516`, `phase5-gateway/internal/router/chat_proxy.go:652-717`; tests in `phase5-gateway/internal/router/server_test.go:2516-2580`.

## 9. Acceptance Criteria

AC-1. Given a request with enabled tool `foo` and model output `<tool_call>{"name":"foo","arguments":{"a":1}}</tool_call>`, the buyer-visible non-streaming response contains `choices[0].message.tool_calls[0].function.name == "foo"` and `choices[0].message.tool_calls[0].function.arguments == "{\"a\":1}"`.

AC-2. When any tool call is emitted, `choices[0].finish_reason == "tool_calls"`.

AC-3. For multiple recognized calls in one model output, response array order matches textual order.

AC-4. Response `tool_calls[].id` values start with `call_`, contain a lower-case hyphenless UUID suffix, and do not collide within the same response.

AC-5. Ambiguous duplicate argument keys produce no `tool_calls[]`; the response falls back to plain assistant content instead of first-key-wins or last-key-wins.

AC-6. Malformed recognized tool-call bodies produce no `tool_calls[]`; the response falls back to plain assistant content.

AC-7. Streaming tool-call responses contain no raw `<tool_call>`, `</tool_call>`, `<|python_tag|>`, or `<|eom_id|>` delimiters.

AC-8. Streaming tool-call responses emit one complete `delta.tool_calls[]` event after generation completes, followed by a terminator chunk with `finish_reason == "tool_calls"`.

AC-9. Concatenating streamed `function.arguments` fragments by `index` reproduces the non-streaming `function.arguments` string byte-for-byte. In v0.1 this is a single-fragment concatenation.

AC-10. `delta.content` and `delta.tool_calls` do not appear in the same SSE event.

AC-11. Coordinator WebSocket relay preserves provider-emitted `tool_calls[]` JSON across `InferenceResponseChunk.data` without stripping, reordering, or canonicalizing fields.

AC-12. Gateway non-streaming and streaming forwarding preserves provider-emitted `tool_calls[]` fields without semantic rewriting.

AC-13. `tool_choice` values other than omitted, `null`, or `"auto"` fail with HTTP 400 code `unsupported_tool_choice` at the current provider boundary.

AC-14. Current provider requests containing `role: "tool"` messages or assistant-history `tool_calls[]` fail with HTTP 400 code `unsupported_tool_messages`.

AC-15. Live gateway configuration for tool-call workloads sets `timeouts.coordinator_header_timeout_seconds >= 60`; current gateway builds also satisfy `coordinator_header_timeout_seconds >= coordinator_request_seconds`.

AC-16. An OpenAI Python SDK 1.x client pointed at the buyer URL can parse the first assistant tool-call response for the canonical `get_weather`-style loop without response adapters. SPEC-018 v0.1 does not certify the second provider turn after tool execution because AC-14 ratifies the current provider limitation.

AC-17. Receipt canonicalization includes canonicalized `tool_calls[]` in the output object when tool calls are emitted.

AC-18. A non-streaming Qwen3-Coder-class tool-call response completes through the public gateway, including `https://api.streamvc.live/v1` deployments, when `coordinator_header_timeout_seconds >= 60`.

## 10. Reserved for v0.2+

The following surfaces are reserved for future SPEC versions and are not part of SPEC-018 v0.1:

- Structured output and `response_format: {"type":"json_schema", ...}` response synthesis.
- Token-incremental streaming verification and promotion. V0.1 ratifies buffered-to-end streaming for tool-enabled requests.
- `X-MacProvider-Context-Cache` prefix-cache reuse header semantics.
- Python and TypeScript SDK wrappers over Sections 2 and 4.
- Per-call or per-response rate limits, including a `max_tool_calls` cap.
- Promotion of response parse failures from plain-content fallback to a structured `malformed_tool_call` error.
- Full provider-side acceptance of second-turn tool-result request messages.

## 11. Open Questions

Q1. V0.1 streaming is buffered-to-end for tool-enabled requests. Should v0.2 promote token-incremental `delta.tool_calls[].function.arguments` streaming after separate verification?

Q2. Should provider-minted tool-call IDs be deterministic so retries reproduce the same IDs, or remain non-deterministic UUIDs? V0.1 is non-deterministic, which minimizes collision risk but weakens retry reproducibility.

Q3. For multi-turn round trips, what should happen if the buyer sends a `tool_call_id` that does not match any ID the provider minted? Current phase3 provider rejects all tool-result messages before this check can occur.

Q4. Should v0.2 define a per-response cap on total `function.arguments` string length? V0.1 has no parser-specific cap beyond request, response, token, body, and gateway estimate limits.

Q5. How does SPEC-018 interact with SPEC-011 warm-swap if a model swap occurs mid-tool-call? Is the call invalidated, retried, or completed against the original model snapshot?

Q6. Detection currently keys on both `modelID` substring matches and output content sentinels. Is content-sentinel detection intentional flexibility, or does it create a model-fingerprinting or prompt-injection surface?

Q7. Receipt canonicalization currently covers canonicalized `tool_calls[]`, content, and finish reason, not the raw model text with delimiters. Should SPEC-015 v0.2 bind the raw model output, the synthesized OpenAI object, or both?

Q8. Should malformed recognized tool calls remain plain-content fallback, or should a future version emit a structured error such as `malformed_tool_call`?

Q9. Should future versions preserve prose interleaved with tool calls as `message.content`, since the OpenAI contract permits content alongside `tool_calls[]`, or should macprovider continue discarding it?

## 12. Non-Goals

Provider-side agent execution is not a SPEC-018 feature. A provider MUST NOT run buyer tools, shell commands, filesystem operations, network egress, MCP clients, or sandboxed agent loops under SPEC-018. That Ring-2 product is reserved for SPEC-019.

Provider-hosted MCP servers are not a SPEC-018 feature. A provider MUST NOT expose provider-local MCP servers to the model's tool loop under SPEC-018. That Ring-3 product is reserved for SPEC-020.

SPEC-018 v0.1 does not define SDK convenience layers, structured-output mode, prefix-cache headers, token-incremental tool-call streaming, or tool execution semantics.
