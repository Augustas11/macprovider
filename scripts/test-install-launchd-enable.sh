#!/usr/bin/env bash
# Hermetic guard for install.sh launchd recovery sequencing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

die() {
  printf '[install-launchd-test] ERROR: %s\n' "$*" >&2
  exit 1
}

require_line() {
  local pattern="$1"
  local description="$2"
  if ! grep -Fq "$pattern" "$INSTALL_SH"; then
    die "missing $description: $pattern"
  fi
}

line_number() {
  local pattern="$1"
  awk -v pattern="$pattern" 'index($0, pattern) { print NR; exit }' "$INSTALL_SH"
}

require_line 'LAUNCHD_DOMAIN="gui/$UID"' "default consumer GUI launchd domain"
require_line 'launchctl_service bootout "$service_target"' "label-target launchd bootout"
require_line 'reclaim_launchd_service "$PROVIDER_LABEL"' "provider launchd reclaim before replacement"
require_line 'launchctl_service enable "$LAUNCHD_DOMAIN/$PROVIDER_LABEL"' "launchd enable before bootstrap"
require_line 'launchctl_service bootstrap "$LAUNCHD_DOMAIN" "$PLIST_BOOTSTRAP_PATH"' "launchd bootstrap"
require_line 'Would enable launchd service: launchctl enable $LAUNCHD_DOMAIN/$PROVIDER_LABEL' "dry-run enable hint"
require_line 'Installing as a background launchd service.' "automatic launchd install message"
require_line 'MACPROVIDER_NO_LAUNCHD=1 expert/debug override' "explicit no-launchd escape hatch"
require_line 'holding_executable="$(lsof -a -p "$holding_pid" -d txt -Fn' "listener executable identity lookup"
require_line 'if [ "$INSTALL_TX_SERVICE_WAS_ACTIVE" -eq 0 ] && [ "$INSTALL_TX_LEGACY_SERVICE_WAS_ACTIVE" -eq 0 ]; then' \
  "legacy launchd upgrades skip manual-process capture"
require_line 'launchctl_service print "$LAUNCHD_DOMAIN/$LEGACY_PROVIDER_LABEL"' "legacy launchd service snapshot"
require_line 'could not bootstrap the previous legacy provider service' "legacy LaunchAgent rollback restore"
require_line 'could not bootstrap the previous legacy watchdog service' "legacy watchdog rollback restore"
require_line '<key>MACPROVIDER_CONFIG</key>' "launchd absolute config env key"
require_line '<string>$config_path</string>' "launchd absolute config env value"
require_line 'Model download ${bar}' "model download progress bar"
require_line 'known_weight_gb_for_model()' "built-in model download size estimates"
require_line 'partial model cache detected' "partial cache cold-timeout path"
require_line 'macprovider-cli autotune --config' "valid autotune operator handoff"

if grep -Fq 'autotune --provider-id' "$INSTALL_SH"; then
  die "installer must not print the unsupported autotune --provider-id option"
fi

if grep -Fq 'Install as a background service?' "$INSTALL_SH"; then
  die "installer should not ask whether to install the required background service"
fi

progress_lib="$(mktemp "${TMPDIR:-/tmp}/macprovider-install-progress.XXXXXX")"
trap 'rm -f "$progress_lib"' EXIT
awk '
  /^cache_size_kb\(\)/ { emit = 1 }
  /^wait_for_local_model\(\)/ { emit = 0 }
  emit { print }
' "$INSTALL_SH" > "$progress_lib"

progress_output="$(
  log() { printf '[macprovider-install] %s\n' "$*"; }
  # shellcheck source=/dev/null
  . "$progress_lib"
  cache_size_kb() { printf '524288'; }
  print_model_download_progress '/unused/cache' 2 45 0
)"

case "$progress_output" in
  *'Model download [#####...............] 0.5/2 GiB (25%, +0.5 GiB; 45s elapsed).'*)
    ;;
  *)
    die "unexpected model download progress output: $progress_output"
    ;;
esac

cache_classification_output="$(
  log() { printf '[macprovider-install] %s\n' "$*"; }
  # shellcheck source=/dev/null
  . "$progress_lib"
  if model_cache_is_warm 524288 2; then
    printf 'partial=warm\n'
  else
    printf 'partial=cold\n'
  fi
  if model_cache_is_warm 1887436 2; then
    printf 'near_complete=warm\n'
  else
    printf 'near_complete=cold\n'
  fi
  if model_cache_is_warm 1 0; then
    printf 'unknown=warm\n'
  else
    printf 'unknown=cold\n'
  fi
)"

case "$cache_classification_output" in
  *'partial=cold'*'near_complete=warm'*'unknown=warm'*)
    ;;
  *)
    die "unexpected model cache classification output: $cache_classification_output"
    ;;
esac

install_plist_line="$(line_number 'install_plist() {')"
line_number_after() {
  local start_line="$1"
  local pattern="$2"
  awk -v start_line="$start_line" -v pattern="$pattern" \
    'NR > start_line && index($0, pattern) { print NR; exit }' "$INSTALL_SH"
}

reclaim_line="$(line_number_after "$install_plist_line" 'reclaim_launchd_service "$PROVIDER_LABEL"')"
enable_line="$(line_number_after "$install_plist_line" 'launchctl_service enable "$LAUNCHD_DOMAIN/$PROVIDER_LABEL"')"
bootstrap_line="$(line_number_after "$install_plist_line" 'launchctl_service bootstrap "$LAUNCHD_DOMAIN" "$PLIST_BOOTSTRAP_PATH"')"

[ -n "$reclaim_line" ] || die "could not locate provider reclaim line"
[ -n "$enable_line" ] || die "could not locate enable line"
[ -n "$bootstrap_line" ] || die "could not locate bootstrap line"

if [ "$reclaim_line" -ge "$enable_line" ] || [ "$enable_line" -ge "$bootstrap_line" ]; then
  die "launchd sequence must be reclaim -> enable -> bootstrap; got $reclaim_line -> $enable_line -> $bootstrap_line"
fi

printf '[install-launchd-test] install.sh launchd enable sequencing ok\n'
