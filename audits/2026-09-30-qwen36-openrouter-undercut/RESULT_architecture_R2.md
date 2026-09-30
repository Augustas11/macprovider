  2821	    """Network stage: per candidate, fetch OpenRouter endpoints -> unweighted
  2822	    median price + demand gauge, and resolve MLX servability/residency. A per-candidate
  2823	    error is recorded in the record (surfaced in the proposal's excluded trail),
  2824	    never aborting the whole scan -- a proposal is reviewed by a human."""
  2825	    min_endpoint_requests = policy.get("min_endpoint_request_count_30m", 1)
  2826	    min_distinct_providers = policy.get("min_distinct_providers", 1)
  2827	    max_residency = Decimal(str(max(tiers)))
  2828	    deadline = clock() + generation_timeout_seconds
  2829	    records: list[dict[str, Any]] = []
  2830	    for model_id in candidate_ids:
  2831	        record: dict[str, Any] = {"model_id": model_id, "pricing": None, "demand_request_count_30m": 0, "endpoint_count": 0, "servability": {}}
  2832	        if clock() >= deadline:
  2833	            # The wall-clock budget is exhausted; record the remaining candidates
  2834	            # as skipped (surfaced in the proposal's excluded trail) rather than
  2835	            # running unbounded OpenRouter + HuggingFace probes past the budget.
  2836	            record["servability"] = {"verdict": "error", "reasons": ["scan budget exhausted before this candidate was probed"]}
  2837	            records.append(record)
  2838	            continue
  2839	        url = ENDPOINTS_URL.format(model_id=quote(model_id, safe="/"))
  2840	        try:
  2841	            document = fetch_json(or_client, url, f"endpoints {model_id}", retries=retries, timeout_seconds=timeout_seconds, sleeper=sleeper, deadline=deadline, clock=clock)
  2842	            record["demand_request_count_30m"] = model_demand_activity(document)
  2843	            data = document.get("data") if isinstance(document, dict) else None
  2844	            endpoints = data.get("endpoints") if isinstance(data, dict) else None
  2845	            record["endpoint_count"] = len(endpoints) if isinstance(endpoints, list) else 0
  2846	            record["pricing"] = cheapest_endpoint_pricing(document, model_id, min_request_count_30m=min_endpoint_requests, min_distinct_providers=min_distinct_providers)
  2847	        except EngineError as error:
  2848	            record["servability"] = {"verdict": "error", "reasons": [f"OpenRouter endpoint pricing failed: {error}"]}
  2849	            records.append(record)
  2850	            continue
  2851	        if clock() >= deadline:
  2852	            record["servability"] = {"verdict": "error", "reasons": ["scan budget exhausted before the servability probe"]}
  2853	            records.append(record)
  2854	            continue
  2855	        try:
  2856	            record["servability"] = dict(servability_resolver(model_id, max_residency))
  2857	        except Exception as error:  # servability probe is best-effort; surface, don't abort
  2858	            record["servability"] = {"verdict": "error", "reasons": [f"servability probe failed: {type(error).__name__}: {error}"]}
  2859	        if clock() >= deadline:
  2860	            # The resolver returned after the budget expired; discard its verdict
  2861	            # so a late result cannot enter the proposal.
  2862	            record["servability"] = {"verdict": "error", "reasons": ["scan budget exhausted during the servability probe"]}
  2863	        records.append(record)
  2864	    return records
  2865
  2866
  2867	def command_propose(args: argparse.Namespace) -> int:
  2868	    policy = load_json_file(Path(args.policy), "policy")
  2869	    validate_policy(policy)
  2870	    # Bound the scan before any network work (mirror fetch): a NaN generation
