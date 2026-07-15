#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
cleanup_test_processes() {
  while IFS= read -r log_path; do
    awk -F'|' '{print $1}' "$log_path" | while read -r pid; do
      kill "$pid" >/dev/null 2>&1 || true
    done
  done < <(find "$TMP" -name manual-fixture.log -type f -print 2>/dev/null)
  rm -rf "$TMP"
}
trap cleanup_test_processes EXIT

python3 - "$INSTALL_SH" > "$TMP/functions.sh" <<'PY'
import sys
names = {
    "cleanup", "install_tx_path_matches", "stage_install_tx_path",
    "stage_lifecycle_snapshot",
    "write_install_recovery_artifacts", "begin_install_transaction",
    "mark_install_cutover_started", "discard_install_transaction_before_cutover",
    "rollback_install_transaction", "commit_install_transaction",
    "arm_install_recovery_agent", "disarm_install_recovery_agent",
    "release_install_lock",
    "launchd_label_is_disabled", "capture_manual_provider_for_recovery",
    "pid_is_live_non_zombie", "stop_owned_manual_provider",
    "validate_port_value", "ensure_port_free",
}
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
i = 0
while i < len(lines):
    name = lines[i].split("()", 1)[0] if "()" in lines[i] else ""
    if name not in names:
        i += 1
        continue
    depth = 0
    while i < len(lines):
        line = lines[i]
        print(line)
        depth += line.count("{") - line.count("}")
        i += 1
        if depth == 0:
            break
PY

# Emit a FULL-schema lifecycle-state record matching the real store's
# JSONEncoder(.sortedKeys) output (compact, alphabetically sorted keys). This is
# the shape ProviderLifecycleStateRecord serializes: authority, state,
# reason_code, writer, operation_id, sequence, transition_id,
# previous_transition_id, provider_id, model_id, operator_paused, version, plus
# last_update/last_restart/last_rejection significant-event sub-records.
# Its definition is also appended to the extracted install functions file so the
# inner transaction harness (a fresh `bash -c`) can author the FULL-schema live
# intermediate record during the mutation phase.
write_full_schema_record() {
  out_path="$1"; state="$2"; reason="$3"; writer="$4"; operation_id="$5"
  sequence="$6"; operator_paused="$7"; transition_id="$8"
  python3 - "$out_path" "$state" "$reason" "$writer" "$operation_id" \
    "$sequence" "$operator_paused" "$transition_id" <<'PY'
import json
import sys

(out_path, state, reason, writer, operation_id, sequence, operator_paused,
 transition_id) = sys.argv[1:]
event = {
    "sequence": int(sequence),
    "transition_id": transition_id,
    "transition_at": "2026-07-15T17:00:00.000Z",
    "state": state,
    "reason_code": reason,
    "writer": writer,
    "operation_id": operation_id,
}
record = {
    "version": 1,
    "sequence": int(sequence),
    "transition_id": transition_id,
    "previous_transition_id": "00000000-0000-4000-8000-000000000000",
    "transition_at": "2026-07-15T17:00:00.000Z",
    "state": state,
    "reason_code": reason,
    "authority": "macprovider_cli",
    "writer": writer,
    "provider_id": "mac",
    "model_id": "qwen3-coder-30b-a3b-instruct",
    "operation_id": operation_id,
    "operator_paused": operator_paused == "true",
    "last_update": event,
    "last_restart": event,
    "last_rejection": event,
}
with open(out_path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

# Make the full-schema record author available to the inner `bash -c` harness,
# which runs as a fresh shell that only sources the extracted install functions.
declare -f write_full_schema_record >> "$TMP/functions.sh"

make_case() {
  case_name="$1"
  root="$TMP/$case_name"
  home="$root/home"
  mkdir -p "$root/bin" "$home/macprovider" "$home/.local/bin" \
    "$home/.config/macprovider" "$home/Library/LaunchAgents" "$root/tx" \
    "$home/.local/share/macprovider-watchdog" "$home/Library/Application Support/macprovider"
  printf 'old-binary\n' > "$home/macprovider/macprovider-cli"
  printf 'old-resource\n' > "$home/macprovider/mlx.metallib"
  chmod +x "$home/macprovider/macprovider-cli"
  ln -s "$home/macprovider/macprovider-cli" "$home/.local/bin/macprovider-cli"
  printf 'model: old-model\nprovider_id: upgrade-provider\n' > "$home/.config/macprovider/config.yaml"
  printf 'upgrade-provider\n' > "$home/.config/macprovider/provider_id"
  printf '{"model_id":"old-model","generated_at":"old"}\n' > "$home/.config/macprovider/last-recommendation.json"
  printf '<plist>old</plist>\n' > "$home/Library/LaunchAgents/live.streamvc.macprovider.plist"
  printf 'old-watchdog\n' > "$home/.local/share/macprovider-watchdog/macprovider-health-monitor"
  printf '<plist>old-watchdog</plist>\n' > "$home/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
  printf '{"version":"old"}\n' > "$home/Library/Application Support/macprovider/install_manifest.json"
  # Seed a prior lifecycle-state file by default so rollback must restore its
  # exact prior contents; the lifecycle_absent_* cases delete it to exercise the
  # restore-prior-absence path. The directory (0700) and file (0600) match the
  # real CLI store posture the installer now validates before snapshotting; the
  # record is FULL-schema (authority/writer/operation_id/sequence/
  # transition_id/... plus operator_paused and version) to match real store
  # output, not a reduced fixture.
  lifecycle_dir="$home/Library/Application Support/macprovider/lifecycle"
  mkdir -p "$lifecycle_dir"
  chmod 700 "$home/Library/Application Support/macprovider" "$lifecycle_dir"
  write_full_schema_record \
    "$lifecycle_dir/state-v1.json" \
    serving install_committed installer serve-op-0001 41 false \
    '11111111-1111-4111-8111-111111111111'
  chmod 600 "$lifecycle_dir/state-v1.json"
  : > "$root/service-active"
  : > "$root/watchdog-service-active"
  : > "$root/launchctl.log"

  cat > "$root/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
service_file="$CASE_ROOT/service-active"
disabled_file="$CASE_ROOT/service-disabled"
case "$*" in
  *macprovider-install-recovery*)
    service_file="$CASE_ROOT/recovery-service-active"
    disabled_file="$CASE_ROOT/recovery-service-disabled"
    ;;
  *macprovider-watchdog*)
    service_file="$CASE_ROOT/watchdog-service-active"
    disabled_file="$CASE_ROOT/watchdog-service-disabled"
    ;;
esac
case "$1" in
  print)
    [ -f "$service_file" ] || exit 1
    ;;
  print-disabled)
    printf 'disabled services = {\n'
    [ ! -f "$CASE_ROOT/service-disabled" ] || printf '  "live.streamvc.macprovider" => true\n'
    [ ! -f "$CASE_ROOT/watchdog-service-disabled" ] || printf '  "live.streamvc.macprovider-watchdog" => true\n'
    printf '}\n'
    ;;
  bootout)
    [ "${FAIL_ACTION:-}" != "bootout" ] || exit 41
    rm -f "$service_file"
    ;;
  bootstrap)
    if printf '%s' "$*" | grep -q 'macprovider-install-recovery'; then
      : > "$service_file"
      exit 0
    fi
    if [ "${FAIL_ONCE_ACTION:-}" = "bootstrap" ] && [ -f "$CASE_ROOT/fail-once" ]; then
      rm -f "$CASE_ROOT/fail-once"
      exit 42
    fi
    [ "${FAIL_ACTION:-}" != "bootstrap" ] || exit 42
    : > "$service_file"
    ;;
  kickstart)
    if printf '%s' "$*" | grep -q 'macprovider-install-recovery'; then
      exit 0
    fi
    if [ "${FAIL_ONCE_ACTION:-}" = "kickstart" ] && [ -f "$CASE_ROOT/fail-once" ]; then
      rm -f "$CASE_ROOT/fail-once"
      exit 43
    fi
    [ "${FAIL_ACTION:-}" != "kickstart" ] || exit 43
    ;;
  enable) rm -f "$disabled_file" ;;
  disable) : > "$disabled_file" ;;
esac
exit 0
EOF
  chmod +x "$root/bin/launchctl"

  cat > "$root/bin/cp" <<'EOF'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="$arg"; done
if [ -f "$CASE_ROOT/fail-backup-cp" ] && printf '%s' "$last" | grep -q '\.staging/install-dir$'; then
  exit 51
