#!/bin/bash
# Runs ON THE STUDIO from ~/lab-ablit-perf/job/ablit-perf/. #2452 step 3: pre-listing checks of the
# Qwen3.8-Flash-Next heretic build (qwen4_exp) on a lab build of this tree (engine 3.32.3-macprovider.84
# from Package.resolved, no fork), before the CLI cut:
#  a. serve: `serve --no-join` of the pinned snapshot under its catalog id QWEN4_ID (default
#     qwen/qwen3.8-flash-next-abliterated) with model_artifact_path and model_artifact_sha256 (the
#     snapshot-manifest hash, verified by the serve), the production route (no autotune flag, no
#     --continuous-batching flag, no CB tuple: a catalog row with no batching entry), one row. Identity:
#     config.json model_type qwen4_exp, the serve's /v1/status model = QWEN4_ID and model_hash =
#     QWEN4_SHA256 (default the manifest hash every #2409 run computed for revision 65b0cd66), the
#     recomputed manifest equal to it, and the family qwen4_exp in serve.err or in the prefill-profile
#     load line (same classifier, ModelRuntime.pagedKVModelCapabilities). The route must be serial
#     (route_status.py ROUTE line);
#  b. memory at one row: one streamed greedy request per MEM_CONTEXTS context (default 4000,32000,
#     each capped below the config's max_position_embeddings and the serve's max_context_tokens),
#     MEM_OUTPUT output tokens (default 256), parity-grid provider_client.py prompts; after each the
#     serve's phys_footprint / lifetime peak / resident size (listing_memory.py sample,
#     proc_pid_rusage). After the serve stops, `macprovider-cli prefill-profile --served-only` (the
#     serve's serial path in its own process, step 512) gives the MLX peak per context. The report
#     proposes min_ram_gb = ceil(serve lifetime peak GiB + 10% of RAM + 4), the rule of the existing
#     large rows (listing_memory.py header cites it);
#  c. buyer-UX: scripts/buyer_ux_conformance.py's checks (SPEC-023 §16.11: tools, tool deltas and
#     round trip, reasoning split, response_format json_object, stop, finish_reason, context-limit
#     error, /v1/messages thinking, /v1/responses function tool) against the same serve over loopback
#     (buyer_ux_local.py header: how it differs from the gateway runs that made every existing record),
#     BUX_SAMPLES samples each (default 3); the record is written to the results, never to the catalog.
# Steps: stage (snapshot download at the pinned revision when QWEN4_PATH is absent, as
# job-qwen4-cb.sh), build (job.sh's .build-lab-harness path, -DMACPROVIDER_LAB_HARNESS, pinned
# engine), serve + a + b + c, stop, prefill-profile, report.
#
# Results: ~/lab-ablit-perf/results/<run>/qwen4-flash-next-listing/{identity.txt,serve/,mem/,
# memory.md,memory.json,buyer-ux-record.json,buyer-ux.txt,prefill-profile.json,build.log}.
# Env: QWEN4_PATH QWEN4_REPO QWEN4_REVISION QWEN4_ID QWEN4_SHA256 MEM_CONTEXTS MEM_OUTPUT BUX_SAMPLES
# METALLIB SKIP_BUILD. LISTING_JOB_CHECK=1: validate the knobs, print the serve config, client and
# profile argv and exit 0 before touching anything (the unit test). Every failure prints `BLOCKER:`;
# the job runs every step it can and ends with JOB_PASS (exit 0) or JOB_FAIL (nonzero). It never
# pauses, restores or touches the live provider: the window owner does.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-ablit-perf
JOB=$LAB/job
GRID=$JOB/parity-grid
SRC=$LAB/src/phase3-binary
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
NAME=qwen4-flash-next-listing
RES=$LAB/results/$RUN_ID/$NAME
QWEN4_REPO=${QWEN4_REPO:-latent-variable/Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp}
QWEN4_REVISION=${QWEN4_REVISION:-65b0cd66046e41b63fb565466c5a52a6295a7592}
QWEN4_PATH=${QWEN4_PATH:-$LAB/models/Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp}
QWEN4_ID=${QWEN4_ID:-qwen/qwen3.8-flash-next-abliterated}
# The snapshot-manifest hash of $QWEN4_REPO@65b0cd66, as job-qwen4-cb.sh computed it in every #2409 run.
QWEN4_SHA256=${QWEN4_SHA256:-f0dfdf5261527e3a64356f95f10c9e906a387f87d85a0d10703692da083043cd}
MEM_CONTEXTS=${MEM_CONTEXTS:-4000,32000}
MEM_OUTPUT=${MEM_OUTPUT:-256}
BUX_SAMPLES=${BUX_SAMPLES:-3}
PORT=18341
PROFILE_STEP=512  # serve's serial prefill step (ModelRuntime.effectivePrefillStepSize, configured 512)
MLX_LM_COMMIT=c4c9c762cc797fd979fc98645f5db5112753bbe9
VENV=$LAB/venv-lm-qwen4  # job-qwen4-cb.sh's venv; here only its `hf` for a missing snapshot
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-harness
BIN=$SRC/$BUILD/release
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }

