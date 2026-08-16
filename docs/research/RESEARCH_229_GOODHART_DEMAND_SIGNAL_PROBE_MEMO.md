<!-- Preface added during commit (the codex probe was fired before operator caught SPEC-018 was already taken by SPEC-018-agentic-tool-calling). All references to "SPEC-018" in this memo should be read as "SPEC-023 — Installer-Integrated Autotune Recommend." The codex output is preserved verbatim below for audit-trail integrity. -->

# SPEC-018 v0.1 Goodhart Probe Memo

Read-only probe. No code or spec files modified. Local context used: [CLAUDE.md](/Users/augstar/macprovider-poc/CLAUDE.md:1), [RESEARCH_229 prompt](/Users/augstar/macprovider-poc/specs/RESEARCH_229_GOODHART_DEMAND_SIGNAL_PROBE_PROMPT.md:1), Entry 92/93/94 in [beta/DECISION_CRITERIA.md](/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md:394), and supporting rate-card research in [RESEARCH_226](/Users/augstar/macprovider-poc/specs/RESEARCH_226_MOE_SELECTION_AND_MARKET_DEMAND_MEMO.md:1) / [RESEARCH_227](/Users/augstar/macprovider-poc/specs/RESEARCH_227_RATE_CARD_V3_MEMO.md:1).

## Part 1 — Failure-Mode Catalog

### FM-1 — Winner-Take-All Herding On Rank

| Field | Assessment |
|---|---|
| Scenario | 50 Tier-A providers install in the same launch week. If `demand_signal` strongly favors OpenRouter rank, all 50 see `gpt-oss-20b` as the highest expected `$/hr`: on M5-class data, `gpt-oss-20b` is ~35-37 tok/s at `$0.100/M`; qwen3-coder is also strong, but if rank weight dominates, the recommendation collapses to one row. |
| What formula does wrong | It treats each provider’s recommendation as independent, but the network outcome is coupled. The 50th `gpt-oss-20b` provider adds much less buyer coverage than the first provider on Qwen3-Coder, Llama, or another eligible SKU. |
| Corrupted intent | “Recommend the model that earns this provider most” becomes “herd the fleet into yesterday’s single highest public demand row,” which destroys catalog coverage. |
| Severity | **Network-killing** if unmitigated for buyer-visible SKUs: buyer requests for uncovered models return `503 no provider`. |
| Goodhart analogue | PageRank made “importance” measurable, then SEO optimized links around the measure rather than page quality. Here, rank becomes the target instead of buyer availability. |

### FM-2 — Cold-Start Exclusion For New Rows

| Field | Assessment |
|---|---|
| Scenario | A new deployable row lands, e.g. `deepseek-v3-distill` or a new qwen coder variant. If `demand_signal = last_7d_macprovider_requests`, the row starts at zero. Recommendation score is zero even if TPS and price are excellent. No provider installs it, so no buyer can use it, so demand remains zero. |
| What formula does wrong | It confuses “not yet served by macprovider” with “not demanded by buyers.” |
| Corrupted intent | Demand signal should estimate latent buyer demand; historical served traffic instead measures the current fleet’s past ability to serve. |
| Severity | **Network-degrading** for optional rows; **network-killing** if new rows are required for market relevance. |
| Goodhart analogue | Recommender systems that only show historically high-click items suppress new items; the metric becomes self-fulfilling exposure, not true preference. |

### FM-3 — TPS Gaming / Benchmark Overfit

| Field | Assessment |
|---|---|
| Scenario | Providers learn the autotune probe shape: short prompts, fixed max tokens, cool machine, no concurrent load. They run install in ideal conditions, close other apps, or patch local CLI output. A model appears to be 60 tok/s during install but later serves at 25 tok/s under heat, memory pressure, or real prompts. |
| What formula does wrong | It assumes local measured TPS is stable, honest, and representative of production. The current design avoids simple self-reported TPS, which closes the easiest attack, but not all gaming. |
| Corrupted intent | TPS should represent buyer-observed sustained throughput; install-time TPS can become a benchmark target. |
| Severity | **Network-degrading**. It misroutes providers into fragile lanes and causes lower real `$/hr`, timeouts, and churn. |
| Goodhart analogue | BLEU-score optimization in machine translation improved metric scores without always improving human-perceived translation quality. A fixed autotune fixture can similarly become the target. |

### FM-4 — Rate-Card Update Lag / Stale Recommendation

| Field | Assessment |
|---|---|
| Scenario | Pearl hot-reloads a rate card: qwen3-coder drops from `$0.235/M` to `$0.160/M`, or a new row becomes best. 50 installed providers keep serving the install-time recommended model. Their projected earnings change, but they do not retune. |
| What formula does wrong | It optimizes at install time, but the inputs are not all install-time constants. Price and demand can change faster than providers naturally reinstall. |
| Corrupted intent | “Expected $/hr” becomes a stale promise. Providers experience unexpected earnings decay and may churn before re-running autotune. |
| Severity | **Network-degrading**; can become network-killing if stale supply remains on deprecated rows while buyers move. |
| Local context | Entry 92 says price-setting goes through exact rate-card rows hot-reloadable by SIGHUP; Wave 0c install recommendation must survive that reality. |

### FM-5 — Demand-Signal Source Mismatch

| Field | Assessment |
|---|---|
| Scenario | OpenRouter rank says `gpt-oss-20b` and Gemma are high-volume. macprovider’s first paying buyers are coding agents requesting qwen3-coder and qwen2.5-coder. The installer keeps recommending general chat rows because public market rank is not macprovider’s actual buyer mix. |
| What formula does wrong | It imports a global market proxy as if it were local demand. Conversely, coord stats are locally relevant but bootstrap at zero and are supply-constrained. |
| Corrupted intent | Demand signal should estimate “probability this provider will receive paid work on this model.” Neither global rank nor local served traffic directly equals that during beta. |
| Severity | **Network-degrading**. Wrong mix means low utilization even when individual model economics look good. |
| Goodhart analogue | Ad platforms optimize for click-through rate even when advertisers care about conversion. Proxy demand is not the same as local paid utilization. |

### FM-6 — Hardware Tier Tail Pathologies

