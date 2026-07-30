# RESEARCH_226 — MoE Model Selection on Apple Silicon + OpenRouter Market Demand

Date pulled: 2026-06-30  
Scope: narrow follow-up to RESEARCH_223, RESEARCH_224, and RESEARCH_225  
Decision target: whether macprovider v2 should add MoE-class `rewards.rate_card` rows

## Executive Decision

Add MoE rows at v2 launch, but do not add a broad MoE catalog.

Initial listing should be:

1. `gpt-oss-20b`
2. `google/gemma-4-26b-a4b-it`
3. `qwen3-30b-a3b` only if Track A supports Qwen3-MoE reliably through MLX/LM Studio/llama.cpp routing

Hold:

1. `qwen3-next-80b-a3b-instruct` until Tier-A/Tier-S real-hardware bench confirms stable multi-stream economics.
2. `minimax-m2.7` until Tier-S-only economics clear the operational threshold.
3. `mixtral-8x7b`, `phi-3.5-moe`, `dbrx`, and `mixtral-8x22b` because demand is weak or the model is dated versus newer MoE traffic.

Core finding: active parameters materially improve decode TPS, but they do not eliminate nominal-weight residency. A 3B-active model with 80B total weights still needs roughly 42 GB at 4-bit, so min-RAM remains a hard admission rule. Bandwidth-tier should become a performance filter, not the first eligibility gate.

## Source Register

All source claims below were pulled on 2026-06-30.

| Source | URL | Used for |
|---|---|---|
| OpenRouter public model API | https://openrouter.ai/api/v1/models | Model IDs, canonical slugs, prices, descriptions |
| OpenRouter public rankings API | https://openrouter.ai/api/frontend/v1/rankings/models | Daily completion-token volume and request counts |
| OpenRouter provider endpoint API | `https://openrouter.ai/api/v1/models/<model>/endpoints` | Cheapest public provider price per model |
| OpenRouter rankings page | https://openrouter.ai/rankings | Confirms rankings are based on real usage data |
| OpenAI gpt-oss-20b model card | https://huggingface.co/openai/gpt-oss-20b | 21B total, 3.6B active, Apache 2.0, MXFP4 memory note |
| Google Gemma 4 26B A4B model card | https://huggingface.co/google/gemma-4-26B-A4B-it | 25.2B total, 3.8B active, 256K context, Apache 2.0 |
| Qwen3-30B-A3B model card | https://huggingface.co/Qwen/Qwen3-30B-A3B | 30.5B total, 3.3B active, 128 experts, local runtime support |
| Qwen3-235B-A22B model card | https://huggingface.co/Qwen/Qwen3-235B-A22B | 235B total, 22B active, local runtime support |
| Qwen3-Next-80B-A3B model card | https://huggingface.co/Qwen/Qwen3-Next-80B-A3B-Instruct | 80B total, 3B active, 256K native context |
| Phi-3.5-MoE model card | https://huggingface.co/microsoft/Phi-3.5-MoE-instruct | 6.6B active, 128K context, MIT |
| DeepSeek-V2-Lite model card | https://huggingface.co/deepseek-ai/DeepSeek-V2-Lite | 15.7B total, 2.4B active, model license |
| MiniMax-M2.7 model card | https://huggingface.co/MiniMaxAI/MiniMax-M2.7 | License and model availability |
| HF blob metadata | `https://huggingface.co/api/models/<repo>?blobs=true` | Quantized file-size estimates |
| LLMCheck benchmarks | https://llmcheck.net/benchmarks.html | Apple Silicon benchmark corpus context |
| LocalLLaMA Qwen3 M4/M3 thread | https://www.reddit.com/r/LocalLLaMA/comments/1ltg9ji/m4_max_vs_m3_ultra_qwen3_mlx_inference/ | Qwen3-30B-A3B anecdotal 65 tok/s M4 Pro, M3 Ultra comparison |
| LocalLLM Qwen3 M4 Max thread | https://www.reddit.com/r/LocalLLM/comments/1l6lxcr/qwen3_30b_a3b_on_macbook_pro_m4_frankly_its_crazy/ | Qwen3-30B-A3B 103 tok/s M4 Max anecdote |
| HN Qwen3 MLX comment | https://news.ycombinator.com/item?id=44635589 | Qwen3-30B-A3B 70-100 tok/s M4 Max anecdote |
| Alex Dong Qwen3 local article | https://alexdong.com/qwen3-30b-a3b-the-new-choice-for-nz-organizations-prioritizing-data-sovereignty.html | Qwen3-30B-A3B 78 tok/s M4 Max reported |
| G13N Gemma 4 article | https://g13n.substack.com/p/gemma-4-is-here-i-tested-all-four | Gemma 4 26B A4B 53 tok/s vs dense 31B 6.59 tok/s on same M2 Max |
| Reddit Gemma 4 M4 Pro thread | https://www.reddit.com/r/LocalLLaMA/comments/1u554eo/diffusiongemma26ba4bit4bit_on_macbook_4_pro_with/ | Gemma 4 26B A4B QAT around 38 tok/s on MacBook M4 Pro 48GB |
| X Gemma 4 M4 Mini post | https://x.com/measure_plan/status/2040069272613834847 | Gemma 4 26B A4B around 34 tok/s on Mac mini M4 16GB |
| LM Studio Qwen3 page | https://lmstudio.ai/models/qwen/qwen3-30b-a3b | 3.3B activated weights, 128 total and 8 active experts |
| Darkbloom public home | https://www.darkbloom.dev/ | Verified-Mac positioning and about-50%-lower-cost claim |

## Method Notes

