# P3-R231 — RESEARCH_231 gate calibration (executor scope lock)

**Task:** P3-R231-00 + P3-R231-01  
**Date:** 2026-07-09  
**Verdict:** **PASS** — scope locked; **no catalog PR** from this executor

---

## Executor hardware (locked)

| Field | Value |
|-------|-------|
| **Machine** | MacBook Air (Mac17,3) |
| **Chip** | Apple M5 (10 cores) — **Tier-C** |
| **RAM** | **32 GB** |
| **Higher RAM tiers** | **Not available** |

This is the **only** catalog bench executor. It validated P0-01, P1-01, P2-02 only.

---

## Bench eligibility rules (hard)

Do **not** run `serve` / `autotune` / `decode-bench` on this Mac when any rule fails:

1. **E1:** resident weights + KV@4k + 4 GB headroom **> 28 GB**
2. **E2:** target catalog `min_bandwidth_tier` **> C**
3. **E3:** MLX pin is VLM / `vision_config` present without verified text-only path
4. **E4:** new row targeting Tier-B+ economics

**No load probes** on failing models. oMLX is advisory only.

---

## RESEARCH_231 Part 3 — disposition

| Priority | Change | Executor? | Required HW | Status |
|----------|--------|-----------|-------------|--------|
| P0 | nemotron `min_sustained_tps` 30→20 | **No** | M5 32 GB possible but **not attempted** — oMLX-only | **DEFERRED** |
| P0 | qwen3-32b TPS 15→10 | **No** | M4 Pro 48 GB (FB-02) | **BLOCKED** |
| P1 | **new row** `qwen3.6-35b-a3b` | **No** | M4 Max 48 GB+; text-only MLX pin | **BLOCKED** |
| P1 | qwen2.5-coder TPS 20→15 | **No** | M4 Max 64 GB (FB-03) | **BLOCKED** |
| P2 | llama-3.2-3b TPS 15→8 | **No** | conflicts Entry 116 | **DEFERRED** |
| P3 | hold gpt-oss / gemma-4 / qwen3-8b | **N/A** | already benched P1-01 / P2-02 | **KEEP** |

---

## Why `qwen3.6-35b-a3b` is blocked (summary)

| Check | Result |
|-------|--------|
| HF weights | ~**20.4 GB** (`mlx-community/Qwen3.6-35B-A3B-4bit`) |
| E1 (28 GB envelope) | **FAIL** |
| Default MLX pin | VLM (`vision_config`, `Qwen3_5MoeForConditionalGeneration`) — **E3 FAIL** |
| Proposed gate tier | **B** (TPS 18) — **E2 FAIL** on M5 32 GB |

Do not bootstrap this model on the executor.

---

## Off-executor queue (P3-R231-02)

When **M4 Pro 48 GB+** or **M4 Max 64 GB+** is available:

| FB ID | Model | Machine class |
|-------|-------|---------------|
| FB-02 | Qwen3-32B-4bit | M4 Pro 48 GB |
| FB-03 | Qwen2.5-Coder-32B | M4 Max 64 GB |
| FB-04 | Qwen3.6-35B-A3B (text-only pin TBD) | M4 Max 48 GB+ |

Use P1-01 clean-machine protocol on the **target tier only**.

---

## Catalog PR policy (G6)

- **No** `autotune-candidates.json` changes from oMLX-only RESEARCH_231 P0/P1 items until local bench on eligible hardware.
- RESEARCH_231 remains the **advisory input** for off-executor scheduling.

**Runbook:** `specs/PLAN_MODEL_CATALOG_EXPANSION_RUNBOOK.md` v0.1.13 § P3-R231.
