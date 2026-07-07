# P0 rollup — Model catalog expansion verification

**Date:** 2026-07-07  
**Plan:** `specs/PLAN_MODEL_CATALOG_EXPANSION_RUNBOOK.md`  
**Gate:** **G0 PROCEED**

---

## Task verdicts

| Task ID | Verdict | Artifact |
|---------|---------|----------|
| P0-01 | **GREEN** | `P0-01-moe-memory-parity.md` |
| P0-02 | **GREEN** (after P0-06) | `P0-02-tier2-catalog-snapshot-rerun.md` (initial: RED) |
| P0-03 | **GREEN** | `P0-03-hf-weights-audit.md` |
| P0-04 | **GREEN** | `P0-04-gemma4-template-probe.md` |
| P0-05 | **GREEN** | `P0-05-nemotron-model-type.md` |
| P0-06 | **GREEN** | `P0-06-tier2-republish.md` |

No WAIVED tasks.

---

## Key findings (actionable for P1)

| Topic | Finding |
|-------|---------|
| **Gemma-4 memory** | ~15 GB resident on 32 GB M5; recommend `min_ram_gb: 28` |
| **Gemma-4 TPS (P0-01)** | ~7.7 tok/s — **low confidence**; do not use for catalog gates; re-bench in P1-01 |
| **P1-01 prerequisite** | gpt-oss sanity on clean 32 GB Mac (target ≥12 tok/s median vs catalog 15 gate) |
| **Gemma-4 template** | `/v1/chat/completions` clean; no `extraEOSTokens` fix needed |
| **Tier-2** | Prod `macprovider-tier2-model-catalog-2026-07-07` — 7/7 autotune aligned |
| **Flagship weights** | gpt-oss-120b, gemma-4-31b, qwen3-next-80b MLX repos confirmed (P4) |
| **Nemotron** | `model_type=nemotron_h`; registry OK |
| **ModelFit** | Unreliable for MoE — keep operator-curated `min_ram_gb` |

---

## G0 recommendation

**PROCEED** to Phase P1 (Gemma-4 unblock).

**G2 partial:** tier-2 hash layer cleared; full publish still needs P1-01 + P1-02 rate card.

---

## Next tasks (priority order)

1. **P1-01** — Clean-machine bench + **gpt-oss sanity check** → then Gemma median TPS gates (supersedes P0-01 ~7.7)
2. **P1-02** — Rate card row for `google-gemma-4-26b-a4b-it`
3. **P1-03** — Catalog + tier-2 + autotune publish (add 8th model)