1. Pricing is public OpenRouter endpoint pricing unless explicitly marked otherwise.
2. OpenRouter rankings are the latest complete daily rows in `/api/frontend/v1/rankings/models`: 2026-06-29 00:00:00.
3. Rankings were aggregated by `model_permaslug` to avoid double-counting variants shown separately in the raw API.
4. File sizes are from HF blob metadata where available. For missing 8-bit sizes, estimates use roughly 2x 4-bit size unless a Q8 blob exists.
5. TPS cells are conservative sustained single-stream estimates for 4K context. Published Apple-Silicon measurements are sparse; cells without direct benchmarks are marked as extrapolated.
6. `S/C` means sustained single-stream tok/s and practical concurrent streams before quality-of-service or memory pressure becomes the bottleneck.
7. Active-param bandwidth math is an upper bound only. MoE gating, dense attention layers, KV movement, runtime overhead, and context length lower real throughput.
8. Min RAM is production min, not theoretical boot min. A model can sometimes load at lower RAM but still be unsuitable for paid routing.

## Part 1 — MoE Model Catalog

| Model | Nominal | Active | Native MLX | GGUF | 4bit GB | 8bit GB | Min RAM 4K ctx | Smallest tier servable | License | Apple Silicon readiness |
|---|---:|---:|:-:|:-:|---:|---:|---:|---|---|---|
| `openai/gpt-oss-20b` | 21B | 3.6B | Partial/community | Yes | 10.7-11.3 | 11.3 native MXFP4/Q8-like | 16-24 GB | Tier-C 24GB | Apache-2.0 | Good; model card says MXFP4 runs within 16GB, but paid routing should require 24GB |
| `google/gemma-4-26b-a4b-it` | 25.2B | 3.8B | Yes | Yes | 14.0-15.9 | 25.0-25.7 | 24-32 GB | Tier-C 32GB, Tier-B 24/48GB | Apache-2.0 | Good; strong MLX/GGUF availability, current demand |
| `google/gemma-4-26b-a4b-it-qat` | 25.2B | 3.8B | Yes | Yes | 14.5-15.4 | n/a | 24-32 GB | Tier-C 32GB | Apache-2.0 | Good; QAT variants have high HF download activity |
| `qwen/qwen3-30b-a3b` | 30.5B | 3.3B | Yes | Yes | 15.3-17.4 | 30.3-33.5 | 24-32 GB | Tier-C 32GB, Tier-B 24/48GB | Apache-2.0 | Good; best Apple anecdotal benchmark coverage |
| `qwen/qwen3-30b-a3b-instruct-2507` | 30.5B | 3.3B | Yes | Yes | 15.3-17.3 | 30.3-33.5 | 24-32 GB | Tier-C 32GB | Apache-2.0 | Good; demand lower than base slug but current |
| `qwen/qwen3-next-80b-a3b-instruct` | 80B | 3B | Yes | Yes | 39.7-45.4 | 79.0-86.7 | 64 GB | Tier-A 64GB | Apache-2.0 | Promising but not v2-launch default; residency dominates |
| `qwen/qwen3-235b-a22b` | 235B | 22B | Yes | Yes | 123 GB MLX | estimated 240+ | 192 GB | Tier-S 192GB+ | Apache-2.0 | Tier-S-only; throughput may not beat dense 32B enough after weight load |
| `deepseek-ai/DeepSeek-V2-Lite-Chat` | 15.7B | 2.4B | Yes | Yes | 8.0-9.7 | 15.6 | 16 GB | Tier-C 16GB | DeepSeek model license, commercial allowed by card | Efficient but not current high OpenRouter demand |
| `microsoft/Phi-3.5-MoE-instruct` | 41.9B | 6.6B | Yes | Yes | 20.8-23.6 | 41.4 | 32 GB | Tier-C 32GB, Tier-B | MIT | Technically servable; weak current demand |
| `mistralai/Mixtral-8x7B-Instruct-v0.1` | 46.7B | about 12.9B | Yes | Yes | 24.6 | 46.2 | 48 GB | Tier-B 48GB, Tier-A | Apache-2.0 | Stable but dated; demand weak |
| `mistralai/Mixtral-8x22B-Instruct-v0.1` | 141B | 39B | No strong MLX row found | Yes | estimated 80+ | estimated 150+ | 128-192 GB | Tier-S; M4 Max 128GB possible but poor economics | Apache-2.0 | Skip; active params too large and demand weak |
| `databricks/dbrx-instruct` | 132B | 36B | Yes, old community | Yes, sparse community | 69.8 MLX | estimated 135+ | 128 GB | Tier-S; M4 Max 128GB possible | Databricks Open Model License | Skip; dated and slow |
| `MiniMax-M2.7` | likely 172B-class | likely A10B-class | No strong MLX | Yes | 101-131 | 226-230 | 192 GB | Tier-S 192GB+ | MiniMax license | High demand but Tier-S-only; not v2 launch |
| `MiniMax-M3` | not fully verified | likely MoE | No Apple path verified | API only / unknown | n/a | n/a | n/a | Not listed | unknown | High OpenRouter demand, but no clear Apple-Silicon route |
| `DeepSeek-V4-Flash` | not fully verified | likely MoE-mid | No Apple path verified | GGUF community exists | unknown | unknown | unknown | Not listed | unknown | Highest demand, but no production-ready AS path established |
| `DeepSeek-V4-Pro` | not fully verified | likely MoE-large | No Apple path verified | unknown | unknown | unknown | unknown | Not listed | unknown | High demand, inefficient/unknown AS route |
| `Yi-34Bx2-MoE-60B` | 60B-ish | unknown | No | Yes | unknown | unknown | 48-64 GB | Tier-A maybe | unclear | Skip; low current demand, non-mainstream |

Production-readiness conclusions:

