#!/usr/bin/env bash
# Hermetic safety checks for the guarded SPEC-008 Phase 1 activation helper.
#
# This script replaces ssh/scp/curl with local fakes and runs the production
# activation script against them. It must never contact Pearl VPS or the public
# coordinator/gateway endpoints.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "$TMP_BASE/tier2-activate-safety.XXXXXX")"
FAKE_BIN="$WORKDIR/bin"
FAKE_HOME="$WORKDIR/home"
SSH_KEY="$FAKE_HOME/.ssh/pearl_operator_ed25519"

log() { printf '[tier2-safety] %s\n' "$*" >&2; }
die() { printf '[tier2-safety] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] || [ "${KEEP_TIER2_SAFETY_TMP:-0}" = "1" ]; then
    log "left temp logs at $WORKDIR"
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    printf '%s\n' "--- $file ---" >&2
    [ -f "$file" ] && sed -n '1,220p' "$file" >&2
    die "expected to find: $needle"
  fi
}

assert_empty_or_missing() {
  local file="$1"
  if [ -s "$file" ]; then
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,220p' "$file" >&2
    die "expected empty or missing file: $file"
  fi
}

write_fake_commands() {
  mkdir -p "$FAKE_BIN" "$FAKE_HOME/.ssh"
  printf 'fake ssh key\n' > "$SSH_KEY"
  chmod 0600 "$SSH_KEY"

  cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'curl'
  for arg in "$@"; do printf ' %q' "$arg"; done
  printf '\n'
} >> "$FAKE_LOG_DIR/curl.log"

url="${!#}"
case "${FAKE_CURL_MODE:-success}" in
  live_pool)
    printf '{"status":"ok","pool_size":2,"pool_ready":2}\n'
    ;;
  invalid_health)
    printf 'not-json\n'
    ;;
  gateway_bad)
    if [[ "$url" == */v1/models ]]; then
      printf '{"data":[],"tier2":{"phase":1,"model_hash":{"state":"partial","require_verified":true,"catalog_available":true}}}\n'
    else
      printf '{"status":"ok","pool_size":0,"pool_ready":0}\n'
    fi
    ;;
  success)
    if [[ "$url" == */v1/models ]]; then
      printf '{"data":[{"id":"model-a"}],"tier2":{"phase":1,"model_hash":{"state":"partial","require_verified":false,"catalog_available":true}}}\n'
    else
      printf '{"status":"ok","pool_size":0,"pool_ready":0}\n'
    fi
    ;;
  *)
    printf 'unknown FAKE_CURL_MODE=%s\n' "${FAKE_CURL_MODE:-}" >&2
    exit 64
    ;;
esac
SH
  chmod +x "$FAKE_BIN/curl"

  cat > "$FAKE_BIN/scp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'scp'
  for arg in "$@"; do printf ' %q' "$arg"; done
  printf '\n'
} >> "$FAKE_LOG_DIR/scp.log"

exit 0
SH
  chmod +x "$FAKE_BIN/scp"

  cat > "$FAKE_BIN/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

cmd="${!#}"
{
  printf 'ssh'
  for arg in "$@"; do printf ' %q' "$arg"; done
  printf '\n--- command ---\n%s\n--- end ---\n' "$cmd"
} >> "$FAKE_LOG_DIR/ssh.log"

if [[ "$cmd" == *"install -o macprovider -g macprovider -m 0644"* && "$cmd" == *"tier2-catalog"* ]]; then
  if [ "${FAKE_REMOTE_HAS_CATALOG:-0}" = "1" ]; then
    printf 'catalog_backup=/opt/macprovider/tier2-catalog.json.bak-tier2-FAKE\n'
  else
    printf 'catalog_created=1\n'
  fi
  exit 0
fi

if [[ "$cmd" == *"install -o macprovider -g macprovider -m 0755"* && "$cmd" == *"/opt/macprovider/coordinator"* ]]; then
  printf 'binary_backup=/opt/macprovider/coordinator.bak-tier2-FAKE\n'
  exit 0
