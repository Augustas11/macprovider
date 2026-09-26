Architecture-review the complete uncommitted M6 promotion-economics diff in /Users/augstar/macprovider-1646-rest against HEAD.

Scope includes these untracked files:
- scripts/measure_cb_promotion_economics.py
- scripts/tests/test_measure_cb_promotion_economics.py
- docs/runbooks/continuous-batching-m6-promotion-economics-2026-09-26.md

Assess whether the evidence boundary is honest and fit for the #1646 campaign: a deterministic offline modeled proxy derived from the checked-in final matrix and catalog rate card, not ledger settlement and not a live Gate A5 measurement. The matrix only preserves median prompt tokens per request and aggregate completion tokens, while SPEC-005 settles and rounds per request. The tool must keep that limitation explicit, keep rate-card projection-hash validation distinct from signature verification, bind same-L_target serial controls, and support only the conclusion warranted by mixed economics plus severe TTFT growth. It must not authorize continuous_batching:on or alter live state.

Find boundary violations, invalid assumptions, evidence/provenance gaps, conclusions stronger than inputs support, unnecessary coupling, and missing safeguards/tests. Rank each finding CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line evidence and an actionable fix. If there are no CRITICAL/HIGH/MEDIUM findings, say PASS and list LOW/INFO separately. Do not edit files.
