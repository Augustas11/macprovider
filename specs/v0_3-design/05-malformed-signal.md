# DESIGN_SPEC_018_v0_2 - Deliverable #5: Structured `malformed_tool_call` signal

## Decision

SPEC-018 v0.2 SHOULD add a structured buyer-visible diagnostic at:

```json
{
  "usage": {
    "prompt_tokens": 123,
    "completion_tokens": 45,
    "total_tokens": 168,
    "macprovider_malformed_tool_call": {
      "detected": true,
      "reason": "parse_failure",
      "parser_version": "spec-018-v0.2.0",
      "raw_excerpt": {
        "text": "<tool_call>{\"name\":\"read_file\",\"arguments\":",
        "bytes": 43,
        "truncated": false,
        "max_bytes": 256
      }
    }
  }
}
```

The field is additive metadata. It does not change `choices[]`, does not add a
new `finish_reason`, does not insert sentinel `tool_calls[]`, and does not
participate in SPEC-015 output receipt canonicalization.

If the coordinator rejects a malformed pre-commit provider stream and therefore
does not have a successful chat-completion body to forward, the existing HTTP
502 `FaultBreakerQualifying` path remains authoritative. In that case the same
diagnostic schema SHOULD be copied under the OpenAI-style error object:

```json
{
  "error": {
    "message": "provider emitted malformed tool-call delta",
    "type": "macprovider_provider_fault",
    "code": "malformed_tool_call",
    "macprovider_malformed_tool_call": {
      "detected": true,
      "reason": "depth_cap_exceeded",
      "parser_version": "spec-018-v0.2.0",
      "raw_excerpt": {
        "text": "<tool_call>{\"name\":\"x\",\"arguments\":{\"a\":{\"b\":",
        "bytes": 51,
        "truncated": true,
        "max_bytes": 256
      }
    }
  }
}
```

That 502 error-body placement is an error-path escape hatch only; the normative
successful-response placement is `usage.macprovider_malformed_tool_call`.

## 1. Wire Shape

Pick option (a): `usage.macprovider_malformed_tool_call`.

Rationale:

- `usage` is already response metadata, not assistant output. The malformed
  signal is telemetry about parsing, not model-authored content.
- Unknown vendor-prefixed fields inside `usage` are the lowest-risk additive
  shape for OpenAI-wire clients. Buyers that do not know the field continue to
  read `choices[]`, `finish_reason`, and token counts normally.
- A top-level `macprovider_extensions` object is also additive in JSON, but it
  is more likely to be dropped by typed SDK response models and less naturally
  available to streaming accumulation code.
- A new `finish_reason = "malformed_tool_call"` is rejected because many SDKs
  and agent frameworks assert known finish-reason enums.
- A sentinel fake tool call is rejected because it pollutes the tool execution
  surface and risks accidental execution by clients that dispatch by
  `function.name`.

Successful non-streaming fallback response example:

```json
{
  "id": "chatcmpl_macprovider_abc",
  "object": "chat.completion",
  "created": 1782520000,
  "model": "qwen3-coder",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "<tool_call>{\"name\":\"read_file\",\"arguments\":",
        "tool_calls": null
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 500,
    "completion_tokens": 12,
    "total_tokens": 512,
    "macprovider_malformed_tool_call": {
      "detected": true,
      "reason": "parse_failure",
      "parser_version": "spec-018-v0.2.0",
      "raw_excerpt": {
        "text": "<tool_call>{\"name\":\"read_file\",\"arguments\":",
        "bytes": 43,
        "truncated": false,
        "max_bytes": 256
      }
    }
  }
}
```

Clean tool-call response example:

```json
{
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": null,
        "tool_calls": [
          {
            "id": "call_0123456789abcdef0123456789abcdef",
            "type": "function",
            "function": {
              "name": "read_file",
              "arguments": "{\"path\":\"README.md\"}"
            }
          }
        ]
      },
      "finish_reason": "tool_calls"
    }
  ],
  "usage": {
    "prompt_tokens": 500,
    "completion_tokens": 30,
    "total_tokens": 530
  }
}
```

For clean responses, `usage.macprovider_malformed_tool_call` MUST be absent.
Implementations MUST NOT emit `{ "detected": false }` in normal responses; absence
is the forward-compatible false value.

## 2. Signal Contents

The diagnostic object schema is:

