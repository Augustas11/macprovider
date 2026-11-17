#!/bin/bash
# Issue #2417 proof of concept: run the second half of a two-Mac model split
# (shard group member) on this Mac, over Tailscale, for one test session.
#
#   bash scripts/lab/shard-poc/member.sh --peer <head Mac's Tailscale address>
#   bash scripts/lab/shard-poc/member.sh --cleanup
#
# What it does: checks this Mac, downloads and verifies the public macprovider
# CLI release and the test model into ~/shard-poc, writes the member config
# from the flags below, and runs `macprovider-cli serve --shard-member` with
# local HTTP only (--no-join): no account, no token, no coordinator, no
# service, no launchd job. Ctrl-C stops it. See README.md in this folder.
#
# Options (all optional except --peer):
#   --peer ADDR            head Mac's Tailscale address (100.64.0.0/10)
#   --listen ADDR          this Mac's Tailscale address (default: detected)
#   --stage-port N         stage link port (default 47101)
#   --port N               local HTTP port of this process (default 18191)
#   --layers A:B           layers this Mac serves (default 14:28)
#   --max-sequences N      requests in flight (default 8, must match the head)
#   --max-context N        tokens per request (default 4096, must match the head)
#   --heartbeat-ms N --heartbeat-misses N --decode-hop-ms N
#   --prefill-chunk-ms N --replay-ms N   link supervision (WAN defaults)
#   --cli-version vX.Y.Z   public CLI release (default pinned in common.sh)
#   --workdir DIR          working folder (default ~/shard-poc)
#   --prepare-only         check, download and verify, write the config, print
#                          the serve command, then exit without starting it
#   --cleanup              remove the working folder and anything this test created
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

PEER=""; LISTEN=""; STAGE_PORT=$STAGE_PORT_DEFAULT; HTTP_PORT=$MEMBER_HTTP_PORT_DEFAULT
LAYERS="$SPLIT_LAYER_DEFAULT:$MODEL_LAYERS"; MAX_SEQUENCES=$MAX_SEQUENCES_DEFAULT; MAX_CONTEXT=$MAX_CONTEXT_DEFAULT
HEARTBEAT_MS=$HEARTBEAT_MS_DEFAULT; HEARTBEAT_MISSES=$HEARTBEAT_MISSES_DEFAULT; DECODE_HOP_MS=$DECODE_HOP_MS_DEFAULT
PREFILL_CHUNK_MS=$PREFILL_CHUNK_MS_DEFAULT; REPLAY_MS=$REPLAY_MS_DEFAULT
CLI_VERSION=$CLI_VERSION_DEFAULT; ROOT="$HOME/shard-poc"; RUN_NAME=member; PREPARE_ONLY=0; CLEANUP=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --peer) PEER="$2"; shift 2 ;;
    --listen) LISTEN="$2"; shift 2 ;;
    --stage-port) STAGE_PORT="$2"; shift 2 ;;
    --port) HTTP_PORT="$2"; shift 2 ;;
    --layers) LAYERS="$2"; shift 2 ;;
    --max-sequences) MAX_SEQUENCES="$2"; shift 2 ;;
    --max-context) MAX_CONTEXT="$2"; shift 2 ;;
    --heartbeat-ms) HEARTBEAT_MS="$2"; shift 2 ;;
    --heartbeat-misses) HEARTBEAT_MISSES="$2"; shift 2 ;;
    --decode-hop-ms) DECODE_HOP_MS="$2"; shift 2 ;;
    --prefill-chunk-ms) PREFILL_CHUNK_MS="$2"; shift 2 ;;
    --replay-ms) REPLAY_MS="$2"; shift 2 ;;
    --cli-version) CLI_VERSION="$2"; shift 2 ;;
    --workdir) ROOT="$2"; shift 2 ;;
    --run-name) RUN_NAME="$2"; shift 2 ;;   # head.sh --rehearse uses this
    --prepare-only) PREPARE_ONLY=1; shift ;;
    --cleanup) CLEANUP=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
done

if [ "$CLEANUP" = 1 ]; then cleanup_root "$ROOT"; exit 0; fi

init_root "$ROOT"
RUN="$ROOT/$RUN_NAME"; mkdir -p "$RUN"; chmod 700 "$RUN"
LOG="$RUN/member-$(date +%Y%m%d-%H%M%S).log"
# The script's output and the CLI's output both go to the screen and the log.
exec > >(trap '' INT TERM; tee -a "$LOG") 2>&1

log "shard-poc member, issue #2417, repo commit $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "log file: $LOG"

# --- checks -------------------------------------------------------------------
[ -n "$PEER" ] || die "--peer is required: the head Mac's Tailscale address (ask the operator)"
is_tailscale_addr "$PEER" || die "--peer $PEER is not a Tailscale address (100.64.0.0/10)"
if [ -z "$LISTEN" ]; then
  LISTEN="$(local_tailscale_addr)" || die "no Tailscale address on this Mac. Install Tailscale, sign in, and run again"
