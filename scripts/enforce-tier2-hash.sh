#!/usr/bin/env bash
# Guarded SPEC-008 C2 enforcement flip.
#
# Default mode is --plan, which prints the intended production actions without
# changing remote state. Pass --apply to change only tier2.require_hash_verified
# to true, SIGHUP the coordinator, and verify with verify-tier2-live --enforced.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/enforce-tier2-hash.sh [--plan|--apply]

Environment:
  SSH_KEY             default: ~/.ssh/pearl_operator_ed25519
  VPS_HOST            default: 159.223.165.194
  VPS_USER            default: root
  SSH_PORT            default: 22
  REMOTE_CONFIG       default: /opt/macprovider/coordinator.yaml
  SERVICE             default: macprovider-coordinator
  COORDINATOR_ORIGIN  default: https://coordinator.streamvc.live
  GATEWAY_ORIGIN      default: https://api.streamvc.live
  DEMO_TOKEN          required by --apply
  OPERATOR_KEY        required by --apply
  VERIFY_SCRIPT       default: scripts/verify-tier2-live.sh
  SSH_BIN             default: ssh

Apply mode:
  1. Runs the full observe-mode verifier before mutation.
  2. Backs up REMOTE_CONFIG.
  3. Changes only tier2.require_hash_verified to true.
  4. Sends SIGHUP to SERVICE.
  5. Requires recent "tier2 config reloaded" journal evidence.
  6. Runs VERIFY_SCRIPT --enforced.
  7. Restores the config backup and SIGHUPs again if reload or verification fails.
USAGE
}

mode="plan"
case "${1:---plan}" in
  --plan) mode="plan" ;;
  --apply) mode="apply" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
REMOTE_CONFIG="${REMOTE_CONFIG:-/opt/macprovider/coordinator.yaml}"
SERVICE="${SERVICE:-macprovider-coordinator}"
COORDINATOR_ORIGIN="${COORDINATOR_ORIGIN:-https://coordinator.streamvc.live}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-https://api.streamvc.live}"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-$SCRIPT_DIR/verify-tier2-live.sh}"
SSH_BIN="${SSH_BIN:-ssh}"

log() { printf '[tier2-enforce] %s\n' "$*" >&2; }
die() { printf '[tier2-enforce] ERROR: %s\n' "$*" >&2; exit 1; }
shell_quote() { printf "%q" "$1"; }
output_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { value = substr($0, index($0, "=") + 1) } END { print value }'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_file() {
  local path="$1"
  [ -f "$path" ] || die "missing file: $path"
}

print_plan() {
  cat <<PLAN
Plan only. No production state was changed.

Would perform:
1. Run:
   DEMO_TOKEN=<redacted> OPERATOR_KEY=<redacted> $VERIFY_SCRIPT --full
2. SSH to $VPS_USER@$VPS_HOST and back up:
   $REMOTE_CONFIG
3. Change only this field in the existing top-level tier2 block:
   require_hash_verified: false -> true
4. Send SIGHUP to $SERVICE.
5. Check recent journal evidence for "tier2 config reloaded".
6. Run:
   DEMO_TOKEN=<redacted> OPERATOR_KEY=<redacted> $VERIFY_SCRIPT --enforced
7. If reload or verification fails, restore the config backup and SIGHUP again.

This script does not change tier2.catalog_path or tier2.catalog_public_key.

To apply production enforcement intentionally:
  DEMO_TOKEN=<token> OPERATOR_KEY=<operator-key> scripts/enforce-tier2-hash.sh --apply
PLAN
}

run_verifier() {
  local verifier_mode="$1"
  DEMO_TOKEN="$DEMO_TOKEN" \
    OPERATOR_KEY="$OPERATOR_KEY" \
    GATEWAY_ORIGIN="$GATEWAY_ORIGIN" \
    COORDINATOR_ORIGIN="$COORDINATOR_ORIGIN" \
    "$VERIFY_SCRIPT" "$verifier_mode"
}

