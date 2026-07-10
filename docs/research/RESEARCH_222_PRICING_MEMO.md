# codex advisor artifact

- Provider: codex
- Exit code: 0
- Created at: 2026-06-30T05:03:00.134Z

## Original task

# RESEARCH PROMPT — Issue #222 beta-campaign pricing decision

Run as: `omc ask codex "$(cat specs/RESEARCH_222_PRICING_PROMPT.md)"`

This is a **strategy research prompt**, not a code-audit prompt. No
3-lane discipline required. Single codex call (or run twice with
different models to cross-check); the output is a recommendation memo,
not a diff.

---

## Task

Decide pricing for the macprovider **beta campaign**. Today's defaults
are placeholders inherited from SPEC-005 D3 — never re-tuned with live
data. Issue #222 quantified the gap: providers earn **~$0.045/hr** at
default rates × current M-series sustained TPS, which is below the v0.1
B6 bare-min ($0.30/hr) and ~22× under the $1.00/hr target. The network
is **not provider-viable** at current settings.

Recommend a concrete rate change (or explicit defer with re-trigger
criteria), backed by market data and a sensitivity analysis. End with a
DECISION_CRITERIA.md entry ready to commit.

## Background — current state (verbatim from code/issue/baseline)

**Rate-card defaults** (`phase4-coordinator/internal/config/config.go:548-549`):
- `PromptCreditsPerMtok: 500_000`
- `CompletionCreditsPerMtok: 1_000_000`
- `Rewards.GlobalMultiplier: 1.0` (line ~543)
- `Rewards.ProviderShare: 0.90`
- `StatsRollup.UsdPerMillionCredits: 1.0` (`$1` per Mcredit)

**Per 1000 completion tokens math:**
- gross_credits = 1000 × 1_000_000 / 1_000_000 = 1000 credits
- provider_credits = 1000 × 0.90 = 900 credits
- USD = 900 × $1.0 / 1_000_000 = **$0.0009 per 1k completion tokens**

**Observed sustained TPS** (BENCHMARK_BASELINE_2026-06-29.md, scenario 07):
- Qwen3-32B-4bit on M4 Air: **14 tok/s** sustained (hardware-bound)
- 14 × 3600 = 50,400 completion tokens/hr → $0.045/hr per provider

**Three SPEC-005 D3 tuning levers** (in order of operational ease):
1. `Rewards.GlobalMultiplier` — single knob, hot-reloadable
2. `StatsRollup.UsdPerMillionCredits` — pure USD-conversion factor
3. Fleet TPS — exogenous; M4 Max / M2 Ultra / M3 Ultra raise the ceiling

## What to produce

### Part 1 — Market comparison (current per-token pricing)

For the model classes macprovider providers actually run today
(MLX-quantized small-mid open models on Apple Silicon), pull current
public per-token prices from these surfaces:

- **OpenAI**: gpt-4o-mini, gpt-4.1-mini, gpt-4o
- **Anthropic**: claude-haiku-4-5, claude-sonnet-4-6
- **Together.ai**: Qwen2.5-Coder-7B / Qwen2.5-32B / Qwen3-32B (closest match)
- **OpenRouter**: same Qwen family + Llama-3-8B / Llama-3.1-8B-Instruct
- **Groq**: Llama-3.1-8B, Llama-3.3-70B (if listed)
- **Replicate / Fireworks / DeepInfra**: same Qwen / Llama tier
- **Local-only baseline**: cost of running Ollama / LM Studio yourself
  (electricity-only, no margin)

For each, report `$/1M prompt` and `$/1M completion` and convert to
$/1k completion. Build a table sorted by completion price ascending.

**Then add the macprovider current default to the table** so the gap
is visible at a glance.

### Part 2 — Provider electricity floor

For the two Apple Silicon SKUs we have data for, compute the
electricity break-even rate:

- M4 Air (active): ~12-15W under MLX load
- M4 Max / M2 Ultra (estimated): ~60-100W under MLX load

At US residential ~$0.16/kWh, what $/hr does each tier need to earn to
break even on electricity alone? Use those numbers as the absolute
floor — anything below loses money even before opportunity cost.

### Part 3 — Sensitivity table

