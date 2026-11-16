#!/bin/bash
# Runs ON THE STUDIO, started detached by `JOB_SCRIPT=job-2376-parity.sh studio-2376.sh`.
# Provider parity for the abliterated MiniMax M3.1-Flash (#2376):
# 1. mlx-vlm oracles on the catalog base with the runtime ablation (target) and without (control);
# 2. a lab-harness release build of this branch (rsynced to ~/lab-2376/src);
# 3. glm-parity of the published snapshot, loaded under its catalog ID, against both oracle sets;
# 4. msb-throughput parity (serial vs 4-row batched scheduler decode) on the same load path.
# The catalog ID resolves through ~/.cache/huggingface/hub/models--minimaxai--minimax-m3.1-flash-abliterated,
# a link to the published stage that this job creates and removes.
set -u
LAB=$HOME/lab-2376
JOB=$LAB/job
RES=$LAB/results/parity
VENV=$LAB/venv-vlm
SRC=$LAB/src/phase3-binary
BASE=${BASE:-$(ls -d "$HOME"/lab-2189/models/*[Mm]ini[Mm]ax*oQ3e* 2>/dev/null | head -n 1)}
STAGE=$LAB/publish/MiniMax-M3.1-Flash-oQ3e-mtp-abliterated
log() { echo "$(date -u '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; exit "${2:-1}"; }
if [ "${LOCAL_STAGE:-0}" = 1 ]; then
  # Unpublished: stage locally with publish_abliterated.py --dry-run (no Hugging Face contact) and
  # load that stage under a local revision id (the first 40 hex digits of its manifest).
  mkdir -p "$LAB/results"
  "$VENV/bin/python" -I "$JOB/publish_abliterated.py" "$BASE" "$LAB/direction-v1.safetensors" "$LAB/results/ablate/eval.json" \
    "$STAGE" MiniMax-M3.1-Flash-oQ3e-mtp-abliterated --expect-base 21188ee28f031b9444e8a250e16aea57ee37a0c2f8d1a24c2ad44686ad744f03 \
    --dry-run > "$LAB/results/local-stage.log" 2>&1 || blocker "local stage failed: $(tail -n 2 "$LAB/results/local-stage.log" | tr '\n' ' ')" 11
  STAGE_MANIFEST=$(sed -n 's/^PUBLISH_STAGE manifest=\([0-9a-f]\{64\}\).*/\1/p' "$LAB/results/local-stage.log" | tail -n 1)
  REVISION=$(printf %s "$STAGE_MANIFEST" | cut -c1-40)
  log "PARITY_LOCAL_STAGE manifest=$STAGE_MANIFEST (not published)"
else
  # The published revision and stage manifest come from the last publish run (PUBLISH_DONE line).
  DONE_LINE=$(grep '^PUBLISH_DONE ' "$LAB/results/publish.log" 2>/dev/null | tail -n 1)
  REVISION=$(echo "$DONE_LINE" | sed -n 's/.* revision=\([0-9a-f]\{40\}\).*/\1/p')
  STAGE_MANIFEST=$(echo "$DONE_LINE" | sed -n 's/.* stage_manifest=\([0-9a-f]\{64\}\).*/\1/p')
fi
MODEL_ID=minimaxai/minimax-m3.1-flash-abliterated
HUBDIR=$HOME/.cache/huggingface/hub/models--minimaxai--minimax-m3.1-flash-abliterated
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
CLI=$SRC/.build-lab-harness/release/macprovider-cli
cleanup() { [ -L "$HUBDIR/snapshots/$REVISION" ] && rm -rf "$HUBDIR"; }
trap cleanup EXIT
# Fresh outputs every run, so a refused load can never be judged on an earlier run's JSON.
rm -rf "$RES" && mkdir -p "$RES"
FAILED=""
log "JOB_START parity base=$BASE"
[ -f "$BASE/config.json" ] || blocker "no MiniMax oQ3e base row" 11
[ -n "$REVISION" ] && [ -n "$STAGE_MANIFEST" ] || blocker "no target revision/manifest (LOCAL_STAGE=${LOCAL_STAGE:-0}: local-stage.log or publish.log PUBLISH_DONE)" 11
log "PARITY_TARGET revision=$REVISION stage_manifest=$STAGE_MANIFEST"
[ -f "$STAGE/refusal_direction.safetensors" ] || blocker "no published stage at $STAGE" 11
[ ! -e "$HUBDIR" ] || blocker "$HUBDIR already exists; refusing to replace it" 11
"$VENV/bin/python" -I -c "
import sys; sys.path.insert(0, '$JOB'); from publish_abliterated import snapshot_manifest_sha256 as m; import pathlib
s = m(pathlib.Path('$STAGE')); print('stage manifest', s); assert s == '$STAGE_MANIFEST', s" || blocker "stage differs from the published manifest" 12

# 1. Oracles (GPU, mlx-vlm), before the build so they cannot share memory with the CLI.
"$VENV/bin/python" -I "$JOB/minimax_parity_oracle.py" "$BASE" "$STAGE/refusal_direction.safetensors" "$JOB/data" "$RES/oracles" \
  > "$RES/oracle.stdout" 2> "$RES/oracle.stderr" || blocker "oracle exit: $(tail -n 2 "$RES/oracle.stderr" | tr '\n' ' ')" 13
grep -E '^ORACLE_' "$RES/oracle.stdout"
for f in "$RES"/oracles/oracle_*.npz; do "$VENV/bin/python" -I "$JOB/glm53_oracle_json.py" "$f" || blocker "oracle json $f" 13; done

# 2. Lab-harness build of this branch.
log "PARITY_BUILD start"
(cd "$SRC" && nice -n 10 swift build -c release --product macprovider-cli --build-path .build-lab-harness \
  -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/build.log" 2>&1 || blocker "swift build failed: $(tail -n 3 "$RES/build.log" | tr '\n' ' ')" 14
cp "$METALLIB" "$(dirname "$CLI")/mlx.metallib"
log "PARITY_BUILD done $("$CLI" --version 2>&1 | head -n 1) cli_sha256=$(shasum -a 256 "$CLI" | cut -c1-16)"

# 3. The published snapshot under its catalog ID (the serve load path, ablation from config.json).
mkdir -p "$HUBDIR/refs" "$HUBDIR/snapshots" && printf %s "$REVISION" > "$HUBDIR/refs/main" && ln -s "$STAGE" "$HUBDIR/snapshots/$REVISION"
for variant in ablated base; do
  args=()
  for p in code_1024 code_8192 chat; do args+=(--oracle "$RES/oracles/oracle_${variant}_$p.json"); done
  "$CLI" glm-parity --model-dir "$MODEL_ID" "${args[@]}" --steps 256 --prefill-step-size 2048 \
    --mlx-cache-limit-mb 2048 --output "$RES/glm-parity-$variant.json" > "$RES/glm-parity-$variant.stdout" 2> "$RES/glm-parity-$variant.stderr"
  rc=$?; [ "$rc" = 0 ] || FAILED="$FAILED glm-parity-$variant:$rc"
  log "PARITY_GLM $variant exit=$rc $(tail -n 3 "$RES/glm-parity-$variant.stderr" | tr '\n' ' ' | cut -c1-300)"
done

# 4. Serial vs batched scheduler decode on the same load path.
"$CLI" msb-throughput --model "$MODEL_ID" --scenario parity --rows 4 --parity-tokens 128 --engine scheduler \
  --output "$RES/msb-parity.json" > "$RES/msb-parity.stdout" 2> "$RES/msb-parity.stderr"
rc=$?; [ "$rc" = 0 ] || FAILED="$FAILED msb:$rc"
log "PARITY_MSB exit=$rc $(tail -n 2 "$RES/msb-parity.stdout" | tr '\n' ' ' | cut -c1-300)"

# Gates: the provider follows the ablated reference (first 16 top-1 exact, teacher-forced top-1 >= 240/256
# on every prompt), leaves the unablated reference on the chat prompt (first-16 top-1 <= 8), and batched
# decode equals serial.
[ -z "$FAILED" ] || blocker "provider runs failed:$FAILED (see $RES/*.stderr)" 15
python3 - "$RES" <<'PY' || blocker "parity gates failed" 15
import json, sys, pathlib
res = pathlib.Path(sys.argv[1]); bad = []
def runs(v): return {r["oracle_source"]: r["measurement"] for r in json.loads((res / f"glm-parity-{v}.json").read_text())["runs"]}
for name, m in runs("ablated").items():
    # glm-parity writes teacher_forced only when the free run diverges; a full match counts as 256/256.
    fr = m["free_running"]; tf = m.get("teacher_forced") or fr
    if fr["top1_compared"] <= 0 or fr["top1_agreement"] != fr["top1_compared"] or tf["matching_tokens"] < 240:
        bad.append(f"ablated {name}: first16 {fr['top1_agreement']}/{fr['top1_compared']} teacher-forced {tf['matching_tokens']}/256")
if len(runs("ablated")) != 3:
    bad.append(f"ablated runs: {len(runs('ablated'))} of 3")
chat = runs("base")["oracle_base_chat.npz"]["free_running"]
if chat["top1_compared"] <= 0 or chat["top1_agreement"] > 8:
    bad.append(f"control chat first16 {chat['top1_agreement']}/16: ablation not visible")
msb = json.loads((res / "msb-parity.json").read_text())
if not msb.get("leftovers", {}).get("parity", {}).get("pass"):
    bad.append("msb batched-vs-serial parity did not pass")
print("PARITY_GATES", "FAIL " + "; ".join(bad) if bad else "PASS")
sys.exit(1 if bad else 0)
PY
log "JOB_PASS"
