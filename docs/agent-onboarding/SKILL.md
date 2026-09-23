---
name: malibu-provider-api-onboarding
description: Use when helping a provider install, verify, repair, update, or uninstall Malibu on an Apple Silicon Mac, or when configuring coding agents and SDKs to use the Malibu OpenAI-compatible or Anthropic-compatible API.
---

# Malibu Provider And API Onboarding

Canonical publication URL: `https://get.malibu.tech/skill.md`
Discovery index publication URL: `https://get.malibu.tech/.well-known/skills/index.json`
Last updated: 2026-09-23

Use this skill for two jobs only:

1. Help a new invited Apple Silicon provider install Malibu, get admitted,
   serve a paid catalog model, verify serving, operate safely, recover, update,
   or uninstall.
2. Help a buyer configure Malibu as an OpenAI-compatible or
   Anthropic-compatible backend for a coding-agent harness or SDK.

## Safety Rules

- Never print secrets. Redact provider tokens, buyer API keys, Keychain values,
  signing keys, SSH keys, environment files, raw prompts, raw logs, and release
  material.
- Default to non-production local smoke checks. Production publication,
  billing, payout, auth, coordinator, release, and deployment work require
  explicit operator approval.
- Do not run destructive commands such as real install, update, uninstall,
  credential rotation, model switch, or service replacement unless the user
  asked for that exact action.
- Never pipe a network fetch into a shell. Fetch scripts to a mode-0600 file,
  preview and syntax-check them, dry-run when supported, then run the same
  local bytes only after approval.
- Use public `malibu.tech` URLs. Do not introduce legacy internal hosts.

## Provider Decision Tree

- GUI owner at the Mac: prefer Malibu.app from `https://malibu.tech/host`.
- Terminal or SSH fleet setup: use `https://get.malibu.tech/install.sh`.
- SSH/headless mode must use `MACPROVIDER_HEADLESS=1` and a non-root
  `MACPROVIDER_HEADLESS_USER`. Headless setup needs working `sudo`; Keychain
  prompts cannot be completed over a blind SSH session.
- The installed user-facing command is `malibu-cli`. Some on-disk paths and
  process names remain `macprovider-cli`; those are wire names, not product
  names.

## Provider Prerequisites

- Apple Silicon Mac running macOS 14 or newer.
- Invite required for paid provider admission. A valid invite is shaped like
  `https://malibu.tech/j#/PLACEHOLDER`. Without an invite, install may complete
  only as a non-paid/donor-style local provider and will not satisfy paid
  serving.
- RAM determines eligible paid catalog models. Use
  `malibu-cli autotune --recommend --check-only --no-submit-hardware-evidence --json`
  after install to learn what fits this Mac; do not promise revenue from RAM
  alone.
- Keep enough disk for the selected model weights plus installer staging.
  If no paid model fits, follow the installer or autotune recommendation;
  do not force a model.
- Earnings are pre-beta credits unless current public account pages say
  otherwise. USDC payouts are not live. Do not make ROI, yield, passive-income,
  or projected-earnings claims.

## Safe Install Flow

Fetch once, preview locally, syntax-check, and dry-run first:

```bash
tmp_install="$(mktemp "${TMPDIR:-/tmp}/macprovider-install.XXXXXX")"
chmod 600 "$tmp_install"
curl -fsSL --proto '=https' --tlsv1.2 --remove-on-error https://get.malibu.tech/install.sh -o "$tmp_install"
install_sha="$(shasum -a 256 "$tmp_install" | awk '{print $1}')"
wc -l "$tmp_install"
bash -n "$tmp_install"
sed -n '1,220p' "$tmp_install"
bash "$tmp_install" --dry-run
```

The preview is not a full review. Before the real install, the user or
operator must review the full local file named by `$tmp_install`, verify the
recorded SHA-256, and approve this exact host mutation:

```bash
printf '%s  %s\n' "$install_sha" "$tmp_install" | shasum -a 256 -c -
bash -n "$tmp_install"
bash "$tmp_install"
rm -f "$tmp_install"
```

Expected install branches:

- Interactive install prompts for defaults, invite/referral handling when
  applicable, service installation, model selection, and admission.
- `MACPROVIDER_NO_PROMPT=1` accepts defaults but still mutates the host.
- `MACPROVIDER_HEADLESS=1 MACPROVIDER_HEADLESS_USER="$USER"` is for SSH-only
  fleet installs.
- `MACPROVIDER_NO_LAUNCHD=1` is expert/debug only. Do not use it for real
  onboarding, because it can leave no provider service running.
- `MACPROVIDER_REFERRAL_REPLACE_INCUMBENT=1` is only for an explicit fresh
  invite replacement of an existing provider identity.
- `MACPROVIDER_MODEL=...` pins a model only when the model is known to fit and
  be eligible. Prefer autotune recommendations.
