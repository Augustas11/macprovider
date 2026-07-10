# SPEC-019 - Structured output (`response_format: json_schema`)

**Version:** 0.2.4 (2026-06-29, LOCKED)
**Depends on:** SPEC-001, SPEC-006, SPEC-015, SPEC-018 v0.2.4 LOCKED
**Status:** LOCKED — r4 defensive audit returned 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6 lanes (4 codex + 2 Claude blind-spot).

## Quick orientation

SPEC-019 v0.1 is the provider-side structured-output contract for OpenAI-wire
`response_format`. Buyers can send `response_format:
{"type":"json_schema", ...}` to `/v1/chat/completions` and receive assistant
`content` that conforms to their schema, or a structured 502 with
`FaultBreakerQualifying` settlement.

The v0.1.0 slice is intentionally narrow: non-streaming only; post-hoc parse and
validate after inference, not constrained decoding; OpenAI strict-mode subset;
bundled `json_object` enforcement fix; no SPEC-015 schema change.

## Current code state

Current code anchors at `98336d9`: the provider request object stores
`responseFormat` (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:14`),
parses `response_format` before prompt-source capture
(`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:83`),
preserves the raw prompt-source field
(`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:144` and
`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:162`), but
the enum only allows `text` and `json_object`
(`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:239-241`)
and rejects any other type with HTTP 400
(`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:371-379`).
Runtime inference renders messages through `ToolPromptRenderer.renderMessages`
before MLX preparation in preflight, non-streaming, and streaming paths
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:400`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:454`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:540`) and only
post-processes native tool-call text through `parseToolCallsIfRequested`
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:483`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:598`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:873-886`).

Receipt binding needs no SPEC-015 schema change: SPEC-015's canonical prompt
object includes `response_format`
(`specs/SPEC-015-receipts.md:1191-1204`, canonical prompt JSON object fields),
and the provider implementation JCS-canonicalizes it into the prompt hash
(`phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:5-16`, JCS
encoder setup and prompt hash input). SPEC-006 already lists `response_format`
in the buyer API allow-list (`specs/SPEC-006-buyer-api.md:1036-1047`, allowed
chat-completions request fields).

SPEC-018 v0.2.4 is the precondition. The SPEC body is locked at `7e50832` via
PR #202, and the implementation landed at `c77313a` via PR #209
(`specs/design/spec-018/SPEC-018-v0_2-IMPL-NOTES.md:7-10`, release note and implementation
commit anchors). SPEC-018 §10b names structured-output response synthesis as the
follow-on surface promoted after streaming-incremental wire contract stability
(`specs/SPEC-018-agentic-tool-calling.md:671-675`, follow-on surface list).

v0.2.0 amendment anchors at `47dc2724`: the current provider still rejects
structured streaming before inference
(`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:220`,
`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:455-474`), and the
coordinator mirrors the `stream:true` rejects
(`phase4-coordinator/internal/buyer/server.go:3676-3687`). The current
streaming provider emits OpenAI-style SSE content deltas and terminates success
with `data: [DONE]`
(`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:520-587`,
`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1074-1085`,
`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1139-1148`). Current
streaming error fallback already writes an error envelope followed by `[DONE]`
after SSE has started
(`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:588-615`). The
non-streaming structured validator entry point is
`validateStructuredCompletion`
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:504-510`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:911-939`), while the
streaming path currently returns an unvalidated final `CompletionResult`
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:520-641`). The v0.1
schema subset reject helper rejects all unknown keywords at provider and
coordinator boundaries
(`phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:65-67`,
`phase4-coordinator/internal/buyer/server.go:3738-3742`), and current
coordinator tests still include `minimum`, `maximum`, `multipleOf`, and
`$schema` in the rejected-keyword fixture
(`phase4-coordinator/internal/buyer/structured_output_validation_test.go:80-85`).

## 1. Buyer-visible contract

**Cross-spec amendment**: SPEC-019 v0.1.0 supersedes SPEC-001
`response_format.type` allowed-values row. SPEC-001 currently allows only
`text` and `json_object` and treats `json_object` as a hint; SPEC-019 adds
`json_schema` and replaces the hint behavior with mandatory post-hoc
enforcement. No other SPEC-001 request fields change. The superseded row is
`specs/SPEC-001-phase3-binary.md:934`, which defines the prior
`response_format` object default, allowed values, hint behavior, and unknown
value rejection.

The provider accepts the OpenAI `response_format` field on the existing
`/v1/chat/completions` endpoint. The field has three supported values:

1. omitted or `{"type":"text"}`: normal assistant text.
2. `{"type":"json_object"}`: assistant `content` MUST be a JSON-parseable
   string whose top-level value is an object or array.
3. `{"type":"json_schema","json_schema":{...}}`: assistant `content` MUST be a
   JSON-parseable string conforming to `json_schema.schema`.

For `json_schema`, the object shape is:

```json
{
  "type": "json_schema",
  "json_schema": {
    "name": "machine_readable_name",
    "description": "optional human description",
    "strict": true,
    "schema": {
      "type": "object",
      "properties": {},
      "required": [],
      "additionalProperties": false
    }
  }
}
```

`json_schema.name` is required. `json_schema.description` is optional prompt
data. `json_schema.strict` is optional and defaults to `true`. v0.1.0 only
defines strict behavior; explicit `strict:false` MUST fail before inference with
HTTP 400 `json_schema_non_strict_unsupported`. The error message MUST say
non-strict structured output is unsupported in SPEC-019 v0.1.0.
`json_schema.schema` is required and MUST fit the §3 subset.

Buyer-side validation obligation: the provider validates syntax and schema
conformance for the returned assistant `content`; it does not validate whether
the values are semantically safe to execute, store, or trust. Buyers MUST apply
their own business-policy validation to parsed structured output before taking
side effects.

**Breaking change for `json_object` buyers**: before SPEC-019, buyers who sent
`response_format: {"type":"json_object"}` received unconstrained text (silent
no-op). v0.1.0 enforces top-level JSON object/array; malformed output is HTTP
502 `malformed_json_response`, `retryable:true`. Buyers relying on best-effort
text fallback under `json_object` MUST migrate to omitted or `{"type":"text"}`
before upgrade. v0.1.0 release notes MUST surface this change.

v0.1.0 is non-streaming only. A request with `response_format.type ==
"json_schema"` and `stream:true` MUST fail before inference with HTTP 400
`streaming_json_schema_unsupported`. `json_object` streaming enforcement is also
out of scope for v0.1.0; `json_object` with `stream:true` MUST fail before
inference with HTTP 400 `streaming_json_object_unsupported` rather than silently
stream unconstrained text. Error messages MUST carry the "unsupported in
SPEC-019 v0.1.0" context instead of versioning the error code.

**v0.2 streaming amendment**: v0.2.0 supersedes the v0.1.0 streaming reject
paragraph above for implementations advertising SPEC-019 v0.2. A request with
`stream:true` and `response_format.type == "json_schema"` is now accepted. A
request with `stream:true` and `response_format.type == "json_object"` is now
accepted. The provider emits normal OpenAI-compatible SSE `content` deltas
during generation and validates only after the stream reaches end-of-stream.
Streaming validation is end-of-stream validation over the concatenated assistant
content buffer, not incremental partial-JSON-prefix validation. On success, the
buyer sees the normal terminal `data: [DONE]`. On validation failure,
malformed JSON, empty / whitespace-only structured content, validator panic, or
validation timeout, the stream terminates with the same OpenAI-style terminal
SSE error-frame shape as SPEC-018 v0.2.4 §10d.4. The failure format is `data:
{"error":{...}}\n\n` followed by `data: [DONE]\n\n` when the buyer connection
can still be written (`specs/SPEC-018-agentic-tool-calling.md:736-753`,
`specs/SPEC-018-agentic-tool-calling.md:834-864`).

**v0.1.5 -> v0.2.0 behavior change**: buyers who depended on HTTP 400
`streaming_json_schema_unsupported` or `streaming_json_object_unsupported` to
detect unsupported structured streaming MUST update detection logic. v0.2
removes those buyer-visible reject codes from the active error-code table and
returns HTTP 200 `text/event-stream` for accepted streaming requests. Failure is
reported, if needed, as a terminal SSE error frame after inference has run. The
current v0.1 reject sites are the provider pre-stream gate
(`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:220`,
`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:455-474`) and the
coordinator pre-dispatch gate
(`phase4-coordinator/internal/buyer/server.go:3676-3687`).

Tools interaction: when both `tools` and `response_format.type ==
"json_schema"` are supplied, tool calls take precedence after inference. If the
model emits a valid tool call under SPEC-018, the response is a `tool_calls[]`
response and the SPEC-019 response schema does not apply to
`tool_calls[].function.arguments`; tool-call arguments are governed by the
tool's own JSON Schema. If the model does not emit a tool call, the assistant
content MUST satisfy this SPEC. Current runtime already performs tool parsing
only when request tools exist
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:873-886`, tool-call
parse gate).

## 2. Acceptance criteria

Every AC includes a "Fail condition" when an existing behavior could falsely
appear to satisfy the new contract. The fail condition names the old behavior
that must be proven absent.

### Request parsing

AC-1. `response_format.type == "json_schema"` is accepted by the provider
request parser and represented in the parsed request. Fail condition: current
HTTP 400 `invalid_request` path remains for `json_schema`
(`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:371-379`,
unknown `response_format.type` rejection).

AC-2. Missing `response_format.json_schema.name` returns HTTP 400
`json_schema_missing_name`, `param:"response_format.json_schema.name"`, and
`inference_ran:false`.

AC-3. Missing `response_format.json_schema.schema` returns HTTP 400
`json_schema_missing_schema`, `param:"response_format.json_schema.schema"`, and
`inference_ran:false`.

AC-4. `strict:false` returns HTTP 400
`json_schema_non_strict_unsupported`; it is not silently treated as
`strict:true` and not accepted as observability-only mode.

### Request validation

AC-5. A schema using any §3 rejected keyword returns HTTP 400
`json_schema_unsupported_keyword`, includes the offending keyword and JSON
pointer in the message or `param`, and does not reach inference.

AC-6. `strict:true` with any object schema that lacks
`additionalProperties:false` returns HTTP 400
`json_schema_strict_requires_additional_properties_false`. Nested object
schemas are checked recursively.

AC-7. `strict:true` with any object schema where `properties` contains a key not
listed in `required` returns HTTP 400
`json_schema_strict_requires_all_properties_required`. Nested object schemas
are checked recursively.

AC-8. Schemas with type-mismatched `const` or `enum`, for example
`{"type":"string","const":42}`, return HTTP 400
`json_schema_invalid_const_or_enum_type` with JSON-pointer `param`.

AC-8a. Invalid-name rejection: requests with `json_schema.name` that fails the
anchored regex `^[A-Za-z0-9_-]{1,64}$` return HTTP 400
`json_schema_invalid_name` at both provider parser and coordinator.
Adversarial fixtures include: 65-byte names, non-ASCII names (e.g. "café"),
names containing newline / control characters, substring-only valid sequences
(e.g. "good\nSYSTEM"), names with disallowed punctuation ("good.evil",
"valid<script>"). The dashed name "person-v1" MUST be accepted
(OpenAI-compatible; v0.1.1 incorrectly rejected this).

### Schema-shape & key-comparison

AC-9. NFC-vs-NFD property name fixture: a schema with NFC property name "café"
(U+0063 U+0061 U+0066 U+00E9) and a model output with NFD property name
`"cafe\u0301"` are byte-distinct; `additionalProperties:false` rejects the NFD
key as `json_schema_validation_failed`.
Adversarial extension: schema with NFC property name "café" plus
attacker-supplied output with visually-equivalent NFD property name
`"cafe\u0301"` -> validator rejects byte-distinct keys as
`json_schema_validation_failed` AND log / error envelope preserves the
offending byte sequence (escaped per JSON string rules; codepoints unchanged).
No Unicode normalization at log time. Future implementations MUST NOT weaken
byte-distinct comparison to NFC-normalized comparison; doing so breaks this AC.

### Caps

AC-10. A raw UTF-8 byte length greater than `16_384` for
`response_format.json_schema.schema` returns HTTP 413 `json_schema_too_large` at
both provider parser and coordinator boundary. Exactly `16_384` bytes succeeds
if the schema is otherwise valid.

AC-11. `json_schema.schema` byte-boundary tests cover exactly `16_384` raw
UTF-8 bytes accepted and `16_385` raw UTF-8 bytes rejected with HTTP 413
`json_schema_too_large` at provider and coordinator. The byte count is over the
schema JSON value as it appears in the request body, including insignificant
whitespace inside that value, not UTF-16 code units and not a compacted
post-parse serialization.

AC-12. Schema-depth fixture: a schema nested exactly 32 levels deep succeeds; 33
levels returns HTTP 400 `json_schema_too_deep` at both provider and coordinator.

AC-13. Deep-nesting fixture: validation rejects output whose decoded JSON depth
exceeds `32` with HTTP 502 `json_schema_validation_failed` and
`FaultBreakerQualifying`; valid depth `32` succeeds. This reuses the SPEC-018
depth posture (`phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-6`,
public depth and byte constants; `specs/SPEC-018-agentic-tool-calling.md:963-975`,
SPEC-018 cap table and fail-closed behavior).

### Output validation

AC-14. `response_format: {"type":"json_object"}` constrains the final assistant
content to valid JSON with top-level object or array. Fail condition: the
current silent no-op remains, where the field is parsed but never consulted by
runtime inference (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:83`,
parse field; `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:477-500`,
current non-streaming output handling).

