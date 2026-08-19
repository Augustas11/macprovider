#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STANDALONE="$REPO_ROOT/ops/macprovider-watchdog/watchdog.sh"
INSTALLER="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_inline_watchdog() {
  awk '
    /write_atomic_install_file "\$WATCHDOG_PATH" 0755 <<.WATCHDOG_EOF./ { inside=1; next }
    inside && /^WATCHDOG_EOF$/ { exit }
    inside { print }
  ' "$INSTALLER"
}

INLINE="$TMP/watchdog-inline.sh"
extract_inline_watchdog > "$INLINE"
[ -s "$INLINE" ] || { echo "failed to extract installer watchdog" >&2; exit 1; }
chmod +x "$INLINE"

make_fixture() {
  root="$1"
  mkdir -p "$root/home/.local/share/macprovider/autoupdate" "$root/bin" "$root/logs"
  printf "new-binary" > "$root/bin/macprovider-cli"
  printf "old-binary" > "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000"
  chmod 755 "$root/bin/macprovider-cli" "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000"
  hash="$(shasum -a 256 "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000" | awk '{print $1}')"
  cat > "$root/home/.local/share/macprovider/autoupdate/pending.json" <<EOF
{"update_id":"123e4567-e89b-42d3-a456-426614174000","target_version":"1.8.10","target_path":"$root/bin/macprovider-cli","backup_path":"$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000","size":10,"mode":493,"sha256":"$hash","marker_deadline":"2000-01-01T00:00:00Z"}
EOF
  : > "$root/home/.local/share/macprovider/autoupdate/update.lock"
  chmod 600 "$root/home/.local/share/macprovider/autoupdate/update.lock"
  : > "$root/launchctl.log"
  cat > "$root/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MACPROVIDER_FAKE_LAUNCHCTL_LOG"
if [ "${MACPROVIDER_FAKE_LAUNCHCTL_HANG:-}" = "${1:-}" ]; then
  exec /bin/sleep 30
fi
if [ "${MACPROVIDER_FAKE_LAUNCHCTL_FAIL:-}" = "${1:-}" ]; then
  exit "${MACPROVIDER_FAKE_LAUNCHCTL_FAIL_STATUS:-42}"
fi
state_dir="$(dirname "$MACPROVIDER_FAKE_LAUNCHCTL_LOG")/launchctl-state"
mkdir -p "$state_dir"
stable_helper="live.malibu.provider-compatibility-reload"
legacy_helper="$stable_helper.123e4567-e89b-42d3-a456-426614174001"

case "${1:-}" in
  list)
    printf -- '-\t0\t%s\n' "$stable_helper"
    printf -- '-\t0\t%s\n' "$legacy_helper"
    ;;
  bootout)
    target="${2:-}"
    label="${target##*/}"
    case "$label" in
      "$stable_helper"|"$legacy_helper")
        : > "$state_dir/booted-out-$label"
        ;;
    esac
    ;;
  print)
    target="${2:-}"
    label="${target##*/}"
    case "$label" in
      "$stable_helper"|"$legacy_helper")
        if [ -e "$state_dir/booted-out-$label" ]; then
          printf 'Could not find service "%s" in domain for user\n' "$label"
          exit 113
        fi
        printf 'pid = 456\nlast exit status = 0\n'
        ;;
      *)
        if [ "${MACPROVIDER_FAKE_PROVIDER_PRESENT:-1}" != "1" ]; then
          printf 'Could not find service "%s" in domain for user\n' "$label"
          exit 113
        fi
        printf 'pid = 123\nlast exit status = 0\n'
        ;;
    esac
    ;;
esac
EOF
  chmod +x "$root/bin/launchctl"
}

