#!/usr/bin/env python3
"""Measured matmul peak of this Mac's GPU, for the prefill ceiling (AGENTS.md swarm rule 1).

usage: matmul_peak.py --out peak.json [--sizes 4096,8192] [--iters 20]

Runs under a venv with mlx. For each size S: a bfloat16 GEMM [S, S] x [S, S], and a
4-bit affine quantized matmul (group 64, the oQ4 layer format) of [S, S] activations by
an [S, S] weight, the kernel prefill's projections and experts run. Each shape gets 3
warm-up calls, then `--iters` timed calls, each evaluated alone; the best call is the
peak (TFLOP/s = 2*M*N*K / seconds). Prints one PEAK line per kernel and writes:

  {"device": ..., "mlx": ..., "kernels": {"bf16_gemm": {"S": tflops, ...},
   "q4_qmm": {...}}, "bf16_tflops": max, "q4_tflops": max}
"""

from __future__ import annotations

import argparse
import json
import sys
import time


def best_seconds(fn, iters: int) -> float:
    import mlx.core as mx

    for _ in range(3):
        mx.eval(fn())
    best = float("inf")
    for _ in range(iters):
        t0 = time.perf_counter()
        mx.eval(fn())
        best = min(best, time.perf_counter() - t0)
    return best


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--sizes", default="4096,8192")
    ap.add_argument("--iters", type=int, default=20)
    a = ap.parse_args(argv)
    import mlx.core as mx

    sizes = [int(s) for s in a.sizes.split(",") if s]
    kernels = {"bf16_gemm": {}, "q4_qmm": {}}
    mx.random.seed(0)
    for s in sizes:
        x = mx.random.normal((s, s)).astype(mx.bfloat16)
        w = mx.random.normal((s, s)).astype(mx.bfloat16)
        sec = best_seconds(lambda: x @ w, a.iters)
        kernels["bf16_gemm"][str(s)] = 2 * s ** 3 / sec / 1e12
        wq, scales, biases = mx.quantize(w, group_size=64, bits=4)
        sec = best_seconds(
            lambda: mx.quantized_matmul(x, wq, scales, biases, transpose=True, group_size=64, bits=4),
            a.iters,
        )
        kernels["q4_qmm"][str(s)] = 2 * s ** 3 / sec / 1e12
        for k in kernels:
            print(f"PEAK {k} S={s} tflops={kernels[k][str(s)]:.2f}", flush=True)
        del x, w, wq, scales, biases
        mx.clear_cache()
    info = mx.metal.device_info() if hasattr(mx, "metal") else {}
    out = {
        "device": str(info.get("device_name", "")),
        "mlx": getattr(mx, "__version__", ""),
        "iters": a.iters,
        "kernels": kernels,
        "bf16_tflops": max(kernels["bf16_gemm"].values()),
        "q4_tflops": max(kernels["q4_qmm"].values()),
    }
    with open(a.out, "w") as f:
        json.dump(out, f, indent=2, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
