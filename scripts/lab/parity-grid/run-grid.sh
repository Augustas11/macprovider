#!/usr/bin/env bash
# Parity-grid lab window for one model: our provider on a loopback port, then
# the stock mlx-lm reference, then compare.py. Noninteractive. The provider
# runs first so a reference that cannot load cannot cost the provider cells.
#
# usage: run-grid.sh --model-path DIR --model-name NAME --bin-dir DIR --out-dir DIR
#                    --python PY [--port 18340] [--cb off|on|canary|auto]
#                    [--serve-env "K=V K2=V2"] [--rows 1,4] [--trials 3]
#                    [--max-context N] [--floor 0.03] [--skip-reference]
#                    [--text-fallback-reason TEXT] [--no-autotune-candidate]
#                    [--margins FILE] [--tie-steps N]
#                    [--serve-arg ARG]... [--sample-seconds N] [--turns 1|2]
#                    [--reference mlx-lm|mlx-vlm|omlx] [--ref-arg ARG]... [--ref-model-path DIR]
#                    [--outputs 128,512] [--contexts short,4k|200,4000]
#                    [--model-id ID --model-sha256 SHA] [--config-extra FILE]
#                    [--skip-compare] [--trials-by-rows 4=1] [--reference-only]
#                    [--expect-route batched|any] [--warmup-stall-s 1200] [--warmup-poll-s 10]
#                    [--seed-self-check FILE] [--expect-native-mtp on|any] [--lab-fence]
#
# --lab-fence (#2448): the provider client sends each trial's rows as one request-named
# admission fence (provider_client.py --lab-fence); a lab-harness serve then admits the
# rows in row order once all are queued. The reference is unaffected.
#
# --reference picks the reference script: reference_mlxlm.py (default) or
# reference_mlxvlm.py for families mlx-lm cannot load, or reference_omlx.py (an
# oMLX server on its own loopback port; --python defaults to /usr/bin/python3,
# the oMLX install comes in as --ref-arg --omlx-dir --ref-arg DIR); --ref-arg passes one
# argument through to it (e.g. --ref-arg --refusal-ablation --ref-arg DIR) and
# --ref-model-path points it at another directory than --model-path (the
# unmodified base of a runtime-ablated snapshot). --outputs / --contexts cut
# grid.json (contexts by name or token count) into OUT/grid.json, which both
# sides then read.
# --model-id serves the snapshot under its catalog id (config `model`,
# `model_artifact_path`, `model_artifact_sha256` = --model-sha256, verified by
# the serve) and sends that id as the request model; --config-extra appends
# raw YAML lines to the serve config (e.g. a continuous_batching accepted
# tuple: in a --no-join serve it adds the cached-turns grant, never the
# authorization to batch). --skip-compare
# stops after the client (exit 7 if it failed, else 0). --trials-by-rows sets
# the provider's trial count per row count (e.g. 4=1 for serial-served models,
# whose 4-row cells only queue); the reference is unaffected.
# --reference-only skips the provider: OUT/provider.jsonl must already hold a
# provider run (and OUT/grid.json, when present and neither --outputs nor
# --contexts is given, is reused as the grid), OUT/reference.jsonl must not
# exist; the reference then runs and compare scores the stored provider cells.
# --bin-dir is not needed.
#
# Batching warm-up (route_status.py gate): after the serve is ready and before
# the client's first request, the window sends no inference request and polls
# /v1/status until the continuous-batching self-check has a verdict and the
# served slots reflect it, or until no self-check can run for this serve. A
# --no-join serve never loads the signed CB policy, so the self-check verdict is
# the only thing that turns batching on, and it runs only while the serve is
# idle. Progress lines start with CB_WARMUP; the status is polled every
# --warmup-poll-s seconds and the only bound is --warmup-stall-s seconds
# without self-check progress (then CB_WARMUP_STALL and the grid runs on
# whatever route serves). --seed-self-check FILE copies a
# cb-self-check.json from an earlier serve of the same binary and model next to
# the config, so the stored verdict applies at startup (as after a restart).
# /v1/status is saved at ready (serve/status-ready.json), at the grid start
# (serve/status.json) and at the grid end (serve/status-end.json); each of the
# last two prints one `ROUTE batching=<active|serial> slots=<n> reason=<...>`
# line and is stored under route.start / route.end in OUT/grid.json. With
# --expect-route batched a serial route prints ROUTE_FAIL and the window exits
# 10 (when compare exited 0 or 1); the cells are still measured.
#
# --expect-native-mtp on: the serve must run native MTP. After the batching warm-up
# the saved /v1/status must show native_mtp.enabled true and a mode other than off
# (route_status.py native-mtp), else the window prints `NATIVE_MTP_FAIL ...`, stops
# the serve before any cell and exits 11; after the grid the end status must also
# show proposed tokens, else the window exits 11 after compare. The client then also
# stores the per-trial change of the native_mtp counters (proposed/accepted tokens,
# acceptance) on each aggregate line of provider.jsonl, and OUT/grid.json holds the
# native_mtp object under native_mtp.start / native_mtp.end. Native MTP is
# admitted at one active row: grids for it use --rows 1. A `--no-join` serve gets the
# signed admission set only with native_mtp_mode auto and a model_catalog_* config
# (the job's <K>_NATIVE_MTP=auto writes it) and the model at its durable store path.
#
# Sanity gate: after a reference run that exited 0, sanity.py checks its text
# (see its docstring). A degenerate reference prints one
# `REFERENCE_SUSPECT <model> <reason>` line, its rows move to
# reference.suspect.jsonl, compare runs as for a failed reference (reference
# columns empty, reason in summary) and the window exits 9.
#
# --turns 2 adds the two-turn cell: after each turn-1 trial the provider client sends turn 2
# ([user1, assistant1 = its own turn-1 text, short follow-up]) and records TTFT and
# cached_prompt_tokens (turn=2 rows in provider.jsonl). The reference then runs after the
# provider and replays that assistant1 text (--provider-jsonl OUT/provider.jsonl). compare.py
# adds a turn-2 section and fails a cell whose provider reports 0 cached tokens. Default 1:
# nothing changes. With --turns 2, env TURN2_HEADER=1 makes the provider client send
# X-MacProvider-Provider-Conversation (one id per trial and row, on both turns; a --no-join
# serve keys its prefix cache only on it; the key is sticky, so native MTP decodes turn 2
# ordinarily, SPEC-048-R009). TURN2_HEADER=cache_only sends the same id plus
# X-MacProvider-Provider-Conversation-Cache-Only: 1, which a lab-harness serve maps to a
# cache-only key as the relay does for live cached turns (native MTP stays eligible). TURN2_HISTORY=verbatim re-sends the turn-1
# reasoning as reasoning_content in the turn-2 history (default content: content only). Both
# are provider-client only; the reference is unchanged. TURN2_FOLLOWUP=continue (default restate)
# makes user2 ask to keep writing, so turn 2 decodes to its output budget (#2459); the reference
# replays only the restate follow-up, so continue needs --skip-reference.
#
# --contexts takes grid.json context names or token counts; a token count grid.json lacks
# (e.g. 34000) becomes one more context of that many target tokens, named by the number.
#
# --no-autotune-candidate drops the lab autotune flag from the serve command;
# with --cb off (and native MTP off for a model that has an admission entry)
# the provider then takes its serial-only small-row route, and with --cb auto
# the route a production serve takes. With the flag the serve is an autotune
# child, which always takes the row-invariant route.
#
# Exit code: compare's (0 all cells pass, 1 a cell fails, 2 unusable input),
# 7 when the client failed, 8 when the reference failed, 9 when it was suspect,
# 10 when --expect-route batched found a serial route and compare exited 0 or 1
# (all after the compare table is printed; 7 wins; with 8 or 9 a ROUTE_FAIL
# line is the signal), 11 when --expect-native-mtp on found native MTP off (before the
# client, or after compare when the end status shows no proposed token; the same
# precedence as 10, after it); 3, 5, 6 and 64 before the client runs.
# A failed reference prints one `REFERENCE_FAIL <model> <error line> (rc=N)`
# line; compare still runs with the reference rows it got (often none), so
# provider.jsonl, summary.md and summary.json hold every provider cell with
# empty reference columns. Check
# the ROUTE lines (or serve/status.json continuous_batching) to see which route ran.
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
TURN2_FOLLOWUP=${TURN2_FOLLOWUP:-restate}
REFERENCE=mlx-lm
REF_ARGS=()
REF_MODEL_PATH=""
OUTPUTS="" CONTEXTS=""
MODEL_ID="" MODEL_SHA="" CONFIG_EXTRA=""
SKIP_COMPARE=0
REF_ONLY=0
TRIALS_BY_ROWS=""
EXPECT_ROUTE=any
WARMUP_STALL_S=1200
WARMUP_POLL_S=10
SEED_SELF_CHECK=""
EXPECT_MTP=any
LAB_FENCE=0
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
    --trials-by-rows) TRIALS_BY_ROWS="$2"; shift 2 ;;
    --reference-only) REF_ONLY=1; shift ;;
    --expect-route) EXPECT_ROUTE="$2"; shift 2 ;;
    --warmup-stall-s) WARMUP_STALL_S="$2"; shift 2 ;;
    --warmup-poll-s) WARMUP_POLL_S="$2"; shift 2 ;;
    --seed-self-check) SEED_SELF_CHECK="$2"; shift 2 ;;
    --expect-native-mtp) EXPECT_MTP="$2"; shift 2 ;;
    --lab-fence) LAB_FENCE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

