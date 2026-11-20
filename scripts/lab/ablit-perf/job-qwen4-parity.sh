#!/bin/bash
# Runs ON THE STUDIO from ~/lab-ablit-perf/job/ablit-perf/. Campaign #2409 cell: token parity of
# the native qwen4_exp (Qwen3.8-Flash-Next) port against the author's Python reference,
# mlx-lm's mlx_lm/models/qwen4_exp.py, text only, before any speed work.
#
# Steps:
#  1. stage before any GPU work: the model snapshot (Hugging Face download at a pinned
#     revision when QWEN4_PATH is absent), a venv with mlx-lm pinned to the commit that
#     added qwen4_exp, and the mlx-swift-lm fork checkout with the port (FORK);
#  2. oracles (GPU, mlx-lm): the 1K and 8K code prompts of scripts/lab/cb-studio/
#     glm53_bench_vlm.py, prefilled in 2048-token chunks, 256 greedy tokens, top-16 logits
#     of the first 16 steps; converted by cb-studio/glm53_oracle_json.py;
#  3. lab-harness release build of src/phase3-binary in its own build path, with the
#     mlx-swift-lm dependency replaced by FORK (`swift package edit`, this build path only);
#  4. glm-parity of the same snapshot against both oracles (prefill chunk 2048, 256 steps);
#  5. gates: first 16 top-1 exact and teacher-forced >= 240/256 on both prompts.
#
# The oracle (qwen4_oracle.py, shipped beside this script) loads the oQ checkpoint with
# mlx-lm's own Model and sanitize. Stock mlx_lm.load cannot: its sanitize concatenates
# each hyper-connection's block_inject_weight into input_mix_weight_down, and in this
# mixed-precision build five of those pairs carry different bits (ORACLE_SPLIT lines);
# the checkpoint also keeps the n-gram table's `weight_scale` (1.0). The oracle keeps a
# mixed pair as two quantized matmuls, reads bits from tensor shapes and checks them
# against the config (ORACLE_QUANT), and must pass the parity-grid sanity rule on short
# greedy chat prompts before its logits count (ORACLE_SANE, else REFERENCE_SUSPECT).
# The model code is the reference's, unchanged.
#
# Env: QWEN4_PATH (snapshot dir), QWEN4_REPO/QWEN4_REVISION (download source), FORK,
# CONTEXTS (default 1024,8192), STEPS (256). Every failure prints `BLOCKER:`; the job ends
# with JOB_PASS (exit 0) or exits nonzero.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-ablit-perf
JOB=$LAB/job
SRC=$LAB/src/phase3-binary
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
RES=$LAB/results/$RUN_ID/qwen4-parity
QWEN4_REPO=${QWEN4_REPO:-latent-variable/Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp}
QWEN4_REVISION=${QWEN4_REVISION:-65b0cd66046e41b63fb565466c5a52a6295a7592}
QWEN4_PATH=${QWEN4_PATH:-$LAB/models/Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp}
FORK=${FORK:-$LAB/mlx-swift-lm-2409}
CONTEXTS=${CONTEXTS:-1024,8192}
STEPS=${STEPS:-256}
MLX_LM_COMMIT=c4c9c762cc797fd979fc98645f5db5112753bbe9
VENV=$LAB/venv-lm-qwen4
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-qwen4
CLI=$SRC/$BUILD/release/macprovider-cli
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; exit "${2:-1}"; }
rm -rf "$RES" && mkdir -p "$RES"
log "JOB_START qwen4-parity run=$RUN_ID model=$QWEN4_PATH fork=$FORK contexts=$CONTEXTS"

# 1. Stage.
[ -f "$FORK/Libraries/MLXLLM/Models/Qwen4Exp.swift" ] \
  || die "no fork checkout with the qwen4_exp port at FORK=$FORK (rsync the campaign/2409-qwen4-exp worktree there)" 11
log "FORK $(git -C "$FORK" rev-parse HEAD 2>/dev/null || echo no-git) $(git -C "$FORK" status --porcelain 2>/dev/null | wc -l | tr -d ' ') uncommitted"
if ! "$VENV/bin/python" -I -c "import mlx_lm.models.qwen4_exp" > /dev/null 2>&1; then
  rm -rf "$VENV"
  PY312=$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)
  [ -x "$PY312" ] || die "python3.12 not found (the mlx wheels need it)" 11
  "$PY312" -m venv "$VENV" && "$VENV/bin/pip" install -q "mlx-lm @ git+https://github.com/ml-explore/mlx-lm@$MLX_LM_COMMIT" \
    > "$RES/venv.log" 2>&1 || die "venv: $(tail -n 2 "$RES/venv.log" | tr '\n' ' ')" 11
