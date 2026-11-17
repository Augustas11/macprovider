"""mlx-lm qwen4_exp greedy oracles (glm53_bench_vlm.py's prompts and .npz format).

usage: qwen4_oracle.py SNAPSHOT_DIR OUT_DIR CONTEXTS STEPS

Loads the checkpoint with mlx-lm's own qwen4_exp Model and sanitize, then:
  1. a sanity gate: greedy text for short chat prompts must pass the parity-grid
     sanity rule (scripts/lab/parity-grid/sanity.py) before any logits are
     trusted; a degenerate reference exits 3 with `REFERENCE_SUSPECT`;
  2. the oracle cells: the code prompt at each context, prefilled in 2048-token
     chunks, STEPS greedy tokens, top-16 logits of the first 16 steps.

Loader differences from stock mlx_lm.load, each printed:
  - mixed-width merges (ORACLE_SPLIT): stock sanitize concatenates a
    hyper-connection's `block_inject_weight` into `input_mix_weight_down`
    (qwen4_exp.py `_merge_linears`). In a mixed-precision oQ build the two parts
    can carry different bits or group sizes, so their packed tensors cannot be
    concatenated. Such a pair stays two quantized matmuls with the outputs
    concatenated in the merged order: each output row is the same quantized dot
    product as in the merged layer. Pairs that share bits are merged as stock.
  - bits per module are read from the tensor shapes (as mlx-lm's
    infer_quant_config does); every module is checked against the checkpoint's
    `quantization` block (keyed `language_model.*`, defaults for unlisted
    modules) and a disagreement fails the load (ORACLE_QUANT).
  - the n-gram table's `weight_scale` is dropped (it is 1.0 in the oQ build;
    mlx-vlm drops it once the table is in shards).
"""
import glob
import hashlib
import importlib.metadata as md
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "parity-grid"))

PREFILL_CHUNK, TOPK, ORACLE_STEPS = 2048, 16, 16
SANITY_MAX_TOKENS = 64
SANITY_PROMPTS = (
    "Describe, in one long paragraph, how a lighthouse keeper spends a winter night.",
    "Explain in plain prose why the sky looks blue during the day and red at sunset.",
    "Write a short story about a baker who finds an old map inside a bag of flour.",
)
_HC_RE = re.compile(r"^(?:language_model\.|model\.language_model\.)?(?:model\.)?layers\.(\d+)\.((?:attn|mlp)_hyper_connection)\.$")


def mixed_merges(shapes):
    """Prefixes (`...layers.N.{attn,mlp}_hyper_connection.`) of checkpoint keys
    whose `input_mix_weight_down` and `block_inject_weight` differ in packed
    width, scales width or affine biases, i.e. in bits, group size or mode;
    `shapes` maps checkpoint keys to shape tuples. MTP keys are skipped (stock
    sanitize drops them)."""
    out = []
    for k in sorted(shapes):
        if not k.endswith("block_inject_weight.weight") or k.startswith(("mtp.", "model.mtp.", "language_model.mtp.")):
            continue
        p = k[: -len("block_inject_weight.weight")]
        parts = (p + "input_mix_weight_down", p + "block_inject_weight")
        if f"{parts[0]}.weight" not in shapes:
            continue
        sigs = {(shapes[f"{q}.weight"][-1], (shapes.get(f"{q}.scales") or (None,))[-1], f"{q}.biases" in shapes)
                for q in parts}
        if len(sigs) > 1:
            out.append(p)
    return out


def quant_key(path):
    """The checkpoint `quantization` key for a module path of the loaded model."""
    k = "language_model." + path
    k = re.sub(r"\.ngram_embedding\.\d+$", ".ngram_embedding.shards.0", k)
    k = re.sub(r"\.input_mix_weight_down\.inject$", ".block_inject_weight", k)
    k = re.sub(r"\.input_mix_weight_down\.down$", ".input_mix_weight_down", k)
    return k


def quant_mismatches(inferred, quantization):
    """[(path, inferred, expected)] where the shape-inferred (bits, group_size)
    of a module differs from the checkpoint's quantization block."""
    default = (quantization.get("bits"), quantization.get("group_size"))
    bad = []
    for path, got in sorted(inferred.items()):
        entry = quantization.get(quant_key(path))
        want = (entry["bits"], entry["group_size"]) if isinstance(entry, dict) else default
        if got != want:
            bad.append((path, got, want))
    return bad


