## Lane: ARCHITECTURE (spec conformance, rollout)

Check:
- The SPEC-038 v0.2.6 FR-CB6 and AC-6b text against the code.
- Whether "equal in distribution" plus neighbour independence is a sound,
  testable contract.
- Ignoring penalties: whether that is consistent with the serial path, and
  what happens if the serial path starts honoring them.
- `CONFORMANCE.json` and the spec index.
- Rollout safety on a live canary: a signed candidate and revision-bound
  acceptance, which are unchanged.
