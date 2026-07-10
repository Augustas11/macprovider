# AUDIT_SPEC_015_v0_4_IMPL_STEP_1_SECURITY_PROMPT

You are auditing Step 1 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Audit as the Codex security lane. Do not edit files.

Scope:

- `implementation-notes-spec-015-v0-4.md`
- `testdata/spec015/v04_settlement_receipts.json`
- `phase7-verify/testdata/generator/v04/main.go`
- `phase3-binary/Tests/macprovider-cliTests/SPEC015V04SettlementFixtureTests.swift`
- `phase4-coordinator/internal/spec015contract/`
- `phase5-gateway/internal/spec015contract/`
- `phase7-verify/internal/jcs/v04_settlement_fixture_test.go`
- `specs/SPEC-015-receipts.md` §N

Required checks:

1. Fixtures do not contain raw prompts, raw buyer outputs beyond synthetic
   fixture strings, bearer tokens, private keys, raw receipt envelopes in audit
   notes, or production secrets.
2. Receipt-key IDs use `ed25519-sha256:<64 lowercase hex>` and signatures are
   deterministic test fixtures only.
3. The fixture/tests do not imply v0.1/v0.2/v0.3 receipts are
   settlement-capable.
4. The fixture/tests do not overclaim that model-hash measurement cannot be
   falsified by a malicious provider.
5. No SPEC-022 buyer debit, provider credit, payout-ready, or gateway money
   movement behavior is added.
6. Module-local Go canonicalizers in phase4/phase5 are test-only and do not
   create a production divergence risk for money movement before later steps.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