case "$MEM_CONTEXTS" in ""|*[!0-9,]*|,*|*,|*,,*) die "MEM_CONTEXTS=$MEM_CONTEXTS must be a comma list of token counts" 64 ;; esac
IFS=, read -r -a CTX_LIST <<< "$MEM_CONTEXTS"
for n in "${CTX_LIST[@]}"; do [ "$n" -ge 200 ] && [ "$n" -le 131072 ] || die "MEM_CONTEXTS: $n is not 200..131072" 64; done
case "$MEM_OUTPUT" in ""|*[!0-9]*) die "MEM_OUTPUT=$MEM_OUTPUT must be 16..4096" 64 ;; esac
[ "$MEM_OUTPUT" -ge 16 ] && [ "$MEM_OUTPUT" -le 4096 ] || die "MEM_OUTPUT=$MEM_OUTPUT must be 16..4096" 64
case "$BUX_SAMPLES" in [1-9]) ;; *) die "BUX_SAMPLES=$BUX_SAMPLES must be 1..9" 64 ;; esac
echo "$QWEN4_SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "QWEN4_SHA256=$QWEN4_SHA256 is not a lowercase sha256" 64
echo "$QWEN4_ID" | grep -Eq '^[a-z0-9._-]+/[a-z0-9._-]+$' || die "QWEN4_ID=$QWEN4_ID is not a lowercase org/name id" 64

SERVE_CONFIG="model: \"$QWEN4_ID\"
model_artifact_path: \"$QWEN4_PATH\"
model_artifact_sha256: $QWEN4_SHA256
port: $PORT
ctl_socket_path: \"$RES/serve/ctl.sock\"
credential_store: protected_file"
SERVE_ARGS=(serve --config "$RES/serve/config.yaml" --no-join)
client_args() {  # $1 context tokens
  CARGS=(--port "$PORT" --model "$QWEN4_ID" --model-name "$NAME" --out "$RES/mem/provider.jsonl"
         --grid "$RES/mem/grid-$1.json" --trials 1 --rows 1)
}
PROFILE_ARGS=(prefill-profile --model-dir "$QWEN4_PATH" --prompt-text "$SRC/Sources/macprovider-cli/ModelRuntime.swift"
              --prompt-tokens "$MEM_CONTEXTS" --step-sizes "$PROFILE_STEP" --runs 1 --generate-tokens "$MEM_OUTPUT"
              --served-only --output "$RES/prefill-profile.json")
BUX_ARGS=(--suite-dir "$JOB/bux" --base "http://127.0.0.1:$PORT/v1" --model "$QWEN4_ID" --served-model "$QWEN4_REPO"
          --catalog-key "$QWEN4_ID" --out "$RES/buyer-ux-record.json" --samples "$BUX_SAMPLES")
