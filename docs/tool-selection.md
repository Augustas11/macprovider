# Tool-selection support

Tool selection keeps the buyer's intended mode through cleartext Chat
Completions, Responses and the optional Messages facade. The normative contracts are
[SPEC-018 §3.11](../specs/SPEC-018-agentic-tool-calling.md) and
[SPEC-006 §5.4](../specs/SPEC-006-buyer-api.md).

This describes the implementation contract. Hardware qualification on the
Mac Studio and buyer acceptance using an approved released provider are still
pending. Unit tests, catalog entries and runtime capability claims do not
establish those gates.

| Serving model/runtime | `auto` | `none` | `required` / selected function |
|---|---|---|---|
| Exact `mlx-community/Qwen3.6-35B-A3B-4bit`, native `mlx_cache` | Existing parsing | Supported | Full generation withheld and schema validated |
| Other native `mlx_cache` model identities | Existing parsing | Supported | Rejected |
| Ollama, LM Studio, oMLX and other external/loopback adapters | Existing behavior | Rejected | Rejected |

An alias works only when it resolves to the same serving model identity.
A provider that loads its configured model under a local name and advertises
a configured catalog id is checked against that catalog id while that model
is loaded; a warm-swapped model is checked against its own id.
Qwen family membership alone does not qualify another model or quantization.
`GET /v1/status` projects `tool_choice_modes` per serving model from eligible
provider claims. The coordinator checks compatibility again during routing;
the provider checks its actual loaded model before generating. Legacy
providers without the new capability contribute only existing `auto` support.
OpenRouter's string-mode enum may include `auto`, `none` and `required` when
backed by compatible serving providers. Named selection remains an object.

## Request forms

For Chat Completions:

```python
request = dict(
    model="mlx-community/Qwen3.6-35B-A3B-4bit",
    messages=[{"role": "user", "content": "Look up weather in Vilnius."}],
    tools=[{
        "type": "function",
        "function": {
            "name": "get_weather",
            "parameters": {
                "type": "object",
                "properties": {"city": {"type": "string"}},
                "required": ["city"],
                "additionalProperties": False,
            },
        },
    }],
    tool_choice={"type": "function", "function": {"name": "get_weather"}},
    parallel_tool_calls=False,
    max_tokens=1024,
)
response = client.chat.completions.create(**request)
```

In the example above, keep `max_tokens=1024` and change the selection to
`tool_choice="required"` to require any declared function, or use
`tool_choice="none"` for a native text turn without new tool calls. Omitted,
`null` and `"auto"` keep the existing tool behavior and do not promise a
required call or schema-valid arguments.

Responses accepts its endpoint's named-function form and translates it to
the same selected function. Messages maps `auto` to `auto`, `none` to `none`,
`any` to `required`, and `{"type":"tool","name":"get_weather"}` to the
selected function. Messages still requires its existing feature flag. The
canonical native checks apply equally to local provider HTTP and cleartext
relay requests.

Relay-blind/encrypted envelopes do not negotiate these explicit tool modes
in this change. They have no `none`, `required`, or named guarantee, and a
cleartext capability listing does not extend to them. A new provider rejects
an explicit non-auto selection after decryption and before generation using
the existing opaque `relay_blind_provider_unsupported` error path, without
disclosing a requested function name; automatic selection is unchanged. A blind coordinator cannot infer hidden selections in legacy
ciphertext or promise that legacy encrypted requests enforce them.

## Schema and output bounds

Guaranteed modes require an explicit completion budget of 1–16,384 tokens
using `max_tokens` (the accepted `max_completion_tokens` alias also works).
An absent or out-of-range budget is rejected before generation with
`unsupported_tool_choice`; no default is supplied for a guaranteed request.
They accept 1–128 uniquely named function tools. Function names
are 1–64 ASCII characters in `[A-Za-z0-9_-]`. Each parameter schema must be a
typed object, at most 16 KiB and depth 32, using the existing strict validator
subset:

- Every schema node declares one type: `object`, `array`, `string`, `number`,
  `integer`, `boolean` or `null`.
- Objects set `additionalProperties:false` and list every property exactly
  once in `required`. Arrays declare an `items` schema.
- Supported keywords are `type`, `properties`, `required`, `items`,
  `additionalProperties`, scalar typed `enum`/`const`, `title`, `description`,
  `minimum`, `maximum`, `multipleOf`, and root `$schema`. Numeric bounds are
  finite and ordered; `multipleOf` is greater than `1e-300`. Every numeric
  value anywhere in a schema, including numeric `enum`/`const` values, has
  absolute magnitude at most `9007199254740991` (`2^53 - 1`). Larger values
  are unsupported because the validator does not promise exact large-integer
  comparison.
- Optional properties, `$ref`, union types, combinators, string patterns and
  formats are unsupported. A schema outside the subset is rejected before
  inference instead of becoming an unenforced prompt suggestion.

A successful required turn contains valid declared calls. A successful named
turn contains only the chosen function. Omitted/false `parallel_tool_calls`
requires exactly one call; true allows 1–128 calls. Arguments are capped at
1 MiB per call and 2 MiB in total, with depth 32. All numeric argument values,
recursively, must also be finite with absolute magnitude at most `2^53 - 1`,
even when their schema has no numeric bound. Numeric-looking strings are
not coerced into numbers. Unsupported schema numbers fail
before generation as `unsupported_tool_schema`; out-of-domain generated
arguments fail as `tool_selection_validation_failed`. Custom stop strings and
non-text `response_format` cannot be combined with guaranteed modes.

The native path uses ordinary model generation followed by complete-output
validation. It does not constrain sampling logits. It accepts complete strict
JSON `<tool_call>` envelopes only, validates the entire generation and every
argument object, and does not repair JSON, fabricate calls or silently retry
as `auto`. The model can fail to produce acceptable output; only successful
responses carry the selection guarantee.

## Streaming and failures

`required` and named streaming requests withhold all generated text and calls
until the entire completion passes validation. Success then emits complete
validated call data and a `tool_calls` finish. Invalid output cannot leak a
partial dispatchable call. Native `none` also holds output until its no-call
check passes. Ordinary `auto` retains incremental tool streaming and serial
stop behavior.

Unsupported selection/model/runtime combinations return HTTP 400
`unsupported_tool_choice`. Malformed selections or unavailable named functions
are HTTP 400 `invalid_tool_choice` at the coordinator boundary (the local
provider uses `unsupported_tool_choice`). Unsupported or malformed guaranteed-mode
schemas return HTTP 400 `unsupported_tool_schema`. Invalid generated output
returns `tool_selection_validation_failed` (HTTP 502 before headers, a terminal
error after streaming begins). This includes wrong names, missing calls,
invalid arguments, malformed/trailing markup, cardinality violations and token
exhaustion. Cancellation and timeout never fabricate a successful result.

Buyers should handle these errors explicitly. A streaming terminal error does
not establish a successful call, and a capability listing does not reserve a
provider or guarantee capacity.
