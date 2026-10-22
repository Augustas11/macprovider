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
  REMOTE_ABORT_RECEIPT="$STUDIO_LAB_WINDOW_DIR/.journal.json.abort.json"
  REMOTE_LIFECYCLE="$STUDIO_LAB_WINDOW_DIR/remote.py"
  REMOTE_PROBE="$STUDIO_LAB_WINDOW_DIR/probe.py"
  REMOTE_LAB_SCRIPT="$STUDIO_LAB_WINDOW_DIR/run-window-diagnostic.sh"
  REMOTE_JOB_HELPER="$STUDIO_LAB_WINDOW_DIR/manifest.py"
}

active_marker_path() { marker_path "$OPS_SCOPE" active; }
completion_mark() {
  local identity=""
  if [ -f "$(active_marker_path)" ]; then
    identity="$(json_field "$(active_marker_path)" 'd.get("job_identity")')"
  else
    identity="${STUDIO_LAB_JOB_IDENTITY:-}"
  fi
  if [[ "$identity" =~ ^[0-9a-f]{64}$ ]]; then printf 'complete-%s' "$identity"
  else printf 'complete-%s' "$STUDIO_LAB_GIT_HEAD"; fi
}

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

# A recovery invocation must not turn the already durable, non-PID window
# lock back into a PID-bound lock before its second live-state check. Fresh
# dispatches retain common.sh's PID binding until start_window durably arms
# the local marker and converts the lock.
acquire_live_lock_for_step() {
  if [ -f "$(active_marker_path)" ]; then
    "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" --purpose "$OPS_NAME:$NEXT_ID" >&2
  else
    "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" --purpose "$OPS_NAME:$NEXT_ID" --bind-pid >&2
  fi
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
  STUDIO_LAB_JOB_KIND="${STUDIO_LAB_JOB_KIND:-diagnostic-legacy}"
  case "$STUDIO_LAB_JOB_KIND" in diagnostic-legacy|profiler-only|qualification|qwen-qualification|qwen-journey|glm-prefill) ;; *) refuse "STUDIO_LAB_JOB_KIND is invalid" ;; esac
  if [[ "$STUDIO_LAB_JOB_KIND" =~ ^(qualification|qwen-qualification)$ ]]; then
    LAB_TIMEOUT_S="${STUDIO_LAB_TIMEOUT_S:-43200}"
  elif [ "$STUDIO_LAB_JOB_KIND" = glm-prefill ]; then
    LAB_TIMEOUT_S="${STUDIO_LAB_TIMEOUT_S:-21600}"
  elif [ "$STUDIO_LAB_JOB_KIND" = qwen-journey ]; then
    LAB_TIMEOUT_S="${STUDIO_LAB_TIMEOUT_S:-7200}"
  else
    LAB_TIMEOUT_S="${STUDIO_LAB_TIMEOUT_S:-3600}"
  fi
  READY_TIMEOUT_S="${STUDIO_LAB_READY_TIMEOUT_S:-1200}"
  POLL_S="${STUDIO_LAB_POLL_S:-5}"
  for value in "$STUDIO_STATUS_PORT" "$DRAIN_TIMEOUT_S" "$LAB_TIMEOUT_S" "$READY_TIMEOUT_S" "$POLL_S"; do
    case "$value" in ""|*[!0-9]*|0) refuse "Studio ports and timeouts must be positive whole numbers" ;; esac
  done
  [ "$READY_TIMEOUT_S" -ge 120 ] || refuse "STUDIO_LAB_READY_TIMEOUT_S must be at least 120"
  [ "$READY_TIMEOUT_S" -le 1200 ] || refuse "STUDIO_LAB_READY_TIMEOUT_S must not exceed 1200"
  if [[ "$STUDIO_LAB_JOB_KIND" =~ ^(qualification|qwen-qualification)$ ]]; then
    [ "$LAB_TIMEOUT_S" -le 43200 ] || refuse "qualification timeout must not exceed 43200"
  elif [ "$STUDIO_LAB_JOB_KIND" = glm-prefill ]; then
    [ "$LAB_TIMEOUT_S" -le 21600 ] || refuse "GLM prefill timeout must not exceed 21600"
  elif [ "$STUDIO_LAB_JOB_KIND" = qwen-journey ]; then
    [ "$LAB_TIMEOUT_S" -le 7200 ] || refuse "Qwen journey timeout must not exceed 7200"
  else
    [ "$LAB_TIMEOUT_S" -le 3600 ] || refuse "STUDIO_LAB_TIMEOUT_S must not exceed 3600"
  fi
  [ -x "$LAB_SCRIPT" ] || refuse "the fixed issue-2080 diagnostic script is missing or not executable"
}

