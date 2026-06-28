# DESIGN_SPEC_018_v0_2 — Deliverable #7: Per-call `function.arguments` byte cap

## Normative recommendation

SPEC-018 v0.2 MUST replace the v0.1.5 `256 KiB` parser/coordinator
DoS bound for response-side `function.arguments` with these runtime
limits:

- `SPEC018_ARGUMENTS_PER_CALL_BYTE_CAP = 1_048_576` bytes (`1 MiB`).
- `SPEC018_ARGUMENTS_PER_RESPONSE_BYTE_CAP = 2_097_152` bytes (`2 MiB`).
- The cap comparison is inclusive: byte length `<= cap` succeeds;
  byte length `> cap` fails closed.
- Byte length is the UTF-8 byte length of the final unescaped
  `function.arguments` string value that an OpenAI client obtains after
  JSON/SSE parsing and fragment concatenation. It is not the byte length
  of the outer response JSON with string-escape overhead.
- The existing JSON nesting cap remains `32`.

The `1 MiB` per-call value is the v0.2 product cap for Cline. It allows
ordinary code writes, large generated configs, and borderline
`write_to_file` operations whose full argument object includes a file path
plus full file contents. It still rejects the important failure case:
multi-MB hostile JSON, for example a prompt-induced `10 MB` argument
string, before commit and settlement.

Public Cline evidence does not provide a usable 95th-percentile
`write_to_file` argument-size distribution. Cline documents tool usage and
OpenTelemetry events, but its telemetry excludes code content, file
contents, file paths, and command arguments/parameters. Public issue
evidence does show large-file `write_to_file` truncation/reliability
pressure, so v0.2 should not pretend that a public p95 has been measured.
The v0.2 release gate is therefore fixture-based plus Cline-smoke-based:
the cap MUST pass the ACs below and a Cline `write_to_file` smoke that
writes a large generated file with final `function.arguments` length in
the `512 KiB` to `1 MiB` band.

Sources checked:

- Cline tools reference: https://docs.cline.bot/tools-reference/all-cline-tools
- Cline telemetry privacy: https://docs.cline.bot/enterprise-solutions/monitoring/telemetry
- Cline OpenTelemetry events: https://docs.cline.bot/enterprise-solutions/monitoring/opentelemetry-events
- Large-file write issue signal: https://github.com/cline/cline/issues/4384

## 1. Cap value

v0.2 MUST use `1_048_576` bytes per call.

Rationale:

- Legitimate use: Cline `write_to_file` carries full file contents inside
  the argument object. `256 KiB` is too close to realistic generated docs,
  formatted JSON, bundled configs, and large code files once path,
  metadata, JSON keys, and string escaping are included. `1 MiB` leaves
  enough room for a roughly `500 KiB` file plus argument-object overhead.
- Attack resistance: `1 MiB` rejects pathological `10 MB` argument streams
  at 10 percent of their target size and preserves a hard fail-closed
  bound. It is large enough for Cline but still small enough that a single
  tool call cannot become an unbounded memory or settlement object.
- Model context: `1 MiB` is already at or beyond what many useful local
  code models can emit in one completion. Raising the default beyond this
  mainly increases denial-of-service exposure while helping only unusual
  workflows that should use segmented writes or patch-style tools.

## 2. Parser/coordinator alignment

The parser-side runtime validator and the coordinator §8.4
commit-worthy validator MUST use the same byte-counting function and the
same constants:

```text
per_call_cap_bytes = 1_048_576
per_response_cap_bytes = 2_097_152
max_json_depth = 32
```

Different parser and coordinator values are non-compliant for public
SPEC-018 v0.2 behavior. A stricter parser would create framework-visible
drift; a stricter coordinator would waste provider work and turn
provider-visible success into buyer-visible failure. The clean v0.2
contract is one cap, enforced twice:

- Parser enforcement protects provider memory and streaming state.
- Coordinator enforcement protects settlement and catches buggy or hostile
  providers.

## 3. Fail modes and buyer-visible shape

### Parser-side, before any tool-call bytes are emitted

