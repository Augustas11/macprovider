# Cross-chip per-layer hidden-state divergence (#2414)

Question: for the same model, weights and token ids, how far apart are the
per-layer hidden states of an M3 Ultra and an M5, and is that gap clearly
smaller than the gap a quantization swap produces on one Mac?

Model: Llama-3.2-3B-Instruct in 4-bit, 8-bit and bf16, revisions pinned in
`inputs.json`. Inputs: three 512-token sequences (prose, Swift, Go) taken from
this repo, stored as token ids, 32 sampled positions, full dumps of layers 3,
11 and 19 for injection. Every run is one teacher-forced forward pass in its
own process; nothing is generated.

## Files

| file | what it does |
|---|---|
| `make_inputs.py` | builds `inputs.json` (already committed; rerun only to change the inputs) |
| `dump.py` | one run: per-layer outputs at the sampled positions, full layer-k outputs, final-logit top-16 and teacher-token logprobs, host / chip / macOS / mlx metadata, weight hashes; `--inject` replaces layer k's output with another run's |
| `run-arms.sh` | every arm on one Mac (`--host m3u` or `--host m5`), two reps each, plus injection runs |
| `compare.py` | offline: gate, arm checks, injection plumbing, separation tables, injection tables, final logits |
| `requirements.txt` | pinned mlx, mlx-lm, numpy, huggingface_hub; both Macs use the same versions |

## Arms

| host | arm | env |
|---|---|---|
| M3 Ultra | `default` | none |
| M3 Ultra | `tf32off` | `MLX_ENABLE_TF32=0` (inert before generation 17: must be bit-identical to `default`) |
| M5 | `default` | none |
| M5 | `tf32off` | `MLX_ENABLE_TF32=0` (fp32 matmul only) |
| M5 | `arch-m3u` | `MLX_METAL_GPU_ARCH` = the M3 Ultra's architecture string from its run (moves kernel selection and NAX) |

The M5 must run macOS 26.2 or later, otherwise MLX does not select the
generation-17 (NAX) kernels and the run measures nothing. `dump.py` records
the macOS build and the architecture MLX reports.

## Procedure

Same pinned environment on both Macs:

```bash
python3 -m venv "$VENV" && "$VENV/bin/pip" install -r scripts/lab/hidden-state-2414/requirements.txt
```

1. M3 Ultra, inside a lab window with the provider paused (forward passes
   plus model loads; well under an hour with the models present):

   ```bash
   scripts/lab/hidden-state-2414/run-arms.sh --host m3u --fetch \
     --models-root ~/lab-2414/models --out ~/lab-2414/runs/m3u --python "$VENV/bin/python"
   ```

2. Copy `~/lab-2414/runs/m3u` to the M5. The M5 runs need its `base/`
   directory for the architecture string and the injection sources.
3. M5, with the local provider paused:

   ```bash
   scripts/lab/hidden-state-2414/run-arms.sh --host m5 --fetch \
     --models-root ~/lab-2414/models --out ~/lab-2414/runs/m5 \
     --ref-runs ~/lab-2414/runs/m3u --python "$VENV/bin/python"
   ```

4. Anywhere with numpy:

   ```bash
   python3 scripts/lab/hidden-state-2414/compare.py ~/lab-2414/runs --out ~/lab-2414/compare
   ```

   Exit 0: every check ran. Exit 1: a gate failed (rep0 and rep1 of an arm
   differ; the difference is printed as that arm's noise floor). Exit 2:
   unusable input (mixed inputs, weight hashes differ between Macs, or a
   self-injection run is not bit-identical to its base run).

## Reading the result

Statistics per hidden-state vector: `max_abs`, `rel_l2`, `one_minus_cos`,
`one_minus_top128` (1 minus the overlap of the 128 largest-magnitude
indices). Layers are grouped into four ranges.

- Honest: M3 Ultra `default` vs one M5 arm, same variant.
- Dishonest: one Mac, `default` arm, the claimed variant vs another variant
  (both Macs contribute).
- Separation = smallest dishonest value / largest honest value. Above 1 the
  distributions do not overlap in that cell.
- Injection: the M3 Ultra's layer-k output is fed into the M5's layers
  k+1..k+n (n = 1, 4, 8) and compared with the M3 Ultra's own layer k+n. The
  dishonest side feeds the same tensor into another variant on the M5. This
  is the number a per-stage audit of a shard group would use.

Stop rule (from the issue): if honest and dishonest overlap at every layer
range and under every arm, record the numbers and do not build a per-stage
audit.

The result note goes in `docs/research/`.
