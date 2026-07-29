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
lane = metadata.get("release_lane", "pearl_runtime_catalog")
if lane not in {"pearl_runtime", "pearl_runtime_catalog"}:
    fail("pearl-release.json release_lane is invalid")
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
if lane == "pearl_runtime":
    if "provider_advertised_version" in metadata:
        fail("pearl-release.json runtime-only lane must not carry provider advertised version")
else:
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

operator_artifacts = metadata.get("operator_artifacts")
coordinator_cli = operator_artifacts.get("coordinator_cli") if isinstance(operator_artifacts, dict) else None
if not isinstance(coordinator_cli, dict) or coordinator_cli.get("asset") != "coordinator-cli-linux-amd64":
    fail("pearl-release.json coordinator CLI artifact does not bind coordinator-cli-linux-amd64")
coordinator_cli_digest = coordinator_cli.get("sha256")
if not isinstance(coordinator_cli_digest, str) or not sha_re.fullmatch(coordinator_cli_digest):
    fail("pearl-release.json coordinator CLI sha256 is invalid")
actual = hashlib.sha256((directory / "coordinator-cli-linux-amd64").read_bytes()).hexdigest()
if actual != coordinator_cli_digest:
    fail("coordinator-cli-linux-amd64 sha256 does not match pearl-release.json")

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
expected_catalog_assets = {
    "release.json",
    "trusted-keys.json",
    "tier2-catalog.json",
    "autotune-candidates.json",
    "autotune-candidates.json.sig",
    "demand-rank.json",
    "demand-rank.json.sig",
}
if lane == "pearl_runtime":
    if catalog not in (None, {}):
        fail("pearl-release.json runtime-only lane must not bind catalog/feed assets")
else:
    if not isinstance(catalog, dict):
        fail("pearl-release.json catalog metadata is missing")
    catalog_files = catalog.get("files")
    if set(catalog_files if isinstance(catalog_files, dict) else ()) != expected_catalog_assets:
        fail("pearl-release.json catalog file set is invalid")
    missing_catalog = sorted(asset for asset in expected_catalog_assets if not (directory / asset).is_file())
    if missing_catalog:
        fail("missing catalog/feed asset(s) for catalog-bound Pearl runtime release: " + " ".join(missing_catalog))
    for asset in sorted(expected_catalog_assets):
        metadata_digest = catalog_files.get(asset)
        if not isinstance(metadata_digest, str) or not sha_re.fullmatch(metadata_digest):
            fail(f"pearl-release.json catalog sha256 is invalid for {asset}")
        actual = hashlib.sha256((directory / asset).read_bytes()).hexdigest()
        if actual != metadata_digest:
            fail(f"{asset} sha256 does not match pearl-release.json catalog metadata")
        checksum_digest = checksums.get(asset)
        if checksum_digest is None:
            fail(f"checksums.txt omits catalog/feed asset: {asset}")
        if checksum_digest != actual:
            fail(f"checksums.txt digest mismatch for catalog/feed asset: {asset}")

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

if ! gh release view "$tag" --repo "$repository" --json tagName,isDraft,isPrerelease,assets > "$work/release.json" 2>"$work/release.err"; then
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
  --pattern pearl-release.json --pattern pearl-release.json.sig \
  --pattern checksums.txt --pattern checksums.txt.sig \
  --pattern coordinator-linux-amd64 --pattern coordinator-cli-linux-amd64 \
  --pattern gateway-linux-amd64 --clobber >/dev/null

lane="$(
  PEARL_RELEASE_METADATA="$work/assets/pearl-release.json" python3 - <<'PY'
import json
import os
import sys

try:
    metadata = json.loads(open(os.environ["PEARL_RELEASE_METADATA"], encoding="utf-8").read())
except Exception as exc:
    print(f"[verify-pearl-runtime-release] ERROR: pearl-release.json is not valid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)
lane = metadata.get("release_lane", "pearl_runtime_catalog") if isinstance(metadata, dict) else None
if lane not in {"pearl_runtime", "pearl_runtime_catalog"}:
    print("[verify-pearl-runtime-release] ERROR: pearl-release.json release_lane is invalid", file=sys.stderr)
    raise SystemExit(1)
print(lane)
PY
)"

if [[ "$lane" = "pearl_runtime_catalog" ]]; then
  catalog_assets=(
    release.json
    trusted-keys.json
    tier2-catalog.json
    autotune-candidates.json
    autotune-candidates.json.sig
    demand-rank.json
    demand-rank.json.sig
  )
  PEARL_RELEASE_VIEW="$work/release.json" \
  PEARL_RELEASE_CATALOG_ASSETS="$(printf '%s\n' "${catalog_assets[@]}")" \
    python3 - <<'PY'
import json
import os
import sys

payload = json.loads(open(os.environ["PEARL_RELEASE_VIEW"], encoding="utf-8").read())
assets = payload.get("assets")
names = {row.get("name") for row in assets if isinstance(row, dict)}
required = {line for line in os.environ["PEARL_RELEASE_CATALOG_ASSETS"].splitlines() if line}
missing = sorted(required - names)
if missing:
    print(
        "[verify-pearl-runtime-release] ERROR: missing catalog/feed asset(s) for catalog-bound Pearl runtime release: "
        + " ".join(missing),
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
  gh release download "$tag" --repo "$repository" --dir "$work/assets" \
    --pattern release.json --pattern trusted-keys.json \
    --pattern tier2-catalog.json --pattern autotune-candidates.json \
    --pattern autotune-candidates.json.sig --pattern demand-rank.json \
    --pattern demand-rank.json.sig --clobber >/dev/null
else
  PEARL_RELEASE_VIEW="$work/release.json" python3 - <<'PY'
import json
import os
import sys

payload = json.loads(open(os.environ["PEARL_RELEASE_VIEW"], encoding="utf-8").read())
if payload.get("isPrerelease") is not True:
    print(
        "[verify-pearl-runtime-release] ERROR: runtime-only Pearl releases must be GitHub prereleases",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
fi

validate_release_dir "$work/assets"
