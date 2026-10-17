"""T2 reference lane: mlx-vlm glm5_next speed + greedy parity oracle.

Usage: python bench_vlm.py <model_dir> <out_dir> [--contexts 1024,8192,65536] [--decode 256]
Writes <out_dir>/speed.json and <out_dir>/oracle_<ctx>.npz (prompt ids, greedy ids,
top-16 logits for the first 16 decode steps). Text path only, temperature 0, no prompt cache.
"""

import argparse
import hashlib
import importlib.metadata as md
import json
import os
import platform
import subprocess
import time

import mlx.core as mx
import numpy as np
import sys

if "--omlx-vendor" in sys.argv:
    # The served artifact uses the mlx-vlm#2030 tensor layout that oMLX vendors;
    # stock mlx-vlm 0.7.8 cannot load it (fused KDA projections, mixed bits).
    from omlx.patches.mlx_vlm_glm5_next_compat import PR_MERGE_SHA, PR_URL, apply_mlx_vlm_glm5_next_compat_patch
    assert apply_mlx_vlm_glm5_next_compat_patch(), "oMLX glm5_next compat patch did not apply"
    VENDOR = {"pr": PR_URL, "merge_sha": PR_MERGE_SHA}
else:
    VENDOR = None

from mlx_vlm import load

PREFILL_CHUNK = 2048
TOPK = 16
ORACLE_STEPS = 16


def corpus_ids(tokenizer, n):
    # Deterministic, code-heavy text: the repo's own Swift sources are not available
    # here, so use a fixed synthetic Python corpus repeated to length.
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
    ids = []
    i = 0
    while len(ids) < n:
        ids.extend(tokenizer.encode(f"# block {i}\n" + unit, add_special_tokens=False))
        i += 1
    return ids[:n]


def prefill(lm, ids, cache):
    logits = None
    for s in range(0, len(ids), PREFILL_CHUNK):
        chunk = mx.array([ids[s : s + PREFILL_CHUNK]])
        out = lm(inputs=chunk, cache=cache)
        logits = out.logits[:, -1, :]
        mx.eval(logits)
    return logits


def run(lm, ids, decode):
    cache = lm.make_cache()
    mx.synchronize()
    mx.reset_peak_memory()
    t0 = time.perf_counter()
    logits = prefill(lm, ids, cache)
    mx.eval(logits)
    t1 = time.perf_counter()
    greedy, tops = [], []
    tok = mx.argmax(logits, axis=-1)
    for step in range(decode):
        mx.eval(tok)
        t = int(tok.item())
        greedy.append(t)
        if step < ORACLE_STEPS:
            l = logits[0].astype(mx.float32)
            idx = mx.argsort(-l)[:TOPK]
            tops.append((np.array(idx), np.array(l[idx])))
        out = lm(inputs=mx.array([[t]]), cache=cache)
        logits = out.logits[:, -1, :]
        tok = mx.argmax(logits, axis=-1)
    mx.eval(tok)
    t2 = time.perf_counter()
    return {
        "prompt_tokens": len(ids),
        "decode_tokens": decode,
        "prefill_s": t1 - t0,
        "prefill_tps": len(ids) / (t1 - t0),
        "decode_s": t2 - t1,
        "decode_tps": decode / (t2 - t1),
        "ttft_s": t1 - t0,
        "peak_memory_gb": mx.get_peak_memory() / 1e9,
    }, greedy, tops


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--contexts", default="1024,8192,65536")
    ap.add_argument("--decode", type=int, default=256)
    ap.add_argument("--omlx-vendor", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)
    model, processor = load(a.model_dir)
    tok = getattr(processor, "tokenizer", processor)
    lm = model.language_model
    # warmup
    run(lm, corpus_ids(tok, 256), 8)
    results = []
    for ctx in [int(x) for x in a.contexts.split(",")]:
        ids = corpus_ids(tok, ctx)
        r, greedy, tops = run(lm, ids, a.decode)
        r["prompt_sha256"] = hashlib.sha256(np.array(ids, dtype=np.int32).tobytes()).hexdigest()
        results.append(r)
        np.savez(
            os.path.join(a.out_dir, f"oracle_{ctx}.npz"),
            prompt=np.array(ids, dtype=np.int32),
            greedy=np.array(greedy, dtype=np.int32),
            top_idx=np.stack([t[0] for t in tops]),
            top_logit=np.stack([t[1] for t in tops]),
        )
        print(json.dumps(r), flush=True)
    meta = {
        "lane": "mlx-vlm-vendored-pr2030" if VENDOR else "mlx-vlm",
        "vendor": VENDOR,
        "versions": {p: md.version(p) for p in ("mlx", "mlx-vlm", "mlx-lm", "transformers") + (("omlx",) if VENDOR else ())},
        "macos": platform.mac_ver()[0],
        "macos_build": subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip(),
        "prefill_chunk": PREFILL_CHUNK,
        "sampling": "greedy argmax, temperature 0, no prompt cache, batch 1",
        "results": results,
    }
    with open(os.path.join(a.out_dir, "speed.json"), "w") as f:
        json.dump(meta, f, indent=2)


if __name__ == "__main__":
    main()
