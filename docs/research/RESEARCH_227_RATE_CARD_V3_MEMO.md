# RESEARCH_227 - Macprovider rate-card v3 OpenRouter re-survey

Date: 2026-06-30

Scope: re-cut the macprovider model menu and rate-card recommendations from the live OpenRouter completion-token ranking, with two separate product lanes:

- Table A: broad-fleet MoE rows that can run on 24-32 GB+ Apple Silicon.
- Table B: coding-specialist rows for M-Max / Ultra providers.

Primary live data sources:

- OpenRouter ranking API: https://openrouter.ai/api/frontend/v1/rankings/models
- OpenRouter model catalog API: https://openrouter.ai/api/v1/models
- OpenRouter endpoints API pattern: `https://openrouter.ai/api/v1/models/{model-id}/endpoints`
- HuggingFace model API / model cards for MLX existence, license fields, and 4-bit safetensor residency.

Important source caveat:

- The OpenRouter ranking payload is not returned as a pure text-only table.
- I sorted rows by `total_completion_tokens` descending to match the prompt's rank anchors:
  - `tencent/hy3-preview-20260421` rank 5.
  - `z-ai/glm-5.2-20260616` rank 8.
  - `xiaomi/mimo-v2.5-20260422` rank 11.
- Pricing is cheapest completion endpoint where the endpoints API exposed provider-level pricing.
- `$/M` values below are completion-token USD per million tokens.
- "MLX residency" is the sum of `.safetensors` blob sizes from HuggingFace API where available; it excludes runtime KV cache and OS headroom.

## Executive Verdict

RESEARCH_226 was directionally right to move from dense-32B defaults to small-active MoE, but it missed a now-obvious demand-led MoE: `nvidia/nemotron-3-nano-30b-a3b`.

The recommended v3 broad-fleet additions are:

1. Keep `openai/gpt-oss-20b` at `$0.100/M`.
2. Keep `google/gemma-4-26b-a4b-it` at `$0.240/M`.
3. Add `nvidia/nemotron-3-nano-30b-a3b` at `$0.160/M`.
4. Demote `qwen/qwen3-30b-a3b` from buyer-facing default until demand recovers; if retained, reprice around `$0.160/M`, not Entry 92's `$0.400/M`.

The developer-coding lane is viable, but not as a dense-only default for every M-Max.

The first developer lane should be:

1. `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` at `$0.235/M` for 32 GB+ code traffic after bench.
2. `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` at `$0.850/M` for 64 GB+ M4 Max / Ultra code traffic after bench.

The coding lane should be marketed as "developer-specialist" rather than "dense-specialist" because the best margin row is Qwen3-Coder A3B MoE, while Qwen2.5-Coder-32B is the quality anchor but has tighter M-Max economics.

## Part 1 - OpenRouter top-50 by completion-token volume

Legend:

- F1 = demand filter: top-100 by completion-token volume.
- F2 = deployability filter: MLX exists or mature GGUF/Metal path.
- F3 = license filter: permissive commercial license.
- A = Table A broad-fleet eligibility.
- B = Table B coding-specialist eligibility.
- `inferred` means source confirms the family/class but not all active/residency details.

