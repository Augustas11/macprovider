# Catalog Release Train — signed SPEC-023 catalog content

> **Current state:** see "Current state — 2026-11-14" below. The older history
> ends at 2026-09-30 and is not rewritten. Per-release activation steps since
> then are recorded in `docs/releases/cli-release-train.md`.

**This file tracks signed catalog-content and pricing rollouts.** It is the
release-train companion to `docs/releases/cli-release-train.md` and
`docs/releases/coordinator-release-train.md`; the operational lane selection
and commands stay in `docs/runbooks/catalog-release-decision-tree.md`.

Update this file when a catalog-content or rows-only pricing PR merges, when a
signed content release goes live, or when a rollout is deliberately held behind
another gate.

## Current state — 2026-11-14

Read from `scripts/ops/catalog-activate.sh status` on 2026-11-14.

- **Live:** `published-2026-11-12-nemotron-3.5-lightning-listed-v283`
  (`live_verified`).
- **Committed on `main`, not activated:**
  `published-2026-11-13-minimax-m3.1-flash-recommendable-v287`, from
  [#2344](https://github.com/Augustas11/macprovider/pull/2344) (`14c223516`).
  It moves `minimaxai/minimax-m3.1-flash` from `listed` to `recommendable`.
  Pending steps: `buyer_ux_conformance`, `catalog_preflight`,
  `catalog_activation`, `canary_bank`, `live_probe` and `gateway_proof`.
  After activation, `buyer_ux_conformance_owed` remains for
  `minimaxai/minimax-m3.1-flash`.
- **`buyer_serving_e2e` owed:** the GLM-5.3-Flash uncensored artifact (since
  `published-2026-11-09-glm53-flash-uncensored-recommendable-v281`) and the
  DeepSeek V4-Flash MXFP4 artifact (since
  `published-2026-10-23-deepseek-v4-flash-recommendable-v1`).
- **Signed release manifest,
  [#2334](https://github.com/Augustas11/macprovider/pull/2334)
  (`d3b136de1`):** a catalog release may ship `release.json.sig`, one Ed25519
  signature over `release.json` (SPEC-023 §3.8). The coordinator code that
  serves it at `/v1/catalog-release`, and its nginx routes, are not live:
  they ride the next Pearl runtime (live is `v1.8.286`). No tracked
  `release.json.sig` exists on `main` at `30fdbe2cf`, so the committed MiniMax
  release carries no manifest signature. #2334 also removes the pre-#2282
  signed-pair, binding-bundle and `signed-pair-plan.py` activation paths.
- **Order:** `scripts/ops/README.md` says catalog activation comes before the
  CLI cut. `cli-release.sh` keeps `candidate_cut` blocked until Pearl serves
  the catalog release on `origin/main`.

## Live on Pearl (2026-09-30, historical)

| Field | Value |
|---|---|
| `autotune/current` | `published-2026-09-25-artifact-hash-correction-v1` |
| Tier-2 catalog | `macprovider-tier2-model-catalog-2026-09-25-artifact-hash-correction-v1` |
| Pricing lane | No post-September-25 rows-only pricing correction is recorded as live in this train. |

Pearl runtime `v1.8.209` was applied through the runtime-only updater on
2026-09-30. The live catalog symlink remained on
`published-2026-09-25-artifact-hash-correction-v1`; #1805 was not activated.

## Pending catalog / pricing rollouts

| Change | Status | Gate |
|---|---|---|
| #1805 pins the OpenRouter-listed Qwen3.6 row behind operator-reviewed advisory market holds: `47,500` prompt, `11,875` cache-hit, and `665,000` completion credits per million tokens. Market evidence may hold the row but must not auto-lower the operator pin. | merged source policy `92d840c3` 2026-09-30; no signed catalog/rate-card rollout yet | **Hold until #1807 completes.** Do not sign or deploy this pricing rollout before the 8 GB / 16 GB fleet demand and catalog-migration issue has completed its acceptance criteria. |

## Rollout rule for #1805

After #1807 is complete, refresh the OpenRouter evidence, review the effective
price diff, and use the catalog-content pricing path in
`docs/runbooks/catalog-release-decision-tree.md`. The signed rollout must be a
reviewed catalog-content/pricing release with the lane's normal preflight,
acknowledgement, journal, SIGHUP, and evidence checks. Do not hand-edit Pearl
pricing, Pearl catalog files, or live provider settings to make #1805 active.

## Evidence

- #1805 merged as `92d840c3472b46ca3525dfcb0e359d26575d5f7f`.
- #1805 validation recorded 551 OpenRouter/catalog Python tests,
  `scripts/test-catalog-release.sh`, `scripts/test-catalog-content-release.sh`,
  and three-lane audit with 0 critical/high/medium findings.
- #1807 is the rollout gate: "Measure model demand and stage the 8GB/16GB
  fleet catalog migration."