load_recovery_context() {
  require_recovery_settings
  DRAIN_TIMEOUT_S="${STUDIO_LAB_DRAIN_TIMEOUT_S:-600}"
  if [ -f "$(active_marker_path)" ]; then
    STUDIO_LAB_JOB_KIND="$(json_field "$(active_marker_path)" 'd.get("job_kind")')"
    STUDIO_LAB_JOB_IDENTITY="$(json_field "$(active_marker_path)" 'd.get("job_identity")')"
  else
    STUDIO_LAB_JOB_KIND="${STUDIO_LAB_JOB_KIND:-diagnostic-legacy}"
  fi
  STUDIO_LAB_JOB_KIND="${STUDIO_LAB_JOB_KIND:-diagnostic-legacy}"
  case "$STUDIO_LAB_JOB_KIND" in diagnostic-legacy|profiler-only|qualification|qwen-qualification|qwen-journey|glm-prefill) ;; *) refuse "active Studio job kind is invalid" ;; esac
  # Recovery is bound to the durable active marker, not a caller's later
  # environment.  The remote journal remains the authoritative deadline.
  if [[ "$STUDIO_LAB_JOB_KIND" =~ ^(qualification|qwen-qualification)$ ]]; then
    LAB_TIMEOUT_S=43200
  elif [ "$STUDIO_LAB_JOB_KIND" = glm-prefill ]; then
    LAB_TIMEOUT_S=21600
  elif [ "$STUDIO_LAB_JOB_KIND" = qwen-journey ]; then
    LAB_TIMEOUT_S=7200
  else
    LAB_TIMEOUT_S=3600
  fi
  READY_TIMEOUT_S="${STUDIO_LAB_READY_TIMEOUT_S:-1200}"
  POLL_S="${STUDIO_LAB_POLL_S:-5}"
  local value
  for value in "$DRAIN_TIMEOUT_S" "$LAB_TIMEOUT_S" "$READY_TIMEOUT_S" "$POLL_S"; do
    case "$value" in ""|*[!0-9]*|0) refuse "Studio recovery timeouts must be positive whole numbers" ;; esac
  done
  [ "$READY_TIMEOUT_S" -ge 120 ] || refuse "STUDIO_LAB_READY_TIMEOUT_S must be at least 120"
  [ "$READY_TIMEOUT_S" -le 1200 ] || refuse "STUDIO_LAB_READY_TIMEOUT_S must not exceed 1200"
  if [[ "$STUDIO_LAB_JOB_KIND" =~ ^(qualification|qwen-qualification)$ ]]; then
    [ "$LAB_TIMEOUT_S" -le 43200 ] || refuse "qualification recovery timeout must not exceed 43200"
  elif [ "$STUDIO_LAB_JOB_KIND" = glm-prefill ]; then
    [ "$LAB_TIMEOUT_S" -le 21600 ] || refuse "GLM prefill timeout must not exceed 21600"
  elif [ "$STUDIO_LAB_JOB_KIND" = qwen-journey ]; then
    [ "$LAB_TIMEOUT_S" -le 7200 ] || refuse "Qwen journey recovery timeout must not exceed 7200"
  else
    [ "$LAB_TIMEOUT_S" -le 3600 ] || refuse "STUDIO_LAB_TIMEOUT_S must not exceed 3600"
  fi
  if [ -f "$(active_marker_path)" ]; then
    STUDIO_LAB_GIT_HEAD="$(json_field "$(active_marker_path)" 'd.get("lab_git_head")')"
  else
    STUDIO_LAB_GIT_HEAD="${STUDIO_LAB_GIT_HEAD:-}"
  fi
}

