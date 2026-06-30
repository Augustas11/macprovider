# RESEARCH PROMPT — MoE model selection on Apple Silicon + OpenRouter market demand

Run as: `omc ask codex "$(cat specs/RESEARCH_226_MOE_SELECTION_AND_MARKET_DEMAND_PROMPT.md)"`

This is a narrow follow-up to:
- RESEARCH_223 (MLX throughput roadmap) — concluded Roadmap D Hybrid
- RESEARCH_224 (pricing v2) — concluded per-model rate-card rows
- RESEARCH_225 (darkbloom.dev comparison) — revealed darkbloom serves
  MoE-with-small-active-params (GPT-OSS 20B / 3.6B active, Gemma 4 26B
  / 3.8B active) at $0.07-$0.165/M output, sidestepping the dense
  bandwidth-bound problem entirely

The MoE-active-parameter angle was barely covered in 223. This prompt
closes that gap **and** layers in real market demand so we know which
MoE models actually have buyer demand.

Output: a decision-grade memo that produces (a) a per-MoE-model TPS
matrix on Apple Silicon, (b) a market-demand-ranked list of MoE
models with current per-token pricing, (c) a concrete delta to
Track B's `rewards.rate_card` if we add MoE-class rows.

---

## Task

Two interleaved questions:

**Engineering question**: For the MoE models that are realistically
servable on Apple Silicon today, what's the **per-hardware-tier
sustained tok/s**? Specifically what happens when bandwidth math is
over **active** params not nominal params?

**Market question**: What MoE models do **buyers actually pay for**
on OpenRouter (and comparable aggregators)? What's the volume, the
price, and the implied buyer-demand ranking? An efficient-to-serve
model with no demand is worthless; a high-demand model we can't serve
efficiently is also worthless.

The intersection of "we can serve it efficiently on Apple Silicon"
AND "buyers will pay for it" is the candidate MoE-class rate-card
rows for macprovider.

---

## Background

**Darkbloom live catalog** (from RESEARCH_225, 2026-06-30):
| Model | Nominal | Active | Min RAM | Their output $/M |
|---|---|---|---|---:|
| `gpt-oss-20b` | 20.9B MoE | 3.6B | 24 GB | $0.070 |
| `gemma-4-26b` | 25.2B MoE | 3.8B | 36 GB | $0.165 |
| `gemma-4-26b-qat-4bit` | 25.2B MoE | 3.8B | 32 GB | $0.165 |

**Darkbloom claimed throughput**: MiniMax M2.5 ~100 tok/s on Apple
Silicon (per docs, not in live catalog — treat as marketing).

**Hardware fleet to evaluate** (same as 223 matrix):
- M4 Air 16GB / 24GB / 32GB
- M4 Pro 24GB / 48GB
- M4 Max 64GB / 128GB
- M2 Ultra 128GB / 192GB
- M3 Ultra 256GB

**Tier framing from 224** (memory bandwidth proxy):
- Tier-S: ≥700 GB/s (M-Ultra)
- Tier-A: ≥350 GB/s (M-Max)
- Tier-B: ≥150 GB/s (M-Pro)
- Tier-C: <150 GB/s (M-Air / base M-series)

---

## What to produce

### Part 1 — MoE model catalog: what's actually servable on Apple Silicon today

For each of these candidates (and any others that surface in research),
report **nominal params, active params, native quantizations available
in MLX / GGUF / mlx-swift, weight-on-disk GB at each quantization,
runtime memory footprint at 4K context, min RAM tier servable**:

- **GPT-OSS 20B** (OpenAI open-weights, 20.9B / 3.6B active) — already
  on darkbloom
- **Gemma 4 26B / 27B family** (Google, 25.2B / 3.8B active) — already
  on darkbloom; check for variants
- **Qwen3-MoE** family (Alibaba) — verify which Qwen3-MoE checkpoints
  exist (235B-A22B? 30B-A3B? others?), MLX support, GGUF support
