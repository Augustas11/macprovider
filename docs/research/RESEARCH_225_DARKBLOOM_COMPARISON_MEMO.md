# codex advisor artifact

- Provider: codex
- Exit code: 0
- Created at: 2026-06-30T05:44:42.603Z

## Original task

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

## Final prompt

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

## Raw output

```text
**Memo: Darkbloom.dev Benchmark Pulled 2026-06-30**

**Lede**

Darkbloom is real and operating, but it is not a clean proof that dense 32B/70B Apple Silicon inference can clear provider economics at competitive buyer prices. It is a hub-and-spoke Apple Silicon inference network run by Eigen Labs, with provider-supplied Macs, OpenAI-compatible APIs, live providers, public stats, public pricing, and Stripe-based USD credits/payouts.

The most important caveat: Darkbloom’s live catalog is mostly small-active-parameter MoE models, not dense 32B/70B models. Its buyer prices are excellent, but provider earnings are still mostly base rewards/subsidy, not organic usage revenue.

Sources pulled 2026-06-30: https://darkbloom.dev, https://docs.darkbloom.dev/llms.txt, https://api.darkbloom.dev/v1/pricing, https://api.darkbloom.dev/v1/models/catalog, https://api.darkbloom.dev/v1/stats, https://api.darkbloom.dev/v1/network/totals?window=30d, https://www.darkbloom.dev/privacy.html, https://www.darkbloom.dev/terms.html, https://openrouter.ai/provider/darkbloom, https://www.bankless.com/read/eigen-labs-is-turning-idle-macs-into-a-private-ai-network.

**Part 1: What Darkbloom Actually Is**

One-line pitch, their words: cost-efficient private AI inference on verified Macs, routed to hardware-verified Apple Silicon providers. Source: https://darkbloom.dev, pulled 2026-06-30.

Launch status: public alpha. Bankless reported the public alpha launch on May 28, 2026 and cited a May 26, 2026 upgrade from research preview to public alpha. Source: https://www.bankless.com/read/eigen-labs-is-turning-idle-macs-into-a-private-ai-network, pulled 2026-06-30.

Architecture: not pure P2P. It is a centralized coordinator / aggregator routing layer with independently operated Mac providers. Users call a chat UI or OpenAI-compatible API; the coordinator matches requests to eligible providers; providers run the model and return outputs. Source: Bankless article and Darkbloom docs, pulled 2026-06-30.

Hardware target: Apple Silicon only for providers. Docs say Apple Silicon M1 or later, macOS 14+, 16 GB minimum for the agent, and 36 GB+ recommended for the smallest catalog model. Source: https://docs.darkbloom.dev/provider/overview.md, pulled 2026-06-30.

Workload focus: text/chat inference is live; docs/API also reference audio transcription, image generation, multimodal Gemma input, and OpenAI-compatible chat/completions. Live direct catalog on 2026-06-30 listed GPT-OSS 20B and Gemma 4 26B variants. Source: https://api.darkbloom.dev/v1/models/catalog, pulled 2026-06-30.

Payment rail: USD prepaid credits via Stripe for buyers; Stripe Connect payouts for providers. Docs state a $0.50 minimum deposit and USD-denominated credits. Source: https://docs.darkbloom.dev/billing/add-credits.md and https://docs.darkbloom.dev/provider/earnings.md, pulled 2026-06-30.

Chain / token: no Darkbloom-specific token or contract address found in official docs. Terms/privacy mention wallet and blockchain transaction data as possible payment/auth data, but public docs I verified only document Stripe USD credits and Stripe Connect payouts. Source: https://www.darkbloom.dev/terms.html and https://www.darkbloom.dev/privacy.html, pulled 2026-06-30.

Open source status: a public `Layr-Labs/d-inference` GitHub repo exists and GitHub metadata describes it as “Private Inference Network on Idle Macs,” created 2026-03-15, but its GitHub API license field is `NOASSERTION`. I did not inspect repository source because this workspace’s AGENTS.md marks that repo as clean-room. Source: https://github.com/Layr-Labs/d-inference, pulled 2026-06-30.

Company/team: Eigen Labs, Inc. operates Darkbloom; no separate DAO structure found. Source: https://www.darkbloom.dev/terms.html, pulled 2026-06-30.

Funding: Darkbloom-specific funding not disclosed. Eigen Labs previously raised major funding from a16z crypto; that is parent/company context, not a Darkbloom-specific round. Source: https://blog.eigencloud.xyz/accelerating-ethereum-together-a16z-crypto-x-eigen-labs/, pulled 2026-06-30.

Privacy caveat: Darkbloom marketing/docs describe encrypted/operator-blind inference, but the privacy policy is more conservative and says current service paths may require coordinator plaintext processing and disclosure to selected providers. Treat privacy as an active design direction with alpha-stage caveats, not a uniformly deployed end-to-end guarantee. Sources: https://docs.darkbloom.dev/security/overview.md and https://www.darkbloom.dev/privacy.html, pulled 2026-06-30.

**Part 2: Pricing Surface**

Current live direct API pricing on 2026-06-30:

| Darkbloom live model | Class | Input $/1M | Output $/1M | Notes |
|---|---:|---:|---:|---|
| `gpt-oss-20b` | 20.9B MoE, 3.6B active | $0.0145 | $0.0700 | 24 GB min RAM, fp8 |
| `gemma-4-26b` | 25.2B MoE, 3.8B active | $0.0300 | $0.1650 | 36 GB min RAM, 8-bit |
| `gemma-4-26b-8bit` | 25.2B MoE, 3.8B active | $0.0300 | $0.1650 | rollback/beta variant |
| `gemma-4-26b-qat-4bit` | 25.2B MoE, 3.8B active | $0.0300 | $0.1650 | 32 GB min RAM, multimodal beta |
| fallback | unspecified | $0.0500 | $0.2000 | public fallback row |

Source: https://api.darkbloom.dev/v1/pricing and https://api.darkbloom.dev/v1/models/catalog, pulled 2026-06-30.

Docs pricing is stale or broader than current live API. Docs list Gemma 4 26B at $0.065/$0.20, Qwen3.5 27B at $0.10/$0.78, Qwen3.5 122B at $0.13/$1.04, and MiniMax M2.5 at $0.06/$0.50. The docs explicitly say to fetch `/v1/pricing` for current rates, so I treat the API as authoritative. Source: https://docs.darkbloom.dev/billing/pricing.md, pulled 2026-06-30.

OpenRouter lists Darkbloom as a provider with two free variants: Gemma 4 26B A4B and GPT-OSS 20B, both `$0/M` input and output on OpenRouter at pull time. Source: https://openrouter.ai/provider/darkbloom, pulled 2026-06-30.

Comparison table:

| Model class | OpenRouter cheap | Darkbloom live direct | Darkbloom via OpenRouter | macprovider current | Macprovider v2 target |
|---|---:|---:|---:|---:|---:|
| 7-8B | $0.04/M | not listed live | not listed | $1.00/M | TBD |
| ~20-26B MoE | n/a in provided table | $0.070-$0.165/M output | $0/M listed | $1.00/M | TBD |
| 32B dense | $0.28/M | not listed live | not listed | $1.00/M | TBD |
| 70B dense | $0.32/M | not listed live | not listed | $1.00/M | TBD |

Buyer-side read: Darkbloom direct is far below macprovider current, but it is not serving the same dense 32B/70B class. OpenRouter’s free Darkbloom rows make the competitive comparison even harder for macprovider, but free capacity should be treated as promotional or partner-routed until a durable paid schedule is shown.

**Part 3: Provider Economics**

Published provider model: consumers pay per token; providers keep 100% of inference revenue during public alpha; payouts use Stripe Connect. Source: https://docs.darkbloom.dev/provider/earnings.md and https://darkbloom.dev, pulled 2026-06-30.

Base rewards: Darkbloom’s public calculator includes a base-reward floor by memory tier, added on top of usage, for attested machines online at least 90% of the month. The site warns the base reward is not guaranteed and tapers as network grows. Source: https://darkbloom.dev/earn-calculator.js, pulled 2026-06-30.

Calculator assumptions: 80% utilization, continuous batching at 4x, prompt:completion ratio about 3.5:1, single-stream efficiency 0.6 of memory bandwidth divided by active model GB. Source: https://darkbloom.dev/earn-calculator.js, pulled 2026-06-30.

Provider calculator reverse-engineer, using current live prices and public calculator equations:

| Hardware | Model | Online | Calc effective decode TPS | Usage net / hr | Base reward / mo | Monthly net |
|---|---|---:|---:|---:|---:|---:|
| M4 Air 24GB | GPT-OSS 20B | 8h/day | 57.6 | $0.0246 | $0 | $5.89 |
| M4 Air 24GB | GPT-OSS 20B | 24/7 | 57.6 | $0.0246 | $10 | $27.68 |
| M4 Air 32GB | Gemma 4 26B QAT | 8h/day | 57.6 | $0.0555 | $0 | $13.32 |
| M4 Air 32GB | Gemma 4 26B QAT | 24/7 | 57.6 | $0.0555 | $12 | $51.97 |
| M4 Max 48GB | Gemma 4 26B QAT | 8h/day | 262.1 | $0.2511 | $0 | $60.27 |
| M4 Max 48GB | Gemma 4 26B QAT | 24/7 | 262.1 | $0.2511 | $16 | $196.82 |
| M2 Ultra 64GB | Gemma 4 26B QAT | 24/7 | 384.0 | $0.3654 | $18 | $281.12 |
| M3 Ultra 96GB | Gemma 4 26B QAT | 24/7 | 393.1 | $0.3731 | $22 | $290.64 |

Reality check from live network totals:

| Window | Active accounts | Total earnings | Work earnings | Reward earnings | Tokens | Jobs |
|---|---:|---:|---:|---:|---:|---:|
| 24h | 207 | $174.10 | $34.25 | $139.85 | 730.4M | 352,144 |
| 7d | 287 | $1,103.87 | $162.17 | $941.71 | 3.57B | 1,773,011 |
| 30d | 398 | $2,209.47 | $263.71 | $1,945.76 | 6.63B | 2,766,541 |

Source: https://api.darkbloom.dev/v1/network/totals?window=24h, `7d`, `30d`, pulled 2026-06-30.

Provider economics conclusion: calculator economics can look viable for M4 Max/Ultra under high utilization, but live demand does not yet support those earnings. Over 30 days, only about $263.71 of provider earnings were work revenue across 398 active accounts; the majority was reward/base-floor subsidy. This supports Track A’s “token subsidy structurally required” conclusion, except Darkbloom’s subsidy appears USD/reward-floor denominated rather than a protocol token.

**Part 4: TPS / Latency / Quality Claims**

Live network stats at pull:

| Metric | Value |
|---|---:|
| Active providers | 333 |
| Serving providers | 75 |
| Online providers | 247 |
| Untrusted providers | 11 |
| Code-attested providers | 300 |
| Total tokens served | 7.37B |
| Total requests | 2.93M |
| Total memory | 30,324 GB |
| Total GPU cores | 11,894 |
| Total memory bandwidth | 151,760 GB/s |
| Reported network capacity | ~5,817 TPS |
| Active requests | 133 |
| Queued requests | 0 |

Source: https://api.darkbloom.dev/v1/stats, pulled 2026-06-30.

Hardware distribution snapshot:

| Chip tier | Providers | Memory GB | GPU cores | Bandwidth GB/s |
|---|---:|---:|---:|---:|
| M4 Max | 62 | 4,416 | 2,320 | 31,132 |
| M1 Max | 46 | 2,464 | 1,328 | 18,400 |
| M3 Ultra | 35 | 11,360 | 2,480 | 28,665 |
| M4 Pro | 35 | 1,520 | 640 | 9,555 |
| M3 Max | 26 | 2,024 | 940 | 9,400 |
| M2 Max | 24 | 1,472 | 864 | 9,600 |
| M4 Base | 21 | 544 | 210 | 2,520 |
| M2 Ultra | 19 | 2,112 | 1,204 | 15,200 |

Source: https://api.darkbloom.dev/v1/stats, pulled 2026-06-30.

Per-provider measured TPS: docs define a `decode_tps` field, but the sampled `/v1/stats` response had `decode_tps: 0` on inspected provider snapshots, so I do not treat per-device TPS as publicly measured. Source: https://docs.darkbloom.dev/reference/stats.md and https://api.darkbloom.dev/v1/stats, pulled 2026-06-30.

Published/claimed model throughput: docs claim MiniMax M2.5 achieves approximately 100 tok/s on Apple Silicon, but MiniMax was not in the live direct catalog at pull time. Source: https://docs.darkbloom.dev/api/models.md and https://api.darkbloom.dev/v1/models/catalog, pulled 2026-06-30.

Latency: I found no public p50/p95/p99 time-to-first-token metrics. Release metadata for v0.6.28 says a provider engine-loop change improved GPU utilization and lowered stream interval for user latency, but that is not an SLO or percentile benchmark. Source: https://api.darkbloom.dev/v1/releases/latest, pulled 2026-06-30.

Quality benchmarks: I found no Darkbloom-run MMLU, HumanEval, SWE-bench, or comparable quality report. Model descriptions are mostly upstream model descriptions, not Darkbloom-specific evals. Source: https://api.darkbloom.dev/v1/models/catalog and https://docs.darkbloom.dev/api/models.md, pulled 2026-06-30.

Track A comparison:

| Hardware × Model | Track A 12mo C | Darkbloom claim / evidence | Track A H100 ref |
|---|---:|---:|---:|
| M4 Max × 32B dense | 75 tok/s | no live 32B dense; calculator implies ~82 single-stream TPS for 4B-active MoE, not dense 32B | 1200 |
| M2/M3 Ultra × 32B dense | 120-140 tok/s | no live 32B dense; calculator implies ~120 single-stream TPS for 4B-active MoE | 1200 |
| M3 Ultra × 70B dense | 65 tok/s | no live 70B; no measured public claim found | 600 |

Interpretation: Darkbloom does not contradict Track A’s dense-model bandwidth ceiling. Their live win comes from MoE models with ~3.6B-3.8B active parameters, Apple Silicon memory aggregation, batching assumptions, and low marginal-cost hardware, not from proving M4 Air can serve Qwen3-32B dense at 80 tok/s.

**Part 5: Cross-Track Implications**

For Track A:

1. Darkbloom does not validate “llama.cpp `--parallel` is best near-term bet.” It appears to use MLX-family Apple Silicon infrastructure, not llama.cpp. Docs mention `vllm-mlx` / `mlx-lm`; current installer/release metadata says `mlx-swift`.

2. Darkbloom’s runtime appears to have migrated. Docs say bundled Python/vllm-mlx; live installer says Swift CLI, links `mlx-swift` directly, ships `mlx.metallib`, and has no Python inference subprocess. Source: https://api.darkbloom.dev/install.sh and https://api.darkbloom.dev/v1/releases/latest, pulled 2026-06-30.

3. No Darkbloom number forces a Track A dense 32B/70B retarget. Their public capacity is not a dense Qwen3-32B benchmark.

4. I found no evidence that Darkbloom is running speculative decode in production. Release notes mention an engine-loop scheduling fix and streaming interval, not draft-model speculation.

5. Darkbloom does support the Track A architectural direction of routing models by hardware tier. Live catalog has min RAM gates: GPT-OSS 20B at 24 GB, Gemma QAT at 32 GB, Gemma 8-bit at 36 GB. Source: https://api.darkbloom.dev/v1/models/catalog, pulled 2026-06-30.

For Track B:

1. Darkbloom direct buyer pricing is well below macprovider current and below a “10-30% under OpenRouter Qwen3-32B” target for its live MoE class. But it is not a comparable dense 32B product.

2. Providers appear to earn USD-denominated account credits/payouts, not only tokens. Provider payouts use Stripe Connect; network totals report micro-USD earnings. Source: docs/provider/earnings and `/v1/network/totals`, pulled 2026-06-30.

3. Darkbloom tier-filters hardware via min RAM/model compatibility and attestation/trust status. It also tracks hardware family/tier, memory, GPU cores, bandwidth, and trust level in public stats.

4. Provider churn/cohort data is partially visible: 398 active accounts in 30d, 333 connected providers at pull time, 205 providers with nonzero generated tokens in inspected current-session stats. It does not publish full churn cohorts.

5. If Darkbloom has buyer-competitive USD price and provider-viable Apple Silicon earnings, the current math depends on rewards/base floors and optimistic utilization, not work revenue alone. The live 30d split is $263.71 work vs $1,945.76 rewards, so organic paid demand is not yet enough.

Hard call: Darkbloom is ahead of macprovider on branding, public stats, OpenAI-compatible API, provider onboarding, hardware attestation story, and buyer pricing for current MoE models. It is not yet ahead as proof of durable provider economics. Its live data reinforces that subsidy/rewards are needed while demand ramps.

**Part 6: Differentiation / Strategy**

What macprovider should copy:

| Darkbloom pattern | Why copy |
|---|---|
| Public `/stats`, `/pricing`, `/models` endpoints | Makes claims auditable and creates market confidence |
| Hardware tier filters | Prevents weak hardware from serving wrong model classes |
| Provider earnings transparency | Lets providers understand utilization and realistic pay |
| OpenAI-compatible API | Lowers buyer migration friction |
| Per-model RAM requirements | Reduces bad-provider UX and failed jobs |
| Base rewards separated from work revenue | Makes subsidy visible instead of hiding it inside tokenomics |

Where macprovider can differentiate:

| Differentiation | Rationale |
|---|---|
| Dense 7-8B and 32B specialization | Darkbloom live catalog is MoE-heavy; macprovider can be explicit about dense model guarantees |
| Honest provider economics | Publish “work revenue vs subsidy” from day one; Darkbloom’s own data shows this matters |
| llama.cpp operational excellence | If Track A’s near-term bet is llama.cpp batching, own that lane instead of chasing MLX parity immediately |
| Privacy claims with fewer caveats | Darkbloom has a marketing/privacy-policy mismatch; macprovider can win trust by being conservative and precise |
| Model curation for agents/developers | Darkbloom’s live models are general; macprovider can focus on coding, tool-use, MCP/A2A agent traffic |
| QoS tiers | Darkbloom public alpha disclaims SLAs; paid buyers may value latency/uptime commitments over lowest price |
| Provider segment clarity | Aim separately at M4 Air 7-8B providers and M-Max/Ultra 32B providers instead of one blended fleet |

Recommended posture:

Do not copy Darkbloom’s exact model mix unless macprovider is willing to pivot from dense 32B economics to small-active MoE economics. Darkbloom’s live system strongly suggests that “Apple Silicon works” depends on using MoE active-parameter economics, RAM gating, batching, and subsidy. For macprovider, the v2 pricing design should explicitly separate buyer price, provider work revenue, and subsidy/reward budget.

For Track A, keep Roadmap D: M4 Air for 7-8B, 32B routed to M-Max/Ultra, near-term batching work. Darkbloom does not disprove that.

For Track B, adopt a Darkbloom-like public pricing and earnings surface, but do not infer that buyer-competitive pricing alone solves provider viability. The live Darkbloom split shows that subsidy is still carrying the provider side.


```
