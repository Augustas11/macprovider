# P0-01 — MLX MoE memory parity (Gemma-4 vs gpt-oss control)

**Task:** P0-01 (Model Catalog Expansion Runbook)  
**Date:** 2026-07-07  
**Executor:** bench / measurement only (no catalog edits)  
**MLX pin:** `mlx-swift-lm` 3.31.4, rev `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57` (`phase3-binary/Package.resolved`)

---

## Hardware & environment

| Field | Value |
|-------|-------|
| **Machine** | MacBook Air (Mac17,3) |
| **Chip** | Apple M5 (10 cores: 4P + 6E) |
| **Unified RAM** | 32 GB (`sysctl hw.memsize` = 34,359,738,368) |
| **Bandwidth tier** | Tier-C (`BandwidthTier.derive` for base M5) |
| **OS** | macOS 26.5 (25F71) |
| **macprovider-cli** | 1.8.16 (release build from task worktree) |
| **Load path** | `serve --no-join` → `LLMModelFactory.shared.loadContainer` + `#huggingFaceTokenizerLoader()` (same as `ModelRuntime.swift:1887–1890`) |
| **Probe shape** | Stage1-equivalent: ~3,284 prompt tokens (`4096 × 0.8`) + 64 decode tokens, `temperature=0`, streaming |

### Measurement notes

- **Process RSS undercounts MLX resident memory** on Apple Silicon (typical ~50–90 MB RSS vs multi-GB unified allocations). Primary metric: **system used-memory delta** from pre-load baseline to idle-after-load, corroborated by on-disk weight size and provider `kv_cache_request_completed` logs.
- Bench used `phase3-binary/.build/release/macprovider-cli` (debug build lacks bundled `default.metallib`).
- A dev provider (`qwen3-coder-30b` on port 61919) was present but showed negligible RSS; Gemma run used a **clean 17 GB used baseline** (15 GB free). gpt-oss reruns after Gemma were **memory-contaminated** (baseline already ~32 GB used); gpt-oss control numbers below prefer the **first clean active-page delta** and on-disk weights.

---

## Per-model results

| Role | MLX repo ID | Quant | On-disk weights | Idle resident Δ† | Post-gen resident Δ† | RSS (idle) ‡ | Swap during bench | Load | 4K probe gen | Decode TPS (rough) |
|------|-------------|-------|-----------------|------------------|------------------------|--------------|-------------------|------|--------------|---------------------|
| **Primary** | `mlx-community/gemma-4-26b-a4b-it-4bit` | 4-bit (+ 8-bit MLP/router slices per `config.json`) | **15 GB** | **+14.98 GB** | **+14.92 GB** | 0.09 GB | **No increase** (−9.9 GB swap vs baseline) | **PASS** | **PASS** (3284+64 tok) | **~7.7** |
| **Control** | `mlx-community/gpt-oss-20b-MXFP4-Q8` | MXFP4-Q8 | **11 GB** | **+10.8 GB** § | n/a § | 0.08 GB § | Heavy swap when baseline full § | **PASS** | **PASS** (3284+64 tok) | **~9–11** § |

† `resident Δ` = `used_gb_after − used_gb_before`, where `used_gb = 32 − free_pages×16 KiB`.  
‡ RSS is not a reliable MLX footprint; included for completeness.  
§ From first low-baseline gpt-oss run (active pages 3.35 → 14.13 GB) and rerun gen log; contaminated reruns hit swap but still completed inference.

### Provider log evidence (4K probe)

**Gemma-4** (`/tmp/p0-01-gemma4-primary.log.serve`):

```json
{"event":"kv_cache_request_completed","model_id":"mlx-community/gemma-4-26b-a4b-it-4bit","prompt_tokens":3284,"completion_tokens":64,"finish_reason":"length"}
```

**gpt-oss** (`/tmp/p0-01-gpt-oss-control-r2.log.serve`):

```json
{"event":"kv_cache_request_completed","model_id":"mlx-community/gpt-oss-20b-MXFP4-Q8","prompt_tokens":3284,"completion_tokens":64,"finish_reason":"length"}
```

---

## Comparison to RESEARCH_226 & catalog

| Model | RESEARCH_226 resident est. | Measured (this bench) | Catalog / baked `min_ram_gb` | Autotune gate (`memoryGB − 4`) on 32 GB |
|-------|---------------------------|------------------------|------------------------------|----------------------------------------|
| **Gemma-4 26B A4B** | 14.0–15.9 GB | **~15 GB** | Baked blocked row `google-gemma-4-26b-a4b-it`; RESEARCH_227 proposes **32 GB** | Requires `min_ram_gb ≤ 28` for eligibility |
| **gpt-oss-20b** | 10.7–11.3 GB | **~11 GB** | Live `openai/gpt-oss-20b` **24 GB** | **24 ≤ 28** — passes gate |

