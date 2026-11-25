#!/bin/bash
# Runs ON THE STUDIO, started detached by scratchpad/windows/window-2466.sh, which has already
# paused live, the runner's Studio target and the FLOP miner and holds the Studio GPU lock. This
# job never pauses, restores or restarts any of them; it refuses to start while anything still runs.
#
# #2466 catalog intake: Sage-S2.1-Flash (Hygaard/Sage-S2.1-Flash-oQ4e-mtp @ SAGE_REV, glm5_next,
# embedded next-N layer, 186.6 GB) against the zai-org/glm-5.3-flash row (Jundot/GLM-5.3-Flash-oQ4e-mtp,
# store snapshot 7299b6a7). Every cell runs the incumbent first, then the candidate, back to back; one
# model is resident at a time (each cell is its own process). Shared tools live in scripts/lab/2465/.
#
# Steps:
#  1. preflight: nothing on :8080/:8000/:$PORT, no live agent, serve, FLOP agent or VM process;
#     inputs present; the metallib is the signed native-MTP entry's (GLM-5.3-Flash);
#  2. snapshot: ~/lab-2466/models/Sage-S2.1-Flash-oQ4e-mtp@SAGE_REV must carry the .verified marker
#     written by scripts/lab/2466/fetch-sage.sh (hf download + per-file sha256/size check).
#     The job then checks the pinned total byte count and file count;
#  3. disk gate: free >= SAGE_GB + EXTRA_GB (60): the native-MTP admission capture copies the
#     whole model on a serve start (#2468), so the window keeps one model's worth free;
#  4. lab-harness release build (-DMACPROVIDER_LAB_HARNESS) in $SRC/phase3-binary/.build-lab-2466;
#  5. identities and fixtures ~/lab-2466/fixtures/<label>/target (APFS clones; glm5_next embeds
#     its MTP layer, so no mtp/ directory);
#  6. cells (CELLS, default "decode aggregate parity reference mtp quality"):
#     decode     decode-bench --prefill-tokens 1024/8192/32768 --decode-tokens 256 --runs 5;
#     aggregate  msb-throughput --engine scheduler --rows 4 at 1024 and 8192, then --scenario msb03;
#     parity     msb-throughput --engine scheduler --scenario parity --rows 4 --parity-tokens 256;
#     reference  scripts/lab/cb-studio/glm53_bench_vlm.py (the GLM lane's mlx-vlm reference) in
#                REF_VENV at 1024/8192/32768, 256 greedy tokens (retried with --omlx-vendor when
#                stock mlx-vlm cannot load the model), glm53_oracle_json.py, then glm-parity
#                --steps 256 --prefill-step-size 2048 --mlx-cache-limit-mb 2048;
#     mtp        native-mtp-bench exploratory s1 cells (prompts 1536/4096, outputs 128/512,
#                MTP_BLOCKS 10, depth 1), then scripts/native_mtp_r015_analyze.py, both models;
#     quality    scripts/lab/2465/quality.py on the coding workload against a loopback
#                `serve --no-join` (native MTP off, CB off); if the candidate's serve does not come
#                up, both models run the mlx-vlm reference instead;
#  7. scripts/lab/2465/intake_verdict.py: `T2466_VERDICT PASS|FAIL ...` in results/<run>/verdict.md.
# Knobs: CELLS PRIOR_RES EXTRA_GB (60) SKIP_BUILD PORT (18466) MTP_BLOCKS (10)
#        DECODE_CTX (1024,8192,32768) REF_CTX (1024,8192,32768) REF_VENV STALL_S (1800).
# Every failure prints `BLOCKER:`; the job ends with JOB_PASS (every step ran; the verdict is in
# T2466_VERDICT) or JOB_FAIL. Watchdogs are stall detectors only, never wall-clock cuts.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-2466
RUN_ID=${RUN_ID:?RUN_ID unset}
SRC=${SRC:?SRC unset}
COMMIT=${COMMIT:?COMMIT unset}
PKG=$SRC/phase3-binary
TOOLS=$SRC/scripts/lab/2465
RES=$LAB/results/$RUN_ID
FIX=$LAB/fixtures
STORE="$HOME/Library/Application Support/macprovider/models"
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-2466
BIN=$PKG/$BUILD/release
PORT=${PORT:-18466}
EXTRA_GB=${EXTRA_GB:-60}
STALL_S=${STALL_S:-1800}
CELLS=${CELLS:-decode aggregate parity reference mtp quality}
MTP_BLOCKS=${MTP_BLOCKS:-10}
DECODE_CTX=${DECODE_CTX:-1024,8192,32768}
REF_CTX=${REF_CTX:-1024,8192,32768}
REF_VENV=${REF_VENV:-$HOME/venvs/ref-omlx}
SAGE_REPO=Hygaard/Sage-S2.1-Flash-oQ4e-mtp
# Pinned 2026-11-22 from https://huggingface.co/api/models/Hygaard/Sage-S2.1-Flash-oQ4e-mtp (sha);
# the tree at this revision: 71 files, 186593494737 bytes (projectors/ included).
SAGE_REV=a972e256db2553562bd718e677d100089aca5fce
SAGE_BYTES=186593494737
SAGE_FILES=71
SAGE_DIR=$LAB/models/Sage-S2.1-Flash-oQ4e-mtp@$SAGE_REV
SAGE_GB=$(( (SAGE_BYTES + 1073741823) / 1073741824 ))
GLM_KEY=zai-org/glm-5.3-flash
GLM_SHA=7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9
INC=glm53 CAND=sage
RUN_SLUG=t2466-$(echo "$RUN_ID" | tr '[:upper:]' '[:lower:]')
FAILED=0
SERVE_PID=""
log() { echo "$(date '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; FAILED=1; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
cli() { (cd "$BIN" && ./macprovider-cli "$@"); }
# present_bytes DIR: bytes of the files already downloaded (the .cache metadata excluded).
present_bytes() { [ -d "$1" ] || { echo 0; return; }; find "$1" -path "$1/.cache" -prune -o -type f -print0 | xargs -0 stat -f '%z' 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
case "$MTP_BLOCKS" in [2-9]|1[0-9]|20) ;; *) die "MTP_BLOCKS must be 2..20" 64 ;; esac
echo "$COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "COMMIT must be the 40-hex campaign commit" 64