fi
if [ -f "$CASE_ROOT/fail-restore-cp" ] && printf '%s' "$last" | grep -q '\.macprovider-restore\.'; then
  exit 52
fi
exec /bin/cp "$@"
EOF
  chmod +x "$root/bin/cp"

  cat > "$root/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [ -f "$CASE_ROOT/fail-config-mv" ] && [ "${1:-}" = "$CASE_ROOT/home/.config/macprovider/config.yaml" ]; then
  exit 61
fi
exec /bin/mv "$@"
EOF
  chmod +x "$root/bin/mv"

  cat > "$root/bin/rm" <<'EOF'
#!/usr/bin/env bash
if [ -f "$CASE_ROOT/fail-retired-rm" ]; then
  for argument in "$@"; do
    case "$argument" in
      *.committed.*) exit 62 ;;
    esac
  done
fi
exec /bin/rm "$@"
EOF
  chmod +x "$root/bin/rm"

  cat > "$root/bin/lsof" <<'EOF'
#!/usr/bin/env bash
arguments="$*"
requested_pid=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "-p" ]; then requested_pid="$argument"; fi
  previous="$argument"
done
manual_pid=""
if [ -n "$requested_pid" ] && kill -0 "$requested_pid" >/dev/null 2>&1; then
  manual_pid="$requested_pid"
elif [ -s "$CASE_ROOT/manual-current.pid" ]; then
  candidate="$(cat "$CASE_ROOT/manual-current.pid")"
  if kill -0 "$candidate" >/dev/null 2>&1; then manual_pid="$candidate"; fi
fi
[ -n "$manual_pid" ] || exit 1
if printf '%s\n' "$arguments" | grep -q -- '-d txt'; then
  printf 'p%s\nn%s\n' "$manual_pid" "$CASE_ROOT/home/macprovider/macprovider-cli"
elif printf '%s\n' "$arguments" | grep -q -- '-d cwd'; then
  printf 'p%s\nn%s\n' "$manual_pid" "$CASE_ROOT/manual-cwd"
elif printf ' %s ' "$arguments" | grep -q -- ' -t '; then
  [ ! -f "$CASE_ROOT/manual-never-bind" ] || exit 1
  printf '%s\n' "$manual_pid"
else
  printf 'COMMAND PID\nmacprovider-cli %s\n' "$manual_pid"
fi
EOF
  chmod +x "$root/bin/lsof"

  cat > "$root/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
if [ -s "$CASE_ROOT/manual-current.pid" ]; then
  pid="$(cat "$CASE_ROOT/manual-current.pid")"
  if kill -0 "$pid" >/dev/null 2>&1; then
    printf '%s %s --port %s\n' "$pid" "$CASE_ROOT/home/macprovider/macprovider-cli" "$(cat "$CASE_ROOT/manual-port")"
    exit 0
  fi
fi
exit 1
EOF
  chmod +x "$root/bin/pgrep"
}

start_manual_fixture() {
  root="$1"
  port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  cat > "$root/manual-provider.c" <<'EOF'
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void write_hex(FILE *log, const char *value) {
  for (const unsigned char *p = (const unsigned char *)value; *p != '\0'; p++) fprintf(log, "%02x", *p);
}

int main(int argc, char **argv) {
  int port = 0;
  const char *log_path = NULL;
  const char *bind_gate = NULL;
  for (int i = 1; i + 1 < argc; i++) if (strcmp(argv[i], "--port") == 0) port = atoi(argv[i + 1]);
  for (int i = 1; i + 1 < argc; i++) if (strcmp(argv[i], "--fixture-log") == 0) log_path = argv[i + 1];
  for (int i = 1; i + 1 < argc; i++) if (strcmp(argv[i], "--bind-gate") == 0) bind_gate = argv[i + 1];
  if (port <= 0 || log_path == NULL || bind_gate == NULL) return 2;
  int never_bind = access(bind_gate, F_OK) == 0;
  if (never_bind) {
    signal(SIGTERM, SIG_IGN);
  } else {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 4) != 0) return 3;
  }
  FILE *log = fopen(log_path, "a");
  if (!log) return 4;
  fprintf(log, "%d", getpid());
  for (int i = 1; i < argc; i++) {
    fprintf(log, "|");
    for (const unsigned char *p = (const unsigned char *)argv[i]; *p != '\0'; p++) fprintf(log, "%02x", *p);
  }
  fprintf(log, "\n");
  fclose(log);
  char cwd[4096];
  const char *context = getenv("MACPROVIDER_RECOVERY_CONTEXT");
  const char *path = getenv("PATH");
  char context_path[8192];
  if (getcwd(cwd, sizeof(cwd)) == NULL || context == NULL || path == NULL) return 5;
  if (snprintf(context_path, sizeof(context_path), "%s.context", log_path) >= (int)sizeof(context_path)) return 6;
  FILE *context_log = fopen(context_path, "a");
  if (!context_log) return 7;
  fprintf(context_log, "%d|", getpid());
  write_hex(context_log, cwd);
  fprintf(context_log, "|");
  write_hex(context_log, context);
  fprintf(context_log, "|");
  write_hex(context_log, path);
  fprintf(context_log, "\n");
  fclose(context_log);
  for (;;) pause();
}
EOF
  cc -O2 -o "$root/home/macprovider/macprovider-cli" "$root/manual-provider.c"
  shasum -a 256 "$root/home/macprovider/macprovider-cli" | awk '{print $1}' > "$root/manual-old.sha256"
  printf '%s\n' "$port" > "$root/manual-port"
  mkdir -p "$root/manual-cwd"
  # Literal shell syntax and lossy-ps edge cases prove argv is captured from
  # KERN_PROCARGS2 and replayed as bytes, never parsed or evaluated by a shell.
  # shellcheck disable=SC2016
  (
    cd "$root/manual-cwd"
    MACPROVIDER_RECOVERY_CONTEXT=$'exact context with spaces\tand tab; $(not evaluated)' \
      PATH="$root/bin:/usr/bin:/bin" \
      exec "$root/home/macprovider/macprovider-cli" --port "$port" --model old-model \
        --fixture-log "$root/manual-fixture.log" \
        --bind-gate "$root/manual-never-bind" \
        --whitespace $'two words\twith tab' \
        --quotes "say \"hello\" and 'goodbye'" \
        --backslashes 'C:\Models\Qwen\file' \
        --metacharacters ';touch ${IFS}'"$root/pwned"' & | $(printf nope) * ? [x]'
  ) &
  manual_pid=$!
  printf '%s\n' "$manual_pid" > "$root/manual-current.pid"
  for _ in $(seq 1 20); do
    kill -0 "$manual_pid" >/dev/null 2>&1 && [ -s "$root/manual-fixture.log" ] && return 0
    sleep 0.1
  done
  return 1
}