REQUIRED="MODEL_PATH MODEL_NAME OUT_DIR"
[ "$REF_ONLY" = 1 ] || REQUIRED="$REQUIRED BIN_DIR"
for v in $REQUIRED; do
  [ -n "${!v}" ] || { echo "missing --$(echo "$v" | tr 'A-Z_' 'a-z-')" >&2; exit 64; }
done
case "$REFERENCE" in
  mlx-lm) REF_SCRIPT="$HERE/reference_mlxlm.py" ;;
  mlx-vlm) REF_SCRIPT="$HERE/reference_mlxvlm.py" ;;
  omlx) REF_SCRIPT="$HERE/reference_omlx.py"; PY="${PY:-/usr/bin/python3}" ;;
  *) echo "--reference must be mlx-lm|mlx-vlm|omlx" >&2; exit 64 ;;
esac
[ "$SKIP_REF" = 1 ] || [ -n "$PY" ] || { echo "missing --python (reference interpreter)" >&2; exit 64; }
if [ "$REF_ONLY" = 1 ]; then
  [ "$SKIP_REF" = 0 ] || { echo "--reference-only and --skip-reference exclude each other" >&2; exit 64; }
  [ -s "$OUT_DIR/provider.jsonl" ] || { echo "--reference-only needs a provider run in $OUT_DIR/provider.jsonl" >&2; exit 64; }
  [ ! -e "$OUT_DIR/reference.jsonl" ] || { echo "$OUT_DIR/reference.jsonl exists; --reference-only needs a fresh one" >&2; exit 64; }
