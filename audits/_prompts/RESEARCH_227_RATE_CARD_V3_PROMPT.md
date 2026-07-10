# RESEARCH PROMPT — Macprovider rate-card v3: re-survey OpenRouter top-50 for broad-fleet MoE + developer-coding dense rows

Run as: `omc ask codex "$(cat /private/tmp/claude-501/-Users-augstar-macprovider-poc/968430ca-6bb8-4e93-9063-f4f57694e1c2/scratchpad/research_227_prompt.md)"`

Follow-up to RESEARCH_226 (MoE selection + market demand). That memo
was constrained by the candidate list I gave it (gpt-oss, gemma-4,
qwen3-moe, minimax, deepseek-distills, mixtral, phi-3.5-moe, dbrx) and
did not deeply evaluate other open-weight MoE rows visible in
OpenRouter top-50 (GLM 5.2 rank 8, Tencent HY3 rank 5, Xiaomi MiMo
rank 11, Kimi K2.6 rank 27, Nemotron-3 rank 25, Nemotron-3-nano-omni
rank 43). It also did not survey dense coding-specialist models for
the developer-target / M-Max+ tier (Qwen-Coder family, DeepSeek-Coder,
Codestral, StarCoder, etc.).

Output: a re-cut macprovider rate-card recommendation **with two
distinct tables** organized around the actual Mac fleet split:

- **Table A — Broad-fleet MoE rows**: models that fit any 24-32GB+
  Apple Silicon (M-base / M5 / M4 Air / M-Pro / M-Max), via the
  active-param-bandwidth math. Anchor on demand × deployability.
- **Table B — Coding-specialist dense rows for M-Max/Ultra**: models
  that target developers (highest-paying buyer segment) and require
  higher-end Macs (64GB+). Anchor on margin × demand.

This feeds a v3 update to `beta/DECISION_CRITERIA.md` Entry 92's
`rewards.rate_card` AND a rewrite of the macprovider-cli install
recommendation logic ([phase3-binary/dist/install.sh](phase3-binary/dist/install.sh)
`choose_model()` + [phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift](phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift)
`defaultCandidates`).

## Strict filter criteria

A model is a candidate ONLY if ALL apply:

1. **Has measurable demand** on OpenRouter (in top-100 by completion-token
   volume; use latest daily ranking from `https://openrouter.ai/api/frontend/v1/rankings/models`)
2. **Can run on MLX** (`mlx-community/<model>` exists on HuggingFace
   OR there is a documented MLX-Swift port OR GGUF on llama.cpp Metal
   path with production-readiness)
3. **Permissive commercial license** (Apache-2.0, MIT, BSD-3, custom
   commercial-permitted licenses like Llama 3 license; reject AGPL,
   research-only, no-commercial-use)
4. **One of two profiles**:
   - **Broad-fleet (Table A)**: active params ≤8B AND 4-bit residency
     ≤18GB (fits 24GB Mac with headroom) AND projected TPS ≥30 on M-base
   - **Coding-dense (Table B)**: dense or large-active-MoE, residency
     ≤45GB (fits 48-64GB Mac), targets coding/developer use case,
     projected TPS ≥20 on M-Max-class hardware

## Background — what's locked

- **Entry 92 v2 rate-card** (existing, no need to revisit pricing math):
  - 7-8B at $0.027/M (Llama-3.1-8B reference)
  - 32B dense at $0.220/M (Qwen3-32B reference)
  - 70B dense at $0.250/M (Llama-3.3-70B reference)
  - gpt-oss-20b at $0.100/M (MoE-small-active)
  - gemma-4-26b-a4b-it at $0.240/M (MoE-small-active)
  - qwen3-30b-a3b at $0.400/M (MoE-small-active, gated)
- **Per-model admission** with RAM-first eligibility (Entry 92)
- **Off-chain MPROV token ledger** subsidizes USD electricity-plus

- **Empirical TPS calibrations** (live network, measured 2026-06-30):
  - M5 32GB × Qwen3-32B-4bit dense: 5.10 tok/s network-delivered,
    6.78 tok/s localhost decode-only
  - Bandwidth-bound at theoretical ceiling; no anomaly