1. The currently viable Apple-Silicon MoE class is not “any MoE”; it is “small-active MoE with 4-bit nominal residency under about 18 GB.”
2. The strongest initial rows are GPT-OSS-20B, Gemma 4 26B A4B, and Qwen3-30B-A3B.
3. Qwen3-Next-80B-A3B is the most interesting holdout: active size is tiny, but 4-bit weights are around 42 GB, so it is not a Tier-C unlock.
4. MiniMax and DeepSeek top OpenRouter demand is strategically important, but current Apple-Silicon readiness is not decision-grade.

## Part 2 — Per-Active-Param TPS Matrix

Hardware bandwidth assumptions:

| Tier | Representative hardware | Bandwidth proxy |
|---|---|---:|
| Tier-C | M4 Air / base M4 | 120 GB/s |
| Tier-B | M4 Pro | 273 GB/s |
| Tier-A | M4 Max | 546 GB/s |
| Tier-S | M2 Ultra | 800 GB/s |
| Tier-S+ | M3 Ultra | 819 GB/s |

Dense reference copied from RESEARCH_223:

| Dense reference | M4 Air | M4 Max | M2/M3 Ultra |
|---|---:|---:|---:|
| Qwen3-32B dense 4bit | 14 tok/s observed, 8-16 target | 25-75 tok/s | 42-140 tok/s |

TPS matrix:

| Model | Active GB 4bit | M4 Air S/C | M4 Pro S/C | M4 Max S/C | M2 Ultra S/C | M3 Ultra S/C | Evidence |
|---|---:|---:|---:|---:|---:|---:|---|
| GPT-OSS 20B, 3.6B active | 1.8 | 35-50 / 1-2 | 55-80 / 2-3 | 80-115 / 3-4 | 95-130 / 4-6 | 100-135 / 4-6 | Extrapolated from active GB and Qwen/Gemma anchors |
| Gemma 4 26B A4B, 3.8B active | 1.9 | 30-45 / 1-2 | 38-70 / 2-3 | 75-105 / 3-4 | 90-125 / 4-5 | 95-130 / 4-5 | Published 34 tok/s M4 Mini 16GB; 38 tok/s M4 Pro; 53 tok/s M2 Max |
| Qwen3-30B-A3B, 3.3B active | 1.65 | 30-45 / 1-2 | 55-75 / 2-3 | 70-105 / 3-4 | 85-115 / 4-6 | 90-125 / 4-6 | Published anecdotes: 65 tok/s M4 Pro, 78-103 tok/s M4 Max, 94.95 tok/s M3 Ultra |
| Qwen3-Next-80B-A3B | 1.5 | OOM | 48GB borderline/OOM | 35-55 / 1-2 | 45-65 / 2-3 | 50-70 / 2-3 | Extrapolated; high nominal residency and hybrid attention lower active-param gain |
| Qwen3-235B-A22B | 11.0 | OOM | OOM | OOM except 128GB risky | 12-20 / 1 | 14-24 / 1 | Extrapolated; 123 GB MLX 4bit weight residency |
| DeepSeek-V2-Lite, 2.4B active | 1.2 | 35-55 / 2 | 60-90 / 3 | 85-125 / 4 | 100-145 / 5-6 | 105-150 / 5-6 | Extrapolated; low demand limits relevance |
| Mixtral 8x7B, about 13B active | 6.5 | OOM/32GB only 12-18 | 18-30 / 1-2 | 25-45 / 2 | 35-55 / 2-3 | 38-60 / 2-3 | Extrapolated; older GGUF/MLX rows |
| Phi-3.5-MoE, 6.6B active | 3.3 | 22-35 / 1 | 38-60 / 2 | 55-80 / 2-3 | 70-95 / 3-4 | 75-100 / 3-4 | Extrapolated; model card active-param fact only |
| DBRX, 36B active | 18.0 | OOM | OOM | 128GB only 8-14 / 1 | 10-18 / 1 | 12-20 / 1 | Extrapolated; 69.8 GB 4bit MLX residency |
| MiniMax M2.7, A10B-ish active | about 5.0 | OOM | OOM | OOM/128GB risky | 25-45 / 1-2 | 30-50 / 1-2 | Extrapolated; 101+ GB 4bit GGUF residency |

Cells that beat dense Qwen3-32B on the same hardware:

| Hardware | MoE cells likely beating dense-32B | Why it matters |
|---|---|---|
| M4 Air 24/32GB | GPT-OSS-20B, Gemma 4 26B A4B, Qwen3-30B-A3B, DeepSeek-V2-Lite, Phi-3.5-MoE on 32GB | These convert Tier-C from “small dense only” into credible 20-30B nominal service |
| M4 Pro 24/48GB | GPT-OSS-20B, Gemma 4 26B A4B, Qwen3-30B-A3B, DeepSeek-V2-Lite, Phi-3.5-MoE | Best practical Tier-B uplift |
| M4 Max 64/128GB | GPT-OSS-20B, Gemma 4 26B A4B, Qwen3-30B-A3B, DeepSeek-V2-Lite, Phi-3.5-MoE; maybe Qwen3-Next quality/value | MoE-small-active is clearly competitive with dense 32B |
| M2/M3 Ultra | Small-active MoE beats dense 32B on latency but not always on economics; large-active MoE does not obviously beat dense 32B | Ultra should serve high-demand rows, not old large-active MoE by default |

Important caveat:

The active-param math explains why Gemma 4 A4B can beat dense Gemma 4 31B on the same machine, but it does not guarantee provider economics. At sub-$0.50/M market prices, even 100 tok/s produces only cents per hour per stream.

## Part 3 — OpenRouter Market Demand

Latest public OpenRouter ranking date: 2026-06-29 00:00:00.

Total completion tokens across the latest day in the public ranking API: 1,460,730,098,305.

Top 30 models by aggregated completion-token volume:

