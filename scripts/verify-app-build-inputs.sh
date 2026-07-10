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
  phase3-binary/app/Package.resolved
)

for relative in "${paths[@]}"; do
  path="$repo_root/$relative"
  [[ -f "$path" && ! -L "$path" ]] || die "reviewed build input is not a regular file: $relative"
  git -C "$repo_root" cat-file -e "$commit:$relative" || die "reviewed commit omits $relative"
  git -C "$repo_root" show "$commit:$relative" | cmp -s - "$path" ||
    die "working-tree bytes differ from reviewed commit: $relative"
done

python3 - "$repo_root/phase3-binary/Package.resolved" \
  "$repo_root/phase3-binary/app/Package.resolved" \
  "$repo_root/phase3-binary/app/project.yml" <<'PY'
import json
import pathlib
import re
import sys

cli_path, app_path, project_path = map(pathlib.Path, sys.argv[1:])
for path in (cli_path, app_path):
    resolved = json.loads(path.read_text(encoding="utf-8"))
    pins = resolved.get("pins")
    if resolved.get("version") not in (2, 3) or not isinstance(pins, list) or not pins:
        raise SystemExit(f"invalid SwiftPM resolution file: {path}")
    for pin in pins:
        state = pin.get("state") if isinstance(pin, dict) else None
        if not isinstance(state, dict) or not re.fullmatch(r"[0-9a-f]{40}", state.get("revision", "")):
            raise SystemExit(f"unpinned SwiftPM revision in {path}")

app = json.loads(app_path.read_text(encoding="utf-8"))
if len(app["pins"]) != 1:
    raise SystemExit("Malibu Package.resolved must contain only Sparkle")
sparkle = app["pins"][0]
if (
    sparkle.get("identity") != "sparkle"
    or sparkle.get("location") != "https://github.com/sparkle-project/Sparkle"
    or sparkle.get("state") != {
        "revision": "0ef1ee0220239b3776f433314515fd849025673f",
        "version": "2.6.4",
    }
):
    raise SystemExit("Malibu Sparkle resolution differs from reviewed 2.6.4 revision")

project = project_path.read_text(encoding="utf-8")
if "exactVersion: 2.6.4" not in project or re.search(r"^\s+from:\s*", project, re.MULTILINE):
    raise SystemExit("project.yml must use the exact Sparkle version")
PY

printf '[verify-app-build-inputs] ok: reviewed SwiftPM and app generator inputs match %s\n' "$commit"
