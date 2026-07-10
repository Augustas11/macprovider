# AUDIT_SPEC_015_V0_4_ARCHITECT_PROMPT

You are auditing `specs/SPEC-015-receipts.md` from the ARCHITECT lane.

Audit target: v0.4 deltas only, centered on the new `0.4.0-draft` header
and §N "Settlement-capable receipts". Treat v0.1/v0.2/v0.3 locked history as
fixed unless a v0.4 clause contradicts it.

Controlling context:

- `specs/SPEC-015-receipts.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PROMPT.md`
- SPEC-022 v0.1.4 requirements quoted or referenced by §N

Lock bar: 0 critical, 0 high, 0 medium.

Focus:

- Is this the right SPEC-015 boundary to unblock SPEC-022 later?
- Are responsibilities assigned to the right layers: provider issuance,
  coordinator ingestion/storage, verifier semantics, gateway streaming
  compatibility, and future SPEC-022 settlement integration?
- Does the spec separate receipt-profile capability from SPEC-022 money
  movement?
- Are streaming delivery, terminal states, chargeability, failover, route
  snapshots, and verifier outcome mappings architecturally coherent?
- Does v0.4 update or supersede old open questions/history clearly enough to
  avoid contradictory implementation instructions?

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`ARCH-C-1`, `ARCH-H-1`, `ARCH-M-1`, etc.). Cite
SPEC text and concrete repo/spec evidence.
