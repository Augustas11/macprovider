# macprovider-poc — Claude session rules

## Git identity: this repo requires the Augustas11 GitHub account

The repository at `https://github.com/Augustas11/macprovider.git` is owned by
the `Augustas11` GitHub account. The user has two `gh` CLI accounts
authenticated:

- `antfleet-ops` (default for most projects; lacks write to this repo)
- `Augustas11` (required for THIS repo)

**Before any `git push` in this repo, every Claude session MUST:**

1. Check active account: `gh auth status`
2. If `antfleet-ops` is shown as active, switch: `gh auth switch -u Augustas11`
3. Push: `git push origin main`

Failure to do this produces `403: Permission to Augustas11/macprovider.git
denied to antfleet-ops` and the push is rejected. The commit is safe in
local main but origin/main does not advance.

Optionally switch back after pushing: `gh auth switch -u antfleet-ops` (so
the user's other projects keep their default).

**Commit identity** (`user.name=a11`, `user.email=augstar@gmail.com`) is
already correctly configured in this repo's `.git/config`. Do not change.

## Why the active-account check matters

The git remote uses HTTPS, and `git push` delegates HTTPS credentials to
the `gh` CLI's active account. Switching account is the cleanest fix
(per-repo credential helpers also work but are easier to misconfigure).
A future Claude session that runs `git push` without checking will
silently push under whichever account is active, fail with 403, and
leave the operator with a "why didn't this push?" mystery.

## Other repo conventions worth remembering

- Spec corpus lives in `specs/`. House style: `BUILD_SPEC_*`, `AUDIT_SPEC_*`,
  `FIX_SPEC_*_VX_Y` naming for prompts; `SPEC-NNN-*.md` for normative
  documents.
- Decision log is `beta/DECISION_CRITERIA.md`. Append entries to capture
  what was decided and why. Pattern established through Entries 1-21.
- d-inference (https://github.com/layr-labs/d-inference) is strictly
  clean-room. NOASSERTION license. Do NOT inspect their source.
- v1.2.3 is the current phase3-binary release. SPEC-001 v1.2.2,
  SPEC-002 v1.1.3, SPEC-003 v0.5 are locked. SPEC-006 v0.2 is in
  regression-audit pending.
- Production coordinator: `coordinator.streamvc.live` (Pearl VPS).
  Public installer redirect: `get.streamvc.live/install.sh`.
