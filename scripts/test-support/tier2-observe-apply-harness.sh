#!/usr/bin/env bash
# TEST-ONLY hermetic apply harness for #608 activation safety.
# NOT for production. Production entrypoint is scripts/activate-tier2-observe.sh
# (--plan only) and Pearl deploy-pearl-vps.sh for live Tier-2 mutation.
#
# This harness retains the gated apply implementation solely so
# scripts/test-tier2-activation-safety.sh can exercise pin/staging/rollback
# against local ssh/scp/curl fakes. It refuses to run unless invoked by basename
# and VPS_HOST=fake-pearl.invalid.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/activate-tier2-observe.sh [--plan|--apply]

Environment:
  CATALOG             default: .omc/tier2/tier2-catalog.json
  PUBLIC_KEY_FILE     default: .omc/tier2/catalog-signing-key.pub
  AUTOTUNE_CANDIDATES default: phase3-binary/catalog/autotune/autotune-candidates.json
                      required for check-tier2-binding before plan/apply (#608)
  SSH_KEY             default: ~/.ssh/pearl_operator_ed25519
  VPS_HOST            default: 159.223.165.194
  VPS_USER            default: root
  SSH_PORT            default: 22
  REMOTE_CONFIG       default: /opt/macprovider/coordinator.yaml
  REMOTE_CATALOG      default: /opt/macprovider/tier2-catalog.json
  SERVICE             default: macprovider-coordinator
  COORDINATOR_BINARY  default: phase4-coordinator/dist/coordinator-linux-amd64
  DEPLOY_COORDINATOR_BINARY=1 uploads COORDINATOR_BINARY before restart
  COORDINATOR_ORIGIN  default: https://coordinator.streamvc.live
  GATEWAY_ORIGIN      default: https://api.streamvc.live
  DEMO_TOKEN          required by --apply unless SKIP_GATEWAY_VERIFY=1
  SKIP_GATEWAY_VERIFY=1 skips /v1/models Tier-2 verification
  FORCE_RESTART=1     required by --apply when providers are connected
  ALLOW_LEGACY_TIER2_OBSERVE_APPLY / TIER2_ACTIVATE_HERMETIC_TEST
                      hermetic-test only; live --apply is retired (#608). Prefer
                      phase4-coordinator/dist/deploy-pearl-vps.sh for production.
  Requires local go toolchain for signed catalog verification before plan/apply
  Requires local python3 for autotune/Tier-2 identity binding before plan/apply,
  and for --apply health parsing / gateway verification
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

# Refuse accidental production use of this test-only harness.
case "$(basename "$0")" in
  tier2-observe-apply-harness.sh) ;;
  *)
    echo "[tier2-activate-harness] ERROR: invoke only as scripts/test-support/tier2-observe-apply-harness.sh" >&2
    exit 1
    ;;
esac
# Harness lives under scripts/test-support/; repo root is one level above scripts/.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CATALOG="${CATALOG:-$REPO_ROOT/.omc/tier2/tier2-catalog.json}"
PUBLIC_KEY_FILE="${PUBLIC_KEY_FILE:-$REPO_ROOT/.omc/tier2/catalog-signing-key.pub}"
AUTOTUNE_CANDIDATES="${AUTOTUNE_CANDIDATES:-$REPO_ROOT/phase3-binary/catalog/autotune/autotune-candidates.json}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-fake-pearl.invalid}"
VPS_USER="${VPS_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
REMOTE_CONFIG="${REMOTE_CONFIG:-/opt/macprovider/coordinator.yaml}"
REMOTE_CATALOG="${REMOTE_CATALOG:-/opt/macprovider/tier2-catalog.json}"
SERVICE="${SERVICE:-macprovider-coordinator}"
COORDINATOR_BINARY="${COORDINATOR_BINARY:-$REPO_ROOT/phase4-coordinator/dist/coordinator-linux-amd64}"
DEPLOY_COORDINATOR_BINARY="${DEPLOY_COORDINATOR_BINARY:-1}"
COORDINATOR_ORIGIN="${COORDINATOR_ORIGIN:-https://coordinator.streamvc.live}"
GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-https://api.streamvc.live}"

PIN_DIR=""
CATALOG_OPERATOR=""
PUBLIC_KEY_OPERATOR=""
AUTOTUNE_OPERATOR=""
CATALOG_PIN_SHA=""
REMOTE_STAGE=""
SSH=()
SCP=()

