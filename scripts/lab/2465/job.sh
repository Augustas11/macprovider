#!/bin/bash
# Runs ON THE STUDIO, started detached by scratchpad/windows/window-2465.sh, which has already
# paused live, the runner's Studio target and the FLOP miner and holds the Studio GPU lock. This
# job never pauses, restores or restarts any of them; it refuses to start while anything still runs.
#
# #2465 catalog intake: DaisyRose-27B (mlx-community/DaisyRose-27B-4bit @ 895983ea, qwen3_5, affine
# 4-bit/64, no MTP tensors) against the qwen/qwen3.8-27b row (mlx-community/Qwen3.8-27B-4bit, store
# snapshot 8a8786e9, head mlx-community/Qwen3.8-27B-MTP-4bit 25d2e7e3). Every cell runs the
# incumbent first, then the candidate, back to back; one model is resident at a time (each cell is
# its own process).
#
# The Qwen MTP head on DaisyRose: native-mtp-bench takes a fixture root with target/ and mtp/
# (NativeMTPBenchFixtureLayout; mtp/ unless the target embeds its MTP layer). Without signed
# journey inputs it builds and validates a lab-only admission from the observed pair
# (makeAndValidateAdmission: format and mtp_num_hidden_layers must agree). The candidate root is
# target/ = APFS clone of DaisyRose, mtp/ = APFS clone of the incumbent's Qwen3.8-27B-MTP-4bit head.
# `serve` cannot do this: its native MTP needs a signed admission bound to the target hash.
#
# Steps:
#  1. preflight: nothing on :8080/:8000/:$PORT, no live agent, serve, FLOP agent or VM process;
#     free disk >= MIN_FREE_GB; inputs present; the metallib is the signed native-MTP entry's;
#  2. lab-harness release build (-DMACPROVIDER_LAB_HARNESS) in $SRC/phase3-binary/.build-lab-2465;
#  3. identities (snapshot-manifest.v1) and fixtures ~/lab-2465/fixtures/<label>/{target,mtp};
#  4. cells (CELLS, default "decode parity reference mtp quality"):
#     decode     decode-bench --prefill-tokens 1024/8192/32768 --decode-tokens 256 --runs 5;
#     parity     msb-throughput --engine scheduler --scenario parity --rows 4 --prompt-tokens 1024
#                --parity-tokens 256;
#     reference  oracle_mlxlm.py in VENV_LM (read only; python -I -B; see VENV_LM below) at 1024/8192/32768, 256
#                greedy tokens, then glm53_oracle_json.py and glm-parity --steps 256
#                --prefill-step-size 2048 --mlx-cache-limit-mb 2048;
#     mtp        native-mtp-bench, then scripts/native_mtp_r015_analyze.py. Candidate: the formal
#                SPEC-048 R015 matrix in the shape of the signed qwen3.8-27b policy (prompts
#                1536/4096/32768, outputs 128/512, MTP_BLOCKS 12, single_token_identical_pair,
#                gated s2/s4 at p1536-o512, 1800 s sustained on s4-p1536-o512). Incumbent
#                (QWEN_MTP): s1 (default) = the same s1 cells at 1536/4096 in this window, an
#                exploratory policy, for same-build acceptance; formal = its full matrix too;
#                reuse = none (compare with docs/evidence/qwen27b-mtp-cap-2026-11-20/qwen38);
#     quality    quality.py on the coding workload against a loopback `serve --no-join`
#                (native MTP off, CB off: greedy output is path-independent); if the candidate's
#                serve does not come up, both models run quality.py reference instead;
#  5. intake_verdict.py: `T2465_VERDICT PASS|FAIL ...` in results/<run>/verdict.md.
# Knobs: CELLS MIN_FREE_GB (60) SKIP_BUILD PORT (18465) QWEN_MTP (s1) MTP_BLOCKS (12)
#        DECODE_CTX (1024,8192,32768) REF_CTX (1024,8192,32768) VENV_LM STALL_S (1800) DAISY_DIR.
# Every failure prints `BLOCKER:`; the job ends with JOB_PASS (every step ran; the verdict is in
# T2465_VERDICT) or JOB_FAIL. Watchdogs are stall detectors only, never wall-clock cuts.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-2465
RUN_ID=${RUN_ID:?RUN_ID unset}
SRC=${SRC:?SRC unset}
COMMIT=${COMMIT:?COMMIT unset}
PKG=$SRC/phase3-binary
HERE=$SRC/scripts/lab/2465
RES=$LAB/results/$RUN_ID
FIX=$LAB/fixtures
STORE="$HOME/Library/Application Support/macprovider/models"
HF="$HOME/.cache/huggingface/hub"
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-2465
BIN=$PKG/$BUILD/release
PORT=${PORT:-18465}
MIN_FREE_GB=${MIN_FREE_GB:-60}
STALL_S=${STALL_S:-1800}
CELLS=${CELLS:-decode parity reference mtp quality}
QWEN_MTP=${QWEN_MTP:-s1}
MTP_BLOCKS=${MTP_BLOCKS:-12}
DECODE_CTX=${DECODE_CTX:-1024,8192,32768}
REF_CTX=${REF_CTX:-1024,8192,32768}
# The mlx-lm reference venv (read only): the first that exists. ~/lab-ablit-perf/venv-lm-qwen4 was
# removed in the 2026-11-22 disk cleanup; ~/venvs/ref-lm-main has mlx 0.32.4 and mlx-lm with qwen3_5.
if [ -z "${VENV_LM:-}" ]; then
  for v in "$HOME/lab-ablit-perf/venv-lm-qwen4" "$HOME/venvs/ref-lm-main" "$HOME/venvs/ref-lm"; do
    [ -z "${VENV_LM:-}" ] && [ -x "$v/bin/python" ] && VENV_LM=$v
  done
