# RESEARCH_231 — oMLX community benchmarks → model catalog calibration

Date pulled: 2026-07-09  
Scope: catalog calibration memo (no code changes, no oMLX runtime adoption)  
Decision target: actionable deltas for the next `autotune-candidates.json` publish PR  
Catalog baseline: `published-2026-07-07-p2-qwen3-8b` (9 recommendable rows)

## Executive summary

1. **oMLX community board is usable as an advisory calibration source**, not a hard gate. Dataset size is **~321k rows** (2026-07-09 index); cells with **n≥10** at **4k / 4bit** on a normalized chip+RAM bucket are decision-grade for directional TG/PP envelopes.
2. **No public JSON bulk API** was found. Repeatable ingestion is **HTML pagination** on `omlx.ai/benchmarks` plus per-run detail pages at `omlx.ai/benchmarks/<id>`. Cloudflare rate-limits aggressive scrapers; operators should snapshot monthly with **≥2 s inter-page delay** and residential IP rotation if needed.
3. **Engine delta band (mlx-lm → mlx-swift-lm 3.31.4):** apply **0.85×** to oMLX TG when the row maps to the **same `mlx-community/*` artifact**; **0.70–0.80×** for quant-variant or community-repack matches; **do not gate** on name-only / Heretic / custom-merge aliases.
4. **Existing gates are mostly well-calibrated** for MoE rows published 2026-07-03–07 (`gpt-oss-20b`, `gemma-4-26b-a4b-it`, `qwen3-8b`) where macprovider local autotune exists. Largest mismatch: **`nvidia/nemotron-3-nano-30b-a3b` `min_sustained_tps=30`** — oMLX sparse for the 30B-A3B pin; proxy data suggests gate is **too tight** on Tier-C 32 GB.
5. **`qwen3-32b` gate `min_sustained_tps=15`** is **borderline too tight** for Tier-B M-Pro 48 GB: oMLX p50 TG @4k ≈ 11 tok/s on M4 Pro → macprovider-adjusted **~9 tok/s**, below gate. Recommend **10** or restrict to Tier-A.
6. **`qwen2.5-coder-32b-instruct` gate `min_sustained_tps=20`** is **slightly tight** for M4 Max: oMLX p50 @4k ≈ 17 → adjusted **~14**. Recommend **15** pending local repro.
7. **Top oMLX demand not in catalog:** `Qwen3.6-35B-A3B` (~3.7k+ filtered rows for 64k context alone), `Qwen3.6-27B`, `Qwen3.5-35B-A3B`, `gemma-4-31b-it`. Only **`Qwen3.6-35B-A3B`** has a clear `mlx-community` path worth a P1 row after local bench.
8. **Community fine-tunes** (`Qwythos-9B`, Heretic uncensored merges, Claude-opus distill names) should map to **`runtime_status: experimental`** or `research_only` — never signed catalog without artifact pin.
9. **TTFT from PP proxy** (`4096/PP×1000`) underestimates macprovider Stage-1 TTFT by **1.3–2.5×** on cold start; use only for sanity bounds on `max_4k_ttft_ms`, not as a substitute for autotune p95.
10. **Gate slack policy:** set `min_sustained_tps = floor(p25_oMLX × engine_delta × 0.90)`; never below **75% of local macprovider median** when local bench exists.
11. **SPEC-023 v0.2+ gates are advisory QoS** — oMLX calibration informs hardware-evidence drift and operator publish discipline; soft gates mean oMLX-only evidence cannot justify *raising* `min_sustained_tps` without local repro.
12. **Rate-card follow-up:** adding `Qwen3.6-35B-A3B` would need RESEARCH_227 repricing lane (~$0.16/M MoE); no dollar changes in this memo.
13. **Next operator actions:** monthly `omlx-benchmark-snapshot-2026-07.json`; quarterly memo rerun; 8 falsification benches listed in Part 5 before any P0 gate change ships.
14. **Confidence:** catalog rows with **both** oMLX cell n≥10 and macprovider autotune = **high**; oMLX-only dense 32B / Nemotron 30B = **medium**; community-merge aliases = **low**.

---

## Source register

| Source | URL / path | Pulled | Used for |
|---|---|---|---|
| oMLX community board (index) | https://omlx.ai/benchmarks | 2026-07-09 | Row counts, schema, top-model frequency |
| oMLX filtered pages (indexed) | `?context=4096&model=…&quantization=4bit` | 2026-07-09 | Per-model TG/PP samples |
| oMLX per-run detail pages | `https://omlx.ai/benchmarks/<id>` | 2026-07-09 | Peak mem, multi-context tables |
| macprovider autotune catalog | `phase3-binary/dist/static/autotune-candidates.json` | 2026-07-09 | Current gates |
| P1-01 Gemma bench | `beta/catalog-expansion/P1-gemma4-bench-matrix.md` | 2026-07-07 | Local TG/TTFT |
| P2-02 Qwen3-8B bench | `beta/catalog-expansion/P2-small-tier-catalog.md` | 2026-07-07 | Local TG/TTFT |
| P0-01 memory | `beta/catalog-expansion/P0-01-moe-memory-parity.md` | 2026-07-07 | Resident RAM |
| decode-bench snapshots | `audits/2026-07-07/bench-snapshots/` | 2026-07-07 | gpt-oss TG cross-check |
| RESEARCH_226 MoE memo | `specs/RESEARCH_226_MOE_SELECTION_AND_MARKET_DEMAND_MEMO.md` | 2026-06-30 | Demand / RAM class |
| RESEARCH_227 rate card | `specs/RESEARCH_227_RATE_CARD_V3_MEMO.md` | 2026-06-30 | Demand ranks |
| SPEC-023 gates | `specs/SPEC-023-installer-autotune-recommend.md` v0.5 | 2026-07-06 | Advisory QoS semantics |
| oMLX upstream repo | https://github.com/jundot/omlx | 2026-07-09 | Local-only bench APIs (not community board) |
| Bandwidth tier derive | `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` | 2026-07-09 | Chip → tier mapping |

