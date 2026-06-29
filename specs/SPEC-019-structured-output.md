# SPEC-019 - Structured output (`response_format: json_schema`)

**Version:** 0.1.5 LOCKED (2026-06-28, round-5b architect re-fire 0/0/0)
**Depends on:** SPEC-001, SPEC-006, SPEC-015, SPEC-018 v0.2.4 LOCKED
**Status:** LOCKED — all 6 audit lanes returned READY TO LOCK.

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
(`specs/SPEC-018-v0_2-IMPL-NOTES.md:7-10`, release note and implementation
commit anchors). SPEC-018 §10b names structured-output response synthesis as the
follow-on surface promoted after streaming-incremental wire contract stability
(`specs/SPEC-018-agentic-tool-calling.md:671-675`, follow-on surface list).

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
(`phase4-coordinator/internal/buyer/billing_recorder.go:181-183`), and the
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

### SPEC-019 error codes

| Code | HTTP | Phase | Retryable | Notes |
|---|---:|---|---|---|
| `json_schema_missing_name` | 400 | pre-inference request validation | false | Missing `response_format.json_schema.name`. |
| `json_schema_missing_schema` | 400 | pre-inference request validation | false | Missing `response_format.json_schema.schema`. |
| `json_schema_non_strict_unsupported` | 400 | pre-inference request validation | false | `strict:false` unsupported in SPEC-019 v0.1.0. |
| `streaming_json_schema_unsupported` | 400 | pre-inference request validation | false | `json_schema` with `stream:true`. |
| `streaming_json_object_unsupported` | 400 | pre-inference request validation | false | `json_object` with `stream:true`. |
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

## 8. Money path

Post-inference structured-output failures are provider-output failures, not
buyer request-validation failures. `malformed_json_response` and
`json_schema_validation_failed` MUST be `FaultBreakerQualifying` and MUST settle
zero provider-positive credits.

The coordinator billing path already accepts a fault flag and only fills
`FaultNone` when the flag is empty
(`phase4-coordinator/internal/buyer/billing_recorder.go:181-183`). The billing
formula returns immediately when `row.FaultFlag == FaultBreakerQualifying`
(`phase4-coordinator/internal/billing/formula.go:112-114`), before positive
credit calculation. SPEC-019 uses those existing paths.

Pre-inference request-validation failures such as `json_schema_missing_name`,
`json_schema_missing_schema`, `json_schema_unsupported_keyword`,
`json_schema_too_large`, `json_schema_too_deep`,
`json_schema_invalid_const_or_enum_type`, `json_schema_invalid_name`,
`json_schema_non_strict_unsupported`, and `streaming_json_schema_unsupported` do
not run inference and do not create provider-positive settlement.

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

## 10. Deferred to v0.2 / v0.3

Deferred to v0.2:

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

## 12. Document metadata

**Version:** 0.1.5 (2026-06-28, round-5 final polish)

**Status:** DRAFT — final defensive lock candidate.

Precondition: SPEC-018 v0.2.4 LOCKED at `7e50832` via PR #202, with
implementation shipped at `c77313a` via PR #209
(`specs/SPEC-018-v0_2-IMPL-NOTES.md:7-10`, release note and implementation
commit anchors).

Successor: TBD. Expected next step is architect-only r5 re-fire for 0/0/0
closure before lock, or v0.2.0 if the audit loop promotes streaming structured
output into scope.

Drafting scope: no implementation code, no SPEC-018 edits, no SPEC-015 schema
change, no new HTTP endpoint.

### Change log

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