- **Buyer UX floors** (use as economic-floor reference):
  - <10 tok/s: donor-class only
  - 10-20: batch/agent acceptable
  - 20-30: chat acceptable
  - 30-50: smooth chat (target)
  - 50+: cloud-competitive

## What to produce

### Part 1 — Refreshed OpenRouter top-50 with class + openness classification

Pull latest `https://openrouter.ai/api/frontend/v1/rankings/models`.
For each row in top-50, classify:

| Rank | Model slug | Total params | Active params | Class | License | MLX/GGUF status | $/M completion | Cheapest provider |
|---:|---|---|---|---|---|---|---:|---|

Class = one of:
- `closed` (proprietary API model — Anthropic, OpenAI, Google Gemini etc.)
- `dense-small` (≤8B open)
- `dense-mid` (>8B ≤32B open)
- `dense-large` (>32B open)
- `dense-coding` (any size, but specialized for code — flag this)
- `moe-small-active` (active ≤8B open)
- `moe-mid-active` (active 8-32B open)
- `moe-large-active` (active >32B open)
- `moe-unknown-active` (open, but active param breakdown not public)

Then per row, mark fits filter criteria 1-3 above (demand + MLX + license).
For each that fits, mark Table A (broad-fleet) or Table B (coding-dense
for M-Max+) eligibility per criterion 4.

### Part 2 — Table A: Broad-fleet MoE rows for M-base / M5 / M-Air / M-Pro

| Rank | Model | Active params (GB at 4-bit) | Total residency 4-bit | OpenRouter cheapest $/M completion | Macprovider target $/M (undercut 10-30%) | Projected single-stream TPS @ M-base (~120 GB/s bandwidth) | Projected single-stream TPS @ M-Max (~410 GB/s) | Buyer UX band on M-base | Provider $/hr @ M-base / target rate | Provider $/hr @ M-Max / target rate | Verdict |
|---:|---|---|---|---:|---:|---:|---:|---|---:|---:|---|

Verdict = ✅ add / ⚠️ gated on X / ❌ skip.

Rank within this table by **(demand × deployability × economic margin)**:
- Demand weight: OpenRouter rank (lower rank = higher score)
- Deployability weight: MLX-mature > GGUF-mature > extrapolation
- Economic weight: provider $/hr at target rate × buyer UX band score

Then state the **recommended initial broad-fleet rate-card additions**
(2-5 rows). For each, cite:
- Why this beats or augments gpt-oss-20b / gemma-4-26b-a4b-it (Entry 92 anchors)
- Minimum RAM gate (per RESEARCH_226 per-model admission shape)
- Concrete `mlx-community/<exact-name>` ID
- Recommended `rewards.rate_card` row YAML

### Part 3 — Table B: Coding-specialist dense rows for M-Max / Ultra (developer-targeted)

The hypothesis: developer buyers (Cursor, Aider, Continue.dev users,
agentic-coding workflows) are willing to pay more per-token for
coding quality. Coding-specialist models often outperform
general-purpose models of similar size on HumanEval, SWE-bench,
LiveCodeBench. They're typically dense (not MoE) for predictable
quality. Run on M-Max/Ultra where bandwidth math supports dense.

Candidates to investigate explicitly:
- Qwen2.5-Coder-32B-Instruct (Apache-2.0)
- Qwen2.5-Coder-14B-Instruct
- Qwen2.5-Coder-7B-Instruct
- DeepSeek-Coder-V2-Lite-Instruct (15B / 2.4B active — actually MoE)
- DeepSeek-Coder-V2-Instruct (236B / 21B active — Ultra-only)
- DeepSeek-V3-Coder if exists
- Mistral Codestral 22B (commercial license caveats?)
- Mistral Codestral Mamba (state-space model, different architecture)
- StarCoder 2 (15B)
- StarCoder 2 3B / 7B
- Qwen3-Coder if released (verify)
- IBM Granite Code 8B / 20B / 34B
- Aider-anointed models from leaderboard
- Codeium open models if any
- Phind CodeLlama variants

For each that fits filter:

| Model | Total params | Architecture (dense vs MoE) | License | MLX/GGUF | HumanEval / SWE-bench (cite source) | OpenRouter rank (or "off OpenRouter — direct demand signal:" e.g. Aider leaderboard, Cursor adoption) | Cheapest market $/M completion | Macprovider target $/M | Projected TPS @ M-Max 64GB | Projected TPS @ M-Ultra | Provider $/hr @ M-Max / target | Provider $/hr @ M-Ultra / target | Verdict |
|---|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|

