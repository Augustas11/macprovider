# MacProvider Agent Guide

This file is the canonical instruction surface for every coding agent in this
repository. Keep it short, concrete, and current. Put long incident writeups in
docs or runbooks and link them from here.

## HARDEST RULE — no options, always implement the goal

Never present the operator with two or more options, an either/or menu, or a
"proceed vs hold" question. Do not stop to ask which path to take. Pick the
single best path toward the stated goal and implement it directly. If a
prerequisite is genuinely blocking (missing access, a hard permission denial),
do everything possible around it, then surface the one specific unblock needed —
never as a menu. Analysis and status are fine; decision-shaped menus are not.

## HARD RULES — activation, evidence, and campaign discipline

These exist because native MTP and CB sat qualified-but-inactive for a week
while sessions regenerated evidence instead of deploying. Each is binding.

1. **Done means live.** A task whose goal is "X active" is done only when a
   live probe shows X serving a real buyer request through the Malibu gateway.
   Merge is not done. A PR that changes catalog, CB, or native-MTP state must
   name its deploy command in the body, and the merging session deploys it the
   same day.
2. **Reuse evidence; never regenerate it.** Before proposing any benchmark,
   qualification, journey, or evidence capture, list the existing evidence and
   name the decode-path code line that changed since it was produced. No named
   line, no benchmark. A new CLI cut changes only identity binding (source,
   SHA-256, CDHash), never the qualification.
3. **Unclearable gates get flagged once.** If a runbook gate depends on a
   workflow or journey that has never run, report it to the operator in one
   line on first encounter. Do not build evidence around it and do not treat
   it as blocking after the operator has decided.
4. **One campaign, one PR.** Before `gh pr create`, run
   `gh pr list --state open --search "<issue or epic number>"`. If an open PR
   exists for that issue or epic, push to it.
5. **Deploy-tooling refusals are fixed, not routed around.** If release or
   deploy tooling refuses a coherent change, fix the tooling in the campaign
   PR or follow its documented order. Never answer a refusal with more
   evidence.
6. **Two sessions without a live change means stop.** Write a one-paragraph
   blocker diagnosis to the operator instead of starting a third session.
7. **Handoffs are committed and point at paths that exist.** One session at a
   time mutates Pearl or a Studio provider. Handback is written, naming what
   changed live.
8. **Releases and live changes go through `scripts/ops/` only.** CLI release,
   catalog/CB/native-MTP activation and the Pearl runtime train each have one
   entry point (`cli-release.sh`, `catalog-activate.sh`, `pearl-runtime.sh`).
   Run `status`, then `next`; `next --run` executes exactly one documented
   step and takes the live-ops lock (`live-lock.sh`). Never call the release
   workflows, `deploy-pearl-vps.sh`, `catalog-content-release.sh --deploy`,
   the Pearl updater `--apply`, or a coordinator restart directly. Claude Code
   enforces this with `scripts/ops/hooks/claude-pretooluse-ops-guard.sh`;
   other agents follow it from this rule. See `scripts/ops/README.md`.
9. **No closing keyword next to an issue number** (the close/fix/resolve
   family, any tense, even negated) in a PR body, title or commit message
   unless that PR completes the issue. Write `Related: #N`. GitHub ignores
   negation; that is how the #1690 and #1749 epics were auto-closed early.
10. **No expiry dates on live features.** Never add an expiry, sunset date,
    automatic withdrawal or automatic kill switch to a live product feature,
    its config validation, ops tooling, SPEC or decision log unless the
    operator explicitly asks for one. A feature that works live stays on. If a
    process document demands an expiry, flag it to the operator as a rule to
    remove instead of complying.
11. **Proven changes ship on.** When lab evidence shows a change works
    (correctness checks pass and the gain is measured) and its audit is
    clean, it ships enabled by default in the same PR. Do not add a
    default-off flag or a separate operator enable gate for it. Handle risk
    in the code itself (caps, bounds, fallbacks) and keep an emergency kill
    switch where one already exists. Signed catalog/CB/native-MTP policy is
    deployment state, not a default-off gate; changing it still goes through
    `scripts/ops/`.

## Project Overview

MacProvider turns Apple Silicon Macs into remote-addressable MLX inference
providers behind Malibu-branded buyer and provider surfaces. The repo includes
the Swift provider CLI/app, Go coordinator and gateway services, verification
tools, specs, release scripts, and operational runbooks.

Read the nearest implementation files before editing; many behavior changes are
governed by `specs/AUTHORITY.json`, `specs/CONFORMANCE.json`, and the matching
`specs/SPEC-NNN-*.md`.

## Project Structure

- `phase3-binary/` - Swift package for `macprovider-cli`, Malibu.app assets,
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

A **hardware campaign** (Studio / real-Mac e2e) is one task: one draft PR,
local `swift build -c release` on the box, isolated loopback, iterate by
commit, audit once at freeze, merge once, then one signed CLI cut. Do not
open a new PR per e2e finding. Runbook:
`docs/runbooks/lab-campaign-loop.md`. Cursor rule:
`.cursor/rules/lab-campaign-loop.mdc`. The Pearl serial-ship rule does
**not** apply to these campaigns. Auto-merge-when-CI-green does **not**
apply until the campaign PR is ready and the lab e2e listed in its body
PASSed.

Money-path, auth, gateway, coordinator, CI, schema, and executable
changes go through PR review. Hardware campaigns (code + Studio e2e) also
go through one campaign PR; see above.

**All docs-only work goes straight to `origin/main`.** Do not open a PR.
Do not wait for CI. Docs do not change a binary, a contract, or buyer
behavior, so a review+CI queue is wasted time. GitHub may still run
workflows on the `main` push; that is not a land gate.

Docs-only means markdown and agent-instruction files:

- `docs/` (runbooks, research, release-train narrative)
- `AGENTS.md`, `CLAUDE.md`
- `.cursor/rules/`
- `audits/` markdown (prompts, evidence writeups)
- `beta/` narrative markdown that does not flip a runtime default

The tree must be clean, local `main` must match `origin/main`, then commit
and `git push origin HEAD:main`.

Still a PR: `phase3-binary/`, `phase4-coordinator/`, `phase5-gateway/`,
`phase7-verify/`, executable `scripts/`, `test/`, `specs/` (including
`SPEC-*.md`, `AUTHORITY.json`, `CONFORMANCE.json`), schemas,
`.github/workflows/`, catalog, rate-card, `coordinator.yaml`, installer
bytes. A mixed change is a PR. Do not smuggle code into a docs push.

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

Skip this section for docs-only pushes to `main`.

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
honestly; do not fabricate specs or requirements to satisfy the checker. The
`spec-index` job in `ci.yml` is part of `ci-required`; treat it red as blocking.

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

- Compare SHA-256 byte identity between both embedded `macprovider-cli`
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
  `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`; do not
  hardcode drifting versions in agent instructions.
- Production coordinator is `coordinator.malibu.tech`; public installer redirect
  is `get.malibu.tech/install.sh`.
- Before ANY Pearl coordinator change (runtime apply, catalog activation,
  config edit), read `docs/runbooks/pearl-coordinator-rollout.md` and state the
  expected downtime to the operator before starting.
