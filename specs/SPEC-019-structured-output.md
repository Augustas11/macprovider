# SPEC-019 - Structured output (`response_format: json_schema`)

**Version:** 0.1.0 (2026-06-28, first draft for audit)
**Depends on:** SPEC-001, SPEC-006, SPEC-015, SPEC-018 v0.2.4 LOCKED
**Status:** DRAFT - audit loop pending.

## Quick orientation

SPEC-019 is the provider-side structured-output contract for OpenAI-wire
`response_format`. It lets a buyer send `response_format:
{"type":"json_schema", ...}` to `/v1/chat/completions` and receive either
assistant `content` that is a JSON string conforming to the supplied schema, or
a structured error envelope.

The v0.1.0 slice is narrow:

- non-streaming only;
- post-hoc parsing and validation after inference, not constrained decoding;
- `json_object` enforcement is bundled because current provider parsing accepts
  it but does not consult it during inference;
- the schema subset is a strict-mode-compatible JSON Schema subset, not full
  JSON Schema.

Current code anchors at `98336d9`: the provider request object stores
`responseFormat` (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:14`),
parses `response_format` before prompt-source capture (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:83`),
preserves the raw prompt-source field (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:144` and
`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:162`), but the enum only allows `text` and `json_object`
(`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:239-241`) and rejects any other type with HTTP
400 (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:371-379`). Runtime inference renders messages
through `ToolPromptRenderer.renderMessages` before MLX preparation in preflight,
non-streaming, and streaming paths (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:400`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:454`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:540`) and only post-processes native tool-call text through
`parseToolCallsIfRequested` (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:483`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:598`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:873-886`). The MLX dependency is pinned to `mlx-swift-examples` 2.29.1
(`phase3-binary/Package.swift:20-23`; `phase3-binary/Package.resolved:22-27`).

Receipt binding needs no SPEC-015 schema change: SPEC-015's canonical prompt
object already includes `response_format` (`specs/SPEC-015-receipts.md:1191-1204`),
and the provider implementation already JCS-canonicalizes it into the prompt
hash (`phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:5-16`).
SPEC-006 already lists `response_format` in the buyer API allow-list
(`specs/SPEC-006-buyer-api.md:1036-1047`).

SPEC-018 v0.2.4 is the precondition. The SPEC body is locked at `7e50832` via
PR #202, and the implementation landed at `c77313a` via PR #209
(`specs/SPEC-018-v0_2-IMPL-NOTES.md:7-10`; `git log --oneline` at drafting
time). SPEC-018 §10b explicitly names structured-output response synthesis as
the follow-on surface promoted after the streaming-incremental wire contract
stabilizes (`specs/SPEC-018-agentic-tool-calling.md:671-675`).

## 1. Buyer-visible contract

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
HTTP 400 `json_schema_non_strict_unsupported_in_v0_1`. `json_schema.schema` is
required and MUST fit the §3 subset.

Buyer-side validation obligation: the provider validates syntax and schema
conformance for the returned assistant `content`; it does not validate whether
the values are semantically safe to execute, store, or trust. Buyers MUST apply
their own business-policy validation to parsed structured output before taking
side effects.

v0.1.0 is non-streaming only. A request with `response_format.type ==
"json_schema"` and `stream:true` MUST fail before inference with HTTP 400
`streaming_json_schema_unsupported_in_v0_1`. `json_object` streaming enforcement
is also out of scope for v0.1.0; `json_object` with `stream:true` MUST fail
before inference with HTTP 400 `streaming_json_object_unsupported_in_v0_1`
rather than silently stream unconstrained text.

