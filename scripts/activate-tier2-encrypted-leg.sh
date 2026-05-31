#!/usr/bin/env bash
# Guarded SPEC-008 C4a encrypted-leg activation flip.
#
# Default mode is --plan, which prints the intended production actions without
# changing remote state. Pass --apply to change only tier2.require_encrypted_leg
# to true, SIGHUP the coordinator, and verify provider-leg encryption disclosure.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/activate-tier2-encrypted-leg.sh [--plan|--apply]

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
  1. Runs VERIFY_SCRIPT --b6-ready to prove C2 remains live and v1.2.6+
     encrypted-provider rollout is ready before mutation.
  2. Verifies /v1/models and /poolz show all currently routable provider legs
     are Pillar-B encrypted.
  3. Backs up REMOTE_CONFIG.
  4. Changes only tier2.require_encrypted_leg to true.
  5. Requires existing tier2.catalog_path, tier2.catalog_public_key, and
     tier2.require_hash_verified: true.
  6. Sends SIGHUP to SERVICE.
  7. Requires recent "tier2 config reloaded" journal evidence.
  8. Re-verifies provider-leg encryption disclosure.
  9. Restores the config backup and SIGHUPs again if reload or verification
     fails.
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

log() { printf '[tier2-encrypted-leg] %s\n' "$*" >&2; }
die() { printf '[tier2-encrypted-leg] ERROR: %s\n' "$*" >&2; exit 1; }
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
   DEMO_TOKEN=<redacted> OPERATOR_KEY=<redacted> $VERIFY_SCRIPT --b6-ready
2. Verify live C4a readiness:
   - $GATEWAY_ORIGIN/v1/models reports provider_leg_encryption: all
   - $COORDINATOR_ORIGIN/poolz has at least one ready v1.2.6+ encrypted provider
   - no currently routable provider is missing encrypted_leg=true
3. SSH to $VPS_USER@$VPS_HOST and back up:
   $REMOTE_CONFIG
4. Require the existing top-level tier2 block to keep:
   catalog_path: <non-empty>
   catalog_public_key: <non-empty>
   require_hash_verified: true
5. Change only this field in the existing top-level tier2 block:
   require_encrypted_leg: true
6. Send SIGHUP to $SERVICE.
7. Check recent journal evidence for "tier2 config reloaded".
8. Re-verify /v1/models reports provider_leg_encryption: all.
9. If reload or verification fails, restore the config backup and SIGHUP again.

This script does not enable require_attestation and does not change
encrypted_leg_aead or rekey thresholds. Publish and roll out the v1.2.6+
provider first; otherwise readiness verification should fail closed.

To apply production C4a intentionally:
  DEMO_TOKEN=<token> OPERATOR_KEY=<operator-key> scripts/activate-tier2-encrypted-leg.sh --apply
PLAN
}

run_b6_ready_verifier() {
  DEMO_TOKEN="$DEMO_TOKEN" \
    OPERATOR_KEY="$OPERATOR_KEY" \
    GATEWAY_ORIGIN="$GATEWAY_ORIGIN" \
    COORDINATOR_ORIGIN="$COORDINATOR_ORIGIN" \
    "$VERIFY_SCRIPT" --b6-ready
}

verify_encrypted_leg_state() {
  local models_json poolz_json
  models_json="$(curl -fsS --max-time 10 -H "X-Demo-Token: $DEMO_TOKEN" "$GATEWAY_ORIGIN/v1/models")"
  poolz_json="$(curl -fsS --max-time 10 -H "Authorization: Bearer $OPERATOR_KEY" "$COORDINATOR_ORIGIN/poolz")"
  MODELS_JSON="$models_json" POOLZ_JSON="$poolz_json" python3 - <<'PY'
import json
import os

def fail(message):
    raise SystemExit(f"verify-tier2-encrypted-leg: {message}")

def semver_tuple(version):
    version = str(version or "").strip()
    if version.startswith(("v", "V")):
        version = version[1:]
    parts = []
    for raw in version.split("."):
        digits = ""
        for ch in raw:
            if not ch.isdigit():
                break
            digits += ch
        parts.append(int(digits or "0"))
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])

try:
    models = json.loads(os.environ["MODELS_JSON"])
except json.JSONDecodeError as exc:
    fail(f"/v1/models returned invalid JSON: {exc}")
try:
    poolz = json.loads(os.environ["POOLZ_JSON"])
except json.JSONDecodeError as exc:
    fail(f"/poolz returned invalid JSON: {exc}")

tier1 = models.get("tier1_disclosure")
if not isinstance(tier1, dict):
    fail("/v1/models is missing tier1_disclosure")
reported = tier1.get("provider_leg_encryption")
if reported != "all":
    fail(f"tier1_disclosure.provider_leg_encryption={reported!r}, want 'all'")

encrypted = None
for candidate in (models.get("tier2"), tier1.get("tier2")):
    if isinstance(candidate, dict) and isinstance(candidate.get("encrypted_leg"), dict):
        encrypted = candidate["encrypted_leg"]
        break
if encrypted is None:
    fail("/v1/models is missing tier2.encrypted_leg disclosure")
state = encrypted.get("state")
if state != "all":
    fail(f"tier2.encrypted_leg.state={state!r}, want 'all'")
if encrypted.get("scope") not in ("coordinator_to_provider_only", None):
    fail(f"tier2.encrypted_leg.scope={encrypted.get('scope')!r}, want coordinator_to_provider_only")
if int(encrypted.get("encrypted_provider_count") or 0) <= 0:
    fail("tier2.encrypted_leg.encrypted_provider_count must be > 0")
