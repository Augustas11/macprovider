# Issue #224 pricing v2: buyer-competitive USD, hardware-tier routing, and token subsidy

Date pulled: 2026-06-30  
Scope: strategy research memo, not a code audit  
Repo: `/Users/augstar/macprovider-poc`  
Related prior memo: `.omc/artifacts/ask/codex-research-prompt-issue-222-beta-campaign-pricing-decision-run-2026-06-30T05-03-00-134Z.md`

## Executive recommendation

The v1 answer should not be used. A provider-USD anchor produces buyer prices that are not competitive with OpenRouter, DeepInfra, Groq, or Together. The v2 answer is to anchor USD to buyer market price, restrict model size by hardware tier, and pay early-provider upside through a beta token-issuance ledger.

Concrete recommendation:

| Lever | Recommendation |
|---|---|
| Buyer USD pricing | Keep `global_multiplier: 1.0`, keep `usd_per_million_credits: 1.0`, and set model-specific completion credit rows to market-pegged values: 7-8B `$0.027/M`, 32B `$0.220/M`, 70B `$0.250/M`. |
| Billing config shape | Use existing exact-model `rewards.rate_card` rows immediately. Add class-level rate-card lookup later if the operator wants one row for all 8B/32B/70B aliases. |
| Hardware routing | Enable hardware-tier routing before 32B/70B paid traffic. Tier-C/B machines remain valid for 7-8B; Tier-A gets 32B; Tier-S gets 70B. Unknown hardware is Tier-C until verified. |
| Provider USD economics | Expect electricity-plus only. At market USD prices, provider USD is roughly `$0.005-$0.036/hr` at the conservative TPS assumptions in this prompt. |
| Token subsidy | Launch an off-chain beta ledger now, mint later at TGE. Use a 2.0% beta budget over six months, with a 120-provider cohort cap and tier-weighted emissions. |
| Beta duration | Run v2 for 90 days or until first meaningful paid-buyer signal, whichever comes first. Token accounting can continue for the six-month beta budget window, but pricing must be revisited earlier. |

The hardest constraint is the first one: buyers have live alternatives. A 32B buyer can currently buy Qwen3-32B completion on OpenRouter or DeepInfra at about `$0.28/M`. Pricing macprovider at `$10/M` asks the buyer to pay about 36x the market. The buyer will not do that during beta unless macprovider offers a different product, which this prompt explicitly does not assume.

## Evidence and assumptions

### Local code facts

The current coordinator reward math has three important properties:

- `phase4-coordinator/internal/config/config.go:543` defaults `Rewards.GlobalMultiplier` to `1.0`.
- `phase4-coordinator/internal/config/config.go:548-549` defaults the rate card to `500000` prompt credits/M and `1000000` completion credits/M.
- `phase4-coordinator/internal/config/config.go:138` defines `StatsRollup.UsdPerMillionCredits`, defaulting to `1.0`.
- `phase4-coordinator/internal/billing/formula.go` resolves a rate-card entry by exact model key, otherwise `default`.
- `phase4-coordinator/internal/billing/formula.go` calculates gross credits from token counts, rate-card credits, and global multiplier, then applies provider share.
- `phase4-coordinator/cmd/coordinator/main.go:908-913` reloads rewards/billing config on SIGHUP.
- Provider selection for buyer requests happens in `phase4-coordinator/internal/buyer/server.go:4227-4350`, mainly `selectProviderExcluding`.
- Provider admission/quota accounting is separate in `phase4-coordinator/internal/ws/admission.go`.

Provider hardware self-report exists but is not yet enough for routing:

- `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift` records chip string, RAM, OS version, and binary version through `MachineFingerprinter.sample()`.
- It reads `hw.memsize`, but does not currently report a normalized memory-bandwidth value.
- The coordinator currently does not filter or tier providers by hardware class.

### Missing pair-track input

No completed RESEARCH_223 throughput memo was found in `.omc/artifacts/ask/` at the time of this memo. I used the conservative TPS defaults from the prompt.

### Market-price source handling

The v1 market table was generated on 2026-06-30, so it is less than seven days old. I reused it where it already covered the requested rows and spot-checked OpenRouter live model pricing through the public model API. Groq's public pricing page is JavaScript-heavy; the v1 table and current public page should be rechecked one more time before a public pricing post, but Groq is not the cheapest row under the current 8B recommendation.

## Part 1 -- Buyer-competitive USD anchor

### Required market rows

All prices below are completion-token prices in USD per 1M tokens unless otherwise noted.