| Rank | Model | Class | Completion tokens | Requests | $/M completion | Trend/source |
|---:|---|---|---:|---:|---:|---|
| 1 | `deepseek/deepseek-v4-flash-20260423` | MoE-mid-active, AS readiness unknown | 225,013,926,597 | 438,201,339 | 0.18 | OpenRouter rankings API |
| 2 | `deepseek/deepseek-v4-pro-20260423` | MoE-large-active, AS readiness unknown | 100,729,229,003 | 77,896,743 | 0.87 | OpenRouter rankings API |
| 3 | `openai/gpt-oss-120b` | MoE-small-active but high residency | 76,752,010,629 | 126,258,644 | 0.15 | OpenRouter rankings API |
| 4 | `google/gemini-2.5-flash-lite` | Closed/unknown | 57,871,444,190 | 252,734,487 | 0.40 | OpenRouter rankings API |
| 5 | `tencent/hy3-preview-20260421` | MoE-mid-active, AS readiness unknown | 53,696,479,752 | 67,104,927 | 0.21 | OpenRouter rankings API |
| 6 | `minimax/minimax-m3-20260531` | MoE, AS readiness unknown | 52,787,716,249 | 60,274,967 | 1.20 | OpenRouter rankings API |
| 7 | `deepseek/deepseek-v3.2-20251201` | MoE-large-active | 48,113,439,517 | 75,245,837 | 0.343 | OpenRouter rankings API |
| 8 | `z-ai/glm-5.2-20260616` | MoE/unknown-active | 42,230,709,327 | 43,724,601 | 3.00 | OpenRouter rankings API |
| 9 | `google/gemini-3-flash-preview-20251217` | Closed/unknown | 42,155,645,958 | 122,327,788 | 3.00 | OpenRouter rankings API |
| 10 | `google/gemini-2.5-flash` | Closed/unknown | 40,297,523,749 | 162,733,532 | 2.50 | OpenRouter rankings API |
| 11 | `xiaomi/mimo-v2.5-20260422` | MoE-mid-active, AS readiness unknown | 38,303,340,154 | 66,764,662 | 0.28 | OpenRouter rankings API |
| 12 | `google/gemini-3.1-flash-lite-20260507` | Closed/unknown | 34,265,159,053 | 95,008,589 | 1.50 | OpenRouter rankings API |
| 13 | `openrouter/owl-alpha` | Closed/unknown | 26,443,249,613 | 59,323,195 | 0.00 | OpenRouter rankings API |
| 14 | `google/gemini-3.1-pro-preview-20260219` | Closed/unknown | 22,730,365,076 | 14,141,432 | 12.00 | OpenRouter rankings API |
| 15 | `anthropic/claude-4.6-sonnet-20260217` | Closed/unknown | 22,266,331,047 | 42,140,687 | 15.00 | OpenRouter rankings API |
| 16 | `google/gemini-3.5-flash-20260519` | Closed/unknown | 22,145,085,723 | 17,287,193 | 9.00 | OpenRouter rankings API |
| 17 | `anthropic/claude-4.7-opus-20260416` | Closed/unknown | 21,824,519,900 | 27,879,813 | 25.00 | OpenRouter rankings API |
| 18 | `anthropic/claude-4.8-opus-20260528` | Closed/unknown | 21,668,593,002 | 22,706,263 | 25.00 | OpenRouter rankings API |
| 19 | `openai/gpt-oss-20b` | MoE-small-active | 21,262,114,419 | 26,601,619 | 0.14 | OpenRouter rankings API |
| 20 | `stepfun/step-3.7-flash-20260528` | Closed/unknown | 20,919,856,552 | 24,557,960 | 1.15 | OpenRouter rankings API |
| 21 | `google/gemma-4-31b-it-20260402` | Dense-mid | 19,407,937,142 | 50,306,194 | 0.35 | OpenRouter rankings API |
| 22 | `google/gemma-4-26b-a4b-it-20260403` | MoE-small-active | 18,841,388,664 | 66,782,258 | 0.33 | OpenRouter rankings API |
| 23 | `openai/gpt-5-mini-2025-08-07` | Closed/unknown | 17,320,050,665 | 31,809,822 | 2.00 | OpenRouter rankings API |
| 24 | `google/gemma-3-27b-it` | Dense-mid | 16,361,641,165 | 25,684,016 | 0.16 | OpenRouter rankings API |
| 25 | `nvidia/nemotron-3-super-120b-a12b-20230311` | MoE-mid-active | 16,045,869,629 | 14,160,958 | 0.40 | OpenRouter rankings API |
| 26 | `openai/gpt-5.5-20260423` | Closed/unknown | 15,474,877,775 | 24,102,884 | 30.00 | OpenRouter rankings API |
| 27 | `moonshotai/kimi-k2.6-20260420` | MoE-mid/large-active, AS readiness unknown | 14,024,317,658 | 10,703,135 | 3.41 | OpenRouter rankings API |
| 28 | `openai/gpt-4o-mini` | Closed/unknown | 13,905,137,012 | 116,219,428 | 0.60 | OpenRouter rankings API |
| 29 | `mistralai/mistral-nemo` | Dense-mid | 13,694,042,021 | 88,776,212 | 0.03 | OpenRouter rankings API |
| 30 | `openai/gpt-5-nano-2025-08-07` | Closed/unknown | 11,495,657,770 | 13,931,761 | 0.40 | OpenRouter rankings API |

Top-30 volume shares by class, with closed models separated because public parameter counts are not decision-grade:

| Class | Top-30 completion tokens | Share |
|---|---:|---:|
| Closed/unknown | 390,783,497,085 | 34.0% |
| MoE-mid-active | 385,847,332,381 | 33.6% |
| MoE-large-active | 205,097,695,505 | 17.9% |
| MoE-small-active | 116,855,513,712 | 10.2% |
| Dense-mid | 49,463,620,328 | 4.3% |
| Dense-small | 0 in top 30 | 0.0% |

OpenRouter demand conclusions:

1. MoE demand is real and large, but much of it is not immediately Apple-Silicon-ready because the leading demand sits in DeepSeek/MiniMax/Tencent/Xiaomi/GLM/Kimi classes with unclear or huge nominal residency.
2. The clean Apple-Silicon intersection in the top 30 is `gpt-oss-20b` and `google/gemma-4-26b-a4b-it`.
3. `qwen/qwen3-30b-a3b` has strong technical fit but is outside the top 100 on the latest daily OpenRouter completion-token ranking. It is a capability row, not a demand row.
4. `qwen/qwen3-next-80b-a3b-instruct` ranks around 64, with meaningful demand but Tier-A/Tier-S-only residency.
5. GPT-OSS-120B has very high demand and only 5.1B active parameters, but it is not a broad fleet unlock because nominal residency is around 60+ GB in practical quantization.

## Part 4 — Intersection: High Demand and Apple-Silicon Efficient

| Model | Class | OpenRouter rank | Cheapest public market $/M completion | Apple-Silicon tier | Tier-A per-stream TPS | Candidate? | Rationale |
|---|---|---:|---:|---|---:|:-:|---|
| `openai/gpt-oss-20b` | MoE-small-active | 19 | 0.13 via OpenRouter WandB endpoint | Tier-C 24GB+ | 80-115 | ✅ | Top-20 demand, Apache-2.0, low residency, likely broad-fleet unlock |
| `google/gemma-4-26b-a4b-it` | MoE-small-active | 22 | 0.30 via OpenRouter Cloudflare endpoint | Tier-C 32GB+, Tier-B 24GB possible | 75-105 | ✅ | Top-25 demand, direct active-param advantage, strong MLX/GGUF availability |
| `qwen/qwen3-30b-a3b` | MoE-small-active | 108/118/138 variants | 0.50 via OpenRouter DeepInfra endpoint | Tier-C 32GB+, Tier-B | 70-105 | ⚠️ | Excellent Apple fit; weak current OpenRouter volume |
| `qwen/qwen3-next-80b-a3b-instruct` | MoE-small-active but high residency | 64 | 0.78 via OpenRouter Alibaba endpoint | Tier-A 64GB+ | 35-55 | ⚠️ | Demand exists; nominal residency makes it Tier-A/S, not broad fleet |
| `openai/gpt-oss-120b` | MoE-small-active but high residency | 3 | 0.15 via OpenRouter | Tier-A 128GB / Tier-S | 35-60 estimate | ❌ for v2 | High demand but too much weight residency for v2 launch route |
| `minimax/minimax-m2.7` | MoE-mid-active, high residency | 58 | 0.72 via OpenRouter Mara endpoint | Tier-S 192GB+ | OOM/risky | ❌ for v2 | Demand exists, but 101+ GB 4-bit residency and unproven AS stack |
| `deepseek/deepseek-v4-flash` | MoE-mid-active, unknown AS | 1 | 0.18 via OpenRouter Wafer endpoint | unknown | unknown | ❌ for v2 | Top demand, but no production-ready Apple-Silicon route established |
| `microsoft/phi-3.5-moe-instruct` | MoE-small-active | not ranked materially | no active OpenRouter endpoint found | Tier-C 32GB+ | 55-80 | ❌ | Efficient but no current buyer demand |
| `mistralai/mixtral-8x7b-instruct` | MoE-mid-active | not ranked materially | no active OpenRouter endpoint found | Tier-B 48GB+ | 25-45 | ❌ | Dated and demand weak |
| `mistralai/mixtral-8x22b-instruct` | MoE-large-active | 238 | 6.00 via OpenRouter Mistral endpoint | Tier-S | 10-20 | ❌ | Price high, demand low, slow |
| `databricks/dbrx-instruct` | MoE-large-active | not ranked materially | no active OpenRouter endpoint found | Tier-S / M4 Max 128GB only | 8-14 | ❌ | Dated; not economically compelling |

## Part 5 — Track B Rate-Card Delta

Interpretation:

1. `completion_credits_per_mtok` is written numerically as the target buyer-facing dollars per million tokens times 1,000,000 credits.
2. Prompt rows use 25% of completion by default unless public market prompt price implies a materially different ratio.
3. Provider gross $/hr below uses target completion price only: `TPS * 3600 * price_per_token`.
4. Provider net after existing `provider_share: 0.90` is also shown.
5. These rows clear electricity on most Macs but do not clear a $0.30/hr provider attractiveness threshold without batching or token subsidy.

Recommended concrete YAML:

```yaml
rewards:
  rate_card:
    # Track B existing rows (don't touch):
    llama-3.1-8b:        # $0.027/M
    qwen3-32b:           # $0.220/M
    llama-3.3-70b:       # $0.250/M

    # New MoE rows from RESEARCH_226:
    gpt-oss-20b:
      prompt_credits_per_mtok: 25000
      completion_credits_per_mtok: 100000   # $0.100/M completion

    google-gemma-4-26b-a4b-it:
      prompt_credits_per_mtok: 60000
      completion_credits_per_mtok: 240000   # $0.240/M completion

    qwen3-30b-a3b:
      prompt_credits_per_mtok: 100000
      completion_credits_per_mtok: 400000   # $0.400/M completion
```

Price derivation:

| Row | Cheapest public market | Source | Target $/M completion | Undercut | Tier-A TPS | Tier-A gross/net $/hr | Tier-S TPS | Tier-S gross/net $/hr | Clears electricity? |
|---|---:|---|---:|---:|---:|---:|---:|---:|:-:|
| `gpt-oss-20b` | 0.13 | OpenRouter endpoint, WandB | 0.100 | 23.1% | 95 | 0.034 / 0.031 | 115 | 0.041 / 0.037 | yes, not $0.30/hr |
| `google-gemma-4-26b-a4b-it` | 0.30 | OpenRouter endpoint, Cloudflare | 0.240 | 20.0% | 90 | 0.078 / 0.070 | 110 | 0.095 / 0.086 | yes, not $0.30/hr |
| `qwen3-30b-a3b` | 0.50 | OpenRouter endpoint, DeepInfra | 0.400 | 20.0% | 85 | 0.122 / 0.110 | 105 | 0.151 / 0.136 | yes, near $0.30/hr only at 2-3 streams |

Tier-eligibility delta:

| Model | Recommended eligibility | Reason |
|---|---|---|
| `gpt-oss-20b` | Allow Tier-C with >=24GB RAM; 16GB only after bench gate | Model card says MXFP4 can run within 16GB, but production routing needs headroom |
| `google-gemma-4-26b-a4b-it` | Allow Tier-C only with >=32GB RAM; allow Tier-B 24GB if bench passes | 4-bit weights are around 14-16 GB, runtime headroom matters |
| `qwen3-30b-a3b` | Allow Tier-C only with >=32GB RAM; Tier-B 24GB after bench gate | 4-bit weights are around 16-17 GB and output contexts can be long |
| `qwen3-next-80b-a3b-instruct` | Tier-A 64GB+ only; not v2 default | 4-bit weights are around 42 GB |
| `gpt-oss-120b` | Tier-A 128GB / Tier-S only; not v2 default | High demand, but residency is not broad-fleet |

Track B implication:

Move from pure bandwidth-tier routing to per-model admission:

```yaml
model_admission:
  gpt-oss-20b:
    min_ram_gb: 24
    min_bandwidth_tier: C
    bench_gate:
      min_sustained_tps: 30
      max_4k_ttft_ms: 2500
  google-gemma-4-26b-a4b-it:
    min_ram_gb: 32
    min_bandwidth_tier: C
    bench_gate:
      min_sustained_tps: 30
      max_4k_ttft_ms: 3000
  qwen3-30b-a3b:
    min_ram_gb: 32
    min_bandwidth_tier: C
    bench_gate:
      min_sustained_tps: 30
      max_4k_ttft_ms: 3000
```

## Part 6 — Strategic Recommendation

Should macprovider add MoE-class rows at v2 launch? Yes, but only 2-3 rows. The demand signal is clear for GPT-OSS-20B and Gemma 4 26B A4B, and both are efficient on Apple Silicon in a way dense-32B is not. Qwen3-30B-A3B should be listed if Track A can guarantee runtime reliability because it is the strongest engineering proof-point, but it is not a demand-led row. Avoid chasing DeepSeek/MiniMax top demand at v2 launch; those are strategically important but not yet Apple-Silicon-production-ready in this repo's terms.

Does the MoE finding change Track A's engineering roadmap? Yes. Track A should not remain “dense llama.cpp `--parallel` first” only. The roadmap should become hybrid: keep dense `--parallel` for qwen3-32b and 70B compatibility, but add MoE-aware runtime selection, per-model RAM admission, and small-active draft/speculative-model selection. The runtime chooser should prefer MLX/LM Studio for Qwen3/Gemma small-active MoE when measured TPS beats llama.cpp, and it should record active params, resident GB, context length, and first-token latency separately.

Does it change Track B's tier filter? Yes. Min-RAM per model must override bandwidth tier for initial eligibility, while bandwidth tier should score expected TPS and concurrency. A Tier-C M4 Air 32GB should be allowed to take GPT-OSS-20B, Gemma 4 A4B, and Qwen3-30B-A3B traffic after a bench gate, even if the same Tier-C provider is not eligible for dense 32B. A Tier-C 16GB machine should not be broadly admitted until it proves model-specific TTFT and sustained decode with production context.

## Part 7 — Open Follow-Up Benchmarks

| Scenario | Hardware | Model | Runtime | Prompt/context | Success threshold |
|---|---|---|---|---|---|
| SCN-226-01 | M4 Air 24GB and 32GB | `openai/gpt-oss-20b` MXFP4/4bit | MLX and llama.cpp GGUF | 4K prompt, 512 completion, 3 runs | >=30 sustained tok/s, no swap, p95 TTFT <=2500 ms |
| SCN-226-02 | M4 Air 32GB, M4 Pro 24GB/48GB | `google/gemma-4-26b-a4b-it` 4bit and QAT 4bit | MLX/VLM and llama.cpp GGUF | 4K text-only and 4K multimodal-disabled text path | >=30 tok/s Tier-C, >=45 tok/s Tier-B, stable memory |
| SCN-226-03 | M4 Max 64GB/128GB and M3 Ultra 256GB | `qwen/qwen3-30b-a3b` 4bit | MLX/LM Studio and llama.cpp | 4K prompt, 2K completion, `/no_think` and thinking variants | Tier-A >=70 tok/s non-thinking; Tier-S >=90 tok/s |
| SCN-226-04 | M4 Max 64GB and M2 Ultra 128/192GB | `qwen/qwen3-next-80b-a3b-instruct` 4bit | MLX and GGUF | 4K and 32K prompts | Load without swap; Tier-A >=35 tok/s at 4K; 32K degradation recorded |
| SCN-226-05 | M2 Ultra 192GB and M3 Ultra 256GB | `minimax/minimax-m2.7` 4bit GGUF | llama.cpp latest | 4K prompt, 512 completion, batch 1 and 2 | Prove or kill Tier-S listing: >=25 tok/s single stream and no swap |