| Rank | Model slug | Total params | Active params | Class | License | MLX/GGUF status | $/M completion | Cheapest provider | F1 | F2 | F3 | A | B |
|---:|---|---:|---:|---|---|---|---:|---|---|---|---|---|---|
| 1 | `deepseek/deepseek-v4-flash-20260423` | unknown | unknown | moe-unknown-active | unknown | no verified MLX | 0.180 | Wafer | yes | no | unknown | no | no |
| 2 | `deepseek/deepseek-v4-pro-20260423` | unknown | unknown | moe-unknown-active | unknown | no verified MLX | 0.870 | DeepSeek | yes | no | unknown | no | no |
| 3 | `openai/gpt-oss-120b` | 120B | small-active, inferred | moe-small-active | Apache-2.0 | MLX/GGUF likely; residency too large | 0.140 | WandB | yes | partial | yes | no | no |
| 4 | `google/gemini-2.5-flash-lite` | closed | closed | closed | proprietary | API only | 0.400 | Google | yes | no | no | no | no |
| 5 | `tencent/hy3-preview-20260421` | unknown | unknown | moe-unknown-active | unverified | no verified MLX | 0.210 | GMICloud | yes | no | unknown | no | no |
| 6 | `minimax/minimax-m3-20260531` | very large, inferred | unknown | moe-unknown-active | custom | `mlx-community/MiniMax-M3-4bit`, 224.9 GB | 1.200 | Minimax | yes | yes | uncertain | no | no |
| 7 | `deepseek/deepseek-v3.2-20251201` | large | large-active, inferred | moe-large-active | custom commercial-permitted, inferred | no M-Max fit | 0.343 | StreamLake | yes | partial | uncertain | no | no |
| 8 | `z-ai/glm-5.2-20260616` | very large | unknown | moe-unknown-active | MIT on HF | `mlx-community/GLM-5.2-4bit`, 389.6 GB | 3.000 | DekaLLM | yes | yes | yes | no | no |
| 9 | `google/gemini-3-flash-preview-20251217` | closed | closed | closed | proprietary | API only | 3.000 | Google | yes | no | no | no | no |
| 10 | `google/gemini-2.5-flash` | closed | closed | closed | proprietary | API only | 2.500 | Google | yes | no | no | no | no |
| 11 | `xiaomi/mimo-v2.5-20260422` | unknown | unknown | moe-unknown-active | MIT on HF | no text MLX found; ASR MLX only | 0.280 | DigitalOcean | yes | no | yes | no | no |
| 12 | `google/gemini-3.1-flash-lite-20260507` | closed | closed | closed | proprietary | API only | 1.500 | Google | yes | no | no | no | no |
| 13 | `openrouter/owl-alpha` | closed | closed | closed | proprietary | API only | 0.000 | Stealth | yes | no | no | no | no |
| 14 | `google/gemini-3.1-pro-preview-20260219` | closed | closed | closed | proprietary | API only | 12.000 | Google | yes | no | no | no | no |
| 15 | `anthropic/claude-4.6-sonnet-20260217` | closed | closed | closed | proprietary | API only | 15.000 | Amazon Bedrock | yes | no | no | no | no |
| 16 | `google/gemini-3.5-flash-20260519` | closed | closed | closed | proprietary | API only | 9.000 | Google | yes | no | no | no | no |
| 17 | `anthropic/claude-4.7-opus-20260416` | closed | closed | closed | proprietary | API only | 25.000 | Google | yes | no | no | no | no |
| 18 | `anthropic/claude-4.8-opus-20260528` | closed | closed | closed | proprietary | API only | 25.000 | Google | yes | no | no | no | no |
| 19 | `stepfun/step-3.7-flash-20260528` | unknown | unknown | closed | proprietary/API | no verified MLX | 1.150 | StepFun | yes | no | no | no | no |
| 20 | `google/gemma-4-26b-a4b-it-20260403` | 26B | ~4B | moe-small-active | Apache-2.0 | `mlx-community/gemma-4-26b-a4b-it-4bit`, 14.54 GB | 0.300 | Cloudflare | yes | yes | yes | yes | no |
| 21 | `google/gemma-4-31b-it-20260402` | 31B | 31B | dense-mid | Apache-2.0, inferred | MLX likely, not checked | 0.350 | WandB | yes | partial | yes | no | no |
| 22 | `openai/gpt-oss-120b` | 120B | small-active, inferred | moe-small-active | Apache-2.0 | residency too large for broad fleet | 0.140 | WandB | yes | partial | yes | no | no |
| 23 | `openai/gpt-5-mini-2025-08-07` | closed | closed | closed | proprietary | API only | 2.000 | OpenAI | yes | no | no | no | no |
| 24 | `openai/gpt-oss-20b` | 20B | ~3.6B | moe-small-active | Apache-2.0 | `mlx-community/gpt-oss-20b-MXFP4-Q4`, 10.41 GB | 0.130 | WandB | yes | yes | yes | yes | no |
| 25 | `google/gemma-3-27b-it` | 27B | 27B | dense-mid | Gemma license / commercial permitted | MLX likely; dense TPS too low for M-base | 0.160 | DeepInfra | yes | partial | yes | no | no |
| 26 | `openai/gpt-5.5-20260423` | closed | closed | closed | proprietary | API only | 30.000 | OpenAI | yes | no | no | no | no |
| 27 | `nvidia/nemotron-3-super-120b-a12b-20230311` | 120B | 12B | moe-mid-active | NVIDIA open license, inferred | MLX exists; residency too large | 0.400 | DeepInfra | yes | partial | yes | no | no |
| 28 | `moonshotai/kimi-k2.6-20260420` | very large | large-active, inferred | moe-large-active | custom | MLX exists; residency far above Mac fit | 3.200 | Ambient | yes | yes | uncertain | no | no |
| 29 | `openai/gpt-4o-mini` | closed | closed | closed | proprietary | API only | 0.600 | Azure | yes | no | no | no | no |
| 30 | `mistralai/mistral-nemo` | 12B | 12B | dense-mid | Apache-2.0 | `mlx-community/Mistral-Nemo-Instruct-2407-4bit`, 6.42 GB | 0.030 | DekaLLM | yes | yes | yes | no | no |
| 31 | `openai/gpt-5-nano-2025-08-07` | closed | closed | closed | proprietary | API only | 0.400 | Azure | yes | no | no | no | no |
| 32 | `z-ai/glm-5.1-20260406` | large | unknown | moe-unknown-active | unknown | no verified fit | 3.080 | GMICloud | yes | no | unknown | no | no |
| 33 | `google/gemini-2.5-pro` | closed | closed | closed | proprietary | API only | 10.000 | Google | yes | no | no | no | no |
| 34 | `anthropic/claude-4.5-haiku-20251001` | closed | closed | closed | proprietary | API only | 5.000 | Amazon Bedrock | yes | no | no | no | no |
| 35 | `openai/gpt-5.4-20260305` | closed | closed | closed | proprietary | API only | 15.000 | OpenAI | yes | no | no | no | no |
| 36 | `x-ai/grok-4.3-20260430` | closed | closed | closed | proprietary | API only | 2.500 | xAI | yes | no | no | no | no |
| 37 | `qwen/qwen3.5-flash-20260224` | unknown | unknown | closed/API | proprietary/API | no verified open checkpoint | 0.260 | Alibaba | yes | no | unknown | no | no |
| 38 | `inclusionai/ling-2.6-flash-20260421` | unknown | unknown | dense-small, inferred | unknown | no verified MLX | 0.030 | Novita | yes | no | unknown | no | no |
| 39 | `google/gemini-3.1-flash-lite-preview-20260303` | closed | closed | closed | proprietary | API only | 1.500 | Google | yes | no | no | no | no |
| 40 | `qwen/qwen3.7-max-20260520` | closed/API | closed/API | closed | proprietary/API | no open checkpoint verified | 3.750 | Alibaba | yes | no | unknown | no | no |
| 41 | `openai/gpt-5.4-mini-20260317` | closed | closed | closed | proprietary | API only | 4.500 | OpenAI | yes | no | no | no | no |
| 42 | `openai/o3-mini-2025-01-31` | closed | closed | closed | proprietary | API only | 4.400 | OpenAI | yes | no | no | no | no |
| 43 | `qwen/qwen3.7-plus-20260602` | closed/API | closed/API | closed | proprietary/API | no open checkpoint verified | 1.280 | Alibaba | yes | no | unknown | no | no |
| 44 | `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning-20260428` | 30B | 3B | moe-small-active | NVIDIA open license, inferred | `mlx-community/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-4bit`, 18.29 GB | 0.000/free row | Nvidia | yes | yes | yes, inferred | gated | no |
| 45 | `xiaomi/mimo-v2.5-pro-20260422` | unknown | unknown | moe-unknown-active | MIT, inferred | no text MLX fit verified | 0.870 | Xiaomi | yes | no | yes | no | no |
| 46 | `moonshotai/kimi-k2.5-0127` | very large | large-active, inferred | moe-large-active | custom | no Mac fit | 1.900 | ModelRun | yes | no | uncertain | no | no |
| 47 | `openai/gpt-5.4-nano-20260317` | closed | closed | closed | proprietary | API only | 1.250 | Azure | yes | no | no | no | no |
| 48 | `nvidia/nemotron-3-ultra-550b-a55b-20260604` | 550B | 55B | moe-large-active | NVIDIA open license, inferred | no Mac fit | 2.200 | DeepInfra | yes | partial | yes | no | no |
| 49 | `meta-llama/llama-3.1-8b-instruct` | 8B | 8B | dense-small | Llama 3.1 commercial permitted | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit`, 4.21 GB | 0.030 | DeepInfra | yes | yes | yes | no | no |
| 50 | `z-ai/glm-5-20260211` | large | unknown | moe-unknown-active | unknown | no verified fit | 1.920 | GMICloud | yes | no | unknown | no | no |

### Part 1 exclusions that matter

- `tencent/hy3-preview` has demand rank 5 and attractive market price, but I did not find a verified MLX text checkpoint or license clarity sufficient for rate-card admission.
- `z-ai/glm-5.2` has demand rank 8, MIT license, and MLX conversion, but the MLX 4-bit residency is roughly 389.6 GB, so it is irrelevant to the Mac fleet.
- `xiaomi/mimo-v2.5` has demand rank 11 and MIT license, but I found only MiMo ASR MLX rows, not a deployable text LM MLX row.
- `minimax/minimax-m3` has demand rank 6 and MLX, but 4-bit residency is roughly 224.9 GB.
- `kimi-k2.6` has demand rank 28 and MLX conversions, but its residency is far beyond the 45 GB M-Max/Ultra budget.

## Part 2 - Table A: Broad-fleet MoE rows

TPS assumptions:

- M-base bandwidth: ~120 GB/s.
- M-Max bandwidth: ~410 GB/s.
- Conservative decode TPS uses active-param bandwidth with overhead, not theoretical ceiling.
- Provider `$ / hr` = `TPS * 3600 / 1_000_000 * target_completion_price_per_M`.

| Rank | Model | Active params (GB at 4-bit) | Total residency 4-bit | OpenRouter cheapest $/M completion | Macprovider target $/M | TPS @ M-base | TPS @ M-Max | UX band on M-base | Provider $/hr @ M-base | Provider $/hr @ M-Max | Verdict |
|---:|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---|
| 20 | `google/gemma-4-26b-a4b-it` | ~1.9 GB active, inferred from ~3.8-4B active | 14.54 GB | 0.300 | 0.240 | 50-55 | 125-140 | smooth chat | 0.043-0.048 | 0.108-0.121 | add |
| 24 | `openai/gpt-oss-20b` | ~1.8 GB active, inferred from ~3.6B active | 10.41 GB | 0.130 | 0.100 | 52-58 | 130-145 | smooth chat | 0.019-0.021 | 0.047-0.052 | add |
| 44 | `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` | ~1.5 GB active | 18.29 GB | 0.000/free row; paid endpoint absent | 0.160, provisional | 55-62 | 135-150 | smooth chat | 0.032-0.036 | 0.078-0.086 | gated on paid endpoint + 32GB RAM |
| 68/88 | `nvidia/nemotron-3-nano-30b-a3b` | ~1.5 GB active | 16.55 GB | 0.200 | 0.160 | 55-62 | 135-150 | smooth chat | 0.032-0.036 | 0.078-0.086 | add |
| 113 | `qwen/qwen3-30b-a3b-instruct-2507` | ~1.5 GB active | 16.00 GB | 0.193 | 0.160 | 55-65 | 135-155 | smooth chat | 0.032-0.037 | 0.078-0.089 | gated; outside strict top-100 |
| 24 legacy | `qwen/qwen3-30b-a3b-04-28` | ~1.5 GB active | 16.00 GB | 0.500 | 0.160-0.180 if kept | 55-65 | 135-155 | smooth chat | 0.032-0.042 | 0.078-0.100 | demote from default |

### Table A ranking

1. `google/gemma-4-26b-a4b-it`
   - Best blend of demand rank 20, deployable MLX residency, and provider economics.
   - Beats `gpt-oss-20b` on market demand and target provider `$ / hr`.
   - Augments `gpt-oss-20b` because it offers a Google/Gemma-branded buyer option with similar Apple-Silicon physics.

2. `openai/gpt-oss-20b`
   - Strong demand rank 24.
   - Smallest residency among the broad-fleet MoE rows.
   - Lowest target price, which helps buyer acquisition.

3. `nvidia/nemotron-3-nano-30b-a3b`
   - Demand rank 68/88 by completion-token sort, still inside the strict top-100 demand filter.
   - Cleanly fits the 18 GB residency gate at 16.55 GB.
   - Cheapest market price is `$0.200/M`, so `$0.160/M` is a 20% undercut.
   - Better v3 addition than Qwen3-30B-A3B because it has a stronger live demand signal and comparable Apple-Silicon deployability.

4. `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning`
   - Stronger demand rank 44 but fails the strict 18 GB residency line by about 0.29 GB and exposes a free/no-paid endpoint oddity.
   - Keep as a 32 GB+ bench candidate, not the default v3 rate-card row.

5. `qwen/qwen3-30b-a3b-instruct-2507`
   - Excellent Apple-Silicon shape.
   - Live demand is just outside strict top-100 completion-token rank in this pull.
   - Current market price is far below Entry 92's `$0.400/M`; if retained, Entry 92 must reprice it downward.

### Recommended initial broad-fleet additions

#### 1. `openai/gpt-oss-20b`

Sources:

- HuggingFace base model: https://huggingface.co/openai/gpt-oss-20b
- MLX model: https://huggingface.co/mlx-community/gpt-oss-20b-MXFP4-Q4
- OpenRouter page: https://openrouter.ai/openai/gpt-oss-20b
- OpenRouter endpoints: cheapest paid completion endpoint observed at `$0.130/M`, WandB.
- License source: HF card license field `apache-2.0`.
- Active params source: model card / family documentation; active param value treated as verified-enough for current Entry 92 anchor, but still bench-gated.

Recommended admission:

```yaml
model_admission:
  openai/gpt-oss-20b:
    min_ram_gb: 24
    min_bandwidth_tier: C
    bench_gate:
      min_sustained_tps: 30
      max_4k_ttft_ms: 2500
