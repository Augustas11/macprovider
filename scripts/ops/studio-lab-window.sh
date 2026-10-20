#!/usr/bin/env bash
# Guarded Studio window for the fixed issue-2080 offline diagnostic.
#
# Usage:
#   scripts/ops/studio-lab-window.sh status
#   scripts/ops/studio-lab-window.sh next
#   MACPROVIDER_OPS_OWNER=<label> scripts/ops/studio-lab-window.sh next --run
set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_NAME=studio-lab-window
# shellcheck source=lib/common.sh
. "$OPS_DIR/lib/common.sh"
# shellcheck source=lib/published-provider-identity.sh
. "$OPS_DIR/lib/published-provider-identity.sh"

OPS_SCOPE=studio-lab-window
STUDIO_MODEL=Mac15,14
REMOTE_HELPER="$OPS_DIR/lib/studio-lab-window-remote.py"
MANIFEST_HELPER="$OPS_DIR/lib/studio-lab-window-manifest.py"
PROBE_HELPER="$OPS_DIR/lib/studio-owner-pin-probe.py"
LAB_SCRIPT="$REPO_ROOT/scripts/lab/2080-native-rows/run-window-diagnostic.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

plain_remote_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$1" != *"/../"* ]] &&
    [[ "$1" != */.. ]] && [[ "$1" != *"//"* ]]
}

q() {
  case "$1" in *"'"*|*$'\n'*|*$'\r'*) refuse "Studio setting contains unsafe shell characters" ;; esac
  printf "'%s'" "$1"
}

jget() {
  printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1],{"d":d}); print(json.dumps(v) if isinstance(v,(dict,list,bool)) else ("" if v is None else v))' "$2" 2>/dev/null || true
}

window_paths() {
  REMOTE_MANIFEST="$STUDIO_LAB_WINDOW_DIR/manifest.json"
  REMOTE_JOURNAL="$STUDIO_LAB_WINDOW_DIR/journal.json"
  REMOTE_LIFECYCLE="$STUDIO_LAB_WINDOW_DIR/remote.py"
  REMOTE_PROBE="$STUDIO_LAB_WINDOW_DIR/probe.py"
  REMOTE_LAB_SCRIPT="$STUDIO_LAB_WINDOW_DIR/run-window-diagnostic.sh"
}

active_marker_path() { marker_path "$OPS_SCOPE" active; }
completion_mark() { printf 'complete-%s' "$STUDIO_LAB_GIT_HEAD"; }

# common.sh normally releases a PID-bound lock on every exit. Once this
# controller has durably recorded an active detached window, that would make
# uncertain Studio state appear free. Retain the converted non-PID lock until
# the matching remote journal is finished.
release_live_lock() {
  [ -n "$OPS_LOCK_OWNER" ] || return 0
  if [ -f "$(active_marker_path)" ]; then
    log "retaining the durable live-ops lock while the Studio window is active"
    OPS_LOCK_OWNER=""
    return 0
  fi
  local owner="$OPS_LOCK_OWNER"
  OPS_LOCK_OWNER=""
  "$OPS_DIR/live-lock.sh" release "$owner" >&2 || true
}

require_recovery_settings() {
  require_studio_ssh
  [ "$STUDIO_SSH" != local ] || refuse "the Studio window must run on the designated Studio over SSH"
  if [ -z "${STUDIO_LAB_WINDOW_DIR:-}" ] || ! plain_remote_path "$STUDIO_LAB_WINDOW_DIR"; then
    refuse "STUDIO_LAB_WINDOW_DIR must be an absolute plain path"
  fi
  window_paths
}