remote_state() {
  require_recovery_settings
  studio_ssh "test \"\$(sysctl -n hw.model)\" = $(q "$STUDIO_MODEL") || exit 3
if [ -e $(q "$REMOTE_JOURNAL") ] || [ -e $(q "$REMOTE_MANIFEST") ] || [ -e $(q "$REMOTE_ABORT_RECEIPT") ]; then
  python3 - status --manifest $(q "$REMOTE_MANIFEST") --journal $(q "$REMOTE_JOURNAL")
elif [ -e $(q "$REMOTE_LIFECYCLE") ] || [ -e $(q "$REMOTE_PROBE") ] || [ -e $(q "$REMOTE_LAB_SCRIPT") ] || [ -e $(q "$REMOTE_JOB_HELPER") ]; then
  printf '%s\n' '{\"state\":\"partial\"}'
else
  printf '%s\n' '{\"state\":\"absent\"}'
fi" 2>/dev/null < "$REMOTE_HELPER"
}

remote_probe() {
  studio_ssh "python3 - --install-dir $(q "$STUDIO_OWNER_PIN_INSTALL_DIR") --config $(q "$STUDIO_OWNER_PIN_CONFIG") --journal $(q "$STUDIO_OWNER_PIN_JOURNAL") --port $(q "$STUDIO_STATUS_PORT") --label $(q "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}")" < "$PROBE_HELPER"
}

source_snapshot() {
  local script_sha helper_sha
  script_sha="$(shasum -a 256 "$LAB_SCRIPT" | awk '{print $1}')"
  helper_sha="$(shasum -a 256 "$MANIFEST_HELPER" | awk '{print $1}')"
  studio_ssh "python3 - source-snapshot --source-dir $(q "$STUDIO_LAB_SOURCE_DIR") --git-head $(q "$STUDIO_LAB_GIT_HEAD") --provider-label $(q "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}") --job-kind $(q "$STUDIO_LAB_JOB_KIND") --lab-script-sha256 $(q "$script_sha") --job-helper-sha256 $(q "$helper_sha")" < "$MANIFEST_HELPER"
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
  local phase="$1" nonce="$2" outcome="${3:-}" manifest_sha="${4:-}"
  if [ -z "$manifest_sha" ] && [ -f "$(active_marker_path)" ]; then
    manifest_sha="$(json_field "$(active_marker_path)" 'd.get("manifest_sha256")')"
  fi
  mark_done "$OPS_SCOPE" active "durable Studio window ownership" \
    "$(python3 -c 'import json,sys; print(json.dumps({"phase":sys.argv[1],"nonce":sys.argv[2],"lab_git_head":sys.argv[3],"outcome_marker":sys.argv[4],"manifest_sha256":sys.argv[5],"job_kind":sys.argv[6],"job_identity":sys.argv[7]}))' "$phase" "$nonce" "$STUDIO_LAB_GIT_HEAD" "$outcome" "$manifest_sha" "${STUDIO_LAB_JOB_KIND:-diagnostic-legacy}" "${STUDIO_LAB_JOB_IDENTITY:-}")"
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
  studio_ssh "python3 -c 'import os,stat,sys; root=sys.argv[1]; names=sys.argv[2:]; exists=os.path.lexists(root); s=os.lstat(root) if exists else None; assert not exists or (os.path.isabs(root) and os.path.realpath(root)==root and stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and not stat.S_IMODE(s.st_mode)&0o077 and not os.path.islink(root)); [os.unlink(os.path.join(root,n)) for n in names if exists and os.path.lexists(os.path.join(root,n))]' $(q "$STUDIO_LAB_WINDOW_DIR") manifest.json remote.py probe.py run-window-diagnostic.sh manifest.py" >/dev/null
}