```

Recommended rate-card row:

```yaml
rewards:
  rate_card:
    openai/gpt-oss-20b:
      usd_per_million_completion_tokens: 0.100
      rationale: "Top-25 OpenRouter demand; 20B small-active MoE; 10.41GB MLX residency; 23% under WandB $0.130/M."
```

#### 2. `google/gemma-4-26b-a4b-it`

Sources:

- MLX model: https://huggingface.co/mlx-community/gemma-4-26b-a4b-it-4bit
- OpenRouter page: https://openrouter.ai/google/gemma-4-26b-a4b-it
- License source: MLX card license field `apache-2.0`.
- Active params source: A4B model naming and model card; active count treated as inferred-but-high-confidence.
- OpenRouter endpoints: cheapest paid completion endpoint observed at `$0.300/M`, Cloudflare.

Why it augments Entry 92:

- It is demand rank 20 versus gpt-oss rank 24 in the current completion-token sorted pull.
- It has higher target price and better provider `$ / hr` while still staying under market.
- It keeps the 24-32 GB broad-fleet premise intact.

Recommended admission:

```yaml
model_admission:
  google/gemma-4-26b-a4b-it:
    min_ram_gb: 32
    min_bandwidth_tier: C
    bench_gate:
      min_sustained_tps: 30
      max_4k_ttft_ms: 3000
