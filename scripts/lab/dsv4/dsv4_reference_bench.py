"""DeepSeek V4-Flash reference lane: mlx-vlm speed baseline + greedy parity oracle (#2111).

Usage: python -I dsv4_reference_bench.py <model_dir> <out_dir>
    [--oracle-contexts 1024,8192,32768] [--ttft-contexts 4096,32768]
    [--rows 1,4] [--row-prompt 1024] [--decode 256]

Writes into <out_dir> (which must not exist):
  speed.json            versions, identity, per-run TTFT / decode tok/s / peak memory
  oracle_<ctx>.npz      prompt ids, greedy ids, top-16 (ids, logprobs) for the first 16 steps
Text path only, temperature 0 (argmax), no prompt cache.

Unlike the GLM T2 harness this measures decode through mlx-vlm's own runtime paths
(generate_step for one row, BatchGenerator for multi-row), so decode tok/s is valid.
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
from mlx_vlm import load
from mlx_vlm.generate import BatchGenerator, generate_step, generation_stream, wired_limit
# Private helper of the pinned mlx-vlm 0.7.10; batch_generate uses it the same way.
from mlx_vlm.generate.ar import _split_prompt_kwargs_per_row

PREFILL_STEP = 2048
TOPK = 16
ORACLE_STEPS = 16


def corpus_ids(tokenizer, n, offset=0):
    # Deterministic, code-heavy text. `offset` gives each batch row a distinct prompt.
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
    bos = getattr(tokenizer, "bos_token_id", None)
    ids = [bos] if bos is not None else []
    i = offset
    while len(ids) < n:
        ids.extend(tokenizer.encode(f"# block {i}\n" + unit, add_special_tokens=False))
        i += 1
    return ids[:n]


def ids_sha(ids):
    return hashlib.sha256(np.array(ids, dtype=np.int32).tobytes()).hexdigest()


def single_row(model, ids, decode, oracle):
    """One row through generate_step: TTFT, steady decode tok/s, greedy ids, top-k."""
    mx.synchronize()
    mx.clear_cache()
    mx.reset_peak_memory()
    greedy, tops, stamps = [], [], []
    t0 = time.perf_counter()
    for token, logprobs in generate_step(
        mx.array([ids]), model, None, None,
        max_tokens=decode, temperature=0.0, prefill_step_size=PREFILL_STEP,
    ):
        t = int(token.item() if hasattr(token, "item") else token)
        stamps.append(time.perf_counter())
        greedy.append(t)
        if oracle and len(tops) < ORACLE_STEPS:
            lp = logprobs.reshape(-1).astype(mx.float32)
            idx = mx.argsort(-lp)[:TOPK]
            tops.append((np.array(idx, dtype=np.int32), np.array(lp[idx], dtype=np.float32)))
    ttft = stamps[0] - t0
    steady = (len(stamps) - 1) / (stamps[-1] - stamps[0]) if len(stamps) > 1 else None
    record = {
        "mode": "single_row_generate_step",
        "prompt_tokens": len(ids),
        "decode_tokens": len(greedy),
        "ttft_s": ttft,
        "prefill_tps": len(ids) / ttft,
        "decode_tps": steady,
        "peak_memory_gb": mx.get_peak_memory() / 1e9,
        "prompt_sha256": ids_sha(ids),
    }
    return record, greedy, tops


def multi_row(model, processor, tokenizer, rows, prompt_tokens, decode):
    """`rows` concurrent rows through mlx-vlm's continuous-batching generator."""
    prompts = [corpus_ids(tokenizer, prompt_tokens, offset=1000 * r) for r in range(rows)]
    mx.synchronize()
    mx.clear_cache()
    mx.reset_peak_memory()
    # Same text-only path as mlx-vlm batch_generate: per-row embeddings as prompt kwargs.
    input_ids = mx.array(prompts)
    embedded = model.get_input_embeddings(input_ids, None, mask=None)
    gen_kwargs = {k: v for k, v in embedded.to_dict().items() if v is not None}
    gen = BatchGenerator(
        model.language_model, processor, max_tokens=decode, prefill_batch_size=rows,
        completion_batch_size=rows, prefill_step_size=PREFILL_STEP,
        compute_logprobs=False, greedy_sampling=True,
    )
    t0 = time.perf_counter()
    uids = gen.insert(input_ids, decode, prompt_kwargs=_split_prompt_kwargs_per_row(gen_kwargs, rows))
    first, last, tokens = {}, {}, {u: [] for u in uids}
    while gen.has_work:
        _, responses = gen.next()
        now = time.perf_counter()
        for r in responses:
            first.setdefault(r.uid, now)
            last[r.uid] = now
            tokens[r.uid].append(int(r.token))
    wall = time.perf_counter() - t0
    gen.close()
    counts = {u: len(t) for u, t in tokens.items()}
    total = sum(counts.values())
    # Decode window: every row has produced its first token until the last token.
    decode_start = max(first.values())
    decode_tokens = sum(n - 1 for n in counts.values())
    decode_window = max(last.values()) - decode_start
    return {
        "mode": "batch_generator",
        "rows": rows,
        "prompt_tokens_per_row": prompt_tokens,
        "max_tokens": decode,
        "output_tokens": total,
        "wall_s": wall,
        "aggregate_output_tps": total / wall,
        "decode_window_tps": decode_tokens / decode_window if decode_window > 0 else None,
        "ttft_first_row_s": min(first.values()) - t0,
        "ttft_last_row_s": decode_start - t0,
        "peak_memory_gb": mx.get_peak_memory() / 1e9,
        "prompt_sha256": [ids_sha(p) for p in prompts],
    }, [tokens[u] for u in uids]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--oracle-contexts", default="1024,8192,32768")
    ap.add_argument("--ttft-contexts", default="4096,32768")
    ap.add_argument("--rows", default="1,4")
    ap.add_argument("--row-prompt", type=int, default=1024)
    ap.add_argument("--decode", type=int, default=256)
    a = ap.parse_args()
    os.makedirs(a.out_dir, mode=0o700)
    ints = lambda s: [int(x) for x in s.split(",") if x]

    with open(os.path.join(a.model_dir, "config.json"), "rb") as f:
        config_bytes = f.read()
    t_load = time.perf_counter()
    model, processor = load(a.model_dir)
    load_s = time.perf_counter() - t_load
    tok = getattr(processor, "tokenizer", processor)
    results = []

    def emit(record):
        results.append(record)
        print(json.dumps(record), flush=True)

    with wired_limit(model, [generation_stream]):
        single_row(model, corpus_ids(tok, 256), 8, oracle=False)  # warmup
        oracle_ctx = ints(a.oracle_contexts)
        for ctx in sorted(set(oracle_ctx) | set(ints(a.ttft_contexts))):
            ids = corpus_ids(tok, ctx)
            is_oracle = ctx in oracle_ctx
            r, greedy, tops = single_row(model, ids, a.decode if is_oracle else 64, is_oracle)
            r["oracle"] = is_oracle
            emit(r)
            if is_oracle:
                np.savez(
                    os.path.join(a.out_dir, f"oracle_{ctx}.npz"),
                    prompt=np.array(ids, dtype=np.int32),
                    greedy=np.array(greedy, dtype=np.int32),
                    top_idx=np.stack([t[0] for t in tops]),
                    top_logprob=np.stack([t[1] for t in tops]),
                )
        greedy_by_ctx = {}
        for ctx in oracle_ctx:
            greedy_by_ctx[ctx] = np.load(os.path.join(a.out_dir, f"oracle_{ctx}.npz"))["greedy"].tolist()
        row_counts = ints(a.rows)
        try:
            multi_row(model, processor, tok, max(row_counts), 256, 8)  # batch-path warmup
        except Exception:
            pass
        for rows in row_counts:
            try:
                record, row_tokens = multi_row(model, processor, tok, rows, a.row_prompt, a.decode)
                # Row 0's prompt is the single-row oracle prompt of the same length.
                oracle = greedy_by_ctx.get(a.row_prompt)
                if oracle is not None:
                    n = min(len(oracle), len(row_tokens[0]))
                    record["row0_matches_single_row_oracle"] = row_tokens[0][:n] == oracle[:n]
                emit(record)
            except Exception as exc:  # report the reference's limit rather than abort the window
                emit({"mode": "batch_generator", "rows": rows, "error": f"{type(exc).__name__}: {exc}"})

    meta = {
        "lane": "mlx-vlm-deepseek_v4",
        "versions": {p: md.version(p) for p in ("mlx", "mlx-metal", "mlx-vlm", "transformers", "numpy")},
        "macos": platform.mac_ver()[0],
        "macos_build": subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip(),
        "model_config_sha256": hashlib.sha256(config_bytes).hexdigest(),
        "load_s": load_s,
        "prefill_step_size": PREFILL_STEP,
        "sampling": "greedy argmax, temperature 0, no prompt cache",
        "oracle_arrays": "prompt, greedy, top_idx, top_logprob (first 16 decode steps)",
        "results": results,
    }
    with open(os.path.join(a.out_dir, "speed.json"), "w") as f:
        json.dump(meta, f, indent=2)


if __name__ == "__main__":
    main()
