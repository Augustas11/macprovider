# AUDIT_SPEC_015_v0_4_IMPL_STEP_0_ADVERSARIAL_PROMPT

You are auditing Step 0 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4` using the Claude subscription
CLI, not an API.

Scope:

- `implementation-notes-spec-015-v0-4.md`
- `specs/SPEC-015-receipts.md`
- `specs/SPEC-015-v0-4-audit.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT_AUDIT.md`
- `specs/SPEC-022-verified-model-settlement.md`

Adversarially verify whether Step 0 creates any opening to later ship
settlement receipts without the locked receipt/model/catalog trust floor.

Required checks:

1. Look for ambiguity that could let v0.1/v0.2/v0.3 receipts become
   settlement-capable.
2. Look for wording that could hide the Swift baseline failure or allow broad
   unverified claims later.
3. Look for any accidental authorization of buyer debit, provider credit,
   payout-ready rows, or gateway money movement.
4. Look for missing evidence that would make Step 1 unsafe to begin.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
