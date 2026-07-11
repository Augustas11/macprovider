#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHDOG="$WATCHDOG_DIR/watchdog.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-watchdog-ac19-20.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

HOME_DIR="$TMP_ROOT/home"
STATE_ROOT="$HOME_DIR/.local/share/macprovider/autoupdate"
BIN_DIR="$TMP_ROOT/bin"
LOG_DIR="$TMP_ROOT/logs"
WATCHDOG_STATE="$TMP_ROOT/watchdog-state"
FAKE_BIN="$TMP_ROOT/fake-bin"

mkdir -p "$STATE_ROOT" "$BIN_DIR" "$LOG_DIR" "$WATCHDOG_STATE" "$FAKE_BIN"
chmod 700 "$HOME_DIR" "$HOME_DIR/.local" "$HOME_DIR/.local/share" "$HOME_DIR/.local/share/macprovider" "$STATE_ROOT" "$BIN_DIR"

cat > "$FAKE_BIN/launchctl" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "print" ]; then
  case "${TEST_LAUNCHCTL_PRINT:-healthy}" in
    crash)
      printf 'pid = 123\nlast exit status = 7\n'
      ;;
    missing_pid)
      printf 'last exit status = 0\n'
      ;;
    *)
      printf 'pid = 123\nlast exit status = 0\n'
      ;;
  esac
fi
exit 0
SH
chmod 700 "$FAKE_BIN/launchctl"

cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
exit "${TEST_CURL_EXIT:-0}"
SH
chmod 700 "$FAKE_BIN/curl"

write_fixture() {
  local backup_body="$1"
  local target_body="$2"
  python3 - "$STATE_ROOT" "$BIN_DIR" "$backup_body" "$target_body" <<'PY'
import datetime
import hashlib
import json
import os
import sys

root, binary_dir, backup_body, target_body = sys.argv[1:5]
update_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
target = os.path.join(binary_dir, "macprovider-cli")
backup = os.path.join(binary_dir, f".macprovider-cli.rollback-{update_id}")
with open(target, "w", encoding="utf-8") as fh:
    fh.write(target_body)
with open(backup, "w", encoding="utf-8") as fh:
    fh.write(backup_body)
os.chmod(target, 0o700)
os.chmod(backup, 0o600)
deadline = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
marker = {
    "update_id": update_id,
    "target_version": "1.7.0",
    "target_path": target,
    "backup_path": backup,
    "size": len(backup_body.encode("utf-8")),
    "mode": 0o700,
    "sha256": hashlib.sha256(b"old-version\n").hexdigest(),
    "marker_deadline": deadline,
}
with open(os.path.join(root, "pending.json"), "w", encoding="utf-8") as fh:
    json.dump(marker, fh, sort_keys=True, separators=(",", ":"))
os.chmod(os.path.join(root, "pending.json"), 0o600)
with open(os.path.join(root, "update.lock"), "w", encoding="utf-8") as fh:
    fh.write("")
os.chmod(os.path.join(root, "update.lock"), 0o600)
PY
}

run_watchdog_tick() {
  HOME="$HOME_DIR" \
  PATH="$FAKE_BIN:$PATH" \
  MACPROVIDER_AUTOUPDATE_STATE_ROOT="$STATE_ROOT" \
  MACPROVIDER_BINARY_DIR="$BIN_DIR" \
  MACPROVIDER_CONFIG_PATH="$TMP_ROOT/missing-config.yaml" \
  MACPROVIDER_LOG_DIR="$LOG_DIR" \
  MACPROVIDER_WATCHDOG_STATE_DIR="$WATCHDOG_STATE" \
  bash "$WATCHDOG"
}