fi
VENV_LM=${VENV_LM:-$HOME/venvs/ref-lm-main}
DAISY_DIR=${DAISY_DIR:-$LAB/models/DaisyRose-27B-4bit}
QWEN_KEY=qwen/qwen3.8-27b
QWEN_SHA=8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05
QWEN_MTP_SHA=25d2e7e3846c6a95201b13a0299eb65527b8146541af3b1eb626eaac95fefb30
DAISY_ID=mlx-community/DaisyRose-27B-4bit
INC=qwen38 CAND=daisy
RUN_SLUG=t2465-$(echo "$RUN_ID" | tr '[:upper:]' '[:lower:]')
FAILED=0
SERVE_PID=""
log() { echo "$(date '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; FAILED=1; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
cli() { (cd "$BIN" && ./macprovider-cli "$@"); }
case " $CELLS " in *" quality "*|*" mtp "*|*" decode "*|*" parity "*|*" reference "*) ;; *) die "CELLS names no known cell: $CELLS" 64 ;; esac
case "$QWEN_MTP" in s1|formal|reuse) ;; *) die "QWEN_MTP must be s1, formal or reuse" 64 ;; esac
case "$MTP_BLOCKS" in 1[0-9]|20) ;; *) die "MTP_BLOCKS must be 10..20 (formal R015)" 64 ;; esac
echo "$COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "COMMIT must be the 40-hex campaign commit" 64

stop_serve() {
  [ -n "$SERVE_PID" ] || return 0
  if kill -0 "$SERVE_PID" 2>/dev/null; then
    kill -TERM "$SERVE_PID" 2>/dev/null
    for _ in $(seq 1 60); do kill -0 "$SERVE_PID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$SERVE_PID" 2>/dev/null
  fi
  wait "$SERVE_PID" 2>/dev/null
  SERVE_PID=""
}
trap stop_serve EXIT
mkdir -p "$RES"
log "JOB_START run=$RUN_ID commit=$COMMIT cells=\"$CELLS\" qwen_mtp=$QWEN_MTP mtp_blocks=$MTP_BLOCKS decode_ctx=$DECODE_CTX ref_ctx=$REF_CTX port=$PORT"

