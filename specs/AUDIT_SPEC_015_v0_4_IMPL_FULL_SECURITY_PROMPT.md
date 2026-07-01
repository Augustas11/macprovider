# AUDIT_SPEC_015_v0_4_IMPL_FULL_SECURITY_PROMPT

You are the Codex security audit lane for the full SPEC-015 v0.4.2
implementation.

Worktree: `/Users/augstar/macprovider-impl-spec-015-v0-4`
Branch: `impl/spec-015-v0-4-settlement-receipts`

Scope: read-only security review of the full current worktree diff for
`BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Steps 1 through 8.
Do not modify files.

Required reading:

- `CLAUDE.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
- `specs/SPEC-015-receipts.md` v0.4.2, especially §N and AC-43 through AC-71
- `specs/SPEC-015-v0-4-audit.md`
- `specs/SPEC-022-verified-model-settlement.md`
- `specs/SPEC-005-billing.md`
- `specs/SPEC-008-tier2.md`
- `implementation-notes-spec-015-v0-4.md`
- `specs/AUDIT_SPEC_015_v0_4_IMPL_STEP_{1,2,3,4,5,6,7,8}.md` where present
- `scripts/verify-spec015-v04-step8.sh`

Security invariants:

1. A provider cannot earn positive settlement candidate status by signing a
   receipt that does not match the route-time catalog/model snapshot,
   coordinator-observed output hash, prompt hash, usage evidence, terminal
   state, attempt identity, account/request/provider identity, receipt key, or
   deadline.
2. Provider-controlled fields cannot extend receipt deadlines, backdate receipt
   arrival, overwrite coordinator-authoritative route/output/usage evidence, or
   create duplicate positive receipt authorization.
3. Legacy receipt versions are not settlement-capable; unknown future versions
   are inconclusive and not payable.
4. Streaming remains OpenAI-compatible and cannot smuggle receipt-only body
   frames into buyer-visible SSE.
5. Transparent failover emits one provider-attempt prefix and overlap/duplicate
   ranges are non-creditable.
6. Audit, verdict, diagnostics, gateway, and buyer surfaces do not expose raw
   receipt envelopes, raw signatures, raw receipt public keys, raw prompts, raw
   outputs, bearer tokens, receipt private keys, raw account scopes, or
   provider-private session/generation identifiers.
7. Buyer/product disclosures do not overclaim malicious-provider model
   self-measurement detection.
8. This diff must not wire SPEC-022 buyer debit, provider-positive settlement,
   payout-ready rows, gateway money movement, or payout idempotency.

Report exploitable or trust-impacting findings, plus material missing tests.
Use severity Critical, High, Medium, Low. Include file/line evidence, attack
scenario, and exact remediation. End with:

Critical: N
High: N
Medium: N
Low: N

Then list validation you ran.