fi
if [ ! -f "$QWEN4_PATH/config.json" ]; then
  free_gb=$(df -g "$LAB" | awk 'NR==2 {print $4}')
  [ "${free_gb:-0}" -ge 130 ] || die "need 130 GB free for the 106 GB snapshot, have ${free_gb} GB" 11
  log "DOWNLOAD $QWEN4_REPO@$QWEN4_REVISION"
  "$VENV/bin/hf" download "$QWEN4_REPO" --revision "$QWEN4_REVISION" --local-dir "$QWEN4_PATH" \
    > "$RES/download.log" 2>&1 || die "download: $(tail -n 2 "$RES/download.log" | tr '\n' ' ')" 11
fi
[ "$(ls "$QWEN4_PATH"/model-*.safetensors 2> /dev/null | wc -l | tr -d ' ')" = 21 ] || die "snapshot at $QWEN4_PATH is not 21 shards" 11

# 2. Oracles, before the build so they never share memory with the CLI.
cp "$JOB/ablit-perf/qwen4_oracle.py" "$RES/qwen4_oracle.py"  # the run record keeps the oracle it ran
log "ORACLE start"
"$VENV/bin/python" -I "$JOB/ablit-perf/qwen4_oracle.py" "$QWEN4_PATH" "$RES/oracles" "$CONTEXTS" "$STEPS" \
  > "$RES/oracle.stdout" 2> "$RES/oracle.stderr"
rc=$?
grep -E '^(ORACLE_|REFERENCE_)' "$RES/oracle.stdout"
[ "$rc" = 3 ] && die "oracle is degenerate, its logits are not a reference: $(grep '^REFERENCE_SUSPECT' "$RES/oracle.stdout" | cut -c1-300)" 13
[ "$rc" = 0 ] || die "oracle exit $rc: $(tail -n 2 "$RES/oracle.stderr" | tr '\n' ' ')" 13
for f in "$RES"/oracles/oracle_*.npz; do
  "$VENV/bin/python" -I "$JOB/cb-studio/glm53_oracle_json.py" "$f" || die "oracle json $f" 13
done

# 3. Lab-harness build against the fork (own build path: job.sh's build stays on the pin).
log "BUILD start"
(cd "$SRC" && swift package --build-path "$BUILD" unedit mlx-swift-lm > /dev/null 2>&1
 swift package --build-path "$BUILD" edit mlx-swift-lm --path "$FORK" \
   && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD" -Xswiftc -DMACPROVIDER_LAB_HARNESS) \
  > "$RES/build.log" 2>&1 || die "swift build failed: $(tail -n 3 "$RES/build.log" | tr '\n' ' ')" 14
cp "$METALLIB" "$(dirname "$CLI")/mlx.metallib"
log "BUILD done $("$CLI" --version 2>&1 | head -n 1) cli_sha256=$(shasum -a 256 "$CLI" | cut -c1-16)"

# 4. Provider parity on the serve load path.
args=()
for f in "$RES"/oracles/oracle_*.json; do args+=(--oracle "$f"); done
"$CLI" glm-parity --model-dir "$QWEN4_PATH" "${args[@]}" --steps "$STEPS" --prefill-step-size 2048 \
  --mlx-cache-limit-mb 2048 --output "$RES/glm-parity.json" > "$RES/glm-parity.stdout" 2> "$RES/glm-parity.stderr"
rc=$?
log "PARITY_GLM exit=$rc $(tail -n 3 "$RES/glm-parity.stderr" | tr '\n' ' ' | cut -c1-300)"
[ "$rc" = 0 ] || die "glm-parity exit $rc (see $RES/glm-parity.stderr)" 15

# 5. Gates.
python3 - "$RES" "$CONTEXTS" "$STEPS" <<'PY' || die "parity gates failed" 15
import json, sys, pathlib
res, contexts, steps = pathlib.Path(sys.argv[1]), sys.argv[2].split(","), int(sys.argv[3])
runs = {r["oracle_source"]: r["measurement"] for r in json.loads((res / "glm-parity.json").read_text())["runs"]}
bad = []
if len(runs) != len(contexts):
    bad.append(f"runs {len(runs)} of {len(contexts)}")
for name, m in sorted(runs.items()):
    # glm-parity writes teacher_forced only when the free run diverges; a full match counts as all steps.
    fr = m["free_running"]; tf = m.get("teacher_forced") or fr
    print(f"PARITY_CELL {name} first16 {fr['top1_agreement']}/{fr['top1_compared']} teacher-forced {tf['matching_tokens']}/{steps}")
    if fr["top1_compared"] <= 0 or fr["top1_agreement"] != fr["top1_compared"] or tf["matching_tokens"] < steps * 15 // 16:
        bad.append(name)
print("PARITY_GATES", "FAIL " + "; ".join(bad) if bad else "PASS")
sys.exit(1 if bad else 0)
PY
log "JOB_PASS"