- Exit code `0` means the script completed. Exit code `7` is usually usage,
  safety, prompt-abort, or validation failure. Exit code `70` is an installer
  or recovery failure that needs diagnostics before retrying.

## Verify Provider Serving

Local checks:

```bash
malibu-cli --version
malibu-cli status
malibu-cli status --json
malibu-cli status --advanced
malibu-cli doctor --offline
malibu-cli doctor report --json
malibu-cli models discover --json
malibu-cli models admission status <candidate-id> --json
malibu-cli autotune --recommend --check-only --no-submit-hardware-evidence --json
```

Serving is not proven by "installed" alone. Stop only when local status shows
the provider is admitted/connected, a catalog model is selected, launchd is
managing the provider service, and no unrecovered install/update error remains.

External public checks:

```bash
curl -fsSL --proto '=https' --tlsv1.2 https://api.malibu.tech/v1/status
curl -fsSL --proto '=https' --tlsv1.2 https://api.malibu.tech/v1/stats/models
```

The model is routable when `/v1/status` lists it with
`available: true`, `ready_provider_count > 0`, and free or total slots, and
`/v1/stats/models` shows `serving_capable_provider_count > 0` plus
`routable_provider_count > 0`. If an authenticated `/v1/models` response is
available, require hash verification to be `all_verified`.

## Provider Operations And Recovery

Use read-only diagnostics before changing files:

```bash
malibu-cli update --check
malibu-cli recover-update --help
malibu-cli models status
malibu-cli autotune --recommend --check-only --no-submit-hardware-evidence --json
malibu-cli autotune --dry-run
```

Useful local paths:

- Config: `~/.config/macprovider/config.yaml`
- Install directory: `~/macprovider`
- Binary: `~/.local/bin/macprovider-cli`
- LaunchAgent: `~/Library/LaunchAgents/live.malibu.provider.plist`
- Logs: `~/Library/Logs/macprovider/`

Recovery ladder:

- `waiting_trust` or `429`: wait and recheck status; do not rotate identity.
- No paid model fits: run autotune recommendation and accept donor/non-paid
  mode only if the user understands it is not paid serving.
- Quarantine or Gatekeeper: use the GUI path or re-download from public Malibu
  endpoints; do not bypass unknown binaries.
- Xcode CLT `python3` stub: install Command Line Tools or use a real Python 3
  before retrying installer paths that need Python.
- SSH Keychain issue: rerun from the logged-in GUI user session, or use the
  documented headless mode with the owner account.
- Coordinator restart churn: collect `status --advanced` and `doctor
  report --json`; avoid restart loops until the specific state is known.
- Interrupted update: inspect `recover-update --help` first; run recovery only
  when the user explicitly asks.

Run the mutating updater only when explicitly asked:

```bash
malibu-cli update
malibu-cli --version
malibu-cli status --advanced
```

## Provider Uninstall

Download once, inspect, dry-run, then use the same local bytes for approved
removal:

```bash
tmp_uninstall="$(mktemp "${TMPDIR:-/tmp}/macprovider-uninstall.XXXXXX")"
chmod 600 "$tmp_uninstall"
curl -fsSL --proto '=https' --tlsv1.2 --remove-on-error https://get.malibu.tech/uninstall.sh -o "$tmp_uninstall"
uninstall_sha="$(shasum -a 256 "$tmp_uninstall" | awk '{print $1}')"
sed -n '1,220p' "$tmp_uninstall"
MACPROVIDER_NO_PROMPT=1 bash "$tmp_uninstall" --dry-run
```

Use `MACPROVIDER_NO_PROMPT=1` for the dry-run because the live uninstaller can
still ask for confirmation through `/dev/tty`; no-TTY coding-agent harnesses
otherwise abort before showing the planned removal commands.

Only remove the provider when the user explicitly asks:

```bash
printf '%s  %s\n' "$uninstall_sha" "$tmp_uninstall" | shasum -a 256 -c -
bash "$tmp_uninstall"
rm -f "$tmp_uninstall"
```

The public uninstaller removes launchd services, installed binary/symlink,
install prefix, watchdog files, and logs recorded in the install manifest. It
does not remove `~/.cache/macprovider`, Hugging Face caches, or files outside
the listed locations. Treat identity/config retention as sensitive; do not
print it.

## Buyer API Essentials

- Base URL for OpenAI-compatible chat: `https://api.malibu.tech/v1`.
- Base URL for the Anthropic Messages facade: `https://api.malibu.tech`.
- Buyer key flow: open `https://api.malibu.tech/auth/github/start`, sign in,
  generate an API key, and store it as a secret. Buyer keys start with `mp_`.
- Discover live model IDs from `/v1/status` or authenticated `/v1/models`.
  Do not hardcode old model IDs.
- Public endpoints for discovery: `/v1/status`, `/v1/stats/models`,
  `/v1/rate-card`, and `/v1/openrouter/models`.
