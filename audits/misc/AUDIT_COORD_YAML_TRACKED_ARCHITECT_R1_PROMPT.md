# Track dist/coordinator.yaml in-tree — ARCHITECT-lane audit (R1)

You are the **architect** lane of a three-lane audit of a PR that
brings the previously-gitignored production coordinator.yaml into
git history. Stay narrowly in your lane — inline-secret hunting goes
to security; YAML schema validity to code.

## Branch / commit
- Branch: `feat/coord-yaml-sync-spec026`
- Worktree root: `/Users/augstar/macprovider-coord-yaml-sync`
- Base: `origin/main` @ `dabf188`
- Files in scope:
  - `.gitignore` (removes exclusion, adds conventions comment)
  - `phase4-coordinator/dist/coordinator.yaml` (NEW to tracking)

## What this change does (operator summary — NOT the audit answer)

Moves the production coordinator config from operator-local to
tree-tracked. All secret-shaped fields already use `env:NAME`
runtime indirection, so nothing sensitive lands in git. The deploy
script's step-1b drift check now compares two known versions
instead of one known and one unknown.

## Architect-lane scope (apply each; stay in lane)

### ARCH-1. Right decision at all

Options considered:
- (a) **Leave gitignored** (status quo). Pros: fastest emergency
  config edit. Cons: no source of truth; each fresh operator must
  bootstrap by SCP from a machine that has the file; drift check
  fails-noisy first-time and needs `ALLOW_CONFIG_DRIFT=1` to
  succeed.
- (b) **Track as done here.** Pros: source of truth; every change
  auditable; deploy step 1b becomes an actual invariant, not a
  guardrail against "you forgot to SCP." Cons: emergency structural
  config changes require a PR; a bad merge could roll bad config
  live on next deploy.
- (c) **Split**: keep `dist/coordinator.yaml` gitignored, track a
  new `dist/coordinator.yaml.production` that operators diff against
  before deploy. Pros: preserves emergency-edit velocity. Cons:
  three-file drift model (tree template, tree production template,
  operator-local); one more thing to keep in sync; deploy step 1b
  needs to know which one to compare against.
- (d) **Secret-management migration**: move to SOPS-encrypted YAML
  or Vault-backed injection. Bigger scope; deferrable.

Argue which is right for this repo's current phase. Consider: single-
operator, VPS-hosted, no CI/CD for config yet, rapid SPEC iteration.

### ARCH-2. Two-file source-of-truth (yaml vs .example)

- `dist/coordinator.yaml.example` remains in the tree (235 lines,
  documentation-heavy comments).
- `dist/coordinator.yaml` (this PR) is the LIVE production config
  (166 lines).
- Options for the future:
  - Delete `.example`, `coordinator.yaml` IS the template.
  - Keep both, sync `.example` structure to match live but stay
    documentation-heavy.
  - Rename `.example` → `coordinator.yaml.annotated` and treat as
    reference documentation.
- This PR ships "keep both, don't sync `.example`". Argue whether
  that's the right scope decision or a documentation-debt burden
  the reviewer must own.

### ARCH-3. Drift-loop invariants

Once tracked, the deploy step 1b invariant is:
> tree yaml ≡ Pearl live yaml (mod secrets)

The invariant is BROKEN whenever:
- A PR lands that touches `coordinator.yaml` and the deploy hasn't
  run yet → drift check catches it on next deploy (correct).
- A hotfix env-var indirection is added on Pearl without a PR →
  drift check catches it (correct).
- Two operators land two PRs touching the same section → conflict
  or wrong-order deploy (rare, small blast radius).

Is there a scenario where the tracked-file model MASKS a real drift?
Trace: could a stale tree yaml be merged with an approved PR, then
deployed, silently rolling back a hotfix that was applied out-of-band
on Pearl? Yes — this is the same failure mode as any tracked config,
mitigated by the PR review discipline saying "before touching this
file, verify Pearl doesn't have unlanded hotfixes."

### ARCH-4. Emergency-config playbook

Ratchet: every structural coordinator.yaml change now requires a
PR. Is that the right posture for a young project? Consider:
- SPEC iterations that need a new config field ship with a
  BUILD_SPEC PR that touches Go code AND yaml — one PR, one review.
  Fine.
- Emergency mitigation (a discovered bug needs a new
  request-per-second cap TODAY) — needs a PR at 3am. Not fine.
  Should there be a documented "emergency direct-push" convention
  citing the admin bypass_mode=always ruleset for coordinator.yaml
  only?
- Env-var-shaped runtime knobs bypass this entirely — a hotfix that
  swaps `env:OPERATOR_KEY` for a new secret is a single
  `/etc/macprovider/*.env` edit + restart. No PR.

Argue whether the emergency posture is adequately covered by
existing conventions (project CLAUDE.md ruleset admin bypass note,
env: runtime indirection) or needs a new documented playbook.

### ARCH-5. Multi-operator futures

Currently single-operator (Augustas11). If a second operator joins:
- They pull tree yaml → have production config immediately. Win.
- They deploy from their machine → same content, same behavior.
  Win.
- They edit yaml locally to test → drift check catches on deploy.
  Win.
- Their Pearl deploys race with the first operator's → git-level
  conflict on merge. Manageable via normal PR workflow.

Confirm the tracked model scales to N operators without change.

### ARCH-6. Gitignore comment as convention statement

The new gitignore comment says:
> "NEVER commit an inline secret to this file — enforce env:
> indirection for every *_key / *_secret / *_token / *_password /
> *_dsn value."

- Is that comment the right place for a convention statement, or
  should it live in AGENTS.md / CONTINUE_RUNBOOK.md / a linked
  spec?
- Could a CI check enforce the "no inline secret" invariant? Sketch
  what such a check would look like (grep + allowlist for
  catalog_public_key + URL fields). Note as follow-up.

### ARCH-7. Downstream impact on tooling

- `dist/deploy-pearl-vps.sh` already normalizes+diffs; no change
  needed.
- Any CI job that runs the deploy in dry-run mode? None visible.
- Fresh-install docs (README, OPS.md) that reference "copy .example
  to coordinator.yaml and fill in" — do they need updating?

### ARCH-8. Rollback story

If this PR is merged and later found to have a wrong-value config
that only manifests under load, rollback is:
1. Revert PR + merge revert PR → tree yaml back to prior state.
2. Re-deploy → step 1b diffs revert vs live, prompts operator, ok.

Is the rollback path clean? Any state that would leak (e.g. a Pearl
env var that assumed the new yaml section exists and can't handle
its absence)?

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence architectural change>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/COORD_YAML_TRACKED_R1_ARCHITECT_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: architect lane READY TO MERGE`