AC-15. `response_format: {"type":"json_schema", ...}` produces assistant
`content` that parses as JSON and validates against `json_schema.schema` when
the model output is valid. The visible `message.content` is the JSON string, not
a parsed object.

AC-16. If final inference output is not JSON-parseable while `json_schema` or
`json_object` is requested, the provider returns HTTP 502
`malformed_json_response` with type `upstream_provider_error`,
`retryable:true`, `inference_ran:true`, and `settlement_ran:true`; the
coordinator records `FaultBreakerQualifying` and zero provider-positive
credits.

AC-17. If final inference output parses as JSON but fails schema validation, the
provider returns HTTP 502 `json_schema_validation_failed` with type
`upstream_provider_error`, `retryable:true`, `inference_ran:true`,
`settlement_ran:true`, and the offending RFC 6901 JSON pointer such as
`/path/to/field`; the coordinator records `FaultBreakerQualifying`.

AC-18. Empty-content fixture: when the model emits zero tokens after stop-token
filtering and `json_schema` or `json_object` is requested, the response is HTTP
502 `malformed_json_response`, not 200 with empty content. Settlement is
`FaultBreakerQualifying`. The envelope asserts `retryable:false` and an
actionable message recommending a buyer-side fix before retry.

AC-19. Response-cap order fixture: output over the `2_097_152`-byte response cap
returns HTTP 502 `response_byte_cap_exceeded` before JSON parsing or schema
validation runs, with `inference_ran:true`, `settlement_ran:true`, and
`FaultBreakerQualifying`.

### Streaming reject

AC-20. `response_format: {"type":"json_schema", ...}` with `stream:true`
returns HTTP 400 `streaming_json_schema_unsupported` with envelope
`type:"invalid_request_error"`, `param:"stream"`, `retryable:false`,
`inference_ran:false`, `settlement_ran:false`, and a message recommending
`stream:false` retry. Same envelope shape for
`streaming_json_object_unsupported`.

### v0.2 streaming

The AC-V2-* numbering below is additive and supersedes AC-20 only for
implementations advertising SPEC-019 v0.2. AC-20 remains the locked v0.1.x
contract.

AC-V2-1. `response_format: {"type":"json_schema", ...}` with `stream:true`
returns HTTP 200 `text/event-stream` and emits normal OpenAI-compatible SSE
content deltas. End-of-stream validation runs over the concatenated assistant
content buffer before success is finalized. Fail condition: either current
v0.1 reject code remains active
(`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:455-474`,
`phase4-coordinator/internal/buyer/server.go:3676-3687`), or the provider
skips structured validation on the final streaming buffer.

AC-V2-2. `response_format: {"type":"json_object"}` with `stream:true` returns
HTTP 200 `text/event-stream`, emits normal SSE content deltas, and validates the
concatenated final content as JSON whose top-level value is an object or array.
Fail condition: v0.1 `streaming_json_object_unsupported` remains active, or the
stream silently permits unconstrained text.

AC-V2-3. A streaming output that fails post-stream validation emits a terminal
SSE error frame matching SPEC-018 v0.2.4 §10d.4 minimum envelope fields
(`error.type`, `error.code`, `error.message`, optional `error.param`,
`error.retryable`, `error.request_id`, `error.inference_ran`,
`error.settlement_ran`) and the stream is settled
`FaultBreakerQualifying` with zero provider-positive credits. Fail condition:
the failure is normalized to `api_error`, returns a plain HTTP 502 after bytes
were already streamed, emits a success terminal only, or records
provider-positive settlement. Terminal SSE error frames for structured-output
validation failures MUST populate `request_id` and `settlement_ran:true`.

AC-V2-3a. Three-layer streaming validation pass-through: provider terminal
validation failure on the provider-to-coordinator WS path closes the stream with
`inference_response_end.status` in `{malformed_json_response,
json_schema_validation_failed}`, preserves retryability, and omits a receipt;
the coordinator SSE writer emits the terminal error frame with
`settlement_ran:true`; and the gateway forwards that terminal SSE error frame
verbatim through `[DONE]` without gateway-side positive / ok settlement and
without remapping to `stream_malformed` or any other code. Provider,
coordinator, and gateway behavior MUST each be enforced by a fixture or unit
test. This leverages the existing provider WS status allow-list precedent at
`phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:529`, the
coordinator writer site at
`phase4-coordinator/internal/buyer/server.go:5150-5170`, and the affected
gateway normalization site at
`phase5-gateway/internal/router/chat_proxy.go:482-557`, the full
`forwardLine` closure, and the gateway positive-settlement site at
`phase5-gateway/internal/router/chat_proxy.go:625-629`
(`settleReported("ok")` and `settleAfterCommit(..., "ok", ...)`). Test:
gateway MUST emit no `usage_events` row with `outcome:"ok"` for a stream whose
terminal SSE frame carries `error.code` in `{malformed_json_response,
json_schema_validation_failed}`. The gateway MUST also NOT remap the terminal
frame to `stream_malformed` via the `!hasChoices` parse branch at
`phase5-gateway/internal/router/chat_proxy.go:533`.

AC-V2-4. A streaming output whose concatenated content is valid JSON matching
`response_format.json_schema.schema` reaches the normal `data: [DONE]`
terminal and emits no terminal SSE error frame. Fail condition: successful
structured streaming is downgraded to non-streaming, or success emits both an
error frame and `[DONE]`.

AC-V2-5. Cline live-fixture: the fixture MUST pin the exact Cline upstream
commit under test and the exact `ai` SDK plus `@ai-sdk/openai-compatible`
package versions pinned by that commit. It MUST invoke the same AI SDK
streaming primitive used by Cline's active OpenAI-compatible call path on that
commit; source inspection of Cline HEAD
`4175677e712e429e1847964f4cd4884077c4ef66` found the active path using
`streamText(...)` in `sdk/packages/llms/src/providers/ai-sdk.ts` with
`ai@6.0.208` and `@ai-sdk/openai-compatible@2.0.51` in `bun.lock`, but the
release fixture README is the normative place to pin the final accepted commit
and versions. The fixture MUST capture the outbound POST body bytes and assert
`stream:true` plus the exact `response_format.json_schema` fields in that body
before asserting parsed output. Fail condition: a synthetic helper, stale Cline
dependency, uncaptured request body, or parsed-output-only assertion passes.

AC-V2-6. openai-python streaming fixture mirrors AC-15's successful
`json_schema` contract with `stream=True`: the fixture accumulates streamed
content deltas into the same JSON string shape and parses it into the expected
Pydantic object. The current non-streaming anchor pins `openai==2.44.0` and
`pydantic>=2,<3`
(`test/integration/spec_019/openai_python_strict_json_schema/requirements.txt:1-2`)
and captures `response_format.json_schema`
(`test/integration/spec_019/openai_python_strict_json_schema/fixture_request_body.json:9-31`).

AC-V2-7. Streaming token-incremental `content` deltas concatenate to the same
assistant content bytes as the non-streaming response for the same deterministic
fixture, modulo transport chunk boundaries. The provider already computes
content deltas from `emittedText` to the candidate/final text
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:562-592`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:603-619`); v0.2
requires the validated final buffer to be that same concatenation. Fail
condition: streaming validation uses bytes that differ from the buyer-visible
delta concatenation.

