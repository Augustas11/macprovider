#!/usr/bin/env bash
# Public uninstall script for the user-level Mac Provider install.

set -euo pipefail

INSTALL_DIR="$HOME/macprovider"
BIN_DIR="$HOME/.local/bin"
BINARY_PATH="$BIN_DIR/macprovider-cli"
PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist"
LOG_DIR="$HOME/Library/Logs/macprovider"
CACHE_DIR="$HOME/.cache/macprovider"
DRY_RUN=0
NO_PROMPT="${MACPROVIDER_NO_PROMPT:-0}"

log() { printf "[macprovider-uninstall] %s\n" "$*"; }

read_line() {
  REPLY=""
  if [ -r /dev/tty ]; then
    IFS= read -r REPLY < /dev/tty || REPLY=""
  else
    IFS= read -r REPLY || REPLY=""
  fi
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf "Usage: bash uninstall.sh [--dry-run]\n"
      exit 0
      ;;
    *)
      printf "[macprovider-uninstall] ERROR: unknown argument: %s\n" "$arg" >&2
      exit 7
      ;;
  esac
done

confirm() {
  if [ "$NO_PROMPT" = "1" ]; then
    log "Proceeding without prompt because MACPROVIDER_NO_PROMPT=1."
    return 0
  fi

  cat <<EOF
This will remove:
  $PLIST_PATH
  $BINARY_PATH
  $INSTALL_DIR
  $LOG_DIR

It will not remove $CACHE_DIR, Hugging Face caches, or other files outside these paths.
EOF
  printf "Uninstall Mac Provider? [y/N] "
  read_line
  answer="$REPLY"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "[dry-run] "
    printf "%q " "$@"
    printf "\n"
  else
    "$@"
  fi
}

guard_safe_path() {
  label="$1"
  path="$2"
  expected="$3"
  case "$path" in
    ""|"/"|"$HOME"|"$HOME/"|"/Users"|"/Users/"|"/Users/"*)
      [ "$path" = "$expected" ] || {
        printf "[macprovider-uninstall] ERROR: refusing unsafe %s path: %s\n" "$label" "$path" >&2
        exit 7
      }
      ;;
  esac
  [ "$path" = "$expected" ] || {
    printf "[macprovider-uninstall] ERROR: refusing non-standard %s path: %s\n" "$label" "$path" >&2
    exit 7
  }
}

main() {
  guard_safe_path "binary" "$BINARY_PATH" "$HOME/.local/bin/macprovider-cli"
  guard_safe_path "support" "$INSTALL_DIR" "$HOME/macprovider"
  guard_safe_path "log" "$LOG_DIR" "$HOME/Library/Logs/macprovider"

  if ! confirm; then
    log "Aborted."
    exit 7
  fi

  if [ -f "$PLIST_PATH" ]; then
    run launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
    run rm -f "$PLIST_PATH"
  else
    log "No launchd plist found at $PLIST_PATH."
  fi

  # v1.2.2+: BINARY_PATH is a symlink to $INSTALL_DIR/macprovider-cli.
  # Use -e/-L tests so both the symlink case and any legacy direct-file
  # install from older v1.2.1 are handled.
  if [ -e "$BINARY_PATH" ] || [ -L "$BINARY_PATH" ]; then
    run rm -f "$BINARY_PATH"
  fi

  if [ -d "$INSTALL_DIR" ]; then
    run rm -rf "$INSTALL_DIR"
  fi

  if [ -d "$LOG_DIR" ]; then
    run rm -rf "$LOG_DIR"
  fi

  log "macprovider-cli has been uninstalled."
  if [ -d "$CACHE_DIR" ]; then
    log "Left cache directory in place: $CACHE_DIR"
  fi
  log "If you want to fully uninstall MLX-cached models from ~/.cache/huggingface/, do that manually."
}

main "$@"
