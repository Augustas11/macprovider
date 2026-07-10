# AUDIT_SPEC_015_V0_4_CODE_PROMPT

You are auditing `specs/SPEC-015-receipts.md` from the CODE lane.

Audit target: v0.4 deltas only, centered on the new `0.4.0-draft` header
and §N "Settlement-capable receipts". Treat v0.1/v0.2/v0.3 locked history as
fixed unless a v0.4 clause contradicts it.

Controlling context:

- `specs/SPEC-015-receipts.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PROMPT.md`
- SPEC-022 v0.1.4 requirements quoted or referenced by §N

Lock bar: 0 critical, 0 high, 0 medium.

Focus:

- Is the v0.4 tuple strict, implementable, and sufficiently typed?
- Does v0.4 preserve v0.1/v0.2/v0.3 verifier compatibility while adding
  `receipt_version: "4"` correctly?
- Are route snapshot, attempt identity, prompt/output hash, usage, timestamp,
  model hash, and receipt-key bindings concrete enough to implement?
- Is streaming delivery implementable without breaking OpenAI-compatible SSE
  clients?
- Are terminal states, chargeability rows, and settlement outcome mappings
  deterministic enough for implementation?
- Are acceptance criteria complete and runnable enough to drive BUILD IMPL?

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`CODE-C-1`, `CODE-H-1`, `CODE-M-1`, etc.). Cite
SPEC text and concrete repo/spec evidence.