| Provider / model row | Prompt $/M | Completion $/M | Source | Date pulled | Note |
|---|---:|---:|---|---|---|
| OpenRouter Qwen3-32B | 0.080 | 0.280 | `https://openrouter.ai/api/v1/models` | 2026-06-30 | Live API row `qwen/qwen3-32b`. |
| DeepInfra Qwen3-32B | 0.080 | 0.280 | `https://deepinfra.com/Qwen/Qwen3-32B` | 2026-06-30 | Same price as v1 table. |
| Together Qwen2.5-Coder-32B | 0.800 | 0.800 | `https://www.together.ai/models/qwen-2-5-coder-32b-instruct` | 2026-06-30 | Not cheapest; useful upper bound for managed API. |
| OpenRouter Qwen2.5-7B | 0.040 | 0.100 | `https://openrouter.ai/api/v1/models` | 2026-06-30 | Qwen 7B is not the cheapest 7-8B anchor. |
| Groq Llama-3.1-8B Instant | 0.040-0.050 | 0.040-0.080 | `https://groq.com/pricing/` | 2026-06-30 | v1 table had `$0.04/M`; current public page should be checked before publishing. |
| OpenRouter Llama-3.1-8B Instruct | 0.020 | 0.030 | `https://openrouter.ai/api/v1/models` | 2026-06-30 | Cheapest observed 7-8B comparable row. |
| OpenRouter Llama-3.3-70B Instruct | 0.100 | 0.320 | `https://openrouter.ai/api/v1/models` | 2026-06-30 | Excludes free promotional route. |
| DeepInfra Llama-3.3-70B Turbo | 0.100 | 0.320 | `https://deepinfra.com/meta-llama/Llama-3.3-70B-Instruct-Turbo` | 2026-06-30 | Same as v1 table. |

### Target macprovider buyer prices

| Model class | Cheapest market $/M | Target macprovider $/M | Undercut % |
|---|---:|---:|---:|
| 7-8B | 0.030 | 0.027 | 10.0% |
| 32B | 0.280 | 0.220 | 21.4% |
| 70B | 0.320 | 0.250 | 21.9% |

The 7-8B target is intentionally anchored to the cheapest OpenRouter Llama 3.1 8B row. If the operator instead treats Groq's current or v1 row as the only comparable 8B benchmark, `$0.027/M` undercuts it by more than 30%. That is acceptable for buyer acquisition but should be called out as aggressive.

### Required coordinator config

The recommended operational config is:

```yaml
stats_rollup:
  usd_per_million_credits: 1.0

rewards:
  global_multiplier: 1.0
  provider_share: 0.90
  rate_card:
    default:
      prompt_credits_per_mtok: 18000
      completion_credits_per_mtok: 27000
    llama-3.1-8b:
      prompt_credits_per_mtok: 18000
      completion_credits_per_mtok: 27000
    qwen-2.5-7b:
      prompt_credits_per_mtok: 36000
      completion_credits_per_mtok: 27000
    qwen3-32b:
      prompt_credits_per_mtok: 64000
      completion_credits_per_mtok: 220000
    qwen-2.5-coder-32b:
      prompt_credits_per_mtok: 64000
      completion_credits_per_mtok: 220000
    llama-3.3-70b:
      prompt_credits_per_mtok: 80000
      completion_credits_per_mtok: 250000
```

Two caveats:

1. The code currently matches rate-card rows by exact model key. The live model IDs must match the coordinator's normalized model string exactly.
2. A class-level row such as `32b:` or `70b:` would be cleaner, but that requires a SPEC/code delta to classify the requested model before billing lookup.

### Why a single multiplier does not work

With the current default completion row of `1,000,000` credits/M and `usd_per_million_credits: 1.0`, a single `global_multiplier` maps directly to buyer completion price:

```text
buyer completion $/M = default completion credits/M / 1,000,000 * global_multiplier
                    = 1.0 * global_multiplier
```

One multiplier cannot be `$0.027`, `$0.220`, and `$0.250` at the same time. A single multiplier of `0.027` would make 32B and 70B too cheap relative to market and would further reduce provider USD. A single multiplier of `0.220` would price 7-8B at 7.3x the cheapest observed OpenRouter 8B row. Therefore the v2 pricing decision needs per-model or per-class rate-card rows.

### Provider USD/hr at target prices

Formula:

```text
provider_usd_per_hour = tps * 3600 / 1,000,000 * target_completion_usd_per_m * provider_share
```

Assumptions:

- Provider share: `0.90`
- Electricity: `$0.16/kWh`
- M4 Air active draw proxy: `15W` => `$0.0024/hr`
- M4 Max active draw proxy: `40W` => `$0.0064/hr`
- M2/M3 Ultra active draw proxy: `80W` => `$0.0128/hr`
- TPS values are the conservative defaults in the prompt.
- Table assumes full utilization. Lower utilization lowers USD revenue proportionally.

