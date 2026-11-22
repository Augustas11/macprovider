"""mlx-lm greedy parity oracles for a qwen3_5 checkpoint, in glm53_bench_vlm.py's format.

usage: oracle_mlxlm.py MODEL_DIR OUT_DIR [--contexts 1024,8192,32768] [--decode 256]

Stock `mlx_lm.load` (mlx-lm's own qwen3_5 Model and sanitize, MTP tensors dropped). Per context:
the code prompt of scripts/lab/cb-studio/glm53_bench_vlm.py (same corpus, so the prompt ids
match that lane), prefilled in 2048-token chunks, DECODE greedy tokens, the top-16 logits of the
first 16 steps. Writes OUT_DIR/oracle_<ctx>.npz (prompt, greedy, top_idx, top_logit) for
scripts/lab/cb-studio/glm53_oracle_json.py, and OUT_DIR/meta.json with the package versions.
These are parity oracles only: the loop is a bare forward loop, so its timings are not a
reference decode tok/s (docs/runbooks/model-family-performance-intake.md, Reference).
"""
import argparse
import hashlib
import importlib.metadata as md
import json
import os
import platform
import subprocess

import mlx.core as mx
import numpy as np
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache

PREFILL_CHUNK, TOPK, ORACLE_STEPS = 2048, 16, 16


def corpus_ids(tokenizer, n):
    # Identical to glm53_bench_vlm.py corpus_ids: the lane's prompt.
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


def run(model, ids, decode):
    cache = make_prompt_cache(model)
    logits = None
    for s in range(0, len(ids), PREFILL_CHUNK):
        logits = model(mx.array([ids[s:s + PREFILL_CHUNK]]), cache=cache)[:, -1, :]
        mx.eval(logits)
    greedy, tops = [], []
    tok = mx.argmax(logits, axis=-1)
    for step in range(decode):
        mx.eval(tok)
        t = int(tok.item())
        greedy.append(t)
        if step < ORACLE_STEPS:
            row = logits[0].astype(mx.float32)
            idx = mx.argsort(-row)[:TOPK]
            tops.append((np.array(idx), np.array(row[idx])))
        logits = model(mx.array([[t]]), cache=cache)[:, -1, :]
        tok = mx.argmax(logits, axis=-1)
    return greedy, tops


def version(p):
    try:
        return md.version(p)
    except md.PackageNotFoundError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--contexts", default="1024,8192,32768")
    ap.add_argument("--decode", type=int, default=256)
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)
    model, tokenizer = load(a.model_dir)
    run(model, corpus_ids(tokenizer, 256), 8)  # warm-up
    cells = []
    for ctx in [int(x) for x in a.contexts.split(",")]:
        ids = corpus_ids(tokenizer, ctx)
        greedy, tops = run(model, ids, a.decode)
        np.savez(os.path.join(a.out_dir, f"oracle_{ctx}.npz"),
                 prompt=np.array(ids, dtype=np.int32), greedy=np.array(greedy, dtype=np.int32),
                 top_idx=np.stack([t[0] for t in tops]), top_logit=np.stack([t[1] for t in tops]))
        cell = {"context": ctx, "prompt_tokens": len(ids), "decode_tokens": len(greedy),
                "prompt_sha256": hashlib.sha256(np.array(ids, dtype=np.int32).tobytes()).hexdigest()}
        cells.append(cell)
        print("ORACLE " + json.dumps(cell), flush=True)
    meta = {"lane": "mlx-lm", "loader": "mlx_lm.load",
            "versions": {p: version(p) for p in ("mlx", "mlx-metal", "mlx-lm", "transformers")},
            "macos_build": subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip(),
            "machine": platform.machine(), "prefill_chunk": PREFILL_CHUNK,
            "sampling": "greedy argmax, batch 1, no prompt cache reuse", "cells": cells}
    with open(os.path.join(a.out_dir, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)


if __name__ == "__main__":
    main()
