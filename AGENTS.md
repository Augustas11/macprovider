# AGENTS.md — for AI agents working on this repo

This repo's full agent rules live in [`CLAUDE.md`](./CLAUDE.md). The
rules there apply to **any** AI coding agent operating in this
repository (Claude, Codex, Cursor, etc.), not just Claude. Read
`CLAUDE.md` before writing or pushing code.

The most important rules, in priority order:

## 1. PR workflow — never develop on local `main`

Money-path and security-sensitive changes (billing, payouts, gateway,
coordinator auth) go through PRs. GitHub squash-merge produces a new
single commit on `origin/main` with a different hash from your
PR-branch commits. If you commit directly to local `main`, you create
a parallel-universe divergence that will conflict on the next push.

Always work on a feature branch. After your PR squash-merges, run
`git reset --hard origin/main` to mirror origin and discard the local
PR-branch commits. See `CLAUDE.md` § *PR workflow* for the full
sequence and recovery steps for inheriting a divergent local main.

## 2. Git identity — pushes route to `Augustas11` automatically

A per-repo credential helper in `.git/config` calls `gh auth token
-u Augustas11` at push time, regardless of which `gh` account is
currently active. A plain `git push origin main` just works. Do **not**
manually switch accounts; do **not** embed tokens in URLs. See
`CLAUDE.md` § *Git identity* for restore steps if the helper is ever
missing (e.g. after a fresh clone).

## 3. Sensitive paths require PR

These directories carry money or auth logic and any change to them
must go through a PR with review:

- `phase4-coordinator/internal/billing/`
- `phase4-coordinator/internal/buyer/`
- `phase4-coordinator/internal/auth/`
- `phase4-coordinator/internal/requestlog/`
- `phase5-gateway/internal/router/`
- `phase5-gateway/internal/auth/`

## 4. Clean-room boundary

`d-inference` (https://github.com/layr-labs/d-inference) is licensed
NOASSERTION and is strictly clean-room. Do **not** inspect their
source under any circumstance.

## 5. Spec and decision-log conventions

- Specs live under `specs/`. House style: `BUILD_SPEC_*`,
  `AUDIT_SPEC_*`, `FIX_SPEC_*_VX_Y` for prompts; `SPEC-NNN-*.md` for
  normative documents.
- Decision log is `beta/DECISION_CRITERIA.md`. Append entries to
  capture what was decided and why.

For the canonical, full version of every rule above, see `CLAUDE.md`.
