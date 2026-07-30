#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[install-pinned-xcodegen] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 1 ]] || die "usage: DESTINATION"
destination="$1"
[[ "$destination" == /* ]] || die "destination must be absolute"
[[ ! -e "$destination" && ! -L "$destination" ]] || die "destination already exists"

readonly version=2.45.4
readonly archive_sha256=090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef
readonly archive_url="https://github.com/yonaskolb/XcodeGen/releases/download/${version}/xcodegen.zip"
temporary="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xcodegen-pinned.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
archive="$temporary/xcodegen.zip"

curl -fsSL --proto '=https' --tlsv1.2 -o "$archive" "$archive_url"
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$archive_sha256" ]] || die "XcodeGen archive digest mismatch"

python3 - "$archive" <<'PY'
import pathlib
import stat
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(archive) as source:
    for row in source.infolist():
        path = pathlib.PurePosixPath(row.filename)
        mode = row.external_attr >> 16
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe XcodeGen archive path: {row.filename}")
        if stat.S_ISLNK(mode):
            raise SystemExit(f"symlinked XcodeGen archive member: {row.filename}")
PY

mkdir "$destination"
unzip -q "$archive" -d "$destination"
binary="$destination/xcodegen/bin/xcodegen"
[[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || die "pinned XcodeGen binary is absent"
"$binary" --version | grep -Fxq "Version: $version" || die "XcodeGen binary version mismatch"
printf '%s\n' "$binary"
