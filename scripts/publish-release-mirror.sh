#!/usr/bin/env bash
# Mirror one GitHub release byte-for-byte to download.malibu.tech (issue #1737).
#
# Provider Macs in mainland China cannot reach github.com / *.githubusercontent.com
# but can reach https://download.malibu.tech (Pearl). install.sh and the CLI
# self-updater fall back to this fixed layout:
#
#   /releases/<tag>/<asset>      byte-identical copy of every GitHub release asset
#   /releases/<tag>/release.json GitHub-API-shaped listing of exactly those assets
#   /releases/latest.json        {"tag_name": "<tag>"}, advisory; --promote-latest
#   /python/<asset>              the python-build-standalone tarball pinned by
#                                phase3-binary/dist/install.sh (SHA-256 checked)
#
# The mirror is untrusted transport: consumers still verify checksums.txt.sig
# (and the python pin) exactly as for GitHub bytes. This script therefore adds
# no authority; it refuses to publish any byte whose SHA-256 differs from the
# digest GitHub reports for that asset, and a published /releases/<tag>/ is
# immutable (re-running is a no-op when identical and an error otherwise).
#
# Usage:
#   scripts/publish-release-mirror.sh --tag vX.Y.Z [--promote-latest]
#   scripts/publish-release-mirror.sh --tag vX.Y.Z [--promote-latest] --stage-only DIR
#
# --promote-latest  also point /releases/latest.json at <tag>. Allowed only for a
#                   stable release that the live coordinator already advertises as
#                   latest_binary_version (/healthz recommended_binary_version),
#                   and never to an older tag than the one currently served.
# --stage-only DIR  download, verify, and lay the tree out under DIR without
#                   uploading (dry run and tests).
#
# Env:
#   GITHUB_REPOSITORY          must be Augustas11/macprovider (default)
#   GH_TOKEN                   read access for gh release download
#   MALIBU_DOWNLOAD_SSH_KEY    path to the Pearl root deploy key (required to upload)
#   MALIBU_DOWNLOAD_VPS_HOST   Pearl host (default 159.223.165.194)
#   MALIBU_DOWNLOAD_VPS_USER   SSH user (default root; must be root)
#   MALIBU_DOWNLOAD_WEBROOT    download.malibu.tech webroot (default /var/www/malibu-download)
#
# Exit codes: 0 published / already identical; 1 failure; 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIRROR_REPOSITORY="Augustas11/macprovider"
MIRROR_ORIGIN="https://download.malibu.tech"
COORDINATOR_HEALTHZ="https://coordinator.malibu.tech/healthz"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

TAG=""
PROMOTE_LATEST=0
STAGE_ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift ;;
    --promote-latest) PROMOTE_LATEST=1 ;;
    --stage-only) STAGE_ONLY="${2:-}"; shift ;;
    -h|--help) sed -n '2,39p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf '[publish-release-mirror] unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

die() { printf '[publish-release-mirror] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[publish-release-mirror] %s\n' "$*"; }

