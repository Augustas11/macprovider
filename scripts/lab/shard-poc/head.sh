#!/bin/bash
# Issue #2417 proof of concept, head side: run the first part of the model
# split on this Mac, link it to the member over Tailscale, and measure.
#
#   bash scripts/lab/shard-poc/head.sh --member <address> --member-memory-gb <N>
#   bash scripts/lab/shard-poc/head.sh --baseline      # same model, this Mac alone
#   bash scripts/lab/shard-poc/head.sh --rehearse      # head and member on this Mac
#   bash scripts/lab/shard-poc/head.sh --cleanup
#
# Same download and verification as member.sh (only the files this Mac's
# layers need). Starts `serve --shard-group` with local HTTP only (--no-join),
# sends the fixed prompts in prompts.json at 1, 2 and 4 streamed requests in
# flight, prints a markdown table and writes results.json, then stops
# everything it started. It never touches an installed provider, its config,
# its ports or its launchd jobs, and pauses nothing: if this Mac's free memory
# is short (for example, a live provider holds a model), it stops with a
# message instead of loading.
#
# Options:
#   --member ADDR          member Mac's Tailscale address (100.64.0.0/10)
#   --member-memory-gb N   the member Mac's memory, as member.sh prints it
#                          (required with --member); sets the split
#   --member-port N        member stage port (default 47101)
#   --model big|small      big (default): Llama 3.3 70B 4-bit, 39.7 GB, too large
#                          for one 32 GB Mac. small: Llama 3.2 3B, a quick link
#                          check only; any Mac runs it alone
#   --rehearse             start a member on this Mac too (two processes, linked
#                          over this Mac's own Tailscale address); needs memory
#                          for both parts
#   --baseline             plain `serve --no-join`, the whole model on this Mac;
#                          skipped when the model does not fit this Mac
#   --port N               local HTTP port of the head (default 18190; 18192 baseline)
#   --split N              head serves layers 0:N, member N:end (default: from
#                          the two Macs' memory; must match the member)
#   --max-sequences N      requests in flight the group admits (default 4)
#   --max-context N        tokens per request (default 4096)
#   --levels L             concurrency levels (default 1,2,4)
#   --max-tokens N         output tokens per request (default 128)
#   --rounds N             waves per level (default 2)
#   --heartbeat-ms N --heartbeat-misses N --decode-hop-ms N
#   --prefill-chunk-ms N --replay-ms N --prefill-chunk-tokens N
#   --cli-version vX.Y.Z   --workdir DIR (default ~/shard-poc)
#   --cleanup              remove the working folder and anything this test created
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

MEMBER=""; MEMBER_PORT=$STAGE_PORT_DEFAULT; MEMBER_MEMORY_GB=""; MODE=shard; HTTP_PORT=""
MODEL=$MODEL_DEFAULT; SPLIT=""; MAX_SEQUENCES=$MAX_SEQUENCES_DEFAULT; MAX_CONTEXT=$MAX_CONTEXT_DEFAULT
LEVELS="1,2,4"; MAX_TOKENS=128; ROUNDS=2; PREFILL_CHUNK_TOKENS=$PREFILL_CHUNK_TOKENS_DEFAULT
HEARTBEAT_MS=$HEARTBEAT_MS_DEFAULT; HEARTBEAT_MISSES=$HEARTBEAT_MISSES_DEFAULT; DECODE_HOP_MS=$DECODE_HOP_MS_DEFAULT
PREFILL_CHUNK_MS=$PREFILL_CHUNK_MS_DEFAULT; REPLAY_MS=$REPLAY_MS_DEFAULT
CLI_VERSION=$CLI_VERSION_DEFAULT; ROOT="$HOME/shard-poc"; CLEANUP=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --member) MEMBER="$2"; shift 2 ;;
    --member-memory-gb) MEMBER_MEMORY_GB="$2"; shift 2 ;;
    --member-port) MEMBER_PORT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
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
select_model "$MODEL"
if ! python3 -I -c 'import sys' >/dev/null 2>&1; then die "python3 is needed for the load driver"; fi
check_supervision
[ "$MAX_SEQUENCES" -ge 1 ] 2>/dev/null || die "--max-sequences must be 1 or more"
[ "$MAX_CONTEXT" -ge 4000 ] 2>/dev/null || die "--max-context must be 4000 or more (the CLI's minimum for a stage)"
for l in $(printf '%s' "$LEVELS" | tr ',' ' '); do
  [ "$l" -ge 1 ] 2>/dev/null && [ "$l" -le "$MAX_SEQUENCES" ] || die "--levels $LEVELS: each level must be within 1..$MAX_SEQUENCES (--max-sequences)"
