#!/usr/bin/env bash
# Publish a locally captured, signed Malibu release set to Pearl.
set -euo pipefail

die() {
  printf '[publish-malibu-latest-dmg] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 9 ]] ||
  die "usage: $0 MANIFEST DMG APPCAST ARTIFACT_INDEX CHECKSUMS SIGNATURE PROVENANCE ACCEPTANCE_CANDIDATE ACCEPTANCE_CANDIDATE_SIG"

manifest="$1"
asset="$2"
appcast="$3"
artifact_index="$4"
checksums="$5"
signature="$6"
provenance="$7"
# Signed acceptance-candidate produced by acceptance-candidate.yml (schema
# macprovider.acceptance-candidate.v1, channel acceptance). Empty for the frozen
# v1.8.39 bootstrap bridge, required for generalized stable promotions. The
# signature/expiry are enforced by the coordinator's acceptance gate; this
# script only transfers and places the already-signed files.
acceptance_candidate="$8"
acceptance_signature="$9"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$SCRIPT_DIR/verify-malibu-publication-set.sh" \
  "$manifest" "$asset" "$appcast" "$artifact_index" \
  "$checksums" "$signature" "$provenance"

read -r tag commit release_number publication_id repository dmg_asset_id appcast_asset_id < <(
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
    manifest["repository"],
    assets[f"Malibu-{tag}.dmg"]["id"],
    # Non-v1.8.39 promotions ship the frozen bridge appcast, which is not a
    # per-release GitHub asset, so it has no numeric manifest asset id.
    assets.get("appcast.xml", {}).get("id", 0),
)
PY
)
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "manifest tag is invalid"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "manifest commit is invalid"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "manifest repository is invalid"
[[ "$release_number" =~ ^[1-9][0-9]*$ ]] || die "manifest release id is invalid"
[[ "$publication_id" =~ ^[0-9a-f]{64}$ ]] || die "manifest publication id is invalid"
[[ "$dmg_asset_id" =~ ^[1-9][0-9]*$ ]] || die "manifest publication dmg asset id is invalid"
if [[ "$tag" == v1.8.39 ]]; then
  [[ "$appcast_asset_id" =~ ^[1-9][0-9]*$ ]] || die "manifest publication appcast asset id is invalid"
  # The frozen v1.8.39 bootstrap bridge predates the acceptance channel and
  # carries no acceptance-candidate.
  [[ -z "$acceptance_candidate" && -z "$acceptance_signature" ]] ||
    die "the frozen v1.8.39 bridge does not carry an acceptance-candidate"
else
  # The frozen bridge appcast is a committed constant, not a release asset.
  appcast_asset_id="frozen-bridge"
  # Generalized stable promotions must place the signed acceptance-candidate so
  # the coordinator's install-time acceptance gate can enforce it.
  [[ -n "$acceptance_candidate" && -n "$acceptance_signature" ]] ||
    die "generalized Malibu promotion requires the signed acceptance-candidate pair"
  for path in "$acceptance_candidate" "$acceptance_signature"; do
    [[ -f "$path" && ! -L "$path" ]] ||
      die "acceptance-candidate input is not a regular file: $path"
  done
  [[ "$(basename "$acceptance_candidate")" == acceptance-candidate.json ]] ||
    die "acceptance-candidate must be named acceptance-candidate.json"
  [[ "$(basename "$acceptance_signature")" == acceptance-candidate.json.sig ]] ||
    die "acceptance-candidate signature must be named acceptance-candidate.json.sig"
  # Fail closed BEFORE any Pearl transfer/promotion: the immutable release dir
  # would otherwise pin a stale/expired/mismatched candidate that only the
  # installer's die-4 rejects, and the same release id could never be repaired.
  # Runs the same domain-separated ECDSA P-256 validation install.sh uses
  # (schema/channel, signing key macprovider-acceptance-p256-v1, checksums.txt
  # binding, 5m-24h validity window, not expired) and pins the candidate's
  # tag/candidate_commit/compatibility_set_id to this exact release.
  repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
  python3 "$SCRIPT_DIR/acceptance-candidate-metadata.py" verify \
    --input "$acceptance_candidate" \
    --signature "$acceptance_signature" \
    --public-key "$repo_root/security/acceptance-candidate-signing-public.pem" \
    --checksums "$checksums" \
    --repository "$repository" \
    --tag "$tag" \
    --candidate-commit "$commit" ||
    die "acceptance-candidate signature/identity/expiry validation failed"
fi

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
if [[ -n "$acceptance_candidate" ]]; then
  local_paths+=("$acceptance_candidate" "$acceptance_signature")
  remote_names+=(acceptance-candidate.json acceptance-candidate.json.sig)
fi
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
    \"\$stage/${dmg_name}.sha256\" \
    \"\$stage/acceptance-candidate.json\" \"\$stage/acceptance-candidate.json.sig\"
"
remote_stage=""

bash "$SCRIPT_DIR/verify-malibu-bootstrap-publication.sh" \
  "$tag" "$asset" "$appcast"

printf '[publish-malibu-latest-dmg] ok: %s/%s + latest.dmg on Pearl (release=%s assets=%s,%s commit=%s)\n' \
  "$WEBROOT" "$dmg_name" "$release_number" "$dmg_asset_id" "$appcast_asset_id" "$commit"
