#!/usr/bin/env bash
# Publish Malibu-{tag}.dmg to download.malibu.tech (Pearl VPS nginx docroot).
#
# Downloads release assets from GitHub, copies to Pearl via SSH, and refreshes
# latest.dmg + appcast.xml for Sparkle.
#
# Usage:
#   bash scripts/publish-malibu-latest-dmg.sh v1.8.19
#
# Environment:
#   MALIBU_DOWNLOAD_VPS_HOST  default 159.223.165.194
#   MALIBU_DOWNLOAD_SSH_KEY   default ~/.ssh/pearl_operator_ed25519
#   MALIBU_DOWNLOAD_VPS_USER  default root
#   MALIBU_DOWNLOAD_WEBROOT   default /var/www/malibu-download
#   VERIFY_MALIBU_DOWNLOAD=1   run verify-malibu-download.sh after upload

set -euo pipefail

die() {
  printf '[publish-malibu-latest-dmg] ERROR: %s\n' "$*" >&2
  exit 1
}

tag="${1:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: $0 vX.Y.Z"

repo="${GITHUB_REPOSITORY:-Augustas11/macprovider}"
dmg_name="Malibu-${tag}.dmg"
versioned_key="Malibu-${tag}.dmg"
latest_key="latest.dmg"

VPS_HOST="${MALIBU_DOWNLOAD_VPS_HOST:-159.223.165.194}"
SSH_KEY="${MALIBU_DOWNLOAD_SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_USER="${MALIBU_DOWNLOAD_VPS_USER:-root}"
WEBROOT="${MALIBU_DOWNLOAD_WEBROOT:-/var/www/malibu-download}"

work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-publish.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

gh release download "$tag" \
  --repo "$repo" \
  --pattern "$dmg_name" \
  --pattern "appcast.xml" \
  --dir "$work" \
  --clobber

asset="$work/$dmg_name"
[[ -f "$asset" ]] || die "release asset missing: $dmg_name"

sha256="$(shasum -a 256 "$asset" | awk '{print $1}')"
printf '%s  %s\n' "$sha256" "$dmg_name" > "$work/${dmg_name}.sha256"

if [[ ! -f "$SSH_KEY" ]]; then
  cat <<EOF
[publish-malibu-latest-dmg] No SSH key at $SSH_KEY — manual step required.

1. Run: bash scripts/setup-malibu-download-pearl.sh
2. Upload $dmg_name to ${WEBROOT} on Pearl as:
     ${versioned_key}
     ${latest_key}
     appcast.xml
     SHA-256: $sha256
3. name.com DNS: download.malibu.tech A -> ${VPS_HOST}
4. GitHub Release fallback:
     https://github.com/$repo/releases/download/$tag/$dmg_name
EOF
  exit 0
fi

SSH="ssh -i $SSH_KEY -o ConnectTimeout=15 -p 22 $VPS_USER@$VPS_HOST"
SCP="scp -i $SSH_KEY -P 22"

$SSH "install -d -o www-data -g www-data -m 0755 $WEBROOT"
$SCP "$asset" "$VPS_USER@$VPS_HOST:/tmp/malibu-${versioned_key}" >/dev/null
$SCP "$work/${dmg_name}.sha256" "$VPS_USER@$VPS_HOST:/tmp/malibu-${dmg_name}.sha256" >/dev/null
appcast="$work/appcast.xml"
if [[ -f "$appcast" ]]; then
  $SCP "$appcast" "$VPS_USER@$VPS_HOST:/tmp/malibu-appcast.xml" >/dev/null
else
  printf '[publish-malibu-latest-dmg] WARN: appcast.xml missing from release %s\n' "$tag" >&2
fi

$SSH "set -e
  install -o www-data -g www-data -m 0644 /tmp/malibu-${versioned_key} ${WEBROOT}/${versioned_key}
  install -o www-data -g www-data -m 0644 /tmp/malibu-${versioned_key} ${WEBROOT}/${latest_key}
  install -o www-data -g www-data -m 0644 /tmp/malibu-${dmg_name}.sha256 ${WEBROOT}/${dmg_name}.sha256
  rm -f /tmp/malibu-${versioned_key} /tmp/malibu-${dmg_name}.sha256
  if [ -f /tmp/malibu-appcast.xml ]; then
    install -o www-data -g www-data -m 0644 /tmp/malibu-appcast.xml ${WEBROOT}/appcast.xml
    rm -f /tmp/malibu-appcast.xml
  fi
"

printf '[publish-malibu-latest-dmg] ok: %s/%s + latest.dmg on Pearl (sha256=%s)\n' \
  "$WEBROOT" "$versioned_key" "$sha256"

if [[ "${VERIFY_MALIBU_DOWNLOAD:-0}" == "1" ]]; then
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  bash "$script_dir/verify-malibu-download.sh"
fi
