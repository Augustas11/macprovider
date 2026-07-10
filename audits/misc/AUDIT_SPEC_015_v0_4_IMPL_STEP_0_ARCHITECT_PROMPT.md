# AUDIT_SPEC_015_v0_4_IMPL_STEP_0_ARCHITECT_PROMPT

You are auditing Step 0 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Scope:

- `implementation-notes-spec-015-v0-4.md`
- `specs/SPEC-015-receipts.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
- `specs/SPEC-015-v0-4-audit.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT_AUDIT.md`
- `specs/SPEC-022-verified-model-settlement.md`

Audit as the Codex architect lane. Determine whether Step 0 establishes enough
architectural control to proceed to Step 1 fixtures without premature product
behavior.

Required checks:

1. The notes anchor implementation to the locked spec/prompt and correct
   worktree.
2. The notes preserve Step 1 as a contract/fixture slice before product
   behavior.
3. The notes keep SPEC-022 settlement money movement outside this branch.
4. The baseline failure is characterized in a way that allows later targeted
   verification without losing visibility.
5. No architecture decision in Step 0 contradicts SPEC-015 §N.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