log() { printf '[tier2-activate] %s\n' "$*" >&2; }
die() { printf '[tier2-activate] ERROR: %s\n' "$*" >&2; exit 1; }
shell_quote() { printf "%q" "$1"; }
output_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { value = substr($0, index($0, "=") + 1) } END { print value }'
}

cleanup_pins() {
  if [ -n "${PIN_DIR:-}" ] && [ -d "$PIN_DIR" ]; then
    case "$PIN_DIR" in
      */tier2-activate-pin.*) rm -rf "$PIN_DIR" ;;
    esac
  fi
}

cleanup_remote_stage() {
  if [ -n "${REMOTE_STAGE:-}" ]; then
    case "$REMOTE_STAGE" in
      /tmp/macprovider-tier2-activate.*)
        if [ "${#SSH[@]}" -gt 0 ]; then
          "${SSH[@]}" "rm -rf -- $(shell_quote "$REMOTE_STAGE")" || true
        fi
        ;;
    esac
    REMOTE_STAGE=""
  fi
}

cleanup_all() {
  cleanup_pins
  cleanup_remote_stage
}
trap cleanup_all EXIT

require_file() {
  local path="$1"
  [ -f "$path" ] || die "missing file: $path"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi
  die "missing shasum or sha256sum"
}

# Pin operator-provided paths before verify/bind/upload so a replacement of the
# original files cannot change the bytes that pass check-tier2-binding (#608).
pin_local_inputs() {
  require_file "$CATALOG"
  require_file "$PUBLIC_KEY_FILE"
  require_file "$AUTOTUNE_CANDIDATES"
  CATALOG_OPERATOR="$CATALOG"
  PUBLIC_KEY_OPERATOR="$PUBLIC_KEY_FILE"
  AUTOTUNE_OPERATOR="$AUTOTUNE_CANDIDATES"
  PIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tier2-activate-pin.XXXXXX")"
  chmod 700 "$PIN_DIR"
  cp "$CATALOG_OPERATOR" "$PIN_DIR/tier2-catalog.json"
  cp "$PUBLIC_KEY_OPERATOR" "$PIN_DIR/catalog-signing-key.pub"
  cp "$AUTOTUNE_OPERATOR" "$PIN_DIR/autotune-candidates.json"
  chmod 400 "$PIN_DIR/tier2-catalog.json" "$PIN_DIR/catalog-signing-key.pub" "$PIN_DIR/autotune-candidates.json"
  CATALOG="$PIN_DIR/tier2-catalog.json"
  PUBLIC_KEY_FILE="$PIN_DIR/catalog-signing-key.pub"
  AUTOTUNE_CANDIDATES="$PIN_DIR/autotune-candidates.json"
  CATALOG_PIN_SHA="$(sha256_file "$CATALOG")"
  log "pinned catalog/public-key/autotune bytes for verify+bind+upload (catalog_sha256=$CATALOG_PIN_SHA)"
}

require_autotune_tier2_binding() {
  require_file "$AUTOTUNE_CANDIDATES"
  require_command python3
  # Fail closed before any remote mutation: Tier-2 must not disagree with the
  # autotune release being activated (#608). Prefer deploy-pearl-vps.sh for the
  # full release transaction; this gate keeps the observe helper from shipping a
  # conflicting live catalog as a second authority.
  if ! python3 "$REPO_ROOT/scripts/catalog-release.py" check-tier2-binding \
    --candidate "$AUTOTUNE_CANDIDATES" \
    --tier2 "$CATALOG"; then
    die "autotune/tier2 identity conflict: refusing Tier-2-only activate. Use deploy-pearl-vps.sh with a matching release, or fix CATALOG / AUTOTUNE_CANDIDATES so check-tier2-binding passes. Do not restore a stale Tier-2 backup alone."
  fi
  log "autotune/tier2 identity binding ok (candidate=$(basename "$AUTOTUNE_OPERATOR"))"
}

