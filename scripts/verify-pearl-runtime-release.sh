#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/verify-pearl-runtime-release.sh --tag vX.Y.Z --expected-commit SHA [options]

Verifies that a release tag is suitable for Pearl runtime rollout before
running macprovider-pearl-update or deploy-pearl-vps.sh.

Options:
  --tag TAG                 release tag, vX.Y.Z
  --expected-commit SHA      exact reviewed source commit expected for the release
  --repository OWNER/REPO    GitHub repository (default: Augustas11/macprovider)
  --remote REMOTE            git remote used for tag-target verification (default: origin)
  --release-dir DIR          verify a local release asset directory instead of GitHub

This is a preflight only. It checks source identity and the Pearl runtime asset
set; macprovider-pearl-update remains the authority for signature verification,
transactional apply, rollback, and live serving gates.
EOF
}

die() {
  printf '[verify-pearl-runtime-release] ERROR: %s\n' "$*" >&2
  exit 1
}

tag=""
expected_commit=""
repository="Augustas11/macprovider"
remote="origin"
release_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --expected-commit)
      expected_commit="${2:-}"
      shift 2
      ;;
    --repository)
      repository="${2:-}"
      shift 2
      ;;
    --remote)
      remote="${2:-}"
      shift 2
      ;;
    --release-dir)
      release_dir="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  usage
  die "--tag must be vX.Y.Z"
}
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || {
  usage
  die "--expected-commit must be a full lowercase commit SHA"
}
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repository must be OWNER/REPO"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$root/scripts/verify-release-tag-target.sh" \
  "$tag" "$expected_commit" "$remote" --require-existing >/dev/null

required_assets=(
  pearl-release.json
  pearl-release.json.sig
  checksums.txt
  checksums.txt.sig
  coordinator-linux-amd64
  coordinator-cli-linux-amd64
  gateway-linux-amd64
  release.json
  trusted-keys.json
  tier2-catalog.json
  autotune-candidates.json
  autotune-candidates.json.sig
  demand-rank.json
  demand-rank.json.sig
)