if [ "${LISTING_JOB_CHECK:-0}" = 1 ]; then
  printf 'SERVE_CONFIG %s\n' "$(echo "$SERVE_CONFIG" | tr '\n' ' ')"
  printf 'SERVE_ARGS'; printf ' %s' "${SERVE_ARGS[@]}"; echo
  for n in "${CTX_LIST[@]}"; do client_args "$n"; printf 'CLIENT_ARGS'; printf ' %s' "${CARGS[@]}"; echo " output=$MEM_OUTPUT"; done
  printf 'BUX_ARGS'; printf ' %s' "${BUX_ARGS[@]}"; echo
  printf 'PROFILE_ARGS'; printf ' %s' "${PROFILE_ARGS[@]}"; echo
  printf 'BUILD_FLAGS -DMACPROVIDER_LAB_HARNESS build_path=%s\n' "$BUILD"
  exit 0
fi

rm -rf "$RES" && mkdir -p "$RES/serve" "$RES/mem"
log "JOB_START qwen4-listing run=$RUN_ID commit=${COMMIT:-unknown} model=$QWEN4_PATH id=$QWEN4_ID contexts=$MEM_CONTEXTS output=$MEM_OUTPUT bux_samples=$BUX_SAMPLES"
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
if lsof -nP -iTCP:$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then die "port $PORT is busy" 3; fi
for f in "$GRID/provider_client.py" "$GRID/route_status.py" "$JOB/bux/buyer_ux_conformance.py" \
         "$JOB/ablit-perf/buyer_ux_local.py" "$JOB/ablit-perf/listing_memory.py" "$JOB/minimax/publish_abliterated.py"; do
  [ -f "$f" ] || die "missing $f (the launcher copies it)" 11
done

# 1. Stage, before any GPU work (job-qwen4-cb.sh's download and manifest handling).
if [ ! -f "$QWEN4_PATH/config.json" ]; then
  if ! "$VENV/bin/hf" version > /dev/null 2>&1; then
    rm -rf "$VENV"
    PY312=$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)
    [ -x "$PY312" ] || die "python3.12 not found (for the hf download tool)" 11
    "$PY312" -m venv "$VENV" && "$VENV/bin/pip" install -q "mlx-lm @ git+https://github.com/ml-explore/mlx-lm@$MLX_LM_COMMIT" \
      > "$RES/venv.log" 2>&1 || die "venv: $(tail -n 2 "$RES/venv.log" | tr '\n' ' ')" 11
  fi
  free_gb=$(df -g "$LAB" | awk 'NR==2 {print $4}')
  [ "${free_gb:-0}" -ge 130 ] || die "need 130 GB free for the 106 GB snapshot, have ${free_gb} GB" 11
  log "DOWNLOAD $QWEN4_REPO@$QWEN4_REVISION"
  "$VENV/bin/hf" download "$QWEN4_REPO" --revision "$QWEN4_REVISION" --local-dir "$QWEN4_PATH" \
    > "$RES/download.log" 2>&1 || die "download: $(tail -n 2 "$RES/download.log" | tr '\n' ' ')" 11
