# RESEARCH PROBE — competitive provider-installer UX + analogous yield-recommendation surfaces (SPEC-018 v0.1 input)

Run as: `omc ask codex "$(cat audits/_prompts/RESEARCH_230_COMPETITIVE_INSTALLER_UX_PROBE_PROMPT.md)"`

This is a **scoped pre-SPEC probe**, not a full research memo. Single codex call, ~20-40 min wall time, ~200-400 line output. Feeds directly into `specs/SPEC-018-installer-autotune-recommend-v0.1.md` drafting on the same day.

## Context

macprovider's Wave 0c (SPEC-018) ships a provider-side install UX that scores each model on the operator's Mac and recommends the highest-expected-`$/hr` model to run. This is a net-new product surface; the operator (macprovider) needs to know whether anyone else in the GPU/compute marketplace space has shipped something analogous, and if not, which adjacent product UXes solve the same input-hardware → output-yield-projection-with-recommendation problem worth importing patterns from.

Current operator hypothesis (to confirm or refute):

> No major decentralized GPU/compute network has a provider-install "we recommend this model for your hardware to earn most" UX. Their provider model is different: vast.ai/RunPod/io.net rent raw GPU capacity (buyer brings the workload), Akash uses manifest-based bidding (provider doesn't pick a model), Darkbloom assigns the catalog top-down. None of them face macprovider's combination of (inference-as-service + heterogeneous consumer hardware + per-model rate card), so none of them face the "what model should this provider run to earn most?" problem.
>
> If true, the closest UX analogues are crypto staking-rewards calculators (StakingRewards.com, Lido dashboard) and mining-pool profitability calculators (WhatToMine.com) — both solve "input hardware/capital → ranked yield projection → recommendation" for heterogeneous-hardware-per-asset-rate markets.

## Task

### Part 1 — Competitive sweep

Confirm or refute the operator hypothesis above by checking the provider-onboarding UX for each network below. For each, answer:

- **Provider install flow shape**: CLI / desktop app / web dashboard / container manifest / hybrid?
- **Does it recommend a workload (model / job type) for the provider's specific hardware?** If yes, what's the recommendation logic + UX surface?
- **Does the provider pick the workload, or is it assigned by the network / buyer?**
- **Does it project earnings before commit?** (Either "this hardware will earn $X/hr" or "this workload on this hardware will earn $X/hr".)
- **One-line summary** of how this maps to macprovider's design space.

Networks to cover (add others if you spot them — Together.ai, Lepton, Modal, Replicate-provider-side, etc.):

1. **vast.ai** — public docs at https://vast.ai/docs/
2. **RunPod** — public docs at https://docs.runpod.io/
3. **io.net** — public docs at https://docs.io.net/
4. **Akash Network** — public docs at https://akash.network/docs/
5. **Aethir** — public docs / whitepaper
6. **Render Network** — public docs
7. **Bittensor** — subnet provider onboarding (Templar, Targon, any subnet handling inference)
8. **Helium** (legacy comparison only — different domain but inspiration source for tokenomics)
9. **Together.ai**, **Lepton.ai**, **Modal**, **Replicate** — closed-source provider sides; check public docs for any provider-onboarding surface (likely none — these are centrally-owned compute, not marketplaces)
10. **Layr-Labs/d-inference (darkbloom.dev)** — **DO NOT inspect source code per CLAUDE.md clean-room rule.** Public docs / whitepaper only. Confirm whether their provider onboarding has any model-recommendation surface or just runs the assigned catalog.

Output as a single comparison table.

### Part 2 — Closest UX analogues (non-competitive)

Survey the following analogous-shape products (input hardware/capital → ranked yield projection → recommendation), and for each pull 2-4 concrete design patterns that translate to macprovider's `autotune --recommend` output:

1. **StakingRewards.com** — heterogeneous staking options (validators, networks) ranked by APR for input stake amount
2. **Lido / RocketPool dashboards** — single-pool but rich yield projection UX
3. **WhatToMine.com** — input GPU model, output ranked profitability per coin
4. **NiceHash dashboard** — heterogeneous mining algorithm allocation per hardware
5. **Yield aggregators**: Yearn / Beefy / Convex — input asset, see ranked yield-per-pool
6. **Cloud cost calculators**: AWS Pricing Calculator, GCP Calculator — input workload, project cost (inverted yield but similar input-hardware shape)
7. **Power Compare / electricity-plan comparison sites** — input usage profile, get ranked best-plan recommendation with savings projection

For each: 2-4 design patterns with concrete examples and how they apply to macprovider. Categories worth checking:

- Input form UX (how is hardware specified — auto-detected vs operator-entered)
- Output ranking presentation (table / cards / chart / sortable)
- Projection confidence (single number / range / risk-adjusted)
- Alternatives display ("you chose X; here's what you would have earned with Y, Z")
- Refresh/staleness handling ("data 6h old", "refresh recommendation")
- Override / donor-mode pattern ("I want to pick a non-recommended option anyway")
- Transparency of formula ("why this recommendation" / "expected yield breakdown")
- Comparison vs network-wide average ("you earn 23% more than median provider in your tier")

### Part 3 — Differentiation framing

Given the Part 1 finding, write a 3-4 paragraph "wedge" framing for the SPEC-018 v0.1 preamble that operator (macprovider) can lift verbatim. The framing should:

- Cite the gap in Part 1 (no decentralized GPU network has this UX, and why — their model is different)
- Cite the closest analogues from Part 2 (staking calculator + mining profitability calculator UX patterns)
- Articulate why macprovider's combination forces this UX (heterogeneous consumer hardware + per-model rate card + inference-as-service)
- Be honest about what this WON'T do (e.g., it won't make providers earn money if there are no buyers; it solves the "which model" question, not the "is there demand" question)

### Part 4 — v0.1 SPEC implications

Concrete list of design decisions Part 1-3 should drive into SPEC-018 v0.1:

- **Output schema** for `autotune --recommend` (JSON shape with 3-5 ranked candidates, score breakdown, comparison vs default)
- **Install transcript copy** (what the operator sees during install — 1-2 example transcripts: happy path + "this Mac is donor-tier")
- **Re-tune cadence + UX** (`autotune --recommend` rerunnable? auto-prompt on rate-card change? operator-triggered only?)
- **Donor-mode opt-in pattern** (CLI flag? YAML config? install-time prompt with explicit "you'd earn $X less" warning?)
- **Status-command integration** (`macprovider status` showing "you're earning $X/hr on model Y; you could earn $Z/hr on model W")

Each implication ties back to a concrete Part 2 pattern + Part 1 confirmation.

### Part 5 — One-line summary per Part

Each Part section ends with a single-line conclusion the SPEC author can lift into SPEC-018 v0.1.

## Constraints

- Read-only. Do NOT modify code, write specs, fire other prompts, or sign up for accounts on any of the surveyed services.
- Web/doc inspection allowed for everything EXCEPT Layr-Labs/d-inference source (clean-room per CLAUDE.md). For d-inference, only public docs / whitepaper / public marketing pages allowed.
- Cite every claim with a URL or "public docs ¶X" reference. If a service's docs don't address a question, say so explicitly ("docs do not mention X").
- Conservative > speculative. If a network has a private provider-recommendation surface you can't verify, flag it as unknown rather than asserting it doesn't exist.
- Output: markdown memo, ~200-400 lines. Structure: Part 1 table, Part 2 patterns, Part 3 wedge framing, Part 4 implications list, Part 5 one-line conclusions.