done
MEMORY_GB="$(hw_gb)"
case "$MODE" in
  shard)
    [ -n "$MEMBER" ] || die "--member is required (the member Mac's Tailscale address), or use --rehearse or --baseline"
    is_tailscale_addr "$MEMBER" || die "--member $MEMBER is not a Tailscale address (100.64.0.0/10). The stage link is not encrypted; this test runs only over Tailscale"
    [ -n "$MEMBER_MEMORY_GB" ] || die "--member-memory-gb is required: member.sh prints it (\"tell the operator: ... --member-memory-gb N\")"
    [ "$MEMBER_MEMORY_GB" -ge 8 ] 2>/dev/null || die "--member-memory-gb must be a number of GB (8 or more)" ;;
  rehearse)
    MEMBER="$(local_tailscale_addr)" || die "--rehearse links the two processes over this Mac's Tailscale address; Tailscale is not up here"
    MEMBER_MEMORY_GB="$MEMORY_GB" ;;
  baseline) ;;
esac

if [ "$MODEL_KIND" = small ]; then
  log "MODEL: $MODEL_REPO. LINK CHECK ONLY: any Mac runs this model alone, so this run does not test"
  log "MODEL: serving a model too large for one Mac. The default --model big does."
else
  log "MODEL: $MODEL_REPO, $(gb "$MODEL_TENSOR_BYTES") GB of weights, $MODEL_LAYERS layers, verified by $MODEL_VERIFICATION"
fi
FITS_ALONE_HEAD="$(fits_alone "$MEMORY_GB" "$MAX_SEQUENCES" "$MAX_CONTEXT")"
log "this Mac has ${MEMORY_GB} GB. Could it hold the whole model alone ($MAX_SEQUENCES requests x $MAX_CONTEXT tokens, the CLI's fit rule): $FITS_ALONE_HEAD"
FITS_ALONE_MEMBER=""
if [ "$MODE" != baseline ]; then
  FITS_ALONE_MEMBER="$(fits_alone "$MEMBER_MEMORY_GB" "$MAX_SEQUENCES" "$MAX_CONTEXT")"
  log "the member has ${MEMBER_MEMORY_GB} GB. Could it hold the whole model alone: $FITS_ALONE_MEMBER"
  if [ "$FITS_ALONE_HEAD" = no ] && [ "$FITS_ALONE_MEMBER" = no ]; then
    log "neither Mac could serve this model alone: this run tests the aim"
  else
    warn "at least one of the two Macs could serve this model alone: this run does NOT show a model too large for either Mac"
  fi
fi

# --- baseline: the whole model on this Mac, only when it fits -------------------
write_skip() {
  printf '{"schema":"shard-poc-2417.result.v1","label":"%s","skipped":true,"reason":"%s","model_repo":"%s","model_revision":"%s","model_tensor_bytes":%s,"head_memory_gb":%s,"fits_alone_head":%s}\n' \
    "$MODE" "$1" "$MODEL_REPO" "$MODEL_REV" "$MODEL_TENSOR_BYTES" "$MEMORY_GB" "$([ "$FITS_ALONE_HEAD" = yes ] && echo true || echo false)" >"$OUT/results.json"
  printf 'Baseline skipped: %s\n' "$1" >"$OUT/results.md"
}
if [ "$MODE" = baseline ]; then
  if [ "$FITS_ALONE_HEAD" != yes ]; then
    read -r W D B _ <<EOF
$(stage_fit "$MEMORY_GB" 0 "$MODEL_LAYERS" "$MAX_SEQUENCES" "$MAX_CONTEXT")
EOF
    REASON="the whole model does not fit this ${MEMORY_GB} GB Mac: weights $(gib "$W") GiB, KV demand $(gib "$D") GiB, KV budget $(gib "$B") GiB (the CLI's fit rule)"
    log "--baseline skipped: $REASON. Loading it anyway would push the Mac into swap, so the script stops here"
    write_skip "$REASON"
    log "results: $OUT"
    exit 0
  fi
  HEAD_START=0; HEAD_END=$MODEL_LAYERS
