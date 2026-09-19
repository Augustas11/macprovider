# OpenRouter → Best-in-Class Catalog Pipeline (design)

Status: PR 1 implemented (proposer + request-count peg + SPEC-023 revision).
Owner: operator (a11). Target branch: `feat/openrouter-catalog-pipeline`.

## Goal

Turn the existing OpenRouter market-feeds engine into an end-to-end pipeline that
**proposes the best servable model catalog + market-pegged pricing** for the
Malibu fleet from live demand/price data, selecting **per hardware profile the
model that maximizes revenue/sec** (yield × achievable throughput — see
objective below), and flows the proposal through the signed-feed pipeline to the
fleet **behind an operator-approval gate**. It is a market-pegged **v0.12.0
catalog cut**, not a rewrite of billing or a new SPEC.

## What already exists (verified 2026-09-18; do not rebuild)

- **Proposer**: `scripts/openrouter_pricing_engine.py` — `fetch` (live snapshot,
  key from `OPENROUTER_API_KEY` env) → `compute` (rate-card + demand-rank
  proposals). Deliberately **non-apply** (runbook: "there is intentionally no
  apply mode"). Market price = unweighted median over distinct paid providers
  gated by 30m request-count eligibility; Malibu price = market × `(1 − undercut_fraction 0.20)`
  (`proposed_price`, ~L1385).
- **Selection seed**: `scripts/openrouter_mlx_candidates.py` — read-only HF probe
  that resolves a canonical `mlx-community/*` fleet-quant build per unmapped
  demand row, fail-closes to `review/not_servable/unresolved`, and does a single
  residency-band fit. **No RAM-tier bucketing.**
- **Policy allowlist**: `scripts/openrouter_pricing_policy.json`
  (`openrouter-market-feeds-v0.12.0`, 10 models). Ranked models outside it are
  emitted `unmapped` and land in the proposal's `blocked` bucket — never guessed.
- **Catalog materializer**: `scripts/catalog-release.py` — validates + canonicalizes
  the authored `autotune-candidates.json` / `demand-rank.json`, and **derives**
  `rate-card.json` (`resolve_rate_card`/`expand_rate_card`). Only verifies
  signatures.
- **Sign + deploy tail**: `scripts/resign-autotune-static.sh` (Ed25519,
  `streamvc-autotune-static-v4`, key file `~/.config/macprovider/keys/autotune-static-v4.private.base64`)
  and `scripts/renew-autotune-static-feed.sh --deploy` (rsync → Pearl
  `/opt/macprovider/autotune/current`, SIGHUP, rollback). Driven by
  `.github/workflows/renew-autotune-static-feed-signed.yml` (Wed 16:00 UTC).
- **Staleness alarms**: `autotune-feed-freshness-alarm.yml` (6h, 20d),
  `renew-autotune-static-feed.yml` (Tue, 7d). **No 401 / fetch-side alarm.**

## Normative surface (SPEC-first)

- **SPEC-023 v0.12.0 LOCKED** is the catalog-pipeline spec and **already specs
  OpenRouter market-pegging** (§3.3.1 rule 8: recommendable price = engine
  proposal, `classes` = `{}`), listed-tier intake (§16, `SPEC-023-R006`), class
  rate rows (§3.3.1, `SPEC-023-R005`), and artifact sets (§3.7, `SPEC-023-R004`).
- **`rate_class` is a closed enum** (§3.3.1 rule 1): `class-3b`, `class-8b`,
  `class-20b-moe`, `class-30b-moe`, `class-32b`, `class-70b`(reserved),
  `class-120b-moe`. Enforced at `catalog-release.py:87` and
  `phase4-coordinator/internal/buyer/catalog_artifacts_feed.go:59`.
- **SPEC-first decision:** the demand-dominant servable models all map onto
  existing buckets — `gpt-oss-120b`→`class-120b-moe`, `gpt-oss-20b`→`class-20b-moe`,
  Qwen3-8b/32b→`class-8b`/`class-32b`, Gemma→`class-30b-moe`/`class-32b`. **No
  SPEC-023 revision is required** for the core cut. A revision is forced only if
  we make a *genuinely new* parameter scale (e.g. a distinct ~13B or ≥235B tier)
  **recommendable**. DeepSeek-V4-flash (~671B) fits no single 256GB box → flagged
  `blocked`/multi-node, not served. Aggressive onboarding is available at the
  **`listed` tier with no `rate_class`** (§16.3); the enum only bites at
  recommendable promotion.
- SPEC-010 (identity, v1.8) and SPEC-005 (money table, v0.6.7) are unchanged by a
  market-pegged cut ("Pricing stays model-key scoped; no SPEC-005 change").

## Selection objective — revenue/sec, NOT "biggest model that fits"

The selection objective is per-hardware **revenue-per-second maximization**, not
size-tiered "best model that fits" (which is economically wrong — big RAM buys
*concurrency of the top-yield model*, not the ability to host one big cheap one):

```
select(h) = argmax over MLX-servable models m of
    revenue_per_sec(m, h) = (market_price_per_token(m) − undercut)
                            × achievable_sustained_tokens_per_sec(m, h, serve_mode)
    subject to: min_ram_gb(m) ≤ ram_gb(h) − safety_margin_gb(4)
                bandwidth_tier(h) ≥ min_bandwidth_tier(m)
```

Concretely, a 256GB box may earn more running a small-footprint **high-yield**
model at high concurrency than `gpt-oss-120b` (61GB, low $/tok) at low
concurrency. RAM headroom is *concurrency budget* for the top-yield model, not a
mandate to host the largest model.

**Honesty constraint on `achievable_sustained_tokens_per_sec`:** it is **measured
for the live serve mode**, never assumed. Concurrency multiplies earnings only
under continuous batching (SPEC-038/039); today's independent single-stream
decode does **not** realize slot→earnings (the `max_batch` two-pipeline reality).
So the engine computes throughput from **real bench + KV-fit headroom** and
**composes with** the `max_batch`/SPEC-038 work; it does not credit a big box with
concurrency it cannot serve today. A `(model, hardware)` pair lacking real bench
is **flagged**, not assigned invented throughput. Servability is decided by the
MLX resolver; price by endpoint pricing — both **verified by the engine**, not
ad-hoc.

**The three placement axes** the pipeline still sets per proposed model (they are
constraints + the pricing bucket, not the objective):
1. `min_ram_gb` (per artifact, resident floor excl. `safety_margin_gb=4`) — from
   the HF safetensors byte sum × runtime headroom (resolver computes residency).
2. `min_bandwidth_tier` ∈ `S/A/B/C` (memory-bandwidth gate).
3. `rate_class` (parameter-scale pricing bucket) — correlated with hardware by
   design (§3.3.1 rule 1), used for the money table, **not** for selection.

The proposal therefore emits, per hardware profile, the **revenue/sec-ranked**
servable set (with the bench/throughput provenance that produced each ranking),
so the operator reviews *why* a model won its slot, not just that it fits.

## The pipeline (end-to-end)

```
OPENROUTER_API_KEY ─▶ fetch ─▶ pricing snapshot ─▶ compute ─┐
                                                            ├─▶ rate-card proposal
HF mlx-community probe ─▶ servability + residency ──────────┤   demand-rank proposal
                                                            └─▶ per-model tier assignment
                                                                (min_ram_gb, min_bandwidth_tier, rate_class)
        │
        ▼  (new: selection layer nominates servable models, then per hardware
        │   profile ranks by revenue/sec = yield × achievable_tps(real bench+KV fit))
   proposed best-in-class catalog  ──▶  PR / reviewable diff  ──[OPERATOR MERGE = the gate]──▶
        catalog-release generate ──▶ resign (v4) ──▶ Pearl deploy ──▶ fleet SIGHUP
```

**Human gate stays on the money-path apply** (PR merge). Everything else — fetch,
compute, select, tier, materialize, sign, deploy — is automated mechanics.

## Pricing basis change (money path) — OpenRouter removed the liquidity input

OpenRouter restructured its endpoints API: it **removed per-endpoint
`completion_tokens_last_30d`** (also `max_prompt_tokens`, `uptime_last_30d`) and
added `perf_last_30m_by_workload` (nested latency/throughput percentiles +
`request_count`) and `supports_tool_choice`. The engine's market peg was a
**liquidity-weighted median weighted by 30-day token volume** — with that input
gone, every endpoint failed the liquidity filter and **no model could be priced**.

There is no replacement for global per-endpoint 30d volume: the endpoints API no
longer exposes it, and the "user activity grouped by endpoint" analytics API is
**account-scoped** (our own usage, needs a management key), not market-wide.

**Adaptation (implemented):** peg to the market with an **unweighted median over
active (`status:0`) paid endpoints** — each eligible endpoint counts once, so no
endpoint can move the pegged price by inflating its API-reported activity. Only
the `perf_last_30m_by_workload.text_generation.request_count` (a 30-*minute* text
request count) gates ELIGIBILITY: a policy field `min_endpoint_request_count_30m`
(default **30**, operator-tunable) is the anti-thin-liquidity floor (a
single-request endpoint is not liquid in a money-path sense). The `liquidity_filter`
provenance is renamed honestly (`liquidity_signal:
"openrouter_request_count_last_30m"`, `price_median_method:
"unweighted_over_active_endpoints"`, `minimum_request_count_last_30m`,
`request_count_last_30m`), the snapshot records `skipped_free_ranked_models` so the
observed cohort shortfall is auditable (`observed + skipped == requested`), and the
policy version is bumped to `openrouter-market-feeds-v0.13.0`. `validate_snapshot`
re-derives and cross-checks the unweighted median; `catalog-release.py` delegates
its release-side replay to that same validator (single source of truth). This is a
money-path methodology change and goes through the 3-lane audit.

**Live evidence (2026-09-18, valid key):** 40/42 rows now `active_priced`.
`gpt-oss-120b` unweighted-median completion was **$0.36/Mtok** on that snapshot
(Google endpoint, 47.7k reqs/30m) vs the deployed feed's stale $0.136 → ~$0.29/Mtok
after undercut. Note this corrects the brief's $0.60 figure ($0.17 was a
low-traffic provider). Demand-dominant rows are closed-weight frontier
models (deepseek-v4-flash 50T tok, gpt-5.6, claude, gemini) — not MLX-servable, so
they are demand context, not catalog candidates.

