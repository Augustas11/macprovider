#!/usr/bin/env bash
# Issue #1616 finding E — reinstall must self-repair a launchd registration
# whose plist file is gone (a prior uninstall that unregistered nothing, or a
# hand-edited install). Before this, begin_install_transaction found a loaded
# service with no plist to snapshot and died 70, so reinstall was blocked until
# an operator ran `launchctl bootout` by hand.
#
# The repair must be narrow: it may only release a registration that proves it
# is ours, and must leave anything ambiguous or foreign loaded so the existing
# fail-closed transaction guard still refuses the install.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" > "$TMP/functions.sh" <<'PY'
import sys

names = [
    "launchctl_service",
    "release_dangling_launchd_registration",
]
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
for name in names:
    matches = [index for index, line in enumerate(lines) if line == f"{name}() {{"]
    if not matches:
        raise SystemExit(f"could not extract {name}")
    index = matches[-1]
    depth = 0
    while index < len(lines):
        current = lines[index]
        print(current)
        depth += current.count("{") - current.count("}")
        index += 1
        if depth == 0:
            break
PY

mkdir -p "$TMP/bin"
cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  print)
    if [ ! -f "$LAUNCHD_STATE" ]; then
      exit 1
    fi
    printf 'gui/%s/%s = {\n  program = %s\n  path = %s\n}\n' \
      "$(id -u)" "${2##*/}" "$PRINTED_PROGRAM" "$PRINTED_PLIST_PATH"
    ;;
  bootout)
    printf '%s\n' "$*" >> "$LAUNCHD_LOG"
    if [ "${BOOTOUT_FAIL:-0}" -eq 1 ]; then
      exit 1
    fi
    rm -f "$LAUNCHD_STATE"
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod 0755 "$TMP/bin/launchctl"

cat > "$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-n" ]; then
  shift
fi
exec "$@"
EOF
chmod 0755 "$TMP/bin/sudo"

PLIST_PATH="$TMP/home/Library/LaunchAgents/live.malibu.provider.plist"
INSTALL_DIR="$TMP/home/macprovider"
BINARY_PATH="$TMP/home/.local/bin/macprovider-cli"
mkdir -p "$(dirname "$PLIST_PATH")"

# `program` / `path` the stubbed launchctl reports for the loaded job.
run_release() {
  LAUNCHD_LOG="$TMP/launchd.log"
  FUNCTION_PATH="$TMP/functions.sh" \
    PATH="$TMP/bin:$PATH" \
    SUDO_BIN="$TMP/bin/sudo" \
    LAUNCHCTL_BIN="$TMP/bin/launchctl" \
    LAUNCHD_DOMAIN="gui/$UID" \
    HEADLESS=0 \
    HEADLESS_USER="" \
    LAUNCHD_STATE="$TMP/launchd-state" \
    LAUNCHD_LOG="$LAUNCHD_LOG" \
    PRINTED_PROGRAM="${PRINTED_PROGRAM:-$INSTALL_DIR/macprovider-cli}" \
    PRINTED_PLIST_PATH="${PRINTED_PLIST_PATH:-$PLIST_PATH}" \
    BOOTOUT_FAIL="${BOOTOUT_FAIL:-0}" \
    PLIST_PATH="$PLIST_PATH" \
    INSTALL_DIR="$INSTALL_DIR" \
    BINARY_PATH="$BINARY_PATH" \
    bash -c '
      set -euo pipefail
      log() { printf "%s\n" "$*" >> "$LAUNCHD_LOG.log"; }
      run() { "$@"; }
      source "$FUNCTION_PATH"
      release_dangling_launchd_registration \
        "live.malibu.provider" "$PLIST_PATH" "$PLIST_PATH" \
        "$INSTALL_DIR/macprovider-cli" "$BINARY_PATH" ""
    '
}