If the provider parser detects a recognized tool-call attempt whose
`function.arguments` would exceed the cap before emitting
`tool_calls[]`, it MUST:

- emit no `tool_calls[]`;
- fall back to ordinary assistant content per §3.5;
- include the deliverable #5 structured signal with
  `reason = "byte_cap_exceeded"`;
- avoid reflecting more than an implementation-defined small excerpt of
  the oversized tool-call markup in the fallback content.

Non-streaming buyer-visible shape:

```json
{
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "<plain fallback content>",
        "tool_calls": null
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "macprovider_malformed_tool_call": {
      "detected": true,
      "reason": "byte_cap_exceeded",
      "scope": "tool_call",
      "cap_bytes": 1048576,
      "observed_bytes": 1048577
    }
  }
}
```

### Coordinator-side, malformed or oversized tool-call delta received

If an oversized `delta.tool_calls[].function.arguments` reaches the
coordinator, the coordinator MUST treat it as provider fault:

- HTTP `502` before response headers are committed;
- `FaultBreakerQualifying`;
- zero provider-positive credits;
- no commit-worthy response settlement.

Gateway buyer-visible non-streaming error shape:

```json
{
  "error": {
    "message": "upstream provider emitted malformed tool call: byte_cap_exceeded",
    "type": "api_error",
    "param": "choices[0].delta.tool_calls[0].function.arguments",
    "code": "upstream_provider_error",
    "macprovider_malformed_tool_call": {
      "detected": true,
      "reason": "byte_cap_exceeded",
      "scope": "tool_call",
      "cap_bytes": 1048576,
      "observed_bytes": 1048577,
      "fault_breaker_qualifying": true
    }
  }
}
```

### Streaming cap exceeded after streaming has begun

Streaming cannot withdraw earlier SSE chunks. If the provider or
coordinator detects the cap crossing after any tool-call stream state has
been emitted, the next buyer-visible event MUST be a terminating SSE error
frame followed by `[DONE]`. The chunk that crosses the cap MUST NOT be
forwarded.

```text
data: {"error":{"message":"tool call arguments exceeded byte cap","type":"api_error","param":"choices[0].delta.tool_calls[0].function.arguments","code":"malformed_tool_call","macprovider_malformed_tool_call":{"detected":true,"reason":"byte_cap_exceeded","scope":"tool_call","cap_bytes":1048576,"observed_bytes":1048577}}}

data: [DONE]
```

The coordinator MUST mark the stream `FaultBreakerQualifying` and settle
zero provider-positive credits. If the provider detects the failure before
emitting any tool-call fragment, it MAY instead use the parser-side
fallback shape above and include the structured malformed signal in the
final usage chunk.

## 4. Multi-call interaction

v0.2 MUST enforce both limits:

- each individual `tool_calls[i].function.arguments` string MUST be
  `<= 1_048_576` UTF-8 bytes;
- the sum of all `function.arguments` UTF-8 byte lengths in the response
  MUST be `<= 2_097_152` bytes.

This preserves per-call Cline ergonomics while closing the multiplicative
DoS case where `N` individually-valid calls produce an unbounded response.
The aggregate failure reason is `response_byte_cap_exceeded`; the per-call
failure reason remains `byte_cap_exceeded`.

## 5. Streaming incremental enforcement

For streaming tool calls, the provider and coordinator MUST keep these
accumulators per choice:

```text
per_call_bytes[index] += utf8_len(decoded_delta_tool_calls[index].function.arguments_fragment)
per_response_bytes += utf8_len(decoded_delta_tool_calls[index].function.arguments_fragment)
```

Before forwarding any SSE chunk that contains a
`function.arguments` fragment, the component MUST decode the fragment,
compute the resulting counters, and reject the chunk if either counter
would exceed its cap. The violating chunk is not forwarded.

Settlement is finalized only at end-of-stream after:

- every call is complete;
- every final `function.arguments` value parses as a JSON object;
- JSON depth is `<= 32`;
- per-call and per-response byte caps pass.

Any cap failure before that point means the response never becomes
commit-worthy, even if earlier bytes were already streamed to the buyer.
Because settlement happens at end-of-stream, this is not a retroactive
credit clawback; it is a non-commit terminal path.

