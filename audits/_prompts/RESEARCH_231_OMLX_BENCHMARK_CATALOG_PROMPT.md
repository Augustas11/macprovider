# RESEARCH PROMPT — oMLX community benchmarks → model catalog calibration

Run as: `omc ask codex "$(cat audits/_prompts/RESEARCH_231_OMLX_BENCHMARK_CATALOG_PROMPT.md)"`

This is a **technical research prompt**, not a code-audit prompt. Single
codex call (or twice with different models). Output is a decision-grade
memo, not a diff.

**Explicit non-goal:** replace macprovider's mlx-swift-lm runtime with
oMLX. oMLX is a **reference dataset and calibration source** for catalog
and autotune gate decisions only.

**Pair-tracks:**
- [RESEARCH_226_MOE_SELECTION_AND_MARKET_DEMAND_MEMO.md] — MoE TPS +
  demand ranking (local benches)
- [RESEARCH_227_RATE_CARD_V3_MEMO.md] — rate-card rows and demand weights
- [PLAN_MODEL_CATALOG_EXPANSION_RUNBOOK.md] — catalog publish gates
- [SPEC-010-model-catalog.md] — normative catalog contract
- `phase3-binary/dist/static/autotune-candidates.json` — signed static feed

---

## Task

[oMLX community benchmarks](https://omlx.ai/benchmarks) publishes
325k+ real-world rows: Apple Silicon chip variant, RAM, model name,
quantization, context length, prefill tok/s (PP), generation tok/s
(TG), and date. Submissions come from oMLX app v0.2.6+ (dashboard bench
tab); the engine is **mlx-lm Python**, not macprovider's mlx-swift-lm.

Produce a **catalog calibration memo** that answers:

1. Which **(chip, RAM, model, quant, context)** cells in the oMLX dataset
   are statistically reliable enough to inform macprovider catalog rows?
2. For each catalog candidate (existing + proposed), what is the
   **best-fit hardware tier** and realistic `bench_gate` envelope?
3. What **catalog deltas** (new rows, `min_ram_gb` changes,
   `min_sustained_tps` / `max_4k_ttft_ms` adjustments,
   `min_bandwidth_tier` changes, `runtime_status` demotions) should
   operators consider — with confidence labels?

The memo must be actionable for the next catalog publish PR without
requiring oMLX runtime adoption.

---

## Background — macprovider catalog surfaces today

### Signed autotune candidate catalog

File: `phase3-binary/dist/static/autotune-candidates.json`

Per-row fields (coordinator parser: `phase4-coordinator/internal/autotune/catalog.go`):

| Field | Role |
|---|---|
| `model_id` | HuggingFace / mlx-community artifact ID |
| `model_revision` + `model_sha256` | Provenance pin for hardware-evidence |
| `min_ram_gb` | §5 RAM gate (`memoryGB - 4` headroom in CLI) |
| `min_bandwidth_tier` | A/B/C routing signal |
| `bench_gate.min_sustained_tps` | Stage 1 generation-only TPS floor |
| `bench_gate.max_4k_ttft_ms` | Stage 1 p95 TTFT ceiling at 4K context |
| `runtime_status` | `recommendable` / blocked states |

Current rows (2026-07-07 publish): Qwen3-Coder-30B-A3B, gpt-oss-20b,
Llama 3.1/3.2 8B/3B, Qwen3-32B, Qwen2.5-Coder-32B, Nemotron-3-Nano-30B,
gemma-4-26b-a4b-it, Qwen3-8B.

### Local bench harnesses (ground truth for macprovider runtime)

| Harness | Metrics | Semantics |
|---|---|---|
| `macprovider-cli decode-bench` | PP + TG | Generation-only TPS excludes TTFT |
| `macprovider-cli autotune` Stage 1 | TG + p95 TTFT | Subprocess `serve --no-join` HTTP probe |
| `macprovider-cli autotune` Stage 2 | knob grid | `kv_bits`, `max_batch`, `max_context` |
| Coordinator hardware-evidence | attested TG/TTFT | POST `/v1/providers/hardware-evidence` |

### oMLX benchmark board schema (observed 2026-07-09)

Columns: `#`, `Chip`, `RAM`, `Model`, `Quant`, `Ctx`, `PP tok/s`,
`TG tok/s`, `Date`.

Filters: chip family (M1–M5), variant (e.g. M1 Pro 16c, M2 Ultra 76c),
quant (2/3/4/6/8 bit), context (1k–64k).

Example rows relevant to catalog:

| Chip | RAM | Model | Quant | Ctx | PP | TG |
|---|---:|---|---|---:|---:|
| M1 Pro 16c | 32 GB | Qwen3.6-27B | 4bit | 4k | 45.1 | 10.6 |
| M1 Max 24c | 64 GB | Qwen3.6-35B-A3B | 4bit | 4k | 38.8 | 2.5 |
| M2 Ultra 76c | 192 GB | copywriter-gemma4-31b-oQ6 | 6bit | 4k | 280.6 | 19.5 |
| M5 10c | 24 GB | Qwythos-9B-... | 4bit | 32k | 147.5 | 8.2 |

**Caveat:** oMLX runs mlx-lm; macprovider runs mlx-swift-lm 3.31.4.
Expect directional agreement, not byte-identical TPS. Document expected
delta bands per model class before using oMLX TG as a hard gate.

---

## What to produce

### Part 1 — oMLX dataset ingestion methodology

Design a **repeatable extraction procedure** (no production code required
in this memo; pseudocode/scripts in memo appendix are fine):

1. **Scrape/API strategy** — determine whether omlx.ai exposes a public
   JSON/API beyond the HTML table (check network tab, GitHub issues,
   sitemap). If no API, document HTML pagination strategy and rate
   limits. Flag ToS considerations.
2. **Normalization table** — map oMLX `Model` strings → macprovider
   `model_id` / catalog keys. Handle aliases:
   - `Qwen3.6-27B` ↔ `mlx-community/Qwen3-*`
   - `gemma4-31b` ↔ `mlx-community/gemma-4-*`
   - community fine-tunes (e.g. `Qwythos-9B`) → `runtime_status: experimental`
3. **Chip normalization** — map oMLX chip strings → macprovider hardware
   summary (`HardwareSummary.chip`, bandwidth tier A/B/C). Document
   ambiguous cases (GPU core count variants within same SKU).
4. **Outlier rejection** — propose filters: min sample count per cell,
   IQR/MAD trimming, date freshness window, exclude known-bad quants.
5. **Engine delta factor** — recommend a default discount/uncertainty
   band when translating oMLX TG → macprovider `min_sustained_tps`
   (e.g. 0.85× for same mlx-community artifact, wider for name-only
   matches).

### Part 2 — Per-model hardware fit matrix

For **each catalog row** in `autotune-candidates.json` plus **top 20
oMLX models by submission count** that are not yet in catalog:

Build a matrix:

| Catalog key | mlx-community model_id | oMLX model aliases | Best chip (p50 TG) | Min RAM (fit) | TG p25/p50/p75 @ 4k | PP p50 @ 4k | macprovider gate today | Recommended gate | Confidence |
|---|---|---|---|---:|---|---|---|---|---|

Use **4k context** as primary column (matches `max_4k_ttft_ms` gate).
Add 1k and 32k columns where sample size ≥ 10.

Derive **hardware tier recommendations**:

| Tier | Bandwidth | Typical chips | Catalog routing intent |
|---|---|---|---|
| A | ≥ 400 GB/s | M-Max, M-Ultra | 32B dense, flagship MoE |
| B | 200–399 GB/s | M-Pro 48GB+ | 32B marginal / large MoE |
| C | < 200 GB/s | M-base, M-Pro 16–24GB | ≤ 8B / small MoE |

For each model, state: **minimum RAM to serve at 4k** (from oMLX peak
memory if available; else infer from model size + quant), and **chips
that should NOT be recommended** (TG < gate or PP implying TTFT blowout).

### Part 3 — Catalog delta proposals

Produce a ranked list of **actionable catalog changes** (max 15 items):

| Priority | Change type | Target row | Current | Proposed | Evidence | Risk |
|---|---|---|---|---|---|---|
| P0 | `min_sustained_tps` adjust | ... | ... | ... | oMLX p25 + local bench | false reject |
| P1 | new row | ... | — | ... | demand + oMLX fit | artifact pin work |
| P2 | `min_ram_gb` lower/raise | ... | ... | ... | oMLX RAM column | OOM |
| P3 | demote `runtime_status` | ... | recommendable → blocked | ... | TG consistently < gate | buyer QoS |

Each proposal must cite:
- oMLX sample count and date range
- Closest macprovider local bench if exists (`beta/catalog-expansion/*`,
  `audits/*/bench-snapshots/`, `state/perf/`)
- RESEARCH_227 demand rank if applicable

**Hard rules for proposals:**
- Never propose a row without a plausible `mlx-community/*` artifact path
- Never lower `model_sha256` requirements
- Treat oMLX-only evidence as **advisory** until macprovider
  `decode-bench` or autotune reproduces within agreed delta band
- Flag models appearing in oMLX but **absent from mlx-community** as
  `research_only`

### Part 4 — Autotune gate calibration

For each existing `bench_gate`:

1. Compare `min_sustained_tps` to oMLX TG distribution for matching
   hardware that can run the model.
2. Compare `max_4k_ttft_ms` to implied TTFT from PP (@ 4096 tokens):
   `ttft_est_ms ≈ 4096 / PP * 1000` (document uncertainty).
3. Recommend **gate slack policy**: e.g. set `min_sustained_tps` at
   p25 × engine_delta, not p50, to avoid false rejects on M-base.
4. Identify gates that are **too loose** (oMLX p10 still above gate —
   providers admit underperforming hardware).

Cross-reference SPEC-023 §5: gates are advisory QoS, not hard blocks —
but they feed hardware-evidence and OPoI drift. Note implications.

### Part 5 — Monitoring and refresh loop

Propose an **operator refresh cadence** (no implementation):

| Artifact | Source | Cadence | Owner |
|---|---|---|---|
| `omlx-benchmark-snapshot-YYYY-MM.json` | omlx.ai scrape | monthly | operator |
| `catalog-calibration-memo-YYYY-MM.md` | this research rerun | quarterly | operator |
| `autotune-candidates.json` delta | memo Part 3 P0/P1 | after memo + local repro | PR |

Add oMLX to `beta/throughput-engineering/UPSTREAM_WATCH.json` watchlist
(recommended fields: latest release tag, benchmark page schema version).

List **5–10 falsification benches** to run on macprovider hardware
after applying catalog deltas (model, chip, expected TG band).

---

## Out of scope

- oMLX runtime integration or sidecar deployment (see RESEARCH_232/233)
- Rate-card dollar changes (cite RESEARCH_227; flag if catalog shift
  implies rate-card follow-up)
- Coordinator code changes (memo-only)
- Inspecting d-inference / Layr-Labs source (clean-room)
- Normative SPEC edits (memo feeds a future catalog PR)

---

## Output format

Markdown memo `docs/research/RESEARCH_231_OMLX_BENCHMARK_CATALOG_MEMO.md`,
**~400–800 lines**.

Required sections: Parts 1–5 above + **Executive summary** (≤ 15 bullets)
+ **Appendix A** model-name normalization table + **Appendix B** scrape
notes.

Tables over prose where possible. Every numeric recommendation carries
**confidence: high / medium / low** and **evidence type: oMLX /
local-bench / both / extrapolated**.

Conservative > optimistic — this memo feeds signed catalog publishes and
hardware-evidence gates.
