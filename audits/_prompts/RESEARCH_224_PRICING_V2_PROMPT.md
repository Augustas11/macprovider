# RESEARCH PROMPT — Beta pricing v2: buyer-competitive USD + capable-M-provider target + crypto-token subsidy

Run as: `omc ask codex "$(cat specs/RESEARCH_224_PRICING_V2_PROMPT.md)"`

This is a strategy research prompt, not a code-audit prompt. Single
codex call. Output is a recommendation memo + ready-to-commit
DECISION_CRITERIA entry.

This is the **v2** of Issue #222 pricing research. The v1 memo
(`.omc/artifacts/ask/codex-research-prompt-issue-222-beta-campaign-pricing-decision-run-2026-06-30T05-03-00-134Z.md`)
anchored to provider USD $/hr and produced a 36×-over-market buyer
price ($10/M completion). Operator rejected v1 in conversation; v2
is the re-scoped question.

Pair-track of [RESEARCH_223_MLX_THROUGHPUT_ROADMAP_PROMPT.md] — if
that memo lands first, use its 6-12 month tok/s targets as Part 1
input; otherwise use the conservative defaults in Background below.

---

## What changed since v1

Three constraints lock in. The decision must satisfy all three:

**Constraint 1 — Buyer USD price must be competitive vs OpenRouter for
comparable model class.** Cheapest comparable Qwen3-32B is **$0.28/M
completion** on OpenRouter/DeepInfra. Beta target: **undercut by
10-30%** to recruit buyers who would otherwise default to OpenRouter.
Same logic for 7-8B class (cheapest is Groq Llama-3.1-8B at ~$0.04/M).
v1's $10/M is dead on arrival.

**Constraint 2 — Provider hardware tier deliberately narrows.** M4 Air
on Qwen-32B is structurally ~25× behind H100 on memory bandwidth and
cannot be made USD-viable via per-token price (a market-rate per-token
price × 14 tok/s × 1 stream produces pennies/hr — no multiplier closes
that gap without breaking buyer-side competitiveness). We **stop
targeting M4 Air for 32B-class jobs** and target the network at
M4 Max / M2 Ultra / M3 Ultra owners who already chose hardware capable
of competitive single-stream and concurrent throughput. M4 Air remains
listable but only for 7-8B class.

**Constraint 3 — Provider USD shortfall is paid in protocol tokens,
not USDC.** The gap between (buyer-competitive USD revenue ×
provider_share) and "what providers need to feel rewarded" is bridged
by issuing crypto tokens (governance / network-equity stake). USD
economics balance at electricity-plus; **token issuance carries the
bootstrap incentive**. This is how comparable networks (Helium, Akash,
Render, Bittensor, io.net) bootstrapped supply.

The decision must specify:
- (a) USD multiplier so buyer price lands at-or-below OpenRouter parity
- (b) per-tier token-issuance schedule that subsidizes providers
- (c) hardware-class filter / tier in coordinator config
- (d) beta cohort size and concrete re-trigger conditions

---

## Background — code state (verbatim, brief)

Same as v1; not repeating. Key locations:
- `phase4-coordinator/internal/config/config.go:543` `Rewards.GlobalMultiplier`
- `phase4-coordinator/internal/config/config.go:548-549` rate-card defaults
- `phase4-coordinator/internal/config/config.go:138` `UsdPerMillionCredits`
- Live operator config: `/opt/macprovider/coordinator.yaml` on Pearl VPS
- Credit arithmetic: SPEC-005 D3 (LOCKED — do not propose changes)
- Hot-reload via SIGHUP at `phase4-coordinator/cmd/coordinator/main.go:908`

**Hardware tier inference** (research before citing):
- Provider binary self-reports hardware via probe — search
  `phase3-binary/Sources/macprovider-cli/` for `HardwareProbe`,
  `sysctl hw.memsize`, `hw.l1icachesize`, or similar
- Coordinator currently does NOT filter or tier providers by hardware

**Conservative TPS assumptions** (use these if RESEARCH_223 hasn't
landed yet; refine if it has):
- M4 Air, 7-8B class: ~55 tok/s single-stream sustained
- M4 Max, 7-8B class: ~80 tok/s single, 2-3 concurrent
- M4 Max, 32B-4bit: ~25 tok/s single, 2 concurrent
- M2 Ultra, 32B-4bit: ~45 tok/s single, 3 concurrent
- M2 Ultra, 70B-4bit: ~18 tok/s single, 1-2 concurrent
- M3 Ultra, 32B-4bit: ~50 tok/s single, 3-4 concurrent
- M3 Ultra, 70B-4bit: ~22 tok/s single, 2 concurrent

**Crypto token context** (research from public-network analogues —
no protocol token issued today; this proposes the mechanism):
- Helium HNT (hotspot bandwidth bootstrap)
- Akash AKT (compute leasing)
- Render RNDR (GPU rendering)
- Bittensor TAO (ML inference subnets) — most architecturally
  comparable
