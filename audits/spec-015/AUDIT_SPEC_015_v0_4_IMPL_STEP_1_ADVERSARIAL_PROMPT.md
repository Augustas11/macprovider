# AUDIT_SPEC_015_v0_4_IMPL_STEP_1_ADVERSARIAL_PROMPT

You are auditing Step 1 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4` using the Claude subscription
CLI, not an API.

Scope:

- `implementation-notes-spec-015-v0-4.md`
- `testdata/spec015/v04_settlement_receipts.json`
- `phase7-verify/testdata/generator/v04/main.go`
- `phase3-binary/Tests/macprovider-cliTests/SPEC015V04SettlementFixtureTests.swift`
- `phase4-coordinator/internal/spec015contract/`
- `phase5-gateway/internal/spec015contract/`
- `phase7-verify/internal/jcs/v04_settlement_fixture_test.go`
- `specs/SPEC-015-receipts.md` §N

Adversarially verify whether this fixture/contract slice could let a later
implementation settle money against the wrong bytes, wrong route snapshot, wrong
usage shape, wrong receipt version, or unsafe streaming assumptions.

Required checks:

1. Try to find any missing fixture coverage that would let streaming or
   terminal-state behavior drift later.
2. Try to find any strict-shape loophole where extra/missing fields would still
   pass the Step 1 tests.
3. Try to find any signature, receipt-key, or output-hash mismatch that the
   tests fail to bind.
4. Try to find any cross-module import or layout choice that undermines later
   verifier/coordinator/gateway parity.
5. Confirm no SPEC-022 money movement behavior is introduced.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