if int(encrypted.get("unencrypted_provider_count") or 0) != 0:
    fail("tier2.encrypted_leg.unencrypted_provider_count must be 0 before C4a")

providers = poolz.get("pool")
if not isinstance(providers, list):
    fail("/poolz is missing pool list")

ready_encrypted = []
ready_plain = []
for provider in providers:
    if not isinstance(provider, dict):
        continue
    state = str(provider.get("state") or "")
    slots_free = provider.get("slots_free", 0)
    try:
        slots_free = int(slots_free)
    except (TypeError, ValueError):
        slots_free = 0
    if state != "ready" or slots_free <= 0:
        continue
    if provider.get("encrypted_leg") is True:
        ready_encrypted.append(provider)
    else:
        ready_plain.append(provider)

if ready_plain:
    fail("currently routable providers missing encrypted_leg=true: " + json.dumps([
        {
            "provider_id": p.get("provider_id"),
            "model_id": p.get("model_id"),
            "binary_version": p.get("binary_version"),
            "encrypted_leg": p.get("encrypted_leg"),
        }
        for p in ready_plain
    ], sort_keys=True))
if not ready_encrypted:
    fail("no ready encrypted provider found in /poolz")
ready_old_encrypted = [
    p for p in ready_encrypted
    if semver_tuple(p.get("binary_version")) < (1, 2, 6)
]
if ready_old_encrypted:
    fail("currently routable encrypted providers below v1.2.6: " + json.dumps([
        {
            "provider_id": p.get("provider_id"),
            "model_id": p.get("model_id"),
            "binary_version": p.get("binary_version"),
            "encrypted_leg": p.get("encrypted_leg"),
        }
        for p in ready_old_encrypted
    ], sort_keys=True))
ready_b6 = [
    p for p in ready_encrypted
    if semver_tuple(p.get("binary_version")) >= (1, 2, 6)
]
if not ready_b6:
    fail("no ready v1.2.6+ encrypted provider found in /poolz")

summary = {
    "model_count": len(models.get("data", [])),
    "provider_leg_encryption": reported,
    "encrypted_provider_count": encrypted.get("encrypted_provider_count"),
    "ready_encrypted_provider_count": len(ready_encrypted),
    "ready_b6_provider_count": len(ready_b6),
}
print(json.dumps(summary, indent=2, sort_keys=True))
PY
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

def value_for(key):
    for line in block[1:]:
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or ':' not in stripped:
            continue
        raw_key, raw_value = stripped.split(':', 1)
        if raw_key.strip() == key:
            value = raw_value.split('#', 1)[0].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in (chr(34), chr(39)):
                value = value[1:-1]
            return value.lower()
    return ''

if not value_for('catalog_path'):
    raise SystemExit('tier2.catalog_path must be configured before C4a activation')
if not value_for('catalog_public_key'):
    raise SystemExit('tier2.catalog_public_key must be configured before C4a activation')
if value_for('require_hash_verified') != 'true':
    raise SystemExit('tier2.require_hash_verified must be true before C4a activation')
if value_for('require_attestation') == 'true':
    raise SystemExit('tier2.require_attestation is already true; run C4a separately before C4b')

updated_lines = list(lines)
require_idx = None
for idx in range(start + 1, end):
    if lines[idx].strip().startswith('require_encrypted_leg:'):
        require_idx = idx
        break

if require_idx is None:
    updated_lines.insert(end, '  require_encrypted_leg: true')
elif lines[require_idx].strip() == 'require_encrypted_leg: true':
    print('already_encrypted_leg=1')
    sys.exit(0)
else:
    updated_lines[require_idx] = '  require_encrypted_leg: true'

updated = '\\n'.join(updated_lines).rstrip() + '\\n'
if updated == original:
    print('already_encrypted_leg=1')
    sys.exit(0)

st = os.stat(path)
backup = f'{path}.bak-c4a-{time.strftime(\"%Y%m%d%H%M%S\", time.gmtime())}'
shutil.copy2(path, backup)
os.chown(backup, st.st_uid, st.st_gid)
os.chmod(backup, st.st_mode & 0o777)
print(f'config_backup={backup}', flush=True)
tmp = f'{path}.tmp-c4a-{os.getpid()}'
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(updated)
os.chown(tmp, st.st_uid, st.st_gid)
os.chmod(tmp, st.st_mode & 0o777)
os.replace(tmp, path)
print('updated require_encrypted_leg=true')
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
  require_command curl
  require_command python3
  require_file "$SSH_KEY"
  require_file "$VERIFY_SCRIPT"
  [ -n "${DEMO_TOKEN:-}" ] || die "DEMO_TOKEN is required by --apply"
  [ -n "${OPERATOR_KEY:-}" ] || die "OPERATOR_KEY is required by --apply"

  SSH=("$SSH_BIN" -i "$SSH_KEY" -o ConnectTimeout=10 -p "$SSH_PORT" "$VPS_USER@$VPS_HOST")

  log "running B6 readiness verifier before C4a activation"
  run_b6_ready_verifier

  log "verifying encrypted provider-leg readiness before mutation"
  verify_encrypted_leg_state

  log "patching live config"
  local patch_output config_backup
  if ! patch_output="$(remote_patch_config)"; then
    printf '%s\n' "$patch_output" >&2
    die "live config encrypted-leg patch failed"
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

  log "verifying encrypted provider-leg disclosure"
  if ! verify_encrypted_leg_state; then
    rollback_and_exit "gateway encrypted-leg disclosure verification failed" "$config_backup"
  fi

  log "C4a encrypted-leg enforcement verified"
}

if [ "$mode" = "plan" ]; then
  print_plan
else
  apply_changes
fi