Rank by **(coding quality × demand × M-Max+ deployability × margin)**.

Then state the **recommended initial coding-dense rate-card additions**
(2-4 rows). Coding rows can price ABOVE general-purpose because
developer buyers pay for quality — propose pricing that:
- Targets 10-30% above general-purpose dense at same size (e.g., if
  Qwen3-32B is $0.220/M, Qwen2.5-Coder-32B might be $0.260-$0.290/M)
- Still undercuts cheapest market by ≥10%
- Produces provider $/hr ≥$0.10 on M-Max-class hardware (so providers
  see meaningful USD return, not just token subsidy)

### Part 4 — Models to REPLACE or DROP from Entry 92 if any

Compare new findings against current Entry 92 MoE anchors:
- gpt-oss-20b (anchored)
- gemma-4-26b-a4b-it (anchored)
- qwen3-30b-a3b (⚠️ engineering-led, no demand)

If Part 2 surfaces a higher-demand AND Apple-Silicon-deliverable MoE
row that beats one of these, recommend the swap and explain why. Be
willing to DEMOTE qwen3-30b-a3b if a better demand-led row exists.

### Part 5 — Install.sh + autotune recommendation overhaul

Concrete output: a recommended `choose_model()` interactive menu for
[phase3-binary/dist/install.sh](phase3-binary/dist/install.sh)
replacing the current dense-Qwen-anchored menu. Format:

```
Detected ~32 GB RAM.

Choose a model — sorted by network demand × hardware fit:
  1) mlx-community/<top-pick>             ~XX GB, target $YY/hr, rank Z
  2) mlx-community/<second>               ...
  ...
  c) custom HuggingFace MLX model id
Selection [default: <top-pick>]:
```

Generate the menu for each of these RAM tiers:
- 16 GB
- 24 GB
- 32 GB
- 48 GB
- 64 GB
- 96 GB+
- 128 GB+

And recommend the corresponding `AutotuneCommand.defaultCandidates`
Swift literal that surfaces the new model set:

```swift
static let defaultCandidates: [AutotuneCandidate] = [
    AutotuneCandidate(modelID: "<exact-mlx-community-id>", sizeB: N),
    ...
]
```

### Part 6 — Strategic verdict

One paragraph each, no fluff:

**Did RESEARCH_226 anchor on the right models?** Yes / partial / no.
If partial, what changes.

**Should macprovider open a developer-coding lane as a v3 differentiation?**
Yes if Part 3 surfaces ≥2 coding-dense rows with viable economics; no
otherwise. Cite Aider leaderboard / Cursor adoption / GitHub Copilot
alternatives evidence if available.

**Is there a 5-row "minimum viable rate-card v3" that the network
should ship?** If yes, list the 5 rows + their target prices.

### Part 7 — Open questions / data we couldn't verify

3-5 things we'd need to confirm before final commit. Examples:
- Exact active-param count for `z-ai/glm-5.2-20260616` (RESEARCH_226
  marked unknown; verify from HF model card or paper)
- License of `tencent/hy3-preview` (open or proprietary?)
- Whether `qwen3-coder-*` checkpoints exist by 2026-06-30

## Out of scope

- Re-litigating Entry 92 pricing math (USD multiplier, tier filter,
  token ledger design) — locked
- Investigating closed-API models (Anthropic, OpenAI, Google Gemini,
  X.AI Grok) — can't serve them anyway
- Inspecting `Layr-Labs/d-inference` source — clean-room
- Custom model training / fine-tuning

## Output format

Markdown memo, **~600-1000 lines**. Tables for Parts 1, 2, 3.
Concrete menu/Swift literals for Part 5. Prose for Parts 4, 6, 7.
Cite EVERY model selection with:
- HuggingFace URL (e.g., `https://huggingface.co/mlx-community/<name>`)
- OpenRouter rank + URL (`https://openrouter.ai/<slug>`)
- License source URL
- Active-params source (HF model card / paper / vendor announcement)

Conservative > optimistic on TPS projections. Flag every cell where
the active-params or MLX-readiness is inferred rather than verified.