- **MiniMax M2** / M2.5 / Text-01 (MiniMax, ~456B MoE / ~46B active —
  verify; this may be too large for M-Ultra)
- **DeepSeek-V2** / V2-Lite / V3 distills — DeepSeek-V3 nominal is
  671B / 37B active (too large), but distillations / smaller MoE
  variants may fit
- **DBRX** (Databricks, 132B / 36B active) — likely Ultra-only
- **Mixtral 8x7B** (Mistral, 47B / ~13B active) — older but well-known
- **Mixtral 8x22B** (Mistral, 141B / ~39B active) — Ultra-tier
- **Phi-3.5-MoE** (Microsoft, 41.9B / 6.6B active)
- **Yi-1.5-MoE** if any extant
- Any newer MoE released in 2026 worth flagging

For each: cite HuggingFace URL + MLX repo URL if it exists +
GGUF availability + license + known issues / production-readiness on
Apple Silicon.

Build:

| Model | Nominal | Active | Native MLX | GGUF | 4bit GB | 8bit GB | Min RAM 4K ctx | Smallest tier servable |
|---|---|---|:-:|:-:|---:|---:|---:|---|

### Part 2 — Per-active-param TPS matrix on Apple Silicon

For each (servable MoE model × hardware tier × quantization)
combination, report **realistic sustained single-stream tok/s** and
expected concurrent-batching ceiling under best-in-tree software stack
(mlx-swift / mlx-lm / llama.cpp `--parallel` — pick the best per cell).

Use the bandwidth-bound math over **active** params, not nominal, as
the upper bound. Cite published benchmarks (blogs, tweets, GitHub
issues, lmstudio.ai testimonials) where they exist; flag everything
else as extrapolation.

| Model | Active GB | M4 Air S/C | M4 Pro S/C | M4 Max S/C | M2 Ultra S/C | M3 Ultra S/C |
|---|---:|---:|---:|---:|---:|---:|
| GPT-OSS 20B (3.6B-act, 4bit) | ~1.8 | | | | | |
| Gemma 4 26B (3.8B-act, 4bit) | ~1.9 | | | | | |
| Qwen3-MoE-30B-A3B (3B-act, 4bit) | ~1.5 | | | | | |
| Qwen3-MoE-235B-A22B (22B-act, 4bit) | ~11 | (oom) | (oom) | (oom) | | |
| Mixtral 8x7B (13B-act, 4bit) | ~6.5 | (oom) | | | | |
| Phi-3.5-MoE (6.6B-act, 4bit) | ~3.3 | | | | | |
| DBRX (36B-act, 4bit) | ~18 | (oom) | (oom) | (oom) | | |

For comparison context, copy the dense reference rows from RESEARCH_223:
- M4 Air × Qwen3-32B (dense, 4bit): 14 tok/s observed, 8-16 12mo target
- M4 Max × Qwen3-32B (dense, 4bit): 25-75 tok/s
- M2/M3 Ultra × Qwen3-32B (dense, 4bit): 42-140 tok/s

**Critical**: explicitly call out which MoE cells **beat** the
dense-32B cells on the same hardware. That's where the active-param
math actually pays.

### Part 3 — OpenRouter market demand

This is the data we've been missing. Pull from OpenRouter's analytics
surfaces:

- `https://openrouter.ai/rankings` — top models by usage volume
- `https://openrouter.ai/api/v1/models` — full model list with pricing
- `https://openrouter.ai/api/frontend/stats/app` — if accessible
- Individual model pages with token-volume sparklines (e.g.,
  `https://openrouter.ai/qwen/qwen3-32b`)
- Their `/api/v1/models/<model>/stats` endpoint if it exists
- Third-party aggregators tracking OpenRouter trends

For the **top 30 models by completion-token volume on OpenRouter**
(or whatever proxy is publicly visible — sometimes it's by request
count, sometimes by spend), report:

| Rank | Model | Class (dense/MoE/active) | Provider tier | $/M completion | Trend | Source |
|---:|---|---|---|---:|---|---|