terminal_context_ok() {
  local state="$1"
  python3 - "$(active_marker_path)" "$OPS_STATE_DIR/$OPS_SCOPE" "$state" <<'PY' 2>/dev/null
import json, os, re, stat, sys

def read_safe(path):
    before = os.lstat(path)
    assert stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1
    assert not os.path.islink(path)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(fd)
        assert (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino)
        data = os.read(fd, 65537)
        assert len(data) <= 65536 and len(data) == before.st_size
    finally:
        os.close(fd)
    value = json.loads(data)
    assert isinstance(value, dict)
    return value

active_path, root, remote_json = sys.argv[1:]
active = read_safe(active_path)
remote = json.loads(remote_json)
nonce = active.get("nonce")
head = active.get("lab_git_head")
marker = active.get("outcome_marker")
manifest_sha = active.get("manifest_sha256")
job_kind = active.get("job_kind", "diagnostic-legacy")
job_identity = active.get("job_identity", "")
assert active.get("phase") == "outcome_recorded"
assert isinstance(nonce, str) and re.fullmatch(r"[0-9a-f]{32}", nonce)
assert isinstance(head, str) and re.fullmatch(r"[0-9a-f]{40}", head)
assert isinstance(manifest_sha, str) and re.fullmatch(r"[0-9a-f]{64}", manifest_sha)
assert job_kind in ("diagnostic-legacy", "profiler-only", "qualification", "qwen-qualification", "qwen-journey", "glm-prefill")
assert (job_kind == "diagnostic-legacy" and job_identity == "") or re.fullmatch(r"[0-9a-f]{64}", job_identity or "")
assert isinstance(marker, str) and re.fullmatch(r"(?:complete-(?:[0-9a-f]{40}|[0-9a-f]{64})|restored-[0-9a-f]{32})", marker)
outcome = read_safe(os.path.join(root, marker + ".json"))
rc = outcome.get("lab_exit_code")
restored = outcome.get("restored_process")
assert outcome.get("step") == marker and outcome.get("nonce") == nonce and outcome.get("lab_git_head") == head
assert outcome.get("manifest_sha256") == manifest_sha
assert outcome.get("job_kind", "diagnostic-legacy") == job_kind
assert outcome.get("job_identity", "") == job_identity
if remote.get("state") == "idle":
    assert remote.get("nonce") == nonce and remote.get("manifest_sha256") == manifest_sha
assert isinstance(rc, int) and not isinstance(rc, bool) and 0 <= rc <= 255
assert marker == (("complete-" + (job_identity or head)) if rc == 0 else ("restored-" + nonce))
assert isinstance(restored, dict)
assert isinstance(restored.get("pid"), int) and restored["pid"] > 0
assert isinstance(restored.get("process_start_us"), int) and restored["process_start_us"] > 0
assert isinstance(restored.get("executable_path"), str) and restored["executable_path"].startswith("/")
PY
}

prepared_context_ok() {
  local state="$1"
  python3 - "$(active_marker_path)" "$state" <<'PY' 2>/dev/null
import json, os, re, stat, sys

path = sys.argv[1]
before = os.lstat(path)
assert stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1
assert not os.path.islink(path)
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    opened = os.fstat(fd)
    assert (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino)
    data = os.read(fd, 65537)
    assert len(data) <= 65536 and len(data) == before.st_size
finally:
    os.close(fd)
active = json.loads(data)
remote = json.loads(sys.argv[2])
nonce = active.get("nonce")
digest = active.get("manifest_sha256")
assert active.get("phase") in ("prepared", "dispatching", "aborting_prepared") and active.get("outcome_marker") == ""
assert isinstance(nonce, str) and re.fullmatch(r"[0-9a-f]{32}", nonce)
assert isinstance(active.get("lab_git_head"), str) and re.fullmatch(r"[0-9a-f]{40}", active["lab_git_head"])
assert isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest)
assert remote.get("state") == "idle" and remote.get("nonce") == nonce and remote.get("manifest_sha256") == digest
PY
}

