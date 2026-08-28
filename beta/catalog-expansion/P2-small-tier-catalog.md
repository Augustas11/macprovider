# P2-02 — Small-tier catalog publish (`qwen3-8b`)

**Task:** P2-02 (Model Catalog Expansion Runbook v0.1.10)  
**Date:** 2026-07-07  
**Executor timestamp (UTC):** 2026-07-07T11:54:07Z  
**Branch:** `fix/p2-02-qwen3-8b-small-tier` (worktree `../macprovider-p2-02`)  
**Verdict:** **PASS**

---

## Operator choice (locked)

| Field | Value |
|-------|-------|
| **Catalog key** | `qwen3-8b` |
| **MLX ID** | `mlx-community/Qwen3-8B-4bit` |
| **Target RAM** | 12–16 GB Macs |
| **Pricing lane** | small-dense — matches `meta-llama/llama-3.1-8b-instruct` ($0.027/M completion) |

**Instruct variant note:** HF search of `mlx-community/Qwen3-8B*` found quant variants (3/4/6/8-bit, DWQ, AWQ) but **no** `*-Instruct-*` repo. Operator locked base `Qwen3-8B-4bit`; chat template in `config.json` supports conversational use via Qwen3 template.

---

## Step 0 — HF + registry gate

| Check | Result |
|-------|--------|
| Repo exists | **PASS** — [mlx-community/Qwen3-8B-4bit](https://huggingface.co/mlx-community/Qwen3-8B-4bit) |
| **model_revision** | `545dc4251c05440727734bcd94334791f6ab0192` |
| License | **Apache-2.0** |
| `config.json` → `model_type` | **`qwen3`** — registered in mlx-swift-lm 3.31.4 (`LLMModelFactory.swift`) |
| Safetensors size | **4.61 GB** (`model.safetensors.index.json` total_size) |
| 16 GB resident estimate | **PASS** — weights 4.6 GB; fits 16 GB Mac with headroom (≪ 12 GB resident ceiling) |

### Artifact hash

| Field | Value |
|-------|-------|
| **model_sha256** | `1f591f9c4fb38d05ea2d879d89a6eeab485c23a04eb75e3e0a289db9d95ec877` |
| **Method** | SPEC-023 §3.2 canonical artifact-set hash on HF snapshot `545dc425…` (11 files, verified byte-for-byte against `ModelArtifactVerifier` algorithm) |

### Alias / normalization

| Incoming string | Normalized key | Rate-card row |
|-----------------|----------------|---------------|
| `qwen3-8b` | `qwen3-8b` | exact |
| `mlx-community/Qwen3-8B-4bit` | `qwen3-8b` | via normalization |
| `Qwen/Qwen3-8B` (buyer) | `qwen3-8b` | via `qwen/` namespace strip + suffix strip |

No separate alias row required (unlike Gemma google-slash path).

---

## Step 1 — Bench matrix

**Protocol:** P1-01 clean-machine (`--drain`, port 18080, `--stage1-replicates 3`).

| Field | Value |
|-------|-------|
| **Machine** | MacBook Air Mac17,3 — Apple **M5**, **32 GB** RAM (16 GB tier not available on executor) |
| **Binary** | `/Applications/Malibu.app/Contents/MacOS/malibu-cli` **1.8.19** |
| **Note** | Worktree `swift build -c release` binary fails MLX metallib load; Malibu binary used for bench (same as prior Llama 8B session logs) |
| **run_id** | `FC1DCD16-B6AD-4F28-AC48-478EB4C25335` |
| **Started (UTC)** | `2026-07-07T11:37:52Z` |
| **Pre-warm** | Model downloaded + served; 3/3 Stage-1 probe completions |

| Metric | Value |
|--------|-------|
| **Median sustained TPS** | **23.93** tokens/sec |
| **p95 TTFT ms** | **3733.3** ms |
| **Probe shape** | `target_context=2000`, `measured_prompt_tokens=1600`, `max_tokens=64`, `replicates=3` |
| **OOM / swap blowout** | **N** |
| **Resident RAM (est.)** | ~6–7 GB at load (4.6 GB weights + KV @ 2000 ctx); **min_ram_gb=12** (resident + 4 GB safety, Llama 8B pattern) |

### Proposed gates (published)

| Gate | Value | Rationale |
|------|-------|-----------|
| `min_sustained_tps` | **15** | Llama 8B small-dense template; measured 23.9 (~80% = 19.1) |
| `max_4k_ttft_ms` | **4500** | p95 3733 + ~800 ms headroom |
| `min_ram_gb` | **12** | 4.6 GB weights + 4 GB admission margin |
| `min_bandwidth_tier` | **C** | M-Base M5 measured |

Autotune `--recommend` ended `internal_error` (model not yet in catalog during bench); Stage-1 metrics above are authoritative for gate setting.

---

## Step 2 — Rate card

Added to `phase4-coordinator/dist/coordinator.yaml`:

```yaml
qwen3-8b:
  prompt_credits_per_mtok: 13500
  prompt_cache_hit_credits_per_mtok: 3375
  completion_credits_per_mtok: 27000
```

| Lane | Completion $/M |
|------|----------------|
| `meta-llama/llama-3.1-8b-instruct` | $0.027 |
| **`qwen3-8b` (new)** | **$0.027** |

Baked offline fallback: `qwen3-8b` row added to `bakedRateCardJSON` at 13.5k / 27k credits (version `baked-2026-07-07-p2-drift` unchanged).

---

## Step 3 — Static feeds + baked fallback

| Field | Value |
|-------|-------|
| **Catalog version** | `published-2026-07-07-p2-qwen3-8b` |
| **generated_at** | `2026-07-07T12:00:00Z` |
| **Recommendable rows** | **9** (8 unchanged + `qwen3-8b`) |

**Demand row:** rank **18**, weight **0.38**, recommendable **true**, min_provider_target **15**.

**Files touched:**

- `phase3-binary/dist/static/autotune-candidates.json`
- `phase3-binary/dist/static/demand-rank.json`
- `phase3-binary/Sources/malibu-cli/AutotuneRecommend.swift` — all three baked strings byte-aligned with live + rate card

---

## Step 4 — Static v4 re-sign

**PASS** — `scripts/resign-autotune-static.sh`, key_id `streamvc-autotune-static-v4`.

---

## Step 5 — Tier-2 catalog (9 models)

| Field | Value |
|-------|-------|
| **catalog_id** | `macprovider-tier2-model-catalog-2026-07-07-p2-qwen3-8b` |
| **issued_at** | `2026-07-07T00:00:00Z` |
| **expires_at** | `2026-10-07T00:00:00Z` |
| **model count** | **9** |
| **signature key_id** | `catalog-key-2026q2` |
| **Local verify** | **PASS** |
| **Unsigned artifact** | `.omc/tier2/tier2-catalog-2026-07-07-p2-qwen3-8b.unsigned.json` |
| **Signed artifact** | `.omc/tier2/tier2-catalog-2026-07-07-p2-qwen3-8b.signed.json` |

Qwen3-8B tier-2 entry: `mlx-community/Qwen3-8B-4bit` sha256 `1f591f9c…ec877`, min_ram_gb **12**.

---

## Step 6 — Tests

| Suite | Result |
|-------|--------|
| `swift test --filter AutotuneRecommend` | **PASS** — 91 tests |
| `swift test --filter AutotuneRecommendSimulate` | **PASS** — 4 tests |
| `go test ./internal/billing/... ./internal/config/...` | **PASS** |

Test fixtures updated: `published-2026-07-07-p1-gemma` → `published-2026-07-07-p2-qwen3-8b` in `AutotuneRecommendTests.swift` / `AutotuneRecommendSimulateTests.swift`.

---

## Step 7 — Deploy

| Surface | Deployed | Timestamp (UTC) | Method |
|---------|----------|-----------------|--------|
| Static feeds | **Y** | 2026-07-07T11:54:07Z | SCP → `/opt/macprovider/static/` (+ `.sig`) |
| Coordinator (rate card) | **Y** | 2026-07-07T11:54:07Z | SCP `coordinator.yaml` + `systemctl kill -s HUP macprovider-coordinator` |
| Tier-2 catalog | **Y** | 2026-07-07T11:54:07Z | SCP → `/opt/macprovider/tier2-catalog.json` (backup `bak-p2-02-20260707T115407Z`) |

Journal: `catalog_loaded` with `catalog_id=macprovider-tier2-model-catalog-2026-07-07-p2-qwen3-8b`, `model_count=9`, `tier2 config reloaded`.

---

## Step 8 — Post-deploy verification

```bash
# Tier-2 (public)
curl -sS https://coordinator.malibu.tech/catalog/current
# → catalog_id macprovider-tier2-model-catalog-2026-07-07-p2-qwen3-8b, 9 models, Qwen3-8B present

# Rate card (public)
curl -sS https://coordinator.malibu.tech/v1/rate-card | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['rows']['qwen3-8b'])"
# → completion_rate_per_mtok 27000

# Static (on-host — nginx /static/ returns 404/rate-limit from this executor IP)
ssh root@159.223.165.194 python3 -c \
  "import json; d=json.load(open('/opt/macprovider/static/autotune-candidates.json')); \
   print(d['version'], len(d['rows']), d['rows']['qwen3-8b']['runtime_status'])"
# → published-2026-07-07-p2-qwen3-8b 9 recommendable
```

---

## P2-02 deliverable summary

```
P2-02 VERDICT: PASS
Catalog key: qwen3-8b
model_revision / model_sha256: 545dc4251c05440727734bcd94334791f6ab0192 / 1f591f9c4fb38d05ea2d879d89a6eeab485c23a04eb75e3e0a289db9d95ec877
Catalog version: published-2026-07-07-p2-qwen3-8b
Tier-2 catalog_id: macprovider-tier2-model-catalog-2026-07-07-p2-qwen3-8b
Deploy: static Y, coordinator Y, tier-2 Y
Tests: AutotuneRecommend 91/91, AutotuneRecommendSimulate 4/4, go billing+config PASS
Artifact: beta/catalog-expansion/P2-small-tier-catalog.md
PR: (not created — awaiting operator commit/PR request)
```

---

## Caveats

1. **Bench RAM tier:** measured on **32 GB** M5, not 16 GB; gates are conservative (12 GB min_ram, TPS gate 15 vs measured 23.9).
2. **Base vs Instruct:** no mlx-community Instruct quant repo; catalog publishes base Qwen3-8B weights.
3. **Worktree release binary:** `swift build -c release` in fresh worktree lacks bundled MLX metallib; use Malibu.app or macprovider-poc release build for hardware bench.
4. **Public `/static/*` URL:** files verified on-host at `/opt/macprovider/static/`; external curl to `/static/autotune-candidates.json` returned 404/rate-limit from executor network (pre-existing nginx/rate-limit behavior).
