## Findings

### HIGH — Malibu participates in its own liquid median, enabling a downward repricing loop

File: [scripts/openrouter_pricing_engine.py:787](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:787)

The exclusion at [line 780](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:780) applies only to `listing_floor`; Malibu is still appended to `priced` and participates in the provider-collapsed median.

Failure scenario: in a two-provider market, Malibu’s current listing becomes the lower median. Rule 5 then undercuts that price by 20%. On successive pricing cuts, `$1.00 → $0.80 → $0.64 → …`. Because Malibu is excluded from `listing_floor`, the competing-listing cap can remain non-binding. Another undercutter such as Darkbloom can amplify this into a race-to-bottom.

Fix: for `openrouter_listed` rows, exclude self-provider identities from both the liquid cohort and listing floor, then enforce `min_distinct_providers` over the remaining non-self providers. Add a regression test with Malibu plus one higher-priced competitor.

### MEDIUM — One unliquid listing can force a 75% reduction or DoS the entire compute

Files: [scripts/openrouter_pricing_engine.py:780](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:780), [scripts/openrouter_pricing_engine.py:1708](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:1708), [scripts/openrouter_pricing_policy.json:338](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_policy.json:338)

Every active paid listing enters the floor regardless of activity, age, provider quorum, or stability. With `min_fraction_of_liquid_price = 0.25`, one provider can quote just above `0.25 / 0.95` of the liquid median and force the price to approximately 25% of that median. A still-lower quote deliberately fails the whole compute.

Thus, the floor prevents a price approaching zero, but it still grants one unauthenticated, zero-activity listing a large unilateral money-path and availability lever.

Fix: require persistence across snapshots and a distinct-provider quorum before a listing may bind, or require explicit operator acknowledgement for any cap materially below the liquid median. A near-zero outlier should not be able to indefinitely block all pricing proposals.

### MEDIUM — `listing_floor` cannot be re-derived, so snapshot tampering passes validation

Files: [scripts/openrouter_pricing_engine.py:869](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:869), [scripts/openrouter_pricing_engine.py:893](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:893)

The snapshot discards the full active-listing set. Validation only proves that the recorded floor does not exceed retained liquid quotes. `content_digest` is an unkeyed hash, so someone altering the snapshot can recompute it.

Reproduced:

- True completion floor `$0.70` changed to `$0.30`: validation accepted it and proposed `285000` credits.
- Changed to `$0.85`: validation also accepted it and proposed `800000` credits, which is not below the real `$0.70` listing.

Release replay uses the same snapshot bytes, so it cannot detect either manipulation.

Fix: retain a closed array of every non-excluded active paid listing—or a separately authenticated raw endpoint artifact—and require `listing_floor` to equal the per-axis minimum derived from that evidence during snapshot validation and release replay.

## Additional conclusions

- Similar names such as `Malibu AI` are not excluded because matching is exact; they behave as external competitors and can exercise the MEDIUM finding above. Exact-name impersonation depends on OpenRouter’s uniqueness guarantees, which are not captured here. Prefer an immutable provider identifier over display names.
- Credits/USD conversion, `ROUND_FLOOR`, cache-hit calculation, and decimal formatting are correct for the stated 47,500/665,000/11,875 result.
- Rule 8 remains enforced by [scripts/catalog-release.py:910](/Users/augstar/macprovider-qwen36-price/scripts/catalog-release.py:910). The proposed Qwen completion price is not currently the minimum recommendable completion row, so this branch does not violate the default-row invariant.
- Targeted `OpenRouterListingCapTests`, Python compilation, policy validation, and `git diff --check` passed.

VERDICT: C=0 H=1 M=2 L=0.