# 1. Preflight.
listening 8080 && die "a server listens on :8080; the Studio is not paused" 3
listening 8000 && die "a server listens on :8000; the FLOP miner backend is not paused" 3
listening "$PORT" && die "port $PORT is busy" 3
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
launchctl list 2>/dev/null | grep -q 'com\.flop\.' && die "a com.flop LaunchAgent is loaded (miner not paused)" 3
pgrep -f "[c]om.apple.Virtualization.VirtualMachine|[l]imactl|[m]lx_service" >/dev/null 2>&1 && die "a miner VM or backend process runs" 3
fg=$(free_gb)
log "DISK free_gb=$fg min=$MIN_FREE_GB"
[ "${fg:-0}" -ge "$MIN_FREE_GB" ] || die "only ${fg} GB free; need $MIN_FREE_GB (build, fixtures are APFS clones)" 13
for f in "$PKG/Package.swift" "$HERE/oracle_mlxlm.py" "$HERE/quality.py" "$HERE/intake_verdict.py" "$HERE/mtp_policy.py" \
         "$HERE/snapshot_id.py" "$HERE/quality_rubric_v1.json" "$SRC/scripts/native_mtp_r015_analyze.py" \
         "$SRC/scripts/lab/cb-studio/glm53_oracle_json.py" "$SRC/scripts/revenue_benchmark_workload.py" \
         "$SRC/scripts/publish-model-mirror.py"; do
  [ -f "$f" ] || die "source tree incomplete: no $f" 11
