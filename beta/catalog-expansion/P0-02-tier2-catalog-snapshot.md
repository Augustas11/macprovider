# P0-02 — Production tier-2 vs autotune catalog diff

**Task:** P0-02 (Model Catalog Expansion Runbook)  
**Pull timestamp (UTC):** 2026-07-07T06:05:58Z  
**Executor:** read-only fetch (no deploys, no secrets)

---

## Sources

| Source | URL / path | Result |
|--------|------------|--------|
| Live autotune | `https://coordinator.streamvc.live/static/autotune-candidates.json` | HTTP 200 |
| Live tier-2 (preferred API) | `https://coordinator.streamvc.live/catalog/current` | HTTP 200 — signed catalog served |
| Tier-2 pubkey | `https://coordinator.streamvc.live/catalog/pubkey` | HTTP 200 — Ed25519 pubkey only (redacted below) |
| Pearl VPS SSH | `/opt/macprovider/tier2-catalog.json` | Not attempted (no SSH in this session) |
| Repo deploy hint | `phase4-coordinator/dist/coordinator.yaml:202` → `/opt/macprovider/tier2-catalog.json` | Confirms on-disk path; `/catalog/current` is the read-only equivalent |
| Local autotune copy | `phase3-binary/dist/static/autotune-candidates.json` | Byte-identical to live fetch at pull time |

---

## Live autotune catalog

| Field | Value |
|-------|-------|
| **version** | `published-2026-07-06-mbase-lite` |
| **generated_at** | `2026-07-06T11:45:00Z` |
| **recommendable row count** | 7 |

### Recommendable rows (runtime_status = `"recommendable"`)

| catalog_key | model_id | model_revision | model_sha256 | min_ram_gb |
|-------------|----------|----------------|--------------|------------|
| `qwen3-coder-30b-a3b-instruct` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `6e302ea604ad9ab206367e2c501d1571023e7b6d` | `10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0` | 28 |
| `openai/gpt-oss-20b` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | `773a7da77e569019bb0fd17a554b263738d669a3` | `f25592861e0b7f4eb8489d9103214f3f0dc4f798bb0e4e0cd817ff2f4191f1b1` | 24 |
| `meta-llama/llama-3.1-8b-instruct` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `241a666dad6cb93c8ff213d39a7f34a36bf26db4` | `67b26d6b1c50dc8836ab3705b06276a43c74c8f66247f9b112e232b58abbd99f` | 12 |
| `qwen3-32b` | `mlx-community/Qwen3-32B-4bit` | `bcaaf7f538adf166c1080a2befdb4f6019f66639` | `69169cceb643f108755f96dba26d8647862e38a7f82cb1b5b25aff8f204967aa` | 48 |
| `qwen2.5-coder-32b-instruct` | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | `d1e3b690c8e225d7795bccddf971ca6be68b2012` | `b7749cc57f37f7e9239d0f9b091bcffe6d7629e48af75e8cb84c1cdca1780973` | 48 |
| `nvidia/nemotron-3-nano-30b-a3b` | `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | `832f602eba5d22436c258c1462bdedc5afddb42b` | `1bc78f214f9a042eaeb290b1fa4cb29915df1028f79d8479266349166c40a71f` | 32 |
| `meta-llama/llama-3.2-3b-instruct` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `7f0dc925e0d0afb0322d96f9255cfddf2ba5636e` | `3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a` | 4 |

No non-`recommendable` rows in the live feed at pull time.

---

## Production tier-2 catalog (`GET /catalog/current`)

| Field | Value |
|-------|-------|
| **catalog_id** | `macprovider-tier2-model-catalog-2026-05-31` |
| **issued_at** | `2026-05-31T00:00:00Z` |
| **expires_at** | `2026-08-31T00:00:00Z` |
| **model count** | 3 |
| **signature** | Ed25519, `key_id=catalog-key-2026q2` (sig redacted) |
| **pubkey fingerprint** | Ed25519 pubkey served at `/catalog/pubkey` (not reproduced here) |

### Tier-2 model entries

| model_id | sha256 | min_ram_gb |
|----------|--------|------------|
| `mlx-community/Qwen2.5-7B-Instruct-4bit` | `c3b0ec86f9a59fb8416f2e037def2ed17ca012173461cd98d7b8b8da7d325e54` | 16 |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | `0baf13715db1eeb56e6d0806b0d764aa1c44497aaaaf8d2ba90c21128d9fe2fe` | 8 |
| `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` | `1e1dbaad7ef9b5df4c4157ee1e13408a7d4386de57911f41deccb3171438e204` | 16 |

All entries use `artifact_kind=mlx_weight_file`, `hash_scope=artifact_manifest`, `source=operator-curated`.

---

## Diff table (autotune recommendable ↔ tier-2 by `model_id`)

Join key: `model_id` (tier-2 has no catalog_key field; see `phase4-coordinator/internal/tier2/catalog.go:32–40`).

| catalog_key | model_id | autotune_sha256 | tier2_sha256 | match | min_ram_gb (autotune / tier2) | notes |
|-------------|----------|-----------------|--------------|-------|-------------------------------|-------|
| `qwen3-coder-30b-a3b-instruct` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `10adb5da…ab9c0` | — | **N** | 28 / — | autotune-only; absent from tier-2 |
| `openai/gpt-oss-20b` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | `f2559286…1f1b1` | — | **N** | 24 / — | autotune-only; absent from tier-2 |
| `meta-llama/llama-3.1-8b-instruct` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `67b26d6b…bd99f` | — | **N** | 12 / — | autotune-only; absent from tier-2 |
| `qwen3-32b` | `mlx-community/Qwen3-32B-4bit` | `69169cce…967aa` | — | **N** | 48 / — | autotune-only; absent from tier-2 |
| `qwen2.5-coder-32b-instruct` | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | `b7749cc5…80973` | — | **N** | 48 / — | autotune-only; absent from tier-2 |
| `nvidia/nemotron-3-nano-30b-a3b` | `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | `1bc78f21…0a71f` | — | **N** | 32 / — | autotune-only; absent from tier-2 |
| `meta-llama/llama-3.2-3b-instruct` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | `3975387f…7216a` | `0baf1371…fe2fe` | **N** | 4 / 8 | **SHA mismatch** on sole overlapping live model; autotune re-signed 2026-07-06 (rev `7f0dc925`), tier-2 still carries pre-expansion manifest |