fi

if [[ "$cmd" == *"REMOTE_CONFIG="* && "$cmd" == *"python3 - <<'PY'"* ]]; then
  printf 'config_backup=/opt/macprovider/coordinator.yaml.bak-tier2-FAKE\n'
  if [ "${FAKE_SSH_MODE:-success}" = "config_fail" ]; then
    printf 'simulated config merge failure\n' >&2
    exit 73
  fi
  printf 'updated tier2 block\n'
  exit 0
fi

if [[ "$cmd" == *"systemctl restart"* && "$cmd" == *"systemctl is-active"* ]]; then
  printf 'active\n'
  exit 0
fi

if [[ "$cmd" == *"journalctl"* && "$cmd" == *"tier2 catalog loaded|catalog_loaded"* ]]; then
  printf 'May 31 00:00:00 coordinator tier2 catalog loaded event=catalog_loaded model_count=2\n'
  exit 0
fi

if [[ "$cmd" == *"journalctl"* && "$cmd" == *"model_hash_"* ]]; then
  printf 'May 31 00:00:01 coordinator model_hash_verified provider=fake-provider\n'
  exit 0
fi

if [[ "$cmd" == *"systemctl status"* ]]; then
  printf 'fake systemctl status\n'
  exit 0
fi

printf 'unhandled fake ssh command\n' >&2
exit 65
SH
  chmod +x "$FAKE_BIN/ssh"
}

BASE_ENV=(
  "PATH=$FAKE_BIN:$PATH"
  "HOME=$FAKE_HOME"
  "CATALOG=${CATALOG:-$REPO_ROOT/.omc/tier2/tier2-catalog.json}"
  "PUBLIC_KEY_FILE=${PUBLIC_KEY_FILE:-$REPO_ROOT/.omc/tier2/catalog-signing-key.pub}"
  "SSH_KEY=$SSH_KEY"
  "VPS_HOST=fake-pearl.invalid"
  "VPS_USER=root"
  "SSH_PORT=2222"
  "REMOTE_CONFIG=/opt/macprovider/coordinator.yaml"
  "REMOTE_CATALOG=/opt/macprovider/tier2-catalog.json"
  "SERVICE=macprovider-coordinator"
  "COORDINATOR_BINARY=${COORDINATOR_BINARY:-$REPO_ROOT/phase4-coordinator/dist/coordinator-linux-amd64}"
  "COORDINATOR_ORIGIN=https://fake-coordinator.invalid"
  "GATEWAY_ORIGIN=https://fake-gateway.invalid"
)

LAST_STDOUT=""
LAST_STDERR=""
LAST_SCENARIO_DIR=""
LAST_RC=0

run_apply() {
  local name="$1"
  local expected="$2"
  shift 2

  LAST_SCENARIO_DIR="$WORKDIR/$name"
  mkdir -p "$LAST_SCENARIO_DIR"
  LAST_STDOUT="$LAST_SCENARIO_DIR/stdout.txt"
  LAST_STDERR="$LAST_SCENARIO_DIR/stderr.txt"

  set +e
  (
    cd "$REPO_ROOT"
    env "${BASE_ENV[@]}" "FAKE_LOG_DIR=$LAST_SCENARIO_DIR" "$@" \
      "$REPO_ROOT/scripts/activate-tier2-observe.sh" --apply
  ) >"$LAST_STDOUT" 2>"$LAST_STDERR"
  LAST_RC=$?
  set -e

  case "$expected" in
    pass)
      [ "$LAST_RC" -eq 0 ] || {
        sed -n '1,220p' "$LAST_STDOUT" >&2
        sed -n '1,220p' "$LAST_STDERR" >&2
        die "$name: expected success, got exit $LAST_RC"
      }
      ;;
    fail)
      [ "$LAST_RC" -ne 0 ] || die "$name: expected failure, got success"
      ;;
    *)
      die "$name: invalid expected result $expected"
      ;;
  esac
}

