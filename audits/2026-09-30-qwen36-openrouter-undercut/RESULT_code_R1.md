## Findings

### HIGH

1. [scripts/openrouter_pricing_engine.py:780](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:780) — Malibu remains in the liquid median.

   Failure scenario: exclusion applies only to `listed`; Malibu is still appended to `priced` at line 787 and can become the lower median at lines 803–804. With active Malibu at `47500/665000` and Darkbloom at `50000/700000`, the next compute produced `38000/532000`. Repeated runs continue the 20% downward ratchet because the listing cap is non-binding.

   Fix: for `openrouter_listed` rows, exclude own-provider names from both the liquid median and quorum, record that exclusion basis in `liquidity_filter`, and require the provider quorum after exclusion.

2. [scripts/openrouter_pricing_engine.py:1707](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:1707) — the manipulation floor uses the same contaminated lower median.

   Failure scenario: with the supported two-provider quorum, one active malicious or erroneous low quote becomes the lower median. The 25% guard then scales down with that quote and provides no protection. A test with a dumper at `$0.001/$0.002` and an honest provider at `$0.10/$1.00` passed computation and proposed `800/1600` credits.

   An inactive dump fails closed, but the same dump becomes accepted as soon as it reports sufficient activity. This also permits a race-to-bottom between active undercutters.

   Fix: derive the manipulation guard from external liquid quotes after removing the cheapest-listing provider, and require the configured distinct-provider quorum to remain; otherwise fail closed.

3. [scripts/openrouter_pricing_engine.py:780](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:780) — partially free paid endpoints are omitted from the listing floor.

   Failure scenario: an active, non-`:free` endpoint with prompt price `0` and positive completion price is still a paid listing, but the `prompt > 0 and completion > 0` condition drops it entirely. The engine then emitted an `80000` prompt rate despite an external `$0` prompt listing, violating “strictly below every listing.”

   Fix: evaluate each axis independently and fail the whole compute when a non-excluded paid endpoint has a zero price on an axis, because strict undercutting on that axis is impossible.

### MEDIUM

4. [scripts/openrouter_pricing_engine.py:1661](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:1661) — a null `listing_floor` does not bind exclusion provenance.

   Failure scenario: the exclusion-policy mismatch check runs only for an object. On the null path, line 1689 checks only retained liquid candidates. A non-liquid provider excluded during fetch but no longer excluded during compute remains invisible, allowing the snapshot to be reused without undercutting that listing.

   Fix: always retain an object containing `excluded_provider_names`, with nullable per-axis floor fields, and compare exclusions unconditionally during compute.

## Other review results

- Cap units and rounding are correct: `$0.05/$0.70 × 0.95 × 1e6` produces `47500/665000`; cache-hit floors to `11875`.
- v5 snapshot compatibility remains intact.
- Rule 8 is enforced downstream by [scripts/catalog-release.py:910](/Users/augstar/macprovider-qwen36-price/scripts/catalog-release.py:910), which requires `default` to copy all three rates from the minimum-completion proposal row.
- No signed rate-card or `coordinator.yaml` change occurs, so SPEC-005 R011/R013 lockstep is not crossed by this branch.
- All 88 pricing-engine tests passed, but they omit active-self, active-dumper, zero-axis, and null-floor exclusion-change cases.
- Architectural status: BLOCK. Recommendation: REQUEST CHANGES.

VERDICT: C=0 H=3 M=1 L=0
