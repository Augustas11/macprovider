# P1 — Gemma-4 catalog rollout artifact

**Catalog key:** `google-gemma-4-26b-a4b-it`  
**MLX ID:** `mlx-community/gemma-4-26b-a4b-it-4bit`  
**Task:** Model Catalog Expansion Runbook v0.1.8  
**Date:** 2026-07-07

---

## P1-02 — Rate card

### Pricing option

**Option A (default)** — completion target **$0.240/M**, 20% undercut vs **$0.300/M** OpenRouter/Cloudflare cheapest paid (RESEARCH_226/227).

| Option | Completion $/M | Undercut vs | Source |
|--------|----------------|-------------|--------|
| **A (chosen)** | **$0.240** | 20% under $0.30/M | RESEARCH_226/227 |
| B | $0.165 | ~Darkbloom live parity | Darkbloom prod |
| C | $0.30 | none | OpenRouter cheapest paid |

### Credits table (`usd_per_million_credits: 1.0`)

| Rate-card key | Prompt credits/M | Prompt cache-hit credits/M | Completion credits/M | Prompt $/M | Cache-hit $/M | Completion $/M |
|---------------|------------------|----------------------------|----------------------|------------|---------------|----------------|
| `google-gemma-4-26b-a4b-it` | 60,000 | 15,000 (25% of prompt) | 240,000 | $0.060 | $0.015 | **$0.240** |
| `gemma-4-26b-a4b-it` (alias) | 60,000 | 15,000 | 240,000 | $0.060 | $0.015 | **$0.240** |

### Comparable MacProvider rows

| Model | Prompt $/M | Completion $/M |
|-------|------------|----------------|
| `openai/gpt-oss-20b` | $0.050 | $0.100 |
| `qwen3-coder-30b-a3b-instruct` | $0.1175 | $0.235 |
| `nemotron-3-nano-30b-a3b` | $0.080 | $0.160 |
| **`google-gemma-4-26b-a4b-it` (new)** | **$0.060** | **$0.240** |

### Market anchors

| Anchor | Completion $/M | MacProvider undercut |
|--------|----------------|----------------------|
| OpenRouter Cloudflare (`google/gemma-4-26b-a4b-it`) | $0.300 | **20.0%** → $0.240 |
| Darkbloom prod (`gemma-4-26b`) | $0.165 | n/a (Option B not chosen) |

### Provider economics (P1-01 bench @ 32 GB Tier-C)

P1-01 measured **12.5 tok/s** sustained median on M5 32 GB ([`P1-gemma4-bench-matrix.md`](P1-gemma4-bench-matrix.md)). RESEARCH_226 gross formula: `TPS × 3600 × (completion_$/M / 1_000_000)`.

| Scenario | TPS | Gross $/hr @ $0.240/M | Net $/hr @ 90% share |
|----------|-----|----------------------|----------------------|
| **P1-01 measured (Tier-C 32 GB)** | 12.5 | **~$0.011** | ~$0.010 |
| RESEARCH_226 Tier-C projection band | 75–105 | ~$0.065–$0.091 | ~$0.058–$0.082 |
| RESEARCH_226 table row (Tier-A reference) | 90 | ~$0.078 | ~$0.070 |

At measured throughput, Gemma-4 clears electricity on Tier-C but is not a high-yield lane until warm sustained TPS improves or buyer mix includes prompt-heavy traffic. Pricing remains demand-led (OpenRouter rank ~20–22), not provider-$/hr-anchored.

### Alias / normalization finding

`NormalizeModelKey()` (`phase4-coordinator/internal/billing/formula.go:65–88`) and `AutotuneModelKeyNormalizer` (`AutotuneRecommend.swift:635–665`) share the same rules.

| Incoming model string | Normalized key | Matches `google-gemma-4-26b-a4b-it` row? |
|-----------------------|----------------|------------------------------------------|
| `google-gemma-4-26b-a4b-it` | `google-gemma-4-26b-a4b-it` | **Yes** (exact) |
| `google/gemma-4-26b-a4b-it` | `gemma-4-26b-a4b-it` | Via **alias row** |
| `mlx-community/gemma-4-26b-a4b-it-4bit` | `gemma-4-26b-a4b-it` | Via **alias row** |

**Served model key (autotune path):** `servedModelKey()` returns the rate-card key `google-gemma-4-26b-a4b-it` for catalog key `google-gemma-4-26b-a4b-it` (no slash in catalog key → not the nemotron-style “keep public namespace” branch). Provider `serve_config.model` and billing `request_log.model` therefore use the hyphenated catalog key when traffic flows through autotune `--recommend --apply`.

**Buyer MLX-path risk:** Direct API callers may still send `mlx-community/gemma-4-26b-a4b-it-4bit` or `google/gemma-4-26b-a4b-it` in the chat `model` field (`modelForRequestLog` passes buyer string verbatim to `RateFor`). Without the alias row, those strings normalize to `gemma-4-26b-a4b-it` and would fall through to `default` ($1.00/M completion — silent overcharge). **Fix applied:** duplicate credits under alias key `gemma-4-26b-a4b-it`.

**Rate-card projection (`/v1/rate-card`):** Both keys project to themselves (`recommendationRateCardProjectionKey` is identity for keys without known namespace slashes). Autotune `rowForRecommendation("google-gemma-4-26b-a4b-it")` hits the primary row; MLX buyer strings hit the alias via normalization.

### coordinator.yaml diff summary

Added after `nemotron-3-nano-30b-a3b` (v4 rows), before `admission:`:

- `google-gemma-4-26b-a4b-it`: prompt **60,000**, cache-hit **15,000**, completion **240,000** credits/M
- `gemma-4-26b-a4b-it`: same credits (MLX/google-slash normalization alias)

