#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
holder_pid=""
recovery_owner_pid=""
mutation_holder_pid=""
cleanup() {
  if [ -s "$TMP/home/holder-shell.pid" ]; then
    kill "$(cat "$TMP/home/holder-shell.pid")" >/dev/null 2>&1 || true
  fi
  if [ -n "$holder_pid" ]; then
    kill "$holder_pid" >/dev/null 2>&1 || true
    wait "$holder_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$recovery_owner_pid" ]; then
    kill "$recovery_owner_pid" >/dev/null 2>&1 || true
    wait "$recovery_owner_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$mutation_holder_pid" ]; then
    kill "$mutation_holder_pid" >/dev/null 2>&1 || true
    wait "$mutation_holder_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

python3 - "$INSTALL_SH" > "$TMP/functions.sh" <<'PY'
import sys
names = {
    "release_install_lock",
    "assert_install_lock_ownership",
    "acquire_install_lock",
    "recover_orphaned_install_transactions",
    "fsync_directory_path",
}
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
index = 0
while index < len(lines):
    name = lines[index].split("()", 1)[0] if "()" in lines[index] else ""
    if name not in names:
        index += 1
        continue
    depth = 0
    while index < len(lines):
        line = lines[index]
        print(line)
        depth += line.count("{") - line.count("}")
        index += 1
        if depth == 0:
            break
PY

mkdir -m 700 "$TMP/home"
run_lock_shell() {
  action="$1"
  HOME="$TMP/home" FUNCTION_PATH="$TMP/functions.sh" ACTION="$action" bash -c '
    set -euo pipefail
    CONFIG_DIR="$HOME/.config/macprovider"
    INSTALL_LOCK_PATH="$CONFIG_DIR/install.lock"
    PROVIDER_MUTATION_ROOT="$HOME/.local/share/macprovider/autoupdate"
    PROVIDER_MUTATION_LOCK_PATH="$PROVIDER_MUTATION_ROOT/update.lock"
    PROVIDER_MUTATION_PENDING_PATH="$PROVIDER_MUTATION_ROOT/pending.json"
    INSTALL_LOCK_HELD=0
    INSTALL_LOCK_TOKEN=""
    INSTALL_LOCK_HOLDER_PID=""
    DRY_RUN=0
    log() { :; }
    die() { code="$1"; shift; printf "%s\n" "$*" >&2; exit "$code"; }
    source "$FUNCTION_PATH"
    trap release_install_lock EXIT
    acquire_install_lock
    case "$ACTION" in
      hold) printf "%s\n" "$$" > "$HOME/holder-shell.pid"; touch "$HOME/held"; while :; do sleep 1; done ;;
      orphan-helper)
        kill -KILL "$INSTALL_LOCK_HOLDER_PID"
        wait "$INSTALL_LOCK_HOLDER_PID" >/dev/null 2>&1 || true
        touch "$HOME/helper-dead"
        while [ ! -f "$HOME/assert-now" ]; do sleep 0.05; done
        assert_install_lock_ownership
        touch "$HOME/protected-mutation"
        ;;
      recover) recover_orphaned_install_transactions ;;
    esac
  '
}

run_lock_shell hold > "$TMP/holder.out" 2> "$TMP/holder.err" &
holder_pid=$!
for _ in $(seq 1 100); do
  [ -f "$TMP/home/held" ] && break
  sleep 0.05
done
[ -f "$TMP/home/held" ]

set +e
run_lock_shell once > "$TMP/second.out" 2> "$TMP/second.err"
second_rc=$?
set -e
[ "$second_rc" -eq 73 ]
grep -F 'another macprovider installer is active' "$TMP/second.err" >/dev/null

kill "$(cat "$TMP/home/holder-shell.pid")"
wait "$holder_pid" >/dev/null 2>&1 || true
holder_pid=""
sleep 1
run_lock_shell once

# A dead flock helper must not make a still-live installer's durable ownership
# record claimable. The second installer receives busy (73), while the original
# owner fail-stops before its next protected mutation/commit boundary.
run_lock_shell orphan-helper > "$TMP/orphan-holder.out" 2> "$TMP/orphan-holder.err" &
holder_pid=$!
for _ in $(seq 1 100); do
  [ -f "$TMP/home/helper-dead" ] && break
  sleep 0.05
done
[ -f "$TMP/home/helper-dead" ]
kill -0 "$holder_pid"
set +e
run_lock_shell once > "$TMP/orphan-second.out" 2> "$TMP/orphan-second.err"
orphan_second_rc=$?
set -e
[ "$orphan_second_rc" -eq 73 ]
grep -F 'another macprovider installer is active' "$TMP/orphan-second.err" >/dev/null
touch "$TMP/home/assert-now"
set +e
wait "$holder_pid"
orphan_owner_rc=$?
set -e
holder_pid=""
[ "$orphan_owner_rc" -eq 70 ]
[ ! -e "$TMP/home/protected-mutation" ]
grep -F 'installer lock ownership was lost' "$TMP/orphan-holder.err" >/dev/null

# Once the exact recorded owner exits, the stale record may be replaced.
run_lock_shell once

