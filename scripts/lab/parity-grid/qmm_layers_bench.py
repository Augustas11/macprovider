#!/usr/bin/env python3
"""Time the quantized matmuls of one decode step on a model's real weights.

A standalone kernel harness that dispatches one kernel on one buffer did not
predict decode speed (it put two kernels within 10% that are 15% apart end to
end). This runs every quantized linear of the model once per pass, in file
order, on its real weights, through MLX's own dispatch, with a fresh random
input per layer: the weight bytes read per pass match a real decode step.

It measures only the quantized matmuls, not attention, norms or host code.
Use it to compare kernel routes inside one build:

    MLX_METAL_SMALL_M_ROW_INVARIANT=1 python qmm_layers_bench.py --model-path DIR
    MLX_METAL_SMALL_M_ROW_INVARIANT=0 python qmm_layers_bench.py --model-path DIR

The variable is read once per process, so each route needs its own run. Needs
only `mlx` (no mlx_lm). Prints one JSON object.
"""
import argparse
import glob
import json
import os
import statistics
import time


def quantized_layers(model_path, default_gs, default_bits):
    import mlx.core as mx

    tensors = {}
    for f in sorted(glob.glob(os.path.join(model_path, "*.safetensors"))):
        tensors.update(mx.load(f))
    layers = []
    for key in tensors:
        if not key.endswith(".scales"):
            continue
        base = key[: -len(".scales")]
        w, s = tensors.get(base + ".weight"), tensors[key]
        b = tensors.get(base + ".biases")
        if w is None or b is None or w.ndim != 2 or "embed" in base:
            continue
        n, groups = s.shape
        # Per-layer overrides are not in the tensors; find the (group, bits)
        # pair that matches the packed width.
        found = None
        for gs in (default_gs, 32, 64, 128):
            for bits in (default_bits, 4, 8, 2, 3, 5, 6):
                if w.shape[1] * 32 == groups * gs * bits:
                    found = (gs, bits)
                    break
            if found:
                break
        if not found:
            continue
        gs, bits = found
        layers.append((base, w, s, b, gs, bits, groups * gs, n))
    return layers


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--rows", type=int, default=1)
    ap.add_argument("--passes", type=int, default=30)
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--chain", action="store_true",
                    help="make each layer's input depend on the previous output, "
                         "as in a real decode, so the GPU cannot overlap layers")
    args = ap.parse_args(argv)

    import mlx.core as mx

    cfg = json.load(open(os.path.join(args.model_path, "config.json")))
    q = cfg.get("quantization") or {}
    layers = quantized_layers(args.model_path, q.get("group_size", 64), q.get("bits", 4))
    if not layers:
        raise SystemExit("no quantized linear layers found")
    mx.eval([t for layer in layers for t in layer[1:4]])

    def inputs():
        xs = [mx.random.normal((args.rows, k)).astype(s.dtype)
              for (_, _, s, _, _, _, k, _) in layers]
        mx.eval(xs)
        return xs

    def one_pass(xs, subset=None):
        outs = []
        prev = None
        for i, (_, w, s, b, gs, bits, _, _) in enumerate(layers):
            if subset is not None and i not in subset:
                continue
            x = xs[i]
            if args.chain and prev is not None:
                x = x + (prev[:, :1] * 0).astype(x.dtype)
            prev = mx.quantized_matmul(
                x, w, scales=s, biases=b, transpose=True, group_size=gs, bits=bits)
            outs.append(prev)
        if args.chain:
            outs = outs[-1:]
        t = time.perf_counter()
        mx.eval(outs)
        return (time.perf_counter() - t) * 1e3

    def measure(subset=None):
        times = []
        for i in range(args.warmup + args.passes):
            ms = one_pass(inputs(), subset)
            if i >= args.warmup:
                times.append(ms)
        return statistics.median(times), min(times)

    total_med, total_min = measure()
    classes = {}
    for i, (_, _, _, _, gs, bits, k, n) in enumerate(layers):
        classes.setdefault((k, n, bits, gs), set()).add(i)
    by_class = []
    for (k, n, bits, gs), idx in sorted(classes.items(), key=lambda kv: -len(kv[1])):
        med, _ = measure(idx)
        by_class.append({"K": k, "N": n, "bits": bits, "group_size": gs,
                         "layers": len(idx), "median_ms": round(med, 3),
                         "us_per_layer": round(med * 1e3 / len(idx), 1)})
    print(json.dumps({
        "model": os.path.basename(os.path.normpath(args.model_path)),
        "rows": args.rows,
        "chain": args.chain,
        "row_invariant_env": os.environ.get("MLX_METAL_SMALL_M_ROW_INVARIANT", "unset"),
        "mlx": mx.__version__,
        "layers": len(layers),
        "pass_median_ms": round(total_med, 3),
        "pass_min_ms": round(total_min, 3),
        "by_class": by_class,
    }, indent=1))


if __name__ == "__main__":
    main()
