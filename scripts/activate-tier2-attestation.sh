#!/usr/bin/env bash
# Guarded SPEC-008 C4b hardware-attestation activation flip.
#
# Default mode is --plan, which prints the intended production actions without
# changing remote state. Pass --apply to change only tier2.require_attestation
# to true, SIGHUP the coordinator, and verify hardware attestation disclosure.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/activate-tier2-attestation.sh [--plan|--apply]

Environment:
  SSH_KEY             default: ~/.ssh/pearl_operator_ed25519
  VPS_HOST            default: 159.223.165.194
  VPS_USER            default: root
  SSH_PORT            default: 22
  REMOTE_CONFIG       default: /opt/macprovider/coordinator.yaml
  SERVICE             default: macprovider-coordinator
  COORDINATOR_ORIGIN  default: https://coordinator.malibu.tech
  GATEWAY_ORIGIN      default: https://api.malibu.tech
  DEMO_TOKEN          required by --apply
  OPERATOR_KEY        required by --apply
  VERIFY_SCRIPT       default: scripts/verify-tier2-live.sh
  SSH_BIN             default: ssh

Apply mode:
  1. Runs VERIFY_SCRIPT --attested to prove C2 remains live and v1.2.6+
     encrypted+attested provider rollout is ready before mutation.
  2. Independently verifies /v1/models and /poolz show all currently routable
     providers are already encrypted and attested.
  3. Backs up REMOTE_CONFIG.
  4. Changes only tier2.require_attestation to true.
  5. Requires existing tier2.catalog_path, tier2.catalog_public_key,
     tier2.require_hash_verified: true, tier2.require_encrypted_leg: true, and
     non-empty tier2.attestation_roots.
  6. Sends SIGHUP to SERVICE.
  7. Requires recent "tier2 config reloaded" journal evidence.
  8. Re-verifies hardware-attestation disclosure.
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
COORDINATOR_ORIGIN="${COORDINATOR_ORIGIN:-https://coordinator.malibu.tech}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-https://api.malibu.tech}"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-$SCRIPT_DIR/verify-tier2-live.sh}"
SSH_BIN="${SSH_BIN:-ssh}"

log() { printf '[tier2-attestation] %s\n' "$*" >&2; }
die() { printf '[tier2-attestation] ERROR: %s\n' "$*" >&2; exit 1; }
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
   DEMO_TOKEN=<redacted> OPERATOR_KEY=<redacted> $VERIFY_SCRIPT --attested
2. Verify live C4b readiness:
   - $GATEWAY_ORIGIN/v1/models reports provider_leg_encryption: all
   - $GATEWAY_ORIGIN/v1/models reports hardware_attestation: all
   - $COORDINATOR_ORIGIN/poolz has at least one ready v1.2.6+ encrypted+attested provider
   - no currently routable provider is missing encrypted_leg=true
   - no currently routable provider has attestation_status other than attested
3. SSH to $VPS_USER@$VPS_HOST and back up:
   $REMOTE_CONFIG
4. Require the existing top-level tier2 block to keep:
   catalog_path: <non-empty>
   catalog_public_key: <non-empty>
   require_hash_verified: true
   require_encrypted_leg: true
   attestation_roots: <non-empty>
5. Change only this field in the existing top-level tier2 block:
   require_attestation: true
6. Send SIGHUP to $SERVICE.
7. Check recent journal evidence for "tier2 config reloaded".
8. Re-verify /v1/models reports hardware_attestation: all.
9. If reload or verification fails, restore the config backup and SIGHUP again.

This script does not change attestation_roots or attestation_formats. Configure
production MDA roots and roll out attested v1.2.6+ providers first; otherwise
readiness verification should fail closed.

To apply production C4b intentionally:
  DEMO_TOKEN=<token> OPERATOR_KEY=<operator-key> scripts/activate-tier2-attestation.sh --apply
PLAN
}

run_attested_verifier() {
  DEMO_TOKEN="$DEMO_TOKEN" \
    OPERATOR_KEY="$OPERATOR_KEY" \
    GATEWAY_ORIGIN="$GATEWAY_ORIGIN" \
    COORDINATOR_ORIGIN="$COORDINATOR_ORIGIN" \
    "$VERIFY_SCRIPT" --attested
}

