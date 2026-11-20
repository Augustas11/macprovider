# Cross-chip per-layer hidden-state divergence: M3 Ultra vs M5 (2026-11-19)

Related: #2414. Tooling: `scripts/lab/hidden-state-2414/` (README there has
the procedure). Raw runs are not committed; every number below comes from
`compare.py` over the run directories, and the tables can be regenerated from
those runs.

## Answer

**The stop rule does not fire.** With `MLX_METAL_GPU_ARCH` set on the M5 to the
M3 Ultra's architecture string (`applegpu_g15d`), the M5 reproduces the M3
Ultra **bit for bit**. That holds for every variant (4-bit, 8-bit, bf16), every
layer, and every final logit, and also when M3 Ultra activations are injected
mid-model. The honest gap is zero, so any quantization swap is detectable by
exact comparison. No tolerance is needed.

Without the override (the M5's default kernels):

- A 4-bit claim separates from a quantization swap at every layer range, by a
  factor of 2.0 or more on every statistic.
- 8-bit and bf16 claims overlap on whole-model hidden states in most cells
  (8-bit separates only in L0-6, on rel_l2 and 1 - cos). Elsewhere the
  8-bit-vs-bf16 swap is smaller than the honest cross-chip gap.
- In the injection (shard-stage) shape, `max_abs` separates a 4-bit stage
  from an 8-bit one, and the reverse, in every cell, by a factor of 4.0 to 48.
  An 8-bit stage swapped for bf16 could not be injected (different dtype) and
  was not measured.

`MLX_ENABLE_TF32=0` changes nothing on either Mac for these models. Their
activations are fp16 (quantized) or bf16, never fp32.

## Setup

| | M3 Ultra (Mac Studio) | M5 (MacBook) |
|---|---|---|
| macOS | 27.0.1 (26A434) | 27.0.1 (26A434) |
| mlx / mlx-lm / numpy | 0.32.4 / 0.32.2 / 2.5.5 | same |
| GPU architecture (MLX) | `applegpu_g15d` | `applegpu_g17g` (default arms) |

- **Model:** Llama-3.2-3B-Instruct, mlx-community 4-bit, 8-bit and bf16 at the
  pinned revisions in `inputs.json`. Weight hashes are identical on both Macs.
  Activations are float16 for 4-bit and 8-bit, and bfloat16 for bf16.
- **Inputs:** three 512-token sequences (prose, Swift, Go), 32 sampled
  positions each, and full layer-k dumps at k = 3, 11, 19.
- **Runs:** each run is one teacher-forced forward pass in its own process.
  The M3 Ultra did 15 runs, the M5 did 66.
- **Gate:** every arm's rep0 and rep1 are bit-identical on both Macs, so the
  same-Mac noise floor is 0.
- **Plumbing checks:** self-injection reproduces the base run bit for bit, and
  every injection run's layer k equals its source.

## Whole-model hidden states, M5 default arm

Separation is the smallest dishonest difference divided by the largest honest
difference. Above 1, the honest and dishonest distributions do not overlap.

- **Honest:** M3 Ultra vs M5, same weights.
- **Dishonest:** same Mac, claimed variant vs another quantization, on both Macs.
- **n:** 672 honest vectors per range, 2688 dishonest.

| claimed | stat | L0-6 | L7-13 | L14-20 | L21-27 |
|---|---|---|---|---|---|
| 4bit | max_abs | 2.8 | 11.9 | 4.85 | 5.31 |
| 4bit | rel_l2 | 7.83 | 3.09 | 2.39 | 2.29 |
| 4bit | 1 - cos | 60.8 | 8.88 | 5.37 | 4.95 |
| 4bit | 1 - top-128 overlap | 2 | 5 | 3.5 | 3.33 |
| 8bit | max_abs | 0.297 | 0.277 | 0.446 | 0.292 |
| 8bit | rel_l2 | 1.24 | 0.247 | 0.564 | 0.696 |
| 8bit | 1 - cos | 1.47 | 0.0599 | 0.152 | 0.322 |
| 8bit | 1 - top-128 overlap | 0 | 0 | 0 | 0 |
| bf16 | max_abs | 0.0212 | 0.0865 | 0.0503 | 0.0292 |
| bf16 | rel_l2 | 0.166 | 0.0783 | 0.0642 | 0.0749 |
| bf16 | 1 - cos | 0.0266 | 0.00596 | 0.00193 | 0.00371 |
| bf16 | 1 - top-128 overlap | 0 | 0 | 0 | 0 |

- **8-bit overlaps** because its nearest dishonest neighbour, bf16, is close to
  it. The smallest dishonest `max_abs` in L7-13 is 0.0088, while the honest
  maximum is 0.032.
- **bf16 overlaps further:** bf16 is the variant whose honest cross-chip gap is
  largest. Its honest max rel_l2 is 0.163 in L21-27, against 0.013 for 4-bit.
- **The `tf32off` arm gives the same table**, because its runs are
  bit-identical to `default` on the M5.
- **The `arch-m3u` arm** has honest maximum 0 in every cell. Its separation is
  infinite wherever the dishonest minimum is above 0; for 8-bit and bf16,
  top-128 overlap is 0/0 (both sides 0) in every range.

## Injection (shard stage), M5 default arm

Each M3 Ultra layer-k output is fed into the M5's layers k+1..k+n and compared
with the M3 Ultra's own layer k+n. On the dishonest side, the same tensor is fed
into the M5's other variant of the same activation dtype (4-bit and 8-bit are
each other's dishonest pair). bf16 has no same-dtype partner, so it has no
dishonest side here. Cross-dtype injection would round the tensor, so those
pairs are skipped.

`max_abs` separation, smallest dishonest divided by largest honest, per k and n:

| claimed | k | n=1 | n=4 | n=8 |
|---|---|---|---|---|
| 4bit | 3 | 29.2 | 23.7 | 7.12 |
| 4bit | 11 | 48.4 | 17.7 | 10.1 |
| 4bit | 19 | 4.0 | 8.67 | 15.9 |
| 8bit | 3 | 30.4 | 21.3 | 14.8 |
| 8bit | 11 | 22.4 | 20.8 | 13.8 |
| 8bit | 19 | 4.0 | 9.71 | 15.2 |

- **Honest `max_abs`** for 4-bit and 8-bit is 0.00098 to 0.0078 after one
  layer and 0.0063 to 0.031 after eight. bf16 reaches 0.0156 after one layer
  and 0.055 to 0.31 after eight (0.31 at k = 19).
- **n:** 96 vectors per cell (3 sequences × 32 positions).
- **Other statistics:** rel_l2, 1 - cos and top-128 overlap separate in some
  cells and overlap in others. Their ratios run from 0 to 3.5e3, depending
  on the cell. `compare.py` prints the full per-statistic table.
- **With `arch-m3u`,** all nine honest injection runs (3 variants × 3 k) are
  bit-identical to the M3 Ultra's own run of the same variant.

## Final logits, teacher-forced

Top-1 covers 3 × 512 = 1536 positions; the teacher-logprob delta covers
3 × 511 = 1533.

| variant | M5 arm | top-1 agree | max abs Δ teacher logprob | M3 Ultra top-2 logprob gap at each disagreement |
|---|---|---|---|---|
| 4bit | default | 1536/1536 | 0.0387 | none |
| 8bit | default | 1534/1536 | 0.0341 | 0, 0.0078 |
| bf16 | default | 1524/1536 | 0.225 | 0, 0.0625, 0.0625, 0, 0.0625, 0.0625, 0, 0, 0.125, 0.125, 0, 0 |
| all | arch-m3u | 1536/1536 | 0 | none |

The quantization swaps, each on one Mac:

| swap | M3 Ultra top-1 | M3 Ultra max Δ | M5 top-1 | M5 max Δ |
|---|---|---|---|---|
| 4bit vs 8bit | 1357/1536 | 3.26 | 1357/1536 | 3.27 |
| 4bit vs bf16 | 1351/1536 | 3.28 | 1354/1536 | 3.24 |
| 8bit vs bf16 | 1518/1536 | 0.309 | 1518/1536 | 0.378 |

What this means for the SPEC-036-R022 statement, "a logit or less":

- **Holds across M3 Ultra and M5 for this model.** The largest honest
  teacher-logprob move is 0.225 nats, on bf16. Every disagreement is at a top-2
  gap of 0.125 or less.
- **The 8-bit-vs-bf16 swap has the same magnitude** as the honest bf16 gap
  (0.309 on the M3 Ultra and 0.378 on the M5, vs 0.225). On the maxima alone, a final-logit tolerance would not separate them; the
  per-position distributions were not compared.

## What it decides

1. **Per-stage audit (SPEC-051).**
   - *Exact audit:* feasible on this pair, in one direction. An M5 that sets
     `MLX_METAL_GPU_ARCH` to the M3 Ultra's architecture string, on the same
     macOS build and mlx version, reproduced the M3 Ultra's activations
     exactly. The reverse (an M3 Ultra forcing `applegpu_g17g`)
     was not run.
     The audit is then an exact comparison, which also catches deviations that
     a tolerance audit would miss.
   - *Tolerance audit at default kernels:* would catch a 4-bit/8-bit stage
     swap with `max_abs` at a threshold between the honest and dishonest
     columns above (96 vectors per cell). An 8-bit stage swapped for bf16 was
     not measured, and on whole-model states that swap overlaps the honest
     gap. It would not work for bf16 claims.
   - *Before building on the exact path,* show that the exact match holds:
     - in the other direction (older chip forcing the newer string);
     - on another chip pair (for example M1/M2 vs M5, or M4 vs M3 Ultra);
     - for larger models and other model families (MoE, hybrid attention);
     - under the real serving path (KV cache, chunked prefill, batched CB rows)
       rather than one uncached forward pass.

     It was measured here only with both Macs on the same macOS build and
     mlx 0.32.4.
2. **SPEC-036 tolerance rationale.** Supported for this model, as covered under
   "Final logits" above. The cold-start prior needs no change.
3. **Upstream (ml-explore/mlx-lm#1280).**
   - The per-layer and cross-chip top-2-gap data here add to the thread. The
     report there has token counts; the two comments give top-2 gaps measured
     on a single chip. These are teacher-forced Llama-3B numbers, not the
     reporter's model or a greedy fork.
   - The architecture override reproduces M3 Ultra output on an M5 exactly.
     That makes it a usable debugging aid for cross-chip divergence reports.

## Limits

- **Scope:** one model (3B, dense, Llama), one chip pair, one macOS build, one
  mlx version. The override was tested only as the M5 emulating the M3 Ultra.
- **No cache or batching:** uncached single-sequence forward passes only. No
  KV cache, chunking or batching.
- **Speed not measured:** the throughput cost of forcing `applegpu_g15d` on the
  M5 (no NAX kernels) was not measured.
- **Override caveat:** `MLX_METAL_GPU_ARCH` is a documented MLX environment
  variable (`docs/src/usage/environment_variables.rst`, present at v0.32.4).
  The docs warn that forcing an architecture that does not match the GPU "can
  select incompatible kernels and produce incorrect results". Here the forced
  M5 output equalled the real M3 Ultra output bit for bit, so it was correct
  for this model, but that is no guarantee for other models or versions. A
  future mlx version may also change which kernels the string selects.
