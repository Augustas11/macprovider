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

require_line 'launchctl bootout "gui/$UID" "$PLIST_PATH"' "launchd bootout before replacement"
require_line 'launchctl enable "gui/$UID/live.streamvc.macprovider"' "launchd enable before bootstrap"
require_line 'launchctl bootstrap "gui/$UID" "$PLIST_PATH"' "launchd bootstrap"
require_line 'Would enable launchd service: launchctl enable gui/$UID/live.streamvc.macprovider' "dry-run enable hint"
require_line 'Installing as a background launchd service.' "automatic launchd install message"
require_line 'MACPROVIDER_NO_LAUNCHD=1 expert/debug override' "explicit no-launchd escape hatch"
require_line 'Model download ${bar}' "model download progress bar"
require_line 'known_weight_gb_for_model()' "built-in model download size estimates"
require_line 'partial model cache detected' "partial cache cold-timeout path"

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

bootout_line="$(line_number 'launchctl bootout "gui/$UID" "$PLIST_PATH"')"
enable_line="$(line_number 'launchctl enable "gui/$UID/live.streamvc.macprovider"')"
bootstrap_line="$(line_number 'launchctl bootstrap "gui/$UID" "$PLIST_PATH"')"

[ -n "$bootout_line" ] || die "could not locate bootout line"
[ -n "$enable_line" ] || die "could not locate enable line"
[ -n "$bootstrap_line" ] || die "could not locate bootstrap line"

if [ "$bootout_line" -ge "$enable_line" ] || [ "$enable_line" -ge "$bootstrap_line" ]; then
  die "launchd sequence must be bootout -> enable -> bootstrap; got $bootout_line -> $enable_line -> $bootstrap_line"
fi

printf '[install-launchd-test] install.sh launchd enable sequencing ok\n'
