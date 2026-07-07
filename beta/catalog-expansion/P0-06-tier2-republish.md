# P0-06 — Tier-2 catalog republish

**Task:** P0-06 (Model Catalog Expansion Runbook)  
**Trigger:** P0-02 RED (`beta/catalog-expansion/P0-02-tier2-catalog-snapshot.md`)  
**Executor timestamp (UTC):** 2026-07-07T06:12:04Z  
**Verdict:** **GREEN**

---

## New catalog

| Field | Value |
|-------|-------|
| **catalog_id** | `macprovider-tier2-model-catalog-2026-07-07` |
| **issued_at** | `2026-07-07T00:00:00Z` |
| **expires_at** | `2026-10-07T00:00:00Z` |
| **model count** | 7 |
| **signature key_id** | `catalog-key-2026q2` |
| **signature alg** | Ed25519 (sig redacted) |

### Model entries (sorted by `model_id`)

| model_id | sha256 | min_ram_gb |
|----------|--------|------------|
| `mlx-community/gpt-oss-20b-MXFP4-Q8` | `f25592861e0b7f4eb8489d9103214f3f0dc4f798bb0e4e0cd817ff2f4191f1b1` | 24 |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | `3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a` | 4 |
| `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | `67b26d6b1c50dc8836ab3705b06276a43c74c8f66247f9b112e232b58abbd99f` | 12 |
| `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | `1bc78f214f9a042eaeb290b1fa4cb29915df1028f79d8479266349166c40a71f` | 32 |
| `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | `b7749cc57f37f7e9239d0f9b091bcffe6d7629e48af75e8cb84c1cdca1780973` | 48 |
| `mlx-community/Qwen3-32B-4bit` | `69169cceb643f108755f96dba26d8647862e38a7f82cb1b5b25aff8f204967aa` | 48 |
| `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | `10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0` | 28 |

All entries use `artifact_kind=mlx_weight_file`, `hash_scope=artifact_manifest`, `source=operator-curated`.

Hashes and `min_ram_gb` values sourced from live autotune feed `published-2026-07-06-mbase-lite` at build time.

---

## Build and sign

| Step | Result |
|------|--------|
| Unsigned artifact | `.omc/tier2/tier2-catalog-2026-07-07.unsigned.json` (out-of-repo) |
| Signed artifact | `.omc/tier2/tier2-catalog-2026-07-07.signed.json` (out-of-repo) |
| Local verify (repo pubkey) | **PASS** — `model_count=7 key_id=catalog-key-2026q2` |
| Local verify (prod pubkey fingerprint) | **PASS** — matches `coordinator.yaml:203` (`IVH2aAlT…0U9aFQ`) |

Private signing key used from `.omc/tier2/catalog-signing-key.priv` (not reproduced).

---

## Deploy

| Field | Value |
|-------|-------|
| **Method** | Option B — catalog-only SCP + install (minimal blast radius) |
| **Deploy timestamp (UTC)** | `2026-07-07T06:12:04Z` |
| **Target host** | Pearl VPS `159.223.165.194` (`ubuntu-s-2vcpu-4gb-120gb-intel-nyc1`) |
| **Destination** | `/opt/macprovider/tier2-catalog.json` (root:macprovider, mode 0640) |
| **Backup** | `/opt/macprovider/tier2-catalog.json.bak-p0-06-<timestamp>` |
| **Reload** | `systemctl kill -s HUP macprovider-coordinator` |
| **Journal evidence** | `tier2 config reloaded` at `2026-07-07T06:12:09Z` |

Full `deploy-pearl-vps.sh` not run — only catalog file replaced.

---

## Post-deploy verification

```json
{
  "catalog_id": "macprovider-tier2-model-catalog-2026-07-07",
  "issued_at": "2026-07-07T00:00:00Z",
  "expires_at": "2026-10-07T00:00:00Z",
  "model_count": 7,
  "key_id": "catalog-key-2026q2"
}
```

`GET https://coordinator.streamvc.live/catalog/current` — HTTP 200, 7 models, all SHA-256 and `min_ram_gb` match live autotune table.

Previous catalog `macprovider-tier2-model-catalog-2026-05-31` (3 models) no longer served.

---

## Operator decisions

| Decision | Outcome |
|----------|---------|
| Legacy tier-2-only `Qwen2.5-7B-Instruct-4bit` | **Removed** — not in live autotune recommendable feed |
| Legacy tier-2-only `Qwen2.5-Coder-7B-Instruct-4bit` | **Removed** — not in live autotune recommendable feed |
| Gemma-4 rows | **Not added** — P1 scope per runbook |
| Llama-3.2-3B hash | **Fixed** — autotune `3975387f…7216a` replaces old tier-2 `0baf1371…fe2fe`; `min_ram_gb` 4 (was 8) |

---

## P0-02 re-run

**Verdict:** **GREEN**

Full re-run artifact: `beta/catalog-expansion/P0-02-tier2-catalog-snapshot-rerun.md`

| Check | Result |
|-------|--------|
| 7/7 autotune recommendable models in tier-2 | **Pass** |
| SHA-256 match on all shared models | **Pass** (including Llama-3.2-3B) |
| No orphan tier-2-only rows | **Pass** |
| No orphan autotune-only rows | **Pass** |

---

## Pass / fail

| Criterion | Assessment |
|-----------|------------|
| Sign + verify OK | **Pass** |
| Deploy OK + `/catalog/current` serves new catalog | **Pass** |
| P0-02 re-run GREEN | **Pass** |

**P0-06: GREEN** — G2 tier-2 republish block cleared for pinned session.