AC-V2-8. Empty-content streaming fixture: when the model emits zero tokens, or
only ASCII structured-output whitespace, under `json_schema` or `json_object`,
the stream ends with a terminal SSE error frame using
`malformed_json_response`, `retryable:false`, and an actionable buyer message.
This is the streaming analogue of AC-18 and reuses the current empty /
whitespace classification
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:942-956`). Fail
condition: the buyer sees 200 success with empty content, or the error is
`retryable:true`.

AC-V2-9. Streaming validation timeout: the timeout sources are provider-side
idle inactivity and wall-clock total deadline.

**Wall-clock total deadline (SPEC-019 v0.2 defined):** the streaming
structured-output request also fails closed when the wall-clock duration since
gateway-side first-byte-of-request exceeds 300 seconds. The gateway owns this
watcher; the value matches the `coordinator_request_seconds` configuration
field by convention. On wall-clock breach: the gateway emits a terminal SSE
error frame using the existing `provider_timeout` code (SPEC-006 §17.5 defines
`provider_timeout`, `specs/SPEC-006-buyer-api.md:2605`), settles the request as
`FaultBreakerQualifying` with zero provider-positive credits, and skips the
gateway-side ok / positive settlement path.

**Provider-side idle timeout** (separate watcher): the provider closes upstream
generation when no buyer-visible content delta is emitted for N seconds (N
deferred to v0.2.x). On idle breach: end-of-stream validation runs on the
buffer-as-of-close; the streaming SSE `provider_timeout` emit path at
`phase4-coordinator/internal/buyer/server.go:2386` carries the terminal frame;
settlement is `FaultBreakerQualifying`.

**Idle vs wall-clock:** both authorities own independent watchers. Either may
fire first. Whichever fires first produces the buyer-visible terminal frame; the
other authority MUST observe the closed stream and not fire a second time.

**Gateway-emit-provider_timeout** is the intended behavior of the gateway
watcher; the gateway IMPL MUST route SPEC-019 streaming wall-clock timeouts
through `provider_timeout` + skip ok/positive settlement (not through
`provider_disconnected` / `stream_truncated`). The existing 300s
upstream-request timeout site is
`phase5-gateway/internal/router/chat_proxy.go:225`; the current
`provider_disconnected` / `stream_truncated` path at
`phase5-gateway/internal/router/chat_proxy.go:592-614` MUST NOT classify
SPEC-019 streaming structured-output timeouts. The fixture set MUST include
streams that hit provider idle timeout and wall-clock deadline. Fail condition:
coordinator WS deadline, generic gateway read timeout classification, or an
unbounded connection becomes the normative timeout source; incomplete streaming
output is treated as successful structured output; the terminal timeout emits
`provider_disconnected` / `stream_truncated`; or the request earns
provider-positive credits.

AC-V2-9b. Streaming content byte cap: when the post-stop-token-filter
buyer-visible `content` delta concatenation exceeds the SPEC-019 v0.2 cap of
`2_097_152` bytes, the provider closes upstream generation and emits a terminal
SSE error frame using `response_byte_cap_exceeded`, with `inference_ran:true`,
`settlement_ran:true`, `FaultBreakerQualifying`, and no success receipt. The
fixture MUST cover the inclusive boundary and cap+1 failure. Fail condition:
over-cap streaming content is truncated and validated, settles provider-positive
credits, or invents a new error code.

AC-V2-10. Numeric bounds `minimum`, `maximum`, and `multipleOf` MUST be accepted
on `number` and `integer` schema nodes. The pre-inference
`json_schema_unsupported_keyword` reject is removed for these three keywords;
the output validator still enforces the constraints on decoded model output.
Fail condition: the current unknown-keyword reject path
(`phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift:65-67`,
`phase4-coordinator/internal/buyer/server.go:3738-3742`) still rejects any of
the three keywords.

AC-V2-10a. Numeric-bound type gate: any of `minimum`, `maximum`, or
`multipleOf` on a schema node whose `type` is not `number` or `integer` MUST
reject pre-inference at provider and coordinator with
`json_schema_unsupported_keyword` and `error.param` carrying the JSON pointer of
the offending node. Negative fixtures MUST cover `string`, `boolean`, `null`,
`array`, and `object` nodes carrying a numeric-bound keyword. Fail condition:
adding the three keywords to a global allow-list permits numeric bounds on
non-numeric schema nodes.

AC-V2-10b. Numeric-bound value validity: provider and coordinator
pre-inference validation MUST reject `multipleOf` values that are `0` or
negative; non-numeric JSON operand types in `multipleOf`, `minimum`, or
`maximum`; and same-node inverted bounds where both are present and
`minimum > maximum`. Schema-validation rejects use
`json_schema_unsupported_keyword`, with `error.param` pointing to the offending
keyword path such as
`response_format.json_schema.schema.properties.X.multipleOf`. Fixtures MUST
cover each invalid case at both provider and coordinator.

Per RFC 8259 §6, the JSON `number` production excludes the literals `NaN`,
`Infinity`, `+Infinity`, and `-Infinity`. All four are not valid JSON tokens, so
the **request-body JSON parser** at the coordinator
(`phase4-coordinator/internal/buyer/server.go:3467-3471`) and at the provider
(`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:22-27`)
rejects them BEFORE schema validation runs. The buyer-visible envelope for
these four literals MUST be HTTP 400 `invalid_json` (the standard request-body
parse error envelope), NOT `json_schema_unsupported_keyword`.

Negative fixtures for `NaN`, `Infinity`, `+Infinity`, and `-Infinity` in
numeric-bound positions MUST assert HTTP 400 `invalid_json`.

The `json_schema_unsupported_keyword` envelope (via §3 schema-subset reject
path) applies to non-numeric operand types only: strings, booleans, `null`,
arrays, and objects in `multipleOf` / `minimum` / `maximum` positions. Negative
fixtures for those five operand types MUST assert HTTP 400
`json_schema_unsupported_keyword` with `error.param` pointing at the offending
node path. Fail condition: invalid bound operands reach inference, NaN /
Infinity parse failures use the schema-validation envelope, non-numeric operand
type failures use the parse-error envelope, or any path invents a new
buyer-visible error code.

AC-V2-11. `$schema` at the top-level
`response_format.json_schema.schema` object MUST be accepted with any JSON
value and ignored for validation-time meta-schema selection. Top-level
`$schema` bytes still count toward `json_schema_max_bytes = 16_384` and are
JCS-canonicalized into the receipt `prompt_hash` per §9. `$schema` remains
rejected at nested schema nodes. Fail condition: the v0.1 fixture-side
normalization that strips top-level `$schema` is still required for an
otherwise valid request
(`test/integration/spec_019/vercel_ai_sdk_strict_json_schema/README.md:14-20`).

AC-V2-12. Vercel Zod paired fixture with `z.number().int()` is accepted
end-to-end without SDK-side normalization when emitted through
`@ai-sdk/openai-compatible@2.0.38` with `supportsStructuredOutputs:true`. This
closes the v0.1 AC-31 deferral where `.int()` was replaced by `z.number()` and
top-level `$schema` was stripped; the existing fixture documents that
normalization step
(`test/integration/spec_019/vercel_ai_sdk_strict_json_schema/README.md:8-20`).
The fixture MUST commit the captured request body bytes containing the actual
Vercel/Zod emission for `z.number().int()`, with no SDK-side rewrite step in
the fixture pipeline. Expected shape, subject to replacement by the actual
captured body if it differs, is top-level `$schema` plus
`{"type":"integer","minimum":-9007199254740991,"maximum":9007199254740991}` on
the integer property. The assertion order is captured body first, parsed output
second.
Fail condition: SDK-side schema rewriting is still needed to pass
pre-inference validation.

AC-V2-13. Partial-content negative streaming fixture set: the fixture set MUST
include **both** a Cline partial-content-then-terminal-error stream **AND** a
Vercel AI SDK partial-content-then-terminal-error stream. Both fixtures MUST:

- emit partial assistant content deltas visible to the buyer's parser,
- terminate with a SSE error frame whose `error.code` is in
  `{malformed_json_response, json_schema_validation_failed}`,
- assert that final SDK-side object parsing fails, with no partial-success path,
- document the contract that partial deltas pre-validation are provisional, not
  final.

Fail condition: buyer tooling treats partial deltas as successful structured
output after terminal validation failure, or only one of the Cline / Vercel
negative streaming fixtures is present.

AC-V2-14. Composite-render streaming invariant: for `stream:true + tools +
json_schema`, empty-tool-history and non-empty-tool-history fixtures MUST assert
byte-equivalent system-position composition through the existing
schema-adjusted `ChatMessage` -> `ToolPromptRenderer.renderMessages(...)` ->
`UserInput` order for Qwen3 and Llama-3.3. This is the streaming extension of
AC-22a / AC-22b without modifying the v0.1.5 locked AC body. Fail condition:
streaming render order diverges from the non-streaming composite-render
fixtures, or the schema instruction moves relative to the tool prompt template.

### Family rendering

AC-21. Family-prompt rendering fixtures for Qwen3 and Llama-3.3 show the schema
instruction is injected into the chat-template system position byte-equivalently
per family. The implementation MUST reuse the modelID-match family mechanism
used by `ToolPromptRenderer`
(`phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift:37-51`,
family matching) and the existing render hook sites
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:400`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:454`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:540`).

AC-22a. Composite-render empty-tool-history fixture: a request with `tools` and
`response_format:json_schema`, but no multi-turn tool data, follows the §4
order and renders the schema instruction byte-equivalently through the
`ToolPromptRenderer.renderMessages(...)` short-circuit path for Qwen3 and
Llama-3.3. Fail condition: the renderer drops, moves, or duplicates the schema
instruction when `containsMultiTurnToolData == false`.

AC-22b. Composite-render non-empty-tool-history fixture: a request with both
`tools` multi-turn history and `response_format:json_schema` follows the §4
order and renders BOTH the schema instruction and the family-keyed tool prompt
template in the deterministic system-position composition, byte-equivalent to
the Qwen3 / Llama-3.3 fixture. Fail condition: alternative ordering, missing
schema instruction, missing tool template markup, or mutation of the original
`tools` array.

AC-23. Concurrent-request fixture: two simultaneous requests with different
schemas render their own schemas into their own system prompts; no cross-render
between requests.

### Tool × schema interaction

AC-24. Tools plus `json_schema` interaction is deterministic: valid tool-call
output returns `tool_calls[]` and skips response-schema validation of tool-call
arguments; no valid tool-call output requires structured assistant content
validation. Fail condition: schema validation is applied to tool-call arguments,
or a valid tool call is discarded solely because `json_schema` is present.

### Money path & receipt ordering

AC-25. Provider receipt regression tests prove `prompt_hash` changes when any
byte of `response_format.json_schema.schema` changes. This is a no-schema-change
regression against SPEC-015's `response_format` canonical prompt field
(`specs/SPEC-015-receipts.md:1191-1204`, canonical prompt object includes
`response_format`) and current JCS implementation
(`phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:5-16`, JCS
canonicalizer behavior).

AC-26. Money-path proof: `malformed_json_response` and
`json_schema_validation_failed` produce `FaultBreakerQualifying` request-log
rows and zero provider-positive credits. The billing recorder normalizes empty
fault flags only when none is provided
(`phase4-coordinator/internal/buyer/billing_recorder.go:192-194`), and the
billing formula returns before positive-credit calculation for
`FaultBreakerQualifying` (`phase4-coordinator/internal/billing/formula.go:112-114`).
Order-of-operations regression test: no success receipt row, no sticky success
write, and no positive billing row exist when post-hoc validation fails.
Validator exceptions, resource-limit aborts, and recursion overflow MUST be
converted to terminal 502 with SPEC-019 code, `inference_ran:true`,
`settlement_ran:true`, `FaultBreakerQualifying`, zero provider-positive credits.

### Coordinator / gateway parity

AC-27. Coordinator validation parity: coordinator request validation extends
the current `response_format.type` allow-list from `text|json_object` to
`text|json_object|json_schema` and enforces the same `16_384` schema cap and
32-level schema-depth cap before dispatch
(`phase4-coordinator/internal/buyer/server.go:3608-3615`, current
`response_format.type` validation).

AC-28. Gateway pass-through remains byte-preserving for request bodies. The
gateway may parse enough to enforce existing quota and stream routing, but it
MUST forward the original request bytes to the coordinator as it does today
(`phase5-gateway/internal/router/chat_proxy.go:102-117`, inbound body read;
`phase5-gateway/internal/router/chat_proxy.go:217-224`, coordinator request
construction from `bytes.NewReader(body)`).

AC-28a. `Content-Encoding` reject fixture: a request whose
`Content-Encoding` header has a normalized field value other than exactly
`identity` (RFC 9110 §8.4.1.1 no-op encoding) returns HTTP 415
`request_content_encoding_unsupported`, `param:"Content-Encoding"`,
`retryable:false`, `inference_ran:false`, `settlement_ran:false`,
identical at gateway and coordinator (parity). Both gzip-compressed
JSON bodies and a header-only fixture (no actual compression) MUST
reject; the SPEC does not require the gateway/coordinator to validate
the body's compression. Accepted: omitted `Content-Encoding` and
`Content-Encoding: identity` (case-insensitive per RFC 9110 §5.5;
optionally surrounded by whitespace, which the parser MUST strip
before comparison). Adversarial fixtures MUST include: `gzip`,
`deflate`, `br`, empty-after-trim (header present with whitespace-only
value), whitespace-surrounded `identity` (accepted after normalization),
case-variant `Identity` / `IDENTITY` (accepted), and a comma-separated
multi-value `identity, gzip` (rejected — not exactly `identity`).

### Buyer-facing UX

AC-29. Cline negative regression: a Cline-style `streamText` request WITHOUT
`response_format` is unaffected by SPEC-019. No new validation, no new error
envelope, no behavior change.

### Forward-compat regression fixtures

AC-30. openai-python paired fixture:
`test/integration/spec_019/openai_python_strict_json_schema/` contains:
- request body with `response_format.json_schema` for `Person`
  (Pydantic model: `class Person(BaseModel): name: str; age: float`
  -- note v0.1.0 fixture uses `float` rather than `int` so that the
  emitted JSON Schema `{"type":"number"}` matches Vercel AI SDK's
  `z.number()` output for byte parity per AC-31),
- `openai==2.44.0`,
- captured outbound HTTP body (`fixture_request_body.json`),
- expected returned parsed `Person` model,
- golden OpenAI `gpt-4o-2024-08-06` response committed for side-by-side
  comparison.
The macprovider response parses into the same `Person` model and the
JCS-canonicalized `response_format.json_schema.schema` matches the golden
fixture modulo an explicit allow-list (`title`, `description`, `$schema`).

AC-31. Vercel AI SDK paired fixture: `test/integration/spec_019/
vercel_ai_sdk_strict_json_schema/` uses the SAME logical `Person` contract as
AC-30 translated to a v0.1.0-compatible Zod shape: `z.object({ name:
z.string(), age: z.number() })`. (`z.number().int()` emits `minimum`/`maximum`
keywords which §3 rejects; v0.1.0 fixtures use unconstrained `z.number()` until
v0.2 widens the §3 subset to include numeric bounds.) The fixture captures the
outbound HTTP body (`fixture_request_body.json`). A normalization step strips
the `$schema` top-level key from the captured Vercel body before
canonical-schema comparison; v0.1.0 §3 rejects `$schema` (per AC-5
rejected-keyword list). With `createOpenAICompatible({
supportsStructuredOutputs: true, ... })` and `@ai-sdk/openai-compatible
@2.0.38`, the AC asserts `response_format.type == "json_schema"`,
`json_schema.strict == true`. The JCS-canonicalized
`response_format.json_schema.schema` MUST match the AC-30 Pydantic schema modulo
`title` / `description` AND `$schema`. v0.1.0 documents the `$schema` strip +
`.int()` substitution as v0.1.0 fixture constraints; v0.2 considers widening §3
to accept these keywords. Production Vercel buyers using
`supportsStructuredOutputs:true` without the test-side `$schema` normalization
receive HTTP 400 from §3's rejected-keyword list in v0.1.0.

AC-32. Vercel default-path fixture (separate file): without
`supportsStructuredOutputs:true`, Vercel emits `json_object` not `json_schema`.
Asserts default path remains v0.1.1 `json_object` enforcement (AC-7).

