#!/bin/bash
# Bounded #1646 M2 joined-provider runner. bench.sh owns the live-provider
# pause/resume; this script owns only the isolated candidate it launches.
set -euo pipefail

PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
export PATH

LAB=/Users/a1/lab-cb-sampling
BINARY=/Users/a1/lab-cb-sampling/bin-tools/macprovider-cli
CONFIG=/Users/a1/.config/macprovider/config.yaml
OUTPUT=/Users/a1/lab-cb-sampling/m2-leftovers
READY=/Users/a1/lab-cb-sampling/m2-leftovers/READY
STOP=/Users/a1/lab-cb-sampling/m2-leftovers/STOP
LOG=/Users/a1/lab-cb-sampling/m2-leftovers/provider.log
MODEL=qwen/qwen3.6-27b
CATALOG_MODEL_ID=mlx-community/Qwen3.6-27B-4bit
MODEL_HASH=518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931
CATALOG_KEY=qwen/qwen3.6-27b
MODELS=qwen/qwen3.6-27b,mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit
SOURCE_TREE=/Users/a1/macprovider-cb-sampling
START_EPOCH=$(/bin/date +%s)
# Leave 30 seconds inside the 18-minute bench window for forced cleanup.
DEADLINE_EPOCH=$((START_EPOCH + 1050))
CHILD_PID=
CHILD_GROUP_READY=0
CLEANED_UP=0

error() {
  echo "m2-joined-provider: $*" >&2
}

child_running() {
  [ -n "$CHILD_PID" ] && /bin/kill -0 "$CHILD_PID" 2>/dev/null
}

signal_child() {
  local signal_name=$1
  if [ "$CHILD_GROUP_READY" -eq 1 ]; then
    /usr/bin/python3 -c \
      'import os, signal, sys; os.killpg(int(sys.argv[1]), getattr(signal, "SIG" + sys.argv[2]))' \
      "$CHILD_PID" "$signal_name" 2>/dev/null || true
  else
    /bin/kill -"$signal_name" "$CHILD_PID" 2>/dev/null || true
  fi
}

terminate_child() {
  local child_state forced wait_count
  [ -n "$CHILD_PID" ] || return 0
  forced=0
  if child_running; then
    signal_child TERM
    wait_count=0
    while child_running && [ "$wait_count" -lt 20 ]; do
      child_state=$(/bin/ps -o stat= -p "$CHILD_PID" 2>/dev/null | /usr/bin/awk '{print $1}')
      case "$child_state" in
        Z*) break ;;
      esac
      /bin/sleep 1
      wait_count=$((wait_count + 1))
    done
    if child_running; then
      child_state=$(/bin/ps -o stat= -p "$CHILD_PID" 2>/dev/null | /usr/bin/awk '{print $1}')
      case "$child_state" in
        Z*) ;;
        *)
          signal_child KILL
          forced=1
          ;;
      esac
    fi
  fi
  wait "$CHILD_PID" 2>/dev/null || true
  CHILD_PID=
  return "$forced"
}

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  [ "$CLEANED_UP" -eq 0 ] || return 0
  CLEANED_UP=1
  terminate_child || true
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps.
on_signal() {
  exit 130
}

trap cleanup EXIT
trap on_signal INT TERM

if [ "$LAB" != /Users/a1/lab-cb-sampling ] ||
   [ "$OUTPUT" != /Users/a1/lab-cb-sampling/m2-leftovers ]; then
  error "internal path guard failed"
  exit 2
fi
if [ ! -x "$BINARY" ]; then
  error "candidate binary is missing or not executable"
  exit 2
fi
if [ ! -f "$CONFIG" ]; then
  error "provider config is missing"
  exit 2
fi
if /usr/sbin/lsof -nP -iTCP:18080 >/dev/null 2>&1; then
  error "port 18080 is not free"
  exit 3
fi

/bin/rm -rf "$OUTPUT"
/bin/mkdir -p "$OUTPUT"
/bin/chmod 700 "$OUTPUT"
umask 077

START_UTC=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
BINARY_SHA=$(/usr/bin/shasum -a 256 "$BINARY" | /usr/bin/awk '{print $1}')
{
  echo "campaign=1646-m2-leftovers"
  echo "started_at_utc=$START_UTC"
  echo "binary_sha256=$BINARY_SHA"
  if [ -d "$SOURCE_TREE/.git" ] || [ -f "$SOURCE_TREE/.git" ]; then
    git_commit=$(/usr/bin/git -C "$SOURCE_TREE" rev-parse --verify HEAD 2>/dev/null || true)
    case "$git_commit" in
      *[!0-9a-f]*|'') ;;
      *) echo "git_commit=$git_commit" ;;
    esac
    git_branch=$(/usr/bin/git -C "$SOURCE_TREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    case "$git_branch" in
      *[!A-Za-z0-9._/-]*|'') ;;
      *) echo "git_branch=$git_branch" ;;
    esac
  fi
} > "$OUTPUT/metadata.txt"

# Start a fresh session so cleanup can address this exact candidate process
# group. The candidate receives a minimal environment: all provider behavior,
# including continuous-batching settings and identity, comes from CONFIG.
/usr/bin/python3 -c '
import os
import sys
os.setsid()
environment = {
    "CFFIXED_USER_HOME": "/Users/a1",
    "HOME": "/Users/a1",
    "LOGNAME": "a1",
    "PATH": "/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin",
    "TMPDIR": "/private/tmp",
    "USER": "a1",
}
os.execve(sys.argv[1], sys.argv[1:], environment)
' "$BINARY" serve \
  --config "$CONFIG" \
  --port 18080 \
  --isolate-lifecycle \
  --credential-store protected_file \
  --enable-warm-swap \
  --swap-drain-timeout-seconds 30 \
  --supported-models "$MODELS" \
  --publish-supported-models \
  </dev/null >>"$LOG" 2>&1 &