aborted_context_ok() {
  local state="$1"
  python3 - "$(active_marker_path)" "$state" <<'PY' 2>/dev/null
import json, os, re, stat, sys
path = sys.argv[1]
before = os.lstat(path)
assert stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1
assert not os.path.islink(path)
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    opened = os.fstat(fd)
    assert (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino)
    data = os.read(fd, 65537)
    assert len(data) <= 65536 and len(data) == before.st_size
finally:
    os.close(fd)
active = json.loads(data)
remote = json.loads(sys.argv[2])
assert active.get("phase") in ("aborting_prepared", "abort_confirmed") and active.get("outcome_marker") == ""
assert isinstance(active.get("nonce"), str) and re.fullmatch(r"[0-9a-f]{32}", active["nonce"])
assert isinstance(active.get("lab_git_head"), str) and re.fullmatch(r"[0-9a-f]{40}", active["lab_git_head"])
assert isinstance(active.get("manifest_sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", active["manifest_sha256"])
assert remote.get("state") == "aborted"
assert remote.get("nonce") == active["nonce"] and remote.get("manifest_sha256") == active["manifest_sha256"]
PY
}

abort_confirmed_context_ok() {
  python3 - "$(active_marker_path)" <<'PY' 2>/dev/null
import json, os, re, stat, sys
path = sys.argv[1]
before = os.lstat(path)
assert stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1
assert not os.path.islink(path)
fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    opened = os.fstat(fd)
    assert (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino)
    data = os.read(fd, 65537)
    assert len(data) <= 65536 and len(data) == before.st_size
finally:
    os.close(fd)
active = json.loads(data)
assert active.get("phase") == "abort_confirmed" and active.get("outcome_marker") == ""
assert isinstance(active.get("nonce"), str) and re.fullmatch(r"[0-9a-f]{32}", active["nonce"])
assert isinstance(active.get("lab_git_head"), str) and re.fullmatch(r"[0-9a-f]{40}", active["lab_git_head"])
assert isinstance(active.get("manifest_sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", active["manifest_sha256"])
PY
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
  local state="$1" nonce revision lab_rc marker payload log_path active phase restored manifest_sha job_kind job_identity
  nonce="$(jget "$state" 'd["nonce"]')"; revision="$(jget "$state" 'd["revision"]')"
  lab_rc="$(jget "$state" 'd.get("lab_exit_code")')"
  phase="$(jget "$state" 'd.get("phase")')"
  restored="$(jget "$state" 'd.get("restored_process")')"
  active="$(active_marker_path)"
  [ -f "$active" ] || return 6
  [ "$phase" = restored ] && [ "$(jget "$state" 'd.get("action")')" = finish ] || return 6
  [ "$(json_field "$active" 'd.get("nonce")')" = "$nonce" ] || return 6
  [ "$(json_field "$active" 'd.get("lab_git_head")')" = "$STUDIO_LAB_GIT_HEAD" ] || return 6
  manifest_sha="$(json_field "$active" 'd.get("manifest_sha256")')"
  job_kind="$(json_field "$active" 'd.get("job_kind", "diagnostic-legacy")')"
  job_identity="$(json_field "$active" 'd.get("job_identity", "")')"
  [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]] || return 6
  case "$job_kind" in diagnostic-legacy) [ -z "$job_identity" ] || return 6 ;; profiler-only|qualification|qwen-qualification|qwen-journey|glm-prefill) [[ "$job_identity" =~ ^[0-9a-f]{64}$ ]] || return 6; [ "$(jget "$state" 'd.get("job_kind")')" = "$job_kind" ] && [ "$(jget "$state" 'd.get("job_identity_sha256")')" = "$job_identity" ] || return 6 ;; *) return 6 ;; esac
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
  payload="$(python3 -c 'import json,sys; print(json.dumps({"lab_git_head":sys.argv[1],"nonce":sys.argv[2],"lab_exit_code":int(sys.argv[3]),"private_supervisor_log":sys.argv[4],"journal_revision":int(sys.argv[5]),"restored_process":json.loads(sys.argv[6]),"manifest_sha256":sys.argv[7],"job_kind":sys.argv[8],"job_identity":sys.argv[9]}))' "$STUDIO_LAB_GIT_HEAD" "$nonce" "$lab_rc" "$log_path" "$revision" "$restored" "$manifest_sha" "$job_kind" "$job_identity")"
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
  local state action nonce revision deadline remote_kind
  state="$(remote_state)" || return 6
  action="$(jget "$state" 'd.get("action")')"
  remote_kind="$(jget "$state" 'd.get("state")')"
  if [ -z "$action" ] && [ -f "$(active_marker_path)" ] &&
     [[ "$remote_kind" =~ ^(idle|partial|absent)$ ]] && terminal_context_ok "$state"; then
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

