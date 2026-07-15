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
  root="$TMP/$case_name"
  make_case "$case_name"
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

assert_old_install() {
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