Classify each as:
- **Dense-small** (≤8B)
- **Dense-mid** (>8B, ≤32B)
- **Dense-large** (>32B)
- **MoE-small-active** (active ≤8B)
- **MoE-mid-active** (active 8-32B)
- **MoE-large-active** (active >32B)

Then aggregate: what **share of OpenRouter volume** sits in each class?
Especially: what share of volume is in models macprovider can
realistically serve on Apple Silicon (MoE-small-active + dense-small +
dense-mid)?

If OpenRouter doesn't publish volume directly, fall back to: (a)
ranking by "trending" pages, (b) anecdotal app-developer mentions,
(c) Together / DeepInfra / Fireworks revenue lists if findable.

### Part 4 — Intersection: high-demand AND Apple-Silicon-efficient

Build the decision table:

| Model | Class | OpenRouter rank | Cheapest market $/M | Apple-Silicon-servable tier | Per-stream TPS @ Tier-A | Demand × Efficiency = candidate? |
|---|---|---:|---:|---|---:|:-:|

Mark each row:
- ✅ **Add to macprovider rate-card** (high demand, efficient on AS)
- ⚠️ **Add but low expected volume** (efficient but niche demand)
- ❌ **Skip** (high demand but inefficient on AS, OR efficient but no
  market)

### Part 5 — Track B rate-card delta

For the rows marked ✅ in Part 4, produce a **concrete addition** to
Track B's `rewards.rate_card`. Maintain Track B's "undercut cheapest
market by 10-30%" rule. Build:

```yaml
rewards:
  rate_card:
    # Track B existing rows (don't touch):
    llama-3.1-8b:        # $0.027/M
    qwen3-32b:           # $0.220/M
    llama-3.3-70b:       # $0.250/M

    # New MoE rows from this memo:
    gpt-oss-20b:
      prompt_credits_per_mtok: __
      completion_credits_per_mtok: __    # target $/M completion
    qwen3-moe-30b-a3b:
      ...
```

For each new row:
- Cite the cheapest market price (URL + date)
- State the undercut %
- Compute provider $/hr at the cell's per-stream TPS (Tier-A and
  Tier-S separately) — does USD margin clear electricity?
- Recommend any tier-eligibility delta (e.g., GPT-OSS 20B servable
  on Tier-C with 24GB RAM, so allow Tier-C providers to serve it
  even though Track B's tier filter would route 32B-dense away from
  them)

### Part 6 — Strategic recommendation

One paragraph each:

**Should macprovider add MoE-class rate-card rows at v2 launch, or
stay dense-only for differentiation?** Decide. If yes, name the 2-4
models worth listing initially. If no, explain why differentiation
beats parity here.

**Does the MoE finding change Track A's engineering roadmap?** If
Apple-Silicon-efficient MoE serving is real, does the engineering
priority shift from "llama.cpp `--parallel` for dense" to "MoE-aware
runtime + draft-model selection per active-param size"? Be specific
about what changes.

**Does it change Track B's tier filter?** Should min-RAM (per-model)
override memory-bandwidth-tier when the active params are small enough?
E.g., should a Tier-C M4 Air be allowed to take GPT-OSS 20B traffic
because it's actually serving 3.6B active?

### Part 7 — Open follow-up benchmarks

3-5 concrete bench scenarios to validate the MoE matrix on real
hardware. Same format as RESEARCH_223 Part 6 (SCN-226-NN).

---

## Out of scope

- Inspecting `Layr-Labs/d-inference` source code (clean-room rule)
- Reproducing darkbloom's exact pricing structure
- Custom MoE training / fine-tuning
- Hardware acquisition recommendations beyond what's needed for tier
  thresholds
- Token-issuance design changes (Track B locked that)

## Output format

Markdown memo, **~400-700 lines**. Tables for Parts 1, 2, 3, 4, 5.
Prose for Part 6. Cite every market-price claim and every published
benchmark with source URL + date pulled. Conservative > optimistic
on TPS projections. If a model is in active development but not
production-ready on Apple Silicon (e.g., MLX support pending), say
that explicitly rather than projecting.
