#!/usr/bin/env bash
# Fail-closed #615 stable-promotion gate against current origin/main.
# Builds durable base tombstone authority from up to 32 first-parent
# ancestors so a deletion is still visible after unrelated successor commits.
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

# Union tombstone IDs across recent first-parent history for durable anti-deletion.
python3 - "$main_sha" "$work/base-tombstones.json" <<'PY'
import json
import subprocess
import sys

main_sha = sys.argv[1]
out_path = sys.argv[2]
revs = subprocess.check_output(
    ["git", "rev-list", "-n", "32", main_sha],
    text=True,
).split()
by_id = {}
for rev in revs:
    try:
        raw = subprocess.check_output(
            ["git", "show", f"{rev}:ops/exceptions/removed-exception-tombstones.json"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        continue
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        continue
    rows = doc.get("tombstones")
    if not isinstance(rows, list):
        continue
    for row in rows:
        if isinstance(row, dict) and isinstance(row.get("id"), str) and row["id"] not in by_id:
            by_id[row["id"]] = row
doc = {
    "schema_version": "macprovider-removed-exception-tombstones-v1",
    "updated_at": "1970-01-01T00:00:00Z",
    "updated_by": "promote-history-union",
    "environment": "pearl-production",
    "tombstones": list(by_id.values()),
}
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
PY

printf 'exception-promote-gate: main=%s parent=%s history_window=32\n' "$main_sha" "${parent_sha:-none}"
python3 scripts/check-production-exceptions.py \
  --register "$work/production-exceptions.json" \
  --tombstones "$work/removed-exception-tombstones.json" \
  --base-tombstones "$work/base-tombstones.json" \
  --previous-register "$work/previous-production-exceptions.json" \
  gate --mode=promote
