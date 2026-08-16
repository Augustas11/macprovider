# Using MacProvider with the OpenAI SDK

MacProvider speaks OpenAI-compatible `/v1/chat/completions`. If you have `openai-python` or `openai-node` installed you already have a MacProvider client — set the `base_url`, use your MacProvider API key, done. This page collects the copy-pasteable patterns for every buyer-facing surface: tool calling, structured output, streaming, sticky-conversation prefix caching, provider pinning, and signed-receipt verification.

There is no `macprovider` SDK. The OpenAI SDK IS the MacProvider SDK. That is deliberate — every agent framework already targets `openai`, and a wrapper would just add friction. When you need something the OpenAI SDK doesn't cover directly (a MacProvider-specific header, a receipt), it's a one-liner on the client or a call to the [`macprovider-verify`](../phase7-verify/README.md) CLI. This page is that reference.

## Base setup

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.malibu.tech/v1",
    api_key="<your-macprovider-api-key>",
)
```

TypeScript / JavaScript:

```typescript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "https://api.malibu.tech/v1",
  apiKey: process.env.MACPROVIDER_API_KEY,
});
```

Get an API key: [api.malibu.tech/auth/github/start](https://api.malibu.tech/auth/github/start)

## Basic completion

```python
resp = client.chat.completions.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[{"role": "user", "content": "Hello, world"}],
)
print(resp.choices[0].message.content)
```

Any MLX chat model in the pool works. Available models: `client.models.list()` or `curl https://api.malibu.tech/v1/models`.

Text-only structured content is accepted for `system` and `user` messages too.
Frameworks that emit `content=[{"type":"text","text":"Hello"}]` for those roles
are normalized to plain text before provider dispatch. Multimodal parts such as
`image_url` are not supported in v1 and return `unsupported_content_shape`.

## Streaming

```python
stream = client.chat.completions.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[{"role": "user", "content": "Explain WebSocket ping/pong in one sentence."}],
    stream=True,
)
for chunk in stream:
    delta = chunk.choices[0].delta.content or ""
    print(delta, end="", flush=True)
```

Server-Sent Events, OpenAI-compatible chunks. No MacProvider-specific handling needed.

## Tool calling

MacProvider ships OpenAI-shape `tools` + `tool_choice` per [SPEC-018](../specs/SPEC-018-*.md). Multi-turn tool loops, streamed tool-call deltas, and `tool_call_id` back-references all work.

```python
resp = client.chat.completions.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[{"role": "user", "content": "What's the weather in Vilnius?"}],
    tools=[
        {
            "type": "function",
            "function": {
                "name": "get_weather",
                "description": "Get the current weather for a city",
                "parameters": {
                    "type": "object",
                    "properties": {"city": {"type": "string"}},
                    "required": ["city"],
                },
            },
        }
    ],
)

for call in resp.choices[0].message.tool_calls or []:
    print(call.function.name, call.function.arguments)  # arguments is a JSON string
```

A complete multi-turn tool demo lives at [`examples/tool_calling_demo.py`](../examples/tool_calling_demo.py).

**Note.** `function.arguments` is a JSON-encoded STRING per OpenAI's wire shape — `json.loads(call.function.arguments)` to get a dict. Both Qwen 2.5 and Llama 3.3 chat templates render `tools` natively.

## Structured output (JSON schema)

Grammar-constrained sampling via [SPEC-019](../specs/SPEC-019-*.md). Works in both streaming and non-streaming.

```python
resp = client.chat.completions.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[
        {"role": "system", "content": "Extract contact info as JSON."},
        {"role": "user", "content": "Call John at 555-0100, john@example.com"},
    ],
    response_format={
        "type": "json_schema",
        "json_schema": {
            "name": "contact",
            "schema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "phone": {"type": "string"},
                    "email": {"type": "string"},
                },
                "required": ["name", "phone", "email"],
            },
            "strict": True,
        },
    },
)

import json
contact = json.loads(resp.choices[0].message.content)
```

The response `content` is a JSON string that matches the schema. `strict: true` guarantees schema conformance via constrained decoding.

## Sticky conversations (prefix-cache reuse)

