# AUDIT_SPEC_015_v0_4_IMPL_STEP_1_PRODUCT_PROMPT

You are auditing Step 1 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4` using the Claude subscription
CLI, not an API.

Scope:

- `implementation-notes-spec-015-v0-4.md`
- `testdata/spec015/v04_settlement_receipts.json`
- `phase3-binary/Tests/macprovider-cliTests/SPEC015V04SettlementFixtureTests.swift`
- `phase4-coordinator/internal/spec015contract/`
- `phase5-gateway/internal/spec015contract/`
- `phase7-verify/internal/jcs/v04_settlement_fixture_test.go`
- `specs/SPEC-015-receipts.md` §N

Audit as a product design critic. Determine whether the fixture/contract slice
supports the product trust floor without misleading buyers, providers, or
operators.

Required checks:

1. Step 1 is framed as full-product trust-floor infrastructure, not a beta-only
   shortcut.
2. Fixtures/tests do not suggest buyers can already get SPEC-022 enforce-mode
   money settlement before later SPEC-022 work lands.
3. Fixtures/tests preserve streaming as first-class agentic buyer tooling
   rather than treating it as a lower-quality path.
4. Operator/provider-facing implications remain honest: this pins bytes and
   receipts, but does not prove malicious providers cannot falsify local model
   measurement.
5. The Step 0 Swift baseline failure remains visible while Step 1's new Swift
   tests pass.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
