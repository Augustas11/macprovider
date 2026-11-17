#!/usr/bin/env bash
# Parity-grid lab window for one model: stock mlx-lm reference, then our
# provider on a loopback port, then compare.py. Noninteractive.
#
# usage: run-grid.sh --model-path DIR --model-name NAME --bin-dir DIR --out-dir DIR
#                    --python PY [--port 18340] [--cb off|on|canary|auto]
#                    [--serve-env "K=V K2=V2"] [--rows 1,4] [--trials 3]
#                    [--max-context N] [--floor 0.03] [--skip-reference]
#                    [--text-fallback-reason TEXT] [--no-autotune-candidate]
#                    [--margins FILE] [--tie-steps N]
#                    [--serve-arg ARG]... [--sample-seconds N] [--turns 1|2]
#                    [--reference mlx-lm|mlx-vlm] [--ref-arg ARG]... [--ref-model-path DIR]
#                    [--outputs 128,512] [--contexts short,4k|200,4000]
#                    [--model-id ID --model-sha256 SHA] [--config-extra FILE]
#                    [--skip-compare]
#
# --reference picks the reference script: reference_mlxlm.py (default) or
# reference_mlxvlm.py for families mlx-lm cannot load; --ref-arg passes one
# argument through to it (e.g. --ref-arg --refusal-ablation --ref-arg DIR) and
# --ref-model-path points it at another directory than --model-path (the
# unmodified base of a runtime-ablated snapshot). --outputs / --contexts cut
# grid.json (contexts by name or token count) into OUT/grid.json, which both
# sides then read.
# --model-id serves the snapshot under its catalog id (config `model`,
# `model_artifact_path`, `model_artifact_sha256` = --model-sha256, verified by
# the serve) and sends that id as the request model; --config-extra appends
# raw YAML lines to the serve config (e.g. a continuous_batching accepted
# tuple, which a --no-join serve takes as its CB authority). --skip-compare
# stops after the client (exit 7 if it failed, else 0).
#
# --turns 2 adds the two-turn cell: after each turn-1 trial the provider client sends turn 2
# ([user1, assistant1 = its own turn-1 text, short follow-up]) and records TTFT and
# cached_prompt_tokens (turn=2 rows in provider.jsonl). The reference then runs after the
# provider and replays that assistant1 text (--provider-jsonl OUT/provider.jsonl). compare.py
# adds a turn-2 section and fails a cell whose provider reports 0 cached tokens. Default 1:
# nothing changes. With --turns 2, env TURN2_HEADER=1 makes the provider client send
# X-MacProvider-Provider-Conversation (one id per trial and row, on both turns; a --no-join
# serve keys its prefix cache only on it) and TURN2_HISTORY=verbatim re-sends the turn-1
# reasoning as reasoning_content in the turn-2 history (default content: content only). Both
# are provider-client only; the reference is unchanged.
#
# --no-autotune-candidate drops the lab autotune flag from the serve command;
# with --cb off (and native MTP off for a model that has an admission entry)
# the provider then takes its serial-only small-row route, and with --cb auto
# the route a production serve takes. With the flag the serve is an autotune
# child, which always takes the row-invariant route.
#
# Exit code: compare's (0 all cells pass, 1 a cell fails, 2 unusable input),
# or 7 when the client failed (after the compare table is printed); 3, 5, 6
# and 64 before the client runs. Check
# serve/status.json continuous_batching.small_m_route to see which route ran.
#
# --python is an interpreter with mlx_lm installed (reference only); the client
# and compare run under the system python3 -I. The script refuses to start when
# anything listens on 8080 or on --port, and it stops only the serve process it
# started (its own child PID).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PORT=18340
CB=off
SERVE_ENV=""
ROWS=""
TRIALS=""
MAX_CONTEXT=""
FLOOR=0.03
SKIP_REF=0
FALLBACK=""
MARGINS=""
TIE_STEPS=""
AUTOTUNE=1
SAMPLE_SECS=0
SERVE_ARGS=()
TURNS=1
TURN2_HEADER=${TURN2_HEADER:-0}
TURN2_HISTORY=${TURN2_HISTORY:-content}
REFERENCE=mlx-lm
REF_ARGS=()
REF_MODEL_PATH=""
OUTPUTS="" CONTEXTS=""
MODEL_ID="" MODEL_SHA="" CONFIG_EXTRA=""
SKIP_COMPARE=0
MODEL_PATH="" MODEL_NAME="" BIN_DIR="" OUT_DIR="" PY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --model-path) MODEL_PATH="$2"; shift 2 ;;
    --model-name) MODEL_NAME="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --python) PY="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --cb) CB="$2"; shift 2 ;;
    --serve-env) SERVE_ENV="$2"; shift 2 ;;
    --rows) ROWS="$2"; shift 2 ;;
    --trials) TRIALS="$2"; shift 2 ;;
    --max-context) MAX_CONTEXT="$2"; shift 2 ;;
    --floor) FLOOR="$2"; shift 2 ;;
    --skip-reference) SKIP_REF=1; shift ;;
    --no-autotune-candidate) AUTOTUNE=0; shift ;;
    --serve-arg) SERVE_ARGS+=("$2"); shift 2 ;;
    --sample-seconds) SAMPLE_SECS="$2"; shift 2 ;;
    --text-fallback-reason) FALLBACK="$2"; shift 2 ;;
    --margins) MARGINS="$2"; shift 2 ;;
    --tie-steps) TIE_STEPS="$2"; shift 2 ;;
    --turns) TURNS="$2"; shift 2 ;;
    --reference) REFERENCE="$2"; shift 2 ;;
    --ref-arg) REF_ARGS+=("$2"); shift 2 ;;
    --ref-model-path) REF_MODEL_PATH="$2"; shift 2 ;;
    --outputs) OUTPUTS="$2"; shift 2 ;;
    --contexts) CONTEXTS="$2"; shift 2 ;;
    --model-id) MODEL_ID="$2"; shift 2 ;;
    --model-sha256) MODEL_SHA="$2"; shift 2 ;;
    --config-extra) CONFIG_EXTRA="$2"; shift 2 ;;
    --skip-compare) SKIP_COMPARE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

