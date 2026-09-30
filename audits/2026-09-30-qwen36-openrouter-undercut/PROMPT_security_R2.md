# security review — Qwen3.6 OpenRouter listing undercut (SPEC-023 v0.22.0 rule 5a)

Repo: /Users/augstar/macprovider-qwen36-price, branch pricing/qwen36-openrouter-undercut (commits 8bbf777e4 + c31ecbbb9). Review the FULL diff `git diff origin/main...HEAD` as a security reviewer. Governing: specs/SPEC-023-installer-autotune-recommend.md §3.3.2 (R008), SPEC-005 billing (R011/R013 rate-card lockstep), CONFORMANCE.json; docs/runbooks/openrouter-pricing-engine.md, catalog-release-decision-tree.md.

Change: pricing engine (scripts/openrouter_pricing_engine.py + scripts/openrouter_pricing_policy.json) gains rule 5a — for policy entries flagged openrouter_listed, cap prompt and completion at floor(cheapest active paid OpenRouter listing x (1-0.05) x 1e6) credits, strictly below every listing; fail closed if the cap is < 0.25 x median-derived price; snapshot schema 6 gains optional pricing.listing_floor; own provider names ("Malibu") excluded from the floor. Qwen3.6-35B-A3B flagged -> 47500/665000/11875 credits ($0.0475/$0.665/$0.011875 per M). No signed rate-card or coordinator.yaml edit in this branch.

Focus: money-path manipulation: can an adversary listing on OpenRouter push our price down arbitrarily or DoS pricing runs; tamper detection of listing_floor; exclusion-list spoofing (a provider named similar to Malibu); fail-closed behavior.

Also evaluate explicitly: once Malibu is itself listed on OpenRouter, does our own endpoint enter the MEDIAN computation (exclusion only applies to the floor) and create a self-referential downward price loop or a race-to-bottom against another undercutter (e.g. Darkbloom also undercutting)? Is the min_fraction_of_liquid_price fail-closed floor adequate against a dumped/malicious or erroneous OpenRouter listing (a single provider listing at near-zero)? Rounding/units correctness (credits vs USD, floor direction, string formatting), and whether the default-row rule 8 invariant can be violated.

Output: findings with severity CRITICAL/HIGH/MEDIUM/LOW/INFO, file:line, failure scenario, fix. End with: VERDICT: C=<n> H=<n> M=<n> L=<n>.


ROUND 2: round-1 findings are in audits/2026-09-30-qwen36-openrouter-undercut/RESULT_{code,security,architecture}_R1.md (and full lane outputs in .omc/artifacts/ask/). Fixes are commit c31ecbbb9. Verify each R1 finding is actually fixed, then review the FULL combined diff fresh for new issues.