else
  if [ -z "$SPLIT" ]; then
    SPLIT="$(plan_split "$MEMORY_GB" "$MEMBER_MEMORY_GB" "$MAX_SEQUENCES" "$MAX_CONTEXT")"
    [ -n "$SPLIT" ] || die "no split of $MODEL_LAYERS layers fits this ${MEMORY_GB} GB Mac and a ${MEMBER_MEMORY_GB} GB member at $MAX_SEQUENCES requests x $MAX_CONTEXT tokens"
    log "split from memory (this Mac ${MEMORY_GB} GB, member ${MEMBER_MEMORY_GB} GB): this Mac 0:$SPLIT, member $SPLIT:$MODEL_LAYERS"
    [ "$MODE" != shard ] || [ "$MEMORY_GB" = "$HEAD_MEMORY_GB_DEFAULT" ] \
      || warn "this Mac has ${MEMORY_GB} GB, not ${HEAD_MEMORY_GB_DEFAULT}: the member must run member.sh with --head-memory-gb $MEMORY_GB (or --layers $SPLIT:$MODEL_LAYERS)"
  fi
  [ "$SPLIT" -ge 1 ] 2>/dev/null && [ "$SPLIT" -lt "$MODEL_LAYERS" ] || die "--split must be within 1..$((MODEL_LAYERS - 1))"
  HEAD_START=0; HEAD_END=$SPLIT
  report_stage "this Mac" "$MEMORY_GB" 0 "$SPLIT" "$MAX_SEQUENCES" "$MAX_CONTEXT"
  report_stage "member" "$MEMBER_MEMORY_GB" "$SPLIT" "$MODEL_LAYERS" "$MAX_SEQUENCES" "$MAX_CONTEXT"
  for r in "$MEMORY_GB 0 $SPLIT" "$MEMBER_MEMORY_GB $SPLIT $MODEL_LAYERS"; do
    # shellcheck disable=SC2086 # three numbers
    set -- $r
    [ "$(stage_fit "$1" "$2" "$3" "$MAX_SEQUENCES" "$MAX_CONTEXT" | awk '{ print $4 }')" = yes ] \
      || die "layers $2:$3 do not fit a ${1} GB Mac by the CLI's rule; the CLI would refuse to start"
  done
fi
read -r HEAD_W HEAD_D HEAD_B _ <<EOF
$(stage_fit "$MEMORY_GB" "$HEAD_START" "$HEAD_END" "$MAX_SEQUENCES" "$MAX_CONTEXT")
EOF
HEAD_NEED=$(awk -v w="$HEAD_W" -v d="$HEAD_D" -v m="$RUNTIME_MARGIN_BYTES" 'BEGIN { printf "%.0f", w + d + m }')
warn_gpu_limit "$MEMORY_GB" "$(awk -v w="$HEAD_W" -v d="$HEAD_D" 'BEGIN { printf "%.0f", w + d }')"
DOWNLOAD_BYTES="$(stage_download_bytes "$HEAD_START" "$HEAD_END")"
NEED_NOW="$HEAD_NEED"
if [ "$MODE" = rehearse ]; then
  read -r MW MD _ _ <<EOF
$(stage_fit "$MEMORY_GB" "$SPLIT" "$MODEL_LAYERS" "$MAX_SEQUENCES" "$MAX_CONTEXT")
EOF
  NEED_NOW=$(awk -v h="$HEAD_NEED" -v w="$MW" -v d="$MD" -v m="$RUNTIME_MARGIN_BYTES" 'BEGIN { printf "%.0f", h + w + d + m }')
  DOWNLOAD_BYTES=$(awk -v a="$DOWNLOAD_BYTES" -v b="$(stage_download_bytes "$SPLIT" "$MODEL_LAYERS")" 'BEGIN { printf "%.0f", a + b }')
fi
check_host "$ROOT" "$(awk -v b="$DOWNLOAD_BYTES" 'BEGIN { printf "%d", b / 1e9 + 3 }')"
check_memory_for "$NEED_NOW" "$([ "$MODE" = rehearse ] && echo "both parts on this Mac" || echo "layers $HEAD_START:$HEAD_END on this Mac") (weights, KV and a margin)"
report_existing_install
port_free "$HTTP_PORT" || die "port $HTTP_PORT is in use; pick another with --port"

