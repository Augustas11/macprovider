LANE: ARCHITECTURE REVIEW.

Focus:
- Decoupling the fused pin from native-MTP R015 (SPEC-048 0.1.23): is the new R003 review gate (ordinary-path qualification + this audit) coherent with MTP-3's exception rules, SPEC-023 R024's same-setting rule, and CONFORMANCE; does any SPEC, CONFORMANCE rationale, UPSTREAM_WATCH field, or checker still describe the retired 1...7 flattened-token envelope or require R015 for the pin.
- The SPEC-048 rule that a decode row must not move between kernels as the batch changes: is it enforced by the implementation for every serving shape, and does any other component (classic speculative decoding, KV cold tier, warm swap, self-test oracle, autotune measurement) depend on the old behaviour.
- Version and changelog integrity after the main merge (SPEC-023 renumbered v0.22.9-v0.22.11; SPEC-048 0.1.23), and whether CONFORMANCE verdicts stay pending where evidence is missing.
- Release/rollback: the kill switch, KVBuildIdentity change (expected cold-tier misses), and what an operator must do if the fused path misbehaves in production.
- Whether merging this PR with native MTP default-off leaves any half-enabled path (status fields, admission parsing, coordinator-visible capability) that could advertise native MTP or change buyer-visible behaviour.
