#!/bin/bash
# Issue #2417 proof of concept, head side: run the first half of the model
# split on this Mac, link it to the member over Tailscale, and measure.
#
#   bash scripts/lab/shard-poc/head.sh --member <member Mac's Tailscale address>
#   bash scripts/lab/shard-poc/head.sh --baseline      # same model, this Mac alone
#   bash scripts/lab/shard-poc/head.sh --rehearse      # head and member on this Mac
#   bash scripts/lab/shard-poc/head.sh --cleanup
#
# Same download and verification as member.sh. Starts `serve --shard-group`
# with local HTTP only (--no-join), sends the fixed prompts in prompts.json at
# 1, 4 and 8 streamed requests in flight, prints a markdown table and writes
# results.json, then stops everything it started. It never touches an installed
# provider, its config, its ports or its launchd jobs, and pauses nothing:
# GPU time on a Mac that serves live traffic is the operator's call.
#
# Options:
#   --member ADDR          member Mac's Tailscale address (100.64.0.0/10)
#   --member-port N        member stage port (default 47101)
#   --rehearse             start a member on this Mac too (two processes, linked
#                          over this Mac's own Tailscale address)
#   --baseline             plain `serve --no-join`, the whole model on this Mac
#   --port N               local HTTP port of the head (default 18190; 18192 baseline)
#   --split N              head serves layers 0:N, member N:28 (default 14)
#   --max-sequences N      requests in flight the group admits (default 8)
#   --max-context N        tokens per request (default 4096)
#   --levels L             concurrency levels (default 1,4,8)
#   --max-tokens N         output tokens per request (default 128)
#   --rounds N             waves per level (default 2)
#   --heartbeat-ms N --heartbeat-misses N --decode-hop-ms N
#   --prefill-chunk-ms N --replay-ms N --prefill-chunk-tokens N
#   --cli-version vX.Y.Z   --workdir DIR (default ~/shard-poc)
#   --cleanup              remove the working folder and anything this test created
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

MEMBER=""; MEMBER_PORT=$STAGE_PORT_DEFAULT; MODE=shard; HTTP_PORT=""
SPLIT=$SPLIT_LAYER_DEFAULT; MAX_SEQUENCES=$MAX_SEQUENCES_DEFAULT; MAX_CONTEXT=$MAX_CONTEXT_DEFAULT
LEVELS="1,4,8"; MAX_TOKENS=128; ROUNDS=2; PREFILL_CHUNK_TOKENS=$PREFILL_CHUNK_TOKENS_DEFAULT
HEARTBEAT_MS=$HEARTBEAT_MS_DEFAULT; HEARTBEAT_MISSES=$HEARTBEAT_MISSES_DEFAULT; DECODE_HOP_MS=$DECODE_HOP_MS_DEFAULT
PREFILL_CHUNK_MS=$PREFILL_CHUNK_MS_DEFAULT; REPLAY_MS=$REPLAY_MS_DEFAULT
CLI_VERSION=$CLI_VERSION_DEFAULT; ROOT="$HOME/shard-poc"; CLEANUP=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --member) MEMBER="$2"; shift 2 ;;
    --member-port) MEMBER_PORT="$2"; shift 2 ;;
    --rehearse) MODE=rehearse; shift ;;
    --baseline) MODE=baseline; shift ;;
    --port) HTTP_PORT="$2"; shift 2 ;;
    --split) SPLIT="$2"; shift 2 ;;
    --max-sequences) MAX_SEQUENCES="$2"; shift 2 ;;
    --max-context) MAX_CONTEXT="$2"; shift 2 ;;
    --levels) LEVELS="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    --heartbeat-ms) HEARTBEAT_MS="$2"; shift 2 ;;
    --heartbeat-misses) HEARTBEAT_MISSES="$2"; shift 2 ;;
    --decode-hop-ms) DECODE_HOP_MS="$2"; shift 2 ;;
    --prefill-chunk-ms) PREFILL_CHUNK_MS="$2"; shift 2 ;;
    --replay-ms) REPLAY_MS="$2"; shift 2 ;;
    --prefill-chunk-tokens) PREFILL_CHUNK_TOKENS="$2"; shift 2 ;;
    --cli-version) CLI_VERSION="$2"; shift 2 ;;
    --workdir) ROOT="$2"; shift 2 ;;
    --cleanup) CLEANUP=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
done

if [ "$CLEANUP" = 1 ]; then cleanup_root "$ROOT"; exit 0; fi
if [ -z "$HTTP_PORT" ]; then
  if [ "$MODE" = baseline ]; then HTTP_PORT=$BASELINE_HTTP_PORT_DEFAULT; else HTTP_PORT=$HEAD_HTTP_PORT_DEFAULT; fi
fi

