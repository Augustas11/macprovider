# AUDIT_SPEC_015_v0_4_IMPL_STEP_0_CODE_PROMPT

You are auditing Step 0 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Scope:

- `implementation-notes-spec-015-v0-4.md`
- `specs/SPEC-015-receipts.md`
- `specs/SPEC-015-v0-4-audit.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT_AUDIT.md`
- `specs/SPEC-022-verified-model-settlement.md`

Audit as the Codex code lane. Determine whether Step 0 correctly records the
implementation baseline and whether any code-readiness issue blocks Step 1.

Required checks:

1. The notes prove the worktree/branch is not local `main`.
2. The notes prove SPEC-015 is locked at v0.4.2 and both SPEC and BUILD IMPL
   audits are already at 0 critical / 0 high / 0 medium.
3. The notes preserve the SPEC-022 boundary: no buyer final debit,
   provider-positive settlement, payout readiness, or gateway money movement is
   in scope for SPEC-015 implementation.
4. Baseline test outcomes are explicit, including the reproducible Swift test
   failure and why it is treated as pre-existing.
5. No product behavior is changed by Step 0.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
