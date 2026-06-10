#!/usr/bin/env bash
# build-linux.sh — produce a version-stamped linux/amd64 gateway binary.
#
# Refuses to build with uncommitted changes by default; set FORCE_DIRTY=1
# to override (the resulting binary's version string will end in "-dirty"
# via `git describe --dirty`, so the deploy gate can still tell).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${FORCE_DIRTY:-}" ]; then
  # `git status --porcelain` catches BOTH modified-tracked AND untracked
  # files (relative to this module's pwd). `git diff --quiet` would miss a
  # new .go file dropped in by an emergency hotfix, which would then ship
  # in a binary whose -ldflags-stamped version still reports "clean" via
  # `git describe` (which also ignores untracked files for its --dirty
  # suffix). See M0-5 Phase 1 follow-up.
  if [ -n "$(git status --porcelain -- .)" ]; then
    echo "refusing to build with uncommitted or untracked changes (set FORCE_DIRTY=1 to override)" >&2
    git status --short -- . >&2
    exit 1
  fi
fi

VERSION="$(git describe --always --dirty --tags 2>/dev/null || git rev-parse --short HEAD)"
OUT="dist/$(basename "$PWD")-linux-amd64"
mkdir -p dist
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.version=${VERSION}" -o "$OUT" ./cmd/gateway
echo "built $OUT @ ${VERSION}"
