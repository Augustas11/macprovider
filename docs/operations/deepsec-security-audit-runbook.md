# DeepSec Security Audit Runbook

This runbook standardizes the PR #317 DeepSec workflow for future audits of
money-path, auth, network-security, and performance-sensitive changes.

Use it for any PR or branch that touches:

- `phase4-coordinator/internal/billing/`
- `phase4-coordinator/internal/buyer/`
- `phase4-coordinator/internal/auth/`
- `phase4-coordinator/internal/requestlog/`
- `phase4-coordinator/internal/ws/`
- `phase5-gateway/internal/router/`
- `phase5-gateway/internal/auth/`
- gateway storage, quota, usage, settlement, or reconciler code
- provider admission, provider HTTP, local loopback API, installer, deploy,
  nginx, Pearl VPS, or coordinator public API surfaces
- rate limits, idempotency, timestamps, settlement finality, ledger math,
  token mint/revocation, provider earnings, or anti-spam controls

## Required Outcome

The operator must produce an artifact set that answers:

1. Which exact commit SHA was audited.
2. Which files were in scope and why.
3. Which DeepSec backend produced findings.
4. Which independent backend revalidated those findings.
5. Which findings are true positives, false positives, fixed, uncertain, or
   accepted risk.
6. Whether the PR may merge, must fix, or needs another audit on a newer SHA.

For money-path and network-security PRs, unresolved `CRITICAL`, `HIGH`,
`HIGH_BUG`, and `MEDIUM` true positives block merge by default. `BUG` findings
also block when they affect billing, settlement, quota, auth, or abuse control.

## Model Policy

Use two independent LLM surfaces:

- Discovery: Codex via DeepSec `--agent codex`.
- Revalidation: Claude via DeepSec `--agent claude`.

Both must run through subscription CLI/auth surfaces, not direct provider API
keys and not AI Gateway keys.

Required guardrails:

- Refuse `OPENAI_API_KEY`.
- Refuse `ANTHROPIC_API_KEY`.
- Refuse `ANTHROPIC_AUTH_TOKEN`.
- Refuse `AI_GATEWAY_API_KEY`.
- Refuse `OPENAI_BASE_URL`.
- Refuse `ANTHROPIC_BASE_URL`.
- Refuse `VERCEL_OIDC_TOKEN`.
- Refuse `VERCEL_TOKEN`.
- Refuse `.env.local` and `.env` in the audit worktree because DeepSec loads
  dotenv files.
- Require `${CODEX_HOME:-$HOME/.codex}/auth.json`.
- Force Claude SDK subprocesses to use project-only settings so user-level
  `~/.claude/settings.json` cannot inject `ANTHROPIC_API_KEY`.

## Scratch Worktree

Never run a security audit against a moving branch name. Resolve the PR head
SHA first and audit that exact object.

```bash
PR=317
SHA="$(gh pr view "$PR" --json headRefOid --jq .headRefOid)"
echo "$SHA"

git fetch origin
git worktree add --detach "../macprovider-deepsec-pr${PR}" "$SHA"
cd "../macprovider-deepsec-pr${PR}"
mkdir -p "audits/pr${PR}-deepsec"
```

If the operator already has a known SHA, verify it still matches the PR:

```bash
gh pr view "$PR" --json headRefOid --jq .headRefOid
git rev-parse HEAD
```

Both values must match before the audit starts.

## Subscription-Only Wrapper

