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