```

Recommended rate-card row:

```yaml
rewards:
  rate_card:
    google/gemma-4-26b-a4b-it:
      usd_per_million_completion_tokens: 0.240
      rationale: "Rank-20 OpenRouter demand; 14.54GB MLX residency; undercuts Cloudflare $0.300/M by 20%."
```

#### 3. `nvidia/nemotron-3-nano-30b-a3b`

Sources:

- MLX model: https://huggingface.co/mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit
- Alternate MLX MXFP4: https://huggingface.co/mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-MLX-MXFP4
- OpenRouter page: https://openrouter.ai/nvidia/nemotron-3-nano-30b-a3b
- OpenRouter endpoints: cheapest paid completion endpoint observed at `$0.200/M`, DeepInfra/Novita.
- License source: HF card license field `other`; requires legal confirmation against NVIDIA open model license before final commit.
- Active params source: model name `30B-A3B`; treated as verified by naming and OpenRouter title.

Why it beats Qwen3-30B-A3B for v3:

- It is inside the strict top-100 completion-token demand filter.
- It has MLX residency of 16.55 GB, inside the 18 GB broad-fleet threshold.
- Its market price gives a clean `$0.160/M` undercut target.
- It is a better demand-led row than Qwen3-30B-A3B, which remains an engineering-led bench row.

Recommended admission:

```yaml
model_admission:
  nvidia/nemotron-3-nano-30b-a3b:
    min_ram_gb: 32
    min_bandwidth_tier: C
    bench_gate:
      min_sustained_tps: 30
      max_4k_ttft_ms: 3000
```

Recommended rate-card row:

```yaml
rewards:
  rate_card:
    nvidia/nemotron-3-nano-30b-a3b:
      usd_per_million_completion_tokens: 0.160
      rationale: "Top-100 OpenRouter completion-token demand; 30B-A3B MoE; 16.55GB MLX residency; 20% under $0.200/M market."
