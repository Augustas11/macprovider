#!/usr/bin/env bash
# build-linux.sh — produce a version-stamped linux/amd64 coordinator binary.
#
# Refuses to build with uncommitted changes by default; set FORCE_DIRTY=1
# to override (the resulting binary's version string will end in "-dirty"
# via `git describe --dirty`, so the deploy gate can still tell).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${FORCE_DIRTY:-}" ]; then
  if ! git diff --quiet HEAD -- . ; then
    echo "refusing to build with uncommitted changes (set FORCE_DIRTY=1 to override)" >&2
    exit 1
  fi
fi

VERSION="$(git describe --always --dirty --tags 2>/dev/null || git rev-parse --short HEAD)"
OUT="dist/$(basename "$PWD")-linux-amd64"
mkdir -p dist
GOOS=linux GOARCH=amd64 go build -ldflags "-X main.version=${VERSION}" -o "$OUT" ./cmd/coordinator
echo "built $OUT @ ${VERSION}"
