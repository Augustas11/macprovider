#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_function() {
  name="$1"
  if [ "$name" = "semantic_merge_config" ]; then
    sed -n '/^semantic_merge_config()/,/^write_config()/p' "$INSTALL_SH" | sed '$d'
    return
  fi
  awk -v start="${name}() {" '
    $0 == start { inside=1 }
    inside { print }
    inside && /^}$/ { exit }
  ' "$INSTALL_SH"
}

for function_name in \
  validate_install_dir validate_port_value \
  prepare_staged_config activate_staged_config select_autotune_benchmark_port \
  semantic_merge_config restore_existing_provider_if_start_skipped \
  prefetch_upgrade_autotune_model own_macprovider_cli_holds_live_port \
  validate_staged_entries; do
  extract_function "$function_name" >> "$TMP/helpers.sh"
done

# shellcheck source=/dev/null
source "$TMP/helpers.sh" || exit 1

arm_transaction_recovery_agent() { :; }

if grep -Fq 'model="$(choose_model "$ram_gb")"' "$INSTALL_SH"; then
  echo "installer still selects a model from mutable RAM tables before verified autotune" >&2
  exit 1
fi
if grep -Fq 'check_catalog_ram_metadata "$coordinator_base" "$model"' "$INSTALL_SH"; then
  echo "installer still queries the legacy unsigned catalog selection surface" >&2
  exit 1
fi
python3 - "$INSTALL_SH" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
main = source[source.rindex("\nmain() {"):]
snapshot = main.index("begin_install_transaction")
stage = main.index("stage_release_payload", snapshot)
prepare = main.index("prepare_staged_config", stage)
freshness = main.index("use_fresh_recommendation_if_available", stage)
recommend_gate = main.index('if [ "$AUTOTUNE_RECOMMENDATION_REQUIRED" -eq 1 ]', freshness)
prefetch = main.index("prefetch_upgrade_autotune_model", freshness)
cutover_marker = main.index("mark_install_cutover_started", recommend_gate)
stop = main.index("ensure_port_free 1", recommend_gate)
recommend = main.index("run_autotune_recommend_apply", stop)
install = main.index("install_binary", recommend)
activate = main.index("activate_staged_config", install)
if not snapshot < stage < prepare < freshness < prefetch < recommend_gate < cutover_marker < stop < recommend < install < activate:
    raise SystemExit("benchmarks are not isolated from the live provider and staged cutover")
helper = source[source.index("run_macprovider_cli_with_amfi_retry() {"):source.index("detect_existing_port() {")]
if 'local cli_path="$MACPROVIDER_CLI_EXECUTABLE"' not in helper:
    raise SystemExit("recommendation helper is not routed to the staged CLI")
recommend_helper = source[source.index("run_autotune_recommend_apply() {"):source.index("use_fresh_recommendation_if_available() {")]
if '--port "${AUTOTUNE_BENCHMARK_PORT:-19080}" --config "$CONFIG_PATH"' not in recommend_helper:
    raise SystemExit("recommendation benchmarks do not use a reserved non-live port")
PY

die() {
  exit "$1"
}

HOME="$TMP/home"
mkdir -m 700 "$HOME"
INSTALL_DIR="$HOME/macprovider"
validate_install_dir
[ "$INSTALL_DIR" = "$HOME/macprovider" ] || {
  echo "safe install path was not preserved" >&2
  exit 1
}
for unsafe in / "$HOME" "$HOME/../escape"; do
  if (INSTALL_DIR="$unsafe"; validate_install_dir); then
    echo "unsafe install path unexpectedly passed: $unsafe" >&2
    exit 1
  fi
done
mkdir -m 700 "$HOME/real"
ln -s "$HOME/real" "$HOME/link"
if (INSTALL_DIR="$HOME/link/provider"; validate_install_dir); then
  echo "symlinked install path unexpectedly passed" >&2
  exit 1
fi
mkdir -m 777 "$HOME/shared"
chmod 777 "$HOME/shared"
if (INSTALL_DIR="$HOME/shared/provider"; validate_install_dir); then
  echo "world-writable install ancestor unexpectedly passed" >&2
  exit 1
fi

complete_payload="$(printf '%s\n' \
  macprovider-cli \
  mlx.metallib \
  compatibility-set.json \
  compatibility-set-local \
  compatibility-set-local/install.sh \
  compatibility-set-local/provider-launch-agent.plist.template \
  compatibility-set-local/updater-rollback.json \
  compatibility-set-local/watchdog-launch-agent.plist.template \
  compatibility-set-local/watchdog.sh \
  Runtime.bundle \
  Runtime.bundle/resource \
  catalog-release \
  catalog-release/release.json \
  catalog-release/trusted-keys.json \
  catalog-release/tier2-catalog.json \
  catalog-release/autotune-candidates.json \
  catalog-release/autotune-candidates.json.sig \
  catalog-release/demand-rank.json \
  catalog-release/demand-rank.json.sig \
  catalog-release/rate-card.json \
  catalog-release/rate-card.json.sig)"