| Field | Assessment |
|---|---|
| Scenario | Tier-S M4 Max/Ultra and Tier-C M1/M4 Air use the same formula. Tier-C sees a high `$/M` dense 32B row and barely passes a short probe, then serves painful TTFT or swaps. Tier-S gets steered to small-active MoE because rank×TPS wins, leaving 70B/dense capacity uncovered. |
| What formula does wrong | It multiplies throughput by price but does not encode model-class coverage value or tier-specific opportunity cost. |
| Corrupted intent | Each hardware tier should serve the models it is uniquely good at. A uniform argmax can waste scarce high-memory/high-bandwidth hosts and overburden low-tier machines. |
| Severity | **Network-degrading**, possibly **network-killing** for high-end rows if all Tier-S machines choose the same small-active MoE rows as Tier-C. |
| Local context | Entry 92 already pivots to per-model RAM-first admission and keeps dense 32B/70B bandwidth gates; the installer must mirror that, not merely score all rows uniformly. |

### FM-7 — Bid-Shading / Provider Coordination

| Field | Assessment |
|---|---|
| Scenario | A provider Discord coordinates: “Tier-S operators all pick qwen2.5-coder-32b, Tier-A pick qwen3-coder, Tier-C pick gpt-oss-20b.” They avoid competition or try to dominate scarce model lanes. |
| What formula does wrong | The formula assumes independent providers and no strategic response. Once recommendations are public and earnings visible, providers can coordinate around scarcity. |
| Corrupted intent | Recommendations should improve network coverage and provider earnings, not create cartel-like lane allocation. |
| Severity | **Cosmetic to network-degrading** in beta. With 120 providers and fixed rate card, the more realistic issue is herding, not cartel control. |
| Goodhart analogue | Mining pools and ASIC concentration: participants optimize around the reward function and centralize behavior even when the protocol intended decentralization. |

### FM-8 — Availability / Quality Blindness

| Field | Assessment |
|---|---|
| Scenario | A model has strong install-time TPS but poor real reliability: high TTFT on 4K prompts, unsupported tokenizer/accounting path, high swap risk, or frequent `stream_output_exceeded`. The formula still recommends it because TPS×price×rank is high. |
| What formula does wrong | It scores speed and price, but not “can this provider reliably serve paid buyer traffic end-to-end?” |
| Corrupted intent | Expected `$/hr` should be paid accepted work, not local decode speed. |
| Severity | **Network-killing** if it recommends rows that fail billing/accounting or runtime support; otherwise **network-degrading**. |
| Local context | Entry 93/94 found real new-row gateway/accounting issues and runtime blockers. SPEC-018 v0.1 must not recommend rows until deployability gates are green. |

### FM-9 — Supply-Constraint Feedback Loop In Coord Stats

| Field | Assessment |
|---|---|
| Scenario | `coordinator.malibu.tech/v1/demand-signal` counts served tokens by model. Models with many providers get more served tokens because they are available. Models with zero providers get zero served tokens even if buyers attempted them and got `503`. |
| What formula does wrong | It measures fulfilled supply, not attempted demand. |
| Corrupted intent | Demand signal should guide supply into missing demand. Served-token stats guide supply toward already-served rows. |
| Severity | **Network-degrading**; **network-killing** when it locks out uncovered models. |
| Goodhart analogue | Marketplace ranking based only on completed sales disadvantages listings that are never shown or are out of stock. |

### FM-10 — Projection Misinterpretation / Provider Churn

| Field | Assessment |
|---|---|
| Scenario | Installer prints “expected `$0.021/hr`” for qwen3-coder from TPS×rate×share, but actual utilization is 5-20%. Provider receives `$0.001-$0.004/hr` cash plus token subsidy. They perceive the recommendation as false advertising. |
| What formula does wrong | It computes full-utilization earning capacity, not expected realized earnings under fleet utilization and buyer volume. |
| Corrupted intent | Onboarding should set provider expectations and reduce churn. A precise-looking formula can overpromise. |
| Severity | **Network-degrading** via provider trust and retention. |
| Local context | Entry 92 explicitly says USD economics are electricity-plus and token subsidy carries beta provider incentive; SPEC-018 wording must preserve that honesty. |

**Part 1 conclusion:** The v0.1 risk is not one bad demand multiplier; it is turning a per-provider argmax into a fleet-wide coordination signal without coverage floors, cold-start priors, deployability gates, and stale-input handling.

## Part 2 — Mitigation Library