Full SHA-256 values (no truncation):

| catalog_key | autotune_sha256 | tier2_sha256 |
|-------------|-----------------|--------------|
| `meta-llama/llama-3.2-3b-instruct` | `3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a` | `0baf13715db1eeb56e6d0806b0d764aa1c44497aaaaf8d2ba90c21128d9fe2fe` |

---

## Orphan / split-brain findings

### In autotune only (6 of 7 live recommendable models)

These models are **recommendable in the live autotune feed** but have **no tier-2 row**:

- `qwen3-coder-30b-a3b-instruct`
- `openai/gpt-oss-20b`
- `meta-llama/llama-3.1-8b-instruct`
- `qwen3-32b`
- `qwen2.5-coder-32b-instruct`
- `nvidia/nemotron-3-nano-30b-a3b`

Providers following autotune can download and serve these; tier-2 hash verification / buyer pricing manifest does not cover them until tier-2 is republished.

### In tier-2 only (orphan / legacy split-brain)

These tier-2 rows have **no matching recommendable autotune catalog_key**:

| model_id | tier2_sha256 | min_ram_gb | risk |
|----------|--------------|------------|------|
| `mlx-community/Qwen2.5-7B-Instruct-4bit` | `c3b0ec86f9a59fb8416f2e037def2ed17ca012173461cd98d7b8b8da7d325e54` | 16 | tier-2-only legacy row (May 2026 catalog) |
| `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` | `1e1dbaad7ef9b5df4c4157ee1e13408a7d4386de57911f41deccb3171438e204` | 16 | tier-2-only legacy row (May 2026 catalog) |

### Gemma-4 flag

| Check | Result |
|-------|--------|
| `google-gemma-4-26b-a4b-it` in tier-2 | **No** |
| Any `gemma-4*` / `gemma4` MLX ID in tier-2 | **No** |
| Gemma in live autotune recommendable feed | **No** (not present in live rows) |

No Gemma-4 split-brain at pull time. Gemma remains a future P1 target per runbook; not blocked by tier-2/autotune divergence today.

---

## Staleness summary

| Dimension | Autotune | Tier-2 |
|-----------|----------|--------|
| Catalog age | 2026-07-06 (`published-2026-07-06-mbase-lite`) | 2026-05-31 (`macprovider-tier2-model-catalog-2026-05-31`) |
| Model count | 7 recommendable | 3 signed entries |
| Overlap | 1 model_id shared (`Llama-3.2-3B-Instruct-4bit`) | Same |
| Hash agreement on overlap | **Fail** — different manifest SHA-256 and `min_ram_gb` (4 vs 8) |

Tier-2 was **reachable** via `/catalog/current` (not YELLOW-waivable for unreachable tier-2). The failure mode is **content drift**, not availability.

---

## Verdict: **RED**

| Criterion | Assessment |
|-----------|------------|
| All 7 live recommendable keys listed with hashes | **Pass** (documented above) |
| No orphan tier-2-only rows without explanation | **Fail** — 2 legacy 7B rows unexplained relative to live autotune |
| No SHA mismatch on live models present in both catalogs | **Fail** — `Llama-3.2-3B-Instruct-4bit` SHA mismatch |
| Gemma-4 split-brain | **Pass** — not present in tier-2 |

**Action before new catalog publishes (per runbook G2):** Re-sign and deploy an updated `tier2-catalog.json` aligned to the live autotune manifest hashes (all 7 recommendable `model_id` + SHA-256 + `min_ram_gb`), retire or explicitly document legacy 7B tier-2 rows, and re-run P0-02 for GREEN.