require_fresh_settings() {
  require_recovery_settings
  local name value
  for name in STUDIO_OWNER_PIN_INSTALL_DIR STUDIO_OWNER_PIN_CONFIG STUDIO_OWNER_PIN_JOURNAL \
    STUDIO_LAB_SOURCE_DIR CANARY_CTL_SOCKET; do
    value="${!name:-}"
    if [ -z "$value" ] || ! plain_remote_path "$value"; then
      refuse "$name must be an absolute plain path"
    fi
  done
  [[ "${STUDIO_LAB_GIT_HEAD:-}" =~ ^[0-9a-f]{40}$ ]] ||
    refuse "STUDIO_LAB_GIT_HEAD must be a lowercase 40-character commit SHA"
  case "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}" in *[!A-Za-z0-9._-]*) refuse "CANARY_LAUNCHD_LABEL is invalid" ;; esac
  STUDIO_STATUS_PORT="${STUDIO_STATUS_PORT:-8080}"
  DRAIN_TIMEOUT_S="${STUDIO_LAB_DRAIN_TIMEOUT_S:-600}"
  LAB_TIMEOUT_S="${STUDIO_LAB_TIMEOUT_S:-3600}"
  READY_TIMEOUT_S="${STUDIO_LAB_READY_TIMEOUT_S:-1200}"
  POLL_S="${STUDIO_LAB_POLL_S:-5}"
  for value in "$STUDIO_STATUS_PORT" "$DRAIN_TIMEOUT_S" "$LAB_TIMEOUT_S" "$READY_TIMEOUT_S" "$POLL_S"; do
    case "$value" in ""|*[!0-9]*|0) refuse "Studio ports and timeouts must be positive whole numbers" ;; esac
  done
  [ "$READY_TIMEOUT_S" -ge 120 ] || refuse "STUDIO_LAB_READY_TIMEOUT_S must be at least 120"
  [ "$READY_TIMEOUT_S" -le 1200 ] || refuse "STUDIO_LAB_READY_TIMEOUT_S must not exceed 1200"
  [ "$LAB_TIMEOUT_S" -le 3600 ] || refuse "STUDIO_LAB_TIMEOUT_S must not exceed 3600"
  [ -x "$LAB_SCRIPT" ] || refuse "the fixed issue-2080 diagnostic script is missing or not executable"
}

load_recovery_context() {
  require_recovery_settings
  DRAIN_TIMEOUT_S="${STUDIO_LAB_DRAIN_TIMEOUT_S:-600}"
  LAB_TIMEOUT_S="${STUDIO_LAB_TIMEOUT_S:-3600}"
  READY_TIMEOUT_S="${STUDIO_LAB_READY_TIMEOUT_S:-1200}"
  POLL_S="${STUDIO_LAB_POLL_S:-5}"
  local value
  for value in "$DRAIN_TIMEOUT_S" "$LAB_TIMEOUT_S" "$READY_TIMEOUT_S" "$POLL_S"; do
    case "$value" in ""|*[!0-9]*|0) refuse "Studio recovery timeouts must be positive whole numbers" ;; esac
  done
  [ "$READY_TIMEOUT_S" -ge 120 ] || refuse "STUDIO_LAB_READY_TIMEOUT_S must be at least 120"
  [ "$READY_TIMEOUT_S" -le 1200 ] || refuse "STUDIO_LAB_READY_TIMEOUT_S must not exceed 1200"
  [ "$LAB_TIMEOUT_S" -le 3600 ] || refuse "STUDIO_LAB_TIMEOUT_S must not exceed 3600"
  if [ -f "$(active_marker_path)" ]; then
    STUDIO_LAB_GIT_HEAD="$(json_field "$(active_marker_path)" 'd.get("lab_git_head")')"
  else
    STUDIO_LAB_GIT_HEAD="${STUDIO_LAB_GIT_HEAD:-}"
  fi
}

remote_state() {
  require_recovery_settings
  studio_ssh "test \"\$(sysctl -n hw.model)\" = $(q "$STUDIO_MODEL") || exit 3
if [ -e $(q "$REMOTE_JOURNAL") ] || [ -e $(q "$REMOTE_MANIFEST") ]; then
  [ -f $(q "$REMOTE_MANIFEST") ] || exit 4
  python3 - status --manifest $(q "$REMOTE_MANIFEST") --journal $(q "$REMOTE_JOURNAL")
elif [ -e $(q "$REMOTE_LIFECYCLE") ] || [ -e $(q "$REMOTE_PROBE") ] || [ -e $(q "$REMOTE_LAB_SCRIPT") ]; then
  printf '%s\n' '{\"state\":\"partial\"}'
else
  printf '%s\n' '{\"state\":\"absent\"}'
fi" 2>/dev/null < "$REMOTE_HELPER"
}