### Data limitation (documented)

Direct HTTP scrape from the research executor hit **Cloudflare 429** on `omlx.ai/benchmarks` (2026-07-09). This memo uses **search-indexed board pages**, **per-run detail URLs**, prompt-embedded example rows, and macprovider local benches. Numeric cells marked **oMLX** without local corroboration should be treated as **directional** until the monthly snapshot pipeline (Part 5) runs from a non-rate-limited operator host.

---

## Part 1 — oMLX dataset ingestion methodology

### 1.1 Scrape / API strategy

| Approach | Finding | Recommendation |
|---|---|---|
| Public JSON API | **Not found** for community board. oMLX server exposes **local** `GET /api/bench/throughput/results` for self-hosted admin runs only (`omlx/admin/benchmark.py`). | Do not depend on local admin API for community data. |
| Community board | Server-rendered HTML table at `/benchmarks` with query filters. | Primary ingestion surface. |
| Per-run detail | Stable URLs `omlx.ai/benchmarks/<8-char id>` with full context matrix + peak mem. | Secondary enrichment for RAM and multi-context. |
| Pagination | `?page=N` (10 rows/page). Index reports **~321k rows / ~32k pages** (2026-07-09). | Full crawl ≈ 9–18 h at 1–2 s/page. |
| Filters | `chip`, `chip_full`, `model`, `quantization`, `context`, `pp_min`, `tg_min`, `sort`, `order`. | Pre-filter per catalog model before bulk pagination. |
| Rate limits | Cloudflare **429** under burst automation. | ≥2 s delay, browser-like UA, monthly not daily. |
| ToS | No explicit robots.txt block found; board is **public marketing + community opt-in** (app v0.2.6+ submit). | Flag: confirm with oMLX before commercial redistribution; macprovider internal snapshots OK. |

**Pseudocode (appendix-ready):**

```python
# omlx_snapshot.py — operator script, not production code
BASE = "https://omlx.ai/benchmarks"
FILTERS = {"context": "4096", "quantization": "4bit", "sort": "date", "order": "desc"}

def fetch_page(page: int, model_substr: str | None = None) -> list[dict]:
    params = {**FILTERS, "page": page}
    if model_substr:
        params["model"] = model_substr
    html = GET(BASE, params=params, delay_sec=2.0)  # respect 429 backoff
    return parse_benchmark_table(html)  # columns: chip, ram_gb, model, quant, ctx, pp, tg, date

def normalize_row(raw) -> dict:
    return {
        "chip_full": raw.chip,           # e.g. "M4 Pro (20c)"
        "ram_gb": parse_ram(raw.ram),
        "model_display": raw.model,
        "quant": raw.quant,
        "context": parse_ctx(raw.ctx),   # 4096 for "4k"
        "pp_tps": float(raw.pp),
        "tg_tps": float(raw.tg),
        "date": parse_date(raw.date),    # YY-MM-DD → ISO
        "catalog_model_id": map_model(raw.model),  # Appendix A
        "bandwidth_tier": map_tier(raw.chip),
    }
```

### 1.2 Normalization — model strings → catalog keys

See **Appendix A** for the full table. Rules:

1. Strip oMLX display suffixes (`-oQ4`, `-oQ6`, `-Heretic…`, `-Claude-4.6-Op…`).
2. Case-fold; map `Qwen3.6-*` → canonical HF family (often **no** exact `mlx-community` pin).
3. Community fine-tunes → `research_only` unless HF repo verified.
4. Quant normalization: `4bit`, `Q4`, `MXFP4-Q8` tagged as `4bit` bucket for comparison; `bf16` rows excluded from 4bit gate calibration.

### 1.3 Chip normalization → `HardwareSummary` + bandwidth tier

macprovider `BandwidthTier.derive(chip:)` (`AutotuneRecommend.swift`):

| oMLX `chip_full` pattern | macprovider `chip` string | Tier | Bandwidth intent |
|---|---|---|---|
| `M*-Ultra*` (M3/M4 gen) | `Apple M3 Ultra` / `Apple M4 Ultra` | **S** | ≥400 GB/s class |
| `M*-Ultra*` (M1/M2) | `Apple M1 Ultra` / `Apple M2 Ultra` | **A** | 400–800 GB/s |
| `M*-Max*` (M3+) | `Apple M4 Max` etc. | **A** | 400–546 GB/s |
| `M*-Max*` (M1/M2) | `Apple M2 Max` etc. | **B** | 200–400 GB/s |
| `M*-Pro*` | `Apple M4 Pro` etc. | **B** | 200–273 GB/s |
| `M* (Nc)` base, no Pro/Max | `Apple M5` etc. | **C** | <200 GB/s |