| Tier x Model class | TPS | Provider $/hr at target | Electricity $/hr | USD margin |
|---|---:|---:|---:|---:|
| M4 Air x 8B | 55 | 0.0048 | 0.0024 | 0.0024 |
| M4 Max x 8B | 80 | 0.0070 | 0.0064 | 0.0006 |
| M4 Max x 32B | 25 | 0.0178 | 0.0064 | 0.0114 |
| M2 Ultra x 32B | 45 | 0.0321 | 0.0128 | 0.0193 |
| M2 Ultra x 70B | 18 | 0.0146 | 0.0128 | 0.0018 |
| M3 Ultra x 32B | 50 | 0.0356 | 0.0128 | 0.0228 |
| M3 Ultra x 70B | 22 | 0.0178 | 0.0128 | 0.0050 |

This is the key v2 conclusion: USD can cover marginal electricity at full utilization, but it cannot deliver a psychologically meaningful `$1/hr` provider incentive without destroying buyer competitiveness. The bootstrap incentive must be token-denominated.

## Part 2 -- Hardware-tier filter design

### Hardware specs and tier thresholds

Apple's public specs support using memory bandwidth as the first routing proxy:

| Chip family | Public memory bandwidth | Recommended tier | Source |
|---|---:|---|---|
| M3 Ultra | 819 GB/s | S | Apple Mac Studio tech specs, 2026-06-30 |
| M2 Ultra | 800 GB/s | S | Apple M2 Ultra public specs, 2026-06-30 |
| M4 Max high bin | 546 GB/s | A | Apple M4 Pro/Max newsroom and tech specs, 2026-06-30 |
| M4 Max lower bin | 410 GB/s | A | Apple MacBook Pro tech specs, 2026-06-30 |
| M3 Max | up to 400 GB/s | A | Apple M3-family specs, 2026-06-30 |
| M4 Pro | 273 GB/s | B | Apple M4 Pro/Max newsroom and tech specs, 2026-06-30 |
| M3 Pro | 150 GB/s | B | Apple M3-family specs, 2026-06-30 |
| Base M4 / M4 Air | about 120 GB/s | C | Apple base M-series specs, 2026-06-30 |
| Base M3 / M3 Air | about 100 GB/s | C | Apple base M-series specs, 2026-06-30 |

I recommend adjusting the prompt's Tier-B lower bound from `200` to `150` GB/s so M3 Pro is not incorrectly pushed into Tier-C. That still keeps Air/base chips below the 32B line.

### Tier definitions

| Tier | Memory bandwidth proxy | Intended Macs | Eligible model max |
|---|---:|---|---:|
| S | `>=700 GB/s` | M2 Ultra, M3 Ultra | 70B |
| A | `>=350 GB/s` and `<700 GB/s` | M4 Max, M3 Max | 32B |
| B | `>=150 GB/s` and `<350 GB/s` | M4 Pro, M3 Pro | 8B |
| C | `<150 GB/s` or unknown | M4, M4 Air, M3, M3 Air, unknown | 8B |

### Per-tier model-class eligibility

| Tier | 7-8B | 32B | 70B |
|---|:-:|:-:|:-:|
| S | yes | yes | yes |
| A | yes | yes | no |
| B | yes | no | no |
| C | yes | no | no |

### Coordinator enforcement point

Primary enforcement belongs in buyer provider selection:

- `phase4-coordinator/internal/buyer/server.go:1313-1441` handles `/v1/chat/completions`.
- `phase4-coordinator/internal/buyer/server.go:1436` selects a provider.
- `phase4-coordinator/internal/buyer/server.go:4227-4350` implements `selectProviderExcluding`.
- `selectProviderExcluding` already filters candidates through request match, routing eligibility, context limits, tier-2 filters, quota, and preflight.

Add hardware eligibility as a shared helper in this selection path. It should run for both regular candidates and pinned provider paths, otherwise a hard-pinned provider could bypass the tier rule.

Recommended insertion point:

1. Resolve requested model class from model ID: 8B, 32B, 70B.
2. Resolve provider tier from reported bandwidth/chip/RAM.
3. Reject candidate before quota reservation and before preflight if `model_params_b > eligible_model_max_params_b`.

Recommended buyer error when no provider is available because all candidates were tier-ineligible:

```json
{
  "error": {
    "code": "hardware_tier_unavailable",
    "message": "No provider in an eligible hardware tier is available for model qwen3-32b; 32B-class traffic requires Tier-A or better."
  }
}
```

Recommended pinned-provider error:

```json
{
  "error": {
    "code": "hardware_tier_mismatch",
    "message": "Pinned provider hardware tier C is not eligible for qwen3-32b; 32B-class traffic requires Tier-A or better."
  }
}
```