| ID | Failure modes | Mechanism | Where it lives | LOC | Adds UX / state / endpoints? | Downside | Bake into v0.1? |
|---|---|---|---|---:|---|---|---|
| M1 | FM-1, FM-6 | **Deterministic top-K diversification.** Instead of always selecting rank 1 score, compute eligible top 3 and choose default by stable hash of provider ID or machine fingerprint across the top band, e.g. choose among candidates within 85-90% of best score. | Formula / autotune logic | Small | No new endpoint; tiny install text may show “recommended” plus alternatives | Some providers get slightly lower projected capacity than pure argmax | **Yes** |
| M2 | FM-1, FM-2, FM-9 | **Minimum catalog coverage floor.** SPEC says every rate-card-eligible, deployable, buyer-visible model needs at least N healthy providers by tier class before demand weighting can suppress it. For beta, N can be small, e.g. 2-3 total and at least 1 non-low-tier where required. | Operator config / formula constants | Small | No new endpoint if encoded in static demand file or release config | Requires operator to maintain row status | **Yes, if static config only** |
| M3 | FM-2, FM-9 | **Cold-start prior / floor.** Clamp `demand_signal` to a nonzero floor for deployable rows, e.g. `max(raw_demand, 0.15)` or rank-prior fallback when local stats are empty. | Formula | Small | None | Can over-recommend speculative rows | **Yes** |
| M4 | FM-2, FM-5 | **Row lifecycle states: candidate / listed / recommended.** New rows are not automatically recommended; they graduate only after runtime, billing, and minimum bench gates pass. Candidate rows can appear as alternatives but not default. | Operator config consumed by install/autotune | Small-medium | No new endpoint if static JSON | Slows launch of hot models | **Yes** |
| M5 | FM-3 | **Benchmark anti-gaming guardrails.** Use CLI-owned local probe, not provider-entered TPS; require warmup + sustained window + TTFT cap + no-swap/thermal sanity. Store measured TPS locally with timestamp and candidate hash. | Autotune logic | Medium | No endpoint; no operator UX beyond progress text | Adds install time | **Yes if minimal; deeper attestation v0.2** |
| M6 | FM-3 | **Production feedback correction.** Coordinator later compares provider-observed request TPS against install TPS and downweights bad actors. | Coord stats / routing | Large | Adds network state and policy | Can punish providers for buyer prompt variance | **Defer v0.2** |
| M7 | FM-4 | **Rate-card version binding.** Recommendation records the rate-card/demand-file version used. Provider heartbeat or status can expose current model; install can warn on next run if config is stale. | Install.sh / autotune metadata | Small | Minimal local UX; no endpoint required | Does not auto-retune existing providers | **Yes** |
| M8 | FM-4 | **Retune hint on upgrade / model reload.** `macprovider upgrade` or install rerun fetches current demand/rate metadata and says “recommendation changed from X to Y.” | install.sh / CLI | Small | Operator-visible UX | Providers must act manually | **Yes** |
| M9 | FM-4 | **Coordinator push retune notices.** Broadcast “recommended model changed” to providers after hot reload. | Coord endpoint / provider protocol | Medium-large | Adds network state and provider UX | Scope creep for v0.1 | **Defer v0.2** |
| M10 | FM-5, FM-9 | **Hybrid demand signal with bootstrap source.** v0.1 uses static/live OpenRouter rank prior; v0.2 switches to blended local attempted-demand stats after sufficient history. | Demand JSON / formula | Small now, medium later | No v0.1 endpoint if static URL | Global rank mismatch remains | **Yes for v0.1 prior; defer local blend** |
| M11 | FM-5, FM-9 | **Track attempted demand, not just served tokens.** Count buyer requests by requested model, including `503 no provider`, auth-valid only. | Coord stats rollup | Medium-large | New coord stats surface or internal table | Abuse/spam filtering needed | **Defer v0.2** |
| M12 | FM-6 | **Hard eligibility gates before scoring.** Filter candidates by RAM, bandwidth tier, runtime support, benchmark pass, model admission, and billing deployability before applying score. | Autotune + operator config | Small-medium | None if silent; install can show only eligible rows | Risk of hiding rows operator expected | **Yes** |
| M13 | FM-6 | **Tier-specific opportunity-cost bonus.** Add small operator-set weights by tier: Tier-S may reserve some probability for high-end rows; Tier-C biased toward small-active MoE. | Formula config | Small | None | Hand-tuned and can become stale | **Maybe v0.1 only as static weights; otherwise defer** |
| M14 | FM-7 | **Do nothing special in v0.1; monitor concentration.** Collusion is lower-probability than herding. The diversification and coverage floors already reduce its effect. | Spec risk register | None | None | Does not detect cartel behavior | **Yes as explicit deferral** |
| M15 | FM-7 | **Per-provider quotas or lane caps.** Coordinator limits provider counts per model or assigns quotas. | Coord/network policy | Large | Adds network state and operator/admin surface | Heavy-handed; can reduce provider autonomy | **Defer v0.2+** |
| M16 | FM-8 | **Deployability gate is mandatory.** A row must be marked `recommendable: true` only after end-to-end request, gateway settlement, tokenizer/accounting, and runtime architecture support are green. | Operator config / demand JSON | Small | No new endpoint | Manual bookkeeping | **Yes** |
| M17 | FM-8 | **Quality-adjusted score factor.** Multiply by `quality_gate` or `reliability_score` from production errors and TTFT. | Coord stats / formula | Medium-large | Network state and possibly endpoint | Needs enough traffic; can feedback-loop | **Defer v0.2** |
| M18 | FM-10 | **Label projection as full-utilization capacity.** Installer must say “at 100% utilization” or “capacity, not guaranteed earnings,” and keep token subsidy messaging separate. | install.sh UX | Small | Operator-visible UX | Less exciting onboarding copy | **Yes** |
| M19 | FM-10 | **Utilization-adjusted expected earnings.** Use local buyer volume / fleet supply to estimate realized earnings. | Coord stats endpoint | Large | New endpoint/state | Bootstrap zero and noisy | **Defer v0.2** |
| M20 | FM-1, FM-4, FM-5 | **Static demand-rank JSON with version and row metadata.** Serve `get.malibu.tech/demand-rank.json` containing row weights, lifecycle state, min provider coverage, and generated timestamp. Installer fetches it with baked fallback. | Static URL + install/autotune | Small-medium | No coord endpoint; no new provider state | Static file can go stale; needs operator discipline | **Yes** |

### Recommended v0.1 Bake-In Set

| Mechanism | Why it belongs in v0.1 |
|---|---|
| M1 deterministic top-K diversification | Cheaply prevents pure argmax herding without a coordinator endpoint. |
| M3 cold-start floor | Prevents zero-demand permanent exclusion. |
| M4 row lifecycle states | Keeps speculative or broken rows out of default recommendations. |
| M7/M8 version binding + retune hint | Handles rate-card/demand-file drift without protocol changes. |
| M12 hard eligibility gates | Prevents impossible or tail-pathological recommendations. |
| M16 deployability gate | Critical after Entry 93/94: do not recommend rows until end-to-end billing/runtime is green. |
| M18 full-utilization wording | Prevents provider trust damage from overstated “expected $/hr.” |
| M20 static/live demand JSON | Gives operator a cheap control plane without waiting for coord stats. |

### v0.1 Formula Shape

Recommended v0.1 scoring should be closer to:

```text
eligible_rows = rows where:
  rate_card_enabled
  recommendable == true
  model_admission passes hardware
  local_autotune passes sustained TPS + TTFT + no-swap gates

raw_score =
  measured_tps
  * 3600
  * usd_per_million
  * provider_share
  * max(demand_weight, cold_start_floor)
  * optional_tier_weight

recommendation_pool =
  top eligible rows within 85-90% of best raw_score
  plus any coverage-floor row still under min_provider_target

default =
  stable_hash(provider_id_or_machine_fingerprint) across recommendation_pool
```