Tools interaction: when both `tools` and `response_format.type ==
"json_schema"` are supplied, tool calls take precedence. If the model emits a
valid tool call under SPEC-018, the response is a `tool_calls[]` response and
the SPEC-019 response schema does not apply to `tool_calls[].function.arguments`;
tool-call arguments are governed by the tool's own JSON Schema. If the model
does not emit a tool call, the assistant content MUST satisfy this SPEC.
Current runtime already performs tool parsing only when request tools exist
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:873-886`).

## 2. Acceptance criteria

AC-1. `response_format.type == "json_schema"` is accepted by the provider
request parser and represented in the parsed request. Fail condition: current
HTTP 400 `invalid_request` path remains for `json_schema`
(`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:371-379`).

AC-2. Missing `response_format.json_schema.name` returns HTTP 400
`json_schema_missing_name`, `param:"response_format.json_schema.name"`, and
`inference_ran:false`.

AC-3. Missing `response_format.json_schema.schema` returns HTTP 400
`json_schema_missing_schema`, `param:"response_format.json_schema.schema"`, and
`inference_ran:false`.

AC-4. A schema using any §3 rejected keyword returns HTTP 400
`json_schema_unsupported_keyword`, includes the offending keyword and JSON
pointer in the message or `param`, and does not reach inference.

AC-5. A raw UTF-8 byte length greater than `16_384` for
`response_format.json_schema.schema` returns HTTP 413
`json_schema_too_large` at both provider parser and coordinator boundary.
Exactly `16_384` bytes succeeds if the schema is otherwise valid.

AC-6. `strict:true` with any object schema that lacks
`additionalProperties:false` returns HTTP 400
`json_schema_strict_requires_additional_properties_false`. Nested object
schemas are checked recursively.

AC-7. `response_format: {"type":"json_object"}` constrains the final assistant
content to valid JSON with top-level object or array. Fail condition: the
current silent no-op remains, where the field is parsed but never consulted by
runtime inference (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:83`; `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:477-500`).

AC-8. `response_format: {"type":"json_schema", ...}` produces assistant
`content` that parses as JSON and validates against `json_schema.schema` when
the model output is valid. The visible `message.content` is the JSON string, not
a parsed object.

AC-9. If final inference output is not JSON-parseable while `json_schema` or
`json_object` is requested, the provider returns HTTP 502
`malformed_json_response` with type `upstream_provider_error`,
`retryable:true`, `inference_ran:true`, and `settlement_ran:true`; the
coordinator records `FaultBreakerQualifying` and zero provider-positive
credits.

AC-10. If final inference output parses as JSON but fails schema validation, the
provider returns HTTP 502 `json_schema_validation_failed` with type
`upstream_provider_error`, `retryable:true`, `inference_ran:true`,
`settlement_ran:true`, and the offending RFC 6901 JSON pointer such as
`/path/to/field`; the coordinator records `FaultBreakerQualifying`.

AC-11. `response_format: {"type":"json_schema", ...}` with `stream:true`
returns HTTP 400 `streaming_json_schema_unsupported_in_v0_1`.
`response_format: {"type":"json_object"}` with `stream:true` returns HTTP 400
`streaming_json_object_unsupported_in_v0_1`.

AC-12. Provider receipt regression tests prove `prompt_hash` changes when any
byte of `response_format.json_schema.schema` changes. This is a no-schema-change
regression against SPEC-015's `response_format` canonical prompt field
(`specs/SPEC-015-receipts.md:1191-1204`) and current JCS implementation
(`phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift:5-16`).