init_root "$ROOT"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/results/$MODE-$STAMP"; mkdir -p "$OUT"
LOG="$OUT/run.log"
exec > >(trap '' INT TERM; tee -a "$LOG") 2>&1
log "shard-poc head, issue #2417, mode $MODE, repo commit $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --- checks -------------------------------------------------------------------
if ! python3 -I -c 'import sys' >/dev/null 2>&1; then die "python3 is needed for the load driver"; fi
check_supervision
[ "$SPLIT" -ge 1 ] 2>/dev/null && [ "$SPLIT" -lt "$MODEL_LAYERS" ] || die "--split must be within 1..$((MODEL_LAYERS - 1))"
case "$MODE" in
  shard)
    [ -n "$MEMBER" ] || die "--member is required (the member Mac's Tailscale address), or use --rehearse or --baseline"
    is_tailscale_addr "$MEMBER" || die "--member $MEMBER is not a Tailscale address (100.64.0.0/10). The stage link is not encrypted; this test runs only over Tailscale"
    check_host "$ROOT" 3 ;;
  rehearse)
    MEMBER="$(local_tailscale_addr)" || die "--rehearse links the two processes over this Mac's Tailscale address; Tailscale is not up here"
    check_host "$ROOT" 5 ;;
  baseline)
    check_host "$ROOT" 3 ;;
esac
report_existing_install
port_free "$HTTP_PORT" || die "port $HTTP_PORT is in use; pick another with --port"

fetch_cli "$ROOT" "$CLI_VERSION"
fetch_model "$ROOT"
clean_env

HEAD_PID=""; MEMBER_PID=""
finish() {
  local code=$?
  trap - INT TERM EXIT
  stop_pid "$HEAD_PID" "the $MODE server"
  stop_pid "$MEMBER_PID" "the rehearsal member"
  # Safety net: a rehearsal member CLI left behind by a killed wrapper.
  [ "$MODE" != rehearse ] || pkill -TERM -f "$ROOT/member-rehearse/shard-member.json" 2>/dev/null || true
  log "results and logs: $OUT"
  exit "$code"
}
trap finish EXIT
trap 'exit 130' INT TERM

# --- rehearsal member ---------------------------------------------------------
if [ "$MODE" = rehearse ]; then
  port_free "$MEMBER_PORT" || die "stage port $MEMBER_PORT is in use"
  bash "$SHARD_POC_DIR/member.sh" --workdir "$ROOT" --run-name member-rehearse --peer "$MEMBER" --listen "$MEMBER" \
    --stage-port "$MEMBER_PORT" --port "$MEMBER_HTTP_PORT_DEFAULT" --layers "$SPLIT:$MODEL_LAYERS" \
    --max-sequences "$MAX_SEQUENCES" --max-context "$MAX_CONTEXT" --cli-version "$CLI_VERSION" \
    --heartbeat-ms "$HEARTBEAT_MS" --heartbeat-misses "$HEARTBEAT_MISSES" --decode-hop-ms "$DECODE_HOP_MS" \
    --prefill-chunk-ms "$PREFILL_CHUNK_MS" --replay-ms "$REPLAY_MS" >/dev/null 2>&1 &
  MEMBER_PID=$!
  log "rehearsal member started (pid $MEMBER_PID); waiting for it to listen"
  t=0
  while :; do
    # shellcheck disable=SC2012 # newest log by mtime; names are fixed
    MLOG="$(ls -t "$ROOT"/member-rehearse/member-*.log 2>/dev/null | head -1 || true)"
    [ -n "$MLOG" ] && grep -q "listening on" "$MLOG" && break
    kill -0 "$MEMBER_PID" 2>/dev/null || die "the rehearsal member exited; see $ROOT/member-rehearse/"
    [ "$t" -lt 600 ] || die "the rehearsal member was not ready after 600 s"
    sleep 2; t=$((t + 2))
  done
  log "rehearsal member listening ($MLOG)"
fi

# --- server -------------------------------------------------------------------
RUN="$ROOT/$MODE"; write_serve_config "$RUN"
# shellcheck disable=SC2086 # SERVE_COMMON_FLAGS is a fixed word list
if [ "$MODE" = baseline ]; then
  set -- "$CLI" serve --config "$RUN/config.yaml" $SERVE_COMMON_FLAGS --port "$HTTP_PORT" --model "$MODEL_DIR" \
    --max-batch "$MAX_SEQUENCES" --max-context "$MAX_CONTEXT"
else
  # Lab chain: the member's id is stage-1 (its ephemeral signer, see member.sh);
  # no member key, so this head serves only local HTTP and never registers.
  cat >"$RUN/group.json" <<JSON
{"schema":"macprovider.shard-group-config.v1","group_epoch":1,"interconnect_class":"ethernet","frame_protection":"hmac-sha256","head_layer_end":$SPLIT,"stages":[{"member_device_id":"stage-1","endpoint":"$MEMBER:$MEMBER_PORT","layer_start":$SPLIT,"layer_end":$MODEL_LAYERS}],"max_concurrency":$MAX_SEQUENCES,"prefill_chunk_tokens":$PREFILL_CHUNK_TOKENS,"supervision":$(supervision_json)}
JSON
  chmod 600 "$RUN/group.json"
  cp "$RUN/group.json" "$OUT/group.json"
  # The head records its chain epoch in this file (ShardGroupEpochStore); note
  # it for --cleanup if this run creates it.
  EPOCH_FILE="$HOME/Library/Application Support/macprovider/shard-groups/head.json"
  [ -e "$EPOCH_FILE" ] || printf '%s\n' "$EPOCH_FILE" >>"$ROOT/.cli-side-dirs-created"
  set -- "$CLI" serve --config "$RUN/config.yaml" $SERVE_COMMON_FLAGS --port "$HTTP_PORT" --model "$MODEL_DIR" \
    --max-context "$MAX_CONTEXT" --shard-group "$RUN/group.json"
