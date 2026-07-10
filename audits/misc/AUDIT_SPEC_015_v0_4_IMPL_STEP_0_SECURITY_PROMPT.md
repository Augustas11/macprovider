# AUDIT_SPEC_015_v0_4_IMPL_STEP_0_SECURITY_PROMPT

You are auditing Step 0 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Scope:

- `implementation-notes-spec-015-v0-4.md`
- `specs/SPEC-015-receipts.md`
- `specs/SPEC-015-v0-4-audit.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT_AUDIT.md`
- `specs/SPEC-022-verified-model-settlement.md`

Audit as the Codex security lane. Determine whether Step 0 preserves the
money-path and trust-path guardrails before implementation begins.

Required checks:

1. The notes do not weaken the locked receipt trust boundary.
2. The notes do not claim SPEC-015 v0.4 proves malicious providers cannot
   falsify local model-hash measurement.
3. The notes do not authorize SPEC-022 enforce-mode money movement.
4. The Swift baseline failure is not dismissed in a way that could hide a
   security-relevant regression.
5. No secrets, raw receipt material, signatures, raw public keys, prompts, or
   outputs are introduced in Step 0 artifacts.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
