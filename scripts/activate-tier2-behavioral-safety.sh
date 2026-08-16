#!/usr/bin/env bash
# Guarded SPEC-008 C3 behavioral-safety activation flip.
#
# Default mode is --plan, which prints the intended production actions without
# changing remote state. Pass --apply to enable only the Tier-2 Pillar D config
# keys, SIGHUP the coordinator, and verify the public disclosure. This script
# expects the B3-capable coordinator and gateway binaries to be deployed first.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/activate-tier2-behavioral-safety.sh [--plan|--apply]

Environment:
  SSH_KEY                         default: ~/.ssh/pearl_operator_ed25519
  VPS_HOST                        default: 159.223.165.194
  VPS_USER                        default: root
  SSH_PORT                        default: 22
  REMOTE_CONFIG                   default: /opt/macprovider/coordinator.yaml
  SERVICE                         default: macprovider-coordinator
  COORDINATOR_ORIGIN              default: https://coordinator.malibu.tech
  GATEWAY_ORIGIN                  default: https://api.malibu.tech
  DEMO_TOKEN                      required by --apply
  OPERATOR_KEY                    required by --apply
  VERIFY_SCRIPT                   default: scripts/verify-tier2-live.sh
  SSH_BIN                         default: ssh
  OUTPUT_SIZE_CAP_BYTES           default: 1048576
  OUTPUT_BYTES_PER_TOKEN_CEILING  default: 16
  DEFAULT_OUTPUT_SIZE_CAP_BYTES   default: 1048576
  ENCODING_VALIDATION_ENABLED     default: true
  RESPONSE_TIME_ANOMALY_ENABLED   default: true
  RESPONSE_TIME_ANOMALY_FACTOR    default: 5.0
  RESPONSE_TIME_ANOMALY_MIN_MS    default: 10000

Apply mode:
  1. Runs VERIFY_SCRIPT --enforced to prove C2 is live before mutation.
  2. Backs up REMOTE_CONFIG.
  3. Changes only behavioral-safety keys in the existing top-level tier2 block.
  4. Requires existing tier2.catalog_path, tier2.catalog_public_key, and
     tier2.require_hash_verified: true.
  5. Sends SIGHUP to SERVICE.
  6. Requires recent "tier2 config reloaded" journal evidence.
  7. Verifies /v1/models reports matching behavioral_safety state and
     tier1_disclosure.untrusted_provider_safety.
  8. Restores the config backup and SIGHUPs again if reload or verification fails.
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

BEHAVIORAL_SAFETY_ENABLED="true"
OUTPUT_SIZE_CAP_BYTES="${OUTPUT_SIZE_CAP_BYTES:-1048576}"
OUTPUT_BYTES_PER_TOKEN_CEILING="${OUTPUT_BYTES_PER_TOKEN_CEILING:-16}"
DEFAULT_OUTPUT_SIZE_CAP_BYTES="${DEFAULT_OUTPUT_SIZE_CAP_BYTES:-1048576}"
ENCODING_VALIDATION_ENABLED="${ENCODING_VALIDATION_ENABLED:-true}"
RESPONSE_TIME_ANOMALY_ENABLED="${RESPONSE_TIME_ANOMALY_ENABLED:-true}"
RESPONSE_TIME_ANOMALY_FACTOR="${RESPONSE_TIME_ANOMALY_FACTOR:-5.0}"
RESPONSE_TIME_ANOMALY_MIN_MS="${RESPONSE_TIME_ANOMALY_MIN_MS:-10000}"

log() { printf '[tier2-behavioral] %s\n' "$*" >&2; }
die() { printf '[tier2-behavioral] ERROR: %s\n' "$*" >&2; exit 1; }
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

normalize_bool_var() {
  local name="$1"
  local value="${!name}"
  case "$value" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) printf 'true' ;;
    0|false|FALSE|False|no|NO|No|off|OFF|Off) printf 'false' ;;
    *) die "$name must be true or false, got: $value" ;;
  esac
}