Multi-turn conversations get routed to the same provider via a buyer-supplied opaque tag on the `X-MacProvider-Conversation` header. When the sticky provider serves turn N+1, its warm KV-cache is reused for the shared prefix and the request is billed at a discounted `prompt_cache_hit_rate_per_mtok` for the cached tokens ([SPEC-004](../specs/SPEC-004-smart-router.md) sticky routing + [SPEC-024](../specs/SPEC-024-prefix-cache-billing.md) billing).

```python
conversation_id = "thread-42"  # any opaque string stable across turns

client_sticky = OpenAI(
    base_url="https://api.malibu.tech/v1",
    api_key="<your-macprovider-api-key>",
    default_headers={"X-MacProvider-Conversation": conversation_id},
)

# Turn 1: cold prefix, provider caches it
resp1 = client_sticky.chat.completions.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[
        {"role": "system", "content": "You are a code review assistant."},
        {"role": "user", "content": "Explain the SOLID principles."},
    ],
)

# Turn 2: same conversation_id -> same provider, warm KV-cache reused
resp2 = client_sticky.chat.completions.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[
        {"role": "system", "content": "You are a code review assistant."},
        {"role": "user", "content": "Explain the SOLID principles."},
        {"role": "assistant", "content": resp1.choices[0].message.content},
        {"role": "user", "content": "Which one is most often violated in practice?"},
    ],
)

# Observe the cache hit
print(resp2.usage.model_dump())
# {"prompt_tokens": 1500, "completion_tokens": 300, "total_tokens": 1800, "cached_prompt_tokens": 1200}
```

- The tag is opaque and buyer-chosen. Use a stable per-thread identifier.
- Gateway HMACs the tag with your `account_id` before forwarding — one buyer's `thread-42` never collides with another buyer's `thread-42`.
- If the sticky provider is unavailable (disconnected, thermally throttled per Cluster D, admission-full), the request falls through to normal routing and `cached_prompt_tokens` will be `0`.
- Legacy providers that don't report cache hits emit `cached_prompt_tokens: 0` — safe to consume unconditionally.

## Pinning to a specific provider

Route every request in a session to a specific provider via `X-MacProvider-Pin-Provider`. Useful for reproducibility, debugging, or when you're contracting a specific Mac.

```python
client_pinned = OpenAI(
    base_url="https://api.malibu.tech/v1",
    api_key="<your-macprovider-api-key>",
    default_headers={"X-MacProvider-Pin-Provider": "provider-air5"},
)
```