remote_probe() {
  studio_ssh "python3 - --install-dir $(q "$STUDIO_OWNER_PIN_INSTALL_DIR") --config $(q "$STUDIO_OWNER_PIN_CONFIG") --journal $(q "$STUDIO_OWNER_PIN_JOURNAL") --port $(q "$STUDIO_STATUS_PORT") --label $(q "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}")" < "$PROBE_HELPER"
}

source_snapshot() {
  studio_ssh "python3 - source-snapshot --source-dir $(q "$STUDIO_LAB_SOURCE_DIR") --git-head $(q "$STUDIO_LAB_GIT_HEAD") --provider-label $(q "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}")" < "$MANIFEST_HELPER"
}

durable_file() {
  python3 - "$1" <<'PY'
import os, stat, sys
path = sys.argv[1]
info = os.lstat(path)
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
    raise SystemExit(1)
fd = os.open(path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
try:
    os.fchmod(fd, 0o600); os.fsync(fd)
finally:
    os.close(fd)
parent = os.open(os.path.dirname(path), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(parent)
finally:
    os.close(parent)
PY
}

write_active_marker() {
  local phase="$1" nonce="$2" outcome="${3:-}"
  mark_done "$OPS_SCOPE" active "durable Studio window ownership" \
    "$(python3 -c 'import json,sys; print(json.dumps({"phase":sys.argv[1],"nonce":sys.argv[2],"lab_git_head":sys.argv[3],"outcome_marker":sys.argv[4]}))' "$phase" "$nonce" "$STUDIO_LAB_GIT_HEAD" "$outcome")"
  durable_file "$(active_marker_path)"
}

stage_file() {
  local source="$1" target="$2" mode="$3"
  studio_ssh "python3 -c 'import os,sys; p=sys.argv[1]; mode=int(sys.argv[2],8); fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode); data=sys.stdin.buffer.read(); out=os.fdopen(fd,\"wb\"); out.write(data); out.flush(); os.fchmod(fd,mode); os.fsync(fd); out.close(); d=os.open(os.path.dirname(p),os.O_RDONLY|os.O_DIRECTORY); os.fsync(d); os.close(d)' $(q "$target") $(q "$mode")" < "$source"
}

prepare_window_dir() {
  studio_ssh "python3 -c 'import os,stat,sys; p=sys.argv[1]; os.makedirs(p,mode=0o700,exist_ok=True); s=os.lstat(p); assert stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and not stat.S_IMODE(s.st_mode)&0o077 and not os.path.islink(p) and os.path.realpath(p)==p; os.chmod(p,0o700)' $(q "$STUDIO_LAB_WINDOW_DIR")"
}

cleanup_remote_stage() {
  studio_ssh "python3 -c 'import os,stat,sys; root=sys.argv[1]; names=sys.argv[2:]; s=os.lstat(root); assert os.path.isabs(root) and os.path.realpath(root)==root and stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and not stat.S_IMODE(s.st_mode)&0o077 and not os.path.islink(root); [os.unlink(os.path.join(root,n)) for n in names if os.path.lexists(os.path.join(root,n))]' $(q "$STUDIO_LAB_WINDOW_DIR") manifest.json remote.py probe.py run-window-diagnostic.sh .journal.json.lock" >/dev/null
}

verify_staged_lifecycle() {
  local expected
  expected="$(shasum -a 256 "$REMOTE_HELPER" | awk '{print $1}')"
  studio_ssh "python3 -c 'import hashlib,os,stat,sys; p=sys.argv[1]; want=sys.argv[2]; before=os.lstat(p); assert stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and before.st_nlink==1 and not stat.S_IMODE(before.st_mode)&0o077 and not os.path.islink(p) and os.path.realpath(p)==p; fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW); opened=os.fstat(fd); assert (opened.st_dev,opened.st_ino)==(before.st_dev,before.st_ino); h=hashlib.sha256(); [h.update(b) for b in iter(lambda:os.read(fd,1048576),b\"\")]; os.close(fd); assert h.hexdigest()==want' $(q "$REMOTE_LIFECYCLE") $(q "$expected")"
}

build_manifest() {
  local probe_file="$1" source_file="$2" output="$3" nonce="$4" script_sha probe_sha log_path
  script_sha="$(shasum -a 256 "$LAB_SCRIPT" | awk '{print $1}')"
  probe_sha="$(shasum -a 256 "$PROBE_HELPER" | awk '{print $1}')"
  log_path="$STUDIO_LAB_WINDOW_DIR/supervisor-$nonce.log"
  python3 "$MANIFEST_HELPER" build --nonce "$nonce" --git-head "$STUDIO_LAB_GIT_HEAD" \
    --probe-json "$probe_file" --source-snapshot-json "$source_file" --probe-sha256 "$probe_sha" \
    --lab-script-sha256 "$script_sha" \
    --install-dir "$STUDIO_OWNER_PIN_INSTALL_DIR" --config-path "$STUDIO_OWNER_PIN_CONFIG" \
    --ctl-socket "$CANARY_CTL_SOCKET" --provider-label "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}" \
    --status-port "$STUDIO_STATUS_PORT" --probe-path "$REMOTE_PROBE" \
    --owner-pin-journal "$STUDIO_OWNER_PIN_JOURNAL" --lab-source-dir "$STUDIO_LAB_SOURCE_DIR" \
    --lab-script-path "$REMOTE_LAB_SCRIPT" --log-path "$log_path" \
    --drain-timeout-s "$DRAIN_TIMEOUT_S" --lab-timeout-s "$LAB_TIMEOUT_S" \
    --ready-timeout-s "$READY_TIMEOUT_S" --poll-s "$POLL_S" > "$output"
}

record_outcome() {
  local state="$1" nonce revision lab_rc marker payload log_path active phase restored
  nonce="$(jget "$state" 'd["nonce"]')"; revision="$(jget "$state" 'd["revision"]')"
  lab_rc="$(jget "$state" 'd.get("lab_exit_code")')"
  phase="$(jget "$state" 'd.get("phase")')"
  restored="$(jget "$state" 'd.get("restored_process")')"
  active="$(active_marker_path)"
  [ -f "$active" ] || return 6
  [ "$phase" = restored ] && [ "$(jget "$state" 'd.get("action")')" = finish ] || return 6
  [ "$(json_field "$active" 'd.get("nonce")')" = "$nonce" ] || return 6
  [ "$(json_field "$active" 'd.get("lab_git_head")')" = "$STUDIO_LAB_GIT_HEAD" ] || return 6
  case "$revision" in ""|*[!0-9]*|0) return 6 ;; esac
  case "$lab_rc" in ""|*[!0-9]*) lab_rc=6 ;; esac
  [ "$lab_rc" -le 255 ] || lab_rc=6
  printf '%s' "$restored" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d.get("pid"),int) and d["pid"]>0; assert isinstance(d.get("process_start_us"),int) and d["process_start_us"]>0; assert isinstance(d.get("executable_path"),str) and d["executable_path"].startswith("/")' 2>/dev/null || return 6
  if [ "$lab_rc" = 0 ] && [[ "$STUDIO_LAB_GIT_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
    marker="$(completion_mark)"
  else
    marker="restored-$nonce"
  fi
  log_path="$STUDIO_LAB_WINDOW_DIR/supervisor-$nonce.log"
  payload="$(python3 -c 'import json,sys; print(json.dumps({"lab_git_head":sys.argv[1],"nonce":sys.argv[2],"lab_exit_code":int(sys.argv[3]),"private_supervisor_log":sys.argv[4],"journal_revision":int(sys.argv[5]),"restored_process":json.loads(sys.argv[6])}))' "$STUDIO_LAB_GIT_HEAD" "$nonce" "$lab_rc" "$log_path" "$revision" "$restored")"
  mark_done "$OPS_SCOPE" "$marker" "offline diagnostic exited $lab_rc after exact provider restoration" "$payload"
  durable_file "$(marker_path "$OPS_SCOPE" "$marker")"
  write_active_marker outcome_recorded "$nonce" "$marker"
  studio_ssh "python3 - finish --manifest $(q "$REMOTE_MANIFEST") --journal $(q "$REMOTE_JOURNAL") --nonce $(q "$nonce") --revision $(q "$revision") --controller-confirmed" < "$REMOTE_HELPER" >/dev/null || return 6
  cleanup_remote_stage || return 6
  "$OPS_DIR/live-lock.sh" release "$MACPROVIDER_OPS_OWNER" >&2 || return 6
  rm -f "$(active_marker_path)"
  return "$lab_rc"
}

reconcile_window() {
  local state action nonce revision deadline
  state="$(remote_state)" || return 6
  action="$(jget "$state" 'd.get("action")')"
  if [ "$(jget "$state" 'd.get("state")')" = idle ] && [ -f "$(active_marker_path)" ] &&
     [ "$(json_field "$(active_marker_path)" 'd.get("phase")')" = outcome_recorded ]; then
    cleanup_remote_stage || return 6
    "$OPS_DIR/live-lock.sh" release "$MACPROVIDER_OPS_OWNER" >&2 || return 6
    rm -f "$(active_marker_path)"
    return 0
  fi
  deadline=$(( $(date +%s) + DRAIN_TIMEOUT_S + LAB_TIMEOUT_S + READY_TIMEOUT_S + 300 ))
  while [ "$action" = wait ] && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep "$POLL_S"
    state="$(remote_state)" || return 6
    action="$(jget "$state" 'd.get("action")')"
  done
  if [ "$action" = recover ]; then
    nonce="$(jget "$state" 'd["nonce"]')"; revision="$(jget "$state" 'd["revision"]')"
    studio_ssh "python3 - recover --manifest $(q "$REMOTE_MANIFEST") --journal $(q "$REMOTE_JOURNAL") --nonce $(q "$nonce") --revision $(q "$revision")" < "$REMOTE_HELPER" >/dev/null || return 6
    state="$(remote_state)" || return 6
    action="$(jget "$state" 'd.get("action")')"
  fi
  [ "$action" = finish ] || return 6
  record_outcome "$state"
}

abort_predispatch_stage() {
  local state kind
  [ ! -f "$(active_marker_path)" ] || refuse "active Studio window ownership cannot be discarded"
  state="$(remote_state)" || refuse "protected Studio staging state is unreadable"
  kind="$(jget "$state" 'd.get("state")')"
  case "$kind" in partial|idle) ;; *) refuse "only pre-dispatch Studio staging may be discarded" ;; esac
  [ -z "$(jget "$state" 'd.get("action")')" ] || refuse "a Studio recovery journal takes precedence"
  studio_ssh "test ! -e $(q "$REMOTE_JOURNAL")" || refuse "a Studio recovery journal takes precedence"
  cleanup_remote_stage || refuse "could not remove the exact pre-dispatch staged files"
}