run_case() {
  case_name="$1"
  fail_action="${2:-}"
  pre_begin_fault="${3:-}"
  rollback_fault="${4:-}"
  install_phase="${5:-mutation}"
  prior_state="${6:-active}"
  manual_behavior="${7:-bind}"
  lifecycle_behavior="${8:-present}"
  root="$TMP/$case_name"
  make_case "$case_name"
  lifecycle_root_dir="$root/home/Library/Application Support/macprovider/lifecycle"
  lifecycle_state_file="$lifecycle_root_dir/state-v1.json"
  case "$lifecycle_behavior" in
    absent-before)
      # An incumbent that predates the lifecycle contract has no state file at
      # transaction start. Rollback must restore that absence exactly.
      rm -rf "$lifecycle_root_dir"
      ;;
    symlink-file)
      # S-M2: the state file is a symlink to an out-of-tree secret. The snapshot
      # must refuse it (no dereference) and abort pre-mutation.
      printf 'attacker-controlled\n' > "$root/outside-secret"
      rm -f "$lifecycle_state_file"
      ln -s "$root/outside-secret" "$lifecycle_state_file"
      ;;
    symlink-parent)
      # S-M2: the lifecycle directory itself is a symlink. Abort pre-mutation.
      rm -rf "$lifecycle_root_dir"
      mkdir -p "$root/elsewhere-lifecycle"
      chmod 700 "$root/elsewhere-lifecycle"
      write_full_schema_record "$root/elsewhere-lifecycle/state-v1.json" \
        serving install_committed installer serve-op-0001 41 false \
        '11111111-1111-4111-8111-111111111111'
      chmod 600 "$root/elsewhere-lifecycle/state-v1.json"
      ln -s "$root/elsewhere-lifecycle" "$lifecycle_root_dir"
      ;;
    wrong-mode)
      # S-M2: a world-readable state file (0644) must be rejected even though it
      # is otherwise a valid owned regular file.
      chmod 644 "$lifecycle_state_file"
      ;;
    oversized)
      # S-M2: a state file larger than the 1MB bound must be rejected.
      python3 -c 'import sys; open(sys.argv[1],"wb").write(b"{}\n"+b"x"*(1024*1024+16))' \
        "$lifecycle_state_file"
      chmod 600 "$lifecycle_state_file"
      ;;
    updater-snapshot)
      # A-01: the snapshot is an updater-written maintenance record with a dead
      # operation id. Rollback must translate it to an installer-owned record so
      # a restored lifecycle-aware CLI cannot be fenced.
      write_full_schema_record "$lifecycle_state_file" \
        update_in_progress update_admission_pending updater updater-dead-op-9999 55 false \
        '33333333-3333-4333-8333-333333333333'
      chmod 600 "$lifecycle_state_file"
      ;;
    serve-snapshot)
      # A-01: a serve-written snapshot restores byte-exact (serve can always
      # leave its own state; no fencing risk, no translation).
      write_full_schema_record "$lifecycle_state_file" \
        serving_buyers serving_ready serve serve-live-op-7777 60 false \
        '44444444-4444-4444-8444-444444444444'
      chmod 600 "$lifecycle_state_file"
      ;;
  esac
  if [ "$prior_state" = "disabled-inactive" ]; then
    rm -f "$root/service-active" "$root/watchdog-service-active"
    : > "$root/service-disabled"
    : > "$root/watchdog-service-disabled"
  fi
  if [ "$prior_state" = "manual" ]; then
    rm -f "$root/service-active"
    start_manual_fixture "$root"
  fi
  if [ "$install_phase" = "credential-self-test" ]; then
    printf 'model: old-model\n' > "$root/home/.config/macprovider/config.yaml"
  elif [ "$install_phase" = "ordinary-token-self-test" ]; then
    printf 'model: old-model\nprovider_id: upgrade-provider\nprovider_token: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' \
      > "$root/home/.config/macprovider/config.yaml"
  fi
  [ -z "$pre_begin_fault" ] || : > "$root/$pre_begin_fault"

  set +e
  PATH="$root/bin:/usr/bin:/bin" \
    LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" FAIL_ACTION="$fail_action" FAIL_ONCE_ACTION="" \
    FUNCTIONS_PATH="$TMP/functions.sh" \
    PRE_BEGIN_FAULT="$pre_begin_fault" ROLLBACK_FAULT="$rollback_fault" INSTALL_PHASE="$install_phase" \
    MANUAL_BEHAVIOR="$manual_behavior" \
    MUTATION_LIFECYCLE_STATE="${MUTATION_LIFECYCLE_STATE:-}" \
    MUTATION_LIFECYCLE_WRITER="${MUTATION_LIFECYCLE_WRITER:-}" \
    MUTATION_LIFECYCLE_SEQUENCE="${MUTATION_LIFECYCLE_SEQUENCE:-}" \
    MUTATION_LIFECYCLE_OPERATOR_PAUSED="${MUTATION_LIFECYCLE_OPERATOR_PAUSED:-}" \
    MUTATION_LEASE_JSON="${MUTATION_LEASE_JSON:-}" \
    RECOVERY_LIFECYCLE_FAULT="${RECOVERY_LIFECYCLE_FAULT:-}" \
    bash -c '
      set -euo pipefail
      HOME="$CASE_ROOT/home"
      INSTALL_DIR="$HOME/macprovider"
      BIN_DIR="$HOME/.local/bin"
      BINARY_PATH="$BIN_DIR/macprovider-cli"
      CONFIG_DIR="$HOME/.config/macprovider"
      CONFIG_PATH="$CONFIG_DIR/config.yaml"
      PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
      RECOMMENDATION_PATH="$CONFIG_DIR/last-recommendation.json"
      INSTALL_LOCK_PATH="$CONFIG_DIR/install.lock"
      INSTALL_RECOVERY_LABEL="live.streamvc.macprovider-install-recovery"
      INSTALL_RECOVERY_PLIST_PATH="$HOME/Library/LaunchAgents/${INSTALL_RECOVERY_LABEL}.plist"
      PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist"
      WATCHDOG_DIR="$HOME/.local/share/macprovider-watchdog"
      WATCHDOG_PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
      WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
      MANIFEST_PATH="$HOME/Library/Application Support/macprovider/install_manifest.json"
      LIFECYCLE_STATE_PATH="$HOME/Library/Application Support/macprovider/lifecycle/state-v1.json"
      LIFECYCLE_LEASE_PATH="$HOME/Library/Application Support/macprovider/lifecycle/lease.json"
      LIFECYCLE_STATE_LOCK_PATH="$HOME/Library/Application Support/macprovider/lifecycle/.state-v1.json.lock"
      LIFECYCLE_LEASE_LOCK_PATH="$HOME/Library/Application Support/macprovider/lifecycle/.lease.json.lock"
      LIFECYCLE_INSTALL_OPERATION_ID="install:test-$$"
      LOG_DIR="$HOME/Library/Logs/macprovider"
      TMPDIR_PATH="$CASE_ROOT/tx"
      PORT="$(cat "$CASE_ROOT/manual-port" 2>/dev/null || printf 18080)"
      MANUAL_PID=""
      DRY_RUN=0
      INSTALL_TX_ACTIVE=0
      INSTALL_TX_COMMITTED=0
      INSTALL_TX_BACKUP=""
      INSTALL_TX_SERVICE_WAS_ACTIVE=0
      INSTALL_TX_HAD_INSTALL_DIR=0
      INSTALL_TX_HAD_BINARY_PATH=0
      INSTALL_TX_HAD_CONFIG=0
      INSTALL_TX_HAD_PROVIDER_ID=0
      INSTALL_TX_HAD_RECOMMENDATION=0
      INSTALL_TX_HAD_PLIST=0
      INSTALL_TX_HAD_WATCHDOG_DIR=0
      INSTALL_TX_HAD_WATCHDOG_PLIST=0
      INSTALL_TX_HAD_MANIFEST=0
      INSTALL_TX_HAD_LIFECYCLE_STATE=0
      INSTALL_TX_LIFECYCLE_SNAPSHOT_WRITER=""
      INSTALL_TX_LIFECYCLE_SNAPSHOT_OPERATOR_PAUSED=false
      INSTALL_TX_SERVICE_WAS_DISABLED=0
      INSTALL_TX_WATCHDOG_WAS_ACTIVE=0
      INSTALL_TX_WATCHDOG_WAS_DISABLED=0
      INSTALL_TX_ROLLING_BACK=0
      INSTALL_TX_BINARY_KIND="symlink"
      CUTOVER_STARTED=0
      INSTALL_LOCK_HELD=0
      INSTALL_LOCK_TOKEN="test-lock-token"
      INSTALL_LOCK_HOLDER_PID=""
      log() { printf "[test] %s\n" "$*" >&2; }
      die() { code="$1"; shift; printf "[test] ERROR: %s\n" "$*" >&2; exit "$code"; }
      source "$FUNCTIONS_PATH"
      # Mutex ownership is covered by install_transaction_lock.test.sh. These
      # fixtures isolate transaction snapshot/rollback behavior without a live
      # background flock helper.
      assert_install_lock_ownership() { :; }
      trap cleanup EXIT
      begin_install_transaction
      if [ "$INSTALL_PHASE" = "pre-cutover" ]; then
        exit 9
      fi
      mark_install_cutover_started
      if [ "$INSTALL_PHASE" = "manual-self-test" ]; then
        ensure_port_free 1
        if [ "$MANUAL_BEHAVIOR" = "never-bind" ]; then
          printf "REC_MANUAL_READY_TIMEOUT_SECONDS=1\n" >> "$INSTALL_TX_BACKUP/state.sh"
          : > "$CASE_ROOT/manual-never-bind"
        fi
        printf "new-binary\n" > "$INSTALL_DIR/macprovider-cli.new"
        chmod +x "$INSTALL_DIR/macprovider-cli.new"
        mv "$INSTALL_DIR/macprovider-cli.new" "$INSTALL_DIR/macprovider-cli"
      else
        printf "new-binary\n" > "$INSTALL_DIR/macprovider-cli"
      fi
      printf "new-resource\n" > "$INSTALL_DIR/mlx.metallib"
      if [ "$INSTALL_PHASE" = "credential-self-test" ]; then
        printf "model: new-model\nprovider_id: mp-0123456789abcdef0123456789abcdef\nprovider_token: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" > "$CONFIG_PATH"
        printf "mp-0123456789abcdef0123456789abcdef\n" > "$PROVIDER_ID_PATH"
      elif [ "$INSTALL_PHASE" = "ordinary-token-self-test" ]; then
        printf "model: new-model\nprovider_id: upgrade-provider\nprovider_token: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" > "$CONFIG_PATH"
        printf "upgrade-provider\n" > "$PROVIDER_ID_PATH"
      else
        printf "model: new-model\nprovider_id: upgrade-provider\n" > "$CONFIG_PATH"
        printf "new-provider\n" > "$PROVIDER_ID_PATH"
      fi
      printf "{\"model_id\":\"new-model\",\"generated_at\":\"new\"}\n" > "$RECOMMENDATION_PATH"
      printf "<plist>new</plist>\n" > "$PLIST_PATH"
      printf "new-watchdog\n" > "$WATCHDOG_DIR/macprovider-health-monitor"
      printf "<plist>new-watchdog</plist>\n" > "$WATCHDOG_PLIST_PATH"
      printf "{\"version\":\"new\"}\n" > "$MANIFEST_PATH"
      # The new install authors a fresh lifecycle state the legacy incumbent
      # cannot clear on rollback. Rollback must restore the reconciled prior
      # contents, or (for an incumbent that had no lifecycle file) the prior
      # absence. The live intermediate is FULL-schema. Cases can override the
      # live writer/pause via MUTATION_LIFECYCLE_* to exercise operator-pause
      # reconciliation set during the transaction.
      mkdir -p "$(dirname "$LIFECYCLE_STATE_PATH")"
      chmod 700 "$(dirname "$LIFECYCLE_STATE_PATH")"
      write_full_schema_record \
        "$LIFECYCLE_STATE_PATH" \
        "${MUTATION_LIFECYCLE_STATE:-rollback_in_progress}" \
        install_admission_failed \
        "${MUTATION_LIFECYCLE_WRITER:-installer}" \
        "install:test-$$" \
        "${MUTATION_LIFECYCLE_SEQUENCE:-183}" \
        "${MUTATION_LIFECYCLE_OPERATOR_PAUSED:-false}" \
        '22222222-2222-4222-8222-222222222222'
      chmod 600 "$LIFECYCLE_STATE_PATH"
      if [ -n "${MUTATION_LEASE_JSON:-}" ]; then
        # Double quotes here: this block runs inside the single-quoted `bash -c`
        # harness, so a single-quoted format string would break out of the outer
        # quote and drop the backslash from \n.
        printf "%s\n" "$MUTATION_LEASE_JSON" > "$LIFECYCLE_LEASE_PATH"
        chmod 600 "$LIFECYCLE_LEASE_PATH"
      fi
      case "$INSTALL_PHASE" in
        plist|watchdog) exit 9 ;;
        bootstrap)
          launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
          : > "$CASE_ROOT/fail-once"
          FAIL_ONCE_ACTION=bootstrap launchctl bootstrap "gui/$UID" "$PLIST_PATH"
          ;;
        kickstart)
          launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
          launchctl bootstrap "gui/$UID" "$PLIST_PATH"
          : > "$CASE_ROOT/fail-once"
          FAIL_ONCE_ACTION=kickstart launchctl kickstart -k "gui/$UID/live.streamvc.macprovider"
          ;;
        manual-self-test) exit 9 ;;
        new-manual-self-test)
          cat > "$INSTALL_DIR/macprovider-cli" <<'MANUAL'