### v0.1 Non-Goals

| Deferred item | Reason |
|---|---|
| Live coord `/v1/demand-signal` endpoint | Bootstrap-zero and supply-feedback risks; adds new surface. |
| Provider quota/cap allocation | Too much market-design complexity for 120-provider beta. |
| Production TPS reputation downweighting | Needs traffic, prompt normalization, and anti-abuse design. |
| Utilization-adjusted earnings | Honest but data-poor before paying buyer history exists. |
| Collusion enforcement | Lower priority than accidental herding and coverage failure. |

**Part 2 conclusion:** SPEC-018 v0.1 should bake in cheap static controls: eligibility gates, deployability states, cold-start floors, top-K diversification, metadata versioning, and honest “capacity not guaranteed earnings” wording; defer live market allocation to v0.2.

## Part 3 — Recommended v0.1 Demand-Signal Source

### Ranking Of Options

| Rank | Option | Verdict |
|---:|---|---|
| 1 | **(b) OpenRouter top-50 rank fetched live from static URL** | Best v0.1 choice. It avoids binary-baked staleness, works before macprovider has buyer history, and gives the operator a safe, cheap control plane. |
| 2 | **(e) Hybrid: v0.1 OpenRouter prior, v0.2 local coord stats after 60+ days** | Correct lifecycle strategy. For v0.1 this reduces to option (b) plus an explicit migration trigger. |
| 3 | **(a) OpenRouter rank baked into binary** | Safe fallback if network fetch fails, but too stale for a fast-changing model market. Refresh only on `macprovider upgrade` is not enough. |
| 4 | **(d) Constant 1.0** | Simple and avoids rank herding, but price×TPS alone will over-select high-price/low-demand rows and ignore buyer market evidence. Useful as a fallback, not primary. |
| 5 | **(c) Coord last-7-day macprovider stats** | Locally relevant later, wrong for v0.1. With ~2 providers and zero paying history, it mostly measures bootstrap accidents and current supply gaps. |

### Recommended Source

Use **option (b)** for v0.1:

```text
Primary: get.malibu.tech/demand-rank.json
Fallback: baked demand-rank snapshot in the installer/CLI
Future: switch or blend with coord attempted-demand stats after 60+ days
```

The static JSON should not be just rank. It should carry enough operator-controlled metadata to avoid separate v0.1 surfaces:

```json
{
  "version": "2026-06-30.1",
  "generated_at": "2026-06-30T00:00:00Z",
  "source": "openrouter_completion_token_rank_operator_curated",
  "cold_start_floor": 0.15,
  "top_k_band": 0.90,
  "rows": {
    "openai/gpt-oss-20b": {
      "demand_weight": 1.00,
      "rank": 24,
      "recommendable": true,
      "min_provider_target": 8
    },
    "qwen/qwen3-coder-30b-a3b-instruct": {
      "demand_weight": 0.85,
      "rank": null,
      "recommendable": true,
      "min_provider_target": 6
    },
    "meta-llama/llama-3.1-8b-instruct": {
      "demand_weight": 0.55,
      "rank": 49,
      "recommendable": true,
      "min_provider_target": 3
    }
  }
}
```

### Why Not Coord Stats In v0.1

Coord stats are attractive because they reflect macprovider’s buyer mix, but v0.1 has three bootstrap defects:

1. **Zero history:** there is not enough paying buyer traffic to estimate demand.
2. **Supply censoring:** a model with no providers cannot accumulate served tokens.
3. **Launch coupling:** if install recommendations are driven by served traffic, early install randomness becomes permanent market structure.

If v0.2 uses coord stats, it should use **attempted demand**, not just served tokens:

```text
demand_signal_v0.2 =
  blend(
    OpenRouter prior,
    auth-valid buyer requested-model counts,
    no-provider 503 counts,
    served paid completion tokens
  )
```

Switch trigger should be explicit:

```text
Use local demand only after:
  >= 60 days history
  >= 50M paid or auth-valid requested completion-token equivalent
  >= 5 buyer accounts or partner keys with non-test traffic
  no single buyer contributes >50% of model demand
```

### Why Not Constant 1.0

Constant demand is better than bad local stats for cold start, but it turns the formula into price×TPS. That would likely over-recommend rows like high-priced coder/dense rows even where buyer demand is thin, and it removes the one signal that distinguishes “technically fast” from “marketable.” It should be a fallback when the static JSON cannot be fetched, not the primary source.

### Required v0.1 Safeguards With Option (b)

| Safeguard | Reason |
|---|---|
| Baked fallback snapshot | Installer must work offline or if `get.malibu.tech` fails. |
| JSON signature or checksum | Prevents accidental or tampered recommendation weights. |
| `recommendable` flag | Operator can block rows with runtime/billing/deployability failures. |
| Cold-start floor | Prevents permanent exclusion of new rows. |
| Top-K diversification band | Prevents all 120 providers choosing the same highest-weight row. |
| Version/timestamp display | Makes stale recommendation diagnosis possible. |
| No exact earnings guarantee | Demand rank is a utilization proxy, not a guarantee. |

**Part 3 conclusion:** For SPEC-018 v0.1, use operator-curated OpenRouter-prior demand weights fetched from `get.malibu.tech/demand-rank.json` with a baked fallback, then graduate to blended coord attempted-demand stats only after 60+ days of real buyer history.

## Part 4 — One-Line Conclusions

| Part | Liftable conclusion |
|---|---|
| Part 1 | The v0.1 risk is not one bad demand multiplier; it is turning a per-provider argmax into a fleet-wide coordination signal without coverage floors, cold-start priors, deployability gates, and stale-input handling. |
| Part 2 | SPEC-018 v0.1 should bake in cheap static controls: eligibility gates, deployability states, cold-start floors, top-K diversification, metadata versioning, and honest “capacity not guaranteed earnings” wording; defer live market allocation to v0.2. |
| Part 3 | For SPEC-018 v0.1, use operator-curated OpenRouter-prior demand weights fetched from `get.malibu.tech/demand-rank.json` with a baked fallback, then graduate to blended coord attempted-demand stats only after 60+ days of real buyer history. |
| Overall | Ship v0.1 as a conservative installer recommendation system, not an autonomous market maker: recommend only deployable eligible rows, diversify defaults, preserve cold-start, and keep live coord demand optimization for v0.2. |