validate_local_values() {
  require_command python3
  ENCODING_VALIDATION_ENABLED="$(normalize_bool_var ENCODING_VALIDATION_ENABLED)"
  RESPONSE_TIME_ANOMALY_ENABLED="$(normalize_bool_var RESPONSE_TIME_ANOMALY_ENABLED)"
  python3 - \
    "$OUTPUT_SIZE_CAP_BYTES" \
    "$OUTPUT_BYTES_PER_TOKEN_CEILING" \
    "$DEFAULT_OUTPUT_SIZE_CAP_BYTES" \
    "$RESPONSE_TIME_ANOMALY_FACTOR" \
    "$RESPONSE_TIME_ANOMALY_MIN_MS" <<'PY'
import sys

cap, ceiling, default_cap, factor, min_ms = sys.argv[1:6]

def parse_int(name, raw):
    try:
        value = int(raw)
    except ValueError:
        raise SystemExit(f"{name} must be an integer")
    return value

cap = parse_int("OUTPUT_SIZE_CAP_BYTES", cap)
ceiling = parse_int("OUTPUT_BYTES_PER_TOKEN_CEILING", ceiling)
default_cap = parse_int("DEFAULT_OUTPUT_SIZE_CAP_BYTES", default_cap)
min_ms = parse_int("RESPONSE_TIME_ANOMALY_MIN_MS", min_ms)
try:
    factor_value = float(factor)
except ValueError:
    raise SystemExit("RESPONSE_TIME_ANOMALY_FACTOR must be numeric")
if cap < 0:
    raise SystemExit("OUTPUT_SIZE_CAP_BYTES must be >= 0")
if ceiling <= 0:
    raise SystemExit("OUTPUT_BYTES_PER_TOKEN_CEILING must be > 0")
if default_cap <= 0:
    raise SystemExit("DEFAULT_OUTPUT_SIZE_CAP_BYTES must be > 0")
if factor_value <= 1.0:
    raise SystemExit("RESPONSE_TIME_ANOMALY_FACTOR must be > 1.0")
if min_ms < 0:
    raise SystemExit("RESPONSE_TIME_ANOMALY_MIN_MS must be >= 0")
PY
}

expected_safety_state() {
  local controls=0
  local cap_active=0
  local encoding_active=0
  local anomaly_active=0
  if [ "$OUTPUT_SIZE_CAP_BYTES" -gt 0 ]; then
    cap_active=1
    controls=$((controls + 1))
  fi
  if [ "$ENCODING_VALIDATION_ENABLED" = "true" ]; then
    encoding_active=1
    controls=$((controls + 1))
  fi
  if [ "$RESPONSE_TIME_ANOMALY_ENABLED" = "true" ]; then
    anomaly_active=1
    controls=$((controls + 1))
  fi
  if [ "$cap_active" -eq 1 ] && [ "$encoding_active" -eq 1 ] && [ "$anomaly_active" -eq 1 ]; then
    printf 'enforced'
  elif [ "$controls" -gt 0 ]; then
    printf 'partial'
  else
    printf 'none'
  fi
}

print_plan() {
  local expected
  expected="$(expected_safety_state)"
  cat <<PLAN
Plan only. No production state was changed.

Would perform:
1. Run:
   DEMO_TOKEN=<redacted> OPERATOR_KEY=<redacted> $VERIFY_SCRIPT --enforced
2. SSH to $VPS_USER@$VPS_HOST and back up:
   $REMOTE_CONFIG
3. Require the existing top-level tier2 block to keep:
   catalog_path: <non-empty>
   catalog_public_key: <non-empty>
   require_hash_verified: true
4. Change only these behavioral-safety fields in the existing top-level tier2 block:
   behavioral_safety_enabled: true
   output_size_cap_bytes: $OUTPUT_SIZE_CAP_BYTES
   output_bytes_per_token_ceiling: $OUTPUT_BYTES_PER_TOKEN_CEILING
   default_output_size_cap_bytes: $DEFAULT_OUTPUT_SIZE_CAP_BYTES
   encoding_validation_enabled: $ENCODING_VALIDATION_ENABLED
   response_time_anomaly_enabled: $RESPONSE_TIME_ANOMALY_ENABLED
   response_time_anomaly_factor: $RESPONSE_TIME_ANOMALY_FACTOR
   response_time_anomaly_min_ms: $RESPONSE_TIME_ANOMALY_MIN_MS
5. Send SIGHUP to $SERVICE.
6. Check recent journal evidence for "tier2 config reloaded".
7. Verify $GATEWAY_ORIGIN/v1/models reports:
   tier2.behavioral_safety.state: $expected
   tier1_disclosure.untrusted_provider_safety: $expected
8. If reload or verification fails, restore the config backup and SIGHUP again.

This script does not change tier2.catalog_path, tier2.catalog_public_key, or
tier2.require_hash_verified. Deploy B3-capable coordinator and gateway binaries
before apply; otherwise the disclosure verification will fail and rollback.

To apply production C3 intentionally:
  DEMO_TOKEN=<token> OPERATOR_KEY=<operator-key> scripts/activate-tier2-behavioral-safety.sh --apply
PLAN
}

