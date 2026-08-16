# RESEARCH PROBE — Goodhart failure modes in marketplace recommender formulas (SPEC-018 v0.1 input)

Run as: `omc ask codex "$(cat specs/RESEARCH_229_GOODHART_DEMAND_SIGNAL_PROBE_PROMPT.md)"`

This is a **scoped pre-SPEC probe**, not a full research memo. Single codex call, ~20-40 min wall time, ~200-400 line output. Feeds directly into `specs/SPEC-018-installer-autotune-recommend-v0.1.md` drafting on the same day.

## Context

macprovider is a P2P Apple-Silicon LLM inference network. Buyers call `https://api.malibu.tech/v1/chat/completions`, gateway routes to coordinator, coordinator picks a provider Mac running the requested model. Providers earn per-token rate-card revenue.

Wave 0c (the SPEC-018 surface) introduces a provider-side install/autotune recommendation: when a new operator runs `macprovider install` on their Mac, the script scores each rate-card-eligible model on their hardware and recommends the one with the highest expected `$/hr` so they earn the most:

```
score(model | mac) = TPS(model, mac) × 3600 × $/M × provider_share × demand_signal(model)
recommend = argmax(score)
```

Inputs:
- `TPS(model, mac)` — measured locally by autotune probe on this Mac (not provider self-report).
- `$/M` — from rate card (Entry 92 v2: gpt-oss-20b $0.10/M, qwen3-coder-30b-a3b $0.235/M, qwen3-32b $0.220/M, llama-3.1-8b $0.027/M, qwen2.5-coder-32b $0.850/M, etc.).
- `provider_share = 0.90` (fixed).
- `demand_signal(model)` — open design question. Candidates: (a) OpenRouter rank baked at install time, (b) live `stats_*` rollup from coord (SPEC-017 surface), (c) static operator-set weight per row, (d) constant 1.0 with price competing.

This formula is the lever providers will optimise around. Beta launch is preparing for a 120-provider cohort (Tier-S 20 + Tier-A 50 + Tier-B 30 + Tier-C 20 per Entry 92).

## Task

Identify Goodhart-class failure modes that arise when this formula becomes the population-wide signal driving 120+ provider model choices, AND propose concrete bake-in-the-SPEC-v0.1 mitigations for each.

Specifically:

### Part 1 — Failure-mode catalog

For each failure mode:
- Concrete scenario (specific numbers if useful — assume 120 providers across tiers, current rate card)
- What the formula does wrong
- What the underlying intent was that gets corrupted
- Severity rating (network-killing / network-degrading / cosmetic)

At minimum, address these candidates (add more if you spot them):
1. **Winner-take-all on rank** — all 50 Tier-A providers install in week 1, all get recommended gpt-oss-20b → oversupply on rank-19, no provider chose Qwen3-Coder or Llama → buyer requesting those models gets `503 no provider`.
2. **Cold-start exclusion** — when a new rate-card row lands (e.g., DeepSeek-V3 distill ships), historical demand_signal = 0 → no provider gets recommended it → no traffic → permanent demand_signal = 0.
3. **TPS gaming** — providers learn to self-report inflated TPS to get recommended into high-$/M lanes. (Note: current design uses local autotune probe, not self-report — assess whether this fully closes the gaming surface.)
4. **Rate-card update lag** — operator hot-reloads rate card on Pearl; 50 installed providers have stale baked recommendation; week-on-week earnings drop; providers churn before re-tuning.
5. **Demand-signal source choice** — OpenRouter rank reflects the broader market, not macprovider's actual buyer mix; coord stats reflect macprovider's mix but bootstrap zero. Which is least-bad?
6. **Tier interaction** — Tier-S providers (M4 Max/Ultra) get the same recommendation logic as Tier-C (M1 Air); does the formula degrade gracefully across the 8× hardware spread, or does it produce pathological recommendations at the tails?
7. **Bid-shading / collusion** — providers coordinate off-network to pick complementary models (worth flagging even if unlikely).

### Part 2 — Mitigation library

For each failure mode in Part 1, propose 1-3 concrete v0.1 SPEC mechanisms. Each mitigation must specify:
- What the mechanism is (in 1-2 sentences)
- Where it lives in the design (formula vs install.sh vs autotune logic vs operator config)
- LOC estimate (rough — "small / medium / large")
- Whether it adds operator-visible UX, network state, or coord endpoints
- Whether it has downside risk worth flagging (e.g., a mitigation for cold-start that hides earnings projection from providers)

Bake the mitigation into v0.1 ONLY if:
- It addresses a failure mode rated network-killing or network-degrading
- It's cheap (small LOC, no new operator surface)
- It composes cleanly with the other mitigations

Defer to v0.2+ if it's expensive, adds operator surface, or addresses cosmetic-tier failure modes.

### Part 3 — Recommended v0.1 demand-signal source

Given (a) beta has ~120 providers in 6 months, (b) macprovider currently has ~2 providers + zero paying buyer history, (c) Wave 1 rate-card hot-reload will broadcast price updates within seconds, (d) Wave 0c is the install-time recommendation that needs to survive Wave 1 changes — recommend ONE concrete source choice for v0.1 with reasoning. Optional: stage to a v0.2 evolution.

Options to evaluate (rank them):
- (a) OpenRouter top-50 rank, baked into binary at release time (refreshed on `macprovider upgrade`)
- (b) OpenRouter top-50 rank, fetched live at install/autotune from a static URL (`get.malibu.tech/demand-rank.json`)
- (c) Coord stats rollup of last-7-day macprovider buyer requests, fetched live (`coordinator.malibu.tech/v1/demand-signal`)
- (d) Constant 1.0 — let price compete naturally
- (e) Hybrid: (a) or (b) for v0.1; switch to (c) at v0.2 once 60+ days of real macprovider buyer history exist

### Part 4 — One-line summary per Part

Each Part section ends with a single-line conclusion the SPEC author can lift verbatim into SPEC-018 v0.1.

## Constraints

- Read-only. Do NOT modify code, write specs, or fire other prompts.
- Cite real-world Goodhart manifestations where helpful (PageRank → SEO arms race, BLEU score → translation gaming, mining-pool difficulty → ASIC concentration, etc.) but ground every claim in the macprovider context.
- Do NOT inspect `Layr-Labs/d-inference` source per CLAUDE.md clean-room rule. Public docs only.
- Output: markdown memo, ~200-400 lines. Structure: Part 1 catalog (table per failure mode), Part 2 library (table mitigation × failure mode), Part 3 recommendation, Part 4 one-line conclusions.