run_watchdog_tick_with_health() {
  HOME="$HOME_DIR" \
  PATH="$FAKE_BIN:$PATH" \
  MACPROVIDER_AUTOUPDATE_STATE_ROOT="$STATE_ROOT" \
  MACPROVIDER_BINARY_DIR="$BIN_DIR" \
  MACPROVIDER_CONFIG_PATH="$TMP_ROOT/missing-config.yaml" \
  MACPROVIDER_CURL="$FAKE_BIN/curl" \
  MACPROVIDER_HEALTHCHECK_URL="http://127.0.0.1:9/healthz" \
  MACPROVIDER_LOG_DIR="$LOG_DIR" \
  MACPROVIDER_WATCHDOG_STATE_DIR="$WATCHDOG_STATE" \
  bash "$WATCHDOG"
}

write_fixture $'old-version\n' $'new-version\n'
LOCK_INODE_BEFORE="$(ls -di "$STATE_ROOT/update.lock" | awk '{print $1}')"
run_watchdog_tick

TARGET="$BIN_DIR/macprovider-cli"
BACKUP="$BIN_DIR/.macprovider-cli.rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
if [ "$(cat "$TARGET")" != $'old-version' ]; then
  echo "AC-19 FAIL: valid backup was not restored" >&2
  exit 1
fi
if [ -e "$STATE_ROOT/pending.json" ] || [ -e "$BACKUP" ] || [ ! -e "$STATE_ROOT/update.lock" ]; then
  echo "AC-19 FAIL: restored marker/backup cleanup or stable lock retention failed" >&2
  exit 1
fi
if [ "$(ls -di "$STATE_ROOT/update.lock" | awk '{print $1}')" != "$LOCK_INODE_BEFORE" ]; then
  echo "AC-19 FAIL: recovery split the stable update.lock inode" >&2
  exit 1
fi

rm -f "$STATE_ROOT"/pending-quarantined-*.json
write_fixture $'corrupt-version\n' $'new-version\n'
run_watchdog_tick

if [ "$(cat "$TARGET")" != $'new-version' ]; then
  echo "AC-20 FAIL: corrupt backup changed live binary" >&2
  exit 1
fi
if [ -e "$STATE_ROOT/pending.json" ] || ! compgen -G "$STATE_ROOT/pending-quarantined-*.json" >/dev/null; then
  echo "AC-20 FAIL: corrupt marker was not quarantined" >&2
  exit 1
fi
if [ ! -e "$BACKUP" ]; then
  echo "AC-20 FAIL: corrupt backup should be left for forensics" >&2
  exit 1
fi
if ! grep -q '"failure_class":"rollback_backup_corrupt"' "$LOG_DIR/watchdog.log"; then
  echo "AC-20 FAIL: rollback_backup_corrupt event missing" >&2
  exit 1
fi

rm -f "$STATE_ROOT"/pending-quarantined-*.json "$LOG_DIR/watchdog.log"
write_fixture $'old-version\n' $'new-version\n'
TEST_LAUNCHCTL_PRINT=crash run_watchdog_tick
if ! grep -q '"failure_class":"post_start_crash"' "$LOG_DIR/watchdog.log"; then
  echo "AC-10 FAIL: post_start_crash event missing" >&2
  exit 1
fi

rm -f "$STATE_ROOT"/pending-quarantined-*.json "$LOG_DIR/watchdog.log"
write_fixture $'old-version\n' $'new-version\n'
TEST_CURL_EXIT=22 run_watchdog_tick_with_health
if ! grep -q '"failure_class":"post_start_health_failed"' "$LOG_DIR/watchdog.log"; then
  echo "AC-10 FAIL: post_start_health_failed event missing" >&2
  exit 1
fi

rm -f "$STATE_ROOT"/pending-quarantined-*.json "$LOG_DIR/watchdog.log"
write_fixture $'old-version\n' $'new-version\n'
cat > "$TARGET" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "macprovider-cli 1.6.0"
  exit 0
fi
exit 0
SH
chmod 700 "$TARGET"
run_watchdog_tick
if ! grep -q '"failure_class":"post_start_rejoin_timeout"' "$LOG_DIR/watchdog.log"; then
  echo "AC-10 FAIL: post_start_rejoin_timeout event missing" >&2
  exit 1
fi

echo "AC-10/19/20 watchdog recovery PASS"