## `propose` mode (implemented) — yield-first over the servable universe

Cross-checking a reference set of high-earning MLX-served models against the
OpenRouter dry-run (2026-09-18) showed the **demand-rank entry point is the wrong
universe**: the best-yield servable models — Qwen `a3b`/27B at **$1–2.2/Mtok**,
GLM-4.5-Air, Mistral-Small, Gemma-3-27B — sit **outside** OpenRouter's top-50
demand rank, yet OpenRouter prices them all by id. Selecting from the top-50 would
*miss the best earners*; the frozen catalog serves the low-yield tail
(gpt-oss-20b $0.14, gemma-4-26b $0.30).

So the engine gained a `propose` subcommand that flips to **yield-first over an
explicit candidate universe**:
1. Candidate universe: an explicit `--candidates` list, or the OpenRouter
   `/models` catalog filtered to open-weight vendors (`select_open_weight_candidates`).
2. Price each model **by id** via `/endpoints` (the unweighted median over distinct providers),
   independent of demand rank.
3. Gauge demand from summed 30m `request_count` (`model_demand_activity`).
4. Resolve MLX servability + residency via the HF resolver
   (`openrouter_mlx_candidates.resolve_row`) — fail-closed to `review` only; a
   vision-language pipeline or missing build is excluded with a reason.