remote_patch_config() {
  local q_remote_config
  q_remote_config="$(shell_quote "$REMOTE_CONFIG")"
  "${SSH[@]}" "REMOTE_CONFIG=$q_remote_config python3 - <<'PY'
import os
import re
import shutil
import sys
import time

path = os.environ['REMOTE_CONFIG']
with open(path, 'r', encoding='utf-8') as f:
    original = f.read()

lines = original.splitlines()
start = None
for i, line in enumerate(lines):
    if line == 'tier2:':
        start = i
        break
if start is None:
    raise SystemExit('missing top-level tier2 block')

top_level_key = re.compile(r'^[A-Za-z0-9_-]+:')
end = start + 1
while end < len(lines) and not top_level_key.match(lines[end]):
    end += 1

block = lines[start:end]
has_catalog_path = any(line.strip().startswith('catalog_path:') and line.split(':', 1)[1].strip() for line in block)
has_catalog_key = any(line.strip().startswith('catalog_public_key:') and line.split(':', 1)[1].strip() for line in block)
if not has_catalog_path or not has_catalog_key:
    raise SystemExit('tier2 catalog_path/catalog_public_key must be configured before enforcement')

updated_lines = list(lines)
require_idx = None
for idx in range(start + 1, end):
    if lines[idx].strip().startswith('require_hash_verified:'):
        require_idx = idx
        break

if require_idx is None:
    updated_lines.insert(end, '  require_hash_verified: true')
elif lines[require_idx].strip() == 'require_hash_verified: true':
    print('already_enforced=1')
    sys.exit(0)
else:
    updated_lines[require_idx] = '  require_hash_verified: true'

updated = '\\n'.join(updated_lines).rstrip() + '\\n'
if updated == original:
    print('already_enforced=1')
    sys.exit(0)

st = os.stat(path)
backup = f'{path}.bak-c2-{time.strftime(\"%Y%m%d%H%M%S\", time.gmtime())}'
shutil.copy2(path, backup)
os.chown(backup, st.st_uid, st.st_gid)
os.chmod(backup, st.st_mode & 0o777)
print(f'config_backup={backup}', flush=True)
tmp = f'{path}.tmp-c2-{os.getpid()}'
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(updated)
os.chown(tmp, st.st_uid, st.st_gid)
os.chmod(tmp, st.st_mode & 0o777)
os.replace(tmp, path)
print('updated require_hash_verified=true')
PY"
}

reload_remote_config() {
  "${SSH[@]}" "set -euo pipefail
    systemctl kill -s HUP $(shell_quote "$SERVICE")
    sleep 2
    systemctl is-active $(shell_quote "$SERVICE")
  "
}

verify_reload_journal() {
  "${SSH[@]}" "journalctl -u $(shell_quote "$SERVICE") --since '-3 min' --no-pager \
    | grep -E 'tier2 config reloaded'"
}

rollback_config() {
  local config_backup="$1"
  [ -n "$config_backup" ] || return 0
  log "restoring previous coordinator config from $config_backup"
  "${SSH[@]}" "set -uo pipefail
    cp -a $(shell_quote "$config_backup") $(shell_quote "$REMOTE_CONFIG")
    systemctl kill -s HUP $(shell_quote "$SERVICE") || true
    sleep 2
    systemctl status --no-pager -n 40 $(shell_quote "$SERVICE") || true
  "
}

rollback_and_exit() {
  local reason="$1"
  local config_backup="$2"
  log "$reason"
  rollback_config "$config_backup"
  exit 1
}

apply_changes() {
  require_command "$SSH_BIN"
  require_file "$SSH_KEY"
  require_file "$VERIFY_SCRIPT"
  [ -n "${DEMO_TOKEN:-}" ] || die "DEMO_TOKEN is required by --apply"
  [ -n "${OPERATOR_KEY:-}" ] || die "OPERATOR_KEY is required by --apply"

  SSH=("$SSH_BIN" -i "$SSH_KEY" -o ConnectTimeout=10 -p "$SSH_PORT" "$VPS_USER@$VPS_HOST")

  log "running full observe-mode verifier before enforcement"
  run_verifier --full

  log "patching live config"
  local patch_output config_backup
  if ! patch_output="$(remote_patch_config)"; then
    printf '%s\n' "$patch_output" >&2
    die "live config enforcement patch failed"
  fi
  printf '%s\n' "$patch_output" >&2
  config_backup="$(printf '%s\n' "$patch_output" | output_value config_backup)"

  log "sending SIGHUP to coordinator"
  if ! reload_remote_config; then
    rollback_and_exit "coordinator SIGHUP reload failed" "$config_backup"
  fi

  log "checking reload journal evidence"
  if ! verify_reload_journal; then
    rollback_and_exit "missing recent tier2 config reload journal evidence" "$config_backup"
  fi

  log "running enforced verifier"
  if ! run_verifier --enforced; then
    rollback_and_exit "enforced verifier failed" "$config_backup"
  fi

  log "C2 enforcement verified"
}

if [ "$mode" = "plan" ]; then
  print_plan
else
  apply_changes
fi
