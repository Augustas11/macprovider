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
#                    [--serve-arg ARG]... [--sample-seconds N]
#
# --no-autotune-candidate drops the lab autotune flag from the serve command;
# with --cb off (and native MTP off for a model that has an admission entry)
# the provider then takes its serial-only small-row route. Check
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
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

for v in MODEL_PATH MODEL_NAME BIN_DIR OUT_DIR; do
  [ -n "${!v}" ] || { echo "missing --$(echo "$v" | tr 'A-Z_' 'a-z-')" >&2; exit 64; }
done
[ "$SKIP_REF" = 1 ] || [ -n "$PY" ] || { echo "missing --python (mlx_lm interpreter)" >&2; exit 64; }
case "$CB" in off|on|canary|auto) ;; *) echo "--cb must be off|on|canary|auto" >&2; exit 64 ;; esac
[ -x "$BIN_DIR/macprovider-cli" ] || { echo "no macprovider-cli in $BIN_DIR" >&2; exit 64; }

listening() { [ -n "$(lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true)" ]; }
if listening 8080; then echo "a server listens on 8080; refusing" >&2; exit 3; fi
if listening "$PORT"; then echo "port $PORT is busy; refusing" >&2; exit 3; fi

mkdir -p "$OUT_DIR/serve"
REF="$OUT_DIR/reference.jsonl"
OURS="$OUT_DIR/provider.jsonl"
COMMON=(--model-name "$MODEL_NAME" --grid "$HERE/grid.json")
[ -n "$ROWS" ] && COMMON+=(--rows "$ROWS")
[ -n "$TRIALS" ] && COMMON+=(--trials "$TRIALS")
[ -n "$MAX_CONTEXT" ] && COMMON+=(--max-context "$MAX_CONTEXT")

if [ "$SKIP_REF" = 0 ]; then
  echo "== reference $(date +%T)"
  "$PY" "$HERE/reference_mlxlm.py" --model-path "$MODEL_PATH" --out "$REF" "${COMMON[@]}"
fi

if [ -z "$MAX_CONTEXT" ] && [ -f "$MODEL_PATH/config.json" ]; then
  # Same context cut as the reference (which reads config.json itself).
  MAX_CONTEXT="$(/usr/bin/python3 -I -c 'import json,sys
c=json.load(open(sys.argv[1])); t=c.get("text_config") or {}
v=c.get("max_position_embeddings") or c.get("max_seq_len") or c.get("seq_length") or t.get("max_position_embeddings")
print(v if isinstance(v,int) else "")' "$MODEL_PATH/config.json")"
  [ -n "$MAX_CONTEXT" ] && COMMON+=(--max-context "$MAX_CONTEXT")
fi

D="$OUT_DIR/serve"
cat > "$D/config.yaml" <<EOF
model: "$MODEL_PATH"
port: $PORT
ctl_socket_path: "$D/ctl.sock"
credential_store: protected_file
EOF
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
/usr/bin/python3 -I "$HERE/provider_client.py" --port "$PORT" --model "$MODEL_PATH" --out "$OURS" \
  "${COMMON[@]}" || client_rc=$?
stop_serve
trap - EXIT

echo "== compare $(date +%T) (client rc=$client_rc)"
CMP=(--ref "$REF" --ours "$OURS" --floor "$FLOOR" --json "$OUT_DIR/summary.json")
[ -n "$FALLBACK" ] && CMP+=(--text-fallback-reason "$FALLBACK")
[ -n "$MARGINS" ] && CMP+=(--margins "$MARGINS")
[ -n "$TIE_STEPS" ] && CMP+=(--tie-steps "$TIE_STEPS")
/usr/bin/python3 -I "$HERE/compare.py" "${CMP[@]}" | tee "$OUT_DIR/summary.md"
exit "${PIPESTATUS[0]}"