stop_serve() {
  [ -n "$SERVE_PID" ] || return 0
  if kill -0 "$SERVE_PID" 2>/dev/null; then
    kill -TERM "$SERVE_PID" 2>/dev/null
    for _ in $(seq 1 120); do kill -0 "$SERVE_PID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$SERVE_PID" 2>/dev/null
  fi
  wait "$SERVE_PID" 2>/dev/null
  SERVE_PID=""
}
trap stop_serve EXIT
mkdir -p "$RES" "$LAB/models"
log "JOB_START run=$RUN_ID commit=$COMMIT cells=\"$CELLS\" sage_rev=$SAGE_REV sage_gb=$SAGE_GB extra_gb=$EXTRA_GB mtp_blocks=$MTP_BLOCKS port=$PORT"

# 1. Preflight.
listening 8080 && die "a server listens on :8080; the Studio is not paused" 3
listening 8000 && die "a server listens on :8000; the FLOP miner backend is not paused" 3
listening "$PORT" && die "port $PORT is busy" 3
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
launchctl list 2>/dev/null | grep -q 'com\.flop\.' && die "a com.flop LaunchAgent is loaded (miner not paused)" 3
pgrep -f "[c]om.apple.Virtualization.VirtualMachine|[l]imactl|[m]lx_service" >/dev/null 2>&1 && die "a miner VM or backend process runs" 3
for f in "$PKG/Package.swift" "$TOOLS/quality.py" "$TOOLS/intake_verdict.py" "$TOOLS/mtp_policy.py" "$TOOLS/snapshot_id.py" \
         "$TOOLS/quality_rubric_v1.json" "$SRC/scripts/native_mtp_r015_analyze.py" "$SRC/scripts/lab/cb-studio/glm53_bench_vlm.py" \
         "$SRC/scripts/lab/cb-studio/glm53_oracle_json.py" "$SRC/scripts/revenue_benchmark_workload.py" "$SRC/scripts/publish-model-mirror.py"; do
  [ -f "$f" ] || die "source tree incomplete: no $f" 11
