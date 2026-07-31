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

Use `/v1/models` with bearer auth for the current model list. Model identity is provider-reported. `/v1/models` distinguishes provider-reported model IDs, catalog-known hash status, and settlement-enforced receipt matching. Settlement enforcement applies only to included paid entrypoints in enforce mode after a receipt matches the route-time catalog snapshot; excluded legacy/direct paths are named separately. Mixed pools are not described as fully verified.

v0.4 settlement receipts verify the provider-reported request-start model hash against the route-time catalog snapshot. They do not detect a provider falsifying its own loaded-model hash measurement.

The live pool has recently served:

| Model | Notes |
|---|---|
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | Small, fast local MLX model |
| `mlx-community/Qwen2.5-7B-Instruct-4bit` | Larger local MLX model |

## API reference

Primary buyer endpoints:

| Method | Path | Auth |
|---|---|---|
| `POST` | `/v1/chat/completions` | Bearer API key or browser demo token |
| `POST` | `/v1/responses` | Bearer API key or browser demo token; available when the Responses compatibility flag is enabled |
| `GET` | `/v1/models` | Bearer API key or demo token |
| `GET` | `/v1/status` | Public |
| `GET` | `/v1/usage` | Bearer API key |
| `POST` | `/v1/feedback` | Bearer API key or demo token |

### Chat completions

`POST /v1/chat/completions` accepts OpenAI-compatible chat completion requests. Set `stream:true` for server-sent events or omit it for a single JSON response.

Text-only structured `messages[].content` arrays are accepted for `system` and
`user` messages and normalized to plain text before provider dispatch.
Multimodal parts such as `image_url` are not supported in v1 and return
`unsupported_content_shape`.

Covered paid settlement claims are limited to `POST /v1/chat/completions`, plus `POST /v1/responses` when the Responses compatibility flag is enabled. Buyer cancel, gateway timeout, provider error, or upstream disconnect can create a partial charge only when a settlement-capable receipt binds the delivered output prefix and partial usage.

### Responses API

`POST /v1/responses` is a stateless OpenAI Responses compatibility facade over the same billed chat-completions pipeline. Send the full `input` on every request with `store:false`. Function tools and `text.format` structured output are translated into the chat pipeline. `include`, `reasoning` summary controls, and `parallel_tool_calls` are tolerated; unsupported hosted or unknown tools are dropped before provider dispatch. `previous_response_id`, `store:true`, `conversation`, `background:true`, non-disabled `truncation`, `response_format`, and multimodal input are not supported.

When the Responses compatibility flag is enabled, covered paid settlement claims include `POST /v1/responses` and `POST /v1/chat/completions`.

Excluded legacy/direct paths are outside this SPEC-022 gateway settlement claim unless separately disabled or migrated behind the gateway paid ledger: `coordinator.streamvc.live`, `m4.streamvc.live`, and `m1.streamvc.live`.

Transparent streaming failover bills only delivered, verified output across attempts and does not double-charge overlapping output; verified here means receipt-bound under the provider-reported-hash caveat above.

### Models

`GET /v1/models` returns the current provider-reported model list plus `tier1_disclosure`. The disclosure separates provider-reported model IDs, catalog-known hash status, and settlement-enforced receipt matching.

### Usage

`GET /v1/usage` returns account quota, key, model, rating summary, and `settlement_disclosure` fields for signed-in API-key users. `daily_tokens_reserved` can include pending verification reservations after a request completes; non-verified terminal outcomes release or refund that reservation.

Buyer receipt and status labels:

| Label | Meaning |
|---|---|
| `pending` | receipt verification is still incomplete and the reservation is not final usage |
| `verified` | a settlement-capable receipt matched the route-time catalog snapshot and can finalize buyer debit and provider settlement |
| `quarantined` | not charged because model-integrity or receipt verification failed; this is not labeled as buyer fault |
| `zero_settled` | not charged because no billable verified work was produced; this is not labeled as buyer fault |

Buyer receipt and status surfaces expose pending, verified, quarantined, and zero_settled labels without raw prompts or raw outputs.

### Feedback

`POST /v1/feedback` records a request rating for operator review.

## Quotas and limits

- Free accounts: 100,000 tokens/account/day.
- Request limit: 4096 tokens/request.
- Account concurrency: 2 concurrent requests/account.
- Demo mode: 1000 tokens/IP/day, 512 tokens/request, 10 sessions/IP/hour.

## Streaming vs non-streaming

Both streaming and non-streaming chat completions are supported. Request timeouts are deployment-configured and enforced by the gateway/coordinator path rather than promised as a fixed product SLA.

## Disclosures

### Tier 1 disclosure

1. **Buyer prompts and provider responses are processed as plaintext on provider hardware.** Providers can technically observe prompts and outputs that route through their machine. This is acceptable for cooperative deployments where buyer and provider have an established trust relationship; it is NOT a private-inference guarantee.
2. **There is no hardware attestation or runtime integrity check on providers.** The coordinator admits providers based on `provider_id` match (pinned tier) or rate-limited provisional admission. Once admitted, the provider runtime is trusted to faithfully serve requests; SPEC-006 v0.8 does NOT cryptographically verify this.
3. **Model identity is provider-reported.** `/v1/models` distinguishes provider-reported model IDs, catalog-known hash status, and settlement-enforced receipt matching. Settlement enforcement applies only to included paid entrypoints in enforce mode after a receipt matches the route-time catalog snapshot; excluded legacy/direct paths are named separately. Mixed pools are not described as fully verified.
4. v0.4 settlement receipts verify the provider-reported request-start model hash against the route-time catalog snapshot. They do not detect a provider falsifying its own loaded-model hash measurement.
5. Observe mode may record receipt and model-hash diagnostics, but it cannot claim verified model integrity and it does not change buyer debit or provider payout. Enforce mode may settle only covered paid POST /v1/chat/completions attempts whose settlement-capable receipt reaches verified finality; mixed pools are not described as fully verified.
6. Pending means quota or balance can remain reserved while receipt verification is incomplete. Non-verified terminal outcomes release or refund that reservation. pending: receipt verification is still incomplete and the reservation is not final usage. verified: a settlement-capable receipt matched the route-time catalog snapshot and can finalize buyer debit and provider settlement. quarantined: not charged because model-integrity or receipt verification failed; this is not labeled as buyer fault. zero_settled: not charged because no billable verified work was produced; this is not labeled as buyer fault.
7. Buyer cancel, gateway timeout, provider error, or upstream disconnect can create a partial charge only when a settlement-capable receipt binds the delivered output prefix and partial usage. Transparent streaming failover bills only delivered, verified output across attempts and does not double-charge overlapping output; verified here means receipt-bound under the provider-reported-hash caveat above.
8. Buyer receipt and status surfaces expose pending, verified, quarantined, and zero_settled labels without raw prompts or raw outputs.
9. **The product makes NO private-inference, hardware-attestation, runtime-binary-attestation, provider-private-prompt, untrusted-provider, malicious-output-prevention, or provider-falsified-model-measurement detection claims.** Any buyer-facing language, including front-door copy, docs, error messages, API responses, marketing material, and this spec, MUST be consistent with these limitations.

What this means for your prompts and outputs: use Mac Provider for cooperative workloads where local-provider plaintext processing is acceptable. Do not send secrets or regulated data that require private inference, attestation, or malicious-provider resistance.

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
| `unsupported_content_shape` | Use string content; `system` and `user` messages may also use text-only structured content arrays. Multimodal parts are not supported in v1 |
| `coordinator_unavailable` | The provider pool is temporarily unavailable |
| `not_found` | The requested route does not exist |