**Conclusion:** Pinned `mlx-swift-lm` 3.31.4 exhibits **MoE resident RAM in line with RESEARCH_226** for both models. No evidence of Darkbloom-scale fused gate+up bloat on these two MoE checkpoints; resident footprint tracks on-disk quantized weights.

---

## ModelFit cross-check (`ModelFit.swift`)

Name-parsing treats parameter suffix as **dense total params**, not MoE active params:

| Model ID | Parsed params | `inferBytesPerParam` | `estimateWeightSizeGB` | Measured resident | Discrepancy |
|----------|---------------|----------------------|--------------------------|-------------------|-------------|
| `gemma-4-26b-a4b-it-4bit` | 26B | 0.5 (4bit) | **13 GB** | **~15 GB** | **Underestimates ~2 GB** — MoE stores all experts resident; mixed 4/8-bit slices add overhead |
| `gpt-oss-20b-MXFP4-Q8` | 20B | 1.0 (`-q8` match) | **20 GB** | **~11 GB** | **Overestimates ~9 GB** — `-q8` suffix is misleading for MXFP4; actual footprint matches MXFP4 MoE residency |

`ModelFit` would mark both as `.fits` on 32 GB, but **admission heuristics derived only from name parsing will be wrong-direction for each MoE variant** (Gemma: false comfort; gpt-oss: false rejection). Catalog `min_ram_gb` should remain operator-curated, not `ModelFit`-derived, for MoE rows.

---

## Autotune 32 GB headroom check

Gate (`AutotuneRecommend.swift:898`): `safetyMarginGB = 4` → eligible when `min_ram_gb ≤ memoryGB − 4` → **≤ 28 GB** on this machine.

| Candidate | Measured resident | Implied RAM need (resident + 4 GB margin) | Fits 32 GB with ≥4 GB headroom? |
|-----------|-------------------|-------------------------------------------|----------------------------------|
| Gemma-4 | ~15 GB | ~19 GB | **Yes** — ~13 GB headroom after weights (OS + KV still tight under concurrent load) |
| gpt-oss-20b | ~11 GB | ~15 GB | **Yes** — comfortable on 32 GB |

---

## Recommended `min_ram_gb` for Gemma-4 catalog row

| Tier | Recommendation | Rationale |
|------|----------------|-----------|
| **Measured floor** | 24 GB | Weights ~15 GB + minimal OS/KV; matches MoE-small-active class |
| **Recommended publish** | **28 GB** | Aligns with autotune gate on 32 GB Tier-C (`32 − 4`); leaves ~13 GB for OS + KV on observed 15 GB weights |
| **Conservative (RESEARCH_227)** | 32 GB | Operator-safe for multi-app Macs and future KV growth |

**Suggested catalog value:** **`min_ram_gb: 28`** for `google/gemma-4-26b-a4b-it` on 32 GB Tier-C fleet; keep **32 GB** if operator prefers RESEARCH_227 conservative posture.

---

## Verdict: **GREEN**

| Criterion | Result |
|-----------|--------|
| Gemma-4 resident ≤ 18 GB | **PASS** (~15 GB) |
| 32 GB load + 4K probe without swap (clean baseline) | **PASS** (swap decreased; gen completed) |
| Pinned mlx-swift-lm 3.31.4 fits with ≥4 GB autotune headroom on 32 GB | **PASS** (~13 GB remaining after ~15 GB weights) |
| OOM / hard load failure | **None observed** |

---

## One-line impact

- **P1-01 / Gemma bench matrix:** **Unblocked** — memory parity confirmed on 32 GB M5.
- **P0-04 (Gemma template probe):** **Unblocked** — prerequisite P0-01 is GREEN.

---

## Raw bench artifacts (local)

| Artifact | Path |
|----------|------|
| Gemma JSON | `/tmp/p0-01-gemma4-primary.json` |
| gpt-oss JSON (clean delta) | `/tmp/p0-01-gpt-oss-control.json` (first run) |
| Bench script | `/tmp/p0-01-moe-bench.sh` |
| Serve logs | `/tmp/p0-01-gemma4-primary.log.serve`, `/tmp/p0-01-gpt-oss-control-r2.log.serve` |
