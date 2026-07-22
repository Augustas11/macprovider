#!/usr/bin/env bash
# Hermetic safety checks for the guarded SPEC-008 Phase 1 activation helper.
#
# This script replaces ssh/scp/curl with local fakes and runs the production
# activation script against them. It must never contact Pearl VPS or the public
# coordinator/gateway endpoints.
#
# #608 finish: also proves activate-tier2-observe refuses a conflicting Tier-2
# catalog before any remote mutation (no independent second authority).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "$TMP_BASE/tier2-activate-safety.XXXXXX")"
FAKE_BIN="$WORKDIR/bin"
FAKE_HOME="$WORKDIR/home"
SSH_KEY="$FAKE_HOME/.ssh/pearl_operator_ed25519"
FIXTURES="$WORKDIR/fixtures"
AUTOTUNE_CANDIDATES="$REPO_ROOT/phase3-binary/catalog/autotune/autotune-candidates.json"
MATCHING_CATALOG="$FIXTURES/tier2-matching.json"
CONFLICT_CATALOG="$FIXTURES/tier2-conflict.json"
PUBLIC_KEY_FILE="$FIXTURES/catalog-signing-key.pub"
PRIVATE_KEY_FILE="$FIXTURES/catalog-signing-key.priv"
FAKE_COORDINATOR="$FIXTURES/coordinator-linux-amd64"

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
  if ! grep -Fq -- "$needle" "$file"; then
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

# Record sha256 of the catalog/binary payload (last local path before remote dest).
local_payload=""
for arg in "$@"; do
  case "$arg" in
    -*|*=*) continue ;;
  esac
  if [ -f "$arg" ]; then
    local_payload="$arg"
  fi
done
if [ -n "$local_payload" ]; then
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$local_payload" | awk '{print $1}' > "$FAKE_LOG_DIR/scp-source.sha256"
  else
    sha256sum "$local_payload" | awk '{print $1}' > "$FAKE_LOG_DIR/scp-source.sha256"
  fi
  printf '%s\n' "$local_payload" > "$FAKE_LOG_DIR/scp-source.path"
  # Keep a catalog-specific digest when present (pin-race proof).
  case "$local_payload" in
    *tier2-catalog.json|*tier2-matching*|*operator-live-catalog*)
      cp "$FAKE_LOG_DIR/scp-source.sha256" "$FAKE_LOG_DIR/scp-catalog.sha256"
      printf '%s\n' "$local_payload" > "$FAKE_LOG_DIR/scp-catalog.path"
      ;;
  esac
fi

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

if [[ "$cmd" == *"mktemp -d -t macprovider-tier2-activate."* ]]; then
  stage="/tmp/macprovider-tier2-activate.FAKE$$"
  mkdir -p "$stage"
  printf '%s\n' "$stage" > "$FAKE_LOG_DIR/remote-stage.path"
  printf '%s\n' "$stage"
  exit 0
fi

if [[ "$cmd" == rm\ -rf\ --\ /tmp/macprovider-tier2-activate.* ]] || [[ "$cmd" == *"rm -rf -- /tmp/macprovider-tier2-activate."* ]]; then
  exit 0
fi

if [[ "$cmd" == *"install -o root -g macprovider -m 0640"* && "$cmd" == *"tier2-catalog"* ]]; then
  if [ "${FAKE_REMOTE_HAS_CATALOG:-0}" = "1" ]; then
    printf 'catalog_backup=/opt/macprovider/tier2-catalog.json.bak-tier2-FAKE\n'
  else
    printf 'catalog_created=1\n'
  fi
  exit 0
fi

if [[ "$cmd" == *"install -o root -g macprovider -m 0750"* && "$cmd" == *"/opt/macprovider/coordinator"* ]]; then
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

