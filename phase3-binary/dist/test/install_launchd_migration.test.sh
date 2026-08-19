#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" > "$TMP/functions.sh" <<'PY'
import sys

names = [
    "xml_escape",
    "write_atomic_install_file",
    "reclaim_launchd_service",
    "reclaim_legacy_launchd_service",
    "render_plist",
    "render_watchdog_plist",
    "install_plist",
    "install_watchdog",
]
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
for name in names:
    for index, line in enumerate(lines):
        if line != f"{name}() {{":
            continue
        depth = 0
        while index < len(lines):
            current = lines[index]
            print(current)
            depth += current.count("{") - current.count("}")
            index += 1
            if depth == 0:
                break
        break
    else:
        raise SystemExit(f"could not extract {name}")
PY
printf '%s\n' 'PROVIDER_LABEL="${PROVIDER_LABEL:-live.malibu.provider}"' >> "$TMP/functions.sh"
printf '%s\n' 'LEGACY_PROVIDER_LABEL="${LEGACY_PROVIDER_LABEL:-live.streamvc.macprovider}"' >> "$TMP/functions.sh"
printf '%s\n' 'LEGACY_PLIST_PATH="${LEGACY_PLIST_PATH:-$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist}"' >> "$TMP/functions.sh"
printf '%s\n' 'WATCHDOG_LABEL="${WATCHDOG_LABEL:-live.malibu.provider-watchdog}"' >> "$TMP/functions.sh"
printf '%s\n' 'LEGACY_WATCHDOG_LABEL="${LEGACY_WATCHDOG_LABEL:-live.streamvc.macprovider-watchdog}"' >> "$TMP/functions.sh"
printf '%s\n' 'LEGACY_WATCHDOG_PLIST_PATH="${LEGACY_WATCHDOG_PLIST_PATH:-$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist}"' >> "$TMP/functions.sh"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/plutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  -lint)
    [ -f "${2:-}" ]
    ;;
  *)
    echo "unsupported plutil mode in launchd migration fixture" >&2
    exit 2
    ;;
esac
EOF
chmod 0755 "$TMP/bin/plutil"

cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  print)
    if [ ! -f "$LAUNCHD_STATE" ]; then
      exit 1
    fi
    case "$2" in
      *live.malibu.provider-watchdog*)
        printf 'gui/%s/live.malibu.provider-watchdog = {\n  program = %s\n  path = %s\n}\n' \
          "$(id -u)" "$WATCHDOG_PROGRAM" "${PRINTED_PLIST_PATH:-$WATCHDOG_PLIST_PATH}"
        ;;
      *)
        printf 'gui/%s/live.malibu.provider = {\n  program = %s\n  path = %s\n}\n' \
          "$(id -u)" "$PROVIDER_PROGRAM" "${PRINTED_PLIST_PATH:-$PLIST_PATH}"
        ;;
    esac
    ;;
  bootout)
    printf '%s\n' "$*" >> "$LAUNCHD_LOG"
    if [ "${BOOTOUT_FAIL:-0}" -eq 1 ]; then
      exit 1
    fi
    rm -f "$LAUNCHD_STATE"
    ;;
  enable|disable)
    printf '%s\n' "$*" >> "$LAUNCHD_LOG"
    ;;
  bootstrap)
    printf '%s\n' "$*" >> "$LAUNCHD_LOG"
    touch "$LAUNCHD_STATE"
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod 0755 "$TMP/bin/launchctl"