fi
[ -z "$MODEL_ID" ] || [ -n "$MODEL_SHA" ] || { echo "--model-id needs --model-sha256" >&2; exit 64; }
[ -z "$CONFIG_EXTRA" ] || [ -f "$CONFIG_EXTRA" ] || { echo "no --config-extra file $CONFIG_EXTRA" >&2; exit 64; }
REF_MODEL_PATH="${REF_MODEL_PATH:-$MODEL_PATH}"
case "$CB" in off|on|canary|auto) ;; *) echo "--cb must be off|on|canary|auto" >&2; exit 64 ;; esac
case "$TURNS" in 1|2) ;; *) echo "--turns must be 1|2" >&2; exit 64 ;; esac
case "$TURN2_HEADER" in 0|1|cache_only) ;; *) echo "TURN2_HEADER must be 0|1|cache_only" >&2; exit 64 ;; esac
case "$TURN2_HISTORY" in content|verbatim) ;; *) echo "TURN2_HISTORY must be content|verbatim" >&2; exit 64 ;; esac
case "$TURN2_FOLLOWUP" in restate) ;; continue)
  [ "$SKIP_REF" = 1 ] || { echo "TURN2_FOLLOWUP=continue needs --skip-reference (the reference replays restate)" >&2; exit 64; } ;;
  *) echo "TURN2_FOLLOWUP must be restate|continue" >&2; exit 64 ;; esac
