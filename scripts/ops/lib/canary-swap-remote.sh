#!/bin/bash
# Runs ON the canary Mac. scripts/ops/canary-swap.sh stages it next to the
# candidate tarball and starts it detached (nohup), so a dropped ssh session
# cannot interrupt a swap or a rollback; the operator side polls RESULT_FILE.
# bash 3.2 compatible (stock macOS /bin/bash).
#
# Payload swap of the live provider to a verified candidate tarball, or the
# narrowly-scoped Studio owner-pin transaction staged by studio-owner-pin.sh:
# pause and drain, back up the install dir, replace the payload, restart, then
# watch (the installed watchdog stays booted out until the candidate, or the
# restored version, is buyer_serving). A provider process restart (crash loop),
# a process that exits, or a /v1/status silence of STATUS_TIMEOUT_S once the
# candidate has reported its model loaded restores the backup, waits until the
# previous version is buyer_serving again, and resumes it. Before the model is
# loaded /v1/status may stay silent (a large model, such as GLM-5.3-Flash at
# about 175 GB, loads for 7-13 minutes): silence then is bounded only by
# READY_TIMEOUT_S while the provider pid stays the same and alive. The owner-
# pin mode changes only max_concurrency_override/max_concurrency_source under
# the provider config lock and restores only those fields on failure.
#
# Exit codes (also written to RESULT_FILE): 0 swapped and buyer-serving;
# 4 refused before the swap (payload untouched, provider resumed);
# 5 candidate failed, previous version restored and buyer-serving;
# 6 recovery needs the operator (the log says what is left).
set -euo pipefail
export PATH="${CANARY_REMOTE_PATH_PREFIX:+$CANARY_REMOTE_PATH_PREFIX:}/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
umask 077

MODE=swap
case "${1:-}" in remove-owner-pin|restore-owner-pin) MODE="$1"; shift ;; esac
if [ "$MODE" = swap ]; then
  TARBALL="$1"
  TARBALL_SHA="$2"
  VERSION="$3"
  INSTALL_DIR="${4:-$HOME/macprovider}"
  LABEL="${5:-live.malibu.provider}"
  SOCKET="${6:-}"
  PORT="$7"
  STATUS_TIMEOUT_S="$8"
  READY_TIMEOUT_S="$9"
  DRAIN_TIMEOUT_S="${10}"
  STABLE_S="${11}"
  POLL_S="${12:-5}"
  RESULT_FILE="${13:-$(dirname "$TARBALL")/result}"
  AIR_PROVIDER_SHA="${14:-}"
  AIR_CONFIG="${15:-}"
  AIR_OLD_BINARY_SHA="${16:-}"
  AIR_ACTION="${17:-}"
  AIR_CONFIG_SHA="${18:-}"
  CONFIG="" JOURNAL="" HELPER="" EXPECTED_BINARY_SHA="" EXPECTED_PROVIDER_SHA="" EXPECTED_MODEL="" EXPECTED_POLICY_SHA=""
  EXPECTED_POLICY_RELEASE="" EXPECTED_POLICY_TUPLE="" EXPECTED_TEAM_ID="" EXPECTED_SIGNING_IDENTIFIER="" EXPECTED_CDHASH=""
else
  VERSION="$1"
  INSTALL_DIR="$2"
  LABEL="${3:-live.malibu.provider}"
  SOCKET="${4:-}"
  PORT="$5"
  STATUS_TIMEOUT_S="$6"
  READY_TIMEOUT_S="$7"
  DRAIN_TIMEOUT_S="$8"
  STABLE_S="$9"
  POLL_S="${10:-5}"
  RESULT_FILE="${11}"
  CONFIG="${12}"
  JOURNAL="${13}"
  HELPER="${14}"
  EXPECTED_BINARY_SHA="${15}"
  EXPECTED_PROVIDER_SHA="${16}"
  EXPECTED_MODEL="${17}"
  EXPECTED_POLICY_SHA="${18}"
  EXPECTED_POLICY_RELEASE="${19}"
  EXPECTED_POLICY_TUPLE="${20}"
  EXPECTED_TEAM_ID="${21}"
  EXPECTED_SIGNING_IDENTIFIER="${22}"
  EXPECTED_CDHASH="${23}"
  TARBALL="" TARBALL_SHA=""
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DOMAIN="gui/$(id -u)"
LA_DIR="${CANARY_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
WATCHDOG_LABEL="$LABEL-watchdog"
[ -n "$SOCKET" ] || SOCKET="$(getconf DARWIN_USER_TEMP_DIR)macprovider-cli/ctl.sock"
BACKUP="$INSTALL_DIR.pre-$VERSION-$TS"
[ "$MODE" = swap ] || BACKUP="$CONFIG.bak-owner-pin-$TS"
FAILED_DIR="$INSTALL_DIR.failed-$VERSION-$TS"
if [ "$MODE" = swap ] && [ "$AIR_ACTION" = restore-air ]; then FAILED_DIR="$FAILED_DIR-$$"; fi
STAGE="$(dirname "$RESULT_FILE")/payload"
LOCK_DIR="$HOME/.macprovider-canary-swap.lock"
MANAGED_FILES="macprovider-cli mlx.metallib compatibility-set.json THIRD-PARTY-NOTICES.txt"
MANAGED_DIRS="catalog-release compatibility-set-local mlx-swift_Cmlx.bundle swift-nio_NIOPosix.bundle"

say() { printf 'canary-window[%s][%s]: %s\n' "$(date -u +%H:%M:%SZ)" "$MODE" "$*" >&2; }
now() { date +%s; }

status_json() { curl -fsS --max-time 5 "http://127.0.0.1:$PORT/v1/status" 2>/dev/null; }

# status_field BODY PATH: dotted path into the status JSON; empty when absent
# or when BODY is not a JSON object.
status_field() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    if not isinstance(v, dict):
        raise ValueError
    for part in sys.argv[1].split("."):
        v = v.get(part) if isinstance(v, dict) else None
except Exception:
    v = None
print("" if v is None else (json.dumps(v) if isinstance(v, bool) else v))' "$2"
}

status_field_sha() {
  printf '%s' "$(status_field "$1" "$2")" | shasum -a 256 | awk '{print $1}'
}