for v in MODEL_PATH MODEL_NAME BIN_DIR OUT_DIR; do
  [ -n "${!v}" ] || { echo "missing --$(echo "$v" | tr 'A-Z_' 'a-z-')" >&2; exit 64; }
done
[ "$SKIP_REF" = 1 ] || [ -n "$PY" ] || { echo "missing --python (reference interpreter)" >&2; exit 64; }
case "$REFERENCE" in
  mlx-lm) REF_SCRIPT="$HERE/reference_mlxlm.py" ;;
  mlx-vlm) REF_SCRIPT="$HERE/reference_mlxvlm.py" ;;
  *) echo "--reference must be mlx-lm|mlx-vlm" >&2; exit 64 ;;
esac
[ -z "$MODEL_ID" ] || [ -n "$MODEL_SHA" ] || { echo "--model-id needs --model-sha256" >&2; exit 64; }
[ -z "$CONFIG_EXTRA" ] || [ -f "$CONFIG_EXTRA" ] || { echo "no --config-extra file $CONFIG_EXTRA" >&2; exit 64; }
REF_MODEL_PATH="${REF_MODEL_PATH:-$MODEL_PATH}"
case "$CB" in off|on|canary|auto) ;; *) echo "--cb must be off|on|canary|auto" >&2; exit 64 ;; esac
case "$TURNS" in 1|2) ;; *) echo "--turns must be 1|2" >&2; exit 64 ;; esac
case "$TURN2_HEADER" in 0|1) ;; *) echo "TURN2_HEADER must be 0|1" >&2; exit 64 ;; esac
case "$TURN2_HISTORY" in content|verbatim) ;; *) echo "TURN2_HISTORY must be content|verbatim" >&2; exit 64 ;; esac
[ -x "$BIN_DIR/macprovider-cli" ] || { echo "no macprovider-cli in $BIN_DIR" >&2; exit 64; }

