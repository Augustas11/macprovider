## Lane: ARCHITECTURE (spec conformance, contracts, rollout)

Check:
- SPEC-024 v0.2.5 FR-CI2, SPEC-037 v0.1.4 and SPEC-038 v0.2.7 against the
  code; `CONFORMANCE.json` and the spec index.
- Whether the checkpoint design (ChatML `<|im_start|>` heuristics) is scoped
  and fail-safe for non-ChatML or other hybrid models.
- Interaction with the AC-26 fence, speculative decoding, the cold tier and
  warm swap.
- Whether committing materialized entries from the batched path stays inside
  SPEC-038's scheduler-ownership rules.
- Rollout safety on a live canary.