case "$EXPECT_MTP" in on|any) ;; *) echo "--expect-native-mtp must be on|any" >&2; exit 64 ;; esac
case "$EXPECT_ROUTE" in batched|any) ;; *) echo "--expect-route must be batched|any" >&2; exit 64 ;; esac
[ -z "$SEED_SELF_CHECK" ] || [ -f "$SEED_SELF_CHECK" ] || { echo "no --seed-self-check file $SEED_SELF_CHECK" >&2; exit 64; }
[ "$REF_ONLY" = 1 ] || [ -x "$BIN_DIR/macprovider-cli" ] || { echo "no macprovider-cli in $BIN_DIR" >&2; exit 64; }

listening() { [ -n "$(lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true)" ]; }
if listening 8080; then echo "a server listens on 8080; refusing" >&2; exit 3; fi
if listening "$PORT"; then echo "port $PORT is busy; refusing" >&2; exit 3; fi

mkdir -p "$OUT_DIR/serve"
REF="$OUT_DIR/reference.jsonl"
OURS="$OUT_DIR/provider.jsonl"
GRID="$HERE/grid.json"
if [ "$REF_ONLY" = 1 ] && [ -z "$OUTPUTS$CONTEXTS" ] && [ -f "$OUT_DIR/grid.json" ]; then
  GRID="$OUT_DIR/grid.json"  # the stored provider run's grid
else
  # OUT/grid.json is this window's own copy: it also records the route.
  GRID="$OUT_DIR/grid.json"
  /usr/bin/python3 -I -c 'import json,sys
g=json.load(open(sys.argv[1])); outs, ctxs = sys.argv[3], sys.argv[4]
if outs: g["outputs"] = [int(x) for x in outs.split(",")]
if ctxs:
    want = ctxs.split(",")
    g["contexts"] = [c for c in g["contexts"] if c["name"] in want or str(c["tokens"]) in want]
    known = {c["name"] for c in g["contexts"]} | {str(c["tokens"]) for c in g["contexts"]}
    g["contexts"] += [{"name": w, "tokens": int(w)} for w in want if w not in known and w.isdigit() and int(w) > 0]
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
# Turn 2 replays the provider's turn-1 text; the reference runs after the provider.
[ "$TURNS" = 1 ] || REF_COMMON+=(--provider-jsonl "$OURS")
CLIENT_ARGS=()
if [ "$TURNS" = 2 ]; then
  case "$TURN2_HEADER" in
    1) CLIENT_ARGS+=(--conversation-header) ;;
    cache_only) CLIENT_ARGS+=(--conversation-header --conversation-cache-only) ;;
  esac
  CLIENT_ARGS+=(--turn2-history "$TURN2_HISTORY" --turn2-followup "$TURN2_FOLLOWUP")
fi

if [ -z "$MAX_CONTEXT" ] && [ -f "$REF_MODEL_PATH/config.json" ]; then
  # Same context cut as the reference (which reads config.json itself).
  MAX_CONTEXT="$(/usr/bin/python3 -I -c 'import json,sys
c=json.load(open(sys.argv[1])); t=c.get("text_config") or {}
v=c.get("max_position_embeddings") or c.get("max_seq_len") or c.get("seq_length") or t.get("max_position_embeddings")
print(v if isinstance(v,int) else "")' "$REF_MODEL_PATH/config.json")"
  [ -n "$MAX_CONTEXT" ] && COMMON+=(--max-context "$MAX_CONTEXT")
fi