validate_local_inputs() {
  if [ "$DEPLOY_COORDINATOR_BINARY" = "1" ]; then
    require_file "$COORDINATOR_BINARY"
    [ -x "$COORDINATOR_BINARY" ] || die "coordinator binary is not executable: $COORDINATOR_BINARY"
    grep -a -q 'tier2 catalog loaded' "$COORDINATOR_BINARY" || die "coordinator binary lacks tier2 catalog-loaded log string: $COORDINATOR_BINARY"
  fi
  require_command go
  go run "$REPO_ROOT/scripts/sign-catalog.go" verify \
    -public-key "$PUBLIC_KEY_FILE" \
    "$CATALOG"
  require_autotune_tier2_binding
  local verify_sha
  verify_sha="$(sha256_file "$CATALOG")"
  if [ "$verify_sha" != "$CATALOG_PIN_SHA" ]; then
    die "pinned catalog bytes drifted after verify/bind (got $verify_sha want $CATALOG_PIN_SHA)"
  fi
}

print_plan() {
  log "validated local catalog, public key, and autotune/Tier-2 identity binding"
  local binary_step
  if [ "$DEPLOY_COORDINATOR_BINARY" = "1" ]; then
    binary_step="2. Copy $COORDINATOR_BINARY to $VPS_USER@$VPS_HOST:/opt/macprovider/coordinator
   after backing up the current binary. Set DEPLOY_COORDINATOR_BINARY=0 to skip."
  else
    binary_step="2. Keep the existing remote coordinator binary because DEPLOY_COORDINATOR_BINARY=0."
  fi
  cat <<PLAN
Plan only. No production state was changed.

#608 note: Tier-2 is derived-only relative to AUTOTUNE_CANDIDATES for this
helper. Prefer phase4-coordinator/dist/deploy-pearl-vps.sh for one release
transaction. Do not restore $REMOTE_CATALOG from a stale backup without the
matching autotune release — coordinator startup/reload fail-closes on conflict.

Would perform:
1. Copy pinned snapshot of $CATALOG_OPERATOR to $VPS_USER@$VPS_HOST:$REMOTE_CATALOG
   after backing up any existing remote catalog
   (only after check-tier2-binding vs $AUTOTUNE_OPERATOR; upload digest=$CATALOG_PIN_SHA).
$binary_step
3. Back up $REMOTE_CONFIG on Pearl VPS.
4. Replace or append only this top-level block in the live config:

tier2:
  catalog_path: $REMOTE_CATALOG
  catalog_public_key: $(tr -d '\n' < "$PUBLIC_KEY_FILE")
  require_hash_verified: false

5. Restart $SERVICE because catalog_path/catalog_public_key are startup-only.
6. Verify service health, recent journal entries for "tier2 catalog loaded",
   and /v1/models Tier-2 disclosure using DEMO_TOKEN.
   Catalog upload, binary upload, config merge, restart, health, journal, or
   gateway-verification failure restores available config, binary, and catalog
   backups, or removes a newly created catalog when no prior remote catalog
   existed.

To apply production Tier-2 changes:
  Use phase4-coordinator/dist/deploy-pearl-vps.sh (one release transaction).
  This helper's --apply path is retired for live hosts (#608).
PLAN
}

remote_create_stage() {
  # Issue #244 / #608: stage into a fresh root-owned 0700 directory instead of
  # predictable /tmp/X names that a compromised local UID could pre-create.
  local stage
  stage="$("${SSH[@]}" 'umask 077 && mktemp -d -t macprovider-tier2-activate.XXXXXXXX')" || \
    die "failed to create remote staging directory"
  stage="$(printf '%s' "$stage" | tr -d '\r\n')"
  case "$stage" in
    /tmp/macprovider-tier2-activate.*) ;;
    *)
      die "remote mktemp produced unexpected path: $stage"
      ;;
  esac
  printf '%s\n' "$stage"
}

remote_install_binary() {
  local stage="$1"
  local remote_tmp="$stage/coordinator-linux-amd64"
  "${SCP[@]}" "$COORDINATOR_BINARY" "$VPS_USER@$VPS_HOST:$remote_tmp"
  "${SSH[@]}" "set -euo pipefail
    backup=/opt/macprovider/coordinator.bak-tier2-\$(date -u +%Y%m%d%H%M%S)
    if [ -L /opt/macprovider/coordinator ]; then
      echo 'coordinator path must not be a symlink' >&2; exit 1
    fi
    if [ -f /opt/macprovider/coordinator ]; then
      cp -a /opt/macprovider/coordinator \"\$backup\"
      echo \"binary_backup=\$backup\"
    fi
    [ -f $(shell_quote "$remote_tmp") ] || { echo 'staged coordinator missing' >&2; exit 1; }
    [ ! -L $(shell_quote "$remote_tmp") ] || { echo 'staged coordinator must not be a symlink' >&2; exit 1; }
    install -o root -g macprovider -m 0750 $(shell_quote "$remote_tmp") /opt/macprovider/coordinator
    rm -f $(shell_quote "$remote_tmp")
  "
}