```json
{
  "detected": true,
  "reason": "parse_failure",
  "parser_version": "spec-018-v0.2.0",
  "raw_excerpt": {
    "text": "<first bytes of committed malformed model-output span>",
    "bytes": 47,
    "truncated": true,
    "max_bytes": 256
  }
}
```

Fields:

- `detected`: REQUIRED boolean. MUST be `true` when the object is present.
- `reason`: REQUIRED enum string. Initial v0.2 values are listed below.
- `parser_version`: REQUIRED string. Recommended format:
  `spec-018-v<major>.<minor>.<patch>` for normative parsers, optionally suffixed
  by implementation build metadata such as `+swift.20260627`.
- `raw_excerpt`: OPTIONAL object. When present, `text` is the UTF-8 replacement
  decoded first `max_bytes` bytes of the committed malformed model-output span,
  JSON-escaped by the enclosing response. `max_bytes` MUST be <= 256 in v0.2.
  `bytes` is the byte length actually included in `text` after truncation.
  `truncated` says whether more bytes were available.

Privacy rule: `raw_excerpt` MUST be derived only from the model-output span that
caused parser commitment. It MUST NOT include request prompt bytes, hidden system
prompt bytes, buyer credentials, or full tool-result payloads copied from the
request. For `prompt_echo_blocked`, `raw_excerpt` SHOULD be omitted unless the
implementation can prove the excerpt contains no buyer-prompt-derived sensitive
content. If omitted for privacy, include:

```json
{
  "raw_excerpt_omitted_reason": "prompt_echo_privacy"
}
```

Canonical initial `reason` values:

| Reason | Meaning | Ties to |
| --- | --- | --- |
| `parse_failure` | Parser committed to a tool-call attempt, but the body failed the family grammar, decoded to invalid JSON/Python call shape, contained duplicate keys, used explicit `null` arguments, decoded to non-object arguments, or named no enabled tool. | v0.1 §3.4 / v0.2 §8.4 |
| `depth_cap_exceeded` | The committed candidate exceeded the JSON nesting cap of 32 before a valid tool call could be emitted. | v0.1.5 §3.4 + §8.4 caps |
| `byte_cap_exceeded` | The committed candidate exceeded the parser or commit-validator byte cap before a valid tool call could be emitted. For v0.2 this includes the existing 256 KiB commit-validator bound and the v0.2 per-arguments cap from deliverable #7 once finalized. | v0.1.5 caps + v0.2 #7 |
| `prompt_echo_blocked` | Parser found an otherwise syntactically valid tool-call candidate whose complete markup is blocked by the v0.2 prompt-echo guard. | v0.2 #3 |
| `family_mismatch` | Tool-call-like framing was present, but the request/model did not select the parser family required to interpret that framing under the active family-selection rules. In legacy modelID mode, this is the §3.2 modelID-no-match case. | v0.1.5 §3.2 |
| `unregistered_model_hash` | Tool-call-like framing was present, but the verified `model_hash` was absent, revoked, or not registered for a tool-call family, and no compliant buyer-consent override applied. | v0.2 #2 |

`reason` is not a provider-fault classifier by itself. Money-path treatment is
defined separately in §8 of this design.

## 3. Streaming Integration

Streaming MUST use the terminal usage chunk. It MUST NOT introduce a separate
SSE `event:` type for this signal.

Reasoning:

- SPEC-018 v0.1 already allows an OpenAI-style usage chunk with `choices = []`.
- Deliverable #4's accumulation model already requires clients to accumulate
  deltas and inspect the final stream state.
- Unknown SSE event types are not reliably surfaced by OpenAI-compatible SDKs.
  A custom event would be invisible to many clients and would fail the Cline
  anchor goal.

Malformed streaming example:

```text
data: {"id":"chatcmpl_macprovider_abc","object":"chat.completion.chunk","created":1782520000,"model":"qwen3-coder","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"chatcmpl_macprovider_abc","object":"chat.completion.chunk","created":1782520000,"model":"qwen3-coder","choices":[{"index":0,"delta":{"content":"<tool_call>{\"name\":\"read_file\",\"arguments\":"},"finish_reason":null}]}

data: {"id":"chatcmpl_macprovider_abc","object":"chat.completion.chunk","created":1782520000,"model":"qwen3-coder","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: {"id":"chatcmpl_macprovider_abc","object":"chat.completion.chunk","created":1782520000,"model":"qwen3-coder","choices":[],"usage":{"prompt_tokens":500,"completion_tokens":12,"total_tokens":512,"macprovider_malformed_tool_call":{"detected":true,"reason":"parse_failure","parser_version":"spec-018-v0.2.0","raw_excerpt":{"text":"<tool_call>{\"name\":\"read_file\",\"arguments\":","bytes":43,"truncated":false,"max_bytes":256}}}}

data: [DONE]
```