#!/usr/bin/env bash
trap "" TERM
while :; do sleep 1; done
MANUAL
          chmod +x "$INSTALL_DIR/macprovider-cli"
          "$INSTALL_DIR/macprovider-cli" &
          MANUAL_PID=$!
          printf "%s\n" "$MANUAL_PID" > "$CASE_ROOT/new-manual.pid"
          kill -0 "$MANUAL_PID"
          exit 9
          ;;
        self-test|credential-self-test|ordinary-token-self-test)
          launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
          launchctl bootout "gui/$UID" "$WATCHDOG_PLIST_PATH" >/dev/null 2>&1 || true
          launchctl enable "gui/$UID/live.streamvc.macprovider"
          launchctl enable "gui/$UID/$WATCHDOG_LABEL"
          launchctl bootstrap "gui/$UID" "$PLIST_PATH"
          launchctl kickstart -k "gui/$UID/live.streamvc.macprovider"
          launchctl bootstrap "gui/$UID" "$WATCHDOG_PLIST_PATH"
          launchctl kickstart -k "gui/$UID/$WATCHDOG_LABEL"
          exit 9
          ;;
        commit-cleanup)
          : > "$CASE_ROOT/fail-retired-rm"
          commit_install_transaction
          exit 0
          ;;
        commit-clean)
          commit_install_transaction
          exit 0
          ;;
      esac
      case "$ROLLBACK_FAULT" in
        fail-restore-cp|fail-config-mv) : > "$CASE_ROOT/$ROLLBACK_FAULT" ;;
      esac
      exit 9
    ' > "$root/stdout.log" 2> "$root/stderr.log"
  case_rc=$?
  set -e
  printf '%s\n' "$case_rc" > "$root/rc"
  if [ "$case_rc" -eq 1 ]; then
    cat "$root/stderr.log" >&2
  fi
  if { [ "$install_phase" = "manual-self-test" ] || [ "$install_phase" = "new-manual-self-test" ]; } \
      && [ "$case_rc" -ne 9 ]; then
    cat "$root/stderr.log" >&2
  fi
}

# Assert the non-lifecycle installation was rolled back. Cases whose snapshot is
# translated (updater-written) restore a rollback_in_progress record on purpose,
# so those assert files only and check the lifecycle record separately.
assert_old_install_files() {
  root="$1"
  home="$root/home"
  grep -F 'old-binary' "$home/macprovider/macprovider-cli" >/dev/null
  grep -F 'old-resource' "$home/macprovider/mlx.metallib" >/dev/null
  grep -F 'model: old-model' "$home/.config/macprovider/config.yaml" >/dev/null
  grep -F 'upgrade-provider' "$home/.config/macprovider/provider_id" >/dev/null
  grep -F '"model_id":"old-model"' "$home/.config/macprovider/last-recommendation.json" >/dev/null
  grep -F '<plist>old</plist>' "$home/Library/LaunchAgents/live.streamvc.macprovider.plist" >/dev/null
  grep -F 'old-watchdog' "$home/.local/share/macprovider-watchdog/macprovider-health-monitor" >/dev/null
  grep -F '<plist>old-watchdog</plist>' "$home/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist" >/dev/null
  grep -F '"version":"old"' "$home/Library/Application Support/macprovider/install_manifest.json" >/dev/null
  [ "$(readlink "$home/.local/bin/macprovider-cli")" = "$home/macprovider/macprovider-cli" ]
}

assert_old_install() {
  root="$1"
  home="$root/home"
  assert_old_install_files "$root"
  # The lifecycle-state file is part of the transaction: for an installer- or
  # serve-written snapshot rollback restores the exact prior serving state,
  # never the newer install/rollback state.
  grep -F '"state":"serving"' "$home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null
  if grep -F '"state":"rollback_in_progress"' "$home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null; then
    echo "rollback left the newer lifecycle state behind instead of restoring the prior one" >&2
    return 1
  fi
}

recovery_dir() {
  find "$1/home/.config/macprovider" -maxdepth 1 -type d -name 'install-recovery-*' ! -name '*.staging' -print -quit
}

assert_recovery_preserved() {
  root="$1"
  recovery="$(recovery_dir "$root")"
  [ -n "$recovery" ]
  [ -s "$recovery/state.sh" ]
  [ -s "$recovery/recover.sh" ]
  [ -x "$recovery/observe.sh" ]
  grep -F 'REC_INSTALL_RECOVERY_LABEL=live.streamvc.macprovider-install-recovery' "$recovery/state.sh" >/dev/null
  grep -F 'fcntl.flock(lock_fd, fcntl.LOCK_EX)' "$recovery/observe.sh" >/dev/null
  grep -F "Run exactly: bash '$recovery/recover.sh'" "$root/stderr.log" >/dev/null
}