```

#### 4. `qwen/qwen3-30b-a3b-instruct-2507`

Sources:

- Base model: https://huggingface.co/Qwen/Qwen3-30B-A3B-Instruct-2507
- MLX model: https://huggingface.co/mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit
- OpenRouter page: https://openrouter.ai/qwen/qwen3-30b-a3b-instruct-2507
- License source: HF card license field `apache-2.0`.
- Active params source: model name `30B-A3B`.
- OpenRouter endpoints: cheapest completion endpoint observed at `$0.193/M`, StreamLake.

Recommended status:

- Do not keep Entry 92's `$0.400/M` buyer-facing price.
- Either remove the row from default admission or reprice to `$0.160/M`.
- Keep as a bench/credibility candidate because the MLX shape is excellent.

Recommended gated row if retained:

```yaml
rewards:
  rate_card:
    qwen/qwen3-30b-a3b-instruct-2507:
      usd_per_million_completion_tokens: 0.160
      rationale: "Engineering-led 30B-A3B MoE row; 16.00GB MLX residency; repriced below live $0.193/M market; not default until top-100 demand recovers."
```

## Part 3 - Table B: Coding-specialist rows for M-Max / Ultra

Strict-filter finding:

- No dense coding-specialist model cleanly satisfies all of:
  - top-100 OpenRouter completion-token demand,
  - permissive license,
  - MLX/GGUF readiness,
  - <=45 GB residency,
  - >=20 TPS on M-Max,
  - provider `$ / hr >= $0.10` while undercutting market by >=10%.
- The closest strict-demand coding model is `moonshotai/kimi-k2.7-code`, but it is a very large MoE and not Mac-fit.
- `qwen/qwen3-coder-480b-a35b` has market demand but is not Mac-fit at <=45 GB.
- Therefore, the developer lane requires an explicit "direct developer demand" exception or a staged experimental category.

| Model | Total params | Architecture | License | MLX/GGUF | HumanEval / SWE-bench signal | OpenRouter rank / direct demand | Cheapest market $/M completion | Macprovider target $/M | TPS @ M-Max 64GB | TPS @ M-Ultra | Provider $/hr @ M-Max | Provider $/hr @ M-Ultra | Verdict |
|---|---:|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|
| `Qwen2.5-Coder-32B-Instruct` | 32B | dense-coding | Apache-2.0 | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`, 17.17 GB | strong code-specialist public benchmark lineage; verify exact score before commit | OpenRouter rank ~332 in live pull; direct Aider/Cursor-class demand signal only | 1.000 | 0.850 | 24-31 | 50-60 | 0.073-0.095 | 0.153-0.184 | add only for M4 Max/Ultra; not M3 Max default |
| `Qwen2.5-Coder-14B-Instruct` | 14B | dense-coding | Apache-2.0 | `mlx-community/Qwen2.5-Coder-14B-Instruct-4bit`, 7.74 GB | good code-specialist lineage; lower quality ceiling | off top-100; direct dev signal | no live OR endpoint found | 0.350 provisional | 50-65 | 90-110 | 0.063-0.082 | 0.113-0.139 | skip paid v3; keep install fallback |
| `Qwen2.5-Coder-7B-Instruct` | 7B | dense-coding | Apache-2.0 | `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`, 3.99 GB | good local coding fallback | off top-100; direct dev signal | no live OR endpoint found | 0.120 provisional | 80-120 | 150-220 | 0.035-0.052 | 0.065-0.095 | install fallback only |
| `Qwen3-Coder-30B-A3B-Instruct` | 30B | coding MoE-small-active | Apache-2.0 | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`, 16.00 GB | newer code-specialist family; verify exact HumanEval/SWE-bench source | OpenRouter model exists; live completion rank outside top-100 | 0.270 | 0.235 | 115-135 | 210-260 | 0.097-0.114 | 0.178-0.220 | add as developer MoE lane after bench |
| `Qwen3-Coder-480B-A35B` | 480B | coding MoE-large-active | Apache-2.0 | `mlx-community/Qwen3-Coder-480B-A35B-Instruct-4bit`; residency too high | high coding demand/quality anchor | visible OpenRouter model; not Mac-fit | 1.000-1.800 | n/a | n/a | n/a | n/a | n/a | skip local Mac serving |
| `DeepSeek-Coder-V2-Lite-Instruct` | ~16B | coding MoE, ~2.4B active | DeepSeek custom commercial-permitted, verify | `mlx-community/DeepSeek-Coder-V2-Lite-Instruct-4bit`, 8.23 GB | strong historical coding model | no top-100 OR demand found | no live OR endpoint found | 0.200 provisional | 110-140 | 200-260 | 0.079-0.101 | 0.144-0.187 | gated research row, not default |
| `DeepSeek-Coder-V2-Instruct` | 236B | coding MoE, ~21B active | DeepSeek custom commercial-permitted, verify | GGUF likely; not <=45 GB residency | strong historical coding model | no top-100 OR demand found | no live OR endpoint found | n/a | n/a | n/a | n/a | n/a | skip Mac fleet |
| `Codestral 22B` | 22B | dense-coding | Mistral/Codestral license caveat | MLX exists via community rows | strong code model, but license caveat | OpenRouter `mistralai/codestral-2508` rank outside top-100 | 0.900 | n/a | 30-40 | 65-80 | n/a | n/a | reject until commercial license cleared |
| `Codestral Mamba` | 7B-ish SSM | state-space coding | Mistral license caveat | MLX not verified for production | niche | no top-100 demand found | n/a | n/a | unknown | unknown | n/a | n/a | skip |
| `StarCoder2-15B` | 15B | dense-coding | BigCode OpenRAIL-M | MLX redirect exists; not current default | older code model | no top-100 OR demand found | n/a | n/a | 45-60 | 90-110 | n/a | n/a | skip due demand/license friction |
| `IBM Granite Code 34B` | 34B | dense-coding | Apache-2.0 | MLX not verified in current search | solid enterprise code model | no top-100 OR demand found | n/a | n/a | 22-30 | 50-60 | n/a | n/a | skip until MLX + demand |
| `Phind CodeLlama` | 34B | dense-coding | Llama-derived | legacy GGUF | older code model | no top-100 OR demand found | n/a | n/a | 22-30 | 50-60 | n/a | n/a | skip |

### Recommended initial coding-dense / developer rows

#### 1. `qwen/qwen3-coder-30b-a3b-instruct`

Sources:

- Base model: https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct
- MLX model: https://huggingface.co/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit
- OpenRouter page: https://openrouter.ai/qwen/qwen3-coder-30b-a3b-instruct
- OpenRouter endpoints: cheapest paid completion endpoint observed at `$0.270/M`, Novita.
- License source: HF card license field `apache-2.0`.
- Active params source: model name `30B-A3B`.

Why it belongs in v3:

- It is the only inspected coding-specialist row with both good MLX residency and provider economics at M-Max-class bandwidth.
- It is not dense, but that is a feature for macprovider economics.
- It can be sold to developer buyers while remaining runnable on the same broad-fleet MoE hardware profile.

Recommended price:

```yaml
rewards:
  rate_card:
    qwen/qwen3-coder-30b-a3b-instruct:
      usd_per_million_completion_tokens: 0.235
      rationale: "Developer-coding MoE row; 16.00GB MLX residency; target undercuts Novita $0.270/M by 13%; expected M-Max provider return near or above $0.10/hr after bench."
