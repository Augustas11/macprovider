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