Use HTTP `503` for normal no-capacity routing and HTTP `409` only if the buyer explicitly pins a known-ineligible provider. If the existing buyer error contract prefers one status for all route failures, keep the existing status and vary only the machine-readable error code.

### Provider onboarding UX

Portal copy:

> Your Mac is welcome on the network. We use memory bandwidth to decide which model sizes your machine can serve without creating slow or uneconomic jobs. MacBook Air and base M-series machines are routed to 7-8B traffic. 32B and 70B traffic is reserved for Max and Ultra chips because buyer pricing has to match OpenRouter-class market prices; an Air serving 32B would earn only pennies per hour and would hurt buyer latency. You still earn USD and beta tokens on eligible 8B work, and your tier can change automatically if you join from faster hardware.

### Telemetry

Log every tier decision where a candidate is rejected. Minimal audit row:

| Field | Meaning |
|---|---|
| `ts_utc` | Coordinator timestamp. |
| `event` | `hardware_tier_mismatch`. |
| `decision` | `reject_candidate` or `reject_pinned_provider`. |
| `request_id` | Buyer request ID. |
| `buyer_account_id` | Buyer/account if available. |
| `provider_id` | Provider stable ID. |
| `assigned_id` | Coordinator assigned provider ID if distinct. |
| `model` | Requested model string. |
| `model_class_params_b` | Parsed model class. |
| `provider_tier` | S/A/B/C/unknown. |
| `provider_mem_bandwidth_gbps` | Reported or inferred bandwidth. |
| `required_min_tier` | Minimum tier for the model class. |
| `eligible_model_max_params_b` | Provider tier max. |
| `route_pinned` | Boolean. |
| `reason` | `provider_tier_below_model_class`. |
| `config_hash` | Active config snapshot/hash. |

### Concrete config schema

This follows existing snake-case config style and makes unknown hardware safe by default:

```yaml
hardware_tiers:
  enabled: true
  bandwidth_source: provider_probe
  unknown_hardware_policy: tier_c
  reject_out_of_tier_models: true
  tiers:
    S:
      min_mem_bandwidth_gbps: 700
      eligible_model_max_params_b: 70
      token_multiplier: 4.0
    A:
      min_mem_bandwidth_gbps: 350
      eligible_model_max_params_b: 32
      token_multiplier: 2.0
    B:
      min_mem_bandwidth_gbps: 150
      eligible_model_max_params_b: 8
      token_multiplier: 1.0
    C:
      min_mem_bandwidth_gbps: 0
      eligible_model_max_params_b: 8
      token_multiplier: 0.5
```

If policy and token accounting should stay separated, move `token_multiplier` into a future `token_issuance.tier_multipliers` block. The duplicated tier names are acceptable during beta if tests assert they stay consistent.

## Part 3 -- Crypto-token issuance subsidy design

### Comparable networks