5. Gate on yield floor, demand floor, servability, and RAM-tier fit
   (`assign_ram_tier`, tiers 32/48/64/96/128/192/256 GB, 4 GB safety margin);
   rank by yield within tier; apply the policy undercut to the proposed price.
6. Emit `openrouter-catalog-proposal` (selected + an excluded audit trail). It
   **never applies, signs, or deploys** — it is the reviewable "select" step.

Live proof (2026-09-18): a 12-model candidate run selected `qwen3-30b-a3b-2507`
(32 GB, $0.30→$0.24, 42.7k reqs), `glm-4.5-air` (96 GB, $0.85→$0.68), and
`gpt-oss-120b` (96 GB, 364k reqs); it correctly excluded the vision-flagged Qwen
3.5/3.6/3.8 and Gemma-3/4 (need a human text-tower confirmation) and the
sub-floor-yield models. `achievable_tps` (the revenue/sec multiplier) is still
bench-gated and composes with SPEC-038; `propose` ranks by yield within tier as
the honest first cut.

## Build plan (split, per GOAL)

**PR 1 (this branch) — design + blocking fixes + working proposer:**
1. Design doc (this file).
2. Blocking fix #1: `:free` fail-closed → **skip `:free`-only ranked models with a
   logged reason**, keep strict fail-closed for genuine ambiguity/schema errors
   (`resolve_rankings_to_catalog`, engine L533-608). Regression test.
3. Blocking fix #2: sync the valid `sk-or-v1-…` key into the operator's canonical
   secret location (Mac + Pearl, 0600, no newline) + document `gh secret set
   OPENROUTER_API_KEY` for CI. Verify HTTP 200; **never print/commit the key**.
   (Note: the repo reads only `OPENROUTER_API_KEY` env; the "operator-secrets"
   path is a host-local convention, not repo machinery — verify host state first.)
4. Selection/servability + tiering layer: extend nomination beyond the 10-model
   allowlist using the HF probe, assign `min_ram_gb`/`min_bandwidth_tier`/`rate_class`,
   rank within tier by earnings. Emit a proposed best-in-class catalog.
5. Live fetch→compute→select on the valid key + real proposal (gpt-oss-120b
   priced to ~market) as evidence. Tests: `test_openrouter_pricing_engine`,
   receipt suite, `test_catalog_artifact_feed`, `make test-dist`.

**PR 2 (this branch) — propose loop, not auto-apply:**
6. Scheduled `propose` workflow opens a **docs-only** PR under
   `docs/research/openrouter-snapshots/` when the proposal digest is new.
   SPEC-023: `propose` NEVER applies, signs, mints a `rate_class`, or feeds
   `catalog-release`. Recommendable promotion stays an explicit §16 operator
   decision. The Wednesday restamp job keeps its content-continuity guard.
   Fail-loud 401 / stale-snapshot alarm: `openrouter-fetch-health-alarm.yml`
   plus `scripts/check-openrouter-fetch-health.py`. CI secret:
   `gh secret set OPENROUTER_API_KEY` (never print/commit the key).

## Non-goals / guardrails

- No billing/`RateFor` changes; no `default`-row or globals changes.
- No catalog change smuggled through the restamp cron (its guard aborts on diff).
- Bench gates carry **honest provenance** (`bench_gate.provenance.source`), not the
  stale `measured_single_host` "M5 32GB" numbers, for any model we newly gate.
- Secret never in a diff (secret-preflight hook); key verified only via HTTP 200.
