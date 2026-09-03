#!/usr/bin/env bash
# Republish the released curl-channel install.sh to the get.malibu.tech webroot.
#
# The public one-liner `curl -fsSL https://get.malibu.tech/install.sh | bash` is
# served as a static file from the coordinator host (Pearl). Cutting a release
# updates the Malibu.app bundle and the GitHub release assets, but nothing
# republishes that static file automatically, so it has silently lagged behind
# releases (e.g. at v1.8.117 it kept serving the v1.8.115/116 copy, missing the
# #1296 escaped-path fix, which makes a fresh install able to hit `die 30`). The
# `install-sh-parity-alarm` workflow only *detects* that drift; this script
# closes it by publishing phase3-binary/dist/install.sh (the checked-out release
# copy) to /var/www/get/install.sh, backing up the current file, and confirming
# the served bytes now match.
#
# Reuses the download.malibu.tech Pearl publish credentials + pinned known_hosts.
#
# Usage:
#   scripts/publish-install-sh.sh --tag vX.Y.Z   # publish that tag's install.sh (must be latest stable)
#   scripts/publish-install-sh.sh --check-only    # compare served vs this checkout (read-only)
#
# Env:
#   MALIBU_DOWNLOAD_SSH_KEY   path to the Pearl root deploy key (required to publish)
#   MALIBU_DOWNLOAD_VPS_HOST  Pearl host (default 159.223.165.194)
#   MALIBU_DOWNLOAD_VPS_USER  SSH user (default root; must be root)
#
# Exit codes: 0 = published or already in sync; 1 = drift (--check-only) or
#             failure; 2 = usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_INSTALL="$REPO_ROOT/phase3-binary/dist/install.sh"
# Fixed production endpoint + webroot, deliberately NOT env-overridable: this
# script exists specifically to keep the public get.malibu.tech curl channel in
# sync, so the served-byte verification cannot be pointed at non-production bytes,
# and the remote webroot path cannot become a shell-injection vector on Pearl.
INSTALL_URL="https://get.malibu.tech/install.sh"
WEBROOT="/var/www/get"
CHECK_ONLY=0
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --tag) TAG="${2:-}"; shift ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf '[publish-install-sh] unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