OpenAI Codex v0.142.2
# SPEC-018 v0.1 Goodhart Probe Memo

Read-only probe. No code or spec files modified. Local context used: [CLAUDE.md](/Users/augstar/macprovider-poc/CLAUDE.md:1), [RESEARCH_229 prompt](/Users/augstar/macprovider-poc/specs/RESEARCH_229_GOODHART_DEMAND_SIGNAL_PROBE_PROMPT.md:1), Entry 92/93/94 in [beta/DECISION_CRITERIA.md](/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md:394), and supporting rate-card research in [RESEARCH_226](/Users/augstar/macprovider-poc/specs/RESEARCH_226_MOE_SELECTION_AND_MARKET_DEMAND_MEMO.md:1) / [RESEARCH_227](/Users/augstar/macprovider-poc/specs/RESEARCH_227_RATE_CARD_V3_MEMO.md:1).

## Part 1 — Failure-Mode Catalog

### FM-1 — Winner-Take-All Herding On Rank

| Field | Assessment |
|---|---|
| Scenario | 50 Tier-A providers install in the same launch week. If `demand_signal` strongly favors OpenRouter rank, all 50 see `gpt-oss-20b` as the highest expected `$/hr`: on M5-class data, `gpt-oss-20b` is ~35-37 tok/s at `$0.100/M`; qwen3-coder is also strong, but if rank weight dominates, the recommendation collapses to one row. |
| What formula does wrong | It treats each provider’s recommendation as independent, but the network outcome is coupled. The 50th `gpt-oss-20b` provider adds much less buyer coverage than the first provider on Qwen3-Coder, Llama, or another eligible SKU. |
| Corrupted intent | “Recommend the model that earns this provider most” becomes “herd the fleet into yesterday’s single highest public demand row,” which destroys catalog coverage. |
| Severity | **Network-killing** if unmitigated for buyer-visible SKUs: buyer requests for uncovered models return `503 no provider`. |
| Goodhart analogue | PageRank made “importance” measurable, then SEO optimized links around the measure rather than page quality. Here, rank becomes the target instead of buyer availability. |

### FM-2 — Cold-Start Exclusion For New Rows

| Field | Assessment |
|---|---|
| Scenario | A new deployable row lands, e.g. `deepseek-v3-distill` or a new qwen coder variant. If `demand_signal = last_7d_macprovider_requests`, the row starts at zero. Recommendation score is zero even if TPS and price are excellent. No provider installs it, so no buyer can use it, so demand remains zero. |
| What formula does wrong | It confuses “not yet served by macprovider” with “not demanded by buyers.” |
| Corrupted intent | Demand signal should estimate latent buyer demand; historical served traffic instead measures the current fleet’s past ability to serve. |
| Severity | **Network-degrading** for optional rows; **network-killing** if new rows are required for market relevance. |
| Goodhart analogue | Recommender systems that only show historically high-click items suppress new items; the metric becomes self-fulfilling exposure, not true preference. |

### FM-3 — TPS Gaming / Benchmark Overfit

| Field | Assessment |
|---|---|
| Scenario | Providers learn the autotune probe shape: short prompts, fixed max tokens, cool machine, no concurrent load. They run install in ideal conditions, close other apps, or patch local CLI output. A model appears to be 60 tok/s during install but later serves at 25 tok/s under heat, memory pressure, or real prompts. |
| What formula does wrong | It assumes local measured TPS is stable, honest, and representative of production. The current design avoids simple self-reported TPS, which closes the easiest attack, but not all gaming. |
| Corrupted intent | TPS should represent buyer-observed sustained throughput; install-time TPS can become a benchmark target. |
| Severity | **Network-degrading**. It misroutes providers into fragile lanes and causes lower real `$/hr`, timeouts, and churn. |
| Goodhart analogue | BLEU-score optimization in machine translation improved metric scores without always improving human-perceived translation quality. A fixed autotune fixture can similarly become the target. |

### FM-4 — Rate-Card Update Lag / Stale Recommendation

| Field | Assessment |
|---|---|
| Scenario | Pearl hot-reloads a rate card: qwen3-coder drops from `$0.235/M` to `$0.160/M`, or a new row becomes best. 50 installed providers keep serving the install-time recommended model. Their projected earnings change, but they do not retune. |
| What formula does wrong | It optimizes at install time, but the inputs are not all install-time constants. Price and demand can change faster than providers naturally reinstall. |
| Corrupted intent | “Expected $/hr” becomes a stale promise. Providers experience unexpected earnings decay and may churn before re-running autotune. |
| Severity | **Network-degrading**; can become network-killing if stale supply remains on deprecated rows while buyers move. |
| Local context | Entry 92 says price-setting goes through exact rate-card rows hot-reloadable by SIGHUP; Wave 0c install recommendation must survive that reality. |

### FM-5 — Demand-Signal Source Mismatch

| Field | Assessment |
|---|---|
| Scenario | OpenRouter rank says `gpt-oss-20b` and Gemma are high-volume. macprovider’s first paying buyers are coding agents requesting qwen3-coder and qwen2.5-coder. The installer keeps recommending general chat rows because public market rank is not macprovider’s actual buyer mix. |
| What formula does wrong | It imports a global market proxy as if it were local demand. Conversely, coord stats are locally relevant but bootstrap at zero and are supply-constrained. |
| Corrupted intent | Demand signal should estimate “probability this provider will receive paid work on this model.” Neither global rank nor local served traffic directly equals that during beta. |
| Severity | **Network-degrading**. Wrong mix means low utilization even when individual model economics look good. |
| Goodhart analogue | Ad platforms optimize for click-through rate even when advertisers care about conversion. Proxy demand is not the same as local paid utilization. |

### FM-6 — Hardware Tier Tail Pathologies