[[ "$TAG" =~ ^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] ||
  { printf '[publish-release-mirror] --tag must be a canonical vMAJOR.MINOR.PATCH\n' >&2; exit 2; }
repo="${GITHUB_REPOSITORY:-$MIRROR_REPOSITORY}"
[[ "$repo" == "$MIRROR_REPOSITORY" ]] || die "the release mirror carries only $MIRROR_REPOSITORY releases"
command -v gh >/dev/null 2>&1 || die "gh is required"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

if [[ -n "$STAGE_ONLY" ]]; then
  mkdir -p "$STAGE_ONLY"
  out="$(cd "$STAGE_ONLY" && pwd)"
  [[ -z "$(ls -A "$out")" ]] || die "--stage-only directory must be empty: $out"
  work="$(mktemp -d "${TMPDIR:-/tmp}/release-mirror-work.XXXXXX")"
else
  work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-mirror.XXXXXX")"
  out="$work/tree"
fi
remote_stage=""
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  rm -rf "$work"
  if [[ -n "$remote_stage" && "$remote_stage" =~ ^/root/\.malibu-publish/stage\.[A-Za-z0-9]+$ ]]; then
    malibu_download_ssh "rm -rf -- '$remote_stage'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- 1. GitHub release metadata ---------------------------------------------
release_api="$work/release-api.json"
gh api -H 'Accept: application/vnd.github+json' "repos/$repo/releases/tags/$TAG" > "$release_api" ||
  die "cannot read GitHub release $TAG"
manifest="$work/assets.tsv"
prerelease="$(python3 - "$release_api" "$TAG" "$manifest" <<'PY'
import json
import re
import sys

release_path, tag, manifest_path = sys.argv[1:]
release = json.load(open(release_path, encoding="utf-8"))
if not isinstance(release, dict) or release.get("tag_name") != tag:
    raise SystemExit("GitHub release tag_name does not match --tag")
if release.get("draft") is not False:
    raise SystemExit("refusing to mirror a draft release")
if not isinstance(release.get("prerelease"), bool):
    raise SystemExit("GitHub release has no boolean prerelease flag")
assets = release.get("assets")
if not isinstance(assets, list) or not assets:
    raise SystemExit("GitHub release has no assets")
safe = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$")
reserved = {"release.json", "latest.json"}
rows = []
for asset in assets:
    name = asset.get("name") if isinstance(asset, dict) else None
    if not isinstance(name, str) or not safe.fullmatch(name) or ".." in name or name in reserved:
        raise SystemExit(f"unsafe or reserved asset name: {name!r}")
    digest = asset.get("digest")
    match = re.fullmatch(r"sha256:([0-9a-f]{64})", digest) if isinstance(digest, str) else None
    if match is None:
        raise SystemExit(f"GitHub reports no sha256 digest for {name}")
    size = asset.get("size")
    if type(size) is not int or size < 0:
        raise SystemExit(f"GitHub reports no size for {name}")
    rows.append((name, match.group(1), size))
names = [row[0] for row in rows]
if len(set(names)) != len(names):
    raise SystemExit("duplicate asset names")
with open(manifest_path, "w", encoding="utf-8") as handle:
    for name, digest, size in sorted(rows):
        handle.write(f"{name}\t{digest}\t{size}\n")
print("true" if release["prerelease"] else "false")
PY
)" || die "GitHub release $TAG is not mirrorable"