def split_mixed_merges(model, weights):
    """Keep each mixed-width merge as two quantized matmuls (module docstring).
    Renames the parts' checkpoint keys so stock sanitize leaves them alone and
    swaps the model's merged Linear for the split one. Returns log lines."""
    import mlx.core as mx
    import mlx.nn as nn

    class SplitDown(nn.Module):
        """input_mix_weight_down as [down rows; inject rows], one matmul each."""

        def __init__(self, in_dims, lowrank, hc):
            super().__init__()
            self.down = nn.Linear(in_dims, lowrank, bias=False)
            self.inject = nn.Linear(in_dims, hc, bias=False)

        def __call__(self, x):
            return mx.concatenate([self.down(x), self.inject(x)], axis=-1)

    shapes = {k: tuple(v.shape) for k, v in weights.items()}
    log = []
    for p in mixed_merges(shapes):
        m = _HC_RE.match(p)
        if m is None:
            raise ValueError(f"mixed merge at {p}: not a decoder-layer hyper-connection")
        owner = getattr(model.model.layers[int(m.group(1))], m.group(2))
        for src, dst in (("input_mix_weight_down", "input_mix_weight_down.down"),
                         ("block_inject_weight", "input_mix_weight_down.inject")):
            for name in ("weight", "scales", "biases"):
                if f"{p}{src}.{name}" in weights:
                    weights[f"{p}{dst}.{name}"] = weights.pop(f"{p}{src}.{name}")
        merged = owner.input_mix_weight_down.weight.shape
        owner.input_mix_weight_down = SplitDown(merged[-1], owner.lowrank, owner.hc)
        log.append(f"layer {m.group(1)} {m.group(2)}: input_mix_weight_down {shapes[p + 'input_mix_weight_down.weight']}"
                   f" + block_inject_weight {shapes[p + 'block_inject_weight.weight']}")
    return log


def prepare(model, weights, quantization=None):
    """mlx-lm's qwen4_exp load on a weights dict: split mixed merges, stock
    sanitize, quantize by tensor shapes (checked against `quantization`),
    strict load. Returns (model, info)."""
    import mlx.core as mx
    import mlx.nn as nn

    dropped = [k for k in weights if k.endswith(".ngram_embedding.weight_scale")]
    for k in dropped:
        del weights[k]
    split = split_mixed_merges(model, weights)
    weights = model.sanitize(weights)

    inferred = {}

    def predicate(p, m):
        if f"{p}.scales" not in weights or not hasattr(m, "to_quantized"):
            return False
        in_dims = m.weight.shape[-1]
        bits = weights[f"{p}.weight"].shape[-1] * 32 // in_dims
        group = in_dims // weights[f"{p}.scales"].shape[-1]
        inferred[p] = (bits, group)
        return {"group_size": group, "bits": bits, "mode": "affine"}

    nn.quantize(model, class_predicate=predicate)
    bad = quant_mismatches(inferred, quantization) if quantization else []
    if bad:
        raise ValueError(f"{len(bad)} modules disagree with the checkpoint quantization block, e.g. "
                         + "; ".join(f"{p} shapes {g} config {w}" for p, g, w in bad[:5]))
    model.load_weights(list(weights.items()), strict=True)
    mx.eval(model.parameters())
    counts = {}
    for b, g in inferred.values():
        counts[f"{b}b/g{g}"] = counts.get(f"{b}b/g{g}", 0) + 1
    return model, {"dropped": dropped, "split": split, "quant_counts": counts,
                   "quant_checked": bool(quantization)}


def load(path):
    import mlx.core as mx
    from mlx_lm.models import qwen4_exp

    config = json.load(open(os.path.join(path, "config.json")))
    model = qwen4_exp.Model(qwen4_exp.ModelArgs.from_dict(config))
    weights = {}
    for f in sorted(glob.glob(os.path.join(path, "model*.safetensors"))):
        weights.update(mx.load(f))
    return prepare(model, weights, config.get("quantization"))


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


def greedy(model, ids, max_tokens, stop=()):
    import mlx.core as mx

    cache = model.make_cache()
    logits = None
    for s in range(0, len(ids), PREFILL_CHUNK):
        logits = model(mx.array([ids[s : s + PREFILL_CHUNK]]), cache=cache)[:, -1, :]
    out = []
    for _ in range(max_tokens):
        t = int(mx.argmax(logits, axis=-1).item())
        if t in stop:
            break
        out.append(t)
        logits = model(mx.array([[t]]), cache=cache)[:, -1, :]
    return out


