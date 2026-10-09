# Runtime comparison on the served Qwen3.6-35B-A3B artifact (2026-10-09)

Same Mac Studio (M3 Ultra, 256 GB), same MLX 4-bit artifact the network serves
(`mlx-community/Qwen3.6-35B-A3B-4bit`, snapshot `3fed776d…`), same load
generator (`scripts/lab/cb-studio/depth_sweep.py`: closed loop, unique salted
prompts, greedy, streamed, 30 s warmup, 90 s window), live `:8080` provider
paused per runtime. Direct HTTP on the box, not the Malibu API.

Runtimes:

- **ours-w1**: campaign lab build, hybrid decode window 1 (today's production
  rule for this model).
- **ours-w16**: same build, lab-only hybrid decode window 16.
- **mlxlm**: `mlx_lm.server` 0.32.0 on MLX 0.32.3, `--decode-concurrency 32
  --prompt-concurrency 8`.
- **omlx**: oMLX 0.7.0, `--max-concurrent-requests 32 --no-cache`.
- **lmstudio**: LM Studio 0.4.26, MLX engine `mlx-llm` 1.13.1, `--parallel 16`.

Aggregate output tok/s (TTFT p95 in seconds). Data: `sweep.jsonl`.

## Prompt-heavy (1536 prompt tokens, 256 output)

| Concurrent | ours-w1 | ours-w16 | mlx-lm | oMLX | LM Studio |
| --- | --- | --- | --- | --- | --- |
| 1 | 74.3 (1.0) | 76.8 (1.0) | 74.8 (0.7) | **97.1** (0.7) | 83.7 (0.8) |
| 8 | 122.9 (5.1) | 137.1 (5.3) | **190.2** (5.0) | 178.5 (1.5) | 178.2 (3.2) |
| 16 | 136.3 (8.0) | 149.2 (9.5) | **209.8** (10.0) | 193.3 (1.9) | 181.9 (3.3) |

## Output-heavy (1800 prompt tokens, 1024 output)

| Concurrent | ours-w1 | ours-w16 | mlx-lm | oMLX | LM Studio |
| --- | --- | --- | --- | --- | --- |
| 1 | 88.1 (1.1) | 96.5 (1.1) | 87.0 (0.9) | **117.5** (0.8) | 99.1 (0.9) |
| 8 | 171.6 (5.0) | 207.7 (6.1) | 255.6 (9.1) | **278.8** (1.6) | 248.0 (3.6) |
| 16 | 196.0 (8.7) | 269.8 (9.6) | **321.1** (11.9) | 315.6 (1.7) | 291.8 (3.8) |

## Reading

- Our runtime as served today (window 1) is last or tied-last in every
  multi-request cell: 28–43% behind the best runtime at 8 and 16 concurrent.
- The window-16 change closes part of it (output-heavy 16: 196 → 270) but
  ours-w16 still trails mlx-lm, oMLX and LM Studio at 8 and 16.
- oMLX is the strongest overall: highest single-request speed, near-best
  aggregate, and TTFT p95 under 2 s at 16 concurrent where ours and mlx-lm sit
  at 9–12 s.
- Ours is competitive only at 1 request.
- Not yet attributed: these runtimes differ from ours in MLX version (0.32.3 vs
  our 0.31.4), KV layout (contiguous vs paged), MoE kernel (stock vs fused) and
  prompt scheduling. `scripts/lab/cb-studio/isolate-gap-1906.sh` isolates them.