| Network | Supply and issuance | Work measurement | Tier weighting | Buyer token role | Anti-sybil / anti-mercenary | Lesson |
|---|---|---|---|---|---|---|
| Helium HNT | No premine; HIP-20 moved to a two-year halving schedule. Docs describe an initial maximum of 240M HNT adjusted to about 223M because year-1 issuance was below target. Net emissions can re-emit burned HNT within a cap. | Hotspot coverage, proof/coverage activity, and data transfer through subDAO mechanics. | Not a simple H100-vs-4090 hardware multiplier; location, radio class, coverage, data transfer, and subDAO rules matter. | Data Credits are USD-pegged utility credits created by burning HNT and used for network fees/data. | Location assertions, PoC mechanics, denylist/quality controls, validator/staking systems. | Usage-linked burn is valuable, but oversupplied low-quality coverage can dilute provider earnings. |
| Akash AKT | Genesis supply commonly documented as 100M AKT with a max around 388.5M; inflation/block rewards are governed network parameters and recent governance has moved toward BME-style economics. | Compute leases in an open marketplace. | No protocol-level GPU-tier multiplier; providers earn through market-clearing lease prices and resource specs. | AKT secures the PoS chain, governs parameters, and supports marketplace economics; buyers can interact through cloud-market flows. | Provider deposits/certificates, marketplace reputation, on-chain leases, governance-controlled parameters. | Marketplace pricing avoids fake subsidy precision, but idle supply alone is not enough; real demand must clear leases. |
| Render RENDER | Render migrated from RNDR to Solana RENDER and implemented Burn-Mint Equilibrium. Users burn RENDER for Render Credits; node operators receive emissions for fulfilled GPU work. | Completed rendering / GPU compute jobs and node operator reward accounting. | Better hardware earns through work capacity, benchmarks, reputation, and job completion, not only raw ownership. | Users burn RENDER into USD-valued work credits; RENDER is also the network token for emissions. | Node reputation, job validation, operator accounting, BME emissions governance. | Burn-mint links buyer usage to token demand; provider rewards still need work validation and reputation. |
| Bittensor TAO | Max supply 21M TAO. Emissions follow Bitcoin-like halvings; current docs describe supply-threshold halving and about 3,600 TAO/day after the first halving. | Subnet-specific miner outputs scored by validators; subnet owners define incentive logic. | No fixed hardware-tier schedule. Faster hardware earns more only if it produces higher-scored outputs. | TAO is used for staking, governance, subnet registration/economics; end-user purchase role depends on subnet. | Stake, registration cost/burn/recycling, validator scoring, subnet-specific rules. | Performance-scored emissions are powerful, but incentive design is complex and gameable. |
| io.net IO | Official docs state 500M genesis IO supply growing to 800M over 20 years; newer tokenomics introduce demand/utilization-sensitive supply and burns. | GPU/CPU supply, cluster rentals, utilization, supplier payouts. | GPU class, reliability, utilization, and supplier status influence earnings. | IO participates in network payments, staking, rewards, governance/economics; newer IDE ties economics to utilization. | Device verification, worker scoring, KYC/compliance surfaces, utilization-based controls. | Fixed emissions bootstrap supply, but utilization-aware emissions are needed to avoid paying idle or fake capacity forever. |
| Aethir ATH | Official docs state total supply of 42B ATH. Rewards include checker node and compute rewards on Arbitrum. Checker bonus pool is documented as 5% of total supply over four years. | Checker node validation and compute-provider work. | Compute class and successful SLA/job fulfillment matter; checker nodes are a separate verification role. | ATH supports rewards, staking/governance/economics for the compute network. | Checker nodes, uptime requirements, reward vesting/claim windows, staking/reputation. | A separate checker/verifier role helps when provider performance claims are hard to trust. |

Sources used for the analog table:

- Helium: `https://docs.helium.com/tokens/hnt-token/`, pulled 2026-06-30.
- Akash: `https://akash.network/token/` and `https://akash.network/blog/an-evolution-of-akash-network-token-economics/`, pulled 2026-06-30.
- Render: `https://know.rendernetwork.com/basics/the-render-spl-token`, `https://know.rendernetwork.com/basics/burn-mint-equilibrium`, and `https://stats.renderfoundation.com/`, pulled 2026-06-30.
- Bittensor: `https://docs.learnbittensor.org/concepts/halving` and `https://docs.taostats.io/docs/tokenomics`, pulled 2026-06-30.
- io.net: `https://io.net/docs/guides/coin/io-coin-allocation` and `https://io.net/tokenomics`, pulled 2026-06-30.
- Aethir: `https://docs.aethir.com/aethir-tokenomics/token-overview`, `https://docs.aethir.com/aethir-tokenomics`, and `https://docs.aethir.com/checker-guide/what-is-the-checker-node/how-do-checker-nodes-work`, pulled 2026-06-30.

### Macprovider beta token design

Token placeholder: `TOKEN_NAME` in provider-facing copy; `MPROV` below for arithmetic only.

Supply assumption:

- Define planning supply as `1,000,000,000 MPROV`.
- Reserve `2.0%` for beta provider issuance over six months: `20,000,000 MPROV`.
- Do not promise that all beta budget emits. Emit only for verified online time, served tokens, and benchmark passes.

Recommended beta cohort:

| Tier | Cohort cap | Rationale |
|---|---:|---|
| S | 20 | Ultra hardware is scarce and most valuable for 70B. |
| A | 50 | M4/M3 Max is the main 32B beta target. |
| B | 30 | Useful 8B supply, but not strategic for 32B/70B. |
| C | 20 | Keep Air/base users included without overpaying non-strategic hardware. |
| Total | 120 | Keeps per-provider allocation meaningful under a 20M-token beta reserve. |

Emission components:

| Component | Formula | Purpose |
|---|---|---|
| Online floor | `4 base MPROV/hour online * tier_multiplier` | Keeps providers connected and reachable. |
| Served-token reward | `50 base MPROV / 1M accepted completion-token-equivalent * tier_multiplier` | Rewards actual useful work, not idle capacity. |
| Benchmark-pass bonus | `2,500 base MPROV * tier_multiplier` per quarterly benchmark pass | Catches degraded machines and rewards verified capability. |
| Tier multiplier | S `4.0`, A `2.0`, B `1.0`, C `0.5` | Makes scarce hardware meaningfully more valuable. |
| Vesting | 90-day cliff, then 12-month linear vest; forfeiture for fraud/sybil/quality violations | Reduces mercenary farming and early exit. |

