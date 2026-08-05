<p align="center">
  <img src="doc/assets/banner.svg" alt="MacProvider — pooled Apple Silicon inference" width="720" />
</p>

<p align="center">
  <a href="https://console.streamvc.live"><strong>Console</strong></a> &middot;
  <a href="#for-providers"><strong>Join as Provider</strong></a> &middot;
  <a href="#for-buyers"><strong>API Access</strong></a> &middot;
  <a href="https://github.com/augustas11/macprovider/releases"><strong>Releases</strong></a>
</p>

<p align="center">
  <img src="https://img.shields.io/github/v/release/augustas11/macprovider?style=flat" alt="Latest release" />
  <img src="https://img.shields.io/badge/platform-Apple%20Silicon-000000?style=flat&logo=apple&logoColor=white" alt="Platform" />
  <img src="https://img.shields.io/badge/runtime-MLX%20%7C%20macOS%2014%2B-5a5a5a?style=flat" alt="Runtime" />
</p>

<br/>

# MacProvider

**Make any Apple Silicon Mac a remote-addressable MLX inference endpoint.** Built on `mlx-lm`. OpenAI-compatible API — streaming, multi-turn tool calling, JSON-schema structured output, sticky conversations with KV-cache reuse. Every response carries a signed receipt binding the prompt, output, provider key, catalog-resolved model hash, and timestamp; the open-source [macprovider-verify](phase7-verify/README.md) CLI verifies that a provider signing key signed that tuple. The receipt does not prove model honesty, hardware attestation, or detection of a provider falsifying its own model-hash measurement.

A lot of the most interesting LLM applications — long-running personal agents, privacy-sensitive tooling, dev workflows that hammer a model thousands of times a day — don't really belong in a cloud datacenter. But the moment you want your Mac's MLX endpoint to be reachable from somewhere that isn't localhost, you fall off a cliff: auth, tunneling, multi-tenant routing, billing, observability, none of it exists out of the box. MacProvider is a thin layer over `mlx-lm` that fills that gap.