start_window() {
  local probe source manifest nonce version state
  require_fresh_settings
  probe="$OPS_TMP_DIR/studio-probe.json"; source="$OPS_TMP_DIR/source-snapshot.json"
  manifest="$OPS_TMP_DIR/window-manifest.json"
  remote_probe > "$probe" || refuse "fresh Studio baseline probe failed"
  [ "$(json_field "$probe" 'd.get("hardware_model")')" = "$STUDIO_MODEL" ] || refuse "SSH target is not the designated Studio"
  [ "$(json_field "$probe" 'd.get("journal",{}).get("state")')" = absent ] || refuse "owner-pin recovery journal is active"
  version="$(json_field "$probe" 'd["installed"]["binary_version"]')"
  published_provider_identity_ok "$version" "$(cat "$probe")" "$STUDIO_OWNER_PIN_INSTALL_DIR" ||
    refuse "installed provider is not the exact published signed release"
  source_snapshot > "$source" || refuse "fixed diagnostic source/artifact snapshot failed"
  nonce="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
  build_manifest "$probe" "$source" "$manifest" "$nonce" || refuse "could not build the fixed lab manifest"
  prepare_window_dir || refuse "protected Studio window directory is unsafe"
  stage_file "$REMOTE_HELPER" "$REMOTE_LIFECYCLE" 600 || refuse "could not stage remote lifecycle helper"
  stage_file "$PROBE_HELPER" "$REMOTE_PROBE" 600 || refuse "could not stage provider probe"
  stage_file "$LAB_SCRIPT" "$REMOTE_LAB_SCRIPT" 700 || refuse "could not stage fixed diagnostic"
  stage_file "$manifest" "$REMOTE_MANIFEST" 600 || refuse "could not stage window manifest"
  "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" --purpose "$OPS_NAME:active-window" >&2 || return 6
  write_active_marker prepared "$nonce"
  OPS_LOCK_OWNER=""
  verify_staged_lifecycle || return 6
  state="$(studio_ssh "python3 $(q "$REMOTE_LIFECYCLE") run --manifest $(q "$REMOTE_MANIFEST") --journal $(q "$REMOTE_JOURNAL")")" || return 6
  [ "$(jget "$state" 'd.get("state")')" = running ] && [ "$(jget "$state" 'd.get("nonce")')" = "$nonce" ] || return 6
  write_active_marker dispatched "$nonce"
  reconcile_window
}