Anti-sybil and quality gates:

- Stable provider identity.
- Hardware fingerprint from chip, RAM, OS, binary version, and future bandwidth/benchmark receipts.
- Reachability checks for online-hour credit.
- Served-token credit only for accepted, non-faulted, latency-bounded completions.
- One human/operator cohort account per beta provider unless manually approved.
- Household/IP/device-review caps during beta.
- Benchmark receipts signed by coordinator or reproducible challenge runner.
- Manual review for tier jumps, suspicious uptime, or repeated benchmark-only participation.

Buyer-side token role:

- Beta buyers should not need the token.
- Keep USD/credits as the buyer acquisition path.
- Treat `TOKEN_NAME` as governance/network-equity and future fee/burn/stake optionality.
- Defer burn-on-use until there is real buyer demand and a token contract.

### Expected token earnings per provider

Median beta assumptions:

- Six-month window: `180` days.
- Calendar hours: `4,320`.
- Verified online rate: `80%`, or `3,456` hours.
- Tier-C active utilization: `20%` of online hours at `55 TPS`.
- Tier-B active utilization: `20%` of online hours at `65 TPS`.
- Tier-A active utilization: `20%` of online hours at `25 TPS` on 32B.
- Tier-S active utilization: `25%` of online hours at `50 TPS` on 32B/70B mix.
- Two quarterly benchmark passes.

| Tier | Median served tokens | Online-floor MPROV | Served-token MPROV | Benchmark MPROV | Total MPROV / provider | MPROV/hr calendar |
|---|---:|---:|---:|---:|---:|---:|
| C | 136.9M | 6,912 | 3,421 | 2,500 | 12,833 | 2.97 |
| B | 161.7M | 13,824 | 8,087 | 5,000 | 26,911 | 6.23 |
| A | 62.2M | 27,648 | 6,221 | 10,000 | 43,869 | 10.15 |
| S | 155.5M | 55,296 | 31,104 | 20,000 | 106,400 | 24.63 |

Dollar-equivalent planning scenarios:

| Tier | Tokens/provider | At $0.10 | At $1.00 | At $10.00 | Equivalent $/hr at $0.10 | Equivalent $/hr at $1.00 | Equivalent $/hr at $10.00 |
|---|---:|---:|---:|---:|---:|---:|---:|
| C | 12,833 | 1,283 | 12,833 | 128,330 | 0.30 | 2.97 | 29.71 |
| B | 26,911 | 2,691 | 26,911 | 269,110 | 0.62 | 6.23 | 62.29 |
| A | 43,869 | 4,387 | 43,869 | 438,690 | 1.02 | 10.15 | 101.55 |
| S | 106,400 | 10,640 | 106,400 | 1,064,000 | 2.46 | 24.63 | 246.30 |

The Tier-A target is satisfied: an M4 Max provider earns electricity-plus USD and more than `$1/hr` equivalent at a conservative `$0.10` token planning price. The `$1` and `$10` scenarios are materially higher than the prompt's moderate/optimistic thresholds.

Cohort budget check:

| Tier | Cohort count | MPROV/provider | Cohort MPROV |
|---|---:|---:|---:|
| S | 20 | 106,400 | 2,128,000 |
| A | 50 | 43,869 | 2,193,450 |
| B | 30 | 26,911 | 807,330 |
| C | 20 | 12,833 | 256,660 |
| Total | 120 | -- | 5,385,440 |

This leaves most of the 20M beta reserve unspent for retention bonuses, additional benchmark rounds, demand spikes, manual grants to high-quality providers, or a second cohort. The budget should remain capped; unused tokens should not auto-distribute just because the reserve exists.

## Part 4 -- Composite recommendation

### Concrete numbers

| Item | Decision |
|---|---|
| `GlobalMultiplier` | `1.0` |
| `UsdPerMillionCredits` | `1.0` |
| Completion price, 7-8B | `$0.027/M` through rate-card rows |
| Completion price, 32B | `$0.220/M` through rate-card rows |
| Completion price, 70B | `$0.250/M` through rate-card rows |
| Provider share | Keep `0.90` for beta |
| Hardware-tier filter | Enable for all 32B/70B traffic before paid buyer traffic; unknown hardware is Tier-C |
| Existing providers | Grandfather only into eligible model classes; no Air/base grandfathering for 32B |
| Token budget | `2.0%` of planning supply over six months, capped at `20,000,000` if supply is 1B |
| Token ledger | Off-chain ledger now, mint later at TGE |
| Online floor | `4 base MPROV/hour online * tier multiplier` |
| Served-token reward | `50 base MPROV / 1M accepted completion-token-equivalent * tier multiplier` |
| Benchmark bonus | `2,500 base MPROV * tier multiplier` per quarterly pass |
| Tier multipliers | S `4.0`, A `2.0`, B `1.0`, C `0.5` |
| Vesting | 90-day cliff, then 12-month linear vest |
| Cohort size | 120 providers: 20 S, 50 A, 30 B, 20 C |
| Pricing revisit | 90 days, first `$500` paid buyer gross revenue, or 50M paid completion tokens, whichever comes first |

