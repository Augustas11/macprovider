#!/bin/bash
# Runs ON THE STUDIO inside a paused Studio window, started detached by
# `JOB_SCRIPT=job-dsv4-abliterated.sh studio-ablit-perf.sh`. Swarm run #2409, cell
# "abliterated DeepSeek V4-Flash": an abliterated DeepSeek-V4-Flash-0731 in the layout the
# catalog serves (TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX), by splice, then its checks.
#
# Why a splice: TensorFold's artifact is a byte transplant of deepseek-ai/DeepSeek-V4-Flash-0731
# (fp4 e2m1 block-32 experts = MLX mxfp4 bytes, fp8 e4m3 128x128-block dense weights = MLX
# mxfp8 bytes with each block scale repeated per 32-group, everything else unchanged, same
# tensor names). prem-research/DeepSeek-V4-Flash-0731-abliterated keeps the original format
# and rewrote only the 20 shards of layers 17-36. So: base + the transplant of the tensors
# that changed. Same size, speed profile, CB behaviour and DSpark/MTP heads as the live row.
#
# Steps (every failure prints `BLOCKER:` and the job ends JOB_FAIL, nonzero):
#  1. lab-harness release build of ~/lab-ablit-perf/src (SKIP_BUILD=1 reuses it), metallib beside it;
#  2. the base: APFS clone of the provider-store snapshot into ~/lab-ablit-perf/models, verified
#     against the catalog snapshot-manifest hash; the reference venv (pinned as in
#     scripts/lab/dsv4/dsv4-reference-policy.json);
#  3. fetch: only prem-research's shards whose LFS sha256 differs from deepseek-ai's (~71.6 GB),
#     each checked against its LFS sha256;
#  4. splice (dsv4_abliterated_splice.py): APFS clone of the base, every tensor of the fetched
#     shards transplanted and compared with the base (a change outside the card's steered
#     modules fails), changed tensors written in place, every other tensor and file verified
#     byte-identical to the base, and the numeric check: each changed module dequantized with
#     mx.dequantize from our layout against the fp8/fp4 source, max abs error 0;
#  5. reference oracles on the abliterated weights at 1K and 8K: mlx-vlm
#     (dsv4_reference_bench.py, as for the base) and DeepSeek's QAT-off reference
#     (dsv4_tf_reference.py on the mlx-vlm prompts), the parity target of fork 10.9+;
#  6. dsv4-parity of the lab-harness build against both; gate on the DeepSeek reference:
#     first 16 top-1 exact and >= PARITY_MIN_MATCH (240) of 256 greedy tokens. On a gate failure
#     the same check runs on the base (its own reference oracles) to tell an abliteration
#     effect from a pre-existing gap;
#  7. refusal sanity: 20 harmful + 20 harmless prompts, base vs abliterated (mlx-vlm, greedy,
#     keyword classes);
#  8. provenance.json (catalog-row inputs) and the job.sh env line for the grid check;
#  9. only with DSV4_PUBLISH=1 (default off: it uploads), after JOB_PASS: publish_dsv4_abliterated.py
#     stages the artifact with a model card and uploads it to aug11/DeepSeek-V4-Flash-0731-MXFP4-MLX-abliterated
#     with the Studio's HF token, --expect-stage = provenance model_sha256, then checks every remote
#     file. A failure prints BLOCKER and PUBLISH_FAIL and exits 20 (the launcher reports a fail).
# Knobs: SKIP_BUILD, METALLIB, PARITY_MIN_MATCH, REFUSAL_DATA, KEEP_SOURCE (1 keeps the
# fetched source shards after a pass), DSV4_PUBLISH, DSV4_PUBLISH_ARGS (e.g. --dry-run or --private),
# RUN_ID, COMMIT.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
# The reference checks import deepseek_v4.py from the model folder; bytecode written there
# would change the artifact manifest after it was recorded (run 20261120T081620Z). -I ignores
# PYTHONDONTWRITEBYTECODE, so every "$PY" call also passes -B.
export PYTHONDONTWRITEBYTECODE=1
LAB=$HOME/lab-ablit-perf
JOB=$LAB/job
SRC=$LAB/src/phase3-binary
STORE="$HOME/Library/Application Support/macprovider/models"
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
RES=$LAB/results/$RUN_ID/dsv4-abliterated
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BIN=$SRC/.build-lab-harness/release
PARITY_MIN_MATCH=${PARITY_MIN_MATCH:-240}
REFUSAL_DATA=${REFUSAL_DATA:-$HOME/lab-2376/job/data}
BASE_ID=deepseek/deepseek-v4-flash
BASE_SHA256=58ee40d4c0bc436695d1d8d6a6cdfdb0326ec37f25e13ec98ea1d5c0878e732c
BASE=$LAB/models/DeepSeek-V4-Flash-0731-MXFP4-MLX
ABL=$LAB/models/DeepSeek-V4-Flash-0731-abliterated-MXFP4-MLX
SOURCE=$LAB/models/prem-research--DeepSeek-V4-Flash-0731-abliterated-457210de
VENV=$LAB/venv-dsv4
PY=$VENV/bin/python
CTXS=1024,8192
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
mkdir -p "$RES"

