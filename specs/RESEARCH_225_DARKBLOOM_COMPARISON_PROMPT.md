# RESEARCH PROMPT — Darkbloom.dev comparison: pricing, TPS, network architecture

Run as: `omc ask codex "$(cat specs/RESEARCH_225_DARKBLOOM_COMPARISON_PROMPT.md)"`

This is a focused strategy research prompt — follow-up to RESEARCH_223
(MLX throughput roadmap) and RESEARCH_224 (beta pricing v2). Single
codex call. Output is a comparison memo + implications for both
parent tracks.

---

## Task

**Darkbloom.dev** is a distributed inference network the operator
believes is architecturally similar to macprovider (modular, likely
Apple Silicon-friendly, provider-supplied compute). Use it as a
**live benchmark** for what pricing + per-token-throughput + model
selection currently looks like on a comparable network as of
2026-06-30. Findings feed both the MLX roadmap (Track A) and the
beta pricing decision (Track B).

If darkbloom.dev turns out to be architecturally different than
expected (e.g., centralized, datacenter-GPU-only, training-focused
rather than inference), say so clearly and report whatever they
actually are — the operator wants ground truth, not a forced fit.

---

## Background — why we care

Macprovider's current posture (pre v2):
- USD multiplier 1.0 → buyer $1.00/M completion (3.5× over OpenRouter
  Qwen3-32B $0.28/M)
- Provider $0.045/hr at M4 Air × 14 tok/s × single stream
- No hardware tier filter
- No protocol token issued
- Hardware fleet: predominantly M4 Air, small number M4 Max + M2 Ultra

Track A (RESEARCH_223) concluded: at conservative 12-month TPS targets,
**no Apple cell clears $0.30/hr at buyer-competitive USD ($0.25/M)**
— token subsidy is structurally required. Track A recommended
Roadmap D (hybrid): M4 Air for 7-8B only, 32B routed to M-Max/Ultra,
llama.cpp `--parallel --cont-batching` as the best near-term
engineering bet.

Track B (RESEARCH_224, in flight) is producing the multiplier + tier
filter + token issuance design.

**The question for this memo**: does darkbloom.dev's live operating
data validate, contradict, or refine the macprovider posture? If
they're successfully serving paid inference on Apple Silicon at
competitive pricing, how? If they tried and pivoted, why?

---

## What to produce

### Part 1 — What is darkbloom.dev actually?

Visit darkbloom.dev directly. Pull their docs, blog, GitHub org if any,
Twitter/X account, Farcaster, Discord/Telegram public channels. Report:

- **One-line elevator pitch** (their words, not yours)
- **Founding date / launch date** (mainnet, testnet, alpha — whatever
  they call it)
- **Architecture**: distributed P2P? centralized aggregator with
  provider back-ends? hub-and-spoke coordinator? cite the doc URL
- **Hardware targeted**: Apple Silicon? consumer GPUs? datacenter? mix?
- **Workload focus**: text inference? image gen? video? training?
  fine-tuning? embeddings?
- **Payment rail**: USD/USDC? own token? credits? gas-paid?
- **Chain (if any)**: which L1/L2, contract addresses if findable
- **Open source status**: is the coordinator / provider client / token
  contract on GitHub? license?
- **Public team / company / DAO structure**
- **Funding** (a16z? paradigm? bootstrapped? token sale? grant?)

If parts of this are not findable on public web, say "not disclosed"
rather than guess.

### Part 2 — Pricing surface

Pull current **buyer-side pricing** for darkbloom.dev. Try every angle:

- Public pricing page on darkbloom.dev
- API docs with $/M-token rates
- Twitter posts where they announced pricing
- Comparable-pricing pages they reference
- Community wiki / Discord faq mirrors

Report:
- $/1M prompt and $/1M completion **per model class** they list
- Discount tiers, monthly minimums, prepaid credits
- Trial credits / free tier
- Whether their pricing is denominated in USD, USDC, or their own token
- Date pulled + source URL

Then **compare side-by-side** with macprovider's current default and
the cheapest market rows from RESEARCH_222 v1 table (OpenRouter
Qwen3-32B $0.28/M, Together Qwen2.5-Coder-32B $0.80/M, Groq 8B $0.04/M):

| Model class | OpenRouter cheap | Darkbloom | macprovider current | Macprovider v2 target (TBD by Track B) |
|---|---:|---:|---:|---:|
| 7-8B | $0.04/M | ? | $1.00/M | ? |
| 32B | $0.28/M | ? | $1.00/M | ? |
| 70B | $0.32/M | ? | $1.00/M | ? |

### Part 3 — Provider economics