build_hermetic_catalogs() {
  require_file() { [ -f "$1" ] || die "missing file: $1"; }
  require_file "$AUTOTUNE_CANDIDATES"
  mkdir -p "$FIXTURES"
  go run "$REPO_ROOT/scripts/sign-catalog.go" keygen \
    -public-out "$PUBLIC_KEY_FILE" \
    -private-out "$PRIVATE_KEY_FILE" >/dev/null

  python3 - "$AUTOTUNE_CANDIDATES" "$FIXTURES" <<'PY'
import json
import pathlib
import sys

candidate = json.loads(pathlib.Path(sys.argv[1]).read_text())
fixtures = pathlib.Path(sys.argv[2])
row = candidate["rows"]["qwen3-8b"]
match_hash = row["model_sha256"]
conflict_hash = "f" * 64
body = {
    "catalog_id": "hermetic-activate-safety",
    "expires_at": "2099-01-01T00:00:00Z",
    "issued_at": "2026-07-10T00:00:00Z",
    "models": [{
        "artifact_kind": "mlx_weight_file",
        "hash_scope": "primary_weight_file",
        "model_id": row["model_id"],
        "min_ram_gb": int(row["min_ram_gb"]),
        "sha256": match_hash,
        "source": "operator-curated",
    }],
    "version": 1,
}
(fixtures / "tier2-matching.unsigned.json").write_text(json.dumps(body, indent=2) + "\n")
body["models"][0]["sha256"] = conflict_hash
(fixtures / "tier2-conflict.unsigned.json").write_text(json.dumps(body, indent=2) + "\n")
PY

  go run "$REPO_ROOT/scripts/sign-catalog.go" sign \
    -key "$PRIVATE_KEY_FILE" \
    -key-id "hermetic-activate-safety" \
    -out "$MATCHING_CATALOG" \
    "$FIXTURES/tier2-matching.unsigned.json" >/dev/null
  go run "$REPO_ROOT/scripts/sign-catalog.go" sign \
    -key "$PRIVATE_KEY_FILE" \
    -key-id "hermetic-activate-safety" \
    -out "$CONFLICT_CATALOG" \
    "$FIXTURES/tier2-conflict.unsigned.json" >/dev/null

  # Fake coordinator binary only needs the catalog-loaded marker string.
  printf '#!/bin/sh\necho "fake coordinator"\n# tier2 catalog loaded\n' > "$FAKE_COORDINATOR"
  chmod +x "$FAKE_COORDINATOR"
}

BASE_ENV=()
LAST_STDOUT=""
LAST_STDERR=""
LAST_SCENARIO_DIR=""
LAST_RC=0

refresh_base_env() {
  local catalog="$1"
  BASE_ENV=(
    "PATH=$FAKE_BIN:$PATH"
    "HOME=$FAKE_HOME"
    "CATALOG=$catalog"
    "PUBLIC_KEY_FILE=$PUBLIC_KEY_FILE"
    "AUTOTUNE_CANDIDATES=$AUTOTUNE_CANDIDATES"
    "SSH_KEY=$SSH_KEY"
    "VPS_HOST=fake-pearl.invalid"
    "VPS_USER=root"
    "SSH_PORT=2222"
    "REMOTE_CONFIG=/opt/macprovider/coordinator.yaml"
    "REMOTE_CATALOG=/opt/macprovider/tier2-catalog.json"
    "SERVICE=macprovider-coordinator"
    "COORDINATOR_BINARY=$FAKE_COORDINATOR"
    "DEPLOY_COORDINATOR_BINARY=1"
    "TIER2_ACTIVATE_HERMETIC_TEST=1"
    "TIER2_ACTIVATE_FAKE_BIN=$FAKE_BIN"
    "COORDINATOR_ORIGIN=https://fake-coordinator.invalid"
    "GATEWAY_ORIGIN=https://fake-gateway.invalid"
  )
}