fetch_cli "$ROOT" "$CLI_VERSION"
fetch_model "$ROOT" "$HEAD_START" "$HEAD_END"
HEAD_MODEL_DIR="$MODEL_DIR"; HEAD_MANIFEST="$MANIFEST_PATH"
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
    --model "$MODEL" --stage-port "$MEMBER_PORT" --port "$MEMBER_HTTP_PORT_DEFAULT" --layers "$SPLIT:$MODEL_LAYERS" \
    --max-sequences "$MAX_SEQUENCES" --max-context "$MAX_CONTEXT" --cli-version "$CLI_VERSION" \
    --heartbeat-ms "$HEARTBEAT_MS" --heartbeat-misses "$HEARTBEAT_MISSES" --decode-hop-ms "$DECODE_HOP_MS" \
    --prefill-chunk-ms "$PREFILL_CHUNK_MS" --replay-ms "$REPLAY_MS" >/dev/null 2>&1 &
  MEMBER_PID=$!
  log "rehearsal member started (pid $MEMBER_PID); waiting for it to download, check and load layers $SPLIT:$MODEL_LAYERS"
  t=0
  while :; do
    # shellcheck disable=SC2012 # newest log by mtime; names are fixed
    MLOG="$(ls -t "$ROOT"/member-rehearse/member-*.log 2>/dev/null | head -1 || true)"
    [ -n "$MLOG" ] && grep -q "listening on" "$MLOG" && break
    kill -0 "$MEMBER_PID" 2>/dev/null || die "the rehearsal member exited; see $ROOT/member-rehearse/"
    # No limit while it downloads; 1800 s for the check and load after that.
    [ -n "$MLOG" ] && grep -q "member started" "$MLOG" && { [ "$t" -lt 1800 ] || die "the rehearsal member was not ready after 1800 s"; t=$((t + 2)); }
    sleep 2
  done
  log "rehearsal member listening ($MLOG)"
  check_memory_for "$HEAD_NEED" "layers 0:$SPLIT on this Mac, next to the rehearsal member"
else
  check_memory_for "$HEAD_NEED" "layers $HEAD_START:$HEAD_END on this Mac"
fi

# --- server -------------------------------------------------------------------
RUN="$ROOT/$MODE"; write_serve_config "$RUN"
# shellcheck disable=SC2086 # SERVE_COMMON_FLAGS is a fixed word list
if [ "$MODE" = baseline ]; then
  # The folder holds every file of the snapshot, each checked against its
  # pinned SHA-256, so plain serve loads it as a local model.
  set -- "$CLI" serve --config "$RUN/config.yaml" $SERVE_COMMON_FLAGS --port "$HTTP_PORT" --model "$HEAD_MODEL_DIR" \
    --max-batch "$MAX_SEQUENCES" --max-context "$MAX_CONTEXT"
else
  # Lab chain: the member's id is stage-1 (its ephemeral signer, see member.sh);
  # no member key, so this head serves only local HTTP and never registers.
  MODEL_DIR="$HEAD_MODEL_DIR"; MANIFEST_PATH="$HEAD_MANIFEST"
  cat >"$RUN/group.json" <<JSON
{"schema":"macprovider.shard-group-config.v1","group_epoch":1,"interconnect_class":"ethernet","frame_protection":"hmac-sha256","head_layer_end":$SPLIT,"stages":[{"member_device_id":"stage-1","endpoint":"$MEMBER:$MEMBER_PORT","layer_start":$SPLIT,"layer_end":$MODEL_LAYERS}],"max_concurrency":$MAX_SEQUENCES,"prefill_chunk_tokens":$PREFILL_CHUNK_TOKENS,"supervision":$(supervision_json)$(snapshot_manifest_json)}
JSON
  chmod 600 "$RUN/group.json"
  cp "$RUN/group.json" "$OUT/group.json"
  # The head records its chain epoch in this file (ShardGroupEpochStore); note
  # it for --cleanup if this run creates it.
  EPOCH_FILE="$HOME/Library/Application Support/macprovider/shard-groups/head.json"
  [ -e "$EPOCH_FILE" ] || printf '%s\n' "$EPOCH_FILE" >>"$ROOT/.cli-side-dirs-created"
  MODEL_FLAGS=()
  while IFS= read -r f; do MODEL_FLAGS+=("$f"); done <<EOF