Create `audits/pr${PR}-deepsec/subscription-only-deepsec.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

for f in .env.local .env; do
  if [ -e "$f" ]; then
    echo "Refusing DeepSec run: $f exists and could inject API credentials." >&2
    exit 1
  fi
done

for v in \
  OPENAI_API_KEY \
  ANTHROPIC_API_KEY \
  ANTHROPIC_AUTH_TOKEN \
  AI_GATEWAY_API_KEY \
  OPENAI_BASE_URL \
  ANTHROPIC_BASE_URL \
  VERCEL_OIDC_TOKEN \
  VERCEL_TOKEN
do
  if [ -n "${!v:-}" ]; then
    echo "Refusing DeepSec run: $v is set." >&2
    exit 1
  fi
done

if [ ! -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ]; then
  echo "Missing Codex subscription auth: ${CODEX_HOME:-$HOME/.codex}/auth.json" >&2
  exit 1
fi

real_claude="$(command -v claude || true)"
if [ -z "$real_claude" ]; then
  echo "Missing Claude CLI." >&2
  exit 1
fi

if ! command -v codex >/dev/null; then
  echo "Missing Codex CLI." >&2
  exit 1
fi

shim_dir="$(mktemp -d)"
trap 'rm -rf "$shim_dir"' EXIT

cat >"$shim_dir/claude" <<EOF
#!/usr/bin/env bash
exec "$real_claude" --setting-sources project "\$@"
EOF
chmod +x "$shim_dir/claude"

echo "subscription-only preflight ok: API/gateway env absent, Codex auth.json present, Claude/Codex CLIs present" >&2

exec env -i \
  HOME="$HOME" \
  PATH="$shim_dir:$PATH" \
  USER="${USER:-}" \
  LOGNAME="${LOGNAME:-}" \
  SHELL="${SHELL:-/bin/bash}" \
  TERM="${TERM:-dumb}" \
  TMPDIR="${TMPDIR:-/tmp}" \
  CLAUDE_CODE_EXECUTABLE="$shim_dir/claude" \
  npx --yes deepsec "$@"
```

Then:

```bash
chmod +x "audits/pr${PR}-deepsec/subscription-only-deepsec.sh"
```

Why the `CLAUDE_CODE_EXECUTABLE` shim matters: DeepSec uses the Claude Agent
SDK, and that SDK may launch its bundled Claude binary instead of the shell
`claude` on `PATH`. Passing `CLAUDE_CODE_EXECUTABLE` forces the SDK to launch
the shim, which adds `--setting-sources project`. This prevents user-level
Claude settings from injecting an API key.

## Preflight

Run these before spending audit tokens:

```bash
env | sort | rg '^(OPENAI_API_KEY|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|AI_GATEWAY_API_KEY|OPENAI_BASE_URL|ANTHROPIC_BASE_URL|VERCEL_OIDC_TOKEN|VERCEL_TOKEN)=' || true

codex --version
claude --version

env -i \
  HOME="$HOME" \
  PATH="$PATH" \
  USER="${USER:-}" \
  LOGNAME="${LOGNAME:-}" \
  SHELL="${SHELL:-/bin/bash}" \
  TERM="${TERM:-dumb}" \
  TMPDIR="${TMPDIR:-/tmp}" \
  claude -p 'Respond with exactly OK.' \
    --output-format json \
    --no-session-persistence \
    --model opus \
    --setting-sources project
```

Expected:

- no API/gateway env output from the first command;
- Codex and Claude versions print;
- Claude returns `is_error: false` and `result: "OK"`.

If Claude returns `Invalid API key`, do not run revalidation. Fix the settings
source path first.

## Build The File Manifest

Start with changed files:

```bash
git diff --name-only "origin/main...$SHA" > "audits/pr${PR}-deepsec/changed.txt"
```

Then create `audits/pr${PR}-deepsec/files.txt`.

Include every changed production/config file plus adjacent high-risk files
needed to reason about reachability. Do not include generated evidence,
test-only files, or unrelated docs unless the PR changes operator policy.

For money-path PRs, bias toward including:

- billing endpoints, formula, hot path, recovery, settlement receipts,
  snapshots, stores, quarantine, rate cards
- buyer forwarders, request routing, failover, server handlers, transport
  result contracts
- request log and idempotency stores
- auth token validation, minting, revocation, and bootstrap code
- coordinator config and config examples
- gateway router, quota reservation, usage, settlement, reconciler, storage
- local provider HTTP server and inference relay
- nginx/deploy files when public API abuse or Pearl VPS exposure is in scope

Keep the manifest focused enough that the model reads the right code, but wide
enough that it can prove or refute reachability.

## Discovery Run

