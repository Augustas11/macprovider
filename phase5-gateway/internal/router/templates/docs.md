# Getting started

Mac Provider exposes an OpenAI-compatible API at `https://api.streamvc.live/v1`.

1. Sign up with GitHub at `/auth/github/start`.
2. Save your `mp_` key on the one-shot account page.
3. Use any OpenAI SDK with `base_url=https://api.streamvc.live/v1`.

## Quickstart code samples

### curl

```sh
curl https://api.streamvc.live/v1/chat/completions \
  -H 'Authorization: Bearer mp_your_key' \
  -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community/Llama-3.2-3B-Instruct-4bit","messages":[{"role":"user","content":"Say hello"}],"max_tokens":64}'
```

### openai-python

```python
from openai import OpenAI

client = OpenAI(api_key="mp_your_key", base_url="https://api.streamvc.live/v1")
resp = client.chat.completions.create(
    model="mlx-community/Llama-3.2-3B-Instruct-4bit",
    messages=[{"role": "user", "content": "Say hello"}],
    max_tokens=64,
)
print(resp.choices[0].message.content)
```

### openai-node

```js
import OpenAI from "openai";

const client = new OpenAI({
  apiKey: "mp_your_key",
  baseURL: "https://api.streamvc.live/v1",
});
const resp = await client.chat.completions.create({
  model: "mlx-community/Llama-3.2-3B-Instruct-4bit",
  messages: [{ role: "user", content: "Say hello" }],
  max_tokens: 64,
});
console.log(resp.choices[0].message.content);
```

### openai-go

```go
client := openai.NewClient(
    option.WithAPIKey("mp_your_key"),
    option.WithBaseURL("https://api.streamvc.live/v1"),
)
completion, err := client.Chat.Completions.New(ctx, openai.ChatCompletionNewParams{
    Model: "mlx-community/Llama-3.2-3B-Instruct-4bit",
    Messages: []openai.ChatCompletionMessageParamUnion{
        openai.UserMessage("Say hello"),
    },
    MaxTokens: openai.Int(64),
})
```

## Models

Use `/v1/models` with bearer auth for the current model list. The live pool has recently served:

| Model | Notes |
|---|---|
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | Small, fast local MLX model |
| `mlx-community/Qwen2.5-7B-Instruct-4bit` | Larger local MLX model |

## API reference

Primary buyer endpoints:

| Method | Path | Auth |
|---|---|---|
| `POST` | `/v1/chat/completions` | Bearer API key or browser demo token |
| `GET` | `/v1/models` | Bearer API key or demo token |
| `GET` | `/v1/status` | Public |
| `GET` | `/v1/usage` | Bearer API key |

## Quotas and limits

- Free beta accounts: 100,000 tokens/account/day.
- Request limit: 4096 tokens/request.
- Account concurrency: 2 concurrent requests/account.
- Demo mode: 1000 tokens/IP/day, 512 tokens/request, 10 sessions/IP/hour.

## Streaming vs non-streaming

Both streaming and non-streaming chat completions are supported. Non-streaming requests have a 120s operational upper bound. Streaming chunks can take up to 120s end-to-end.

## Disclosures

### Tier 1 disclosure

1. **Buyer prompts and provider responses are processed as plaintext on provider hardware.** Providers can technically observe prompts and outputs that route through their machine. This is acceptable for cooperative deployments where buyer and provider have an established trust relationship; it is NOT a private-inference guarantee.
2. **There is no hardware attestation or runtime integrity check on providers.** The coordinator admits providers based on `provider_id` match (pinned tier) or rate-limited provisional admission. Once admitted, the provider runtime is trusted to faithfully serve requests; SPEC-006 v0.6 does NOT cryptographically verify this.
3. **Model identity is provider-reported.** When `/v1/models` aggregates the pool's served models, the model identifier reflects what the provider's binary advertises. SPEC-006 v0.6 does NOT cryptographically verify the loaded model against a catalog of known artifact hashes.
4. **The product makes NO privacy, attestation, integrity, untrusted-provider, or malicious-provider claims.** Any buyer-facing language, including front-door copy, docs, error messages, API responses, marketing material, and this spec, MUST be consistent with properties 1-3.

What this means for your prompts and outputs: use Mac Provider for cooperative beta workloads where local-provider plaintext processing is acceptable. Do not send secrets or regulated data that require private inference, attestation, or malicious-provider resistance.

Tier 2 roadmap: future.

## Status and reliability

Check `/v1/status` for current pool status, model availability, and aggregate provider capacity. Known limitations: provider availability can change as Macs sleep, wake, or disconnect from the network.

Found a bug? Contact the operator through the project channel where you received access.

## Errors

Errors use the OpenAI envelope shape:

```json
{
  "error": {
    "message": "Missing bearer token",
    "type": "authentication_error",
    "code": "missing_bearer_token"
  }
}
```

Common codes:

| Code | Meaning |
|---|---|
| `missing_bearer_token` | Add `Authorization: Bearer mp_...` |
| `invalid_demo_token` | Refresh the browser demo session |
| `quota_exhausted` | Daily or request quota is exhausted |
| `coordinator_unavailable` | The provider pool is temporarily unavailable |
| `not_found` | The requested route does not exist |