AC-33. Prompt-injection fixture covers hostile strings in
`json_schema.description`, `json_schema.name`, property names, property
descriptions, enum values, and const values. Hostile strings cannot terminate
the schema instruction block, cannot inject system role text, and cannot inject
tool-call sentinels.

AC-34. Duplicate-key fixture: if model output contains duplicate JSON object
keys and `json_schema` or `json_object` is requested, the provider fails closed
with HTTP 502 `malformed_json_response` rather than accepting parser-dependent
first-key-wins or last-key-wins behavior.

## 3. Schema-subset grammar

Reference: OpenAI Structured Outputs strict-mode documentation
(`https://platform.openai.com/docs/guides/structured-outputs`) is an external
compatibility reference, not the normative source for this SPEC. This section is
normative for macprovider v0.1.0.

Allowed schema keywords:

| Keyword | Allowed shape | v0.1.0 rule |
|---|---|---|
| `type` | string enum: `object`, `array`, `string`, `number`, `integer`, `boolean`, `null` | REQUIRED at every schema node. |
| `properties` | object of property name to schema | Allowed only when `type:"object"`. |
| `required` | array of unique strings | Allowed only when `type:"object"`; each entry MUST name a key in `properties`. |
| `items` | schema object | REQUIRED when `type:"array"`; disallowed otherwise. |
| `enum` | array of JSON scalar values | Values MUST be valid JSON scalars and conform to `type`. |
| `const` | JSON scalar value | Value MUST conform to `type`. |
| `additionalProperties` | exactly `false` | REQUIRED for every object schema under `strict:true`. |
| `description` | string | Prompt data only; no validation effect. |
| `title` | string | Prompt data only; no validation effect. |

Rejected keywords in v0.1.0: count = 34. v0.1.0 rejects `oneOf`, `anyOf`,
`allOf`, `not`, `$schema`, `$ref`, `$defs`, `definitions`, `pattern`, `format`,
`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`,
`minLength`, `maxLength`, `minItems`, `maxItems`, `uniqueItems`, `contains`,
`minProperties`, `maxProperties`, `propertyNames`, `patternProperties`,
`dependentSchemas`, `dependentRequired`, `if`, `then`, `else`, `default`,
`examples`, `readOnly`, `writeOnly`, and any unknown keyword. Rejection uses
HTTP 400 `json_schema_unsupported_keyword`.

**v0.2 schema-subset amendment**: v0.2.0 widens the v0.1.0 subset in exactly
four places:

- `minimum` is allowed only on schema nodes whose `type` is `number` or
  `integer`.
- `maximum` is allowed only on schema nodes whose `type` is `number` or
  `integer`.
- `multipleOf` is allowed only on schema nodes whose `type` is `number` or
  `integer`.
- `$schema` is allowed only as a top-level key of
  `response_format.json_schema.schema`. The value MAY be any JSON value. The
  provider and coordinator MUST ignore it for meta-schema selection and MUST
  validate against the SPEC-019 subset, not against the URI or value named by
  `$schema`.

Top-level `$schema` bytes count toward `json_schema_max_bytes = 16_384` and are
JCS-canonicalized into the receipt `prompt_hash` per §9. '`$schema` is ignored'
refers only to validation-time meta-schema selection -- `$schema` bytes are NOT
excluded from cap accounting or receipt prompt-hash binding.

The v0.2 rejected-keyword list is otherwise unchanged. `oneOf`, `anyOf`,
`allOf`, `not`, `$ref`, `$defs`, `definitions`, `pattern`, `format`,
`exclusiveMinimum`, `exclusiveMaximum`, `minLength`, `maxLength`, `minItems`,
`maxItems`, `uniqueItems`, `contains`, `minProperties`, `maxProperties`,
`propertyNames`, `patternProperties`, `dependentSchemas`, `dependentRequired`,
`if`, `then`, `else`, `default`, `examples`, `readOnly`, `writeOnly`, nested
`$schema`, and any unknown keyword still fail before inference with HTTP 400
`json_schema_unsupported_keyword`.

Pre-inference subset checking acknowledges `minimum`, `maximum`, and
`multipleOf` as valid keywords but does not satisfy the output constraint by
itself. The runtime validator MUST enforce these keywords against the decoded
model output when validating `json_schema` responses.

Pre-inference numeric-bound validation is type-conditional and value-checked.
`minimum`, `maximum`, and `multipleOf` are supported only on schema nodes whose
`type` is `number` or `integer`; use on any other node type rejects before
inference with HTTP 400 `json_schema_unsupported_keyword`. `multipleOf` values
MUST be JSON numbers greater than `0`; `0`, negative values, and non-number JSON
values reject before inference. `minimum` and `maximum` values MUST be JSON
numbers; strings, `null`, booleans, arrays, and objects reject before inference.
When both `minimum` and `maximum` are present on the same schema node,
`minimum <= maximum` is required; inverted bounds reject before inference. All
rejects in this paragraph use the existing `json_schema_unsupported_keyword`
code with `error.param` pointing at the offending keyword path, such as
`response_format.json_schema.schema.properties.X.multipleOf`; v0.2 does not add
a numeric-bound-specific error code.

The schema root MAY be any allowed `type`, including array or scalar. If the
root is an object, it MUST include `additionalProperties:false` under
`strict:true`. If a nested schema is an object, the same rule applies
recursively. Under `strict:true`, an object schema's `required` array MUST
contain every key in `properties`. The reverse direction, every entry in
`required` MUST name a key in `properties`, is already required. Violation
returns HTTP 400 `json_schema_strict_requires_all_properties_required`,
`param` = JSON pointer of the offending object node.

A schema where `const` or any `enum` element does not conform to `type` returns
HTTP 400 `json_schema_invalid_const_or_enum_type`, `param` = JSON pointer of
the offending node.

Property names are compared by raw UTF-8 byte sequence. No Unicode
normalization is applied at validation. Two property names with different byte
sequences are distinct keys even if they normalize to the same form.

`json_schema.name` is buyer-controlled, untrusted prompt data when rendered
into the system-position chat template. The provider request parser and
coordinator validator MUST reject names that do not match the anchored regex
`^[A-Za-z0-9_-]{1,64}$` (OpenAI-compatible machine-name shape: letters,
digits, underscore, hyphen, 1-64 bytes). Names that fail this constraint return
HTTP 400 `json_schema_invalid_name`,
`param:"response_format.json_schema.name"`, `inference_ran:false`. Provider and
coordinator MUST enforce identical constraint semantics; a coordinator-direct
path that bypasses the provider parser MUST still reject.

The validator MUST reject schemas that rely on unsupported keywords for safety
or correctness.

## 4. Family rendering

The provider MUST improve probability of valid JSON by injecting a
family-specific system instruction before inference. This is prompt guidance,
not a substitute for §5 validation.

Rendering uses the same family key mechanism as SPEC-018 v0.2: modelID
substring match for Qwen (`qwen2.5` or `qwen3`) and Llama-3.3 (`llama-3.3`), as
implemented by `ToolPromptRenderer`
(`phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift:37-51`, family
matching). The render hook lives where `ToolPromptRenderer.renderMessages` is
currently called before `context.processor.prepare`
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:400`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:454`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:540`). v0.1.0 MUST
NOT introduce a model-hash registry.

The injected instruction MUST be placed in the chat-template system position.
If the buyer supplied a system message, the structured-output instruction is
appended after it with a deterministic separator. If no system message exists,
the renderer creates one. The instruction MUST include:

- the `json_schema.name`;
- the optional `json_schema.description` as JSON-escaped data;
- the exact schema JSON, deterministically serialized with sorted keys and no
  insignificant whitespace;
- the directive that the final assistant content must be only JSON with no
  Markdown fences, prose preface, or trailing commentary.

**Composite render rule when both `tools` and `response_format: json_schema`
are present** — the implementation MUST follow this exact order at each
`ModelRuntime.swift` hook site (cite `:400`, `:454`, `:540`):

1. Construct schema-adjusted `ChatMessage` values: prepend the
   structured-output schema instruction to the system-position message,
   leaving all other messages unchanged.
2. Pass the adjusted `ChatMessage` array to
   `ToolPromptRenderer.renderMessages(...)`. The renderer is a no-op
   short-circuit when no multi-turn tool data is present
   (`containsMultiTurnToolData == false`) and renders the family-keyed
   tool prompt-template when present; either path preserves the
   prepended schema instruction.
3. Construct `UserInput(chat: rendered, tools: request.tools)` with the
   original `tools` array unchanged.

This is a single normative order. No alternative ordering is permitted.
A request with both `tools` history and `response_format: json_schema`
produces a deterministic system-position composed of: schema
instruction followed by family-keyed tool prompt-template markup.

**Stateless renderer**: the structured-output renderer MUST be stateless across
requests in v0.1.0. No schema cache (in-process, per-connection, or per-family)
is permitted. Schema warm-cache is deferred to v0.2 per §10.

Qwen3 fixture requirement: input messages plus a simple object schema render to
a Qwen-family chat template with the schema instruction in the system segment.

Llama-3.3 fixture requirement: the same request renders to the Llama-3.3 system
segment using the Llama family template.

Descriptions, enum strings, const strings, property names, and
`json_schema.name` are untrusted prompt data. They MUST be embedded only as JSON
string data inside the schema block; renderer tests MUST include attempts to
close the block, inject new system text, and include tool-call sentinels.

**v0.2 amendment**: no family-rendering rule changes in v0.2. Streaming
structured output uses the same family-keyed renderer and the same composite
render order. The only streaming-specific change is that the final concatenated
assistant content buffer is validated at end-of-stream.

## 5. Validator behavior

After non-streaming inference completes and stop-token filtering has run
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:477-483`,
non-streaming post-processing; `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:592-599`,
streaming final post-processing; `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:811-828`,
stop-token filtering), the provider applies this sequence:

1. If valid SPEC-018 tool calls were produced and request tools are enabled,
   return the tool-call response and skip SPEC-019 content validation.
2. If `response_format.type == "text"`, return normal assistant content.
3. If `response_format.type == "json_object"`, parse final assistant content as
   JSON, reject duplicate keys, and require root object or array.
4. If `response_format.type == "json_schema"`, parse final assistant content as
   JSON, reject duplicate keys, validate decoded JSON depth, and validate
   against the supplied schema subset.

**Normative ordering**: a success receipt MUST NOT be emitted, a sticky success
route MUST NOT be written, and no provider-positive billing row MUST be created
until post-hoc structured-output validation has completed and returned success.
On `malformed_json_response` or `json_schema_validation_failed`, no success
receipt is emitted; the request is settled as `FaultBreakerQualifying` per §8
with zero provider-positive credits.

**Validator panic / fatal-error catch-all**: after inference starts, every
structured-output postprocess failure path MUST be caught and converted to a
terminal HTTP 502 SPEC-019 envelope with `inference_ran:true`,
`settlement_ran:true`, `FaultBreakerQualifying`, no success receipt emitted, no
sticky-success route written, and zero provider-positive credits. Failure modes
covered: thrown errors, runtime panics or fatal assertions, recursion /
stack-overflow, resource-limit aborts (timeout / memory), and any unexpected
validator internal error. Fallback code mapping: JSON parse internals →
`malformed_json_response`; validator internals →
`json_schema_validation_failed`. An empty / default HTTP 500 from the request
handler MUST NOT escape this boundary on the structured-output postprocess
path.