client_rc=0
if [ "$REF_ONLY" = 1 ]; then
  echo "== provider skipped (--reference-only): $(grep -c '"kind": "row"' "$OURS") stored rows in $OURS"
else
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
if [ -n "$SEED_SELF_CHECK" ]; then
  # The store is private (0600, owner only, no symlink); serve reads it next to its config.
  cp "$SEED_SELF_CHECK" "$D/cb-self-check.json" && chmod 600 "$D/cb-self-check.json"
fi
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
curl -s "http://127.0.0.1:$PORT/v1/status" > "$D/status-ready.json"

echo "== batching warm-up $(date +%T) (no requests until the self-check decides)"
warm_rc=0
/usr/bin/python3 -I "$HERE/route_status.py" gate --port "$PORT" --serve-err "$D/serve.err" --pid "$SP" \
  --stall-s "$WARMUP_STALL_S" --poll-s "$WARMUP_POLL_S" || warm_rc=$?
case $warm_rc in
  0) ;;
  4) echo "batching warm-up stalled; measuring the route that serves (see the ROUTE line)" >&2 ;;
  5) echo "serve exited during the batching warm-up" >&2; tail -20 "$D/serve.err" >&2; exit 5 ;;
  *) echo "batching warm-up failed rc=$warm_rc; measuring the route that serves" >&2 ;;
esac
route_rc=0
curl -s "http://127.0.0.1:$PORT/v1/status" > "$D/status.json"
/usr/bin/python3 -I "$HERE/route_status.py" record --status "$D/status.json" --serve-err "$D/serve.err" \
  --grid "$GRID" --phase start --expect "$EXPECT_ROUTE" || route_rc=$?

mtp_rc=0
if [ "$EXPECT_MTP" = on ]; then
  /usr/bin/python3 -I "$HERE/route_status.py" native-mtp --status "$D/status.json" --grid "$GRID" --phase start \
    --expect on || mtp_rc=$?
  if [ "$mtp_rc" -ne 0 ]; then
    echo "serve.err native-MTP lines:" >&2
    grep -i "native_mtp\|native mtp\|admission" "$D/serve.err" | tail -20 >&2 || true
    exit 11
  fi
fi

MTP_CLIENT_ARGS=()
[ "$EXPECT_MTP" != on ] || MTP_CLIENT_ARGS=(--native-mtp-counters)
[ "$LAB_FENCE" = 0 ] || MTP_CLIENT_ARGS+=(--lab-fence)
echo "== client $(date +%T)"
if [ "$SAMPLE_SECS" -gt 0 ] 2>/dev/null; then
  # One stack sample of the serve process while the client runs, to split
  # host work from GPU wait. The first cells are the short-context ones.
  (sleep 8; sample "$SP" "$SAMPLE_SECS" -file "$OUT_DIR/serve-sample.txt" >/dev/null 2>&1 || true) &