scripts/openrouter_pricing_engine.py:778:    excluded_listing_providers: Sequence[str] = (),
scripts/openrouter_pricing_engine.py:799:    excluded_listing = frozenset(excluded_listing_providers)
scripts/openrouter_pricing_engine.py:1249:            excluded_listing_providers=listing_excluded_provider_names(policy),
scripts/openrouter_pricing_engine.py:2808:def fetch_catalog_records(
scripts/openrouter_pricing_engine.py:2912:    records = fetch_catalog_records(

hook: PostToolUse
hook: PostToolUse
hook: PostToolUse Completed
hook: PostToolUse Completed
collab: Wait
hook: PostToolUse
hook: PostToolUse Completed
codex
Architectural status: **BLOCK**

### MEDIUM

1. [scripts/openrouter_pricing_engine.py:2846](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:2846) — the catalog `propose` path still includes Malibu in its market median.

   Failure scenario: `fetch_catalog_records()` calls `cheapest_endpoint_pricing()` without `excluded_listing_providers`. With Malibu plus one competitor and quorum 2, `propose` treats the market as liquid and can price from Malibu, contradicting SPEC-023’s “own providers never set a market reference” rule. The signed `fetch/compute` path is fixed, but the broader authoring engine is inconsistent.

   Fix: pass `listing_excluded_provider_names(policy)` here and test Malibu plus one competitor becoming illiquid.

2. [scripts/openrouter_pricing_engine.py:893](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:893), [scripts/openrouter_pricing_engine.py:900](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:900), [scripts/catalog-release.py:867](/Users/augstar/macprovider-qwen36-price/scripts/catalog-release.py:867) — `listing_floor` is internally re-derivable, but still not authenticated against the fetched endpoint set.

   Failure scenario: remove the inactive Darkbloom entry from `listing_floor.listings`, recompute the minima and unkeyed `content_digest`, then run validation and release replay. Both accept it because they only verify consistency within the modified snapshot. I reproduced acceptance with the proposed Qwen price changing from `47500/665000` to `95000/800000`, no longer below the omitted real Darkbloom listing.

   Thus the round-1 snapshot-tampering finding is not actually closed; release replay reproduces the same compromised named bytes rather than independently proving the OpenRouter observations.

   Fix: retain and bind a separately authenticated/raw endpoints artifact, or sign/attest the fetch result before proposal authoring. Re-derive schema-6 listings from that independently bound artifact during compute and release replay.

3. [scripts/openrouter_pricing_policy.json:338](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_policy.json:338), [scripts/openrouter_pricing_engine.py:824](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:824), [scripts/openrouter_pricing_engine.py:1812](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:1812) — the 25% guard still grants unliquid listings a large unilateral pricing lever and does not fully prevent a multi-undercutter race.

   Failure scenario: a single zero-activity listing slightly above `0.25 / 0.95` of the independent median binds automatically and can reduce the rate by nearly 75% without acknowledgement. Two sufficiently low liquid undercutters can also dominate the lower-median reference after only the cheapest provider is removed, allowing their prices—and Malibu’s cap—to ratchet downward together.

   A truly near-zero listing now safely holds the row, so silent near-zero repricing is fixed. The remaining control is nevertheless inadequate against a dumped but carefully selected listing, and it preserves a row-level release-denial lever.

   Fix: require a floor-setting listing to be liquid and persistent across independent snapshots before it binds automatically. Otherwise require acknowledgement. Anchor maximum downward movement to the prior signed rate or a separately stable reference, and use a trimmed reference that cannot be controlled by the next-lowest undercutter.

### LOW

4. [specs/SPEC-023-installer-autotune-recommend.md:371](/Users/augstar/macprovider-qwen36-price/specs/SPEC-023-installer-autotune-recommend.md:371), [specs/SPEC-023-installer-autotune-recommend.md:388](/Users/augstar/macprovider-qwen36-price/specs/SPEC-023-installer-autotune-recommend.md:388) — historical rule restatements still say cheapest-print is forbidden “as the published rate” without the rule-5a carve-out.

   Failure scenario: an operator following the change-log restatement concludes that any cheapest-listing-derived published rate is non-compliant, while current §3.3.2 explicitly permits it as a one-way cap.

   Fix: annotate both statements: cheapest-print remains forbidden as the rule-4 base, with the v0.22.0 rule-5a cap as the sole exception.

### Round-1 disposition

Fixed:

- Malibu is excluded from the signed `fetch/compute` median, quorum, and floor.
- The guard removes the floor-setting provider and checks the final selected rate.
- Partial-free listings and zero-price axes now hold safely.
- Missing/null floor provenance and policy-exclusion drift fail closed.
- Main normative rule 4/5a text and R008 conformance mappings are present.
- Qwen units and flooring are correct: `47500/665000/11875`.
- No signed rate card or `coordinator.yaml` changed. SPEC-005 R011/R013 publication lockstep remains in the release lane.
- Release replay rejects a held recommendable row, and [catalog-release.py:910](/Users/augstar/macprovider-qwen36-price/scripts/catalog-release.py:910) preserves rule 8 by requiring `default` to copy the minimum-completion proposed row.

Not fully fixed:

- Unliquid-listing economic leverage.
- Snapshot authenticity against omitted/replaced upstream listings.
- Every cheapest-quote-ban restatement.
- Own-provider exclusion in the proposal-only catalog scan.

Validation: all 94 targeted pricing-engine tests passed; `git diff --check origin/main...HEAD` passed. The internally consistent snapshot-removal reproduction also passed validation, confirming finding 2.

VERDICT: C=0 H=0 M=3 L=1.