CHILD_PID=$!

# Refuse group signalling unless the setsid/exec launcher produced the exact
# expected group. Cleanup falls back to the exact PID if startup failed early.
group_wait=0
while [ "$group_wait" -lt 10 ]; do
  if ! child_running; then
    wait "$CHILD_PID" 2>/dev/null || child_status=$?
    CHILD_PID=
    error "candidate exited during launch (status ${child_status:-0}); logs preserved"
    exit 4
  fi
  child_pgid=$(/bin/ps -o pgid= -p "$CHILD_PID" 2>/dev/null | /usr/bin/tr -d ' ')
  if [ "$child_pgid" = "$CHILD_PID" ]; then
    CHILD_GROUP_READY=1
    break
  fi
  /bin/sleep 1
  group_wait=$((group_wait + 1))
done
if [ "$CHILD_GROUP_READY" -ne 1 ]; then
  error "candidate process-group isolation failed; logs preserved"
  exit 4
fi

CONTROL_SOCKET=
while [ "$(/bin/date +%s)" -lt "$DEADLINE_EPOCH" ]; do
  if [ -e "$STOP" ]; then
    if ! terminate_child; then
      error "candidate required forced termination; logs preserved"
      exit 6
    fi
    echo "m2-joined-provider: stopped"
    exit 0
  fi
  if ! child_running; then
    if wait "$CHILD_PID"; then child_status=0; else child_status=$?; fi
    CHILD_PID=
    error "candidate exited before readiness (status $child_status); logs preserved"
    exit 4
  fi

  if [ -z "$CONTROL_SOCKET" ]; then
    socket_candidates=$(
      { /usr/sbin/lsof -a -p "$CHILD_PID" -U -Fn 2>/dev/null || true; } |
        /usr/bin/awk 'BEGIN { prefix = "n/private/tmp/macprovider-autotune-"; suffix = "/control.sock" } index($0, prefix) == 1 { middle = substr($0, length(prefix) + 1, length($0) - length(prefix) - length(suffix)); if (middle != "" && index(middle, "/") == 0 && substr($0, length($0) - length(suffix) + 1) == suffix) print substr($0, 2) }'
    )
    socket_count=$(printf '%s\n' "$socket_candidates" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')
    if [ "$socket_count" -eq 1 ]; then
      candidate_socket=$socket_candidates
      candidate_root=${candidate_socket%/control.sock}
      root_name=${candidate_root##*/}
      root_stat=$(/usr/bin/stat -f '%u:%Lp' "$candidate_root" 2>/dev/null || true)
      socket_owner=$(/usr/bin/stat -f '%u' "$candidate_socket" 2>/dev/null || true)
      current_uid=$(/usr/bin/id -u)
      case "$root_name" in
        macprovider-autotune-*) root_name_ok=1 ;;
        *) root_name_ok=0 ;;
      esac
      if [ "$root_name_ok" -eq 1 ] &&
         [ "$root_stat" = "$current_uid:700" ] &&
         [ "$socket_owner" = "$current_uid" ] &&
         [ -S "$candidate_socket" ] &&
         [ -f "$candidate_root/lifecycle/state-v1.json" ]; then
        CONTROL_SOCKET=$candidate_socket
        printf '%s\n' "$CONTROL_SOCKET" > "$OUTPUT/.control-socket.txt.tmp"
        /bin/mv "$OUTPUT/.control-socket.txt.tmp" "$OUTPUT/control-socket.txt"
      fi
    fi
  fi

  if [ -n "$CONTROL_SOCKET" ] &&
     /usr/bin/curl -fsS --connect-timeout 1 --max-time 4 \
       http://127.0.0.1:18080/v1/status 2>/dev/null |
       /usr/bin/python3 -c '
import json
import sys
try:
    status = json.load(sys.stdin)
    ready = (
        status.get("coordinator_origin") == "wss://coordinator.malibu.tech"
        and status.get("coordinator", {}).get("connected") is True
        and status.get("network_state") == "buyer_serving"
        and status.get("catalog", {}).get("state") == "live_verified"
        and status.get("catalog", {}).get("catalog_key") == sys.argv[3]
        and status.get("catalog", {}).get("model_id") == sys.argv[4]
        and status.get("status") == "ready"
        and status.get("model_loaded") is True
        and status.get("model") == sys.argv[1]
        and status.get("model_hash") == sys.argv[2]
    )
except (AttributeError, TypeError, ValueError):
    ready = False
sys.exit(0 if ready else 1)
' "$MODEL" "$MODEL_HASH" "$CATALOG_KEY" "$CATALOG_MODEL_ID"; then
    printf 'ready_at_utc=%s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUTPUT/.READY.tmp"
    /bin/mv "$OUTPUT/.READY.tmp" "$READY"
    break
  fi
  /bin/sleep 2
done

if [ ! -f "$READY" ]; then
  error "candidate readiness deadline expired; logs preserved"
  exit 5
fi

while [ "$(/bin/date +%s)" -lt "$DEADLINE_EPOCH" ]; do
  if [ -e "$STOP" ]; then
    if ! terminate_child; then
      error "candidate required forced termination; logs preserved"
      exit 6
    fi
    echo "m2-joined-provider: stopped"
    exit 0
  fi
  if ! child_running; then
    if wait "$CHILD_PID"; then child_status=0; else child_status=$?; fi
    CHILD_PID=
    error "candidate exited while awaiting STOP (status $child_status); logs preserved"
    exit 4
  fi
  /bin/sleep 2
done

error "candidate deadline expired before STOP; logs preserved"
exit 5