If `usage.macprovider_malformed_tool_call` is present in a stream, it MUST appear
in the last JSON `data:` payload before `[DONE]`, and that payload MUST have
`choices: []`. The field MUST NOT appear mid-stream.

For clean streaming tool calls, the usage chunk MAY be present or absent per the
normal usage policy, but if present it MUST NOT contain
`macprovider_malformed_tool_call`.

## 4. Cline Integration

Cline should consume the signal at its OpenAI-compatible provider boundary, not
inside individual tools. The minimal integration is an interceptor around the
chat-completions response object and the streaming chunk accumulator:

1. Non-streaming: after `chat.completions.create(...)` resolves, read
   `response.usage?.macprovider_malformed_tool_call`.
2. Streaming: accumulate chunks normally; when the terminal usage chunk arrives,
   read `chunk.usage?.macprovider_malformed_tool_call`.
3. HTTP 502: catch the provider error, parse the JSON body if present, and read
   `error.macprovider_malformed_tool_call`.
4. If the object is absent, preserve existing Cline behavior.
5. If present, do not try to execute or synthesize a tool call from
   `message.content`.

Suggested Cline policy:

| Reason | Cline behavior |
| --- | --- |
| `parse_failure` | Treat as malformed model output. Retry at most once with a different model or with non-streaming disabled/enabled according to the current failure mode. If repeated, show a provider/model malformed-tool-call error. |
| `depth_cap_exceeded` | Do not retry unchanged. Ask the user to narrow the task or switch to a model/profile that emits smaller structured arguments. |
| `byte_cap_exceeded` | Do not retry unchanged for large file-write/tool-output cases. Ask the user to split the operation or use a model/profile with the v0.2 arguments cap configured appropriately. |
| `prompt_echo_blocked` | Fail visibly with prompt-sanitization guidance. Retrying unchanged is expected to repeat the block. |
| `family_mismatch` | Treat as provider/model configuration mismatch. Retry only if another registered tool-capable model is available. |
| `unregistered_model_hash` | Treat as trust/configuration failure. Prefer a registered model; do not silently opt into an unregistered-hash override. |

SPEC-018 SHOULD NOT name a target Cline PR number. Cline is an external
open-source project and its extension points can move. The SPEC SHOULD instead
define a Cline compatibility acceptance artifact: a small wrapper/interceptor
patch, test fixture, or provider adapter proving that Cline can observe
`usage.macprovider_malformed_tool_call` and choose a user-visible recovery path
without parsing raw malformed markup.

## 5. Backward Compatibility and Receipts

Compatibility contract:

- The signal is additive. Buyers that ignore unknown `usage` fields MUST keep
  receiving the same `choices[]` content/tool-call shape they would have received
  without the signal.
- `choices[0].finish_reason` MUST remain one of the existing OpenAI-compatible
  values for the delivered completion, typically `"stop"`, `"length"`, or
  `"tool_calls"`. It MUST NOT be changed to `"malformed_tool_call"` in v0.2.
- The signal MUST NOT appear in `choices[0].message.tool_calls`.
- The signal MUST NOT appear in the canonical output object used by SPEC-015
  receipts. SPEC-015 §5.1 output canonicalization remains:

```json
{
  "content": "<assistant content string or empty string>",
  "tool_calls": null,
  "finish_reason": "stop"
}
```

or, for valid tool-call output:

```json
{
  "content": "",
  "tool_calls": [
    {
      "id": "call_0123456789abcdef0123456789abcdef",
      "type": "function",
      "function": {
        "name": "read_file",
        "arguments": "{\"path\":\"README.md\"}"
      }
    }
  ],
  "finish_reason": "tool_calls"
}
```

The malformed diagnostic is metadata about parser handling. Binding it into
`output_hash` would make receipt verification depend on diagnostic policy and
would make privacy redaction changes receipt-breaking. v0.2 MUST leave
SPEC-015 canonicalization unchanged for this deliverable.