- io.net IO (GPU compute)
- Aethir ATH (GPU cloud)

---

## What to produce

### Part 1 — Buyer-competitive USD anchor

Pull current per-token pricing for the cheapest comparable open-model
providers. **If RESEARCH_222 market table is <7 days old, cite it;
otherwise re-fetch.** Required rows:

- OpenRouter Qwen3-32B
- DeepInfra Qwen3-32B
- Together Qwen2.5-Coder-32B
- OpenRouter Qwen3-7B / Qwen2.5-7B
- Groq Llama-3.1-8B
- OpenRouter Llama-3.1-8B
- OpenRouter Llama-3.3-70B
- DeepInfra Llama-3.3-70B

Pick the **target USD price per 1M completion tokens** that macprovider
charges buyers, **per model class**, that undercuts cheapest market by
10-30%. Show targets in this table:

| Model class | Cheapest market $/M | Target macprovider $/M | Undercut % |
|---|---:|---:|---:|
| 7-8B | | | |
| 32B | | | |
| 70B | | | |

Back-derive the required coordinator config. Likely one of:
- Single `GlobalMultiplier` (all classes priced uniformly) — show value
- Per-rate-card-row multiplier (different price per model size) —
  requires SPEC delta; flag if needed

For each target, compute the resulting **provider USD $/hr** per
hardware tier at conservative TPS (Background). Build:

| Tier × Model class | TPS | Provider $/hr at target | Electricity $/hr | USD margin |
|---|---:|---:|---:|---:|
| M4 Air × 8B | | | | |
| M4 Max × 8B | | | | |
| M4 Max × 32B | | | | |
| M2 Ultra × 32B | | | | |
| M2 Ultra × 70B | | | | |
| M3 Ultra × 32B | | | | |
| M3 Ultra × 70B | | | | |

The whole point: USD margin should be ≥0 (covers electricity) but
won't approach $1/hr "B6 target." Token issuance closes that gap.

### Part 2 — Hardware-tier filter design

The coordinator must NOT silently accept M4 Air providers for 32B-class
jobs at this pricing. Specify:

**2.1 Tier definitions** (use memory bandwidth as the proxy):
- **Tier-S**: ≥700 GB/s — M2 Ultra, M3 Ultra
- **Tier-A**: 350-700 GB/s — M4 Max, M3 Max
- **Tier-B**: 200-350 GB/s — M4 Pro, M3 Pro
- **Tier-C**: <200 GB/s — M4 / M4 Air / M3 / M3 Air
- Adjust thresholds based on actual M-series specs research

**2.2 Per-tier model-class eligibility**:

| Tier | 7-8B | 32B | 70B |
|---|:-:|:-:|:-:|
| S | ✓ | ✓ | ✓ |
| A | ✓ | ✓ | ✗ |
| B | ✓ | ✗ | ✗ |
| C | ✓ | ✗ | ✗ |

**2.3 Coordinator enforcement point**: cite the exact admission-control
location in code (search for where the coordinator selects a provider
for an inbound request — likely in `phase4-coordinator/internal/`
under routing/admission/assignment). Specify the rejection error code
and message returned to providers attempting out-of-tier work.

**2.4 Provider onboarding UX**: portal copy explaining why their Air
can't take 32B traffic but is welcome for 8B.

**2.5 Telemetry**: what gets logged when a job is rejected for
hardware-tier mismatch (audit-log row schema).

**2.6 Concrete config schema** for `coordinator.yaml`:

```yaml
hardware_tiers:
  S:
    min_mem_bandwidth_gbps: 700
    eligible_model_max_params_b: 70
  A:
    min_mem_bandwidth_gbps: 350
    eligible_model_max_params_b: 32
  B:
    min_mem_bandwidth_gbps: 200
    eligible_model_max_params_b: 8
  C:
    min_mem_bandwidth_gbps: 0
    eligible_model_max_params_b: 8
```

(Adjust schema to fit current `coordinator.yaml` shape — match
existing key conventions.)

### Part 3 — Crypto-token issuance subsidy design

Research the comparable networks (Helium, Akash, Render, Bittensor,
io.net, Aethir) and report each one's:
- Initial supply, total supply cap
- Issuance schedule (decay curve, halving, target inflation)
- Work measurement (what counts as "work" for issuance)
- Per-tier weighting (does an H100 provider earn more tokens than an
  RTX 4090?)
- Vesting / cliff for early providers
- Buyer-side token role (governance only? required for purchase?
  burn-on-use? bonded fees?)