validate_release_dir() {
  local directory="$1"
  [[ -d "$directory" ]] || die "release directory does not exist: $directory"
  local missing=()
  local asset
  for asset in "${required_assets[@]}"; do
    [[ -f "$directory/$asset" ]] || missing+=("$asset")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "missing Pearl runtime release asset(s): ${missing[*]}"
  fi
  PEARL_RELEASE_DIR="$directory" \
  PEARL_RELEASE_TAG="$tag" \
  PEARL_RELEASE_EXPECTED_COMMIT="$expected_commit" \
  PEARL_RELEASE_REPOSITORY="$repository" \
  PEARL_RELEASE_REQUIRED_ASSETS="$(printf '%s\n' "${required_assets[@]}")" \
    python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import re
import sys


def fail(message: str) -> None:
    print(f"[verify-pearl-runtime-release] ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


directory = pathlib.Path(os.environ["PEARL_RELEASE_DIR"])
tag = os.environ["PEARL_RELEASE_TAG"]
expected_commit = os.environ["PEARL_RELEASE_EXPECTED_COMMIT"]
repository = os.environ["PEARL_RELEASE_REPOSITORY"]
required_assets = [line for line in os.environ["PEARL_RELEASE_REQUIRED_ASSETS"].splitlines() if line]

try:
    metadata = json.loads((directory / "pearl-release.json").read_text(encoding="utf-8"))
except Exception as exc:
    fail(f"pearl-release.json is not valid JSON: {exc}")

if not isinstance(metadata, dict) or metadata.get("schema_version") != 1:
    fail("pearl-release.json has unsupported schema")
if metadata.get("repository") != repository:
    fail(f"pearl-release.json repository is {metadata.get('repository')!r}, expected {repository!r}")
if metadata.get("tag") != tag:
    fail(f"pearl-release.json tag is {metadata.get('tag')!r}, expected {tag!r}")
if metadata.get("commit") != expected_commit:
    fail(f"pearl-release.json commit is {metadata.get('commit')!r}, expected {expected_commit!r}")
if metadata.get("architecture") != "linux-amd64":
    fail("pearl-release.json architecture must be linux-amd64")
version = tag.removeprefix("v")
if metadata.get("release_version") != version:
    fail("pearl-release.json release_version does not match the tag")
if metadata.get("provider_advertised_version") != version:
    fail("pearl-release.json provider_advertised_version does not match the tag")

components = metadata.get("components")
if not isinstance(components, dict):
    fail("pearl-release.json components are missing")

component_assets = {
    "coordinator": "coordinator-linux-amd64",
    "gateway": "gateway-linux-amd64",
}
sha_re = re.compile(r"^[0-9a-f]{64}$")
for name, asset in component_assets.items():
    row = components.get(name)
    if not isinstance(row, dict) or row.get("asset") != asset:
        fail(f"pearl-release.json {name} component does not bind {asset}")
    digest = row.get("sha256")
    if not isinstance(digest, str) or not sha_re.fullmatch(digest):
        fail(f"pearl-release.json {name} sha256 is invalid")
    actual = hashlib.sha256((directory / asset).read_bytes()).hexdigest()
    if actual != digest:
        fail(f"{asset} sha256 does not match pearl-release.json")

checksums = {}
for raw in (directory / "checksums.txt").read_text(encoding="utf-8").splitlines():
    parts = raw.strip().split()
    if len(parts) != 2:
        continue
    digest, name = parts
    name = name.removeprefix("*")
    if sha_re.fullmatch(digest):
        checksums[name] = digest

for asset in required_assets:
    if asset in {"checksums.txt", "checksums.txt.sig"}:
        continue
    digest = checksums.get(asset)
    if digest is None:
        fail(f"checksums.txt omits required Pearl runtime asset: {asset}")
    actual = hashlib.sha256((directory / asset).read_bytes()).hexdigest()
    if actual != digest:
        fail(f"checksums.txt digest mismatch for {asset}")

catalog = metadata.get("catalog")
if not isinstance(catalog, dict):
    fail("pearl-release.json catalog metadata is missing")
catalog_files = catalog.get("files")
expected_catalog_assets = {
    "release.json",
    "trusted-keys.json",
    "tier2-catalog.json",
    "autotune-candidates.json",
    "autotune-candidates.json.sig",
    "demand-rank.json",
    "demand-rank.json.sig",
}
if set(catalog_files if isinstance(catalog_files, dict) else ()) != expected_catalog_assets:
    fail("pearl-release.json catalog file set is invalid")

print(f"[verify-pearl-runtime-release] ok: {tag} has Pearl runtime assets for {expected_commit}")
PY
}

if [[ -n "$release_dir" ]]; then
  validate_release_dir "$release_dir"
  exit 0
fi

command -v gh >/dev/null 2>&1 || die "gh CLI is required unless --release-dir is provided"
work="$(mktemp -d "${TMPDIR:-/tmp}/pearl-runtime-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if ! gh release view "$tag" --repo "$repository" --json tagName,isDraft,assets > "$work/release.json" 2>"$work/release.err"; then
  die "Pearl runtime release assets are missing for $tag: GitHub release not found"
fi

PEARL_RELEASE_VIEW="$work/release.json" \
PEARL_RELEASE_TAG="$tag" \
PEARL_RELEASE_REQUIRED_ASSETS="$(printf '%s\n' "${required_assets[@]}")" \
  python3 - <<'PY'
import json
import os
import sys


def fail(message: str) -> None:
    print(f"[verify-pearl-runtime-release] ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


payload = json.loads(open(os.environ["PEARL_RELEASE_VIEW"], encoding="utf-8").read())
tag = os.environ["PEARL_RELEASE_TAG"]
if payload.get("tagName") != tag:
    fail("GitHub release tag does not match requested tag")
if payload.get("isDraft") is True:
    fail("GitHub release is still draft; Pearl rollout requires published immutable assets")
assets = payload.get("assets")
names = {row.get("name") for row in assets if isinstance(row, dict)}
required = {line for line in os.environ["PEARL_RELEASE_REQUIRED_ASSETS"].splitlines() if line}
missing = sorted(required - names)
if missing:
    fail("missing Pearl runtime release asset(s): " + " ".join(missing))
PY

gh release download "$tag" --repo "$repository" --dir "$work/assets" \
  --pattern pearl-release.json --pattern checksums.txt --clobber >/dev/null

# Download only the runtime pair for digest validation. The asset-list check
# above proves the remaining signed catalog/operator files are present, and the
# updater performs full signature and catalog validation before live mutation.
gh release download "$tag" --repo "$repository" --dir "$work/assets" \
  --pattern coordinator-linux-amd64 --pattern gateway-linux-amd64 --clobber >/dev/null

# Create empty placeholders for already-proven present assets that are not
# downloaded in GitHub mode. Their checksums are verified by macprovider-pearl-update.
for asset in "${required_assets[@]}"; do
  [[ -e "$work/assets/$asset" ]] || : > "$work/assets/$asset"
done

PEARL_RELEASE_DIR="$work/assets" \
PEARL_RELEASE_TAG="$tag" \
PEARL_RELEASE_EXPECTED_COMMIT="$expected_commit" \
PEARL_RELEASE_REPOSITORY="$repository" \
PEARL_RELEASE_REQUIRED_ASSETS="$(printf '%s\n' pearl-release.json checksums.txt coordinator-linux-amd64 gateway-linux-amd64)" \
  python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import re
import sys


def fail(message: str) -> None:
    print(f"[verify-pearl-runtime-release] ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


directory = pathlib.Path(os.environ["PEARL_RELEASE_DIR"])
tag = os.environ["PEARL_RELEASE_TAG"]
expected_commit = os.environ["PEARL_RELEASE_EXPECTED_COMMIT"]
repository = os.environ["PEARL_RELEASE_REPOSITORY"]
metadata = json.loads((directory / "pearl-release.json").read_text(encoding="utf-8"))
if metadata.get("repository") != repository:
    fail("pearl-release.json repository mismatch")
if metadata.get("tag") != tag:
    fail("pearl-release.json tag mismatch")
if metadata.get("commit") != expected_commit:
    fail(f"pearl-release.json commit is {metadata.get('commit')!r}, expected {expected_commit!r}")
if metadata.get("architecture") != "linux-amd64":
    fail("pearl-release.json architecture must be linux-amd64")
components = metadata.get("components")
if not isinstance(components, dict):
    fail("pearl-release.json components are missing")
sha_re = re.compile(r"^[0-9a-f]{64}$")
for name, asset in (("coordinator", "coordinator-linux-amd64"), ("gateway", "gateway-linux-amd64")):
    row = components.get(name)
    if not isinstance(row, dict) or row.get("asset") != asset:
        fail(f"pearl-release.json {name} component does not bind {asset}")
    digest = row.get("sha256")
    if not isinstance(digest, str) or not sha_re.fullmatch(digest):
        fail(f"pearl-release.json {name} sha256 is invalid")
    actual = hashlib.sha256((directory / asset).read_bytes()).hexdigest()
    if actual != digest:
        fail(f"{asset} sha256 does not match pearl-release.json")
print(f"[verify-pearl-runtime-release] ok: {tag} has Pearl runtime assets for {expected_commit}")
PY