remote_install_catalog() {
  local stage="$1"
  local remote_tmp="$stage/tier2-catalog.json"
  local upload_sha
  upload_sha="$(sha256_file "$CATALOG")"
  if [ "$upload_sha" != "$CATALOG_PIN_SHA" ]; then
    die "refusing upload: catalog bytes differ from pinned verify/bind digest (got $upload_sha want $CATALOG_PIN_SHA)"
  fi
  "${SCP[@]}" "$CATALOG" "$VPS_USER@$VPS_HOST:$remote_tmp"
  "${SSH[@]}" "set -euo pipefail
    id macprovider >/dev/null 2>&1 || useradd --system --home /opt/macprovider --shell /usr/sbin/nologin macprovider
    install -d -o root -g macprovider -m 0750 /opt/macprovider
    backup=
    if [ -L $(shell_quote "$REMOTE_CATALOG") ]; then
      echo 'remote catalog must not be a symlink' >&2
      exit 1
    fi
    if [ -e $(shell_quote "$REMOTE_CATALOG") ]; then
      [ -f $(shell_quote "$REMOTE_CATALOG") ] || { echo 'remote catalog must be a regular file' >&2; exit 1; }
      backup=$(shell_quote "$REMOTE_CATALOG").bak-tier2-\$(date -u +%Y%m%d%H%M%S)
      cp -a $(shell_quote "$REMOTE_CATALOG") \"\$backup\"
      echo \"catalog_backup=\$backup\"
    else
      echo \"catalog_created=1\"
    fi
    # Fail closed if staging path is not a regular file (symlink race).
    [ -L $(shell_quote "$remote_tmp") ] && { echo 'staged catalog must not be a symlink' >&2; exit 1; }
    [ -f $(shell_quote "$remote_tmp") ] || { echo 'staged catalog missing' >&2; exit 1; }
    install -o root -g macprovider -m 0640 $(shell_quote "$remote_tmp") $(shell_quote "$REMOTE_CATALOG")
    rm -f $(shell_quote "$remote_tmp")
  "
}

remote_patch_config() {
  local public_key
  public_key="$(tr -d '\n' < "$PUBLIC_KEY_FILE")"
  local q_public_key q_remote_config q_remote_catalog
  q_public_key="$(shell_quote "$public_key")"
  q_remote_config="$(shell_quote "$REMOTE_CONFIG")"
  q_remote_catalog="$(shell_quote "$REMOTE_CATALOG")"

  "${SSH[@]}" "PUBLIC_KEY=$q_public_key REMOTE_CONFIG=$q_remote_config REMOTE_CATALOG=$q_remote_catalog python3 - <<'PY'
import os
import re
import shutil
import sys
import time

path = os.environ['REMOTE_CONFIG']
catalog_path = os.environ['REMOTE_CATALOG']
public_key = os.environ['PUBLIC_KEY']
with open(path, 'r', encoding='utf-8') as f:
    original = f.read()

lines = original.splitlines()
start = None
for i, line in enumerate(lines):
    if line == 'tier2:':
        start = i
        break

if start is None:
    block = '\\n'.join([
        'tier2:',
        f'  catalog_path: {catalog_path}',
        f'  catalog_public_key: {public_key}',
        '  require_hash_verified: false',
        '',
    ])
    updated = original.rstrip() + '\\n\\n' + block
else:
    end = start + 1
    top_level_key = re.compile(r'^[A-Za-z0-9_-]+:')
    while end < len(lines) and not top_level_key.match(lines[end]):
        end += 1
    block_lines = lines[start:end]

    def key_for(line):
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or ':' not in stripped:
            return None
        return stripped.split(':', 1)[0]

    replacements = {
        'catalog_path': f'  catalog_path: {catalog_path}',
        'catalog_public_key': f'  catalog_public_key: {public_key}',
        'require_hash_verified': '  require_hash_verified: false',
    }
    seen = set()
    updated_block = []
    for line in block_lines:
        key = key_for(line)
        if key in replacements:
            updated_block.append(replacements[key])
            seen.add(key)
        else:
            updated_block.append(line)
    insert_at = len(updated_block)
    for key in ('catalog_path', 'catalog_public_key', 'require_hash_verified'):
        if key not in seen:
            updated_block.insert(insert_at, replacements[key])
            insert_at += 1
    updated_lines = lines[:start] + updated_block + lines[end:]
    updated = '\\n'.join(updated_lines).rstrip() + '\\n'

if updated == original:
    print('tier2 block already current')
    sys.exit(0)

st = os.stat(path)
backup = f'{path}.bak-tier2-{time.strftime(\"%Y%m%d%H%M%S\", time.gmtime())}'
shutil.copy2(path, backup)
os.chown(backup, st.st_uid, st.st_gid)
os.chmod(backup, st.st_mode & 0o777)
print(f'config_backup={backup}', flush=True)
tmp = f'{path}.tmp-tier2-{os.getpid()}'
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(updated)
os.chown(tmp, st.st_uid, st.st_gid)
os.chmod(tmp, st.st_mode & 0o777)
os.replace(tmp, path)
print('updated tier2 block')
PY"
}

