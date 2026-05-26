# macprovider PoC — Vercel deploy

Single-page chat UI + edge-function proxy that forwards prompts to the
M1 / M4 Macs through their existing Cloudflare tunnels. Same backend the
harness uses; no new endpoints required on the provider side.

## Files

- `index.html` — chat UI + receipt panel
- `api/chat.js` — Vercel Edge function, streams SSE from the chosen provider
- `api/providers.js` — returns the provider config (tunnel + model)
- `vercel.json` — disables edge caching / proxy buffering on the streaming route

## One-time setup

```
npm i -g vercel        # if you don't have the CLI
cd beta/web
vercel login
```

## Deploy

Preview deploy (gets you a unique URL to share):

```
cd beta/web
vercel
```

Promote to production (gets you the project's stable URL):

```
vercel --prod
```

The CLI prints the URL — that's what you send to the M4 contributor.

## Verifying it works

After deploy, open the URL and:

1. Pick **M1** in the dropdown → send "ping". Tokens should stream in.
   The receipt panel should show `tunnel: m1.streamvc.live`,
   `model: …llama-3.2-3b…`, a TTFT, and a tok/s.
2. Flip to **M4** → send the same prompt. Tunnel should flip to
   `m4.streamvc.live`, model to `…Qwen2.5-7B…`, and tok/s should change
   noticeably (different hardware + different model).

The side-by-side behavior difference is the proof that two physically
different Macs really answered.

## Limits worth knowing

- **Edge function timeout:** ~25–60s depending on Vercel plan. Responses
  are capped at 384 tokens to stay well inside that.
- **Public URL:** anyone with the link can spend M1/M4 compute. Fine for
  sharing with a handful of trusted reviewers; don't post it publicly.
- **No signed receipts yet:** attestation is the tunnel hostname only.
  Cryptographically-signed receipts land in Phase 3.

## If a request errors

- `502 upstream error` → that provider's tunnel/mlx_lm.server is down.
  Check `cloudflared` status on the corresponding Mac.
- `400 unknown provider` → client sent something other than `m1`/`m4`.
- Hangs with no tokens → upstream is up but the model is loading or busy.
  TTFT for a cold model can be 5–15s.