```bash
"audits/pr${PR}-deepsec/subscription-only-deepsec.sh" process \
  --project-id "macprovider-deepsec-pr${PR}" \
  --files-from "audits/pr${PR}-deepsec/files.txt" \
  --agent codex \
  --concurrency 1 \
  --batch-size 4 \
  --no-ignore \
  --comment-out "audits/pr${PR}-deepsec/codex-comment.md"
```

DeepSec exits non-zero when it finds issues. That is expected. Treat the run as
complete if it writes the comment/export artifact and reports all files done.

## Claude Revalidation

Run Claude only after Codex findings exist:

```bash
"audits/pr${PR}-deepsec/subscription-only-deepsec.sh" revalidate \
  --project-id "macprovider-deepsec-pr${PR}" \
  --agent claude \
  --concurrency 1 \
  --batch-size 2
```

Do not add `--force` unless intentionally rechecking already-completed
verdicts. If the run is interrupted, rerun the same command without `--force`;
DeepSec should continue with unrevalidated findings.

Claude revalidation is not a second discovery scan. It reads files and traces
call paths to verdict Codex findings as true positive, false positive, fixed,
uncertain, or duplicate.

## Export Artifacts

```bash
"audits/pr${PR}-deepsec/subscription-only-deepsec.sh" export \
  --project-id "macprovider-deepsec-pr${PR}" \
  --format json \
  --out "audits/pr${PR}-deepsec/findings-claude-revalidated.json"

rm -rf "audits/pr${PR}-deepsec/findings-claude-revalidated-md"
"audits/pr${PR}-deepsec/subscription-only-deepsec.sh" export \
  --project-id "macprovider-deepsec-pr${PR}" \
  --format md-dir \
  --out "audits/pr${PR}-deepsec/findings-claude-revalidated-md"
```

The export hides resolved false-positive/fixed/accepted-risk findings by
default. To inspect raw verdict metadata, read DeepSec state under:

```bash
data/macprovider-deepsec-pr${PR}/files/
data/macprovider-deepsec-pr${PR}/runs/
```

Useful summary:

```bash
find "data/macprovider-deepsec-pr${PR}/files" -type f -name '*.json' -print0 |
  xargs -0 jq -r '.findings[]? | select(.revalidation.verdict != null) |
  [.severity, .revalidation.verdict, .title, .revalidation.runId] | @tsv' |
  sort
```

## Merge Gate

Before merge, the PR owner must either:

- fix every blocking true positive and rerun DeepSec on the new PR head SHA;
- prove a finding false-positive with concrete code references and record the
  accepted verdict;
- explicitly record accepted risk in the PR and decision log.

For money-path/auth/network abuse findings, accepted risk should be rare and
must name the compensating control, blast radius, and revisit trigger.

Do not merge on "Claude failed to revalidate." That is a tooling blocker, not a
security result.

## PR #317 Reference Run

Reference SHA:

```text
b0f1c60a1971c2705e4c713b964634e8a4af4944
```

Discovery:

- Agent: Codex / `gpt-5.5`
- Files: 19
- Findings: 8
- Run: `20260702152958-f421ef3f36966fda`

Revalidation:

- Agent: Claude / `claude-opus-4-8`
- Findings revalidated: 8
- True positives: 8
- False positives: 0
- Fixed: 0
- Uncertain: 0
- Runs:
  - `20260702161340-003ce6b59e1c2796`
  - `20260702162635-e129e5e40ade1761`

Confirmed true positives:

- `HIGH` Provider earnings token use does not harden token against self-heal
  takeover.
- `HIGH` Pending settlement holds can leave delivered responses unbilled and
  unreconciled.
- `HIGH_BUG` Billing ranges use unsafe RFC3339Nano string ordering.
- `MEDIUM` Unauthenticated loopback inference endpoint is browser-triggerable.
- `MEDIUM` Unauthenticated requests can exhaust the admin ledger rate-limit
  bucket.
- `MEDIUM` Idempotency keys are global across accounts.
- `BUG` RFC3339Nano text comparison can miss active config snapshots.
- `BUG` Retry loop can continue after a streaming dispatch already wrote an
  error response.
