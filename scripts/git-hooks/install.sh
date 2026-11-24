#!/usr/bin/env bash
# Point this checkout's git hooks at the versioned scripts/git-hooks.
# Run once per checkout (worktrees share the main clone's config).
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
git -C "$root" config core.hooksPath scripts/git-hooks
printf 'core.hooksPath=scripts/git-hooks in %s\n' "$root"