### Rollout

1. Immediately set buyer USD prices through exact-model rate-card rows in the live coordinator config and SIGHUP the coordinator.
2. Ship hardware-tier telemetry first if implementation risk is high, but hard-enforce out-of-tier routing before any 32B/70B paid buyer campaign.
3. Start the off-chain token ledger with the next beta cohort, not retroactively for all historical uptime unless the operator manually grants a one-time genesis credit.
4. Publish the provider-facing tier explanation before enforcing the filter, so M4 Air users understand why they are not receiving 32B traffic.

### Operator pitch to providers

> We're pricing the network to undercut OpenRouter on USD because that's what attracts paying buyers. Your USD earnings will be electricity-plus. We're issuing TOKEN_NAME to bridge the gap as a network-equity stake -- early providers earn more than late entrants. Your hardware tier determines which jobs you can take and what multiplier your token issuance gets. If you bought an M4 Air hoping to earn $1/hr on 32B traffic, the honest answer is no -- that cell isn't physically viable at market-competitive buyer pricing. If you bought an M-Ultra, this is the network for you.

## Part 5 -- DECISION_CRITERIA.md entry

Ready-to-commit entry for `beta/DECISION_CRITERIA.md`:

```markdown
| 2026-06-30 | **Entry 93 -- Issue #224 beta pricing v2: buyer USD price pegs to OpenRouter-class market and provider upside moves to TOKEN_NAME.** The v1 provider-USD anchor would have priced 32B completion around `$10/M`, roughly 36x the observed OpenRouter/DeepInfra Qwen3-32B completion market row of `$0.28/M`. The v2 market check instead pegs buyer USD to competitive completion prices: 7-8B `$0.027/M`, 32B `$0.220/M`, and 70B `$0.250/M`, each at or below comparable OpenRouter/DeepInfra/Groq/Together rows. At those prices, conservative Mac TPS produces only electricity-plus provider USD, so early-provider upside must come from protocol-token issuance rather than USDC subsidy. | **Decision:** keep `rewards.global_multiplier: 1.0`, keep `stats_rollup.usd_per_million_credits: 1.0`, and set exact-model rate-card rows to 7-8B `$0.027/M`, 32B `$0.220/M`, and 70B `$0.250/M` completion equivalents. Add hardware-tier routing before paid 32B/70B traffic: Tier-S `>=700 GB/s` can serve 70B, Tier-A `>=350 GB/s` can serve 32B, Tier-B `>=150 GB/s` can serve 8B, and Tier-C/unknown can serve 8B only. Launch an off-chain beta TOKEN_NAME ledger with a 2.0% six-month beta reserve, 120-provider cohort cap, online floor of `4` base tokens/hour, served-token reward of `50` base tokens per 1M accepted completion-token-equivalent, quarterly benchmark bonus of `2,500` base tokens, tier multipliers S `4.0`, A `2.0`, B `1.0`, C `0.5`, and 90-day cliff plus 12-month linear vesting. **Why:** buyer demand requires OpenRouter-class USD pricing; provider-USD math at that price only covers marginal electricity; Helium, Render, Bittensor, io.net, Aethir, and Akash show that DePIN supply bootstrapping uses tokenized network upside plus work/quality gates rather than overcharging buyers. **Effective:** rate-card update is hot-reloadable on the next coordinator config deploy/SIGHUP; hardware-tier filtering ships in the next coordinator release and must hard-reject out-of-tier 32B/70B routing before paid buyer traffic; token accounting starts with the next beta cohort through an operator ledger and can mint at TGE. **Re-trigger:** revisit on first paying buyer gross revenue above `$500`, first 50M paid completion tokens, fleet sustained p50 crossing Tier-A 32B `>=40 tok/s` or Tier-S 70B `>=30 tok/s` for seven days, TOKEN_NAME planning price outside `$0.10-$10.00` for 30 days after a reliable market mark, Tier-A/S monthly provider churn above `15%`, all-tier monthly churn above `25%`, cohort cap of 120 providers reached, or 90 calendar days elapsed. **Owner:** operator. | **Phase 5 / network implication:** billing remains buyer-competitive, routing stops assigning physically uneconomic model classes to Air/base hardware, and provider acquisition messaging shifts from guaranteed USDC yield to electricity-plus USD plus vested network-equity upside. |
```