# serving BODY VERSION: the provider runs VERSION with its model loaded and
# serves buyers.
serving() {
  [ "$(status_field "$1" binary_version)" = "$2" ] &&
    [ "$(status_field "$1" model_loaded)" = true ] &&
    [ "$(status_field "$1" network_state)" = buyer_serving ]
}

paused() {
  [ "$(status_field "$1" lifecycle.state)" = paused_by_operator ] ||
    [ "$(status_field "$1" lifecycle.operator_paused)" = true ]
}

control() {
  python3 - "$SOCKET" "$1" <<'PY'
import json, socket, sys
path, frame = sys.argv[1], sys.argv[2]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    s.connect(path)
    s.sendall((json.dumps({"type": frame}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    ack = json.loads(buf.split(b"\n", 1)[0] or b"{}")
except Exception as exc:
    print("control %s failed: %s" % (frame, exc), file=sys.stderr)
    sys.exit(1)
print(json.dumps(ack), file=sys.stderr)
sys.exit(0 if ack.get("accepted") is True else 1)
PY
}

job_pid() {
  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}

verify_binary_identity() {
  local binary="$INSTALL_DIR/macprovider-cli" details team identifier cdhash
  python3 - "$binary" <<'PY' || return 1
import os, stat, sys
path = sys.argv[1]
try:
    info = os.lstat(path)
except OSError:
    sys.exit(1)
if (
    not stat.S_ISREG(info.st_mode)
    or info.st_uid != os.getuid()
    or info.st_nlink != 1
    or os.path.realpath(path) != path
):
    sys.exit(1)
PY
  [ "$(shasum -a 256 "$binary" | awk '{print $1}')" = "$EXPECTED_BINARY_SHA" ] || return 1
  codesign --verify --strict --verbose=2 "$binary" >/dev/null 2>&1 || return 1
  details="$(codesign -d --arch arm64 -vvv "$binary" 2>&1)" || return 1
  team="$(printf '%s\n' "$details" | awk -F= '$1 == "TeamIdentifier" {print $2; exit}')"
  identifier="$(printf '%s\n' "$details" | awk -F= '$1 == "Identifier" {print $2; exit}')"
  cdhash="$(printf '%s\n' "$details" | awk -F= '$1 == "CDHash" {print tolower($2); exit}')"
  [ "$team" = "$EXPECTED_TEAM_ID" ] &&
    [ "$identifier" = "$EXPECTED_SIGNING_IDENTIFIER" ] &&
    [ "$cdhash" = "$EXPECTED_CDHASH" ]
}

verify_launch_plist() {
  python3 - "$LA_DIR/$LABEL.plist" "$INSTALL_DIR/macprovider-cli" "$CONFIG" "$LABEL" <<'PY'
import os, plistlib, stat, sys
path, binary, config, label = sys.argv[1:]
try:
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1 or before.st_size > 64*1024:
        sys.exit(1)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    opened = os.fstat(fd)
    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        sys.exit(1)
    data = os.read(fd, 64*1024 + 1)
    os.close(fd)
    if len(data) != before.st_size or len(data) > 64*1024:
        sys.exit(1)
    value = plistlib.loads(data)
except Exception:
    sys.exit(1)
args, program = value.get("ProgramArguments"), value.get("Program")
expected = os.path.realpath(binary)
config_flags = [i for i, item in enumerate(args or []) if item == "--config"]
if (
    value.get("Label") != label
    or not isinstance(args, list)
    or len(args) != 4
    or not all(isinstance(item, str) for item in args)
    or os.path.realpath(args[0]) != expected
    or (program is not None and (not isinstance(program, str) or os.path.realpath(program) != expected))
    or args[1] != "serve"
    or len(config_flags) != 1
    or config_flags[0] + 1 >= len(args)
    or not os.path.isabs(args[config_flags[0] + 1])
    or os.path.realpath(args[config_flags[0] + 1]) != os.path.realpath(config)
):
    sys.exit(1)
PY
}

# Prints the kernel process start in microseconds after binding launchd's PID
# to the exact canonical executable, uid and real uid. This mirrors the
# released installer's libproc lifecycle-lease identity check.
verify_job_process() {
  local expected_pid="$1" live_pid
  verify_launch_plist || return 1
  live_pid="$(job_pid)"
  [ "$live_pid" = "$expected_pid" ] || return 1
  python3 - "$expected_pid" "$INSTALL_DIR/macprovider-cli" "$(id -u)" <<'PY'
import ctypes, os, sys
class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags",ctypes.c_uint32),("pbi_status",ctypes.c_uint32),("pbi_xstatus",ctypes.c_uint32),
        ("pbi_pid",ctypes.c_uint32),("pbi_ppid",ctypes.c_uint32),("pbi_uid",ctypes.c_uint32),
        ("pbi_gid",ctypes.c_uint32),("pbi_ruid",ctypes.c_uint32),("pbi_rgid",ctypes.c_uint32),
        ("pbi_svuid",ctypes.c_uint32),("pbi_svgid",ctypes.c_uint32),("rfu_1",ctypes.c_uint32),
        ("pbi_comm",ctypes.c_char*16),("pbi_name",ctypes.c_char*32),("pbi_nfiles",ctypes.c_uint32),
        ("pbi_pgid",ctypes.c_uint32),("pbi_pjobc",ctypes.c_uint32),("pbi_e_tdev",ctypes.c_uint32),
        ("pbi_e_tpgid",ctypes.c_uint32),("pbi_nice",ctypes.c_int32),
        ("pbi_start_tvsec",ctypes.c_uint64),("pbi_start_tvusec",ctypes.c_uint64),
    ]
pid, binary, owner = int(sys.argv[1]), os.path.realpath(sys.argv[2]), int(sys.argv[3])
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
proc_pidinfo = libproc.proc_pidinfo
proc_pidinfo.argtypes = [ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
proc_pidinfo.restype = ctypes.c_int
info = ProcBsdInfo()
if proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info)) != ctypes.sizeof(info): sys.exit(1)
buf = ctypes.create_string_buffer(4096)
proc_pidpath = libproc.proc_pidpath
proc_pidpath.argtypes = [ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
proc_pidpath.restype = ctypes.c_int
if proc_pidpath(pid,buf,ctypes.sizeof(buf)) <= 0: sys.exit(1)
start = int(info.pbi_start_tvsec)*1000000 + int(info.pbi_start_tvusec)
path = os.path.realpath(buf.value.decode("utf-8","surrogateescape"))
if start <= 0 or int(info.pbi_uid) != owner or int(info.pbi_ruid) != owner or path != binary: sys.exit(1)
print(start)
PY
}

stop_jobs() {
  launchctl bootout "$DOMAIN/$WATCHDOG_LABEL" 2>/dev/null || true
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  for _ in $(seq 1 60); do
    if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 &&
       ! launchctl print "$DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  say "provider or watchdog job still loaded after 60s bootout"
  return 1
}

# start_jobs: bootstrap the provider and, unless "provider" is passed, its
# watchdog (when installed); fails when a requested job is not loaded
# afterwards. The swap and the rollback start the provider alone: an installed
# watchdog armed for this boot would treat the new process's model-load
# window as a failed /v1/health and kickstart it, which reads as a crash loop.
# The watchdog comes back only once the provider is buyer_serving.
start_jobs() {
  local job ok jobs="$LABEL $WATCHDOG_LABEL"
  [ "${1:-}" = provider ] && jobs="$LABEL"
  for job in $jobs; do
    [ -f "$LA_DIR/$job.plist" ] || continue
    ok=0
    for _ in 1 2 3 4 5; do
      if launchctl bootstrap "$DOMAIN" "$LA_DIR/$job.plist" 2>/dev/null ||
         launchctl print "$DOMAIN/$job" >/dev/null 2>&1; then
        ok=1
        break
      fi
      sleep 2
    done
    [ "$ok" = 1 ] || { say "launchctl bootstrap of $job failed"; return 1; }
  done
}

# start_watchdog: bring the installed watchdog back once the provider serves.
# A failure is reported, not fatal: the provider is already serving.
start_watchdog() {
  [ -f "$LA_DIR/$WATCHDOG_LABEL.plist" ] || return 0
  launchctl print "$DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1 && return 0
  local _
  for _ in 1 2 3 4 5; do
    if launchctl bootstrap "$DOMAIN" "$LA_DIR/$WATCHDOG_LABEL.plist" 2>/dev/null ||
       launchctl print "$DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1; then
      say "watchdog $WATCHDOG_LABEL restarted"
      return 0
    fi
    sleep 2
  done
  say "!!! watchdog $WATCHDOG_LABEL did not start; bootstrap it by hand"
}

require_watchdog() {
  [ -f "$LA_DIR/$WATCHDOG_LABEL.plist" ] || return 0
  start_watchdog
  launchctl print "$DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1 || {
    say "!!! watchdog $WATCHDOG_LABEL is not loaded"
    return 1
  }
}

# wait_serving VERSION: resume (the operator pause outlives a restart) until
# VERSION is buyer_serving and stays so for STABLE_S.
wait_serving() {
  local deadline body ready_at=""
  deadline=$(( $(now) + READY_TIMEOUT_S ))
  while [ "$(now)" -lt "$deadline" ]; do
    body="$(status_json || true)"
    if [ -n "$body" ] && [ "$(status_field "$body" model_loaded)" = true ] && paused "$body"; then
      if [ "$MODE" != swap ]; then
        verify_binary_identity && verify_job_process "$(job_pid)" >/dev/null || return 1
      fi
      control resume_request || true
    fi
    if [ -n "$body" ] && serving "$body" "$1"; then
      [ -n "$ready_at" ] || ready_at="$(now)"
      [ $(( $(now) - ready_at )) -lt "$STABLE_S" ] || return 0
    else
      ready_at=""
    fi
    sleep "$POLL_S"
  done
  return 1
}

PAUSED=0
SWAPPED=0
CONFIG_ARMED=0
FINISHED=0
LOCKED=0
OLD_VERSION=""

# watchdog_note: on an operator-recovery exit the watchdog is deliberately
# left booted out (it would kick a half-restored provider); say so.
watchdog_note() {
  [ -f "$LA_DIR/$WATCHDOG_LABEL.plist" ] || return 0
  launchctl print "$DOMAIN/$WATCHDOG_LABEL" >/dev/null 2>&1 && return 0
  say "!!! watchdog $WATCHDOG_LABEL left unloaded; bootstrap it once the provider is buyer_serving: launchctl bootstrap $DOMAIN '$LA_DIR/$WATCHDOG_LABEL.plist'"
}

# finish RC: the single exit; records RC for the operator side.
finish() {
  FINISHED=1
  trap - EXIT
  [ "$1" != 6 ] || watchdog_note || true
  printf '%s\n' "$1" >"$RESULT_FILE.tmp" && mv "$RESULT_FILE.tmp" "$RESULT_FILE"
  if [ "$MODE" = swap ] && [ "$AIR_ACTION" = restore-air ] && [ "$1" = 5 ]; then
    # Cancellation/completion is durable before releasing the same host lock
    # a delayed original worker must acquire before touching the provider.
    python3 - "$(dirname "$RESULT_FILE")/result.restored" <<'PY' || exit 6
import os, sys, tempfile
path=sys.argv[1]
fd, temporary=tempfile.mkstemp(dir=os.path.dirname(path),prefix=".air-terminal-")
with os.fdopen(fd,"w") as stream:
    stream.write("5\n"); stream.flush(); os.fsync(stream.fileno())
os.replace(temporary,path)
directory=os.open(os.path.dirname(path),os.O_RDONLY)
try: os.fsync(directory)
finally: os.close(directory)
PY
  fi
  if [ "$LOCKED" = 1 ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
  exit "$1"
}

restore_backup() {
  if [ "$MODE" != swap ]; then
    restore_config "$1"
  fi
  FINISHED=1
  say "ROLLBACK: restoring $BACKUP ($1)"
  if [ -n "$AIR_PROVIDER_SHA" ]; then
    python3 - "$(dirname "$RESULT_FILE")/result.recovery.json" <<'PY' || finish 6
import json, os, sys, tempfile
path=sys.argv[1]
with open(path) as stream: record=json.load(stream)
record["phase"]="restoring"
fd, temporary=tempfile.mkstemp(dir=os.path.dirname(path), prefix=".air-restore-")
with os.fdopen(fd,"w") as stream:
    json.dump(record,stream); stream.flush(); os.fsync(stream.fileno())
os.replace(temporary,path)
directory=os.open(os.path.dirname(path),os.O_RDONLY)
try: os.fsync(directory)
finally: os.close(directory)
PY
  fi
  stop_jobs || { say "!!! rollback could not stop the candidate job; restore $BACKUP into $INSTALL_DIR by hand"; finish 6; }
  if [ -e "$INSTALL_DIR" ]; then
    mv "$INSTALL_DIR" "$FAILED_DIR" || { say "!!! could not move the candidate payload aside; restore $BACKUP by hand"; finish 6; }
  elif [ -z "$AIR_PROVIDER_SHA" ]; then
    finish 6
  fi
  cp -Rp "$BACKUP" "$INSTALL_DIR" || { say "!!! could not copy $BACKUP back to $INSTALL_DIR; do it by hand"; finish 6; }
  start_jobs provider || { say "!!! restored $BACKUP but the provider job did not start; bootstrap $LABEL by hand"; finish 6; }
  if [ -n "$AIR_PROVIDER_SHA" ]; then
    # The signed incumbent was disconnected before recovery. Restoring that
    # exact zero-work state is a successful rollback, not a buyer-serving claim.
    local air_deadline air_body air_pid air_start air_since
    air_deadline=$(( $(now) + READY_TIMEOUT_S ))
    while :; do
      air_pid="$(job_pid)"
      if [ -n "$air_pid" ] && air_start="$(verify_job_process "$air_pid")"; then break; fi
      [ "$(now)" -lt "$air_deadline" ] || finish 6
      sleep "$POLL_S"
    done
    air_since=0
    while :; do
      [ "$(job_pid)" = "$air_pid" ] && [ "$(verify_job_process "$air_pid")" = "$air_start" ] || finish 6
      air_body="$(status_json || true)"
      if [ "$(status_field "$air_body" binary_version)" = "$OLD_VERSION" ] &&
         [ "$(status_field_sha "$air_body" provider_id)" = "$AIR_PROVIDER_SHA" ] &&
         [ "$(status_field "$air_body" requests_in_flight)" = 0 ] &&
         [ "$(status_field "$air_body" lifecycle.operator_paused)" != true ] &&
         [ "$(shasum -a 256 "$INSTALL_DIR/macprovider-cli" | awk '{print $1}')" = "$AIR_OLD_BINARY_SHA" ]; then
        [ "$air_since" != 0 ] || air_since="$(now)"
        if [ $(( $(now) - air_since )) -lt "$STABLE_S" ]; then sleep "$POLL_S"; continue; fi
        codesign --verify --strict "$INSTALL_DIR/macprovider-cli" >/dev/null 2>&1 || finish 6
        require_watchdog || finish 6
        say "ROLLBACK done: exact signed Air incumbent restored; buyer readiness is not claimed"
        finish 5
      fi
      air_since=0
      [ "$(now)" -lt "$air_deadline" ] || finish 6
      sleep "$POLL_S"
    done
  elif ! wait_serving "$OLD_VERSION"; then
    say "!!! restored $BACKUP but $OLD_VERSION is not buyer_serving within ${READY_TIMEOUT_S}s; check the provider and send resume_request on $SOCKET"
    finish 6
  fi
  start_watchdog
  say "ROLLBACK done: $OLD_VERSION buyer_serving again; failed payload kept at $FAILED_DIR"
  finish 5
}

config_postconditions() {
  [ "$(status_field "$1" binary_version)" = "$VERSION" ] &&
    [ "$(status_field_sha "$1" provider_id)" = "$EXPECTED_PROVIDER_SHA" ] &&
    [ "$(status_field "$1" model)" = "$EXPECTED_MODEL" ] &&
    [ "$(status_field "$1" capacity.max_concurrency)" = 4 ] &&
    [ "$(status_field "$1" continuous_batching.active)" = true ] &&
    [ "$(status_field "$1" continuous_batching.policy.load_status)" = live_verified ] &&
    [ "$(status_field "$1" continuous_batching.policy.authorized)" = true ] &&
    [ "$(status_field "$1" continuous_batching.policy.policy_sha256)" = "$EXPECTED_POLICY_SHA" ] &&
    [ "$(status_field "$1" continuous_batching.policy.release_id)" = "$EXPECTED_POLICY_RELEASE" ] &&
    [ "$(status_field "$1" continuous_batching.policy.tuple_sha256)" = "$EXPECTED_POLICY_TUPLE" ] &&
    [ "$(status_field "$1" continuous_batching.self_check.served_slots)" = 4 ] &&
    [ "$(status_field "$1" continuous_batching.scheduler.slots_total)" = 4 ] &&
    [ "$(status_field "$1" coordinator.connected)" = true ] &&
    [ "$(status_field "$1" lifecycle.operator_paused)" != true ]
}

restore_config() {
  local result_code="${2:-5}" recovered_pid recovered_start body
  FINISHED=1
  say "ROLLBACK: restoring the 4/owner pin ($1)"
  stop_jobs || { say "!!! rollback could not stop the provider; journal retained"; finish 6; }
  python3 "$HELPER" restore --config "$CONFIG" --journal "$JOURNAL" || {
    say "!!! scoped pin restore refused; journal and protected backup retained"; finish 6;
  }
  if ! verify_binary_identity || ! verify_launch_plist; then
    say "!!! pin restored but signed executable identity is not exact; provider and watchdog remain stopped; journal retained"
    finish 6
  fi
  start_jobs provider || { say "!!! pin restored but provider did not start; journal retained"; finish 6; }
  recovered_pid="$(job_pid)"
  recovered_start="$(verify_job_process "$recovered_pid")" || {
    say "!!! pin restored but launched process is not the exact signed executable; journal retained"; stop_jobs || true; finish 6;
  }
  if ! wait_serving "$VERSION"; then
    say "!!! pin restored but $VERSION is not buyer_serving within ${READY_TIMEOUT_S}s; journal retained"
    finish 6
  fi
  body="$(status_json || true)"
  if ! config_postconditions "$body"; then
    say "!!! pin restored but serving status does not preserve the signed four-slot tuple; journal retained"
    finish 6
  fi
  [ "$(status_field "$body" service_instance.pid)" = "$recovered_pid" ] &&
    [ "$(verify_job_process "$recovered_pid")" = "$recovered_start" ] || {
      say "!!! recovered provider process identity changed; journal retained"; finish 6;
    }
  require_watchdog || { say "!!! pin restored but watchdog is not loaded; journal retained"; finish 6; }
  python3 "$HELPER" finish --config "$CONFIG" --journal "$JOURNAL" --restored || {
    say "!!! provider recovered but restore journal could not be finalized"; finish 6;
  }
  say "ROLLBACK done: exact 4/owner pin restored and $VERSION buyer_serving"
  finish "$result_code"
}

# shellcheck disable=SC2329  # EXIT trap
on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$FINISHED" = 1 ]; then
    say "!!! recovery stopped unexpectedly (exit $rc); check $INSTALL_DIR against $BACKUP"
    finish 6
  fi
  if [ "$CONFIG_ARMED" = 1 ]; then
    restore_config "unexpected exit $rc during the owner-pin transaction"
  fi
  if [ "$SWAPPED" = 1 ]; then
    restore_backup "unexpected exit $rc during the swap"
  fi
  if [ "$PAUSED" = 1 ] && ! wait_serving "$OLD_VERSION"; then
    say "!!! provider may still be PAUSED or not serving; send resume_request on $SOCKET"
    finish 6
  fi
  case "$rc" in 4) finish 4 ;; *) finish 6 ;; esac
}
trap on_exit EXIT
if [ "$MODE" = swap ]; then
  trap 'say "ignoring SIGHUP"' HUP
