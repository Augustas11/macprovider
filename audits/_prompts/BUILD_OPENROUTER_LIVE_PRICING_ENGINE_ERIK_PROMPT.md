# Task: OpenRouter live pricing engine (real-time rate-card ingestion)

Nice work on the oMLX gates — you had the hard part (the trust invariant + scope discipline) right. This next one is a step up: real code, and a **working system**, not a memo. It's the durable version of the rate-card refresh — instead of hand-surveying OpenRouter every month, we build the pipeline that keeps pricing current on its own.

## Why (the problem this fixes)
The rate-card (`phase3-binary/catalog/autotune/rate-card.json`) sets **what a provider earns per token** for each model, benchmarked against the competitive market (OpenRouter). Today that benchmark is stale manual desk research (`docs/research/RESEARCH_227_RATE_CARD_V3_MEMO.md`). Stale pricing quietly bleeds: too high → buyers leave; too low → providers underearn. We want a system that pulls live market data and continuously computes fresh proposed pricing.

## The critical design constraint (read first)
**We never auto-write a money-path rate-card unsupervised.** A bad OpenRouter pull — a 429, a schema change, a garbage row — must never silently push wrong prices to providers and buyers. So the system is **continuous compute + a guarded apply**: it fetches live and computes proposed pricing on every run, but turning a proposal into a live `rate-card.json` change goes through a sanity gate + review. That gate is the line between your part and ours.

## The system — three components

**Component 1 — Live fetcher + normalizer (YOURS; durable core, non-money-path).**
- Fetch `https://openrouter.ai/api/frontend/v1/rankings/models` (rankings/demand) + per-model pricing.
- Handle the failure modes robustly and **fail closed**: rate-limit/429 backoff (RESEARCH_231 hit a Cloudflare 429 on the oMLX board — same class), timeouts, schema drift (unexpected fields/missing keys → reject, don't guess), empty/partial pulls.
- Normalize to a **stable, versioned snapshot** (JSON) with a content digest and a fetched-at timestamp — the same shape as the repo's oMLX monthly-snapshot pattern (find it under `scripts/` / the oMLX snapshot pipeline and mirror it). The snapshot is the durable artifact everything else consumes.

**Component 2 — Pricing compute engine (YOURS; the "real-time" part).**
- Input: the fresh snapshot + a **cost/margin policy** (the undercut-band rules from the RESEARCH_227 v3 prompt — read `audits/_prompts/RESEARCH_227_RATE_CARD_V3_PROMPT.md` for the class/openness/license filter and the target-rate formula).
- For each eligible model (clears demand + MLX-availability + permissive-license filter), compute the proposed macprovider rate.
- **Output a structured pricing PROPOSAL / diff** vs the current `rate-card.json` — machine-readable (added rows, changed rates, dropped rows), with the reasoning per row. This is what makes it "real-time": each run emits an up-to-date proposal. It does **not** write the rate-card.
- Include the **Nemotron-3 license resolution** as part of the eligibility logic (is `nvidia/nemotron-3-*` commercially permissive? cite the terms) — those rows are currently blocked on that question.

**Component 3 — Guarded apply (OURS; money-path — do NOT build this).**
- Applying a proposal to the live `rate-card.json` goes through a sanity gate (bounded per-row delta, no-empty-pull guard, staleness check) + review before it moves money. You build the interface (the proposal format Component 2 emits); we own the apply and its guardrails. **If your Component 2 logic starts deciding what actually ships to the rate-card, that's the boundary — stop and hand it over.**

## Deliverables (Components 1 + 2)
- A fetcher + normalizer that emits a versioned snapshot JSON, with rate-limit/schema-drift/empty-pull handling, runnable on demand and schedulable (match the existing snapshot script's invocation pattern).
- A compute engine that turns a snapshot + policy into a structured pricing proposal/diff, with the Nemotron license call baked into eligibility.
- **Tests + fixtures**: a recorded OpenRouter response fixture (so tests don't hit the network), and unit tests for the normalizer (incl. the failure modes: 429, malformed, empty) and the compute engine (a fixed snapshot → an expected proposal). Deterministic, offline-runnable.
- A short README section: how to run it, the snapshot schema, and the proposal format Component 3 consumes.

## Boundaries / scope (so you don't hit the walls you hit on oMLX)
- **You own Components 1 + 2** (fetch → normalize → compute → emit proposal). These are non-money-path: they produce artifacts, they don't change live pricing.
- **The apply (3) is ours** — the actual `rate-card.json` write + guardrails + deploy. Don't cross that line; if the work pulls you toward it, flag it and we take over (same split as oMLX).
- **Keep it off the money-path Go/Swift** where you can — a standalone script/tool (match the repo's `scripts/` conventions and the oMLX snapshot pattern) is the right home, not the coordinator or CLI serving code.
- **The audit is on us.** Don't block on running codex — I'll run the three-lane audit + an adversarial pass on your diff. Just flag anything you're unsure about, especially around the fail-closed failure modes.

## Read first (in order)
1. `docs/research/RESEARCH_227_RATE_CARD_V3_MEMO.md` — the current (stale) manual research this replaces.
2. `audits/_prompts/RESEARCH_227_RATE_CARD_V3_PROMPT.md` — the eligibility filter + target-rate formula (your Component 2 policy).
3. The repo's **oMLX monthly-snapshot** script/pipeline (grep `scripts/` for the oMLX snapshot) — the pattern to mirror for Component 1.
4. `phase3-binary/catalog/autotune/rate-card.json` — the current shipped rates (reference only; do not edit — that's Component 3).

## Done when
- Components 1 + 2 land as a PR: fetcher emits a versioned snapshot, compute engine emits a structured proposal (with the Nemotron call), fail-closed on the bad-pull paths, offline tests + fixtures green, README documented — and the proposal format is a clean handoff to the (our) guarded apply.

This is a real system, not a numbers refresh — that's the point. Build the engine that keeps pricing honest on its own; we'll wire the guarded money-move on top.
