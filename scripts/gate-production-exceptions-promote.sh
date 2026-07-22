#!/usr/bin/env bash
# Fail-closed #615 stable-promotion gate against current origin/main.
# Uses origin/main^ as previous/base authority so already-merged tombstone
# deletions or expiry self-extensions still fail closed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"

git fetch --no-tags origin main
main_sha="$(git rev-parse origin/main)"
parent_sha="$(git rev-parse "${main_sha}^" 2>/dev/null || true)"

work="$(mktemp -d "${TMPDIR:-/tmp}/exception-promote.XXXXXX")"
trap 'rm -rf "$work"' EXIT

git show "${main_sha}:ops/exceptions/production-exceptions.json" \
  > "$work/production-exceptions.json"

if git cat-file -e "${main_sha}:ops/exceptions/removed-exception-tombstones.json" 2>/dev/null; then
  git show "${main_sha}:ops/exceptions/removed-exception-tombstones.json" \
    > "$work/removed-exception-tombstones.json"
else
  printf '%s\n' '{"schema_version":"macprovider-removed-exception-tombstones-v1","updated_at":"1970-01-01T00:00:00Z","updated_by":"missing","environment":"pearl-production","tombstones":[]}' \
    > "$work/removed-exception-tombstones.json"
fi

if [ -n "$parent_sha" ] && git cat-file -e "${parent_sha}:ops/exceptions/production-exceptions.json" 2>/dev/null; then
  git show "${parent_sha}:ops/exceptions/production-exceptions.json" \
    > "$work/previous-production-exceptions.json"
else
  cp "$work/production-exceptions.json" "$work/previous-production-exceptions.json"
fi

if [ -n "$parent_sha" ] && git cat-file -e "${parent_sha}:ops/exceptions/removed-exception-tombstones.json" 2>/dev/null; then
  git show "${parent_sha}:ops/exceptions/removed-exception-tombstones.json" \
    > "$work/base-tombstones.json"
else
  printf '%s\n' '{"schema_version":"macprovider-removed-exception-tombstones-v1","updated_at":"1970-01-01T00:00:00Z","updated_by":"missing","environment":"pearl-production","tombstones":[]}' \
    > "$work/base-tombstones.json"
fi

printf 'exception-promote-gate: main=%s parent=%s\n' "$main_sha" "${parent_sha:-none}"
python3 scripts/check-production-exceptions.py \
  --register "$work/production-exceptions.json" \
  --tombstones "$work/removed-exception-tombstones.json" \
  --base-tombstones "$work/base-tombstones.json" \
  --previous-register "$work/previous-production-exceptions.json" \
  gate --mode=promote
