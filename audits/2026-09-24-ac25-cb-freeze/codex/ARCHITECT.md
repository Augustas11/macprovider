## Lane: ARCHITECTURE (spec conformance, contracts, rollout safety)

Check:
- SPEC-038, SPEC-039, and SPEC-001 text versus the code, including
  `specs/CONFORMANCE.json` and `AUTHORITY.json` consistency.
- FR-CB10 tuple fail-closed behavior.
- Canary vs on vs off semantics.
- First-turn-only hybrid scope enforcement.
- Coupling of the new knobs.
- Whether the one-tuple canary enable is safe to ship on a signed candidate:
  rollback path and what an operator must set.
