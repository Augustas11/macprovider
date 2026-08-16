#!/usr/bin/env bash
# Immediately prevents new canary load. The sentinel is checked before any
# credential resolution or network call; scheduler shutdown is defense in depth.
set -euo pipefail

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  : "${CANARY_TEST_PLATFORM:?CANARY_TEST_PLATFORM is required when sourcing emergency-disable.sh}"
  platform="$CANARY_TEST_PLATFORM"
else
  case "$OSTYPE" in
    darwin*) platform="Darwin" ;;
    linux*) platform="Linux" ;;
    *) platform="$(/usr/bin/uname -s)" ;;
  esac
fi
target_uid=""
if [[ "$platform" == "Darwin" ]]; then
  target_user="${CANARY_TARGET_USER:-${SUDO_USER:-$(id -un)}}"
  if [[ "$target_user" == "root" && -z "${CANARY_TARGET_HOME:-}" ]]; then
    echo "canary: class=configuration_error set CANARY_TARGET_USER or CANARY_TARGET_HOME when disabling via a root shell" >&2
    exit 2
  fi
  target_uid="${CANARY_TARGET_UID:-$(id -u "$target_user")}"
  target_home="${CANARY_TARGET_HOME:-}"
  if [[ -z "$target_home" ]]; then
    target_home="$(dscl . -read "/Users/$target_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  fi
  if [[ -z "$target_home" || "$target_home" != /* ]]; then
    echo "canary: class=configuration_error cannot resolve target home for $target_user" >&2
    exit 2
  fi
  : "${CANARY_DISABLE_FILE:=$target_home/.local/state/canary-buyer/DISABLED}"
  : "${CANARY_ENABLE_FILE:=$target_home/.config/macprovider/canary-buyer.enabled}"
else
  : "${CANARY_DISABLE_FILE:=/var/lib/macprovider-canary-buyer/DISABLED}"
  : "${CANARY_ENABLE_FILE:=/etc/macprovider-canary-buyer/enabled}"
fi

mkdir -p "$(dirname "$CANARY_DISABLE_FILE")"
: >"$CANARY_DISABLE_FILE"
chmod 0644 "$CANARY_DISABLE_FILE"
rm -f "$CANARY_ENABLE_FILE"

SYSTEMCTL_BIN="${CANARY_SYSTEMCTL_BIN:-$(command -v systemctl || true)}"
if [[ -n "$SYSTEMCTL_BIN" && ( -n "${CANARY_SYSTEMCTL_BIN:-}" || -d /run/systemd/system ) ]]; then
  "$SYSTEMCTL_BIN" disable --now canary-buyer.timer
  "$SYSTEMCTL_BIN" stop canary-buyer.service
  if "$SYSTEMCTL_BIN" is-active --quiet canary-buyer.timer \
      || "$SYSTEMCTL_BIN" is-active --quiet canary-buyer.service; then
    echo "canary: class=emergency_disable_failed systemd unit remains active" >&2
    exit 1
  fi
  if "$SYSTEMCTL_BIN" is-enabled --quiet canary-buyer.timer; then
    echo "canary: class=emergency_disable_failed timer remains enabled" >&2
    exit 1
  fi
fi

LAUNCHCTL_BIN="${CANARY_LAUNCHCTL_BIN:-$(command -v launchctl || true)}"
if [[ -n "$LAUNCHCTL_BIN" && "$platform" == "Darwin" ]]; then
  launch_target="gui/$target_uid/com.malibu.canary-buyer"
  "$LAUNCHCTL_BIN" bootout "$launch_target" 2>/dev/null || true
  if "$LAUNCHCTL_BIN" print "$launch_target" >/dev/null 2>&1; then
    echo "canary: class=emergency_disable_failed launchd agent remains loaded" >&2
    exit 1
  fi
fi

echo "canary: class=emergency_disabled sentinel=$CANARY_DISABLE_FILE scheduler_stopped=true"