| Field | Assessment |
|---|---|
| Scenario | Tier-S M4 Max/Ultra and Tier-C M1/M4 Air use the same formula. Tier-C sees a high `$/M` dense 32B row and barely passes a short probe, then serves painful TTFT or swaps. Tier-S gets steered to small-active MoE because rank×TPS wins, leaving 70B/dense capacity uncovered. |
| What formula does wrong | It multiplies throughput by price but does not encode model-class coverage value or tier-specific opportunity cost. |
| Corrupted intent | Each hardware tier should serve the models it is uniquely good at. A uniform argmax can waste scarce high-memory/high-bandwidth hosts and overburden low-tier machines. |
| Severity | **Network-degrading**, possibly **network-killing** for high-end rows if all Tier-S machines choose the same small-active MoE rows as Tier-C. |
| Local context | Entry 92 already pivots to per-model RAM-first admission and keeps dense 32B/70B bandwidth gates; the installer must mirror that, not merely score all rows uniformly. |

### FM-7 — Bid-Shading / Provider Coordination

| Field | Assessment |
|---|---|
| Scenario | A provider Discord coordinates: “Tier-S operators all pick qwen2.5-coder-32b, Tier-A pick qwen3-coder, Tier-C pick gpt-oss-20b.” They avoid competition or try to dominate scarce model lanes. |
| What formula does wrong | The formula assumes independent providers and no strategic response. Once recommendations are public and earnings visible, providers can coordinate around scarcity. |
| Corrupted intent | Recommendations should improve network coverage and provider earnings, not create cartel-like lane allocation. |
| Severity | **Cosmetic to network-degrading** in beta. With 120 providers and fixed rate card, the more realistic issue is herding, not cartel control. |
| Goodhart analogue | Mining pools and ASIC concentration: participants optimize around the reward function and centralize behavior even when the protocol intended decentralization. |

### FM-8 — Availability / Quality Blindness

| Field | Assessment |
|---|---|
| Scenario | A model has strong install-time TPS but poor real reliability: high TTFT on 4K prompts, unsupported tokenizer/accounting path, high swap risk, or frequent `stream_output_exceeded`. The formula still recommends it because TPS×price×rank is high. |
| What formula does wrong | It scores speed and price, but not “can this provider reliably serve paid buyer traffic end-to-end?” |
| Corrupted intent | Expected `$/hr` should be paid accepted work, not local decode speed. |
| Severity | **Network-killing** if it recommends rows that fail billing/accounting or runtime support; otherwise **network-degrading**. |
| Local context | Entry 93/94 found real new-row gateway/accounting issues and runtime blockers. SPEC-018 v0.1 must not recommend rows until deployability gates are green. |

### FM-9 — Supply-Constraint Feedback Loop In Coord Stats

| Field | Assessment |
|---|---|
| Scenario | `coordinator.malibu.tech/v1/demand-signal` counts served tokens by model. Models with many providers get more served tokens because they are available. Models with zero providers get zero served tokens even if buyers attempted them and got `503`. |
| What formula does wrong | It measures fulfilled supply, not attempted demand. |
| Corrupted intent | Demand signal should guide supply into missing demand. Served-token stats guide supply toward already-served rows. |
| Severity | **Network-degrading**; **network-killing** when it locks out uncovered models. |
| Goodhart analogue | Marketplace ranking based only on completed sales disadvantages listings that are never shown or are out of stock. |

### FM-10 — Projection Misinterpretation / Provider Churn

| Field | Assessment |
|---|---|
| Scenario | Installer prints “expected `$0.021/hr`” for qwen3-coder from TPS×rate×share, but actual utilization is 5-20%. Provider receives `$0.001-$0.004/hr` cash plus token subsidy. They perceive the recommendation as false advertising. |
| What formula does wrong | It computes full-utilization earning capacity, not expected realized earnings under fleet utilization and buyer volume. |
| Corrupted intent | Onboarding should set provider expectations and reduce churn. A precise-looking formula can overpromise. |
| Severity | **Network-degrading** via provider trust and retention. |
| Local context | Entry 92 explicitly says USD economics are electricity-plus and token subsidy carries beta provider incentive; SPEC-018 wording must preserve that honesty. |

**Part 1 conclusion:** The v0.1 risk is not one bad demand multiplier; it is turning a per-provider argmax into a fleet-wide coordination signal without coverage floors, cold-start priors, deployability gates, and stale-input handling.

## Part 2 — Mitigation Library