done
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
METALLIB_SHA=$(shasum -a 256 "$METALLIB" | cut -d' ' -f1)
SIGNED_METALLIB=$(/usr/bin/python3 -I -c 'import json,sys
e=[e for e in json.load(open(sys.argv[1]))["entries"] if e.get("model_key")==sys.argv[2] and e.get("artifact_hash")==sys.argv[3]]
print(e[0]["metallib_sha256"] if len(e)==1 else "")' "$PKG/catalog/autotune/native-mtp-admission.json" "$QWEN_KEY" "$QWEN_SHA")
log "METALLIB sha256=$METALLIB_SHA signed_native_mtp_entry=$SIGNED_METALLIB"
[ "$METALLIB_SHA" = "$SIGNED_METALLIB" ] || die "metallib $METALLIB_SHA is not the signed native-MTP entry's $SIGNED_METALLIB" 14
QWEN_DIR=""
for d in "$STORE"/mlx-community--Qwen3.8-27B-4bit/*/"$QWEN_SHA"; do [ -f "$d/config.json" ] && QWEN_DIR=$d; done
[ -n "$QWEN_DIR" ] || die "no durable qwen3.8-27b snapshot $QWEN_SHA in the provider store" 11
HEAD_DIR=""
for d in "$STORE"/mlx-community--Qwen3.8-27B-MTP-4bit/*/"$QWEN_MTP_SHA" "$HF"/models--mlx-community--Qwen3.8-27B-MTP-4bit/snapshots/b643c01b6d3b094e325edb6ebd832e16c486c575; do
  [ -z "$HEAD_DIR" ] && [ -f "$d/config.json" ] && HEAD_DIR=$d
done
[ -n "$HEAD_DIR" ] || die "no Qwen3.8-27B-MTP-4bit head ($QWEN_MTP_SHA) in the store or the HF cache" 11
[ -f "$DAISY_DIR/config.json" ] || die "no DaisyRose snapshot at $DAISY_DIR" 11
[ -x "$VENV_LM/bin/python" ] || die "no reference venv at $VENV_LM" 11
REF_VERSIONS=$("$VENV_LM/bin/python" -I -B -c 'import importlib.metadata as m; print(" ".join(p+"="+m.version(p) for p in ("mlx","mlx-lm","numpy")))') \
  || die "the reference venv has no mlx / mlx-lm / numpy" 11
log "INPUTS qwen=$QWEN_DIR head=$HEAD_DIR daisy=$DAISY_DIR ref_venv=$VENV_LM $REF_VERSIONS"

# 2. Build.
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

# 3. Identities and fixtures (APFS clones; the store, the head and the download stay read only).
DAISY_SHA=$(/usr/bin/python3 -I "$HERE/snapshot_id.py" "$DAISY_DIR" | cut -d' ' -f1)
echo "$DAISY_SHA" | grep -Eq '^[0-9a-f]{64}$' || die "DaisyRose snapshot identity failed" 11
HEAD_SHA=$(/usr/bin/python3 -I "$HERE/snapshot_id.py" "$HEAD_DIR" | cut -d' ' -f1)
[ "$HEAD_SHA" = "$QWEN_MTP_SHA" ] || die "head identity $HEAD_SHA is not the signed $QWEN_MTP_SHA" 11
QWEN_TOK=$(shasum -a 256 "$QWEN_DIR/tokenizer.json" | cut -d' ' -f1)
DAISY_TOK=$(shasum -a 256 "$DAISY_DIR/tokenizer.json" | cut -d' ' -f1)
COMPAT=$(/usr/bin/python3 -I - "$DAISY_DIR" "$QWEN_DIR" "$HEAD_DIR" <<'PY'
import json, sys
def cfg(d):
    c = json.load(open(d + "/config.json"))
    return c.get("text_config", c), c
(dt, d), (qt, q), (ht, h) = (cfg(x) for x in sys.argv[1:4])
keys = ("model_type", "hidden_size", "vocab_size", "num_hidden_layers", "mtp_num_hidden_layers")
diff = [f"{k}:{dt.get(k)}!={qt.get(k)}" for k in keys if dt.get(k) != qt.get(k)]
print("daisy_vs_qwen=" + (",".join(diff) or "same"),
      "head_vocab=%s head_hidden=%s" % (ht.get("vocab_size"), ht.get("hidden_size")),
      "quant=%s/%s" % ((d.get("quantization") or {}).get("bits"), (d.get("quantization") or {}).get("group_size")))
PY
)
log "IDENTITY daisy=$DAISY_SHA head=$HEAD_SHA qwen=$QWEN_SHA tokenizer daisy=$DAISY_TOK qwen=$QWEN_TOK $COMPAT"
[ "$DAISY_TOK" = "$QWEN_TOK" ] || log "IDENTITY_NOTE DaisyRose tokenizer.json bytes differ from Qwen3.8-27B's; prompts are counted on each model's own tokenizer"
fixture() {  # fixture LABEL TARGET_DIR
  local root=$FIX/$1
  rm -rf -- "$root" && mkdir -p "$root" \
    && /bin/cp -c -R -L "$2" "$root/target" && /bin/cp -c -R -L "$HEAD_DIR" "$root/mtp" \
    && rm -rf -- "$root/target/.cache" "$root/mtp/.cache"
}
fixture "$INC" "$QWEN_DIR" || die "qwen fixture clone failed" 11
fixture "$CAND" "$DAISY_DIR" || die "daisy fixture clone failed" 11
log "FIXTURES $FIX/{$INC,$CAND}/{target,mtp} free_gb=$(free_gb)"
model_dir() { [ "$1" = "$INC" ] && echo "$QWEN_DIR" || echo "$DAISY_DIR"; }

# 4. Cells.
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
cell_reference() {
  local m d rc args f
  for m in $INC $CAND; do
    d=$RES/ref/$m; mkdir -p "$d"
    log "CELL_START reference-oracle $m contexts=$REF_CTX"
    "$VENV_LM/bin/python" -I -B "$HERE/oracle_mlxlm.py" "$(model_dir "$m")" "$d" --contexts "$REF_CTX" --decode 256 \
      > "$d/oracle.out" 2> "$d/oracle.err"
    rc=$?
    log "CELL_DONE reference-oracle $m rc=$rc $(grep -c '^ORACLE ' "$d/oracle.out") oracles"
    [ $rc = 0 ] || { blocker "reference oracle $m rc=$rc: $(tail -n 2 "$d/oracle.err" | tr '\n' ' ' | cut -c1-300)"; continue; }
    args=()
    for f in "$d"/oracle_*.npz; do
      "$VENV_LM/bin/python" -I -B "$SRC/scripts/lab/cb-studio/glm53_oracle_json.py" "$f" > /dev/null 2>> "$d/oracle.err" \
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
# mtp_model LABEL MODEL_ID TARGET_SHA TOKENIZER_SHA FORMAL(0|1) PROMPTS
mtp_model() {
  local m=$1 mid=$2 tsha=$3 tok=$4 formal=$5 prompts=$6 d=$RES/mtp/$1 i err rc ok=1 cell p o
  mkdir -p "$d"
  local fflag=()
  [ "$formal" = 1 ] && fflag=(--formal)
  /usr/bin/python3 -I "$HERE/mtp_policy.py" write "$d/policy.json" --model-id "$mid" --target-sha "$tsha" \
    --mtp-sha "$QWEN_MTP_SHA" --tokenizer-sha "$tok" --qualified-slots 4 --prompts "$prompts" --outputs 128,512 \
    --blocks "$MTP_BLOCKS" --seed 20261119 --commit "$COMMIT" --fork "$FORK" --hw "$(sysctl -n hw.model)" \
    --os-build "$(sysctl -n kern.osversion)" --xcode unknown --swift "$(/usr/bin/xcrun swift --version 2>/dev/null | head -n 1)" \
    --exclusion single_token_identical_pair ${fflag[@]+"${fflag[@]}"} \
    || { blocker "mtp $m: policy generation failed"; return 1; }
  bench() { (cd "$BIN" && env MACPROVIDER_NATIVE_MTP_E2E=1 ./macprovider-cli native-mtp-bench --root "$FIX/$m" --model-id "$mid" \
    --policy "$d/policy.json" --provider-commit "$COMMIT" "$@"); }
  for i in 1 2 3 4 5 6 7 8; do
    bench --out "$d/validate.jsonl" --validate-policy-only --identity-cache "$LAB/mtp-identity-cache.json" \
      > "$d/validate.out" 2> "$d/validate.err" && break
    err=$(cat "$d/validate.out" "$d/validate.err")
    /usr/bin/python3 -I "$HERE/mtp_policy.py" fix "$d/policy.json" "$err" \
      || { blocker "mtp $m: native-mtp-bench refuses the policy: $(echo "$err" | tr '\n' ' ' | cut -c1-400)"; return 1; }
    [ "$i" = 8 ] && { blocker "mtp $m: policy still refused after 8 environment fixes"; return 1; }
  done
  shasum -a 256 "$d/policy.json" >> "$RES/identity.sha256"
  log "MTP_VALIDATED $m formal=$formal policy_sha256=$(shasum -a 256 "$d/policy.json" | cut -c1-16)"
  rm -f "$d/bench.jsonl"
  local cells=()
  for p in ${prompts//,/ }; do for o in 128 512; do cells+=("s1-p$p-o$o"); done; done
  [ "$formal" = 1 ] && cells+=(s2-p1536-o512 s4-p1536-o512 sustained)
  for cell in "${cells[@]}"; do
    log "MTP_CELL_START $m $cell"
    if [ "$cell" = sustained ]; then bench --out "$d/bench.jsonl" --phase sustained > "$d/$cell.out" 2> "$d/$cell.log"
    else bench --out "$d/bench.jsonl" --only-cell "$cell" --phase matrix > "$d/$cell.out" 2> "$d/$cell.log"; fi
    rc=$?
    log "MTP_CELL_DONE $m $cell rc=$rc records=$(wc -l < "$d/bench.jsonl" 2>/dev/null | tr -d ' ')"
    [ $rc = 0 ] || { blocker "mtp $m $cell rc=$rc: $(tail -n 2 "$d/$cell.log" | tr '\n' ' ' | cut -c1-300)"; ok=0; break; }
  done
  /usr/bin/python3 -I "$SRC/scripts/native_mtp_r015_analyze.py" "$d/bench.jsonl" "$d/policy.json" > "$d/analysis.json" 2> "$d/analysis.err"
  /usr/bin/python3 -I "$SRC/scripts/native_mtp_r015_analyze.py" "$d/bench.jsonl" "$d/policy.json" --format markdown > "$d/analysis.md" 2>> "$d/analysis.err"
  log "MTP_DONE $m analyzer=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall_status"))' "$d/analysis.json" 2>/dev/null)"
  sed "s/^/MTP_TABLE $m /" "$d/analysis.md" 2>/dev/null
  [ $ok = 1 ]
}
cell_mtp() {
  case "$QWEN_MTP" in
    s1) mtp_model "$INC" "$QWEN_KEY" "$QWEN_SHA" "$QWEN_TOK" 0 1536,4096 ;;
    formal) mtp_model "$INC" "$QWEN_KEY" "$QWEN_SHA" "$QWEN_TOK" 1 1536,4096,32768 ;;
    reuse) log "MTP_REUSE $INC docs/evidence/qwen27b-mtp-cap-2026-11-20/qwen38 (no same-window incumbent run)" ;;
  esac
  mtp_model "$CAND" "$DAISY_ID" "$DAISY_SHA" "$DAISY_TOK" 1 1536,4096,32768
}