else
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
fi

refuse() { say "REFUSED: $*"; exit 4; }

# --- preflight: nothing touched yet -----------------------------------------
# One swap at a time on this Mac, whichever operator Mac started it. The lock
# is published with its owner pid already inside (rename of a prepared dir),
# so no run ever sees an ownerless lock; one without a readable pid is busy.
lock_refused() {
  say "REFUSED: $1"
  trap - EXIT
  printf '4\n' >"$RESULT_FILE"
  exit 4
}
publish_lock() {
  python3 - "$LOCK_DIR" "$$" <<'PY'
import os, sys, tempfile
lock, pid = sys.argv[1], sys.argv[2]
prep = tempfile.mkdtemp(prefix=os.path.basename(lock) + ".init.", dir=os.path.dirname(lock))
with open(os.path.join(prep, "pid"), "w") as f:
    f.write(pid + "\n")
try:
    os.rename(prep, lock)  # fails when lock exists and is not empty
except OSError:
    os.remove(os.path.join(prep, "pid")); os.rmdir(prep)
    sys.exit(1)
PY
}
if ! publish_lock; then
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  case "$holder" in ''|*[!0-9]*) lock_refused "canary-swap lock $LOCK_DIR has no owner pid; remove it by hand if no swap runs" ;; esac
  kill -0 "$holder" 2>/dev/null && lock_refused "another canary swap (pid $holder) is running on this Mac"
  # Stale owner: only the run whose rename wins may publish again.
  mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null || lock_refused "could not take over the canary-swap lock"
  rm -rf "$LOCK_DIR.stale.$$"
  publish_lock || lock_refused "could not take over the canary-swap lock"
  say "took over stale canary-swap lock (pid $holder)"
