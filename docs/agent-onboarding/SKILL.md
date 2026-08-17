---
name: macprovider-agent-onboarding
description: Use when helping providers install, repair, inspect, update, or uninstall MacProvider, or when helping buyers use MacProvider through OpenAI-compatible SDKs.
---

# MacProvider Agent Onboarding Skill

Canonical publication URL: `https://get.malibu.tech/skill.md`
Discovery index publication URL: `https://get.malibu.tech/.well-known/skills/index.json`
Source path: `docs/agent-onboarding/SKILL.md`
Last updated: 2026-08-17

Use this skill when an agent needs to help a provider install, repair,
inspect, update, or uninstall MacProvider, or when a buyer wants to use
MacProvider through an OpenAI-compatible SDK.

## Safety Rules

- Never print secrets. Redact provider tokens, buyer API keys, Keychain values,
  signing keys, coordinator environment values, SSH keys, and release signing
  material.
- Default to non-production local smoke checks. Production coordinator changes,
  release publication, billing, payout, auth, operator key, and live deployment
  work require explicit operator approval.
- Do not run destructive commands such as uninstall, credential rotation,
  release promotion, or production deploy scripts unless the operator asked for
  that exact action.
- Do not inspect `d-inference` source. It is outside the clean-room boundary.
- Use `malibu.tech` URLs. Do not introduce legacy `streamvc.live` URLs.

## Provider Install

Target host: Apple Silicon Mac, macOS 14 or newer.

Inspect the installer first when possible:

```bash
tmp_install="$(mktemp "${TMPDIR:-/tmp}/macprovider-install.XXXXXX")"
chmod 600 "$tmp_install"
curl -fsSL --proto '=https' --tlsv1.2 --remove-on-error https://get.malibu.tech/install.sh -o "$tmp_install" &&
  less "$tmp_install" &&
  bash "$tmp_install"
rm -f "$tmp_install"
```

For unattended local smoke checks only, use documented installer environment
variables such as `MACPROVIDER_NO_PROMPT=1`, `MACPROVIDER_NO_LAUNCHD=1`,
`MACPROVIDER_MODEL=...`, and `MACPROVIDER_COORDINATOR_URL=...`. Do not use
non-interactive install mode against production credentials unless explicitly
authorized.

## Provider Status And Recovery

Use the installed CLI before changing files by hand. These commands are
read-only diagnostics:

```bash
macprovider-cli --version
macprovider-cli status
macprovider-cli status --json
macprovider-cli status --advanced
macprovider-cli update --check
```

Run the mutating updater only when the operator explicitly asks to update this
provider, after `update --check` reports the target and after noting whether a
launchd-managed service may restart:

```bash
macprovider-cli update
macprovider-cli --version
macprovider-cli status --advanced
```

If the CLI cannot reach the coordinator and reports an old public version,
the public installer can perform an upgrade-in-place after it verifies signed
release metadata and artifacts. Treat this as a mutating update path: run it
only when the operator explicitly asks to update this provider, after noting
the target version and whether a launchd-managed service may restart.

```bash
tmp_install="$(mktemp "${TMPDIR:-/tmp}/macprovider-install.XXXXXX")"
chmod 600 "$tmp_install"
curl -fsSL --proto '=https' --tlsv1.2 --remove-on-error https://get.malibu.tech/install.sh -o "$tmp_install" &&
  bash "$tmp_install"
rm -f "$tmp_install"
```

Useful local paths:

- Config: `~/.config/macprovider/config.yaml`
- Install directory: `~/macprovider`
- LaunchAgent: `~/Library/LaunchAgents/live.malibu.provider.plist`
- Logs: `~/Library/Logs/macprovider/`

Do not print raw logs into a chat, ticket, or agent transcript. Logs may contain
tokens, prompts, headers, local paths, and request/response bodies. Prefer the
status commands above. If logs are required, use a maintained project redactor
or a narrow local extractor that emits only allowlisted status fields.

## Provider Uninstall

Download the uninstaller once, inspect it, then run the same local bytes for
dry-run and approved removal. Do not execute a second mutable network fetch for
the real uninstall.

```bash
tmp_uninstall="$(mktemp "${TMPDIR:-/tmp}/macprovider-uninstall.XXXXXX")"
chmod 600 "$tmp_uninstall"
curl -fsSL --proto '=https' --tlsv1.2 --remove-on-error https://get.malibu.tech/uninstall.sh -o "$tmp_uninstall" &&
  uninstall_sha="$(shasum -a 256 "$tmp_uninstall" | awk '{print $1}')" &&
  less "$tmp_uninstall" &&
  bash "$tmp_uninstall" --dry-run
```

Only remove the provider when the operator explicitly asks:

```bash
printf '%s  %s\n' "$uninstall_sha" "$tmp_uninstall" | shasum -a 256 -c -
bash "$tmp_uninstall"
rm -f "$tmp_uninstall"
```

## Buyer SDK Compatibility

MacProvider is OpenAI-compatible. There is no separate `macprovider` SDK.

Python:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.malibu.tech/v1",
    api_key="<your-macprovider-api-key>",
)
```

TypeScript:

```typescript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "https://api.malibu.tech/v1",
  apiKey: process.env.MACPROVIDER_API_KEY,
});
```

Get a buyer API key at `https://api.malibu.tech/auth/github/start`.

## Local Smoke Stop Condition

A non-production onboarding smoke is complete when:

1. `macprovider-cli --version` prints the installed version.
2. `macprovider-cli status` or `macprovider-cli status --json` reaches the local
   status endpoint.
3. The provider either appears connected or reports a specific recoverable
   coordinator/version/config error.
4. No secret material was printed.
5. No production deploy, release promotion, or credential mutation was run.

## Authoritative References

- `README.md`
- `docs/using-macprovider-with-openai-sdk.md`
- `docs/runbooks/provider-cli-release-verification.md`
- `ops/runbooks/entry-610-first-hop-recovery.md`
- `specs/SPEC-003-open-onboarding.md`
- `specs/SPEC-006-buyer-api.md`
- `specs/SPEC-020-provider-autoupdate.md`
- `specs/SPEC-035-provider-connection-diagnostics.md`
