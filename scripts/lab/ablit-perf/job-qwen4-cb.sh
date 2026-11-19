#!/bin/bash
# Runs ON THE STUDIO from ~/lab-ablit-perf/job/ablit-perf/. Campaign #2409 cell: continuous-batching
# throughput of the native qwen4_exp (Qwen3.8-Flash-Next heretic-2 oQ4e-mtp) port at 1, 4, 8 and 16
# rows, our provider against stock mlx-lm's batched generation on the same weights and prompts.
# Goal metric: aggregate output tok/s (total completion tokens / (last token of the last row -
# first request start)) per cell, both sides, plus TTFT and token parity.
#
# Steps:
#  1. stage before any GPU work (as job-qwen4-parity.sh): the fork checkout with the batched Qwen4Exp
#     (FORK), the mlx-lm venv pinned to the commit that added qwen4_exp (it must also import
#     BatchGenerator), the snapshot (Hugging Face download at the pinned revision when QWEN4_PATH
#     is absent);
#  2. lab-harness release build of the rsynced campaign tree (~/lab-ablit-perf/src/phase3-binary) in
#     its own build path with the mlx-swift-lm dependency replaced by FORK (`swift package edit`, this
#     build path only), the release metallib beside the binary;
#  3. scripts/lab/parity-grid/run-grid.sh, one invocation: our provider first, then the reference, then
#     compare.py. The provider serves the snapshot under QWEN4_ID with its snapshot-manifest hash
#     (run-grid --model-id/--model-sha256; the serve verifies the hash; no catalog entry or CB policy
#     entry is needed with `--no-join`). Both are required for batching: the paged engine attaches
#     Qwen4-Exp only under the allowlisted id, and with no verified model hash the provider requests
#     no CB tuple, so the self-check never runs and the serve stays serial. The serve config carries
#     `continuous_batching: canary` and the accepted tuple qwen4_cb_tuple.py computes the way the
#     provider does (job.sh cb_extra takes it from a signed entry instead); it grants cached turns, and
#     after the grid `check` compares it with the serve's `[paged-kv] runtime-identity` line
#     (TUPLE_MATCH, else a BLOCKER). The serve runs the production route (`--cb auto`, no autotune
#     flag) with the served slots owner-pinned to CB_SLOTS
#     (16: config max_concurrency_override + max_concurrency_source owner; the self-check only lowers
#     the pin to the width it verifies), the cached-turns grant and a queue limit of CB_SLOTS. A
#     `--no-join` serve never loads a signed CB policy, so the serve first waits, idle, for the CB
#     self-check verdict (run-grid.sh batching warm-up) and `--expect-route batched` fails the job
#     when the route is serial. Grid: rows CB_ROWS (1,4,8,16) x contexts CONTEXTS (200,4000) x outputs
#     OUTPUTS (512), TRIALS (3). The reference is reference_mlxlm.py --loader qwen4 --batched: the
#     qwen4_oracle.py loader shim (the oQ4e build has mixed-width hyper-connection pairs that stock
#     mlx_lm.load cannot read) and mlx-lm's BatchGenerator, greedy, one batch per N-row cell (its
#     header has the timing definitions); rows 1 runs stream_generate as in the other jobs;
#  4. checks: the ROUTE slots at the grid start and end equal CB_SLOTS (PASS_SLOTS line; the
#     self-check ladder stored in cb-self-check.json is copied into the results and summarized in
#     one CB_SELF_CHECK line), no REFERENCE_FAIL/SUSPECT, no ROUTE_FAIL.
#
# Results: ~/lab-ablit-perf/results/<run>/qwen4-flash-next-cb/main/{provider.jsonl,reference.jsonl,
# summary.md,summary.json,grid.json,run.log,serve/} and .../cb-self-check.json.
# Env: CB_ROWS CB_SLOTS CONTEXTS OUTPUTS TRIALS REF_PREFILL_BATCH_SIZE (mlx-lm prefill_batch_size,
# default its own 8) QWEN4_PATH QWEN4_REPO QWEN4_REVISION QWEN4_ID QWEN4_SHA256 (the snapshot-manifest
# hash; computed from QWEN4_PATH when unset, and the serve refuses a wrong one) FORK METALLIB SKIP_BUILD
# SEED_SELF_CHECK_RUN (a run id whose .../qwen4-flash-next-cb/main/serve/cb-self-check.json seeds
# the serve, so the ~5+ min idle self-check is skipped when its key matches). CB_JOB_CHECK=1:
# validate the knobs, print the run-grid argv and exit 0 before touching anything (the unit test).
# Every failure prints `BLOCKER:`; the job ends with JOB_PASS (exit 0) or JOB_FAIL (nonzero). A cell
# slower than the reference, or a text/token difference run-grid.sh reports as rc 1, is a finding:
# the table is printed and the job still passes.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-ablit-perf
JOB=$LAB/job
GRID=$JOB/parity-grid
SRC=$LAB/src/phase3-binary
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
NAME=qwen4-flash-next-cb
RES=$LAB/results/$RUN_ID
OUT=$RES/$NAME/main
QWEN4_REPO=${QWEN4_REPO:-latent-variable/Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp}
QWEN4_REVISION=${QWEN4_REVISION:-65b0cd66046e41b63fb565466c5a52a6295a7592}
QWEN4_PATH=${QWEN4_PATH:-$LAB/models/Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp}
QWEN4_ID=${QWEN4_ID:-latent-variable/qwen3.8-flash-next-heretic-2-oq4e-mtp}
QWEN4_SHA256=${QWEN4_SHA256:-}
FORK=${FORK:-$LAB/mlx-swift-lm-2409}
CB_ROWS=${CB_ROWS:-1,4,8,16}
CB_SLOTS=${CB_SLOTS:-16}
CONTEXTS=${CONTEXTS:-200,4000}
OUTPUTS=${OUTPUTS:-512}
TRIALS=${TRIALS:-3}
REF_PREFILL_BATCH_SIZE=${REF_PREFILL_BATCH_SIZE:-}
SEED_SELF_CHECK_RUN=${SEED_SELF_CHECK_RUN:-}
MLX_LM_COMMIT=c4c9c762cc797fd979fc98645f5db5112753bbe9
VENV=$LAB/venv-lm-qwen4
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-qwen4
BIN=$SRC/$BUILD/release
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }

# Knobs: validated before anything is touched.
case "$CB_ROWS" in ""|*[!0-9,]*|,*|*,|*,,*) die "CB_ROWS=$CB_ROWS must be a comma list of row counts" 64 ;; esac
MAX_ROWS=0
IFS=, read -r -a ROW_LIST <<< "$CB_ROWS"
for r in "${ROW_LIST[@]}"; do
  [ "$r" -ge 1 ] && [ "$r" -le 32 ] || die "CB_ROWS: $r is not 1..32" 64
  [ "$r" -le "$MAX_ROWS" ] || MAX_ROWS=$r
done
case "$CB_SLOTS" in ""|*[!0-9]*) die "CB_SLOTS=$CB_SLOTS must be a number" 64 ;; esac
[ "$CB_SLOTS" -ge 1 ] && [ "$CB_SLOTS" -le 32 ] || die "CB_SLOTS=$CB_SLOTS must be 1..32" 64
[ "$CB_SLOTS" -ge "$MAX_ROWS" ] || die "CB_SLOTS=$CB_SLOTS is below the largest row count $MAX_ROWS: its rows would queue, not batch" 64
case "$CONTEXTS" in ""|*[!A-Za-z0-9,]*) die "CONTEXTS=$CONTEXTS must be a comma list of context names or token counts" 64 ;; esac
case "$OUTPUTS" in ""|*[!0-9,]*) die "OUTPUTS=$OUTPUTS must be a comma list of token counts" 64 ;; esac
case "$TRIALS" in ""|*[!0-9]*|0) die "TRIALS=$TRIALS must be a positive number" 64 ;; esac
case "$REF_PREFILL_BATCH_SIZE" in ""|[1-9]|[1-9][0-9]) ;; *) die "REF_PREFILL_BATCH_SIZE=$REF_PREFILL_BATCH_SIZE must be 1..99" 64 ;; esac
[ -z "$SEED_SELF_CHECK_RUN" ] || echo "$SEED_SELF_CHECK_RUN" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$' || die "SEED_SELF_CHECK_RUN=$SEED_SELF_CHECK_RUN is not a run id" 64
[ -z "$QWEN4_SHA256" ] || echo "$QWEN4_SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "QWEN4_SHA256=$QWEN4_SHA256 is not a lowercase sha256" 64
echo "$QWEN4_ID" | grep -Eq '^[a-z0-9._-]+/[a-z0-9._-]+$' || die "QWEN4_ID=$QWEN4_ID is not a lowercase org/name id" 64

