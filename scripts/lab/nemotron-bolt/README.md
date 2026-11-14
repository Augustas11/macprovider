# Nemotron 3.5 Bolt 74B-A9B reference oracles (#2329)

`bolt_reference_oracle.py` writes greedy parity oracles for `glm-parity` from NVIDIA's
own model code. Nothing from NVIDIA's repository is copied here; the script imports it
from a local snapshot.

## Reference

- Repository: `nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-BF16` (OpenMDW-1.1)
- Revision: `e09a4cedb1787db1760375ee5539f222cae0c672` (2026-10-23)
- Weights: 62 safetensors shards, 149.8 GB bf16 (the language model and the vision tower)
- Code: `llm_config.auto_map` names `modeling_nemotron_h_puzzle.NemotronHPuzzleForCausalLM`,
  which subclasses `modeling_nemotron_h.NemotronHForCausalLM`. The script imports those
  two files and their two configuration files from the snapshot, plus the snapshot
  tokenizer. The SHA-256 of every file it reads is pinned in the script.
- Python: `torch==2.15.0`, `transformers==5.8.1` (the version in `config.json`),
  `huggingface_hub==1.9.2`, `tokenizers==0.22.2`, `safetensors==0.8.0`, `numpy==2.5.4`.
  The model card names no PyTorch version.

No released mlx-lm, mlx-vlm or transformers class loads `nemotron_h_puzzle`.

## What runs that is not NVIDIA's file

The module docstring lists each change and why. In short:

1. A stub `mamba_ssm` package supplies `rmsnorm_fn` (the plain-PyTorch
   `rms_norm_ref` of mamba_ssm). The real package needs CUDA and does not install on
   macOS. The file imports it unconditionally.
2. Multi-token Mamba input runs a corrected copy of the file's naive-SSD prefill. The
   file's PyTorch fallback sums the inter-chunk recurrence over the wrong axis
   (`.sum(dim=2)` where the source-chunk axis is dim 3). From position 128 (one SSD
   chunk) on, its prefill then disagrees with its own token-by-token decode recurrence.
   The copy also takes the stored conv inputs and SSM state, so 8K prompts prefill in
   1024-token pieces (one piece at 8K needs about 69 GB per Mamba layer). Decode runs the
   file unchanged.
3. Before writing any oracle, a self-check prefills 256 prompt ids two ways: chunked,
   and through the file's own decode recurrence one token at a time. The 16 greedy
   tokens must match. The only accepted difference is a top-2 tie within the logit
   noise measured on the earlier steps. The result goes to `self_check.json`.

The Mamba cache keeps state in float32 (`llm_config.mamba_ssm_cache_dtype`). Attention
is NVIDIA's `eager_attention_forward`.

## Prompt and output

The prompt is the shared corpus of `scripts/lab/cb-studio/glm53_bench_vlm.py`
(`"# block {i}\n" + UNIT`, no special tokens, cut to N ids), tokenized with the
snapshot's own tokenizer. The script decodes 256 greedy tokens and records the
top-16 ids and logits of the first 16 steps. Output per context N:

- `oracle_<N>.npz`: `prompt`, `greedy`, `top_idx`, `top_logit`
- `oracle_<N>.json`: `glm-parity-oracle-v1`, byte-identical to
  `scripts/lab/cb-studio/glm53_oracle_json.py oracle_<N>.npz`
- `oracle_<N>.meta.json`: device, dtype, versions, prefill and decode tokens/s, peak
  physical footprint (Metal included) and RSS, the smallest top-2 gap, and the self-check

## Commands

```bash
python3.12 -m venv venv
venv/bin/pip install --only-binary :all: torch==2.15.0 transformers==5.8.1 \
  huggingface_hub==1.9.2 tokenizers==0.22.2 safetensors==0.8.0 numpy==2.5.4
venv/bin/python -I -c 'from huggingface_hub import snapshot_download as s; s("nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-BF16", revision="e09a4cedb1787db1760375ee5539f222cae0c672", local_dir="ref", allow_patterns=["model-*-of-00063.safetensors", "model.safetensors.index.json", "config.json", "*.py", "tokenizer.json", "tokenizer_config.json"])'
HF_HUB_OFFLINE=1 venv/bin/python -I scripts/lab/nemotron-bolt/bolt_reference_oracle.py ref oracles
macprovider-cli glm-parity --model-dir <4-bit artifact> --oracle oracles/oracle_1024.json \
  --oracle oracles/oracle_8192.json --steps 256 --prefill-step-size 1024 --mlx-cache-limit-mb 2048 --output parity.json
```

Run it on MPS (the default). `--device cpu` is for functional checks only. With
torch 2.15 a bf16 matmul on the CPU measured 0.001 TFLOPS on an M5, against 4.6 on MPS,
and float32 weights (300 GB) do not fit in 256 GB. The file's MoE loop runs every
routed expert of every layer for each token, including experts that get no tokens, and
it synchronizes once per expert. That is about 13.8k expert calls per decoded token, so
expect seconds per token. Use `--skip-existing` to resume after a failed context.