fi
is_tailscale_addr "$LISTEN" || die "--listen $LISTEN is not a Tailscale address (100.64.0.0/10). This test refuses any other network"
is_local_addr "$LISTEN" || die "--listen $LISTEN is not an address of this Mac"
log "SECURITY: the stage link between the two Macs is NOT encrypted by the CLI and, in this lab mode,"
log "SECURITY: does not check which Mac connects. Only Tailscale (encrypted, limited to machines you"
log "SECURITY: share) protects it. That is why this script listens only on this Mac's Tailscale address."
case "$LAYERS" in *:*) LAYER_START="${LAYERS%%:*}"; LAYER_END="${LAYERS##*:}" ;; *) die "--layers must be A:B" ;; esac
[ "$LAYER_START" -ge 1 ] 2>/dev/null && [ "$LAYER_END" -gt "$LAYER_START" ] && [ "$LAYER_END" -le "$MODEL_LAYERS" ] \
  || die "--layers $LAYERS must be within 1:$MODEL_LAYERS"
check_supervision
check_host "$ROOT" 3
report_existing_install
for p in "$HTTP_PORT" "$STAGE_PORT"; do port_free "$p" || die "port $p is in use; pick another with --port or --stage-port"; done

# --- downloads ----------------------------------------------------------------
fetch_cli "$ROOT" "$CLI_VERSION"
fetch_model "$ROOT"

# --- config -------------------------------------------------------------------
# Lab chain (no member keys): the member signs with an ephemeral key under the
# id stage-<index> (ShardMemberRuntime.swift ShardGroupServe.signer), which the
# head's group config names. interconnect_class ethernet needs hmac-sha256 frame
# protection: frames carry an HMAC under a per-session key agreement, which
# detects changed frames but does not hide them.
write_serve_config "$RUN"
STAGE_INDEX=1
cat >"$RUN/shard-member.json" <<JSON
{"schema":"macprovider.shard-member-config.v1","group_provider_id":"head","group_epoch":1,"role":"stage","stage_index":$STAGE_INDEX,"layer_start":$LAYER_START,"layer_end":$LAYER_END,"listen":"$LISTEN:$STAGE_PORT","interconnect_class":"ethernet","frame_protection":"hmac-sha256","max_sequences":$MAX_SEQUENCES,"max_context_tokens":$MAX_CONTEXT,"supervision":$(supervision_json)}
JSON
chmod 600 "$RUN/shard-member.json"
log "member config: $RUN/shard-member.json"
cat "$RUN/shard-member.json"; echo

clean_env
# shellcheck disable=SC2086 # SERVE_COMMON_FLAGS is a fixed word list
set -- "$CLI" serve --config "$RUN/config.yaml" $SERVE_COMMON_FLAGS --port "$HTTP_PORT" \
  --model "$MODEL_DIR" --shard-member "$RUN/shard-member.json"
log "serve command: $*"
if [ "$PREPARE_ONLY" = 1 ]; then
  log "--prepare-only: everything is downloaded and verified; not starting the member"
  exit 0
fi

# --- run ----------------------------------------------------------------------
SERVE_PID=""
finish() {
  local code=$?
  trap - INT TERM EXIT
  stop_pid "$SERVE_PID" "the member"
  log "stopped. To remove everything this test created: bash $SHARD_POC_DIR/member.sh --cleanup"
  log "log file: $LOG"
  sleep 1; share_copy "$LOG"
  log "copy to attach to the GitHub issue (Tailscale addresses and home path removed): ${LOG%.log}.share.log"
  exit "$code"
}
trap finish EXIT
trap 'exit 130' INT TERM

"$@" &
SERVE_PID=$!
log "member started (pid $SERVE_PID); loading layers $LAYER_START:$LAYER_END"
t=0
until grep -q "listening on" "$LOG" 2>/dev/null; do
  kill -0 "$SERVE_PID" 2>/dev/null || die "the member exited before it was ready; see the lines above"
  [ "$t" -lt 600 ] || die "the member was not ready after 600 s"
  sleep 1; t=$((t + 1))
done
cat <<EOF

================================================================================
 RUNNING: macprovider-cli $CLI_VERSION, shard group member (layers $LAYER_START:$LAYER_END
 of $MODEL_REPO), listening for the head on this Mac's Tailscale address,
 port $STAGE_PORT. Expected head: $PEER.
 It takes no requests of its own. It runs only while this window is open.
 Stop:         press Ctrl-C
 Remove all:   bash $SHARD_POC_DIR/member.sh --cleanup
 Log file:     $LOG
================================================================================

EOF
wait "$SERVE_PID" || true
SERVE_PID=""
log "the member process exited"