done
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
METALLIB_SHA=$(shasum -a 256 "$METALLIB" | cut -d' ' -f1)
SIGNED_METALLIB=$(/usr/bin/python3 -I -c 'import json,sys
e=[e for e in json.load(open(sys.argv[1]))["entries"] if e.get("model_key")==sys.argv[2] and e.get("artifact_hash")==sys.argv[3]]
print(e[0]["metallib_sha256"] if len(e)==1 else "")' "$PKG/catalog/autotune/native-mtp-admission.json" "$GLM_KEY" "$GLM_SHA")
log "METALLIB sha256=$METALLIB_SHA signed_native_mtp_entry=$SIGNED_METALLIB"
[ "$METALLIB_SHA" = "$SIGNED_METALLIB" ] || die "metallib $METALLIB_SHA is not the signed native-MTP entry's $SIGNED_METALLIB" 14
GLM_DIR=""
for d in "$STORE"/Jundot--GLM-5.3-Flash-oQ4e-mtp/*/"$GLM_SHA"; do [ -f "$d/config.json" ] && GLM_DIR=$d; done
[ -n "$GLM_DIR" ] || die "no durable GLM-5.3-Flash snapshot $GLM_SHA in the provider store" 11
[ -x "$REF_VENV/bin/python" ] || die "no reference venv at $REF_VENV" 11
REF_VERSIONS=$("$REF_VENV/bin/python" -I -B -c 'import importlib.metadata as m; print(" ".join(p+"="+m.version(p) for p in ("mlx","mlx-vlm","mlx-lm","huggingface_hub","numpy")))') \
  || die "the reference venv lacks mlx / mlx-vlm / mlx-lm / huggingface_hub / numpy" 11
log "INPUTS glm=$GLM_DIR ref_venv=$REF_VENV $REF_VERSIONS"

# 2. Snapshot. scripts/lab/2466/fetch-sage.sh downloads and hash-verifies it (the first window
# ran on an unverified directory: provider preflight_hash mismatch); this job only checks the marker.
[ "$(cat "$SAGE_DIR.verified" 2>/dev/null)" = "$SAGE_REPO $SAGE_REV" ] \
  || die "Sage snapshot $SAGE_DIR is not hash-verified: run scripts/lab/2466/fetch-sage.sh first" 11
have=$(present_bytes "$SAGE_DIR")
files=$(find "$SAGE_DIR" -path "$SAGE_DIR/.cache" -prune -o -type f -print | grep -c .)
log "SNAPSHOT_VERIFIED bytes=$have files=$files (pinned $SAGE_BYTES / $SAGE_FILES)"
[ "$have" = "$SAGE_BYTES" ] && [ "$files" = "$SAGE_FILES" ] || die "Sage snapshot is not the pinned tree: $have bytes, $files files" 12
# `hf download --local-dir` leaves .cache/huggingface/ metadata in the snapshot. snapshot_id.py
# skips it, but the provider's artifact hash (ModelArtifactVerifier.inspectCanonicalArtifact)
# counts every file, so a serve of this directory failed preflight_hash. Drop it.
rm -rf -- "${SAGE_DIR:?}/.cache"

# 3. Disk gate for the window itself.
fg=$(free_gb)
log "DISK free_gb=$fg window_needs_gb=$((SAGE_GB + EXTRA_GB))"
[ "${fg:-0}" -ge $((SAGE_GB + EXTRA_GB)) ] || die "only ${fg} GB free; the window needs model ${SAGE_GB} + ${EXTRA_GB} GB (#2468 whole-model native-MTP capture)" 13

# 4. Build.
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD_START lab-harness release"
  (cd "$PKG" && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD" -Xswiftc -DMACPROVIDER_LAB_HARNESS) \
    > "$RES/build.log" 2>&1 || die "release build failed: $(grep -m3 'error:' "$RES/build.log" | tr '\n' ' ' | cut -c1-400)" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no lab-harness binary at $BIN" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" > "$RES/identity.sha256"
FORK=$(sed -n 's/.*static let mlxSwiftLMRevision = "\([0-9a-f]*\)".*/\1/p' "$PKG/Sources/macprovider-cli/KVConversationColdTierAdapter.swift" | head -n 1)
DIGEST=$(/usr/bin/python3 -I "$SRC/scripts/decode_path_digest.py" 2>/dev/null | tail -n 1)
log "BUILD_DONE $("$BIN/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity.sha256" | head -n 1) mlx_swift_lm=$FORK decode_path_digest=$DIGEST"

# 5. Identities and fixtures.
SAGE_SHA=$(/usr/bin/python3 -I "$TOOLS/snapshot_id.py" "$SAGE_DIR" | cut -d' ' -f1)
echo "$SAGE_SHA" | grep -Eq '^[0-9a-f]{64}$' || die "Sage snapshot identity failed" 11
GLM_TOK=$(shasum -a 256 "$GLM_DIR/tokenizer.json" | cut -d' ' -f1)
SAGE_TOK=$(shasum -a 256 "$SAGE_DIR/tokenizer.json" | cut -d' ' -f1)
COMPAT=$(/usr/bin/python3 -I - "$SAGE_DIR" "$GLM_DIR" <<'PY'
import json, sys
def cfg(d):
    c = json.load(open(d + "/config.json"))
    return c.get("text_config", c), c
(st, s), (gt, g) = (cfg(x) for x in sys.argv[1:3])
keys = ("model_type", "hidden_size", "vocab_size", "num_hidden_layers", "num_nextn_predict_layers")
diff = [f"{k}:{st.get(k, s.get(k))}!={gt.get(k, g.get(k))}" for k in keys if st.get(k, s.get(k)) != gt.get(k, g.get(k))]
print("sage_vs_glm=" + (",".join(diff) or "same"), "sage_model_type=%s" % s.get("model_type"))
PY
)
log "IDENTITY sage=$SAGE_SHA glm=$GLM_SHA tokenizer sage=$SAGE_TOK glm=$GLM_TOK $COMPAT"
fixture() {  # fixture LABEL TARGET_DIR
  rm -rf -- "${FIX:?}/$1" && mkdir -p "$FIX/$1" && /bin/cp -c -R -L "$2" "$FIX/$1/target" && rm -rf -- "$FIX/$1/target/.cache"
}
fixture "$INC" "$GLM_DIR" || die "GLM fixture clone failed" 11
fixture "$CAND" "$SAGE_DIR" || die "Sage fixture clone failed" 11
log "FIXTURES $FIX/{$INC,$CAND}/target free_gb=$(free_gb)"
model_dir() { [ "$1" = "$INC" ] && echo "$GLM_DIR" || echo "$SAGE_DIR"; }

# 6. Cells.
cell_decode() {
  mkdir -p "$RES/decode"
  local m ctx rc
  for ctx in ${DECODE_CTX//,/ }; do
    for m in $INC $CAND; do
      log "CELL_START decode $m ctx=$ctx"
      cli decode-bench --model "$(model_dir "$m")" --prefill-tokens "$ctx" --decode-tokens 256 --runs 5 \
        --output "$RES/decode/$m-$ctx.json" > "$RES/decode/$m-$ctx.out" 2> "$RES/decode/$m-$ctx.err"
      rc=$?
      log "CELL_DONE decode $m ctx=$ctx rc=$rc $(grep -o 'decode_tps_p50=[^ ]*\|prefill_tps_p50=[^ ]*' "$RES/decode/$m-$ctx.err" | tr '\n' ' ')"
      [ $rc = 0 ] || blocker "decode $m $ctx rc=$rc: $(tail -n 2 "$RES/decode/$m-$ctx.err" | tr '\n' ' ' | cut -c1-300)"
    done
  done
}
cell_aggregate() {
  mkdir -p "$RES/aggregate"
  local m ctx rc
  for ctx in 1024 8192 msb03; do
    for m in $INC $CAND; do
      log "CELL_START aggregate $m $ctx"
      if [ "$ctx" = msb03 ]; then
        cli msb-throughput --model "$(model_dir "$m")" --engine scheduler --scenario msb03 --rows 4 --decode-tokens 256 --runs 5 \
          --output "$RES/aggregate/$m-msb03.json" > "$RES/aggregate/$m-msb03.out" 2> "$RES/aggregate/$m-msb03.err"
      else
        cli msb-throughput --model "$(model_dir "$m")" --engine scheduler --rows 4 --prompt-tokens "$ctx" --decode-tokens 256 --runs 5 \
          --output "$RES/aggregate/$m-$ctx.json" > "$RES/aggregate/$m-$ctx.out" 2> "$RES/aggregate/$m-$ctx.err"
      fi
      rc=$?
      log "CELL_DONE aggregate $m $ctx rc=$rc $(grep -o '"\(aggregateTPSp50\|makespanVsSerial\|aggregateVsProductionSerial\)" *: *[0-9.]*' "$RES/aggregate/$m-$ctx.json" 2>/dev/null | tr '\n' ' ')"
      [ $rc = 0 ] || blocker "aggregate $m $ctx rc=$rc: $(tail -n 2 "$RES/aggregate/$m-$ctx.err" | tr '\n' ' ' | cut -c1-300)"
    done
  done
}
cell_parity() {
  mkdir -p "$RES/parity"
  local m rc
  for m in $INC $CAND; do
    log "CELL_START parity $m"
    cli msb-throughput --model "$(model_dir "$m")" --engine scheduler --scenario parity --rows 4 --prompt-tokens 1024 \
      --parity-tokens 256 --output "$RES/parity/$m.json" > "$RES/parity/$m.out" 2> "$RES/parity/$m.err"
    rc=$?
    log "CELL_DONE parity $m rc=$rc $(grep -o '"pass" *: *[a-z]*' "$RES/parity/$m.json" 2>/dev/null | head -n 1)"
    [ $rc = 0 ] || blocker "parity $m rc=$rc: $(tail -n 2 "$RES/parity/$m.err" | tr '\n' ' ' | cut -c1-300)"
  done
}
VENDOR_FLAG=()
cell_reference() {
  local m d rc args f
  for m in $INC $CAND; do
    d=$RES/ref/$m; mkdir -p "$d"
    log "CELL_START reference-oracle $m contexts=$REF_CTX"
    "$REF_VENV/bin/python" -I -B "$SRC/scripts/lab/cb-studio/glm53_bench_vlm.py" "$(model_dir "$m")" "$d" --contexts "$REF_CTX" --decode 256 \
      > "$d/oracle.out" 2> "$d/oracle.err"
    rc=$?
    if [ $rc != 0 ]; then
      log "REFERENCE_RETRY $m with --omlx-vendor (stock mlx-vlm: $(tail -n 1 "$d/oracle.err" | cut -c1-200))"
      "$REF_VENV/bin/python" -I -B "$SRC/scripts/lab/cb-studio/glm53_bench_vlm.py" "$(model_dir "$m")" "$d" --contexts "$REF_CTX" --decode 256 \
        --omlx-vendor > "$d/oracle.out" 2> "$d/oracle-vendor.err"
      rc=$?
      [ $rc = 0 ] && VENDOR_FLAG=(--omlx-vendor)
    fi
    log "CELL_DONE reference-oracle $m rc=$rc lane=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("lane"))' "$d/speed.json" 2>/dev/null)"
    [ $rc = 0 ] || { blocker "reference oracle $m rc=$rc: $(tail -n 2 "$d/oracle-vendor.err" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"; continue; }
    args=()
    for f in "$d"/oracle_*.npz; do
      "$REF_VENV/bin/python" -I -B "$SRC/scripts/lab/cb-studio/glm53_oracle_json.py" "$f" > /dev/null 2>> "$d/oracle.err" \
        || { blocker "oracle json $f"; continue 2; }
      args+=(--oracle "${f%.npz}.json")
    done
    log "CELL_START reference-parity $m"
    cli glm-parity --model-dir "$(model_dir "$m")" "${args[@]}" --steps 256 --prefill-step-size 2048 --mlx-cache-limit-mb 2048 \
      --output "$d/glm-parity.json" > "$d/glm-parity.out" 2> "$d/glm-parity.err"
    rc=$?
    log "CELL_DONE reference-parity $m rc=$rc $(grep -o 'first_divergence=[^ ]* top1_first16=[^ ]*' "$d/glm-parity.err" | tr '\n' ' ')"
    [ $rc = 0 ] || blocker "glm-parity $m rc=$rc: $(tail -n 2 "$d/glm-parity.err" | tr '\n' ' ' | cut -c1-300)"
  done
}
# mtp_model LABEL MODEL_ID TARGET_SHA TOKENIZER_SHA: exploratory s1 cells, embedded MTP layer.
mtp_model() {
  local m=$1 mid=$2 tsha=$3 tok=$4 d=$RES/mtp/$1 i err rc ok=1 cell p o
  mkdir -p "$d"
  /usr/bin/python3 -I "$TOOLS/mtp_policy.py" write "$d/policy.json" --model-id "$mid" --target-sha "$tsha" \
    --mtp-sha "$tsha" --tokenizer-sha "$tok" --qualified-slots 4 --prompts 1536,4096 --outputs 128,512 \
    --blocks "$MTP_BLOCKS" --seed 20261122 --commit "$COMMIT" --fork "$FORK" --hw "$(sysctl -n hw.model)" \
    --os-build "$(sysctl -n kern.osversion)" --xcode unknown --swift "$(/usr/bin/xcrun swift --version 2>/dev/null | head -n 1)" \
    || { blocker "mtp $m: policy generation failed"; return 1; }
  bench() { (cd "$BIN" && env MACPROVIDER_NATIVE_MTP_E2E=1 ./macprovider-cli native-mtp-bench --root "$FIX/$m" --model-id "$mid" \
    --policy "$d/policy.json" --provider-commit "$COMMIT" "$@"); }
  for i in 1 2 3 4 5 6 7 8; do
    bench --out "$d/validate.jsonl" --validate-policy-only --identity-cache "$LAB/mtp-identity-cache.json" \
      > "$d/validate.out" 2> "$d/validate.err" && break
    err=$(cat "$d/validate.out" "$d/validate.err")
    /usr/bin/python3 -I "$TOOLS/mtp_policy.py" fix "$d/policy.json" "$err" \
      || { blocker "mtp $m: native-mtp-bench refuses the policy: $(echo "$err" | tr '\n' ' ' | cut -c1-400)"; return 1; }
    [ "$i" = 8 ] && { blocker "mtp $m: policy still refused after 8 environment fixes"; return 1; }
  done
  shasum -a 256 "$d/policy.json" >> "$RES/identity.sha256"
  log "MTP_VALIDATED $m policy_sha256=$(shasum -a 256 "$d/policy.json" | cut -c1-16)"
  rm -f "$d/bench.jsonl"
  for p in 1536 4096; do
    for o in 128 512; do
      cell=s1-p$p-o$o
      log "MTP_CELL_START $m $cell"
      bench --out "$d/bench.jsonl" --only-cell "$cell" --phase matrix > "$d/$cell.out" 2> "$d/$cell.log"
      rc=$?
      log "MTP_CELL_DONE $m $cell rc=$rc records=$(wc -l < "$d/bench.jsonl" 2>/dev/null | tr -d ' ')"
      [ $rc = 0 ] || { blocker "mtp $m $cell rc=$rc: $(tail -n 2 "$d/$cell.log" | tr '\n' ' ' | cut -c1-300)"; ok=0; }
    done
  done
  /usr/bin/python3 -I "$SRC/scripts/native_mtp_r015_analyze.py" "$d/bench.jsonl" "$d/policy.json" > "$d/analysis.json" 2> "$d/analysis.err"
  /usr/bin/python3 -I "$SRC/scripts/native_mtp_r015_analyze.py" "$d/bench.jsonl" "$d/policy.json" --format markdown > "$d/analysis.md" 2>> "$d/analysis.err"
  log "MTP_DONE $m analyzer=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall_status"))' "$d/analysis.json" 2>/dev/null)"
  sed "s/^/MTP_TABLE $m /" "$d/analysis.md" 2>/dev/null
  [ $ok = 1 ]
}
cell_mtp() {
  mtp_model "$INC" "$GLM_KEY" "$GLM_SHA" "$GLM_TOK"
  mtp_model "$CAND" "$SAGE_REPO" "$SAGE_SHA" "$SAGE_TOK"
}

