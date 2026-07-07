# P0-03 — HuggingFace MLX weight availability (flagship candidates)

**Task:** P0-03 (Model Catalog Expansion Runbook)  
**Date:** 2026-07-07  
**Executor:** read-only HF API audit (no downloads, no catalog/code changes)

---

## Registry reference (mlx-swift-lm 3.31.4 pin)

Expected `model_type` values per `LLMModelFactory.swift:26–87`:

| Catalog target | Expected `model_type` | Registry line |
|----------------|----------------------|---------------|
| `gpt-oss-120b` | `gpt_oss` | 71 |
| `gemma-4-31b-4bit` | `gemma4` / `gemma4_text` | 38–40 |
| `qwen3-next-80b-a3b` | `qwen3_next` | 44 |

---

## Summary table

| Target | Repo ID | Revision | Size (GB) | `model_type` | Registry Y/N | License | Verdict | Notes |
|--------|---------|----------|-----------|--------------|--------------|---------|---------|-------|
| `gpt-oss-120b` | [mlx-community/gpt-oss-120b-4bit](https://huggingface.co/mlx-community/gpt-oss-120b-4bit) | `08e7899579b5dd5e0364e4bcd32578134072e22d` | **65.77** | `gpt_oss` | **Y** | Apache-2.0 | **GREEN** | MoE 128 experts × 4 active/tok; est. resident **~66–70 GB** (+ KV). Alt: `gpt-oss-120b-MXFP4-Q4` (62.33 GB, rev `bce781be…`). |
| `gemma-4-31b-4bit` | [mlx-community/gemma-4-31b-it-4bit](https://huggingface.co/mlx-community/gemma-4-31b-it-4bit) | `696d436c404745a59f30e4939a658162b0a9e57f` | **18.41** | `gemma4` (top); `text_config.model_type` = `gemma4_text` | **Y** | Apache-2.0 | **GREEN** | Dense text backbone (`enable_moe_block: false`); packaged as VLM (`Gemma4ForConditionalGeneration`). Est. resident **~17–20 GB** (31B×0.5 + vision tower). Base (non-IT) twin: `gemma-4-31b-4bit` same size/rev family. |
| `qwen3-next-80b-a3b` | [mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit) | `d8a069bfa8ae87d3d468412e1034acae19b5892b` | **44.84** | `qwen3_next` | **Y** | Apache-2.0 | **GREEN** | MoE 512 experts × 10 active/tok; full expert residency. Est. resident **~40–45 GB** (+ KV). Matches RESEARCH_226 range. |

---

## Per-target detail

### 1. `gpt-oss-120b`

**Search:** `mlx-community/*gpt-oss-120*` → 4 mlx-community repos (4bit, MXFP4-Q4/Q8, etc.).  
**Fallback:** `lmstudio-community/gpt-oss-120b-MLX-8bit` (8-bit only; no 4bit lmstudio variant).

**Primary candidate:** `mlx-community/gpt-oss-120b-4bit`

| Field | Value |
|-------|-------|
| Revision | `08e7899579b5dd5e0364e4bcd32578134072e22d` |
| Safetensors | 13 shards, **65.77 GB** total |
| `config.json` → `model_type` | `gpt_oss` |
| `architectures` | `["GptOssForCausalLM"]` |
| MoE topology | 36 layers; `num_local_experts: 128`; `num_experts_per_tok: 4` |
| Quantization | 4-bit affine, `group_size: 64` |
| License | Apache-2.0 |
| Registry | `gpt_oss` registered at `LLMModelFactory.swift:71` |

**Resident estimate:** MoE loads all 128 experts → disk size ≈ resident weights (~66 GB) + KV/activations. Aligns with runbook P4-01 estimate 60–70 GB. Min machine: M4 Max 64 GB (tight) or M3 Ultra 96 GB.

**Alternate:** `mlx-community/gpt-oss-120b-MXFP4-Q4` — 62.33 GB, `model_type: gpt_oss`, rev `bce781bef0f2fc85ed4e575af74054f5aad73ddd`.

---

### 2. `gemma-4-31b-4bit` (dense)

**Search:** `mlx-community/*gemma-4-31b*` → 20+ repos (4/5/6/8bit, IT and base, QAT, MXFP4).  
**Fallback:** `lmstudio-community/gemma-4-31B-it-MLX-4bit` exists (same arch family).

**Primary candidate:** `mlx-community/gemma-4-31b-it-4bit` (highest downloads among 4bit variants)

| Field | Value |
|-------|-------|
| Revision | `696d436c404745a59f30e4939a658162b0a9e57f` |
| Safetensors | 4 shards, **18.41 GB** total |
| `config.json` → `model_type` | `gemma4` (wrapper) |
| `text_config.model_type` | `gemma4_text` |
| `text_config.enable_moe_block` | `false` (dense) |
| `text_config.num_hidden_layers` | 60; `hidden_size: 5376` |
| `architectures` | `["Gemma4ForConditionalGeneration"]` |
| Pipeline tag | `image-text-to-text` (VLM bundle includes vision encoder) |
| Quantization | 4-bit affine, `group_size: 64` |
| License | Apache-2.0 |
| Registry | `gemma4`, `gemma4_text`, `gemma4_unified` at `LLMModelFactory.swift:38–40` |

**Resident estimate:** Dense 31B at ~0.5 B/param ≈ **15.5 GB** text weights; total checkpoint 18.4 GB implies ~3 GB vision/multimodal overhead. Text-only serve path should use `gemma4_text` sub-config. Est. resident **~17–20 GB** on 48 GB tier (P4-03).

**Note:** No separate text-only MLX repo found; all `gemma-4-31b*` mlx-community checkpoints use the VLM wrapper with dense text backbone. Acceptable for P4 bench — P0-04 must validate chat template on text path.

---

### 3. `qwen3-next-80b-a3b`

**Search:** `mlx-community/*Qwen3-Next-80B*` → 4 repos (4/5/6/8bit).  
**Fallback:** none required (mlx-community primary sufficient).

**Primary candidate:** `mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit`

| Field | Value |
|-------|-------|
| Revision | `d8a069bfa8ae87d3d468412e1034acae19b5892b` |
| Safetensors | 9 shards, **44.84 GB** total |
| `config.json` → `model_type` | `qwen3_next` |
| `architectures` | `["Qwen3NextForCausalLM"]` |
| MoE topology | 48 layers; `num_experts: 512`; `num_experts_per_tok: 10` |
| Quantization | 4-bit affine (gate layers 8-bit per-layer overrides) |
| License | Apache-2.0 |
| Registry | `qwen3_next` registered at `LLMModelFactory.swift:44` |

**Resident estimate:** Full 512-expert residency → **~40–45 GB** weights (+ KV). Matches RESEARCH_226 SCN-226-04 and runbook P4-02. Tier-A 64 GB minimum.

---

## Cross-check: weights without registry (none found)

All three primary repos declare `model_type` values present in pinned `LLMTypeRegistry`. No case of weights-on-disk with missing/wrong type requiring arch work before P4 bench.

---

## Overall verdict

### **GREEN**

All three flagship candidates have ≥1 `mlx-community` repo with MLX safetensors, verified `config.json` `model_type`, and registry match. P4 bench (P4-01, P4-02, P4-03) is **unblocked on HF weight availability**; hardware tier and runtime validation remain gating.

**Recommendation:** Proceed to P4 bench planning on documented repos above. Gemma-4 path should pair with P0-04 template probe before catalog publish.