# The run-grid.sh argv (serve flags, reference flags, grid cut). The config extra file is written by the caller.
grid_args() {
  GARGS=(--model-path "$QWEN4_PATH" --model-id "$QWEN4_ID" --model-sha256 "${QWEN4_SHA256:-<snapshot-manifest>}"
         --model-name "$NAME" --bin-dir "$BIN" --out-dir "$OUT" --cb auto
         --no-autotune-candidate --rows "$CB_ROWS" --contexts "$CONTEXTS" --outputs "$OUTPUTS" --trials "$TRIALS"
         --config-extra "$RES/$NAME/serve-extra.yaml" --expect-route batched
         --python "$VENV/bin/python" --reference mlx-lm --ref-arg --loader --ref-arg qwen4 --ref-arg --batched)
  [ -z "$REF_PREFILL_BATCH_SIZE" ] || GARGS+=(--ref-arg --prefill-batch-size --ref-arg "$REF_PREFILL_BATCH_SIZE")
  [ -z "$SEED_SELF_CHECK_RUN" ] || GARGS+=(--seed-self-check "$LAB/results/$SEED_SELF_CHECK_RUN/$NAME/main/serve/cb-self-check.json")
}
if [ "${CB_JOB_CHECK:-0}" = 1 ]; then
  grid_args
  printf 'GRID_ARGS'; printf ' %s' "${GARGS[@]}"; echo
  printf 'SERVE_EXTRA continuous_batching=canary accepted_tuple=computed max_concurrency_override=%s max_concurrency_source=owner continuous_batch_queue_limit=%s\n' "$CB_SLOTS" "$CB_SLOTS"
  exit 0
fi

mkdir -p "$OUT/serve"
log "JOB_START qwen4-cb run=$RUN_ID commit=${COMMIT:-unknown} model=$QWEN4_PATH fork=$FORK rows=$CB_ROWS slots=$CB_SLOTS contexts=$CONTEXTS outputs=$OUTPUTS trials=$TRIALS${SEED_SELF_CHECK_RUN:+ seed=$SEED_SELF_CHECK_RUN}"
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
if [ -n "$SEED_SELF_CHECK_RUN" ]; then
  [ -s "$LAB/results/$SEED_SELF_CHECK_RUN/$NAME/main/serve/cb-self-check.json" ] \
    || die "SEED_SELF_CHECK_RUN: no cb-self-check.json at $LAB/results/$SEED_SELF_CHECK_RUN/$NAME/main/serve" 11
fi

# 1. Stage, before any GPU work.
[ -f "$FORK/Libraries/MLXLLM/Models/Qwen4Exp.swift" ] \
  || die "no fork checkout with the qwen4_exp port at FORK=$FORK (rsync the campaign/2409-qwen4-exp-batch worktree there)" 11
log "FORK $(git -C "$FORK" rev-parse HEAD 2>/dev/null || echo no-git) $(git -C "$FORK" status --porcelain 2>/dev/null | wc -l | tr -d ' ') uncommitted"
if ! "$VENV/bin/python" -I -c "import mlx_lm.models.qwen4_exp; from mlx_lm.generate import BatchGenerator" > /dev/null 2>&1; then
  rm -rf "$VENV"
  PY312=$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)
  [ -x "$PY312" ] || die "python3.12 not found (the mlx wheels need it)" 11
  "$PY312" -m venv "$VENV" && "$VENV/bin/pip" install -q "mlx-lm @ git+https://github.com/ml-explore/mlx-lm@$MLX_LM_COMMIT" \
    > "$RES/venv.log" 2>&1 || die "venv: $(tail -n 2 "$RES/venv.log" | tr '\n' ' ')" 11
  "$VENV/bin/python" -I -c "import mlx_lm.models.qwen4_exp; from mlx_lm.generate import BatchGenerator" > /dev/null 2>&1 \
    || die "the venv's mlx-lm has no qwen4_exp model or no BatchGenerator" 11