remote_restore_and_report() {
  local config_backup="$1"
  local binary_backup="$2"
  local catalog_backup="$3"
  local catalog_created="$4"
  if [ -z "$config_backup" ] && [ -z "$binary_backup" ] && [ -z "$catalog_backup" ] && [ "$catalog_created" != "1" ]; then
    "${SSH[@]}" "systemctl status --no-pager -n 40 $(shell_quote "$SERVICE") || true"
    return
  fi
  "${SSH[@]}" "set -uo pipefail
    if [ -n $(shell_quote "$config_backup") ]; then
      cp -a $(shell_quote "$config_backup") $(shell_quote "$REMOTE_CONFIG")
    fi
    if [ -n $(shell_quote "$binary_backup") ]; then
      systemctl stop $(shell_quote "$SERVICE") || true
      cp -a $(shell_quote "$binary_backup") /opt/macprovider/coordinator
    fi
    if [ -n $(shell_quote "$catalog_backup") ]; then
      cp -a $(shell_quote "$catalog_backup") $(shell_quote "$REMOTE_CATALOG")
    elif [ $(shell_quote "$catalog_created") = 1 ]; then
      rm -f $(shell_quote "$REMOTE_CATALOG")
    fi
    systemctl restart $(shell_quote "$SERVICE") || true
    systemctl status --no-pager -n 40 $(shell_quote "$SERVICE") || true
  "
}

rollback_and_exit() {
  local reason="$1"
  local config_backup="$2"
  local binary_backup="$3"
  local catalog_backup="$4"
  local catalog_created="$5"
  log "$reason"
  if [ -n "$config_backup" ]; then
    log "restoring previous coordinator config from $config_backup"
  fi
  if [ -n "$binary_backup" ]; then
    log "restoring previous coordinator binary from $binary_backup"
  fi
  if [ -n "$catalog_backup" ]; then
    log "restoring previous tier2 catalog from $catalog_backup"
  elif [ "$catalog_created" = "1" ]; then
    log "removing newly created remote tier2 catalog"
  fi
  remote_restore_and_report "$config_backup" "$binary_backup" "$catalog_backup" "$catalog_created"
  exit 1
}

