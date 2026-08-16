# macprovider-poc — Claude session rules

## Git identity: pushes route to Augustas11 automatically (per-repo helper)

The repository at `https://github.com/Augustas11/macprovider.git` is owned
by the `Augustas11` GitHub account. The user has two `gh` CLI accounts
authenticated:

- `antfleet-ops` (default for most projects; lacks write to this repo)
- `Augustas11` (required for THIS repo)

**Pushes from this repo route to `Augustas11` automatically.** A per-repo
credential helper in `.git/config` invokes `gh auth token -u Augustas11`
at push time, regardless of which gh account is currently active. So a
plain `git push origin main` just works.

You do **not** need to:

- Run `gh auth switch -u Augustas11` before pushing
- Use URL-embedded tokens (`https://Augustas11:$TOK@github.com/...`)
- Check `gh auth status` first

The helper config lives in `.git/config` (local, not replicated by clone):

```
[credential "https://github.com/Augustas11/macprovider.git"]
    username = Augustas11
    helper =
    helper = "!f() { test \"$1\" = get && printf \"username=Augustas11\\npassword=%s\\n\" \"$(gh auth token -u Augustas11)\"; }; f"
```

**Commit identity** (`user.name=a11`, `user.email=augstar@gmail.com`) is
already configured in this repo's `.git/config`. Do not change.

## If the routing ever fails (restore steps)

The helper lives in `.git/config`, which is local-only — a fresh
`git clone` of this repo does NOT carry it. If `git push` from this
repo ever returns `403: Permission to Augustas11/macprovider.git denied
to antfleet-ops`, the helper was never installed or got clobbered.
Restore with:

```bash
git config --local --add "credential.https://github.com/Augustas11/macprovider.git.helper" ""
git config --local --add "credential.https://github.com/Augustas11/macprovider.git.helper" '!f() { test "$1" = get && printf "username=Augustas11\npassword=%s\n" "$(gh auth token -u Augustas11)"; }; f'
git config --local "credential.https://github.com/Augustas11/macprovider.git.username" Augustas11
```

One-shot bypass while the helper is missing (no config changes):

```bash
git push "https://Augustas11:$(gh auth token -u Augustas11)@github.com/Augustas11/macprovider.git" main
```

## Why the helper exists (and not just `credential.<url>.username`)