reset_state() {
  rm -f "$TMP/launchd.log" "$TMP/launchd.log.log" "$TMP/launchd-state"
  rm -f "$PLIST_PATH"
}

# 1. Dangling: service loaded, plist file gone, identity matches -> released.
reset_state
touch "$TMP/launchd-state"
run_release
grep -Fx "bootout gui/$(id -u)/live.malibu.provider" "$TMP/launchd.log" >/dev/null \
  || { echo "FAIL: dangling registration was not booted out" >&2; exit 1; }
[ ! -f "$TMP/launchd-state" ] || { echo "FAIL: service still loaded" >&2; exit 1; }

# 2. Plist present on disk -> not dangling; the normal snapshot/reclaim path
#    owns this label and must not be pre-empted.
reset_state
touch "$TMP/launchd-state"
: > "$PLIST_PATH"
run_release
[ ! -s "$TMP/launchd.log" ] || { echo "FAIL: booted out a recoverable service" >&2; exit 1; }
[ -f "$TMP/launchd-state" ] || { echo "FAIL: recoverable service was unloaded" >&2; exit 1; }

# 3. Not loaded at all -> no-op.
reset_state
run_release
[ ! -s "$TMP/launchd.log" ] || { echo "FAIL: acted on an absent service" >&2; exit 1; }

# 4. Foreign executable under our label -> refuse to touch it. The existing
#    fail-closed transaction guard must still see it loaded.
reset_state
touch "$TMP/launchd-state"
PRINTED_PROGRAM="/opt/somebody-else/bin/other" run_release
[ ! -s "$TMP/launchd.log" ] || { echo "FAIL: booted out a foreign executable" >&2; exit 1; }
[ -f "$TMP/launchd-state" ] || { echo "FAIL: foreign service was unloaded" >&2; exit 1; }

# 5. Unexpected plist identity reported by launchd -> refuse.
reset_state
touch "$TMP/launchd-state"
PRINTED_PLIST_PATH="/Library/LaunchDaemons/somebody.else.plist" run_release
[ ! -s "$TMP/launchd.log" ] || { echo "FAIL: booted out an unexpected plist identity" >&2; exit 1; }
[ -f "$TMP/launchd-state" ] || { echo "FAIL: unexpected identity was unloaded" >&2; exit 1; }

# 6. Bootout fails -> repair reports success (it is best-effort) but leaves the
#    service loaded so the transaction guard still fails closed.
reset_state
touch "$TMP/launchd-state"
BOOTOUT_FAIL=1 run_release
[ -f "$TMP/launchd-state" ] || { echo "FAIL: service vanished despite bootout failure" >&2; exit 1; }

# 7. Watchdog tuple — the repair must accept every executable the transaction
#    snapshot/reclaim paths accept for the watchdog labels, including
#    $WATCHDOG_PATH. Omitting it left a headless dangling watchdog unrepaired.
WATCHDOG_PLIST_PATH="$TMP/home/Library/LaunchAgents/live.malibu.provider-watchdog.plist"
WATCHDOG_DIR="$TMP/home/.local/share/macprovider-watchdog"
WATCHDOG_PATH="$WATCHDOG_DIR/macprovider-health-monitor"
WATCHDOG_BOOTSTRAP_PATH="/Library/Application Support/macprovider/macprovider-health-monitor"