validate_staged_entries "$complete_payload" "test payload"
if (validate_staged_entries "${complete_payload//$'\n'mlx.metallib/}" "test payload"); then
  echo "payload without mlx.metallib unexpectedly passed validation" >&2
  exit 1
fi
if (validate_staged_entries "${complete_payload//$'\n'Runtime.bundle$'\n'Runtime.bundle\/resource/}" "test payload"); then
  echo "payload without a SwiftPM bundle unexpectedly passed validation" >&2
  exit 1
fi
if (validate_staged_entries "${complete_payload//$'\n'catalog-release\/release.json/}" "test payload"); then
  echo "payload without the signed catalog manifest unexpectedly passed validation" >&2
  exit 1
fi
if (validate_staged_entries "${complete_payload//$'\n'catalog-release\/rate-card.json.sig/}" "test payload"); then
  echo "payload without the signed rate-card sidecar unexpectedly passed validation" >&2
  exit 1
fi
if (validate_staged_entries "${complete_payload//$'\n'compatibility-set.json/}" "test payload"); then
  echo "payload without the compatibility-set manifest unexpectedly passed validation" >&2
  exit 1
fi

CONFIG_DIR="$TMP/home/.config/macprovider"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
LIVE_CONFIG_PATH="$CONFIG_PATH"
PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
LIVE_PROVIDER_ID_PATH="$PROVIDER_ID_PATH"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_PATH" <<'EOF'
# operator-owned settings must survive installer upgrades
model: "old/model"
provider_token: "secret-token"
receipt_log_path: "/private/receipts.jsonl"
enable_receipts: false
enable_warm_swap: true
auto_update: false
custom_block:
  nested: keep-me
port: 18080
EOF

semantic_merge_config \
  "$CONFIG_PATH" \
  "new/model" \
  "provider-new" \
  "wss://coordinator.example/ws/provider" \
  "19090"

grep -F 'model: "new/model"' "$CONFIG_PATH" >/dev/null
grep -F 'provider_id: "provider-new"' "$CONFIG_PATH" >/dev/null
grep -F 'coordinator_url: "wss://coordinator.example/ws/provider"' "$CONFIG_PATH" >/dev/null
grep -F 'port: 19090' "$CONFIG_PATH" >/dev/null
grep -F 'provider_token: "secret-token"' "$CONFIG_PATH" >/dev/null
grep -F 'receipt_log_path: "/private/receipts.jsonl"' "$CONFIG_PATH" >/dev/null
grep -F 'enable_receipts: false' "$CONFIG_PATH" >/dev/null
grep -F 'enable_warm_swap: true' "$CONFIG_PATH" >/dev/null
grep -F 'auto_update: false' "$CONFIG_PATH" >/dev/null
grep -F '  nested: keep-me' "$CONFIG_PATH" >/dev/null

semantic_merge_config \
  "$CONFIG_PATH" \
  "new/model" \
  "provider-new" \
  "wss://coordinator.example/ws/provider" \
  "19090" \
  "true"

grep -F 'enable_receipts: true' "$CONFIG_PATH" >/dev/null
[ "$(grep -c '^enable_receipts:' "$CONFIG_PATH")" -eq 1 ]
grep -F 'provider_token: "secret-token"' "$CONFIG_PATH" >/dev/null
grep -F 'receipt_log_path: "/private/receipts.jsonl"' "$CONFIG_PATH" >/dev/null
grep -F 'enable_warm_swap: true' "$CONFIG_PATH" >/dev/null
grep -F 'auto_update: false' "$CONFIG_PATH" >/dev/null
grep -F '  nested: keep-me' "$CONFIG_PATH" >/dev/null

staging_dir="$TMP/staging"
mkdir -p "$staging_dir"
printf 'provider-old\n' > "$LIVE_PROVIDER_ID_PATH"
prepare_staged_config
grep -F 'model: "new/model"' "$STAGED_CONFIG_PATH" >/dev/null
semantic_merge_config "$STAGED_CONFIG_PATH" "staged/model" "provider-staged" "wss://staged.example/ws/provider" "19090"
printf 'provider-staged\n' > "$STAGED_PROVIDER_ID_PATH"
grep -F 'model: "new/model"' "$LIVE_CONFIG_PATH" >/dev/null
activate_staged_config
grep -F 'model: "staged/model"' "$LIVE_CONFIG_PATH" >/dev/null
grep -F 'provider-staged' "$LIVE_PROVIDER_ID_PATH" >/dev/null

