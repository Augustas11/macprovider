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
# The oracle loads the oQ checkpoint with mlx-lm's own Model and sanitize. Stock
# mlx_lm.load cannot: the oQ config keys per-layer quantization by the mlx-vlm module
# paths (`language_model.*`), and the checkpoint keeps the n-gram table's
# `weight_scale`, which mlx-vlm drops once the table is in shards (fp8.py). So the
# oracle reads each layer's bits and group size from its tensor shapes and drops that
# one tensor; the model code is the reference's, unchanged.
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
cat > "$RES/qwen4_oracle.py" <<'PY'
"""mlx-lm qwen4_exp greedy oracles (glm53_bench_vlm.py's prompts and .npz format)."""
import glob, hashlib, importlib.metadata as md, json, os, sys, time
import mlx.core as mx
import mlx.nn as nn
import numpy as np
from mlx_lm.models import qwen4_exp
from transformers import AutoTokenizer

PREFILL_CHUNK, TOPK, ORACLE_STEPS = 2048, 16, 16


def corpus_ids(tokenizer, n):
    # Same text as scripts/lab/cb-studio/glm53_bench_vlm.py corpus_ids.
    unit = (
        "def fibonacci(n: int) -> int:\n"
        "    a, b = 0, 1\n"
        "    for _ in range(n):\n"
        "        a, b = b, a + b\n"
        "    return a\n\n"
        "class Cache:\n"
        "    def __init__(self, size):\n"
        "        self.size = size\n"
        "        self.store = {}\n\n"
        "    def get(self, key, default=None):\n"
        "        return self.store.get(key, default)\n\n"
    )
    ids, i = [], 0
    while len(ids) < n:
        ids.extend(tokenizer.encode(f"# block {i}\n" + unit, add_special_tokens=False))
        i += 1
    return ids[:n]


def load(path):
    config = json.load(open(os.path.join(path, "config.json")))
    model = qwen4_exp.Model(qwen4_exp.ModelArgs.from_dict(config))
    weights = {}
    for f in sorted(glob.glob(os.path.join(path, "model*.safetensors"))):
        weights.update(mx.load(f))
    dropped = [k for k in weights if k.endswith(".ngram_embedding.weight_scale")]
    for k in dropped:
        del weights[k]
    weights = model.sanitize(weights)

    def predicate(p, m):
        if f"{p}.scales" not in weights:
            return False
        in_dims = m.weight.shape[-1]
        bits = weights[f"{p}.weight"].shape[-1] * 32 // in_dims
        group = in_dims // weights[f"{p}.scales"].shape[-1]
        return {"group_size": group, "bits": bits, "mode": "affine"}

    nn.quantize(model, class_predicate=predicate)
    model.load_weights(list(weights.items()), strict=True)
    mx.eval(model.parameters())
    return model, dropped


def run(model, ids, decode):
    cache = model.make_cache()
    mx.synchronize()
    mx.reset_peak_memory()
    t0 = time.perf_counter()
    for s in range(0, len(ids), PREFILL_CHUNK):
        logits = model(mx.array([ids[s : s + PREFILL_CHUNK]]), cache=cache)[:, -1, :]
        mx.eval(logits)
    t1 = time.perf_counter()
    greedy, tops = [], []
    tok = mx.argmax(logits, axis=-1)
    for step in range(decode):
        t = int(tok.item())
        greedy.append(t)
        if step < ORACLE_STEPS:
            row = logits[0].astype(mx.float32)
            idx = mx.argsort(-row)[:TOPK]
            tops.append((np.array(idx), np.array(row[idx])))
        logits = model(mx.array([[t]]), cache=cache)[:, -1, :]
        tok = mx.argmax(logits, axis=-1)
        mx.eval(tok)
    t2 = time.perf_counter()
    return {
        "prompt_tokens": len(ids), "decode_tokens": decode,
        "prefill_tps": len(ids) / (t1 - t0), "decode_tps": decode / (t2 - t1),
        "ttft_s": t1 - t0, "peak_memory_gb": mx.get_peak_memory() / 1e9,
    }, greedy, tops


def main():
    path, out, contexts, decode = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    os.makedirs(out, exist_ok=True)
    info = mx.device_info() if hasattr(mx, "device_info") else mx.metal.device_info()
    mx.set_wired_limit(int(info["max_recommended_working_set_size"]))
    t = time.perf_counter()
    model, dropped = load(path)
    print(f"ORACLE_LOAD s={time.perf_counter() - t:.1f} dropped={dropped}", flush=True)
    tokenizer = AutoTokenizer.from_pretrained(path)
    run(model, corpus_ids(tokenizer, 256), 8)  # warm-up
    results = []
    for ctx in [int(x) for x in contexts.split(",")]:
        ids = corpus_ids(tokenizer, ctx)
        r, greedy, tops = run(model, ids, decode)
        r["prompt_sha256"] = hashlib.sha256(np.array(ids, dtype=np.int32).tobytes()).hexdigest()
        results.append(r)
        np.savez(
            os.path.join(out, f"oracle_{ctx}.npz"),
            prompt=np.array(ids, dtype=np.int32), greedy=np.array(greedy, dtype=np.int32),
            top_idx=np.stack([x[0] for x in tops]), top_logit=np.stack([x[1] for x in tops]),
        )
        print("ORACLE_CELL " + json.dumps(r), flush=True)
    versions = {p: md.version(p) for p in ("mlx", "mlx-lm")}
    json.dump({"versions": versions, "results": results}, open(os.path.join(out, "speed.json"), "w"), indent=2)
    print("ORACLE_DONE " + json.dumps(versions), flush=True)


main()
PY
log "ORACLE start"
"$VENV/bin/python" -I "$RES/qwen4_oracle.py" "$QWEN4_PATH" "$RES/oracles" "$CONTEXTS" "$STEPS" \
  > "$RES/oracle.stdout" 2> "$RES/oracle.stderr" || die "oracle exit: $(tail -n 2 "$RES/oracle.stderr" | tr '\n' ' ')" 13
grep -E '^ORACLE_' "$RES/oracle.stdout"
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