fi
/usr/bin/python3 -I "$HERE/provider_client.py" --port "$PORT" --model "$REQUEST_MODEL" --out "$OURS" \
  "${COMMON[@]}" ${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"} ${TRIALS_BY_ROWS:+--trials-by-rows "$TRIALS_BY_ROWS"} \
  ${MTP_CLIENT_ARGS[@]+"${MTP_CLIENT_ARGS[@]}"} || client_rc=$?
if curl -s --max-time 10 "http://127.0.0.1:$PORT/v1/status" > "$D/status-end.json"; then
  /usr/bin/python3 -I "$HERE/route_status.py" record --status "$D/status-end.json" --serve-err "$D/serve.err" \
    --grid "$GRID" --phase end --expect "$EXPECT_ROUTE" || route_rc=$?
else
  echo "ROUTE_FAIL phase=end no /v1/status at the grid end"; route_rc=10
fi
if [ "$EXPECT_MTP" = on ]; then
  if [ -s "$D/status-end.json" ]; then
    /usr/bin/python3 -I "$HERE/route_status.py" native-mtp --status "$D/status-end.json" --grid "$GRID" --phase end \
      --expect on || mtp_rc=$?
  else
    echo "NATIVE_MTP_FAIL phase=end no /v1/status at the grid end"; mtp_rc=11
  fi
fi
stop_serve
trap - EXIT
fi

ref_rc=0 ref_err=""
if [ "$SKIP_REF" = 0 ]; then
  echo "== reference $(date +%T) $REFERENCE"
  set +e
  "$PY" "$REF_SCRIPT" --model-path "$REF_MODEL_PATH" --out "$REF" "${REF_COMMON[@]}" ${REF_ARGS[@]+"${REF_ARGS[@]}"} \
    2>&1 | tee "$OUT_DIR/reference.log"
  ref_rc="${PIPESTATUS[0]}"
  set -e
  if [ "$ref_rc" -ne 0 ]; then
    # The exception line of a traceback, else the last line printed.
    ref_err="$(grep -E '^[A-Za-z_][A-Za-z0-9_.]*(Error|Exception|Exit)\b' "$OUT_DIR/reference.log" | tail -n 1 || true)"
    [ -n "$ref_err" ] || ref_err="$(grep -v '^[[:space:]]*$' "$OUT_DIR/reference.log" | tail -n 1 || true)"
    ref_err="$(printf '%s' "${ref_err:-no output}" | cut -c1-400) (rc=$ref_rc)"
    echo "REFERENCE_FAIL $MODEL_NAME $ref_err"
  else
    # A reference that ran but decoded garbage is no reference: same handling as a failure.
    sane_rc=0
    sane_out="$(/usr/bin/python3 -I "$HERE/sanity.py" --ref "$REF" --model-name "$MODEL_NAME" \
      --json "$OUT_DIR/reference-sanity.json" 2>&1)" || sane_rc=$?
    echo "$sane_out"
    if [ "$sane_rc" -ne 0 ]; then
      ref_err="$(printf '%s\n' "$sane_out" | grep -m1 '^REFERENCE_SUSPECT ' || true)"
      [ -n "$ref_err" ] || { ref_err="REFERENCE_SUSPECT $MODEL_NAME sanity check rc=$sane_rc"; echo "$ref_err"; }
      ref_err="$(printf '%s' "$ref_err" | cut -c1-600)"
      mv "$REF" "$OUT_DIR/reference.suspect.jsonl"
      ref_rc=9
    fi
  fi
fi

if [ "$SKIP_COMPARE" = 1 ]; then
  echo "== compare skipped (client rc=$client_rc reference rc=$ref_rc route rc=${route_rc:-0})"
  [ "$client_rc" -eq 0 ] || exit 7
  [ "$ref_rc" -ne 9 ] || exit 9
  [ "$ref_rc" -eq 0 ] || exit 8
  [ "${route_rc:-0}" -eq 0 ] || exit 10
  [ "${mtp_rc:-0}" -eq 0 ] || exit 11
  exit 0
fi
echo "== compare $(date +%T) (client rc=$client_rc reference rc=$ref_rc)"
CMP=(--ref "$REF" --ours "$OURS" --floor "$FLOOR" --json "$OUT_DIR/summary.json")
[ -n "$ref_err" ] && CMP+=(--reference-failed "$ref_err")
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
if [ "$ref_rc" -eq 9 ]; then
  echo "reference suspect (compare rc=$compare_rc): its output is degenerate; reference columns empty" >&2
  exit 9
fi
if [ "$ref_rc" -ne 0 ]; then
  echo "reference failed (rc=$ref_rc; compare rc=$compare_rc): provider cells measured, reference columns empty" >&2
  exit 8
fi
if [ "${route_rc:-0}" -ne 0 ] && [ "$compare_rc" -le 1 ]; then
  echo "route not the expected one (compare rc=$compare_rc): see the ROUTE_FAIL line" >&2
  exit 10
fi
if [ "${mtp_rc:-0}" -ne 0 ] && [ "$compare_rc" -le 1 ]; then
  echo "native MTP not on (compare rc=$compare_rc): see the NATIVE_MTP_FAIL line" >&2
  exit 11
fi
exit "$compare_rc"