fi
LOCKED=1
if [ "$MODE" = swap ] && [ -n "$AIR_PROVIDER_SHA" ] && [ "$AIR_ACTION" = recover-air ] &&
   [ -f "$(dirname "$RESULT_FILE")/result.restored" ]; then
  refuse "this Air dispatch was cancelled/restored before its worker started"
fi

case "$INSTALL_DIR" in
  "$HOME"/?*) ;;
  *) refuse "install dir $INSTALL_DIR is not under $HOME" ;;
esac
case "$INSTALL_DIR" in *"/../"*|*/..|*"/./"*|*/.|*//*) refuse "install dir $INSTALL_DIR is not canonical" ;; esac
[ ! -L "$INSTALL_DIR" ] || refuse "install dir $INSTALL_DIR is a symlink"
if [ "$MODE" = swap ] && [ "$AIR_ACTION" = restore-air ] && [ ! -e "$INSTALL_DIR" ]; then
  [ "$(cd "$(dirname "$INSTALL_DIR")" && pwd -P)" = "$(dirname "$INSTALL_DIR")" ] &&
    [ -O "$(dirname "$INSTALL_DIR")" ] || refuse "Air recovery parent is not canonical and owner-owned"
else
[ -d "$INSTALL_DIR" ] || refuse "install dir $INSTALL_DIR is missing"
# No symlinked ancestor below $HOME either: the physical path must be the
# lexical one, so every mv/cp/rm below stays inside it.
[ "$(cd "$INSTALL_DIR" && pwd -P)" = "$(cd "$HOME" && pwd -P)/${INSTALL_DIR#"$HOME"/}" ] ||
  refuse "install dir $INSTALL_DIR resolves through a symlink"
