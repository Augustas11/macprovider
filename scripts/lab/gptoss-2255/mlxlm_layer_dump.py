"""Dump gpt-oss per-layer tensors from mlx-lm for one teacher-forced prompt (#2255).

The native side is the fork's env-gated `GPTOSSLayerDump`
(`MLX_LM_GPTOSS_LAYER_DUMP=<dir>`) driven by `macprovider-cli glm-parity`.
This script writes the same tensors from mlx-lm, with the same names and the
same prompt chunking (`glm-parity` "glm" mode: chunks of --prefill-step-size,
last one included):

  mlxlm_f<forward>_embed.npy         embeddings
  mlxlm_f<forward>_layer00_attn.npy  layer-0 attention output (before the residual)
  mlxlm_f<forward>_layer<NN>.npy     each decoder layer's output
  mlxlm_f<forward>_final_norm.npy    the final RMSNorm output
  manifest.jsonl                     one line per forward

Every tensor is stored as float32 (lossless from bf16). Compare the two
directories with compare_layer_dump.py.

Usage:
  python -I mlxlm_layer_dump.py --model <gpt-oss dir> --oracle <oracle.json> \
      --out <dir> [--prefill-step-size 2048] [--forwards 4]
"""

import argparse
import json
from pathlib import Path

import mlx.core as mx
import numpy as np
from mlx_lm import load


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True)
    ap.add_argument("--oracle", required=True, help="glm-parity oracle JSON (its `prompt` is the input)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--prefill-step-size", type=int, default=2048)
    ap.add_argument("--forwards", type=int, default=4, help="dump at most this many forwards")
    args = ap.parse_args()

    oracle = json.loads(Path(args.oracle).read_text())
    if oracle.get("schema") != "glm-parity-oracle-v1":
        raise SystemExit(f"{args.oracle}: not a glm-parity-oracle-v1 file")
    prompt = [int(t) for t in oracle["prompt"]]
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = out / "manifest.jsonl"
    manifest.write_text("")

    model, _ = load(args.model)
    inner = model.model
    layers = list(inner.layers)
    state = {"forward": None}

    def write(array, name):
        f = state["forward"]
        if f is None:
            return
        mx.eval(array)
        np.save(out / f"mlxlm_f{f}_{name}.npy", np.array(array.astype(mx.float32)))

    def wrap(cls, names):
        """Patch `cls.__call__` so the instances in `names` (id -> name) dump their output."""
        original = cls.__call__

        def call(self, *a, **kw):
            y = original(self, *a, **kw)
            name = names.get(id(self))
            if name is not None:
                write(y, name)
            return y

        cls.__call__ = call

    # Classes can be shared (RMSNorm also backs the per-layer norms), so each
    # patch matches by instance and is applied once per class.
    targets = {}
    targets.setdefault(type(inner.embed_tokens), {})[id(inner.embed_tokens)] = "embed"
    targets.setdefault(type(layers[0].self_attn), {})[id(layers[0].self_attn)] = "layer00_attn"
    for i, layer in enumerate(layers):
        targets.setdefault(type(layer), {})[id(layer)] = f"layer{i:02d}"
    targets.setdefault(type(inner.norm), {})[id(inner.norm)] = "final_norm"
    for cls, names in targets.items():
        wrap(cls, names)

    cache = model.make_cache()
    forward = 0
    start = 0
    while start < len(prompt):
        end = min(start + args.prefill_step_size, len(prompt))
        state["forward"] = forward if forward < args.forwards else None
        if state["forward"] is not None:
            line = {"forward": forward, "tokens": end - start, "cache_offset": cache[0].offset}
            with manifest.open("a") as fh:
                fh.write(json.dumps(line, separators=(",", ":")) + "\n")
        logits = model(mx.array(prompt[start:end])[None], cache=cache)
        mx.eval(logits)
        forward += 1
        start = end
    state["forward"] = None
    print(f"mlxlm_layer_dump: {forward} forward(s), {min(forward, args.forwards)} dumped to {out}")


if __name__ == "__main__":
    main()
