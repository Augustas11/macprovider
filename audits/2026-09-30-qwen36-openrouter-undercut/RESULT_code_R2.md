codex
Targeted tests pass: all 14 rule-5a tests and three schema-v5 compatibility tests are green. One round-1 concern still needs adversarial verification: whether a self-consistent rewrite of the retained listing evidence can bypass validation, since the snapshot digest is not authenticated.
hook: PreToolUse
hook: PreToolUse Completed
exec
/bin/bash -lc "PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from scripts import openrouter_pricing_engine as e
from scripts.tests.test_openrouter_pricing_engine import synthetic_production_market_snapshot, qwen36_live_endpoints_2026_09_30, QWEN36
s = synthetic_production_market_snapshot(endpoint_overrides={QWEN36: qwen36_live_endpoints_2026_09_30()})
r = next(x for x in s['rows'] if x['source_model_id'] == QWEN36)
f = r['pricing']['listing_floor']
d = next(x for x in f['listings'] if x['provider_name'] == 'Darkbloom')
print('before', f['prompt_usd_per_mtok'], f['completion_usd_per_mtok'], d['request_count_last_30m'])
d['prompt_usd_per_mtok'] = '0.5'
d['completion_usd_per_mtok'] = '0.8'
f.update(e.listing_axis_minima(f['listings']))
f['listings'] = sorted(f['listings'], key=e.listing_sort_key)
s['content_digest'] = e.sha256_prefixed(e.snapshot_digest_payload(s))
e.validate_snapshot(s)
print('accepted', f['prompt_usd_per_mtok'], f['completion_usd_per_mtok'])
PY" in /Users/augstar/macprovider-qwen36-price
 succeeded in 91ms:
before 0.05 0.7 None
accepted 0.1 0.8

hook: PostToolUse
hook: PostToolUse
hook: PostToolUse Completed
hook: PostToolUse Completed
hook: PreToolUse
hook: PreToolUse Completed
exec
/bin/bash -lc "PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
from scripts import openrouter_pricing_engine as e
from scripts.tests.test_openrouter_pricing_engine import fixture
p = fixture('legacy-policy-2026-08-10.json')
p['models'][0]['openrouter_listed'] = True
e.validate_policy(p)
print('legacy policy with openrouter_listed accepted')
PY" in /Users/augstar/macprovider-qwen36-price
 succeeded in 696ms:
legacy policy with openrouter_listed accepted

hook: PostToolUse
hook: PostToolUse
hook: PostToolUse Completed
hook: PostToolUse Completed
collab: Wait
hook: PostToolUse
hook: PostToolUse Completed
hook: PostToolUse
hook: PostToolUse Completed
hook: PreToolUse
hook: PreToolUse Completed
exec
/bin/bash -lc 'PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_openrouter_pricing_engine' in /Users/augstar/macprovider-qwen36-price
 succeeded in 1172ms:
..............................................................................................
----------------------------------------------------------------------
Ran 94 tests in 1.137s

OK

hook: PostToolUse
hook: PostToolUse
hook: PostToolUse Completed
hook: PostToolUse Completed
collab: Wait
hook: PostToolUse
hook: PostToolUse Completed
codex
## Findings

### MEDIUM

1. [scripts/openrouter_pricing_engine.py:943](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:943) — Snapshot listing evidence remains self-authenticating.

   Failure scenario: remove Darkbloom from `listing_floor.listings`, recompute the minima and unkeyed `content_digest`, and validation accepts the modified snapshot. A reproduced proposal changed from `47500/665000` to `95000/800000`. Removing a zero-axis listing similarly bypasses the required hold. This leaves the round-1 snapshot-tampering finding unresolved and contradicts AC-MKT-17’s “removed listing fails validation” expectation.

   Fix: retain independently bound raw endpoint-response evidence and rederive listings from those bytes during compute/release replay. Add tests that remove the cheapest and zero-axis listings while updating all derived fields and the digest.

### LOW

2. [scripts/openrouter_pricing_engine.py:1357](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:1357) — Legacy policies accept `openrouter_listed`, but schema-v5 computation ignores it.

   Failure scenario: adding `"openrouter_listed": true` to a valid legacy policy passes validation. The legacy path then calls uncapped `proposed_completion_price` at [line 2096](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:2096), silently providing no rule-5a protection.

   Fix: reject `openrouter_listed` in legacy policy models, keeping existing schema-v5 policies compatible while preventing mixed-generation semantics. Add a rejection test.

## Round-1 verification

Fixed:

- Malibu is excluded before median, quorum, and floor computation; the self-referential loop is closed.
- The guard median excludes the floor-setting provider and rechecks quorum.
- Partially free listings are retained, and a zero axis holds the row.
- The guard checks the final selected rate rather than only the cap.
- Missing floors and exclusion-policy mismatches fail closed.
- Documentation and R008 conformance mappings were corrected.
- Units, `ROUND_FLOOR`, decimal formatting, and `47500/665000/11875` output are correct.
- Schema-v5 behavior remains covered for valid legacy policies.
- Rule 8 remains enforced by [scripts/catalog-release.py:910](/Users/augstar/macprovider-qwen36-price/scripts/catalog-release.py:910).
- No signed rate card or `coordinator.yaml` changed, so R011/R013 publication lockstep is not crossed.

Not fully fixed:

- Snapshot evidence integrity, as finding 1.
- The single-listing manipulation risk is bounded, not eliminated. With the configured `0.25` guard, one listing just above `0.25 / 0.95 ≈ 26.32%` of the independent median can still force roughly a 75% reduction without acknowledgement. A near-zero quote is held, but this threshold is not a strong defense against a deliberately calibrated dump.
- Another undercutter can cause a downward sequence until the 25% guard is reached. Malibu itself no longer participates when its provider name is exactly `"Malibu"`.
- Own-provider exclusion is exact display-name matching at [scripts/openrouter_pricing_engine.py:821](/Users/augstar/macprovider-qwen36-price/scripts/openrouter_pricing_engine.py:821); a renamed provider identity would reintroduce self-reference until policy is updated.

Validation evidence:

- All 94 pricing-engine tests passed.
- The 14 dedicated rule-5a tests passed.
- Three targeted schema-v5 compatibility tests passed.
- `git diff --check` passed.
- Architecture status: WATCH.
- Recommendation: REQUEST CHANGES.

VERDICT: C=0 H=0 M=1 L=1.