listening() { [ -n "$(lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true)" ]; }
if listening 8080; then echo "a server listens on 8080; refusing" >&2; exit 3; fi
if listening "$PORT"; then echo "port $PORT is busy; refusing" >&2; exit 3; fi

mkdir -p "$OUT_DIR/serve"
REF="$OUT_DIR/reference.jsonl"
OURS="$OUT_DIR/provider.jsonl"
GRID="$HERE/grid.json"
if [ -n "$OUTPUTS" ] || [ -n "$CONTEXTS" ]; then
  GRID="$OUT_DIR/grid.json"
  /usr/bin/python3 -I -c 'import json,sys
g=json.load(open(sys.argv[1])); outs, ctxs = sys.argv[3], sys.argv[4]
if outs: g["outputs"] = [int(x) for x in outs.split(",")]
if ctxs:
    want = ctxs.split(",")
    g["contexts"] = [c for c in g["contexts"] if c["name"] in want or str(c["tokens"]) in want]
    if len(g["contexts"]) != len(want): sys.exit("unknown context in %s" % ctxs)
json.dump(g, open(sys.argv[2], "w"), indent=2)' "$HERE/grid.json" "$GRID" "$OUTPUTS" "$CONTEXTS" \
    || { echo "bad --outputs/--contexts" >&2; exit 64; }
fi
COMMON=(--model-name "$MODEL_NAME" --grid "$GRID")
[ -n "$ROWS" ] && COMMON+=(--rows "$ROWS")
[ -n "$TRIALS" ] && COMMON+=(--trials "$TRIALS")
[ -n "$MAX_CONTEXT" ] && COMMON+=(--max-context "$MAX_CONTEXT")
[ "$TURNS" = 1 ] || COMMON+=(--turns "$TURNS")
REF_COMMON=("${COMMON[@]}")
[ "$TURNS" = 1 ] || REF_COMMON+=(--provider-jsonl "$OURS")
CLIENT_ARGS=()
if [ "$TURNS" = 2 ]; then
  [ "$TURN2_HEADER" = 0 ] || CLIENT_ARGS+=(--conversation-header)
  CLIENT_ARGS+=(--turn2-history "$TURN2_HISTORY")
fi

run_reference() {
  echo "== reference $(date +%T) $REFERENCE"
  "$PY" "$REF_SCRIPT" --model-path "$REF_MODEL_PATH" --out "$REF" "${REF_COMMON[@]}" ${REF_ARGS[@]+"${REF_ARGS[@]}"}
}
# Turn 2 replays the provider's turn-1 text, so its reference runs after the provider.
if [ "$SKIP_REF" = 0 ] && [ "$TURNS" = 1 ]; then
  run_reference
fi

if [ -z "$MAX_CONTEXT" ] && [ -f "$REF_MODEL_PATH/config.json" ]; then
  # Same context cut as the reference (which reads config.json itself).
  MAX_CONTEXT="$(/usr/bin/python3 -I -c 'import json,sys
c=json.load(open(sys.argv[1])); t=c.get("text_config") or {}
v=c.get("max_position_embeddings") or c.get("max_seq_len") or c.get("seq_length") or t.get("max_position_embeddings")
print(v if isinstance(v,int) else "")' "$REF_MODEL_PATH/config.json")"
  [ -n "$MAX_CONTEXT" ] && COMMON+=(--max-context "$MAX_CONTEXT")
fi

D="$OUT_DIR/serve"
REQUEST_MODEL="$MODEL_PATH"
if [ -n "$MODEL_ID" ]; then
  REQUEST_MODEL="$MODEL_ID"
  cat > "$D/config.yaml" <<EOF
model: "$MODEL_ID"
model_artifact_path: "$MODEL_PATH"
model_artifact_sha256: $MODEL_SHA
EOF
else
  printf 'model: "%s"\n' "$MODEL_PATH" > "$D/config.yaml"
fi
cat >> "$D/config.yaml" <<EOF
port: $PORT
ctl_socket_path: "$D/ctl.sock"
credential_store: protected_file
EOF
[ -z "$CONFIG_EXTRA" ] || cat "$CONFIG_EXTRA" >> "$D/config.yaml"
shasum -a 256 "$BIN_DIR/macprovider-cli" > "$D/identity.sha256"