fi
log "REF_VERSION $("$VENV/bin/python" -I -c 'import importlib.metadata as m; print("mlx", m.version("mlx"), "mlx-lm", m.version("mlx-lm"))')"
if [ ! -f "$QWEN4_PATH/config.json" ]; then
  free_gb=$(df -g "$LAB" | awk 'NR==2 {print $4}')
  [ "${free_gb:-0}" -ge 130 ] || die "need 130 GB free for the 106 GB snapshot, have ${free_gb} GB" 11
  log "DOWNLOAD $QWEN4_REPO@$QWEN4_REVISION"
  "$VENV/bin/hf" download "$QWEN4_REPO" --revision "$QWEN4_REVISION" --local-dir "$QWEN4_PATH" \
    > "$RES/download.log" 2>&1 || die "download: $(tail -n 2 "$RES/download.log" | tr '\n' ' ')" 11
fi
[ "$(ls "$QWEN4_PATH"/model-*.safetensors 2> /dev/null | wc -l | tr -d ' ')" = 21 ] || die "snapshot at $QWEN4_PATH is not 21 shards" 11
[ -f "$JOB/ablit-perf/qwen4_oracle.py" ] || die "no qwen4_oracle.py at $JOB/ablit-perf (the reference loader)" 11
cp "$JOB/ablit-perf/qwen4_oracle.py" "$RES/qwen4_oracle.py"  # the run record keeps the loader it ran
cp "$GRID/reference_mlxlm.py" "$RES/reference_mlxlm.py"
[ -f "$JOB/minimax/publish_abliterated.py" ] || die "no publish_abliterated.py at $JOB/minimax (the snapshot-manifest hash)" 11
if [ -z "$QWEN4_SHA256" ]; then
  # macprovider.snapshot-manifest.v1, as job.sh manifest(): what the serve verifies as model_artifact_sha256.
  QWEN4_SHA256=$(/usr/bin/python3 -I -c 'import sys,pathlib; sys.path.insert(0, sys.argv[1])
from publish_abliterated import snapshot_manifest_sha256 as m; print(m(pathlib.Path(sys.argv[2])))' "$JOB/minimax" "$QWEN4_PATH") \
    && echo "$QWEN4_SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "snapshot manifest of $QWEN4_PATH failed: $QWEN4_SHA256" 11
fi
log "MODEL $QWEN4_ID model_sha256=$QWEN4_SHA256"

# 2. Lab-harness build against the fork (own build path: job.sh's build stays on the pin).
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD start"
  (cd "$SRC" && swift package --build-path "$BUILD" unedit mlx-swift-lm > /dev/null 2>&1
   swift package --build-path "$BUILD" edit mlx-swift-lm --path "$FORK" \
     && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD" -Xswiftc -DMACPROVIDER_LAB_HARNESS) \
    > "$RES/build.log" 2>&1 || die "swift build failed: $(tail -n 3 "$RES/build.log" | tr '\n' ' ')" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no lab-harness binary at $BIN" 14
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" > "$RES/identity.sha256"
log "BUILD done $("$BIN/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity.sha256" | head -n 1)"

# Serve config extra (job.sh cb_extra / <K>_SERVED_SLOTS): canary mode and the accepted tuple with its
# cached-turns grant (computed: no signed entry exists), owner-pinned served slots and the queue limit
# that bounds the self-check ladder. The tuple binds the metallib beside the binary, so it follows the build.
/usr/bin/python3 -I "$JOB/ablit-perf/qwen4_cb_tuple.py" tuple --model-path "$QWEN4_PATH" --model-id "$QWEN4_ID" \
  --model-sha256 "$QWEN4_SHA256" --metallib "$BIN/mlx.metallib" --yaml-out "$RES/$NAME/cb-tuple.yaml" \
  --json-out "$RES/$NAME/cb-tuple.json" > "$RES/$NAME/cb-tuple.out" 2>&1 \
  || die "CB tuple: $(tail -n 2 "$RES/$NAME/cb-tuple.out" | tr '\n' ' ')" 11
log "CB_TUPLE $(cat "$RES/$NAME/cb-tuple.out")"
{ cat "$RES/$NAME/cb-tuple.yaml"; cat <<EOF
continuous_batching_cached_turns: true
continuous_batch_queue_limit: $CB_SLOTS
max_concurrency_override: $CB_SLOTS
max_concurrency_source: owner
EOF
} > "$RES/$NAME/serve-extra.yaml"

# 3. Provider grid, batched reference, compare: one run-grid.sh.
grid_args
log "GRID_START $NAME rows=$CB_ROWS slots=$CB_SLOTS contexts=$CONTEXTS outputs=$OUTPUTS trials=$TRIALS reference=mlx-lm batched (qwen4 loader) expect_route=batched"
bash "$GRID/run-grid.sh" "${GARGS[@]}" > "$OUT/run.log" 2>&1
rc=$?
log "GRID_DONE $NAME rc=$rc (0 all cells pass, 1 a cell fails the ratio/text gates: a finding, 7 the client failed, 8 the reference failed, 9 it was suspect, 10 the route was serial, other: before the client)"
grep -E '^(CB_WARMUP_DONE|CB_WARMUP_STALL|CB_WARMUP_FAIL|ROUTE|ROUTE_FAIL|REFERENCE_SANE|REFERENCE_SUSPECT|REFERENCE_FAIL) ' "$OUT/run.log" | sed "s/^/GRID_ /"
FAILED=0
blocker() { log "BLOCKER: $*"; FAILED=1; }
case $rc in
  0|1) sed -n '/^| model/,/^$/p' "$OUT/summary.md" ;;
  8|9) sed -n '/^| model/,/^$/p' "$OUT/summary.md" 2> /dev/null
       blocker "the reference failed or is suspect; provider cells are measured, reference columns are empty ($(grep -m1 -E '^REFERENCE_(FAIL|SUSPECT) ' "$OUT/run.log" | cut -c1-300))" ;;
  10) sed -n '/^| model/,/^$/p' "$OUT/summary.md" 2> /dev/null
      blocker "ROUTE_FAIL: the serve was serial, not batched ($(grep -m1 '^ROUTE_FAIL ' "$OUT/run.log" | cut -c1-300))" ;;
  *) blocker "grid rc=$rc: $(tail -n 3 "$OUT/run.log" | tr '\n' ' ')" ;;