| For Providers | For Buyers |
|---|---|
| Run MLX models locally on any M1+ Mac | OpenAI-compatible `/v1/chat/completions` endpoint |
| Outbound WebSocket only — no port-forwarding needed | Route to the full pool or pin to a specific provider |
| Choose which models to serve from your Mac | Pay only for compute, no subscription required |
| Manage your provider at [portal.streamvc.live](https://portal.streamvc.live) | Chat and monitor at [console.streamvc.live](https://console.streamvc.live) |

## Console

**[console.streamvc.live](https://console.streamvc.live)** is the buyer-facing front end. Today it ships two views:

- **Browser chat.** Send requests to the network directly from the browser, with session history.
- **Pool dashboard.** Monitor live provider pool status and which models are warm.

**[portal.streamvc.live](https://portal.streamvc.live)** is the provider-facing front end. Sign in with your `provider_id` + `provider_token` to see your Mac's setup, earnings, identity, and the latest installer release. See [SPEC-014](specs/SPEC-014-provider-portal.md) for the surface contract.

## Architecture

```
Provider Mac (MLX)
  └── outbound WS ──▶ MacProvider
                      (pool · routing · billing)
                             │
               ┌─────────────┴─────────────┐
               │                           │
    api.streamvc.live/v1          console.streamvc.live
    (OpenAI-compatible)               (web front end)
```

New public installs join as **provisional providers** over outbound WebSocket tunneling and can be promoted to pinned by the operator after observation. No inbound port-forwarding is required on the provider Mac.

For production public onboarding, the coordinator must run with both token gates set explicitly:

```yaml
auth:
  require_provider_tokens: true
  allow_tokenless_provisional_bootstrap: true
```

`require_provider_tokens` keeps normal provider reconnects fail-closed. `allow_tokenless_provisional_bootstrap` only admits the first tokenless provisional connect far enough to mint and persist its own `provider_token`; pinned providers and provider IDs whose active token has already been used still reject tokenless reconnects. Invite-only deployments can set the bootstrap flag to `false`, but then new Macs need an operator-preprovisioned `provider_token`.

**Trust model — what the coordinator sees:** prompts and responses pass through the gateway to enable routing and billing. Model weights stay on the provider Mac and never leave. Buyer prompts and provider responses are processed as plaintext on provider hardware — providers can technically observe prompts and outputs that route through their machine. This is acceptable for cooperative deployments where buyer and provider have an established trust relationship; it is NOT a private-inference guarantee. A self-hosted coordinator is on the roadmap for buyers who need local-only trust.

## For Providers

Run on any Apple Silicon Mac (M1 or newer, macOS 14+):

```bash
curl -fsSL https://get.streamvc.live/install.sh | bash
```

The installer:

- Picks a recommended MLX model by running the SPEC-023 `autotune-recommend` flow against a signed static feed of demand rank + candidate models. Eligibility is gated by RAM headroom (catalog `min_ram_gb` vs Mac RAM minus a 4 GB safety margin), bandwidth tier, and a local benchmark probe; scoring ranks eligible rows by `demand_weight × completion_rate_per_mtok × sustained_tps` using live `/v1/rate-card` per-token rates (you can override)
- Asks for a stable provider handle used as your pool identity
- Downloads and verifies the latest `macprovider-cli` release against a signed checksum manifest
- Installs under `~/macprovider` and sets up a user-level launchd service
- Runs a local `/v1/models` check and a coordinator pool visibility check
- Enrolls the provider in autoupdate (SPEC-020): once the coordinator advertises a newer `recommended_binary_version`, the provider validates the signed release, drains in-flight traffic, and swaps itself in place

Normal recovery for an already-installed provider:

```bash
macprovider-cli update
macprovider-cli --version
macprovider-cli status
```

If the installed CLI is still public **1.8.48** and cannot reach the coordinator, re-run the signed installer upgrade-in-place (see `ops/runbooks/entry-610-first-hop-recovery.md`).

**Security note:** `curl | bash` gives the downloaded script control of your user account. Inspect first if you prefer:

```bash
curl -fsSL https://get.streamvc.live/install.sh -o install.sh
less install.sh
bash install.sh
```

The binary is checksum-verified against a signed release manifest. macOS quarantine (`xattr`) is cleared with your approval during install. Developer ID signing and notarization are planned for a future release.

## For Buyers

Base URL: `https://api.streamvc.live`

The API is OpenAI-compatible — swap in your existing client:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.streamvc.live/v1",
    api_key="<your-api-key>",
)

response = client.chat.completions.create(
    model="mlx-community/Llama-3.2-3B-Instruct-4bit",
    messages=[{"role": "user", "content": "Hello"}],
)
print(response.choices[0].message.content)
```

Get an API key → [api.streamvc.live/auth/github/start](https://api.streamvc.live/auth/github/start)  
API reference → [api.streamvc.live/docs#api-reference](https://api.streamvc.live/docs#api-reference)  
Cookbook (tool calling, structured output, sticky conversations, receipt verification) → [docs/using-macprovider-with-openai-sdk.md](docs/using-macprovider-with-openai-sdk.md)

### What the OpenAI-shape surface covers

- **Streaming** (`stream: true`) with token-incremental deltas.
- **Tool calling** (SPEC-018) — multi-turn agent loops for Qwen and Llama 3.3 tool-call templates. First-turn `tool_calls[]` emission plus second-turn `role: "tool"` acceptance and assistant-history rendering. Anchor framework: [Cline](https://github.com/cline/cline). Caps: 1 MiB per `function.arguments`, 2 MiB per response, 256 KiB per `role: "tool"` message.
- **Structured output** (SPEC-019, LOCKED) — `response_format: {"type": "json_schema", "json_schema": {...}}` with OpenAI strict-mode subset, and a bundled fix that makes `json_object` actually enforce top-level JSON.
- **Sticky conversations + KV-cache reuse** (SPEC-024) — pass a stable `conversation_id`; the coordinator routes back to the same provider and reports `cached_prompt_tokens` in the OpenAI `usage` object. Prefix-cache billing is metered separately.

See [docs/using-macprovider-with-openai-sdk.md](docs/using-macprovider-with-openai-sdk.md) for worked examples.

### Security model: buyer-side validation obligation

For tool-calling responses, emitted `tool_calls[]` reflect model output, not provider-verified intent; buyer-side agent frameworks MUST validate before execution. MacProvider transports the parsed OpenAI-compatible shape; it does not decide whether a requested tool name or argument payload is safe for your agent policy. Treat emitted tool calls with the same trust posture you would apply to a model running on local hardware: parsed output, not provider-verified intent.

## Releases

Latest release and signed binaries: [github.com/augustas11/macprovider/releases](https://github.com/augustas11/macprovider/releases) (badge above auto-updates).

## Shipped

- **Signed inference receipts (SPEC-015).** Every response carries a v0.3 nine-field receipt tuple (`model_hash`, `model_id`, `output_hash`, `prompt_hash`, `provider_pubkey`, `receipt_version`, `tokens_out`, `ttft_ms`, `unix_ts`) signed with the provider's Ed25519 receipt key. Verify with the open-source [macprovider-verify](phase7-verify/README.md) CLI; back-compat with legacy v0.1/v0.2 receipts is preserved. Streaming responses now emit a settlement-capable receipt as well.
- **Verified model settlement (SPEC-022).** Coordinator receipt verdicts drive gateway buyer debit/refund decisions on the money path. Missing / malformed / unverifiable receipts settle as `FaultBreakerQualifying` with zero provider-positive credits.
- **Multi-turn OpenAI tool calling (SPEC-018).** First-turn emission plus second-turn `role: "tool"` acceptance and assistant-history rendering for Qwen and Llama 3.3 templates. Cline drop-in works.
- **Structured output (SPEC-019, LOCKED).** `response_format: json_schema` with OpenAI strict-mode subset; post-hoc validate-and-fault.
- **Prefix-cache reuse + billing (SPEC-024).** Sticky `conversation_id` routing, `cached_prompt_tokens` in `usage`, prefix-cache metering.
- **Provider autoupdate (SPEC-020).** Coordinator advertises `recommended_binary_version`; providers auto-drain, verify the signed release, and swap in place.
- **Installer-integrated autotune-recommend (SPEC-023 v0.4 LOCKED).** Signed static demand-rank + candidate-catalog feeds off Pearl nginx; RAM/benchmark eligibility gates at install time; per-token payout transcript (recommended model or donor-only fallback — no hourly projection or starter tier).
- **Provider payout pipeline (SPEC-016).** USDC payout design on Base, gated on the operator hot-wallet prerequisites in §9; converged after 20 codex audit rounds.

## In flight

## OpenRouter pricing proposal engine

`scripts/openrouter_pricing_engine.py` is a standalone, non-money-path tool
that fetches OpenRouter demand and per-model endpoint pricing, writes a
validated snapshot, and computes a reviewable pricing proposal. It has no
apply mode and never modifies `phase3-binary/catalog/autotune/rate-card.json`.

Create a live snapshot in an operator-owned directory, then compute a proposal
against the read-only rate-card reference:

```bash
python3 scripts/openrouter_pricing_engine.py fetch --output-dir /var/tmp/openrouter-pricing
python3 scripts/openrouter_pricing_engine.py compute \
  --snapshot /var/tmp/openrouter-pricing/openrouter-pricing-snapshot-<timestamp>.json \
  --rate-card phase3-binary/catalog/autotune/rate-card.json \
  --output-dir /var/tmp/openrouter-pricing
```

The fetch command uses an explicitly unstable, undocumented frontend rankings
endpoint for demand, plus the documented model catalog and each selected model's
documented endpoints response. If the rankings dependency changes, fetch fails
closed without a snapshot; operators must review and update the adapter rather
than infer a fallback. Production proposals require a complete
top-100 snapshot; `--top-n` below 100 is useful only for fetch-only diagnostics.
It retries transient errors with bounded backoff, honors `Retry-After` for
429s, and fails closed without writing a snapshot on a timeout, schema change,
empty result, invalid price, or partial pull. Commands are noninteractive and
suitable for an external scheduler.

Snapshots contain `schema_version`, `fetched_at`, a reproducible
`content_digest`, endpoint/schema provenance, and normalized demand/pricing
rows. Proposals contain their source snapshot digest, policy version,
rate-card reference digest, and `added`, `changed`, `dropped`, `blocked`, and
`unchanged` rows with reasons. See
[`docs/runbooks/openrouter-pricing-engine.md`](docs/runbooks/openrouter-pricing-engine.md)
for the schemas, policy evidence, and offline test procedure.

- **Native Mac app (SPEC-025, "Malibu").** Signed `.dmg` + menu-bar wrapper around `macprovider-cli` — non-developer-facing brand and installer path. P0 skeleton shipped.
- **Browserless one-click provider onboarding (SPEC-026 draft).** Deep-link launch flow so new providers can join without a terminal.
- **Self-hosted coordinator.** For buyers who need local-only trust; see the trust-model note above.