Pull whatever they publish about **provider-side earnings**. Try:

- Provider onboarding page / "become a node operator" docs
- Required hardware specs (which Apple Silicon SKUs? GPUs? RAM?)
- Earning model: per-token-served? per-hour-online? staking-weighted?
  token-issuance-weighted?
- Stated $/hr or token/hr earnings ranges per hardware tier
- Slashing / penalty mechanics
- Vesting / cliff on early-provider rewards
- Anti-sybil / KYC / staking-bond requirements
- Date pulled + source URL

If they publish a "what you'd earn" calculator, screenshot/record the
inputs and outputs at a few realistic settings (M4 Air, M4 Max,
24/7 vs 8h/day).

### Part 4 — TPS / latency / quality claims

Pull whatever they publish (or third parties have measured) about
**observed throughput**:

- Claimed sustained tok/s per hardware tier per model
- Independent benchmarks (Twitter, blogs, Reddit, OpenRouter-style
  aggregator pages that include them)
- p50 / p95 / p99 latency to first token
- Concurrent-streams handling (single-stream-only? continuous batching?
  multi-tenant?)
- Quality benchmarks (MMLU, HumanEval, etc.) for their hosted models

Compare to Track A's per-cell targets:

| Hardware × Model | Track A 12mo C | Darkbloom claim | Track A H100 ref |
|---|---:|---:|---:|
| M4 Max × 32B | 75 tok/s | ? | 1200 (32-stream) |
| M2/M3 Ultra × 32B | 120-140 tok/s | ? | 1200 |
| M3 Ultra × 70B | 65 tok/s | ? | 600 |

If their claims contradict Track A's bandwidth-bound ceiling math
(e.g. "M4 Air does 80 tok/s on Qwen3-32B"), flag explicitly — either
they're using a different model definition (smaller, different
quantization), running speculative decode, batch-aggregating across
providers, or claim is marketing.

### Part 5 — Cross-track implications

Answer these explicitly:

**For Track A (MLX roadmap)**:
1. Does darkbloom.dev validate or contradict the "llama.cpp
   `--parallel` is best near-term bet" finding?
2. Are they using MLX, llama.cpp, or something else?
3. Do they have a published throughput number that should make us
   re-do any Track A 12-month target?
4. Are they running speculative decode in production? draft-model
   selection?

**For Track B (pricing v2)**:
1. What's their buyer USD price relative to macprovider's "undercut
   OpenRouter by 10-30%" target?
2. Are providers actually earning USD or only tokens? What's the
   USD:token split?
3. Are they tier-filtering hardware? what's the schema?
4. Do they publish provider churn? cohort-size data? meta tells us
   whether the token-subsidy model is working in the wild.
5. If darkbloom.dev has both a buyer-competitive USD price AND
   provider-viable earnings on Apple Silicon, **how do the numbers
   actually work**? Reverse-engineer their math.

**Hard call**: if darkbloom.dev is straightforwardly better than
macprovider on multiple axes (price, hardware fit, provider
economics), say so and recommend what macprovider should copy or
differentiate on. If darkbloom.dev is worse / vaporware / abandoned,
say that too — operator wants ground truth.

### Part 6 — Differentiation / strategic implications

If darkbloom.dev is real and operating, where can macprovider
**differentiate** rather than compete head-on? Candidates:
- Verifiable inference (cryptographic proof of model + prompt)
- Privacy / local-first / no-data-retention guarantees
- Specific model curation (e.g., only open-weights, no proprietary)
- Specific buyer segments (developers? agents? enterprises?)
- Specific provider segments (homelab? prosumer? professional?)
- Integration surface (OpenAI-compat API, MCP, A2A, etc.)
- Quality-of-service guarantees (latency SLOs, uptime, throughput
  commitments)

Or — recommend that macprovider just adopts darkbloom.dev's posture if
it's clearly working.

---

## Out of scope

- Reverse-engineering proprietary darkbloom.dev code (use only public
  surfaces — docs, blog, GitHub if open, tweets, Discord public)
- Copying any darkbloom.dev IP or trademarks
- Reaching out to darkbloom.dev team for unpublished data
- Producing code changes (memo only)
- Producing SPEC delta (memo only)

## Output format

Markdown memo, **~300-600 lines**. Tables for Parts 2, 3, 4. Prose
for Parts 1, 5, 6. Cite every claim with **source URL + date pulled**.
If darkbloom.dev turns out to be different than expected (centralized,
not Apple Silicon focused, abandoned, vaporware, scam, training-only,
etc.), make that the lede — don't bury it. Conservative > optimistic
on their claims; flag marketing-vs-measured throughout.