esac
grep -q '^ROUTE_FAIL ' "$OUT/run.log" && [ $rc != 10 ] && blocker "ROUTE_FAIL: $(grep -m1 '^ROUTE_FAIL ' "$OUT/run.log" | cut -c1-300)"

# 4. The computed tuple against the identity the serve measured, the self-check ladder and the served slots.
/usr/bin/python3 -I "$JOB/ablit-perf/qwen4_cb_tuple.py" check --tuple-json "$RES/$NAME/cb-tuple.json" \
  --serve-err "$OUT/serve/serve.err" | tee "$RES/$NAME/cb-tuple-check.txt"
[ "${PIPESTATUS[0]}" = 0 ] || blocker "the computed CB tuple does not match the serve's runtime identity: $(cut -c1-400 "$RES/$NAME/cb-tuple-check.txt")"
grep -m1 'event=inference_error' "$OUT/serve/serve.err" | cut -c1-400 | sed 's/^/INFERENCE_ERROR /'
if [ -s "$OUT/serve/cb-self-check.json" ]; then
  cp "$OUT/serve/cb-self-check.json" "$RES/$NAME/cb-self-check.json"
  /usr/bin/python3 -I - "$RES/$NAME/cb-self-check.json" <<'PY' | sed 's/^/CB_SELF_CHECK /'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("unreadable:", e); sys.exit()
print(json.dumps(d, sort_keys=True)[:900])
PY
else
  blocker "no cb-self-check.json in $OUT/serve: the self-check stored no verdict (the ladder is not recorded)"
fi
if [ -f "$OUT/grid.json" ]; then
  /usr/bin/python3 -I -c 'import json,sys
r=json.load(open(sys.argv[1])).get("route",{}); want=int(sys.argv[2])
got={p:(r.get(p) or {}).get("slots") for p in ("start","end")}
print("PASS_SLOTS want=%d start=%s end=%s verified_k=%s" % (want, got["start"], got["end"], (r.get("start") or {}).get("verified_k")))
sys.exit(0 if all(v==want for v in got.values()) else 1)' "$OUT/grid.json" "$CB_SLOTS" | tee -a "$OUT/slots.txt"
  [ "${PIPESTATUS[0]}" = 0 ] || blocker "served slots differ from the pin $CB_SLOTS (verified_k above is the width the self-check verified): the wide cells did not batch at their row count"
else
  blocker "no grid.json in $OUT"
fi
[ -s "$OUT/provider.jsonl" ] && [ -s "$OUT/reference.jsonl" ] || blocker "provider.jsonl or reference.jsonl missing or empty in $OUT"

[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