Provider IDs are visible on the pool dashboard at [console.malibu.tech](https://console.malibu.tech). If the pinned provider is offline the request returns `503 no_provider_available` rather than routing to a substitute — pinning is strict.

`X-MacProvider-Pin-Provider` and `X-MacProvider-Conversation` compose: pinning trumps sticky. If you pin, sticky becomes redundant.

## Which provider served this request?

Every response carries `X-MacProvider-Provider` identifying which provider actually served it — useful for logging, debugging, or feeding a subsequent pin.

```python
resp = client.chat.completions.create(...)
served_by = resp.response.headers.get("X-MacProvider-Provider")
```

(Extracting response headers from `openai-python` requires the `raw_response` accessor — see the [OpenAI SDK docs](https://github.com/openai/openai-python#accessing-raw-response-data-eg-headers) for the exact pattern.)

## Signed inference receipts

Every response carries an ed25519-signed receipt in the `X-MacProvider-Receipt` response header. The receipt binds the canonical prompt hash, output hash, provider public key, catalog-resolved model hash, and timestamp per [SPEC-015 v0.3](../specs/SPEC-015-receipts.md). You can verify offline that a provider signing key signed that tuple, without trusting the gateway for receipt verification. The receipt does not prove model honesty, hardware attestation, or detection of a provider falsifying its own model-hash measurement.

Capture the receipt at request time:

```python
raw = client.chat.completions.with_raw_response.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[{"role": "user", "content": "Hello"}],
)
resp = raw.parse()
receipt = raw.headers.get("X-MacProvider-Receipt")
```

Verify offline with the [`macprovider-verify`](../phase7-verify/README.md) CLI:

```bash
macprovider-verify \
  --receipt "$RECEIPT" \
  --request-body "$REQUEST_JSON" \
  --response-body "$RESPONSE_JSON"
# Exit code 0 = valid, non-zero = invalid/inconclusive
```

Install `macprovider-verify` per the [phase7-verify README](../phase7-verify/README.md). Pure Go, no runtime dependencies, cross-platform.

**When to verify:** most buyers verify post-hoc for audit trails rather than on every request (per-request verification adds a round-trip). Batch a day's receipts, run `macprovider-verify` in a nightly job, keep the verified receipts for dispute resolution.

## Full working example

Put the pieces together:

```python
import json
from openai import OpenAI

client = OpenAI(
    base_url="https://api.malibu.tech/v1",
    api_key="<your-macprovider-api-key>",
    default_headers={"X-MacProvider-Conversation": "session-2026-07-02-a"},
)

raw = client.chat.completions.with_raw_response.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Give me one interesting fact about Apple Silicon."},
    ],
    response_format={
        "type": "json_schema",
        "json_schema": {
            "name": "fact",
            "schema": {
                "type": "object",
                "properties": {"fact": {"type": "string"}, "source": {"type": "string"}},
                "required": ["fact", "source"],
            },
            "strict": True,
        },
    },
)
resp = raw.parse()

print("served by:  ", raw.headers.get("X-MacProvider-Provider"))
print("cached toks:", resp.usage.cached_prompt_tokens if hasattr(resp.usage, "cached_prompt_tokens") else 0)
print("receipt:    ", raw.headers.get("X-MacProvider-Receipt")[:60], "...")
print("payload:    ", json.loads(resp.choices[0].message.content))
```

## Header reference

| Header | Direction | Purpose | Ref |
|---|---|---|---|
| `X-MacProvider-Conversation` | Request | Sticky-affinity tag for prefix-cache reuse | SPEC-004, SPEC-024 |
| `X-MacProvider-Pin-Provider` | Request | Strict-pin to specific provider | SPEC-004 |
| `X-MacProvider-Provider` | Response | Which provider actually served this | SPEC-002 |
| `X-MacProvider-Receipt` | Response | ed25519-signed inference receipt | SPEC-015 v0.3 |

## Usage object reference

MacProvider's `usage` extends OpenAI's shape with one field:

```json
{
  "prompt_tokens": 1500,
  "completion_tokens": 300,
  "total_tokens": 1800,
  "cached_prompt_tokens": 1200
}
```

`cached_prompt_tokens` is always present, `0` when there was no cache reuse (non-sticky route, cold sticky provider, or pre-SPEC-024 provider). See [SPEC-024](../specs/SPEC-024-prefix-cache-billing.md) for the billing formula.

## Framework compatibility

Any framework built on `openai-python` or `openai-node` works out of the box. Tested surfaces:

- **LangChain.** `ChatOpenAI(base_url=..., api_key=...)` — full compatibility including tool calling and structured output.
- **LlamaIndex.** `OpenAI(base_url=..., api_key=...)` — same story.
- **Instructor.** Structured output via `response_format` works; Instructor's `patch()` layer sees MacProvider as plain OpenAI.
- **Aider.** Point `OPENAI_API_BASE` at `https://api.malibu.tech/v1`; existing config keys work.
- **Cline / Continue.** Per [SPEC-018 v0.2.4](../specs/SPEC-018-*.md) MacProvider is a Cline drop-in target — set the OpenAI-compatible endpoint to `https://api.malibu.tech/v1`.

If you find a framework where the OpenAI SDK works but MacProvider doesn't, that's a wire-shape bug — file an issue with a minimal repro.

## What's NOT in the OpenAI SDK

Two things live outside the SDK because they don't fit its request/response shape:

1. **Receipt verification** — one-way offline check, better as a separate tool (`macprovider-verify`).
2. **Provider selection / autotune** — buyer-side (`macprovider-cli models browse`, `macprovider-cli autotune`) is separate from the API surface.

Everything else — routing, retries, billing, model catalog, model-hash verification, tool calling, structured output, streaming, sticky affinity, provider pinning — is transparent through the OpenAI SDK.