# Swift self-update/autoupdate and the shell installer share a fixed lock order:
# install.lock first, then update.lock. A live Swift mutation holder fences the
# installer before any transaction snapshot or recovery mutation begins.
mkdir -p "$TMP/home/.local/share/macprovider/autoupdate"
chmod 700 "$TMP/home/.local" "$TMP/home/.local/share" "$TMP/home/.local/share/macprovider" "$TMP/home/.local/share/macprovider/autoupdate"
python3 - "$TMP/home/.local/share/macprovider/autoupdate/update.lock" "$TMP/home/mutation-held" <<'PY' &
import fcntl, os, signal, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(0))
while True:
    time.sleep(0.1)
PY
mutation_holder_pid=$!
for _ in $(seq 1 100); do
  [ -f "$TMP/home/mutation-held" ] && break
  sleep 0.05
done
set +e
run_lock_shell once > "$TMP/mutation-busy.out" 2> "$TMP/mutation-busy.err"
mutation_busy_rc=$?
set -e
[ "$mutation_busy_rc" -eq 73 ]
grep -F 'another provider update is active' "$TMP/mutation-busy.err" >/dev/null
kill "$mutation_holder_pid"
wait "$mutation_holder_pid" >/dev/null 2>&1 || true
mutation_holder_pid=""

# A durable pending updater marker remains an active transaction even after the
# updater process restarted and released its kernel locks. Installer must wait
# for coordinator admission or rollback recovery instead of overwriting it.
printf '{}\n' > "$TMP/home/.local/share/macprovider/autoupdate/pending.json"
chmod 600 "$TMP/home/.local/share/macprovider/autoupdate/pending.json"
set +e
run_lock_shell once > "$TMP/mutation-pending.out" 2> "$TMP/mutation-pending.err"
mutation_pending_rc=$?
set -e
[ "$mutation_pending_rc" -eq 73 ]
grep -F 'awaiting coordinator admission or recovery' "$TMP/mutation-pending.err" >/dev/null
rm -f "$TMP/home/.local/share/macprovider/autoupdate/pending.json"
run_lock_shell once

# The per-transaction recovery claim uses the same durable-owner fence. Killing
# only its flock helper must not let a second recovery process mutate the same
# rollback bundle while the recorded recovery owner is still alive.
python3 - "$INSTALL_SH" > "$TMP/recovery-claim.py" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
needle = 'python3 - "$RECOVERY_DIR/recovery.lock" "$$" "$claim_status" <<\'PY\' &'
start = next(index for index, line in enumerate(lines) if needle in line) + 1
for line in lines[start:]:
    if line == "PY":
        break
    print(line)
else:
    raise SystemExit("recovery claim heredoc terminator not found")
PY
sleep 60 &
recovery_owner_pid=$!
: > "$TMP/recovery-status-1"
python3 "$TMP/recovery-claim.py" "$TMP/recovery.lock" "$recovery_owner_pid" "$TMP/recovery-status-1" &
recovery_helper_pid=$!
for _ in $(seq 1 100); do
  [ -s "$TMP/recovery-status-1" ] && break
  sleep 0.05
done
grep -Fx 'ok' "$TMP/recovery-status-1" >/dev/null
kill -KILL "$recovery_helper_pid"
wait "$recovery_helper_pid" >/dev/null 2>&1 || true
: > "$TMP/recovery-status-2"
set +e
python3 "$TMP/recovery-claim.py" "$TMP/recovery.lock" "$$" "$TMP/recovery-status-2"
recovery_second_rc=$?
set -e
[ "$recovery_second_rc" -eq 75 ]
grep -Fx 'busy' "$TMP/recovery-status-2" >/dev/null
kill "$recovery_owner_pid"
wait "$recovery_owner_pid" >/dev/null 2>&1 || true
recovery_owner_pid=""

for suffix in 02 01; do
  recovery="$TMP/home/.config/macprovider/install-recovery-$suffix"
  mkdir -m 700 "$recovery"
  printf '# state fixture\n' > "$recovery/state.sh"
  cat > "$recovery/recover.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$suffix' >> '$TMP/home/recovery-order'
EOF
  chmod 700 "$recovery/recover.sh"
done
run_lock_shell recover
[ "$(tr '\n' ' ' < "$TMP/home/recovery-order")" = "01 02 " ]
[ -z "$(find "$TMP/home/.config/macprovider" -maxdepth 1 -type d -name 'install-recovery-*' -print -quit)" ]

rm -f "$TMP/home/.config/macprovider/install.lock"
ln -s "$TMP/home/attacker-lock" "$TMP/home/.config/macprovider/install.lock"
set +e
run_lock_shell once > "$TMP/symlink.out" 2> "$TMP/symlink.err"
symlink_rc=$?
set -e
[ "$symlink_rc" -eq 70 ]
[ ! -e "$TMP/home/attacker-lock" ]

python3 - "$INSTALL_SH" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
required = [
    'INSTALL_RECOVERY_LABEL="live.malibu.provider-install-recovery"',
    'arm_install_recovery_agent',
    'fcntl.flock(lock_fd, fcntl.LOCK_EX)',
    'os.path.join(recovery_dir, "recover.sh")',
    'disarm_install_recovery_agent',
    '"holder_pid": os.getpid()',
    'existing_boot == current_boot',
    'raise RuntimeError("installer lock helper no longer owns the kernel lock")',
    'raise RuntimeError("recovery lock record is invalid")',
]
missing = [fragment for fragment in required if fragment not in text]
if missing:
    raise SystemExit(f"missing durable observer behavior: {missing}")
PY