**Ambiguous cases:**

| Issue | Handling |
|---|---|
| GPU core count in name (`M4 Pro (16c)` vs `(20c)`) | Treat as same SKU family; bucket by **tier + RAM**, not core count. |
| RAM variants within tier (24 vs 48 GB M-Pro) | Separate cells; RAM is independent gate via `min_ram_gb`. |
| `M5 Max (40c)` vs catalog `min_bandwidth_tier` | Maps to **A**, not S — catalog tier letters align with derive() not marketing "Max=always flagship". |

### 1.4 Outlier rejection filters

| Filter | Threshold | Rationale |
|---|---|---|
| Min sample count per cell | **n ≥ 10** for percentile quotes; **n ≥ 3** for directional only | Board has duplicate tester runs |
| Date freshness | **≤ 120 days** (oMLX v0.3+ KV fix May 2026) | Pre-`af97a0f` oMLX TG deflated by KV memcpy bug |
| Quant bucket | Must match catalog quant (**4bit**) | bf16/8bit rows skew high |
| Context | Primary **4096**; secondary 1024 / 32768 when n≥10 | Matches `max_4k_ttft_ms` |
| TG sanity | Drop TG **> 500** at 4k (micro-model pollution) | Top sort dominated by 0.8B models |
| TG floor | Drop TG **< 0.5** | OOM-throttle / typo rows |
| IQR trim | Remove TG outside **[Q1−1.5×IQR, Q3+1.5×IQR]** per cell | Tester config outliers |
| MAD alternative | For n<20, use median ± **3×MAD** | Robust when IQR unstable |
| Duplicate tester | Collapse same `(chip, ram, model, quant, ctx, date±1d)` keeping median TG | Issue #1007 self-test spam |

### 1.5 Engine delta factor (oMLX mlx-lm → macprovider mlx-swift-lm)

| Match quality | TG multiplier | PP / TTFT | Confidence |
|---|---|---|---|
| Same `mlx-community/*` repo + same quant family | **0.85×** | PP proxy ×1.0 for order-of-magnitude | medium-high |
| Same HF base, different quant pack (DWQ, oQ4) | **0.75×** | +20% TTFT uncertainty | medium |
| Name-only / community merge | **0.70×** (do not gate) | advisory only | low |
| MoE @ M-Base cold start | Additional **0.90×** on top | TTFT +30% vs oMLX warm | medium |

**Worked example (gemma-4-26b-a4b-it @ M4 24GB):** oMLX TG p50=33.3 → macprovider estimate **28.3**; local P1-01 M5 measured **12.5** → engine gap on *base* tier is larger than 0.85× suggests; **tier-C local bench wins** when available.

---

## Part 2 — Per-model hardware fit matrix

### 2.1 Tier reference

| Tier | Bandwidth | Typical chips | Catalog routing intent |
|---|---|---|---|
| **A** | ≥400 GB/s | M-Max (M3+), M-Ultra (M1/M2) | 32B dense, flagship MoE |
| **B** | 200–399 GB/s | M-Pro 48GB+, M-Max (M1/M2) | 32B marginal / large MoE |
| **C** | <200 GB/s | M-base, M-Pro 16–24GB | ≤8B / small MoE |

### 2.2 Existing catalog rows

Cells use **4k / 4bit** unless noted. TG percentiles are from indexed oMLX samples (Jul 2026); **macprovider-adjusted TG** = oMLX × 0.85 (same artifact) or ×0.75 (variant).

