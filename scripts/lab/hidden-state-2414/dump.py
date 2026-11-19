"""Teacher-forced per-layer hidden-state dump for one arm of #2414.

One process = one run: load one model variant, run each fixed token-id
sequence of inputs.json through the model in a single forward pass (no KV
cache, no chunking), and save:

  seq<i>.npz
    layers        float32 [num_layers, P, hidden]  each decoder layer's output
                  (the residual stream) at the P sampled positions
    full_<k>      float32 [T, hidden]  layer k's output at every position, for
                  each k in inputs.json `full_layers` (injection sources)
    top_ids       int32   [T, 16]  final-logit top-16 token ids, descending
    top_logprobs  float32 [T, 16]  their log-probabilities
    next_logprob  float32 [T-1]    log-probability of the teacher token t+1
  meta.json       host, chip, GPU architecture as MLX sees it, macOS build,
                  mlx / mlx-lm versions, env flags, weight hashes, per-file
                  content sha256 of every npz

Injection mode (--inject <run dir> --inject-layer k): the output of layer k is
replaced, at every position, by layer k's output from the source run, and the
run continues through the remaining layers of this model. Hidden states are
stored as float32 and cast back to the activation dtype on injection, which is
exact for bf16/fp16 activations; injecting a run into a repeat of itself must
therefore reproduce it bit for bit (compare.py checks this).

Usage:
  python -I dump.py --inputs inputs.json --model <dir> --variant 4bit \
      --host m5 --arm default --out <dir> [--inject <run> --inject-layer 11]
"""

import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
from pathlib import Path

import mlx.core as mx
import numpy as np

TOP_K = 16
ENV_FLAGS = ("MLX_ENABLE_TF32", "MLX_METAL_GPU_ARCH")


def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout.strip()
    except OSError:
        return ""


def sha256_file(path, chunk=1 << 24):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def content_sha256(arrays):
    """Hash of the array contents (npz files carry zip timestamps, so file
    bytes differ between identical runs)."""
    h = hashlib.sha256()
    for k in sorted(arrays):
        a = np.ascontiguousarray(arrays[k])
        h.update(f"{k}|{a.dtype.str}|{a.shape}|".encode())
        h.update(a.tobytes())
    return h.hexdigest()


def weight_hashes(model_dir):
    d = Path(model_dir)
    files = sorted(p for p in d.iterdir() if p.suffix == ".safetensors" or p.name == "config.json")
    if not any(p.suffix == ".safetensors" for p in files):
        raise SystemExit(f"{model_dir}: no .safetensors files")
    return {p.name: sha256_file(p.resolve()) for p in files}


