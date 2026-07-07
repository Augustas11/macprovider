# P0-02 re-run — Production tier-2 vs autotune catalog diff

**Task:** P0-02 re-run after P0-06 tier-2 republish  
**Pull timestamp (UTC):** 2026-07-07T06:12:30Z  
**Trigger:** P0-06 deploy of `macprovider-tier2-model-catalog-2026-07-07`  
**Prior artifact:** `beta/catalog-expansion/P0-02-tier2-catalog-snapshot.md` (RED)

---

## Sources

| Source | URL / path | Result |
|--------|------------|--------|
| Live autotune | `https://coordinator.streamvc.live/static/autotune-candidates.json` | HTTP 200 |
| Live tier-2 | `https://coordinator.streamvc.live/catalog/current` | HTTP 200 |
| Pearl on-disk | `/opt/macprovider/tier2-catalog.json` | Updated 2026-07-07T06:12:04Z (P0-06 deploy) |

---

## Live autotune catalog

| Field | Value |
|-------|-------|
| **version** | `published-2026-07-06-mbase-lite` |
| **generated_at** | `2026-07-06T11:45:00Z` |
| **recommendable row count** | 7 |

Unchanged from initial P0-02 pull.

---

## Production tier-2 catalog (`GET /catalog/current`)

| Field | Value |
|-------|-------|
| **catalog_id** | `macprovider-tier2-model-catalog-2026-07-07` |
| **issued_at** | `2026-07-07T00:00:00Z` |
| **expires_at** | `2026-10-07T00:00:00Z` |
| **model count** | 7 |
| **signature** | Ed25519, `key_id=catalog-key-2026q2` (sig redacted) |

### Tier-2 model entries

| model_id | sha256 | min_ram_gb |
|----------|--------|------------|
| `mlx-community/gpt-oss-20b-MXFP4-Q8` | `f25592861e0b7f4eb8489d9103214f3f0dc4f798bb0e4e0cd817ff2f4191f1b1` | 24 |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | `3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a` | 4 |
| `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `67b26d6b1c50dc8836ab3705b06276a43c74c8f66247f9b112e232b58abbd99f` | 12 |
| `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | `1bc78f214f9a042eaeb290b1fa4cb29915df1028f79d8479266349166c40a71f` | 32 |
| `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | `b7749cc57f37f7e9239d0f9b091bcffe6d7629e48af75e8cb84c1cdca1780973` | 48 |
| `mlx-community/Qwen3-32B-4bit` | `69169cceb643f108755f96dba26d8647862e38a7f82cb1b5b25aff8f204967aa` | 48 |
| `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0` | 28 |

---

## Diff summary (autotune recommendable ↔ tier-2 by `model_id`)

| Metric | Count |
|--------|-------|
| Autotune recommendable | 7 |
| Tier-2 models | 7 |
| Full match (sha256 + min_ram_gb) | **7** |
| Autotune-only (missing from tier-2) | **0** |
| Tier-2-only orphans | **0** |
| SHA or min_ram_gb mismatch | **0** |

### Resolved from prior RED

| Issue (P0-02 initial) | Re-run status |
|-----------------------|---------------|
| 6 autotune-only models absent from tier-2 | **Fixed** — all 7 present |
| Llama-3.2-3B SHA mismatch (`3975387f…` vs `0baf1371…`) | **Fixed** — autotune hash served |
| Orphan `Qwen2.5-7B-Instruct-4bit` | **Removed** (operator decision: retire) |
| Orphan `Qwen2.5-Coder-7B-Instruct-4bit` | **Removed** (operator decision: retire) |

---

## Verdict: **GREEN**

| Criterion | Assessment |
|-----------|------------|
| All 7 live recommendable keys listed with hashes | **Pass** |
| No orphan tier-2-only rows without explanation | **Pass** |
| No SHA mismatch on live models present in both catalogs | **Pass** |
| Gemma-4 split-brain | **Pass** — not present in tier-2 |

**P0-02 re-run: GREEN** — tier-2 aligned to live autotune; G2 block cleared.