fi
log "serve command: $*"
SLOG="$OUT/server.log"
"$@" >"$SLOG" 2>&1 &
HEAD_PID=$!
log "server started (pid $HEAD_PID); waiting for local HTTP on port $HTTP_PORT"
t=0
until curl -fsS --max-time 2 "http://127.0.0.1:$HTTP_PORT/v1/models" >/dev/null 2>&1; do
  kill -0 "$HEAD_PID" 2>/dev/null || { tail -20 "$SLOG"; die "the server exited before it was ready (log: $SLOG)"; }
  [ "$t" -lt 600 ] || die "the server was not ready after 600 s (log: $SLOG)"
  sleep 2; t=$((t + 2))
done
log "server ready after about ${t} s"
grep -E "shard-group: (hello ok|startup throughput|stage )" "$SLOG" || true

# --- link round trip ----------------------------------------------------------
# The released CLI measures the stage-link round trip (startup probe and
# heartbeats) but reports it only to the coordinator, which a --no-join run
# never reaches. So the round trip here is measured beside the link: ICMP ping
# and, when the Tailscale CLI is present, `tailscale ping` (it also says whether
# the path is direct or relayed).
RTT_JSON='{}'
if [ "$MODE" != baseline ]; then
  PING_OUT="$(ping -c 20 -q "$MEMBER" 2>&1 || true)"
  printf '%s\n' "$PING_OUT" >"$OUT/ping.txt"
  PING_SUMMARY="$(printf '%s\n' "$PING_OUT" | sed -n 's/.*= \([0-9.]*\)\/\([0-9.]*\)\/\([0-9.]*\)\/.*/min \1 avg \2 max \3 ms/p')"
  PING_LOSS="$(printf '%s\n' "$PING_OUT" | grep -Eo '[0-9.]+% packet loss' || true)"
  [ -z "$PING_SUMMARY" ] || PING_SUMMARY="$PING_SUMMARY, $PING_LOSS"
  TS_PATH=""
  TS="$(tailscale_cli || true)"
  if [ -n "$TS" ] && [ "$MODE" = shard ]; then
    "$TS" ping -c 5 "$MEMBER" >"$OUT/tailscale-ping.txt" 2>&1 || true
    TS_PATH="$(grep -Eo 'via (DERP\([^)]*\)|[^ ]+)' "$OUT/tailscale-ping.txt" | tail -1 || true)"
  fi
  RTT_JSON="$(printf '{"link_round_trip":{"source":"ICMP ping over Tailscale, 20 packets","summary":"%s","tailscale_path":"%s"}}' \
    "${PING_SUMMARY:-not measured}" "$TS_PATH")"
  log "link round trip: ${PING_SUMMARY:-not measured} ${TS_PATH}"
fi

# --- load ---------------------------------------------------------------------
curl -fsS --max-time 5 "http://127.0.0.1:$HTTP_PORT/v1/status" >"$OUT/status-before.json" 2>/dev/null || true
EXTRA="$(printf '%s' "$RTT_JSON" | sed 's/}$//')"
[ "$EXTRA" = "{" ] && EXTRA="{" || EXTRA="$EXTRA,"
EXTRA="$EXTRA$(printf '"mode":"%s","cli_version":"%s","model_repo":"%s","model_revision":"%s","split":"0:%s/%s:%s","supervision":%s,"prefill_chunk_tokens":%s,"max_sequences":%s,"max_context":%s,"host_chip":"%s"}' \
  "$MODE" "$CLI_VERSION" "$MODEL_REPO" "$MODEL_REV" "$SPLIT" "$SPLIT" "$MODEL_LAYERS" "$(supervision_json)" \
  "$PREFILL_CHUNK_TOKENS" "$MAX_SEQUENCES" "$MAX_CONTEXT" "$(sysctl -n machdep.cpu.brand_string)")"
log "driving $LEVELS requests in flight, $MAX_TOKENS tokens each, $ROUNDS rounds"
python3 -I "$SHARD_POC_DIR/drive.py" --url "http://127.0.0.1:$HTTP_PORT" --prompts "$SHARD_POC_DIR/prompts.json" \
  --levels "$LEVELS" --max-tokens "$MAX_TOKENS" --rounds "$ROUNDS" --label "$MODE" --out "$OUT" --extra "$EXTRA"
curl -fsS --max-time 5 "http://127.0.0.1:$HTTP_PORT/v1/status" >"$OUT/status-after.json" 2>/dev/null || true
grep -E "shard-group: " "$SLOG" >"$OUT/shard-group-lines.txt" 2>/dev/null || true
[ -n "${MLOG:-}" ] && cp "$MLOG" "$OUT/member.log"
log "done: $OUT/results.md and $OUT/results.json"
