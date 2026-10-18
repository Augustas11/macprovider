#!/bin/bash
# Runs ON the canary Mac; scripts/ops/canary-swap.sh sends it over STUDIO_SSH
# as `bash -s -- ARGS`. bash 3.2 compatible (stock macOS /bin/bash).
#
# Payload-only swap of the live provider to a verified candidate tarball:
# pause and drain, back up the install dir, replace the payload, restart, then
# watch. A process restart (crash loop) or a /v1/status silence longer than
# STATUS_TIMEOUT_S restores the backup and resumes the provider. Config and
# LaunchAgents are never edited.
#
# Exit codes: 0 swapped and buyer-serving; 4 refused before the swap (nothing
# changed, provider resumed); 5 candidate failed and the backup was restored;
# 6 the restore itself needs the operator (message says what is left).
set -euo pipefail
export PATH="${CANARY_REMOTE_PATH_PREFIX:+$CANARY_REMOTE_PATH_PREFIX:}/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

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

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DOMAIN="gui/$(id -u)"
LA_DIR="${CANARY_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
WATCHDOG_LABEL="$LABEL-watchdog"
[ -n "$SOCKET" ] || SOCKET="$(getconf DARWIN_USER_TEMP_DIR)macprovider-cli/ctl.sock"
BACKUP="$INSTALL_DIR.pre-$VERSION-$TS"
STAGE="$(dirname "$TARBALL")/payload"

say() { printf 'canary-swap[%s]: %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
now() { date +%s; }

status_json() { curl -fsS --max-time 5 "http://127.0.0.1:$PORT/v1/status" 2>/dev/null; }

# status_field BODY PATH: dotted path into the status JSON; empty when absent.
status_field() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    for part in sys.argv[1].split("."):
        v = v.get(part) if isinstance(v, dict) else None
except Exception:
    v = None
print("" if v is None else (json.dumps(v) if isinstance(v, bool) else v))' "$2"
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

stop_jobs() {
  launchctl bootout "$DOMAIN/$WATCHDOG_LABEL" 2>/dev/null || true
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  for _ in $(seq 1 60); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
    sleep 1
  done
  say "provider job still loaded after 60s bootout"
  return 1
}

start_jobs() {
  local job
  for job in "$LABEL" "$WATCHDOG_LABEL"; do
    [ -f "$LA_DIR/$job.plist" ] || continue
    for _ in 1 2 3 4 5; do
      launchctl bootstrap "$DOMAIN" "$LA_DIR/$job.plist" 2>/dev/null && break
      sleep 2
    done
  done
}

# resume_until_running: the operator pause outlives a restart, so the provider
# comes back paused until it accepts resume_request.
resume_until_running() {
  local deadline body state
  deadline=$(( $(now) + READY_TIMEOUT_S ))
  while [ "$(now)" -lt "$deadline" ]; do
    body="$(status_json || true)"
    if [ -n "$body" ]; then
      state="$(status_field "$body" lifecycle.state)"
      if [ "$state" != paused_by_operator ] && [ "$(status_field "$body" lifecycle.operator_paused)" != true ]; then
        return 0
      fi
      control resume_request || true
    fi
    sleep "$POLL_S"
  done
  return 1
}

PAUSED=0
SWAPPED=0
FINISHED=0

restore_backup() {
  # Runs once: its own exits must not re-enter on_exit's restore.
  FINISHED=1
  say "ROLLBACK: restoring $BACKUP ($1)"
  if ! stop_jobs; then
    say "!!! rollback could not stop the candidate job; restore $BACKUP into $INSTALL_DIR by hand"
    exit 6
  fi
  rm -rf "$INSTALL_DIR.failed-$VERSION-$TS"
  mv "$INSTALL_DIR" "$INSTALL_DIR.failed-$VERSION-$TS"
  cp -Rp "$BACKUP" "$INSTALL_DIR"
  start_jobs
  if ! resume_until_running; then
    say "!!! restored $BACKUP but the provider is not answering resumed; send resume_request on $SOCKET"
    exit 6
  fi
  local body
  body="$(status_json || true)"
  say "ROLLBACK done: binary_version $(status_field "$body" binary_version), network_state $(status_field "$body" network_state); failed payload kept at $INSTALL_DIR.failed-$VERSION-$TS"
  exit 5
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$FINISHED" = 1 ]; then
    case "$rc" in
      0|5|6) ;;
      *) say "!!! rollback did not complete (exit $rc): restore $BACKUP into $INSTALL_DIR and resume by hand" ;;
    esac
    exit "$rc"
  fi
  if [ "$SWAPPED" = 1 ]; then
    restore_backup "unexpected exit $rc during the swap"
  fi
  if [ "$PAUSED" = 1 ]; then
    resume_until_running || say "!!! provider may still be PAUSED; send resume_request on $SOCKET"
  fi
  exit "$rc"
}
trap on_exit EXIT