# Happy rollback: every old path and the active service are verified before the
# durable recovery bundle is removed. The original admission error is retained.
run_case success
[ "$(cat "$TMP/success/rc")" -eq 9 ]
assert_old_install "$TMP/success"
[ -f "$TMP/success/service-active" ]
[ -f "$TMP/success/watchdog-service-active" ]
[ -z "$(recovery_dir "$TMP/success")" ]
grep -F 'bootstrap gui/' "$TMP/success/launchctl.log" >/dev/null
grep -F 'kickstart -k gui/' "$TMP/success/launchctl.log" >/dev/null

# (a) Lifecycle-state rollback restores the exact prior contents byte-for-byte.
# The mutation phase overwrote the file with an installer-written
# rollback_in_progress state a legacy incumbent could never clear; because the
# snapshot was installer-written and unpaused, a healthy rollback restores the
# full-schema serving record byte-exact (no translation, no pause reconcile).
write_full_schema_record "$TMP/success/expected-serving.json" \
  serving install_committed installer serve-op-0001 41 false \
  '11111111-1111-4111-8111-111111111111'
lifecycle_old_hash="$(shasum -a 256 "$TMP/success/home/Library/Application Support/macprovider/lifecycle/state-v1.json" | awk '{print $1}')"
[ "$lifecycle_old_hash" = "$(shasum -a 256 "$TMP/success/expected-serving.json" | awk '{print $1}')" ]
# The restored file keeps the store's owned 0600 posture after rollback.
restored_perm="$(stat -f '%Lp' "$TMP/success/home/Library/Application Support/macprovider/lifecycle/state-v1.json" 2>/dev/null \
  || stat -c '%a' "$TMP/success/home/Library/Application Support/macprovider/lifecycle/state-v1.json")"
[ "$restored_perm" = "600" ]

# (b) Lifecycle-state rollback restores prior ABSENCE. An incumbent with no
# lifecycle file must not gain a stranded state file after rollback; the file
# (and no leftover restore/candidate siblings) must be gone.
run_case lifecycle_absent_restore "" "" "" self-test active bind absent-before
root="$TMP/lifecycle_absent_restore"
[ "$(cat "$root/rc")" -eq 9 ]
grep -F 'old-binary' "$root/home/macprovider/macprovider-cli" >/dev/null
grep -F 'model: old-model' "$root/home/.config/macprovider/config.yaml" >/dev/null
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" ]; then
  echo "rollback stranded a lifecycle-state file where the incumbent had none" >&2
  exit 1
fi
if compgen -G "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json.macprovider-restore.*" >/dev/null; then
  echo "rollback left a lifecycle restore candidate behind" >&2
  exit 1
fi
[ -z "$(recovery_dir "$root")" ]

# (c) An interrupted rollback that is completed by re-running the recovery
# script (the same path the armed LaunchAgent and orphan scan use) must still
# restore the lifecycle contents. A rename fault aborts the first rollback with
# the durable bundle preserved and the newer lifecycle state still live; a
# fault-free rerun of recover.sh must converge to the prior serving state.
run_case lifecycle_interrupted_recovery "" "" fail-config-mv
root="$TMP/lifecycle_interrupted_recovery"
[ "$(cat "$root/rc")" -eq 70 ]
grep -F 'rollback_in_progress' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null
assert_recovery_preserved "$root"
lifecycle_recovery="$(recovery_dir "$root")"
rm -f "$root/fail-config-mv"
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$lifecycle_recovery/recover.sh" > "$root/lifecycle-retry.stdout.log" 2> "$root/lifecycle-retry.stderr.log"
lifecycle_retry_rc=$?
set -e
[ "$lifecycle_retry_rc" -eq 0 ]
grep -F '"state":"serving"' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null
if grep -F 'rollback_in_progress' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null; then
  echo "resumed recovery left the newer lifecycle state behind" >&2
  exit 1
fi
grep -F 'model: old-model' "$root/home/.config/macprovider/config.yaml" >/dev/null

# (d) Forward-success: on commit the lifecycle file keeps the new-install state
# and the snapshot is discarded with the retired recovery bundle. Rollback must
# not fire.
run_case lifecycle_forward_success "" "" "" commit-clean
root="$TMP/lifecycle_forward_success"
[ "$(cat "$root/rc")" -eq 0 ]
grep -F 'rollback_in_progress' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null
if grep -F '"state":"serving"' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null; then
  echo "forward-success incorrectly reverted the lifecycle state to the prior snapshot" >&2
  exit 1
fi
[ -z "$(recovery_dir "$root")" ]
if compgen -G "$root/home/.config/macprovider/install-recovery-*.committed.*" >/dev/null; then
  echo "clean commit did not retire the recovery bundle carrying the lifecycle snapshot" >&2
  exit 1
fi

# A failed artifact prefetch exits before the durable cutover marker. Cleanup
# may restore the suspended watchdog, but it must never boot out, replace, or
# restart the healthy incumbent provider.
run_case pre_cutover_prefetch_failure "" "" "" pre-cutover
[ "$(cat "$TMP/pre_cutover_prefetch_failure/rc")" -eq 9 ]
assert_old_install "$TMP/pre_cutover_prefetch_failure"
[ -f "$TMP/pre_cutover_prefetch_failure/service-active" ]
[ -f "$TMP/pre_cutover_prefetch_failure/watchdog-service-active" ]
[ -z "$(recovery_dir "$TMP/pre_cutover_prefetch_failure")" ]
if grep -F 'bootout gui/' "$TMP/pre_cutover_prefetch_failure/launchctl.log" \
    | grep -F 'live.streamvc.macprovider.plist' >/dev/null; then
  echo "pre-cutover failure stopped the incumbent provider" >&2
  exit 1
fi
grep -F 'Cutover never started; incumbent provider files and process were left untouched.' \
  "$TMP/pre_cutover_prefetch_failure/stderr.log" >/dev/null

# A backup copy/disk failure occurs before any replacement or service stop.
run_case backup_cp_failure "" fail-backup-cp
[ "$(cat "$TMP/backup_cp_failure/rc")" -eq 70 ]
assert_old_install "$TMP/backup_cp_failure"
[ -f "$TMP/backup_cp_failure/service-active" ]
[ -f "$TMP/backup_cp_failure/watchdog-service-active" ]
if grep -F 'bootout gui/' "$TMP/backup_cp_failure/launchctl.log" >/dev/null; then
  echo "backup failure stopped the existing service" >&2
  exit 1
fi

# A restore copy failure leaves the failed new install untouched and preserves
# the complete durable backup plus an exact, rerunnable recovery command.
run_case restore_cp_failure "" "" fail-restore-cp
[ "$(cat "$TMP/restore_cp_failure/rc")" -eq 70 ]
grep -F 'new-binary' "$TMP/restore_cp_failure/home/macprovider/macprovider-cli" >/dev/null
grep -F 'model: new-model' "$TMP/restore_cp_failure/home/.config/macprovider/config.yaml" >/dev/null
[ -f "$TMP/restore_cp_failure/service-active" ]
assert_recovery_preserved "$TMP/restore_cp_failure"

# A permission-like rename failure never deletes the blocked path. Earlier
# swaps retain both the restored old path and the displaced new path durably.
run_case permission_failure "" "" fail-config-mv
[ "$(cat "$TMP/permission_failure/rc")" -eq 70 ]
grep -F 'model: new-model' "$TMP/permission_failure/home/.config/macprovider/config.yaml" >/dev/null
assert_recovery_preserved "$TMP/permission_failure"
permission_recovery="$(recovery_dir "$TMP/permission_failure")"
grep -R -F 'new-binary' "$permission_recovery/failed-current" >/dev/null
grep -F 'old-binary' "$TMP/permission_failure/home/macprovider/macprovider-cli" >/dev/null

# launchd failures are fatal after file restoration, and the verified backup is
# retained instead of being silently discarded.
for action in bootstrap kickstart; do
  run_case "${action}_failure" "$action"
  root="$TMP/${action}_failure"
  [ "$(cat "$root/rc")" -eq 70 ]
  assert_old_install "$root"
  assert_recovery_preserved "$root"
done

# Failures at every post-admission mutation boundary restore both launchd
# services and all provider/watchdog/manifest files. bootstrap and kickstart
# fail once during installation so the recovery attempts themselves can prove
# the prior services are restartable.
for phase in plist watchdog bootstrap kickstart self-test; do
  run_case "install_${phase}_failure" "" "" "" "$phase"
  root="$TMP/install_${phase}_failure"
  [ "$(cat "$root/rc")" -eq 9 ] || [ "$(cat "$root/rc")" -eq 42 ] || [ "$(cat "$root/rc")" -eq 43 ]
  assert_old_install "$root"
  [ -f "$root/service-active" ]
  [ -f "$root/watchdog-service-active" ]
  [ -z "$(recovery_dir "$root")" ]