---

## P1-03 — Catalog publish

**Executor timestamp (UTC):** 2026-07-07T08:04:20Z  
**Branch:** `fix/p1-03-gemma-catalog-publish` (from `fix/p1-02-gemma-rate-card`)  
**Verdict:** **PASS**

### Artifact resolution (Step 1)

| Field | Value |
|-------|-------|
| **model_revision** | `0d77464eeb233a2da68ebf9d7dc4edaac7db956d` (HF API `mlx-community/gemma-4-26b-a4b-it-4bit`) |
| **model_sha256** | `436ce68d2ac5a27dde3b54569736fb7a69dc3b7a175d2f633147c7802b3bc88a` |
| **Hash method** | `ModelArtifactVerifier.canonicalArtifactHash` on local cache `~/Library/Caches/models/mlx-community/gemma-4-26b-a4b-it-4bit` (Swift-verified) |

### Static feeds (Steps 2–4)

| Field | Value |
|-------|-------|
| **Catalog version** | `published-2026-07-07-p1-gemma` |
| **generated_at** | `2026-07-07T08:02:25Z` |
| **Recommendable rows** | 8 (7 unchanged + Gemma) |
| **Gemma gates** | `min_ram_gb=28`, `min_bandwidth_tier=C`, `min_sustained_tps=10`, `max_4k_ttft_ms=3000`, `runtime_status=recommendable` |
| **Demand row** | rank 22, weight 0.55, recommendable true, min_provider_target 20 |
| **Static v4 sign** | **PASS** — `scripts/resign-autotune-static.sh`, key_id `streamvc-autotune-static-v4` |

### Baked fallback (Step 3)

Updated `AutotuneRecommend.swift` baked strings to mirror live feeds byte-for-byte:

- `bakedCandidateCatalogJSON` — Gemma recommendable with revision + sha256
- `bakedDemandRankJSON` — Gemma rank 22 / weight 0.55
- `bakedRateCardJSON` — `google-gemma-4-26b-a4b-it` + `gemma-4-26b-a4b-it` alias at 60k/240k credits

### Tier-2 catalog (Step 5)

| Field | Value |
|-------|-------|
| **catalog_id** | `macprovider-tier2-model-catalog-2026-07-07-p1-gemma` |
| **issued_at** | `2026-07-07T00:00:00Z` |
| **expires_at** | `2026-10-07T00:00:00Z` |
| **model count** | 8 |
| **signature key_id** | `catalog-key-2026q2` |
| **Local verify** | **PASS** — prod pubkey fingerprint matches `coordinator.yaml` (`IVH2aAlT…0U9aFQ`) |
| **Unsigned artifact** | `.omc/tier2/tier2-catalog-2026-07-07-p1-gemma.unsigned.json` (out-of-repo) |
| **Signed artifact** | `.omc/tier2/tier2-catalog-2026-07-07-p1-gemma.signed.json` (out-of-repo) |

Gemma tier-2 entry: `mlx-community/gemma-4-26b-a4b-it-4bit` sha256 `436ce68d…bc88a`, min_ram_gb 28.

### Tests (Step 6)

| Suite | Result |
|-------|--------|
| `swift test --filter AutotuneRecommend` | **PASS** — 91 tests |
| `swift test --filter AutotuneRecommendSimulate` | **PASS** — 4 tests |
| `go test ./internal/billing/... ./internal/config/...` | **PASS** |

Optional 32 GB hardware smoke (`autotune --recommend --candidate-models … --drain`) not run in this session; G2 satisfied by unit/simulate tests + live feed verification.

### Deploy (Step 7)

| Surface | Deployed | Timestamp (UTC) | Method |
|---------|----------|-----------------|--------|
| Static feeds | **Y** | 2026-07-07T08:03:57Z | SCP → `/opt/macprovider/static/` (candidates + demand + `.sig`) |
| Coordinator (rate card) | **Y** | 2026-07-07T08:04:20Z | SCP `coordinator.yaml` + `systemctl kill -s HUP macprovider-coordinator` |
| Tier-2 catalog | **Y** | 2026-07-07T08:04:20Z | SCP → `/opt/macprovider/tier2-catalog.json` (backup `bak-p1-03-20260707T080357Z`) |

Journal: `tier2 config reloaded`, `catalog_loaded` with `model_count=8`, `catalog_id=macprovider-tier2-model-catalog-2026-07-07-p1-gemma`.

### Post-deploy verification (Step 8)

```bash
curl -sS https://coordinator.malibu.tech/catalog/current | python3 -m json.tool
# → catalog_id macprovider-tier2-model-catalog-2026-07-07-p1-gemma, 8 models, Gemma present

curl -sS https://coordinator.malibu.tech/static/autotune-candidates.json | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['version'], len(d['rows']), d['rows']['google-gemma-4-26b-a4b-it']['runtime_status'])"
# → published-2026-07-07-p1-gemma 8 recommendable

curl -sS https://coordinator.malibu.tech/v1/rate-card | python3 -c \
  "import sys,json; r=json.load(sys.stdin)['rows']; print(r['google-gemma-4-26b-a4b-it'])"
# → completion_rate_per_mtok 240000
```

Live static bytes match repo-signed artifacts; sig sidecar key_id `streamvc-autotune-static-v4` unchanged.

### G2 verdict

| Criterion | Result |
|-----------|--------|
| Static JSON live + signed | **PASS** |
| Tier-2 verifies, 8/8 models | **PASS** |
| Gemma hash matches autotune row | **PASS** (`436ce68d…bc88a`) |
| Autotune simulate / unit tests | **PASS** |

**G2: CLOSED — PASS**

---
