# Run a private pool: creator guide

This guide takes an outside creator from a fresh Mac to a private Trusted
Pool that serves your own model and earns credits, using only public
surfaces. You sign everything on your own Mac. Your keys never leave it.

Normative source: SPEC-043 0.3.0 (self-serve private pools) and SPEC-042
(pool entries). A private pool is reachable only by buyer accounts you
authorize. Public listing is operator-only and is not part of this guide.

Buyers call your pool as described in the [buyer guide](buyer-guide.md).

## What you need

- Apple Silicon Mac, macOS 14 or later, for each provider Mac.
- A GitHub account. The Mac is claimed to it.
- A Malibu account API key (sign in at
  <https://api.malibu.tech/auth/github/start>). Use the same GitHub user for
  the claim and the key.
- A model you are licensed to serve commercially.

You run two roles, usually on the same Mac:

| Role | Command | What it does |
|---|---|---|
| Provider | `macprovider-cli serve`, `models ...` | Serves the model and earns credits |
| Creator | `macprovider-cli creator ...` | Owns the pool: signs its policy, admits Macs, authorizes buyers |

## 1. Install and claim the Mac

```bash
curl -fsSL https://get.malibu.tech/install.sh | bash
macprovider-cli claim
```

`claim` opens <https://portal.malibu.tech/claim>, where you sign in with
GitHub. Pass `--no-browser` to print the URL instead of opening it. The Mac
must already have a provider token from the install.

`creator admit` (step 5) only sees Macs claimed by the GitHub user tied to
your creator API key. A Mac claimed by anyone else cannot be admitted to your
pool, and delegated membership is not available to self-serve pools.

List the Macs you have claimed and their provider ids:

```bash
macprovider-cli creator providers
```

## 2. Create the pool

```bash
printf '%s' "$MALIBU_API_KEY" | macprovider-cli creator login --api-key-stdin
# first run prints the Agreement and accepts nothing; read it
macprovider-cli creator agree --display-name "My Pool" \
  --legal-contact you@example.com --billing-contact you@example.com \
  --emergency-endpoint mailto:you@example.com
# same command with --yes accepts it
macprovider-cli creator agree --display-name "My Pool" \
  --legal-contact you@example.com --billing-contact you@example.com \
  --emergency-endpoint mailto:you@example.com --yes
macprovider-cli creator keygen
```

- `login` stores the key owner-only and defaults to the public gateway
  (`--gateway-url` overrides).
- `agree` without `--yes` prints the Creator Agreement and accepts nothing.
  Contact fields are limited to 256 bytes each.
- `keygen` prints `pool_id=<id>`. Use it as `<pool-id>` below. Keys are
  stored under `~/.config/macprovider/creator` (set
  `MACPROVIDER_CREATOR_HOME` to move them). Back this directory up: losing it
  loses control of the pool.

```bash
macprovider-cli creator pool create --pool <pool-id>
macprovider-cli creator register-root --pool <pool-id> --display-name "My Pool"
```

## 3. Provider: propose your model

On the Mac that serves it, with the engine running (see
[Engines](#engines)):

```bash
macprovider-cli models discover --json
macprovider-cli models propose <candidate> --pool <pool-id> --slug <slug> --json > proposal.json
```

`<candidate>` is an id, served model reference, or display name from
`discover`. `--slug` is lowercase `[a-z0-9][a-z0-9-]{0,62}`; the model id will
be `pool/<pool-id>/<slug>`. Optionally suggest prices with
`--prompt-rate-per-mtok`, `--prompt-cache-hit-rate-per-mtok` and
`--completion-rate-per-mtok` (all three or none; cache-hit not above prompt).
The proposal holds hashes and metadata only. A suggested price is never used
until you sign it.

If you are both creator and provider, you review your own proposal.

## 4. Creator: sign and submit the manifest

The quickest path signs straight from the proposal. `--from-proposal` keeps
the proposal's hash and runtime as they are and fills only your fields; it
can be repeated, one per proposal:

```bash
macprovider-cli creator manifest sign --pool <pool-id> --from-proposal proposal.json \
  --license Apache-2.0 --attest-paid-serving \
  --prompt-rate-per-mtok 20000 --prompt-cache-hit-rate-per-mtok 5000 \
  --completion-rate-per-mtok 40000 --max-context-tokens 16384
```

The rates are needed only when the proposal suggests none, and
`--max-context-tokens` only when it reports none. A proposal for another pool
is refused.

Alternatively, write `models.json` from the proposal's `model_entry`,
adding your fields:

```json
{"model_entries": [{
  "pool_model_id": "pool/<pool-id>/<slug>",
  "artifact_hash_algorithm": "macprovider.gguf-file.v1",
  "artifact_hash": "<64 hex from the proposal>",
  "allowed_runtime_sources": ["llamacpp_loopback"],
  "license": "Apache-2.0",
  "paid_serving_attested": true,
  "pricing": {"prompt_rate_per_mtok": 20000,
              "prompt_cache_hit_rate_per_mtok": 5000,
              "completion_rate_per_mtok": 40000},
  "disclosure_class": "pool_attested_unverified",
  "max_context_tokens": 16384}]}
```

- `license` is a pinned SPDX id or `LicenseRef-*`. It must permit paid
  serving, because `paid_serving_attested: true` is your claim. Do not use
  non-commercial licenses.
- `max_context_tokens` must not exceed what the engine is started with.
- Every manifest must carry the full current list of entries. An entry left
  out is removed.
- Do not propose a model already in the global catalog
  (`pool_model_entry_catalog_overlap`).

```bash
macprovider-cli creator manifest sign --pool <pool-id> --models-file models.json
macprovider-cli creator manifest submit --pool <pool-id>
```

`sign` works offline and prints `manifest_version`, `manifest_core_digest`,
`effective_from` and `expires_at`. Useful options: `--validity-days` (default 90),
`--settlement-mode` (default `enforce`; pool entries require it),
`--min-binary-version` (default `1.8.0`), `--min-eligible-members`
(default 1). Re-run `sign` and `submit` for each change; there is no
in-place edit.

> **Manifest timing.** A higher manifest version takes effect when you submit
> it; it does not wait for the previous version to expire.
> `creator status --pool <pool-id>` shows the accepted version's
> `effective_from` and `expires_at`.

`sign` reads the coordinator's pricing bounds (`creator status` and
`creator agree` show them too) and refuses a rate outside them before
signing, naming the bound, for example
`max_completion_rate_per_mtok=<limit>`. A submit refused for the same
reason names the entry and the bound.

## 5. Creator: admit, authorize, promote

```bash
macprovider-cli creator admit <provider-id> --pool <pool-id>
macprovider-cli creator authorize-buyer <buyer-account-id> --pool <pool-id>
macprovider-cli creator promote --pool <pool-id>
```

- `admit` takes a provider id from `creator providers`. The Mac must be
  connected. Remove a grant with `creator authorize-buyer ... --remove`.
- Buyers find their account id as in the [buyer guide](buyer-guide.md).
- `promote` runs the automated gate and activates the pool.

## 6. Provider: offer and serve

On each member Mac:

```bash
macprovider-cli models offer <candidate> --dry-run --json   # review
macprovider-cli models offer <candidate> --yes --json
macprovider-cli models admission status <candidate> --json
```

Use the same discovery flags as in `propose` (for example
`--llamacpp-origin` and `--llamacpp-model-path`). `status` should show
`binding_scope: pool` and your `pool_model_id`. To withdraw an offer, use
`models admission withdraw`. An offer answered `409 replay_conflict` means a
different offer for that candidate is already recorded: withdraw it, then
offer again.

Then set the pool model id in the provider config
(`~/.config/macprovider/config.yaml`) and restart:

```yaml
pool_model_id: pool/<pool-id>/<slug>
```

(`MACPROVIDER_POOL_MODEL_ID` also works.) Restart the provider so its next
hello binds to the pool:

```bash
macprovider-cli restart
```

`restart` restarts the installed provider service and waits for the new
serve process.

An uncatalogued pool model becomes routable only after the Mac is a member,
the pool is active, and the Mac has restarted after both.

## 7. Revoke, pause, drain, retire

```bash
macprovider-cli creator revoke --pool <pool-id> --provider <provider-id>
macprovider-cli creator revoke --pool <pool-id> --model pool/<pool-id>/<slug>
macprovider-cli creator lifecycle --pool <pool-id> --set paused|draining|retired [--reason "..."]
```

- `revoke --provider` removes a member Mac from the pool's routes.
- `revoke --model` signs the next manifest version without that entry,
  keeping every other entry and setting, and leaves it pending. Run
  `creator manifest submit --pool <pool-id>` to apply it. It takes effect
  at submit. A pool's only model cannot be revoked; retire the pool
  instead.
- `lifecycle` pauses, drains or retires the pool. Retired is final. A paused
  or draining pool returns to active with `creator promote`.

## 8. Check status and earnings

```bash
macprovider-cli creator status --pool <pool-id>
macprovider-cli creator earnings --pool <pool-id> [--from YYYY-MM-DD --to YYYY-MM-DD]
```

`earnings` shows payable provider credits earned by your Macs on your pool.
`--from` is inclusive, `--to` is exclusive, UTC, at most 31 days apart.
Declared revenue splits are not executed (`split_execution_status:
declared_not_executed`); you see provider earnings, not creator revenue.

## Engines

A pool serves its model through exactly one engine per Mac. Native MLX needs
nothing extra. Every other engine runs on a loopback address and earns only
inside a pool. For each, the manifest's `allowed_runtime_sources` entry and
the pool's runtime allowlist must name it. Full detail:
[trusted-pool-external-engines.md](../runbooks/trusted-pool-external-engines.md).

| Engine | Model reference | `allowed_runtime_sources` | What it needs |
|---|---|---|---|
| Native MLX | Hugging Face snapshot | `mlx_cache` | The snapshot in the Hugging Face cache or the model store `serve` uses (`--mlx-cache-dir` to inspect only another cache) |
| llama.cpp | `llamacpp:<file stem>` | `llamacpp_loopback` | `llama-server --jinja`, and `--llamacpp-model-path` pinning the one GGUF file |
| Ollama | `ollama:<tag>` | `ollama_loopback` | A pulled tag; `OLLAMA_MODELS` if not `~/.ollama/models` |
| LM Studio | `lmstudio:<model key or identifier>` | `lmstudio_loopback` | LM Studio 0.4+ with the model loaded; several quantizations resolve to the loaded one |
| `mlx_lm.server` | `mlxlm:<snapshot dir>` | `mlxlm_loopback` | Started with a local snapshot path (`--model <path>`, port 8081); auto-detected, or set `MACPROVIDER_MLXLM_MODEL_PATH` |
| oMLX | `omlx:<snapshot dir>` | `omlx_loopback` | `MACPROVIDER_OMLX_MODEL_PATH`; no API key on the server |

Notes:

- `loopback_origin` in the config (or `MACPROVIDER_LOOPBACK_ORIGIN`) points
  the CLI at the engine and must be a loopback address. Malibu's own serve
  port and the llama.cpp and `mlx_lm.server` default (8080) clash; use
  another port for one of them.
- Evidence status differs. Native MLX and llama.cpp have had paid pool
  requests settled in production. Ollama has served pool requests with valid
  receipts; LM Studio, `mlx_lm.server` and oMLX are supported but have no
  production paid proof yet.
- Usage from external engines is reported by your own Mac and recorded as
  `pool_operator_attested`. This is administrative trust, and buyers are told
  so.
- Switching a Mac to another engine is a new offer and a restart.

## Limits

Per creator account (SPEC-043 0.3.0, enforced by the coordinator):

| Limit | Value | Error |
|---|---|---|
| Requests to the creator API | 600 per hour | `429 rate_limited` with `Retry-After` |
| Mutating requests | 60 per hour | `429 rate_limited` |
| Pools per account, lifetime | 8 | `409 self_serve_limit_reached` (`pools_per_creator`) |
| Self-serve pools, network-wide | 256 | `409 self_serve_limit_reached` (`self_serve_pools`) |
| Events in one pool (history cap) | 512 | `409 self_serve_limit_reached` (`events_per_pool`) |
| Earnings query range | 31 days | rejected |
| Creator Agreement term | 365 days, 30-day grace | see below |

Every manifest, offer, admission and grant is an event, so a pool that you
change constantly can reach the history cap. Pause, drain and retire are
allowed up to 8 events past the cap so you can always take a full pool out
of service. A retried request with the same idempotency key is not refused by
a cap.

If you renew the Agreement after the grace period, your active pools are
paused with reason `creator_agreement_renewal`; promote them again.

**Price bounds.** Each of a model's three rates (prompt, cached prompt,
completion, in credits per million tokens) must lie inside inclusive
network-set bounds, with cache-hit not above prompt. A rate outside them is
refused with `pool_model_pricing_out_of_bounds`, which names the entry, the
bound and its limit. The bounds are coordinator configuration; read the live
values with `creator status` (or `GET /v1/creator/pricing-bounds`).
`creator manifest sign` checks them before signing.

Buyers pay your signed rates under the standard formula and platform fee.

## Common errors

| Symptom | Cause |
|---|---|
| `not logged in` | Run `creator login` first |
| `no local keys for pool ...` | Run `creator keygen` on the Mac that holds the keys |
| `admit` finds no provider | The Mac is not claimed by your GitHub user, or not connected |
| 409 `replay_conflict` | An operation id was reused with different content. Re-submitting an identical offer is idempotent; if you changed the offer, withdraw the earlier one (`models admission withdraw`) first |
| `pool_model_entry_*` on submit | The manifest was refused whole; the code names the entry problem (duplicate, runtime pairing, license, unattested paid serving, context) |
| Buyer gets `503 pool_unavailable` | Pool not active, buyer not authorized, or no member serving; the answer is deliberately non-specific |

## Known gaps

- A Mac in two active pools with the same artifact binds only when its
  config names the entry: set `pool_model_id`. Without it the offer status
  warns `pool_binding_ambiguous`; a `pool_model_id` that matches no active
  entry warns `pool_binding_requested_entry_unmatched`.