die() { printf '[publish-install-sh] ERROR: %s\n' "$*" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
sha256_url() {
  # Prints the sha256 of the served file, or fails on fetch error. Streams to a
  # temp file (never through $(...)) so trailing newlines/NULs are hashed exactly.
  local tmp rc=0
  tmp="$(mktemp)"
  if curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 -o "$tmp" -- "$INSTALL_URL" 2>/dev/null; then
    sha256_file "$tmp"
  else
    rc=1
  fi
  rm -f "$tmp"
  return "$rc"
}

[[ -f "$SOURCE_INSTALL" ]] || die "missing release install.sh: $SOURCE_INSTALL"
expected="$(sha256_file "$SOURCE_INSTALL")"
# Defense-in-depth: both values are interpolated into a remote root shell below.
# They are constants/derived-from-a-repo-file here, but assert their shape anyway.
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "unexpected sha256 for $SOURCE_INSTALL: $expected"
[[ "$WEBROOT" =~ ^/[A-Za-z0-9._/-]+$ && "$WEBROOT" != *"/../"* && "$WEBROOT" != */.. ]] || die "unsafe webroot: $WEBROOT"
printf '[publish-install-sh] release install.sh sha256=%s\n' "$expected"

# In publish mode, bind to the release tag BEFORE any success/no-op exit: nothing
# may report success without proving --tag is the current latest stable release
# and byte-identical to these bytes. This keeps the standalone recovery path as
# safe as the automated one — it can never publish (or silently "succeed" on)
# HEAD, uncommitted, prerelease, forged-local-tag, or superseded bytes.
if [[ "$CHECK_ONLY" == 0 ]]; then
  [[ -n "$TAG" ]] || die "--tag <vX.Y.Z> is required to publish (refusing to publish non-released bytes)"
  # Always fetch the tag fresh from origin (force-overwriting any local ref) so a
  # stale or locally-forged tag cannot satisfy the byte-match below.
  git -C "$REPO_ROOT" fetch --no-tags --quiet --force origin "refs/tags/$TAG:refs/tags/$TAG" \
    || die "cannot fetch tag $TAG from origin"
  tag_tmp="$(mktemp)"
  git -C "$REPO_ROOT" show "$TAG:phase3-binary/dist/install.sh" > "$tag_tmp" 2>/dev/null \
    || { rm -f "$tag_tmp"; die "tag $TAG has no phase3-binary/dist/install.sh"; }
  tag_sha="$(sha256_file "$tag_tmp")"
  rm -f "$tag_tmp"
  [[ "$tag_sha" == "$expected" ]] \
    || die "local phase3-binary/dist/install.sh ($expected) does not match $TAG ($tag_sha); are you on the release commit?"
  command -v gh >/dev/null 2>&1 || die "gh is required to verify $TAG is the latest stable release"
  # Pin the repo (never rely on ambient gh context). GitHub's releases/latest
  # endpoint returns the "Latest" release, which excludes prereleases/drafts; if
  # it equals $TAG we neither regress the channel nor ship a prerelease.
  repo="${GITHUB_REPOSITORY:-Augustas11/macprovider}"
  latest_tag="$(gh api "repos/$repo/releases/latest" -q .tag_name 2>/dev/null)" \
    || die "cannot determine the latest stable release for $repo"
  [[ "$latest_tag" == "$TAG" ]] \
    || die "$TAG is not the latest stable release (GitHub latest = ${latest_tag:-none}); refusing to republish"
  printf '[publish-install-sh] verified %s is the latest stable release and matches the checkout\n' "$TAG"
fi

served="$(sha256_url || true)"
if [[ -n "$served" && "$served" == "$expected" ]]; then
  printf '[publish-install-sh] served install.sh already matches the release; nothing to do\n'
  exit 0
fi

if [[ "$CHECK_ONLY" == 1 ]]; then
  printf '[publish-install-sh] DRIFT: served=%s expected=%s\n' "${served:-<fetch-failed>}" "$expected" >&2
  exit 1
fi

# --- publish path ------------------------------------------------------------

: "${MALIBU_DOWNLOAD_SSH_KEY:?required to publish: set to the Pearl root deploy key path}"
SSH_KEY="$MALIBU_DOWNLOAD_SSH_KEY"
VPS_USER="${MALIBU_DOWNLOAD_VPS_USER:-root}"
VPS_HOST="${MALIBU_DOWNLOAD_VPS_HOST:-159.223.165.194}"
export SSH_KEY VPS_USER VPS_HOST SCRIPT_DIR
[[ "$VPS_USER" == "root" ]] || die "Pearl publication requires the root SSH account"
[[ -f "$SSH_KEY" && ! -L "$SSH_KEY" ]] || die "SSH key missing or symlinked: $SSH_KEY"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/malibu-download-ssh.sh"

remote_stage=""
# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
  if [[ -n "$remote_stage" && "$remote_stage" =~ ^/root/\.malibu-publish/stage\.[A-Za-z0-9]+$ ]]; then
    malibu_download_ssh "rm -rf -- '$remote_stage'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

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

malibu_download_scp "$SOURCE_INSTALL" "$VPS_USER@$VPS_HOST:$remote_stage/install.sh" >/dev/null

# Backup current, verify staged bytes, atomic same-dir rename into the webroot,
# and confirm the on-disk sha. All remote-side; nothing runs unless the staged
# file already hashes to the released install.sh.
malibu_download_ssh "set -euo pipefail
  stage='$remote_stage'
  webroot='$WEBROOT'
  expected='$expected'
  ts=\"\$(date -u +%Y%m%dT%H%M%SZ)\"
  src=\"\$stage/install.sh\"
  chown root:root \"\$src\"
  chmod 0755 \"\$src\"
  actual=\"\$(sha256sum \"\$src\" | awk '{print \$1}')\"
  [ \"\$actual\" = \"\$expected\" ] || { echo \"staged sha256 mismatch: \$actual != \$expected\" >&2; exit 1; }
  [ -d \"\$webroot\" ] || { echo \"missing webroot \$webroot\" >&2; exit 1; }
  if [ -f \"\$webroot/install.sh\" ]; then
    cp -p \"\$webroot/install.sh\" \"\$webroot/install.sh.bak-stale-\$ts\"
  fi
  tmp=\"\$webroot/.install.sh.new.\$ts\"
  cp -p \"\$src\" \"\$tmp\"
  chown root:root \"\$tmp\"
  chmod 0755 \"\$tmp\"
  mv -f \"\$tmp\" \"\$webroot/install.sh\"
  disk=\"\$(sha256sum \"\$webroot/install.sh\" | awk '{print \$1}')\"
  [ \"\$disk\" = \"\$expected\" ] || { echo \"post-publish on-disk sha256 mismatch\" >&2; exit 1; }
  echo \"[pearl] install.sh republished (\$expected); backup install.sh.bak-stale-\$ts\"
"
# Keep remote_stage set so the EXIT trap removes the Pearl staging dir; the remote
# command above does not clean up after itself.

# Confirm the public channel serves the new bytes (retry: served is uncached at
# the origin, but allow for any front-side propagation).
for _ in 1 2 3 4 5 6; do
  served="$(sha256_url || true)"
  [[ "$served" == "$expected" ]] && { printf '[publish-install-sh] ok: served install.sh now matches the release (%s)\n' "$expected"; exit 0; }
  sleep 10
done
die "republished but served still != expected (served=${served:-<fetch-failed>} expected=$expected)"
