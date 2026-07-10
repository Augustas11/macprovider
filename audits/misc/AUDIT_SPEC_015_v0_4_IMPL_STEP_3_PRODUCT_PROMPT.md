# AUDIT_SPEC_015_v0_4_IMPL_STEP_3_PRODUCT_PROMPT

You are auditing Step 3 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4` using the Claude subscription
CLI, not an API.

Audit as the product design critic lane. Do not edit files.

Scope:

- `implementation-notes-spec-015-v0-4.md` Step 3.
- `specs/SPEC-015-receipts.md` §N.5 through §N.7.
- `specs/SPEC-022-verified-model-settlement.md`.
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Step 3.
- `phase4-coordinator/internal/billing/settlement_output.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/buyer/settlement_output.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/server.go`
- Step 3 tests in `phase4-coordinator/internal/billing/` and
  `phase4-coordinator/internal/buyer/`.

Evaluate whether this step delivers the intended buyer/provider trust product
surface without degrading agentic streaming UX.

Required checks:

1. Streaming remains first-class and OpenAI-compatible for buyer clients; no
   buyer-visible receipt protocol is required.
2. The evidence captured is meaningful for the buyer trust promise: output,
   usage, terminal state, route catalog match, and failover ranges can be
   audited later.
3. The implementation avoids premature claims that providers cannot cheat or
   that money movement is already enforced.
4. Failure modes are explainable for future operations: malformed output,
   timeout, cancellation, provider error, and overlap are distinguishable.
5. The remaining gap to SPEC-022 is clear and bounded: signed provider receipt
   ingestion/verification and settlement enforcement still come later.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