## Part 6 -- Implementation pointers

### USD multiplier and rate card

| Change | File / line | Hot-reloadable? | Work type |
|---|---|---|---|
| Keep `GlobalMultiplier` at `1.0` | `phase4-coordinator/internal/config/config.go:543` default; live `/opt/macprovider/coordinator.yaml` | Yes, rewards config reloads on SIGHUP through `cmd/coordinator/main.go:908-913` | Operator config |
| Set exact-model rate-card rows | `phase4-coordinator/internal/config/config.go:548-549` defaults; live config under `rewards.rate_card` | Yes, through reward/billing reload on SIGHUP | Operator config |
| Keep `UsdPerMillionCredits` at `1.0` | `phase4-coordinator/internal/config/config.go:138` and default around `571` | Do not rely on hot reload; leave unchanged | Operator config |
| Per-class rate-card rows | `phase4-coordinator/internal/billing/formula.go` currently exact model -> default | No; new code and SPEC delta | SPEC/code |

Exact-model rows are the fastest safe path. Per-class rows are cleaner but require code to parse model class before rate lookup and tests to prove no default-rate fallback accidentally overprices or underprices traffic.

### Hardware-tier filter

| Change | File / location | Restart? | Rough complexity |
|---|---|---|---:|
| Add config structs/defaults/validation | `phase4-coordinator/internal/config/config.go` | Coordinator restart or SIGHUP if wired into reload snapshot | 80-120 LOC |
| Persist/report hardware tier fields | `phase4-coordinator/internal/pool/provider.go`, WS provider registration/status structs | Coordinator restart and provider binary update if adding probe fields | 80-150 LOC |
| Enforce route eligibility | `phase4-coordinator/internal/buyer/server.go:4227-4350` | Coordinator restart | 80-150 LOC plus tests |
| Prevent pinned-provider bypass | Same buyer selection path and pinned-provider validation helpers | Coordinator restart | Included above |
| Add provider probe bandwidth mapping | `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift` | Provider binary release | 80-120 LOC |
| Add audit logs/metrics | Buyer selection path plus existing logger/metrics packages | Coordinator restart | 50-100 LOC |

Total estimate: 350-600 LOC with unit tests and routing tests.

### Token issuance beta mechanic

| Option | Description | Pros | Cons | Recommendation |
|---|---|---|---|---|
| Option alpha | Off-chain ledger; mint later at TGE | Launches immediately; no audited contract dependency; easy to revise before token exists | Requires operator trust and careful export/audit trail | Recommended |
| Option beta | On-chain contract from day 1 | Transparent and composable | Premature engineering cost; contract audit; hard to revise while economics are still beta | Do not use for this beta |

Implementation sketch for option alpha:

- Append-only CSV/SQLite/Postgres ledger keyed by provider ID, day, tier, online hours, accepted completion-token-equivalent, benchmark pass, multiplier, gross token amount, vesting status.
- Daily export to signed artifact.
- Monthly operator review for anomalies.
- TGE conversion script later maps vested/unvested ledger balances to token allocations.

### Provider portal copy

Search/update the provider portal pages that describe:

- How provider earnings are calculated.
- Which models a Mac can serve.
- Beta token rewards.
- Hardware eligibility / tier explanation.

The prompt names `portal.malibu.tech`; if that portal source is outside this repo, this is pure operator messaging rather than a repo change. If it is in-repo, update the relevant `pages/` route and add a new hardware-tier explanation page.

### What is hot-reloadable vs new code

| Item | Classification |
|---|---|
| `rewards.global_multiplier` live value | Hot-reloadable through SIGHUP |
| Exact-model `rewards.rate_card` values | Hot-reloadable through SIGHUP |
| `stats_rollup.usd_per_million_credits` | Leave unchanged; not needed for this decision |
| Per-class billing lookup | New code + SPEC delta |
| Hardware-tier config | New code |
| Hardware-tier enforcement | New coordinator code |
| Provider memory-bandwidth probe | New provider-binary code |
| Token ledger | New operator bookkeeping or small service; no chain dependency |
| On-chain token issuance | Contract deployment; explicitly out of scope for beta launch |
| Provider pitch / tier explanation | Pure operator messaging unless portal source is in repo |

## Stop condition

The v2 decision is ready when:

- Buyer USD target table is accepted.
- Live config uses exact-model rate-card rows or a SPEC delta is opened for class rows.
- Hardware-tier routing is scheduled before paid 32B/70B buyer traffic.
- Off-chain token ledger policy is approved before onboarding the next provider cohort.
- `beta/DECISION_CRITERIA.md` receives Entry 93 or the operator chooses a different entry number.