Forward compatibility:

- v0.2.x MAY add new `reason` enum values.
- v0.2.x MUST NOT remove existing values.
- v0.2.x MUST NOT repurpose an existing value to mean a different condition.
- Clients MUST treat unknown `reason` values as non-executable malformed-tool
  diagnostics and show a generic provider/model parsing error.

## 6. False-Positive Control

The signal MUST NOT fire on speculative lookahead alone.

The parser has committed to a tool-call attempt only after all of the following
are true:

1. The request is tool-enabled.
2. A parser family has been selected, or a fail-closed family/hash diagnostic is
   being evaluated.
3. The model output contains a complete family-recognized opening marker at a
   framing position. Examples: Qwen `<tool_call>` or Llama `<|python_tag|>`.
4. After optional whitespace, the bytes following the opening marker begin with
   the grammar's body lead, such as `{` for Qwen JSON tool-call markup or the
   family-specific function-call lead for Llama.
5. The parser has started consuming that body as a candidate tool call.

If the output contains only a partial marker, a marker mentioned in prose without
the grammar body lead, or a lookahead prefix that the parser abandons before
body consumption, the provider MUST treat it as normal content and MUST NOT emit
`macprovider_malformed_tool_call`.

Examples:

- `The literal string <tool_call> appears in this document.` MUST NOT fire.
- `<tool_call>{"name":"read_file","arguments":` MAY fire as `parse_failure`
  because the parser consumed a committed Qwen body.
- `<tool_call>{"name":"x","arguments":{"a":` that exceeds depth 32 while being
  consumed MUST fire as `depth_cap_exceeded`.
- Tool-call-like output under an unregistered `model_hash` MUST fire as
  `unregistered_model_hash` only after a complete known opening marker plus body
  lead is observed; mere prose about tool calls MUST NOT fire.

Parser-version drift is acceptable only under this commitment rule. If v0.2
changes lookahead windows, it MUST NOT broaden firing to candidates that never
passed the committed-attempt threshold.

## 7. Acceptance Criteria and Test Plan

AC-MTC-1 (non-streaming parse failure). Given enabled tool `read_file`, selected
Qwen parser family, and model output
`<tool_call>{"name":"read_file","arguments":`, the buyer-visible response either:

- returns the existing settlement-protecting HTTP 502 fault path with
  `error.macprovider_malformed_tool_call.reason == "parse_failure"` when the
  coordinator rejects a malformed pre-commit provider emission; or
- returns HTTP 200 plain assistant content with no `tool_calls[]` and
  `usage.macprovider_malformed_tool_call.reason == "parse_failure"` when the
  provider locally falls back before emitting a commit-worthy malformed delta.

In both cases, no buyer-visible executable `tool_calls[]` is present.

AC-MTC-2 (non-streaming depth cap). Given a committed tool-call candidate whose
`arguments` nesting exceeds 32, the response diagnostic has
`reason == "depth_cap_exceeded"`, no executable `tool_calls[]` is emitted, and
provider-positive settlement remains blocked when this occurs on the
coordinator pre-commit fault path.

AC-MTC-3 (non-streaming byte cap). Given a committed tool-call candidate whose
candidate body or `function.arguments` exceeds the active byte cap, the response
diagnostic has `reason == "byte_cap_exceeded"` and no executable `tool_calls[]`
is emitted.

AC-MTC-4 (prompt echo). Given request prompt content containing an exact
tool-call markup block and model output echoing the same block, the provider
emits no executable `tool_calls[]` and the diagnostic reason is
`prompt_echo_blocked`. `raw_excerpt` is omitted or privacy-redacted according to
§2.

AC-MTC-5 (family mismatch). Given model output containing complete tool-call
framing plus body lead, but no selected compatible parser family under §3.2 or
the active v0.2 family-selection rules, the response emits no executable
`tool_calls[]` and the diagnostic reason is `family_mismatch`.

AC-MTC-6 (unregistered model hash). Given model output containing complete
tool-call framing plus body lead while the verified `model_hash` is not
registered for tool-call synthesis and no buyer-consent override applies, the
response emits no executable `tool_calls[]` and the diagnostic reason is
`unregistered_model_hash`.