## 6. Configurability

v0.2 MUST NOT make the cap buyer-negotiable or provider-operator
configurable on the public SPEC-018 wire surface.

The public v0.2 constants are part of the compatibility contract:

```text
per_call_cap_bytes = 1_048_576
per_response_cap_bytes = 2_097_152
```

Operators MAY run private, non-public experiments with different values,
but a deployment advertising SPEC-018 v0.2 compliance MUST accept the
baseline fixtures below and MUST enforce the same values at parser and
coordinator. A future SPEC may introduce a
`request_header -> operator_max -> hard_max` negotiation chain, but that
requires a SPEC-006 header allocation and an advertised effective-cap
response field. It is deliberately deferred because provider-local
misconfiguration would otherwise turn a wire guarantee into a route
lottery for Cline.

## 7. §10c forward-compat invariant

The v0.2 cap is wire behavior.

Future SPEC-018 v0.2.x versions MAY raise `per_call_cap_bytes` or
`per_response_cap_bytes`. They MUST NOT lower either value for default
no-header behavior, MUST NOT change the inclusive boundary rule, and MUST
NOT change the byte-counting domain from UTF-8 bytes of the unescaped
final `function.arguments` string.

A v0.2.x implementation MUST continue to accept every v0.2.0 baseline
fixture whose calls are `<= 1_048_576` bytes each and whose aggregate
arguments are `<= 2_097_152` bytes. Lowering either cap requires a major
SPEC-018 version bump or an explicit buyer opt-in to a lower cap.

## 8. Acceptance criteria and test plan

AC-25. **Constants and alignment.** Parser and coordinator tests assert
that the effective public constants are exactly:
`per_call_cap_bytes == 1_048_576`,
`per_response_cap_bytes == 2_097_152`, and `max_json_depth == 32`.

AC-26. **Cap passes below and at boundary.** Given a recognized Qwen
`write_to_file` tool call whose final emitted `function.arguments` UTF-8
byte length is `1_048_575`, the provider emits a normal tool call with
`finish_reason == "tool_calls"`. Repeat with exact length `1_048_576`;
it also succeeds.

AC-27. **Per-call cap rejects above boundary.** Given the same fixture
with final `function.arguments` UTF-8 byte length `1_048_577`, the
provider emits no `tool_calls[]` and includes
`usage.macprovider_malformed_tool_call.reason == "byte_cap_exceeded"` on
the parser-side fallback path. A coordinator unit test that receives the
same oversized tool-call delta returns HTTP `502`, marks
`FaultBreakerQualifying`, and settles zero provider-positive credits.

AC-28. **Streaming cap rejects mid-stream.** Given streaming fragments
for one `tool_calls[0].function.arguments` where the first fragments sum
to `1_048_570` bytes and the next decoded fragment is `7` bytes, the
component rejects before forwarding the crossing fragment, emits a
terminating SSE error frame with `code == "malformed_tool_call"` and
`reason == "byte_cap_exceeded"`, then emits `[DONE]`. Settlement is zero
provider-positive credits and `FaultBreakerQualifying` is recorded.

AC-29. **Aggregate cap rejects.** Two tool calls with argument lengths
`700_000` and `700_000` bytes succeed. Three tool calls with argument
lengths `700_000`, `700_000`, and `700_000` bytes fail because the
aggregate `2_100_000` exceeds `2_097_152`; the structured reason is
`response_byte_cap_exceeded`.

AC-30. **Byte counting is UTF-8, not scalar count.** A fixture containing
multi-byte Unicode inside `function.arguments` is counted by UTF-8 bytes.
A string whose character count is below the cap but UTF-8 byte length is
`1_048_577` fails.

AC-31. **§10c cap regression.** Every SPEC-018 v0.2.x candidate runs the
v0.2.0 baseline cap fixture suite: exact-boundary per-call success,
aggregate-boundary success, per-call `+1` rejection, and aggregate `+1`
rejection. The exact-boundary success fixtures MUST continue to succeed
without buyer headers or provider-specific configuration.
