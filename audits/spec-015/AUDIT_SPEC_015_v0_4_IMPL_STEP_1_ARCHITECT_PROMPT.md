# AUDIT_SPEC_015_v0_4_IMPL_STEP_1_ARCHITECT_PROMPT

You are auditing Step 1 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Audit as the Codex architect lane. Do not edit files.

Scope:

- `implementation-notes-spec-015-v0-4.md`
- `testdata/spec015/v04_settlement_receipts.json`
- `phase7-verify/testdata/generator/v04/main.go`
- `phase3-binary/Tests/macprovider-cliTests/SPEC015V04SettlementFixtureTests.swift`
- `phase4-coordinator/internal/spec015contract/`
- `phase5-gateway/internal/spec015contract/`
- `phase7-verify/internal/jcs/v04_settlement_fixture_test.go`
- `specs/SPEC-015-receipts.md` §N
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Step 1

Required checks:

1. The fixture corpus is a suitable contract foundation for later route
   snapshots, terminal/output/usage canonicalization, verifier support, and
   provider issuance steps.
2. The repository layout avoids illegal cross-module imports and leaves a clear
   path for later production canonicalization without importing
   `phase7-verify/internal/*`.
3. The tests pin strict shapes exactly enough to prevent silent optional-field
   drift in v0.4 tuple, route snapshot, usage, and settlement output objects.
4. Streaming receipt requirements are represented at the contract layer without
   adding non-OpenAI SSE events or buyer-dependent receipt delivery.
5. Step 1 remains before product behavior and does not collapse later Step 2-6
   responsibilities into fixture tests.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
