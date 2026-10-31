#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# This checks the committed published catalog, whose signed runtime identity
# can precede the candidate fork. Use the actual publication's pin in an
# isolated fixture; all current canonical, generated, signed and baked bytes
# still pass the complete verifier. Production source verification is unchanged.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
GIT_NO_REPLACE_OBJECTS=1 git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$tmp"
catalog_commit="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$ROOT" log -1 --format=%H HEAD -- phase3-binary/catalog/autotune/release.json)"
GIT_NO_REPLACE_OBJECTS=1 git -C "$ROOT" show "$catalog_commit:phase3-binary/Package.resolved" \
  > "$tmp/phase3-binary/Package.resolved"
GIT_DIR="$(git -C "$ROOT" rev-parse --absolute-git-dir)" GIT_NO_REPLACE_OBJECTS=1 \
  python3 "$tmp/scripts/catalog-release.py" verify
printf 'PASS: canonical, generated, signed, and baked autotune release bytes agree\n'