model_loaded() {
  curl -s --max-time 3 "http://127.0.0.1:$PORT/v1/status" | /usr/bin/python3 -I -c \
    'import json,sys; sys.exit(0 if json.load(sys.stdin).get("model_loaded") is True else 1)' 2>/dev/null
}
wait_ready() {
  local last="" since now cur
  since=$(date +%s)
  until model_loaded; do
    kill -0 "$SERVE_PID" 2>/dev/null || return 5
    cur=$(stat -f '%m %z' "$1" 2>/dev/null); now=$(date +%s)
    if [ "$cur" != "$last" ]; then last=$cur; since=$now; fi
    [ $((now - since)) -lt "$STALL_S" ] || return 4
    sleep 5
  done
}
serve_quality() {  # serve_quality LABEL MODEL_ID DIR SHA
  local m=$1 mid=$2 dir=$3 sha=$4 s=$RES/quality/$1-serve rc
  mkdir -p "$s/home" "$s/tmp"
  {
    printf 'model: "%s"\n' "$mid"
    printf 'model_artifact_path: "%s"\n' "$dir"
    printf 'model_artifact_sha256: %s\n' "$sha"
    printf 'port: %s\nctl_socket_path: "%s/tmp/ctl.sock"\ncredential_store: protected_file\n' "$PORT" "$s"
    printf 'native_mtp_mode: off\ncontinuous_batching: off\n'
  } > "$s/config.yaml"
  log "QUALITY_SERVE_START $m model=$mid free_gb=$(free_gb)"
  ( export CFFIXED_USER_HOME=$s/home TMPDIR=$s/tmp/ MACPROVIDER_LIFECYCLE_ROOT=$s/home/lifecycle \
      MACPROVIDER_CTL_SOCKET_PATH=$s/tmp/ctl.sock MACPROVIDER_SWITCH_STATE_PATH=$s/tmp/last-switch.ts \
      MACPROVIDER_WATCHDOG_STATE_DIR=$s/home/watchdog MACPROVIDER_AUTO_UPDATE_ENABLED=false
    cd "$BIN" && exec ./macprovider-cli serve --config "$s/config.yaml" --no-join > "$s/serve.out" 2> "$s/serve.err" < /dev/null ) &
  SERVE_PID=$!
  wait_ready "$s/serve.err"; rc=$?
  if [ $rc != 0 ]; then
    log "QUALITY_SERVE_UNAVAILABLE $m rc=$rc (5 exited, 4 stalled): $(tail -n 3 "$s/serve.err" | tr '\n' ' ' | cut -c1-300)"
    stop_serve; return 1
  fi
  /usr/bin/python3 -I "$TOOLS/quality.py" serve --port "$PORT" --model "$mid" --label "$m" --run-id "$RUN_SLUG" \
    --out "$RES/quality/$m-raw.jsonl" > "$RES/quality/$m.log" 2>&1; rc=$?
  grep '^QUALITY_REQ ' "$RES/quality/$m.log"
  stop_serve
  for _ in $(seq 1 60); do listening "$PORT" || break; sleep 1; done
  log "QUALITY_SERVE_END $m rc=$rc free_gb=$(free_gb)"
  return $rc
}
ref_quality() {  # ref_quality LABEL DIR
  log "QUALITY_REFERENCE_START $1"
  "$REF_VENV/bin/python" -I -B "$TOOLS/quality.py" reference --model-dir "$2" --loader mlx-vlm ${VENDOR_FLAG[@]+"${VENDOR_FLAG[@]}"} \
    --label "$1" --run-id "$RUN_SLUG" --out "$RES/quality/$1-raw.jsonl" > "$RES/quality/$1.log" 2>&1 \
    || blocker "reference quality $1: $(tail -n 2 "$RES/quality/$1.log" | tr '\n' ' ' | cut -c1-300)"
  grep '^QUALITY_REQ ' "$RES/quality/$1.log"
}
cell_quality() {
  mkdir -p "$RES/quality"
  local path=serve m
  serve_quality "$INC" "$GLM_KEY" "$GLM_DIR" "$GLM_SHA" || path=reference
  [ $path = serve ] && { serve_quality "$CAND" "$SAGE_REPO" "$SAGE_DIR" "$SAGE_SHA" || path=reference; }
  if [ $path = reference ]; then
    log "QUALITY_PATH reference (a lab serve did not answer all nine; both models run the mlx-vlm reference)"
    ref_quality "$INC" "$GLM_DIR"; ref_quality "$CAND" "$SAGE_DIR"
  fi
  for m in $INC $CAND; do
    /usr/bin/python3 -I "$TOOLS/quality.py" score --raw "$RES/quality/$m-raw.jsonl" --rubric "$TOOLS/quality_rubric_v1.json" \
      --out "$RES/quality/$m-score.json" > "$RES/quality/$m-score.log" 2>&1 || blocker "quality score $m failed"
    grep -E '^QUALITY(_CASE)? ' "$RES/quality/$m-score.log"
  done
}

