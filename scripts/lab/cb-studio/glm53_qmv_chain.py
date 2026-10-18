"""Dependent one-token quantized matmul chain (GLM-5.3 T3, epic #2029).

Same method as `GLMBench --qmv-chain`: 200 back-to-back x_{i+1} = qmm(x_i)
calls on an 8192 x 8192 affine matrix (group 64) per bit width, best of 3,
for comparing the decode qmv speed of two MLX cores.
Usage: python -I glm53_qmv_chain.py
"""

import time

import mlx.core as mx


def main():
    n = 8192
    if mx.metal.is_available():
        mx.set_wired_limit(mx.device_info()["max_recommended_working_set_size"])
    for bits in (8, 6, 5, 4):
        w = mx.random.randint(0, 2**31 - 1, (n, n * bits // 32)).astype(mx.uint32)
        s = (0.0001 + 0.0001 * mx.random.uniform(shape=(n, n // 64))).astype(mx.bfloat16)
        b = (-0.001 * mx.random.uniform(shape=(n, n // 64))).astype(mx.bfloat16)
        x = (0.1 * mx.random.normal((1, n))).astype(mx.bfloat16)
        mx.eval(w, s, b, x)

        def chain(count):
            y = x
            for _ in range(count):
                y = mx.quantized_matmul(y, w, s, b, transpose=True, group_size=64, bits=bits)
            return y

        mx.eval(chain(10))
        best = float("inf")
        for _ in range(3):
            t = time.perf_counter()
            mx.eval(chain(200))
            best = min(best, time.perf_counter() - t)
        moved = w.nbytes + s.nbytes + b.nbytes
        print(f"chain: bits={bits} {best / 200 * 1e6:.1f} us/call {moved * 200 / best / 1e9:.1f} GB/s "
              f"(mlx {mx.__version__})", flush=True)


if __name__ == "__main__":
    main()