run_enforced_verifier() {
  DEMO_TOKEN="$DEMO_TOKEN" \
    OPERATOR_KEY="$OPERATOR_KEY" \
    GATEWAY_ORIGIN="$GATEWAY_ORIGIN" \
    COORDINATOR_ORIGIN="$COORDINATOR_ORIGIN" \
    "$VERIFY_SCRIPT" --enforced
}

remote_patch_config() {
  local q_remote_config
  local q_behavioral_safety_enabled
  local q_output_size_cap_bytes
  local q_output_bytes_per_token_ceiling
  local q_default_output_size_cap_bytes
  local q_encoding_validation_enabled
  local q_response_time_anomaly_enabled
  local q_response_time_anomaly_factor
  local q_response_time_anomaly_min_ms
  q_remote_config="$(shell_quote "$REMOTE_CONFIG")"
  q_behavioral_safety_enabled="$(shell_quote "$BEHAVIORAL_SAFETY_ENABLED")"
  q_output_size_cap_bytes="$(shell_quote "$OUTPUT_SIZE_CAP_BYTES")"
  q_output_bytes_per_token_ceiling="$(shell_quote "$OUTPUT_BYTES_PER_TOKEN_CEILING")"
  q_default_output_size_cap_bytes="$(shell_quote "$DEFAULT_OUTPUT_SIZE_CAP_BYTES")"
  q_encoding_validation_enabled="$(shell_quote "$ENCODING_VALIDATION_ENABLED")"
  q_response_time_anomaly_enabled="$(shell_quote "$RESPONSE_TIME_ANOMALY_ENABLED")"
  q_response_time_anomaly_factor="$(shell_quote "$RESPONSE_TIME_ANOMALY_FACTOR")"
  q_response_time_anomaly_min_ms="$(shell_quote "$RESPONSE_TIME_ANOMALY_MIN_MS")"

  "${SSH[@]}" "REMOTE_CONFIG=$q_remote_config BEHAVIORAL_SAFETY_ENABLED=$q_behavioral_safety_enabled OUTPUT_SIZE_CAP_BYTES=$q_output_size_cap_bytes OUTPUT_BYTES_PER_TOKEN_CEILING=$q_output_bytes_per_token_ceiling DEFAULT_OUTPUT_SIZE_CAP_BYTES=$q_default_output_size_cap_bytes ENCODING_VALIDATION_ENABLED=$q_encoding_validation_enabled RESPONSE_TIME_ANOMALY_ENABLED=$q_response_time_anomaly_enabled RESPONSE_TIME_ANOMALY_FACTOR=$q_response_time_anomaly_factor RESPONSE_TIME_ANOMALY_MIN_MS=$q_response_time_anomaly_min_ms python3 - <<'PY'
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
    raise SystemExit('tier2.catalog_path must be configured before C3 activation')
if not value_for('catalog_public_key'):
    raise SystemExit('tier2.catalog_public_key must be configured before C3 activation')
if value_for('require_hash_verified') != 'true':
    raise SystemExit('tier2.require_hash_verified must be true before C3 activation')

updates = [
    ('behavioral_safety_enabled', os.environ['BEHAVIORAL_SAFETY_ENABLED']),
    ('output_size_cap_bytes', os.environ['OUTPUT_SIZE_CAP_BYTES']),
    ('output_bytes_per_token_ceiling', os.environ['OUTPUT_BYTES_PER_TOKEN_CEILING']),
    ('default_output_size_cap_bytes', os.environ['DEFAULT_OUTPUT_SIZE_CAP_BYTES']),
    ('encoding_validation_enabled', os.environ['ENCODING_VALIDATION_ENABLED']),
    ('response_time_anomaly_enabled', os.environ['RESPONSE_TIME_ANOMALY_ENABLED']),
    ('response_time_anomaly_factor', os.environ['RESPONSE_TIME_ANOMALY_FACTOR']),
    ('response_time_anomaly_min_ms', os.environ['RESPONSE_TIME_ANOMALY_MIN_MS']),
]
update_keys = {key for key, _ in updates}

updated_lines = list(lines)
seen = set()
for idx in range(start + 1, end):
    stripped = lines[idx].strip()
    if not stripped or stripped.startswith('#') or ':' not in stripped:
        continue
    key = stripped.split(':', 1)[0].strip()
    if key in update_keys:
        value = dict(updates)[key]
        updated_lines[idx] = f'  {key}: {value}'
        seen.add(key)

insert_at = end
for key, value in updates:
    if key not in seen:
        updated_lines.insert(insert_at, f'  {key}: {value}')
        insert_at += 1

updated = '\\n'.join(updated_lines).rstrip() + '\\n'
if updated == original:
    print('already_behavioral_safety=1')
    sys.exit(0)

st = os.stat(path)
backup = f'{path}.bak-c3-{time.strftime(\"%Y%m%d%H%M%S\", time.gmtime())}'
shutil.copy2(path, backup)
os.chown(backup, st.st_uid, st.st_gid)
os.chmod(backup, st.st_mode & 0o777)
print(f'config_backup={backup}', flush=True)
tmp = f'{path}.tmp-c3-{os.getpid()}'
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(updated)
os.chown(tmp, st.st_uid, st.st_gid)
os.chmod(tmp, st.st_mode & 0o777)
os.replace(tmp, path)
print('updated tier2 behavioral safety')
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

verify_behavioral_disclosure() {
  local expected="$1"
  local models_json
  models_json="$(curl -fsS --max-time 10 -H "X-Demo-Token: $DEMO_TOKEN" "$GATEWAY_ORIGIN/v1/models")"
  MODELS_JSON="$models_json" python3 - "$expected" <<'PY'
import json
import os
import sys

expected = sys.argv[1]

def fail(message):
    raise SystemExit(f"verify-tier2-behavioral: {message}")

try:
    body = json.loads(os.environ["MODELS_JSON"])
except json.JSONDecodeError as exc:
    fail(f"/v1/models returned invalid JSON: {exc}")

tier2 = body.get("tier2")
if not isinstance(tier2, dict):
    fail("/v1/models is missing top-level tier2 block")
behavioral = tier2.get("behavioral_safety")
if not isinstance(behavioral, dict):
    fail("/v1/models is missing tier2.behavioral_safety block")
state = behavioral.get("state")
if state != expected:
    fail(f"tier2.behavioral_safety.state={state!r}, want {expected!r}")

disclosure = body.get("tier1_disclosure")
if not isinstance(disclosure, dict):
    fail("/v1/models is missing tier1_disclosure")
reported = disclosure.get("untrusted_provider_safety")
if reported != expected:
    fail(f"tier1_disclosure.untrusted_provider_safety={reported!r}, want {expected!r}")

if expected == "enforced":
    for key in ("size_cap", "encoding_validation", "ttft_anomaly_logging"):
        if behavioral.get(key) is not True:
            fail(f"tier2.behavioral_safety.{key} is not true")

summary = {
    "model_count": len(body.get("data", [])),
    "tier2_phase": tier2.get("phase"),
    "behavioral_safety_state": state,
    "untrusted_provider_safety": reported,
    "size_cap": behavioral.get("size_cap"),
    "encoding_validation": behavioral.get("encoding_validation"),
    "ttft_anomaly_logging": behavioral.get("ttft_anomaly_logging"),
}
print(json.dumps(summary, indent=2, sort_keys=True))
PY
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

  local expected
  expected="$(expected_safety_state)"

  log "running enforced C2 verifier before C3 activation"
  run_enforced_verifier

  log "patching live config"
  local patch_output config_backup
  if ! patch_output="$(remote_patch_config)"; then
    printf '%s\n' "$patch_output" >&2
    die "live config behavioral-safety patch failed"
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

  log "verifying gateway behavioral-safety disclosure"
  if ! verify_behavioral_disclosure "$expected"; then
    rollback_and_exit "gateway behavioral-safety disclosure verification failed" "$config_backup"
  fi

  log "C3 behavioral safety verified"
}

validate_local_values
if [ "$mode" = "plan" ]; then
  print_plan
else
  apply_changes
fi