| ID | Failure modes | Mechanism | Where it lives | LOC | Adds UX / state / endpoints? | Downside | Bake into v0.1? |
|---|---|---|---|---:|---|---|---|
| M1 | FM-1, FM-6 | **Deterministic top-K diversification.** Instead of always selecting rank 1 score, compute eligible top 3 and choose default by stable hash of provider ID or machine fingerprint across the top band, e.g. choose among candidates within 85-90% of best score. | Formula / autotune logic | Small | No new endpoint; tiny install text may show “recommended” plus alternatives | Some providers get slightly lower projected capacity than pure argmax | **Yes** |
| M2 | FM-1, FM-2, FM-9 | **Minimum catalog coverage floor.** SPEC says every rate-card-eligible, deployable, buyer-visible model needs at least N healthy providers by tier class before demand weighting can suppress it. For beta, N can be small, e.g. 2-3 total and at least 1 non-low-tier where required. | Operator config / formula constants | Small | No new endpoint if encoded in static demand file or release config | Requires operator to maintain row status | **Yes, if static config only** |
| M3 | FM-2, FM-9 | **Cold-start prior / floor.** Clamp `demand_signal` to a nonzero floor for deployable rows, e.g. `max(raw_demand, 0.15)` or rank-prior fallback when local stats are empty. | Formula | Small | None | Can over-recommend speculative rows | **Yes** |
| M4 | FM-2, FM-5 | **Row lifecycle states: candidate / listed / recommended.** New rows are not automatically recommended; they graduate only after runtime, billing, and minimum bench gates pass. Candidate rows can appear as alternatives but not default. | Operator config consumed by install/autotune | Small-medium | No new endpoint if static JSON | Slows launch of hot models | **Yes** |
| M5 | FM-3 | **Benchmark anti-gaming guardrails.** Use CLI-owned local probe, not provider-entered TPS; require warmup + sustained window + TTFT cap + no-swap/thermal sanity. Store measured TPS locally with timestamp and candidate hash. | Autotune logic | Medium | No endpoint; no operator UX beyond progress text | Adds install time | **Yes if minimal; deeper attestation v0.2** |
| M6 | FM-3 | **Production feedback correction.** Coordinator later compares provider-observed request TPS against install TPS and downweights bad actors. | Coord stats / routing | Large | Adds network state and policy | Can punish providers for buyer prompt variance | **Defer v0.2** |
| M7 | FM-4 | **Rate-card version binding.** Recommendation records the rate-card/demand-file version used. Provider heartbeat or status can expose current model; install can warn on next run if config is stale. | Install.sh / autotune metadata | Small | Minimal local UX; no endpoint required | Does not auto-retune existing providers | **Yes** |
| M8 | FM-4 | **Retune hint on upgrade / model reload.** `macprovider upgrade` or install rerun fetches current demand/rate metadata and says “recommendation changed from X to Y.” | install.sh / CLI | Small | Operator-visible UX | Providers must act manually | **Yes** |
| M9 | FM-4 | **Coordinator push retune notices.** Broadcast “recommended model changed” to providers after hot reload. | Coord endpoint / provider protocol | Medium-large | Adds network state and provider UX | Scope creep for v0.1 | **Defer v0.2** |
| M10 | FM-5, FM-9 | **Hybrid demand signal with bootstrap source.** v0.1 uses static/live OpenRouter rank prior; v0.2 switches to blended local attempted-demand stats after sufficient history. | Demand JSON / formula | Small now, medium later | No v0.1 endpoint if static URL | Global rank mismatch remains | **Yes for v0.1 prior; defer local blend** |
| M11 | FM-5, FM-9 | **Track attempted demand, not just served tokens.** Count buyer requests by requested model, including `503 no provider`, auth-valid only. | Coord stats rollup | Medium-large | New coord stats surface or internal table | Abuse/spam filtering needed | **Defer v0.2** |
| M12 | FM-6 | **Hard eligibility gates before scoring.** Filter candidates by RAM, bandwidth tier, runtime support, benchmark pass, model admission, and billing deployability before applying score. | Autotune + operator config | Small-medium | None if silent; install can show only eligible rows | Risk of hiding rows operator expected | **Yes** |
| M13 | FM-6 | **Tier-specific opportunity-cost bonus.** Add small operator-set weights by tier: Tier-S may reserve some probability for high-end rows; Tier-C biased toward small-active MoE. | Formula config | Small | None | Hand-tuned and can become stale | **Maybe v0.1 only as static weights; otherwise defer** |
| M14 | FM-7 | **Do nothing special in v0.1; monitor concentration.** Collusion is lower-probability than herding. The diversification and coverage floors already reduce its effect. | Spec risk register | None | None | Does not detect cartel behavior | **Yes as explicit deferral** |
| M15 | FM-7 | **Per-provider quotas or lane caps.** Coordinator limits provider counts per model or assigns quotas. | Coord/network policy | Large | Adds network state and operator/admin surface | Heavy-handed; can reduce provider autonomy | **Defer v0.2+** |
| M16 | FM-8 | **Deployability gate is mandatory.** A row must be marked `recommendable: true` only after end-to-end request, gateway settlement, tokenizer/accounting, and runtime architecture support are green. | Operator config / demand JSON | Small | No new endpoint | Manual bookkeeping | **Yes** |
| M17 | FM-8 | **Quality-adjusted score factor.** Multiply by `quality_gate` or `reliability_score` from production errors and TTFT. | Coord stats / formula | Medium-large | Network state and possibly endpoint | Needs enough traffic; can feedback-loop | **Defer v0.2** |
| M18 | FM-10 | **Label projection as full-utilization capacity.** Installer must say “at 100% utilization” or “capacity, not guaranteed earnings,” and keep token subsidy messaging separate. | install.sh UX | Small | Operator-visible UX | Less exciting onboarding copy | **Yes** |
| M19 | FM-10 | **Utilization-adjusted expected earnings.** Use local buyer volume / fleet supply to estimate realized earnings. | Coord stats endpoint | Large | New endpoint/state | Bootstrap zero and noisy | **Defer v0.2** |
| M20 | FM-1, FM-4, FM-5 | **Static demand-rank JSON with version and row metadata.** Serve `get.malibu.tech/demand-rank.json` containing row weights, lifecycle state, min provider coverage, and generated timestamp. Installer fetches it with baked fallback. | Static URL + install/autotune | Small-medium | No coord endpoint; no new provider state | Static file can go stale; needs operator discipline | **Yes** |

### Recommended v0.1 Bake-In Set

| Mechanism | Why it belongs in v0.1 |
|---|---|
| M1 deterministic top-K diversification | Cheaply prevents pure argmax herding without a coordinator endpoint. |
| M3 cold-start floor | Prevents zero-demand permanent exclusion. |
| M4 row lifecycle states | Keeps speculative or broken rows out of default recommendations. |
| M7/M8 version binding + retune hint | Handles rate-card/demand-file drift without protocol changes. |
| M12 hard eligibility gates | Prevents impossible or tail-pathological recommendations. |
| M16 deployability gate | Critical after Entry 93/94: do not recommend rows until end-to-end billing/runtime is green. |
| M18 full-utilization wording | Prevents provider trust damage from overstated “expected $/hr.” |
| M20 static/live demand JSON | Gives operator a cheap control plane without waiting for coord stats. |

### v0.1 Formula Shape

Recommended v0.1 scoring should be closer to:

```text
eligible_rows = rows where:
  rate_card_enabled
  recommendable == true
  model_admission passes hardware
  local_autotune passes sustained TPS + TTFT + no-swap gates

raw_score =
  measured_tps
  * 3600
  * usd_per_million
  * provider_share
  * max(demand_weight, cold_start_floor)
  * optional_tier_weight

recommendation_pool =
  top eligible rows within 85-90% of best raw_score
  plus any coverage-floor row still under min_provider_target

default =
  stable_hash(provider_id_or_machine_fingerprint) across recommendation_pool
```

### v0.1 Non-Goals

