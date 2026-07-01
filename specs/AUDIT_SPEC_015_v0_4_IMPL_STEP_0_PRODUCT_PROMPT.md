# AUDIT_SPEC_015_v0_4_IMPL_STEP_0_PRODUCT_PROMPT

You are auditing Step 0 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4` using the Claude subscription
CLI, not an API.

Scope:

- `implementation-notes-spec-015-v0-4.md`
- `specs/SPEC-015-receipts.md`
- `specs/SPEC-022-verified-model-settlement.md`

Audit as a product design critic. Determine whether Step 0 keeps product
claims honest before implementation begins.

Required checks:

1. The notes frame SPEC-015 v0.4 as the first full-product receipt trust floor,
   not as a beta-only shortcut.
2. The notes do not overpromise model-hash anti-tamper guarantees.
3. The notes do not imply buyers can already receive SPEC-022 enforce-mode
   money settlement before SPEC-022 work lands.
4. The Swift baseline failure remains visible enough for launch-risk tracking.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