verify_attestation_state() {
  local models_json poolz_json
  models_json="$(curl -fsS --max-time 10 -H "X-Demo-Token: $DEMO_TOKEN" "$GATEWAY_ORIGIN/v1/models")"
  poolz_json="$(curl -fsS --max-time 10 -H "Authorization: Bearer $OPERATOR_KEY" "$COORDINATOR_ORIGIN/poolz")"
  MODELS_JSON="$models_json" POOLZ_JSON="$poolz_json" python3 - <<'PY'
import json
import os

def fail(message):
    raise SystemExit(f"verify-tier2-attestation: {message}")

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
leg_reported = tier1.get("provider_leg_encryption")
if leg_reported != "all":
    fail(f"tier1_disclosure.provider_leg_encryption={leg_reported!r}, want 'all'")
attestation_reported = tier1.get("hardware_attestation")
if attestation_reported != "all":
    fail(f"tier1_disclosure.hardware_attestation={attestation_reported!r}, want 'all'")

tier2_candidates = [models.get("tier2"), tier1.get("tier2")]
encrypted = None
attestation = None
for candidate in tier2_candidates:
    if not isinstance(candidate, dict):
        continue
    if encrypted is None and isinstance(candidate.get("encrypted_leg"), dict):
        encrypted = candidate["encrypted_leg"]
    if attestation is None and isinstance(candidate.get("attestation"), dict):
        attestation = candidate["attestation"]
if encrypted is None:
    fail("/v1/models is missing tier2.encrypted_leg disclosure")
if attestation is None:
    fail("/v1/models is missing tier2.attestation disclosure")
if encrypted.get("state") != "all":
    fail(f"tier2.encrypted_leg.state={encrypted.get('state')!r}, want 'all'")
if int(encrypted.get("unencrypted_provider_count") or 0) != 0:
    fail("tier2.encrypted_leg.unencrypted_provider_count must be 0 before C4b")
if attestation.get("state") != "all":
    fail(f"tier2.attestation.state={attestation.get('state')!r}, want 'all'")
if int(attestation.get("attested_provider_count") or 0) <= 0:
    fail("tier2.attestation.attested_provider_count must be > 0")
if int(attestation.get("unsupported_provider_count") or 0) != 0:
    fail("tier2.attestation.unsupported_provider_count must be 0 before C4b")

providers = poolz.get("pool")
if not isinstance(providers, list):
    fail("/poolz is missing pool list")

ready_attested = []
ready_bad = []
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
    encrypted_leg = provider.get("encrypted_leg") is True
    attestation_status = str(provider.get("attestation_status") or "")
    if encrypted_leg and attestation_status == "attested":
        ready_attested.append(provider)
    else:
        ready_bad.append(provider)

if ready_bad:
    fail("currently routable providers are not encrypted+attested: " + json.dumps([
        {
            "provider_id": p.get("provider_id"),
            "model_id": p.get("model_id"),
            "binary_version": p.get("binary_version"),
            "encrypted_leg": p.get("encrypted_leg"),
            "attestation_status": p.get("attestation_status"),
        }
        for p in ready_bad
    ], sort_keys=True))
if not ready_attested:
    fail("no ready encrypted+attested provider found in /poolz")
ready_old_attested = [
    p for p in ready_attested
    if semver_tuple(p.get("binary_version")) < (1, 2, 6)
]
if ready_old_attested:
    fail("currently routable encrypted+attested providers below v1.2.6: " + json.dumps([
        {
            "provider_id": p.get("provider_id"),
            "model_id": p.get("model_id"),
            "binary_version": p.get("binary_version"),
            "encrypted_leg": p.get("encrypted_leg"),
            "attestation_status": p.get("attestation_status"),
        }
        for p in ready_old_attested
    ], sort_keys=True))
ready_attested_b6 = [
    p for p in ready_attested
    if semver_tuple(p.get("binary_version")) >= (1, 2, 6)
]
if not ready_attested_b6:
    fail("no ready v1.2.6+ encrypted+attested provider found in /poolz")

summary = {
    "model_count": len(models.get("data", [])),
    "provider_leg_encryption": leg_reported,
    "hardware_attestation": attestation_reported,
    "attested_provider_count": attestation.get("attested_provider_count"),
    "ready_attested_provider_count": len(ready_attested),
    "ready_attested_b6_provider_count": len(ready_attested_b6),
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

def strip_yaml_quotes(value):
    return value.strip().strip(chr(34) + chr(39))

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

def list_has_value(key):
    for idx, line in enumerate(lines[start + 1:end], start + 1):
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or ':' not in stripped:
            continue
        raw_key, raw_value = stripped.split(':', 1)
        if raw_key.strip() != key:
            continue
        raw_value = raw_value.split('#', 1)[0].strip()
        if raw_value:
            lowered = raw_value.lower()
            if lowered in ('[]', 'null', '~', chr(34) * 2, chr(39) * 2):
                return False
            if raw_value.startswith('[') and raw_value.endswith(']'):
                inner = raw_value[1:-1].strip()
                return bool(inner)
            return True
        j = idx + 1
        while j < end:
            candidate = lines[j]
            if re.match(r'^  [A-Za-z0-9_-]+:', candidate):
                break
            nested = candidate.strip()
            if nested.startswith('-') and nested[1:].strip():
                return True
            j += 1
        return False
    return False

def list_values(key):
    for idx in range(start + 1, end):
        raw = lines[idx]
        if not raw.startswith('  ') or raw.startswith('    '):
            continue
        if ':' not in raw:
            continue
        raw_key, raw_value = raw.split(':', 1)
        if raw_key.strip() != key:
            continue
        raw_value = raw_value.split('#', 1)[0].strip()
        if raw_value.startswith('[') and raw_value.endswith(']'):
            inner = raw_value[1:-1].strip()
            if not inner:
                return []
            return [strip_yaml_quotes(item) for item in inner.split(',') if item.strip()]
        if raw_value:
            return [strip_yaml_quotes(raw_value)]
        values = []
        j = idx + 1
        while j < end:
            candidate = lines[j]
            if re.match(r'^  [A-Za-z0-9_-]+:', candidate):
                break
            nested = candidate.strip()
            if nested.startswith('-') and nested[1:].strip():
                values.append(strip_yaml_quotes(nested[1:].split('#', 1)[0]))
            j += 1
        return values
    return []

if not value_for('catalog_path'):
    raise SystemExit('tier2.catalog_path must be configured before C4b activation')
if not value_for('catalog_public_key'):
    raise SystemExit('tier2.catalog_public_key must be configured before C4b activation')
if value_for('require_hash_verified') != 'true':
    raise SystemExit('tier2.require_hash_verified must be true before C4b activation')
if value_for('require_encrypted_leg') != 'true':
    raise SystemExit('tier2.require_encrypted_leg must be true before C4b activation')
if not list_has_value('attestation_roots'):
    raise SystemExit('tier2.attestation_roots must be non-empty before C4b activation')
if any(value == 'mock-root' for value in list_values('attestation_roots')):
    raise SystemExit('tier2.attestation_roots must not contain mock-root before C4b activation')

updated_lines = list(lines)
require_idx = None
for idx in range(start + 1, end):
    if lines[idx].strip().startswith('require_attestation:'):
        require_idx = idx
        break

if require_idx is None:
    updated_lines.insert(end, '  require_attestation: true')
elif lines[require_idx].strip() == 'require_attestation: true':
    print('already_attestation=1')
    sys.exit(0)
else:
    updated_lines[require_idx] = '  require_attestation: true'

updated = '\\n'.join(updated_lines).rstrip() + '\\n'
if updated == original:
    print('already_attestation=1')
    sys.exit(0)

st = os.stat(path)
backup = f'{path}.bak-c4b-{time.strftime(\"%Y%m%d%H%M%S\", time.gmtime())}'
shutil.copy2(path, backup)
os.chown(backup, st.st_uid, st.st_gid)
os.chmod(backup, st.st_mode & 0o777)
print(f'config_backup={backup}', flush=True)
tmp = f'{path}.tmp-c4b-{os.getpid()}'
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(updated)
os.chown(tmp, st.st_uid, st.st_gid)
os.chmod(tmp, st.st_mode & 0o777)
os.replace(tmp, path)
print('updated require_attestation=true')
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

  log "running attested readiness verifier before C4b activation"
  run_attested_verifier

  log "verifying attested provider readiness before mutation"
  verify_attestation_state

  log "patching live config"
  local patch_output config_backup
  if ! patch_output="$(remote_patch_config)"; then
    printf '%s\n' "$patch_output" >&2
    die "live config attestation patch failed"
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

  log "verifying hardware-attestation disclosure"
  if ! verify_attestation_state; then
    rollback_and_exit "gateway hardware-attestation disclosure verification failed" "$config_backup"
  fi

  log "C4b hardware-attestation enforcement verified"
}

if [ "$mode" = "plan" ]; then
  print_plan
else
  apply_changes
fi