For each combination of {GlobalMultiplier ∈ [1, 5, 10, 25, 50, 100]} ×
{sustained TPS ∈ [14, 30, 60, 120]}, compute:
- provider $/hr earnings
- gateway $/hr revenue (the 10% buyer-side share)
- buyer $/1M completion tokens (what they pay) — compare against the
  market table from Part 1

Highlight the cells where:
- provider clears electricity floor for M4 Air
- provider clears B6 bare-min ($0.30/hr)
- provider clears B6 target ($1.00/hr)
- buyer price stays competitive vs Together.ai / OpenRouter for
  comparable Qwen tier

### Part 4 — Beta-campaign pricing recommendation

Pick ONE of the following postures and justify it with the data above:

**Posture A — provider-subsidized bootstrap.** Set multiplier high
enough that even M4 Air clears $0.30/hr at 14 tok/s. Accept that buyer
price will be above-market. Bet: attract providers first, fix buyer
side once fleet TPS scales.

**Posture B — buyer-competitive.** Set multiplier so buyer $/1M
completion sits at parity with cheapest market tier (likely
OpenRouter/Together for Qwen). Accept that providers earn below floor
on M4 Air; bet that they upgrade hardware or accept it as donation /
network-equity stake.

**Posture C — explicit defer.** Keep current placeholders. Document
trigger criteria for when to revisit (e.g. "when fleet sustained p50
TPS ≥ 30 tok/s" or "when buyer count > 10" or "when we have ≥ 1 paying
buyer").

**Posture D — split rate card.** Two model classes: "premium" (large
models, higher TPS hardware) priced near market; "donor" (small models
on entry-level hardware) priced as effective give-away. Bet: lets
M4 Air providers join without distorting buyer-facing economics.

If none of A-D fits, propose your own. Be concrete: name the new
GlobalMultiplier value (or new UsdPerMillionCredits), show the
resulting cells in the Part 3 table, and state who pays the gap.

### Part 5 — DECISION_CRITERIA.md entry (ready to commit)

Drop a numbered entry suitable for appending to `beta/DECISION_CRITERIA.md`.
House style is established through Entries 1-21. The entry must contain:

- **Decision** — what changed and to what value(s)
- **Why** — market data + sensitivity table cell that backs it
- **Effective** — when does the new rate go live (next deploy? next
  beta cohort?)
- **Re-trigger** — what observable condition would force a revisit
- **Owner** — operator (default)

### Part 6 — Implementation pointer (optional)

If the recommendation is to change defaults, point at the exact lines:
- `phase4-coordinator/internal/config/config.go:543` (GlobalMultiplier)
- `phase4-coordinator/internal/config/config.go:548-549` (rate-card)
- `phase4-coordinator/internal/config/config.go:138` (UsdPerMillionCredits)
- Live operator config: `/opt/macprovider/coordinator.yaml` on Pearl VPS

Note whether the change is hot-reloadable or requires a coordinator
restart, and whether SPEC-NETWORK-BENCHMARK-v0.1 §3.3 thresholds need
to be updated to match the new economics.

## Out of scope

- Real USD payouts (separate payment-rail work, not blocking pricing)
- Token issuance / treasury / equity mechanics
- Changing the credit arithmetic model itself (SPEC-005 D3 is locked)
- Refactoring the rate-card schema

## Output format

Markdown memo, ~400-800 lines. Tables for Parts 1 + 3. Plain prose
for Parts 2 + 4. Code block for Part 5. Cite every market price with
the source URL you pulled it from and the date — these change weekly.

## Final prompt

# RESEARCH PROMPT — Issue #222 beta-campaign pricing decision

Run as: `omc ask codex "$(cat specs/RESEARCH_222_PRICING_PROMPT.md)"`

This is a **strategy research prompt**, not a code-audit prompt. No
3-lane discipline required. Single codex call (or run twice with
different models to cross-check); the output is a recommendation memo,
not a diff.

---

## Task

Decide pricing for the macprovider **beta campaign**. Today's defaults
are placeholders inherited from SPEC-005 D3 — never re-tuned with live
data. Issue #222 quantified the gap: providers earn **~$0.045/hr** at
default rates × current M-series sustained TPS, which is below the v0.1
B6 bare-min ($0.30/hr) and ~22× under the $1.00/hr target. The network
is **not provider-viable** at current settings.

Recommend a concrete rate change (or explicit defer with re-trigger
criteria), backed by market data and a sensitivity analysis. End with a
DECISION_CRITERIA.md entry ready to commit.

## Background — current state (verbatim from code/issue/baseline)

**Rate-card defaults** (`phase4-coordinator/internal/config/config.go:548-549`):
- `PromptCreditsPerMtok: 500_000`
- `CompletionCreditsPerMtok: 1_000_000`
- `Rewards.GlobalMultiplier: 1.0` (line ~543)
- `Rewards.ProviderShare: 0.90`
- `StatsRollup.UsdPerMillionCredits: 1.0` (`$1` per Mcredit)

**Per 1000 completion tokens math:**
- gross_credits = 1000 × 1_000_000 / 1_000_000 = 1000 credits
- provider_credits = 1000 × 0.90 = 900 credits
- USD = 900 × $1.0 / 1_000_000 = **$0.0009 per 1k completion tokens**

**Observed sustained TPS** (BENCHMARK_BASELINE_2026-06-29.md, scenario 07):
- Qwen3-32B-4bit on M4 Air: **14 tok/s** sustained (hardware-bound)
- 14 × 3600 = 50,400 completion tokens/hr → $0.045/hr per provider

**Three SPEC-005 D3 tuning levers** (in order of operational ease):
1. `Rewards.GlobalMultiplier` — single knob, hot-reloadable
2. `StatsRollup.UsdPerMillionCredits` — pure USD-conversion factor
3. Fleet TPS — exogenous; M4 Max / M2 Ultra / M3 Ultra raise the ceiling

## What to produce

### Part 1 — Market comparison (current per-token pricing)

For the model classes macprovider providers actually run today
(MLX-quantized small-mid open models on Apple Silicon), pull current
public per-token prices from these surfaces:

- **OpenAI**: gpt-4o-mini, gpt-4.1-mini, gpt-4o
- **Anthropic**: claude-haiku-4-5, claude-sonnet-4-6
- **Together.ai**: Qwen2.5-Coder-7B / Qwen2.5-32B / Qwen3-32B (closest match)
- **OpenRouter**: same Qwen family + Llama-3-8B / Llama-3.1-8B-Instruct
- **Groq**: Llama-3.1-8B, Llama-3.3-70B (if listed)
- **Replicate / Fireworks / DeepInfra**: same Qwen / Llama tier
- **Local-only baseline**: cost of running Ollama / LM Studio yourself
  (electricity-only, no margin)

For each, report `$/1M prompt` and `$/1M completion` and convert to
$/1k completion. Build a table sorted by completion price ascending.

**Then add the macprovider current default to the table** so the gap
is visible at a glance.

### Part 2 — Provider electricity floor

For the two Apple Silicon SKUs we have data for, compute the
electricity break-even rate:

- M4 Air (active): ~12-15W under MLX load
- M4 Max / M2 Ultra (estimated): ~60-100W under MLX load

At US residential ~$0.16/kWh, what $/hr does each tier need to earn to
break even on electricity alone? Use those numbers as the absolute
floor — anything below loses money even before opportunity cost.

### Part 3 — Sensitivity table

For each combination of {GlobalMultiplier ∈ [1, 5, 10, 25, 50, 100]} ×
{sustained TPS ∈ [14, 30, 60, 120]}, compute:
- provider $/hr earnings
- gateway $/hr revenue (the 10% buyer-side share)
- buyer $/1M completion tokens (what they pay) — compare against the
  market table from Part 1

Highlight the cells where:
- provider clears electricity floor for M4 Air
- provider clears B6 bare-min ($0.30/hr)
- provider clears B6 target ($1.00/hr)
- buyer price stays competitive vs Together.ai / OpenRouter for
  comparable Qwen tier

### Part 4 — Beta-campaign pricing recommendation

Pick ONE of the following postures and justify it with the data above:

**Posture A — provider-subsidized bootstrap.** Set multiplier high
enough that even M4 Air clears $0.30/hr at 14 tok/s. Accept that buyer
price will be above-market. Bet: attract providers first, fix buyer
side once fleet TPS scales.

**Posture B — buyer-competitive.** Set multiplier so buyer $/1M
completion sits at parity with cheapest market tier (likely
OpenRouter/Together for Qwen). Accept that providers earn below floor
on M4 Air; bet that they upgrade hardware or accept it as donation /
network-equity stake.

**Posture C — explicit defer.** Keep current placeholders. Document
trigger criteria for when to revisit (e.g. "when fleet sustained p50
TPS ≥ 30 tok/s" or "when buyer count > 10" or "when we have ≥ 1 paying
buyer").

**Posture D — split rate card.** Two model classes: "premium" (large
models, higher TPS hardware) priced near market; "donor" (small models
on entry-level hardware) priced as effective give-away. Bet: lets
M4 Air providers join without distorting buyer-facing economics.

If none of A-D fits, propose your own. Be concrete: name the new
GlobalMultiplier value (or new UsdPerMillionCredits), show the
resulting cells in the Part 3 table, and state who pays the gap.

### Part 5 — DECISION_CRITERIA.md entry (ready to commit)

Drop a numbered entry suitable for appending to `beta/DECISION_CRITERIA.md`.
House style is established through Entries 1-21. The entry must contain:

- **Decision** — what changed and to what value(s)
- **Why** — market data + sensitivity table cell that backs it
- **Effective** — when does the new rate go live (next deploy? next
  beta cohort?)
- **Re-trigger** — what observable condition would force a revisit
- **Owner** — operator (default)

### Part 6 — Implementation pointer (optional)

If the recommendation is to change defaults, point at the exact lines:
- `phase4-coordinator/internal/config/config.go:543` (GlobalMultiplier)
- `phase4-coordinator/internal/config/config.go:548-549` (rate-card)
- `phase4-coordinator/internal/config/config.go:138` (UsdPerMillionCredits)
- Live operator config: `/opt/macprovider/coordinator.yaml` on Pearl VPS

Note whether the change is hot-reloadable or requires a coordinator
restart, and whether SPEC-NETWORK-BENCHMARK-v0.1 §3.3 thresholds need
to be updated to match the new economics.

## Out of scope

- Real USD payouts (separate payment-rail work, not blocking pricing)
- Token issuance / treasury / equity mechanics
- Changing the credit arithmetic model itself (SPEC-005 D3 is locked)
- Refactoring the rate-card schema

## Output format

Markdown memo, ~400-800 lines. Tables for Parts 1 + 3. Plain prose
for Parts 2 + 4. Code block for Part 5. Cite every market price with
the source URL you pulled it from and the date — these change weekly.

## Raw output

```text
**Memo — Issue #222 Beta Pricing**

Date: 2026-06-30  
Recommendation: **Posture A, set `Rewards.GlobalMultiplier = 10.0` for the next beta cohort.** This makes the current 14 tok/s M4 Air provider clear the B6 bare-min `$0.30/hr` threshold at `$0.454/hr`, but it makes buyer completion pricing `$10/M tokens`, far above comparable Qwen market pricing. The gap is paid by beta buyers unless the operator issues buyer credits or treats beta traffic as subsidized acquisition.

**Part 1 — Market Comparison**

All prices are public list prices retrieved 2026-06-30. `$ / 1k completion` is `completion price / 1000`.

| Rank | Surface / model | $/1M prompt | $/1M completion | $/1k completion | Source |
|---:|---|---:|---:|---:|---|
| 1 | OpenRouter Llama 3.1 8B Instruct | 0.02 | 0.03 | 0.00003 | [OpenRouter models API](https://openrouter.ai/api/v1/models) |
| 2 | Groq Llama 3.1 8B Instant | 0.04 | 0.04 | 0.00004 | [Groq pricing](https://groq.com/pricing/) |
| 3 | Local-only M4 Air electricity, 12-15W @14 tok/s | n/a | 0.038-0.048 | 0.000038-0.000048 | Prompt power assumptions, `$0.16/kWh` |
| 4 | DeepInfra Llama 3.1 8B Instruct | 0.03 | 0.05 | 0.00005 | [DeepInfra model page](https://deepinfra.com/meta-llama/Meta-Llama-3.1-8B-Instruct) |
| 5 | OpenRouter Qwen2.5 7B Instruct | 0.04 | 0.10 | 0.00010 | [OpenRouter models API](https://openrouter.ai/api/v1/models) |
| 6 | OpenRouter Llama 3 8B Instruct | 0.14 | 0.14 | 0.00014 | [OpenRouter models API](https://openrouter.ai/api/v1/models) |
| 7 | Fireworks Llama 3.1 8B tier | 0.20 | 0.20 | 0.00020 | [Fireworks pricing/model pages](https://docs.fireworks.ai/serverless/pricing) |
| 8 | Together Qwen3.5 9B closest Qwen small tier | 0.17 | 0.25 | 0.00025 | [Together pricing](https://www.together.ai/pricing) |
| 9 | OpenRouter Qwen3 32B | 0.08 | 0.28 | 0.00028 | [OpenRouter models API](https://openrouter.ai/api/v1/models) |
| 10 | DeepInfra Qwen3 32B | 0.08 | 0.28 | 0.00028 | [DeepInfra Qwen3 32B](https://deepinfra.com/Qwen/Qwen3-32B) |
| 11 | Together Qwen2.5 7B Turbo | 0.30 | 0.30 | 0.00030 | [Together pricing](https://www.together.ai/pricing) |
| 12 | DeepInfra Llama 3.3 70B Turbo | 0.10 | 0.32 | 0.00032 | [DeepInfra 70B](https://deepinfra.com/meta-llama/Llama-3.3-70B-Instruct-Turbo) |
| 13 | OpenRouter Llama 3.3 70B Instruct | 0.10 | 0.32 | 0.00032 | [OpenRouter models API](https://openrouter.ai/api/v1/models) |
| 14 | OpenAI gpt-4o-mini | 0.15 | 0.60 | 0.00060 | [OpenAI gpt-4o-mini](https://openai.com/index/gpt-4o-mini-advancing-cost-efficient-intelligence/) |
| 15 | Groq Llama 3.3 70B Versatile | 0.59 | 0.79 | 0.00079 | [Groq pricing](https://groq.com/pricing/) |
| 16 | Together Qwen2.5-Coder 32B Instruct | 0.80 | 0.80 | 0.00080 | [Together model page](https://www.together.ai/models/qwen-2-5-coder-32b-instruct) |
| 17 | Fireworks Llama 3.3 70B tier | 0.90 | 0.90 | 0.00090 | [Fireworks pricing/model pages](https://docs.fireworks.ai/serverless/pricing) |
| 18 | **macprovider current buyer gross** | **0.50** | **1.00** | **0.00100** | [config.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/config/config.go:544) |
| 19 | OpenRouter Qwen2.5-Coder 32B Instruct | 0.66 | 1.00 | 0.00100 | [OpenRouter models API](https://openrouter.ai/api/v1/models) |
| 20 | Together Qwen3.7 Plus closest current Qwen plus tier | 0.32 | 1.28 | 0.00128 | [Together pricing](https://www.together.ai/pricing) |
| 21 | OpenAI gpt-4.1-mini | 0.40 | 1.60 | 0.00160 | [OpenAI GPT-4.1](https://openai.com/index/gpt-4-1/) |
| 22 | Anthropic Claude Haiku 4.5 | 1.00 | 5.00 | 0.00500 | [Claude models overview](https://docs.claude.com/en/docs/about-claude/models/overview) |
| 23 | Replicate L40S GPU-second baseline, converted @120 tok/s | n/a | 8.13 | 0.00813 | [Replicate pricing](https://replicate.com/pricing) |
| 24 | OpenAI gpt-4o | 2.50 | 10.00 | 0.01000 | [OpenAI pricing](https://platform.openai.com/docs/pricing) |
| 25 | Anthropic Claude Sonnet 4.6 | 3.00 | 15.00 | 0.01500 | [Claude models overview](https://docs.claude.com/en/docs/about-claude/models/overview) |

Key read: **macprovider current buyer gross price is already above the cheapest comparable Qwen3 32B market rows** (`$1.00/M` vs `$0.28/M`). The provider problem is not that buyers are undercharged relative to the cheapest market; it is that 14 tok/s is too slow for `$0.90/M provider-net` to produce hourly earnings.

**Part 2 — Provider Electricity Floor**

At `$0.16/kWh`:

| Hardware tier | Load watts | Electricity $/hr | Comment |
|---|---:|---:|---|
| M4 Air active MLX load | 12-15W | `$0.0019-$0.0024/hr` | Current `$0.045/hr` clears electricity by ~19x. |
| M4 Max / M2 Ultra estimate | 60-100W | `$0.0096-$0.0160/hr` | Still tiny versus B6; opportunity cost dominates. |

Electricity is not the binding constraint. The binding constraints are provider opportunity cost and beta-recruiting optics. B6 `$0.30/hr` is a bare-min human incentive, not an energy break-even.

**Part 3 — Sensitivity Table**

Formula with today’s credit arithmetic:

`provider $/hr = TPS * 3600 / 1e6 * 0.90 * GlobalMultiplier`  
`gateway $/hr = TPS * 3600 / 1e6 * 0.10 * GlobalMultiplier`  
`buyer $/1M completion = $1.00 * GlobalMultiplier`

Flags: `elec` clears M4 Air electricity high-end floor; `B6-min` clears `$0.30/hr`; `B6-target` clears `$1.00/hr`; `market-ish` means buyer price remains near Together Qwen3.7 Plus `$1.28/M`, not the cheapest OpenRouter/DeepInfra Qwen3-32B `$0.28/M`.

| Multiplier | TPS | Provider $/hr | Gateway $/hr | Buyer $/1M completion | Flags |
|---:|---:|---:|---:|---:|---|
| 1 | 14 | $0.045 | $0.005 | $1.00 | elec, market-ish |
| 1 | 30 | $0.097 | $0.011 | $1.00 | elec, market-ish |
| 1 | 60 | $0.194 | $0.022 | $1.00 | elec, market-ish |
| 1 | 120 | $0.389 | $0.043 | $1.00 | elec, B6-min, market-ish |
| 5 | 14 | $0.227 | $0.025 | $5.00 | elec |
| 5 | 30 | $0.486 | $0.054 | $5.00 | elec, B6-min |
| 5 | 60 | $0.972 | $0.108 | $5.00 | elec, B6-min |
| 5 | 120 | $1.944 | $0.216 | $5.00 | elec, B6-min, B6-target |
| 10 | 14 | $0.454 | $0.050 | $10.00 | elec, B6-min |
| 10 | 30 | $0.972 | $0.108 | $10.00 | elec, B6-min |
| 10 | 60 | $1.944 | $0.216 | $10.00 | elec, B6-min, B6-target |
| 10 | 120 | $3.888 | $0.432 | $10.00 | elec, B6-min, B6-target |
| 25 | 14 | $1.134 | $0.126 | $25.00 | elec, B6-min, B6-target |
| 25 | 30 | $2.430 | $0.270 | $25.00 | elec, B6-min, B6-target |
| 25 | 60 | $4.860 | $0.540 | $25.00 | elec, B6-min, B6-target |
| 25 | 120 | $9.720 | $1.080 | $25.00 | elec, B6-min, B6-target |
| 50 | 14 | $2.268 | $0.252 | $50.00 | elec, B6-min, B6-target |
| 50 | 30 | $4.860 | $0.540 | $50.00 | elec, B6-min, B6-target |
| 50 | 60 | $9.720 | $1.080 | $50.00 | elec, B6-min, B6-target |
| 50 | 120 | $19.440 | $2.160 | $50.00 | elec, B6-min, B6-target |
| 100 | 14 | $4.536 | $0.504 | $100.00 | elec, B6-min, B6-target |
| 100 | 30 | $9.720 | $1.080 | $100.00 | elec, B6-min, B6-target |
| 100 | 60 | $19.440 | $2.160 | $100.00 | elec, B6-min, B6-target |
| 100 | 120 | $38.880 | $4.320 | $100.00 | elec, B6-min, B6-target |

There is no multiplier in `[1, 5, 10, 25, 50, 100]` that is both cheap-Qwen competitive and M4-Air B6 viable. Strict parity with OpenRouter/DeepInfra Qwen3-32B (`$0.28/M`) would require `GlobalMultiplier ~= 0.28`, which drops the M4 Air provider to about `$0.013/hr`.

**Part 4 — Recommendation**

Pick **Posture A — provider-subsidized bootstrap**, but cap it at the B6 bare-min, not the `$1/hr` target.

Set:

```yaml
rewards:
  global_multiplier: 10.0
```

Do **not** change `UsdPerMillionCredits` for this decision. `GlobalMultiplier` is the intended pricing knob; it snapshots into billing rows and preserves the existing credit-to-USD reporting convention.

Why `10.0`:

- It moves the known M4 Air/Qwen3-32B cell from `$0.045/hr` to `$0.454/hr`.
- It clears B6 bare-min at the current worst observed sustained TPS.
- It nearly reaches B6 target at 30 tok/s (`$0.972/hr`) and clears target from 60 tok/s up.
- It avoids the worse optics of `25.0`, which would clear `$1/hr` on M4 Air but produce `$25/M` buyer completion pricing.

Who pays: the buyer-side price becomes `$10/M completion tokens`. That is **~36x** OpenRouter/DeepInfra Qwen3-32B (`$0.28/M`) and **12.5x** Together Qwen2.5-Coder-32B (`$0.80/M`). For beta, this only makes sense if the operator either limits paid buyer exposure, issues beta credits, or frames this as a provider-supply bootstrap campaign rather than a buyer-cost campaign.

Re-trigger:

- Fleet sustained p50 reaches `>= 60 tok/s` for the Qwen 30B-ish class.
- There is `>= 1` real paying buyer comparing invoices against Together/OpenRouter.
- Beta buyer completion volume exceeds `10M tokens/week`.
- Provider churn remains high even with `$0.30/hr+` projected earnings.
- A per-model/per-hardware split rate card becomes necessary to avoid pricing donor 7B traffic like premium 32B traffic.

**Part 5 — Decision Log Entry**

```markdown
| 2026-06-30 | **Entry 92 — Issue #222 beta-campaign pricing: current defaults are provider-nonviable at live M-series TPS.** Market check retrieved 2026-06-30 shows cheapest comparable Qwen3-32B completion pricing at **$0.28/M** on OpenRouter/DeepInfra, Together Qwen2.5-Coder-32B at **$0.80/M**, and macprovider current buyer gross at **$1.00/M** while provider-net is only **$0.90/M**. With BENCHMARK_BASELINE_2026-06-29 scenario 07 sustained **14 tok/s**, current provider earnings are **$0.045/hr**, below B6 bare-min **$0.30/hr** and far below target **$1.00/hr**. Electricity is not binding: M4 Air 12-15W at $0.16/kWh is only **$0.0019-$0.0024/hr**. | **Decision:** adopt provider-subsidized bootstrap pricing for the beta campaign by setting `rewards.global_multiplier: 10.0` for the next beta cohort / next Pearl coordinator pricing deploy. Keep `stats_rollup.usd_per_million_credits: 1.0`, `provider_share: 0.90`, and the default rate-card shape unchanged. **Why:** the 14 tok/s × multiplier 10 cell yields **$0.454/hr provider earnings**, clearing B6 bare-min without jumping to the `$25/M` buyer price required for B6 target on M4 Air. Buyer completion price becomes **$10/M**, explicitly above-market; the operator/beta buyer side pays that bootstrap gap until fleet TPS improves. **Effective:** next coordinator deploy or live config reload before onboarding the next beta provider cohort. **Re-trigger:** revisit immediately when fleet sustained p50 for Qwen 30B-ish class is ≥60 tok/s, when there is ≥1 real paying buyer, when beta buyer completion volume exceeds 10M tokens/week, when provider churn persists despite projected ≥$0.30/hr, or when per-model split pricing is needed. **Owner:** operator. | **Phase 5 / benchmark implication:** B6 can remain `$0.30/hr` bare-min and `$1.00/hr` target, but `BENCHMARK_PRICING_v0.1.json` must be re-derived after the config change. SPEC-NETWORK-BENCHMARK-v0.1 §3.3 thresholds do not need to move; expected B6 verdict changes from FAIL to PASS-bare-min for 14 tok/s providers under multiplier 10. |
```

**Part 6 — Implementation Pointer**

Change live config first:

- Pearl VPS: `/opt/macprovider/coordinator.yaml`
- Set `rewards.global_multiplier: 10.0`
- Send `SIGHUP` to the coordinator. The reload path loads config, writes a billing snapshot, and applies `SetBillingConfig` for new requests at [main.go](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:908).

Code defaults if you want the repo default to match:

- `Rewards.GlobalMultiplier` at [config.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/config/config.go:544)
- Rate-card defaults at [config.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/config/config.go:548)
- `UsdPerMillionCredits` field at [config.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/config/config.go:138)

No repo files were changed in this research pass.


```
