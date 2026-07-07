# P2-03 — Baked/live drift cleanup

**Task:** Model Catalog Expansion Runbook v0.1.10 — P2-03 ONLY  
**Date:** 2026-07-07  
**Branch:** `fix/p2-03-baked-live-drift` (worktree `../macprovider-p2-03`)  
**Live catalog version:** `published-2026-07-07-p1-gemma`

> **NOT DEPLOYED** — repo-only offline-fallback fix. No static feed re-sign, no coordinator deploy, no tier-2 publish.

---

## Summary

| Surface | Before | After | Action |
|---------|--------|-------|--------|
| `bakedCandidateCatalogJSON` | byte-aligned with `dist/static/autotune-candidates.json` | unchanged | PASS — no edit |
| `bakedDemandRankJSON` | byte-aligned with `dist/static/demand-rank.json` | unchanged | PASS — no edit |
| `bakedRateCardJSON` | `baked-2026-07-03`; Nemotron stale at 235k completion | `baked-2026-07-07-p2-drift`; Nemotron 160k completion | **FIXED** |

---

## Drift table

| Field | Live (coordinator.yaml / static) | Baked-before | Baked-after |
|-------|----------------------------------|--------------|-------------|
| `bakedRateCardJSON.version` | n/a (live uses SHA256 hash at `/v1/rate-card`) | `baked-2026-07-03` | `baked-2026-07-07-p2-drift` |
| `bakedRateCardJSON.generated_at` | n/a | `2026-07-03T00:00:00Z` | `2026-07-07T10:47:00Z` |
| `nemotron-3-nano-30b-a3b.prompt_rate_per_mtok` | 80,000 | 117,500 | **80,000** |
| `nemotron-3-nano-30b-a3b.completion_rate_per_mtok` | 160,000 | 235,000 | **160,000** |
| `google-gemma-4-26b-a4b-it` completion | 240,000 | 240,000 | 240,000 (verify PASS) |
| `gemma-4-26b-a4b-it` completion | 240,000 | 240,000 | 240,000 (verify PASS) |
| `qwen3-coder-30b-a3b-instruct` completion | 235,000 | 235,000 | 235,000 (verify PASS) |
| `openai/gpt-oss-20b` completion | 100,000 | 100,000 | 100,000 (verify PASS) |
| `qwen3-32b` completion | 220,000 | 220,000 | 220,000 (verify PASS) |
| `qwen2.5-coder-32b-instruct` completion | 850,000 | 850,000 | 850,000 (verify PASS) |
| `meta-llama/*` completion | 27,000 | 27,000 | 27,000 (verify PASS) |
| `bakedCandidateCatalogJSON` bytes | `dist/static/autotune-candidates.json` | identical | identical (PASS) |
| `bakedDemandRankJSON` bytes | `dist/static/demand-rank.json` | identical | identical (PASS) |
| `qwen3-32b.min_ram_gb` (historical 32 vs 48 note) | 48 | 48 | 48 (PASS — no drift) |

---

## Candidate catalog SHA256

| Source | SHA256 |
|--------|--------|
| Live `phase3-binary/dist/static/autotune-candidates.json` | `7f9338daf42a5dceba75e9061f8502d615c6fbc36f055108148152a712d52ee4` |
| Baked-after `bakedCandidateCatalogJSON` | `7f9338daf42a5dceba75e9061f8502d615c6fbc36f055108148152a712d52ee4` |

Byte-for-byte match — no static re-sign required.

Demand rank SHA256 (live = baked-after): `69aff620b034bf8392e5c8492065e9766c4ff32286e9a1772a3e81eaf0cf9fdb`

---

## Rate-card row diff summary

Only **Nemotron** drifted between baked fallback and `phase4-coordinator/dist/coordinator.yaml`:

| Key | Field | Baked-before | Live / baked-after |
|-----|-------|--------------|-------------------|
| `nemotron-3-nano-30b-a3b` | `prompt_rate_per_mtok` | 117,500 | **80,000** |
| `nemotron-3-nano-30b-a3b` | `completion_rate_per_mtok` | 235,000 | **160,000** ($0.160/M) |

All other recommendable-model rows already matched coordinator projection (including P1 Gemma alias rows).

---

## Files changed

| File | Change |
|------|--------|
| `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` | Updated `bakedRateCardJSON` version, `generated_at`, Nemotron credits |
| `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift` | Nemotron baked-rate assertions; freshness mock rate-card version |
| `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendSimulateTests.swift` | Expected baked rate-card version string |

**Not touched:** `phase3-binary/dist/static/*`, `coordinator.yaml`, tier-2 catalog, `ServeCommandTests` (candidate `generated_at` unchanged).

---

## Test results

```text
cd phase3-binary
swift test --filter AutotuneRecommend
# Executed 95 tests, with 0 failures

swift test --filter 'ServeCommandTests/testCoordinatorJoinAcceptsCatalogBound|ServeCommandTests/testDonorModeAcceptsCatalogBound'
# Executed 2 tests, with 0 failures
```

---

## Blockers for P2-02

None.

---

## P2-03 VERDICT: PASS

**Drift items fixed:** Nemotron baked rate-card prompt/completion credits (117.5k/235k → 80k/160k); rate-card version bump `baked-2026-07-03` → `baked-2026-07-07-p2-drift`.

**Tests:** AutotuneRecommend 95/95 pass; ServeCommandTests catalog-bound 2/2 pass.

**Artifact:** `beta/catalog-expansion/P2-baked-live-drift.md`

**Blockers for P2-02:** none
