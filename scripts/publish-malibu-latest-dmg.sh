#!/usr/bin/env bash
# Publish a locally captured, signed Malibu release set to Pearl.
set -euo pipefail

die() {
  printf '[publish-malibu-latest-dmg] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 6 ]] ||
  die "usage: $0 MANIFEST DMG APPCAST CHECKSUMS SIGNATURE PROVENANCE"

manifest="$1"
asset="$2"
appcast="$3"
checksums="$4"
signature="$5"
provenance="$6"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$SCRIPT_DIR/verify-malibu-publication-set.sh" \
  "$manifest" "$asset" "$appcast" "$checksums" "$signature" "$provenance"

read -r tag commit release_number publication_id dmg_asset_id appcast_asset_id < <(
  python3 - "$manifest" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
tag = manifest["tag"]
assets = manifest["assets"]
print(
    tag,
    manifest["commit"],
    manifest["release_id"],
    manifest["publication_id"],
    assets[f"Malibu-{tag}.dmg"]["id"],
    assets["appcast.xml"]["id"],
)
PY
)
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "manifest tag is invalid"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "manifest commit is invalid"
[[ "$release_number" =~ ^[1-9][0-9]*$ ]] || die "manifest release id is invalid"
[[ "$publication_id" =~ ^[0-9a-f]{64}$ ]] || die "manifest publication id is invalid"
[[ "$dmg_asset_id" =~ ^[1-9][0-9]*$ && "$appcast_asset_id" =~ ^[1-9][0-9]*$ ]] ||
  die "manifest publication asset ids are invalid"

VPS_HOST="${MALIBU_DOWNLOAD_VPS_HOST:-159.223.165.194}"
SSH_KEY="${MALIBU_DOWNLOAD_SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_USER="${MALIBU_DOWNLOAD_VPS_USER:-root}"
WEBROOT="${MALIBU_DOWNLOAD_WEBROOT:-/var/www/malibu-download}"
[[ "$VPS_USER" == root ]] || die "Pearl publication requires the root SSH account"
[[ "$WEBROOT" =~ ^/[A-Za-z0-9._/-]+$ && "$WEBROOT" != *'/../'* && "$WEBROOT" != */.. ]] ||
  die "unsafe webroot"
[[ -f "$SSH_KEY" && ! -L "$SSH_KEY" ]] ||
  die "SSH key missing or symlinked: $SSH_KEY (refusing a partial public publication)"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

dmg_name="Malibu-${tag}.dmg"
checksum_file="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/Malibu-${tag}.XXXXXX.sha256")"
printf '%s  %s\n' "$(sha256_file "$asset")" "$dmg_name" >"$checksum_file"

# Resolved relative to this script at runtime.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/malibu-download-ssh.sh"

remote_stage=""
cleanup() {
  rm -f "$checksum_file"
  if [[ -n "$remote_stage" && "$remote_stage" =~ ^/root/\.malibu-publish/stage\.[A-Za-z0-9]+$ ]]; then
    malibu_download_ssh "rm -rf -- '$remote_stage'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# This block intentionally expands only on Pearl.
# shellcheck disable=SC2016
remote_stage="$(malibu_download_ssh 'set -eu
  umask 077
  install -d -o root -g root -m 0700 /root/.malibu-publish
  stage="$(mktemp -d /root/.malibu-publish/stage.XXXXXXXX)"
  chown root:root "$stage"
  chmod 0700 "$stage"
  printf "%s\n" "$stage"')"
[[ "$remote_stage" =~ ^/root/\.malibu-publish/stage\.[A-Za-z0-9]+$ ]] ||
  die "Pearl returned an unsafe staging path"

helper="$SCRIPT_DIR/install-malibu-publication.sh"
declare -a local_paths=("$manifest" "$asset" "$appcast" "$checksum_file" "$helper")
declare -a remote_names=(publication-manifest.json "$dmg_name" appcast.xml "${dmg_name}.sha256" install-helper)
declare -a expected_hashes=()
for index in "${!local_paths[@]}"; do
  expected_hashes+=("$(sha256_file "${local_paths[$index]}")")
  malibu_download_scp \
    "${local_paths[$index]}" \
    "$VPS_USER@$VPS_HOST:$remote_stage/${remote_names[$index]}" >/dev/null
done

specs=""
for index in "${!remote_names[@]}"; do
  mode=0600
  [[ "${remote_names[$index]}" == install-helper ]] && mode=0700
  specs+=" '${remote_names[$index]}:${expected_hashes[$index]}:$mode'"
done

malibu_download_ssh "set -euo pipefail
  stage='$remote_stage'
  cleanup_remote() { rm -rf -- \"\$stage\"; }
  trap cleanup_remote EXIT
  for spec in$specs; do
    name=\"\${spec%%:*}\"
    rest=\"\${spec#*:}\"
    expected=\"\${rest%%:*}\"
    mode=\"\${rest##*:}\"
    path=\"\$stage/\$name\"
    chown root:root \"\$path\"
    chmod \"\$mode\" \"\$path\"
    meta=\"\$(stat -c '%u:%g:%a:%h:%F' \"\$path\")\"
    expected_meta=\"0:0:\${mode#0}:1:regular file\"
    [ \"\$meta\" = \"\$expected_meta\" ] || {
      echo \"unsafe transferred file \$path: \$meta\" >&2
      exit 1
    }
    actual=\"\$(sha256sum \"\$path\" | awk '{print \$1}')\"
    [ \"\$actual\" = \"\$expected\" ] || {
      echo \"transferred sha256 mismatch for \$path\" >&2
      exit 1
    }
  done
  \"\$stage/install-helper\" \
    '$WEBROOT' '$tag' '$publication_id' \
    \"\$stage/publication-manifest.json\" \
    \"\$stage/$dmg_name\" \
    \"\$stage/appcast.xml\" \
    \"\$stage/${dmg_name}.sha256\"
"
remote_stage=""

printf '[publish-malibu-latest-dmg] ok: %s/%s + latest.dmg on Pearl (release=%s assets=%s,%s commit=%s)\n' \
  "$WEBROOT" "$dmg_name" "$release_number" "$dmg_asset_id" "$appcast_asset_id" "$commit"

if [[ "${VERIFY_MALIBU_DOWNLOAD:-0}" == 1 ]]; then
  bash "$SCRIPT_DIR/verify-malibu-download.sh"
fi