```

Recommended admission:

```yaml
model_admission:
  qwen/qwen3-coder-30b-a3b-instruct:
    min_ram_gb: 32
    min_bandwidth_tier: B
    bench_gate:
      min_sustained_tps: 60
      max_4k_ttft_ms: 3000
```

#### 2. `qwen/qwen-2.5-coder-32b-instruct`

Sources:

- Base model: https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct
- MLX model: https://huggingface.co/mlx-community/Qwen2.5-Coder-32B-Instruct-4bit
- OpenRouter page: https://openrouter.ai/qwen/qwen-2.5-coder-32b-instruct
- OpenRouter endpoints: cheapest completion endpoint observed at `$1.000/M`, Cloudflare.
- License source: HF card license field `apache-2.0`.
- Active params source: dense 32B model card/name.

Why it belongs in v3:

- It is the dense coding quality anchor.
- Developer buyers are the segment most likely to pay a premium for coding quality.
- It should not be offered to M-base/M-Pro providers; the economics need M4 Max or Ultra-class decode.

Recommended price:

```yaml
rewards:
  rate_card:
    qwen/qwen-2.5-coder-32b-instruct:
      usd_per_million_completion_tokens: 0.850
      rationale: "Dense developer-coding quality row; 17.17GB MLX residency; 15% under Cloudflare $1.000/M; M4 Max/Ultra only because M3 Max economics are borderline."
```

Recommended admission:

```yaml
model_admission:
  qwen/qwen-2.5-coder-32b-instruct:
    min_ram_gb: 64
    min_bandwidth_tier: A
    bench_gate:
      min_sustained_tps: 30
      max_4k_ttft_ms: 3500
```

#### 3. `deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct`

Sources:

- Base model: https://huggingface.co/deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct
- MLX model: https://huggingface.co/mlx-community/DeepSeek-Coder-V2-Lite-Instruct-4bit
- License source: HF card license field `other`; legal review needed for exact commercial terms.
- Active params source: model family documentation; 2.4B active commonly cited, still verify from model card/paper before final commit.

Recommended status:

- Do not add to the paid v3 rate-card until an OpenRouter or direct buyer demand signal exists.
- Keep as a benchmark comparison row because its MLX residency and active-param math are excellent.

## Part 4 - Models to replace or drop from Entry 92

### Keep: `openai/gpt-oss-20b`

Reason:

- Still top-25 by completion-token demand in the live pull.
- MLX residency is only 10.41 GB.
- Market price supports the existing `$0.100/M` target.

### Keep: `google/gemma-4-26b-a4b-it`

Reason:

- Rank 20 by completion-token demand, ahead of gpt-oss-20b.
- MLX residency is 14.54 GB.
- Existing `$0.240/M` target is still a clean 20% undercut of the `$0.300/M` market endpoint.

### Add / replace into anchor set: `nvidia/nemotron-3-nano-30b-a3b`

Reason:

- Demand-led, not just engineering-led.
- Fits the active-param and residency shape better than most top-50 MoE rows.
- Gives macprovider a third broad-fleet MoE row with a different vendor/family.

### Demote: `qwen3-30b-a3b`

Reason:

- The live completion-token ranking puts Qwen3-30B-A3B variants outside the strict top-100 in this pull.
- Entry 92's `$0.400/M` is no longer market-consistent for the 2507 Instruct variant because the cheapest observed endpoint is `$0.193/M`.
- Keep it as a bench candidate, not a default buyer route.

## Part 5 - Install.sh + Autotune recommendation overhaul

Principles for the install menu:

- Sort by network demand x hardware fit.
- Prefer paid demand rows over purely engineering rows.
- Keep 16 GB machines out of paid large-MoE defaults.
- Use "target $/hr" as a provider-visible approximate at that tier, not a guarantee.
- Keep the custom HuggingFace MLX path.

### 16 GB menu

```text
Detected ~16 GB RAM.