add_full_release_fixture() {
  root="$1"
  python3 - "$root" <<'PY'
import hashlib
import json
import os
import stat
import sys

root = sys.argv[1]
binary_dir = os.path.join(root, "bin")
pending = os.path.join(root, "home/.local/share/macprovider/autoupdate/pending.json")
update_id = "123e4567-e89b-42d3-a456-426614174000"
release_backup = os.path.join(binary_dir, f".macprovider-cli.release-rollback-{update_id}")

def write(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    os.chmod(path, 0o644)

for relative, body in {
    "mlx.metallib": "old-metal",
    "THIRD-PARTY-NOTICES.txt": "old-notices",
    "Runtime.bundle/resource": "old-bundle",
    "catalog-release/release.json": "old-catalog",
}.items():
    write(os.path.join(release_backup, relative), body)
for current, directories, _ in os.walk(release_backup):
    os.chmod(current, 0o700 if current == release_backup else 0o755)

for relative, body in {
    "mlx.metallib": "new-metal",
    "THIRD-PARTY-NOTICES.txt": "new-notices",
    "Runtime.bundle/resource": "new-bundle",
    "NewOnly.bundle/resource": "new-only",
    "catalog-release/release.json": "new-catalog",
}.items():
    write(os.path.join(binary_dir, relative), body)

def file_sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

records = []
for current, directories, files in os.walk(release_backup):
    directories.sort()
    files.sort()
    for name in directories + files:
        path = os.path.join(current, name)
        item = os.lstat(path)
        relative = os.path.relpath(path, release_backup)
        mode = stat.S_IMODE(item.st_mode)
        if stat.S_ISDIR(item.st_mode):
            record = f"d\0{relative}\0{mode}\0"
        else:
            record = f"f\0{relative}\0{mode}\0{item.st_size}\0{file_sha(path)}\0"
        records.append((relative, record.encode()))
digest = hashlib.sha256()
for _, record in sorted(records):
    digest.update(record)

with open(pending, encoding="utf-8") as handle:
    marker = json.load(handle)
marker["release_backup_path"] = release_backup
marker["release_backup_sha256"] = digest.hexdigest()
with open(pending, "w", encoding="utf-8") as handle:
    json.dump(marker, handle, sort_keys=True, separators=(",", ":"))
PY
}

run_reconcile() {
  script="$1"
  root="$2"
  lock_inode_before="$(ls -di "$root/home/.local/share/macprovider/autoupdate/update.lock" | awk '{print $1}')"
  invoke_reconcile "$script" "$root"
  cmp -s "$root/bin/macprovider-cli" <(printf "old-binary")
  [ ! -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
  [ -e "$root/home/.local/share/macprovider/autoupdate/update.lock" ]
  [ "$(ls -di "$root/home/.local/share/macprovider/autoupdate/update.lock" | awk '{print $1}')" = "$lock_inode_before" ]
  grep -Fx "list" "$root/launchctl.log" >/dev/null
  grep -F "bootout gui/" "$root/launchctl.log" \
    | grep -F "live.malibu.provider-compatibility-reload" >/dev/null
  grep -F "bootout gui/" "$root/launchctl.log" \
    | grep -F "live.malibu.provider-compatibility-reload.123e4567-e89b-42d3-a456-426614174001" >/dev/null
  grep -F "print gui/" "$root/launchctl.log" \
    | grep -F "live.malibu.provider-compatibility-reload" >/dev/null
  grep -F "print gui/" "$root/launchctl.log" \
    | grep -F "live.malibu.provider-compatibility-reload.123e4567-e89b-42d3-a456-426614174001" >/dev/null
  grep -F "bootstrap gui/" "$root/launchctl.log" >/dev/null
  grep -F "kickstart -k gui/" "$root/launchctl.log" >/dev/null
}

invoke_reconcile() {
  script="$1"
  root="$2"
  HOME="$root/home" \
  MACPROVIDER_BINARY_PATH="$root/bin/macprovider-cli" \
  MACPROVIDER_LOG_DIR="$root/logs" \
  MACPROVIDER_FAKE_LAUNCHCTL_LOG="$root/launchctl.log" \
  MACPROVIDER_FAKE_LAUNCHCTL_HANG="${MACPROVIDER_FAKE_LAUNCHCTL_HANG:-}" \
  MACPROVIDER_FAKE_LAUNCHCTL_FAIL="${MACPROVIDER_FAKE_LAUNCHCTL_FAIL:-}" \
  MACPROVIDER_FAKE_LAUNCHCTL_FAIL_STATUS="${MACPROVIDER_FAKE_LAUNCHCTL_FAIL_STATUS:-42}" \
  MACPROVIDER_FAKE_PROVIDER_PRESENT="${MACPROVIDER_FAKE_PROVIDER_PRESENT:-1}" \
  PATH="$root/bin:$PATH" \
  bash "$script" --reconcile-autoupdate
}

seed_killed_helper_owner() {
  root="$1"
  ready="$root/helper-ready"
  mkdir -p "$root/home/.config/macprovider"
  chmod 700 "$root/home/.config" "$root/home/.config/macprovider"
  python3 - \
    "$root/home/.config/macprovider/install.lock" \
    "$root/home/.local/share/macprovider/autoupdate/update.lock" \
    "$$" \
    "$ready" <<'PY' &
import fcntl
import json
import os
import subprocess
import sys
import time

outer_path, inner_path, owner_pid_text, ready_path = sys.argv[1:]
owner_pid = int(owner_pid_text)

def process_start(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""

def boot_session():
    try:
        result = subprocess.run(
            ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.stdout.strip():
            return result.stdout.strip()
    except FileNotFoundError:
        pass
    with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as handle:
        return handle.read().strip()

outer = os.open(outer_path, os.O_CREAT | os.O_RDWR, 0o600)
inner = os.open(inner_path, os.O_RDWR)
os.fchmod(outer, 0o600)
os.fchmod(inner, 0o600)
fcntl.flock(outer, fcntl.LOCK_EX)
fcntl.flock(inner, fcntl.LOCK_EX)
record = {
    "pid": owner_pid,
    "process_start": process_start(owner_pid),
    "boot_session": boot_session(),
    "token": "test-token",
    "holder_pid": os.getpid(),
    "holder_process_start": process_start(os.getpid()),
}
payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode()
os.ftruncate(outer, 0)
os.write(outer, payload)
os.fsync(outer)
with open(ready_path, "w", encoding="ascii") as handle:
    handle.write("ready\n")
while True:
    time.sleep(1)
PY
  helper_pid=$!
  for _ in $(seq 1 100); do
    [ -s "$ready" ] && break
    kill -0 "$helper_pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -s "$ready" ] || { echo "lock helper did not become ready" >&2; return 1; }
  kill -KILL "$helper_pid"
  wait "$helper_pid" 2>/dev/null || true
}

assert_live_owner_fences_recovery() {
  script="$1"
  root="$2"
  seed_killed_helper_owner "$root"
  invoke_reconcile "$script" "$root"
  cmp -s "$root/bin/macprovider-cli" <(printf "new-binary")
  [ -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
}

assert_unsafe_lock_rejected() {
  script="$1"
  root="$2"
  kind="$3"
  case "$kind" in
    hardlink)
      rm -f "$root/home/.local/share/macprovider/autoupdate/update.lock"
      : > "$root/home/.local/share/macprovider/autoupdate/lock-source"
      chmod 600 "$root/home/.local/share/macprovider/autoupdate/lock-source"
      ln "$root/home/.local/share/macprovider/autoupdate/lock-source" \
        "$root/home/.local/share/macprovider/autoupdate/update.lock"
      ;;
    fifo)
      rm -f "$root/home/.local/share/macprovider/autoupdate/update.lock"
      mkfifo "$root/home/.local/share/macprovider/autoupdate/update.lock"
      chmod 600 "$root/home/.local/share/macprovider/autoupdate/update.lock"
      ;;
    inner-readable)
      chmod 644 "$root/home/.local/share/macprovider/autoupdate/update.lock"
      ;;
    outer-readable)
      mkdir -p "$root/home/.config/macprovider"
      chmod 700 "$root/home/.config" "$root/home/.config/macprovider"
      : > "$root/home/.config/macprovider/install.lock"
      chmod 644 "$root/home/.config/macprovider/install.lock"
      ;;
    *) return 2 ;;
  esac
  invoke_reconcile "$script" "$root"
  cmp -s "$root/bin/macprovider-cli" <(printf "new-binary")
  [ -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
  grep -F "recovery_error=mutation_lock_invalid:" "$root/logs/watchdog.log" >/dev/null
}

assert_restart_timeout_retains_recovery() {
  script="$1"
  root="$2"
  started="$SECONDS"
  MACPROVIDER_FAKE_LAUNCHCTL_HANG=bootstrap invoke_reconcile "$script" "$root"
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt 10 ]
  cmp -s "$root/bin/macprovider-cli" <(printf "old-binary")
  [ -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
  [ -e "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000" ]
  grep -F "restored_release_restart_deferred" "$root/logs/watchdog.log" >/dev/null
}

assert_restart_failure_retains_recovery() {
  script="$1"
  root="$2"
  operation="$3"
  provider_present="${4:-1}"
  MACPROVIDER_FAKE_LAUNCHCTL_FAIL="$operation" \
    MACPROVIDER_FAKE_PROVIDER_PRESENT="$provider_present" \
    invoke_reconcile "$script" "$root"
  cmp -s "$root/bin/macprovider-cli" <(printf "old-binary")
  [ -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
  [ -e "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000" ]
  grep -F "restored_release_restart_deferred" "$root/logs/watchdog.log" >/dev/null
}

assert_loaded_service_accepts_nonzero_bootstrap() {
  script="$1"
  root="$2"
  MACPROVIDER_FAKE_LAUNCHCTL_FAIL=bootstrap invoke_reconcile "$script" "$root"
  cmp -s "$root/bin/macprovider-cli" <(printf "old-binary")
  [ ! -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
  grep -F "print gui/" "$root/launchctl.log" | grep -F "live.malibu.provider" >/dev/null
  grep -F "kickstart -k gui/" "$root/launchctl.log" >/dev/null
}

assert_home_acl_write_is_tolerated() {
  script="$1"
  root="$2"
  if ! chmod +a "group:everyone allow add_file" "$root/home" 2>/dev/null; then
    return 0
  fi
  invoke_reconcile "$script" "$root"
  cmp -s "$root/bin/macprovider-cli" <(printf "old-binary")
  [ ! -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
  if grep -F "recovery_error=acl_write_rejected:$root/home" "$root/logs/watchdog.log" >/dev/null; then
    echo "watchdog must tolerate write ACLs on HOME while checking autoupdate descendants" >&2
    return 1
  fi
}

make_fixture "$TMP/standalone"
run_reconcile "$STANDALONE" "$TMP/standalone"

make_fixture "$TMP/inline"
run_reconcile "$INLINE" "$TMP/inline"

make_fixture "$TMP/full-standalone"
add_full_release_fixture "$TMP/full-standalone"
run_reconcile "$STANDALONE" "$TMP/full-standalone"
cmp -s "$TMP/full-standalone/bin/mlx.metallib" <(printf "old-metal")
cmp -s "$TMP/full-standalone/bin/THIRD-PARTY-NOTICES.txt" <(printf "old-notices")
cmp -s "$TMP/full-standalone/bin/Runtime.bundle/resource" <(printf "old-bundle")
cmp -s "$TMP/full-standalone/bin/catalog-release/release.json" <(printf "old-catalog")
[ ! -e "$TMP/full-standalone/bin/NewOnly.bundle" ]
[ ! -e "$TMP/full-standalone/bin/.macprovider-cli.release-rollback-123e4567-e89b-42d3-a456-426614174000" ]

make_fixture "$TMP/full-inline"
add_full_release_fixture "$TMP/full-inline"
run_reconcile "$INLINE" "$TMP/full-inline"
cmp -s "$TMP/full-inline/bin/mlx.metallib" <(printf "old-metal")
cmp -s "$TMP/full-inline/bin/catalog-release/release.json" <(printf "old-catalog")
[ ! -e "$TMP/full-inline/bin/NewOnly.bundle" ]

for script_name in standalone inline; do
  if [ "$script_name" = standalone ]; then
    script="$STANDALONE"
  else
    script="$INLINE"
  fi
  make_fixture "$TMP/live-owner-$script_name"
  assert_live_owner_fences_recovery "$script" "$TMP/live-owner-$script_name"
  make_fixture "$TMP/restart-timeout-$script_name"
  assert_restart_timeout_retains_recovery "$script" "$TMP/restart-timeout-$script_name"
  make_fixture "$TMP/bootstrap-failure-$script_name"
  assert_restart_failure_retains_recovery \
    "$script" "$TMP/bootstrap-failure-$script_name" bootstrap 0
  make_fixture "$TMP/kickstart-failure-$script_name"
  assert_restart_failure_retains_recovery \
    "$script" "$TMP/kickstart-failure-$script_name" kickstart
  make_fixture "$TMP/bootstrap-loaded-$script_name"
  assert_loaded_service_accepts_nonzero_bootstrap \
    "$script" "$TMP/bootstrap-loaded-$script_name"
  make_fixture "$TMP/home-acl-$script_name"
  assert_home_acl_write_is_tolerated "$script" "$TMP/home-acl-$script_name"
  for kind in hardlink fifo inner-readable outer-readable; do
    make_fixture "$TMP/unsafe-$script_name-$kind"
    assert_unsafe_lock_rejected "$script" "$TMP/unsafe-$script_name-$kind" "$kind"
  done
done

echo "watchdog rollback paths ok"
