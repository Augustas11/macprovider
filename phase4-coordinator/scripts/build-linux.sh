#!/usr/bin/env bash
# build-linux.sh — produce a version-stamped linux/amd64 coordinator binary.
#
# Refuses to build with uncommitted changes by default; set FORCE_DIRTY=1
# to override (the resulting binary's version string will end in "-dirty"
# via `git describe --dirty` for modified-tracked dirty, or
# "-dirty-forced" appended below for untracked-only dirty, so the deploy
# gate can still tell either way).
set -euo pipefail
cd "$(dirname "$0")/.."

# `git status --porcelain` catches BOTH modified-tracked AND untracked
# files (relative to this module's pwd). `git diff --quiet` would miss a
# new .go file dropped in by an emergency hotfix, which would then ship
# in a binary whose -ldflags-stamped version still reports "clean" via
# `git describe` (which also ignores untracked files for its --dirty
# suffix). See M0-5 Phase 1 follow-up.
DIRTY_STATE="$(git status --porcelain -- .)"
if [ -z "${FORCE_DIRTY:-}" ] && [ -n "$DIRTY_STATE" ]; then
  echo "refusing to build with uncommitted or untracked changes (set FORCE_DIRTY=1 to override)" >&2
  git status --short -- . >&2
  exit 1
fi

VERSION="$(git describe --always --dirty --tags 2>/dev/null || git rev-parse --short HEAD)"
# `git describe --dirty` only marks modifications to tracked files. If
# FORCE_DIRTY=1 overrode an UNTRACKED-only dirty state (a brand-new file
# the operator hasn't `git add`'d yet), the version stamp would otherwise
# look clean — defeating the rollback gate's ability to spot a forced
# build. Append "-dirty-forced" in that case so the binary's /healthz
# response self-identifies as an override build.
if [ -n "${FORCE_DIRTY:-}" ] && [ -n "$DIRTY_STATE" ]; then
  case "$VERSION" in
    *-dirty) ;;  # git describe already marked the modified-tracked path
    *) VERSION="${VERSION}-dirty-forced" ;;
  esac
fi

OUT="dist/coordinator-linux-amd64"
mkdir -p dist
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.version=${VERSION}" -o "$OUT" ./cmd/coordinator
echo "built $OUT @ ${VERSION}"
