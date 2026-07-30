# P0-05 — Nemotron-3-Nano `model_type` verification

**Task:** P0-05 (Model Catalog Expansion Runbook)  
**Date:** 2026-07-07  
**Executor:** read-only investigation (no catalog/code changes)

---

## HuggingFace source

| Field | Value |
|-------|-------|
| **Repo** | [mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit](https://huggingface.co/mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit) |
| **Revision** | `832f602eba5d22436c258c1462bdedc5afddb42b` |
| **config.json URL** | https://huggingface.co/mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit/raw/832f602eba5d22436c258c1462bdedc5afddb42b/config.json |

Matches live catalog row `nvidia/nemotron-3-nano-30b-a3b` in `phase3-binary/dist/static/autotune-candidates.json`.

---

## `config.json` — architecture fields

| Field | Value |
|-------|-------|
| **`model_type`** | **`nemotron_h`** |
| `architectures` | `["NemotronHForCausalLM"]` |
| `auto_map.AutoModelForCausalLM` | `modeling_nemotron_h.NemotronHForCausalLM` |
| `hybrid_override_pattern` | `MEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEM*EMEMEMEM*EMEMEMEME` (Mamba + attention + MoE hybrid) |
| `n_routed_experts` | 128 |
| `num_experts_per_tok` | 6 |
| `n_shared_experts` | 1 |
| `moe_intermediate_size` | 1856 |
| `moe_shared_expert_intermediate_size` | 3712 |
| `num_hidden_layers` | 52 |
| `hidden_size` | 2688 |
| `quantization` | 4-bit affine, group_size 64 |

**Not** `afmoe`, `qwen3_moe`, or `bailing_moe` — the HF config declares the dedicated hybrid type `nemotron_h`.

---

## Registry match (mlx-swift-lm 3.31.4)

| Field | Value |
|-------|-------|
| **Pinned package** | `mlx-swift-lm` exact `3.31.4` (`Package.swift:21–22`) |
| **Resolved revision** | `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57` (`Package.resolved`) |
| **Registry file** | `phase3-binary/.build/checkouts/mlx-swift-lm/Libraries/MLXLLM/LLMModelFactory.swift` |

**Match: YES**

```79:79:phase3-binary/.build/checkouts/mlx-swift-lm/Libraries/MLXLLM/LLMModelFactory.swift
        "nemotron_h": create(NemotronHConfiguration.self, NemotronHModel.init),
```

Supporting implementation: `Libraries/MLXLLM/Models/NemotronH.swift` (hybrid Mamba/attention/MoE blocks); `NemotronHConfiguration.modelType` defaults to `"nemotron_h"` and maps JSON key `model_type` (`NemotronH.swift:799–835`). Unit tests present: `Tests/MLXLMTests/NemotronHTests.swift`.

`LLMTypeRegistry` does **not** need fallback to `afmoe` or `qwen3_moe` for this checkpoint.

---

## Load test (optional)

| Item | Result |
|------|--------|
| Local HF snapshot | **Not found** (`~/.cache/huggingface`, `~/Library/Caches/huggingface`) |
| `LLMModelFactory.shared.loadContainer` | **Not run** — weights unavailable locally |

---

## Catalog cross-check

Live row `nvidia/nemotron-3-nano-30b-a3b`:

- `runtime_status`: **`recommendable`**
- `notes`: *"published 2026-07-06: issue 411 Nemotron runtime validated; coordinator-side rollout active; SPEC-023 v0.3 gates are advisory QoS."*
- Static key rotation v4 (2026-07-06) documents Nemotron feed update under issue 411 (`phase3-binary/dist/static/keys/README.md`).

Catalog claim of runtime validation is **consistent** with registry support for `nemotron_h`; no evidence of a false `unsupportedModelType` path for this revision.

---

## Verdict

### **GREEN**

`model_type` is **`nemotron_h`** (verbatim from HF `config.json` at revision `832f602e…`), and it is registered in pinned `mlx-swift-lm` 3.31.4 `LLMTypeRegistry` at `LLMModelFactory.swift:79`. Local load was not executed; catalog “runtime validated” note aligns with registry coverage.

**Recommendation:** No hotfix required — keep `nvidia/nemotron-3-nano-30b-a3b` as recommendable; P0-05 does not block G0 on model_type grounds.