run_reclaim() {
  LAUNCHD_STATE="$TMP/launchd-state"
  LAUNCHD_LOG="$TMP/launchd.log"
  FUNCTION_PATH="$TMP/functions.sh" \
    PROVIDER_LABEL="live.malibu.provider" \
    WATCHDOG_LABEL="live.malibu.provider-watchdog" \
    INSTALL_DIR="$TMP/home/macprovider" \
    BINARY_PATH="$TMP/home/.local/bin/macprovider-cli" \
    WATCHDOG_DIR="$TMP/home/.local/share/macprovider-watchdog" \
    WATCHDOG_PATH="$TMP/home/.local/share/macprovider-watchdog/macprovider-health-monitor" \
    PLIST_PATH="$TMP/home/Library/LaunchAgents/live.malibu.provider.plist" \
    WATCHDOG_PLIST_PATH="$TMP/home/Library/LaunchAgents/live.malibu.provider-watchdog.plist" \
    PROVIDER_PROGRAM="$TMP/home/.local/bin/macprovider-cli" \
    WATCHDOG_PROGRAM="$TMP/home/.local/share/macprovider-watchdog/watchdog.sh" \
    PATH="$TMP/bin:$PATH" \
    LAUNCHD_STATE="$LAUNCHD_STATE" \
    LAUNCHD_LOG="$LAUNCHD_LOG" \
    PRINTED_PLIST_PATH="${PRINTED_PLIST_PATH:-}" \
    BOOTOUT_FAIL="${1:-0}" \
    bash -c '
      set -euo pipefail
      log() { :; }
      run() { "$@"; }
      die() { return "$1"; }
      write_watchdog_script() { :; }
    INSTALL_TX_ACTIVE=1
    INSTALL_TX_HAD_PLIST=1
    INSTALL_TX_HAD_WATCHDOG_PLIST=1
    DRY_RUN=0
    NO_LAUNCHD=0
    NO_WATCHDOG=0
    LAUNCHD_INSTALLED=0
    WATCHDOG_INSTALLED=0
    source "$FUNCTION_PATH"
      reclaim_launchd_service "$PROVIDER_LABEL"
    '
}

touch "$TMP/launchd-state"
run_reclaim
grep -Fx "bootout gui/$(id -u)/live.malibu.provider" "$TMP/launchd.log" >/dev/null
[ ! -f "$TMP/launchd-state" ]

rm -f "$TMP/launchd-state" "$TMP/launchd.log"
run_reclaim
[ ! -s "$TMP/launchd.log" ]

touch "$TMP/launchd-state"
set +e
run_reclaim 1
reclaim_rc=$?
set -e
[ "$reclaim_rc" -ne 0 ]
[ -f "$TMP/launchd-state" ]

rm -f "$TMP/launchd.log"
set +e
PRINTED_PLIST_PATH="$TMP/home/Library/LaunchAgents/unexpected.plist" run_reclaim
reclaim_rc=$?
set -e
[ "$reclaim_rc" -ne 0 ]
[ -f "$TMP/launchd-state" ]

rm -f "$TMP/launchd-state" "$TMP/launchd.log"
mkdir -p "$TMP/home/Library/LaunchAgents" "$TMP/home/.local/bin" "$TMP/home/.local/share/macprovider-watchdog"
printf '<plist>old</plist>\n' > "$TMP/home/Library/LaunchAgents/live.malibu.provider.plist"
printf '<plist>old-watchdog</plist>\n' > "$TMP/home/Library/LaunchAgents/live.malibu.provider-watchdog.plist"
touch "$TMP/launchd-state"
HOME="$TMP/home" \
  FUNCTION_PATH="$TMP/functions.sh" \
  PROVIDER_PROGRAM="$TMP/home/.local/bin/macprovider-cli" \
  WATCHDOG_PROGRAM="$TMP/home/.local/share/macprovider-watchdog/watchdog.sh" \
  PATH="$TMP/bin:$PATH" \
  LAUNCHD_STATE="$TMP/launchd-state" \
  LAUNCHD_LOG="$TMP/launchd.log" \
  bash -c '
    set -euo pipefail
    log() { :; }
    run() { "$@"; }
    die() { return "$1"; }
    assert_install_lock_ownership() { :; }
    write_watchdog_script() { printf "watchdog\n" > "$WATCHDOG_PATH"; }
    source "$FUNCTION_PATH"
    INSTALL_DIR="$HOME/macprovider"
    BINARY_PATH="$HOME/.local/bin/macprovider-cli"
    WATCHDOG_DIR="$HOME/.local/share/macprovider-watchdog"
    WATCHDOG_PATH="$WATCHDOG_DIR/macprovider-health-monitor"
    CONFIG_PATH="$HOME/.config/macprovider/config.yaml"
    LOG_DIR="$HOME/Library/Logs/macprovider"
    PLIST_PATH="$HOME/Library/LaunchAgents/live.malibu.provider.plist"
    WATCHDOG_PLIST_PATH="$HOME/Library/LaunchAgents/live.malibu.provider-watchdog.plist"
    PROVIDER_LABEL="live.malibu.provider"
    WATCHDOG_LABEL="live.malibu.provider-watchdog"
    DRY_RUN=0
    NO_LAUNCHD=0
    NO_WATCHDOG=0
    LAUNCHD_INSTALLED=0
    WATCHDOG_INSTALLED=0
    PROVIDER_PROGRAM="$BINARY_PATH"
    WATCHDOG_PROGRAM="$WATCHDOG_DIR/watchdog.sh"
    INSTALL_TX_ACTIVE=1
    INSTALL_TX_HAD_PLIST=1
    INSTALL_TX_HAD_WATCHDOG_PLIST=1
    install_plist "mlx-community/Qwen" "provider" "https://coordinator.example"
    [ "$LAUNCHD_INSTALLED" -eq 1 ]
    install_watchdog "https://coordinator.example"
    [ "$WATCHDOG_INSTALLED" -eq 1 ]
  '