done

# Ordinary operator-issued credentials are already present in the previous
# config snapshot. The bootstrap-preservation helper must leave them to normal
# rollback rather than treating a non-mp provider ID as a recovery error.
run_case ordinary_token_restore "" "" "" ordinary-token-self-test
root="$TMP/ordinary_token_restore"
[ "$(cat "$root/rc")" -eq 9 ]
assert_old_install "$root"
grep -F 'provider_token: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  "$root/home/.config/macprovider/config.yaml" >/dev/null
[ -z "$(recovery_dir "$root")" ]

# A bootstrap bearer may already be durably confirmed before a later local
# readiness failure. Rollback restores the last-known-good payload and service
# files without deleting the newly confirmed provider identity and token.
run_case confirmed_credential_restore "" "" "" credential-self-test
root="$TMP/confirmed_credential_restore"
[ "$(cat "$root/rc")" -eq 9 ]
grep -F 'old-binary' "$root/home/macprovider/macprovider-cli" >/dev/null
grep -F 'old-resource' "$root/home/macprovider/mlx.metallib" >/dev/null
grep -F 'model: old-model' "$root/home/.config/macprovider/config.yaml" >/dev/null
grep -F 'provider_id: "mp-0123456789abcdef0123456789abcdef"' \
  "$root/home/.config/macprovider/config.yaml" >/dev/null
grep -F 'provider_token: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  "$root/home/.config/macprovider/config.yaml" >/dev/null
[ "$(cat "$root/home/.config/macprovider/provider_id")" = 'mp-0123456789abcdef0123456789abcdef' ]
grep -F '<plist>old</plist>' "$root/home/Library/LaunchAgents/live.streamvc.macprovider.plist" >/dev/null
grep -F 'old-watchdog' "$root/home/.local/share/macprovider-watchdog/macprovider-health-monitor" >/dev/null
grep -F '"version":"old"' "$root/home/Library/Application Support/macprovider/install_manifest.json" >/dev/null
[ -z "$(recovery_dir "$root")" ]

# Once commit atomically retires the active bundle, a best-effort rm failure is
# only cleanup debt: EXIT must not roll the admitted new install back.
run_case commit_cleanup_failure "" "" "" commit-cleanup
root="$TMP/commit_cleanup_failure"
[ "$(cat "$root/rc")" -eq 0 ]
grep -F 'new-binary' "$root/home/macprovider/macprovider-cli" >/dev/null
grep -F 'new-resource' "$root/home/macprovider/mlx.metallib" >/dev/null
grep -F 'model: new-model' "$root/home/.config/macprovider/config.yaml" >/dev/null
committed_recovery="$(find "$root/home/.config/macprovider" -maxdepth 1 -type d \
  -name 'install-recovery-*.committed.*' -print -quit)"
[ -n "$committed_recovery" ]
[ -s "$committed_recovery/state.sh" ]
grep -F 'WARNING: install committed but retired recovery data could not be removed' "$root/stderr.log" >/dev/null
if grep -F 'Install did not pass admission' "$root/stderr.log" >/dev/null; then
  echo "retired recovery cleanup failure triggered rollback" >&2
  exit 1
fi

# A newly launched manual provider can ignore TERM. Admission failure must
# escalate to KILL, prove the exact owned pid is dead, and only then replace
# its files with the previous installation.
run_case new_manual_term_ignoring "" "" "" new-manual-self-test
root="$TMP/new_manual_term_ignoring"
[ "$(cat "$root/rc")" -eq 9 ]
new_manual_pid="$(cat "$root/new-manual.pid")"
if kill -0 "$new_manual_pid" >/dev/null 2>&1; then
  echo "TERM-ignoring newly installed manual provider survived rollback" >&2
  exit 1
fi
assert_old_install "$root"
[ -z "$(recovery_dir "$root")" ]

# Enabled/disabled and active/inactive launchd state is part of the transaction,
# not just plist contents.
run_case disabled_inactive_restore "" "" "" self-test disabled-inactive
root="$TMP/disabled_inactive_restore"
assert_old_install "$root"
[ ! -f "$root/service-active" ]
[ ! -f "$root/watchdog-service-active" ]
[ -f "$root/service-disabled" ]
[ -f "$root/watchdog-service-disabled" ]
[ -z "$(recovery_dir "$root")" ]

# ---------------------------------------------------------------------------
# S-M2: the lifecycle snapshot follows no symlinks, validates owner/type/nlink/
# mode/size, and aborts the transaction closed (before any live mutation) on
# violation. Each negative fixture leaves the incumbent install byte-for-byte
# untouched (begin_install_transaction dies before cutover), no recovery bundle
# is published, and the tell-tale attacker secret is never dereferenced.
# ---------------------------------------------------------------------------
assert_snapshot_aborted_pre_mutation() {
  root="$1"
  reason="$2"
  # begin_install_transaction dies 70 before marking cutover; the inner harness
  # propagates that. The incumbent binary/config/service are left intact.
  [ "$(cat "$root/rc")" -eq 70 ]
  grep -F 'old-binary' "$root/home/macprovider/macprovider-cli" >/dev/null
  grep -F 'model: old-model' "$root/home/.config/macprovider/config.yaml" >/dev/null
  [ -f "$root/service-active" ]
  # No durable recovery bundle survives a pre-mutation snapshot failure.
  [ -z "$(recovery_dir "$root")" ]
  grep -F "$reason" "$root/stderr.log" >/dev/null
  # The incumbent provider was never stopped.
  if grep -F 'bootout gui/' "$root/launchctl.log" \
      | grep -F 'live.streamvc.macprovider.plist' >/dev/null; then
    echo "snapshot failure stopped the incumbent provider" >&2
    exit 1
  fi
}

run_case lifecycle_symlink_file "" "" "" self-test active bind symlink-file
assert_snapshot_aborted_pre_mutation "$TMP/lifecycle_symlink_file" lifecycle_state_symlink
# The out-of-tree secret behind the symlink was never copied anywhere.
if find "$TMP/lifecycle_symlink_file/home/.config/macprovider" -type f \
    -name 'lifecycle-state-v1.json' -exec grep -l 'attacker-controlled' {} + 2>/dev/null | grep -q .; then
  echo "snapshot dereferenced a symlinked state file" >&2
  exit 1
fi

run_case lifecycle_symlink_parent "" "" "" self-test active bind symlink-parent
assert_snapshot_aborted_pre_mutation "$TMP/lifecycle_symlink_parent" lifecycle_parent_symlink

run_case lifecycle_wrong_mode "" "" "" self-test active bind wrong-mode
assert_snapshot_aborted_pre_mutation "$TMP/lifecycle_wrong_mode" lifecycle_state_mode

run_case lifecycle_oversized "" "" "" self-test active bind oversized
assert_snapshot_aborted_pre_mutation "$TMP/lifecycle_oversized" lifecycle_state_oversized

# ---------------------------------------------------------------------------
# A-01(a): a stale-valid updater-written snapshot with a dead operation id is
# NOT raw-restored (that would fence a restored lifecycle-aware CLI). Rollback
# translates it under the lock into an installer-owned rollback_in_progress
# record: writer installer, fresh installer operation id, reserved reason code,
# provider_id/model_id/operator_paused/version preserved, sequence advanced past
# both the snapshot (55) and the live intermediate (183).
# ---------------------------------------------------------------------------
run_case lifecycle_updater_translated "" "" "" self-test active bind updater-snapshot
root="$TMP/lifecycle_updater_translated"
[ "$(cat "$root/rc")" -eq 9 ]
assert_old_install_files "$root"
[ -z "$(recovery_dir "$root")" ]
python3 - "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
def require(condition, message):
    if not condition:
        raise SystemExit("translated record %s: %r" % (message, record))
