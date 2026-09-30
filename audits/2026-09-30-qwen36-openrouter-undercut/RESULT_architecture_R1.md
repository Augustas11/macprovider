Architecture status: **BLOCK**

### HIGH — Malibu enters its own liquid-median reference

File: [openrouter_pricing_engine.py:780](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:780), [openrouter_pricing_engine.py:787](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:787)

Failure scenario: `excluded_provider_names` removes Malibu only from `listing_floor`; the endpoint is still appended to `priced`. Once Malibu has sufficient activity, its previous price can become the lower median and be undercut again. A two-provider reproduction proposed 40,000/532,000 credits from Malibu’s own 50,000/665,000 listing. Repeated releases produce a self-referential downward loop; another undercutter can create a mutual race-to-bottom.

Fix: exclude own providers from the rule-4 median for `openrouter_listed` rows, bind that exclusion into `liquidity_filter`, and enforce the distinct-provider quorum after exclusion. Add two- and three-provider feedback-loop tests.

### HIGH — The 25% guard is derived from the same poisonable median

File: [openrouter_pricing_engine.py:801](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:801), [openrouter_pricing_engine.py:1707](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:1707)

Failure scenario: with the configured two-provider quorum and lower median, one active near-zero listing plus one honest provider makes the near-zero listing the median. The 25% floor then also approaches zero. A reproduction passed at 80 prompt and 80 completion credits instead of failing closed. The existing test at [test_openrouter_pricing_engine.py:1613](/Users/augstar/macprovider-qwen36-price/scripts/tests/test_openrouter_pricing_engine.py:1613) covers only an inactive dumper against an otherwise healthy median.

Fix: make the safety reference independent of the cheapest listing—require at least three non-excluded liquid providers, exclude the cheapest/floor-setting provider from the reference median, and/or anchor against the prior signed rate or an absolute operator floor.

### MEDIUM — The configured floor is checked against the cap candidate, not the final selected rate

File: [openrouter_pricing_engine.py:1702](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:1702), [openrouter_pricing_engine.py:1713](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:1713)

Failure scenario: policy validation allows `min_fraction_of_liquid_price` through 100%, but the code validates `cap_credits` before selecting `min(rule-5 mint, cap)`. With a 90% floor, the engine accepted the ordinary 80%-of-median mint—800,000 credits against a required 900,000 minimum.

Fix: compute the final selected credits first and compare those credits against `floor_credits`. Add coverage above the normal 80% rule-5 mint.

### MEDIUM — Cheapest-quote and schema restatements remain contradictory

Files: [openrouter-pricing-engine.md:108](/Users/augstar/macprovider-qwen36-price/docs/runbooks/openrouter-pricing-engine.md:108), [openrouter-pricing-engine.md:113](/Users/augstar/macprovider-qwen36-price/docs/runbooks/openrouter-pricing-engine.md:113), [openrouter-pricing-engine.md:234](/Users/augstar/macprovider-qwen36-price/docs/runbooks/openrouter-pricing-engine.md:234), [SPEC-023:3336](/Users/augstar/macprovider-qwen36-price/specs/SPEC-023-installer-autotune-recommend.md:3336)

Failure scenario: the runbook still says normalization and broad-fleet pricing use the cheapest active provider, documents snapshot schema 5, and the risk register still says cheapest-print is forbidden without the rule-5a exception. Operators can consequently validate against the wrong invariant.

Fix: consistently state “rule-4 lower median as the base; cheapest listing only as rule-5a’s one-way cap,” document schema 6 and `listing_floor`, and update the risk-register restatement.

### MEDIUM — R008 conformance traceability is empty

File: [CONFORMANCE.json:2747](/Users/augstar/macprovider-qwen36-price/specs/CONFORMANCE.json:2747)

Failure scenario: the rationale claims rule 5a is implemented with tests, while `implementation` and `tests` remain empty. Governance tooling cannot trace AC-MKT-14..16 to their enforcement or regression coverage.

Fix: map `cheapest_endpoint_pricing`, `validate_listing_floor`, `apply_listing_cap`, `proposed_price`, and the listing-cap tests. The requirement can remain pending until a signed cut exists.

### INFO — Explicit checks with no finding

- Authoring/release separation is intact: no signed rate card or `coordinator.yaml` changed, and the release lane still replays proposal bytes.
- SPEC-005 R011/R013 lockstep remains enforced when a price is published.
- Decimal units, ×1,000,000 conversion, flooring, and string formatting are correct.
- Rule 8 cannot silently drift: [catalog-release.py:910](/Users/augstar/macprovider-qwen36-price/scripts/catalog-release.py:910) forces `default` to copy the minimum-completion proposed row.
- Targeted suite: 88 tests passed.

VERDICT: C=0 H=2 M=3 L=0