AC-13. Family-prompt rendering fixtures for Qwen3 and Llama-3.3 show the schema
instruction is injected into the chat-template system position byte-equivalently
per family. The implementation MUST reuse the modelID-match family mechanism
used by `ToolPromptRenderer` (`phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift:37-51`)
and the existing render hook sites (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:400`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:454`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:540`).

AC-14. Tools plus `json_schema` interaction is deterministic: valid tool-call
output returns `tool_calls[]` and skips response-schema validation of
tool-call arguments; no valid tool-call output requires structured assistant
content validation. Fail condition: schema validation is applied to tool-call
arguments, or a valid tool call is discarded solely because `json_schema` is
present.

AC-15. Forward-compatibility regression with `openai==2.44.0`: sending
`response_format=json_schema(...)` against macprovider produces the same parsed
Pydantic model as the canonical fixture against OpenAI
`gpt-4o-2024-08-06`, modulo model-dependent field values fixed by the fixture
prompt.

AC-16. Vercel AI SDK regression with `@ai-sdk/openai-compatible@2.0.38` and a
Zod schema returns a parsed object matching the canonical fixture.

AC-17. `json_schema.schema` byte-boundary tests cover exactly `16_384` raw
UTF-8 bytes accepted and `16_385` raw UTF-8 bytes rejected with HTTP 413
`json_schema_too_large` at provider and coordinator. The byte count is over the
schema JSON value as it appears in the request body, including insignificant
whitespace inside that value, not UTF-16 code units and not a compacted
post-parse serialization.

AC-18. Error envelopes for all v0.1.0 HTTP and terminal errors include at least
`error.type`, `error.code`, `error.message`, `error.param`, `error.retryable`,
`error.request_id`, `error.inference_ran`, and `error.settlement_ran`, matching
the SPEC-018 v0.2 envelope discipline (`specs/SPEC-018-agentic-tool-calling.md:734-753`).

AC-19. Money-path proof: `malformed_json_response` and
`json_schema_validation_failed` produce `FaultBreakerQualifying` request-log
rows and zero provider-positive credits. The billing recorder normalizes empty
fault flags only when none is provided
(`phase4-coordinator/internal/buyer/billing_recorder.go:181-183`), and the
billing formula returns before positive-credit calculation for
`FaultBreakerQualifying` (`phase4-coordinator/internal/billing/formula.go:112-114`).

AC-20. Coordinator validation parity: coordinator request validation extends
the current `response_format.type` allow-list from `text|json_object` to
`text|json_object|json_schema` and enforces the same `16_384` schema cap
before dispatch (`phase4-coordinator/internal/buyer/server.go:3608-3615`).

AC-21. Gateway pass-through remains byte-preserving for request bodies. The
gateway may parse enough to enforce existing quota and stream routing, but it
MUST forward the original request bytes to the coordinator as it does today
(`phase5-gateway/internal/router/chat_proxy.go:102-117`,
`phase5-gateway/internal/router/chat_proxy.go:217-224`, `phase5-gateway/internal/router/chat_proxy.go:997-1008`).

AC-22. `strict:false` returns HTTP 400
`json_schema_non_strict_unsupported_in_v0_1`; it is not silently treated as
`strict:true` and not accepted as observability-only mode.

AC-23. Schema-description prompt-injection fixture: hostile strings in
`json_schema.description`, property descriptions, enum values, and const values
are rendered as JSON data inside the schema instruction, cannot terminate the
schema block, and do not suppress validation.

AC-24. Duplicate-key fixture: if model output contains duplicate JSON object
keys and `json_schema` or `json_object` is requested, the provider fails closed
with HTTP 502 `malformed_json_response` rather than accepting parser-dependent
first-key-wins or last-key-wins behavior.

AC-25. Deep-nesting fixture: validation rejects output whose decoded JSON depth
exceeds `32` with HTTP 502 `json_schema_validation_failed` and
`FaultBreakerQualifying`; valid depth `32` succeeds. This reuses the SPEC-018
depth posture (`phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-6`;
`specs/SPEC-018-agentic-tool-calling.md:963-975`).

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

Rejected keywords in v0.1.0: `oneOf`, `anyOf`, `allOf`, `not`, `$ref`,
`$defs`, `definitions`, `pattern`, `format`, `minimum`, `maximum`,
`exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `minLength`, `maxLength`,
`minItems`, `maxItems`, `uniqueItems`, `contains`, `minProperties`,
`maxProperties`, `propertyNames`, `patternProperties`, `dependentSchemas`,
`dependentRequired`, `if`, `then`, `else`, `default`, `examples`, `readOnly`,
`writeOnly`, and any unknown keyword. Rejection uses HTTP 400
`json_schema_unsupported_keyword`.

The schema root MAY be any allowed `type`, including array or scalar. If the
root is an object, it MUST include `additionalProperties:false` under
`strict:true`. If a nested schema is an object, the same rule applies
recursively. The validator MUST reject schemas that rely on unsupported
keywords for safety or correctness.

## 4. Family rendering

The provider MUST improve probability of valid JSON by injecting a
family-specific system instruction before inference. This is prompt guidance,
not a substitute for §5 validation.

Rendering uses the same family key mechanism as SPEC-018 v0.2: modelID
substring match for Qwen (`qwen2.5` or `qwen3`) and Llama-3.3
(`llama-3.3`), as implemented by `ToolPromptRenderer`
(`phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift:37-51`).
The render hook lives where `ToolPromptRenderer.renderMessages` is currently
called before `context.processor.prepare` (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:400`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:454`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:540`). v0.1.0 MUST NOT introduce a model-hash registry.

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

Qwen3 fixture requirement: input messages plus a simple object schema render to
a Qwen-family chat template with the schema instruction in the system segment
and no tool-call sentinel injection.

Llama-3.3 fixture requirement: the same request renders to the Llama-3.3 system
segment using the Llama family template and no `<|python_tag|>` tool-call
sentinel injection.

Descriptions, enum strings, const strings, and property names are untrusted
prompt data. They MUST be embedded only as JSON string data inside the schema
block; renderer tests MUST include attempts to close the block, inject new
system text, and include tool-call sentinels.

## 5. Validator behavior

After non-streaming inference completes and stop-token filtering has run
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:477-483`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:592-599`,
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:811-828`), the
provider applies this sequence:

1. If valid SPEC-018 tool calls were produced and request tools are enabled,
   return the tool-call response and skip SPEC-019 content validation.
2. If `response_format.type == "text"`, return normal assistant content.
3. If `response_format.type == "json_object"`, parse final assistant content as
   JSON, reject duplicate keys, and require root object or array.
4. If `response_format.type == "json_schema"`, parse final assistant content as
   JSON, reject duplicate keys, validate decoded JSON depth, and validate
   against the supplied schema subset.

`malformed_json_response` is used when parsing fails, duplicate keys are found,
the top-level value is not object-or-array for `json_object`, or the model
output cannot be represented as valid UTF-8 JSON text. It is HTTP 502,
`type:"upstream_provider_error"`, `retryable:true`, `inference_ran:true`, and
`settlement_ran:true`.

`json_schema_validation_failed` is used when parsed JSON fails schema
validation. It is HTTP 502, `type:"upstream_provider_error"`,
`retryable:true`, `inference_ran:true`, and `settlement_ran:true`. The envelope
MUST include the first offending RFC 6901 JSON pointer in `error.param`; root
failure uses `"/"`. The message SHOULD include the expected type or keyword
that failed, but buyers MUST key retry logic off `error.code`.

No internal retry is allowed in v0.1.0. Buyer retries happen at the buyer layer.

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

Response-size cap is inherited from SPEC-018 §10d.7:
`SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP = 2_097_152`
(`specs/SPEC-018-agentic-tool-calling.md:963-975`;
`phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-6`;
`phase4-coordinator/internal/buyer/server.go:42-45`). SPEC-019 does not define
a new response cap. For structured output, the cap applies to the final
assistant content's UTF-8 bytes after JSON parsing and validation, not to the
outer HTTP response envelope.

Decoded output JSON depth is capped at `32`, matching SPEC-018's public depth
constant (`phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:4-6`; `specs/SPEC-018-agentic-tool-calling.md:963-975`).

## 7. Coordinator / gateway behavior

Coordinator request validation currently accepts `response_format.type` only if
empty, `text`, or `json_object` (`phase4-coordinator/internal/buyer/server.go:3608-3615`).
SPEC-019 v0.1.0 extends the allow-list to `json_schema` and adds defense-in-depth
validation for:

- `json_schema.name` present and string;
- `json_schema.schema` present and object;
- schema UTF-8 byte length `<= 16_384`;
- rejected keywords;
- strict object `additionalProperties:false`;
- `stream:true` unsupported errors from §1.

After validation, coordinator dispatch remains pass-through. It MUST preserve
the buyer's `response_format` field through provider dispatch.

Gateway behavior remains pass-through. The gateway currently reads the inbound
body, parses only the minimal `chatRequest` fields for quota and stream routing,
then creates the upstream coordinator request from the original `body`
(`phase5-gateway/internal/router/chat_proxy.go:102-117`, `phase5-gateway/internal/router/chat_proxy.go:217-224`,
`phase5-gateway/internal/router/chat_proxy.go:997-1008`). SPEC-019 adds no gateway schema parser and no new endpoint.

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
`json_schema_too_large`, `json_schema_non_strict_unsupported_in_v0_1`, and
`streaming_json_schema_unsupported_in_v0_1` do not run inference and do not
create provider-positive settlement.

## 9. Forward-compatibility invariants

The schema subset MAY widen across v0.1.x. It MUST NOT narrow for requests that
were valid under v0.1.0.

Error codes MAY add new values. Existing v0.1.0 error codes MUST NOT be renamed
or repurposed.

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
change (`specs/SPEC-015-receipts.md:1191-1204`).

## 10. Deferred to v0.2 / v0.3

Deferred to v0.2:

- streaming structured output with partial-JSON-prefix validation per chunk;
- Vercel AI SDK and OpenAI SDK matrix expansion beyond the v0.1.0 anchor
  fixtures;
- wider schema subset after Cline and Vercel AI SDK compatibility evidence.

Deferred to v0.3 or later:

- `oneOf` / `anyOf` polymorphism;
- `$ref` / `$defs` schema reuse;
- non-strict mode (`strict:false`) as observability without enforcement;
- auto-retry with tightened prompt on validation failure;
- schema warm-cache between requests on the same connection;
- model-hash-bound structured-output family renderer registry.

## 11. Open questions / audit hooks

Audit lanes should probe:

1. JSON canonicalization edge cases: duplicate keys, NaN, Infinity,
   `-Infinity`, negative zero, lone surrogates in strings, unpaired escapes,
   deeply nested arrays, and UTF-8 byte counting for multibyte property names.
2. Prompt-injection risk from attacker-controlled schema descriptions, enum
   strings, const strings, property names, and tool-call sentinel strings inside
   schema text.
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
9. Coordinator/provider parity: schema-size cap, keyword rejection, strict
   object rules, stream unsupported errors, and error codes must be identical.
10. SDK ergonomics: `openai==2.44.0` Pydantic parsing and
    `@ai-sdk/openai-compatible@2.0.38` Zod parsing should fail only on real
    schema violations, not on envelope or content-shape drift.

## 12. Document metadata

Status: DRAFT. This SPEC becomes LOCKED only after the audit loop converges at
0 CRITICAL, 0 HIGH, and 0 MEDIUM across all required lanes.

Version: 0.1.0.

Precondition: SPEC-018 v0.2.4 LOCKED at `7e50832` via PR #202, with
implementation shipped at `c77313a` via PR #209
(`specs/SPEC-018-v0_2-IMPL-NOTES.md:7-10`; `git log --oneline` at drafting
time).

Successor: TBD. Expected next version is v0.1.1 for audit absorption or v0.2.0
if the audit loop promotes streaming structured output into scope.

Drafting scope: no implementation code, no SPEC-018 edits, no SPEC-015 schema
change, no new HTTP endpoint.
