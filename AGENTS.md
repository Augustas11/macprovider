# MacProvider Agent Guide

This file is the canonical instruction surface for every coding agent in this
repository. Keep it short, concrete, and current. Put long incident writeups in
docs or runbooks and link them from here.

## Project Overview

MacProvider turns Apple Silicon Macs into remote-addressable MLX inference
providers behind Malibu-branded buyer and provider surfaces. The repo includes
the Swift provider CLI/app, Go coordinator and gateway services, verification
tools, specs, release scripts, and operational runbooks.

Read the nearest implementation files before editing; many behavior changes are
governed by `specs/AUTHORITY.json`, `specs/CONFORMANCE.json`, and the matching
`specs/SPEC-NNN-*.md`.

## Project Structure

- `phase3-binary/` - Swift package for `malibu-cli`, Malibu.app assets,
  installer, catalog, release, and provider runtime scripts.
- `phase4-coordinator/` - Go coordinator, provider pool, billing, rewards,
  onboarding, stats, auth, and deployment scripts.
- `phase5-gateway/` - Go OpenAI-compatible gateway and buyer routing surface.
- `phase7-verify/` - Go receipt verification CLI and schemas.
- `test/integration/` - cross-service coordinator/gateway integration harness.
- `scripts/` - release, governance, catalog, journey, and CI helper scripts.
- `specs/` - normative specs and generated governance indexes.
- `docs/` and `ops/` - documentation, runbooks, operations notes, and
  deployment helpers.
- `audits/` - durable audit evidence and historical review artifacts.

## Setup And Build

Use the existing package managers and pinned dependencies; do not add new
dependencies without explicit approval.

```bash
make build-linux
cd phase3-binary && swift build
cd phase4-coordinator && go build ./...
cd phase5-gateway && go build ./...
```

Go modules currently target Go `1.26.6`; the Swift package targets macOS 14+
with Swift tools 5.9.

## Testing And Checks

Run the smallest relevant test while iterating, then the broader gate for the
surface you changed.

```bash
make test                  # coordinator, gateway, integration, and dist checks
make vet                   # go vet for coordinator, gateway, integration
make test-coordinator      # coordinator Go tests
make test-gateway          # gateway Go tests
make test-integration      # real cross-service integration harness
make test-dist             # release/deploy/script regression suite
make lint-coordinator      # golangci-lint with repo config
cd phase3-binary && swift test
```

Single-test examples:

```bash
cd phase4-coordinator && go test ./internal/billing -run TestName
cd phase5-gateway && go test ./internal/router -run TestName
cd test/integration && go test -run TestName -race -count=1
cd phase3-binary && swift test --filter TestName
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_upstream_watch
node --test path/to/file.test.mjs
bash scripts/test-catalog-release.sh
```

Never claim an interrupted, skipped, or timed-out run passed. Report the exact
command and result.

## Code Style

- Go: run `gofmt`; use `make vet` and `make lint-coordinator` where relevant.
- Swift: follow existing SwiftPM layout and strict concurrency settings.
- Python, shell, and Node scripts: keep them noninteractive when used by CI or
  release automation.
- Follow neighboring patterns; do not reformat unrelated files.
- Comments should explain non-obvious constraints, not restate the code.

## Git Workflow

Never do write-heavy work in canonical `/Users/augstar/macprovider-poc` unless
the user explicitly says to use that checkout. Start from a fresh sibling
worktree:

```bash
git status -sb
git worktree list
git fetch origin
git worktree add ../macprovider-<topic> -b <scope>/<topic> origin/main
cd ../macprovider-<topic>
```

Use one branch per task. Before pushing or opening a PR, verify
`git log origin/main..HEAD` contains only the current task.

Money-path, auth, gateway, coordinator, release, CI, schema, and executable
changes go through PR review. Docs-only narrative changes may go direct to
`main` only when the working tree is clean, local `main` exactly mirrors
`origin/main`, and the change touches no executable, config, schema, release,
catalog, rate-card, workflow, or runtime-affecting path.

After any PR squash-merge or direct docs push, sync canonical main:

```bash
git -C /Users/augstar/macprovider-poc fetch origin
git -C /Users/augstar/macprovider-poc checkout main
git -C /Users/augstar/macprovider-poc reset --hard origin/main
```

Do not force-push `main`, admin-merge, bypass branch protection, or merge with
red required checks unless the user gives explicit written approval for that
specific action in the current turn.

## Git Identity

This repo pushes to `Augustas11/macprovider`. A local credential helper should
call `gh auth token -u Augustas11` automatically. Do not switch global GitHub
accounts and do not embed tokens in remote URLs. If push routing fails, restore
the local helper in `.git/config`; do not print or persist token values.

## PR Governance

Before `gh pr create`, draft the PR body and validate the governance block when
the branch changes specs, manifests, product behavior, or any non-governance
path:

```bash
python3 scripts/check_spec_pr_declaration.py \
  --event /tmp/pr-event.json \
  --base origin/main \
  --head HEAD
```

The PR body must contain exactly one `SPEC-GOVERNANCE-DECLARATION-BEGIN` /
`SPEC-GOVERNANCE-DECLARATION-END` block when the validator requires it. Fill it
honestly; do not fabricate specs or requirements to satisfy the checker. Treat a
red `spec-index / check` as blocking for agent behavior.

## Sensitive Paths

Changes under these paths require PR review and careful tests:

- `phase4-coordinator/internal/billing/`
- `phase4-coordinator/internal/buyer/`
- `phase4-coordinator/internal/auth/`
- `phase4-coordinator/internal/requestlog/`
- `phase5-gateway/internal/router/`
- `phase5-gateway/internal/auth/`

For any change that mints, upgrades, downgrades, or buyer-exposes a trust tier
or attestation-strength label, update or confirm the normative SPEC first
before writing code.

## Audit Gate

Implementation slices are not done until the full fix diff is audited. Run
three lanes over the complete diff as it will land: code review, security
review, and architecture review. In Codex sessions, use native Codex
subagents/auditor lanes. Use `omc ask codex` only as a legacy fallback outside
Codex contexts that lack native subagents.

Gate: 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings across all three lanes. LOW and
INFO findings may be carried explicitly.

Review the full combined fix, not only a follow-up slice. When needed, find the
base commit before the first fix commit and diff that base to the working tree,
scoped to the fix files.

## Release Verification

Provider CLI releases that ship both Malibu.app and the standalone tarball need
release-asset proof, not just green workflows:

- Compare SHA-256 byte identity between both embedded `malibu-cli`
  binaries after final signing, notarization, stapling, and packaging.
- Do not use `codesign --force --deep` to paper over nested signing.
- Verify the updater path from the previous stable version.
- Do not patch immutable public releases in place; cut a new release.

Runbook: `docs/runbooks/provider-cli-release-verification.md`.

## Boundaries

- `d-inference` is licensed NOASSERTION and is clean-room. Do not inspect its
  source.
- Never commit secrets, API keys, `.env` files, private keys, payout keys, or
  operator-only credentials.
- Keep local scratch files, editor state, and orchestration logs out of the
  tracked tree; use ignored local paths such as `scratchpad/`, `.claude/`,
  `.cursor/`, `.omc/`, or `.omx/` when a tool needs them.
- Current versions of record live in line 3 of each `specs/SPEC-NNN-*.md` and
  the `binaryVersion` constant in
  `phase3-binary/Sources/malibu-cli/CoordinatorClient.swift`; do not
  hardcode drifting versions in agent instructions.
- Production coordinator is `coordinator.malibu.tech`; public installer redirect
  is `get.malibu.tech/install.sh`.