## Appendix A — Additional OpenRouter Ranking Evidence

These rows matter because several candidate MoE models sit below the top 30. They are still relevant for capability planning, but not demand-led v2 launch rows.

| Rank | Model | Completion tokens | Requests | Note |
|---:|---|---:|---:|---|
| 31 | `z-ai/glm-5.1-20260406` | 11,105,548,199 | 16,241,830 | High demand, unclear Apple path |
| 32 | `google/gemini-2.5-pro` | 10,857,067,818 | 5,953,435 | Closed |
| 33 | `anthropic/claude-4.5-haiku-20251001` | 10,427,640,868 | 31,592,183 | Closed |
| 34 | `openai/gpt-5.4-20260305` | 9,686,777,557 | 16,712,531 | Closed |
| 35 | `x-ai/grok-4.3-20260430` | 9,323,617,741 | 14,121,302 | Closed |
| 36 | `qwen/qwen3.5-flash-20260224` | 9,178,460,756 | 29,398,851 | API model, unclear local availability |
| 37 | `inclusionai/ling-2.6-flash-20260421` | 7,780,531,939 | 26,529,586 | API model |
| 38 | `google/gemini-3.1-flash-lite-preview-20260303` | 7,690,469,577 | 30,222,125 | Closed |
| 39 | `qwen/qwen3.7-max-20260520` | 7,206,611,919 | 10,511,303 | API model |
| 40 | `openai/gpt-5.4-mini-20260317` | 7,162,950,233 | 25,391,444 | Closed |
| 41 | `openai/o3-mini-2025-01-31` | 7,051,044,331 | 1,434,139 | Closed |
| 42 | `qwen/qwen3.7-plus-20260602` | 6,737,918,413 | 14,648,425 | API model |
| 43 | `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning-20260428` | 6,361,805,891 | 1,514,198 | MoE-small-active; inspect later |
| 44 | `xiaomi/mimo-v2.5-pro-20260422` | 6,034,095,645 | 9,036,205 | MoE, unclear Apple path |
| 45 | `moonshotai/kimi-k2.5-0127` | 5,582,724,011 | 7,804,131 | MoE, high residency likely |
| 46 | `openai/gpt-5.4-nano-20260317` | 5,370,635,107 | 21,115,569 | Closed |
| 47 | `nvidia/nemotron-3-ultra-550b-a55b-20260604` | 5,128,367,242 | 10,101,262 | MoE-large-active; not AS-efficient |
| 48 | `meta-llama/llama-3.1-8b-instruct` | 5,088,424,384 | 51,935,386 | Dense-small; Track B existing row |
| 49 | `z-ai/glm-5-20260211` | 4,943,811,985 | 7,556,556 | MoE/unknown-active |
| 50 | `openai/gpt-oss-20b` free/variant traffic already merged | 4,628,479,021 raw variant | 8,233,189 raw variant | Merged into rank 19 in aggregate |
| 58 | `minimax/minimax-m2.7-20260318` | 4,013,901,014 | 6,523,312 | Demand exists; Tier-S-only |
| 64 | `qwen/qwen3-next-80b-a3b-instruct-2509` | 3,474,299,926 | 5,487,930 | Hold row; Tier-A/S only |
| 108 | `qwen/qwen3-30b-a3b-instruct-2507` | 845,155,002 | 3,192,158 | Engineering-led candidate |
| 118 | `qwen/qwen3-30b-a3b-04-28` | 718,491,187 | 780,569 | Engineering-led candidate |
| 138 | `qwen/qwen3-30b-a3b-thinking-2507` | 425,815,246 | 344,962 | Engineering-led candidate |
| 238 | `mistralai/mixtral-8x22b-instruct` | 33,416,950 | 43,940 | Skip |

Demand interpretation from Appendix A:

1. The Qwen3-A3B family has fragmented demand across base, instruct, and thinking variants.
2. Combining the three visible Qwen3-A3B rows gives about 1.99B completion tokens for the day, still far below GPT-OSS-20B and Gemma 4 A4B.
3. MiniMax M2.7 demand is stronger than Qwen3-A3B demand, but its 4-bit residency starts around 101 GB, so it is not a broad Apple-Silicon unlock.
4. Nemotron 3 Nano Omni A3B deserves a later research pass, but it is not in the prompt's initial model set and needs license/runtime verification.

## Appendix B — Quantization Evidence Snapshot

HF blob metadata pulled on 2026-06-30:

| Repo | Quant | Size |
|---|---|---:|
| `bartowski/openai_gpt-oss-20b-GGUF` | Q4 / IQ4 | 10.7-10.9 GB |
| `bartowski/openai_gpt-oss-20b-GGUF` | MXFP4 | 11.3 GB |
| `bartowski/openai_gpt-oss-20b-GGUF` | bf16 | 12.8 GB |
| `mlx-community/gpt-oss-20b-OptiQ-4bit` | MLX 4bit | 10.8 GB |
| `mlx-community/gemma-4-26b-a4b-it-4bit` | MLX 4bit | 14.5 GB |
| `mlx-community/gemma-4-26B-A4B-it-qat-4bit` | MLX QAT 4bit | 14.5 GB |
| `unsloth/gemma-4-26B-A4B-it-GGUF` | IQ4 | 12.7 GB |
| `unsloth/gemma-4-26B-A4B-it-GGUF` | Q4_K | 15.4-15.8 GB |
| `unsloth/gemma-4-26B-A4B-it-GGUF` | Q8 | 25.0-25.7 GB |
| `mlx-community/Qwen3-30B-A3B-4bit` | MLX 4bit | 16.0 GB |
| `bartowski/Qwen_Qwen3-30B-A3B-GGUF` | IQ4 | 15.3-16.2 GB |
| `bartowski/Qwen_Qwen3-30B-A3B-GGUF` | Q4_K | 16.7-17.6 GB |
| `bartowski/Qwen_Qwen3-30B-A3B-GGUF` | Q8 | 30.3 GB |
| `mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit` | MLX 4bit | 41.8 GB |
| `mlx-community/Qwen3-Next-80B-A3B-Instruct-8bit` | MLX 8bit | 78.8 GB |
| `unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF` | IQ4/Q4 | 39.7-45.2 GB |
| `unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF` | Q8 | 79.0-86.7 GB |
| `mlx-community/Qwen3-235B-A22B-4bit` | MLX 4bit | 123.2 GB |
| `mlx-community/DeepSeek-V2-Lite-Chat-4bit-mlx` | MLX 4bit | 8.2 GB |
| `legraphista/DeepSeek-V2-Lite-Chat-IMat-GGUF` | IQ4 | 8.0-8.3 GB |
| `legraphista/DeepSeek-V2-Lite-Chat-IMat-GGUF` | Q8 | 15.6 GB |
| `mlx-community/Phi-3.5-MoE-instruct-4bit` | MLX 4bit | 21.9 GB |
| `bartowski/Phi-3.5-MoE-instruct-GGUF` | IQ4/Q4 | 20.8-23.7 GB |
| `bartowski/Phi-3.5-MoE-instruct-GGUF` | Q8 | 41.4 GB |
| `TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF` | Q4 | 24.6 GB |
| `TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF` | Q8 | 46.2 GB |
| `mlx-community/dbrx-instruct-4bit` | MLX 4bit | 69.8 GB |
| `unsloth/MiniMax-M2.7-GGUF` | IQ4 | 101.0-103.1 GB |
| `unsloth/MiniMax-M2.7-GGUF` | Q4_K | 122.0-131.1 GB |
| `unsloth/MiniMax-M2.7-GGUF` | Q8 | 226.4-229.6 GB |

Appendix B conclusions:

1. GPT-OSS-20B and DeepSeek-V2-Lite are the only listed MoE rows that can plausibly fit 16GB with care.
2. Gemma 4 A4B and Qwen3-30B-A3B are practical on 24GB only if context is controlled; 32GB is the correct paid-routing threshold.
3. Qwen3-Next-80B-A3B is small-active but not small-resident.
4. Qwen3-235B-A22B and MiniMax-M2.7 are not broad fleet rows regardless of active params.

## Appendix C — Throughput Formula and Guardrails

Naive upper-bound formula:

```text
active_weight_bytes_per_token = active_params * bytes_per_param
upper_bound_tps = memory_bandwidth_bytes_per_second / active_weight_bytes_per_token
```

For 4-bit active weights:

```text
bytes_per_param ~= 0.5 before quantization overhead
```

Example:

```text
Qwen3-30B-A3B active bytes ~= 3.3B * 0.5 = 1.65 GB
M4 Max upper bound ~= 546 / 1.65 = 331 tok/s
Realistic sustained observed/anecdotal range ~= 70-105 tok/s
Effective factor ~= 21-32% of raw active-weight bandwidth upper bound
```

Why the effective factor is far below 100%:

1. Attention layers are not pure MoE expert loads.
2. KV cache reads/writes grow with context.
3. Runtime kernels do not perfectly saturate memory bandwidth.
4. Expert routing and shared experts add overhead.
5. Some runtimes keep dense projections or embeddings in hot paths.
6. Token sampling, detokenization, server framing, and OpenAI-compatible streaming consume wall time.
7. Thermal stability matters on fanless or thin-client Macs.

Admission rules implied by the formula:

1. Use nominal quantized model size for load eligibility.
2. Use active quantized size for decode-throughput expectation.
3. Use measured TTFT for routing score; active params alone do not predict TTFT.
4. Use context-specific bench gates; a 4K-prompt row may not survive 32K traffic.
5. Require no-swap evidence for paid routing.

## Appendix D — Known Gaps and Follow-Up Data Requests

1. Need a current public Darkbloom authenticated catalog or screenshot export to independently cite the $0.070 and $0.165 rows from RESEARCH_225.
2. Need provider-side OpenRouter volume over 7-day and 30-day windows; the public endpoint used here is daily.
3. Need current MLX/VLM support confirmation for Gemma 4 multimodal paths under text-only routing.
4. Need Apple-Silicon benchmark parity across MLX, llama.cpp, LM Studio, and mlx-swift for the same model quant.
5. Need power draw readings during sustained MoE decode to replace the coarse electricity-clears/does-not-clear judgment.
6. Need direct GPT-OSS-20B Apple-Silicon benchmark rows; current TPS matrix uses extrapolation from Qwen/Gemma anchors.
7. Need direct Qwen3-Next-80B-A3B Apple-Silicon rows; current matrix is deliberately conservative.
8. Need license review before listing MiniMax or newer DeepSeek/Tencent/Xiaomi MoE rows.
9. Need buyer-side quality acceptance checks; fast cheap MoE is only useful if buyers accept the output for coding/agent traffic.
10. Need route-level observability for model slug, quant, runtime, RAM, context length, TTFT, decode TPS, and emitted completion tokens.

## Final Recommendation

MoE is a real v2 launch advantage only when the model is both small-active and low-residency. The initial macprovider MoE class should list GPT-OSS-20B and Gemma 4 26B A4B as demand-led rows, with Qwen3-30B-A3B as an engineering-led row if the bench gate passes. Do not list broad MoE, MiniMax, DBRX, Mixtral 8x22B, or DeepSeek V4 yet. The most important product change is per-model admission: small-active MoE lets Tier-C providers serve credible nominal-20B/30B models, but only when RAM headroom and local bench evidence prove it.