for c in $CELLS; do
  case "$c" in
    decode|aggregate|parity|reference|mtp|quality) log "CELLS_START $c free_gb=$(free_gb)"; "cell_$c"; log "CELLS_DONE $c" ;;
    *) blocker "unknown cell $c" ;;
  esac
done

# 7. Verdict. PRIOR_RES names an earlier run's results directory on this Studio; a cell this run
# skipped is taken from it (AGENTS.md rule 2: reuse evidence when no decode-path line changed;
# the job's BUILD_DONE decode_path_digest of both runs must match, which the log records).
if [ -n "${PRIOR_RES:-}" ]; then
  [ -d "$PRIOR_RES" ] || blocker "PRIOR_RES $PRIOR_RES is not a directory"
  for c in decode aggregate parity ref mtp quality; do
    if [ ! -d "$RES/$c" ] && [ -d "$PRIOR_RES/$c" ]; then
      /bin/cp -R "$PRIOR_RES/$c" "$RES/$c" && log "REUSED $c from $PRIOR_RES"
    fi
  done
fi
/usr/bin/python3 -I "$TOOLS/intake_verdict.py" --issue 2466 --res "$RES" --incumbent "$INC" --candidate "$CAND" \
  --json "$RES/verdict.json" > "$RES/verdict.md" 2>&1
vrc=$?
cat "$RES/verdict.md"
[ "$vrc" -le 1 ] || blocker "intake_verdict.py rc=$vrc (unusable input)"
rm -rf -- "${FIX:?}"
[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
