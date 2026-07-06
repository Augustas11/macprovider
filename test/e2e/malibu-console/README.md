# Malibu Console E2E smoke

Mirrors the buyer paths used by `malibu.tech/console` (`console/api.js`):

- `GET /v1/status` — pool dot / model availability
- `POST /v1/chat/completions` — streaming chat with sticky `X-MacProvider-Conversation`

## Run against production API

```bash
export MALIBU_API_KEY=mp_your_key
export MALIBU_MODEL=qwen3-coder-30b-a3b-instruct   # optional
node test/e2e/malibu-console/smoke.mjs
```

Demo quota (no key):

```bash
MALIBU_ALLOW_DEMO=1 node test/e2e/malibu-console/smoke.mjs
```

## What to watch

| Signal | Healthy | Investigate |
|--------|---------|-------------|
| turn1 latency | usually < 10s | > 30s with small prompt |
| turn2 `cached_prompt_tokens` | > 0 when sticky works | 0 on multi-turn |
| turn2 502 | should not happen after gateway retry | provider WS flap / single-node pool |
| Malibu app "Sync" | brief during reconnect | stuck > 60s |

Provider-side: `~/Library/Logs/macprovider/macprovider.out.log` for `coordinator reconnect failed`.
