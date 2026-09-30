# Catalog Release Train — signed SPEC-023 catalog content

**This file tracks signed catalog-content and pricing rollouts.** It is the
release-train companion to `docs/releases/cli-release-train.md` and
`docs/releases/coordinator-release-train.md`; the operational lane selection
and commands stay in `docs/runbooks/catalog-release-decision-tree.md`.

Update this file when a catalog-content or rows-only pricing PR merges, when a
signed content release goes live, or when a rollout is deliberately held behind
another gate.

## Live on Pearl

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
