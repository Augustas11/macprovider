#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHDOG="$WATCHDOG_DIR/watchdog.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-watchdog-ac19-20.XXXXXX")"
LOCK_HOLDER_PID=""

cleanup() {
  if [ -n "$LOCK_HOLDER_PID" ]; then
    kill "$LOCK_HOLDER_PID" 2>/dev/null || true
    wait "$LOCK_HOLDER_PID" 2>/dev/null || true
  fi
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

cat > "$FAKE_BIN/ditto" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 4 ] || [ "$1" != "-x" ] || [ "$2" != "-k" ]; then
  exit 64
fi
python3 - "$3" "$4" <<'PY'
import sys
import zipfile

archive, destination = sys.argv[1:3]
with zipfile.ZipFile(archive, "r") as handle:
    handle.extractall(destination)
PY
SH
chmod 700 "$FAKE_BIN/ditto"

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

trust_fixture_backup_and_bind_compatibility_set() {
  python3 - "$STATE_ROOT" <<'PY'
import hashlib
import json
import os
import sys

root = sys.argv[1]
pending = os.path.join(root, "pending.json")
with open(pending, "r", encoding="utf-8") as handle:
    marker = json.load(handle)
with open(marker["backup_path"], "rb") as handle:
    backup = handle.read()
marker["size"] = len(backup)
marker["sha256"] = hashlib.sha256(backup).hexdigest()
marker["target_compatibility_set_id"] = "issue-585-test-set"
marker["target_compatibility_set_sha256"] = hashlib.sha256(b"issue-585-test-set").hexdigest()
with open(pending, "w", encoding="utf-8") as handle:
    json.dump(marker, handle, sort_keys=True, separators=(",", ":"))
os.chmod(pending, 0o600)
PY
}

add_compatibility_set_rollback_fixture() {
  python3 - "$STATE_ROOT" "$BIN_DIR" "$HOME_DIR" <<'PY'
import hashlib
import json
import os
import stat
import sys

root, binary_dir, home = sys.argv[1:4]
update_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
release_backup = os.path.join(binary_dir, f".macprovider-cli.release-rollback-{update_id}")
external_backup = os.path.join(release_backup, "external-local-members")
os.makedirs(os.path.join(release_backup, "compatibility-set-local"), mode=0o700)
os.makedirs(external_backup, mode=0o700)

live_local = os.path.join(binary_dir, "compatibility-set-local")
os.makedirs(live_local, mode=0o700, exist_ok=True)
with open(os.path.join(live_local, "install.sh"), "w", encoding="utf-8") as handle:
    handle.write("new-install-contract\n")
with open(os.path.join(release_backup, "compatibility-set-local", "install.sh"), "w", encoding="utf-8") as handle:
    handle.write("old-install-contract\n")

members = [
    (
        "launchd",
        os.path.join(home, "Library/LaunchAgents/live.streamvc.macprovider.plist"),
        "provider.plist",
        "old-provider-plist\n",
        "new-provider-plist\n",
        0o600,
    ),
    (
        "watchdog_script",
        os.path.join(home, ".local/share/macprovider-watchdog/macprovider-health-monitor"),
        "watchdog.sh",
        "old-watchdog-script\n",
        "new-watchdog-script\n",
        0o700,
    ),
    (
        "watchdog_plist",
        os.path.join(home, "Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"),
        "watchdog.plist",
        "old-watchdog-plist\n",
        "new-watchdog-plist\n",
        0o600,
    ),
]
state = {"schema_version": 1, "members": []}
for member, target, backup_name, old_body, new_body, mode in members:
    os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(new_body)
    os.chmod(target, mode)
    backup_path = os.path.join(external_backup, backup_name)
    with open(backup_path, "w", encoding="utf-8") as handle:
        handle.write(old_body)
    os.chmod(backup_path, mode)
    state["members"].append(
        {
            "member": member,
            "mode": mode,
            "sha256": hashlib.sha256(old_body.encode("utf-8")).hexdigest(),
            "was_present": True,
        }
    )
with open(os.path.join(external_backup, "state.json"), "w", encoding="utf-8") as handle:
    json.dump(state, handle, sort_keys=True, separators=(",", ":"))
os.chmod(os.path.join(external_backup, "state.json"), 0o600)

def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

records = []
for current, directory_names, file_names in os.walk(release_backup, topdown=True, followlinks=False):
    directory_names.sort()
    file_names.sort()
    for name in directory_names + file_names:
        path = os.path.join(current, name)
        info = os.lstat(path)
        relative = os.path.relpath(path, release_backup)
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISDIR(info.st_mode):
            record = f"d\0{relative}\0{mode}\0"
        elif stat.S_ISREG(info.st_mode):
            record = f"f\0{relative}\0{mode}\0{info.st_size}\0{file_sha256(path)}\0"
        else:
            raise RuntimeError(f"unexpected fixture entry: {path}")
        records.append((relative, record.encode("utf-8")))
digest = hashlib.sha256()
for _, record in sorted(records, key=lambda item: item[0]):
    digest.update(record)

pending = os.path.join(root, "pending.json")
with open(pending, "r", encoding="utf-8") as handle:
    marker = json.load(handle)
marker["release_backup_path"] = release_backup
marker["release_backup_sha256"] = digest.hexdigest()
with open(pending, "w", encoding="utf-8") as handle:
    json.dump(marker, handle, sort_keys=True, separators=(",", ":"))
os.chmod(pending, 0o600)
PY
}