restart_guard_refuses_connected_pool() {
  run_apply "restart_guard_refuses_connected_pool" fail \
    "FAKE_CURL_MODE=live_pool" \
    "SKIP_GATEWAY_VERIFY=1"

  assert_contains "$LAST_STDERR" "refusing restart with 2 connected provider(s)"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/ssh.log"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/scp.log"
  log "ok - connected-provider restart guard refused before remote mutation"
}

health_parse_failure_refuses_without_force() {
  run_apply "health_parse_failure_refuses_without_force" fail \
    "FAKE_CURL_MODE=invalid_health" \
    "SKIP_GATEWAY_VERIFY=1"

  assert_contains "$LAST_STDERR" "could not determine connected provider count"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/ssh.log"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/scp.log"
  log "ok - unparseable health refuses before remote mutation"
}

config_merge_failure_rolls_back() {
  run_apply "config_merge_failure_rolls_back" fail \
    "FAKE_CURL_MODE=success" \
    "FAKE_SSH_MODE=config_fail" \
    "FORCE_RESTART=1" \
    "SKIP_GATEWAY_VERIFY=1"

  assert_contains "$LAST_STDERR" "live config tier2 merge failed"
  assert_contains "$LAST_STDERR" "restoring previous coordinator config from /opt/macprovider/coordinator.yaml.bak-tier2-FAKE"
  assert_contains "$LAST_STDERR" "restoring previous coordinator binary from /opt/macprovider/coordinator.bak-tier2-FAKE"
  assert_contains "$LAST_STDERR" "removing newly created remote tier2 catalog"
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "cp -a /opt/macprovider/coordinator.yaml.bak-tier2-FAKE /opt/macprovider/coordinator.yaml"
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "systemctl stop macprovider-coordinator"
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "cp -a /opt/macprovider/coordinator.bak-tier2-FAKE /opt/macprovider/coordinator"
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "rm -f /opt/macprovider/tier2-catalog.json"
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "systemctl restart macprovider-coordinator"
  assert_contains "$LAST_SCENARIO_DIR/scp.log" "tier2-catalog"
  assert_contains "$LAST_SCENARIO_DIR/scp.log" "coordinator-linux-amd64"
  log "ok - config merge failure restores config/binary and removes created catalog"
}

gateway_failure_rolls_back() {
  run_apply "gateway_failure_rolls_back" fail \
    "FAKE_CURL_MODE=gateway_bad" \
    "FORCE_RESTART=1" \
    "DEMO_TOKEN=fake-token"

  assert_contains "$LAST_STDERR" "gateway /v1/models Tier-2 disclosure verification failed"
  assert_contains "$LAST_STDERR" "restoring previous coordinator config from /opt/macprovider/coordinator.yaml.bak-tier2-FAKE"
  assert_contains "$LAST_STDERR" "restoring previous coordinator binary from /opt/macprovider/coordinator.bak-tier2-FAKE"
  assert_contains "$LAST_STDERR" "removing newly created remote tier2 catalog"
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "systemctl stop macprovider-coordinator"
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "systemctl restart macprovider-coordinator"
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "systemctl status --no-pager -n 40 macprovider-coordinator"
  log "ok - failed gateway disclosure check rolls back remote state"
}

successful_apply_path_with_fakes() {
  run_apply "successful_apply_path_with_fakes" pass \
    "FAKE_CURL_MODE=success" \
    "FORCE_RESTART=1" \
    "DEMO_TOKEN=fake-token"

  assert_contains "$LAST_STDERR" "verifying gateway /v1/models Tier-2 disclosure"
  assert_contains "$LAST_STDOUT" "tier2 catalog loaded"
  assert_contains "$LAST_STDOUT" "model_hash_verified"
  assert_contains "$LAST_STDOUT" "'require_verified': False"
  log "ok - fake apply path reaches health, journal, and gateway verification"
}

write_fake_commands
restart_guard_refuses_connected_pool
health_parse_failure_refuses_without_force
config_merge_failure_rolls_back
gateway_failure_rolls_back
successful_apply_path_with_fakes

log "all activation safety checks passed"