**Partial-validator-state rule**: when the validator does not complete normally
— thrown error, panic / fatal assertion, recursion / stack overflow,
resource-limit abort, or any other internal failure — partial validation state
MUST be discarded before emitting the fallback envelope. The fallback envelope
MUST use `error.param:""` (RFC 6901 root) and a generic message (e.g. "Schema
validation aborted before completion"); the envelope MUST NOT report a JSON
pointer derived from partially-completed validation, since that pointer could
mislead the buyer about which field actually failed.

**Empty content under `json_schema` / `json_object`**: if final inference output
(post stop-token filtering,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:811-828`) is the empty
string `""`, the response is classified as HTTP 502 `malformed_json_response`
with `inference_ran:true`, `settlement_ran:true`, `FaultBreakerQualifying`.
Empty string is not a JSON value.

**Empty-content subcase override**: when the offending output is the empty
string `""` after stop-token filtering, the response envelope MUST set
`retryable:false` and the `error.message` MUST recommend a buyer-side fix (e.g.
"Model emitted zero tokens for the requested schema; adjust `temperature` /
`seed` (for stochastic models), or modify the prompt or schema before retrying
— automatic same-request retry will not succeed."). This prevents deterministic
empty output from burning the buyer's retry budget. Non-empty malformed JSON
output keeps `retryable:true` per the standard envelope.

**Retry semantics**: `retryable:false` means the buyer's SDK SHOULD NOT blindly
replay the identical request (including same `seed` / `temperature` / `prompt` /
`schema`). Buyers MAY issue a deliberately modified retry — different `seed`,
different `temperature`, a relaxed schema, or a clarifying prompt — after their
own retry policy decision. The `retryable:false` value prevents the SDK
auto-retry loop, not buyer-initiated recovery.

`malformed_json_response` is used when parsing fails, duplicate keys are found,
the top-level value is not object-or-array for `json_object`, the final content
is empty, or the model output cannot be represented as valid UTF-8 JSON text. It
is HTTP 502, `type:"upstream_provider_error"`, `retryable:true`,
`inference_ran:true`, and `settlement_ran:true`.

`json_schema_validation_failed` is used when parsed JSON fails schema
validation. It is HTTP 502, `type:"upstream_provider_error"`,
`retryable:true`, `inference_ran:true`, and `settlement_ran:true`. The envelope
MUST include the first offending RFC 6901 JSON pointer in `error.param`; for
root-level failures, the JSON pointer is the empty string `""`, per RFC 6901
§5. The message SHOULD include the expected type or keyword that failed, but
buyers MUST key retry logic off `error.code`.

No internal retry is allowed in v0.1.0. Buyer retries happen at the buyer layer.

### v0.2 streaming validation

For `stream:true` with `json_schema` or `json_object`, the validator runs at
end-of-stream over the exact byte-equivalent concatenation of buyer-visible SSE
`content` deltas. This is the same post-hoc validation posture as v0.1
non-streaming, using the same structured validator semantics; v0.2 relaxes the
pre-inference `stream:true` reject gate rather than introducing constrained
decoding. Current non-streaming validation is anchored at
`validateStructuredCompletion`
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:504-510`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:911-939`), and the
current streaming path already returns the final `CompletionResult` after
emitting content deltas
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:562-641`).

Validation trigger: when the streaming generator is ready to emit its success
terminal `[DONE]`, the provider first validates the concatenated content buffer.
If validation succeeds, the provider emits the normal finish chunk, optional
usage chunk, and `data: [DONE]` success terminal. If validation fails, the
provider emits a terminal SSE error frame in the SPEC-018 v0.2.4 §10d.4 shape
and does not emit a success terminal. The current provider success terminal is
`writeSSEDone()`
(`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:568-587`,
`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1084-1089`), and the
current post-start error path already writes `error.envelope` followed by
`[DONE]`
(`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:588-592`).

Empty-content and whitespace-only override: the v0.1 empty-content rule applies
unchanged, except the buyer-visible surface is a terminal SSE error frame rather
than HTTP 502 after a non-streaming response. Empty string and ASCII
whitespace-only content map to `malformed_json_response`, `retryable:false`,
and an actionable buyer-side message
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:942-956`).

Validator panic / fatal-error catch-all: the v0.1 catch-all posture applies to
streaming end-of-stream validation. A panic, thrown error, recursion abort,
resource-limit abort, timeout, or unexpected validator internal error during
streaming validation MUST become a terminal SSE error frame with
`FaultBreakerQualifying`, no success receipt, no sticky-success route, and zero
provider-positive credits. Partial validator state MUST be discarded as in the
v0.1 rule.

SPEC-019 v0.2.3 defines two independent streaming-validation timeout
authorities. The provider owns the idle watcher: if no buyer-visible `content`
delta is emitted for N seconds, where N is deferred to a future v0.2.x, the
provider MUST close upstream generation, run end-of-stream validation over the
post-stop-token-filter concatenated `content` buffer as of close, and emit a
terminal SSE error frame through the streaming `provider_timeout` path
(`phase4-coordinator/internal/buyer/server.go:2386`). Settlement is
`FaultBreakerQualifying`.

The gateway owns the wall-clock watcher: the streaming structured-output request
also fails closed when the wall-clock duration since gateway-side
first-byte-of-request exceeds 300 seconds. The value matches the
`coordinator_request_seconds` configuration field by convention; SPEC-019 v0.2,
not SPEC-006, defines this wall-clock semantic. On wall-clock breach, the
gateway emits a terminal SSE error frame using the existing `provider_timeout`
code (SPEC-006 §17.5 defines `provider_timeout`,
`specs/SPEC-006-buyer-api.md:2605`), settles the request as
`FaultBreakerQualifying` with zero provider-positive credits, and skips the
gateway-side ok / positive settlement path. The gateway IMPL MUST route
SPEC-019 streaming wall-clock timeouts through `provider_timeout`, not through
the `provider_disconnected` / `stream_truncated` path currently associated with
the gateway timeout surface (`phase5-gateway/internal/router/chat_proxy.go:225`,
`:592-614`). Either timeout authority may fire first; whichever fires first
produces the buyer-visible terminal frame, and the other authority MUST observe
the closed stream and not fire a second time. Coordinator WS deadlines and
generic gateway read-timeout classification remain transport safety mechanisms,
not the normative structured-output validation-timeout authority.

### SPEC-019 error codes

| Code | HTTP | Phase | Retryable | Notes |
|---|---:|---|---|---|
| `json_schema_missing_name` | 400 | pre-inference request validation | false | Missing `response_format.json_schema.name`. |
| `json_schema_missing_schema` | 400 | pre-inference request validation | false | Missing `response_format.json_schema.schema`. |
| `json_schema_non_strict_unsupported` | 400 | pre-inference request validation | false | `strict:false` unsupported in SPEC-019 v0.1.0. |
| `streaming_json_schema_unsupported` | 400 | pre-inference request validation | false | v0.1.x-only migration code for `json_schema` with `stream:true`; deleted from active v0.2. |
| `streaming_json_object_unsupported` | 400 | pre-inference request validation | false | v0.1.x-only migration code for `json_object` with `stream:true`; deleted from active v0.2. |
| `json_schema_unsupported_keyword` | 400 | pre-inference request validation | false | Unsupported schema keyword. |
| `json_schema_strict_requires_additional_properties_false` | 400 | pre-inference request validation | false | Object schema lacks `additionalProperties:false`. |
| `json_schema_strict_requires_all_properties_required` | 400 | pre-inference request validation | false | Strict object properties not all required. |
| `json_schema_invalid_const_or_enum_type` | 400 | pre-inference request validation | false | `const` or `enum` value conflicts with `type`. |
| `json_schema_invalid_name` | 400 | pre-inference request validation | false | `json_schema.name` outside machine-name constraint. |
| `json_schema_too_large` | 413 | pre-inference request validation | false | Schema JSON value over `16_384` raw UTF-8 bytes. |
| `json_schema_too_deep` | 400 | pre-inference request validation | false | Schema nesting exceeds 32 levels. |
| `request_content_encoding_unsupported` | 415 | gateway + coordinator pre-validation | false | v0.1.0 rejects compressed request bodies. |
| `malformed_json_response` | 502 | post-inference output validation | true* | Output not valid JSON text, duplicate keys, empty content, or invalid `json_object` root. |
| `json_schema_validation_failed` | 502 | post-inference output validation | true | Parsed JSON does not satisfy schema or output depth. |
| `response_byte_cap_exceeded` | 502 | post-inference raw output cap | true | Existing SPEC-018 code; parsing and validation do not run. |

* Empty-content subcase override: `malformed_json_response` caused by `""` after
  stop-token filtering is `retryable:false` with an actionable buyer-side fix
  message; non-empty malformed JSON remains `retryable:true`.

**v0.2 error-code amendment**: `streaming_json_schema_unsupported` and
`streaming_json_object_unsupported` are deleted from the active buyer-visible
SPEC-019 v0.2 error table. They remain documented only as v0.1.x migration
history. `malformed_json_response` and `json_schema_validation_failed` are valid
HTTP and terminal-SSE error-envelope codes in v0.2. The coordinator retryability
table currently marks the two streaming reject codes false and the two
post-inference structured-output codes retryable
(`phase4-coordinator/internal/buyer/server.go:59-73`); v0.2 removes the former
from active request validation while preserving the latter. v0.2.3 streaming
idle and wall-clock timeout breaches reuse existing `provider_timeout`; SPEC-006
§17.5 / `specs/SPEC-006-buyer-api.md:2605` is cited only as the
`provider_timeout` definition. SPEC-019 v0.2 defines the gateway-owned
wall-clock timeout semantics and adds no SPEC-019-owned timeout error code.

Minimum terminal error envelope:

```json
{
  "error": {
    "type": "upstream_provider_error",
    "code": "json_schema_validation_failed",
    "message": "Structured output did not match response_format.json_schema.schema at /path/to/field",
    "param": "/path/to/field",
    "retryable": true,
    "request_id": "<request id>",
    "inference_ran": true,
    "settlement_ran": true
  }
}
```

## 6. Caps

`json_schema_max_bytes = 16_384`.

The cap applies to `response_format.json_schema.schema`, counted as raw UTF-8
bytes over the schema JSON value as it appears in the request body, including
insignificant whitespace inside that value. Provider and coordinator MUST share
a helper or byte-for-byte equivalent tests. The cap comparison is inclusive:
`<= 16_384` succeeds.

**`json_schema_max_depth = 32`**. Schemas exceeding 32 nested levels at parse
time return HTTP 400 `json_schema_too_deep` at both provider and coordinator
before inference. Depth is counted at every level (`properties[*]`, `items`,
nested `items`/`properties`). Same constant as the output-validation depth cap
in AC-13, by design.

Both `json_schema_max_depth` (schema-side, §6) and AC-13 (output-instance side)
use the same constant 32 by design — a schema at depth 32 can match an instance
at depth 32.

**Depth counting algorithm**: the count is the maximum nesting of the schema
JSON tree itself, NOT instance-implied depth. Algorithm: at the root schema
object, depth = 1; each nested `properties[*]` subtree, `items` subtree,
`additionalProperties` subtree, or schema-typed value inside `oneOf`/`anyOf`
(note: those keywords are rejected per §3, but the counter rule still applies
if support is added later) increments the count by 1. Sibling schemas at the
same level do not increase depth. Provider and coordinator MUST use this
identical algorithm. Example: `{"type":"object","properties":{"a":{"type":
"object","properties":{"b":{"type":"string"}}}}}` is depth 3 (root →
properties.a → properties.a.properties.b).

Mixed-keyword example: `{"type":"array","items":{"type":"array",
"items":{"type":"object","properties":{"id":{"type":"string"}}}}}` is depth 4
— root array (depth 1) → items array (depth 2) → items object (depth 3) →
properties.id string (depth 4). Both `items` subtree and `properties[*]`
subtree increment the counter by 1, regardless of which keyword is used at each
level. Provider and coordinator MUST compute the same value.

SPEC-019 inherits the SPEC-018 §9 / §10d.7 response-size posture
(`specs/SPEC-018-agentic-tool-calling.md:963-975`, cap values and fail-closed
requirements). **Response cap order**: the SPEC-018 v0.2.4 §9
`2_097_152`-byte response cap is enforced on the raw UTF-8 bytes emitted by
inference, before JSON parsing or schema validation runs. Exceeding the cap
returns HTTP 502 `response_byte_cap_exceeded` (existing SPEC-018 code),
`inference_ran:true`, `settlement_ran:true`, `FaultBreakerQualifying`.
Structured-output parsing and validation never run on over-cap output; this
mirrors SPEC-018 §10d.7 fail-closed posture.

Decoded output JSON depth is capped at `32`, matching SPEC-018's public depth
constant (`phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-6`,
public depth constant).

v0.2 does not change SPEC-019 schema-size or schema-depth caps. For streaming
structured output, SPEC-019 v0.2 defines a concatenated-`content` cap of
`2_097_152` bytes. The byte domain is the post-stop-token-filter,
buyer-visible SSE `content` delta concatenation, counted as UTF-8 bytes with an
inclusive boundary. The value intentionally matches the SPEC-018 v0.2.4
response cap value, but this is a SPEC-019-defined cap for assistant `content`,
not a reuse of SPEC-018's `tool_calls[].function.arguments` cap. If the cap is
exceeded, the provider MUST close upstream generation and emit a terminal SSE
error frame using the existing `response_byte_cap_exceeded` code with
`inference_ran:true`, `settlement_ran:true`, no success receipt, and
`FaultBreakerQualifying`. Structured-output parsing and validation do not run on
over-cap output.

## 7. Coordinator / gateway behavior

Coordinator request validation currently accepts `response_format.type` only if
empty, `text`, or `json_object`
(`phase4-coordinator/internal/buyer/server.go:3608-3615`, current allow-list).
SPEC-019 v0.1.0 extends the allow-list to `json_schema` and adds
defense-in-depth validation for:

- `json_schema.name` present, string, escaped, length-bounded, and valid per §3;
- `json_schema.schema` present and object;
- schema UTF-8 byte length `<= 16_384`;
- schema depth `<= 32`;
- rejected keywords;
- strict object `additionalProperties:false`;
- strict object `required` contains every `properties` key;
- `const` / `enum` type conformance;
- `stream:true` unsupported errors from §1.

**v0.2 coordinator amendment**: the final bullet above is v0.1.x-only. For
v0.2, coordinator request validation MUST NOT reject `stream:true` solely
because `response_format` is `json_schema` or `json_object`; the current
coordinator reject branches at
`phase4-coordinator/internal/buyer/server.go:3676-3687` are removed for v0.2.
Coordinator validation still enforces the §3 schema subset before dispatch.
End-of-stream structured-output validation then runs with the same semantics as
the non-streaming path.

After validation, coordinator dispatch remains pass-through. It MUST preserve
the buyer's `response_format` field through provider dispatch.

Gateway behavior remains pass-through. The gateway currently reads the inbound
body, parses only the minimal `chatRequest` fields for quota and stream routing,
then creates the upstream coordinator request from the original `body`
(`phase5-gateway/internal/router/chat_proxy.go:102-117`, inbound body read;
`phase5-gateway/internal/router/chat_proxy.go:217`, upstream request build from
`bytes.NewReader(body)`). SPEC-019 adds no gateway schema parser and no new
endpoint.

**Inbound `Content-Encoding` posture (v0.1.0)**: the gateway and
coordinator MUST reject any request with a `Content-Encoding` header
whose normalized field value is not exactly `identity` (RFC 9110
§8.4.1.1 explicit no-op encoding). `Content-Encoding: identity` and
omitted `Content-Encoding` are accepted. All other values (`gzip`,
`deflate`, `br`, or any compressed encoding) return HTTP 415
`request_content_encoding_unsupported` with an actionable message
("v0.1.0 accepts `Content-Encoding: identity` or no `Content-Encoding`
header; compressed request bodies are deferred to v0.2 per §10.").
This sidesteps three problems with transparent decompression in v0.1.0:
(a) current gateway `parseChatRequest` reads `r.Body` directly without
`gzip.NewReader` (cite `phase5-gateway/internal/router/chat_proxy.go:102-117`);
(b) decompressed-byte caps would need a second tier of
limits; (c) gateway, coordinator, and provider would need identical
decompression semantics to preserve the `json_schema.schema` byte cap
and JCS canonicalization invariants. v0.1.0 keeps a single byte-domain
(uncompressed request body) for all three components. No SPEC-006 or
SPEC-001 amendment is required: SPEC-006 §1650-1657 already covers
request-body size limits and 413; this adds 415 for a separate
content-coding gate.

**Settlement double-attribution prevention**: for the gateway-passed-through
detail codes `malformed_json_response` and `json_schema_validation_failed`, the
gateway MUST NOT invoke `settleBeforeResponse`
(`phase5-gateway/internal/router/chat_proxy.go` — grep for current line) on
these specific codes. These are downstream `FaultBreakerQualifying` outcomes
already settled by the coordinator; a second gateway-side settle would
double-debit the buyer.

**Gateway pass-through allow-list amendment**: SPEC-019 v0.1.0 amends SPEC-006's
provider-5xx normalization (`specs/SPEC-006-buyer-api.md:2556`, gateway 502
normalization to `api_error` / `upstream_provider_error`) to add
`malformed_json_response` and `json_schema_validation_failed` to the
gateway-pass-through detail-code allow-list. Other 502 codes from the provider
continue to normalize to `api_error` / `upstream_provider_error` per SPEC-006.
The current gateway normalization paths are
`phase5-gateway/internal/router/chat_proxy.go:317-327`, non-OK coordinator
response normalization, `phase5-gateway/internal/router/chat_proxy.go:593-599`,
receipt-eligible provider error pass-through helper, and
`phase5-gateway/internal/router/chat_proxy.go:601-607`,
`isNullUsageProviderError` predicate.

**v0.2 streaming pass-through allow-list amendment**: SPEC-006 gateway
normalization MUST also pass through terminal SSE error frames whose
`error.code` is one of:

- `malformed_json_response` (coordinator/provider-emitted)
- `json_schema_validation_failed` (coordinator/provider-emitted)
- `response_byte_cap_exceeded` (coordinator/provider-emitted; pass-through, no gateway `usage_events` row written — refund-only)
- `provider_timeout` (TWO emission paths: provider/coordinator-emitted pass-through with no gateway row, AND gateway-owned wall-clock timeout written by `writeStructuredOutputTimeoutSSE` with `usage_events.outcome=provider_timeout`)

The gateway MUST NOT remap these terminal SSE
error frames to `api_error`, `stream_malformed`, generic
`upstream_provider_error`, or any other code, and MUST NOT drop the structured
`retryable`, `request_id`, `inference_ran`, or `settlement_ran` fields required
by SPEC-018 v0.2.4 §10d.0. The gateway MUST recognize these terminal SSE error
frames as final structured-output failures, forward them verbatim through
`[DONE]`, and skip gateway-side positive / ok settlement. The affected gateway
normalization site is the full `forwardLine` closure at
`phase5-gateway/internal/router/chat_proxy.go:482-557`; the positive-settlement
site that MUST be skipped after forwarding these terminal SSE error frames is
`phase5-gateway/internal/router/chat_proxy.go:625-629`.

These v0.2 terminal SSE error frames inherit the SHAPE and POSITION clauses
of SPEC-006 §17.7.1 (#232): the envelope MUST be a standalone data frame
(no `choices`, no `usage` tokens), MUST be the LAST data frame before
`[DONE]` or EOF, MUST NOT be followed by additional content frames, and
MUST be on a line starting at column 0 with no leading whitespace per the
SSE spec.

The code-vs-outcome MAPPING clause of §17.7.1 applies ONLY when the gateway
itself writes a non-`"ok"` `usage_events` row at the same time the envelope
is emitted. Forwarded v0.2 structured-output terminal frames where the
gateway PASSES THROUGH the provider's envelope and SKIPS positive/ok
settlement (no gateway `usage_events` row) do not trigger the mapping
check — there is no settlement row to match against. All four v0.2
terminal codes — `malformed_json_response`, `json_schema_validation_failed`,
`response_byte_cap_exceeded`, and the provider/coordinator pass-through
variant of `provider_timeout` — are valid `error.code` values for the
shape/position contract regardless. When SPEC-019 paths DO settle a non-ok
gateway `usage_events` row (e.g. the gateway-owned wall-clock
`provider_timeout` written by `writeStructuredOutputTimeoutSSE`), the
mapping is `error.code = usage_events.outcome` by default, with any
divergence added to the §17.7.1 mapping-exception list.

Provider-to-coordinator WS streaming terminal validation failure MUST close the
WS stream with `inference_response_end.status` in `{malformed_json_response,
json_schema_validation_failed}`, preserve retryability, and omit a receipt. This
requirement leverages the existing WS end-status allow-list precedent at
`phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:529`.

Coordinator terminal v0.2 SSE error frames for SPEC-019 streaming validation
failure MUST populate `request_id` and `settlement_ran:true`. The writer site
requiring SPEC-019-specific handling is
`phase4-coordinator/internal/buyer/server.go:5150-5170`. The coordinator
already recognizes those two codes as SPEC-019 provider detail codes
(`phase4-coordinator/internal/buyer/server.go:4944-4955`) and has an
OpenAI-style SSE error writer with the required minimum fields for terminal
streaming errors
(`phase4-coordinator/internal/buyer/server.go:5150-5170`).

Streaming auto-downgrade reuses SPEC-018 v0.2.4 §10d.4 per-(buyer, provider)
attribution and recovery: malformed streams from one buyer to one provider MUST
NOT downgrade that provider for all buyers
(`specs/SPEC-018-agentic-tool-calling.md:834-840`). SPEC-019 v0.2 does not add
a new public streaming negotiation surface.

## 8. Money path

Post-inference structured-output failures are provider-output failures, not
buyer request-validation failures. `malformed_json_response` and
`json_schema_validation_failed` MUST be `FaultBreakerQualifying` and MUST settle
zero provider-positive credits.

The coordinator billing path already accepts a fault flag and only fills
`FaultNone` when the flag is empty
(`phase4-coordinator/internal/buyer/billing_recorder.go:192-194`). The billing
formula returns immediately when `row.FaultFlag == FaultBreakerQualifying`
(`phase4-coordinator/internal/billing/formula.go:112-114`), before positive
credit calculation. SPEC-019 uses those existing paths.

Pre-inference request-validation failures such as `json_schema_missing_name`,
`json_schema_missing_schema`, `json_schema_unsupported_keyword`,
`json_schema_too_large`, `json_schema_too_deep`,
`json_schema_invalid_const_or_enum_type`, `json_schema_invalid_name`,
`json_schema_non_strict_unsupported`, and `streaming_json_schema_unsupported` do
not run inference and do not create provider-positive settlement.

**v0.2 streaming money-path amendment**: streaming structured-output validation
failure is a provider-output failure after inference has run. It MUST be
recorded as `FaultBreakerQualifying` and settle zero provider-positive credits,
the same posture as v0.1 non-streaming `malformed_json_response` and
`json_schema_validation_failed`. The billing recorder preserves an explicit
fault flag and only normalizes an empty flag to `FaultNone`
(`phase4-coordinator/internal/buyer/billing_recorder.go:192-208`), and the
billing formula returns before positive-credit calculation for
`FaultBreakerQualifying`
(`phase4-coordinator/internal/billing/formula.go:112-114`). For v0.2,
`streaming_json_schema_unsupported` and `streaming_json_object_unsupported` are
not pre-inference failure modes because structured streaming is accepted.
Provider-to-coordinator WS terminal validation failure MUST carry
`inference_response_end.status` in `{malformed_json_response,
json_schema_validation_failed}`, preserve retryability, and omit a receipt. The
coordinator terminal SSE writer MUST include `request_id` and
`settlement_ran:true`. The gateway MUST treat terminal SSE error frames with
`error.code` in `{malformed_json_response, json_schema_validation_failed}` as
final structured-output failures, forward them verbatim through `[DONE]`, and
skip gateway-side positive / ok settlement; it MUST NOT remap them to
`stream_malformed` or any other code. In particular, the gateway-side
`settleReported("ok")` / `settleAfterCommit(..., "ok", ...)` positive-settle
site at `phase5-gateway/internal/router/chat_proxy.go:625-629` MUST be skipped
after forwarding a terminal SSE error frame with `error.code` in
`{malformed_json_response, json_schema_validation_failed}`. Streaming idle
timeout, wall-clock timeout, and
SPEC-019 streaming content-cap failure also settle `FaultBreakerQualifying`.

## 9. Forward-compatibility invariants

The schema subset MAY widen across v0.1.x. It MUST NOT narrow for requests that
were valid under v0.1.0.

Error codes MAY add new values. Existing v0.1.0 error codes MUST NOT be renamed
or repurposed after v0.1.1. The v0.1.1 rename from
`streaming_json_schema_unsupported`, `streaming_json_object_unsupported`, and
`json_schema_non_strict_unsupported` removes version suffixes before lock; future
version context belongs in `error.message`, not `error.code`.

Caps MAY raise. Caps MUST NOT lower for default behavior without a major version
bump or explicit buyer opt-in defined by a later SPEC.

The `json_schema` request shape MAY add optional fields inside
`response_format.json_schema.*`. Future versions MUST NOT require new fields
without a major version bump.

`strict:true` semantics in v0.1.0 are the conformant baseline. `strict:false`
semantics, if added later, MUST be additive and MUST NOT weaken the validation
performed for `strict:true`.

The receipt canonical prompt object MUST continue to bind `response_format`.
Future receipt work MAY add observability fields, but MUST NOT remove
`response_format` from the prompt hash input without a SPEC-015 major-version
change (`specs/SPEC-015-receipts.md:1191-1204`, canonical prompt object fields).

**Receipt canonical scope for `response_format`**: the receipt prompt hash is
computed over the raw `response_format` JSON value as received in the request
body. Defaulted-but-absent fields, notably `strict` defaulting to `true`, are NOT
folded into the hash. Buyers seeking byte-stable receipts MUST send defaulted
fields explicitly. This is the JCS-canonicalization contract of
`phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:5-16` applied
to v0.1.0; a future version MAY fold defaults in but MUST announce the
migration.

**v0.2 streaming validation invariant**: v0.2 MAY use end-of-stream validation
for `stream:true` structured output. Future versions MAY promote streaming
validation to incremental partial-JSON-prefix tolerant validation, but MUST NOT
regress below v0.2's end-of-stream validation guarantee for accepted
`stream:true` + `response_format` requests.

**v0.2 schema-keyword monotonicity**: acceptance of `minimum`, `maximum`,
`multipleOf`, and top-level `$schema` is monotonic. Future v0.2.x versions MAY
widen the accepted-keyword set but MUST NOT remove those four accepted keywords
from default behavior.

**v0.2 receipt invariant**: no SPEC-015 schema change is required for streaming
structured output. `response_format` remains bound into the prompt hash through
the existing JCS canonical prompt object
(`phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:5-16`).
Top-level `$schema` bytes count toward `json_schema_max_bytes = 16_384` and are
JCS-canonicalized into the receipt `prompt_hash` per §9. '`$schema` is ignored'
refers only to validation-time meta-schema selection -- `$schema` bytes are NOT
excluded from cap accounting or receipt prompt-hash binding.

## 10. Deferred to v0.2 / v0.3

Deferred after v0.2.3:

- v0.2.x or v0.3: transparent gateway-side decompression of
  `Content-Encoding: gzip` / `deflate` / `br` request bodies with a
  decompressed-byte cap. v0.2.0 keeps the single uncompressed byte-domain
  invariant for caps and JCS and continues returning HTTP 415
  `request_content_encoding_unsupported` for compressed request bodies.
- v0.2.x or v0.3: schema warm-cache between requests on the same connection.
- v0.2.x or v0.3: wider schema subset beyond numeric bounds and top-level
  `$schema`.
- v0.2.x or v0.3: partial-JSON-prefix tolerant streaming validation. v0.2.0
  ships end-of-stream validation over the concatenated content buffer.
- v0.2.x: concrete provider idle inactivity duration N for structured-output
  streaming timeout. v0.2.3 defines the provider-owned idle watcher, the
  gateway-owned SPEC-019 wall-clock watcher with 300s counted from
  gateway-side first-byte-of-request, terminal `provider_timeout` behavior, and
  the no-double-fire rule, but intentionally defers the idle numeric value.

Deferred to v0.3 or later:

- v0.3 or later: `oneOf` / `anyOf` polymorphism.
- v0.3 or later: `$ref` / `$defs` schema reuse.
- v0.3 or later: nested Pydantic fixtures. AC-30 uses a flat Pydantic model
  because nested Pydantic models emit `$defs` / `$ref`, which §3 rejects per
  the v0.1.0 reject-list; fixtures with nested classes are deferred to v0.3
  when `$ref` / `$defs` schema reuse is in scope.
- v0.3 or later: non-strict mode (`strict:false`) as observability without
  enforcement.
- v0.3 or later: auto-retry with tightened prompt on validation failure.
- v0.3 or later: model-hash-bound structured-output family renderer registry.

A buyer-facing migration note in the public release notes is a v0.1.0 release
acceptance criterion.

**v0.1.0 is NOT a Cline drop-in structured-output release.** Cline source as of
`92806c60` does not send `response_format` / `json_schema` / `generateObject` /
`streamObject` on its active streaming code path. Cline structured-output
enablement is a v0.2 streaming-validation deliverable. v0.1.0 unlocks
structured output for non-streaming SDK consumers (openai-python, Vercel AI SDK
non-stream).

**v0.2.0 amendment**: Cline structured-output enablement on the active
streaming path, streaming structured output, and §3 numeric-bound plus
top-level `$schema` acceptance are no longer deferred. They are the v0.2.0
deliverables. Partial-JSON-prefix tolerant validation remains deferred.

**v0.2.1 amendment**: r1 absorption tightens the v0.2 deliverables without
adding a new endpoint, SPEC-015 schema change, or SPEC-018 edit. It defines the
three-layer streaming validation bridge, provider-idle timeout authority,
numeric-bound operand rules, SPEC-019-owned streaming `content` cap, Cline and
Vercel captured-body fixture requirements, and the `$schema` cap/hash
clarification. The concrete idle duration N remains deferred to v0.2.x.

**v0.2.2 amendment**: r2 absorption substitutes SPEC-006 `provider_timeout` for
the prior timeout-code placeholder, adds wall-clock total deadline closure using
the existing SPEC-006 per-request deadline, widens gateway pass-through and
positive-settlement citations, requires both Cline and Vercel partial-content
negative streaming fixtures, and adds RFC 8259 §6 NaN / Infinity numeric-bound
reject coverage. It does not add a SPEC-015 schema change, SPEC-018 edit, new
HTTP endpoint, or new error code.

**v0.2.3 amendment**: r3 absorption retracts the r2 "reuse existing SPEC-006
per-request deadline" wall-clock framing because SPEC-006 has no normative prose
for `coordinator_request_seconds`. SPEC-019 v0.2.3 defines its own
gateway-owned wall-clock watcher, counted from gateway-side
first-byte-of-request with a 300s value that matches `coordinator_request_seconds`
by convention, and requires terminal SSE `provider_timeout`,
`FaultBreakerQualifying`, zero provider-positive credits, and no gateway
ok/positive settlement on breach. It also corrects the streaming
`provider_timeout` citation to `phase4-coordinator/internal/buyer/server.go:2386`
and the SPEC-006 definition cite to §17.5 /
`specs/SPEC-006-buyer-api.md:2605`; and it corrects AC-V2-10b so NaN /
Infinity request-body tokens assert HTTP 400 `invalid_json`, while non-numeric
operand types continue to assert HTTP 400 `json_schema_unsupported_keyword`.
Traceability: `specs/SPEC-019-v0_2-r3-audit.md`.

Historical v0.1.5 deferred text retained for audit traceability, superseded by
the v0.2.0 active deferred list above:

- v0.2: streaming structured output with partial-JSON-prefix validation per
  chunk.
- v0.2: Cline structured-output enablement on the active streaming path.
- v0.2: Vercel AI SDK and OpenAI SDK matrix expansion beyond the v0.1.0 anchor
  fixtures.
- v0.2: wider schema subset after Cline and Vercel AI SDK compatibility
  evidence.
- v0.2: schema warm-cache between requests on the same connection.
- v0.2: transparent gateway-side decompression of `Content-Encoding: gzip` /
  `deflate` / `br` request bodies with a decompressed-byte cap. v0.1.0 keeps
  the single uncompressed byte-domain invariant for caps and JCS. v0.1.0
  returns HTTP 415 `request_content_encoding_unsupported` for compressed bodies
  until v0.2 decompression semantics land.
- v0.2: §3 numeric-bound keywords (`minimum`, `maximum`, `multipleOf`) and
  `$schema` top-level acceptance to enable direct round-trip with Vercel AI
  SDK's full Zod expressivity without an SDK-side normalization step.

## 11. Open questions / audit hooks

Audit lanes should probe:

1. JSON canonicalization edge cases: duplicate keys, NaN, Infinity,
   `-Infinity`, negative zero, lone surrogates in strings, unpaired escapes,
   deeply nested arrays, and UTF-8 byte counting for multibyte property names.
2. Prompt-injection risk from attacker-controlled schema descriptions, schema
   names, enum strings, const strings, property names, and tool-call sentinel
   strings inside schema text.
3. Whether the `json_object` top-level object-or-array rule is sufficient for
   OpenAI compatibility or should narrow to object-only before lock.
4. Whether `strict:false` should be rejected as specified or accepted as a
   synonym for `strict:true`; v0.1.0 currently rejects to avoid silent semantic
   drift.
5. Whether scalar root schemas should remain allowed in v0.1.0 or be deferred
   until SDK compatibility evidence exists.
6. Model-quality regression: structured-output system prompt injection MUST NOT
   affect requests without `response_format` and SHOULD be measured for
   structured requests against non-structured fixture quality.
7. Tools plus `json_schema`: audit that schema validation never applies to
   tool-call arguments and that non-tool responses still validate.
8. Money path: verify every post-inference parse/validation failure reaches
   `FaultBreakerQualifying`, zero provider-positive credits, no sticky-route
   success write, and no success receipt.
9. Coordinator/provider parity: schema-size cap, schema-depth cap, keyword
   rejection, strict object rules, stream unsupported errors, and error codes
   must be identical.
10. SDK ergonomics: `openai==2.44.0` Pydantic parsing and
    `@ai-sdk/openai-compatible@2.0.38` Zod parsing should fail only on real
    schema violations, not on envelope or content-shape drift.

v0.2 audit lanes should additionally probe:

11. Whether end-of-stream validation creates an unacceptable buyer DoS posture
    when a provider emits up to the 2 MiB response cap of unvalidated tokens and
    then fails validation. The counter-argument is parity with v0.1
    non-streaming post-hoc validation: inference ran, buyer receives an error,
    and settlement is `FaultBreakerQualifying`.
12. Whether the terminal SSE error-frame shape should exactly reuse SPEC-018
    v0.2.4 §10d.4 or whether SPEC-019 needs a dedicated structured-output
    streaming shape before lock.
13. Whether `Content-Type: text/event-stream; charset=utf-8` and chunked
    transfer encoding are preserved through the gateway/coordinator path on
    structured-output terminal-error streams. The provider SSE headers are
    currently `content-type`, `cache-control`, `connection`, and
    `transfer-encoding: chunked`
    (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1169-1178`).
