# OpenRouter → Best-in-Class Catalog Pipeline (design)

Status: design / pre-implementation. Owner: operator (a11). Target branch:
`feat/openrouter-catalog-pipeline`.

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
  apply mode"). Market price = liquidity-filtered volume-weighted median across
  endpoints; Malibu price = market × `(1 − undercut_fraction 0.20)`
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

**PR 2 (follow-up) — gated deploy loop:**
6. Scheduled proposer workflow (`fetch`+`compute`+select) that opens the proposal
   as a PR/diff; on merge, a gated-apply job runs `catalog-release generate` →
   resign v4 → Pearl deploy. Reconcile with the Wed restamp job (whose
   content-continuity guard blocks catalog changes — the apply must be its own
   job). Add a **fail-loud 401 / stale-snapshot alarm** on the fetch side.

## Non-goals / guardrails

- No billing/`RateFor` changes; no `default`-row or globals changes.
- No catalog change smuggled through the restamp cron (its guard aborts on diff).
- Bench gates carry **honest provenance** (`bench_gate.provenance.source`), not the
  stale `measured_single_host` "M5 32GB" numbers, for any model we newly gate.
- Secret never in a diff (secret-preflight hook); key verified only via HTTP 200.