Choose a model - sorted by network demand x hardware fit:
  1) mlx-community/Meta-Llama-3.1-8B-Instruct-4bit        ~4.2 GB, target ~$0.005/hr, rank 49
  2) mlx-community/Mistral-Nemo-Instruct-2407-4bit        ~6.4 GB, target ~$0.006/hr, rank 30
  3) mlx-community/Qwen2.5-Coder-7B-Instruct-4bit         ~4.0 GB, developer fallback, off top-100
  4) mlx-community/Llama-3.2-3B-Instruct-4bit             ~1.7 GB, low-RAM fallback
  c) custom HuggingFace MLX model id
Selection [default: mlx-community/Meta-Llama-3.1-8B-Instruct-4bit]:
```

### 24 GB menu

```text
Detected ~24 GB RAM.

Choose a model - sorted by network demand x hardware fit:
  1) mlx-community/gpt-oss-20b-MXFP4-Q4                   ~10.4 GB, target ~$0.020/hr, rank 24
  2) mlx-community/Meta-Llama-3.1-8B-Instruct-4bit        ~4.2 GB, target ~$0.005/hr, rank 49
  3) mlx-community/Mistral-Nemo-Instruct-2407-4bit        ~6.4 GB, target ~$0.006/hr, rank 30
  4) mlx-community/Qwen2.5-Coder-14B-Instruct-4bit        ~7.7 GB, developer fallback
  c) custom HuggingFace MLX model id
Selection [default: mlx-community/gpt-oss-20b-MXFP4-Q4]:
```

### 32 GB menu

```text
Detected ~32 GB RAM.

Choose a model - sorted by network demand x hardware fit:
  1) mlx-community/gemma-4-26b-a4b-it-4bit                ~14.5 GB, target ~$0.045/hr, rank 20
  2) mlx-community/gpt-oss-20b-MXFP4-Q4                   ~10.4 GB, target ~$0.020/hr, rank 24
  3) mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit    ~16.6 GB, target ~$0.034/hr, rank 68/88
  4) mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit      ~16.0 GB, developer row, gated bench
  5) mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit       ~16.0 GB, engineering row, gated demand
  c) custom HuggingFace MLX model id
Selection [default: mlx-community/gemma-4-26b-a4b-it-4bit]:
```

### 48 GB menu

```text
Detected ~48 GB RAM.

Choose a model - sorted by network demand x hardware fit:
  1) mlx-community/gemma-4-26b-a4b-it-4bit                ~14.5 GB, target ~$0.045/hr, rank 20
  2) mlx-community/gpt-oss-20b-MXFP4-Q4                   ~10.4 GB, target ~$0.020/hr, rank 24
  3) mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit    ~16.6 GB, target ~$0.034/hr, rank 68/88
  4) mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit      ~16.0 GB, developer row, gated bench
  5) mlx-community/Qwen3-32B-4bit                         ~17.2 GB, dense general row, Tier-A only
  c) custom HuggingFace MLX model id
Selection [default: mlx-community/gemma-4-26b-a4b-it-4bit]:
```

### 64 GB menu

```text
Detected ~64 GB RAM.

Choose a model - sorted by network demand x hardware fit:
  1) mlx-community/gemma-4-26b-a4b-it-4bit                ~14.5 GB, target ~$0.112/hr on M-Max, rank 20
  2) mlx-community/gpt-oss-20b-MXFP4-Q4                   ~10.4 GB, target ~$0.050/hr on M-Max, rank 24
  3) mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit    ~16.6 GB, target ~$0.082/hr on M-Max, rank 68/88
  4) mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit      ~16.0 GB, target ~$0.105/hr on M-Max, developer
  5) mlx-community/Qwen2.5-Coder-32B-Instruct-4bit        ~17.2 GB, target ~$0.090/hr on M4 Max, developer dense
  6) mlx-community/Llama-3.3-70B-Instruct-4bit            ~37.0 GB, dense 70B Tier-S/A only
  c) custom HuggingFace MLX model id
Selection [default: mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit]:
```

### 96 GB+ menu

```text
Detected ~96 GB RAM.

Choose a model - sorted by network demand x hardware fit:
  1) mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit      ~16.0 GB, target ~$0.105/hr on M-Max, developer
  2) mlx-community/Qwen2.5-Coder-32B-Instruct-4bit        ~17.2 GB, target ~$0.090-$0.180/hr, developer dense
  3) mlx-community/gemma-4-26b-a4b-it-4bit                ~14.5 GB, target ~$0.112/hr on M-Max, rank 20
  4) mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit    ~16.6 GB, target ~$0.082/hr on M-Max, rank 68/88
  5) mlx-community/Llama-3.3-70B-Instruct-4bit            ~37.0 GB, dense 70B Tier-S/A only
  6) mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit       ~41.8 GB, experimental MoE, gated demand
  c) custom HuggingFace MLX model id
Selection [default: mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit]:
```

### 128 GB+ menu

```text
Detected ~128 GB RAM.

Choose a model - sorted by network demand x hardware fit:
  1) mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit      ~16.0 GB, target ~$0.105/hr on M-Max, developer
  2) mlx-community/Qwen2.5-Coder-32B-Instruct-4bit        ~17.2 GB, target ~$0.090-$0.180/hr, developer dense
  3) mlx-community/Llama-3.3-70B-Instruct-4bit            ~37.0 GB, dense 70B Tier-S/A only
  4) mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit       ~41.8 GB, experimental MoE, gated demand
  5) mlx-community/gemma-4-26b-a4b-it-4bit                ~14.5 GB, high-demand broad-fleet MoE
  6) mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit    ~16.6 GB, high-demand broad-fleet MoE
  c) custom HuggingFace MLX model id