run_apply() {
  local name="$1"
  local expected="$2"
  local catalog="$3"
  shift 3

  refresh_base_env "$catalog"
  LAST_SCENARIO_DIR="$WORKDIR/$name"
  mkdir -p "$LAST_SCENARIO_DIR"
  LAST_STDOUT="$LAST_SCENARIO_DIR/stdout.txt"
  LAST_STDERR="$LAST_SCENARIO_DIR/stderr.txt"

  set +e
  (
    cd "$REPO_ROOT"
    env "${BASE_ENV[@]}" "FAKE_LOG_DIR=$LAST_SCENARIO_DIR" "$@" \
      "$REPO_ROOT/scripts/test-support/tier2-observe-apply-harness.sh" --apply
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

binding_conflict_refuses_before_remote_mutation() {
  run_apply "binding_conflict_refuses_before_remote_mutation" fail "$CONFLICT_CATALOG" \
    "FAKE_CURL_MODE=success" \
    "FORCE_RESTART=1" \
    "SKIP_GATEWAY_VERIFY=1"

  assert_contains "$LAST_STDERR" "autotune/tier2 identity conflict"
  assert_contains "$LAST_STDERR" "refusing Tier-2-only activate"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/ssh.log"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/scp.log"
  log "ok - conflicting Tier-2 catalog refused before remote mutation (#608)"
}

apply_disabled_without_legacy_override() {
  # Production entrypoint must refuse --apply unconditionally.
  LAST_SCENARIO_DIR="$WORKDIR/apply_disabled_without_legacy_override"
  mkdir -p "$LAST_SCENARIO_DIR"
  LAST_STDOUT="$LAST_SCENARIO_DIR/stdout.txt"
  LAST_STDERR="$LAST_SCENARIO_DIR/stderr.txt"
  set +e
  (
    cd "$REPO_ROOT"
    env "CATALOG=$MATCHING_CATALOG" \
      "PUBLIC_KEY_FILE=$PUBLIC_KEY_FILE" \
      "AUTOTUNE_CANDIDATES=$AUTOTUNE_CANDIDATES" \
      "$REPO_ROOT/scripts/activate-tier2-observe.sh" --apply
  ) >"$LAST_STDOUT" 2>"$LAST_STDERR"
  LAST_RC=$?
  set -e
  [ "$LAST_RC" -ne 0 ] || die "production --apply should fail"
  assert_contains "$LAST_STDERR" "--apply is retired for live Tier-2 mutation"
  assert_contains "$LAST_STDERR" "deploy-pearl-vps.sh"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/ssh.log"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/scp.log"
  log "ok - production entrypoint retires --apply unconditionally"
}

stale_backup_shaped_conflict_refuses() {
  # Same shape as #585: Qwen present in both catalogs with drifted hash.
  run_apply "stale_backup_shaped_conflict_refuses" fail "$CONFLICT_CATALOG" \
    "FAKE_CURL_MODE=live_pool" \
    "SKIP_GATEWAY_VERIFY=1"

  assert_contains "$LAST_STDERR" "conflicts"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/ssh.log"
  log "ok - stale/conflicted Tier-2 identity cannot be restored alone"
}

restart_guard_refuses_connected_pool() {
  run_apply "restart_guard_refuses_connected_pool" fail "$MATCHING_CATALOG" \
    "FAKE_CURL_MODE=live_pool" \
    "SKIP_GATEWAY_VERIFY=1"

  assert_contains "$LAST_STDERR" "refusing restart with 2 connected provider(s)"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/ssh.log"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/scp.log"
  log "ok - connected-provider restart guard refused before remote mutation"
}

health_parse_failure_refuses_without_force() {
  run_apply "health_parse_failure_refuses_without_force" fail "$MATCHING_CATALOG" \
    "FAKE_CURL_MODE=invalid_health" \
    "SKIP_GATEWAY_VERIFY=1"

  assert_contains "$LAST_STDERR" "could not determine connected provider count"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/ssh.log"
  assert_empty_or_missing "$LAST_SCENARIO_DIR/scp.log"
  log "ok - unparseable health refuses before remote mutation"
}

config_merge_failure_rolls_back() {
  run_apply "config_merge_failure_rolls_back" fail "$MATCHING_CATALOG" \
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
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "mktemp -d -t macprovider-tier2-activate."
  assert_contains "$LAST_SCENARIO_DIR/scp.log" "tier2-catalog"
  assert_contains "$LAST_SCENARIO_DIR/scp.log" "coordinator-linux-amd64"
  log "ok - config merge failure restores config/binary and removes created catalog"
}

existing_catalog_backup_restored_on_failure() {
  run_apply "existing_catalog_backup_restored_on_failure" fail "$MATCHING_CATALOG" \
    "FAKE_CURL_MODE=success" \
    "FAKE_SSH_MODE=config_fail" \
    "FAKE_REMOTE_HAS_CATALOG=1" \
    "FORCE_RESTART=1" \
    "SKIP_GATEWAY_VERIFY=1"

  assert_contains "$LAST_STDERR" "live config tier2 merge failed"
  assert_contains "$LAST_STDERR" "restoring previous tier2 catalog from /opt/macprovider/tier2-catalog.json.bak-tier2-FAKE"
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "cp -a /opt/macprovider/tier2-catalog.json.bak-tier2-FAKE /opt/macprovider/tier2-catalog.json"
  log "ok - existing Tier-2 catalog backup is restored on failure"
}

gateway_failure_rolls_back() {
  run_apply "gateway_failure_rolls_back" fail "$MATCHING_CATALOG" \
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
  run_apply "successful_apply_path_with_fakes" pass "$MATCHING_CATALOG" \
    "FAKE_CURL_MODE=success" \
    "FORCE_RESTART=1" \
    "DEMO_TOKEN=fake-token"

  assert_contains "$LAST_STDERR" "autotune/tier2 identity binding ok"
  assert_contains "$LAST_STDERR" "pinned catalog/public-key/autotune bytes"
  assert_contains "$LAST_STDERR" "verifying gateway /v1/models Tier-2 disclosure"
  assert_contains "$LAST_STDOUT" "tier2 catalog loaded"
  assert_contains "$LAST_STDOUT" "model_hash_verified"
  assert_contains "$LAST_STDOUT" "'require_verified': False"
  log "ok - fake apply path reaches health, journal, and gateway verification"
}

pin_race_uploads_pinned_bytes_not_replaced_original() {
  # After pin+validate, overwrite the operator catalog with a conflicting signed
  # body. Upload must still use the pinned matching bytes (#608 audit MEDIUM).
  local operator_catalog="$FIXTURES/operator-live-catalog.json"
  cp "$MATCHING_CATALOG" "$operator_catalog"
  local matching_sha conflict_sha
  if command -v shasum >/dev/null 2>&1; then
    matching_sha="$(shasum -a 256 "$MATCHING_CATALOG" | awk '{print $1}')"
    conflict_sha="$(shasum -a 256 "$CONFLICT_CATALOG" | awk '{print $1}')"
  else
    matching_sha="$(sha256sum "$MATCHING_CATALOG" | awk '{print $1}')"
    conflict_sha="$(sha256sum "$CONFLICT_CATALOG" | awk '{print $1}')"
  fi
  [ "$matching_sha" != "$conflict_sha" ] || die "matching and conflict catalogs unexpectedly identical"

  run_apply "pin_race_uploads_pinned_bytes_not_replaced_original" pass "$operator_catalog" \
    "FAKE_CURL_MODE=success" \
    "FORCE_RESTART=1" \
    "SKIP_GATEWAY_VERIFY=1" \
    "TIER2_ACTIVATE_TEST_REPLACEMENT=$CONFLICT_CATALOG"

  assert_contains "$LAST_STDERR" "pinned catalog/public-key/autotune bytes"
  assert_contains "$LAST_STDERR" "remote staging dir:"
  [ -f "$LAST_SCENARIO_DIR/scp-catalog.sha256" ] || die "scp did not record catalog sha256"
  local uploaded_sha operator_sha
  uploaded_sha="$(tr -d '[:space:]' < "$LAST_SCENARIO_DIR/scp-catalog.sha256")"
  [ "$uploaded_sha" = "$matching_sha" ] || die "expected pinned matching sha $matching_sha, got $uploaded_sha (path=$(cat "$LAST_SCENARIO_DIR/scp-catalog.path" 2>/dev/null || true))"
  if command -v shasum >/dev/null 2>&1; then
    operator_sha="$(shasum -a 256 "$operator_catalog" | awk '{print $1}')"
  else
    operator_sha="$(sha256sum "$operator_catalog" | awk '{print $1}')"
  fi
  [ "$operator_sha" = "$conflict_sha" ] || die "test seam did not replace operator catalog with conflict bytes"
  assert_contains "$LAST_SCENARIO_DIR/scp.log" "tier2-catalog"
  assert_contains "$LAST_SCENARIO_DIR/ssh.log" "mktemp -d -t macprovider-tier2-activate."
  log "ok - post-validate operator catalog replacement cannot change uploaded pinned bytes"
}

write_fake_commands
build_hermetic_catalogs
binding_conflict_refuses_before_remote_mutation
apply_disabled_without_legacy_override
stale_backup_shaped_conflict_refuses
restart_guard_refuses_connected_pool
health_parse_failure_refuses_without_force
config_merge_failure_rolls_back
existing_catalog_backup_restored_on_failure
gateway_failure_rolls_back
successful_apply_path_with_fakes
pin_race_uploads_pinned_bytes_not_replaced_original

log "all activation safety checks passed"