apply_changes() {
  if [ "$VPS_HOST" != "fake-pearl.invalid" ] || [ "${TIER2_ACTIVATE_HERMETIC_TEST:-0}" != "1" ]; then
    die "test-only harness refuses apply unless VPS_HOST=fake-pearl.invalid and TIER2_ACTIVATE_HERMETIC_TEST=1"
  fi
  # Network tools must come from the hermetic fake bin (not real OpenSSH), so an
  # ssh Host alias for fake-pearl.invalid cannot reach Pearl.
  [ -n "${TIER2_ACTIVATE_FAKE_BIN:-}" ] || die "TIER2_ACTIVATE_FAKE_BIN is required for the test-only apply harness"
  [ -x "$TIER2_ACTIVATE_FAKE_BIN/ssh" ] || die "missing fake ssh: $TIER2_ACTIVATE_FAKE_BIN/ssh"
  [ -x "$TIER2_ACTIVATE_FAKE_BIN/scp" ] || die "missing fake scp: $TIER2_ACTIVATE_FAKE_BIN/scp"
  [ -x "$TIER2_ACTIVATE_FAKE_BIN/curl" ] || die "missing fake curl: $TIER2_ACTIVATE_FAKE_BIN/curl"
  require_command python3
  require_file "$SSH_KEY"
  if [ -z "${DEMO_TOKEN:-}" ] && [ "${SKIP_GATEWAY_VERIFY:-0}" != "1" ]; then
    die "DEMO_TOKEN is required for /v1/models Tier-2 verification; set SKIP_GATEWAY_VERIFY=1 only if verifying manually"
  fi

  SSH=("$TIER2_ACTIVATE_FAKE_BIN/ssh" -i "$SSH_KEY" -o ConnectTimeout=10 -p "$SSH_PORT" "$VPS_USER@$VPS_HOST")
  SCP=("$TIER2_ACTIVATE_FAKE_BIN/scp" -i "$SSH_KEY" -P "$SSH_PORT")
  CURL=("$TIER2_ACTIVATE_FAKE_BIN/curl")

  log "checking current coordinator pool size"
  local connected_count
  if ! connected_count="$("${CURL[@]}" -fsS --max-time 5 "$COORDINATOR_ORIGIN/healthz" \
    | python3 -c 'import json,sys; body=json.load(sys.stdin); print(max(int(body.get("pool_size") or 0), int(body.get("pool_ready") or 0)))')"; then
    if [ "${FORCE_RESTART:-0}" != "1" ]; then
      die "could not determine connected provider count; rerun with FORCE_RESTART=1 only after accepting drain impact"
    fi
    connected_count=0
    log "could not determine connected provider count; FORCE_RESTART=1 set, proceeding"
  fi
  if [ "${connected_count:-0}" -gt 0 ] && [ "${FORCE_RESTART:-0}" != "1" ]; then
    die "refusing restart with $connected_count connected provider(s); rerun with FORCE_RESTART=1 after accepting drain impact"
  fi

  local binary_backup=""
  local catalog_backup=""
  local catalog_created="0"
  REMOTE_STAGE="$(remote_create_stage)"
  log "remote staging dir: $REMOTE_STAGE (root-owned 0700)"

  log "uploading signed catalog"
  local catalog_output
  if ! catalog_output="$(remote_install_catalog "$REMOTE_STAGE")"; then
    printf '%s\n' "$catalog_output" >&2
    catalog_backup="$(printf '%s\n' "$catalog_output" | output_value catalog_backup)"
    if [[ "$catalog_output" == *"catalog_created=1"* ]]; then
      catalog_created="1"
    fi
    rollback_and_exit "catalog upload/install failed" "" "" "$catalog_backup" "$catalog_created"
  fi
  printf '%s\n' "$catalog_output" >&2
  catalog_backup="$(printf '%s\n' "$catalog_output" | output_value catalog_backup)"
  if [[ "$catalog_output" == *"catalog_created=1"* ]]; then
    catalog_created="1"
  fi

  if [ "$DEPLOY_COORDINATOR_BINARY" = "1" ]; then
    log "uploading coordinator binary artifact"
    local binary_output
    if ! binary_output="$(remote_install_binary "$REMOTE_STAGE")"; then
      printf '%s\n' "$binary_output" >&2
      binary_backup="$(printf '%s\n' "$binary_output" | output_value binary_backup)"
      rollback_and_exit "coordinator binary upload/install failed" "" "$binary_backup" "$catalog_backup" "$catalog_created"
    fi
    printf '%s\n' "$binary_output" >&2
    binary_backup="$(printf '%s\n' "$binary_output" | output_value binary_backup)"
  else
    log "DEPLOY_COORDINATOR_BINARY=0; keeping existing remote coordinator binary"
  fi

  log "merging tier2 block into live config"
  local patch_output backup_path
  if ! patch_output="$(remote_patch_config)"; then
    printf '%s\n' "$patch_output" >&2
    backup_path="$(printf '%s\n' "$patch_output" | output_value config_backup)"
    rollback_and_exit "live config tier2 merge failed" "$backup_path" "$binary_backup" "$catalog_backup" "$catalog_created"
  fi
  printf '%s\n' "$patch_output" >&2
  backup_path="$(printf '%s\n' "$patch_output" | output_value config_backup)"

  log "restarting coordinator for startup-only tier2 catalog fields"
  if ! "${SSH[@]}" "set -euo pipefail
      systemctl restart $(shell_quote "$SERVICE")
      sleep 3
      systemctl is-active $(shell_quote "$SERVICE")
    "; then
    rollback_and_exit "restart failed" "$backup_path" "$binary_backup" "$catalog_backup" "$catalog_created"
  fi

  log "verifying public coordinator health"
  if ! "${CURL[@]}" -fsS --max-time 10 "$COORDINATOR_ORIGIN/healthz" >/dev/null; then
    rollback_and_exit "public coordinator health check failed after restart" "$backup_path" "$binary_backup" "$catalog_backup" "$catalog_created"
  fi

  log "verifying tier2 catalog-loaded journal evidence"
  if ! "${SSH[@]}" "journalctl -u $(shell_quote "$SERVICE") --since '-5 min' --no-pager \
      | grep -E 'tier2 catalog loaded|catalog_loaded'"; then
    rollback_and_exit "missing recent tier2 catalog-loaded journal evidence after restart" "$backup_path" "$binary_backup" "$catalog_backup" "$catalog_created"
  fi

  log "recent tier2 provider hash journal evidence"
  "${SSH[@]}" "journalctl -u $(shell_quote "$SERVICE") --since '-5 min' --no-pager \
    | grep -E 'model_hash_(verified|uncatalogued|mismatch|invalid)' || true"

  if [ "${SKIP_GATEWAY_VERIFY:-0}" = "1" ]; then
    log "SKIP_GATEWAY_VERIFY=1; skipping /v1/models Tier-2 disclosure verification"
  else
    log "verifying gateway /v1/models Tier-2 disclosure"
    if ! "${CURL[@]}" -fsS --max-time 10 -H "X-Demo-Token: $DEMO_TOKEN" "$GATEWAY_ORIGIN/v1/models" \
      | python3 -c 'import json,sys; body=json.load(sys.stdin); tier2=body.get("tier2"); assert isinstance(tier2, dict), "missing tier2"; model_hash=tier2.get("model_hash"); assert isinstance(model_hash, dict), "missing tier2.model_hash"; state=model_hash.get("state"); assert state is not None, "missing tier2.model_hash.state"; assert model_hash.get("require_verified") is False, "require_hash_verified is not false"; print({"model_count": len(body.get("data", [])), "phase": tier2.get("phase"), "model_hash_state": state, "require_verified": model_hash.get("require_verified"), "catalog_available": model_hash.get("catalog_available")})'; then
      rollback_and_exit "gateway /v1/models Tier-2 disclosure verification failed" "$backup_path" "$binary_backup" "$catalog_backup" "$catalog_created"
    fi
  fi
}