[ -O "$INSTALL_DIR" ] || refuse "install dir $INSTALL_DIR is not owned by $(id -un)"
fi
[ "$MODE" != swap ] || { [ ! -e "$BACKUP" ] && [ ! -e "$FAILED_DIR" ]; } || refuse "backup path $BACKUP already exists"
[ -f "$LA_DIR/$LABEL.plist" ] || refuse "missing LaunchAgent $LA_DIR/$LABEL.plist"
[ "$MODE" = swap ] || {
  case "$CONFIG" in "$HOME"/?*) ;; *) refuse "config is not under HOME" ;; esac
  case "$JOURNAL" in "$HOME"/?*) ;; *) refuse "journal is not under HOME" ;; esac
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] && [ -O "$CONFIG" ] || refuse "config is missing, symlinked, or not owner-owned"
  [ -f "$HELPER" ] && [ ! -L "$HELPER" ] && [ -O "$HELPER" ] || refuse "config helper is missing, symlinked, or not owner-owned"
}

if [ "$MODE" = swap ] && [ "$AIR_ACTION" = restore-air ]; then
  CONFIG="$AIR_CONFIG"
  [ "$VERSION" = 1.8.260 ] && [ "$(sysctl -n hw.model)" = Mac15,12 ] &&
    [ "$(sysctl -n hw.memsize)" = 17179869184 ] || refuse "Air payload restore identity mismatch"
  verify_launch_plist || refuse "Air restore LaunchAgent mismatch"
  [ -f "$AIR_CONFIG" ] && [ ! -L "$AIR_CONFIG" ] && [ -O "$AIR_CONFIG" ] || refuse "Air baseline config is not an owned regular file"
  [ "$(shasum -a 256 "$AIR_CONFIG" | awk '{print $1}')" = "$AIR_CONFIG_SHA" ] || refuse "Air baseline config changed"
  if [ ! -e "$(dirname "$RESULT_FILE")/result.recovery.json" ]; then
    # The same host lock excludes a live worker. An unchanged authenticated
    # incumbent proves the pre-armed window; result.restored seals cancellation
    # against a delayed original worker after this lock is released.
    [ -f "$INSTALL_DIR/macprovider-cli" ] && [ ! -L "$INSTALL_DIR/macprovider-cli" ] || refuse "pre-armed Air incumbent is absent"
    [ "$(shasum -a 256 "$INSTALL_DIR/macprovider-cli" | awk '{print $1}')" = "$AIR_OLD_BINARY_SHA" ] || refuse "pre-armed Air bytes changed"
    codesign --verify --strict "$INSTALL_DIR/macprovider-cli" >/dev/null 2>&1 || refuse "pre-armed incumbent signature invalid"
    body="$(status_json)" || refuse "pre-armed incumbent status is unavailable"
    [ "$(status_field "$body" binary_version)" = 1.8.258 ] &&
      [ "$(status_field_sha "$body" provider_id)" = "$AIR_PROVIDER_SHA" ] &&
      [ "$(status_field "$body" coordinator.connected)" = false ] &&
      [ "$(status_field "$body" requests_in_flight)" = 0 ] &&
      [ "$(status_field "$body" lifecycle.operator_paused)" != true ] || refuse "pre-armed incumbent is not the untouched Air baseline"
    verify_job_process "$(job_pid)" >/dev/null || refuse "pre-armed incumbent process mismatch"
    finish 5
  fi
  BACKUP="$(python3 - "$(dirname "$RESULT_FILE")/result.recovery.json" "$INSTALL_DIR" "$AIR_CONFIG" "$AIR_PROVIDER_SHA" "$AIR_OLD_BINARY_SHA" "$TARBALL_SHA" <<'PY'