add_malibu_rollback_fixture() {
  python3 - "$STATE_ROOT" "$HOME_DIR" <<'PY'
import hashlib
import json
import os
import plistlib
import shutil
import stat
import sys
import tempfile
import zipfile

root, home = sys.argv[1:3]
pending = os.path.join(root, "pending.json")
with open(pending, "r", encoding="utf-8") as handle:
    marker = json.load(handle)
release_backup = marker["release_backup_path"]
target = os.path.normpath(os.path.join(home, "Applications/Malibu.app"))
os.makedirs(os.path.join(target, "Contents", "MacOS"), mode=0o700, exist_ok=True)
with open(os.path.join(target, "Contents", "Info.plist"), "wb") as handle:
    plistlib.dump({"CFBundleIdentifier": "tech.malibu.app", "CFBundleShortVersionString": "1.7.0"}, handle)
with open(os.path.join(target, "Contents", "MacOS", "Malibu"), "w", encoding="utf-8") as handle:
    handle.write("new-app\n")
os.chmod(os.path.join(target, "Contents", "MacOS", "Malibu"), 0o700)

old_root = tempfile.mkdtemp(prefix="watchdog-old-malibu-")
try:
    old_app = os.path.join(old_root, "Malibu.app")
    os.makedirs(os.path.join(old_app, "Contents", "MacOS"), mode=0o700)
    with open(os.path.join(old_app, "Contents", "Info.plist"), "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "tech.malibu.app", "CFBundleShortVersionString": "1.6.0"}, handle)
    with open(os.path.join(old_app, "Contents", "MacOS", "Malibu"), "w", encoding="utf-8") as handle:
        handle.write("old-app\n")
    os.chmod(os.path.join(old_app, "Contents", "MacOS", "Malibu"), 0o700)
    archive = os.path.join(release_backup, "Malibu.app.zip")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as handle:
        for current, directory_names, file_names in os.walk(old_app):
            directory_names.sort()
            file_names.sort()
            for name in file_names:
                path = os.path.join(current, name)
                relative = os.path.relpath(path, old_root)
                handle.write(path, relative)
    os.chmod(archive, 0o600)
finally:
    shutil.rmtree(old_root)

def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

state = {
    "archive_sha256": file_sha256(os.path.join(release_backup, "Malibu.app.zip")),
    "schema_version": 1,
    "target_path": target,
}
with open(os.path.join(release_backup, "malibu-app-state.json"), "w", encoding="utf-8") as handle:
    json.dump(state, handle, sort_keys=True, separators=(",", ":"))
os.chmod(os.path.join(release_backup, "malibu-app-state.json"), 0o600)

records = []
for current, directory_names, file_names in os.walk(release_backup, topdown=True, followlinks=False):
    directory_names.sort()
    file_names.sort()
    for name in directory_names + file_names:
        path = os.path.join(current, name)
        info = os.lstat(path)
        relative = os.path.relpath(path, release_backup)
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISDIR(info.st_mode):
            record = f"d\0{relative}\0{mode}\0"
        elif stat.S_ISREG(info.st_mode):
            record = f"f\0{relative}\0{mode}\0{info.st_size}\0{file_sha256(path)}\0"
        else:
            raise RuntimeError(f"unexpected fixture entry: {path}")
        records.append((relative, record.encode("utf-8")))
digest = hashlib.sha256()
for _, record in sorted(records, key=lambda item: item[0]):
    digest.update(record)
marker["release_backup_sha256"] = digest.hexdigest()
with open(pending, "w", encoding="utf-8") as handle:
    json.dump(marker, handle, sort_keys=True, separators=(",", ":"))
os.chmod(pending, 0o600)
PY
}

bind_exact_rollback_transaction() {
  python3 - "$STATE_ROOT" <<'PY'
import json
import os
import sys

pending = os.path.join(sys.argv[1], "pending.json")
with open(pending, "r", encoding="utf-8") as handle:
    marker = json.load(handle)
marker.update({
    "previous_compatibility_set_id": "Augustas11/macprovider:v1.6.0@0123456789abcdef0123456789abcdef01234567",
    "previous_compatibility_set_sha256": "6" * 64,
    "previous_version": "1.6.0",
    "target_compatibility_set_id": "Augustas11/macprovider:v1.7.0@fedcba9876543210fedcba9876543210fedcba98",
    "target_compatibility_set_sha256": "7" * 64,
    "transaction_state": "activating_target",
})
with open(pending, "w", encoding="utf-8") as handle:
    json.dump(marker, handle, sort_keys=True, separators=(",", ":"))
os.chmod(pending, 0o600)
PY
}

run_watchdog_tick() {
  HOME="$HOME_DIR" \
  PATH="$FAKE_BIN:$PATH" \
  MACPROVIDER_AUTOUPDATE_STATE_ROOT="$STATE_ROOT" \
  MACPROVIDER_BINARY_PATH="$BIN_DIR/macprovider-cli" \
  MACPROVIDER_BINARY_DIR="$BIN_DIR" \
  MACPROVIDER_CONFIG_PATH="$TMP_ROOT/missing-config.yaml" \
  MACPROVIDER_DITTO="$FAKE_BIN/ditto" \
  MACPROVIDER_LOG_DIR="$LOG_DIR" \
  MACPROVIDER_WATCHDOG_STATE_DIR="$WATCHDOG_STATE" \
  TEST_LIFECYCLE_LEASE_KIND="${TEST_LIFECYCLE_LEASE_KIND:-}" \
  TEST_LIFECYCLE_LEASE_OWNER_PID="${TEST_LIFECYCLE_LEASE_OWNER_PID:-}" \
  bash "$WATCHDOG"
}

run_watchdog_tick_with_health() {
  HOME="$HOME_DIR" \
  PATH="$FAKE_BIN:$PATH" \
  MACPROVIDER_AUTOUPDATE_STATE_ROOT="$STATE_ROOT" \
  MACPROVIDER_BINARY_PATH="$BIN_DIR/macprovider-cli" \
  MACPROVIDER_BINARY_DIR="$BIN_DIR" \
  MACPROVIDER_CONFIG_PATH="$TMP_ROOT/missing-config.yaml" \
  MACPROVIDER_CURL="$FAKE_BIN/curl" \
  MACPROVIDER_DITTO="$FAKE_BIN/ditto" \
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

rm -f "$LOG_DIR/watchdog.log"
write_fixture $'old-version\n' $'new-version\n'
add_compatibility_set_rollback_fixture
add_malibu_rollback_fixture
run_watchdog_tick
if [ "$(cat "$BIN_DIR/compatibility-set-local/install.sh")" != $'old-install-contract' ]; then
  echo "AC-19 FAIL: compatibility-set local resources were not restored" >&2
  cat "$LOG_DIR/watchdog.log" >&2
  exit 1
fi
if [ "$(cat "$HOME_DIR/Library/LaunchAgents/live.streamvc.macprovider.plist")" != $'old-provider-plist' ] || \
   [ "$(cat "$HOME_DIR/.local/share/macprovider-watchdog/macprovider-health-monitor")" != $'old-watchdog-script' ] || \
   [ "$(cat "$HOME_DIR/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist")" != $'old-watchdog-plist' ]; then
  echo "AC-19 FAIL: external compatibility-set members were not restored" >&2
  exit 1
fi
if [ "$(cat "$HOME_DIR/Applications/Malibu.app/Contents/MacOS/Malibu")" != $'new-app' ]; then
  echo "AC-19 FAIL: provider rollback mutated independently managed Malibu.app" >&2
  exit 1
fi
if [ -e "$STATE_ROOT/pending.json" ] || [ -e "$BACKUP" ] || \
   [ -e "$BIN_DIR/.macprovider-cli.release-rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" ]; then
  echo "AC-19 FAIL: compatibility-set rollback artifacts were not cleaned up" >&2
  exit 1
fi
grep -q '"reason":"restored_prior_release"' "$LOG_DIR/watchdog.log"

rm -f "$LOG_DIR/watchdog.log"
EXACT_ROLLBACK_BACKUP='#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf "macprovider-cli 1.6.0\n"
  exit 0
fi
if [ "${1:-}" = "lifecycle-state" ] && [ "${2:-}" = "transition" ]; then
  exit 0
fi
exit 1
'
write_fixture "$EXACT_ROLLBACK_BACKUP" $'new-version\n'
trust_fixture_backup_and_bind_compatibility_set
add_compatibility_set_rollback_fixture
bind_exact_rollback_transaction
run_watchdog_tick
if [ ! -e "$STATE_ROOT/pending.json" ] || [ ! -e "$BACKUP" ] || \
   [ ! -e "$BIN_DIR/.macprovider-cli.release-rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" ]; then
  echo "AC-19 FAIL: exact-set rollback discarded snapshots before prior-set readiness" >&2
  exit 1
fi
python3 - "$STATE_ROOT/pending.json" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    marker = json.load(handle)
assert marker["transaction_state"] == "awaiting_previous_readiness"
assert marker["previous_version"] == "1.6.0"
PY
grep -q 'restored_prior_release_awaiting_buyer_serving' "$LOG_DIR/watchdog.log"
run_watchdog_tick
grep -q 'pending_marker_still_inside_post_start_window' "$LOG_DIR/watchdog.log"
rm -f "$STATE_ROOT/pending.json" "$BACKUP"
rm -rf "$BIN_DIR/.macprovider-cli.release-rollback-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

rm -f "$LOG_DIR/watchdog.log"
TEST_LIFECYCLE_TRANSITION_LOG="$TMP_ROOT/lifecycle-transition.log"
export TEST_LIFECYCLE_TRANSITION_LOG
RECOVERY_AWARE_BACKUP='#!/usr/bin/env bash
if [ "${1:-}" = "lifecycle-state" ] && [ "${2:-}" = "transition" ]; then
  printf "%s\n" "$*" > "$TEST_LIFECYCLE_TRANSITION_LOG"
  exit 0
fi
exit 1
'
write_fixture "$RECOVERY_AWARE_BACKUP" $'new-version\n'
trust_fixture_backup_and_bind_compatibility_set
run_watchdog_tick
grep -q -- '--state watchdog_recovery' "$TEST_LIFECYCLE_TRANSITION_LOG"
grep -q -- '--reason-code watchdog_rollback_post_start_rejoin_timeout' "$TEST_LIFECYCLE_TRANSITION_LOG"
grep -q -- '--writer watchdog' "$TEST_LIFECYCLE_TRANSITION_LOG"
grep -q -- '--operation-id watchdog-recovery:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' "$TEST_LIFECYCLE_TRANSITION_LOG"
grep -q -- '--compatibility-set-id issue-585-test-set' "$TEST_LIFECYCLE_TRANSITION_LOG"
grep -q 'lifecycle_transition=watchdog_recovery' "$LOG_DIR/watchdog.log"
unset TEST_LIFECYCLE_TRANSITION_LOG

rm -f "$LOG_DIR/watchdog.log"
write_fixture $'old-version\n' $'new-version\n'
LIFECYCLE_LOCK="$HOME_DIR/Library/Application Support/macprovider/lifecycle/.lease.json.lock"
LOCK_READY="$TMP_ROOT/lifecycle-lock-ready"
python3 - "$LIFECYCLE_LOCK" "$LOCK_READY" <<'PY' &
import fcntl
import os
import sys
import time

lock_path, ready_path = sys.argv[1:3]
descriptor = os.open(lock_path, os.O_RDWR)
fcntl.flock(descriptor, fcntl.LOCK_EX)
with open(ready_path, "w", encoding="ascii") as handle:
    handle.write("ready\n")
time.sleep(30)
PY
LOCK_HOLDER_PID=$!
for _ in $(seq 1 100); do
  [ -e "$LOCK_READY" ] && break
  sleep 0.01
done
[ -e "$LOCK_READY" ] || { echo "lifecycle arbitration FAIL: lock holder did not start" >&2; exit 1; }
run_watchdog_tick
kill "$LOCK_HOLDER_PID"
wait "$LOCK_HOLDER_PID" 2>/dev/null || true
LOCK_HOLDER_PID=""
if ! grep -q 'new-version' "$TARGET" || [ ! -e "$STATE_ROOT/pending.json" ] || [ ! -e "$BACKUP" ]; then
  echo "lifecycle arbitration FAIL: contended lifecycle lock did not fence recovery" >&2
  exit 1
fi
grep -q 'recovery_deferred=lifecycle_lease_lock_contended' "$LOG_DIR/watchdog.log"
run_watchdog_tick
if [ "$(cat "$TARGET")" != $'old-version' ] || [ -e "$STATE_ROOT/pending.json" ] || [ -e "$BACKUP" ]; then
  echo "lifecycle arbitration FAIL: rollback did not resume after lifecycle lock release" >&2
  exit 1
fi

LEASE_AWARE_TARGET=$'#!/usr/bin/env bash\n# lease-aware-new-version\nif [ "$*" = "lifecycle-lease status" ] && [ -n "${TEST_LIFECYCLE_LEASE_KIND:-}" ]; then\n  printf "{\\"kind\\":\\"%s\\",\\"owner_pid\\":%s,\\"state\\":\\"valid\\"}\\n" "$TEST_LIFECYCLE_LEASE_KIND" "$TEST_LIFECYCLE_LEASE_OWNER_PID"\n  exit 0\nfi\nexit 1\n'

rm -f "$LOG_DIR/watchdog.log"
write_fixture $'old-version\n' "$LEASE_AWARE_TARGET"
TEST_LIFECYCLE_LEASE_KIND=maintenance
TEST_LIFECYCLE_LEASE_OWNER_PID=123
export TEST_LIFECYCLE_LEASE_KIND TEST_LIFECYCLE_LEASE_OWNER_PID
run_watchdog_tick
if ! grep -q 'lease-aware-new-version' "$TARGET" || [ ! -e "$STATE_ROOT/pending.json" ] || [ ! -e "$BACKUP" ]; then
  echo "lifecycle arbitration FAIL: maintenance lease did not preserve the pending transaction" >&2
  cat "$LOG_DIR/watchdog.log" >&2
  exit 1
fi
grep -q 'recovery_deferred=validated_maintenance_lease owner_pid=123' "$LOG_DIR/watchdog.log"

TEST_LIFECYCLE_LEASE_KIND=
TEST_LIFECYCLE_LEASE_OWNER_PID=
export TEST_LIFECYCLE_LEASE_KIND TEST_LIFECYCLE_LEASE_OWNER_PID
run_watchdog_tick
if [ "$(cat "$TARGET")" != $'old-version' ] || [ -e "$STATE_ROOT/pending.json" ] || [ -e "$BACKUP" ]; then
  echo "lifecycle arbitration FAIL: rollback did not resume after maintenance lease release" >&2
  exit 1
fi

rm -f "$LOG_DIR/watchdog.log"
write_fixture $'old-version\n' "$LEASE_AWARE_TARGET"
TEST_LIFECYCLE_LEASE_KIND=startup
TEST_LIFECYCLE_LEASE_OWNER_PID=777
export TEST_LIFECYCLE_LEASE_KIND TEST_LIFECYCLE_LEASE_OWNER_PID
run_watchdog_tick
if ! grep -q 'lease-aware-new-version' "$TARGET" || [ ! -e "$STATE_ROOT/pending.json" ] || [ ! -e "$BACKUP" ]; then
  echo "lifecycle arbitration FAIL: unrelated startup lease did not preserve the pending transaction" >&2
  exit 1
fi
grep -q 'recovery_deferred=validated_unrelated_startup_lease owner_pid=777' "$LOG_DIR/watchdog.log"

rm -f "$LOG_DIR/watchdog.log"
write_fixture $'old-version\n' "$LEASE_AWARE_TARGET"
TEST_LIFECYCLE_LEASE_OWNER_PID=123
export TEST_LIFECYCLE_LEASE_OWNER_PID
run_watchdog_tick
if [ "$(cat "$TARGET")" != $'old-version' ] || [ -e "$STATE_ROOT/pending.json" ] || [ -e "$BACKUP" ]; then
  echo "lifecycle arbitration FAIL: failed autoupdate startup lease defeated rollback" >&2
  exit 1
fi
grep -q 'recovery_continuing=expired_autoupdate_startup owner_pid=123' "$LOG_DIR/watchdog.log"

TEST_LIFECYCLE_LEASE_KIND=
TEST_LIFECYCLE_LEASE_OWNER_PID=
export TEST_LIFECYCLE_LEASE_KIND TEST_LIFECYCLE_LEASE_OWNER_PID

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
