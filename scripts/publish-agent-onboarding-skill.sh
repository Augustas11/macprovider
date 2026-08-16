#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[publish-agent-onboarding-skill] ERROR: %s\n' "$*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
skill="${1:-$REPO_ROOT/docs/agent-onboarding/SKILL.md}"
index="${2:-$REPO_ROOT/docs/agent-onboarding/.well-known/skills/index.json}"
validator="$SCRIPT_DIR/verify-agent-onboarding-skill.py"
helper="$SCRIPT_DIR/install-agent-onboarding-publication.sh"
WEBROOT="${MALIBU_GET_WEBROOT:-/var/www/malibu-get}"
GET_HOST="${MALIBU_GET_HOST:-get.malibu.tech}"
VPS_HOST="${MALIBU_GET_VPS_HOST:-${MALIBU_DOWNLOAD_VPS_HOST:-159.223.165.194}}"
SSH_KEY="${MALIBU_GET_SSH_KEY:-${MALIBU_DOWNLOAD_SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}}"
VPS_USER="${MALIBU_GET_VPS_USER:-${MALIBU_DOWNLOAD_VPS_USER:-root}}"
MALIBU_DOWNLOAD_KNOWN_HOSTS="${MALIBU_GET_KNOWN_HOSTS:-${MALIBU_DOWNLOAD_KNOWN_HOSTS:-$SCRIPT_DIR/dist/malibu-download-known_hosts}}"

[[ "$WEBROOT" =~ ^/[A-Za-z0-9._/-]+$ && "$WEBROOT" != *'/../'* && "$WEBROOT" != */.. ]] ||
  die "unsafe get webroot"
[[ "$GET_HOST" == "get.malibu.tech" ]] || die "unexpected get host: $GET_HOST"
[[ "$VPS_USER" == root ]] || die "get publication requires the root SSH account"
[[ -f "$SSH_KEY" && ! -L "$SSH_KEY" ]] ||
  die "SSH key missing or symlinked: $SSH_KEY (refusing partial get publication)"

PYTHONDONTWRITEBYTECODE=1 python3 "$validator" --skill "$skill" --index "$index"

# shellcheck source=scripts/malibu-download-ssh.sh
source "$SCRIPT_DIR/malibu-download-ssh.sh"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

remote_stage="$(malibu_download_ssh 'set -eu
  umask 077
  install -d -o root -g root -m 0700 /root/.malibu-agent-onboarding-publish
  stage="$(mktemp -d /root/.malibu-agent-onboarding-publish/stage.XXXXXXXX)"
  chown root:root "$stage"
  chmod 0700 "$stage"
  printf "%s\n" "$stage"')"
[[ "$remote_stage" =~ ^/root/\.malibu-agent-onboarding-publish/stage\.[A-Za-z0-9]+$ ]] ||
  die "Pearl returned an unsafe staging path"

cleanup() {
  if [[ -n "${remote_stage:-}" ]]; then
    malibu_download_ssh "rm -rf -- '$remote_stage'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

declare -a local_paths=("$skill" "$index" "$validator" "$helper")
declare -a remote_names=(skill.md index.json validator.py install-helper)
declare -a expected_hashes=()
for i in "${!local_paths[@]}"; do
  expected_hashes+=("$(sha256_file "${local_paths[$i]}")")
  malibu_download_scp \
    "${local_paths[$i]}" \
    "$VPS_USER@$VPS_HOST:$remote_stage/${remote_names[$i]}" >/dev/null
done

specs=""
for i in "${!remote_names[@]}"; do
  mode=0600
  [[ "${remote_names[$i]}" == install-helper ]] && mode=0700
  specs+=" '${remote_names[$i]}:${expected_hashes[$i]}:$mode'"
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
  PYTHONDONTWRITEBYTECODE=1 python3 \"\$stage/validator.py\" \
    --skill \"\$stage/skill.md\" \
    --index \"\$stage/index.json\" \
    --no-reference-existence
  \"\$stage/install-helper\" '$WEBROOT' \
    \"\$stage/skill.md\" \"\$stage/index.json\" \"\$stage/validator.py\"
"
remote_stage=""

MALIBU_AGENT_ONBOARDING_HOST="$GET_HOST" \
  bash "$SCRIPT_DIR/verify-agent-onboarding-hosted.sh" "$skill" "$index"

printf '[publish-agent-onboarding-skill] ok: %s/skill.md\n' "$GET_HOST"