- Anti-sybil / anti-mercenary mechanisms
- 1-line lesson learned (what worked, what didn't)

Cite each protocol's whitepaper / docs URL + most recent
tokenomics-update date.

Then design **macprovider's beta issuance** with concrete numbers:

- **Total beta budget**: e.g., 1-3% of supply distributed over 6
  months — pick a defensible %
- **Per-hour-online floor**: incentive to stay connected and reachable
- **Per-token-served weight**: incentive to actually serve (not just
  idle)
- **Per-tier multiplier**: incentive to bring better hardware — e.g.,
  Tier-S × 4, Tier-A × 2, Tier-B × 1, Tier-C × 0.5
- **Benchmark-pass bonus**: incentive to pass SPEC-NETWORK-BENCHMARK
  thresholds (catch quietly-degraded providers)
- **Vesting schedule**: anti-mercenary — e.g., 90-day cliff, 12-month
  linear vest from the cliff
- **Beta cohort cap**: limit providers at N to make per-provider
  allocation meaningful (suggest a number based on token budget /
  per-provider allocation arithmetic)

Show expected **token-quantity earned per beta provider per hardware
tier** assuming median network conditions, and **dollar-equivalent
value** under three token-price scenarios: $0.10, $1.00, $10.00 per
token at TGE.

**Goal**: a Tier-A (M4 Max) provider earning electricity-plus USD
(~$0.10/hr) plus token issuance reaches **>$1/hr equivalent at
conservative token valuation, >$5/hr at moderate, >$25/hr at
optimistic**. Tier-S providers earn proportionally more (their
hardware is more valuable to the network).

### Part 4 — Composite recommendation

Pick concrete numbers across all three levers:

- `GlobalMultiplier`: __ (justify against Part 1 table)
- `UsdPerMillionCredits`: __ (recommend keep at 1.0 unless arithmetic
  forces otherwise)
- **Hardware-tier filter**: enable initially? phase in over N weeks?
  grandfather existing providers?
- **Token issuance**: total beta budget, per-hour, per-token, per-tier
  weight, vesting
- **Beta cohort size**: cap providers at N
- **Beta cohort duration**: how long does v2 pricing run before
  forced revisit (e.g., 90 days or first paying buyer)

Then a one-paragraph **operator pitch to providers** — the honest
plain-English message:

> "We're pricing the network to undercut OpenRouter on USD because
> that's what attracts paying buyers. Your USD earnings will be
> electricity-plus. We're issuing TOKEN_NAME to bridge the gap as a
> network-equity stake — early providers earn more than late
> entrants. Your hardware tier determines which jobs you can take and
> what multiplier your token issuance gets. If you bought an M4 Air
> hoping to earn $1/hr on 32B traffic, the honest answer is no — that
> cell isn't physically viable at market-competitive buyer pricing.
> If you bought an M-Ultra, this is the network for you."

### Part 5 — DECISION_CRITERIA.md entry (ready to commit)

Single numbered entry in established Entries 1-21 house style. Must
contain:
- **Decision**: USD multiplier + hardware-tier filter + token-issuance
  design (one-line each)
- **Why**: market table cell + Part 1 derivation + comparable-network
  precedent for token design
- **Effective**: when does new rate + tier filter + issuance go live
  (next deploy? next cohort?)
- **Re-trigger**: observable conditions that force revisit —
  - First paying buyer revenue > $X
  - Fleet sustained p50 TPS by tier crosses a target
  - Token price moves outside the planning band
  - Provider churn by tier exceeds Y%
  - Beta cohort duration elapses
- **Owner**: operator

### Part 6 — Implementation pointers

For each change, name file/line and whether it's hot-reloadable,
new code, contract deployment, or pure operator messaging:

- **USD multiplier**: hot-reload via SIGHUP at
  `phase4-coordinator/internal/config/config.go:543` and live config
- **Per-rate-card-row multiplier** (if Part 1 requires it): new SPEC
  delta to SPEC-005, estimate code touch
- **Hardware-tier filter**: new code — name the file in
  `phase4-coordinator/internal/` where admission-control happens, with
  rough complexity (~LOC estimate)
- **Token issuance — beta-phase mechanic**:
  - Option α: off-chain ledger that mints later at TGE (operator
    bookkeeping, no on-chain dependency, can launch immediately)
  - Option β: on-chain contract from day 1 (full transparency, higher
    eng cost, requires contract audit)
  - Recommend one + name the trade-off
- **Provider portal copy**: which page(s) need updating —
  portal.malibu.tech `pages/` or wherever; flag the tier-filter
  explanation page as new

Flag what's hot-reloadable, what needs a coordinator restart, what's
new code, what's contract deployment, what's pure operator messaging.

---

## Out of scope

- Specific token-contract Solidity / Move code (design only)
- Real USDC payout rails (separate work)
- MLX engineering throughput roadmap (RESEARCH_223)
- Refactoring SPEC-005 D3 credit arithmetic (LOCKED)
- Marketing strategy for buyer acquisition (network-side only)

## Output format

Markdown memo, **~500-900 lines**. Tables for Parts 1, 2, 3. Prose
for Part 4 including the operator pitch verbatim. Code block for
Part 5. Cite every market price and every analog-network parameter
with source URL + date pulled. Conservative > optimistic on token
valuation scenarios.
