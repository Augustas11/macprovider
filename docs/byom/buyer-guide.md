# Call a private pool: buyer guide

A private Trusted Pool serves a model that its creator chose and priced. Only
buyer accounts the creator authorizes can reach it. This guide covers what
you need to call one.

Base URL: `https://api.malibu.tech/v1`. If you run the pool yourself, see the
[creator guide](creator-guide.md).

Buyers need no invite code: a Malibu API key is enough. Invite codes are only
for adding provider Macs, which the creator guide covers.

## 1. Get your account id

Use a normal Malibu API key (sign in at
<https://api.malibu.tech/auth/github/start>):

```bash
curl -s https://api.malibu.tech/v1/usage -H "Authorization: Bearer $MALIBU_API_KEY"
```

The response has a top-level `account_id`. Send it to the pool creator. The
creator authorizes the account (`macprovider-cli creator authorize-buyer
<account-id> --pool <pool-id>`), so every API key on that account can then
select the pool.

Only API-key credentials can select a pool. Wallet sessions and demo tokens
cannot, and are refused as `pool_unavailable`.

The creator tells you two things: the `<pool-id>` and the model `<slug>`.

## 2. List the pool's models

```bash
curl -s https://api.malibu.tech/v1/models \
  -H "Authorization: Bearer $MALIBU_API_KEY" \
  -H "X-MacProvider-Pool-Select: <pool-id>"
```

A pool-only model never appears in the global `/v1/models` list. Without the
header, or with another pool's id, the model does not exist for you
(`404 model_not_found`).

## 3. Send a request

```bash
curl -s https://api.malibu.tech/v1/chat/completions \
  -H "Authorization: Bearer $MALIBU_API_KEY" \
  -H "Content-Type: application/json" \
  -H "X-MacProvider-Pool-Select: <pool-id>" \
  -d '{"model":"pool/<pool-id>/<slug>","messages":[{"role":"user","content":"hi"}]}'
```

With the OpenAI SDK, pass the header as a default header:

```python
from openai import OpenAI
client = OpenAI(base_url="https://api.malibu.tech/v1", api_key=KEY,
                default_headers={"X-MacProvider-Pool-Select": "<pool-id>"})
client.chat.completions.create(model="pool/<pool-id>/<slug>", messages=[...])
```

The pool header is a header only. Do not put pool information in the request
body.

### Optional: choose the engine

If the pool's members run more than one inference engine, add
`X-MacProvider-Engine-Select` with one of `native`, `llamacpp`, `lmstudio`,
`mlxlm`, `ollama`, `omlx`. Leave it out for native MLX pools. Any engine other
than `native` works only together with `X-MacProvider-Pool-Select`. See
[Choosing an inference engine](../using-macprovider-with-openai-sdk.md#choosing-an-inference-engine).

## 4. Read the disclosure

Pool models are attested by the pool creator, not verified by the network.
Every response says so:

| Response header | Meaning |
|---|---|
| `X-MacProvider-Model-Disclosure: pool_attested_unverified` | The model's identity is the creator's claim |
| `X-MacProvider-Pool-Manifest-Core-Digest` | SHA-256 of the signed pool policy that authorized the route |
| `X-MacProvider-Engine` | Engine that served the request: `mlx_cache`, `llamacpp_loopback`, `lmstudio_loopback`, `mlxlm_loopback`, `ollama_loopback`, `omlx_loopback` |
| `X-MacProvider-Receipt` | Signed receipt for the request |

Prompts and responses are visible to the Malibu coordinator, and the operator
of the provider Mac that serves your request may access request content. Do
not send data you would not give both.

Price is the per-model rate the creator signed (prompt, cached prompt,
completion per million tokens), under the standard formula and platform fee.

## Errors

Pool refusals are deliberately non-specific so that private pools cannot be
enumerated.

| Status and code | Meaning |
|---|---|
| `503 pool_unavailable` | Not authorized, unknown pool, pool not active, not enabled, or you used a wallet session. Not retryable; it does not say which |
| `400 pool_selection_invalid` | `X-MacProvider-Pool-Select` sent more than once with different values |
| `400 invalid_engine_selection` | Unknown engine value |
| `503 engine_unavailable` | The engine is not allowed by the pool, or no member serves it now. Also returned for a non-native engine without a pool header |
| `404 model_not_found` | Model id wrong, or you did not select the pool |
| `503 model_not_loaded` | The provider's engine stopped listing the bound model; the creator must restart it |
| `503 pool_model_requires_gateway_upgrade` | Transient during a network rollout; no charge |

If you always get `pool_unavailable`, check with the creator that your
account id (not the API key) is authorized and the pool is active.