require(record["writer"] == "installer", "must be installer-owned")
require(record["state"] == "rollback_in_progress", "must be rollback_in_progress")
require(record["reason_code"] == "install_rollback_restored_translated", "reserved reason code")
require(record["authority"] == "macprovider_cli", "authority preserved")
require(record["version"] == 1, "version preserved")
require(record["provider_id"] == "mac", "provider_id preserved")
require(record["model_id"] == "qwen3-coder-30b-a3b-instruct", "model_id preserved")
require(record["operator_paused"] is False, "operator_paused preserved false")
require(record["operation_id"].startswith("install-rollback:"), "fresh installer op id")
require(record["operation_id"] != "updater-dead-op-9999", "dead op id not reused")
require(record["sequence"] > 183, "sequence advanced past live intermediate")
require(record["sequence"] > 55, "sequence advanced past snapshot")
# transition_id is a fresh lowercase UUID distinct from the snapshot's.
tid = record["transition_id"]
require(tid == tid.lower() and len(tid) == 36, "fresh lowercase uuid transition id")
require(tid != "33333333-3333-4333-8333-333333333333", "new transition id")
require(record.get("previous_transition_id") == "33333333-3333-4333-8333-333333333333",
        "previous_transition_id chains snapshot")
PY

# A-01(b): a serve-written snapshot restores byte-exact (serve can always leave
# its own state; no fencing risk, no translation).
run_case lifecycle_serve_byte_exact "" "" "" self-test active bind serve-snapshot
root="$TMP/lifecycle_serve_byte_exact"
[ "$(cat "$root/rc")" -eq 9 ]
assert_old_install_files "$root"
write_full_schema_record "$root/expected-serve.json" \
  serving_buyers serving_ready serve serve-live-op-7777 60 false \
  '44444444-4444-4444-8444-444444444444'
serve_restored_hash="$(shasum -a 256 "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" | awk '{print $1}')"
[ "$serve_restored_hash" = "$(shasum -a 256 "$root/expected-serve.json" | awk '{print $1}')" ]
[ -z "$(recovery_dir "$root")" ]

# A-01(c): a durable operator pause set DURING the transaction (live file
# operator_paused true while the snapshot was unpaused) survives rollback. The
# restored record preserves operator_paused: true even though the snapshot did
# not carry it.
MUTATION_LIFECYCLE_OPERATOR_PAUSED=true \
  run_case lifecycle_pause_survives "" "" "" self-test
root="$TMP/lifecycle_pause_survives"
[ "$(cat "$root/rc")" -eq 9 ]
assert_old_install_files "$root"
python3 - "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
if record.get("operator_paused") is not True:
    raise SystemExit("durable operator pause set during the transaction was lost on rollback: %r" % record)
# The installer-written unpaused snapshot's other fields are otherwise preserved.
if record.get("writer") != "installer" or record.get("state") != "serving":
    raise SystemExit("pause reconciliation altered unrelated fields: %r" % record)
PY
[ -z "$(recovery_dir "$root")" ]

# A-01(e): lock contention. When the store lock cannot be acquired at restore
# time, recovery fails closed with the bundle preserved and the newer lifecycle
# state still live. A rerun of recover.sh after the lock is released converges.
run_case lifecycle_lock_contended "" "" fail-config-mv
root="$TMP/lifecycle_lock_contended"
[ "$(cat "$root/rc")" -eq 70 ]
lock_recovery="$(recovery_dir "$root")"
assert_recovery_preserved "$root"
rm -f "$root/fail-config-mv"
# Hold the store lock from an external process, then confirm recover.sh fails
# closed (lock_contended) with the bundle preserved.
lifecycle_lock_path="$root/home/Library/Application Support/macprovider/lifecycle/.state-v1.json.lock"
: > "$lifecycle_lock_path"
chmod 600 "$lifecycle_lock_path"
python3 - "$lifecycle_lock_path" > "$root/lock-holder.status" 2>/dev/null <<'PY' &
import fcntl
import os
import sys
import time

fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
sys.stdout.write("held\n")
sys.stdout.flush()
# Hold longer than the restore's bounded lock timeout so the contended retry
# fails closed rather than waiting the holder out. The test kills this holder
# immediately after asserting the fail-closed outcome.
time.sleep(60)
PY
lock_holder_pid=$!
for _ in $(seq 1 40); do
  grep -qx held "$root/lock-holder.status" 2>/dev/null && break
  sleep 0.1
done
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$lock_recovery/recover.sh" > "$root/lock-retry.stdout.log" 2> "$root/lock-retry.stderr.log"
lock_retry_rc=$?
set -e
kill "$lock_holder_pid" >/dev/null 2>&1 || true
wait "$lock_holder_pid" 2>/dev/null || true
[ "$lock_retry_rc" -eq 70 ]
grep -F 'lifecycle_lock_contended' "$root/lock-retry.stderr.log" >/dev/null
# The bundle is preserved and the newer live state is still present.
[ -n "$(recovery_dir "$root")" ]
grep -F 'rollback_in_progress' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null
# With the lock released, a rerun converges to the restored serving state.
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$lock_recovery/recover.sh" > "$root/lock-retry2.stdout.log" 2> "$root/lock-retry2.stderr.log"
lock_retry2_rc=$?
set -e
[ "$lock_retry2_rc" -eq 0 ]
grep -F '"state":"serving"' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null

# ---------------------------------------------------------------------------
# S-M3: durability fault injection. A fault BETWEEN the move-aside and the
# move-in preserves the bundle; a clean rerun converges. A forced post-swap
# verification failure likewise preserves the bundle.
# ---------------------------------------------------------------------------
run_case lifecycle_fault_between "" "" fail-config-mv
root="$TMP/lifecycle_fault_between"
[ "$(cat "$root/rc")" -eq 70 ]
between_recovery="$(recovery_dir "$root")"
assert_recovery_preserved "$root"
rm -f "$root/fail-config-mv"
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  RECOVERY_LIFECYCLE_FAULT=between-aside-and-move-in \
  bash "$between_recovery/recover.sh" > "$root/between.stdout.log" 2> "$root/between.stderr.log"
between_rc=$?
set -e
[ "$between_rc" -eq 70 ]
grep -F 'lifecycle_restore_interrupted_between_aside_and_move_in' "$root/between.stderr.log" >/dev/null
[ -n "$(recovery_dir "$root")" ]
# Clean rerun (no fault) converges to the restored serving state.
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$between_recovery/recover.sh" > "$root/between2.stdout.log" 2> "$root/between2.stderr.log"
between2_rc=$?
set -e
[ "$between2_rc" -eq 0 ]
grep -F '"state":"serving"' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null

run_case lifecycle_fault_postswap "" "" fail-config-mv
root="$TMP/lifecycle_fault_postswap"
[ "$(cat "$root/rc")" -eq 70 ]
postswap_recovery="$(recovery_dir "$root")"
rm -f "$root/fail-config-mv"
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  RECOVERY_LIFECYCLE_FAULT=post-swap-verify-failure \
  bash "$postswap_recovery/recover.sh" > "$root/postswap.stdout.log" 2> "$root/postswap.stderr.log"
postswap_rc=$?
set -e
[ "$postswap_rc" -eq 70 ]
grep -F 'lifecycle_restore_post_swap_verification_forced' "$root/postswap.stderr.log" >/dev/null
[ -n "$(recovery_dir "$root")" ]
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$postswap_recovery/recover.sh" > "$root/postswap2.stdout.log" 2> "$root/postswap2.stderr.log"
postswap2_rc=$?
set -e
[ "$postswap2_rc" -eq 0 ]
grep -F '"state":"serving"' "$root/home/Library/Application Support/macprovider/lifecycle/state-v1.json" >/dev/null

# ---------------------------------------------------------------------------
# A-05: lease reconciliation after rollback. The lock files are synchronization
# primitives and must remain byte-stable; only lease.json is reconciled.
# ---------------------------------------------------------------------------
# (A-05.1) A stale lease from the rolled-back install operation is removed.
MUTATION_LEASE_JSON='{"operation_id":"install:test-'"$$"'","owner_pid":999999,"kind":"maintenance"}' \
  run_case lease_stale_operation "" "" "" self-test
root="$TMP/lease_stale_operation"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "stale rolled-back-operation lease survived rollback" >&2
  exit 1
fi
[ -z "$(recovery_dir "$root")" ]

# (A-05.2) A dead-owner lease (foreign operation but the PID is not alive) is
# removed.
MUTATION_LEASE_JSON='{"operation_id":"someone-else","owner_pid":999999,"kind":"startup"}' \
  run_case lease_dead_owner "" "" "" self-test