gather() {
  local state action remote_kind active completion
  require_recovery_settings
  state="$(remote_state)" || { fact remote_state unreadable; step recovery blocked "remote journal state is unreadable"; set_next recovery blocked "Inspect the guarded Studio journal" "" "remote state cannot be authenticated"; return; }
  remote_kind="$(jget "$state" 'd.get("state")')"; action="$(jget "$state" 'd.get("action")')"
  fact remote_state "${remote_kind:-journaled}"
  fact remote_action "${action:-none}"
  if [ -n "$action" ]; then
    step recovery pending "remote journal action is $action"
    set_next recovery mutate "Reconcile and restore the guarded Studio window" "scripts/ops/studio-lab-window.sh _apply reconcile"
    NEXT_DOWNTIME="Studio provider recovery/readiness only; no Pearl restart; buyer runner remains active"
    return
  fi
  active="$(active_marker_path)"
  if [ -f "$active" ]; then
    if [ "$remote_kind" = idle ] && [ "$(json_field "$active" 'd.get("phase")')" = outcome_recorded ]; then
      step recovery pending "remote journal finished; protected scratch cleanup remains"
      set_next recovery mutate "Finish guarded Studio cleanup" "scripts/ops/studio-lab-window.sh _apply reconcile"
    else
      step recovery blocked "local durable ownership remains without an authenticated journal action"
      set_next recovery blocked "Preserve the Studio reservation for inspection" "" "active marker and remote journal do not form a safe terminal pair"
    fi
    return
  fi
  if [ "$remote_kind" = partial ] || [ "$remote_kind" = idle ]; then
    step staging pending "pre-dispatch protected scratch remains without a recovery journal"
    set_next staging mutate "Remove the exact abandoned pre-dispatch staged files" "scripts/ops/studio-lab-window.sh _apply abort-stage"
    return
  fi
  [ "$remote_kind" = absent ] || { step recovery blocked "protected scratch state is unexpected"; set_next recovery blocked "Inspect protected Studio scratch" "" "scratch state is not safely classifiable"; return; }
  require_fresh_settings
  completion="$(completion_mark)"
  if marker_done "$OPS_SCOPE" "$completion" && [ "$(marker_field "$OPS_SCOPE" "$completion" 'd.get("lab_exit_code")')" = 0 ]; then
    step window "done" "fixed diagnostic completed and exact provider restoration was committed"
    set_next "done" "done" "Studio lab window complete"
    return
  fi
  step window pending "fixed offline diagnostic is ready for a guarded window"
  set_next window mutate "Run the fixed issue-2080 Studio diagnostic" "scripts/ops/studio-lab-window.sh _apply run"
  NEXT_DOWNTIME="Studio provider pause/drain/unload, bounded offline diagnostic, and released-provider reload (20 minute readiness bound); no Pearl restart; buyer runner remains active and routes elsewhere"
}

internal() {
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] || refuse "internal actions run only through status, next, and next --run"
  [ "${1:-}" = _apply ] || refuse "unknown internal command"
  case "${2:-}" in
    run) start_window ;;
    reconcile) load_recovery_context; reconcile_window ;;
    abort-stage) load_recovery_context; abort_predispatch_stage ;;
    *) refuse "unknown Studio window action" ;;
  esac
}

ops_main "$@"