refuse() { say "REFUSED: $*"; exit 4; }

# --- preflight: nothing touched yet -----------------------------------------
[ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" = "$TARBALL_SHA" ] || refuse "staged tarball sha256 differs from the verified candidate"
[ -d "$INSTALL_DIR" ] || refuse "missing install dir $INSTALL_DIR"
[ -f "$LA_DIR/$LABEL.plist" ] || refuse "missing LaunchAgent $LA_DIR/$LABEL.plist"
rm -rf "$STAGE"
mkdir -p "$STAGE"
tar -xzf "$TARBALL" -C "$STAGE"
if find "$STAGE" \( -type l -o -type b -o -type c -o -type p \) -print | grep . >/dev/null; then
  refuse "candidate payload contains links or device files"
fi
[ -f "$STAGE/macprovider-cli" ] && [ -f "$STAGE/mlx.metallib" ] || refuse "candidate payload lacks macprovider-cli or mlx.metallib"
chmod 755 "$STAGE/macprovider-cli"
staged_version="$("$STAGE/macprovider-cli" --version | tr -d '\r\n')"
[ "$staged_version" = "$VERSION" ] || refuse "staged macprovider-cli reports $staged_version, expected $VERSION"
body="$(status_json)" || refuse "live /v1/status on :$PORT is not answering; not swapping an unhealthy provider"
old_version="$(status_field "$body" binary_version)"
[ "$old_version" != "$VERSION" ] || refuse "the canary already runs $VERSION"
say "preflight ok: live $old_version -> candidate $VERSION"

# --- pause and drain -------------------------------------------------------
control pause_request || refuse "pause_request was not accepted on $SOCKET"
PAUSED=1
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
cp -Rp "$INSTALL_DIR" "$BACKUP"
say "backup=$BACKUP"
SWAPPED=1
stop_jobs || restore_backup "provider job did not stop"
for f in macprovider-cli mlx.metallib compatibility-set.json THIRD-PARTY-NOTICES.txt; do
  [ -f "$STAGE/$f" ] || continue
  rm -f "$INSTALL_DIR/$f"
  cp "$STAGE/$f" "$INSTALL_DIR/$f"
done
for d in catalog-release compatibility-set-local mlx-swift_Cmlx.bundle swift-nio_NIOPosix.bundle; do
  [ -d "$STAGE/$d" ] || continue
  rm -rf "${INSTALL_DIR:?}/$d"
  cp -R "$STAGE/$d" "$INSTALL_DIR/$d"
done
chmod 755 "$INSTALL_DIR/macprovider-cli"
cmp "$STAGE/macprovider-cli" "$INSTALL_DIR/macprovider-cli" || restore_backup "installed binary differs from the staged candidate"
start_jobs
say "restarted on $VERSION"

# --- watch: crash loop or status silence restores the backup ----------------
start="$(now)"
pid0=""
while [ -z "$pid0" ]; do
  pid0="$(job_pid)"
  [ -n "$pid0" ] && break
  [ $(( $(now) - start )) -lt 15 ] || restore_backup "provider job has no process 15s after bootstrap"
  sleep 1
done
last_answer="$start"
resumed=0
ready_at=""
while :; do
  t="$(now)"
  pid="$(job_pid)"
  [ "$pid" = "$pid0" ] || restore_backup "provider process restarted (pid $pid0 -> ${pid:-none}): crash loop"
  body="$(status_json || true)"
  if [ -n "$body" ]; then
    last_answer="$t"
    running="$(status_field "$body" binary_version)"
    [ "$running" = "$VERSION" ] || restore_backup "/v1/status reports binary_version $running, expected $VERSION"
    if [ "$resumed" = 0 ] && [ "$(status_field "$body" model_loaded)" = true ]; then
      control resume_request && resumed=1
    fi
    if [ "$resumed" = 1 ] && [ "$(status_field "$body" network_state)" = buyer_serving ] && [ -z "$ready_at" ]; then
      ready_at="$t"
      say "buyer_serving on $VERSION; holding ${STABLE_S}s for a crash"
    fi
    if [ -n "$ready_at" ] && [ $(( t - ready_at )) -ge "$STABLE_S" ]; then
      break
    fi
  elif [ $(( t - last_answer )) -ge "$STATUS_TIMEOUT_S" ]; then
    restore_backup "/v1/status not answering for ${STATUS_TIMEOUT_S}s"
  fi
  [ $(( t - start )) -lt "$READY_TIMEOUT_S" ] || restore_backup "not buyer_serving within ${READY_TIMEOUT_S}s"
  sleep "$POLL_S"
done
FINISHED=1
say "OK: canary serves $VERSION (pid $pid0); previous payload kept at $BACKUP"
printf '{"result":"swapped","version":"%s","previous_version":"%s","backup":"%s","pid":"%s"}\n' \
  "$VERSION" "$old_version" "$BACKUP" "$pid0"
