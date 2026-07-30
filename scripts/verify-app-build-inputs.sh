#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-app-build-inputs] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 1 && "$1" =~ ^[0-9a-f]{40}$ ]] || die "usage: REVIEWED_COMMIT"
commit="$1"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
paths=(
  phase3-binary/Package.resolved
  phase3-binary/app/project.yml
)

for relative in "${paths[@]}"; do
  path="$repo_root/$relative"
  [[ -f "$path" && ! -L "$path" ]] || die "reviewed build input is not a regular file: $relative"
  git -C "$repo_root" cat-file -e "$commit:$relative" || die "reviewed commit omits $relative"
  git -C "$repo_root" show "$commit:$relative" | cmp -s - "$path" ||
    die "working-tree bytes differ from reviewed commit: $relative"
done

python3 - "$repo_root/phase3-binary/Package.resolved" \
  "$repo_root/phase3-binary/app/project.yml" <<'PY'
import json
import pathlib
import re
import sys

cli_path, project_path = map(pathlib.Path, sys.argv[1:])
resolved = json.loads(cli_path.read_text(encoding="utf-8"))
pins = resolved.get("pins")
if resolved.get("version") not in (2, 3) or not isinstance(pins, list) or not pins:
    raise SystemExit(f"invalid SwiftPM resolution file: {cli_path}")
for pin in pins:
    state = pin.get("state") if isinstance(pin, dict) else None
    if not isinstance(state, dict) or not re.fullmatch(r"[0-9a-f]{40}", state.get("revision", "")):
        raise SystemExit(f"unpinned SwiftPM revision in {cli_path}")
project = project_path.read_text(encoding="utf-8")
if "Sparkle" in project or re.search(r"^packages:\s*", project, re.MULTILINE):
    raise SystemExit("Malibu must remain dependency-free; the CLI owns updates")
PY

printf '[verify-app-build-inputs] ok: reviewed SwiftPM and app generator inputs match %s\n' "$commit"