14. Whether `[DONE]` remains the right transport close marker for both success
    and failure paths when the failure is semantically terminal-error rather
    than successful completion.
15. Whether the SPEC-019 v0.2.3 wall-clock value of 300s, counted from
    gateway-side first-byte-of-request and matched to `coordinator_request_seconds`
    by convention, is fit-for-purpose for structured streaming or should be
    changed in a future v0.2.x.
16. v0.1.5 LOCKED retryable drift for `response_byte_cap_exceeded`: §5
    error-code table marks `retryable: true`, but IMPL
    `phase4-coordinator/internal/buyer/server.go:56` marks `false`. This is
    pre-existing v0.1.5 LOCKED drift and out of v0.2 amendment scope. AC-V2-9b
    does not explicitly bind retryable and inherits IMPL semantics. Reconcile
    in v0.3.

## 12. Document metadata

**Version:** 0.2.4 (2026-06-29, LOCKED)

**Status:** LOCKED — r4 defensive audit returned 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6 lanes.

Audit trajectory:
- r1: 1C + 9H + 9M → absorbed in v0.2.1.
- r2: 1C + 3H + 5M → absorbed in v0.2.2.
- r3: 0C + 3H + 3M → absorbed in v0.2.3 (wall-clock authority rewrite + NaN/Infinity envelope split).
- r4 defensive: 0C + 0H + 0M across all 6 lanes. LOCK satisfied.