AC-MTC-7 (clean tool call absence). Given clean output
`<tool_call>{"name":"read_file","arguments":{"path":"README.md"}}</tool_call>`,
the response emits a normal `tool_calls[]` entry, `finish_reason == "tool_calls"`,
and `usage.macprovider_malformed_tool_call` is absent.

AC-MTC-8 (plain prose absence). Given normal assistant prose that contains no
committed tool-call attempt, the response emits normal content and
`usage.macprovider_malformed_tool_call` is absent.

AC-MTC-9 (lookahead false-positive guard). Given prose containing
`<tool_call>` without a grammar body lead, the response emits normal content and
the malformed signal is absent.

AC-MTC-10 (streaming parse failure). For the AC-MTC-1 fixture with
`stream=true`, the terminal usage chunk before `[DONE]` contains
`usage.macprovider_malformed_tool_call.reason == "parse_failure"` on a successful
fallback stream, or the HTTP 502 error body contains
`error.macprovider_malformed_tool_call.reason == "parse_failure"` on a
coordinator fault-breaker stream.

AC-MTC-11 (streaming clean tool call absence). For the AC-MTC-7 fixture with
`stream=true`, accumulated `delta.tool_calls[].function.arguments` matches the
non-streaming arguments string, the final finish reason is `"tool_calls"`, and no
usage chunk contains `macprovider_malformed_tool_call`.

AC-MTC-12 (SDK backward compatibility). A v0.2 candidate response fixture with
`usage.macprovider_malformed_tool_call` parses under the AC-23 v0.1.3-baseline
OpenAI Python SDK pin without raising because of the unknown vendor-prefixed
usage field. The same test MUST include a clean response fixture proving absence
does not change the normal typed response path.

AC-MTC-13 (receipt non-participation). For a non-streaming malformed fallback
that returns HTTP 200 plain content with the usage diagnostic, recomputing the
SPEC-015 `output_hash` over §5.1 fields only yields the same hash as the same
response with the `usage.macprovider_malformed_tool_call` field removed.

AC-MTC-14 (Cline observation). A Cline compatibility harness or wrapper test
observes the diagnostic in both non-streaming and streaming modes and routes it
to a non-executing recovery path. The test MUST assert that Cline does not
execute a tool from `message.content` when the diagnostic is present.

## 8. Money-Path Interaction

This signal is diagnostic only. It MUST NOT change settlement, fault-breaker, or
credit rules.

Provider-fault / zero-credit cases:

- `parse_failure`, `depth_cap_exceeded`, and `byte_cap_exceeded` on a malformed
  pre-commit tool-call delta remain governed by §8.4. The coordinator MUST NOT
  treat such a delta as commit-worthy, MUST return the existing HTTP 502
  `FaultBreakerQualifying` response, and MUST settle zero provider credits.
- Adding `macprovider_malformed_tool_call` to the error body or audit event does
  not make the response billable and does not create a receipt-bearing successful
  completion.

Non-provider-fault diagnostic cases:

- `prompt_echo_blocked` is not a provider fault when the provider correctly
  detects and suppresses prompt-derived tool-call synthesis. The provider did
  normal inference and applied the required guard. The provider SHOULD earn for
  the turn under the normal successful-response settlement rules, subject to
  whatever settlement policy applies to the delivered non-tool completion.
- `family_mismatch` and `unregistered_model_hash` are configuration/trust
  diagnostics. They MUST fail closed for tool-call synthesis. Settlement follows
  the existing policy for the delivered response or the existing error path that
  applies to the request; the malformed signal itself does not override it.

Audit/logging:

- Coordinator and provider audit events SHOULD record
  `malformed_tool_call.reason`, `parser_version`, and whether the path was
  `successful_fallback` or `fault_breaker_502`.
- Audit logs MUST NOT store `raw_excerpt` by default. If an implementation keeps
  excerpts for local debug builds, it must be opt-in and redacted under the same
  privacy rule as §2.

## Recommendation Summary

Use `usage.macprovider_malformed_tool_call` for successful OpenAI-shaped
responses and terminal streaming usage chunks. Keep clean responses silent by
omitting the field. Use the same schema inside the existing OpenAI-style error
body only when the coordinator's 502 fault-breaker path prevents a successful
`usage` envelope. Do not alter `finish_reason`, do not synthesize sentinel tool
calls, do not include the diagnostic in SPEC-015 receipts, and do not let the
diagnostic alter money-path settlement.