| Catalog key | mlx-community model_id | oMLX aliases | Best chip (p50 TG) | Min RAM (fit) | TG p25/p50/p75 @4k | PP p50 @4k | Gate today | Recommended gate | Confidence |
|---|---|---|---|---:|---|---|---|---|---|
| `qwen3-coder-30b-a3b-instruct` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `Qwen3-Coder-30B-A3B-Instruct*`, `*Coder-30B-A3B*` | M5 Pro 20c (78.5) | **28** (peak ~17 GB) | 47 / **72** / 84 | 1266 | TPS **20**, TTFT 3500 | **TPS 18**, TTFT 3500 | medium (oMLX) |
| `openai/gpt-oss-20b` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | `gpt-oss-20b-MXFP4-Q8`, `gpt-oss-20b*` | M5 Max 40c (112.9 @4k Q8) | **24** (peak ~12 GB) | 65 / **71** / 137† | 1783 | TPS **15**, TTFT 2500 | **keep 15 / 2500** | **high** (both) |
| `meta-llama/llama-3.1-8b-instruct` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `Meta-Llama-3-8B*`, `Llama-3.1-8B*` | M3 Max 40c (43.1) | **12** | 35 / **43** / 50 | 545 | TPS **15**, TTFT 2500 | **keep 15 / 2500** | medium (oMLX) |
| `qwen3-32b` | `mlx-community/Qwen3-32B-4bit` | `Qwen3-32B*`, `Qwen3.6-27B`‡ | M4 Pro 20c (11.2) | **48** (peak ~19 GB) | 5 / **11** / 12 | 88 | TPS **15**, TTFT 4000, tier **B** | **TPS 10**, tier **A** OR TPS 10 @B | medium (oMLX) |
| `qwen2.5-coder-32b-instruct` | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | `Qwen2.5-Coder-32B-Instruct` | M4 Max 32c (17.0) | **48** (peak ~19 GB) | 12 / **17** / 18 | 168 | TPS **20**, TTFT 3500, tier **A** | **TPS 15**, TTFT 3500 | medium (oMLX) |
| `nvidia/nemotron-3-nano-30b-a3b` | `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | `Nemotron-3-Nano-30B*`, `Nemotron-3-Nano-4B`§ | sparse; proxy M4 10c Nano-4B (39.9) | **32** | ? / **~35**¶ / ? | 291 | TPS **30**, TTFT 3000 | **TPS 20**, TTFT 3000 | **low** (oMLX sparse) |
| `meta-llama/llama-3.2-3b-instruct` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `Llama-3.2-3B-Instruct` | M1 8c (2.0) | **4–8** | 2 / **2** / 3 | 181 | TPS **15**, TTFT 2500 | **TPS 8**, TTFT 3000 | medium (oMLX) |
| `google-gemma-4-26b-a4b-it` | `mlx-community/gemma-4-26b-a4b-it-4bit` | `gemma-4-26b-a4b-it`, `gemma-4-26B-A4B-it` | M4 Max 40c (95.4) | **28** (peak ~15 GB) | 33 / **38** / 95 | 328–1400 | TPS **10**, TTFT 3000 | **keep 10 / 3000** | **high** (both) |
| `qwen3-8b` | `mlx-community/Qwen3-8B-4bit` | `Qwen3-8B`, `Qwen3.5-9B-OptiQ` | M4 16GB (15.6)‖ | **12** | 14 / **16** / 39 | 217 | TPS **15**, TTFT 4500 | **keep 15 / 4500** | **high** (both) |

† M5 Max tier-A hardware; not Tier-C admission target.  
‡ `Qwen3.6-27B` is related dense family, not byte-identical pin.  
§ Nemotron-4B oMLX rows are **wrong param count** but show NVIDIA MoE runtime class; 30B-A3B oMLX submissions sparse at 4k/4bit in index.  
¶ Extrapolated from 4B @39.9 × MoE residency scaling; wide uncertainty.  
‖ Qwen3.5-9B is proxy for small dense Qwen3 class on 16 GB M4.

**Local macprovider corroboration (M5 32 GB Tier-C):**

| Catalog key | Local median TG | Local p95 TTFT ms | oMLX-adjusted Tier-C TG | Gate fit |
|---|---:|---:|---:|---|
| `openai/gpt-oss-20b` | **18.3** (P1-01) / **22.9** (decode-bench) | 1590 | N/A (no M5 base oMLX @4k in sample) | **PASS** @15 |
| `google-gemma-4-26b-a4b-it` | **12.5** | 2611 | M4 24GB oMLX 33 → adj **28** (upper bound) | **PASS** @10 |
| `qwen3-8b` | **23.9** | 3733 | M4 16GB proxy 15.6 → adj **13** | **PASS** @15 |

### 2.3 Multi-context columns (where n≥10 indexed)

| Catalog key | TG p50 @1k | TG p50 @4k | TG p50 @32k | Notes |
|---|---:|---:|---:|---|
| `openai/gpt-oss-20b` | 77.5 (M5 Pro) | **71.0** | 24.3 (64k) | TG degrades slowly with ctx |
| `google-gemma-4-26b-a4b-it` | 33.9 (M4) | **33.3** | n<10 | Flat ctx curve on MoE |
| `qwen3-coder-30b-a3b-instruct` | 43.3 (M4) | **34.4** | 56.9 (32k M3 Max) | Unusual 32k uplift — verify |
| `qwen3-32b` | 5.8 (M4) | **5.4** | n<10 | Dense 32B poor on Tier-C |
| `qwen2.5-coder-32b-instruct` | 18.2 (M4 Max) | **17.0** | n<10 | |
| `qwen3-8b` | 40.8 (M3 Ultra bf16) | **38.6** | 25.9 | bf16 row; 4bit expect ~10% higher |

### 2.4 Top-20 oMLX models **not** in catalog (by submission frequency)

Ranked by indexed filter counts + board prominence (2026-07-09):

| Rank | oMLX model family | Est. rows | mlx-community path | Proposed catalog status |
|---:|---|---:|---|---|
| 1 | `Qwen3.6-35B-A3B` (+variants) | **3,700+** (64k filter alone) | `mlx-community/Qwen3.6-35B-A3B-4bit` (verify pin) | **P1 candidate** after local bench |
| 2 | `Qwen3.5-35B-A3B` | high | community exists | P2 — superseded by 3.6 |
| 3 | `Qwen3.6-27B` | high | partial / `Qwen3.6-27B-4bit` | research_only until pin |
| 4 | `gemma-4-31b-it` | high | `mlx-community/gemma-4-31b-it-4bit` | P2 — dense, weak MoE economics |
| 5 | `Qwen3.5-9B` / `Qwen3.5-9B-OptiQ` | high | no exact mlx pin | alias of `qwen3-8b` class only |
| 6 | `Qwen3.5-0.8B` | high (TG sort noise) | multiple | skip — not provider lane |
| 7 | `MiniMax-M2.5` | medium | `mlx-community/MiniMax-M2.5-4bit` (224GB+) | Tier-S only — no catalog |
| 8 | `GLM-5` / `GLM-5.2` | medium | 389 GB MLX | Tier-S only — no catalog |
| 9 | `Qwen3-Coder-Next` | medium | verify HF | P2 coding lane |
| 10 | `LFM2-24B-A2B` | medium | community | experimental |
| 11 | `gpt-oss-120b` | medium | residency too large | no catalog |
| 12 | `Qwen3.6-40B-*` distill merges | medium | none standard | research_only |
| 13 | `copywriter-gemma4-31b-oQ6` | low-med | none | research_only |
| 14 | `Qwythos-9B-*` | low-med | none | experimental |
| 15 | `SmolLM2-360M` | low | multiple | skip |
| 16 | `Mistral-Nemo` | low | `mlx-community/Mistral-Nemo-Instruct-2407-4bit` | P3 — weak OR demand |
| 17 | `DeepSeek-V3.x` | low | sparse MLX | no catalog |
| 18 | `Phi-4` / `Phi-3.5` | low | community | P3 |
| 19 | `Nemotron-3-Super-120B` | low | too large | no catalog |
| 20 | `gemma-3-270m-it` | low (TG leaderboard artifact) | multiple | skip |

**Hardware fit — top P1 candidate `Qwen3.6-35B-A3B`:**

| Chip tier | oMLX TG p50 @4k (4bit) | Adj TG (×0.85) | Min RAM | Recommend |
|---|---:|---:|---:|---|
| M5 Max 40c | 73–91 (1k-heavy); 4k est. **45–55** | **38–47** | 32 GB+ | Tier-A row |
| M4 Pro 48GB | est. **25–35** | **21–30** | 32 GB | Tier-B marginal |
| M5 32GB base | 13–15 (64k rows) | **11–13** | 32 GB tight | **not recommended** |

### 2.5 Chips that should NOT be recommended (per model)

| Catalog key | Block chips / configs | Reason |
|---|---|---|
| `qwen3-32b` | M4 32GB, M-base | oMLX TG <6; OOM at 32k |
| `qwen2.5-coder-32b-instruct` | M4 Pro 48GB | TG ~12 < proposed gate 15 |
| `nvidia/nemotron-3-nano-30b-a3b` | All Tier-C <32GB RAM | MoE residency + sparse evidence |
| `meta-llama/llama-3.2-3b-instruct` | M1 8GB | TG ~2; gate fiction at 15 |
| `google-gemma-4-26b-a4b-it` | none at ≥32GB | viable back to 28 GB min_ram |
| `qwen3-coder-30b-a3b-instruct` | M4 32GB borderline | TG ~34 oMLX → adj 29 OK; M2 Pro 47 |

---

## Part 3 — Catalog delta proposals

Max 15 ranked changes. Evidence types: **oMLX**, **local-bench**, **both**, **extrapolated**.

| Priority | Change type | Target row | Current | Proposed | Evidence | Risk |
|---|---|---|---|---|---|---|
| **P0** | `min_sustained_tps` ↓ | `nvidia/nemotron-3-nano-30b-a3b` | **30** | **20** | oMLX proxy + RESEARCH_227 rank 68; no local 30B bench | false reject providers |
| **P0** | `min_sustained_tps` ↓ | `qwen3-32b` | **15** | **10** | oMLX M4 Pro p50=11 → adj 9 (oMLX); RESEARCH_226 dense tier | admit slow 32B on M-Pro |
| **P1** | new row | `qwen3.6-35b-a3b` | — | TPS **18**, RAM **32**, tier **B**, TTFT **3500** | oMLX demand #1; RESEARCH_227 MoE lane | artifact pin + local repro required |
| **P1** | `min_sustained_tps` ↓ | `qwen2.5-coder-32b-instruct` | **20** | **15** | oMLX M4 Max p50=17 → adj 14 (oMLX) | buyer QoS on M4 Max |
| **P2** | `min_sustained_tps` ↓ | `meta-llama/llama-3.2-3b-instruct` | **15** | **8** | oMLX M1 8GB TG=2 (oMLX); Entry 116 8GB target | admits non-viable 8GB? — pair with RAM floor |
| **P2** | `min_ram_gb` ↑ | `meta-llama/llama-3.2-3b-instruct` | **4** | **8** | oMLX shows 8GB config TG=2; 4GB not viable | blocks 8GB row intent — **conflicts Entry 116**; defer |
| **P2** | `min_bandwidth_tier` ↑ | `qwen3-32b` | **B** | **A** | oMLX: Tier-B TG below gate | shrinks eligible pool |
| **P3** | demote `runtime_status` | community merges (`Qwythos`, Heretic) | n/a | `research_only` | oMLX volume, no mlx pin | none — not in catalog |
| **P3** | `max_4k_ttft_ms` ↑ | `qwen3-8b` | **4500** | **5000** | local p95 **3733** + headroom (both) | minor QoS soft warning |
| **P3** | new row | `qwen3-coder-next` | — | draft | oMLX coding demand | no pin |
| **P3** | `min_sustained_tps` hold | `qwen3-coder-30b-a3b-instruct` | **20** | **18** | oMLX p50 72 (oMLX); no local | low priority |
| **P3** | `min_sustained_tps` hold | `openai/gpt-oss-20b` | **15** | keep | both: local 18.3 | none |
| **P3** | `min_sustained_tps` hold | `google-gemma-4-26b-a4b-it` | **10** | keep | both: local 12.5 | none |
| **P3** | flag loose gate | `meta-llama/llama-3.1-8b-instruct` | **15** | keep (monitor) | oMLX p10 >>15 on M3 Max | admits underperf hardware — advisory OK |
| **P3** | rate-card follow-up | `qwen3.6-35b-a3b` | — | ~$0.16/M per RESEARCH_227 | demand | pricing PR separate |

**Hard rules compliance:**

- No proposal lowers `model_sha256` requirements.
- P1 `qwen3.6-35b-a3b` requires HF snapshot + SPEC-023 §3.2 hash before publish.
- oMLX-only P0 items (`nemotron`, `qwen3-32b`) require **falsification benches** (Part 5) before merge.

---

## Part 4 — Autotune gate calibration

### 4.1 `min_sustained_tps` vs oMLX TG

| Catalog key | Gate | oMLX p25@4k (adj×0.85) | oMLX p50@4k (adj) | Local median | Gate vs p25 | Verdict |
|---|---:|---:|---:|---:|---|---|
| `openai/gpt-oss-20b` | 15 | ~55† | ~60† | **18.3** | gate > local | **OK** — local is binding |
| `google-gemma-4-26b-a4b-it` | 10 | ~28 | ~32 | **12.5** | gate < local | **OK** |
| `qwen3-8b` | 15 | ~12 | ~14 | **23.9** | gate < local | **OK** |
| `qwen3-coder-30b-a3b-instruct` | 20 | ~40 | ~61 | — | gate << oMLX | **loose** (advisory) |
| `qwen3-32b` | 15 | ~4 | ~9 | — | gate > p50 | **too tight** |
| `qwen2.5-coder-32b-instruct` | 20 | ~10 | ~14 | — | gate > p50 | **tight** |
| `nvidia/nemotron-3-nano-30b-a3b` | 30 | ~30¶ | ~34¶ | — | gate ≈ p25 | **too tight** on Tier-C |
| `meta-llama/llama-3.2-3b-instruct` | 15 | ~2 | ~2 | — | gate >> p50 | **far too loose** |
| `meta-llama/llama-3.1-8b-instruct` | 15 | ~30 | ~37 | — | gate << p50 | **loose** (advisory) |

† Tier-A M5 Pro samples — not Tier-C admission path.

### 4.2 `max_4k_ttft_ms` vs PP-implied TTFT

Formula: `ttft_est_ms ≈ 4096 / PP × 1000` (prefill-only lower bound).

| Catalog key | Gate ms | PP p50 @4k | TTFT est ms | Local p95 TTFT | Recommended max_4k |
|---|---:|---:|---:|---:|---:|
| `openai/gpt-oss-20b` | 2500 | 1783 | **2295** | 1590 | **2500** |
| `google-gemma-4-26b-a4b-it` | 3000 | 328 (M4) | **12,488** | 2611 | **3000** — PP proxy useless (warm/cache) |
| `qwen3-8b` | 4500 | 217 (M4) | **18,876** | 3733 | **4500–5000** |
| `qwen3-coder-30b-a3b-instruct` | 3500 | 1266 | **3235** | — | **3500** |
| `qwen3-32b` | 4000 | 88 | **46,545** | — | **4000** — proxy fails; use autotune only |
| `qwen2.5-coder-32b-instruct` | 3500 | 168 | **24,381** | — | **3500** |
| `nvidia/nemotron-3-nano-30b-a3b` | 3000 | 291 | **14,075** | — | **3000** |

**PP proxy caveat:** oMLX PP is often measured warm with prefix-cache hits; macprovider Stage-1 TTFT includes cold tokenizer + graph compile. **Do not tighten TTFT gates from oMLX PP alone.**

### 4.3 Gate slack policy (recommended)

```
min_sustained_tps = min(
    floor(local_median × 0.80),          # when local bench exists — binding
    floor(oMLX_p25 × engine_delta × 0.90) # when oMLX-only
)
```

- Never set below **8** for recommendable rows (buyer QoS floor).
- **Raise** gates only with **local** bench showing headroom >30% above current gate.
- Identify **too-loose** gates: oMLX p10 (adj) > 2× gate → flag for hardware-evidence drift monitoring, not auto-tighten.

### 4.4 SPEC-023 §5 implications

Per SPEC-023 v0.2–v0.5: `min_sustained_tps` / `max_4k_ttft_ms` are **advisory QoS**. oMLX calibration therefore:

1. **Informs** operator publish values and hardware-evidence expectations.
2. **Does not** justify hard-blocking without policy change (would need `hard_min_sustained_tps`).
3. **Feeds** OPoI drift when attested provider TG chronically below oMLX p25 for same chip class — coordinator `benchmarkPassesGate` still uses catalog hash + evidence match.

---

## Part 5 — Monitoring and refresh loop

### 5.1 Operator cadence

| Artifact | Source | Cadence | Owner |
|---|---|---|---|
| `omlx-benchmark-snapshot-YYYY-MM.json` | `omlx.ai/benchmarks` filtered crawl | **monthly** | operator |
| `catalog-calibration-memo-YYYY-MM.md` | rerun RESEARCH_231 prompt | **quarterly** | operator |
| `autotune-candidates.json` delta | Part 3 P0/P1 after local repro | **after memo + bench** | PR author |
| `UPSTREAM_WATCH.json` oMLX stanza | release tag + schema check | **monthly** | operator |

### 5.2 UPSTREAM_WATCH addition

Added to `beta/throughput-engineering/UPSTREAM_WATCH.json`:

```json
"omlx": {
  "repo": "jundot/omlx",
  "homepage": "https://omlx.ai",
  "latest_release_tag": "v0.5.0.dev3",
  "benchmark_page_schema_version": "2026-07-09",
  "community_benchmark_rows_approx": 321280,
  "submission_min_app_version": "v0.2.6",
  "runbook_tasks": ["RESEARCH_231", "catalog-calibration"],
  "notes": "Community board uses mlx-lm; macprovider applies 0.85× engine_delta. Not a runtime dependency."
}
```

### 5.3 Falsification benches (post-delta)

Run on macprovider `mlx-swift-lm` 3.31.4 before shipping P0/P1 catalog changes:

| ID | Model | Chip target | Context | Expected TG band | Pass criterion |
|---|---|---|---|---|---|
| FB-01 | `NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | M5 32GB | 4k | **18–28** tok/s | median ≥20 if gate→20 |
| FB-02 | `Qwen3-32B-4bit` | M4 Pro 48GB | 4k | **8–14** tok/s | median ≥10 if gate→10 |
| FB-03 | `Qwen2.5-Coder-32B-Instruct-4bit` | M4 Max 64GB | 4k | **12–20** tok/s | median ≥15 if gate→15 |
| FB-04 | `Qwen3.6-35B-A3B-4bit` | M4 Max 48GB | 4k | **20–35** tok/s | median ≥18 before new row |
| FB-05 | `Llama-3.2-3B-Instruct-4bit` | M4 16GB | 4k | **10–25** tok/s | median ≥8 if gate→8 |
| FB-06 | `gpt-oss-20b-MXFP4-Q8` | M5 32GB | 4k | **15–25** tok/s | regression guard ≥15 |
| FB-07 | `gemma-4-26b-a4b-it-4bit` | M5 32GB | 4k | **10–15** tok/s | regression guard ≥10 |
| FB-08 | `Qwen3-8B-4bit` | M5 32GB | 4k | **20–28** tok/s | regression guard ≥15 |