abort_prepared_window() {
  local state kind nonce manifest_sha result
  state="$(remote_state)" || refuse "prepared Studio state is unreadable"
  kind="$(jget "$state" 'd.get("state")')"
  if [ "$kind" = idle ]; then
    prepared_context_ok "$state" || refuse "prepared Studio intent does not match the authenticated remote manifest"
    nonce="$(jget "$state" 'd["nonce"]')"
    manifest_sha="$(jget "$state" 'd["manifest_sha256"]')"
    write_active_marker aborting_prepared "$nonce" "" "$manifest_sha"
    result="$(studio_ssh "python3 - abort --manifest $(q "$REMOTE_MANIFEST") --journal $(q "$REMOTE_JOURNAL") --nonce $(q "$nonce") --manifest-sha256 $(q "$manifest_sha")" < "$REMOTE_HELPER")" ||
      refuse "prepared Studio abort was refused"
    state="$result"
    kind="$(jget "$state" 'd.get("state")')"
  fi
  if [ "$kind" = aborted ]; then
    aborted_context_ok "$state" || refuse "prepared Studio abort receipt does not match durable local ownership"
    nonce="$(jget "$state" 'd["nonce"]')"
    manifest_sha="$(jget "$state" 'd["manifest_sha256"]')"
    write_active_marker abort_confirmed "$nonce" "" "$manifest_sha"
    result="$(studio_ssh "python3 - finish-abort --manifest $(q "$REMOTE_MANIFEST") --journal $(q "$REMOTE_JOURNAL") --nonce $(q "$nonce") --manifest-sha256 $(q "$manifest_sha")" < "$REMOTE_HELPER")" ||
      refuse "could not finish the authenticated Studio abort receipt"
    [ "$(jget "$result" 'd.get("state")')" = abort-finished ] &&
      [ "$(jget "$result" 'd.get("nonce")')" = "$nonce" ] ||
      refuse "Studio abort finish returned a mismatched result"
  elif [[ "$kind" =~ ^(partial|absent)$ ]] && abort_confirmed_context_ok; then
    nonce="$(json_field "$(active_marker_path)" 'd["nonce"]')"
  else
    refuse "prepared Studio abort is not in an authenticated recoverable state"
  fi
  cleanup_remote_stage || refuse "could not remove exact prepared Studio staging"
  "$OPS_DIR/live-lock.sh" release "$MACPROVIDER_OPS_OWNER" >&2 || refuse "could not release the durable Studio lock"
  rm -f "$(active_marker_path)"
}

start_window() {
  local probe source manifest nonce version state manifest_sha source_kind
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
  source_kind="$(json_field "$source" 'd.get("job",{}).get("kind")')"
  if [ "$STUDIO_LAB_JOB_KIND" = diagnostic-legacy ]; then
    [ -z "$source_kind" ] || refuse "legacy source snapshot unexpectedly created a job"
    STUDIO_LAB_JOB_IDENTITY=""
  else
    [ "$source_kind" = "$STUDIO_LAB_JOB_KIND" ] || refuse "source snapshot job kind is not the requested job"
    STUDIO_LAB_JOB_IDENTITY="$(json_field "$source" 'd.get("job",{}).get("identity_sha256")')"
    [[ "$STUDIO_LAB_JOB_IDENTITY" =~ ^[0-9a-f]{64}$ ]] || refuse "source snapshot job identity is invalid"
  fi
  nonce="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
  build_manifest "$probe" "$source" "$manifest" "$nonce" || refuse "could not build the fixed lab manifest"
  manifest_sha="$(shasum -a 256 "$manifest" | awk '{print $1}')"
  prepare_window_dir || refuse "protected Studio window directory is unsafe"
  stage_file "$REMOTE_HELPER" "$REMOTE_LIFECYCLE" 600 || refuse "could not stage remote lifecycle helper"
  stage_file "$PROBE_HELPER" "$REMOTE_PROBE" 600 || refuse "could not stage provider probe"
  stage_file "$LAB_SCRIPT" "$REMOTE_LAB_SCRIPT" 700 || refuse "could not stage fixed diagnostic"
  if [ "$STUDIO_LAB_JOB_KIND" != diagnostic-legacy ]; then
    stage_file "$MANIFEST_HELPER" "$REMOTE_JOB_HELPER" 600 || refuse "could not stage fixed job helper"
  fi
  stage_file "$manifest" "$REMOTE_MANIFEST" 600 || refuse "could not stage window manifest"
  "$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" --purpose "$OPS_NAME:active-window" >&2 || return 6
  write_active_marker prepared "$nonce" "" "$manifest_sha"
  OPS_LOCK_OWNER=""
  verify_staged_lifecycle || return 6
  write_active_marker dispatching "$nonce"
  state="$(studio_ssh "python3 $(q "$REMOTE_LIFECYCLE") run --manifest $(q "$REMOTE_MANIFEST") --journal $(q "$REMOTE_JOURNAL")")" || return 6
  [ "$(jget "$state" 'd.get("state")')" = running ] && [ "$(jget "$state" 'd.get("nonce")')" = "$nonce" ] || return 6
  write_active_marker dispatched "$nonce"
  reconcile_window
}

