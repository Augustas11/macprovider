#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-app-build-inputs] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ ( "$#" == 1 || "$#" == 2 ) && "$1" =~ ^[0-9a-f]{40}$ ]] ||
  die "usage: REVIEWED_COMMIT [CHECKOUT_ROOT]"
commit="$1"
# An explicit checkout root lets a trusted (main-owned) copy of this verifier
# check an untrusted candidate checkout without executing candidate code.
if [[ "$#" == 2 ]]; then
  checkout_root="$2"
  # Strip trailing slashes first: `-L link/` tests the target, not the link.
  while [[ "$checkout_root" == */ && "$checkout_root" != / ]]; do
    checkout_root="${checkout_root%/}"
  done
  [[ -d "$checkout_root" && ! -L "$checkout_root" ]] ||
    die "checkout root is not a directory: $2"
  repo_root="$(cd "$checkout_root" && pwd -P)"
else
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fi
paths=(
  phase3-binary/Package.resolved
  phase3-binary/app/project.yml
)

reviewed_copy="$(mktemp "${TMPDIR:-/tmp}/verify-app-build-inputs.XXXXXX")"
trap 'rm -f "$reviewed_copy"' EXIT

for relative in "${paths[@]}"; do
  path="$repo_root/$relative"
  [[ -f "$path" && ! -L "$path" ]] || die "reviewed build input is not a regular file: $relative"
  git -C "$repo_root" cat-file -e "$commit:$relative" || die "reviewed commit omits $relative"
  git -C "$repo_root" show "$commit:$relative" >"$reviewed_copy" ||
    die "cannot read $relative from reviewed commit"
  cmp -s "$reviewed_copy" "$path" ||
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