- Requests require `Authorization: Bearer $MALIBU_API_KEY`.
- Quota errors return `429 quota_exhausted`; inspect `X-RateLimit-*` headers.
- Use `n: 1`; higher `n` is rejected.
- Keep `max_tokens` small for smoke tests. Respect model context limits from
  `/v1/status` or `/v1/models`.
- Streaming works, but stream chunks may not carry signed receipts.
- Sticky cache uses `X-MacProvider-Conversation`. Cache-hit pricing appears in
  usage when a provider reuses the prefix.
- Buyer provider pinning is not a general public harness feature; do not rely
  on it unless the account explicitly exposes it.
- Structured outputs support a narrow JSON Schema subset. Avoid `$ref`,
  `anyOf`, `pattern`, and `format`.
- Tool calls are model-dependent. Qwen-family models are the best first try.
  Some models return plain text even when tools are supplied, and some
  gpt-oss-style tool behavior is first-turn only.
- Long sessions are bounded by request-body bytes, aggregate tool-result bytes,
  assistant-history tool-call bytes/counts, and the served model context
  window. Start a new thread before a harness approaches those limits.

## Generic SDKs

Python OpenAI SDK:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.malibu.tech/v1",
    api_key="<your-malibu-api-key>",
)
```

TypeScript OpenAI SDK:

```typescript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "https://api.malibu.tech/v1",
  apiKey: process.env.MALIBU_API_KEY,
});
```

Anthropic SDKs use the Messages facade:

```bash
export ANTHROPIC_BASE_URL="https://api.malibu.tech"
export ANTHROPIC_AUTH_TOKEN="$MALIBU_API_KEY"
```

## Coding-Agent Harness Recipes

Use a model ID returned by `/v1/status` in every recipe.

- Claude Code: experimental Anthropic facade. Set
  `ANTHROPIC_BASE_URL=https://api.malibu.tech` and
  `ANTHROPIC_AUTH_TOKEN=$MALIBU_API_KEY`. Smoke with a tiny `/v1/messages`
  request before trusting tools or long sessions.
- Codex CLI: add a custom provider in `~/.codex/config.toml`:
  `[model_providers.malibu]`, `name = "Malibu"`,
  `base_url = "https://api.malibu.tech/v1"`,
  `env_key = "MALIBU_API_KEY"`, `wire_api = "chat"`, then set
  `model_provider = "malibu"` and `model` to a live model ID.
- Cursor: Settings -> Models -> OpenAI API key, set the key, override the
  OpenAI base URL to `https://api.malibu.tech/v1`, add/select a live model ID.
  Custom-base support is best for chat; agent/tool behavior may vary.
- Cline: choose API Provider "OpenAI Compatible"; Base URL
  `https://api.malibu.tech/v1`; API Key `$MALIBU_API_KEY`; Model ID from
  `/v1/status`; set context window from that status response.
- Continue: in `config.yaml`, use `provider: openai`,
  `apiBase: https://api.malibu.tech/v1`, `apiKey: $MALIBU_API_KEY`, and
  `model: <live-model-id>`.
- Aider: set `OPENAI_API_BASE=https://api.malibu.tech/v1` and
  `OPENAI_API_KEY=$MALIBU_API_KEY`, then run
  `aider --model openai/<live-model-id>`.
- OpenCode: in `opencode.jsonc`, define a provider using
  `@opencode/ai/providers/openai-compatible`,
  `settings.baseURL = "https://api.malibu.tech/v1"`, and the live model ID;
  add the credential through `/connect`.
- Pi: add `~/.pi/agent/models.json` provider `malibu` with
  `baseUrl: "https://api.malibu.tech/v1"`, `api: "openai-completions"`,
  `apiKey: "$MALIBU_API_KEY"`, and `models: [{"id":"<live-model-id>"}]`.
- Zed: Agent Settings -> Add Provider -> OpenAI-compatible, or set
  `language_models.openai_compatible.malibu.api_url` to
  `https://api.malibu.tech/v1` with `available_models` containing the live
  model and context window.
- Goose: configure the OpenAI provider with `OPENAI_HOST=https://api.malibu.tech`,
  `OPENAI_BASE_PATH=v1/chat/completions`, `OPENAI_API_KEY=$MALIBU_API_KEY`,
  `GOOSE_PROVIDER=openai`, and `GOOSE_MODEL=<live-model-id>`.

## Tiny API Probes

OpenAI-shape basic chat:

```bash
curl -fsS https://api.malibu.tech/v1/chat/completions \
  -H "Authorization: Bearer $MALIBU_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"<live-model-id>","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":8,"n":1}'
```

Anthropic-shape basic chat:

```bash
curl -fsS https://api.malibu.tech/v1/messages \
  -H "Authorization: Bearer $MALIBU_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"<live-model-id>","max_tokens":8,"messages":[{"role":"user","content":"Reply with ok."}]}'
```

Local smoke is complete only when no secret was printed, the provider is
admitted and routable or the API probe returns a normal chat response, and no
mutating action outside the user's exact request was run.