Protocol: P1-01 clean-machine autotune, `--stage1-replicates 3`, `--drain`, port 18080.

---

## Appendix A — Model-name normalization table

| oMLX display pattern | Normalized catalog key | mlx-community `model_id` | Match quality | `runtime_status` |
|---|---|---|---|---|
| `gpt-oss-20b-MXFP4-Q8` | `openai/gpt-oss-20b` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | **exact** | recommendable |
| `gpt-oss-20b-MXFP4-Q4` | `openai/gpt-oss-20b` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | quant variant | recommendable (same class) |
| `gemma-4-26b-a4b-it` | `google-gemma-4-26b-a4b-it` | `mlx-community/gemma-4-26b-a4b-it-4bit` | **exact** | recommendable |
| `gemma-4-26B-A4B-it-oQ8` | `google-gemma-4-26b-a4b-it` | `mlx-community/gemma-4-26b-a4b-it-4bit` | quant variant | recommendable |
| `gemma-4-31b-it` | — | `mlx-community/gemma-4-31b-it-4bit` | exact (not in catalog) | research_only |
| `Qwen3-Coder-30B-A3B-Instruct*` | `qwen3-coder-30b-a3b-instruct` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | **exact** | recommendable |
| `Qwen3-Coder-Next*` | — | verify HF | name-only | experimental |
| `Qwen3-32B*` | `qwen3-32b` | `mlx-community/Qwen3-32B-4bit` | **exact** | recommendable |
| `Qwen3.6-27B*` | `qwen3-32b` (proxy) | none exact | family proxy | research_only |
| `Qwen3.6-35B-A3B*` | `qwen3.6-35b-a3b` (proposed) | `mlx-community/Qwen3.6-35B-A3B-4bit` | verify pin | draft |
| `Qwen3.5-35B-A3B*` | `qwen3-30b-a3b` (legacy) | `mlx-community/Qwen3-30B-A3B-Instruct-4bit` | generational | research_only |
| `Qwen3-8B` / `Qwen3.5-9B*` | `qwen3-8b` | `mlx-community/Qwen3-8B-4bit` | proxy | recommendable |
| `Qwen2.5-Coder-32B-Instruct` | `qwen2.5-coder-32b-instruct` | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | **exact** | recommendable |
| `Meta-Llama-3-8B-Instruct` | `meta-llama/llama-3.1-8b-instruct` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | **exact** | recommendable |
| `Llama-3.2-3B-Instruct` | `meta-llama/llama-3.2-3b-instruct` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | **exact** | recommendable |
| `NVIDIA-Nemotron-3-Nano-30B*` | `nvidia/nemotron-3-nano-30b-a3b` | `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | **exact** | recommendable |
| `NVIDIA-Nemotron-3-Nano-4B` | `nvidia/nemotron-3-nano-30b-a3b` (wrong) | proxy only | param mismatch | do not use for gate |
| `MiniMax-M2.5` | — | `mlx-community/MiniMax-M2.5-4bit` | exact | Tier-S blocked |
| `GLM-5*` | — | `mlx-community/GLM-5.2-4bit` | exact | Tier-S blocked |
| `Qwythos-9B-*` | — | none | community FT | experimental |
| `*-Heretic-*` / `*-uncensored-*` | — | none | community FT | research_only |
| `*-Claude-4.6-Opus-*` distill | — | none | merge | research_only |
| `copywriter-gemma4-31b-oQ6` | — | none | community | research_only |
| `SmolLM2-360M*` | — | various | micro | skip |
| `LFM2-24B-A2B` | — | verify HF | MoE | experimental |

---

## Appendix B — Scrape notes (2026-07-09)

### B.1 Network behavior

| Observation | Detail |
|---|---|
| Cloudflare | Burst curl/WebFetch → **429**; per-run detail URLs less restricted via search cache |
| Pagination | 10 rows/page; `294k–321k` total rows reported depending on sort/filter |
| Sort keys | `sort=tg_tps|date|pp_tps`, `order=asc|desc` |
| Date format | `YY-MM-DD` (e.g. `26-07-06` = 2026-07-06) |
| Context filter | `context=4096` for 4k; also `1k`, `8192`, `32768`, `65536` |

### B.2 Known data quality issues

| Issue | Source | Mitigation |
|---|---|---|
| KV memcpy in TG (pre-May 2026) | oMLX issue #1007 | Date filter ≥ 2026-05-01 |
| Tester self-spam | issue #1007 author | IQR trim + dedup |
| CPU-variant rows dropped on sort | issue #1007 | Document; not relevant to MLX |
| 1k context TG sort leaderboard pollution | board default sort | Always filter `context=4096` for catalog |
| Custom quant names (`oQ4`, `RotorQuant`) | community | Map to nearest bit bucket; lower confidence |
| Model column truncation | HTML `...` | Follow detail page for full name |

### B.3 Example snapshot records (structured)

```json
[
  {
    "id": "yurm6qxb",
    "chip_full": "M5 Pro (16c)",
    "ram_gb": 48,
    "model_display": "gpt-oss-20b-MXFP4-Q8",
    "quant": "4bit",
    "context": 4096,
    "pp_tps": 1783,
    "tg_tps": 71.0,
    "peak_mem_gb": 11.8,
    "omlx_version": "v0.2.24",
    "date": "2026-03-30",
    "catalog_key": "openai/gpt-oss-20b"
  },
  {
    "id": "a9cjuzat",
    "chip_full": "M4 (10c)",
    "ram_gb": 24,
    "model_display": "gemma-4-26b-a4b-it",
    "quant": "4bit",
    "context": 4096,
    "pp_tps": 328.0,
    "tg_tps": 33.3,
    "peak_mem_gb": 14.9,
    "omlx_version": "v0.3.8",
    "date": "2026-05-04",
    "catalog_key": "google-gemma-4-26b-a4b-it"
  },
  {
    "id": "tlthy0ab",
    "chip_full": "M5 Pro (20c)",
    "ram_gb": 24,
    "model_display": "Qwen3-Coder-30B-A3B-Instruct4bit",
    "quant": "4bit",
    "context": 4096,
    "pp_tps": 2392,
    "tg_tps": 78.5,
    "peak_mem_gb": 16.3,
    "omlx_version": "v0.3.8",
    "date": "2026-05-11",
    "catalog_key": "qwen3-coder-30b-a3b-instruct"
  }
]
```

### B.4 Alternative datasets (not primary)

| Dataset | URL | Notes |
|---|---|---|
| Anubis OSS leaderboard | https://devpadapp.com/leaderboard.html | Multi-engine (Ollama/LM Studio/MLX); useful cross-check, not mlx-lm specific |
| mlx-Chronos | GitHub PR/discussion #1391 | Engine comparison protocol; complementary |
| oMLX marketing benches | https://omlx.ai/ | M3 Ultra 512GB controlled; not community |

---

## Decision log cross-reference

Append to `beta/DECISION_CRITERIA.md` when acting on this memo:

- **Entry TBD:** RESEARCH_231 oMLX calibration adopted; engine_delta=0.85; P0 gate changes gated on FB-01..FB-03 local repro.
- RESEARCH_227 linkage: `qwen3.6-35b-a3b` P1 requires rate-card row before recommendable publish.
- RESEARCH_232/233: oMLX remains reference-only; no runtime integration.

---

*Memo complete. Next step: operator monthly snapshot + FB-01..FB-03 falsification on task hardware before catalog PR.*