| Deferred item | Reason |
|---|---|
| Live coord `/v1/demand-signal` endpoint | Bootstrap-zero and supply-feedback risks; adds new surface. |
| Provider quota/cap allocation | Too much market-design complexity for 120-provider beta. |
| Production TPS reputation downweighting | Needs traffic, prompt normalization, and anti-abuse design. |
| Utilization-adjusted earnings | Honest but data-poor before paying buyer history exists. |
| Collusion enforcement | Lower priority than accidental herding and coverage failure. |

**Part 2 conclusion:** SPEC-018 v0.1 should bake in cheap static controls: eligibility gates, deployability states, cold-start floors, top-K diversification, metadata versioning, and honest “capacity not guaranteed earnings” wording; defer live market allocation to v0.2.

## Part 3 — Recommended v0.1 Demand-Signal Source

### Ranking Of Options

| Rank | Option | Verdict |
|---:|---|---|
| 1 | **(b) OpenRouter top-50 rank fetched live from static URL** | Best v0.1 choice. It avoids binary-baked staleness, works before macprovider has buyer history, and gives the operator a safe, cheap control plane. |
| 2 | **(e) Hybrid: v0.1 OpenRouter prior, v0.2 local coord stats after 60+ days** | Correct lifecycle strategy. For v0.1 this reduces to option (b) plus an explicit migration trigger. |
| 3 | **(a) OpenRouter rank baked into binary** | Safe fallback if network fetch fails, but too stale for a fast-changing model market. Refresh only on `macprovider upgrade` is not enough. |
| 4 | **(d) Constant 1.0** | Simple and avoids rank herding, but price×TPS alone will over-select high-price/low-demand rows and ignore buyer market evidence. Useful as a fallback, not primary. |
| 5 | **(c) Coord last-7-day macprovider stats** | Locally relevant later, wrong for v0.1. With ~2 providers and zero paying history, it mostly measures bootstrap accidents and current supply gaps. |

### Recommended Source

Use **option (b)** for v0.1:

```text
Primary: get.malibu.tech/demand-rank.json
Fallback: baked demand-rank snapshot in the installer/CLI
Future: switch or blend with coord attempted-demand stats after 60+ days
```

The static JSON should not be just rank. It should carry enough operator-controlled metadata to avoid separate v0.1 surfaces:

```json
{
  "version": "2026-06-30.1",
  "generated_at": "2026-06-30T00:00:00Z",
  "source": "openrouter_completion_token_rank_operator_curated",
  "cold_start_floor": 0.15,
  "top_k_band": 0.90,
  "rows": {
    "openai/gpt-oss-20b": {
      "demand_weight": 1.00,
      "rank": 24,
      "recommendable": true,
      "min_provider_target": 8
    },
    "qwen/qwen3-coder-30b-a3b-instruct": {
      "demand_weight": 0.85,
      "rank": null,
      "recommendable": true,
      "min_provider_target": 6
    },
    "meta-llama/llama-3.1-8b-instruct": {
      "demand_weight": 0.55,
      "rank": 49,
      "recommendable": true,
      "min_provider_target": 3
    }
  }
}
```

### Why Not Coord Stats In v0.1

Coord stats are attractive because they reflect macprovider’s buyer mix, but v0.1 has three bootstrap defects:

1. **Zero history:** there is not enough paying buyer traffic to estimate demand.
2. **Supply censoring:** a model with no providers cannot accumulate served tokens.
3. **Launch coupling:** if install recommendations are driven by served traffic, early install randomness becomes permanent market structure.

If v0.2 uses coord stats, it should use **attempted demand**, not just served tokens:

```text
demand_signal_v0.2 =
  blend(
    OpenRouter prior,
    auth-valid buyer requested-model counts,
    no-provider 503 counts,
    served paid completion tokens
  )
```

Switch trigger should be explicit:

```text
Use local demand only after:
  >= 60 days history
  >= 50M paid or auth-valid requested completion-token equivalent
  >= 5 buyer accounts or partner keys with non-test traffic
  no single buyer contributes >50% of model demand
```

### Why Not Constant 1.0

Constant demand is better than bad local stats for cold start, but it turns the formula into price×TPS. That would likely over-recommend rows like high-priced coder/dense rows even where buyer demand is thin, and it removes the one signal that distinguishes “technically fast” from “marketable.” It should be a fallback when the static JSON cannot be fetched, not the primary source.

### Required v0.1 Safeguards With Option (b)

| Safeguard | Reason |
|---|---|
| Baked fallback snapshot | Installer must work offline or if `get.malibu.tech` fails. |
| JSON signature or checksum | Prevents accidental or tampered recommendation weights. |
| `recommendable` flag | Operator can block rows with runtime/billing/deployability failures. |
| Cold-start floor | Prevents permanent exclusion of new rows. |
| Top-K diversification band | Prevents all 120 providers choosing the same highest-weight row. |
| Version/timestamp display | Makes stale recommendation diagnosis possible. |
| No exact earnings guarantee | Demand rank is a utilization proxy, not a guarantee. |

**Part 3 conclusion:** For SPEC-018 v0.1, use operator-curated OpenRouter-prior demand weights fetched from `get.malibu.tech/demand-rank.json` with a baked fallback, then graduate to blended coord attempted-demand stats only after 60+ days of real buyer history.

## Part 4 — One-Line Conclusions

| Part | Liftable conclusion |
|---|---|
| Part 1 | The v0.1 risk is not one bad demand multiplier; it is turning a per-provider argmax into a fleet-wide coordination signal without coverage floors, cold-start priors, deployability gates, and stale-input handling. |
| Part 2 | SPEC-018 v0.1 should bake in cheap static controls: eligibility gates, deployability states, cold-start floors, top-K diversification, metadata versioning, and honest “capacity not guaranteed earnings” wording; defer live market allocation to v0.2. |
| Part 3 | For SPEC-018 v0.1, use operator-curated OpenRouter-prior demand weights fetched from `get.malibu.tech/demand-rank.json` with a baked fallback, then graduate to blended coord attempted-demand stats only after 60+ days of real buyer history. |
| Overall | Ship v0.1 as a conservative installer recommendation system, not an autonomous market maker: recommend only deployable eligible rows, diversify defaults, preserve cold-start, and keep live coord demand optimization for v0.2. |
tokens used
89 775

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.