model_loaded() {
  curl -s --max-time 3 "http://127.0.0.1:$PORT/v1/status" | /usr/bin/python3 -I -c \
    'import json,sys; sys.exit(0 if json.load(sys.stdin).get("model_loaded") is True else 1)' 2>/dev/null
}
# wait_ready LOG: until the serve answers model_loaded; 5 when it exits, 4 when LOG stalls STALL_S.
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
# serve_quality LABEL MODEL_ID DIR SHA: 0 when the serve came up and all nine requests answered.
serve_quality() {
  local m=$1 mid=$2 dir=$3 sha=$4 s=$RES/quality/$1-serve rc
  mkdir -p "$s/home" "$s/tmp"
  {
    printf 'model: "%s"\n' "$mid"
    printf 'model_artifact_path: "%s"\n' "$dir"
    printf 'model_artifact_sha256: %s\n' "$sha"
    printf 'port: %s\nctl_socket_path: "%s/tmp/ctl.sock"\ncredential_store: protected_file\n' "$PORT" "$s"
    printf 'native_mtp_mode: off\ncontinuous_batching: off\n'
  } > "$s/config.yaml"
  log "QUALITY_SERVE_START $m model=$mid"
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
  /usr/bin/python3 -I "$HERE/quality.py" serve --port "$PORT" --model "$mid" --label "$m" --run-id "$RUN_SLUG" \
    --out "$RES/quality/$m-raw.jsonl" > "$RES/quality/$m.log" 2>&1; rc=$?
  grep '^QUALITY_REQ ' "$RES/quality/$m.log"
  stop_serve
  for _ in $(seq 1 60); do listening "$PORT" || break; sleep 1; done
  [ $rc = 0 ] || log "QUALITY_SERVE_REQUEST_FAILED $m: $(grep -v '^QUALITY_REQ ' "$RES/quality/$m.log" | tail -n 2 | tr '\n' ' ' | cut -c1-300)"
  return $rc
}
ref_quality() {  # ref_quality LABEL DIR
  log "QUALITY_REFERENCE_START $1"
  "$VENV_LM/bin/python" -I -B "$HERE/quality.py" reference --model-dir "$2" --loader mlx-lm --label "$1" --run-id "$RUN_SLUG" \
    --out "$RES/quality/$1-raw.jsonl" > "$RES/quality/$1.log" 2>&1 || blocker "reference quality $1: $(tail -n 2 "$RES/quality/$1.log" | tr '\n' ' ' | cut -c1-300)"
  grep '^QUALITY_REQ ' "$RES/quality/$1.log"
}
cell_quality() {
  mkdir -p "$RES/quality"
  local path=serve m
  serve_quality "$INC" "$QWEN_KEY" "$QWEN_DIR" "$QWEN_SHA" || path=reference
  [ $path = serve ] && { serve_quality "$CAND" "$DAISY_ID" "$DAISY_DIR" "$DAISY_SHA" || path=reference; }
  if [ $path = reference ]; then
    log "QUALITY_PATH reference (a lab serve did not answer all nine; both models run the mlx-lm reference)"
    ref_quality "$INC" "$QWEN_DIR"; ref_quality "$CAND" "$DAISY_DIR"
  fi
  for m in $INC $CAND; do
    /usr/bin/python3 -I "$HERE/quality.py" score --raw "$RES/quality/$m-raw.jsonl" --rubric "$HERE/quality_rubric_v1.json" \
      --out "$RES/quality/$m-score.json" > "$RES/quality/$m-score.log" 2>&1 || blocker "quality score $m failed"
    grep -E '^QUALITY(_CASE)? ' "$RES/quality/$m-score.log"
  done
}

for c in $CELLS; do
  case "$c" in
    decode|parity|reference|mtp|quality) log "CELLS_START $c free_gb=$(free_gb)"; "cell_$c"; log "CELLS_DONE $c" ;;
    *) blocker "unknown cell $c" ;;
  esac
done

# 5. Verdict.
/usr/bin/python3 -I "$HERE/intake_verdict.py" --issue 2465 --res "$RES" --incumbent "$INC" --candidate "$CAND" \
  --json "$RES/verdict.json" > "$RES/verdict.md" 2>&1
vrc=$?
cat "$RES/verdict.md"
[ "$vrc" -le 1 ] || blocker "intake_verdict.py rc=$vrc (unusable input)"
rm -rf -- "$FIX"
[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