def host_meta():
    import mlx_lm

    info = mx.device_info()
    return {
        "chip": sh(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "hw_model": sh(["sysctl", "-n", "hw.model"]),
        "macos": sh(["sw_vers", "-productVersion"]),
        "macos_build": sh(["sw_vers", "-buildVersion"]),
        "python": sys.version.split()[0],
        "mlx": mx.__version__,
        "mlx_lm": mlx_lm.__version__,
        "numpy": np.__version__,
        "gpu_architecture": info.get("architecture"),
        "gpu_device_name": info.get("device_name"),
        "memory_size": info.get("memory_size"),
        "env": {k: os.environ.get(k) for k in ENV_FLAGS},
        "platform": platform.platform(),
    }


class LayerTap:
    """Patches the decoder-layer class so each instance's output is captured
    (and, for the injection layer, replaced)."""

    def __init__(self, layers):
        self.index = {id(layer): i for i, layer in enumerate(layers)}
        self.outputs = {}
        self.inject = None  # (layer index, mx.array) or None
        classes = {type(layer) for layer in layers}
        if len(classes) != 1:
            raise SystemExit(f"expected one decoder-layer class, got {classes}")
        cls = classes.pop()
        original = cls.__call__
        tap = self

        def call(self, *a, **kw):
            y = original(self, *a, **kw)
            i = tap.index.get(id(self))
            if i is None:
                return y
            if tap.inject is not None and tap.inject[0] == i:
                src = tap.inject[1]
                if src.shape != y.shape:
                    raise SystemExit(f"inject layer {i}: shape {src.shape} != {y.shape}")
                y = src.astype(y.dtype)
            tap.outputs[i] = y
            return y

        cls.__call__ = call


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--inputs", required=True)
    ap.add_argument("--model", required=True, help="local model directory")
    ap.add_argument("--variant", required=True, help="key of inputs.json `models` (4bit, 8bit, bf16)")
    ap.add_argument("--host", required=True, help="label, e.g. m3u or m5")
    ap.add_argument("--arm", required=True, help="label, e.g. default, tf32off, arch-m3u")
    ap.add_argument("--rep", type=int, default=0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--inject", help="source run directory (injection mode)")
    ap.add_argument("--inject-layer", type=int)
    args = ap.parse_args()

    inputs = json.loads(Path(args.inputs).read_text())
    if inputs.get("schema") != "hidden-state-2414-inputs-v1":
        raise SystemExit(f"{args.inputs}: not a hidden-state-2414-inputs-v1 file")
    if args.variant not in inputs["models"]:
        raise SystemExit(f"unknown variant {args.variant}")
    if (args.inject is None) != (args.inject_layer is None):
        raise SystemExit("--inject and --inject-layer go together")
    positions = inputs["positions"]
    full_layers = inputs["full_layers"]

    out = Path(args.out)
    if out.exists() and any(out.iterdir()):
        raise SystemExit(f"{out}: exists and is not empty; use a fresh directory per run")
    out.mkdir(parents=True, exist_ok=True)

    src_meta = None
    if args.inject:
        src_meta = json.loads((Path(args.inject) / "meta.json").read_text())
        if args.inject_layer not in src_meta["full_layers"]:
            raise SystemExit(f"source run has no full dump of layer {args.inject_layer}")
        if src_meta["inputs_sha256"] != sha256_file(args.inputs):
            raise SystemExit("source run used different inputs")

    hashes = weight_hashes(args.model)

    from mlx_lm import load

    model, _ = load(args.model)
    layers = list(model.model.layers)
    if max(full_layers) >= len(layers):
        raise SystemExit(f"full layer {max(full_layers)} >= {len(layers)} layers")
    tap = LayerTap(layers)

    files = {}
    for si, seq in enumerate(inputs["sequences"]):
        ids = mx.array(seq["ids"], dtype=mx.int32)[None]
        tap.outputs = {}
        tap.inject = None
        if args.inject:
            with np.load(Path(args.inject) / f"seq{si}.npz") as src:
                tap.inject = (args.inject_layer, mx.array(src[f"full_{args.inject_layer}"])[None])
        logits = model(ids)
        if len(tap.outputs) != len(layers):
            raise SystemExit(f"captured {len(tap.outputs)} of {len(layers)} layers")
        logits = logits[0].astype(mx.float32)
        logprobs = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
        order = mx.argsort(-logprobs, axis=-1)[:, :TOP_K]
        top_lp = mx.take_along_axis(logprobs, order, axis=-1)
        nxt = mx.array(seq["ids"][1:], dtype=mx.int32)[:, None]
        next_lp = mx.take_along_axis(logprobs[:-1], nxt, axis=-1)[:, 0]
        pos = mx.array(positions, dtype=mx.int32)
        sampled = mx.stack([tap.outputs[i][0][pos] for i in range(len(layers))]).astype(mx.float32)
        full = {f"full_{k}": tap.outputs[k][0].astype(mx.float32) for k in full_layers}
        mx.eval(sampled, order, top_lp, next_lp, *full.values())

        arrays = {
            "layers": np.array(sampled),
            "top_ids": np.array(order.astype(mx.int32)),
            "top_logprobs": np.array(top_lp),
            "next_logprob": np.array(next_lp),
        }
        arrays.update({k: np.array(v) for k, v in full.items()})
        name = f"seq{si}.npz"
        np.savez(out / name, **arrays)
        files[name] = content_sha256(arrays)

    meta = {
        "schema": "hidden-state-2414-run-v1",
        "host": args.host,
        "arm": args.arm,
        "variant": args.variant,
        "rep": args.rep,
        "model_dir": str(Path(args.model).resolve()),
        "model": inputs["models"][args.variant],
        "weights_sha256": hashes,
        "inputs_sha256": sha256_file(args.inputs),
        "positions": positions,
        "full_layers": full_layers,
        "num_layers": len(layers),
        "activation_dtype": str(tap.outputs[0].dtype),
        "inject": None if not args.inject else {
            "source": str(Path(args.inject).resolve()),
            "layer": args.inject_layer,
            "source_host": src_meta["host"],
            "source_arm": src_meta["arm"],
            "source_variant": src_meta["variant"],
            "source_rep": src_meta["rep"],
        },
        "files_sha256": files,
        **host_meta(),
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=1) + "\n")
    print(f"dump: {args.host}/{args.arm}/{args.variant} rep{args.rep}"
          f"{' inject L' + str(args.inject_layer) if args.inject else ''}"
          f" arch={meta['gpu_architecture']} -> {out}")


if __name__ == "__main__":
    main()
