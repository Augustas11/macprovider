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
    printf 'gui/%s/live.malibu.provider = {\n  program = %s\n  path = %s\n}\n' \
      "$(id -u)" "$PRINTED_PROGRAM" "$PRINTED_PLIST_PATH"
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

echo "install_dangling_launchd_repair: OK"