grep -F 'enable gui/' "$TMP/launchd.log" | grep -F 'live.malibu.provider' >/dev/null
grep -F 'bootstrap gui/' "$TMP/launchd.log" | grep -F 'live.malibu.provider.plist' >/dev/null
grep -F 'enable gui/' "$TMP/launchd.log" | grep -F 'live.malibu.provider-watchdog' >/dev/null
grep -F 'bootstrap gui/' "$TMP/launchd.log" | grep -F 'live.malibu.provider-watchdog.plist' >/dev/null

rm -f "$TMP/launchd-state" "$TMP/launchd.log"
touch "$TMP/launchd-state"
set +e
FUNCTION_PATH="$TMP/functions.sh" \
  PROVIDER_LABEL="live.malibu.provider" \
  WATCHDOG_LABEL="live.malibu.provider-watchdog" \
  INSTALL_DIR="$TMP/home/macprovider" \
  BINARY_PATH="$TMP/home/.local/bin/macprovider-cli" \
  WATCHDOG_DIR="$TMP/home/.local/share/macprovider-watchdog" \
  WATCHDOG_PATH="$TMP/home/.local/share/macprovider-watchdog/macprovider-health-monitor" \
  PLIST_PATH="$TMP/home/Library/LaunchAgents/live.malibu.provider.plist" \
  WATCHDOG_PLIST_PATH="$TMP/home/Library/LaunchAgents/live.malibu.provider-watchdog.plist" \
  PROVIDER_PROGRAM="$TMP/unexpected-provider" \
  WATCHDOG_PROGRAM="$TMP/home/.local/share/macprovider-watchdog/watchdog.sh" \
  PATH="$TMP/bin:$PATH" LAUNCHD_STATE="$TMP/launchd-state" LAUNCHD_LOG="$TMP/launchd.log" \
  bash -c '
    set -euo pipefail
    log() { :; }
    source "$FUNCTION_PATH"
    INSTALL_TX_ACTIVE=1; INSTALL_TX_HAD_PLIST=1; INSTALL_TX_HAD_WATCHDOG_PLIST=1
    reclaim_launchd_service "$PROVIDER_LABEL"
  '
unexpected_rc=$?
set -e
[ "$unexpected_rc" -ne 0 ]
[ -f "$TMP/launchd-state" ]

