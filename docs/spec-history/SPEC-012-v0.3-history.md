# SPEC-012 v0.3 split and audit history

This non-normative record preserves the evolution of the 2026-06-06 wide-scope
Provider Model Catalog and Warm Swap draft. Git history before the governance
foundation contains the full v0.1-v0.3 change narratives.

The original draft combined four surfaces: provider model capability/catalog
identity, operator-pushed local warm swap, coordinator-initiated demand-pull
swap with buyer cold-model visibility, and recommended-model discovery. Review
split those responsibilities as follows:

- SPEC-010 owns provider model capability and catalog identity.
- SPEC-011 owns operator-pushed, binary-local warm swap.
- SPEC-012 retains coordinator `set_model`, demand-pull cold wake/parking,
  buyer-visible cold models/`model_not_warm`, and swap-status visibility.
- SPEC-013 owns local autotune recommendations.

The 2026-06-26 open-questions triage marked the former Phase 2 and Phase 3
outlines subsumed by SPEC-011 and SPEC-010/SPEC-013 respectively. They are not
part of the current SPEC-012 authority.

The retained coordinator-driven contract is not locked or implemented. The
round-three record in
[`audits/spec-012/SPEC-012-source-audit-history.md`](../../audits/spec-012/SPEC-012-source-audit-history.md)
reports 1 CRITICAL, 12 MAJOR, and 3 MINOR findings and a NOT READY TO LOCK
verdict. The unresolved SPEC-008 hash-field conflict and other gaps are tracked
as `DECISION_REQUIRED` under issue #614.