fi
[ "$(ls "$QWEN4_PATH"/model-*.safetensors 2> /dev/null | wc -l | tr -d ' ')" = 21 ] || die "snapshot at $QWEN4_PATH is not 21 shards" 11
model_type=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model_type"))' "$QWEN4_PATH/config.json")
manifest=$(/usr/bin/python3 -I -c 'import sys,pathlib; sys.path.insert(0, sys.argv[1])
from publish_abliterated import snapshot_manifest_sha256 as m; print(m(pathlib.Path(sys.argv[2])))' "$JOB/minimax" "$QWEN4_PATH")
echo "$manifest" | grep -Eq '^[0-9a-f]{64}$' || die "snapshot manifest of $QWEN4_PATH failed: $manifest" 11
log "MODEL $QWEN4_ID model_type=$model_type manifest_sha256=$manifest expected=$QWEN4_SHA256"
[ "$model_type" = qwen4_exp ] || die "config.json model_type is $model_type, not qwen4_exp" 11
[ "$manifest" = "$QWEN4_SHA256" ] || die "snapshot manifest $manifest differs from QWEN4_SHA256 $QWEN4_SHA256 (not the pinned snapshot)" 11
# Context cap: the config's position limit (text_config included), less the output and a template margin.
MAX_POS=$(/usr/bin/python3 -I -c 'import json,sys
c=json.load(open(sys.argv[1])); t=c.get("text_config") or {}
v=c.get("max_position_embeddings") or t.get("max_position_embeddings") or 0
print(v if isinstance(v,int) else 0)' "$QWEN4_PATH/config.json")
log "MEM_CONFIG max_position_embeddings=$MAX_POS"

# 2. Lab-harness build of this tree on the pinned engine (job.sh's build path).
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD start"
  (cd "$SRC" && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD" \
    -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/build.log" 2>&1 \
    || die "swift build failed: $(tail -n 3 "$RES/build.log" | tr '\n' ' ')" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no lab-harness binary at $BIN" 14
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" > "$RES/identity.sha256"
log "BUILD done $("$BIN/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity.sha256" | head -n 1)"

FAILED=0
blocker() { log "BLOCKER: $*"; FAILED=1; }
SP=""
PP=""
stop_serve() {
  [ -n "$SP" ] && kill -0 "$SP" 2>/dev/null || return 0
  kill -TERM "$SP" 2>/dev/null
  for _ in $(seq 1 60); do kill -0 "$SP" 2>/dev/null || return 0; sleep 0.5; done
  kill -KILL "$SP" 2>/dev/null
}
cleanup() { stop_serve; [ -n "$PP" ] && kill -TERM "$PP" 2>/dev/null; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
sample() { /usr/bin/python3 -I "$JOB/ablit-perf/listing_memory.py" sample --pid "$1" --label "$2" >> "$RES/mem/samples.jsonl" \
  && log "MEM_SAMPLE $(tail -n 1 "$RES/mem/samples.jsonl")"; }

# 3. Serve under the catalog id, production route, one row.
echo "$SERVE_CONFIG" > "$RES/serve/config.yaml"
log "SERVE start port=$PORT id=$QWEN4_ID"
(cd "$BIN" && exec "$BIN/macprovider-cli" "${SERVE_ARGS[@]}" > "$RES/serve/serve.out" 2> "$RES/serve/serve.err" < /dev/null) &
SP=$!
ready=0
while kill -0 "$SP" 2>/dev/null; do  # no deadline: the launcher's stall watcher sees a hung load
  if curl -s --max-time 3 "http://127.0.0.1:$PORT/v1/status" | /usr/bin/python3 -I -c \
      'import json,sys; sys.exit(0 if json.load(sys.stdin).get("model_loaded") is True else 1)' 2>/dev/null; then
    ready=1; break
  fi
  sleep 5
done
[ "$ready" = 1 ] || die "serve exited before the model loaded: $(tail -n 5 "$RES/serve/serve.err" | tr '\n' ' ')" 5
curl -s "http://127.0.0.1:$PORT/v1/status" > "$RES/serve/status-ready.json"
curl -s "http://127.0.0.1:$PORT/v1/models" > "$RES/serve/models.json"
sample "$SP" "serve loaded"
# No inference request until any self-check decided (it runs only while the serve is idle).
/usr/bin/python3 -I "$GRID/route_status.py" gate --port "$PORT" --serve-err "$RES/serve/serve.err" --pid "$SP" \
  > "$RES/serve/route-gate.txt" 2>&1
curl -s "http://127.0.0.1:$PORT/v1/status" > "$RES/serve/status.json"
echo '{}' > "$RES/serve/route.json"
/usr/bin/python3 -I "$GRID/route_status.py" record --status "$RES/serve/status.json" --serve-err "$RES/serve/serve.err" \
  --grid "$RES/serve/route.json" --phase start --expect any | tee "$RES/serve/route.txt"
grep -q '^ROUTE batching=serial ' "$RES/serve/route.txt" \
  || blocker "the serve is not on the serial route a catalog row with no batching entry takes: $(head -n 1 "$RES/serve/route.txt")"

# a. Identity.
/usr/bin/python3 -I - "$RES/serve/status.json" "$RES/serve/models.json" "$QWEN4_ID" "$QWEN4_SHA256" <<'PY' | tee "$RES/identity.txt"
import json, sys
s = json.load(open(sys.argv[1]))
try:
    ids = [m.get("id") for m in json.load(open(sys.argv[2])).get("data") or []]
except Exception:
    ids = []
ok = s.get("model") == sys.argv[3] and s.get("model_hash") == sys.argv[4] and sys.argv[3] in ids
print("IDENTITY_STATUS model=%s model_hash=%s algorithm=%s models=%s %s" % (
    s.get("model"), s.get("model_hash"), s.get("model_hash_algorithm"), ids, "ok" if ok else "MISMATCH"))
sys.exit(0 if ok else 1)
PY
[ "${PIPESTATUS[0]}" = 0 ] || blocker "the serve does not report $QWEN4_ID with model_hash $QWEN4_SHA256 (identity.txt)"
fam_lines=$(grep -c 'qwen4_exp' "$RES/serve/serve.err")
grep -m 3 'qwen4_exp' "$RES/serve/serve.err" | cut -c1-300 | sed 's/^/IDENTITY_SERVE_LOG /' | tee -a "$RES/identity.txt"

# b. Memory: one request per context, a footprint sample after each.
SERVE_MAX_CTX=$(/usr/bin/python3 -I -c 'import json,sys
c=(json.load(open(sys.argv[1])).get("capacity") or {}).get("max_context_tokens"); print(c if isinstance(c,int) else 0)' \
  "$RES/serve/status.json" 2>/dev/null || echo 0)
log "MEM_LIMITS max_position_embeddings=$MAX_POS serve_max_context_tokens=$SERVE_MAX_CTX"
RUN_CTX=()
for n in "${CTX_LIST[@]}"; do
  cap=$n
  for lim in "$MAX_POS" "$SERVE_MAX_CTX"; do
    [ "$lim" -gt 0 ] && [ $((cap + MEM_OUTPUT + 512)) -gt "$lim" ] && cap=$((lim - MEM_OUTPUT - 512))
  done
  [ "$cap" = "$n" ] || log "MEM_CAP context $n -> $cap (the largest the limits above allow)"
  [ "$cap" -ge 200 ] || { blocker "context $n leaves no room under the limits"; continue; }
  RUN_CTX+=("$cap")
  /usr/bin/python3 -I -c 'import json,sys
json.dump({"schema": "parity-grid.v1", "outputs": [int(sys.argv[2])], "contexts": [{"name": sys.argv[1], "tokens": int(sys.argv[1])}],
           "rows": [1], "trials": 1, "warmup_tokens": 32, "noise_floor": 0.03}, open(sys.argv[3], "w"), indent=2)' \
    "$cap" "$MEM_OUTPUT" "$RES/mem/grid-$cap.json"
  client_args "$cap"
  /usr/bin/python3 -I "$GRID/provider_client.py" "${CARGS[@]}" >> "$RES/mem/client.log" 2>&1 \
    || blocker "the $cap-token request failed: $(tail -n 2 "$RES/mem/client.log" | tr '\n' ' ')"
  /usr/bin/python3 -I -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r=[x for x in rows if x.get("kind")=="row" and x.get("ctx_target")==int(sys.argv[2])][-1:]
print("MEM_CELL ctx=%s prompt_tokens=%s completion_tokens=%s ttft_s=%s decode_tps=%s error=%s" % ((sys.argv[2],) + tuple(
    r[0].get(k) for k in ("prompt_tokens","completion_tokens","ttft_s","decode_tps","error")) if r else (sys.argv[2],)+("?",)*5))' \
    "$RES/mem/provider.jsonl" "$cap" 2>/dev/null | while read -r l; do log "$l"; done
  sample "$SP" "serve after ctx=$cap" || blocker "no footprint sample after ctx=$cap"
done

# c. Buyer-UX suite against the same serve.
log "BUX_START samples=$BUX_SAMPLES"
/usr/bin/python3 -I "$JOB/ablit-perf/buyer_ux_local.py" "${BUX_ARGS[@]}" > "$RES/buyer-ux.txt" 2>&1
bux_rc=$?
while read -r l; do log "$l"; done < "$RES/buyer-ux.txt"
[ "$bux_rc" = 0 ] || blocker "buyer-UX gate failed (rc=$bux_rc): $(grep -m1 '^BUX_GATE' "$RES/buyer-ux.txt" | cut -c1-400)"
sample "$SP" "serve end" || blocker "no footprint sample at the serve end"
curl -s "http://127.0.0.1:$PORT/v1/status" > "$RES/serve/status-end.json"
grep -m1 'event=inference_error' "$RES/serve/serve.err" | cut -c1-400 | sed 's/^/INFERENCE_ERROR /'
stop_serve
SP=""

# MLX peak per context: the serve's serial path in its own process (no serve runs now).
if [ "${#RUN_CTX[@]}" -gt 0 ]; then
  PROFILE_ARGS=(prefill-profile --model-dir "$QWEN4_PATH" --prompt-text "$SRC/Sources/macprovider-cli/ModelRuntime.swift"
                --prompt-tokens "$(IFS=,; echo "${RUN_CTX[*]}")" --step-sizes "$PROFILE_STEP" --runs 1
                --generate-tokens "$MEM_OUTPUT" --served-only --output "$RES/prefill-profile.json")
  log "PROFILE_START ${PROFILE_ARGS[*]}"
  "$BIN/macprovider-cli" "${PROFILE_ARGS[@]}" > "$RES/prefill-profile.stdout" 2> "$RES/prefill-profile.stderr" &
  PP=$!
  last=""
  while kill -0 "$PP" 2>/dev/null; do
    s=$(/usr/bin/python3 -I "$JOB/ablit-perf/listing_memory.py" sample --pid "$PP" --label prefill-profile 2>/dev/null) && last=$s
    sleep 5
  done
  wait "$PP"; prc=$?; PP=""
  [ -n "$last" ] && echo "$last" >> "$RES/mem/samples.jsonl"
  grep '^prefill-profile: ' "$RES/prefill-profile.stderr" | sed 's/^/PROFILE_ /'
  [ "$prc" = 0 ] && [ -s "$RES/prefill-profile.json" ] \
    || blocker "prefill-profile exit $prc: $(tail -n 3 "$RES/prefill-profile.stderr" | tr '\n' ' ')"
  grep -q 'family=qwen4_exp' "$RES/prefill-profile.stderr" && fam_lines=$((fam_lines + 1)) \
    && grep -m1 'family=' "$RES/prefill-profile.stderr" | sed 's/^/IDENTITY_PROFILE_LOG /' | tee -a "$RES/identity.txt"
fi
[ "$fam_lines" -gt 0 ] || blocker "neither serve.err nor the prefill-profile load line names the qwen4_exp family"

# Report: footprint table, MLX peaks, proposed min_ram_gb.
/usr/bin/python3 -I "$JOB/ablit-perf/listing_memory.py" report --samples "$RES/mem/samples.jsonl" \
  --profile "$RES/prefill-profile.json" --ram-bytes "$(sysctl -n hw.memsize)" \
  --out-md "$RES/memory.md" --out-json "$RES/memory.json" > "$RES/memory.stdout" 2>&1 \
  && sed 's/^/MEM_REPORT /' "$RES/memory.md" \
  || blocker "memory report: $(tail -n 2 "$RES/memory.stdout" | tr '\n' ' ')"
[ -s "$RES/memory.json" ] && log "LISTING_MIN_RAM_GB $(/usr/bin/python3 -I -c 'import json,sys
r=json.load(open(sys.argv[1])); print(r["proposed_min_ram_gb"], "peak_gib=%s" % r["serve_lifetime_peak_gib"], "serve_default_step=%s" % r["serve_default_step"])' "$RES/memory.json")"

[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