$(model_serve_flags)
EOF
  set -- "$CLI" serve --config "$RUN/config.yaml" $SERVE_COMMON_FLAGS --port "$HTTP_PORT" "${MODEL_FLAGS[@]}" \
    --max-context "$MAX_CONTEXT" --shard-group "$RUN/group.json"
fi
log "serve command: $*"
SLOG="$OUT/server.log"
"$@" >"$SLOG" 2>&1 &
HEAD_PID=$!
log "server started (pid $HEAD_PID); the CLI checks the files, loads them and links to the member; waiting for local HTTP on port $HTTP_PORT"
t=0
until curl -fsS --max-time 2 "http://127.0.0.1:$HTTP_PORT/v1/models" >/dev/null 2>&1; do
  kill -0 "$HEAD_PID" 2>/dev/null || { tail -20 "$SLOG"; die "the server exited before it was ready (log: $SLOG)"; }
  [ "$t" -lt 1800 ] || die "the server was not ready after 1800 s (log: $SLOG)"
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
jbool() { case "$1" in yes) echo true ;; no) echo false ;; *) echo null ;; esac; }
NEITHER=null
[ "$MODE" = baseline ] || { [ "$FITS_ALONE_HEAD" = no ] && [ "$FITS_ALONE_MEMBER" = no ] && NEITHER=true || NEITHER=false; }
if [ "$MODE" = baseline ]; then SPLIT_TEXT="0:$MODEL_LAYERS (one Mac)"; else SPLIT_TEXT="0:$SPLIT/$SPLIT:$MODEL_LAYERS"; fi
EXTRA="$(printf '%s' "$RTT_JSON" | sed 's/}$//')"
[ "$EXTRA" = "{" ] && EXTRA="{" || EXTRA="$EXTRA,"
EXTRA="$EXTRA$(printf '"mode":"%s","cli_version":"%s","model_repo":"%s","model_revision":"%s","model_verification":"%s","model_tensor_bytes":%s,"head_download_bytes":%s,"head_stage_weight_bytes":%s,"head_stage_kv_demand_bytes":%s,"head_stage_kv_budget_bytes":%s,"head_memory_gb":%s,"member_memory_gb":%s,"fits_alone_head":%s,"fits_alone_member":%s,"neither_alone":%s,"split":"%s","supervision":%s,"prefill_chunk_tokens":%s,"max_sequences":%s,"max_context":%s,"host_chip":"%s"}' \
  "$MODE" "$CLI_VERSION" "$MODEL_REPO" "$MODEL_REV" "$MODEL_VERIFICATION" "$MODEL_TENSOR_BYTES" "$(stage_download_bytes "$HEAD_START" "$HEAD_END")" \
  "$HEAD_W" "$HEAD_D" "$HEAD_B" "$MEMORY_GB" "${MEMBER_MEMORY_GB:-null}" "$(jbool "$FITS_ALONE_HEAD")" "$(jbool "$FITS_ALONE_MEMBER")" "$NEITHER" \
  "$SPLIT_TEXT" "$(supervision_json)" "$PREFILL_CHUNK_TOKENS" "$MAX_SEQUENCES" "$MAX_CONTEXT" "$(sysctl -n machdep.cpu.brand_string)")"
log "driving $LEVELS requests in flight, $MAX_TOKENS tokens each, $ROUNDS rounds"
python3 -I "$SHARD_POC_DIR/drive.py" --url "http://127.0.0.1:$HTTP_PORT" --prompts "$SHARD_POC_DIR/prompts.json" \
  --levels "$LEVELS" --max-tokens "$MAX_TOKENS" --rounds "$ROUNDS" --label "$MODE" --out "$OUT" --extra "$EXTRA"
curl -fsS --max-time 5 "http://127.0.0.1:$HTTP_PORT/v1/status" >"$OUT/status-after.json" 2>/dev/null || true
grep -E "shard-group: " "$SLOG" >"$OUT/shard-group-lines.txt" 2>/dev/null || true
[ -n "${MLOG:-}" ] && cp "$MLOG" "$OUT/member.log"
log "done: $OUT/results.md and $OUT/results.json"