pin_local_inputs
validate_local_inputs
# Constrained hermetic seam: overwrite operator catalog path after pin/validate
# only when running against the fake host with a temp-dir operator catalog.
if [ -n "${TIER2_ACTIVATE_TEST_REPLACEMENT:-}" ]; then
  [ "${TIER2_ACTIVATE_HERMETIC_TEST:-0}" = "1" ] || die "TIER2_ACTIVATE_TEST_REPLACEMENT requires TIER2_ACTIVATE_HERMETIC_TEST=1"
  [ "$VPS_HOST" = "fake-pearl.invalid" ] || die "TIER2_ACTIVATE_TEST_REPLACEMENT only allowed against fake-pearl.invalid"
  require_file "$TIER2_ACTIVATE_TEST_REPLACEMENT"
  [ -n "$CATALOG_OPERATOR" ] || die "CATALOG_OPERATOR unset for test replacement"
  case "$CATALOG_OPERATOR" in
    */tier2-activate-safety.*/fixtures/*) ;;
    *) die "TIER2_ACTIVATE_TEST_REPLACEMENT refused outside hermetic fixture catalog path" ;;
  esac
  cp "$TIER2_ACTIVATE_TEST_REPLACEMENT" "$CATALOG_OPERATOR"
  log "test seam: replaced operator catalog with $TIER2_ACTIVATE_TEST_REPLACEMENT"
fi
if [ "$mode" = "plan" ]; then
  print_plan
else
  apply_changes
fi