grep -F 'reclaim_launchd_service "$PROVIDER_LABEL"' "$INSTALL_SH" >/dev/null
grep -F 'reclaim_launchd_service "$WATCHDOG_LABEL"' "$INSTALL_SH" >/dev/null
grep -F 'service_identity_matches' "$INSTALL_SH" >/dev/null
grep -F 'launchctl bootout "gui/$REC_UID/$service_label"' "$INSTALL_SH" >/dev/null
if grep -F 'launchctl bootout "gui/$REC_UID" "$REC_PLIST_PATH"' "$INSTALL_SH" >/dev/null; then
  echo "recovery still uses path-based provider bootout" >&2
  exit 1
fi
echo "launchd migration reclaim ok"

python3 - "$INSTALL_SH" > "$TMP/port-functions.sh" <<'PY'
import sys

names = [
    "validate_port_value",
    "ensure_port_free",
    "reclaim_launchd_service",
    "reclaim_legacy_launchd_service",
]
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
for name in names:
    for index, line in enumerate(lines):
        if line != f"{name}() {{":
            continue
        depth = 0
        while index < len(lines):
            current = lines[index]
            print(current)
            depth += current.count("{") - current.count("}")
            index += 1
            if depth == 0:
                break
        break
    else:
        raise SystemExit(f"could not extract {name}")
PY
printf '%s\n' 'PROVIDER_LABEL="${PROVIDER_LABEL:-live.malibu.provider}"' >> "$TMP/port-functions.sh"
printf '%s\n' 'LEGACY_PROVIDER_LABEL="${LEGACY_PROVIDER_LABEL:-live.streamvc.macprovider}"' >> "$TMP/port-functions.sh"
printf '%s\n' 'LEGACY_PLIST_PATH="${LEGACY_PLIST_PATH:-$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist}"' >> "$TMP/port-functions.sh"

mkdir -p "$TMP/port-bin"
cat > "$TMP/port-bin/lsof" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"-d txt"*) printf 'p4242\nn%s/macprovider/macprovider-cli\n' "$HOME" ;;
  *-t*)
    if [ -f "$LSOF_T_SEEN" ]; then
      exit 0
    fi
    : > "$LSOF_T_SEEN"
    printf '4242\n'
    ;;
  *) printf "COMMAND PID\nmacprovider-cli 4242\n" ;;
esac
EOF
chmod 0755 "$TMP/port-bin/lsof"
: > "$TMP/legacy-upgrade.log"
rm -f "$TMP/lsof-t-seen"
HOME="$TMP/home" \
  FUNCTION_PATH="$TMP/port-functions.sh" \
  PATH="$TMP/port-bin:/usr/bin:/bin" \
  LEGACY_UPGRADE_LOG="$TMP/legacy-upgrade.log" \
  LSOF_T_SEEN="$TMP/lsof-t-seen" \
  bash -c '
    set -euo pipefail
    die() { printf "ERR:%s\n" "$*" >&2; exit "$1"; }
    log() { printf "LOG:%s\n" "$*" >&2; }
    assert_install_lock_ownership() { :; }
    capture_manual_provider_for_recovery() {
      printf "captured\n" >> "$LEGACY_UPGRADE_LOG"
      die 70 "manual capture should not run for a loaded legacy LaunchAgent"
    }
    DRY_RUN=0
    PORT=18080
    INSTALL_DIR="$HOME/macprovider"
    BINARY_PATH="$HOME/.local/bin/macprovider-cli"
    INSTALL_TX_SERVICE_WAS_ACTIVE=0
    INSTALL_TX_LEGACY_SERVICE_WAS_ACTIVE=1
    INSTALL_TX_ACTIVE=1
    source "$FUNCTION_PATH"
    reclaim_launchd_service() { printf "reclaim-current\n" >> "$LEGACY_UPGRADE_LOG"; }
    reclaim_legacy_launchd_service() { printf "reclaim-legacy\n" >> "$LEGACY_UPGRADE_LOG"; }
    ensure_port_free 1
  '
grep -Fx "reclaim-legacy" "$TMP/legacy-upgrade.log" >/dev/null
if grep -Fx "captured" "$TMP/legacy-upgrade.log" >/dev/null; then
  echo "legacy launchd upgrade captured a manual provider" >&2
  exit 1
fi
echo "legacy launchd upgrade skips manual capture ok"
