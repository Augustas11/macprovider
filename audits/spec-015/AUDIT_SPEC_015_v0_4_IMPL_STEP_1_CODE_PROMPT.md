# AUDIT_SPEC_015_v0_4_IMPL_STEP_1_CODE_PROMPT

You are auditing Step 1 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Audit as the Codex code lane. Do not edit files.

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

1. The fixture corpus includes strict `receipt_version: "4"` signed tuples,
   `route_snapshot_v1`, `settlement_output_v1`, and strict `usage` fixtures.
2. `settlement_output_v1` coverage includes non-streaming `normal_done`,
   streaming `[DONE]`/`normal_done`, `provider_error`, `buyer_cancel`,
   `gateway_timeout`, `upstream_transport_disconnect`, and empty/non-empty
   prefix cases.
3. Swift and Go tests prove byte-identical canonical bytes and SHA-256 hashes
   for route snapshot, usage, settlement output, and receipt tuple fixtures.
4. Phase4 and phase5 do not import `phase7-verify/internal/*`.
5. The generator is deterministic and the regeneration command is documented.
6. No product behavior, coordinator ingestion, provider issuance, or SPEC-022
   money movement is introduced in Step 1.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