run_release_watchdog() {
  LAUNCHD_LOG="$TMP/launchd.log"
  FUNCTION_PATH="$TMP/functions.sh" \
    PATH="$TMP/bin:$PATH" \
    SUDO_BIN="$TMP/bin/sudo" \
    LAUNCHCTL_BIN="$TMP/bin/launchctl" \
    LAUNCHD_DOMAIN="gui/$UID" \
    HEADLESS=0 \
    HEADLESS_USER="" \
    LAUNCHD_STATE="$TMP/launchd-state" \
    LAUNCHD_LOG="$LAUNCHD_LOG" \
    PRINTED_PROGRAM="${PRINTED_PROGRAM:-$WATCHDOG_BOOTSTRAP_PATH}" \
    PRINTED_PLIST_PATH="${PRINTED_PLIST_PATH:-$WATCHDOG_PLIST_PATH}" \
    BOOTOUT_FAIL=0 \
    WATCHDOG_PLIST_PATH="$WATCHDOG_PLIST_PATH" \
    WATCHDOG_DIR="$WATCHDOG_DIR" \
    WATCHDOG_PATH="$WATCHDOG_PATH" \
    WATCHDOG_BOOTSTRAP_PATH="$WATCHDOG_BOOTSTRAP_PATH" \
    bash -c '
      set -euo pipefail
      log() { printf "%s\n" "$*" >> "$LAUNCHD_LOG.log"; }
      run() { "$@"; }
      source "$FUNCTION_PATH"
      release_dangling_launchd_registration \
        "live.malibu.provider-watchdog" "$WATCHDOG_PLIST_PATH" "$WATCHDOG_PLIST_PATH" \
        "$WATCHDOG_BOOTSTRAP_PATH" "$WATCHDOG_DIR/watchdog.sh" "$WATCHDOG_PATH"
    '
}

for watchdog_program in \
  "$WATCHDOG_BOOTSTRAP_PATH" \
  "$WATCHDOG_DIR/watchdog.sh" \
  "$WATCHDOG_PATH"; do
  reset_state
  touch "$TMP/launchd-state"
  PRINTED_PROGRAM="$watchdog_program" run_release_watchdog
  grep -Fx "bootout gui/$(id -u)/live.malibu.provider-watchdog" "$TMP/launchd.log" >/dev/null \
    || { echo "FAIL: dangling watchdog on $watchdog_program was not repaired" >&2; exit 1; }
done

# A foreign watchdog executable is still refused.
reset_state
touch "$TMP/launchd-state"
PRINTED_PROGRAM="/opt/other/health-monitor" run_release_watchdog
[ ! -s "$TMP/launchd.log" ] || { echo "FAIL: booted out a foreign watchdog" >&2; exit 1; }
[ -f "$TMP/launchd-state" ] || { echo "FAIL: foreign watchdog was unloaded" >&2; exit 1; }

# 8. Call-site tuple. The cases above drive the helper directly, so they pass
#    whatever tuple they are handed — they cannot catch the real defect, which
#    was `begin_install_transaction` passing an INCOMPLETE tuple. Assert on the
#    call sites themselves: both watchdog labels must offer $WATCHDOG_PATH as
#    the third accepted executable, matching what the transaction snapshot and
#    reclaim paths accept.
watchdog_call_sites="$(
  awk '/^  release_dangling_launchd_registration \\$/ { collecting = 1; block = ""; }
       collecting { block = block $0 "\n" }
       collecting && !/\\$/ {
         collecting = 0
         if (block ~ /WATCHDOG_LABEL/) { printf "%s", block }
       }' "$INSTALL_SH"
)"
watchdog_call_site_count="$(printf '%s' "$watchdog_call_sites" | grep -c 'release_dangling_launchd_registration' || true)"
[ "$watchdog_call_site_count" -eq 2 ] || {
  echo "FAIL: expected 2 watchdog dangling-repair call sites, found $watchdog_call_site_count" >&2
  exit 1
}
printf '%s' "$watchdog_call_sites" | grep -c '"\$WATCHDOG_PATH"$' >/dev/null || {
  echo "FAIL: watchdog dangling-repair call sites do not accept \$WATCHDOG_PATH" >&2
  exit 1
}
[ "$(printf '%s' "$watchdog_call_sites" | grep -c '"\$WATCHDOG_PATH"$')" -eq 2 ] || {
  echo "FAIL: both watchdog call sites must accept \$WATCHDOG_PATH" >&2
  exit 1
}

echo "install_dangling_launchd_repair: OK"