def sanity_rows(model, tokenizer, stop):
    rows = []
    for i, prompt in enumerate(SANITY_PROMPTS):
        messages = [{"role": "user", "content": prompt}]
        try:
            text = tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False,
                                                 enable_thinking=False)
        except Exception:  # no chat template: the bare prompt
            text = prompt
        out = greedy(model, tokenizer.encode(text, add_special_tokens=False), SANITY_MAX_TOKENS, stop)
        rows.append({"kind": "row", "ctx_target": "sanity", "max_tokens": SANITY_MAX_TOKENS, "row": i,
                     "trial": 0, "completion_tokens": len(out),
                     "text": tokenizer.decode(out, skip_special_tokens=True), "error": None})
    return rows


def run(model, ids, decode):
    import mlx.core as mx
    import numpy as np

    cache = model.make_cache()
    mx.synchronize()
    mx.reset_peak_memory()
    t0 = time.perf_counter()
    for s in range(0, len(ids), PREFILL_CHUNK):
        logits = model(mx.array([ids[s : s + PREFILL_CHUNK]]), cache=cache)[:, -1, :]
        mx.eval(logits)
    t1 = time.perf_counter()
    greedy_ids, tops = [], []
    tok = mx.argmax(logits, axis=-1)
    for step in range(decode):
        t = int(tok.item())
        greedy_ids.append(t)
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
    }, greedy_ids, tops


def main():
    import mlx.core as mx
    import numpy as np
    from transformers import AutoTokenizer

    import sanity

    path, out, contexts, decode = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    os.makedirs(out, exist_ok=True)
    info = mx.device_info() if hasattr(mx, "device_info") else mx.metal.device_info()
    mx.set_wired_limit(int(info["max_recommended_working_set_size"]))
    t = time.perf_counter()
    model, load_info = load(path)
    for line in load_info["split"]:
        print(f"ORACLE_SPLIT {line}", flush=True)
    print(f"ORACLE_QUANT checked={load_info['quant_checked']} {json.dumps(load_info['quant_counts'], sort_keys=True)}",
          flush=True)
    print(f"ORACLE_LOAD s={time.perf_counter() - t:.1f} split={len(load_info['split'])} dropped={load_info['dropped']}",
          flush=True)
    tokenizer = AutoTokenizer.from_pretrained(path)

    eos = model.args.text.eos_token_id
    stop = set(eos if isinstance(eos, list) else [eos])
    top_eos = json.load(open(os.path.join(path, "config.json"))).get("eos_token_id")
    stop |= set(top_eos if isinstance(top_eos, list) else [top_eos] if top_eos is not None else [])
    if tokenizer.eos_token_id is not None:
        stop.add(tokenizer.eos_token_id)
    rows = sanity_rows(model, tokenizer, stop)
    with open(os.path.join(out, "sanity.jsonl"), "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in rows))
    verdict = sanity.check_reference(rows)
    for r in rows:
        print("ORACLE_SANITY_ROW " + json.dumps({"row": r["row"], "tokens": r["completion_tokens"],
                                                  "text": r["text"][:160]}), flush=True)
    if verdict["suspect"]:
        msg = f"REFERENCE_SUSPECT qwen4_exp mlx-lm oracle: {verdict['reason']}"
        print(msg, flush=True)
        print(msg, file=sys.stderr, flush=True)
        sys.exit(3)
    print("ORACLE_SANE " + json.dumps(verdict["contexts"]), flush=True)

    run(model, corpus_ids(tokenizer, 256), 8)  # warm-up
    results = []
    for ctx in [int(x) for x in contexts.split(",")]:
        ids = corpus_ids(tokenizer, ctx)
        r, greedy_ids, tops = run(model, ids, decode)
        r["prompt_sha256"] = hashlib.sha256(np.array(ids, dtype=np.int32).tobytes()).hexdigest()
        results.append(r)
        np.savez(
            os.path.join(out, f"oracle_{ctx}.npz"),
            prompt=np.array(ids, dtype=np.int32), greedy=np.array(greedy_ids, dtype=np.int32),
            top_idx=np.stack([x[0] for x in tops]), top_logit=np.stack([x[1] for x in tops]),
        )
        print("ORACLE_CELL " + json.dumps(r), flush=True)
    versions = {p: md.version(p) for p in ("mlx", "mlx-lm")}
    json.dump({"versions": versions, "results": results, "loader": load_info, "sanity": verdict},
              open(os.path.join(out, "speed.json"), "w"), indent=2)
    print("ORACLE_DONE " + json.dumps(versions), flush=True)


if __name__ == "__main__":
    main()