Precondition: SPEC-018 v0.2.4 LOCKED at `7e50832` via PR #202, with
implementation shipped at `c77313a` via PR #209
(`specs/design/spec-018/SPEC-018-v0_2-IMPL-NOTES.md:7-10`, release note and implementation
commit anchors).

Successor: SPEC-019 v0.2 IMPL — same playbook as v0.1.5 IMPL (PR #225).
Streaming structured output, gateway-owned wall-clock authority, numeric
bounds + $schema, Cline + Vercel AI SDK + openai-python streaming
fixtures.

Drafting scope: no implementation code, no SPEC-018 edits, no SPEC-015 schema
change, no new HTTP endpoint.

### Change log

- **v0.2.4 (2026-06-29, LOCKED):** r4 defensive audit returned **READY TO
  LOCK** from all 6 lanes (architect, code, security, product-design codex
  + critic, narrative Claude blind-spot) at 0 CRITICAL + 0 HIGH + 0 MEDIUM
  against v0.2.3 anchor `568e110`. Each lane independently verified the r3
  wall-clock authority rewrite landed cleanly: SPEC-006 §17.5 / `:2605`
  cite resolves; `server.go:2386` is the streaming SSE site; gateway-owned
  wall-clock + provider-owned idle authorities are consistent across
  AC-V2-9 / §5 / §7 / §8; no MUST-verb subject ambiguity; no new phantom
  citations. Grep guards (`§3221`, `:3221`, `server.go:1722`,
  `inference_timeout`) all = 0 hits. No SPEC text changes between v0.2.3
  and v0.2.4 LOCKED — only the version header, §12 metadata, and this
  change-log entry move. Audit trajectory: r1 (1C+9H+9M) → r2 (1C+3H+5M)
  → r3 (0C+3H+3M) → r4 (0/0/0). Lock narrative:
  `specs/SPEC-019-v0_2-r4-audit.md`. Successor: SPEC-019 v0.2 IMPL.

- **v0.2.3 (2026-06-29, r3-absorption draft for audit):** Absorbs the r3 audit
  findings from `specs/SPEC-019-v0_2-r3-audit.md` (0C + 3H + 3M across 3
  lanes; lanes A, B, and F READY TO LOCK) while keeping v0.1.5 locked text
  immutable. The wall-clock authority rewrite retracts the r2 "reuse existing
  SPEC-006 per-request deadline" framing because SPEC-006 has no normative prose
  for `coordinator_request_seconds`; SPEC-019 v0.2.3 instead defines a
  gateway-owned 300s wall-clock watcher counted from gateway-side
  first-byte-of-request, with terminal SSE `provider_timeout`,
  `FaultBreakerQualifying`, zero provider-positive credits, skip of the
  gateway-side ok / positive settlement path, and no double-fire with the
  provider-owned idle watcher. The NaN / Infinity correction makes
  request-body literals `NaN`, `Infinity`, `+Infinity`, and `-Infinity` assert
  HTTP 400 `invalid_json`, while non-numeric numeric-bound operand types remain
  HTTP 400 `json_schema_unsupported_keyword`. No SPEC-015 schema change, no
  SPEC-018 edits, no SPEC-006 edits, no new HTTP endpoint, and no new error
  codes.

- **v0.2.2 (2026-06-29, r2-absorption draft for audit):** Absorbs the r2 audit
  findings from `specs/SPEC-019-v0_2-r2-audit.md` (1C + 3H + 5M across 4 lanes;
  lanes A and F READY TO LOCK) while keeping v0.1.5 locked text immutable.
  T-r2-1 replaces the prior timeout-code placeholder with SPEC-006
  `provider_timeout` and records no new error code; T-r2-2 widens gateway
  streaming pass-through citations, names the positive-settlement site, and
  adds the no-`outcome:"ok"` / no-`stream_malformed` IMPL test obligation;
  T-r2-3 makes the partial-content negative fixture set conjunctive across
  Cline and Vercel. S-r2-1 adds the wall-clock total deadline paired with idle
  timeout; S-r2-2 records the locked `response_byte_cap_exceeded` retryability
  drift as a §11 deferral only; S-r2-3 adds RFC 8259 §6 NaN / Infinity
  rejection coverage for numeric-bound operands. No SPEC-015 schema change, no
  SPEC-018 edits, no new HTTP endpoint, and no new error codes.

- **v0.2.1 (2026-06-29, r1-absorption draft for audit):** Absorbs the r1 audit
  findings from `specs/SPEC-019-v0_2-r1-audit.md` (1C + 9H + 9M across 5 lanes;
  lane F READY TO LOCK) while keeping v0.1.5 locked text immutable. Convergent
  themes closed: T-1 specifies the provider WS -> coordinator SSE -> gateway SSE
  pass-through and settlement bridge for terminal streaming validation failures;
  T-2 binds streaming timeout authority to provider-side idle inactivity and
  reuses `provider_timeout`; T-3 adds numeric-bound operand validity and
  inverted-bound rejects using `json_schema_unsupported_keyword`; T-4 adds
  numeric-bound type-conditional negative fixtures. Singular findings closed:
  S-1 defines the SPEC-019 streaming concatenated-`content` cap at `2_097_152`
  bytes; S-2 annotates deleted v0.1.x streaming reject codes in the error table;
  S-3 requires Cline commit/version pinning plus captured outbound POST bytes;
  S-4 adds the partial-content-then-terminal-error negative fixture; S-5 requires
  captured Vercel/Zod `z.number().int()` request bytes; S-6 clarifies `$schema`
  cap accounting and receipt `prompt_hash` binding; S-7 adds the streaming
  composite-render invariant as AC-V2-14. No SPEC-015 schema change, no SPEC-018
  edits, and no new HTTP endpoint.

- **v0.2.0 (2026-06-29, draft for audit):** v0.2 amendment on top of
  locked v0.1.5 for the narrow Cline drop-in structured-output build.
  Resolved design calls are normative: streaming validation is
  end-of-stream validation over concatenated `content` deltas, not
  partial-JSON-prefix validation; Cline is the anchor framework through
  `@ai-sdk/openai-compatible@2.0.38` with
  `supportsStructuredOutputs:true`; numeric bounds plus top-level
  `$schema` are the only schema-subset widening; and
  `streaming_json_schema_unsupported` /
  `streaming_json_object_unsupported` are deleted from the active v0.2
  buyer-visible error table. Four narrow deliverables: (1)
  `stream:true` + `json_schema` / `json_object` accepted with normal
  SSE deltas and terminal validation; (2) terminal streaming
  validation failures reuse SPEC-018 v0.2.4 §10d.4 error frames and
  settle `FaultBreakerQualifying`; (3) §3 accepts `minimum`,
  `maximum`, `multipleOf`, and top-level `$schema` while leaving
  polymorphism / `$ref` / `$defs` deferred; (4) SDK fixtures expand to
  live Cline/Vercel streaming plus openai-python streaming, including
  the former v0.1 AC-31 `z.number().int()` / `$schema` gap. No
  SPEC-015 schema change; `PromptCanonicalizer.swift:5-16` already
  binds `response_format` into the prompt hash. No SPEC-018 edits.

- **v0.1.5 (2026-06-28, round-5 final polish):** Absorbed the single
  r5 MEDIUM. AC-28a fixture wording rewritten to match the §7
  `Content-Encoding: identity` carve-out from r4 (architect M-1).
  AC-28a now defines a single coherent fixture: reject when
  normalized value is not exactly `identity`; accept omitted header
  and `identity` (case-insensitive, whitespace-tolerant). Adversarial
  fixture rows added for case-variants, whitespace surrounds, and
  multi-value `identity, gzip` rejection. 5 of 6 r5 lanes returned
  READY TO LOCK; only the architect lane found this fixture
  inconsistency. Round narrative: `specs/SPEC-019-v0_1-r5-audit.md`;
  per-lane findings: `specs/SPEC-019-v0_1-{architect,code,security,
  product-design,critic,narrative}-r5-audit.md`. Re-fire architect-
  only lane to confirm 0/0/0 closure before lock.

- **v0.1.4 (2026-06-28, round-4 polish absorption):** Absorbed 2 HIGH +
  3 MEDIUM + 6 minor across 6 audit lanes. Three lanes (security,
  product-design, narrative) returned READY TO LOCK at r4. `Content-
  Encoding: identity` accept/reject contradiction resolved -- §7 now
  rejects only non-`identity` non-empty values (architect + critic
  convergent). AC-30 Pydantic fixture changed from `int` to `float`
  so both Pydantic and Vercel Zod fixtures emit
  `{"type":"number"}` (code). AC-31 citation fix: rejected-keyword
  list AC reference corrected; §3 explicitly includes `$schema` in
  reject list (critic). §10 nested-Pydantic deferral target corrected
  from v0.2 to v0.3 to align with $ref/$defs deferral (critic).
  §10 transparent-decompression bullet names the v0.1.0 error code
  `request_content_encoding_unsupported` for traceability (code minor).
  AC-31 footnote: production Vercel buyers with
  `supportsStructuredOutputs:true` and no normalization receive HTTP
  400 in v0.1.0 (critic minor). §10 bullet-shape normalized (narrative
  minor). Round narrative: `specs/SPEC-019-v0_1-r4-audit.md`; per-lane
  findings: `specs/SPEC-019-v0_1-{architect,code,security,
  product-design,critic,narrative}-r4-audit.md`. Codex security,
  product-design, and Claude narrative lanes = first 3 READY TO LOCK
  at the same round.

- **v0.1.3 (2026-06-28, round-3 defensive absorption):** Absorbed 2
  HIGH + 7 MEDIUM + 4 minor + 1 Q across 6 audit lanes. Gzip posture
  switched from gateway-decompression to HTTP 415 reject in v0.1.0
  (critic + architect + security convergent on r2's gzip block being
  unimplementable against current gateway code) — transparent
  decompression deferred to v0.2. AC-31 Vercel fixture changed to
  v0.1.0-compatible Zod shape (`z.number()` instead of
  `z.number().int()`) + `$schema` strip step documented (PD).
  §5 panic catch-all partial-validator-state discard rule added
  (security). §5 empty-content actionable message replaced
  `max_tokens` with `temperature` / `seed` (critic). §6 dual-axis
  signpost AC citation corrected to AC-13 (narrative). §6 depth-
  counting algorithm gains mixed `items`/`properties` worked example
  (critic). Empty-content `retryable:false` semantics clarified as
  "no SDK auto-retry, buyer-initiated modified retry permitted" (PD).
  Nested-Pydantic v0.1.0 limitation documented in §10 (critic minor).
  Round narrative: `specs/SPEC-019-v0_1-r3-audit.md`; per-lane
  findings: `specs/SPEC-019-v0_1-{architect,code,security,
  product-design,critic,narrative}-r3-audit.md`. Codex code lane was
  the first lane to return READY TO LOCK at any round.

- **v0.1.1 (2026-06-28, round-1 audit absorption):** Absorbed 3 CRITICAL
  + 14 HIGH + 14 MEDIUM findings across 6 audit lanes. Cross-spec
  amendments to SPEC-001 (§1) and SPEC-006 (§7). New strict-mode parity rule
  (§3), const/enum type-conformance rule (§3), NFC/NFD byte-comparison rule
  (§3), and new error codes. Money-path receipt-ordering normative (§5 + §2
  AC-26). Empty-content classification (§5). Defaulted-strict receipt scope
  clarified (§9). Schema-depth cap added (§6), response cap pre-parse order
  fixed (§6), and `json_schema.name` rule added (§3 + §2 AC-33). Composite
  tool×schema render order (§4) and stateless renderer requirement (§4) added.
  Concrete SDK fixtures (§2 AC-30/AC-31). Versioned error-code suffixes dropped
  (§1 + §2 AC-11/AC-22). Quick orientation + AC categories restructured (§0 /
  §2). Round narrative:
  `specs/SPEC-019-v0_1-r1-audit.md`; per-lane findings:
  `specs/SPEC-019-v0_1-{architect,code,security,product-design,critic,
  narrative}-r1-audit.md`.

- **v0.1.2 (2026-06-28, round-2 defensive absorption):** Absorbed 6
  HIGH + 9 MEDIUM + 3 minor findings across 6 audit lanes. Composite
  render order unified to single normative sequence in §4 (architect/
  code/critic convergent). `json_schema.name` rule made
  OpenAI-compatible (`^[A-Za-z0-9_-]{1,64}$`), mandatory, and AC-
  asserted at provider + coordinator (critic/code/PD/security
  convergent). Empty-content `retryable:false` override added in §5
  (PD). Validator panic / fatal-error catch-all normative block added
  in §5 (security). AC-30/AC-31 SDK parity rewritten as paired
  fixture (PD). Schema-depth counting algorithm specified in §6
  (critic). NFC/NFD adversarial fixture added to AC-9 (security).
  gzip body-byte preservation added to §7 (critic / carried-from-r1).
  Gateway double-settlement prevention added to §7 (critic). Stale
  gateway citations fixed in §7 (code). Round narrative:
  `specs/SPEC-019-v0_1-r2-audit.md`; per-lane findings:
  `specs/SPEC-019-v0_1-{architect,code,security,product-design,
  critic,narrative}-r2-audit.md`.

- **v0.1.0 (2026-06-28, first draft for audit):** Initial structured-output
  draft for non-streaming `json_schema` and `json_object` post-hoc enforcement.