root="$TMP/lease_dead_owner"
[ "$(cat "$root/rc")" -eq 9 ]
if [ -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "dead-owner lease survived rollback" >&2
  exit 1
fi

# (A-05.3) A live foreign-owner lease (not part of this transaction) is
# preserved. The lock files are never mutated byte-wise.
lease_live_root="$TMP/lease_live_foreign"
sleep 300 &
foreign_pid=$!
# Pre-create the lock files so we can hash them before and after and prove they
# are never rewritten by the reconciler.
mutation_lease="{\"operation_id\":\"unrelated-live\",\"owner_pid\":$foreign_pid,\"kind\":\"startup\"}"
MUTATION_LEASE_JSON="$mutation_lease" \
  run_case lease_live_foreign "" "" "" self-test
root="$TMP/lease_live_foreign"
[ "$(cat "$root/rc")" -eq 9 ]
if [ ! -e "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" ]; then
  echo "live foreign-owner lease was incorrectly removed" >&2
  kill "$foreign_pid" >/dev/null 2>&1 || true
  exit 1
fi
grep -F 'unrelated-live' "$root/home/Library/Application Support/macprovider/lifecycle/lease.json" >/dev/null
# The synchronization lock files exist and were never emptied/rewritten by the
# reconciler (they are 0-length primitives the CLI never treats as content).
for lock in .state-v1.json.lock .lease.json.lock; do
  lock_path="$root/home/Library/Application Support/macprovider/lifecycle/$lock"
  [ -f "$lock_path" ]
  [ ! -s "$lock_path" ] || {
    echo "lock file $lock was written with content by recovery" >&2
    kill "$foreign_pid" >/dev/null 2>&1 || true
    exit 1
  }
done
kill "$foreign_pid" >/dev/null 2>&1 || true
wait "$foreign_pid" 2>/dev/null || true
[ -z "$(recovery_dir "$root")" ]

run_darwin_manual_recovery_cases() {
# A non-launchd provider holding the configured port is a real protected
# process state: capture it before stop, restore the exact prior binary and
# argv on self-test failure, and never evaluate shell metacharacters stored in
# an argument.
run_case manual_provider_restore "" "" "" manual-self-test manual
wait "$manual_pid" 2>/dev/null || true
root="$TMP/manual_provider_restore"
[ "$(cat "$root/rc")" -eq 9 ]
for _ in $(seq 1 20); do
  [ "$(wc -l < "$root/manual-fixture.log" | tr -d ' ')" -ge 2 ] && break
  sleep 0.1
done
initial_pid="$(head -n 1 "$root/manual-fixture.log" | cut -d'|' -f1)"
restored_pid="$(tail -n 1 "$root/manual-fixture.log" | cut -d'|' -f1)"
[ "$initial_pid" != "$restored_pid" ]
if kill -0 "$initial_pid" >/dev/null 2>&1; then
  echo "original manual provider survived protected stop" >&2
  exit 1
fi
kill -0 "$restored_pid"
[ "$(wc -l < "$root/manual-fixture.log" | tr -d ' ')" -eq 2 ]
python3 - "$root/manual-fixture.log" "$root" "$(cat "$root/manual-port")" <<'PY'
import os
import sys

log_path, root, port = sys.argv[1:]
with open(log_path, "r", encoding="ascii") as handle:
    lines = [line.rstrip("\n").split("|") for line in handle]
if len(lines) != 2:
    raise SystemExit(f"expected original and restored argv records, got {len(lines)}")
decoded = [[bytes.fromhex(argument) for argument in line[1:]] for line in lines]
expected = [
    b"--port", port.encode("ascii"),
    b"--model", b"old-model",
    b"--fixture-log", os.fsencode(root + "/manual-fixture.log"),
    b"--bind-gate", os.fsencode(root + "/manual-never-bind"),
    b"--whitespace", b"two words\twith tab",
    b"--quotes", b"say \"hello\" and 'goodbye'",
    b"--backslashes", b"C:\\Models\\Qwen\\file",
    b"--metacharacters", os.fsencode(";touch ${IFS}" + root + "/pwned & | $(printf nope) * ? [x]"),
]
if decoded[0] != expected:
    raise SystemExit(f"fixture did not start with expected exact argv: {decoded[0]!r}")
if decoded[1] != decoded[0]:
    raise SystemExit(f"restored argv differs from exact original: {decoded!r}")
PY
python3 - "$root/manual-fixture.log.context" "$root" <<'PY'
import os
import sys

log_path, root = sys.argv[1:]
with open(log_path, "r", encoding="ascii") as handle:
    lines = [line.rstrip("\n").split("|") for line in handle]
if len(lines) != 2 or any(len(line) != 4 for line in lines):
    raise SystemExit(f"expected original and restored process context records, got {lines!r}")
decoded = [[bytes.fromhex(field) for field in line[1:]] for line in lines]
expected = [
    os.fsencode(os.path.realpath(root + "/manual-cwd")),
    b"exact context with spaces\tand tab; $(not evaluated)",
    os.fsencode(root + "/bin:/usr/bin:/bin"),
]
if decoded[0] != expected:
    raise SystemExit(f"fixture did not start with expected cwd/environment: {decoded[0]!r}")
if decoded[1] != decoded[0]:
    raise SystemExit(f"restored cwd/environment differs from exact original: {decoded!r}")
PY
[ ! -e "$root/pwned" ]
[ "$(shasum -a 256 "$root/home/macprovider/macprovider-cli" | awk '{print $1}')" = "$(cat "$root/manual-old.sha256")" ]
grep -F 'model: old-model' "$root/home/.config/macprovider/config.yaml" >/dev/null
[ -z "$(recovery_dir "$root")" ]
kill "$restored_pid"

# A restored process that remains alive but never binds is not a successful
# rollback. It ignores TERM to exercise the KILL fallback; recovery must prove
# it is dead, preserve the bundle, and permit a clean retry with no orphan.
run_case manual_provider_never_binds "" "" "" manual-self-test manual never-bind
wait "$manual_pid" 2>/dev/null || true
root="$TMP/manual_provider_never_binds"
[ "$(cat "$root/rc")" -eq 70 ]
assert_recovery_preserved "$root"
[ "$(wc -l < "$root/manual-fixture.log" | tr -d ' ')" -eq 2 ]
failed_restored_pid="$(sed -n '2s/|.*//p' "$root/manual-fixture.log")"
for _ in $(seq 1 20); do
  ! kill -0 "$failed_restored_pid" >/dev/null 2>&1 && break
  sleep 0.1
done
if kill -0 "$failed_restored_pid" >/dev/null 2>&1; then
  echo "never-binding restored provider survived recovery cleanup" >&2
  exit 1
fi
recovery="$(recovery_dir "$root")"
[ ! -e "$recovery/manual-restored.pid" ]
rm -f "$root/manual-never-bind"
set +e
PATH="$root/bin:/usr/bin:/bin" LAUNCHCTL_LOG="$root/launchctl.log" CASE_ROOT="$root" \
  bash "$recovery/recover.sh" > "$root/retry.stdout.log" 2> "$root/retry.stderr.log"
retry_rc=$?
set -e
[ "$retry_rc" -eq 0 ]
for _ in $(seq 1 20); do
  [ "$(wc -l < "$root/manual-fixture.log" | tr -d ' ')" -ge 3 ] && break
  sleep 0.1
done
[ "$(wc -l < "$root/manual-fixture.log" | tr -d ' ')" -eq 3 ]
retry_pid="$(sed -n '3s/|.*//p' "$root/manual-fixture.log")"
[ "$retry_pid" != "$failed_restored_pid" ]
kill -0 "$retry_pid"
[ "$(cat "$recovery/manual-restored.pid")" = "$retry_pid" ]
first_argv="$(sed -n '1s/^[^|]*|//p' "$root/manual-fixture.log")"
failed_argv="$(sed -n '2s/^[^|]*|//p' "$root/manual-fixture.log")"
retry_argv="$(sed -n '3s/^[^|]*|//p' "$root/manual-fixture.log")"
[ "$failed_argv" = "$first_argv" ]
[ "$retry_argv" = "$first_argv" ]
if kill -0 "$failed_restored_pid" >/dev/null 2>&1; then
  echo "failed restored provider was orphaned after successful retry" >&2
  exit 1
fi
kill "$retry_pid"
}

# Exact capture and byte-for-byte replay of an existing process uses Darwin's
# KERN_PROCARGS2 contract. Portable CI still exercises every other rollback
# case above; the macOS lane runs these two process-preservation cases.
if [ "$(uname -s)" = "Darwin" ]; then
  run_darwin_manual_recovery_cases
else
  echo "skipping Darwin-only manual provider argv recovery cases"
fi

echo "upgrade evidence rollback fault matrix ok"