# Promotion gate runs before any download, so a refused promotion stages nothing.
if [[ "$PROMOTE_LATEST" == 1 ]]; then
  [[ "$prerelease" == false ]] || die "--promote-latest refuses a prerelease"
  advertised="$(curl -fsS --proto '=https' --max-time 20 -- "$COORDINATOR_HEALTHZ" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("recommended_binary_version",""))')" ||
    die "cannot read the coordinator advertisement from $COORDINATOR_HEALTHZ"
  [[ "v${advertised#v}" == "$TAG" ]] ||
    die "coordinator advertises ${advertised:-nothing}, not $TAG; advance latest_binary_version first"
  served_latest="$(curl -fsS --proto '=https' --max-time 20 -- "$MIRROR_ORIGIN/releases/latest.json" 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
  if [[ "$served_latest" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    python3 - "$served_latest" "$TAG" <<'PY' || die "served latest.json ($served_latest) is newer than $TAG; refusing to regress"
import sys
served, tag = (tuple(int(part) for part in value[1:].split(".")) for value in sys.argv[1:])
raise SystemExit(0 if tag >= served else 1)
PY
  fi
fi

# --- 2. Download every asset and prove byte identity ------------------------
files_dir="$work/download"
mkdir -p "$files_dir"
gh release download "$TAG" --repo "$repo" --dir "$files_dir" >/dev/null ||
  die "cannot download the assets of $TAG"
python3 - "$manifest" "$files_dir" <<'PY' || die "downloaded assets are not byte-identical to GitHub's digests"
import hashlib
import os
import stat
import sys

manifest_path, files_dir = sys.argv[1:]
expected = {}
for line in open(manifest_path, encoding="utf-8"):
    name, digest, size = line.rstrip("\n").split("\t")
    expected[name] = (digest, int(size))
present = set(os.listdir(files_dir))
if present != set(expected):
    raise SystemExit(f"asset set mismatch: missing={sorted(set(expected) - present)} extra={sorted(present - set(expected))}")
for name, (digest, size) in expected.items():
    path = os.path.join(files_dir, name)
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_size != size:
        raise SystemExit(f"{name}: not a regular file of the GitHub size")
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            hasher.update(chunk)
    if hasher.hexdigest() != digest:
        raise SystemExit(f"{name}: sha256 differs from the GitHub asset digest")
PY
log "verified $(wc -l < "$manifest" | tr -d ' ') assets of $TAG against GitHub's sha256 digests"

# --- 3. Lay out the mirror tree ----------------------------------------------
release_dir="$out/releases/$TAG"
mkdir -p "$release_dir"
while IFS=$'\t' read -r name _digest _size; do
  cp -p "$files_dir/$name" "$release_dir/$name"
done < "$manifest"
python3 - "$manifest" "$TAG" "$prerelease" "$MIRROR_ORIGIN" "$release_dir/release.json" <<'PY'
import json
import sys

manifest_path, tag, prerelease, origin, out_path = sys.argv[1:]
names = [line.split("\t", 1)[0] for line in open(manifest_path, encoding="utf-8")]
document = {
    "tag_name": tag,
    "draft": False,
    "prerelease": prerelease == "true",
    "assets": [
        {"name": name, "browser_download_url": f"{origin}/releases/{tag}/{name}"}
        for name in names
    ],
}
with open(out_path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(document, indent=2, sort_keys=True, ensure_ascii=True) + "\n")
PY

# The pinned bootstrap interpreter (install.sh BOOTSTRAP_PYTHON_*). Mirrored with
# every release so a new pin is served before the installer carrying it ships.
read -r python_asset python_url python_sha < <(python3 - "$INSTALL_SH" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
def value(name):
    match = re.search(rf'^{name}="([^"$]*)"$', text, re.M)
    if match is None:
        raise SystemExit(f"install.sh has no literal {name}")
    return match.group(1)
release = value("BOOTSTRAP_PYTHON_RELEASE")
asset = value("BOOTSTRAP_PYTHON_ASSET")
sha = value("BOOTSTRAP_PYTHON_SHA256")
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,199}", asset) or not re.fullmatch(r"[0-9a-f]{64}", sha):
    raise SystemExit("install.sh python pin is malformed")
if not re.fullmatch(r"[0-9]{8}", release):
    raise SystemExit("install.sh python release is malformed")
url = f"https://github.com/astral-sh/python-build-standalone/releases/download/{release}/{asset}"
print(asset, url, sha)
PY
) || die "cannot read the pinned bootstrap python from $INSTALL_SH"
mkdir -p "$out/python"
curl -fsSL --proto '=https' --connect-timeout 15 --retry 3 --retry-connrefused --max-time 900 \
  -o "$out/python/$python_asset" -- "$python_url" || die "cannot download $python_url"
[[ "$(sha256_file "$out/python/$python_asset")" == "$python_sha" ]] ||
  die "$python_asset does not match the install.sh SHA-256 pin"

# --- 4. latest.json (promotion only; gated above) ----------------------------
if [[ "$PROMOTE_LATEST" == 1 ]]; then
  printf '{"tag_name": "%s"}\n' "$TAG" > "$out/releases/latest.json"
fi

if [[ -n "$STAGE_ONLY" ]]; then
  log "staged mirror tree for $TAG under $out (no upload)"
  exit 0
fi

# --- 5. Upload to Pearl -------------------------------------------------------
: "${MALIBU_DOWNLOAD_SSH_KEY:?required to publish: set to the Pearl root deploy key path}"
SSH_KEY="$MALIBU_DOWNLOAD_SSH_KEY"
VPS_USER="${MALIBU_DOWNLOAD_VPS_USER:-root}"
VPS_HOST="${MALIBU_DOWNLOAD_VPS_HOST:-159.223.165.194}"
WEBROOT="${MALIBU_DOWNLOAD_WEBROOT:-/var/www/malibu-download}"
export SSH_KEY VPS_USER VPS_HOST SCRIPT_DIR
[[ "$VPS_USER" == root ]] || die "Pearl publication requires the root SSH account"
[[ "$WEBROOT" =~ ^/[A-Za-z0-9._/-]+$ && "$WEBROOT" != *'/../'* && "$WEBROOT" != */.. ]] || die "unsafe webroot"
[[ -f "$SSH_KEY" && ! -L "$SSH_KEY" ]] || die "SSH key missing or symlinked: $SSH_KEY"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/malibu-download-ssh.sh"

# Remote variables must expand on Pearl, not in this local shell.
# shellcheck disable=SC2016
remote_stage="$(malibu_download_ssh 'set -eu
  umask 077
  install -d -o root -g root -m 0700 /root/.malibu-publish
  stage="$(mktemp -d /root/.malibu-publish/stage.XXXXXXXX)"
  chown root:root "$stage"
  chmod 0700 "$stage"
  printf "%s\n" "$stage"')"
[[ "$remote_stage" =~ ^/root/\.malibu-publish/stage\.[A-Za-z0-9]+$ ]] ||
  die "Pearl returned an unsafe staging path: $remote_stage"

# Every name below matched ^[A-Za-z0-9][A-Za-z0-9._+-]*$ (validated above), so
# the single-quoted interpolation into the remote shell cannot inject.
release_specs=""
for path in "$release_dir"/*; do
  name="$(basename "$path")"
  malibu_download_scp "$path" "$VPS_USER@$VPS_HOST:$remote_stage/$name" >/dev/null
  release_specs+=" '$name:$(sha256_file "$path")'"
done
malibu_download_scp "$out/python/$python_asset" "$VPS_USER@$VPS_HOST:$remote_stage/.python-$python_asset" >/dev/null
latest_sha=""
if [[ -f "$out/releases/latest.json" ]]; then
  malibu_download_scp "$out/releases/latest.json" "$VPS_USER@$VPS_HOST:$remote_stage/.latest.json" >/dev/null
  latest_sha="$(sha256_file "$out/releases/latest.json")"
fi

# Verify staged bytes, then install atomically. /releases/<tag>/ is immutable:
# an existing directory must already hold exactly these bytes.
malibu_download_ssh "set -euo pipefail
  stage='$remote_stage'
  webroot='$WEBROOT'
  tag='$TAG'
  python_asset='$python_asset'
  python_sha='$python_sha'
  latest_sha='$latest_sha'
  check() { [ \"\$(sha256sum \"\$1\" | awk '{print \$1}')\" = \"\$2\" ] || { echo \"sha256 mismatch: \$1\" >&2; exit 1; }; }
  [ -d \"\$webroot\" ] || { echo \"missing webroot \$webroot\" >&2; exit 1; }
  install -d -o root -g root -m 0755 \"\$webroot/releases\" \"\$webroot/python\"
  count=0
  for spec in$release_specs; do
    name=\"\${spec%%:*}\"
    check \"\$stage/\$name\" \"\${spec#*:}\"
    count=\$((count + 1))
  done
  target=\"\$webroot/releases/\$tag\"
  if [ -e \"\$target\" ]; then
    [ \"\$(find \"\$target\" -mindepth 1 | wc -l)\" -eq \"\$count\" ] || { echo \"\$target exists with a different file set; releases are immutable\" >&2; exit 1; }
    for spec in$release_specs; do
      check \"\$target/\${spec%%:*}\" \"\${spec#*:}\"
    done
    echo \"[pearl] \$target already mirrors these bytes\"
  else
    tmp=\"\$webroot/releases/.\$tag.new.\$\$\"
    rm -rf -- \"\$tmp\"
    install -d -o root -g root -m 0755 \"\$tmp\"
    for spec in$release_specs; do
      install -o root -g root -m 0644 \"\$stage/\${spec%%:*}\" \"\$tmp/\${spec%%:*}\"
    done
    mv -T -- \"\$tmp\" \"\$target\"
    echo \"[pearl] mirrored \$count files to \$target\"
  fi
  check \"\$stage/.python-\$python_asset\" \"\$python_sha\"
  if [ -e \"\$webroot/python/\$python_asset\" ]; then
    check \"\$webroot/python/\$python_asset\" \"\$python_sha\"
  else
    install -o root -g root -m 0644 \"\$stage/.python-\$python_asset\" \"\$webroot/python/.\$python_asset.new\"
    mv -f -- \"\$webroot/python/.\$python_asset.new\" \"\$webroot/python/\$python_asset\"
  fi
  if [ -n \"\$latest_sha\" ]; then
    check \"\$stage/.latest.json\" \"\$latest_sha\"
    install -o root -g root -m 0644 \"\$stage/.latest.json\" \"\$webroot/releases/.latest.json.new\"
    mv -f -- \"\$webroot/releases/.latest.json.new\" \"\$webroot/releases/latest.json\"
    echo \"[pearl] latest.json -> \$tag\"
  fi
"

# --- 6. Confirm the public host serves the exact bytes -----------------------
served_sha() {
  local tmp rc=0
  tmp="$(mktemp "$work/served.XXXXXX")"
  if curl -fsSL --proto '=https' --max-time 900 -o "$tmp" -- "$1" 2>/dev/null; then
    sha256_file "$tmp"
  else
    rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}
verify_served() {
  local url="$1" expected="$2" got=""
  for _ in 1 2 3 4 5 6; do
    got="$(served_sha "$url" || true)"
    [[ "$got" == "$expected" ]] && return 0
    sleep 10
  done
  die "served $url is ${got:-<fetch failed>}, expected $expected"
}
for path in "$release_dir"/*; do
  name="$(basename "$path")"
  verify_served "$MIRROR_ORIGIN/releases/$TAG/$name" "$(sha256_file "$path")"
done
verify_served "$MIRROR_ORIGIN/python/$python_asset" "$python_sha"
[[ -z "$latest_sha" ]] || verify_served "$MIRROR_ORIGIN/releases/latest.json" "$latest_sha"
log "ok: $MIRROR_ORIGIN/releases/$TAG/ serves every GitHub asset byte-identically$([[ -z "$latest_sha" ]] || printf '; latest.json -> %s' "$TAG")"