Selection [default: mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit]:
```

### Recommended Swift literal

Use larger `sizeB` values for RAM filtering, but remember that MoE rows need separate active-param economics in the installer text and coordinator admission.

```swift
static let defaultCandidates: [AutotuneCandidate] = [
    AutotuneCandidate(modelID: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", sizeB: 30),
    AutotuneCandidate(modelID: "mlx-community/gemma-4-26b-a4b-it-4bit", sizeB: 26),
    AutotuneCandidate(modelID: "mlx-community/gpt-oss-20b-MXFP4-Q4", sizeB: 20),
    AutotuneCandidate(modelID: "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit", sizeB: 30),
    AutotuneCandidate(modelID: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit", sizeB: 32),
    AutotuneCandidate(modelID: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", sizeB: 30),
    AutotuneCandidate(modelID: "mlx-community/Qwen3-32B-4bit", sizeB: 32),
    AutotuneCandidate(modelID: "mlx-community/Llama-3.3-70B-Instruct-4bit", sizeB: 70),
    AutotuneCandidate(modelID: "mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit", sizeB: 80),
    AutotuneCandidate(modelID: "mlx-community/Mistral-Nemo-Instruct-2407-4bit", sizeB: 12),
    AutotuneCandidate(modelID: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", sizeB: 8),
    AutotuneCandidate(modelID: "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit", sizeB: 14),
    AutotuneCandidate(modelID: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", sizeB: 7),
    AutotuneCandidate(modelID: "mlx-community/Llama-3.2-3B-Instruct-4bit", sizeB: 3),
]
```

## Part 6 - Strategic verdict

### Did RESEARCH_226 anchor on the right models?

Partial. It correctly identified that small-active MoE is the right Apple-Silicon product shape and correctly kept `gpt-oss-20b` plus `gemma-4-26b-a4b-it`. It over-weighted `qwen3-30b-a3b` as an engineering proof-point and under-weighted demand-led rows now visible in OpenRouter's top-100 completion-token table, especially `nvidia/nemotron-3-nano-30b-a3b`.

### Should macprovider open a developer-coding lane as v3 differentiation?

Yes, but with a caveat: do not promise a dense-only coding lane. The viable v3 developer lane is `Qwen3-Coder-30B-A3B` for margin plus `Qwen2.5-Coder-32B` for dense quality on M4 Max / Ultra. The dense 32B row can undercut market but only clears the provider-return floor on high-end M-Max/Ultra machines, not every 64 GB Mac.

### Is there a 5-row minimum viable rate-card v3?

Yes:

```yaml
rewards:
  rate_card:
    meta-llama/llama-3.1-8b-instruct:
      usd_per_million_completion_tokens: 0.027
    openai/gpt-oss-20b:
      usd_per_million_completion_tokens: 0.100
    google/gemma-4-26b-a4b-it:
      usd_per_million_completion_tokens: 0.240
    nvidia/nemotron-3-nano-30b-a3b:
      usd_per_million_completion_tokens: 0.160
    qwen/qwen3-coder-30b-a3b-instruct:
      usd_per_million_completion_tokens: 0.235
```

Optional sixth row after M4 Max/Ultra bench:

```yaml
rewards:
  rate_card:
    qwen/qwen-2.5-coder-32b-instruct:
      usd_per_million_completion_tokens: 0.850
```

## Part 7 - Open questions / before-final-commit checks

1. Confirm exact legal/commercial terms for NVIDIA Nemotron 3 Nano A3B.
   - HF MLX card license field is `other`.
   - The row should not merge into production rate-card until legal text confirms commercial serving is allowed.

2. Confirm exact active-param count and runtime behavior for `nvidia/nemotron-3-nano-30b-a3b`.
   - Model name says A3B.
   - Bench must verify sustained TPS and memory pressure on 32 GB M-base/M-Pro.

3. Confirm whether `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` has a paid OpenRouter endpoint.
   - It has stronger rank than the non-omni row.
   - Current endpoint data surfaced a free row / no useful paid endpoint.
   - Its 18.29 GB MLX residency misses the strict 18 GB threshold.

4. Confirm exact Qwen3-Coder benchmark claims from an official model card or paper before marketing the developer lane.
   - The rate-card can be driven by demand and economics.
   - Marketing copy should cite HumanEval / SWE-bench / LiveCodeBench only after exact numbers are verified.

5. Re-run OpenRouter completion-token ranking immediately before the Entry 92 v3 commit.
   - The live pull was 2026-06-29 UTC data returned on 2026-06-30.
   - Qwen3-30B-A3B was just outside strict top-100 in this pull; if it re-enters, status can move from "demote" to "gated add at repriced target."

6. Bench gates required before production:
   - M-base 24/32 GB x `gpt-oss-20b-MXFP4-Q4`.
   - M-base 32 GB x `gemma-4-26b-a4b-it-4bit`.
   - M-base 32 GB x `NVIDIA-Nemotron-3-Nano-30B-A3B-4bit`.
   - M-Max 64 GB x `Qwen3-Coder-30B-A3B-Instruct-4bit`.
   - M4 Max or Ultra x `Qwen2.5-Coder-32B-Instruct-4bit`.