log "JOB_START dsv4-abliterated run=$RUN_ID commit=${COMMIT:-unknown}"
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
for f in dsv4/dsv4_abliterated_splice.py dsv4/dsv4_reference_bench.py dsv4/dsv4_tf_reference.py dsv4/dsv4_refusal_check.py \
  cb-studio/glm53_oracle_json.py minimax/publish_abliterated.py ablit-perf/publish_dsv4_abliterated.py; do
  [ -f "$JOB/$f" ] || die "missing job file $JOB/$f" 11
done
BASE_FROM=""
for d in "$STORE/TensorFold--DeepSeek-V4-Flash-0731-MXFP4-MLX"/*/"$BASE_SHA256"; do [ -f "$d/config.json" ] && BASE_FROM=$d; done
# Fallback: a plain download of the same revision left by another lab job (read-only input;
# the manifest check below decides whether it is the catalog artifact).
BASE_ALT=${DSV4_BASE_DIR:-$HOME/lab-upstream/dsv4/models/DeepSeek-V4-Flash-0731-MXFP4-MLX}
[ -n "$BASE_FROM" ] || { [ -f "$BASE_ALT/config.json" ] && BASE_FROM=$BASE_ALT; }
[ -n "$BASE_FROM" ] || [ -f "$BASE/config.json" ] || die "no DeepSeek V4-Flash snapshot in the provider store and none at $BASE" 11

manifest() {  # macprovider.snapshot-manifest.v1 of DIR, the catalog's model_sha256
  /usr/bin/python3 -I -c 'import sys,pathlib; sys.path.insert(0, sys.argv[1])
from publish_abliterated import snapshot_manifest_sha256 as m; print(m(pathlib.Path(sys.argv[2])))' "$JOB/minimax" "$1"
}

# 1. Build.
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD_START"
  (cd "$SRC" && nice -n 10 swift build -c release --product macprovider-cli --build-path .build-lab-harness \
    -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/build.log" 2>&1 || die "swift build failed: $(tail -n 3 "$RES/build.log" | tr '\n' ' ')" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no lab-harness binary at $BIN" 14
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" > "$RES/identity.sha256"
log "BUILD_DONE $("$BIN/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity.sha256" | head -n 1)"

# 2. Base clone (the store is only read) and the reference venv.
if [ -d "$BASE" ] && [ "$(manifest "$BASE" 2>/dev/null)" = "$BASE_SHA256" ]; then
  log "CLONE_OK base manifest=$BASE_SHA256 (existing)"
else
  [ -n "$BASE_FROM" ] || die "$BASE is not the catalog artifact and the store has no snapshot to clone" 11
  log "CLONE_START base from $BASE_FROM"
  rm -rf -- "$BASE" && mkdir -p "$(dirname "$BASE")" && /bin/cp -c -R "$BASE_FROM" "$BASE" || die "APFS clone of the base failed" 11
  rm -rf -- "$BASE/.cache"
  got=$(manifest "$BASE") || die "manifest of $BASE failed" 11
  [ "$got" = "$BASE_SHA256" ] || die "base clone manifest $got is not the catalog artifact $BASE_SHA256" 11
  log "CLONE_OK base manifest=$got"
fi
if ! "$PY" -c 'import mlx_vlm, numpy' >/dev/null 2>&1; then
  py312=$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)
  [ -x "$py312" ] || die "python3.12 not found for the reference venv" 12
  "$py312" -m venv "$VENV" && "$VENV/bin/pip" install -q mlx-vlm==0.7.10 mlx==0.32.4 > "$RES/venv.log" 2>&1 \
    || die "reference venv failed: $(tail -n 2 "$RES/venv.log" | tr '\n' ' ')" 12
fi
"$PY" -c 'import importlib.metadata as m
for p in ("mlx", "mlx-metal", "mlx-vlm", "numpy", "transformers"): print("REF_VERSION", p, m.version(p))' | tee "$RES/versions.txt"
grep -q 'REF_VERSION mlx-vlm 0.7.10' "$RES/versions.txt" && grep -q 'REF_VERSION mlx 0.32.4' "$RES/versions.txt" \
  || die "reference venv is not mlx-vlm 0.7.10 / mlx 0.32.4 (dsv4-reference-policy.json)" 12

# 3. Fetch the rewritten shards only.
log "FETCH_START"
"$PY" -B -I "$JOB/dsv4/dsv4_abliterated_splice.py" fetch --dest "$SOURCE" --out "$RES/fetch.json" 2>&1 | tee "$RES/fetch.log" | grep -E 'FETCH_PLAN|FETCH_DONE|BLOCKER'
[ "${PIPESTATUS[0]}" = 0 ] || die "fetch failed: $(grep BLOCKER "$RES/fetch.log" | tail -n 1)" 13

# 4. Splice into an APFS clone of the base, verify, numeric check.
log "SPLICE_START"
rm -rf -- "$ABL" && /bin/cp -c -R "$BASE" "$ABL" || die "APFS clone for the splice failed" 15
"$PY" -B -I "$JOB/dsv4/dsv4_abliterated_splice.py" splice --base "$BASE" --source "$SOURCE" --fetch "$RES/fetch.json" \
  --out "$ABL" --manifest "$RES/tensor-diff.json" --numeric --require-mlx 2>&1 | tee "$RES/splice.log" \
  | grep -E 'SPLICE_COMPARED|SPLICE_WRITTEN|SPLICE_VERIFIED|SPLICE_DONE|NUMERIC|BLOCKER'
[ "${PIPESTATUS[0]}" = 0 ] || { rm -rf -- "$ABL"; die "splice failed: $(grep BLOCKER "$RES/splice.log" | tail -n 1)" 15; }
ABL_SHA256=$(manifest "$ABL") || die "manifest of $ABL failed" 15
[ "$ABL_SHA256" != "$BASE_SHA256" ] || die "the spliced artifact equals the base" 15
[ "$(manifest "$BASE")" = "$BASE_SHA256" ] || die "the base clone changed during the splice" 15
log "SPLICE_ARTIFACT $ABL manifest=$ABL_SHA256 tensor_diff_sha256=$(shasum -a 256 "$RES/tensor-diff.json" | cut -d' ' -f1)"

# 5. Reference oracles on the abliterated weights (one model resident at a time).
oracles() {  # oracles MODEL_DIR OUTDIR: mlx-vlm and DeepSeek-reference oracles at $CTXS, plus their JSON
  local model=$1 out=$2 c
  rm -rf -- "$out" && mkdir -p "$out" || return 1
  log "ORACLE_VLM_START $model"
  "$PY" -B -I "$JOB/dsv4/dsv4_reference_bench.py" "$model" "$out/vlm" --oracle-contexts "$CTXS" --ttft-contexts "" --rows "" \
    > "$out/vlm.log" 2>&1 || { log "BLOCKER: mlx-vlm oracle failed: $(tail -n 2 "$out/vlm.log" | tr '\n' ' ')"; return 1; }
  log "ORACLE_REF_START $model"
  "$PY" -B -I "$JOB/dsv4/dsv4_tf_reference.py" oracle "$model" "$out/ref" --prompts "$out/vlm" --contexts "$CTXS" \
    > "$out/ref.log" 2>&1 || { log "BLOCKER: DeepSeek-reference oracle failed: $(tail -n 2 "$out/ref.log" | tr '\n' ' ')"; return 1; }
  for c in ${CTXS//,/ }; do
    cp "$out/vlm/oracle_$c.npz" "$out/vlm_$c.npz" && cp "$out/ref/oracle_$c.npz" "$out/ref_$c.npz" || return 1
    "$PY" -B -I "$JOB/cb-studio/glm53_oracle_json.py" "$out/vlm_$c.npz" > /dev/null \
      && "$PY" -B -I "$JOB/cb-studio/glm53_oracle_json.py" "$out/ref_$c.npz" > /dev/null || return 1
  done
  log "ORACLE_DONE $model ref_vs_vlm_greedy_equal=$("$PY" -B -I -c 'import json,sys
a,b=(json.load(open(p))["greedy"] for p in sys.argv[1:3]); print(sum(x==y for x,y in zip(a,b)), "/", len(a))' "$out/ref_1024.json" "$out/vlm_1024.json") (1K)"
}

# parity MODEL_DIR ORACLE_DIR OUT.json: dsv4-parity against all four oracles on one load.
parity() {
  local args=() c
  for c in ${CTXS//,/ }; do args+=(--oracle "$2/ref_$c.json" --oracle "$2/vlm_$c.json"); done
  log "PARITY_START $1"
  (cd "$BIN" && ./macprovider-cli dsv4-parity --model-dir "$1" "${args[@]}" --steps 256 --output "$3") \
    > "${3%.json}.stdout" 2> "${3%.json}.stderr" || { log "BLOCKER: dsv4-parity exit $?: $(tail -n 3 "${3%.json}.stderr" | tr '\n' ' ')"; return 1; }
  grep '^dsv4-parity: oracle=' "${3%.json}.stderr" | sed 's/^/PARITY_LINE /'
}

# parity_gate OUT.json: the DeepSeek-reference runs pass the gate.
parity_gate() {
  /usr/bin/python3 -I - "$1" "$PARITY_MIN_MATCH" <<'PY'
import json, sys
doc, need = json.load(open(sys.argv[1])), int(sys.argv[2])
bad, seen = [], 0
for run in doc["runs"]:
    m, src = run["measurement"], run["oracle_source"]
    fr = m["free_running"]
    tf = m.get("teacher_forced") or fr  # written only when the free run diverges
    line = f"{src}: first16 {fr['top1_agreement']}/{fr['top1_compared']} greedy {tf['matching_tokens']}/{tf['compared_tokens']}"
    print("PARITY_RESULT", line, "decode_tps=%.2f peak_gb=%.1f" % (m.get("decode_tokens_per_second", 0), m.get("peak_memory_gb", 0)))
    if not src.startswith("ref_"):
        continue  # mlx-vlm diverges from DeepSeek's reference by design: informative only
    seen += 1
    if fr["top1_compared"] <= 0 or fr["top1_agreement"] != fr["top1_compared"] or tf["matching_tokens"] < need:
        bad.append(line)
if seen == 0:
    bad.append("no DeepSeek-reference run in the result")
print("PARITY_GATE", "PASS" if not bad else "FAIL " + "; ".join(bad))
sys.exit(1 if bad else 0)
PY
}

oracles "$ABL" "$RES/oracles-abliterated" || die "abliterated oracles failed" 16

# 6. Provider parity on the abliterated weights.
parity "$ABL" "$RES/oracles-abliterated" "$RES/parity-abliterated.json" || die "dsv4-parity on the abliterated artifact did not run" 17
if ! parity_gate "$RES/parity-abliterated.json"; then
  log "PARITY_CONTROL the gate failed; the same check on the base tells an abliteration effect from a pre-existing gap"
  if oracles "$BASE" "$RES/oracles-base" && parity "$BASE" "$RES/oracles-base" "$RES/parity-base.json"; then
    parity_gate "$RES/parity-base.json" | sed 's/^/BASE_/'
  fi
  die "abliterated dsv4-parity gate failed (see PARITY_RESULT lines and BASE_PARITY_* control)" 17
fi

# 7. Refusal sanity, base vs abliterated.
"$PY" -B -I "$JOB/dsv4/dsv4_refusal_check.py" prompts "$RES/refusal-prompts.json" --data "$REFUSAL_DATA" \
  || die "refusal prompts unavailable" 18
for side in base abliterated; do
  [ $side = base ] && dir=$BASE || dir=$ABL
  log "REFUSAL_START $side"
  "$PY" -B -I "$JOB/dsv4/dsv4_refusal_check.py" run "$dir" "$RES/refusal-prompts.json" "$RES/refusal-$side.jsonl" --label $side \
    > "$RES/refusal-$side.log" 2>&1 || die "refusal run ($side) failed: $(tail -n 2 "$RES/refusal-$side.log" | tr '\n' ' ')" 18
done
"$PY" -B -I "$JOB/dsv4/dsv4_refusal_check.py" compare "$RES/refusal-base.jsonl" "$RES/refusal-abliterated.jsonl" \
  --json "$RES/refusal.json" || die "refusal gate failed" 18

# 8. Provenance for a later catalog row, and the hand-off to the grid check.
/usr/bin/python3 -I - "$RES" "$ABL_SHA256" "$BASE_ID" "$BASE_SHA256" "$PARITY_MIN_MATCH" > "$RES/provenance.json" <<'PY' || die "provenance failed" 19
import hashlib, json, pathlib, sys
res, abl_sha, base_id, base_sha, min_match = pathlib.Path(sys.argv[1]), *sys.argv[2:6]
diff = json.loads((res / "tensor-diff.json").read_text())
parity = json.loads((res / "parity-abliterated.json").read_text())
print(json.dumps({
    "schema": "macprovider.dsv4-abliterated-provenance.v1",
    "license": "mit",
    "model_sha256": abl_sha,
    "base_catalog_row": {"model_id": base_id, "model_sha256": base_sha, **diff["served_base"]},
    "abliteration_source": diff["source"],
    "source_base": diff["source_base"],
    "method": "ARA (prem-research model card): attn.wo_b, ffn.shared_experts.w2 and the listed experts' ffn.experts.E.w2, layers 17-36",
    "edited_experts_json_sha256": diff["edited_experts_json_sha256"],
    "recipe": diff["recipe"],
    "tensor_diff_sha256": hashlib.sha256((res / "tensor-diff.json").read_bytes()).hexdigest(),
    "changed_tensors": len(diff["changed_tensors"]),
    "touched_shards": diff["touched_shards"],
    "numeric_worst_max_abs_err": diff["numeric"]["worst_max_abs_err"],
    "parity_min_match": int(min_match),
    "parity_runs": [{"oracle": r["oracle_source"], "first_divergence": r["measurement"]["free_running"].get("first_divergence")}
                    for r in parity["runs"]],
    "refusal": json.loads((res / "refusal.json").read_text()),
}, indent=2, sort_keys=True))
PY
log "PROVENANCE $RES/provenance.json model_sha256=$ABL_SHA256 changed_tensors=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["changed_tensors"])' "$RES/provenance.json")"
log "HANDOFF grid check (job.sh): MODELS=dsv4abl DSV4ABL_PATH=$ABL studio-ablit-perf.sh (served by path; the other DSV4ABL_* fields default in job.sh; catalog model_sha256 would be $ABL_SHA256)"
if [ "${KEEP_SOURCE:-0}" != 1 ]; then
  rm -rf -- "$SOURCE" && log "SOURCE_REMOVED $SOURCE (the tensor diff in $RES records it)"
fi
# The artifact must still be the recorded one after every check that read it.
find "$ABL" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
[ "$(manifest "$ABL")" = "$ABL_SHA256" ] || die "the artifact changed after its manifest was recorded" 15
log "ARTIFACT_UNCHANGED manifest=$ABL_SHA256"
log "JOB_PASS"

# 9. Optional publish, after the pass (DSV4_PUBLISH=1).
if [ "${DSV4_PUBLISH:-0}" = 1 ]; then
  pfail() { log "BLOCKER: $*"; log "PUBLISH_FAIL"; exit 20; }
  EXPECT=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["model_sha256"])' "$RES/provenance.json") \
    || pfail "no model_sha256 in $RES/provenance.json"
  [ "$EXPECT" = "$ABL_SHA256" ] || pfail "provenance model_sha256 $EXPECT is not this run's artifact $ABL_SHA256"
  case " ${DSV4_PUBLISH_ARGS:-} " in *" --dry-run "*) ;; *)
    "$PY" -c 'import huggingface_hub, hf_xet' 2>/dev/null || "$VENV/bin/pip" install -q "hf_xet==1.8.0" > "$RES/publish-pip.log" 2>&1 \
      || pfail "hf_xet install failed"
    [ -x "$VENV/bin/hf" ] || pfail "no hf CLI in $VENV/bin" ;;
  esac
  read -r -a PUBLISH_ARGS <<< "${DSV4_PUBLISH_ARGS:-}"
  log "PUBLISH_START expect_stage=$EXPECT args=${DSV4_PUBLISH_ARGS:-}"
  "$PY" -B -I "$JOB/ablit-perf/publish_dsv4_abliterated.py" "$ABL" "$RES" "$LAB/publish/DeepSeek-V4-Flash-0731-MXFP4-MLX-abliterated" \
    --expect-stage "$EXPECT" ${PUBLISH_ARGS[@]+"${PUBLISH_ARGS[@]}"} 2>&1 | tee "$RES/publish.log"
  [ "${PIPESTATUS[0]}" = 0 ] || pfail "publish_dsv4_abliterated.py failed: $(grep BLOCKER "$RES/publish.log" | tail -n 1)"
  log "PUBLISH_PASS"
fi
