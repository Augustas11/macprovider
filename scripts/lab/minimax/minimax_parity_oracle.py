"""Greedy parity oracles for the abliterated MiniMax M3.1-Flash (#2376), from mlx-vlm.

Usage:
  python -I minimax_parity_oracle.py BASE_DIR DIRECTION DATA_DIR OUT_DIR
         [--contexts 1024,8192] [--decode 256] [--lo 16] [--hi 42] [--alpha 1.5]

The reference is mlx-vlm on the unmodified catalog artifact (BASE_DIR) with the runtime
refusal-direction ablation of minimax_ablate.py (the method the published snapshot's
`text_config.refusal_ablation` names). mlx-vlm is not pointed at the published snapshot,
because it would read refusal_direction.safetensors as a weight file.

Prompts:
- `code_<N>`: the shared code corpus of scripts/lab/cb-studio/glm53_bench_vlm.py, cut to N ids;
- `chat`: the first held-out harmful prompt (DATA_DIR/harmful_test.json) in the chat
  template, where ablated and unmodified outputs differ.

Each prompt gets two oracles: `oracle_ablated_<prompt>.npz` (the target the provider must
match) and `oracle_base_<prompt>.npz` (the control: the provider must leave it, or the
ablation is not applied). Format: glm53_bench_vlm.py's (prompt, greedy, top-16 ids and
logits of the first 16 steps); scripts/lab/cb-studio/glm53_oracle_json.py converts it.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata as md
import json
import os
import pathlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # the job dir holds both helpers

import mlx.core as mx
import numpy as np
from mlx_vlm import load

from glm53_bench_vlm import corpus_ids, run  # noqa: E402
from minimax_ablate import Ablation, chat_ids  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("base_dir"); ap.add_argument("direction"); ap.add_argument("data_dir"); ap.add_argument("out_dir")
    ap.add_argument("--contexts", default="1024,8192")
    ap.add_argument("--decode", type=int, default=256)
    ap.add_argument("--lo", type=int, default=16); ap.add_argument("--hi", type=int, default=42)
    ap.add_argument("--alpha", type=float, default=1.5)
    a = ap.parse_args()
    out = pathlib.Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    info = mx.device_info() if hasattr(mx, "device_info") else mx.metal.device_info()
    mx.set_wired_limit(int(info["max_recommended_working_set_size"]))
    model, processor = load(a.base_dir)
    tok = getattr(processor, "tokenizer", processor)
    lm = model.language_model
    layers = lm.model.layers
    assert 0 <= a.lo <= a.hi < len(layers), (a.lo, a.hi, len(layers))
    Ablation(type(layers[0]))
    loaded = mx.load(a.direction)
    assert len(loaded) == 1, list(loaded)
    r = next(iter(loaded.values()))  # `refusal_direction` (lab) or `language_model.refusal_direction` (published)
    assert r.ndim == 1, r.shape

    prompts = {f"code_{n}": corpus_ids(tok, int(n)) for n in a.contexts.split(",")}
    harmful = json.loads((pathlib.Path(a.data_dir) / "harmful_test.json").read_text())
    prompts["chat"] = chat_ids(tok, harmful[0])

    run(lm, corpus_ids(tok, 256), 8)  # warmup
    meta = {"schema": "macprovider.minimax-abliterated-parity-oracle.v1",
            "base_dir": a.base_dir, "direction_sha256": hashlib.sha256(pathlib.Path(a.direction).read_bytes()).hexdigest(),
            "layers": [a.lo, a.hi], "alpha": a.alpha, "decode": a.decode,
            "versions": {p: md.version(p) for p in ("mlx", "mlx-vlm", "mlx-lm")}, "oracles": {}}
    for variant in ("ablated", "base"):
        for i in range(a.lo, a.hi + 1):
            layers[i]._ablate = (a.alpha, r) if variant == "ablated" else None
        for name, ids in prompts.items():
            stats, greedy, tops = run(lm, ids, a.decode)
            path = out / f"oracle_{variant}_{name}.npz"
            np.savez(path, prompt=np.array(ids, dtype=np.int32), greedy=np.array(greedy, dtype=np.int32),
                     top_idx=np.stack([t[0] for t in tops]), top_logit=np.stack([t[1] for t in tops]))
            gaps = [float(t[1][0] - t[1][1]) for t in tops]
            meta["oracles"][path.name] = {**stats, "min_top2_gap_first16": min(gaps)}
            print(f"ORACLE_WRITTEN {path.name} prompt={len(ids)} decode_tps={stats['decode_tps']:.1f}", flush=True)
    for name in prompts:
        a_g = np.load(out / f"oracle_ablated_{name}.npz")["greedy"]
        b_g = np.load(out / f"oracle_base_{name}.npz")["greedy"]
        diff = int(np.argmax(a_g != b_g)) if (a_g != b_g).any() else -1
        meta["oracles"][f"first_ablated_vs_base_difference_{name}"] = diff
        print(f"ORACLE_CONTROL {name} first_difference={diff}", flush=True)
    (out / "oracle_meta.json").write_text(json.dumps(meta, indent=2) + "\n")


if __name__ == "__main__":
    main()