import hashlib, json, os, pathlib, stat, sys
path, install, config, provider, binary_sha, target_sha = sys.argv[1:]
info=os.lstat(path)
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077: raise SystemExit(1)
d=json.load(open(path))
if d.get("schema_version")!="macprovider.air_payload_recovery.v1" or d.get("install_dir")!=install or d.get("provider_id_sha256")!=provider or d.get("incumbent_binary_sha256")!=binary_sha or d.get("target_tarball_sha256")!=target_sha: raise SystemExit(1)
if pathlib.Path(config).is_symlink() or hashlib.sha256(pathlib.Path(config).read_bytes()).hexdigest()!=d.get("config_sha256"): raise SystemExit(1)
backup=pathlib.Path(d["backup_path"])
if backup.parent!=pathlib.Path(install).parent or not backup.name.startswith(pathlib.Path(install).name+".pre-1.8.260-") or backup.resolve()!=backup or not backup.is_dir(): raise SystemExit(1)
binary=backup/"macprovider-cli"
if binary.is_symlink() or hashlib.sha256(binary.read_bytes()).hexdigest()!=binary_sha: raise SystemExit(1)
if not pathlib.Path(install).exists() and d.get("phase")!="restoring": raise SystemExit(1)
print(backup)
PY
)" || refuse "Air recovery record/backup/config cannot be authenticated"
  codesign --verify --strict "$BACKUP/macprovider-cli" >/dev/null 2>&1 || refuse "Air recovery backup signature invalid"
  OLD_VERSION=1.8.258
  SWAPPED=1
  restore_backup "journal-first explicit Air payload recovery"
fi

if [ "$MODE" = restore-owner-pin ]; then
  [ -f "$JOURNAL" ] || refuse "no unfinished owner-pin journal to restore"
  CONFIG_ARMED=1
  restore_config "operator recovery" 0
fi