PORT=18080
lsof() {
  case "$*" in
    *-iTCP:19080*) printf '123\n' ;;
    *) return 1 ;;
  esac
}
select_autotune_benchmark_port
[ "$AUTOTUNE_BENCHMARK_PORT" = "19081" ] || {
  echo "autotune did not reserve the next free non-live benchmark port" >&2
  exit 1
}
if (MACPROVIDER_AUTOTUNE_PORT=18080; select_autotune_benchmark_port); then
  echo "autotune accepted the live provider port for staged benchmarks" >&2
  exit 1
fi

CONFIG_PATH="$LIVE_CONFIG_PATH"
PROVIDER_ID_PATH="$LIVE_PROVIDER_ID_PATH"
CUTOVER_STARTED=0
INSTALL_TX_WATCHDOG_WAS_ACTIVE=0
WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
WATCHDOG_PLIST_PATH="$TMP/home/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
log() { :; }

skip_restore_called="$TMP/skip-restore-called"
skip_discard_called="$TMP/skip-discard-called"
(
  SKIP_PROVIDER_START=1
  EXISTING_INSTALL_WAS_PRESENT=1
  rollback_install_transaction() { : > "$skip_restore_called"; }
  discard_install_transaction_before_cutover() { : > "$skip_discard_called"; }
  restore_existing_provider_if_start_skipped
)
test -f "$skip_discard_called"
test ! -f "$skip_restore_called"

(
  SKIP_PROVIDER_START=1
  EXISTING_INSTALL_WAS_PRESENT=1
  CUTOVER_STARTED=1
  rollback_install_transaction() { : > "$skip_restore_called"; }
  restore_existing_provider_if_start_skipped
)
test -f "$skip_restore_called"

( SKIP_PROVIDER_START=1; EXISTING_INSTALL_WAS_PRESENT=0; ! restore_existing_provider_if_start_skipped )

PORT=18080
INSTALL_DIR="$TMP/install"

# prefetch_upgrade_autotune_model retry dead-end fix: a prior install that
# carries no signed-catalog model id (donor-mode / never-started / minimally
# seeded config from an interrupted first run) must NOT die 6 on retry when no
# provider service is running. It should fall through to a fresh recommendation.
(
  lsof() { return 1; }  # nothing holding the port
  EXISTING_INSTALL_WAS_PRESENT=1
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=0
  prefetch_upgrade_autotune_model
) || {
  echo "prefetch dead-ended a retry with no live provider instead of re-tuning" >&2
  exit 1
}

# But when a launchd provider service IS active, prefetch must still fail
# closed rather than stop a live earner for a blind re-tune with no pinned model.
if (
  lsof() { return 1; }
  EXISTING_INSTALL_WAS_PRESENT=1
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=1
  prefetch_upgrade_autotune_model
); then
  echo "prefetch stopped a live launchd provider for a blind re-tune with no pinned model" >&2
  exit 1
fi

# And when a MANUALLY started macprovider-cli holds the live port (no launchd
# service, so INSTALL_TX_SERVICE_WAS_ACTIVE=0), prefetch must ALSO fail closed --
# INSTALL_TX_SERVICE_WAS_ACTIVE alone is not a sufficient live-provider signal.
if (
  # Mock lsof: report a listener on $PORT whose txt executable is our own CLI.
  # The -d txt query resolves the executable; the -iTCP query lists the pid.
  lsof() {
    case "$*" in
      *-d\ txt*) printf 'n%s/macprovider-cli\n' "$INSTALL_DIR" ;;
      *-iTCP:*) printf '4242\n' ;;
      *) return 1 ;;
    esac
  }
  EXISTING_INSTALL_WAS_PRESENT=1
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=0
  prefetch_upgrade_autotune_model
); then
  echo "prefetch stopped a live MANUAL provider (own CLI on port) for a blind re-tune" >&2
  exit 1
fi

# A FOREIGN process on the port (not our CLI) is not our provider; fall through.
(
  lsof() {
    case "$*" in
      *-d\ txt*) printf 'n/usr/bin/some-other-daemon\n' ;;
      *-iTCP:*) printf '9999\n' ;;
      *) return 1 ;;
    esac
  }
  EXISTING_INSTALL_WAS_PRESENT=1
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=0
  prefetch_upgrade_autotune_model
) || {
  echo "prefetch fail-closed on a foreign (non-CLI) port holder" >&2
  exit 1
}

# No existing install at all: prefetch is a no-op.
(
  lsof() { return 1; }
  EXISTING_INSTALL_WAS_PRESENT=0
  AUTOTUNE_UPGRADE_CANDIDATE_MODEL_ID=""
  INSTALL_TX_SERVICE_WAS_ACTIVE=0
  prefetch_upgrade_autotune_model
) || {
  echo "prefetch failed the fresh-install no-op case" >&2
  exit 1
}

echo "provider upgrade staging, config preservation, and cutover ordering ok"