CB_ARGS=()
[ "$CB" = auto ] || CB_ARGS=(--continuous-batching "$CB")
read -r -a ENV_ARGS <<< "${SERVE_ENV:-PARITY_GRID_NOOP=1}"

AT_ARGS=()
if [ "$AUTOTUNE" = 1 ]; then AT_ARGS=(--autotune-candidate); fi
echo "== provider $(date +%T) cb=$CB port=$PORT"
(cd "$BIN_DIR" && exec env "${ENV_ARGS[@]}" "$BIN_DIR/macprovider-cli" serve --config "$D/config.yaml" \
  --no-join ${AT_ARGS[@]+"${AT_ARGS[@]}"} ${CB_ARGS[@]+"${CB_ARGS[@]}"} ${SERVE_ARGS[@]+"${SERVE_ARGS[@]}"} >"$D/serve.out" 2> "$D/serve.err" < /dev/null) &
SP=$!
stop_serve() {
  if kill -0 "$SP" 2>/dev/null; then
    kill -TERM "$SP" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$SP" 2>/dev/null || return 0; sleep 0.5; done
    kill -KILL "$SP" 2>/dev/null || true
  fi
}
trap stop_serve EXIT

ready=0
for _ in $(seq 1 240); do
  kill -0 "$SP" 2>/dev/null || { echo "serve exited" >&2; tail -20 "$D/serve.err" >&2; exit 5; }
  if curl -s --max-time 3 "http://127.0.0.1:$PORT/v1/status" | /usr/bin/python3 -I -c \
      'import json,sys; sys.exit(0 if json.load(sys.stdin).get("model_loaded") is True else 1)' 2>/dev/null; then
    ready=1; break
  fi
  sleep 5
done
[ "$ready" = 1 ] || { echo "serve not ready" >&2; tail -20 "$D/serve.err" >&2; exit 6; }
curl -s "http://127.0.0.1:$PORT/v1/status" > "$D/status.json"

echo "== client $(date +%T)"
client_rc=0
if [ "$SAMPLE_SECS" -gt 0 ] 2>/dev/null; then
  # One stack sample of the serve process while the client runs, to split
  # host work from GPU wait. The first cells are the short-context ones.
  (sleep 8; sample "$SP" "$SAMPLE_SECS" -file "$OUT_DIR/serve-sample.txt" >/dev/null 2>&1 || true) &
fi
/usr/bin/python3 -I "$HERE/provider_client.py" --port "$PORT" --model "$REQUEST_MODEL" --out "$OURS" \
  "${COMMON[@]}" ${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"} || client_rc=$?
stop_serve
trap - EXIT
if [ "$SKIP_REF" = 0 ] && [ "$TURNS" = 2 ]; then
  run_reference
fi

if [ "$SKIP_COMPARE" = 1 ]; then
  echo "== compare skipped (client rc=$client_rc)"
  [ "$client_rc" -eq 0 ] || exit 7
  exit 0
fi
echo "== compare $(date +%T) (client rc=$client_rc)"
CMP=(--ref "$REF" --ours "$OURS" --floor "$FLOOR" --json "$OUT_DIR/summary.json")
[ -n "$FALLBACK" ] && CMP+=(--text-fallback-reason "$FALLBACK")
[ -n "$MARGINS" ] && CMP+=(--margins "$MARGINS")
[ -n "$TIE_STEPS" ] && CMP+=(--tie-steps "$TIE_STEPS")
# errexit would end the script at a failing compare, before the client check.
set +e
/usr/bin/python3 -I "$HERE/compare.py" "${CMP[@]}" | tee "$OUT_DIR/summary.md"
compare_rc="${PIPESTATUS[0]}"
set -e
# A client that failed leaves cells missing or partial: the table above is
# printed for diagnosis, but the window fails whatever compare said.
if [ "$client_rc" -ne 0 ]; then
  echo "client failed (rc=$client_rc; compare rc=$compare_rc)" >&2
  exit 7
fi
exit "$compare_rc"