if [ "$MODE" = remove-owner-pin ]; then
  verify_binary_identity || refuse "installed CLI signed identity changed"
  verify_launch_plist || refuse "provider LaunchAgent does not execute the signed CLI path"
  body="$(status_json)" || refuse "live /v1/status on :$PORT is not answering"
  OLD_VERSION="$(status_field "$body" binary_version)"
  [ "$OLD_VERSION" = "$VERSION" ] || refuse "live binary version ${OLD_VERSION:-none} != $VERSION"
  serving "$body" "$VERSION" || refuse "the provider is not buyer_serving on $VERSION"
  config_postconditions "$body" || refuse "live status is not the exact signed four-slot GLM tuple"
  old_pid="$(job_pid)"
  [ -n "$old_pid" ] || refuse "provider job has no pid"
  [ "$(status_field "$body" service_instance.pid)" = "$old_pid" ] || refuse "status and launchd provider pid differ"
  verify_job_process "$old_pid" >/dev/null || refuse "live provider process is not the signed CLI path"
  provider_hash="$(status_field_sha "$body" provider_id)"
  python3 "$HELPER" prepare --config "$CONFIG" --journal "$JOURNAL" --backup "$BACKUP" \
    --version "$VERSION" --provider-id-sha256 "$provider_hash" --model "$EXPECTED_MODEL" \
    --policy-sha256 "$EXPECTED_POLICY_SHA" --policy-release-id "$EXPECTED_POLICY_RELEASE" \
    --policy-tuple-sha256 "$EXPECTED_POLICY_TUPLE" --binary-sha256 "$EXPECTED_BINARY_SHA" \
    --team-id "$EXPECTED_TEAM_ID" --signing-identifier "$EXPECTED_SIGNING_IDENTIFIER" \
    --cdhash "$EXPECTED_CDHASH" --executable-path "$INSTALL_DIR/macprovider-cli" ||
    refuse "could not arm the owner-pin journal"
  CONFIG_ARMED=1
  PAUSED=1
  control pause_request || refuse "pause_request was not accepted on $SOCKET"
  deadline=$(( $(now) + DRAIN_TIMEOUT_S ))
  while :; do
    body="$(status_json || true)"
    inflight="$(status_field "$body" requests_in_flight)"
    [ "$inflight" = 0 ] && break
    [ "$(now)" -lt "$deadline" ] || refuse "requests_in_flight=${inflight:-unknown} after ${DRAIN_TIMEOUT_S}s drain"
    sleep "$POLL_S"
  done
  stop_jobs || restore_config "provider job did not stop"
  python3 "$HELPER" apply --config "$CONFIG" --journal "$JOURNAL" || restore_config "scoped config mutation failed"
  verify_binary_identity || restore_config "signed executable identity changed before config validation"
  "$INSTALL_DIR/macprovider-cli" provider context explain --config "$CONFIG" --port "$PORT" >/dev/null ||
    restore_config "released CLI rejected the unpinned config"
  verify_binary_identity || restore_config "signed executable identity changed before bootstrap"
  verify_launch_plist || restore_config "provider LaunchAgent changed before bootstrap"
  start_jobs provider || restore_config "provider job did not start"
  start="$(now)"; pid0=""
  while [ -z "$pid0" ]; do
    pid0="$(job_pid)"
    [ -n "$pid0" ] && break
    [ $(( $(now) - start )) -lt 15 ] || restore_config "provider job has no process 15s after bootstrap"
    sleep 1
  done
  [ "$pid0" != "$old_pid" ] || restore_config "provider restart kept the old pid $old_pid"
  process_start="$(verify_job_process "$pid0")" || restore_config "launched provider is not the exact signed executable"
  last_answer="$start"; loaded=0; ready_at=""
  while :; do
    t="$(now)"; pid="$(job_pid)"
    [ "$pid" = "$pid0" ] || restore_config "provider process restarted (pid $pid0 -> ${pid:-none}): crash loop"
    [ "$(verify_job_process "$pid0")" = "$process_start" ] || restore_config "provider process identity changed during readiness"
    body="$(status_json || true)"
    if [ -n "$body" ]; then
      last_answer="$t"
      [ "$(status_field "$body" binary_version)" = "$VERSION" ] || restore_config "status binary identity changed"
      if [ "$(status_field "$body" model_loaded)" = true ]; then
        loaded=1
        paused "$body" && control resume_request || true
      fi
      if serving "$body" "$VERSION" && config_postconditions "$body"; then
        [ -n "$ready_at" ] || ready_at="$t"
        [ $(( t - ready_at )) -lt "$STABLE_S" ] || break
      else
        ready_at=""
      fi
    elif [ "$loaded" = 1 ] && [ $(( t - last_answer )) -ge "$STATUS_TIMEOUT_S" ]; then
      restore_config "/v1/status silent after model load"
    fi
    [ $(( t - start )) -lt "$READY_TIMEOUT_S" ] || restore_config "not buyer_serving on the signed four-slot tuple within ${READY_TIMEOUT_S}s"
    sleep "$POLL_S"
  done
  verify_binary_identity || restore_config "signed executable identity changed after readiness"
  [ "$(verify_job_process "$pid0")" = "$process_start" ] || restore_config "provider process identity changed after readiness"
  require_watchdog || restore_config "watchdog did not return after readiness"
  [ "$(verify_job_process "$pid0")" = "$process_start" ] || restore_config "watchdog restart changed the accepted provider process"
  python3 "$HELPER" accept --config "$CONFIG" --journal "$JOURNAL" --pid "$pid0" \
    --process-start-us "$process_start" --executable-path "$INSTALL_DIR/macprovider-cli" ||
    restore_config "could not durably bind the accepted provider process"
  # The controller keeps the journal armed through the provider-attributed
  # gateway proof. It either finalizes it after that proof or dispatches this
  # script's restore-owner-pin mode on every failure/signal.
  CONFIG_ARMED=0
  say "OK: owner pin removed; $VERSION buyer_serving at four slots (pid $pid0 start $process_start)"
  finish 0
fi

[ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" = "$TARBALL_SHA" ] || refuse "staged tarball sha256 differs from the verified candidate"

# Members are checked from the archive headers before anything is extracted:
# relative names only, regular files and directories only, no duplicates.
rm -rf "$STAGE"
mkdir -p "$STAGE"
python3 - "$TARBALL" "$STAGE" <<'PY' || refuse "candidate tarball has unsafe or unexpected members"
import os, sys, tarfile
src, dest = sys.argv[1], sys.argv[2]
with tarfile.open(src, "r:gz") as tar:
    members, seen = tar.getmembers(), set()
    for m in members:
        name = os.path.normpath(m.name)
        if m.name.startswith("/") or name == ".." or name.startswith("../") or name in seen:
            sys.exit("unsafe member name: %r" % m.name)
        if not (m.isfile() or m.isdir()):
            sys.exit("non-regular member: %r" % m.name)
        seen.add(name)
    for m in members:
        tar.extract(m, dest, set_attrs=False)
PY
[ -f "$STAGE/macprovider-cli" ] && [ -f "$STAGE/mlx.metallib" ] || refuse "candidate payload lacks macprovider-cli or mlx.metallib"
chmod 755 "$STAGE/macprovider-cli"
staged_version="$("$STAGE/macprovider-cli" --version | tr -d '\r\n')"
[ "$staged_version" = "$VERSION" ] || refuse "staged macprovider-cli reports $staged_version, expected $VERSION"
body="$(status_json)" || refuse "live /v1/status on :$PORT is not answering; not swapping an unhealthy provider"
OLD_VERSION="$(status_field "$body" binary_version)"
[ -n "$OLD_VERSION" ] || refuse "live /v1/status reports no binary_version"
[ "$OLD_VERSION" != "$VERSION" ] || refuse "the canary already runs $VERSION"
if [ -n "$AIR_PROVIDER_SHA" ]; then
  # The only non-serving swap is the explicitly bound, signed Air recovery.
  [ "$VERSION" = 1.8.260 ] && [ "$OLD_VERSION" = 1.8.258 ] || refuse "Air recovery version mismatch"
  [ "$(sysctl -n hw.model)" = Mac15,12 ] && [ "$(sysctl -n hw.memsize)" = 17179869184 ] || refuse "Air recovery hardware mismatch"
  [ "$(status_field_sha "$body" provider_id)" = "$AIR_PROVIDER_SHA" ] || refuse "Air recovery provider mismatch"
  [ "$(status_field "$body" coordinator.connected)" = false ] && [ "$(status_field "$body" requests_in_flight)" = 0 ] || refuse "Air recovery requires disconnected zero-inflight incumbent"
  [ "$(status_field "$body" lifecycle.operator_paused)" != true ] || refuse "Air recovery cannot override operator pause"
  [ "$(shasum -a 256 "$INSTALL_DIR/macprovider-cli" | awk '{print $1}')" = "$AIR_OLD_BINARY_SHA" ] || refuse "Air recovery incumbent bytes changed"
  [ "$(shasum -a 256 "$AIR_CONFIG" | awk '{print $1}')" = "$AIR_CONFIG_SHA" ] || refuse "Air recovery config changed"
  codesign --verify --strict "$INSTALL_DIR/macprovider-cli" >/dev/null 2>&1 || refuse "Air recovery incumbent signature is invalid"
  CONFIG="$AIR_CONFIG"
  verify_launch_plist || refuse "Air recovery LaunchAgent mismatch"
  verify_job_process "$(job_pid)" >/dev/null || refuse "Air recovery process mismatch"
else
  serving "$body" "$OLD_VERSION" || refuse "the canary is not buyer_serving on $OLD_VERSION; not swapping"
fi
say "preflight ok: live $OLD_VERSION -> candidate $VERSION"

# --- pause and drain -------------------------------------------------------
# Marked before sending: an accepted pause whose ack is lost still gets resumed.
PAUSED=1
if [ -z "$AIR_PROVIDER_SHA" ]; then
  control pause_request || refuse "pause_request was not accepted on $SOCKET"
else
  # Recheck immediately before stopping: never discard work admitted meanwhile.
  body="$(status_json)" || refuse "Air recovery lost incumbent status"
  [ "$(status_field "$body" coordinator.connected)" = false ] && [ "$(status_field "$body" requests_in_flight)" = 0 ] || refuse "Air recovery incumbent became active"
fi
deadline=$(( $(now) + DRAIN_TIMEOUT_S ))
while :; do
  body="$(status_json || true)"
  inflight="$(status_field "$body" requests_in_flight)"
  [ "$inflight" = 0 ] && break
  [ "$(now)" -lt "$deadline" ] || refuse "requests_in_flight=${inflight:-unknown} after ${DRAIN_TIMEOUT_S}s drain"
  sleep "$POLL_S"
done
say "drained in_flight=0"

# --- swap ------------------------------------------------------------------
cp -Rp "$INSTALL_DIR" "$BACKUP" || refuse "could not back up $INSTALL_DIR"
say "backup=$BACKUP"
if [ -n "$AIR_PROVIDER_SHA" ]; then
  # Detached operation metadata survives controller loss; no config or tokens.
  python3 - "$RESULT_FILE.recovery.json" "$BACKUP" "$INSTALL_DIR" "$AIR_PROVIDER_SHA" "$AIR_OLD_BINARY_SHA" "$TARBALL_SHA" "$AIR_CONFIG" <<'PY' || refuse "could not arm Air payload recovery record"
import hashlib, json, os, sys
path, backup, install, provider, old_sha, target_sha, config = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as stream:
    json.dump({"schema_version":"macprovider.air_payload_recovery.v1", "phase":"armed",
               "backup_path":backup, "install_dir":install, "provider_id_sha256":provider,
               "incumbent_binary_sha256":old_sha, "target_tarball_sha256":target_sha,
               "config_sha256":hashlib.sha256(open(config,"rb").read()).hexdigest()}, stream)
    stream.flush(); os.fsync(stream.fileno())
directory = os.open(os.path.dirname(path), os.O_RDONLY)
try: os.fsync(directory)
finally: os.close(directory)
PY
fi
SWAPPED=1
stop_jobs || restore_backup "provider job did not stop"
for f in $MANAGED_FILES; do
  rm -f "$INSTALL_DIR/$f"
  [ ! -f "$STAGE/$f" ] || cp "$STAGE/$f" "$INSTALL_DIR/$f"
done
for d in $MANAGED_DIRS; do
  rm -rf "${INSTALL_DIR:?}/$d"
  [ ! -d "$STAGE/$d" ] || cp -R "$STAGE/$d" "$INSTALL_DIR/$d"
done
chmod 755 "$INSTALL_DIR/macprovider-cli"
cmp "$STAGE/macprovider-cli" "$INSTALL_DIR/macprovider-cli" || restore_backup "installed binary differs from the staged candidate"
start_jobs provider || restore_backup "provider job did not start"
say "restarted on $VERSION"

# --- watch: crash loop, exit or post-load status silence restores the backup -
# A pid change (crash loop) or a process that exited (launchd reports no pid)
# fails at once. /v1/status silence
# while the model loads is not a failure: the model-load window of a large
# model is bounded by READY_TIMEOUT_S alone. Once the candidate has reported
# model_loaded, a silence of STATUS_TIMEOUT_S is a hang and fails.
start="$(now)"
pid0=""
while [ -z "$pid0" ]; do
  pid0="$(job_pid)"
  [ -n "$pid0" ] && break
  [ $(( $(now) - start )) -lt 15 ] || restore_backup "provider job has no process 15s after bootstrap"
  sleep 1
done
last_answer="$start"
loaded=0
ready_at=""
while :; do
  t="$(now)"
  pid="$(job_pid)"
  [ "$pid" = "$pid0" ] || restore_backup "provider process restarted (pid $pid0 -> ${pid:-none}): crash loop"
  body="$(status_json || true)"
  if [ -n "$body" ]; then
    last_answer="$t"
    running="$(status_field "$body" binary_version)"
    [ "$running" = "$VERSION" ] || restore_backup "/v1/status reports binary_version ${running:-none}, expected $VERSION"
    if [ "$(status_field "$body" model_loaded)" = true ]; then
      [ "$loaded" = 1 ] || say "model loaded on $VERSION after $(( t - start ))s"
      loaded=1
      if paused "$body"; then
        control resume_request || true
      fi
    fi
    if serving "$body" "$VERSION"; then
      if [ -z "$ready_at" ]; then
        ready_at="$t"
        say "buyer_serving on $VERSION; holding ${STABLE_S}s for a crash"
      fi
      [ $(( t - ready_at )) -lt "$STABLE_S" ] || break
    else
      ready_at=""
    fi
  elif [ "$loaded" = 1 ] && [ $(( t - last_answer )) -ge "$STATUS_TIMEOUT_S" ]; then
    restore_backup "/v1/status not answering for ${STATUS_TIMEOUT_S}s after the model loaded"
  fi
  [ $(( t - start )) -lt "$READY_TIMEOUT_S" ] || restore_backup "not buyer_serving within ${READY_TIMEOUT_S}s"
  sleep "$POLL_S"
done
start_watchdog
say "OK: canary serves $VERSION (pid $pid0); previous payload kept at $BACKUP"
finish 0