gather() {
  local state action remote_kind active completion source source_kind
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
    if [[ "$remote_kind" =~ ^(idle|partial|absent)$ ]] && terminal_context_ok "$state"; then
      step recovery pending "remote journal finished; protected scratch cleanup remains"
      set_next recovery mutate "Finish guarded Studio cleanup" "scripts/ops/studio-lab-window.sh _apply reconcile"
    elif [ "$remote_kind" = idle ] && prepared_context_ok "$state"; then
      step staging pending "prepared Studio intent is authenticated but no remote execution journal exists"
      set_next staging mutate "Abort the exact prepared Studio window" "scripts/ops/studio-lab-window.sh _apply abort-prepared"
    elif [ "$remote_kind" = aborted ] && aborted_context_ok "$state"; then
      step staging pending "authenticated abort receipt remains for the prepared Studio intent"
      set_next staging mutate "Finish the authenticated prepared Studio abort" "scripts/ops/studio-lab-window.sh _apply abort-prepared"
    elif [[ "$remote_kind" =~ ^(partial|absent)$ ]] && abort_confirmed_context_ok; then
      step staging pending "the prepared abort was confirmed locally; exact cleanup remains"
      set_next staging mutate "Finish the interrupted prepared Studio abort" "scripts/ops/studio-lab-window.sh _apply abort-prepared"
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
  # The production preflight always initializes these; retain the legacy
  # default for callers that only need completion-status inspection.
  STUDIO_LAB_JOB_KIND="${STUDIO_LAB_JOB_KIND:-diagnostic-legacy}"
  STUDIO_LAB_JOB_IDENTITY="${STUDIO_LAB_JOB_IDENTITY:-}"
  # Completion for a qualified job is keyed to a newly-derived immutable job
  # identity, never a caller-supplied environment value or stale status cache.
  if [ "$STUDIO_LAB_JOB_KIND" = diagnostic-legacy ]; then
    STUDIO_LAB_JOB_IDENTITY=""
  else
    source="$OPS_TMP_DIR/status-source-snapshot.json"
    if ! source_snapshot > "$source"; then
      step recovery blocked "fresh Studio source snapshot could not authenticate the job identity"
      set_next recovery blocked "Preserve Studio state for source identity inspection" "" "source snapshot failed"
      return
    fi
    source_kind="$(json_field "$source" 'd.get("job",{}).get("kind")')"
    STUDIO_LAB_JOB_IDENTITY="$(json_field "$source" 'd.get("job",{}).get("identity_sha256")')"
    if [ "$source_kind" != "$STUDIO_LAB_JOB_KIND" ] || ! [[ "$STUDIO_LAB_JOB_IDENTITY" =~ ^[0-9a-f]{64}$ ]]; then
      step recovery blocked "fresh Studio source snapshot job identity is invalid"
      set_next recovery blocked "Preserve Studio state for manifest inspection" "" "job identity mismatch"
      return
    fi
  fi
  completion="$(completion_mark)"
  if marker_done "$OPS_SCOPE" "$completion" && [ "$(marker_field "$OPS_SCOPE" "$completion" 'd.get("lab_exit_code")')" = 0 ] && {
    [ "$STUDIO_LAB_JOB_KIND" = diagnostic-legacy ] || {
      [ "$(marker_field "$OPS_SCOPE" "$completion" 'd.get("job_kind")')" = "$STUDIO_LAB_JOB_KIND" ] &&
        [ "$(marker_field "$OPS_SCOPE" "$completion" 'd.get("job_identity")')" = "$STUDIO_LAB_JOB_IDENTITY" ]
    }
  }; then
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
    abort-prepared) load_recovery_context; abort_prepared_window ;;
    *) refuse "unknown Studio window action" ;;
  esac
}

ops_main "$@"