The git remote uses HTTPS, which delegates auth to `gh`. By default,
`gh auth git-credential` returns the *active* gh account's token and
silently ignores any `username` hint git tries to send (verified
empirically against `gh 2.83.2` — when asked with `username=Augustas11`
it returns empty rather than the matching account's token). So pinning
`credential.<url>.username = Augustas11` alone is not enough; the helper
must explicitly call `gh auth token -u Augustas11` to bypass gh's
active-account state.

## Worktree isolation: don't edit the canonical checkout

For any implementation, audit, release, or other write-heavy task in this
repo, do not work directly in `/Users/augstar/macprovider-poc`. Start from a
fresh sibling worktree off the intended base, usually `origin/main`, unless the
user explicitly says to use the current checkout:

```bash
git status -sb
git worktree list
git fetch origin
git worktree add ../macprovider-<topic> -b fix/<topic> origin/main
cd ../macprovider-<topic>
```

Do all edits, tests, commits, pushes, PR work, and merge follow-up inside that
task worktree. Do not reuse or mutate another active session's branch/worktree
silently. For audits, start from `origin/main` and audit merged code unless the
user names a different base.

## PR workflow: don't develop on local `main`

Money-path and security-sensitive changes (billing, payouts, gateway,
coordinator auth) go through PRs in this repo, not direct push (origin
commit `9bd77f4 Close audited billing and idempotency gaps` is one such
PR). GitHub's **squash-merge** produces a single new commit on
`origin/main` containing the diff of all your PR-branch commits, plus
any review-round additions.

If you developed on local `main` instead of a feature branch, your
local `main` keeps the original individual commits while `origin/main`
has the squashed equivalent under a different hash. Git sees this as
two divergent branches modifying the same lines, and the next push,
rebase, or merge **will conflict**.

**Rule: always work on a feature branch in this repo.**

```bash
# Start any change
git fetch origin
git checkout -b fix/<topic> origin/main

# Commit, push, open PR
git push -u origin fix/<topic>
gh pr create

# After PR squash-merges on GitHub
git checkout main
git fetch origin
git reset --hard origin/main          # mirror origin, discard local PR commits
git branch -D fix/<topic>             # delete the dead PR branch
```

The `reset --hard origin/main` after each PR is the step most people
miss. It is what keeps local `main` from becoming a parallel-universe
copy of code that already exists on origin under a different hash.

### If you inherit a divergent local main

Symptoms:

- `git push origin main` returns non-fast-forward
- `git log origin/main..HEAD` shows local commits that author-overlap
  with recent origin commits on the same files
- Rebase or merge produces conflicts where the same author appears on
  both sides of `<<<<<<< HEAD` / `>>>>>>> origin/main` markers

In priority order:

1. **Verify equivalence, then reset.** Pick an overlapping file (e.g.
   `phase4-coordinator/internal/billing/formula.go`) and run
   `git diff origin/main HEAD~N -- <file>`. If empty, the local commits
   are stale duplicates of a squashed origin commit. Backup first:
   `git branch backup-pre-sync HEAD`. Then `git reset --hard origin/main`.
2. **Merge and prefer origin** when origin has review-round work local
   does not. `git merge origin/main`, resolve conflicts with
   `git checkout --theirs <file>` for each conflict (origin = local
   work + review additions in this pattern). Build + test both modules
   (`phase4-coordinator`, `phase5-gateway`) before sealing.
3. **Stop and ask the user** if the relationship between the two sides
   is not clear from commit messages and file diffs. Never guess on
   money-path code.

Never `git push --force` to make local "win" — it discards origin's
review-round additions, which often include security/billing fixes.

### Reference event (2026-06-04)

We inherited a 14-commit local-main divergence against origin commit
`9bd77f4 Close audited billing and idempotency gaps`. The 14 commits
were the original PR-branch commits left behind on local main after
the squash-merge. Resolved via merge + `--theirs`, preserving local
intent and bringing in the idempotency-key feature added during
review. Backup branch `backup-main-pre-merge-20260604` preserves the
pre-merge tip in case of regression.

## PR governance declaration gate (don't panic when it's red)

Every PR runs the `spec-index` workflow's `check` job
(`scripts/check_spec_pr_declaration.py`), which requires the **PR body** to
contain exactly one `SPEC-GOVERNANCE-DECLARATION-BEGIN` /
`SPEC-GOVERNANCE-DECLARATION-END` block wrapping a
`schema_version: "spec-pr-governance-v1"` JSON payload. Omit it and that
job goes red with `PR body must contain exactly one ...DECLARATION-BEGIN/END`.

**This `check` is advisory, not a merge blocker.** The `main` ruleset
requires only the **`ci-required`** status context (the aggregation job at
the bottom of `.github/workflows/ci.yml`; it does *not* `needs:` spec-index)
plus **1 approving review**. A red `spec-index / check` does not block merge.

Fill the block honestly when a spec fits (real example, PR #713):

```
SPEC-GOVERNANCE-DECLARATION-BEGIN
{
  "schema_version": "spec-pr-governance-v1",
  "behavior_change": "yes",          // "none" or "yes"
  "contract_change": "none",         // "yes" if you touch AUTHORITY.json,
                                     // CONFORMANCE.json, or a canonical SPEC-NNN
  "specs": ["SPEC-020"],
  "requirements": ["SPEC-020-R001"],
  "authority_domains": ["provider-autoupdate"],
  "arbitration": ["CODE_BUG"],
  "tests": ["scripts/test-catalog-release.sh"],
  "journeys": ["not-required"],
  "issue": "https://github.com/Augustas11/macprovider/issues/608"
}
SPEC-GOVERNANCE-DECLARATION-END
```

Rules: `behavior_change: "none"` is allowed **only** for governance-only
paths (`specs/**`, the `check_spec_*`/`gen_spec_index` scripts,
`schemas/spec-*`, `.github/CODEOWNERS`, `.github/workflows/spec-index.yml`,
`beta/DECISION_CRITERIA.md`, `docs/spec-governance-foundation.md`,
`docs/spec-history/**`). Any **other** changed path is "non-governance" and
rejects `"none"` — it must be `"yes"` with ≥1 each of specs / requirements /
authority_domains / arbitration / tests / journeys, all validated against
`specs/AUTHORITY.json` and `specs/CONFORMANCE.json`.

**Infra/CI-only PRs (e.g. a `ci.yml` tweak) have no honest declaration:**
`ci.yml` is a non-governance path but no authority domain governs CI, so
`"none"` is rejected and `"yes"` has no real spec to cite. Do **not**
fabricate a spec link. Either merge past the advisory red (state in the PR
body that `check` is non-required) or bundle the CI change into a
spec-linked PR (how #713 shipped its `ci.yml` edit). Do not relax `ci.yml`
into the governance-only allowlist to dodge this — that regime looks
deliberate.

## Release verification: workflow green is not production proof

For every provider CLI release that ships both a standalone provider tarball
and Malibu.app, the release contract is the installer/updater contract, not
just GitHub Actions success.

Rules:

1. The `macprovider-cli` inside Malibu.app must be byte-identical to the
   `macprovider-cli` inside the standalone provider tarball after all signing,
   notarization, stapling, and packaging steps. Compare SHA-256 bytes, not
   only `--version`, codesign requirement text, Gatekeeper, or notarization.
2. Do not use recursive app signing (`codesign --force --deep`) on a bundle
   after copying in the already-signed standalone provider CLI. Sign nested
   code explicitly first, sign the outer app without `--deep`, then verify the
   app with `codesign --verify --deep`.
3. Do not mark a release production-verified until the updater path from the
   previous stable version accepts it. `embedded_cli_mismatch` is a correct
   fail-closed updater rejection, not a warning to bypass.
4. Candidate workflow green is only candidate evidence. Final release proof
   must come from immutable release assets after publication/download, with
   signatures/checksums verified and the updater invariant exercised.
5. If a public immutable release violates these invariants, do not patch the
   release in place. Keep coordinator recommendation on the previous stable
   version and cut a new release with matching artifacts.

Keep product-specific smoke tests separate from release packaging proof. For
example, Buzz/null-tool-schema verification proves the product fix; it does
not prove the updater or Malibu packaging invariants above.

Runbook: `docs/runbooks/provider-cli-release-verification.md`.

## Other repo conventions worth remembering

- Every implementation slice must pass the audit loop before being treated as
  done. This applies to full implementations and step/deliverable/checkpoint
  implementations alike: run the three Codex audit lanes (code, security,
  architect) and keep fixing/re-auditing until all three report 0 CRITICAL,
  0 HIGH, and 0 MEDIUM findings. LOW/INFO findings may be carried explicitly.
- Spec corpus lives in `specs/`. House style: `BUILD_SPEC_*`, `AUDIT_SPEC_*`,
  `FIX_SPEC_*_VX_Y` naming for prompts; `SPEC-NNN-*.md` for normative
  documents.
- Decision log is `beta/DECISION_CRITERIA.md`. Append entries to capture
  what was decided and why. Pattern established through Entries 1-21.
- d-inference (https://github.com/layr-labs/d-inference) is strictly
  clean-room. NOASSERTION license. Do NOT inspect their source.
- Current versions of record: line 3 of each `specs/SPEC-NNN-*.md`,
  and the `binaryVersion` constant in
  `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`. Do
  not hardcode versions in this file — they drift; the spec headers
  and the constant do not. See also `specs/README.md` for a generated
  index (also subject to drift, source of truth is each spec header).
- Production coordinator: `coordinator.malibu.tech` (Pearl VPS).
  Public installer redirect: `get.malibu.tech/install.sh`.
